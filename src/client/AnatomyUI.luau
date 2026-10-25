--[[
	AnatomyUI: bottom-centre condition display (replaces a health bar).
	  * silhouette built from the shared Anatomy layout, seen from behind (your right is on the right)
	    segment colour = integrity; red outline = bleeding; hollow + x = severed/lost
	  * organs drawn at their anatomical positions, coloured by health
	  * separate blood meter (volume, incapacitation + lethal marks, bleed rate)
	  * short list of the most serious injuries and the current state
	Driven only by the server's AnatomyUpdate snapshots.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("RagdollRonin")
local Config = require(Shared:WaitForChild("Config"))
local Anatomy = require(Shared:WaitForChild("Anatomy"))

local AnatomyUI = {}

local K = 16 -- pixels per unscaled stud in the silhouette
local C_OK = Color3.fromRGB(150, 168, 150)
local C_HURT = Color3.fromRGB(226, 200, 80)
local C_SEVERE = Color3.fromRGB(235, 130, 40)
local C_CRIT = Color3.fromRGB(215, 40, 40)
local C_LOST = Color3.fromRGB(40, 40, 44)
local C_BLEED = Color3.fromRGB(255, 30, 30)

local ui = { Segments = {}, Organs = {} }
local snapshot

local function integrityColor(frac)
	if frac >= 0.85 then
		return C_OK
	elseif frac >= 0.6 then
		return C_HURT
	elseif frac >= 0.3 then
		return C_SEVERE
	end
	return C_CRIT
end

local function organColor(h)
	if h >= 95 then
		return Color3.fromRGB(240, 220, 220)
	elseif h >= 60 then
		return C_HURT
	elseif h >= 30 then
		return C_SEVERE
	elseif h > 0 then
		return C_CRIT
	end
	return Color3.new(0, 0, 0)
end

local function label(parent, text, size, pos, sz, align, color)
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency = 1
	t.Font = Enum.Font.GothamMedium
	t.TextSize = size
	t.TextColor3 = color or Color3.fromRGB(230, 230, 230)
	t.TextXAlignment = align or Enum.TextXAlignment.Left
	t.TextYAlignment = Enum.TextYAlignment.Top
	t.Position = pos
	t.Size = sz
	t.Text = text
	t.Parent = parent
	return t
end

function AnatomyUI.Init(ctx)
	local panel = Instance.new("Frame")
	panel.Name = "AnatomyPanel"
	panel.AnchorPoint = Vector2.new(0.5, 1)
	panel.Position = UDim2.new(0.5, 0, 1, -12)
	panel.Size = UDim2.fromOffset(360, 150)
	panel.BackgroundColor3 = Color3.fromRGB(14, 14, 18)
	panel.BackgroundTransparency = 0.25
	panel.BorderSizePixel = 0
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = panel
	panel.Parent = ctx.Gui
	ui.Panel = panel

	-- silhouette
	local body = Instance.new("Frame")
	body.BackgroundTransparency = 1
	body.Position = UDim2.fromOffset(8, 8)
	body.Size = UDim2.fromOffset(84, 134)
	body.Parent = panel
	local cx, cy = 42, 58 -- pixel position of the pelvis centre
	for _, def in ipairs(Anatomy.Parts) do
		local f = Instance.new("Frame")
		f.Name = def.Name
		f.AnchorPoint = Vector2.new(0.5, 0.5)
		f.Position = UDim2.fromOffset(cx + def.Center.X * K, cy - def.Center.Y * K)
		f.Size = UDim2.fromOffset(math.max(3, def.Size.X * K - 1), math.max(3, def.Size.Y * K - 1))
		f.BackgroundColor3 = C_OK
		f.BorderSizePixel = 0
		local st = Instance.new("UIStroke")
		st.Thickness = 1
		st.Color = Color3.new(0, 0, 0)
		st.Transparency = 0.5
		st.Parent = f
		f.Parent = body
		ui.Segments[def.Segment] = ui.Segments[def.Segment] or {}
		table.insert(ui.Segments[def.Segment], { Frame = f, Stroke = st })
	end
	for _, o in ipairs(Anatomy.Organs) do
		local pdef = Anatomy.PartByName[o.Part]
		local p = pdef.Center + o.Offset
		local d = math.max(5, math.floor(o.Radius * 2 * K * 0.8))
		local f = Instance.new("Frame")
		f.Name = o.Name
		f.AnchorPoint = Vector2.new(0.5, 0.5)
		f.Position = UDim2.fromOffset(cx + p.X * K, cy - p.Y * K)
		f.Size = UDim2.fromOffset(d, d)
		f.BackgroundColor3 = organColor(100)
		f.BorderSizePixel = 0
		f.ZIndex = 3
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0.5, 0)
		c.Parent = f
		local st = Instance.new("UIStroke")
		st.Thickness = 1
		st.Color = Color3.fromRGB(60, 0, 0)
		st.Parent = f
		f.Parent = body
		ui.Organs[o.Name] = f
	end
	label(body, "L", 10, UDim2.fromOffset(0, 0), UDim2.fromOffset(10, 10), nil, Color3.fromRGB(150, 150, 150))
	label(body, "R", 10, UDim2.fromOffset(76, 0), UDim2.fromOffset(10, 10), nil, Color3.fromRGB(150, 150, 150))

	-- blood meter
	local meter = Instance.new("Frame")
	meter.Position = UDim2.fromOffset(102, 22)
	meter.Size = UDim2.fromOffset(16, 100)
	meter.BackgroundColor3 = Color3.fromRGB(40, 20, 22)
	meter.BorderSizePixel = 0
	meter.Parent = panel
	local fill = Instance.new("Frame")
	fill.AnchorPoint = Vector2.new(0, 1)
	fill.Position = UDim2.fromScale(0, 1)
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = Color3.fromRGB(170, 14, 22)
	fill.BorderSizePixel = 0
	fill.Parent = meter
	for _, mark in ipairs({ { Config.Blood.Incapacitated, Color3.fromRGB(255, 200, 60) }, { Config.Blood.Lethal, Color3.new(1, 1, 1) } }) do
		local m = Instance.new("Frame")
		m.AnchorPoint = Vector2.new(0, 0.5)
		m.Position = UDim2.fromScale(0, 1 - mark[1])
		m.Size = UDim2.new(1, 4, 0, 2)
		m.BackgroundColor3 = mark[2]
		m.BorderSizePixel = 0
		m.ZIndex = 2
		m.Parent = meter
	end
	ui.BloodFill = fill
	label(panel, "BLOOD", 9, UDim2.fromOffset(96, 8), UDim2.fromOffset(30, 12), Enum.TextXAlignment.Center, Color3.fromRGB(200, 120, 120))
	ui.BloodText = label(panel, "5.0 L", 11, UDim2.fromOffset(94, 124), UDim2.fromOffset(34, 12), Enum.TextXAlignment.Center)
	ui.RateText = label(panel, "", 10, UDim2.fromOffset(90, 136), UDim2.fromOffset(42, 12), Enum.TextXAlignment.Center, C_BLEED)

	-- text column
	ui.State = label(panel, "", 13, UDim2.fromOffset(138, 8), UDim2.fromOffset(214, 16))
	ui.State.Font = Enum.Font.GothamBold
	ui.Injuries = label(panel, "", 11, UDim2.fromOffset(138, 28), UDim2.fromOffset(214, 92))
	ui.Injuries.TextWrapped = true
	ui.Injuries.RichText = true
	local legend = label(panel, "", 10, UDim2.fromOffset(138, 128), UDim2.fromOffset(214, 14))
	legend.RichText = true
	legend.Text = '<font color="#96a896">■</font> ok  <font color="#e2c850">■</font> hurt  <font color="#eb8228">■</font> severe  <font color="#d72828">■</font> critical  <font color="#ff1e1e">□</font> bleeding  × lost'

	ctx.Remotes.AnatomyUpdate.OnClientEvent:Connect(function(snap)
		if typeof(snap) == "table" then
			snapshot = snap
			AnatomyUI.Render(ctx)
		end
	end)
end

function AnatomyUI.OnNewFighter(ctx, model)
	snapshot = nil
end

local function injuryLines(snap)
	local lines = {}
	if snap.Pending then
		table.insert(lines, '<font color="#ff4040"><b>' .. snap.Pending .. " - dying</b></font>")
	end
	if snap.Death then
		table.insert(lines, '<font color="#ff4040"><b>Dead: ' .. snap.Death .. "</b></font>")
	end
	local organs = {}
	for _, o in ipairs(Anatomy.Organs) do
		local h = snap.Org[o.Name]
		if h and h < 100 then
			table.insert(organs, { h, string.format('<font color="#ff8080">%s %d%%</font>', o.Label, h) })
		end
	end
	table.sort(organs, function(a, b)
		return a[1] < b[1]
	end)
	for _, o in ipairs(organs) do
		table.insert(lines, o[2])
	end
	local segs = {}
	for name, rec in pairs(snap.Seg) do
		local def = Anatomy.Segments[name]
		if rec.l then
			table.insert(segs, { -1, def.Label .. " lost" })
		elseif rec.s then
			table.insert(segs, { 0, def.Label .. " severed" })
		elseif rec.i < 85 then
			table.insert(segs, { rec.i, string.format("%s %d%%%s", def.Label, rec.i, rec.f and "" or " (useless)") })
		end
	end
	table.sort(segs, function(a, b)
		return a[1] < b[1]
	end)
	for _, s in ipairs(segs) do
		table.insert(lines, s[2])
	end
	if not snap.Sword and not snap.Death then
		table.insert(lines, '<font color="#ffb050">Disarmed</font>')
	end
	local out = {}
	for i = 1, math.min(6, #lines) do
		out[i] = lines[i]
	end
	if #lines == 0 then
		return '<font color="#96a896">No injuries</font>'
	end
	return table.concat(out, "\n")
end

function AnatomyUI.Render(ctx)
	local snap = snapshot
	if not snap then
		return
	end
	for segName, frames in pairs(ui.Segments) do
		local rec = snap.Seg[segName]
		if rec then
			for _, fr in ipairs(frames) do
				local partLost = rec.l or (rec.s and fr.Frame.Name:sub(-1) == "D")
				if partLost then
					fr.Frame.BackgroundTransparency = 0.85
					fr.Frame.BackgroundColor3 = C_LOST
					fr.Stroke.Color = Color3.fromRGB(180, 40, 40)
					fr.Stroke.Transparency = 0
				else
					fr.Frame.BackgroundTransparency = 0
					fr.Frame.BackgroundColor3 = rec.s and C_CRIT or integrityColor(rec.i / 100)
					local bleeding = rec.b > 1
					fr.Stroke.Color = bleeding and C_BLEED or Color3.new(0, 0, 0)
					fr.Stroke.Thickness = bleeding and 2 or 1
					fr.Stroke.Transparency = bleeding and 0 or 0.5
				end
			end
		end
	end
	for name, f in pairs(ui.Organs) do
		local h = snap.Org[name] or 100
		f.BackgroundColor3 = organColor(h)
		f.Visible = true
	end
	local frac = math.clamp(snap.Blood / snap.BloodMax, 0, 1)
	ui.BloodFill.Size = UDim2.fromScale(1, frac)
	ui.BloodFill.BackgroundColor3 = frac > Config.Blood.WeakAt and Color3.fromRGB(170, 14, 22)
		or (frac > Config.Blood.Incapacitated and Color3.fromRGB(200, 60, 30) or Color3.fromRGB(110, 10, 14))
	ui.BloodText.Text = string.format("%.1f L", snap.Blood / 1000)
	ui.RateText.Text = snap.Rate > 0.5 and string.format("-%d ml/s", math.floor(snap.Rate + 0.5)) or ""
	local state = snap.Death and "Dead" or snap.State
	local extra = ""
	if snap.Inc and not snap.Death then
		extra = "  (incapacitated)"
	elseif snap.Legs and snap.Legs < Config.Movement.KneelLegSupport and snap.Legs > 0 and not snap.Death then
		extra = "  (kneeling)"
	end
	ui.State.Text = tostring(state) .. extra
	ui.State.TextColor3 = (state == "Dead" or snap.Inc) and C_CRIT or Color3.fromRGB(235, 235, 235)
	ui.Injuries.Text = injuryLines(snap)
end

local pulse = 0
function AnatomyUI.Update(ctx, dt)
	-- pulse bleeding outlines so active bleeding reads at a glance
	pulse += dt
	if not snapshot then
		return
	end
	local a = 0.5 + 0.5 * math.sin(pulse * 8)
	for segName, frames in pairs(ui.Segments) do
		local rec = snapshot.Seg[segName]
		if rec and rec.b > 1 and not rec.l then
			for _, fr in ipairs(frames) do
				fr.Stroke.Transparency = a * 0.6
			end
		end
	end
end

return AnatomyUI
