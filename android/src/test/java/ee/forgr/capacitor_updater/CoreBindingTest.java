package ee.forgr.capacitor_updater;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.fail;

import java.io.File;
import java.nio.file.Files;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import org.json.JSONArray;
import org.json.JSONObject;
import org.junit.Test;

/**
 * Smoke test of the JNI binding: one core call and one engine call. The shared contract fixtures
 * (native-contract-tests/) run in Rust (core/tests/contract.rs).
 */
public class CoreBindingTest {

    @Test
    public void coreCallReturnsValuesAndErrorCodes() throws Exception {
        final JSONObject resolved = CapgoCore.call("resolvePathInside", CapgoCore.input("base", "/data/versions", "path", "abc"));
        assertEquals("/data/versions/abc", resolved.getString("path"));
        try {
            CapgoCore.call("resolvePathInside", CapgoCore.input("base", "/data/versions", "path", "../abc"));
            fail("path traversal must fail");
        } catch (final CapgoCore.Failure failure) {
            assertEquals("path_traversal", failure.code);
        }
    }

    @Test
    public void engineCallReachesTheHost() throws Exception {
        final File root = Files.createTempDirectory("capgo-binding").toFile();
        final Map<String, String> store = new ConcurrentHashMap<>();
        final CapgoEngineHost host = new CapgoEngineHost() {
            @Override
            void log(final int level, final String message) {}

            @Override
            String kvGet(final String key, final String defaultValue) {
                return store.getOrDefault(key, defaultValue);
            }

            @Override
            boolean kvContains(final String key) {
                return store.containsKey(key);
            }

            @Override
            void kvSet(final String key, final String value) {
                if (value == null) {
                    store.remove(key);
                } else {
                    store.put(key, value);
                }
            }

            @Override
            String kvKeysJson() {
                return new JSONArray(store.keySet()).toString();
            }

            @Override
            void emit(final String event, final String payloadJson) {}
        };
        final CapgoEngine engine = new CapgoEngine(
            CapgoCore.input(
                "platform",
                "android",
                "appId",
                "app.capgo.binding",
                "bundleRoot",
                new File(root, "versions").getAbsolutePath(),
                "storageRoot",
                root.getAbsolutePath()
            ),
            host
        );
        try {
            final JSONObject saved = engine.call(
                "bundleSave",
                CapgoCore.input("id", "abc", "bundle", CapgoCore.input("id", "abc", "version", "1.2.3", "status", "success"))
            );
            assertEquals(true, saved.getBoolean("saved"));
            assertEquals("1.2.3", engine.call("bundleGet", CapgoCore.input("id", "abc")).getString("version"));
        } finally {
            engine.close();
        }
    }
}
