//! update_response: the input is the body of the update server's reply (HTTP 200, JSON),
//! served by a loopback server and read by the engine's update check (`getLatest`: body
//! limits, JSON, error and kind mapping). C: core-c/fuzz/update_response.c.
#![no_main]

use std::sync::{Arc, OnceLock};

use capgo_updater_core::engine::Engine;
use capgo_updater_core_fuzz::{engine_config, host, server_port, set_response};
use libfuzzer_sys::fuzz_target;
use serde_json::json;

fn engine() -> &'static (Arc<Engine>, String) {
    static ENGINE: OnceLock<(Arc<Engine>, String)> = OnceLock::new();
    ENGINE.get_or_init(|| {
        let config = engine_config(json!({ "timeoutMs": 2000 }));
        let engine = Engine::new(host(), &config).expect("engine refused the fuzz configuration");
        let input = json!({ "updateUrl": format!("http://127.0.0.1:{}/updates", server_port()) }).to_string();
        (engine, input)
    })
}

fuzz_target!(init: capgo_updater_core_fuzz::tolerate_contained_ureq_panic(), |data: &[u8]| {
    let (engine, input) = engine();
    let mut response = format!(
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: {}\r\n\r\n",
        data.len()
    )
    .into_bytes();
    response.extend_from_slice(data);
    set_response(&response);
    let reply = engine.call_json("getLatest", input);
    serde_json::from_str::<serde_json::Value>(&reply).expect("engine reply is JSON");
});
