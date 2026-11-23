//! Supervised scoped live probe launcher (`live` feature only). See
//! `zag_apple_bridge::probe` for what it does and the environment it reads.
//! Without the `live` feature the binary refuses to run.

#[cfg(feature = "live")]
fn main() {
    std::process::exit(zag_apple_bridge::probe::run());
}

#[cfg(not(feature = "live"))]
fn main() {
    eprintln!("Build with --features live to run the scoped probe (it is compiled out of app builds).");
    std::process::exit(2);
}
