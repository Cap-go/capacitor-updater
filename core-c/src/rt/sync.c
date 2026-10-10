/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

#include "sync.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "str.h"

void cg_mutex_init(cg_mutex *mutex) { pthread_mutex_init(mutex, NULL); }
void cg_mutex_destroy(cg_mutex *mutex) { pthread_mutex_destroy(mutex); }
void cg_lock(cg_mutex *mutex) { pthread_mutex_lock(mutex); }
void cg_unlock(cg_mutex *mutex) { pthread_mutex_unlock(mutex); }

#if defined(__APPLE__)
/* macOS / iOS have no pthread_condattr_setclock: relative waits are used instead. */
#define CG_COND_RELATIVE 1
#endif

void cg_cond_init(cg_cond *cond) {
#ifdef CG_COND_RELATIVE
    pthread_cond_init(cond, NULL);
#else
    pthread_condattr_t attr;
    pthread_condattr_init(&attr);
    pthread_condattr_setclock(&attr, CLOCK_MONOTONIC);
    pthread_cond_init(cond, &attr);
    pthread_condattr_destroy(&attr);
#endif
}

void cg_cond_destroy(cg_cond *cond) { pthread_cond_destroy(cond); }
void cg_cond_wait(cg_cond *cond, cg_mutex *mutex) { pthread_cond_wait(cond, mutex); }
void cg_cond_signal(cg_cond *cond) { pthread_cond_signal(cond); }
void cg_cond_broadcast(cg_cond *cond) { pthread_cond_broadcast(cond); }

bool cg_cond_wait_ms(cg_cond *cond, cg_mutex *mutex, int64_t timeout_ms) {
    if (timeout_ms < 0) timeout_ms = 0;
    struct timespec ts;
#ifdef CG_COND_RELATIVE
    ts.tv_sec = (time_t)(timeout_ms / 1000);
    ts.tv_nsec = (long)((timeout_ms % 1000) * 1000000);
    return pthread_cond_timedwait_relative_np(cond, mutex, &ts) != ETIMEDOUT;
#else
    clock_gettime(CLOCK_MONOTONIC, &ts);
    ts.tv_sec += (time_t)(timeout_ms / 1000);
    ts.tv_nsec += (long)((timeout_ms % 1000) * 1000000);
    if (ts.tv_nsec >= 1000000000L) {
        ts.tv_sec++;
        ts.tv_nsec -= 1000000000L;
    }
    return pthread_cond_timedwait(cond, mutex, &ts) != ETIMEDOUT;
#endif
}

typedef struct {
    void (*run)(void *);
    void *arg;
    char name[16];
} thread_start;

static void *thread_main(void *raw) {
    thread_start start = *(thread_start *)raw;
    free(raw);
#if defined(__APPLE__)
    pthread_setname_np(start.name);
#elif defined(__linux__) || defined(__ANDROID__)
    pthread_setname_np(pthread_self(), start.name);
#endif
    start.run(start.arg);
    return NULL;
}

static bool spawn(const char *name, void (*run)(void *), void *arg, bool detached, pthread_t *out) {
    thread_start *start = cg_calloc(1, sizeof(thread_start));
    start->run = run;
    start->arg = arg;
    /* Linux limits thread names to 15 bytes. */
    snprintf(start->name, sizeof start->name, "capgo-%s", name ? name : "worker");
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    /* Extraction recursion and TLS handshakes need more than the 512 KiB default of secondary threads. */
    pthread_attr_setstacksize(&attr, 2 * 1024 * 1024);
    if (detached) pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    pthread_t thread;
    int result = pthread_create(&thread, &attr, thread_main, start);
    pthread_attr_destroy(&attr);
    if (result != 0) {
        free(start);
        return false;
    }
    if (out) *out = thread;
    return true;
}

bool cg_spawn(const char *name, void (*run)(void *), void *arg) { return spawn(name, run, arg, true, NULL); }

bool cg_spawn_joinable(const char *name, void (*run)(void *), void *arg, pthread_t *thread) {
    return spawn(name, run, arg, false, thread);
}

void cg_join(pthread_t thread) { pthread_join(thread, NULL); }

int64_t cg_now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

uint64_t cg_mono_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

int64_t cg_mono_ms(void) { return (int64_t)(cg_mono_ns() / 1000000ull); }

void cg_sleep_ms(int64_t ms) {
    if (ms <= 0) return;
    struct timespec ts = {(time_t)(ms / 1000), (long)((ms % 1000) * 1000000)};
    while (nanosleep(&ts, &ts) != 0 && errno == EINTR) {
    }
}

int cg_cpu_count(void) {
    long count = sysconf(_SC_NPROCESSORS_ONLN);
    return count > 0 ? (int)count : 1;
}

void cg_event_init(cg_event *event) {
    cg_mutex_init(&event->mutex);
    cg_cond_init(&event->cond);
    event->set = false;
}

void cg_event_destroy(cg_event *event) {
    cg_mutex_destroy(&event->mutex);
    cg_cond_destroy(&event->cond);
}

void cg_event_set(cg_event *event) {
    cg_lock(&event->mutex);
    event->set = true;
    cg_cond_broadcast(&event->cond);
    cg_unlock(&event->mutex);
}

bool cg_event_is_set(cg_event *event) {
    cg_lock(&event->mutex);
    bool set = event->set;
    cg_unlock(&event->mutex);
    return set;
}

void cg_event_wait(cg_event *event) {
    cg_lock(&event->mutex);
    while (!event->set) cg_cond_wait(&event->cond, &event->mutex);
    cg_unlock(&event->mutex);
}

bool cg_event_wait_ms(cg_event *event, int64_t timeout_ms) {
    int64_t deadline = cg_mono_ms() + timeout_ms;
    cg_lock(&event->mutex);
    while (!event->set) {
        int64_t left = deadline - cg_mono_ms();
        if (left <= 0) break;
        cg_cond_wait_ms(&event->cond, &event->mutex, left);
    }
    bool set = event->set;
    cg_unlock(&event->mutex);
    return set;
}
