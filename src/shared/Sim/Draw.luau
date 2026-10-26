--[[
	Draw: animated drawing and sheathing of the katana (key 1), after the iaido draw (Config.Draw).

	Draw
	  reach  the right hand crosses the body to the hilt (the sword target moves to the grip on the
	         sheathed handle), the left hand takes the scabbard just below the mouth, the torso
	         turns left so the right shoulder comes forward
	  grip   the sword leaves the scabbard weld for the right hand (Attach)
	  pull   the right hand draws the sword forward along the scabbard line, edge up, while the left
	         hand pulls the scabbard back along itself (saya-biki), until the tip clears the mouth
	  swing  the freed blade swings forward through a level point in front of the left side into
	         the guard, the left hand leaves the scabbard for the hilt (two hands), the scabbard
	         settles back and the torso turns back to the front
	Sheathe (noto) is the reverse: align the blade edge up with its tip at the mouth of the pulled
	back scabbard, slide it home as the scabbard comes forward, hand it to the scabbard weld,
	let go.

	Everything is driven through the normal controllers: the scripted sword target goes to the
	sword arm IK and hand drive, Draw.Pose(f).Left to the left arm IK, Biki to the scabbard's weld
	(MotorController). Time is accumulated per step (DrawT), never read from a clock, so it rolls
	back and replays exactly (SimState) and needs no clock agreement in Owner mode.
	Attach() moves the instances (welds) wherever the fighter's physics is simulated: the server,
	or the owning client in Owner mode (the server copies it from the client's report, OwnerSync);
	a predicting client under server authority only flips the flag and lets the server move them.
]]
local RunService = game:GetService("RunService")
local Config = require(script.Parent.Parent.Config)
local Util = require(script.Parent.Util)
local Runtime = require(script.Parent.Runtime)

local Draw = {}
local D, SW = Config.Draw, Config.Sword
local S = Config.Scale
local GRIP_IN_HANDLE = CFrame.new(0, 0.25 * SW.HandleLength, 0) -- the sword grip frame (GripAtt) on the handle
local OUT = SW.BladeLength + SW.GuardThickness + D.ClearMargin -- slide that brings the tip out of the mouth
local SAYA_HALF = (SW.BladeLength + 0.15) / 2
local PREDICTING = Runtime.ServerAuthority and RunService:IsClient()
-- level point of the swing out of the scabbard, in front of the left side (upper-torso space)
local MID = (function()
	local dir = Vector3.new(-0.45, 0.2, -0.87).Unit
	local edge = Util.perpendicular(Vector3.yAxis, dir, Vector3.xAxis)
	return CFrame.fromMatrix(Vector3.new(-0.25, 0.05, -1.5) * S, edge, dir, edge:Cross(dir))
end)()

local function smooth(x)
	return Util.smoothstep(math.clamp(x, 0, 1))
end

------------------------------------------------------------------ attach
-- Move the sword into the right hand (toHand) or into the scabbard. Both are Welds with fixed
-- offsets (CharacterBuilder), so the sword always lands exactly in the grip or the scabbard seat
-- whatever positions this machine sees; pivot also moves it there right away (the simulating side).
function Draw.Attach(f, toHand, pivot)
	local sw = f.Sword
	if not sw then
		return false
	end
	if PREDICTING then
		f.Sheathed = not toHand
		return true
	end
	local grip, sheath, saya = sw.GripJoint, sw.SheathWeld, sw.Saya
	if not grip or not sheath or not saya or not saya.Parent or not grip.Parent then
		return false
	end
	if toHand then
		local hand = f.Parts.RightHand
		if not hand or not hand.Parent or not sw.HandLocal then
			return false
		end
		sheath.Enabled = false
		if pivot then
			sw.Model:PivotTo(hand.CFrame * sw.HandLocal)
		end
		grip.Enabled = true
	else
		grip.Enabled = false
		if pivot then
			sw.Model:PivotTo(saya.CFrame * sw.InSaya)
		end
		sheath.Enabled = true
	end
	f.Sheathed = not toHand
	sw.Blade.CanQuery = toHand
	if sw.Collider then
		sw.Collider.CanCollide = toHand
	end
	if sw.ParryZone then
		sw.ParryZone.CanQuery = false
	end
	if f.Attack then
		f.Attack.PrevBladeCF = nil -- (no stroke from the jump)
	end
	f.Model:SetAttribute("Sheathed", not toHand)
	f.OwnershipDirty = 3 -- the sword changed assembly: the server re-pins ownership
	Runtime.Sound(toHand and "Draw" or "Sheathe", sw.Handle.Position)
	return true
end

local function canDraw(f)
	local sw = f.Sword
	return sw ~= nil and sw.Saya ~= nil and f.Parts.RightHand ~= nil and f.Drives.HandPos ~= nil
		and f.Caps.SwordArm > 0.05 and (f.SegFactor and f.SegFactor.RightHand or 1) >= 0.35
end

------------------------------------------------------------------ per step
-- Input (start of UpdateAim): start a draw or sheathe on a fresh press of 1; interruptions end it
function Draw.Input(f, inp)
	local pressed = inp.Sheath == true and not f.SheathHeld
	f.SheathHeld = inp.Sheath == true
	local st = f.State
	local free = st == "Idle" or st == "Moving"
	if f.DrawKind and not free then
		-- staggered, knocked down, kicking...: the sword stays wherever it is now
		f.DrawKind = nil
	end
	if pressed and not f.DrawKind and f.Sword and (free or st == "Attacking" or st == "Blocking") then
		if f.Sheathed then
			if canDraw(f) then
				f.DrawKind, f.DrawT = "Draw", 0
			end
		else
			f.DrawKind, f.DrawT = "Sheathe", 0
		end
	end
end

-- Pose (end of UpdateAim): the scripted sword target, blended with the normal one. Sets f.DrawPose
-- { Left = left hand target (upper-torso space) or nil, Biki = scabbard pull, TwoHand } and the
-- torso twist; returns the target to use.
function Draw.Pose(f, dt, normal)
	f.DrawPose = nil
	local kind = f.DrawKind
	local sw = f.Sword
	local pelvis, ut = f.Parts.LowerTorso, f.Parts.UpperTorso
	if not kind or not sw or not sw.SayaBase or not sw.InSaya or not pelvis or not ut then
		f.DrawKind = nil
		return normal
	end
	f.DrawT = (f.DrawT or 0) + dt
	local t = f.DrawT
	local toUT = ut.CFrame:ToObjectSpace(pelvis.CFrame) -- pelvis space -> upper-torso space
	local base = sw.SayaBase
	local d = base.UpVector -- along the scabbard toward its end (pelvis space)
	-- grip frame of the sword slid `out` studs out of a scabbard pulled back `biki` studs
	local function gripAt(out, biki)
		return toUT * CFrame.new(d * (biki - out)) * base * sw.InSaya * GRIP_IN_HANDLE
	end
	-- where the left hand holds the scabbard: just below the mouth
	local function mouth(biki)
		return toUT * (CFrame.new(d * biki) * base * CFrame.new(0, -SAYA_HALF + 0.12, 0)).Position
	end

	local B = D.SayaBiki
	local target, weight, biki, twist, left, twoHand = normal, 0, 0, 0, nil, false
	if kind == "Draw" then
		local R, P, W = D.ReachTime, D.PullTime, D.SwingTime
		if t < R then
			local u = smooth(t / R)
			target, weight = gripAt(0, 0), u
			twist, left = D.Twist * u, mouth(0)
		else
			if f.Sheathed then
				Draw.Attach(f, true, true) -- the right hand closes on the hilt
			end
			if t < R + P then
				local u = smooth((t - R) / P)
				biki = B * u
				target, weight = gripAt(OUT * u, biki), 1
				twist, left = D.Twist, mouth(biki)
			elseif t < R + P + W then
				local u = smooth((t - R - P) / W)
				local out = gripAt(OUT, B)
				-- out of the scabbard -> the level point in front of the left side -> the guard
				if u < 0.5 then
					target, weight = out:Lerp(MID, u * 2), 1
				else
					target, weight = MID, 1 - (u - 0.5) * 2
				end
				biki, twist = B * (1 - u), D.Twist * (1 - u)
				left = u < 0.45 and mouth(biki) or nil
				twoHand = u >= 0.45
			else
				f.DrawKind = nil
				return normal
			end
		end
	else -- Sheathe
		local Al, In, Rl = D.AlignTime, D.InsertTime, D.ReleaseTime
		if t < Al then
			local u = smooth(t / Al)
			biki = B * u
			-- from the guard, through the level point, to the tip at the mouth
			if u < 0.5 then
				target, weight = MID, u * 2
			else
				target, weight = MID:Lerp(gripAt(OUT, biki), (u - 0.5) * 2), 1
			end
			twist = D.Twist * u
			left = u > 0.3 and mouth(biki) or nil
			twoHand = u <= 0.3
		elseif t < Al + In then
			local u = smooth((t - Al) / In)
			biki = B * (1 - u)
			target, weight = gripAt(OUT * (1 - u), biki), 1
			twist, left = D.Twist, mouth(biki)
		else
			if not f.Sheathed then
				Draw.Attach(f, false, true) -- home: the scabbard holds it
			end
			if t < Al + In + Rl then
				local u = smooth((t - Al - In) / Rl)
				target, weight = gripAt(0, 0), 1 - u
				twist = D.Twist * (1 - u)
				left = u < 0.5 and mouth(0) or nil
			else
				f.DrawKind = nil
				return normal
			end
		end
	end
	f.DrawPose = { Left = left, Biki = biki, TwoHand = twoHand }
	if f.Aim then
		f.Aim.Twist = twist
	end
	return normal:Lerp(target, weight)
end

return Draw
