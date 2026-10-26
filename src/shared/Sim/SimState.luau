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
	client compute slightly different poses than the server and mispredict every step), rounded to
	QUANTUM, and the rounded value is what both sides continue from: the client may compute the
	last digits of a sin/acos differently from the server, and rounding absorbs that.
	Injury-derived capabilities and segment strengths are server-only inputs; the client just reads
	them. In Owner mode (Runtime.OwnerPhysics) the same attributes are the owning client's own
	state store: the server writes everything once at spawn and afterwards only those server-only
	inputs (StoreServer); its other decisions arrive through OwnerSync. Store() skips unchanged values; OnRollback() forgets what was written so nothing is skipped
	after the engine restores older values.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.RagdollRonin
local Config = require(Shared.Config)
local Anatomy = require(Shared.Anatomy)
local Input = require(script.Parent.Input)

local SimState = {}

local LT, UT = "LowerTorso", "UpperTorso"
local QUANTUM = 1e-6
local FIELDS = {} -- { Part, Name, Get(f), Set(f, v) }
local VECS = {} -- { Part, Name, Get(f), Set(f, v) }: stored as three number attributes

-- server: true for values only the server computes (injuries); StoreServer() writes just those
local function field(part, name, get, set, server)
	table.insert(FIELDS, { Part = part, Name = "S_" .. name, Get = get, Set = set, Server = server })
end

local function vecField(part, name, get, set)
	local n = "S_" .. name
	table.insert(VECS, { Part = part, X = n .. "X", Y = n .. "Y", Z = n .. "Z", Get = get, Set = set })
end

local function q(x)
	return math.round(x / QUANTUM) * QUANTUM
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
field(LT, "GaitStride", function(f) return f.Gait.Stride end, function(f, v) f.Gait.Stride = v or 0 end)
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
vecField(UT, "AimEdge", function(f) return f.Aim.Edge end, function(f, v) f.Aim.Edge = v or Vector3.new(0, -1, 0) end)
-- a bound (blocked) attack: where the cursor was stopped and the direction it may not push on.
-- BindU comes first: it creates or clears the record the other three fill in.
field(UT, "BindU", function(f) return f.Aim.Bind and f.Aim.Bind.U end, function(f, v)
	if v == nil then
		f.Aim.Bind = nil
	else
		f.Aim.Bind = f.Aim.Bind or { U = v, V = 0, DU = 0, DV = -1 }
		f.Aim.Bind.U = v
	end
end)
for _, key in ipairs({ "V", "DU", "DV" }) do
	field(UT, "Bind" .. key, function(f) return f.Aim.Bind and f.Aim.Bind[key] end, function(f, v)
		if f.Aim.Bind and v ~= nil then
			f.Aim.Bind[key] = v
		end
	end)
end
-- speed-limited sword target (MotorController.limitTurn): blade direction and edge
vecField(UT, "SwordAimDir", function(f) return f.SwordAimDir end, function(f, v) f.SwordAimDir = v end)
vecField(UT, "SwordAimEdge", function(f) return f.SwordAimEdge end, function(f, v) f.SwordAimEdge = v end)
field(UT, "BlockActive", function(f) return f.Block.Active end, function(f, v) f.Block.Active = v == true end)
field(UT, "BlockStart", function(f) return f.Block.StartTime end, function(f, v) f.Block.StartTime = v or 0 end)
field(UT, "ReleaseTime", function(f) return f.Attack.ReleaseTime end, function(f, v) f.Attack.ReleaseTime = v end)
field(UT, "FollowThrough", function(f) return f.Attack.FollowThrough end, function(f, v) f.Attack.FollowThrough = v == true end)
field(UT, "StrokeActive", function(f) return f.Attack.Stroke ~= nil or f.Attack.StrokeActive == true end, function(f, v)
	f.Attack.StrokeActive = v == true
end)
field(UT, "RecoilUntil", function(f) return f.Attack.RecoilUntil end, function(f, v) f.Attack.RecoilUntil = v or 0 end)
field(LT, "KickHeld", function(f) return f.KickHeld end, function(f, v) f.KickHeld = v == true end)
field(LT, "KickReadyAt", function(f) return f.KickReadyAt end, function(f, v) f.KickReadyAt = v or 0 end)
-- motor controller memory
field(UT, "LimbsCollide", function(f) return f.LimbsCollide end, function(f, v) f.LimbsCollide = v end)
field(UT, "OffHandFree", function(f) return f.OffHandFree end, function(f, v) f.OffHandFree = v == true end)
field(UT, "ArmSwivelR", function(f) return f.ArmState and f.ArmState.Swivel end, function(f, v) f.ArmState.Swivel = v or 0 end)
field(UT, "ArmRollR", function(f) return f.ArmState and f.ArmState.Roll end, function(f, v) f.ArmState.Roll = v or 0 end)
field(UT, "ArmSwivelL", function(f) return f.ArmState and f.ArmState.SwivelL end, function(f, v) f.ArmState.SwivelL = v or 0 end)
-- server-only inputs to the simulation
field(UT, "TotalMass", function(f) return f.TotalMass end, function(f, v) f.TotalMass = v or 1 end, true)
-- drawing / sheathing (Sim.Draw): where the sword is, the running animation and its time
field(UT, "Sheathed", function(f) return f.Sheathed == true end, function(f, v) f.Sheathed = v == true end)
field(UT, "DrawKind", function(f) return f.DrawKind end, function(f, v) f.DrawKind = v end)
field(UT, "DrawT", function(f) return f.DrawT end, function(f, v) f.DrawT = v or 0 end)
field(UT, "SheathHeld", function(f) return f.SheathHeld end, function(f, v) f.SheathHeld = v == true end)
-- incantation (Sim.Incant)
field(UT, "IncantT", function(f) return f.IncantT end, function(f, v) f.IncantT = v end)
field(UT, "IncantHeld", function(f) return f.IncantHeld end, function(f, v) f.IncantHeld = v == true end)
field(UT, "IncantReadyAt", function(f) return f.IncantReadyAt end, function(f, v) f.IncantReadyAt = v end)
-- bowing (Sim.Bow)
field(UT, "BowT", function(f) return f.BowT end, function(f, v) f.BowT = v end)
field(UT, "BowHeld", function(f) return f.BowHeld end, function(f, v) f.BowHeld = v == true end)
local CAP_KEYS = { "LegLeft", "LegRight", "LegSupport", "SwordArm", "OffArm", "Grip", "Strength", "Move", "Stability", "BalanceRegen", "BalanceMax", "Kneeling", "Incapacitated" }
for _, key in ipairs(CAP_KEYS) do
	field(UT, "Cap_" .. key, function(f) return f.Caps[key] end, function(f, v) f.Caps[key] = v end, true)
end
local SEGMENTS = {}
for name in pairs(Anatomy.Segments) do
	table.insert(SEGMENTS, name)
end
table.sort(SEGMENTS)
for _, name in ipairs(SEGMENTS) do
	field(LT, "Seg_" .. name, function(f) return f.SegFactor[name] end, function(f, v) f.SegFactor[name] = v or 0 end, true)
end

local NIL = {} -- remembers "attribute cleared" in SimWritten

local function write(part, written, name, v)
	local key = if v == nil then NIL else v
	if written[name] ~= key then
		part:SetAttribute(name, v)
		written[name] = key
	end
end

function SimState.Store(f, serverOnly)
	local written = f.SimWritten
	if not written then
		written = {}
		f.SimWritten = written
	end
	for _, fd in ipairs(FIELDS) do
		local part = f.Parts[fd.Part]
		if part and (fd.Server or not serverOnly) then
			local v = fd.Get(f)
			if type(v) == "number" then
				local r = q(v)
				if r ~= v then
					v = r
					fd.Set(f, v) -- continue from exactly what was published
				end
			end
			write(part, written, fd.Name, v)
		end
	end
	for _, vd in ipairs(VECS) do
		local part = not serverOnly and f.Parts[vd.Part]
		if part then
			local v = vd.Get(f)
			local x, y, z
			if v then
				x, y, z = q(v.X), q(v.Y), q(v.Z)
				vd.Set(f, Vector3.new(x, y, z))
			end
			write(part, written, vd.X, x)
			write(part, written, vd.Y, y)
			write(part, written, vd.Z, z)
		end
	end
end

-- Owner mode: the owning client simulates the fighter and keeps everything else; the server only
-- publishes the injury-derived values (see server OwnerSync)
function SimState.StoreServer(f)
	SimState.Store(f, true)
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
		fd.Set(f, v)
	end
	for _, vd in ipairs(VECS) do
		local part = vd.Part == LT and lt or ut
		local x, y, z = part:GetAttribute(vd.X), part:GetAttribute(vd.Y), part:GetAttribute(vd.Z)
		written[vd.X] = if x == nil then NIL else x
		written[vd.Y] = if y == nil then NIL else y
		written[vd.Z] = if z == nil then NIL else z
		vd.Set(f, (x and y and z) and Vector3.new(x, y, z) or nil)
	end
	return true
end

-- Owner mode, every step after the first Load: only the server-only inputs (injury capabilities,
-- segment strengths, mass) can have changed under the owning client, which keeps everything else
-- in its own Lua record. Much cheaper than a full Load + Store every step.
local SERVER_FIELDS = {}
for _, fd in ipairs(FIELDS) do
	if fd.Server then
		table.insert(SERVER_FIELDS, fd)
	end
end
function SimState.LoadServer(f)
	local lt, ut = f.Parts[LT], f.Parts[UT]
	if not lt or not ut then
		return false
	end
	for _, fd in ipairs(SERVER_FIELDS) do
		fd.Set(f, (fd.Part == LT and lt or ut):GetAttribute(fd.Name))
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
		local saya = model:FindFirstChild("Saya")
		sword = {
			Model = katana,
			Handle = katana.Handle,
			Blade = katana.Blade,
			ParryZone = katana:FindFirstChild("ParryZone"),
			Collider = katana:FindFirstChild("BladeCollider"),
			GripJoint = katana:FindFirstChild("GripJoint"),
			HandLocal = katana.Handle:GetAttribute("HandLocal"),
			Saya = saya,
			SayaWeld = saya and saya:FindFirstChild("SayaWeld"),
			SheathWeld = saya and saya:FindFirstChild("SheathWeld"),
			SayaBase = saya and saya:GetAttribute("BaseC0"),
			InSaya = saya and saya:GetAttribute("InSaya"),
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
		Gait = { Phase = 0, Stride = 0 },
		Recovery = { Attempts = 0 },
		Aim = { U = Config.Aim.ReadyU, V = Config.Aim.ReadyV, VU = 0, VV = 0, Edge = Vector3.new(0, -1, 0), Guard = 0, Ready = 1 },
		Attack = { Phase = "Ready", RecoilUntil = 0, SegmentHitTimes = {} },
		Block = { Active = false, StartTime = 0 },
		ArmState = { Swivel = 0, Roll = 0, SwivelL = 0 },
	}
end

return SimState
