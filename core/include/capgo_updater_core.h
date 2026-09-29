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

/** Releases a string returned by capgo_core_call(). NULL is ignored. */
void capgo_core_free(char *value);

#ifdef __cplusplus
}
#endif

#endif /* CAPGO_UPDATER_CORE_H */
