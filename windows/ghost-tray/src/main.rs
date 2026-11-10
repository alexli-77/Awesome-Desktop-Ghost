// Ghost 👻 for Windows — tray app that makes other apps' windows transparent
// (layered windows) and, optionally, invisible to screen capture
// (SetWindowDisplayAffinity via an injected DLL). See README for the design.
//
// Everything runs on one UI thread, so shared state lives in a thread-local
// `App` that the window procedures and the poll timer reach through `with_app`.

#![windows_subsystem = "windows"]

mod hud;
mod inject;
mod win;

use std::cell::RefCell;

use winreg::enums::HKEY_CURRENT_USER;
use winreg::RegKey;

use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::{HINSTANCE, HWND, LPARAM, LRESULT, POINT, WPARAM};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::SystemInformation::GetTickCount64;
use windows::Win32::UI::Input::KeyboardAndMouse::{
    RegisterHotKey, MOD_ALT, MOD_CONTROL, MOD_NOREPEAT,
};
use windows::Win32::UI::Shell::{
    Shell_NotifyIconW, NIF_ICON, NIF_MESSAGE, NIF_TIP, NIM_ADD, NIM_DELETE, NOTIFYICONDATAW,
};
use windows::Win32::UI::WindowsAndMessaging::*;

// ---- constants ------------------------------------------------------------

const WM_TRAY: u32 = WM_APP + 1;
const TIMER_POLL: usize = 1;
const HOTKEY_ID: i32 = 1;

const IDM_HIDE: usize = 100;
const IDM_RESTORE_ALL: usize = 101;
const IDM_STARTUP: usize = 102;
const IDM_EXIT: usize = 103;
const IDM_DEF_BASE: usize = 200; // + percent (30..=90)
const IDM_WIN_BASE: usize = 1000; // + index into menu_windows

const DEFAULT_PERCENTS: [u8; 7] = [30, 40, 50, 60, 70, 80, 90];
const HOVER_MS: u64 = 300;
const RUN_KEY: &str = r"Software\Microsoft\Windows\CurrentVersion\Run";
const RUN_VALUE: &str = "Ghost";

// ---- state ----------------------------------------------------------------

struct Ghost {
    hwnd: isize,
    pid: u32,
    percent: u8,
    added_layered: bool,
    hidden: bool,
}

pub struct App {
    msg_hwnd: isize,
    pub hud_hwnd: isize,
    ghosts: Vec<Ghost>,
    menu_windows: Vec<win::WinInfo>,
    default_percent: u8,
    hide_in_shares: bool,
    last_pt: POINT,
    last_move: u64,
    pub hud_target: isize,
    pub hud_percent: u8,
    pub dragging: bool,
}

thread_local! {
    static APP: RefCell<Option<App>> = const { RefCell::new(None) };
}

pub fn with_app<R>(f: impl FnOnce(&mut App) -> R) -> R {
    APP.with(|a| f(a.borrow_mut().as_mut().expect("app not initialized")))
}

fn now_ms() -> u64 {
    unsafe { GetTickCount64() }
}

// ---- entry ----------------------------------------------------------------

fn main() {
    unsafe {
        let hmodule = GetModuleHandleW(None).unwrap();
        let hinst = HINSTANCE(hmodule.0);

        // Hidden host window: owns the tray icon, hotkey, menu and poll timer.
        let cls = w!("GhostMsgWindow");
        let wc = WNDCLASSW {
            lpfnWndProc: Some(msg_wndproc),
            hInstance: hinst,
            lpszClassName: cls,
            ..Default::default()
        };
        RegisterClassW(&wc);
        let hwnd = CreateWindowExW(
            Default::default(),
            cls,
            w!("Ghost"),
            WS_OVERLAPPED,
            0,
            0,
            0,
            0,
            None,
            None,
            hinst,
            None,
        )
        .expect("create message window");

        hud::register_class(hinst);

        APP.with(|a| {
            *a.borrow_mut() = Some(App {
                msg_hwnd: hwnd.0 as isize,
                hud_hwnd: 0,
                ghosts: Vec::new(),
                menu_windows: Vec::new(),
                default_percent: 60,
                hide_in_shares: false,
                last_pt: POINT::default(),
                last_move: now_ms(),
                hud_target: 0,
                hud_percent: 60,
                dragging: false,
            });
        });

        // ⌃⌥T toggles the foreground window.
        let _ = RegisterHotKey(
            hwnd,
            HOTKEY_ID,
            MOD_CONTROL | MOD_ALT | MOD_NOREPEAT,
            b'T' as u32,
        );

        add_tray_icon(hwnd.0 as isize, hinst);
        SetTimer(hwnd, TIMER_POLL, 60, None);

        let mut msg = MSG::default();
        while GetMessageW(&mut msg, None, 0, 0).as_bool() {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }
}

// ---- tray icon ------------------------------------------------------------

fn add_tray_icon(hwnd: isize, hinst: windows::Win32::Foundation::HINSTANCE) {
    unsafe {
        let icon = LoadIconW(hinst, PCWSTR(1 as *const u16)).unwrap_or_default();
        let mut nid = NOTIFYICONDATAW {
            cbSize: std::mem::size_of::<NOTIFYICONDATAW>() as u32,
            hWnd: HWND(hwnd as *mut _),
            uID: 1,
            uFlags: NIF_ICON | NIF_MESSAGE | NIF_TIP,
            uCallbackMessage: WM_TRAY,
            hIcon: icon,
            ..Default::default()
        };
        let tip: Vec<u16> = "Ghost 👻".encode_utf16().collect();
        nid.szTip[..tip.len()].copy_from_slice(&tip);
        let _ = Shell_NotifyIconW(NIM_ADD, &nid);
    }
}

fn remove_tray_icon(hwnd: isize) {
    unsafe {
        let nid = NOTIFYICONDATAW {
            cbSize: std::mem::size_of::<NOTIFYICONDATAW>() as u32,
            hWnd: HWND(hwnd as *mut _),
            uID: 1,
            ..Default::default()
        };
        let _ = Shell_NotifyIconW(NIM_DELETE, &nid);
    }
}

// ---- message window procedure ---------------------------------------------

extern "system" fn msg_wndproc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    unsafe {
        match msg {
            WM_TRAY => {
                let evt = (lp.0 & 0xFFFF) as u32;
                if evt == WM_RBUTTONUP || evt == WM_LBUTTONUP || evt == WM_CONTEXTMENU {
                    show_menu(hwnd);
                }
                LRESULT(0)
            }
            WM_HOTKEY if wp.0 as i32 == HOTKEY_ID => {
                toggle_foreground();
                LRESULT(0)
            }
            WM_TIMER if wp.0 == TIMER_POLL => {
                poll_hover();
                LRESULT(0)
            }
            WM_DESTROY => {
                restore_all();
                remove_tray_icon(hwnd.0 as isize);
                PostQuitMessage(0);
                LRESULT(0)
            }
            _ => DefWindowProcW(hwnd, msg, wp, lp),
        }
    }
}

// ---- context menu ---------------------------------------------------------

fn own_hwnds() -> Vec<isize> {
    with_app(|a| vec![a.msg_hwnd, a.hud_hwnd])
}

fn show_menu(hwnd: HWND) {
    unsafe {
        let menu = CreatePopupMenu().unwrap();

        append_disabled(menu, "悬停窗口标题栏 → 滑块 ｜ ⌃⌥T 切换前台窗口");

        // Default-opacity submenu.
        let sub = CreatePopupMenu().unwrap();
        let def = with_app(|a| a.default_percent);
        for p in DEFAULT_PERCENTS {
            let flags = if p == def { MF_STRING | MF_CHECKED } else { MF_STRING };
            let _ = AppendMenuW(sub, flags, IDM_DEF_BASE + p as usize, wtext(&format!("{p}%")));
        }
        let _ = AppendMenuW(
            menu,
            MF_POPUP,
            sub.0 as usize,
            w!("⌃⌥T 默认透明度"),
        );

        let hide_on = with_app(|a| a.hide_in_shares);
        let hflags = if hide_on { MF_STRING | MF_CHECKED } else { MF_STRING };
        let _ = AppendMenuW(menu, hflags, IDM_HIDE, w!("共享/录屏时隐藏（只有你能看到）"));

        let count = with_app(|a| a.ghosts.len());
        if count > 0 {
            let _ = AppendMenuW(
                menu,
                MF_STRING,
                IDM_RESTORE_ALL,
                wtext(&format!("全部恢复 ({count})")),
            );
        }

        let sflags = if startup_enabled() { MF_STRING | MF_CHECKED } else { MF_STRING };
        let _ = AppendMenuW(menu, sflags, IDM_STARTUP, w!("登录时自动启动"));

        let _ = AppendMenuW(menu, MF_SEPARATOR, 0, PCWSTR::null());
        append_disabled(menu, "窗口（点击 = 切换）");

        // Snapshot the window list so command ids map back to hwnds.
        let wins = win::top_level_windows(&own_hwnds());
        for (i, wi) in wins.iter().take(30).enumerate() {
            let ghosted = with_app(|a| a.ghosts.iter().find(|g| g.hwnd == wi.hwnd).map(|g| g.percent));
            let mut label: String = wi.title.chars().take(60).collect();
            let mut flags = MF_STRING;
            if let Some(p) = ghosted {
                label = format!("{label}   {p}%");
                flags |= MF_CHECKED;
            }
            let _ = AppendMenuW(menu, flags, IDM_WIN_BASE + i, wtext(&label));
        }
        with_app(|a| a.menu_windows = wins);

        let _ = AppendMenuW(menu, MF_SEPARATOR, 0, PCWSTR::null());
        let _ = AppendMenuW(menu, MF_STRING, IDM_EXIT, w!("退出"));

        let mut pt = POINT::default();
        let _ = GetCursorPos(&mut pt);
        // Required so the menu dismisses when clicking elsewhere.
        let _ = SetForegroundWindow(hwnd);
        let cmd = TrackPopupMenu(
            menu,
            TPM_RIGHTBUTTON | TPM_RETURNCMD | TPM_NONOTIFY,
            pt.x,
            pt.y,
            0,
            hwnd,
            None,
        );
        let _ = PostMessageW(hwnd, WM_NULL, WPARAM(0), LPARAM(0));
        let _ = DestroyMenu(menu);

        dispatch_command(cmd.0 as usize);
    }
}

fn append_disabled(menu: HMENU, text: &str) {
    unsafe {
        let _ = AppendMenuW(menu, MF_STRING | MF_GRAYED | MF_DISABLED, 0, wtext(text));
    }
}

fn dispatch_command(cmd: usize) {
    if cmd == 0 {
        return;
    }
    match cmd {
        IDM_HIDE => toggle_hide_in_shares(),
        IDM_RESTORE_ALL => restore_all(),
        IDM_STARTUP => toggle_startup(),
        IDM_EXIT => unsafe {
            let h = with_app(|a| a.msg_hwnd);
            let _ = DestroyWindow(HWND(h as *mut _));
        },
        _ if (IDM_DEF_BASE + 20..IDM_DEF_BASE + 100).contains(&cmd) => {
            with_app(|a| a.default_percent = (cmd - IDM_DEF_BASE) as u8);
        }
        _ if cmd >= IDM_WIN_BASE => {
            let idx = cmd - IDM_WIN_BASE;
            let wi = with_app(|a| a.menu_windows.get(idx).cloned());
            if let Some(wi) = wi {
                toggle_window(wi.hwnd, wi.pid);
            }
        }
        _ => {}
    }
}

// ---- ghosting -------------------------------------------------------------

fn is_ghosted(hwnd: isize) -> bool {
    with_app(|a| a.ghosts.iter().any(|g| g.hwnd == hwnd))
}

fn ghost_percent(hwnd: isize) -> Option<u8> {
    with_app(|a| a.ghosts.iter().find(|g| g.hwnd == hwnd).map(|g| g.percent))
}

/// Set a window to `percent` opacity. 100 (or more) restores it.
pub fn set_opacity(hwnd: isize, pid: u32, percent: u8) {
    if percent >= 100 {
        restore_one(hwnd);
        return;
    }
    match win::set_alpha(hwnd, percent) {
        Ok(added) => {
            let hide = with_app(|a| a.hide_in_shares);
            with_app(|a| {
                if let Some(g) = a.ghosts.iter_mut().find(|g| g.hwnd == hwnd) {
                    g.percent = percent;
                } else {
                    a.ghosts.push(Ghost {
                        hwnd,
                        pid,
                        percent,
                        added_layered: added,
                        hidden: false,
                    });
                }
            });
            if hide {
                apply_hide(hwnd, pid, true);
            }
        }
        Err(e) => error_box(&e),
    }
}

fn toggle_window(hwnd: isize, pid: u32) {
    if is_ghosted(hwnd) {
        restore_one(hwnd);
    } else {
        let p = with_app(|a| a.default_percent);
        set_opacity(hwnd, pid, p);
    }
}

fn restore_one(hwnd: isize) {
    let g = with_app(|a| {
        if let Some(i) = a.ghosts.iter().position(|g| g.hwnd == hwnd) {
            Some(a.ghosts.remove(i))
        } else {
            None
        }
    });
    if let Some(g) = g {
        if g.hidden {
            let _ = inject::set_affinity(g.pid, g.hwnd, inject::WDA_NONE);
        }
        win::restore(g.hwnd, g.added_layered);
    }
}

fn restore_all() {
    let all = with_app(|a| std::mem::take(&mut a.ghosts));
    for g in all {
        if g.hidden {
            let _ = inject::set_affinity(g.pid, g.hwnd, inject::WDA_NONE);
        }
        win::restore(g.hwnd, g.added_layered);
    }
}

fn apply_hide(hwnd: isize, pid: u32, hide: bool) {
    let aff = if hide { inject::WDA_EXCLUDEFROMCAPTURE } else { inject::WDA_NONE };
    match inject::set_affinity(pid, hwnd, aff) {
        Ok(()) => {
            with_app(|a| {
                if let Some(g) = a.ghosts.iter_mut().find(|g| g.hwnd == hwnd) {
                    g.hidden = hide;
                }
            });
        }
        Err(e) => error_box(&format!("隐藏窗口失败：{e}")),
    }
}

fn toggle_hide_in_shares() {
    let on = with_app(|a| {
        a.hide_in_shares = !a.hide_in_shares;
        a.hide_in_shares
    });
    let targets: Vec<(isize, u32)> = with_app(|a| a.ghosts.iter().map(|g| (g.hwnd, g.pid)).collect());
    let mut errs = Vec::new();
    for (hwnd, pid) in targets {
        let aff = if on { inject::WDA_EXCLUDEFROMCAPTURE } else { inject::WDA_NONE };
        match inject::set_affinity(pid, hwnd, aff) {
            Ok(()) => with_app(|a| {
                if let Some(g) = a.ghosts.iter_mut().find(|g| g.hwnd == hwnd) {
                    g.hidden = on;
                }
            }),
            Err(e) => errs.push(e),
        }
    }
    // Ghost's own HUD is always excluded from capture (same-process call).
    hud::set_hud_capture_excluded();
    if !errs.is_empty() {
        error_box(&format!(
            "有 {} 个窗口无法{}隐藏：\n{}",
            errs.len(),
            if on { "" } else { "取消" },
            errs.join("\n")
        ));
    }
}

fn toggle_foreground() {
    unsafe {
        let fg = GetForegroundWindow();
        let root = GetAncestor(fg, GA_ROOT);
        let hwnd = root.0 as isize;
        if !win::is_candidate(hwnd, &own_hwnds()) {
            return;
        }
        let pid = win::pid_of(hwnd);
        toggle_window(hwnd, pid);
    }
}

// ---- hover polling --------------------------------------------------------

fn poll_hover() {
    unsafe {
        let mut pt = POINT::default();
        if GetCursorPos(&mut pt).is_err() {
            return;
        }
        let (last, moved) = with_app(|a| {
            let moved = pt.x != a.last_pt.x || pt.y != a.last_pt.y;
            if moved {
                a.last_pt = pt;
                a.last_move = now_ms();
            }
            (a.last_move, moved)
        });
        let _ = moved;
        let stationary = now_ms().saturating_sub(last);

        let (hud, hud_target) = with_app(|a| (a.hud_hwnd, a.hud_target));
        let dragging = with_app(|a| a.dragging);

        // Hide the HUD when the cursor leaves both it and the target.
        if hud != 0 && !dragging {
            let over_hud = point_in_window(hud, pt, 8);
            let over_tgt = win::point_in_caption(hud_target, pt.x, pt.y)
                || point_in_window(hud_target, pt, 0);
            if !over_hud && !over_tgt {
                hud::destroy();
            }
        }

        // Show the HUD after a 0.3 s dwell over a title bar.
        let hud = with_app(|a| a.hud_hwnd);
        if hud == 0 && stationary >= HOVER_MS {
            let under = WindowFromPoint(pt);
            let root = GetAncestor(under, GA_ROOT).0 as isize;
            if win::is_candidate(root, &own_hwnds()) && win::point_in_caption(root, pt.x, pt.y) {
                let p = ghost_percent(root).unwrap_or(with_app(|a| a.default_percent));
                hud::show_for(root, p);
            }
        }
    }
}

fn point_in_window(hwnd: isize, pt: POINT, pad: i32) -> bool {
    if hwnd == 0 {
        return false;
    }
    let r = win::window_rect(hwnd);
    pt.x >= r.left - pad && pt.x < r.right + pad && pt.y >= r.top - pad && pt.y < r.bottom + pad
}

// ---- startup (run at login) -----------------------------------------------

fn startup_enabled() -> bool {
    RegKey::predef(HKEY_CURRENT_USER)
        .open_subkey(RUN_KEY)
        .and_then(|k| k.get_value::<String, _>(RUN_VALUE))
        .is_ok()
}

fn toggle_startup() {
    let key = match RegKey::predef(HKEY_CURRENT_USER).create_subkey(RUN_KEY) {
        Ok((k, _)) => k,
        Err(e) => return error_box(&format!("打开注册表失败：{e}")),
    };
    if startup_enabled() {
        let _ = key.delete_value(RUN_VALUE);
    } else {
        let exe = std::env::current_exe().unwrap_or_default();
        let _ = key.set_value(RUN_VALUE, &format!("\"{}\"", exe.display()));
    }
}

// ---- helpers --------------------------------------------------------------

pub fn wtext(s: &str) -> PCWSTR {
    // Leaks a wide buffer for the duration of a menu call; menus are rare and
    // short-lived, so the leak is negligible and avoids lifetime juggling.
    let v: Vec<u16> = s.encode_utf16().chain(std::iter::once(0)).collect();
    let ptr = v.as_ptr();
    std::mem::forget(v);
    PCWSTR(ptr)
}

pub fn error_box(msg: &str) {
    unsafe {
        let text: Vec<u16> = msg.encode_utf16().chain(std::iter::once(0)).collect();
        MessageBoxW(
            None,
            PCWSTR(text.as_ptr()),
            w!("Ghost"),
            MB_OK | MB_ICONWARNING,
        );
    }
}
