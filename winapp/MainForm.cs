// Cửa sổ chính: 2 khung duyệt file cạnh nhau + thanh tiến độ.
// Mỗi khung chọn "Máy này" hoặc một server → copy qua lại đủ 4 chiều.
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace TreSSH
{
    public class MainForm : Form
    {
        readonly PaneControl _left = new PaneControl();
        readonly PaneControl _right = new PaneControl();
        readonly ToolStripStatusLabel _status = new ToolStripStatusLabel("Sẵn sàng");
        readonly ToolStripProgressBar _progress = new ToolStripProgressBar { Visible = false, Width = 180 };
        List<HostInfo> _hosts;
        CancellationTokenSource _cts;

        public MainForm()
        {
            Text = "Tre SSH — 2 khung, kéo–thả copy";
            ClientSize = new Size(1080, 640);
            StartPosition = FormStartPosition.CenterScreen;

            _hosts = HostStore.Load();

            var menu = new MenuStrip();
            var mServer = new ToolStripMenuItem("&Server");
            var mManage = new ToolStripMenuItem("Quản lý server…", null, (s, e) => ManageHosts());
            var mQuit = new ToolStripMenuItem("Thoát", null, (s, e) => Close());
            mServer.DropDownItems.AddRange(new ToolStripItem[] { mManage, new ToolStripSeparator(), mQuit });
            var mHelp = new ToolStripMenuItem("&Trợ giúp", null, (s, e) => ShowHelp());
            menu.Items.AddRange(new ToolStripItem[] { mServer, mHelp });

            var split = new SplitContainer { Dock = DockStyle.Fill, SplitterDistance = 540 };
            split.Panel1.Controls.Add(_left);
            split.Panel2.Controls.Add(_right);

            var bar = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = 36, Padding = new Padding(6, 4, 6, 4) };
            var toRight = new Button { Text = "Copy  →", AutoSize = true };
            var toLeft = new Button { Text = "←  Copy", AutoSize = true };
            var cancel = new Button { Text = "Dừng", AutoSize = true, Enabled = false };
            toRight.Click += async (s, e) => await CopySelection(_left, _right, cancel);
            toLeft.Click += async (s, e) => await CopySelection(_right, _left, cancel);
            cancel.Click += (s, e) => { if (_cts != null) _cts.Cancel(); };
            bar.Controls.AddRange(new Control[] { toRight, toLeft, cancel });

            var strip = new StatusStrip();
            strip.Items.Add(_status);
            strip.Items.Add(_progress);

            foreach (var p in new[] { _left, _right })
            {
                p.Status += msg => _status.Text = msg;
                p.Dropped += async (pane, payload, destDir) => await CopyDropped(pane, payload, destDir, cancel);
                p.SetHosts(_hosts);
            }

            Controls.Add(split);
            Controls.Add(bar);
            Controls.Add(strip);
            Controls.Add(menu);
            MainMenuStrip = menu;
        }

        void ManageHosts()
        {
            using (var f = new HostsForm(_hosts))
            {
                f.ShowDialog(this);
                _hosts = f.Hosts;
            }
            _left.SetHosts(_hosts);
            _right.SetHosts(_hosts);
        }

        void ShowHelp()
        {
            MessageBox.Show(
                "1. Server → Quản lý server: thêm server (mật khẩu hoặc SSH key).\r\n" +
                "2. Mỗi khung chọn nguồn: \"Máy này\" hoặc một server.\r\n" +
                "3. Kéo file/thư mục từ khung này sang khung kia để copy — hoặc dùng nút Copy →.\r\n" +
                "   Thả lên một thư mục thì copy vào bên trong thư mục đó.\r\n" +
                "   Kéo thẳng file từ Explorer vào khung server cũng upload được.\r\n\r\n" +
                "Dữ liệu server lưu ở: " + HostStore.Dir + "\r\n" +
                "Mật khẩu mã hóa bằng DPAPI theo tài khoản Windows hiện tại.",
                "Hướng dẫn", MessageBoxButtons.OK, MessageBoxIcon.Information);
        }

        // Nút Copy →: lấy các mục đang chọn ở khung nguồn.
        async Task CopySelection(PaneControl from, PaneControl to, Button cancelBtn)
        {
            if (from.Source == null || to.Source == null) { _status.Text = "Chọn nguồn cho cả hai khung trước."; return; }
            var items = from.SelectedItems();
            if (items.Count == 0) { _status.Text = "Chọn file/thư mục cần copy ở khung nguồn."; return; }

            var payload = new DragPayload { From = from };
            foreach (var it in items)
            {
                payload.Paths.Add(from.Source.Combine(from.CurrentPath, it.Name));
                payload.Names.Add(it.Name);
            }
            await CopyDropped(to, payload, to.CurrentPath, cancelBtn);
        }

        // Copy thật: nguồn có thể là khung kia, hoặc file kéo từ Explorer (From == null → máy này).
        async Task CopyDropped(PaneControl to, DragPayload payload, string destDir, Button cancelBtn)
        {
            if (to.Source == null) return;
            if (to.Source.IsLocal && destDir == LocalSource.Drives)
            {
                _status.Text = "Mở một ổ đĩa/thư mục ở khung đích trước đã.";
                return;
            }

            IFileSource src = payload.From != null ? payload.From.Source : new LocalSource();
            bool disposeSrc = payload.From == null;
            IFileSource dst = to.Source;

            _cts = new CancellationTokenSource();
            cancelBtn.Enabled = true;
            _progress.Visible = true;
            _progress.Value = 0;

            var report = new Progress<string>(m => _status.Text = m);
            var pct = new Progress<int>(v => _progress.Value = Math.Max(0, Math.Min(100, v)));
            var ct = _cts.Token;
            var paths = payload.Paths;
            var names = payload.Names;

            try
            {
                var res = await Task.Run(() =>
                {
                    var all = new TransferResult();
                    for (int i = 0; i < paths.Count; i++)
                    {
                        ct.ThrowIfCancellationRequested();
                        string sp = paths[i], nm = names[i];
                        ((IProgress<string>)report).Report("⏳ Đang copy \"" + nm + "\"…");

                        long total = Transfer.Measure(src, sp);
                        var r = Transfer.Copy(src, sp, dst, destDir, nm, total, (done, tot) =>
                        {
                            if (tot > 0) ((IProgress<int>)pct).Report((int)(done * 100 / tot));
                            ((IProgress<string>)report).Report(
                                "⏳ \"" + nm + "\" — " + Transfer.FormatSize(done) + " / " + Transfer.FormatSize(tot));
                        }, ct);
                        all.Files += r.Files;
                        all.Bytes += r.Bytes;
                    }
                    return all;
                }, ct);

                _status.Text = "✓ Xong — " + res.Files + " tệp, " + Transfer.FormatSize(res.Bytes);
                await to.Reload();
            }
            catch (OperationCanceledException)
            {
                _status.Text = "Đã dừng theo yêu cầu.";
                await to.Reload();
            }
            catch (Exception ex)
            {
                _status.Text = "Lỗi copy: " + ex.Message;
                MessageBox.Show(ex.Message, "Lỗi copy", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
            finally
            {
                if (disposeSrc) src.Dispose();
                _progress.Visible = false;
                cancelBtn.Enabled = false;
                _cts.Dispose();
                _cts = null;
            }
        }
    }
}
