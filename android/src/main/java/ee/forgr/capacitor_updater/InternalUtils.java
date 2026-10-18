package ee.forgr.capacitor_updater;

import android.content.Context;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.os.Build;
import com.getcapacitor.JSObject;
import com.getcapacitor.util.JSONUtils;
import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.util.Map;
import org.json.JSONException;
import org.json.JSONObject;

public class InternalUtils {

    static final String CAPACITOR_CONFIG_ASSET = "capacitor.config.json";

    /**
     * Converts a Map to JSObject for proper bridge serialization.
     */
    public static JSObject mapToJSObject(Map<String, Object> map) {
        JSObject jsObject = new JSObject();
        for (Map.Entry<String, Object> entry : map.entrySet()) {
            jsObject.put(entry.getKey(), entry.getValue());
        }
        return jsObject;
    }

    public static String getPackageName(PackageManager pm, String packageName) {
        try {
            PackageInfo pInfo = getPackageInfoInternal(pm, packageName);
            return pInfo != null ? pInfo.packageName : null;
        } catch (PackageManager.NameNotFoundException e) {
            // Exception is handled internally, and null is returned to indicate the package name could not be retrieved
            return null;
        }
    }

    static String readAssetAsString(final Context context, final String assetPath) throws IOException {
        final StringBuilder buffer = new StringBuilder();
        try (
            final BufferedReader reader = new BufferedReader(
                new InputStreamReader(context.getAssets().open(assetPath), StandardCharsets.UTF_8)
            )
        ) {
            String line;
            while ((line = reader.readLine()) != null) {
                buffer.append(line).append('\n');
            }
        }
        return buffer.toString();
    }

    /** Replaces CapConfig.getString for root keys: Capacitor 9 removed it. */
    public static String getRootConfigString(Context context, String key, String defaultValue) {
        try {
            return JSONUtils.getString(new JSONObject(readAssetAsString(context, CAPACITOR_CONFIG_ASSET)), key, defaultValue);
        } catch (IOException | JSONException e) {
            return defaultValue;
        }
    }

    private static PackageInfo getPackageInfoInternal(PackageManager pm, String packageName) throws PackageManager.NameNotFoundException {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            return pm.getPackageInfo(packageName, PackageManager.PackageInfoFlags.of(0));
        } else {
            return getPackageInfoLegacy(pm, packageName, (int) (long) 0);
        }
    }

    @SuppressWarnings("deprecation")
    private static PackageInfo getPackageInfoLegacy(PackageManager pm, String packageName, int flags)
        throws PackageManager.NameNotFoundException {
        return pm.getPackageInfo(packageName, flags);
    }
}
