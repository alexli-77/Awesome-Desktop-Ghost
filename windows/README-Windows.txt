Ghost 👻 for Windows
====================

Make any window look transparent, and optionally hide it from screen sharing.

INSTALL
  1. Unzip. Keep Ghost.exe and ghost_inject.dll together in the same folder
     (the "hide from capture" feature needs the DLL next to the exe).
     Use the x64 build on Intel/AMD PCs, the arm64 build on ARM PCs.
  2. Double-click Ghost.exe. A ghost icon 👻 appears in the tray (the system
     notification area, bottom-right). There is no window.

  Windows SmartScreen may say "Windows protected your PC" because the app is
  not code-signed. Click "More info" -> "Run anyway". (We have no paid signing
  certificate; the source is on GitHub if you want to build it yourself.)

USE
  - Hover a window's title bar for ~0.3 s: a slider appears at its top-right.
    Drag it (20%-100%). 100% restores the window.
  - Ctrl+Alt+T toggles the foreground window between opaque and the default
    opacity.
  - Right-click the tray icon 👻 for: the window list (click one to toggle),
    the default-opacity submenu, "hide from screen sharing", "restore all",
    "run at login", and "exit".

HIDE FROM SCREEN SHARING
  Tray -> "共享/录屏时隐藏" marks ghosted windows so they do not appear in
  screen recordings or shares (Microsoft's SetWindowDisplayAffinity /
  WDA_EXCLUDEFROMCAPTURE). This needs a small helper DLL to be injected into
  the target process, so:
  - It cannot touch windows of elevated / protected processes unless you run
    Ghost as administrator.
  - Antivirus may flag the injection. If a window will not hide, that is the
    likely cause.
  - 32-bit target apps are not supported by this build.

LIMITS
  - Transparency uses the standard layered-window API; a few apps that manage
    their own layering may look wrong.
  - Only tested where the CI compiled it; see the project README for the
    verification status on real hardware.
