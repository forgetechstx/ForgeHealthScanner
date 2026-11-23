using System;
using System.Drawing;
using System.Drawing.Printing;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows.Forms;

internal static class NativeTools
{
    internal static void About(Form owner, Image logo)
    {
        using (var dialog = new Form { Text = "About ForgeHealthScanner", ClientSize = new Size(490, 340), StartPosition = FormStartPosition.CenterParent })
        {
            var close = NativeWindow.Button("Close");
            close.Dock = DockStyle.Bottom;
            close.DialogResult = DialogResult.OK;
            var text = new Label { Dock = DockStyle.Fill, Padding = new Padding(20), Text =
                "ForgeHealthScanner " + NativeApp.Version + Environment.NewLine + "Forge Technologies" + Environment.NewLine + Environment.NewLine +
                "Portable Windows health scanner. Results stay on this PC unless you choose to share them." + Environment.NewLine + Environment.NewLine +
                "MIT License. Provided without warranty." };
            dialog.Controls.Add(text);
            dialog.Controls.Add(new PictureBox { Dock = DockStyle.Top, Height = 130, BackColor = Color.Black, Image = logo, SizeMode = PictureBoxSizeMode.Zoom });
            dialog.Controls.Add(close);
            dialog.CancelButton = close;
            dialog.ShowDialog(owner);
        }
    }

    internal static void Print(Form owner, ScanReport report)
    {
        var body = new StringBuilder();
        body.AppendLine("ForgeHealthScanner   |   " + report.device).AppendLine(report.os + "   |   " + report.Timestamp.ToLocalTime().ToString("g")).AppendLine();
        foreach (var check in report.checks)
            body.AppendLine(check.status.ToUpperInvariant() + "   " + check.name).AppendLine(check.detail).AppendLine(check.action).AppendLine();
        using (var doc = new PrintDocument { DocumentName = "ForgeHealthScanner report" })
        using (var font = new Font("Segoe UI", 10))
        using (var format = new StringFormat { FormatFlags = StringFormatFlags.LineLimit })
        using (var dialog = new PrintDialog { Document = doc, UseEXDialog = true })
        {
            string remaining = body.ToString();
            doc.PrintPage += (s, e) => {
                int characters, lines;
                e.Graphics.MeasureString(remaining, font, e.MarginBounds.Size, format, out characters, out lines);
                if (characters == 0) throw new InvalidOperationException("The printable area is too small.");
                e.Graphics.DrawString(remaining.Substring(0, characters), font, Brushes.Black, e.MarginBounds, format);
                remaining = remaining.Substring(characters);
                e.HasMorePages = remaining.Length != 0;
            };
            if (dialog.ShowDialog(owner) == DialogResult.OK) doc.Print();
        }
    }

    internal static void Backups(Form owner, string folder)
    {
        ScanReports.CheckLocalFolder(folder);
        using (var form = new Form { Text = "Registry backups", Size = new Size(740, 480), StartPosition = FormStartPosition.CenterParent })
        {
            var list = new ComboBox { Dock = DockStyle.Top, DropDownStyle = ComboBoxStyle.DropDownList };
            var preview = new TextBox { Dock = DockStyle.Fill, Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Both, WordWrap = false };
            var delete = NativeWindow.Button("Delete selected backup");
            delete.Dock = DockStyle.Bottom;
            Action populate = () => {
                list.Items.Clear();
                ScanReports.CheckLocalFolder(folder);
                if (Directory.Exists(folder))
                    list.Items.AddRange(new DirectoryInfo(folder).GetFiles("startup-run-*.reg")
                        .Where(f => Regex.IsMatch(f.Name, @"\Astartup-run-[a-fA-F0-9]{32}\.reg\z") && (f.Attributes & FileAttributes.ReparsePoint) == 0)
                        .OrderByDescending(f => f.LastWriteTimeUtc).Select(f => (object)f.Name).ToArray());
                delete.Enabled = list.Items.Count > 0;
                if (delete.Enabled) list.SelectedIndex = 0;
                else preview.Text = "No registry backups found.";
            };
            list.SelectedIndexChanged += (s, e) => {
                if (list.SelectedItem == null) return;
                try
                {
                    ScanReports.CheckLocalFolder(folder);
                    string path = Path.Combine(folder, (string)list.SelectedItem);
                    if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0) throw new IOException("Linked files cannot be previewed.");
                    using (var file = File.OpenRead(path))
                    {
                        if (file.Length > 2 * 1024 * 1024) throw new IOException("This backup exceeds the 2 MB preview limit.");
                        using (var reader = new StreamReader(file, true)) preview.Text = reader.ReadToEnd();
                    }
                }
                catch (Exception ex) { preview.Text = ex.Message; }
            };
            delete.Click += (s, e) => {
                string name = list.SelectedItem as string;
                if (name == null || MessageBox.Show(form, "Permanently delete " + name + "?", "Delete backup", MessageBoxButtons.YesNo,
                    MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2) != DialogResult.Yes) return;
                try
                {
                    ScanReports.CheckLocalFolder(folder);
                    string path = Path.Combine(folder, name);
                    if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0) throw new IOException("Linked files cannot be deleted here.");
                    File.Delete(path);
                    populate();
                }
                catch (Exception ex) { MessageBox.Show(form, ex.Message, "Backup could not be deleted"); }
            };
            form.Controls.Add(preview);
            form.Controls.Add(list);
            form.Controls.Add(delete);
            populate();
            form.ShowDialog(owner);
        }
    }
}
