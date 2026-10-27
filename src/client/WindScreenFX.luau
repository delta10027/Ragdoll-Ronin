--[[
	WindScreenFX: screen-space effects for facing / walking into a strong wind (Sim.Wind).

	Exposure (0..1) = Wind.Strength * how squarely the camera faces into the wind.
	Push    (0..1) = how fast the fighter is walking into it (velocity along -wind / WalkSpeed).

	  Frost   soft icy-white glaze at the screen edges (thickest in the corners). Stays faint
	          while standing facing the wind, sharpens as you push into it.
	  Squint  faint cool shading at the top and bottom edges, like narrowed eyes.
	  Blur    peripheral softening through the Lighting DepthOfField (local to this client):
	          the fighter stays in focus, everything nearer/further softens. Restored when calm.
	  Streaks thin air streaks rushing outward past the screen edges; count, speed and opacity
	          follow Push, and they drift sideways with any crosswind.
	  Tint    slight cold, desaturated colour correction.

	Tuning lives in FX below.
]]
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage:WaitForChild("RagdollRonin"):WaitForChild("Config"))
local Wind = require(ReplicatedStorage.RagdollRonin:WaitForChild("Sim"):WaitForChild("Wind"))

local WindScreenFX = {}

local FX = {
	FrostColor = Color3.fromRGB(214, 232, 248),
	FrostMaxAlpha = 0.55, -- edge opacity at full exposure + full push
	FrostIdle = 0.45, -- fraction of the frost kept while standing still facing the wind
	FrostSide = 0.22, -- width of the left/right glaze (fraction of screen width)
	FrostTopBottom = 0.2, -- height of the top/bottom glaze (fraction of screen height)

	SquintColor = Color3.fromRGB(40, 52, 66),
	SquintMaxAlpha = 0.28,
	SquintSize = 0.11, -- fraction of screen height

	BlurFar = 0.6, -- DepthOfField FarIntensity at full
	BlurNear = 0.5, -- DepthOfField NearIntensity at full
	BlurFocusRadius = 12, -- studs kept sharp around the fighter at full

	StreakColor = Color3.fromRGB(235, 244, 255),
	StreakMaxAlpha = 0.55,
	StreakRate = 70, -- streaks per second at full push
	StreakIdleRate = 8, -- streaks per second standing in the wind
	StreakSpeed = { 900, 1900 }, -- px/s at full push
	StreakLength = { 70, 220 }, -- px
	StreakPool = 70,
	StreakSpawnRadius = { 0.3, 0.46 }, -- spawn ring, fraction of half the screen diagonal
	CrossDrift = 700, -- px/s sideways drift per unit of crosswind

	Tint = Color3.fromRGB(228, 238, 255),
	TintSaturation = -0.18,

	Rise = 3.5, -- easing sharpness when the effect builds
	Fall = 2.2, -- easing sharpness when it fades
}

local state = {
	Exposure = 0,
	Push = 0,
	SpawnDebt = 0,
	T = 0,
}

local function ease(cur, target, dt)
	local k = target > cur and FX.Rise or FX.Fall
	return cur + (target - cur) * (1 - math.exp(-k * dt))
end

local function lerp(a, b, t)
	return a + (b - a) * t
end

-- an edge band: solid at the screen edge, fading inward
local function edge(parent, name, color, anchor, pos, size, rotation)
	local f = Instance.new("Frame")
	f.Name = name
	f.BorderSizePixel = 0
	f.BackgroundColor3 = color
	f.BackgroundTransparency = 1
	f.AnchorPoint = anchor
	f.Position = pos
	f.Size = size
	local g = Instance.new("UIGradient")
	g.Rotation = rotation -- gradient runs from the edge (0) inward (1)
	g.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.3, 0.45),
		NumberSequenceKeypoint.new(0.65, 0.85),
		NumberSequenceKeypoint.new(1, 1),
	})
	g.Parent = f
	f.Parent = parent
	return f
end

function WindScreenFX.Init(ctx)
	local gui = Instance.new("ScreenGui")
	gui.Name = "RR_WindScreenFX"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 4 -- under the HUD (5)
	gui.Parent = ctx.Player:WaitForChild("PlayerGui")
	state.Gui = gui

	local s, tb = FX.FrostSide, FX.FrostTopBottom
	state.Frost = {
		edge(gui, "FrostLeft", FX.FrostColor, Vector2.new(0, 0), UDim2.new(0, 0, 0, 0), UDim2.new(s, 0, 1, 0), 0),
		edge(gui, "FrostRight", FX.FrostColor, Vector2.new(1, 0), UDim2.new(1, 0, 0, 0), UDim2.new(s, 0, 1, 0), 180),
		edge(gui, "FrostTop", FX.FrostColor, Vector2.new(0, 0), UDim2.new(0, 0, 0, 0), UDim2.new(1, 0, tb, 0), 90),
		edge(gui, "FrostBottom", FX.FrostColor, Vector2.new(0, 1), UDim2.new(0, 0, 1, 0), UDim2.new(1, 0, tb, 0), 270),
	}
	state.Squint = {
		edge(gui, "SquintTop", FX.SquintColor, Vector2.new(0, 0), UDim2.new(0, 0, 0, 0), UDim2.new(1, 0, FX.SquintSize, 0), 90),
		edge(gui, "SquintBottom", FX.SquintColor, Vector2.new(0, 1), UDim2.new(0, 0, 1, 0), UDim2.new(1, 0, FX.SquintSize, 0), 270),
	}

	local streakLayer = Instance.new("Frame")
	streakLayer.Name = "Streaks"
	streakLayer.BackgroundTransparency = 1
	streakLayer.Size = UDim2.fromScale(1, 1)
	streakLayer.ClipsDescendants = true
	streakLayer.Parent = gui
	state.Streaks = {}
	for i = 1, FX.StreakPool do
		local f = Instance.new("Frame")
		f.Name = "Streak"
		f.BorderSizePixel = 0
		f.BackgroundColor3 = FX.StreakColor
		f.AnchorPoint = Vector2.new(0.5, 0.5)
		f.Visible = false
		local g = Instance.new("UIGradient")
		g.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.6, 0),
			NumberSequenceKeypoint.new(1, 1),
		})
		g.Parent = f
		f.Parent = streakLayer
		state.Streaks[i] = { Frame = f, Alive = false }
	end

	local cc = Instance.new("ColorCorrectionEffect")
	cc.Name = "RR_WindTint"
	cc.Enabled = false
	cc.Parent = Lighting
	state.Tint = cc

	-- the place's own DepthOfField (changes made here stay on this client)
	local dof = Lighting:FindFirstChildOfClass("DepthOfFieldEffect")
	if not dof then
		dof = Instance.new("DepthOfFieldEffect")
		dof.Name = "RR_WindDOF"
		dof.Enabled = false
		dof.FarIntensity, dof.NearIntensity = 0, 0
		dof.Parent = Lighting
	end
	state.DOF = dof
	state.DOFBase = {
		Enabled = dof.Enabled,
		Far = dof.FarIntensity,
		Near = dof.NearIntensity,
		Focus = dof.FocusDistance,
		Radius = dof.InFocusRadius,
	}
end

local rng = Random.new()

local function spawnStreak(screen, push, cross)
	for _, s in ipairs(state.Streaks) do
		if not s.Alive then
			local ang = rng:NextNumber(0, 2 * math.pi)
			local halfDiag = screen.Magnitude / 2
			local r = rng:NextNumber(FX.StreakSpawnRadius[1], FX.StreakSpawnRadius[2]) * halfDiag
			local outward = Vector2.new(math.cos(ang), math.sin(ang))
			local speed = lerp(FX.StreakSpeed[1] * 0.35, rng:NextNumber(FX.StreakSpeed[1], FX.StreakSpeed[2]), push)
			s.Pos = screen / 2 + outward * r
			s.Vel = outward * speed + Vector2.new(cross * FX.CrossDrift, 0)
			s.Length = rng:NextNumber(FX.StreakLength[1], FX.StreakLength[2]) * lerp(0.6, 1, push)
			s.Thick = rng:NextInteger(1, 2)
			s.Age = 0
			s.Life = rng:NextNumber(0.25, 0.55)
			s.Alpha = rng:NextNumber(0.5, 1)
			s.Alive = true
			s.Frame.Visible = true
			return
		end
	end
end

function WindScreenFX.Update(ctx, dt)
	if not state.Gui then
		return
	end
	state.T += dt
	local cam = workspace.CurrentCamera

	-- targets
	local exposureT, pushT, cross = 0, 0, 0
	local strength = Wind.Strength()
	local model = ctx.Fighter
	local body = model and model.Parent and (model:FindFirstChild("UpperTorso") or model:FindFirstChild("LowerTorso"))
	if strength > 0 and body then
		local dir = Wind.Get() -- blows toward
		local look = cam.CFrame.LookVector
		look = Vector3.new(look.X, 0, look.Z)
		if look.Magnitude > 1e-3 then
			look = look.Unit
			local facing = math.clamp((-look:Dot(dir) + 0.2) / 1.2, 0, 1) -- 1 face-on, fades out past side-on
			exposureT = strength * facing
			cross = cam.CFrame.RightVector:Dot(dir) -- + blows to the right on screen
		end
		local v = body.AssemblyLinearVelocity
		local into = -Vector3.new(v.X, 0, v.Z):Dot(dir) -- studs/s straight into the wind
		pushT = math.clamp(into / (0.6 * Config.Movement.WalkSpeed), 0, 1) * (exposureT > 0 and 1 or 0)
	end
	state.Exposure = ease(state.Exposure, exposureT, dt)
	state.Push = ease(state.Push, pushT, dt)
	local e, p = state.Exposure, state.Push
	local active = e > 0.01
	state.Gui.Enabled = active or state.AnyStreak == true

	-- frost + squint (a slow shimmer so the glaze doesn't sit dead still)
	local shimmer = 1 + math.noise(state.T * 0.7, 3.1) * 0.25
	local frost = FX.FrostMaxAlpha * e * lerp(FX.FrostIdle, 1, p) * shimmer
	for i, f in ipairs(state.Frost) do
		local side = 1 + math.noise(state.T * 0.5, i * 7.3) * 0.2
		f.BackgroundTransparency = 1 - math.clamp(frost * side, 0, 1)
	end
	local squint = FX.SquintMaxAlpha * e * lerp(0.3, 1, p)
	for _, f in ipairs(state.Squint) do
		f.BackgroundTransparency = 1 - squint
	end

	-- peripheral blur through depth of field: focus on the fighter, soften the rest
	local dof, base = state.DOF, state.DOFBase
	local b = e * lerp(0.35, 1, p)
	if b > 0.01 then
		dof.Enabled = true
		local focusDist = body and (body.Position - cam.CFrame.Position).Magnitude or base.Focus
		dof.FarIntensity = lerp(base.Enabled and base.Far or 0, FX.BlurFar, b)
		dof.NearIntensity = lerp(base.Enabled and base.Near or 0, FX.BlurNear, b)
		dof.FocusDistance = lerp(base.Focus, focusDist, math.min(1, b * 3))
		dof.InFocusRadius = lerp(base.Radius, FX.BlurFocusRadius, b)
		state.DOFTouched = true
	elseif state.DOFTouched then
		dof.Enabled = base.Enabled
		dof.FarIntensity, dof.NearIntensity = base.Far, base.Near
		dof.FocusDistance, dof.InFocusRadius = base.Focus, base.Radius
		state.DOFTouched = false
	end

	-- cold tint
	local tint = state.Tint
	tint.Enabled = active
	if active then
		tint.TintColor = Color3.new(1, 1, 1):Lerp(FX.Tint, e)
		tint.Saturation = FX.TintSaturation * e
	end

	-- streaks
	local screen = state.Gui.AbsoluteSize
	if active and screen.X > 0 then
		local rate = (FX.StreakIdleRate + (FX.StreakRate - FX.StreakIdleRate) * p) * e
		state.SpawnDebt += rate * dt
		while state.SpawnDebt >= 1 do
			state.SpawnDebt -= 1
			spawnStreak(screen, p, cross)
		end
	else
		state.SpawnDebt = 0
	end
	local any = false
	local streakAlpha = FX.StreakMaxAlpha * math.max(e, 0.15) * lerp(0.4, 1, p)
	for _, s in ipairs(state.Streaks) do
		if s.Alive then
			s.Age += dt
			s.Pos += s.Vel * dt
			local outOf = s.Pos.X < -200 or s.Pos.Y < -200 or s.Pos.X > screen.X + 200 or s.Pos.Y > screen.Y + 200
			if s.Age >= s.Life or outOf then
				s.Alive = false
				s.Frame.Visible = false
			else
				any = true
				local f = s.Frame
				local life = s.Age / s.Life
				local fade = math.min(1, life * 5) * math.min(1, (1 - life) * 3)
				f.Position = UDim2.fromOffset(s.Pos.X, s.Pos.Y)
				f.Size = UDim2.fromOffset(s.Length, s.Thick)
				f.Rotation = math.deg(math.atan2(s.Vel.Y, s.Vel.X))
				f.BackgroundTransparency = 1 - streakAlpha * s.Alpha * fade
			end
		end
	end
	state.AnyStreak = any
end

return WindScreenFX
