/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/* Launch, lifecycle, health and WebView statistics, and download progress events (Rust
 * engine/plugin/telemetry.rs). */

#include "engine/plugin/telemetry.h"

#include <stdlib.h>
#include <string.h>

#include "engine/engine.h"
#include "engine/plugin/plugin.h"
#include "engine/plugin/ready.h"
#include "engine/stats.h"
#include "engine/store.h"
#include "net_url.h"
#include "policy.h"

#define APP_SESSION_ID "CapacitorUpdater.appSessionId"
#define APP_SESSION_FOREGROUND "CapacitorUpdater.appSessionForeground"
#define APP_SESSION_STARTED_AT "CapacitorUpdater.appSessionStartedAt"
#define LAST_REPORTED_UNCLEAN_SESSION "CapacitorUpdater.lastReportedUncleanSessionId"
#define LAST_REPORTED_APP_EXIT "CapacitorUpdater.lastReportedAppExitTimestamp"
#define LAST_RENDER_PROCESS_GONE "CapacitorUpdater.lastWebViewRenderProcessGone"

/* value.chars().take(max). malloc'd. */
static char *truncate_chars(const char *value, size_t max) {
    size_t count = 0, index = 0;
    for (; value[index]; index++) {
        if (((unsigned char)value[index] & 0xC0) != 0x80) {
            if (count == max) break;
            count++;
        }
    }
    return cg_strndup(value, index);
}

static bool is_ascii_digit(char c) { return c >= '0' && c <= '9'; }

static bool is_ascii_hex(char c) {
    return is_ascii_digit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}

/* Non-ASCII bytes fail every check below, like the Rust char checks (a multibyte char, or
 * the U+FFFD of a lossy decoding, is never a digit). */
static bool is_sensitive_segment(const char *segment, size_t len) {
    bool digits = len > 0, hex = len > 0, uuid = len == 36;
    for (size_t i = 0; i < len; i++) {
        char c = segment[i];
        if (!is_ascii_digit(c)) digits = false;
        if (!is_ascii_hex(c)) hex = false;
        if (uuid) {
            if (i == 8 || i == 13 || i == 18 || i == 23) uuid = c == '-';
            else uuid = is_ascii_hex(c);
        }
    }
    return (len >= 6 && digits) || (len >= 16 && hex) || uuid;
}

static int hex_value(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/* `%XX` escapes decoded into *out (bytes; see is_sensitive_segment for the lossy part). */
static void percent_decoded(const char *segment, size_t len, cg_buf *out) {
    out->len = 0;
    size_t index = 0;
    while (index < len) {
        int high = index + 1 < len ? hex_value(segment[index + 1]) : -1;
        int low = index + 2 < len ? hex_value(segment[index + 2]) : -1;
        if (segment[index] == '%' && high >= 0 && low >= 0) {
            cg_buf_putc(out, (char)(high * 16 + low));
            index += 3;
        } else {
            cg_buf_putc(out, segment[index]);
            index++;
        }
    }
}

static char *strip_query_and_fragment(const char *value) { return cg_strndup(value, strcspn(value, "?#")); }

/* Parts of a URL as the Rust `url` crate exposes them: host_str, port, path. Special
 * schemes come from the shared parser; other schemes (`capacitor://`) are read here
 * (authority after `//`, userinfo dropped). false when there is no host. */
static bool url_parts(const char *value, char **scheme, char **host, char **port, char **path) {
    cg_url url;
    if (cg_url_parse(value, NULL, &url) != CG_URL_OK) return false;
    if (url.host == CG_URL_HOST_NONE) {
        cg_url_clear(&url);
        return false;
    }
    *scheme = cg_url_scheme(&url);
    if (!url.opaque) {
        *host = cg_url_host_str(&url);
        *port = url.port >= 0 ? cg_fmt(":%d", url.port) : cg_strdup("");
        *path = cg_url_path(&url);
        cg_url_clear(&url);
        return true;
    }
    cg_url_clear(&url);
    const char *rest = strchr(value, ':') + 1;
    rest += 2; /* "//": a host is present */
    size_t authority = strcspn(rest, "/?#");
    const char *at = NULL;
    for (size_t i = 0; i < authority; i++)
        if (rest[i] == '@') at = rest + i;
    const char *host_start = at ? at + 1 : rest;
    size_t host_len = (size_t)(rest + authority - host_start);
    size_t name_len = host_len;
    bool brackets = false;
    for (size_t i = 0; i < host_len; i++) {
        if (host_start[i] == '[') brackets = true;
        if (host_start[i] == ']') brackets = false;
        if (host_start[i] == ':' && !brackets) {
            name_len = i;
            break;
        }
    }
    *host = cg_strndup(host_start, name_len);
    if (name_len < host_len && name_len + 1 < host_len) {
        char *digits = cg_strndup(host_start + name_len + 1, host_len - name_len - 1);
        uint64_t number = 0;
        *port = cg_parse_u64(digits, &number) ? cg_fmt(":%llu", (unsigned long long)number) : cg_strdup("");
        free(digits);
    } else {
        *port = cg_strdup("");
    }
    const char *path_start = rest + authority;
    *path = cg_strndup(path_start, strcspn(path_start, "?#"));
    return true;
}

char *cg_telemetry_sanitize_stats_url(const char *value) {
    if (!value || !*value) return cg_strdup("");
    char *scheme = NULL, *host = NULL, *port = NULL, *path = NULL;
    if (url_parts(value, &scheme, &host, &port, &path)) {
        cg_buf joined = {0};
        cg_buf decoded = {0};
        const char *segment = path;
        bool first = true;
        while (true) {
            size_t len = strcspn(segment, "/");
            if (!first) cg_buf_putc(&joined, '/');
            first = false;
            percent_decoded(segment, len, &decoded);
            if (is_sensitive_segment(decoded.data ? decoded.data : "", decoded.len)) cg_buf_puts(&joined, "redacted");
            else cg_buf_put(&joined, segment, len);
            if (!segment[len]) break;
            segment += len + 1;
        }
        cg_buf_free(&decoded);
        char *sanitized_path = cg_buf_take(&joined);
        if (strcmp(sanitized_path, "/") == 0) {
            char *needle = cg_fmt("%s%s/", host, port);
            if (!strstr(value, needle)) cg_replace(&sanitized_path, cg_strdup(""));
            free(needle);
        }
        char *out = cg_fmt("%s://%s%s%s", scheme, host, port, sanitized_path);
        free(sanitized_path);
        free(scheme);
        free(host);
        free(port);
        free(path);
        return out;
    }
    return strip_query_and_fragment(value);
}

/* `text(key)` of webview_error_metadata: strings, numbers and booleans as text. malloc'd. */
static char *data_text(const cj *data, const char *key) {
    const cj *value = cj_get(data, key);
    if (cj_is_str(value)) return cg_strdup(cj_as_str(value));
    if (cj_is_number(value) || cj_is_bool(value)) return cj_print(value);
    return cg_strdup("");
}

static char *data_text_or(const cj *data, const char *key, const char *fallback) {
    char *value = data_text(data, key);
    if (*value) return value;
    free(value);
    return data_text(data, fallback);
}

static char *sanitized_text(const cj *data, const char *key) {
    char *value = data_text(data, key);
    char *out = cg_telemetry_sanitize_stats_url(value);
    free(value);
    return out;
}

cj *cg_telemetry_webview_error_metadata(const cj *data) {
    char *error_type = data_text(data, "type");
    if (!*error_type) cg_replace(&error_type, cg_strdup("javascript_error"));
    struct {
        const char *key;
        char *value;
        size_t max;
    } fields[16] = {
        {"error_type", error_type, 64},
        {"message", data_text(data, "message"), 1024},
        {"source", sanitized_text(data, "source"), 512},
        {"line", data_text_or(data, "line", "lineno"), 32},
        {"column", data_text_or(data, "column", "colno"), 32},
        {"stack", data_text(data, "stack"), 2048},
        {"tag_name", data_text(data, "tag_name"), 64},
        {"href", sanitized_text(data, "href"), 512},
        {"user_agent", data_text(data, "user_agent"), 256},
        {"session_id", data_text(data, "session_id"), 128},
        {"duration_ms", data_text(data, "duration_ms"), 32},
        {"page_started_at", data_text(data, "page_started_at"), 64},
        {"previous_session_id", data_text(data, "previous_session_id"), 128},
        {"previous_href", sanitized_text(data, "previous_href"), 512},
        {"previous_started_at", data_text(data, "previous_started_at"), 64},
        {"previous_updated_at", data_text(data, "previous_updated_at"), 64},
    };
    cj *metadata = cj_obj();
    for (size_t i = 0; i < 16; i++) {
        if (*fields[i].value) cj_set(metadata, fields[i].key, cj_str_own(truncate_chars(fields[i].value, fields[i].max)));
        free(fields[i].value);
    }
    return metadata;
}

const char *cg_telemetry_exit_reason_action(int64_t reason) {
    switch (reason) {
        case 4: return "app_crash";
        case 5: return "app_crash_native";
        case 6: return "app_anr";
        case 3: return "app_killed_low_memory";
        case 9: return "app_killed_excessive_resource_usage";
        case 7: return "app_initialization_failure";
        default: return NULL;
    }
}

const char *cg_telemetry_exit_reason_name(int64_t reason) {
    switch (reason) {
        case 1: return "exit_self";
        case 2: return "signaled";
        case 3: return "low_memory";
        case 4: return "crash";
        case 5: return "crash_native";
        case 6: return "anr";
        case 7: return "initialization_failure";
        case 8: return "permission_change";
        case 9: return "excessive_resource_usage";
        case 10: return "user_requested";
        case 12: return "dependency_died";
        default: return "unknown";
    }
}

static bool stats_enabled(cg_engine *engine) {
    char *url = CG_CONFIG_DUP(engine, stats_url);
    bool enabled = *url != 0;
    free(url);
    return enabled;
}

static char *current_version_name(cg_engine *engine) {
    cg_bundle_info current;
    cg_store_current_bundle(engine, &current);
    char *name = cg_strdup(cg_bundle_info_version_name(&current));
    cg_bundle_info_clear(&current);
    return name;
}

void cg_telemetry_report_app_launch_start(cg_engine *engine) {
    cg_plugin_state *state = cg_plugin_lock_state(engine);
    if (state->launch_start_reported) {
        cg_plugin_unlock_state(engine);
        return;
    }
    state->launch_start_reported = true;
    int64_t started_at = state->launch_started_at_ms;
    cg_plugin_unlock_state(engine);
    if (!stats_enabled(engine)) return;
    cj *metadata = cj_objv("launch_started_at", cj_str_own(cg_fmt("%lld", (long long)started_at)), "source",
                           cj_str("plugin_load"), NULL);
    char *version = current_version_name(engine);
    cg_stats_send_stats(engine, "app_launch_start", version, "", metadata);
    free(version);
    cj_free(metadata);
}

/* Shared by ready / timeout: marks the launch reported (false when it already was). */
static bool claim_launch_end(cg_engine *engine, bool timeout, int64_t *started_at) {
    cg_plugin_state *state = cg_plugin_lock_state(engine);
    if (state->launch_ready_reported || state->launch_timeout_reported) {
        cg_plugin_unlock_state(engine);
        return false;
    }
    if (timeout) state->launch_timeout_reported = true;
    else state->launch_ready_reported = true;
    *started_at = state->launch_started_at_ms;
    cg_plugin_unlock_state(engine);
    return true;
}

static char *duration_since(int64_t started_at) {
    int64_t duration = cg_plugin_now_ms() - started_at;
    return cg_fmt("%lld", (long long)(duration < 0 ? 0 : duration));
}

void cg_telemetry_report_app_launch_ready(cg_engine *engine, const cg_bundle_info *bundle) {
    int64_t started_at;
    if (!claim_launch_end(engine, false, &started_at)) return;
    if (!stats_enabled(engine)) return;
    cj *metadata = cj_objv("duration_ms", cj_str_own(duration_since(started_at)), "launch_started_at",
                           cj_str_own(cg_fmt("%lld", (long long)started_at)), "source", cj_str("notify_app_ready"),
                           NULL);
    cg_stats_send_stats(engine, "app_launch_ready", cg_bundle_info_version_name(bundle), "", metadata);
    cj_free(metadata);
}

void cg_telemetry_report_app_launch_timeout(cg_engine *engine, const cg_bundle_info *bundle) {
    int64_t started_at;
    if (!claim_launch_end(engine, true, &started_at)) return;
    if (!stats_enabled(engine)) return;
    char *duration = duration_since(started_at);
    char *timeout = cg_fmt("%lld", (long long)cg_ready_app_ready_check_timeout(engine));
    cj *metadata = cj_objv("duration_ms", cj_str_own(duration), "launch_started_at",
                           cj_str_own(cg_fmt("%lld", (long long)started_at)), "timeout_ms", cj_str_own(timeout),
                           "source", cj_str("app_ready_timeout"), NULL);
    cg_stats_send_stats(engine, "app_launch_timeout", cg_bundle_info_version_name(bundle), "", metadata);
    cj_free(metadata);
}

/* Sends `action` and applies `writes` (consumed) once the server acknowledged it. */
static void send_stats_then_persist(cg_engine *engine, const char *action, const cj *metadata, cg_kv_writes *writes) {
    char *random = cg_store_random_id();
    char *callback_id = cg_fmt("capgo-ack-%s", random);
    free(random);
    cg_stats_add_ack(engine, callback_id, writes);
    char *version = current_version_name(engine);
    cg_stats_send_stats_with_callback(engine, action, version, "", metadata, callback_id);
    free(version);
    free(callback_id);
}

static char *kv_text_or_empty(cg_engine *engine, const char *key) {
    char *value = cg_plugin_kv_text(engine, key);
    return value ? value : cg_strdup("");
}

void cg_telemetry_report_native_version_stats_if_changed(cg_engine *engine) {
    cg_engine_config *config = cg_engine_config_snapshot(engine);
    char *version_build = cg_strdup(config->version_build);
    char *version_code;
    if (!*config->version_code) {
        cg_plugin_config plugin_config;
        cg_plugin_plugin_config(engine, &plugin_config);
        version_code = cg_strdup(plugin_config.native_build);
        cg_plugin_config_clear(&plugin_config);
    } else {
        version_code = cg_strdup(config->version_code);
    }
    char *version_os = cg_strdup(config->version_os);
    cg_config_release(config);
    char *previous_os = kv_text_or_empty(engine, CG_KEY_LAST_VERSION_OS);
    char *previous_build = kv_text_or_empty(engine, CG_KEY_LAST_VERSION_BUILD);
    char *previous_code = kv_text_or_empty(engine, CG_KEY_LAST_VERSION_CODE);

    bool os_changed = *version_os && *previous_os && strcmp(previous_os, version_os) != 0;
    if (os_changed) {
        cj *metadata = cj_objv("previous_version_os", cj_str(previous_os), "current_version_os", cj_str(version_os),
                               NULL);
        cg_kv_writes writes = {0};
        cg_kv_writes_push(&writes, cg_strdup(CG_KEY_LAST_VERSION_OS), cg_strdup(version_os));
        send_stats_then_persist(engine, "os_version_changed", metadata, &writes);
        cg_kv_writes_clear(&writes);
        cj_free(metadata);
    }
    bool has_previous_native = *previous_build || *previous_code;
    bool native_changed = has_previous_native &&
                          (strcmp(previous_build, version_build) != 0 || strcmp(previous_code, version_code) != 0);
    if (native_changed) {
        cj *metadata = cj_objv("previous_version_build", cj_str(previous_build), "current_version_build",
                               cj_str(version_build), "previous_version_code", cj_str(previous_code),
                               "current_version_code", cj_str(version_code), NULL);
        cg_kv_writes writes = {0};
        cg_kv_writes_push(&writes, cg_strdup(CG_KEY_LAST_VERSION_BUILD), cg_strdup(version_build));
        cg_kv_writes_push(&writes, cg_strdup(CG_KEY_LAST_VERSION_CODE), cg_strdup(version_code));
        send_stats_then_persist(engine, "native_app_version_changed", metadata, &writes);
        cg_kv_writes_clear(&writes);
        cj_free(metadata);
    }
    if (!os_changed) cg_plugin_kv_write(engine, CG_KEY_LAST_VERSION_OS, version_os);
    if (!native_changed) {
        cg_plugin_kv_write(engine, CG_KEY_LAST_VERSION_BUILD, version_build);
        cg_plugin_kv_write(engine, CG_KEY_LAST_VERSION_CODE, version_code);
    }
    free(version_build);
    free(version_code);
    free(version_os);
    free(previous_os);
    free(previous_build);
    free(previous_code);
}

void cg_telemetry_report_webview_stats(cg_engine *engine, const char *action, const cj *metadata) {
    cj *copy = cj_is_obj(metadata) ? cj_clone(metadata) : cj_obj();
    static const char *const url_keys[] = {"href", "source", "previous_href"};
    for (size_t i = 0; i < 3; i++) {
        const char *url = cj_as_str(cj_get(copy, url_keys[i]));
        if (!url) continue;
        char *sanitized = cg_telemetry_sanitize_stats_url(url);
        cj_set(copy, url_keys[i], cj_str_own(truncate_chars(sanitized, 512)));
        free(sanitized);
    }
    char *version = current_version_name(engine);
    cg_stats_send_stats(engine, action, version, "", copy);
    free(version);
    cj_free(copy);
}

void cg_telemetry_report_webview_error(cg_engine *engine, const cj *data) {
    const char *error_type = cj_as_str(cj_get(data, "type"));
    if (!error_type || !*error_type) error_type = "javascript_error";
    const char *action = cg_policy_stats_action_for_webview_error_type(error_type);
    cj *metadata = cg_telemetry_webview_error_metadata(data);
    cg_telemetry_report_webview_stats(engine, action, metadata);
    cj_free(metadata);
}

static int64_t exit_number(const cj *exit, const char *key) {
    int64_t value;
    return cj_as_i64(cj_get(exit, key), &value) ? value : 0;
}

void cg_telemetry_report_previous_exits(cg_engine *engine, const cj *exits) {
    if (!stats_enabled(engine)) return;
    int64_t last_reported = 0;
    char *stored = cg_plugin_kv_text(engine, LAST_REPORTED_APP_EXIT);
    if (stored && !cg_parse_i64(stored, &last_reported)) last_reported = 0;
    free(stored);
    int64_t newest = last_reported;
    size_t count = cj_len(exits);
    for (size_t i = 0; i < count && i < 8; i++) {
        const cj *exit = cj_at(exits, i);
        int64_t timestamp = exit_number(exit, "timestamp");
        if (timestamp <= last_reported) continue;
        int64_t reason = exit_number(exit, "reason");
        const char *action = cg_telemetry_exit_reason_action(reason);
        if (!action) continue;
        cj *metadata = cj_objv(
            "exit_reason", cj_str(cg_telemetry_exit_reason_name(reason)), "exit_reason_code",
            cj_str_own(cg_fmt("%lld", (long long)reason)), "exit_status",
            cj_str_own(cg_fmt("%lld", (long long)exit_number(exit, "status"))), "exit_importance",
            cj_str_own(cg_fmt("%lld", (long long)exit_number(exit, "importance"))), "exit_timestamp",
            cj_str_own(cg_fmt("%lld", (long long)timestamp)), "pid",
            cj_str_own(cg_fmt("%lld", (long long)exit_number(exit, "pid"))), "pss_kb",
            cj_str_own(cg_fmt("%lld", (long long)exit_number(exit, "pss"))), "rss_kb",
            cj_str_own(cg_fmt("%lld", (long long)exit_number(exit, "rss"))), NULL);
        static const struct {
            const char *key, *source;
            size_t max;
        } texts[] = {{"process_name", "processName", 128}, {"exit_description", "description", 512}};
        for (size_t j = 0; j < 2; j++) {
            const char *value = cj_as_str(cj_get(exit, texts[j].source));
            if (value && *value) cj_set(metadata, texts[j].key, cj_str_own(truncate_chars(value, texts[j].max)));
        }
        cg_telemetry_report_webview_stats(engine, action, metadata);
        cj_free(metadata);
        if (timestamp > newest) newest = timestamp;
    }
    if (newest > last_reported) {
        char *text = cg_fmt("%lld", (long long)newest);
        cg_plugin_kv_write(engine, LAST_REPORTED_APP_EXIT, text);
        free(text);
    }
}

void cg_telemetry_report_previous_unclean_exit_and_start_session(cg_engine *engine) {
    char *previous = cg_plugin_kv_text(engine, APP_SESSION_ID);
    if (previous && !*previous) {
        free(previous);
        previous = NULL;
    }
    char *last_reported = cg_plugin_kv_text(engine, LAST_REPORTED_UNCLEAN_SESSION);
    bool was_foreground = false;
    if (!cg_plugin_kv_flag(engine, APP_SESSION_FOREGROUND, &was_foreground)) was_foreground = false;
    if (previous && was_foreground && !(last_reported && strcmp(previous, last_reported) == 0)) {
        cj *metadata = cj_objv("exit_reason", cj_str("unclean_foreground_exit"), "exit_source",
                               cj_str("ios_session_marker"), "previous_session_id", cj_str(previous), NULL);
        char *started = cg_plugin_kv_text(engine, APP_SESSION_STARTED_AT);
        if (started && *started) cj_set(metadata, "session_started_at", cj_str(started));
        free(started);
        cg_telemetry_report_webview_stats(engine, "app_crash", metadata);
        cj_free(metadata);
        cg_plugin_kv_write(engine, LAST_REPORTED_UNCLEAN_SESSION, previous);
    }
    free(previous);
    free(last_reported);
    char *random = cg_store_random_id();
    char *session = cg_fmt("%s-%lld", random, (long long)cg_plugin_now_ms());
    free(random);
    cg_plugin_kv_write(engine, APP_SESSION_ID, session);
    free(session);
    cg_plugin_kv_write_flag(engine, APP_SESSION_FOREGROUND, true);
    char *now = cg_fmt("%lld", (long long)cg_plugin_now_ms());
    cg_plugin_kv_write(engine, APP_SESSION_STARTED_AT, now);
    free(now);
}

void cg_telemetry_mark_session_foreground(cg_engine *engine, bool foreground) {
    bool track = cg_plugin_config_track_unclean_exits(&cg_plugin_lock_state(engine)->config);
    cg_plugin_unlock_state(engine);
    if (track) cg_plugin_kv_write_flag(engine, APP_SESSION_FOREGROUND, foreground);
}

void cg_telemetry_report_memory_warning(cg_engine *engine) {
    cj *metadata = cj_objv("source", cj_str("ios_memory_warning"), NULL);
    cg_telemetry_report_webview_stats(engine, "app_memory_warning", metadata);
    cj_free(metadata);
}

void cg_telemetry_persist_render_process_gone(cg_engine *engine, const cj *metadata) {
    char *text = cj_print(metadata);
    cg_plugin_kv_write(engine, LAST_RENDER_PROCESS_GONE, text);
    free(text);
}

void cg_telemetry_report_previous_render_process_gone(cg_engine *engine) {
    char *raw = cg_plugin_kv_text(engine, LAST_RENDER_PROCESS_GONE);
    if (!raw) return;
    cg_plugin_kv_write(engine, LAST_RENDER_PROCESS_GONE, NULL);
    cj *stored = cj_parse(raw, NULL);
    free(raw);
    if (!cj_is_obj(stored)) {
        cj_free(stored);
        return;
    }
    cj *metadata = cj_obj();
    for (size_t i = 0; i < cj_len(stored); i++) {
        const cj *value = cj_value_at(stored, i);
        char *text = cj_is_str(value) ? cg_strdup(cj_as_str(value)) : cj_print(value);
        cj_set(metadata, cj_key_at(stored, i), cj_str_own(text));
    }
    cj_free(stored);
    cj_set(metadata, "reported_after_restart", cj_str("true"));
    cg_telemetry_report_webview_stats(engine, "webview_render_process_gone", metadata);
    cj_free(metadata);
}

void cg_telemetry_notify_download(cg_engine *engine, const char *id, int64_t percent) {
    cg_bundle_info bundle;
    cg_store_get_bundle_info(engine, id, &bundle);
    cj *payload = cj_objv("percent", cj_i64(percent), "bundle", cg_bundle_info_to_js(&bundle), NULL);
    cg_host_emit(&engine->host, "download", payload);
    cj_free(payload);
    if (percent >= 100) {
        cg_plugin_emit_bundle_event(engine, "downloadComplete", &bundle);
        cg_stats_send_stats(engine, "download_complete", cg_bundle_info_version_name(&bundle), NULL, NULL);
        cg_plugin_state_remove_stat_percent(cg_plugin_lock_state(engine), id);
        cg_plugin_unlock_state(engine);
        cg_bundle_info_clear(&bundle);
        return;
    }
    int64_t bucket = (percent / 10) * 10;
    /* Per download: concurrent downloads must not suppress each other's buckets. */
    cg_plugin_state *state = cg_plugin_lock_state(engine);
    int64_t last = 0;
    if (!cg_plugin_state_stat_percent(state, id, &last)) last = 0;
    if (percent == 0) last = 0;
    bool should_send = bucket > last;
    if (should_send) last = bucket;
    cg_plugin_state_set_stat_percent(state, id, last);
    cg_plugin_unlock_state(engine);
    if (should_send) {
        char *action = cg_fmt("download_%lld", (long long)bucket);
        cg_stats_send_stats(engine, action, cg_bundle_info_version_name(&bundle), NULL, NULL);
        free(action);
    }
    cg_bundle_info_clear(&bundle);
}

void cg_telemetry_forget_download_progress(cg_engine *engine, const char *id) {
    cg_plugin_state_remove_stat_percent(cg_plugin_lock_state(engine), id);
    cg_plugin_unlock_state(engine);
}
