--[[
	SimInput: player intent through the Input Action System, used under server authority (the
	engine records InputAction states per simulation frame, sends them to the server and replays
	them on the client during resimulation; RemoteEvents are not replayed).

	The server creates one InputContext per player (it must live under the Player). The client
	fires the same intent the RemoteEvent path sends, every frame, from outside the simulation:
	  Move   Direction2D  world-space move direction (x, z), length <= 1
	  Look   Direction2D  facing as (sin yaw, cos yaw)
	  Aim    Direction2D  combat cursor (u, v) on the unit disk
	  Attack Bool         M1 held
	  Guard  Bool         M2 held
	Inside the simulation both sides read the states with Read(), which validates them exactly
	like NetService validates packets (nothing is trusted beyond "intent").
]]
local Util = require(script.Parent.Util)

local SimInput = {}

local CONTEXT = "RR_Input"
local ACTIONS = {
	Move = Enum.InputActionType.Direction2D,
	Look = Enum.InputActionType.Direction2D,
	Aim = Enum.InputActionType.Direction2D,
	Attack = Enum.InputActionType.Bool,
	Guard = Enum.InputActionType.Bool,
}

-- server: give a player their input context
function SimInput.Setup(player)
	if player:FindFirstChild(CONTEXT) then
		return
	end
	local ctx = Instance.new("InputContext")
	ctx.Name = CONTEXT
	for name, kind in pairs(ACTIONS) do
		local a = Instance.new("InputAction")
		a.Name = name
		a.Type = kind
		a.Parent = ctx
	end
	ctx.Parent = player
end

local function action(player, name)
	local ctx = player:FindFirstChild(CONTEXT)
	return ctx and ctx:FindFirstChild(name)
end

local function vec2(player, name)
	local a = action(player, name)
	local v = a and a:GetState()
	if typeof(v) == "Vector2" and Util.isFinite(v.X) and Util.isFinite(v.Y) then
		return v
	end
	return nil
end

-- both sides, inside the simulation: fill `into` (an Input record) from the player's actions
function SimInput.Read(player, into)
	local move = vec2(player, "Move")
	if move then
		local m = Vector3.new(move.X, 0, move.Y)
		into.Move = m.Magnitude > 1 and m.Unit or m
	end
	local look = vec2(player, "Look")
	if look and look.Magnitude > 0.1 then
		into.Yaw = math.atan2(look.X, look.Y) % (2 * math.pi)
	end
	local aim = vec2(player, "Aim")
	if aim then
		local r = aim.Magnitude
		if r > 1 then
			aim = aim / r
		end
		into.AimU, into.AimV = aim.X, aim.Y
	end
	local m1, m2 = action(player, "Attack"), action(player, "Guard")
	into.M1 = m1 ~= nil and m1:GetState() == true
	into.M2 = m2 ~= nil and m2:GetState() == true
	return into
end

-- client, outside the simulation (render step): publish this frame's intent
function SimInput.Fire(player, move, yaw, u, v, m1, m2)
	local ctx = player:FindFirstChild(CONTEXT)
	if not ctx then
		return false
	end
	local function fire(name, value)
		local a = ctx:FindFirstChild(name)
		if a then
			a:Fire(value)
		end
	end
	fire("Move", Vector2.new(move.X, move.Z))
	fire("Look", Vector2.new(math.sin(yaw), math.cos(yaw)))
	fire("Aim", Vector2.new(u, v))
	fire("Attack", m1)
	fire("Guard", m2)
	return true
end

return SimInput
