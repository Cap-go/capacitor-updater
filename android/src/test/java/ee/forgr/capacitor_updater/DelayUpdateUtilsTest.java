package ee.forgr.capacitor_updater;

import static org.junit.Assert.*;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.*;

import android.content.SharedPreferences;
import io.github.g00fy2.versioncompare.Version;
import java.util.ArrayList;
import org.json.JSONArray;
import org.json.JSONObject;
import org.junit.Before;
import org.junit.Test;
import org.mockito.ArgumentCaptor;
import org.mockito.Mock;
import org.mockito.MockitoAnnotations;

public class DelayUpdateUtilsTest {

    @Mock
    private SharedPreferences prefs;

    @Mock
    private SharedPreferences.Editor editor;

    @Mock
    private Logger logger;

    private DelayUpdateUtils utils;

    @Before
    public void setUp() {
        MockitoAnnotations.openMocks(this);

        when(prefs.getString(eq(DelayUpdateUtils.DELAY_CONDITION_PREFERENCES), anyString())).thenReturn("[]");
        when(prefs.getLong(eq(DelayUpdateUtils.BACKGROUND_TIMESTAMP_KEY), anyLong())).thenReturn(0L);
        when(editor.putString(anyString(), anyString())).thenReturn(editor);
        when(editor.remove(anyString())).thenReturn(editor);
        when(editor.commit()).thenReturn(true);

        utils = new DelayUpdateUtils(prefs, editor, new Version("1.0.0"), logger);
    }

    @Test
    public void parseDelayConditions_returnsPopulatedListForValidJson() throws Exception {
        JSONArray jsonArray = new JSONArray();
        jsonArray.put(new JSONObject().put("kind", "background").put("value", "5000"));
        jsonArray.put(new JSONObject().put("kind", "kill").put("value", ""));
        jsonArray.put(new JSONObject().put("kind", "nativeVersion").put("value", "2.0.0"));
        jsonArray.put(new JSONObject().put("kind", "date").put("value", "2023-01-01T00:00:00.000"));

        ArrayList<DelayCondition> result = utils.parseDelayConditions(jsonArray.toString());

        assertEquals(4, result.size());
        assertEquals(DelayUntilNext.background, result.get(0).getKind());
        assertEquals("5000", result.get(0).getValue());
        assertEquals(DelayUntilNext.kill, result.get(1).getKind());
        assertEquals(DelayUntilNext.nativeVersion, result.get(2).getKind());
        assertEquals(DelayUntilNext.date, result.get(3).getKind());
    }

    @Test
    public void parseDelayConditions_skipsInvalidEntries() throws Exception {
        JSONArray jsonArray = new JSONArray();
        jsonArray.put(new JSONObject().put("kind", "unknown").put("value", "123"));
        jsonArray.put(new JSONObject().put("value", "missingKind"));
        jsonArray.put(new JSONObject().put("kind", "kill").put("value", ""));

        ArrayList<DelayCondition> result = utils.parseDelayConditions(jsonArray.toString());

        assertEquals(1, result.size());
        assertEquals(DelayUntilNext.kill, result.get(0).getKind());
    }

    @Test
    public void parseDelayConditions_handlesInvalidJsonSafely() {
        ArrayList<DelayCondition> result = utils.parseDelayConditions("not-json");

        assertTrue(result.isEmpty());
        verify(logger).error(contains("Failed to parse delay conditions"));
    }

    @Test
    public void checkCancelDelay_foregroundRemovesExpiredBackgroundCondition() throws Exception {
        JSONArray stored = new JSONArray();
        stored.put(new JSONObject().put("kind", "background").put("value", "1"));
        stored.put(new JSONObject().put("kind", "kill").put("value", ""));
        when(prefs.getString(eq(DelayUpdateUtils.DELAY_CONDITION_PREFERENCES), anyString())).thenReturn(stored.toString());

        utils.checkCancelDelay(DelayUpdateUtils.CancelDelaySource.FOREGROUND);

        ArgumentCaptor<String> captor = ArgumentCaptor.forClass(String.class);
        verify(editor).putString(eq(DelayUpdateUtils.DELAY_CONDITION_PREFERENCES), captor.capture());
        verify(editor).commit();

        JSONArray updated = new JSONArray(captor.getValue());
        assertEquals(1, updated.length());
        JSONObject remaining = updated.getJSONObject(0);
        assertEquals("kill", remaining.getString("kind"));
    }

    @Test
    public void checkCancelDelay_killedClearsDelaysWithoutInstalling() throws Exception {
        JSONArray stored = new JSONArray();
        stored.put(new JSONObject().put("kind", "kill").put("value", ""));
        when(prefs.getString(eq(DelayUpdateUtils.DELAY_CONDITION_PREFERENCES), anyString())).thenReturn(stored.toString());

        utils.checkCancelDelay(DelayUpdateUtils.CancelDelaySource.KILLED);

        verify(editor).remove(eq(DelayUpdateUtils.DELAY_CONDITION_PREFERENCES));
        verify(editor).commit();
        verify(editor, never()).putString(eq(DelayUpdateUtils.DELAY_CONDITION_PREFERENCES), anyString());
    }

    @Test
    public void checkCancelDelay_killedKeepsOtherConditions() throws Exception {
        JSONArray stored = new JSONArray();
        stored.put(new JSONObject().put("kind", "kill").put("value", ""));
        stored.put(new JSONObject().put("kind", "background").put("value", "5000"));
        when(prefs.getString(eq(DelayUpdateUtils.DELAY_CONDITION_PREFERENCES), anyString())).thenReturn(stored.toString());

        utils.checkCancelDelay(DelayUpdateUtils.CancelDelaySource.KILLED);

        ArgumentCaptor<String> captor = ArgumentCaptor.forClass(String.class);
        verify(editor).putString(eq(DelayUpdateUtils.DELAY_CONDITION_PREFERENCES), captor.capture());
        verify(editor).commit();
        verify(editor, never()).remove(eq(DelayUpdateUtils.DELAY_CONDITION_PREFERENCES));

        JSONArray updated = new JSONArray(captor.getValue());
        assertEquals(1, updated.length());
        JSONObject remaining = updated.getJSONObject(0);
        assertEquals("background", remaining.getString("kind"));
        assertEquals("5000", remaining.getString("value"));
    }
}
