//! Standalone offline-only Rust IPC fixture. Compiled by the test harness,
//! never registered as a Cargo binary and never included in release builds.
use std::io::{self, Read, Write};

fn read_frame(input: &mut impl Read) -> io::Result<String> {
    let mut header = [0u8; 4];
    input.read_exact(&mut header)?;
    let len = u32::from_be_bytes(header) as usize;
    if len == 0 || len > 65536 {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "length"));
    }
    let mut bytes = vec![0u8; len];
    input.read_exact(&mut bytes)?;
    String::from_utf8(bytes).map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "utf8"))
}
fn send(output: &mut impl Write, body: &str) -> io::Result<()> {
    output.write_all(&(body.len() as u32).to_be_bytes())?;
    output.write_all(body.as_bytes())?;
    output.flush()
}
fn run() -> io::Result<()> {
    let mut input = io::stdin().lock();
    let mut output = io::stdout().lock();
    let start = read_frame(&mut input)?;
    if start != r#"{"identifier":"mock","spim":"mock","type":"start","version":1}"# {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "start"));
    }
    send(&mut output, r#"{"version":1,"type":"started","cpim":"mock"}"#)?;
    let finish = read_frame(&mut input)?;
    if finish != r#"{"ptm":"mock","tk":"mock","type":"finish","version":1}"# {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "finish"));
    }
    let mut trailing = [0u8; 1];
    if input.read(&mut trailing)? != 0 {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "trailing"));
    }
    send(&mut output, r#"{"version":1,"type":"finished","adi_pb":"mock"}"#)
}
fn run_v2() -> io::Result<()> {
    let mut input = io::stdin().lock();
    let mut output = io::stdout().lock();
    let start = read_frame(&mut input)?;
    if start != r#"{"identifier":"-2","spim_hex":"00ff","type":"start","version":2}"# { return Err(io::Error::new(io::ErrorKind::InvalidData, "v2 start")); }
    send(&mut output, r#"{"version":2,"type":"started","cpim_hex":"00ff"}"#)?;
    let finish = read_frame(&mut input)?;
    if finish != r#"{"ptm_hex":"ff00","tk_hex":"80","type":"finish","version":2}"# { return Err(io::Error::new(io::ErrorKind::InvalidData, "v2 finish")); }
    let mut trailing = [0u8; 1];
    if input.read(&mut trailing)? != 0 { return Err(io::Error::new(io::ErrorKind::InvalidData, "v2 trailing")); }
    send(&mut output, r#"{"version":2,"type":"finished","adi_pb_hex":"ff00"}"#)
}
fn main() {
    let result = match std::env::args().nth(1).as_deref() {
        Some("--v2") => run_v2(),
        Some("--v2-stall") => {
            let mut input = io::stdin().lock();
            let _ = read_frame(&mut input);
            std::thread::sleep(std::time::Duration::from_secs(30));
            Ok(())
        }
        _ => run(),
    };
    if result.is_err() { std::process::exit(1); }
}
