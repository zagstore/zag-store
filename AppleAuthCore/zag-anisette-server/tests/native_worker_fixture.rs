//! Offline stand-in for the native worker's server-facing modes, compiled
//! by the native_backend tests. Its "OTP" and "state" bytes are labelled
//! fakes: they exercise the server's supervision and v3 encoding only and
//! prove nothing about Apple. Behaviour is chosen by the state or SPIM bytes.
use std::io::{Read, Write};
use std::time::Duration;

fn frame(payload: &str) {
    let mut out = std::io::stdout().lock();
    out.write_all(&(payload.len() as u32).to_be_bytes()).unwrap();
    out.write_all(payload.as_bytes()).unwrap();
    out.flush().unwrap();
}

fn read_frame() -> Option<String> {
    let mut stdin = std::io::stdin().lock();
    let mut length = [0u8; 4];
    stdin.read_exact(&mut length).ok()?;
    let mut payload = vec![0u8; u32::from_be_bytes(length) as usize];
    stdin.read_exact(&mut payload).ok()?;
    String::from_utf8(payload).ok()
}

fn hex(bytes: &[u8]) -> String { bytes.iter().map(|b| format!("{b:02x}")).collect() }

fn unhex(text: &str) -> Vec<u8> {
    (0..text.len()).step_by(2).map(|i| u8::from_str_radix(&text[i..i + 2], 16).unwrap()).collect()
}

fn field(json: &str, name: &str) -> Vec<u8> {
    let key = format!("\"{name}\":\"");
    let start = json.find(&key).unwrap() + key.len();
    unhex(&json[start..start + json[start..].find('"').unwrap()])
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let (runtime, mode, dir, android_id) = (&args[1], args[2].as_str(), &args[3], &args[4]);
    match mode {
        "--native-offline-check" => {
            if runtime.contains("broken-readiness") { std::process::exit(1); }
            println!("PASS: empty state reports NOT_PROVISIONED (-45061) and refuses OTPs; no Apple contact");
        }
        "--native-headers" => {
            let state = String::from_utf8(std::fs::read(format!("{dir}/adi.pb")).unwrap()).unwrap_or_default();
            let ready = |aid: &str| if aid == android_id {
                frame(&format!(r#"{{"version":2,"type":"headers","machine_id_hex":"{}","otp_hex":"{}"}}"#,
                    hex(b"fake-mid"), hex(format!("fake-otp:{aid}").as_bytes())));
            } else {
                // A state bound to another identity.
                frame(r#"{"version":2,"type":"error","code":"native_failure"}"#);
            };
            match state.as_str() {
                "unprovisioned" => frame(r#"{"version":2,"type":"error","code":"not_provisioned"}"#),
                "corrupt" => frame(r#"{"version":2,"type":"error","code":"native_failure"}"#),
                "crash" => std::process::exit(3),
                "hang" => std::thread::sleep(Duration::from_secs(60)),
                "garbage" => frame(r#"{"version":2,"type":"headers"}"#),
                "descendant" => {
                    // A helper that outlives the worker must die with its group.
                    let child = std::process::Command::new("sleep").arg("60").spawn().unwrap();
                    std::fs::write(format!("{runtime}/descendant.pid"), child.id().to_string()).unwrap();
                    ready(android_id);
                }
                other => match other.split_once(':') {
                    Some(("provisioned", aid)) => ready(aid),
                    Some(("slow", aid)) => { std::thread::sleep(Duration::from_millis(300)); ready(aid) }
                    _ => frame(r#"{"version":2,"type":"error","code":"native_failure"}"#),
                },
            }
        }
        "--native-v2-session" => {
            let start = read_frame().unwrap();
            let spim = field(&start, "spim_hex");
            match spim.as_slice() {
                b"crash" => std::process::exit(3),
                b"hang" => std::thread::sleep(Duration::from_secs(60)),
                _ => {}
            }
            let cpim = [b"cpim:".as_slice(), &spim].concat();
            frame(&format!(r#"{{"version":2,"type":"started","cpim_hex":"{}"}}"#, hex(&cpim)));
            let Some(finish) = read_frame() else { std::process::exit(5) };
            let ptm = field(&finish, "ptm_hex");
            if ptm == b"bad" { std::process::exit(4); }
            let state = format!("provisioned:{android_id}");
            std::fs::write(format!("{dir}/adi.pb"), &state).unwrap();
            let reported = if ptm == b"mismatch" { "provisioned:other".to_string() } else { state };
            frame(&format!(r#"{{"version":2,"type":"finished","adi_pb_hex":"{}"}}"#, hex(reported.as_bytes())));
        }
        _ => std::process::exit(2),
    }
}
