//! The bridge's own checks, through its C interface, with the scripted
//! backend (`cargo test --features mock`) and without it (`cargo test`).

use std::ffi::c_void;
use std::sync::mpsc;
use std::time::Duration;

use serde_json::{Value, json};
use zag_apple_bridge::ffi::*;

extern "C" fn collect(context: *mut c_void, bytes: *const u8, length: usize) {
    let sender = unsafe { &*(context as *const mpsc::Sender<Value>) };
    let slice = unsafe { std::slice::from_raw_parts(bytes, length) };
    let _ = sender.send(serde_json::from_slice(slice).unwrap());
}

struct Events {
    receiver: mpsc::Receiver<Value>,
    sender: *mut mpsc::Sender<Value>,
}

impl Events {
    fn new() -> Self {
        let (tx, receiver) = mpsc::channel();
        Self { receiver, sender: Box::into_raw(Box::new(tx)) }
    }
    fn context(&self) -> *mut c_void {
        self.sender as *mut c_void
    }
    fn next(&self) -> Value {
        self.receiver.recv_timeout(Duration::from_secs(10)).expect("event")
    }
}

fn sign_in(slot: u64, email: &str, password: &str, events: &Events) {
    unsafe {
        zag_bridge_sign_in(slot, email.as_ptr(), email.len(), password.as_ptr(), password.len(), events.context(), collect)
    }
}

fn answer(slot: u64, code: &str) -> i32 {
    unsafe { zag_bridge_answer(slot, ZAG_BRIDGE_ANSWER_CODE, code.as_ptr(), code.len()) }
}

fn portal(slot: u64, credential: &Value, request: Value) -> Value {
    let events = Events::new();
    let credential = credential.to_string();
    let request = request.to_string();
    unsafe {
        zag_bridge_portal(slot, credential.as_ptr(), credential.len(), request.as_ptr(), request.len(), events.context(), collect)
    }
    events.next()
}

#[cfg(not(any(feature = "live", feature = "mock")))]
#[test]
fn without_live_or_mock_everything_is_disabled() {
    assert_eq!(zag_bridge_live_compiled(), 0);
    let url = c"https://anisette.invalid";
    assert_eq!(unsafe { zag_bridge_configure_live(url.as_ptr(), c"C02ZAGTEST01".as_ptr(), std::ptr::null()) }, ZAG_BRIDGE_DISABLED);
    assert_eq!(unsafe { zag_bridge_configure_mock(b"{}".as_ptr(), 2) }, ZAG_BRIDGE_UNSUPPORTED);
    let slot = zag_bridge_open_slot();
    let events = Events::new();
    sign_in(slot, "someone@example.com", "password", &events);
    assert_eq!(events.next(), json!({ "event": "failed", "kind": "disabled" }));
    let credential = json!({ "accountIdentifier": "A", "token": "T", "expiresAt": 4_000_000_000u64 });
    assert_eq!(portal(slot, &credential, json!({ "op": "teams" })), json!({ "event": "failed", "kind": "disabled" }));
    zag_bridge_close_slot(slot);
}

#[cfg(feature = "mock")]
mod scripted {
    use super::*;
    use std::sync::Mutex;

    // The backend is process-wide; the tests share one script.
    static LOCK: Mutex<()> = Mutex::new(());

    fn configure() -> std::sync::MutexGuard<'static, ()> {
        let guard = LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let team = |id: &str| json!({ "identifier": id, "name": "Personal Team", "kind": "personalFree" });
        let script = json!({ "accounts": [
            { "email": "first@zag.test", "password": "pw-one", "accountIdentifier": "ACC1", "teams": [team("TEAMONE001")] },
            { "email": "second@zag.test", "password": "pw-two", "accountIdentifier": "ACC2", "teams": [team("TEAMTWO002")] },
            { "email": "device@zag.test", "password": "pw", "accountIdentifier": "ACC3", "twoFactor": "trustedDevice",
              "code": "123456", "smsCode": "654321", "teams": [team("TEAMTRE003")] },
            { "email": "offline@zag.test", "password": "pw", "accountIdentifier": "ACC4", "signInFailure": "network" },
            { "email": "slow@zag.test", "password": "pw", "accountIdentifier": "ACC5", "delayMilliseconds": 30000 },
            { "email": "short@zag.test", "password": "pw", "accountIdentifier": "ACC6", "sessionLifetime": 1, "teams": [team("TEAMSIX006")] },
            { "email": "flaky@zag.test", "password": "pw", "accountIdentifier": "ACC7", "portalFailure": "network", "teams": [team("TEAMSVN007")] },
            { "email": "panic@zag.test", "password": "pw", "accountIdentifier": "ACC8", "panics": true },
        ]});
        let bytes = script.to_string();
        assert_eq!(unsafe { zag_bridge_configure_mock(bytes.as_ptr(), bytes.len()) }, ZAG_BRIDGE_OK);
        guard
    }

    fn signed_in(slot: u64, email: &str, password: &str) -> Value {
        let events = Events::new();
        sign_in(slot, email, password, &events);
        let event = events.next();
        assert_eq!(event["event"], "signedIn", "{event}");
        event["credential"].clone()
    }

    #[test]
    fn sign_in_without_two_factor() {
        let _guard = configure();
        let slot = zag_bridge_open_slot();
        let credential = signed_in(slot, "first@zag.test", "pw-one");
        assert_eq!(credential["accountIdentifier"], "ACC1");
        let teams = portal(slot, &credential, json!({ "op": "teams" }));
        assert_eq!(teams["value"][0]["identifier"], "TEAMONE001");
        zag_bridge_close_slot(slot);
    }

    #[test]
    fn wrong_password_and_network_failure_are_reported_as_kinds() {
        let _guard = configure();
        let slot = zag_bridge_open_slot();
        let events = Events::new();
        sign_in(slot, "first@zag.test", "wrong", &events);
        assert_eq!(events.next(), json!({ "event": "failed", "kind": "rejected" }));
        sign_in(slot, "offline@zag.test", "pw", &events);
        assert_eq!(events.next(), json!({ "event": "failed", "kind": "network" }));
        zag_bridge_close_slot(slot);
    }

    #[test]
    fn two_factor_device_code_with_one_retry_and_sms() {
        let _guard = configure();
        let slot = zag_bridge_open_slot();
        let events = Events::new();
        sign_in(slot, "device@zag.test", "pw", &events);
        let prompt = events.next();
        assert_eq!(prompt["event"], "codeRequired");
        assert_eq!(prompt["prompt"]["method"], "trustedDevice");
        assert_eq!(prompt["prompt"]["canRequestSms"], true);
        assert_eq!(answer(slot, "12a456"), ZAG_BRIDGE_INVALID, "non-digit codes never leave Swift's side");
        assert_eq!(answer(slot, "000000"), ZAG_BRIDGE_OK);
        let retry = events.next();
        assert_eq!(retry["prompt"]["retry"], true);
        assert_eq!(unsafe { zag_bridge_answer(slot, ZAG_BRIDGE_ANSWER_SMS, std::ptr::null(), 0) }, ZAG_BRIDGE_OK);
        let sms = events.next();
        assert_eq!(sms["prompt"]["method"], "sms");
        assert_eq!(sms["prompt"]["maskedDestination"], "12");
        assert_eq!(answer(slot, "654321"), ZAG_BRIDGE_OK);
        let done = events.next();
        assert_eq!(done["event"], "signedIn");
        assert!(!done.to_string().contains("pw\""), "the password is never echoed");
        zag_bridge_close_slot(slot);
    }

    #[test]
    fn two_wrong_codes_end_the_sign_in() {
        let _guard = configure();
        let slot = zag_bridge_open_slot();
        let events = Events::new();
        sign_in(slot, "device@zag.test", "pw", &events);
        events.next();
        answer(slot, "000000");
        events.next();
        answer(slot, "111111");
        assert_eq!(events.next(), json!({ "event": "failed", "kind": "twoFactorRejected" }));
        assert_eq!(answer(slot, "123456"), ZAG_BRIDGE_INVALID, "no prompt is waiting any more");
        zag_bridge_close_slot(slot);
    }

    #[test]
    fn cancelling_at_the_code_prompt_and_while_waiting() {
        let _guard = configure();
        let slot = zag_bridge_open_slot();
        let events = Events::new();
        sign_in(slot, "device@zag.test", "pw", &events);
        events.next();
        assert_eq!(zag_bridge_cancel(slot), ZAG_BRIDGE_OK);
        assert_eq!(events.next(), json!({ "event": "failed", "kind": "cancelled" }));

        sign_in(slot, "slow@zag.test", "pw", &events);
        let busy = Events::new();
        sign_in(slot, "first@zag.test", "pw-one", &busy);
        assert_eq!(busy.next(), json!({ "event": "failed", "kind": "busy" }), "one sign-in per slot");
        std::thread::sleep(Duration::from_millis(50));
        assert_eq!(zag_bridge_cancel(slot), ZAG_BRIDGE_OK);
        assert_eq!(events.next(), json!({ "event": "failed", "kind": "cancelled" }));
        // The slot is usable again.
        signed_in(slot, "first@zag.test", "pw-one");
        zag_bridge_close_slot(slot);
    }

    #[test]
    fn closing_a_slot_cancels_and_forgets_it() {
        let _guard = configure();
        let slot = zag_bridge_open_slot();
        let events = Events::new();
        sign_in(slot, "slow@zag.test", "pw", &events);
        std::thread::sleep(Duration::from_millis(50));
        zag_bridge_close_slot(slot);
        assert_eq!(events.next(), json!({ "event": "failed", "kind": "cancelled" }));
        assert_eq!(zag_bridge_cancel(slot), ZAG_BRIDGE_INVALID);
    }

    #[test]
    fn expired_sessions_are_reported_and_not_reused() {
        let _guard = configure();
        let slot = zag_bridge_open_slot();
        let credential = signed_in(slot, "short@zag.test", "pw");
        std::thread::sleep(Duration::from_millis(1100));
        let teams = json!({ "op": "devices", "team": "TEAMSIX006" });
        assert_eq!(portal(slot, &credential, teams.clone()), json!({ "event": "failed", "kind": "sessionExpired" }));
        assert_eq!(portal(slot, &credential, teams), json!({ "event": "failed", "kind": "sessionExpired" }));
        let unknown = json!({ "accountIdentifier": "ACC6", "token": "forged", "expiresAt": 4_000_000_000u64 });
        assert_eq!(portal(slot, &unknown, json!({ "op": "teams" })), json!({ "event": "failed", "kind": "sessionExpired" }));
        zag_bridge_close_slot(slot);
    }

    #[test]
    fn a_panicking_operation_still_ends_with_one_terminal_event() {
        let _guard = configure();
        let slot = zag_bridge_open_slot();
        let events = Events::new();
        sign_in(slot, "panic@zag.test", "pw", &events);
        assert_eq!(events.next(), json!({ "event": "failed", "kind": "malformed" }));
        signed_in(slot, "first@zag.test", "pw-one");
        zag_bridge_close_slot(slot);
    }

    #[test]
    fn portal_network_failure() {
        let _guard = configure();
        let slot = zag_bridge_open_slot();
        let credential = signed_in(slot, "flaky@zag.test", "pw");
        assert_eq!(portal(slot, &credential, json!({ "op": "teams" })), json!({ "event": "failed", "kind": "network" }));
        zag_bridge_close_slot(slot);
    }

    #[test]
    fn accounts_are_isolated_by_slot_and_team() {
        let _guard = configure();
        let (one, two) = (zag_bridge_open_slot(), zag_bridge_open_slot());
        let first = signed_in(one, "first@zag.test", "pw-one");
        let second = signed_in(two, "second@zag.test", "pw-two");
        let register = json!({ "op": "registerDevice", "team": "TEAMONE001", "udid": "00000000-PLACEHOLDER", "name": "Test iPhone" });
        assert_eq!(portal(one, &first, register)["event"], "result");
        // Another account's credential in this slot is refused.
        assert_eq!(portal(one, &second, json!({ "op": "teams" })), json!({ "event": "failed", "kind": "invalidInput" }));
        assert_eq!(portal(two, &first, json!({ "op": "teams" })), json!({ "event": "failed", "kind": "invalidInput" }));
        // Each account sees only its own team and its own registrations.
        assert_eq!(portal(two, &second, json!({ "op": "devices", "team": "TEAMTWO002" }))["value"], json!([]));
        assert_eq!(portal(two, &second, json!({ "op": "devices", "team": "TEAMONE001" })), json!({ "event": "failed", "kind": "invalidInput" }));
        assert_eq!(portal(one, &first, json!({ "op": "devices", "team": "TEAMONE001" }))["value"][0]["name"], "Test iPhone");
        // A sign-in through a slot with another account rebinds it and drops
        // the old cached session.
        let rebound = signed_in(one, "second@zag.test", "pw-two");
        assert_eq!(portal(one, &first, json!({ "op": "teams" })), json!({ "event": "failed", "kind": "invalidInput" }));
        assert_eq!(portal(one, &rebound, json!({ "op": "teams" }))["value"][0]["identifier"], "TEAMTWO002");
        zag_bridge_close_slot(one);
        zag_bridge_close_slot(two);
    }

    #[test]
    fn malformed_inputs_are_refused() {
        let _guard = configure();
        let slot = zag_bridge_open_slot();
        let events = Events::new();
        unsafe { zag_bridge_sign_in(slot, std::ptr::null(), 0, b"pw".as_ptr(), 2, events.context(), collect) };
        assert_eq!(events.next(), json!({ "event": "failed", "kind": "invalidInput" }));
        let credential = json!({ "accountIdentifier": "ACC1", "token": "t", "expiresAt": 1 });
        assert_eq!(portal(slot, &credential, json!({ "op": "deleteEverything" })), json!({ "event": "failed", "kind": "invalidInput" }));
        assert_eq!(answer(999_999, "123456"), ZAG_BRIDGE_INVALID);
        zag_bridge_close_slot(slot);
    }
}

/// Compiled with `live` only to check the gate: nothing here configures a
/// usable backend, so no connection is attempted.
#[cfg(all(feature = "live", not(feature = "mock")))]
#[test]
fn live_build_refuses_insecure_configuration_and_runs_nothing_unconfigured() {
    assert_eq!(zag_bridge_live_compiled(), 1);
    extern "C" fn store(_: *mut c_void, _: *const std::ffi::c_char, _: *const u8, _: usize) -> i32 { 1 }
    extern "C" fn retrieve(_: *mut c_void, _: *const std::ffi::c_char, _: *mut *mut u8, _: *mut usize) -> i32 { 1 }
    extern "C" fn delete(_: *mut c_void, _: *const std::ffi::c_char) -> i32 { 1 }
    extern "C" fn release(_: *mut c_void, _: *mut u8, _: usize) {}
    let storage = ZagBridgeStorage { context: std::ptr::null_mut(), store, retrieve, delete_item: delete, release };
    for url in [c"http://anisette.invalid", c"not a url", c"ftp://anisette.invalid"] {
        assert_eq!(unsafe { zag_bridge_configure_live(url.as_ptr(), c"C02ZAGTEST01".as_ptr(), &storage) }, ZAG_BRIDGE_INVALID);
    }
    // No device serial, or a malformed one: refused, never defaulted.
    let https = c"https://anisette.invalid";
    assert_eq!(unsafe { zag_bridge_configure_live(https.as_ptr(), std::ptr::null(), &storage) }, ZAG_BRIDGE_INVALID);
    for serial in [c"", c"0 0", c"serial-with-dash"] {
        assert_eq!(unsafe { zag_bridge_configure_live(https.as_ptr(), serial.as_ptr(), &storage) }, ZAG_BRIDGE_INVALID);
    }
    let slot = zag_bridge_open_slot();
    let events = Events::new();
    sign_in(slot, "someone@example.com", "password", &events);
    assert_eq!(events.next(), json!({ "event": "failed", "kind": "notConfigured" }));
    zag_bridge_close_slot(slot);
}
