//! Stamps the build date into the binary.
//!
//! Every flan-server reports crate version 0.1.0, and several of them run at
//! once from independently stale builds — so the version alone can't tell two
//! apart. The date can.

use std::time::{SystemTime, UNIX_EPOCH};

fn main() {
    // Days since the epoch → a date, without pulling in a date library for one
    // string. Good enough to answer "is this relay older than that one".
    let days = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() / 86_400)
        .unwrap_or(0);
    let (year, month, day) = civil_from_days(days as i64);
    println!("cargo:rustc-env=FLAN_BUILD_DATE={year:04}-{month:02}-{day:02}");
    // Without this the stamp would be baked in on the first build and kept
    // forever, which is exactly the staleness it exists to expose.
    println!("cargo:rerun-if-changed=src");
}

/// Howard Hinnant's days-from-civil, inverted. Public domain algorithm.
fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u64;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}
