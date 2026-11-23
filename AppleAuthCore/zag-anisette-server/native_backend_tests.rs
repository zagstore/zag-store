//! The native backend through the real listener, HTTP parser and WebSocket
//! stack, with the offline fake worker (tests/native_worker_fixture.rs).
//! Its OTPs are fakes: these tests prove supervision, isolation, cleanup and
//! the v3 encoding, never Apple acceptance. `real_coreadi_*` uses the real
//! native worker and Apple Music libraries when they are configured.
use super::*;
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::sync::{Arc, OnceLock};
use std::os::unix::fs::PermissionsExt;
use tungstenite::Message;

fn temp(name: &str) -> PathBuf {
    use std::sync::atomic::AtomicU32;
    static NEXT: AtomicU32 = AtomicU32::new(0);
    let dir = std::env::temp_dir().canonicalize().unwrap().join(format!(
        "zag-native-{name}-{}-{}", std::process::id(), NEXT.fetch_add(1, Ordering::Relaxed)));
    let _ = fs::remove_dir_all(&dir);
    fs::DirBuilder::new().mode(0o700).create(&dir).unwrap();
    dir
}

/// The fixture worker, compiled once per test run.
fn fixture() -> PathBuf {
    static WORKER: OnceLock<PathBuf> = OnceLock::new();
    WORKER.get_or_init(|| {
        let dir = temp("worker");
        let executable = dir.join("worker");
        let source = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/native_worker_fixture.rs");
        assert!(Command::new("rustc").args(["--edition=2021", "-O", "-o"]).arg(&executable).arg(&source)
            .status().unwrap().success());
        fs::set_permissions(&executable, fs::Permissions::from_mode(0o700)).unwrap();
        executable
    }).clone()
}

/// A runtime tree that passes the library checks (fixture contents).
fn runtime(name: &str) -> PathBuf {
    let root = temp(name);
    fs::set_permissions(&root, fs::Permissions::from_mode(0o755)).unwrap();
    let lib = root.join("lib/x86_64");
    fs::DirBuilder::new().recursive(true).mode(0o755).create(&lib).unwrap();
    for (dir, mode) in [(root.join("lib"), 0o755), (lib.clone(), 0o755)] {
        fs::set_permissions(dir, fs::Permissions::from_mode(mode)).unwrap();
    }
    for name in LIBRARIES {
        fs::write(lib.join(name), b"\x7fELF fixture").unwrap();
        fs::set_permissions(lib.join(name), fs::Permissions::from_mode(0o644)).unwrap();
    }
    root
}

fn config(runtime: PathBuf, state_dir: PathBuf, max_workers: usize) -> NativeConfig {
    NativeConfig {
        platform: NativePlatform::Android, worker: fixture(), runtime, state_dir, max_workers,
        headers_deadline: Duration::from_millis(1500), session_deadline: Duration::from_secs(5),
    }
}

fn backend(max_workers: usize) -> Arc<NativeBackend> {
    Arc::new(NativeBackend::open(config(runtime("runtime"), temp("state"), max_workers)).unwrap())
}

fn server(native: Arc<NativeBackend>) -> SocketAddr {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    thread::spawn(move || crate::serve_with(listener, Some(native)));
    address
}

fn http(address: SocketAddr, request: &str) -> (String, serde_json::Value) {
    let mut stream = TcpStream::connect(address).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
    stream.write_all(request.as_bytes()).unwrap();
    let mut out = String::new();
    stream.read_to_string(&mut out).unwrap();
    let (head, body) = out.split_once("\r\n\r\n").unwrap();
    (head.lines().next().unwrap().to_string(), serde_json::from_str(body).unwrap_or(serde_json::Value::Null))
}

fn get_headers(address: SocketAddr, identifier: &[u8; 16], state: &[u8]) -> (String, serde_json::Value) {
    let body = serde_json::json!({"identifier": base64_encode(identifier), "adi_pb": base64_encode(state)}).to_string();
    http(address, &format!(
        "POST /v3/get_headers HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{body}", body.len()))
}

fn work_entries(native: &NativeBackend) -> usize {
    fs::read_dir(&native.work).unwrap().count()
}

fn wait_until(condition: impl Fn() -> bool) -> bool {
    let end = Instant::now() + Duration::from_secs(10);
    while Instant::now() < end {
        if condition() { return true; }
        thread::sleep(Duration::from_millis(20));
    }
    false
}

#[test]
fn base64_and_identity_follow_the_client_contract() {
    for bytes in [&b"a"[..], b"ab", b"abc", b"abcd", &[0, 255, 128, 7]] {
        assert_eq!(base64_decode(&base64_encode(bytes), 64).unwrap(), bytes);
    }
    assert_eq!(base64_encode(b"fake-otp"), "ZmFrZS1vdHA=");
    for bad in ["", "Zg", "Zg=", "Zh==", "Z===", "Zg==Zg==", "Zm9v\n", "Zm9v YmFy"] {
        assert!(base64_decode(bad, 64).is_none(), "{bad:?}");
    }
    assert!(base64_decode("Zm9v", 2).is_none());
    // Same derivation as the coordinator: UUID text, upper-cased, 16 chars.
    let id: [u8; 16] = *b"\x01\x23\x45\x67\x89\xab\xcd\xef\x00\x11\x22\x33\x44\x55\x66\x77";
    assert_eq!(android_identifier(&id), "01234567-89AB-CD");
    // The request the client sends, including its resync fields.
    let request = serde_json::json!({"identifier": base64_encode(&id), "adi_pb": "c3RhdGU=",
        "sim": "x", "device_id": "y", "md_lu": "z"}).to_string();
    assert_eq!(parse_headers_request(request.as_bytes()).unwrap(), (id, b"state".to_vec()));
    for bad in [
        serde_json::json!({"identifier": "AAAA", "adi_pb": "c3RhdGU="}),
        serde_json::json!({"identifier": base64_encode(&id)}),
        serde_json::json!({"identifier": base64_encode(&id), "adi_pb": "c3RhdGU=", "extra": "x"}),
        serde_json::json!({"identifier": base64_encode(&id), "adi_pb": 1}),
        serde_json::json!({"identifier": base64_encode(&id), "adi_pb": base64_encode(&vec![0; MAX_STATE_BYTES + 1])}),
    ] {
        assert_eq!(parse_headers_request(bad.to_string().as_bytes()), Err(BackendError::InvalidInput), "{bad}");
    }
}

#[test]
fn startup_refuses_unsafe_configuration_and_recovers_the_work_area() {
    // A failing readiness check, an unprotected library and an open state
    // directory each stop startup.
    let broken = temp("broken-readiness");
    fs::set_permissions(&broken, fs::Permissions::from_mode(0o755)).unwrap();
    let good = runtime("runtime");
    for name in ["lib", "lib/x86_64"] {
        // Explicit modes: a umask of 002 would leave these group-writable,
        // which startup rightly refuses before the readiness check.
        fs::DirBuilder::new().mode(0o755).create(broken.join(name)).unwrap();
        fs::set_permissions(broken.join(name), fs::Permissions::from_mode(0o755)).unwrap();
    }
    for name in LIBRARIES { fs::copy(good.join("lib/x86_64").join(name), broken.join("lib/x86_64").join(name)).unwrap(); }
    assert_eq!(NativeBackend::open(config(broken, temp("state"), 1)).err(),
        Some(BackendError::Config("native readiness check failed")));
    let writable = runtime("runtime");
    fs::set_permissions(writable.join("lib/x86_64/libCoreADI.so"), fs::Permissions::from_mode(0o666)).unwrap();
    assert!(matches!(NativeBackend::open(config(writable, temp("state"), 1)), Err(BackendError::Config(_))));
    let open = temp("state");
    fs::set_permissions(&open, fs::Permissions::from_mode(0o755)).unwrap();
    assert!(matches!(NativeBackend::open(config(runtime("runtime"), open, 1)), Err(BackendError::Config(_))));
    let mut unapproved = config(runtime("runtime"), temp("state"), 1);
    unapproved.worker = PathBuf::from("relative-worker");
    assert!(matches!(NativeBackend::open(unapproved), Err(BackendError::Config(_))));

    // Restart after an interruption: leftover request directories are
    // removed; anything that is not a private directory stops startup.
    let state = temp("state");
    let leftover = state.join("work/0123");
    fs::DirBuilder::new().recursive(true).mode(0o700).create(&leftover).unwrap();
    fs::write(leftover.join("adi.pb"), b"left by a killed worker").unwrap();
    let native = NativeBackend::open(config(runtime("runtime"), state.clone(), 1)).unwrap();
    assert!(native.ready());
    assert_eq!(work_entries(&native), 0);
    drop(native);
    fs::write(state.join("work/stray"), b"x").unwrap();
    assert!(matches!(NativeBackend::open(config(runtime("runtime"), state, 1)), Err(BackendError::Config(_))));
}

#[test]
fn get_headers_serves_loaded_states_and_rejects_invalid_ones_safely() {
    let native = backend(4);
    let address = server(Arc::clone(&native));
    let id = [7u8; 16];
    let aid = android_identifier(&id);

    let (status, body) = get_headers(address, &id, format!("provisioned:{aid}").as_bytes());
    assert_eq!(status, "HTTP/1.1 200 OK");
    assert_eq!(body["result"], "Headers");
    assert_eq!(body["X-Apple-I-MD"], base64_encode(format!("fake-otp:{aid}").as_bytes()));
    assert_eq!(body["X-Apple-I-MD-M"], base64_encode(b"fake-mid"));
    assert_eq!(body["X-Apple-I-MD-RINFO"], "17106176");
    assert_eq!(body.as_object().unwrap().len(), 4);

    // The client re-provisions on "-45061"; other state problems are errors.
    let (status, body) = get_headers(address, &id, b"unprovisioned");
    assert_eq!((status.as_str(), body["result"].as_str()), ("HTTP/1.1 200 OK", Some("GetHeadersError")));
    assert!(body["message"].as_str().unwrap().contains("-45061"));
    for state in [&b"corrupt"[..], format!("provisioned:{}", android_identifier(&[8; 16])).as_bytes()] {
        let (_, body) = get_headers(address, &id, state);
        assert_eq!(body["result"], "GetHeadersError");
        assert!(!body["message"].as_str().unwrap().contains("-45061"));
    }
    // Crashed, hung or misbehaving workers are killed and reported; the
    // server keeps serving.
    for state in [&b"crash"[..], b"garbage", b"hang"] {
        let (status, body) = get_headers(address, &id, state);
        assert_eq!((status.as_str(), &body["error"]), ("HTTP/1.1 503 Service Unavailable", &serde_json::json!("native_worker_failed")));
    }
    // Malformed requests never reach a worker.
    let (_, body) = http(address, "POST /v3/get_headers HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}");
    assert_eq!(body["result"], "GetHeadersError");

    // A descendant left behind by a worker dies with its process group.
    let (_, body) = get_headers(address, &id, b"descendant");
    assert_eq!(body["result"], "Headers");
    let pid: i32 = fs::read_to_string(native.config.runtime.join("descendant.pid")).unwrap().parse().unwrap();
    assert!(wait_until(|| unsafe { libc::kill(pid, 0) } != 0), "worker descendant survived");

    assert!(wait_until(|| work_entries(&native) == 0 && native.active_workers() == 0));
    let (_, health) = http(address, "GET /healthz HTTP/1.1\r\nHost: x\r\n\r\n");
    assert_eq!((health["backend"].as_str(), health["workers"]["max"].as_u64()), (Some("native"), Some(4)));
}

#[test]
fn concurrent_requests_are_isolated_and_bounded() {
    let native = backend(2);
    let address = server(Arc::clone(&native));
    let peak = Arc::new(AtomicUsize::new(0));
    let watcher = {
        let (native, peak) = (Arc::clone(&native), Arc::clone(&peak));
        thread::spawn(move || for _ in 0..200 {
            peak.fetch_max(native.active_workers(), Ordering::Relaxed);
            thread::sleep(Duration::from_millis(5));
        })
    };
    let results: Vec<_> = (0..8u8).map(|n| thread::spawn(move || {
        let id = [n; 16];
        let (status, body) = get_headers(address, &id, format!("slow:{}", android_identifier(&id)).as_bytes());
        (n, status, body)
    })).collect::<Vec<_>>().into_iter().map(|t| t.join().unwrap()).collect();
    watcher.join().unwrap();
    let mut served = 0;
    for (n, status, body) in results {
        if status == "HTTP/1.1 200 OK" {
            // Each OTP comes from that request's own state and identity.
            assert_eq!(body["X-Apple-I-MD"], base64_encode(format!("fake-otp:{}", android_identifier(&[n; 16])).as_bytes()));
            served += 1;
        } else {
            assert_eq!((status.as_str(), &body["error"]), ("HTTP/1.1 503 Service Unavailable", &serde_json::json!("busy")));
        }
    }
    assert!(served >= 2, "{served}");
    assert!(peak.load(Ordering::Relaxed) <= 2);
    assert!(wait_until(|| work_entries(&native) == 0 && native.active_workers() == 0));
}

fn websocket(address: SocketAddr) -> tungstenite::WebSocket<TcpStream> {
    let stream = TcpStream::connect(address).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    tungstenite::client(format!("ws://{address}/v3/provisioning_session"), stream).unwrap().0
}

fn exchange(ws: &mut tungstenite::WebSocket<TcpStream>, message: serde_json::Value) -> serde_json::Value {
    ws.send(Message::Text(message.to_string().into())).unwrap();
    serde_json::from_str(&ws.read().unwrap().into_text().unwrap()).unwrap()
}

#[test]
fn provisioning_session_follows_the_client_protocol_and_cleans_up() {
    let native = backend(4);
    let address = server(Arc::clone(&native));
    let read = |ws: &mut tungstenite::WebSocket<TcpStream>| -> serde_json::Value {
        serde_json::from_str(&ws.read().unwrap().into_text().unwrap()).unwrap()
    };
    let id = [9u8; 16];
    let identifier = serde_json::json!({"identifier": base64_encode(&id)});

    // The complete exchange, as remote_v3::provision drives it.
    let mut ws = websocket(address);
    assert_eq!(read(&mut ws), serde_json::json!({"result": "GiveIdentifier"}));
    assert_eq!(exchange(&mut ws, identifier.clone()), serde_json::json!({"result": "GiveStartProvisioningData"}));
    let reply = exchange(&mut ws, serde_json::json!({"spim": base64_encode(b"spim-bytes")}));
    assert_eq!(reply["result"], "GiveEndProvisioningData");
    assert_eq!(reply["cpim"], base64_encode(b"cpim:spim-bytes"));
    let reply = exchange(&mut ws, serde_json::json!({"ptm": base64_encode(b"ptm"), "tk": base64_encode(b"tk")}));
    assert_eq!(reply["result"], "ProvisioningSuccess");
    let adi_pb = base64_decode(reply["adi_pb"].as_str().unwrap(), MAX_STATE_BYTES).unwrap();
    assert_eq!(adi_pb, format!("provisioned:{}", android_identifier(&id)).as_bytes());
    // That state then serves headers for the same identity.
    let (_, body) = get_headers(address, &id, &adi_pb);
    assert_eq!(body["result"], "Headers");

    // Failures carry the client's error tags.
    let mut ws = websocket(address);
    read(&mut ws);
    assert_eq!(exchange(&mut ws, serde_json::json!({"identifier": "c2hvcnQ="})), serde_json::json!({"result": "InvalidIdentifier"}));
    for (spim, ptm, tag) in [
        (&b"crash"[..], None, "StartProvisioningError"),
        (b"ok", Some(&b"bad"[..]), "EndProvisioningError"),
        (b"ok", Some(b"mismatch"), "EndProvisioningError"),
    ] {
        let mut ws = websocket(address);
        read(&mut ws);
        exchange(&mut ws, identifier.clone());
        let reply = exchange(&mut ws, serde_json::json!({"spim": base64_encode(spim)}));
        let reply = match ptm {
            None => reply,
            Some(ptm) => exchange(&mut ws, serde_json::json!({"ptm": base64_encode(ptm), "tk": base64_encode(b"tk")})),
        };
        assert_eq!(reply["result"], tag, "{spim:?}");
    }
    // Out of order, and malformed material.
    let mut ws = websocket(address);
    read(&mut ws);
    exchange(&mut ws, identifier.clone());
    assert_eq!(exchange(&mut ws, serde_json::json!({"ptm": "cA==", "tk": "dA=="}))["result"], "StartProvisioningError");
    let mut ws = websocket(address);
    read(&mut ws);
    exchange(&mut ws, identifier.clone());
    assert_eq!(exchange(&mut ws, serde_json::json!({"spim": "not base64!"}))["result"], "StartProvisioningError");

    // A client that disconnects between Start and Finish (or a hung worker)
    // leaves no process and no directory behind.
    let mut ws = websocket(address);
    read(&mut ws);
    exchange(&mut ws, identifier.clone());
    exchange(&mut ws, serde_json::json!({"spim": base64_encode(b"ok")}));
    drop(ws);
    let mut ws = websocket(address);
    read(&mut ws);
    exchange(&mut ws, identifier);
    ws.send(Message::Text(serde_json::json!({"spim": base64_encode(b"hang")}).to_string().into())).unwrap();
    assert_eq!(read(&mut ws)["result"], "StartProvisioningError");
    assert!(wait_until(|| work_entries(&native) == 0 && native.active_workers() == 0));
}

#[test]
fn health_and_readiness_report_the_backend() {
    let native = backend(3);
    let address = server(Arc::clone(&native));
    let (status, health) = http(address, "GET /healthz HTTP/1.1\r\nHost: x\r\n\r\n");
    assert_eq!(status, "HTTP/1.1 200 OK");
    assert_eq!((health["backend"].as_str(), health["workers"]["active"].as_u64()), (Some("native"), Some(0)));
    // Not ready without the client metadata file that /v3/client_info serves.
    if std::env::var_os("ZAG_ANISETTE_CLIENT_INFO_FILE").is_none() {
        let (status, ready) = http(address, "GET /readyz HTTP/1.1\r\nHost: x\r\n\r\n");
        assert_eq!((status.as_str(), ready["reason"].as_str()), ("HTTP/1.1 503 Service Unavailable", Some("client_metadata_unavailable")));
        let (status, _) = http(address, "GET /v3/client_info HTTP/1.1\r\nHost: x\r\n\r\n");
        assert_eq!(status, "HTTP/1.1 503 Service Unavailable");
    }
}

/// Real Apple Music CoreADI through the real worker, offline: startup
/// readiness (NOT_PROVISIONED), then a state and an SPIM Apple never issued
/// are rejected by the libraries. Runs when ZAG_NATIVE_E2E_WORKER and
/// ZAG_NATIVE_E2E_RUNTIME are set; it proves rejection, not acceptance.
#[test]
fn real_coreadi_rejects_unprovisioned_material_offline() {
    let (Some(worker), Some(runtime)) = (std::env::var_os("ZAG_NATIVE_E2E_WORKER"), std::env::var_os("ZAG_NATIVE_E2E_RUNTIME")) else {
        eprintln!("skipped: ZAG_NATIVE_E2E_WORKER / ZAG_NATIVE_E2E_RUNTIME not set");
        return;
    };
    let native = Arc::new(NativeBackend::open(NativeConfig {
        platform: NativePlatform::Android,
        worker: PathBuf::from(worker), runtime: PathBuf::from(runtime), state_dir: temp("real-state"),
        max_workers: 2, headers_deadline: Duration::from_secs(20), session_deadline: Duration::from_secs(30),
    }).expect("real native readiness check"));
    let address = server(Arc::clone(&native));
    let mut id = [0u8; 16];
    fs::File::open("/dev/urandom").unwrap().read_exact(&mut id).unwrap();
    let (status, body) = get_headers(address, &id, b"not an Apple-issued adi.pb");
    assert_eq!(status, "HTTP/1.1 200 OK");
    assert_eq!(body["result"], "GetHeadersError", "{body}");
    eprintln!("real CoreADI get_headers on a foreign state: {}", body["message"]);
    let mut ws = websocket(address);
    ws.read().unwrap();
    exchange(&mut ws, serde_json::json!({"identifier": base64_encode(&id)}));
    let reply = exchange(&mut ws, serde_json::json!({"spim": base64_encode(&[0x5a; 64])}));
    assert_eq!(reply["result"], "StartProvisioningError", "{reply}");
    assert!(wait_until(|| work_entries(&native) == 0 && native.active_workers() == 0));
}

/// A Windows runtime: a protected directory holding CoreADI64.dll.
fn windows_runtime(name: &str) -> PathBuf {
    let root = temp(name);
    fs::set_permissions(&root, fs::Permissions::from_mode(0o755)).unwrap();
    fs::write(root.join(WINDOWS_LIBRARY), b"MZ fixture").unwrap();
    fs::set_permissions(root.join(WINDOWS_LIBRARY), fs::Permissions::from_mode(0o644)).unwrap();
    root
}

#[test]
fn platforms_are_configured_separately_and_never_mixed() {
    let windows = |runtime: PathBuf| NativeConfig { platform: NativePlatform::Windows, ..config(runtime, temp("state"), 2) };
    // Each platform accepts only its own runtime layout.
    assert!(matches!(NativeBackend::open(windows(runtime("android-layout"))), Err(BackendError::Config(_))));
    let android = config(windows_runtime("windows-layout"), temp("state"), 2);
    assert!(matches!(NativeBackend::open(android), Err(BackendError::Config(_))));
    let native = Arc::new(NativeBackend::open(windows(windows_runtime("windows"))).unwrap());
    assert_eq!(native.platform(), NativePlatform::Windows);
    // The Windows worker receives the identifier as lower-case hex.
    let address = server(Arc::clone(&native));
    let id: [u8; 16] = *b"\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\xff";
    let hex: String = id.iter().map(|b| format!("{b:02x}")).collect();
    let (_, body) = get_headers(address, &id, format!("provisioned:{hex}").as_bytes());
    assert_eq!(body["result"], "Headers", "{body}");
    let (_, body) = get_headers(address, &id, format!("provisioned:{}", android_identifier(&id)).as_bytes());
    assert_eq!(body["result"], "GetHeadersError");
    let (_, health) = http(address, "GET /healthz HTTP/1.1\r\nHost: x\r\n\r\n");
    assert_eq!((health["native_platform"].as_str(), health["adi_platform"].as_str()), (Some("windows"), Some("Windows")));
}

#[test]
fn readiness_needs_an_identity_of_the_configured_adi() {
    let metadata = |client_info: &str, user_agent: &str| crate::client_info_config::parse(
        serde_json::json!({"client_info": client_info, "user_agent": user_agent}).to_string().as_bytes()).unwrap();
    // The client_info follows iTunes 12.13.12.3's template; the user agent is
    // only a syntactic placeholder (the real one is unresolved).
    let itunes = metadata("<PC> <Windows;10.0(0,0);19045> <com.apple.AuthKitWin/1 (com.apple.iTunes/12.13.12)>", "iTunes/12.13.12");
    let mac = metadata("<MacBookPro13,2> <macOS;13.1;22C65> <com.apple.AuthKit/1 (com.apple.akd/1.0)>", "akd/1.0 CFNetwork/808.1.4");
    let windows_akd = metadata("<PC> <Windows;6.2(0,0);9200> <com.apple.AuthKit/1 (com.apple.akd/1.0)>", "akd/1.0 CFNetwork/808.1.4");
    assert!(NativePlatform::Windows.accepts(&itunes));
    assert!(!NativePlatform::Windows.accepts(&mac));
    // A Windows platform field alone is not iTunes' AuthKitWin identity.
    assert!(!NativePlatform::Windows.accepts(&windows_akd));
    assert!(!NativePlatform::Android.accepts(&itunes));
    assert!(!NativePlatform::Android.accepts(&mac));
}

/// Real Windows CoreADI64.dll through the real Windows worker and the real
/// server path, offline: readiness (NOT_PROVISIONED), then states and an
/// SPIM Apple never issued are rejected, concurrently and with cleanup.
/// Runs when ZAG_NATIVE_E2E_WINDOWS_WORKER and _RUNTIME are set; it proves
/// rejection and supervision, not acceptance.
#[test]
fn real_windows_coreadi_rejects_unprovisioned_material_offline() {
    let (Some(worker), Some(runtime)) = (std::env::var_os("ZAG_NATIVE_E2E_WINDOWS_WORKER"), std::env::var_os("ZAG_NATIVE_E2E_WINDOWS_RUNTIME")) else {
        eprintln!("skipped: ZAG_NATIVE_E2E_WINDOWS_WORKER / ZAG_NATIVE_E2E_WINDOWS_RUNTIME not set");
        return;
    };
    let native = Arc::new(NativeBackend::open(NativeConfig {
        platform: NativePlatform::Windows,
        worker: PathBuf::from(worker), runtime: PathBuf::from(runtime), state_dir: temp("real-windows-state"),
        max_workers: 3, headers_deadline: Duration::from_secs(20), session_deadline: Duration::from_secs(30),
    }).expect("real Windows readiness check"));
    let address = server(Arc::clone(&native));
    let mut id = [0u8; 16];
    fs::File::open("/dev/urandom").unwrap().read_exact(&mut id).unwrap();
    // Plain bytes are not a Windows state container.
    let (status, body) = get_headers(address, &id, b"not an Apple-issued adi.pb");
    assert_eq!((status.as_str(), body["result"].as_str()), ("HTTP/1.1 200 OK", Some("GetHeadersError")), "{body}");
    eprintln!("real Windows CoreADI, plain bytes: {}", body["message"]);
    // A well-formed container whose files Apple never issued.
    let entry = |name: &str, data: &[u8]| [&(name.len() as u16).to_be_bytes()[..], name.as_bytes(), &(data.len() as u32).to_be_bytes(), data].concat();
    let forged = [&b"ZWADI\x00\x01\x00"[..], &entry("adi.pb", &[0x5a; 256])].concat();
    // Eight at once against three worker slots: each is rejected by CoreADI
    // or refused as busy, never answered with headers.
    let replies: Vec<_> = (0..8).map(|_| { let forged = forged.clone(); thread::spawn(move || get_headers(address, &id, &forged)) })
        .collect::<Vec<_>>().into_iter().map(|t| t.join().unwrap()).collect();
    let rejected: Vec<_> = replies.iter().filter(|(status, body)| status == "HTTP/1.1 200 OK" && body["result"] == "GetHeadersError").collect();
    let busy = replies.iter().filter(|(status, body)| status == "HTTP/1.1 503 Service Unavailable" && body["error"] == "busy").count();
    assert_eq!(rejected.len() + busy, replies.len(), "{replies:?}");
    assert!(!rejected.is_empty());
    eprintln!("real Windows CoreADI, forged container: {} ({} rejected, {busy} busy)", rejected[0].1["message"], rejected.len());
    let (_, body) = get_headers(address, &id, &forged);
    assert_eq!(body["result"], "GetHeadersError", "{body}");
    let mut ws = websocket(address);
    ws.read().unwrap();
    exchange(&mut ws, serde_json::json!({"identifier": base64_encode(&id)}));
    let reply = exchange(&mut ws, serde_json::json!({"spim": base64_encode(&[0x5a; 64])}));
    assert_eq!(reply["result"], "StartProvisioningError", "{reply}");
    assert!(wait_until(|| work_entries(&native) == 0 && native.active_workers() == 0));
}
