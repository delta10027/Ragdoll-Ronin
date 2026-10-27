--[[
	CombatCursorUI: shows exactly the input the combat controller uses.
	  ring        the combat disk (visible while M1/M2 are held)
	  cursor dot  the intended sword position (same u, v that is sent to the server)
	  blade line  attack: centre -> cursor, the direction the blade will point;
	              guard: a bar across the cursor showing how the guard will lie
	  trail/arrow recent cursor motion = swing direction (the edge follows it)
	  diamond     where the server-simulated blade tip actually is (projected), showing lag/inertia
	Colours follow the server's AttackPhase: Ready/Guiding (white/amber), Swing (red),
	Guard (blue), Recoil (violet); violet with "BOUND" while a blocked attack holds the cursor.
	Feedback text flashes for blocks, parries, interrupts, hits.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("RagdollRonin")
local Config = require(Shared:WaitForChild("Config"))
local InputController = require(script.Parent.InputController)

local CombatCursorUI = {}

local COLORS = {
	Ready = Color3.fromRGB(235, 235, 235),
	Guiding = Color3.fromRGB(255, 200, 90),
	Swing = Color3.fromRGB(255, 70, 50),
	Guard = Color3.fromRGB(90, 170, 255),
	Recoil = Color3.fromRGB(190, 120, 255),
	Unarmed = Color3.fromRGB(140, 140, 140),
	Sheathed = Color3.fromRGB(140, 140, 140),
	Drawing = Color3.fromRGB(200, 200, 200),
	Disabled = Color3.fromRGB(120, 120, 120),
}
local TRAIL = 6

local ui = {}

local function circle(parent, size, color, transp)
	local f = Instance.new("Frame")
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Size = UDim2.fromOffset(size, size)
	f.BackgroundColor3 = color
	f.BackgroundTransparency = transp or 0
	f.BorderSizePixel = 0
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0.5, 0)
	c.Parent = f
	f.Parent = parent
	return f
end

local function line(parent, thickness, color)
	local f = Instance.new("Frame")
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.BorderSizePixel = 0
	f.BackgroundColor3 = color
	f.Size = UDim2.fromOffset(1, thickness)
	f.Parent = parent
	return f
end

local function placeLine(l, a, b, thickness)
	local d = b - a
	local len = d.Magnitude
	l.Visible = len > 1
	l.Position = UDim2.fromOffset((a.X + b.X) / 2, (a.Y + b.Y) / 2)
	l.Size = UDim2.fromOffset(len, thickness)
	l.Rotation = math.deg(math.atan2(d.Y, d.X))
end

function CombatCursorUI.Init(ctx)
	local root = Instance.new("Frame")
	root.Name = "CombatCursor"
	root.BackgroundTransparency = 1
	root.Size = UDim2.fromScale(1, 1)
	root.Parent = ctx.Gui
	ui.Root = root

	-- the disk, cursor and blade markers (H hides them; feedback text stays)
	local disk = Instance.new("Frame")
	disk.Name = "Disk"
	disk.BackgroundTransparency = 1
	disk.Size = UDim2.fromScale(1, 1)
	disk.Parent = root
	ui.Disk = disk

	local ring = circle(disk, 100, Color3.new(1, 1, 1), 1)
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 1.5
	stroke.Transparency = 0.6
	stroke.Color = Color3.new(1, 1, 1)
	stroke.Parent = ring
	ui.Ring, ui.RingStroke = ring, stroke
	ui.Center = circle(disk, 4, Color3.new(1, 1, 1), 0.4)
	ui.Blade = line(disk, 2, Color3.new(1, 1, 1))
	ui.Guard = line(disk, 4, COLORS.Guard)
	ui.Trail = {}
	for i = 1, TRAIL do
		ui.Trail[i] = circle(disk, 4, Color3.new(1, 1, 1), 0.5)
	end
	ui.Arrow = line(disk, 2, Color3.new(1, 1, 1))
	local head = Instance.new("Frame")
	head.AnchorPoint = Vector2.new(0.5, 0.5)
	head.Size = UDim2.fromOffset(8, 8)
	head.BorderSizePixel = 0
	head.Rotation = 45
	head.Parent = disk
	ui.ArrowHead = head
	ui.Cursor = circle(disk, 10, Color3.new(1, 1, 1), 0)
	local cs = Instance.new("UIStroke")
	cs.Thickness = 1.5
	cs.Color = Color3.new(0, 0, 0)
	cs.Transparency = 0.3
	cs.Parent = ui.Cursor
	local tip = Instance.new("Frame")
	tip.AnchorPoint = Vector2.new(0.5, 0.5)
	tip.Size = UDim2.fromOffset(7, 7)
	tip.Rotation = 45
	tip.BackgroundTransparency = 1
	local ts = Instance.new("UIStroke")
	ts.Thickness = 1.5
	ts.Color = Color3.new(1, 1, 1)
	ts.Parent = tip
	tip.Parent = disk
	ui.Tip, ui.TipStroke = tip, ts

	local label = Instance.new("TextLabel")
	label.AnchorPoint = Vector2.new(0.5, 0)
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromOffset(240, 26)
	label.FontFace = Font.new("rbxasset://fonts/families/BuilderSans.json", Enum.FontWeight.Bold)
	label.TextSize = 18
	label.TextStrokeTransparency = 0.4
	label.TextColor3 = Color3.new(1, 1, 1)
	label.Text = ""
	label.Parent = root
	ui.Label = label
	ui.LabelUntil = 0

	local death = Instance.new("TextLabel")
	death.AnchorPoint = Vector2.new(0.5, 0.5)
	death.Position = UDim2.fromScale(0.5, 0.35)
	death.Size = UDim2.fromOffset(600, 60)
	death.BackgroundTransparency = 1
	death.Font = Enum.Font.GothamBlack
	death.TextSize = 30
	death.TextColor3 = Color3.fromRGB(220, 40, 40)
	death.TextStrokeTransparency = 0.3
	death.Visible = false
	death.Parent = root
	ui.Death = death

	ctx.Remotes.CombatFeedback.OnClientEvent:Connect(function(kind, info)
		CombatCursorUI.Flash(ctx, kind, info or {})
	end)
end

-- H: show / hide the combat disk
function CombatCursorUI.ToggleDisk()
	ui.Disk.Visible = not ui.Disk.Visible
	return ui.Disk.Visible
end

function CombatCursorUI.OnNewFighter(ctx, model)
	ui.Death.Visible = false
	ui.DeathUntil = nil
end

local MESSAGES = {
	AttackBlocked = { "BLOCKED", COLORS.Guard },
	AttackParried = { "PARRIED!", Color3.fromRGB(255, 120, 255) },
	AttackGlanced = { "GLANCED OFF GUARD", COLORS.Guiding },
	GuardBroken = { "GUARD BROKEN", COLORS.Swing },
	BladeBeaten = { "BLADE BEATEN ASIDE", COLORS.Guiding },
	Clash = { "CLASH", Color3.fromRGB(255, 230, 120) },
	Blocked = { "BLOCK", COLORS.Guard },
	Parried = { "PARRY!", Color3.fromRGB(120, 255, 200) },
	GuardGlanced = { "GUARD SLIPPED", COLORS.Swing },
	GuardOverpowered = { "GUARD OVERPOWERED", COLORS.Swing },
	BladeKnockedAside = { "BLADE KNOCKED ASIDE", COLORS.Swing },
	Interrupted = { "INTERRUPTED", COLORS.Swing },
	KnockedDown = { "KNOCKED DOWN", COLORS.Swing },
	Contact = { "touch", Color3.fromRGB(200, 200, 200) },
	KickLanded = { "TEEP!", Color3.fromRGB(255, 200, 90) },
	KickBlocked = { "TEEP CHECKED", COLORS.Guard },
	Kicked = { "KICKED BACK", COLORS.Swing },
	BlockedKick = { "TEEP BLOCKED", COLORS.Guard },
	ArmorStopped = { "STOPPED BY ARMOUR", COLORS.Guiding },
	ArmorHeld = { "ARMOUR HELD", COLORS.Guard },
	EnemyArmorBroken = { "ARMOUR SHATTERED", COLORS.Swing },
	ArmorBroken = { "YOUR ARMOUR BROKE", COLORS.Swing },
	Ignited = { "SET ALIGHT", Color3.fromRGB(255, 140, 40) },
	Burning = { "BURNING", Color3.fromRGB(255, 110, 30) },
	ShroudedEnemy = { "SHROUDED", Color3.fromRGB(170, 120, 240) },
}

function CombatCursorUI.Flash(ctx, kind, info)
	local text, color
	if kind == "Hit" then
		text = (info.Severed and "SEVERED " or "") .. string.upper(info.Label or "HIT") .. (info.Fatal and " - LETHAL" or "")
		color = info.Severed and Color3.fromRGB(255, 40, 40) or Color3.fromRGB(255, 160, 120)
	elseif kind == "Hurt" then
		text = "HIT: " .. (info.Label or "") .. (info.Severed and " (SEVERED)" or "")
		color = Color3.fromRGB(255, 80, 80)
	elseif kind == "Killed" then
		text = "KILLED " .. tostring(info.Target)
		color = Color3.fromRGB(255, 60, 60)
	elseif kind == "LoadoutRefused" then
		text, color = tostring(info.Reason or "Not now"), COLORS.Guiding
		if ctx.LoadoutRefused then
			ctx.LoadoutRefused(info.Reason)
		end
	elseif kind == "Shrouded" then
		-- a shadowed blade's wound: the sight darkens and drains of colour, then clears
		text, color = "SHROUDED", Color3.fromRGB(170, 120, 240)
		local Lighting = game:GetService("Lighting")
		local TweenService = game:GetService("TweenService")
		local cc = Lighting:FindFirstChild("RR_Shroud")
		if not cc then
			cc = Instance.new("ColorCorrectionEffect")
			cc.Name = "RR_Shroud"
			cc.Parent = Lighting
		end
		local darken = tonumber(info.Darken) or 0.35
		local time = tonumber(info.Time) or 4
		cc.Brightness, cc.Saturation, cc.Contrast = -darken, -0.7, 0.15
		cc.TintColor = Color3.fromRGB(200, 185, 230)
		local fade = TweenService:Create(cc, TweenInfo.new(time, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ Brightness = 0, Saturation = 0, Contrast = 0, TintColor = Color3.new(1, 1, 1) })
		fade:Play()
	elseif kind == "Died" then
		ui.DeathBase = "YOU DIED - " .. tostring(info.Reason)
		ui.Death.Text = ui.DeathBase
		ui.Death.Visible = true
		ui.DeathUntil = os.clock() + (info.Respawn or 5)
		return
	else
		local m = MESSAGES[kind]
		if not m then
			return
		end
		text, color = m[1], m[2]
	end
	ui.Label.Text = text
	ui.Label.TextColor3 = color
	ui.LabelUntil = os.clock() + 0.9
	ui.FlashColor = color
	ui.FlashUntil = os.clock() + 0.25
end

function CombatCursorUI.Update(ctx, dt)
	local cam = workspace.CurrentCamera
	local vp = cam.ViewportSize
	local R = math.floor(math.min(vp.X, vp.Y) * 0.17)
	local s = ctx.Input
	if not s then
		return
	end
	local model = ctx.Fighter
	-- anchor the combat disk in front of the fighter's chest so the cursor sits where the sword goes
	local center = Vector2.new(vp.X * 0.5, vp.Y * 0.52)
	local ut = model and model:FindFirstChild("UpperTorso")
	local pelvis = model and model:FindFirstChild("LowerTorso")
	if ut and pelvis then
		local look = pelvis.CFrame.LookVector
		local fwd = Vector3.new(look.X, 0, look.Z)
		fwd = fwd.Magnitude > 0.1 and fwd.Unit or Vector3.zero
		local p, onScreen = cam:WorldToViewportPoint(ut.Position + fwd * 1.6 + Vector3.new(0, 0.25, 0))
		if onScreen then
			local target = Vector2.new(p.X, p.Y)
			ui.Anchor = ui.Anchor and ui.Anchor:Lerp(target, math.min(1, 12 * dt)) or target
			center = ui.Anchor
		end
	end
	local state = model and model:GetAttribute("State") or "Idle"
	local phase = model and model:GetAttribute("AttackPhase") or "Ready"
	local disabled = state == "Dead" or state == "Falling" or state == "GroundedRecovery" or state == "SeverelyInjured" or state == "Recovering"
	local active = s.M1 or s.M2
	local color = disabled and COLORS.Disabled or (COLORS[phase] or COLORS.Ready)
	if s.M2 and not disabled and phase ~= "Unarmed" then
		color = COLORS.Guard
	end
	-- a bound (blocked) attack: the cursor is held where the blades met until it is drawn back
	local bound = s.M1 and not disabled and InputController.Bind(ctx) ~= nil
	if bound then
		color = COLORS.Recoil
	end
	local now = os.clock()
	if ui.FlashUntil and now < ui.FlashUntil then
		color = ui.FlashColor
	end

	ui.Ring.Position = UDim2.fromOffset(center.X, center.Y)
	ui.Ring.Size = UDim2.fromOffset(R * 2, R * 2)
	ui.RingStroke.Color = color
	ui.RingStroke.Transparency = active and 0.35 or 0.85
	ui.Center.Position = UDim2.fromOffset(center.X, center.Y)

	local cur = center + Vector2.new(s.AimU, -s.AimV) * R
	ui.Cursor.Position = UDim2.fromOffset(cur.X, cur.Y)
	ui.Cursor.BackgroundColor3 = color
	ui.Cursor.Size = UDim2.fromOffset(active and 12 or 8, active and 12 or 8)

	-- intended sword direction
	if s.M2 then
		ui.Blade.Visible = false
		local r = math.sqrt(s.AimU ^ 2 + s.AimV ^ 2)
		local radial = r > 0.2 and Vector2.new(s.AimU, -s.AimV) / r or Vector2.new(0, -1)
		local across = Vector2.new(-radial.Y, radial.X)
		placeLine(ui.Guard, cur - across * R * 0.45, cur + across * R * 0.45, 4)
		ui.Guard.BackgroundColor3 = color
	else
		ui.Guard.Visible = false
		placeLine(ui.Blade, center, cur, 2)
		ui.Blade.BackgroundColor3 = color
		ui.Blade.BackgroundTransparency = active and 0.2 or 0.7
	end

	-- motion trail + arrow (swing direction)
	local h = s.History
	for i = 1, TRAIL do
		local sample = h[math.max(1, #h - (i * 2))]
		local dot = ui.Trail[i]
		if sample and active then
			dot.Visible = true
			dot.Position = UDim2.fromOffset(center.X + sample.u * R, center.Y - sample.v * R)
			dot.BackgroundColor3 = color
			dot.BackgroundTransparency = 0.3 + i * 0.1
		else
			dot.Visible = false
		end
	end
	local mu, mv = InputController.MotionVector(ctx, 0.08)
	local speed = math.sqrt(mu * mu + mv * mv)
	if active and speed > 0.6 then
		local dir = Vector2.new(mu, -mv) / speed
		local len = math.clamp(speed * 10, 14, 60)
		local tipPos = cur + dir * len
		placeLine(ui.Arrow, cur, tipPos, 2)
		ui.Arrow.BackgroundColor3 = color
		ui.ArrowHead.Visible = true
		ui.ArrowHead.Position = UDim2.fromOffset(tipPos.X, tipPos.Y)
		ui.ArrowHead.BackgroundColor3 = color
	else
		ui.Arrow.Visible = false
		ui.ArrowHead.Visible = false
	end

	-- actual blade tip (server simulated, replicated)
	local blade = model and model:FindFirstChild("Katana") and model.Katana:FindFirstChild("Blade")
	if blade then
		local p, onScreen = cam:WorldToViewportPoint(blade.CFrame:PointToWorldSpace(Vector3.new(0, blade.Size.Y / 2, 0)))
		ui.Tip.Visible = onScreen
		ui.Tip.Position = UDim2.fromOffset(p.X, p.Y)
		ui.TipStroke.Color = color
	else
		ui.Tip.Visible = false
	end

	ui.Label.Position = UDim2.fromOffset(center.X, center.Y + R + 10)
	if bound and now >= ui.LabelUntil then
		ui.Label.Text = "BOUND - pull back"
		ui.Label.TextColor3 = COLORS.Recoil
		ui.Label.Visible = true
	else
		ui.Label.Visible = now < ui.LabelUntil
	end
	if ui.DeathUntil then
		local left = math.max(0, ui.DeathUntil - now)
		ui.Death.Text = (ui.DeathBase or "") .. string.format("   respawn in %.0f", left)
	end
end

return CombatCursorUI
