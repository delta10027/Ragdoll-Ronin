--[[
	CameraController: over-the-shoulder third-person camera (Scriptable).
	Yaw/pitch are changed by mouse movement ONLY while no sword button is held; while M1/M2 are
	held the mouse drives the combat cursor instead and the camera (and therefore facing) holds.
	The camera yaw is sent to the server as the desired facing.
	Locked on (K, LockOn) the yaw follows the target instead of the mouse.
	V toggles a front view (camera in front of the fighter looking back at it, e.g. to inspect
	poses); facing and controls are unchanged, only the camera moves round.
	Walking into a strong wind (Sim.Wind) shakes the camera: scaled by Wind.Strength, how fast the
	fighter walks and how straight into the wind, eased in and out (WIND_SHAKE below).
	Sprinting shakes it too (SPRINT_SHAKE below): a jolt down on every footfall (synced to the
	fighter's own gait when this client simulates it), a side-to-side sway per stride and a
	little jitter, scaled by how far past walking speed the fighter is moving.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage:WaitForChild("RagdollRonin"):WaitForChild("Config"))
local LockOn = require(script.Parent.LockOn)
local Wind = require(ReplicatedStorage.RagdollRonin:WaitForChild("Sim"):WaitForChild("Wind"))

-- camera shake when walking into the wind
local WIND_SHAKE = {
	Angle = math.rad(0.9), -- max rotational wobble at full shake (radians)
	Offset = 0.04, -- max positional jitter at full shake (studs)
	Frequency =2, -- wobble speed (noise cycles per second)
	RiseSharpness = 2, -- how fast the shake builds up
	FallSharpness = 6, -- how fast it settles once you stop / turn away
}

-- camera shake while sprinting (speed past Config.Movement.WalkSpeed)
local SPRINT_SHAKE = {
	FootfallDrop = 0.03, -- studs the camera jolts down as each foot lands
	FootfallPitch = math.rad(0.2), -- and how far it nods with it
	Sway = math.rad(0.1), -- side-to-side roll, once per stride
	Jitter = math.rad(0.15), -- small random wobble on top
	JitterFrequency = 7, -- noise cycles per second
	StepRate = 4.6, -- footfalls per second when the gait can't be read (not this client's fighter)
	RiseSharpness = 3,
	FallSharpness = 7,
}

local CameraController = {}
local CC = Config.Camera

local params = RaycastParams.new()
params.CollisionGroup = "RR_GroundQuery" -- world geometry only (never fighters, swords or debris)
params.IgnoreWater = true

function CameraController.Init(ctx)
	ctx.Camera = { Yaw = 0, Pitch = -0.2, Focus = nil, Front = false, Shake = 0, ShakeT = 0, Sprint = 0, SprintT = 0 }
	local label = Instance.new("TextLabel")
	label.Name = "FrontViewLabel"
	label.AnchorPoint = Vector2.new(0.5, 0)
	label.Position = UDim2.new(0.5, 0, 0, 12)
	label.Size = UDim2.fromOffset(220, 26)
	label.BackgroundColor3 = Color3.new(0, 0, 0)
	label.BackgroundTransparency = 0.45
	label.TextColor3 = Color3.new(1, 1, 1)
	label.Font = Enum.Font.GothamMedium
	label.TextSize = 14
	label.Text = "Front view (V to return)"
	label.Visible = false
	label.Parent = ctx.Gui
	ctx.Camera.Label = label
end

function CameraController.ToggleFront(ctx)
	local c = ctx.Camera
	c.Front = not c.Front
	c.Label.Visible = c.Front
end

function CameraController.OnNewFighter(ctx, model)
	local pelvis = model:WaitForChild("LowerTorso", 5)
	if pelvis then
		local look = pelvis.CFrame.LookVector
		ctx.Camera.Yaw = math.atan2(-look.X, -look.Z)
		ctx.Camera.Focus = nil
	end
end

function CameraController.Rotate(ctx, dx, dy)
	local c = ctx.Camera
	if ctx.Lock and ctx.Lock.Target then
		dx = 0 -- (locked on: the yaw follows the target)
	end
	c.Yaw = (c.Yaw - dx * Config.Aim.CameraSensitivity) % (2 * math.pi)
	c.Pitch = math.clamp(c.Pitch - dy * Config.Aim.CameraSensitivity, CC.MinPitch, CC.MaxPitch)
end

-- 0..1: how hard the fighter is pushing into the wind right now
local function windShakeTarget(focusPart)
	local strength = Wind.Strength()
	if strength <= 0 then
		return 0
	end
	local v = focusPart.AssemblyLinearVelocity
	local vel = Vector3.new(v.X, 0, v.Z)
	local speed = vel.Magnitude
	if speed < 1 then
		return 0
	end
	local dir = Wind.Get()
	local into = math.max(0, -(vel / speed):Dot(dir)) -- 1 straight into it, 0 across or with it
	local walking = math.clamp(speed / (0.3 * Config.Movement.WalkSpeed), 0, 1)
	return strength * into * walking
end

local function shakeCFrame(c, dt, focusPart)
	local target = windShakeTarget(focusPart)
	local sharp = target > c.Shake and WIND_SHAKE.RiseSharpness or WIND_SHAKE.FallSharpness
	c.Shake += (target - c.Shake) * (1 - math.exp(-sharp * dt))
	if c.Shake < 0.01 then
		return CFrame.identity
	end
	c.ShakeT += dt * WIND_SHAKE.Frequency
	local t, s = c.ShakeT, c.Shake
	local a, o = WIND_SHAKE.Angle * s * 2, WIND_SHAKE.Offset * s * 2 -- (math.noise spans about +-0.5)
	return CFrame.new(
		math.noise(t, 11.3) * o,
		math.noise(t, 27.1) * o,
		0
	) * CFrame.Angles(
		math.noise(t, 3.7) * a,
		math.noise(t, 5.9) * a,
		math.noise(t, 8.2) * a * 1.5
	)
end

local function sprintShakeCFrame(ctx, c, dt, focusPart)
	local M = Config.Movement
	local v = focusPart.AssemblyLinearVelocity
	local speed = Vector3.new(v.X, 0, v.Z).Magnitude
	local lo = M.WalkSpeed * 1.05
	local hi = M.WalkSpeed * (M.SprintSpeedMult or 1.7)
	local target = hi > lo and math.clamp((speed - lo) / (hi - lo), 0, 1) or 0
	local sharp = target > c.Sprint and SPRINT_SHAKE.RiseSharpness or SPRINT_SHAKE.FallSharpness
	c.Sprint += (target - c.Sprint) * (1 - math.exp(-sharp * dt))
	if c.Sprint < 0.01 then
		return CFrame.identity
	end
	local s = c.Sprint
	-- gait phase (0..2pi per stride, a foot lands at 0 and pi): this client's own simulation of
	-- its fighter when it runs one, otherwise a steady clock
	local p = ctx.Prediction
	local f = p and p.Owner and p.Fighter
	local phase = f and f.Gait and f.Gait.Phase
	if typeof(phase) ~= "number" then
		c.SprintT += dt * SPRINT_SHAKE.StepRate * math.pi
		phase = c.SprintT
	end
	local impact = math.max(0, math.cos(2 * phase)) ^ 6 -- sharp spike at each footfall
	c.ShakeT2 = (c.ShakeT2 or 0) + dt * SPRINT_SHAKE.JitterFrequency
	local t, j = c.ShakeT2, SPRINT_SHAKE.Jitter * s * 2
	return CFrame.new(0, -SPRINT_SHAKE.FootfallDrop * impact * s, 0) * CFrame.Angles(
		-SPRINT_SHAKE.FootfallPitch * impact * s + math.noise(t, 41.7) * j,
		math.noise(t, 53.3) * j,
		SPRINT_SHAKE.Sway * math.sin(phase) * s + math.noise(t, 67.9) * j
	)
end

function CameraController.Update(ctx, dt)
	local cam = workspace.CurrentCamera
	if cam.CameraType ~= Enum.CameraType.Scriptable then
		cam.CameraType = Enum.CameraType.Scriptable
	end
	local model = ctx.Fighter
	local focusPart = model and (model:FindFirstChild("UpperTorso") or model:FindFirstChild("LowerTorso"))
	if not focusPart then
		return
	end
	local c = ctx.Camera
	local target = focusPart.Position + Vector3.new(0, CC.FocusHeight, 0)
	if not c.Focus or (c.Focus - target).Magnitude > 30 then
		c.Focus = target
	else
		c.Focus = c.Focus:Lerp(target, 1 - math.exp(-CC.FollowSharpness * dt))
	end
	local lockYaw, lockPitch = LockOn.Aim(ctx, c.Focus)
	if lockYaw then
		local k = 1 - math.exp(-CC.LockTurnSharpness * dt)
		c.Yaw = (c.Yaw + ((lockYaw - c.Yaw + math.pi) % (2 * math.pi) - math.pi) * k) % (2 * math.pi)
		c.Pitch = math.clamp(c.Pitch + (lockPitch - c.Pitch) * k * 0.5, CC.MinPitch, CC.MaxPitch)
	end
	local yaw = c.Front and c.Yaw + math.pi or c.Yaw
	local rot = CFrame.Angles(0, yaw, 0) * CFrame.Angles(c.Pitch, 0, 0)
	local desired = c.Focus + rot:VectorToWorldSpace(c.Front and CC.FrontOffset or CC.Offset)
	local hit = workspace:Raycast(c.Focus, desired - c.Focus, params)
	if hit then
		desired = hit.Position + hit.Normal * 0.3
	end
	cam.CFrame = CFrame.new(desired) * rot * shakeCFrame(c, dt, focusPart) * sprintShakeCFrame(ctx, c, dt, focusPart)
end

return CameraController
