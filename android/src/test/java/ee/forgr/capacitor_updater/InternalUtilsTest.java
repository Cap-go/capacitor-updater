package ee.forgr.capacitor_updater;

import static org.junit.Assert.assertEquals;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

import android.content.Context;
import android.content.res.AssetManager;
import java.io.ByteArrayInputStream;
import java.io.FileNotFoundException;
import java.nio.charset.StandardCharsets;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;

@RunWith(RobolectricTestRunner.class)
public class InternalUtilsTest {

    private static Context contextWithConfig(final String json) throws Exception {
        final Context context = mock(Context.class);
        final AssetManager assets = mock(AssetManager.class);
        when(context.getAssets()).thenReturn(assets);
        if (json == null) {
            when(assets.open("capacitor.config.json")).thenThrow(new FileNotFoundException("capacitor.config.json"));
        } else {
            when(assets.open("capacitor.config.json")).thenReturn(new ByteArrayInputStream(json.getBytes(StandardCharsets.UTF_8)));
        }
        return context;
    }

    @Test
    public void readsTheRootAppId() throws Exception {
        final Context context = contextWithConfig("{\n  \"appId\": \"com.example.app\",\n  \"appName\": \"Example\"\n}");
        assertEquals("com.example.app", InternalUtils.getRootConfigString(context, "appId", "fallback"));
    }

    @Test
    public void ignoresThePluginAppId() throws Exception {
        final Context context = contextWithConfig("{\"plugins\":{\"CapacitorUpdater\":{\"appId\":\"com.example.plugin\"}}}");
        assertEquals("fallback", InternalUtils.getRootConfigString(context, "appId", "fallback"));
    }

    @Test
    public void fallsBackWhenTheConfigIsMissingOrInvalid() throws Exception {
        assertEquals("fallback", InternalUtils.getRootConfigString(contextWithConfig(null), "appId", "fallback"));
        assertEquals("fallback", InternalUtils.getRootConfigString(contextWithConfig("not json"), "appId", "fallback"));
    }
}
