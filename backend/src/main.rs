// SSH Web Client — backend (axum + russh)
// Entrypoint bản server/Docker: đọc cấu hình từ ENV rồi chạy server trong lib.rs.
// (App desktop Tauri dùng chung lib này, xem desktop/src-tauri/src/main.rs.)
use ssh_web::{crypto, serve, ServerConfig};
use tracing_subscriber::EnvFilter;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::from_default_env().add_directive("ssh_web=info".parse()?))
        .init();

    // Master key cho mã hóa credentials. Lấy từ ENV (32 bytes base64) — KHÔNG hardcode trong prod.
    let master_key = crypto::load_or_create_master_key()?;
    let jwt_secret =
        std::env::var("JWT_SECRET").unwrap_or_else(|_| "change-me-in-production-please".into());

    serve(ServerConfig {
        bind: std::env::var("BIND").unwrap_or_else(|_| "0.0.0.0:8080".into()),
        // Mặc định ghi vào /app/data (volume mount) để persist qua rebuild; đổi bằng DB_PATH.
        db_path: std::env::var("DB_PATH")
            .unwrap_or_else(|_| "data/data.sqlite".into())
            .into(),
        static_dir: std::env::var("STATIC_DIR")
            .unwrap_or_else(|_| "static".into())
            .into(),
        master_key,
        jwt_secret,
        // ⚠ Bản web hosted phải để TẮT: bật là client duyệt được ổ đĩa của máy chủ.
        // Chỉ bật khi tự chạy trên máy mình (LOCAL_FS=1), còn app desktop luôn bật.
        local_fs: std::env::var("LOCAL_FS").map(|v| v == "1").unwrap_or(false),
    })
    .await
}
