package ee.forgr.capacitor_updater;

import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.annotation.Config;

/** Runs native-contract-tests/core.json (update modes, period delay, response kinds) through the JNI binding. */
@RunWith(RobolectricTestRunner.class)
@Config(manifest = Config.NONE)
public class NativeContractTest {

    @Test
    public void coreMatchesNativeContract() throws Exception {
        CoreContractAdapter.runFixture("core");
    }
}
