pub const c = @cImport({
    @cDefine("_WIN32_WINNT", "0x0601");
    @cInclude("windows.h");
    @cInclude("shellapi.h");
    @cInclude("winhttp.h");
    @cInclude("sddl.h");
    // Windows 11 window chrome (Mica, dark title bar, rounded corners).
    // Note _WIN32_WINNT above is 0x0601 (Win7), so the newer DWMWA_* constants
    // are not declared here — callers pass the documented integers directly.
    @cInclude("dwmapi.h");
    // SetWindowTheme, for the dark common-controls theme on dialog children.
    @cInclude("uxtheme.h");
    @cInclude("winghostty/win32_host.h");
});
