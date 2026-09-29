package ee.forgr.capacitor_updater;

import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertSame;
import static org.junit.Assert.assertThrows;
import static org.junit.Assert.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

import java.io.IOException;
import okhttp3.Interceptor;
import okhttp3.Protocol;
import okhttp3.Request;
import okhttp3.Response;
import okhttp3.ResponseBody;
import org.junit.After;
import org.junit.Test;

public class RedirectPolicyTest {

    @After
    public void resetPolicy() {
        DownloadService.setAllowHttpsToHttpRedirect(false);
    }

    private static Response response(String requestUrl, int code, String location) {
        Response.Builder builder = new Response.Builder()
            .request(new Request.Builder().url(requestUrl).build())
            .protocol(Protocol.HTTP_1_1)
            .code(code)
            .message("status")
            .body(ResponseBody.create(new byte[0], null));
        if (location != null) {
            builder.header("Location", location);
        }
        return builder.build();
    }

    private static Response runNetworkInterceptor(Response upstream) throws IOException {
        Interceptor.Chain chain = mock(Interceptor.Chain.class);
        when(chain.request()).thenReturn(upstream.request());
        when(chain.proceed(any(Request.class))).thenReturn(upstream);
        Interceptor interceptor = DownloadService.sharedClient.networkInterceptors().get(0);
        return interceptor.intercept(chain);
    }

    @Test
    public void detectsOnlyHttpsToHttpRedirects() {
        assertTrue(DownloadService.isHttpsToHttpRedirect(response("https://api.capgo.app/a", 302, "http://evil.example/b")));
        assertTrue(DownloadService.isHttpsToHttpRedirect(response("https://api.capgo.app/a", 307, "HTTP://api.capgo.app/a")));
        assertFalse(DownloadService.isHttpsToHttpRedirect(response("https://api.capgo.app/a", 302, "/relative")));
        assertFalse(DownloadService.isHttpsToHttpRedirect(response("https://api.capgo.app/a", 301, "https://cdn.capgo.app/b")));
        assertFalse(DownloadService.isHttpsToHttpRedirect(response("http://api.capgo.app/a", 302, "http://other.example/b")));
        assertFalse(DownloadService.isHttpsToHttpRedirect(response("http://api.capgo.app/a", 302, "https://api.capgo.app/a")));
        assertFalse(DownloadService.isHttpsToHttpRedirect(response("https://api.capgo.app/a", 200, "http://evil.example/b")));
        assertFalse(DownloadService.isHttpsToHttpRedirect(response("https://api.capgo.app/a", 302, null)));
    }

    @Test
    public void blocksHttpsToHttpRedirectByDefault() {
        Response downgrade = response("https://api.capgo.app/a", 302, "http://evil.example/bundle.zip");
        IOException error = assertThrows(IOException.class, () -> runNetworkInterceptor(downgrade));
        assertTrue(error.getMessage().contains("allowHttpsToHttpRedirect"));
    }

    @Test
    public void allowsHttpsToHttpRedirectWhenEnabled() throws IOException {
        DownloadService.setAllowHttpsToHttpRedirect(true);
        Response downgrade = response("https://api.capgo.app/a", 302, "http://example.com/bundle.zip");
        assertSame(downgrade, runNetworkInterceptor(downgrade));
    }

    @Test
    public void passesSafeRedirectsThrough() throws IOException {
        Response upgrade = response("http://api.capgo.app/a", 302, "https://api.capgo.app/a");
        assertSame(upgrade, runNetworkInterceptor(upgrade));
        Response sameScheme = response("https://api.capgo.app/a", 302, "https://cdn.capgo.app/b");
        assertSame(sameScheme, runNetworkInterceptor(sameScheme));
    }
}
