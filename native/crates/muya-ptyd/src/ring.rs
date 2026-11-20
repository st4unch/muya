//! Bounded, memory-only output history per session (PRD §5; never written to disk, AC23).
//! One fixed allocation: a growable deque doubled its capacity on overflow (Faz 0 S9: 2 MB per
//! session instead of 1 MB).

pub const RING_BYTES: usize = 1 << 20;

pub struct Ring {
    buf: Box<[u8]>,
    head: usize,
    len: usize,
    /// Sequence number of the first byte kept.
    pub start: u64,
}

impl Default for Ring {
    fn default() -> Self {
        Self::with_capacity(RING_BYTES)
    }
}

impl Ring {
    pub fn with_capacity(cap: usize) -> Self {
        Self {
            buf: vec![0; cap].into_boxed_slice(),
            head: 0,
            len: 0,
            start: 0,
        }
    }

    fn cap(&self) -> usize {
        self.buf.len()
    }

    pub fn push(&mut self, mut data: &[u8]) {
        let cap = self.cap();
        if data.len() > cap {
            self.start += (self.len + data.len() - cap) as u64;
            self.len = 0;
            data = &data[data.len() - cap..];
        }
        let n = data.len();
        let first = n.min(cap - self.head);
        self.buf[self.head..self.head + first].copy_from_slice(&data[..first]);
        self.buf[..n - first].copy_from_slice(&data[first..]);
        self.head = (self.head + n) % cap;
        self.start += (self.len + n).saturating_sub(cap) as u64;
        self.len = (self.len + n).min(cap);
    }

    /// Sequence number one past the last byte.
    pub fn end(&self) -> u64 {
        self.start + self.len as u64
    }

    pub fn contents(&self) -> Vec<u8> {
        let cap = self.cap();
        let tail = (self.head + cap - self.len) % cap;
        let mut out = Vec::with_capacity(self.len);
        if tail + self.len <= cap {
            out.extend_from_slice(&self.buf[tail..tail + self.len]);
        } else {
            out.extend_from_slice(&self.buf[tail..]);
            out.extend_from_slice(&self.buf[..self.head]);
        }
        out
    }

    /// Overwrites the kept bytes with zeros (session end: no terminal content lingers in memory).
    pub fn wipe(&mut self) {
        self.buf.fill(0);
        self.len = 0;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matches_a_reference_on_random_pushes() {
        let mut r = Ring::with_capacity(4096);
        let mut all = Vec::new();
        let mut seed = 7u64;
        for _ in 0..5000 {
            seed = seed
                .wrapping_mul(6364136223846793005)
                .wrapping_add(1442695040888963407);
            let n = (seed >> 33) as usize % 300 + if seed % 97 == 0 { 5000 } else { 0 };
            let chunk: Vec<u8> = (0..n).map(|i| (i as u64 ^ seed) as u8).collect();
            r.push(&chunk);
            all.extend_from_slice(&chunk);
            let keep = all.len().min(4096);
            assert_eq!(r.end(), all.len() as u64);
            assert_eq!(r.start, (all.len() - keep) as u64);
        }
        assert_eq!(r.contents(), &all[all.len() - 4096..]);
    }

    #[test]
    fn default_ring_is_one_megabyte_and_wipe_clears() {
        let mut r = Ring::default();
        r.push(b"secret");
        assert_eq!(r.contents(), b"secret");
        r.wipe();
        assert!(r.contents().is_empty());
        assert_eq!(r.end(), r.start);
    }
}
