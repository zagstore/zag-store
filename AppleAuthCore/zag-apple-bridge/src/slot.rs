//! Slots: one per Swift authenticator, so one per account. A slot runs at
//! most one sign-in at a time. After a sign-in it is bound to that Apple
//! Account, and a portal call with another account's credential is
//! refused. Its portal session is cached for its own credential only, and
//! dropped when the slot closes. Nothing is shared between slots except the
//! configured backend.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock, RwLock};

use serde_json::{Value, json};
use tokio::runtime::Runtime;
use tokio::sync::{mpsc, oneshot};
use zeroize::Zeroizing;

use crate::backend::*;

/// Delivers one event (JSON) to Swift. The bytes are wiped after delivery.
pub type Emit = Box<dyn Fn(&[u8]) + Send + Sync>;

pub(crate) fn runtime() -> &'static Runtime {
    static RUNTIME: OnceLock<Runtime> = OnceLock::new();
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("zag-apple-bridge")
            .enable_time()
            .build()
            .expect("bridge runtime")
    })
}

static BACKEND: RwLock<Option<Arc<dyn Backend>>> = RwLock::new(None);

#[cfg(any(feature = "live", feature = "mock"))]
pub(crate) fn set_backend(backend: Arc<dyn Backend>) {
    *BACKEND.write().unwrap_or_else(|p| p.into_inner()) = Some(backend);
}

#[cfg(feature = "live")]
pub(crate) fn backend_is_set() -> bool {
    BACKEND.read().unwrap_or_else(|p| p.into_inner()).is_some()
}

fn backend() -> BridgeResult<Arc<dyn Backend>> {
    if !crate::LIVE && !cfg!(feature = "mock") {
        return Err(FailureKind::Disabled.into());
    }
    BACKEND
        .read()
        .unwrap_or_else(|p| p.into_inner())
        .clone()
        .ok_or(FailureKind::NotConfigured.into())
}

struct CachedSession {
    token: Zeroizing<String>,
    session: Box<dyn PortalSession>,
}

#[derive(Default)]
struct Slot {
    /// The Apple Account this slot belongs to, once known.
    bound: Option<String>,
    signing_in: bool,
    /// Only one portal request may run in a slot; cancellation is slot-wide.
    portal_busy: bool,
    answers: Option<mpsc::UnboundedSender<CodeAction>>,
    /// Stops every running operation in this slot.
    cancels: Vec<oneshot::Sender<()>>,
    session: Option<Arc<tokio::sync::Mutex<Option<CachedSession>>>>,
}

static NEXT: AtomicU64 = AtomicU64::new(1);

fn slots() -> &'static Mutex<HashMap<u64, Slot>> {
    static SLOTS: OnceLock<Mutex<HashMap<u64, Slot>>> = OnceLock::new();
    SLOTS.get_or_init(Default::default)
}

fn with_slot<T>(id: u64, body: impl FnOnce(&mut Slot) -> BridgeResult<T>) -> BridgeResult<T> {
    let mut slots = slots().lock().unwrap_or_else(|p| p.into_inner());
    let slot = slots.get_mut(&id).ok_or(BridgeError::new(FailureKind::InvalidInput))?;
    body(slot)
}

pub fn open() -> u64 {
    let id = NEXT.fetch_add(1, Ordering::Relaxed);
    slots().lock().unwrap_or_else(|p| p.into_inner()).insert(id, Slot::default());
    id
}

/// Cancels whatever is running and forgets the slot's session.
pub fn close(id: u64) {
    let slot = slots().lock().unwrap_or_else(|p| p.into_inner()).remove(&id);
    if let Some(mut slot) = slot {
        for cancel in slot.cancels.drain(..) {
            let _ = cancel.send(());
        }
    }
}

pub fn cancel(id: u64) -> BridgeResult<()> {
    with_slot(id, |slot| {
        for cancel in slot.cancels.drain(..) {
            let _ = cancel.send(());
        }
        slot.answers = None;
        Ok(())
    })
}

pub fn answer(id: u64, action: CodeAction) -> BridgeResult<()> {
    with_slot(id, |slot| {
        let sender = slot.answers.as_ref().ok_or(BridgeError::new(FailureKind::InvalidInput))?;
        sender.send(action).map_err(|_| FailureKind::Cancelled.into())
    })
}

fn failure(kind: FailureKind) -> Value {
    json!({ "event": "failed", "kind": kind })
}

fn send(emit: &Emit, value: Value) {
    let bytes = Zeroizing::new(serde_json::to_vec(&value).unwrap_or_default());
    emit(&bytes);
}

/// Starts a sign-in. `emit` receives zero or more `codeRequired` events and
/// then exactly one `signedIn` or `failed` event.
pub fn sign_in(id: u64, anisette_scope: String, email: String, password: Zeroizing<String>, emit: Emit) {
    let (prompts_tx, mut prompts_rx) = mpsc::unbounded_channel();
    let (answers_tx, answers_rx) = mpsc::unbounded_channel();
    let (cancel_tx, cancel_rx) = oneshot::channel();
    let started = with_slot(id, |slot| {
        if slot.signing_in || slot.portal_busy {
            return Err(FailureKind::Busy.into());
        }
        slot.signing_in = true;
        slot.answers = Some(answers_tx);
        slot.cancels.push(cancel_tx);
        Ok(())
    })
    .and_then(|_| backend());
    let backend = match started {
        Ok(backend) => backend,
        Err(error) => {
            if error.kind != FailureKind::Busy && error.kind != FailureKind::InvalidInput {
                finish_sign_in(id, None);
            }
            return send(&emit, failure(error.kind));
        }
    };
    let emit = Arc::new(emit);
    let prompt_emit = emit.clone();
    let forward = runtime().spawn(async move {
        while let Some(prompt) = prompts_rx.recv().await {
            send(&prompt_emit, json!({ "event": "codeRequired", "prompt": prompt }));
        }
    });
    let task = runtime().spawn(async move {
        let prompter = Prompter { prompts: prompts_tx, answers: tokio::sync::Mutex::new(answers_rx) };
        let result = tokio::select! {
            result = backend.sign_in(&anisette_scope, &email, password, &prompter) => result,
            _ = cancel_rx => Err(FailureKind::Cancelled.into()),
        };
        drop(prompter);
        let _ = forward.await;
        match result {
            Ok(signed_in) => {
                finish_sign_in(id, Some(signed_in.credential.account_identifier.clone()));
                let event = json!({
                    "event": "signedIn",
                    "credential": {
                        "accountIdentifier": signed_in.credential.account_identifier,
                        "token": signed_in.credential.token.as_str(),
                        "expiresAt": signed_in.credential.expires_at,
                    },
                    "teams": signed_in.teams,
                });
                event
            }
            Err(error) => {
                finish_sign_in(id, None);
                failure(error.kind)
            }
        }
    });
    // The terminal event is delivered even if the operation panics.
    runtime().spawn(async move {
        let event = task.await.unwrap_or_else(|_| {
            finish_sign_in(id, None);
            failure(FailureKind::Malformed)
        });
        send(&emit, event);
    });
}

fn finish_sign_in(id: u64, account: Option<String>) {
    let _ = with_slot(id, |slot| {
        slot.signing_in = false;
        slot.answers = None;
        slot.cancels.retain(|cancel| !cancel.is_closed());
        if let Some(account) = account {
            if slot.bound.as_ref() != Some(&account) {
                // A different account signed in through this slot: nothing of
                // the previous account's session may be reused.
                slot.session = None;
            }
            slot.bound = Some(account);
        }
        Ok(())
    });
}

/// Runs one portal operation with `credential`. `emit` receives exactly one
/// `result` or `failed` event.
pub fn portal(id: u64, credential: Credential, request: PortalRequest, emit: Emit) {
    let (cancel_tx, cancel_rx) = oneshot::channel();
    let prepared = with_slot(id, |slot| {
        // A slot's cancellation is intentionally broad. Refuse overlapping
        // operations rather than let one caller cancel another's mutation.
        if slot.signing_in || slot.portal_busy {
            return Err(FailureKind::Busy.into());
        }
        match &slot.bound {
            Some(bound) if *bound != credential.account_identifier => return Err(FailureKind::InvalidInput.into()),
            Some(_) => {}
            // A session restored after launch binds the slot on first use.
            None => slot.bound = Some(credential.account_identifier.clone()),
        }
        slot.portal_busy = true;
        slot.cancels.push(cancel_tx);
        Ok(slot.session.get_or_insert_with(Default::default).clone())
    })
    .and_then(|session| backend().map(|backend| (backend, session)));
    let (backend, cache) = match prepared {
        Ok(prepared) => prepared,
        Err(error) => return send(&emit, failure(error.kind)),
    };
    let task = runtime().spawn(async move {
        let run = async {
            let mut cache = cache.lock().await;
            let reusable = cache.as_ref().is_some_and(|cached| cached.token == credential.token);
            if !reusable {
                *cache = None;
                let session = backend.open_session(&credential).await?;
                *cache = Some(CachedSession { token: credential.token.clone(), session });
            }
            let cached = cache.as_mut().ok_or(BridgeError::new(FailureKind::NotSignedIn))?;
            let result = cached.session.call(request).await;
            if matches!(result, Err(BridgeError { kind: FailureKind::SessionExpired })) {
                *cache = None;
            }
            result
        };
        let result = tokio::select! {
            result = run => result,
            _ = cancel_rx => Err(FailureKind::Cancelled.into()),
        };
        let _ = with_slot(id, |slot| {
            slot.portal_busy = false;
            slot.cancels.retain(|cancel| !cancel.is_closed());
            Ok(())
        });
        match result {
            Ok(value) => json!({ "event": "result", "value": value }),
            Err(error) => failure(error.kind),
        }
    });
    runtime().spawn(async move {
        send(&emit, task.await.unwrap_or_else(|_| failure(FailureKind::Malformed)));
    });
}

#[cfg(test)]
mod concurrency_tests {
    use super::*;
    use std::sync::{Arc, Mutex};

    #[test]
    fn busy_portal_slot_rejects_overlapping_portal_and_sign_in() {
        let id = open();
        with_slot(id, |slot| {
            slot.portal_busy = true;
            Ok(())
        }).unwrap();

        let events = Arc::new(Mutex::new(Vec::<Value>::new()));
        let portal_events = events.clone();
        portal(
            id,
            Credential {
                account_identifier: "test-account".to_string(),
                token: Zeroizing::new("test-token".to_string()),
                expires_at: u64::MAX,
            },
            PortalRequest::Teams,
            Box::new(move |bytes| {
                portal_events.lock().unwrap().push(serde_json::from_slice(bytes).unwrap());
            }),
        );
        assert_eq!(
            events.lock().unwrap().as_slice(),
            &[json!({"event":"failed","kind":"busy"})]
        );

        let sign_in_events = events.clone();
        sign_in(
            id,
            "atest".to_string(),
            "test@example.invalid".to_string(),
            Zeroizing::new("not-a-real-password".to_string()),
            Box::new(move |bytes| {
                sign_in_events.lock().unwrap().push(serde_json::from_slice(bytes).unwrap());
            }),
        );
        assert_eq!(
            events.lock().unwrap().last(),
            Some(&json!({"event":"failed","kind":"busy"}))
        );
        close(id);
    }
}
