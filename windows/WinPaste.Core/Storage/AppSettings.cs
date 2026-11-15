using System.Text.Json;
using WinPaste.Core.Models;

namespace WinPaste.Core.Storage;

public enum ClickAction
{
    Copy = 0,
    Paste = 1
}

public sealed class AppSettingsData
{
    public int HistoryLimit { get; set; } = 500;
    public ClickAction ClickAction { get; set; } = ClickAction.Copy;
    public bool AlwaysOnTop { get; set; }
    public bool ClearIncludesPinned { get; set; }
    public double PreviewWidth { get; set; } = 400;
    public double PreviewHeight { get; set; } = 300;
    public double? MainWindowLeft { get; set; }
    public double? MainWindowTop { get; set; }
    public double MainWindowWidth { get; set; } = 460;
    public double MainWindowHeight { get; set; } = 600;
    public string TargetLanguageId { get; set; } = "zh-Hans";
}

public sealed class AppSettingsStore
{
    private readonly string _settingsPath;
    private readonly object _gate = new();
    private AppSettingsData _data;

    public AppSettingsStore(AppPaths? paths = null)
    {
        var p = paths ?? AppPaths.Default;
        p.EnsureDirectories();
        _settingsPath = p.SettingsPath;
        _data = LoadInternal();
    }

    public AppSettingsData Snapshot
    {
        get
        {
            lock (_gate)
            {
                return new AppSettingsData
                {
                    HistoryLimit = _data.HistoryLimit,
                    ClickAction = _data.ClickAction,
                    AlwaysOnTop = _data.AlwaysOnTop,
                    ClearIncludesPinned = _data.ClearIncludesPinned,
                    PreviewWidth = _data.PreviewWidth,
                    PreviewHeight = _data.PreviewHeight,
                    MainWindowLeft = _data.MainWindowLeft,
                    MainWindowTop = _data.MainWindowTop,
                    MainWindowWidth = _data.MainWindowWidth,
                    MainWindowHeight = _data.MainWindowHeight,
                    TargetLanguageId = _data.TargetLanguageId
                };
            }
        }
    }

    public int HistoryLimit
    {
        get { lock (_gate) return _data.HistoryLimit; }
        set => Update(d => d.HistoryLimit = Math.Clamp(value, 100, 5000));
    }

    public ClickAction ClickAction
    {
        get { lock (_gate) return _data.ClickAction; }
        set => Update(d => d.ClickAction = value);
    }

    public bool AlwaysOnTop
    {
        get { lock (_gate) return _data.AlwaysOnTop; }
        set => Update(d => d.AlwaysOnTop = value);
    }

    public bool ClearIncludesPinned
    {
        get { lock (_gate) return _data.ClearIncludesPinned; }
        set => Update(d => d.ClearIncludesPinned = value);
    }

    public double PreviewWidth
    {
        get { lock (_gate) return Math.Clamp(_data.PreviewWidth, 280, 700); }
        set => Update(d => d.PreviewWidth = Math.Clamp(value, 280, 700));
    }

    public double PreviewHeight
    {
        get { lock (_gate) return Math.Clamp(_data.PreviewHeight, 120, 700); }
        set => Update(d => d.PreviewHeight = Math.Clamp(value, 120, 700));
    }

    public string TargetLanguageId
    {
        get { lock (_gate) return _data.TargetLanguageId; }
        set => Update(d => d.TargetLanguageId = string.IsNullOrWhiteSpace(value) ? "zh-Hans" : value);
    }

    public void SaveMainWindowBounds(double left, double top, double width, double height)
    {
        Update(d =>
        {
            d.MainWindowLeft = left;
            d.MainWindowTop = top;
            d.MainWindowWidth = Math.Max(320, width);
            d.MainWindowHeight = Math.Max(360, height);
        });
    }

    public void Update(Action<AppSettingsData> mutator)
    {
        lock (_gate)
        {
            mutator(_data);
            SaveInternal(_data);
        }
    }

    private AppSettingsData LoadInternal()
    {
        try
        {
            if (File.Exists(_settingsPath))
            {
                var json = File.ReadAllText(_settingsPath);
                var parsed = JsonSerializer.Deserialize<AppSettingsData>(json);
                if (parsed is not null)
                {
                    parsed.HistoryLimit = Math.Clamp(parsed.HistoryLimit, 100, 5000);
                    parsed.PreviewWidth = Math.Clamp(parsed.PreviewWidth, 280, 700);
                    parsed.PreviewHeight = Math.Clamp(parsed.PreviewHeight, 120, 700);
                    parsed.MainWindowWidth = Math.Max(320, parsed.MainWindowWidth);
                    parsed.MainWindowHeight = Math.Max(360, parsed.MainWindowHeight);
                    return parsed;
                }
            }
        }
        catch
        {
            // Corrupted settings file falls back cleanly to defaults.
        }
        return new AppSettingsData();
    }

    private void SaveInternal(AppSettingsData data)
    {
        try
        {
            var dir = Path.GetDirectoryName(_settingsPath);
            if (!string.IsNullOrEmpty(dir))
                Directory.CreateDirectory(dir);
            var json = JsonSerializer.Serialize(data, new JsonSerializerOptions { WriteIndented = true });
            var tmp = _settingsPath + ".tmp";
            File.WriteAllText(tmp, json);
            File.Move(tmp, _settingsPath, overwrite: true);
        }
        catch
        {
            // Ignore transient IO failures.
        }
    }
}
