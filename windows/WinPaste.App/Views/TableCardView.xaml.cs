using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using WinPaste.App.Services;
using WinPaste.Core.Models;
using WinPaste.Core.Parsing;

namespace WinPaste.App.Views;

public partial class TableCardView : UserControl
{
    private ClipboardViewModel? _vm;
    private ClipboardItem? _item;
    private string[][] _rows = [];
    private bool _expanded;
    private (int R, int C)? _selStart;
    private (int R, int C)? _selEnd;

    public TableCardView()
    {
        InitializeComponent();
    }

    public void Bind(ClipboardViewModel vm, ClipboardItem item)
    {
        if (_vm != null)
            _vm.PropertyChanged -= Vm_PropertyChanged;

        _vm = vm;
        _item = item;
        _rows = vm.ParseTableRows(item);
        _vm.PropertyChanged += Vm_PropertyChanged;

        int rCount = _rows.Length;
        int cCount = _rows.Length > 0 ? _rows.Max(r => r.Length) : 0;
        HeaderMetaText.Text = $"{rCount} 行 × {cCount} 列 · {TimeFormatter.RelativeTimeShort(item.CreatedAt)}";

        PinBadge.Visibility = item.Pinned ? Visibility.Visible : Visibility.Collapsed;
        MenuPinItem.Header = item.Pinned ? "取消置顶" : "置顶";
        BtnPinLabel.Text = item.Pinned ? "取消置顶" : "置顶";

        BuildCollapsedGrid();
        UpdateExpandedVisibility();
        UpdateFlashAppearance();
    }

    private void Vm_PropertyChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(ClipboardViewModel.FlashItemId) or nameof(ClipboardViewModel.FlashedCellKey))
        {
            UpdateFlashAppearance();
            if (_expanded)
                BuildExpandedGrid();
        }
    }

    private void UpdateFlashAppearance()
    {
        if (_vm == null || _item == null) return;
        bool flashed = _vm.FlashItemId == _item.Id;
        CardBorder.Background = flashed
            ? new SolidColorBrush(Color.FromArgb(0x20, 0x28, 0xCD, 0x41))
            : (IsMouseOver ? (Brush)FindResource("CardHoverBrush") : (Brush)FindResource("CardBackgroundBrush"));
        CardBorder.BorderBrush = flashed
            ? (Brush)FindResource("SuccessGreenBrush")
            : (Brush)FindResource("BorderHairlineBrush");
    }

    private void BuildCollapsedGrid()
    {
        CollapsedGrid.Children.Clear();
        CollapsedGrid.RowDefinitions.Clear();
        CollapsedGrid.ColumnDefinitions.Clear();

        int maxR = Math.Min(2, _rows.Length);
        int maxC = Math.Min(6, _rows.Length > 0 ? _rows.Max(r => r.Length) : 0);

        for (int r = 0; r < maxR; r++)
            CollapsedGrid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        for (int c = 0; c < maxC; c++)
            CollapsedGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(74) });

        var borderBrush = (Brush)FindResource("BorderHairlineBrush");
        var headerBg = (Brush)FindResource("SubtleSurfaceBrush");
        var cellBg = Brushes.White;
        var primary = (Brush)FindResource("TextPrimaryBrush");
        var secondary = (Brush)FindResource("TextSecondaryBrush");

        for (int r = 0; r < maxR; r++)
        {
            for (int c = 0; c < maxC; c++)
            {
                string val = c < _rows[r].Length ? _rows[r][c] : string.Empty;
                var bd = new Border
                {
                    Width = 74,
                    Height = 21,
                    BorderBrush = borderBrush,
                    BorderThickness = new Thickness(c == 0 ? 1 : 0, r == 0 ? 1 : 0, 1, 1),
                    Background = r == 0 ? headerBg : cellBg,
                    Padding = new Thickness(5, 2, 5, 2),
                    Child = new TextBlock
                    {
                        Text = val,
                        FontSize = 11,
                        FontWeight = r == 0 ? FontWeights.SemiBold : FontWeights.Normal,
                        Foreground = r == 0 ? primary : secondary,
                        TextTrimming = TextTrimming.CharacterEllipsis,
                        VerticalAlignment = VerticalAlignment.Center
                    }
                };
                Grid.SetRow(bd, r);
                Grid.SetColumn(bd, c);
                CollapsedGrid.Children.Add(bd);
            }
        }
    }

    private void UpdateExpandedVisibility()
    {
        CollapsedPreviewScroller.Visibility = _expanded ? Visibility.Collapsed : Visibility.Visible;
        ExpandedContainer.Visibility = _expanded ? Visibility.Visible : Visibility.Collapsed;
        ExpandChevron.Text = _expanded ? "收起 ▴" : "展开 ▾";
        if (_expanded)
            BuildExpandedGrid();
    }

    private void BuildExpandedGrid()
    {
        if (_item == null || _vm == null) return;
        ExpandedGrid.Children.Clear();
        ExpandedGrid.RowDefinitions.Clear();
        ExpandedGrid.ColumnDefinitions.Clear();

        int maxR = Math.Min(TableParser.MaxRenderRows, _rows.Length);
        int maxC = Math.Min(TableParser.MaxRenderCols, _rows.Length > 0 ? _rows.Max(r => r.Length) : 0);
        if (maxR == 0 || maxC == 0) return;

        // +1 for header row & row-number col
        ExpandedGrid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(22) });
        for (int r = 0; r < maxR; r++)
            ExpandedGrid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(24) });

        ExpandedGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(36) });
        for (int c = 0; c < maxC; c++)
            ExpandedGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(86) });

        var borderBrush = (Brush)FindResource("BorderHairlineBrush");
        var headerBg = (Brush)FindResource("SubtleSurfaceBrush");
        var selectedBg = (Brush)FindResource("AccentSoftBrush");
        var accent = (Brush)FindResource("AccentBrush");
        var flashBg = new SolidColorBrush(Color.FromArgb(0x38, 0x28, 0xCD, 0x41));
        var primary = (Brush)FindResource("TextPrimaryBrush");
        var secondary = (Brush)FindResource("TextSecondaryBrush");

        // Top-left corner
        var corner = new Border
        {
            BorderBrush = borderBrush,
            BorderThickness = new Thickness(1),
            Background = headerBg
        };
        Grid.SetRow(corner, 0);
        Grid.SetColumn(corner, 0);
        ExpandedGrid.Children.Add(corner);

        // Column headers (A, B, C...)
        for (int c = 0; c < maxC; c++)
        {
            int colIdx = c;
            var colHeader = new Border
            {
                BorderBrush = borderBrush,
                BorderThickness = new Thickness(0, 1, 1, 1),
                Background = headerBg,
                Cursor = Cursors.Hand,
                ToolTip = $"点击复制第 {TableParser.ColumnLetter(c)} 列",
                Child = new TextBlock
                {
                    Text = TableParser.ColumnLetter(c),
                    FontSize = 10.5,
                    FontWeight = FontWeights.SemiBold,
                    Foreground = secondary,
                    HorizontalAlignment = HorizontalAlignment.Center,
                    VerticalAlignment = VerticalAlignment.Center
                }
            };
            colHeader.MouseLeftButtonUp += (_, e) =>
            {
                e.Handled = true;
                _vm.CopyTableColumn(_item.Id, _rows, colIdx);
            };
            Grid.SetRow(colHeader, 0);
            Grid.SetColumn(colHeader, c + 1);
            ExpandedGrid.Children.Add(colHeader);
        }

        // Rows
        for (int r = 0; r < maxR; r++)
        {
            int rowIdx = r;
            var rowHeader = new Border
            {
                BorderBrush = borderBrush,
                BorderThickness = new Thickness(1, 0, 1, 1),
                Background = headerBg,
                Cursor = Cursors.Hand,
                ToolTip = $"点击复制第 {r + 1} 行",
                Child = new TextBlock
                {
                    Text = (r + 1).ToString(),
                    FontSize = 10.5,
                    Foreground = secondary,
                    HorizontalAlignment = HorizontalAlignment.Center,
                    VerticalAlignment = VerticalAlignment.Center
                }
            };
            rowHeader.MouseLeftButtonUp += (_, e) =>
            {
                e.Handled = true;
                _vm.CopyTableRow(_item.Id, _rows, rowIdx);
            };
            Grid.SetRow(rowHeader, r + 1);
            Grid.SetColumn(rowHeader, 0);
            ExpandedGrid.Children.Add(rowHeader);

            for (int c = 0; c < maxC; c++)
            {
                int colIdx = c;
                string val = c < _rows[r].Length ? _rows[r][c] : string.Empty;
                bool isSel = IsCellSelected(r, c);
                bool isFlashed = _vm.FlashedCellKey == $"{_item.Id}:{r}:{c}";

                var cell = new Border
                {
                    BorderBrush = isSel ? accent : borderBrush,
                    BorderThickness = isSel ? new Thickness(1) : new Thickness(0, 0, 1, 1),
                    Background = isFlashed ? flashBg : (isSel ? selectedBg : Brushes.White),
                    Padding = new Thickness(6, 2, 6, 2),
                    Cursor = Cursors.Hand,
                    Child = new TextBlock
                    {
                        Text = val,
                        FontSize = 11.5,
                        Foreground = primary,
                        TextTrimming = TextTrimming.CharacterEllipsis,
                        VerticalAlignment = VerticalAlignment.Center,
                        ToolTip = val.Length > 18 ? val : null
                    }
                };
                cell.MouseLeftButtonDown += (_, e) =>
                {
                    e.Handled = true;
                    if (e.ClickCount == 2)
                    {
                        _vm.CopyTableCell(_item.Id, _rows, rowIdx, colIdx);
                        return;
                    }

                    bool shift = (Keyboard.Modifiers & ModifierKeys.Shift) != 0;
                    if (shift && _selStart.HasValue)
                    {
                        _selEnd = (rowIdx, colIdx);
                    }
                    else
                    {
                        _selStart = (rowIdx, colIdx);
                        _selEnd = (rowIdx, colIdx);
                    }
                    UpdateSelectionToolbar();
                    BuildExpandedGrid();
                };
                Grid.SetRow(cell, r + 1);
                Grid.SetColumn(cell, c + 1);
                ExpandedGrid.Children.Add(cell);
            }
        }
    }

    private bool IsCellSelected(int r, int c)
    {
        if (!_selStart.HasValue) return false;
        var a = _selStart.Value;
        var b = _selEnd ?? a;
        int r1 = Math.Min(a.R, b.R), r2 = Math.Max(a.R, b.R);
        int c1 = Math.Min(a.C, b.C), c2 = Math.Max(a.C, b.C);
        return r >= r1 && r <= r2 && c >= c1 && c <= c2;
    }

    private void UpdateSelectionToolbar()
    {
        if (_selStart.HasValue)
        {
            var a = _selStart.Value;
            var b = _selEnd ?? a;
            int rows = Math.Abs(b.R - a.R) + 1;
            int cols = Math.Abs(b.C - a.C) + 1;
            SelectionHintText.Text = $"已选 {rows}×{cols}";
            SelectionHintText.Foreground = (Brush)FindResource("AccentBrush");
            BtnCopyRegion.Visibility = Visibility.Visible;
            BtnClearSel.Visibility = Visibility.Visible;
        }
        else
        {
            SelectionHintText.Text = "单击选中单元格 · Shift+单击框选 · 双击复制 · 点行号/列标复制整行整列";
            SelectionHintText.Foreground = (Brush)FindResource("TextTertiaryBrush");
            BtnCopyRegion.Visibility = Visibility.Collapsed;
            BtnClearSel.Visibility = Visibility.Collapsed;
        }
    }

    private void BtnCopyRegion_Click(object sender, RoutedEventArgs e)
    {
        if (_vm == null || _item == null || !_selStart.HasValue) return;
        var a = _selStart.Value;
        var b = _selEnd ?? a;
        _vm.CopyTableRegion(_item.Id, _rows, a.R, a.C, b.R, b.C);
    }

    private void BtnClearSelection_Click(object sender, RoutedEventArgs e)
    {
        _selStart = null;
        _selEnd = null;
        UpdateSelectionToolbar();
        BuildExpandedGrid();
    }

    private void BtnToggleExpand_Click(object sender, RoutedEventArgs e)
    {
        e.Handled = true;
        _expanded = !_expanded;
        UpdateExpandedVisibility();
    }

    private void Root_MouseEnter(object sender, MouseEventArgs e)
    {
        HoverActions.Visibility = Visibility.Visible;
        UpdateFlashAppearance();
    }

    private void Root_MouseLeave(object sender, MouseEventArgs e)
    {
        HoverActions.Visibility = Visibility.Collapsed;
        UpdateFlashAppearance();
    }

    private void Root_MouseLeftButtonUp(object sender, MouseButtonEventArgs e)
    {
        if (_vm != null && _item != null && !_expanded)
            _vm.ActivateItem(_item);
    }

    private void BtnPinToScreen_Click(object sender, RoutedEventArgs e) { e.Handled = true; if (_item != null) _vm?.PinItem(_item); }
    private void BtnTogglePin_Click(object sender, RoutedEventArgs e) { e.Handled = true; if (_item != null) _vm?.SetPinned(_item, !_item.Pinned); }
    private void BtnDelete_Click(object sender, RoutedEventArgs e) { e.Handled = true; if (_item != null) _vm?.DeleteItem(_item); }
    private void MenuCopy_Click(object sender, RoutedEventArgs e) { if (_item != null) _vm?.CopyItem(_item); }
    private void MenuPinToScreen_Click(object sender, RoutedEventArgs e) { if (_item != null) _vm?.PinItem(_item); }
    private void MenuTogglePin_Click(object sender, RoutedEventArgs e) { if (_item != null) _vm?.SetPinned(_item, !_item.Pinned); }
    private void MenuDelete_Click(object sender, RoutedEventArgs e) { if (_item != null) _vm?.DeleteItem(_item); }
}
