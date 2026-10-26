--[[
	Ragdoll Ronin - server bootstrap and the single centralized update loop.

	Controllers (before physics): state logic -> aim/sword target -> motors & drives
	  normally in PreSimulation (in Owner mode not for players' fighters: their own clients run
	  them, see OwnerSync); under server authority (Workspace.AuthorityMode = Server) inside
	  RunService:BindToSimulation, so the owning client can run the same step to predict its own
	  fighter (see Shared.Sim.SimState). Validation, disarming and debug then run on Heartbeat.
	PostSimulation (after physics):  blade stroke tracking -> swept hit detection -> combat resolution,
	  then kicks (KickResolver)
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
local Input = require(Shared.Sim.Input)
local StateMachine = require(Shared.Sim.StateMachine)
local BalanceController = require(Shared.Sim.BalanceController)
local SwordController = require(Shared.Sim.SwordController)
local MotorController = require(Shared.Sim.MotorController)
local HitDetection = require(Modules.HitDetection)
local CombatResolver = require(Modules.CombatResolver)
local AnatomyService = require(Modules.AnatomyService)
local BleedingService = require(Modules.BleedingService)
local Lifecycle = require(Modules.Lifecycle)
local NetService = require(Modules.NetService)
local DebugService = require(Modules.DebugService)
local DevTools = require(Modules.DevTools)
local TestDummies = require(Modules.TestDummies)
local Dismemberment = require(Modules.Dismemberment)
local OwnerSync = require(Modules.OwnerSync)
local KickResolver = require(Modules.KickResolver)
local SoundFX = require(Modules.SoundFX)
local Runtime = require(Shared.Sim.Runtime)
local SimState = require(Shared.Sim.SimState)

Runtime.Debug = DebugService

CollisionSetup.Init()
DebugService.Init()
OwnerSync.Init()
SoundFX.Init()
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
TestDummies.Init({ Spawn = Lifecycle.Spawn })

------------------------------------------------------------------ error isolation
local lastError = {}
local function guarded(f, phase, fn, ...)
	local ok, err = xpcall(fn, debug.traceback, ...)
	if not ok then
		local key = f.Id .. phase
		local now = os.clock()
		if not lastError[key] or now - lastError[key] > 2 then
			lastError[key] = now
			warn(string.format("[RR] %s update error (%s): %s", f.Name, phase, tostring(err)))
		end
	end
end

-- a crippled sword hand cannot hold the katana, however it was injured
local function checkDisarm(f)
	if f.Sword and not f.Sheathed and not f.Dead and f.Anatomy.Segments.RightHand.Integrity < Config.Anatomy.DisarmHandIntegrity then
		Dismemberment.DropSword(f, f.Parts.UpperTorso and f.Parts.UpperTorso.CFrame.LookVector * 6)
	end
end

-- the predictable part of a fighter's frame (identical on a predicting client)
local function stepControllers(f, dt)
	local inp = Input.Get(f)
	BalanceController.Update(f, dt, inp)
	SwordController.UpdateAim(f, dt, inp)
	MotorController.Apply(f, dt, inp)
end

local function stepPre(f, dt)
	if f.Removed or not Lifecycle.Validate(f) then
		return
	end
	checkDisarm(f)
	if OwnerSync.Applies(f) then
		OwnerSync.Pre(f, Input.Get(f)) -- the owner's client runs this fighter's controllers
	else
		stepControllers(f, dt)
	end
	SwordController.PublishBind(f)
	DebugService.Tick(f)
end

-- server authority: only simulation-safe work runs inside the bound step; the state it leaves is
-- published for client prediction
local function stepSim(f, dt)
	if f.Removed or not f.Model.Parent or not f.Parts.LowerTorso or not f.Parts.LowerTorso.Parent then
		return
	end
	stepControllers(f, dt)
	SimState.Store(f)
end

local function stepHeartbeat(f)
	if f.Removed or not Lifecycle.Validate(f) then
		return
	end
	checkDisarm(f)
	SwordController.PublishBind(f)
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
	KickResolver.Step(f)
end

if Runtime.ServerAuthority then
	RunService:BindToSimulation(function(dt)
		for _, f in ipairs(Registry.List()) do
			guarded(f, "sim", stepSim, f, dt)
		end
	end, Enum.StepFrequency.Hz60)
	RunService.Heartbeat:Connect(function()
		for _, f in ipairs(Registry.List()) do
			guarded(f, "heartbeat", stepHeartbeat, f)
		end
	end)
else
	RunService.PreSimulation:Connect(function(dt)
		for _, f in ipairs(Registry.List()) do
			guarded(f, "pre", stepPre, f, dt)
		end
	end)
end

RunService.PostSimulation:Connect(function(dt)
	for _, f in ipairs(Registry.List()) do
		guarded(f, "post", stepPost, f, dt)
	end
end)

------------------------------------------------------------------ slow loops
local anatomyRemote = Shared.Remotes.AnatomyUpdate
local CharacterBuilder = require(Modules.CharacterBuilder)
local bleedAccum, syncAccum, heartbeat, ownerAccum = 0, 0, 0, 0

-- Ownership guard: live fighter bodies are always simulated by the server, except a player's own
-- fighter in Owner mode, which its client simulates (CharacterBuilder.ExpectedOwner).
local function guardOwnership()
	for _, f in ipairs(Registry.List()) do
		local pelvis = f.Parts.LowerTorso
		if not f.Removed and pelvis and pelvis.Parent then
			local okAuto, auto = pcall(pelvis.GetNetworkOwnershipAuto, pelvis)
			local okOwner, owner = pcall(pelvis.GetNetworkOwner, pelvis)
			if (okAuto and auto) or (okOwner and owner ~= CharacterBuilder.ExpectedOwner(f.Model)) then
				DebugService.Log("reclaiming network ownership of", f.Name)
				CharacterBuilder.ClaimOwnership(f.Model)
			end
		end
	end
end

RunService.Heartbeat:Connect(function(dt)
	-- Owner mode: tell each owner what combat decided about their fighter this frame
	for _, f in ipairs(Registry.List()) do
		if OwnerSync.Applies(f) then
			guarded(f, "ownersync", OwnerSync.Flush, f)
		end
	end
	-- prompt re-claim after the body's assembly changed (wound marks, stumps, dropped sword).
	-- Under server authority the engine keeps everything server-owned and predicts instead.
	if not Runtime.ServerAuthority then
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

local MODE_TEXT = {
	ServerAuthority = " (server authority + client prediction; Workspace.AuthorityMode must be Server)",
	Owner = " (owner mode: each client simulates its own fighter; Workspace.AuthorityMode must be Automatic)",
	Server = " (server simulates everyone; Workspace.AuthorityMode must be Automatic)",
}
print("[RR] Ragdoll Ronin combat server ready" .. (MODE_TEXT[Runtime.Mode] or (" (unknown Config.Network.Mode " .. tostring(Runtime.Mode) .. ")")))
