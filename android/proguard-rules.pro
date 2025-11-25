# Add project specific ProGuard rules here.
# You can control the set of applied configuration files using the
# proguardFiles setting in build.gradle.
#
# For more details, see
#   http://developer.android.com/guide/developing/tools/proguard.html

# If your project uses WebView with JS, uncomment the following
# and specify the fully qualified class name to the JavaScript interface
# class:
#-keepclassmembers class fqcn.of.javascript.interface.for.webview {
#   public *;
#}

# Uncomment this to preserve the line number information for
# debugging stack traces.
#-keepattributes SourceFile,LineNumberTable

# If you keep the line number information, uncomment this to
# hide the original source file name.
#-renamesourcefileattribute SourceFile

# Preserve annotation and signature metadata used by runtime checks
-keepattributes *Annotation*, Signature

# Preserve the entire Capgo plugin package
-keep class ee.forgr.capacitor_updater.** { *; }

# Preserve Capacitor classes and members accessed via reflection for autoSplashscreen
# These rules are safe even if SplashScreen plugin is not present - they only reference core Capacitor classes
-keep class com.getcapacitor.Bridge {
    com.getcapacitor.MessageHandler msgHandler;
}

-keep class com.getcapacitor.MessageHandler { *; }

-keep class com.getcapacitor.PluginCall {
    <init>(com.getcapacitor.MessageHandler, java.lang.String, java.lang.String, java.lang.String, com.getcapacitor.JSObject);
}

# Keep SplashScreen plugin methods that are called via reflection
# This applies to any plugin, not just SplashScreen
-keep class * implements com.getcapacitor.PluginHandle {
    public void invoke(java.lang.String, com.getcapacitor.PluginCall);
}
