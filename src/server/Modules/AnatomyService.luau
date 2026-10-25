--[[
	AnatomyService: the authoritative injury model (server only). No global health value exists.

	Per fighter:
	  Segments[name] = { Integrity 0..100, Bleeding ml/s, Severed, Lost, Functional, Wound }
	  Organs[name]   = { Health 0..100, Destroyed }
	  Blood (ml), BleedRate, Stumps (boundary -> ml/s), Incapacitated, PendingDeath

	Penetration model (ApplyStrike):
	  drive  = power * quality * KindPenetration[kind]
	  resist = segment.Resistance * (0.35 + 0.65 * integrity)      -- damaged tissue resists less
	  drive <= resist      -> "Stopped": the outer structure stops the blade (reduced surface damage)
	  otherwise depth = (drive - resist) * DepthPerPower, capped by segment thickness
	  The wound channel is the segment from the contact point along the blade's relative motion
	  (cuts) or along the blade axis (thrusts). An organ is hit only if that channel geometrically
	  passes within organ radius + blade half width of the organ centre.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.RagdollRonin
local Config = require(Shared.Config)
local Anatomy = require(Shared.Anatomy)
local Util = require(script.Parent.Util)

local AnatomyService = {}
local S = Config.Scale

function AnatomyService.Create(f)
	local A = {
		Segments = {},
		Organs = {},
		Blood = Config.Blood.Max,
		BleedRate = 0,
		Stumps = {},
		Incapacitated = false,
		PendingDeath = nil,
		InjuryLog = {},
	}
	for name in pairs(Anatomy.Segments) do
		A.Segments[name] = { Integrity = 100, Bleeding = 0, Severed = false, Lost = false, Functional = true, Wound = 0 }
	end
	for _, o in ipairs(Anatomy.Organs) do
		A.Organs[o.Name] = { Health = 100, Destroyed = false }
	end
	f.Anatomy = A
	AnatomyService.UpdateCaps(f)
end

local function segFactor(rec)
	if rec.Severed then
		return 0
	end
	return math.clamp(rec.Integrity / 100 + 0.15, 0, 1)
end

-- Derive physical capabilities from injuries. Called after every injury and bleed tick.
function AnatomyService.UpdateCaps(f)
	local A = f.Anatomy
	local seg = A.Segments
	local function leg(side)
		local th, sh, ft = seg[side .. "Thigh"], seg[side .. "Shin"], seg[side .. "Foot"]
		if th.Severed or sh.Severed then
			return 0
		end
		local v = segFactor(th) * 0.5 + segFactor(sh) * 0.35 + (ft.Lost and 0 or segFactor(ft)) * 0.15
		if ft.Lost then
			v *= 0.55
		end
		if not th.Functional or not sh.Functional then
			v *= 0.4
		end
		return v
	end
	local function arm(side)
		local ua, fa, h = seg[side .. "UpperArm"], seg[side .. "Forearm"], seg[side .. "Hand"]
		if ua.Severed or fa.Severed or h.Severed then
			return 0
		end
		local v = segFactor(ua) * 0.4 + segFactor(fa) * 0.35 + segFactor(h) * 0.25
		if not ua.Functional or not fa.Functional then
			v *= 0.3
		end
		return v
	end
	local B = Config.Blood
	local bloodFrac = A.Blood / B.Max
	local bloodStrength = bloodFrac >= B.WeakAt and 1 or (bloodFrac >= B.VeryWeakAt and 0.8 or 0.6)
	local lungsOk = 0
	for _, n in ipairs({ "LungL", "LungR" }) do
		if A.Organs[n].Health > Anatomy.LungFailure.Threshold then
			lungsOk += 1
		end
	end
	local breath = lungsOk == 2 and 1 or (lungsOk == 1 and 0.65 or 0.3)
	local torso = math.min(segFactor(seg.UpperTorso), segFactor(seg.LowerTorso))
	local legL, legR = leg("Left"), leg("Right")
	local legSupport = (legL + legR) / 2
	local swordArm = arm("Right")
	local offArm = arm("Left")
	local hand = seg.RightHand
	local grip = hand.Severed and 0 or (0.3 + 0.7 * segFactor(hand))
	if offArm > 0.3 then
		grip = math.min(1, grip + 0.15) -- two-handed grip steadies the blade
	end

	local caps = f.Caps or {}
	caps.LegLeft, caps.LegRight = legL, legR
	caps.LegSupport = legSupport
	caps.SwordArm = swordArm
	caps.OffArm = offArm
	caps.Grip = grip
	caps.BloodStrength = bloodStrength
	caps.Breath = breath
	caps.Strength = bloodStrength * (0.6 + 0.4 * torso) * math.sqrt(breath)
	caps.Move = math.pow(legSupport, 1.3) * bloodStrength * (0.6 + 0.4 * segFactor(seg.LowerTorso))
	caps.Stability = (0.35 + 0.65 * legSupport) * bloodStrength
	caps.BalanceRegen = breath * bloodStrength * (0.5 + 0.5 * segFactor(seg.LowerTorso))
	caps.BalanceMax = 0.5 + 0.5 * legSupport
	caps.Kneeling = legSupport < Config.Movement.KneelLegSupport
	f.Caps = caps

	local incapacitated = bloodFrac < B.Incapacitated or A.PendingDeath ~= nil or A.Organs.Brain.Health < 60
	A.Incapacitated = incapacitated
end

function AnatomyService.SegmentFactor(f, segName)
	local rec = f.Anatomy.Segments[segName]
	return rec and segFactor(rec) or 0
end

local function damageOrgan(f, organName, amount, results)
	local o = f.Anatomy.Organs[organName]
	if not o or o.Destroyed or amount <= 0 then
		return
	end
	o.Health = math.max(0, o.Health - amount)
	if o.Health <= 0 then
		o.Destroyed = true
	end
	table.insert(results, { Name = organName, Damage = amount, Health = o.Health })
end

local function nearestBoundary(f, segDef, position)
	if not segDef.Boundaries then
		return nil
	end
	local best, bestDist
	for _, bName in ipairs(segDef.Boundaries) do
		local j = f.Joints[bName]
		local parent = j and f.Parts[j.ParentName]
		if j and not j.Severed and parent and f.Parts[j.ChildName] then
			local pivot = parent.CFrame:PointToWorldSpace(j.PivotLocal)
			local d = (pivot - position).Magnitude
			if not bestDist or d < bestDist then
				best, bestDist = bName, d
			end
		end
	end
	return best
end

--[[
	strike = { Segment, Part, Position, Direction (unit relative motion), BladeAxis, Power, Kind, Quality }
	returns { Outcome, Damage, Depth, Organs = {...}, SeverBoundary, EnergyRemaining }
]]
function AnatomyService.ApplyStrike(f, strike)
	local C = Config.Anatomy
	local A = f.Anatomy
	local segDef = Anatomy.Segments[strike.Segment]
	local rec = A.Segments[strike.Segment]
	local result = { Outcome = "None", Damage = 0, Depth = 0, Organs = {}, EnergyRemaining = 1 }
	if not segDef or not rec then
		return result
	end

	local integrity = rec.Integrity / 100
	local resist = segDef.Resistance * (0.35 + 0.65 * integrity)
	local effPower = strike.Power * strike.Quality
	local drive = effPower * C.KindPenetration[strike.Kind]
	local damage = effPower * C.KindDamage[strike.Kind] * C.DamagePerPower
	local depth = 0
	if drive <= resist then
		result.Outcome = "Stopped"
		damage *= C.StoppedDamageMult
	else
		depth = math.min((drive - resist) * C.DepthPerPower * S, segDef.Thickness * S * 1.15)
		result.Outcome = "Wound"
	end
	rec.Integrity = math.max(0, rec.Integrity - damage)
	rec.Wound = math.max(rec.Wound, damage)
	local bleed = damage * C.BleedPerDamage * segDef.BleedFactor * C.KindBleed[strike.Kind]
	if result.Outcome == "Stopped" then
		bleed *= 0.3
	end
	rec.Bleeding += bleed

	-- organ penetration: geometric test of the wound channel against organ spheres
	if depth > 0 then
		local channelDir = (strike.Kind == "Thrust") and strike.BladeAxis or strike.Direction
		local a = strike.Position
		local b = a + channelDir * depth
		for _, o in ipairs(Anatomy.OrgansBySegment[strike.Segment] or {}) do
			local part = f.Parts[o.Part]
			if part then
				local c = part.CFrame:PointToWorldSpace(o.Offset * S)
				local dist = (c - Util.closestPointOnSegment(c, a, b)).Magnitude
				local reach = o.Radius * S + C.BladeHalfWidth
				if dist <= reach then
					local overlap = 1 - 0.5 * dist / reach
					local dmg = C.OrganDamagePerPower * (drive - resist) * overlap * (strike.Kind == "Thrust" and 1.25 or 1)
					damageOrgan(f, o.Name, dmg, result.Organs)
				end
			end
		end
		if #result.Organs > 0 then
			result.Outcome = "Penetrating"
		end
	end

	-- blunt trauma to the skull bruises the brain without penetration
	if strike.Kind == "Blunt" and strike.Segment == "Head" and strike.Power > C.ConcussionPower then
		damageOrgan(f, "Brain", (strike.Power - C.ConcussionPower) * C.ConcussionDamage, result.Organs)
	end

	rec.Functional = not rec.Severed and rec.Integrity > C.DisableBelow

	-- severing: only edge-aligned cuts; existing damage lowers the threshold
	if strike.Kind == "Cut" and segDef.SeverPower then
		local w = C.SeverIntegrityWeight
		local threshold = segDef.SeverPower * ((1 - w) + w * rec.Integrity / 100)
		if effPower >= threshold or rec.Integrity <= 0 then
			result.SeverBoundary = nearestBoundary(f, segDef, strike.Position)
		end
	end

	result.Damage = damage
	result.Depth = depth
	-- energy the blade keeps after this contact (passing through tissue/bone costs momentum)
	local E = C.EnergyRemaining
	result.EnergyRemaining = result.SeverBoundary and E.Severed or (result.Outcome == "Stopped" and E.Stopped or E.Wound)

	local organNames = {}
	for _, o in ipairs(result.Organs) do
		table.insert(organNames, o.Name)
	end
	local entry = string.format("%s %s %s dmg=%.0f depth=%.2f%s", segDef.Label, strike.Kind, result.Outcome, damage, depth,
		#organNames > 0 and (" organs=" .. table.concat(organNames, "+")) or "")
	table.insert(A.InjuryLog, entry)
	if #A.InjuryLog > 12 then
		table.remove(A.InjuryLog, 1)
	end
	result.Summary = entry

	AnatomyService.EvaluateVitals(f)
	AnatomyService.UpdateCaps(f)
	f.AnatomyDirty = true
	return result
end

-- Called by Dismemberment after parts physically separate. distalParts: set of part names.
function AnatomyService.OnSevered(f, boundaryName, distalParts)
	local A = f.Anatomy
	local jd = Anatomy.JointByName[boundaryName]
	for segName, partNames in pairs(Anatomy.SegmentParts) do
		local gone, total = 0, #partNames
		for _, pn in ipairs(partNames) do
			if distalParts[pn] then
				gone += 1
			end
		end
		if gone > 0 then
			local rec = A.Segments[segName]
			rec.Severed = true
			rec.Functional = false
			if gone == total then
				rec.Lost = true
				rec.Bleeding = 0 -- the bleeding is now the stump's
			end
		end
	end
	-- organs inside lost parts are gone
	for _, o in ipairs(Anatomy.Organs) do
		if distalParts[o.Part] then
			local rec = A.Organs[o.Name]
			rec.Health = 0
			rec.Destroyed = true
		end
	end
	-- a cut boundary that crosses major vessels bleeds heavily
	A.Stumps[boundaryName] = { Rate = jd and jd.StumpBleed or 40 }
	table.insert(A.InjuryLog, "SEVERED at " .. ((jd and jd.Label) or boundaryName))
	AnatomyService.EvaluateVitals(f)
	AnatomyService.UpdateCaps(f)
	f.AnatomyDirty = true
end

-- Organ rules that kill after a delay (heart, lungs) schedule PendingDeath and incapacitate.
function AnatomyService.EvaluateVitals(f)
	local A = f.Anatomy
	if A.PendingDeath then
		return
	end
	local now = os.clock()
	for _, o in ipairs(Anatomy.Organs) do
		local rule = o.Lethal
		if rule and rule.Delay > 0 and A.Organs[o.Name].Health <= rule.Threshold then
			A.PendingDeath = { At = now + rule.Delay, Reason = o.Label .. " destroyed" }
			return
		end
	end
	local lf = Anatomy.LungFailure
	if A.Organs.LungL.Health <= lf.Threshold and A.Organs.LungR.Health <= lf.Threshold then
		A.PendingDeath = { At = now + lf.Delay, Reason = "Respiratory failure (both lungs)" }
	end
end

-- Returns a death reason if the fighter must die now, else nil.
function AnatomyService.CheckFatal(f)
	local A = f.Anatomy
	if A.Segments.Neck.Severed or A.Segments.Head.Lost then
		return "Decapitated"
	end
	for _, o in ipairs(Anatomy.Organs) do
		local rule = o.Lethal
		if rule and rule.Delay == 0 and A.Organs[o.Name].Health <= rule.Threshold then
			return o.Label .. " destroyed"
		end
	end
	if A.Segments.Neck.Integrity <= 0 then
		return "Neck destroyed (spinal cord severed)"
	end
	if A.Blood / Config.Blood.Max <= Config.Blood.Lethal then
		return "Blood loss"
	end
	if A.PendingDeath and os.clock() >= A.PendingDeath.At then
		return A.PendingDeath.Reason
	end
	return nil
end

-- Compact snapshot for the owning client's anatomy UI
function AnatomyService.Snapshot(f)
	local A = f.Anatomy
	local segs = {}
	for name, rec in pairs(A.Segments) do
		segs[name] = {
			i = math.floor(rec.Integrity + 0.5),
			b = math.floor(rec.Bleeding * 10) / 10,
			s = rec.Severed,
			l = rec.Lost,
			f = rec.Functional,
		}
	end
	local organs = {}
	for name, rec in pairs(A.Organs) do
		organs[name] = math.floor(rec.Health + 0.5)
	end
	local stumps = 0
	for _ in pairs(A.Stumps) do
		stumps += 1
	end
	return {
		Seg = segs,
		Org = organs,
		Blood = math.floor(A.Blood),
		BloodMax = Config.Blood.Max,
		Rate = math.floor(A.BleedRate * 10) / 10,
		State = f.State,
		Inc = A.Incapacitated,
		Pending = A.PendingDeath and A.PendingDeath.Reason or nil,
		Death = f.DeathReason,
		Legs = math.floor((f.Caps.LegSupport or 0) * 100) / 100,
		Arm = math.floor((f.Caps.SwordArm or 0) * 100) / 100,
		Sword = f.Sword ~= nil,
		Log = { table.unpack(A.InjuryLog, math.max(1, #A.InjuryLog - 3)) },
	}
end

return AnatomyService
