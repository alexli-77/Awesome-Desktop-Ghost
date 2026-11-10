// ghost_inject.dll — injected into a target process so that a
// SetWindowDisplayAffinity call runs *inside* that process.
//
// SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE) only affects windows owned
// by the calling process, so the tray cannot hide another app's window from
// its own process. The tray injects this DLL; on load it reads the target HWND
// and the affinity value from a named shared-memory block the tray filled in,
// applies it, reports a status byte back, signals a named event, then unloads
// itself (FreeLibraryAndExitThread) so nothing lingers in the target.

#![cfg(windows)]

use core::ffi::c_void;
use core::mem::size_of;
use windows::core::w;
use windows::Win32::Foundation::{BOOL, CloseHandle, HMODULE, HWND, TRUE};
use windows::Win32::System::LibraryLoader::{DisableThreadLibraryCalls, FreeLibraryAndExitThread};
use windows::Win32::System::Memory::{
    MapViewOfFile, OpenFileMappingW, UnmapViewOfFile, FILE_MAP_ALL_ACCESS,
};
use windows::Win32::System::Threading::{
    CreateThread, OpenEventW, SetEvent, EVENT_MODIFY_STATE, THREAD_CREATION_FLAGS,
};
use windows::Win32::UI::WindowsAndMessaging::{
    SetWindowDisplayAffinity, WINDOW_DISPLAY_AFFINITY,
};

// Must match ghost-tray's `inject::Params`.
#[repr(C)]
struct Params {
    hwnd: u64,
    affinity: u32,
    status: u32, // 0 = pending, 1 = success, 2 = failed
}

const DLL_PROCESS_ATTACH: u32 = 1;

#[no_mangle]
#[allow(non_snake_case, clippy::missing_safety_doc)]
pub unsafe extern "system" fn DllMain(hinst: HMODULE, reason: u32, _reserved: *mut c_void) -> BOOL {
    if reason == DLL_PROCESS_ATTACH {
        let _ = DisableThreadLibraryCalls(hinst);
        // Hand the work to a dedicated thread: doing it on the loader lock (in
        // DllMain) and self-unloading from there is unsafe, so the thread owns
        // the whole lifetime and ejects the module when done.
        let _ = CreateThread(
            None,
            0,
            Some(worker),
            Some(hinst.0 as *const c_void),
            THREAD_CREATION_FLAGS(0),
            None,
        );
    }
    TRUE
}

unsafe extern "system" fn worker(param: *mut c_void) -> u32 {
    apply();
    // Unload this DLL from the target and end the thread in one atomic step.
    // This call does not return; the trailing 0 only satisfies the signature.
    FreeLibraryAndExitThread(HMODULE(param), 0);
    0
}

unsafe fn apply() {
    let Ok(mapping) = OpenFileMappingW(FILE_MAP_ALL_ACCESS.0, false, w!("GhostInjectParams")) else {
        return;
    };
    let view = MapViewOfFile(mapping, FILE_MAP_ALL_ACCESS, 0, 0, size_of::<Params>());
    if view.Value.is_null() {
        let _ = CloseHandle(mapping);
        return;
    }

    let p = view.Value as *mut Params;
    let hwnd = HWND((*p).hwnd as *mut c_void);
    let affinity = WINDOW_DISPLAY_AFFINITY((*p).affinity);

    let ok = SetWindowDisplayAffinity(hwnd, affinity).is_ok();
    (*p).status = if ok { 1 } else { 2 };

    let _ = UnmapViewOfFile(view);
    let _ = CloseHandle(mapping);

    // Tell the tray the DLL has run (success or not).
    if let Ok(ev) = OpenEventW(EVENT_MODIFY_STATE, false, w!("GhostInjectDone")) {
        let _ = SetEvent(ev);
        let _ = CloseHandle(ev);
    }
}
