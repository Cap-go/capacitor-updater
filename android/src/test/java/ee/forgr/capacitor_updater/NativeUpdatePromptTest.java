package ee.forgr.capacitor_updater;

import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import android.content.SharedPreferences;
import com.getcapacitor.JSObject;
import com.getcapacitor.PluginConfig;
import org.junit.Test;
import org.mockito.Mockito;

public class NativeUpdatePromptTest {

    @Test
    public void detectsNativeStoreBlocksFromBackendErrors() {
        JSObject major = new JSObject();
        major.put("error", "disable_auto_update_to_major");
        assertTrue(NativeUpdatePrompt.isNativeStoreUpdateBlock(major));

        JSObject underNative = new JSObject();
        underNative.put("error", "disable_auto_update_under_native");
        assertTrue(NativeUpdatePrompt.isNativeStoreUpdateBlock(underNative));

        JSObject minor = new JSObject();
        minor.put("error", "disable_auto_update_to_minor");
        assertTrue(NativeUpdatePrompt.isNativeStoreUpdateBlock(minor));

        JSObject storeMessage = new JSObject();
        storeMessage.put("message", "store_update_required");
        assertTrue(NativeUpdatePrompt.isNativeStoreUpdateBlock(storeMessage));

        JSObject breaking = new JSObject();
        breaking.put("breaking", true);
        assertTrue(NativeUpdatePrompt.isNativeStoreUpdateBlock(breaking));

        JSObject unrelated = new JSObject();
        unrelated.put("error", "response_error");
        assertFalse(NativeUpdatePrompt.isNativeStoreUpdateBlock(unrelated));
    }

    @Test
    public void respectsSessionAndCooldownForNativeVersion() {
        NativeUpdatePrompt.resetSessionStateForTesting();
        PluginConfig config = Mockito.mock(PluginConfig.class);
        Mockito.when(config.getBoolean("nativeUpdatePrompt", false)).thenReturn(true);
        Mockito.when(config.getBoolean("nativeUpdatePromptOnStoreCheck", false)).thenReturn(false);
        Mockito.when(config.getInt("nativeUpdatePromptCooldownHours", 24)).thenReturn(24);

        SharedPreferences prefs = Mockito.mock(SharedPreferences.class);
        Mockito.when(prefs.getString(NativeUpdatePrompt.PREF_LAST_NATIVE_VERSION, "")).thenReturn("42");
        Mockito.when(prefs.getLong(NativeUpdatePrompt.PREF_LAST_SHOWN_MS, 0L)).thenReturn(System.currentTimeMillis());

        NativeUpdatePrompt prompt = new NativeUpdatePrompt(
            config,
            prefs,
            Mockito.mock(ee.forgr.capacitor_updater.Logger.class),
            Mockito.mock(NativeUpdatePrompt.NativeUpdatePromptHost.class)
        );

        assertFalse(prompt.shouldShowForNativeVersion("42"));
        assertTrue(prompt.shouldShowForNativeVersion("99"));
    }

    @Test
    public void scheduleShowIgnoresDuplicatePresentationWhileInFlight() {
        NativeUpdatePrompt.resetSessionStateForTesting();
        PluginConfig config = Mockito.mock(PluginConfig.class);
        Mockito.when(config.getBoolean("nativeUpdatePrompt", false)).thenReturn(true);
        Mockito.when(config.getBoolean("nativeUpdatePromptOnStoreCheck", false)).thenReturn(false);
        Mockito.when(config.getInt("nativeUpdatePromptCooldownHours", 24)).thenReturn(24);

        NativeUpdatePrompt.NativeUpdatePromptHost host = Mockito.mock(NativeUpdatePrompt.NativeUpdatePromptHost.class);
        Mockito.when(host.getNativeBuildVersion()).thenReturn("42");

        NativeUpdatePrompt prompt = new NativeUpdatePrompt(
            config,
            Mockito.mock(SharedPreferences.class),
            Mockito.mock(ee.forgr.capacitor_updater.Logger.class),
            host
        );
        prompt.resetPresentationStateForTesting();

        JSObject response = new JSObject();
        response.put("breaking", true);
        prompt.maybeShowForUpdateBlock(response);
        assertTrue(prompt.isPromptPresentationActiveForTesting());
        prompt.maybeShowForUpdateBlock(response);
        assertTrue(prompt.isPromptPresentationActiveForTesting());

        prompt.resetPresentationStateForTesting();
        assertFalse(prompt.isPromptPresentationActiveForTesting());
    }

    @Test
    public void showsInAllRegionsWhenCountryFilterUnset() {
        PluginConfig config = Mockito.mock(PluginConfig.class);
        Mockito.when(config.getBoolean("nativeUpdatePrompt", false)).thenReturn(true);
        Mockito.when(config.getBoolean("nativeUpdatePromptOnStoreCheck", false)).thenReturn(false);
        Mockito.when(config.getInt("nativeUpdatePromptCooldownHours", 24)).thenReturn(24);
        Mockito.when(config.getString("nativeUpdatePromptCountry", null)).thenReturn(null);

        NativeUpdatePrompt prompt = new NativeUpdatePrompt(
            config,
            Mockito.mock(SharedPreferences.class),
            Mockito.mock(ee.forgr.capacitor_updater.Logger.class),
            Mockito.mock(NativeUpdatePrompt.NativeUpdatePromptHost.class)
        );

        assertTrue(prompt.matchesCountryFilter());
    }
}
