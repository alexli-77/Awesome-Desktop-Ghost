// The hover slider HUD: a small layered popup that appears at a window's
// top-right after a 0.3 s title-bar dwell. Dragging the knob sets that window's
// opacity live (20 %–100 %); 100 % restores it. The HUD itself is excluded from
// screen capture so it never shows up in a recording.

use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::{COLORREF, HINSTANCE, HWND, LPARAM, LRESULT, RECT, WPARAM};
use windows::Win32::Graphics::Gdi::{
    BeginPaint, CreateRoundRectRgn, CreateSolidBrush, DeleteObject, Ellipse, EndPaint, FillRect,
    GetStockObject, InvalidateRect, Rectangle, SelectObject, SetBkMode, SetTextColor, SetWindowRgn,
    TextOutW, DEFAULT_GUI_FONT, HDC, HGDIOBJ, PAINTSTRUCT, TRANSPARENT,
};
use windows::Win32::UI::Input::KeyboardAndMouse::{ReleaseCapture, SetCapture};
use windows::Win32::UI::WindowsAndMessaging::*;

use crate::{set_opacity, with_app};

const CLASS: PCWSTR = w!("GhostHud");
const W: i32 = 210;
const H: i32 = 50;
const TL: i32 = 58; // track left
const TR: i32 = W - 16; // track right
const CY: i32 = H / 2;

fn rgb(r: u8, g: u8, b: u8) -> COLORREF {
    COLORREF((r as u32) | ((g as u32) << 8) | ((b as u32) << 16))
}

fn pct_to_x(p: u8) -> i32 {
    TL + ((p as i32 - 20) * (TR - TL)) / 80
}

fn x_to_pct(x: i32) -> u8 {
    let c = x.clamp(TL, TR);
    (20 + ((c - TL) * 80) / (TR - TL)).clamp(20, 100) as u8
}

pub fn register_class(hinst: HINSTANCE) {
    unsafe {
        let wc = WNDCLASSW {
            lpfnWndProc: Some(hud_wndproc),
            hInstance: hinst,
            lpszClassName: CLASS,
            hCursor: LoadCursorW(None, IDC_ARROW).unwrap_or_default(),
            ..Default::default()
        };
        RegisterClassW(&wc);
    }
}

pub fn show_for(target: isize, percent: u8) {
    unsafe {
        let r = crate::win::window_rect(target);
        let x = (r.right - W - 8).max(0);
        let y = (r.top + 6).max(0);

        let hwnd = CreateWindowExW(
            WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_NOACTIVATE,
            CLASS,
            w!("Ghost HUD"),
            WS_POPUP,
            x,
            y,
            W,
            H,
            None,
            None,
            None,
            None,
        );
        let Ok(hwnd) = hwnd else { return };

        let rgn = CreateRoundRectRgn(0, 0, W + 1, H + 1, 16, 16);
        let _ = SetWindowRgn(hwnd, rgn, true);
        let _ = SetLayeredWindowAttributes(hwnd, COLORREF(0), 240, LWA_ALPHA);
        // Keep the HUD out of screen captures (same-process call, no injection).
        let _ = SetWindowDisplayAffinity(hwnd, WINDOW_DISPLAY_AFFINITY(0x11));

        with_app(|a| {
            a.hud_hwnd = hwnd.0 as isize;
            a.hud_target = target;
            a.hud_percent = percent;
        });

        let _ = ShowWindow(hwnd, SW_SHOWNOACTIVATE);
        let _ = InvalidateRect(hwnd, None, true);
    }
}

pub fn destroy() {
    let h = with_app(|a| {
        let h = a.hud_hwnd;
        a.hud_hwnd = 0;
        a.hud_target = 0;
        a.dragging = false;
        h
    });
    if h != 0 {
        unsafe {
            let _ = DestroyWindow(HWND(h as *mut _));
        }
    }
}

pub fn set_hud_capture_excluded() {
    let h = with_app(|a| a.hud_hwnd);
    if h != 0 {
        unsafe {
            let _ = SetWindowDisplayAffinity(HWND(h as *mut _), WINDOW_DISPLAY_AFFINITY(0x11));
        }
    }
}

fn apply(x: i32) {
    let p = x_to_pct(x);
    let target = with_app(|a| {
        a.hud_percent = p;
        a.hud_target
    });
    if target != 0 {
        let pid = crate::win::pid_of(target);
        set_opacity(target, pid, p);
    }
    with_app(|a| {
        if a.hud_hwnd != 0 {
            unsafe {
                let _ = InvalidateRect(HWND(a.hud_hwnd as *mut _), None, true);
            }
        }
    });
}

fn get_x(lp: LPARAM) -> i32 {
    (lp.0 & 0xFFFF) as i16 as i32
}

extern "system" fn hud_wndproc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    unsafe {
        match msg {
            WM_LBUTTONDOWN => {
                SetCapture(hwnd);
                with_app(|a| a.dragging = true);
                apply(get_x(lp));
                LRESULT(0)
            }
            WM_MOUSEMOVE => {
                if with_app(|a| a.dragging) {
                    apply(get_x(lp));
                }
                LRESULT(0)
            }
            WM_LBUTTONUP => {
                let _ = ReleaseCapture();
                with_app(|a| a.dragging = false);
                LRESULT(0)
            }
            WM_PAINT => {
                paint(hwnd);
                LRESULT(0)
            }
            _ => DefWindowProcW(hwnd, msg, wp, lp),
        }
    }
}

fn paint(hwnd: HWND) {
    unsafe {
        let mut ps = PAINTSTRUCT::default();
        let hdc = BeginPaint(hwnd, &mut ps);

        let mut client = RECT::default();
        let _ = GetClientRect(hwnd, &mut client);

        let bg = CreateSolidBrush(rgb(32, 33, 38));
        FillRect(hdc, &client, bg);
        let _ = DeleteObject(HGDIOBJ(bg.0));

        let p = with_app(|a| a.hud_percent);
        let knob_x = pct_to_x(p);

        // Track (unfilled) and filled portion.
        fill_bar(hdc, TL, TR, rgb(80, 82, 90));
        fill_bar(hdc, TL, knob_x, rgb(120, 170, 255));

        // Knob.
        let white = CreateSolidBrush(rgb(240, 240, 245));
        let old = SelectObject(hdc, HGDIOBJ(white.0));
        let _ = Ellipse(hdc, knob_x - 8, CY - 8, knob_x + 8, CY + 8);
        SelectObject(hdc, old);
        let _ = DeleteObject(HGDIOBJ(white.0));

        // Percent label.
        SetBkMode(hdc, TRANSPARENT);
        SetTextColor(hdc, rgb(235, 235, 240));
        let font = GetStockObject(DEFAULT_GUI_FONT);
        let oldf = SelectObject(hdc, font);
        let label: Vec<u16> = format!("{p}%").encode_utf16().collect();
        let _ = TextOutW(hdc, 12, CY - 8, &label);
        SelectObject(hdc, oldf);

        let _ = EndPaint(hwnd, &ps);
    }
}

fn fill_bar(hdc: HDC, x0: i32, x1: i32, color: COLORREF) {
    unsafe {
        let brush = CreateSolidBrush(color);
        let old = SelectObject(hdc, HGDIOBJ(brush.0));
        // 6-px tall bar.
        let _ = Rectangle(hdc, x0, CY - 3, x1.max(x0 + 1), CY + 3);
        SelectObject(hdc, old);
        let _ = DeleteObject(HGDIOBJ(brush.0));
    }
}
