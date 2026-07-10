use std::{collections::BTreeMap, fs, io, time::Instant};

#[derive(Clone, Debug, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
pub struct CpuCore {
    pub id: u32,
    pub current_pct: Option<u8>,
    pub one_minute_pct: Option<u8>,
    pub five_minute_pct: Option<u8>,
    pub fifteen_minute_pct: Option<u8>,
}

#[derive(Clone, Debug, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
pub struct Cpu {
    pub cores: Vec<CpuCore>,
}
impl Cpu {
    pub fn empty() -> Self {
        Self { cores: Vec::new() }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Counters {
    total: u64,
    idle: u64,
}
#[derive(Clone, Debug)]
struct Tracker {
    previous: Option<(Counters, Instant)>,
    ewma: Option<[f64; 3]>,
}
impl Tracker {
    fn new() -> Self {
        Self {
            previous: None,
            ewma: None,
        }
    }
    fn baseline(id: u32) -> CpuCore {
        CpuCore {
            id,
            current_pct: None,
            one_minute_pct: None,
            five_minute_pct: None,
            fifteen_minute_pct: None,
        }
    }
}

pub(crate) struct CpuSampler {
    trackers: BTreeMap<u32, Tracker>,
}
impl CpuSampler {
    pub(crate) fn new() -> Self {
        Self {
            trackers: BTreeMap::new(),
        }
    }
    pub(crate) fn sample(&mut self) -> Cpu {
        match read_proc_stat().and_then(|raw| parse_proc_stat(&raw)) {
            Ok(value) => self.observe(value, Instant::now()),
            Err(_) => self.clear(),
        }
    }
    fn clear(&mut self) -> Cpu {
        self.trackers.clear();
        Cpu::empty()
    }
    fn observe(&mut self, counters: BTreeMap<u32, Counters>, now: Instant) -> Cpu {
        self.trackers.retain(|id, _| counters.contains_key(id));
        let mut cores = Vec::with_capacity(counters.len());
        for (id, current) in counters {
            let tracker = self.trackers.entry(id).or_insert_with(Tracker::new);
            let Some((previous, previous_at)) = tracker.previous else {
                tracker.previous = Some((current, now));
                cores.push(Tracker::baseline(id));
                continue;
            };
            let delta_total = i128::from(current.total) - i128::from(previous.total);
            if delta_total <= 0 {
                *tracker = Tracker::new();
                cores.push(Tracker::baseline(id));
                continue;
            }
            let delta_idle = i128::from(current.idle) - i128::from(previous.idle);
            let utilization =
                (100.0 * (delta_total - delta_idle) as f64 / delta_total as f64).clamp(0.0, 100.0);
            let dt = now.duration_since(previous_at).as_secs_f64();
            let next = match tracker.ewma {
                Some(previous) => [60.0, 300.0, 900.0].map(|tau: f64| {
                    let decay = (-dt / tau).exp();
                    let index = if tau == 60.0 {
                        0
                    } else if tau == 300.0 {
                        1
                    } else {
                        2
                    };
                    previous[index] * decay + utilization * (1.0 - decay)
                }),
                None => [utilization; 3],
            };
            tracker.previous = Some((current, now));
            tracker.ewma = Some(next);
            cores.push(CpuCore {
                id,
                current_pct: Some(round_pct(utilization)),
                one_minute_pct: Some(round_pct(next[0])),
                five_minute_pct: Some(round_pct(next[1])),
                fifteen_minute_pct: Some(round_pct(next[2])),
            });
        }
        Cpu { cores }
    }
}
fn round_pct(value: f64) -> u8 {
    value.round().clamp(0.0, 100.0) as u8
}
fn read_proc_stat() -> io::Result<String> {
    fs::read_to_string("/proc/stat")
}
fn parse_proc_stat(raw: &str) -> io::Result<BTreeMap<u32, Counters>> {
    let mut cores = BTreeMap::new();
    for line in raw.lines() {
        let Some(label) = line.split_whitespace().next() else {
            continue;
        };
        if label == "cpu" || !label.starts_with("cpu") {
            continue;
        }
        let suffix = &label[3..];
        if suffix.is_empty() || !suffix.bytes().all(|byte| byte.is_ascii_digit()) {
            return Err(invalid("invalid CPU label"));
        }
        let id = suffix
            .parse::<u32>()
            .map_err(|error| invalid(error.to_string()))?;
        let values = line
            .split_whitespace()
            .skip(1)
            .map(|value| {
                value
                    .parse::<u64>()
                    .map_err(|error| invalid(error.to_string()))
            })
            .collect::<Result<Vec<_>, _>>()?;
        if values.len() < 8 {
            return Err(invalid("missing CPU counters"));
        }
        let total = values[..8]
            .iter()
            .try_fold(0_u64, |sum, value| sum.checked_add(*value))
            .ok_or_else(|| invalid("CPU counter overflow"))?;
        let idle = values[3]
            .checked_add(values[4])
            .ok_or_else(|| invalid("CPU idle overflow"))?;
        if cores.insert(id, Counters { total, idle }).is_some() {
            return Err(invalid("duplicate CPU ID"));
        }
    }
    if cores.is_empty() {
        return Err(invalid("no per-core counters"));
    }
    Ok(cores)
}
fn invalid(message: impl Into<String>) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message.into())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;
    fn c(total: u64, idle: u64) -> Counters {
        Counters { total, idle }
    }
    fn m(entries: &[(u32, Counters)]) -> BTreeMap<u32, Counters> {
        entries.iter().copied().collect()
    }
    #[test]
    fn parser_orders_ids_excludes_guest_and_counts_iowait_idle() {
        let p = parse_proc_stat(
            "cpu 1 1 1 1 1 1 1 1\ncpu2 10 2 3 20 5 1 2 4 99 99\nintr 1\ncpu0 1 2 3 4 5 6 7 8\n",
        )
        .unwrap();
        assert_eq!(p.keys().copied().collect::<Vec<_>>(), vec![0, 2]);
        assert_eq!(
            p[&2],
            Counters {
                total: 47,
                idle: 25
            }
        );
    }
    #[test]
    fn parser_rejects_invalid_sets() {
        for raw in [
            "",
            "cpu 1 2 3 4 5 6 7 8\n",
            "cpuX 1 2 3 4 5 6 7 8\n",
            "cpu0 1 2\n",
            "cpu0 1 2 3 4 5 6 7 8\ncpu0 1 2 3 4 5 6 7 8\n",
            "cpu0 18446744073709551615 1 0 0 0 0 0 0\n",
        ] {
            assert!(parse_proc_stat(raw).is_err(), "{raw}");
        }
    }
    #[test]
    fn derives_utilization_and_seeds_ewmas() {
        let t = Instant::now();
        let mut s = CpuSampler::new();
        s.observe(m(&[(0, c(100, 50)), (1, c(100, 50)), (2, c(100, 50))]), t);
        let cpu = s.observe(
            m(&[(0, c(200, 150)), (1, c(200, 125)), (2, c(200, 50))]),
            t + Duration::from_secs(2),
        );
        assert_eq!(
            cpu.cores.iter().map(|x| x.current_pct).collect::<Vec<_>>(),
            vec![Some(0), Some(25), Some(100)]
        );
        assert!(cpu.cores.iter().all(|x| x.one_minute_pct == x.current_pct
            && x.five_minute_pct == x.current_pct
            && x.fifteen_minute_pct == x.current_pct));
    }
    #[test]
    fn actual_elapsed_time_drives_raw_ewma() {
        let t = Instant::now();
        let mut s = CpuSampler::new();
        s.observe(m(&[(0, c(100, 100))]), t);
        s.observe(m(&[(0, c(200, 100))]), t + Duration::from_secs(1));
        let cpu = s.observe(m(&[(0, c(300, 200))]), t + Duration::from_secs(61));
        let raw = s.trackers[&0].ewma.unwrap();
        for (index, tau) in [60.0_f64, 300.0, 900.0].iter().enumerate() {
            let expected = 100.0 * (-60.0 / tau).exp();
            assert!((raw[index] - expected).abs() < 0.000_001);
        }
        assert_eq!(cpu.cores[0].one_minute_pct, Some(raw[0].round() as u8));
        assert_eq!(cpu.cores[0].five_minute_pct, Some(raw[1].round() as u8));
        assert_eq!(cpu.cores[0].fifteen_minute_pct, Some(raw[2].round() as u8));
    }

    #[test]
    fn rounded_wire_values_never_feed_back_into_ewmas() {
        let t = Instant::now();
        let mut sampler = CpuSampler::new();
        sampler.observe(m(&[(0, c(1_000, 1_000))]), t);
        let seeded = sampler.observe(m(&[(0, c(1_250, 1_249))]), t + Duration::from_secs(1));
        assert_eq!(seeded.cores[0].one_minute_pct, Some(0));
        assert!((sampler.trackers[&0].ewma.unwrap()[0] - 0.4).abs() < 0.000_001);
        sampler.observe(m(&[(0, c(1_500, 1_499))]), t + Duration::from_secs(61));
        assert!(sampler.trackers[&0].ewma.unwrap()[0] > 0.1);
    }
    #[test]
    fn invalid_delta_resets_one_core_and_requires_two_reads() {
        let t = Instant::now();
        let mut s = CpuSampler::new();
        s.observe(m(&[(0, c(100, 50)), (1, c(100, 50))]), t);
        s.observe(
            m(&[(0, c(200, 100)), (1, c(200, 100))]),
            t + Duration::from_secs(1),
        );
        let x = s.observe(
            m(&[(0, c(200, 100)), (1, c(300, 150))]),
            t + Duration::from_secs(2),
        );
        assert_eq!(x.cores[0].current_pct, None);
        assert_eq!(x.cores[1].current_pct, Some(50));
        assert_eq!(
            s.observe(
                m(&[(0, c(300, 150)), (1, c(400, 200))]),
                t + Duration::from_secs(3)
            )
            .cores[0]
                .current_pct,
            None
        );
        assert_eq!(
            s.observe(
                m(&[(0, c(400, 200)), (1, c(500, 250))]),
                t + Duration::from_secs(4)
            )
            .cores[0]
                .current_pct,
            Some(50)
        );
    }

    #[test]
    fn negative_total_delta_resets_and_whole_failure_restarts_baseline() {
        let t = Instant::now();
        let mut sampler = CpuSampler::new();
        sampler.observe(m(&[(0, c(200, 100))]), t);
        assert_eq!(
            sampler
                .observe(m(&[(0, c(100, 50))]), t + Duration::from_secs(1))
                .cores[0]
                .current_pct,
            None
        );
        assert_eq!(
            sampler
                .observe(m(&[(0, c(150, 75))]), t + Duration::from_secs(2))
                .cores[0]
                .current_pct,
            None
        );
        assert_eq!(
            sampler
                .observe(m(&[(0, c(200, 100))]), t + Duration::from_secs(3))
                .cores[0]
                .current_pct,
            Some(50)
        );
        sampler.clear();
        assert_eq!(
            sampler
                .observe(m(&[(0, c(300, 150))]), t + Duration::from_secs(4))
                .cores[0]
                .current_pct,
            None
        );
        assert_eq!(
            sampler
                .observe(m(&[(0, c(400, 200))]), t + Duration::from_secs(5))
                .cores[0]
                .current_pct,
            Some(50)
        );
    }
    #[test]
    fn decreasing_idle_clamps_without_reset() {
        let t = Instant::now();
        let mut s = CpuSampler::new();
        s.observe(m(&[(0, c(100, 90))]), t);
        s.observe(m(&[(0, c(110, 80))]), t + Duration::from_secs(1));
        assert_eq!(s.trackers[&0].ewma, Some([100.0; 3]));
    }
    #[test]
    fn topology_and_failure_clear_history() {
        let t = Instant::now();
        let mut s = CpuSampler::new();
        assert_eq!(
            s.observe(m(&[(2, c(100, 50))]), t).cores,
            vec![Tracker::baseline(2)]
        );
        assert_eq!(
            s.observe(m(&[(0, c(100, 50))]), t + Duration::from_secs(1))
                .cores,
            vec![Tracker::baseline(0)]
        );
        assert!(s.clear().cores.is_empty());
        assert!(s.trackers.is_empty());
    }
}
