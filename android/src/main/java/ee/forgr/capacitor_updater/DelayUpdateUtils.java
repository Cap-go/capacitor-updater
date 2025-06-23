package ee.forgr.capacitor_updater;

import android.content.SharedPreferences;
import android.util.Log;
import com.google.common.reflect.TypeToken;
import com.google.gson.Gson;
import io.github.g00fy2.versioncompare.Version;
import java.lang.reflect.Type;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Date;

public class DelayUpdateUtils {

    public static final String DELAY_CONDITION_PREFERENCES = "DELAY_CONDITION_PREFERENCES_CAPGO";
    public static final String BACKGROUND_TIMESTAMP_KEY = "BACKGROUND_TIMESTAMP_KEY_CAPGO";

    private final SharedPreferences prefs;
    private final SharedPreferences.Editor editor;
    private final Version currentVersionNative;
    private final Runnable installNext;

    public DelayUpdateUtils(SharedPreferences prefs, SharedPreferences.Editor editor, Version currentVersionNative, Runnable installNext) {
        this.prefs = prefs;
        this.editor = editor;
        this.currentVersionNative = currentVersionNative;
        this.installNext = installNext;
    }

    public enum CancelDelaySource {
        KILLED,
        BACKGROUND,
        FOREGROUND
    }

    public void checkCancelDelay(CancelDelaySource source) {
        Gson gson = new Gson();
        String delayUpdatePreferences = prefs.getString(DELAY_CONDITION_PREFERENCES, "[]");
        Type type = new TypeToken<ArrayList<DelayCondition>>() {}.getType();
        ArrayList<DelayCondition> delayConditionList = gson.fromJson(delayUpdatePreferences, type);
        ArrayList<DelayCondition> delayConditionListToKeep = new ArrayList<>(delayConditionList.size());
        int index = 0;

        for (DelayCondition condition : delayConditionList) {
            DelayUntilNext kind = condition.getKind();
            String value = condition.getValue();
            switch (kind) {
                case DelayUntilNext.background:
                    if (source == CancelDelaySource.FOREGROUND) {
                        long backgroundedAt = getBackgroundTimestamp();
                        long now = System.currentTimeMillis();
                        long delta = Math.max(0, now - backgroundedAt);
                        long longValue = 0L;
                        try {
                            longValue = Long.parseLong(value);
                        } catch (NumberFormatException e) {
                            Log.e(
                                CapacitorUpdater.TAG,
                                "Background condition (value: " +
                                value +
                                ") had an invalid value at index " +
                                index +
                                ". We will likely remove it."
                            );
                        }

                        if (delta > longValue) {
                            Log.i(
                                CapacitorUpdater.TAG,
                                "Background condition (value: " +
                                value +
                                ") deleted at index " +
                                index +
                                ". Delta: " +
                                delta +
                                ", longValue: " +
                                longValue
                            );
                        }
                    } else {
                        delayConditionListToKeep.add(condition);
                        Log.i(
                            CapacitorUpdater.TAG,
                            "Background delay (value: " +
                            value +
                            ") condition kept at index " +
                            index +
                            " (source: " +
                            source.toString() +
                            ")"
                        );
                    }
                    break;
                case DelayUntilNext.kill:
                    if (source == CancelDelaySource.KILLED) {
                        this.installNext.run();
                    } else {
                        delayConditionListToKeep.add(condition);
                        Log.i(
                            CapacitorUpdater.TAG,
                            "Kill delay (value: " + value + ") condition kept at index " + index + " (source: " + source.toString() + ")"
                        );
                    }
                    break;
                case DelayUntilNext.date:
                    if (!"".equals(value)) {
                        try {
                            final SimpleDateFormat sdf = new SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS");
                            Date date = sdf.parse(value);
                            assert date != null;
                            if (new Date().compareTo(date) > 0) {
                                Log.i(
                                    CapacitorUpdater.TAG,
                                    "Date delay (value: " + value + ") condition removed due to expired date at index " + index
                                );
                            } else {
                                delayConditionListToKeep.add(condition);
                                Log.i(CapacitorUpdater.TAG, "Date delay (value: " + value + ") condition kept at index " + index);
                            }
                        } catch (final Exception e) {
                            Log.e(
                                CapacitorUpdater.TAG,
                                "Date delay (value: " + value + ") condition removed due to parsing issue at index " + index,
                                e
                            );
                        }
                    } else {
                        Log.d(
                            CapacitorUpdater.TAG,
                            "Date delay (value: " + value + ") condition removed due to empty value at index " + index
                        );
                    }
                    break;
                case DelayUntilNext.nativeVersion:
                    if (!"".equals(value)) {
                        try {
                            final Version versionLimit = new Version(value);
                            if (this.currentVersionNative.isAtLeast(versionLimit)) {
                                Log.i(
                                    CapacitorUpdater.TAG,
                                    "Native version delay (value: " + value + ") condition removed due to above limit at index " + index
                                );
                            } else {
                                delayConditionListToKeep.add(condition);
                                Log.i(CapacitorUpdater.TAG, "Native version delay (value: " + value + ") condition kept at index " + index);
                            }
                        } catch (final Exception e) {
                            Log.e(
                                CapacitorUpdater.TAG,
                                "Native version delay (value: " + value + ") condition removed due to parsing issue at index " + index,
                                e
                            );
                        }
                    } else {
                        Log.d(
                            CapacitorUpdater.TAG,
                            "Native version delay (value: " + value + ") condition removed due to empty value at index " + index
                        );
                    }
                    break;
            }
            index++;
        }

        if (!delayConditionListToKeep.isEmpty()) {
            this.setMultiDelay(gson.toJson(delayConditionListToKeep));
        }
    }

    public Boolean setMultiDelay(String delayConditions) {
        try {
            this.editor.putString(DELAY_CONDITION_PREFERENCES, delayConditions);
            this.editor.commit();
            Log.i(CapacitorUpdater.TAG, "Delay update saved");
            return true;
        } catch (final Exception e) {
            Log.e(CapacitorUpdater.TAG, "Failed to delay update, [Error calling '_setMultiDelay()']", e);
            return false;
        }
    }

    public void setBackgroundTimestamp(long backgroundTimestamp) {
        try {
            this.editor.putLong(BACKGROUND_TIMESTAMP_KEY, backgroundTimestamp);
            this.editor.commit();
            Log.i(CapacitorUpdater.TAG, "Delay update saved");
        } catch (final Exception e) {
            Log.e(CapacitorUpdater.TAG, "Failed to delay update, [Error calling '_setBackgroundTimestamp()']", e);
        }
    }

    public void unsetBackgroundTimestamp() {
        try {
            this.editor.remove(BACKGROUND_TIMESTAMP_KEY);
            this.editor.commit();
            Log.i(CapacitorUpdater.TAG, "Delay update saved");
        } catch (final Exception e) {
            Log.e(CapacitorUpdater.TAG, "Failed to delay update, [Error calling '_unsetBackgroundTimestamp()']", e);
        }
    }

    private long getBackgroundTimestamp() {
        try {
            return this.prefs.getLong(BACKGROUND_TIMESTAMP_KEY, 0);
        } catch (final Exception e) {
            Log.e(CapacitorUpdater.TAG, "Failed to delay update, [Error calling '_getBackgroundTimestamp()']", e);
            return 0;
        }
    }

    public boolean cancelDelay(String source) {
        try {
            this.editor.remove(DELAY_CONDITION_PREFERENCES);
            this.editor.commit();
            Log.i(CapacitorUpdater.TAG, "All delays canceled from " + source);
            return true;
        } catch (final Exception e) {
            Log.e(CapacitorUpdater.TAG, "Failed to cancel update delay", e);
            return false;
        }
    }
}
