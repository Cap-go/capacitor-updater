package ee.forgr.capacitor_updater;

import static org.junit.Assert.assertEquals;

import java.io.IOException;
import java.net.InetSocketAddress;
import java.net.Proxy;
import java.net.ProxySelector;
import java.net.SocketAddress;
import java.net.URI;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import org.json.JSONObject;
import org.junit.Test;

/** The engine's {@code proxyForUrl} hook: the system {@link ProxySelector}, as OkHttp used it. */
public class ProxyForUrlTest {

    private static final class FixedSelector extends ProxySelector {

        final List<Proxy> proxies;
        final List<URI> asked = new ArrayList<>();

        FixedSelector(final Proxy... proxies) {
            this.proxies = Arrays.asList(proxies);
        }

        @Override
        public List<Proxy> select(final URI uri) {
            asked.add(uri);
            return proxies;
        }

        @Override
        public void connectFailed(final URI uri, final SocketAddress address, final IOException error) {}
    }

    private static Proxy http(final String host, final int port) {
        return new Proxy(Proxy.Type.HTTP, InetSocketAddress.createUnresolved(host, port));
    }

    private static String reply(final ProxySelector selector, final String url) throws Exception {
        return CapgoUpdater.proxyForUrlReply(new JSONObject().put("url", url).toString(), selector);
    }

    @Test
    public void httpProxyIsReportedWithHostAndPort() throws Exception {
        final FixedSelector selector = new FixedSelector(http("proxy.corp", 3128));
        final JSONObject reply = new JSONObject(reply(selector, "https://plugin.capgo.app/updates"));
        assertEquals("http", reply.getString("type"));
        assertEquals("proxy.corp", reply.getString("host"));
        assertEquals(3128, reply.getInt("port"));
        assertEquals(URI.create("https://plugin.capgo.app/updates"), selector.asked.get(0));
    }

    @Test
    public void directAndUnsupportedProxiesConnectDirectly() throws Exception {
        final Proxy socks = new Proxy(Proxy.Type.SOCKS, InetSocketAddress.createUnresolved("socks.corp", 1080));
        assertEquals("direct", new JSONObject(reply(new FixedSelector(Proxy.NO_PROXY), "https://a.b/")).getString("type"));
        assertEquals("direct", new JSONObject(reply(new FixedSelector(socks), "https://a.b/")).getString("type"));
        assertEquals("direct", new JSONObject(reply(new FixedSelector(), "https://a.b/")).getString("type"));
        assertEquals("direct", new JSONObject(reply(null, "https://a.b/")).getString("type"));
        // DIRECT first wins, like OkHttp's route order.
        assertEquals(
            "direct",
            new JSONObject(reply(new FixedSelector(Proxy.NO_PROXY, http("proxy.corp", 3128)), "https://a.b/")).getString("type")
        );
        // An unsupported SOCKS entry is skipped for the next HTTP proxy.
        assertEquals(
            "proxy.corp",
            new JSONObject(reply(new FixedSelector(socks, http("proxy.corp", 8080)), "https://a.b/")).getString("host")
        );
    }

    @Test
    public void badInputOrFailingSelectorConnectsDirectly() throws Exception {
        final ProxySelector failing = new ProxySelector() {
            @Override
            public List<Proxy> select(final URI uri) {
                throw new IllegalArgumentException("no route");
            }

            @Override
            public void connectFailed(final URI uri, final SocketAddress address, final IOException error) {}
        };
        assertEquals("direct", new JSONObject(reply(failing, "https://a.b/")).getString("type"));
        assertEquals("direct", new JSONObject(reply(new FixedSelector(http("p", 1)), "http://[bad")).getString("type"));
        assertEquals(
            "direct",
            new JSONObject(CapgoUpdater.proxyForUrlReply("not json", new FixedSelector(http("p", 1)))).getString("type")
        );
        assertEquals("{\"type\":\"direct\"}", CapgoUpdater.proxyReply(Collections.emptyList()).toString());
    }
}
