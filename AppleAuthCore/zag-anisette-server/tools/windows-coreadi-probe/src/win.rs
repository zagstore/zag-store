//! The Windows API surface CoreADI64.dll imports, implemented on Linux.
//!
//! Every function uses the win64 ABI. Files are confined to a private root
//! (drive `C:` maps to `<root>/c`), the registry and the volume serial come
//! from a per-root machine file, and randomness comes from the kernel. A
//! function this process does not implement names itself and aborts, so an
//! unexpected code path is reported instead of silently returning garbage.
//! The process runs CoreADI on one thread, so synchronisation is trivial.
#![allow(non_snake_case, clippy::missing_safety_doc)]
use std::cell::Cell;
use std::collections::{BTreeMap, HashMap};
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt};
use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};

type Bool = i32;
type Handle = isize;
const TRUE: Bool = 1;
const FALSE: Bool = 0;
const INVALID_HANDLE_VALUE: Handle = -1;
const ERROR_FILE_NOT_FOUND: u32 = 2;
const ERROR_PATH_NOT_FOUND: u32 = 3;
const ERROR_ACCESS_DENIED: u32 = 5;
const ERROR_INVALID_HANDLE: u32 = 6;
const ERROR_NO_MORE_FILES: u32 = 18;
const ERROR_FILE_EXISTS: u32 = 80;
const ERROR_INVALID_PARAMETER: u32 = 87;
const ERROR_MOD_NOT_FOUND: u32 = 126;
const ERROR_PROC_NOT_FOUND: u32 = 127;
const ERROR_ALREADY_EXISTS: u32 = 183;
const ERROR_MORE_DATA: u32 = 234;
const FILE_ATTRIBUTE_DIRECTORY: u32 = 0x10;
const FILE_ATTRIBUTE_NORMAL: u32 = 0x80;

// ---------------------------------------------------------------- state

/// Synthetic machine values for this private root. They describe a test
/// machine of our own, never a real device.
pub struct Machine {
    pub volume_serial: u32,
    pub registry: BTreeMap<String, String>,
}

struct Host {
    root: PathBuf,
    machine: Machine,
    handles: HashMap<Handle, Object>,
    next_handle: Handle,
    trace: bool,
    calls: BTreeMap<&'static str, u64>,
    events: Vec<String>,
}

enum Object {
    File(File),
    Find(Vec<(String, bool, u64)>, usize),
    Sync,
    CryptProvider,
    Key(String),
}

static HOST: OnceLock<Mutex<Host>> = OnceLock::new();
thread_local!(static LAST_ERROR: Cell<u32> = const { Cell::new(0) });

pub fn install(root: PathBuf, machine: Machine, trace: bool) {
    let host = Host { root, machine, handles: HashMap::new(), next_handle: 0x1000, trace,
        calls: BTreeMap::new(), events: Vec::new() };
    if HOST.set(Mutex::new(host)).is_err() { panic!("host installed twice"); }
}

fn host() -> std::sync::MutexGuard<'static, Host> { HOST.get().expect("host").lock().unwrap() }

fn called(name: &'static str) {
    let mut h = host();
    *h.calls.entry(name).or_default() += 1;
}

/// Records a host-visible effect (file path, registry name). The values
/// involved are synthetic test data, never Apple material.
fn event(text: String) {
    let mut h = host();
    if h.trace { eprintln!("  win: {text}"); }
    if h.events.len() < 512 && !h.events.contains(&text) { h.events.push(text); }
}

pub fn calls() -> BTreeMap<&'static str, u64> { host().calls.clone() }
pub fn events() -> Vec<String> { host().events.clone() }

/// Diagnostic detail, printed only with --trace.
fn trace(text: impl FnOnce() -> String) { if host().trace { eprintln!("  trace: {}", text()); } }

fn set_error(code: u32) { LAST_ERROR.with(|e| e.set(code)); }

fn insert(object: Object) -> Handle {
    let mut h = host();
    let handle = h.next_handle;
    h.next_handle += 4;
    h.handles.insert(handle, object);
    handle
}

// ---------------------------------------------------------------- strings

unsafe fn wide(p: *const u16) -> String {
    if p.is_null() { return String::new(); }
    let mut n = 0;
    while *p.add(n) != 0 { n += 1; }
    String::from_utf16_lossy(std::slice::from_raw_parts(p, n))
}

unsafe fn narrow(p: *const u8) -> String {
    if p.is_null() { return String::new(); }
    std::ffi::CStr::from_ptr(p.cast()).to_string_lossy().into_owned()
}

/// Writes `s` as a NUL-terminated UTF-16 string into `buffer` of `capacity`
/// characters and zeroes the rest of the buffer; returns the length without
/// the terminator, or None. CoreADI converts whole MAX_PATH buffers,
/// including what follows the terminator, so leftover stack bytes there
/// would make the conversion overflow.
unsafe fn put_wide(s: &str, buffer: *mut u16, capacity: usize) -> Option<usize> {
    let units: Vec<u16> = s.encode_utf16().collect();
    if buffer.is_null() || units.len() + 1 > capacity { return None; }
    std::ptr::copy_nonoverlapping(units.as_ptr(), buffer, units.len());
    std::ptr::write_bytes(buffer.add(units.len()), 0, capacity - units.len());
    Some(units.len())
}

/// Maps a Windows path into the private root: `C:\x\y` -> `<root>/c/x/y`.
/// Relative paths resolve against `C:\`. `..` components are refused.
fn map_path(windows: &str) -> Option<PathBuf> {
    let p = windows.trim_start_matches(r"\\?\").replace('/', "\\");
    let (drive, rest) = match p.as_bytes() {
        [d, b':', ..] if d.is_ascii_alphabetic() => ((*d as char).to_ascii_lowercase(), &p[2..]),
        _ => ('c', p.as_str()),
    };
    let mut out = host().root.join(drive.to_string());
    for part in rest.split('\\').filter(|s| !s.is_empty() && *s != ".") {
        if part == ".." || part.contains('\0') { return None; }
        out.push(part);
    }
    Some(out)
}

fn io_error(e: &std::io::Error) -> u32 {
    match e.kind() {
        std::io::ErrorKind::NotFound => ERROR_FILE_NOT_FOUND,
        std::io::ErrorKind::AlreadyExists => ERROR_FILE_EXISTS,
        std::io::ErrorKind::PermissionDenied => ERROR_ACCESS_DENIED,
        _ => ERROR_PATH_NOT_FOUND,
    }
}

// ---------------------------------------------------------------- unsupported

macro_rules! unsupported {
    ($($name:ident),* $(,)?) => {$(
        pub extern "win64" fn $name() -> usize {
            eprintln!("FAIL: CoreADI called the unimplemented Windows API {}", stringify!($name));
            std::process::abort();
        }
    )*};
}
// Exception dispatch and crash reporting: reaching any of these means the
// library raised an exception or failed a security check.
unsupported!(RtlCaptureContext, RtlLookupFunctionEntry, RtlVirtualUnwind, RtlUnwindEx,
    UnhandledExceptionFilter, RaiseException, ReadConsoleW, WriteConsoleW);

// ---------------------------------------------------------------- process

pub extern "win64" fn GetLastError() -> u32 { LAST_ERROR.with(|e| e.get()) }
pub extern "win64" fn SetLastError(code: u32) { set_error(code) }
pub extern "win64" fn GetCurrentProcessId() -> u32 { called("GetCurrentProcessId"); std::process::id() }
pub extern "win64" fn GetCurrentThreadId() -> u32 { called("GetCurrentThreadId"); unsafe { libc::gettid() as u32 } }
pub extern "win64" fn GetCurrentProcess() -> Handle { -1 }
pub extern "win64" fn IsDebuggerPresent() -> Bool { called("IsDebuggerPresent"); FALSE }
pub extern "win64" fn SetUnhandledExceptionFilter(_filter: usize) -> usize { called("SetUnhandledExceptionFilter"); 0 }
pub extern "win64" fn IsProcessorFeaturePresent(feature: u32) -> Bool {
    called("IsProcessorFeaturePresent");
    // SSE, SSE2, SSE3 and the RDTSC/NX basics every x86_64 host has. Fast
    // fail (23) is reported absent: int 0x29 is not a Linux system call.
    matches!(feature, 3 | 6 | 7 | 8 | 10 | 12 | 13) as Bool
}
pub extern "win64" fn ExitProcess(code: u32) -> ! {
    eprintln!("FAIL: CoreADI called ExitProcess({code})");
    std::process::exit(70);
}
pub extern "win64" fn TerminateProcess(_process: Handle, code: u32) -> Bool {
    eprintln!("FAIL: CoreADI called TerminateProcess({code})");
    std::process::exit(70);
}
pub extern "win64" fn QueryPerformanceCounter(out: *mut i64) -> Bool {
    called("QueryPerformanceCounter");
    let mut t = libc::timespec { tv_sec: 0, tv_nsec: 0 };
    unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC, &mut t); *out = t.tv_sec * 1_000_000_000 + t.tv_nsec; }
    TRUE
}
pub unsafe extern "win64" fn GetStartupInfoW(info: *mut u8) {
    called("GetStartupInfoW");
    std::ptr::write_bytes(info, 0, 104);
    *(info as *mut u32) = 104;
}
static COMMAND_LINE_W: [u16; 8] = [b'c' as u16, b'o' as u16, b'r' as u16, b'e' as u16, b'a' as u16, b'd' as u16, b'i' as u16, 0];
static COMMAND_LINE_A: &[u8] = b"coreadi\0";
static EMPTY_ENVIRONMENT: [u16; 2] = [0, 0];
pub extern "win64" fn GetCommandLineA() -> *const u8 { called("GetCommandLineA"); COMMAND_LINE_A.as_ptr() }
pub extern "win64" fn GetCommandLineW() -> *const u16 { called("GetCommandLineW"); COMMAND_LINE_W.as_ptr() }
pub extern "win64" fn GetEnvironmentStringsW() -> *const u16 { called("GetEnvironmentStringsW"); EMPTY_ENVIRONMENT.as_ptr() }
pub extern "win64" fn FreeEnvironmentStringsW(_p: usize) -> Bool { TRUE }
pub unsafe extern "win64" fn SetEnvironmentVariableA(name: *const u8, _value: *const u8) -> Bool {
    called("SetEnvironmentVariableA");
    event(format!("SetEnvironmentVariableA {}", narrow(name)));
    TRUE
}

// ---------------------------------------------------------------- modules

static MODULE_BASE: OnceLock<usize> = OnceLock::new();
pub fn set_module_base(base: usize) { let _ = MODULE_BASE.set(base); }

pub unsafe extern "win64" fn GetModuleHandleW(name: *const u16) -> usize {
    called("GetModuleHandleW");
    if name.is_null() { return *MODULE_BASE.get().unwrap(); }
    event(format!("GetModuleHandleW {} -> not loaded", wide(name)));
    set_error(ERROR_MOD_NOT_FOUND);
    0
}
pub unsafe extern "win64" fn GetModuleHandleExW(_flags: u32, name: *const u16, out: *mut usize) -> Bool {
    called("GetModuleHandleExW");
    if !(_flags & 4 != 0) { event(format!("GetModuleHandleExW {} -> not loaded", wide(name))); }
    if !out.is_null() { *out = 0; }
    set_error(ERROR_MOD_NOT_FOUND);
    FALSE
}
/// No other library is ever loaded: the CRT falls back to its imports.
pub unsafe extern "win64" fn LoadLibraryExW(name: *const u16, _file: Handle, _flags: u32) -> usize {
    called("LoadLibraryExW");
    event(format!("LoadLibraryExW {} -> refused", wide(name)));
    set_error(ERROR_MOD_NOT_FOUND);
    0
}
pub unsafe extern "win64" fn GetProcAddress(_module: usize, name: *const u8) -> usize {
    called("GetProcAddress");
    if (name as usize) >> 16 != 0 { event(format!("GetProcAddress {} -> none", narrow(name))); }
    set_error(ERROR_PROC_NOT_FOUND);
    0
}
pub extern "win64" fn FreeLibrary(_module: usize) -> Bool { TRUE }

// ---------------------------------------------------------------- heap

const HEAP: Handle = 0x7e00;
const HEAP_ZERO_MEMORY: u32 = 8;
pub extern "win64" fn GetProcessHeap() -> Handle { HEAP }
pub unsafe extern "win64" fn HeapAlloc(_heap: Handle, flags: u32, size: usize) -> *mut u8 {
    let p = libc::malloc(size + 16) as *mut u8;
    if p.is_null() { return p; }
    *(p as *mut usize) = size;
    if flags & HEAP_ZERO_MEMORY != 0 { std::ptr::write_bytes(p.add(16), 0, size); }
    p.add(16)
}
pub unsafe extern "win64" fn HeapFree(_heap: Handle, _flags: u32, p: *mut u8) -> Bool {
    if !p.is_null() { libc::free(p.sub(16).cast()); }
    TRUE
}
pub unsafe extern "win64" fn HeapReAlloc(_heap: Handle, flags: u32, p: *mut u8, size: usize) -> *mut u8 {
    if p.is_null() { return HeapAlloc(_heap, flags, size); }
    let old = *(p.sub(16) as *const usize);
    let q = libc::realloc(p.sub(16).cast(), size + 16) as *mut u8;
    if q.is_null() { return q; }
    *(q as *mut usize) = size;
    if flags & HEAP_ZERO_MEMORY != 0 && size > old { std::ptr::write_bytes(q.add(16 + old), 0, size - old); }
    q.add(16)
}
pub unsafe extern "win64" fn HeapSize(_heap: Handle, _flags: u32, p: *const u8) -> usize { *(p.sub(16) as *const usize) }

// ---------------------------------------------------------------- threads and sync

pub extern "win64" fn InitializeCriticalSectionAndSpinCount(_cs: usize, _spin: u32) -> Bool { TRUE }
pub extern "win64" fn EnterCriticalSection(_cs: usize) {}
pub extern "win64" fn LeaveCriticalSection(_cs: usize) {}
pub extern "win64" fn DeleteCriticalSection(_cs: usize) {}

static TLS: Mutex<Vec<Option<usize>>> = Mutex::new(Vec::new());
pub extern "win64" fn TlsAlloc() -> u32 {
    called("TlsAlloc");
    let mut t = TLS.lock().unwrap();
    t.push(Some(0));
    (t.len() - 1) as u32
}
pub extern "win64" fn TlsGetValue(i: u32) -> usize {
    set_error(0);
    TLS.lock().unwrap().get(i as usize).copied().flatten().unwrap_or(0)
}
pub extern "win64" fn TlsSetValue(i: u32, v: usize) -> Bool {
    match TLS.lock().unwrap().get_mut(i as usize) {
        Some(slot @ Some(_)) => { *slot = Some(v); TRUE }
        _ => { set_error(ERROR_INVALID_PARAMETER); FALSE }
    }
}
pub extern "win64" fn TlsFree(i: u32) -> Bool {
    if let Some(slot) = TLS.lock().unwrap().get_mut(i as usize) { *slot = None; }
    TRUE
}
pub unsafe extern "win64" fn InitializeSListHead(head: *mut u8) { std::ptr::write_bytes(head, 0, 16) }
/// Nothing is ever pushed (InterlockedPushEntrySList is not imported).
pub unsafe extern "win64" fn InterlockedFlushSList(head: *mut u8) -> usize { std::ptr::write_bytes(head, 0, 16); 0 }

pub unsafe extern "win64" fn CreateEventA(_sec: usize, _manual: Bool, _initial: Bool, name: *const u8) -> Handle {
    called("CreateEventA");
    if !name.is_null() { event(format!("CreateEventA {}", narrow(name))); }
    insert(Object::Sync)
}
pub unsafe extern "win64" fn CreateMutexA(_sec: usize, _owner: Bool, name: *const u8) -> Handle {
    called("CreateMutexA");
    if !name.is_null() { event(format!("CreateMutexA {}", narrow(name))); }
    set_error(0);
    insert(Object::Sync)
}
pub extern "win64" fn SetEvent(_h: Handle) -> Bool { TRUE }
pub extern "win64" fn ResetEvent(_h: Handle) -> Bool { TRUE }
pub extern "win64" fn ReleaseMutex(_h: Handle) -> Bool { TRUE }
/// Single-threaded: every wait is satisfied immediately (WAIT_OBJECT_0).
pub extern "win64" fn WaitForSingleObject(_h: Handle, _ms: u32) -> u32 { called("WaitForSingleObject"); 0 }
pub extern "win64" fn SignalObjectAndWait(_s: Handle, _w: Handle, _ms: u32, _alertable: Bool) -> u32 { 0 }
pub extern "win64" fn CloseHandle(h: Handle) -> Bool {
    if host().handles.remove(&h).is_some() { TRUE } else { set_error(ERROR_INVALID_HANDLE); FALSE }
}

// ---------------------------------------------------------------- files

const GENERIC_READ: u32 = 0x8000_0000;
const GENERIC_WRITE: u32 = 0x4000_0000;

pub unsafe extern "win64" fn CreateFileW(name: *const u16, access: u32, _share: u32, _sec: usize,
    disposition: u32, _flags: u32, _template: Handle) -> Handle {
    called("CreateFileW");
    let windows = wide(name);
    let Some(path) = map_path(&windows) else { set_error(ERROR_ACCESS_DENIED); return INVALID_HANDLE_VALUE };
    let exists = path.exists();
    let mut o = OpenOptions::new();
    o.read(true).mode(0o600);
    if access & (GENERIC_WRITE | 0x2 | 0x4 | 0x1000_0000) != 0 { o.write(true); }
    match disposition {
        1 => { o.write(true).create_new(true); }
        2 => { o.write(true).create(true).truncate(true); }
        3 => {}
        4 => { o.write(true).create(true); }
        5 => { o.write(true).truncate(true); }
        _ => { set_error(ERROR_INVALID_PARAMETER); return INVALID_HANDLE_VALUE; }
    }
    let _ = access & GENERIC_READ;
    event(format!("CreateFileW {windows} disposition={disposition} existed={exists}"));
    match o.open(&path) {
        Ok(f) => {
            set_error(if exists && (disposition == 2 || disposition == 4) { ERROR_ALREADY_EXISTS } else { 0 });
            insert(Object::File(f))
        }
        Err(e) => { set_error(io_error(&e)); INVALID_HANDLE_VALUE }
    }
}

fn with_file<T>(h: Handle, f: impl FnOnce(&mut File) -> std::io::Result<T>) -> Option<T> {
    let mut host = host();
    match host.handles.get_mut(&h) {
        Some(Object::File(file)) => match f(file) {
            Ok(v) => Some(v),
            Err(e) => { drop(host); set_error(io_error(&e)); None }
        },
        _ => { drop(host); set_error(ERROR_INVALID_HANDLE); None }
    }
}

pub unsafe extern "win64" fn ReadFile(h: Handle, buffer: *mut u8, n: u32, read: *mut u32, _ov: usize) -> Bool {
    called("ReadFile");
    let slice = std::slice::from_raw_parts_mut(buffer, n as usize);
    match with_file(h, |f| f.read(slice)) {
        Some(got) => { if !read.is_null() { *read = got as u32; } TRUE }
        None => FALSE,
    }
}
pub unsafe extern "win64" fn WriteFile(h: Handle, buffer: *const u8, n: u32, written: *mut u32, _ov: usize) -> Bool {
    called("WriteFile");
    let slice = std::slice::from_raw_parts(buffer, n as usize);
    match with_file(h, |f| f.write_all(slice)) {
        Some(()) => { if !written.is_null() { *written = n; } TRUE }
        None => FALSE,
    }
}
pub unsafe extern "win64" fn SetFilePointerEx(h: Handle, distance: i64, new: *mut i64, method: u32) -> Bool {
    let seek = match method { 0 => SeekFrom::Start(distance as u64), 1 => SeekFrom::Current(distance), 2 => SeekFrom::End(distance),
        _ => { set_error(ERROR_INVALID_PARAMETER); return FALSE } };
    match with_file(h, |f| f.seek(seek)) {
        Some(at) => { if !new.is_null() { *new = at as i64; } TRUE }
        None => FALSE,
    }
}
pub extern "win64" fn SetEndOfFile(h: Handle) -> Bool {
    with_file(h, |f| { let at = f.stream_position()?; f.set_len(at) }).map_or(FALSE, |_| TRUE)
}
pub extern "win64" fn FlushFileBuffers(h: Handle) -> Bool { with_file(h, |f| f.sync_all()).map_or(FALSE, |_| TRUE) }
pub extern "win64" fn GetFileType(h: Handle) -> u32 {
    // FILE_TYPE_DISK for our files, FILE_TYPE_UNKNOWN otherwise.
    matches!(host().handles.get(&h), Some(Object::File(_))) as u32
}
pub unsafe extern "win64" fn GetFileInformationByHandle(h: Handle, info: *mut u8) -> Bool {
    called("GetFileInformationByHandle");
    let Some(m) = with_file(h, |f| f.metadata()) else { return FALSE };
    let serial = host().machine.volume_serial;
    std::ptr::write_bytes(info, 0, 52);
    let put = |o: usize, v: u32| *(info.add(o) as *mut u32) = v;
    put(0, if m.is_dir() { FILE_ATTRIBUTE_DIRECTORY } else { FILE_ATTRIBUTE_NORMAL });
    let ft = |t: i64| ((t as u64 + 11_644_473_600) * 10_000_000).to_le_bytes();
    for (o, t) in [(4, m.ctime()), (12, m.atime()), (20, m.mtime())] {
        std::ptr::copy_nonoverlapping(ft(t).as_ptr(), info.add(o), 8);
    }
    put(28, serial);
    put(32, (m.len() >> 32) as u32);
    put(36, m.len() as u32);
    put(40, m.nlink() as u32);
    put(44, (m.ino() >> 32) as u32);
    put(48, m.ino() as u32);
    TRUE
}

fn attributes(windows: &str) -> u32 {
    let Some(path) = map_path(windows) else { set_error(ERROR_ACCESS_DENIED); return u32::MAX };
    let result = match fs::metadata(&path) {
        Ok(m) if m.is_dir() => FILE_ATTRIBUTE_DIRECTORY,
        Ok(_) => FILE_ATTRIBUTE_NORMAL,
        Err(e) => { set_error(io_error(&e)); u32::MAX }
    };
    event(format!("GetFileAttributes {windows} -> {}", if result == u32::MAX { "missing".into() } else { format!("{result:#x}") }));
    result
}
pub unsafe extern "win64" fn GetFileAttributesW(name: *const u16) -> u32 { called("GetFileAttributesW"); attributes(&wide(name)) }
pub unsafe extern "win64" fn GetFileAttributesA(name: *const u8) -> u32 { called("GetFileAttributesA"); attributes(&narrow(name)) }
fn set_attributes(windows: &str, value: u32) -> Bool {
    event(format!("SetFileAttributes {windows} {value:#x}"));
    if map_path(windows).is_some_and(|p| p.exists()) { TRUE } else { set_error(ERROR_FILE_NOT_FOUND); FALSE }
}
pub unsafe extern "win64" fn SetFileAttributesW(name: *const u16, v: u32) -> Bool { called("SetFileAttributesW"); set_attributes(&wide(name), v) }
pub unsafe extern "win64" fn SetFileAttributesA(name: *const u8, v: u32) -> Bool { called("SetFileAttributesA"); set_attributes(&narrow(name), v) }

pub unsafe extern "win64" fn CreateDirectoryW(name: *const u16, _sec: usize) -> Bool {
    called("CreateDirectoryW");
    let windows = wide(name);
    let Some(path) = map_path(&windows) else { set_error(ERROR_ACCESS_DENIED); return FALSE };
    event(format!("CreateDirectoryW {windows}"));
    match fs::DirBuilder::new().mode(0o700).create(&path) {
        Ok(()) => TRUE,
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => { set_error(ERROR_ALREADY_EXISTS); FALSE }
        Err(e) => { set_error(if e.kind() == std::io::ErrorKind::NotFound { ERROR_PATH_NOT_FOUND } else { io_error(&e) }); FALSE }
    }
}
pub unsafe extern "win64" fn DeleteFileW(name: *const u16) -> Bool {
    called("DeleteFileW");
    let windows = wide(name);
    event(format!("DeleteFileW {windows}"));
    match map_path(&windows).map(fs::remove_file) {
        Some(Ok(())) => TRUE,
        Some(Err(e)) => { set_error(io_error(&e)); FALSE }
        None => { set_error(ERROR_ACCESS_DENIED); FALSE }
    }
}

fn glob(pattern: &[u8], name: &[u8]) -> bool {
    match (pattern.first(), name.first()) {
        (None, None) => true,
        (Some(b'*'), _) => glob(&pattern[1..], name) || (!name.is_empty() && glob(pattern, &name[1..])),
        (Some(b'?'), Some(_)) => glob(&pattern[1..], &name[1..]),
        (Some(p), Some(n)) if p.eq_ignore_ascii_case(n) => glob(&pattern[1..], &name[1..]),
        _ => false,
    }
}

unsafe fn fill_find_data(data: *mut u8, (name, dir, len): &(String, bool, u64)) {
    std::ptr::write_bytes(data, 0, 320);
    *(data as *mut u32) = if *dir { FILE_ATTRIBUTE_DIRECTORY } else { FILE_ATTRIBUTE_NORMAL };
    *(data.add(28) as *mut u32) = (len >> 32) as u32;
    *(data.add(32) as *mut u32) = *len as u32;
    let bytes = name.as_bytes();
    std::ptr::copy_nonoverlapping(bytes.as_ptr(), data.add(44), bytes.len().min(259));
}

pub unsafe extern "win64" fn FindFirstFileExA(name: *const u8, _level: u32, data: *mut u8, _op: u32, _filter: usize, _flags: u32) -> Handle {
    called("FindFirstFileExA");
    let windows = narrow(name);
    let (dir, pattern) = windows.rsplit_once('\\').unwrap_or(("", &windows));
    event(format!("FindFirstFileExA {windows}"));
    let Some(path) = map_path(dir) else { set_error(ERROR_ACCESS_DENIED); return INVALID_HANDLE_VALUE };
    let mut found: Vec<(String, bool, u64)> = fs::read_dir(&path).into_iter().flatten().flatten()
        .filter_map(|e| { let m = e.metadata().ok()?; Some((e.file_name().to_string_lossy().into_owned(), m.is_dir(), m.len())) })
        .filter(|(n, _, _)| glob(pattern.as_bytes(), n.as_bytes()))
        .collect();
    found.sort();
    if found.is_empty() { set_error(ERROR_FILE_NOT_FOUND); return INVALID_HANDLE_VALUE; }
    fill_find_data(data, &found[0]);
    insert(Object::Find(found, 1))
}
pub unsafe extern "win64" fn FindNextFileA(h: Handle, data: *mut u8) -> Bool {
    let mut host = host();
    let Some(Object::Find(entries, next)) = host.handles.get_mut(&h) else { drop(host); set_error(ERROR_INVALID_HANDLE); return FALSE };
    if *next >= entries.len() { drop(host); set_error(ERROR_NO_MORE_FILES); return FALSE; }
    fill_find_data(data, &entries[*next]);
    *next += 1;
    TRUE
}
pub extern "win64" fn FindClose(h: Handle) -> Bool { CloseHandle(h) }

pub extern "win64" fn GetDriveTypeW(_root: *const u16) -> u32 { called("GetDriveTypeW"); 3 /* DRIVE_FIXED */ }
pub unsafe extern "win64" fn GetVolumeInformationW(root: *const u16, name: *mut u16, name_n: u32, serial: *mut u32,
    max_component: *mut u32, flags: *mut u32, fs_name: *mut u16, fs_name_n: u32) -> Bool {
    called("GetVolumeInformationW");
    event(format!("GetVolumeInformationW {}", wide(root)));
    if !name.is_null() && put_wide("", name, name_n as usize).is_none() { set_error(ERROR_MORE_DATA); return FALSE; }
    if !serial.is_null() { *serial = host().machine.volume_serial; }
    if !max_component.is_null() { *max_component = 255; }
    if !flags.is_null() { *flags = 0x03e7_00ff; }
    if !fs_name.is_null() && put_wide("NTFS", fs_name, fs_name_n as usize).is_none() { set_error(ERROR_MORE_DATA); return FALSE; }
    TRUE
}
pub unsafe extern "win64" fn GetCurrentDirectoryW(n: u32, buffer: *mut u16) -> u32 {
    called("GetCurrentDirectoryW");
    match put_wide("C:\\", buffer, n as usize) { Some(len) => len as u32, None => 4 }
}

// ---------------------------------------------------------------- console

pub extern "win64" fn GetStdHandle(_which: u32) -> Handle { INVALID_HANDLE_VALUE }
pub extern "win64" fn SetStdHandle(_which: u32, _h: Handle) -> Bool { TRUE }
pub extern "win64" fn GetConsoleMode(_h: Handle, _mode: *mut u32) -> Bool { set_error(ERROR_INVALID_HANDLE); FALSE }
pub extern "win64" fn GetConsoleCP() -> u32 { 1252 }

// ---------------------------------------------------------------- code pages and text

const ACP: u32 = 1252;
pub extern "win64" fn GetACP() -> u32 { called("GetACP"); ACP }
pub extern "win64" fn GetOEMCP() -> u32 { 437 }
pub extern "win64" fn IsValidCodePage(cp: u32) -> Bool { matches!(cp, 437 | 1252 | 65001) as Bool }
pub unsafe extern "win64" fn GetCPInfo(cp: u32, info: *mut u8) -> Bool {
    if IsValidCodePage(cp) == FALSE { set_error(ERROR_INVALID_PARAMETER); return FALSE; }
    std::ptr::write_bytes(info, 0, 20);
    *(info as *mut u32) = if cp == 65001 { 4 } else { 1 };
    *info.add(4) = b'?';
    TRUE
}

fn decode(cp: u32, bytes: &[u8]) -> Vec<u16> {
    if cp == 65001 { String::from_utf8_lossy(bytes).encode_utf16().collect() } else { bytes.iter().map(|&b| b as u16).collect() }
}
fn encode(cp: u32, units: &[u16]) -> Vec<u8> {
    if cp == 65001 { String::from_utf16_lossy(units).into_bytes() } else { units.iter().map(|&u| if u < 256 { u as u8 } else { b'?' }).collect() }
}

pub unsafe extern "win64" fn MultiByteToWideChar(cp: u32, _flags: u32, src: *const u8, n: i32, dst: *mut u16, dst_n: i32) -> i32 {
    let len = if n < 0 { libc::strlen(src.cast()) + 1 } else { n as usize };
    let cp = if cp == 0 { ACP } else { cp };
    let out = decode(cp, std::slice::from_raw_parts(src, len));
    trace(|| format!("MultiByteToWideChar cp={cp} n={n} dst_n={dst_n} -> {} {:?}", out.len(), String::from_utf16_lossy(&out)));
    if dst_n == 0 { return out.len() as i32; }
    partial(&out, dst, dst_n)
}
pub unsafe extern "win64" fn WideCharToMultiByte(cp: u32, _flags: u32, src: *const u16, n: i32, dst: *mut u8, dst_n: i32,
    _default: *const u8, used: *mut Bool) -> i32 {
    let len = if n < 0 { let mut k = 0; while *src.add(k) != 0 { k += 1; } k + 1 } else { n as usize };
    let cp = if cp == 0 { ACP } else { cp };
    let out = encode(cp, std::slice::from_raw_parts(src, len));
    if !used.is_null() { *used = FALSE; }
    trace(|| format!("WideCharToMultiByte cp={cp} n={n} dst_n={dst_n} -> {} {:?}", out.len(), String::from_utf8_lossy(&out)));
    if dst_n == 0 { return out.len() as i32; }
    partial(&out, dst, dst_n)
}

/// Copies a conversion result like Windows does: when the destination is
/// too small it is filled as far as it goes and the call fails with
/// ERROR_INSUFFICIENT_BUFFER. CoreADI converts whole MAX_PATH buffers and
/// relies on the terminated prefix that this leaves behind.
unsafe fn partial<T: Copy>(out: &[T], dst: *mut T, dst_n: i32) -> i32 {
    let n = out.len().min(dst_n as usize);
    std::ptr::copy_nonoverlapping(out.as_ptr(), dst, n);
    if n < out.len() { set_error(122); 0 } else { n as i32 }
}
unsafe fn wide_slice<'a>(p: *const u16, n: i32) -> &'a [u16] {
    let len = if n < 0 { let mut k = 0; while *p.add(k) != 0 { k += 1; } k } else { n as usize };
    std::slice::from_raw_parts(p, len)
}
fn fold(u: u16, ignore_case: bool) -> u16 { if ignore_case && (b'A' as u16..=b'Z' as u16).contains(&u) { u + 32 } else { u } }
pub unsafe extern "win64" fn CompareStringW(_locale: u32, flags: u32, a: *const u16, an: i32, b: *const u16, bn: i32) -> i32 {
    let ic = flags & 1 != 0;
    let (a, b) = (wide_slice(a, an), wide_slice(b, bn));
    match a.iter().map(|&u| fold(u, ic)).cmp(b.iter().map(|&u| fold(u, ic))) {
        std::cmp::Ordering::Less => 1, std::cmp::Ordering::Equal => 2, std::cmp::Ordering::Greater => 3,
    }
}
pub unsafe extern "win64" fn LCMapStringW(_locale: u32, flags: u32, src: *const u16, n: i32, dst: *mut u16, dst_n: i32) -> i32 {
    let s = if n < 0 { std::slice::from_raw_parts(src, wide_slice(src, -1).len() + 1) } else { wide_slice(src, n) };
    let out: Vec<u16> = s.iter().map(|&u| match (flags & 0x300, u) {
        (0x100, 65..=90) => u + 32,
        (0x200, 97..=122) => u - 32,
        _ => u,
    }).collect();
    if dst_n == 0 { return out.len() as i32; }
    partial(&out, dst, dst_n)
}
pub unsafe extern "win64" fn GetStringTypeW(kind: u32, src: *const u16, n: i32, out: *mut u16) -> Bool {
    if kind != 1 { set_error(ERROR_INVALID_PARAMETER); return FALSE; }
    for (i, &u) in wide_slice(src, n).iter().enumerate() {
        let c = char::from_u32(u as u32).unwrap_or('\u{fffd}');
        let mut t = 0x200u16; // C1_DEFINED
        if c.is_ascii_uppercase() { t |= 0x1 | 0x100; }
        if c.is_ascii_lowercase() { t |= 0x2 | 0x100; }
        if c.is_ascii_digit() { t |= 0x4; }
        if c.is_ascii_hexdigit() { t |= 0x80; }
        if c.is_whitespace() { t |= 0x8; }
        if c == ' ' || c == '\t' { t |= 0x40; }
        if c.is_ascii_punctuation() { t |= 0x10; }
        if c.is_control() { t |= 0x20; }
        if !c.is_ascii() && c.is_alphabetic() { t |= 0x100; }
        *out.add(i) = t;
    }
    TRUE
}

// ---------------------------------------------------------------- ADVAPI32

pub extern "win64" fn CryptAcquireContextA(out: *mut Handle, _container: usize, _provider: usize, _kind: u32, _flags: u32) -> Bool {
    called("CryptAcquireContextA");
    unsafe { *out = insert(Object::CryptProvider); }
    TRUE
}
pub unsafe extern "win64" fn CryptGenRandom(_provider: Handle, n: u32, buffer: *mut u8) -> Bool {
    called("CryptGenRandom");
    let mut done = 0usize;
    while done < n as usize {
        let r = libc::getrandom(buffer.add(done).cast(), n as usize - done, 0);
        if r <= 0 { return FALSE; }
        done += r as usize;
    }
    TRUE
}
pub extern "win64" fn CryptReleaseContext(h: Handle, _flags: u32) -> Bool { CloseHandle(h) }

fn root_key(h: Handle) -> Option<&'static str> {
    match h as u32 {
        0x8000_0000 => Some("HKEY_CLASSES_ROOT"),
        0x8000_0001 => Some("HKEY_CURRENT_USER"),
        0x8000_0002 => Some("HKEY_LOCAL_MACHINE"),
        0x8000_0003 => Some("HKEY_USERS"),
        _ => None,
    }
}
pub unsafe extern "win64" fn RegOpenKeyExA(parent: Handle, sub: *const u8, _opts: u32, _sam: u32, out: *mut Handle) -> i32 {
    called("RegOpenKeyExA");
    let base = match root_key(parent) {
        Some(r) => r.to_owned(),
        None => match host().handles.get(&parent) { Some(Object::Key(k)) => k.clone(), _ => return ERROR_INVALID_HANDLE as i32 },
    };
    let key = format!("{base}\\{}", narrow(sub));
    let known = host().machine.registry.keys().any(|k| k.rsplit_once('\\').is_some_and(|(p, _)| p.eq_ignore_ascii_case(&key)));
    event(format!("RegOpenKeyExA {key} -> {}", if known { "opened" } else { "absent" }));
    if !known { return ERROR_FILE_NOT_FOUND as i32; }
    *out = insert(Object::Key(key));
    0
}
pub unsafe extern "win64" fn RegQueryValueExA(h: Handle, name: *const u8, _reserved: usize, kind: *mut u32, data: *mut u8, size: *mut u32) -> i32 {
    called("RegQueryValueExA");
    let key = match host().handles.get(&h) { Some(Object::Key(k)) => k.clone(), _ => return ERROR_INVALID_HANDLE as i32 };
    let full = format!("{key}\\{}", narrow(name));
    let value = host().machine.registry.iter().find(|(k, _)| k.eq_ignore_ascii_case(&full)).map(|(_, v)| v.clone());
    event(format!("RegQueryValueExA {full} -> {}", if value.is_some() { "REG_SZ" } else { "absent" }));
    let Some(value) = value else { return ERROR_FILE_NOT_FOUND as i32 };
    let bytes = [value.as_bytes(), b"\0"].concat();
    if !kind.is_null() { *kind = 1; /* REG_SZ */ }
    if size.is_null() { return ERROR_INVALID_PARAMETER as i32; }
    let capacity = *size as usize;
    *size = bytes.len() as u32;
    if data.is_null() { return 0; }
    if capacity < bytes.len() { return ERROR_MORE_DATA as i32; }
    std::ptr::copy_nonoverlapping(bytes.as_ptr(), data, bytes.len());
    0
}
pub extern "win64" fn RegCloseKey(h: Handle) -> i32 { if CloseHandle(h) == TRUE { 0 } else { ERROR_INVALID_HANDLE as i32 } }

// ---------------------------------------------------------------- SHELL32 / SHLWAPI

pub unsafe extern "win64" fn SHGetFolderPathW(_hwnd: usize, csidl: i32, _token: Handle, _flags: u32, out: *mut u16) -> i32 {
    called("SHGetFolderPathW");
    let path = match csidl & 0xff {
        0x1a => r"C:\Users\zag\AppData\Roaming",
        0x1c => r"C:\Users\zag\AppData\Local",
        0x23 => r"C:\ProgramData",
        0x28 => r"C:\Users\zag",
        other => { event(format!("SHGetFolderPathW csidl={other:#x} -> unsupported")); return 0x8000_4005u32 as i32; }
    };
    event(format!("SHGetFolderPathW csidl={:#x} -> {path}", csidl & 0xff));
    if csidl & 0x8000 != 0 { // CSIDL_FLAG_CREATE
        if let Some(p) = map_path(path) { let _ = fs::DirBuilder::new().recursive(true).mode(0o700).create(p); }
    }
    put_wide(path, out, 260).map_or(0x8007_007au32 as i32, |_| 0)
}
pub unsafe extern "win64" fn PathAppendW(path: *mut u16, more: *const u16) -> Bool {
    called("PathAppendW");
    let (a, b) = (wide(path), wide(more));
    let joined = if a.is_empty() { b } else if b.is_empty() { a } else {
        format!("{}\\{}", a.trim_end_matches('\\'), b.trim_start_matches('\\'))
    };
    put_wide(&joined, path, 260).map_or(FALSE, |_| TRUE)
}
pub unsafe extern "win64" fn PathIsDirectoryW(path: *const u16) -> Bool {
    called("PathIsDirectoryW");
    let windows = wide(path);
    let is_dir = map_path(&windows).is_some_and(|p| p.is_dir());
    event(format!("PathIsDirectoryW {windows} -> {is_dir}"));
    if is_dir { FILE_ATTRIBUTE_DIRECTORY as Bool } else { FALSE }
}

// ---------------------------------------------------------------- time and names

const UNIX_TO_FILETIME_SECONDS: u64 = 11_644_473_600;
pub unsafe extern "win64" fn GetSystemTimeAsFileTime(out: *mut u64) {
    called("GetSystemTimeAsFileTime");
    let mut t = libc::timespec { tv_sec: 0, tv_nsec: 0 };
    libc::clock_gettime(libc::CLOCK_REALTIME, &mut t);
    *out = (t.tv_sec as u64 + UNIX_TO_FILETIME_SECONDS) * 10_000_000 + t.tv_nsec as u64 / 100;
}
pub unsafe extern "win64" fn FileTimeToSystemTime(ft: *const u64, st: *mut u16) -> Bool {
    called("FileTimeToSystemTime");
    let ticks = *ft;
    let Some(seconds) = (ticks / 10_000_000).checked_sub(UNIX_TO_FILETIME_SECONDS) else { set_error(ERROR_INVALID_PARAMETER); return FALSE };
    let seconds = seconds as libc::time_t;
    let mut tm: libc::tm = std::mem::zeroed();
    if libc::gmtime_r(&seconds, &mut tm).is_null() { set_error(ERROR_INVALID_PARAMETER); return FALSE; }
    let fields = [tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_wday, tm.tm_mday, tm.tm_hour, tm.tm_min, tm.tm_sec, ((ticks / 10_000) % 1000) as i32];
    for (i, v) in fields.iter().enumerate() { *st.add(i) = *v as u16; }
    TRUE
}
/// The host clock is UTC: local time equals system time.
pub unsafe extern "win64" fn SystemTimeToTzSpecificLocalTime(_tz: usize, utc: *const u16, local: *mut u16) -> Bool {
    std::ptr::copy_nonoverlapping(utc, local, 8);
    TRUE
}
pub unsafe extern "win64" fn GetTimeZoneInformation(info: *mut u8) -> u32 {
    called("GetTimeZoneInformation");
    std::ptr::write_bytes(info, 0, 172);
    0 // TIME_ZONE_ID_UNKNOWN: UTC
}
pub extern "win64" fn PeekNamedPipe(_h: Handle, _b: usize, _n: u32, _r: usize, _a: usize, _l: usize) -> Bool { set_error(ERROR_INVALID_HANDLE); FALSE }

/// Where the library would live in a standard iTunes installation.
const MODULE_PATH: &str = r"C:\Program Files\iTunes\CoreADI64.dll";
pub unsafe extern "win64" fn GetModuleFileNameA(_module: usize, buffer: *mut u8, n: u32) -> u32 {
    called("GetModuleFileNameA");
    event(format!("GetModuleFileNameA -> {MODULE_PATH}"));
    let bytes = MODULE_PATH.as_bytes();
    if n == 0 { set_error(122); return 0; }
    let copy = bytes.len().min(n as usize - 1);
    std::ptr::copy_nonoverlapping(bytes.as_ptr(), buffer, copy);
    *buffer.add(copy) = 0;
    if copy < bytes.len() { set_error(122); n } else { copy as u32 }
}
pub unsafe extern "win64" fn GetFullPathNameW(name: *const u16, n: u32, buffer: *mut u16, file_part: *mut *mut u16) -> u32 {
    called("GetFullPathNameW");
    let windows = wide(name).replace('/', "\\");
    let full = if windows.as_bytes().get(1) == Some(&b':') { windows.clone() } else { format!("C:\\{}", windows.trim_start_matches('\\')) };
    let needed = full.encode_utf16().count() as u32 + 1;
    trace(|| format!("GetFullPathNameW {windows:?} n={n} -> {full:?}"));
    match put_wide(&full, buffer, n as usize) {
        Some(len) => {
            if !file_part.is_null() {
                *file_part = match full.rfind('\\') { Some(i) if i + 1 < full.len() => buffer.add(full[..=i].encode_utf16().count()), _ => std::ptr::null_mut() };
            }
            len as u32
        }
        None => needed,
    }
}
pub unsafe extern "win64" fn GetUserNameA(buffer: *mut u8, n: *mut u32) -> Bool {
    called("GetUserNameA");
    event("GetUserNameA -> zag".into());
    let name = b"zag\0";
    if (*n as usize) < name.len() { *n = name.len() as u32; set_error(122); return FALSE; }
    std::ptr::copy_nonoverlapping(name.as_ptr(), buffer, name.len());
    *n = name.len() as u32;
    TRUE
}

// ---------------------------------------------------------------- binding

macro_rules! table {
    ($($dll:literal : [$($f:ident),* $(,)?]),* $(,)?) => {
        /// The host implementation of `dll!name`, if any.
        pub fn resolve(dll: &str, name: &str) -> Option<usize> {
            $( if dll.eq_ignore_ascii_case($dll) { $( if name == stringify!($f) { return Some($f as *const () as usize); } )* } )*
            None
        }
    };
}
table! {
    "KERNEL32.dll": [CreateEventA, CreateDirectoryW, SetEvent, WaitForSingleObject, GetVolumeInformationW,
        GetFileAttributesA, WideCharToMultiByte, GetFileAttributesW, CloseHandle, CreateMutexA, SetFileAttributesA,
        ResetEvent, ReleaseMutex, SignalObjectAndWait, GetLastError, SetFileAttributesW, SetEndOfFile, HeapReAlloc,
        HeapSize, QueryPerformanceCounter, GetCurrentProcessId, GetCurrentThreadId, InitializeSListHead,
        RtlCaptureContext, RtlLookupFunctionEntry, RtlVirtualUnwind, IsDebuggerPresent, UnhandledExceptionFilter,
        SetUnhandledExceptionFilter, GetStartupInfoW, IsProcessorFeaturePresent, GetModuleHandleW, RtlUnwindEx,
        InterlockedFlushSList, SetLastError, EnterCriticalSection, LeaveCriticalSection, DeleteCriticalSection,
        InitializeCriticalSectionAndSpinCount, TlsAlloc, TlsGetValue, TlsSetValue, TlsFree, FreeLibrary,
        GetProcAddress, LoadLibraryExW, CreateFileW, GetDriveTypeW, GetFileInformationByHandle, GetFileType,
        GetCurrentProcess, ExitProcess, TerminateProcess, GetModuleHandleExW, MultiByteToWideChar, HeapFree,
        HeapAlloc, CompareStringW, LCMapStringW, DeleteFileW, ReadFile, GetConsoleMode, ReadConsoleW, WriteFile,
        GetConsoleCP, GetCurrentDirectoryW, SetStdHandle, GetStdHandle, FindClose, FindFirstFileExA, FindNextFileA,
        IsValidCodePage, GetACP, GetOEMCP, GetCPInfo, GetCommandLineA, GetCommandLineW, GetEnvironmentStringsW,
        FreeEnvironmentStringsW, SetEnvironmentVariableA, GetProcessHeap, GetStringTypeW, FlushFileBuffers,
        SetFilePointerEx, WriteConsoleW, RaiseException, GetSystemTimeAsFileTime, PeekNamedPipe,
        SystemTimeToTzSpecificLocalTime, FileTimeToSystemTime, GetModuleFileNameA, GetFullPathNameW, GetTimeZoneInformation],
    "ADVAPI32.dll": [GetUserNameA, CryptGenRandom, CryptReleaseContext, RegCloseKey, CryptAcquireContextA, RegQueryValueExA, RegOpenKeyExA],
    "SHLWAPI.dll": [PathAppendW, PathIsDirectoryW],
    "SHELL32.dll": [SHGetFolderPathW],
}

// ---------------------------------------------------------------- thread environment

/// A minimal TEB/PEB behind %gs for the calling thread: the code reads the
/// stack limits (`__chkstk`, gs:0x08/0x10), the TEB self pointer (gs:0x30)
/// and the PEB (gs:0x60). Leaked: it lives as long as the thread.
pub fn install_thread_environment() -> std::io::Result<()> {
    let teb = Box::leak(vec![0u8; 0x2000].into_boxed_slice()).as_mut_ptr();
    let peb = Box::leak(vec![0u8; 0x1000].into_boxed_slice()).as_mut_ptr();
    unsafe {
        let mut attr: libc::pthread_attr_t = std::mem::zeroed();
        if libc::pthread_getattr_np(libc::pthread_self(), &mut attr) != 0 { return Err(std::io::Error::other("pthread_getattr_np")); }
        let (mut low, mut size) = (std::ptr::null_mut(), 0usize);
        libc::pthread_attr_getstack(&attr, &mut low, &mut size);
        libc::pthread_attr_destroy(&mut attr);
        let put = |p: *mut u8, o: usize, v: usize| *(p.add(o) as *mut usize) = v;
        put(teb, 0x08, low as usize + size); // StackBase
        put(teb, 0x10, low as usize + 0x10000); // StackLimit, above the guard
        put(teb, 0x30, teb as usize); // Self
        put(teb, 0x40, std::process::id() as usize); // ClientId.UniqueProcess
        put(teb, 0x48, libc::gettid() as usize); // ClientId.UniqueThread
        put(teb, 0x60, peb as usize); // ProcessEnvironmentBlock
        put(peb, 0x30, HEAP as usize); // ProcessHeap
        const ARCH_SET_GS: libc::c_int = 0x1001;
        if libc::syscall(libc::SYS_arch_prctl, ARCH_SET_GS, teb as usize) != 0 { return Err(std::io::Error::last_os_error()); }
    }
    Ok(())
}


#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn find_patterns_match_like_windows() {
        assert!(glob(b"adi*.pb", b"ADI-99086F85.pb"));
        assert!(glob(b"*", b"anything"));
        assert!(glob(b"a?i.pb", b"adi.pb"));
        assert!(!glob(b"adi*.pb", b"adi.pb.tmp"));
    }

    #[test]
    fn conversions_fill_a_short_buffer_then_fail() {
        let out = [1u8, 2, 3, 4];
        let mut dst = [0u8; 3];
        assert_eq!(unsafe { partial(&out, dst.as_mut_ptr(), 3) }, 0);
        assert_eq!(dst, [1, 2, 3]);
        assert_eq!(GetLastError(), 122);
        let mut dst = [0u8; 4];
        assert_eq!(unsafe { partial(&out, dst.as_mut_ptr(), 4) }, 4);
    }

    #[test]
    fn wide_output_is_terminated_and_the_rest_zeroed() {
        let mut buffer = [0xffffu16; 8];
        assert_eq!(unsafe { put_wide("C:\\x", buffer.as_mut_ptr(), 8) }, Some(4));
        assert_eq!(buffer, [b'C' as u16, b':' as u16, b'\\' as u16, b'x' as u16, 0, 0, 0, 0]);
        assert_eq!(unsafe { put_wide("C:\\x", buffer.as_mut_ptr(), 4) }, None);
    }

    #[test]
    fn every_coreadi_import_is_bound() {
        for name in ["HeapAlloc", "CreateFileW", "GetSystemTimeAsFileTime", "GetFullPathNameW", "RaiseException"] {
            assert!(resolve("KERNEL32.dll", name).is_some(), "{name}");
        }
        assert!(resolve("ADVAPI32.dll", "CryptGenRandom").is_some());
        assert!(resolve("SHELL32.dll", "SHGetFolderPathW").is_some());
        assert!(resolve("KERNEL32.dll", "CreateThread").is_none());
    }
}
