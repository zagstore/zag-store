//! Calls into the Windows CoreADI dispatcher (`vdfut768ig`).
//!
//! The dispatcher takes a 32-bit function code and a parameter block. The
//! block points at one buffer holding the request, encoded as fixed-width
//! big-endian fields: `u32 1` (clear payload), `u32 1` (marker), then the
//! message fields in order, with pointers as u64. The library writes the
//! status back into the first four bytes of the same buffer.
pub const INITIALIZE: u32 = 0x12db_31c5;
pub const IS_MACHINE_PROVISIONED: u32 = 0xb0ed_a7af;
pub const PROVISIONING_START: u32 = 0x716b_d86c;
pub const REQUEST_OTP: u32 = 0xcfe0_b46a;
pub const STORAGE_DISPOSE: u32 = 0x3e58_e7f9;
pub const TEAR_DOWN: u32 = 0x08c0_fe9e;

pub const NOT_PROVISIONED: i32 = -45061;

#[repr(C)]
struct Parameters { payload: *mut u8, input_size: u32, output_size: u32, flags: u32 }

type Dispatcher = unsafe extern "win64" fn(u32, *const Parameters) -> i32;

pub struct CoreAdi { dispatch: Dispatcher }

/// Builds one request buffer.
#[derive(Default)]
pub struct Message(Vec<u8>);
impl Message {
    pub fn new() -> Self { Message([1u32.to_be_bytes(), 1u32.to_be_bytes()].concat()) }
    pub fn i64(mut self, v: i64) -> Self { self.0.extend(v.to_be_bytes()); self }
    pub fn u32(mut self, v: u32) -> Self { self.0.extend(v.to_be_bytes()); self }
    pub fn ptr<T>(mut self, p: *const T) -> Self { self.0.extend((p as u64).to_be_bytes()); self }
}

/// The two status channels: the dispatcher's return value, and the status
/// the call wrote back into the buffer.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Status { pub dispatch: i32, pub result: i32 }
impl Status {
    /// The ADI status a caller acts on.
    pub fn code(self) -> i32 { if self.dispatch < 0 { self.dispatch } else { self.result } }
}

impl CoreAdi {
    /// # Safety
    /// `address` must be the loaded library's `vdfut768ig` export.
    pub unsafe fn new(address: usize) -> Self { CoreAdi { dispatch: std::mem::transmute::<usize, Dispatcher>(address) } }

    pub fn call(&self, code: u32, message: Message) -> Status {
        let mut buffer = message.0.into_boxed_slice();
        let parameters = Parameters { payload: buffer.as_mut_ptr(), input_size: buffer.len() as u32, output_size: 4, flags: 0 };
        let dispatch = unsafe { (self.dispatch)(code, &parameters) };
        let result = i32::from_be_bytes(buffer[..4].try_into().unwrap());
        Status { dispatch, result }
    }

    pub fn initialize(&self) -> Status { self.call(INITIALIZE, Message::new()) }
    pub fn is_machine_provisioned(&self, ds_id: i64) -> Status { self.call(IS_MACHINE_PROVISIONED, Message::new().i64(ds_id)) }
    pub fn tear_down(&self) -> Status { self.call(TEAR_DOWN, Message::new()) }

    /// Returns the status and, on success, (machine id, OTP) lengths only.
    pub fn request_otp(&self, ds_id: i64) -> (Status, Option<(usize, usize)>) {
        let (mut mid, mut mid_len, mut otp, mut otp_len) = (std::ptr::null::<u8>(), 0u32, std::ptr::null::<u8>(), 0u32);
        let status = self.call(REQUEST_OTP, Message::new().i64(ds_id)
            .ptr(&mut mid as *mut _).ptr(&mut mid_len as *mut _).ptr(&mut otp as *mut _).ptr(&mut otp_len as *mut _));
        if status.code() != 0 { return (status, None); }
        let lengths = (mid_len as usize, otp_len as usize);
        for p in [mid, otp] { if !p.is_null() { self.call(STORAGE_DISPOSE, Message::new().ptr(p)); } }
        (status, Some(lengths))
    }

    /// Starts provisioning with `spim`; returns the status and the CPIM length.
    pub fn start_provisioning(&self, ds_id: i64, spim: &[u8]) -> (Status, Option<usize>) {
        let (mut cpim, mut cpim_len, mut session) = (std::ptr::null::<u8>(), 0u32, 0u32);
        let status = self.call(PROVISIONING_START, Message::new().i64(ds_id).ptr(spim.as_ptr()).u32(spim.len() as u32)
            .ptr(&mut cpim as *mut _).ptr(&mut cpim_len as *mut _).ptr(&mut session as *mut _));
        if status.code() != 0 { return (status, None); }
        if !cpim.is_null() { self.call(STORAGE_DISPOSE, Message::new().ptr(cpim)); }
        (status, Some(cpim_len as usize))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn messages_are_fixed_width_big_endian() {
        assert_eq!(Message::new().0, [0, 0, 0, 1, 0, 0, 0, 1]);
        assert_eq!(Message::new().i64(-2).0[8..], [0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xfe]);
        assert_eq!(Message::new().u32(0x0102_0304).ptr(0x1122usize as *const u8).0[8..],
            [1, 2, 3, 4, 0, 0, 0, 0, 0, 0, 0x11, 0x22]);
        assert_eq!(Status { dispatch: -1, result: 0 }.code(), -1);
        assert_eq!(Status { dispatch: 0, result: NOT_PROVISIONED }.code(), NOT_PROVISIONED);
    }
}
