//! http_response: the input is `<mode> <raw HTTP response>`, served by a loopback server (also
//! the proxy for every other URL, so redirects never leave the machine). The low bit of
//! `mode` picks a buffered GET (`Http::get`: status line, headers, chunked and Content-Length
//! bodies, gzip, redirects) or a streamed download (`Http::download`).
//! C: core-c/fuzz/http_response.c.
#![no_main]

use std::time::Duration;

use capgo_updater_core::net::{Http, NetError, NetErrorKind, Stream};
use capgo_updater_core_fuzz::{host, server_port, set_response};
use libfuzzer_sys::fuzz_target;

fuzz_target!(init: capgo_updater_core_fuzz::tolerate_contained_ureq_panic(), |data: &[u8]| {
    let Some((mode, response)) = data.split_first() else {
        return;
    };
    let port = server_port();
    set_response(response);
    let http = Http::new(host(), "capgo-fuzz".into(), Duration::from_millis(2000));
    let url = format!("http://127.0.0.1:{port}/fuzz");
    if mode & 1 == 1 {
        let mut total = 0usize;
        let _ = http.download(&url, &[], &mut |event| {
            if let Stream::Chunk(chunk) = event {
                total += chunk.len();
            }
            if total < 64 << 20 {
                Ok(())
            } else {
                Err(NetError {
                    kind: NetErrorKind::Io,
                    message: "limit".into(),
                })
            }
        });
    } else if let Ok(response) = http.get(&url) {
        let _ = response.json();
    }
});
