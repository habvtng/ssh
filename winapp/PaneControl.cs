// Một khung duyệt file: chọn nguồn (Máy này / server) + thanh nút + danh sách file.
// Kéo–thả: kéo hàng từ khung này sang khung kia để copy; kéo file từ Explorer vào cũng được.
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Linq;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace TreSSH
{
    // Dữ liệu kéo giữa 2 khung trong app.
    public class DragPayload
    {
        public PaneControl From;
        public List<string> Paths = new List<string>();
        public List<string> Names = new List<string>();
    }

    public class PaneControl : UserControl
    {
        readonly ComboBox _cbo = new ComboBox();
        readonly Button _btnUp = new Button();
        readonly Button _btnReload = new Button();
        readonly Button _btnMkdir = new Button();
        readonly Button _btnRename = new Button();
        readonly Button _btnDelete = new Button();
        readonly TextBox _txtPath = new TextBox();
        readonly ListView _lv = new ListView();

        public IFileSource Source { get; private set; }
        public string CurrentPath { get; private set; }

        /// Báo trạng thái ra thanh dưới cùng của cửa sổ.
        public event Action<string> Status;
        /// Có mục được thả vào khung này (kéo từ khung kia, hoặc từ Explorer).
        public event Action<PaneControl, DragPayload, string> Dropped;

        public PaneControl()
        {
            Dock = DockStyle.Fill;

            var bar = new FlowLayoutPanel { Dock = DockStyle.Top, Height = 30, WrapContents = false, Padding = new Padding(2) };
            _cbo.DropDownStyle = ComboBoxStyle.DropDownList;
            _cbo.Width = 180;
            _cbo.SelectedIndexChanged += async (s, e) => await OnSourceChanged();
            InitBtn(_btnUp, "⬆", "Thư mục cha", async (s, e) => await Up());
            InitBtn(_btnReload, "⟳", "Tải lại", async (s, e) => await Reload());
            InitBtn(_btnMkdir, "Thư mục mới", "Tạo thư mục", async (s, e) => await Mkdir());
            InitBtn(_btnRename, "Đổi tên", "Đổi tên mục đang chọn", async (s, e) => await Rename());
            InitBtn(_btnDelete, "Xóa", "Xóa mục đang chọn", async (s, e) => await DeleteSel());
            bar.Controls.AddRange(new Control[] { _cbo, _btnUp, _btnReload, _btnMkdir, _btnRename, _btnDelete });

            _txtPath.Dock = DockStyle.Top;
            _txtPath.ReadOnly = true;
            _txtPath.BackColor = SystemColors.Control;

            _lv.Dock = DockStyle.Fill;
            _lv.View = View.Details;
            _lv.FullRowSelect = true;
            _lv.MultiSelect = true;
            _lv.AllowDrop = true;
            _lv.Columns.Add("Tên", 240);
            _lv.Columns.Add("Kích thước", 90, HorizontalAlignment.Right);
            _lv.Columns.Add("Loại", 70);
            _lv.DoubleClick += async (s, e) => await OpenSelected();
            _lv.ItemDrag += Lv_ItemDrag;
            _lv.DragEnter += Lv_DragEnter;
            _lv.DragDrop += Lv_DragDrop;

            Controls.Add(_lv);
            Controls.Add(_txtPath);
            Controls.Add(bar);
            SetEnabled(false);
        }

        void InitBtn(Button b, string text, string tip, EventHandler onClick)
        {
            b.Text = text;
            b.AutoSize = true;
            b.Click += onClick;
            new ToolTip().SetToolTip(b, tip);
        }

        void SetEnabled(bool on)
        {
            _btnUp.Enabled = _btnReload.Enabled = _btnMkdir.Enabled =
                _btnRename.Enabled = _btnDelete.Enabled = on;
        }

        void Say(string msg) { if (Status != null) Status(msg); }

        // ---- Nguồn ----
        public void SetHosts(List<HostInfo> hosts)
        {
            var keep = _cbo.SelectedItem;
            _cbo.Items.Clear();
            _cbo.Items.Add("— chọn nguồn —");
            _cbo.Items.Add("Máy này");
            foreach (var h in hosts) _cbo.Items.Add(h);
            _cbo.SelectedIndex = 0;
            if (keep is HostInfo)
            {
                var again = hosts.FirstOrDefault(h => h.Id == ((HostInfo)keep).Id);
                if (again != null) _cbo.SelectedItem = again;
            }
        }

        async Task OnSourceChanged()
        {
            if (Source != null) { Source.Dispose(); Source = null; }
            _lv.Items.Clear();
            _txtPath.Text = "";
            SetEnabled(false);

            var sel = _cbo.SelectedItem;
            if (sel == null || _cbo.SelectedIndex == 0) return;

            if (_cbo.SelectedIndex == 1)
            {
                Source = new LocalSource();
            }
            else
            {
                var h = (HostInfo)sel;
                Say("Đang kết nối " + h.Display + "…");
                try
                {
                    Source = await Task.Run(() => (IFileSource)new SftpSource(h));
                }
                catch (Exception ex)
                {
                    Say("Không kết nối được: " + ex.Message);
                    MessageBox.Show(ex.Message, "Lỗi kết nối", MessageBoxButtons.OK, MessageBoxIcon.Error);
                    _cbo.SelectedIndex = 0;
                    return;
                }
            }
            SetEnabled(true);
            await Navigate(Source.Home());
        }

        // ---- Duyệt ----
        public async Task Navigate(string path)
        {
            if (Source == null) return;
            var src = Source;
            try
            {
                Cursor = Cursors.WaitCursor;
                var abs = await Task.Run(() => src.Canonical(path));
                var items = await Task.Run(() => src.List(abs).Sorted());
                if (Source != src) return;      // người dùng đã đổi nguồn giữa chừng
                CurrentPath = abs;
                _txtPath.Text = abs;
                Render(items);
                Say(src.Label + " — " + abs + " (" + items.Count + " mục)");
            }
            catch (Exception ex)
            {
                Say("Lỗi: " + ex.Message);
            }
            finally { Cursor = Cursors.Default; }
        }

        void Render(List<FileItem> items)
        {
            _lv.BeginUpdate();
            _lv.Items.Clear();
            foreach (var it in items)
            {
                var row = new ListViewItem(it.Name);
                row.SubItems.Add(it.IsDir ? "" : Transfer.FormatSize(it.Size));
                row.SubItems.Add(it.IsDir ? "thư mục" : (it.IsLink ? "liên kết" : "tệp"));
                row.Tag = it;
                _lv.Items.Add(row);
            }
            _lv.EndUpdate();
        }

        public Task Reload() { return Navigate(CurrentPath); }
        public Task Up() { return Navigate(Source.Parent(CurrentPath)); }

        async Task OpenSelected()
        {
            var it = SelectedItems().FirstOrDefault();
            if (it == null || !it.IsDir) return;
            await Navigate(Source.Combine(CurrentPath, it.Name));
        }

        public List<FileItem> SelectedItems()
        {
            return _lv.SelectedItems.Cast<ListViewItem>().Select(x => (FileItem)x.Tag).ToList();
        }

        // ---- Tạo / đổi tên / xóa ----
        async Task Mkdir()
        {
            var name = Prompt.Show("Tên thư mục mới:", "Thư mục mới", "");
            if (string.IsNullOrEmpty(name)) return;
            var src = Source; var dir = CurrentPath;
            try
            {
                await Task.Run(() => src.Mkdir(src.Combine(dir, name)));
                Say("✓ Đã tạo \"" + name + "\"");
                await Reload();
            }
            catch (Exception ex) { Say("Lỗi tạo thư mục: " + ex.Message); }
        }

        async Task Rename()
        {
            var it = SelectedItems().FirstOrDefault();
            if (it == null) { Say("Chọn một mục trước."); return; }
            var name = Prompt.Show("Tên mới:", "Đổi tên", it.Name);
            if (string.IsNullOrEmpty(name) || name == it.Name) return;
            var src = Source; var dir = CurrentPath;
            try
            {
                await Task.Run(() => src.Rename(src.Combine(dir, it.Name), src.Combine(dir, name)));
                Say("✓ Đã đổi tên thành \"" + name + "\"");
                await Reload();
            }
            catch (Exception ex) { Say("Lỗi đổi tên: " + ex.Message); }
        }

        async Task DeleteSel()
        {
            var items = SelectedItems();
            if (items.Count == 0) { Say("Chọn mục cần xóa trước."); return; }
            var msg = items.Count == 1
                ? "Xóa \"" + items[0].Name + "\"?" + (items[0].IsDir ? "\nCả thư mục và nội dung bên trong." : "")
                : "Xóa " + items.Count + " mục đang chọn?";
            if (MessageBox.Show(msg, "Xác nhận xóa", MessageBoxButtons.YesNo, MessageBoxIcon.Warning) != DialogResult.Yes)
                return;

            var src = Source; var dir = CurrentPath;
            try
            {
                await Task.Run(() =>
                {
                    foreach (var it in items) src.Delete(src.Combine(dir, it.Name));
                });
                Say("✓ Đã xóa " + items.Count + " mục");
                await Reload();
            }
            catch (Exception ex) { Say("Lỗi xóa: " + ex.Message); }
        }

        // ---- Kéo–thả ----
        void Lv_ItemDrag(object sender, ItemDragEventArgs e)
        {
            if (Source == null) return;
            var items = SelectedItems();
            if (items.Count == 0) return;
            var p = new DragPayload { From = this };
            foreach (var it in items)
            {
                p.Paths.Add(Source.Combine(CurrentPath, it.Name));
                p.Names.Add(it.Name);
            }
            _lv.DoDragDrop(p, DragDropEffects.Copy);
        }

        void Lv_DragEnter(object sender, DragEventArgs e)
        {
            if (Source == null) { e.Effect = DragDropEffects.None; return; }
            bool ok = e.Data.GetDataPresent(typeof(DragPayload)) || e.Data.GetDataPresent(DataFormats.FileDrop);
            e.Effect = ok ? DragDropEffects.Copy : DragDropEffects.None;
        }

        void Lv_DragDrop(object sender, DragEventArgs e)
        {
            if (Source == null || Dropped == null) return;

            // Thả vào đúng một thư mục trong danh sách thì copy vào trong thư mục đó.
            var pt = _lv.PointToClient(new Point(e.X, e.Y));
            var hit = _lv.GetItemAt(pt.X, pt.Y);
            string destDir = CurrentPath;
            if (hit != null && ((FileItem)hit.Tag).IsDir)
                destDir = Source.Combine(CurrentPath, ((FileItem)hit.Tag).Name);

            if (e.Data.GetDataPresent(typeof(DragPayload)))
            {
                Dropped(this, (DragPayload)e.Data.GetData(typeof(DragPayload)), destDir);
            }
            else if (e.Data.GetDataPresent(DataFormats.FileDrop))
            {
                // Kéo thẳng từ Explorer: nguồn là máy này.
                var files = (string[])e.Data.GetData(DataFormats.FileDrop);
                var p = new DragPayload { From = null };
                foreach (var f in files)
                {
                    p.Paths.Add(f);
                    p.Names.Add(System.IO.Path.GetFileName(f.TrimEnd('\\')));
                }
                Dropped(this, p, destDir);
            }
        }
    }

    // Hộp nhập một dòng (WinForms không có sẵn InputBox).
    public static class Prompt
    {
        public static string Show(string label, string title, string def)
        {
            using (var f = new Form())
            {
                f.Text = title;
                f.FormBorderStyle = FormBorderStyle.FixedDialog;
                f.StartPosition = FormStartPosition.CenterParent;
                f.MinimizeBox = f.MaximizeBox = false;
                f.ClientSize = new Size(380, 110);

                var lb = new Label { Text = label, Left = 12, Top = 12, Width = 350 };
                var tb = new TextBox { Text = def, Left = 12, Top = 36, Width = 356 };
                var ok = new Button { Text = "OK", DialogResult = DialogResult.OK, Left = 200, Top = 70, Width = 80 };
                var cancel = new Button { Text = "Hủy", DialogResult = DialogResult.Cancel, Left = 288, Top = 70, Width = 80 };

                f.Controls.AddRange(new Control[] { lb, tb, ok, cancel });
                f.AcceptButton = ok;
                f.CancelButton = cancel;
                return f.ShowDialog() == DialogResult.OK ? tb.Text.Trim() : null;
            }
        }
    }
}
