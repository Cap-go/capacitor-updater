/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/*
 * Downloads run as jobs of the host's scheduler (Rust engine/scheduled.rs, Android
 * WorkManager): they wait for the network, retry with the scheduler's backoff and survive
 * the app process. See the Rust module comment for the protocol (`scheduleDownload` hook,
 * `runScheduledDownload` / `stopScheduledDownload` operations, job files in
 * `<storageRoot>/capgo_download_jobs/<id>.json`).
 *
 * The job registry (waiters, running attempts) is process-wide: a static in scheduled.c with
 * its own mutex and condition variable. Never call the host or another engine lock while
 * holding it (Rust drops the guard before `scheduled_download_retrying`).
 */
#ifndef CG_ENGINE_SCHEDULED_H
#define CG_ENGINE_SCHEDULED_H

#include <stdbool.h>
#include <stddef.h>

#include "bundle.h"
#include "engine/download.h"
#include "engine/engine_api.h"
#include "rt/err.h"
#include "rt/json.h"
#include "rt/str.h"

#define CG_JOBS_DIR "capgo_download_jobs"
/* How often a waiting caller re-checks cancellation and engine release. */
#define CG_SCHEDULED_WAIT_TICK_MS 500

/* How a scheduled download ended for its waiting caller (Rust Scheduled). */
typedef enum {
    /* The job finished; a failure already has its ERROR record. */
    CG_SCHEDULED_SETTLED = 0,
    /* The job was cancelled (bundle deleted, reset) before it finished. */
    CG_SCHEDULED_CANCELLED,
    /* The engine was released (plugin destroyed): the job goes on without this caller. */
    CG_SCHEDULED_DETACHED,
} cg_scheduled_kind;

typedef struct {
    cg_scheduled_kind kind;
    /* CG_SCHEDULED_SETTLED: Ok(bundle) when ok, Err(error) otherwise. */
    bool ok;
    cg_bundle_info bundle;
    cg_error error;
} cg_scheduled;

void cg_scheduled_clear(cg_scheduled *scheduled);

/* Scheduled download attempts running in this process. */
size_t cg_scheduled_running_jobs(void);
/* Ids of the scheduled downloads not finished yet (job files). */
cg_strs cg_scheduled_pending_job_ids(cg_engine *engine);
/* Job `id` downloads a manifest (its partial files are named by file, not job). */
bool cg_scheduled_job_has_manifest(cg_engine *engine, const char *id);
/* Offers the transfer of a started download to the host's scheduler. false (Rust None): the
 * host does not schedule downloads and the caller runs it in-process. true: *out is the
 * outcome (the call blocked until the job ended, was cancelled or the engine detached). */
bool cg_scheduled_schedule_download(cg_engine *engine, const cg_download_request *request,
                                    const cg_bundle_info *record, const cg_cancel *cancel, cg_scheduled *out);
/* Waits for a scheduled job of `version` an earlier process started. Option<CoreResult<..>>:
 * returns -1 (None: no such job or nobody runs it), 1 (Ok, *out initialized) or 0 (Err,
 * *err set). */
int cg_scheduled_adopt_scheduled_download(cg_engine *engine, const char *version, cg_bundle_info *out,
                                          cg_error *err);
/* Result of a scheduled download for its caller, like the in-process one. Consumes
 * *scheduled (cleared). CoreResult<BundleInfo> convention of download.h. */
bool cg_scheduled_scheduled_result(cg_engine *engine, const cg_download_request *request,
                                   const cg_bundle_info *record, cg_scheduled *scheduled, cg_bundle_info *out,
                                   cg_error *err);
/* `runScheduledDownload {id}`: one attempt of job `id`. Owned
 * `{result: "success" | "retry" | "failure", bundle?, error?}`. */
cj *cg_scheduled_run_scheduled_download(cg_engine *engine, const char *id);
/* `stopScheduledDownload {id}`: the scheduler stopped the job; abort its attempt. */
void cg_scheduled_stop_scheduled_download(cg_engine *engine, const char *id);
/* Cancels the scheduled downloads of `version` (every one with NULL). */
void cg_scheduled_cancel_scheduled_downloads(cg_engine *engine, const char *version);
/* Cancels the platform jobs of `version` (`cancelVersionDownload` hook), then their engine
 * side. false when the host refused. */
bool cg_scheduled_cancel_version_download(cg_engine *engine, const char *version);
/* `detachScheduledDownloads`: callers waiting for a scheduled download return. */
void cg_scheduled_detach_scheduled_downloads(cg_engine *engine);

#endif
