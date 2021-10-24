package ee.forgr.capacitor_updater;

import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;

@CapacitorPlugin(name = "CapacitorUpdater")
public class CapacitorUpdaterPlugin extends Plugin {

    private CapacitorUpdater implementation = new CapacitorUpdater();

    @PluginMethod
    public void echo(PluginCall call) {
        String url = call.getString("url");

        JSObject ret = new JSObject();
        ret.put("done", implementation.updateApp(url));
        call.resolve(ret);
    }
}
