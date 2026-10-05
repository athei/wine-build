//! Reading a PE image's `VS_VERSIONINFO` so the database can match on a
//! version fingerprint (company, product, original filename) that is stable
//! across install location and patches.
//!
//! There are two places to read it from. The main image of the running process
//! is already mapped when this library loads, so a resource RVA is just an
//! offset from the image base. An executable that ntdll asks about before it
//! starts the process is read from its file, where an RVA has to be translated
//! through the section table first. Both go through the same resource walk
//! over [`Rva`], and every read is bounds checked: a malformed or
//! resource-free image yields an empty [`VersionInfo`], never a wild read.

use core::ffi::c_void;
use std::{fs::File, os::unix::fs::FileExt as _, path::Path};

use compatdb_table::VersionInfo;

/// Read the version fingerprint of the image mapped at `image_base`.
pub fn read(image_base: *const c_void) -> VersionInfo {
    Mapped::new(image_base).map_or_else(VersionInfo::default, |img| from_image(&img))
}

/// Read the version fingerprint of the PE file at `path`. A file that cannot
/// be opened or is not a PE yields an empty [`VersionInfo`].
pub fn read_file(path: &Path) -> VersionInfo {
    File::open(path)
        .ok()
        .and_then(PeFile::new)
        .map_or_else(VersionInfo::default, |img| from_image(&img))
}

/// The most bytes read for a version resource. `VS_VERSIONINFO` records its
/// own length in a 16-bit field, so nothing past this can belong to it, and a
/// corrupt size field cannot make the reader allocate more.
const MAX_VERSION_BLOB: usize = 0x1_0000;

/// The most sections a file may declare before it is treated as malformed.
/// Windows XP refused images with more than 96, and real executables stay far
/// below even that; this bound only keeps a hostile header from making the
/// reader load and scan a section table of up to 65535 entries.
const MAX_SECTIONS: usize = 1024;

/// The granularity the loader rounds `PointerToRawData` down to, whatever the
/// header's `FileAlignment` says.
const RAW_DATA_ALIGNMENT: usize = 0x200;

/// The smallest page size the image can be mapped with. A `SectionAlignment`
/// below it means the loader maps the file as is, without moving sections.
const PAGE_SIZE: usize = 0x1000;

/// Bounds-checked reads by RVA from some layout of a PE image.
trait Rva {
    /// Fill `buf` with the bytes at `rva`, or return `None` when any of them
    /// lies outside what this source can supply.
    fn read(&self, rva: usize, buf: &mut [u8]) -> Option<()>;

    fn u16(&self, rva: usize) -> Option<u16> {
        let mut b = [0; 2];
        self.read(rva, &mut b)?;
        Some(u16::from_le_bytes(b))
    }

    fn u32(&self, rva: usize) -> Option<u32> {
        let mut b = [0; 4];
        self.read(rva, &mut b)?;
        Some(u32::from_le_bytes(b))
    }
}

/// Raw bytes, read at their own offsets. Used for the section table and, in
/// the tests, for whole images.
impl Rva for [u8] {
    fn read(&self, rva: usize, buf: &mut [u8]) -> Option<()> {
        buf.copy_from_slice(self.get(rva..rva.checked_add(buf.len())?)?);
        Some(())
    }
}

impl<T: Rva + ?Sized> Rva for &T {
    fn read(&self, rva: usize, buf: &mut [u8]) -> Option<()> {
        (**self).read(rva, buf)
    }
}

/// A file, read at its own offsets. Only right for the headers, which sit at
/// the start of the file at the same offsets they have in the image;
/// [`PeFile`] translates everything else.
impl Rva for File {
    fn read(&self, rva: usize, buf: &mut [u8]) -> Option<()> {
        self.read_exact_at(buf, u64::try_from(rva).ok()?).ok()
    }
}

/// The main image, mapped by the loader at `base` and `size` bytes long.
struct Mapped {
    base: *const u8,
    size: usize,
}

impl Mapped {
    /// The image at `image_base`, bounded by its own `SizeOfImage`.
    fn new(image_base: *const c_void) -> Option<Self> {
        if image_base.is_null() {
            return None;
        }
        let base = image_base.cast::<u8>();
        // The headers always occupy the first page, which is enough to read
        // the real extent from.
        let bootstrap = Self { base, size: 0x1000 };
        let size = Headers::parse(&bootstrap)?.size_of_image;
        Some(Self { base, size })
    }
}

impl Rva for Mapped {
    fn read(&self, rva: usize, buf: &mut [u8]) -> Option<()> {
        if rva.checked_add(buf.len())? > self.size {
            return None;
        }
        // SAFETY: rva..rva+len lies within [0, size), the image's own extent,
        // which the loader mapped readable before this library was loaded.
        let src = unsafe { std::slice::from_raw_parts(self.base.add(rva), buf.len()) };
        buf.copy_from_slice(src);
        Some(())
    }
}

/// One entry of the section table: where a section sits in the image and
/// where its bytes are in the file.
struct Section {
    virtual_address: usize,
    virtual_size: usize,
    raw_offset: usize,
    raw_size: usize,
}

/// A PE file read through its section table, so that RVAs land where the
/// loader would have mapped them.
struct PeFile<S> {
    source: S,
    size_of_headers: usize,
    sections: Vec<Section>,
    /// The low-alignment layout (`FileAlignment == SectionAlignment`, below
    /// a page), which the loader maps flat, so every RVA is its file offset.
    flat: bool,
}

impl<S: Rva> PeFile<S> {
    /// Read the headers and the section table of `source`.
    fn new(source: S) -> Option<Self> {
        let headers = Headers::parse(&source)?;
        if headers.section_count > MAX_SECTIONS {
            return None;
        }
        let mut table = vec![0; headers.section_count.checked_mul(40)?];
        source.read(headers.section_table, &mut table)?;
        let table = table.as_slice();
        let mut sections = Vec::with_capacity(headers.section_count);
        for i in 0..headers.section_count {
            let at = i.checked_mul(40)?;
            let field = |off: usize| -> Option<usize> {
                usize::try_from(table.u32(at.checked_add(off)?)?).ok()
            };
            sections.push(Section {
                virtual_size: field(8)?,
                virtual_address: field(12)?,
                raw_size: field(16)?,
                raw_offset: field(20)?,
            });
        }
        Some(Self {
            source,
            size_of_headers: headers.header_size,
            sections,
            flat: headers.section_alignment != 0
                && headers.section_alignment < PAGE_SIZE
                && headers.section_alignment == headers.file_alignment,
        })
    }

    /// The file offset of the `len` bytes at `rva`, when they are all backed
    /// by the file. Bytes in a section's zero-filled tail, or outside every
    /// section and the headers, are not.
    fn offset(&self, rva: usize, len: usize) -> Option<usize> {
        if self.flat {
            return Some(rva);
        }
        for s in &self.sections {
            let extent = if s.virtual_size == 0 {
                s.raw_size
            } else {
                s.virtual_size
            };
            let Some(delta) = rva.checked_sub(s.virtual_address) else {
                continue;
            };
            if delta >= extent {
                continue;
            }
            if delta.checked_add(len)? > s.raw_size {
                return None;
            }
            return (s.raw_offset & !(RAW_DATA_ALIGNMENT - 1)).checked_add(delta);
        }
        (rva.checked_add(len)? <= self.size_of_headers).then_some(rva)
    }
}

impl<S: Rva> Rva for PeFile<S> {
    fn read(&self, rva: usize, buf: &mut [u8]) -> Option<()> {
        let offset = self.offset(rva, buf.len())?;
        self.source.read(offset, buf)
    }
}

/// The header fields the reader needs, all as RVAs or sizes.
struct Headers {
    size_of_image: usize,
    /// `SizeOfHeaders`.
    header_size: usize,
    section_alignment: usize,
    file_alignment: usize,
    section_count: usize,
    section_table: usize,
    /// The resource directory's RVA, 0 when the image has none.
    resource_rva: usize,
}

impl Headers {
    fn parse<R: Rva + ?Sized>(img: &R) -> Option<Self> {
        let e_lfanew = usize::try_from(img.u32(0x3c)?).ok()?;
        let mut signature = [0; 4];
        img.read(e_lfanew, &mut signature)?;
        if &signature != b"PE\0\0" {
            return None;
        }
        let coff = e_lfanew.checked_add(4)?;
        let section_count = usize::from(img.u16(coff.checked_add(2)?)?);
        let optional_size = usize::from(img.u16(coff.checked_add(16)?)?);
        let opt = coff.checked_add(20)?;
        let pe32plus = img.u16(opt)? == 0x20b;
        let section_alignment = usize::try_from(img.u32(opt.checked_add(32)?)?).ok()?;
        let file_alignment = usize::try_from(img.u32(opt.checked_add(36)?)?).ok()?;
        let size_of_image = usize::try_from(img.u32(opt.checked_add(56)?)?).ok()?;
        let header_size = usize::try_from(img.u32(opt.checked_add(60)?)?).ok()?;
        // NumberOfRvaAndSizes, then the data directories (8 bytes each); the
        // resource directory is entry 2.
        let (count_at, dirs_at) = if pe32plus { (108, 112) } else { (92, 96) };
        let dir_count = img.u32(opt.checked_add(count_at)?)?;
        let resource_rva = if dir_count > 2 {
            usize::try_from(img.u32(opt.checked_add(dirs_at + 2 * 8)?)?).ok()?
        } else {
            0
        };
        Some(Self {
            size_of_image,
            header_size,
            section_alignment,
            file_alignment,
            section_count,
            section_table: opt.checked_add(optional_size)?,
            resource_rva,
        })
    }
}

fn from_image<R: Rva + ?Sized>(img: &R) -> VersionInfo {
    version_blob(img)
        .map(|blob| VersionInfo::from_resource(&blob))
        .unwrap_or_default()
}

fn version_blob<R: Rva + ?Sized>(img: &R) -> Option<Vec<u16>> {
    let res_rva = Headers::parse(img)?.resource_rva;
    if res_rva == 0 {
        return None;
    }

    // RT_VERSION, then the first name and the first language under it.
    let ver_dir = find_id_subdir(img, res_rva, res_rva, 16)?;
    let (name_child, name_is_dir) = first_child(img, res_rva, ver_dir)?;
    if !name_is_dir {
        return None;
    }
    let (lang_leaf, lang_is_dir) = first_child(img, res_rva, name_child)?;
    if lang_is_dir {
        return None;
    }

    // IMAGE_RESOURCE_DATA_ENTRY: OffsetToData (an RVA), Size.
    let data_rva = usize::try_from(img.u32(lang_leaf)?).ok()?;
    let data_size = usize::try_from(img.u32(lang_leaf.checked_add(4)?)?).ok()?;
    let mut raw = vec![0; data_size.min(MAX_VERSION_BLOB)];
    img.read(data_rva, &mut raw)?;

    // The blob is UTF-16; collect the u16 units.
    Some(
        raw.as_chunks::<2>()
            .0
            .iter()
            .map(|c| u16::from_le_bytes(*c))
            .collect(),
    )
}

/// Find the sub-directory for a resource entry with numeric id `id` in the
/// directory at `dir_off`. `res_base` is the resource section base (offsets in
/// entries are relative to it).
fn find_id_subdir<R: Rva + ?Sized>(
    img: &R,
    res_base: usize,
    dir_off: usize,
    id: u32,
) -> Option<usize> {
    let named = usize::from(img.u16(dir_off.checked_add(12)?)?);
    let ids = usize::from(img.u16(dir_off.checked_add(14)?)?);
    let entries = dir_off.checked_add(16)?;
    // The named entries come first, so only the id entries after them can
    // match. That also caps the scan at the 65535 entries the count can
    // declare, whatever a hostile name count says.
    for i in named..named.checked_add(ids)? {
        let eo = entries.checked_add(i.checked_mul(8)?)?;
        let name = img.u32(eo)?;
        let offset = img.u32(eo.checked_add(4)?)?;
        // An id entry whose id matches, pointing at a sub-directory (high bit
        // of offset set). An id entry has the high bit of its name clear, so
        // the comparison checks that too.
        if name == id && offset & 0x8000_0000 != 0 {
            return res_base.checked_add(usize::try_from(offset & 0x7fff_ffff).ok()?);
        }
    }
    None
}

/// The first entry of a resource directory: its child offset (relative to
/// `res_base`) and whether that child is another directory.
fn first_child<R: Rva + ?Sized>(img: &R, res_base: usize, dir_off: usize) -> Option<(usize, bool)> {
    let named = usize::from(img.u16(dir_off.checked_add(12)?)?);
    let ids = usize::from(img.u16(dir_off.checked_add(14)?)?);
    if named.checked_add(ids)? == 0 {
        return None;
    }
    let offset = img.u32(dir_off.checked_add(16 + 4)?)?;
    let child = res_base.checked_add(usize::try_from(offset & 0x7fff_ffff).ok()?)?;
    Some((child, offset & 0x8000_0000 != 0))
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::indexing_slicing)]
mod tests {
    use super::*;

    const SECTION_RVA: usize = 0x2000;
    const SECTION_FILE_OFFSET: usize = 0x200;
    const SIZE_OF_IMAGE: usize = 0x3000;

    fn put16(buf: &mut [u8], at: usize, v: u16) {
        buf[at..at + 2].copy_from_slice(&v.to_le_bytes());
    }

    fn put32(buf: &mut [u8], at: usize, v: u32) {
        buf[at..at + 4].copy_from_slice(&v.to_le_bytes());
    }

    fn u32_of(v: usize) -> u32 {
        u32::try_from(v).unwrap()
    }

    /// A `VS_VERSIONINFO`-shaped blob holding the three fields.
    fn version_blob_bytes() -> Vec<u8> {
        let mut units: Vec<u16> = Vec::new();
        for (key, value) in [
            ("CompanyName", "Acme Games"),
            ("ProductName", "Rocket Sled"),
            ("OriginalFilename", "Sled.exe"),
        ] {
            units.extend([0x40, 0x0f, 0x01]);
            units.extend(key.encode_utf16());
            units.extend([0, 0]);
            units.extend(value.encode_utf16());
            units.push(0);
        }
        units.iter().flat_map(|u| u.to_le_bytes()).collect()
    }

    /// The `.rsrc` section's bytes, laid out for `SECTION_RVA`: a three-level
    /// directory (`RT_VERSION`, name 1, language 0x409), the data entry, and
    /// the blob.
    fn rsrc_section() -> Vec<u8> {
        let blob = version_blob_bytes();
        let mut s = vec![0; 0x60 + blob.len()];
        // Each directory: 16-byte header, then one id entry.
        for (dir, id, child) in [
            (0x00, 16, 0x8000_0018),
            (0x18, 1, 0x8000_0030),
            (0x30, 0x409, 0x48),
        ] {
            put16(&mut s, dir + 14, 1);
            put32(&mut s, dir + 16, id);
            put32(&mut s, dir + 20, child);
        }
        put32(&mut s, 0x48, u32_of(SECTION_RVA + 0x60));
        put32(&mut s, 0x4c, u32_of(blob.len()));
        s[0x60..].copy_from_slice(&blob);
        s
    }

    /// PE32 headers with one `.rsrc` section of `raw_size` bytes.
    fn headers(raw_size: usize) -> Vec<u8> {
        let mut h = vec![0; SECTION_FILE_OFFSET];
        h[0..2].copy_from_slice(b"MZ");
        put32(&mut h, 0x3c, 0x40);
        h[0x40..0x44].copy_from_slice(b"PE\0\0");
        let coff = 0x44;
        put16(&mut h, coff, 0x14c);
        put16(&mut h, coff + 2, 1);
        put16(&mut h, coff + 16, 0xe0);
        let opt = coff + 20;
        put16(&mut h, opt, 0x10b);
        put32(&mut h, opt + 32, u32_of(PAGE_SIZE));
        put32(&mut h, opt + 36, u32_of(RAW_DATA_ALIGNMENT));
        put32(&mut h, opt + 56, u32_of(SIZE_OF_IMAGE));
        put32(&mut h, opt + 60, u32_of(SECTION_FILE_OFFSET));
        put32(&mut h, opt + 92, 16);
        put32(&mut h, opt + 96 + 16, u32_of(SECTION_RVA));
        put32(&mut h, opt + 96 + 20, u32_of(raw_size));
        let sec = opt + 0xe0;
        h[sec..sec + 5].copy_from_slice(b".rsrc");
        put32(&mut h, sec + 8, u32_of(raw_size));
        put32(&mut h, sec + 12, u32_of(SECTION_RVA));
        put32(&mut h, sec + 16, u32_of(raw_size));
        put32(&mut h, sec + 20, u32_of(SECTION_FILE_OFFSET));
        h
    }

    /// The image as it sits on disk: headers, then the section's raw bytes.
    fn file_layout() -> Vec<u8> {
        let rsrc = rsrc_section();
        let mut file = headers(rsrc.len());
        file.extend(&rsrc);
        file
    }

    /// The image as the loader maps it: the section at its RVA.
    fn mapped_layout() -> Vec<u8> {
        let rsrc = rsrc_section();
        let mut image = vec![0; SIZE_OF_IMAGE];
        image[..SECTION_FILE_OFFSET].copy_from_slice(&headers(rsrc.len()));
        image[SECTION_RVA..SECTION_RVA + rsrc.len()].copy_from_slice(&rsrc);
        image
    }

    fn expected() -> VersionInfo {
        VersionInfo {
            company: "Acme Games".into(),
            product: "Rocket Sled".into(),
            original_filename: "Sled.exe".into(),
        }
    }

    #[test]
    fn a_file_is_read_through_its_section_table() {
        let file = file_layout();
        let pe = PeFile::new(file.as_slice()).unwrap();
        assert_eq!(from_image(&pe), expected());
        // Read at raw offsets, the resource RVA points past the end of the
        // file, which is why the translation is needed at all.
        assert_eq!(from_image(file.as_slice()), VersionInfo::default());
    }

    #[test]
    fn the_mapped_and_the_file_readers_agree() {
        let image = mapped_layout();
        assert_eq!(read(image.as_ptr().cast()), expected());
        assert_eq!(from_image(image.as_slice()), expected());
    }

    #[test]
    fn pointer_to_raw_data_is_rounded_down_like_the_loader_does() {
        let mut file = file_layout();
        let sec = 0x44 + 20 + 0xe0;
        put32(&mut file, sec + 20, u32_of(SECTION_FILE_OFFSET + 0x1ff));
        let pe = PeFile::new(file.as_slice()).unwrap();
        assert_eq!(from_image(&pe), expected());
    }

    #[test]
    fn a_low_alignment_file_is_read_flat() {
        // FileAlignment == SectionAlignment below a page: the loader maps the
        // file as is, so the file looks exactly like the mapped image.
        let mut file = mapped_layout();
        let opt = 0x44 + 20;
        put32(&mut file, opt + 32, 0x200);
        put32(&mut file, opt + 36, 0x200);
        // The section table still claims the usual raw offset, which a flat
        // read must ignore.
        let pe = PeFile::new(file.as_slice()).unwrap();
        assert!(pe.flat);
        assert_eq!(from_image(&pe), expected());
    }

    #[test]
    fn a_hostile_section_count_is_refused() {
        let mut file = file_layout();
        put16(&mut file, 0x44 + 2, u16::MAX);
        assert!(PeFile::new(file.as_slice()).is_none());
    }

    #[test]
    fn a_read_past_the_raw_data_of_a_section_fails() {
        let file = file_layout();
        let pe = PeFile::new(file.as_slice()).unwrap();
        let end = SECTION_RVA + rsrc_section().len();
        let mut buf = [0; 4];
        assert!(pe.read(end - 4, &mut buf).is_some());
        assert!(pe.read(end - 3, &mut buf).is_none());
        // Between the headers and the section nothing is backed by the file.
        assert!(pe.read(SECTION_FILE_OFFSET, &mut buf).is_none());
        assert!(pe.read(SECTION_FILE_OFFSET - 4, &mut buf).is_some());
    }

    #[test]
    fn a_truncated_or_foreign_file_yields_nothing() {
        let file = file_layout();
        for len in [0, 0x3c, 0x60, SECTION_FILE_OFFSET, file.len() - 1] {
            let pe = PeFile::new(&file[..len]);
            assert_eq!(
                pe.map(|pe| from_image(&pe)).unwrap_or_default(),
                VersionInfo::default(),
                "truncated to {len:#x}"
            );
        }
        let mut not_pe = file;
        not_pe[0x40] = b'N';
        assert!(PeFile::new(not_pe.as_slice()).is_none());
        assert_eq!(read(core::ptr::null()), VersionInfo::default());
    }

    #[test]
    fn read_file_handles_a_missing_file() {
        assert_eq!(
            read_file(Path::new("/nonexistent/compatdb/Game.exe")),
            VersionInfo::default()
        );
    }

    #[test]
    fn read_file_reads_a_wine_builtin_when_one_is_installed() {
        // Not a fixture: the dist/ tree next to this repository, where the
        // build scripts put a bundle. A linked worktree has no such tree, so
        // set COMPATDB_TEST_PE to the path of a Wine kernel32.dll (any PE
        // whose OriginalFilename is kernel32.dll) to run it there, for
        // example .../dist/wine/lib/wine/i386-windows/kernel32.dll. Skipped
        // when the file does not exist, with a line on stderr that cargo test
        // only shows when run with `-- --nocapture`.
        let path = std::env::var_os("COMPATDB_TEST_PE").map_or_else(
            || {
                Path::new(env!("CARGO_MANIFEST_DIR"))
                    .join("../../dist/wine/lib/wine/i386-windows/kernel32.dll")
            },
            std::path::PathBuf::from,
        );
        if !path.is_file() {
            eprintln!(
                "skipping: no PE at {} (set COMPATDB_TEST_PE)",
                path.display()
            );
            return;
        }
        let version = read_file(&path);
        assert_eq!(
            version.original_filename.to_ascii_lowercase(),
            "kernel32.dll"
        );
        assert!(!version.company.is_empty());
    }
}
