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

    /**
     * Reads a root string value from the bundled capacitor.config.json.
     * Capacitor 9 removed CapConfig.getString, so the file is read directly.
     */
    public static String getRootConfigString(Context context, String key, String defaultValue) {
        try (
            BufferedReader reader = new BufferedReader(
                new InputStreamReader(context.getAssets().open("capacitor.config.json"), StandardCharsets.UTF_8)
            )
        ) {
            final StringBuilder json = new StringBuilder();
            String line;
            while ((line = reader.readLine()) != null) {
                json.append(line);
            }
            return JSONUtils.getString(new JSONObject(json.toString()), key, defaultValue);
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
