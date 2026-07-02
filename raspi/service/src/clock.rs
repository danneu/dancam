pub fn boottime_ms() -> u64 {
    let time = current_time();
    let secs = u64::try_from(time.tv_sec).unwrap_or(0);
    let nanos = u64::try_from(time.tv_nsec).unwrap_or(0);
    secs.saturating_mul(1000).saturating_add(nanos / 1_000_000)
}

#[cfg(target_os = "linux")]
fn current_time() -> rustix::time::Timespec {
    rustix::time::clock_gettime(rustix::time::ClockId::Boottime)
}

#[cfg(not(target_os = "linux"))]
fn current_time() -> rustix::time::Timespec {
    rustix::time::clock_gettime(rustix::time::ClockId::Monotonic)
}
