--[[
	Incantations: what an incantation does once it is cast (Config.Incantations; the animation is
	Shared.Sim.Incant, started by J).

	The server watches each fighter's incantation animation (the owner's report in Owner mode,
	OwnerSync, or its own simulation) and, if the fighter's chosen incantation is off cooldown:
	  rub     flames follow the hand along the blade (an emitter on the left hand)
	  active  once the rub is complete: the blade burns for Duration seconds (model attribute
	          "IncantActive" = the name, which also sends "Incantation : Fire" in the caster's chat,
	          client IncantChat); interrupting the rub cancels it
	Fire: strikes are PowerMult stronger (cuts, and blocks it pushes through), and a body part it
	wounds catches fire for BurnTime seconds, losing integrity and balance while it burns.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.RagdollRonin
local Config = require(Shared.Config)
local Incant = require(Shared.Sim.Incant)
local AnatomyService = require(script.Parent.AnatomyService)
local OwnerSync = require(script.Parent.OwnerSync)
local SoundFX = require(script.Parent.SoundFX)
local Feedback = require(script.Parent.Feedback)

local Incantations = {}
local IC = Config.Incantations
local FIRE_TEX = "rbxasset://textures/particles/fire_main.dds"

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

local function activate(f, c)
	local def = IC[c.Name]
	clearFx(c.Fx)
	c.Fx = {}
	c.Active = true
	c.Until = os.clock() + def.Duration
	local blade = f.Sword and f.Sword.Blade
	if blade and blade.Parent then
		table.insert(c.Fx, flames(blade, 60, 0.55))
		local light = Instance.new("PointLight")
		light.Name = "RR_FireLight"
		light.Color = Color3.fromRGB(255, 140, 50)
		light.Range = 9
		light.Brightness = 2
		light.Parent = blade
		table.insert(c.Fx, light)
		SoundFX.Play("Incantation", blade.Position)
	end
	f.Model:SetAttribute("IncantActive", c.Name)
	f.IncantPower = def.PowerMult or 1
end

local function finish(f)
	local c = f.Cast
	if c then
		clearFx(c.Fx)
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
				table.insert(c.Fx, flames(hand, 35, 0.35))
			end
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

-- a body part the burning blade wounded catches fire
function Incantations.OnWound(att, target, segName, part)
	local c = att.Cast
	if not (c and c.Active and c.Name == "Fire") or target.Dead or not part or not part.Parent then
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

function Incantations.Step(f, dt)
	if f.Removed then
		return
	end
	stepCast(f)
	stepBurns(f, dt)
end

-- strike power multiplier of this fighter's blade (CombatResolver)
function Incantations.PowerMult(f)
	return f.IncantPower or 1
end

return Incantations
