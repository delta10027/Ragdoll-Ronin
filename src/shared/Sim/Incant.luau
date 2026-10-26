--[[
	Incant: the incantation (J) animation (Config.Incant), shared by the controllers like Draw.

	  raise  the blade comes level across the chest, pointing left, edge forward and the flat up;
	         the free left hand goes to the flat just past the guard
	  rub    the hand runs along the flat to the tip (the blade takes the incantation behind it)
	  hold   the hand leaves the tip
	  lower  the sword returns to the guard

	Started on a fresh press of J while standing with the sword drawn, an incantation chosen
	(the model's "IncantChoice", set by the server Loadout) and none active or cooling down. Time
	is accumulated per step (IncantT, SimState), like the draw. Anything other than standing or
	walking ends it. What the incantation does is the server's (Incantations): it watches the
	animation run and gives the blade its power when the rub is complete.
]]
local Config = require(script.Parent.Parent.Config)
local Util = require(script.Parent.Util)
local Runtime = require(script.Parent.Runtime)

local Incant = {}
local I, SW = Config.Incant, Config.Sword
local S = Config.Scale

Incant.RubStart = I.RaiseTime
Incant.RubEnd = I.RaiseTime + I.RubTime
Incant.Total = I.RaiseTime + I.RubTime + I.HoldTime + I.LowerTime

local DIR = I.Blade.Unit
local EDGE = Util.perpendicular(I.Edge, DIR, Vector3.zAxis)
local POSE = CFrame.fromMatrix(I.Grip * S, EDGE, DIR, EDGE:Cross(DIR))
local GUARD_OFF = 0.25 * SW.HandleLength + SW.GuardThickness -- grip -> blade base
local function along(u) -- left hand on the flat, u = 0 by the guard .. 1 by the tip
	return POSE.Position + DIR * (GUARD_OFF + SW.BladeLength * (0.08 + 0.84 * u)) + Vector3.new(0, I.HandAbove * S, 0)
end

local function smooth(x)
	return Util.smoothstep(math.clamp(x, 0, 1))
end

-- start of UpdateAim (after Draw.Input)
function Incant.Input(f, inp)
	local pressed = inp.Incant == true and not f.IncantHeld
	f.IncantHeld = inp.Incant == true
	local st = f.State
	local free = st == "Idle" or st == "Moving"
	if f.IncantT and (not free or f.Sheathed or f.DrawKind or not f.Sword) then
		f.IncantT = nil
	end
	if pressed and not f.IncantT and free and f.Sword and not f.Sheathed and not f.DrawKind
		and Runtime.now() >= (f.IncantReadyAt or 0) then
		local m = f.Model
		local choice = m and m:GetAttribute("IncantChoice")
		local def = choice and Config.Incantations[choice]
		if def and not m:GetAttribute("IncantActive") then
			f.IncantT = 0
			f.IncantReadyAt = Runtime.now() + def.Cooldown
		end
	end
end

-- end of UpdateAim: the scripted sword target, blended with the normal one; sets f.DrawPose (the
-- left hand's target, used for the draw too)
function Incant.Pose(f, dt, normal)
	local t = (f.IncantT or 0) + dt
	f.IncantT = t
	local weight, left
	if t < I.RaiseTime then
		weight = smooth(t / I.RaiseTime)
		left = weight > 0.4 and along(0) or nil
	elseif t < Incant.RubEnd then
		weight = 1
		left = along(smooth((t - Incant.RubStart) / I.RubTime))
	elseif t < Incant.RubEnd + I.HoldTime then
		weight = 1
	elseif t < Incant.Total then
		weight = 1 - smooth((t - Incant.RubEnd - I.HoldTime) / I.LowerTime)
	else
		f.IncantT = nil
		return normal
	end
	f.DrawPose = { Left = left, Biki = 0, TwoHand = false }
	if f.Aim then
		f.Aim.Twist = 0
	end
	return normal:Lerp(POSE, weight)
end

return Incant
