/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

package ee.forgr.capacitor_updater;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;

/** JNI entry point of the shared Rust updater core (libcapgo_updater_core). */
final class CapgoCoreNative {

    /** JVM unit tests only: path of the core built for the host (set by android/build.gradle). */
    static final String HOST_LIBRARY_PROPERTY = "capgo.core.hostLibrary";

    /**
     * Why the library did not load, {@code null} when it did. A throw from this static block would make every later
     * use of the class fail with NoClassDefFoundError and, as an Error, escape Capacitor's plugin load and crash the
     * app at launch (missing ABI, 16 KB page device, broken split install): the plugin checks {@link #isAvailable()}
     * and runs without the updater instead.
     */
    private static final Throwable LOAD_ERROR;
    /** Tests only: a simulated load failure. */
    private static volatile Throwable simulatedLoadError;

    static {
        Throwable error = null;
        try {
            final String hostLibrary = System.getProperty(HOST_LIBRARY_PROPERTY);
            if (hostLibrary == null || hostLibrary.isEmpty()) {
                System.loadLibrary("capgo_updater_core");
            } else {
                loadHostLibrary(new File(hostLibrary));
            }
        } catch (final Throwable e) {
            error = e;
        }
        LOAD_ERROR = error;
    }

    private CapgoCoreNative() {}

    /** {@code false} when the native core could not be loaded: no native method may be called. */
    static boolean isAvailable() {
        return loadError() == null;
    }

    /** Why the native core could not be loaded, {@code null} when it is available. */
    static Throwable loadError() {
        final Throwable simulated = simulatedLoadError;
        return simulated != null ? simulated : LOAD_ERROR;
    }

    /** Tests: simulate a library that failed to load; {@code null} ends the simulation. */
    static void setLoadErrorForTesting(final Throwable error) {
        simulatedLoadError = error;
    }

    /** Runs a core operation; returns the JSON envelope {"ok":...}. Never null. */
    static native String call(String operation, String inputJson);

    /** Creates an updater engine; 0 when the configuration is invalid (reported through host.log). */
    static native long engineCreate(String configJson, CapgoEngineHost host);

    /** Runs an engine operation; returns the JSON envelope {"ok":...}. Blocking. */
    static native String engineCall(long engine, String operation, String inputJson);

    static native void engineDestroy(long engine);

    /**
     * Robolectric runs each SDK sandbox in its own class loader, and the JVM refuses to bind one native library to
     * two class loaders, so every loader gets its own copy. Plain streams: this class also loads on API 24-25, which
     * have no java.nio.file.
     */
    private static void loadHostLibrary(final File library) {
        try {
            final File copy = File.createTempFile("capgo_updater_core", "-" + library.getName());
            copy.deleteOnExit();
            try (InputStream in = new FileInputStream(library); OutputStream out = new FileOutputStream(copy)) {
                final byte[] buffer = new byte[64 * 1024];
                int read;
                while ((read = in.read(buffer)) != -1) {
                    out.write(buffer, 0, read);
                }
            }
            System.load(copy.getAbsolutePath());
        } catch (IOException e) {
            throw new UnsatisfiedLinkError("Cannot load Capgo core host library " + library + ": " + e.getMessage());
        }
    }
}
