// Schema sqlite + helper thời gian.
// Các bảng phải khớp với câu SQL trong api.rs / ssh.rs.
use rusqlite::Connection;
use std::time::{SystemTime, UNIX_EPOCH};

/// Unix epoch (giây). Dùng cho cột `created`.
pub fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// Mở (hoặc tạo) DB và đảm bảo schema tồn tại.
pub fn init_db(path: &str) -> rusqlite::Result<Connection> {
    // Tạo thư mục cha nếu chưa có (vd. data/ khi chạy ngoài Docker).
    if let Some(dir) = std::path::Path::new(path).parent() {
        if !dir.as_os_str().is_empty() {
            let _ = std::fs::create_dir_all(dir);
        }
    }
    let conn = Connection::open(path)?;
    conn.execute_batch(
        r#"
        PRAGMA journal_mode = WAL;
        PRAGMA foreign_keys = ON;

        CREATE TABLE IF NOT EXISTS users (
            id        TEXT PRIMARY KEY,
            username  TEXT NOT NULL UNIQUE,
            pw_hash   TEXT NOT NULL,
            created   INTEGER NOT NULL
        );

        CREATE TABLE IF NOT EXISTS hosts (
            id            TEXT PRIMARY KEY,
            user_id       TEXT NOT NULL,
            label         TEXT NOT NULL,
            host          TEXT NOT NULL,
            port          INTEGER NOT NULL,
            username      TEXT NOT NULL,
            auth_type     TEXT NOT NULL,            -- "password" | "key"
            password_enc  TEXT,                     -- AES-256-GCM, base64
            key_id        TEXT,
            created       INTEGER NOT NULL
        );

        CREATE TABLE IF NOT EXISTS ssh_keys (
            id              TEXT PRIMARY KEY,
            user_id         TEXT NOT NULL,
            name            TEXT NOT NULL,
            priv_enc        TEXT NOT NULL,          -- private key PEM, mã hóa
            passphrase_enc  TEXT,
            created         INTEGER NOT NULL
        );

        CREATE TABLE IF NOT EXISTS snippets (
            id        TEXT PRIMARY KEY,
            user_id   TEXT NOT NULL,
            name      TEXT NOT NULL,
            command   TEXT NOT NULL,
            created   INTEGER NOT NULL
        );

        CREATE TABLE IF NOT EXISTS tunnels (
            id           TEXT PRIMARY KEY,
            user_id      TEXT NOT NULL,
            host_id      TEXT NOT NULL,
            kind         TEXT NOT NULL,             -- "local" | "remote" | "dynamic"
            listen_host  TEXT NOT NULL,
            listen_port  INTEGER NOT NULL,
            dest_host    TEXT,
            dest_port    INTEGER,
            created      INTEGER NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_hosts_user    ON hosts(user_id);
        CREATE INDEX IF NOT EXISTS idx_keys_user     ON ssh_keys(user_id);
        CREATE INDEX IF NOT EXISTS idx_snippets_user ON snippets(user_id);
        CREATE INDEX IF NOT EXISTS idx_tunnels_user  ON tunnels(user_id);
        "#,
    )?;
    Ok(conn)
}
