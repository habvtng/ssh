// REST API handlers.
use axum::{extract::{State, Path}, Json, http::StatusCode};
use serde::{Serialize, Deserialize};
use serde_json::{json, Value};
use crate::{AppState, auth::{self, AuthUser}, crypto, db::now};
use uuid::Uuid;

type R = Result<Json<Value>, (StatusCode, String)>;
fn err(c: StatusCode, m: impl ToString) -> (StatusCode, String) { (c, m.to_string()) }

// ---------- AUTH ----------
#[derive(Deserialize)]
pub struct Credentials { pub username: String, pub password: String }

pub async fn register(State(s): State<AppState>, Json(c): Json<Credentials>) -> R {
    let db = s.db.lock().await;
    let id = Uuid::new_v4().to_string();
    let hash = auth::hash_pw(&c.password).map_err(|e| err(StatusCode::INTERNAL_SERVER_ERROR, e))?;
    db.execute("INSERT INTO users (id,username,pw_hash,created) VALUES (?,?,?,?)",
        rusqlite::params![id, c.username, hash, now()])
        .map_err(|_| err(StatusCode::CONFLICT, "username đã tồn tại"))?;
    let token = auth::make_token(&s.jwt_secret, &id).map_err(|e| err(StatusCode::INTERNAL_SERVER_ERROR, e))?;
    Ok(Json(json!({ "token": token })))
}

pub async fn login(State(s): State<AppState>, Json(c): Json<Credentials>) -> R {
    let db = s.db.lock().await;
    let (id, hash): (String, String) = db.query_row(
        "SELECT id, pw_hash FROM users WHERE username=?",
        [&c.username], |r| Ok((r.get(0)?, r.get(1)?)))
        .map_err(|_| err(StatusCode::UNAUTHORIZED, "sai tài khoản"))?;
    if !auth::verify_pw(&c.password, &hash) {
        return Err(err(StatusCode::UNAUTHORIZED, "sai mật khẩu"));
    }
    let token = auth::make_token(&s.jwt_secret, &id).map_err(|e| err(StatusCode::INTERNAL_SERVER_ERROR, e))?;
    Ok(Json(json!({ "token": token })))
}

// ---------- HOSTS ----------
#[derive(Deserialize)]
pub struct HostIn {
    pub label: String, pub host: String, pub port: u16, pub username: String,
    pub auth_type: String,          // "password" | "key"
    pub password: Option<String>,
    pub key_id: Option<String>,
}

pub async fn list_hosts(State(s): State<AppState>, AuthUser(uid): AuthUser) -> R {
    let db = s.db.lock().await;
    let mut stmt = db.prepare(
        "SELECT id,label,host,port,username,auth_type,key_id FROM hosts WHERE user_id=? ORDER BY label")
        .map_err(|e| err(StatusCode::INTERNAL_SERVER_ERROR, e))?;
    let rows = stmt.query_map([&uid], |r| Ok(json!({
        "id": r.get::<_,String>(0)?, "label": r.get::<_,String>(1)?,
        "host": r.get::<_,String>(2)?, "port": r.get::<_,i64>(3)?,
        "username": r.get::<_,String>(4)?, "auth_type": r.get::<_,String>(5)?,
        "key_id": r.get::<_,Option<String>>(6)?,
    }))).map_err(|e| err(StatusCode::INTERNAL_SERVER_ERROR, e))?;
    let list: Vec<Value> = rows.filter_map(|x| x.ok()).collect();
    Ok(Json(json!(list)))
}

pub async fn create_host(State(s): State<AppState>, AuthUser(uid): AuthUser, Json(h): Json<HostIn>) -> R {
    let db = s.db.lock().await;
    let id = Uuid::new_v4().to_string();
    let pw_enc = match &h.password {
        Some(p) if !p.is_empty() => Some(crypto::encrypt(&s.master_key, p)
            .map_err(|e| err(StatusCode::INTERNAL_SERVER_ERROR, e))?),
        _ => None,
    };
    db.execute(
        "INSERT INTO hosts (id,user_id,label,host,port,username,auth_type,password_enc,key_id,created)
         VALUES (?,?,?,?,?,?,?,?,?,?)",
        rusqlite::params![id, uid, h.label, h.host, h.port, h.username, h.auth_type, pw_enc, h.key_id, now()])
        .map_err(|e| err(StatusCode::INTERNAL_SERVER_ERROR, e))?;
    Ok(Json(json!({ "id": id })))
}

pub async fn update_host(State(s): State<AppState>, AuthUser(uid): AuthUser, Path(id): Path<String>, Json(h): Json<HostIn>) -> R {
    let db = s.db.lock().await;
    let pw_enc = match &h.password {
        Some(p) if !p.is_empty() => Some(crypto::encrypt(&s.master_key, p)
            .map_err(|e| err(StatusCode::INTERNAL_SERVER_ERROR, e))?),
        _ => None,
    };
    db.execute(
        "UPDATE hosts SET label=?,host=?,port=?,username=?,auth_type=?,
         password_enc=COALESCE(?,password_enc),key_id=? WHERE id=? AND user_id=?",
        rusqlite::params![h.label,h.host,h.port,h.username,h.auth_type,pw_enc,h.key_id,id,uid])
        .map_err(|e| err(StatusCode::INTERNAL_SERVER_ERROR, e))?;
    Ok(Json(json!({ "ok": true })))
}

pub async fn delete_host(State(s): State<AppState>, AuthUser(uid): AuthUser, Path(id): Path<String>) -> R {
    let db = s.db.lock().await;
    db.execute("DELETE FROM hosts WHERE id=? AND user_id=?", rusqlite::params![id, uid])
        .map_err(|e| err(StatusCode::INTERNAL_SERVER_ERROR, e))?;
    Ok(Json(json!({ "ok": true })))
}

// ---------- SSH KEYS ----------
#[derive(Deserialize)]
pub struct KeyIn { pub name: String, pub private_key: String, pub passphrase: Option<String> }

pub async fn list_keys(State(s): State<AppState>, AuthUser(uid): AuthUser) -> R {
    let db = s.db.lock().await;
    let mut stmt = db.prepare("SELECT id,name,created FROM ssh_keys WHERE user_id=? ORDER BY name")
        .map_err(|e| err(StatusCode::INTERNAL_SERVER_ERROR, e))?;
    let rows = stmt.query_map([&uid], |r| Ok(json!({
        "id": r.get::<_,String>(0)?, "name": r.get::<_,String>(1)?, "created": r.get::<_,i64>(2)?
    }))).map_err(|e| err(StatusCode::INTERNAL_SERVER_ERROR, e))?;
    Ok(Json(json!(rows.filter_map(|x| x.ok()).collect::<Vec<_>>())))
}

pub async fn create_key(State(s): State<AppState>, AuthUser(uid): AuthUser, Json(k): Json<KeyIn>) -> R {
    let db = s.db.lock().await;
    let id = Uuid::new_v4().to_string();
    let priv_enc = crypto::encrypt(&s.master_key, &k.private_key)
        .map_err(|e| err(StatusCode::INTERNAL_SERVER_ERROR, e))?;
    let pass_enc = match &k.passphrase {
        Some(p) if !p.is_empty() => Some(crypto::encrypt(&s.master_key, p)
            .map_err(|e| err(StatusCode::INTERNAL_SERVER_ERROR, e))?),
        _ => None,
    };
    db.execute("INSERT INTO ssh_keys (id,user_id,name,priv_enc,passphrase_enc,created) VALUES (?,?,?,?,?,?)",
        rusqlite::params![id, uid, k.name, priv_enc, pass_enc, now()])
        .map_err(|e| err(StatusCode::INTERNAL_SERVER_ERROR, e))?;
    Ok(Json(json!({ "id": id })))
}

pub async fn delete_key(State(s): State<AppState>, AuthUser(uid): AuthUser, Path(id): Path<String>) -> R {
    let db = s.db.lock().await;
    db.execute("DELETE FROM ssh_keys WHERE id=? AND user_id=?", rusqlite::params![id, uid])
        .map_err(|e| err(StatusCode::INTERNAL_SERVER_ERROR, e))?;
    Ok(Json(json!({ "ok": true })))
}

// ---------- SNIPPETS ----------
#[derive(Deserialize)]
pub struct SnippetIn { pub name: String, pub command: String }

pub async fn list_snippets(State(s): State<AppState>, AuthUser(uid): AuthUser) -> R {
    let db = s.db.lock().await;
    let mut stmt = db.prepare("SELECT id,name,command FROM snippets WHERE user_id=? ORDER BY name")
        .map_err(|e| err(StatusCode::INTERNAL_SERVER_ERROR, e))?;
    let rows = stmt.query_map([&uid], |r| Ok(json!({
        "id": r.get::<_,String>(0)?, "name": r.get::<_,String>(1)?, "command": r.get::<_,String>(2)?
    }))).map_err(|e| err(StatusCode::INTERNAL_SERVER_ERROR, e))?;
    Ok(Json(json!(rows.filter_map(|x| x.ok()).collect::<Vec<_>>())))
}

pub async fn create_snippet(State(s): State<AppState>, AuthUser(uid): AuthUser, Json(sn): Json<SnippetIn>) -> R {
    let db = s.db.lock().await;
    let id = Uuid::new_v4().to_string();
    db.execute("INSERT INTO snippets (id,user_id,name,command,created) VALUES (?,?,?,?,?)",
        rusqlite::params![id, uid, sn.name, sn.command, now()])
        .map_err(|e| err(StatusCode::INTERNAL_SERVER_ERROR, e))?;
    Ok(Json(json!({ "id": id })))
}

pub async fn delete_snippet(State(s): State<AppState>, AuthUser(uid): AuthUser, Path(id): Path<String>) -> R {
    let db = s.db.lock().await;
    db.execute("DELETE FROM snippets WHERE id=? AND user_id=?", rusqlite::params![id, uid])
        .map_err(|e| err(StatusCode::INTERNAL_SERVER_ERROR, e))?;
    Ok(Json(json!({ "ok": true })))
}

// ---------- TUNNELS (port forward) ----------
#[derive(Deserialize)]
pub struct TunnelIn {
    pub host_id: String, pub kind: String,
    pub listen_host: String, pub listen_port: u16,
    pub dest_host: Option<String>, pub dest_port: Option<u16>,
}

pub async fn list_tunnels(State(s): State<AppState>, AuthUser(uid): AuthUser) -> R {
    let db = s.db.lock().await;
    let mut stmt = db.prepare(
        "SELECT id,host_id,kind,listen_host,listen_port,dest_host,dest_port FROM tunnels WHERE user_id=?")
        .map_err(|e| err(StatusCode::INTERNAL_SERVER_ERROR, e))?;
    let rows = stmt.query_map([&uid], |r| Ok(json!({
        "id": r.get::<_,String>(0)?, "host_id": r.get::<_,String>(1)?, "kind": r.get::<_,String>(2)?,
        "listen_host": r.get::<_,String>(3)?, "listen_port": r.get::<_,i64>(4)?,
        "dest_host": r.get::<_,Option<String>>(5)?, "dest_port": r.get::<_,Option<i64>>(6)?,
    }))).map_err(|e| err(StatusCode::INTERNAL_SERVER_ERROR, e))?;
    Ok(Json(json!(rows.filter_map(|x| x.ok()).collect::<Vec<_>>())))
}

pub async fn create_tunnel(State(s): State<AppState>, AuthUser(uid): AuthUser, Json(t): Json<TunnelIn>) -> R {
    let db = s.db.lock().await;
    let id = Uuid::new_v4().to_string();
    db.execute(
        "INSERT INTO tunnels (id,user_id,host_id,kind,listen_host,listen_port,dest_host,dest_port,created)
         VALUES (?,?,?,?,?,?,?,?,?)",
        rusqlite::params![id,uid,t.host_id,t.kind,t.listen_host,t.listen_port,t.dest_host,t.dest_port,now()])
        .map_err(|e| err(StatusCode::INTERNAL_SERVER_ERROR, e))?;
    // Khởi động tunnel thực tế qua tunnel::start (xem tunnel.rs)
    Ok(Json(json!({ "id": id, "note": "tunnel record created — start handled by tunnel manager" })))
}

pub async fn stop_tunnel(State(s): State<AppState>, AuthUser(uid): AuthUser, Path(id): Path<String>) -> R {
    let db = s.db.lock().await;
    db.execute("DELETE FROM tunnels WHERE id=? AND user_id=?", rusqlite::params![id, uid])
        .map_err(|e| err(StatusCode::INTERNAL_SERVER_ERROR, e))?;
    Ok(Json(json!({ "ok": true })))
}
