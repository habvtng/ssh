// Hai nguồn file dùng chung một giao diện: máy này (System.IO) và server (SFTP qua SSH.NET).
// Nhờ vậy màn 2 khung copy được đủ 4 chiều mà không cần viết 4 nhánh code.
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using Renci.SshNet;

namespace TreSSH
{
    public class FileItem
    {
        public string Name;
        public bool IsDir;
        public bool IsLink;
        public long Size;
    }

    public interface IFileSource : IDisposable
    {
        string Label { get; }
        bool IsLocal { get; }
        string Home();
        /// Rút gọn "..", "." thành đường dẫn tuyệt đối.
        string Canonical(string path);
        string Combine(string dir, string name);
        string Parent(string path);
        List<FileItem> List(string path);
        bool Exists(string path);
        bool IsDir(string path);
        long FileSize(string path);
        void Mkdir(string path);
        void Rename(string from, string to);
        void Delete(string path);
        Stream OpenRead(string path);
        Stream OpenWrite(string path);
    }

    // ---------- Máy này ----------
    // "@drives" là màn danh sách ổ đĩa (C:\, D:\…) — hiện ra khi đi lên trên gốc ổ đĩa.
    public class LocalSource : IFileSource
    {
        public const string Drives = "@drives";

        public string Label { get { return "Máy này"; } }
        public bool IsLocal { get { return true; } }
        public void Dispose() { }

        public string Home()
        {
            return Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        }

        public string Canonical(string path)
        {
            if (string.IsNullOrEmpty(path) || path == Drives) return Drives;
            try { return Path.GetFullPath(path); }
            catch { return Drives; }
        }

        public string Combine(string dir, string name)
        {
            if (dir == Drives) return name;             // hàng trong màn ổ đĩa đã là "C:\"
            return Path.Combine(dir, name);
        }

        public string Parent(string path)
        {
            if (path == Drives) return Drives;
            var root = Path.GetPathRoot(path);
            if (string.Equals(path.TrimEnd('\\'), (root ?? "").TrimEnd('\\'), StringComparison.OrdinalIgnoreCase))
                return Drives;                          // đang ở gốc ổ đĩa → về danh sách ổ đĩa
            var parent = Path.GetDirectoryName(path);
            return string.IsNullOrEmpty(parent) ? Drives : parent;
        }

        public List<FileItem> List(string path)
        {
            var outp = new List<FileItem>();
            if (path == Drives)
            {
                foreach (var d in DriveInfo.GetDrives())
                {
                    if (!d.IsReady) continue;
                    outp.Add(new FileItem { Name = d.Name, IsDir = true });
                }
                return outp;
            }

            var di = new DirectoryInfo(path);
            foreach (var sub in di.GetDirectories())
                outp.Add(new FileItem { Name = sub.Name, IsDir = true });
            foreach (var f in di.GetFiles())
                outp.Add(new FileItem { Name = f.Name, Size = f.Length });
            return outp;
        }

        public bool Exists(string path) { return File.Exists(path) || Directory.Exists(path); }
        public bool IsDir(string path) { return Directory.Exists(path); }
        public long FileSize(string path) { return new FileInfo(path).Length; }
        public void Mkdir(string path) { Directory.CreateDirectory(path); }
        public void Rename(string from, string to)
        {
            if (Directory.Exists(from)) Directory.Move(from, to);
            else File.Move(from, to);
        }
        public void Delete(string path)
        {
            if (Directory.Exists(path)) Directory.Delete(path, true);
            else File.Delete(path);
        }
        public Stream OpenRead(string path) { return File.OpenRead(path); }
        public Stream OpenWrite(string path) { return File.Create(path); }
    }

    // ---------- Server (SFTP) ----------
    public class SftpSource : IFileSource
    {
        readonly SftpClient _c;
        readonly string _label;

        public string Label { get { return _label; } }
        public bool IsLocal { get { return false; } }

        public SftpSource(HostInfo h)
        {
            _label = h.Display;
            _c = new SftpClient(BuildConnection(h));
            _c.Connect();
        }

        // Xác thực: mật khẩu, hoặc private key (có/không passphrase).
        static ConnectionInfo BuildConnection(HostInfo h)
        {
            AuthenticationMethod auth;
            if (h.AuthType == "key")
            {
                var pass = Secret.Unprotect(h.PassphraseEnc);
                var key = string.IsNullOrEmpty(pass)
                    ? new PrivateKeyFile(h.KeyPath)
                    : new PrivateKeyFile(h.KeyPath, pass);
                auth = new PrivateKeyAuthenticationMethod(h.Username, key);
            }
            else
            {
                auth = new PasswordAuthenticationMethod(h.Username, Secret.Unprotect(h.PasswordEnc));
            }
            return new ConnectionInfo(h.Host, h.Port <= 0 ? 22 : h.Port, h.Username, auth);
        }

        public void Dispose()
        {
            try { if (_c.IsConnected) _c.Disconnect(); } catch { }
            _c.Dispose();
        }

        public string Home() { return _c.WorkingDirectory; }

        public string Canonical(string path)
        {
            if (string.IsNullOrEmpty(path) || path == ".") return _c.WorkingDirectory;
            // ChangeDirectory tự rút gọn ".." rồi WorkingDirectory trả về đường tuyệt đối.
            var keep = _c.WorkingDirectory;
            try
            {
                _c.ChangeDirectory(path);
                var abs = _c.WorkingDirectory;
                _c.ChangeDirectory(keep);
                return abs;
            }
            catch
            {
                return path;
            }
        }

        public string Combine(string dir, string name)
        {
            if (string.IsNullOrEmpty(dir) || dir == "/") return "/" + name;
            return dir.TrimEnd('/') + "/" + name;
        }

        public string Parent(string path)
        {
            if (string.IsNullOrEmpty(path) || path == "/") return "/";
            var p = path.TrimEnd('/');
            int i = p.LastIndexOf('/');
            if (i <= 0) return "/";
            return p.Substring(0, i);
        }

        public List<FileItem> List(string path)
        {
            var outp = new List<FileItem>();
            foreach (var f in _c.ListDirectory(path))
            {
                if (f.Name == "." || f.Name == "..") continue;
                outp.Add(new FileItem
                {
                    Name = f.Name,
                    IsDir = f.IsDirectory,
                    IsLink = f.IsSymbolicLink,
                    Size = f.IsDirectory ? 0 : f.Length
                });
            }
            return outp;
        }

        public bool Exists(string path) { return _c.Exists(path); }
        public bool IsDir(string path) { return _c.Get(path).IsDirectory; }
        public long FileSize(string path) { return _c.Get(path).Length; }
        public void Mkdir(string path) { _c.CreateDirectory(path); }
        public void Rename(string from, string to) { _c.RenameFile(from, to); }

        public void Delete(string path)
        {
            var f = _c.Get(path);
            if (!f.IsDirectory) { _c.DeleteFile(path); return; }
            // Xóa đệ quy: dọn hết bên trong rồi mới rmdir.
            foreach (var e in _c.ListDirectory(path))
            {
                if (e.Name == "." || e.Name == "..") continue;
                Delete(Combine(path, e.Name));
            }
            _c.DeleteDirectory(path);
        }

        public Stream OpenRead(string path) { return _c.OpenRead(path); }
        public Stream OpenWrite(string path) { return _c.Create(path); }
    }

    // Sắp xếp hiển thị: thư mục trước, rồi theo tên (không phân biệt hoa thường).
    public static class FileItemSort
    {
        public static List<FileItem> Sorted(this List<FileItem> items)
        {
            return items
                .OrderByDescending(x => x.IsDir)
                .ThenBy(x => x.Name, StringComparer.OrdinalIgnoreCase)
                .ToList();
        }
    }
}
