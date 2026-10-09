/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/*
 * Preview sessions: try other bundles (channels, pull requests) on a device and come back
 * to the live bundle. Port of Rust engine/plugin/preview.rs.
 */
#include "engine/plugin/preview.h"

#include <stdlib.h>
#include <string.h>
#include <strings.h>

#include "engine/backend.h"
#include "engine/engine.h"
#include "engine/plugin/channel.h"
#include "engine/plugin/methods.h"
#include "engine/plugin/ready.h"
#include "engine/store.h"
#include "host.h"
#include "net_url.h"
#include "rt/str.h"

#define PREVIEW_NOTICE_DELAY_MS 600
/* Download URL used when a preview payload only carries a manifest. */
#define NO_ZIP_URL "https://404.capgo.app/no.zip"

/* ---- URLs (Rust url::Url) */

static bool is_special_scheme(const char *scheme) {
    return strcmp(scheme, "http") == 0 || strcmp(scheme, "https") == 0 || strcmp(scheme, "ws") == 0 ||
           strcmp(scheme, "wss") == 0 || strcmp(scheme, "ftp") == 0;
}

static bool is_dot(const char *segment, size_t len) {
    return (len == 1 && segment[0] == '.') || (len == 3 && strncasecmp(segment, "%2e", 3) == 0);
}

static bool is_dot_dot(const char *segment, size_t len) {
    if (len == 2) return segment[0] == '.' && segment[1] == '.';
    if (len == 4) return (segment[0] == '.' && strncasecmp(segment + 1, "%2e", 3) == 0) ||
                         (strncasecmp(segment, "%2e", 3) == 0 && segment[3] == '.');
    if (len == 6) return strncasecmp(segment, "%2e%2e", 6) == 0;
    return false;
}

/* WHATWG path parsing of [path, path + len) (starts with '/'): dot segments resolved.
 * Percent-encoding is not applied: the result is only compared with plain ASCII paths. */
static char *normalize_path(const char *path, size_t len) {
    cg_strs segments = {0};
    size_t at = 1;
    for (;;) {
        const char *start = path + at;
        const char *slash = at <= len ? memchr(start, '/', len - at) : NULL;
        size_t seg_len = slash ? (size_t)(slash - start) : len - at;
        bool last = slash == NULL;
        if (is_dot_dot(start, seg_len)) {
            if (segments.len > 0) free(segments.items[--segments.len]);
            if (last) cg_strs_push_copy(&segments, "");
        } else if (is_dot(start, seg_len)) {
            if (last) cg_strs_push_copy(&segments, "");
        } else {
            cg_strs_push(&segments, cg_strndup(start, seg_len));
        }
        if (last) break;
        at += seg_len + 1;
    }
    cg_buf out = {0};
    for (size_t i = 0; i < segments.len; i++) {
        cg_buf_putc(&out, '/');
        cg_buf_puts(&out, segments.items[i]);
    }
    if (out.len == 0) cg_buf_putc(&out, '/');
    cg_strs_free(&segments);
    return cg_buf_take(&out);
}

/* Opaque host forbidden code points (the url crate fails on them). */
static bool forbidden_opaque_host(const char *host, size_t len) {
    for (size_t i = 0; i < len; i++) {
        if (strchr(" #/:<>?@[\\]^|", host[i]) && host[i]) return true;
        if (host[i] == 0) return true;
    }
    return false;
}

/* Path (and, for non-special schemes, host) of a URL as `url::Url::parse` sees it: *host
 * malloc'd or NULL (no host), returns the path (malloc'd) or NULL when the URL does not
 * parse. */
static char *url_host_and_path(const char *url, char **scheme_out, char **host_out) {
    *scheme_out = NULL;
    *host_out = NULL;
    /* Leading / trailing C0 controls and spaces are trimmed, tabs and newlines removed. */
    const char *start = url, *end = url + strlen(url);
    while (start < end && (unsigned char)*start <= ' ') start++;
    while (end > start && (unsigned char)end[-1] <= ' ') end--;
    cg_buf clean = {0};
    for (const char *p = start; p < end; p++)
        if (*p != '\t' && *p != '\n' && *p != '\r') cg_buf_putc(&clean, *p);
    char *text = cg_buf_take(&clean);
    if (!text) text = cg_strdup("");
    size_t at = 0;
    char c = text[0];
    if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'))) {
        free(text);
        return NULL;
    }
    while ((c = text[at]) && ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
                              c == '+' || c == '-' || c == '.'))
        at++;
    if (text[at] != ':') {
        free(text);
        return NULL;
    }
    char *scheme = cg_strndup(text, at);
    for (char *p = scheme; *p; p++)
        if (*p >= 'A' && *p <= 'Z') *p = (char)(*p + 32);
    *scheme_out = scheme;
    const char *rest = text + at + 1;

    if (is_special_scheme(scheme)) {
        cg_url parsed;
        char *path = NULL;
        if (cg_url_parse(url, NULL, &parsed) == CG_URL_OK) {
            path = cg_url_path(&parsed);
            cg_url_clear(&parsed);
        }
        free(text);
        return path;
    }
    if (strcmp(scheme, "file") == 0) {
        char *copy = cg_strdup(rest);
        for (char *p = copy; *p; p++)
            if (*p == '\\') *p = '/';
        const char *p = copy;
        if (p[0] == '/' && p[1] == '/') p += 2 + strcspn(p + 2, "/?#");
        size_t len = strcspn(p, "?#");
        char *path;
        if (len > 0 && p[0] == '/') {
            path = normalize_path(p, len);
        } else {
            char *prefixed = cg_fmt("/%.*s", (int)len, p);
            path = normalize_path(prefixed, len + 1);
            free(prefixed);
        }
        free(copy);
        free(text);
        return path;
    }
    char *path = NULL;
    if (rest[0] == '/' && rest[1] == '/') {
        const char *authority = rest + 2;
        size_t authority_len = strcspn(authority, "/?#");
        const char *host = authority;
        size_t host_len = authority_len;
        bool has_userinfo = false;
        for (size_t i = authority_len; i > 0; i--) {
            if (authority[i - 1] == '@') {
                host = authority + i;
                host_len = authority_len - i;
                has_userinfo = true;
                break;
            }
        }
        if (host_len > 0 && host[0] == '[') {
            /* IPv6 hosts never form a preview path. */
            free(text);
            return NULL;
        }
        const char *colon = memchr(host, ':', host_len);
        size_t name_len = colon ? (size_t)(colon - host) : host_len;
        if (colon) {
            const char *port = colon + 1;
            size_t port_len = host_len - name_len - 1;
            uint64_t value = 0;
            for (size_t i = 0; i < port_len; i++) {
                if (port[i] < '0' || port[i] > '9') {
                    free(text);
                    return NULL;
                }
                value = value * 10 + (uint64_t)(port[i] - '0');
                if (value > 65535) {
                    free(text);
                    return NULL;
                }
            }
        }
        if ((name_len == 0 && (has_userinfo || colon)) || forbidden_opaque_host(host, name_len)) {
            free(text);
            return NULL;
        }
        *host_out = cg_strndup(host, name_len);
        const char *p = authority + authority_len;
        size_t len = strcspn(p, "?#");
        path = len > 0 ? normalize_path(p, len) : cg_strdup("");
    } else if (rest[0] == '/') {
        path = normalize_path(rest, strcspn(rest, "?#"));
    } else {
        /* Cannot-be-a-base URL: the opaque path as written. */
        path = cg_strndup(rest, strcspn(rest, "?#"));
    }
    free(text);
    return path;
}

/* `true` for `/preview/channel` and `/preview/bundle` links (`capgo://preview/bundle` too). */
bool cg_preview_is_preview_deep_link(const char *url) {
    char *scheme, *host;
    char *path = url_host_and_path(url ? url : "", &scheme, &host);
    if (!path) {
        free(scheme);
        free(host);
        return false;
    }
    char *compared;
    if (strcmp(scheme, "capgo") == 0) {
        char *joined = cg_fmt("/%s%s", host ? host : "", path);
        cg_buf collapsed = {0};
        for (const char *p = joined; *p; p++) {
            if (*p == '/' && collapsed.len > 0 && collapsed.data[collapsed.len - 1] == '/') continue;
            cg_buf_putc(&collapsed, *p);
        }
        free(joined);
        compared = cg_buf_take(&collapsed);
        if (!compared) compared = cg_strdup("");
    } else {
        compared = cg_strdup(path);
    }
    bool matches = strcmp(compared, "/preview/channel") == 0 || strcmp(compared, "/preview/bundle") == 0;
    free(compared);
    free(path);
    free(scheme);
    free(host);
    return matches;
}

static char *normalized_payload_url(const char *raw) {
    char *value = cg_plugin_normalized_optional(raw);
    if (!value) return NULL;
    cg_url url;
    char *result = NULL;
    if (cg_url_parse(value, NULL, &url) == CG_URL_OK) {
        if (cg_url_scheme_is(&url, "http") || cg_url_scheme_is(&url, "https")) result = cg_strdup(url.serialization);
        cg_url_clear(&url);
    }
    free(value);
    return result;
}

/* ---- small helpers */

static bool kv_flag_or(cg_engine *engine, const char *key, bool fallback) {
    bool value;
    return cg_plugin_kv_flag(engine, key, &value) ? value : fallback;
}

static bool preview_enabled(cg_engine *engine) {
    bool enabled = cg_plugin_lock_state(engine)->preview_session_enabled;
    cg_plugin_unlock_state(engine);
    return enabled;
}

static bool allow_preview(cg_engine *engine) {
    cg_plugin_config config;
    cg_plugin_plugin_config(engine, &config);
    bool allowed = config.allow_preview;
    cg_plugin_config_clear(&config);
    return allowed;
}

static char *current_bundle_id(cg_engine *engine) {
    cg_bundle_info current;
    cg_store_current_bundle(engine, &current);
    char *id = cg_strdup(cg_bundle_info_id(&current));
    cg_bundle_info_clear(&current);
    return id;
}

/* normalized_optional(value.get(key).and_then(as_str)). */
static char *field(const cj *object, const char *key) { return cg_plugin_normalized_optional(cj_get_str(object, key)); }

/* ---- registry */

static cj *previews(cg_engine *engine) {
    char *raw = cg_plugin_kv_text(engine, CG_KEY_PREVIEW_SESSIONS);
    char *trimmed = raw ? cg_trim(raw) : NULL;
    bool empty = !trimmed || !*trimmed;
    free(trimmed);
    if (empty) {
        free(raw);
        return cj_obj();
    }
    cj *parsed = cj_parse(raw, NULL);
    free(raw);
    if (cj_is_obj(parsed)) return parsed;
    cj_free(parsed);
    cg_host_log(&engine->host, CG_WARN, "Could not parse preview sessions, clearing them");
    cg_plugin_kv_write(engine, CG_KEY_PREVIEW_SESSIONS, NULL);
    return cj_obj();
}

static void save_previews(cg_engine *engine, const cj *map) {
    char *text = cj_print(map);
    cg_plugin_kv_write(engine, CG_KEY_PREVIEW_SESSIONS, text);
    free(text);
}

static cj *preview_info(cg_engine *engine, const char *id, const cj *metadata, const cg_strs *available,
                        const char *current_id) {
    cg_bundle_info bundle;
    cg_store_get_bundle_info(engine, id, &bundle);
    if ((!cg_bundle_info_is_builtin(&bundle) && !cg_strs_contains(available, id)) ||
        cg_bundle_info_is_deleted(&bundle) || cg_bundle_info_is_error(&bundle)) {
        cg_bundle_info_clear(&bundle);
        return NULL;
    }
    char *now = cg_plugin_iso_now();
    cj *info = cj_obj();
    cj_set(info, "id", cj_str(id));
    cj_set(info, "bundle", cg_bundle_info_to_js(&bundle));
    cg_bundle_info_clear(&bundle);
    char *created = field(metadata, "createdAt");
    cj_set(info, "createdAt", created ? cj_str_own(created) : cj_str(now));
    char *updated = field(metadata, "updatedAt");
    cj_set(info, "updatedAt", updated ? cj_str_own(updated) : cj_str(now));
    char *last_used = field(metadata, "lastUsedAt");
    cj_set(info, "lastUsedAt", last_used ? cj_str_own(last_used) : cj_str(now));
    free(now);
    bool active = preview_enabled(engine) && strcmp(id, current_id) == 0;
    cj_set(info, "isActive", cj_bool(active));
    static const char *const keys[4] = {"name", "source", "appId", "payloadUrl"};
    for (size_t i = 0; i < 4; i++) {
        char *value = field(metadata, keys[i]);
        if (value) cj_set(info, keys[i], cj_str_own(value));
    }
    return info;
}

static cg_strs available_bundle_ids(cg_engine *engine) {
    cg_bundle_list list;
    cg_store_list(engine, false, &list);
    cg_strs ids = {0};
    for (size_t i = 0; i < list.len; i++) cg_strs_push_copy(&ids, cg_bundle_info_id(&list.items[i]));
    cg_bundle_list_clear(&list);
    return ids;
}

static const char *last_used_at(const cj *info) { return cg_or_empty(cj_get_str(info, "lastUsedAt")); }

/* Previews sorted by last use; stale entries are dropped when `cleanup`. */
cj *cg_preview_list_preview_infos(cg_engine *engine, bool cleanup) {
    cj *map = previews(engine);
    cg_strs available = available_bundle_ids(engine);
    char *current_id = current_bundle_id(engine);
    cj *infos = cj_arr();
    cg_strs stale = {0};
    for (size_t i = 0; i < cj_len(map); i++) {
        const char *id = cj_key_at(map, i);
        const cj *metadata = cj_value_at(map, i);
        cj *info = cj_is_obj(metadata) ? preview_info(engine, id, metadata, &available, current_id) : NULL;
        if (info) cj_push(infos, info);
        else cg_strs_push_copy(&stale, id);
    }
    /* Stable sort, most recent first (Rust sort_by on lastUsedAt descending). */
    size_t count = cj_len(infos);
    cj **items = infos->v.a.items;
    for (size_t i = 1; i < count; i++) {
        cj *item = items[i];
        size_t j = i;
        while (j > 0 && strcmp(last_used_at(item), last_used_at(items[j - 1])) > 0) {
            items[j] = items[j - 1];
            j--;
        }
        items[j] = item;
    }
    if (cleanup && stale.len > 0) {
        for (size_t i = 0; i < stale.len; i++) cj_remove(map, stale.items[i]);
        save_previews(engine, map);
    }
    cg_strs_free(&stale);
    free(current_id);
    cg_strs_free(&available);
    cj_free(map);
    return infos;
}

static cj *stored_preview_info(cg_engine *engine, const char *id) {
    cj *map = previews(engine);
    const cj *metadata = cj_get(map, id);
    if (!cj_is_obj(metadata)) {
        cj_free(map);
        return NULL;
    }
    char *current_id = current_bundle_id(engine);
    cg_strs available = available_bundle_ids(engine);
    cj *info = preview_info(engine, id, metadata, &available, current_id);
    cg_strs_free(&available);
    free(current_id);
    cj_free(map);
    return info;
}

/* Records (or refreshes) `bundle` in the registry; `old_id` is the preview it replaces. */
cj *cg_preview_record_preview_bundle(cg_engine *engine, const cg_bundle_info *bundle, const char *old_id) {
    char *now = cg_plugin_iso_now();
    const char *id = cg_bundle_info_id(bundle);
    const char *replacing = old_id && strcmp(old_id, id) != 0 ? old_id : NULL;
    cj *map = previews(engine);
    const cj *existing = cj_get(map, id);
    cj *metadata;
    if (cj_is_obj(existing)) metadata = cj_clone(existing);
    else if (replacing && cj_is_obj(cj_get(map, replacing))) metadata = cj_clone(cj_get(map, replacing));
    else metadata = cj_obj();
    cj_entry(metadata, "createdAt", cj_str(now));
    cj_set(metadata, "updatedAt", cj_str(now));
    char *current_id = current_bundle_id(engine);
    const cj *last_used = cj_get(metadata, "lastUsedAt");
    if (!last_used || cj_is_null(last_used) || strcmp(current_id, id) == 0)
        cj_set(metadata, "lastUsedAt", cj_str(now));
    cj_set(metadata, "version", cj_str(cg_bundle_info_version_name(bundle)));
    if (!replacing) {
        static const char *const fields[4][2] = {{"appId", CG_KEY_PREVIEW_APP_ID},
                                                 {"payloadUrl", CG_KEY_PREVIEW_PAYLOAD_URL},
                                                 {"name", CG_KEY_PREVIEW_NAME},
                                                 {"source", CG_KEY_PREVIEW_SOURCE}};
        for (size_t i = 0; i < 4; i++) {
            char *stored = cg_plugin_kv_text(engine, fields[i][1]);
            char *value = cg_plugin_normalized_optional(stored);
            free(stored);
            if (value) cj_set(metadata, fields[i][0], cj_str_own(value));
            else cj_remove(metadata, fields[i][0]);
        }
    }
    char *name = field(metadata, "name");
    if (!name) cj_set(metadata, "name", cj_str(cg_bundle_info_version_name(bundle)));
    free(name);
    if (replacing) cj_remove(map, replacing);
    cj_set(map, id, cj_clone(metadata));
    save_previews(engine, map);
    cj_free(map);
    cg_strs available = available_bundle_ids(engine);
    cj *info = preview_info(engine, id, metadata, &available, current_id);
    cg_strs_free(&available);
    if (!info) {
        bool active = preview_enabled(engine) && strcmp(current_id, id) == 0;
        info = cj_objv("id", cj_str(id), "bundle", cg_bundle_info_to_js(bundle), "createdAt", cj_str(now),
                       "updatedAt", cj_str(now), "lastUsedAt", cj_str(now), "isActive", cj_bool(active), NULL);
    }
    cj_free(metadata);
    free(current_id);
    free(now);
    return info;
}

void cg_preview_set_active_app_id(cg_engine *engine, const char *app_id) {
    cj *value = cj_objv("appId", cj_str(app_id), NULL);
    cg_error err = CG_ERROR_INIT;
    cg_engine_configure(engine, value, &err);
    cg_err_clear(&err);
    cj_free(value);
}

static void restore_preview_previous_app_id(cg_engine *engine) {
    char *previous = cg_plugin_kv_text(engine, CG_KEY_PREVIEW_PREVIOUS_APP_ID);
    if (previous && *previous) {
        cg_preview_set_active_app_id(engine, previous);
        cg_info(&engine->host, "Restored appId after preview: %s", previous);
    }
    free(previous);
}

static void update_current_preview_metadata_from(cg_engine *engine, const cj *preview) {
    char *app_id = field(preview, "appId");
    if (app_id) {
        cg_preview_set_active_app_id(engine, app_id);
        cg_plugin_kv_write(engine, CG_KEY_PREVIEW_APP_ID, app_id);
    } else {
        restore_preview_previous_app_id(engine);
        cg_plugin_kv_write(engine, CG_KEY_PREVIEW_APP_ID, NULL);
    }
    free(app_id);
    static const char *const fields[3][2] = {{"payloadUrl", CG_KEY_PREVIEW_PAYLOAD_URL},
                                             {"name", CG_KEY_PREVIEW_NAME},
                                             {"source", CG_KEY_PREVIEW_SOURCE}};
    for (size_t i = 0; i < 3; i++) {
        char *value = field(preview, fields[i][0]);
        cg_plugin_kv_write(engine, fields[i][1], value);
        free(value);
    }
}

/* ---- state transitions */

static bool prepare_preview_fallback_if_needed(cg_engine *engine) {
    if (preview_enabled(engine)) return true;
    const cg_host *host = &engine->host;
    cg_bundle_info current;
    cg_store_current_bundle(engine, &current);
    if (!cg_store_set_preview_fallback_bundle(engine, cg_bundle_info_id(&current))) {
        cg_host_log(host, CG_ERROR, "Could not save current bundle as preview fallback");
        cg_bundle_info_clear(&current);
        return false;
    }
    cg_bundle_info next;
    if (cg_store_next_bundle(engine, &next)) {
        if (!cg_bundle_info_is_deleted(&next) && !cg_bundle_info_is_error(&next))
            cg_plugin_kv_write(engine, CG_KEY_PREVIEW_PREVIOUS_NEXT_BUNDLE, cg_bundle_info_id(&next));
        else cg_plugin_kv_write(engine, CG_KEY_PREVIEW_PREVIOUS_NEXT_BUNDLE, NULL);
        cg_bundle_info_clear(&next);
    } else {
        cg_plugin_kv_write(engine, CG_KEY_PREVIEW_PREVIOUS_NEXT_BUNDLE, NULL);
    }
    char *app_id = CG_CONFIG_DUP(engine, app_id);
    cg_plugin_kv_write(engine, CG_KEY_PREVIEW_PREVIOUS_APP_ID, app_id);
    free(app_id);
    if (!cg_channel_snapshot_default_channel_for_preview(engine)) {
        /* No session starts: nothing may stay behind (a stale liveBundle, a protected fallback). */
        cg_store_set_preview_fallback_bundle(engine, NULL);
        cg_plugin_kv_write(engine, CG_KEY_PREVIEW_PREVIOUS_NEXT_BUNDLE, NULL);
        cg_plugin_kv_write(engine, CG_KEY_PREVIEW_PREVIOUS_APP_ID, NULL);
        cg_bundle_info_clear(&current);
        return false;
    }
    cg_plugin_state *state = cg_plugin_lock_state(engine);
    bool menu = state->shake_menu_enabled, selector = state->shake_channel_selector_enabled;
    cg_plugin_unlock_state(engine);
    cg_plugin_kv_write_flag(engine, CG_KEY_PREVIEW_PREVIOUS_SHAKE_MENU, menu);
    cg_plugin_kv_write_flag(engine, CG_KEY_PREVIEW_PREVIOUS_SHAKE_CHANNEL_SELECTOR, selector);
    cg_info(host, "Preview session started with fallback bundle: %s", cg_bundle_info_id(&current));
    cg_bundle_info_clear(&current);
    return true;
}

static void activate_preview_session_state(cg_engine *engine) {
    cg_preview_clear_incoming_preview_transition(engine);
    cg_plugin_preview_loader(engine, false, "preview-session-started");
    cg_plugin_state *state = cg_plugin_lock_state(engine);
    state->preview_session_enabled = true;
    state->preview_alert_pending = true;
    state->shake_menu_enabled = true;
    cg_plugin_unlock_state(engine);
    cg_plugin_set_engine_preview_session(engine, true);
    cg_plugin_kv_write_flag(engine, CG_KEY_PREVIEW_SESSION, true);
    cg_plugin_kv_write_flag(engine, CG_KEY_PREVIEW_ALERT_PENDING, true);
    cg_plugin_sync_shake_menu(engine);
}

/* Clears the "leaving preview" guard (called when the new page is ready). */
void cg_preview_clear_incoming_preview_transition(cg_engine *engine) {
    cg_plugin_state *state = cg_plugin_lock_state(engine);
    state->leaving_preview_for_link = false;
    bool enabled = state->preview_session_enabled;
    cg_plugin_unlock_state(engine);
    if (!enabled) cg_plugin_set_engine_preview_session(engine, false);
}

static void restore_preview_previous_next_bundle(cg_engine *engine) {
    char *id = cg_plugin_kv_text(engine, CG_KEY_PREVIEW_PREVIOUS_NEXT_BUNDLE);
    if (!id || !*id) {
        cg_store_set_next_bundle(engine, NULL);
    } else if (!cg_store_set_next_bundle(engine, id)) {
        cg_warn(&engine->host, "Could not restore pre-preview next bundle: %s", id);
        cg_store_set_next_bundle(engine, NULL);
    }
    free(id);
}

static void clear_preview_session_preferences(cg_engine *engine) {
    cg_store_set_preview_fallback_bundle(engine, NULL);
    cg_channel_snapshot snapshot;
    cg_channel_channel_snapshot(engine, &snapshot);
    bool snapshot_pending =
        snapshot.kind == CG_CHANNEL_SNAPSHOT_SNAPSHOT || snapshot.kind == CG_CHANNEL_SNAPSHOT_UNREADABLE;
    cg_channel_snapshot_clear(&snapshot);
    static const char *const keys[] = {
        CG_KEY_PREVIEW_SESSION,       CG_KEY_PREVIEW_PREVIOUS_SHAKE_MENU, CG_KEY_PREVIEW_PREVIOUS_SHAKE_CHANNEL_SELECTOR,
        CG_KEY_PREVIEW_PREVIOUS_NEXT_BUNDLE, CG_KEY_PREVIEW_PREVIOUS_APP_ID, CG_KEY_PREVIEW_APP_ID,
        CG_KEY_PREVIEW_PAYLOAD_URL,   CG_KEY_PREVIEW_NAME,                CG_KEY_PREVIEW_SOURCE,
        CG_KEY_PREVIEW_ALERT_PENDING,
    };
    for (size_t i = 0; i < sizeof keys / sizeof *keys; i++) cg_plugin_kv_write(engine, keys[i], NULL);
    if (!snapshot_pending) {
        cg_plugin_kv_write(engine, CG_KEY_PREVIEW_PREVIOUS_DEFAULT_CHANNEL, NULL);
        cg_plugin_kv_write(engine, CG_KEY_PREVIEW_PREVIOUS_DEFAULT_CHANNEL_WAS_SET, NULL);
    }
}

static void end_preview_session(cg_engine *engine, bool keep_preview_guard) {
    cg_plugin_config config;
    cg_plugin_plugin_config(engine, &config);
    bool previous_menu = kv_flag_or(engine, CG_KEY_PREVIEW_PREVIOUS_SHAKE_MENU, config.shake_menu);
    bool previous_selector =
        kv_flag_or(engine, CG_KEY_PREVIEW_PREVIOUS_SHAKE_CHANNEL_SELECTOR, config.allow_shake_channel_selector);
    cg_plugin_config_clear(&config);
    restore_preview_previous_next_bundle(engine);
    restore_preview_previous_app_id(engine);
    cg_channel_restore_preview_previous_default_channel(engine);
    cg_plugin_state *state = cg_plugin_lock_state(engine);
    state->preview_session_enabled = false;
    state->preview_alert_pending = false;
    state->shake_menu_enabled = previous_menu;
    state->shake_channel_selector_enabled = previous_selector;
    cg_plugin_unlock_state(engine);
    if (keep_preview_guard) {
        /* The fallback's first launch must not be rolled back or auto-updated. */
        cg_plugin_set_engine_preview_session(engine, true);
    } else {
        cg_preview_clear_incoming_preview_transition(engine);
    }
    cg_plugin_sync_shake_menu(engine);
    clear_preview_session_preferences(engine);
    cg_host_log(&engine->host, CG_INFO, "Preview session ended");
}

/* Option<BundleInfo>: true with *out initialized. */
static bool resolve_preview_fallback(cg_engine *engine, const char *reason, cg_bundle_info *out) {
    const cg_host *host = &engine->host;
    cg_bundle_info fallback;
    bool has_fallback = cg_store_preview_fallback_bundle(engine, &fallback);
    if (has_fallback && !cg_bundle_info_is_error(&fallback) && cg_store_can_set(engine, &fallback)) {
        *out = fallback;
        return true;
    }
    if (!has_fallback)
        cg_warn(host, "No preview fallback bundle available for %s. Falling back to builtin bundle.", reason);
    else if (cg_bundle_info_is_error(&fallback))
        cg_warn(host, "Preview fallback bundle is in error state for %s. Falling back to builtin bundle.", reason);
    else
        cg_warn(host, "Preview fallback bundle is not installable for %s. Falling back to builtin bundle.", reason);
    if (has_fallback) cg_bundle_info_clear(&fallback);
    cg_bundle_info builtin;
    cg_store_get_bundle_info(engine, CG_BUNDLE_ID_BUILTIN, &builtin);
    if (!cg_bundle_info_is_error(&builtin) && cg_store_can_set(engine, &builtin)) {
        *out = builtin;
        return true;
    }
    cg_bundle_info_clear(&builtin);
    cg_error_log(host, "Builtin bundle is not available to leave preview for %s", reason);
    return false;
}

static bool reset_to_preview_fallback(cg_engine *engine) {
    cg_bundle_info fallback;
    if (!resolve_preview_fallback(engine, "leave preview", &fallback)) return false;
    cg_reset_state previous_state;
    cg_store_capture_reset_state(engine, &previous_state);
    cg_bundle_info current;
    cg_store_current_bundle(engine, &current);
    char *previous_name = cg_strdup(cg_bundle_info_version_name(&current));
    cg_bundle_info_clear(&current);
    cg_info(&engine->host, "Resetting to preview fallback bundle: %s", cg_bundle_info_version_name(&fallback));
    bool ok = false;
    if (cg_store_stage_preview_fallback_reload(engine, &fallback) && cg_ready_reload_without_waiting(engine)) {
        cg_store_finalize_reset_transition(engine, previous_name, false);
        cg_plugin_emit_set_event(engine, &fallback);
        ok = true;
    } else {
        cg_store_restore_reset_state(engine, &previous_state);
        cg_ready_restore_live_bundle(engine);
    }
    free(previous_name);
    cg_reset_state_clear(&previous_state);
    cg_bundle_info_clear(&fallback);
    return ok;
}

/* `resetPreview()` and the shake menu "leave preview" action. */
bool cg_preview_leave_preview_session(cg_engine *engine) {
    cg_plugin_preview_loader(engine, true, "leave-preview-session");
    if (!reset_to_preview_fallback(engine)) {
        cg_plugin_preview_loader(engine, false, "leave-preview-session-failed");
        return false;
    }
    end_preview_session(engine, true);
    return true;
}

static bool leave_preview_without_reload(cg_engine *engine, bool keep_guard) {
    cg_bundle_info fallback;
    if (!resolve_preview_fallback(engine, "preview deeplink launch", &fallback)) return false;
    bool staged = cg_store_stage_preview_fallback_reload(engine, &fallback);
    cg_bundle_info_clear(&fallback);
    if (!staged) {
        cg_host_log(&engine->host, CG_ERROR, "Could not stage preview fallback bundle");
        return false;
    }
    end_preview_session(engine, keep_guard);
    return true;
}

/* A preview deep link opened the app: restore the live bundle before the first load. */
void cg_preview_leave_preview_for_launch_url(cg_engine *engine, const char *url) {
    cg_plugin_state *state = cg_plugin_lock_state(engine);
    bool enabled = state->preview_session_enabled, leaving = state->leaving_preview_for_link;
    cg_plugin_unlock_state(engine);
    if (!enabled || leaving || !cg_preview_is_preview_deep_link(url)) return;
    cg_plugin_lock_state(engine)->leaving_preview_for_link = true;
    cg_plugin_unlock_state(engine);
    cg_plugin_preview_loader(engine, true, "preview-launch-deeplink");
    cg_host_log(&engine->host, CG_INFO,
                "Preview deeplink launch detected while preview session is active; restoring fallback before "
                "initial load");
    if (!leave_preview_without_reload(engine, false)) {
        cg_host_log(&engine->host, CG_ERROR,
                    "Could not leave preview session before initial preview deeplink routing");
        cg_plugin_lock_state(engine)->leaving_preview_for_link = false;
        cg_plugin_unlock_state(engine);
        cg_plugin_preview_loader(engine, false, "preview-launch-deeplink-failed");
    }
}

static void clear_transition_later(cg_engine_weak *weak, void *ctx) {
    int64_t delay = *(int64_t *)ctx;
    cg_engine *engine = cg_engine_sleep_unless_dropped(weak, delay);
    if (!engine) return;
    cg_preview_clear_incoming_preview_transition(engine);
    cg_engine_release(engine);
}

static bool leave_preview_for_incoming_link(cg_engine *engine) {
    cg_bundle_info fallback;
    if (!resolve_preview_fallback(engine, "incoming preview deeplink", &fallback)) {
        cg_preview_clear_incoming_preview_transition(engine);
        cg_plugin_preview_loader(engine, false, "incoming-preview-deeplink-failed");
        return false;
    }
    cg_reset_state previous_state;
    cg_store_capture_reset_state(engine, &previous_state);
    bool staged = cg_store_stage_preview_fallback_reload(engine, &fallback);
    cg_bundle_info_clear(&fallback);
    if (!staged) {
        cg_host_log(&engine->host, CG_ERROR, "Could not stage preview fallback bundle");
        cg_preview_clear_incoming_preview_transition(engine);
        cg_plugin_preview_loader(engine, false, "incoming-preview-deeplink-failed");
        cg_reset_state_clear(&previous_state);
        return false;
    }
    if (!cg_ready_reload_without_waiting(engine)) {
        cg_store_restore_reset_state(engine, &previous_state);
        cg_ready_restore_live_bundle(engine);
        cg_preview_clear_incoming_preview_transition(engine);
        cg_plugin_preview_loader(engine, false, "incoming-preview-deeplink-reload-failed");
        cg_reset_state_clear(&previous_state);
        return false;
    }
    cg_reset_state_clear(&previous_state);
    end_preview_session(engine, true);
    /* Keep the guard until the fallback had a chance to confirm itself. */
    cg_plugin_config config;
    cg_plugin_plugin_config(engine, &config);
    int64_t *delay = cg_malloc(sizeof *delay);
    *delay = (int64_t)config.app_ready_timeout_ms;
    cg_plugin_config_clear(&config);
    cg_engine_spawn_weak(engine, "preview", clear_transition_later, delay, free);
    return true;
}

static void leave_for_incoming_link_task(cg_engine_weak *weak, void *ctx) {
    cg_engine *engine = cg_engine_upgrade(weak);
    if (!engine) return;
    if (!leave_preview_for_incoming_link(engine))
        cg_host_log(&engine->host, CG_ERROR,
                    "Could not leave preview session before routing incoming preview deeplink");
    cg_engine_release(engine);
}

/* A preview deep link arrived while the app runs. Returns whether the link starts leaving
 * the preview (the host then routes it after the reload). */
bool cg_preview_handle_open_url(cg_engine *engine, const char *url) {
    cg_plugin_state *state = cg_plugin_lock_state(engine);
    bool enabled = state->preview_session_enabled, leaving = state->leaving_preview_for_link;
    cg_plugin_unlock_state(engine);
    if (!enabled || leaving || !cg_preview_is_preview_deep_link(url)) return false;
    cg_plugin_lock_state(engine)->leaving_preview_for_link = true;
    cg_plugin_unlock_state(engine);
    cg_plugin_preview_loader(engine, true, "incoming-preview-deeplink");
    cg_engine_spawn_weak(engine, "preview", leave_for_incoming_link_task, NULL, NULL);
    return true;
}

/* Rust download_preview_payload: CoreResult<BundleInfo>. */
static bool download_preview_payload(cg_engine *engine, const cj *payload, cg_bundle_info *out, cg_error *err) {
    char *version = cg_trim(cg_or_empty(cj_get_str(payload, "version")));
    if (!*version) {
        free(version);
        return cg_err_set(err, "invalid_payload", "Preview payload is missing a version");
    }
    const cj *manifest = cj_get(payload, "manifest");
    if (!cj_is_arr(manifest) || cj_len(manifest) == 0) manifest = NULL;
    const char *url = cg_or_empty(cj_get_str(payload, "url"));
    if (!*url && !manifest) {
        free(version);
        return cg_err_set(err, "invalid_payload", "Preview payload is missing download information");
    }
    if (!*url) url = NO_ZIP_URL;
    cg_bundle_info bundle;
    bool ok = cg_methods_download_bundle(engine, url, version, cg_or_empty(cj_get_str(payload, "sessionKey")),
                                         cg_or_empty(cj_get_str(payload, "checksum")), manifest, &bundle, err);
    free(version);
    if (!ok) return false;
    if (cg_bundle_info_is_error(&bundle)) {
        cg_err_set(err, "download_failed", "Download failed: %s",
                   cg_bundle_status_str(cg_bundle_info_status(&bundle)));
        cg_bundle_info_clear(&bundle);
        return false;
    }
    *out = bundle;
    return true;
}

/* Rust refresh_preview_from_payload: Result<bool, CoreError>. */
static bool refresh_preview_from_payload(cg_engine *engine, const char *url, bool *reloaded, cg_error *err) {
    cj *payload = cg_backend_fetch_json(engine, url, err);
    if (!payload) return false;
    char *version = cg_trim(cg_or_empty(cj_get_str(payload, "version")));
    if (!*version) {
        free(version);
        cj_free(payload);
        return cg_err_set(err, "invalid_payload", "Preview payload is missing a version");
    }
    cg_bundle_info current;
    cg_store_current_bundle(engine, &current);
    if (strcmp(version, cg_bundle_info_version_name(&current)) == 0) {
        cg_host_log(&engine->host, CG_INFO, "Preview payload unchanged, reloading current bundle");
        free(version);
        cj_free(payload);
        cg_bundle_info_clear(&current);
        *reloaded = cg_ready_reload_without_waiting(engine);
        return true;
    }
    free(version);
    cg_bundle_info next;
    bool downloaded = download_preview_payload(engine, payload, &next, err);
    cj_free(payload);
    if (!downloaded) {
        cg_bundle_info_clear(&current);
        return false;
    }
    if (!cg_store_set_bundle(engine, cg_bundle_info_id(&next))) {
        cg_bundle_info_clear(&next);
        cg_bundle_info_clear(&current);
        return cg_err_set(err, "set_failed", "Downloaded preview bundle cannot be applied");
    }
    cj_free(cg_preview_record_preview_bundle(engine, &next, cg_bundle_info_id(&current)));
    cg_plugin_emit_set_event(engine, &next);
    cg_bundle_info_clear(&next);
    cg_bundle_info_clear(&current);
    *reloaded = cg_ready_reload_without_waiting(engine);
    return true;
}

/* Shake menu "reload": refresh from the preview payload URL when there is one. */
bool cg_preview_reload_preview_session(cg_engine *engine) {
    cg_plugin_preview_loader(engine, true, "reload-preview-session");
    char *stored = cg_plugin_kv_text(engine, CG_KEY_PREVIEW_PAYLOAD_URL);
    char *payload_url = normalized_payload_url(stored);
    free(stored);
    bool reloaded;
    if (payload_url) {
        cg_error err = CG_ERROR_INIT;
        if (!refresh_preview_from_payload(engine, payload_url, &reloaded, &err)) {
            cg_error_log(&engine->host, "Could not refresh preview session: %s", err.message);
            cg_err_clear(&err);
            reloaded = false;
        }
        free(payload_url);
    } else {
        reloaded = cg_ready_reload_without_waiting(engine);
    }
    if (!reloaded) cg_plugin_preview_loader(engine, false, "reload-preview-session-failed");
    return reloaded;
}

static void reset_state_to_config(cg_engine *engine) {
    cg_plugin_config config;
    cg_plugin_plugin_config(engine, &config);
    cg_plugin_state *state = cg_plugin_lock_state(engine);
    state->preview_session_enabled = false;
    state->preview_alert_pending = false;
    state->leaving_preview_for_link = false;
    state->shake_menu_enabled = config.shake_menu;
    state->shake_channel_selector_enabled = config.allow_shake_channel_selector;
    cg_replace(&state->shake_menu_gesture, cg_strdup(config.shake_menu_gesture));
    cg_plugin_unlock_state(engine);
    cg_plugin_config_clear(&config);
}

/* Native build changed: previews point at bundles of the previous build. */
void cg_preview_clear_preview_session_for_native_build_change(cg_engine *engine) {
    bool enabled = preview_enabled(engine);
    if (!enabled) {
        cg_bundle_info fallback;
        bool has_fallback = cg_store_preview_fallback_bundle(engine, &fallback);
        if (has_fallback) cg_bundle_info_clear(&fallback);
        if (!has_fallback) {
            cj *map = previews(engine);
            bool empty = cj_len(map) == 0;
            cj_free(map);
            if (empty) return;
        }
    }
    cg_host_log(&engine->host, CG_INFO, "Native build changed; clearing preview session state");
    reset_state_to_config(engine);
    cg_plugin_set_engine_preview_session(engine, false);
    cg_plugin_sync_shake_menu(engine);
    restore_preview_previous_app_id(engine);
    cg_channel_restore_preview_previous_default_channel(engine);
    cg_store_set_preview_fallback_bundle(engine, NULL);
    cg_store_set_next_bundle(engine, NULL);
    clear_preview_session_preferences(engine);
    cg_plugin_kv_write(engine, CG_KEY_PREVIEW_SESSIONS, NULL);
}

static void clear_preview_session_because_disabled(cg_engine *engine) {
    cg_host_log(&engine->host, CG_INFO, "Preview session disabled by config; restoring preview fallback");
    cg_bundle_info bundle;
    if (resolve_preview_fallback(engine, "preview disabled", &bundle)) {
        cg_store_stage_preview_fallback_reload(engine, &bundle);
        cg_bundle_info_clear(&bundle);
    } else {
        cg_host_log(&engine->host, CG_WARN, "Could not restore preview fallback while disabling preview");
    }
    restore_preview_previous_next_bundle(engine);
    restore_preview_previous_app_id(engine);
    cg_channel_restore_preview_previous_default_channel(engine);
    reset_state_to_config(engine);
    cg_plugin_set_engine_preview_session(engine, false);
    cg_plugin_preview_loader(engine, false, "preview-session-disabled");
    cg_plugin_sync_shake_menu(engine);
    clear_preview_session_preferences(engine);
}

/* Load: resume (or drop, when `allowPreview` is off) a stored preview session. */
void cg_preview_restore_preview_state_at_load(cg_engine *engine) {
    cg_plugin_config config;
    cg_plugin_plugin_config(engine, &config);
    bool stored = kv_flag_or(engine, CG_KEY_PREVIEW_SESSION, false);
    if (stored && !config.allow_preview) {
        cg_plugin_config_clear(&config);
        clear_preview_session_because_disabled(engine);
        return;
    }
    bool enabled = stored && config.allow_preview;
    cg_plugin_lock_state(engine)->preview_session_enabled = enabled;
    cg_plugin_unlock_state(engine);
    cg_plugin_set_engine_preview_session(engine, enabled);
    if (!enabled) {
        cg_plugin_config_clear(&config);
        return;
    }
    bool alert_pending = kv_flag_or(engine, CG_KEY_PREVIEW_ALERT_PENDING, true);
    bool selector =
        kv_flag_or(engine, CG_KEY_PREVIEW_PREVIOUS_SHAKE_CHANNEL_SELECTOR, config.allow_shake_channel_selector);
    cg_plugin_config_clear(&config);
    cg_plugin_state *state = cg_plugin_lock_state(engine);
    state->preview_alert_pending = alert_pending;
    state->shake_menu_enabled = true;
    state->shake_channel_selector_enabled = selector;
    cg_plugin_unlock_state(engine);
    char *app_id = cg_plugin_kv_text(engine, CG_KEY_PREVIEW_APP_ID);
    if (app_id && *app_id) {
        cg_preview_set_active_app_id(engine, app_id);
        cg_info(&engine->host, "Using preview appId %s", app_id);
    }
    free(app_id);
}

static void preview_notice_task(cg_engine_weak *weak, void *ctx) {
    cg_engine *engine = cg_engine_sleep_unless_dropped(weak, PREVIEW_NOTICE_DELAY_MS);
    if (!engine) return;
    cg_plugin_state *state = cg_plugin_lock_state(engine);
    bool enabled = state->preview_session_enabled;
    char *gesture = cg_strdup(state->shake_menu_gesture);
    cg_plugin_unlock_state(engine);
    if (enabled) {
        cj *reply = cg_plugin_hook(engine, CG_HOOK_PREVIEW_NOTICE, cj_objv("gesture", cj_str_own(gesture), NULL));
        gesture = NULL;
        bool shown = false;
        if (!cj_as_bool(cj_get(reply, "shown"), &shown)) shown = false;
        cj_free(reply);
        if (!shown) {
            cg_plugin_lock_state(engine)->preview_alert_pending = true;
            cg_plugin_unlock_state(engine);
            cg_plugin_kv_write_flag(engine, CG_KEY_PREVIEW_ALERT_PENDING, true);
        }
    }
    free(gesture);
    cg_engine_release(engine);
}

/* Shows "Preview started" once per session (re-armed when the host could not show it). */
void cg_preview_show_preview_notice_if_needed(cg_engine *engine) {
    cg_plugin_state *state = cg_plugin_lock_state(engine);
    if (!state->preview_session_enabled || !state->preview_alert_pending) {
        cg_plugin_unlock_state(engine);
        return;
    }
    state->preview_alert_pending = false;
    cg_plugin_unlock_state(engine);
    cg_plugin_kv_write_flag(engine, CG_KEY_PREVIEW_ALERT_PENDING, false);
    cg_engine_spawn_weak(engine, "preview", preview_notice_task, NULL, NULL);
}

/* ---- methods */

static bool require_preview_allowed(cg_engine *engine, const char *method, cg_rejection *rejection) {
    if (allow_preview(engine)) return true;
    cg_rejection_newf(rejection, "%s not allowed. Set allowPreview to true in your config to enable it.", method);
    return false;
}

cj *cg_preview_method_start_preview_session(cg_engine *engine, const cj *args, cg_rejection *rejection) {
    if (!require_preview_allowed(engine, "startPreviewSession", rejection)) {
        cg_plugin_preview_loader(engine, false, "preview-session-not-allowed");
        return NULL;
    }
    char *app_id = field(args, "appId");
    const char *raw_payload_url = cj_get_str(args, "payloadUrl");
    char *payload_url = normalized_payload_url(raw_payload_url);
    char *raw_normalized = cg_plugin_normalized_optional(raw_payload_url);
    bool invalid = raw_normalized && !payload_url;
    free(raw_normalized);
    if (invalid) {
        cg_plugin_preview_loader(engine, false, "preview-session-invalid-payload");
        free(app_id);
        return cg_rejection_new(rejection, "Invalid preview payloadUrl");
    }
    if (!prepare_preview_fallback_if_needed(engine)) {
        cg_plugin_preview_loader(engine, false, "preview-session-fallback-failed");
        free(app_id);
        free(payload_url);
        return cg_rejection_new(rejection, "Could not save current bundle as preview fallback");
    }
    if (app_id) {
        cg_preview_set_active_app_id(engine, app_id);
        cg_plugin_kv_write(engine, CG_KEY_PREVIEW_APP_ID, app_id);
        cg_info(&engine->host, "Preview session using appId: %s", app_id);
    }
    free(app_id);
    cg_plugin_kv_write(engine, CG_KEY_PREVIEW_PAYLOAD_URL, payload_url);
    free(payload_url);
    char *name = field(args, "name");
    cg_plugin_kv_write(engine, CG_KEY_PREVIEW_NAME, name);
    free(name);
    char *source = field(args, "source");
    cg_plugin_kv_write(engine, CG_KEY_PREVIEW_SOURCE, source);
    free(source);
    activate_preview_session_state(engine);
    return cj_null();
}

cj *cg_preview_method_list_previews(cg_engine *engine, cg_rejection *rejection) {
    if (!require_preview_allowed(engine, "listPreviews", rejection)) return NULL;
    cj *list = cg_preview_list_preview_infos(engine, true);
    cj *result = cj_obj();
    for (size_t i = 0; i < cj_len(list); i++) {
        const cj *preview = cj_at(list, i);
        bool active = false;
        if (cj_as_bool(cj_get(preview, "isActive"), &active) && active) {
            cj_set(result, "current", cj_clone(preview));
            break;
        }
    }
    cj_set(result, "previews", list);
    cg_bundle_info current;
    cg_store_current_bundle(engine, &current);
    cj_set(result, "currentBundle", cg_bundle_info_to_js(&current));
    cg_bundle_info_clear(&current);
    cg_bundle_info live;
    if (cg_store_preview_fallback_bundle(engine, &live)) {
        cj_set(result, "liveBundle", cg_bundle_info_to_js(&live));
        cg_bundle_info_clear(&live);
    }
    return result;
}

/* `setPreview` / shake menu: switch to a stored preview. */
bool cg_preview_set_preview(cg_engine *engine, const char *id, const char *reason, cg_rejection *rejection) {
    cj *preview = stored_preview_info(engine, id);
    if (!preview) {
        cg_rejection_newf(rejection, "Preview %s is not available locally", id);
        return false;
    }
    cg_plugin_preview_loader(engine, true, reason);
    char *step = NULL;
    if (!prepare_preview_fallback_if_needed(engine)) {
        step = cg_fmt("%s-fallback-failed", reason);
        cg_plugin_preview_loader(engine, false, step);
        free(step);
        cj_free(preview);
        cg_rejection_new(rejection, "Could not save current bundle as preview fallback");
        return false;
    }
    if (!cg_store_set_bundle(engine, id)) {
        step = cg_fmt("%s-failed", reason);
        cg_plugin_preview_loader(engine, false, step);
        free(step);
        cj_free(preview);
        cg_rejection_newf(rejection, "Preview %s cannot be applied", id);
        return false;
    }
    cg_bundle_info bundle;
    cg_store_get_bundle_info(engine, id, &bundle);
    update_current_preview_metadata_from(engine, preview);
    cj_free(preview);
    activate_preview_session_state(engine);
    cj_free(cg_preview_record_preview_bundle(engine, &bundle, NULL));
    if (!cg_ready_reload_without_waiting(engine)) {
        step = cg_fmt("%s-reload-failed", reason);
        cg_plugin_preview_loader(engine, false, step);
        free(step);
        cg_bundle_info_clear(&bundle);
        cg_rejection_newf(rejection, "Reload failed after setting preview %s", id);
        return false;
    }
    cg_plugin_emit_set_event(engine, &bundle);
    cg_bundle_info_clear(&bundle);
    cg_preview_show_preview_notice_if_needed(engine);
    return true;
}

/* args.get(key).and_then(as_str).filter(non-empty). */
static const char *non_empty_str(const cj *args, const char *key) {
    const char *value = cj_get_str(args, key);
    return value && *value ? value : NULL;
}

/* An id with a NUL byte names no stored preview or bundle (Rust compares the whole string);
 * C strings stop at the NUL, so such ids are kept apart explicitly. */
static bool id_has_nul(const cj *args) { return cj_str_has_nul(cj_get(args, "id")); }

cj *cg_preview_method_set_preview(cg_engine *engine, const cj *args, cg_rejection *rejection) {
    if (!require_preview_allowed(engine, "setPreview", rejection)) return NULL;
    const char *id = non_empty_str(args, "id");
    if (!id) return cg_rejection_new(rejection, "setPreview called without id");
    if (id_has_nul(args)) {
        cj_free(previews(engine)); /* stored_preview_info reads (and may clear) the registry */
        return cg_rejection_newf(rejection, "Preview %s is not available locally", id);
    }
    return cg_preview_set_preview(engine, id, "set-preview", rejection) ? cj_null() : NULL;
}

cj *cg_preview_method_reset_preview(cg_engine *engine, cg_rejection *rejection) {
    if (!preview_enabled(engine)) return cj_null();
    if (cg_preview_leave_preview_session(engine)) return cj_null();
    return cg_rejection_new(rejection, "Could not leave preview session");
}

cj *cg_preview_method_delete_preview(cg_engine *engine, const cj *args, cg_rejection *rejection) {
    if (!require_preview_allowed(engine, "deletePreview", rejection)) return NULL;
    const char *id = non_empty_str(args, "id");
    if (!id) return cg_rejection_new(rejection, "deletePreview called without id");
    bool has_nul = id_has_nul(args);
    /* Copied first: the state lock must not be held across the bundle lookup. */
    bool preview_active = preview_enabled(engine);
    if (preview_active && !has_nul) {
        char *current_id = current_bundle_id(engine);
        bool is_current = strcmp(current_id, id) == 0;
        free(current_id);
        if (is_current) return cg_rejection_new(rejection, "Cannot delete the active preview");
    } else if (preview_active) {
        free(current_bundle_id(engine));
    }
    cj *map = previews(engine);
    bool removed = !has_nul && cj_remove(map, id);
    save_previews(engine, map);
    cj_free(map);
    cg_bundle_info fallback, next;
    bool has_fallback = cg_store_preview_fallback_bundle(engine, &fallback);
    bool has_next = cg_store_next_bundle(engine, &next);
    bool deleted = removed && strcmp(id, CG_BUNDLE_ID_BUILTIN) != 0 &&
                   (!has_fallback || strcmp(cg_bundle_info_id(&fallback), id) != 0) &&
                   (!has_next || strcmp(cg_bundle_info_id(&next), id) != 0) &&
                   cg_store_delete_bundle(engine, id, false, true);
    if (has_fallback) cg_bundle_info_clear(&fallback);
    if (has_next) cg_bundle_info_clear(&next);
    return cj_objv("deleted", cj_bool(deleted), "removed", cj_bool(removed), NULL);
}

/* Rust preview_update: Result<Value, CoreError>. */
static cj *preview_update(cg_engine *engine, const char *id, const cj *preview, const char *payload_url, bool download,
                          cg_error *err) {
    cj *payload = cg_backend_fetch_json(engine, payload_url, err);
    if (!payload) return NULL;
    char *version = cg_trim(cg_or_empty(cj_get_str(payload, "version")));
    if (!*version) {
        free(version);
        cj_free(payload);
        cg_err_set(err, "invalid_payload", "Preview payload is missing a version");
        return NULL;
    }
    cg_bundle_info current_preview;
    cg_store_get_bundle_info(engine, id, &current_preview);
    bool up_to_date = strcmp(version, cg_bundle_info_version_name(&current_preview)) == 0;
    if (up_to_date || !download) {
        cj *result = cj_objv("preview", cj_clone(preview), "latestVersion", cj_str_own(version), "upToDate",
                             cj_bool(up_to_date), "updated", cj_bool(false), "bundle",
                             cg_bundle_info_to_js(&current_preview), NULL);
        cg_bundle_info_clear(&current_preview);
        cj_free(payload);
        return result;
    }
    cg_bundle_info_clear(&current_preview);
    cg_bundle_info next;
    bool downloaded = download_preview_payload(engine, payload, &next, err);
    cj_free(payload);
    if (!downloaded) {
        free(version);
        return NULL;
    }
    bool was_active = false;
    if (preview_enabled(engine)) {
        char *current_id = current_bundle_id(engine);
        was_active = strcmp(current_id, id) == 0;
        free(current_id);
    }
    if (was_active && !cg_store_set_bundle(engine, cg_bundle_info_id(&next))) {
        cg_bundle_info_clear(&next);
        free(version);
        cg_err_set(err, "set_failed", "Downloaded preview bundle cannot be applied");
        return NULL;
    }
    cj *saved = cg_preview_record_preview_bundle(engine, &next, id);
    if (was_active) {
        if (!cg_ready_reload_without_waiting(engine)) {
            cj_free(saved);
            cg_bundle_info_clear(&next);
            free(version);
            cg_err_set(err, "reload_failed", "Reload failed after updating preview");
            return NULL;
        }
        cg_plugin_emit_set_event(engine, &next);
        cg_preview_show_preview_notice_if_needed(engine);
    }
    cj *result = cj_objv("preview", saved, "latestVersion", cj_str_own(version), "upToDate", cj_bool(false),
                         "updated", cj_bool(true), "bundle", cg_bundle_info_to_js(&next), NULL);
    cg_bundle_info_clear(&next);
    return result;
}

cj *cg_preview_method_preview_update(cg_engine *engine, const cj *args, bool download, cg_rejection *rejection) {
    if (!allow_preview(engine))
        return cg_rejection_new(rejection,
                                "Preview updates not allowed. Set allowPreview to true in your config to enable it.");
    const char *id = non_empty_str(args, "id");
    if (!id) return cg_rejection_new(rejection, "Preview update called without id");
    cj *preview = NULL;
    if (id_has_nul(args)) cj_free(previews(engine)); /* stored_preview_info reads (and may clear) the registry */
    else preview = stored_preview_info(engine, id);
    char *payload_url = preview ? normalized_payload_url(cj_get_str(preview, "payloadUrl")) : NULL;
    if (!preview || !payload_url) {
        cj_free(preview);
        free(payload_url);
        return cg_rejection_newf(rejection, "Preview %s has no payloadUrl to update from", id);
    }
    cg_error err = CG_ERROR_INIT;
    cj *result = preview_update(engine, id, preview, payload_url, download, &err);
    cj_free(preview);
    free(payload_url);
    if (!result) {
        cg_rejection_newf(rejection, "Could not update preview: %s", err.message);
        cg_err_clear(&err);
    }
    return result;
}
