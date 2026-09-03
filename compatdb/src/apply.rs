//! Applying a [`Resolution`] to the current process: prepending the Direct3D
//! trees, adding load-order overrides, and rewriting the command line and
//! environment in both PEB copies.

use std::{
    ffi::{CString, OsStr},
    os::unix::ffi::OsStrExt as _,
    path::{Path, PathBuf},
    ptr,
};

use compatdb_table::{Arch, Resolution, append_cmdline, merge_env};

use crate::{Process, log, ntdll::Ntdll};

/// Prepend `lib/wine/<family>/<name>` to the builtin search path, where
/// `family` is `dxgi` or `d3d9` and `name` the implementation's tree.
///
/// Every process gets one tree per family. The default dirs hold only
/// fake-module markers for these DLLs, so this is purely additive and nothing
/// is ever disabled. If the tree is missing the process falls back to whatever
/// the default dir holds, which is a load failure for that API.
pub fn tree(nt: &Ntdll, arch: Arch, family: &str, name: &str) {
    let Some(lib_wine) = lib_wine_dir() else {
        log::line(&format!("  {family}: cannot locate lib/wine"));
        return;
    };
    let side = lib_wine.join(family).join(name);
    let side_pe = side.join(arch.pe_dir());
    if !side_pe.is_dir() {
        log::line(&format!(
            "  {family} = {name}: {} missing, using the default dir",
            side_pe.display()
        ));
        return;
    }
    if !nt.has_prepend_dll_path() {
        log::line(&format!("  {family}: ntdll lacks prepend_dll_path"));
        return;
    }
    let Ok(c_side) = CString::new(side.as_os_str().as_bytes()) else {
        return;
    };
    // ntdll keeps the pointer without copying, so it must outlive the process.
    nt.prepend_dll_path(c_side.into_raw());
    log::line(&format!("  {family} = {name} (from {})", side.display()));
}

/// Add each `names=order` load-order override.
pub fn dll_overrides(nt: &Ntdll, overrides: &[String]) {
    if overrides.is_empty() {
        return;
    }
    if !nt.has_add_load_order_override() {
        log::line("ntdll lacks add_load_order_override, ignoring dll_overrides");
        return;
    }
    for entry in overrides {
        add_override(nt, entry);
    }
}

/// Rewrite `CommandLine` and `Environment` in the 64-bit params and, for a
/// wow64 process, in the 32-bit copy too. Nothing is touched when neither the
/// command line nor the environment actually changes.
pub fn rewrite_params(nt: &Ntdll, process: &Process, resolution: &Resolution) {
    // Touch only what actually changes. Rewriting the (often large, inherited)
    // environment when only the command line changed is unnecessary and risky,
    // so the two are handled independently, each in its own allocation.
    if let Some(cmd) = append_cmdline(&process.cmdline, &resolution.arguments) {
        rewrite_command_line(nt, process, &cmd);
    }
    if let Some(env) = merge_env(&process.env, &resolution.env) {
        rewrite_environment(nt, process, &env);
    }
}

/// Repoint `CommandLine` at a fresh copy of `cmd` (plus a terminating NUL) in
/// both PEB copies.
fn rewrite_command_line(nt: &Ntdll, process: &Process, cmd: &[u16]) {
    let Some(cmd_bytes) = cmd.len().checked_mul(2) else {
        log::line("  command line too long to rewrite");
        return;
    };
    let (Ok(length), Ok(maximum)) = (
        u16::try_from(cmd_bytes),
        u16::try_from(cmd_bytes.saturating_add(2)),
    ) else {
        log::line("  command line exceeds the 64 KB UNICODE_STRING limit, not rewriting");
        return;
    };
    let Some(units) = cmd.len().checked_add(1) else {
        return;
    };
    let Some(size) = units.checked_mul(2) else {
        return;
    };
    let Some(base) = alloc_block(nt, process, size) else {
        return;
    };
    let ptr = base.cast::<u16>();
    // SAFETY: `base` maps `size` bytes = `units` u16 units; the command line
    // and its NUL fit exactly.
    unsafe {
        ptr::copy_nonoverlapping(cmd.as_ptr(), ptr, cmd.len());
        ptr.add(cmd.len()).write(0);
    }
    // SAFETY: `process.params` is the live 64-bit parameters; only the command
    // line descriptor is repointed at the fresh block, which outlives us.
    unsafe {
        let p = &mut *process.params;
        p.command_line.buffer = ptr;
        p.command_line.length = length;
        p.command_line.maximum_length = maximum;
    }
    if let Some(params32) = process.params32 {
        let Ok(buf32) = u32::try_from(ptr as usize) else {
            log::line("  rewritten command line is not addressable from 32-bit code");
            return;
        };
        // SAFETY: `params32` is the live wow64 parameters; the block sits below
        // 2 GB so the u32 pointer is exact.
        unsafe {
            let p = &mut *params32;
            p.command_line.buffer = buf32;
            p.command_line.length = length;
            p.command_line.maximum_length = maximum;
        }
    }
}

/// Repoint `Environment` at a fresh copy of `env` in both PEB copies.
fn rewrite_environment(nt: &Ntdll, process: &Process, env: &[u16]) {
    let Some(size) = env.len().checked_mul(2) else {
        log::line("  environment too large to rewrite");
        return;
    };
    let Some(base) = alloc_block(nt, process, size) else {
        return;
    };
    let ptr = base.cast::<u16>();
    // SAFETY: `base` maps `size` bytes = `env.len()` u16 units.
    unsafe {
        ptr::copy_nonoverlapping(env.as_ptr(), ptr, env.len());
    }
    // SAFETY: `process.params` is the live 64-bit parameters; only the
    // environment pointer and size are repointed at the fresh block.
    unsafe {
        let p = &mut *process.params;
        p.environment = ptr;
        p.environment_size = size;
    }
    if let Some(params32) = process.params32 {
        let (Ok(env32), Ok(size32)) = (u32::try_from(ptr as usize), u32::try_from(size)) else {
            log::line("  rewritten environment is not addressable from 32-bit code");
            return;
        };
        // SAFETY: `params32` is the live wow64 parameters; the block sits below
        // 2 GB so the u32 pointer is exact.
        unsafe {
            let p = &mut *params32;
            p.environment = env32;
            p.environment_size = size32;
        }
    }
}

/// Allocate a committed block, below 2 GB when the process is 32-bit so its
/// `ULONG` pointers can address it.
fn alloc_block(nt: &Ntdll, process: &Process, size: usize) -> Option<*mut core::ffi::c_void> {
    let zero_bits = if process.params32.is_some() {
        crate::ntdll::LIMIT_2G_MINUS_1
    } else {
        0
    };
    let base = nt.allocate(size, zero_bits);
    if base.is_none() {
        log::line("  NtAllocateVirtualMemory failed, not rewriting");
    }
    base
}
/// Apply the environment entries to this process's own unix environment too, so
/// unix-side readers (winemetal, mtld3d, Metal) see them. An empty value
/// removes the variable.
pub fn unix_env(entries: &[(String, String)]) {
    for (name, value) in entries {
        let Ok(c_name) = CString::new(name.as_str()) else {
            continue;
        };
        if value.is_empty() {
            // SAFETY: `c_name` is a valid NUL-terminated string for the call.
            unsafe {
                libc::unsetenv(c_name.as_ptr());
            }
            continue;
        }
        let Ok(c_value) = CString::new(value.as_str()) else {
            continue;
        };
        // SAFETY: both strings are valid and NUL-terminated for the call.
        unsafe {
            libc::setenv(c_name.as_ptr(), c_value.as_ptr(), 1);
        }
    }
}

fn add_override(nt: &Ntdll, entry: &str) {
    let mut buf: Vec<u16> = entry.encode_utf16().collect();
    buf.push(0);
    nt.add_load_order_override(buf.as_ptr());
}

/// `.../lib/wine` derived from this library's own path (`dladdr`), which is
/// `.../lib/wine/<arch>-unix/compatdb.so`.
fn lib_wine_dir() -> Option<PathBuf> {
    // SAFETY: `info` is written by dladdr before it is read; the call takes a
    // valid code address and a valid out-pointer.
    let path = unsafe {
        let mut info: libc::Dl_info = std::mem::zeroed();
        let addr = tree as *const libc::c_void;
        if libc::dladdr(addr, ptr::from_mut(&mut info)) == 0 || info.dli_fname.is_null() {
            return None;
        }
        std::ffi::CStr::from_ptr(info.dli_fname)
    };
    let os = OsStr::from_bytes(path.to_bytes());
    Path::new(os).parent()?.parent().map(Path::to_path_buf)
}
