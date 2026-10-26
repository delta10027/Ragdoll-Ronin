--[[
	Bow: the standing bow (rei) on G (Config.Bow), shared by the controllers.

	A fresh press of G while standing still (Idle / Moving with no move input) starts it. The time
	is accumulated per step (BowT), never read from a clock, so it rolls back and replays exactly
	(SimState). Moving, M1, M2, C or 1, or leaving the standing states, ends it at once.
	The pose is applied by MotorController (pelvis tip, waist, head, legs kept under the body)
	and SwordController (a drawn sword is lowered).
]]
local Config = require(script.Parent.Parent.Config)
local Util = require(script.Parent.Util)

local Bow = {}
local B = Config.Bow

Bow.Total = B.DownTime + B.HoldTime + B.UpTime

-- BalanceController.Update, every step (before the kick and the sword states read the input)
function Bow.Update(f, dt, inp)
	local pressed = inp.Bow == true and not f.BowHeld
	f.BowHeld = inp.Bow == true
	local st = f.State
	local still = (st == "Idle" or st == "Moving") and inp.Move.Magnitude <= 0.1
	local busy = inp.M1 or inp.M2 or inp.Kick or inp.Sheath or inp.Incant or f.DrawKind ~= nil or f.IncantT ~= nil
		or f.Caps.Kneeling
	if f.BowT then
		f.BowT += dt
		if f.BowT >= Bow.Total or not still or busy then
			f.BowT = nil
		end
	elseif pressed and still and not busy then
		f.BowT = 0
	end
end

-- 0 (upright) .. 1 (fully bowed)
function Bow.Amount(f)
	local t = f.BowT
	if not t then
		return 0
	end
	if t < B.DownTime then
		return Util.smoothstep(t / B.DownTime)
	elseif t < B.DownTime + B.HoldTime then
		return 1
	end
	return 1 - Util.smoothstep(math.clamp((t - B.DownTime - B.HoldTime) / B.UpTime, 0, 1))
end

return Bow
