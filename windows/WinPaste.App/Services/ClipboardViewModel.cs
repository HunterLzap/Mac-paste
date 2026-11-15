using System.Collections.ObjectModel;
using System.ComponentModel;
using System.IO;
using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Windows;
using System.Windows.Threading;
using WinPaste.Core.Models;
using WinPaste.Core.Parsing;
using WinPaste.Core.Storage;

namespace WinPaste.App.Services;

public sealed class ClipboardViewModel : INotifyPropertyChanged, IDisposable
{
    private readonly HistoryStore _store;
    private readonly AppSettingsStore _settings;
    private readonly ClipboardMonitor _monitor;
    private readonly PasteInjector _injector;
    private readonly ExternalAppTracker _appTracker;
    private readonly DispatcherTimer _searchDebounceTimer;

    private ClipboardKind _tab = ClipboardKind.ShortText;
    private string _searchText = string.Empty;
    private int _totalCount;
    private long? _sequentialItemId;
    private int _sequentialIndex;
    private long? _flashItemId;
    private string? _flashedCellKey;
    private DateTime _lastSeqClickUtc = DateTime.MinValue;
    private bool _reloadScheduled;

    public ObservableCollection<ClipboardItem> Items { get; } = [];

    public ClipboardKind Tab
    {
        get => _tab;
        set
        {
            if (_tab == value) return;
            _tab = value;
            OnPropertyChanged();
            Reload();
        }
    }

    public string SearchText
    {
        get => _searchText;
        set
        {
            if (_searchText == value) return;
            _searchText = value;
            OnPropertyChanged();
            _searchDebounceTimer.Stop();
            _searchDebounceTimer.Start();
        }
    }

    public int TotalCount
    {
        get => _totalCount;
        private set { if (_totalCount != value) { _totalCount = value; OnPropertyChanged(); } }
    }

    public long? SequentialItemId
    {
        get => _sequentialItemId;
        private set { if (_sequentialItemId != value) { _sequentialItemId = value; OnPropertyChanged(); OnSequentialChanged(); } }
    }

    public int SequentialIndex
    {
        get => _sequentialIndex;
        private set { if (_sequentialIndex != value) { _sequentialIndex = value; OnPropertyChanged(); OnSequentialChanged(); } }
    }

    public long? FlashItemId
    {
        get => _flashItemId;
        private set { if (_flashItemId != value) { _flashItemId = value; OnPropertyChanged(); } }
    }

    public string? FlashedCellKey
    {
        get => _flashedCellKey;
        private set { if (_flashedCellKey != value) { _flashedCellKey = value; OnPropertyChanged(); } }
    }

    public ClickAction ClickAction
    {
        get => _settings.ClickAction;
        set { if (_settings.ClickAction != value) { _settings.ClickAction = value; OnPropertyChanged(); } }
    }

    public bool AlwaysOnTop
    {
        get => _settings.AlwaysOnTop;
        set { if (_settings.AlwaysOnTop != value) { _settings.AlwaysOnTop = value; OnPropertyChanged(); AlwaysOnTopChanged?.Invoke(value); } }
    }

    public bool ClearIncludesPinned
    {
        get => _settings.ClearIncludesPinned;
        set { if (_settings.ClearIncludesPinned != value) { _settings.ClearIncludesPinned = value; OnPropertyChanged(); } }
    }

    public int HistoryLimit
    {
        get => _settings.HistoryLimit;
        set { if (_settings.HistoryLimit != value) { _settings.HistoryLimit = value; OnPropertyChanged(); } }
    }

    public bool LaunchAtLoginEnabled
    {
        get => LaunchAtLogin.IsEnabled;
        set
        {
            if (LaunchAtLogin.SetEnabled(value))
                OnPropertyChanged();
        }
    }

    public IReadOnlyList<string> SequentialSegments
    {
        get
        {
            if (_sequentialItemId is null) return [];
            var item = Items.FirstOrDefault(x => x.Id == _sequentialItemId)
                ?? _store.Fetch(ClipboardKind.LongText, null, 1000).FirstOrDefault(x => x.Id == _sequentialItemId)
                ?? _store.Fetch(ClipboardKind.ShortText, null, 1000).FirstOrDefault(x => x.Id == _sequentialItemId);
            return item?.Paragraphs ?? [];
        }
    }

    public string SequentialCurrentSegment
    {
        get
        {
            var segs = SequentialSegments;
            if (_sequentialIndex < 0 || _sequentialIndex >= segs.Count) return string.Empty;
            return segs[_sequentialIndex];
        }
    }

    public string? SequentialNextSegment
    {
        get
        {
            var segs = SequentialSegments;
            int next = _sequentialIndex + 1;
            return next >= 0 && next < segs.Count ? segs[next] : null;
        }
    }

    public event Action<bool>? AlwaysOnTopChanged;
    public event Action<ClipboardItem>? PinItemRequested;
    public event Action? PinCurrentRequested;
    public event Action<string>? QuickLookImageRequested;
    public event Action? RequestHideMainWindow;

    public event PropertyChangedEventHandler? PropertyChanged;

    public ClipboardViewModel(
        HistoryStore store,
        AppSettingsStore settings,
        ClipboardMonitor monitor,
        PasteInjector injector,
        ExternalAppTracker appTracker)
    {
        _store = store;
        _settings = settings;
        _monitor = monitor;
        _injector = injector;
        _appTracker = appTracker;

        _searchDebounceTimer = new DispatcherTimer
        {
            Interval = TimeSpan.FromMilliseconds(120)
        };
        _searchDebounceTimer.Tick += (_, _) =>
        {
            _searchDebounceTimer.Stop();
            Reload();
        };

        _monitor.OnChanged += _ => ScheduleReload();
        Reload();
    }

    public void ScheduleReload()
    {
        if (_reloadScheduled) return;
        _reloadScheduled = true;
        Application.Current?.Dispatcher.BeginInvoke(() =>
        {
            _reloadScheduled = false;
            Reload();
        }, DispatcherPriority.Background);
    }

    public void Reload()
    {
        var fetched = _store.Fetch(_tab, _searchText, 1000);
        Items.Clear();
        foreach (var item in fetched)
            Items.Add(item);

        TotalCount = _store.Count(_tab, _searchText);
        OnSequentialChanged();
    }

    public void ActivateItem(ClipboardItem item)
    {
        if (SequentialItemId == item.Id)
        {
            ActivateSequential(item);
            return;
        }

        WriteBack(item);
        FlashItem(item.Id);

        if (ClickAction == ClickAction.Paste)
            _ = PasteToExternalAsync(closeWindow: !AlwaysOnTop);
    }

    public void CopyItem(ClipboardItem item)
    {
        WriteBack(item);
        FlashItem(item.Id);
    }

    public void PasteSegment(string segment)
    {
        _monitor.WriteText(segment);
        _ = PasteToExternalAsync(closeWindow: !AlwaysOnTop);
    }

    public void CopyText(string text)
    {
        _monitor.WriteText(text);
    }

    public void ToggleSequential(ClipboardItem item)
    {
        if (item.Paragraphs.Count < 2) return;
        if (SequentialItemId == item.Id)
        {
            ResetSequential();
            return;
        }

        _sequentialItemId = item.Id;
        _sequentialIndex = 0;
        _monitor.WriteText(item.Paragraphs[0]);
        OnPropertyChanged(nameof(SequentialItemId));
        OnPropertyChanged(nameof(SequentialIndex));
        OnSequentialChanged();
    }

    public void StepSequential(int delta)
    {
        var segs = SequentialSegments;
        if (segs.Count == 0) return;
        int next = Math.Clamp(_sequentialIndex + delta, 0, segs.Count - 1);
        if (next == _sequentialIndex) return;
        SequentialIndex = next;
        _monitor.WriteText(segs[next]);
    }

    public void ResetSequential()
    {
        _sequentialItemId = null;
        _sequentialIndex = 0;
        OnPropertyChanged(nameof(SequentialItemId));
        OnPropertyChanged(nameof(SequentialIndex));
        OnSequentialChanged();
    }

    public void HandleUserCtrlV(bool inSelfApp)
    {
        if (SequentialItemId is not long seqId) return;
        var segs = SequentialSegments;
        if (segs.Count == 0)
        {
            ResetSequential();
            return;
        }

        FlashItem(seqId);
        int cur = SequentialIndex;

        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(100) };
        timer.Tick += (_, _) =>
        {
            timer.Stop();
            if (SequentialItemId != seqId) return;
            if (cur + 1 >= segs.Count)
            {
                ResetSequential();
            }
            else
            {
                SequentialIndex = cur + 1;
                _monitor.WriteText(segs[cur + 1]);
            }
        };
        timer.Start();
    }

    public void ActivateSequential(ClipboardItem item)
    {
        var now = DateTime.UtcNow;
        if ((now - _lastSeqClickUtc).TotalMilliseconds < 250) return;
        _lastSeqClickUtc = now;

        var segs = item.Paragraphs;
        if (segs.Count == 0) return;
        int cur = Math.Clamp(SequentialIndex, 0, segs.Count - 1);

        _monitor.WriteText(segs[cur]);
        FlashItem(item.Id);

        _ = PasteAndAdvanceSequentialAsync(item.Id, cur, segs);
    }

    public void PasteNextSequentialFromHotKey()
    {
        if (SequentialItemId is not long id) return;
        var item = Items.FirstOrDefault(x => x.Id == id)
            ?? _store.Fetch(ClipboardKind.LongText, null, 1000).FirstOrDefault(x => x.Id == id)
            ?? _store.Fetch(ClipboardKind.ShortText, null, 1000).FirstOrDefault(x => x.Id == id);
        if (item == null) return;
        ActivateSequential(item);
    }

    private async Task PasteAndAdvanceSequentialAsync(long itemId, int cur, IReadOnlyList<string> segs)
    {
        await _injector.PasteToTargetAsync(_appTracker, waitModifierRelease: true, ensureTargetForeground: !AlwaysOnTop);
        await Task.Delay(280);
        Application.Current?.Dispatcher.Invoke(() =>
        {
            if (SequentialItemId != itemId) return;
            if (cur + 1 >= segs.Count)
            {
                ResetSequential();
            }
            else
            {
                SequentialIndex = cur + 1;
                _monitor.WriteText(segs[cur + 1]);
            }
        });
    }

    private async Task PasteToExternalAsync(bool closeWindow)
    {
        if (closeWindow)
            RequestHideMainWindow?.Invoke();
        await _injector.PasteToTargetAsync(_appTracker, waitModifierRelease: true, ensureTargetForeground: true);
    }

    public void WriteBack(ClipboardItem item)
    {
        switch (item.Kind)
        {
            case ClipboardKind.Image when !string.IsNullOrEmpty(item.DataPath) && File.Exists(item.DataPath):
                _monitor.WritePngBytes(File.ReadAllBytes(item.DataPath));
                break;

            case ClipboardKind.Table:
                var rows = ParseTableRows(item);
                string html = rows != null ? TableParser.HtmlTable(rows) : $"<pre>{TableParser.EscapeHtml(item.Content)}</pre>";
                _monitor.WriteTable(item.Content, html);
                break;

            default:
                _monitor.WriteText(item.Content);
                break;
        }
    }

    public void SetPinned(ClipboardItem item, bool pinned)
    {
        _store.SetPinned(item.Id, pinned);
        Reload();
    }

    public void DeleteItem(ClipboardItem item)
    {
        if (SequentialItemId == item.Id)
            ResetSequential();
        _store.Delete(item.Id);
        Reload();
    }

    public void ClearHistory()
    {
        ResetSequential();
        _store.ClearAll(keepPinned: !ClearIncludesPinned);
        Reload();
    }

    public void PinItem(ClipboardItem item) => PinItemRequested?.Invoke(item);
    public void PinCurrentOrLatest() => PinCurrentRequested?.Invoke();
    public void OpenQuickLook(string imagePath) => QuickLookImageRequested?.Invoke(imagePath);

    public string[][] ParseTableRows(ClipboardItem item)
    {
        if (!string.IsNullOrEmpty(item.TableJson))
        {
            try
            {
                var parsed = JsonSerializer.Deserialize<string[][]>(item.TableJson);
                if (parsed is { Length: > 0 })
                    return parsed;
            }
            catch { }
        }
        return TableParser.ParseTsv(item.Content) ?? [[item.Content]];
    }

    public void CopyTableCell(long itemId, string[][] rows, int r, int c)
    {
        if (r < 0 || r >= rows.Length || c < 0 || c >= rows[r].Length) return;
        _monitor.WriteText(rows[r][c]);
        FlashCell($"{itemId}:{r}:{c}");
    }

    public void CopyTableRow(long itemId, string[][] rows, int r)
    {
        if (r < 0 || r >= rows.Length) return;
        var slice = new[] { rows[r] };
        _monitor.WriteTable(TableParser.CanonicalTsv(slice), TableParser.HtmlTable(slice));
        FlashItem(itemId);
    }

    public void CopyTableColumn(long itemId, string[][] rows, int c)
    {
        var slice = rows.Select(row => new[] { c < row.Length ? row[c] : string.Empty }).ToArray();
        _monitor.WriteTable(TableParser.CanonicalTsv(slice), TableParser.HtmlTable(slice));
        FlashItem(itemId);
    }

    public void CopyTableRegion(long itemId, string[][] rows, int r1, int c1, int r2, int c2)
    {
        int rMin = Math.Clamp(Math.Min(r1, r2), 0, rows.Length - 1);
        int rMax = Math.Clamp(Math.Max(r1, r2), 0, rows.Length - 1);
        int cMin = Math.Min(c1, c2);
        int cMax = Math.Max(c1, c2);

        var slice = new List<string[]>(rMax - rMin + 1);
        for (int r = rMin; r <= rMax; r++)
        {
            var outRow = new string[cMax - cMin + 1];
            for (int c = cMin; c <= cMax; c++)
                outRow[c - cMin] = c >= 0 && c < rows[r].Length ? rows[r][c] : string.Empty;
            slice.Add(outRow);
        }
        var arr = slice.ToArray();
        _monitor.WriteTable(TableParser.CanonicalTsv(arr), TableParser.HtmlTable(arr));
        FlashItem(itemId);
    }

    public void FlashItem(long id)
    {
        FlashItemId = id;
        var t = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(450) };
        t.Tick += (_, _) =>
        {
            t.Stop();
            if (FlashItemId == id) FlashItemId = null;
        };
        t.Start();
    }

    public void FlashCell(string key)
    {
        FlashedCellKey = key;
        var t = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(450) };
        t.Tick += (_, _) =>
        {
            t.Stop();
            if (FlashedCellKey == key) FlashedCellKey = null;
        };
        t.Start();
    }

    private void OnSequentialChanged()
    {
        OnPropertyChanged(nameof(SequentialSegments));
        OnPropertyChanged(nameof(SequentialCurrentSegment));
        OnPropertyChanged(nameof(SequentialNextSegment));
    }

    private void OnPropertyChanged([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

    public void Dispose()
    {
        _searchDebounceTimer.Stop();
    }
}
