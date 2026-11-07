package app.capgo.updater;

import android.content.Intent;
import android.os.Bundle;

import com.getcapacitor.Bridge;
import com.getcapacitor.BridgeActivity;

public class MainActivity extends BridgeActivity {
    private static final String E2E_JS_FLAG = "window.__capgoMaestroIsE2E=true;";

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        publishE2EIntentExtra();
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        publishE2EIntentExtra();
    }

    @Override
    public void onStart() {
        super.onStart();
        publishE2EIntentExtra();
    }

    private void publishE2EIntentExtra() {
        Intent intent = getIntent();
        if (intent == null || !intent.getBooleanExtra("isE2E", false)) {
            return;
        }

        Bridge bridge = getBridge();
        if (bridge == null) {
            return;
        }

        bridge.eval(E2E_JS_FLAG, null);
    }
}
