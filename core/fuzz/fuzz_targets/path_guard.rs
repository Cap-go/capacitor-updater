//! path_guard: the input is `<base> 0xFF <relative path>` (no 0xFF: the relative path under
//! /data/app/versions). Manifest file_name, zip entry and bundle id guards
//! (`paths::resolve_path_inside`, `resolve_manifest_target_path`, `builtin_asset_path`) must
//! keep every accepted path strictly inside its base. C: core-c/fuzz/path_guard.c.
#![no_main]

use capgo_updater_core::paths;
use capgo_updater_core_fuzz::check_inside;
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let (base, relative) = match data.iter().position(|byte| *byte == 0xFF) {
        Some(at) => (
            String::from_utf8_lossy(&data[..at]).into_owned(),
            String::from_utf8_lossy(&data[at + 1..]).into_owned(),
        ),
        None => (
            "/data/app/versions".to_string(),
            String::from_utf8_lossy(data).into_owned(),
        ),
    };
    // The C target sees C strings: both stop at the first NUL of the base.
    let base = base.split('\0').next().unwrap_or_default();

    if let Ok(resolved) = paths::resolve_path_inside(base, &relative) {
        assert!(
            !paths::contains_path_traversal_segment(&relative),
            "{relative:?} accepted with a .. segment"
        );
        assert!(
            !relative.starts_with('/') && !relative.starts_with('~'),
            "{relative:?} accepted as absolute"
        );
        check_inside(base, &relative, &resolved);
    }
    if let Ok(target) = paths::resolve_manifest_target_path(base, &relative) {
        check_inside(base, &relative, &target);
    }
    if let Ok(asset) = paths::builtin_asset_path(&relative) {
        assert!(asset.starts_with("public/"), "builtin asset {relative:?} -> {asset:?}");
        check_inside("public", &relative, &asset);
    }
});
