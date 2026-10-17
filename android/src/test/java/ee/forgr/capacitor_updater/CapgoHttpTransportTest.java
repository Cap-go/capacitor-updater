package ee.forgr.capacitor_updater;

import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;

import android.content.Context;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import org.robolectric.annotation.Config;

/** Below Android 14 there is no HttpEngine: the transport sends nothing and the core keeps its own client. */
@RunWith(RobolectricTestRunner.class)
@Config(manifest = Config.NONE)
public class CapgoHttpTransportTest {

    private static String request(final Context context) {
        return CapgoHttpTransport.request(context, "GET", "https://a.test/", "[]", null, 1000, null, 0);
    }

    @Test
    @Config(sdk = 33)
    public void androidThirteenHasNoTransport() {
        assertFalse(CapgoHttpTransport.supported());
        assertNull(request(RuntimeEnvironment.getApplication()));
    }

    @Test
    @Config(sdk = 28)
    public void olderDevicesHaveNoTransport() {
        assertFalse(CapgoHttpTransport.supported());
        assertNull(request(RuntimeEnvironment.getApplication()));
    }

    @Test
    public void noContextNoTransport() {
        assertNull(request(null));
    }
}
