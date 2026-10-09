using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.IO;
using System.Linq;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Media;

namespace ScreenTranslator;

/// Bảng thuật ngữ dùng chung cho thuật ngữ chung (Cài đặt) và thuật ngữ của từng game (tab Thuật ngữ).
/// AppSettings trả bản sao nên đọc qua `get`, sửa xong gán lại qua `set`.
public sealed class GlossaryEditor : DockPanel
{
    sealed class Row
    {
        public Guid id { get; set; }
        public string term { get; set; } = "";
        public string translation { get; set; } = "";
        public bool keepAsIs { get; set; }
    }

    readonly Func<List<GlossaryEntry>> get;
    readonly Action<List<GlossaryEntry>> set;
    readonly string fileName;
    readonly ObservableCollection<Row> rows = new();
    readonly DataGrid grid;
    readonly TextBlock count = Ui.Caption(""), message = Ui.Caption("");

    public GlossaryEditor(Func<List<GlossaryEntry>> get, Action<List<GlossaryEntry>> set, string fileName, string note)
    {
        this.get = get; this.set = set; this.fileName = fileName;
        grid = new DataGrid
        {
            ItemsSource = rows, AutoGenerateColumns = false, CanUserAddRows = false, HeadersVisibility = DataGridHeadersVisibility.Column,
            GridLinesVisibility = DataGridGridLinesVisibility.Horizontal, Background = Brushes.White, RowHeaderWidth = 0,
        };
        grid.Columns.Add(new DataGridTextColumn { Header = "Thuật ngữ gốc", Binding = new Binding("term") { UpdateSourceTrigger = UpdateSourceTrigger.PropertyChanged }, Width = new DataGridLength(1, DataGridLengthUnitType.Star) });
        grid.Columns.Add(new DataGridTextColumn { Header = "Dịch thành (trống = giữ nguyên)", Binding = new Binding("translation") { UpdateSourceTrigger = UpdateSourceTrigger.PropertyChanged }, Width = new DataGridLength(1, DataGridLengthUnitType.Star) });
        grid.Columns.Add(new DataGridCheckBoxColumn { Header = "Giữ nguyên", Binding = new Binding("keepAsIs") { UpdateSourceTrigger = UpdateSourceTrigger.PropertyChanged }, Width = 90 });
        grid.CellEditEnding += (_, _) => Dispatcher.BeginInvoke(Save, System.Windows.Threading.DispatcherPriority.Background);
        grid.CurrentCellChanged += (_, _) => Save();
        Unloaded += (_, _) => Save();

        var add = Ui.IconBtn("", () => { rows.Add(new Row { id = Guid.NewGuid() }); grid.ScrollIntoView(rows[^1]); UpdateCount(); }, "Thêm dòng");
        var del = Ui.IconBtn("", () => { foreach (var r in grid.SelectedItems.Cast<Row>().ToList()) rows.Remove(r); Save(); }, "Xoá dòng đã chọn");
        var head = Ui.Caption(note);
        head.Margin = new Thickness(0, 0, 0, 8);
        SetDock(head, Dock.Top);
        var bar = Ui.Row(Ui.H(6, add, del, count, message), Ui.Btn("Nhập CSV…", ImportCSV), Ui.Btn("Xuất CSV…", ExportCSV));
        bar.Margin = new Thickness(0, 8, 0, 0);
        SetDock(bar, Dock.Bottom);
        Children.Add(head); Children.Add(bar); Children.Add(grid);
        Reload();
    }

    /// Đọc lại từ cài đặt (sau khi đổi game).
    public void Reload()
    {
        rows.Clear();
        foreach (var g in get()) rows.Add(new Row { id = g.id, term = g.term, translation = g.translation, keepAsIs = g.keepAsIs });
        message.Text = "";
        UpdateCount();
    }

    /// Ghi bảng vào cài đặt; bỏ dòng trống. Không đổi gì thì không ghi.
    public void Save()
    {
        var list = rows.Where(r => r.term.Trim().Length > 0 || r.translation.Length > 0)
            .Select(r => new GlossaryEntry { id = r.id, term = r.term, translation = r.translation, keepAsIs = r.keepAsIs }).ToList();
        var old = get();
        bool same = old.Count == list.Count && old.Zip(list).All(p => p.First.id == p.Second.id && p.First.term == p.Second.term
            && p.First.translation == p.Second.translation && p.First.keepAsIs == p.Second.keepAsIs);
        if (!same) set(list);
        UpdateCount();
    }

    void UpdateCount() => count.Text = $"{rows.Count} thuật ngữ";

    /// CSV `thuật ngữ,bản dịch` (bản dịch trống = giữ nguyên). Bỏ dòng tiêu đề và dòng chú thích `#`;
    /// thuật ngữ đã có thì được cập nhật, không thêm trùng.
    void ImportCSV()
    {
        var dlg = new Microsoft.Win32.OpenFileDialog { Filter = "CSV (*.csv;*.txt)|*.csv;*.txt|Tất cả|*.*" };
        if (dlg.ShowDialog() != true) return;
        string[] lines;
        try { lines = File.ReadAllLines(dlg.FileName, Encoding.UTF8); }
        catch (Exception e) { message.Text = $"Không đọc được file: {e.Message}"; return; }
        grid.CommitEdit(DataGridEditingUnit.Row, true);
        int added = 0, updated = 0;
        foreach (var line in lines)
        {
            var raw = line.Trim();
            if (raw.Length == 0 || raw.StartsWith('#')) continue;
            var parts = raw.Split(',', 2).Select(p => p.Trim().Trim('"')).ToArray();
            var term = parts[0];
            if (term.Length == 0) continue;
            if (term.ToLowerInvariant() is "term" or "thuật ngữ" or "thuat ngu") continue;
            var tr = parts.Length > 1 ? parts[1] : "";
            if (rows.FirstOrDefault(r => string.Equals(r.term, term, StringComparison.OrdinalIgnoreCase)) is Row r)
            {
                r.translation = tr; r.keepAsIs = tr.Length == 0; updated++;
            }
            else { rows.Add(new Row { id = Guid.NewGuid(), term = term, translation = tr, keepAsIs = tr.Length == 0 }); added++; }
        }
        grid.Items.Refresh();
        Save();
        message.Text = $"Đã nhập: {added} mới, {updated} cập nhật";
    }

    void ExportCSV()
    {
        Save();
        var dlg = new Microsoft.Win32.SaveFileDialog { FileName = SafeName(fileName), Filter = "CSV (*.csv)|*.csv" };
        if (dlg.ShowDialog() != true) return;
        try { File.WriteAllText(dlg.FileName, string.Join("\n", get().Select(g => $"{g.term},{(g.keepAsIs ? "" : g.translation)}")), new UTF8Encoding(false)); }
        catch (Exception e) { message.Text = $"Không ghi được file: {e.Message}"; }
    }

    /// Tên game có thể chứa ký tự không hợp lệ trong tên file (`:` …).
    static string SafeName(string s) => string.Concat(s.Select(c => Path.GetInvalidFileNameChars().Contains(c) ? '-' : c));
}
