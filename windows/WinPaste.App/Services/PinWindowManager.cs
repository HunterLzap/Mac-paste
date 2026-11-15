using System.IO;
using SkiaSharp;
using WinPaste.App.Windows;
using WinPaste.Core.Imaging;
using WinPaste.Core.Models;
using WinPaste.Core.OCR;
using WinPaste.Core.Storage;
using WinPaste.Core.Translation;

namespace WinPaste.App.Services;

public sealed class PinWindowManager
{
    private readonly ClipboardMonitor _clipboardMonitor;
    private readonly HistoryStore _historyStore;
    private readonly ClipboardViewModel _viewModel;
    private readonly IOcrEngine _ocrEngine;
    private readonly IEnglishSpellChecker _spellChecker;
    private readonly TranslationService _translator;
    private readonly AppSettingsStore _settings;

    private readonly List<PinWindow> _pins = [];
    private bool _allHidden;

    public PinWindowManager(
        ClipboardMonitor clipboardMonitor,
        HistoryStore historyStore,
        ClipboardViewModel viewModel,
        IOcrEngine ocrEngine,
        IEnglishSpellChecker spellChecker,
        TranslationService translator,
        AppSettingsStore settings)
    {
        _clipboardMonitor = clipboardMonitor;
        _historyStore = historyStore;
        _viewModel = viewModel;
        _ocrEngine = ocrEngine;
        _spellChecker = spellChecker;
        _translator = translator;
        _settings = settings;
    }

    public void PinImage(SKBitmap bitmap, ScreenshotRect? initialPhysRect = null)
    {
        var pin = new PinWindow(
            PinWindow.PinKind.Image,
            _clipboardMonitor,
            _ocrEngine,
            _spellChecker,
            _translator,
            _settings,
            bitmap: bitmap,
            initialPhysRect: initialPhysRect);
        TrackAndShow(pin);
    }

    public void PinText(string text)
    {
        var pin = new PinWindow(
            PinWindow.PinKind.Text,
            _clipboardMonitor,
            _ocrEngine,
            _spellChecker,
            _translator,
            _settings,
            text: text);
        TrackAndShow(pin);
    }

    public void PinTable(string[][] rows)
    {
        var pin = new PinWindow(
            PinWindow.PinKind.Table,
            _clipboardMonitor,
            _ocrEngine,
            _spellChecker,
            _translator,
            _settings,
            tableRows: rows);
        TrackAndShow(pin);
    }

    public void PinImageFile(string path)
    {
        if (!File.Exists(path)) return;
        var bmp = SKBitmap.Decode(path);
        if (bmp != null)
            PinImage(bmp);
    }

    public void PinClipboardItem(ClipboardItem item)
    {
        if (item.Kind == ClipboardKind.Image && !string.IsNullOrEmpty(item.DataPath))
        {
            PinImageFile(item.DataPath);
        }
        else if (item.Kind == ClipboardKind.Table)
        {
            PinTable(_viewModel.ParseTableRows(item));
        }
        else
        {
            PinText(item.Content);
        }
    }

    public void PinCurrentClipboardOrLatest()
    {
        byte[]? imgPng = _clipboardMonitor.TryReadCurrentImagePng();
        if (imgPng is { Length: > 0 })
        {
            var bmp = SKBitmap.Decode(imgPng);
            if (bmp != null)
            {
                PinImage(bmp);
                return;
            }
        }

        string? curText = _clipboardMonitor.TryReadCurrentText();
        if (!string.IsNullOrWhiteSpace(curText))
        {
            if (curText.Contains('\t') && Core.Parsing.TableParser.LooksLikeTsv(curText))
            {
                var rows = Core.Parsing.TableParser.ParseTsv(curText);
                if (rows is { Length: >= 2 })
                {
                    PinTable(rows);
                    return;
                }
            }
            PinText(curText);
            return;
        }

        // 回退到历史记录最新一条
        ClipboardKind[] order = [ClipboardKind.Image, ClipboardKind.ShortText, ClipboardKind.LongText, ClipboardKind.Table];
        var latest = order
            .SelectMany(k => _historyStore.Fetch(k, null, 1))
            .OrderByDescending(i => i.CreatedAt)
            .FirstOrDefault();

        if (latest != null)
            PinClipboardItem(latest);
    }

    public void ToggleAllVisibility()
    {
        if (_pins.Count == 0) return;
        _allHidden = !_allHidden;
        foreach (var pin in _pins.ToList())
        {
            pin.IsHiddenByGlobalToggle = _allHidden;
            if (_allHidden)
                pin.HideWithToolbar();
            else
                pin.Show();
        }
    }

    public void CloseAll()
    {
        foreach (var pin in _pins.ToList())
            pin.Close();
        _pins.Clear();
    }

    private void TrackAndShow(PinWindow pin)
    {
        _allHidden = false;
        // 连续多张贴图错开 24px 避免完全重叠
        if (_pins.Count > 0 && pin.WindowStartupLocation == System.Windows.WindowStartupLocation.Manual)
        {
            double offset = (_pins.Count % 6) * 24;
            pin.Left += offset;
            pin.Top += offset;
        }
        _pins.Add(pin);
        pin.PinClosed += closed => _pins.Remove(closed);
        pin.Show();
    }
}
