using System.Runtime.InteropServices;
using SkiaSharp;

namespace WinPaste.Core.Imaging;

/// <summary>
/// 1:1 复刻 Mac 版 ScrollImageStitcher：
/// 双向垂直位移估算 + SAD 重叠匹配 + 锚点回滚去重 + 连续失配重锚定 + 24000px 上限。
/// 所有尺寸均为物理像素。
/// </summary>
public sealed class ScrollImageStitcher
{
    public const int MaxPixelHeight = 24_000;

    public readonly record struct AppendResult(
        bool Appended,
        int AppendedRows,
        int PrependedRows,
        bool NoMovement,
        int TotalHeight);

    private sealed class FramePixels
    {
        public int Width { get; }
        public int Height { get; }
        public int RowBytes { get; }
        public byte[] Rgba { get; } // 统一 Bgra8888 4 bytes/pixel

        public FramePixels(int width, int height, byte[] rgba)
        {
            Width = width;
            Height = height;
            RowBytes = width * 4;
            Rgba = rgba;
        }
    }

    private FramePixels? _prevFrame;
    private byte[] _stitchedPixels = [];
    private int _stitchedWidth;
    private int _stitchedHeight;
    private int _anchorTop;
    private int _consecutiveNoMatch;
    private readonly int _cropInset;

    public int TotalPixelHeight => _stitchedHeight;
    public int Width => _stitchedWidth;
    public bool HasContent => _stitchedHeight > 0 && _stitchedWidth > 0;

    /// <param name="cropInset">可选去边框像素数（默认 0；Windows 如无独立边框侵入选区可设 0）</param>
    public ScrollImageStitcher(int cropInset = 0)
    {
        _cropInset = Math.Max(0, cropInset);
    }

    public AppendResult Append(SKBitmap rawFrame)
    {
        var curr = ExtractFrame(rawFrame);
        if (curr == null || curr.Width <= 0 || curr.Height <= 0)
            return new AppendResult(false, 0, 0, false, _stitchedHeight);

        if (_prevFrame == null)
        {
            _stitchedWidth = curr.Width;
            _stitchedHeight = curr.Height;
            _stitchedPixels = new byte[curr.Rgba.Length];
            Buffer.BlockCopy(curr.Rgba, 0, _stitchedPixels, 0, curr.Rgba.Length);
            _anchorTop = 0;
            _prevFrame = curr;
            return new AppendResult(true, curr.Height, 0, false, _stitchedHeight);
        }

        if (curr.Width != _prevFrame.Width)
            return new AppendResult(false, 0, 0, false, _stitchedHeight);

        int w = curr.Width;
        int prevH = _prevFrame.Height;
        int currH = curr.Height;
        int stride = w * 4;
        int expectedRowBytes = stride;
        int maxH = MaxPixelHeight;

        const double threshold = 25.0;
        const int minOverlap = 24;

        // 先检测“无明显移动”
        double zeroDiff = OverlapDifference(_prevFrame, 0, curr, 0, Math.Min(prevH, currH));
        if (zeroDiff < 1.2)
            return new AppendResult(false, 0, 0, true, _stitchedHeight);

        int est = EstimateVerticalDisplacement(_prevFrame, curr);

        // 1. 尝试向下滚动：prev[d ..< prevH] 与 curr[0 ..< overlap] 重合，curr 底部新增 d 行
        int bestDownD = -1;
        double bestDownDiff = threshold;
        if (est >= 0)
        {
            int center = Math.Clamp(est, 4, prevH - minOverlap);
            ReadOnlySpan<int> candidates = [center - 1, center, center + 1];
            foreach (int d in candidates)
            {
                if (d < 4 || d > prevH - minOverlap) continue;
                int overlap = Math.Min(prevH - d, currH);
                if (overlap < minOverlap) continue;
                double diff = OverlapDifference(_prevFrame, d, curr, 0, overlap);
                if (diff < bestDownDiff)
                {
                    bestDownDiff = diff;
                    bestDownD = d;
                }
            }
        }

        // 2. 尝试向上滚动：prev[0 ..< overlap] 与 curr[d ..< currH] 重合，顶行向上回移 d 行
        int bestUpD = -1;
        double bestUpDiff = threshold;
        if (est < 0)
        {
            int center = Math.Clamp(-est, 4, currH - minOverlap);
            ReadOnlySpan<int> candidates = [center - 1, center, center + 1];
            foreach (int d in candidates)
            {
                if (d < 4 || d > currH - minOverlap) continue;
                int overlap = Math.Min(prevH, currH - d);
                if (overlap < minOverlap) continue;
                double diff = OverlapDifference(_prevFrame, 0, curr, d, overlap);
                if (diff < bestUpDiff)
                {
                    bestUpDiff = diff;
                    bestUpD = d;
                }
            }
        }

        bool goDown = bestDownD > 0 && (bestUpD <= 0 || bestDownDiff <= bestUpDiff);

        if (goDown)
        {
            int d = bestDownD;
            int newAnchorTop = _anchorTop + d;
            int neededBottom = newAnchorTop + currH;
            int rowsToAdd = neededBottom - _stitchedHeight;

            if (rowsToAdd > 0)
            {
                if (_stitchedHeight + rowsToAdd > maxH)
                    return new AppendResult(false, 0, 0, false, _stitchedHeight);

                int overlapStartInCurr = currH - rowsToAdd;
                int oldLen = _stitchedPixels.Length;
                int addBytes = rowsToAdd * stride;
                Array.Resize(ref _stitchedPixels, oldLen + addBytes);
                Buffer.BlockCopy(curr.Rgba, overlapStartInCurr * expectedRowBytes, _stitchedPixels, oldLen, addBytes);
                _stitchedHeight += rowsToAdd;
            }
            else
            {
                // 向下回到已拼接区域内部：用更鲜活的最新帧局部覆写（同步回滚游标）
                int overlapRows = Math.Min(currH, _stitchedHeight - newAnchorTop);
                if (overlapRows > 0 && newAnchorTop >= 0)
                {
                    Buffer.BlockCopy(
                        curr.Rgba, 0,
                        _stitchedPixels, newAnchorTop * stride,
                        overlapRows * stride);
                }
            }

            _anchorTop = newAnchorTop;
            _consecutiveNoMatch = 0;
            _prevFrame = curr;
            return new AppendResult(true, Math.Max(0, rowsToAdd), 0, false, _stitchedHeight);
        }

        if (bestUpD > 0)
        {
            int d = bestUpD;
            int newAnchorTop = _anchorTop - d;
            int prepended = 0;

            if (newAnchorTop < 0)
            {
                prepended = -newAnchorTop;
                if (_stitchedHeight + prepended > maxH)
                    return new AppendResult(false, 0, 0, false, _stitchedHeight);

                byte[] newBuf = new byte[(_stitchedHeight + prepended) * stride];
                Buffer.BlockCopy(curr.Rgba, 0, newBuf, 0, currH * stride);

                int remainingExistingRows = _stitchedHeight + prepended - currH;
                if (remainingExistingRows > 0)
                {
                    int srcOffset = (currH - prepended) * stride;
                    if (srcOffset >= 0 && srcOffset + remainingExistingRows * stride <= _stitchedPixels.Length)
                    {
                        Buffer.BlockCopy(
                            _stitchedPixels, srcOffset,
                            newBuf, currH * stride,
                            remainingExistingRows * stride);
                    }
                }

                _stitchedPixels = newBuf;
                _stitchedHeight += prepended;
                _anchorTop = 0;
            }
            else
            {
                // 还在已有画布内部向上回退：覆写重叠段并回退游标
                int overlapRows = Math.Min(currH, _stitchedHeight - newAnchorTop);
                if (overlapRows > 0)
                {
                    Buffer.BlockCopy(
                        curr.Rgba, 0,
                        _stitchedPixels, newAnchorTop * stride,
                        overlapRows * stride);
                }
                _anchorTop = newAnchorTop;
            }

            _consecutiveNoMatch = 0;
            _prevFrame = curr;
            return new AppendResult(true, 0, prepended, false, _stitchedHeight);
        }

        _consecutiveNoMatch++;
        if (_consecutiveNoMatch >= 6)
        {
            _prevFrame = curr;
            _consecutiveNoMatch = 0;
        }
        return new AppendResult(false, 0, 0, false, _stitchedHeight);
    }

    public SKBitmap? AssembleStitchedImage()
    {
        if (_stitchedWidth <= 0 || _stitchedHeight <= 0 || _stitchedPixels.Length == 0)
            return null;

        var info = new SKImageInfo(_stitchedWidth, _stitchedHeight, SKColorType.Bgra8888, SKAlphaType.Premul);
        var bmp = new SKBitmap(info);
        nint ptr = bmp.GetPixels();
        Marshal.Copy(_stitchedPixels, 0, ptr, Math.Min(_stitchedPixels.Length, bmp.ByteCount));
        return bmp;
    }

    private FramePixels? ExtractFrame(SKBitmap source)
    {
        if (source.Width <= 0 || source.Height <= 0)
            return null;

        int inset = (_cropInset > 0 && source.Width > _cropInset * 2 + 8 && source.Height > _cropInset * 2 + 8)
            ? _cropInset
            : 0;
        int w = source.Width - inset * 2;
        int h = source.Height - inset * 2;

        // 转为标准 Bgra8888 连续缓冲区
        var info = new SKImageInfo(w, h, SKColorType.Bgra8888, SKAlphaType.Premul);
        using var normalized = new SKBitmap(info);
        using (var canvas = new SKCanvas(normalized))
        {
            canvas.DrawBitmap(
                source,
                new SKRect(inset, inset, inset + w, inset + h),
                new SKRect(0, 0, w, h));
        }

        byte[] buf = new byte[normalized.ByteCount];
        Marshal.Copy(normalized.GetPixels(), buf, 0, buf.Length);
        return new FramePixels(w, h, buf);
    }

    private static double OverlapDifference(
        FramePixels prev,
        int prevOffsetY,
        FramePixels curr,
        int currOffsetY,
        int overlapHeight)
    {
        int w = prev.Width;
        int xStart = w / 20;
        int xEnd = w - w / 20;
        int xSpan = Math.Max(1, xEnd - xStart);
        int colStep = Math.Max(1, xSpan / 45);
        int rowStep = Math.Max(1, overlapHeight / 28);

        long totalDiff = 0;
        long samples = 0;

        for (int dy = 0; dy < overlapHeight; dy += rowStep)
        {
            int py = prevOffsetY + dy;
            int cy = currOffsetY + dy;
            int pRow = py * prev.RowBytes;
            int cRow = cy * curr.RowBytes;

            for (int x = xStart; x < xEnd; x += colStep)
            {
                int po = pRow + x * 4;
                int co = cRow + x * 4;
                totalDiff += Math.Abs(prev.Rgba[po] - curr.Rgba[co]);
                totalDiff += Math.Abs(prev.Rgba[po + 1] - curr.Rgba[co + 1]);
                totalDiff += Math.Abs(prev.Rgba[po + 2] - curr.Rgba[co + 2]);
                samples++;
            }
        }

        return samples == 0 ? 999.0 : (double)totalDiff / (samples * 3.0);
    }

    /// <summary>
    /// 使用采样特征行估算最可能的纵向位移（正值=内容向上滚即视图向下新内容，负值=向上回滚）
    /// </summary>
    private static int EstimateVerticalDisplacement(FramePixels prev, FramePixels curr)
    {
        int w = prev.Width;
        int h = Math.Min(prev.Height, curr.Height);
        if (h < 32) return 0;

        // 计算每行横向压缩特征（取中间区域 16 个点亮度均值，用于极速粗搜）
        int[] prevSig = BuildRowSignatures(prev);
        int[] currSig = BuildRowSignatures(curr);

        const int minOverlap = 24;
        int bestSignedOffset = 0;
        double bestScore = double.MaxValue;

        // 粗搜 step=4
        int maxDown = prev.Height - minOverlap;
        for (int d = 4; d <= maxDown; d += 4)
        {
            int overlap = Math.Min(prev.Height - d, curr.Height);
            double s = SignatureDiff(prevSig, d, currSig, 0, overlap);
            if (s < bestScore)
            {
                bestScore = s;
                bestSignedOffset = d;
            }
        }

        int maxUp = curr.Height - minOverlap;
        for (int d = 4; d <= maxUp; d += 4)
        {
            int overlap = Math.Min(prev.Height, curr.Height - d);
            double s = SignatureDiff(prevSig, 0, currSig, d, overlap);
            if (s < bestScore)
            {
                bestScore = s;
                bestSignedOffset = -d;
            }
        }

        // 在最优粗搜附近 ±3 精搜
        int coarse = bestSignedOffset;
        for (int delta = coarse - 3; delta <= coarse + 3; delta++)
        {
            if (Math.Abs(delta) < 4) continue;
            if (delta > 0 && delta <= maxDown)
            {
                int overlap = Math.Min(prev.Height - delta, curr.Height);
                double s = SignatureDiff(prevSig, delta, currSig, 0, overlap);
                if (s < bestScore)
                {
                    bestScore = s;
                    bestSignedOffset = delta;
                }
            }
            else if (delta < 0 && -delta <= maxUp)
            {
                int d = -delta;
                int overlap = Math.Min(prev.Height, curr.Height - d);
                double s = SignatureDiff(prevSig, 0, currSig, d, overlap);
                if (s < bestScore)
                {
                    bestScore = s;
                    bestSignedOffset = delta;
                }
            }
        }

        return bestSignedOffset;
    }

    private static int[] BuildRowSignatures(FramePixels frame)
    {
        var sig = new int[frame.Height];
        int xStart = frame.Width / 12;
        int xEnd = frame.Width - frame.Width / 12;
        int step = Math.Max(1, (xEnd - xStart) / 24);

        for (int y = 0; y < frame.Height; y++)
        {
            int row = y * frame.RowBytes;
            int acc = 0;
            int cnt = 0;
            for (int x = xStart; x < xEnd; x += step)
            {
                int o = row + x * 4;
                int lum = (frame.Rgba[o + 2] * 77 + frame.Rgba[o + 1] * 150 + frame.Rgba[o] * 29) >> 8;
                acc += lum;
                cnt++;
            }
            sig[y] = cnt > 0 ? acc / cnt : 0;
        }
        return sig;
    }

    private static double SignatureDiff(int[] a, int offA, int[] b, int offB, int overlap)
    {
        int rowStep = Math.Max(1, overlap / 36);
        long diff = 0;
        int count = 0;
        for (int i = 0; i < overlap; i += rowStep)
        {
            diff += Math.Abs(a[offA + i] - b[offB + i]);
            count++;
        }
        return count == 0 ? double.MaxValue : (double)diff / count;
    }
}
