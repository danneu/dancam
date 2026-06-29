use std::{
    collections::HashMap,
    fs::File,
    io::{Read, Seek, SeekFrom},
    path::Path,
    sync::Mutex,
};

const PACKET_SIZE: usize = 188;
const TS_SYNC: u8 = 0x47;
const TS_CLOCK_HZ: u64 = 90_000;
const HEAD_WINDOW: u64 = 256 * 1024;
const TAIL_WINDOW: u64 = 512 * 1024;

#[derive(Debug, PartialEq, Eq)]
struct PtsSpan {
    min: u64,
    max: u64,
    frame_interval: u64,
}

pub(crate) struct DurationCache {
    entries: Mutex<HashMap<u32, (u64, Option<u64>)>>,
}

impl DurationCache {
    pub(crate) fn new() -> Self {
        Self {
            entries: Mutex::new(HashMap::new()),
        }
    }

    pub(crate) fn duration_ms(&self, seq: u32, path: &Path, bytes: u64) -> Option<u64> {
        {
            let entries = self.entries.lock().expect("duration cache mutex poisoned");
            if let Some((cached_bytes, dur_ms)) = entries.get(&seq) {
                if *cached_bytes == bytes {
                    return *dur_ms;
                }
            }
        }

        let dur_ms = segment_duration_ms(path, bytes);
        self.entries
            .lock()
            .expect("duration cache mutex poisoned")
            .insert(seq, (bytes, dur_ms));
        dur_ms
    }
}

impl Default for DurationCache {
    fn default() -> Self {
        Self::new()
    }
}

fn segment_duration_ms(path: &Path, bytes: u64) -> Option<u64> {
    duration_ms_from_span(segment_pts_span(path, bytes)?)
}

fn segment_pts_span(path: &Path, bytes: u64) -> Option<PtsSpan> {
    if bytes <= HEAD_WINDOW + TAIL_WINDOW {
        return scan_pts_bounds(&std::fs::read(path).ok()?);
    }

    let mut file = File::open(path).ok()?;
    let head = read_window(&mut file, 0, usize::try_from(HEAD_WINDOW).ok()?)?;
    let tail_off = tail_window_offset(bytes);
    let tail_len = usize::try_from(bytes.checked_sub(tail_off)?).ok()?;
    let tail = read_window(&mut file, tail_off, tail_len)?;

    let head_span = scan_pts_bounds(&head)?;
    let tail_span = scan_pts_bounds(&tail)?;
    let frame_interval = if tail_span.frame_interval > 0 {
        tail_span.frame_interval
    } else {
        head_span.frame_interval
    };

    Some(PtsSpan {
        min: head_span.min,
        max: tail_span.max,
        frame_interval,
    })
}

fn read_window(file: &mut File, offset: u64, len: usize) -> Option<Vec<u8>> {
    let mut buf = vec![0; len];
    file.seek(SeekFrom::Start(offset)).ok()?;
    file.read_exact(&mut buf).ok()?;
    Some(buf)
}

fn tail_window_offset(bytes: u64) -> u64 {
    (bytes.saturating_sub(TAIL_WINDOW) / PACKET_SIZE as u64) * PACKET_SIZE as u64
}

fn duration_ms_from_span(span: PtsSpan) -> Option<u64> {
    if span.max <= span.min || span.frame_interval == 0 {
        return None;
    }

    let ticks = span
        .max
        .checked_sub(span.min)?
        .checked_add(span.frame_interval)?;
    ticks
        .checked_mul(1000)
        .map(|ms_ticks| ms_ticks / TS_CLOCK_HZ)
}

fn scan_pts_bounds(buf: &[u8]) -> Option<PtsSpan> {
    let mut pts_values = Vec::new();

    for packet in buf.chunks_exact(PACKET_SIZE) {
        if packet[0] != TS_SYNC || packet[1] & 0x80 != 0 || packet[1] & 0x40 == 0 {
            continue;
        }

        let adaptation_field_control = (packet[3] & 0x30) >> 4;
        let payload_offset = match adaptation_field_control {
            1 => 4,
            2 | 0 => continue,
            3 => {
                let offset = 5usize.checked_add(packet[4] as usize)?;
                if offset > PACKET_SIZE {
                    continue;
                }
                offset
            }
            _ => continue,
        };

        if let Some(pts) = pts_from_pes_payload(&packet[payload_offset..]) {
            pts_values.push(pts);
        }
    }

    if pts_values.is_empty() {
        return None;
    }

    pts_values.sort_unstable();
    pts_values.dedup();

    let min = pts_values[0];
    let max = *pts_values.last().expect("pts_values is not empty");
    let frame_interval = pts_values
        .windows(2)
        .map(|window| window[1] - window[0])
        .filter(|delta| *delta > 0)
        .min()
        .unwrap_or(0);

    Some(PtsSpan {
        min,
        max,
        frame_interval,
    })
}

fn pts_from_pes_payload(payload: &[u8]) -> Option<u64> {
    if payload.len() < 14 || payload[0..3] != [0, 0, 1] {
        return None;
    }
    if !(0xe0..=0xef).contains(&payload[3]) {
        return None;
    }

    let pts_dts_flags = (payload[7] & 0xc0) >> 6;
    if pts_dts_flags != 0b10 && pts_dts_flags != 0b11 {
        return None;
    }

    let pes_header_len = payload[8] as usize;
    if pes_header_len < 5 || 9usize.checked_add(pes_header_len)? > payload.len() {
        return None;
    }

    decode_pts(&payload[9..14], pts_dts_flags)
}

fn decode_pts(bytes: &[u8], pts_dts_flags: u8) -> Option<u64> {
    let expected_prefix = match pts_dts_flags {
        0b10 => 0x20,
        0b11 => 0x30,
        _ => return None,
    };
    if bytes.len() != 5
        || bytes[0] & 0xf0 != expected_prefix
        || bytes[0] & 0x01 == 0
        || bytes[2] & 0x01 == 0
        || bytes[4] & 0x01 == 0
    {
        return None;
    }

    let high = u64::from((bytes[0] >> 1) & 0x07) << 30;
    let middle = (u64::from(bytes[1]) << 7 | u64::from(bytes[2] >> 1)) << 15;
    let low = u64::from(bytes[3]) << 7 | u64::from(bytes[4] >> 1);
    Some(high | middle | low)
}

#[cfg(test)]
mod tests {
    use super::{
        scan_pts_bounds, segment_duration_ms, segment_pts_span, tail_window_offset, DurationCache,
        PtsSpan, HEAD_WINDOW, PACKET_SIZE, TAIL_WINDOW,
    };
    use std::{
        fs,
        path::{Path, PathBuf},
    };

    #[test]
    fn scan_pts_bounds_extracts_span_and_frame_interval() {
        let buf = pts_buffer(&[0, 3000, 6000]);

        assert_eq!(
            scan_pts_bounds(&buf),
            Some(PtsSpan {
                min: 0,
                max: 6000,
                frame_interval: 3000,
            })
        );

        let temp = TempFile::write("three-pts.ts", &buf);
        assert_eq!(segment_duration_ms(&temp.path, buf.len() as u64), Some(100));
    }

    #[test]
    fn returns_none_for_garbage_empty_truncated_and_single_pts_segments() {
        assert_eq!(scan_pts_bounds(b"zero"), None);

        let garbage = TempFile::write("garbage.ts", b"zero");
        assert_eq!(segment_duration_ms(&garbage.path, 4), None);

        let empty = TempFile::write("empty.ts", b"");
        assert_eq!(segment_duration_ms(&empty.path, 0), None);

        let truncated = truncated_pes_packet();
        assert_eq!(scan_pts_bounds(&truncated), None);

        let single = pts_buffer(&[3000]);
        let single_file = TempFile::write("single.ts", &single);
        assert_eq!(
            segment_duration_ms(&single_file.path, single.len() as u64),
            None
        );
    }

    #[test]
    fn large_file_uses_head_min_and_tail_max() {
        let tail_base = 90_000 * 45;
        let mut buf = null_packet_buffer(((HEAD_WINDOW + TAIL_WINDOW) as usize / PACKET_SIZE) + 20);
        put_pts_packet(&mut buf, 0, 0);
        put_pts_packet(&mut buf, 1, 3000);
        put_pts_packet(&mut buf, 2, 6000);

        let tail_packet = tail_window_offset(buf.len() as u64) as usize / PACKET_SIZE;
        put_pts_packet(&mut buf, tail_packet, tail_base);
        put_pts_packet(&mut buf, tail_packet + 1, tail_base + 3000);
        put_pts_packet(&mut buf, tail_packet + 2, tail_base + 6000);

        let temp = TempFile::write("large.ts", &buf);

        assert_eq!(
            segment_pts_span(&temp.path, buf.len() as u64),
            Some(PtsSpan {
                min: 0,
                max: tail_base + 6000,
                frame_interval: 3000,
            })
        );
        assert_eq!(
            segment_duration_ms(&temp.path, buf.len() as u64),
            Some(((tail_base + 6000) + 3000) * 1000 / 90_000)
        );
    }

    #[test]
    fn large_file_returns_none_when_tail_has_no_pts() {
        let garbage = null_packet_buffer(((HEAD_WINDOW + TAIL_WINDOW) as usize / PACKET_SIZE) + 20);
        let garbage_file = TempFile::write("large-garbage.ts", &garbage);
        assert_eq!(
            segment_duration_ms(&garbage_file.path, garbage.len() as u64),
            None
        );

        let mut head_only = garbage;
        put_pts_packet(&mut head_only, 0, 0);
        put_pts_packet(&mut head_only, 1, 3000);
        put_pts_packet(&mut head_only, 2, 6000);
        let head_only_file = TempFile::write("head-only.ts", &head_only);
        assert_eq!(
            segment_duration_ms(&head_only_file.path, head_only.len() as u64),
            None
        );
    }

    #[test]
    fn large_file_borrows_head_interval_when_tail_has_one_pts() {
        let tail_pts = 90_000 * 45;
        let mut buf = null_packet_buffer(((HEAD_WINDOW + TAIL_WINDOW) as usize / PACKET_SIZE) + 20);
        put_pts_packet(&mut buf, 0, 0);
        put_pts_packet(&mut buf, 1, 3000);
        put_pts_packet(&mut buf, 2, 6000);

        let tail_packet = tail_window_offset(buf.len() as u64) as usize / PACKET_SIZE;
        put_pts_packet(&mut buf, tail_packet, tail_pts);

        let temp = TempFile::write("tail-single-pts.ts", &buf);

        assert_eq!(
            segment_pts_span(&temp.path, buf.len() as u64),
            Some(PtsSpan {
                min: 0,
                max: tail_pts,
                frame_interval: 3000,
            })
        );
        assert_eq!(
            segment_duration_ms(&temp.path, buf.len() as u64),
            Some((tail_pts + 3000) * 1000 / 90_000)
        );
    }

    #[test]
    fn parses_real_transport_stream_fixture() {
        let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("assets/clips/seg_00000.ts");
        let bytes = fs::metadata(&path).unwrap().len();

        let dur_ms = segment_duration_ms(&path, bytes).unwrap();

        assert!(
            (dur_ms as i64 - 30_000).abs() <= 100,
            "duration was {dur_ms} ms"
        );
    }

    #[test]
    fn duration_cache_keys_by_sequence_and_bytes() {
        let first = pts_buffer(&[0, 3000]);
        let second = pts_buffer(&[0, 3000, 6000]);
        let first_file = TempFile::write("first.ts", &first);
        let second_file = TempFile::write("second.ts", &second);
        let cache = DurationCache::new();

        assert_eq!(
            cache.duration_ms(1, &first_file.path, first.len() as u64),
            Some(66)
        );
        assert_eq!(
            cache.duration_ms(1, &second_file.path, second.len() as u64),
            Some(100)
        );
        assert_eq!(
            cache.duration_ms(2, &first_file.path, first.len() as u64),
            Some(66)
        );
    }

    fn pts_buffer(values: &[u64]) -> Vec<u8> {
        let mut buf = Vec::with_capacity(values.len() * PACKET_SIZE);
        for value in values {
            buf.extend_from_slice(&pts_packet(*value));
        }
        buf
    }

    fn pts_packet(pts: u64) -> [u8; PACKET_SIZE] {
        let mut packet = [0xff; PACKET_SIZE];
        packet[0] = 0x47;
        packet[1] = 0x40;
        packet[2] = 0x00;
        packet[3] = 0x10;

        let payload = &mut packet[4..];
        payload[0..9].copy_from_slice(&[0x00, 0x00, 0x01, 0xe0, 0x00, 0x00, 0x80, 0x80, 0x05]);
        payload[9..14].copy_from_slice(&encode_pts(pts));
        packet
    }

    fn encode_pts(pts: u64) -> [u8; 5] {
        [
            0x20 | (((pts >> 30) as u8 & 0x07) << 1) | 0x01,
            (pts >> 22) as u8,
            (((pts >> 15) as u8 & 0x7f) << 1) | 0x01,
            (pts >> 7) as u8,
            ((pts as u8 & 0x7f) << 1) | 0x01,
        ]
    }

    fn truncated_pes_packet() -> [u8; PACKET_SIZE] {
        let mut packet = null_packet();
        packet[1] = 0x40;
        packet[3] = 0x30;
        packet[4] = 170;
        let payload = &mut packet[175..];
        payload.copy_from_slice(&[
            0x00, 0x00, 0x01, 0xe0, 0x00, 0x00, 0x80, 0x80, 0x05, 0x21, 0x00, 0x01, 0x00,
        ]);
        packet
    }

    fn null_packet_buffer(packet_count: usize) -> Vec<u8> {
        let packet = null_packet();
        let mut buf = Vec::with_capacity(packet_count * PACKET_SIZE);
        for _ in 0..packet_count {
            buf.extend_from_slice(&packet);
        }
        buf
    }

    fn null_packet() -> [u8; PACKET_SIZE] {
        let mut packet = [0xff; PACKET_SIZE];
        packet[0] = 0x47;
        packet[1] = 0x1f;
        packet[2] = 0xff;
        packet[3] = 0x10;
        packet
    }

    fn put_pts_packet(buf: &mut [u8], packet_index: usize, pts: u64) {
        let start = packet_index * PACKET_SIZE;
        buf[start..start + PACKET_SIZE].copy_from_slice(&pts_packet(pts));
    }

    struct TempFile {
        dir: PathBuf,
        path: PathBuf,
    }

    impl TempFile {
        fn write(name: &str, bytes: &[u8]) -> Self {
            let dir =
                std::env::temp_dir().join(format!("dancam-ts-duration-{}", uuid::Uuid::new_v4()));
            fs::create_dir(&dir).unwrap();
            let path = dir.join(name);
            fs::write(&path, bytes).unwrap();
            Self { dir, path }
        }
    }

    impl Drop for TempFile {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.dir);
        }
    }
}
