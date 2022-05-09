#import <Foundation/Foundation.h>
#import <Capacitor/Capacitor.h>

// Define the plugin using the CAP_PLUGIN Macro, and
// each method the plugin supports using the CAP_PLUGIN_METHOD macro.
CAP_PLUGIN(CapacitorUpdaterPlugin, "CapacitorUpdater",
           CAP_PLUGIN_METHOD(download, CAPPluginReturnPromise);
           CAP_PLUGIN_METHOD(set, CAPPluginReturnPromise);
           CAP_PLUGIN_METHOD(list, CAPPluginReturnPromise);
           CAP_PLUGIN_METHOD(delete, CAPPluginReturnPromise);
           CAP_PLUGIN_METHOD(reset, CAPPluginReturnPromise);
           CAP_PLUGIN_METHOD(current, CAPPluginReturnPromise);
           CAP_PLUGIN_METHOD(reload, CAPPluginReturnPromise);
           CAP_PLUGIN_METHOD(next, CAPPluginReturnPromise);
           CAP_PLUGIN_METHOD(notifyAppReady, CAPPluginReturnPromise);
           CAP_PLUGIN_METHOD(delayUpdate, CAPPluginReturnPromise);
           CAP_PLUGIN_METHOD(getId, CAPPluginReturnPromise);
           CAP_PLUGIN_METHOD(getPluginVersion, CAPPluginReturnPromise);
           CAP_PLUGIN_METHOD(next, CAPPluginReturnPromise);
           CAP_PLUGIN_METHOD(isAutoUpdateEnabled, CAPPluginReturnPromise);
)
