package ee.forgr.capacitor_updater;

import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.annotation.Config;

/**
 * Runs the shared updater core contract (native-contract-tests/policy.json, security.json, crypto.json)
 * through the Android JNI binding. Success cases must match `expect` exactly; error cases must fail with
 * the expected code.
 */
@RunWith(RobolectricTestRunner.class)
@Config(manifest = Config.NONE)
public class CoreContractTest {

    @Test
    public void policyMatchesCoreContract() throws Exception {
        CoreContractAdapter.runFixture("policy");
    }

    @Test
    public void securityMatchesCoreContract() throws Exception {
        CoreContractAdapter.runFixture("security");
    }

    @Test
    public void cryptoMatchesCoreContract() throws Exception {
        CoreContractAdapter.runFixture("crypto");
    }
}
