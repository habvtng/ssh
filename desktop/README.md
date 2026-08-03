# Tre SSH — bản desktop Windows (Tauri)

App desktop đóng gói **frontend + backend Rust vào một tiến trình duy nhất**:

```
Tre SSH.exe
 ├─ WebView2 (cửa sổ app)  →  http://127.0.0.1:<port trống>
 └─ axum (crate ssh-web)   →  /api/*, /ws/ssh/:id  + frontend nhúng sẵn trong binary
                              SSH/SFTP tới server đích bằng russh
```

Không cần Docker, không cần cài Rust, không phải mở trình duyệt. Người dùng chỉ chạy 1 file.

> App native **Tre SSH (macOS/iOS)** trong `app/` là SwiftUI nên **không** build cho Windows được —
> bản Windows là app Tauri này, dùng chung backend Rust với bản web.

## Dữ liệu người dùng

| Thứ | Đường dẫn Windows |
|---|---|
| DB (user/host/key/snippet) | `%APPDATA%\vn.tre360.ssh.desktop\data.sqlite` |
| Khóa mã hóa + JWT secret | `%APPDATA%\vn.tre360.ssh.desktop\secrets.txt` |

`secrets.txt` sinh ngẫu nhiên lần chạy đầu. **Xóa/đổi file này = mất quyền giải mã** mật khẩu và
SSH key đã lưu trong `data.sqlite` (tài khoản đăng nhập vẫn còn nhưng credential host thì hỏng).
Muốn chuyển máy: copy **cả hai** file sang máy mới.

Server chỉ bind `127.0.0.1` với port trống ngẫu nhiên → máy khác trong LAN không truy cập được.

## Build

Tauri **không cross-compile** sang Windows từ macOS/Linux (cần MSVC + WebView2 SDK), nên có 2 đường:

### 1. GitHub Actions (không cần máy Windows)

Workflow [`.github/workflows/windows-desktop.yml`](../.github/workflows/windows-desktop.yml):

- Bấm tay: tab **Actions → Windows desktop → Run workflow** → tải artifact `tre-ssh-windows`.
- Hoặc push tag `v*` (`git tag v1.0.0 && git push origin v1.0.0`) → build xong tự đưa `.msi` +
  `-setup.exe` lên **Releases**.

### 2. Trên máy Windows

Cần: [Rust](https://rustup.rs) (MSVC toolchain), **Visual Studio Build Tools** (C++ desktop),
**WebView2 Runtime** (Windows 11 có sẵn).

```powershell
cargo install tauri-cli --version "^2" --locked
cd desktop\src-tauri
cargo tauri build
```

Kết quả:

| File | Dùng để |
|---|---|
| `target\release\tre-ssh-desktop.exe` | bản portable, chạy thẳng không cần cài (bộ cài mới đổi tên thành `Tre SSH.exe`) |
| `target\release\bundle\msi\*.msi` | bộ cài MSI |
| `target\release\bundle\nsis\*-setup.exe` | bộ cài NSIS (cài cho user hiện tại, không cần quyền admin) |

Chạy thử lúc phát triển: `cargo tauri dev`.

## Ghi chú kỹ thuật

- `backend/src/lib.rs` là phần dùng chung: `build_api_router` (REST + WebSocket, không kèm static),
  `build_state_parts`, `bind_router`. Bin `ssh-web` (bản Docker) và app desktop đều gọi vào đây —
  sửa route thì cả hai bản đều được, đừng thêm route riêng ở một bên.
- Frontend nhúng bằng `include_dir!` lúc compile (`desktop/src-tauri/src/main.rs`), phục vụ qua
  `fallback(serve_embedded)`. Sửa `frontend/index.html` xong phải **build lại** app mới thấy đổi.
- Cửa sổ trỏ vào `http://127.0.0.1:<port>` (`WebviewUrl::External`) nên frontend chạy y hệt bản web,
  không cần đổi `const API = '/api'` hay cơ chế WebSocket subprotocol.
