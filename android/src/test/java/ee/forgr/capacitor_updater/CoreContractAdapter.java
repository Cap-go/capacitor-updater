package ee.forgr.capacitor_updater;

import java.io.File;
import java.io.OutputStream;
import java.io.RandomAccessFile;
import java.nio.file.Files;
import java.security.PublicKey;
import org.json.JSONObject;

/**
 * Maps a shared core contract case (native-contract-tests/{policy,security,crypto}.json)
 * onto the current Java implementation and returns an output object with the same keys
 * as the fixture `expect`. Error cases surface as thrown exceptions.
 *
 * The runner (CoreContractTest) is implementation-agnostic; a Rust-backed adapter can
 * later expose the same `run(group, input)` shape.
 */
final class CoreContractAdapter {

    /** Thrown when a specific case cannot be exercised by this implementation (not a failure). */
    static final class UnsupportedCase extends Exception {

        UnsupportedCase(String reason) {
            super(reason);
        }
    }

    /** Thrown when the adapter has no mapping at all for a group. */
    static final class UnknownGroup extends RuntimeException {

        UnknownGroup(String group) {
            super("No Android adapter for group " + group);
        }
    }

    private static final File CACHE_DIR = new File("/capgo-contract/cache");

    private CoreContractAdapter() {}

    static JSONObject run(String group, JSONObject input) throws Exception {
        switch (group) {
            // ------------------------------------------------------------ policy.json
            case "legacyDirectUpdateAutoMode":
                return out("mode", CapacitorUpdaterPlugin.autoUpdateModeForLegacyDirectUpdateMode(input.getString("directUpdateMode")));
            case "isDirectUpdateMode":
                return out("direct", CapacitorUpdaterPlugin.isDirectUpdateMode(input.getString("directUpdateMode")));
            case "shakeMenuGesture": {
                String value = str(input, "value");
                return out(
                    "gesture",
                    CapacitorUpdaterPlugin.normalizedShakeMenuGesture(value),
                    "supported",
                    CapacitorUpdaterPlugin.isSupportedShakeMenuGesture(value)
                );
            }
            case "webViewErrorStatsAction":
                return out("action", CapacitorUpdaterPlugin.statsActionForWebViewErrorType(input.getString("type")));
            case "launchDownloadReady":
                return out(
                    "notify",
                    CapgoUpdater.shouldNotifyLaunchDownloadReady(
                        input.getBoolean("awaitedByCaller"),
                        input.getBoolean("success"),
                        input.getBoolean("directInstall"),
                        input.getBoolean("previewSession")
                    ),
                    "status",
                    CapgoUpdater.launchDownloadReadyStatus(input.getBoolean("success"), input.getBoolean("setNext"))
                );
            case "foreignBundleReset":
                return out(
                    "reset",
                    CapgoUpdater.shouldResetForForeignBundle(
                        str(input, "bundlePath"),
                        input.getBoolean("isBuiltin"),
                        input.getBoolean("hasStoredBundleInfo")
                    )
                );
            case "clearPersistedDefaultChannel":
                return out(
                    "clear",
                    CapacitorUpdaterPlugin.shouldClearPersistedDefaultChannel(
                        input.getBoolean("persistDefaultChannelOnReinstall"),
                        input.getBoolean("resetWhenUpdate"),
                        input.getBoolean("nativeBuildVersionChanged"),
                        input.getBoolean("restoredReinstall")
                    )
                );
            case "manifestConcurrency":
                return out("maxConcurrentFiles", DownloadService.manifestMaxConcurrentFiles(input.getInt("processorCount")));
            case "userAgent": {
                // The Android builder hard codes the "android" platform segment.
                String platform = input.getString("platform");
                if (!"android".equals(platform)) {
                    throw new UnsupportedCase("platform " + platform + " is not built by the Android user agent helper");
                }
                return out(
                    "userAgent",
                    DownloadService.buildUserAgent(input.getString("appId"), input.getString("pluginVersion"), input.getString("versionOs"))
                );
            }
            case "retryableHttpStatus":
                return out("retryable", DownloadService.isRetryableHttpStatus(input.getInt("status")));
            case "contentRange": {
                DownloadService.ContentRangeInfo range = DownloadService.parseContentRange(str(input, "header"));
                if (range == null) {
                    return out("range", JSONObject.NULL);
                }
                return out("range", out("start", range.start, "end", range.end, "total", range.total));
            }
            case "zipResumePlan": {
                DownloadService.ZipWritePlan plan = DownloadService.planZipResumeWrite(
                    input.getInt("responseCode"),
                    input.getLong("downloadedBytes"),
                    str(input, "contentRange")
                );
                return out("responseCode", plan.statusCode, "writeOffset", plan.writeOffset);
            }
            case "appendHttpBody":
                return out("append", DownloadService.shouldAppendHttpBody(input.getInt("statusCode"), input.getLong("existingBytes")));
            case "rateLimitDeadline":
                return out(
                    "blockedUntilMs",
                    CapgoUpdater.resolveRateLimitBlockedUntilMs(str(input, "retryAfter"), str(input, "body"), input.getLong("nowMs"))
                );
            case "remoteError": {
                String body = str(input, "body");
                return out("error", CapgoUpdater.parseRemoteError(body), "message", CapgoUpdater.parseRemoteMessage(body));
            }
            case "bundleStatus": {
                BundleStatus status = BundleStatus.fromString(str(input, "value"));
                return out("status", status == null ? JSONObject.NULL : status.toString());
            }
            // ---------------------------------------------------------- security.json
            case "pathTraversalSegment":
                return out("traversal", CapgoUpdater.containsPathTraversalSegment(input.getString("path")));
            case "resolvePathInside":
                return out(
                    "path",
                    CapgoUpdater.resolvePathInsideDirectory(new File(input.getString("base")), str(input, "path")).getPath()
                );
            case "manifestTargetPath":
                return out(
                    "path",
                    DownloadService.resolveManifestTargetFile(new File(input.getString("base")), input.getString("fileName")).getPath()
                );
            case "builtinAssetPath":
                return out("assetPath", DownloadService.resolveBuiltinAssetPath(input.getString("fileName")));
            case "safeCacheHash":
                return out("safe", CapgoUpdater.isSafeCacheHash(str(input, "hash")));
            case "reusableCacheFile":
                return reusableCacheFile(str(input, "hash"), input.isNull("size") ? null : input.getLong("size"));
            case "manifestPartialName":
                return out("name", DownloadService.manifestPartialFile(CACHE_DIR, str(input, "hash"), str(input, "fileName")).getName());
            case "shortPathKey":
                return out("key", CryptoCipher.shortPathKey(str(input, "value")));
            // ------------------------------------------------------------ crypto.json
            case "sessionKeyValid":
                return out("valid", CryptoCipher.isValidSessionKey(str(input, "sessionKey")));
            case "keyId":
                return out("keyId", CryptoCipher.calcKeyId(str(input, "publicKey")));
            case "publicKeyValid": {
                boolean valid;
                try {
                    PublicKey key = CryptoCipher.stringToPublicKey(input.getString("publicKey"));
                    valid = key != null;
                } catch (Exception error) {
                    valid = false;
                }
                return out("valid", valid);
            }
            case "checksumAlgorithm":
                return out("algorithm", CryptoCipher.detectChecksumAlgorithm(str(input, "checksum")));
            case "checksumFile":
                return checksumFile(input.getString("contentHex"), input.getInt("repeat"));
            case "decryptChecksum":
                return out("checksum", CryptoCipher.decryptChecksum(input.getString("checksum"), input.getString("publicKey")));
            case "decryptFile":
                return decryptFile(input.getString("publicKey"), input.getString("sessionKey"), input.getString("ciphertextHex"));
            default:
                throw new UnknownGroup(group);
        }
    }

    private static JSONObject reusableCacheFile(String hash, Long size) throws Exception {
        File dir = Files.createTempDirectory("capgo-core-contract").toFile();
        File file = new File(dir, "cache.bin");
        try {
            if (size != null) {
                try (RandomAccessFile raf = new RandomAccessFile(file, "rw")) {
                    raf.setLength(size);
                }
            }
            return out("reusable", CapgoUpdater.isReusableCacheFile(file, hash));
        } finally {
            deleteQuietly(file);
            deleteQuietly(dir);
        }
    }

    private static JSONObject checksumFile(String contentHex, int repeat) throws Exception {
        File file = File.createTempFile("capgo-core-contract", ".bin");
        try {
            byte[] chunk = hexToBytes(contentHex);
            try (OutputStream output = Files.newOutputStream(file.toPath())) {
                for (int i = 0; i < repeat; i++) {
                    output.write(chunk);
                }
            }
            return out("checksum", CryptoCipher.calcChecksum(file));
        } finally {
            deleteQuietly(file);
        }
    }

    private static JSONObject decryptFile(String publicKey, String sessionKey, String ciphertextHex) throws Exception {
        File dir = Files.createTempDirectory("capgo-core-contract").toFile();
        File file = new File(dir, "bundle.bin");
        try {
            Files.write(file.toPath(), hexToBytes(ciphertextHex));
            CryptoCipher.decryptFile(file, publicKey, sessionKey);
            return out("plaintextHex", bytesToHex(Files.readAllBytes(file.toPath())));
        } finally {
            File[] leftovers = dir.listFiles();
            if (leftovers != null) {
                for (File leftover : leftovers) {
                    deleteQuietly(leftover);
                }
            }
            deleteQuietly(dir);
        }
    }

    private static void deleteQuietly(File file) {
        if (file.exists() && !file.delete()) {
            file.deleteOnExit();
        }
    }

    private static String str(JSONObject input, String key) {
        return input.has(key) && !input.isNull(key) ? input.optString(key) : null;
    }

    private static JSONObject out(Object... keyValues) throws Exception {
        JSONObject result = new JSONObject();
        for (int i = 0; i < keyValues.length; i += 2) {
            result.put((String) keyValues[i], keyValues[i + 1]);
        }
        return result;
    }

    static byte[] hexToBytes(String hex) {
        if (hex.length() % 2 != 0) {
            throw new IllegalArgumentException("Odd hex length");
        }
        byte[] data = new byte[hex.length() / 2];
        for (int i = 0; i < hex.length(); i += 2) {
            data[i / 2] = (byte) ((Character.digit(hex.charAt(i), 16) << 4) + Character.digit(hex.charAt(i + 1), 16));
        }
        return data;
    }

    static String bytesToHex(byte[] bytes) {
        StringBuilder hex = new StringBuilder(bytes.length * 2);
        for (byte b : bytes) {
            hex.append(Character.forDigit((b >> 4) & 0xf, 16)).append(Character.forDigit(b & 0xf, 16));
        }
        return hex.toString();
    }
}
