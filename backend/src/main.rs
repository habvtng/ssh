// SSH Web Client — backend (axum + russh)
// Entrypoint: HTTP API + WebSocket SSH bridge + static frontend
mod db;
mod crypto;
mod auth;
mod ssh;
mod sftp;
mod api;
mod tunnel;

use axum::{
    routing::{get, post, delete, put},
    Router,
};
use std::sync::Arc;
use tower_http::{cors::CorsLayer, services::ServeDir};
use tracing_subscriber::EnvFilter;

#[derive(Clone)]
pub struct AppState {
    pub db: Arc<tokio::sync::Mutex<rusqlite::Connection>>,
    pub master_key: Arc<[u8; 32]>,
    pub jwt_secret: Arc<String>,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::from_default_env().add_directive("ssh_web=info".parse()?))
        .init();

    // Master key cho mã hóa credentials. Lấy từ ENV (32 bytes base64) — KHÔNG hardcode trong prod.
    let master_key = crypto::load_or_create_master_key()?;
    let jwt_secret = std::env::var("JWT_SECRET")
        .unwrap_or_else(|_| "change-me-in-production-please".into());

    // Mặc định ghi vào /app/data (volume mount) để persist qua rebuild; đổi bằng DB_PATH.
    let db_path = std::env::var("DB_PATH").unwrap_or_else(|_| "data/data.sqlite".into());
    let conn = db::init_db(&db_path)?;
    let state = AppState {
        db: Arc::new(tokio::sync::Mutex::new(conn)),
        master_key: Arc::new(master_key),
        jwt_secret: Arc::new(jwt_secret),
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
        .with_state(state.clone());

    let app = Router::new()
        .nest("/api", api_routes)
        // WebSocket: browser <-> server <-> SSH shell
        .route("/ws/ssh/:host_id", get(ssh::ws_handler))
        .with_state(state)
        .nest_service("/", ServeDir::new("static"))
        .layer(CorsLayer::permissive());

    let addr = std::env::var("BIND").unwrap_or_else(|_| "0.0.0.0:8080".into());
    tracing::info!("Listening on {addr}");
    let listener = tokio::net::TcpListener::bind(&addr).await?;
    axum::serve(listener, app).await?;
    Ok(())
}
