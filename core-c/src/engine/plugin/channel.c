/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/*
 * Default channel persistence (reinstall handling, backup-excluded state files) and the
 * channel / latest-version plugin methods. Port of Rust engine/plugin/channel.rs.
 */
#include "engine/plugin/channel.h"

#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "engine/backend.h"
#include "engine/engine.h"
#include "engine/fsutil.h"
#include "engine/manifest.h"
#include "engine/plugin/flow.h"
#include "engine/plugin/methods.h"
#include "engine/store.h"
#include "host.h"
#include "policy.h"
#include "rt/str.h"

void cg_channel_snapshot_clear(cg_channel_snapshot *snapshot) {
    if (!snapshot) return;
    free(snapshot->channel);
    memset(snapshot, 0, sizeof *snapshot);
}

void cg_channel_state_clear(cg_channel_state *state) {
    if (!state) return;
    free(state->channel);
    memset(state, 0, sizeof *state);
}

/* ---- files */

static char *no_backup_file(cg_engine *engine, const char *name) {
    cg_plugin_config config;
    cg_plugin_plugin_config(engine, &config);
    char *path = *config.no_backup_dir ? cg_fsutil_join(config.no_backup_dir, name) : NULL;
    cg_plugin_config_clear(&config);
    return path;
}

static bool write_no_backup_file(cg_engine *engine, const char *path, const void *data, size_t len, cg_error *err) {
    char *parent = cg_fsutil_parent(path);
    if (parent && *parent && !cg_fsutil_create_dir_all_err(parent, err)) {
        free(parent);
        return false;
    }
    free(parent);
    if (!cg_fsutil_write_atomically(path, data, len, err)) return false;
    cj_free(cg_plugin_hook(engine, CG_HOOK_EXCLUDE_FROM_BACKUP, cj_objv("path", cj_str(path), NULL)));
    return true;
}

/* fs::read: *data malloc'd (NUL-terminated, *len bytes), false with the io error in *err. */
static bool read_file(const char *path, char **data, size_t *len, cg_error *err) {
    int fd = cg_fsutil_open(path, O_RDONLY, 0);
    if (fd < 0) return cg_fsutil_os_error(err, errno);
    cg_buf buf = {0};
    char chunk[8192];
    for (;;) {
        ssize_t n = read(fd, chunk, sizeof chunk);
        if (n < 0) {
            if (errno == EINTR) continue;
            int error = errno;
            close(fd);
            cg_buf_free(&buf);
            return cg_fsutil_os_error(err, error);
        }
        if (n == 0) break;
        cg_buf_put(&buf, chunk, (size_t)n);
    }
    close(fd);
    *len = buf.len;
    if (!buf.data) cg_buf_reserve(&buf, 0);
    *data = cg_buf_take(&buf);
    return true;
}

/* fs::remove_file: false with errno. */
static bool remove_file(const char *path) { return unlink(path) == 0; }

void cg_channel_default_channel_state(cg_engine *engine, cg_channel_state *out) {
    memset(out, 0, sizeof *out);
    out->readable = true;
    char *path = no_backup_file(engine, CG_KEY_DEFAULT_CHANNEL_STATE_FILE);
    if (!path) return;
    if (!cg_fsutil_exists(path)) {
        free(path);
        return;
    }
    char *data;
    size_t len;
    cg_error err = CG_ERROR_INIT;
    if (!read_file(path, &data, &len, &err)) {
        cg_warn(&engine->host, "Cannot read persisted default channel state: %s", err.message);
        cg_err_clear(&err);
        out->exists = true;
        out->readable = false;
        free(path);
        return;
    }
    free(path);
    out->exists = true;
    if (len == 0) {
        free(data);
        return;
    }
    if (!cg_utf8_valid(data, len)) {
        cg_host_log(&engine->host, CG_WARN, "Cannot decode persisted default channel state");
        free(data);
        out->readable = false;
        return;
    }
    out->channel = data;
}

static bool write_default_channel_state(cg_engine *engine, const char *channel, cg_error *err) {
    char *path = no_backup_file(engine, CG_KEY_DEFAULT_CHANNEL_STATE_FILE);
    if (!path) return true;
    const char *data = channel ? channel : "";
    bool ok = write_no_backup_file(engine, path, data, strlen(data), err);
    free(path);
    return ok;
}

void cg_channel_channel_snapshot(cg_engine *engine, cg_channel_snapshot *out) {
    memset(out, 0, sizeof *out);
    char *path = no_backup_file(engine, CG_KEY_DEFAULT_CHANNEL_SNAPSHOT_FILE);
    if (!path || !cg_fsutil_exists(path)) {
        free(path);
        out->kind = CG_CHANNEL_SNAPSHOT_MISSING;
        return;
    }
    char *data;
    size_t len;
    cg_error err = CG_ERROR_INIT;
    bool ok = read_file(path, &data, &len, &err);
    free(path);
    cg_err_clear(&err);
    out->kind = CG_CHANNEL_SNAPSHOT_UNREADABLE;
    if (!ok) return;
    if (len == 1 && data[0] == 0) {
        out->kind = CG_CHANNEL_SNAPSHOT_INVALIDATED;
    } else if (len == 1 && data[0] == 1) {
        out->kind = CG_CHANNEL_SNAPSHOT_SNAPSHOT;
    } else if (len >= 1 && data[0] == 2) {
        if (cg_utf8_valid(data + 1, len - 1)) {
            out->kind = CG_CHANNEL_SNAPSHOT_SNAPSHOT;
            out->channel = cg_strndup(data + 1, len - 1);
        }
    }
    free(data);
}

bool cg_channel_write_channel_snapshot(cg_engine *engine, const cg_channel_snapshot *snapshot, cg_error *err) {
    char *path = no_backup_file(engine, CG_KEY_DEFAULT_CHANNEL_SNAPSHOT_FILE);
    if (!path) return true;
    cg_buf data = {0};
    if (snapshot->kind == CG_CHANNEL_SNAPSHOT_SNAPSHOT && snapshot->channel) {
        cg_buf_putc(&data, 2);
        cg_buf_puts(&data, snapshot->channel);
    } else if (snapshot->kind == CG_CHANNEL_SNAPSHOT_SNAPSHOT) {
        cg_buf_putc(&data, 1);
    } else {
        cg_buf_putc(&data, 0);
    }
    bool ok = write_no_backup_file(engine, path, data.data, data.len, err);
    cg_buf_free(&data);
    free(path);
    return ok;
}

static bool has_pending_channel_snapshot(cg_engine *engine) {
    cg_channel_snapshot snapshot;
    cg_channel_channel_snapshot(engine, &snapshot);
    bool pending = snapshot.kind == CG_CHANNEL_SNAPSHOT_SNAPSHOT || snapshot.kind == CG_CHANNEL_SNAPSHOT_UNREADABLE;
    cg_channel_snapshot_clear(&snapshot);
    return pending;
}

static bool plugin_flag_persist_on_reinstall(cg_engine *engine) {
    cg_plugin_config config;
    cg_plugin_plugin_config(engine, &config);
    bool value = config.persist_default_channel_on_reinstall;
    cg_plugin_config_clear(&config);
    return value;
}

/* The channel that `setChannel` persisted (state file first, then the key/value store). */
char *cg_channel_persisted_default_channel(cg_engine *engine) {
    cg_channel_state state;
    cg_channel_default_channel_state(engine, &state);
    if (state.exists) {
        if (state.readable) return state.channel;
        cg_channel_state_clear(&state);
        if (!plugin_flag_persist_on_reinstall(engine)) return NULL;
    }
    cg_channel_state_clear(&state);
    return cg_plugin_kv_text(engine, CG_KEY_DEFAULT_CHANNEL);
}

/* Mirrors the key/value channel into the state file (falls back to the store when it cannot
 * be written). */
bool cg_channel_persist_default_channel_state_from_store(cg_engine *engine) {
    char *channel = cg_plugin_kv_text(engine, CG_KEY_DEFAULT_CHANNEL);
    cg_error err = CG_ERROR_INIT;
    bool written = write_default_channel_state(engine, channel, &err);
    free(channel);
    if (written) return true;
    char *path = no_backup_file(engine, CG_KEY_DEFAULT_CHANNEL_STATE_FILE);
    if (path && cg_fsutil_exists(path) && !remove_file(path)) {
        cg_warn(&engine->host, "Cannot persist or invalidate default channel state: %s", err.message);
        free(path);
        cg_err_clear(&err);
        return false;
    }
    free(path);
    cg_warn(&engine->host, "Cannot persist default channel state; falling back to stored preferences: %s",
            err.message);
    cg_err_clear(&err);
    return true;
}

static bool clear_persisted_default_channel(cg_engine *engine) {
    cg_error err = CG_ERROR_INIT;
    cg_channel_snapshot invalidated = {CG_CHANNEL_SNAPSHOT_INVALIDATED, NULL};
    if (!write_default_channel_state(engine, NULL, &err) ||
        !cg_channel_write_channel_snapshot(engine, &invalidated, &err)) {
        cg_warn(&engine->host, "Cannot persist cleared default channel state: %s", err.message);
        cg_err_clear(&err);
        return false;
    }
    cg_plugin_kv_write(engine, CG_KEY_DEFAULT_CHANNEL, NULL);
    cg_plugin_kv_write(engine, CG_KEY_PREVIEW_PREVIOUS_DEFAULT_CHANNEL, NULL);
    cg_plugin_kv_write(engine, CG_KEY_PREVIEW_PREVIOUS_DEFAULT_CHANNEL_WAS_SET, NULL);
    return true;
}

static char *install_marker(cg_engine *engine) { return no_backup_file(engine, CG_KEY_INSTALL_MARKER_FILE); }

static bool kv_flag_or(cg_engine *engine, const char *key, bool fallback) {
    bool value;
    return cg_plugin_kv_flag(engine, key, &value) ? value : fallback;
}

static void prepare_install_marker(cg_engine *engine) {
    char *marker = install_marker(engine);
    if (!marker) return;
    bool created = kv_flag_or(engine, CG_KEY_INSTALL_MARKER_CREATED, false);
    cg_error err = CG_ERROR_INIT;
    bool ok;
    if (cg_fsutil_exists(marker)) {
        cj_free(cg_plugin_hook(engine, CG_HOOK_EXCLUDE_FROM_BACKUP, cj_objv("path", cj_str(marker), NULL)));
        ok = true;
    } else {
        ok = write_no_backup_file(engine, marker, "", 0, &err);
    }
    if (ok) {
        if (!created) cg_plugin_kv_write_flag(engine, CG_KEY_INSTALL_MARKER_CREATED, true);
    } else {
        remove_file(marker);
        cg_plugin_kv_write_flag(engine, CG_KEY_INSTALL_MARKER_CREATED, false);
        cg_warn(&engine->host, "Cannot prepare default channel install marker: %s", err.message);
        cg_err_clear(&err);
    }
    free(marker);
}

static void set_config_default_channel(cg_engine *engine, const char *channel) {
    cg_engine_config *config = cg_engine_config_begin(engine);
    cg_replace(&config->default_channel, cg_strdup(channel));
    cg_engine_config_commit(engine, config);
}

static bool cleanup_must_retry(cg_engine *engine) {
    bool retry = cg_plugin_lock_state(engine)->default_channel_cleanup_must_retry;
    cg_plugin_unlock_state(engine);
    return retry;
}

/* Reinstall handling and default channel resolution at load. */
void cg_channel_prepare_default_channel(cg_engine *engine, bool native_build_changed) {
    const cg_host *host = &engine->host;
    cg_plugin_config config;
    cg_plugin_plugin_config(engine, &config);
    bool disabled = !config.persist_default_channel_on_reinstall;
    bool restored_reinstall = false;
    if (disabled && kv_flag_or(engine, CG_KEY_INSTALL_MARKER_CREATED, false)) {
        char *marker = install_marker(engine);
        restored_reinstall = marker && !cg_fsutil_exists(marker);
        free(marker);
    }
    bool marker_can_be_prepared = true;
    if (cg_policy_should_clear_persisted_default_channel(config.persist_default_channel_on_reinstall,
                                                         config.reset_when_update, native_build_changed,
                                                         restored_reinstall)) {
        if (clear_persisted_default_channel(engine)) {
            cg_host_log(host, CG_INFO, "Cleared persisted defaultChannel because reinstall persistence is disabled");
        } else {
            cg_host_log(host, CG_WARN, "Cannot durably clear persisted defaultChannel");
            cg_plugin_lock_state(engine)->default_channel_cleanup_must_retry = true;
            cg_plugin_unlock_state(engine);
            marker_can_be_prepared = false;
            char *marker = install_marker(engine);
            if (marker && cg_fsutil_exists(marker) && !remove_file(marker)) {
                char *detail = cg_io_message(errno);
                cg_warn(host, "Cannot invalidate default channel install marker for cleanup retry: %s", detail);
                free(detail);
            }
            free(marker);
        }
    }
    if (disabled && marker_can_be_prepared) prepare_install_marker(engine);
    bool retry = cleanup_must_retry(engine);
    bool in_preview = config.allow_preview && kv_flag_or(engine, CG_KEY_PREVIEW_SESSION, false);
    if (!in_preview && !retry && has_pending_channel_snapshot(engine))
        cg_channel_restore_preview_previous_default_channel(engine);

    cg_channel_state state;
    cg_channel_default_channel_state(engine, &state);
    char *channel;
    if (retry) {
        cg_host_log(host, CG_INFO, "Using configured defaultChannel until persisted cleanup can retry");
        channel = cg_strdup(config.default_channel);
    } else if (state.exists && state.readable) {
        cg_plugin_kv_write(engine, CG_KEY_DEFAULT_CHANNEL, state.channel);
        channel = cg_strdup(state.channel && *state.channel ? state.channel : config.default_channel);
    } else if (disabled && state.exists) {
        cg_host_log(host, CG_WARN,
                    "Ignoring unreadable persisted defaultChannel while reinstall persistence is disabled");
        channel = cg_strdup(config.default_channel);
    } else {
        char *stored = cg_plugin_kv_text(engine, CG_KEY_DEFAULT_CHANNEL);
        if (stored && *stored) {
            cg_host_log(host, CG_INFO, "Loaded persisted defaultChannel from setChannel()");
            channel = stored;
        } else {
            free(stored);
            channel = cg_strdup(config.default_channel);
        }
    }
    if (!retry && (!state.exists || (!disabled && !state.readable)))
        cg_channel_persist_default_channel_state_from_store(engine);
    set_config_default_channel(engine, channel);
    free(channel);
    cg_channel_state_clear(&state);
    cg_plugin_config_clear(&config);
}

/* Restores the channel saved when the preview session started. */
void cg_channel_restore_preview_previous_default_channel(cg_engine *engine) {
    const cg_host *host = &engine->host;
    if (cleanup_must_retry(engine)) return;
    cg_plugin_config config;
    cg_plugin_plugin_config(engine, &config);
    char *config_channel = cg_strdup(config.default_channel);
    cg_plugin_config_clear(&config);
    cg_channel_snapshot snapshot;
    cg_channel_channel_snapshot(engine, &snapshot);
    /* Option<Option<String>>: has_previous = Some, previous NULL = Some(None). */
    bool has_previous = false;
    char *previous = NULL;
    switch (snapshot.kind) {
    case CG_CHANNEL_SNAPSHOT_SNAPSHOT:
        has_previous = true;
        previous = snapshot.channel;
        snapshot.channel = NULL;
        break;
    case CG_CHANNEL_SNAPSHOT_INVALIDATED:
        has_previous = true;
        break;
    case CG_CHANNEL_SNAPSHOT_UNREADABLE:
        cg_host_log(host, CG_WARN, "Default channel preview restore will retry on next launch");
        free(config_channel);
        return;
    case CG_CHANNEL_SNAPSHOT_MISSING:
        /* Without a snapshot file, the key/value copy decides. */
        if (kv_flag_or(engine, CG_KEY_PREVIEW_PREVIOUS_DEFAULT_CHANNEL_WAS_SET, false)) {
            has_previous = true;
            previous = cg_plugin_kv_text(engine, CG_KEY_PREVIEW_PREVIOUS_DEFAULT_CHANNEL);
            if (!previous) previous = cg_strdup("");
        } else {
            char *was_set = cg_plugin_kv_text(engine, CG_KEY_PREVIEW_PREVIOUS_DEFAULT_CHANNEL_WAS_SET);
            has_previous = was_set != NULL;
            free(was_set);
        }
        break;
    }
    cg_channel_snapshot_clear(&snapshot);
    if (!has_previous) {
        free(config_channel);
        return;
    }
    cg_plugin_kv_write(engine, CG_KEY_DEFAULT_CHANNEL, previous);
    /* In use right away, even when the restore is not final yet (the previous iOS plugin). */
    set_config_default_channel(engine, previous && *previous ? previous : config_channel);
    free(previous);
    free(config_channel);
    if (!cg_channel_persist_default_channel_state_from_store(engine)) {
        cg_host_log(host, CG_WARN, "Default channel preview restore will retry on next launch");
        return;
    }
    /* Until the snapshot is invalidated the restore is not final: the next launch would apply
     * it again over a later setChannel. Retry then, like the previous iOS plugin. */
    cg_channel_snapshot invalidated = {CG_CHANNEL_SNAPSHOT_INVALIDATED, NULL};
    cg_error err = CG_ERROR_INIT;
    if (!cg_channel_write_channel_snapshot(engine, &invalidated, &err)) {
        cg_err_clear(&err);
        cg_channel_snapshot current;
        cg_channel_channel_snapshot(engine, &current);
        bool is_invalidated = current.kind == CG_CHANNEL_SNAPSHOT_INVALIDATED;
        cg_channel_snapshot_clear(&current);
        if (!is_invalidated) {
            cg_host_log(host, CG_WARN, "Default channel preview restore will retry on next launch");
            return;
        }
    }
    cg_plugin_kv_write(engine, CG_KEY_PREVIEW_PREVIOUS_DEFAULT_CHANNEL, NULL);
    cg_plugin_kv_write(engine, CG_KEY_PREVIEW_PREVIOUS_DEFAULT_CHANNEL_WAS_SET, NULL);
    cg_host_log(host, CG_INFO, "Restored defaultChannel after preview");
}

/* Saves the channel to restore when the preview ends. */
bool cg_channel_snapshot_default_channel_for_preview(cg_engine *engine) {
    char *channel = cg_channel_persisted_default_channel(engine);
    cg_channel_snapshot snapshot = {CG_CHANNEL_SNAPSHOT_SNAPSHOT, channel};
    cg_error err = CG_ERROR_INIT;
    if (!cg_channel_write_channel_snapshot(engine, &snapshot, &err)) {
        cg_error_log(&engine->host, "Could not durably save the default channel preview snapshot: %s", err.message);
        cg_err_clear(&err);
        free(channel);
        return false;
    }
    if (channel) {
        cg_plugin_kv_write(engine, CG_KEY_PREVIEW_PREVIOUS_DEFAULT_CHANNEL, channel);
        cg_plugin_kv_write_flag(engine, CG_KEY_PREVIEW_PREVIOUS_DEFAULT_CHANNEL_WAS_SET, true);
    } else {
        cg_plugin_kv_write(engine, CG_KEY_PREVIEW_PREVIOUS_DEFAULT_CHANNEL, NULL);
        cg_plugin_kv_write_flag(engine, CG_KEY_PREVIEW_PREVIOUS_DEFAULT_CHANNEL_WAS_SET, false);
    }
    free(channel);
    return true;
}

/* ---- channel methods */

static cj *channel_error(const cj *result, const char *code, cg_rejection *rejection) {
    const char *error = cj_get_str(result, "error");
    if (!error) error = "request_failed";
    const char *message = cj_get_str(result, "message");
    if (!message || !*message) message = error;
    return cg_rejection_coded(rejection, message, code, error);
}

/* The server call succeeded: a failed state-file write only affects the reinstall restore
 * (stored preferences still hold the channel), so it is logged, not rejected. */
static void persist_channel_state_after(cg_engine *engine, const char *method) {
    if (!cg_channel_persist_default_channel_state_from_store(engine))
        cg_error_log(&engine->host,
                     "%s: the default channel state file could not be updated; a reinstall may restore an older "
                     "channel",
                     method);
}

static void trigger_after_channel_change(cg_engine *engine, bool trigger) {
    if (trigger && cg_plugin_is_auto_update_enabled(engine)) {
        cg_host_log(&engine->host, CG_INFO, "Calling autoupdater after channel change!");
        cg_flow_background_download(engine);
    }
}

static bool arg_bool(const cj *args, const char *key) {
    bool value = false;
    return cj_as_bool(cj_get(args, key), &value) && value;
}

cj *cg_channel_method_set_channel(cg_engine *engine, const cj *args, cg_rejection *rejection) {
    const char *channel = cj_get_str(args, "channel");
    if (!channel) {
        cg_host_log(&engine->host, CG_ERROR, "setChannel called without channel");
        return cg_rejection_coded(rejection, "setChannel called without channel", "SETCHANNEL_INVALID_PARAMS",
                                  "missing_parameter");
    }
    cg_plugin_config config;
    cg_plugin_plugin_config(engine, &config);
    cj *result = cg_backend_set_channel(engine, channel, CG_KEY_DEFAULT_CHANNEL, config.allow_set_default_channel,
                                        config.default_channel);
    cg_plugin_config_clear(&config);
    if (cj_has(result, "error")) {
        channel_error(result, "SETCHANNEL_FAILED", rejection);
        const char *error = cg_or_empty(cj_get_str(result, "error"));
        if (cg_contains(error, "cannot_update_via_private_channel") || cg_contains(error, "channel_self_set_not_allowed")) {
            cj *payload = cj_objv("channel", cj_str(channel), "message", cj_str(rejection->message), NULL);
            cg_host_emit(&engine->host, "channelPrivate", payload);
            cj_free(payload);
        }
        cj_free(result);
        return NULL;
    }
    persist_channel_state_after(engine, "setChannel");
    trigger_after_channel_change(engine, arg_bool(args, "triggerAutoUpdate"));
    /* Every server field, plus the status / message the previous iOS plugin always set. */
    bool unset = false;
    unset = cj_as_bool(cj_get(result, "unset"), &unset) && unset;
    if (!cj_is_str(cj_get(result, "status"))) cj_set(result, "status", cj_str(unset ? "ok" : ""));
    if (!cj_is_str(cj_get(result, "message")))
        cj_set(result, "message",
               cj_str(unset ? "Public channel requested, channel override removed. Device will use public channel "
                              "automatically."
                            : ""));
    return result;
}

cj *cg_channel_method_unset_channel(cg_engine *engine, const cj *args, cg_rejection *rejection) {
    cg_plugin_config config;
    cg_plugin_plugin_config(engine, &config);
    cj *result = cg_backend_unset_channel(engine, CG_KEY_DEFAULT_CHANNEL, config.default_channel,
                                          config.allow_set_default_channel);
    cg_plugin_config_clear(&config);
    if (cj_has(result, "error")) {
        channel_error(result, "UNSETCHANNEL_FAILED", rejection);
        cj_free(result);
        return NULL;
    }
    persist_channel_state_after(engine, "unsetChannel");
    trigger_after_channel_change(engine, arg_bool(args, "triggerAutoUpdate"));
    return result;
}

cj *cg_channel_method_get_channel(cg_engine *engine, cg_rejection *rejection) {
    cj *result = cg_backend_get_channel(engine, CG_KEY_DEFAULT_CHANNEL);
    if (cj_has(result, "error")) {
        channel_error(result, "GETCHANNEL_FAILED", rejection);
        cj_free(result);
        return NULL;
    }
    persist_channel_state_after(engine, "getChannel");
    /* Every server field; allowSet defaults to true when the server omits it. */
    if (!cj_is_bool(cj_get(result, "allowSet"))) cj_set(result, "allowSet", cj_bool(true));
    return result;
}

cj *cg_channel_method_list_channels(cg_engine *engine, cg_rejection *rejection) {
    cj *result = cg_backend_list_channels(engine);
    if (cj_has(result, "error")) {
        channel_error(result, "LISTCHANNELS_FAILED", rejection);
        cj_free(result);
        return NULL;
    }
    return result;
}

/* ---- getLatest */

static void attach_bundle_size(cg_engine *engine, cj *latest) {
    const cj *manifest = cj_get(latest, "manifest");
    if (!cj_is_arr(manifest) || cj_len(manifest) == 0) return;
    const char *session_key = cg_or_empty(cj_get_str(latest, "sessionKey"));
    cj *missing = cg_manifest_missing_bundle_files(engine, manifest, session_key);
    const cj *missing_list = cj_get(missing, "missing");
    cj *missing_manifest = cj_is_arr(missing_list) ? cj_clone(missing_list) : cj_arr();
    char *version = cg_strdup(cj_get_str(latest, "version"));
    char *update_url = CG_CONFIG_DUP(engine, update_url);
    cj *size = cg_backend_bundle_download_size(engine, update_url, version, missing_manifest);
    free(update_url);
    free(version);
    cj_free(missing_manifest);
    cj_set(latest, "missing", missing);
    cj_set(latest, "downloadSize", size);
}

cj *cg_channel_method_get_latest(cg_engine *engine, const cj *args, cg_rejection *rejection) {
    const char *channel = cj_get_str(args, "channel");
    bool include_size = arg_bool(args, "includeBundleSize");
    char *app_id = cg_plugin_normalized_optional(cj_get_str(args, "appId"));
    if (app_id) {
        cg_plugin_config config;
        cg_plugin_plugin_config(engine, &config);
        bool allow_preview = config.allow_preview;
        cg_plugin_config_clear(&config);
        if (!allow_preview) {
            free(app_id);
            return cg_rejection_new(rejection, "getLatest preview override not allowed. Set allowPreview to true in "
                                               "your config to enable it.");
        }
    }
    cj *result = cg_backend_get_latest(engine, NULL, channel, app_id);
    free(app_id);
    char *version = cg_strdup(cg_or_empty(cj_get_str(result, "version")));
    if (cj_has(result, "error") || cj_has(result, "kind")) {
        const char *kind = cg_policy_normalized_update_response_kind(cj_get_str(result, "kind"));
        cj_set(result, "kind", cj_str(kind));
        cg_flow_notify_breaking_events_if_needed(engine, result, version);
        char *error = cg_strdup(cg_or_empty(cj_get_str(result, "error")));
        const char *message_value = cj_get_str(result, "message");
        char *message = cg_strdup(message_value ? message_value : "server did not provide a message");
        if (strcmp(kind, "failed") == 0) {
            cg_error_log(&engine->host, "getLatest failed with error: %s, message: %s", error, message);
            cg_rejection_new(rejection, *error ? error : message);
            free(error);
            free(message);
            free(version);
            cj_free(result);
            return NULL;
        }
        if (!*version) {
            cg_bundle_info current;
            cg_store_current_bundle(engine, &current);
            cj_set(result, "version", cj_str(cg_bundle_info_version_name(&current)));
            cg_bundle_info_clear(&current);
        }
        if (include_size) attach_bundle_size(engine, result);
        cg_info(&engine->host, "getLatest returned %s: %s", kind, message);
        free(error);
        free(message);
        free(version);
        return result;
    }
    const char *message = cj_get_str(result, "message");
    if (message) {
        char *copy = cg_strdup(message);
        cg_flow_notify_breaking_events_if_needed(engine, result, version);
        cg_rejection_new(rejection, copy);
        free(copy);
        free(version);
        cj_free(result);
        return NULL;
    }
    free(version);
    if (include_size) attach_bundle_size(engine, result);
    return result;
}

/* ---- shake menu */

static cj *menu_result(const char *status, char *message) {
    return cj_objv("status", cj_str(status), "message", cj_str_own(message), NULL);
}

static void progress(cg_engine *engine, char *message) {
    cj_free(cg_plugin_hook(engine, CG_HOOK_SHAKE_MENU_PROGRESS, cj_objv("message", cj_str_own(message), NULL)));
}

static const char *field(const cj *object, const char *key) { return cg_or_empty(cj_get_str(object, key)); }

/* Shake-menu channel switch: `setChannel`, `getLatest`, `download`, then `next`. Reports
 * progress through the `shakeMenuProgress` hook and answers what the menu shows:
 * `{ status: "error" | "success" | "updateReady", message, bundleId?, version? }`. The host
 * applies the bundle (`set`) only when the user chooses to reload. */
cj *cg_channel_shake_menu_switch_channel(cg_engine *engine, const char *channel) {
    cg_rejection rejection = CG_REJECTION_INIT;
    cj *args = cj_objv("channel", cj_str(channel), "triggerAutoUpdate", cj_bool(false), NULL);
    cj *set = cg_methods_run_plugin_method(engine, "setChannel", args, &rejection);
    cj_free(args);
    if (!set) {
        cj *out = menu_result("error", cg_fmt("Failed to set channel: %s", rejection.message));
        cg_rejection_clear(&rejection);
        return out;
    }
    cj_free(set);
    progress(engine, cg_strdup("Checking for updates..."));

    args = cj_objv("channel", cj_str(channel), NULL);
    cj *latest = cg_methods_run_plugin_method(engine, "getLatest", args, &rejection);
    cj_free(args);
    if (!latest) {
        cj *out = menu_result("error", cg_fmt("Channel set to %s. Update check failed: %s", channel, rejection.message));
        cg_rejection_clear(&rejection);
        return out;
    }
    if (!cj_is_obj(latest)) {
        cj_free(latest);
        return menu_result("success", cg_fmt("Channel set to %s. Could not check for updates.", channel));
    }
    const char *latest_error = field(latest, "error"), *kind = field(latest, "kind");
    const char *candidates[3] = {field(latest, "message"), latest_error, kind};
    const char *detail = "server did not provide a message";
    for (size_t i = 0; i < 3; i++) {
        if (*candidates[i]) {
            detail = candidates[i];
            break;
        }
    }
    cj *out = NULL;
    if (*latest_error && strcmp(kind, "up_to_date") != 0 && strcmp(kind, "blocked") != 0) {
        out = menu_result("error", cg_fmt("Channel set to %s. Update check failed: %s", channel, detail));
    } else if (strcmp(kind, "blocked") == 0) {
        out = menu_result("error", cg_fmt("Channel set to %s. Update check blocked: %s", channel, detail));
    }
    if (out) {
        cj_free(latest);
        return out;
    }

    const char *url = field(latest, "url");
    const cj *manifest = cj_get(latest, "manifest");
    if (!cj_is_arr(manifest) || cj_len(manifest) == 0) manifest = NULL;
    /* A manifest-only response legitimately has no URL (the files come from the manifest). */
    if (strcmp(kind, "up_to_date") == 0 || (!*url && !manifest)) {
        cj_free(latest);
        return menu_result("success", cg_fmt("Channel set to %s. Already on latest version.", channel));
    }
    char *version = cg_strdup(field(latest, "version"));
    if (!*version) {
        free(version);
        cj_free(latest);
        return menu_result("error", cg_fmt("Channel set to %s. Update check failed: missing version.", channel));
    }
    progress(engine, cg_fmt("Downloading update %s...", version));

    /* Manifest-only responses have no zip URL; the download tolerates this placeholder. */
    cj *request = cj_objv("url", cj_str(*url ? url : "https://404.capgo.app/no.zip"), "version", cj_str(version),
                          "sessionKey", cj_str(field(latest, "sessionKey")), "checksum",
                          cj_str(field(latest, "checksum")), NULL);
    if (manifest) cj_set(request, "manifest", cj_clone(manifest));
    cj_free(latest);
    cj *bundle = cg_methods_run_plugin_method(engine, "download", request, &rejection);
    cj_free(request);
    if (!bundle) {
        out = menu_result("error", cg_fmt("Failed to download update: %s", rejection.message));
        cg_rejection_clear(&rejection);
        free(version);
        return out;
    }
    char *bundle_id = cg_strdup(field(bundle, "id"));
    cj_free(bundle);
    if (!*bundle_id) {
        free(bundle_id);
        free(version);
        return menu_result("error", cg_strdup("Failed to download update: missing bundle"));
    }
    args = cj_objv("id", cj_str(bundle_id), NULL);
    cj *next = cg_methods_run_plugin_method(engine, "next", args, &rejection);
    cj_free(args);
    if (!next) {
        cg_warn(&engine->host, "Could not queue downloaded bundle: %s", rejection.message);
        cg_rejection_clear(&rejection);
    }
    cj_free(next);
    out = cj_objv("status", cj_str("updateReady"), "message",
                  cj_str_own(cg_fmt("Update downloaded! Reload to apply version %s?", version)), "bundleId",
                  cj_str_own(bundle_id), "version", cj_str_own(version), NULL);
    return out;
}
