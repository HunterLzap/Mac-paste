using System.Text;
using System.Text.RegularExpressions;

namespace WinPaste.Core.OCR;

/// <summary>
/// 100% 还原 Mac 版 ScreenshotManager.swift 的 OCR 碎片归一化、行组归并、段落合并、
/// 跨行断词拼接、单行真实高度保留与同轴居中传染算法。
/// </summary>
public static partial class OcrBlockSegmenter
{
    private static readonly HashSet<string> CommonShortEnglishWords = new(StringComparer.OrdinalIgnoreCase)
    {
        "a", "i", "in", "on", "at", "to", "by", "of", "or", "as", "is", "it",
        "be", "an", "no", "up", "we", "he", "my", "if", "do", "go", "so", "us",
        "me", "for", "and", "the", "are", "but", "not", "you", "all", "can",
        "had", "her", "was", "one", "our", "out", "day", "get", "has", "him",
        "his", "how", "man", "new", "now", "old", "see", "two", "way", "who",
        "its", "let", "put", "say", "she", "too", "use", "off", "per", "via"
    };

    [GeneratedRegex(@"\bAl-(?=[A-Za-z])")]
    private static partial Regex AiHyphenRegex();

    [GeneratedRegex(@"\bAlGC\b")]
    private static partial Regex AigcRegex();

    [GeneratedRegex(@"\bOpenAl\b")]
    private static partial Regex OpenAiRegex();

    [GeneratedRegex(@"\bGenAl\b")]
    private static partial Regex GenAiRegex();

    [GeneratedRegex(@"\bAl(?=\s+(?:Native|Powered|Driven|First|Agent|Agents|Chat|Model|Models|Assistant))")]
    private static partial Regex AiPhraseRegex();

    /// <summary>
    /// 修复无衬线字体中大写 I 与小写 l 常见的 OCR 混淆（如 Al-Native -> AI-Native、AlGC -> AIGC）
    /// </summary>
    public static string NormalizeOcrText(string text)
    {
        if (string.IsNullOrEmpty(text))
            return string.Empty;

        var result = AiHyphenRegex().Replace(text, "AI-");
        result = AigcRegex().Replace(result, "AIGC");
        result = OpenAiRegex().Replace(result, "OpenAI");
        result = GenAiRegex().Replace(result, "GenAI");
        result = AiPhraseRegex().Replace(result, "AI");
        return result;
    }

    /// <summary>
    /// 从原始 OCR 碎片提取行片段（垂直重叠行组归并 + 同行水平邻近片段合并）
    /// </summary>
    public static List<OcrLineSegment> ExtractLineSegments(
        IReadOnlyList<OcrRawFragment> rawFragments,
        double imageWidth,
        double imageHeight)
    {
        if (rawFragments.Count == 0)
            return new List<OcrLineSegment>();

        double aspect = Math.Max(imageHeight, 1.0) / Math.Max(imageWidth, 1.0);

        // 转换到与 Mac Vision 一致的归一化左下角坐标系（Y 越大越靠上），保证所有几何判定与 Mac 版 1:1 严格一致
        var fragments = rawFragments
            .Select(f =>
            {
                var trimmed = f.Text.Trim();
                if (trimmed.Length == 0)
                    return ((string Text, NormRect Box)?)null;

                var text = NormalizeOcrText(trimmed);
                var tl = f.TopLeftBox;
                var visionBox = new NormRect(
                    X: tl.X,
                    Y: 1.0 - (tl.Y + tl.Height),
                    Width: tl.Width,
                    Height: tl.Height);
                return ((string Text, NormRect Box)?)(text, visionBox);
            })
            .Where(x => x.HasValue)
            .Select(x => x!.Value)
            .OrderByDescending(f => f.Box.MidY)
            .ToList();

        if (fragments.Count == 0)
            return new List<OcrLineSegment>();

        // 1. 先按垂直重叠或中心接近度分入水平行组（避免行尾短碎片因缺少下延字母导致中心上偏而另起一行）
        var rowGroups = new List<List<(string Text, NormRect Box)>>();
        foreach (var frag in fragments)
        {
            int matchGroupIdx = -1;
            for (int i = 0; i < rowGroups.Count; i++)
            {
                var group = rowGroups[i];
                double avgH = group.Average(g => g.Box.Height);
                double midY = group.Average(g => g.Box.MidY);
                double groupMinY = group.Min(g => g.Box.MinY);
                double groupMaxY = group.Max(g => g.Box.MaxY);
                double overlapY = Math.Min(frag.Box.MaxY, groupMaxY) - Math.Max(frag.Box.MinY, groupMinY);
                double minH = Math.Min(frag.Box.Height, avgH);
                double maxH = Math.Max(frag.Box.Height, avgH);
                if ((minH > 0 && overlapY >= minH * 0.25) || Math.Abs(frag.Box.MidY - midY) < maxH * 0.65)
                {
                    matchGroupIdx = i;
                    break;
                }
            }

            if (matchGroupIdx >= 0)
                rowGroups[matchGroupIdx].Add(frag);
            else
                rowGroups.Add([frag]);
        }

        // 按垂直位置从上到下排序（Vision 坐标系原点在左下角，midY 越大越靠上）
        rowGroups.Sort((a, b) =>
        {
            double midYA = a.Average(x => x.Box.MidY);
            double midYB = b.Average(x => x.Box.MidY);
            return midYB.CompareTo(midYA);
        });

        // 2. 每行内按从左到右顺序，仅合并水平间距较小的邻近碎片；远距分栏/按钮保持为独立片段
        var segments = new List<OcrLineSegment>();
        foreach (var group in rowGroups)
        {
            var sorted = group.OrderBy(x => x.Box.MinX).ToList();
            OcrLineSegment? current = null;

            foreach (var frag in sorted)
            {
                if (current is not null)
                {
                    double lineH = Math.Max(current.AvgHeight, current.Box.Height);
                    double lineHInX = lineH * aspect;
                    double gapX = frag.Box.MinX - current.Box.MaxX;
                    double overlapY = Math.Min(frag.Box.MaxY, current.Box.MaxY) - Math.Max(frag.Box.MinY, current.Box.MinY);
                    double minH = Math.Min(frag.Box.Height, lineH);
                    bool verticalMatch = (minH > 0 && overlapY >= minH * 0.20)
                        || Math.Abs(frag.Box.MidY - current.Box.MidY) < Math.Max(frag.Box.Height, lineH) * 0.65;
                    bool horizontalMatch = gapX < Math.Max(lineHInX * 2.8, 0.04) && gapX >= -lineHInX * 1.5;

                    if (verticalMatch && horizontalMatch)
                    {
                        char prevLast = current.Text.Length > 0 ? current.Text[^1] : ' ';
                        char currFirst = frag.Text.Length > 0 ? frag.Text[0] : ' ';
                        if (IsCjk(prevLast) && IsCjk(currFirst) && gapX < Math.Max(lineHInX * 0.45, 0.015))
                            current.Text += frag.Text;
                        else
                            current.Text += " " + frag.Text;

                        current.Box = current.Box.Union(frag.Box);
                        current.TotalHeight += frag.Box.Height;
                        current.Count += 1;
                    }
                    else
                    {
                        segments.Add(current);
                        current = new OcrLineSegment(frag.Text, frag.Box, frag.Box.Height, 1);
                    }
                }
                else
                {
                    current = new OcrLineSegment(frag.Text, frag.Box, frag.Box.Height, 1);
                }
            }

            if (current is not null)
                segments.Add(current);
        }

        return segments;
    }

    private sealed class BlockAccumulator
    {
        public string Text { get; set; }
        public NormRect Box { get; set; }
        public int LineCount { get; set; }
        public double TotalLineHeight { get; set; }
        public List<OcrLineSegment> Segments { get; }

        public OcrLineSegment LastSegment => Segments[^1];
        public double AvgLineHeight => TotalLineHeight / Math.Max(LineCount, 1);

        public BlockAccumulator(OcrLineSegment first)
        {
            Text = first.Text;
            Box = first.Box;
            LineCount = 1;
            TotalLineHeight = first.AvgHeight;
            Segments = [first];
        }
    }

    /// <summary>
    /// 识别图片中的语义文本块及其归一化位置（左上角为原点），供原位分块翻译与双语对照使用
    /// </summary>
    public static List<OcrTextBlock> SegmentBlocks(
        IReadOnlyList<OcrRawFragment> rawFragments,
        double imageWidth,
        double imageHeight,
        IEnglishSpellChecker? spellChecker = null)
    {
        var segments = ExtractLineSegments(rawFragments, imageWidth, imageHeight);
        if (segments.Count == 0)
            return new List<OcrTextBlock>();

        spellChecker ??= EnglishSpellChecker.Shared;
        double aspect = Math.Max(imageHeight, 1.0) / Math.Max(imageWidth, 1.0);

        static bool CanMergeIntoParagraph(BlockAccumulator acc, OcrLineSegment seg, double aspectRatio)
        {
            var curr = acc.LastSegment;
            double avgH = acc.AvgLineHeight;
            double avgHInX = avgH * aspectRatio;

            // 1. 左边缘对齐或中心轴对称居中对齐
            bool isLeftAligned = Math.Abs(acc.Box.MinX - seg.Box.MinX) <= avgHInX * 1.5;
            bool isCenterAligned = Math.Abs(acc.Box.MidX - seg.Box.MidX) <= Math.Max(avgHInX * 2.0, 0.025)
                && seg.Box.Width <= curr.Box.Width * 1.25;
            if (!isLeftAligned && !isCenterAligned)
                return false;

            // 2. 垂直间距紧凑（Vision 左下角坐标系，上一行 minY 在下一行 maxY 上方）
            double verticalGap = curr.Box.MinY - seg.Box.MaxY;
            if (verticalGap < -avgH * 0.25 || verticalGap > avgH * 0.90)
                return false;

            // 3. 字号高度相近（兼容含上伸/下延字母与仅短小写字母的跨行大标题）
            double ratio = Math.Max(curr.AvgHeight, seg.AvgHeight) / Math.Max(Math.Min(curr.AvgHeight, seg.AvgHeight), 0.0001);
            if (ratio > 1.50)
                return false;

            // 4. 上一行需为较长正文行且两行水平投影充分重叠
            bool prevIsBodyLine = curr.Text.Length >= 16 || curr.Box.Width >= avgHInX * 7.0;
            if (!prevIsBodyLine)
                return false;

            double overlapW = Math.Min(curr.Box.MaxX, seg.Box.MaxX) - Math.Max(curr.Box.MinX, seg.Box.MinX);
            double minW = Math.Min(curr.Box.Width, seg.Box.Width);
            return minW > 0 && (overlapW / minW) >= 0.45;
        }

        var accumulators = new List<BlockAccumulator>();
        foreach (var seg in segments)
        {
            int matchIdx = -1;
            for (int idx = accumulators.Count - 1; idx >= 0; idx--)
            {
                if (!CanMergeIntoParagraph(accumulators[idx], seg, aspect))
                    continue;

                // 确保两行之间没有真正夹在中间的已成块文本（排除同行兄弟片段）
                var curr = accumulators[idx].LastSegment;
                bool hasIntervening = false;
                for (int j = idx + 1; j < accumulators.Count; j++)
                {
                    var other = accumulators[j];
                    double ox = Math.Min(other.Box.MaxX, seg.Box.MaxX) - Math.Max(other.Box.MinX, seg.Box.MinX);
                    if (ox > 0 && other.Box.MidY < curr.Box.MinY && other.Box.MidY > seg.Box.MaxY)
                    {
                        hasIntervening = true;
                        break;
                    }
                }
                if (!hasIntervening)
                {
                    matchIdx = idx;
                    break;
                }
            }

            if (matchIdx >= 0)
            {
                var acc = accumulators[matchIdx];
                acc.Text = JoinParagraphLines(acc.Text, seg.Text, spellChecker);
                acc.Box = acc.Box.Union(seg.Box);
                acc.LineCount += 1;
                acc.TotalLineHeight += seg.AvgHeight;
                acc.Segments.Add(seg);
            }
            else
            {
                accumulators.Add(new BlockAccumulator(seg));
            }
        }

        var unitBounds = new NormRect(0, 0, 1, 1);
        var blocks = new List<OcrTextBlock>();
        foreach (var acc in accumulators)
        {
            var trimmed = acc.Text.Trim();
            if (trimmed.Length == 0)
                continue;

            var topLeftRect = new NormRect(
                X: acc.Box.MinX,
                Y: 1.0 - acc.Box.MaxY,
                Width: acc.Box.Width,
                Height: acc.Box.Height).Intersect(unitBounds);

            if (topLeftRect.IsEmpty)
                continue;

            bool blockCentered = false;
            if (acc.Segments.Count >= 2)
            {
                var widest = acc.Segments.MaxBy(s => s.Box.Width)!;
                var shortest = acc.Segments.MinBy(s => s.Box.Width)!;
                if (shortest.Box.Width < widest.Box.Width * 0.92)
                {
                    double centerDiff = Math.Abs(shortest.Box.MidX - widest.Box.MidX);
                    double leftDiff = Math.Abs(shortest.Box.MinX - widest.Box.MinX);
                    double maxCenterTol = Math.Max(acc.AvgLineHeight * aspect * 2.0, 0.025);
                    if (centerDiff <= maxCenterTol && centerDiff < leftDiff * 0.55)
                        blockCentered = true;
                }
            }

            blocks.Add(new OcrTextBlock(
                Text: trimmed,
                NormalizedRect: topLeftRect,
                NormalizedLineHeight: acc.AvgLineHeight,
                LineCount: acc.LineCount,
                IsCentered: blockCentered));
        }

        // 同轴居中传染：若同列存在已判定的居中块或两个宽度明显不同却共享中心轴的块，则均视为居中
        var centeredFlags = blocks.Select(b => b.IsCentered).ToArray();
        for (int i = 0; i < blocks.Count; i++)
        {
            if (centeredFlags[i]) continue;
            var a = blocks[i].NormalizedRect;
            for (int j = 0; j < blocks.Count; j++)
            {
                if (i == j) continue;
                var b = blocks[j].NormalizedRect;
                double centerDiff = Math.Abs(a.MidX - b.MidX);
                if (centeredFlags[j] && centerDiff <= 0.055)
                {
                    centeredFlags[i] = true;
                    break;
                }
                double leftDiff = Math.Abs(a.MinX - b.MinX);
                if (centerDiff <= 0.035 && leftDiff > 0.035 && Math.Abs(a.Width - b.Width) > 0.08)
                {
                    centeredFlags[i] = true;
                    break;
                }
            }
        }

        for (int i = 0; i < blocks.Count; i++)
        {
            if (centeredFlags[i] != blocks[i].IsCentered)
                blocks[i] = blocks[i] with { IsCentered = centeredFlags[i] };
        }

        blocks.Sort((a, b) =>
        {
            double minH = Math.Min(a.NormalizedRect.Height, b.NormalizedRect.Height);
            if (Math.Abs(a.NormalizedRect.MidY - b.NormalizedRect.MidY) < minH * 0.5)
                return a.NormalizedRect.MinX.CompareTo(b.NormalizedRect.MinX);
            return a.NormalizedRect.MinY.CompareTo(b.NormalizedRect.MinY);
        });

        return blocks;
    }

    /// <summary>
    /// 智能拼接跨行文本：识别 CJK 连续字、连字符断行及英文跨行断词（如 Ex + perts -> Experts）
    /// </summary>
    public static string JoinParagraphLines(string prev, string next, IEnglishSpellChecker? spellChecker = null)
    {
        var p = prev.Trim();
        var n = next.Trim();
        if (p.Length == 0) return n;
        if (n.Length == 0) return p;

        spellChecker ??= EnglishSpellChecker.Shared;

        if (IsCjk(p[^1]) && IsCjk(n[0]))
            return p + n;

        if (p.EndsWith('-') && char.IsAsciiLetterLower(n[0]))
        {
            var pNoHyphen = p[..^1];
            var leftStem = TrailingAsciiLetters(pNoHyphen);
            var rightStem = LeadingAsciiLetters(n);
            if (leftStem is not null && rightStem is not null &&
                spellChecker.IsValidEnglishWord(leftStem + rightStem))
            {
                return pNoHyphen + n;
            }
        }

        var lastWord = TrailingAsciiLetters(p);
        var firstWord = LeadingAsciiLetters(n);
        if (lastWord is not null && firstWord is not null && char.IsAsciiLetterLower(firstWord[0]))
        {
            var combined = lastWord + firstWord;
            if (spellChecker.IsValidEnglishWord(combined))
            {
                bool firstMissing = !spellChecker.IsValidEnglishWord(firstWord);
                bool lastMissing = !spellChecker.IsValidEnglishWord(lastWord);
                bool shortNonFunctionStem = lastWord.Length <= 3 && !CommonShortEnglishWords.Contains(lastWord);
                if (firstMissing || lastMissing || shortNonFunctionStem)
                    return p + n;
            }
        }

        return p + " " + n;
    }

    public static string? TrailingAsciiLetters(string text)
    {
        int i = text.Length - 1;
        while (i >= 0 && char.IsAsciiLetter(text[i]))
            i--;
        int start = i + 1;
        return start < text.Length ? text[start..] : null;
    }

    public static string? LeadingAsciiLetters(string text)
    {
        int i = 0;
        while (i < text.Length && char.IsAsciiLetter(text[i]))
            i++;
        return i > 0 ? text[..i] : null;
    }

    public static bool IsCjk(char ch)
    {
        int scalar = ch;
        return (scalar >= 0x4E00 && scalar <= 0x9FFF)
            || (scalar >= 0x3400 && scalar <= 0x4DBF)
            || (scalar >= 0x20000 && scalar <= 0x2A6DF);
    }
}
