using WinPaste.Core.OCR;
using Xunit;

namespace WinPaste.Tests;

public class OcrBlockSegmenterTests
{
    private sealed class MockSpellChecker : IEnglishSpellChecker
    {
        private readonly HashSet<string> _words;
        public MockSpellChecker(params string[] words) =>
            _words = new HashSet<string>(words, StringComparer.OrdinalIgnoreCase);
        public bool IsValidEnglishWord(string word) => _words.Contains(word);
    }

    [Theory]
    [InlineData("Al-Native Architecture", "AI-Native Architecture")]
    [InlineData("OpenAl SDK", "OpenAI SDK")]
    [InlineData("Al Powered workflow", "AI Powered workflow")]
    [InlineData("Alice in Wonderland", "Alice in Wonderland")]
    [InlineData("Alpha Beta", "Alpha Beta")]
    public void NormalizeOcrText_FixesCommonAiOcrMisreadSafely(string input, string expected)
    {
        Assert.Equal(expected, OcrBlockSegmenter.NormalizeOcrText(input));
    }

    [Fact]
    public void SegmentBlocks_MergesSameRowTrailingWordEvenWithSmallGap()
    {
        List<OcrRawFragment> frags =
        [
            new("Hello", new NormRect(0.10, 0.20, 0.14, 0.05)),
            new("world!", new NormRect(0.25, 0.202, 0.14, 0.048)),
        ];

        var blocks = OcrBlockSegmenter.SegmentBlocks(frags, 1000, 1000);
        Assert.Single(blocks);
        Assert.Equal("Hello world!", blocks[0].Text);
        Assert.Equal(1, blocks[0].LineCount);
        Assert.InRange(blocks[0].NormalizedLineHeight, 0.045, 0.055);
    }

    [Fact]
    public void SegmentBlocks_RejoinsBrokenEnglishWordsAcrossLineWrap()
    {
        var checker = new MockSpellChecker("Experts", "development");

        List<OcrRawFragment> frags =
        [
            new("Built by Ex", new NormRect(0.10, 0.20, 0.60, 0.05)),
            new("perts in devel-", new NormRect(0.10, 0.26, 0.62, 0.05)),
            new("opment today", new NormRect(0.10, 0.32, 0.45, 0.05)),
        ];

        var blocks = OcrBlockSegmenter.SegmentBlocks(frags, 1000, 1000, checker);
        Assert.Single(blocks);
        Assert.Equal("Built by Experts in development today", blocks[0].Text);
        Assert.Equal(3, blocks[0].LineCount);
        Assert.InRange(blocks[0].NormalizedLineHeight, 0.045, 0.055);
    }

    [Fact]
    public void SegmentBlocks_InterveningSiblingExclusion_StillMergesLeftColumnParagraph()
    {
        List<OcrRawFragment> frags =
        [
            new("First line in left column", new NormRect(0.05, 0.20, 0.35, 0.05)),
            new("Right column note", new NormRect(0.60, 0.23, 0.30, 0.05)),
            new("Second line in left column", new NormRect(0.05, 0.26, 0.35, 0.05)),
        ];

        var blocks = OcrBlockSegmenter.SegmentBlocks(frags, 1000, 1000);
        var leftBlock = blocks.FirstOrDefault(b => b.Text.Contains("First line"));
        Assert.NotNull(leftBlock);
        Assert.Contains("Second line in left column", leftBlock!.Text);
        Assert.Equal(2, leftBlock.LineCount);
    }

    [Fact]
    public void SegmentBlocks_CenteredAlignmentAndAxisContagion()
    {
        List<OcrRawFragment> frags =
        [
            new("Welcome Back", new NormRect(0.35, 0.15, 0.30, 0.07)),
            new("This workspace lets you translate", new NormRect(0.20, 0.25, 0.60, 0.045)),
            new("any UI screenshot directly.", new NormRect(0.27, 0.305, 0.46, 0.045)),
        ];

        var blocks = OcrBlockSegmenter.SegmentBlocks(frags, 1000, 1000);
        Assert.Equal(2, blocks.Count);
        Assert.All(blocks, b => Assert.True(b.IsCentered));
    }
}
