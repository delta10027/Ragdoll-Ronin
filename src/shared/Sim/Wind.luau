--[[
	Wind: the server's one wind (Config.Wind), read from the workspace attributes "WindSpeed"
	(studs/s) and "WindYaw" (degrees: 0 blows toward -Z, 90 toward -X). The server's Loadout sets
	them (creative menu M, Weather); before they replicate the Config defaults are used.

	Shared: the fighters' controllers (MotorController: walking into it is slower, covering the
	face) run it on the server and on a predicting client; the client's WindView and CloakView
	read it for the streaks and the cape.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.RagdollRonin.Config)

local Wind = {}
local W = Config.Wind

-- unit horizontal direction the wind blows toward, and its speed
function Wind.Get()
	local speed = workspace:GetAttribute("WindSpeed")
	local yaw = workspace:GetAttribute("WindYaw")
	speed = typeof(speed) == "number" and math.clamp(speed, 0, W.MaxSpeed) or W.Speed
	yaw = math.rad(typeof(yaw) == "number" and yaw or W.Yaw)
	return Vector3.new(-math.sin(yaw), 0, -math.cos(yaw)), speed
end

-- wind velocity (studs/s)
function Wind.Velocity()
	local dir, speed = Wind.Get()
	return dir * speed
end

-- how hard the fighters feel it: 0 below HighSpeed, 1 from FullSpeed
function Wind.Strength()
	local _, speed = Wind.Get()
	return math.clamp((speed - W.HighSpeed) / (W.FullSpeed - W.HighSpeed), 0, 1)
end

-- commanded walk (world, horizontal) slowed by its part straight into the wind
function Wind.Resist(vel)
	local strength = Wind.Strength()
	local speed = vel.Magnitude
	if strength <= 0 or speed < 1e-3 then
		return vel
	end
	local dir = Wind.Get()
	local into = math.max(0, -(vel / speed):Dot(dir))
	return vel * (1 - W.IntoSlow * strength * into)
end

-- 0..1: how far a fighter walking with velocity `vel` and facing `facing` (unit, horizontal)
-- shields the face. Any wind above HighSpeed covers fully (it doesn't scale with the wind, so the
-- pose never sits halfway with the walk's arm swing showing through); it only ramps in as the
-- fighter starts walking and turns from the wind at the back to into it.
function Wind.Cover(vel, facing)
	if not vel or Wind.Strength() <= 0 then
		return 0
	end
	local walking = math.clamp(vel.Magnitude / (0.3 * Config.Movement.WalkSpeed), 0, 1)
	local dir = Wind.Get()
	local headOn = math.clamp((0.6 - facing:Dot(dir)) / 0.3, 0, 1) -- 1 into or across it, 0 back to it
	return walking * headOn
end

return Wind
