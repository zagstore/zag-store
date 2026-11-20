//! Bounded length-prefixed IPC framing for an offline ADI worker.
//! This is not connected to the HTTP listener or to an executable.
//! The caller must enforce a process deadline and kill/reap the worker on timeout.
#![allow(dead_code)]
use std::io::{self, Read, Write};
use crate::adi_worker_protocol::MAX_MESSAGE_BYTES;

#[derive(Debug, PartialEq, Eq)]
pub enum FrameError {
    Io(io::ErrorKind),
    Empty,
    Oversized,
}

pub fn write_frame<W: Write>(writer: &mut W, payload: &[u8]) -> Result<(), FrameError> {
    if payload.is_empty() { return Err(FrameError::Empty); }
    if payload.len() > MAX_MESSAGE_BYTES { return Err(FrameError::Oversized); }
    let length = u32::try_from(payload.len()).map_err(|_| FrameError::Oversized)?;
    writer.write_all(&length.to_be_bytes()).map_err(|e| FrameError::Io(e.kind()))?;
    writer.write_all(payload).map_err(|e| FrameError::Io(e.kind()))?;
    writer.flush().map_err(|e| FrameError::Io(e.kind()))
}

/// Reads exactly one frame, allocating no more than MAX_MESSAGE_BYTES.
/// A caller must not reuse the stream after an error.
pub fn read_frame<R: Read>(reader: &mut R) -> Result<Vec<u8>, FrameError> {
    let mut header = [0u8; 4];
    reader.read_exact(&mut header).map_err(|e| FrameError::Io(e.kind()))?;
    let length = u32::from_be_bytes(header) as usize;
    if length == 0 { return Err(FrameError::Empty); }
    if length > MAX_MESSAGE_BYTES { return Err(FrameError::Oversized); }
    let mut payload = vec![0u8; length];
    reader.read_exact(&mut payload).map_err(|e| FrameError::Io(e.kind()))?;
    Ok(payload)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn roundtrip_and_exact_maximum() {
        for size in [1, 100, MAX_MESSAGE_BYTES] {
            let input = vec![b'a'; size];
            let mut frame = Vec::new();
            write_frame(&mut frame, &input).unwrap();
            assert_eq!(frame.len(), size + 4);
            assert_eq!(read_frame(&mut frame.as_slice()), Ok(input));
        }
    }
    #[test]
    fn rejects_empty_and_oversized_outbound() {
        assert_eq!(write_frame(&mut Vec::new(), &[]), Err(FrameError::Empty));
        assert_eq!(write_frame(&mut Vec::new(), &vec![0; MAX_MESSAGE_BYTES + 1]), Err(FrameError::Oversized));
    }
    #[test]
    fn rejects_oversized_header_before_allocating_body() {
        let header = ((MAX_MESSAGE_BYTES + 1) as u32).to_be_bytes();
        assert_eq!(read_frame(&mut header.as_slice()), Err(FrameError::Oversized));
        assert_eq!(read_frame(&mut 0u32.to_be_bytes().as_slice()), Err(FrameError::Empty));
    }
    #[test]
    fn truncated_header_and_body_fail_closed() {
        assert_eq!(read_frame(&mut [0u8; 2].as_slice()), Err(FrameError::Io(io::ErrorKind::UnexpectedEof)));
        let mut frame = Vec::from(8u32.to_be_bytes());
        frame.extend_from_slice(b"short");
        assert_eq!(read_frame(&mut frame.as_slice()), Err(FrameError::Io(io::ErrorKind::UnexpectedEof)));
    }
    #[test]
    fn writer_errors_propagate() {
        struct Broken;
        impl Write for Broken {
            fn write(&mut self, _: &[u8]) -> io::Result<usize> { Err(io::ErrorKind::BrokenPipe.into()) }
            fn flush(&mut self) -> io::Result<()> { Ok(()) }
        }
        assert_eq!(write_frame(&mut Broken, b"x"), Err(FrameError::Io(io::ErrorKind::BrokenPipe)));
    }
}
