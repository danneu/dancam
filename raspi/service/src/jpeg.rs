#[derive(Default)]
pub struct JpegSplitter {
    buffer: Vec<u8>,
}

impl JpegSplitter {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn push(&mut self, bytes: &[u8]) -> Vec<Vec<u8>> {
        self.buffer.extend_from_slice(bytes);

        let mut frames = Vec::new();
        while let Some(frame) = self.next_frame() {
            frames.push(frame);
        }

        frames
    }

    fn next_frame(&mut self) -> Option<Vec<u8>> {
        let soi = find_marker(&self.buffer, [0xff, 0xd8])?;
        if soi > 0 {
            self.buffer.drain(..soi);
        }

        let eoi = find_marker_from(&self.buffer, [0xff, 0xd9], 2)?;
        Some(self.buffer.drain(..eoi + 2).collect())
    }
}

fn find_marker(bytes: &[u8], marker: [u8; 2]) -> Option<usize> {
    find_marker_from(bytes, marker, 0)
}

fn find_marker_from(bytes: &[u8], marker: [u8; 2], start: usize) -> Option<usize> {
    bytes
        .windows(2)
        .enumerate()
        .skip(start)
        .find_map(|(index, pair)| (pair == marker).then_some(index))
}

#[cfg(test)]
mod tests {
    use super::JpegSplitter;

    const F0: &[u8] = &[0xff, 0xd8, 0x00, 0x01, 0xff, 0xd9];
    const F1: &[u8] = &[0xff, 0xd8, 0x02, 0x03, 0xff, 0xd9];

    #[test]
    fn splits_single_frame() {
        let mut splitter = JpegSplitter::new();

        assert_eq!(splitter.push(F0), vec![F0.to_vec()]);
    }

    #[test]
    fn splits_two_frames_in_one_push() {
        let mut splitter = JpegSplitter::new();

        let mut bytes = Vec::new();
        bytes.extend_from_slice(F0);
        bytes.extend_from_slice(F1);

        assert_eq!(splitter.push(&bytes), vec![F0.to_vec(), F1.to_vec()]);
    }

    #[test]
    fn reassembles_frame_split_across_pushes() {
        let mut splitter = JpegSplitter::new();

        assert!(splitter.push(&F0[..3]).is_empty());
        assert_eq!(splitter.push(&F0[3..]), vec![F0.to_vec()]);
    }

    #[test]
    fn retains_partial_trailing_frame() {
        let mut splitter = JpegSplitter::new();

        let mut bytes = Vec::new();
        bytes.extend_from_slice(F0);
        bytes.extend_from_slice(&F1[..3]);

        assert_eq!(splitter.push(&bytes), vec![F0.to_vec()]);
        assert_eq!(splitter.push(&F1[3..]), vec![F1.to_vec()]);
    }

    #[test]
    fn skips_garbage_before_first_soi() {
        let mut splitter = JpegSplitter::new();

        let mut bytes = vec![0x00, 0x01, 0x02];
        bytes.extend_from_slice(F0);

        assert_eq!(splitter.push(&bytes), vec![F0.to_vec()]);
    }

    #[test]
    fn empty_buffer_yields_none() {
        let mut splitter = JpegSplitter::new();

        assert!(splitter.push(&[]).is_empty());
    }
}
