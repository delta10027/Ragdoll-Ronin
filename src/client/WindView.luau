--[[
	WindView: faint wave streaks that show the wind (Shared.Sim.Wind, Config.Wind). Each wisp is an
	invisible local part carrying a camera-facing Trail; it flies downwind at the wind's speed and
	bobs up and down (and a little sideways) every WispWavelength studs, so its trail draws a wave. Wisps appear at
	random around the camera, live a few seconds, then stop emitting and are reused once their
	trail has faded. Their number follows the wind: none when calm, Config.Wind.Wisps at FullSpeed.
	Local parts only.
]]
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("RagdollRonin")
local Config = require(Shared:WaitForChild("Config"))
local Wind = require(Shared:WaitForChild("Sim"):WaitForChild("Wind"))

local WindView = {}
local W = Config.Wind

local folder
local wisps = {}
local clock = 0
local groundParams = RaycastParams.new()
groundParams.CollisionGroup = "RR_GroundQuery"

local function newWisp()
	local p = Instance.new("Part")
	p.Name = "WindWisp"
	p.Size = Vector3.one * 0.1
	p.Transparency = 1
	p.Anchored = true
	p.CanCollide, p.CanQuery, p.CanTouch, p.CastShadow = false, false, false, false
	local a0 = Instance.new("Attachment")
	a0.Position = Vector3.new(0, 0.05, 0)
	a0.Parent = p
	local a1 = Instance.new("Attachment")
	a1.Position = Vector3.new(0, -0.05, 0)
	a1.Parent = p
	local trail = Instance.new("Trail")
	trail.Attachment0, trail.Attachment1 = a0, a1
	trail.FaceCamera = true
	trail.LightEmission = 0.4
	trail.Color = ColorSequence.new(Color3.new(1, 1, 1))
	-- faint at the head, fading out along the tail
	trail.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, W.WispTransparency),
		NumberSequenceKeypoint.new(1, 1),
	})
	trail.WidthScale = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(1, 0.3),
	})
	trail.Enabled = false
	trail.Parent = p
	p.Parent = folder
	return { Part = p, Trail = trail, Alive = false, FreeAt = 0 }
end

-- start a wisp somewhere around the camera, on the upwind side more often than not
local function launch(w, center, dir, speed)
	local angle = math.random() * 2 * math.pi
	local r = W.WispRadius * math.sqrt(math.random())
	local pos = center + Vector3.new(math.cos(angle) * r, 0, math.sin(angle) * r) - dir * W.WispRadius * 0.3
	local hit = workspace:Raycast(pos + Vector3.new(0, 30, 0), Vector3.new(0, -80, 0), groundParams)
	local ground = hit and hit.Position.Y or center.Y - 4
	w.Origin = Vector3.new(pos.X, ground + 0.5 + math.random() * 7, pos.Z)
	w.Age = 0
	w.Travel = 0
	w.Life = W.WispLife[1] + math.random() * (W.WispLife[2] - W.WispLife[1])
	w.Phase = math.random() * 2 * math.pi
	w.Alive = true
	w.Part.CFrame = CFrame.new(w.Origin)
	w.Trail.Lifetime = math.clamp(W.WispTrailLength / speed, 0.15, 1.5)
	w.Trail:Clear()
	w.Trail.Enabled = true
end

local function update(dt)
	clock += dt
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	local dir, speed = Wind.Get()
	local want = speed < W.CalmSpeed and 0 or math.ceil(W.Wisps * math.clamp(speed / W.FullSpeed, 0, 1))
	local center = camera.CFrame.Position + camera.CFrame.LookVector * 12
	local side = Vector3.yAxis:Cross(dir)

	local alive = 0
	for _, w in ipairs(wisps) do
		if w.Alive then
			alive += 1
		end
	end
	while #wisps < want do
		table.insert(wisps, newWisp())
	end

	local parts, cframes = {}, {}
	for _, w in ipairs(wisps) do
		if w.Alive then
			w.Age += dt
			local far = (w.Part.Position - center).Magnitude > W.WispRadius * 1.6
			if w.Age >= w.Life or far or speed < W.CalmSpeed then
				-- stop emitting; the trail fades before the wisp is reused
				w.Alive = false
				w.Trail.Enabled = false
				w.FreeAt = clock + w.Trail.Lifetime
				alive -= 1
			else
				w.Travel += speed * dt
				local k = w.Travel / W.WispWavelength * 2 * math.pi
				local wave = math.sin(k + w.Phase) * W.WispWave
				local sway = math.sin(k * 0.6 + w.Phase * 1.7) * W.WispWave * 0.5
				local pos = w.Origin + dir * w.Travel + Vector3.new(0, wave, 0) + side * sway
				table.insert(parts, w.Part)
				table.insert(cframes, CFrame.new(pos))
			end
		elseif alive < want and clock >= w.FreeAt then
			launch(w, center, dir, speed)
			alive += 1
		end
	end
	if #parts > 0 then
		workspace:BulkMoveTo(parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

function WindView.Init(_ctx)
	folder = Instance.new("Folder")
	folder.Name = "RR_Wind"
	folder.Parent = workspace
	RunService.RenderStepped:Connect(update)
end

return WindView
