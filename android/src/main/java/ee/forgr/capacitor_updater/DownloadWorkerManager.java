package ee.forgr.capacitor_updater;

import android.content.Context;
import android.os.Build;
import androidx.work.BackoffPolicy;
import androidx.work.Configuration;
import androidx.work.Constraints;
import androidx.work.Data;
import androidx.work.ExistingWorkPolicy;
import androidx.work.NetworkType;
import androidx.work.OneTimeWorkRequest;
import androidx.work.OutOfQuotaPolicy;
import androidx.work.WorkInfo;
import androidx.work.WorkManager;
import androidx.work.WorkRequest;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;

public class DownloadWorkerManager {

    private static Logger logger;

    public static void setLogger(Logger loggerInstance) {
        logger = loggerInstance;
    }

    private static volatile boolean isInitialized = false;
    private static final ExecutorService cancelExecutor = Executors.newSingleThreadExecutor();

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
                .anyMatch((workInfo) -> !workInfo.getState().isFinished());
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
        String installSource,
        String statsUrl,
        boolean disableNonUpdateEvents,
        boolean limitUpdateEventsToBilling,
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
            .putString(DownloadService.INSTALL_SOURCE, installSource)
            .putString(DownloadService.STATS_URL, statsUrl)
            .putBoolean(DownloadService.DISABLE_NON_UPDATE_EVENTS, disableNonUpdateEvents)
            .putBoolean(DownloadService.LIMIT_UPDATE_EVENTS_TO_BILLING, limitUpdateEventsToBilling)
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
        // Android 12+ expedited jobs skip the WorkManager delay without a
        // foreground service. Older APIs require getForegroundInfo().
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            workRequestBuilder.setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST);
        }

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
        cancelExecutor.execute(() -> cancelVersionDownloadInternal(context, version, false));
    }

    public static boolean cancelVersionDownloadAndAwait(Context context, String version) {
        initializeIfNeeded(context.getApplicationContext());
        Future<?> future = cancelExecutor.submit(() -> cancelVersionDownloadInternal(context, version, true));
        try {
            future.get(10, TimeUnit.SECONDS);
            return true;
        } catch (TimeoutException e) {
            future.cancel(true);
            logger.error("Timed out awaiting version download cancel");
            return false;
        } catch (Exception e) {
            logger.error("Error awaiting version download cancel: " + e.getMessage());
            return false;
        }
    }

    private static Set<String> collectManifestIdsForVersion(WorkManager workManager, String version) {
        Set<String> downloadIds = new HashSet<>();
        try {
            List<WorkInfo> workInfos = workManager.getWorkInfosByTag(version).get();
            for (WorkInfo workInfo : workInfos) {
                for (String tag : workInfo.getTags()) {
                    if (!"capacitor_updater_download".equals(tag) && !version.equals(tag)) {
                        downloadIds.add(tag);
                    }
                }
            }
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new IllegalStateException("Interrupted while collecting manifest ids before version cancel", e);
        } catch (Exception e) {
            logger.error("Error collecting manifest ids before version cancel: " + e.getMessage());
        }
        return downloadIds;
    }

    private static void clearManifestIds(Set<String> downloadIds) {
        for (String downloadId : downloadIds) {
            DataManager.getInstance().clearManifest(downloadId);
        }
    }

    private static void cancelVersionDownloadInternal(Context context, String version, boolean awaitFinished) {
        if (Thread.currentThread().isInterrupted()) {
            return;
        }
        WorkManager workManager = WorkManager.getInstance(context);
        Set<String> downloadIds = collectManifestIdsForVersion(workManager, version);
        workManager.cancelAllWorkByTag(version);
        clearManifestIds(downloadIds);
        if (awaitFinished) {
            awaitVersionWorkFinished(workManager, version);
        }
    }

    private static void awaitVersionWorkFinished(WorkManager workManager, String version) {
        for (int i = 0; i < 100; i++) {
            if (Thread.currentThread().isInterrupted()) {
                throw new IllegalStateException("Interrupted while waiting for version download cancel");
            }
            try {
                boolean anyActive = workManager
                    .getWorkInfosByTag(version)
                    .get()
                    .stream()
                    .anyMatch((workInfo) -> !workInfo.getState().isFinished());
                if (!anyActive) {
                    return;
                }
                Thread.sleep(100);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                throw new IllegalStateException("Interrupted while waiting for download cancel", e);
            } catch (Exception e) {
                throw new IllegalStateException("Error waiting for download cancel: " + e.getMessage(), e);
            }
        }
        throw new IllegalStateException("Timed out waiting for version download cancel: " + version);
    }

    public static void cancelBundleDownload(Context context, String id, String version) {
        String uniqueWorkName = "bundle_" + id + "_" + version;
        initializeIfNeeded(context.getApplicationContext());
        WorkManager workManager = WorkManager.getInstance(context);
        workManager.cancelUniqueWork(uniqueWorkName);
        DataManager.getInstance().clearManifest(id);
    }

    public static void cancelAllDownloads(Context context) {
        initializeIfNeeded(context.getApplicationContext());
        WorkManager workManager = WorkManager.getInstance(context);
        workManager.cancelAllWorkByTag("capacitor_updater_download");
        DataManager.getInstance().clearAllManifests();
    }
}
