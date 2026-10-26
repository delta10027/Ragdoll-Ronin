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
	    collide (SwordBuilder collider), and an attack that meets a guard or blade is BOUND
	    (SwordController.Bind): its cursor stops where they met and can only be drawn back, so a
	    blocked cut has to be pulled out (or M1 released) before the sword can go anywhere else.
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
local Draw = require(script.Parent.Draw)

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
-- while kicking the sword is held up in guard, clear of the rising knee (Config.Kick)
local KICK_POS = Config.Kick.HandsGrip * S
local KICK_DIR = Config.Kick.HandsBlade.Unit
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
	Draw.Input(f, inp) -- 1: draw / sheathe (animated, Shared.Sim.Draw)
	local swordOK = f.Sword ~= nil and not f.Sheathed and not f.DrawKind and f.Caps.SwordArm > 0.05
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
	-- a blocked attack is bound to the blade it met (SwordController.Bind): the cursor cannot push
	-- on, only draw back, until the fighter retreats far enough, lets go of M1 or changes stance
	local bind = aim.Bind
	if bind then
		local back = -((aim.U - bind.U) * bind.DU + (aim.V - bind.V) * bind.DV)
		if mode ~= "Attack" or not inp.M1 or back >= A.BindRelease then
			aim.Bind = nil
		else
			aim.U, aim.V = SwordController.ConstrainCursor(aim.U, aim.V, bind)
			local push = aim.VU * bind.DU + aim.VV * bind.DV
			if push > 0 then
				aim.VU -= push * bind.DU
				aim.VV -= push * bind.DV
			end
		end
	end

	aim.Guard += ((blocking and 1 or 0) - aim.Guard) * math.min(1, A.GuardBlendRate * dt)
	aim.Ready += ((mode == "Ready" and 1 or 0) - aim.Ready) * math.min(1, A.ReadyBlendRate * dt)

	local apos, adir, windup, atwist = attackPose(aim.U, aim.V)
	local gpos, gdir, gedge, gtwist = guardPose(aim.U, aim.V)
	local g = aim.Guard
	local pos = apos:Lerp(gpos, g)
	local dir = Util.slerpUnit(adir, gdir, g)
	local ready = aim.Ready
	local kicking = st == "Kicking"
	pos = pos:Lerp(kicking and KICK_POS or READY_POS, ready)
	dir = Util.slerpUnit(dir, kicking and KICK_DIR or READY_DIR, ready)
	-- body twist for MotorController (derived each step from the cursor, so it needs no rollback state)
	aim.Twist = (atwist + (gtwist - atwist) * g) * (1 - ready)

	local spd = math.sqrt(aim.VU * aim.VU + aim.VV * aim.VV)
	local wantEdge
	if mode == "Attack" then
		-- at rest (no windup) the edge settles onto the underside of the blade - the side a finished
		-- cut was travelling - instead of keeping whatever it had. ("Away from the body" was tried and
		-- is ill-defined at the finishes, where the blade itself points away from the body: it flipped
		-- the edge up toward the fighter at the bottom of a downward cut.)
		local rest = Util.perpendicular(DEFAULT_EDGE, dir, Util.perpendicular(Vector3.new(0, 0, -1), dir, Vector3.xAxis))
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

	local target = CFrame.fromMatrix(pos, X, dir, X:Cross(dir))
	if f.DrawKind then
		-- drawing / sheathing: the scripted path (it runs along the scabbard, so no body clearance)
		target = Draw.Pose(f, dt, target)
		aim.Edge = target.RightVector
	else
		f.DrawPose = nil
	end
	f.SwordTargetCF = target
end

------------------------------------------------------------------ bind (blocked attacks)
-- Where a bound cursor may be: behind the point the attack was stopped at (along the direction it
-- was travelling), with a little sideways slack that widens the further it is drawn back.
-- Shared with the client, which holds its own cursor the same way so the circle shows the stop.
function SwordController.ConstrainCursor(u, v, bind)
	local du, dv = u - bind.U, v - bind.V
	local s = math.min(0, du * bind.DU + dv * bind.DV)
	local p = du * -bind.DV + dv * bind.DU
	local slack = A.BindSlack - s
	p = math.clamp(p, -slack, slack)
	return bind.U + bind.DU * s - bind.DV * p, bind.V + bind.DV * s + bind.DU * p
end

-- Server: the attack met a guard or another blade. The cursor is pulled back to the pose that
-- matches where the blade actually is (the cursor and the sword target run ahead of the physical
-- blade), plus a small rebound, and held there (UpdateAim). Returns true when newly bound.
function SwordController.Bind(f)
	local aim = f.Aim
	if aim.Bind or f.State ~= "Attacking" then
		return false
	end
	local du, dv = aim.VU, aim.VV
	local m = math.sqrt(du * du + dv * dv)
	if m < A.BindMinSpeed then
		-- barely moving: the push is taken to be toward the centre of the disk (through the cut)
		du, dv = -aim.U, -aim.V
		m = math.sqrt(du * du + dv * dv)
	end
	if m < 1e-3 then
		du, dv, m = 0, -1, 1
	end
	du, dv = du / m, dv / m
	-- walk back along the travel direction to the pose closest to the physical blade
	local u, v = aim.U, aim.V
	local ut = f.Parts.UpperTorso
	if f.Sword and ut then
		local blade = ut.CFrame:VectorToObjectSpace(f.Sword.Handle.CFrame.YVector)
		local best, bestDot = 0, -2
		for k = 0, 30 do
			local s = k * 0.05
			local _, d = attackPose(aim.U - du * s, aim.V - dv * s)
			local dot = d:Dot(blade)
			if dot > bestDot + 1e-4 then
				best, bestDot = s, dot
			elseif dot < bestDot - 0.1 then
				break -- past the match (going further back would only find the windup side)
			end
		end
		u, v = aim.U - du * best, aim.V - dv * best
	end
	u, v = u - du * A.BindRebound, v - dv * A.BindRebound
	local r = math.sqrt(u * u + v * v)
	if r > 1 then
		u, v = u / r, v / r
	end
	aim.U, aim.V, aim.VU, aim.VV = u, v, 0, 0
	aim.Bind = { U = u, V = v, DU = du, DV = dv }
	return true
end

-- Server, outside the simulation: mirror the bind on the model for the owner's cursor UI (under
-- server authority the client reads its own predicted copy from SimState's attributes instead)
function SwordController.PublishBind(f)
	local b = f.Aim and f.Aim.Bind
	local key = b and string.format("%.3f %.3f %.3f %.3f", b.U, b.V, b.DU, b.DV) or ""
	if f.PublishedBind ~= key then
		f.PublishedBind = key
		f.Model:SetAttribute("AimBind", b and Vector3.new(b.U, b.V, 0) or nil)
		f.Model:SetAttribute("AimBindDir", b and Vector3.new(b.DU, b.DV, 0) or nil)
	end
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

-- Post-physics. Returns sweep info {PrevCF, CF, Dt, Stroke} if the blade may strike this frame
-- (Stroke = nil: it may only meet other blades, see CombatResolver.Process).
function SwordController.Track(f, dt, inp)
	local atk = f.Attack
	if not f.Sword or f.Sheathed or f.DrawKind then
		atk.Stroke = nil
		atk.PrevBladeCF = nil
		setPhase(f, (not f.Sword and "Unarmed") or (f.DrawKind and "Drawing") or "Sheathed")
		return nil
	end
	local cf = f.Sword.Blade.CFrame
	local prev = atk.PrevBladeCF
	if f.RemoteBody and prev and cf == prev and (atk.HeldDt or 0) < 0.2 then
		-- a body its owner simulates (Owner mode) arrives by replication, not every frame: wait for
		-- the next pose and measure the motion over the whole gap
		atk.HeldDt = (atk.HeldDt or 0) + dt
		return nil
	end
	dt += atk.HeldDt or 0
	atk.HeldDt = 0
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
				Runtime.Sound("Slash", cf.Position, f)
			elseif not inp.M1 and atk.ReleaseTime and now - atk.ReleaseTime > C.FollowThroughTime then
				SwordController.EndStroke(f, "Released")
				s = nil
			else
				s.Dir = Util.unit(s.Dir * 0.8 + dirNow * 0.2, s.Dir)
			end
		end
	elseif canStrike and inp.M1 and speed > C.StrokeStartSpeed then
		s = SwordController.StartStroke(f, rel / speed)
		Runtime.Sound("Slash", cf.Position, f)
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
	elseif f.State == "Attacking" and not f.Aim.Bind then
		-- no damaging stroke, but a slow push into a guard or blade still binds (CombatResolver)
		return { PrevCF = prev, CF = cf, Dt = dt, Stroke = nil }
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
