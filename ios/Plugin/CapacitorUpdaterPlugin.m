#import <Foundation/Foundation.h>
#import <Capacitor/Capacitor.h>

// Define the plugin using the CAP_PLUGIN Macro, and
// each method the plugin supports using the CAP_PLUGIN_METHOD macro.
CAP_PLUGIN(CapacitorUpdaterPlugin, "CapacitorUpdater",
           CAP_PLUGIN_METHOD(download, CAPPluginReturnPromise);
           CAP_PLUGIN_METHOD(setUpdateUrl, CAPPluginReturnPromise);
           CAP_PLUGIN_METHOD(setStatsUrl, CAPPluginReturnPromise);
           CAP_PLUGIN_METHOD(setChannelUrl, CAPPluginReturnPromise);
           CAP_PLUGIN_METHOD(set, CAPPluginReturnPromise);
           CAP_PLUGIN_METHOD(list, CAPPluginReturnPromise);
           CAP_PLUGIN_METHOD(delete, CAPPluginReturnPromise);
           CAP_PLUGIN_METHOD(reset, CAPPluginReturnPromise);
           CAP_PLUGIN_METHOD(current, CAPPluginReturnPromise);
           CAP_PLUGIN_METHOD(reload, CAPPluginReturnPromise);
           CAP_PLUGIN_METHOD(notifyAppReady, CAPPluginReturnPromise);
           CAP_PLUGIN_METHOD(setDelay, CAPPluginReturnPromise);
           CAP_PLUGIN_METHOD(setMultiDelay, CAPPluginReturnPromise);
           CAP_PLUGIN_METHOD(cancelDelay, CAPPluginReturnPromise);
           CAP_PLUGIN_METHOD(getLatest, CAPPluginReturnPromise);
           CAP_PLUGIN_METHOD(setChannel, CAPPluginReturnPromise);
           CAP_PLUGIN_METHOD(getChannel, CAPPluginReturnPromise);
           CAP_PLUGIN_METHOD(setCustomId, CAPPluginReturnPromise);
           CAP_PLUGIN_METHOD(getDeviceId, CAPPluginReturnPromise);
           CAP_PLUGIN_METHOD(getPluginVersion, CAPPluginReturnPromise);
           CAP_PLUGIN_METHOD(next, CAPPluginReturnPromise);
           CAP_PLUGIN_METHOD(isAutoUpdateEnabled, CAPPluginReturnPromise);
           CAP_PLUGIN_METHOD(getBuiltinVersion, CAPPluginReturnPromise);
)
