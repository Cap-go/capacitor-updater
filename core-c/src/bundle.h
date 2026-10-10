/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/*
 * Bundle model shared by every host, stored and exchanged as JSON (Rust bundle.rs).
 *
 * A cg_bundle_info owns its strings. Stack values are released with
 * cg_bundle_info_clear, heap values (cg_bundle_info_new / _clone / _with_*) with
 * cg_bundle_info_free. Accessors return borrowed pointers valid while the value lives.
 *
 * Rust BundleInfo -> C:
 *   BundleInfo::new            cg_bundle_info_init / cg_bundle_info_new
 *   is_builtin / is_unknown    cg_bundle_info_is_builtin / _is_unknown
 *   id()                       cg_bundle_info_id
 *   version_name()             cg_bundle_info_version_name
 *   status()                   cg_bundle_info_status       (effective: builtin is success)
 *   downloaded() / checksum()  cg_bundle_info_downloaded / _checksum (builtin overrides)
 *   is_error ... is_downloaded cg_bundle_info_is_error ... _is_downloaded (raw status)
 *   with_status / with_id      cg_bundle_info_with_status / _with_id (heap copies)
 *   to_js / to_raw / from_raw  cg_bundle_info_to_js / _to_raw / _from_raw
 *   to_stored_json / from_stored_json
 *                              cg_bundle_info_to_stored_json / _from_stored_json
 *   clone / ==                 cg_bundle_info_clone, cg_bundle_info_copy / cg_bundle_info_eq
 */
#ifndef CG_BUNDLE_H
#define CG_BUNDLE_H

#include <stdbool.h>
#include <stdint.h>

#include "rt/json.h"

#define CG_BUNDLE_ID_BUILTIN "builtin"
#define CG_BUNDLE_VERSION_UNKNOWN "unknown"
#define CG_BUNDLE_DOWNLOADED_BUILTIN "1970-01-01T00:00:00.000Z"

/* The six stored status strings, in Rust STATUSES order. */
extern const char *const CG_BUNDLE_STATUSES[6];

/* Parses a stored bundle status: surrounding whitespace (Unicode) and ASCII case are
 * ignored, NULL / empty means "pending", unknown values give NULL. Static string. */
const char *cg_bundle_parse_bundle_status(const char *value);

typedef enum {
    CG_BUNDLE_SUCCESS = 0,
    CG_BUNDLE_ERROR,
    CG_BUNDLE_PENDING,
    CG_BUNDLE_DELETED,
    CG_BUNDLE_DELETING,
    CG_BUNDLE_DOWNLOADING,
} cg_bundle_status;

/* BundleStatus::as_str ("success", "error", ...). */
const char *cg_bundle_status_str(cg_bundle_status status);
/* BundleStatus::parse: false (Rust None) for unknown values; NULL / "" is pending. */
bool cg_bundle_status_parse(const char *value, cg_bundle_status *out);

/* A downloaded (or builtin) web bundle. */
typedef struct {
    char *id;           /* never NULL once initialized */
    char *version;      /* NULL / "" = builtin version name */
    char *downloaded;   /* never NULL, trimmed */
    char *checksum;     /* never NULL */
    cg_bundle_status status;
    char *link;         /* NULL = absent */
    char *comment;      /* NULL = absent */
} cg_bundle_info;

/* BundleInfo::new: copies every string (NULL id / downloaded / checksum read as "");
 * `downloaded` is trimmed; link and comment are absent. */
void cg_bundle_info_init(cg_bundle_info *out, const char *id, const char *version, cg_bundle_status status,
                         const char *downloaded, const char *checksum);
cg_bundle_info *cg_bundle_info_new(const char *id, const char *version, cg_bundle_status status,
                                   const char *downloaded, const char *checksum);
/* Frees the members (the struct is zeroed). NULL-safe. */
void cg_bundle_info_clear(cg_bundle_info *info);
/* Frees the members and the struct. NULL-safe. */
void cg_bundle_info_free(cg_bundle_info *info);
/* Deep copy into *out (not cleared first). */
void cg_bundle_info_copy(cg_bundle_info *out, const cg_bundle_info *info);
/* Heap deep copy (NULL in, NULL out). */
cg_bundle_info *cg_bundle_info_clone(const cg_bundle_info *info);
/* Field-by-field equality (Rust PartialEq; NULL != ""). */
bool cg_bundle_info_eq(const cg_bundle_info *a, const cg_bundle_info *b);

/* Field setters: copy `value` (NULL allowed for version / link / comment). */
void cg_bundle_info_set_link(cg_bundle_info *info, const char *value);
void cg_bundle_info_set_comment(cg_bundle_info *info, const char *value);

bool cg_bundle_info_is_builtin(const cg_bundle_info *info);
bool cg_bundle_info_is_unknown(const cg_bundle_info *info);
const char *cg_bundle_info_id(const cg_bundle_info *info);
/* The version, or "builtin" when it is absent or empty. */
const char *cg_bundle_info_version_name(const cg_bundle_info *info);
/* Effective status: success for the builtin bundle. */
cg_bundle_status cg_bundle_info_status(const cg_bundle_info *info);
/* DOWNLOADED_BUILTIN for the builtin bundle. */
const char *cg_bundle_info_downloaded(const cg_bundle_info *info);
/* "" for the builtin bundle. */
const char *cg_bundle_info_checksum(const cg_bundle_info *info);
/* Raw status checks (no builtin override, like Rust). */
bool cg_bundle_info_is_error(const cg_bundle_info *info);
bool cg_bundle_info_is_deleted(const cg_bundle_info *info);
bool cg_bundle_info_is_deleting(const cg_bundle_info *info);
bool cg_bundle_info_is_downloading(const cg_bundle_info *info);
/* Not builtin, downloaded set and not the builtin date, not deleted / deleting. */
bool cg_bundle_info_is_downloaded(const cg_bundle_info *info);

/* Heap copies with one field changed. */
cg_bundle_info *cg_bundle_info_with_status(const cg_bundle_info *info, cg_bundle_status status);
cg_bundle_info *cg_bundle_info_with_id(const cg_bundle_info *info, const char *id);

/* JSON shape exposed to JavaScript (`BundleInfo` in definitions.ts): id, version (name),
 * downloaded, checksum, status (effective), link / comment only when non-empty. Owned. */
cj *cg_bundle_info_to_js(const cg_bundle_info *info);
/* Raw fields for hosts that rebuild their own value type (nullable version, link, comment;
 * raw status). Owned. */
cj *cg_bundle_info_to_raw(const cg_bundle_info *info);
/* Inverse of to_raw. false (Rust None) when `value` is not an object; *out is then
 * untouched, otherwise initialized (caller clears it). */
bool cg_bundle_info_from_raw(const cj *value, cg_bundle_info *out);
/* JSON persisted under `<id>_info` (readable by every previous plugin version). malloc'd. */
char *cg_bundle_info_to_stored_json(const cg_bundle_info *info);
/* Parses a stored `<id>_info` value (Android JSON string or iOS Codable JSON, legacy Swift
 * `{"SUCCESS":{}}` statuses included). false (Rust None) when not a JSON object; *out is
 * then untouched, otherwise initialized (caller clears it). */
bool cg_bundle_info_from_stored_json(const char *value, cg_bundle_info *out);

/* ISO-8601 UTC timestamp with milliseconds (`2024-01-02T03:04:05.678Z`), malloc'd. */
char *cg_bundle_iso8601_now(void);
char *cg_bundle_iso8601_from_millis(int64_t millis);

#endif
