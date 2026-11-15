using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;
using Microsoft.Win32;
using SkiaSharp;
using SkiaSharp.Views.Desktop;
using SkiaSharp.Views.WPF;
using WinPaste.App.Interop;
using WinPaste.App.Services;
using WinPaste.Core.Imaging;
using WinPaste.Core.OCR;
using WinPaste.Core.Storage;
using WinPaste.Core.Translation;

namespace WinPaste.App.Windows;

public partial class ScreenshotOverlayWindow : Window
{
    public enum OverlayCompletionAction
    {
        Cancelled,
        Copied,
        Saved,
        Pinned,
        StartScrollCapture
    }

    public sealed record CompletionResult(
        OverlayCompletionAction Action,
        SKBitmap? CroppedBitmap,
        ScreenshotRect PhysicalSelectionRect,
        IReadOnlyList<InPlaceTranslatedBlock>? TranslatedBlocks = null);

    private readonly SKBitmap _screenBitmap;
    private readonly ScreenBitmapSampler _sampler;
    private readonly int _virtualLeft;
    private readonly int _virtualTop;
    private readonly int _virtualWidth;
    private readonly int _virtualHeight;

    private readonly IOcrEngine _ocrEngine;
    private readonly IEnglishSpellChecker _spellChecker;
    private readonly TranslationService _translator;
    private readonly AppSettingsStore _settings;

    private ScreenshotRect? _selectionRect;
    private bool _hasFinishedInitialDrag;
    private ScreenshotPoint _dragStartPhys;
    private ScreenshotPoint _currentMousePhys;
    private bool _mouseMovedDuringCapture;

    private enum DragMode { None, CreatingSelection, MovingSelection, ResizingSelection, DrawingAnnotation, MovingAnnotation, ResizingAnnotation }
    private DragMode _dragMode = DragMode.None;
    private ResizeHandle _activeResizeHandle;
    private ScreenshotRect _resizeOriginRect;
    private ScreenshotPoint _moveOffsetFromOrigin;

    private ScreenshotTool? _activeTool;
    private ScreenshotColor _activeColor = ScreenshotPalette.SwatchColors[0];
    private double _activeLineWidth = ScreenshotPalette.StrokeWidths[1].Width;

    private readonly List<ScreenshotAnnotation> _annotations = [];
    private readonly Stack<List<ScreenshotAnnotation>> _undoStack = new();
    private readonly Stack<List<ScreenshotAnnotation>> _redoStack = new();
    private ScreenshotAnnotation? _draftAnnotation;
    private int? _selectedAnnotationIdx;
    private AnnotationHandle _activeAnnHandle;
    private ScreenshotPoint _annDragLastPhys;

    private ScreenshotPoint? _pendingTextPoint;
    private bool _translating;
    private bool _showTranslated = true;
    private List<InPlaceTranslatedBlock>? _translatedBlocks;

    private readonly DispatcherTimer _toastTimer;
    public CompletionResult? Result { get; private set; }

    public ScreenshotOverlayWindow(
        SKBitmap virtualScreenBitmap,
        int virtualLeft,
        int virtualTop,
        IOcrEngine ocrEngine,
        IEnglishSpellChecker spellChecker,
        TranslationService translator,
        AppSettingsStore settings)
    {
        InitializeComponent();
        _screenBitmap = virtualScreenBitmap;
        _sampler = new ScreenBitmapSampler(virtualScreenBitmap);
        _virtualLeft = virtualLeft;
        _virtualTop = virtualTop;
        _virtualWidth = virtualScreenBitmap.Width;
        _virtualHeight = virtualScreenBitmap.Height;
        _ocrEngine = ocrEngine;
        _spellChecker = spellChecker;
        _translator = translator;
        _settings = settings;

        _toastTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1.8) };
        _toastTimer.Tick += (_, _) =>
        {
            _toastTimer.Stop();
            ToastBadge.Visibility = Visibility.Collapsed;
        };

        BuildStyleSubBar();
        InitLanguageCombo();
    }

    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        if (OperatingSystem.IsWindows())
        {
            nint hwnd = new WindowInteropHelper(this).Handle;
            NativeMethods.SetWindowPos(
                hwnd,
                NativeMethods.HWND_TOPMOST,
                _virtualLeft,
                _virtualTop,
                _virtualWidth,
                _virtualHeight,
                NativeMethods.SWP_SHOWWINDOW);
        }
    }

    private void InitLanguageCombo()
    {
        LanguageCombo.ItemsSource = TranslationService.CommonTargetLanguages;
        LanguageCombo.DisplayMemberPath = "Name";
        var saved = TranslationService.CommonTargetLanguages.FirstOrDefault(l => l.Id == _settings.TargetLanguageId)
            ?? TranslationService.CommonTargetLanguages[0];
        LanguageCombo.SelectedItem = saved;
    }

    private void BuildStyleSubBar()
    {
        ColorSwatchesHost.Children.Clear();
        foreach (var c in ScreenshotPalette.SwatchColors)
        {
            var swatchColor = c;
            var btn = new Button
            {
                Width = 20,
                Height = 20,
                Margin = new Thickness(2, 0, 2, 0),
                Padding = new Thickness(0),
                Style = (Style)FindResource("TactileButtonStyle"),
                Tag = swatchColor,
                Content = new Border
                {
                    Width = 14,
                    Height = 14,
                    CornerRadius = new CornerRadius(7),
                    Background = new SolidColorBrush(Color.FromRgb(swatchColor.R, swatchColor.G, swatchColor.B)),
                    BorderBrush = swatchColor.R > 240 && swatchColor.G > 240 ? Brushes.Gray : Brushes.Transparent,
                    BorderThickness = new Thickness(1)
                }
            };
            btn.Click += (_, _) =>
            {
                _activeColor = swatchColor;
                RefreshStyleSubBarHighlights();
            };
            ColorSwatchesHost.Children.Add(btn);
        }

        StrokeWidthsHost.Children.Clear();
        foreach (var (label, width) in ScreenshotPalette.StrokeWidths)
        {
            double w = width;
            var btn = new Button
            {
                Content = label,
                Margin = new Thickness(2, 0, 2, 0),
                Padding = new Thickness(6, 2, 6, 2),
                FontSize = 11,
                Style = (Style)FindResource("TactileButtonStyle"),
                Tag = w
            };
            btn.Click += (_, _) =>
            {
                _activeLineWidth = w;
                RefreshStyleSubBarHighlights();
            };
            StrokeWidthsHost.Children.Add(btn);
        }

        RefreshStyleSubBarHighlights();
    }

    private void RefreshStyleSubBarHighlights()
    {
        var soft = (Brush)FindResource("AccentSoftBrush");
        foreach (Button b in ColorSwatchesHost.Children)
        {
            bool active = b.Tag is ScreenshotColor sc && sc == _activeColor;
            b.Background = active ? soft : Brushes.Transparent;
        }
        foreach (Button b in StrokeWidthsHost.Children)
        {
            bool active = b.Tag is double w && Math.Abs(w - _activeLineWidth) < 0.1;
            b.Background = active ? soft : Brushes.Transparent;
        }
    }

    private ScreenshotPoint GetPhysicalPoint(MouseEventArgs e)
    {
        var pt = e.GetPosition(RootGrid);
        var screenPx = RootGrid.PointToScreen(pt);
        return new ScreenshotPoint(
            Math.Clamp(screenPx.X - _virtualLeft, 0, _virtualWidth),
            Math.Clamp(screenPx.Y - _virtualTop, 0, _virtualHeight));
    }

    private Point PhysicalToCanvasDip(double physX, double physY)
    {
        var screenPt = new Point(_virtualLeft + physX, _virtualTop + physY);
        return OverlayCanvas.PointFromScreen(screenPt);
    }

    private void SkiaCanvas_PaintSurface(object? sender, SKPaintSurfaceEventArgs e)
    {
        var canvas = e.Surface.Canvas;
        canvas.Clear(SKColors.Black);

        float scaleX = _virtualWidth > 0 ? (float)e.Info.Width / _virtualWidth : 1f;
        float scaleY = _virtualHeight > 0 ? (float)e.Info.Height / _virtualHeight : 1f;
        canvas.Save();
        canvas.Scale(scaleX, scaleY);

        // 1. 全屏冻帧底图
        canvas.DrawBitmap(_screenBitmap, 0, 0);

        if (_selectionRect is ScreenshotRect sel && !sel.IsEmpty)
        {
            // 2. 选区外遮罩（evenodd path difference）
            using var maskPath = new SKPath { FillType = SKPathFillType.EvenOdd };
            maskPath.AddRect(new SKRect(0, 0, _virtualWidth, _virtualHeight));
            maskPath.AddRect(sel.ToSKRect());
            using var maskPaint = new SKPaint { Color = new SKColor(26, 36, 56, 66), Style = SKPaintStyle.Fill };
            canvas.DrawPath(maskPath, maskPaint);

            // 3. 选区内部：原位翻译覆盖层 + 标注层（裁剪在选区内部防止外溢）
            canvas.Save();
            canvas.ClipRect(sel.ToSKRect());

            if (_showTranslated && _translatedBlocks is { Count: > 0 })
                ScreenshotRenderer.DrawInPlaceTranslationBlocks(canvas, _translatedBlocks, sel);

            ScreenshotRenderer.DrawAnnotations(canvas, _annotations, _sampler);
            if (_draftAnnotation != null)
                ScreenshotRenderer.DrawAnnotation(canvas, _draftAnnotation, _sampler);

            if (_selectedAnnotationIdx is int selIdx && selIdx >= 0 && selIdx < _annotations.Count)
                DrawSelectedAnnotationHandles(canvas, _annotations[selIdx]);

            canvas.Restore();

            // 4. 选区高亮边框与 8 控制点
            using var borderPaint = new SKPaint
            {
                IsAntialias = true,
                Style = SKPaintStyle.Stroke,
                StrokeWidth = 1.8f,
                Color = new SKColor(0x00, 0x7A, 0xFF)
            };
            canvas.DrawRect(sel.ToSKRect(), borderPaint);

            DrawSelectionHandles(canvas, sel);
            DrawSelectionDimensionBadge(canvas, sel);
        }
        else
        {
            // 未框选时全屏轻暗化
            using var fullMask = new SKPaint { Color = new SKColor(26, 36, 56, 66), Style = SKPaintStyle.Fill };
            canvas.DrawRect(0, 0, _virtualWidth, _virtualHeight, fullMask);
        }

        // 5. 放大镜 HUD（初始移动或拖拽选区时显示，进入标注工具栏后自动隐藏以免遮挡画笔）
        if (_activeTool == null && (_dragMode == DragMode.CreatingSelection || !_hasFinishedInitialDrag))
        {
            DrawMagnifierHud(canvas, _currentMousePhys);
        }

        canvas.Restore();
    }

    private static void DrawSelectionHandles(SKCanvas canvas, ScreenshotRect sel)
    {
        using var fill = new SKPaint { IsAntialias = true, Style = SKPaintStyle.Fill, Color = SKColors.White };
        using var stroke = new SKPaint { IsAntialias = true, Style = SKPaintStyle.Stroke, StrokeWidth = 1.6f, Color = new SKColor(0x00, 0x7A, 0xFF) };

        foreach (var (_, pt) in GetResizeHandlePoints(sel))
        {
            canvas.DrawCircle((float)pt.X, (float)pt.Y, 4.5f, fill);
            canvas.DrawCircle((float)pt.X, (float)pt.Y, 4.5f, stroke);
        }
    }

    private static void DrawSelectedAnnotationHandles(SKCanvas canvas, ScreenshotAnnotation ann)
    {
        var r = ann.GetBoundingRect();
        using var dashPaint = new SKPaint
        {
            IsAntialias = true,
            Style = SKPaintStyle.Stroke,
            StrokeWidth = 1.2f,
            Color = new SKColor(0x00, 0x7A, 0xFF, 200),
            PathEffect = SKPathEffect.CreateDash([5f, 4f], 0f)
        };
        canvas.DrawRect(r.ToSKRect(), dashPaint);

        using var fill = new SKPaint { IsAntialias = true, Style = SKPaintStyle.Fill, Color = SKColors.White };
        using var stroke = new SKPaint { IsAntialias = true, Style = SKPaintStyle.Stroke, StrokeWidth = 1.5f, Color = new SKColor(0x00, 0x7A, 0xFF) };

        ScreenshotPoint[] pts = ann.Tool switch
        {
            ScreenshotTool.Arrow => [ann.StartPoint, ann.EndPoint],
            ScreenshotTool.Rectangle or ScreenshotTool.Ellipse =>
                [new(ann.Rect.Left, ann.Rect.Top), new(ann.Rect.Right, ann.Rect.Top), new(ann.Rect.Left, ann.Rect.Bottom), new(ann.Rect.Right, ann.Rect.Bottom)],
            _ => []
        };
        foreach (var pt in pts)
        {
            canvas.DrawCircle((float)pt.X, (float)pt.Y, 4.5f, fill);
            canvas.DrawCircle((float)pt.X, (float)pt.Y, 4.5f, stroke);
        }
    }

    private static void DrawSelectionDimensionBadge(SKCanvas canvas, ScreenshotRect sel)
    {
        string text = $"{(int)Math.Round(sel.Width)} × {(int)Math.Round(sel.Height)}";
        using var font = new SKFont(SKTypeface.Default, 12f);
        float w = font.MeasureText(text) + 16f;
        const float h = 22f;
        float x = (float)sel.Left;
        float y = (float)(sel.Top >= 28 ? sel.Top - 26 : sel.Top + 6);

        var rect = new SKRect(x, y, x + w, y + h);
        using var bg = new SKPaint { IsAntialias = true, Color = new SKColor(24, 28, 35, 215) };
        canvas.DrawRoundRect(rect, 5, 5, bg);
        using var fg = new SKPaint { IsAntialias = true, Color = SKColors.White };
        canvas.DrawText(text, x + 8f, y + 15.5f, font, fg);
    }

    private void DrawMagnifierHud(SKCanvas canvas, ScreenshotPoint physCursor)
    {
        int px = Math.Clamp((int)Math.Floor(physCursor.X), 0, _virtualWidth - 1);
        int py = Math.Clamp((int)Math.Floor(physCursor.Y), 0, _virtualHeight - 1);
        var centerColor = _sampler.ColorAtInt(px, py);

        const int radius = 6;
        const float cellSize = 9f;
        const int gridDim = radius * 2 + 1;
        float gridW = gridDim * cellSize;
        float hudW = gridW + 12f;
        float hudH = gridW + 46f;

        float hx = (float)physCursor.X + 22f;
        float hy = (float)physCursor.Y + 22f;
        if (hx + hudW > _virtualWidth - 8) hx = (float)physCursor.X - hudW - 18f;
        if (hy + hudH > _virtualHeight - 8) hy = (float)physCursor.Y - hudH - 18f;

        var outer = new SKRect(hx, hy, hx + hudW, hy + hudH);
        using var cardPaint = new SKPaint { IsAntialias = true, Color = new SKColor(20, 24, 32, 235) };
        canvas.DrawRoundRect(outer, 8, 8, cardPaint);

        var grid = _sampler.ExtractMagnifierPatch(px, py, radius);
        float gx0 = hx + 6f;
        float gy0 = hy + 6f;

        using var cellPaint = new SKPaint { IsAntialias = false, Style = SKPaintStyle.Fill };
        for (int r = 0; r < gridDim; r++)
        {
            for (int c = 0; c < gridDim; c++)
            {
                cellPaint.Color = grid[r, c].ToSKColor();
                canvas.DrawRect(gx0 + c * cellSize, gy0 + r * cellSize, cellSize, cellSize, cellPaint);
            }
        }

        // 中心像素高亮十字准星
        float cx = gx0 + radius * cellSize;
        float cy = gy0 + radius * cellSize;
        using var crossPaint = new SKPaint { Style = SKPaintStyle.Stroke, StrokeWidth = 1.5f, Color = new SKColor(0x00, 0x7A, 0xFF) };
        canvas.DrawRect(cx, cy, cellSize, cellSize, crossPaint);

        using var font = new SKFont(SKTypeface.Default, 11f);
        using var txtPaint = new SKPaint { IsAntialias = true, Color = SKColors.White };
        canvas.DrawText($"({px}, {py})  {centerColor.HexString}", hx + 8f, gy0 + gridW + 16f, font, txtPaint);

        using var subPaint = new SKPaint { IsAntialias = true, Color = new SKColor(180, 190, 205) };
        canvas.DrawText("按 C 复制色值", hx + 8f, gy0 + gridW + 32f, font, subPaint);
    }

    private static IEnumerable<(ResizeHandle Handle, ScreenshotPoint Point)> GetResizeHandlePoints(ScreenshotRect r)
    {
        yield return (ResizeHandle.TopLeft, new(r.Left, r.Top));
        yield return (ResizeHandle.Top, new(r.MidX, r.Top));
        yield return (ResizeHandle.TopRight, new(r.Right, r.Top));
        yield return (ResizeHandle.Left, new(r.Left, r.MidY));
        yield return (ResizeHandle.Right, new(r.Right, r.MidY));
        yield return (ResizeHandle.BottomLeft, new(r.Left, r.Bottom));
        yield return (ResizeHandle.Bottom, new(r.MidX, r.Bottom));
        yield return (ResizeHandle.BottomRight, new(r.Right, r.Bottom));
    }

    private static ResizeHandle? HitTestResizeHandle(ScreenshotRect sel, ScreenshotPoint pt)
    {
        foreach (var (h, hp) in GetResizeHandlePoints(sel))
        {
            if (pt.DistanceTo(hp) <= 10.0)
                return h;
        }
        return null;
    }

    private void SkiaCanvas_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        var pt = GetPhysicalPoint(e);
        _currentMousePhys = pt;

        // 若文字框打开中，先提交文字
        if (InlineTextBox.Visibility == Visibility.Visible)
            CommitInlineTextBox();

        // 若双击选区内部且未处于工具编辑模式 → 直接完成截图
        if (e.ClickCount == 2 && _activeTool == null && _selectionRect is ScreenshotRect dblSel && dblSel.Contains(pt))
        {
            FinishWith(OverlayCompletionAction.Copied);
            return;
        }

        if (_selectionRect is not ScreenshotRect sel || !_hasFinishedInitialDrag)
        {
            _dragMode = DragMode.CreatingSelection;
            _dragStartPhys = pt;
            _selectionRect = new ScreenshotRect(pt.X, pt.Y, 1, 1);
            ToolbarHost.Visibility = Visibility.Collapsed;
            SkiaCanvas.CaptureMouse();
            SkiaCanvas.InvalidateVisual();
            return;
        }

        // 工具激活模式下：先命中已有标注手柄或主体
        if (_activeTool.HasValue)
        {
            if (sel.Contains(pt))
            {
                if (_selectedAnnotationIdx is int curIdx && curIdx >= 0 && curIdx < _annotations.Count)
                {
                    if (_annotations[curIdx].HitTestHandle(pt) is AnnotationHandle ah)
                    {
                        PushUndoSnapshot();
                        _dragMode = DragMode.ResizingAnnotation;
                        _activeAnnHandle = ah;
                        SkiaCanvas.CaptureMouse();
                        return;
                    }
                    if (_annotations[curIdx].HitTest(pt))
                    {
                        PushUndoSnapshot();
                        _dragMode = DragMode.MovingAnnotation;
                        _annDragLastPhys = pt;
                        SkiaCanvas.CaptureMouse();
                        return;
                    }
                }

                for (int i = _annotations.Count - 1; i >= 0; i--)
                {
                    if (_annotations[i].HitTest(pt))
                    {
                        _selectedAnnotationIdx = i;
                        PushUndoSnapshot();
                        _dragMode = DragMode.MovingAnnotation;
                        _annDragLastPhys = pt;
                        SkiaCanvas.CaptureMouse();
                        SkiaCanvas.InvalidateVisual();
                        return;
                    }
                }

                _selectedAnnotationIdx = null;

                if (_activeTool == ScreenshotTool.Text)
                {
                    OpenInlineTextBoxAt(pt);
                    return;
                }

                _dragMode = DragMode.DrawingAnnotation;
                _draftAnnotation = new ScreenshotAnnotation
                {
                    Tool = _activeTool.Value,
                    StartPoint = pt,
                    EndPoint = pt,
                    Points = [pt],
                    Color = _activeColor,
                    LineWidth = _activeLineWidth
                };
                SkiaCanvas.CaptureMouse();
                SkiaCanvas.InvalidateVisual();
                return;
            }
        }

        // 无工具模式：检测 8 控制点缩放或选区整体移动
        if (HitTestResizeHandle(sel, pt) is ResizeHandle rh)
        {
            _dragMode = DragMode.ResizingSelection;
            _activeResizeHandle = rh;
            _resizeOriginRect = sel;
            ToolbarHost.Visibility = Visibility.Collapsed;
            SkiaCanvas.CaptureMouse();
            return;
        }

        if (sel.Contains(pt))
        {
            _dragMode = DragMode.MovingSelection;
            _moveOffsetFromOrigin = new ScreenshotPoint(pt.X - sel.Left, pt.Y - sel.Top);
            _resizeOriginRect = sel;
            ToolbarHost.Visibility = Visibility.Collapsed;
            SkiaCanvas.CaptureMouse();
            return;
        }
    }

    private void SkiaCanvas_MouseMove(object sender, MouseEventArgs e)
    {
        var pt = GetPhysicalPoint(e);
        _currentMousePhys = pt;

        switch (_dragMode)
        {
            case DragMode.CreatingSelection:
                _mouseMovedDuringCapture = true;
                _selectionRect = ScreenshotRect.FromPoints(_dragStartPhys, pt);
                break;

            case DragMode.MovingSelection:
                double nx = Math.Clamp(pt.X - _moveOffsetFromOrigin.X, 0, Math.Max(0, _virtualWidth - _resizeOriginRect.Width));
                double ny = Math.Clamp(pt.Y - _moveOffsetFromOrigin.Y, 0, Math.Max(0, _virtualHeight - _resizeOriginRect.Height));
                _selectionRect = new ScreenshotRect(nx, ny, _resizeOriginRect.Width, _resizeOriginRect.Height);
                break;

            case DragMode.ResizingSelection:
                _selectionRect = ApplyResizeHandle(_resizeOriginRect, _activeResizeHandle, pt);
                break;

            case DragMode.DrawingAnnotation when _draftAnnotation != null:
                _draftAnnotation.EndPoint = pt;
                if (_draftAnnotation.Tool is ScreenshotTool.Pen or ScreenshotTool.Highlighter or ScreenshotTool.Mosaic)
                {
                    if (_draftAnnotation.Points.Count == 0 || _draftAnnotation.Points[^1].DistanceTo(pt) >= 2.0)
                        _draftAnnotation.Points.Add(pt);
                }
                break;

            case DragMode.MovingAnnotation when _selectedAnnotationIdx is int idx && idx < _annotations.Count:
                _annotations[idx].MoveBy(pt.X - _annDragLastPhys.X, pt.Y - _annDragLastPhys.Y);
                _annDragLastPhys = pt;
                break;

            case DragMode.ResizingAnnotation when _selectedAnnotationIdx is int idx && idx < _annotations.Count:
                _annotations[idx].DragHandle(_activeAnnHandle, pt);
                break;
        }

        SkiaCanvas.InvalidateVisual();
    }

    private void SkiaCanvas_MouseLeftButtonUp(object sender, MouseButtonEventArgs e)
    {
        if (SkiaCanvas.IsMouseCaptured)
            SkiaCanvas.ReleaseMouseCapture();

        var finishedMode = _dragMode;
        _dragMode = DragMode.None;

        if (finishedMode == DragMode.CreatingSelection)
        {
            if (!_mouseMovedDuringCapture || _selectionRect is not { Width: >= 8, Height: >= 8 })
            {
                // 单击未拖动时默认全屏或最小合理选区提示
                _selectionRect = null;
                _hasFinishedInitialDrag = false;
                SkiaCanvas.InvalidateVisual();
                return;
            }
            _hasFinishedInitialDrag = true;
            PositionAndShowToolbar();
        }
        else if (finishedMode is DragMode.MovingSelection or DragMode.ResizingSelection)
        {
            PositionAndShowToolbar();
        }
        else if (finishedMode == DragMode.DrawingAnnotation && _draftAnnotation != null)
        {
            if (_draftAnnotation.IsValid)
            {
                PushUndoSnapshot();
                _annotations.Add(_draftAnnotation);
                _selectedAnnotationIdx = _annotations.Count - 1;
                UpdateUndoRedoButtons();
            }
            _draftAnnotation = null;
        }

        SkiaCanvas.InvalidateVisual();
    }

    private void SkiaCanvas_MouseRightButtonUp(object sender, MouseButtonEventArgs e)
    {
        CancelAndClose();
    }

    private ScreenshotRect ApplyResizeHandle(ScreenshotRect r, ResizeHandle h, ScreenshotPoint pt)
    {
        double left = r.Left, top = r.Top, right = r.Right, bottom = r.Bottom;
        const double minSize = 12.0;

        switch (h)
        {
            case ResizeHandle.TopLeft:
                left = Math.Min(pt.X, right - minSize);
                top = Math.Min(pt.Y, bottom - minSize);
                break;
            case ResizeHandle.Top:
                top = Math.Min(pt.Y, bottom - minSize);
                break;
            case ResizeHandle.TopRight:
                right = Math.Max(pt.X, left + minSize);
                top = Math.Min(pt.Y, bottom - minSize);
                break;
            case ResizeHandle.Left:
                left = Math.Min(pt.X, right - minSize);
                break;
            case ResizeHandle.Right:
                right = Math.Max(pt.X, left + minSize);
                break;
            case ResizeHandle.BottomLeft:
                left = Math.Min(pt.X, right - minSize);
                bottom = Math.Max(pt.Y, top + minSize);
                break;
            case ResizeHandle.Bottom:
                bottom = Math.Max(pt.Y, top + minSize);
                break;
            case ResizeHandle.BottomRight:
                right = Math.Max(pt.X, left + minSize);
                bottom = Math.Max(pt.Y, top + minSize);
                break;
        }

        left = Math.Clamp(left, 0, _virtualWidth - minSize);
        top = Math.Clamp(top, 0, _virtualHeight - minSize);
        right = Math.Clamp(right, left + minSize, _virtualWidth);
        bottom = Math.Clamp(bottom, top + minSize, _virtualHeight);
        return new ScreenshotRect(left, top, right - left, bottom - top);
    }

    private void PositionAndShowToolbar()
    {
        if (_selectionRect is not ScreenshotRect sel) return;
        ToolbarHost.Visibility = Visibility.Visible;
        ToolbarHost.UpdateLayout();

        var topLeftDip = PhysicalToCanvasDip(sel.Left, sel.Top);
        var botRightDip = PhysicalToCanvasDip(sel.Right, sel.Bottom);

        double barW = ToolbarHost.ActualWidth > 0 ? ToolbarHost.ActualWidth : 740;
        double barH = ToolbarHost.ActualHeight > 0 ? ToolbarHost.ActualHeight : 44;

        double leftDip = Math.Clamp(botRightDip.X - barW, 8, Math.Max(8, OverlayCanvas.ActualWidth - barW - 8));
        double topDip = botRightDip.Y + 8;
        if (topDip + barH > OverlayCanvas.ActualHeight - 8)
        {
            double aboveDip = topLeftDip.Y - barH - 8;
            topDip = aboveDip >= 8 ? aboveDip : Math.Max(8, botRightDip.Y - barH - 8);
        }

        Canvas.SetLeft(ToolbarHost, leftDip);
        Canvas.SetTop(ToolbarHost, topDip);
    }

    private void OpenInlineTextBoxAt(ScreenshotPoint physPt)
    {
        _pendingTextPoint = physPt;
        var dip = PhysicalToCanvasDip(physPt.X, physPt.Y);
        Canvas.SetLeft(InlineTextBox, dip.X);
        Canvas.SetTop(InlineTextBox, dip.Y);

        InlineTextBox.Text = string.Empty;
        InlineTextBox.Foreground = new SolidColorBrush(Color.FromRgb(_activeColor.R, _activeColor.G, _activeColor.B));
        InlineTextBox.FontSize = _activeLineWidth <= 3 ? 14 : _activeLineWidth <= 5 ? 18 : 23;
        InlineTextBox.Visibility = Visibility.Visible;
        InlineTextBox.Focus();
    }

    private void CommitInlineTextBox()
    {
        if (InlineTextBox.Visibility != Visibility.Visible) return;
        string txt = InlineTextBox.Text;
        var pt = _pendingTextPoint;
        InlineTextBox.Visibility = Visibility.Collapsed;
        _pendingTextPoint = null;

        if (!string.IsNullOrWhiteSpace(txt) && pt is ScreenshotPoint p)
        {
            PushUndoSnapshot();
            _annotations.Add(new ScreenshotAnnotation
            {
                Tool = ScreenshotTool.Text,
                StartPoint = p,
                EndPoint = p,
                Color = _activeColor,
                LineWidth = _activeLineWidth,
                Text = txt
            });
            _selectedAnnotationIdx = _annotations.Count - 1;
            UpdateUndoRedoButtons();
            SkiaCanvas.InvalidateVisual();
        }
    }

    private void InlineTextBox_LostKeyboardFocus(object sender, KeyboardFocusChangedEventArgs e) => CommitInlineTextBox();

    private void InlineTextBox_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape)
        {
            e.Handled = true;
            InlineTextBox.Visibility = Visibility.Collapsed;
            _pendingTextPoint = null;
        }
        else if (e.Key == Key.Enter && (Keyboard.Modifiers & ModifierKeys.Shift) == 0)
        {
            e.Handled = true;
            CommitInlineTextBox();
        }
    }

    private void ToolBtn_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: string tag } || !Enum.TryParse<ScreenshotTool>(tag, out var tool))
            return;

        _activeTool = _activeTool == tool ? null : tool;
        _selectedAnnotationIdx = null;

        Button[] toolBtns = [BtnToolRect, BtnToolEllipse, BtnToolArrow, BtnToolPen, BtnToolHighlighter, BtnToolMosaic, BtnToolText];
        var soft = (Brush)FindResource("AccentSoftBrush");
        var accentFg = (Brush)FindResource("AccentBrush");
        var secFg = (Brush)FindResource("TextSecondaryBrush");

        foreach (var b in toolBtns)
        {
            bool isOn = _activeTool.HasValue && string.Equals(b.Tag?.ToString(), _activeTool.Value.ToString(), StringComparison.Ordinal);
            b.Background = isOn ? soft : Brushes.Transparent;
            b.Foreground = isOn ? accentFg : secFg;
        }

        StyleSubBar.Visibility = _activeTool.HasValue ? Visibility.Visible : Visibility.Collapsed;
        PositionAndShowToolbar();
        SkiaCanvas.InvalidateVisual();
    }

    private void PushUndoSnapshot()
    {
        _undoStack.Push(_annotations.Select(a => a.Clone()).ToList());
        _redoStack.Clear();
        UpdateUndoRedoButtons();
    }

    private void UpdateUndoRedoButtons()
    {
        BtnUndo.IsEnabled = _undoStack.Count > 0;
        BtnRedo.IsEnabled = _redoStack.Count > 0;
    }

    private void BtnUndo_Click(object sender, RoutedEventArgs e)
    {
        if (_undoStack.Count == 0) return;
        _redoStack.Push(_annotations.Select(a => a.Clone()).ToList());
        _annotations.Clear();
        _annotations.AddRange(_undoStack.Pop());
        _selectedAnnotationIdx = null;
        UpdateUndoRedoButtons();
        SkiaCanvas.InvalidateVisual();
    }

    private void BtnRedo_Click(object sender, RoutedEventArgs e)
    {
        if (_redoStack.Count == 0) return;
        _undoStack.Push(_annotations.Select(a => a.Clone()).ToList());
        _annotations.Clear();
        _annotations.AddRange(_redoStack.Pop());
        _selectedAnnotationIdx = null;
        UpdateUndoRedoButtons();
        SkiaCanvas.InvalidateVisual();
    }

    private void LanguageCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (LanguageCombo.SelectedItem is TranslationService.TargetLanguage lang)
        {
            _settings.TargetLanguageId = lang.Id;
            if (_translatedBlocks != null && !_translating)
                _ = TranslateSelectionAsync(lang.Code);
        }
    }

    private void BtnTranslate_Click(object sender, RoutedEventArgs e)
    {
        if (_translating) return;
        string code = (LanguageCombo.SelectedItem as TranslationService.TargetLanguage)?.Code ?? "zh-CN";
        _ = TranslateSelectionAsync(code);
    }

    private void BtnToggleOriginal_Click(object sender, RoutedEventArgs e)
    {
        _showTranslated = !_showTranslated;
        BtnToggleOriginal.Content = _showTranslated ? "原图" : "译文";
        SkiaCanvas.InvalidateVisual();
    }

    private async Task TranslateSelectionAsync(string targetGoogleCode)
    {
        if (_selectionRect is not ScreenshotRect sel || sel.Width < 12 || sel.Height < 12)
            return;

        _translating = true;
        TxtTranslateBtn.Text = "翻译中…";
        BtnTranslate.IsEnabled = false;

        try
        {
            using var cropped = ScreenshotRenderer.RenderExportBitmap(_screenBitmap, sel, []);
            var ocrBlocks = await _ocrEngine.RecognizeTextBlocksAsync(cropped, _spellChecker);
            if (ocrBlocks.Count == 0)
            {
                ShowToast("选区内未识别到文字");
                return;
            }

            var texts = ocrBlocks.Select(b => b.Text).ToList();
            string[] translated = await _translator.TranslateBatchAsync(texts, targetCode: targetGoogleCode);

            var styled = new List<InPlaceTranslatedBlock>(ocrBlocks.Count);
            for (int i = 0; i < ocrBlocks.Count; i++)
            {
                string tr = i < translated.Length ? translated[i] : ocrBlocks[i].Text;
                styled.Add(InPlaceStyleDetector.Detect(i, ocrBlocks[i], tr, _sampler, sel));
            }

            _translatedBlocks = styled;
            _showTranslated = true;
            BtnToggleOriginal.Visibility = Visibility.Visible;
            BtnToggleOriginal.Content = "原图";
            SkiaCanvas.InvalidateVisual();
            ShowToast($"已原位翻译 {styled.Count} 个文本块");
        }
        catch
        {
            ShowToast("翻译失败，请检查网络连接");
        }
        finally
        {
            _translating = false;
            TxtTranslateBtn.Text = "翻译";
            BtnTranslate.IsEnabled = true;
        }
    }

    private void ShowToast(string message)
    {
        ToastText.Text = message;
        if (_selectionRect is ScreenshotRect sel)
        {
            var p = PhysicalToCanvasDip(sel.Left + 8, sel.Top + 8);
            Canvas.SetLeft(ToastBadge, Math.Max(12, p.X));
            Canvas.SetTop(ToastBadge, Math.Max(12, p.Y));
        }
        else
        {
            Canvas.SetLeft(ToastBadge, 24);
            Canvas.SetTop(ToastBadge, 24);
        }
        ToastBadge.Visibility = Visibility.Visible;
        _toastTimer.Stop();
        _toastTimer.Start();
    }

    private void Window_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (InlineTextBox.IsKeyboardFocusWithin)
            return;

        bool ctrl = (Keyboard.Modifiers & ModifierKeys.Control) != 0;
        bool shift = (Keyboard.Modifiers & ModifierKeys.Shift) != 0;

        if (e.Key == Key.Escape)
        {
            e.Handled = true;
            if (_translatedBlocks != null)
            {
                _translatedBlocks = null;
                BtnToggleOriginal.Visibility = Visibility.Collapsed;
                SkiaCanvas.InvalidateVisual();
            }
            else
            {
                CancelAndClose();
            }
            return;
        }

        if (e.Key == Key.C && !ctrl && _activeTool == null)
        {
            e.Handled = true;
            int px = Math.Clamp((int)Math.Floor(_currentMousePhys.X), 0, _virtualWidth - 1);
            int py = Math.Clamp((int)Math.Floor(_currentMousePhys.Y), 0, _virtualHeight - 1);
            string hex = _sampler.ColorAtInt(px, py).HexString;
            Clipboard.SetText(hex);
            ShowToast($"已复制色值 {hex}");
            return;
        }

        if (e.Key == Key.Z && ctrl)
        {
            e.Handled = true;
            if (shift) BtnRedo_Click(this, new RoutedEventArgs());
            else BtnUndo_Click(this, new RoutedEventArgs());
            return;
        }
        if (e.Key == Key.Y && ctrl)
        {
            e.Handled = true;
            BtnRedo_Click(this, new RoutedEventArgs());
            return;
        }
        if (e.Key == Key.S && ctrl && _hasFinishedInitialDrag)
        {
            e.Handled = true;
            FinishWith(OverlayCompletionAction.Saved);
            return;
        }
        if (e.Key is Key.Back or Key.Delete && _selectedAnnotationIdx is int idx && idx < _annotations.Count)
        {
            e.Handled = true;
            PushUndoSnapshot();
            _annotations.RemoveAt(idx);
            _selectedAnnotationIdx = null;
            UpdateUndoRedoButtons();
            SkiaCanvas.InvalidateVisual();
            return;
        }

        if (_hasFinishedInitialDrag && _selectionRect is ScreenshotRect sel)
        {
            if (e.Key == Key.L)
            {
                e.Handled = true;
                FinishWith(OverlayCompletionAction.StartScrollCapture);
                return;
            }
            if (e.Key == Key.F3)
            {
                e.Handled = true;
                FinishWith(OverlayCompletionAction.Pinned);
                return;
            }
            if (e.Key == Key.Enter)
            {
                e.Handled = true;
                FinishWith(OverlayCompletionAction.Copied);
                return;
            }

            int step = shift ? 10 : 1;
            double dx = 0, dy = 0;
            if (e.Key == Key.Left) dx = -step;
            else if (e.Key == Key.Right) dx = step;
            else if (e.Key == Key.Up) dy = -step;
            else if (e.Key == Key.Down) dy = step;

            if (dx != 0 || dy != 0)
            {
                e.Handled = true;
                double nx = Math.Clamp(sel.Left + dx, 0, Math.Max(0, _virtualWidth - sel.Width));
                double ny = Math.Clamp(sel.Top + dy, 0, Math.Max(0, _virtualHeight - sel.Height));
                _selectionRect = new ScreenshotRect(nx, ny, sel.Width, sel.Height);
                PositionAndShowToolbar();
                SkiaCanvas.InvalidateVisual();
            }
        }
    }

    private void FinishWith(OverlayCompletionAction action)
    {
        if (InlineTextBox.Visibility == Visibility.Visible)
            CommitInlineTextBox();

        if (_selectionRect is not ScreenshotRect sel || sel.Width < 2 || sel.Height < 2)
        {
            CancelAndClose();
            return;
        }

        var blocksToBake = _showTranslated ? _translatedBlocks : null;
        var cropped = action == OverlayCompletionAction.StartScrollCapture
            ? null
            : ScreenshotRenderer.RenderExportBitmap(_screenBitmap, sel, _annotations, blocksToBake);

        // 将物理坐标还原为虚拟桌面绝对物理坐标以便 ScrollCapture 连续区域截取
        var globalPhysRect = new ScreenshotRect(
            _virtualLeft + sel.Left,
            _virtualTop + sel.Top,
            sel.Width,
            sel.Height);

        Result = new CompletionResult(action, cropped, globalPhysRect, blocksToBake);
        Close();
    }

    public void FinishAndPinFromHotKey()
    {
        if (_hasFinishedInitialDrag && _selectionRect is { Width: >= 2, Height: >= 2 })
            FinishWith(OverlayCompletionAction.Pinned);
        else
            CancelAndClose();
    }

    private void CancelAndClose()
    {
        Result = new CompletionResult(OverlayCompletionAction.Cancelled, null, default);
        Close();
    }

    private void BtnScrollCapture_Click(object sender, RoutedEventArgs e) => FinishWith(OverlayCompletionAction.StartScrollCapture);
    private void BtnPin_Click(object sender, RoutedEventArgs e) => FinishWith(OverlayCompletionAction.Pinned);
    private void BtnSave_Click(object sender, RoutedEventArgs e) => FinishWith(OverlayCompletionAction.Saved);
    private void BtnCancel_Click(object sender, RoutedEventArgs e) => CancelAndClose();
    private void BtnDone_Click(object sender, RoutedEventArgs e) => FinishWith(OverlayCompletionAction.Copied);
}
