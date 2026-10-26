--[[
	Kick: timing and pose of the teep (Muay Thai push kick, Config.Kick), shared by the controllers
	(BalanceController starts and ends it, MotorController poses it, SwordController keeps the
	hands up) and the server's KickResolver.

	Phases, from the moment the Kicking state starts:
	  chamber  the lead knee rises to the chest, foot tucked under it, toes pulled back
	  extend   the hips drive forward and the leg shoots out straight, sole first, into the target's
	           belly; the pelvis and torso lean back to counterbalance, the standing leg straightens
	  hold     fully extended (the push)
	  retract  the knee snaps back to the chamber, then the foot steps back down to the stance
	Phase(t) returns lift (0 = normal stance, 1 = leg up) and ext (0 = chambered, 1 = extended).
]]
local Config = require(script.Parent.Parent.Config)
local Util = require(script.Parent.Util)

local Kick = {}
local K = Config.Kick
local rad = math.rad

Kick.Total = K.ChamberTime + K.ExtendTime + K.HoldTime + K.RetractTime
Kick.Leg = K.Leg
Kick.Support = K.Leg == "Left" and "Right" or "Left"
local RETRACT_SPLIT = 0.45 -- share of the retract spent pulling the leg back to the chamber

function Kick.Phase(t)
	local c, e, h = K.ChamberTime, K.ExtendTime, K.HoldTime
	if t < c then
		return Util.smoothstep(t / c), 0, false
	elseif t < c + e then
		return 1, Util.smoothstep((t - c) / e), true
	elseif t < c + e + h then
		return 1, 1, t < c + e + h * 0.5
	end
	local u = math.clamp((t - c - e - h) / K.RetractTime, 0, 1)
	if u < RETRACT_SPLIT then
		return 1, 1 - Util.smoothstep(u / RETRACT_SPLIT), false
	end
	return 1 - Util.smoothstep((u - RETRACT_SPLIT) / (1 - RETRACT_SPLIT)), 0, false
end

-- Leg joint targets for the kick (pose table entries, relative to the pelvis), at full lift.
-- `ext` is the extension; `lean` the pelvis lean back (radians) the standing leg compensates for.
function Kick.LegPose(pose, ext, lean)
	local ch, ex = K.Chamber, K.Extend
	local leg, sup = Kick.Leg, Kick.Support
	local s = leg == "Right" and 1 or -1
	local hip = ch.Hip + (ex.Hip - ch.Hip) * ext
	local knee = ch.Knee + (ex.Knee - ch.Knee) * ext
	local ankle = ch.Ankle + (ex.Ankle - ch.Ankle) * ext
	pose[leg .. "Hip"] = CFrame.Angles(rad(hip), 0, s * rad(3))
	pose[leg .. "Knee"] = rad(knee)
	pose[leg .. "Ankle"] = CFrame.Angles(rad(ankle), 0, 0)
	-- standing leg: straight under the body however far the pelvis leans back, foot flat
	local sk = rad(K.SupportKnee)
	pose[sup .. "Hip"] = CFrame.Angles(sk * 0.5 - lean, 0, -s * rad(4))
	pose[sup .. "Knee"] = sk
	pose[sup .. "Ankle"] = CFrame.Angles(sk * 0.5, 0, s * rad(4))
end

return Kick
