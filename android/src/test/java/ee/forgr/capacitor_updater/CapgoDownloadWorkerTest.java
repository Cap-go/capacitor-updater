package ee.forgr.capacitor_updater;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertTrue;

import android.content.Context;
import android.content.SharedPreferences;
import android.util.Log;
import androidx.work.Configuration;
import androidx.work.Data;
import androidx.work.ListenableWorker;
import androidx.work.NetworkType;
import androidx.work.WorkInfo;
import androidx.work.WorkManager;
import androidx.work.testing.SynchronousExecutor;
import androidx.work.testing.TestDriver;
import androidx.work.testing.TestWorkerBuilder;
import androidx.work.testing.WorkManagerTestInitHelper;
import com.getcapacitor.plugin.WebView;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.zip.ZipEntry;
import java.util.zip.ZipOutputStream;
import org.json.JSONArray;
import org.json.JSONObject;
import org.junit.After;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import org.robolectric.annotation.Config;
import org.robolectric.shadows.ShadowBuild;

/**
 * Bundle downloads run as WorkManager jobs ({@link CapgoDownloadWorker}) whose runs call the Rust engine, like the
 * previous Android plugin: queued with a network constraint, retried on network failures (resuming the partial file),
 * failed on checksum errors, and finished by a worker even when the plugin is gone.
 */
@RunWith(RobolectricTestRunner.class)
@Config(manifest = Config.NONE)
public class CapgoDownloadWorkerTest {

    private final List<String> events = new CopyOnWriteArrayList<>();
    private final List<String> ranges = new CopyOnWriteArrayList<>();
    private final AtomicInteger truncateNext = new AtomicInteger();
    private final ExecutorService callers = Executors.newCachedThreadPool();
    private Context context;
    private SharedPreferences prefs;
    private CapgoEngine engine;
    private ServerSocket server;
    private String baseUrl;
    private byte[] bundle;

    @Before
    public void setUp() throws Exception {
        // A phone, not an emulator: jobs wait for a connected network.
        ShadowBuild.setBrand("google");
        ShadowBuild.setDevice("oriole");
        ShadowBuild.setFingerprint("google/oriole/oriole:14/AP2A.240805.005/12025142:user/release-keys");
        ShadowBuild.setHardware("oriole");
        ShadowBuild.setManufacturer("Google");
        ShadowBuild.setModel("Pixel 6");
        ShadowBuild.setProduct("oriole");
        this.context = RuntimeEnvironment.getApplication();
        WorkManagerTestInitHelper.initializeTestWorkManager(
            this.context,
            new Configuration.Builder().setMinimumLoggingLevel(Log.DEBUG).setExecutor(new SynchronousExecutor()).build()
        );
        this.prefs = this.context.getSharedPreferences(WebView.WEBVIEW_PREFS_NAME, Context.MODE_PRIVATE);
        this.prefs.edit().clear().commit();
        this.bundle = zip("<html>v2</html>");
        this.server = new ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"));
        final Thread acceptor = new Thread(() -> {
            while (!this.server.isClosed()) {
                try {
                    final Socket socket = this.server.accept();
                    this.callers.execute(() -> this.serve(socket));
                } catch (final Exception e) {
                    return;
                }
            }
        });
        acceptor.setDaemon(true);
        acceptor.start();
        this.baseUrl = "http://127.0.0.1:" + this.server.getLocalPort();
        this.engine = this.createPluginEngine();
        this.engine.call(
            "pluginLoad",
            CapgoCore.input(
                "config",
                CapgoCore.input("autoUpdate", false, "statsUrl", ""),
                "native",
                CapgoCore.input(
                    "versionName",
                    "1.0.0",
                    "versionCode",
                    "10",
                    "noBackupDir",
                    this.context.getNoBackupFilesDir().getAbsolutePath(),
                    "previousExits",
                    new JSONArray()
                )
            )
        );
        CapgoEngineHolder.setPluginEngine(this.engine);
    }

    @After
    public void tearDown() {
        CapgoEngineHolder.reset();
        this.callers.shutdownNow();
        if (this.engine != null) {
            try {
                // Releases calls still waiting for a job, so close() does not wait for them.
                this.engine.call("detachScheduledDownloads", null);
            } catch (final CapgoCore.Failure ignored) {
                // Closed.
            }
            this.engine.close();
        }
        try {
            this.server.close();
        } catch (final Exception ignored) {
            // Closing.
        }
    }

    /** {@code /b.zip}: the whole bundle, the rest of it for a Range request, or half of it when a drop is armed. */
    private void serve(final Socket socket) {
        try (Socket client = socket) {
            final InputStream input = client.getInputStream();
            final StringBuilder head = new StringBuilder();
            int read;
            while ((read = input.read()) != -1) {
                head.append((char) read);
                if (head.length() >= 4 && head.substring(head.length() - 4).equals("\r\n\r\n")) {
                    break;
                }
            }
            String range = "";
            for (final String line : head.toString().split("\r\n")) {
                if (line.toLowerCase(java.util.Locale.ROOT).startsWith("range:")) {
                    range = line.substring(6).trim();
                }
            }
            this.ranges.add(range);
            final int start = range.startsWith("bytes=") ? Integer.parseInt(range.substring(6, range.length() - 1)) : 0;
            final OutputStream output = client.getOutputStream();
            final String status =
                start > 0
                    ? "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes " +
                      start +
                      "-" +
                      (this.bundle.length - 1) +
                      "/" +
                      this.bundle.length +
                      "\r\n"
                    : "HTTP/1.1 200 OK\r\n";
            output.write(
                (status + "Content-Length: " + (this.bundle.length - start) + "\r\nConnection: close\r\n\r\n").getBytes(
                    StandardCharsets.UTF_8
                )
            );
            if (this.truncateNext.getAndDecrement() > 0) {
                // The network drops midway.
                output.write(this.bundle, start, (this.bundle.length - start) / 2);
            } else {
                output.write(this.bundle, start, this.bundle.length - start);
            }
            output.flush();
        } catch (final Exception ignored) {
            // Client went away.
        }
    }

    private CapgoEngine createPluginEngine() {
        final CapgoUpdater updater = new CapgoUpdater(
            this.context,
            this.prefs,
            new Logger("CapgoDownloadWorkerTest", new Logger.Options(Logger.LogLevel.silent)),
            new CapgoUpdater.Listener() {
                @Override
                public void onEvent(final String event, final String payloadJson) {
                    events.add(event);
                }

                @Override
                public String onHook(final String name, final String payloadJson) {
                    return null;
                }
            }
        );
        return updater.createEngine(
            CapgoCore.input(
                "appId",
                "app.capgo.test",
                "pluginVersion",
                "8.0.0",
                "versionBuild",
                "1.0.0",
                "versionCode",
                "10",
                "versionOs",
                "15",
                "deviceId",
                "device-1"
            ),
            "serverBasePath"
        );
    }

    private static byte[] zip(final String index) throws Exception {
        final ByteArrayOutputStream buffer = new ByteArrayOutputStream();
        try (ZipOutputStream zip = new ZipOutputStream(buffer)) {
            zip.putNextEntry(new ZipEntry("index.html"));
            zip.write(index.getBytes("UTF-8"));
            zip.closeEntry();
            // Large enough to be dropped midway.
            zip.putNextEntry(new ZipEntry("filler.txt"));
            final byte[] filler = new byte[256 * 1024];
            for (int index2 = 0; index2 < filler.length; index2++) {
                filler[index2] = (byte) (index2 * 31 + 7);
            }
            zip.write(filler);
            zip.closeEntry();
        }
        return buffer.toByteArray();
    }

    private static String sha256(final byte[] bytes) throws Exception {
        final StringBuilder hex = new StringBuilder();
        for (final byte value : MessageDigest.getInstance("SHA-256").digest(bytes)) {
            hex.append(String.format("%02x", value));
        }
        return hex.toString();
    }

    /** {@code download()} as the plugin runs it: on a method thread, blocking until the job ends. */
    private Future<JSONObject> download(final String checksum) {
        final JSONObject args = CapgoCore.input("url", this.baseUrl + "/b.zip", "version", "2.0.0", "checksum", checksum);
        return this.callers.submit(() -> this.engine.call("pluginMethod", CapgoCore.input("name", "download", "args", args)));
    }

    private WorkInfo awaitJob() throws Exception {
        final long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(10);
        while (System.nanoTime() < deadline) {
            final List<WorkInfo> infos = WorkManager.getInstance(this.context).getWorkInfosByTag(CapgoDownloadWorker.TAG).get();
            if (!infos.isEmpty()) {
                return infos.get(0);
            }
            Thread.sleep(10);
        }
        throw new AssertionError("no download job was enqueued");
    }

    private WorkInfo job(final WorkInfo job) throws Exception {
        return WorkManager.getInstance(this.context).getWorkInfoById(job.getId()).get();
    }

    private Data inputOf(final WorkInfo job) {
        final String id = job
            .getTags()
            .stream()
            .filter((tag) -> tag.length() == 10)
            .findFirst()
            .orElse("");
        return new Data.Builder().putString(CapgoDownloadWorker.KEY_ID, id).putString(CapgoDownloadWorker.KEY_VERSION, "2.0.0").build();
    }

    private TestDriver driver() {
        return WorkManagerTestInitHelper.getTestDriver(this.context);
    }

    private JSONObject storedBundle(final String id) throws Exception {
        return new JSONObject(this.prefs.getString(id + "_info", "{}"));
    }

    @Test
    public void downloadEnqueuesAJobThatWaitsForTheNetwork() throws Exception {
        final Future<JSONObject> call = this.download(sha256(this.bundle));
        final WorkInfo job = this.awaitJob();
        assertEquals(WorkInfo.State.ENQUEUED, job.getState());
        assertEquals(NetworkType.CONNECTED, job.getConstraints().getRequiredNetworkType());
        final String id = job
            .getTags()
            .stream()
            .filter((tag) -> tag.length() == 10)
            .findFirst()
            .orElse("");
        assertTrue(job.getTags().toString(), job.getTags().contains(CapgoDownloadWorker.versionTag("2.0.0")));
        assertEquals("downloading", this.storedBundle(id).getString("status"));
        // Offline: nothing runs and download() stays pending.
        Thread.sleep(200);
        assertFalse(call.isDone());
        assertTrue(this.ranges.isEmpty());

        // The network comes back.
        this.driver().setAllConstraintsMet(job.getId());
        final JSONObject result = call.get(10, TimeUnit.SECONDS);
        assertEquals(result.toString(), id, result.getJSONObject("resolve").getString("id"));
        assertEquals("pending", result.getJSONObject("resolve").getString("status"));
        assertEquals(WorkInfo.State.SUCCEEDED, this.job(job).getState());
        assertTrue(this.events.toString(), this.events.contains("updateAvailable"));
        assertTrue(new File(this.context.getFilesDir(), "versions/" + id + "/index.html").exists());
    }

    /** Emulators often report no validated network to background jobs: their jobs do not wait for one. */
    @Test
    public void emulatorJobsDoNotWaitForTheNetwork() throws Exception {
        ShadowBuild.setProduct("sdk_gphone64_arm64");
        this.download(sha256(this.bundle));
        assertEquals(NetworkType.NOT_REQUIRED, this.awaitJob().getConstraints().getRequiredNetworkType());
    }

    /** The main thread cannot wait for a running job to stop: the caller must not delete its files yet. */
    @Test
    public void cancellingOnTheMainThreadDoesNotClaimTheJobStopped() throws Exception {
        this.download(sha256(this.bundle));
        this.awaitJob();
        final Logger logger = new Logger("CapgoDownloadWorkerTest", new Logger.Options(Logger.LogLevel.silent));
        assertFalse(CapgoDownloadWorker.cancelVersion(this.context, "2.0.0", logger));
    }

    @Test
    public void aDroppedDownloadIsRetriedAndResumed() throws Exception {
        this.truncateNext.set(1);
        final Future<JSONObject> call = this.download(sha256(this.bundle));
        final WorkInfo job = this.awaitJob();
        this.driver().setAllConstraintsMet(job.getId());
        // The run failed with a network error: WorkManager backs off and keeps the job.
        final WorkInfo retrying = this.job(job);
        assertEquals(WorkInfo.State.ENQUEUED, retrying.getState());
        assertEquals(1, retrying.getRunAttemptCount());
        assertFalse(call.isDone());

        // WorkManager runs it again once the backoff elapsed (the test scheduler does not replay backoffs).
        final CapgoDownloadWorker rerun = TestWorkerBuilder.from(this.context, CapgoDownloadWorker.class, new SynchronousExecutor())
            .setInputData(this.inputOf(job))
            .setRunAttemptCount(1)
            .build();
        assertEquals(ListenableWorker.Result.success(), rerun.doWork());
        final JSONObject result = call.get(10, TimeUnit.SECONDS);
        assertEquals(result.toString(), "pending", result.getJSONObject("resolve").getString("status"));
        assertEquals(2, this.ranges.size());
        assertEquals("", this.ranges.get(0));
        assertTrue(this.ranges.toString(), this.ranges.get(1).startsWith("bytes=") && !this.ranges.get(1).equals("bytes=0-"));
    }

    @Test
    public void aChecksumErrorFailsTheJob() throws Exception {
        final Future<JSONObject> call = this.download(sha256("other".getBytes("UTF-8")));
        final WorkInfo job = this.awaitJob();
        this.driver().setAllConstraintsMet(job.getId());
        assertEquals(WorkInfo.State.FAILED, this.job(job).getState());
        final JSONObject result = call.get(10, TimeUnit.SECONDS);
        assertTrue(result.toString(), result.getJSONObject("reject").getString("message").contains("Checksum"));
        final String id = job
            .getTags()
            .stream()
            .filter((tag) -> tag.length() == 10)
            .findFirst()
            .orElse("");
        assertEquals("error", this.storedBundle(id).getString("status"));
        assertEquals(1, this.ranges.size());
    }

    /** The app process died mid-download: WorkManager runs the job later without the plugin and the bundle is recorded. */
    @Test
    public void aJobWithoutThePluginRecordsTheBundle() throws Exception {
        final Future<JSONObject> call = this.download(sha256(this.bundle));
        final WorkInfo job = this.awaitJob();
        final String id = job
            .getTags()
            .stream()
            .filter((tag) -> tag.length() == 10)
            .findFirst()
            .orElse("");
        // The plugin goes away: its call is released, the job stays queued.
        this.engine.call("detachScheduledDownloads", null);
        assertNotNull(call.get(10, TimeUnit.SECONDS).optJSONObject("reject"));
        CapgoEngineHolder.reset();
        this.engine.close();
        this.engine = null;

        this.driver().setAllConstraintsMet(job.getId());
        assertEquals(WorkInfo.State.SUCCEEDED, this.job(job).getState());
        final JSONObject stored = this.storedBundle(id);
        assertEquals("pending", stored.getString("status"));
        assertEquals("2.0.0", stored.getString("version"));
        assertEquals(sha256(this.bundle), stored.getString("checksum"));
        assertTrue(new File(this.context.getFilesDir(), "versions/" + id + "/index.html").exists());
    }

    @Test
    public void deletingTheBundleCancelsItsJob() throws Exception {
        final Future<JSONObject> call = this.download(sha256(this.bundle));
        final WorkInfo job = this.awaitJob();
        final String id = job
            .getTags()
            .stream()
            .filter((tag) -> tag.length() == 10)
            .findFirst()
            .orElse("");
        // Off the main thread, like the plugin's method lane: the delete waits for the job to stop.
        final JSONObject deleted = this.callers
            .submit(() -> this.engine.call("pluginMethod", CapgoCore.input("name", "delete", "args", CapgoCore.input("id", id))))
            .get(15, TimeUnit.SECONDS);
        assertTrue(deleted.toString(), deleted.has("resolve"));
        assertEquals(WorkInfo.State.CANCELLED, this.job(job).getState());
        assertNotNull(call.get(10, TimeUnit.SECONDS).optJSONObject("reject"));
        assertTrue(this.ranges.isEmpty());
    }
}
