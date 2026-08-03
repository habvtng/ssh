// SFTP browser: list thư mục + đọc file qua russh-sftp (chạy trên 1 channel SSH).
use axum::{extract::State, http::StatusCode, Json};
use russh_sftp::client::SftpSession;
use serde::Deserialize;
use serde_json::{json, Value};

use crate::{auth::AuthUser, ssh, AppState};

type R = Result<Json<Value>, (StatusCode, String)>;
fn err(c: StatusCode, m: impl ToString) -> (StatusCode, String) {
    (c, m.to_string())
}

// Mở 1 phiên SFTP tới host. Giữ luôn `Handle` (session) để kết nối SSH không bị đóng
// khi đang dùng channel — caller phải bind nó tới hết vòng đời sftp.
// Dùng lại ở localfs.rs (copy máy này ⟷ server).
pub(crate) async fn open_sftp_for(
    s: &AppState,
    uid: &str,
    host_id: &str,
) -> anyhow::Result<(russh::client::Handle<ssh::Handler>, SftpSession)> {
    open_sftp(s, uid, host_id).await
}

async fn open_sftp(
    s: &AppState,
    uid: &str,
    host_id: &str,
) -> anyhow::Result<(russh::client::Handle<ssh::Handler>, SftpSession)> {
    let host = ssh::load_host(s, uid, host_id).await?;
    let session = ssh::connect_session(&host).await?;
    let channel = session.channel_open_session().await?;
    channel.request_subsystem(true, "sftp").await?;
    let sftp = SftpSession::new(channel.into_stream()).await?;
    Ok((session, sftp))
}

// ---------- LIST ----------
#[derive(Deserialize)]
pub struct ListReq {
    pub host_id: String,
    pub path: Option<String>,
}

pub async fn list(State(s): State<AppState>, AuthUser(uid): AuthUser, Json(req): Json<ListReq>) -> R {
    let req_path = req.path.unwrap_or_else(|| ".".to_string());
    let (_session, sftp) = open_sftp(&s, &uid, &req.host_id)
        .await
        .map_err(|e| err(StatusCode::BAD_GATEWAY, e))?;

    // Chuẩn hóa về đường tuyệt đối (xử lý "." và "..") cho breadcrumb.
    let abs = sftp.canonicalize(&req_path).await.unwrap_or(req_path);

    let dir = sftp
        .read_dir(&abs)
        .await
        .map_err(|e| err(StatusCode::BAD_GATEWAY, e))?;

    // (is_dir, tên_thường, json) để sắp xếp: thư mục trước, rồi theo tên.
    let mut rows: Vec<(bool, String, Value)> = Vec::new();
    for e in dir {
        let name = e.file_name();
        if name == "." || name == ".." {
            continue;
        }
        let ft = e.file_type();
        let md = e.metadata();
        let kind = if ft.is_dir() {
            "dir"
        } else if ft.is_symlink() {
            "symlink"
        } else {
            "file"
        };
        rows.push((
            ft.is_dir(),
            name.to_lowercase(),
            json!({ "name": name, "type": kind, "size": md.size, "mtime": md.mtime }),
        ));
    }
    rows.sort_by(|a, b| b.0.cmp(&a.0).then(a.1.cmp(&b.1)));
    let entries: Vec<Value> = rows.into_iter().map(|(_, _, v)| v).collect();

    Ok(Json(json!({ "path": abs, "entries": entries })))
}

// ---------- READ (xem file) ----------
const MAX_VIEW: usize = 1024 * 1024; // 1 MB

#[derive(Deserialize)]
pub struct ReadReq {
    pub host_id: String,
    pub path: String,
}

pub async fn read(State(s): State<AppState>, AuthUser(uid): AuthUser, Json(req): Json<ReadReq>) -> R {
    let (_session, sftp) = open_sftp(&s, &uid, &req.host_id)
        .await
        .map_err(|e| err(StatusCode::BAD_GATEWAY, e))?;

    let data = sftp
        .read(&req.path)
        .await
        .map_err(|e| err(StatusCode::BAD_GATEWAY, e))?;

    let total = data.len();
    let truncated = total > MAX_VIEW;
    let slice = &data[..total.min(MAX_VIEW)];

    match std::str::from_utf8(slice) {
        Ok(text) => Ok(Json(
            json!({ "kind": "text", "content": text, "truncated": truncated, "size": total }),
        )),
        Err(_) => {
            use base64::{engine::general_purpose::STANDARD, Engine};
            Ok(Json(json!({
                "kind": "binary",
                "base64": STANDARD.encode(slice),
                "truncated": truncated,
                "size": total
            })))
        }
    }
}

// ---------- TRANSFER (copy file/thư mục giữa 2 host) ----------
// Mở SFTP tới CẢ HAI host trong cùng request, đọc từ nguồn → ghi sang đích.
// Thư mục copy đệ quy (server làm cầu nối, không qua máy client).
#[derive(Deserialize)]
pub struct TransferReq {
    pub src_host_id: String,
    pub src_path: String, // đường dẫn tuyệt đối tới file/thư mục nguồn
    pub dst_host_id: String,
    pub dst_dir: String, // thư mục đích sẽ chứa bản sao
    pub name: String,    // tên mục tạo dưới dst_dir
}

// Ghép path kiểu unix, bỏ '/' thừa ở cuối base.
fn join(base: &str, name: &str) -> String {
    if base == "/" {
        format!("/{name}")
    } else {
        format!("{}/{}", base.trim_end_matches('/'), name)
    }
}

// Copy đệ quy bằng stack tường minh (tránh async đệ quy phải Box::pin).
async fn copy_tree(
    src: &SftpSession,
    dst: &SftpSession,
    src_root: String,
    dst_root: String,
) -> anyhow::Result<(u64, u64)> {
    let mut files = 0u64;
    let mut bytes = 0u64;
    let mut stack = vec![(src_root, dst_root)];
    while let Some((sp, dp)) = stack.pop() {
        let md = src.metadata(&sp).await?;
        if md.is_dir() {
            // Tạo thư mục đích (bỏ qua lỗi nếu đã tồn tại).
            let _ = dst.create_dir(&dp).await;
            for e in src.read_dir(&sp).await? {
                let name = e.file_name();
                if name == "." || name == ".." {
                    continue;
                }
                stack.push((join(&sp, &name), join(&dp, &name)));
            }
        } else {
            let data = src.read(&sp).await?;
            bytes += data.len() as u64;
            dst.write(&dp, &data).await?;
            files += 1;
        }
    }
    Ok((files, bytes))
}

pub async fn transfer(
    State(s): State<AppState>,
    AuthUser(uid): AuthUser,
    Json(req): Json<TransferReq>,
) -> R {
    let (_s1, src) = open_sftp(&s, &uid, &req.src_host_id)
        .await
        .map_err(|e| err(StatusCode::BAD_GATEWAY, e))?;
    let (_s2, dst) = open_sftp(&s, &uid, &req.dst_host_id)
        .await
        .map_err(|e| err(StatusCode::BAD_GATEWAY, e))?;

    let dst_path = join(&req.dst_dir, &req.name);
    let (files, bytes) = copy_tree(&src, &dst, req.src_path.clone(), dst_path.clone())
        .await
        .map_err(|e| err(StatusCode::BAD_GATEWAY, e))?;

    Ok(Json(json!({ "ok": true, "dst": dst_path, "files": files, "bytes": bytes })))
}
