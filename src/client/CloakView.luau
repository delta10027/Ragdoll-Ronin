--[[
	CloakView: the cloth pieces' look (Config.Armor.Pieces Cloak, Cape, Scarf and Haori; their
	shapes in Config.Cloak.Styles), built by ArmorView.
	  collar  a band around the neck, welded to the Neck (the Scarf's is a thick wrap)
	  mantle  a layer over the shoulders, welded to the UpperTorso, with a clasp at the front
	  sheets  cloths of Cols x Rows points. The top row is pinned to the body (across the back of
	          the shoulders for a cape; a Haori also down the front and around each upper arm for
	          its sleeves), the rest is simulated here (verlet at a fixed Step): gravity, drag
	          toward the wind (Shared.Sim.Wind, gusting and fluttering along the cloth), distance
	          constraints between neighbours, pushed out of the body's boxes (and a bag's,
	          AddColliders) and kept above the ground. Each cell is drawn as an anchored panel
	          between its corners, in the piece's colours (a trim column, a hem row).
	A style either lists its Sheets (pins on body parts, in units of that part's half size) or
	gives one cape's size and its Strips (x offsets: a Scarf's two tails); its Panels are given
	in unscaled studs from their part's centre.
	Local parts only, like the armour shells. A sheet stops simulating once its parts are gone
	(ArmorView took the piece off, or the fighter left the workspace), and is hidden once a part
	it hangs from is cut off.
	For a figure in a ViewportFrame (the inventory) Build takes opts:
	  Wind    a fixed wind velocity instead of the server's; the cloth is moved directly (not
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

-- the body boxes a sheet is kept out of (a style's Sheets name their own)
local COLLIDERS = {
	Body = {
		"UpperTorso", "LowerTorso",
		"LeftThighP", "LeftThighD", "LeftShinP", "LeftShinD",
		"RightThighP", "RightThighD", "RightShinP", "RightShinD",
	},
	LeftArm = { "UpperTorso", "LeftUpperArmP", "LeftUpperArmD", "LeftForearmP", "LeftForearmD" },
	RightArm = { "UpperTorso", "RightUpperArmP", "RightUpperArmD", "RightForearmP", "RightForearmD" },
}

local capes = {} -- active sheet records
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

local function pinWorld(cape, c)
	local pin = cape.Pins[c]
	return pin.Part.CFrame:PointToWorldSpace(pin.Local)
end

-- hang the cloth straight down from its pins
local function reset(cape)
	for r = 1, cape.Rows do
		for c = 1, cape.Cols do
			local p = pinWorld(cape, c) - Vector3.new(0, (r - 1) * cape.Dy, 0)
			cape.Pos[r][c] = p
			cape.Prev[r][c] = p
		end
	end
	cape.LastPin = cape.Pos[1][1]
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
	local rows, cols = cape.Rows, cape.Cols
	local pos, prev = cape.Pos, cape.Prev
	local gravity = Vector3.new(0, -workspace.Gravity * CL.GravityScale, 0)
	local gust = 1 + CL.Gust * math.sin(clock * 0.8 + cape.Phase)
	for r = 2, rows do
		for c = 1, cols do
			local p = pos[r][c]
			local v = (p - prev[r][c]) / dt
			local flutter = 1 + CL.Flutter * math.sin(clock * 3.1 + r * 0.9 + c * 1.7 + cape.Phase)
			local wind = windVel * gust * flutter
			local a = gravity + (wind - v) * CL.Drag
			prev[r][c] = p
			pos[r][c] = p + v * dt + a * dt * dt
		end
	end

	for c = 1, cols do
		pos[1][c] = pinWorld(cape, c)
	end

	local dy = cape.Dy
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
		for r = 1, rows do
			local widen = 1 + (cape.Flare - 1) * (r - 1) / (rows - 1)
			for c = 1, cols do
				if c < cols and r > 1 then
					satisfy(r, c, r, c + 1, cape.Rest[c] * widen)
				end
				if r < rows then
					satisfy(r, c, r + 1, c, dy)
				end
			end
		end
	end

	local extra = extraColliders[cape.Model]
	for r = 2, rows do
		for c = 1, cols do
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
	local pos = cape.Pos
	local i = 0
	for r = 1, cape.Rows - 1 do
		for c = 1, cape.Cols - 1 do
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

-- move a viewport sheet's panels straight to their frames
local function place(parts, cframes)
	for k, part in ipairs(parts) do
		part.CFrame = cframes[k]
	end
end

local function attached(cape)
	for _, pin in ipairs(cape.Pins) do
		if pin.Part.Parent ~= cape.Model then
			return false
		end
	end
	return true
end

local function update(dt)
	clock += dt
	local camera = workspace.CurrentCamera
	local camPos = camera and camera.CFrame.Position or Vector3.zero
	local parts, cframes = {}, {}
	local windVel = Wind.Velocity()
	for i = #capes, 1, -1 do
		local cape = capes[i]
		if not cape.Panels[1].Parent or not cape.Model.Parent or not attached(cape) then
			-- taken off, gone, or what it hangs from was cut off
			render(cape, false, {}, {})
			table.remove(capes, i)
			continue
		end
		local anchor = cape.Pins[1].Part
		local direct = cape.Wind ~= nil
		local near = direct or (anchor.Position - camPos).Magnitude < CL.SimDistance
		if not near then
			cape.Far = true
			render(cape, false, {}, {})
			continue
		end
		local pin = pinWorld(cape, 1)
		if cape.Far or (pin - cape.LastPin).Magnitude > 8 then
			reset(cape) -- just came into range, or the fighter teleported / respawned
			cape.Far = false
		end
		cape.LastPin = pin

		local floorY
		if not direct then
			local hit = workspace:Raycast(anchor.Position, Vector3.new(0, -12, 0), groundParams)
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

-- the sheets of a style, as { Pins = { { Part, Local } }, Rows, Length, Flare, Colliders, Trim
-- (column), Hem } with the pins on this model's parts
local function sheetsOf(model, st)
	local out = {}
	if st.Sheets then
		for _, sh in ipairs(st.Sheets) do
			local pins = {}
			for _, pin in ipairs(sh.Pins) do
				local part = model:FindFirstChild(pin[1])
				if not (part and part:IsA("BasePart")) then
					pins = nil
					break
				end
				local h = part.Size * 0.5
				table.insert(pins, { Part = part, Local = Vector3.new(h.X * pin[2].X, h.Y * pin[2].Y, h.Z * pin[2].Z) })
			end
			if pins then
				table.insert(out, { Pins = pins, Rows = sh.Rows, Length = sh.Length, Flare = sh.Flare or 1, Colliders = sh.Colliders or "Body", Trim = sh.Trim, Hem = sh.Hem })
			end
		end
		return out
	end
	-- a cape across the back of the shoulders (one per strip)
	local upper = model:FindFirstChild("UpperTorso")
	local half = upper.Size * 0.5
	for _, x in ipairs(st.Strips or { 0 }) do
		local pins = {}
		for c = 1, st.Cols do
			local u = (c - 1) / (st.Cols - 1) - 0.5
			table.insert(pins, { Part = upper, Local = Vector3.new(x + u * st.TopWidth, half.Y - 0.02, half.Z + CL.BodyMargin) })
		end
		table.insert(out, { Pins = pins, Rows = st.Rows, Length = st.Length, Flare = st.BottomWidth / st.TopWidth, Colliders = "Body" })
	end
	return out
end

-- builds the cloth piece `piece` (a Config.Cloak.Styles key) on this fighter in the piece's
-- colours ({ Main, Trim, Accent }); returns its parts (ArmorView destroys them to take it off)
function CloakView.Build(model, piece, colors, folder, opts)
	opts = opts or {}
	local st = CL.Styles[piece] or CL.Styles.Cloak
	local main = colors.Main
	local list = {}
	local neck = model:FindFirstChild("Neck")
	local upper = model:FindFirstChild("UpperTorso")
	if not (upper and upper:IsA("BasePart")) then
		return list
	end
	local inflate = AR.Inflate

	if st.Collar > 0 and neck and neck:IsA("BasePart") then
		local d = math.max(neck.Size.X, neck.Size.Z) + inflate * (piece == "Scarf" and 5 or 3)
		local collar = plain("Cloak_Collar", Vector3.new(neck.Size.Y * st.Collar, d, d), colors[st.CollarColor or "Main"] or main, Enum.Material.Fabric)
		collar.Shape = Enum.PartType.Cylinder -- along X: turned upright around the neck
		collar.CFrame = neck.CFrame * CFrame.new(0, -neck.Size.Y * 0.2, 0) * CFrame.Angles(0, 0, math.pi / 2)
		table.insert(list, weldTo(neck, collar, folder))
		if piece == "Scarf" then
			-- the knot at the back of the neck the tails hang from
			local knot = plain("Cloak_Knot", Vector3.one * (d * 0.45), main, Enum.Material.Fabric)
			knot.Shape = Enum.PartType.Ball
			knot.CFrame = neck.CFrame * CFrame.new(0, -neck.Size.Y * 0.35, d * 0.45)
			table.insert(list, weldTo(neck, knot, folder))
		end
	end

	local half = upper.Size * 0.5
	if st.Mantle > 0 then
		local mantle = plain("Cloak_Mantle", Vector3.new(upper.Size.X + inflate * 5, upper.Size.Y * st.Mantle, upper.Size.Z + inflate * 5), main, Enum.Material.Fabric)
		mantle.CFrame = upper.CFrame * CFrame.new(0, half.Y - mantle.Size.Y * 0.4, 0)
		table.insert(list, weldTo(upper, mantle, folder))
	end

	if st.Clasp then
		local clasp = plain("Cloak_Clasp", Vector3.one * (upper.Size.X * 0.11), CL.ClaspColor, Enum.Material.Metal)
		clasp.Shape = Enum.PartType.Ball
		clasp.CFrame = upper.CFrame * CFrame.new(0, half.Y - clasp.Size.Y * 0.6, -half.Z - inflate * 2.5)
		table.insert(list, weldTo(upper, clasp, folder))
	end

	if st.Himo then
		-- the haori's cord, tied across the chest between the two fronts, with a knot
		local accent = colors.Accent or main
		local z = -half.Z - 0.2 * Config.Scale -- over the front panels
		local y = half.Y * 0.15
		for _, sx in ipairs({ -1, 1 }) do
			local cord = plain("Haori_Himo", Vector3.new(half.X * 0.3, upper.Size.Y * 0.035, 0.05), accent, Enum.Material.Fabric)
			cord.CFrame = upper.CFrame * CFrame.new(sx * half.X * 0.15, y, z) * CFrame.Angles(0, 0, sx * math.rad(-12))
			table.insert(list, weldTo(upper, cord, folder))
		end
		local knot = plain("Haori_Knot", Vector3.one * (upper.Size.X * 0.07), accent, Enum.Material.Fabric)
		knot.Shape = Enum.PartType.Ball
		knot.CFrame = upper.CFrame * CFrame.new(0, y - upper.Size.Y * 0.01, z)
		table.insert(list, weldTo(upper, knot, folder))
		for _, sx in ipairs({ -1, 1 }) do
			local tassel = plain("Haori_Tassel", Vector3.new(0.05, upper.Size.Y * 0.14, 0.05), accent, Enum.Material.Fabric)
			tassel.CFrame = upper.CFrame * CFrame.new(sx * upper.Size.X * 0.025, y - upper.Size.Y * 0.08, z) * CFrame.Angles(0, 0, sx * math.rad(10))
			table.insert(list, weldTo(upper, tassel, folder))
		end
	end

	for _, pa in ipairs(st.Panels or {}) do
		local part = model:FindFirstChild(pa[1])
		if part and part:IsA("BasePart") then
			local panel = plain("Cloak_Panel", pa[3] * Config.Scale, colors[pa[4]] or main, Enum.Material.Fabric)
			panel.CFrame = part.CFrame * CFrame.new(pa[2] * Config.Scale)
			table.insert(list, weldTo(part, panel, folder))
		end
	end

	for _, sh in ipairs(sheetsOf(model, st)) do
		local cols, rows = #sh.Pins, sh.Rows
		local colliders = {}
		for _, name in ipairs(COLLIDERS[sh.Colliders] or COLLIDERS.Body) do
			local part = model:FindFirstChild(name)
			if part and part:IsA("BasePart") then
				table.insert(colliders, part)
			end
		end
		local cape = {
			Model = model,
			Pins = sh.Pins,
			Rows = rows,
			Cols = cols,
			Dy = sh.Length / (rows - 1),
			Flare = sh.Flare,
			Rest = {},
			Panels = {},
			Colliders = colliders,
			Pos = {},
			Prev = {},
			Acc = 0,
			Phase = math.random() * 10,
			Far = false,
			Wind = opts.Wind,
		}
		for r = 1, rows do
			cape.Pos[r], cape.Prev[r] = {}, {}
		end
		reset(cape)
		-- the cloth's width between its columns, as pinned now
		for c = 1, cols - 1 do
			cape.Rest[c] = (cape.Pos[1][c + 1] - cape.Pos[1][c]).Magnitude
		end
		for r = 1, rows - 1 do
			for c = 1, cols - 1 do
				local color = main
				if sh.Hem and r == rows - 1 then
					color = colors[sh.Hem] or main
				elseif sh.Trim and c == sh.Trim then
					color = colors.Trim or main
				end
				local panel = plain("Cloak_Cape", Vector3.one * 0.1, color, Enum.Material.Fabric)
				panel.Anchored = true
				panel.CFrame = upper.CFrame
				panel.Parent = folder
				table.insert(cape.Panels, panel)
				table.insert(list, panel)
			end
		end
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
