package ee.forgr.capacitor_updater;

import android.content.SharedPreferences;
import java.text.ParsePosition;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Date;
import java.util.Locale;
import java.util.TimeZone;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

public class DelayUpdateUtils {

    private final Logger logger;

    public static final String DELAY_CONDITION_PREFERENCES = "DELAY_CONDITION_PREFERENCES_CAPGO";
    public static final String DELAY_CONDITION_MODE_PREFERENCES = "DELAY_CONDITION_MODE_PREFERENCES_CAPGO";
    public static final String DELAY_CONDITION_MODE_AND = "and";
    public static final String DELAY_CONDITION_MODE_OR = "or";
    public static final String BACKGROUND_TIMESTAMP_KEY = "BACKGROUND_TIMESTAMP_KEY_CAPGO";

    private final SharedPreferences prefs;
    private final SharedPreferences.Editor editor;
    private final Version currentVersionNative;

    public DelayUpdateUtils(SharedPreferences prefs, SharedPreferences.Editor editor, Version currentVersionNative, Logger logger) {
        this.prefs = prefs;
        this.editor = editor;
        this.currentVersionNative = currentVersionNative;
        this.logger = logger;
    }

    public enum CancelDelaySource {
        KILLED,
        BACKGROUND,
        FOREGROUND
    }

    public void checkCancelDelay(CancelDelaySource source) {
        String delayUpdatePreferences = prefs.getString(DELAY_CONDITION_PREFERENCES, "[]");
        ArrayList<DelayCondition> delayConditionList = parseDelayConditions(delayUpdatePreferences);
        if (delayConditionList.isEmpty()) {
            return;
        }

        final boolean useOrMode = isOrConditionMode();
        ArrayList<DelayCondition> delayConditionListToKeep = new ArrayList<>(delayConditionList.size());
        int index = 0;
        boolean anyConditionMet = false;

        for (DelayCondition condition : delayConditionList) {
            ConditionCheckResult result = evaluateCondition(condition, source, index);
            if (result.met) {
                anyConditionMet = true;
                if (!useOrMode) {
                    logger.info(result.logMessage);
                }
            } else if (!useOrMode) {
                if (result.keep) {
                    delayConditionListToKeep.add(condition);
                }
                if (result.logMessage != null) {
                    if (result.error) {
                        logger.error(result.logMessage);
                    } else {
                        logger.info(result.logMessage);
                    }
                }
            } else if (result.keep) {
                delayConditionListToKeep.add(condition);
            }
            index++;
        }

        if (useOrMode) {
            if (anyConditionMet || delayConditionListToKeep.isEmpty()) {
                logger.info("Delay condition met in OR mode (source: " + source + "), canceling delay");
                this.cancelDelay("checkCancelDelay");
            } else if (delayConditionListToKeep.size() != delayConditionList.size()) {
                this.setMultiDelay(convertDelayConditionsToJson(delayConditionListToKeep));
            }
            return;
        }

        if (delayConditionListToKeep.isEmpty()) {
            this.cancelDelay("checkCancelDelay");
        } else {
            this.setMultiDelay(convertDelayConditionsToJson(delayConditionListToKeep));
        }
    }

    private static final class ConditionCheckResult {

        final boolean met;
        final boolean keep;
        final boolean error;
        final String logMessage;

        ConditionCheckResult(boolean met, boolean keep, boolean error, String logMessage) {
            this.met = met;
            this.keep = keep;
            this.error = error;
            this.logMessage = logMessage;
        }
    }

    private ConditionCheckResult evaluateCondition(DelayCondition condition, CancelDelaySource source, int index) {
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
                        return new ConditionCheckResult(
                            false,
                            false,
                            true,
                            "Background condition (value: " +
                                value +
                                ") had an invalid value at index " +
                                index +
                                ". We will likely remove it."
                        );
                    }

                    if (delta > longValue) {
                        return new ConditionCheckResult(
                            true,
                            false,
                            false,
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
                    return new ConditionCheckResult(
                        false,
                        true,
                        false,
                        "Background delay (value: " + value + ") condition kept at index " + index + " (source: " + source + ")"
                    );
                }
                return new ConditionCheckResult(
                    false,
                    true,
                    false,
                    "Background delay (value: " + value + ") condition kept at index " + index + " (source: " + source + ")"
                );
            case DelayUntilNext.kill:
                if (source == CancelDelaySource.KILLED) {
                    return new ConditionCheckResult(
                        true,
                        false,
                        false,
                        "Kill delay (value: " + value + ") condition removed at index " + index + " after app kill"
                    );
                }
                return new ConditionCheckResult(
                    false,
                    true,
                    false,
                    "Kill delay (value: " + value + ") condition kept at index " + index + " (source: " + source + ")"
                );
            case DelayUntilNext.date:
                if (!"".equals(value)) {
                    Date date = parseDateCondition(value);
                    if (date != null) {
                        if (new Date().compareTo(date) > 0) {
                            return new ConditionCheckResult(
                                true,
                                false,
                                false,
                                "Date delay (value: " + value + ") condition removed due to expired date at index " + index
                            );
                        }
                        return new ConditionCheckResult(
                            false,
                            true,
                            false,
                            "Date delay (value: " + value + ") condition kept at index " + index
                        );
                    }
                    return new ConditionCheckResult(
                        false,
                        false,
                        true,
                        "Date delay (value: " + value + ") condition removed due to parsing issue at index " + index
                    );
                }
                return new ConditionCheckResult(
                    false,
                    false,
                    false,
                    "Date delay (value: " + value + ") condition removed due to empty value at index " + index
                );
            case DelayUntilNext.nativeVersion:
                if (!"".equals(value)) {
                    try {
                        final Version versionLimit = new Version(value);
                        if (this.currentVersionNative.isAtLeast(versionLimit)) {
                            return new ConditionCheckResult(
                                true,
                                false,
                                false,
                                "Native version delay (value: " + value + ") condition removed due to above limit at index " + index
                            );
                        }
                        return new ConditionCheckResult(
                            false,
                            true,
                            false,
                            "Native version delay (value: " + value + ") condition kept at index " + index
                        );
                    } catch (final Exception e) {
                        return new ConditionCheckResult(
                            false,
                            false,
                            true,
                            "Native version delay (value: " +
                                value +
                                ") condition removed due to parsing issue at index " +
                                index +
                                " " +
                                e.getMessage()
                        );
                    }
                }
                return new ConditionCheckResult(
                    false,
                    false,
                    false,
                    "Native version delay (value: " + value + ") condition removed due to empty value at index " + index
                );
            default:
                return new ConditionCheckResult(false, false, true, "Unknown delay condition kind at index " + index);
        }
    }

    public boolean isOrConditionMode() {
        return DELAY_CONDITION_MODE_OR.equals(getConditionMode());
    }

    public String getConditionMode() {
        String mode = prefs.getString(DELAY_CONDITION_MODE_PREFERENCES, DELAY_CONDITION_MODE_AND);
        if (DELAY_CONDITION_MODE_OR.equals(mode)) {
            return DELAY_CONDITION_MODE_OR;
        }
        return DELAY_CONDITION_MODE_AND;
    }

    public Boolean setConditionMode(String conditionMode) {
        try {
            String normalized = DELAY_CONDITION_MODE_OR.equals(conditionMode) ? DELAY_CONDITION_MODE_OR : DELAY_CONDITION_MODE_AND;
            if (!DELAY_CONDITION_MODE_AND.equals(conditionMode) && !DELAY_CONDITION_MODE_OR.equals(conditionMode)) {
                logger.warn("Unknown delay condition mode '" + conditionMode + "', defaulting to '" + DELAY_CONDITION_MODE_AND + "'");
            }
            this.editor.putString(DELAY_CONDITION_MODE_PREFERENCES, normalized);
            if (!this.editor.commit()) {
                logger.error("Failed to save delay condition mode: commit returned false");
                return false;
            }
            logger.info("Delay condition mode saved: " + normalized);
            return true;
        } catch (final Exception e) {
            logger.error("Failed to save delay condition mode: " + e.getMessage());
            return false;
        }
    }

    public ArrayList<DelayCondition> parseDelayConditions(String json) {
        ArrayList<DelayCondition> conditions = new ArrayList<>();
        if (json == null || json.isEmpty()) {
            return conditions;
        }
        try {
            JSONArray array = new JSONArray(json);
            for (int i = 0; i < array.length(); i++) {
                JSONObject item = array.optJSONObject(i);
                if (item == null) {
                    continue;
                }
                String kindValue = item.optString("kind", "");
                String value = item.optString("value", "");
                if (kindValue.isEmpty()) {
                    logger.warn("Delay condition missing kind at index " + i);
                    continue;
                }
                try {
                    DelayUntilNext kind = DelayUntilNext.valueOf(kindValue);
                    conditions.add(new DelayCondition(kind, value));
                } catch (IllegalArgumentException e) {
                    logger.warn("Unknown delay condition kind '" + kindValue + "' at index " + i);
                }
            }
        } catch (JSONException e) {
            logger.error("Failed to parse delay conditions: " + e.getMessage());
        }
        return conditions;
    }

    private Date parseDateCondition(String value) {
        String[] patterns = {
            "yyyy-MM-dd'T'HH:mm:ss.SSSXXX",
            "yyyy-MM-dd'T'HH:mm:ssXXX",
            "yyyy-MM-dd'T'HH:mm:ss.SSSXX",
            "yyyy-MM-dd'T'HH:mm:ssXX",
            "yyyy-MM-dd'T'HH:mm:ss.SSSX",
            "yyyy-MM-dd'T'HH:mm:ssX",
            "yyyy-MM-dd'T'HH:mm:ss.SSS",
            "yyyy-MM-dd'T'HH:mm:ss"
        };

        for (String pattern : patterns) {
            Date parsed = parseDateWithPattern(value, pattern);
            if (parsed != null) {
                return parsed;
            }
        }

        return null;
    }

    private Date parseDateWithPattern(String value, String pattern) {
        try {
            SimpleDateFormat sdf = new SimpleDateFormat(pattern, Locale.US);
            sdf.setLenient(false);

            // If no timezone is provided, keep historical behavior and interpret as local time.
            if (!pattern.contains("X")) {
                sdf.setTimeZone(TimeZone.getDefault());
            }

            ParsePosition position = new ParsePosition(0);
            Date parsed = sdf.parse(value, position);
            if (parsed != null && position.getIndex() == value.length()) {
                return parsed;
            }
        } catch (Exception ignored) {}

        return null;
    }

    private String convertDelayConditionsToJson(ArrayList<DelayCondition> conditions) {
        JSONArray array = new JSONArray();
        for (DelayCondition condition : conditions) {
            try {
                JSONObject obj = new JSONObject();
                obj.put("kind", condition.getKind().name());
                obj.put("value", condition.getValue());
                array.put(obj);
            } catch (JSONException e) {
                logger.error("Failed to serialize delay condition: " + e.getMessage());
            }
        }
        return array.toString();
    }

    public Boolean setMultiDelay(String delayConditions) {
        try {
            this.editor.putString(DELAY_CONDITION_PREFERENCES, delayConditions);
            if (!this.editor.commit()) {
                logger.error("Failed to delay update: commit returned false");
                return false;
            }
            logger.info("Delay update saved");
            return true;
        } catch (final Exception e) {
            logger.error("Failed to delay update, [Error calling '_setMultiDelay()'] " + e.getMessage());
            return false;
        }
    }

    public void setBackgroundTimestamp(long backgroundTimestamp) {
        try {
            this.editor.putLong(BACKGROUND_TIMESTAMP_KEY, backgroundTimestamp);
            this.editor.commit();
            logger.info("Background timestamp set");
        } catch (final Exception e) {
            logger.error("Failed to delay update, [Error calling '_setBackgroundTimestamp()'] " + e.getMessage());
        }
    }

    public void unsetBackgroundTimestamp() {
        try {
            this.editor.remove(BACKGROUND_TIMESTAMP_KEY);
            this.editor.commit();
            logger.info("Background timestamp unset");
        } catch (final Exception e) {
            logger.error("Failed to delay update, [Error calling '_unsetBackgroundTimestamp()'] " + e.getMessage());
        }
    }

    private long getBackgroundTimestamp() {
        try {
            return this.prefs.getLong(BACKGROUND_TIMESTAMP_KEY, 0);
        } catch (final Exception e) {
            logger.error("Failed to delay update, [Error calling '_getBackgroundTimestamp()'] " + e.getMessage());
            return 0;
        }
    }

    public boolean cancelDelay(String source) {
        try {
            this.editor.remove(DELAY_CONDITION_PREFERENCES);
            this.editor.remove(DELAY_CONDITION_MODE_PREFERENCES);
            this.editor.commit();
            logger.info("All delays canceled from " + source);
            return true;
        } catch (final Exception e) {
            logger.error("Failed to cancel update delay " + e.getMessage());
            return false;
        }
    }
}
