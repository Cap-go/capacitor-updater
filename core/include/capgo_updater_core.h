/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

#ifndef CAPGO_UPDATER_CORE_H
#define CAPGO_UPDATER_CORE_H

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Runs one Capgo updater core operation.
 *
 * `operation` is an operation name (see native-contract-tests/ group names),
 * `input_json` a UTF-8 JSON object (NULL or "" means `{}`).
 *
 * Returns a UTF-8 JSON envelope, never NULL:
 *   {"ok":true,"value":{...}}
 *   {"ok":false,"error":{"code":"...","message":"..."}}
 * The returned string must be released with capgo_core_free().
 * Thread-safe.
 */
char *capgo_core_call(const char *operation, const char *input_json);

/** Releases a string returned by capgo_core_call() or capgo_engine_call(). NULL is ignored. */
void capgo_core_free(char *value);

/**
 * Platform services for the updater engine. Every callback may run on any
 * thread. Strings passed in are valid only during the call. kv_get / kv_keys
 * return host-allocated strings (or NULL) that the engine releases with
 * free_string. release is called once when the engine is destroyed.
 * hook (optional) receives platform hooks by name with a JSON payload
 * (willSwitchBundle, cancelVersionDownload, beforeDownload, cancelAllDownloads,
 * sendStats) and returns a host-allocated JSON object reply or NULL.
 */
typedef struct CapgoHostCallbacks {
    void *context;
    void (*log)(void *context, int level, const char *message);
    char *(*kv_get)(void *context, const char *key);
    void (*kv_set)(void *context, const char *key, const char *value);
    char *(*kv_keys)(void *context);
    void (*emit)(void *context, const char *event, const char *payload_json);
    void (*free_string)(void *context, char *value);
    char *(*hook)(void *context, const char *name, const char *payload_json);
    void (*release)(void *context);
} CapgoHostCallbacks;

typedef struct CapgoEngine CapgoEngine;

/**
 * Creates an updater engine from a JSON configuration; NULL when invalid.
 * The engine owns host.context in every case: on failure release(context) has
 * already been called when NULL is returned.
 */
CapgoEngine *capgo_engine_new(const char *config_json, CapgoHostCallbacks host);

/** Runs an engine operation (blocking); JSON envelope like capgo_core_call(). */
char *capgo_engine_call(const CapgoEngine *engine, const char *operation, const char *input_json);

/** Destroys an engine (no call may be in flight). */
void capgo_engine_free(CapgoEngine *engine);

#ifdef __cplusplus
}
#endif

#endif /* CAPGO_UPDATER_CORE_H */
