using WinPaste.Core.Parsing;
using Xunit;

namespace WinPaste.Tests;

public class TableParserTests
{
    [Fact]
    public void LooksLikeTsv_ValidTable_ReturnsTrue()
    {
        string tsv = "Name\tRole\tCity\nAlice\tEngineer\tShanghai\nBob\tDesigner\tBeijing";
        Assert.True(TableParser.LooksLikeTsv(tsv));
    }

    [Fact]
    public void LooksLikeTsv_IndentedCodeWithTabs_ReturnsFalse()
    {
        string code = "if (ready) {\n\t\treturn true;\n\t}\n\telse {\n\t\treturn false;\n\t}";
        Assert.False(TableParser.LooksLikeTsv(code));
    }

    [Fact]
    public void LooksLikeTsv_SingleColumn_ReturnsFalse()
    {
        Assert.False(TableParser.LooksLikeTsv("line1\nline2\nline3"));
    }

    [Fact]
    public void ParseHtml_NestedTableAndEntities_ParsesOuterTableCleanly()
    {
        string html = """
            <html><body>
            <table>
              <tr><th>Key &amp; Name</th><th>Value &lt;tag&gt;</th></tr>
              <tr><td>A&#65;&nbsp;1</td><td><table><tr><td>inner1</td><td>inner2</td></tr></table></td></tr>
              <tr><td>&#x4E2D;&#x6587;</td><td>ok</td></tr>
            </table>
            </body></html>
            """;

        var parsed = TableParser.ParseHtml(html);
        Assert.NotNull(parsed);
        Assert.Equal(3, parsed!.Length);
        Assert.Equal("Key & Name", parsed[0][0]);
        Assert.Equal("Value <tag>", parsed[0][1]);
        Assert.Equal("AA 1", parsed[1][0]);
        Assert.Contains("inner1", parsed[1][1]);
        Assert.Equal("中文", parsed[2][0]);
        Assert.Equal("ok", parsed[2][1]);
    }

    [Fact]
    public void CanonicalTsv_And_HtmlTable_RoundTripAndEscape()
    {
        string[][] rows =
        [
            ["Col 1", "Col 2"],
            ["a b", "c<d>&e"],
            ["onlyOne"]
        ];

        var norm = TableParser.Normalized(rows);
        Assert.NotNull(norm);
        Assert.Equal(3, norm!.Length);
        Assert.All(norm, r => Assert.Equal(2, r.Length));
        Assert.Equal("", norm[2][1]);

        string tsv = TableParser.CanonicalTsv(norm);
        Assert.Contains("a b\tc<d>&e", tsv);

        string html = TableParser.HtmlTable(norm);
        Assert.Contains("<td>c&lt;d&gt;&amp;e</td>", html);
    }

    [Theory]
    [InlineData(0, "A")]
    [InlineData(25, "Z")]
    [InlineData(26, "AA")]
    [InlineData(27, "AB")]
    [InlineData(701, "ZZ")]
    [InlineData(702, "AAA")]
    public void ColumnLetter_MatchesExcelConvention(int index, string expected)
    {
        Assert.Equal(expected, TableParser.ColumnLetter(index));
    }
}
