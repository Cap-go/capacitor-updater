package ee.forgr.capacitor_updater;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;
import static org.robolectric.Shadows.shadowOf;

import android.app.AlertDialog;
import android.app.Dialog;
import android.os.Looper;
import android.view.View;
import android.view.ViewGroup;
import android.widget.ListView;
import com.getcapacitor.BridgeActivity;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import org.json.JSONObject;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.Robolectric;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.annotation.Config;
import org.robolectric.shadows.ShadowDialog;

/** The shake menu stays busy from the channel pick until the switch ends: no second, concurrent switch. */
@RunWith(RobolectricTestRunner.class)
@Config(manifest = Config.NONE)
public class ShakeMenuTest {

    @Test
    public void pickingAChannelKeepsTheMenuBusyUntilTheSwitchEnds() throws Exception {
        final BridgeActivity activity = Robolectric.buildActivity(BridgeActivity.class).get();
        final CapacitorUpdaterPlugin plugin = mock(CapacitorUpdaterPlugin.class);
        final CountDownLatch switching = new CountDownLatch(1);
        final CountDownLatch finish = new CountDownLatch(1);
        when(plugin.switchChannelFromShakeMenu(anyString())).thenAnswer((invocation) -> {
            switching.countDown();
            finish.await(5, TimeUnit.SECONDS);
            return new JSONObject().put("status", "success").put("message", "Switched");
        });
        final ShakeMenu menu = new ShakeMenu(
            plugin,
            activity,
            new Logger("ShakeMenuTest", new Logger.Options(Logger.LogLevel.silent)),
            "shake"
        );
        setShowing(menu, true);
        final Method present = ShakeMenu.class.getDeclaredMethod("presentChannelPicker", List.class);
        present.setAccessible(true);
        present.invoke(menu, List.of("beta"));
        final AlertDialog picker = (AlertDialog) ShadowDialog.getLatestDialog();
        final ListView list = findListView(picker.getWindow().getDecorView());
        list.performItemClick(list, 0, 0);
        shadowOf(Looper.getMainLooper()).idle();
        assertFalse(picker.isShowing());
        assertTrue(switching.await(5, TimeUnit.SECONDS));
        assertTrue("busy while switching", isShowing(menu));
        final Dialog progress = ShadowDialog.getLatestDialog();
        assertTrue(progress != picker && progress.isShowing());

        finish.countDown();
        final long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5);
        Dialog result = progress;
        while (result == progress || !result.isShowing()) {
            assertTrue("result dialog", System.nanoTime() < deadline);
            Thread.sleep(10);
            shadowOf(Looper.getMainLooper()).idle();
            result = ShadowDialog.getLatestDialog();
        }
        assertTrue("busy until the result is dismissed", isShowing(menu));
        result.dismiss();
        shadowOf(Looper.getMainLooper()).idle();
        assertFalse(isShowing(menu));
        assertEquals(null, plugin.shakeMenuProgressListener);
        menu.stop();
    }

    /** Background work that ends after the activity finished must not show or dismiss dialogs (BadTokenException). */
    @Test
    public void backgroundResultsAfterTheActivityFinishedShowNoDialog() throws Exception {
        final BridgeActivity activity = Robolectric.buildActivity(BridgeActivity.class).get();
        final CapacitorUpdaterPlugin plugin = mock(CapacitorUpdaterPlugin.class);
        final CountDownLatch switched = new CountDownLatch(1);
        when(plugin.setPreviewFromShakeMenu(anyString())).thenAnswer((invocation) -> {
            switched.countDown();
            return false;
        });
        final ShakeMenu menu = new ShakeMenu(
            plugin,
            activity,
            new Logger("ShakeMenuTest", new Logger.Options(Logger.LogLevel.silent)),
            "shake"
        );
        setShowing(menu, true);
        activity.finish();

        final Method select = ShakeMenu.class.getDeclaredMethod("selectPreview", String.class);
        select.setAccessible(true);
        select.invoke(menu, "preview-1");
        assertTrue(switched.await(5, TimeUnit.SECONDS));
        final long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5);
        while (isShowing(menu)) {
            assertTrue("menu ends", System.nanoTime() < deadline);
            Thread.sleep(10);
            shadowOf(Looper.getMainLooper()).idle();
        }
        shadowOf(Looper.getMainLooper()).idle();
        assertEquals(null, ShadowDialog.getLatestDialog());

        // Direct UI calls skip too, and a dialog that is not showing is not dismissed.
        final Method showError = ShakeMenu.class.getDeclaredMethod("showError", String.class);
        showError.setAccessible(true);
        showError.invoke(menu, "late error");
        assertEquals(null, ShadowDialog.getLatestDialog());
        final Method dismiss = ShakeMenu.class.getDeclaredMethod("dismissQuietly", Dialog.class);
        dismiss.setAccessible(true);
        final Dialog neverShown = mock(Dialog.class);
        dismiss.invoke(menu, neverShown);
        org.mockito.Mockito.verify(neverShown, org.mockito.Mockito.never()).dismiss();
        final Dialog detached = mock(Dialog.class);
        when(detached.isShowing()).thenReturn(true);
        org.mockito.Mockito.doThrow(new IllegalArgumentException("View not attached to window manager")).when(detached).dismiss();
        dismiss.invoke(menu, detached);
        menu.stop();
    }

    private static ListView findListView(final View view) {
        if (view instanceof ListView) {
            return (ListView) view;
        }
        if (view instanceof ViewGroup) {
            final ViewGroup group = (ViewGroup) view;
            for (int index = 0; index < group.getChildCount(); index++) {
                final ListView found = findListView(group.getChildAt(index));
                if (found != null) {
                    return found;
                }
            }
        }
        return null;
    }

    private static boolean isShowing(final ShakeMenu menu) throws Exception {
        final Field field = ShakeMenu.class.getDeclaredField("isShowing");
        field.setAccessible(true);
        return field.getBoolean(menu);
    }

    private static void setShowing(final ShakeMenu menu, final boolean showing) throws Exception {
        final Field field = ShakeMenu.class.getDeclaredField("isShowing");
        field.setAccessible(true);
        field.setBoolean(menu, showing);
    }
}
