--[[
	OwnerSync (Config.Network.Mode = "Owner", Workspace.AuthorityMode = Automatic).

	Each player's client owns and simulates its own fighter (client Prediction runs the
	controllers), so the server must not run its own copy of them: it would only fight the client
	over the drive targets. Instead, for those fighters:

	  client -> server  every input packet also reports the client's simulation: state, balance,
	                    guard, cursor, whether the attack is bound, and the last server event it has
	                    applied (Report). The server adopts it, so blocks, strokes and reactions are
	                    judged from what the player is really doing.
	  server -> client  whatever the server decides about that fighter (stagger, knockdown, death,
	                    balance damage, recoil, a bound attack: Flush), and impulses on its body
	                    (Impulse), go to the owner over the SimEvent remote, numbered. Until the
	                    client reports having applied the latest one, its reports are ignored, so a
	                    stale report cannot undo a hit.
	Times are never sent (each side has its own clock): only durations.
	The body positions the server sees are the owner's, replicated; the server still decides every
	hit and its damage. The owner's body is trusted, so this mode is for testing.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.RagdollRonin
local Config = require(Shared.Config)
local StateDefs = require(Shared.StateDefs)
local Runtime = require(Shared.Sim.Runtime)
local SimState = require(Shared.Sim.SimState)
local StateMachine = require(Shared.Sim.StateMachine)
local Registry = require(script.Parent.Registry)

local OwnerSync = {}

local remote = Shared.Remotes.SimEvent
local REPORTABLE = {}
for _, s in ipairs(StateDefs.States) do
	if s ~= "Dead" then
		REPORTABLE[s] = true
	end
end

function OwnerSync.Applies(f)
	return Runtime.OwnerPhysics and f.Player ~= nil and not f.Removed
end

-- what the server and the owner last agreed on
local function agreed(f)
	return {
		State = f.State,
		StateTime = f.StateTime,
		Until = f.StateData.Until,
		Balance = f.Balance,
		Recoil = f.Attack.RecoilUntil,
		Bind = f.Aim.Bind,
	}
end

local function record(f)
	local o = f.OwnerSync
	if not o then
		o = { Seq = 0, Stored = false }
		o.Agreed = agreed(f)
		f.OwnerSync = o
	end
	return o
end

-- Pre-simulation, instead of the controllers
function OwnerSync.Pre(f, inp)
	local o = record(f)
	f.RemoteBody = true -- SwordController.Track: the blade pose arrives by replication
	if not o.Stored then
		o.Stored = true
		SimState.Store(f) -- the client's starting state
	else
		SimState.StoreServer(f)
	end
	-- release bookkeeping for stroke tracking (UpdateAim does it for fighters the server runs)
	local atk = f.Attack
	if inp.M1 and f.Sword then
		atk.ReleaseTime = nil
	elseif atk.ReleaseTime == nil then
		atk.ReleaseTime = Runtime.now()
	end
end

-- r = { State, Balance, Block, AimU, AimV, AimVU, AimVV, Bound, Ack } (validated by NetService)
function OwnerSync.Report(f, r)
	local o = record(f)
	if f.Dead or r.Ack < o.Seq or not REPORTABLE[r.State] then
		return
	end
	local now = Runtime.now()
	if r.State ~= f.State then
		-- (a fresh Until, so a server stagger extension starts from now)
		StateMachine.Mirror(f, r.State, { Until = now })
	end
	f.Balance = math.clamp(r.Balance, 0, Config.Balance.Max)
	local aim = f.Aim
	aim.U, aim.V, aim.VU, aim.VV = r.AimU, r.AimV, r.AimVU, r.AimVV
	if not r.Bound then
		aim.Bind = nil
	end
	local blocking = r.Block and f.State == "Blocking" and f.Sword ~= nil and not f.Sheathed
	if blocking ~= f.Block.Active then
		f.Block.Active = blocking
		if blocking then
			f.Block.StartTime = now
		end
		if f.Sword and f.Sword.ParryZone then
			f.Sword.ParryZone.CanQuery = blocking
		end
	end
	o.Agreed = agreed(f)
end

local function send(f, ev)
	local o = record(f)
	o.Seq += 1
	ev.Seq = o.Seq
	ev.Id = f.Id
	remote:FireClient(f.Player, ev)
end

-- Heartbeat, after combat: send the owner what the server changed since they last agreed
function OwnerSync.Flush(f)
	if not f.Player or not f.Player.Parent then
		return
	end
	local o = record(f)
	local a = o.Agreed
	local now = Runtime.now()
	local ev
	if f.State ~= a.State or f.StateTime ~= a.StateTime or f.StateData.Until ~= a.Until then
		ev = {}
		local data = {}
		for k, v in pairs(f.StateData) do
			data[k] = v
		end
		if data.Until then
			data.Left = data.Until - now
			data.Until = nil
		end
		ev.State = { To = f.State, Reason = f.Model:GetAttribute("StateReason"), Data = data }
	end
	if f.Balance ~= a.Balance then
		ev = ev or {}
		ev.Balance = f.Balance - a.Balance
	end
	if f.Attack.RecoilUntil ~= a.Recoil then
		ev = ev or {}
		ev.Recoil = math.max(0, f.Attack.RecoilUntil - now)
	end
	local b = f.Aim.Bind
	if b and b ~= a.Bind then
		ev = ev or {}
		ev.Bind = { U = b.U, V = b.V, DU = b.DU, DV = b.DV }
	end
	if ev then
		send(f, ev)
		o.Agreed = agreed(f)
	end
end

-- Runtime.Impulse on the server: a body its owner simulates gets the impulse on the owner's side
local function fighterOf(part)
	local m = part:FindFirstAncestorWhichIsA("Model")
	while m do
		local id = m:GetAttribute("FighterId")
		if id then
			return Registry.ById[id]
		end
		m = m:FindFirstAncestorWhichIsA("Model")
	end
	return nil
end

function OwnerSync.Init()
	if not Runtime.OwnerPhysics then
		return
	end
	Runtime.Impulse = function(part, impulse)
		local f = fighterOf(part)
		if f and OwnerSync.Applies(f) and f.Player.Parent then
			remote:FireClient(f.Player, { Id = f.Id, Impulse = { Part = part, J = impulse } })
		else
			part:ApplyImpulse(impulse)
		end
	end
end

return OwnerSync
