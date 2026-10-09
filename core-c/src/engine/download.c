/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/* Zip bundle downloads and the shared download lifecycle (Rust engine/download.rs). */

#include "engine/download.h"

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdio.h>
#include <sys/stat.h>
#include <unistd.h>

#include "crypto/aes_cbc.h"
#include "crypto/checksum.h"
#include "crypto/crypto.h"
#include "engine/archive.h"
#include "engine/engine.h"
#include "engine/fsutil.h"
#include "engine/manifest.h"
#include "engine/plugin/telemetry.h"
#include "engine/scheduled.h"
#include "engine/stats.h"
#include "engine/store.h"
#include "http.h"

/* Minimum free space (x2 margin) required before any bundle download. */
#define MIN_FREE_BYTES (50ull * 1024 * 1024)
#define MAX_ZIP_ATTEMPTS 3u

/* ---------------------------------------------------------------- DownloadRequest */

void cg_download_request_init(cg_download_request *request) {
    memset(request, 0, sizeof *request);
    request->url = cg_strdup("");
    request->version = cg_strdup("");
    request->session_key = cg_strdup("");
    request->checksum = cg_strdup("");
}

/* JSON string member (with its NUL bytes), NULL when absent or not a string. */
static const cj *string_member(const cj *input, const char *key) {
    const cj *value = cj_get(input, key);
    return cj_is_str(value) ? value : NULL;
}

/* A string that is only compared or decoded (session key, checksum): a NUL byte becomes
 * 0x01, which every check rejects the way Rust rejects the NUL (no hex / base64 / hash
 * matches it), instead of a C view truncated at the NUL passing a gate. */
static char *gate_text(const cj *value) {
    if (!value) return cg_strdup("");
    char *text = cg_strndup(value->v.s.ptr, value->v.s.len);
    for (size_t i = 0; i < value->v.s.len; i++)
        if (text[i] == '\0') text[i] = '\x01';
    return text;
}

/* A URL: NUL bytes are percent-encoded (the Rust url parser escapes C0 controls). */
static char *url_text(const cj *value) {
    if (!value) return cg_strdup("");
    cg_buf buf = {0};
    for (size_t i = 0; i < value->v.s.len; i++) {
        if (value->v.s.ptr[i] == '\0') {
            cg_buf_puts(&buf, "%00");
        } else {
            cg_buf_putc(&buf, value->v.s.ptr[i]);
        }
    }
    return cg_buf_take(&buf);
}

static char *plain_text(const cj *value) { return cg_strdup(value ? cj_as_str(value) : ""); }

bool cg_download_request_from_json(const cj *input, cg_download_request *out, cg_error *err) {
    const cj *version = string_member(input, "version");
    if (!version || version->v.s.len == 0) return cg_err_invalid_input(err, "Download called without version");
    const cj *id = string_member(input, "id");
    /* The id names the bundle folder and its record: a truncated C view could address another
     * bundle (Rust fails on the NUL when it touches the file system). */
    if (id && cj_str_has_nul(id)) return cg_err_invalid_input(err, "Download called with an invalid id");
    memset(out, 0, sizeof *out);
    out->id = id && id->v.s.len > 0 ? cg_strdup(cj_as_str(id)) : NULL;
    out->url = url_text(string_member(input, "url"));
    out->version = plain_text(version);
    out->session_key = gate_text(string_member(input, "sessionKey"));
    out->checksum = gate_text(string_member(input, "checksum"));
    const cj *manifest = cj_get(input, "manifest");
    out->manifest = cj_is_arr(manifest) ? cj_clone(manifest) : NULL;
    const cj *link = string_member(input, "link");
    out->link = link ? cg_strdup(cj_as_str(link)) : NULL;
    const cj *comment = string_member(input, "comment");
    out->comment = comment ? cg_strdup(cj_as_str(comment)) : NULL;
    out->set_next = cj_get_bool(input, "setNext", false);
    out->direct_update = cj_get_bool(input, "directUpdate", false);
    out->emit_events = cj_get_bool(input, "emitEvents", true);
    return true;
}

static cj *opt_str(const char *value) { return value ? cj_str(value) : cj_null(); }

cj *cg_download_request_to_json(const cg_download_request *request) {
    return cj_objv("id", opt_str(request->id), "url", cj_str(request->url), "version", cj_str(request->version),
                   "sessionKey", cj_str(request->session_key), "checksum", cj_str(request->checksum), "manifest",
                   request->manifest ? cj_clone(request->manifest) : cj_null(), "link", opt_str(request->link),
                   "comment", opt_str(request->comment), "setNext", cj_bool(request->set_next), "directUpdate",
                   cj_bool(request->direct_update), "emitEvents", cj_bool(request->emit_events), NULL);
}

static char *dup_opt(const char *value) { return value ? cg_strdup(value) : NULL; }

void cg_download_request_copy(cg_download_request *out, const cg_download_request *request) {
    out->id = dup_opt(request->id);
    out->url = cg_strdup(cg_or_empty(request->url));
    out->version = cg_strdup(cg_or_empty(request->version));
    out->session_key = cg_strdup(cg_or_empty(request->session_key));
    out->checksum = cg_strdup(cg_or_empty(request->checksum));
    out->manifest = request->manifest ? cj_clone(request->manifest) : NULL;
    out->link = dup_opt(request->link);
    out->comment = dup_opt(request->comment);
    out->set_next = request->set_next;
    out->direct_update = request->direct_update;
    out->emit_events = request->emit_events;
}

void cg_download_request_clear(cg_download_request *request) {
    free(request->id);
    free(request->url);
    free(request->version);
    free(request->session_key);
    free(request->checksum);
    cj_free(request->manifest);
    free(request->link);
    free(request->comment);
    memset(request, 0, sizeof *request);
}

/* ---------------------------------------------------------------- error classification */

bool cg_download_is_retryable_download_error(const cg_error *error) {
    const char *code = error->code ? error->code : "";
    if (strcmp(code, "network_error") == 0 || strcmp(code, "timeout") == 0 ||
        strcmp(code, "incomplete_download") == 0)
        return true;
    if (strcmp(code, "http_error") == 0) {
        const char *message = cg_or_empty(error->message);
        if (!cg_starts_with(message, "HTTP error: ")) return false;
        char *status_text = cg_trim(message + strlen("HTTP error: "));
        int64_t status;
        bool retryable = cg_parse_i64(status_text, &status) && cg_http_is_retryable_http_status(status);
        free(status_text);
        return retryable;
    }
    return false;
}

bool cg_download_net_error_retryable(const cg_net_error *error) {
    switch (error->kind) {
    case CG_NET_INVALID_URL:
    case CG_NET_TLS:
    case CG_NET_INSECURE_REDIRECT:
    case CG_NET_IO: return false;
    default: return true;
    }
}

const char *cg_download_net_error_code(const cg_net_error *error) {
    switch (error->kind) {
    case CG_NET_INVALID_URL: return "invalid_url";
    case CG_NET_TLS: return "tls_error";
    case CG_NET_INSECURE_REDIRECT: return "blocked_redirect";
    case CG_NET_IO: return "io_error";
    default: return cg_net_error_is_timeout(error) ? "timeout" : "network_error";
    }
}

/* ---------------------------------------------------------------- lifecycle */

void cg_download_progress(cg_engine *engine, const char *id, int64_t percent) {
    cg_telemetry_notify_download(engine, id, percent < 0 ? 0 : percent > 100 ? 100 : percent);
}

bool cg_download_cancel_download(cg_engine *engine, const char *version) {
    cg_lock(&engine->downloads.lock);
    cg_download_entry *entry = cg_download_map_find(&engine->downloads, version);
    bool running = entry && entry->len > 0;
    if (running)
        for (size_t i = 0; i < entry->len; i++) cg_cancel_set(entry->tokens[i]);
    cg_unlock(&engine->downloads.lock);
    return running;
}

bool cg_download_is_downloading(cg_engine *engine, const char *version) {
    cg_lock(&engine->downloads.lock);
    cg_download_entry *entry = cg_download_map_find(&engine->downloads, version);
    bool running = entry && entry->len > 0;
    cg_unlock(&engine->downloads.lock);
    return running;
}

static void stat_version(cg_engine *engine, const char *action, const char *version) {
    cg_stats_send_stats(engine, action, version, NULL, NULL);
}

bool cg_download_require_session_key(cg_engine *engine, const char *session_key, const char *version,
                                     cg_error *err) {
    char *public_key = CG_CONFIG_DUP(engine, public_key);
    bool refused = *public_key && !cg_crypto_is_valid_session_key(session_key);
    free(public_key);
    if (refused) {
        cg_host_log(&engine->host, CG_ERROR, "Public key present but no valid session key provided");
        stat_version(engine, "session_key_required", version);
        return cg_err_set(err, "session_key_required", "Session key required when public key is present");
    }
    return true;
}

bool cg_download_require_checksum(cg_engine *engine, const char *checksum, const char *version, cg_error *err) {
    if (cg_empty(checksum)) {
        cg_host_log(&engine->host, CG_ERROR, "No checksum provided");
        stat_version(engine, "checksum_required", version);
        return cg_err_set(err, "checksum_required", "Checksum required");
    }
    return true;
}

bool cg_download_check_disk_space(cg_engine *engine, uint64_t needed, const char *version, cg_error *err) {
    char *root = CG_CONFIG_DUP(engine, storage_root);
    uint64_t free_bytes = 0;
    bool known = cg_fsutil_available_space(root, &free_bytes);
    free(root);
    uint64_t wanted = needed > UINT64_MAX / 2 ? UINT64_MAX : needed * 2;
    if (!known) {
        cg_host_log(&engine->host, CG_WARN, "Could not determine free disk space; continuing");
        return true;
    }
    if (free_bytes < wanted) {
        cg_error_log(&engine->host, "Insufficient disk space: %" PRIu64 " bytes free, %" PRIu64 " needed", free_bytes,
                     wanted);
        stat_version(engine, "insufficient_disk_space", version);
        return cg_err_set(err, "insufficient_disk_space", "Insufficient disk space for download");
    }
    return true;
}

/* Deletes a previous failed/deleted record for the same version before retrying. */
static bool clear_failed_version(cg_engine *engine, const char *version, cg_error *err) {
    cg_bundle_info existing;
    if (!cg_store_get_bundle_info_by_name(engine, version, &existing)) return true;
    bool ok = true;
    if (cg_bundle_info_is_error(&existing) || cg_bundle_info_is_deleted(&existing) ||
        cg_bundle_info_is_deleting(&existing)) {
        cg_info(&engine->host, "Found existing failed bundle for version %s, deleting before retry", version);
        if (!cg_store_delete_bundle(engine, existing.id, true, false))
            ok = cg_err_set(err, "delete_failed", "Failed to delete existing bundle before retry");
    }
    cg_bundle_info_clear(&existing);
    return ok;
}

void cg_download_start_record(cg_engine *engine, const cg_download_request *request, cg_bundle_info *out) {
    char *id = request->id ? cg_strdup(request->id) : cg_store_random_id();
    char *now = cg_bundle_iso8601_now();
    cg_bundle_info_init(out, id, request->version, CG_BUNDLE_DOWNLOADING, now, "");
    cg_bundle_info_set_link(out, request->link);
    cg_bundle_info_set_comment(out, request->comment);
    cg_store_save_bundle_info(engine, id, out);
    free(now);
    free(id);
}

void cg_download_fail_download(cg_engine *engine, const cg_bundle_info *record, const cg_error *error,
                               bool emit_events) {
    cg_error_log(&engine->host, "Download failed: %s", cg_or_empty(error->message));
    cg_bundle_info *failed = cg_bundle_info_with_status(record, CG_BUNDLE_ERROR);
    cg_store_save_bundle_info(engine, record->id, failed);
    cg_bundle_info_free(failed);
    cg_telemetry_forget_download_progress(engine, record->id);
    /* Callers that report failures themselves (plugin methods, the update cycle) send the event
     * and the stat once. */
    if (emit_events) {
        cj *payload = cj_objv("version", cj_str(cg_bundle_info_version_name(record)), "error",
                              cj_str(cg_or_empty(error->code)), NULL);
        cg_host_emit(&engine->host, "downloadFailed", payload);
        cj_free(payload);
        stat_version(engine, "download_fail", cg_bundle_info_version_name(record));
    }
}

void cg_download_finish_install(cg_engine *engine, const cg_bundle_info *record, const char *checksum,
                                const cg_download_request *request, cg_bundle_info *out) {
    char *now = cg_bundle_iso8601_now();
    cg_bundle_info_init(out, record->id, record->version, CG_BUNDLE_PENDING, now, checksum);
    free(now);
    cg_bundle_info_set_link(out, record->link);
    cg_bundle_info_set_comment(out, record->comment);
    cg_store_save_bundle_info(engine, record->id, out);
    cg_download_progress(engine, record->id, 100);
    if (request->emit_events) {
        cj *payload = cj_objv("bundle", cg_bundle_info_to_js(out), NULL);
        cg_host_emit(&engine->host, "updateAvailable", payload);
        cj_free(payload);
    }
    if (request->set_next) {
        if (CG_CONFIG_FLAG(engine, preview_session)) {
            cg_host_log(&engine->host, CG_INFO,
                        "Preview session is active, skipping automatic install of downloaded bundle");
        } else if (request->direct_update) {
            cj *payload = cj_objv("bundle", cg_bundle_info_to_raw(out), NULL);
            cg_host_emit(&engine->host, "directUpdateFinish", payload);
            cj_free(payload);
        } else {
            cg_store_set_next_bundle(engine, record->id);
        }
    }
}

bool cg_download_download_zip(cg_engine *engine, const cg_download_request *request, cg_bundle_info *out,
                              cg_error *err) {
    if (!cg_download_require_session_key(engine, request->session_key, request->version, err)) return false;
    if (!cg_download_require_checksum(engine, request->checksum, request->version, err)) return false;
    char *blocked = cg_host_before_download(&engine->host);
    if (blocked) return cg_err_set_own(err, "download_blocked", blocked);
    if (!clear_failed_version(engine, request->version, err)) return false;
    cg_bundle_info record;
    cg_download_start_record(engine, request, &record);
    cg_download_progress(engine, record.id, 0);
    cg_download_progress(engine, record.id, 5);
    bool ok = cg_download_run_download(engine, request, &record, out, err);
    cg_bundle_info_clear(&record);
    return ok;
}

bool cg_download_run_download(cg_engine *engine, const cg_download_request *request, const cg_bundle_info *record,
                              cg_bundle_info *out, cg_error *err) {
    cg_cancel *cancel = cg_manifest_register_download_token(engine, request->version);
    cg_scheduled scheduled;
    memset(&scheduled, 0, sizeof scheduled);
    bool ok;
    if (cg_scheduled_schedule_download(engine, request, record, cancel, &scheduled)) {
        ok = cg_scheduled_scheduled_result(engine, request, record, &scheduled, out, err);
    } else {
        cg_error local = CG_ERROR_INIT;
        ok = cg_download_transfer_and_install(engine, request, record, cancel, false, out, &local);
        ok = cg_download_settle_download(engine, request, record, ok, out, &local);
        if (!ok) {
            if (err) {
                cg_err_move(err, &local);
            } else {
                cg_err_clear(&local);
            }
        }
    }
    cg_manifest_unregister_download_token(engine, request->version, cancel);
    cg_cancel_release(cancel);
    return ok;
}

static bool download_zip_inner(cg_engine *engine, const cg_download_request *request, const cg_bundle_info *record,
                               const cg_cancel *cancel, bool resumable, cg_bundle_info *out, cg_error *err);

bool cg_download_transfer_and_install(cg_engine *engine, const cg_download_request *request,
                                      const cg_bundle_info *record, const cg_cancel *cancel, bool resumable,
                                      cg_bundle_info *out, cg_error *err) {
    if (request->manifest)
        return cg_manifest_download_manifest_inner(engine, request, request->manifest, record, cancel, out, err);
    return download_zip_inner(engine, request, record, cancel, resumable, out, err);
}

bool cg_download_settle_download(cg_engine *engine, const cg_download_request *request, const cg_bundle_info *record,
                                 bool ok, cg_bundle_info *result, cg_error *err) {
    if (ok) return true;
    if (request->manifest) {
        cg_error ignored = CG_ERROR_INIT;
        char *dir = cg_store_bundle_directory(engine, record->id, &ignored);
        if (dir) cg_store_remove_path(dir, &ignored);
        cg_err_clear(&ignored);
        free(dir);
    }
    cg_error none = CG_ERROR_INIT;
    cg_download_fail_download(engine, record, err ? err : &none, request->emit_events);
    return false;
}

/* ---------------------------------------------------------------- zip transfer */

static void remove_files(const char *const *paths, size_t count) {
    for (size_t i = 0; i < count; i++) unlink(paths[i]);
}

/* Rust `f64 as i64` (saturating, NaN = 0). */
static int64_t f64_to_i64(double value) {
    if (value != value) return 0;
    if (value >= 9223372036854775807.0) return INT64_MAX;
    if (value <= -9223372036854775808.0) return INT64_MIN;
    return (int64_t)value;
}

typedef struct {
    cg_engine *engine;
    const char *id;
    const char *temp;
    const cg_cancel *cancel;
    const cg_stream_sink *sink;
    uint64_t existing;
    cg_block_writer *file;
    uint64_t written;
    bool has_expected_total;
    uint64_t expected_total;
    uint64_t offset;
    int64_t last_percent;
    uint16_t plan_status;
    char *content_range;
    bool has_body_len;
    uint64_t body_len;
} zip_transfer;

static bool stopped(cg_net_error *err) { return cg_net_error_set(err, CG_NET_IO, "download_stopped"); }

static bool zip_head(zip_transfer *t, const cg_net_stream_head *head, cg_net_error *err) {
    if (!(head->status == 200 || head->status == 206))
        return cg_net_error_set(err, CG_NET_NETWORK, "HTTP error: %u", (unsigned)head->status);
    const char *content_range = cg_net_stream_head_header(head, "Content-Range");
    cg_zip_write_plan plan;
    const char *code = NULL;
    if (!cg_http_plan_zip_resume_write(head->status, (int64_t)t->existing, content_range, &plan, &code))
        return cg_net_error_set(err, CG_NET_NETWORK, "%s", code ? code : "");
    t->plan_status = (uint16_t)plan.response_code;
    t->offset = (uint64_t)plan.write_offset;
    cg_replace(&t->content_range, content_range ? cg_strdup(content_range) : NULL);
    t->has_body_len = head->has_content_length;
    t->body_len = head->content_length;
    bool append = cg_http_should_append_http_body(plan.response_code, (int64_t)t->existing);
    t->has_expected_total = head->has_content_length;
    t->expected_total = append ? head->content_length + t->offset : head->content_length;
    uint64_t free_bytes;
    if (t->has_expected_total && cg_fsutil_available_space(t->temp, &free_bytes)) {
        uint64_t wanted = t->expected_total > UINT64_MAX / 2 ? UINT64_MAX : t->expected_total * 2;
        if (free_bytes < wanted) return cg_net_error_set(err, CG_NET_IO, "insufficient_disk_space");
    }
    int fd = cg_fsutil_open(t->temp, O_CREAT | O_WRONLY | (append ? O_APPEND : O_TRUNC), 0666);
    if (fd < 0) return cg_net_error_set_own(err, CG_NET_IO, cg_io_message(errno));
    t->written = append ? t->existing : 0;
    /* A resumed body only covers the tail: no streamed result. */
    cg_stream_sink none = {.kind = CG_SINK_NONE};
    if (t->file) cg_block_writer_free(t->file);
    t->file = cg_block_writer_new(fd, append ? &none : t->sink);
    return true;
}

static bool zip_chunk(zip_transfer *t, const uint8_t *data, size_t len, cg_net_error *err) {
    if (cg_cancel_is_cancelled(t->cancel)) return stopped(err);
    if (!t->file) return stopped(err);
    cg_error write_error = CG_ERROR_INIT;
    if (!cg_block_writer_write(t->file, data, len, &write_error)) {
        cg_net_error_set(err, CG_NET_IO, "%s", cg_or_empty(write_error.message));
        cg_err_clear(&write_error);
        return false;
    }
    t->written += len;
    if (t->has_expected_total && t->expected_total > 0) {
        int64_t percent = f64_to_i64(((double)t->written / (double)t->expected_total) * 100.0);
        percent = percent < 10 ? 10 : percent > 70 ? 70 : percent;
        if (percent >= t->last_percent + 10) {
            t->last_percent = (percent / 10) * 10;
            cg_download_progress(t->engine, t->id, t->last_percent);
        }
    }
    return true;
}

static bool zip_handler(void *context, const cg_net_stream *event, cg_net_error *err) {
    zip_transfer *t = context;
    if (event->kind == CG_NET_STREAM_HEAD) return zip_head(t, event->head, err);
    return zip_chunk(t, event->data, event->len, err);
}

static uint64_t file_len(const char *path) {
    struct stat st;
    return stat(path, &st) == 0 ? (uint64_t)st.st_size : 0;
}

/* One GET attempt. true with *hash (NULL = None); false with *err and *retryable. */
static bool transfer_zip_once(cg_engine *engine, const char *url, const char *version, const char *id,
                              const char *temp, const cg_cancel *cancel, const cg_stream_sink *sink, char **hash,
                              bool *retryable, cg_error *err) {
    *hash = NULL;
    zip_transfer t = {.engine = engine, .id = id, .temp = temp, .cancel = cancel, .sink = sink};
    t.existing = file_len(temp);
    char range[48];
    snprintf(range, sizeof range, "bytes=%" PRIu64 "-", t.existing);
    cg_net_header headers[1] = {{"Range", range}};
    cg_net_error net = CG_NET_ERROR_INIT;
    bool ok = cg_http_download(engine->http, url, headers, t.existing > 0 ? 1 : 0, zip_handler, &t, NULL, &net);
    char *streamed_hash = NULL;
    if (t.file) {
        cg_error io = CG_ERROR_INIT;
        if (!cg_block_writer_finish(t.file, &streamed_hash, &io)) {
            cg_err_set(err, "io_error", "Cannot write download: %s", cg_or_empty(io.message));
            cg_err_clear(&io);
            cg_net_error_clear(&net);
            free(t.content_range);
            *retryable = true;
            return false;
        }
    }
    if (!ok) {
        free(streamed_hash);
        free(t.content_range);
        const char *message = cg_or_empty(net.message);
        if (strcmp(message, "insufficient_disk_space") == 0) {
            stat_version(engine, "insufficient_disk_space", version);
            cg_err_set(err, "insufficient_disk_space", "Insufficient disk space for download");
            *retryable = false;
        } else if (strcmp(message, "download_stopped") == 0) {
            cg_err_set(err, "download_stopped", "Download cancelled");
            *retryable = false;
        } else {
            int64_t status;
            if (cg_starts_with(message, "HTTP error: ") && cg_parse_i64(message + strlen("HTTP error: "), &status)) {
                *retryable = cg_http_is_retryable_http_status(status);
            } else {
                *retryable = cg_download_net_error_retryable(&net);
            }
            const char *code = cg_starts_with(message, "HTTP error") ? "http_error" : cg_download_net_error_code(&net);
            cg_err_set(err, code, "%s", message);
        }
        cg_net_error_clear(&net);
        return false;
    }
    /* Completeness checks (resume safety). */
    uint64_t length = file_len(temp);
    const char *incomplete = NULL;
    if (t.plan_status == 206) {
        cg_content_range range_value;
        if (cg_http_parse_content_range(t.content_range, &range_value) && range_value.total >= 0) {
            if ((uint64_t)range_value.start != t.offset) {
                incomplete = "content_range_mismatch";
            } else if (length - t.offset != (uint64_t)(range_value.end - range_value.start + 1)) {
                incomplete = "incomplete_content_range";
            } else if (length != (uint64_t)range_value.total) {
                incomplete = "incomplete_download";
            }
        } else {
            incomplete = "unknown_content_range_total";
        }
    } else if (t.has_body_len && length != t.body_len) {
        incomplete = "incomplete_download";
    }
    free(t.content_range);
    if (incomplete) {
        free(streamed_hash);
        cg_err_set(err, "incomplete_download", "%s", incomplete);
        *retryable = true;
        return false;
    }
    *hash = streamed_hash;
    return true;
}

/* GET with resume and up to `attempts` tries into `temp`. */
static bool transfer_zip(cg_engine *engine, const char *url, const char *version, const char *id, const char *temp,
                         const char *info, const cg_cancel *cancel, const cg_stream_sink *sink, unsigned attempts,
                         bool resume, char **hash, cg_error *err) {
    bool resumable = false;
    if (resume && cg_fsutil_exists(temp)) {
        size_t len = 0;
        char *saved = NULL;
        FILE *file = fopen(info, "rb");
        if (file) {
            cg_buf buf = {0};
            char chunk[256];
            size_t read;
            while ((read = fread(chunk, 1, sizeof chunk, file)) > 0) cg_buf_put(&buf, chunk, read);
            bool failed = ferror(file);
            fclose(file);
            len = buf.len;
            saved = cg_buf_take(&buf);
            /* fs::read_to_string: invalid UTF-8 is an error. */
            if (failed || !cg_utf8_valid(saved, len)) {
                free(saved);
                saved = NULL;
            }
        }
        resumable = saved && len == strlen(version) && memcmp(saved, version, len) == 0;
        free(saved);
    }
    if (!resumable) {
        int fd = cg_fsutil_open(info, O_CREAT | O_WRONLY | O_TRUNC, 0666);
        if (fd >= 0) {
            cg_fsutil_write_all(fd, version, strlen(version));
            close(fd);
        }
        unlink(temp);
    }
    unsigned attempt = 0;
    bool restarted = false;
    for (;;) {
        attempt++;
        bool retryable = false;
        cg_error error = CG_ERROR_INIT;
        if (transfer_zip_once(engine, url, version, id, temp, cancel, sink, hash, &retryable, &error)) return true;
        /* The resumed partial already holds the whole body (the previous attempt ended before it
         * was verified): start over once. */
        if (resumable && !restarted && cg_eq(error.message, "HTTP error: 416")) {
            restarted = true;
            attempt--;
            unlink(temp);
            cg_err_clear(&error);
            continue;
        }
        if (!retryable || attempt >= attempts || cg_cancel_is_cancelled(cancel)) {
            if (err) {
                cg_err_move(err, &error);
            } else {
                cg_err_clear(&error);
            }
            return false;
        }
        cg_warn(&engine->host, "Download attempt %u failed (%s), retrying", attempt, cg_or_empty(error.message));
        cg_err_clear(&error);
        cg_sleep_ms(500 * (int64_t)attempt);
    }
}

/* Decrypts (when encrypted) and checks the zip against the expected checksum before anything is
 * extracted. Returns the SHA-256 of the plain zip (malloc'd), NULL with *err. Takes ownership of
 * streamed_hash. */
static char *verify_zip(cg_engine *engine, const char *zip, const cg_download_request *request, char *streamed_hash,
                        bool encrypted, cg_error *err) {
    char *public_key = CG_CONFIG_DUP(engine, public_key);
    char *expected = cg_strdup(request->checksum);
    char *plain_hash = streamed_hash;
    char *actual = NULL;
    if (encrypted && plain_hash) {
        char *decrypted = cg_crypto_decrypt_checksum(request->checksum, public_key, err);
        if (!decrypted) goto fail;
        cg_replace(&expected, decrypted);
    } else if (cg_crypto_is_valid_session_key(request->session_key)) {
        cg_session_key session;
        bool has_key = false;
        cg_error error = CG_ERROR_INIT;
        bool ok = cg_crypto_bundle_session_key(public_key, request->session_key, &session, &has_key, &error);
        free(plain_hash);
        plain_hash = NULL;
        if (ok && has_key) {
            plain_hash = cg_aes_cbc_decrypt_file_in_place_hashed(zip, session.key, session.iv, &error);
            ok = plain_hash != NULL;
        }
        if (!ok) {
            /* The checksum covers the decrypted zip. */
            stat_version(engine, "decrypt_fail", request->version);
            cg_err_set(err, "decrypt_fail", "AES file decryption failed: %s", cg_or_empty(error.message));
            cg_err_clear(&error);
            goto fail;
        }
        char *decrypted = cg_crypto_decrypt_checksum(request->checksum, public_key, err);
        if (!decrypted) goto fail;
        cg_replace(&expected, decrypted);
    } else if (*public_key) {
        char *decrypted = cg_crypto_decrypt_checksum(request->checksum, public_key, err);
        if (!decrypted) goto fail;
        cg_replace(&expected, decrypted);
    }
    if (plain_hash) {
        actual = plain_hash;
        plain_hash = NULL;
    } else {
        actual = cg_checksum_sha256_file(zip, err);
        if (!actual) goto fail;
    }
    /* Exact match, as both native implementations compared the zip checksum. */
    if (strcmp(expected, actual) != 0) {
        cg_host_log(&engine->host, CG_ERROR, "Checksum mismatch");
        cg_debug(&engine->host, "Expected: %s, Got: %s", expected, actual);
        stat_version(engine, "checksum_fail", request->version);
        cg_err_set(err, "checksum_fail", "Checksum failed: expected %s, got %s", expected, actual);
        free(actual);
        actual = NULL;
        goto fail;
    }
    free(expected);
    free(public_key);
    return actual;
fail:
    free(plain_hash);
    free(expected);
    free(public_key);
    return NULL;
}

typedef struct {
    cg_engine *engine;
    const char *id;
    int64_t last;
    const cg_cancel *cancel;
} extract_ctx;

static void extract_progress(void *context, size_t done, size_t total) {
    extract_ctx *ctx = context;
    int64_t percent = 75 + (int64_t)(done * 15 / (total > 1 ? total : 1));
    if (percent != ctx->last) {
        ctx->last = percent;
        cg_download_progress(ctx->engine, ctx->id, percent);
    }
}

static bool extract_cancelled(void *context) { return cg_cancel_is_cancelled(((extract_ctx *)context)->cancel); }

static void delta_cache_run(cg_engine *engine, void *ctx) { cg_download_populate_delta_cache(engine, ctx); }

/* Everything after a successful zip transfer: decrypted-file move, verification, extraction and
 * install. Takes ownership of streamed_hash. */
static bool finish_zip_download(cg_engine *engine, const cg_download_request *request, const cg_bundle_info *record,
                                const char *temp, const char *plain, char *streamed_hash, bool encrypted,
                                const cg_cancel *cancel, cg_bundle_info *out, cg_error *err) {
    const char *id = record->id;
    /* Decrypted while downloading: the plaintext replaces the ciphertext. */
    if (streamed_hash && encrypted) {
        if (rename(plain, temp) != 0) {
            const char *paths[] = {temp, plain};
            remove_files(paths, 2);
            free(streamed_hash);
            return cg_err_set(err, "unzip_fail", "Cannot move the decrypted bundle");
        }
    } else {
        unlink(plain);
    }
    stat_version(engine, "download_zip_complete", request->version);
    cg_download_progress(engine, id, 71);

    char *checksum = verify_zip(engine, temp, request, streamed_hash, encrypted, err);
    if (!checksum) {
        unlink(temp);
        return false;
    }

    char *storage = CG_CONFIG_DUP(engine, storage_root);
    char *random = cg_store_random_id();
    char *name = cg_fmt("%s%s", CG_TEMP_UNZIP_PREFIX, random);
    char *extract_dir = cg_fsutil_join(storage, name);
    free(name);
    free(random);
    free(storage);
    cg_download_progress(engine, id, 75);
    extract_ctx ctx = {.engine = engine, .id = id, .last = 75, .cancel = cancel};
    cg_extract_error extract_error = CG_EXTRACT_ERROR_INIT;
    bool extracted =
        cg_archive_extract_zip(temp, extract_dir, extract_progress, extract_cancelled, &ctx, &extract_error);
    unlink(temp);
    cg_error ignored = CG_ERROR_INIT;
    if (!extracted) {
        cg_store_remove_path(extract_dir, &ignored);
        cg_err_clear(&ignored);
        const char *stat = cg_extract_error_stat(&extract_error);
        if (stat) stat_version(engine, stat, request->version);
        bool cancelled = extract_error.kind == CG_EXTRACT_CANCELLED;
        if (!cancelled) stat_version(engine, "unzip_fail", request->version);
        cg_err_set_own(err, cancelled ? "download_stopped" : "unzip_fail",
                       cg_extract_error_message(&extract_error, NULL));
        cg_extract_error_clear(&extract_error);
        free(extract_dir);
        free(checksum);
        return false;
    }
    char *bundle_dir = cg_store_bundle_directory(engine, id, err);
    if (!bundle_dir) {
        free(extract_dir);
        free(checksum);
        return false;
    }
    if (!cg_archive_install_extracted(extract_dir, bundle_dir, err)) {
        cg_store_remove_path(extract_dir, &ignored);
        cg_err_clear(&ignored);
        cg_store_remove_path(bundle_dir, &ignored);
        cg_err_clear(&ignored);
        free(extract_dir);
        free(bundle_dir);
        free(checksum);
        return false;
    }
    free(extract_dir);
    free(bundle_dir);
    cg_download_progress(engine, id, 91);
    cg_download_finish_install(engine, record, checksum, request, out);
    free(checksum);
    /* Rust: `if let Some(engine) = self.weak_self().upgrade()`: the caller holds a reference. */
    cg_engine_spawn_strong(engine, "delta-cache", delta_cache_run, cg_strdup(id), free);
    return true;
}

static bool download_zip_inner(cg_engine *engine, const cg_download_request *request, const cg_bundle_info *record,
                               const cg_cancel *cancel, bool resumable, cg_bundle_info *out, cg_error *err) {
    const char *id = record->id;
    if (!cg_download_check_disk_space(engine, MIN_FREE_BYTES, request->version, err)) return false;
    stat_version(engine, "download_zip_start", request->version);
    char *storage = CG_CONFIG_DUP(engine, storage_root);
    cg_error io = CG_ERROR_INIT;
    if (!cg_fsutil_create_dir_all_err(storage, &io)) {
        cg_err_set(err, "io_error", "Cannot create updater storage: %s", cg_or_empty(io.message));
        cg_err_clear(&io);
        free(storage);
        return false;
    }
    char *name = cg_fmt("temp_%s.tmp", id);
    char *temp = cg_fsutil_join(storage, name);
    free(name);
    name = cg_fmt("update_%s.dat", id);
    char *info = cg_fsutil_join(storage, name);
    free(name);
    /* Plain zips are hashed while they download; encrypted ones are decrypted (and the plaintext
     * hashed) while they download. Resumed transfers fall back to a pass over the file. */
    name = cg_fmt("temp_%s.plain", id);
    char *plain = cg_fsutil_join(storage, name);
    free(name);
    free(storage);
    bool encrypted = cg_crypto_is_valid_session_key(request->session_key);
    cg_stream_sink sink = {.kind = CG_SINK_HASH};
    if (encrypted) {
        char *public_key = CG_CONFIG_DUP(engine, public_key);
        cg_session_key session;
        bool has_key = false;
        cg_error ignored = CG_ERROR_INIT;
        if (cg_crypto_bundle_session_key(public_key, request->session_key, &session, &has_key, &ignored) &&
            has_key) {
            sink.kind = CG_SINK_DECRYPT;
            memcpy(sink.key, session.key, sizeof sink.key);
            memcpy(sink.iv, session.iv, sizeof sink.iv);
            sink.plain = plain;
        } else {
            sink.kind = CG_SINK_NONE;
        }
        cg_err_clear(&ignored);
        free(public_key);
    }
    unsigned attempts = resumable ? 1 : MAX_ZIP_ATTEMPTS;
    char *streamed_hash = NULL;
    cg_error error = CG_ERROR_INIT;
    bool ok = false;
    if (transfer_zip(engine, request->url, request->version, id, temp, info, cancel, &sink, attempts, resumable,
                     &streamed_hash, &error)) {
        unlink(info);
        ok = finish_zip_download(engine, request, record, temp, plain, streamed_hash, encrypted, cancel, out,
                                 &error);
        /* The transfer succeeded but the bundle could not be finalized (decrypt, checksum, unzip,
         * move or install). */
        if (!ok && !cg_err_is(&error, "download_stopped"))
            stat_version(engine, "finish_download_fail", request->version);
    } else {
        /* A scheduled job keeps a consistent partial file: its next attempt resumes it. */
        bool inconsistent = cg_err_is(&error, "incomplete_download") || cg_eq(error.message, "invalid_content_range");
        if (resumable && !inconsistent &&
            (cg_download_is_retryable_download_error(&error) || cg_err_is(&error, "download_stopped"))) {
            unlink(plain);
        } else {
            const char *paths[] = {info, temp, plain};
            remove_files(paths, 3);
        }
    }
    if (!ok) {
        if (err) {
            cg_err_move(err, &error);
        } else {
            cg_err_clear(&error);
        }
    }
    free(temp);
    free(info);
    free(plain);
    return ok;
}

/* ---------------------------------------------------------------- delta cache, sweeps */

void cg_download_populate_delta_cache(cg_engine *engine, const char *id) {
    cg_error ignored = CG_ERROR_INIT;
    char *bundle = cg_store_bundle_directory(engine, id, &ignored);
    cg_err_clear(&ignored);
    if (!bundle) return;
    char *cache = CG_CONFIG_DUP(engine, cache_dir);
    if (!*cache || !cg_fsutil_is_dir(bundle) || !cg_fsutil_create_dir_all(cache)) {
        free(cache);
        free(bundle);
        return;
    }
    char *builtin = CG_CONFIG_DUP(engine, builtin_dir);
    cg_strs files = {0};
    cg_download_collect_files(bundle, &files);
    size_t bundle_len = strlen(bundle);
    for (size_t i = 0; i < files.len; i++) {
        const char *file = files.items[i];
        char *hash = cg_checksum_sha256_file(file, &ignored);
        cg_err_clear(&ignored);
        if (!hash) continue;
        /* strip_prefix(bundle): files come from walking `bundle`. */
        const char *relative = file;
        if (strncmp(file, bundle, bundle_len) == 0 && (file[bundle_len] == '/' || file[bundle_len] == '\0')) {
            relative = file + bundle_len;
            while (*relative == '/') relative++;
        }
        if (*builtin) {
            char *builtin_file = cg_fsutil_join(builtin, relative);
            bool same = cg_fsutil_file_matches_hash(builtin_file, hash);
            free(builtin_file);
            if (same) {
                free(hash);
                continue;
            }
        }
        const char *name = cg_fsutil_file_name(file);
        char *target_name = cg_fmt("%s_%s", hash, name ? name : "");
        char *target = cg_fsutil_join(cache, target_name);
        free(target_name);
        free(hash);
        if (!cg_fsutil_exists(target)) {
            if (!cg_fsutil_copy_atomically(file, target, &ignored))
                cg_debug(&engine->host, "Delta cache copy failed: %s", file);
            cg_err_clear(&ignored);
        }
        free(target);
    }
    cg_strs_free(&files);
    free(builtin);
    free(cache);
    free(bundle);
}

static bool is_stale_name(const char *name) {
    return (cg_starts_with(name, "temp_") && cg_ends_with(name, ".tmp")) ||
           (cg_starts_with(name, "update_") && cg_ends_with(name, ".dat")) ||
           (cg_starts_with(name, "partial_") && cg_ends_with(name, ".tmp")) || cg_starts_with(name, "work_");
}

void cg_download_cleanup_download_temp_files(cg_engine *engine) {
    const uint64_t age_ms = 3600ull * 1000;
    char *dirs[2] = {CG_CONFIG_DUP(engine, storage_root), CG_CONFIG_DUP(engine, cache_dir)};
    /* Partial files of scheduled downloads wait for their next attempt. Manifest partials are
     * named by file, not job: keep them all while a manifest job is pending. */
    cg_strs jobs = cg_scheduled_pending_job_ids(engine);
    bool manifest_pending = false;
    for (size_t i = 0; i < jobs.len && !manifest_pending; i++)
        manifest_pending = cg_scheduled_job_has_manifest(engine, jobs.items[i]);
    for (size_t d = 0; d < 2; d++) {
        cg_error ignored = CG_ERROR_INIT;
        size_t len = 0;
        char **names = cg_fsutil_read_dir(dirs[d], &len, &ignored);
        cg_err_clear(&ignored);
        if (!names) continue;
        for (size_t i = 0; i < len; i++) {
            const char *name = names[i];
            bool pending = manifest_pending && cg_starts_with(name, "partial_");
            for (size_t j = 0; j < jobs.len && !pending; j++) pending = cg_contains(name, jobs.items[j]);
            if (pending || !is_stale_name(name)) continue;
            char *path = cg_fsutil_join(dirs[d], name);
            if (cg_fsutil_modified_before(path, age_ms)) {
                cg_store_remove_path(path, &ignored);
                cg_err_clear(&ignored);
            }
            free(path);
        }
        cg_fsutil_free_names(names, len);
    }
    cg_strs_free(&jobs);
    free(dirs[0]);
    free(dirs[1]);
}

void cg_download_collect_files(const char *dir, cg_strs *out) {
    /* Heap work list: recursion per folder level could overflow a host thread's stack on a
     * deeply nested bundle. */
    cg_strs pending = {0};
    cg_strs_push_copy(&pending, dir);
    while (pending.len > 0) {
        char *current = pending.items[--pending.len];
        cg_error ignored = CG_ERROR_INIT;
        size_t len = 0;
        char **names = cg_fsutil_read_dir(current, &len, &ignored);
        cg_err_clear(&ignored);
        if (names) {
            for (size_t i = 0; i < len; i++) {
                const char *name = names[i];
                if (cg_starts_with(name, "__MACOSX") || name[0] == '.') continue;
                char *path = cg_fsutil_join(current, name);
                struct stat st;
                /* Never descend through a directory symlink: `assets/loop -> .` would loop forever. */
                if (lstat(path, &st) == 0 && S_ISDIR(st.st_mode)) {
                    cg_strs_push(&pending, path);
                } else if (cg_fsutil_is_file(path)) {
                    cg_strs_push(out, path);
                } else {
                    free(path);
                }
            }
            cg_fsutil_free_names(names, len);
        }
        free(current);
    }
    cg_strs_free(&pending);
}
