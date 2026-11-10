# Ghost 👻

Make any macOS window look transparent — **without disabling SIP**.

Hover a window's title bar and a slider appears; drag it and the window becomes see-through while staying fully clickable.

## How it works

macOS does not let one process change another process's window alpha, and the old injection tricks (Afloat, SIMBL) no longer survive SIP and the hardened runtime.

Ghost takes the opposite route. Instead of making the target window transparent, it:

1. captures the display **with the target window excluded** using ScreenCaptureKit,
2. draws that capture in a click-through overlay sitting on top of the target, at partial alpha.

Visually the target looks transparent — you see what is behind it. Clicks pass through the overlay to the real window. Only the Screen Recording permission is needed.

## Usage

- **Hover** a window's title bar for ~0.3 s → a slider HUD appears at the window's top-right. Drag it (20 % – 100 %). 100 % restores the window.
- **⌃⌥T** toggles the frontmost window between 100 % and the default opacity.
- Menu bar **👻** lists windows with their current opacity, lets you restore all, and sets the ⌃⌥T default.

Multiple windows can be ghosted at different levels.

### Hide from screen sharing

Menu bar **👻 → 共享/录屏时隐藏** switches modes: ghosted windows stay visible to you at their opacity, but disappear from screen sharing, recordings and screenshots (Zoom, Meet, Teams, Cap, QuickTime, ⇧⌘3 …). Everyone else sees what is behind the window.

How: while a window is hidden, Ghost covers each display with a full-screen capture of the screen *without* that app, which only captures see, and shows you a second, local-only capture of the real screen on top, with the hidden window blended in. Because the cover is full-screen, dragging, jumping, minimizing or switching Spaces can't uncover the window. A hidden app's menus, sheets and popovers are left out from their first frame; its unrelated windows stay visible to viewers (a newly opened one may appear a moment late). The cursor is hidden from captures while it's over a hidden window.

**Which sharing tools it works with.** Hiding relies on the capture tool honouring macOS's "don't capture this window" flag, which everything built on ScreenCaptureKit does:

- verified: Chrome's screen sharing (`getDisplayMedia`, what Google Meet, Zoom / Teams / Feishu in the browser use), the macOS screenshot and recording tools (⇧⌘3, ⇧⌘5), Cap;
- **not** honoured: Feishu / Lark's desktop screen recorder, which grabs the raw screen — it records exactly what you see, so nothing can be hidden from it. Other native meeting apps may do the same; test before relying on them (share your screen and check what the other side sees).

If Ghost crashes or is force-quit, a watchdog process that keeps opaque blocks under the hidden windows takes over at once and relaunches Ghost, which covers them again.

Trade-offs while something is hidden:

- your whole screen is shown through a capture, about one display frame late, and the window server works noticeably harder (≈ half a CPU core on an M-series Mac);
- DRM-protected video (Netflix, Apple TV) can't be captured, so it may show black to you as well;
- quitting Ghost from the menu warns you first: hidden windows reappear in shares once it's gone.

## Install

1. Download `Ghost.app.zip` from the [latest release](../../releases/latest) and unzip it.
2. Drag `Ghost.app` into `/Applications` (optional) and double-click it. It lives in the menu bar as 👻 — no Dock icon.
3. First launch asks for **Screen Recording**: turn Ghost on in *System Settings → Privacy & Security → Screen Recording*, then quit Ghost (👻 → 退出) and open it again.
4. Optional: 👻 → **登录时自动启动** to have it start at login.

The app is ad-hoc signed (no paid Apple developer certificate), so the first double-click may be blocked with "cannot be opened because the developer cannot be verified". Either right-click → **Open** → Open, or clear the quarantine flag once:

```bash
xattr -dr com.apple.quarantine /Applications/Ghost.app
```

## Build from source

Requires macOS 13+ and Xcode or the Command Line Tools.

```bash
git clone https://github.com/alexli-77/Awesome-Desktop-Ghost.git
cd Awesome-Desktop-Ghost
./build.sh      # builds Ghost.app and installs it to /Applications
open /Applications/Ghost.app
```

`build.sh` also resets the stale Screen Recording grant (`tccutil reset ScreenCapture com.yangli.ghost`), because an ad-hoc signature changes on every build and macOS forgets the previous permission.

## Limitations

- The ghost effect shows up in screen recordings (Cap, QuickTime, …); the opacity slider does not.
- Overlays live at the floating window level, so a normal window dragged *over* a ghosted window is slightly dimmed in the overlapping area.
- Full-screen apps and Stage Manager are untested; hide mode is untested on multiple displays.
- Cost is roughly one 30 fps screen recording per display in use; negligible on Apple silicon.

## License

MIT
