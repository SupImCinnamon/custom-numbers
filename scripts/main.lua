-- Damage numbers animated exactly like healing numbers, stacked per target,
-- plus custom colours for body shots, headshots and healing, all set from an
-- ImGui menu.
--
-- UIWorldOverlay is native: AddDamage spawns a number, then every frame
-- UpdateDamage runs a scale function and a world-space physics function on it.
-- We swap those two for the healing equivalents and spawn damage numbers with
-- the healing lifetime, height, offsets and fade. Stacking folds each new hit
-- into the target's live number and retires the duplicate the game spawned.
--
-- The Win32 client inlines both scale functions into UpdateDamage and
-- UpdateHealing, so there the motion hook also applies the healing scale,
-- through the clip's own x/y scale setters.

local cfg = tempest.config({
	enabled = true,
	stack = true, -- body shots add up
	stack_headshots = "add", -- "each", "add" (a number of their own) or "body" (into the body shots' number)
	stack_style = "last", -- look of a number headshots joined: "first", "last" or "body"
	stack_window = 0.4,
	damage_color = "",
	headshot_color = "",
	healing_color = "",
	menu_key = "F7",
})
local active = cfg.enabled ~= false
local stack_body = cfg.stack ~= false
local stack_heads = cfg.stack_headshots
-- Older configs stored a boolean: whether headshots joined the body shot stack.
if type(stack_heads) == "boolean" then
	stack_heads = not stack_body and "each" or stack_heads and "body" or "add"
elseif stack_heads ~= "each" and (stack_heads ~= "body" or not stack_body) then
	stack_heads = "add"
end
local STACK_STYLES = { "first", "last", "body" }
local stack_style = cfg.stack_style
if stack_style ~= "first" and stack_style ~= "body" then
	stack_style = "last"
end
local stack_window = tonumber(cfg.stack_window) or 0.4

local function log(fmt, ...)
	tempest.log("[custom-numbers] " .. string.format(fmt, ...))
end

-- "#RRGGBB", "RRGGBB" or "0xRRGGBB"; anything else keeps the game's colour.
local function parse_color(s)
	if type(s) ~= "string" then
		return nil
	end
	local hex = s:match("^#?(%x%x%x%x%x%x)$") or s:match("^0[xX](%x%x%x%x%x%x)$")
	return hex and tonumber(hex, 16)
end

local function hex(color)
	return color and string.format("#%06X", color) or ""
end

local colors = {
	body = parse_color(cfg.damage_color),
	healing = parse_color(cfg.healing_color),
}
-- Older configs could set headshot_color to "body"; it now copies the body shot colour.
colors.head = cfg.headshot_color == "body" and colors.body or parse_color(cfg.headshot_color)

local X86 = tempest.status().arch == "x86"

local SIGS = X86 and {
	add_damage = "6A FF 68 ? ? ? ? 64 A1 00 00 00 00 50 81 EC B8 00 00 00 53 55 56 57 A1 ? ? ? ? 33 C4 50 8D 84 24 CC 00 00 00 64 A3 00 00 00 00 8B F9 8B 9C 24 DC 00 00 00 53 C7 44 24 20 00 00 00 00 E8 ? ? ? ? 85 C0 74 15 8B 10 8B C8 FF 92 FC 05 00 00 85 C0 74 07 B8 01 00 00 00 EB 02 33 C0 83 BF 94 01 00 00 00 0F 84 ? ? ? ? 8B AC 24 E4 00 00 00",
	add_healing = "6A FF 68 ? ? ? ? 64 A1 00 00 00 00 50 81 EC 8C 00 00 00 53 55 56 57 A1 ? ? ? ? 33 C4 50 8D 84 24 A0 00 00 00 64 A3 00 00 00 00 8B F1 C7 44 24 14 00 00 00 00 83 BE 94 01 00 00 00 0F 84 ? ? ? ? 8B 9C 24 B8 00 00 00 85 DB",
	damage_motion = "51 56 8B 74 24 0C 57 8B F9 C7 46 14 00 00 00 00 C7 46 18 00 00 00 00 F3 0F 10 87 F0 01 00 00",
	fade_out = "56 8B F1 8B 8E DC 00 00 00 85 C9 74 26 F3 0F 10 44 24 10 8B 01 83 EC 08 F3 0F 11 44 24 04 F3 0F 10 44 24 14 F3 0F 11 04 24 FF 74 24 10 FF 90 58 01 00 00",
	damage_frame = "83 EC 08 8B 89 60 01 00 00 53 8B 01 55 0F 57 C0 56 F3 0F 11 44 24 10 F3 0F 10 05",
	-- GFxObject's _xscale/_yscale setters (percent)
	set_xscale = "83 EC 2C 56 8B F1 F6 46 78 02 74 39 8B 8E C8 00 00 00",
	set_yscale = "83 EC 2C 56 8B F1 F6 46 78 02 74 3D 8B 8E C8 00 00 00 F3 0F 10 4C 24 34 F7 C1 00 01 00 00",
} or {
	add_damage = "48 8B C4 55 41 54 41 55 41 56 41 57 48 8D 68 98 48 81 EC 40 01 00 00 48 C7 45 E0 FE FF FF FF 48 89 58 10 48 89 70 18 48 89 78 20 0F 29 70 C8 0F 29 78 B8 44 0F 29 40 A8 44 0F 29 48 98 44 0F 29 50 88 45 8B F1 45 0F B6 E8 44 8B FA 48 8B D9 33 FF 89 7C 24 20 E8 ? ? ? ? 48 85 C0 74 14 4C 8B 00 48 8B C8 41 FF 90 F8 0B 00 00 85 C0 8D 47 01 75 02 8B C7 39 BB 00 02 00 00 0F 84 ? ? ? ? 45 85 F6",
	add_healing = "48 8B C4 55 57 41 57 48 8D 68 A1 48 81 EC 00 01 00 00 48 C7 45 27 FE FF FF FF 48 89 58 10 48 89 70 18 0F 29 70 D8 41 8B D9 48 8B F9 45 33 FF 44 89 7C 24 20 44 39 B9 00 02 00 00 0F 84 ? ? ? ?",
	damage_scale = "40 53 48 83 EC 30 F3 0F 10 81 5C 02 00 00 F3 0F 10 91 34 02 00 00 0F 29 74 24 20 0F 28 C8",
	damage_motion = "48 89 5C 24 08 57 48 83 EC 30 33 C0 48 8B DA 48 8B F9 48 89 42 14 F3 0F 10 81 5C 02 00 00 F3 0F 10 99 34 02 00 00 0F 28 C8",
	heal_scale = "40 53 48 83 EC 30 F3 0F 10 81 68 02 00 00 F3 0F 10 1D ? ? ? ? 0F 29 74 24 20 0F 28 D0",
	fade_out = "48 89 5C 24 08 57 48 83 EC 20 48 8B D9 48 8B 89 0C 01 00 00 48 8B FA 48 85 C9 74 09 48 8B 01 FF 90 B0 02 00 00",
	-- Anim frame for a damage value: how far it is above the local weapon's base damage
	damage_frame = "48 8B C4 48 89 58 08 48 89 68 10 48 89 70 18 48 89 78 20 41 56 48 83 EC 70 48 8B 89 B4 01 00 00 0F 29 70 E8 0F 29 78 D8",
}

-- The signatures bake these offsets into their instructions, so the reflected
-- layout has to agree before anything is written.
local P = X86 and {
	m_nMaxDamageTicksPerDevice = 0x198,
	m_fDamageMaxWorldOffset = 0x1dc,
	m_fDamageMaxInitialSpeed = 0x1e4,
	m_fDamageVerticalOffset = 0x1ec,
	m_fDamageTimer = 0x1f0,
	m_fHealingSpeed = 0x1f4,
	m_fHealingBloom = 0x1f8,
	m_fHealingTimer = 0x1fc,
	m_fDamageNumbersOffsetScale = 0x208,
	m_DamageData = 0x23c,
	m_HealingData = 0x248,
} or {
	m_nMaxDamageTicksPerDevice = 0x204,
	m_fDamageMaxWorldOffset = 0x248,
	m_fDamageMaxInitialSpeed = 0x250,
	m_fDamageVerticalOffset = 0x258,
	m_fDamageTimer = 0x25c,
	m_fHealingSpeed = 0x260,
	m_fHealingBloom = 0x264,
	m_fHealingTimer = 0x268,
	m_fDamageNumbersOffsetScale = 0x274,
	m_DamageData = 0x2b8,
	m_HealingData = 0x2c8,
}

local PTR = X86 and 4 or 8
-- Win32 natives are thiscall (`this` in ECX, the rest on the stack); Win64 ignores this.
local CONV = "thiscall"
local CALL = { conv = CONV }

-- UIWorldOverlay.OverlayData, with PooledOverlayData's clips from +0x48
local ENTRY_SIZE = X86 and 0x60 or 0x74
local E_ROLL, E_SCALE, E_TIMER, E_ANIM_X, E_ANIM_Y = 0x08, 0x0c, 0x10, 0x14, 0x18
-- vWorldLoc: where the number is anchored in the world (UpdateDamage projects it each frame)
local E_WORLD = 0x24
local E_CLIP = 0x48
local E_ANIM, E_TEXT, E_TF = E_CLIP + PTR, E_CLIP + 2 * PTR, E_CLIP + 3 * PTR

-- AddDamage's last argument is the combat event type, which picks the Text
-- clip's frame (11 -> 3, 12 -> 4, 17 -> 5, 18 -> 7, else 1); 12 is the
-- headshot (seen in game: 1.5x damage, frame 4), 2 a body shot.
local HEADSHOT_EVENT, BODY_EVENT = 12, 2

-- AddHealing's constants
local HEAL_Z_OFFSET = 60
local HEAL_FADE_TIME = 0.5

-- A stacked number that keeps getting hit is held this many seconds into its animation.
local STACK_HOLD = 0.25
-- The per-weapon cap drops hits before they reach AddDamage, which would leave holes in a stack.
local NO_CAP = 0x3fffffff

local SPAWN_PARAMS = {
	P.m_fDamageMaxWorldOffset, P.m_fDamageMaxInitialSpeed, P.m_fDamageVerticalOffset,
	P.m_fDamageTimer, P.m_fDamageNumbersOffsetScale,
}

local function resolve()
	local addr = {}
	for name, sig in pairs(SIGS) do
		local hits = memory.scan(sig, 2)
		if #hits ~= 1 then
			return nil, string.format("signature %s matched %d times", name, #hits)
		end
		addr[name] = hits[1]
	end
	return addr
end

local addr, why = resolve()
if not addr then
	log("disabled: %s", why)
	return
end

-- Checked on the first live overlay, through plain property access. Object:prop
-- also names each property's inner type from a slot that only holds an object
-- for arrays/structs; on Wine that slot is garbage for ints and floats and the
-- lookup faults.
local PROBE = 4097 -- exact as both an int and a float
local function field_at(scene, overlay, name, off)
	local kind = name:sub(1, 3)
	if kind == "m_n" or kind == "m_f" then
		local read = kind == "m_n" and memory.read_i32 or memory.read_f32
		local write = kind == "m_n" and memory.write_i32 or memory.write_f32
		local was = read(overlay + off)
		write(overlay + off, PROBE)
		local ok, seen = pcall(function()
			return scene[name]
		end)
		write(overlay + off, was)
		return ok and seen == PROBE
	end
	local ok, at = pcall(function()
		return scene[name]:addr()
	end)
	return ok and at == overlay + off
end

local layout_ok
local function check_layout(overlay)
	if layout_ok == nil then
		local scene = tempest.object(overlay)
		local bad = not scene and "the overlay is not a live object" or nil
		for name, off in pairs(scene and P or {}) do
			if not field_at(scene, overlay, name, off) then
				bad = string.format("%s is not at 0x%x", name, off)
				break
			end
		end
		layout_ok = not bad
		if bad then
			log("disabled: %s", bad)
		end
	end
	return layout_ok
end

local function count(list)
	return memory.read_i32(list + PTR)
end

-- Spawning appends to the list, so a grown list means the last entry is the new number.
local function newest(list, before)
	local n = count(list)
	if n <= before then
		return nil
	end
	return memory.read_ptr(list) + (n - 1) * ENTRY_SIZE
end

local function find_entry(list, clip)
	local data = memory.read_ptr(list)
	for i = 0, count(list) - 1 do
		local entry = data + i * ENTRY_SIZE
		if memory.read_ptr(entry + E_CLIP) == clip then
			return entry
		end
	end
end

local function damage_color(headshot)
	if headshot then
		return colors.head
	end
	return colors.body
end

-- Text fields are pooled and reused, so remember each one's own colour to put
-- back once its custom colour is turned off.
local game_colors = {}

local function recolor(tf_ptr, color)
	if not color and not game_colors[tf_ptr] then
		return
	end
	local tf = tempest.object(tf_ptr)
	if not tf then
		return
	end
	if color then
		game_colors[tf_ptr] = game_colors[tf_ptr] or tf:GetInt("textColor")
		tf:SetInt("textColor", color)
	else
		tf:SetInt("textColor", game_colors[tf_ptr])
		game_colors[tf_ptr] = nil
	end
end

local fading_for -- overlay whose AddDamage is running

-- `event` replaces AddDamage's event type, which it only uses to pick the number's style.
local function spawn_damage(original, overlay, event)
	if not active then
		original(nil, nil, nil, nil, nil, event)
		return
	end
	local saved = {}
	for _, off in ipairs(SPAWN_PARAMS) do
		saved[off] = memory.read_f32(overlay + off)
	end
	memory.write_f32(overlay + P.m_fDamageTimer, memory.read_f32(overlay + P.m_fHealingTimer))
	memory.write_f32(overlay + P.m_fDamageVerticalOffset, HEAL_Z_OFFSET)
	memory.write_f32(overlay + P.m_fDamageMaxWorldOffset, 0)
	memory.write_f32(overlay + P.m_fDamageMaxInitialSpeed, 0)
	memory.write_f32(overlay + P.m_fDamageNumbersOffsetScale, 0)
	fading_for = overlay
	local ok, e = pcall(original, nil, nil, nil, nil, nil, event)
	fading_for = nil
	for off, v in pairs(saved) do
		memory.write_f32(overlay + off, v)
	end
	if not ok then
		error(e)
	end
end

-- Running totals by target and damage type; owners maps a stack's clip back to
-- its key, since pooled clips get reused once a number expires.
local stacks, owners, stack_overlay = {}, {}, nil

-- Each overlay's own cap, from before it was first lifted; `shared` outlives a
-- hot reload of this mod, which would otherwise only find NO_CAP there.
shared.damage_column_caps = shared.damage_column_caps or {}
local game_caps = shared.damage_column_caps

local function stacking()
	return stack_body or stack_heads ~= "each"
end

local function set_cap(overlay)
	local cap = memory.read_i32(overlay + P.m_nMaxDamageTicksPerDevice)
	if cap ~= NO_CAP then
		game_caps[overlay] = cap
	end
	local lift = stacking()
	if lift and cap ~= NO_CAP then
		memory.write_i32(overlay + P.m_nMaxDamageTicksPerDevice, NO_CAP)
	elseif not lift and cap == NO_CAP and game_caps[overlay] then
		memory.write_i32(overlay + P.m_nMaxDamageTicksPerDevice, game_caps[overlay])
	end
end

-- Folds the number AddDamage just spawned into the target's live stack; true when it did.
local function add_to_stack(overlay, entry, key, value, headshot)
	local s = stacks[key]
	local into = s and owners[s.clip] == key and find_entry(overlay + P.m_DamageData, s.clip)
	if not into then
		return false
	end
	local remaining = memory.read_f32(into + E_TIMER)
	if remaining <= 0 or s.last - remaining > stack_window then
		return false
	end

	local scene = tempest.object(overlay)
	s.total = s.total + value
	s.last = math.max(remaining, s.life - STACK_HOLD)
	if s.last > remaining then
		memory.write_f32(into + E_TIMER, s.last)
		local clip = tempest.object(s.clip)
		scene:CancelAnim(clip)
		clip:SetAlpha(100)
		scene:FadeOut(clip, HEAL_FADE_TIME, s.last - HEAL_FADE_TIME)
	end
	-- A merged stack keeps its first hit's look ("first"), or takes the latest hit's
	-- colour ("body", spawned in the body style) or colour and style ("last").
	-- Pooled numbers serve every hit type with one text field, so switching frames keeps it.
	if stack_style == "last" and headshot ~= s.headshot then
		local from = tempest.object(memory.read_ptr(entry + E_TEXT))
		local frame = from and from:GetInt("_currentframe")
		if frame and frame > 0 then
			tempest.object(s.text):GotoAndStopI(frame)
		end
	end
	tempest.object(s.tf):SetText(tostring(s.total))
	if stack_style ~= "first" then
		s.headshot = headshot
	end
	recolor(s.tf, damage_color(s.headshot))
	tempest.object(s.anim):GotoAndStopI(memory.call(addr.damage_frame, overlay, s.total, CALL))
	-- The duplicate spawned where the target is now; move the stack there so it follows a moving target.
	for i = 0, 8, 4 do
		memory.write_f32(into + E_WORLD + i, memory.read_f32(entry + E_WORLD + i))
	end

	-- The duplicate stays hidden until the next UpdateDamage expires it, which
	-- also releases its slot in the per-weapon count and returns the clip to the pool.
	local dup = tempest.object(memory.read_ptr(entry + E_CLIP))
	scene:CancelAnim(dup)
	dup:SetAlpha(0)
	memory.write_f32(entry + E_TIMER, 0)
	return true
end

local function add_damage(original, overlay, target, target_type, value, _, event)
	if not check_layout(overlay) then
		return
	end
	if overlay ~= stack_overlay then
		stacks, owners, stack_overlay = {}, {}, overlay
	end
	set_cap(overlay)
	local list = overlay + P.m_DamageData
	local before = count(list)
	-- The caller only fills the low byte of its slot
	event = event % 0x100
	local headshot = event == HEADSHOT_EVENT
	-- value <= 0 is the "immune" label, which never stacks
	local stackable = value > 0 and value < 0x80000000 and (headshot and stack_heads ~= "each" or not headshot and stack_body)
	local merged = stackable and headshot and stack_heads == "body"
	spawn_damage(original, overlay, (merged and stack_style == "body") and BODY_EVENT or nil)
	local entry = newest(list, before)
	if not entry then
		return
	end
	local clip = memory.read_ptr(entry + E_CLIP)
	owners[clip] = nil
	if stackable then
		local kind = merged and BODY_EVENT or event
		local key = string.format("%d:%d:%d", target, target_type, kind)
		if add_to_stack(overlay, entry, key, value, headshot) then
			return
		end
		local life = memory.read_f32(entry + E_TIMER)
		stacks[key] = {
			clip = clip,
			anim = memory.read_ptr(entry + E_ANIM),
			text = memory.read_ptr(entry + E_TEXT),
			tf = memory.read_ptr(entry + E_TF),
			headshot = headshot,
			total = value,
			life = life,
			last = life,
		}
		owners[clip] = key
	end
	recolor(memory.read_ptr(entry + E_TF), damage_color(headshot))
end--

local function add_healing(original, overlay)
	if not check_layout(overlay) then
		return
	end
	local list = overlay + P.m_HealingData
	local before = count(list)
	original()
	local entry = newest(list, before)
	if entry then
		recolor(memory.read_ptr(entry + E_TF), colors.healing)
	end
end

-- AddDamage's fade scales with the damage value; healing always fades over its last half second.
local function fade_out(original, scene)
	if fading_for ~= scene then
		return
	end
	local heal_timer = memory.read_f32(scene + P.m_fHealingTimer)
	original(nil, nil, memory.f32(HEAL_FADE_TIME), memory.f32(heal_timer - HEAL_FADE_TIME))
end

local function damage_scale(original, overlay, entry)
	if not active or not layout_ok then
		return
	end
	memory.call(addr.heal_scale, overlay, entry)
	return 0
end

-- The healing scale for Win32, where it only exists inline in UpdateHealing:
-- a bloom that settles back to full size over the number's life.
local function apply_heal_scale(overlay, entry, heal_timer)
	local t = (heal_timer - memory.read_f32(entry + E_TIMER)) / heal_timer
	local s = (1 - t * memory.read_f32(overlay + P.m_fHealingSpeed)) * memory.read_f32(overlay + P.m_fHealingBloom) + 100
	if s < 100 then
		s = (2 - t) * 50
	end
	s = s * memory.read_f32(entry + E_SCALE) * 0.9
	local clip = memory.read_ptr(entry + E_CLIP)
	memory.call(addr.set_xscale, clip, memory.f32(s), CALL)
	memory.call(addr.set_yscale, clip, memory.f32(s), CALL)
end

-- The arc UpdateHealing computes inline: up and out along fRoll, then settling back down.
local function damage_motion(original, overlay, entry)
	if not active or not layout_ok then
		return
	end
	local heal_timer = memory.read_f32(overlay + P.m_fHealingTimer)
	if heal_timer > 0 then
		if X86 then
			apply_heal_scale(overlay, entry, heal_timer)
		end
		local t = (heal_timer - memory.read_f32(entry + E_TIMER)) / heal_timer * 15
		memory.write_f32(entry + E_ANIM_X, t * memory.read_f32(entry + E_ROLL))
		memory.write_f32(entry + E_ANIM_Y, t * t * 0.75 - t * 10)
	end
	return 0
end

local hooks = {}
local ok, e = pcall(function()
	hooks[#hooks + 1] = memory.hook(addr.add_damage, add_damage, { args = 6, conv = CONV })
	hooks[#hooks + 1] = memory.hook(addr.add_healing, add_healing, { args = 4, conv = CONV })
	hooks[#hooks + 1] = memory.hook(addr.fade_out, fade_out, { args = { "ptr", "ptr", "f32", "f32" }, conv = CONV })
	if addr.damage_scale then
		hooks[#hooks + 1] = memory.hook(addr.damage_scale, damage_scale, { args = 2, conv = CONV })
	end
	hooks[#hooks + 1] = memory.hook(addr.damage_motion, damage_motion, { args = 2, conv = CONV })
end)
if not ok then
	for _, id in ipairs(hooks) do
		memory.unhook(id)
	end
	log("disabled: %s", tostring(e))
	return
end

-- Settings menu, in Wolper's look

local W = require("lib.wolper_ui")

local FALLBACK_KEY = "Insert" -- bound instead when the configured menu key cannot be
local MENU_WIDTH = 40 -- in font heights

local menu_open = false
local dirty = false
local listening = false -- waiting for a new menu key

local function set_menu(open)
	-- Opening only happens from a key press, outside a frame, where fonts can be added.
	if open then
		W.load_fonts()
	end
	menu_open = open
	listening = false
	ui.capture(open)
end

local function save()
	dirty = false
	cfg.enabled, cfg.stack, cfg.stack_window = active, stack_body, stack_window
	cfg.stack_headshots, cfg.stack_style = stack_heads, stack_style
	cfg.damage_color = hex(colors.body)
	cfg.headshot_color = hex(colors.head)
	cfg.healing_color = hex(colors.healing)
	tempest.save_config(cfg)
end

local menu_key_id

local function bind_menu_key(spec)
	local bound, id = pcall(tempest.on_key, spec, function()
		if not listening then
			set_menu(not menu_open)
		end
		return true
	end)
	if not bound then
		return false, id
	end
	if menu_key_id then
		tempest.off_key(menu_key_id)
	end
	menu_key_id = id
	return true
end

local bound, bind_err = bind_menu_key(cfg.menu_key)
if not bound then
	log("menu key %q not bound (%s); using %s", tostring(cfg.menu_key), tostring(bind_err), FALLBACK_KEY)
	cfg.menu_key = FALLBACK_KEY
	bound = bind_menu_key(FALLBACK_KEY)
end

-- ImGui key name -> Tempest key name, for rebinding the menu key.
local KEY_NAMES = {
	LeftArrow = "Left", RightArrow = "Right", UpArrow = "Up", DownArrow = "Down",
	GraveAccent = "Tilde", Equal = "Equals", Apostrophe = "Quote",
	KeypadMultiply = "Multiply", KeypadAdd = "Add", KeypadSubtract = "Subtract",
	KeypadDecimal = "Decimal", KeypadDivide = "Divide",
	MouseMiddle = "MouseMiddle", MouseX1 = "Mouse4", MouseX2 = "Mouse5",
}
for _, k in ipairs({
	"Insert", "Delete", "Home", "End", "PageUp", "PageDown", "Backspace", "Tab", "Enter", "Space",
	"Minus", "LeftBracket", "RightBracket", "Backslash", "Semicolon", "Comma", "Period", "Slash",
	"CapsLock", "NumLock", "ScrollLock", "Pause",
}) do
	KEY_NAMES[k] = k
end
for i = 1, 24 do
	KEY_NAMES["F" .. i] = "F" .. i
end
for i = 0, 9 do
	KEY_NAMES[tostring(i)] = tostring(i)
	KEY_NAMES["Keypad" .. i] = "NumPad" .. i
end
for c = 65, 90 do
	KEY_NAMES[string.char(c)] = string.char(c)
end

local function key_down(name)
	local k = ui.Key[name]
	return k ~= nil and ui.key_down(k)
end

local function pressed_key()
	for imgui_name, name in pairs(KEY_NAMES) do
		local k = ui.Key[imgui_name]
		if k and ui.key_pressed(k, false) then
			local parts = {}
			if key_down("LeftCtrl") or key_down("RightCtrl") then
				parts[#parts + 1] = "Ctrl"
			end
			if key_down("LeftShift") or key_down("RightShift") then
				parts[#parts + 1] = "Shift"
			end
			if key_down("LeftAlt") or key_down("RightAlt") then
				parts[#parts + 1] = "Alt"
			end
			parts[#parts + 1] = name
			return table.concat(parts, "+")
		end
	end
end

local function to_rgb(color)
	return { math.floor(color / 0x10000) % 256 / 255, math.floor(color / 0x100) % 256 / 255, color % 256 / 255 }
end

local function from_rgb(rgb)
	local function byte(v)
		return math.floor(math.max(0, math.min(1, v)) * 255 + 0.5)
	end
	return byte(rgb[1]) * 0x10000 + byte(rgb[2]) * 0x100 + byte(rgb[3])
end

-- Where each picker starts; it keeps the last colour after a reset.
local picked = {}
for _, kind in ipairs({ "body", "head", "healing" }) do
	picked[kind] = to_rgb(colors[kind] or 0xFFFFFF)
end

local ANIMATIONS = { "Default", "Legacy" }
local BODY_STACKS = { "Each", "Add up" }
local BODY_STACK_TIPS = {
	"Every body shot shows its own number.",
	"Body shots on a target add up into one number.",
}
local HEAD_STACK_MODES = { "each", "add", "body" }
local HEAD_STACKS = { "Each", "Add up", "With body" }
local HEAD_STACK_TIPS = {
	"Every headshot shows its own number.",
	"Headshots on a target add up into a number of their own.",
	"Headshots add to the body shots' number.",
}
-- While body shots show one by one there is no number to join.
local HEAD_STACK_TIPS_ALONE = { HEAD_STACK_TIPS[1], HEAD_STACK_TIPS[2], "Needs body shots to add up." }
local HEAD_STACK_ENABLED_ALONE = { true, true, false }
-- Short, so the shared control column keeps its width when this row appears.
local MERGED_STYLES = { "First", "Last", "Body" }
local MERGED_STYLE_TIPS = {
	"Styled and colored like its first hit.",
	"Styled and colored like its latest hit.",
	"In the body shot style, colored like its latest hit.",
}

-- Returns true when the row's action button was pressed.
local function color_row(label, kind, action, action_enabled, action_tip)
	local rgb, set, changed, acted = W.color_row(label, picked[kind], colors[kind] ~= nil, nil, action, action_enabled, action_tip)
	if changed then
		picked[kind] = rgb
		colors[kind] = set and from_rgb(rgb) or nil
		dirty = true
	end
	return acted
end

local function index_of(list, value)
	for i, v in ipairs(list) do
		if v == value then
			return i
		end
	end
end

local function draw_settings()
	if W.page_header("Custom Numbers") then
		set_menu(false)
	end

	W.begin_section()
	local choice, changed = W.segmented_row("Animation", ANIMATIONS, active and 2 or 1,
		"Legacy makes damage numbers rise and fade like healing numbers.")
	if changed then
		active, dirty = choice == 2, true
	end
	W.end_section()

	W.begin_section("Stacking")
	choice, changed = W.segmented_row("Body shots", BODY_STACKS, stack_body and 2 or 1, nil, BODY_STACK_TIPS)
	if changed then
		stack_body, dirty = choice == 2, true
		if not stack_body and stack_heads == "body" then
			stack_heads = "add"
		end
	end
	choice, changed = W.segmented_row("Headshots", HEAD_STACKS, index_of(HEAD_STACK_MODES, stack_heads), nil,
		stack_body and HEAD_STACK_TIPS or HEAD_STACK_TIPS_ALONE, not stack_body and HEAD_STACK_ENABLED_ALONE or nil)
	if changed then
		stack_heads, dirty = HEAD_STACK_MODES[choice], true
	end
	if W.begin_reveal("window", stacking()) then
		local window
		window, changed = W.slider_row("Combine hits within", stack_window, 0.05, 2, "%.2f s",
			"A hit that lands later than this after the one before starts a new number.")
		if changed then
			stack_window, dirty = window, true
		end
		W.end_reveal()
	end
	if W.begin_reveal("style", stack_heads == "body") then
		choice, changed = W.segmented_row("Total looks like", MERGED_STYLES, index_of(STACK_STYLES, stack_style), nil, MERGED_STYLE_TIPS)
		if changed then
			stack_style, dirty = STACK_STYLES[choice], true
		end
		W.end_reveal()
	end
	W.end_section()

	W.begin_section("Colors", "New numbers pick up changes.")
	color_row("Body shots", "body")
	local copy_tip = not colors.body and "Pick a body shot color first."
		or colors.head == colors.body and "Headshots already use the body shot color."
		or "Headshots take the body shot color."
	if color_row("Headshots", "head", "Use body color", colors.body ~= nil and colors.body ~= colors.head, copy_tip) then
		colors.head, picked.head, dirty = colors.body, picked.body, true
	end
	color_row("Healing", "healing")
	W.end_section()

	W.begin_section("Menu")
	if W.keybind_row("Menu key", cfg.menu_key, listening) then
		listening = true
	end
	W.end_section()

	if listening and W.capture_sheet("Menu key", cfg.menu_key, "Ctrl, Shift and Alt combinations work too. Esc cancels.") then
		listening = false
	end
end

local function poll_rebind()
	if ui.key_pressed(ui.Key.Escape, false) then
		listening = false
		return
	end
	local spec = pressed_key()
	if not spec then
		return
	end
	listening = false
	local rebound, why = bind_menu_key(spec)
	if rebound then
		cfg.menu_key = spec
		dirty = true
	else
		log("menu key %q not bound: %s", spec, tostring(why))
	end
end

ui.on_draw(function()
	if menu_open and listening then
		poll_rebind()
	end
	W.menu("Custom Numbers", menu_open, MENU_WIDTH, draw_settings)
	-- Sliders and pickers report a change every frame while dragged; write once they let go.
	if dirty and not ui.is_any_item_active() then
		save()
	end
end)

local function show(color)
	return color and hex(color) or "game"
end

local base = memory.base()
local found = {}
for name, a in pairs(addr) do
	found[#found + 1] = string.format("%s +0x%x", name, a - base)
end
table.sort(found)
log("hooks live (%s, %s), animation %s, stacking body shots %s and headshots %s within %.2fs, body %s, head %s, healing %s, menu key %s",
	X86 and "Win32" or "Win64", table.concat(found, ", "), active and "on" or "off",
	stack_body and "add" or "each", stack_heads, stack_window, show(colors.body),
	show(colors.head), show(colors.healing), bound and cfg.menu_key or "none")
