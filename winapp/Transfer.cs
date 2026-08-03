// Copy file/thư mục (đệ quy) giữa hai nguồn bất kỳ: máy↔server, server↔server, máy↔máy.
// Đọc–ghi theo chunk 256KB nên file lớn không nuốt hết RAM và báo được tiến độ.
using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;

namespace TreSSH
{
    public class TransferResult
    {
        public long Files;
        public long Bytes;
    }

    public static class Transfer
    {
        const int Chunk = 256 * 1024;

        /// Tổng dung lượng cây nguồn — làm mẫu số cho thanh tiến độ.
        public static long Measure(IFileSource src, string path)
        {
            long total = 0;
            var stack = new Stack<string>();
            stack.Push(path);
            while (stack.Count > 0)
            {
                var p = stack.Pop();
                if (src.IsDir(p))
                {
                    foreach (var e in src.List(p)) stack.Push(src.Combine(p, e.Name));
                }
                else
                {
                    try { total += src.FileSize(p); } catch { }
                }
            }
            return total;
        }

        /// Copy `srcPath` sang `dstDir/name`. progress(đã xong, tổng) gọi liên tục khi ghi.
        public static TransferResult Copy(
            IFileSource src, string srcPath,
            IFileSource dst, string dstDir, string name,
            long total, Action<long, long> progress, CancellationToken ct)
        {
            var res = new TransferResult();
            long done = 0;
            var buf = new byte[Chunk];

            var stack = new Stack<KeyValuePair<string, string>>();
            stack.Push(new KeyValuePair<string, string>(srcPath, dst.Combine(dstDir, name)));

            while (stack.Count > 0)
            {
                ct.ThrowIfCancellationRequested();
                var pair = stack.Pop();
                string sp = pair.Key, dp = pair.Value;

                if (src.IsDir(sp))
                {
                    if (!dst.Exists(dp)) dst.Mkdir(dp);
                    foreach (var e in src.List(sp))
                        stack.Push(new KeyValuePair<string, string>(src.Combine(sp, e.Name), dst.Combine(dp, e.Name)));
                    continue;
                }

                using (var rs = src.OpenRead(sp))
                using (var ws = dst.OpenWrite(dp))
                {
                    int n;
                    while ((n = rs.Read(buf, 0, buf.Length)) > 0)
                    {
                        ct.ThrowIfCancellationRequested();
                        ws.Write(buf, 0, n);
                        done += n;
                        res.Bytes += n;
                        if (progress != null) progress(done, Math.Max(total, done));
                    }
                }
                res.Files++;
            }
            return res;
        }

        public static string FormatSize(long n)
        {
            string[] u = { "B", "K", "M", "G", "T" };
            double x = n;
            int i = 0;
            while (x >= 1024 && i < u.Length - 1) { x /= 1024; i++; }
            return i == 0 ? ((long)x) + u[i] : x.ToString("0.0") + u[i];
        }
    }
}
