--[[
	Incantations: what an incantation does once it is cast (Config.Incantations; the animation is
	Shared.Sim.Incant, started by J).

	The server watches each fighter's incantation animation (the owner's report in Owner mode,
	OwnerSync, or its own simulation) and, if the fighter's chosen incantation is off cooldown:
	  rub     the Incantation sound plays, then the incantation's own (Config.Sounds
	          FireIncantation, ShadowIncantation, LightningIncantation); flames (Shadow: dark smoke, Lightning: sparks)
	          follow the hand along the blade (an emitter on the left hand)
	  active  once the rub is complete: the blade takes it for Duration seconds (model attribute
	          "IncantActive" = the name, which also sends "Incantation : Fire" in the caster's
	          chat, client InventoryClient); interrupting the rub cancels it
	Fire: the blade burns. Strikes are PowerMult stronger (cuts, and blocks it pushes through), and
	a body part it wounds catches fire for BurnTime seconds, losing integrity and balance while it
	burns.
	Shadow: the blade's metal fades to a dark shade trailing black smoke, hard to see coming. A
	body part it wounds is shrouded for ShroudTime seconds: smoke clings to it, the wound bleeds
	ShroudBleed ml/s more, the fighter loses balance, and their sight darkens (Feedback
	"Shrouded", the client's CombatCursorUI).
	Lightning: the blade crackles with sparks, and every kick (KickResolver, once the leg is out)
	shoots a bolt from the foot straight ahead, up to BoltRange and stopped by the world. A
	fighter it strikes is shocked: the body part loses ShockDamage integrity (through armour;
	a bolt on the sword goes into the sword hand), the body is thrown back and loses
	ShockBalance, knocked down with none left (Feedback "Shocked" / "ShockedEnemy").
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.RagdollRonin
local Config = require(Shared.Config)
local Incant = require(Shared.Sim.Incant)
local Anatomy = require(Shared.Anatomy)
local Runtime = require(Shared.Sim.Runtime)
local BalanceController = require(Shared.Sim.BalanceController)
local StateDefs = require(Shared.StateDefs)
local Debris = game:GetService("Debris")
local TweenService = game:GetService("TweenService")
local Registry = require(script.Parent.Registry)
local AnatomyService = require(script.Parent.AnatomyService)
local OwnerSync = require(script.Parent.OwnerSync)
local SoundFX = require(script.Parent.SoundFX)
local Feedback = require(script.Parent.Feedback)

local Incantations = {}
local IC = Config.Incantations
local FIRE_TEX = "rbxasset://textures/particles/fire_main.dds"
local SMOKE_TEX = "rbxasset://textures/particles/smoke_main.dds"
local SPARK_TEX = "rbxasset://textures/particles/sparkles_main.dds"
local SHADOWED = { "Blade", "Edge", "Kissaki" } -- the sword's metal parts a Shadow blade hides

local killFn
function Incantations.SetKill(fn)
	killFn = fn
end

local function flames(parent, rate, size)
	local pe = Instance.new("ParticleEmitter")
	pe.Name = "RR_Flames"
	pe.Texture = FIRE_TEX
	pe.LightEmission = 1
	pe.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 230, 120)),
		ColorSequenceKeypoint.new(0.4, Color3.fromRGB(255, 120, 30)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(160, 20, 10)),
	})
	pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, size), NumberSequenceKeypoint.new(1, size * 0.15) })
	pe.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(1, 1) })
	pe.Lifetime = NumberRange.new(0.25, 0.5)
	pe.Speed = NumberRange.new(1, 2.5)
	pe.Acceleration = Vector3.new(0, 6, 0)
	pe.SpreadAngle = Vector2.new(25, 25)
	pe.RotSpeed = NumberRange.new(-90, 90)
	pe.Rotation = NumberRange.new(0, 360)
	pe.Rate = rate
	pe.LockedToPart = false
	pe.Parent = parent
	return pe
end

-- dark smoke curling off a shadowed blade, hand or wound
local function smoke(parent, rate, size)
	local pe = Instance.new("ParticleEmitter")
	pe.Name = "RR_Shadow"
	pe.Texture = SMOKE_TEX
	pe.LightEmission = 0
	pe.LightInfluence = 0
	pe.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(40, 20, 60)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(0, 0, 0)),
	})
	pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, size * 0.4), NumberSequenceKeypoint.new(1, size) })
	pe.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.15, 0.35),
		NumberSequenceKeypoint.new(1, 1),
	})
	pe.Lifetime = NumberRange.new(0.5, 0.9)
	pe.Speed = NumberRange.new(0.3, 0.9)
	pe.Acceleration = Vector3.new(0, 1.5, 0)
	pe.Drag = 2
	pe.SpreadAngle = Vector2.new(180, 180)
	pe.RotSpeed = NumberRange.new(-40, 40)
	pe.Rotation = NumberRange.new(0, 360)
	pe.Rate = rate
	pe.LockedToPart = false
	pe.Parent = parent
	return pe
end

-- blue-white sparks crackling off a charged blade or hand
local function sparks(parent, rate, size)
	local pe = Instance.new("ParticleEmitter")
	pe.Name = "RR_Sparks"
	pe.Texture = SPARK_TEX
	pe.LightEmission = 1
	pe.Color = ColorSequence.new(Color3.fromRGB(230, 245, 255), IC.Lightning.BoltColor)
	pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, size), NumberSequenceKeypoint.new(1, 0) })
	pe.Lifetime = NumberRange.new(0.08, 0.22)
	pe.Speed = NumberRange.new(3, 7)
	pe.SpreadAngle = Vector2.new(180, 180)
	pe.Rotation = NumberRange.new(0, 360)
	pe.Rate = rate
	pe.LockedToPart = false
	pe.Parent = parent
	return pe
end

local function clearFx(list)
	for _, inst in ipairs(list or {}) do
		inst:Destroy()
	end
end

local function casting(f)
	if OwnerSync.Applies(f) then
		return f.ReportIncanting == true
	end
	return f.IncantT ~= nil
end

-- the sword's metal sinks into shadow; c.Shade keeps how it looked, to bring it back
local function shade(f, c, def)
	local model = f.Sword and f.Sword.Model
	if not model then
		return
	end
	c.Shade = {}
	for _, name in ipairs(SHADOWED) do
		local part = model:FindFirstChild(name)
		if part and part:IsA("BasePart") then
			c.Shade[part] = { Transparency = part.Transparency, Color = part.Color, Material = part.Material }
			part.Transparency = def.BladeTransparency
			part.Color = def.BladeColor
			part.Material = Enum.Material.SmoothPlastic
		end
	end
end

local function unshade(c)
	for part, was in pairs(c.Shade or {}) do
		if part.Parent then
			part.Transparency, part.Color, part.Material = was.Transparency, was.Color, was.Material
		end
	end
	c.Shade = nil
end

local function activate(f, c)
	local def = IC[c.Name]
	clearFx(c.Fx)
	c.Fx = {}
	c.Active = true
	c.Until = os.clock() + def.Duration
	local blade = f.Sword and f.Sword.Blade
	if blade and blade.Parent then
		if c.Name == "Shadow" then
			table.insert(c.Fx, smoke(blade, 45, 0.7))
			shade(f, c, def)
		elseif c.Name == "Lightning" then
			table.insert(c.Fx, sparks(blade, 40, 0.35))
			local light = Instance.new("PointLight")
			light.Name = "RR_LightningLight"
			light.Color = def.BoltColor
			light.Range = 8
			light.Brightness = 1.5
			light.Parent = blade
			table.insert(c.Fx, light)
		else
			table.insert(c.Fx, flames(blade, 60, 0.55))
			local light = Instance.new("PointLight")
			light.Name = "RR_FireLight"
			light.Color = Color3.fromRGB(255, 140, 50)
			light.Range = 9
			light.Brightness = 2
			light.Parent = blade
			table.insert(c.Fx, light)
		end
	end
	f.Model:SetAttribute("IncantActive", c.Name)
	f.IncantPower = def.PowerMult or 1
end

local function finish(f)
	local c = f.Cast
	if c then
		clearFx(c.Fx)
		unshade(c)
	end
	f.Cast = nil
	f.IncantPower = nil
	if f.Model and f.Model.Parent then
		f.Model:SetAttribute("IncantActive", nil)
	end
end

local function stepCast(f)
	local now = os.clock()
	local on = casting(f)
	local c = f.Cast
	if on and not f.WasCasting and not (c and c.Active) then
		-- the animation began: start the incantation if it may be cast
		local name = f.Model:GetAttribute("IncantChoice")
		local def = name and IC[name]
		if def and f.Sword and not f.Sheathed and now >= (f.IncantServerReady or 0) then
			c = { Name = name, Start = now, Fx = {} }
			f.Cast = c
			f.IncantServerReady = now + def.Cooldown - 1 -- (a second of slack for the owner's clock)
			local hand = f.Parts.LeftHand
			if hand and hand.Parent then
				local fx = name == "Shadow" and smoke(hand, 30, 0.45) or name == "Lightning" and sparks(hand, 35, 0.3) or flames(hand, 35, 0.35)
				table.insert(c.Fx, fx)
			end
			local blade = f.Sword.Blade
			-- as the animation starts, then the incantation's own sound ("FireIncantation", ...)
			SoundFX.Play("Incantation", (blade and blade.Parent and blade or f.Parts.UpperTorso).Position, name .. "Incantation")
		end
	end
	f.WasCasting = on
	if not c then
		return
	end
	if not c.Active then
		local t = now - c.Start
		if t >= Incant.RubEnd then
			activate(f, c)
		elseif not on or f.Dead then
			finish(f) -- interrupted before the rub was complete
		end
	elseif now >= c.Until or f.Dead or not f.Sword or f.Sheathed then -- (sheathing puts the fire out)
		finish(f)
	end
end

-- a body part the shadowed blade wounded is shrouded
local function shroud(att, target, segName, part)
	local def = IC.Shadow
	local rec = target.Anatomy and target.Anatomy.Segments[segName]
	if rec and not rec.Severed then
		rec.Bleeding += def.ShroudBleed
		target.AnatomyDirty = true
	end
	target.Shrouds = target.Shrouds or {}
	local sh = target.Shrouds[segName]
	if sh then
		sh.Until = os.clock() + def.ShroudTime
	else
		target.Shrouds[segName] = { Until = os.clock() + def.ShroudTime, Fx = smoke(part, 25, 0.6) }
		SoundFX.Play("ShadowHit", part.Position)
	end
	Feedback.Send(target, "Shrouded", { Time = def.ShroudTime, Darken = def.ShroudDarken })
	Feedback.Send(att, "ShroudedEnemy", {})
end

-- a body part the burning blade wounded catches fire (a shadowed one's is shrouded)
function Incantations.OnWound(att, target, segName, part)
	local c = att.Cast
	if not (c and c.Active) or target.Dead or not part or not part.Parent then
		return
	end
	if c.Name == "Shadow" then
		return shroud(att, target, segName, part)
	elseif c.Name ~= "Fire" then
		return
	end
	local def = IC.Fire
	target.Burns = target.Burns or {}
	local b = target.Burns[segName]
	if b then
		b.Until = os.clock() + def.BurnTime
		return
	end
	target.Burns[segName] = { Until = os.clock() + def.BurnTime, Fx = flames(part, 30, 0.5) }
	SoundFX.Play("FireHit", part.Position)
	Feedback.Send(target, "Burning", {})
	Feedback.Send(att, "Ignited", {})
end

local boltParams = RaycastParams.new()
boltParams.FilterType = Enum.RaycastFilterType.Exclude
boltParams.CollisionGroup = "RR_HitQuery" -- (fighters and blades only)
local worldParams = RaycastParams.new()
worldParams.FilterType = Enum.RaycastFilterType.Exclude

-- the bolt's look: a jagged line of neon from `from` to `to`, a flash at both ends, fading fast
local function drawBolt(from, to)
	local def = IC.Lightning
	local folder = Instance.new("Folder")
	folder.Name = "RR_Bolt"
	local d = to - from
	local len = d.Magnitude
	if len < 0.1 then
		return
	end
	local n = math.clamp(math.floor(len / 2.5), 4, 18)
	local side = d:Cross(Vector3.yAxis)
	side = side.Magnitude > 1e-3 and side.Unit or Vector3.xAxis
	local up = side:Cross(d.Unit)
	local points = { from }
	for i = 1, n - 1 do
		local jitter = (side * (math.random() - 0.5) + up * (math.random() - 0.5)) * math.min(1.6, len * 0.06)
		table.insert(points, from + d * (i / n) + jitter)
	end
	table.insert(points, to)
	local parts = {}
	for i = 1, #points - 1 do
		local a, b = points[i], points[i + 1]
		for _, w in ipairs({ { 0.14, 0, Color3.new(1, 1, 1) }, { 0.4, 0.55, def.BoltColor } }) do
			local seg = Instance.new("Part")
			seg.Name = "Bolt"
			seg.Anchored = true
			seg.CanCollide, seg.CanQuery, seg.CanTouch, seg.CastShadow = false, false, false, false
			seg.Material = Enum.Material.Neon
			seg.Color = w[3]
			seg.Transparency = w[2]
			seg.Size = Vector3.new(w[1], w[1], (b - a).Magnitude + w[1])
			seg.CFrame = CFrame.lookAt((a + b) * 0.5, b)
			seg.Parent = folder
			table.insert(parts, seg)
		end
	end
	for _, at in ipairs({ from, to }) do
		local glow = Instance.new("Part")
		glow.Name = "Flash"
		glow.Anchored = true
		glow.CanCollide, glow.CanQuery, glow.CanTouch, glow.CastShadow = false, false, false, false
		glow.Transparency = 1
		glow.Size = Vector3.one * 0.2
		glow.CFrame = CFrame.new(at)
		local light = Instance.new("PointLight")
		light.Color = def.BoltColor
		light.Range = 14
		light.Brightness = 4
		light.Parent = glow
		glow.Parent = folder
	end
	folder.Parent = workspace
	local info = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.In, 0, false, 0.06)
	for _, seg in ipairs(parts) do
		TweenService:Create(seg, info, { Transparency = 1 }):Play()
	end
	Debris:AddItem(folder, 0.4)
end

local function shock(att, target, part, dir)
	local def = IC.Lightning
	local info = Anatomy.PartByName[part.Name]
	local segName = info and target.Parts[part.Name] == part and info.Segment or "RightHand" -- (the sword: into the hand)
	local rec = target.Anatomy and target.Anatomy.Segments[segName]
	if rec and not rec.Severed then
		rec.Integrity = math.max(0, rec.Integrity - def.ShockDamage)
		rec.Functional = rec.Integrity > Config.Anatomy.DisableBelow
		AnatomyService.EvaluateVitals(target)
		AnatomyService.UpdateCaps(target)
		target.AnatomyDirty = true
	end
	for _, p in pairs(target.Parts) do
		if p.Parent then
			Runtime.Impulse(p, (dir * def.ShockKnockbackDV + Vector3.new(0, 3, 0)) * p:GetMass())
		end
	end
	if StateDefs.Upright[target.State] then
		target.Balance = (target.Balance or 0) - def.ShockBalance
		if target.Balance <= 0 then
			BalanceController.KnockDown(target, dir, 10, "Struck by lightning")
		else
			BalanceController.Stagger(target, def.ShockStaggerTime, dir, "Shocked")
		end
	end
	SoundFX.Play("LightningHit", part.Position)
	Feedback.Send(target, "Shocked", {})
	Feedback.Send(att, "ShockedEnemy", { Target = target.Name })
	local fatal = AnatomyService.CheckFatal(target)
	if fatal and killFn then
		killFn(target, fatal)
	end
end

-- KickResolver: this fighter's kick is out (once per kick). With Lightning on the blade, a bolt
-- leaves the foot along `dir`.
function Incantations.OnKick(f, from, dir)
	local c = f.Cast
	if not (c and c.Active and c.Name == "Lightning") or f.Dead then
		return
	end
	local def = IC.Lightning
	local reach = dir * def.BoltRange
	boltParams.FilterDescendantsInstances = { f.Model }
	worldParams.FilterDescendantsInstances = { f.Model }
	local to = from + reach
	local wall = workspace:Raycast(from, reach, worldParams)
	if wall and not Registry.FromPart(wall.Instance) then
		to = wall.Position
	end
	local hit = workspace:Spherecast(from, def.BoltRadius, to - from, boltParams)
	local target = hit and Registry.FromPart(hit.Instance)
	if target and target ~= f and not target.Dead then
		to = hit.Position
	else
		target = nil
	end
	drawBolt(from, to)
	SoundFX.Play("Lightning", from)
	if target then
		shock(f, target, hit.Instance, dir)
	end
end

local function stepBurns(f, dt)
	if not f.Burns then
		return
	end
	local def = IC.Fire
	local now = os.clock()
	local any = false
	for segName, b in pairs(f.Burns) do
		local rec = f.Anatomy and f.Anatomy.Segments[segName]
		if now >= b.Until or f.Dead or not rec or not b.Fx.Parent then
			b.Fx:Destroy()
			f.Burns[segName] = nil
		else
			any = true
			rec.Integrity = math.max(0, rec.Integrity - def.BurnIntegrityPerSecond * dt)
			rec.Functional = not rec.Severed and rec.Integrity > Config.Anatomy.DisableBelow
			-- (burning shakes the fighter but never knocks them over, Config.Balance.BodyHitFloor)
			local bal = f.Balance or 0
			f.Balance = math.max(bal - def.BurnBalancePerSecond * dt, math.min(bal, Config.Balance.BodyHitFloor))
		end
	end
	if any then
		AnatomyService.EvaluateVitals(f)
		AnatomyService.UpdateCaps(f)
		f.AnatomyDirty = true
		local fatal = AnatomyService.CheckFatal(f)
		if fatal and killFn then
			killFn(f, fatal)
		end
	end
end

local function stepShrouds(f, dt)
	if not f.Shrouds then
		return
	end
	local def = IC.Shadow
	local now = os.clock()
	for segName, sh in pairs(f.Shrouds) do
		if now >= sh.Until or f.Dead or not sh.Fx.Parent then
			sh.Fx:Destroy()
			f.Shrouds[segName] = nil
		else
			-- (like burning, it shakes the fighter but never knocks them over)
			local bal = f.Balance or 0
			f.Balance = math.max(bal - def.ShroudBalancePerSecond * dt, math.min(bal, Config.Balance.BodyHitFloor))
		end
	end
end

function Incantations.Step(f, dt)
	if f.Removed then
		return
	end
	stepCast(f)
	stepBurns(f, dt)
	stepShrouds(f, dt)
end

-- strike power multiplier of this fighter's blade (CombatResolver)
function Incantations.PowerMult(f)
	return f.IncantPower or 1
end

return Incantations
