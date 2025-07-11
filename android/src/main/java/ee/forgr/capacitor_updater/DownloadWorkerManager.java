package ee.forgr.capacitor_updater;

import android.content.Context;
import androidx.work.BackoffPolicy;
import androidx.work.Configuration;
import androidx.work.Constraints;
import androidx.work.Data;
import androidx.work.NetworkType;
import androidx.work.OneTimeWorkRequest;
import androidx.work.WorkManager;
import androidx.work.WorkRequest;
import java.util.HashSet;
import java.util.Set;
import java.util.concurrent.TimeUnit;

public class DownloadWorkerManager {

    private static Logger logger;

    public static void setLogger(Logger loggerInstance) {
        logger = loggerInstance;
    }

    private static volatile boolean isInitialized = false;
    private static final Set<String> activeVersions = new HashSet<>();

    private static synchronized void initializeIfNeeded(Context context) {
        if (!isInitialized) {
            try {
                Configuration config = new Configuration.Builder().setMinimumLoggingLevel(android.util.Log.INFO).build();
                WorkManager.initialize(context, config);
                isInitialized = true;
            } catch (IllegalStateException e) {
                // WorkManager was already initialized, ignore
            }
        }
    }

    public static synchronized boolean isVersionDownloading(String version) {
        return activeVersions.contains(version);
    }

    public static void enqueueDownload(
        Context context,
        String url,
        String id,
        String documentsDir,
        String dest,
        String version,
        String sessionKey,
        String checksum,
        String publicKey,
        boolean isManifest,
        boolean isEmulator
    ) {
        initializeIfNeeded(context.getApplicationContext());

        // If version is already downloading, don't start another one
        if (isVersionDownloading(version)) {
            logger.info("Version " + version + " is already downloading");
            return;
        }
        activeVersions.add(version);

        // Create input data
        Data inputData = new Data.Builder()
            .putString(DownloadService.URL, url)
            .putString(DownloadService.ID, id)
            .putString(DownloadService.DOCDIR, documentsDir)
            .putString(DownloadService.FILEDEST, dest)
            .putString(DownloadService.VERSION, version)
            .putString(DownloadService.SESSIONKEY, sessionKey)
            .putString(DownloadService.CHECKSUM, checksum)
            .putBoolean(DownloadService.IS_MANIFEST, isManifest)
            .putString(DownloadService.PUBLIC_KEY, publicKey)
            .build();

        // Create network constraints - be more lenient on emulators
        Constraints.Builder constraintsBuilder = new Constraints.Builder();
        if (isEmulator) {
            logger.info("Emulator detected - using lenient network constraints");
            // On emulators, use NOT_REQUIRED to avoid background network issues
            constraintsBuilder.setRequiredNetworkType(NetworkType.NOT_REQUIRED);
        } else {
            constraintsBuilder.setRequiredNetworkType(NetworkType.CONNECTED);
        }
        Constraints constraints = constraintsBuilder.build();

        // Create work request with tags for tracking
        OneTimeWorkRequest.Builder workRequestBuilder = new OneTimeWorkRequest.Builder(DownloadService.class)
            .setConstraints(constraints)
            .setInputData(inputData)
            .addTag(id)
            .addTag(version) // Add version tag for tracking
            .addTag("capacitor_updater_download");

        // More aggressive retry policy for emulators
        if (isEmulator) {
            workRequestBuilder.setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS);
        } else {
            workRequestBuilder.setBackoffCriteria(BackoffPolicy.LINEAR, WorkRequest.MIN_BACKOFF_MILLIS, TimeUnit.MILLISECONDS);
        }

        OneTimeWorkRequest workRequest = workRequestBuilder.build();

        // Enqueue work
        WorkManager.getInstance(context).enqueue(workRequest);
    }

    public static void cancelVersionDownload(Context context, String version) {
        initializeIfNeeded(context.getApplicationContext());
        WorkManager.getInstance(context).cancelAllWorkByTag(version);
        activeVersions.remove(version);
    }

    public static void cancelAllDownloads(Context context) {
        initializeIfNeeded(context.getApplicationContext());
        WorkManager.getInstance(context).cancelAllWorkByTag("capacitor_updater_download");
        activeVersions.clear();
    }
}
