package ee.forgr.capacitor_updater;

import static org.junit.Assert.assertEquals;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.CALLS_REAL_METHODS;
import static org.mockito.Mockito.doAnswer;
import static org.mockito.Mockito.mock;

import androidx.work.Data;
import com.google.common.util.concurrent.ListenableFuture;
import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.annotation.Config;

@RunWith(RobolectricTestRunner.class)
@Config(manifest = Config.NONE)
public class DownloadProgressTest {

    @Test
    public void repeatedOrLatePercentagesDoNotWriteWorkManagerProgressAgain() throws Exception {
        DownloadService worker = mock(DownloadService.class, CALLS_REAL_METHODS);
        List<Integer> writes = new ArrayList<>();
        doAnswer((call) -> {
            Data value = call.getArgument(0);
            writes.add(value.getInt(DownloadService.PERCENT, -1));
            return mock(ListenableFuture.class);
        })
            .when(worker)
            .setProgressAsync(any(Data.class));
        Method update = DownloadService.class.getDeclaredMethod("setProgress", int.class);
        update.setAccessible(true);
        for (int percent : new int[] { 10, 10, 9, 11, 11, 70 }) update.invoke(worker, percent);
        assertEquals(Arrays.asList(10, 11, 70), writes);
    }
}
