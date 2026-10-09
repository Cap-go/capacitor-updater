/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/* JNI entry points for `ee.forgr.capacitor_updater.CapgoCoreNative` (Rust jni.rs). The Java host
 * (`CapgoEngineHost`) is adapted to CapgoHostCallbacks, so the engine sees one host interface. */

#include <jni.h>
#include <stdlib.h>
#include <string.h>

#include "api.h"
#include "engine/engine_api.h"
#include "host.h"

#define CG_JNI_EXPORT __attribute__((visibility("default"))) JNIEXPORT

/* Clears a pending Java exception: calling Java with one pending aborts under CheckJNI. */
static void clear_exception(JNIEnv *env) {
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionDescribe(env);
        (*env)->ExceptionClear(env);
    }
}

/* Modified UTF-8 from Java -> malloc'd UTF-8 ("" for null). NULL with *err on failure. */
static char *read_string(JNIEnv *env, jstring value, cg_error *err) {
    if (!value) return cg_strdup("");
    const char *chars = (*env)->GetStringUTFChars(env, value, NULL);
    if (!chars) {
        clear_exception(env);
        cg_err_invalid_input(err, "Invalid Java string: Java exception was thrown");
        return NULL;
    }
    char *copy = cg_strdup(chars);
    (*env)->ReleaseStringUTFChars(env, value, chars);
    return copy;
}

/* The result string for Java, or null when it cannot be made. */
static jstring java_string(JNIEnv *env, char *output) {
    clear_exception(env);
    jstring value = (*env)->NewStringUTF(env, output);
    free(output);
    if (!value) clear_exception(env);
    return value;
}

CG_JNI_EXPORT jstring JNICALL Java_ee_forgr_capacitor_1updater_CapgoCoreNative_call(JNIEnv *env, jclass cls,
                                                                                     jstring operation,
                                                                                     jstring input_json) {
    cg_error err = CG_ERROR_INIT;
    char *op = read_string(env, operation, &err);
    char *input = op ? read_string(env, input_json, &err) : NULL;
    char *output = input ? cg_api_call_json(op, input) : cg_api_envelope(NULL, &err);
    free(op);
    free(input);
    cg_err_clear(&err);
    return java_string(env, output);
}

/* ---------------------------------------------------------------------------- Java host */

typedef struct {
    JavaVM *vm;
    jobject host; /* global ref */
} jni_host;

typedef struct {
    JNIEnv *env;
    bool attached;
} env_scope;

static bool enter(jni_host *h, env_scope *scope) {
    scope->attached = false;
    if ((*h->vm)->GetEnv(h->vm, (void **)&scope->env, JNI_VERSION_1_6) == JNI_EDETACHED) {
        if ((*h->vm)->AttachCurrentThread(h->vm, (void *)&scope->env, NULL) != JNI_OK) return false;
        scope->attached = true;
    }
    /* A local frame frees this callback's local references when it returns (Android 7 aborts
     * past 512 of them on a Java thread that called into the engine). */
    if ((*scope->env)->PushLocalFrame(scope->env, 16) != 0) {
        clear_exception(scope->env);
        if (scope->attached) (*h->vm)->DetachCurrentThread(h->vm);
        return false;
    }
    return true;
}

/* Returns false when a Java exception was pending (cleared). */
static bool leave(jni_host *h, env_scope *scope) {
    bool ok = !(*scope->env)->ExceptionCheck(scope->env);
    clear_exception(scope->env);
    (*scope->env)->PopLocalFrame(scope->env, NULL);
    if (scope->attached) (*h->vm)->DetachCurrentThread(h->vm);
    return ok;
}

static jstring jstr(JNIEnv *env, const char *value) { return value ? (*env)->NewStringUTF(env, value) : NULL; }

static jmethodID method(JNIEnv *env, jobject object, const char *name, const char *signature) {
    jclass cls = (*env)->GetObjectClass(env, object);
    return cls ? (*env)->GetMethodID(env, cls, name, signature) : NULL;
}

/* Copies a Java string result (NULL for null). */
static char *string_result(JNIEnv *env, jobject value) {
    if (!value || (*env)->ExceptionCheck(env)) return NULL;
    const char *chars = (*env)->GetStringUTFChars(env, (jstring)value, NULL);
    if (!chars) return NULL;
    char *copy = cg_strdup(chars);
    (*env)->ReleaseStringUTFChars(env, (jstring)value, chars);
    return copy;
}

static void cb_log(void *context, int level, const char *message) {
    jni_host *h = context;
    env_scope s;
    if (!enter(h, &s)) return;
    jmethodID m = method(s.env, h->host, "log", "(ILjava/lang/String;)V");
    jstring text = jstr(s.env, message);
    if (m && text) (*s.env)->CallVoidMethod(s.env, h->host, m, (jint)level, text);
    leave(h, &s);
}

static char *cb_kv_get(void *context, const char *key) {
    jni_host *h = context;
    env_scope s;
    if (!enter(h, &s)) return NULL;
    char *result = NULL;
    jmethodID m = method(s.env, h->host, "kvGet", "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;");
    jstring k = jstr(s.env, key);
    if (m && k) result = string_result(s.env, (*s.env)->CallObjectMethod(s.env, h->host, m, k, NULL));
    if (!leave(h, &s)) {
        free(result);
        return NULL;
    }
    return result;
}

static void cb_kv_set(void *context, const char *key, const char *value) {
    jni_host *h = context;
    env_scope s;
    if (!enter(h, &s)) return;
    jmethodID m = method(s.env, h->host, "kvSet", "(Ljava/lang/String;Ljava/lang/String;)V");
    jstring k = jstr(s.env, key);
    jstring v = jstr(s.env, value);
    if (m && k && (v || !value)) (*s.env)->CallVoidMethod(s.env, h->host, m, k, v);
    leave(h, &s);
}

static char *cb_kv_keys(void *context) {
    jni_host *h = context;
    env_scope s;
    if (!enter(h, &s)) return NULL;
    char *result = NULL;
    jmethodID m = method(s.env, h->host, "kvKeysJson", "()Ljava/lang/String;");
    if (m) result = string_result(s.env, (*s.env)->CallObjectMethod(s.env, h->host, m));
    if (!leave(h, &s)) {
        free(result);
        return NULL;
    }
    return result;
}

static void cb_emit(void *context, const char *event, const char *payload) {
    jni_host *h = context;
    env_scope s;
    if (!enter(h, &s)) return;
    jmethodID m = method(s.env, h->host, "emit", "(Ljava/lang/String;Ljava/lang/String;)V");
    jstring e = jstr(s.env, event);
    jstring p = jstr(s.env, payload);
    if (m && e && p) (*s.env)->CallVoidMethod(s.env, h->host, m, e, p);
    leave(h, &s);
}

static void cb_free_string(void *context, char *value) { free(value); }

/* Calls a Java method `name(String) -> V/Z`; returns -1 when the call failed. */
static int call_string_method(jni_host *h, const char *name, const char *signature, const char *arg, bool returns_bool) {
    env_scope s;
    if (!enter(h, &s)) return -1;
    int result = -1;
    jmethodID m = method(s.env, h->host, name, signature);
    jstring a = arg ? jstr(s.env, arg) : NULL;
    if (m && (a || !arg)) {
        if (returns_bool) {
            jboolean value = arg ? (*s.env)->CallBooleanMethod(s.env, h->host, m, a)
                                 : (*s.env)->CallBooleanMethod(s.env, h->host, m);
            result = value ? 1 : 0;
        } else {
            if (arg) (*s.env)->CallVoidMethod(s.env, h->host, m, a);
            else (*s.env)->CallVoidMethod(s.env, h->host, m);
            result = 0;
        }
    }
    if (!leave(h, &s)) return -1;
    return result;
}

static char *reply(cj *value) {
    char *text = cj_print(value);
    cj_free(value);
    return text;
}

/* The Java host has dedicated methods for the host services the C ABI carries as hooks. */
static char *cb_hook(void *context, const char *name, const char *payload) {
    jni_host *h = context;
    cj *input = cj_parse(payload, NULL);
    const char *arg = NULL;
    if (strcmp(name, "willSwitchBundle") == 0) {
        arg = cj_get_str(input, "path");
        call_string_method(h, "willSwitchBundle", "(Ljava/lang/String;)V", arg ? arg : "", false);
        cj_free(input);
        return NULL;
    }
    if (strcmp(name, "cancelVersionDownload") == 0) {
        arg = cj_get_str(input, "version");
        int cancelled = call_string_method(h, "cancelVersionDownload", "(Ljava/lang/String;)Z", arg ? arg : "", true);
        cj_free(input);
        return reply(cj_objv("cancelled", cj_bool(cancelled == 1), NULL));
    }
    if (strcmp(name, "cancelAllDownloads") == 0) {
        call_string_method(h, "cancelAllDownloads", "()V", NULL, false);
        cj_free(input);
        return NULL;
    }
    if (strcmp(name, "sendStats") == 0) {
        /* Not routed by the Java host: the engine queues the event itself. */
        cj_free(input);
        return NULL;
    }
    if (strcmp(name, "beforeDownload") == 0) {
        cj_free(input);
        env_scope s;
        if (!enter(h, &s)) return reply(cj_objv("error", cj_str("Download gate failed"), NULL));
        char *error = NULL;
        bool called = false;
        jmethodID m = method(s.env, h->host, "beforeDownload", "()Ljava/lang/String;");
        if (m) {
            jobject value = (*s.env)->CallObjectMethod(s.env, h->host, m);
            called = !(*s.env)->ExceptionCheck(s.env);
            if (called) error = string_result(s.env, value);
        }
        if (!leave(h, &s) || !called) {
            free(error);
            return reply(cj_objv("error", cj_str("Download gate failed"), NULL));
        }
        return error ? reply(cj_objv("error", cj_str_own(error), NULL)) : NULL;
    }
    cj_free(input);
    env_scope s;
    if (!enter(h, &s)) return NULL;
    char *result = NULL;
    jmethodID m = method(s.env, h->host, "hook", "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;");
    jstring n = jstr(s.env, name);
    jstring p = jstr(s.env, payload);
    if (m && n && p) result = string_result(s.env, (*s.env)->CallObjectMethod(s.env, h->host, m, n, p));
    if (!leave(h, &s)) {
        free(result);
        return NULL;
    }
    return result;
}

static int32_t cb_verify(void *context, const char *server_name, const uint8_t *const *certificates,
                         const size_t *lengths, size_t count, char **error) {
    jni_host *h = context;
    env_scope s;
    if (!enter(h, &s)) {
        *error = cg_strdup("Certificate verification failed in host");
        return 0;
    }
    int32_t verdict = 0;
    char *message = NULL;
    bool called = false;
    jclass byte_array = (*s.env)->FindClass(s.env, "[B");
    jobjectArray chain = byte_array ? (*s.env)->NewObjectArray(s.env, (jsize)count, byte_array, NULL) : NULL;
    bool filled = chain != NULL;
    for (size_t i = 0; filled && i < count; i++) {
        jbyteArray der = (*s.env)->NewByteArray(s.env, (jsize)lengths[i]);
        if (!der) {
            filled = false;
            break;
        }
        (*s.env)->SetByteArrayRegion(s.env, der, 0, (jsize)lengths[i], (const jbyte *)certificates[i]);
        (*s.env)->SetObjectArrayElement(s.env, chain, (jsize)i, der);
        /* One local reference per certificate would overflow Android 7's 512 limit. */
        (*s.env)->DeleteLocalRef(s.env, der);
        if ((*s.env)->ExceptionCheck(s.env)) filled = false;
    }
    jmethodID m = filled ? method(s.env, h->host, "verifyServerCertificate", "([[BLjava/lang/String;)Ljava/lang/String;")
                         : NULL;
    jstring name = m ? jstr(s.env, server_name) : NULL;
    if (m && name) {
        jobject value = (*s.env)->CallObjectMethod(s.env, h->host, m, chain, name);
        called = !(*s.env)->ExceptionCheck(s.env);
        if (called) {
            message = string_result(s.env, value);
            verdict = message ? 0 : 1;
        }
    }
    if (!leave(h, &s) || !called) {
        free(message);
        *error = cg_strdup("Certificate verification failed in host");
        return 0;
    }
    *error = message;
    return verdict;
}

static void cb_release(void *context) {
    jni_host *h = context;
    JNIEnv *env = NULL;
    bool attached = false;
    if ((*h->vm)->GetEnv(h->vm, (void **)&env, JNI_VERSION_1_6) == JNI_EDETACHED) {
        if ((*h->vm)->AttachCurrentThread(h->vm, (void *)&env, NULL) == JNI_OK) attached = true;
        else env = NULL;
    }
    if (env) (*env)->DeleteGlobalRef(env, h->host);
    if (attached) (*h->vm)->DetachCurrentThread(h->vm);
    free(h);
}

/* `static native long engineCreate(String configJson, CapgoEngineHost host)`; 0 on failure. */
CG_JNI_EXPORT jlong JNICALL Java_ee_forgr_capacitor_1updater_CapgoCoreNative_engineCreate(JNIEnv *env, jclass cls,
                                                                                          jstring config_json,
                                                                                          jobject host) {
    JavaVM *vm = NULL;
    if ((*env)->GetJavaVM(env, &vm) != JNI_OK) return 0;
    jobject global = (*env)->NewGlobalRef(env, host);
    if (!global) return 0;
    jni_host *h = cg_calloc(1, sizeof(jni_host));
    h->vm = vm;
    h->host = global;
    CapgoHostCallbacks callbacks = {
        .context = h,
        .log = cb_log,
        .kv_get = cb_kv_get,
        .kv_set = cb_kv_set,
        .kv_keys = cb_kv_keys,
        .emit = cb_emit,
        .free_string = cb_free_string,
        .hook = cb_hook,
        .release = cb_release,
        .verify_server_certificate = cb_verify,
    };
    cg_error err = CG_ERROR_INIT;
    cg_engine *engine = NULL;
    char *config = read_string(env, config_json, &err);
    if (config) engine = cg_engine_create(config, &callbacks, &err);
    free(config);
    if (!engine) {
        cg_host failed = {.cb = callbacks};
        char *display = cg_err_display(&err);
        cg_host_logf(&failed, CG_ERROR, "Capgo engine init failed: %s", display);
        free(display);
        cg_err_clear(&err);
        cg_host_release(&failed);
        return 0;
    }
    return (jlong)(intptr_t)engine;
}

/* `static native String engineCall(long engine, String operation, String inputJson)` */
CG_JNI_EXPORT jstring JNICALL Java_ee_forgr_capacitor_1updater_CapgoCoreNative_engineCall(JNIEnv *env, jclass cls,
                                                                                         jlong engine,
                                                                                         jstring operation,
                                                                                         jstring input_json) {
    cg_error err = CG_ERROR_INIT;
    char *output;
    if (!engine) {
        cg_err_invalid_input(&err, "Engine handle is 0");
        output = cg_api_envelope(NULL, &err);
    } else {
        char *op = read_string(env, operation, &err);
        char *input = op ? read_string(env, input_json, &err) : NULL;
        output = input ? cg_engine_call_json((cg_engine *)(intptr_t)engine, op, input) : cg_api_envelope(NULL, &err);
        free(op);
        free(input);
    }
    cg_err_clear(&err);
    return java_string(env, output);
}

/* `static native void engineDestroy(long engine)` */
CG_JNI_EXPORT void JNICALL Java_ee_forgr_capacitor_1updater_CapgoCoreNative_engineDestroy(JNIEnv *env, jclass cls,
                                                                                         jlong engine) {
    if (engine) cg_engine_free_handle((cg_engine *)(intptr_t)engine);
}
