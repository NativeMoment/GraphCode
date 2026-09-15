//! Shared Windows 11 chrome.
//!
//! Before this module the app made no DwmSetWindowAttribute calls at all and
//! left every one of its 42 native controls system-drawn with the default GUI
//! font, which is why dialogs rendered with Windows-95 bevels and a light
//! title bar regardless of how the client area was painted.
//!
//! Everything here is best-effort: older Windows returns a failure HRESULT for
//! attributes it does not recognise and we ignore it, so this stays safe on
//! Windows 10 and degrades to the previous look rather than failing.

const std = @import("std");
const c = @import("Win32.zig").c;

// DWM attribute ids. _WIN32_WINNT is 0x0601 (Windows 7) in Win32.zig, so the
// DWMWA_* constants are not declared by the headers — pass the documented
// integers directly.
const DWMWA_USE_IMMERSIVE_DARK_MODE: c.DWORD = 20;
const DWMWA_USE_IMMERSIVE_DARK_MODE_LEGACY: c.DWORD = 19;
const DWMWA_WINDOW_CORNER_PREFERENCE: c.DWORD = 33;
const DWMWA_SYSTEMBACKDROP_TYPE: c.DWORD = 38;

const DWMWCP_ROUND: c.INT = 2;
const DWMSBT_MAINWINDOW: c.INT = 2; // Mica
const DWMSBT_TRANSIENTWINDOW: c.INT = 3; // Acrylic, for dialogs/popups

/// Opt the whole process into dark mode.
///
/// This must run before any SetWindowTheme("DarkMode_*") call, otherwise those
/// silently do nothing and controls stay light — which is exactly what happened
/// on the first attempt: the title bar darkened but every EDIT, COMBOBOX and
/// BUTTON in the dialogs stayed white.
///
/// SetPreferredAppMode is exported from uxtheme.dll by ORDINAL 135 only, with
/// no public header declaration, so it has to be resolved at runtime. It exists
/// from Windows 10 1809; on anything older GetProcAddress simply returns null
/// and we leave the light theme in place.
const PreferredAppMode = enum(c_int) { default = 0, allow_dark = 1, force_dark = 2, force_light = 3 };
const SetPreferredAppModeFn = *const fn (PreferredAppMode) callconv(.winapi) PreferredAppMode;

var dark_mode_ready = false;

pub fn enableProcessDarkMode() void {
    if (dark_mode_ready) return;
    dark_mode_ready = true;
    const module = c.LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("uxtheme.dll").ptr) orelse return;
    // MAKEINTRESOURCEA(135) — the ordinal must be passed as a pointer-sized int.
    const proc = c.GetProcAddress(module, @ptrFromInt(135)) orelse return;
    const setPreferredAppMode: SetPreferredAppModeFn = @ptrCast(proc);
    _ = setPreferredAppMode(.allow_dark);
}

/// Dark title bar. Attribute 20 is correct on Windows 10 2004+; 19 was the
/// pre-release id, so fall back to it when 20 is rejected.
pub fn applyDarkTitleBar(hwnd: c.HWND) void {
    var dark: c.BOOL = 1;
    if (c.DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, &dark, @sizeOf(c.BOOL)) != 0)
        _ = c.DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE_LEGACY, &dark, @sizeOf(c.BOOL));
}

pub fn applyRoundedCorners(hwnd: c.HWND) void {
    var corner: c.INT = DWMWCP_ROUND;
    _ = c.DwmSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, &corner, @sizeOf(c.INT));
}

/// Main-window chrome: dark title bar, rounded corners, Mica backdrop.
pub fn applyWindowChrome(hwnd: c.HWND) void {
    applyDarkTitleBar(hwnd);
    applyRoundedCorners(hwnd);
    var backdrop: c.INT = DWMSBT_MAINWINDOW;
    _ = c.DwmSetWindowAttribute(hwnd, DWMWA_SYSTEMBACKDROP_TYPE, &backdrop, @sizeOf(c.INT));
}

/// Dialog chrome: same, but Acrylic rather than Mica, which is what Windows
/// uses for transient surfaces. Also restyles every child control.
pub fn applyDialogChrome(hwnd: c.HWND) void {
    applyDarkTitleBar(hwnd);
    applyRoundedCorners(hwnd);
    var backdrop: c.INT = DWMSBT_TRANSIENTWINDOW;
    _ = c.DwmSetWindowAttribute(hwnd, DWMWA_SYSTEMBACKDROP_TYPE, &backdrop, @sizeOf(c.INT));
    modernizeChildren(hwnd);
}

/// Walk every child control, give it Segoe UI 9pt and the dark Explorer theme.
/// The default is the ancient DEFAULT_GUI_FONT plus the light common-controls
/// theme, which is the single biggest reason the dialogs look dated.
pub fn modernizeChildren(hwnd: c.HWND) void {
    _ = c.EnumChildWindows(hwnd, childProc, 0);
}

fn childProc(child: c.HWND, _: c.LPARAM) callconv(.c) c.BOOL {
    if (uiFont()) |font|
        _ = c.SendMessageW(child, c.WM_SETFONT, @intFromPtr(font), 1);
    applyDarkTheme(child);
    return 1;
}

/// Opt a control into the dark common-controls theme. "DarkMode_Explorer"
/// covers list/tree/scrollbar; "DarkMode_CFD" is the one that actually darkens
/// EDIT and COMBOBOX backgrounds.
pub fn applyDarkTheme(hwnd: c.HWND) void {
    var class_name: [64]u16 = undefined;
    const n = c.GetClassNameW(hwnd, &class_name, class_name.len);
    if (n <= 0) return;
    const class = class_name[0..@intCast(n)];
    if (eqlAscii(class, "Edit") or eqlAscii(class, "ComboBox")) {
        const cfd = std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_CFD");
        _ = c.SetWindowTheme(hwnd, cfd.ptr, null);
    } else {
        const explorer = std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer");
        _ = c.SetWindowTheme(hwnd, explorer.ptr, null);
    }
}

fn eqlAscii(wide: []const u16, ascii: []const u8) bool {
    if (wide.len != ascii.len) return false;
    for (wide, ascii) |w, a| {
        if (w != a) return false;
    }
    return true;
}

// Dialog surface colours. COLORREF is 0x00BBGGRR — blue, green, red.
const dialog_bg: u32 = 0x00262220; // rgb(32,34,38)
const control_bg: u32 = 0x00332E2B; // rgb(43,46,51)
const dialog_text: u32 = 0x00F2F2F2; // rgb(242,242,242)

var dialog_brush: ?c.HBRUSH = null;
var control_brush: ?c.HBRUSH = null;

/// Handle WM_CTLCOLOR* so dialog backgrounds and control faces go dark.
///
/// SetWindowTheme alone does not repaint a dialog's own background or a STATIC
/// label's, so without this the dialogs stayed white behind dark-themed edits.
/// Returns the brush to hand back from the window proc, or null if unhandled.
pub fn controlColor(message: c.UINT, hdc: c.HDC) ?c.HBRUSH {
    switch (message) {
        c.WM_CTLCOLORDLG, c.WM_CTLCOLORSTATIC, c.WM_CTLCOLORBTN => {
            _ = c.SetTextColor(hdc, dialog_text);
            _ = c.SetBkColor(hdc, dialog_bg);
            _ = c.SetBkMode(hdc, c.OPAQUE);
            if (dialog_brush == null) dialog_brush = c.CreateSolidBrush(dialog_bg);
            return dialog_brush;
        },
        c.WM_CTLCOLOREDIT, c.WM_CTLCOLORLISTBOX => {
            _ = c.SetTextColor(hdc, dialog_text);
            _ = c.SetBkColor(hdc, control_bg);
            if (control_brush == null) control_brush = c.CreateSolidBrush(control_bg);
            return control_brush;
        },
        else => return null,
    }
}

// Button palette. GDI COLORREF is 0x00BBGGRR — blue, green, red.
const button_face: u32 = 0x003A3330; // rgb(48,51,58)
const button_hot: u32 = 0x00484040; // rgb(64,64,72)
const button_pressed: u32 = 0x002E2926; // rgb(38,41,46)
const button_text: u32 = 0x00F2F2F2; // rgb(242,242,242)
const button_disabled: u32 = 0x00707070; // rgb(112,112,112)
const button_accent: u32 = 0x00FF9F0A; // rgb(10,159,255)

/// Paint an owner-draw push button: flat, rounded, no 3D bevel.
///
/// Windows' stock BS_PUSHBUTTON draws a raised grey chrome that no amount of
/// theming removes, which is why the buttons looked like Windows 95 even after
/// the rest of the window went dark. Owner-draw is the only way to replace it.
pub fn drawButton(item: *const c.DRAWITEMSTRUCT) void {
    const hdc = item.hDC;
    const bounds = item.rcItem;
    const pressed = (item.itemState & c.ODS_SELECTED) != 0;
    const disabled = (item.itemState & c.ODS_DISABLED) != 0;
    const focused = (item.itemState & c.ODS_FOCUS) != 0;

    const face = if (pressed) button_pressed else if (focused) button_hot else button_face;
    const border = if (focused) button_accent else face;

    const brush = c.CreateSolidBrush(face);
    const pen = c.CreatePen(c.PS_SOLID, 1, border);
    if (brush != null and pen != null) {
        const old_brush = c.SelectObject(hdc, brush);
        const old_pen = c.SelectObject(hdc, pen);
        _ = c.RoundRect(hdc, bounds.left, bounds.top, bounds.right, bounds.bottom, 12, 12);
        _ = c.SelectObject(hdc, old_pen);
        _ = c.SelectObject(hdc, old_brush);
    }
    if (pen != null) _ = c.DeleteObject(pen);
    if (brush != null) _ = c.DeleteObject(brush);

    var text: [256]u16 = undefined;
    const n = c.GetWindowTextW(item.hwndItem, &text, text.len);
    if (n > 0) {
        const old_font = if (uiFont()) |font| c.SelectObject(hdc, font) else null;
        _ = c.SetBkMode(hdc, c.TRANSPARENT);
        _ = c.SetTextColor(hdc, if (disabled) button_disabled else button_text);
        var rc = bounds;
        _ = c.DrawTextW(hdc, &text, n, &rc, c.DT_CENTER | c.DT_VCENTER | c.DT_SINGLELINE);
        if (old_font != null) _ = c.SelectObject(hdc, old_font);
    }
}

/// Segoe UI 9pt, created once and reused. The handle is owned by this module
/// and intentionally lives for the process lifetime — controls keep
/// referencing it, so it must not be deleted while any dialog is open.
var ui_font: ?c.HFONT = null;

pub fn uiFont() ?c.HFONT {
    if (ui_font) |font| return font;
    ui_font = c.CreateFontW(
        -12, 0, 0, 0, c.FW_NORMAL, 0, 0, 0, c.DEFAULT_CHARSET,
        c.OUT_DEFAULT_PRECIS, c.CLIP_DEFAULT_PRECIS, c.CLEARTYPE_QUALITY,
        c.DEFAULT_PITCH | c.FF_DONTCARE,
        std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI").ptr,
    );
    return ui_font;
}

test "class name comparison is exact" {
    const edit = std.unicode.utf8ToUtf16LeStringLiteral("Edit");
    try std.testing.expect(eqlAscii(edit[0..4], "Edit"));
    try std.testing.expect(!eqlAscii(edit[0..4], "Button"));
}
