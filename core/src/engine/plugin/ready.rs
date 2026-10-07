//! Reload, `notifyAppReady` and rollback: the part of the update lifecycle
//! that decides whether a bundle stays.

use crate::sync::LockRecover;
use std::time::Duration;

use serde_json::{json, Value};

use super::{hooks, keys};
use crate::bundle::{BundleInfo, BundleStatus};
use crate::engine::Engine;
use crate::host::HostLog;

/// Wraps `Capacitor.nativePromise` (not the plugin proxy: registerPlugin's get trap
/// ignores assignments to notifyAppReady) so `notifyAppReady` reports the page's
/// generation. Each document keeps its own generation.
const READY_SCRIPT_TAIL: &str = ";if(window.__capgoReadyBridge)return;function arm(){var cap=window.Capacitor;if(!cap||typeof cap.nativePromise!=='function'||cap.__capgoNativePromise)return false;var orig=cap.nativePromise.bind(cap);cap.nativePromise=function(pluginName,methodName,options){if(pluginName==='CapacitorUpdater'&&methodName==='notifyAppReady'){var next={};if(options&&typeof options==='object'){for(var k in options){if(Object.prototype.hasOwnProperty.call(options,k))next[k]=options[k];}}next.loadGeneration=window.__CAPGO_READY_GEN;options=next;}return orig(pluginName,methodName,options);};cap.__capgoNativePromise=true;window.__capgoReadyBridge=true;return true;}if(!arm()){var n=0;var t=setInterval(function(){if(arm()||++n>100)clearInterval(t);},20);}})();";

/// Document-start script the host injects with `applyBundle` (`readyScript`).
pub(crate) fn ready_generation_script(generation: i64) -> String {
    format!("(function(){{window.__CAPGO_READY_GEN={generation}{READY_SCRIPT_TAIL}")
}

impl Engine {
    // ---- notifyAppReady signal ---------------------------------------------------------------

    fn ready_token(&self) -> u64 {
        self.plugin.ready.inner.lock_or_recover().signals
    }

    /// Arms the wait consumed by the next `appReady` emission.
    pub(crate) fn arm_pending_ready_wait(&self) {
        let mut inner = self.plugin.ready.inner.lock_or_recover();
        inner.pending = Some(inner.signals);
    }

    pub(crate) fn clear_pending_ready_wait(&self) {
        self.plugin.ready.inner.lock_or_recover().pending = None;
    }

    fn take_pending_ready_wait(&self) -> Option<u64> {
        self.plugin.ready.inner.lock_or_recover().pending.take()
    }

    /// Waits until `notifyAppReady` fires after `token` (false on timeout).
    pub(crate) fn wait_for_app_ready(&self, token: u64, timeout: Duration) -> bool {
        // notifyAppReady comes through the host's method lane.
        crate::host::release_method_lane();
        let inner = self.plugin.ready.inner.lock_or_recover();
        let (inner, result) = self
            .plugin
            .ready
            .changed
            .wait_timeout_while(inner, timeout, |inner| inner.signals <= token)
            .unwrap();
        drop(inner);
        if result.timed_out() {
            self.host
                .error(format!("Semaphore wait timed out after {}ms", timeout.as_millis()));
            return false;
        }
        true
    }

    fn signal_app_ready(&self) {
        let mut inner = self.plugin.ready.inner.lock_or_recover();
        inner.signals += 1;
        drop(inner);
        self.plugin.ready.changed.notify_all();
    }

    /// Emits `appReady`, after the armed `notifyAppReady` wait when there is one.
    pub(crate) fn send_ready_to_js(&self, current: &BundleInfo, message: &str) {
        self.host.info(format!("sendReadyToJs: {message}"));
        let pending = self.take_pending_ready_wait();
        let emit = {
            let current = current.clone();
            let message = message.to_string();
            move |engine: &Engine| {
                engine
                    .host
                    .emit_retained("appReady", &json!({ "bundle": current.to_js(), "status": message }));
                if engine.plugin_config().auto_splashscreen {
                    engine.hide_splashscreen();
                }
                engine.preview_loader(false, "app-ready");
            }
        };
        match pending {
            None => emit(self),
            Some(token) => {
                let timeout = Duration::from_millis(self.plugin_config().app_ready_timeout_ms);
                let weak = self.weak_self();
                self.spawn("app-ready-timeout", move || {
                    if let Some(engine) = weak.upgrade() {
                        engine.wait_for_app_ready(token, timeout);
                        emit(&engine);
                    }
                });
            }
        }
    }

    // ---- rollback timer ----------------------------------------------------------------------

    /// Rollback delay: `appReadyTimeout`, and at least the pending-bundle minimum while the current
    /// bundle is unconfirmed.
    pub(crate) fn app_ready_check_timeout(&self) -> Duration {
        let config = self.plugin_config();
        let current = self.current_bundle();
        let millis = if current.status() == BundleStatus::Success {
            config.app_ready_timeout_ms
        } else {
            config.app_ready_timeout_ms.max(config.pending_bundle_min_timeout_ms)
        };
        Duration::from_millis(millis)
    }

    /// (Re)arms the deferred `notifyAppReady` check; the previous one is dropped.
    pub(crate) fn check_app_ready(&self, wait: Duration) {
        let generation = self
            .plugin
            .app_ready_check
            .fetch_add(1, std::sync::atomic::Ordering::SeqCst)
            + 1;
        self.host.info(format!(
            "Wait for {} ms, then check for notifyAppReady",
            wait.as_millis()
        ));
        let weak = self.weak_self();
        self.spawn("delay", move || {
            let Some(engine) = Engine::sleep_unless_dropped(&weak, wait) else {
                return;
            };
            if engine.plugin.app_ready_check.load(std::sync::atomic::Ordering::SeqCst) != generation {
                return;
            }
            // A backgrounded (or frozen, then thawed) app cannot confirm its page: the next
            // foreground arms a fresh check.
            if engine.plugin_state().in_background {
                engine
                    .host
                    .info("App is in background, notifyAppReady check deferred to the next foreground");
                return;
            }
            engine.check_revert();
        });
    }

    /// Drops the pending `notifyAppReady` check without arming a new one.
    pub(crate) fn invalidate_app_ready_check(&self) {
        self.plugin
            .app_ready_check
            .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
    }

    /// Rolls back the current bundle when `notifyAppReady` never confirmed it.
    pub(crate) fn check_revert(&self) {
        let current = self.current_bundle();
        if current.is_builtin() {
            self.host
                .info("Built-in bundle is active. We skip the check for notifyAppReady.");
            return;
        }
        if self.is_preview_state_active() {
            self.host
                .info("Preview session is active. We skip the check for notifyAppReady.");
            return;
        }
        self.host.debug(format!("Current bundle is: {}", current.id()));
        if current.status() == BundleStatus::Success {
            self.host
                .info(format!("notifyAppReady was called. This is fine: {}", current.id()));
            return;
        }
        self.host.error(format!(
            "notifyAppReady was not called, roll back current bundle: {}",
            current.id()
        ));
        {
            let _confirmation = self
                .plugin
                .confirmation
                .lock()
                .unwrap_or_else(|poison| poison.into_inner());
            // notifyAppReady may have confirmed the bundle since the check above.
            let latest = self.current_bundle();
            if latest.id() != current.id() || latest.status() == BundleStatus::Success {
                self.host.info(format!(
                    "notifyAppReady was called meanwhile, keeping: {}",
                    current.id()
                ));
                return;
            }
            self.host
                .info("Did you forget to call 'notifyAppReady()' in your Capacitor App code?");
            self.kv_write(keys::LAST_FAILED_BUNDLE, Some(&current.to_stored_json()));
            self.emit_bundle_event("updateFailed", &current);
            self.report_app_launch_timeout(&current);
            self.send_stats("update_fail", Some(current.version_name()), None, None);
            self.set_error(current.id());
        }
        self.perform_reset(true, false, true);
        if self.plugin_config().auto_delete_failed && !current.is_builtin() {
            let failed_id = current.id().to_string();
            let latest = self.get_bundle_info(Some(&failed_id));
            let still_current = self.current_bundle().id() == failed_id;
            // Resetting onto this same bundle writes SUCCESS: that bundle must survive.
            if latest.status() != BundleStatus::Error || still_current {
                self.host.info(format!("Skip deleting bundle {failed_id} after reset"));
                return;
            }
            let version = latest.version_name().to_string();
            self.host.info(format!("Deleting failing bundle: {version}"));
            // Marked before the async delete so a kill still resumes it (drainPendingDeletes).
            self.save_bundle_info(&failed_id, Some(&latest.with_status(BundleStatus::Deleting)));
            let weak = self.weak_self();
            self.spawn("delete", move || {
                if let Some(engine) = weak.upgrade() {
                    if engine.delete_bundle(&failed_id, false, false) {
                        engine.host.info(format!("Failed bundle deleted: {version}"));
                    } else {
                        engine.host.error(format!("Failed to delete failed bundle: {version}"));
                    }
                }
            });
        }
    }

    // ---- readiness guard (stale pages) -------------------------------------------------------

    fn arm_ready_guard(&self) -> i64 {
        let mut state = self.plugin_state();
        state.ready_generation += 1;
        state.ready_guard_armed = true;
        state.ready_generation
    }

    /// The page for `generation` could not be stamped: accept any `notifyAppReady`.
    pub(crate) fn disarm_ready_guard(&self, generation: i64) {
        let mut state = self.plugin_state();
        if state.ready_generation == generation && state.ready_guard_armed {
            state.ready_guard_armed = false;
            drop(state);
            self.host
                .warn("Could not stamp notifyAppReady for the next page. Readiness guard disabled for this reload.");
        }
    }

    /// `notifyAppReady` from a page loaded before the last reload is ignored.
    pub(crate) fn accepts_ready_call(&self, reported: Option<i64>) -> bool {
        let state = self.plugin_state();
        if !state.ready_guard_armed {
            return true;
        }
        reported == Some(state.ready_generation)
    }

    // ---- reload primitives -------------------------------------------------------------------

    /// Points the WebView at the current bundle.
    pub(crate) fn apply_current_bundle(&self) -> bool {
        let generation = self.arm_ready_guard();
        let path = self.current_bundle_path();
        let is_builtin = self.is_using_builtin();
        self.host.info(format!("Reloading: {path}"));
        let reply = self.hook(
            hooks::APPLY_BUNDLE,
            json!({
                "path": path,
                "isBuiltin": is_builtin,
                "readyGeneration": generation,
                "readyScript": ready_generation_script(generation),
            }),
        );
        let ok = reply
            .as_ref()
            .and_then(|reply| reply.get("ok"))
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let guarded = reply
            .as_ref()
            .and_then(|reply| reply.get("guard"))
            .and_then(Value::as_bool)
            .unwrap_or(true);
        if !ok || !guarded {
            self.disarm_ready_guard(generation);
        }
        ok
    }

    /// Re-applies the live bundle after a rejected reload.
    pub(crate) fn restore_live_bundle(&self) {
        if !self.apply_current_bundle() {
            self.host.warn("Failed to restore live bundle after rejected reload");
        }
    }

    /// Reloads the WebView on the current bundle. Hosts that wait for readiness
    /// return `false` when `notifyAppReady` does not arrive in time.
    pub(crate) fn reload_app(&self) -> bool {
        let config = self.plugin_config();
        // A backgrounded page cannot confirm itself: do not wait (the next foreground checks it).
        if config.reload_waits_for_app_ready && !self.plugin_state().in_background {
            // This reload owns notifyAppReady synchronization.
            self.clear_pending_ready_wait();
            let token = self.ready_token();
            if !self.apply_current_bundle() {
                return false;
            }
            let wait = self.app_ready_check_timeout();
            self.check_app_ready(wait);
            self.host.emit("appReloaded", &json!({}));
            return self.wait_for_app_ready(token, wait);
        }
        self.arm_pending_ready_wait();
        if !self.apply_current_bundle() {
            self.clear_pending_ready_wait();
            return false;
        }
        self.check_app_ready(self.app_ready_check_timeout());
        self.host.emit("appReloaded", &json!({}));
        true
    }

    /// Reload used by preview sessions: never waits for readiness.
    pub(crate) fn reload_without_waiting(&self) -> bool {
        if !self.apply_current_bundle() {
            return false;
        }
        self.check_app_ready(self.app_ready_check_timeout());
        self.host.emit("appReloaded", &json!({}));
        true
    }

    /// Stages `bundle`, reloads, finalizes (or restores everything on failure).
    pub(crate) fn apply_downloaded_bundle(&self, bundle: &BundleInfo) -> bool {
        let previous_state = self.capture_reset_state();
        let previous_name = self.current_bundle().version_name().to_string();
        if !self.stage_pending_reload(bundle) {
            self.restore_reset_state(&previous_state);
            self.host.error(format!(
                "Direct update failed to stage downloaded bundle: {}",
                bundle.id()
            ));
            return false;
        }
        if self.reload_app() {
            self.finalize_pending_reload(bundle, &previous_name);
            self.set_next_bundle(None);
            return true;
        }
        self.restore_reset_state(&previous_state);
        self.restore_live_bundle();
        self.host.error(format!(
            "Direct update reload failed after staging bundle: {}",
            bundle.id()
        ));
        false
    }

    /// `set(id)` from JavaScript: switch and reload.
    pub(crate) fn set_and_reload(&self, id: &str) -> Result<BundleInfo, String> {
        self.host.info(format!("Setting active bundle {id}"));
        if !self.set_bundle(id) {
            return Err(format!("Update failed, id {id} does not exist."));
        }
        let bundle = self.get_bundle_info(Some(id));
        if self.plugin_state().preview_session_enabled {
            self.record_preview_bundle(&bundle, None);
            if !self.reload_without_waiting() {
                return Err(format!("Reload failed after setting preview bundle {id}"));
            }
        } else if !self.reload_app() {
            return Err(format!("Reload failed after setting bundle {id}"));
        }
        self.emit_set_event(&bundle);
        self.show_preview_notice_if_needed();
        Ok(bundle)
    }

    /// `reload()` from JavaScript: applies a pending bundle first when there is one.
    pub(crate) fn reload_with_pending(&self) -> Result<(), String> {
        let current = self.current_bundle();
        let next = self.next_bundle();
        if let Some(next) =
            next.filter(|next| !self.is_preview_state_active() && !next.is_error() && next.id() != current.id())
        {
            let previous_state = self.capture_reset_state();
            let previous_name = current.version_name().to_string();
            self.host.info(format!(
                "Applying pending bundle before reload: {}",
                next.version_name()
            ));
            let staged = if next.is_builtin() {
                self.prepare_reset_state_for_transition();
                true
            } else {
                self.stage_pending_reload(&next)
            };
            if staged && self.reload_app() {
                if next.is_builtin() {
                    self.finalize_reset_transition(&previous_name, false);
                } else {
                    self.finalize_pending_reload(&next, &previous_name);
                }
                self.emit_set_event(&next);
                self.set_next_bundle(None);
                self.show_preview_notice_if_needed();
                return Ok(());
            }
            self.restore_reset_state(&previous_state);
            self.restore_live_bundle();
            return Err(format!(
                "Reload failed after applying pending bundle: {}",
                next.version_name()
            ));
        }
        if self.reload_app() {
            self.show_preview_notice_if_needed();
            Ok(())
        } else {
            Err("Reload failed".into())
        }
    }

    /// Reset to the pending bundle, the last successful bundle, or builtin.
    pub(crate) fn perform_reset(&self, to_last_successful: bool, use_pending_bundle: bool, internal: bool) -> bool {
        let fallback = self.fallback_bundle();
        let pending = self.next_bundle();
        let previous_state = self.capture_reset_state();
        let previous_name = self.current_bundle().version_name().to_string();

        if use_pending_bundle {
            let Some(pending) = pending.filter(|pending| !pending.is_error()) else {
                self.host.error("No pending bundle available to reset to");
                return false;
            };
            if !self.can_set(&pending) {
                self.host.error("Pending bundle is not installable");
                return false;
            }
            self.prepare_reset_state_for_transition();
            self.host
                .info(format!("Resetting to pending bundle: {}", pending.version_name()));
            let applied = pending.is_builtin() || self.set_bundle(pending.id());
            if applied && self.reload_app() {
                self.finalize_reset_transition(&previous_name, internal);
                self.emit_set_event(&pending);
                self.set_next_bundle(None);
                return true;
            }
            self.restore_reset_state(&previous_state);
            self.restore_live_bundle();
            return false;
        }

        if to_last_successful && !fallback.is_builtin() {
            if self.can_set(&fallback) {
                self.prepare_reset_state_for_transition();
                self.host.info(format!("Resetting to: {}", fallback.version_name()));
                if self.set_bundle(fallback.id()) && self.reload_app() {
                    self.finalize_reset_transition(&previous_name, internal);
                    self.emit_set_event(&fallback);
                    return true;
                }
                if !internal {
                    self.restore_reset_state(&previous_state);
                    self.restore_live_bundle();
                    return false;
                }
                self.host
                    .warn("Fallback reload failed during internal reset, resetting to builtin instead");
            } else {
                self.host
                    .warn("Fallback bundle is not installable, resetting to builtin instead");
            }
        }

        self.prepare_reset_state_for_transition();
        self.host.info("Resetting to builtin version");
        if self.reload_app() {
            self.finalize_reset_transition(&previous_name, internal);
            return true;
        }
        if !internal {
            self.restore_reset_state(&previous_state);
            self.restore_live_bundle();
        }
        false
    }

    /// `notifyAppReady()`: confirms the current bundle.
    pub(crate) fn notify_app_ready(&self, reported_generation: Option<i64>) -> Value {
        let current = self.current_bundle();
        if !self.accepts_ready_call(reported_generation) {
            self.host
                .info("Ignoring notifyAppReady from a page that is no longer current");
            return json!({ "bundle": current.to_js() });
        }
        if let Some(engine) = self.weak_self().upgrade() {
            let _confirmation = self
                .plugin
                .confirmation
                .lock()
                .unwrap_or_else(|poison| poison.into_inner());
            engine.set_success(current.id(), self.plugin_config().auto_delete_previous);
        }
        self.report_app_launch_ready(&current);
        self.host.info(format!(
            "Current bundle loaded successfully. ['notifyAppReady()' was called] {}",
            current.id()
        ));
        self.signal_app_ready();
        self.clear_incoming_preview_transition();
        self.preview_loader(false, "notify-app-ready");
        json!({ "bundle": self.current_bundle().to_js() })
    }

    /// One-shot read of the bundle that was rolled back.
    pub(crate) fn take_failed_update(&self) -> Value {
        let Some(raw) = self
            .kv_text(keys::LAST_FAILED_BUNDLE)
            .filter(|raw| !raw.trim().is_empty())
        else {
            return Value::Null;
        };
        self.kv_write(keys::LAST_FAILED_BUNDLE, None);
        match BundleInfo::from_stored_json(&raw) {
            Some(bundle) if !bundle.is_unknown() => json!({ "bundle": bundle.to_js() }),
            _ => {
                self.host.error("Failed to parse failed bundle info");
                Value::Null
            }
        }
    }

    // ---- splash screen -----------------------------------------------------------------------

    pub(crate) fn show_splashscreen(&self) {
        let generation = self
            .plugin
            .splash_timer
            .fetch_add(1, std::sync::atomic::Ordering::SeqCst)
            + 1;
        self.plugin_state().auto_splashscreen_timed_out = false;
        self.hook(hooks::SPLASH, json!({ "action": "show" }));
        let timeout = self.plugin_config().auto_splashscreen_timeout_ms;
        if timeout == 0 {
            return;
        }
        let weak = self.weak_self();
        self.spawn("app-ready-timeout", move || {
            let Some(engine) = Engine::sleep_unless_dropped(&weak, Duration::from_millis(timeout)) else {
                return;
            };
            if engine.plugin.splash_timer.load(std::sync::atomic::Ordering::SeqCst) != generation {
                return;
            }
            engine
                .host
                .info("autoSplashscreen timeout reached, hiding splashscreen");
            engine.plugin_state().auto_splashscreen_timed_out = true;
            engine.hook(hooks::SPLASH, json!({ "action": "hide" }));
        });
    }

    pub(crate) fn hide_splashscreen(&self) {
        self.plugin
            .splash_timer
            .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        self.hook(hooks::SPLASH, json!({ "action": "hide" }));
    }
}

#[cfg(test)]
mod tests {
    use super::ready_generation_script;

    /// Byte-identical to the script the Android and iOS hosts used to build.
    #[test]
    fn ready_generation_script_stamps_notify_app_ready() {
        let script = ready_generation_script(7);
        assert_eq!(
            script,
            "(function(){window.__CAPGO_READY_GEN=7;if(window.__capgoReadyBridge)return;function arm(){var cap=window.Capacitor;if(!cap||typeof cap.nativePromise!=='function'||cap.__capgoNativePromise)return false;var orig=cap.nativePromise.bind(cap);cap.nativePromise=function(pluginName,methodName,options){if(pluginName==='CapacitorUpdater'&&methodName==='notifyAppReady'){var next={};if(options&&typeof options==='object'){for(var k in options){if(Object.prototype.hasOwnProperty.call(options,k))next[k]=options[k];}}next.loadGeneration=window.__CAPGO_READY_GEN;options=next;}return orig(pluginName,methodName,options);};cap.__capgoNativePromise=true;window.__capgoReadyBridge=true;return true;}if(!arm()){var n=0;var t=setInterval(function(){if(arm()||++n>100)clearInterval(t);},20);}})();"
        );
        assert!(script.contains("window.__CAPGO_READY_GEN=7;"));
        assert!(script.contains("methodName==='notifyAppReady'"));
        assert!(script.contains("next.loadGeneration=window.__CAPGO_READY_GEN"));
        assert!(!script.contains("plugin.notifyAppReady="));
    }
}
