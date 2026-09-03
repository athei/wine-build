//! Reading a mapped image's `VS_VERSIONINFO` so the database can match on a
//! version fingerprint (company, product, original filename) that is stable
//! across install location and patches.
//!
//! The main image is already mapped when this library loads, so resource RVAs
//! are just offsets from the image base. All navigation goes through a bounds
//! checked view of the image; a malformed or resource-free image yields an
//! empty [`VersionInfo`], never a wild read.

use core::ffi::c_void;

use compatdb_table::VersionInfo;

/// Read the version fingerprint of the image mapped at `image_base`.
pub fn read(image_base: *const c_void) -> VersionInfo {
    version_blob(image_base)
        .map(|blob| VersionInfo::from_resource(&blob))
        .unwrap_or_default()
}

/// A bounds-checked view over the loaded image.
struct Image {
    base: *const u8,
    size: usize,
}

impl Image {
    fn bytes(&self, off: usize, len: usize) -> Option<&[u8]> {
        if off.checked_add(len)? > self.size {
            return None;
        }
        // SAFETY: off..off+len lies within [0, size), the image's own extent.
        Some(unsafe { std::slice::from_raw_parts(self.base.add(off), len) })
    }

    fn u16(&self, off: usize) -> Option<u16> {
        let arr: [u8; 2] = self.bytes(off, 2)?.try_into().ok()?;
        Some(u16::from_le_bytes(arr))
    }

    fn u32(&self, off: usize) -> Option<u32> {
        let arr: [u8; 4] = self.bytes(off, 4)?.try_into().ok()?;
        Some(u32::from_le_bytes(arr))
    }
}

fn version_blob(image_base: *const c_void) -> Option<Vec<u16>> {
    if image_base.is_null() {
        return None;
    }
    let base = image_base.cast::<u8>();

    let bootstrap = Image { base, size: 0x1000 };
    let e_lfanew = usize::try_from(bootstrap.u32(0x3c)?).ok()?;
    if bootstrap.bytes(e_lfanew, 4)? != b"PE\0\0" {
        return None;
    }
    let opt = e_lfanew.checked_add(24)?;
    let magic = bootstrap.u16(opt)?;
    let pe32plus = magic == 0x20b;
    let size_of_image = usize::try_from(bootstrap.u32(opt.checked_add(56)?)?).ok()?;

    // Now the full, correctly-bounded image.
    let img = Image {
        base,
        size: size_of_image,
    };
    // Data directories start after the optional header's fixed part; the
    // resource directory is entry 2 (16 bytes each).
    let dir_base = opt.checked_add(if pe32plus { 112 } else { 96 })?;
    let res_rva = usize::try_from(img.u32(dir_base.checked_add(2 * 8)?)?).ok()?;
    if res_rva == 0 {
        return None;
    }

    let ver_dir = find_id_subdir(&img, res_rva, res_rva, 16)?;
    let (name_child, name_is_dir) = first_child(&img, res_rva, ver_dir)?;
    if !name_is_dir {
        return None;
    }
    let (lang_leaf, lang_is_dir) = first_child(&img, res_rva, name_child)?;
    if lang_is_dir {
        return None;
    }

    // IMAGE_RESOURCE_DATA_ENTRY: OffsetToData (an RVA), Size.
    let data_rva = usize::try_from(img.u32(lang_leaf)?).ok()?;
    let data_size = usize::try_from(img.u32(lang_leaf.checked_add(4)?)?).ok()?;
    let raw = img.bytes(data_rva, data_size)?;

    // The blob is UTF-16; collect the u16 units.
    Some(
        raw.chunks_exact(2)
            .filter_map(|c| c.try_into().ok().map(u16::from_le_bytes))
            .collect(),
    )
}

/// Find the sub-directory for a resource entry with numeric id `id` in the
/// directory at `dir_off`. `res_base` is the resource section base (offsets in
/// entries are relative to it).
fn find_id_subdir(img: &Image, res_base: usize, dir_off: usize, id: u32) -> Option<usize> {
    let named = usize::from(img.u16(dir_off.checked_add(12)?)?);
    let ids = usize::from(img.u16(dir_off.checked_add(14)?)?);
    let entries = dir_off.checked_add(16)?;
    for i in 0..named.checked_add(ids)? {
        let eo = entries.checked_add(i.checked_mul(8)?)?;
        let name = img.u32(eo)?;
        let offset = img.u32(eo.checked_add(4)?)?;
        // A numeric id entry (high bit clear) whose id matches, pointing at a
        // sub-directory (high bit of offset set).
        if name & 0x8000_0000 == 0 && name == id && offset & 0x8000_0000 != 0 {
            return res_base.checked_add(usize::try_from(offset & 0x7fff_ffff).ok()?);
        }
    }
    None
}

/// The first entry of a resource directory: its child offset (relative to
/// `res_base`) and whether that child is another directory.
fn first_child(img: &Image, res_base: usize, dir_off: usize) -> Option<(usize, bool)> {
    let named = usize::from(img.u16(dir_off.checked_add(12)?)?);
    let ids = usize::from(img.u16(dir_off.checked_add(14)?)?);
    if named.checked_add(ids)? == 0 {
        return None;
    }
    let offset = img.u32(dir_off.checked_add(16 + 4)?)?;
    let child = res_base.checked_add(usize::try_from(offset & 0x7fff_ffff).ok()?)?;
    Some((child, offset & 0x8000_0000 != 0))
}
