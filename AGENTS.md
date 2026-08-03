# AGENTS.md — tre360 SSH (Web SSH Client)

Hướng dẫn cho coding agent làm việc trên dự án này. Đọc kỹ phần "Trạng thái hiện tại" trước khi build.

## Dự án là gì

Web SSH client (kiểu Termius) chạy trên trình duyệt. Backend Rust làm cầu nối
`browser ⟷ WebSocket ⟷ SSH`. Người dùng quản lý host/key/snippet/tunnel qua REST,
mở terminal qua WebSocket. Chi tiết kiến trúc & tính năng: xem [README.md](README.md).

```
Browser (xterm.js)  ──HTTPS REST──┐
                    ──WSS PTY─────┤
                                  ▼
              axum server (Rust)
                ├─ russh       → SSH tới host đích, PTY shell
                ├─ rusqlite    → hosts / keys / snippets / tunnels
                ├─ AES-256-GCM → mã hóa credentials trước khi lưu DB
                └─ JWT+argon2  → auth người dùng
```

## Cấu trúc thư mục

```
ssh/
├─ backend/
│  ├─ Cargo.toml          # deps + resolver v3 + rust-version 1.88
│  └─ src/
│     ├─ lib.rs           # AppState + routes + serve() — DÙNG CHUNG cho bin và app desktop
│     ├─ main.rs          # bin ssh-web: đọc ENV (BIND/DB_PATH/STATIC_DIR) rồi gọi lib::serve
│     ├─ api.rs           # REST handlers (auth/hosts/keys/snippets/tunnels)
│     ├─ ssh.rs           # WebSocket ⟷ SSH bridge (russh PTY) + connect_session dùng chung
│     ├─ sftp.rs          # SFTP browser: /api/sftp/list + /api/sftp/read (russh-sftp)
│     ├─ localfs.rs       # /api/local/* — duyệt file MÁY CHẠY BACKEND (chỉ bật ở app desktop)
│     ├─ db.rs            # schema sqlite + now()
│     ├─ crypto.rs        # AES-256-GCM + master key
│     ├─ auth.rs          # JWT + argon2 + AuthUser extractor
│     └─ tunnel.rs        # port-forward manager (KHUNG — chưa nối runtime)
├─ frontend/
│  └─ index.html          # SPA: xterm.js + UI quản lý
├─ desktop/src-tauri/     # app desktop Windows (Tauri v2) — nhúng frontend + lib ssh-web vào 1 .exe
│  ├─ src/main.rs         # bind 127.0.0.1:0 → mở WebviewWindow trỏ vào port đó
│  └─ tauri.conf.json     # bundle targets: nsis + msi
├─ app/                   # app native macOS/iOS (SwiftUI) — không liên quan backend Rust
├─ Dockerfile             # multi-stage: rust:1.88-slim-bookworm build → debian:bookworm-slim
├─ docker-compose.yml     # service ssh-web, cổng 8080, volume ./data
├─ .env                   # MASTER_KEY + JWT_SECRET (KHÔNG commit)
└─ README.md
```

> Dockerfile build từ root context: `COPY backend/Cargo.toml`, `COPY backend/src`,
> `COPY frontend`. Binary tên `ssh-web`, frontend served từ `/app/static`.

## Trạng thái hiện tại — build & chạy OK

Đủ 7 file nguồn + Cargo.toml. `docker compose build` compile sạch, container lên,
phục vụ SPA ở `/`, REST ở `/api/*`; đã smoke-test register / login / auth-guard chạy đúng.

Mỗi file module cung cấp đúng hợp đồng API mà `api.rs`/`ssh.rs`/`main.rs` gọi —
**đừng đổi tên/đối số** nếu không phải sửa lan ra nhiều chỗ:

| File | Hợp đồng API |
|---|---|
| `db.rs` | `init_db(path:&str) -> rusqlite::Result<Connection>` (bảng `users, hosts, ssh_keys, snippets, tunnels`); `now() -> i64`. |
| `crypto.rs` | `load_or_create_master_key() -> anyhow::Result<[u8;32]>` (đọc `MASTER_KEY` base64 ENV); `encrypt/decrypt(&[u8;32], &str) -> anyhow::Result<String>`. AES-256-GCM, format `base64(nonce‖ct)`. |
| `auth.rs` | `hash_pw(&str)->Result<String,String>`; `verify_pw(&str,&str)->bool`; `make_token/verify_token`; extractor `AuthUser(pub String)` đọc `Authorization: Bearer`. argon2 + jsonwebtoken. |
| `sftp.rs` | `list` (duyệt thư mục, canonicalize, dirs-first) + `read` (xem file ≤1MB, text/base64). Dùng `ssh::load_host` + `ssh::connect_session` rồi mở subsystem `sftp` qua russh-sftp 2.3. |
| `tunnel.rs` | Khung port-forward — `start()` mới là TODO, chưa bind listener. |
| `localfs.rs` | `/api/local/{list,mkdir,rename,delete,copy,upload,download}` + `/api/capabilities`. Chỉ mount khi `ServerConfig.local_fs` bật (app desktop = true, bin `ssh-web` = ENV `LOCAL_FS=1`, **mặc định tắt**). ⚠ Bật ở bản web hosted = client duyệt được ổ đĩa máy chủ. |
| `lib.rs` | `AppState`; `build_api_router(state)` (REST + WS, không static); `build_router(state,&Path)` (thêm ServeDir); `build_state_parts(&Path,[u8;32],String)`; `bind_router(&str,Router)->(SocketAddr,fut)`; `serve(ServerConfig)`. **App desktop Tauri gọi thẳng các hàm này** — thêm route mới thì thêm trong `build_api_router` để cả 2 bản cùng có. |

> **Persistence:** DB ghi vào `data/data.sqlite` (mặc định, đổi bằng `DB_PATH`) — nằm trong
> volume `/app/data` nên **không mất khi rebuild**. Đừng đổi về `data.sqlite` trần (ghi vào
> lớp container, mất sạch user/host mỗi lần `--build`).

### ⚠️ Bẫy về version (đã xử lý — đừng lặp lại)

- **Đừng hạ base image về `rust:1.82`.** Dep phụ (`time`, `home`) đã đòi rustc **1.88**.
  Dockerfile dùng `rust:1.88-slim-bookworm` — giữ biến thể **bookworm** để glibc khớp
  stage runtime `debian:bookworm-slim` (nhảy lên trixie → binary không chạy được).
- **Cargo.toml bật `resolver = "3"` (MSRV-aware)** để cargo chọn version crate tương thích
  `rust-version`, tránh kéo bản mới nhất rồi đòi Rust cao hơn base. Đừng gỡ.
- **`russh = "0.61"`** (MSRV 1.85). `ssh.rs` dùng API mới: `AuthResult.success()`,
  `PrivateKeyWithHashAlg`, `best_supported_rsa_hash`, `keys::ssh_key`. **Không hạ về 0.46**
  (API cũ trả `bool`, không có các symbol này → compile fail).
- **xterm đóng gói local ở `frontend/vendor/`** (xterm.js + css + addon-fit), nạp qua
  `/vendor/...`. **Đừng trỏ lại CDN cdnjs** — URL `xterm/5.3.0/*.min.js` trên cdnjs trả 404,
  làm `Terminal` undefined → click host không mở được terminal.
- **WS auth qua subprotocol:** `ws_handler` PHẢI echo lại `Sec-WebSocket-Protocol` client gửi
  (`ws.protocols([token])`), nếu không browser fail handshake → terminal không gõ được.

## Build & chạy

```bash
# Từ thư mục root (chỗ có Dockerfile)
# .env đã tồn tại; nếu cần tạo lại:
cat > .env << EOF
MASTER_KEY=$(openssl rand -base64 32)
JWT_SECRET=$(openssl rand -base64 48)
EOF

docker compose up -d --build      # → http://localhost:8080
```

Build thủ công không Docker:

```bash
cd backend
cargo build --release
cp -r ../frontend ./static        # main.rs serve ServeDir::new("static")
MASTER_KEY=$(openssl rand -base64 32) JWT_SECRET=$(openssl rand -base64 48) \
  ./target/release/ssh-web        # mặc định BIND=0.0.0.0:8080
```

## Quy ước & ràng buộc khi sửa code

- **MASTER_KEY là vĩnh viễn.** Đổi key = không giải mã được credentials đã lưu trong DB.
  Mọi thay đổi format encrypt/decrypt phải tính tới dữ liệu cũ.
- **Mọi credential (password host, private key, passphrase) phải mã hóa trước khi vào DB.**
  Không bao giờ lưu plaintext. Xem cách `api.rs` gọi `crypto::encrypt`.
- **Auth bằng JWT Bearer** cho REST; WebSocket lấy token qua `sec-websocket-protocol` header
  (xem `ssh.rs::ws_handler`). Giữ nguyên cơ chế này.
- **Đa tenant theo `user_id`.** Mọi query host/key/snippet/tunnel đều phải kèm
  `WHERE ... user_id=?` — đừng bỏ điều kiện này (rò rỉ dữ liệu giữa user).
- **russh API nhạy version.** `ssh.rs` dùng `PrivateKeyWithHashAlg`, `best_supported_rsa_hash`,
  `russh::keys::ssh_key::PublicKey`, native async trait `Handler` (không `#[async_trait]`).
  Khi đổi version trong Cargo.toml phải khớp các API này (russh ≥ 0.50; hiện pin 0.61).
- **Comment & UI tiếng Việt.** Giữ phong cách hiện có khi thêm code.

## Bảo mật — lưu ý trước khi đưa ra Internet

- `check_server_key` đang luôn `Ok(true)` (TOFU bỏ qua) → production nên verify known_hosts.
- Server giữ `MASTER_KEY` nên root container giải mã được credentials → đặt sau Cloudflare
  Access / mTLS / VPN, đừng phơi trần.
- Tunnel manager mới là khung, chưa nối listener TCP với russh `channel_open_direct_tcpip`.

Chi tiết đầy đủ: phần "Cảnh báo bảo mật" trong [README.md](README.md).

## Kiểm tra trước khi báo "xong"

- `docker compose build` compile sạch (hoặc `cargo build --release` trong `backend/`).
- `docker compose up -d` lên được, log có `Listening on 0.0.0.0:8080`, mở
  `http://localhost:8080` thấy SPA.
- Đăng ký tài khoản đầu, thêm host, mở terminal → gõ được lệnh qua WS.
- Không log/echo plaintext credentials hay token ra stdout.

## Quy ước giao tiếp

- Luôn gọi người dùng là **"Bố"**, agent xưng **"con"**. Bố sẽ chỉ cho con cách làm việc hiệu quả hơn.
- Luôn trả lời bằng **tiếng Việt**.
