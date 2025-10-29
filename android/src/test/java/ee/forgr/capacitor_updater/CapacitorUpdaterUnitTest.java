package ee.forgr.capacitor_updater;

import static org.junit.Assert.*;

import io.github.g00fy2.versioncompare.Version;
import java.util.Date;
import org.junit.Test;

public class CapacitorUpdaterUnitTest {

    // BundleInfo Tests

    @Test
    public void testBundleInfoInitialization() {
        BundleInfo bundleInfo = new BundleInfo("test-id", "1.0.0", BundleStatus.PENDING, new Date(), "abc123");

        assertEquals("test-id", bundleInfo.getId());
        assertEquals("1.0.0", bundleInfo.getVersionName());
        assertEquals(BundleStatus.PENDING, bundleInfo.getStatus());
        assertEquals("abc123", bundleInfo.getChecksum());
    }

    @Test
    public void testBundleInfoBuiltin() {
        BundleInfo bundleInfo = new BundleInfo(
            BundleInfo.ID_BUILTIN,
            "1.0.0",
            BundleStatus.SUCCESS,
            BundleInfo.DOWNLOADED_BUILTIN,
            "abc123"
        );

        assertTrue(bundleInfo.isBuiltin());
        assertFalse(bundleInfo.isUnknown());
    }

    @Test
    public void testBundleInfoUnknown() {
        BundleInfo bundleInfo = new BundleInfo(
            BundleInfo.VERSION_UNKNOWN,
            "1.0.0",
            BundleStatus.SUCCESS,
            BundleInfo.DOWNLOADED_BUILTIN,
            "abc123"
        );

        assertTrue(bundleInfo.isUnknown());
        assertFalse(bundleInfo.isBuiltin());
    }

    @Test
    public void testBundleInfoErrorStatus() {
        BundleInfo bundleInfo = new BundleInfo("test-id", "1.0.0", BundleStatus.ERROR, new Date(), "abc123");

        assertTrue(bundleInfo.isErrorStatus());
        assertFalse(bundleInfo.isDeleted());
    }

    @Test
    public void testBundleInfoDeleted() {
        BundleInfo bundleInfo = new BundleInfo("test-id", "1.0.0", BundleStatus.DELETED, new Date(), "abc123");

        assertTrue(bundleInfo.isDeleted());
        assertFalse(bundleInfo.isErrorStatus());
    }

    @Test
    public void testBundleInfoIsDownloaded() {
        BundleInfo bundleInfo = new BundleInfo("test-id", "1.0.0", BundleStatus.SUCCESS, new Date(), "abc123");

        assertTrue(bundleInfo.isDownloaded());

        BundleInfo builtinBundle = new BundleInfo(BundleInfo.ID_BUILTIN, "1.0.0", BundleStatus.SUCCESS, new Date(), "abc123");

        assertFalse(builtinBundle.isDownloaded());
    }

    @Test
    public void testBundleInfoSetters() {
        BundleInfo original = new BundleInfo("test-id", "1.0.0", BundleStatus.SUCCESS, new Date(), "abc123");

        BundleInfo withNewChecksum = original.setChecksum("new-checksum");
        assertEquals("new-checksum", withNewChecksum.getChecksum());
        assertEquals("test-id", withNewChecksum.getId());

        BundleInfo withNewId = original.setId("new-id");
        assertEquals("new-id", withNewId.getId());
        assertEquals("abc123", withNewId.getChecksum());

        BundleInfo withNewStatus = original.setStatus(BundleStatus.ERROR);
        assertEquals(BundleStatus.ERROR, withNewStatus.getStatus());
    }

    @Test
    public void testBundleInfoCopyConstructor() {
        BundleInfo original = new BundleInfo("test-id", "1.0.0", BundleStatus.SUCCESS, new Date(), "abc123");

        BundleInfo copy = new BundleInfo(original);

        assertEquals(original.getId(), copy.getId());
        assertEquals(original.getVersionName(), copy.getVersionName());
        assertEquals(original.getStatus(), copy.getStatus());
        assertEquals(original.getChecksum(), copy.getChecksum());
    }

    // BundleStatus Tests

    @Test
    public void testBundleStatusToString() {
        assertEquals("success", BundleStatus.SUCCESS.toString());
        assertEquals("error", BundleStatus.ERROR.toString());
        assertEquals("pending", BundleStatus.PENDING.toString());
        assertEquals("deleted", BundleStatus.DELETED.toString());
        assertEquals("downloading", BundleStatus.DOWNLOADING.toString());
    }

    @Test
    public void testBundleStatusFromString() {
        assertEquals(BundleStatus.SUCCESS, BundleStatus.fromString("success"));
        assertEquals(BundleStatus.ERROR, BundleStatus.fromString("error"));
        assertEquals(BundleStatus.PENDING, BundleStatus.fromString("pending"));
        assertEquals(BundleStatus.DELETED, BundleStatus.fromString("deleted"));
        assertEquals(BundleStatus.DOWNLOADING, BundleStatus.fromString("downloading"));

        // Test null/empty string returns PENDING
        assertEquals(BundleStatus.PENDING, BundleStatus.fromString(null));
        assertEquals(BundleStatus.PENDING, BundleStatus.fromString(""));

        // Test invalid string returns null
        assertNull(BundleStatus.fromString("invalid"));
    }

    // Version Comparison Tests

    @Test
    public void testVersionComparison() {
        Version version1 = new Version("1.0.0");
        Version version2 = new Version("1.0.1");
        Version version3 = new Version("2.0.0");
        Version version4 = new Version("1.0.0");

        assertTrue(version1.isLowerThan(version2));
        assertTrue(version2.isLowerThan(version3));
        assertTrue(version1.isEqual(version4));
        assertFalse(version3.isLowerThan(version1));
    }

    @Test
    public void testVersionIsAtLeast() {
        Version version1 = new Version("1.0.0");
        Version version2 = new Version("1.0.1");

        assertTrue(version2.isAtLeast("1.0.0"));
        assertTrue(version2.isAtLeast("1.0.1"));
        assertFalse(version1.isAtLeast("1.0.1"));
    }

    // Edge Cases Tests

    @Test
    public void testBundleInfoWithNullValues() {
        BundleInfo bundleInfo = new BundleInfo(null, null, null, (String) null, null);

        assertNotNull(bundleInfo.getId());
        assertNotNull(bundleInfo.getStatus());
        assertNotNull(bundleInfo.getChecksum());
    }

    @Test
    public void testLargeDataHandling() {
        // Create a large string
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < 10000; i++) {
            sb.append("test-data-");
        }
        String largeData = sb.toString();

        BundleInfo bundleInfo = new BundleInfo("test-id", largeData, BundleStatus.SUCCESS, new Date(), largeData);

        assertNotNull(bundleInfo);
        assertEquals(largeData, bundleInfo.getVersionName());
        assertEquals(largeData, bundleInfo.getChecksum());
    }
}
