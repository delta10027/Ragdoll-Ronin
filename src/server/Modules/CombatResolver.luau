--[[
	CombatResolver: turns swept contacts into authoritative outcomes.

	Strike power (no client-supplied numbers anywhere):
	  power = PowerScale * (relSpeed / RefSpeed)^2 * commitment * weapon * strokeEnergy * attackerStrength
	  relSpeed   = blade point velocity (from the sweep) minus the target surface velocity
	  commitment = stroke tip travel / CommitmentDistance (short flicks are weak)
	  strokeEnergy drops after every block, glance or body it passes through
	Contact classification:
	  Thrust - moving along the blade axis and contact near the tip
	  Cut    - relative motion aligned with the cutting edge (quality from alignment)
	  Blunt  - flat or spine contact

	Blade-vs-blade (the attacker's sweep reached the defender's sword or guard volume first):
	  defender blocking -> quality q = how perpendicular the guard is to the attack (1 - |axis.dir|),
	    must also be in front of the defender.
	      q < MinQuality or behind  -> Glance: attack slides on with reduced energy
	      power > guard*Overpower   -> Overpowered: guard broken, defender staggered, attack continues
	      raised within ParryWindow -> Parried: attacker deflected hard + staggered
	      otherwise                 -> Blocked: attacker deflected + recoil, defender pays balance
	  defender not blocking -> Clash (both deflect) if they were swinging, else Beat (blade knocked aside)
	Blocked, parried and clashing attacks are also BOUND (SwordController.Bind): the attacker's
	cursor stops where the blades met and can only be drawn back. Blades meeting without a stroke
	(a slow push into a guard or a blade) bind too, without any strike.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.RagdollRonin
local Config = require(Shared.Config)
local Anatomy = require(Shared.Anatomy)
local StateDefs = require(Shared.StateDefs)
local Util = require(Shared.Sim.Util)
local Registry = require(script.Parent.Registry)
local AnatomyService = require(script.Parent.AnatomyService)
local Dismemberment = require(script.Parent.Dismemberment)
local BalanceController = require(Shared.Sim.BalanceController)
local SwordController = require(Shared.Sim.SwordController)
local StateMachine = require(Shared.Sim.StateMachine)
local Runtime = require(Shared.Sim.Runtime)
local BloodFX = require(script.Parent.BloodFX)
local Feedback = require(script.Parent.Feedback)
local DebugService = require(script.Parent.DebugService)
local HitDetection = require(script.Parent.HitDetection)
local SoundFX = require(script.Parent.SoundFX)

local CombatResolver = {}
local C = Config.Combat
local BK = Config.Block
local BL = Config.Balance
local S = Config.Scale
local MAX_REACH = (1.3 + 2.475) * S + Config.Sword.BladeLength + Config.Sword.HandleLength + C.ReachMargin

local killFn -- injected by Main (Lifecycle.Kill) to avoid a require cycle
function CombatResolver.SetKill(fn)
	killFn = fn
end

local function strikePower(att, stroke, relSpeed)
	local commitment = math.clamp(stroke.Distance / C.CommitmentDistance, C.MinCommitment, 1)
	local p = C.PowerScale * (relSpeed / C.RefSpeed) ^ 2 * commitment * Config.Sword.WeaponFactor * stroke.EnergyMult * att.Caps.Strength
	return math.min(p, C.MaxPower), commitment
end

local function plausible(att, target, h)
	if att.Dead or target.Dead or not att.Sword then
		return false, "dead/unarmed"
	end
	if att.Attack.TipSpeed > C.MaxPlausibleTipSpeed then
		return false, "tip speed"
	end
	local ut = att.Parts.UpperTorso
	if not ut or (h.Position - ut.Position).Magnitude > MAX_REACH then
		return false, "reach"
	end
	return true
end

local function deflect(f, dir, dv)
	if f.Sword and f.Sword.Handle.Parent then
		local h = f.Sword.Handle
		Runtime.Impulse(h, Util.unit(dir, Vector3.yAxis) * dv * h.AssemblyMass)
	end
end

local function feedbackBoth(att, def, kindAtt, kindDef, info)
	Feedback.Send(att, kindAtt, info)
	Feedback.Send(def, kindDef, info)
end

------------------------------------------------------------------ blade contacts
-- returns "Stop" (stroke ends) or "Continue"
local function resolveBladeContact(att, def, h)
	local now = Runtime.now()
	local stroke = att.Attack.Stroke
	if not def.Sword or not def.Sword.Blade.Parent then
		return "Continue"
	end
	local defBlade = def.Sword.Blade
	local rel = h.PointVel - defBlade:GetVelocityAtPosition(h.Position)
	local speed = rel.Magnitude
	local dir = speed > 1e-3 and rel / speed or stroke.Dir
	local power = strikePower(att, stroke, speed)
	local q = 1 - math.abs(defBlade.CFrame.YVector:Dot(dir))
	local torso = def.Parts.UpperTorso
	local facing = Util.unit(Util.flat(def.Parts.LowerTorso.CFrame.LookVector), Vector3.zAxis)
	local inFront = torso and Util.unit(Util.flat(h.Position - torso.Position), facing):Dot(facing) > BK.FrontTolerance
	local info = { Power = math.floor(power * 10) / 10, Quality = math.floor(q * 100) / 100 }
	DebugService.Marker(h.Position, Color3.fromRGB(80, 160, 255), 0.45)

	if def.State == "Blocking" and def.Block.Active then
		local guard = BK.Strength * (0.35 + 0.65 * q) * def.Caps.SwordArm * def.Caps.Grip * def.Caps.Strength * (inFront and 1 or 0.35)
		local parry = inFront and q >= BK.ParryMinQuality and (now - def.Block.StartTime) <= BK.ParryWindow
		local outcome
		if q < BK.MinQuality or not inFront then
			outcome = "Glance"
			stroke.EnergyMult *= BK.GlanceEnergyMult
			stroke.GuardPassed[def.Id] = true
			def.Balance -= power * BK.BalanceCostPerPower * 0.3
			feedbackBoth(att, def, "AttackGlanced", "GuardGlanced", info)
		elseif power > guard * BK.OverpowerRatio and not parry then
			outcome = "Overpowered"
			stroke.EnergyMult *= BK.OverpowerEnergyMult
			stroke.GuardPassed[def.Id] = true
			def.Balance -= power * BK.BalanceCostPerPower * 1.5
			deflect(def, dir, C.DeflectDV)
			BalanceController.Stagger(def, C.StaggerTime, dir, "Guard overpowered")
			feedbackBoth(att, def, "GuardBroken", "GuardOverpowered", info)
		elseif parry then
			outcome = "Parried"
			SwordController.Bind(att)
			deflect(att, -dir, C.ParryDeflectDV)
			SwordController.Recoil(att, C.ParryStaggerTime)
			BalanceController.Stagger(att, C.ParryStaggerTime, -dir, "Parried")
			feedbackBoth(att, def, "AttackParried", "Parried", info)
		else
			outcome = "Blocked"
			SwordController.Bind(att)
			deflect(att, -dir, C.DeflectDV)
			deflect(def, dir, C.DeflectDV * 0.35)
			SwordController.Recoil(att, C.RecoilTime)
			def.Balance -= power * BK.BalanceCostPerPower
			if def.Balance <= BL.OffBalanceThreshold then
				BalanceController.Stagger(def, C.StaggerTime, dir, "Block pushed through")
			end
			feedbackBoth(att, def, "AttackBlocked", "Blocked", info)
		end
		SoundFX.Play((outcome == "Parried" and "Parry") or ((outcome == "Glance" or outcome == "Overpowered") and "Clash") or "Block", h.Position)
		DebugService.Attr(att, "LastBlock", outcome .. " by " .. def.Name)
		DebugService.Attr(def, "LastBlock", string.format("%s q=%.2f p=%.1f", outcome, q, power))
		DebugService.Log(att.Name, "->", def.Name, outcome, "q", q, "power", power)
		return (outcome == "Glance" or outcome == "Overpowered") and "Continue" or "Stop"
	end

	-- blades met outside a guard
	if def.Attack.Stroke then
		SwordController.Bind(att)
		SwordController.Bind(def)
		deflect(att, -dir, C.DeflectDV * 0.8)
		deflect(def, dir, C.DeflectDV * 0.8)
		SwordController.Recoil(att, C.RecoilTime * BK.ClashRecoilMult)
		SwordController.Recoil(def, C.RecoilTime * BK.ClashRecoilMult)
		feedbackBoth(att, def, "Clash", "Clash", info)
		SoundFX.Play("Clash", h.Position)
		DebugService.Attr(att, "LastBlock", "Clash")
		DebugService.Attr(def, "LastBlock", "Clash")
		return "Stop"
	end
	if power > BK.Strength * 0.5 then
		deflect(def, dir, C.DeflectDV)
		stroke.EnergyMult *= BK.BeatEnergyMult
		stroke.GuardPassed[def.Id] = true
		feedbackBoth(att, def, "BladeBeaten", "BladeKnockedAside", info)
		SoundFX.Play("Clash", h.Position)
		DebugService.Attr(def, "LastBlock", "Blade beaten aside")
		return "Continue"
	end
	SwordController.Bind(att)
	deflect(att, -dir, C.DeflectDV * 0.6)
	SwordController.Recoil(att, C.RecoilTime * BK.ClashRecoilMult)
	feedbackBoth(att, def, "Clash", "Clash", info)
	SoundFX.Play("Clash", h.Position)
	return "Stop"
end

------------------------------------------------------------------ body contacts
local function react(att, target, h, dir, power, segName, strike)
	if target.Dead then
		return
	end
	local segDef = Anatomy.Segments[segName]
	local locMult = BL.LocationMult[segDef.BalanceClass] or 1
	local st = target.State
	local stateMult = (st == "Attacking" and BL.AttackingMult) or (st == "Blocking" and BL.BlockingMult)
		or ((st == "OffBalance" or st == "Staggered") and BL.OffBalanceMult) or 1
	local injuryMult = 1 + (1 - target.Caps.LegSupport) * 0.8
	local push = Util.unit(Util.flat(dir), Vector3.zAxis)

	-- bounded physical impulse on the struck segment
	if h.Part.Parent and Registry.FromPart(h.Part) == target then
		local dv = math.min(power * C.HitDVPerPower, C.MaxHitDV)
		Runtime.Impulse(h.Part, dir * dv * h.Part.AssemblyMass)
	end

	target.Balance -= power * BL.CostPerPower * locMult * stateMult * injuryMult
	local effective = power * locMult * injuryMult
	local reaction = "Flinch"
	if StateDefs.Ground[st] or st == "Recovering" then
		if st == "Recovering" and effective >= C.StaggerPower then
			StateMachine.Set(target, "Falling", "Hit while getting up")
			reaction = "Knocked back down"
		end
	elseif effective >= C.KnockdownPower or target.Balance <= 0 then
		BalanceController.KnockDown(target, push, power, "Knocked down")
		reaction = "Knockdown"
		Feedback.Send(target, "KnockedDown", {})
	elseif effective >= C.StaggerPower
		or (st == "Attacking" and (segDef.BalanceClass == "Arm" or segDef.BalanceClass == "Hand") and power >= C.ArmInterruptPower) then
		local dur = effective >= C.StaggerPower * 1.8 and C.HeavyStaggerTime or C.StaggerTime
		if st == "Attacking" then
			Feedback.Send(target, "Interrupted", { Segment = segName })
		end
		BalanceController.Stagger(target, dur, push, "Hit " .. segDef.Label)
		reaction = "Stagger"
	elseif target.Balance < BL.OffBalanceThreshold then
		BalanceController.OffBalance(target, push, "Hit " .. segDef.Label)
		reaction = "OffBalance"
	end
	return reaction
end

local function resolveBodyHit(att, target, h)
	local segName = h.Part:GetAttribute("Segment")
	local stroke = att.Attack.Stroke
	if not segName or not stroke then
		return "Continue"
	end
	local key = target.Id .. ":" .. segName
	if stroke.Hits[key] then
		return "Continue"
	end
	local now = Runtime.now()
	local last = att.Attack.SegmentHitTimes[key]
	stroke.Hits[key] = true
	if last and now - last < C.SegmentCooldown then
		return "Continue"
	end
	local ok, why = plausible(att, target, h)
	if not ok then
		DebugService.Hit("%s -> %s %s: rejected (%s)", att.Name, target.Name, segName, tostring(why))
		return "Continue"
	end
	att.Attack.SegmentHitTimes[key] = now

	local blade = att.Sword.Blade.CFrame
	local rel = h.PointVel - h.Part:GetVelocityAtPosition(h.Position)
	local speed = rel.Magnitude
	if speed < 1e-3 then
		DebugService.Hit("%s -> %s %s: no relative speed", att.Name, target.Name, segName)
		return "Continue"
	end
	local dir = rel / speed
	local power, commitment = strikePower(att, stroke, speed)
	local axial = dir:Dot(blade.YVector)
	local edgeDot = dir:Dot(blade.XVector)
	local kind, quality
	if axial > C.ThrustAxialDot and h.Sample >= HitDetection.SampleCount - 1 then
		kind = "Thrust"
		quality = 0.4 + 0.6 * math.clamp((axial - C.ThrustAxialDot) / (1 - C.ThrustAxialDot), 0, 1)
	elseif edgeDot > C.CutEdgeDot then
		kind = "Cut"
		quality = math.clamp((edgeDot - C.CutEdgeDot) / (0.85 - C.CutEdgeDot), 0.25, 1)
	else
		kind = "Blunt"
		quality = C.BluntQuality
	end

	DebugService.Marker(h.Position, Color3.fromRGB(255, 60, 40))
	DebugService.Attr(att, "LastContact", string.format("%s %s v=%.0f", target.Name, segName, speed))
	DebugService.Attr(att, "LastTargetSegment", segName)

	if power < C.MinDamagingPower then
		stroke.EnergyMult *= 0.9
		DebugService.Hit("%s -> %s %s: too weak to damage (power %.2f < %.2f, speed %.0f)", att.Name, target.Name, segName, power, C.MinDamagingPower, speed)
		Feedback.Send(att, "Contact", { Segment = segName })
		return "Continue"
	end

	DebugService.Hit("%s -> %s %s: %s power %.1f quality %.2f", att.Name, target.Name, segName, kind, power, quality)
	local strike = AnatomyService.ApplyStrike(target, {
		Segment = segName,
		Part = h.Part,
		Position = h.Position,
		Direction = dir,
		BladeAxis = blade.YVector,
		Power = power,
		Kind = kind,
		Quality = quality,
	})
	stroke.EnergyMult *= strike.EnergyRemaining
	BloodFX.WoundMark(target, h.Part, h.Position, h.Normal, strike.Damage / 40)
	if strike.Outcome ~= "Stopped" then
		BloodFX.Source(target, segName, h.Part, CFrame.new(h.Position))
		BloodFX.Burst(h.Part, h.Position, strike.Damage * 0.5)
	end

	local severed = nil
	if strike.SeverBoundary then
		local distal = Dismemberment.Sever(target, strike.SeverBoundary, dir, power)
		if distal then
			severed = strike.SeverBoundary
			AnatomyService.OnSevered(target, strike.SeverBoundary, distal)
		end
	end
	-- crippled sword hand loses the sword (also enforced every frame in Main)
	if target.Sword and target.Anatomy.Segments.RightHand.Integrity < Config.Anatomy.DisarmHandIntegrity then
		Dismemberment.DropSword(target, dir * 8)
	end

	local reaction = react(att, target, h, dir, power, segName, strike)
	local summary = string.format("%s p=%.1f q=%.2f c=%.2f %s%s -> %s", kind, power, quality, commitment, strike.Summary or "",
		severed and (" SEVERED " .. severed) or "", tostring(reaction))
	DebugService.Attr(target, "LastInjury", summary)
	DebugService.Log(att.Name, "hit", target.Name, summary)

	local fatal = AnatomyService.CheckFatal(target)
	-- one blade passing through a body touches several segments: one cut sound per attacker per
	-- HitSoundCooldown (a sever or decapitation still plays, it is the sound that matters)
	local hitSound = (severed == "NeckBase" or fatal == "Decapitated") and "Decapitation" or (severed and "Sever") or "Cut"
	local now2 = os.clock()
	if hitSound ~= "Cut" or now2 - (att.LastHitSound or 0) >= Config.Sounds.HitSoundCooldown then
		att.LastHitSound = now2
		SoundFX.Play(hitSound, h.Position)
	end
	if fatal and killFn then
		killFn(target, fatal, att)
	end

	DebugService.Hit("  -> %s, damage %.0f%s%s", tostring(strike.Outcome), strike.Damage or 0, severed and (", severed " .. severed) or "", fatal and (", fatal: " .. fatal) or "")
	local info = { Segment = segName, Label = Anatomy.Segments[segName].Label, Kind = kind, Power = math.floor(power * 10) / 10, Outcome = strike.Outcome, Severed = severed, Fatal = fatal }
	Feedback.Send(att, "Hit", info)
	Feedback.Send(target, "Hurt", info)
	return "Continue"
end

------------------------------------------------------------------ entry
-- no stroke open: the blade is only pushed, so it can bind against a blade but never strike
local function processPush(att, hits)
	for _, h in ipairs(hits) do
		local def = Registry.FromPart(h.Part)
		if def and def ~= att and not def.Dead and h.Part:GetAttribute("SwordPart") then
			local guarded = def.State == "Blocking" and def.Block.Active
			if (guarded or h.Part:GetAttribute("SwordPart") == "Blade") and SwordController.Bind(att) then
				if guarded then
					feedbackBoth(att, def, "AttackBlocked", "Blocked", {})
				else
					Feedback.Send(att, "Clash", {})
				end
				SoundFX.Play(guarded and "Block" or "Clash", h.Position)
				DebugService.Attr(att, "LastBlock", "Pushed into " .. def.Name)
			end
			return
		end
	end
end

function CombatResolver.Process(att, hits)
	if not att.Attack.Stroke then
		processPush(att, hits)
		return
	end
	for idx, h in ipairs(hits) do
		local stroke = att.Attack.Stroke
		if not stroke or att.Dead then
			return
		end
		local target = Registry.FromPart(h.Part)
		if target and target ~= att and not target.Dead then
			local result = "Continue"
			if h.Part:GetAttribute("SwordPart") then
				if not stroke.GuardPassed[target.Id] then
					result = resolveBladeContact(att, target, h)
				end
			else
				-- tolerance: a guard contact just after this body contact still intercepts it
				if not stroke.GuardPassed[target.Id] then
					for j = idx + 1, #hits do
						local g = hits[j]
						if g.T > h.T + C.GuardTimeTolerance then
							break
						end
						if g.Part:GetAttribute("SwordPart") and Registry.FromPart(g.Part) == target then
							result = resolveBladeContact(att, target, g)
							break
						end
					end
				end
				if result == "Continue" and att.Attack.Stroke then
					result = resolveBodyHit(att, target, h)
				end
			end
			if result == "Stop" then
				SwordController.EndStroke(att, "Stopped")
				return
			end
		end
	end
end

return CombatResolver
