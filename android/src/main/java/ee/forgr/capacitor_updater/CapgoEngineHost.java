/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

package ee.forgr.capacitor_updater;

import java.io.ByteArrayInputStream;
import java.security.KeyStore;
import java.security.cert.CertificateFactory;
import java.security.cert.X509Certificate;
import java.util.List;
import javax.net.ssl.TrustManager;
import javax.net.ssl.TrustManagerFactory;
import javax.net.ssl.X509TrustManager;

/**
 * Platform services the Rust engine calls back into (from any thread): persistence, logs, events,
 * TLS trust and Android-only download scheduling hooks.
 */
abstract class CapgoEngineHost {

    abstract void log(int level, String message);

    /** Stored value, or {@code defaultValue} when absent. */
    abstract String kvGet(String key, String defaultValue);

    abstract boolean kvContains(String key);

    /** {@code value == null} removes the key. Must be durable (commit). */
    abstract void kvSet(String key, String value);

    /** JSON array of every persisted key. */
    abstract String kvKeysJson();

    abstract void emit(String event, String payloadJson);

    void willSwitchBundle(String path) {}

    boolean cancelVersionDownload(String version) {
        return true;
    }

    void cancelAllDownloads() {}

    /** Statistics emitted by engine logic; return true once queued (through the statsSend operation). */
    boolean sendStats(String action, String versionName, String oldVersionName) {
        return false;
    }

    /**
     * Verifies a server chain (DER, leaf first) with the platform trust store (network security config, user CAs).
     * The engine verifies the host name. Returns {@code null} when trusted, else the reason.
     */
    String verifyServerCertificate(byte[][] chain, String serverName) {
        try {
            final CertificateFactory factory = CertificateFactory.getInstance("X.509");
            final X509Certificate[] certificates = new X509Certificate[chain.length];
            for (int index = 0; index < chain.length; index++) {
                certificates[index] = (X509Certificate) factory.generateCertificate(new ByteArrayInputStream(chain[index]));
            }
            final TrustManagerFactory trustManagerFactory = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm());
            trustManagerFactory.init((KeyStore) null);
            for (final TrustManager trustManager : trustManagerFactory.getTrustManagers()) {
                if (trustManager instanceof X509TrustManager) {
                    checkServerTrusted((X509TrustManager) trustManager, certificates, serverName);
                    return null;
                }
            }
            return "No X509TrustManager available";
        } catch (Exception e) {
            return e.getMessage() == null ? e.getClass().getSimpleName() : e.getMessage();
        }
    }

    private static void checkServerTrusted(final X509TrustManager trustManager, final X509Certificate[] chain, final String host)
        throws Exception {
        try {
            // Android: honours network security config (per-domain pins, user CAs).
            final Class<?> extensions = Class.forName("android.net.http.X509TrustManagerExtensions");
            final Object instance = extensions.getConstructor(X509TrustManager.class).newInstance(trustManager);
            @SuppressWarnings("unchecked")
            final List<X509Certificate> ignored = (List<X509Certificate>) extensions
                .getMethod("checkServerTrusted", X509Certificate[].class, String.class, String.class)
                .invoke(instance, chain, "RSA", host);
        } catch (ClassNotFoundException | NoSuchMethodException e) {
            trustManager.checkServerTrusted(chain, "RSA");
        } catch (java.lang.reflect.InvocationTargetException e) {
            final Throwable cause = e.getCause();
            if (cause instanceof Exception) {
                throw (Exception) cause;
            }
            throw e;
        }
    }
}
