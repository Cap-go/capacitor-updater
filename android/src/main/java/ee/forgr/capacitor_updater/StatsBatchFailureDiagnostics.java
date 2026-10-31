package ee.forgr.capacitor_updater;

import androidx.annotation.NonNull;
import okhttp3.HttpUrl;

final class StatsBatchFailureDiagnostics {

    static final String STATUS_UNAVAILABLE = "unavailable";

    private StatsBatchFailureDiagnostics() {}

    @NonNull
    static String safeDestinationUrl(@NonNull HttpUrl url) {
        final String scheme = url.scheme();
        final int port = url.port();
        if (port == HttpUrl.defaultPort(scheme)) {
            return scheme + "://" + url.host();
        }
        return scheme + "://" + url.host() + ":" + port;
    }

    @NonNull
    static String formatFailureMessage(
        @NonNull final String messagePrefix,
        @NonNull final String safeDestination,
        @NonNull final String status,
        final long elapsedMs
    ) {
        return messagePrefix + " destination=" + safeDestination + " status=" + status + " elapsedMs=" + elapsedMs;
    }
}
