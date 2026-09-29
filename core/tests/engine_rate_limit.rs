//! The 429 block is process-wide by design (shared by every engine), so this
//! test lives in its own test binary.
mod support;

use std::time::Duration;

use serde_json::json;
use support::{FakeServer, TestEngine};

#[test]
fn rate_limit_blocks_following_requests() {
    let server = FakeServer::start(|_| {
        (
            429,
            vec![("Retry-After".into(), "60".into())],
            json!({ "error": "too_many_requests", "message": "slow" })
                .to_string()
                .into_bytes(),
        )
    });
    let t = TestEngine::new(json!({
        "updateUrl": format!("{}/updates", server.url),
        "statsUrl": format!("{}/stats", server.url),
    }));
    let first = t.call("getLatest", json!({}));
    assert_eq!(first["error"], "too_many_requests");
    assert_eq!(first["statusCode"], 429);
    assert_eq!(t.call("isRemoteBlocked", json!({}))["blocked"], true);
    let before = server.requests().len();
    let second = t.call("getLatest", json!({}));
    assert_eq!(second["error"], "too_many_requests");
    assert_eq!(second["message"], "slow");
    std::thread::sleep(Duration::from_millis(200));
    let urls: Vec<String> = server
        .requests()
        .iter()
        .map(|request| request.url.clone())
        .collect();
    assert!(
        urls.iter().filter(|url| url.contains("updates")).count() == 1,
        "blocked request never sent: {urls:?}"
    );
    assert!(server.requests().len() >= before);
}
