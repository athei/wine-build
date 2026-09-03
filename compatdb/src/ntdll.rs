//! The wine ntdll surface the library uses, resolved at load time with
//! `dlsym(RTLD_DEFAULT)` (ntdll.so is already loaded `RTLD_NOW` and global),
//! plus the `repr(C)` process structures. Every layout carries a `const`
//! size/offset assertion, so a mistyped field is a build error rather than
//! undefined behaviour at runtime.

use core::ffi::{c_char, c_void};
use std::mem::{offset_of, size_of};

pub type NtStatus = i32;
pub type Handle = *mut c_void;

/// `(HANDLE)~0`, the pseudo-handle for the current process.
pub const CURRENT_PROCESS: Handle = usize::MAX as Handle;
/// `ProcessWow64Information`.
pub const PROCESS_WOW64_INFORMATION: u32 = 26;
pub const MEM_COMMIT: u32 = 0x1000;
pub const PAGE_READWRITE: u32 = 0x04;
/// `TEB.Peb` sits here on 64-bit.
pub const TEB_PEB_OFFSET: usize = 0x60;
/// `zero_bits` value that caps an allocation below 2 GB, so a 32-bit process
/// can address the block through a `ULONG` pointer.
pub const LIMIT_2G_MINUS_1: usize = 0x7fff_ffff;

/// The reply size of `ProcessWow64Information` (a `ULONG_PTR`). All supported
/// targets are 64-bit; the assertion below keeps that honest.
const PTR_LEN: u32 = 8;
const _: () = assert!(size_of::<usize>() == PTR_LEN as usize);

#[repr(C)]
pub struct UnicodeString {
    pub length: u16,
    pub maximum_length: u16,
    pub buffer: *mut u16,
}

#[repr(C)]
pub struct UnicodeString32 {
    pub length: u16,
    pub maximum_length: u16,
    pub buffer: u32,
}

#[repr(C)]
struct Curdir {
    dos_path: UnicodeString,
    handle: *mut c_void,
}

#[repr(C)]
struct Curdir32 {
    dos_path: UnicodeString32,
    handle: u32,
}

#[repr(C)]
struct DriveLetterCurdir {
    flags: u16,
    length: u16,
    time_stamp: u32,
    dos_path: UnicodeString,
}

#[repr(C)]
struct DriveLetterCurdir32 {
    flags: u16,
    length: u16,
    time_stamp: u32,
    dos_path: UnicodeString32,
}

/// `RTL_USER_PROCESS_PARAMETERS` (64-bit). Modelled in full so the fields we
/// touch land at the ABI offsets, which the asserts below check.
#[repr(C)]
pub struct ProcessParameters {
    allocation_size: u32,
    size: u32,
    flags: u32,
    debug_flags: u32,
    console_handle: *mut c_void,
    console_flags: u32,
    std_input: *mut c_void,
    std_output: *mut c_void,
    std_error: *mut c_void,
    current_directory: Curdir,
    dll_path: UnicodeString,
    pub image_path_name: UnicodeString,
    pub command_line: UnicodeString,
    pub environment: *mut u16,
    dw_x: u32,
    dw_y: u32,
    dw_x_size: u32,
    dw_y_size: u32,
    dw_x_count_chars: u32,
    dw_y_count_chars: u32,
    dw_fill_attribute: u32,
    dw_flags: u32,
    w_show_window: u32,
    window_title: UnicodeString,
    desktop: UnicodeString,
    shell_info: UnicodeString,
    runtime_info: UnicodeString,
    dl_current_directory: [DriveLetterCurdir; 32],
    pub environment_size: usize,
    environment_version: usize,
    package_dependency_data: *mut c_void,
    process_group_id: u32,
    loader_threads: u32,
}

/// `RTL_USER_PROCESS_PARAMETERS32`, the below-2 GB copy a wow64 process reads.
#[repr(C)]
pub struct ProcessParameters32 {
    allocation_size: u32,
    size: u32,
    flags: u32,
    debug_flags: u32,
    console_handle: u32,
    console_flags: u32,
    std_input: u32,
    std_output: u32,
    std_error: u32,
    current_directory: Curdir32,
    dll_path: UnicodeString32,
    image_path_name: UnicodeString32,
    pub command_line: UnicodeString32,
    pub environment: u32,
    dw_x: u32,
    dw_y: u32,
    dw_x_size: u32,
    dw_y_size: u32,
    dw_x_count_chars: u32,
    dw_y_count_chars: u32,
    dw_fill_attribute: u32,
    dw_flags: u32,
    w_show_window: u32,
    window_title: UnicodeString32,
    desktop: UnicodeString32,
    shell_info: UnicodeString32,
    runtime_info: UnicodeString32,
    dl_current_directory: [DriveLetterCurdir32; 32],
    pub environment_size: u32,
    environment_version: u32,
    package_dependency_data: u32,
    process_group_id: u32,
    loader_threads: u32,
}

/// The `PEB` prefix up to `ProcessParameters`, exposing `ImageBaseAddress`.
#[repr(C)]
pub struct Peb {
    _pad0: [u8; 0x10],
    pub image_base: *mut c_void,
    _ldr: *mut c_void,
    pub process_parameters: *mut ProcessParameters,
}

/// The `PEB32` prefix up to `ProcessParameters`.
#[repr(C)]
pub struct Peb32 {
    _pad: [u8; 0x10],
    pub process_parameters: u32,
}

const _: () = {
    assert!(size_of::<UnicodeString>() == 0x10);
    assert!(size_of::<UnicodeString32>() == 0x08);
    assert!(size_of::<ProcessParameters>() == 0x410);
    assert!(offset_of!(ProcessParameters, image_path_name) == 0x60);
    assert!(offset_of!(ProcessParameters, command_line) == 0x70);
    assert!(offset_of!(ProcessParameters, environment) == 0x80);
    assert!(offset_of!(ProcessParameters, environment_size) == 0x3f0);
    assert!(size_of::<ProcessParameters32>() == 0x2a4);
    assert!(offset_of!(ProcessParameters32, command_line) == 0x40);
    assert!(offset_of!(ProcessParameters32, environment) == 0x48);
    assert!(offset_of!(ProcessParameters32, environment_size) == 0x290);
    assert!(offset_of!(Peb, image_base) == 0x10);
    assert!(offset_of!(Peb, process_parameters) == 0x20);
    assert!(offset_of!(Peb32, process_parameters) == 0x10);
};

type FnCurrentTeb = unsafe extern "C" fn() -> *mut c_void;
type FnQueryInformationProcess =
    unsafe extern "C" fn(Handle, u32, *mut c_void, u32, *mut u32) -> NtStatus;
type FnAllocateVirtualMemory =
    unsafe extern "C" fn(Handle, *mut *mut c_void, usize, *mut usize, u32, u32) -> NtStatus;
type FnPrependDllPath = unsafe extern "C" fn(*const c_char);
type FnAddLoadOrderOverride = unsafe extern "C" fn(*const u16);

/// The resolved ntdll functions. The first three are required; the two hooks
/// are optional and their features are skipped (with a log line) when absent.
pub struct Ntdll {
    current_teb: FnCurrentTeb,
    query_information_process: FnQueryInformationProcess,
    allocate_virtual_memory: FnAllocateVirtualMemory,
    prepend_dll_path: Option<FnPrependDllPath>,
    add_load_order_override: Option<FnAddLoadOrderOverride>,
}

/// Look one symbol up in the default (global) namespace.
///
/// # Safety
/// The caller must transmute the returned pointer to a signature that matches
/// the real export.
unsafe fn sym(name: &[u8]) -> *mut c_void {
    debug_assert_eq!(name.last(), Some(&0), "symbol name must be NUL-terminated");
    // SAFETY: `name` is a NUL-terminated byte string; dlsym returns null when
    // the symbol is absent, which every caller checks.
    unsafe { libc::dlsym(libc::RTLD_DEFAULT, name.as_ptr().cast::<c_char>()) }
}

impl Ntdll {
    /// Resolve the ntdll surface, or `None` when a required symbol is missing.
    pub fn resolve() -> Option<Self> {
        // SAFETY: each transmute pairs a symbol with the signature ntdll.so
        // exports for it (verified against dlls/ntdll/unix). A null result is
        // turned into None before any call.
        unsafe {
            let teb = sym(b"NtCurrentTeb\0");
            let qip = sym(b"NtQueryInformationProcess\0");
            let alloc = sym(b"NtAllocateVirtualMemory\0");
            if teb.is_null() || qip.is_null() || alloc.is_null() {
                return None;
            }
            let prepend = sym(b"prepend_dll_path\0");
            let add_override = sym(b"add_load_order_override\0");
            Some(Self {
                current_teb: std::mem::transmute::<*mut c_void, FnCurrentTeb>(teb),
                query_information_process: std::mem::transmute::<
                    *mut c_void,
                    FnQueryInformationProcess,
                >(qip),
                allocate_virtual_memory: std::mem::transmute::<*mut c_void, FnAllocateVirtualMemory>(
                    alloc,
                ),
                prepend_dll_path: (!prepend.is_null())
                    .then(|| std::mem::transmute::<*mut c_void, FnPrependDllPath>(prepend)),
                add_load_order_override: (!add_override.is_null()).then(|| {
                    std::mem::transmute::<*mut c_void, FnAddLoadOrderOverride>(add_override)
                }),
            })
        }
    }

    /// The current thread's TEB pointer.
    pub fn current_teb(&self) -> *mut c_void {
        // SAFETY: NtCurrentTeb reads thread-local storage set up long before
        // this library is loaded; it takes no arguments and cannot fail.
        unsafe { (self.current_teb)() }
    }

    /// `NtQueryInformationProcess` for one ULONG-sized info class on the
    /// current process. Returns the value, or `None` on any failure.
    pub fn wow64_information(&self) -> Option<usize> {
        let mut value: usize = 0;
        let ptr: *mut c_void = std::ptr::from_mut(&mut value).cast();
        // SAFETY: `value` outlives the call and is exactly ULONG_PTR-sized, the
        // reply size ProcessWow64Information writes.
        let status = unsafe {
            (self.query_information_process)(
                CURRENT_PROCESS,
                PROCESS_WOW64_INFORMATION,
                ptr,
                PTR_LEN,
                std::ptr::null_mut(),
            )
        };
        (status == 0).then_some(value)
    }

    /// Allocate a committed read-write block. `zero_bits` caps the address (see
    /// [`LIMIT_2G_MINUS_1`]). Returns the base pointer, or `None` on failure.
    pub fn allocate(&self, size: usize, zero_bits: usize) -> Option<*mut c_void> {
        let mut base: *mut c_void = std::ptr::null_mut();
        let mut sz = size;
        // SAFETY: `base` and `sz` are valid out-parameters; the call either
        // fills `base` with a fresh mapping or returns a non-zero status.
        let status = unsafe {
            (self.allocate_virtual_memory)(
                CURRENT_PROCESS,
                std::ptr::from_mut(&mut base),
                zero_bits,
                std::ptr::from_mut(&mut sz),
                MEM_COMMIT,
                PAGE_READWRITE,
            )
        };
        (status == 0 && !base.is_null()).then_some(base)
    }

    pub const fn has_prepend_dll_path(&self) -> bool {
        self.prepend_dll_path.is_some()
    }

    /// Prepend a directory to the builtin DLL search path. The pointer must
    /// stay alive for the process lifetime (ntdll stores it without copying),
    /// so callers pass a leaked `CString`.
    pub fn prepend_dll_path(&self, dir: *const c_char) {
        if let Some(f) = self.prepend_dll_path {
            // SAFETY: `dir` is a valid, NUL-terminated, leaked C string.
            unsafe { f(dir) }
        }
    }

    pub const fn has_add_load_order_override(&self) -> bool {
        self.add_load_order_override.is_some()
    }

    /// Add one `names=order` load-order override. ntdll copies the string, so a
    /// temporary NUL-terminated UTF-16 buffer is fine.
    pub fn add_load_order_override(&self, entry: *const u16) {
        if let Some(f) = self.add_load_order_override {
            // SAFETY: `entry` points at a NUL-terminated UTF-16 string valid
            // for the duration of the call.
            unsafe { f(entry) }
        }
    }
}
