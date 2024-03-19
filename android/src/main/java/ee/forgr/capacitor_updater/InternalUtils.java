package ee.forgr.capacitor_updater;

import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.os.Build;

public class InternalUtils {

  public static String getPackageName(PackageManager pm, String packageName) {
    try {
      PackageInfo pInfo = getPackageInfoInternal(pm, packageName, 0);
      return (pInfo != null) ? pInfo.packageName : null;
    } catch (PackageManager.NameNotFoundException e) {
      // Exception is handled internally, and null is returned to indicate the package name could not be retrieved
      return null;
    }
  }

  private static PackageInfo getPackageInfoInternal(
    PackageManager pm,
    String packageName,
    long flags
  ) throws PackageManager.NameNotFoundException {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
      return pm.getPackageInfo(
        packageName,
        PackageManager.PackageInfoFlags.of(flags)
      );
    } else {
      return getPackageInfoLegacy(pm, packageName, (int) flags);
    }
  }

  @SuppressWarnings("deprecation")
  private static PackageInfo getPackageInfoLegacy(
    PackageManager pm,
    String packageName,
    int flags
  ) throws PackageManager.NameNotFoundException {
    return pm.getPackageInfo(packageName, flags);
  }
}
