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
git clone https://github.com/alexli-77/Ghost.git
cd Ghost
./build.sh      # produces Ghost.app
open Ghost.app
```

`build.sh` also resets the stale Screen Recording grant (`tccutil reset ScreenCapture com.yangli.ghost`), because an ad-hoc signature changes on every build and macOS forgets the previous permission.

## Limitations

- Overlays live at the floating window level, so a normal window dragged *over* a ghosted window is slightly dimmed in the overlapping area.
- Full-screen apps and Stage Manager are untested.
- Cost is roughly one 30 fps screen recording per display in use; negligible on Apple silicon.

## License

MIT
