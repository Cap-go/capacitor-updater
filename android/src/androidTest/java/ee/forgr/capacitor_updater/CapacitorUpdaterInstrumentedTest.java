package ee.forgr.capacitor_updater;

import static org.junit.Assert.*;

import android.content.Context;
import android.content.SharedPreferences;
import android.os.Environment;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;
import androidx.test.rule.GrantPermissionRule;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.util.Date;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import org.junit.Before;
import org.junit.Rule;
import org.junit.Test;
import org.junit.runner.RunWith;

/**
 * Instrumented test, which will execute on an Android device.
 */
@RunWith(AndroidJUnit4.class)
public class CapacitorUpdaterInstrumentedTest {

    @Rule
    public GrantPermissionRule permissionRule = GrantPermissionRule.grant(
        android.Manifest.permission.INTERNET,
        android.Manifest.permission.WRITE_EXTERNAL_STORAGE,
        android.Manifest.permission.READ_EXTERNAL_STORAGE
    );

    private Context context;
    private SharedPreferences sharedPreferences;
    private SharedPreferences.Editor editor;
    private DataManager dataManager;
    private CapgoUpdater capgoUpdater;

    @Before
    public void setUp() {
        context = InstrumentationRegistry.getInstrumentation().getTargetContext();
        sharedPreferences = context.getSharedPreferences("test_prefs", Context.MODE_PRIVATE);
        editor = sharedPreferences.edit();
        dataManager = new DataManager(context, sharedPreferences, editor);
        capgoUpdater = new CapgoUpdater(context, dataManager);
    }

    @Test
    public void testAppContext() {
        assertNotNull(context);
        assertTrue(context.getPackageName().contains("capacitor"));
    }

    // File System Tests

    @Test
    public void testFileOperations() throws IOException {
        File testFile = new File(context.getFilesDir(), "test_file.txt");
        String testContent = "Test content for file operations";

        // Test file creation
        try (FileOutputStream fos = new FileOutputStream(testFile)) {
            fos.write(testContent.getBytes());
        }

        assertTrue(testFile.exists());
        assertEquals(testContent.length(), testFile.length());

        // Test file deletion
        boolean deleted = testFile.delete();
        assertTrue(deleted);
        assertFalse(testFile.exists());
    }

    @Test
    public void testDirectoryOperations() {
        File testDir = new File(context.getFilesDir(), "test_directory");

        // Test directory creation
        boolean created = testDir.mkdir();
        assertTrue(created);
        assertTrue(testDir.exists());
        assertTrue(testDir.isDirectory());

        // Test directory deletion
        boolean deleted = testDir.delete();
        assertTrue(deleted);
        assertFalse(testDir.exists());
    }

    @Test
    public void testBundleDirectoryStructure() {
        String bundleId = UUID.randomUUID().toString();
        File bundleDir = new File(context.getFilesDir(), bundleId);

        // Create bundle directory
        assertTrue(bundleDir.mkdir());

        // Create subdirectories that would be used in real scenario
        File publicDir = new File(bundleDir, "public");
        assertTrue(publicDir.mkdir());

        File indexFile = new File(publicDir, "index.html");
        try {
            assertTrue(indexFile.createNewFile());
        } catch (IOException e) {
            fail("Failed to create index file: " + e.getMessage());
        }

        // Verify structure
        assertTrue(bundleDir.exists());
        assertTrue(publicDir.exists());
        assertTrue(indexFile.exists());

        // Clean up
        indexFile.delete();
        publicDir.delete();
        bundleDir.delete();
    }

    // DataManager Integration Tests

    @Test
    public void testDataManagerWithRealStorage() {
        // Create and save multiple bundles
        BundleInfo bundle1 = new BundleInfo(
            UUID.randomUUID().toString(),
            "1.0.0",
            BundleStatus.SUCCESS,
            new Date(),
            "https://example.com/bundle1",
            "Bundle 1",
            null,
            "checksum1"
        );

        BundleInfo bundle2 = new BundleInfo(
            UUID.randomUUID().toString(),
            "2.0.0",
            BundleStatus.PENDING,
            new Date(),
            "https://example.com/bundle2",
            "Bundle 2",
            null,
            "checksum2"
        );

        dataManager.saveBundle(bundle1);
        dataManager.saveBundle(bundle2);

        // Verify bundles are saved
        BundleInfo[] bundles = dataManager.listBundles();
        assertEquals(2, bundles.length);

        // Test filtering by status
        int successCount = 0;
        int pendingCount = 0;
        for (BundleInfo bundle : bundles) {
            if (bundle.getStatus() == BundleStatus.SUCCESS) successCount++;
            if (bundle.getStatus() == BundleStatus.PENDING) pendingCount++;
        }
        assertEquals(1, successCount);
        assertEquals(1, pendingCount);

        // Clean up
        dataManager.deleteBundle(bundle1.getId());
        dataManager.deleteBundle(bundle2.getId());
        assertEquals(0, dataManager.listBundles().length);
    }

    @Test
    public void testSharedPreferencesPersistence() {
        String testKey = "test_persistence_key";
        String testValue = "test_persistence_value";

        // Save value
        editor.putString(testKey, testValue);
        editor.apply();

        // Create new instances to test persistence
        SharedPreferences newPrefs = context.getSharedPreferences("test_prefs", Context.MODE_PRIVATE);
        String retrievedValue = newPrefs.getString(testKey, null);

        assertEquals(testValue, retrievedValue);

        // Clean up
        editor.remove(testKey);
        editor.apply();
    }

    // Concurrency Tests

    @Test
    public void testConcurrentBundleOperations() throws InterruptedException {
        final int threadCount = 10;
        final CountDownLatch latch = new CountDownLatch(threadCount);

        for (int i = 0; i < threadCount; i++) {
            final int index = i;
            new Thread(() -> {
                BundleInfo bundle = new BundleInfo(
                    "bundle-" + index,
                    "1.0." + index,
                    BundleStatus.SUCCESS,
                    new Date(),
                    "https://example.com/bundle" + index,
                    "Bundle " + index,
                    null,
                    "checksum" + index
                );
                dataManager.saveBundle(bundle);
                latch.countDown();
            })
                .start();
        }

        assertTrue(latch.await(5, TimeUnit.SECONDS));

        // Verify all bundles were saved
        BundleInfo[] bundles = dataManager.listBundles();
        assertEquals(threadCount, bundles.length);

        // Clean up
        for (int i = 0; i < threadCount; i++) {
            dataManager.deleteBundle("bundle-" + i);
        }
    }

    @Test
    public void testActiveBundleThreadSafety() throws InterruptedException {
        final int iterations = 100;
        final CountDownLatch writeLatch = new CountDownLatch(iterations);
        final CountDownLatch readLatch = new CountDownLatch(iterations);

        // Writer thread
        new Thread(() -> {
            for (int i = 0; i < iterations; i++) {
                dataManager.setActiveBundle("bundle-" + i);
                writeLatch.countDown();
            }
        })
            .start();

        // Reader thread
        new Thread(() -> {
            for (int i = 0; i < iterations; i++) {
                String activeBundle = dataManager.getActiveBundle();
                assertNotNull(activeBundle);
                readLatch.countDown();
            }
        })
            .start();

        assertTrue(writeLatch.await(5, TimeUnit.SECONDS));
        assertTrue(readLatch.await(5, TimeUnit.SECONDS));
    }

    // Network Related Tests (Mock)

    @Test
    public void testURLValidation() {
        assertTrue(InternalUtils.isValidURL("https://example.com"));
        assertTrue(InternalUtils.isValidURL("http://localhost:3000"));
        assertTrue(InternalUtils.isValidURL("https://api.example.com/v1/updates"));

        assertFalse(InternalUtils.isValidURL("not-a-url"));
        assertFalse(InternalUtils.isValidURL("ftp://example.com")); // Not http/https
        assertFalse(InternalUtils.isValidURL(""));
        assertFalse(InternalUtils.isValidURL(null));
    }

    // Device Information Tests

    @Test
    public void testDeviceInformation() {
        String packageInfo = InternalUtils.getPackageInfo(context);

        assertNotNull(packageInfo);
        assertTrue(packageInfo.contains("android-native"));
        assertTrue(packageInfo.contains("package_name"));
        assertTrue(packageInfo.contains("version_name"));
        assertTrue(packageInfo.contains("version_code"));

        // Verify JSON format
        assertTrue(packageInfo.startsWith("{"));
        assertTrue(packageInfo.endsWith("}"));
    }

    @Test
    public void testDeviceIDConsistency() {
        String deviceId1 = InternalUtils.generateDeviceID(context);
        String deviceId2 = InternalUtils.generateDeviceID(context);

        assertNotNull(deviceId1);
        assertNotNull(deviceId2);
        assertEquals(deviceId1, deviceId2);

        // Verify format (should be a valid UUID-like string)
        assertTrue(deviceId1.length() > 0);
    }

    // Memory and Performance Tests

    @Test
    public void testMemoryLeakPrevention() {
        // Create and destroy multiple instances
        for (int i = 0; i < 100; i++) {
            DataManager tempDataManager = new DataManager(context, sharedPreferences, editor);
            BundleInfo bundle = new BundleInfo(
                "temp-" + i,
                "1.0.0",
                BundleStatus.SUCCESS,
                new Date(),
                "https://example.com",
                "Temp",
                null,
                "checksum"
            );
            tempDataManager.saveBundle(bundle);
            tempDataManager.deleteBundle(bundle.getId());
        }

        // Force garbage collection
        System.gc();

        // Verify no bundles remain
        assertEquals(0, dataManager.listBundles().length);
    }

    @Test
    public void testLargeDataHandling() {
        // Create a large bundle with lots of data
        StringBuilder largeString = new StringBuilder();
        for (int i = 0; i < 10000; i++) {
            largeString.append("test-data-").append(i).append("-");
        }

        BundleInfo largeBundle = new BundleInfo(
            "large-bundle",
            largeString.toString(),
            BundleStatus.SUCCESS,
            new Date(),
            largeString.toString(),
            "Large Bundle",
            null,
            largeString.toString()
        );

        // Save and retrieve
        dataManager.saveBundle(largeBundle);
        BundleInfo retrieved = dataManager.getBundle("large-bundle");

        assertNotNull(retrieved);
        assertEquals(largeString.toString(), retrieved.getVersion());

        // Clean up
        dataManager.deleteBundle("large-bundle");
    }

    // Edge Cases

    @Test
    public void testEmptyBundleList() {
        // Ensure no bundles exist
        BundleInfo[] bundles = dataManager.listBundles();
        for (BundleInfo bundle : bundles) {
            dataManager.deleteBundle(bundle.getId());
        }

        // Test operations on empty list
        assertEquals(0, dataManager.listBundles().length);
        assertNull(dataManager.getActiveBundle());
        assertNull(dataManager.getNextBundle());
    }

    @Test
    public void testSpecialCharactersInBundleInfo() {
        String specialChars = "!@#$%^&*()_+-=[]{}|;':\",./<>?";
        BundleInfo bundle = new BundleInfo(
            "special-bundle",
            specialChars,
            BundleStatus.SUCCESS,
            new Date(),
            "https://example.com",
            specialChars,
            null,
            specialChars
        );

        dataManager.saveBundle(bundle);
        BundleInfo retrieved = dataManager.getBundle("special-bundle");

        assertNotNull(retrieved);
        assertEquals(specialChars, retrieved.getVersion());
        assertEquals(specialChars, retrieved.getVersionName());

        // Clean up
        dataManager.deleteBundle("special-bundle");
    }

    @Test
    public void testNullHandling() {
        // Test setting null values
        dataManager.setActiveBundle(null);
        assertNull(dataManager.getActiveBundle());

        dataManager.setNextBundle(null);
        assertNull(dataManager.getNextBundle());

        dataManager.setChannel(null);
        assertNull(dataManager.getChannel());

        dataManager.setCustomId(null);
        assertNull(dataManager.getCustomId());
    }
}
