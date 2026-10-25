--[[
	SwordController: turns the player's 2D combat cursor into a physically driven sword.

	Input mapping (all in upper-torso space, so the torso twist carries the sword):
	  cursor (u, v) on a unit disk, u = right, v = up.
	  READY pose (no button): two-handed, hands low in front of the hips, blade angled up/forward.
	  ATTACK pose: grip moves across the body with the cursor; the blade points outward from the
	    body toward the cursor and forward, so sweeping the cursor sweeps the tip through an arc.
	    Centre of the disk = blade straight ahead and arms extended (thrust). Pushing the cursor to
	    the top draws the sword back over the head (blade behind the head), so dragging it down
	    from there is a full vertical cut. The upper diagonals raise the sword over that shoulder
	    and the lower diagonals finish at the opposite hip, so corner-to-corner is a diagonal cut.
	  GUARD pose: the cursor picks the threatened side; key poses (Config.Aim.GuardKeys) hold the
	    blade out beyond the body on that side with the edge facing the threat, e.g. flat across
	    above the head for an upward threat. Blades physically collide (SwordBuilder collider),
	    so a held guard stops a swing where they meet.
	  EDGE: while swinging, the cutting edge turns to face the direction the blade actually moves
	    (rate limited), so a deliberate stroke leads with the edge and a sloppy one hits with the
	    flat. While wound up overhead the edge already faces the coming downward cut.
	  BODY: hands and blade are kept out of the fighter's own torso/head (BodyShape).

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
local BodyShape = require(script.Parent.BodyShape)

local SwordController = {}

local S = Config.Scale
local A = Config.Aim
local C = Config.Combat
local SHOULDER_R = Vector3.new(1.2, 0.5, 0) * S
local REACH_MAX = (1.05 + 1.425) * S * 0.98
local REACH_MIN = 0.55 * S
local DEFAULT_EDGE = Vector3.new(0, -1, 0)

function SwordController.Init(f)
	f.Aim = { U = A.ReadyU, V = A.ReadyV, VU = 0, VV = 0, Edge = DEFAULT_EDGE, Guard = 0, Ready = 1 }
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
-- All pose functions return the grip position (scaled, upper-torso space) and blade direction.
local READY_POS = A.ReadyGrip * S
local READY_DIR = A.ReadyBlade.Unit
local WINDUP_DIR = A.WindupBlade.Unit
-- blade point whose motion defines "the direction the cut travels" (mid-blade toward the tip)
local CUT_POINT = Config.Sword.HandleLength * 0.25 + Config.Sword.BladeLength * 0.6

-- Key poses are authored unscaled in Config; angle 0 = cursor straight up, clockwise (u right)
local function scaledKey(k)
	return { Pos = k.Grip * S, Dir = k.Blade.Unit }
end
local GUARD_KEYS = {}
for i, k in ipairs(A.GuardKeys) do
	GUARD_KEYS[i] = scaledKey(k)
end
local GUARD_CENTER = scaledKey(A.GuardCenter)
local DIAGONALS = {}
for _, k in ipairs(A.DiagonalKeys) do
	local d = scaledKey(k)
	d.Angle = math.rad(k.Angle)
	d.Windup = k.Windup == true
	table.insert(DIAGONALS, d)
end

local function cursorAngle(u, v)
	return math.atan2(u, v) % (2 * math.pi)
end

-- Returns pos, dir and the windup weight (0 = normal attack pose, 1 = fully drawn back: overhead
-- or over a shoulder, where the edge should already face the coming cut).
local function attackPose(u, v)
	local r2 = math.min(1, u * u + v * v)
	-- cross-body poses (sword hand on the left) sit further out so the arm clears the chest
	local depth = A.GripDepth + A.ThrustDepth * (1 - r2) + A.CrossBodyDepth * math.max(0, -u)
	local spread = u * A.GripSpreadX * (u < 0 and A.CrossBodySpread or 1)
	local pos = Vector3.new(spread, A.GripBaseY + v * A.GripSpreadY, -depth) * S
	local dir = Vector3.new(u * A.BladeOutward, v * A.BladeOutward + A.BladeLift, -1).Unit
	-- above WindupStart the sword is drawn back over the head; the blade rotates through vertical,
	-- so sweeping the cursor down from the top is one continuous vertical cut
	local x = math.clamp((v - A.WindupStart) / (1 - A.WindupStart), 0, 1)
	if x > 0 then
		local grip = (A.WindupGrip + Vector3.new(u * A.WindupSpreadX, 0, 0)) * S
		local blade = Util.unit(WINDUP_DIR + Vector3.new(u * A.WindupBladeOutward, 0, 0), WINDUP_DIR)
		pos = pos:Lerp(grip, Util.smoothstep(x * A.WindupPosLead))
		dir = Util.slerpUnit(dir, blade, Util.smoothstep(x))
	end
	-- diagonals: sword raised over a shoulder, cut down across the body to the opposite hip
	local r = math.sqrt(r2)
	local wr = Util.smoothstep((r - A.DiagonalRimStart) / (1 - A.DiagonalRimStart))
	if wr > 0 then
		local ang = cursorAngle(u, v)
		for _, d in ipairs(DIAGONALS) do
			local off = math.abs(Util.angleDelta(ang, d.Angle))
			local w = Util.smoothstep(1 - off / math.rad(A.DiagonalWidth)) * wr
			if w > 0 then
				pos = pos:Lerp(d.Pos, w)
				dir = Util.slerpUnit(dir, d.Dir, w)
				if d.Windup then
					x = math.max(x, w)
				end
			end
		end
	end
	-- out at the rim (sides and above) the edge pre-aims at a cut back through the centre
	local prep = Util.smoothstep((r - A.RimPrepStart) / (1 - A.RimPrepStart)) * Util.smoothstep((v + 0.4) / 0.4)
	return pos, dir, math.max(x, prep)
end

-- Direction a point down the blade travels when the cursor moves along (du, dv): the edge leads it
local function cutDirection(u, v, du, dv, fallback)
	local m = math.sqrt(du * du + dv * dv)
	if m < 1e-6 then
		return fallback
	end
	local h = 0.03 / m
	local p0, d0 = attackPose(u, v)
	local p1, d1 = attackPose(u + du * h, v + dv * h)
	return Util.unit((p1 + d1 * CUT_POINT) - (p0 + d0 * CUT_POINT), fallback)
end

-- Guard: eight key poses around the disk (each held out beyond the body on its side so a real
-- swing meets the blade before the body), blended by cursor angle; near the centre they blend
-- into a central guard in front of the chin.
local function guardPose(u, v)
	local r = math.sqrt(u * u + v * v)
	local ru, rv = 0, 1
	if r >= 0.2 then
		ru, rv = u / r, v / r
	end
	local n = #GUARD_KEYS
	local a = cursorAngle(ru, rv) / (2 * math.pi) * n
	local i = math.floor(a)
	local t = Util.smoothstep(a - i)
	local k0, k1 = GUARD_KEYS[i % n + 1], GUARD_KEYS[(i + 1) % n + 1]
	local pos = k0.Pos:Lerp(k1.Pos, t)
	local dir = Util.slerpUnit(k0.Dir, k1.Dir, t)
	local w = Util.smoothstep((r - A.GuardRimStart) / (A.GuardRimFull - A.GuardRimStart))
	pos = GUARD_CENTER.Pos:Lerp(pos, w)
	dir = Util.slerpUnit(GUARD_CENTER.Dir, dir, w)
	-- the edge faces the threat (its roll is then chosen for reach in UpdateAim)
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

-- Keep the hands and blade out of the fighter's own torso and head (they do not collide with it)
local HAND_CLEARANCE = 0.24 * S
local BLADE_CLEARANCE = 0.1 * S
local BLADE_SAMPLES = {}
for k = 1, 6 do
	BLADE_SAMPLES[k] = Config.Sword.HandleLength * 0.25 + Config.Sword.BladeLength * (k - 0.5) / 6
end

local function clearBody(pos, dir)
	pos = BodyShape.PushOut(pos, HAND_CLEARANCE)
	for _ = 1, 4 do
		local worst, wn, wd = 0, nil, 0
		for _, t in ipairs(BLADE_SAMPLES) do
			local n, pen = BodyShape.Contact(pos + dir * t, BLADE_CLEARANCE)
			if n and pen > worst then
				worst, wn, wd = pen, n, t
			end
		end
		if not wn then
			break
		end
		-- tilt the blade so the deepest sample leaves the body
		dir = Util.unit(dir * wd + wn * (worst + 0.01), dir)
	end
	return pos, dir
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
	aim.Ready += ((mode == "Ready" and 1 or 0) - aim.Ready) * math.min(1, A.ReadyBlendRate * dt)

	local apos, adir, windup = attackPose(aim.U, aim.V)
	local gpos, gdir, gedge = guardPose(aim.U, aim.V)
	local g = aim.Guard
	local pos = apos:Lerp(gpos, g)
	local dir = Util.slerpUnit(adir, gdir, g)
	local ready = aim.Ready
	pos = pos:Lerp(READY_POS, ready)
	dir = Util.slerpUnit(dir, READY_DIR, ready)

	local spd = math.sqrt(aim.VU * aim.VU + aim.VV * aim.VV)
	local wantEdge
	if mode == "Attack" then
		wantEdge = spd > A.EdgeMinSpeed and cutDirection(aim.U, aim.V, aim.VU, aim.VV, aim.Edge) or aim.Edge
		if windup > 0 then
			-- while drawn back the edge already faces the coming cut (down through the centre of
			-- the disk; the spine leads the backswing), so the cut starts edge-first instead of
			-- turning the blade mid-swing
			local cut = cutDirection(aim.U, aim.V, -aim.U, -aim.V, wantEdge)
			wantEdge = Util.unit(wantEdge:Lerp(cut, Util.smoothstep(windup * 2)), cut)
		end
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
	wantEdge = Util.unit(wantEdge:Lerp(DEFAULT_EDGE, ready), wantEdge)

	pos = clampReach(pos)
	pos, dir = clearBody(pos, dir)
	wantEdge = Util.perpendicular(wantEdge, dir, Util.perpendicular(DEFAULT_EDGE, dir, Vector3.xAxis))
	local cur = Util.perpendicular(aim.Edge, dir, wantEdge)
	aim.Edge = Util.rotateToward(cur, wantEdge, A.EdgeTurnRate * dt)
	local X = Util.perpendicular(aim.Edge, dir, wantEdge)

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
