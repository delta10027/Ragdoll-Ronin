--[[
	Input: validated per-fighter intent. Written by NetService (players) or DevTools (test dummies);
	under server authority players' intent is read from their InputActions instead (SimInput).
	The server never receives poses, hits or damage from clients - only this intent.
]]
local Config = require(game:GetService("ReplicatedStorage").RagdollRonin.Config)
local Runtime = require(script.Parent.Runtime)
local SimInput = require(script.Parent.SimInput)

local Input = {}

function Input.Neutral()
	return {
		Move = Vector3.zero,
		Yaw = 0,
		AimU = Config.Aim.ReadyU,
		AimV = Config.Aim.ReadyV,
		M1 = false,
		M2 = false,
		Kick = false, -- C (teep); a tap is held for a few frames so it is never missed
		Crouch = false, -- CTRL held
		Sheath = false, -- 1 (draw / sheathe), a tap held a few frames like the kick
		Seq = 0,
		LastPacket = 0,
	}
end

function Input.Init(f, yaw)
	f.Input = Input.Neutral()
	f.Input.Yaw = yaw or 0
	f.Input.LastPacket = os.clock()
	f.InputOverride = nil
end

-- Effective intent this frame. Stale player input decays to neutral (keeps facing).
function Input.Get(f)
	if f.InputOverride then
		return f.InputOverride
	end
	local i = f.Input
	if Runtime.ServerAuthority and f.Player then
		return SimInput.Read(f.Player, i)
	end
	if f.Player and os.clock() - i.LastPacket > Config.Network.InputTimeout then
		local n = Input.Neutral()
		n.Yaw = i.Yaw
		return n
	end
	return i
end

return Input
