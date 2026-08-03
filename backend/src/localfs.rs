// Duyệt file trên CHÍNH MÁY chạy backend + copy qua lại với server SFTP.
//
// ⚠ CHỈ bật cho app desktop (backend chạy trên máy người dùng). Bản web hosted phải TẮT,
// nếu không client duyệt được ổ đĩa của máy chủ. Cổng bật/tắt: ServerConfig.local_fs
// (bin ssh-web đọc ENV LOCAL_FS=1, mặc định tắt).
use axum::{extract::State, http::StatusCode, Json};
use russh_sftp::client::SftpSession;
use serde::Deserialize;
use serde_json::{json, Value};
use std::path::{Path, PathBuf};

use crate::{auth::AuthUser, sftp::open_sftp_for, AppState};

type R = Result<Json<Value>, (StatusCode, String)>;
fn err(c: StatusCode, m: impl ToString) -> (StatusCode, String) {
    (c, m.to_string())
}
fn bad(m: impl ToString) -> (StatusCode, String) {
    err(StatusCode::BAD_REQUEST, m)
}

// canonicalize() trên Windows trả về dạng verbatim `\\?\C:\...` — cắt đi cho dễ đọc.
fn pretty(p: &Path) -> String {
    let s = p.to_string_lossy().to_string();
    s.strip_prefix(r"\\?\").unwrap_or(&s).to_string()
}

fn home_dir() -> PathBuf {
    std::env::var_os("USERPROFILE")
        .or_else(|| std::env::var_os("HOME"))
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/"))
}

// Danh sách ổ đĩa (Windows). Dùng khi ở "trên cùng" — đi lên quá gốc ổ đĩa.
#[cfg(windows)]
fn drives() -> Vec<Value> {
    (b'A'..=b'Z')
        .map(|c| format!("{}:\\", c as char))
        .filter(|d| Path::new(d).exists())
        .map(|d| json!({ "name": d, "type": "dir", "size": 0 }))
        .collect()
}
#[cfg(not(windows))]
fn drives() -> Vec<Value> {
    vec![json!({ "name": "/", "type": "dir", "size": 0 })]
}

// "" hoặc "." → home; còn lại canonicalize. Lỗi (vd. "C:\\..") → None = mức ổ đĩa.
fn resolve(input: &str) -> Option<PathBuf> {
    let raw = input.trim();
    if raw.is_empty() || raw == "." {
        return Some(std::fs::canonicalize(home_dir()).unwrap_or_else(|_| home_dir()));
    }
    if raw == "@drives" {
        return None;
    }
    std::fs::canonicalize(raw).ok()
}

#[derive(Deserialize)]
pub struct PathReq {
    pub path: Option<String>,
}

pub async fn list(AuthUser(_uid): AuthUser, Json(req): Json<PathReq>) -> R {
    let input = req.path.unwrap_or_default();
    let Some(dir) = resolve(&input) else {
        return Ok(Json(json!({ "path": "@drives", "entries": drives() })));
    };
    if !dir.is_dir() {
        return Err(bad(format!("{} không phải thư mục", pretty(&dir))));
    }

    let mut rd = tokio::fs::read_dir(&dir)
        .await
        .map_err(|e| bad(format!("không đọc được thư mục: {e}")))?;
    // (không phải thư mục, tên thường, json) → thư mục lên trước, rồi theo tên.
    let mut rows: Vec<(bool, String, Value)> = Vec::new();
    while let Ok(Some(e)) = rd.next_entry().await {
        let name = e.file_name().to_string_lossy().to_string();
        let md = match e.metadata().await {
            Ok(m) => m,
            Err(_) => continue, // file bị khoá quyền — bỏ qua, đừng làm hỏng cả listing
        };
        let kind = if md.is_dir() {
            "dir"
        } else if md.is_symlink() {
            "symlink"
        } else {
            "file"
        };
        rows.push((
            !md.is_dir(),
            name.to_lowercase(),
            json!({ "name": name, "type": kind, "size": md.len() }),
        ));
    }
    rows.sort_by(|a, b| a.0.cmp(&b.0).then(a.1.cmp(&b.1)));
    let entries: Vec<Value> = rows.into_iter().map(|(_, _, v)| v).collect();

    Ok(Json(json!({ "path": pretty(&dir), "entries": entries })))
}

#[derive(Deserialize)]
pub struct MkdirReq {
    pub path: String,
}
pub async fn mkdir(AuthUser(_uid): AuthUser, Json(req): Json<MkdirReq>) -> R {
    tokio::fs::create_dir_all(&req.path)
        .await
        .map_err(|e| bad(e))?;
    Ok(Json(json!({ "ok": true })))
}

#[derive(Deserialize)]
pub struct RenameReq {
    pub from: String,
    pub to: String,
}
pub async fn rename(AuthUser(_uid): AuthUser, Json(req): Json<RenameReq>) -> R {
    if Path::new(&req.to).exists() {
        return Err(bad("tên đích đã tồn tại"));
    }
    tokio::fs::rename(&req.from, &req.to)
        .await
        .map_err(|e| bad(e))?;
    Ok(Json(json!({ "ok": true })))
}

#[derive(Deserialize)]
pub struct DeleteReq {
    pub path: String,
}
pub async fn delete(AuthUser(_uid): AuthUser, Json(req): Json<DeleteReq>) -> R {
    let p = PathBuf::from(&req.path);
    let md = tokio::fs::symlink_metadata(&p).await.map_err(|e| bad(e))?;
    if md.is_dir() {
        tokio::fs::remove_dir_all(&p).await.map_err(|e| bad(e))?;
    } else {
        tokio::fs::remove_file(&p).await.map_err(|e| bad(e))?;
    }
    Ok(Json(json!({ "ok": true })))
}

// --- Copy: máy này ⟷ server, và máy này → máy này ---

#[derive(Deserialize)]
pub struct XferReq {
    pub host_id: String,
    pub src: String,     // đường dẫn nguồn (tuyệt đối)
    pub dst_dir: String, // thư mục đích
    pub name: String,    // tên mục tạo dưới dst_dir
}

// Ghép path kiểu unix cho phía server SFTP.
fn rjoin(base: &str, name: &str) -> String {
    if base == "/" {
        format!("/{name}")
    } else {
        format!("{}/{}", base.trim_end_matches('/'), name)
    }
}

// Máy này → server (đệ quy, stack tường minh để khỏi async đệ quy).
async fn upload_tree(sftp: &SftpSession, src: PathBuf, dst: String) -> anyhow::Result<(u64, u64)> {
    let (mut files, mut bytes) = (0u64, 0u64);
    let mut stack = vec![(src, dst)];
    while let Some((sp, dp)) = stack.pop() {
        if sp.is_dir() {
            let _ = sftp.create_dir(&dp).await;
            let mut rd = tokio::fs::read_dir(&sp).await?;
            while let Some(e) = rd.next_entry().await? {
                let name = e.file_name().to_string_lossy().to_string();
                stack.push((sp.join(&name), rjoin(&dp, &name)));
            }
        } else {
            let data = tokio::fs::read(&sp).await?;
            bytes += data.len() as u64;
            sftp.write(&dp, &data).await?;
            files += 1;
        }
    }
    Ok((files, bytes))
}

// Server → máy này (đệ quy).
async fn download_tree(sftp: &SftpSession, src: String, dst: PathBuf) -> anyhow::Result<(u64, u64)> {
    let (mut files, mut bytes) = (0u64, 0u64);
    let mut stack = vec![(src, dst)];
    while let Some((sp, dp)) = stack.pop() {
        let md = sftp.metadata(&sp).await?;
        if md.is_dir() {
            tokio::fs::create_dir_all(&dp).await?;
            for e in sftp.read_dir(&sp).await? {
                let name = e.file_name();
                if name == "." || name == ".." {
                    continue;
                }
                stack.push((rjoin(&sp, &name), dp.join(&name)));
            }
        } else {
            let data = sftp.read(&sp).await?;
            bytes += data.len() as u64;
            tokio::fs::write(&dp, &data).await?;
            files += 1;
        }
    }
    Ok((files, bytes))
}

pub async fn upload(State(s): State<AppState>, AuthUser(uid): AuthUser, Json(req): Json<XferReq>) -> R {
    let (_sess, sftp) = open_sftp_for(&s, &uid, &req.host_id)
        .await
        .map_err(|e| err(StatusCode::BAD_GATEWAY, e))?;
    let dst = rjoin(&req.dst_dir, &req.name);
    let (files, bytes) = upload_tree(&sftp, PathBuf::from(&req.src), dst.clone())
        .await
        .map_err(|e| err(StatusCode::BAD_GATEWAY, e))?;
    Ok(Json(json!({ "ok": true, "dst": dst, "files": files, "bytes": bytes })))
}

pub async fn download(State(s): State<AppState>, AuthUser(uid): AuthUser, Json(req): Json<XferReq>) -> R {
    let (_sess, sftp) = open_sftp_for(&s, &uid, &req.host_id)
        .await
        .map_err(|e| err(StatusCode::BAD_GATEWAY, e))?;
    let dst = PathBuf::from(&req.dst_dir).join(&req.name);
    let (files, bytes) = download_tree(&sftp, req.src.clone(), dst.clone())
        .await
        .map_err(|e| err(StatusCode::BAD_GATEWAY, e))?;
    Ok(Json(json!({ "ok": true, "dst": pretty(&dst), "files": files, "bytes": bytes })))
}

#[derive(Deserialize)]
pub struct LocalCopyReq {
    pub src: String,
    pub dst_dir: String,
    pub name: String,
}

// Máy này → máy này.
pub async fn copy(AuthUser(_uid): AuthUser, Json(req): Json<LocalCopyReq>) -> R {
    let src = PathBuf::from(&req.src);
    let dst = PathBuf::from(&req.dst_dir).join(&req.name);
    if dst.exists() {
        return Err(bad(format!("\"{}\" đã tồn tại ở thư mục đích", req.name)));
    }
    if dst.starts_with(&src) {
        return Err(bad("không copy được thư mục vào chính nó"));
    }

    let (mut files, mut bytes) = (0u64, 0u64);
    let mut stack = vec![(src, dst.clone())];
    while let Some((sp, dp)) = stack.pop() {
        if sp.is_dir() {
            tokio::fs::create_dir_all(&dp).await.map_err(|e| bad(e))?;
            let mut rd = tokio::fs::read_dir(&sp).await.map_err(|e| bad(e))?;
            while let Ok(Some(e)) = rd.next_entry().await {
                let name = e.file_name();
                stack.push((sp.join(&name), dp.join(&name)));
            }
        } else {
            bytes += tokio::fs::copy(&sp, &dp).await.map_err(|e| bad(e))?;
            files += 1;
        }
    }
    Ok(Json(json!({ "ok": true, "dst": pretty(&dst), "files": files, "bytes": bytes })))
}
