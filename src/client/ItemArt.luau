--[[
	ItemArt: the 3D pictures in the menus, each a ViewportFrame.
	  Icon(key)       an item on its own (Config.Items): wearables are built by ArmorView.BuildPiece
	                  on an invisible figure and framed by their bounds, books are modelled here.
	                  Made once per item and cloned.
	  Figure(colors)  the rest-pose body (Shared.Anatomy) for the inventory to dress
	  Katana()        the sword (Config.Sword, as SwordBuilder builds it) lying along +Y
	  Viewport()      an empty ViewportFrame with a WorldModel and a Camera, lit for the menus
	  Frame(vf, parts, yaw, pitch, fill)  point the camera at parts from that direction
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("RagdollRonin")
local Config = require(Shared:WaitForChild("Config"))
local Anatomy = require(Shared:WaitForChild("Anatomy"))
local ArmorView = require(script.Parent.ArmorView)

local ItemArt = {}
local S = Config.Scale
local IT = Config.Items

-- the direction each icon is seen from (degrees around the figure, 0 = from the front)
local ICON_YAW = { Cloak = 160, Cape = 160, Scarf = 135, Satchel = 145, TravelPack = 150 }

local templates = {}

function ItemArt.Viewport(props)
	local vf = Instance.new("ViewportFrame")
	vf.BackgroundTransparency = 1
	vf.Ambient = Color3.fromRGB(150, 140, 135)
	vf.LightColor = Color3.fromRGB(255, 244, 228)
	vf.LightDirection = Vector3.new(-0.6, -1, -0.8)
	for k, v in pairs(props or {}) do
		vf[k] = v
	end
	local world = Instance.new("WorldModel")
	world.Parent = vf
	local cam = Instance.new("Camera")
	cam.FieldOfView = 30
	cam.Parent = vf
	vf.CurrentCamera = cam
	return vf, world, cam
end

local function bounds(parts)
	local lo, hi = Vector3.one * math.huge, -Vector3.one * math.huge
	for _, p in ipairs(parts) do
		if p:IsA("BasePart") and p.Transparency < 1 then
			local h = p.Size * 0.5
			for _, c in ipairs({
				Vector3.new(h.X, h.Y, h.Z), Vector3.new(-h.X, h.Y, h.Z), Vector3.new(h.X, -h.Y, h.Z), Vector3.new(h.X, h.Y, -h.Z),
				Vector3.new(-h.X, -h.Y, h.Z), Vector3.new(-h.X, h.Y, -h.Z), Vector3.new(h.X, -h.Y, -h.Z), -h,
			}) do
				local w = p.CFrame:PointToWorldSpace(c)
				lo, hi = lo:Min(w), hi:Max(w)
			end
		end
	end
	return (lo + hi) * 0.5, (hi - lo).Magnitude * 0.5
end

-- camera on a sphere around the parts' bounds: yaw 0 looks at the figure's front (it faces -Z)
function ItemArt.Frame(vf, parts, yaw, pitch, fill)
	local cam = vf.CurrentCamera
	local center, radius = bounds(parts)
	if radius ~= radius or radius == math.huge then
		return
	end
	local dir = CFrame.Angles(0, math.rad(yaw or 25), 0) * CFrame.Angles(math.rad(pitch or 12), 0, 0) * Vector3.new(0, 0, -1)
	local dist = radius / math.sin(math.rad(cam.FieldOfView / 2)) * (fill or 1)
	cam.CFrame = CFrame.lookAt(center + dir * dist, center)
	return center, dist
end

-- the body at rest, pelvis at the origin, facing -Z; colors: part name -> Color3 (else Anatomy's)
function ItemArt.Figure(colors)
	local model = Instance.new("Model")
	model.Name = "Figure"
	for _, def in ipairs(Anatomy.Parts) do
		local p = Instance.new("Part")
		p.Name = def.Name
		p.Size = def.Size * S
		p.CFrame = CFrame.new(def.Center * S)
		p.Color = (colors and colors[def.Name]) or Anatomy.Colors[def.Color] or Color3.new(0.5, 0.5, 0.5)
		p.Material = def.Color == "Skin" and Enum.Material.SmoothPlastic or Enum.Material.Fabric
		p.Anchored = true
		p.CanCollide, p.CanQuery, p.CanTouch = false, false, false
		p.TopSurface, p.BottomSurface = Enum.SurfaceType.Smooth, Enum.SurfaceType.Smooth
		p.Parent = model
	end
	local face = Instance.new("Decal")
	face.Name = "face"
	face.Texture = "rbxasset://textures/face.png"
	face.Face = Enum.NormalId.Front
	face.Parent = model.Head
	model.PrimaryPart = model.LowerTorso
	return model
end

local function mk(parent, name, size, cf, color, material, class)
	local p = Instance.new(class or "Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.Anchored = true
	p.CanCollide, p.CanQuery, p.CanTouch = false, false, false
	p.TopSurface, p.BottomSurface = Enum.SurfaceType.Smooth, Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

-- the katana, handle centre at the origin, blade toward +Y, edge toward +X (SwordBuilder's frame)
function ItemArt.Katana()
	local C = Config.Sword
	local model = Instance.new("Model")
	model.Name = "Katana"
	local HL, BL = C.HandleLength, C.BladeLength
	local handle = mk(model, "Handle", Vector3.new(C.HandleWidth, HL, C.HandleWidth * 0.8), CFrame.new(), Color3.fromRGB(30, 24, 22), Enum.Material.Fabric)
	-- the diamond wrap of the hilt
	for i = 1, 5 do
		mk(model, "Wrap", Vector3.new(C.HandleWidth * 1.08, HL * 0.05, C.HandleWidth * 0.86), CFrame.new(0, -HL / 2 + HL * i / 6, 0) * CFrame.Angles(0, 0, math.rad(i % 2 == 0 and 18 or -18)), Color3.fromRGB(196, 186, 160), Enum.Material.Fabric)
	end
	mk(model, "Kashira", Vector3.new(C.HandleWidth * 1.1, HL * 0.06, C.HandleWidth * 0.9), CFrame.new(0, -HL / 2, 0), Color3.fromRGB(70, 58, 30), Enum.Material.Metal)
	mk(model, "Tsuba", Vector3.new(C.GuardThickness, C.GuardDiameter, C.GuardDiameter), CFrame.new(0, HL / 2 + C.GuardThickness / 2, 0) * CFrame.Angles(0, 0, math.pi / 2), Color3.fromRGB(70, 58, 30), Enum.Material.Metal).Shape = Enum.PartType.Cylinder
	local bladeCF = CFrame.new(0, HL / 2 + C.GuardThickness + BL / 2, 0)
	local blade = mk(model, "Blade", Vector3.new(C.BladeWidth, BL, C.BladeThickness), bladeCF, Color3.fromRGB(150, 156, 166), Enum.Material.Metal)
	local edge = mk(model, "Edge", Vector3.new(C.BladeWidth * 0.22, BL * 0.98, C.BladeThickness * 1.08), bladeCF * CFrame.new(C.BladeWidth * 0.4, -BL * 0.01, 0), Color3.fromRGB(235, 238, 242))
	local tipLen = C.BladeWidth * 1.6
	mk(model, "Kissaki", Vector3.new(C.BladeThickness, C.BladeWidth, tipLen),
		bladeCF * CFrame.new(0, BL / 2 + tipLen / 2, 0) * CFrame.fromMatrix(Vector3.zero, Vector3.new(0, 0, -1), Vector3.new(1, 0, 0), Vector3.new(0, -1, 0)),
		blade.Color, Enum.Material.Metal, "WedgePart")
	model.PrimaryPart = handle
	return model, blade, edge
end

-- a closed book lying on its back, cover toward +Z
local function book(parent, color)
	local w, h, t = 1.0, 1.35, 0.3
	mk(parent, "Cover", Vector3.new(w, h, t), CFrame.new(), color, Enum.Material.Leather)
	mk(parent, "Pages", Vector3.new(w * 0.94, h * 0.94, t * 0.72), CFrame.new(w * 0.05, 0, 0), Color3.fromRGB(230, 218, 190), Enum.Material.SmoothPlastic)
	mk(parent, "Spine", Vector3.new(w * 0.1, h * 1.01, t * 1.06), CFrame.new(-w * 0.47, 0, 0), color:Lerp(Color3.new(0, 0, 0), 0.35), Enum.Material.Leather)
	-- an emblem on the cover: a flame-coloured diamond in a gold ring
	local gold = Config.Cloak.ClaspColor
	mk(parent, "Ring", Vector3.new(0.05, w * 0.5, w * 0.5), CFrame.new(w * 0.04, h * 0.05, t / 2 + 0.01) * CFrame.Angles(0, math.pi / 2, 0), gold, Enum.Material.Metal).Shape = Enum.PartType.Cylinder
	mk(parent, "Gem", Vector3.new(w * 0.24, w * 0.24, 0.06), CFrame.new(w * 0.04, h * 0.05, t / 2 + 0.04) * CFrame.Angles(0, 0, math.rad(45)), Color3.fromRGB(255, 150, 60), Enum.Material.Neon)
	for _, y in ipairs({ -0.38, 0.42 }) do
		mk(parent, "Band", Vector3.new(w * 1.01, 0.05, t * 1.04), CFrame.new(0, h * y, 0), gold, Enum.Material.Metal)
	end
end

local function buildIcon(key)
	local def = IT[key]
	local vf, world = ItemArt.Viewport({ Size = UDim2.fromScale(1, 1) })
	if def.Kind == "Book" then
		local m = Instance.new("Model")
		book(m, def.Color or Color3.fromRGB(120, 40, 30))
		m:PivotTo(CFrame.Angles(math.rad(-20), math.rad(25), math.rad(-12)))
		m.Parent = world
		ItemArt.Frame(vf, m:GetChildren(), 180, 0, 1.0) -- from +Z: the cover
		return vf
	end
	-- built on an invisible figure, so it sits as it does when worn
	local figure = ItemArt.Figure()
	for _, p in ipairs(figure:GetChildren()) do
		if p:IsA("BasePart") then
			p.Transparency = 1
		end
	end
	figure.Head.face:Destroy()
	figure.Parent = world
	local body = figure:GetChildren()
	local parts = ArmorView.BuildPiece(figure, key, figure, { Static = true })
	ItemArt.Frame(vf, parts, ICON_YAW[key] or 25, 14, 0.92)
	-- the body was only there to build on: the icon (cloned for every cell) keeps just the item
	for _, p in ipairs(body) do
		p:Destroy()
	end
	return vf
end

-- a fresh copy of the item's picture (a ViewportFrame filling its parent)
function ItemArt.Icon(key)
	if not IT[key] or key == "Order" then
		return ItemArt.Viewport({ Size = UDim2.fromScale(1, 1) })
	end
	local t = templates[key]
	if not t then
		t = buildIcon(key)
		templates[key] = t
	end
	local vf = t:Clone()
	vf.CurrentCamera = vf:FindFirstChildOfClass("Camera")
	return vf
end

return ItemArt
