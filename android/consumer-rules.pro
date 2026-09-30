# Applied to apps that use this plugin (consumerProguardFiles).

# The Rust core (JNI) binds its native methods by name and calls the host
# callbacks by name and signature. R8 cannot see those references.
-keepclasseswithmembernames,includedescriptorclasses class ee.forgr.capacitor_updater.CapgoCoreNative {
    native <methods>;
}
-keep class ee.forgr.capacitor_updater.CapgoEngineHost { *; }
-keep class * extends ee.forgr.capacitor_updater.CapgoEngineHost { *; }
