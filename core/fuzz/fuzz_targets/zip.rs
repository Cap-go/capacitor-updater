//! zip: the input is a bundle zip. Central directory, entry reader, inflate, CRC and the
//! zip-slip / symlink guards (`archive::extract_zip`), then the single-folder unwrap
//! (`archive::install_extracted`). C: core-c/fuzz/zip.c.
#![no_main]

use capgo_updater_core::engine::archive;
use capgo_updater_core_fuzz::{remove_tree, scratch_dir};
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let dir = scratch_dir();
    let zip = dir.join("input.zip");
    let out = dir.join("extract");
    let bundle = dir.join("bundle");
    remove_tree(&out);
    remove_tree(&bundle);
    std::fs::write(&zip, data).expect("write input");
    match archive::extract_zip(&zip, &out, &mut |_, _| {}, &|| false) {
        Ok(()) => {
            let _ = archive::install_extracted(&out, &bundle);
        }
        Err(error) => {
            let _ = error.message();
        }
    }
    remove_tree(&out);
    remove_tree(&bundle);
});
