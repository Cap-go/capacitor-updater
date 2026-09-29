/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

package ee.forgr.capacitor_updater;

import java.io.File;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.StandardCopyOption;

/** JNI entry point of the shared Rust updater core (libcapgo_updater_core). */
final class CapgoCoreNative {

    /** JVM unit tests only: path of the core built for the host (set by android/build.gradle). */
    static final String HOST_LIBRARY_PROPERTY = "capgo.core.hostLibrary";

    static {
        final String hostLibrary = System.getProperty(HOST_LIBRARY_PROPERTY);
        if (hostLibrary == null || hostLibrary.isEmpty()) {
            System.loadLibrary("capgo_updater_core");
        } else {
            loadHostLibrary(new File(hostLibrary));
        }
    }

    private CapgoCoreNative() {}

    /** Runs a core operation; returns the JSON envelope {"ok":...}. Never null. */
    static native String call(String operation, String inputJson);

    /** Creates an updater engine; 0 when the configuration is invalid (reported through host.log). */
    static native long engineCreate(String configJson, CapgoEngineHost host);

    /** Runs an engine operation; returns the JSON envelope {"ok":...}. Blocking. */
    static native String engineCall(long engine, String operation, String inputJson);

    static native void engineDestroy(long engine);

    /**
     * Robolectric runs each SDK sandbox in its own class loader, and the JVM refuses to bind one native library to
     * two class loaders, so every loader gets its own copy.
     */
    private static void loadHostLibrary(final File library) {
        try {
            final File copy = File.createTempFile("capgo_updater_core", "-" + library.getName());
            copy.deleteOnExit();
            Files.copy(library.toPath(), copy.toPath(), StandardCopyOption.REPLACE_EXISTING);
            System.load(copy.getAbsolutePath());
        } catch (IOException e) {
            throw new UnsatisfiedLinkError("Cannot load Capgo core host library " + library + ": " + e.getMessage());
        }
    }
}
