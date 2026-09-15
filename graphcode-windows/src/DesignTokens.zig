pub const Color = u32;

pub const window_tone: Color = 0x001E1E1E;
pub const window_background: Color = 0x8C1E1E1E;
pub const canvas_background: Color = 0x9E181818;
pub const canvas_tone: Color = 0x00181818;
pub const canvas_grid_line: Color = 0x00272727;
pub const canvas_edge: Color = 0x006A6A6A;
pub const canvas_selection: Color = 0x007AB8FF;
pub const unfocused_pane_veil: Color = 0x591E1E1E;
pub const terminal_background_opacity: f32 = 0.80;
pub const workspace_rail: Color = 0x001D1D21;
pub const pane_focus_tint: Color = 0x000A84FF;

pub const loop_card_width: i32 = 250;
pub const loop_card_height: i32 = 106;
pub const loop_card_radius: i32 = 11;
pub const loop_card_stripe: i32 = 4;
pub const workspace_rail_width: i32 = 212;
pub const loop_bar_height: i32 = 46;
pub const loop_detail_width: i32 = 272;
pub const pane_header_height: i32 = 22;
pub const tab_bar_height: i32 = 30;
pub const canvas_grid_cell: i32 = 24;

pub const sidebar_width: i32 = 220;
pub const header_height: i32 = 34;
pub const workspace_height: i32 = 250;
pub const activity_strip_height: i32 = 48;

// ---------------------------------------------------------------------------
// Modern surface / text / accent roles.
//
// GDI COLORREF is 0x00BBGGRR — byte order is BLUE, GREEN, RED. Writing these as
// if they were 0xRRGGBB silently swaps red and blue, which is why every value
// below carries its true RGB in a comment.
// ---------------------------------------------------------------------------

// Measured from the project's own brand surfaces, not invented: the docs site
// (docs/assets/css/style.scss, docs/index.html) and screenshots/graph-hero.png.
// Hex in the comments is the source sRGB; the literal is COLORREF 0x00BBGGRR.

// Surfaces, darkest to lightest.
pub const surface_base: Color = 0x00171313; // #131317 window ground
pub const surface_raised: Color = 0x00302A2A; // #2a2a30 sidebar / panels
pub const surface_hover: Color = 0x00423A3A; // #3a3a42 row hover
pub const surface_selected: Color = 0x00524A4A; // #4a4a52 row selected
pub const surface_border: Color = 0x003D3630; // #30363d hairline divider

// Text, strongest to weakest.
pub const text_primary: Color = 0x00F3EDE6; // #e6edf3
pub const text_secondary: Color = 0x00D9D1C9; // #c9d1d9
pub const text_muted: Color = 0x00948E8E; // #8e8e94
pub const text_faint: Color = 0x00646464; // rgb(100,100,100) section headings

// Accent + status.
// The brand accent is AMBER (#f0a23b - the most-used colour on the docs site and
// the "needs you" colour in graph-hero.png), not a blue. An earlier revision of
// this file guessed blue without checking the reference.
pub const accent: Color = 0x003BA2F0; // #f0a23b brand amber
pub const status_attention: Color = 0x003BA2F0; // #f0a23b "needs you"
pub const status_running: Color = 0x00FF9E4A; // #4a9eff blue "running"
pub const status_done: Color = 0x008AC94E; // #4ec98a green
pub const status_failed: Color = 0x005F5FFF; // rgb(255,95,95) red
pub const status_idle: Color = 0x00948E8E; // #8e8e94 grey

// Geometry.
pub const row_radius: i32 = 7;
pub const chip_radius: i32 = 9;
pub const row_height: i32 = 26;
pub const row_inset: i32 = 8;

// Segoe Fluent Icons / Segoe MDL2 Assets glyphs. Both ship with Windows 11;
// MDL2 is the fallback on 10. Rendered via DrawTextW with `icon_font`.
pub const icon_font = "Segoe Fluent Icons";
pub const icon_font_fallback = "Segoe MDL2 Assets";
pub const glyph_chevron_right = "\u{E76C}";
pub const glyph_chevron_down = "\u{E70D}";
pub const glyph_folder = "\u{E8B7}";
pub const glyph_cloud = "\u{E753}";
pub const glyph_graph = "\u{E71B}";
pub const glyph_chat = "\u{E8BD}";
pub const glyph_add = "\u{E710}";

pub fn rgb(color: Color) u32 {
    return color & 0x00FFFFFF;
}
