package ee.forgr.capacitor_updater;

import static org.junit.Assert.assertEquals;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import org.json.JSONArray;
import org.json.JSONObject;
import org.junit.Test;

public class NativeContractTest {

    private static JSONObject contract() {
        try {
            return new JSONObject(new String(Files.readAllBytes(contractFile()), StandardCharsets.UTF_8));
        } catch (Exception error) {
            throw new AssertionError("Unable to load native contract fixture", error);
        }
    }

    private static Path contractFile() throws IOException {
        Path current = Path.of(System.getProperty("user.dir")).toAbsolutePath();
        while (current != null) {
            Path candidate = current.resolve("native-contract-tests/core.json");
            if (Files.exists(candidate)) {
                return candidate;
            }
            current = current.getParent();
        }
        throw new IOException("native-contract-tests/core.json not found");
    }

    private static String nullableString(final JSONObject object, final String key) throws Exception {
        if (!object.has(key) || object.isNull(key)) {
            return null;
        }
        return object.getString(key);
    }

    @Test
    public void periodCheckDelayMatchesNativeContract() throws Exception {
        JSONArray cases = contract().getJSONArray("periodCheckDelay");
        for (int index = 0; index < cases.length(); index++) {
            JSONObject testCase = cases.getJSONObject(index);
            String id = testCase.getString("id");
            int seconds = testCase.getJSONObject("input").getInt("seconds");
            int expected = testCase.getJSONObject("expect").getInt("normalizedSeconds");

            assertEquals(id, expected, CapacitorUpdaterPlugin.normalizedPeriodCheckDelaySeconds(seconds));
        }
    }

    @Test
    public void onLaunchDirectUpdateConsumptionMatchesNativeContract() throws Exception {
        JSONArray cases = contract().getJSONArray("onLaunchDirectUpdateConsumption");
        for (int index = 0; index < cases.length(); index++) {
            JSONObject testCase = cases.getJSONObject(index);
            String id = testCase.getString("id");
            JSONObject input = testCase.getJSONObject("input");
            boolean expected = testCase.getJSONObject("expect").getBoolean("consume");

            assertEquals(
                id,
                expected,
                CapacitorUpdaterPlugin.shouldConsumeOnLaunchDirectUpdate(input.getString("mode"), input.getBoolean("plannedDirectUpdate"))
            );
        }
    }

    @Test
    public void updateResponseKindMatchesNativeContract() throws Exception {
        JSONArray cases = contract().getJSONArray("updateResponseKind");
        for (int index = 0; index < cases.length(); index++) {
            JSONObject testCase = cases.getJSONObject(index);
            String id = testCase.getString("id");
            String kind = nullableString(testCase.getJSONObject("input"), "kind");
            String expected = testCase.getJSONObject("expect").getString("kind");

            assertEquals(id, expected, CapacitorUpdaterPlugin.normalizedUpdateResponseKind(kind));
        }
    }
}
