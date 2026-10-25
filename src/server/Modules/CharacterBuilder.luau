--[[
	CharacterBuilder: assembles a custom articulated fighter (no Humanoid, no R6/R15 rig).

	Physical structure
	  * 26 parts forming 18 anatomical segments (see Anatomy).
	  * Ball joints: BallSocketConstraint (limits + friction) driven by a TwoAttachment AlignOrientation
	    whose parent-side attachment is rotated to the desired relative pose (procedural motor).
	  * Elbows/knees: HingeConstraint servos.
	  * Limb halves: WeldConstraint seams (cut boundaries).
	  * Pelvis: AlignOrientation (upright/facing), LinearVelocity (planar locomotion), VectorForce (support).
	  * Sword hand: AlignPosition + AlignOrientation toward an attachment on the upper torso that the
	    sword controller moves; the katana is welded to the hand (grip joint).
	All drive strengths start at zero; MotorController sets them every frame from the state machine,
	so exactly one system owns every joint.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.RagdollRonin
local Config = require(Shared.Config)
local Anatomy = require(Shared.Anatomy)
local SwordBuilder = require(script.Parent.SwordBuilder)
local Runtime = require(Shared.Sim.Runtime)

local CharacterBuilder = {}

local S = Config.Scale
-- Hand-local frame of the sword grip: sword +Y points out of the fist (hand -Z), edge (+X) along hand -Y
local GRIP_ROT = CFrame.fromMatrix(Vector3.zero, Vector3.new(0, -1, 0), Vector3.new(0, 0, -1))
local AXIS_UP = CFrame.fromMatrix(Vector3.zero, Vector3.new(0, 1, 0), Vector3.new(-1, 0, 0))
local AXIS_DOWN = CFrame.fromMatrix(Vector3.zero, Vector3.new(0, -1, 0), Vector3.new(1, 0, 0))

local function attach(part, name, worldCF)
	local a = Instance.new("Attachment")
	a.Name = name
	a.CFrame = part.CFrame:ToObjectSpace(worldCF)
	a.Parent = part
	return a
end

local function newPart(def, pelvisCF, palette)
	local p = Instance.new("Part")
	p.Name = def.Name
	p.Size = def.Size * S
	p.CFrame = pelvisCF * CFrame.new(def.Center * S)
	p.Color = palette[def.Color] or Anatomy.Colors[def.Color] or Color3.new(0.5, 0.5, 0.5)
	p.Material = (def.Color == "Skin") and Enum.Material.SmoothPlastic or Enum.Material.Fabric
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.CanCollide = true
	p.CanTouch = false
	p.CanQuery = true
	p.CollisionGroup = def.Group == "Core" and "RR_Core" or "RR_Limb"
	local density = def.Group == "Core" and Config.Physics.TorsoDensity or Config.Physics.LimbDensity
	local friction = def.Segment:find("Foot") and Config.Physics.FootFriction or Config.Physics.Friction
	p.CustomPhysicalProperties = PhysicalProperties.new(density, friction, 0, 1, 1)
	p:SetAttribute("Segment", def.Segment)
	return p
end

-- spawnCF: ground position + facing. opts: { Name, GiColor }
function CharacterBuilder.Build(spawnCF, opts)
	opts = opts or {}
	local model = Instance.new("Model")
	model.Name = opts.Name or "Fighter"
	model:SetAttribute("RR_Fighter", true)
	-- streaming (required by server authority) must deliver the body whole or not at all
	model.ModelStreamingMode = Enum.ModelStreamingMode.Atomic

	local jointsFolder = Instance.new("Folder")
	jointsFolder.Name = "Joints"
	jointsFolder.Parent = model
	local drivesFolder = Instance.new("Folder")
	drivesFolder.Name = "Drives"
	drivesFolder.Parent = model

	local pelvisCF = spawnCF * CFrame.new(0, Config.Movement.StandHeight + 0.2, 0)
	local palette = { Gi = opts.GiColor }

	-- parts
	local parts = {}
	for _, def in ipairs(Anatomy.Parts) do
		local p = newPart(def, pelvisCF, palette)
		p.Parent = model
		parts[def.Name] = p
	end
	model.PrimaryPart = parts.LowerTorso

	-- face so the head's front is readable
	local face = Instance.new("Decal")
	face.Name = "face"
	face.Texture = "rbxasset://textures/face.png"
	face.Face = Enum.NormalId.Front
	face.Parent = parts.Head

	-- joints
	local joints = {}
	local adjacency = {}
	for name in pairs(parts) do
		adjacency[name] = {}
	end
	for _, jd in ipairs(Anatomy.Joints) do
		local pp, cp = parts[jd.Parent], parts[jd.Child]
		local pivotWorld = pelvisCF * CFrame.new(jd.Pivot * S)
		local rec = {
			Name = jd.Name,
			Def = jd,
			ParentName = jd.Parent,
			ChildName = jd.Child,
			Kind = jd.Type,
			PivotLocal = pp.CFrame:PointToObjectSpace(pivotWorld.Position),
			Instances = {},
			Severed = false,
		}
		if jd.Type == "Weld" then
			local w = Instance.new("WeldConstraint")
			w.Name = jd.Name
			w.Part0 = pp
			w.Part1 = cp
			w.Parent = jointsFolder
			rec.Constraint = w
			table.insert(rec.Instances, w)
		elseif jd.Type == "Ball" then
			local axisCF = pivotWorld * (jd.Axis == "Up" and AXIS_UP or AXIS_DOWN)
			local a0 = attach(pp, "J0_" .. jd.Name, axisCF)
			local a1 = attach(cp, "J1_" .. jd.Name, axisCF)
			local bs = Instance.new("BallSocketConstraint")
			bs.Name = jd.Name
			bs.Attachment0 = a0
			bs.Attachment1 = a1
			bs.LimitsEnabled = true
			bs.UpperAngle = jd.Cone
			bs.TwistLimitsEnabled = true
			bs.TwistLowerAngle = -jd.Twist
			bs.TwistUpperAngle = jd.Twist
			bs.MaxFrictionTorque = Config.Physics.JointFriction
			bs.Restitution = 0
			bs.Parent = jointsFolder
			rec.Constraint = bs
			table.insert(rec.Instances, bs)
			table.insert(rec.Instances, a0)
			table.insert(rec.Instances, a1)
			if jd.DriveClass then
				-- child attachment keeps the rest orientation; the parent-side attachment is the target
				local dc = attach(cp, "D0_" .. jd.Name, pivotWorld)
				local dp = attach(pp, "D1_" .. jd.Name, pivotWorld)
				local ao = Instance.new("AlignOrientation")
				ao.Name = "Drive_" .. jd.Name
				ao.Mode = Enum.OrientationAlignmentMode.TwoAttachment
				ao.Attachment0 = dc
				ao.Attachment1 = dp
				-- internal muscle: equal and opposite torque on the parent, so limbs cannot spin the body
				ao.ReactionTorqueEnabled = true
				ao.RigidityEnabled = false
				ao.MaxTorque = 0
				ao.Responsiveness = Config.Drives.Joint[jd.DriveClass].Responsiveness
				ao.Parent = jointsFolder
				rec.Drive = ao
				rec.TargetAtt = dp
				rec.TargetBase = dp.CFrame
				dp:SetAttribute("BaseCFrame", dp.CFrame) -- rest target, for client prediction
				table.insert(rec.Instances, ao)
				table.insert(rec.Instances, dc)
				table.insert(rec.Instances, dp)
			end
		elseif jd.Type == "Hinge" then
			local a0 = attach(pp, "J0_" .. jd.Name, pivotWorld) -- identity orientation: hinge axis = lateral X
			local a1 = attach(cp, "J1_" .. jd.Name, pivotWorld)
			local h = Instance.new("HingeConstraint")
			h.Name = jd.Name
			h.Attachment0 = a0
			h.Attachment1 = a1
			h.LimitsEnabled = true
			local sign = jd.RotSign * Config.Drives.HingeSign
			local l1, l2 = jd.FlexMin * sign, jd.FlexMax * sign
			h.LowerAngle = math.min(l1, l2)
			h.UpperAngle = math.max(l1, l2)
			h.Restitution = 0
			h.ActuatorType = Enum.ActuatorType.Servo
			h.ServoMaxTorque = 0
			h.AngularSpeed = Config.Drives.Joint[jd.DriveClass].Speed
			h.TargetAngle = 0
			h.Parent = jointsFolder
			rec.Constraint = h
			rec.Sign = sign
			table.insert(rec.Instances, h)
			table.insert(rec.Instances, a0)
			table.insert(rec.Instances, a1)
		end
		joints[jd.Name] = rec
		table.insert(adjacency[jd.Parent], { Part = jd.Child, Joint = jd.Name })
		table.insert(adjacency[jd.Child], { Part = jd.Parent, Joint = jd.Name })
	end

	for _, pair in ipairs(Anatomy.CoreNoCollide) do
		local nc = Instance.new("NoCollisionConstraint")
		nc.Part0 = parts[pair[1]]
		nc.Part1 = parts[pair[2]]
		nc.Parent = jointsFolder
	end

	-- pelvis drives
	local pelvis = parts.LowerTorso
	local root = attach(pelvis, "RootAtt", pelvisCF)
	local upright = Instance.new("AlignOrientation")
	upright.Name = "PelvisUpright"
	upright.Mode = Enum.OrientationAlignmentMode.OneAttachment
	upright.Attachment0 = root
	upright.CFrame = pelvisCF.Rotation
	upright.ReactionTorqueEnabled = false
	upright.MaxTorque = 0
	upright.Responsiveness = Config.Drives.PelvisResponsiveness
	upright.Parent = drivesFolder

	local move = Instance.new("LinearVelocity")
	move.Name = "Locomotion"
	move.Attachment0 = root
	move.VelocityConstraintMode = Enum.VelocityConstraintMode.Plane
	move.PrimaryTangentAxis = Vector3.xAxis
	move.SecondaryTangentAxis = Vector3.zAxis
	move.RelativeTo = Enum.ActuatorRelativeTo.World
	move.PlaneVelocity = Vector2.zero
	move.MaxForce = 0
	move.Parent = drivesFolder

	local support = Instance.new("VectorForce")
	support.Name = "Support"
	support.Attachment0 = root
	support.RelativeTo = Enum.ActuatorRelativeTo.World
	support.ApplyAtCenterOfMass = true
	support.Force = Vector3.zero
	support.Parent = drivesFolder

	-- sword hand drives + katana
	local hand = parts.RightHand
	local ut = parts.UpperTorso
	local gripWorld = hand.CFrame * CFrame.new(0, -0.05 * S, 0) * GRIP_ROT
	local handGrip = attach(hand, "SwordGrip", gripWorld)
	local swordTarget = attach(ut, "SwordTarget", gripWorld)

	local handPos = Instance.new("AlignPosition")
	handPos.Name = "HandPosition"
	handPos.Mode = Enum.PositionAlignmentMode.TwoAttachment
	handPos.Attachment0 = handGrip
	handPos.Attachment1 = swordTarget
	-- Reaction forces are essential: the target lives on the torso, so a one-sided force would let
	-- the arm drag the whole body forever (self-propulsion). With reaction it is an internal force.
	handPos.ReactionForceEnabled = true
	-- apply at the grip, not the hand+sword assembly COM (that leaves a large steady-state error)
	handPos.ApplyAtCenterOfMass = false
	handPos.MaxForce = 0
	handPos.Responsiveness = Config.Drives.HandResponsiveness
	handPos.MaxVelocity = Config.Drives.HandMaxVelocity
	handPos.Parent = drivesFolder

	local handOri = Instance.new("AlignOrientation")
	handOri.Name = "HandOrientation"
	handOri.Mode = Enum.OrientationAlignmentMode.TwoAttachment
	handOri.Attachment0 = handGrip
	handOri.Attachment1 = swordTarget
	handOri.ReactionTorqueEnabled = true
	handOri.MaxTorque = 0
	handOri.Responsiveness = Config.Drives.HandAngResponsiveness
	handOri.MaxAngularVelocity = Config.Drives.HandMaxAngularVelocity
	handOri.Parent = drivesFolder

	local sword = SwordBuilder.Build(gripWorld)
	sword.Model.Parent = model
	local gripJoint = Instance.new("WeldConstraint")
	gripJoint.Name = "GripJoint"
	gripJoint.Part0 = hand
	gripJoint.Part1 = sword.Handle
	gripJoint.Parent = sword.Model
	sword.GripJoint = gripJoint

	local offHand = parts.LeftHand
	local offGrip = attach(offHand, "OffGrip", offHand.CFrame * CFrame.new(0, -0.05 * S, 0))
	local offPos = Instance.new("AlignPosition")
	offPos.Name = "OffHandPosition"
	offPos.Mode = Enum.PositionAlignmentMode.TwoAttachment
	offPos.Attachment0 = offGrip
	offPos.Attachment1 = sword.OffGripAtt
	offPos.ReactionForceEnabled = true
	offPos.ApplyAtCenterOfMass = false
	offPos.MaxForce = 0
	offPos.Responsiveness = Config.Drives.OffHandResponsiveness
	offPos.Parent = drivesFolder

	local totalMass = 0
	for _, p in pairs(parts) do
		totalMass += p:GetMass()
	end
	for _, p in ipairs(sword.Model:GetChildren()) do
		if p:IsA("BasePart") and not p.Massless then
			totalMass += p:GetMass()
		end
	end

	return {
		Model = model,
		Parts = parts,
		Joints = joints,
		Adjacency = adjacency,
		JointsFolder = jointsFolder,
		Drives = {
			Folder = drivesFolder,
			Root = root,
			Upright = upright,
			Move = move,
			Support = support,
			HandPos = handPos,
			HandOri = handOri,
			SwordTarget = swordTarget,
			HandGrip = handGrip,
			OffPos = offPos,
		},
		Sword = sword,
		TotalMass = totalMass,
		PelvisCF = pelvisCF,
	}
end

-- Server-owned physics: clients never simulate fighter bodies (authority + exploit resistance).
function CharacterBuilder.ClaimOwnership(model)
	if Runtime.ServerAuthority then
		return -- the engine keeps server authority itself (and predicts the owner's fighter)
	end
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") and not d.Anchored then
			pcall(d.SetNetworkOwner, d, nil)
		end
	end
end

return CharacterBuilder
