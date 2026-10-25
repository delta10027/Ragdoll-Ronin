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
local AnatomyService = require(script.Parent.AnatomyService)
local BodyShape = require(script.Parent.BodyShape)

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
local function cacheOf(f, inst)
	local c = f.DriveCache[inst]
	if not c then
		c = {}
		f.DriveCache[inst] = c
	end
	return c
end

local function setNum(f, inst, prop, value, eps)
	local c = cacheOf(f, inst)
	local old = c[prop]
	if old == nil or math.abs(old - value) > eps or (value == 0 and old ~= 0) then
		inst[prop] = value
		c[prop] = value
	end
end

local function setCF(f, inst, prop, cf, posEps, angEps)
	local c = cacheOf(f, inst)
	local old = c[prop]
	if old == nil or (old.Position - cf.Position).Magnitude > posEps or Util.rotationDelta(old, cf) > angEps then
		inst[prop] = cf
		c[prop] = cf
	end
end

local function setVec(f, inst, prop, v, eps)
	local c = cacheOf(f, inst)
	local old = c[prop]
	if old == nil or (old - v).Magnitude > eps then
		inst[prop] = v
		c[prop] = v
	end
end

------------------------------------------------------------------ IK
-- Elbow swing candidates (degrees about the shoulder->target line), tried when the preferred
-- elbow would put the arm inside the torso or head. Ordered so the closest clear one wins.
local POLE_STEPS = { 0, 20, -20, 40, -40, 60, -60, 85, -85, 110, -110, 140, -140, 180 }
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

-- Two-bone arm IK in upper-torso space. Returns upper-arm rotation (rest frame: limb along -Y,
-- elbow flexion about +X toward -Z) and elbow flex angle.
-- avoid (optional table, kept per fighter and side): swing the elbow around the shoulder->target
-- line until the arm clears the body, preferring the requested pole and the previous choice.
local function solveArm(side, target, poleDir, l2, avoid)
	l2 = l2 or L2
	local shoulder = SHOULDER[side]
	local toT = target - shoulder
	local d = math.clamp(toT.Magnitude, 0.25 * (L1 + l2), (L1 + l2) * 0.999)
	local n = Util.unit(toT, Vector3.new(0, -1, 0))
	local cosA = math.clamp((L1 * L1 + d * d - l2 * l2) / (2 * L1 * d), -1, 1)
	local cosE = math.clamp((L1 * L1 + l2 * l2 - d * d) / (2 * L1 * l2), -1, 1)
	local flex = math.pi - math.acos(cosE)
	local fallbackPole = Util.perpendicular(POLE[side], n, Util.perpendicular(Vector3.new(0, 0, 1), n, Vector3.xAxis))
	local pole = poleDir and Util.perpendicular(poleDir, n, fallbackPole) or fallbackPole
	local sinA = math.sqrt(1 - cosA * cosA)
	if avoid then
		local tgt = shoulder + n * d
		local bestPole, bestCost, bestStep = pole, math.huge, 0
		local prev = avoid.Step or 0
		for _, step in ipairs(POLE_STEPS) do
			local p = step == 0 and pole or CFrame.fromAxisAngle(n, rad(step)):VectorToWorldSpace(pole)
			local elbow = shoulder + (n * cosA + p * sinA) * L1
			local pen = armPenetration(shoulder, elbow, tgt)
			local cost = pen + 0.0008 * math.abs(step) + 0.0004 * math.abs(step - prev)
			if cost < bestCost then
				bestPole, bestCost, bestStep = p, cost, step
			end
			if pen == 0 and step == 0 and prev == 0 then
				break -- common case: the natural elbow is already clear
			end
		end
		pole = bestPole
		avoid.Step = bestStep
	end
	local u = n * cosA + pole * sinA -- upper arm direction
	local elbow = shoulder + u * L1
	local fore = Util.unit(target - elbow, n)
	local Y = -u
	local Z = -Util.perpendicular(fore, u, -pole) -- forearm deviates toward local -Z
	local X = Y:Cross(Z)
	return CFrame.fromMatrix(Vector3.zero, X, Y, Z), flex
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

-- off-hand grip point on the hilt (upper-torso space)
local function offHandTarget(f)
	return (f.SwordTargetCF * CFrame.new(0, -0.55 * Config.Sword.HandleLength, 0)).Position
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

local function armPose(f, pose)
	f.ArmAvoid = f.ArmAvoid or { Right = {}, Left = {} }
	updateOffHandGrip(f)
	if f.Sword and f.Joints.RightShoulder and not f.Joints.RightShoulder.Severed and f.SwordTargetCF then
		-- orientation-aware IK: aim the wrist, and bend the elbow toward where the forearm would
		-- naturally be for the requested hand orientation, so the wrist needs minimal bending
		local handCF = f.SwordTargetCF * GRIP_LOCAL_INV
		local wrist = handCF:PointToWorldSpace(WRIST_IN_HAND)
		local idealElbow = wrist + handCF.UpVector * L_FOREARM
		local rot, flex = solveArm("Right", wrist, idealElbow - SHOULDER.Right, L_FOREARM, f.ArmAvoid.Right)
		pose.RightShoulder = rot
		pose.RightElbow = flex
	elseif not pose.RightShoulder then
		hangArms(pose, "Right")
	end
	if twoHanded(f) then
		local rot, flex = solveArm("Left", offHandTarget(f), nil, nil, f.ArmAvoid.Left)
		pose.LeftShoulder = rot
		pose.LeftElbow = flex
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
	local torsoYaw = 0
	local lean = rad(6)
	if st == "Attacking" then
		torsoYaw = -aim.U * 0.45
		lean += rad(6) * math.clamp(0.5 - aim.V * 0.5, 0, 1)
	elseif st == "Blocking" then
		torsoYaw = -aim.U * 0.25
	end
	pose.Waist = CFrame.Angles(0, torsoYaw, 0) * CFrame.Angles(-lean, 0, 0)
	pose.NeckBase = CFrame.Angles(0, -torsoYaw * 0.5, 0)
	pose.NeckHead = CFrame.Angles(lean * 0.5, -torsoYaw * 0.5, 0)
	if f.Caps.Kneeling then
		kneelLegs(f, pose)
	else
		standLegs(f, dt, pose)
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

	-- 1. joints
	local pose = MotorController.ComputePose(f, dt)
	for name, j in pairs(f.Joints) do
		if not j.Severed then
			local cls = j.Def.DriveClass and D.Joint[j.Def.DriveClass]
			if cls then
				local segF = AnatomyService.SegmentFactor(f, Anatomy.PartByName[j.ChildName].Segment)
				local t = (ARM_CLASS[j.Def.DriveClass] and armTone or bodyTone) * (0.25 + 0.75 * segF)
				if name == "RightWrist" and f.Sword then
					t = 0 -- the sword drive owns the sword hand's orientation
				end
				if j.Kind == "Ball" and j.Drive then
					setNum(f, j.Drive, "MaxTorque", cls.Torque * t, cls.Torque * 0.02)
					setCF(f, j.TargetAtt, "CFrame", j.TargetBase * (pose[name] or CFrame.identity), 0.01, D.TargetAngleEpsilon)
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
		local rate = (st == "Attacking" or st == "Blocking") and M.AttackTurnRate or M.TurnRate
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
	end
	setCF(f, Dr.Upright, "CFrame", leanCF * CFrame.Angles(0, f.FacingYaw, 0), 1, rad(0.5))
	local uprightTone = tone.Upright * (st == "Recovering" and r * Config.Recovery.UprightTorqueScale or 1)
	setNum(f, Dr.Upright, "MaxTorque", D.PelvisTorquePerMass * f.TotalMass * uprightTone * caps.Stability, 5)

	-- 3. locomotion
	local moveDir = StateDefs.Upright[st] and inp.Move or Vector3.zero
	local speed = M.WalkSpeed * tone.Move * caps.Move * (caps.Kneeling and M.KneelSpeedMult or 1)
	local vel = moveDir * speed
	f.CommandedVelocity = vel
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
		force = f.TotalMass * acc * tone.Support * r
	end
	setVec(f, Dr.Support, "Force", Vector3.new(0, force, 0), f.TotalMass * 2)

	-- 5. hands
	if Dr.HandPos and Dr.HandOri then
		local k = 0
		if f.Sword and f.SwordTargetCF then
			k = armTone * caps.SwordArm * caps.Grip
			if os.clock() < f.Attack.RecoilUntil then
				k *= Config.Combat.RecoilHandScale
			elseif st == "Blocking" then
				k *= D.BlockHandMult -- blades now collide: a braced guard must hold against a swing
			end
			setCF(f, Dr.SwordTarget, "CFrame", f.SwordTargetCF, 0.004, rad(0.3))
		end
		setNum(f, Dr.HandPos, "MaxForce", D.HandForce * k, D.HandForce * 0.01)
		setNum(f, Dr.HandOri, "MaxTorque", D.HandTorque * k, D.HandTorque * 0.01)
		setNum(f, Dr.HandPos, "MaxVelocity", D.HandMaxVelocity * (0.6 + 0.4 * caps.SwordArm), 0.5)
	end
	if Dr.OffPos then
		setNum(f, Dr.OffPos, "MaxForce", twoHanded(f) and D.OffHandForce * armTone * caps.OffArm or 0, 5)
	end
end

MotorController.SolveArm = solveArm
return MotorController
