--[[
	WeatherView: this client's rain and weather sounds.

	Rain (Config.Rain, workspace attribute "RainIntensity" 0..1, set from the loadout menu):
	  * drops: a particle emitter on an invisible plate above the camera, tilted so the drops fall
	    along gravity + Config.Rain.WindDrift x the wind (Sim.Wind), and shifted upwind so the slanted
	    rain still lands around the camera
	  * splashes: a second emitter on the ground under the camera
	  * a slightly darker, greyer colour grade
	  * the rain sound (Config.Rain.SoundId), volume following the intensity
	Wind sound (Config.Wind.SoundId): louder and a little higher pitched the stronger the wind,
	silent below Config.Wind.CalmSpeed.
	Everything is local (parts under the camera, sounds in SoundService) and eases toward the
	server's values so changes fade in and out.
]]
local Lighting = game:GetService("Lighting")
local SoundService = game:GetService("SoundService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage:WaitForChild("RagdollRonin"):WaitForChild("Config"))
local Wind = require(ReplicatedStorage.RagdollRonin:WaitForChild("Sim"):WaitForChild("Wind"))

local WeatherView = {}
local R = Config.Rain
local W = Config.Wind
local DROP_TEXTURE = "rbxasset://textures/whiteCircle.png"

local state = { Rain = 0, WindVol = 0 }

local groundParams = RaycastParams.new()
groundParams.CollisionGroup = "RR_GroundQuery" -- world geometry only
groundParams.IgnoreWater = true

-- "123", 123 or "rbxassetid://123" -> "rbxassetid://123"; "" / nil -> nil
local function soundUrl(id)
	if typeof(id) == "number" then
		return id > 0 and ("rbxassetid://" .. math.floor(id)) or nil
	end
	if typeof(id) ~= "string" then
		return nil
	end
	id = id:gsub("%s", "")
	if id == "" then
		return nil
	end
	if id:match("^%d+$") then
		return "rbxassetid://" .. id
	end
	return id
end

local function loopSound(name, id)
	local url = soundUrl(id)
	if not url then
		return nil
	end
	local s = Instance.new("Sound")
	s.Name = name
	s.SoundId = url
	s.Looped = true
	s.Volume = 0
	s.Parent = SoundService
	return s
end

local function plate(name, parent)
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Transparency = 1
	p.Parent = parent
	return p
end

function WeatherView.Init(_ctx)
	local cam = workspace.CurrentCamera
	local folder = Instance.new("Folder")
	folder.Name = "RR_Weather"
	folder.Parent = cam
	state.Folder = folder

	-- drops
	local sky = plate("RainPlate", folder)
	sky.Size = Vector3.new(R.Area, R.Area, 1) -- (faces along its look direction = the fall)
	local drops = Instance.new("ParticleEmitter")
	drops.Name = "Drops"
	drops.Texture = DROP_TEXTURE
	drops.Shape = Enum.ParticleEmitterShape.Box
	drops.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
	drops.EmissionDirection = Enum.NormalId.Front
	drops.Orientation = Enum.ParticleOrientation.VelocityParallel
	drops.Speed = NumberRange.new(R.FallSpeed[1], R.FallSpeed[2])
	drops.SpreadAngle = Vector2.new(2, 2)
	drops.Lifetime = NumberRange.new((R.Height + 8) / R.FallSpeed[2], (R.Height + 12) / R.FallSpeed[1])
	drops.Size = NumberSequence.new(R.DropSize)
	drops.Squash = NumberSequence.new(R.DropSquash)
	drops.Color = ColorSequence.new(R.DropColor)
	drops.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.08, R.DropTransparency),
		NumberSequenceKeypoint.new(1, R.DropTransparency),
	})
	drops.LightInfluence = 0.8
	drops.LightEmission = 0.05
	drops.Rate = 0
	drops.Parent = sky
	state.Sky, state.Drops = sky, drops

	-- splashes
	local ground = plate("SplashPlate", folder)
	ground.Size = Vector3.new(R.SplashArea, 0.2, R.SplashArea)
	local splash = Instance.new("ParticleEmitter")
	splash.Name = "Splashes"
	splash.Texture = DROP_TEXTURE
	splash.Shape = Enum.ParticleEmitterShape.Box
	splash.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
	splash.EmissionDirection = Enum.NormalId.Top
	splash.Speed = NumberRange.new(3, 7)
	splash.SpreadAngle = Vector2.new(35, 35)
	splash.Acceleration = Vector3.new(0, -60, 0)
	splash.Lifetime = NumberRange.new(0.12, 0.25)
	splash.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.12),
		NumberSequenceKeypoint.new(1, 0.03),
	})
	splash.Squash = NumberSequence.new(1.2) -- (wider than tall: a flat spray, not a ball)
	splash.Color = ColorSequence.new(R.DropColor)
	splash.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.35),
		NumberSequenceKeypoint.new(1, 1),
	})
	splash.LightInfluence = 0.8
	splash.Rate = 0
	splash.Parent = ground
	state.Ground, state.Splash = ground, splash

	local cc = Instance.new("ColorCorrectionEffect")
	cc.Name = "RR_RainGrade"
	cc.Enabled = false
	cc.Parent = Lighting
	state.Grade = cc

	state.RainSound = loopSound("RR_RainSound", R.SoundId)
	state.WindSound = loopSound("RR_WindSound", W.SoundId)
end

local function ease(cur, target, dt, rate)
	return cur + (target - cur) * (1 - math.exp(-rate * dt))
end

local function setPlaying(s, on)
	if not s then
		return
	end
	if on and not s.IsPlaying then
		s:Play()
	elseif not on and s.IsPlaying then
		s:Stop()
	end
end

function WeatherView.Update(_ctx, dt)
	if not state.Folder then
		return
	end
	local cam = workspace.CurrentCamera
	if state.Folder.Parent ~= cam then
		state.Folder.Parent = cam -- (the camera can be replaced)
	end
	local camPos = cam.CFrame.Position

	-- rain
	local want = workspace:GetAttribute("RainIntensity")
	want = typeof(want) == "number" and math.clamp(want, 0, 1) or R.Intensity
	state.Rain = ease(state.Rain, want, dt, 1.2)
	local r = state.Rain
	if r < 0.005 then
		r = 0
	end

	local fall = (R.FallSpeed[1] + R.FallSpeed[2]) / 2
	local drift = Wind.Velocity() * R.WindDrift
	local vel = Vector3.new(drift.X, -fall, drift.Z)
	local t = (R.Height + 4) / fall -- time from the plate to camera height
	local origin = camPos + Vector3.new(0, R.Height, 0) - Vector3.new(drift.X, 0, drift.Z) * t
	-- (up = +Z: the fall is never horizontal, so it can't be parallel to it)
	state.Sky.CFrame = CFrame.lookAt(origin, origin + vel, Vector3.zAxis)
	state.Drops.Rate = R.MaxDrops * r

	local hit = workspace:Raycast(camPos, Vector3.new(0, -200, 0), groundParams)
	local groundY = hit and hit.Position.Y or (camPos.Y - 10)
	state.Ground.CFrame = CFrame.new(camPos.X, groundY + 0.15, camPos.Z)
	state.Splash.Rate = R.MaxSplashes * r

	local grade = state.Grade
	grade.Enabled = r > 0
	if r > 0 then
		grade.Brightness = R.Darken * r
		grade.Saturation = R.Desaturate * r
	end

	if state.RainSound then
		state.RainSound.Volume = R.SoundVolume * r
		setPlaying(state.RainSound, r > 0)
	end

	-- wind sound
	if state.WindSound then
		local _, speed = Wind.Get()
		local k = math.clamp((speed - W.CalmSpeed) / (W.MaxSpeed - W.CalmSpeed), 0, 1)
		local target = speed >= W.CalmSpeed and (W.SoundVolume[1] + (W.SoundVolume[2] - W.SoundVolume[1]) * k) or 0
		state.WindVol = ease(state.WindVol, target, dt, 1.5)
		state.WindSound.Volume = state.WindVol
		state.WindSound.PlaybackSpeed = W.SoundPitch[1] + (W.SoundPitch[2] - W.SoundPitch[1]) * k
		setPlaying(state.WindSound, state.WindVol > 0.005)
	end
end

return WeatherView
