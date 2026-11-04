package ee.forgr.capacitor_updater;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.spy;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import android.content.res.AssetFileDescriptor;
import android.content.res.AssetManager;
import java.io.ByteArrayInputStream;
import java.io.File;
import java.io.FileNotFoundException;
import java.io.IOException;
import java.lang.reflect.Field;
import java.nio.charset.StandardCharsets;
import org.junit.After;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;

@RunWith(RobolectricTestRunner.class)
public class BuiltinHashesTest {

    private static final String TABLE_ASSET = DownloadService.BUILTIN_HASHES_ASSET;

    @Before
    @After
    public void resetBuiltinHashesCache() throws Exception {
        final Field field = DownloadService.class.getDeclaredField("builtinHashes");
        field.setAccessible(true);
        field.set(null, null);
    }

    private static AssetManager assetsWithTable(final String tableJson, final String assetPath, final byte[] assetBytes) throws Exception {
        final AssetManager assets = mock(AssetManager.class);
        if (tableJson == null) {
            when(assets.open(TABLE_ASSET)).thenThrow(new FileNotFoundException(TABLE_ASSET));
        } else {
            when(assets.open(TABLE_ASSET)).thenReturn(new ByteArrayInputStream(tableJson.getBytes(StandardCharsets.UTF_8)));
        }
        if (assetPath != null && assetBytes != null) {
            when(assets.open(eq(assetPath))).thenAnswer((invocation) -> new ByteArrayInputStream(assetBytes));
            final AssetFileDescriptor afd = mock(AssetFileDescriptor.class);
            when(afd.getLength()).thenReturn((long) assetBytes.length);
            when(assets.openFd(eq(assetPath))).thenReturn(afd);
        }
        return assets;
    }

    private static String tableJson(final String relPath, final String hash, final long size) {
        return "{\"files\":{\"" + relPath + "\":{\"sha256\":\"" + hash + "\",\"size\":" + size + "}}}";
    }

    private static String tableJsonLegacyString(final String relPath, final String hash) {
        return "{\"files\":{\"" + relPath + "\":\"" + hash + "\"}}";
    }

    @Test
    public void builtinHashVerdictAcceptsLegacyStringTableEntry() throws Exception {
        final byte[] content = "legacy string entry".getBytes(StandardCharsets.UTF_8);
        final String hash = CryptoCipher.calcChecksum(new ByteArrayInputStream(content));
        final String table = tableJsonLegacyString("index.html", hash);
        final AssetManager assets = assetsWithTable(table, "public/index.html", content);
        assertEquals(Boolean.TRUE, DownloadService.builtinHashVerdict(assets, "public/index.html", hash));
        assertTrue(DownloadService.builtinAssetMatches(assets, "index.html", hash));
    }

    @Test
    public void builtinHashVerdictFallsBackWhenOpenFdFails() throws Exception {
        final byte[] content = "compressed asset".getBytes(StandardCharsets.UTF_8);
        final String hash = CryptoCipher.calcChecksum(new ByteArrayInputStream(content));
        final String table = tableJson("index.html", hash, content.length);
        final AssetManager assets = assetsWithTable(table, "public/index.html", content);
        when(assets.openFd(eq("public/index.html"))).thenThrow(new IOException("Asset not compressed with openFd"));
        assertNull(DownloadService.builtinHashVerdict(assets, "public/index.html", hash));
        assertTrue(DownloadService.builtinAssetMatches(assets, "index.html", hash));
    }

    @Test
    public void builtinHashVerdictFallsBackWhenTableSizeStale() throws Exception {
        final byte[] content = "size stale".getBytes(StandardCharsets.UTF_8);
        final String hash = CryptoCipher.calcChecksum(new ByteArrayInputStream(content));
        final String tableHash = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
        final String table = "{\"files\":{\"index.html\":{\"sha256\":\"" + tableHash + "\",\"size\":" + (content.length + 50) + "}}}";
        final AssetManager assets = assetsWithTable(table, "public/index.html", content);
        assertNull(DownloadService.builtinHashVerdict(assets, "public/index.html", hash));
        assertTrue(DownloadService.builtinAssetMatches(assets, "index.html", hash));
    }

    @Test
    public void builtinHashVerdictReturnsNullWhenTableMissing() throws Exception {
        final AssetManager assets = assetsWithTable(null, null, null);
        assertNull(DownloadService.builtinHashVerdict(assets, "public/index.html", "abc"));
    }

    @Test
    public void builtinHashVerdictMatchesStoredHashWithoutReadingAsset() throws Exception {
        final byte[] content = "hello".getBytes(StandardCharsets.UTF_8);
        final String hash = CryptoCipher.calcChecksum(new ByteArrayInputStream(content));
        final String table = tableJson("index.html", hash, content.length);
        final AssetManager assets = assetsWithTable(table, "public/index.html", content);
        assertEquals(Boolean.TRUE, DownloadService.builtinHashVerdict(assets, "public/index.html", hash));
        assertEquals(
            Boolean.FALSE,
            DownloadService.builtinHashVerdict(
                assets,
                "public/index.html",
                "0000000000000000000000000000000000000000000000000000000000000000"
            )
        );
    }

    @Test
    public void builtinHashVerdictReturnsNullForPathNotInTable() throws Exception {
        final String table = "{\"files\":{\"index.html\":\"abc\"}}";
        final AssetManager assets = assetsWithTable(table, null, null);
        assertNull(DownloadService.builtinHashVerdict(assets, "public/other.html", "abc"));
    }

    @Test
    public void builtinHashVerdictFallsBackWhenTableSizeMalformed() throws Exception {
        final byte[] content = "malformed size field".getBytes(StandardCharsets.UTF_8);
        final String hash = CryptoCipher.calcChecksum(new ByteArrayInputStream(content));
        final String tableHash = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
        final String table = "{\"files\":{\"index.html\":{\"sha256\":\"" + tableHash + "\",\"size\":\"not-a-number\"}}}";
        final AssetManager assets = assetsWithTable(table, "public/index.html", content);
        assertNull(DownloadService.builtinHashVerdict(assets, "public/index.html", hash));
        assertTrue(DownloadService.builtinAssetMatches(assets, "index.html", hash));
    }

    @Test
    public void builtinAssetMatchesUsesTableWithoutRehashingContentAsset() throws Exception {
        final byte[] content = "builtin body".getBytes(StandardCharsets.UTF_8);
        final String hash = CryptoCipher.calcChecksum(new ByteArrayInputStream(content));
        final String table = tableJson("index.html", hash, content.length);
        final AssetManager assets = assetsWithTable(table, "public/index.html", content);
        final ByteArrayInputStream contentStream = spy(new ByteArrayInputStream(content));
        when(assets.open(eq("public/index.html"))).thenAnswer((invocation) -> contentStream);
        assertTrue(DownloadService.builtinAssetMatches(assets, "index.html", hash));
        verify(assets).open(eq("public/index.html"));
        verify(contentStream, never()).read(any(byte[].class));
    }

    @Test
    public void builtinAssetMatchesFallsBackToHashingWhenPathMissingFromTable() throws Exception {
        final byte[] content = "fallback".getBytes(StandardCharsets.UTF_8);
        final String hash = CryptoCipher.calcChecksum(new ByteArrayInputStream(content));
        final String table = "{\"files\":{\"other.html\":\"" + hash + "\"}}";
        final AssetManager assets = assetsWithTable(table, "public/index.html", content);
        assertTrue(DownloadService.builtinAssetMatches(assets, "index.html", hash));
        verify(assets).open(eq("public/index.html"));
    }

    @Test
    public void tryCopyBuiltinAssetSkipsCopyWhenTableSaysMismatch() throws Exception {
        final byte[] content = "content".getBytes(StandardCharsets.UTF_8);
        final String hash = CryptoCipher.calcChecksum(new ByteArrayInputStream(content));
        final String table = tableJson("index.html", "0000000000000000000000000000000000000000000000000000000000000000", content.length);
        final AssetManager assets = assetsWithTable(table, "public/index.html", content);
        final File dest = new File(System.getProperty("java.io.tmpdir"), "capgo-builtin-mismatch-" + System.nanoTime() + ".dat");
        assertFalse(dest.exists());
        assertFalse(DownloadService.tryCopyBuiltinAsset(assets, "index.html", dest, hash));
        verify(assets, never()).open(eq("public/index.html"));
        assertFalse(dest.exists());
    }

    @Test
    public void tryCopyBuiltinAssetCopiesWithoutRehashWhenTableMatches() throws Exception {
        final byte[] content = "copy me".getBytes(StandardCharsets.UTF_8);
        final String hash = CryptoCipher.calcChecksum(new ByteArrayInputStream(content));
        final String table = tableJson("index.html", hash, content.length);
        final AssetManager assets = assetsWithTable(table, "public/index.html", content);
        final File dest = File.createTempFile("capgo-builtin-test-", ".dat");
        dest.deleteOnExit();
        assertTrue(DownloadService.tryCopyBuiltinAsset(assets, "index.html", dest, hash));
        assertTrue(dest.exists());
        assertEquals(hash, CryptoCipher.calcChecksum(dest));
    }

    @Test
    public void builtinHashesReadsTableAssetOnceAcrossManyLookupsAndUpdates() throws Exception {
        final byte[] content = "once".getBytes(StandardCharsets.UTF_8);
        final String hash = CryptoCipher.calcChecksum(new ByteArrayInputStream(content));
        final String table =
            "{\"files\":{\"index.html\":{\"sha256\":\"" +
            hash +
            "\",\"size\":" +
            content.length +
            "},\"app.js\":{\"sha256\":\"" +
            hash +
            "\",\"size\":" +
            content.length +
            "}}}";
        final AssetManager assets = assetsWithTable(table, "public/index.html", content);
        when(assets.open(eq("public/app.js"))).thenAnswer((invocation) -> new ByteArrayInputStream(content));
        final AssetFileDescriptor appJsFd = mock(AssetFileDescriptor.class);
        when(appJsFd.getLength()).thenReturn((long) content.length);
        when(assets.openFd(eq("public/app.js"))).thenReturn(appJsFd);

        for (int i = 0; i < 15; i++) {
            assertEquals(Boolean.TRUE, DownloadService.builtinHashVerdict(assets, "public/index.html", hash));
            assertTrue(DownloadService.builtinAssetMatches(assets, "index.html", hash));
            assertTrue(DownloadService.builtinAssetMatches(assets, "app.js", hash));
        }

        verify(assets, times(1)).open(eq(TABLE_ASSET));
    }

    @Test
    public void builtinHashesReadsMissingTableOnceThenReusesEmptyCache() throws Exception {
        final byte[] content = "fallback once".getBytes(StandardCharsets.UTF_8);
        final String hash = CryptoCipher.calcChecksum(new ByteArrayInputStream(content));
        final AssetManager assets = assetsWithTable(null, "public/index.html", content);

        for (int i = 0; i < 10; i++) {
            assertNull(DownloadService.builtinHashVerdict(assets, "public/index.html", hash));
            assertTrue(DownloadService.builtinAssetMatches(assets, "index.html", hash));
        }

        verify(assets, times(1)).open(eq(TABLE_ASSET));
    }

    @Test
    public void builtinAssetMatchesFallsBackToHashingWhenTableEntryIsMalformed() throws Exception {
        final byte[] content = "malformed table entry".getBytes(StandardCharsets.UTF_8);
        final String hash = CryptoCipher.calcChecksum(new ByteArrayInputStream(content));
        final String table = "{\"files\":{\"index.html\":\"not-a-sha256\"}}";
        final AssetManager assets = assetsWithTable(table, "public/index.html", content);
        assertTrue(DownloadService.builtinAssetMatches(assets, "index.html", hash));
        verify(assets).open(eq("public/index.html"));
    }

    @Test
    public void builtinHashVerdictFallsBackWhenTableSizeNegativeOrFractional() throws Exception {
        final byte[] content = "negative size field".getBytes(StandardCharsets.UTF_8);
        final String hash = CryptoCipher.calcChecksum(new ByteArrayInputStream(content));
        final String tableHash = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
        for (final String size : new String[] { "-5", "12.5" }) {
            resetBuiltinHashesCache();
            final String table = "{\"files\":{\"index.html\":{\"sha256\":\"" + tableHash + "\",\"size\":" + size + "}}}";
            final AssetManager assets = assetsWithTable(table, "public/index.html", content);
            assertNull(DownloadService.builtinHashVerdict(assets, "public/index.html", hash));
            assertTrue(DownloadService.builtinAssetMatches(assets, "index.html", hash));
        }
    }
}
