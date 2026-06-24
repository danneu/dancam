pub trait Backend: Send + Sync + 'static {
    fn recording(&self) -> bool;
}

pub struct MockBackend;

impl Backend for MockBackend {
    fn recording(&self) -> bool {
        false
    }
}
