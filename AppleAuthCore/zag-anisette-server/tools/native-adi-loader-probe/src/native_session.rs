//! Native ADI lifecycle bridge for the isolated, operator-run probe.
//!
//! This module resolves the audited StoreServicesCore entry points. It does
//! not issue requests or modify live services; provisioning material only
//! passes through it from a supervised coordinator.
//! Keep the mapped AndroidLibrary alive longer than NativeFunctions and Session.
use android_loader::android_library::AndroidLibrary;
use android_loader::sysv64_type;
use std::io;

const MAX_MATERIAL: usize = 16 * 1024;

type StartFn = sysv64_type!(fn(i64, *const u8, u32, *mut *const u8, *mut u32, *mut u32) -> i32);
type EndFn = sysv64_type!(fn(u32, *const u8, u32, *const u8, u32) -> i32);
type DestroyFn = sysv64_type!(fn(u32) -> i32);
type DisposeFn = sysv64_type!(fn(*const u8) -> i32);
type LoginCodeFn = sysv64_type!(fn(i64) -> i32);
type OtpFn = sysv64_type!(fn(i64, *mut *const u8, *mut u32, *mut *const u8, *mut u32) -> i32);

/// ADIGetLoginCode result for a state directory that holds no provisioning.
pub const NOT_PROVISIONED: i32 = -45061;

fn native_failure(phase: &'static str) -> io::Error {
    io::Error::new(io::ErrorKind::Other, phase)
}
fn invalid(reason: &'static str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, reason)
}

/// These function pointers must not outlive the mapped library.
pub struct NativeFunctions<'a> {
    _library: &'a AndroidLibrary<'a>,
    start: StartFn,
    end: EndFn,
    destroy: DestroyFn,
    dispose: DisposeFn,
    login_code: LoginCodeFn,
    otp: OtpFn,
}

impl<'a> NativeFunctions<'a> {
    pub fn resolve(library: &'a AndroidLibrary<'a>) -> io::Result<Self> {
        let symbol = |name| library.get_symbol(name).ok_or_else(|| invalid("missing native ADI symbol"));
        // Audited against SideStore/apple-private-apis@03beb1aa and
        // Dadoum/Provision@7717ce1f, confirmed present on user's local APK.
        Ok(Self {
            _library: library,
            start: unsafe { std::mem::transmute::<*const (), StartFn>(symbol("rsegvyrt87")?) },
            end: unsafe { std::mem::transmute::<*const (), EndFn>(symbol("uv5t6nhkui")?) },
            destroy: unsafe { std::mem::transmute::<*const (), DestroyFn>(symbol("fy34trz2st")?) },
            dispose: unsafe { std::mem::transmute::<*const (), DisposeFn>(symbol("jk24uiwqrg")?) },
            login_code: unsafe { std::mem::transmute::<*const (), LoginCodeFn>(symbol("aslgmuibau")?) },
            otp: unsafe { std::mem::transmute::<*const (), OtpFn>(symbol("qi864985u0")?) },
        })
    }

    /// Whether the configured state directory holds provisioning for ds_id.
    /// Any status other than success or NOT_PROVISIONED is an error.
    pub fn is_provisioned(&self, ds_id: i64) -> io::Result<bool> {
        match (self.login_code)(ds_id) {
            0 => Ok(true),
            NOT_PROVISIONED => Ok(false),
            _ => Err(native_failure("native ADI login-code query returned error")),
        }
    }

    /// Proves the configured state can generate headers: requests one OTP
    /// and machine identifier, checks both are present, and disposes them
    /// without exposing their contents. Returns nothing on purpose.
    pub fn check_otp(&self, ds_id: i64) -> io::Result<()> {
        let (mut mid_ptr, mut mid_len): (*const u8, u32) = (std::ptr::null(), 0);
        let (mut otp_ptr, mut otp_len): (*const u8, u32) = (std::ptr::null(), 0);
        let code = (self.otp)(ds_id, &mut mid_ptr, &mut mid_len, &mut otp_ptr, &mut otp_len);
        let _mid = NativeAllocation { ptr: mid_ptr, dispose: self.dispose };
        let _otp = NativeAllocation { ptr: otp_ptr, dispose: self.dispose };
        if code != 0 {
            return Err(native_failure("native ADI OTP request returned error"));
        }
        if mid_ptr.is_null() || otp_ptr.is_null() || mid_len == 0 || otp_len == 0
            || mid_len as usize > MAX_MATERIAL || otp_len as usize > MAX_MATERIAL {
            return Err(invalid("invalid OTP material returned by native ADI"));
        }
        Ok(())
    }

    /// The caller must first initialize CoreADI, set its state directory and
    /// Android identifier, and supply real Apple-issued SPIM and an intended
    /// ds_id. No part of this method creates those values.
    #[allow(dead_code)]
    pub fn start(&self, ds_id: i64, spim: &[u8]) -> io::Result<(Session<'_, 'a>, Vec<u8>)> {
        if spim.is_empty() || spim.len() > MAX_MATERIAL {
            return Err(invalid("invalid SPIM size"));
        }
        let mut cpim_ptr: *const u8 = std::ptr::null();
        let mut cpim_len: u32 = 0;
        let mut session_id: u32 = 0;
        let code = (self.start)(
            ds_id, spim.as_ptr(), spim.len() as u32,
            &mut cpim_ptr, &mut cpim_len, &mut session_id,
        );
        // A native allocation belongs to ADIDispose, not Rust's allocator.
        let cpim_allocation = NativeAllocation { ptr: cpim_ptr, dispose: self.dispose };
        if code != 0 {
            return Err(native_failure("native ADI Start returned error"));
        }
        // Take ownership immediately after successful Start so every Rust
        // error/return attempts the matching native Destroy once.
        let session = Session { functions: self, handle: Some(session_id) };
        if cpim_ptr.is_null() || cpim_len == 0 || cpim_len as usize > MAX_MATERIAL {
            return Err(invalid("invalid CPIM returned by native Start"));
        }
        let cpim = unsafe { std::slice::from_raw_parts(cpim_allocation.ptr, cpim_len as usize) }.to_vec();
        Ok((session, cpim))
    }
}

/// An Apple-allocated CPIM buffer must always be freed by the Apple API.
struct NativeAllocation {
    ptr: *const u8,
    dispose: DisposeFn,
}
impl Drop for NativeAllocation {
    fn drop(&mut self) {
        if !self.ptr.is_null() {
            let _ = (self.dispose)(self.ptr);
        }
    }
}

/// Owns one native handle. Never serialize it, duplicate it, or hold it across
/// worker processes. End and Destroy are distinct native operations.
pub struct Session<'f, 'a> {
    functions: &'f NativeFunctions<'a>,
    handle: Option<u32>,
}
impl Session<'_, '_> {
    #[allow(dead_code)]
    pub fn finish(&mut self, ptm: &[u8], tk: &[u8]) -> io::Result<()> {
        if ptm.is_empty() || tk.is_empty() ||
            ptm.len() > MAX_MATERIAL || tk.len() > MAX_MATERIAL {
            return Err(invalid("invalid Finish material size"));
        }
        let handle = self.handle.ok_or_else(|| invalid("session already closed"))?;
        let end_code = (self.functions.end)(
            handle, ptm.as_ptr(), ptm.len() as u32,
            tk.as_ptr(), tk.len() as u32,
        );
        // Destroy even if End fails; a failed native Destroy is terminal.
        let destroy_result = self.close();
        if end_code != 0 {
            return Err(native_failure("native ADI End returned error"));
        }
        destroy_result
    }

    fn close(&mut self) -> io::Result<()> {
        if let Some(handle) = self.handle.take() {
            if (self.functions.destroy)(handle) != 0 {
                return Err(native_failure("native ADI Destroy returned error"));
            }
        }
        Ok(())
    }
}
impl Drop for Session<'_, '_> {
    fn drop(&mut self) {
        let _ = self.close();
    }
}
