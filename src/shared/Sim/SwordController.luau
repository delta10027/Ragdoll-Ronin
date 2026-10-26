--[[
	SwordController: turns the player's 2D combat cursor into a physically driven sword.

	Input mapping (all in upper-torso space, so the torso twist carries the sword):
	  cursor (u, v) on a unit disk, u = right, v = up.
	  READY pose (no button): two-handed, hands low in front of the hips, blade angled up/forward.
	  ATTACK pose: out at the rim of the disk the sword is drawn back (or finished) like a real
	    katana cut: overhead at the top, hasso by the shoulder at the upper diagonals, wound up over
	    the shoulder at the sides, finished at the hip / low in front below (Config.Aim.AttackKeys).
	    The centre of the disk is blade straight ahead with the arms extended (thrust). Toward the
	    centre the blade turns from the rim key to straight ahead, so dragging the cursor across
	    the disk through the middle is one cut: top to bottom a vertical cut, top-right to
	    bottom-left a shoulder-to-hip kesa cut, right to left a horizontal cut. Every key also turns
	    the body (waist and hips), so wide cuts wind up and follow through with the whole torso.
	  GUARD pose: the cursor picks the threatened side; key poses (Config.Aim.GuardKeys) hold the
	    blade out beyond the body on that side with the edge facing the threat: flat across above
	    the head for an upward threat, upright beside the body for the sides. Blades physically
	    collide (SwordBuilder collider), so a held guard stops a swing where they meet.
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
local Runtime = require(script.Parent.Runtime)
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
	f.Aim = { U = A.ReadyU, V = A.ReadyV, VU = 0, VV = 0, Edge = DEFAULT_EDGE, Guard = 0, Ready = 1, Twist = 0 }
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
-- blade point whose motion defines "the direction the cut travels" (mid-blade toward the tip)
local CUT_POINT = Config.Sword.HandleLength * 0.25 + Config.Sword.BladeLength * 0.6

-- Key poses are authored unscaled in Config; angle 0 = cursor straight up, clockwise (u right)
local function scaledKey(k)
	local key = { Pos = k.Grip * S, Dir = k.Blade.Unit, Twist = k.Twist or 0 }
	if k.Edge then
		-- full blade orientation (X = edge, Y = blade), so guards blend as one rotation
		local e = Util.perpendicular(k.Edge, key.Dir, Vector3.xAxis)
		key.Rot = CFrame.fromMatrix(Vector3.zero, e, key.Dir, e:Cross(key.Dir))
	end
	return key
end
local GUARD_KEYS = {}
for i, k in ipairs(A.GuardKeys) do
	GUARD_KEYS[i] = scaledKey(k)
end
local GUARD_CENTER = scaledKey(A.GuardCenter)
local ATTACK_KEYS = {}
for i, k in ipairs(A.AttackKeys) do
	local key = scaledKey(k)
	key.Windup = k.Windup or 0
	ATTACK_KEYS[i] = key
end
local ATTACK_CENTER = scaledKey(A.AttackCenter)

local function cursorAngle(u, v)
	return math.atan2(u, v) % (2 * math.pi)
end

-- Returns pos, dir, the windup weight (0 = normal attack pose, 1 = fully drawn back, where the
-- edge should already face the coming cut) and the body twist.
local function attackPose(u, v)
	local r = math.min(1, math.sqrt(u * u + v * v))
	-- rim pose: the two neighbouring keys, blended by cursor angle. Eased like the guard keys, so
	-- most of each 45 degree slice holds close to its key pose (the wind-ups and finishes are
	-- consistent even when the cursor is a little off) and the in-between poses are only passed
	-- through quickly
	local n = #ATTACK_KEYS
	local a = cursorAngle(u, v) / (2 * math.pi) * n
	local i = math.floor(a)
	local t = Util.smoothstep(a - i)
	local k0, k1 = ATTACK_KEYS[i % n + 1], ATTACK_KEYS[(i + 1) % n + 1]
	local rimPos = k0.Pos:Lerp(k1.Pos, t)
	local rimDir = Util.slerpUnit(k0.Dir, k1.Dir, t)
	-- toward the centre the blade turns (along the shortest arc, which is the plane of the cut)
	-- to straight ahead; the hands lead, so a cut from a windup swings the blade over first
	local w = math.min(1, r / A.AttackRimFull)
	local pos = ATTACK_CENTER.Pos:Lerp(rimPos, Util.smoothstep(w * A.AttackPosLead))
	local dir = Util.slerpUnit(ATTACK_CENTER.Dir, rimDir, w)
	local prep = Util.smoothstep((r - A.RimPrepStart) / (1 - A.RimPrepStart))
	local windup = (k0.Windup + (k1.Windup - k0.Windup) * t) * prep
	local twist = (k0.Twist + (k1.Twist - k0.Twist) * t) * w
	return pos, dir, windup, twist
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
	-- blade direction and edge blend together as one rotation: blending them separately lets the
	-- edge pass through zero (and snap the blade over) when the blade turns a lot between keys
	local pos = k0.Pos:Lerp(k1.Pos, t)
	local rot = k0.Rot:Lerp(k1.Rot, t)
	local twist = k0.Twist + (k1.Twist - k0.Twist) * t
	local w = Util.smoothstep((r - A.GuardRimStart) / (A.GuardRimFull - A.GuardRimStart))
	pos = GUARD_CENTER.Pos:Lerp(pos, w)
	rot = GUARD_CENTER.Rot:Lerp(rot, w)
	twist = GUARD_CENTER.Twist + (twist - GUARD_CENTER.Twist) * w
	return pos, rot.UpVector, rot.RightVector, twist
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
	local now = Runtime.now()
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
		if f.Sword and f.Sword.ParryZone then
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
	-- (strokes are tracked on the server only; a predicting client knows one is open via StrokeActive)
	local stroking = atk.Stroke ~= nil or atk.StrokeActive == true
	atk.FollowThrough = stroking and atk.ReleaseTime ~= nil and (now - atk.ReleaseTime) < C.FollowThroughTime

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
	-- the cursor waits for the sword target: the hand drive's target turns toward the requested
	-- pose at a capped rate (MotorController, f.SwordAimDir), so when the cursor runs far ahead of it, cursor motion
	-- that would add to the gap slows and finally stops until the target catches up (moving back
	-- toward it is never held). The target always catches up, so this cannot deadlock; keeping the
	-- gap small means the hand drive's short way round is always the right way.
	local follow = 1
	if mode ~= "Ready" and f.Sword and f.SwordAimDir then
		local pose = mode == "Guard" and guardPose or attackPose
		local blade = f.SwordAimDir.Unit
		local function lagAt(u, v)
			local _, d = pose(u, v)
			return math.acos(math.clamp(blade:Dot(d), -1, 1))
		end
		local lagNew = lagAt(aim.U + aim.VU * dt, aim.V + aim.VV * dt)
		if lagNew > lagAt(aim.U, aim.V) then
			follow = 1 - Util.smoothstep((lagNew - A.LagSlowStart) / (A.LagStop - A.LagSlowStart))
		end
	end
	aim.U += aim.VU * dt * follow
	aim.V += aim.VV * dt * follow
	local r = math.sqrt(aim.U * aim.U + aim.V * aim.V)
	if r > 1 then
		aim.U, aim.V = aim.U / r, aim.V / r
	end

	aim.Guard += ((blocking and 1 or 0) - aim.Guard) * math.min(1, A.GuardBlendRate * dt)
	aim.Ready += ((mode == "Ready" and 1 or 0) - aim.Ready) * math.min(1, A.ReadyBlendRate * dt)

	local apos, adir, windup, atwist = attackPose(aim.U, aim.V)
	local gpos, gdir, gedge, gtwist = guardPose(aim.U, aim.V)
	local g = aim.Guard
	local pos = apos:Lerp(gpos, g)
	local dir = Util.slerpUnit(adir, gdir, g)
	local ready = aim.Ready
	pos = pos:Lerp(READY_POS, ready)
	dir = Util.slerpUnit(dir, READY_DIR, ready)
	-- body twist for MotorController (derived each step from the cursor, so it needs no rollback state)
	aim.Twist = (atwist + (gtwist - atwist) * g) * (1 - ready)

	local spd = math.sqrt(aim.VU * aim.VU + aim.VV * aim.VV)
	local wantEdge
	if mode == "Attack" then
		-- at rest (no windup) the edge settles to face away from the body instead of keeping whatever
		-- it had: the forearm then points outward with the elbow between body and hand, and the edge
		-- can never end up facing the fighter (e.g. after a vertical cut)
		local mid = pos + dir * CUT_POINT
		local rest = Util.perpendicular(Util.unit(mid, dir), dir, Util.perpendicular(DEFAULT_EDGE, dir, Vector3.xAxis))
		wantEdge = spd > A.EdgeMinSpeed and cutDirection(aim.U, aim.V, aim.VU, aim.VV, aim.Edge) or rest
		if windup > 0 then
			-- while drawn back the edge already faces the coming cut (back through the centre of
			-- the disk; the spine leads the backswing), so the cut starts edge-first. Rolled about
			-- the blade axis: the two directions are often opposite, and blending opposite
			-- vectors passes through zero and snaps the blade over.
			-- Measured just inside the rim: out there the pose no longer changes with the radius, so
			-- the cut direction would be undefined and the edge would keep whatever roll it had
			-- (e.g. facing down, which swings the elbow up over the shoulder).
			local rr = math.sqrt(aim.U * aim.U + aim.V * aim.V)
			local inner = rr > 1e-3 and math.min(1, A.AttackRimFull * 0.9 / rr) or 1
			local cut = cutDirection(aim.U * inner, aim.V * inner, -aim.U, -aim.V, wantEdge)
			wantEdge = Util.rollToward(wantEdge, cut, dir, Util.smoothstep(windup * 2))
		end
	elseif mode == "Ready" then
		wantEdge = DEFAULT_EDGE
	else
		wantEdge = aim.Edge
	end
	-- (guard edges come from the guard keys: a block does not care which way the edge faces, so each
	-- key uses the roll the arms reach most comfortably and the guard never spins the sword)
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
		Start = Runtime.now(),
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
	f.Attack.RecoilUntil = math.max(f.Attack.RecoilUntil, Runtime.now() + duration)
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
	local now = Runtime.now()

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
		if f.Sword and f.Sword.ParryZone then
			f.Sword.ParryZone.CanQuery = false
		end
	end
end

return SwordController
