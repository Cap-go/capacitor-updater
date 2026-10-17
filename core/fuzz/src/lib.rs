//! Shared helpers of the Rust fuzz targets (`fuzz_targets/<target>.rs`). The C core has the
//! same targets with the same input format in `core-c/fuzz/<target>.c` (`fuzz_support.c`), and
//! both share the seed corpus in `fuzz/corpus/<target>`.

use std::io::{Read, Write};
use std::net::{Shutdown, TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use capgo_updater_core::host::MemoryHost;
use serde_json::json;

/// The public key the crypto targets use (native-contract-tests/cli/cli-crypto.json).
pub const PUBLIC_KEY: &str = "-----BEGIN RSA PUBLIC KEY-----\n\
MIIBCgKCAQEAxog7suMG1F2Y/e6CLNpWU0Kp5eNXPYSE+lY4Nzrxq8Mdi0nKR8tK\n\
qWHxCgNQJrfhE9CjSwuu9w656i3P32zIGRSu/nDgUkDd4Z2EGiq+Eu3ooR9SnUTC\n\
/yjCksNdbu47RHTvCtHbDEczqfpIDZMgRgYbRePQAxVHWJehfetO80yDoNdiRDrD\n\
c0UYgNQf/H5ko2KWiQs7yjsU22zPLfwZ8NEkuD2hTXZeOj/pBUborVAykI9bI59I\n\
PfQPVKEdW9RAggpR2FcYbnTMaYSc9yVIxu4VxWB7DfvPKJOrz4HOJIwfTwuFGeQs\n\
wUcG10QvXok+NHjaHHc+iBe2hk24XDUnGQIDAQAB\n\
-----END RSA PUBLIC KEY-----\n";

/// A per-process scratch directory (created once).
pub fn scratch_dir() -> &'static Path {
    static DIR: OnceLock<PathBuf> = OnceLock::new();
    DIR.get_or_init(|| {
        let dir = std::env::temp_dir().join(format!("capgo-fuzz-rust-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("scratch directory");
        dir
    })
}

/// Removes a file or a directory tree; missing paths are fine.
pub fn remove_tree(path: &Path) {
    match std::fs::symlink_metadata(path) {
        Ok(meta) if meta.is_dir() => {
            let _ = std::fs::remove_dir_all(path);
        }
        Ok(_) => {
            let _ = std::fs::remove_file(path);
        }
        Err(_) => {}
    }
}

// ---- loopback server

static RESPONSE: Mutex<Vec<u8>> = Mutex::new(Vec::new());

/// Reads the request head and its Content-Length body (an unread request would turn the
/// close into a reset that hides the response). Gives up after 2 s or 1 MiB.
fn drain_request(stream: &mut TcpStream) {
    let _ = stream.set_read_timeout(Some(Duration::from_secs(2)));
    let mut head = Vec::new();
    let mut buffer = [0u8; 4096];
    loop {
        let Ok(got) = stream.read(&mut buffer) else { return };
        if got == 0 {
            return;
        }
        head.extend_from_slice(&buffer[..got]);
        if let Some(end) = head.windows(4).position(|window| window == b"\r\n\r\n") {
            let text = String::from_utf8_lossy(&head[..end]).to_ascii_lowercase();
            let length = text
                .split("\r\n")
                .find_map(|line| line.strip_prefix("content-length:"))
                .and_then(|value| value.trim().parse::<usize>().ok())
                .filter(|length| *length <= 1 << 20)
                .unwrap_or(0);
            let mut body = length.saturating_sub(head.len() - end - 4);
            while body > 0 {
                match stream.read(&mut buffer) {
                    Ok(0) | Err(_) => return,
                    Ok(got) => body = body.saturating_sub(got),
                }
            }
            return;
        }
        if head.len() >= 16384 {
            return;
        }
    }
}

fn serve(mut stream: TcpStream) {
    drain_request(&mut stream);
    let response = RESPONSE.lock().unwrap().clone();
    let _ = stream.write_all(&response);
    let _ = stream.shutdown(Shutdown::Write);
    // Wait for the client to close (it frees its connection pool at the end of each run).
    let _ = stream.set_read_timeout(Some(Duration::from_secs(1)));
    let mut buffer = [0u8; 4096];
    while matches!(stream.read(&mut buffer), Ok(got) if got > 0) {}
    // No TIME_WAIT: thousands of connections a second would exhaust the ports.
    let linger = libc::linger {
        l_onoff: 1,
        l_linger: 0,
    };
    // SAFETY: a valid socket and a correctly sized option value.
    unsafe {
        libc::setsockopt(
            std::os::fd::AsRawFd::as_raw_fd(&stream),
            libc::SOL_SOCKET,
            libc::SO_LINGER,
            (&linger as *const libc::linger).cast(),
            std::mem::size_of::<libc::linger>() as libc::socklen_t,
        );
    }
}

/// The port of a loopback HTTP server that answers every request with the current response
/// bytes, then half-closes. Started once.
pub fn server_port() -> u16 {
    static PORT: OnceLock<u16> = OnceLock::new();
    *PORT.get_or_init(|| {
        let listener = TcpListener::bind("127.0.0.1:0").expect("loopback listener");
        let port = listener.local_addr().unwrap().port();
        std::thread::spawn(move || {
            for stream in listener.incoming().flatten() {
                std::thread::spawn(move || serve(stream));
            }
        });
        port
    })
}

pub fn set_response(bytes: &[u8]) {
    *RESPONSE.lock().unwrap() = bytes.to_vec();
}

/// An in-memory host: every request goes through the loopback server (proxyForUrl), plain
/// HTTP is permitted, HTTPS is refused (no certificate verdict but a rejection).
pub fn host() -> Arc<MemoryHost> {
    let host = Arc::new(MemoryHost::default());
    host.reply_to_hook(
        "proxyForUrl",
        json!({ "type": "http", "host": "127.0.0.1", "port": server_port() }),
    );
    *host.certificate_verdict.lock().unwrap() = Some(Some(Err("fuzz: no TLS".into())));
    host
}

/// Engine configuration of the engine-level targets, storage in the scratch directory.
pub fn engine_config(extra: serde_json::Value) -> serde_json::Value {
    let dir = scratch_dir();
    let mut config = json!({
        "platform": "android",
        "appId": "app.capgo.fuzz",
        "versionBuild": "1.0.0",
        "deviceId": "fuzz",
        "storageRoot": dir.to_string_lossy(),
        "bundleRoot": dir.join("versions").to_string_lossy(),
        "cacheDir": dir.join("cache").to_string_lossy(),
    });
    if let (Some(config), Some(extra)) = (config.as_object_mut(), extra.as_object()) {
        for (key, value) in extra {
            config.insert(key.clone(), value.clone());
        }
    }
    config
}

/// The path guard invariant shared by the path_guard and manifest targets: a resolved path is
/// `<base>/<components>` with no empty, `.` or `..` component and no backslash or NUL.
pub fn check_inside(base: &str, relative: &str, resolved: &str) {
    let trimmed = base.trim_end_matches('/');
    let (prefix, rest) = if trimmed.is_empty() {
        ("/", resolved.strip_prefix('/'))
    } else {
        (
            trimmed,
            resolved.strip_prefix(trimmed).and_then(|rest| rest.strip_prefix('/')),
        )
    };
    let Some(rest) = rest else {
        panic!("{base:?} + {relative:?} -> {resolved:?}: outside {prefix:?}");
    };
    assert!(
        !rest.is_empty(),
        "{base:?} + {relative:?} -> {resolved:?}: resolves to the base itself"
    );
    assert!(
        !rest.contains('\\') && !rest.contains('\0'),
        "{base:?} + {relative:?} -> {resolved:?}: separator"
    );
    for segment in rest.split('/') {
        assert!(
            !segment.is_empty() && segment != "." && segment != "..",
            "{base:?} + {relative:?} -> {resolved:?}: bad segment"
        );
    }
}

/// Reads at most `limit` bytes from a decoder, ignoring errors (like the C targets).
pub fn drain(reader: &mut dyn Read, limit: usize) {
    let mut buffer = vec![0u8; 65536];
    let mut total = 0;
    while let Ok(got) = reader.read(&mut buffer) {
        if got == 0 {
            return;
        }
        total += got;
        if total > limit {
            return;
        }
    }
}

/// ureq 2.12 panics on a response header line without `:`; net.rs catches that panic and
/// refuses the response (`contain_ureq_panic`). libfuzzer-sys aborts on every panic, caught or
/// not: this keeps aborting on all others. Call it in the `init` of the network targets.
pub fn tolerate_contained_ureq_panic() {
    let aborting = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        let contained = info
            .location()
            .is_some_and(|location| location.file().contains("ureq-2.") && location.file().ends_with("header.rs"));
        if !contained {
            aborting(info);
        }
    }));
}
