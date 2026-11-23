//! Minimal PE32+ loader for one self-contained x86_64 DLL: maps the
//! sections, applies base relocations, binds imports to host shims and sets
//! section protections. No Windows loader semantics beyond what CoreADI64
//! needs (no TLS directory, no delay imports, no forwarded exports).
use std::io;

fn bad(message: &str) -> io::Error { io::Error::new(io::ErrorKind::InvalidData, message.to_owned()) }

fn u16_at(d: &[u8], o: usize) -> io::Result<u16> {
    d.get(o..o + 2).map(|b| u16::from_le_bytes([b[0], b[1]])).ok_or_else(|| bad("truncated image"))
}
fn u32_at(d: &[u8], o: usize) -> io::Result<u32> {
    d.get(o..o + 4).map(|b| u32::from_le_bytes(b.try_into().unwrap())).ok_or_else(|| bad("truncated image"))
}
fn u64_at(d: &[u8], o: usize) -> io::Result<u64> {
    d.get(o..o + 8).map(|b| u64::from_le_bytes(b.try_into().unwrap())).ok_or_else(|| bad("truncated image"))
}

const IMAGE_FILE_MACHINE_AMD64: u16 = 0x8664;
const IMAGE_FILE_DLL: u16 = 0x2000;
const IMAGE_REL_BASED_ABSOLUTE: u16 = 0;
const IMAGE_REL_BASED_DIR64: u16 = 10;
const IMAGE_SCN_MEM_EXECUTE: u32 = 0x2000_0000;
const IMAGE_SCN_MEM_WRITE: u32 = 0x8000_0000;

struct Section { rva: usize, vsize: usize, raw_off: usize, raw_size: usize, flags: u32 }

/// A mapped image. It is never unmapped: the worker process exits instead.
pub struct Image {
    pub base: usize,
    pub size: usize,
    pub entry: usize,
    exports: Vec<(String, usize)>,
}

impl Image {
    pub fn export(&self, name: &str) -> Option<usize> {
        self.exports.iter().find(|(n, _)| n == name).map(|&(_, a)| a)
    }
    pub fn export_names(&self) -> Vec<&str> { self.exports.iter().map(|(n, _)| n.as_str()).collect() }

    /// Loads `file`. `resolve(dll, name)` returns the host address for an
    /// import; any unresolved import fails the load.
    pub fn load(file: &[u8], resolve: &dyn Fn(&str, &str) -> Option<usize>) -> io::Result<Image> {
        if file.get(..2) != Some(b"MZ") { return Err(bad("not an MZ image")); }
        let pe = u32_at(file, 0x3c)? as usize;
        if file.get(pe..pe + 4) != Some(b"PE\0\0") { return Err(bad("no PE signature")); }
        let coff = pe + 4;
        if u16_at(file, coff)? != IMAGE_FILE_MACHINE_AMD64 { return Err(bad("not an x86_64 image")); }
        if u16_at(file, coff + 18)? & IMAGE_FILE_DLL == 0 { return Err(bad("not a DLL")); }
        let sections_n = u16_at(file, coff + 2)? as usize;
        let opt_size = u16_at(file, coff + 16)? as usize;
        let opt = coff + 20;
        if u16_at(file, opt)? != 0x20b { return Err(bad("not PE32+")); }
        let entry_rva = u32_at(file, opt + 16)? as usize;
        let preferred = u64_at(file, opt + 24)? as usize;
        let size = u32_at(file, opt + 56)? as usize;
        let headers = u32_at(file, opt + 60)? as usize;
        let dirs_n = u32_at(file, opt + 108)? as usize;
        let dir = |i: usize| -> io::Result<(usize, usize)> {
            if i >= dirs_n { return Ok((0, 0)); }
            Ok((u32_at(file, opt + 112 + i * 8)? as usize, u32_at(file, opt + 116 + i * 8)? as usize))
        };
        if size == 0 || size > 64 << 20 || headers > size || headers > file.len() { return Err(bad("implausible image size")); }
        if dir(9)?.0 != 0 { return Err(bad("TLS directory not supported")); }
        if dir(13)?.0 != 0 { return Err(bad("delay imports not supported")); }

        let mut sections = Vec::with_capacity(sections_n);
        let table = opt + opt_size;
        for i in 0..sections_n {
            let s = table + i * 40;
            let section = Section {
                vsize: u32_at(file, s + 8)? as usize,
                rva: u32_at(file, s + 12)? as usize,
                raw_size: u32_at(file, s + 16)? as usize,
                raw_off: u32_at(file, s + 20)? as usize,
                flags: u32_at(file, s + 36)?,
            };
            let raw = section.raw_size.min(section.vsize.max(section.raw_size));
            if section.rva.checked_add(section.vsize.max(raw)).is_none_or(|end| end > size)
                || section.raw_off.checked_add(raw).is_none_or(|end| end > file.len())
                || section.rva % 0x1000 != 0
            {
                return Err(bad("section outside the image"));
            }
            sections.push(section);
        }

        // Map read-write first; protections are applied after binding.
        let base = unsafe {
            libc::mmap(preferred as *mut _, size, libc::PROT_READ | libc::PROT_WRITE,
                libc::MAP_PRIVATE | libc::MAP_ANONYMOUS, -1, 0)
        };
        if base == libc::MAP_FAILED { return Err(io::Error::last_os_error()); }
        let base = base as usize;
        let image = unsafe { std::slice::from_raw_parts_mut(base as *mut u8, size) };
        image[..headers].copy_from_slice(&file[..headers]);
        for s in &sections {
            let n = s.raw_size.min(s.vsize.max(s.raw_size)).min(size - s.rva);
            image[s.rva..s.rva + n].copy_from_slice(&file[s.raw_off..s.raw_off + n]);
        }

        // Base relocations.
        let delta = base.wrapping_sub(preferred);
        let (reloc_rva, reloc_size) = dir(5)?;
        if delta != 0 {
            if reloc_rva == 0 { return Err(bad("image needs relocation but has none")); }
            let mut at = reloc_rva;
            while at + 8 <= reloc_rva + reloc_size {
                let page = u32_at(image, at)? as usize;
                let block = u32_at(image, at + 4)? as usize;
                if block < 8 || at + block > reloc_rva + reloc_size { return Err(bad("bad relocation block")); }
                for e in (at + 8..at + block).step_by(2) {
                    let entry = u16_at(image, e)?;
                    let target = page + (entry & 0xfff) as usize;
                    match entry >> 12 {
                        IMAGE_REL_BASED_ABSOLUTE => {}
                        IMAGE_REL_BASED_DIR64 if target + 8 <= size => {
                            let value = u64_at(image, target)? as usize;
                            image[target..target + 8].copy_from_slice(&(value.wrapping_add(delta) as u64).to_le_bytes());
                        }
                        _ => return Err(bad("unsupported relocation")),
                    }
                }
                at += block;
            }
        }

        // Imports, bound by name only.
        let cstr = |image: &[u8], at: usize| -> io::Result<String> {
            let tail = image.get(at..).ok_or_else(|| bad("name outside image"))?;
            let end = tail.iter().position(|&b| b == 0).ok_or_else(|| bad("unterminated name"))?;
            Ok(String::from_utf8_lossy(&tail[..end]).into_owned())
        };
        let (imports_rva, _) = dir(1)?;
        let mut missing = Vec::new();
        let mut d = imports_rva;
        while imports_rva != 0 {
            let lookup = u32_at(image, d)? as usize;
            let name_rva = u32_at(image, d + 12)? as usize;
            let iat = u32_at(image, d + 16)? as usize;
            if name_rva == 0 && iat == 0 { break; }
            let dll = cstr(image, name_rva)?;
            let mut i = 0;
            loop {
                let thunk = u64_at(image, if lookup != 0 { lookup } else { iat } + i * 8)?;
                if thunk == 0 { break; }
                if thunk >> 63 == 1 { return Err(bad("ordinal imports not supported")); }
                let name = cstr(image, thunk as usize + 2)?;
                let address = resolve(&dll, &name).unwrap_or_else(|| { missing.push(format!("{dll}!{name}")); 0 });
                let slot = iat + i * 8;
                image[slot..slot + 8].copy_from_slice(&(address as u64).to_le_bytes());
                i += 1;
            }
            d += 20;
        }
        if !missing.is_empty() { return Err(bad(&format!("unresolved imports: {}", missing.join(" ")))); }

        // Exports by name.
        let mut exports = Vec::new();
        let (exports_rva, _) = dir(0)?;
        if exports_rva != 0 {
            let names_n = u32_at(image, exports_rva + 24)? as usize;
            let functions = u32_at(image, exports_rva + 28)? as usize;
            let names = u32_at(image, exports_rva + 32)? as usize;
            let ordinals = u32_at(image, exports_rva + 36)? as usize;
            for i in 0..names_n {
                let name = cstr(image, u32_at(image, names + i * 4)? as usize)?;
                let ordinal = u16_at(image, ordinals + i * 2)? as usize;
                let rva = u32_at(image, functions + ordinal * 4)? as usize;
                if rva >= size { return Err(bad("export outside image")); }
                exports.push((name, base + rva));
            }
        }

        // Protections: headers read-only, sections from their flags, never W+X.
        let page = |n: usize| (n + 0xfff) & !0xfff;
        let protect = |at: usize, len: usize, prot: i32| -> io::Result<()> {
            if unsafe { libc::mprotect((base + at) as *mut _, page(len), prot) } != 0 {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        };
        protect(0, headers, libc::PROT_READ)?;
        for s in &sections {
            let prot = if s.flags & IMAGE_SCN_MEM_EXECUTE != 0 {
                if s.flags & IMAGE_SCN_MEM_WRITE != 0 { return Err(bad("writable code section")); }
                libc::PROT_READ | libc::PROT_EXEC
            } else if s.flags & IMAGE_SCN_MEM_WRITE != 0 {
                libc::PROT_READ | libc::PROT_WRITE
            } else {
                libc::PROT_READ
            };
            protect(s.rva, s.vsize.max(1), prot)?;
        }
        Ok(Image { base, size, entry: base + entry_rva, exports })
    }
}
