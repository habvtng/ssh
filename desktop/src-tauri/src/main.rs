// Tre SSH desktop — một .exe duy nhất:
//   1. nhúng frontend (thư mục ../../frontend) thẳng vào binary,
//   2. chạy backend axum (crate ssh-web) trên 127.0.0.1 với port trống bất kỳ,
//   3. mở cửa sổ webview trỏ vào chính server đó.
// Dữ liệu (sqlite + khóa mã hóa) nằm trong thư mục app-data của user, không mất khi cập nhật app.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")] // Windows: không kèm cửa sổ console

use axum::{
    http::{header, StatusCode, Uri},
    response::{IntoResponse, Response},
};
use base64::{engine::general_purpose::STANDARD, Engine};
use include_dir::{include_dir, Dir};
use rand::RngCore;
use std::path::{Path, PathBuf};
use tauri::{Manager, WebviewUrl, WebviewWindowBuilder};

// Frontend SPA nhúng lúc compile (index.html + vendor/xterm...).
static FRONTEND: Dir<'_> = include_dir!("$CARGO_MANIFEST_DIR/../../frontend");

fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::from_default_env()
                .add_directive("ssh_web=info".parse().expect("directive")),
        )
        .init();

    tauri::Builder::default()
        .setup(|app| {
            // Thư mục dữ liệu: %APPDATA%\vn.tre360.ssh.desktop (Windows) / ~/Library/Application Support/... (macOS)
            let data_dir = app.path().app_data_dir()?;
            std::fs::create_dir_all(&data_dir)?;

            let (master_key, jwt_secret) = load_or_create_secrets(&data_dir)?;
            let state = ssh_web::build_state_parts(
                &data_dir.join("data.sqlite"),
                master_key,
                jwt_secret,
            )?;
            let router = ssh_web::build_api_router(state).fallback(serve_embedded);

            // Bind trước để biết port thật rồi mới mở cửa sổ trỏ vào đúng port đó.
            let addr = tauri::async_runtime::block_on(async move {
                let (addr, fut) = ssh_web::bind_router("127.0.0.1:0", router).await?;
                tauri::async_runtime::spawn(async move {
                    if let Err(e) = fut.await {
                        tracing::error!("server dừng: {e}");
                    }
                });
                anyhow::Ok(addr)
            })?;
            tracing::info!("Backend nội bộ: http://{addr}");

            WebviewWindowBuilder::new(
                app,
                "main",
                WebviewUrl::External(format!("http://{addr}").parse()?),
            )
            .title("Tre SSH")
            .inner_size(1280.0, 860.0)
            .min_inner_size(900.0, 600.0)
            .build()?;

            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("không khởi động được app Tre SSH");
}

// Phục vụ frontend nhúng trong binary; đường dẫn lạ thì trả index.html (SPA).
async fn serve_embedded(uri: Uri) -> Response {
    let path = uri.path().trim_start_matches('/');
    let path = if path.is_empty() { "index.html" } else { path };
    let file = FRONTEND
        .get_file(path)
        .or_else(|| FRONTEND.get_file("index.html"));
    match file {
        Some(f) => {
            let mime = mime_guess::from_path(f.path()).first_or_octet_stream();
            (
                [(header::CONTENT_TYPE, mime.as_ref().to_string())],
                f.contents().to_vec(),
            )
                .into_response()
        }
        None => (StatusCode::NOT_FOUND, "không tìm thấy frontend").into_response(),
    }
}

// Khóa mã hóa credentials + secret JWT: sinh ngẫu nhiên lần chạy đầu rồi giữ nguyên mãi mãi.
// ĐỔI FILE NÀY = MẤT quyền giải mã mật khẩu/SSH key đã lưu trong data.sqlite.
fn load_or_create_secrets(data_dir: &Path) -> anyhow::Result<([u8; 32], String)> {
    let path: PathBuf = data_dir.join("secrets.txt");
    if let Ok(text) = std::fs::read_to_string(&path) {
        let mut lines = text.lines();
        let key_b64 = lines.next().unwrap_or_default().trim();
        let jwt = lines.next().unwrap_or_default().trim();
        let bytes = STANDARD.decode(key_b64)?;
        if bytes.len() == 32 && !jwt.is_empty() {
            let mut key = [0u8; 32];
            key.copy_from_slice(&bytes);
            return Ok((key, jwt.to_string()));
        }
        tracing::warn!("secrets.txt hỏng — sinh lại (dữ liệu cũ sẽ không giải mã được)");
    }

    let mut key = [0u8; 32];
    rand::thread_rng().fill_bytes(&mut key);
    let mut jwt_raw = [0u8; 48];
    rand::thread_rng().fill_bytes(&mut jwt_raw);
    let jwt = STANDARD.encode(jwt_raw);
    std::fs::write(&path, format!("{}\n{}\n", STANDARD.encode(key), jwt))?;
    Ok((key, jwt))
}
