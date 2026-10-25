--[[
	SwordController: turns the player's 2D combat cursor into a physically driven sword.

	Input mapping (all in upper-torso space, so the torso twist carries the sword):
	  cursor (u, v) on a unit disk, u = right, v = up.
	  ATTACK pose: grip moves across the body with the cursor; the blade points outward from the
	    body toward the cursor and forward, so sweeping the cursor sweeps the tip through an arc.
	    Centre of the disk = blade straight ahead and arms extended (thrust).
	  GUARD pose: the cursor picks the threatened side; the blade is laid ACROSS that line
	    (perpendicular to the radial direction) with the edge facing the threat.
	  EDGE: while swinging, the cutting edge turns to face the direction the cursor moves (rate
	    limited), so a deliberate stroke leads with the edge and a sloppy one hits with the flat.

	Smoothing/inertia: the server's controller cursor chases the client cursor with a gain, an
	acceleration limit and a hard speed cap (Config.Aim). The resulting target is applied through
	force/torque-limited AlignPosition/AlignOrientation with velocity caps, so the blade has mass,
	lag and limits; the client can never teleport it.

	Stroke tracking (post-physics): a stroke opens when the tip's speed relative to the pelvis
	exceeds StrokeStartSpeed while attacking, and closes when it slows, reverses sharply, the
	button is released (after a short follow-through) or the state changes. Hit deduplication and
	commitment are per stroke, so a resting blade can never deal damage.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.RagdollRonin
local Config = require(Shared.Config)
local Util = require(script.Parent.Util)
local DebugService = require(script.Parent.DebugService)

local SwordController = {}

local S = Config.Scale
local A = Config.Aim
local C = Config.Combat
local SHOULDER_R = Vector3.new(1.2, 0.5, 0) * S
local REACH_MAX = (1.05 + 1.425) * S * 0.98
local REACH_MIN = 0.55 * S
local DEFAULT_EDGE = Vector3.new(0, -1, 0)

function SwordController.Init(f)
	f.Aim = { U = A.ReadyU, V = A.ReadyV, VU = 0, VV = 0, Edge = DEFAULT_EDGE, Guard = 0 }
	f.Attack = {
		Phase = "Ready",
		Stroke = nil,
		StrokeCount = 0,
		RecoilUntil = 0,
		ReleaseTime = nil,
		FollowThrough = false,
		PrevBladeCF = nil,
		TipSpeed = 0,
		SegmentHitTimes = {},
	}
	f.Block = { Active = false, StartTime = 0 }
	f.Model:SetAttribute("AttackPhase", "Ready")
	f.Model:SetAttribute("HasSword", true)
end

------------------------------------------------------------------ pose mapping
local function attackPose(u, v)
	local r2 = math.min(1, u * u + v * v)
	local pos = Vector3.new(u * A.GripSpreadX, A.GripBaseY + v * A.GripSpreadY, -(A.GripDepth + A.ThrustDepth * (1 - r2))) * S
	local dir = Vector3.new(u * A.BladeOutward, v * A.BladeOutward + A.BladeLift, -1).Unit
	return pos, dir
end

local function guardPose(u, v)
	local r = math.sqrt(u * u + v * v)
	local ru, rv = 0, 1
	if r >= 0.2 then
		ru, rv = u / r, v / r
	end
	-- blade lies across the threatened line; prefer tip-up orientations
	local du, dv = -rv, ru
	if dv < -0.15 then
		du, dv = -du, -dv
	end
	local dir = Vector3.new(du, dv, -0.35).Unit
	local reach = math.clamp(r, 0.35, 1)
	local blockPoint = Vector3.new(ru * A.GuardRadius * reach, A.GuardBaseY + rv * A.GuardRadius * reach, -A.GuardDepth) * S
	local pos = blockPoint - dir * (Config.Sword.BladeLength * 0.45 + Config.Sword.HandleLength * 0.3)
	local edge = Vector3.new(ru, rv, -0.2)
	return pos, dir, edge
end

local function clampReach(pos)
	local d = pos - SHOULDER_R
	local m = d.Magnitude
	if m > REACH_MAX then
		return SHOULDER_R + d / m * REACH_MAX
	elseif m < REACH_MIN and m > 1e-4 then
		return SHOULDER_R + d / m * REACH_MIN
	end
	return pos
end

------------------------------------------------------------------ pre-physics: aim -> target
function SwordController.UpdateAim(f, dt, inp)
	local now = os.clock()
	local st = f.State
	local swordOK = f.Sword ~= nil and f.Caps.SwordArm > 0.05
	local mode = "Ready"
	if swordOK and st == "Attacking" then
		mode = "Attack"
	elseif swordOK and st == "Blocking" then
		mode = "Guard"
	end

	-- guard bookkeeping (parry timing starts when the guard is raised)
	local blocking = mode == "Guard"
	if blocking ~= f.Block.Active then
		f.Block.Active = blocking
		if blocking then
			f.Block.StartTime = now
		end
		if f.Sword then
			f.Sword.ParryZone.CanQuery = blocking
		end
	end

	-- release / follow-through
	local atk = f.Attack
	if inp.M1 and swordOK then
		atk.ReleaseTime = nil
	elseif atk.ReleaseTime == nil then
		atk.ReleaseTime = now
	end
	atk.FollowThrough = atk.Stroke ~= nil and atk.ReleaseTime ~= nil and (now - atk.ReleaseTime) < C.FollowThroughTime

	-- controller cursor chases the requested cursor with inertia and a speed cap
	local aim = f.Aim
	local tu, tv = A.ReadyU, A.ReadyV
	if mode ~= "Ready" then
		tu, tv = inp.AimU, inp.AimV
	end
	local du, dv = (tu - aim.U) * A.Gain, (tv - aim.V) * A.Gain
	local m = math.sqrt(du * du + dv * dv)
	if m > A.MaxSpeed then
		du, dv = du / m * A.MaxSpeed, dv / m * A.MaxSpeed
	end
	local k = math.min(1, A.Accel * dt)
	aim.VU += (du - aim.VU) * k
	aim.VV += (dv - aim.VV) * k
	aim.U += aim.VU * dt
	aim.V += aim.VV * dt
	local r = math.sqrt(aim.U * aim.U + aim.V * aim.V)
	if r > 1 then
		aim.U, aim.V = aim.U / r, aim.V / r
	end

	aim.Guard += ((blocking and 1 or 0) - aim.Guard) * math.min(1, A.GuardBlendRate * dt)

	local apos, adir = attackPose(aim.U, aim.V)
	local gpos, gdir, gedge = guardPose(aim.U, aim.V)
	local g = aim.Guard
	local pos = apos:Lerp(gpos, g)
	local dir = Util.unit(adir:Lerp(gdir, g), adir)

	local spd = math.sqrt(aim.VU * aim.VU + aim.VV * aim.VV)
	local wantEdge
	if mode == "Attack" and spd > A.EdgeMinSpeed then
		wantEdge = Vector3.new(aim.VU, aim.VV, 0) / spd
	elseif mode == "Ready" then
		wantEdge = DEFAULT_EDGE
	else
		wantEdge = aim.Edge
	end
	-- Guard: the edge's facing does not matter for a block, so choose the roll the sword arm can
	-- actually reach (the forearm runs opposite the edge in the grip): edge pointing away from
	-- the shoulder. Hysteresis prevents flip-flopping.
	if g > 0.5 then
		local toShoulder = Util.unit(SHOULDER_R - pos, Vector3.zAxis)
		local ge = Util.perpendicular(gedge.Unit, dir, gedge.Unit)
		local keep = aim.GuardFlip and -ge or ge
		local other = -keep
		if (-other):Dot(toShoulder) > (-keep):Dot(toShoulder) + 0.3 then
			aim.GuardFlip = not aim.GuardFlip
		end
		gedge = aim.GuardFlip and -ge or ge
	else
		aim.GuardFlip = false
	end
	wantEdge = Util.unit(wantEdge:Lerp(gedge.Unit, g), wantEdge)
	wantEdge = Util.perpendicular(wantEdge, dir, Util.perpendicular(DEFAULT_EDGE, dir, Vector3.xAxis))
	local cur = Util.perpendicular(aim.Edge, dir, wantEdge)
	aim.Edge = Util.rotateToward(cur, wantEdge, A.EdgeTurnRate * dt)
	local X = Util.perpendicular(aim.Edge, dir, wantEdge)

	pos = clampReach(pos)
	f.SwordTargetCF = CFrame.fromMatrix(pos, X, dir, X:Cross(dir))
end

------------------------------------------------------------------ strokes
function SwordController.StartStroke(f, dir)
	local atk = f.Attack
	atk.StrokeCount += 1
	atk.Stroke = {
		Id = atk.StrokeCount,
		Dir = dir,
		Start = os.clock(),
		Distance = 0,
		LowTime = 0,
		PeakSpeed = 0,
		Hits = {},
		GuardPassed = {},
		EnergyMult = 1,
	}
	return atk.Stroke
end

function SwordController.EndStroke(f, reason)
	local atk = f.Attack
	if atk and atk.Stroke then
		atk.Stroke = nil
		atk.LastStrokeEnd = reason
	end
end

function SwordController.Recoil(f, duration)
	SwordController.EndStroke(f, "Recoil")
	f.Attack.RecoilUntil = math.max(f.Attack.RecoilUntil, os.clock() + duration)
end

local function setPhase(f, phase)
	if f.Attack.Phase ~= phase then
		f.Attack.Phase = phase
		f.Model:SetAttribute("AttackPhase", phase)
	end
end

-- Post-physics. Returns sweep info {PrevCF, CF, Dt, Stroke} if the blade may strike this frame.
function SwordController.Track(f, dt, inp)
	local atk = f.Attack
	if not f.Sword then
		atk.Stroke = nil
		atk.PrevBladeCF = nil
		setPhase(f, "Unarmed")
		return nil
	end
	local cf = f.Sword.Blade.CFrame
	local prev = atk.PrevBladeCF
	atk.PrevBladeCF = cf
	if not prev or dt <= 0 then
		return nil
	end
	local tipLocal = f.Sword.TipLocal
	local tipVel = (cf:PointToWorldSpace(tipLocal) - prev:PointToWorldSpace(tipLocal)) / dt
	local rel = tipVel - f.Parts.LowerTorso.AssemblyLinearVelocity
	local speed = rel.Magnitude
	atk.TipSpeed = speed
	local now = os.clock()

	local canStrike = f.State == "Attacking" and now >= atk.RecoilUntil and f.Caps.SwordArm > 0.05
	local s = atk.Stroke
	if s then
		if not canStrike then
			SwordController.EndStroke(f, "State")
			s = nil
		else
			local dirNow = speed > 1e-3 and rel / speed or s.Dir
			s.Distance += speed * dt
			s.PeakSpeed = math.max(s.PeakSpeed, speed)
			s.LowTime = speed < C.StrokeEndSpeed and s.LowTime + dt or 0
			if s.LowTime > C.StrokeEndHold then
				SwordController.EndStroke(f, "Slowed")
				s = nil
			elseif speed > C.StrokeStartSpeed and dirNow:Dot(s.Dir) < C.ReversalDot then
				SwordController.EndStroke(f, "Reversal")
				s = SwordController.StartStroke(f, dirNow)
			elseif not inp.M1 and atk.ReleaseTime and now - atk.ReleaseTime > C.FollowThroughTime then
				SwordController.EndStroke(f, "Released")
				s = nil
			else
				s.Dir = Util.unit(s.Dir * 0.8 + dirNow * 0.2, s.Dir)
			end
		end
	elseif canStrike and inp.M1 and speed > C.StrokeStartSpeed then
		s = SwordController.StartStroke(f, rel / speed)
	end

	if now < atk.RecoilUntil then
		setPhase(f, "Recoil")
	elseif s then
		setPhase(f, "Swing")
	elseif f.State == "Attacking" then
		setPhase(f, "Guiding")
	elseif f.State == "Blocking" then
		setPhase(f, "Guard")
	else
		setPhase(f, "Ready")
	end

	if s then
		return { PrevCF = prev, CF = cf, Dt = dt, Stroke = s }
	end
	return nil
end

-- State listener: anything that takes the fighter out of Attacking ends the stroke
function SwordController.OnTransition(f, from, to)
	if to ~= "Attacking" then
		SwordController.EndStroke(f, "State:" .. to)
	end
	if to ~= "Blocking" and f.Block and f.Block.Active then
		f.Block.Active = false
		if f.Sword then
			f.Sword.ParryZone.CanQuery = false
		end
	end
end

return SwordController
