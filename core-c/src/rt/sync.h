/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/* Locks, condition variables, threads and clocks (POSIX). */
#ifndef CG_SYNC_H
#define CG_SYNC_H

#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>

typedef pthread_mutex_t cg_mutex;
typedef pthread_cond_t cg_cond;

#define CG_MUTEX_INIT PTHREAD_MUTEX_INITIALIZER
#define CG_COND_INIT PTHREAD_COND_INITIALIZER

void cg_mutex_init(cg_mutex *mutex);
void cg_mutex_destroy(cg_mutex *mutex);
void cg_lock(cg_mutex *mutex);
void cg_unlock(cg_mutex *mutex);

/* Condition variables use the monotonic clock where available. */
void cg_cond_init(cg_cond *cond);
void cg_cond_destroy(cg_cond *cond);
void cg_cond_wait(cg_cond *cond, cg_mutex *mutex);
/* false on timeout. */
bool cg_cond_wait_ms(cg_cond *cond, cg_mutex *mutex, int64_t timeout_ms);
void cg_cond_signal(cg_cond *cond);
void cg_cond_broadcast(cg_cond *cond);

/* Starts a detached thread named "capgo-<name>". false when the OS refuses (arg untouched). */
bool cg_spawn(const char *name, void (*run)(void *arg), void *arg);
/* Joinable variant. */
bool cg_spawn_joinable(const char *name, void (*run)(void *arg), void *arg, pthread_t *thread);
void cg_join(pthread_t thread);

/* Milliseconds since the Unix epoch (wall clock). */
int64_t cg_now_ms(void);
/* Monotonic clock. */
int64_t cg_mono_ms(void);
uint64_t cg_mono_ns(void);
void cg_sleep_ms(int64_t ms);

/* Number of online processors (>= 1). */
int cg_cpu_count(void);

/* A one-shot latch / event: set once, waiters wake. */
typedef struct {
    cg_mutex mutex;
    cg_cond cond;
    bool set;
} cg_event;

void cg_event_init(cg_event *event);
void cg_event_destroy(cg_event *event);
void cg_event_set(cg_event *event);
bool cg_event_is_set(cg_event *event);
void cg_event_wait(cg_event *event);
bool cg_event_wait_ms(cg_event *event, int64_t timeout_ms);

#endif
