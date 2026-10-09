/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/* Capgo backend client (Rust engine/backend.rs). */

#include "engine/backend.h"

#include <stdlib.h>
#include <string.h>

#include "bundle.h"
#include "engine/engine.h"
#include "engine/stats.h"
#include "engine/store.h"
#include "http.h"
#include "net_url.h"

/* ---------------------------------------------------------------- rate limit state */

/* Process-wide like the previous static fields: every engine (plugin, download workers)
 * honours the same Retry-After window. Leaf lock. */
static cg_mutex rate_limit_lock = CG_MUTEX_INIT;
static struct {
    int64_t blocked_until_ms;
    char *error;   /* NULL = "" */
    char *message; /* NULL = "" */
    bool statistic_sent;
} rate_limit;

void cg_remote_block_clear(cg_remote_block *block) {
    free(block->error);
    free(block->message);
    block->error = NULL;
    block->message = NULL;
    block->blocked = false;
}

/* error_map(error, message): takes ownership of message. */
static cj *error_map_own(const char *error, char *message) {
    return cj_objv("error", cj_str(error), "message", cj_str_own(message), NULL);
}

static cj *error_map(const char *error, const char *message) { return error_map_own(error, cg_strdup(message)); }

/* `value.as_str().map_or_else(|| value.to_string(), str::to_string)`. malloc'd. */
static char *value_text(const cj *value) {
    return cj_is_str(value) ? cg_strdup(cj_as_str(value)) : cj_print(value);
}

static char *current_version_name(cg_engine *engine) {
    cg_bundle_info current;
    cg_store_current_bundle(engine, &current);
    char *version = cg_strdup(cg_bundle_info_version_name(&current));
    cg_bundle_info_clear(&current);
    return version;
}

/* ---------------------------------------------------------------- info object */

cj *cg_backend_info_object(cg_engine *engine, const char *app_id_override) {
    cg_engine_config *config = cg_engine_config_snapshot(engine);
    cj *info = cj_obj();
    cj_set(info, "platform", cj_str(config->platform));
    cj_set(info, "device_id", cj_str(config->device_id));
    const char *app_id = config->app_id;
    if (app_id_override) {
        char *trimmed = cg_trim(app_id_override);
        if (*trimmed) app_id = app_id_override;
        free(trimmed);
    }
    cj_set(info, "app_id", cj_str(app_id));
    cj_set(info, "custom_id", cj_str(config->custom_id));
    cj_set(info, "version_build", cj_str(config->version_build));
    cj_set(info, "version_code", cj_str(config->version_code));
    cj_set(info, "version_os", cj_str(config->version_os));
    cj_set(info, "version_name", cj_str_own(current_version_name(engine)));
    cj_set(info, "plugin_version", cj_str(config->plugin_version));
    cj_set(info, "is_emulator", cj_bool(config->is_emulator));
    cj_set(info, "is_prod", cj_bool(config->is_prod));
    cj_set(info, "install_source", cj_str(config->install_source));
    cj_set(info, "defaultChannel", cj_str(config->default_channel));
    if (*config->key_id) cj_set(info, "key_id", cj_str(config->key_id));
    cg_config_release(config);
    return info;
}

/* ---------------------------------------------------------------- remote block */

bool cg_backend_is_remote_blocked(cg_engine *engine) {
    (void)engine;
    cg_lock(&rate_limit_lock);
    bool blocked = true;
    if (rate_limit.blocked_until_ms <= 0) {
        blocked = false;
    } else if (cg_now_ms() >= rate_limit.blocked_until_ms) {
        rate_limit.blocked_until_ms = 0;
        blocked = false;
    }
    cg_unlock(&rate_limit_lock);
    return blocked;
}

static cj *remote_blocked_error(void) {
    cg_lock(&rate_limit_lock);
    const char *error = cg_empty(rate_limit.error) ? "too_many_requests" : rate_limit.error;
    const char *message = cg_empty(rate_limit.message) ? "Too many requests" : rate_limit.message;
    cj *map = error_map(error, message);
    cg_unlock(&rate_limit_lock);
    return map;
}

static void release_statistic(void) {
    cg_lock(&rate_limit_lock);
    rate_limit.statistic_sent = false;
    cg_unlock(&rate_limit_lock);
}

typedef struct {
    char *stats_url;
    cj *event;
} rate_limit_statistic;

static void drop_rate_limit_statistic(void *ctx) {
    rate_limit_statistic *job = ctx;
    free(job->stats_url);
    cj_free(job->event);
    free(job);
}

static void run_rate_limit_statistic(cg_engine *engine, void *ctx) {
    rate_limit_statistic *job = ctx;
    cg_net_response response = {0};
    cg_net_error error = CG_NET_ERROR_INIT;
    if (cg_http_post_json(engine->http, job->stats_url, job->event, &response, &error)) {
        if (cg_net_response_is_success(&response)) {
            cg_host_log(&engine->host, CG_INFO, "Rate limit statistic sent");
        } else {
            release_statistic();
            cg_host_log(&engine->host, CG_ERROR, "Error sending rate limit statistic");
            cg_debug(&engine->host, "Response code: %u", (unsigned)response.status);
        }
        cg_net_response_clear(&response);
    } else {
        release_statistic();
        cg_host_log(&engine->host, CG_ERROR, "Failed to send rate limit statistic");
        cg_debug(&engine->host, "Error: %s", cg_or_empty(error.message));
        cg_net_error_clear(&error);
    }
}

static void send_rate_limit_statistic(cg_engine *engine) {
    char *stats_url = CG_CONFIG_DUP(engine, stats_url);
    if (!*stats_url) {
        free(stats_url);
        release_statistic();
        return;
    }
    cj *event = cg_backend_info_object(engine, NULL);
    cj_set(event, "version_name", cj_str_own(current_version_name(engine)));
    cj_set(event, "old_version_name", cj_str(""));
    cj_set(event, "action", cj_str("rate_limit_reached"));
    rate_limit_statistic *job = cg_malloc(sizeof *job);
    job->stats_url = stats_url;
    job->event = event;
    /* `weak_self().upgrade()` always succeeds here: the caller holds a strong reference. */
    cg_engine_spawn_strong(engine, "stats", run_rate_limit_statistic, job, drop_rate_limit_statistic);
}

void cg_backend_handle_rate_limit(cg_engine *engine, const cg_net_response *response, cg_remote_block *out) {
    if (response->status != 429) {
        out->blocked = false;
        out->error = cg_strdup("");
        out->message = cg_strdup("");
        return;
    }
    char *body = cg_net_response_text(response);
    char *error = NULL;
    char *message = NULL;
    cg_http_parse_remote_error(body, &error, &message);
    if (!*error) cg_replace(&error, cg_strdup("too_many_requests"));
    if (!*message) cg_replace(&message, cg_strdup("Too many requests"));
    int64_t now = cg_now_ms();
    int64_t until = cg_http_rate_limit_blocked_until_ms(cg_net_response_header(response, "Retry-After"), body, now);
    free(body);
    cg_lock(&rate_limit_lock);
    if (until > rate_limit.blocked_until_ms) {
        rate_limit.blocked_until_ms = until;
        cg_replace(&rate_limit.error, cg_strdup(error));
        cg_replace(&rate_limit.message, cg_strdup(message));
    } else if (rate_limit.blocked_until_ms <= 0) {
        cg_replace(&rate_limit.error, cg_strdup(error));
        cg_replace(&rate_limit.message, cg_strdup(message));
    }
    cg_engine_config *config = cg_engine_config_snapshot(engine);
    bool claim = strcmp(error, "too_many_requests") == 0 && !config->preview_session && *config->stats_url &&
                 !rate_limit.statistic_sent;
    cg_config_release(config);
    if (claim) rate_limit.statistic_sent = true;
    cg_unlock(&rate_limit_lock);
    if (claim) send_rate_limit_statistic(engine);
    int64_t retry_after = ((until > now ? until : now) - now + 999) / 1000;
    if (retry_after < 0) retry_after = 0;
    cg_warn(&engine->host, "Received 429 (%s). Honouring Retry-After: %llds.", error, (long long)retry_after);
    out->blocked = true;
    out->error = error;
    out->message = message;
}

/* ---------------------------------------------------------------- requests */

/* `object.get(key)` not null: as text (malloc'd), NULL otherwise. */
static char *field_text(const cj *object, const char *key) {
    const cj *value = cj_get(object, key);
    if (!value || cj_is_null(value)) return NULL;
    return value_text(value);
}

/* POSTs `body` and normalizes the reply like every previous plugin version: errors carry
 * `error`, `message`, `kind` and `statusCode`; success returns the JSON fields (with
 * `session_key` renamed `sessionKey`) plus `statusCode`. A JSON reply with `error` or `kind`
 * keeps every other server field too. */
static cj *json_request(cg_engine *engine, const char *url, const cj *body) {
    cg_net_response response = {0};
    cg_net_error net_error = CG_NET_ERROR_INIT;
    if (!cg_http_post_json(engine->http, url, body, &response, &net_error)) {
        cj *ret = error_map_own("network_error", cg_fmt("Request failed: %s", cg_or_empty(net_error.message)));
        cj_set(ret, "kind", cj_str("failed"));
        cg_net_error_clear(&net_error);
        return ret;
    }
    uint16_t status = response.status;
    cj *parsed = cg_net_response_json(&response);
    if (parsed && !cj_is_obj(parsed)) {
        cj_free(parsed);
        parsed = NULL;
    }
    cj *ret = NULL;
    if (parsed && (cj_has(parsed, "error") || cj_has(parsed, "kind"))) {
        ret = cj_obj();
        for (size_t i = 0; i < cj_len(parsed); i++) {
            const char *key = cj_key_at(parsed, i);
            const cj *value = cj_value_at(parsed, i);
            if (strcmp(key, "error") == 0 || strcmp(key, "kind") == 0 || strcmp(key, "message") == 0 ||
                strcmp(key, "version") == 0 || strcmp(key, "statusCode") == 0)
                continue;
            cj_set(ret, strcmp(key, "session_key") == 0 ? "sessionKey" : key, cj_clone(value));
        }
        if (status == 429) {
            cg_remote_block block;
            cg_backend_handle_rate_limit(engine, &response, &block);
            char *error = *block.error ? cg_strdup(block.error) : field_text(parsed, "error");
            cj_set(ret, "error", cj_str_own(error ? error : cg_strdup("too_many_requests")));
            char *message = *block.message ? cg_strdup(block.message) : field_text(parsed, "message");
            cj_set(ret, "message", cj_str_own(message ? message : cg_strdup("Too many requests")));
            char *kind = field_text(parsed, "kind");
            cj_set(ret, "kind", cj_str_own(kind ? kind : cg_strdup("failed")));
            cg_remote_block_clear(&block);
        } else {
            char *error = field_text(parsed, "error");
            if (error) cj_set(ret, "error", cj_str_own(error));
            char *kind = field_text(parsed, "kind");
            if (kind) cj_set(ret, "kind", cj_str_own(kind));
            char *message = field_text(parsed, "message");
            cj_set(ret, "message", cj_str_own(message ? message : cg_strdup("server did not provide a message")));
        }
        char *version = field_text(parsed, "version");
        if (version) cj_set(ret, "version", cj_str_own(version));
        cj_set(ret, "statusCode", cj_u64(status));
        cj_free(parsed);
        cg_net_response_clear(&response);
        return ret;
    }
    cg_remote_block block;
    cg_backend_handle_rate_limit(engine, &response, &block);
    if (block.blocked) {
        ret = error_map(block.error, block.message);
        cj_set(ret, "kind", cj_str("failed"));
        cj_set(ret, "statusCode", cj_u64(status));
    } else if (!cg_net_response_is_success(&response)) {
        /* Keep the server's explanation when the error body only carries a message. */
        const char *server_message = parsed ? cj_get_str(parsed, "message") : NULL;
        ret = server_message && *server_message ? error_map("response_error", server_message)
                                                : error_map_own("response_error", cg_fmt("Server error: %u", status));
        cj_set(ret, "kind", cj_str("failed"));
        cj_set(ret, "statusCode", cj_u64(status));
    } else if (!parsed) {
        ret = error_map("parse_error", "JSON parse error: Response is not a JSON object");
        cj_set(ret, "kind", cj_str("failed"));
    } else {
        ret = cj_obj();
        cj_set(ret, "statusCode", cj_u64(status));
        for (size_t i = 0; i < cj_len(parsed); i++) {
            const char *key = cj_key_at(parsed, i);
            cj_set(ret, strcmp(key, "session_key") == 0 ? "sessionKey" : key, cj_clone(cj_value_at(parsed, i)));
        }
    }
    cg_remote_block_clear(&block);
    cj_free(parsed);
    cg_net_response_clear(&response);
    return ret;
}

cj *cg_backend_get_latest(cg_engine *engine, const char *update_url, const char *channel,
                          const char *app_id_override) {
    if (cg_backend_is_remote_blocked(engine)) {
        cj *ret = remote_blocked_error();
        char *error = cj_print(cj_get(ret, "error"));
        cg_debug(&engine->host, "Skipping getLatest due to remote block (%s).", error);
        free(error);
        cj_set(ret, "kind", cj_str("failed"));
        return ret;
    }
    cj *info = cg_backend_info_object(engine, app_id_override);
    if (channel) cj_set(info, "defaultChannel", cj_str(channel));
    char *text = cj_print(info);
    cg_info(&engine->host, "Auto-update parameters: %s", text);
    free(text);
    char *url = update_url ? cg_strdup(update_url) : CG_CONFIG_DUP(engine, update_url);
    cj *ret = json_request(engine, url, info);
    free(url);
    cj_free(info);
    return ret;
}

/* NULL with *error_out (the error map) when no channel URL is set. */
static char *channel_url(cg_engine *engine, const char *missing_message, cj **error_out) {
    char *url = CG_CONFIG_DUP(engine, channel_url);
    if (!*url) {
        free(url);
        cg_host_log(&engine->host, CG_ERROR, "Channel URL is not set");
        *error_out = error_map("missing_config", missing_message);
        return NULL;
    }
    return url;
}

static void persist_default_channel(cg_engine *engine, const char *key, const char *channel) {
    if (key && *key) cg_host_kv_set(&engine->host, key, channel);
}

/* `self.config_mut().default_channel = channel`. */
static void set_default_channel(cg_engine *engine, const char *channel) {
    cg_engine_config *config = cg_engine_config_begin(engine);
    cg_replace(&config->default_channel, cg_strdup(channel));
    cg_engine_config_commit(engine, config);
}

cj *cg_backend_unset_channel(cg_engine *engine, const char *persist_key, const char *config_default_channel,
                             bool allow_set_default_channel) {
    if (!allow_set_default_channel) {
        cg_host_log(&engine->host, CG_ERROR, "unsetChannel is disabled by allowSetDefaultChannel config");
        return error_map("disabled_by_config", "unsetChannel is disabled by configuration");
    }
    persist_default_channel(engine, persist_key, NULL);
    set_default_channel(engine, config_default_channel);
    cg_info(&engine->host, "Persisted defaultChannel cleared, reverted to config value: %s", config_default_channel);
    return cj_objv("status", cj_str("ok"), "message", cj_str("Channel override removed"), NULL);
}

cj *cg_backend_set_channel(cg_engine *engine, const char *channel, const char *persist_key,
                           bool allow_set_default_channel, const char *config_default_channel) {
    if (!allow_set_default_channel) {
        cg_host_log(&engine->host, CG_ERROR, "setChannel is disabled by allowSetDefaultChannel config");
        return error_map("disabled_by_config", "setChannel is disabled by configuration");
    }
    if (cg_backend_is_remote_blocked(engine)) return remote_blocked_error();
    cj *error = NULL;
    char *url = channel_url(engine, "channelUrl missing", &error);
    if (!url) return error;
    cj *info = cg_backend_info_object(engine, NULL);
    cj_set(info, "channel", cj_str(channel));
    cj *res = json_request(engine, url, info);
    cj_free(info);
    free(url);
    if (cj_has(res, "error")) return res;
    bool unset = false;
    if (cj_as_bool(cj_get(res, "unset"), &unset) && unset) {
        persist_default_channel(engine, persist_key, NULL);
        set_default_channel(engine, config_default_channel);
        cg_host_log(&engine->host, CG_INFO, "Public channel requested, channel override removed");
    } else {
        set_default_channel(engine, channel);
        persist_default_channel(engine, persist_key, channel);
        cg_info(&engine->host, "defaultChannel persisted locally: %s", channel);
    }
    return res;
}

/* `body.get(key).and_then(as_str).filter(non-empty)` (borrowed). */
static const char *nonempty_str(const cj *body, const char *key) {
    const char *value = cj_is_obj(body) ? cj_get_str(body, key) : NULL;
    return value && *value ? value : NULL;
}

/* Non-2xx channel reply: the server's `error` / `message` when the body has them (like
 * `setChannel`), else `response_error` / `Server error: <status>`. */
static cj *channel_status_error(const cg_net_response *response) {
    cj *body = cg_net_response_json(response);
    const char *error = nonempty_str(body, "error");
    const char *message = nonempty_str(body, "message");
    cj *ret;
    if (error)
        ret = error_map(error, message ? message : "server did not provide a message");
    else
        ret = message ? error_map("response_error", message)
                      : error_map_own("response_error", cg_fmt("Server error: %u", (unsigned)response->status));
    cj_set(ret, "statusCode", cj_u64(response->status));
    cj_free(body);
    return ret;
}

cj *cg_backend_get_channel(cg_engine *engine, const char *persist_key) {
    if (cg_backend_is_remote_blocked(engine)) return remote_blocked_error();
    cj *error_out = NULL;
    char *url = channel_url(engine, "Channel URL is not set", &error_out);
    if (!url) return error_out;
    cj *info = cg_backend_info_object(engine, NULL);
    cg_net_response response = {0};
    cg_net_error net_error = CG_NET_ERROR_INIT;
    bool sent = cg_http_send_json(engine->http, "PUT", url, info, &response, &net_error);
    cj_free(info);
    free(url);
    if (!sent) {
        cj *ret = error_map_own("network_error", cg_fmt("Request failed: %s", cg_or_empty(net_error.message)));
        cg_net_error_clear(&net_error);
        return ret;
    }
    cj *ret = NULL;
    cg_remote_block block;
    cg_backend_handle_rate_limit(engine, &response, &block);
    if (block.blocked) {
        ret = error_map(block.error, block.message);
        cg_remote_block_clear(&block);
        cg_net_response_clear(&response);
        return ret;
    }
    cg_remote_block_clear(&block);
    char *body = cg_net_response_text(&response);
    char *default_channel = CG_CONFIG_DUP(engine, default_channel);
    cj *object = NULL;
    if (response.status == 400 && strstr(body, "channel_not_found") && *default_channel) {
        ret = cj_objv("channel", cj_str(default_channel), "status", cj_str("default"), NULL);
    } else if (!cg_net_response_is_success(&response)) {
        ret = channel_status_error(&response);
    } else if (!*body) {
        ret = error_map("no_response_body", "Empty response body");
    } else if (!cj_is_obj(object = cg_net_response_json(&response))) {
        ret = error_map("parse_error", "JSON parse error: Response is not a JSON object");
    } else if (cj_has(object, "error")) {
        const char *message = cj_get_str(object, "message");
        ret = cj_objv("error", cj_str_own(value_text(cj_get(object, "error"))), "message",
                      cj_str(message ? message : "server did not provide a message"), NULL);
    } else {
        const char *raw_channel = cj_get_str(object, "channel");
        if (raw_channel) {
            char *channel = cg_trim(raw_channel);
            if (*channel && strcmp(channel, CG_BUNDLE_ID_BUILTIN) != 0) {
                set_default_channel(engine, channel);
                persist_default_channel(engine, persist_key, channel);
                cg_info(&engine->host, "defaultChannel synchronized from getChannel(): %s", channel);
            }
            free(channel);
        }
        ret = object;
        object = NULL;
    }
    cj_free(object);
    free(default_channel);
    free(body);
    cg_net_response_clear(&response);
    return ret;
}

static void encode_query(cg_buf *out, const char *value) {
    for (const unsigned char *byte = (const unsigned char *)value; *byte; byte++) {
        unsigned char c = *byte;
        if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' || c == '_' ||
            c == '.' || c == '~')
            cg_buf_putc(out, (char)c);
        else
            cg_buf_printf(out, "%%%02X", c);
    }
}

/* The parsed channel array: `{channels: [...]}` or a parse error. */
static cj *parse_channel_list(cg_engine *engine, const cj *channels) {
    cj *list = cj_arr();
    for (size_t i = 0; i < cj_len(channels); i++) {
        const cj *object = cj_at(channels, i);
        if (!cj_is_obj(object)) {
            cj_free(list);
            return error_map("parse_error", "JSON parse error: channel is not an object");
        }
        const cj *id = cj_get(object, "id");
        if (!cj_is_number(id)) {
            cj_free(list);
            return error_map("parse_error", "JSON parse error: Channel id must be a number");
        }
        const char *name = cj_get_str(object, "name");
        bool public_flag = false, allow_self_set = false;
        cj_as_bool(cj_get(object, "public"), &public_flag);
        cj_as_bool(cj_get(object, "allow_self_set"), &allow_self_set);
        cj_push(list, cj_objv("id", cj_clone(id), "name", cj_str(name ? name : ""), "public", cj_bool(public_flag),
                              "allow_self_set", cj_bool(allow_self_set), NULL));
    }
    cg_host_log(&engine->host, CG_INFO, "Channels listed successfully");
    return cj_objv("channels", list, NULL);
}

cj *cg_backend_list_channels(cg_engine *engine) {
    if (cg_backend_is_remote_blocked(engine)) return remote_blocked_error();
    cj *error_out = NULL;
    char *url = channel_url(engine, "Channel URL is not set", &error_out);
    if (!url) return error_out;
    cj *info = cg_backend_info_object(engine, NULL);
    cg_buf request_url = {0};
    cg_buf_puts(&request_url, url);
    cg_buf_putc(&request_url, strchr(url, '?') ? '&' : '?');
    for (size_t i = 0; i < cj_len(info); i++) {
        if (i > 0) cg_buf_putc(&request_url, '&');
        encode_query(&request_url, cj_key_at(info, i));
        cg_buf_putc(&request_url, '=');
        char *value = value_text(cj_value_at(info, i));
        encode_query(&request_url, value);
        free(value);
    }
    cj_free(info);
    free(url);
    cg_net_response response = {0};
    cg_net_error net_error = CG_NET_ERROR_INIT;
    bool sent = cg_http_get(engine->http, request_url.data, &response, &net_error);
    cg_buf_free(&request_url);
    if (!sent) {
        cj *ret = error_map_own("network_error", cg_fmt("Request failed: %s", cg_or_empty(net_error.message)));
        cg_net_error_clear(&net_error);
        return ret;
    }
    cj *ret = NULL;
    cg_remote_block block;
    cg_backend_handle_rate_limit(engine, &response, &block);
    if (block.blocked) {
        ret = error_map(block.error, block.message);
    } else if (!cg_net_response_is_success(&response)) {
        ret = channel_status_error(&response);
    } else if (response.body_len == 0) {
        ret = error_map("no_response_body", "Empty response body");
    } else {
        cj *parsed = cg_net_response_json(&response);
        if (!parsed) {
            ret = error_map("parse_error", "JSON parse error: invalid JSON");
        } else if (cj_is_arr(parsed)) {
            ret = parse_channel_list(engine, parsed);
        } else if (cj_is_obj(parsed) && cj_has(parsed, "error")) {
            const char *message = cj_get_str(parsed, "message");
            ret = cj_objv("error", cj_clone(cj_get(parsed, "error")), "message",
                          cj_str(message ? message : "server did not provide a message"), NULL);
        } else {
            ret = error_map("parse_error", "Unexpected channels response format");
        }
        cj_free(parsed);
    }
    cg_remote_block_clear(&block);
    cg_net_response_clear(&response);
    return ret;
}

/* ---------------------------------------------------------------- bundle size */

static cj *unavailable_bundle_size(const cj *manifest, const char *error) {
    cj *files = cj_arr();
    size_t count = cj_len(manifest);
    for (size_t i = 0; i < count; i++) {
        const cj *entry = cj_at(manifest, i);
        cj *copy = cj_is_obj(entry) ? cj_clone(entry) : cj_obj();
        cj_set(copy, "error", cj_str(error));
        cj_push(files, copy);
    }
    return cj_objv("totalSize", cj_u64(0), "knownFiles", cj_u64(0), "unknownFiles", cj_u64(count), "files", files,
                   NULL);
}

cj *cg_backend_bundle_download_size(cg_engine *engine, const char *update_url, const char *version,
                                    const cj *manifest) {
    if (cj_len(manifest) == 0 || !cj_is_arr(manifest)) {
        return cj_objv("totalSize", cj_u64(0), "knownFiles", cj_u64(0), "unknownFiles", cj_u64(0), "files", cj_arr(),
                       NULL);
    }
    cj *info = cg_backend_info_object(engine, NULL);
    cj_set(info, "version", cj_str(cg_or_empty(version)));
    cj_set(info, "manifest", cj_clone(manifest));
    char *url = cg_backend_manifest_size_url(update_url);
    cg_net_response response = {0};
    cg_net_error net_error = CG_NET_ERROR_INIT;
    bool sent = cg_http_post_json(engine->http, url, info, &response, &net_error);
    free(url);
    cj_free(info);
    if (!sent) {
        cg_host_log(&engine->host, CG_ERROR, "Error getting bundle download size");
        cg_debug(&engine->host, "Error: %s", cg_or_empty(net_error.message));
        cg_net_error_clear(&net_error);
        return unavailable_bundle_size(manifest, "response_error");
    }
    cj *ret = NULL;
    if (cg_net_response_is_success(&response) && response.body_len > 0) {
        cj *parsed = cg_net_response_json(&response);
        if (cj_is_obj(parsed))
            ret = parsed;
        else
            cj_free(parsed);
    }
    cg_net_response_clear(&response);
    return ret ? ret : unavailable_bundle_size(manifest, "response_error");
}

/* ---------------------------------------------------------------- preview payloads */

#define MAX_PAYLOAD_BYTES (16u * 1024u * 1024u)

static bool collect_payload(void *context, const cg_net_stream *event, cg_net_error *err) {
    cg_buf *body = context;
    if (event->kind == CG_NET_STREAM_CHUNK) {
        if (body->len + event->len > MAX_PAYLOAD_BYTES)
            return cg_net_error_set(err, CG_NET_IO, "Preview payload is too large");
        cg_buf_put(body, event->data, event->len);
    }
    return true;
}

cj *cg_backend_fetch_json(cg_engine *engine, const char *url, cg_error *err) {
    cg_url parsed;
    if (cg_url_parse(url, NULL, &parsed) != CG_URL_OK) {
        cg_err_set(err, "invalid_url", "Expected an http or https URL");
        return NULL;
    }
    char *scheme = cg_url_scheme(&parsed);
    bool web = strcmp(scheme, "http") == 0 || strcmp(scheme, "https") == 0;
    free(scheme);
    cg_url_clear(&parsed);
    if (!web) {
        cg_err_set(err, "invalid_url", "Expected an http or https URL");
        return NULL;
    }
    cg_buf body = {0};
    cg_net_header headers[] = {{"Accept", "application/json"}};
    cg_net_stream_head head = {0};
    cg_net_error net_error = CG_NET_ERROR_INIT;
    if (!cg_http_download(engine->http, url, headers, 1, collect_payload, &body, &head, &net_error)) {
        cg_err_set(err, "network_error", "%s", cg_or_empty(net_error.message));
        cg_net_error_clear(&net_error);
        cg_buf_free(&body);
        return NULL;
    }
    uint16_t status = head.status;
    cg_net_stream_head_clear(&head);
    cj *json = cj_parsen(body.data ? body.data : "", body.len, NULL);
    cg_buf_free(&body);
    if (!(status >= 200 && status < 300)) {
        const cj *field = cj_is_obj(json) ? cj_get(json, "message") : NULL;
        if (!field && cj_is_obj(json)) field = cj_get(json, "error");
        const char *message = cj_is_str(field) ? cj_as_str(field) : NULL;
        if (message)
            cg_err_set(err, "response_error", "%s", message);
        else
            cg_err_set(err, "response_error", "Request failed with HTTP %u", (unsigned)status);
        cj_free(json);
        return NULL;
    }
    if (!cj_is_obj(json)) {
        cj_free(json);
        cg_err_set(err, "parse_error", "Response is not a JSON object");
        return NULL;
    }
    return json;
}

char *cg_backend_manifest_size_url(const char *update_url) {
    size_t len = strcspn(update_url, "?#");
    while (len && update_url[len - 1] == '/') len--;
    cg_buf url = {0};
    cg_buf_put(&url, update_url, len);
    cg_buf_puts(&url, "/manifest_size");
    return cg_buf_take(&url);
}
