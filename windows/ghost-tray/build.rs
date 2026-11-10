fn main() {
    // Compiles ghost.rc: the tray icon, the app manifest (DPI awareness,
    // asInvoker so no forced UAC), and the version block.
    embed_resource::compile("ghost.rc", embed_resource::NONE);
}
