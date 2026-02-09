package ee.forgr.capacitor_updater;

import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.os.Build;

import com.getcapacitor.JSObject;

import java.util.Map;

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
            return (pInfo != null) ? pInfo.packageName : null;
        } catch (PackageManager.NameNotFoundException e) {
            // Exception is handled internally, and null is returned to indicate the package name could not be retrieved
            return null;
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
