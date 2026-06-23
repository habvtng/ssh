// WebSocket <-> SSH bridge. Mở PTY shell trên host, stream 2 chiều.
// Protocol từ browser (JSON text frames):
//   {"t":"data","d":"<base64? no — raw>"}   -> gửi keystrokes
//   {"t":"resize","cols":N,"rows":M}        -> resize PTY
// Server -> browser: binary frames = output thô từ shell.
use axum::{
    extract::{State, Path, ws::{WebSocket, WebSocketUpgrade, Message}},
    response::IntoResponse,
    http::HeaderMap,
};
use russh::{client, ChannelMsg, Disconnect};
use russh::keys::*;
use std::sync::Arc;
use crate::{AppState, auth, crypto};

pub(crate) struct Handler;
impl client::Handler for Handler {
    type Error = russh::Error;
    async fn check_server_key(&mut self, _key: &russh::keys::ssh_key::PublicKey)
        -> Result<bool, Self::Error> {
        // PROD: nên verify known_hosts. Demo: chấp nhận (TOFU bỏ qua).
        Ok(true)
    }
}

pub async fn ws_handler(
    ws: WebSocketUpgrade,
    State(s): State<AppState>,
    Path(host_id): Path<String>,
    headers: HeaderMap,
) -> impl IntoResponse {
    // Auth qua subprotocol: browser gửi token trong Sec-WebSocket-Protocol.
    let token = headers.get("sec-websocket-protocol")
        .and_then(|v| v.to_str().ok()).map(|s| s.to_string());
    // PHẢI echo lại subprotocol client đã gửi, nếu không browser sẽ fail handshake
    // ("Sent non-empty Sec-WebSocket-Protocol header but no response was received").
    let ws = match &token {
        Some(t) => ws.protocols([t.clone()]),
        None => ws,
    };
    ws.on_upgrade(move |socket| handle(socket, s, host_id, token))
}

async fn handle(mut socket: WebSocket, state: AppState, host_id: String, token: Option<String>) {
    let uid = match token.and_then(|t| auth::verify_token(&state.jwt_secret, &t)) {
        Some(u) => u,
        None => { let _ = socket.send(Message::Text("AUTH_FAILED".into())).await; return; }
    };

    // Lấy thông tin host + credential, giải mã.
    let conn = match load_host(&state, &uid, &host_id).await {
        Ok(c) => c,
        Err(e) => { let _ = socket.send(Message::Text(format!("ERR {e}"))).await; return; }
    };

    if let Err(e) = run_ssh(socket, conn).await {
        tracing::error!("ssh session error: {e}");
    }
}

pub(crate) struct HostConn {
    host: String, port: u16, username: String,
    password: Option<String>,
    private_key: Option<String>, passphrase: Option<String>,
}

pub(crate) async fn load_host(state: &AppState, uid: &str, host_id: &str) -> anyhow::Result<HostConn> {
    let db = state.db.lock().await;
    let (host, port, username, auth_type, pw_enc, key_id): (String,i64,String,String,Option<String>,Option<String>) =
        db.query_row(
            "SELECT host,port,username,auth_type,password_enc,key_id FROM hosts WHERE id=? AND user_id=?",
            rusqlite::params![host_id, uid],
            |r| Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?,r.get(4)?,r.get(5)?)))?;

    let mut c = HostConn {
        host, port: port as u16, username,
        password: None, private_key: None, passphrase: None,
    };
    if auth_type == "password" {
        if let Some(enc) = pw_enc {
            c.password = Some(crypto::decrypt(&state.master_key, &enc)?);
        }
    } else if auth_type == "key" {
        if let Some(kid) = key_id {
            let (priv_enc, pass_enc): (String, Option<String>) = db.query_row(
                "SELECT priv_enc,passphrase_enc FROM ssh_keys WHERE id=? AND user_id=?",
                rusqlite::params![kid, uid], |r| Ok((r.get(0)?, r.get(1)?)))?;
            c.private_key = Some(crypto::decrypt(&state.master_key, &priv_enc)?);
            if let Some(pe) = pass_enc {
                c.passphrase = Some(crypto::decrypt(&state.master_key, &pe)?);
            }
        }
    }
    Ok(c)
}

// Kết nối + xác thực SSH, trả session handle. Dùng chung cho shell (ssh) lẫn sftp.
pub(crate) async fn connect_session(c: &HostConn) -> anyhow::Result<client::Handle<Handler>> {
    let config = Arc::new(client::Config::default());
    let mut session = client::connect(config, (c.host.as_str(), c.port), Handler).await?;

    let authed = if let Some(pk) = &c.private_key {
        let key = decode_secret_key(pk, c.passphrase.as_deref())?;
        let hash = session.best_supported_rsa_hash().await?.flatten();
        session.authenticate_publickey(&c.username,
            russh::keys::PrivateKeyWithHashAlg::new(Arc::new(key), hash)).await?.success()
    } else if let Some(pw) = &c.password {
        session.authenticate_password(&c.username, pw).await?.success()
    } else {
        false
    };
    if !authed {
        anyhow::bail!("xác thực SSH thất bại");
    }
    Ok(session)
}

async fn run_ssh(mut socket: WebSocket, c: HostConn) -> anyhow::Result<()> {
    let session = match connect_session(&c).await {
        Ok(s) => s,
        Err(e) => {
            let _ = socket.send(Message::Text(format!("AUTH_FAILED (ssh): {e}"))).await;
            return Ok(());
        }
    };

    let mut channel = session.channel_open_session().await?;
    channel.request_pty(false, "xterm-256color", 80, 24, 0, 0, &[]).await?;
    channel.request_shell(true).await?;

    loop {
        tokio::select! {
            // Output từ SSH -> browser
            msg = channel.wait() => {
                match msg {
                    Some(ChannelMsg::Data { data }) => {
                        if socket.send(Message::Binary(data.to_vec())).await.is_err() { break; }
                    }
                    Some(ChannelMsg::ExtendedData { data, .. }) => {
                        if socket.send(Message::Binary(data.to_vec())).await.is_err() { break; }
                    }
                    Some(ChannelMsg::Eof) | Some(ChannelMsg::Close) | None => break,
                    _ => {}
                }
            }
            // Input từ browser -> SSH
            ws_msg = socket.recv() => {
                match ws_msg {
                    Some(Ok(Message::Text(t))) => {
                        if let Ok(v) = serde_json::from_str::<serde_json::Value>(&t) {
                            match v.get("t").and_then(|x| x.as_str()) {
                                Some("data") => {
                                    if let Some(d) = v.get("d").and_then(|x| x.as_str()) {
                                        channel.data(d.as_bytes()).await.ok();
                                    }
                                }
                                Some("resize") => {
                                    let cols = v.get("cols").and_then(|x| x.as_u64()).unwrap_or(80) as u32;
                                    let rows = v.get("rows").and_then(|x| x.as_u64()).unwrap_or(24) as u32;
                                    channel.window_change(cols, rows, 0, 0).await.ok();
                                }
                                _ => {}
                            }
                        }
                    }
                    Some(Ok(Message::Binary(b))) => { channel.data(&b[..]).await.ok(); }
                    Some(Ok(Message::Close(_))) | None | Some(Err(_)) => break,
                    _ => {}
                }
            }
        }
    }

    session.disconnect(Disconnect::ByApplication, "bye", "en").await.ok();
    Ok(())
}
