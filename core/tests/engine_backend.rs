mod support;

use serde_json::json;
use support::{FakeServer, TestEngine};

fn engine_with(server: &FakeServer) -> TestEngine {
    TestEngine::new(json!({
        "updateUrl": format!("{}/updates", server.url),
        "statsUrl": format!("{}/stats", server.url),
        "channelUrl": format!("{}/channel_self", server.url),
    }))
}

#[test]
fn get_latest_posts_info_object_and_renames_session_key() {
    let server = FakeServer::start(|_| {
        FakeServer::json(
            200,
            json!({ "version": "1.2.0", "url": "https://x/b.zip", "session_key": "iv:key", "checksum": "abc" }),
        )
    });
    let t = engine_with(&server);
    let result = t.call("getLatest", json!({ "channel": "beta" }));
    assert_eq!(result["version"], "1.2.0");
    assert_eq!(result["sessionKey"], "iv:key");
    assert_eq!(result["statusCode"], 200);
    let request = &server.requests()[0];
    assert_eq!(request.method, "POST");
    let body = request.json();
    assert_eq!(body["platform"], "android");
    assert_eq!(body["app_id"], "app.capgo.test");
    assert_eq!(body["defaultChannel"], "beta");
    assert_eq!(body["version_name"], "1.0.0");
    assert_eq!(body["is_prod"], true);
    assert!(request
        .header("User-Agent")
        .unwrap()
        .starts_with("CapacitorUpdater/8.0.0 (app.capgo.test) android/14"));
}

#[test]
fn get_latest_error_body_keeps_kind_message_and_status() {
    let server = FakeServer::start(|_| {
        FakeServer::json(
            200,
            json!({ "error": "no_new_version_available", "kind": "up_to_date" }),
        )
    });
    let t = engine_with(&server);
    let result = t.call("getLatest", json!({}));
    assert_eq!(result["error"], "no_new_version_available");
    assert_eq!(result["kind"], "up_to_date");
    assert_eq!(result["message"], "server did not provide a message");
    assert_eq!(result["statusCode"], 200);
}

#[test]
fn get_latest_error_body_keeps_every_server_field() {
    let server = FakeServer::start(|_| {
        FakeServer::json(
            200,
            json!({
                "error": "disable_auto_update_to_major",
                "kind": "blocked",
                "message": "major",
                "version": "3.0.0",
                "major": true,
                "breaking": true,
                "link": "https://example.com/notes",
                "comment": "big one",
                "data": { "team": "a" },
                "session_key": "iv:key",
                "manifest": [{ "file_name": "a.js", "file_hash": "h", "download_url": "https://x/a.js" }],
                "url": "https://x/b.zip",
                "checksum": "abc",
            }),
        )
    });
    let t = engine_with(&server);
    let result = t.call("getLatest", json!({}));
    assert_eq!(result["error"], "disable_auto_update_to_major");
    assert_eq!(result["kind"], "blocked");
    assert_eq!(result["message"], "major");
    assert_eq!(result["version"], "3.0.0");
    assert_eq!(result["statusCode"], 200);
    assert_eq!(result["major"], true);
    assert_eq!(result["breaking"], true);
    assert_eq!(result["link"], "https://example.com/notes");
    assert_eq!(result["comment"], "big one");
    assert_eq!(result["data"]["team"], "a");
    assert_eq!(result["sessionKey"], "iv:key");
    assert!(result.get("session_key").is_none());
    assert_eq!(result["manifest"][0]["file_name"], "a.js");
    assert_eq!(result["url"], "https://x/b.zip");
    assert_eq!(result["checksum"], "abc");
}

#[test]
fn server_error_and_network_error() {
    let server = FakeServer::start(|_| (500, vec![], b"oops".to_vec()));
    let t = engine_with(&server);
    let result = t.call("getLatest", json!({}));
    assert_eq!(result["error"], "response_error");
    assert_eq!(result["message"], "Server error: 500");
    let t = TestEngine::new(json!({ "updateUrl": "http://127.0.0.1:1/updates" }));
    assert_eq!(t.call("getLatest", json!({}))["error"], "network_error");
}

#[test]
fn set_channel_persists_and_unset_reverts() {
    let server = FakeServer::start(|request| {
        if request.json()["channel"] == "public" {
            FakeServer::json(200, json!({ "status": "ok", "unset": true }))
        } else {
            FakeServer::json(200, json!({ "status": "ok" }))
        }
    });
    let t = engine_with(&server);
    let result = t.call(
        "setChannel",
        json!({ "channel": "beta", "persistKey": "CapacitorUpdater.defaultChannel", "configDefaultChannel": "prod" }),
    );
    assert_eq!(result["status"], "ok");
    assert_eq!(t.kv("CapacitorUpdater.defaultChannel").unwrap(), "beta");
    assert_eq!(t.call("config", json!({}))["defaultChannel"], "beta");
    t.call(
        "setChannel",
        json!({ "channel": "public", "persistKey": "CapacitorUpdater.defaultChannel", "configDefaultChannel": "prod" }),
    );
    assert!(t.kv("CapacitorUpdater.defaultChannel").is_none());
    assert_eq!(t.call("config", json!({}))["defaultChannel"], "prod");
    let disabled = t.call("setChannel", json!({ "channel": "x", "allowSetDefaultChannel": false }));
    assert_eq!(disabled["error"], "disabled_by_config");
}

#[test]
fn get_channel_uses_put_and_falls_back_to_default_channel() {
    let server = FakeServer::start(|request| {
        assert_eq!(request.method, "PUT");
        (400, vec![], b"{\"error\":\"channel_not_found\"}".to_vec())
    });
    let t = TestEngine::new(json!({ "channelUrl": format!("{}/channel_self", server.url), "defaultChannel": "prod" }));
    let result = t.call("getChannel", json!({}));
    assert_eq!(result["channel"], "prod");
    assert_eq!(result["status"], "default");
}

#[test]
fn list_channels_sends_query_and_parses_array() {
    let server = FakeServer::start(|_| {
        FakeServer::json(
            200,
            json!([{ "id": 1, "name": "prod", "public": true }, { "id": 2, "name": "beta", "allow_self_set": true }]),
        )
    });
    let t = engine_with(&server);
    let result = t.call("listChannels", json!({}));
    assert_eq!(result["channels"][1]["allow_self_set"], true);
    assert_eq!(result["channels"][0]["allow_self_set"], false);
    assert!(server.requests()[0].url.contains("app_id=app.capgo.test"));
    assert_eq!(server.requests()[0].method, "GET");
}

#[test]
fn missing_channel_url() {
    let t = TestEngine::new(json!({}));
    assert_eq!(t.call("listChannels", json!({}))["error"], "missing_config");
    assert_eq!(
        t.call("setChannel", json!({ "channel": "x" }))["message"],
        "channelUrl missing"
    );
}

#[test]
fn stats_are_batched_and_sent() {
    let server = FakeServer::start(|_| (200, vec![], b"{}".to_vec()));
    let t = engine_with(&server);
    t.call(
        "statsSend",
        json!({ "action": "set", "versionName": "1.0.1", "callbackId": "cb-1" }),
    );
    t.call("statsSend", json!({ "action": "delete" }));
    assert_eq!(t.call("statsPendingCount", json!({}))["count"], 2);
    t.call("statsFlush", json!({}));
    let requests = server.requests();
    let batch = requests
        .iter()
        .find(|request| request.url.contains("stats"))
        .unwrap()
        .json();
    assert_eq!(batch.as_array().unwrap().len(), 2);
    assert_eq!(batch[0]["action"], "set");
    assert_eq!(batch[1]["version_name"], "1.0.0");
    assert!(batch[0]["timestamp"].as_i64().unwrap() > 0);
    assert_eq!(t.host.events_named("statsSent")[0]["callbackId"], "cb-1");
    assert_eq!(t.call("statsPendingCount", json!({}))["count"], 0);
}

#[test]
fn stats_are_requeued_on_transient_failure_and_persisted() {
    let server = FakeServer::start(|_| (503, vec![], vec![]));
    let t = engine_with(&server);
    t.call("statsSend", json!({ "action": "set" }));
    t.call("statsFlush", json!({}));
    assert_eq!(t.call("statsPendingCount", json!({}))["count"], 1);
    t.call("statsPersist", json!({}));
    let file = t.root().join("capgo_pending_stats.json");
    let stored: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(&file).unwrap()).unwrap();
    assert_eq!(stored.as_array().unwrap().len(), 1);
    // A new engine instance restores the queue.
    let other =
        TestEngine::new(json!({ "statsUrl": "http://127.0.0.1:1/stats", "storageRoot": t.root().to_string_lossy() }));
    other.call("statsRestore", json!({}));
    assert_eq!(other.call("statsPendingCount", json!({}))["count"], 1);
}

#[test]
fn stats_skipped_in_preview_session_or_without_url() {
    let t = TestEngine::new(json!({}));
    t.call("statsSend", json!({ "action": "set" }));
    assert_eq!(t.call("statsPendingCount", json!({}))["count"], 0);
    let t = TestEngine::new(json!({ "statsUrl": "http://127.0.0.1:1/stats", "previewSession": true }));
    t.call("statsSend", json!({ "action": "set" }));
    assert_eq!(t.call("statsPendingCount", json!({}))["count"], 0);
}

#[test]
fn bundle_size_falls_back_on_error() {
    let t = TestEngine::new(json!({ "updateUrl": "http://127.0.0.1:1/updates?x=1" }));
    let result = t.call("bundleDownloadSize", json!({ "manifest": [{ "file_name": "a.js" }] }));
    assert_eq!(result["unknownFiles"], 1);
    assert_eq!(result["files"][0]["error"], "response_error");
    assert_eq!(
        capgo_updater_core::engine::backend::manifest_size_url("https://x/updates?y=1"),
        "https://x/updates/manifest_size"
    );
}

#[test]
fn set_channel_error_status_does_not_persist_default_channel() {
    let server = FakeServer::start(|_| FakeServer::json(401, json!({ "status": "error", "message": "Unauthorized" })));
    let t = engine_with(&server);
    let result = t.call(
        "setChannel",
        json!({ "channel": "beta", "persistKey": "CapacitorUpdater.defaultChannel", "configDefaultChannel": "stable" }),
    );
    assert_eq!(result["error"], "response_error");
    assert_eq!(result["message"], "Unauthorized");
    assert!(t.kv("CapacitorUpdater.defaultChannel").is_none());
}

#[test]
fn get_channel_persists_server_channel() {
    let server = FakeServer::start(|_| {
        FakeServer::json(200, json!({ "channel": "company-a", "status": "ok", "allowSet": true }))
    });
    let t = engine_with(&server);
    let result = t.call("getChannel", json!({ "persistKey": "CapacitorUpdater.defaultChannel" }));
    assert_eq!(result["channel"], "company-a");
    assert_eq!(t.kv("CapacitorUpdater.defaultChannel").unwrap(), "company-a");
}

#[test]
fn cleartext_http_follows_the_app_policy() {
    let server = FakeServer::start(|_| FakeServer::json(200, json!({ "version": "1.2.0" })));
    let t = engine_with(&server);
    t.host
        .reply_to_hook("cleartextPermitted", json!({ "permitted": false }));
    let result = t.call("getLatest", json!({}));
    assert_eq!(result["error"], "network_error");
    assert!(result["message"].as_str().unwrap().contains("Cleartext HTTP traffic"));
    assert!(server.requests().is_empty(), "nothing sent in clear text");
    assert_eq!(t.host.hooks_named("cleartextPermitted")[0]["host"], "127.0.0.1");
}
