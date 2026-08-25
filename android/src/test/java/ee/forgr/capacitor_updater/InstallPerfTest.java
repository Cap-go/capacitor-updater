package ee.forgr.capacitor_updater;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;
import static org.mockito.Mockito.mock;

import java.io.ByteArrayInputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.file.Files;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.zip.CRC32;
import java.util.zip.ZipEntry;
import java.util.zip.ZipOutputStream;
import org.junit.Test;

public class InstallPerfTest {

    private static final int ZIP_FILES = 512;
    private static final int ZIP_FILE_BYTES = 64 * 1024;
    private static final int MANIFEST_FILES = 10_000;
    private static final int MANIFEST_FILE_BYTES = 2048;
    private static final int RUNS = 3;
    private static final int OLD_ZIP_BUFFER = 8192;
    private static final int OLD_HASH_BUFFER = 1024;

    @Test
    public void compareZipAndManifestInstallBeforeAfter() throws Exception {
        CryptoCipher.setLogger(mock(Logger.class));
        DownloadService.setLogger(mock(Logger.class));
        final File root = Files.createTempDirectory("capgo-install-perf").toFile();
        root.deleteOnExit();

        final File zip = new File(root, "bundle.zip");
        writeStoredZip(zip, ZIP_FILES, ZIP_FILE_BYTES);
        System.out.println(
            "CAPGO_INSTALL_PERF platform=android fixture=zip files=" + ZIP_FILES + " bytes_each=" + ZIP_FILE_BYTES + " zip_bytes=" + zip.length()
        );

        long[] unzipBefore = new long[RUNS];
        long[] unzipAfter = new long[RUNS];
        for (int i = 0; i < RUNS; i++) {
            unzipBefore[i] = timeUnzip(root, zip, "unzip-before-" + i, OLD_ZIP_BUFFER);
            unzipAfter[i] = timeUnzip(root, zip, "unzip-after-" + i, CryptoCipher.ioBufferBytes());
        }

        final byte[] payload = new byte[ZIP_FILES * ZIP_FILE_BYTES];
        Arrays.fill(payload, (byte) 0x5A);
        long[] writeBefore = new long[RUNS];
        long[] writeAfter = new long[RUNS];
        for (int i = 0; i < RUNS; i++) {
            writeBefore[i] = timeZipWrite(new File(root, "write-before-" + i + ".bin"), payload, OLD_ZIP_BUFFER);
            writeAfter[i] = timeZipWriteHttpBody(new File(root, "write-after-" + i + ".bin"), payload);
        }

        final File builtin = new File(root, "builtin");
        assertTrue(builtin.mkdirs());
        final List<File> sources = new ArrayList<>(MANIFEST_FILES);
        final List<String> hashes = new ArrayList<>(MANIFEST_FILES);
        final byte[] fileBytes = new byte[MANIFEST_FILE_BYTES];
        Arrays.fill(fileBytes, (byte) 0x11);
        for (int i = 0; i < MANIFEST_FILES; i++) {
            fileBytes[0] = (byte) i;
            fileBytes[1] = (byte) (i >> 8);
            fileBytes[2] = (byte) (i >> 16);
            final File source = new File(builtin, "f" + i + ".js");
            Files.write(source.toPath(), fileBytes);
            sources.add(source);
            hashes.add(CryptoCipher.calcChecksum(source));
        }

        long[] manifestBefore = new long[RUNS];
        long[] manifestAfter = new long[RUNS];
        for (int i = 0; i < RUNS; i++) {
            manifestBefore[i] = timeManifestBefore(new File(root, "manifest-before-" + i), sources, hashes);
            manifestAfter[i] = timeManifestAfter(new File(root, "manifest-after-" + i), sources, hashes);
        }

        printResult("android", "unzip_32mb_512files", unzipBefore, unzipAfter);
        printResult("android", "zip_write_32mb", writeBefore, writeAfter);
        printResult("android", "manifest_10k_builtin_copy", manifestBefore, manifestAfter);
    }

    private static long timeUnzip(final File root, final File zip, final String destName, final int bufferSize) throws Exception {
        final CapgoUpdater updater = new CapgoUpdater(mock(Logger.class));
        updater.documentsDir = root;
        final File dest = new File(root, destName);
        deleteRecursively(dest);
        final long start = System.nanoTime();
        final File out = updater.unzip("perf", zip, destName, bufferSize);
        final long elapsed = (System.nanoTime() - start) / 1_000_000L;
        assertEquals(ZIP_FILES, countFiles(out));
        return elapsed;
    }

    private static long timeZipWrite(final File dest, final byte[] payload, final int bufferSize) throws Exception {
        dest.delete();
        final long start = System.nanoTime();
        try (FileOutputStream out = new FileOutputStream(dest); ByteArrayInputStream in = new ByteArrayInputStream(payload)) {
            final byte[] buffer = new byte[bufferSize];
            int n;
            while ((n = in.read(buffer)) != -1) {
                out.write(buffer, 0, n);
            }
            out.flush();
        }
        final long elapsed = (System.nanoTime() - start) / 1_000_000L;
        assertEquals(payload.length, dest.length());
        return elapsed;
    }

    private static long timeZipWriteHttpBody(final File dest, final byte[] payload) throws Exception {
        dest.delete();
        final long start = System.nanoTime();
        DownloadService.writeHttpBody(dest, new ByteArrayInputStream(payload), 200, 0);
        final long elapsed = (System.nanoTime() - start) / 1_000_000L;
        assertEquals(payload.length, dest.length());
        return elapsed;
    }

    private static long timeManifestBefore(final File destDir, final List<File> sources, final List<String> hashes) throws Exception {
        deleteRecursively(destDir);
        assertTrue(destDir.mkdirs());
        final ExecutorService executor = Executors.newFixedThreadPool(DownloadService.manifestMaxConcurrentFiles());
        final AtomicInteger copied = new AtomicInteger();
        final long start = System.nanoTime();
        final List<Future<?>> futures = new ArrayList<>(sources.size());
        for (int i = 0; i < sources.size(); i++) {
            final File source = sources.get(i);
            final File dest = new File(destDir, source.getName());
            final String expected = hashes.get(i);
            futures.add(
                executor.submit(() -> {
                    try {
                        if (!expected.equalsIgnoreCase(sha256OneKiB(source))) {
                            throw new IOException("checksum mismatch " + source.getName());
                        }
                        DownloadService.copyFileChannel(source, dest);
                        copied.incrementAndGet();
                    } catch (Exception e) {
                        throw new RuntimeException(e);
                    }
                })
            );
        }
        for (Future<?> future : futures) {
            future.get();
        }
        executor.shutdown();
        final long elapsed = (System.nanoTime() - start) / 1_000_000L;
        assertEquals(MANIFEST_FILES, copied.get());
        return elapsed;
    }

    private static long timeManifestAfter(final File destDir, final List<File> sources, final List<String> hashes) throws Exception {
        deleteRecursively(destDir);
        assertTrue(destDir.mkdirs());
        final ExecutorService executor = Executors.newFixedThreadPool(DownloadService.manifestMaxConcurrentFiles());
        final AtomicInteger copied = new AtomicInteger();
        final long start = System.nanoTime();
        final List<Future<?>> futures = new ArrayList<>(sources.size());
        for (int i = 0; i < sources.size(); i++) {
            final File source = sources.get(i);
            final File dest = new File(destDir, source.getName());
            final String expected = hashes.get(i);
            futures.add(
                executor.submit(() -> {
                    if (!DownloadService.tryCopyBuiltinFile(source, dest, expected)) {
                        throw new RuntimeException("copy failed " + source.getName());
                    }
                    copied.incrementAndGet();
                })
            );
        }
        for (Future<?> future : futures) {
            future.get();
        }
        executor.shutdown();
        final long elapsed = (System.nanoTime() - start) / 1_000_000L;
        assertEquals(MANIFEST_FILES, copied.get());
        return elapsed;
    }

    private static void printResult(final String platform, final String scenario, final long[] before, final long[] after) {
        System.out.println(
            "CAPGO_INSTALL_PERF platform=" +
            platform +
            " scenario=" +
            scenario +
            " before_ms=" +
            median(before) +
            " after_ms=" +
            median(after) +
            " before_runs=" +
            Arrays.toString(before) +
            " after_runs=" +
            Arrays.toString(after)
        );
    }

    private static long median(final long[] values) {
        final long[] copy = Arrays.copyOf(values, values.length);
        Arrays.sort(copy);
        return copy[copy.length / 2];
    }

    private static void writeStoredZip(final File zip, final int fileCount, final int fileBytes) throws IOException {
        final byte[] payload = new byte[fileBytes];
        try (ZipOutputStream zos = new ZipOutputStream(new FileOutputStream(zip))) {
        zos.setMethod(ZipOutputStream.STORED);
            for (int i = 0; i < fileCount; i++) {
                Arrays.fill(payload, (byte) (i & 0xff));
                payload[0] = (byte) i;
                payload[1] = (byte) (i >> 8);
                final ZipEntry entry = new ZipEntry("www/f" + i + ".js");
                entry.setMethod(ZipEntry.STORED);
                entry.setSize(payload.length);
                entry.setCompressedSize(payload.length);
                final CRC32 crc = new CRC32();
                crc.update(payload);
                entry.setCrc(crc.getValue());
                zos.putNextEntry(entry);
                zos.write(payload);
                zos.closeEntry();
            }
        }
    }

    private static String sha256OneKiB(final File file) throws Exception {
        final MessageDigest digest = MessageDigest.getInstance("SHA-256");
        final byte[] buffer = new byte[OLD_HASH_BUFFER];
        try (FileInputStream in = new FileInputStream(file)) {
            int n;
            while ((n = in.read(buffer)) != -1) {
                digest.update(buffer, 0, n);
            }
        }
        final byte[] bytes = digest.digest();
        final StringBuilder hex = new StringBuilder(bytes.length * 2);
        for (byte b : bytes) {
            hex.append(String.format("%02x", b));
        }
        return hex.toString();
    }

    private static int countFiles(final File dir) {
        final File[] entries = dir.listFiles();
        if (entries == null) {
            return 0;
        }
        int count = 0;
        for (File entry : entries) {
            if (entry.isDirectory()) {
                count += countFiles(entry);
            } else {
                count++;
            }
        }
        return count;
    }

    private static void deleteRecursively(final File file) {
        if (file == null || !file.exists()) {
            return;
        }
        final File[] children = file.listFiles();
        if (children != null) {
            for (File child : children) {
                deleteRecursively(child);
            }
        }
        file.delete();
    }
}
