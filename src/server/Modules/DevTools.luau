--[[
	DevTools (Studio only): a BindableFunction ServerStorage.RR_DevCommand used for repeatable tests.
	Not created in live servers. Dummies are ordinary fighters driven by an input override - they run
	through exactly the same controllers, hit detection and anatomy as players.

	Examples (server command bar during Play):
	  local dev = game.ServerStorage.RR_DevCommand
	  local id = dev:Invoke("spawnDummy", { Position = Vector3.new(0,0,-6), Yaw = math.pi })
	  dev:Invoke("setInput", id, { M2 = true, AimU = -0.8, AimV = 0 })
	  print(dev:Invoke("status", id))
]]
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.RagdollRonin
local Config = require(Shared.Config)
local Anatomy = require(Shared.Anatomy)
local Registry = require(script.Parent.Registry)
local Input = require(Shared.Sim.Input)
local AnatomyService = require(script.Parent.AnatomyService)
local Dismemberment = require(script.Parent.Dismemberment)
local CombatResolver = require(script.Parent.CombatResolver)

local DevTools = {}

local function fighterSummary(f)
	local A = f.Anatomy
	local segs = {}
	for name, rec in pairs(A.Segments) do
		if rec.Integrity < 100 or rec.Severed or rec.Bleeding > 0 then
			segs[name] = string.format("i=%.0f b=%.1f%s%s", rec.Integrity, rec.Bleeding, rec.Severed and " SEVERED" or "", rec.Lost and " LOST" or "")
		end
	end
	local organs = {}
	for name, rec in pairs(A.Organs) do
		if rec.Health < 100 then
			organs[name] = math.floor(rec.Health)
		end
	end
	local pelvis = f.Parts.LowerTorso
	return {
		Id = f.Id,
		Name = f.Name,
		State = f.State,
		StateReason = f.Model:GetAttribute("StateReason"),
		AttackPhase = f.Attack.Phase,
		TipSpeed = math.floor(f.Attack.TipSpeed * 10) / 10,
		Balance = math.floor(f.Balance),
		Blood = math.floor(A.Blood),
		BleedRate = math.floor(A.BleedRate * 10) / 10,
		Incapacitated = A.Incapacitated,
		PendingDeath = A.PendingDeath and A.PendingDeath.Reason,
		Dead = f.Dead,
		DeathReason = f.DeathReason,
		HasSword = f.Sword ~= nil,
		Caps = {
			LegSupport = math.floor(f.Caps.LegSupport * 100) / 100,
			SwordArm = math.floor(f.Caps.SwordArm * 100) / 100,
			Grip = math.floor(f.Caps.Grip * 100) / 100,
			Move = math.floor(f.Caps.Move * 100) / 100,
			Strength = math.floor(f.Caps.Strength * 100) / 100,
			Kneeling = f.Caps.Kneeling,
		},
		Position = pelvis and pelvis.Position,
		Height = f.Ground and math.floor(f.Ground.Height * 100) / 100,
		UpDot = f.UpDot and math.floor(f.UpDot * 100) / 100,
		Segments = segs,
		Organs = organs,
		Stumps = (function()
			local t = {}
			for k, s in pairs(A.Stumps) do
				t[k] = math.floor(s.Rate)
			end
			return t
		end)(),
		Log = A.InjuryLog,
		History = f.StateHistory,
		LastBlock = f.Model:GetAttribute("LastBlock"),
		LastInjury = f.Model:GetAttribute("LastInjury"),
	}
end

-- Deterministic anatomy test: apply a strike to a segment without physics (dev only)
local function testStrike(f, segName, power, kind, quality, fromDir, kill)
	local partName = Anatomy.SegmentParts[segName] and Anatomy.SegmentParts[segName][1]
	local part = partName and f.Parts[partName]
	if not part then
		return "segment not attached"
	end
	local dir = (fromDir or -part.CFrame.LookVector).Unit -- default: from the front, inward
	local pos = part.Position - dir * (math.max(part.Size.X, part.Size.Z) * 0.5)
	local strike = AnatomyService.ApplyStrike(f, {
		Segment = segName, Part = part, Position = pos, Direction = dir, BladeAxis = dir,
		Power = power, Kind = kind or "Cut", Quality = quality or 1,
	})
	if strike.SeverBoundary then
		local distal = Dismemberment.Sever(f, strike.SeverBoundary, dir, power)
		if distal then
			AnatomyService.OnSevered(f, strike.SeverBoundary, distal)
		end
	end
	local fatal = AnatomyService.CheckFatal(f)
	if fatal and kill then
		kill(f, fatal)
	end
	return { Summary = strike.Summary, Sever = strike.SeverBoundary, Fatal = fatal, Organs = strike.Organs }
end

function DevTools.Init(api)
	if not RunService:IsStudio() or not Config.Debug.DevToolsInStudio then
		return
	end
	local bf = ServerStorage:FindFirstChild("RR_DevCommand") or Instance.new("BindableFunction")
	bf.Name = "RR_DevCommand"
	bf.Parent = ServerStorage
	bf.OnInvoke = function(cmd, a, b, c, d, e)
		if cmd == "spawnDummy" then
			a = a or {}
			local f = api.Spawn(nil, { Name = a.Name, Position = a.Position, Yaw = a.Yaw, RespawnDummy = a.Respawn })
			return f.Id
		elseif cmd == "setInput" then
			local f = Registry.ById[a]
			if not f then
				return false
			end
			local i = Input.Neutral()
			i.Yaw = f.FacingYaw
			for k, v in pairs(b or {}) do
				i[k] = v
			end
			f.InputOverride = i
			return true
		elseif cmd == "clearInput" then
			local f = Registry.ById[a]
			if f then
				f.InputOverride = nil
			end
			return true
		elseif cmd == "status" then
			if a then
				local f = Registry.ById[a]
				return f and fighterSummary(f) or nil
			end
			local all = {}
			for _, f in ipairs(Registry.List()) do
				table.insert(all, fighterSummary(f))
			end
			return all
		elseif cmd == "list" then
			local ids = {}
			for _, f in ipairs(Registry.List()) do
				ids[f.Name] = f.Id
			end
			return ids
		elseif cmd == "playerFighter" then
			local p = a and Players:FindFirstChild(a) or Players:GetPlayers()[1]
			local f = p and Registry.ByPlayer[p]
			return f and f.Id
		elseif cmd == "kill" then
			local f = Registry.ById[a]
			if f then
				api.Kill(f, b or "Dev kill")
			end
			return true
		elseif cmd == "remove" then
			local f = Registry.ById[a]
			if f then
				api.Despawn(f, false)
			end
			return true
		elseif cmd == "impulse" then
			local f = Registry.ById[a]
			local part = f and f.Parts[b]
			if part then
				part:ApplyImpulse(c * part.AssemblyMass)
			end
			return part ~= nil
		elseif cmd == "knockdown" then
			local f = Registry.ById[a]
			if f then
				api.KnockDown(f, b or Vector3.new(0, 0, 1), c or 10)
			end
			return true
		elseif cmd == "testStrike" then
			local f = Registry.ById[a]
			if not f then
				return "no fighter"
			end
			local opts = c or {}
			return testStrike(f, b, opts.Power or 5, opts.Kind, opts.Quality, opts.Dir, api.Kill)
		elseif cmd == "teleport" then
			local f = Registry.ById[a]
			if f then
				f.Model:PivotTo(b)
			end
			return true
		elseif cmd == "setDebug" then
			workspace:SetAttribute("RR_Debug", a == true)
			return true
		end
		return "unknown command " .. tostring(cmd)
	end
end

return DevTools
