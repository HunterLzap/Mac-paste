using System.Collections.Specialized;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using SkiaSharp;
using WinPaste.App.Interop;
using WinPaste.Core.Models;
using WinPaste.Core.Parsing;
using WinPaste.Core.Storage;

namespace WinPaste.App.Services;

/// <summary>
/// 剪贴板监听器：
/// 主通道使用 Win32 AddClipboardFormatListener（零轮询开销），辅以 500ms 序号兜底；
/// 并提供写回剪贴板与防自写循环屏蔽。
/// </summary>
public sealed partial class ClipboardMonitor : IDisposable
{
    private readonly ClipboardIngestor _ingestor;
    private readonly DispatcherTimer _fallbackTimer;
    private HwndSource? _hwndSource;
    private uint _lastSequenceNumber;
    private bool _running;

    public event Action<ClipboardKind>? OnChanged;

    [GeneratedRegex(@"<!--StartFragment-->(.*?)<!--EndFragment-->", RegexOptions.Singleline | RegexOptions.IgnoreCase)]
    private static partial Regex CfHtmlFragmentRegex();

    public ClipboardMonitor(ClipboardIngestor ingestor)
    {
        _ingestor = ingestor;
        _fallbackTimer = new DispatcherTimer(DispatcherPriority.Background)
        {
            Interval = TimeSpan.FromMilliseconds(500)
        };
        _fallbackTimer.Tick += (_, _) => CheckClipboard();
    }

    public void Start()
    {
        if (_running) return;
        _running = true;

        if (OperatingSystem.IsWindows())
        {
            var parameters = new HwndSourceParameters("WinPasteClipboardSink")
            {
                Width = 0,
                Height = 0,
                ParentWindow = new nint(-3) // HWND_MESSAGE
            };
            _hwndSource = new HwndSource(parameters);
            _hwndSource.AddHook(WndProc);
            NativeMethods.AddClipboardFormatListener(_hwndSource.Handle);
        }

        _lastSequenceNumber = SafeGetSequenceNumber();
        _fallbackTimer.Start();
    }

    public void MarkInternalWrite(string? text = null)
    {
        uint seq = SafeGetSequenceNumber();
        _lastSequenceNumber = seq;
        _ingestor.MarkInternalWrite(seq, text);
    }

    public bool WriteText(string text)
    {
        try
        {
            Clipboard.SetDataObject(text, true);
            MarkInternalWrite(text);
            return true;
        }
        catch
        {
            return false;
        }
    }

    public bool WriteTable(string tsv, string htmlFragment)
    {
        try
        {
            var data = new DataObject();
            data.SetData(DataFormats.UnicodeText, tsv);
            data.SetData(DataFormats.Text, tsv);
            data.SetData(DataFormats.Html, BuildCfHtmlPayload(htmlFragment));
            Clipboard.SetDataObject(data, true);
            MarkInternalWrite(tsv);
            return true;
        }
        catch
        {
            return WriteText(tsv);
        }
    }

    public bool WritePngBytes(byte[] pngBytes)
    {
        try
        {
            using var ms = new MemoryStream(pngBytes);
            var decoder = new PngBitmapDecoder(ms, BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnLoad);
            BitmapSource source = decoder.Frames[0];
            source.Freeze();

            var data = new DataObject();
            data.SetImage(source);
            data.SetData("PNG", new MemoryStream(pngBytes), autoConvert: false);
            Clipboard.SetDataObject(data, true);
            MarkInternalWrite();
            return true;
        }
        catch
        {
            return false;
        }
    }

    public bool WriteBitmap(SKBitmap bitmap)
    {
        using var image = SKImage.FromBitmap(bitmap);
        using var encoded = image.Encode(SKEncodedImageFormat.Png, 100);
        return WritePngBytes(encoded.ToArray());
    }

    public byte[]? TryReadCurrentImagePng()
    {
        try
        {
            if (Clipboard.ContainsData("PNG"))
            {
                if (Clipboard.GetData("PNG") is MemoryStream ms)
                    return ms.ToArray();
                if (Clipboard.GetData("PNG") is byte[] raw)
                    return raw;
            }
            if (Clipboard.ContainsImage())
            {
                var img = Clipboard.GetImage();
                if (img != null)
                {
                    var encoder = new PngBitmapEncoder();
                    encoder.Frames.Add(BitmapFrame.Create(img));
                    using var outStream = new MemoryStream();
                    encoder.Save(outStream);
                    return outStream.ToArray();
                }
            }
        }
        catch { }
        return null;
    }

    public string? TryReadCurrentText()
    {
        try
        {
            return Clipboard.ContainsText() ? Clipboard.GetText() : null;
        }
        catch { return null; }
    }

    private nint WndProc(nint hwnd, int msg, nint wParam, nint lParam, ref bool handled)
    {
        if (msg == NativeMethods.WM_CLIPBOARDUPDATE)
        {
            CheckClipboard(forceRead: true);
        }
        return nint.Zero;
    }

    private void CheckClipboard(bool forceRead = false)
    {
        if (!_running) return;
        uint seq = SafeGetSequenceNumber();
        if (!forceRead && seq == _lastSequenceNumber)
            return;

        _lastSequenceNumber = seq;
        if (_ingestor.ShouldIgnoreSequence(seq))
            return;

        try
        {
            string[]? files = null;
            if (Clipboard.ContainsFileDropList())
            {
                StringCollection col = Clipboard.GetFileDropList();
                var list = new List<string>(col.Count);
                foreach (string? item in col)
                {
                    if (!string.IsNullOrWhiteSpace(item))
                        list.Add(item);
                }
                list.Sort(StringComparer.OrdinalIgnoreCase);
                if (list.Count > 0)
                    files = list.ToArray();
            }

            string? html = null;
            if (files == null && Clipboard.ContainsData(DataFormats.Html))
            {
                if (Clipboard.GetData(DataFormats.Html) is string rawHtml)
                    html = ExtractCfHtmlFragment(rawHtml);
            }

            string? text = null;
            if (files == null && Clipboard.ContainsText())
                text = Clipboard.GetText();

            byte[]? imageBytes = null;
            if (files == null && string.IsNullOrEmpty(html) && string.IsNullOrWhiteSpace(text))
                imageBytes = TryReadCurrentImagePng();

            var kind = _ingestor.IngestSnapshot(seq, files, html, text, imageBytes);
            if (kind.HasValue)
                OnChanged?.Invoke(kind.Value);
        }
        catch
        {
            // 剪贴板被其他进程短暂锁定属于正常竞态，下次变更/轮询会自动重试
        }
    }

    private static uint SafeGetSequenceNumber() =>
        OperatingSystem.IsWindows() ? NativeMethods.GetClipboardSequenceNumber() : 0;

    private static string ExtractCfHtmlFragment(string cfHtml)
    {
        var match = CfHtmlFragmentRegex().Match(cfHtml);
        return match.Success ? match.Groups[1].Value : cfHtml;
    }

    private static string BuildCfHtmlPayload(string htmlFragment)
    {
        const string headerTemplate =
            "Version:0.9\r\n" +
            "StartHTML:{0:D10}\r\n" +
            "EndHTML:{1:D10}\r\n" +
            "StartFragment:{2:D10}\r\n" +
            "EndFragment:{3:D10}\r\n";

        const string prefix = "<html><body>\r\n<!--StartFragment-->";
        const string suffix = "<!--EndFragment-->\r\n</body></html>";

        string dummyHeader = string.Format(headerTemplate, 0, 0, 0, 0);
        int headerByteCount = Encoding.UTF8.GetByteCount(dummyHeader);
        int prefixByteCount = Encoding.UTF8.GetByteCount(prefix);
        int fragmentByteCount = Encoding.UTF8.GetByteCount(htmlFragment);
        int suffixByteCount = Encoding.UTF8.GetByteCount(suffix);

        int startHtml = headerByteCount;
        int startFragment = startHtml + prefixByteCount;
        int endFragment = startFragment + fragmentByteCount;
        int endHtml = endFragment + suffixByteCount;

        string header = string.Format(headerTemplate, startHtml, endHtml, startFragment, endFragment);
        return header + prefix + htmlFragment + suffix;
    }

    public void Dispose()
    {
        _running = false;
        _fallbackTimer.Stop();
        if (_hwndSource != null)
        {
            if (OperatingSystem.IsWindows())
                NativeMethods.RemoveClipboardFormatListener(_hwndSource.Handle);
            _hwndSource.Dispose();
            _hwndSource = null;
        }
    }
}
