package ee.forgr.capacitor_updater;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import okhttp3.HttpUrl;

final class StatsBatchFailureDiagnostics {

    static final String STATUS_UNAVAILABLE = "unavailable";

    private StatsBatchFailureDiagnostics() {}

    @NonNull
    static String safeDestinationUrl(@NonNull HttpUrl url) {
        return url.newBuilder().username("").password("").query(null).fragment(null).build().toString();
    }

    @NonNull
    static String safeDestinationUrl(@Nullable String urlString) {
        if (urlString == null || urlString.isEmpty()) {
            return "";
        }
        final HttpUrl parsed = HttpUrl.parse(urlString);
        if (parsed == null) {
            return urlString;
        }
        return safeDestinationUrl(parsed);
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
