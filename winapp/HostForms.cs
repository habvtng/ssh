// Hộp thoại thêm/sửa server + cửa sổ quản lý danh sách server.
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Windows.Forms;

namespace TreSSH
{
    public class HostDialog : Form
    {
        readonly TextBox _label = new TextBox();
        readonly TextBox _host = new TextBox();
        readonly TextBox _port = new TextBox { Text = "22" };
        readonly TextBox _user = new TextBox { Text = "root" };
        readonly ComboBox _auth = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList };
        readonly TextBox _password = new TextBox { UseSystemPasswordChar = true };
        readonly TextBox _keyPath = new TextBox();
        readonly TextBox _passphrase = new TextBox { UseSystemPasswordChar = true };
        readonly Button _browse = new Button { Text = "Chọn…" };

        public HostInfo Result { get; private set; }

        public HostDialog(HostInfo edit)
        {
            Text = edit == null ? "Thêm server" : "Sửa server";
            FormBorderStyle = FormBorderStyle.FixedDialog;
            StartPosition = FormStartPosition.CenterParent;
            MinimizeBox = MaximizeBox = false;
            ClientSize = new Size(430, 300);

            _auth.Items.AddRange(new object[] { "Mật khẩu", "SSH key" });
            _auth.SelectedIndex = 0;
            _auth.SelectedIndexChanged += (s, e) => SyncAuthFields();

            int y = 12;
            AddRow("Tên hiển thị", _label, ref y);
            AddRow("Host / IP", _host, ref y);
            AddRow("Cổng", _port, ref y);
            AddRow("Tài khoản", _user, ref y);
            AddRow("Xác thực", _auth, ref y);
            AddRow("Mật khẩu", _password, ref y);
            AddRow("File private key", _keyPath, ref y);
            _browse.Left = 344; _browse.Top = _keyPath.Top - 1; _browse.Width = 74;
            _browse.Click += (s, e) =>
            {
                using (var d = new OpenFileDialog { Title = "Chọn private key" })
                    if (d.ShowDialog() == DialogResult.OK) _keyPath.Text = d.FileName;
            };
            _keyPath.Width = 320;
            Controls.Add(_browse);
            AddRow("Passphrase", _passphrase, ref y);

            var ok = new Button { Text = "Lưu", DialogResult = DialogResult.OK, Left = 250, Top = y + 10, Width = 80 };
            var cancel = new Button { Text = "Hủy", DialogResult = DialogResult.Cancel, Left = 338, Top = y + 10, Width = 80 };
            ok.Click += (s, e) => Save(edit);
            Controls.AddRange(new Control[] { ok, cancel });
            AcceptButton = ok;
            CancelButton = cancel;

            if (edit != null)
            {
                _label.Text = edit.Label;
                _host.Text = edit.Host;
                _port.Text = edit.Port.ToString();
                _user.Text = edit.Username;
                _auth.SelectedIndex = edit.AuthType == "key" ? 1 : 0;
                _password.Text = Secret.Unprotect(edit.PasswordEnc);
                _keyPath.Text = edit.KeyPath;
                _passphrase.Text = Secret.Unprotect(edit.PassphraseEnc);
            }
            SyncAuthFields();
        }

        void AddRow(string caption, Control c, ref int y)
        {
            Controls.Add(new Label { Text = caption, Left = 12, Top = y + 3, Width = 110 });
            c.Left = 126; c.Top = y; if (c.Width < 200) c.Width = 292;
            Controls.Add(c);
            y += 30;
        }

        void SyncAuthFields()
        {
            bool key = _auth.SelectedIndex == 1;
            _password.Enabled = !key;
            _keyPath.Enabled = _passphrase.Enabled = _browse.Enabled = key;
        }

        void Save(HostInfo edit)
        {
            var h = edit ?? new HostInfo();
            h.Label = _label.Text.Trim();
            h.Host = _host.Text.Trim();
            int port;
            h.Port = int.TryParse(_port.Text.Trim(), out port) && port > 0 ? port : 22;
            h.Username = _user.Text.Trim();
            h.AuthType = _auth.SelectedIndex == 1 ? "key" : "password";
            h.PasswordEnc = Secret.Protect(_password.Text);
            h.KeyPath = _keyPath.Text.Trim();
            h.PassphraseEnc = Secret.Protect(_passphrase.Text);

            if (string.IsNullOrEmpty(h.Host))
            {
                MessageBox.Show("Nhập host/IP đã.", "Thiếu thông tin");
                DialogResult = DialogResult.None;
                return;
            }
            Result = h;
        }
    }

    public class HostsForm : Form
    {
        readonly ListBox _list = new ListBox { Dock = DockStyle.Fill };
        public List<HostInfo> Hosts;

        public HostsForm(List<HostInfo> hosts)
        {
            Hosts = hosts;
            Text = "Quản lý server";
            StartPosition = FormStartPosition.CenterParent;
            ClientSize = new Size(420, 320);

            var bar = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = 38, Padding = new Padding(6) };
            var add = new Button { Text = "Thêm", AutoSize = true };
            var edit = new Button { Text = "Sửa", AutoSize = true };
            var del = new Button { Text = "Xóa", AutoSize = true };
            var close = new Button { Text = "Đóng", AutoSize = true, DialogResult = DialogResult.OK };
            bar.Controls.AddRange(new Control[] { add, edit, del, close });

            add.Click += (s, e) =>
            {
                using (var d = new HostDialog(null))
                    if (d.ShowDialog(this) == DialogResult.OK && d.Result != null) { Hosts.Add(d.Result); Persist(); }
            };
            edit.Click += (s, e) =>
            {
                var sel = _list.SelectedItem as HostInfo;
                if (sel == null) return;
                using (var d = new HostDialog(sel))
                    if (d.ShowDialog(this) == DialogResult.OK) Persist();
            };
            del.Click += (s, e) =>
            {
                var sel = _list.SelectedItem as HostInfo;
                if (sel == null) return;
                if (MessageBox.Show("Xóa server \"" + sel.Display + "\"?", "Xác nhận",
                        MessageBoxButtons.YesNo, MessageBoxIcon.Warning) != DialogResult.Yes) return;
                Hosts.Remove(sel);
                Persist();
            };
            _list.DoubleClick += (s, e) => edit.PerformClick();

            Controls.Add(_list);
            Controls.Add(bar);
            Refill();
        }

        void Persist()
        {
            HostStore.Save(Hosts);
            Refill();
        }

        void Refill()
        {
            _list.Items.Clear();
            foreach (var h in Hosts) _list.Items.Add(h);
        }
    }
}
