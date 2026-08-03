// Lưu danh sách server + credential vào %APPDATA%\TreSSH\hosts.json.
// Mật khẩu / passphrase mã hóa bằng DPAPI theo tài khoản Windows hiện tại
// (CurrentUser) — file chép sang máy khác hoặc user khác sẽ không giải mã được.
using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using Newtonsoft.Json;

namespace TreSSH
{
    public class HostInfo
    {
        public string Id = Guid.NewGuid().ToString("N");
        public string Label = "";
        public string Host = "";
        public int Port = 22;
        public string Username = "root";
        /// "password" hoặc "key"
        public string AuthType = "password";
        /// Mật khẩu đã mã hóa DPAPI (base64). Không bao giờ lưu plaintext.
        public string PasswordEnc = "";
        /// Đường dẫn tới file private key (OpenSSH/PEM) trên máy này.
        public string KeyPath = "";
        public string PassphraseEnc = "";

        public string Display
        {
            get { return string.IsNullOrEmpty(Label) ? Host : Label; }
        }
        public override string ToString() { return Display; }
    }

    public static class Secret
    {
        public static string Protect(string plain)
        {
            if (string.IsNullOrEmpty(plain)) return "";
            byte[] enc = ProtectedData.Protect(
                Encoding.UTF8.GetBytes(plain), null, DataProtectionScope.CurrentUser);
            return Convert.ToBase64String(enc);
        }

        public static string Unprotect(string enc)
        {
            if (string.IsNullOrEmpty(enc)) return "";
            try
            {
                byte[] plain = ProtectedData.Unprotect(
                    Convert.FromBase64String(enc), null, DataProtectionScope.CurrentUser);
                return Encoding.UTF8.GetString(plain);
            }
            catch
            {
                // Sai user Windows hoặc file bị chép từ máy khác → coi như chưa có mật khẩu.
                return "";
            }
        }
    }

    public static class HostStore
    {
        public static string Dir
        {
            get
            {
                return Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "TreSSH");
            }
        }
        static string File_ { get { return Path.Combine(Dir, "hosts.json"); } }

        public static List<HostInfo> Load()
        {
            try
            {
                if (!File.Exists(File_)) return new List<HostInfo>();
                var json = File.ReadAllText(File_, Encoding.UTF8);
                var list = JsonConvert.DeserializeObject<List<HostInfo>>(json);
                return list ?? new List<HostInfo>();
            }
            catch
            {
                return new List<HostInfo>();
            }
        }

        public static void Save(List<HostInfo> hosts)
        {
            Directory.CreateDirectory(Dir);
            File.WriteAllText(File_, JsonConvert.SerializeObject(hosts, Formatting.Indented), Encoding.UTF8);
        }
    }
}
