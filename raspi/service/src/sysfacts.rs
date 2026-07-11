use std::path::Path;

#[derive(Clone, Debug, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
pub struct DiskUsage {
    pub used: u64,
    pub total: u64,
}

#[derive(Clone, Debug, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
pub struct MemInfo {
    pub total: u64,
    pub available: u64,
    pub swap_total: u64,
    pub swap_used: u64,
}

pub fn soc_temp_c() -> Option<f32> {
    #[cfg(target_os = "linux")]
    {
        std::fs::read_to_string("/sys/class/thermal/thermal_zone0/temp")
            .ok()
            .and_then(|raw| parse_thermal(&raw))
    }

    #[cfg(not(target_os = "linux"))]
    {
        None
    }
}

#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
pub fn parse_thermal(raw: &str) -> Option<f32> {
    let millic = raw.trim().parse::<f32>().ok()?;
    Some(millic / 1000.0)
}

pub fn mem_info() -> Option<MemInfo> {
    #[cfg(target_os = "linux")]
    {
        std::fs::read_to_string("/proc/meminfo")
            .ok()
            .and_then(|raw| parse_meminfo(&raw))
    }

    #[cfg(not(target_os = "linux"))]
    {
        None
    }
}

#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
pub fn parse_meminfo(raw: &str) -> Option<MemInfo> {
    let total = meminfo_kib(raw, "MemTotal")?.checked_mul(1024)?;
    let available = meminfo_kib(raw, "MemAvailable")?.checked_mul(1024)?;
    let swap_total = meminfo_kib(raw, "SwapTotal")?.checked_mul(1024)?;
    let swap_free = meminfo_kib(raw, "SwapFree")?.checked_mul(1024)?;

    Some(MemInfo {
        total,
        available,
        swap_total,
        swap_used: swap_total.saturating_sub(swap_free),
    })
}

pub fn disk_usage(path: &Path) -> Option<DiskUsage> {
    let stat = rustix::fs::statvfs(path).ok()?;
    let block_size = if stat.f_frsize > 0 {
        stat.f_frsize
    } else {
        stat.f_bsize
    };
    let total = stat.f_blocks.checked_mul(block_size)?;
    let free = stat.f_bfree.checked_mul(block_size)?;

    Some(DiskUsage {
        used: total.saturating_sub(free),
        total,
    })
}

/// Bytes available to the non-root service. This deliberately uses f_bavail,
/// excluding filesystem blocks reserved for root.
pub fn disk_avail(path: &Path) -> Option<u64> {
    let stat = rustix::fs::statvfs(path).ok()?;
    let block_size = if stat.f_frsize > 0 {
        stat.f_frsize
    } else {
        stat.f_bsize
    };
    stat.f_bavail.checked_mul(block_size)
}

#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
fn meminfo_kib(raw: &str, key: &str) -> Option<u64> {
    raw.lines().find_map(|line| {
        let (line_key, rest) = line.split_once(':')?;
        if line_key != key {
            return None;
        }

        let mut parts = rest.split_whitespace();
        let value = parts.next()?.parse().ok()?;
        let unit = parts.next()?;
        (unit == "kB").then_some(value)
    })
}

#[cfg(test)]
mod tests {
    use super::{disk_avail, disk_usage, parse_meminfo, parse_thermal, MemInfo};

    #[test]
    fn parse_thermal_converts_millicelsius_to_celsius() {
        assert_eq!(parse_thermal("51234\n"), Some(51.234));
    }

    #[test]
    fn parse_thermal_rejects_garbage() {
        assert_eq!(parse_thermal("not-a-temp"), None);
    }

    #[test]
    fn parse_meminfo_returns_bytes_and_used_swap() {
        let meminfo = "\
MemTotal:         512000 kB
MemFree:          100000 kB
MemAvailable:     200000 kB
SwapTotal:          4096 kB
SwapFree:           1024 kB
";

        assert_eq!(
            parse_meminfo(meminfo),
            Some(MemInfo {
                total: 512000 * 1024,
                available: 200000 * 1024,
                swap_total: 4096 * 1024,
                swap_used: 3072 * 1024,
            })
        );
    }

    #[test]
    fn parse_meminfo_rejects_missing_required_fields() {
        assert_eq!(parse_meminfo("MemTotal: 512000 kB\n"), None);
    }

    #[test]
    fn parse_meminfo_rejects_non_kib_units() {
        let meminfo = "\
MemTotal:         512000 bytes
MemAvailable:     200000 kB
SwapTotal:          4096 kB
SwapFree:           1024 kB
";

        assert_eq!(parse_meminfo(meminfo), None);
    }

    #[test]
    fn disk_avail_reports_non_root_available_bytes() {
        let dir = std::env::temp_dir();
        let avail = disk_avail(&dir).expect("temporary directory should be stat-able");
        assert!(avail <= disk_usage(&dir).expect("disk usage").total);
    }
}
