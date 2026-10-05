//! `compatdb.so`: the per-process settings library wine's ntdll dlopens from
//! `<ntdll_dir>/compatdb.so` in every process (the slot `CrossOver` hack 24067
//! provides), before any PE code runs. Its main entry point is a Mach-O
//! initializer; ntdll also calls [`compatdb_query_x87`] to decide whether a
//! process starts under the x87sidecar.
//!
//! It holds the built-in rules, overlays the ones passed in
//! [`ENV_VAR`](compatdb_table::ENV_VAR), resolves the rules that match this
//! process and applies them: the D3D9 and DXGI trees, DLL load-order
//! overrides, the DPI awareness, large address awareness, and
//! command-line/environment rewrites. All the decision logic lives in
//! [`compatdb_table`]; this crate only moves bytes in and out of the running
//! process, so its `unsafe` is confined to a thin ntdll shell.
#![deny(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::panic,
    clippy::indexing_slicing
)]
#![forbid(clippy::undocumented_unsafe_blocks)]

mod apply;
mod builtin;
mod log;
mod ntdll;
mod version;

use std::{
    ffi::{CStr, CString, OsStr, c_char, c_int},
    fmt::Write as _,
    os::unix::ffi::OsStrExt as _,
    path::Path,
};

use compatdb_table::{Arch, Dxgi, ENV_VAR, Table, VersionInfo, basename_of};

use crate::ntdll::{Ntdll, Peb, Peb32, ProcessParameters, ProcessParameters32, TEB_PEB_OFFSET};

/// The Mach-O initializer, run from ntdll's `dlopen` in every wine process.
#[used]
#[unsafe(link_section = "__DATA,__mod_init_func")]
static INIT: extern "C" fn() = init;

extern "C" fn init() {
    // ntdll can load the library before it is initialized itself, only to
    // call compatdb_query_x87, and says so through compatdb_preinit_query.
    // Nothing here would work then, so do nothing. dyld does not unload this
    // library on dlclose, and a later dlopen of it does not run INIT again,
    // so skipping here would also skip the real run in this process. That is
    // only correct because ntdll's pre-init path always ends in execv or
    // fatal_error: the process that runs the program is a fresh image that
    // loads the library again and runs INIT normally.
    if ntdll::is_preinit_load() {
        return;
    }
    run();
}

/// Whether the executable at `unix_path` should start under the x87sidecar:
/// 1 to attach it, 0 not to, -1 for no opinion (a null or empty path, or no
/// rule that sets `x87_sidecar`).
///
/// ntdll calls this before it starts an i386 process, and possibly before
/// ntdll itself is initialized, so it reads only the rule table and the file:
/// no PEB, no TEB and no ntdll symbol. It keeps no state between calls. The
/// path is a unix path when ntdll could resolve one; otherwise it may be a DOS
/// path, in which case only the basename is known and the version fingerprint
/// is empty.
///
/// # Safety
/// `unix_path` must be null or point at a NUL-terminated string that stays
/// valid for the duration of the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn compatdb_query_x87(unix_path: *const c_char) -> c_int {
    if unix_path.is_null() {
        log::line("x87 query without a path, no opinion");
        return -1;
    }
    // SAFETY: the caller passes a NUL-terminated string that stays valid for
    // the call; it is copied out before anything else happens.
    let path = unsafe { CStr::from_ptr(unix_path) }.to_bytes().to_vec();
    let (table, _) = load_table();
    let Some((exe, version, x87)) = query_x87(&table, &path) else {
        log::line("x87 query without a file name, no opinion");
        return -1;
    };
    let (answer, ret) = match x87 {
        Some(true) => ("x87_sidecar (rule) = true", 1),
        Some(false) => ("x87_sidecar (rule) = false", 0),
        None => ("x87_sidecar (rule) unset, no opinion", -1),
    };
    log::line(&format!(
        "x87 query {exe}{}: {answer}",
        fingerprint(&version)
    ));
    ret
}

/// Resolve `x87_sidecar` for the executable at `path`, a unix path or a DOS
/// one. Returns the basename and version fingerprint it matched on along with
/// the value, or `None` when the path names no file.
fn query_x87(table: &Table, path: &[u8]) -> Option<(String, VersionInfo, Option<bool>)> {
    let path_utf16: Vec<u16> = String::from_utf8_lossy(path).encode_utf16().collect();
    let exe = basename_of(&path_utf16);
    if exe.is_empty() {
        return None;
    }
    // ntdll passes an absolute unix path for a file it found. Anything else
    // is a DOS path or a bare name, which must not be opened relative to the
    // current directory, so it reads as no version resource, as does a file
    // that does not exist.
    let version = if path.starts_with(b"/") {
        version::read_file(Path::new(OsStr::from_bytes(path)))
    } else {
        VersionInfo::default()
    };
    let x87 = table.resolve(&exe, &version).x87_sidecar;
    Some((exe, version, x87))
}

/// The built-in rules with the overrides from [`ENV_VAR`] laid on top, plus
/// the lines worth logging about the overrides: parse diagnostics and
/// overrides that name no rule.
fn load_table() -> (Table, Vec<String>) {
    // The built-in rules are compiled in; only overrides travel in the
    // environment (absent unless something set it). Overlay them.
    let mut table = builtin::table();
    let mut messages = Vec::new();
    if let Some(text) = read_env() {
        let (overrides, diagnostics) = Table::parse(&text);
        messages.extend(diagnostics);
        for name in table.overlay(overrides) {
            messages.push(format!("override names no rule: {name}"));
        }
    }
    (table, messages)
}

fn run() {
    // The library always loads, in every wine process, whether or not the env
    // var is set: the default dirs ship no real Direct3D at all, so both
    // implementations are chosen here (per arch, or per the database) and
    // their trees prepended. It always logs one line per process so a miss is
    // as visible as a hit.
    let Some(nt) = Ntdll::resolve() else {
        log::line("required ntdll symbols missing, doing nothing");
        return;
    };
    let (table, messages) = load_table();
    for m in &messages {
        log::line(m);
    }
    let Some(process) = Process::current(&nt) else {
        return;
    };
    let resolution = table.resolve(&process.exe, &process.version);
    let arch = match process.arch {
        Arch::X86_64 => "x86_64",
        Arch::I386 => "i386",
    };
    log::line(&format!(
        "{} [{arch}]{}",
        process.exe,
        fingerprint(&process.version)
    ));
    if resolution.matched.is_empty() {
        // Diagnose a miss by the fingerprint on the line above: an empty one
        // means the image carries no version resource for a rule to pin.
        log::line("  no rule matched");
    } else {
        log::line(&format!("  rules = {}", resolution.matched.join(", ")));
    }

    // Every process gets one tree of each family prepended: a rule's choice,
    // or the arch default. Purely additive: the default dirs hold nothing that
    // could conflict, so nothing is ever disabled.
    let dxgi = Dxgi::effective(resolution.dxgi, process.arch);
    if let Some(want) = resolution.dxgi
        && want != dxgi
    {
        log::line(&format!(
            "  dxgi = {} not available on {arch}, using {}",
            want.as_str(),
            dxgi.as_str()
        ));
    }
    apply::tree(&nt, process.arch, "dxgi", dxgi.as_str());
    let d3d9 = resolution.d3d9.unwrap_or_default();
    apply::tree(&nt, process.arch, "d3d9", d3d9.as_str());

    // The remaining knobs apply only when a rule matched this process.
    if !resolution.dll_overrides.is_empty() {
        log::line(&format!(
            "  dll_overrides = {}",
            resolution.dll_overrides.join(";")
        ));
        apply::dll_overrides(&nt, &resolution.dll_overrides);
    }
    if let Some(aware) = resolution.dpi_aware {
        apply::dpi_awareness(&nt, aware);
    }
    if let Some(laa) = resolution.large_address_aware {
        apply::large_address_aware(&nt, laa);
    }
    // Only for the log, and only the rule's value: ntdll asked
    // compatdb_query_x87 before it started the process and decided then, and
    // it may have skipped the sidecar regardless (an empty ROSETTA_X87_PATH,
    // no sidecar installed, an ntdll without the query). For a first launch
    // by DOS path, ntdll resolves the path through the prefix's dosdevices;
    // when that fails the query saw only the basename. It means
    // nothing to a 64-bit process, so only an i386 one shows it.
    if let (Some(x87), Arch::I386) = (resolution.x87_sidecar, process.arch) {
        log::line(&format!("  x87_sidecar (rule) = {x87}"));
    }
    if !resolution.arguments.is_empty() {
        log::line(&format!("  arguments = {}", resolution.arguments.join(" ")));
    }
    if !resolution.env.is_empty() {
        let env: Vec<String> = resolution
            .env
            .iter()
            .map(|(name, value)| format!("{name}={value}"))
            .collect();
        log::line(&format!("  env = {}", env.join(", ")));
    }
    apply::rewrite_params(&nt, &process, &resolution);
    apply::unix_env(&resolution.env);
}

/// A compact `company="..." product="..." original_filename="..."` suffix,
/// listing only the version fields that are present. Empty when the image
/// carries no version resource.
fn fingerprint(v: &VersionInfo) -> String {
    let mut parts = String::new();
    for (label, value) in [
        ("company", &v.company),
        ("product", &v.product),
        ("original_filename", &v.original_filename),
    ] {
        if !value.is_empty() {
            let _ = write!(parts, " {label}={value:?}");
        }
    }
    parts
}

/// The value of [`ENV_VAR`], read straight from the C environment so the
/// no-op path allocates nothing beyond the small variable name.
fn read_env() -> Option<String> {
    let name = CString::new(ENV_VAR).ok()?;
    // SAFETY: `name` is a valid NUL-terminated string; getenv returns a pointer
    // into the environment or null, and we copy it out immediately.
    let ptr = unsafe { libc::getenv(name.as_ptr()) };
    if ptr.is_null() {
        return None;
    }
    // SAFETY: getenv returned a non-null pointer to a NUL-terminated string.
    let value = unsafe { CStr::from_ptr(ptr) }
        .to_string_lossy()
        .into_owned();
    (!value.is_empty()).then_some(value)
}

/// An owned snapshot of the process identity and the two strings the library
/// may rewrite, taken once so all later work is on owned data.
pub(crate) struct Process {
    pub params: *mut ProcessParameters,
    pub params32: Option<*mut ProcessParameters32>,
    pub arch: Arch,
    pub exe: String,
    pub version: VersionInfo,
    pub cmdline: Vec<u16>,
    pub env: Vec<u16>,
}

impl Process {
    fn current(nt: &Ntdll) -> Option<Self> {
        let teb = nt.current_teb();
        if teb.is_null() {
            log::line("NtCurrentTeb returned null");
            return None;
        }
        // SAFETY: TEB.Peb sits at TEB_PEB_OFFSET (a multiple of 8, so the
        // slot is pointer-aligned) and holds the PEB pointer, which ntdll
        // populated before this library was loaded.
        #[allow(clippy::cast_ptr_alignment)]
        let peb = unsafe {
            teb.cast::<u8>()
                .add(TEB_PEB_OFFSET)
                .cast::<*mut Peb>()
                .read()
        };
        if peb.is_null() {
            log::line("PEB pointer is null");
            return None;
        }
        // SAFETY: `peb` is the live PEB; ProcessParameters and the image base
        // are already set.
        let (params, image_base) = unsafe { ((*peb).process_parameters, (*peb).image_base) };
        if params.is_null() {
            log::line("ProcessParameters pointer is null");
            return None;
        }

        let (arch, params32) = match nt.wow64_information() {
            Some(w) if w != 0 => {
                let peb32 = w as *const Peb32;
                // SAFETY: a non-zero ProcessWow64Information value is the live
                // PEB32 address for a 32-bit process.
                let pp = unsafe { (*peb32).process_parameters };
                if pp == 0 {
                    log::line("wow64 ProcessParameters pointer is null");
                    return None;
                }
                (Arch::I386, Some(pp as usize as *mut ProcessParameters32))
            }
            _ => (Arch::X86_64, None),
        };

        // SAFETY: `params` is the live 64-bit process parameters; each field
        // read below is a UNICODE_STRING or the environment pointer/size.
        let (image_path, cmdline, env) = unsafe {
            let p = &*params;
            (
                read_unicode(&p.image_path_name),
                read_unicode(&p.command_line),
                read_environment(p.environment, p.environment_size),
            )
        };
        let exe = basename_of(&image_path);
        let version = version::read(image_base.cast_const());

        Some(Self {
            params,
            params32,
            arch,
            exe,
            version,
            cmdline,
            env,
        })
    }
}

/// Copy a `UNICODE_STRING` into an owned `Vec<u16>`.
///
/// # Safety
/// `u.buffer` must be null or point at `u.length` bytes of UTF-16.
unsafe fn read_unicode(u: &ntdll::UnicodeString) -> Vec<u16> {
    if u.buffer.is_null() || u.length == 0 {
        return Vec::new();
    }
    let units = usize::from(u.length / 2);
    // SAFETY: the caller guarantees `buffer` covers `length` bytes.
    unsafe { std::slice::from_raw_parts(u.buffer, units) }.to_vec()
}

/// Copy an environment block into an owned `Vec<u16>`, keeping its terminators.
///
/// # Safety
/// `env` must be null or point at `size_bytes` bytes of UTF-16.
unsafe fn read_environment(env: *mut u16, size_bytes: usize) -> Vec<u16> {
    if env.is_null() || size_bytes < 2 {
        return vec![0, 0];
    }
    let units = size_bytes / 2;
    // SAFETY: the caller guarantees `env` covers `size_bytes` bytes.
    unsafe { std::slice::from_raw_parts(env, units) }.to_vec()
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use compatdb_table::{ANY_EXE, Rule};

    use super::*;

    fn table() -> Table {
        Table {
            rules: vec![
                Rule {
                    name: "defaults".into(),
                    exe: ANY_EXE.into(),
                    x87_sidecar: Some(true),
                    ..Rule::default()
                },
                Rule {
                    name: "no-x87".into(),
                    exe: "Old.exe".into(),
                    x87_sidecar: Some(false),
                    ..Rule::default()
                },
            ],
        }
    }

    fn x87(table: &Table, path: &str) -> Option<bool> {
        query_x87(table, path.as_bytes()).unwrap().2
    }

    #[test]
    fn the_query_matches_on_the_basename_of_a_unix_or_a_dos_path() {
        let table = table();
        assert_eq!(x87(&table, "/nonexistent/games/old.exe"), Some(false));
        assert_eq!(x87(&table, "C:\\Games\\OLD.EXE"), Some(false));
        assert_eq!(x87(&table, "old.exe"), Some(false));
        assert_eq!(x87(&table, "/nonexistent/games/new.exe"), Some(true));
        let (exe, version, _) = query_x87(&table, b"C:\\Games\\Old.exe").unwrap();
        assert_eq!(exe, "Old.exe");
        assert_eq!(version, VersionInfo::default());
    }

    #[test]
    fn the_query_has_no_opinion_without_a_file_name_or_a_rule() {
        let table = table();
        assert!(query_x87(&table, b"").is_none());
        assert!(query_x87(&table, b"/nonexistent/games/").is_none());
        assert!(query_x87(&table, b"C:\\Games\\").is_none());
        assert_eq!(x87(&Table::default(), "/nonexistent/game.exe"), None);
        // SAFETY: a null path is part of the contract.
        assert_eq!(unsafe { compatdb_query_x87(std::ptr::null()) }, -1);
        let empty = c"";
        // SAFETY: a valid NUL-terminated string.
        assert_eq!(unsafe { compatdb_query_x87(empty.as_ptr()) }, -1);
    }

    #[test]
    fn the_builtin_default_attaches_the_sidecar() {
        // The exported function reads WINE_COMPATDB, which a developer's shell
        // may set; the answer is only predictable without it.
        if std::env::var_os(ENV_VAR).is_some() {
            return;
        }
        let path = c"/nonexistent/games/game.exe";
        // SAFETY: a valid NUL-terminated string.
        assert_eq!(unsafe { compatdb_query_x87(path.as_ptr()) }, 1);
    }
}
