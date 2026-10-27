--[[
	CloakView: the Cloak's look (Config.Armor.Pieces.Cloak, Config.Cloak), built by ArmorView.
	  collar  a band around the neck, welded to the Neck
	  mantle  a layer over the shoulders, welded to the UpperTorso, with a clasp at the front
	  cape    a cloth of Cols x Rows points; the top row is pinned across the back of the shoulders,
	          the rest is simulated here (verlet at a fixed Step): gravity, drag toward the wind,
	          distance constraints between neighbours, pushed out of the torso and leg boxes and
	          kept above the ground. Each cell is drawn as an anchored panel between its corners.
	Local parts only, like the armour shells. A cape stops simulating once its parts are gone
	(ArmorView took the cloak off, or the fighter left the workspace).
]]
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("RagdollRonin")
local Config = require(Shared:WaitForChild("Config"))

local CloakView = {}
local CL = Config.Cloak
local AR = Config.Armor

local COLLIDERS = {
	"UpperTorso", "LowerTorso",
	"LeftThighP", "LeftThighD", "LeftShinP", "LeftShinD",
	"RightThighP", "RightThighD", "RightShinP", "RightShinD",
}

local capes = {} -- active cape records
local groundParams = RaycastParams.new()
groundParams.CollisionGroup = "RR_GroundQuery"
local clock = 0

local function plain(name, size, color, material)
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Color = color
	p.Material = material
	p.Massless = true
	p.CanCollide, p.CanQuery, p.CanTouch = false, false, false
	return p
end

local function weldTo(part, s, folder)
	s.CastShadow = false
	local w = Instance.new("WeldConstraint")
	w.Part0 = part
	w.Part1 = s
	w.Parent = s
	s.Parent = folder
	return s
end

-- pinned top-row point (column c) in the upper torso's space
local function pinLocal(upper, c)
	local half = upper.Size * 0.5
	local x = (c - 1) / (CL.Cols - 1) - 0.5
	return Vector3.new(x * CL.TopWidth, half.Y - 0.02, half.Z + CL.BodyMargin)
end

-- hang the cloth straight down behind the shoulders
local function reset(cape)
	local cf = cape.Upper.CFrame
	local dy = CL.Length / (CL.Rows - 1)
	for r = 1, CL.Rows do
		for c = 1, CL.Cols do
			local top = pinLocal(cape.Upper, c)
			local p = cf:PointToWorldSpace(top) - Vector3.new(0, (r - 1) * dy, 0)
			cape.Pos[r][c] = p
			cape.Prev[r][c] = p
		end
	end
	cape.LastPin = cape.Pos[1][1]
end

local function restWidth(r)
	local t = (r - 1) / (CL.Rows - 1)
	return (CL.TopWidth + (CL.BottomWidth - CL.TopWidth) * t) / (CL.Cols - 1)
end

local function pushOutOfBox(p, part)
	local loc = part.CFrame:PointToObjectSpace(p)
	local h = part.Size * 0.5 + Vector3.one * CL.BodyMargin
	local dx, dy, dz = h.X - math.abs(loc.X), h.Y - math.abs(loc.Y), h.Z - math.abs(loc.Z)
	if dx <= 0 or dy <= 0 or dz <= 0 then
		return p
	end
	-- out along the axis of least penetration
	if dz <= dx and dz <= dy then
		loc = Vector3.new(loc.X, loc.Y, loc.Z >= 0 and h.Z or -h.Z)
	elseif dx <= dy then
		loc = Vector3.new(loc.X >= 0 and h.X or -h.X, loc.Y, loc.Z)
	else
		loc = Vector3.new(loc.X, loc.Y >= 0 and h.Y or -h.Y, loc.Z)
	end
	return part.CFrame:PointToWorldSpace(loc)
end

local function step(cape, dt, floorY)
	local pos, prev = cape.Pos, cape.Prev
	local gravity = Vector3.new(0, -workspace.Gravity * CL.GravityScale, 0)
	local gust = 1 + CL.Gust * math.sin(clock * 0.8 + cape.Phase)
	for r = 2, CL.Rows do
		for c = 1, CL.Cols do
			local p = pos[r][c]
			local v = (p - prev[r][c]) / dt
			local flutter = 1 + CL.Flutter * math.sin(clock * 3.1 + r * 0.9 + c * 1.7 + cape.Phase)
			local wind = CL.Wind * gust * flutter
			local a = gravity + (wind - v) * CL.Drag
			prev[r][c] = p
			pos[r][c] = p + v * dt + a * dt * dt
		end
	end

	local upper = cape.Upper
	for c = 1, CL.Cols do
		pos[1][c] = upper.CFrame:PointToWorldSpace(pinLocal(upper, c))
	end

	local dy = CL.Length / (CL.Rows - 1)
	local function satisfy(r1, c1, r2, c2, rest)
		local a, b = pos[r1][c1], pos[r2][c2]
		local d = b - a
		local len = d.Magnitude
		if len < 1e-6 then
			return
		end
		local corr = d * ((len - rest) / len)
		if r1 == 1 then -- pinned: only the free end moves
			pos[r2][c2] = b - corr
		else
			pos[r1][c1] = a + corr * 0.5
			pos[r2][c2] = b - corr * 0.5
		end
	end
	for _ = 1, CL.Iterations do
		for r = 1, CL.Rows do
			local w = restWidth(r)
			for c = 1, CL.Cols do
				if c < CL.Cols and r > 1 then
					satisfy(r, c, r, c + 1, w)
				end
				if r < CL.Rows then
					satisfy(r, c, r + 1, c, dy)
				end
			end
		end
	end

	for r = 2, CL.Rows do
		for c = 1, CL.Cols do
			local p = pos[r][c]
			for _, part in ipairs(cape.Colliders) do
				if part.Parent == cape.Model then
					p = pushOutOfBox(p, part)
				end
			end
			if floorY and p.Y < floorY then
				p = Vector3.new(p.X, floorY, p.Z)
			end
			pos[r][c] = p
		end
	end
end

local function render(cape, visible, parts, cframes)
	local pos = cape.Pos
	local i = 0
	for r = 1, CL.Rows - 1 do
		for c = 1, CL.Cols - 1 do
			i += 1
			local panel = cape.Panels[i]
			local a, b, d, e = pos[r][c], pos[r][c + 1], pos[r + 1][c], pos[r + 1][c + 1]
			local right = ((b - a) + (e - d)) * 0.5
			local down = ((d - a) + (e - b)) * 0.5
			local w, h = right.Magnitude, down.Magnitude
			if w > 1e-4 and h > 1e-4 then
				local x = right / w
				local up = -down / h
				local y = up - x * up:Dot(x)
				if y.Magnitude > 1e-4 then
					y = y.Unit
					local size = Vector3.new(w + CL.Thickness * 2, h + CL.Thickness * 2, CL.Thickness)
					if panel.Size ~= size then
						panel.Size = size
					end
					table.insert(parts, panel)
					table.insert(cframes, CFrame.fromMatrix((a + b + d + e) * 0.25, x, y, x:Cross(y)))
				end
			end
			panel.LocalTransparencyModifier = visible and 0 or 1
		end
	end
end

local function update(dt)
	clock += dt
	local camera = workspace.CurrentCamera
	local camPos = camera and camera.CFrame.Position or Vector3.zero
	local parts, cframes = {}, {}
	for i = #capes, 1, -1 do
		local cape = capes[i]
		local upper = cape.Upper
		if not cape.Panels[1].Parent or upper.Parent ~= cape.Model or not cape.Model.Parent then
			table.remove(capes, i)
			continue
		end
		local near = (upper.Position - camPos).Magnitude < CL.SimDistance
		if not near then
			cape.Far = true
			render(cape, false, {}, {})
			continue
		end
		local pin = upper.CFrame:PointToWorldSpace(pinLocal(upper, 1))
		if cape.Far or (pin - cape.LastPin).Magnitude > 8 then
			reset(cape) -- just came into range, or the fighter teleported / respawned
			cape.Far = false
		end
		cape.LastPin = pin

		local hit = workspace:Raycast(upper.Position, Vector3.new(0, -12, 0), groundParams)
		local floorY = hit and hit.Position.Y + CL.Thickness

		cape.Acc = math.min(cape.Acc + dt, CL.Step * 4)
		while cape.Acc >= CL.Step do
			cape.Acc -= CL.Step
			step(cape, CL.Step, floorY)
		end
		render(cape, true, parts, cframes)
	end
	if #parts > 0 then
		workspace:BulkMoveTo(parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

-- builds the cloak on this fighter; returns its parts (ArmorView destroys them to take it off)
function CloakView.Build(model, color, folder)
	local list = {}
	local neck = model:FindFirstChild("Neck")
	local upper = model:FindFirstChild("UpperTorso")
	if not (upper and upper:IsA("BasePart")) then
		return list
	end
	local inflate = AR.Inflate

	if neck and neck:IsA("BasePart") then
		local d = math.max(neck.Size.X, neck.Size.Z) + inflate * 3
		local collar = plain("Cloak_Collar", Vector3.new(neck.Size.Y * 0.7, d, d), color, Enum.Material.Fabric)
		collar.Shape = Enum.PartType.Cylinder -- along X: turned upright around the neck
		collar.CFrame = neck.CFrame * CFrame.new(0, -neck.Size.Y * 0.2, 0) * CFrame.Angles(0, 0, math.pi / 2)
		table.insert(list, weldTo(neck, collar, folder))
	end

	local half = upper.Size * 0.5
	local mantle = plain("Cloak_Mantle", Vector3.new(upper.Size.X + inflate * 5, upper.Size.Y * 0.18, upper.Size.Z + inflate * 5), color, Enum.Material.Fabric)
	mantle.CFrame = upper.CFrame * CFrame.new(0, half.Y - mantle.Size.Y * 0.4, 0)
	table.insert(list, weldTo(upper, mantle, folder))

	local clasp = plain("Cloak_Clasp", Vector3.one * (upper.Size.X * 0.11), CL.ClaspColor, Enum.Material.Metal)
	clasp.Shape = Enum.PartType.Ball
	clasp.CFrame = upper.CFrame * CFrame.new(0, half.Y - clasp.Size.Y * 0.6, -half.Z - inflate * 2.5)
	table.insert(list, weldTo(upper, clasp, folder))

	local cape = {
		Model = model,
		Upper = upper,
		Panels = {},
		Colliders = {},
		Pos = {},
		Prev = {},
		Acc = 0,
		Phase = math.random() * 10,
		Far = false,
	}
	for _, name in ipairs(COLLIDERS) do
		local part = model:FindFirstChild(name)
		if part and part:IsA("BasePart") then
			table.insert(cape.Colliders, part)
		end
	end
	for r = 1, CL.Rows do
		cape.Pos[r], cape.Prev[r] = {}, {}
	end
	for _ = 1, (CL.Rows - 1) * (CL.Cols - 1) do
		local panel = plain("Cloak_Cape", Vector3.one * 0.1, color, Enum.Material.Fabric)
		panel.Anchored = true
		panel.CFrame = upper.CFrame
		panel.Parent = folder
		table.insert(cape.Panels, panel)
		table.insert(list, panel)
	end
	reset(cape)
	table.insert(capes, cape)
	return list
end

function CloakView.Init(_ctx)
	RunService.RenderStepped:Connect(update)
end

return CloakView
