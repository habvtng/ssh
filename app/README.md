# tre360 SSH — app native macOS + iOS

App SwiftUI đa nền tảng (một target chạy cả macOS 15+ và iOS 17+). SSH/SFTP chạy
thẳng trên thiết bị bằng [Citadel](https://github.com/orlandos-nl/Citadel), terminal
bằng [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm). **Không cần backend Rust.**

## Tính năng

- Quản lý **host** (password / SSH key) — credential lưu trong **Keychain**.
- Quản lý **khóa SSH** (OpenSSH/PEM, hỗ trợ passphrase) — ed25519 + RSA.
- **Terminal** PTY tương tác (SwiftTerm).
- **Trình duyệt SFTP** cho từng host.
- Màn **2 Server**: duyệt file 2 server song song, **kéo–thả copy** file/thư mục
  (đệ quy) giữa hai server. iPad/Mac xếp cạnh nhau, iPhone xếp trên–dưới.

## Build / chạy

Cần Xcode 26+. Project sinh bằng [XcodeGen](https://github.com/yonaskolb/XcodeGen)
từ [project.yml](project.yml) — **đừng sửa `.xcodeproj` trực tiếp**, sửa `project.yml` rồi `xcodegen generate`.

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

> Lần đầu trên máy mới có thể cần: `xcodebuild -downloadComponent MetalToolchain`
> (SwiftTerm dùng shader Metal) và `xcodebuild -downloadPlatform iOS` (SDK/simulator iOS).

## Lưu ý bảo mật

- `hostKeyValidator: .acceptAnything()` (TOFU bỏ qua) — production nên verify known_hosts.
- Mọi credential nằm trong Keychain của thiết bị, không ghi plaintext ra đĩa.
