// Top-level window enumeration and per-window transparency via the standard
// layered-window API (no screen capture, unlike the macOS build).

use windows::Win32::Foundation::{
    GetLastError, SetLastError, BOOL, COLORREF, HWND, LPARAM, RECT, TRUE, WIN32_ERROR,
};
use windows::Win32::Graphics::Dwm::{DwmGetWindowAttribute, DWMWA_CLOAKED};
use windows::Win32::UI::WindowsAndMessaging::{
    EnumWindows, GetWindowLongPtrW, GetWindowRect, GetWindowTextLengthW, GetWindowTextW,
    GetWindowThreadProcessId, IsWindowVisible, SetLayeredWindowAttributes, SetWindowLongPtrW,
    GWL_EXSTYLE, LWA_ALPHA, WINDOW_EX_STYLE, WS_EX_LAYERED, WS_EX_TOOLWINDOW,
};

#[derive(Clone)]
pub struct WinInfo {
    pub hwnd: isize,
    pub pid: u32,
    pub title: String,
}

struct EnumCtx {
    out: Vec<WinInfo>,
    exclude: Vec<isize>,
}

pub fn pid_of(hwnd: isize) -> u32 {
    let mut pid = 0u32;
    unsafe {
        GetWindowThreadProcessId(HWND(hwnd as *mut _), Some(&mut pid));
    }
    pid
}

fn is_cloaked(hwnd: HWND) -> bool {
    let mut cloaked = 0u32;
    unsafe {
        DwmGetWindowAttribute(
            hwnd,
            DWMWA_CLOAKED,
            &mut cloaked as *mut _ as *mut _,
            std::mem::size_of::<u32>() as u32,
        )
        .is_ok()
            && cloaked != 0
    }
}

extern "system" fn enum_proc(hwnd: HWND, lparam: LPARAM) -> BOOL {
    unsafe {
        let ctx = &mut *(lparam.0 as *mut EnumCtx);
        if ctx.exclude.contains(&(hwnd.0 as isize)) {
            return TRUE;
        }
        if !IsWindowVisible(hwnd).as_bool() {
            return TRUE;
        }
        let len = GetWindowTextLengthW(hwnd);
        if len == 0 {
            return TRUE;
        }
        let ex = GetWindowLongPtrW(hwnd, GWL_EXSTYLE) as u32;
        if ex & WS_EX_TOOLWINDOW.0 != 0 {
            return TRUE;
        }
        if is_cloaked(hwnd) {
            return TRUE;
        }
        let mut buf = vec![0u16; (len + 1) as usize];
        let n = GetWindowTextW(hwnd, &mut buf);
        let title = String::from_utf16_lossy(&buf[..n as usize]);
        let mut pid = 0u32;
        GetWindowThreadProcessId(hwnd, Some(&mut pid));
        ctx.out.push(WinInfo {
            hwnd: hwnd.0 as isize,
            pid,
            title,
        });
        TRUE
    }
}

/// All visible, titled, non-tool top-level windows, excluding the given hwnds
/// (Ghost's own windows).
pub fn top_level_windows(exclude: &[isize]) -> Vec<WinInfo> {
    let mut ctx = EnumCtx {
        out: Vec::new(),
        exclude: exclude.to_vec(),
    };
    unsafe {
        let _ = EnumWindows(Some(enum_proc), LPARAM(&mut ctx as *mut _ as isize));
    }
    ctx.out
}

pub fn window_rect(hwnd: isize) -> RECT {
    let mut r = RECT::default();
    unsafe {
        let _ = GetWindowRect(HWND(hwnd as *mut _), &mut r);
    }
    r
}

/// Make `hwnd` partly transparent. `percent` in 20..=99. Returns whether we had
/// to add WS_EX_LAYERED (so restore can remove it again), or an error string if
/// the window belongs to a more-privileged process (UIPI) or otherwise refuses.
pub fn set_alpha(hwnd: isize, percent: u8) -> Result<bool, String> {
    let h = HWND(hwnd as *mut _);
    unsafe {
        let ex = GetWindowLongPtrW(h, GWL_EXSTYLE);
        let added = (ex & WS_EX_LAYERED.0 as isize) == 0;
        if added {
            SetLastError(WIN32_ERROR(0));
            let prev = SetWindowLongPtrW(h, GWL_EXSTYLE, ex | WS_EX_LAYERED.0 as isize);
            if prev == 0 && GetLastError().0 != 0 {
                return Err(uipi_hint());
            }
        }
        let alpha = ((percent as u32 * 255) / 100) as u8;
        SetLayeredWindowAttributes(h, COLORREF(0), alpha, LWA_ALPHA)
            .map_err(|_| uipi_hint())?;
    }
    Ok(added)
}

/// Undo `set_alpha`. If we added WS_EX_LAYERED, remove it; otherwise the window
/// was already layered, so just restore full opacity.
pub fn restore(hwnd: isize, added_layered: bool) {
    let h = HWND(hwnd as *mut _);
    unsafe {
        if added_layered {
            let ex = GetWindowLongPtrW(h, GWL_EXSTYLE);
            let cleared = ex & !(WS_EX_LAYERED.0 as isize);
            SetWindowLongPtrW(h, GWL_EXSTYLE, cleared);
        } else {
            let _ = SetLayeredWindowAttributes(h, COLORREF(0), 255, LWA_ALPHA);
        }
    }
}

fn uipi_hint() -> String {
    "无法修改该窗口：可能来自提权进程或是 UWP/商店应用。以管理员身份运行 Ghost 可处理提权窗口。".into()
}

/// True if `pt` (screen coords) lies in the approximate title-bar band of
/// `hwnd`. Windows has no single "title bar rect" API that works across custom
/// chrome, so we use the top ~42 px of the window.
pub fn point_in_caption(hwnd: isize, x: i32, y: i32) -> bool {
    let r = window_rect(hwnd);
    let band = 42;
    x >= r.left && x < r.right && y >= r.top && y < r.top + band
}

#[allow(dead_code)]
pub fn ex_style(hwnd: isize) -> WINDOW_EX_STYLE {
    unsafe { WINDOW_EX_STYLE(GetWindowLongPtrW(HWND(hwnd as *mut _), GWL_EXSTYLE) as u32) }
}

/// Is this a window a user would reasonably want to ghost (and not one of ours)?
pub fn is_candidate(hwnd: isize, exclude: &[isize]) -> bool {
    if hwnd == 0 || exclude.contains(&hwnd) {
        return false;
    }
    let h = HWND(hwnd as *mut _);
    unsafe {
        if !IsWindowVisible(h).as_bool() || GetWindowTextLengthW(h) == 0 {
            return false;
        }
        let ex = GetWindowLongPtrW(h, GWL_EXSTYLE) as u32;
        if ex & WS_EX_TOOLWINDOW.0 != 0 {
            return false;
        }
    }
    !is_cloaked(h)
}
