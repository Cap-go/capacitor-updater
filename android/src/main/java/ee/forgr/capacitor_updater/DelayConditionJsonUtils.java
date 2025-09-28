package ee.forgr.capacitor_updater;

import java.util.ArrayList;
import java.util.Collection;
import java.util.List;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

/**
 * Utility helpers to serialize and deserialize {@link DelayCondition} without relying on reflective Gson TypeToken.
 */
final class DelayConditionJsonUtils {

    private DelayConditionJsonUtils() {}

    static List<DelayCondition> parse(String json, Logger logger) {
        List<DelayCondition> result = new ArrayList<>();
        if (json == null || json.trim().isEmpty()) {
            return result;
        }

        try {
            JSONArray array = new JSONArray(json);
            for (int i = 0; i < array.length(); i++) {
                JSONObject conditionJson = array.optJSONObject(i);
                if (conditionJson == null) {
                    if (logger != null) {
                        logger.error("Delay condition at index " + i + " is not a JSON object");
                    }
                    continue;
                }

                String kindValue = conditionJson.optString("kind", null);
                if (kindValue == null || kindValue.isEmpty()) {
                    if (logger != null) {
                        logger.error("Delay condition missing 'kind' at index " + i);
                    }
                    continue;
                }

                DelayUntilNext kind;
                try {
                    kind = DelayUntilNext.valueOf(kindValue);
                } catch (IllegalArgumentException ex) {
                    if (logger != null) {
                        logger.error("Unknown delay condition kind '" + kindValue + "' at index " + i);
                    }
                    continue;
                }

                String value = conditionJson.optString("value", "");
                result.add(new DelayCondition(kind, value));
            }
        } catch (JSONException ex) {
            if (logger != null) {
                logger.error("Failed to parse delay conditions JSON: " + ex.getMessage());
            }
        }

        return result;
    }

    static String toJson(Collection<DelayCondition> conditions) {
        JSONArray array = new JSONArray();
        if (conditions == null) {
            return array.toString();
        }

        for (DelayCondition condition : conditions) {
            if (condition == null || condition.getKind() == null) {
                continue;
            }

            JSONObject obj = new JSONObject();
            try {
                obj.put("kind", condition.getKind().name());
                obj.put("value", condition.getValue() != null ? condition.getValue() : "");
                array.put(obj);
            } catch (JSONException ignored) {
                // Values are simple strings; this block should never be reached.
            }
        }

        return array.toString();
    }
}
