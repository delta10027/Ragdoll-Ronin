--[[
	Ragdoll Ronin - server bootstrap and the single centralized update loop.

	PreSimulation  (before physics): state logic -> aim/sword target -> motors & drives
	PostSimulation (after physics):  blade stroke tracking -> swept hit detection -> combat resolution
	Bleeding runs on its own bounded interval; anatomy snapshots are pushed to owners at a fixed rate.
	Each fighter is updated inside pcall so one broken fighter cannot stop combat for everyone.
]]
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.RagdollRonin
local Config = require(Shared.Config)
local StateDefs = require(Shared.StateDefs)

local Modules = script.Parent.Modules
local CollisionSetup = require(Modules.CollisionSetup)
local Registry = require(Modules.Registry)
local Input = require(Modules.Input)
local StateMachine = require(Modules.StateMachine)
local BalanceController = require(Modules.BalanceController)
local SwordController = require(Modules.SwordController)
local MotorController = require(Modules.MotorController)
local HitDetection = require(Modules.HitDetection)
local CombatResolver = require(Modules.CombatResolver)
local AnatomyService = require(Modules.AnatomyService)
local BleedingService = require(Modules.BleedingService)
local Lifecycle = require(Modules.Lifecycle)
local NetService = require(Modules.NetService)
local DebugService = require(Modules.DebugService)
local DevTools = require(Modules.DevTools)
local Dismemberment = require(Modules.Dismemberment)

CollisionSetup.Init()
DebugService.Init()
CombatResolver.SetKill(Lifecycle.Kill)
NetService.SetReset(function(f)
	Lifecycle.Kill(f, "Reset")
end)
NetService.Init()

StateMachine.OnTransition(function(f, from, to, reason)
	SwordController.OnTransition(f, from, to)
	if StateDefs.Upright[to] and f.LastRecoveryPhase ~= "-" then
		f.LastRecoveryPhase = "-"
		DebugService.Attr(f, "RecoveryPhase", "-")
	end
end)

DevTools.Init({
	Spawn = Lifecycle.Spawn,
	Kill = Lifecycle.Kill,
	Despawn = Lifecycle.Despawn,
	KnockDown = BalanceController.KnockDown,
})
Lifecycle.Init()

------------------------------------------------------------------ error isolation
local lastError = {}
local function guarded(f, phase, fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then
		local key = f.Id .. phase
		local now = os.clock()
		if not lastError[key] or now - lastError[key] > 2 then
			lastError[key] = now
			warn(string.format("[RR] %s update error (%s): %s", f.Name, phase, tostring(err)))
		end
	end
end

local function stepPre(f, dt)
	if f.Removed or not Lifecycle.Validate(f) then
		return
	end
	local inp = Input.Get(f)
	-- a crippled sword hand cannot hold the katana, however it was injured
	if f.Sword and not f.Dead and f.Anatomy.Segments.RightHand.Integrity < Config.Anatomy.DisarmHandIntegrity then
		Dismemberment.DropSword(f, f.Parts.UpperTorso and f.Parts.UpperTorso.CFrame.LookVector * 6)
	end
	BalanceController.Update(f, dt, inp)
	SwordController.UpdateAim(f, dt, inp)
	MotorController.Apply(f, dt, inp)
	DebugService.Tick(f)
end

local function stepPost(f, dt)
	if f.Removed or f.Dead then
		return
	end
	local sweep = SwordController.Track(f, dt, Input.Get(f))
	if sweep then
		local hits = HitDetection.Sweep(f, sweep)
		if #hits > 0 then
			CombatResolver.Process(f, hits)
		end
	end
end

RunService.PreSimulation:Connect(function(dt)
	for _, f in ipairs(Registry.List()) do
		guarded(f, "pre", stepPre, f, dt)
	end
end)

RunService.PostSimulation:Connect(function(dt)
	for _, f in ipairs(Registry.List()) do
		guarded(f, "post", stepPost, f, dt)
	end
end)

------------------------------------------------------------------ slow loops
local anatomyRemote = Shared.Remotes.AnatomyUpdate
local CharacterBuilder = require(Modules.CharacterBuilder)
local bleedAccum, syncAccum, heartbeat, ownerAccum = 0, 0, 0, 0

-- Ownership guard: live fighter bodies must always be simulated by the server.
local function guardOwnership()
	for _, f in ipairs(Registry.List()) do
		local pelvis = f.Parts.LowerTorso
		if not f.Removed and pelvis and pelvis.Parent then
			local okAuto, auto = pcall(pelvis.GetNetworkOwnershipAuto, pelvis)
			local okOwner, owner = pcall(pelvis.GetNetworkOwner, pelvis)
			if (okAuto and auto) or (okOwner and owner ~= nil) then
				DebugService.Log("reclaiming network ownership of", f.Name)
				CharacterBuilder.ClaimOwnership(f.Model)
			end
		end
	end
end

RunService.Heartbeat:Connect(function(dt)
	-- prompt re-claim after the body's assembly changed (wound marks, stumps, dropped sword)
	for _, f in ipairs(Registry.List()) do
		if f.OwnershipDirty and f.OwnershipDirty > 0 and not f.Removed then
			f.OwnershipDirty -= 1
			CharacterBuilder.ClaimOwnership(f.Model)
		end
	end
	ownerAccum += dt
	if ownerAccum >= 1 then
		ownerAccum = 0
		pcall(guardOwnership)
	end
	bleedAccum += dt
	if bleedAccum >= Config.Blood.TickInterval then
		local step = bleedAccum
		bleedAccum = 0
		local ok, err = pcall(BleedingService.Tick, step, Lifecycle.Kill)
		if not ok then
			warn("[RR] bleeding tick error: " .. tostring(err))
		end
	end
	syncAccum += dt
	heartbeat += dt
	if syncAccum >= Config.Network.AnatomySyncInterval then
		syncAccum = 0
		local force = heartbeat >= 1
		if force then
			heartbeat = 0
		end
		for _, f in ipairs(Registry.List()) do
			if f.Player and f.Player.Parent and (f.AnatomyDirty or force) then
				f.AnatomyDirty = false
				local ok, snap = pcall(AnatomyService.Snapshot, f)
				if ok then
					anatomyRemote:FireClient(f.Player, snap)
				end
			end
		end
	end
end)

print("[RR] Ragdoll Ronin combat server ready")
