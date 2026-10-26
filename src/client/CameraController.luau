--[[
	CameraController: over-the-shoulder third-person camera (Scriptable).
	Yaw/pitch are changed by mouse movement ONLY while no sword button is held; while M1/M2 are
	held the mouse drives the combat cursor instead and the camera (and therefore facing) holds.
	The camera yaw is sent to the server as the desired facing.
	Locked on (K, LockOn) the yaw follows the target instead of the mouse.
	V toggles a front view (camera in front of the fighter looking back at it, e.g. to inspect
	poses); facing and controls are unchanged, only the camera moves round.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage:WaitForChild("RagdollRonin"):WaitForChild("Config"))
local LockOn = require(script.Parent.LockOn)

local CameraController = {}
local CC = Config.Camera

local params = RaycastParams.new()
params.CollisionGroup = "RR_GroundQuery" -- world geometry only (never fighters, swords or debris)
params.IgnoreWater = true

function CameraController.Init(ctx)
	ctx.Camera = { Yaw = 0, Pitch = -0.2, Focus = nil, Front = false }
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
	cam.CFrame = CFrame.new(desired) * rot
end

return CameraController
