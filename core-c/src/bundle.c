/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/* Bundle model shared by every host, stored and exchanged as JSON. */

#include "bundle.h"

#include <stdlib.h>
#include <string.h>

#include "rt/str.h"
#include "rt/sync.h"

const char *const CG_BUNDLE_STATUSES[6] = {"success", "error", "pending", "deleted", "deleting", "downloading"};

const char *cg_bundle_parse_bundle_status(const char *value) {
    size_t start, len;
    cg_trim_range(cg_or_empty(value), &start, &len);
    if (len == 0) return "pending";
    const char *text = cg_or_empty(value) + start;
    for (size_t i = 0; i < 6; i++) {
        const char *status = CG_BUNDLE_STATUSES[i];
        if (strlen(status) != len) continue;
        bool same = true;
        for (size_t j = 0; j < len && same; j++) {
            unsigned char c = (unsigned char)text[j];
            if (c >= 'A' && c <= 'Z') c = (unsigned char)(c - 'A' + 'a');
            same = c == (unsigned char)status[j];
        }
        if (same) return status;
    }
    return NULL;
}

const char *cg_bundle_status_str(cg_bundle_status status) {
    switch (status) {
    case CG_BUNDLE_SUCCESS: return "success";
    case CG_BUNDLE_ERROR: return "error";
    case CG_BUNDLE_PENDING: return "pending";
    case CG_BUNDLE_DELETED: return "deleted";
    case CG_BUNDLE_DELETING: return "deleting";
    case CG_BUNDLE_DOWNLOADING: return "downloading";
    }
    return "error";
}

bool cg_bundle_status_parse(const char *value, cg_bundle_status *out) {
    const char *status = cg_bundle_parse_bundle_status(value);
    if (!status) return false;
    cg_bundle_status parsed = CG_BUNDLE_DOWNLOADING;
    if (strcmp(status, "success") == 0) parsed = CG_BUNDLE_SUCCESS;
    else if (strcmp(status, "error") == 0) parsed = CG_BUNDLE_ERROR;
    else if (strcmp(status, "pending") == 0) parsed = CG_BUNDLE_PENDING;
    else if (strcmp(status, "deleted") == 0) parsed = CG_BUNDLE_DELETED;
    else if (strcmp(status, "deleting") == 0) parsed = CG_BUNDLE_DELETING;
    if (out) *out = parsed;
    return true;
}

/* BundleStatus::parse(value).unwrap_or(fallback). */
static cg_bundle_status status_or(const char *value, cg_bundle_status fallback) {
    cg_bundle_status status;
    return cg_bundle_status_parse(value, &status) ? status : fallback;
}

void cg_bundle_info_init(cg_bundle_info *out, const char *id, const char *version, cg_bundle_status status,
                         const char *downloaded, const char *checksum) {
    out->id = cg_strdup(cg_or_empty(id));
    out->version = cg_strdup(version);
    out->downloaded = cg_trim(cg_or_empty(downloaded));
    out->checksum = cg_strdup(cg_or_empty(checksum));
    out->status = status;
    out->link = NULL;
    out->comment = NULL;
}

cg_bundle_info *cg_bundle_info_new(const char *id, const char *version, cg_bundle_status status,
                                   const char *downloaded, const char *checksum) {
    cg_bundle_info *info = cg_malloc(sizeof(*info));
    cg_bundle_info_init(info, id, version, status, downloaded, checksum);
    return info;
}

void cg_bundle_info_clear(cg_bundle_info *info) {
    if (!info) return;
    free(info->id);
    free(info->version);
    free(info->downloaded);
    free(info->checksum);
    free(info->link);
    free(info->comment);
    memset(info, 0, sizeof(*info));
}

void cg_bundle_info_free(cg_bundle_info *info) {
    if (!info) return;
    cg_bundle_info_clear(info);
    free(info);
}

void cg_bundle_info_copy(cg_bundle_info *out, const cg_bundle_info *info) {
    out->id = cg_strdup(cg_or_empty(info->id));
    out->version = cg_strdup(info->version);
    out->downloaded = cg_strdup(cg_or_empty(info->downloaded));
    out->checksum = cg_strdup(cg_or_empty(info->checksum));
    out->status = info->status;
    out->link = cg_strdup(info->link);
    out->comment = cg_strdup(info->comment);
}

cg_bundle_info *cg_bundle_info_clone(const cg_bundle_info *info) {
    if (!info) return NULL;
    cg_bundle_info *copy = cg_malloc(sizeof(*copy));
    cg_bundle_info_copy(copy, info);
    return copy;
}

static bool opt_eq(const char *a, const char *b) { return (!a && !b) || (a && b && strcmp(a, b) == 0); }

bool cg_bundle_info_eq(const cg_bundle_info *a, const cg_bundle_info *b) {
    if (!a || !b) return a == b;
    return opt_eq(a->id, b->id) && opt_eq(a->version, b->version) && opt_eq(a->downloaded, b->downloaded) &&
           opt_eq(a->checksum, b->checksum) && a->status == b->status && opt_eq(a->link, b->link) &&
           opt_eq(a->comment, b->comment);
}

void cg_bundle_info_set_link(cg_bundle_info *info, const char *value) { cg_replace(&info->link, cg_strdup(value)); }

void cg_bundle_info_set_comment(cg_bundle_info *info, const char *value) {
    cg_replace(&info->comment, cg_strdup(value));
}

bool cg_bundle_info_is_builtin(const cg_bundle_info *info) { return cg_eq(info->id, CG_BUNDLE_ID_BUILTIN); }

bool cg_bundle_info_is_unknown(const cg_bundle_info *info) { return cg_eq(info->id, CG_BUNDLE_VERSION_UNKNOWN); }

const char *cg_bundle_info_id(const cg_bundle_info *info) { return cg_or_empty(info->id); }

const char *cg_bundle_info_version_name(const cg_bundle_info *info) {
    return cg_empty(info->version) ? CG_BUNDLE_ID_BUILTIN : info->version;
}

cg_bundle_status cg_bundle_info_status(const cg_bundle_info *info) {
    return cg_bundle_info_is_builtin(info) ? CG_BUNDLE_SUCCESS : info->status;
}

const char *cg_bundle_info_downloaded(const cg_bundle_info *info) {
    return cg_bundle_info_is_builtin(info) ? CG_BUNDLE_DOWNLOADED_BUILTIN : cg_or_empty(info->downloaded);
}

const char *cg_bundle_info_checksum(const cg_bundle_info *info) {
    return cg_bundle_info_is_builtin(info) ? "" : cg_or_empty(info->checksum);
}

bool cg_bundle_info_is_error(const cg_bundle_info *info) { return info->status == CG_BUNDLE_ERROR; }
bool cg_bundle_info_is_deleted(const cg_bundle_info *info) { return info->status == CG_BUNDLE_DELETED; }
bool cg_bundle_info_is_deleting(const cg_bundle_info *info) { return info->status == CG_BUNDLE_DELETING; }
bool cg_bundle_info_is_downloading(const cg_bundle_info *info) { return info->status == CG_BUNDLE_DOWNLOADING; }

bool cg_bundle_info_is_downloaded(const cg_bundle_info *info) {
    return !cg_bundle_info_is_builtin(info) && !cg_empty(info->downloaded) &&
           !cg_eq(info->downloaded, CG_BUNDLE_DOWNLOADED_BUILTIN) && !cg_bundle_info_is_deleted(info) &&
           !cg_bundle_info_is_deleting(info);
}

cg_bundle_info *cg_bundle_info_with_status(const cg_bundle_info *info, cg_bundle_status status) {
    cg_bundle_info *copy = cg_bundle_info_clone(info);
    copy->status = status;
    return copy;
}

cg_bundle_info *cg_bundle_info_with_id(const cg_bundle_info *info, const char *id) {
    cg_bundle_info *copy = cg_bundle_info_clone(info);
    cg_replace(&copy->id, cg_strdup(cg_or_empty(id)));
    return copy;
}

cj *cg_bundle_info_to_js(const cg_bundle_info *info) {
    cj *out = cj_objv("id", cj_str(cg_bundle_info_id(info)), "version", cj_str(cg_bundle_info_version_name(info)),
                      "downloaded", cj_str(cg_bundle_info_downloaded(info)), "checksum",
                      cj_str(cg_bundle_info_checksum(info)), "status",
                      cj_str(cg_bundle_status_str(cg_bundle_info_status(info))), NULL);
    if (!cg_empty(info->link)) cj_set(out, "link", cj_str(info->link));
    if (!cg_empty(info->comment)) cj_set(out, "comment", cj_str(info->comment));
    return out;
}

cj *cg_bundle_info_to_raw(const cg_bundle_info *info) {
    return cj_objv("id", cj_str(cg_or_empty(info->id)), "version", cj_str(info->version), "downloaded",
                   cj_str(cg_or_empty(info->downloaded)), "checksum", cj_str(cg_or_empty(info->checksum)), "status",
                   cj_str(cg_bundle_status_str(info->status)), "link", cj_str(info->link), "comment",
                   cj_str(info->comment), NULL);
}

/* Status of a stored / raw object: a one-key object is the legacy Swift tagged enum
 * (`{"SUCCESS":{}}`), anything else is read as a string (non-strings read as "" = pending);
 * unknown values are errors. */
static cg_bundle_status status_of(const cj *status) {
    if (cj_is_obj(status) && cj_len(status) == 1) return status_or(cj_key_at(status, 0), CG_BUNDLE_ERROR);
    return status_or(cj_as_str(status), CG_BUNDLE_ERROR);
}

/* Fields shared by from_raw and from_stored_json; version is set by the caller. */
static void fields_from_object(const cj *object, cg_bundle_info *out) {
    out->id = cg_strdup(cg_or_empty(cj_get_str(object, "id")));
    out->version = NULL;
    out->downloaded = cg_trim(cg_or_empty(cj_get_str(object, "downloaded")));
    out->checksum = cg_strdup(cg_or_empty(cj_get_str(object, "checksum")));
    out->status = status_of(cj_get(object, "status"));
    out->link = cg_strdup(cj_get_str(object, "link"));
    out->comment = cg_strdup(cj_get_str(object, "comment"));
}

bool cg_bundle_info_from_raw(const cj *value, cg_bundle_info *out) {
    if (!cj_is_obj(value)) return false;
    fields_from_object(value, out);
    out->version = cg_strdup(cj_get_str(value, "version"));
    return true;
}

char *cg_bundle_info_to_stored_json(const cg_bundle_info *info) {
    cj *value = cg_bundle_info_to_js(info);
    cj_set(value, "id", cj_str(cg_bundle_info_is_builtin(info) ? CG_BUNDLE_ID_BUILTIN : cg_or_empty(info->id)));
    char *text = cj_print(value);
    cj_free(value);
    return text;
}

bool cg_bundle_info_from_stored_json(const char *value, cg_bundle_info *out) {
    if (!value) return false;
    cj *json = cj_parse(value, NULL);
    if (!cj_is_obj(json)) {
        cj_free(json);
        return false;
    }
    fields_from_object(json, out);
    /* A missing status is pending (status_of reads absent as "" = pending too). */
    const char *version = cj_get_str(json, "version");
    out->version = cg_strdup(version ? version : CG_BUNDLE_VERSION_UNKNOWN);
    cj_free(json);
    return true;
}

char *cg_bundle_iso8601_now(void) { return cg_bundle_iso8601_from_millis(cg_now_ms()); }

static int64_t div_euclid(int64_t a, int64_t b) {
    int64_t q = a / b;
    if (a % b < 0) q = b > 0 ? q - 1 : q + 1;
    return q;
}

static int64_t rem_euclid(int64_t a, int64_t b) {
    int64_t r = a % b;
    if (r < 0) r = b > 0 ? r + b : r - b;
    return r;
}

char *cg_bundle_iso8601_from_millis(int64_t millis) {
    int64_t seconds = div_euclid(millis, 1000);
    int64_t ms = rem_euclid(millis, 1000);
    int64_t days = div_euclid(seconds, 86400);
    int64_t secs_of_day = rem_euclid(seconds, 86400);
    /* Civil-from-days (Howard Hinnant). */
    int64_t z = days + 719468;
    int64_t era = div_euclid(z, 146097);
    int64_t doe = rem_euclid(z, 146097);
    int64_t yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    int64_t y = yoe + era * 400;
    int64_t doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    int64_t mp = (5 * doy + 2) / 153;
    int64_t d = doy - (153 * mp + 2) / 5 + 1;
    int64_t m = mp < 10 ? mp + 3 : mp - 9;
    if (m <= 2) y += 1;
    return cg_fmt("%04lld-%02lld-%02lldT%02lld:%02lld:%02lld.%03lldZ", (long long)y, (long long)m, (long long)d,
                  (long long)(secs_of_day / 3600), (long long)((secs_of_day % 3600) / 60),
                  (long long)(secs_of_day % 60), (long long)ms);
}
