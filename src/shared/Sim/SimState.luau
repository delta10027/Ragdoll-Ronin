--[[
	SimState: makes a fighter's simulation predictable under server authority.

	The controllers (BalanceController, SwordController.UpdateAim, MotorController) keep their
	state in Lua tables on the fighter record `f`. The server authority system only rolls back and
	re-syncs instance properties and attributes, so every value those controllers carry from one
	step to the next is mirrored into attributes on the torso parts:

	  server  runs the step, then Store(f): attributes = authoritative state (including anything
	          combat, anatomy or lifecycle changed outside the simulation since the last step)
	  client  Load(f) at the start of every step (attributes hold either its own prediction from the
	          previous step, or the server's state after a rollback), runs the same step, Store(f)

	Numbers are stored as doubles (Vector3 attributes are single precision, which would make the
	client compute slightly different poses than the server and mispredict every step).
	Injury-derived capabilities and segment strengths are server-only inputs; the client just reads
	them. Store() skips unchanged values; OnRollback() forgets what was written so nothing is skipped
	after the engine restores older values.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.RagdollRonin
local Config = require(Shared.Config)
local Anatomy = require(Shared.Anatomy)
local Input = require(script.Parent.Input)

local SimState = {}

local LT, UT = "LowerTorso", "UpperTorso"
local FIELDS = {} -- { Part, Name, Get(f), Set(f, v) }

local function field(part, name, get, set)
	table.insert(FIELDS, { Part = part, Name = "S_" .. name, Get = get, Set = set })
end

local function vecField(part, name, get, set)
	field(part, name .. "X", function(f)
		local v = get(f)
		return v and v.X
	end, function() end)
	field(part, name .. "Y", function(f)
		local v = get(f)
		return v and v.Y
	end, function() end)
	field(part, name .. "Z", function(f)
		local v = get(f)
		return v and v.Z
	end, function(f, z, part0)
		-- the Z setter runs last and assembles the vector from all three attributes
		local x, y = part0:GetAttribute("S_" .. name .. "X"), part0:GetAttribute("S_" .. name .. "Y")
		set(f, (x and y and z) and Vector3.new(x, y, z) or nil)
	end)
end

-- state machine / balance (pelvis)
field(LT, "State", function(f) return f.State end, function(f, v) f.State = v end)
field(LT, "StateTime", function(f) return f.StateTime end, function(f, v) f.StateTime = v end)
field(LT, "Balance", function(f) return f.Balance end, function(f, v) f.Balance = v end)
field(LT, "TiltTimer", function(f) return f.TiltTimer end, function(f, v) f.TiltTimer = v end)
field(LT, "AirTimer", function(f) return f.AirTimer end, function(f, v) f.AirTimer = v end)
field(LT, "LastLegSupport", function(f) return f.LastLegSupport end, function(f, v) f.LastLegSupport = v end)
field(LT, "TargetHeight", function(f) return f.TargetHeight end, function(f, v) f.TargetHeight = v end)
field(LT, "Attempts", function(f) return f.Recovery.Attempts end, function(f, v) f.Recovery.Attempts = v or 0 end)
field(LT, "RecoverRequested", function(f) return f.RecoverRequested end, function(f, v) f.RecoverRequested = v == true end)
field(LT, "FacingYaw", function(f) return f.FacingYaw end, function(f, v) f.FacingYaw = v end)
field(LT, "GaitPhase", function(f) return f.Gait.Phase end, function(f, v) f.Gait.Phase = v or 0 end)
field(LT, "Dead", function(f) return f.Dead end, function(f, v) f.Dead = v == true end)
-- StateData (the per-state scratch table)
for _, key in ipairs({ "Until", "FaceDown", "R", "StartHeight", "Yaw", "Stable", "Attempt", "Wait" }) do
	field(LT, "SD_" .. key, function(f) return f.StateData[key] end, function(f, v) f.StateData[key] = v end)
end
vecField(LT, "SD_PushDir", function(f) return f.StateData.PushDir end, function(f, v) f.StateData.PushDir = v end)

-- sword aim / attack / guard (upper torso)
field(UT, "AimU", function(f) return f.Aim.U end, function(f, v) f.Aim.U = v end)
field(UT, "AimV", function(f) return f.Aim.V end, function(f, v) f.Aim.V = v end)
field(UT, "AimVU", function(f) return f.Aim.VU end, function(f, v) f.Aim.VU = v end)
field(UT, "AimVV", function(f) return f.Aim.VV end, function(f, v) f.Aim.VV = v end)
field(UT, "AimGuard", function(f) return f.Aim.Guard end, function(f, v) f.Aim.Guard = v end)
field(UT, "AimReady", function(f) return f.Aim.Ready end, function(f, v) f.Aim.Ready = v end)
field(UT, "GuardFlip", function(f) return f.Aim.GuardFlip end, function(f, v) f.Aim.GuardFlip = v == true end)
vecField(UT, "AimEdge", function(f) return f.Aim.Edge end, function(f, v) f.Aim.Edge = v or Vector3.new(0, -1, 0) end)
field(UT, "BlockActive", function(f) return f.Block.Active end, function(f, v) f.Block.Active = v == true end)
field(UT, "BlockStart", function(f) return f.Block.StartTime end, function(f, v) f.Block.StartTime = v or 0 end)
field(UT, "ReleaseTime", function(f) return f.Attack.ReleaseTime end, function(f, v) f.Attack.ReleaseTime = v end)
field(UT, "FollowThrough", function(f) return f.Attack.FollowThrough end, function(f, v) f.Attack.FollowThrough = v == true end)
field(UT, "StrokeActive", function(f) return f.Attack.Stroke ~= nil or f.Attack.StrokeActive == true end, function(f, v)
	f.Attack.StrokeActive = v == true
end)
field(UT, "RecoilUntil", function(f) return f.Attack.RecoilUntil end, function(f, v) f.Attack.RecoilUntil = v or 0 end)
-- motor controller memory
field(UT, "LimbsCollide", function(f) return f.LimbsCollide end, function(f, v) f.LimbsCollide = v end)
field(UT, "OffHandFree", function(f) return f.OffHandFree end, function(f, v) f.OffHandFree = v == true end)
field(UT, "ArmStepR", function(f) return f.ArmAvoid and f.ArmAvoid.Right.Step end, function(f, v) f.ArmAvoid.Right.Step = v end)
field(UT, "ArmStepL", function(f) return f.ArmAvoid and f.ArmAvoid.Left.Step end, function(f, v) f.ArmAvoid.Left.Step = v end)
-- server-only inputs to the simulation
field(UT, "TotalMass", function(f) return f.TotalMass end, function(f, v) f.TotalMass = v or 1 end)
local CAP_KEYS = { "LegLeft", "LegRight", "LegSupport", "SwordArm", "OffArm", "Grip", "Strength", "Move", "Stability", "BalanceRegen", "BalanceMax", "Kneeling", "Incapacitated" }
for _, key in ipairs(CAP_KEYS) do
	field(UT, "Cap_" .. key, function(f) return f.Caps[key] end, function(f, v) f.Caps[key] = v end)
end
local SEGMENTS = {}
for name in pairs(Anatomy.Segments) do
	table.insert(SEGMENTS, name)
end
table.sort(SEGMENTS)
for _, name in ipairs(SEGMENTS) do
	field(LT, "Seg_" .. name, function(f) return f.SegFactor[name] end, function(f, v) f.SegFactor[name] = v or 0 end)
end

local NIL = {} -- remembers "attribute cleared" in SimWritten

function SimState.Store(f)
	local written = f.SimWritten
	if not written then
		written = {}
		f.SimWritten = written
	end
	for _, fd in ipairs(FIELDS) do
		local part = f.Parts[fd.Part]
		if part then
			local v = fd.Get(f)
			local key = if v == nil then NIL else v
			if written[fd.Name] ~= key then
				part:SetAttribute(fd.Name, v)
				written[fd.Name] = key
			end
		end
	end
end

-- Returns false until the server has written the state at least once
function SimState.Load(f)
	local lt, ut = f.Parts[LT], f.Parts[UT]
	if not lt or not ut or lt:GetAttribute("S_State") == nil then
		return false
	end
	f.StateData = {}
	local written = f.SimWritten or {}
	f.SimWritten = written
	for _, fd in ipairs(FIELDS) do
		local part = fd.Part == LT and lt or ut
		local v = part:GetAttribute(fd.Name)
		written[fd.Name] = if v == nil then NIL else v
		fd.Set(f, v, part)
	end
	return true
end

-- After a rollback the engine has restored older attribute and property values: forget what this
-- client thinks it last wrote so the next step writes everything again.
function SimState.OnRollback(f)
	f.SimWritten = {}
	f.DriveCache = setmetatable({}, { __mode = "k" })
end

------------------------------------------------------------------ client fighter record
-- Builds the record the controllers need from a replicated fighter model (client prediction).
-- Returns nil while the model is incomplete (e.g. still streaming in).
function SimState.BuildClient(model, player)
	local parts = {}
	for _, def in ipairs(Anatomy.Parts) do
		local p = model:FindFirstChild(def.Name)
		if p and p:IsA("BasePart") then
			parts[def.Name] = p
		end
	end
	local jointsFolder = model:FindFirstChild("Joints")
	local drivesFolder = model:FindFirstChild("Drives")
	if not parts.LowerTorso or not parts.UpperTorso or not jointsFolder or not drivesFolder then
		return nil
	end
	local joints = {}
	for _, jd in ipairs(Anatomy.Joints) do
		local c = jointsFolder:FindFirstChild(jd.Name)
		local rec = {
			Name = jd.Name,
			Def = jd,
			ParentName = jd.Parent,
			ChildName = jd.Child,
			Kind = jd.Type,
			Constraint = c,
			Severed = c == nil or parts[jd.Parent] == nil or parts[jd.Child] == nil,
		}
		if jd.Type == "Ball" and jd.DriveClass then
			rec.Drive = jointsFolder:FindFirstChild("Drive_" .. jd.Name)
			rec.TargetAtt = parts[jd.Parent] and parts[jd.Parent]:FindFirstChild("D1_" .. jd.Name)
			rec.TargetBase = rec.TargetAtt and rec.TargetAtt:GetAttribute("BaseCFrame")
			if not (rec.Drive and rec.TargetAtt and rec.TargetBase) then
				rec.Severed = true
			end
		elseif jd.Type == "Hinge" then
			rec.Sign = jd.RotSign * Config.Drives.HingeSign
		end
		joints[jd.Name] = rec
	end
	local drives = {
		Folder = drivesFolder,
		Upright = drivesFolder:FindFirstChild("PelvisUpright"),
		Move = drivesFolder:FindFirstChild("Locomotion"),
		Support = drivesFolder:FindFirstChild("Support"),
		HandPos = drivesFolder:FindFirstChild("HandPosition"),
		HandOri = drivesFolder:FindFirstChild("HandOrientation"),
		OffPos = drivesFolder:FindFirstChild("OffHandPosition"),
		SwordTarget = parts.UpperTorso:FindFirstChild("SwordTarget"),
	}
	if not drives.Upright or not drives.Move or not drives.Support then
		return nil
	end
	local sword
	local katana = model:FindFirstChild("Katana")
	if katana and katana:FindFirstChild("Handle") and katana:FindFirstChild("Blade") then
		sword = {
			Model = katana,
			Handle = katana.Handle,
			Blade = katana.Blade,
			ParryZone = katana:FindFirstChild("ParryZone"),
			Collider = katana:FindFirstChild("BladeCollider"),
		}
	end
	return {
		IsPrediction = true,
		Id = model:GetAttribute("FighterId"),
		Name = model.Name,
		Player = player,
		Model = model,
		Parts = parts,
		Joints = joints,
		Drives = drives,
		Sword = sword,
		TotalMass = 1,
		DriveCache = setmetatable({}, { __mode = "k" }),
		Input = Input.Neutral(),
		Caps = {},
		SegFactor = {},
		StateData = {},
		StateHistory = {},
		Gait = { Phase = 0 },
		Recovery = { Attempts = 0 },
		Aim = { U = Config.Aim.ReadyU, V = Config.Aim.ReadyV, VU = 0, VV = 0, Edge = Vector3.new(0, -1, 0), Guard = 0, Ready = 1 },
		Attack = { Phase = "Ready", RecoilUntil = 0, SegmentHitTimes = {} },
		Block = { Active = false, StartTime = 0 },
		ArmAvoid = { Right = {}, Left = {} },
	}
end

return SimState
