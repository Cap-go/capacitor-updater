# Consumer ProGuard / R8 rules: merged into apps that depend on this library (Capacitor 9 enables release minify by default).

# Capacitor reflects plugin classes and @PluginMethod entries; keep this plugin and its methods.
-keep @com.getcapacitor.annotation.CapacitorPlugin class ee.forgr.capacitor_updater.CapacitorUpdaterPlugin { *; }
-keepclassmembers class ee.forgr.capacitor_updater.CapacitorUpdaterPlugin {
    @com.getcapacitor.PluginMethod <methods>;
}

# Inner types on the plugin (for example autoSplashscreen helper call construction).
-keep class ee.forgr.capacitor_updater.CapacitorUpdaterPlugin$* { *; }

# Splash automation calls other plugins through PluginHandle; Capacitor may route that by name, so keep invoke.
-keepclassmembers class * implements com.getcapacitor.PluginHandle {
    public void invoke(java.lang.String, com.getcapacitor.PluginCall);
}

# FireAndForgetPluginCall supplies a null MessageHandler; keep the constructor signature PluginCall uses at runtime.
-keep class com.getcapacitor.PluginCall {
    <init>(com.getcapacitor.MessageHandler, java.lang.String, java.lang.String, java.lang.String, com.getcapacitor.JSObject);
}

# Constructor parameter type for the kept PluginCall signature above.
-keep class com.getcapacitor.MessageHandler { *; }

# Optional Background Runner integration: Class.forName for the worker when that plugin is installed.
-keep class io.ionic.backgroundrunner.plugin.RunnerWorker {
    <init>(android.content.Context, androidx.work.WorkerParameters);
}

# Document start script support reflects WebViewFeature and WebViewCompat by name on older API levels.
-keepclassmembers class androidx.webkit.WebViewFeature {
    public static final java.lang.String DOCUMENT_START_SCRIPT;
    public static boolean isFeatureSupported(java.lang.String);
}
-keep class androidx.webkit.WebViewCompat {
    public static void addDocumentStartJavaScript(android.webkit.WebView, java.lang.String, java.util.Set);
}

# WorkManager constructs these worker classes by class object or class name at runtime.
-keepclassmembers class ee.forgr.capacitor_updater.DownloadService {
    <init>(android.content.Context, androidx.work.WorkerParameters);
}
-keepclassmembers class ee.forgr.capacitor_updater.HeadlessUpdateWorker {
    <init>(android.content.Context, androidx.work.WorkerParameters);
}

# Used by Capacitor and androidx APIs that read annotations and generic types at runtime.
-keepattributes *Annotation*, Signature
