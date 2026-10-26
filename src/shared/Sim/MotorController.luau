--[[
	MotorController: the ONLY writer of joint targets and drive strengths.

	Each frame it
	  1. picks a muscle tone for the current state (upright / limp / bracing / ramping recovery / dead)
	  2. computes a procedural pose (stance, gait, kneel, brace, falling) + arm IK toward the sword
	  3. writes joint drive targets/strengths (scaled by segment integrity: injured limbs droop)
	  4. writes pelvis upright torque, planar locomotion and support force
	  5. writes sword-hand / off-hand drives
	Writes are thresholded so unchanged targets do not replicate.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.RagdollRonin
local Config = require(Shared.Config)
local Anatomy = require(Shared.Anatomy)
local StateDefs = require(Shared.StateDefs)
local Util = require(script.Parent.Util)
local Runtime = require(script.Parent.Runtime)
local BodyShape = require(script.Parent.BodyShape)
local Spacing = require(script.Parent.Spacing)
local Kick = require(script.Parent.Kick)
local StateMachine = require(script.Parent.StateMachine)

local MotorController = {}

local S = Config.Scale
local M = Config.Movement
local D = Config.Drives
local rad = math.rad

local TONE = {
	Idle = { Body = 1, Arm = 1, Upright = 1, Support = 1, Move = 1 },
	Moving = { Body = 1, Arm = 1, Upright = 1, Support = 1, Move = 1 },
	Attacking = { Body = 1, Arm = 1, Upright = 1, Support = 1, Move = M.AttackSpeedMult },
	Blocking = { Body = 1, Arm = 1, Upright = 1, Support = 1, Move = M.BlockSpeedMult },
	Kicking = { Body = 1, Arm = 1, Upright = 1, Support = 1, Move = Config.Kick.MoveMult },
	Staggered = { Body = 0.8, Arm = 0.45, Upright = 0.75, Support = 1, Move = M.StaggerSpeedMult, Accel = M.StaggerAcceleration },
	OffBalance = { Body = 0.85, Arm = 0.7, Upright = 0.45, Support = 1, Move = M.OffBalanceSpeedMult, Accel = M.StaggerAcceleration },
	Falling = { Body = 0.06, Arm = 0.05, Upright = 0, Support = 0, Move = 0 },
	GroundedRecovery = { Body = 0.45, Arm = 0.4, Upright = 0, Support = 0, Move = 0 },
	Recovering = { Body = 1, Arm = 0.6, Upright = 1, Support = 1, Move = 0 }, -- scaled by the attempt ramp
	SeverelyInjured = { Body = 0.15, Arm = 0.12, Upright = 0, Support = 0, Move = 0 },
	Dead = { Body = 0, Arm = 0, Upright = 0, Support = 0, Move = 0 },
}
MotorController.Tone = TONE

local ARM_CLASS = { Shoulder = true, Elbow = true, Wrist = true }
local LIMB_PART = {}
for _, def in ipairs(Anatomy.Parts) do
	if def.Group == "Limb" then
		LIMB_PART[def.Name] = true
	end
end
local SHOULDER = { Right = Vector3.new(1.2, 0.5, 0) * S, Left = Vector3.new(-1.2, 0.5, 0) * S }
local POLE = { Right = Vector3.new(0.4, -0.6, 0.7).Unit, Left = Vector3.new(-0.4, -0.6, 0.7).Unit }
local L1 = 1.05 * S -- shoulder pivot -> elbow pivot
local L2 = 1.425 * S -- elbow pivot -> palm grip
local L_FOREARM = 1.15 * S -- elbow pivot -> wrist pivot
-- hand-local frame of the sword grip (must match CharacterBuilder)
local GRIP_LOCAL = CFrame.new(0, -0.05 * S, 0) * CFrame.fromMatrix(Vector3.zero, Vector3.new(0, -1, 0), Vector3.new(0, 0, -1))
local GRIP_LOCAL_INV = GRIP_LOCAL:Inverse()
local WRIST_IN_HAND = Vector3.new(0, 0.225 * S, 0)

------------------------------------------------------------------ thresholded writes
-- Under server authority every value is written exactly: the skip-small-changes cache depends on
-- write history, which differs between the server and a client that just rolled back, so the
-- engine would see slightly different drive targets and keep mispredicting.
local EXACT = Runtime.ServerAuthority
-- quantization of the few drive values computed straight from physics state (which differs by
-- tiny amounts between client prediction and server), so both sides usually write the same value
local SUPPORT_ACCEL_STEP = 0.5 -- studs/s^2
local GAIT_ANGLE_STEP = math.rad(3)

local function quantize(x, step)
	return math.round(x / step) * step
end

local function cacheOf(f, inst)
	local c = f.DriveCache[inst]
	if not c then
		c = {}
		f.DriveCache[inst] = c
	end
	return c
end

local function setNum(f, inst, prop, value, eps)
	if EXACT then
		inst[prop] = value
		return
	end
	local c = cacheOf(f, inst)
	local old = c[prop]
	if old == nil or math.abs(old - value) > eps or (value == 0 and old ~= 0) then
		inst[prop] = value
		c[prop] = value
	end
end

local function setCF(f, inst, prop, cf, posEps, angEps)
	if EXACT then
		inst[prop] = cf
		return
	end
	local c = cacheOf(f, inst)
	local old = c[prop]
	if old == nil or (old.Position - cf.Position).Magnitude > posEps or Util.rotationDelta(old, cf) > angEps then
		inst[prop] = cf
		c[prop] = cf
	end
end

local function setVec(f, inst, prop, v, eps)
	if EXACT then
		inst[prop] = v
		return
	end
	local c = cacheOf(f, inst)
	local old = c[prop]
	if old == nil or (old - v).Magnitude > eps then
		inst[prop] = v
		c[prop] = v
	end
end

------------------------------------------------------------------ IK
local LIMIT_COST = 0.6 -- cost per radian past a joint limit (comparable to ~0.1 stud of body overlap per 10 degrees)
local ARM_RADIUS = 0.21 * S

local function armPenetration(shoulder, elbow, target)
	local pen = 0
	for _, t in ipairs({ 0.45, 0.75, 1 }) do
		pen += BodyShape.Penetration(shoulder:Lerp(elbow, t), ARM_RADIUS)
	end
	for _, t in ipairs({ 0.35, 0.7 }) do
		pen += BodyShape.Penetration(elbow:Lerp(target, t), ARM_RADIUS)
	end
	return pen
end

-- Joint limits the IK must respect (Anatomy): an IK pose beyond them leaves the joint drive pushing
-- into the ball-socket limit every frame, which jitters - and under server authority makes client
-- and server physics diverge. A small margin keeps the solution off the hard stop.
local LIMIT_MARGIN = rad(8)
local SHOULDER_TWIST = rad(Anatomy.JointByName.RightShoulder.Twist) - LIMIT_MARGIN
local WRIST_CONE = rad(Anatomy.JointByName.RightWrist.Cone) - LIMIT_MARGIN
local WRIST_TWIST = rad(Anatomy.JointByName.RightWrist.Twist) - LIMIT_MARGIN
local LIMB_AXIS = Vector3.new(0, -1, 0)

-- Swing (cone angle) and twist of a rotation relative to the rest frame (limb along -Y, secondary
-- axis +X), decomposed the way a BallSocketConstraint measures them.
local function swingTwist(r)
	local b = r:VectorToWorldSpace(LIMB_AXIS)
	local swing = math.acos(math.clamp(LIMB_AXIS:Dot(b), -1, 1))
	local axis = LIMB_AXIS:Cross(b)
	if axis.Magnitude < 1e-6 then
		axis = Vector3.xAxis
	end
	local twistOnly = CFrame.fromAxisAngle(axis.Unit, swing):Inverse() * r
	local x = twistOnly:VectorToWorldSpace(Vector3.xAxis)
	return swing, math.atan2(x.Z, x.X)
end

-- Upper-arm rotation for an elbow swung toward `pole`
local function armFrame(shoulder, n, cosA, sinA, pole, target)
	local u = n * cosA + pole * sinA -- upper arm direction
	local elbow = shoulder + u * L1
	local fore = Util.unit(target - elbow, n)
	local Y = -u
	local Z = -Util.perpendicular(fore, u, -pole) -- forearm deviates toward local -Z
	local X = Y:Cross(Z)
	return CFrame.fromMatrix(Vector3.zero, X, Y, Z), elbow
end

-- How far (radians) a candidate arm pose goes past the shoulder and wrist limits
local function limitExcess(rot, flex, handRot)
	local _, twist = swingTwist(rot)
	local over = math.max(0, math.abs(twist) - SHOULDER_TWIST)
	if handRot then
		local wrist = (rot * CFrame.fromAxisAngle(Vector3.xAxis, flex)):Inverse() * handRot
		local cone, wtwist = swingTwist(wrist)
		over += math.max(0, cone - WRIST_CONE) + math.max(0, math.abs(wtwist) - WRIST_TWIST)
	end
	return over
end

------------------------------------------------------------------ arm controller
--[[
	Both arms are posed from ONE solution per step that the joint drives and the hand drive agree on,
	so they never fight (fighting is what twisted arms, bent elbows backwards and left the arm stuck
	in a broken pose after fast swings):

	  * Two-bone IK to the wrist; the elbow is swung about the shoulder->wrist line by a swivel
	    angle measured from a natural "down and out" pole.
	  * Each step a coarse search finds the swivel (and, for the sword arm, a roll of the sword
	    about its blade, relative to what SwordController asked for) that keeps the arm out of the
	    body and inside the shoulder/wrist limits while staying close to the requested edge. The
	    arm's actual swivel and roll then only MOVE TOWARD that answer at a capped rate: when the
	    best answer changes branch, the elbow swings round smoothly instead of snapping (the wrist
	    stays where it is while the elbow swivels).
	  * The wrist rotation is whatever turns the forearm into the requested hand orientation,
	    clamped into the wrist's limits; forward kinematics then gives the grip the arm really
	    reaches, and THAT is what the hand drive holds (f.SwordHoldCF).
	Swivel and roll are rollback state (SimState ArmSwivelR / ArmRollR / ArmSwivelL).
]]
local ARM = Config.Drives.Arm
local SHOULDER_CONE = rad(Anatomy.JointByName.RightShoulder.Cone) - LIMIT_MARGIN
local SWIVELS = {}
for a = -160, 180, 20 do
	table.insert(SWIVELS, rad(a))
end
local ROLLS = { 0, rad(30), rad(-30), rad(60), rad(-60), rad(90), rad(-90) }

-- Two-bone IK in upper-torso space with the elbow swung by `swivel` from the natural pole.
-- Returns the upper-arm rotation (rest frame: limb along -Y, elbow flexion about +X toward -Z),
-- elbow flex, elbow position and the (reach-clamped) wrist point.
local function armGeometry(side, target, l2, swivel)
	local shoulder = SHOULDER[side]
	local toT = target - shoulder
	local d = math.clamp(toT.Magnitude, 0.25 * (L1 + l2), (L1 + l2) * 0.999)
	local n = Util.unit(toT, Vector3.new(0, -1, 0))
	local cosA = math.clamp((L1 * L1 + d * d - l2 * l2) / (2 * L1 * d), -1, 1)
	local cosE = math.clamp((L1 * L1 + l2 * l2 - d * d) / (2 * L1 * l2), -1, 1)
	local flex = math.pi - math.acos(cosE)
	local sinA = math.sqrt(1 - cosA * cosA)
	local base = Util.perpendicular(POLE[side], n, Util.perpendicular(Vector3.new(0, 0, 1), n, Vector3.xAxis))
	local pole = CFrame.fromAxisAngle(n, swivel):VectorToWorldSpace(base)
	local rot, elbow = armFrame(shoulder, n, cosA, sinA, pole, target)
	return rot, flex, elbow, shoulder + n * d
end

-- Clamp a joint rotation (rest frame as in swingTwist) into a cone and twist range
local function clampSwingTwist(r, cone, twist)
	local b = r:VectorToWorldSpace(LIMB_AXIS)
	local swing = math.acos(math.clamp(LIMB_AXIS:Dot(b), -1, 1))
	local axis = LIMB_AXIS:Cross(b)
	axis = axis.Magnitude < 1e-6 and Vector3.xAxis or axis.Unit
	local x = (CFrame.fromAxisAngle(axis, swing):Inverse() * r):VectorToWorldSpace(Vector3.xAxis)
	local t = math.atan2(x.Z, x.X)
	if swing <= cone and math.abs(t) <= twist then
		return r
	end
	return CFrame.fromAxisAngle(axis, math.min(swing, cone)) * CFrame.fromAxisAngle(Vector3.yAxis, -math.clamp(t, -twist, twist))
end

-- Joint drives always turn the short way, but the shoulder (+-110 deg) and wrist (+-165 deg) twist
-- ranges do not include +-180: going from one end of the range to the other the short way runs into
-- the limit, and the drive then pushes into it and stays there (the arm stays twisted, the hands stay
-- flipped). So while the target twist is far from the joint's actual twist, the drive is given an
-- intermediate target that moves the twist at most TWIST_STEP toward it, through the allowed range.
local TWIST_STEP = rad(60)
local TWIST_WALK_MIN = 90 -- degrees of twist range from which a joint is walked like this
local function walkTwist(f, j, target)
	local pp, cp = f.Parts[j.ParentName], f.Parts[j.ChildName]
	if not pp or not cp then
		return target
	end
	local _, now = swingTwist(pp.CFrame:ToObjectSpace(cp.CFrame).Rotation)
	local b = target:VectorToWorldSpace(LIMB_AXIS)
	local swing = math.acos(math.clamp(LIMB_AXIS:Dot(b), -1, 1))
	local axis = LIMB_AXIS:Cross(b)
	axis = axis.Magnitude < 1e-6 and Vector3.xAxis or axis.Unit
	local swingCF = CFrame.fromAxisAngle(axis, swing)
	local x = (swingCF:Inverse() * target):VectorToWorldSpace(Vector3.xAxis)
	local want = math.atan2(x.Z, x.X)
	if math.abs(want - now) <= TWIST_STEP then
		return target
	end
	return swingCF * CFrame.fromAxisAngle(Vector3.yAxis, -(now + math.sign(want - now) * TWIST_STEP))
end

-- Turn the sword target `from` toward `to` at a capped rate: the blade direction first (shortest
-- arc), then the roll about the blade. Keeps the hand drive's target from ever running so far ahead
-- of the sword that the drive's short way round becomes the wrong way (the sword flipping over).
local function limitTurn(from, to, maxDir, maxRoll)
	local d0, d1 = from.UpVector, to.UpVector
	local d = Util.rotateToward(d0, d1, maxDir)
	local axis = d0:Cross(d)
	local e = from.RightVector
	if axis.Magnitude > 1e-6 then
		e = CFrame.fromAxisAngle(axis.Unit, math.acos(math.clamp(d0:Dot(d), -1, 1))):VectorToWorldSpace(e)
	end
	e = Util.perpendicular(e, d, Util.perpendicular(Vector3.new(0, -1, 0), d, Vector3.xAxis))
	local want = Util.perpendicular(to.RightVector, d, e)
	e = Util.perpendicular(Util.rotateToward(e, want, maxRoll), d, want)
	return CFrame.fromMatrix(to.Position, e, d, e:Cross(d))
end

local function wristExcess(rot, flex, handRot)
	local cone, twist = swingTwist((rot * CFrame.fromAxisAngle(Vector3.xAxis, flex)):Inverse() * handRot)
	return math.max(0, cone - WRIST_CONE) + math.max(0, math.abs(twist) - WRIST_TWIST)
end

local function shoulderExcess(rot)
	local _, twist = swingTwist(rot)
	return math.max(0, math.abs(twist) - SHOULDER_TWIST)
end

-- hand frame and wrist point for the sword grip rolled by `roll` about the blade
local function handOf(grip, roll)
	local hand = (roll == 0 and grip or grip * CFrame.Angles(0, roll, 0)) * GRIP_LOCAL_INV
	return hand, hand:PointToWorldSpace(WRIST_IN_HAND)
end

local function approachLinear(cur, target, maxStep)
	return cur + math.clamp(target - cur, -maxStep, maxStep)
end

-- Sword arm: returns shoulder rotation, elbow flex, wrist rotation and the grip CFrame it reaches
local function solveSwordArm(st, grip, dt)
	-- search (arm geometry once per swivel, at the current roll: rolling about the blade moves the
	-- wrist only slightly; each roll candidate then only changes the wrist limit)
	local _, wristNow = handOf(grip, st.Roll)
	local hands = {}
	for i, roll in ipairs(ROLLS) do
		hands[i] = (handOf(grip, roll)).Rotation
	end
	local bestCost, bestSwivel, bestRoll = math.huge, st.Swivel, st.Roll
	local function consider(swivel, extraRoll)
		local rot, flex, elbow, reach = armGeometry("Right", wristNow, L_FOREARM, swivel)
		local base = armPenetration(SHOULDER.Right, elbow, reach) + shoulderExcess(rot) * LIMIT_COST
			+ ARM.SwivelCost * math.abs(swivel) + ARM.Hysteresis * math.abs(Util.angleDelta(st.Swivel, swivel))
		local function try(roll, handRot)
			local c = base + wristExcess(rot, flex, handRot) * LIMIT_COST + ARM.RollCost * math.abs(roll)
				+ ARM.Hysteresis * math.abs(roll - st.Roll)
			if c < bestCost then
				bestCost, bestSwivel, bestRoll = c, swivel, roll
			end
		end
		for i, roll in ipairs(ROLLS) do
			try(roll, hands[i])
		end
		try(extraRoll, (handOf(grip, extraRoll)).Rotation)
	end
	for _, swivel in ipairs(SWIVELS) do
		consider(swivel, st.Roll)
	end
	consider(st.Swivel, st.Roll)
	st.Swivel = Util.angleDelta(0, Util.approachAngle(st.Swivel, bestSwivel, ARM.SwivelRate * dt))
	st.Roll = approachLinear(st.Roll, bestRoll, ARM.RollRate * dt)

	-- final pose from the arm's own swivel and roll; wrist clamped; forward kinematics
	local hand, wrist = handOf(grip, st.Roll)
	local rot, flex = armGeometry("Right", wrist, L_FOREARM, st.Swivel)
	rot = clampSwingTwist(rot, SHOULDER_CONE, SHOULDER_TWIST)
	local fore = rot * CFrame.fromAxisAngle(Vector3.xAxis, flex)
	local wristRot = clampSwingTwist(fore:Inverse() * hand.Rotation, WRIST_CONE, WRIST_TWIST)
	local handRot = fore * wristRot
	local elbowPos = SHOULDER.Right + rot:VectorToWorldSpace(Vector3.new(0, -L1, 0))
	local wristPos = elbowPos + fore:VectorToWorldSpace(Vector3.new(0, -L_FOREARM, 0))
	local reached = (CFrame.new(wristPos) * handRot * CFrame.new(-WRIST_IN_HAND)) * GRIP_LOCAL
	return rot, flex, wristRot, reached
end

-- Off arm: shoulder rotation and elbow flex reaching `target` (hand orientation left free)
local function solveOffArm(st, target, dt)
	local bestCost, bestSwivel = math.huge, st.SwivelL
	local function consider(swivel)
		local rot, flex, elbow, reach = armGeometry("Left", target, L2, swivel)
		local c = armPenetration(SHOULDER.Left, elbow, reach) + shoulderExcess(rot) * LIMIT_COST
			+ ARM.SwivelCost * math.abs(swivel) + ARM.Hysteresis * math.abs(Util.angleDelta(st.SwivelL, swivel))
		if c < bestCost then
			bestCost, bestSwivel = c, swivel
		end
	end
	for _, swivel in ipairs(SWIVELS) do
		consider(swivel)
	end
	consider(st.SwivelL)
	st.SwivelL = Util.angleDelta(0, Util.approachAngle(st.SwivelL, bestSwivel, ARM.SwivelRate * dt))
	local rot, flex = armGeometry("Left", target, L2, st.SwivelL)
	return clampSwingTwist(rot, SHOULDER_CONE, SHOULDER_TWIST), flex
end

------------------------------------------------------------------ poses
local function hangArms(pose, side)
	local s = side == "Right" and 1 or -1
	pose[side .. "Shoulder"] = CFrame.Angles(rad(8), 0, s * rad(6))
	pose[side .. "Elbow"] = rad(20)
end

-- Gait is driven by the COMMANDED velocity: driving it from actual velocity lets a shove start
-- the stepping cycle, which then kicks the ground and sustains itself.
local function standLegs(f, dt, pose)
	local pelvis = f.Parts.LowerTorso
	local vel = f.CommandedVelocity or Vector3.zero
	local speed = vel.Magnitude
	local frac = math.clamp(speed / M.WalkSpeed, 0, 1)
	local g = f.Gait
	if speed > 0.6 then
		g.Phase = (g.Phase + dt * speed / M.StrideLength * 2 * math.pi) % (2 * math.pi)
	end
	local lv = pelvis.CFrame:VectorToObjectSpace(vel)
	local m = Util.unit(Vector3.new(lv.X, 0, lv.Z), Vector3.new(0, 0, -1))
	if EXACT then
		local a = quantize(math.atan2(m.X, -m.Z), GAIT_ANGLE_STEP)
		m = Vector3.new(math.sin(a), 0, -math.cos(a))
	end
	local axis = Vector3.new(-m.Z, 0, m.X) -- rotating the leg about this swings it toward m
	local fwd = -m.Z
	for _, side in ipairs({ "Left", "Right" }) do
		local ph = g.Phase + (side == "Right" and math.pi or 0)
		local swing = M.GaitHipAmplitude * frac * math.sin(ph)
		local knee = M.StanceKneeBend + M.GaitKneeAmplitude * frac * math.max(0, math.cos(ph))
		local stancePitch = (side == "Left" and rad(10) or rad(-8)) * (1 - frac)
		local splay = (side == "Right" and 1 or -1) * rad(4)
		local thighPitch = knee * 0.5 + stancePitch
		pose[side .. "Hip"] = CFrame.fromAxisAngle(axis, swing) * CFrame.Angles(thighPitch, 0, splay)
		pose[side .. "Knee"] = knee
		pose[side .. "Ankle"] = CFrame.Angles(knee - thighPitch - swing * fwd, 0, -splay)
	end
end

local function kneelLegs(f, pose)
	local front = (f.Caps.LegLeft >= f.Caps.LegRight) and "Left" or "Right"
	local back = front == "Left" and "Right" or "Left"
	pose[front .. "Hip"] = CFrame.Angles(rad(70), 0, 0)
	pose[front .. "Knee"] = rad(85)
	pose[front .. "Ankle"] = CFrame.Angles(rad(15), 0, 0)
	pose[back .. "Hip"] = CFrame.Angles(rad(-10), 0, 0)
	pose[back .. "Knee"] = rad(100)
	pose[back .. "Ankle"] = CFrame.Angles(rad(40), 0, 0)
end

local function bracePose(pose, faceDown)
	for _, side in ipairs({ "Left", "Right" }) do
		local s = side == "Right" and 1 or -1
		if faceDown then
			pose[side .. "Hip"] = CFrame.Angles(rad(80), 0, s * rad(6))
			pose[side .. "Knee"] = rad(100)
			pose[side .. "Ankle"] = CFrame.Angles(rad(20), 0, 0)
			pose[side .. "Shoulder"] = CFrame.Angles(rad(80), 0, s * rad(10))
			pose[side .. "Elbow"] = rad(40)
		else
			pose[side .. "Hip"] = CFrame.Angles(rad(70), 0, s * rad(8))
			pose[side .. "Knee"] = rad(95)
			pose[side .. "Ankle"] = CFrame.Angles(rad(25), 0, 0)
			pose[side .. "Shoulder"] = CFrame.Angles(rad(-30), 0, s * rad(25))
			pose[side .. "Elbow"] = rad(30)
		end
	end
	pose.Waist = CFrame.Angles(faceDown and rad(-10) or rad(-35), 0, 0)
	pose.NeckBase = CFrame.Angles(faceDown and rad(20) or rad(-20), 0, 0)
	pose.NeckHead = CFrame.identity
end

local function fallingPose(pose)
	for _, side in ipairs({ "Left", "Right" }) do
		pose[side .. "Hip"] = CFrame.Angles(rad(20), 0, 0)
		pose[side .. "Knee"] = rad(30)
		pose[side .. "Elbow"] = rad(30)
	end
end

-- off-hand grip point on the hilt (upper-torso space), on the grip the sword arm really reaches
local function offHandTarget(f)
	return ((f.SwordHoldCF or f.SwordTargetCF) * CFrame.new(0, -0.55 * Config.Sword.HandleLength, 0)).Position
end

local function twoHanded(f)
	return f.Sword ~= nil and f.Drives.OffPos ~= nil and f.Caps.OffArm > 0.2 and StateDefs.Upright[f.State] == true
		and f.SwordTargetCF ~= nil and not f.OffHandFree
end

-- The off hand lets go when the pose puts the hilt out of its reach (e.g. a guard low on the
-- right) instead of straining the arm through the torso; it takes hold again once back in reach.
local function updateOffHandGrip(f)
	if not f.SwordTargetCF then
		return
	end
	local reach = (offHandTarget(f) - SHOULDER.Left).Magnitude / (L1 + L2)
	f.OffHandFree = reach > (f.OffHandFree and 1.0 or 1.08)
end

-- Once per step (before the pose): solve both arms and remember the result for armPose
local function solveArms(f, dt)
	f.ArmState = f.ArmState or { Swivel = 0, Roll = 0, SwivelL = 0 }
	local st = f.ArmState
	local out = {}
	f.ArmSolution = out
	f.SwordHoldCF = nil
	if f.Sword and f.Joints.RightShoulder and not f.Joints.RightShoulder.Severed and f.SwordTargetCF then
		local rot, flex, wristRot, reached = solveSwordArm(st, f.SwordTargetCF, dt)
		out.RightShoulder, out.RightElbow, out.RightWrist = rot, flex, wristRot
		f.SwordHoldCF = reached
	end
	updateOffHandGrip(f)
	if twoHanded(f) then
		out.LeftShoulder, out.LeftElbow = solveOffArm(st, offHandTarget(f), dt)
	end
end

local function armPose(f, pose)
	local sol = f.ArmSolution or {}
	if sol.RightShoulder then
		pose.RightShoulder, pose.RightElbow, pose.RightWrist = sol.RightShoulder, sol.RightElbow, sol.RightWrist
	elseif not pose.RightShoulder then
		hangArms(pose, "Right")
	end
	if sol.LeftShoulder then
		pose.LeftShoulder, pose.LeftElbow = sol.LeftShoulder, sol.LeftElbow
	elseif not pose.LeftShoulder then
		hangArms(pose, "Left")
	end
end

local function blendPose(a, b, t)
	local out = {}
	for k, va in pairs(a) do
		local vb = b[k]
		if vb == nil then
			out[k] = va
		elseif typeof(va) == "CFrame" then
			out[k] = va:Lerp(vb, t)
		else
			out[k] = va + (vb - va) * t
		end
	end
	for k, vb in pairs(b) do
		if out[k] == nil then
			out[k] = vb
		end
	end
	return out
end

local function uprightPose(f, dt)
	local pose = {}
	local st = f.State
	local aim = f.Aim
	-- body twist from the sword pose (wind-up / follow-through, guard side): the waist turns by it
	-- and the hips add Config.Aim.HipTwist of it (pelvis facing, see Apply); the neck turns the head
	-- back to the front
	local torsoYaw = aim and aim.Twist or 0
	local twist = torsoYaw * (1 + Config.Aim.HipTwist)
	local lean = rad(6)
	if st == "Attacking" then
		lean += rad(6) * math.clamp(0.5 - aim.V * 0.5, 0, 1)
	end
	pose.Waist = CFrame.Angles(0, torsoYaw, 0) * CFrame.Angles(-lean, 0, 0)
	pose.NeckBase = CFrame.Angles(0, -twist * 0.5, 0)
	pose.NeckHead = CFrame.Angles(lean * 0.5, -twist * 0.5, 0)
	if f.Caps.Kneeling then
		kneelLegs(f, pose)
	else
		standLegs(f, dt, pose)
	end
	if st == "Kicking" then
		-- teep: blend the stance into the kick leg pose as the knee comes up (Sim.Kick)
		local lift, ext = Kick.Phase(StateMachine.Elapsed(f))
		local lean = rad(Config.Kick.Lean) * ext
		local kick = {}
		Kick.LegPose(kick, ext, lean)
		local legs = {}
		for k in pairs(kick) do
			legs[k] = pose[k]
		end
		for k, v in pairs(blendPose(legs, kick, lift)) do
			pose[k] = v
		end
		-- the head stays level and on the target while the body leans back
		pose.NeckBase = pose.NeckBase * CFrame.Angles(-lean * 0.6, 0, 0)
	end
	armPose(f, pose)
	return pose
end

function MotorController.ComputePose(f, dt)
	local st = f.State
	if StateDefs.Upright[st] then
		return uprightPose(f, dt)
	end
	local pose = {}
	if st == "Falling" or st == "Dead" then
		fallingPose(pose)
	elseif st == "GroundedRecovery" or st == "SeverelyInjured" then
		bracePose(pose, f.StateData.FaceDown == true)
	elseif st == "Recovering" then
		local brace = {}
		bracePose(brace, f.StateData.FaceDown == true)
		local stand = uprightPose(f, dt)
		pose = blendPose(brace, stand, Util.smoothstep(f.StateData.R or 0))
	end
	armPose(f, pose)
	return pose
end

------------------------------------------------------------------ apply
function MotorController.Apply(f, dt, inp)
	local st = f.State
	local tone = TONE[st] or TONE.Idle
	local caps = f.Caps
	local r = (st == "Recovering") and (f.StateData.R or 0) or 1
	local strength = 0.55 + 0.45 * caps.Strength
	local bodyTone = tone.Body * strength * (st == "Recovering" and (0.5 + 0.5 * r) or 1)
	local armTone = tone.Arm * strength

	-- 0. limbs only touch the world while the fighter is actually down. When upright, the support
	--    spring carries the body and limbs are posed procedurally; driven limbs pressing into the
	--    ground get a ground reaction that kicks or even catapults the body (found in testing).
	--    On the ground they collide normally so falls, bracing and push-ups are physical.
	local limbsCollide = not StateDefs.Upright[st] and not (st == "Recovering" and r > 0.5)
	if f.LimbsCollide ~= limbsCollide then
		f.LimbsCollide = limbsCollide
		for name, part in pairs(f.Parts) do
			if LIMB_PART[name] then
				part.CanCollide = limbsCollide
			end
		end
	end

	-- commanded locomotion, before the pose: the gait cycle follows it (this step's, not last step's)
	local moveDir = StateDefs.Upright[st] and inp.Move or Vector3.zero
	local speed = M.WalkSpeed * tone.Move * caps.Move * (caps.Kneeling and M.KneelSpeedMult or 1)
	local vel = moveDir * speed
	if StateDefs.Upright[st] then
		vel = Spacing.Adjust(f, vel)
	end
	local kickLift, kickExt, kickDrive = 0, 0, false
	if st == "Kicking" then
		kickLift, kickExt, kickDrive = Kick.Phase(StateMachine.Elapsed(f))
		if kickDrive then
			-- the hips drive forward into the push (allowed into the other fighter's space: that
			-- is the point of the teep)
			vel += Vector3.new(-math.sin(f.FacingYaw), 0, -math.cos(f.FacingYaw)) * Config.Kick.LungeSpeed
		end
	end
	f.CommandedVelocity = st == "Kicking" and Vector3.zero or vel -- (no walking gait under the kick)

	-- 1. joints (the sword target first turns toward this step's request at a capped rate)
	if f.SwordTargetCF then
		if f.SwordAimDir and f.SwordAimEdge then
			local d = f.SwordAimDir.Unit -- (stored rounded, so renormalise)
			local e = Util.perpendicular(f.SwordAimEdge, d, Util.perpendicular(Vector3.new(0, -1, 0), d, Vector3.xAxis))
			local from = CFrame.fromMatrix(Vector3.zero, e, d, e:Cross(d))
			f.SwordTargetCF = limitTurn(from, f.SwordTargetCF, D.HandTurnRate * dt, D.HandRollRate * dt)
		end
		f.SwordAimDir, f.SwordAimEdge = f.SwordTargetCF.UpVector, f.SwordTargetCF.RightVector
	end
	solveArms(f, dt)
	local pose = MotorController.ComputePose(f, dt)
	for name, j in pairs(f.Joints) do
		if not j.Severed then
			local cls = j.Def.DriveClass and D.Joint[j.Def.DriveClass]
			if cls then
				local segF = f.SegFactor[Anatomy.PartByName[j.ChildName].Segment] or 0
				local t = (ARM_CLASS[j.Def.DriveClass] and armTone or bodyTone) * (0.25 + 0.75 * segF)
				if j.Kind == "Ball" and j.Drive then
					setNum(f, j.Drive, "MaxTorque", cls.Torque * t, cls.Torque * 0.02)
					local target = pose[name] or CFrame.identity
					if j.Def.Twist >= TWIST_WALK_MIN then
						target = walkTwist(f, j, target)
					end
					setCF(f, j.TargetAtt, "CFrame", j.TargetBase * target, 0.01, D.TargetAngleEpsilon)
				elseif j.Kind == "Hinge" then
					setNum(f, j.Constraint, "ServoMaxTorque", cls.Torque * t, cls.Torque * 0.02)
					local flex = math.clamp(pose[name] or 0, rad(j.Def.FlexMin), rad(j.Def.FlexMax))
					setNum(f, j.Constraint, "TargetAngle", math.deg(flex) * j.Sign, 0.5)
				end
			end
		end
	end

	-- 2. pelvis: facing + upright
	local Dr = f.Drives
	local pelvis = f.Parts.LowerTorso
	if StateDefs.Upright[st] then
		local rate = (st == "Attacking" or st == "Blocking" or st == "Kicking") and M.AttackTurnRate or M.TurnRate
		f.FacingYaw = Util.approachAngle(f.FacingYaw, inp.Yaw, rate * dt)
	elseif st == "Recovering" then
		f.FacingYaw = f.StateData.Yaw or f.FacingYaw
	end
	local leanCF = CFrame.identity
	if st == "OffBalance" and f.StateData.PushDir then
		local axis = Vector3.yAxis:Cross(f.StateData.PushDir)
		if axis.Magnitude > 1e-3 then
			leanCF = CFrame.fromAxisAngle(axis.Unit, rad(14))
		end
	elseif st == "Kicking" and kickExt > 0 then
		-- lean back against the extended leg (about the facing's right axis: + tips the top back)
		local right = Vector3.new(math.cos(f.FacingYaw), 0, -math.sin(f.FacingYaw))
		leanCF = CFrame.fromAxisAngle(right, rad(Config.Kick.Lean) * kickExt)
	end
	local hipTwist = StateDefs.Upright[st] and f.Aim and f.Aim.Twist * Config.Aim.HipTwist or 0
	setCF(f, Dr.Upright, "CFrame", leanCF * CFrame.Angles(0, f.FacingYaw + hipTwist, 0), 1, rad(0.5))
	local uprightTone = tone.Upright * (st == "Recovering" and r * Config.Recovery.UprightTorqueScale or 1)
	setNum(f, Dr.Upright, "MaxTorque", D.PelvisTorquePerMass * f.TotalMass * uprightTone * caps.Stability, 5)

	-- 3. locomotion
	setVec(f, Dr.Move, "PlaneVelocity", Vector2.new(vel.X, vel.Z), 0.05)
	local authority = (tone.Support > 0 and f.Grounded) and r or 0
	setNum(f, Dr.Move, "MaxForce", f.TotalMass * (tone.Accel or M.Acceleration) * authority, 1)

	-- 4. support (spring-damper toward stand/kneel height, scaled by the recovery ramp)
	local force = 0
	if tone.Support > 0 and f.Ground then
		local target = f.TargetHeight
		if st == "Recovering" then
			target = (f.StateData.StartHeight or target) + (target - (f.StateData.StartHeight or target)) * Util.smoothstep(r)
		end
		local g = workspace.Gravity
		local vy = pelvis.AssemblyLinearVelocity.Y
		local acc = g + M.SupportStiffness * (target - f.Ground.Height) - M.SupportDamping * vy
		acc = math.clamp(acc, 0, g * M.MaxSupportAccel)
		if EXACT then
			acc = quantize(acc, SUPPORT_ACCEL_STEP)
		end
		force = f.TotalMass * acc * tone.Support * r
	end
	setVec(f, Dr.Support, "Force", Vector3.new(0, force, 0), f.TotalMass * 2)

	-- 5. hands
	if Dr.HandPos and Dr.HandOri then
		local k = 0
		if f.Sword and f.SwordTargetCF then
			k = armTone * caps.SwordArm * caps.Grip
			if Runtime.now() < f.Attack.RecoilUntil then
				k *= Config.Combat.RecoilHandScale
			elseif st == "Blocking" then
				k *= D.BlockHandMult -- blades now collide: a braced guard must hold against a swing
			end
			setCF(f, Dr.SwordTarget, "CFrame", f.SwordHoldCF or f.SwordTargetCF, 0.004, rad(0.3))
		end
		setNum(f, Dr.HandPos, "MaxForce", D.HandForce * k, D.HandForce * 0.01)
		setNum(f, Dr.HandOri, "MaxTorque", D.HandTorque * k, D.HandTorque * 0.01)
		setNum(f, Dr.HandPos, "MaxVelocity", D.HandMaxVelocity * (0.6 + 0.4 * caps.SwordArm), 0.5)
	end
	if Dr.OffPos then
		setNum(f, Dr.OffPos, "MaxForce", twoHanded(f) and D.OffHandForce * armTone * caps.OffArm or 0, 5)
	end
end

return MotorController
