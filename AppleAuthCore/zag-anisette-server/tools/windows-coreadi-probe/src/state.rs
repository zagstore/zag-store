//! The client-held state for the Windows backend.
//!
//! Windows CoreADI keeps its provisioning in a directory of files
//! (`C:\ProgramData\Apple Computer\iTunes\adi\adi.pb` plus machine-specific
//! `adi-<hex>.pb`), while a v3 client keeps one opaque `adi_pb` blob. The
//! blob is this container: a magic, then each regular file of the directory
//! in name order as `u16 name length, name, u32 length, bytes` (big-endian).
//! Packing is deterministic, so a state round-trips byte for byte, and
//! unpacking is strict: anything else is refused.
use std::fs;
use std::io;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::{Path, PathBuf};

const MAGIC: &[u8; 8] = b"ZWADI\x00\x01\x00";
/// The server's bound on a client's `adi_pb`.
pub const MAX_STATE: usize = 16 * 1024;
const MAX_FILES: usize = 8;

fn invalid(message: &str) -> io::Error { io::Error::new(io::ErrorKind::InvalidData, message.to_owned()) }

/// `C:\ProgramData\Apple Computer\iTunes\adi` inside a worker's private root.
pub fn adi_dir(root: &Path) -> PathBuf { root.join("c/ProgramData/Apple Computer/iTunes/adi") }

fn valid_name(name: &str) -> bool {
    (1..=64).contains(&name.len()) && !name.starts_with('.')
        && name.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'-' | b'_'))
}

/// Packs every file of `dir`. A subdirectory, link or odd name is refused.
pub fn pack(dir: &Path) -> io::Result<Vec<u8>> {
    let mut files = Vec::new();
    for entry in fs::read_dir(dir)? {
        let entry = entry?;
        let name = entry.file_name().into_string().map_err(|_| invalid("non-UTF-8 state file name"))?;
        if !entry.file_type()?.is_file() || !valid_name(&name) { return Err(invalid("unexpected entry in the state directory")); }
        files.push((name, fs::read(entry.path())?));
    }
    if files.is_empty() || files.len() > MAX_FILES { return Err(invalid("unexpected number of state files")); }
    files.sort();
    let mut out = MAGIC.to_vec();
    for (name, bytes) in &files {
        out.extend((name.len() as u16).to_be_bytes());
        out.extend(name.as_bytes());
        out.extend((bytes.len() as u32).to_be_bytes());
        out.extend(bytes);
    }
    if out.len() > MAX_STATE { return Err(invalid("state larger than a client may hold")); }
    Ok(out)
}

/// The files of a container, strictly validated.
pub fn parse(bytes: &[u8]) -> io::Result<Vec<(String, &[u8])>> {
    if bytes.len() > MAX_STATE || !bytes.starts_with(MAGIC) { return Err(invalid("not a Windows ADI state")); }
    fn take<'a>(bytes: &'a [u8], at: &mut usize, n: usize) -> io::Result<&'a [u8]> {
        let end = at.checked_add(n).filter(|&end| end <= bytes.len()).ok_or_else(|| invalid("truncated state"))?;
        let slice = &bytes[*at..end];
        *at = end;
        Ok(slice)
    }
    let mut at = MAGIC.len();
    let mut files: Vec<(String, &[u8])> = Vec::new();
    while at < bytes.len() {
        let name_len = u16::from_be_bytes(take(bytes, &mut at, 2)?.try_into().unwrap()) as usize;
        let name = std::str::from_utf8(take(bytes, &mut at, name_len)?).map_err(|_| invalid("bad state file name"))?.to_owned();
        let len = u32::from_be_bytes(take(bytes, &mut at, 4)?.try_into().unwrap()) as usize;
        let data = take(bytes, &mut at, len)?;
        if !valid_name(&name) || files.last().is_some_and(|(last, _)| *last >= name) || files.len() == MAX_FILES {
            return Err(invalid("state files are not unique, ordered and well named"));
        }
        files.push((name, data));
    }
    if files.is_empty() { return Err(invalid("empty state")); }
    Ok(files)
}

/// Writes a container's files into `dir`, created 0700; files are 0600.
pub fn unpack(bytes: &[u8], dir: &Path) -> io::Result<()> {
    let files = parse(bytes)?;
    fs::DirBuilder::new().recursive(true).mode(0o700).create(dir)?;
    for (name, data) in files {
        let mut file = fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(dir.join(name))?;
        io::Write::write_all(&mut file, data)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn containers_round_trip_and_are_strict() {
        let dir = std::env::temp_dir().join(format!("zwadi-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("adi.pb"), b"one").unwrap();
        fs::write(dir.join("adi-99086F85.pb"), b"two").unwrap();
        let packed = pack(&dir).unwrap();
        let files = parse(&packed).unwrap();
        assert_eq!(files.iter().map(|(n, _)| n.as_str()).collect::<Vec<_>>(), ["adi-99086F85.pb", "adi.pb"]);
        let copy = dir.join("copy");
        unpack(&packed, &copy).unwrap();
        fs::remove_dir_all(dir.join("copy")).unwrap();
        assert_eq!(pack(&dir).unwrap(), packed);
        // Truncation, trailing bytes, reordering, bad names and plain bytes are refused.
        assert!(parse(&packed[..packed.len() - 1]).is_err());
        assert!(parse(&[packed.as_slice(), &[0]].concat()).is_err());
        assert!(parse(b"not an Apple-issued adi.pb").is_err());
        assert!(parse(MAGIC).is_err());
        let entry = |name: &str| [&(name.len() as u16).to_be_bytes()[..], name.as_bytes(), &1u32.to_be_bytes(), b"x"].concat();
        assert!(parse(&[&MAGIC[..], &entry("b"), &entry("a")].concat()).is_err());
        assert!(parse(&[&MAGIC[..], &entry("../x")].concat()).is_err());
        assert!(parse(&[&MAGIC[..], &entry("a"), &entry("a")].concat()).is_err());
        fs::create_dir(dir.join("sub")).unwrap();
        assert!(pack(&dir).is_err());
        fs::remove_dir_all(&dir).unwrap();
    }
}
