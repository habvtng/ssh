# Tre SSH — bản Windows viết riêng bằng C# (WinForms)

Dành cho **Windows đời cũ** (Windows 8 / Server 2012 trở lên), nơi bản Tauri không chạy được:

| | Bản Tauri (`desktop/`) | Bản C# này (`winapp/`) |
|---|---|---|
| Giao diện | WebView2 (Edge) | WinForms — vẽ bằng Win32 có sẵn |
| Runtime cần có | WebView2 Runtime + UCRT | **.NET Framework 4.5 — có sẵn trong Windows 8/Server 2012** |
| Kích thước | ~416 MB (kèm WebView2 offline) | **1.7 MB, một file .exe** |
| Tính năng | đủ (kèm terminal SSH) | quản lý server + duyệt/copy file (SFTP). **Chưa có terminal** |

Không cần cài đặt: chép `TreSSH.exe` vào máy rồi chạy.

## Dùng thế nào

1. **Server → Quản lý server**: thêm server (mật khẩu hoặc file private key + passphrase).
2. Mỗi khung (trái/phải) chọn nguồn: **Máy này** hoặc một server.
3. **Kéo–thả** file/thư mục từ khung này sang khung kia để copy — hoặc chọn rồi bấm `Copy →`.
   - Thả lên một thư mục trong danh sách = copy vào bên trong thư mục đó.
   - Kéo thẳng file/thư mục **từ Explorer** vào khung server cũng upload được.
4. Nút `Dừng` hủy giữa chừng; thanh dưới cùng hiện tiến độ (đã copy / tổng, %).

Copy thư mục là đệ quy, đọc–ghi theo chunk 256 KB nên file lớn không ngốn RAM.

Đi lên quá gốc ổ đĩa (`C:\`) thì khung hiện **danh sách ổ đĩa** để chọn ổ khác.

## Dữ liệu

`%APPDATA%\TreSSH\hosts.json` — danh sách server. Mật khẩu và passphrase mã hóa bằng **DPAPI**
theo tài khoản Windows đang đăng nhập: chép file sang máy khác hoặc user khác thì phần mật khẩu
không giải mã được (phải nhập lại), các thông tin còn lại vẫn dùng được.

## Build

Cần .NET SDK (bản nào cũng được, ≥ 6). Build được **cả trên macOS/Linux** vì reference assemblies
của .NET Framework lấy từ NuGet:

```bash
cd winapp
dotnet build -c Release        # → bin/Release/net45/TreSSH.exe
```

CI: [`.github/workflows/windows-csharp.yml`](../.github/workflows/windows-csharp.yml) build trên
`windows-latest`, tự kiểm tra `.exe` chạy độc lập (`--selftest`) rồi đưa lên artifact
`tre-ssh-winforms`; push tag `v*` thì lên Releases.

## Ghi chú kỹ thuật

- `TargetFramework=net45` là **cố ý** — đó là bản .NET Framework in-box của Windows 8/Server 2012.
  Nâng lên net462/net48 là máy đời đó phải cài thêm runtime, đúng cái bẫy đang muốn tránh.
- `SSH.NET 2020.0.2` là bản cuối còn asset `net40` (chạy được trên 4.5). Bản mới hơn đòi net462.
- Hai DLL phụ thuộc được **nhúng vào .exe** (target `NhungDll` trong `.csproj`) và nạp lại lúc chạy
  bằng `AppDomain.AssemblyResolve` (xem `Program.cs`) → phát hành đúng một file.
- Kiến trúc: `IFileSource` (trong `FileSources.cs`) có 2 hiện thực `LocalSource` / `SftpSource`,
  nên `Transfer.Copy` chỉ viết một lần mà chạy đủ 4 chiều máy↔server, server↔server, máy↔máy.
- Chưa có terminal SSH. Muốn thêm thì cần `ShellStream` của SSH.NET + một control terminal biết
  parse escape sequence VT — đó là phần việc lớn, để đợt sau.
