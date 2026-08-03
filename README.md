# Tre SSH

Ba cách dùng cùng một bộ tính năng SSH/SFTP:

- **App native macOS + iOS** — SwiftUI, SSH chạy thẳng trên thiết bị, không cần backend. Xem [`app/`](app/).
- **App desktop Windows (Tauri)** — vỏ Tauri bọc frontend + nhúng luôn backend Rust vào **một file `.exe`**. Cần WebView2 nên hợp với Windows 10/11. Xem [`desktop/`](desktop/).
- **App Windows đời cũ (C# WinForms)** — 1.7 MB, chạy bằng .NET Framework 4.5 có sẵn trong Windows 8/Server 2012, không WebView2. Xem [`winapp/`](winapp/).
- **Web SSH client** — chạy trên trình duyệt, backend Rust làm cầu nối. Xem phần dưới.

---

# App native macOS + iOS

App SwiftUI đa nền tảng (một target chạy cả **macOS 15+** và **iOS 17+**). SSH/SFTP chạy thẳng trên thiết bị bằng [Citadel](https://github.com/orlandos-nl/Citadel), terminal bằng [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm). **Không cần backend Rust.**

## Tính năng

- Quản lý **host** (password / SSH key) — credential lưu trong **Keychain**.
- Quản lý **khóa SSH** (OpenSSH/PEM, hỗ trợ passphrase) — ed25519 + RSA.
- **Terminal** PTY tương tác (SwiftTerm).
- **Trình duyệt SFTP** cho từng host.
- Màn **2 Server**: duyệt file 2 server song song, **kéo–thả copy** file/thư mục (đệ quy) giữa hai server. iPad/Mac xếp cạnh nhau, iPhone xếp trên–dưới.

## Build / chạy

Cần Xcode 26+. Project sinh bằng [XcodeGen](https://github.com/yonaskolb/XcodeGen) từ [`app/project.yml`](app/project.yml) — **đừng sửa `.xcodeproj` trực tiếp**, sửa `project.yml` rồi `xcodegen generate`.

```bash
brew install xcodegen        # nếu chưa có
cd app
xcodegen generate            # sinh Tre360SSH.xcodeproj
open Tre360SSH.xcodeproj      # rồi chọn scheme + Run trong Xcode
```

Build/kiểm bằng dòng lệnh:

```bash
# macOS
xcodebuild -project Tre360SSH.xcodeproj -scheme Tre360SSH \
  -destination 'platform=macOS' build

# iOS simulator
xcodebuild -project Tre360SSH.xcodeproj -scheme Tre360SSH \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
```

> Lần đầu trên máy mới có thể cần: `xcodebuild -downloadComponent MetalToolchain` (SwiftTerm dùng shader Metal) và `xcodebuild -downloadPlatform iOS` (SDK/simulator iOS).

Chi tiết: [`app/README.md`](app/README.md).

---

# App desktop Windows (Tauri)

App SwiftUI ở trên chỉ chạy được trên Apple. Bản Windows là app **Tauri** ở [`desktop/`](desktop/):
cửa sổ WebView2 hiển thị đúng frontend của bản web, còn backend axum (crate `ssh-web`) chạy nhúng
ngay trong tiến trình app ở `127.0.0.1` với port trống ngẫu nhiên → **một file `.exe`**, không Docker,
không mở trình duyệt. Dữ liệu nằm ở `%APPDATA%\vn.tre360.ssh.desktop\`.

Tauri không cross-compile sang Windows từ macOS, nên build bằng **GitHub Actions**
([`.github/workflows/windows-desktop.yml`](.github/workflows/windows-desktop.yml): Actions → *Windows
desktop* → Run workflow, hoặc push tag `v*` để ra Releases), hoặc chạy trên máy Windows:

```powershell
cargo install tauri-cli --version "^2" --locked
cd desktop\src-tauri
cargo tauri build      # → Tre SSH.exe + bundle\msi\*.msi + bundle\nsis\*-setup.exe
```

Chi tiết: [`desktop/README.md`](desktop/README.md).

---

# Web SSH Client

SSH client chạy trên trình duyệt (như Termius), kiểu **web app thật**: vào bằng URL từ bất kỳ đâu, không cài đặt. Backend Rust làm cầu nối `browser ⟷ WebSocket ⟷ SSH`.

## Kiến trúc

```
Browser (xterm.js)
   │  HTTPS  (REST: hosts/keys/snippets/tunnels)
   │  WSS    (/ws/ssh/:host_id  — stream PTY 2 chiều)
   ▼
axum server (Rust)
   ├─ russh        → kết nối SSH tới host đích, mở PTY shell
   ├─ rusqlite     → lưu hosts / keys / snippets / tunnels
   ├─ AES-256-GCM  → mã hóa credentials trước khi lưu DB
   └─ JWT + argon2 → auth người dùng
   ▼
Host SSH đích (10.0.0.12, v.v.)
```

## Tính năng

- **Quản lý host** — host/port/user, auth bằng password hoặc SSH key
- **Terminal** — multi-tab, full PTY, resize tự động (xterm.js)
- **Key management** — lưu private key (PEM) đã mã hóa, dùng lại cho nhiều host
- **Snippets** — lệnh hay dùng, click 1 phát chèn vào shell đang mở
- **Port forward** — local / remote / dynamic (khung quản lý tunnel)
- **Bảo mật** — credentials mã hóa AES-256-GCM bằng `MASTER_KEY`; password user hash argon2; session JWT

## Build & chạy (Docker)

```bash
# 1. Tạo secrets
cat > .env << EOF
MASTER_KEY=$(openssl rand -base64 32)
JWT_SECRET=$(openssl rand -base64 48)
EOF

# 2. Build + run
docker compose up -d --build

# 3. Mở http://localhost:8080 — đăng ký tài khoản đầu tiên
```

> ⚠️ Giữ `MASTER_KEY` cố định. Đổi key = không giải mã được credentials đã lưu.

## Build thủ công (không Docker)

```bash
cd backend
cargo build --release
cp -r ../frontend ./static
MASTER_KEY=$(openssl rand -base64 32) JWT_SECRET=$(openssl rand -base64 48) \
  ./target/release/ssh-web
```

## Deploy dưới tre360.vn (Nginx + Cloudflare)

Reverse proxy cần bật WebSocket upgrade:

```nginx
location / {
    proxy_pass http://127.0.0.1:8080;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
    proxy_read_timeout 86400;   # giữ phiên SSH lâu
}
```

Subdomain gợi ý: `ssh.tre360.vn`. Trên Cloudflare bật proxy + WebSocket (mặc định on).

## Cảnh báo bảo mật (đọc trước khi đưa ra Internet)

1. **Server giữ được key giải mã** — `MASTER_KEY` nằm trên server, ai có quyền root container có thể giải mã credentials. Đây là đánh đổi cố hữu của mọi web SSH client. Cân nhắc giới hạn truy cập (Cloudflare Access / mTLS / VPN-only).
2. **Host key verification đang ở chế độ TOFU bỏ qua** (`check_server_key` luôn `Ok(true)`). Production nên lưu & verify known_hosts để chống MITM. Xem `ssh.rs`.
3. **Đặt sau lớp auth mạng** — đừng phơi `ssh.tre360.vn` trần ra Internet; thêm Cloudflare Access hoặc IP allowlist.
4. Tunnel manager (`tunnel.rs`) hiện là khung — phần nối listener TCP với russh `channel_open_direct_tcpip` cần hoàn thiện khi triển khai port-forward thực tế.

## Cấu trúc

```
ssh-web/
├─ backend/
│  ├─ Cargo.toml
│  └─ src/
│     ├─ main.rs      # routes, server
│     ├─ db.rs        # schema sqlite
│     ├─ crypto.rs    # AES-256-GCM
│     ├─ auth.rs      # JWT + argon2 + extractor
│     ├─ api.rs       # REST handlers
│     ├─ ssh.rs       # WebSocket ⟷ SSH bridge (russh PTY)
│     └─ tunnel.rs    # port-forward manager (khung)
├─ frontend/
│  └─ index.html      # SPA: xterm.js + UI quản lý
├─ Dockerfile
├─ docker-compose.yml
└─ README.md
```

## Còn thiếu để bằng Termius (roadmap)

- SFTP file browser (russh-sftp — thêm route `/ws/sftp/:id` + UI cây thư mục)
- Hoàn thiện port-forward runtime + auto-start tunnel khi mở host
- known_hosts verification UI (chấp nhận/ghi nhớ fingerprint)
- Split-pane terminal, theme tùy biến
- Đồng bộ nhiều thiết bị (đã sẵn nền vì state nằm server-side)
