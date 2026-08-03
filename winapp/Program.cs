// Điểm vào. Trước khi chạy form, cắm handler nạp DLL phụ thuộc từ resource nhúng trong .exe
// (xem target NhungDll trong .csproj) — nhờ vậy phát hành chỉ một file TreSSH.exe.
using System;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

namespace TreSSH
{
    static class Program
    {
        [STAThread]
        static int Main(string[] args)
        {
            AppDomain.CurrentDomain.AssemblyResolve += ResolveEmbedded;

            // CI gọi `TreSSH.exe --selftest`: kiểm tra DLL nhúng nạp được, khỏi cần mở cửa sổ.
            if (args.Length > 0 && args[0] == "--selftest") return SelfTest();

            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.ThreadException += (s, e) => Report(e.Exception);
            AppDomain.CurrentDomain.UnhandledException += (s, e) => Report(e.ExceptionObject as Exception);

            Application.Run(new MainForm());
            return 0;
        }

        static int SelfTest()
        {
            try
            {
                var sftp = typeof(Renci.SshNet.SftpClient).FullName;
                var json = Newtonsoft.Json.JsonConvert.SerializeObject(new HostInfo());
                Console.WriteLine("OK " + sftp + " | hosts.json mẫu " + json.Length + " ký tự");
                return 0;
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine("SELFTEST FAIL: " + ex);
                return 1;
            }
        }

        static Assembly ResolveEmbedded(object sender, ResolveEventArgs args)
        {
            var name = new AssemblyName(args.Name).Name;
            using (var st = Assembly.GetExecutingAssembly().GetManifestResourceStream("dep." + name + ".dll"))
            {
                if (st == null) return null;
                var bytes = new byte[st.Length];
                st.Read(bytes, 0, bytes.Length);
                return Assembly.Load(bytes);
            }
        }

        static void Report(Exception ex)
        {
            if (ex == null) return;
            MessageBox.Show(ex.ToString(), "Lỗi không mong đợi", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }
}
