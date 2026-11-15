using Microsoft.Data.Sqlite;
using SkiaSharp;
using WinPaste.Core.Models;
using WinPaste.Core.Storage;
using Xunit;

namespace WinPaste.Tests;

public sealed class HistoryStoreTests : IDisposable
{
    private readonly string _tempDir;
    private readonly AppPaths _paths;
    private int _limit = 100;
    private readonly HistoryStore _historyStore;

    public HistoryStoreTests()
    {
        _tempDir = Path.Combine(Path.GetTempPath(), "WinPasteTests_" + Guid.NewGuid().ToString("N"));
        _paths = new AppPaths(_tempDir);
        _paths.EnsureDirectories();
        _historyStore = new HistoryStore(_paths, () => _limit);
    }

    public void Dispose()
    {
        _historyStore.Dispose();
        try { Directory.Delete(_tempDir, recursive: true); } catch { }
    }

    [Fact]
    public void Upsert_And_Fetch_DeduplicatesExactContent()
    {
        var t0 = DateTimeOffset.UtcNow;
        Assert.True(_historyStore.Upsert(ClipboardKind.ShortText, "hello world", null, null, HashHelper.Sha256Hex("hello world"), timestamp: t0));
        Assert.True(_historyStore.Upsert(ClipboardKind.ShortText, "second item", null, null, HashHelper.Sha256Hex("second item"), timestamp: t0.AddSeconds(1)));
        Assert.False(_historyStore.Upsert(ClipboardKind.ShortText, "hello world", null, null, HashHelper.Sha256Hex("hello world"), timestamp: t0.AddSeconds(2)));

        var all = _historyStore.Fetch(ClipboardKind.ShortText, "", limit: 50);
        Assert.Equal(2, all.Count);
        Assert.Equal("second item", all[0].Content);
        Assert.Equal("hello world", all[1].Content);
    }

    [Fact]
    public void Upsert_MultiLineSegmentDedupe_SkipsChildSegmentWhenMultiLineParentExists()
    {
        const string multi = "Line One\nLine Two\nLine Three";
        Assert.True(_historyStore.Upsert(ClipboardKind.ShortText, multi, null, null, HashHelper.Sha256Hex(multi)));
        Assert.False(_historyStore.Upsert(ClipboardKind.ShortText, "Line Two", null, null, HashHelper.Sha256Hex("Line Two")));

        var items = _historyStore.Fetch(ClipboardKind.ShortText, "", limit: 50);
        Assert.Single(items);
        Assert.Equal(3, items[0].Paragraphs.Count);
    }

    [Fact]
    public void Fetch_SearchEscapesSqlLikeWildcards()
    {
        _historyStore.Upsert(ClipboardKind.ShortText, "100% legit_item", null, null, HashHelper.Sha256Hex("100% legit_item"));
        _historyStore.Upsert(ClipboardKind.ShortText, "normal item", null, null, HashHelper.Sha256Hex("normal item"));

        var pctResults = _historyStore.Fetch(ClipboardKind.ShortText, "%", limit: 50);
        Assert.Single(pctResults);
        Assert.Equal("100% legit_item", pctResults[0].Content);

        var underscoreResults = _historyStore.Fetch(ClipboardKind.ShortText, "_", limit: 50);
        Assert.Single(underscoreResults);
        Assert.Equal("100% legit_item", underscoreResults[0].Content);
    }

    [Fact]
    public void Eviction_PreservesPinnedItems()
    {
        _historyStore.Upsert(ClipboardKind.ShortText, "keep me", null, null, HashHelper.Sha256Hex("keep me"));
        var pinned = _historyStore.Fetch(ClipboardKind.ShortText, "keep me", 10).Single();
        _historyStore.SetPinned(pinned.Id, true);

        _limit = 3;
        for (int i = 0; i < 6; i++)
        {
            string s = $"item {i}";
            _historyStore.Upsert(ClipboardKind.ShortText, s, null, null, HashHelper.Sha256Hex(s),
                timestamp: DateTimeOffset.UtcNow.AddSeconds(i + 1));
        }

        var remaining = _historyStore.Fetch(ClipboardKind.ShortText, "", limit: 50);
        Assert.Contains(remaining, x => x.Content == "keep me" && x.Pinned);
        Assert.Equal(4, remaining.Count); // 1 pinned + 3 unpinned
    }

    [Fact]
    public void ClearAll_RespectsKeepPinnedFlag()
    {
        _historyStore.Upsert(ClipboardKind.ShortText, "pinned note", null, null, HashHelper.Sha256Hex("pinned note"));
        var item = _historyStore.Fetch(ClipboardKind.ShortText, "", 10).Single();
        _historyStore.SetPinned(item.Id, true);
        _historyStore.Upsert(ClipboardKind.ShortText, "ephemeral note", null, null, HashHelper.Sha256Hex("ephemeral note"));

        _historyStore.ClearAll(keepPinned: true);
        var afterKeep = _historyStore.Fetch(ClipboardKind.ShortText, "", 50);
        Assert.Single(afterKeep);
        Assert.Equal("pinned note", afterKeep[0].Content);

        _historyStore.ClearAll(keepPinned: false);
        Assert.Empty(_historyStore.Fetch(ClipboardKind.ShortText, "", 50));
    }

    [Fact]
    public void ImageStore_IdenticalVisualPngAndWebp_ProduceIdenticalPixelFingerprint()
    {
        using var bmp = new SKBitmap(64, 48, SKColorType.Bgra8888, SKAlphaType.Premul);
        using (var c = new SKCanvas(bmp))
        {
            c.Clear(new SKColor(240, 244, 250));
            using var p = new SKPaint { Color = new SKColor(0, 122, 255) };
            c.DrawRect(8, 8, 48, 32, p);
        }

        using var img = SKImage.FromBitmap(bmp);
        byte[] png1 = img.Encode(SKEncodedImageFormat.Png, 100).ToArray();
        byte[] webp = img.Encode(SKEncodedImageFormat.Webp, 100).ToArray();

        string? fp1 = ImageStore.PixelFingerprint(png1);
        string? fp2 = ImageStore.PixelFingerprint(webp);
        Assert.NotNull(fp1);
        Assert.Equal(fp1, fp2);

        var saved = ImageStore.Save(png1, _paths);
        Assert.NotNull(saved);
        Assert.True(File.Exists(saved!.DataPath));
        Assert.True(File.Exists(saved.ThumbPath));
        Assert.Equal(png1.Length, saved.PngByteCount);
        Assert.Equal(png1, File.ReadAllBytes(saved.DataPath));
    }

    [Fact]
    public void Migration_FromV1Schema_UpgradesToV3AndDeduplicatesImages()
    {
        string migDir = Path.Combine(_tempDir, "mig");
        var migPaths = new AppPaths(migDir);
        migPaths.EnsureDirectories();

        using var bmp = new SKBitmap(32, 32);
        using (var c = new SKCanvas(bmp)) c.Clear(SKColors.Coral);
        using var img = SKImage.FromBitmap(bmp);
        byte[] png = img.Encode(SKEncodedImageFormat.Png, 100).ToArray();
        byte[] webp = img.Encode(SKEncodedImageFormat.Webp, 100).ToArray();
        var s1 = ImageStore.Save(png, migPaths)!;
        string extraPath = Path.Combine(migPaths.ImagesDir, "legacy_dup.png");
        string extraThumb = Path.Combine(migPaths.ThumbsDir, "legacy_dup.png");
        File.WriteAllBytes(extraPath, webp);
        File.WriteAllBytes(extraThumb, webp);

        using (var conn = new SqliteConnection($"Data Source={migPaths.DbPath}"))
        {
            conn.Open();
            using var cmd = conn.CreateCommand();
            cmd.CommandText = """
                CREATE TABLE history(
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    kind INTEGER NOT NULL,
                    content TEXT NOT NULL DEFAULT '',
                    data_path TEXT,
                    thumb_path TEXT,
                    hash TEXT NOT NULL,
                    pinned INTEGER NOT NULL DEFAULT 0,
                    created_at REAL NOT NULL
                );
                PRAGMA user_version = 1;
                """;
            cmd.ExecuteNonQuery();

            using var ins = conn.CreateCommand();
            ins.CommandText = "INSERT INTO history(kind, content, data_path, thumb_path, hash, pinned, created_at) VALUES(2, '32×32', $dp, $tp, $h, 0, $t)";
            ins.Parameters.AddWithValue("$dp", s1.DataPath);
            ins.Parameters.AddWithValue("$tp", s1.ThumbPath);
            ins.Parameters.AddWithValue("$h", "h1");
            ins.Parameters.AddWithValue("$t", 1000.0);
            ins.ExecuteNonQuery();

            ins.Parameters["$dp"].Value = extraPath;
            ins.Parameters["$tp"].Value = extraThumb;
            ins.Parameters["$h"].Value = "h2";
            ins.Parameters["$t"].Value = 2000.0;
            ins.ExecuteNonQuery();
        }

        using var store = new HistoryStore(migPaths, () => 100);
        var rows = store.Fetch(ClipboardKind.Image, "", 10);
        Assert.Single(rows);
        Assert.False(string.IsNullOrEmpty(rows[0].ThumbPath));
    }
}
