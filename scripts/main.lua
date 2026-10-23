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
	stack = true,
	stack_headshots = false,
	stack_style = "last", -- look of a merged stack: "first", "last" or "body"
	stack_window = 0.4,
	damage_color = "",
	headshot_color = "",
	healing_color = "",
	menu_key = "F7",
})
local active = cfg.enabled ~= false
local stacking = cfg.stack ~= false
local merge_heads = cfg.stack_headshots == true -- headshots join the body shot stack
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

-- headshot_color can also be "body": headshots then use the body shot colour.
local colors = {
	body = parse_color(cfg.damage_color),
	head = parse_color(cfg.headshot_color),
	healing = parse_color(cfg.healing_color),
}
local head_same = cfg.headshot_color == "body"

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
	if headshot and not head_same then
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

local function set_cap(overlay)
	local cap = memory.read_i32(overlay + P.m_nMaxDamageTicksPerDevice)
	if cap ~= NO_CAP then
		game_caps[overlay] = cap
	end
	if stacking and cap ~= NO_CAP then
		memory.write_i32(overlay + P.m_nMaxDamageTicksPerDevice, NO_CAP)
	elseif not stacking and cap == NO_CAP and game_caps[overlay] then
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
	local stackable = stacking and value > 0 and value < 0x80000000
	local merged = stackable and merge_heads and headshot
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

-- Settings menu

local FALLBACK_KEY = "Insert" -- bound instead when the configured menu key cannot be
local COMBO_WIDTH = 170

local menu_open = false
local dirty = false
local listening = false -- waiting for a new menu key

local function set_menu(open)
	menu_open = open
	listening = false
	ui.capture(open)
end

local function save()
	dirty = false
	cfg.enabled, cfg.stack, cfg.stack_window = active, stacking, stack_window
	cfg.stack_headshots, cfg.stack_style = merge_heads, stack_style
	cfg.damage_color = hex(colors.body)
	cfg.headshot_color = head_same and "body" or hex(colors.head)
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

-- What each picker shows, kept while its colour is off so switching back restores it.
local picked = {}
for _, kind in ipairs({ "body", "head", "healing" }) do
	picked[kind] = to_rgb(colors[kind] or 0xFFFFFF)
end

local function combo(label, index, items)
	ui.set_next_item_width(COMBO_WIDTH)
	return ui.combo(label, index, items)
end

local function swatch(kind)
	ui.same_line()
	local rgb, edited = ui.color_edit("##" .. kind, picked[kind], ui.ColorEditFlags.NoInputs)
	if edited then
		picked[kind] = rgb
		colors[kind] = from_rgb(rgb)
		dirty = true
	end
end

local COLOR_MODES = { "Default", "Custom" }
local HEAD_MODES = { "Default", "Same as body shots", "Custom" }

local function color_row(label, kind)
	local mode, changed = combo(label, colors[kind] and 2 or 1, COLOR_MODES)
	if changed then
		colors[kind] = mode == 2 and from_rgb(picked[kind]) or nil
		dirty = true
	end
	if colors[kind] then
		swatch(kind)
	end
end

local function headshot_row()
	local mode, changed = combo("Headshots", head_same and 2 or colors.head and 3 or 1, HEAD_MODES)
	if changed then
		head_same = mode == 2
		colors.head = mode == 3 and from_rgb(picked.head) or nil
		dirty = true
	end
	if colors.head then
		swatch("head")
	end
end

local function draw_settings()
	local choice, changed = combo("Animation", active and 2 or 1, { "Default", "Legacy" })
	if changed then
		active, dirty = choice == 2, true
	end

	ui.separator_text("Stacking")
	local on
	on, changed = ui.checkbox("Stack hits", stacking)
	if changed then
		stacking, dirty = on, true
	end
	ui.begin_disabled(not stacking)
	ui.set_next_item_width(COMBO_WIDTH)
	local window
	window, changed = ui.slider_float("Max gap between hits", stack_window, 0.05, 2, "%.2f s", ui.SliderFlags.AlwaysClamp)
	if changed then
		stack_window, dirty = window, true
	end
	on, changed = ui.checkbox("Stack headshots with body shots", merge_heads)
	if changed then
		merge_heads, dirty = on, true
	end
	ui.begin_disabled(not merge_heads)
	local style_index = 2
	for i, name in ipairs(STACK_STYLES) do
		if name == stack_style then
			style_index = i
		end
	end
	choice, changed = combo("Merged style", style_index, { "First hit", "Last hit", "Body only" })
	if changed then
		stack_style, dirty = STACK_STYLES[choice], true
	end
	ui.end_disabled()
	ui.end_disabled()
	if merge_heads then
		ui.text_disabled(({
			first = "One number per target, styled and coloured like its first hit.",
			last = "One number per target, styled and coloured like its latest hit.",
			body = "One number per target in the body shot style, coloured like its latest hit.",
		})[stack_style])
	else
		ui.text_disabled("Headshots and body shots stack separately.")
	end

	ui.separator_text("Colors")
	color_row("Body shots", "body")
	headshot_row()
	color_row("Healing", "healing")
	ui.text_disabled("New numbers pick up changes.")

	ui.separator_text("Menu")
	ui.align_text_to_frame_padding()
	ui.text("Menu key")
	ui.same_line()
	if listening then
		ui.button("Press a key... (Esc cancels)")
	elseif ui.button(cfg.menu_key .. "##menu_key") then
		listening = true
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

-- Theme: midnight panels, gold trim, parchment text. Pushed around our window
-- only, since every mod draws with the same ImGui style.
local GOLD, NIGHT, INK = 0xE8B54A, 0x141722, 0x1E2230
local function rgba(hex, a)
	return math.floor(hex / 0x10000) % 256 / 255, math.floor(hex / 0x100) % 256 / 255, hex % 256 / 255, a or 1
end
local THEME_COLORS = {
	{ "Text", 0xEDE6D6 },
	{ "TextDisabled", 0x8C8676 },
	{ "WindowBg", NIGHT, 0.97 },
	{ "PopupBg", NIGHT, 0.98 },
	{ "Border", GOLD, 0.35 },
	{ "BorderShadow", 0x000000, 0 },
	{ "TitleBg", 0x191C28 },
	{ "TitleBgActive", 0x272033 },
	{ "TitleBgCollapsed", 0x191C28, 0.8 },
	{ "FrameBg", INK },
	{ "FrameBgHovered", 0x2A3044 },
	{ "FrameBgActive", 0x343B54 },
	{ "CheckMark", GOLD },
	{ "SliderGrab", GOLD, 0.85 },
	{ "SliderGrabActive", 0xF6D27A },
	{ "Button", 0x2A3044 },
	{ "ButtonHovered", GOLD, 0.40 },
	{ "ButtonActive", GOLD, 0.65 },
	{ "Header", GOLD, 0.22 },
	{ "HeaderHovered", GOLD, 0.38 },
	{ "HeaderActive", GOLD, 0.55 },
	{ "Separator", GOLD, 0.30 },
	{ "ScrollbarBg", NIGHT, 0.6 },
	{ "ScrollbarGrab", 0x343B54 },
	{ "ScrollbarGrabHovered", GOLD, 0.45 },
	{ "ScrollbarGrabActive", GOLD, 0.7 },
	{ "NavCursor", GOLD },
}
local THEME_VARS = {
	{ "WindowRounding", 10 },
	{ "WindowBorderSize", 1 },
	{ "WindowPadding", 16, 14 },
	{ "WindowTitleAlign", 0.5, 0.5 },
	{ "PopupRounding", 8 },
	{ "FrameRounding", 6 },
	{ "FramePadding", 9, 5 },
	{ "GrabRounding", 6 },
	{ "GrabMinSize", 12 },
	{ "ItemSpacing", 10, 8 },
	{ "ScrollbarRounding", 6 },
	{ "SeparatorTextBorderSize", 2 },
	{ "SeparatorTextPadding", 0, 6 },
}

local function push_theme()
	for _, c in ipairs(THEME_COLORS) do
		ui.push_color(ui.Col[c[1]], rgba(c[2], c[3]))
	end
	for _, v in ipairs(THEME_VARS) do
		ui.push_var(ui.StyleVar[v[1]], v[2], v[3])
	end
end

local function pop_theme()
	ui.pop_var(#THEME_VARS)
	ui.pop_color(#THEME_COLORS)
end

ui.on_draw(function()
	if menu_open then
		if listening then
			poll_rebind()
		end
		local w, h = ui.screen()
		ui.set_next_window_pos(w / 2, h / 2, ui.Cond.FirstUseEver, 0.5, 0.5)
		push_theme()
		local ok, open = pcall(ui.window, "Custom Numbers", { open = true, flags = ui.WindowFlags.AlwaysAutoResize }, draw_settings)
		pop_theme()
		if not ok then
			error(open, 0)
		end
		if open == false then
			set_menu(false)
		end
	end
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
log("hooks live (%s, %s), animation %s, stacking %s, body %s, head %s, healing %s, menu key %s",
	X86 and "Win32" or "Win64", table.concat(found, ", "), active and "on" or "off",
	stacking and string.format("%.2fs", stack_window) or "off", show(colors.body),
	head_same and "body" or show(colors.head), show(colors.healing), bound and cfg.menu_key or "none")
