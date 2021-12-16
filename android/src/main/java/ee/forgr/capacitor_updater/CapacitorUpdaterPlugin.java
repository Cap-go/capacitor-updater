package ee.forgr.capacitor_updater;

import android.util.Log;

import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;

import java.util.ArrayList;

@CapacitorPlugin(name = "CapacitorUpdater")
public class CapacitorUpdaterPlugin extends Plugin {
    private CapacitorUpdater implementation;

    @Override
    public void load() {
        super.load();
        implementation = new CapacitorUpdater(this.getContext());
    }
//    private CapacitorUpdater implementation = new CapacitorUpdater(this.getContext());

    @PluginMethod
    public void download(PluginCall call) {
        String url = call.getString("url");

        String res = implementation.download(url);
        if ((res) != null) {
            JSObject ret = new JSObject();
            ret.put("version", res);
            call.resolve(ret);
        } else {
            call.reject("download failed");
        }
    }

    @PluginMethod
    public void set(PluginCall call) {
        String version = call.getString("version");
        Boolean res = implementation.set(version);

        if (!res) {
            call.reject("Update failed, version don't exist");
        } else {
            String pathHot = implementation.getLastPathHot();
            Log.i("CapacitorUpdater", "getLastPathHot : " + pathHot);
            this.bridge.setServerBasePath(pathHot);
            call.resolve();
        }
    }

    @PluginMethod
    public void delete(PluginCall call) {
        String version = call.getString("version");
        Boolean res = implementation.delete(version);

        if (res) {
            call.resolve();
        } else {
            call.reject("Delete failed, version don't exist");
        }
    }

    @PluginMethod
    public void list(PluginCall call) {
        ArrayList<String> res = implementation.list();
        JSObject ret = new JSObject();
        ret.put("versions", res);
        call.resolve(ret);
    }

    @PluginMethod
    public void reset(PluginCall call) {
        implementation.reset();
        String pathHot = implementation.getLastPathHot();
        this.bridge.setServerAssetPath(pathHot);
        call.resolve();
    }

    @PluginMethod
    public void current(PluginCall call) {
        String pathHot = implementation.getLastPathHot();
        JSObject ret = new JSObject();
        String current = pathHot.length() >= 10 ? pathHot.substring(pathHot.length() - 10) : "default";
        ret.put("current", current);
        call.resolve(ret);
    }
}
