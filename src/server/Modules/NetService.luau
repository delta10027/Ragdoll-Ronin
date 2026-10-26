--[[
	NetService: the only entry points from clients.

	CombatInput (UnreliableRemoteEvent, ~60 Hz): seq, moveX, moveZ, yaw, aimU, aimV, buttons
	  (buttons: bit0 = M1, bit1 = M2, bit2 = kick, bit3 = crouch)
	  * token-bucket rate limit per player; malformed or non-finite packets are dropped
	  * out-of-order packets (seq not increasing) are dropped
	  * move clamped to unit length, aim clamped to the unit disk, buttons masked to 4 bits
	  The server converts this INTENT into motion itself (speed caps, inertia, physical drives),
	  so no packet can move the sword faster than physics allows or declare a hit/damage.
	  Owner mode adds the client's own simulation of its fighter after the buttons (see OwnerSync):
	    state, balance, guard (bool), aimU, aimV, aimVU, aimVV, bound (bool), ack
	CombatAction (RemoteEvent): "Recover" | "Reset" | "Sheath" (draw / sheathe), cooldown limited.
	Under server authority the per-frame intent comes from InputActions instead (Sim.SimInput,
	created here per player); CombatInput packets are then ignored.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Shared = ReplicatedStorage.RagdollRonin
local Config = require(Shared.Config)
local Registry = require(script.Parent.Registry)
local Util = require(Shared.Sim.Util)
local BalanceController = require(Shared.Sim.BalanceController)
local DebugService = require(script.Parent.DebugService)
local Runtime = require(Shared.Sim.Runtime)
local SimInput = require(Shared.Sim.SimInput)
local OwnerSync = require(script.Parent.OwnerSync)
local SheathService = require(script.Parent.SheathService)

local NetService = {}
local N = Config.Network
local buckets = {}
local actionTimes = {}
local rejects = {}

local function allow(player)
	local now = os.clock()
	local b = buckets[player]
	if not b then
		b = { Tokens = N.BucketCapacity, Last = now }
		buckets[player] = b
	end
	b.Tokens = math.min(N.BucketCapacity, b.Tokens + (now - b.Last) * N.BucketRefillPerSecond)
	b.Last = now
	if b.Tokens < 1 then
		return false
	end
	b.Tokens -= 1
	return true
end

local function reject(player, why)
	rejects[player] = (rejects[player] or 0) + 1
	if DebugService.Enabled() and rejects[player] % 50 == 1 then
		warn("[RR] rejected input from", player.Name, why, "total", rejects[player])
	end
end

function NetService.RejectCount(player)
	return rejects[player] or 0
end

-- Owner mode: the client's report of its own simulation; false if malformed
local function ownerReport(f, state, balance, guard, au, av, avu, avv, bound, ack)
	if typeof(state) ~= "string" or #state > 24 or typeof(guard) ~= "boolean" or typeof(bound) ~= "boolean" then
		return false
	end
	local nums = { balance, au, av, avu, avv, ack }
	for k = 1, 6 do
		if not Util.isFinite(nums[k]) then
			return false
		end
	end
	local r = math.sqrt(au * au + av * av)
	if r > 1 then
		au, av = au / r, av / r
	end
	local m = Config.Aim.MaxSpeed * 2
	OwnerSync.Report(f, {
		State = state,
		Balance = balance,
		Block = guard,
		AimU = au,
		AimV = av,
		AimVU = math.clamp(avu, -m, m),
		AimVV = math.clamp(avv, -m, m),
		Bound = bound,
		Ack = math.floor(ack),
	})
	return true
end

local function onInput(player, seq, mx, mz, yaw, u, v, buttons, ...)
	if Runtime.ServerAuthority then
		return
	end
	if not allow(player) then
		return reject(player, "rate")
	end
	local f = Registry.ByPlayer[player]
	if not f or f.Dead then
		return
	end
	local args = { seq, mx, mz, yaw, u, v, buttons }
	for k = 1, 7 do -- numeric loop: ipairs would stop at a nil and let it through
		if not Util.isFinite(args[k]) then
			return reject(player, "malformed")
		end
	end
	local i = f.Input
	if seq <= i.Seq then
		-- small step back = reordered/duplicate packet: drop. A large jump back means the client's
		-- counter restarted (script reload); accept it so input can never be locked out.
		if i.Seq - seq < 1000 then
			return
		end
	end
	local move = Vector3.new(mx, 0, mz)
	if move.Magnitude > 1 then
		move = move.Unit
	end
	local r = math.sqrt(u * u + v * v)
	if r > 1 then
		u, v = u / r, v / r
	end
	buttons = math.floor(buttons) % 16
	i.Seq = seq
	i.Move = move
	i.Yaw = yaw % (2 * math.pi)
	i.AimU = u
	i.AimV = v
	i.M1 = buttons % 2 == 1
	i.M2 = math.floor(buttons / 2) % 2 == 1
	i.Kick = math.floor(buttons / 4) % 2 == 1
	i.Crouch = buttons >= 8
	i.LastPacket = os.clock()
	-- (no report yet while the client is still building its fighter record)
	if OwnerSync.Applies(f) and select("#", ...) > 0 and (...) ~= nil and not ownerReport(f, ...) then
		return reject(player, "malformed report")
	end
end

local resetFn
function NetService.SetReset(fn)
	resetFn = fn
end

local function onAction(player, action)
	if typeof(action) ~= "string" or #action > 16 then
		return reject(player, "bad action")
	end
	local now = os.clock()
	local key = player.UserId .. action
	if actionTimes[key] and now - actionTimes[key] < N.ActionCooldown then
		return
	end
	actionTimes[key] = now
	local f = Registry.ByPlayer[player]
	if not f or f.Dead then
		return
	end
	if action == "Recover" then
		BalanceController.RequestRecover(f)
	elseif action == "Sheath" then
		SheathService.Toggle(f)
	elseif action == "Reset" and resetFn then
		resetFn(f)
	end
end

function NetService.Init()
	local remotes = Shared.Remotes
	remotes.CombatInput.OnServerEvent:Connect(onInput)
	remotes.CombatAction.OnServerEvent:Connect(onAction)
	if Runtime.ServerAuthority then
		Players.PlayerAdded:Connect(SimInput.Setup)
		for _, p in ipairs(Players:GetPlayers()) do
			SimInput.Setup(p)
		end
	end
	Players.PlayerRemoving:Connect(function(p)
		buckets[p] = nil
		rejects[p] = nil
	end)
end

return NetService
