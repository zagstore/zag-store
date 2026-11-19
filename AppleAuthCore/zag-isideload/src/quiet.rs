// Zag Store fork: logging is compiled out.
//
// Upstream logs through `tracing`, at debug level including anisette
// provisioning messages. These macros keep upstream's call sites unchanged
// but never evaluate or format their arguments, so nothing an account,
// a session or a device identifier reaches a log from this crate.

macro_rules! debug {
    ($($t:tt)*) => {
        if false {
            let _ = format_args!($($t)*);
        }
    };
}

macro_rules! info {
    ($($t:tt)*) => {
        if false {
            let _ = format_args!($($t)*);
        }
    };
}

macro_rules! warn {
    ($($t:tt)*) => {
        if false {
            let _ = format_args!($($t)*);
        }
    };
}

macro_rules! error {
    ($($t:tt)*) => {
        if false {
            let _ = format_args!($($t)*);
        }
    };
}
