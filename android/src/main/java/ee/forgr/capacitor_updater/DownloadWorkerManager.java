package ee.forgr.capacitor_updater;

import android.content.Context;
import androidx.work.BackoffPolicy;
import androidx.work.Configuration;
import androidx.work.Constraints;
import androidx.work.Data;
import androidx.work.ExistingWorkPolicy;
import androidx.work.NetworkType;
import androidx.work.OneTimeWorkRequest;
import androidx.work.WorkManager;
import androidx.work.WorkRequest;
import java.util.concurrent.TimeUnit;

public class DownloadWorkerManager {

    private static Logger logger;

    public static void setLogger(Logger loggerInstance) {
        logger = loggerInstance;
    }

    private static volatile boolean isInitialized = false;

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

    public static boolean isVersionDownloading(Context context, String version) {
        initializeIfNeeded(context.getApplicationContext());
        try {
            return WorkManager.getInstance(context)
                .getWorkInfosByTag(version)
                .get()
                .stream()
                .anyMatch(workInfo -> !workInfo.getState().isFinished());
        } catch (Exception e) {
            logger.error("Error checking download status: " + e.getMessage());
            return false;
        }
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
        boolean isEmulator,
        String appId,
        String pluginVersion,
        boolean isProd,
        String statsUrl,
        String deviceId,
        String versionBuild,
        String versionCode,
        String versionOs,
        String customId,
        String defaultChannel
    ) {
        initializeIfNeeded(context.getApplicationContext());

        // Use unique work name for this bundle to prevent duplicates
        String uniqueWorkName = "bundle_" + id + "_" + version;

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
            .putString(DownloadService.APP_ID, appId)
            .putString(DownloadService.pluginVersion, pluginVersion)
            .putString(DownloadService.STATS_URL, statsUrl)
            .putString(DownloadService.DEVICE_ID, deviceId)
            .putString(DownloadService.VERSION_BUILD, versionBuild)
            .putString(DownloadService.VERSION_CODE, versionCode)
            .putString(DownloadService.VERSION_OS, versionOs)
            .putString(DownloadService.CUSTOM_ID, customId)
            .putString(DownloadService.DEFAULT_CHANNEL, defaultChannel)
            .putBoolean(DownloadService.IS_PROD, isProd)
            .putBoolean(DownloadService.IS_EMULATOR, isEmulator)
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
            .addTag(version)
            .addTag("capacitor_updater_download");

        // More aggressive retry policy for emulators
        if (isEmulator) {
            workRequestBuilder.setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS);
        } else {
            workRequestBuilder.setBackoffCriteria(BackoffPolicy.LINEAR, WorkRequest.MIN_BACKOFF_MILLIS, TimeUnit.MILLISECONDS);
        }

        OneTimeWorkRequest workRequest = workRequestBuilder.build();

        // Use beginUniqueWork to prevent duplicate downloads
        WorkManager.getInstance(context)
            .beginUniqueWork(
                uniqueWorkName,
                ExistingWorkPolicy.KEEP, // Don't start if already running
                workRequest
            )
            .enqueue();
    }

    public static void cancelVersionDownload(Context context, String version) {
        initializeIfNeeded(context.getApplicationContext());
        WorkManager.getInstance(context).cancelAllWorkByTag(version);
    }

    public static void cancelBundleDownload(Context context, String id, String version) {
        String uniqueWorkName = "bundle_" + id + "_" + version;
        initializeIfNeeded(context.getApplicationContext());
        WorkManager.getInstance(context).cancelUniqueWork(uniqueWorkName);
    }

    public static void cancelAllDownloads(Context context) {
        initializeIfNeeded(context.getApplicationContext());
        WorkManager.getInstance(context).cancelAllWorkByTag("capacitor_updater_download");
    }
}
