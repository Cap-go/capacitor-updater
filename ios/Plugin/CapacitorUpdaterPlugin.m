#import <Foundation/Foundation.h>
#import <Capacitor/Capacitor.h>

// Define the plugin using the CAP_PLUGIN Macro, and
// each method the plugin supports using the CAP_PLUGIN_METHOD macro.
CAP_PLUGIN(CapacitorUpdaterPlugin, "CapacitorUpdater",
           CAP_PLUGIN_METHOD(download, CAPPluginReturnPromise);
           CAP_PLUGIN_METHOD(set, CAPPluginReturnNone);
           CAP_PLUGIN_METHOD(list, CAPPluginReturnNone);
           CAP_PLUGIN_METHOD(delete, CAPPluginReturnNone);
           CAP_PLUGIN_METHOD(load, CAPPluginReturnNone);
)
