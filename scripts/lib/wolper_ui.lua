-- Wolper's menu look for Tempest Lua mods: the palette, metrics, motion and
-- row controls of Wolper's UiWidgets (docs/overlay-ui.md in the Wolper tree),
-- drawn through the `ui` module. A menu is a window of rounded lists; a row
-- is a label, an optional "?" with help, and one control on the right.
--
-- Everything but load_fonts runs inside a ui.on_draw handler. The menu's
-- colours and sizes are pushed around its window only, since every mod
-- draws with the same ImGui style.
local ffi = require("ffi")

local C = ui.C
local Col, Var = ui.Col, ui.StyleVar
local band, bor, lshift, rshift = bit.band, bit.bor, bit.lshift, bit.rshift
local floor, max, min, abs = math.floor, math.max, math.min, math.abs

local M = {}

local function round(v)
	return floor(v + 0.5)
end

local function clamp01(v)
	return v < 0 and 0 or v > 1 and 1 or v
end

-- Colours: packed ImU32, from Wolper's OverlayMenuTheme palette.

local function rgba(r, g, b, a)
	return bor(lshift(a or 255, 24), lshift(b, 16), lshift(g, 8), r)
end

local function mix(a, b, t)
	local ar, ag, ab, aa = band(a, 0xFF), band(rshift(a, 8), 0xFF), band(rshift(a, 16), 0xFF), rshift(a, 24)
	local br, bg, bb, ba = band(b, 0xFF), band(rshift(b, 8), 0xFF), band(rshift(b, 16), 0xFF), rshift(b, 24)
	return rgba(round(ar + (br - ar) * t), round(ag + (bg - ag) * t), round(ab + (bb - ab) * t), round(aa + (ba - aa) * t))
end

local P = {
	window = rgba(17, 17, 19),
	box = rgba(30, 30, 33),
	fill = rgba(48, 48, 53),
	fill_hover = rgba(58, 58, 64),
	raised = rgba(84, 84, 91),
	popup = rgba(38, 38, 42),
	key_edge = rgba(16, 16, 18),
	border_strong = rgba(84, 84, 92),
	rim = rgba(255, 255, 255, 16),
	divider = rgba(45, 45, 50),
	icon_idle = rgba(190, 190, 196),
	text = rgba(244, 244, 246),
	text_muted = rgba(156, 156, 164),
	text_faint = rgba(124, 124, 132),
	track_off = rgba(62, 62, 68),
	knob = rgba(248, 248, 250),
	knob_shadow = rgba(0, 0, 0, 72),
	thumb_shadow = rgba(0, 0, 0, 60),
	scrim = rgba(0, 0, 0, 150),
	white = rgba(255, 255, 255),
	black = rgba(0, 0, 0),
	none = 0,
}

-- Wolper's accent presets, in the order its settings store them.
local ACCENTS = {
	{ 58, 196, 212 }, -- Wolper
	{ 150, 136, 222 }, -- Iris
	{ 228, 82, 76 }, -- Signal
	{ 208, 164, 88 }, -- Brass
	{ 128, 176, 108 }, -- Moss
	{ 214, 208, 194 }, -- Bone
}

local accent, accent_bright
-- Flat (ImGuiCol, colour) pairs pushed around the menu, so stock widgets
-- such as the colour picker and tooltips share the surfaces.
local THEME = {}

local function set_accent(index)
	local preset = ACCENTS[(index or 0) + 1] or ACCENTS[1]
	local r, g, b = preset[1], preset[2], preset[3]
	accent = rgba(r, g, b)
	accent_bright = rgba(r + floor((255 - r) * 0.3), g + floor((255 - g) * 0.3), b + floor((255 - b) * 0.3))
	THEME = {
		Col.Text, P.text,
		Col.TextDisabled, P.text_faint,
		Col.WindowBg, P.window,
		Col.ChildBg, P.none,
		Col.PopupBg, P.popup,
		Col.Border, P.rim,
		Col.BorderShadow, P.none,
		Col.FrameBg, P.fill,
		Col.FrameBgHovered, P.fill_hover,
		Col.FrameBgActive, P.fill_hover,
		Col.ScrollbarBg, P.none,
		Col.ScrollbarGrab, P.raised,
		Col.ScrollbarGrabHovered, P.border_strong,
		Col.ScrollbarGrabActive, accent,
		Col.CheckMark, accent_bright,
		Col.SliderGrab, accent,
		Col.SliderGrabActive, accent_bright,
		Col.Button, P.fill,
		Col.ButtonHovered, P.fill_hover,
		Col.ButtonActive, P.raised,
		Col.Header, rgba(r, g, b, 56),
		Col.HeaderHovered, rgba(r, g, b, 77),
		Col.HeaderActive, rgba(r, g, b, 102),
		Col.Separator, P.divider,
		Col.TextSelectedBg, rgba(r, g, b, 89),
		Col.NavCursor, accent,
	}
end

-- The accent the player picked in Wolper's interface settings, if Wolper is installed.
local function wolper_accent()
	local dir = os.getenv("APPDATA")
	local file = dir and io.open(dir .. "\\Wolper\\shared.json", "r")
	if not file then
		return 0
	end
	local text = file:read("*a") or ""
	file:close()
	return tonumber(text:match('"uiAccent"%s*:%s*(%d)')) or 0
end

set_accent(wolper_accent())

-- Fonts: Wolper's Segoe UI Semibold body and Bold titles. Wine and Proton
-- prefixes usually lack Segoe UI, so Arial and Tahoma stand in, and the
-- built-in font when none is there.

local FONT_SIZE = 17
local FONT_DIR = (os.getenv("WINDIR") or "C:\\Windows") .. "\\Fonts\\"
local BODY_FACES = { "seguisb.ttf", "segoeui.ttf", "arial.ttf", "tahoma.ttf" }
local STRONG_FACES = { "segoeuib.ttf", "arialbd.ttf", "tahomabd.ttf" }

-- Every mod draws from one font atlas, which outlives reloads, so a face
-- already in it is reused by the name ImGui gives it ("seguisb.ttf, 17px").
local function atlas_font(name)
	local list = C.igGetIO().Fonts.Fonts
	for i = 0, list.Size - 1 do
		local font = list.Data[i]
		if font.Sources ~= nil and ffi.string(font.Sources.Name) == name then
			return font
		end
	end
end

local function add_face(names)
	for _, name in ipairs(names) do
		local font = atlas_font(string.format("%s, %dpx", name, FONT_SIZE))
		if font then
			return font
		end
		local path = FONT_DIR .. name
		local file = io.open(path, "rb")
		if file then
			file:close()
			font = ui.add_font(path, FONT_SIZE)
			if font then
				return font
			end
		end
	end
end

local fonts -- { body, strong } once loaded; both nil means the built-in font

-- ui.add_font only hands back the font outside a frame: call this from a key
-- handler or at load.
function M.load_fonts()
	if fonts or not ui.ready() then
		return
	end
	local body = add_face(BODY_FACES)
	fonts = { body = body, strong = body and add_face(STRONG_FACES) }
end

-- Per-frame state

local fs, u, dt = FONT_SIZE, 1, 1 / 60 -- font size, interface scale, frame time
local body_font, strong_font
local reduce = false -- Windows' "Show animations" is off

local FLT_MAX = 3.402823466e38
local v1, v2, v3, out = ffi.new("ImVec2"), ffi.new("ImVec2"), ffi.new("ImVec2"), ffi.new("ImVec2")
local f1, f3 = ffi.new("float[1]"), ffi.new("float[3]")

local function vec(v, x, y)
	v.x, v.y = x, y
	return v
end

-- Colours with the style alpha applied, so content fades with the menu and reveals.
local function col(c, alpha)
	return C.igGetColorU32_U32(c, alpha or 1)
end

local function cursor()
	C.igGetCursorScreenPos(out)
	return floor(out.x), floor(out.y)
end

local function set_cursor(x, y)
	C.igSetCursorScreenPos(vec(v1, x, y))
end

local function avail_x()
	C.igGetContentRegionAvail(out)
	return out.x
end

local function dummy(w, h)
	C.igDummy(vec(v1, w, h))
end

local function window_rect()
	C.igGetWindowPos(out)
	local x, y = out.x, out.y
	C.igGetWindowSize(out)
	return x, y, x + out.x, y + out.y
end

local function hand()
	C.igSetMouseCursor(ui.MouseCursor.Hand)
end

local function text_size(font, size, text, wrap)
	C.ImFont_CalcTextSizeA(out, font, size, FLT_MAX, wrap or 0, text, nil, nil)
	return out.x, out.y
end

local function text_w(font, size, text)
	C.ImFont_CalcTextSizeA(out, font, size, FLT_MAX, 0, text, nil, nil)
	return out.x
end

local function draw_text(dl, font, size, x, y, color, text, wrap)
	C.ImDrawList_AddText_FontPtr(dl, font, size, vec(v1, floor(x), floor(y)), color, text, nil, wrap or 0, nil)
end

local function centered(dl, font, size, cx, y, color, text)
	draw_text(dl, font, size, cx - text_w(font, size, text) * 0.5, y, color, text)
end

local function fill(dl, x1, y1, x2, y2, color, rounding)
	C.ImDrawList_AddRectFilled(dl, vec(v1, x1, y1), vec(v2, x2, y2), color, rounding or 0, 0)
end

local function outline(dl, x1, y1, x2, y2, color, rounding, thickness)
	C.ImDrawList_AddRect(dl, vec(v1, x1, y1), vec(v2, x2, y2), color, rounding or 0, 0, thickness or 1)
end

local function line(dl, x1, y1, x2, y2, color, thickness)
	C.ImDrawList_AddLine(dl, vec(v1, x1, y1), vec(v2, x2, y2), color, thickness or 1)
end

local function circle(dl, x, y, r, color)
	C.ImDrawList_AddCircleFilled(dl, vec(v1, x, y), r, color, 0)
end

local function push_clip(dl, x1, y1, x2, y2)
	C.ImDrawList_PushClipRect(dl, vec(v1, x1, y1), vec(v2, x2, y2), true)
end

local function push_var(idx, a, b)
	if b then
		C.igPushStyleVar_Vec2(idx, vec(v1, a, b))
	else
		C.igPushStyleVar_Float(idx, a)
	end
end

local function style_alpha()
	return C.igGetStyle().Alpha
end

-- Sizes follow the font, as in Wolper.
local function frame_height()
	return C.igGetFrameHeight()
end

local function small_size()
	return round(fs * 0.86)
end

local function row_gap()
	return round(fs * 1.2)
end

local function info_diameter()
	return round(fs * 0.9)
end

local function info_gap()
	return round(fs * 0.4)
end

local function switch_width()
	return round(frame_height() * 1.72)
end

local function prose_width(available)
	return max(1, min(available, fs * 46))
end

-- Motion: eases and critically damped springs that settle without overshooting.

local function update_reduce_motion()
end

do
	-- SPI_GETCLIENTAREAANIMATION through user32, which Wine provides too.
	pcall(ffi.cdef, "int __stdcall SystemParametersInfoW(unsigned int, unsigned int, void*, unsigned int);")
	local ok, spi = pcall(function()
		return ffi.C.SystemParametersInfoW
	end)
	if ok then
		local value = ffi.new("int[1]")
		local checked = -1e9
		-- The setting rarely changes, so it is read every few seconds.
		update_reduce_motion = function()
			local now = C.igGetTime()
			if now - checked >= 3 then
				checked = now
				value[0] = 1
				reduce = spi(0x1042, 0, value, 0) ~= 0 and value[0] == 0
			end
		end
	end
end

local smooth = {}

-- Exponential ease toward the target; starts at the target.
local function smooth_to(id, target, speed)
	local v = smooth[id]
	if v == nil then
		smooth[id] = target
		return target
	end
	v = v + (target - v) * clamp01(speed * dt)
	smooth[id] = v
	return v
end

-- smooth_to for anything that moves; cuts to the target under reduced motion.
local function slide_to(id, target, speed)
	local v = smooth_to(id, target, speed)
	return reduce and target or v
end

-- Closed-form critically damped step; `response` is roughly the seconds to settle.
local function spring(value, velocity, target, response)
	local omega = 6.28318530718 / max(response, 0.01)
	local offset = value - target
	local drive = velocity + omega * offset
	local decay = math.exp(-omega * dt)
	return target + (offset + drive * dt) * decay, (velocity - omega * drive * dt) * decay
end

local presses = {}

-- Press feedback: a squash while held that settles back to 1 without ringing.
local function press_scale(id, active)
	local s = presses[id]
	if not s then
		presses[id] = { 1, 0 }
		return 1
	end
	s[2] = s[2] + (((active and 0.96 or 1) - s[1]) * 420 - s[2] * 41) * dt
	s[1] = s[1] + s[2] * dt
	if s[1] > 1 then
		s[1], s[2] = 1, 0
	end
	return s[1]
end

local appears = {}

-- Rises from 0 to 1 each time something shows again after a frame without it.
local function appear(id, speed)
	local s = appears[id]
	if not s then
		s = { frame = -2, value = 0 }
		appears[id] = s
	end
	local frame = C.igGetFrameCount()
	if s.frame ~= frame then
		if s.frame ~= frame - 1 then
			s.value = 0
		end
		s.value = s.value + (1 - s.value) * clamp01(speed * dt)
		if s.value > 0.995 then
			s.value = 1
		end
		s.frame = frame
	end
	return s.value
end

local function draw_shadow(dl, x1, y1, x2, y2, rounding, strength)
	-- Stacked translucent shapes, each a little larger and lower, add up to a
	-- shadow that is darkest near the edge and falls toward the bottom.
	for layer = 6, 1, -1 do
		local spread = layer * 3 * u
		local alpha = strength * (1 - (layer - 1) / 6) / 6
		fill(dl, x1 - spread, y1 - spread * 0.5, x2 + spread, y2 + spread * 1.5, col(P.black, alpha), rounding + spread)
	end
end

-- Tooltips for the item just drawn; they fade in when they first show.
local function tooltip(text)
	if not text or not C.igIsItemHovered(ui.HoveredFlags.ForTooltip) then
		return
	end
	push_var(Var.Alpha, style_alpha() * appear("tooltip", 22))
	push_var(Var.WindowPadding, round(11 * u), round(7 * u))
	push_var(Var.PopupRounding, 8 * u)
	if C.igBeginTooltip() then
		C.igPushTextWrapPos(fs * 24)
		C.igTextUnformatted(text, nil)
		C.igPopTextWrapPos()
		C.igEndTooltip()
	end
	C.igPopStyleVar(3)
end

-- A small "?" that shows `text` on hover. It sits on top of its row without
-- taking layout space.
local function info_bubble(id, text, cx, cy)
	local x, y = cursor()
	local r = info_diameter() * 0.5
	set_cursor(cx - r, cy - r)
	C.igInvisibleButton(id, vec(v1, r * 2, r * 2), 0)
	local hovered = C.igIsItemHovered(ui.HoveredFlags.AllowWhenDisabled)
	local dl = C.igGetWindowDrawList()
	circle(dl, cx, cy, r, col(hovered and P.fill_hover or P.fill))
	local size = round(r * 2 * 0.78)
	centered(dl, strong_font, size, cx, floor(cy - size * 0.5), col(hovered and P.text or P.text_muted), "?")
	if hovered then
		hand()
	end
	tooltip(text)
	set_cursor(x, y)
end

-- Window

local presence = 0 -- how far the menu has faded in
local untitled = 0
local MENU_FLAGS = bor(ui.WindowFlags.NoTitleBar, ui.WindowFlags.NoCollapse, ui.WindowFlags.NoScrollbar, ui.WindowFlags.NoScrollWithMouse)

-- Lists of one window share a control column: sliders, segmented controls
-- and keys start and end at the same place in every row, sized by the widest
-- of them the frame before. A control too wide to sit beside its label puts
-- all of them under their labels from the next frame on.
local column = { width = 0, widest = 0, stacked = false, too_wide = false, stacked_width = 0, stacked_widest = 0 }

local function start_column_frame()
	column.width, column.widest = column.widest, 0
	column.stacked, column.too_wide = column.too_wide, false
	column.stacked_width, column.stacked_widest = column.stacked_widest, 0
end

-- Sizes at the 17 px font; they scale with it.
local THEME_SIZES = {
	{ Var.WindowPadding, 22, 18 },
	{ Var.WindowRounding, 12 },
	{ Var.ChildRounding, 10 },
	{ Var.PopupRounding, 10 },
	{ Var.FrameRounding, 7 },
	{ Var.FramePadding, 10, 6 },
	{ Var.ItemSpacing, 10, 8 },
	{ Var.ItemInnerSpacing, 8, 6 },
	{ Var.GrabRounding, 6 },
	{ Var.GrabMinSize, 12 },
	{ Var.ScrollbarSize, 10 },
	{ Var.ScrollbarRounding, 6 },
}
local THEME_BORDERS = { Var.WindowBorderSize, 1, Var.ChildBorderSize, 0, Var.PopupBorderSize, 1, Var.FrameBorderSize, 0 }

-- Returns how many style vars it pushed.
local function push_theme(alpha)
	for i = 1, #THEME, 2 do
		C.igPushStyleColor_U32(THEME[i], THEME[i + 1])
	end
	push_var(Var.Alpha, alpha)
	for _, size in ipairs(THEME_SIZES) do
		push_var(size[1], round(size[2] * u), size[3] and round(size[3] * u))
	end
	for i = 1, #THEME_BORDERS, 2 do
		push_var(THEME_BORDERS[i], THEME_BORDERS[i + 1])
	end
	return 1 + #THEME_SIZES + #THEME_BORDERS / 2
end

-- The menu window, `width` font heights wide and as tall as its content. It
-- fades in when `open` turns on and out after it turns off; `draw` fills it.
-- Draw errors propagate to the runtime, whose ImGui error recovery unwinds.
function M.menu(id, open, width, draw)
	local delta = C.igGetIO().DeltaTime
	dt = delta < 0 and 0 or min(delta, 1 / 30)
	presence = presence + ((open and 1 or 0) - presence) * clamp01(dt * 18)
	if presence > 0.995 then
		presence = 1
	end
	if not open and presence < 0.01 then
		presence = 0
		return
	end
	update_reduce_motion()

	local pushed_font = fonts and fonts.body
	if pushed_font then
		C.igPushFont(pushed_font)
	end
	body_font = C.igGetFont()
	strong_font = fonts and fonts.strong or body_font
	fs = C.igGetFontSize()
	u = fs / FONT_SIZE
	untitled = 0
	start_column_frame()

	local vars = push_theme(style_alpha() * presence)
	local io = C.igGetIO()
	C.igSetNextWindowPos(vec(v1, io.DisplaySize.x * 0.5, io.DisplaySize.y * 0.5), ui.Cond.FirstUseEver, vec(v2, 0.5, 0.5))
	C.igSetNextWindowSize(vec(v1, round(width * fs), 0), ui.Cond.Always)
	-- While it fades out after closing, the pointer already belongs to the game.
	if C.igBegin(id, nil, open and MENU_FLAGS or bor(MENU_FLAGS, ui.WindowFlags.NoInputs)) then
		local x1, y1, x2, y2 = window_rect()
		draw_shadow(C.igGetBackgroundDrawList_Nil(), x1, y1, x2, y2, 12 * u, 0.6)
		draw()
	end
	C.igEnd()
	C.igPopStyleVar(vars)
	C.igPopStyleColor(#THEME / 2)
	if pushed_font then
		C.igPopFont()
	end
end

local function close_button(size)
	local x, y = cursor()
	local id = C.igGetID_Str("##close")
	local pressed = C.igInvisibleButton("##close", vec(v1, size, size), 0)
	local hovered, active = C.igIsItemHovered(0), C.igIsItemActive()
	if hovered then
		hand()
	end
	tooltip("Close the menu")
	local dl = C.igGetWindowDrawList()
	local r = size * 0.5 * press_scale(id, active)
	local cx, cy = x + size * 0.5, y + size * 0.5
	circle(dl, cx, cy, r, col(active and P.raised or hovered and P.fill_hover or P.fill))
	local arm = r * 0.32
	local glyph = col(hovered and P.text or P.icon_idle)
	line(dl, cx - arm, cy - arm, cx + arm, cy + arm, glyph, 1.7)
	line(dl, cx - arm, cy + arm, cx + arm, cy - arm, glyph, 1.7)
	return pressed
end

-- The page's large bold title, a few words about it, and the close button.
-- Returns true when the close button was clicked.
function M.page_header(title, subtitle)
	local title_size = round(fs * 1.75)
	local button = round(28 * u)
	local line_height = max(round(title_size * 1.2), button)
	local width = avail_x()
	local x, y = cursor()
	local dl = C.igGetWindowDrawList()
	draw_text(dl, strong_font, title_size, x, y + (line_height - title_size) * 0.5, col(P.text), title)
	dummy(width, line_height)
	local after_x, after_y = cursor()
	set_cursor(x + width - button, y + floor((line_height - button) * 0.5))
	local closed = close_button(button)
	set_cursor(after_x, after_y)
	if subtitle then
		local sub_y = floor(after_y - C.igGetStyle().ItemSpacing.y + 2)
		set_cursor(after_x, sub_y)
		local wrap = prose_width(width)
		draw_text(dl, body_font, fs, after_x, sub_y, col(P.text_muted), subtitle, wrap)
		local _, height = text_size(body_font, fs, subtitle, wrap)
		dummy(width, height)
	end
	dummy(0, round(4 * u))
	return closed
end

-- Sections: rounded lists of rows separated by hairlines. The list is drawn
-- behind its rows once their height is known (Wolper uses auto-sizing child
-- windows, which skip their first frame and would throw off the menu's
-- first measurement).

local section = { active = false, rows = 0, x1 = 0, y1 = 0, x2 = 0, width = 0 }
local CARD_PADDING = 16
local REVEAL_INDENT = 22

-- Room left for a row's content: inside the list, up to its right padding.
local function row_avail()
	if not section.active then
		return avail_x()
	end
	C.igGetCursorScreenPos(out)
	return section.x2 - round(CARD_PADDING * u) - out.x
end

local function group_title(text, info)
	local size = small_size()
	dummy(0, round(fs * 0.7))
	local x, y = cursor()
	local inset = round(CARD_PADDING * u)
	local width = text_w(strong_font, size, text)
	draw_text(C.igGetWindowDrawList(), strong_font, size, x + inset, y, col(P.text_muted), text)
	dummy(inset + width, size)
	if info then
		info_bubble(text .. "##info", info, floor(x + inset + width + info_gap() + info_diameter() * 0.5), floor(y + size * 0.5) + 0.5)
	end
end

-- A list with an optional sentence-case title above it and an optional "?"
-- after the title for a note about the whole list.
function M.begin_section(title, info)
	if title then
		group_title(title, info)
		C.igPushID_Str(title)
	else
		untitled = untitled + 1
		C.igPushID_Int(untitled)
	end
	local x, y = cursor()
	local padding = round(CARD_PADDING * u)
	section.active, section.rows = true, 0
	section.x1, section.y1, section.x2 = x, y, x + floor(avail_x())
	section.width = section.x2 - x - padding * 2
	local dl = C.igGetWindowDrawList()
	C.ImDrawList_ChannelsSplit(dl, 2)
	C.ImDrawList_ChannelsSetCurrent(dl, 1)
	C.igIndent(padding)
	push_var(Var.ItemSpacing, C.igGetStyle().ItemSpacing.x, 0)
end

function M.end_section()
	C.igPopStyleVar(1)
	C.igUnindent(round(CARD_PADDING * u))
	local _, y2 = cursor()
	local x1, y1, x2 = section.x1, section.y1, section.x2
	local dl = C.igGetWindowDrawList()
	C.ImDrawList_ChannelsSetCurrent(dl, 0)
	fill(dl, x1, y1, x2, y2, col(P.box), 10 * u)
	-- The light rim that lifts the list off the page.
	outline(dl, x1 + 0.5, y1 + 0.5, x2 - 0.5, y2 - 0.5, col(P.rim), 10 * u, 1)
	C.ImDrawList_ChannelsMerge(dl)
	section.active = false
	C.igPopID()
	-- The page's item spacing after the list.
	dummy(0, 0)
end

-- Dependent options, indented under the option they depend on. They exist
-- only while `open` and fade in at full height, so nothing below slides.
function M.begin_reveal(id, open)
	C.igPushID_Str(id)
	local fade = smooth_to(C.igGetID_Str("##reveal"), open and 1 or 0, 14)
	if not open then
		C.igPopID()
		return false
	end
	push_var(Var.Alpha, style_alpha() * fade)
	C.igIndent(REVEAL_INDENT * u)
	return true
end

function M.end_reveal()
	C.igUnindent(REVEAL_INDENT * u)
	C.igPopStyleVar(1)
	C.igPopID()
end

-- Rows

-- Width of the shared column for a control that needs `natural` pixels, or 0
-- when the control goes under its label. Labels keep at least half the list.
local function control_column(natural)
	local list = section.width
	local limit = min(row_avail() - fs * 9 - row_gap(), floor(list * 0.5))
	if natural > limit then
		column.too_wide = true
		return 0
	end
	if column.stacked then
		return 0
	end
	column.widest = max(column.widest, natural)
	local base = round(min(max(list * 0.38, fs * 11), fs * 17))
	return floor(min(max(natural, base, column.width), limit))
end

local row = { x = 0, y = 0, w = 0, h = 0, help = nil, info_x = 0, info_y = 0 }

-- A hairline above every row after the first, from the row's text to the list's edge.
local function row_divider(x, y)
	if not section.active then
		return
	end
	section.rows = section.rows + 1
	if section.rows > 1 then
		line(C.igGetWindowDrawList(), x, y + 0.5, section.x2 - round(CARD_PADDING * u * 0.5), y + 0.5, col(P.divider), 1)
	end
end

-- Lays out a row and draws its label. Returns where the control goes, which
-- is under the label when `stacked`.
local function layout_row(label, help, control_w, control_h, stacked)
	local x, y = cursor()
	local width = max(1, row_avail())
	local padding = round(fs * 0.62)
	local text_width = max(1, (stacked or control_w <= 0) and width or width - control_w - row_gap())
	local wrap = help and max(1, text_width - info_diameter() - info_gap()) or text_width
	local label_w, label_h = text_size(body_font, fs, label, wrap)
	local h, ty, cx, cy
	if stacked then
		local gap = round(padding * 0.8)
		h = padding + label_h + gap + control_h + padding
		ty, cx, cy = y + padding, x, y + padding + label_h + gap
	else
		h = round(max(fs * 2.6, max(label_h, control_h) + padding * 2))
		ty, cx, cy = y + (h - label_h) * 0.5, x + width - control_w, y + (h - control_h) * 0.5
	end
	row_divider(x, y)
	row.x, row.y, row.w, row.h, row.help = x, y, width, h, help
	if help then
		row.info_x = floor(x + label_w + info_gap() + info_diameter() * 0.5)
		row.info_y = floor(ty + fs * 0.5) + 0.5
	end
	draw_text(C.igGetWindowDrawList(), body_font, fs, x, ty, col(P.text), label, wrap)
	cx, cy = floor(cx), floor(cy)
	set_cursor(cx, cy)
	return cx, cy
end

-- Adds the row's "?" and claims the row's space.
local function finish_row()
	if row.help then
		info_bubble("##info", row.help, row.info_x, row.info_y)
	end
	set_cursor(row.x, row.y)
	dummy(row.w, row.h)
end

-- Switch: the knob travels on a spring and stretches toward its destination while held.

local switches = {}

local function draw_switch(id, on, x, y, hovered, held)
	local target = on and 1 or 0
	local m = switches[id]
	if not m then
		m = { pos = target, vel = 0, stretch = 0 }
		switches[id] = m
	elseif reduce then
		m.pos, m.vel = target, 0
	else
		m.pos, m.vel = spring(m.pos, m.vel, target, 0.24)
		m.pos = clamp01(m.pos)
	end
	m.stretch = m.stretch + ((held and not reduce and 1 or 0) - m.stretch) * clamp01(dt * 22)

	local h, w = frame_height(), switch_width()
	local dl = C.igGetWindowDrawList()
	local track = mix(P.track_off, accent, m.pos)
	if hovered then
		track = mix(track, P.white, 0.07)
	end
	fill(dl, x, y, x + w, y + h, col(track), h * 0.5)
	local inset = 2.5 * u
	local radius = h * 0.5 - inset
	local extra = m.stretch * h * 0.3
	local center = x + inset + radius + (w - (inset + radius) * 2) * m.pos
	local left, right = center - radius - extra * m.pos, center + radius + extra * (1 - m.pos)
	local cy = y + h * 0.5
	fill(dl, left, cy - radius + 1, right, cy + radius + 1, col(P.knob_shadow), radius)
	fill(dl, left, cy - radius, right, cy + radius, col(P.knob), radius)
end

-- A row with a switch; the whole row toggles it. Returns value, changed.
function M.switch_row(label, value, help)
	C.igPushID_Str(label)
	local x, y = layout_row(label, help, switch_width(), frame_height(), false)
	set_cursor(row.x, row.y)
	local id = C.igGetID_Str("##row")
	-- The row's "?" sits on top and takes the pointer from it.
	C.igSetNextItemAllowOverlap()
	local pressed = C.igInvisibleButton("##row", vec(v1, row.w, row.h), 0)
	local hovered, held = C.igIsItemHovered(0), C.igIsItemActive()
	if hovered then
		hand()
	end
	if pressed then
		value = not value
	end
	draw_switch(id, value, x, y, hovered, held)
	finish_row()
	C.igPopID()
	return value, pressed
end

-- Slider: a rail filled with the accent up to a round knob, the value at the end.
-- Returns value, changed.
local SLIDER_FLAGS = bor(ui.SliderFlags.NoInput, ui.SliderFlags.AlwaysClamp)
local SLIDER_HIDDEN = { Col.FrameBg, Col.FrameBgHovered, Col.FrameBgActive, Col.SliderGrab, Col.SliderGrabActive }

function M.slider_row(label, value, minimum, maximum, format, help)
	C.igPushID_Str(label)
	local text = format:format(value)
	-- Values get one width unless they need more, so the tracks of a list end together.
	local value_w = math.ceil(max(text_w(body_font, fs, text), text_w(body_font, fs, format:format(minimum)), text_w(body_font, fs, format:format(maximum)), round(fs * 3.8)))
	local gap = round(fs * 0.8)
	local width = control_column(fs * 8 + gap + value_w)
	local stacked = width <= 0
	local slider_w = (stacked and row_avail() or width) - gap - value_w
	local knob = round(fs * 0.6)
	local slider_h = max(knob * 2 + 4, fs)
	local x, y = layout_row(label, help, slider_w + gap + value_w, slider_h, stacked)

	C.igSetNextItemWidth(slider_w)
	push_var(Var.FramePadding, C.igGetStyle().FramePadding.x, (slider_h - fs) * 0.5)
	push_var(Var.GrabMinSize, knob * 2)
	for _, idx in ipairs(SLIDER_HIDDEN) do
		C.igPushStyleColor_U32(idx, P.none)
	end
	f1[0] = value
	local changed = C.igSliderFloat("##slider", f1, minimum, maximum, "", SLIDER_FLAGS)
	local hovered, active = C.igIsItemHovered(0), C.igIsItemActive()
	C.igPopStyleColor(#SLIDER_HIDDEN)
	C.igPopStyleVar(2)
	if changed then
		value = f1[0]
	end
	if hovered then
		hand()
	end

	-- ImGui keeps 2 px between the frame and the grab's travel.
	local start_x, end_x = x + 2 + knob, x + slider_w - 2 - knob
	local cy = floor(y + slider_h * 0.5)
	local knob_x = round(start_x + (end_x - start_x) * clamp01(maximum > minimum and (value - minimum) / (maximum - minimum) or 0))
	local dl = C.igGetWindowDrawList()
	local rail = 4 * u
	fill(dl, x + 2, cy - rail * 0.5, x + slider_w - 2, cy + rail * 0.5, col(P.track_off), rail * 0.5)
	fill(dl, x + 2, cy - rail * 0.5, knob_x, cy + rail * 0.5, col(accent), rail * 0.5)
	-- Holding the knob deepens its shadow, as if lifted under the pointer.
	circle(dl, knob_x, cy + 1, knob + (active and 1.5 or 0.5), col(active and rgba(0, 0, 0, 110) or P.knob_shadow))
	circle(dl, knob_x, cy, knob, col((hovered or active) and P.white or P.knob))
	if changed then
		text = format:format(value)
	end
	draw_text(dl, body_font, fs, x + slider_w + gap + value_w - text_w(body_font, fs, text), cy - fs * 0.5, col(active and P.text or P.text_muted), text)
	finish_row()
	C.igPopID()
	return value, changed
end

-- Segmented control: the chosen segment is a raised neutral thumb that
-- slides between positions.

local function segmented_width(labels)
	local padding = round(fs * 0.95)
	local widest = 0
	for i = 1, #labels do
		widest = max(widest, text_w(strong_font, fs, labels[i]) + padding * 2)
	end
	return round(widest * #labels) + 4
end

local function segmented(labels, index, width, tips, enabled)
	local count = #labels
	local h = frame_height()
	local inset = 2
	local segment_w = (width - inset * 2) / count
	local rounding = 8 * u
	local x, y = cursor()
	local dl = C.igGetWindowDrawList()
	fill(dl, x, y, x + width, y + h, col(P.fill), rounding)

	local slide = slide_to(C.igGetID_Str("##slide"), index - 1, 20)
	-- Thin dividers between neighbouring segments the thumb is not on.
	for i = 1, count - 1 do
		local visibility = clamp01(min(abs(slide - i), abs(slide - i + 1)) * 2 - 0.2)
		if visibility > 0 then
			local dx = floor(x + inset + segment_w * i) + 0.5
			line(dl, dx, y + h * 0.28, dx, y + h - h * 0.28, col(P.border_strong, visibility * 0.7), 1)
		end
	end
	local thumb_x = x + inset + slide * segment_w
	fill(dl, thumb_x, y + inset + 1, thumb_x + segment_w, y + h - inset + 1, col(P.thumb_shadow), rounding - inset)
	fill(dl, thumb_x, y + inset, thumb_x + segment_w, y + h - inset, col(P.raised), rounding - inset)

	local chosen, changed = index, false
	for i = 1, count do
		local sx = x + inset + segment_w * (i - 1)
		set_cursor(sx, y)
		C.igPushID_Int(i)
		local pressed = C.igInvisibleButton("##segment", vec(v1, segment_w, h), 0)
		local hovered = C.igIsItemHovered(ui.HoveredFlags.AllowWhenDisabled)
		local on = not enabled or enabled[i]
		if hovered and on and i ~= index then
			hand()
		end
		tooltip(tips and tips[i])
		if pressed and on and i ~= index then
			chosen, changed = i, true
		end
		local covered = clamp01(1 - abs(slide - (i - 1)))
		local label = labels[i]
		local tx = floor(max(sx + 4, sx + (segment_w - text_w(strong_font, fs, label)) * 0.5))
		local color = on and col(mix(hovered and P.text or P.text_muted, P.text, covered)) or col(P.text_muted, 0.5)
		push_clip(dl, sx + 2, y, sx + segment_w - 2, y + h)
		draw_text(dl, covered > 0.5 and strong_font or body_font, fs, tx, y + h * 0.5 - fs * 0.5, color, label)
		C.ImDrawList_PopClipRect(dl)
		C.igPopID()
	end
	set_cursor(x, y)
	dummy(width, h)
	return chosen, changed
end

-- A row with a segmented choice. `index` is 1-based; `tips` optionally
-- explains each segment, and segments `enabled` marks false grey out but
-- keep their tip. Returns index, changed.
function M.segmented_row(label, labels, index, help, tips, enabled)
	C.igPushID_Str(label)
	local natural = segmented_width(labels)
	local available = row_avail()
	local width = control_column(natural)
	local stacked = width <= 0
	if stacked then
		-- Segmented controls under their labels share the widest one's width.
		width = max(natural, available * 0.6)
		column.stacked_widest = max(column.stacked_widest, width)
		width = min(available, max(width, column.stacked_width))
	end
	layout_row(label, help, width, frame_height(), stacked)
	local changed
	index, changed = segmented(labels, index, width, tips, enabled)
	finish_row()
	C.igPopID()
	return index, changed
end

-- A filled button without a border; it squashes slightly while pressed.
local function button(label, w, h)
	local x, y = cursor()
	local id = C.igGetID_Str(label)
	local pressed = C.igInvisibleButton(label, vec(v1, w, h), 0)
	local hovered, held = C.igIsItemHovered(0), C.igIsItemActive()
	if hovered then
		hand()
	end
	local s = press_scale(id, held)
	local cx, cy = x + w * 0.5, y + h * 0.5
	local dl = C.igGetWindowDrawList()
	fill(dl, cx - w * 0.5 * s, cy - h * 0.5 * s, cx + w * 0.5 * s, cy + h * 0.5 * s, col(held and P.raised or hovered and P.fill_hover or P.fill), 7 * u)
	centered(dl, body_font, fs, cx, cy - fs * 0.5, col(P.text), label)
	return pressed
end

local function button_width(label)
	return round(text_w(body_font, fs, label) + fs * 1.8)
end

-- An icon button that stays quiet until hovered, with a counter-clockwise
-- arrow. Drawn at `alpha` so it can fade; only clickable while `enabled`.
local function reset_button(x, y, size, enabled, alpha, tip)
	local hovered, active, pressed = false, false, false
	if enabled then
		set_cursor(x, y)
		pressed = C.igInvisibleButton("##reset", vec(v1, size, size), 0)
		hovered, active = C.igIsItemHovered(0), C.igIsItemActive()
		if hovered then
			hand()
		end
		tooltip(tip)
	end
	local dl = C.igGetWindowDrawList()
	if hovered or active then
		fill(dl, x, y, x + size, y + size, col(active and P.raised or P.fill_hover, alpha), 7 * u)
	end
	local glyph = col((hovered or active) and P.text or P.icon_idle, alpha)
	local cx, cy, r = x + size * 0.5, y + size * 0.5, size * 0.24
	-- From the top round to the upper left, with the head at the top pointing back.
	C.ImDrawList_PathArcTo(dl, vec(v1, cx, cy), r, -math.pi * 0.5, math.pi * 1.05, 0)
	C.ImDrawList_PathStroke(dl, glyph, 0, 1.7)
	C.ImDrawList_AddTriangleFilled(dl, vec(v1, cx - r * 0.65, cy - r), vec(v2, cx + r * 0.1, cy - r * 1.55), vec(v3, cx + r * 0.1, cy - r * 0.45), glyph)
	return pressed
end

local PICKER_FLAGS = bor(ui.ColorEditFlags.NoSidePreview, ui.ColorEditFlags.PickerHueBar)
local UNSET_LABEL = "Pick color"

-- A colour row. The well is always there: it shows the colour while one is
-- `set` and "Pick color" while the game's own is used, and opens a picker that
-- starts from `rgb` ({ r, g, b } in 0..1). A reset button beside it goes back
-- to the game's colour. An optional `action` button sits before them.
-- Returns rgb (a new table when picked), set, changed, action pressed.
function M.color_row(label, rgb, set, help, action, action_enabled, action_tip)
	C.igPushID_Str(label)
	local h = frame_height()
	local gap = round(fs * 0.45)
	local well_w = max(round(h * 1.6), button_width(UNSET_LABEL))
	local action_w = action and button_width(action) or 0
	local x, y = layout_row(label, help, (action and action_w + gap or 0) + h + gap + well_w, h, false)

	local acted = false
	if action then
		C.igBeginDisabled(not action_enabled)
		acted = button(action, action_w, h)
		C.igEndDisabled()
		tooltip(action_tip)
		x = x + action_w + gap
	end

	local changed = false
	-- Fades out after a reset instead of leaving a gap at once.
	local reset_alpha = smooth_to(C.igGetID_Str("##resetFade"), set and 1 or 0, 14)
	if reset_alpha > 0.01 and reset_button(x, y, h, set, reset_alpha, "Back to the game's color") then
		set, changed = false, true
	end
	x = x + h + gap

	set_cursor(x, y)
	local id = C.igGetID_Str("##swatch")
	local open = C.igInvisibleButton("##swatch", vec(v1, well_w, h), 0)
	local hovered, active = C.igIsItemHovered(0), C.igIsItemActive()
	if hovered then
		hand()
	end
	tooltip(not set and "The game's color is used until you pick one.")
	local s = press_scale(id, active)
	local cx, cy = x + well_w * 0.5, y + h * 0.5
	local x1, y1, x2, y2 = cx - well_w * 0.5 * s, cy - h * 0.5 * s, cx + well_w * 0.5 * s, cy + h * 0.5 * s
	local dl = C.igGetWindowDrawList()
	local rounding = 7 * u
	fill(dl, x1, y1, x2, y2, col((hovered or active) and P.fill_hover or P.fill), rounding)
	if set then
		fill(dl, x1 + 3, y1 + 3, x2 - 3, y2 - 3, col(rgba(round(rgb[1] * 255), round(rgb[2] * 255), round(rgb[3] * 255))), rounding - 2)
	else
		centered(dl, body_font, fs, cx, cy - fs * 0.5, col(P.text), UNSET_LABEL)
	end
	if open then
		C.igOpenPopup_Str("##picker", 0)
	end

	push_var(Var.WindowPadding, round(12 * u), round(12 * u))
	if C.igBeginPopup("##picker", 0) then
		C.igSetNextItemWidth(fs * 13)
		f3[0], f3[1], f3[2] = rgb[1], rgb[2], rgb[3]
		if C.igColorPicker3("##picker", f3, PICKER_FLAGS) then
			rgb, set, changed = { f3[0], f3[1], f3[2] }, true, true
		end
		C.igEndPopup()
	end
	C.igPopStyleVar(1)
	finish_row()
	C.igPopID()
	return rgb, set, changed, acted
end

-- Keys

local HOTKEY_WIDTH = 150

-- A keycap: a face over a darker lower edge; `sink` lowers the face while
-- pressed. Returns the face.
local function keycap_face(dl, x1, y1, x2, y2, face, sink)
	local depth, rounding = 3 * u, 7 * u
	fill(dl, x1, y1 + depth, x2, y2, col(P.key_edge), rounding)
	fill(dl, x1, y1 + sink, x2, y2 - depth + sink, col(face), rounding)
	return x1, y1 + sink, x2, y2 - depth + sink
end

-- A ring that breathes around something waiting for input.
local function listening_ring(dl, x1, y1, x2, y2)
	local pulse = 0.5 + 0.5 * math.sin(C.igGetTime() * 5)
	outline(dl, x1 - 2, y1 - 2, x2 + 2, y2 + 2, col(accent, 0.45 + 0.55 * pulse), 9 * u, 2)
end

-- A row with a keycap showing `key`; returns true when clicked. While
-- `listening`, the keycap asks for the new key.
function M.keybind_row(label, key, listening, help)
	C.igPushID_Str(label)
	local width = control_column(HOTKEY_WIDTH * u)
	local stacked = width <= 0
	if stacked then
		width = HOTKEY_WIDTH * u
	end
	local h = frame_height()
	local x, y = layout_row(label, help, width, h, stacked)
	local pressed = C.igInvisibleButton("##keycap", vec(v1, width, h), 0)
	local hovered, active = C.igIsItemHovered(0), C.igIsItemActive()
	if hovered then
		hand()
	end
	local dl = C.igGetWindowDrawList()
	local face = listening and mix(P.fill, accent, 0.25) or hovered and P.fill_hover or P.fill
	local fx1, fy1, fx2, fy2 = keycap_face(dl, x, y, x + width, y + h, face, active and 2 or 0)
	if listening then
		listening_ring(dl, fx1, fy1, fx2, fy2)
	end
	local text = listening and "Press a key..." or key
	push_clip(dl, fx1, fy1, fx2, fy2)
	draw_text(dl, strong_font, fs, max(fx1 + 8, (fx1 + fx2 - text_w(strong_font, fs, text)) * 0.5), (fy1 + fy2 - fs) * 0.5, col(listening and accent_bright or P.text), text)
	C.ImDrawList_PopClipRect(dl)
	finish_row()
	C.igPopID()
	return pressed
end

local SHEET_FLAGS = bor(ui.WindowFlags.NoDecoration, ui.WindowFlags.NoBackground, ui.WindowFlags.NoSavedSettings, ui.WindowFlags.NoMove, ui.WindowFlags.NoNav)

-- While a key is being recorded, a sheet in the middle of the screen asks for
-- it over a dimmed backdrop: the key it replaces, what it is for, and how to
-- back out. Returns true when Cancel was clicked.
function M.capture_sheet(action, key, hint)
	local io = C.igGetIO()
	local dw, dh = io.DisplaySize.x, io.DisplaySize.y
	local shown = appear("capture", 16)
	C.igSetNextWindowPos(vec(v1, 0, 0), 0, vec(v2, 0, 0))
	C.igSetNextWindowSize(vec(v1, dw, dh), 0)
	C.igSetNextWindowFocus()
	push_var(Var.Alpha, style_alpha() * shown)
	push_var(Var.WindowPadding, 0, 0)
	push_var(Var.WindowBorderSize, 0)
	local cancelled = false
	if C.igBegin("##WolperKeyCapture", nil, SHEET_FLAGS) then
		local dl = C.igGetWindowDrawList()
		fill(dl, 0, 0, dw, dh, col(P.scrim))

		local title = "Press a key"
		local padding = round(fs * 1.5)
		local title_size = round(fs * 1.3)
		local small = small_size()
		local key_h = round(fs * 2.4)
		local key_w = round(max(fs * 6, text_w(strong_font, fs, key) + fs * 2))
		local content = max(fs * 17, key_w, text_w(strong_font, title_size, title), text_w(body_font, small, hint), text_w(body_font, fs, action))
		local width = round(min(content + padding * 2, dw - 32))
		local button_h = frame_height()
		local title_gap, hint_gap, button_gap = round(fs * 1.1), round(fs * 0.55), round(fs * 1.4)
		local height = padding + key_h + title_gap + title_size + 4 + fs + hint_gap + small + button_gap + button_h + padding
		-- The sheet rises a little as it fades in.
		local lift = reduce and 0 or (1 - shown) * 12 * u
		local x, y = floor((dw - width) * 0.5), floor((dh - height) * 0.5 + lift)
		local rounding = 12 * u
		draw_shadow(dl, x, y, x + width, y + height, rounding, 0.55)
		fill(dl, x, y, x + width, y + height, col(P.popup), rounding)
		outline(dl, x + 0.5, y + 0.5, x + width - 0.5, y + height - 0.5, col(P.rim), rounding, 1)

		local cx = x + width * 0.5
		local ty = y + padding
		local kx = floor(cx - key_w * 0.5)
		local fx1, fy1, fx2, fy2 = keycap_face(dl, kx, ty, kx + key_w, ty + key_h, P.fill, 0)
		listening_ring(dl, fx1, fy1, fx2, fy2)
		centered(dl, strong_font, fs, cx, floor((fy1 + fy2 - fs) * 0.5), col(P.text_muted), key)
		ty = ty + key_h + title_gap
		centered(dl, strong_font, title_size, cx, ty, col(P.text), title)
		ty = ty + title_size
		centered(dl, body_font, fs, cx, ty + 4, col(P.text_muted), action)
		ty = ty + 4 + fs + hint_gap
		centered(dl, body_font, small, cx, ty, col(P.text_faint), hint)
		ty = ty + small + button_gap
		set_cursor(x + padding, ty)
		cancelled = button("Cancel", width - padding * 2, button_h)
	end
	C.igEnd()
	C.igPopStyleVar(3)
	return cancelled
end

return M
