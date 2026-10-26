--[[
	BalanceController: decides WHAT the body is doing (state logic). MotorController decides HOW.

	  * ground probe (world-only raycast) -> height above ground, grounded flag
	  * balance meter: drained by impacts, regenerates while upright (limited by injuries)
	  * physical fall detection: excessive pelvis tilt or losing the ground
	  * input-driven Idle/Moving/Attacking/Blocking selection
	  * the recovery sequence:
	      Falling          limp; wait until the body settles (or a timeout)
	      GroundedRecovery brace pose chosen from posture (face-down push-up / face-up sit-up);
	                       wait BraceTime (Space shortens it), with back-off after failed attempts
	      Recovering       upright torque and support force ramp from 0 -> 1 over RampTime / legs,
	                       pose blends brace -> stand. Success needs the pelvis upright, near target
	                       height and slow for StableTime. Timeout -> back to GroundedRecovery.
	      SeverelyInjured  no leg support or incapacitated: braced on the ground, no standing
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.RagdollRonin
local Config = require(Shared.Config)
local StateDefs = require(Shared.StateDefs)
local Util = require(script.Parent.Util)
local StateMachine = require(script.Parent.StateMachine)
local Runtime = require(script.Parent.Runtime)
local Kick = require(script.Parent.Kick)

local BalanceController = {}

local M = Config.Movement
local B = Config.Balance
local R = Config.Recovery

local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Exclude
groundParams.CollisionGroup = "RR_GroundQuery"
groundParams.IgnoreWater = true

function BalanceController.Init(f, yaw)
	f.Balance = B.Max
	f.FacingYaw = yaw or 0
	f.TiltTimer = 0
	f.AirTimer = 0
	f.Gait = { Phase = 0 }
	f.Recovery = { Attempts = 0 }
	f.RecoverRequested = false
	f.TargetHeight = M.StandHeight
	f.Grounded = true
end

local function probe(f)
	local pelvis = f.Parts.LowerTorso
	local origin = pelvis.Position
	local res = workspace:Raycast(origin, Vector3.new(0, -(M.StandHeight + M.GroundProbeExtra), 0), groundParams)
	if res then
		f.Ground = { Height = origin.Y - res.Position.Y, Normal = res.Normal, Point = res.Position }
	else
		f.Ground = nil
	end
	f.Grounded = f.Ground ~= nil and f.Ground.Height < f.TargetHeight + M.GroundedTolerance
	f.UpDot = pelvis.CFrame.UpVector.Y
end

local function retryDelay(f)
	local d = R.BraceTime + R.RetryBaseDelay * f.Recovery.Attempts
	return math.min(d, R.BraceTime + R.RetryMaxDelay)
end

local function canEverStand(f)
	return f.Caps.LegSupport >= R.MinLegSupport and not f.Caps.Incapacitated
end

local function headingYaw(f)
	-- heading the body is lying along: projected look vector, or up vector when lying flat
	local cf = f.Parts.LowerTorso.CFrame
	local v = Util.flat(cf.LookVector)
	if v.Magnitude < 0.3 then
		v = Util.flat(-cf.UpVector)
		if cf.LookVector.Y > 0 then
			v = -v
		end
	end
	if v.Magnitude < 1e-3 then
		return f.FacingYaw
	end
	v = v.Unit
	return math.atan2(-v.X, -v.Z)
end

------------------------------------------------------------------ reactions (called by CombatResolver)
function BalanceController.KnockDown(f, pushDir, power, reason)
	if f.Dead then
		return
	end
	if StateMachine.Set(f, "Falling", reason or "Knockdown") then
		local dv = math.min(power, 12) / 12 * Config.Combat.KnockdownDV
		local dir = (Util.unit(Util.flat(pushDir), Vector3.zAxis) + Vector3.new(0, 0.15, 0)).Unit
		for _, name in ipairs({ "UpperTorso", "Head" }) do
			local p = f.Parts[name]
			if p then
				Runtime.Impulse(p, dir * dv * p.AssemblyMass)
			end
		end
	end
end

function BalanceController.Stagger(f, duration, pushDir, reason)
	if f.Dead or not StateDefs.Upright[f.State] then
		return false
	end
	if f.State == "Staggered" then
		f.StateData.Until = math.max(f.StateData.Until, Runtime.now() + duration)
		return true
	end
	return StateMachine.Set(f, "Staggered", reason or "Stagger", { Until = Runtime.now() + duration, PushDir = pushDir and Util.unit(Util.flat(pushDir)) })
end

function BalanceController.OffBalance(f, pushDir, reason)
	if f.Dead or not StateDefs.Upright[f.State] or f.State == "Staggered" then
		return false
	end
	return StateMachine.Set(f, "OffBalance", reason or "Balance", { PushDir = pushDir and Util.unit(Util.flat(pushDir)) })
end

function BalanceController.RequestRecover(f)
	f.RecoverRequested = true
end

------------------------------------------------------------------ per-frame update
function BalanceController.Update(f, dt, inp)
	probe(f)
	local st = f.State
	if st == "Dead" then
		return
	end
	local now = Runtime.now()
	local pelvis = f.Parts.LowerTorso
	local caps = f.Caps

	-- stance height (rate limited: a sudden drop of the spring target makes the body dive)
	local crouch = (st == "Attacking" or st == "Blocking") and 0.97 or 1
	if inp.Crouch and StateDefs.Upright[st] then
		crouch = M.CrouchHeightFactor -- CTRL (the legs follow the height, MotorController.standLegs)
	end
	local desiredHeight = M.StandHeight * (caps.Kneeling and M.KneelHeightFactor or 1) * crouch
	local maxStep = M.HeightChangeRate * dt
	f.TargetHeight += math.clamp(desiredHeight - f.TargetHeight, -maxStep, maxStep)

	-- incapacitation or loss of both legs takes the fighter down from any active state
	if (StateDefs.Upright[st] or st == "Recovering") and not canEverStand(f) then
		StateMachine.Set(f, "Falling", f.Caps.Incapacitated and "Incapacitated" or "No leg support")
		return
	end

	-- suddenly losing a leg's support (severed / shattered) topples a standing fighter
	local lastLegs = f.LastLegSupport or caps.LegSupport
	f.LastLegSupport = caps.LegSupport
	if StateDefs.Upright[st] and lastLegs - caps.LegSupport >= 0.3 then
		StateMachine.Set(f, "Falling", "Lost a leg")
		return
	end

	if StateDefs.Upright[st] then
		-- physical loss of balance
		if f.UpDot < math.cos(B.TiltFallAngle) then
			f.TiltTimer += dt
		else
			f.TiltTimer = 0
		end
		if f.Grounded then
			f.AirTimer = 0
		else
			f.AirTimer += dt
		end
		if f.TiltTimer > B.TiltFallTime then
			StateMachine.Set(f, "Falling", "Tipped over")
			return
		end
		if f.AirTimer > B.UngroundedFallTime then
			StateMachine.Set(f, "Falling", "Lost footing")
			return
		end
		if f.Balance <= 0 then
			StateMachine.Set(f, "Falling", "Balance depleted")
			return
		end

		-- regeneration (slower while reeling)
		local regen = B.Regen * caps.BalanceRegen * ((st == "Staggered" or st == "OffBalance") and 0.5 or 1)
		f.Balance = math.min(B.Max * caps.BalanceMax, f.Balance + regen * dt)

		if st == "Staggered" then
			if now >= (f.StateData.Until or 0) then
				if f.Balance < B.OffBalanceThreshold then
					StateMachine.Set(f, "OffBalance", "Still reeling", { PushDir = f.StateData.PushDir })
				else
					StateMachine.Set(f, "Idle", "Stagger ended")
				end
			end
			return
		elseif st == "OffBalance" then
			if f.Balance >= B.RecoverAt * caps.BalanceMax then
				StateMachine.Set(f, "Idle", "Regained balance")
			end
			return
		elseif st == "Kicking" then
			f.KickHeld = inp.Kick == true
			if StateMachine.Elapsed(f) >= Kick.Total then
				f.KickReadyAt = now + Config.Kick.Cooldown
				StateMachine.Set(f, inp.Move.Magnitude > 0.1 and "Moving" or "Idle", "Kick done")
			end
			return
		end

		-- teep on a fresh press of C, standing on both legs with the kicking leg whole
		local pressed = inp.Kick == true and not f.KickHeld
		f.KickHeld = inp.Kick == true
		local leg = Kick.Leg
		if pressed and now >= (f.KickReadyAt or 0) and not caps.Kneeling and caps.LegSupport >= 0.6
			and (caps["Leg" .. leg] or 0) >= 0.5 and f.Parts[leg .. "Foot"] then
			StateMachine.Set(f, "Kicking", "Teep")
			return
		end

		-- controllable states follow intent
		local canSword = f.Sword ~= nil and not f.Sheathed and not f.DrawKind and caps.SwordArm > 0.05
		local want
		if inp.M2 and canSword then
			want = "Blocking"
		elseif canSword and (inp.M1 or f.Attack.FollowThrough) then
			want = "Attacking"
		elseif inp.Move.Magnitude > 0.1 then
			want = "Moving"
		else
			want = "Idle"
		end
		if want ~= st then
			StateMachine.Set(f, want, "Input")
		end
		return
	end

	if st == "Falling" then
		local t = StateMachine.Elapsed(f)
		local speed = pelvis.AssemblyLinearVelocity.Magnitude
		if (t > R.MinFallTime and speed < R.SettleSpeed) or t > R.MaxFallTime then
			local faceDown = pelvis.CFrame.LookVector.Y < -0.3
			if canEverStand(f) then
				StateMachine.Set(f, "GroundedRecovery", "Settled", { Wait = retryDelay(f), FaceDown = faceDown })
			else
				StateMachine.Set(f, "SeverelyInjured", f.Caps.Incapacitated and "Incapacitated" or "Cannot stand", { FaceDown = faceDown })
			end
		end
	elseif st == "GroundedRecovery" then
		f.StateData.FaceDown = pelvis.CFrame.LookVector.Y < -0.3
		if not canEverStand(f) then
			StateMachine.Set(f, "SeverelyInjured", "Cannot stand", { FaceDown = f.StateData.FaceDown })
			return
		end
		local t = StateMachine.Elapsed(f)
		local manual = f.RecoverRequested and t > R.ManualMinGroundTime
		if t >= (f.StateData.Wait or R.BraceTime) or manual then
			f.Recovery.Attempts += 1
			StateMachine.Set(f, "Recovering", manual and "Player attempt" or "Auto attempt", {
				R = 0,
				FaceDown = f.StateData.FaceDown,
				StartHeight = f.Ground and f.Ground.Height or (M.StandHeight * 0.3),
				Yaw = headingYaw(f),
				Stable = 0,
				Attempt = f.Recovery.Attempts,
			})
		end
		f.RecoverRequested = false
	elseif st == "Recovering" then
		local d = f.StateData
		local t = StateMachine.Elapsed(f)
		local rampTime = R.RampTime / math.max(0.4, caps.LegSupport) / math.max(0.5, caps.Strength)
		d.R = math.clamp(t / rampTime, 0, 1)
		local upright = f.UpDot >= R.SuccessUpDot
		local high = f.Ground ~= nil and f.Ground.Height >= f.TargetHeight * R.SuccessHeightFrac
		local slow = pelvis.AssemblyLinearVelocity.Magnitude < R.MaxSuccessSpeed
		if d.R >= 0.6 and upright and high and slow then
			d.Stable += dt
		else
			d.Stable = 0
		end
		if d.Stable >= R.StableTime then
			f.Recovery.Attempts = 0
			f.Balance = math.max(f.Balance, R.RestoredBalance * caps.BalanceMax)
			f.TiltTimer, f.AirTimer = 0, 0
			StateMachine.Set(f, "Idle", "Recovered")
		elseif t > R.Timeout then
			StateMachine.Set(f, "GroundedRecovery", "Attempt failed", { Wait = retryDelay(f), FaceDown = pelvis.CFrame.LookVector.Y < -0.3 })
		end
	elseif st == "SeverelyInjured" then
		f.StateData.FaceDown = pelvis.CFrame.LookVector.Y < -0.3
		if canEverStand(f) and StateMachine.Elapsed(f) > R.BraceTime then
			StateMachine.Set(f, "GroundedRecovery", "Able to try again", { Wait = retryDelay(f), FaceDown = f.StateData.FaceDown })
		end
	end

	local phase = st == "Recovering" and string.format("attempt %d r=%.1f", f.StateData.Attempt or 0, f.StateData.R or 0)
		or (StateDefs.Ground[st] and st or "-")
	if phase ~= f.LastRecoveryPhase then
		f.LastRecoveryPhase = phase
		Runtime.Debug.Attr(f, "RecoveryPhase", phase)
	end
end

return BalanceController
