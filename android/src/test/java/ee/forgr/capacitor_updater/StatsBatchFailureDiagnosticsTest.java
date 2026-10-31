package ee.forgr.capacitor_updater;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import java.lang.reflect.Method;
import okhttp3.HttpUrl;
import org.junit.Test;

public class StatsBatchFailureDiagnosticsTest {

    @Test
    public void transientHttpFailureMessageIncludesStatusAndElapsedMs() {
        final String message = StatsBatchFailureDiagnostics.formatFailureMessage(
            "Error sending stats batch",
            "https://plugin.capgo.app/stats",
            "504",
            123L
        );
        assertTrue(message.startsWith("Error sending stats batch"));
        assertEquals("Error sending stats batch destination=https://plugin.capgo.app/stats status=504 elapsedMs=123", message);
    }

    @Test
    public void transportFailureUsesUnavailableStatus() {
        final String message = StatsBatchFailureDiagnostics.formatFailureMessage(
            "Failed to send stats batch",
            "https://plugin.capgo.app/stats",
            StatsBatchFailureDiagnostics.STATUS_UNAVAILABLE,
            50L
        );
        assertEquals("Failed to send stats batch destination=https://plugin.capgo.app/stats status=unavailable elapsedMs=50", message);
    }

    @Test
    public void safeDestinationStripsUserInfoQueryAndFragment() {
        final HttpUrl url = HttpUrl.parse("https://user:secret@example.com:8443/api/stats?token=abc#frag");
        assertEquals("https://example.com:8443/api/stats", StatsBatchFailureDiagnostics.safeDestinationUrl(url));
    }

    @Test
    public void safeDestinationUsesFinalUrlAfterRedirect() {
        final HttpUrl original = HttpUrl.parse("https://old.example.com/stats");
        final HttpUrl redirected = HttpUrl.parse("https://new.example.com/v2/stats");
        assertEquals("https://old.example.com/stats", StatsBatchFailureDiagnostics.safeDestinationUrl(original));
        assertEquals("https://new.example.com/v2/stats", StatsBatchFailureDiagnostics.safeDestinationUrl(redirected));
    }

    @Test
    public void transientStatsFailureRetries504() throws Exception {
        final Method method = CapgoUpdater.class.getDeclaredMethod("isTransientStatsFailure", int.class);
        method.setAccessible(true);
        assertTrue((Boolean) method.invoke(null, 504));
        assertFalse((Boolean) method.invoke(null, 404));
    }
}
