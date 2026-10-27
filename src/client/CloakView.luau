--[[
	CloakView: the cloth pieces' look (Config.Armor.Pieces Cloak, Cape and Scarf; their shapes in
	Config.Cloak.Styles), built by ArmorView.
	  collar  a band around the neck, welded to the Neck (the Scarf's is a thick wrap)
	  mantle  a layer over the shoulders, welded to the UpperTorso, with a clasp at the front
	  cape    a cloth of Cols x Rows points (a Scarf: one per strip, its two tails); the top row is
	          pinned across the back of the shoulders, the rest is simulated here (verlet at a fixed
	          Step): gravity, drag toward the wind (Shared.Sim.Wind, gusting and fluttering along
	          the cloth), distance constraints between neighbours, pushed out of the torso and leg
	          boxes (and a bag's, AddColliders) and kept above the ground. Each cell is drawn as an
	          anchored panel between its corners.
	Local parts only, like the armour shells. A cape stops simulating once its parts are gone
	(ArmorView took the cloak off, or the fighter left the workspace).
	For a figure in a ViewportFrame (the inventory) Build takes opts:
	  Wind    a fixed wind velocity instead of the server's; the cape is moved directly (not
	          BulkMoveTo, which only works in the workspace), always simulated, no ground
	  Static  settle the cloth once and leave it (item icons)
]]
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("RagdollRonin")
local Config = require(Shared:WaitForChild("Config"))
local Wind = require(Shared:WaitForChild("Sim"):WaitForChild("Wind"))

local CloakView = {}
local CL = Config.Cloak
local AR = Config.Armor

local COLLIDERS = {
	"UpperTorso", "LowerTorso",
	"LeftThighP", "LeftThighD", "LeftShinP", "LeftShinD",
	"RightThighP", "RightThighD", "RightShinP", "RightShinD",
}

local capes = {} -- active cape records
local extraColliders = setmetatable({}, { __mode = "k" }) -- model -> { parts } (a bag)
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
local function pinLocal(cape, c)
	local st = cape.Style
	local half = cape.Upper.Size * 0.5
	local x = (c - 1) / (st.Cols - 1) - 0.5
	return Vector3.new(cape.X + x * st.TopWidth, half.Y - 0.02, half.Z + CL.BodyMargin)
end

-- hang the cloth straight down behind the shoulders
local function reset(cape)
	local st = cape.Style
	local cf = cape.Upper.CFrame
	local dy = st.Length / (st.Rows - 1)
	for r = 1, st.Rows do
		for c = 1, st.Cols do
			local top = pinLocal(cape, c)
			local p = cf:PointToWorldSpace(top) - Vector3.new(0, (r - 1) * dy, 0)
			cape.Pos[r][c] = p
			cape.Prev[r][c] = p
		end
	end
	cape.LastPin = cape.Pos[1][1]
end

local function restWidth(st, r)
	local t = (r - 1) / (st.Rows - 1)
	return (st.TopWidth + (st.BottomWidth - st.TopWidth) * t) / (st.Cols - 1)
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

local function step(cape, dt, floorY, windVel)
	local st = cape.Style
	local pos, prev = cape.Pos, cape.Prev
	local gravity = Vector3.new(0, -workspace.Gravity * CL.GravityScale, 0)
	local gust = 1 + CL.Gust * math.sin(clock * 0.8 + cape.Phase)
	for r = 2, st.Rows do
		for c = 1, st.Cols do
			local p = pos[r][c]
			local v = (p - prev[r][c]) / dt
			local flutter = 1 + CL.Flutter * math.sin(clock * 3.1 + r * 0.9 + c * 1.7 + cape.Phase)
			local wind = windVel * gust * flutter
			local a = gravity + (wind - v) * CL.Drag
			prev[r][c] = p
			pos[r][c] = p + v * dt + a * dt * dt
		end
	end

	local upper = cape.Upper
	for c = 1, st.Cols do
		pos[1][c] = upper.CFrame:PointToWorldSpace(pinLocal(cape, c))
	end

	local dy = st.Length / (st.Rows - 1)
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
		for r = 1, st.Rows do
			local w = restWidth(st, r)
			for c = 1, st.Cols do
				if c < st.Cols and r > 1 then
					satisfy(r, c, r, c + 1, w)
				end
				if r < st.Rows then
					satisfy(r, c, r + 1, c, dy)
				end
			end
		end
	end

	local extra = extraColliders[cape.Model]
	for r = 2, st.Rows do
		for c = 1, st.Cols do
			local p = pos[r][c]
			for _, part in ipairs(cape.Colliders) do
				if part.Parent == cape.Model then
					p = pushOutOfBox(p, part)
				end
			end
			if extra then
				for _, part in ipairs(extra) do
					if part.Parent then
						p = pushOutOfBox(p, part)
					end
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
	local st = cape.Style
	local pos = cape.Pos
	local i = 0
	for r = 1, st.Rows - 1 do
		for c = 1, st.Cols - 1 do
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

-- move a viewport cape's panels straight to their frames
local function place(parts, cframes)
	for k, part in ipairs(parts) do
		part.CFrame = cframes[k]
	end
end

local function update(dt)
	clock += dt
	local camera = workspace.CurrentCamera
	local camPos = camera and camera.CFrame.Position or Vector3.zero
	local parts, cframes = {}, {}
	local windVel = Wind.Velocity()
	for i = #capes, 1, -1 do
		local cape = capes[i]
		local upper = cape.Upper
		if not cape.Panels[1].Parent or upper.Parent ~= cape.Model or not cape.Model.Parent then
			table.remove(capes, i)
			continue
		end
		local direct = cape.Wind ~= nil
		local near = direct or (upper.Position - camPos).Magnitude < CL.SimDistance
		if not near then
			cape.Far = true
			render(cape, false, {}, {})
			continue
		end
		local pin = upper.CFrame:PointToWorldSpace(pinLocal(cape, 1))
		if cape.Far or (pin - cape.LastPin).Magnitude > 8 then
			reset(cape) -- just came into range, or the fighter teleported / respawned
			cape.Far = false
		end
		cape.LastPin = pin

		local floorY
		if not direct then
			local hit = workspace:Raycast(upper.Position, Vector3.new(0, -12, 0), groundParams)
			floorY = hit and hit.Position.Y + CL.Thickness
		end

		cape.Acc = math.min(cape.Acc + dt, CL.Step * 4)
		while cape.Acc >= CL.Step do
			cape.Acc -= CL.Step
			step(cape, CL.Step, floorY, cape.Wind or windVel)
		end
		if direct then
			local own, ownFrames = {}, {}
			render(cape, true, own, ownFrames)
			place(own, ownFrames)
		else
			render(cape, true, parts, cframes)
		end
	end
	if #parts > 0 then
		workspace:BulkMoveTo(parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

-- parts on this fighter (a bag) the cloth is kept out of, as long as they are in the game
function CloakView.AddColliders(model, list)
	local extra = extraColliders[model] or {}
	for i = #extra, 1, -1 do
		if not extra[i].Parent then
			table.remove(extra, i)
		end
	end
	for _, part in ipairs(list) do
		if part:IsA("BasePart") then
			table.insert(extra, part)
		end
	end
	extraColliders[model] = extra
end

-- builds the cloth piece `piece` (a Config.Cloak.Styles key) on this fighter; returns its parts
-- (ArmorView destroys them to take it off)
function CloakView.Build(model, piece, color, folder, opts)
	opts = opts or {}
	local st = CL.Styles[piece] or CL.Styles.Cloak
	local list = {}
	local neck = model:FindFirstChild("Neck")
	local upper = model:FindFirstChild("UpperTorso")
	if not (upper and upper:IsA("BasePart")) then
		return list
	end
	local inflate = AR.Inflate

	if st.Collar > 0 and neck and neck:IsA("BasePart") then
		local d = math.max(neck.Size.X, neck.Size.Z) + inflate * (piece == "Scarf" and 5 or 3)
		local collar = plain("Cloak_Collar", Vector3.new(neck.Size.Y * st.Collar, d, d), color, Enum.Material.Fabric)
		collar.Shape = Enum.PartType.Cylinder -- along X: turned upright around the neck
		collar.CFrame = neck.CFrame * CFrame.new(0, -neck.Size.Y * 0.2, 0) * CFrame.Angles(0, 0, math.pi / 2)
		table.insert(list, weldTo(neck, collar, folder))
		if piece == "Scarf" then
			-- the knot at the back of the neck the tails hang from
			local knot = plain("Cloak_Knot", Vector3.one * (d * 0.45), color, Enum.Material.Fabric)
			knot.Shape = Enum.PartType.Ball
			knot.CFrame = neck.CFrame * CFrame.new(0, -neck.Size.Y * 0.35, d * 0.45)
			table.insert(list, weldTo(neck, knot, folder))
		end
	end

	local half = upper.Size * 0.5
	if st.Mantle > 0 then
		local mantle = plain("Cloak_Mantle", Vector3.new(upper.Size.X + inflate * 5, upper.Size.Y * st.Mantle, upper.Size.Z + inflate * 5), color, Enum.Material.Fabric)
		mantle.CFrame = upper.CFrame * CFrame.new(0, half.Y - mantle.Size.Y * 0.4, 0)
		table.insert(list, weldTo(upper, mantle, folder))
	end

	if st.Clasp then
		local clasp = plain("Cloak_Clasp", Vector3.one * (upper.Size.X * 0.11), CL.ClaspColor, Enum.Material.Metal)
		clasp.Shape = Enum.PartType.Ball
		clasp.CFrame = upper.CFrame * CFrame.new(0, half.Y - clasp.Size.Y * 0.6, -half.Z - inflate * 2.5)
		table.insert(list, weldTo(upper, clasp, folder))
	end

	local colliders = {}
	for _, name in ipairs(COLLIDERS) do
		local part = model:FindFirstChild(name)
		if part and part:IsA("BasePart") then
			table.insert(colliders, part)
		end
	end
	for _, x in ipairs(st.Strips or { 0 }) do
		local cape = {
			Model = model,
			Upper = upper,
			Style = st,
			X = x,
			Panels = {},
			Colliders = colliders,
			Pos = {},
			Prev = {},
			Acc = 0,
			Phase = math.random() * 10,
			Far = false,
			Wind = opts.Wind,
		}
		for r = 1, st.Rows do
			cape.Pos[r], cape.Prev[r] = {}, {}
		end
		for _ = 1, (st.Rows - 1) * (st.Cols - 1) do
			local panel = plain("Cloak_Cape", Vector3.one * 0.1, color, Enum.Material.Fabric)
			panel.Anchored = true
			panel.CFrame = upper.CFrame
			panel.Parent = folder
			table.insert(cape.Panels, panel)
			table.insert(list, panel)
		end
		reset(cape)
		if opts.Static then
			-- let it fall into a drape in a light breeze from the front, then leave it
			local breeze = upper.CFrame:VectorToWorldSpace(Vector3.new(0, 0, 3))
			for _ = 1, 90 do
				step(cape, CL.Step, nil, breeze)
			end
			local parts, cframes = {}, {}
			render(cape, true, parts, cframes)
			place(parts, cframes)
		else
			table.insert(capes, cape)
		end
	end
	return list
end

function CloakView.Init(_ctx)
	RunService.RenderStepped:Connect(update)
end

return CloakView
