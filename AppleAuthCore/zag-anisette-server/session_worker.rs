//! Offline-only, session-scoped worker protocol prototype.
//! No Apple APIs, native libraries, sockets, or credentials.
use std::io::{self, BufRead, Read, Write};

const MAX_FRAME: usize = 64 * 1024;

pub trait SessionBackend {
    fn start(&mut self, identifier: &str, spim: &str) -> Result<String, &'static str>;
    fn finish(&mut self, ptm: &str, tk: &str) -> Result<String, &'static str>;
    fn cancel(&mut self);
}

#[derive(Default)]
pub struct MockBackend {
    active: bool,
    cancelled: bool,
}
impl SessionBackend for MockBackend {
    fn start(&mut self, identifier: &str, spim: &str) -> Result<String, &'static str> {
        if self.active || identifier.is_empty() || spim.is_empty() { return Err("invalid_state"); }
        self.active = true;
        Ok("offline-cpim".into())
    }
    fn finish(&mut self, ptm: &str, tk: &str) -> Result<String, &'static str> {
        if !self.active || ptm.is_empty() || tk.is_empty() { return Err("invalid_state"); }
        self.active = false;
        Ok("offline-adi-pb".into())
    }
    fn cancel(&mut self) { self.active = false; self.cancelled = true; }
}

#[derive(Debug, PartialEq, Eq)]
pub enum Phase { AwaitStart, AwaitFinish, Completed, Cancelled }

pub struct Session<B: SessionBackend> {
    backend: B,
    phase: Phase,
    deadline: Instant,
}
impl<B: SessionBackend> Session<B> {
    pub fn new(backend: B) -> Self { Self::with_timeout(backend, Duration::from_secs(10)) }
    pub fn with_timeout(backend: B, timeout: Duration) -> Self {
        Self { backend, phase: Phase::AwaitStart, deadline: Instant::now() + timeout }
    }
    fn ensure_live(&mut self) -> Result<(), &'static str> {
        if Instant::now() >= self.deadline { self.cancel(); Err("expired") } else { Ok(()) }
    }
    pub fn phase(&self) -> &Phase { &self.phase }
    pub fn start(&mut self, identifier: &str, spim: &str) -> Result<String, &'static str> {
        self.ensure_live()?;
        if self.phase != Phase::AwaitStart { return Err("invalid_state"); }
        match self.backend.start(identifier, spim) {
            Ok(cpim) => { self.phase = Phase::AwaitFinish; Ok(cpim) }
            Err(e) => { self.cancel(); Err(e) }
        }
    }
    pub fn finish(&mut self, ptm: &str, tk: &str) -> Result<String, &'static str> {
        self.ensure_live()?;
        if self.phase != Phase::AwaitFinish { return Err("invalid_state"); }
        match self.backend.finish(ptm, tk) {
            Ok(adi_pb) => { self.phase = Phase::Completed; Ok(adi_pb) }
            Err(e) => { self.cancel(); Err(e) }
        }
    }
    pub fn cancel(&mut self) {
        if self.phase != Phase::Completed && self.phase != Phase::Cancelled {
            self.backend.cancel();
            self.phase = Phase::Cancelled;
        }
    }
}
impl<B: SessionBackend> Drop for Session<B> {
    fn drop(&mut self) { self.cancel(); }
}

// Transport prototype: bounded, line-delimited JSON over an already trusted
// pipe. This is deliberately NOT wired into the production IPC or HTTP server.
pub fn serve_mock<R: BufRead, W: Write>(mut input: R, mut output: W) -> io::Result<()> {
    let mut session = Session::new(MockBackend::default());
    loop {
        let mut line = Vec::new();
        let bytes = input.by_ref().take((MAX_FRAME + 1) as u64).read_until(b'\n', &mut line)?;
        if bytes == 0 { return Ok(()); }
        if line.len() > MAX_FRAME || !line.ends_with(b"\n") {
            session.cancel();
            return Err(io::Error::new(io::ErrorKind::InvalidData, "invalid frame"));
        }
        let value: serde_json::Value = serde_json::from_slice(&line)
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "invalid json"))?;
        let obj = value.as_object().ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "invalid object"))?;
        let kind = obj.get("type").and_then(serde_json::Value::as_str).unwrap_or("");
        let field = |key: &str| obj.get(key).and_then(serde_json::Value::as_str).unwrap_or("");
        let result = match kind {
            "start" if obj.len() == 3 => session.start(field("identifier"), field("spim")).map(|v| ("started", v)),
            "finish" if obj.len() == 3 => session.finish(field("ptm"), field("tk")).map(|v| ("finished", v)),
            "cancel" if obj.len() == 1 => { session.cancel(); return Ok(()); },
            _ => { session.cancel(); Err("invalid_request") },
        };
        let response = match result {
            Ok((kind, value)) => serde_json::json!({"type":kind,"value":value}),
            Err(_) => serde_json::json!({"type":"error","code":"invalid_state"}),
        };
        serde_json::to_writer(&mut output, &response)?;
        output.write_all(b"\n")?;
        output.flush()?;
        if session.phase() != &Phase::AwaitFinish { return Ok(()); }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn full_session_and_cleanup() {
        let mut s = Session::new(MockBackend::default());
        assert_eq!(s.start("id", "spim"), Ok("offline-cpim".into()));
        assert_eq!(s.finish("ptm", "tk"), Ok("offline-adi-pb".into()));
        assert_eq!(s.phase(), &Phase::Completed);
        assert_eq!(s.finish("ptm", "tk"), Err("invalid_state"));
    }
    #[test]
    fn cancel_prevents_finish() {
        let mut s = Session::new(MockBackend::default());
        assert!(s.start("id", "spim").is_ok());
        s.cancel();
        assert_eq!(s.phase(), &Phase::Cancelled);
        assert_eq!(s.finish("ptm", "tk"), Err("invalid_state"));
    }
    #[test]
    fn invalid_start_fails_closed() {
        let mut s = Session::new(MockBackend::default());
        assert_eq!(s.start("", "spim"), Err("invalid_state"));
        assert_eq!(s.phase(), &Phase::Cancelled);
    }
    #[test]
    fn oversized_line_is_rejected_without_response() {
        let mut input = vec![b'x'; MAX_FRAME + 1];
        input.push(b'\n');
        let mut output = Vec::new();
        assert!(serve_mock(&input[..], &mut output).is_err());
        assert!(output.is_empty());
    }
    #[test]
    fn incomplete_line_is_rejected_without_response() {
        let mut output = Vec::new();
        assert!(serve_mock(&b"{\"type\":\"start\"}"[..], &mut output).is_err());
        assert!(output.is_empty());
    }
    #[test]
    fn finish_before_start_fails_closed() {
        let input = b"{\"type\":\"finish\",\"ptm\":\"ptm\",\"tk\":\"tk\"}\n";
        let mut output = Vec::new();
        serve_mock(&input[..], &mut output).unwrap();
        let response: serde_json::Value = serde_json::from_slice(&output).unwrap();
        assert_eq!(response["type"], "error");
    }
    #[test]
    fn expired_session_cancels_before_native_finish() {
        let mut s = Session::with_timeout(MockBackend::default(), Duration::ZERO);
        assert_eq!(s.start("id", "spim"), Err("expired"));
        assert_eq!(s.phase(), &Phase::Cancelled);
        assert_eq!(s.finish("ptm", "tk"), Err("expired"));
    }
    #[test]
    fn framed_mock_roundtrip() {
        let input = b"{\"type\":\"start\",\"identifier\":\"id\",\"spim\":\"spim\"}\n{\"type\":\"finish\",\"ptm\":\"ptm\",\"tk\":\"tk\"}\n";
        let mut output = Vec::new();
        serve_mock(&input[..], &mut output).unwrap();
        let messages: Vec<serde_json::Value> = output.split(|&b| b == b'\n').filter(|s| !s.is_empty())
            .map(|s| serde_json::from_slice(s).unwrap()).collect();
        assert_eq!(messages.len(), 2);
        assert_eq!(messages[0]["type"], "started");
        assert_eq!(messages[1]["type"], "finished");
    }
}
