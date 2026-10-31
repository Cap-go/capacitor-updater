package ee.forgr.capacitor_updater;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import android.content.res.AssetManager;
import java.io.ByteArrayInputStream;
import java.io.File;
import java.io.FileNotFoundException;
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
            when(assets.open(eq(assetPath))).thenReturn(new ByteArrayInputStream(assetBytes));
        }
        return assets;
    }

    @Test
    public void builtinHashVerdictReturnsNullWhenTableMissing() throws Exception {
        final AssetManager assets = assetsWithTable(null, null, null);
        assertNull(DownloadService.builtinHashVerdict(assets, "public/index.html", "abc"));
    }

    @Test
    public void builtinHashVerdictMatchesStoredHashWithoutReadingAsset() throws Exception {
        final String hash = CryptoCipher.calcChecksum(new ByteArrayInputStream("hello".getBytes(StandardCharsets.UTF_8)));
        final String table = "{\"files\":{\"index.html\":\"" + hash + "\"}}";
        final AssetManager assets = assetsWithTable(table, null, null);
        assertEquals(Boolean.TRUE, DownloadService.builtinHashVerdict(assets, "public/index.html", hash));
        assertEquals(Boolean.FALSE, DownloadService.builtinHashVerdict(assets, "public/index.html", "deadbeef"));
    }

    @Test
    public void builtinHashVerdictReturnsNullForPathNotInTable() throws Exception {
        final String table = "{\"files\":{\"index.html\":\"abc\"}}";
        final AssetManager assets = assetsWithTable(table, null, null);
        assertNull(DownloadService.builtinHashVerdict(assets, "public/other.html", "abc"));
    }

    @Test
    public void builtinAssetMatchesUsesTableWithoutOpeningContentAsset() throws Exception {
        final byte[] content = "builtin body".getBytes(StandardCharsets.UTF_8);
        final String hash = CryptoCipher.calcChecksum(new ByteArrayInputStream(content));
        final String table = "{\"files\":{\"index.html\":\"" + hash + "\"}}";
        final AssetManager assets = assetsWithTable(table, "public/index.html", content);
        assertTrue(DownloadService.builtinAssetMatches(assets, "index.html", hash));
        verify(assets, never()).open(eq("public/index.html"));
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
        final String table = "{\"files\":{\"index.html\":\"0000000000000000000000000000000000000000000000000000000000000000\"}}";
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
        final String table = "{\"files\":{\"index.html\":\"" + hash + "\"}}";
        final AssetManager assets = assetsWithTable(table, "public/index.html", content);
        final File dest = File.createTempFile("capgo-builtin-test-", ".dat");
        dest.deleteOnExit();
        assertTrue(DownloadService.tryCopyBuiltinAsset(assets, "index.html", dest, hash));
        assertTrue(dest.exists());
        assertEquals(hash, CryptoCipher.calcChecksum(dest));
    }
}
