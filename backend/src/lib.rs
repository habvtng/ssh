// SSH Web Client — thư viện lõi: router + state + server.
// Tách khỏi main.rs để dùng lại được ở 2 chỗ:
//   - bin `ssh-web` (bản server/Docker, cấu hình qua ENV)
//   - app desktop Tauri (Windows/macOS) nhúng thẳng server này vào tiến trình app.
pub mod api;
pub mod auth;
pub mod crypto;
pub mod db;
pub mod localfs;
pub mod sftp;
pub mod ssh;
pub mod tunnel;

use axum::{
    routing::{delete, get, post, put},
    Router,
};
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use tower_http::{cors::CorsLayer, services::ServeDir};

#[derive(Clone)]
pub struct AppState {
    pub db: Arc<tokio::sync::Mutex<rusqlite::Connection>>,
    pub master_key: Arc<[u8; 32]>,
    pub jwt_secret: Arc<String>,
}

/// Cấu hình một lần chạy server.
pub struct ServerConfig {
    pub bind: String,          // "0.0.0.0:8080" hoặc "127.0.0.1:0" (chọn port trống)
    pub db_path: PathBuf,      // file sqlite
    pub static_dir: PathBuf,   // thư mục frontend (index.html + vendor/)
    pub master_key: [u8; 32],
    pub jwt_secret: String,
    /// Cho duyệt/copy file trên máy chạy backend. Bật ở app desktop, TẮT ở bản web hosted.
    pub local_fs: bool,
}

/// Router phần động: REST `/api/*` + WebSocket `/ws/ssh/:id` (chưa có static).
/// App desktop dùng cái này rồi tự gắn frontend nhúng sẵn trong binary.
///
/// `local_fs` = cho phép duyệt/copy file trên chính máy chạy backend. Chỉ bật ở app desktop;
/// bản web hosted bật là client duyệt được ổ đĩa máy chủ.
pub fn build_api_router(state: AppState, local_fs: bool) -> Router {
    // Frontend hỏi cờ này để hiện (hay giấu) nguồn "💻 Máy này" ở màn 2 Server.
    let caps = Router::new().route(
        "/capabilities",
        get(move || async move { axum::Json(serde_json::json!({ "local_fs": local_fs })) }),
    );

    let local_routes = if local_fs {
        Router::new()
            .route("/local/list", post(localfs::list))
            .route("/local/mkdir", post(localfs::mkdir))
            .route("/local/rename", post(localfs::rename))
            .route("/local/delete", post(localfs::delete))
            .route("/local/copy", post(localfs::copy))
            .route("/local/upload", post(localfs::upload))
            .route("/local/download", post(localfs::download))
            .with_state(state.clone())
    } else {
        Router::new()
    };

    let api_routes = Router::new()
        // auth
        .route("/auth/login", post(api::login))
        .route("/auth/register", post(api::register))
        // hosts CRUD
        .route("/hosts", get(api::list_hosts).post(api::create_host))
        .route("/hosts/:id", put(api::update_host).delete(api::delete_host))
        // ssh keys (key management)
        .route("/keys", get(api::list_keys).post(api::create_key))
        .route("/keys/:id", delete(api::delete_key))
        // snippets
        .route("/snippets", get(api::list_snippets).post(api::create_snippet))
        .route("/snippets/:id", delete(api::delete_snippet))
        // port forwards
        .route("/tunnels", get(api::list_tunnels).post(api::create_tunnel))
        .route("/tunnels/:id", delete(api::stop_tunnel))
        // sftp browser
        .route("/sftp/list", post(sftp::list))
        .route("/sftp/read", post(sftp::read))
        .route("/sftp/transfer", post(sftp::transfer))
        .with_state(state.clone())
        // máy này ⟷ server (chỉ có khi local_fs bật) + cờ capabilities cho frontend
        .merge(local_routes)
        .merge(caps);

    Router::new()
        .nest("/api", api_routes)
        // WebSocket: browser <-> server <-> SSH shell
        .route("/ws/ssh/:host_id", get(ssh::ws_handler))
        .with_state(state)
        .layer(CorsLayer::permissive())
}

/// Router đầy đủ: API + frontend đọc từ thư mục trên đĩa (bản server/Docker).
pub fn build_router(state: AppState, static_dir: &Path, local_fs: bool) -> Router {
    build_api_router(state, local_fs).nest_service("/", ServeDir::new(static_dir))
}

/// Mở DB + dựng state.
pub fn build_state_parts(
    db_path: &Path,
    master_key: [u8; 32],
    jwt_secret: String,
) -> anyhow::Result<AppState> {
    let conn = db::init_db(&db_path.to_string_lossy())?;
    Ok(AppState {
        db: Arc::new(tokio::sync::Mutex::new(conn)),
        master_key: Arc::new(master_key),
        jwt_secret: Arc::new(jwt_secret),
    })
}

pub fn build_state(cfg: &ServerConfig) -> anyhow::Result<AppState> {
    build_state_parts(&cfg.db_path, cfg.master_key, cfg.jwt_secret.clone())
}

/// Bind một router bất kỳ, trả địa chỉ thật + future phục vụ.
pub async fn bind_router(
    addr: &str,
    app: Router,
) -> anyhow::Result<(SocketAddr, impl std::future::Future<Output = std::io::Result<()>>)> {
    let listener = tokio::net::TcpListener::bind(addr).await?;
    let local = listener.local_addr()?;
    Ok((local, async move { axum::serve(listener, app).await }))
}

/// Bind trước, trả về địa chỉ thật (biết được port khi bind ":0") + future phục vụ.
/// App desktop cần địa chỉ này để trỏ cửa sổ webview vào đúng port.
pub async fn bind(
    cfg: ServerConfig,
) -> anyhow::Result<(SocketAddr, impl std::future::Future<Output = std::io::Result<()>>)> {
    let state = build_state(&cfg)?;
    let app = build_router(state, &cfg.static_dir, cfg.local_fs);
    bind_router(&cfg.bind, app).await
}

/// Chạy server tới khi tiến trình dừng (dùng cho bin `ssh-web`).
pub async fn serve(cfg: ServerConfig) -> anyhow::Result<()> {
    let (addr, fut) = bind(cfg).await?;
    tracing::info!("Listening on {addr}");
    fut.await?;
    Ok(())
}
