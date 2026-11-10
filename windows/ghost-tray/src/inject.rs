// Injects ghost_inject.dll into a target process so SetWindowDisplayAffinity
// runs inside it. We hand the DLL its parameters through a named shared-memory
// block and wait on a named event for it to report back.

use std::mem::size_of;
use std::path::PathBuf;

use windows::core::{s, PCWSTR};
use windows::Win32::Foundation::{CloseHandle, BOOL, HANDLE, INVALID_HANDLE_VALUE};
use windows::Win32::System::LibraryLoader::{GetModuleHandleW, GetProcAddress};
use windows::Win32::System::Memory::{
    CreateFileMappingW, MapViewOfFile, UnmapViewOfFile, VirtualAllocEx, VirtualFreeEx,
    FILE_MAP_ALL_ACCESS, MEM_COMMIT, MEM_RELEASE, MEM_RESERVE, PAGE_READWRITE,
};
use windows::Win32::System::Threading::{
    CreateEventW, CreateRemoteThread, IsWow64Process, OpenProcess, ResetEvent, WaitForSingleObject,
    LPTHREAD_START_ROUTINE, PROCESS_CREATE_THREAD, PROCESS_QUERY_INFORMATION, PROCESS_VM_OPERATION,
    PROCESS_VM_READ, PROCESS_VM_WRITE, WAIT_OBJECT_0,
};

// WDA_* values from winuser.h.
pub const WDA_NONE: u32 = 0x0000_0000;
pub const WDA_EXCLUDEFROMCAPTURE: u32 = 0x0000_0011;

// Must match ghost-inject's `Params`.
#[repr(C)]
struct Params {
    hwnd: u64,
    affinity: u32,
    status: u32,
}

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

pub fn dll_path() -> PathBuf {
    let mut p = std::env::current_exe().unwrap_or_default();
    p.pop();
    p.push("ghost_inject.dll");
    p
}

fn is_wow64(h: HANDLE) -> bool {
    let mut b = BOOL(0);
    unsafe {
        let _ = IsWow64Process(h, &mut b);
    }
    b.as_bool()
}

/// Apply `affinity` (WDA_NONE or WDA_EXCLUDEFROMCAPTURE) to `hwnd`, which is
/// owned by process `pid`. Returns a human-readable error on failure.
pub fn set_affinity(pid: u32, hwnd: isize, affinity: u32) -> Result<(), String> {
    if !dll_path().exists() {
        return Err("找不到 ghost_inject.dll（应与 Ghost.exe 放在一起）".into());
    }
    unsafe { set_affinity_inner(pid, hwnd, affinity) }
}

unsafe fn set_affinity_inner(pid: u32, hwnd: isize, affinity: u32) -> Result<(), String> {
    // Shared parameter block the DLL reads.
    let map_name = wide("GhostInjectParams");
    let mapping = CreateFileMappingW(
        INVALID_HANDLE_VALUE,
        None,
        PAGE_READWRITE,
        0,
        size_of::<Params>() as u32,
        PCWSTR(map_name.as_ptr()),
    )
    .map_err(|e| format!("创建共享内存失败：{e}"))?;
    let view = MapViewOfFile(mapping, FILE_MAP_ALL_ACCESS, 0, 0, size_of::<Params>());
    if view.Value.is_null() {
        let _ = CloseHandle(mapping);
        return Err("映射共享内存失败".into());
    }
    let params = view.Value as *mut Params;
    (*params).hwnd = hwnd as u64;
    (*params).affinity = affinity;
    (*params).status = 0;

    // Completion event (manual reset).
    let ev_name = wide("GhostInjectDone");
    let event = CreateEventW(None, true, false, PCWSTR(ev_name.as_ptr()))
        .map_err(|e| format!("创建事件失败：{e}"))?;
    let _ = ResetEvent(event);

    let cleanup = |extra: Option<(HANDLE, *mut core::ffi::c_void, usize)>| {
        if let Some((proc, mem, _)) = extra {
            let _ = VirtualFreeEx(proc, mem, 0, MEM_RELEASE);
            let _ = CloseHandle(proc);
        }
        let _ = UnmapViewOfFile(view);
        let _ = CloseHandle(event);
        let _ = CloseHandle(mapping);
    };

    let proc = match OpenProcess(
        PROCESS_CREATE_THREAD
            | PROCESS_QUERY_INFORMATION
            | PROCESS_VM_OPERATION
            | PROCESS_VM_WRITE
            | PROCESS_VM_READ,
        false,
        pid,
    ) {
        Ok(h) => h,
        Err(_) => {
            cleanup(None);
            return Err("无法打开目标进程（可能是提权或受保护进程）。请以管理员身份运行 Ghost 再试。".into());
        }
    };

    // Bitness must match: a 64-bit tray cannot inject a 64-bit DLL into a
    // 32-bit (WOW64) process and vice versa.
    let self_proc = windows::Win32::System::Threading::GetCurrentProcess();
    if is_wow64(proc) != is_wow64(self_proc) {
        cleanup(Some((proc, std::ptr::null_mut(), 0)));
        return Err("目标是 32 位程序，当前版本只能处理 64 位窗口。".into());
    }

    // Write the DLL path into the target.
    let path = wide(&dll_path().to_string_lossy());
    let bytes = path.len() * 2;
    let remote = VirtualAllocEx(proc, None, bytes, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    if remote.is_null() {
        cleanup(Some((proc, std::ptr::null_mut(), 0)));
        return Err("在目标进程分配内存失败".into());
    }
    if windows::Win32::System::Memory::WriteProcessMemory(
        proc,
        remote,
        path.as_ptr() as *const _,
        bytes,
        None,
    )
    .is_err()
    {
        cleanup(Some((proc, remote, bytes)));
        return Err("写入目标进程失败".into());
    }

    // LoadLibraryW address is the same across processes (ASLR keeps kernel32 at
    // one base per boot session).
    let k32 = GetModuleHandleW(PCWSTR(wide("kernel32.dll").as_ptr()))
        .map_err(|e| format!("找不到 kernel32：{e}"))?;
    let load = GetProcAddress(k32, s!("LoadLibraryW"));
    let start: LPTHREAD_START_ROUTINE = std::mem::transmute(load);

    let thread = match CreateRemoteThread(proc, None, 0, start, Some(remote as *const _), 0, None) {
        Ok(h) => h,
        Err(_) => {
            cleanup(Some((proc, remote, bytes)));
            return Err("注入失败（可能被杀毒软件拦截，或目标是受保护进程）。".into());
        }
    };

    // The DLL's own worker thread signals the event once it has run. 5 s is
    // plenty; a timeout means the DLL never loaded or was blocked.
    let waited = WaitForSingleObject(event, 5000);
    let status = (*params).status;
    let _ = CloseHandle(thread);
    cleanup(Some((proc, remote, bytes)));

    if waited != WAIT_OBJECT_0 {
        return Err("注入超时，目标可能拦截了注入。".into());
    }
    match status {
        1 => Ok(()),
        2 => Err("目标进程内 SetWindowDisplayAffinity 调用失败。".into()),
        _ => Err("注入未返回结果。".into()),
    }
}
