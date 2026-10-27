--[[
	GearView: the clothing that is neither plates (ArmorView shells) nor cloth (CloakView), built
	from a few parts welded to the body (Config.Armor.Pieces, by View):
	  Kasa     a wide, shallow straw cone on the head, tipped a little forward
	  Satchel  a small bag on the lower back, its strap across the chest
	  Pack     a framed pack on the upper back with a rolled blanket on top and two shoulder straps
	  Waraji   straw soles under the feet, bands over the toes and a tie at each ankle
	Build returns the parts (ArmorView destroys them to take the piece off). Bags are also given
	to CloakView as colliders, so a cape drapes over them.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage:WaitForChild("RagdollRonin"):WaitForChild("Config"))

local GearView = {}

local function part(name, size, color, material, shape)
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Color = color
	p.Material = material or Enum.Material.Fabric
	if shape then
		p.Shape = shape
	end
	p.Massless = true
	p.CanCollide, p.CanQuery, p.CanTouch, p.CastShadow = false, false, false, false
	return p
end

local function weld(list, folder, base, p, cf)
	p.CFrame = base.CFrame * cf
	local w = Instance.new("WeldConstraint")
	w.Part0 = base
	w.Part1 = p
	w.Parent = p
	p.Parent = folder
	table.insert(list, p)
	return p
end

local UPRIGHT = CFrame.Angles(0, 0, math.pi / 2) -- a cylinder's axis (X) turned to Y

local builders = {}

function builders.Kasa(model, color, folder, list)
	local head = model:FindFirstChild("Head")
	if not head then
		return
	end
	local w = math.max(head.Size.X, head.Size.Z)
	local base = CFrame.new(0, head.Size.Y * 0.25, 0) * CFrame.Angles(math.rad(-6), 0, 0)
	-- stacked discs, wide at the brim to narrow at the top: a shallow cone, full enough low down
	-- to keep the corners of the head inside it
	local discs = 8
	local rise = 0.45 * w
	for i = 0, discs - 1 do
		local t = i / (discs - 1)
		local d = w * (2.4 - 1.8 * t * t)
		local disc = part("Kasa_" .. i, Vector3.new(rise / discs + 0.01, d, d), i % 2 == 0 and color or color:Lerp(Color3.new(0, 0, 0), 0.08), Enum.Material.Fabric, Enum.PartType.Cylinder)
		weld(list, folder, head, disc, base * CFrame.new(0, t * rise, 0) * UPRIGHT)
	end
	local knob = part("Kasa_Top", Vector3.one * (w * 0.2), color:Lerp(Color3.new(0, 0, 0), 0.25), Enum.Material.Fabric, Enum.PartType.Ball)
	weld(list, folder, head, knob, base * CFrame.new(0, rise + w * 0.02, 0))
	-- a cord under the chin
	local cord = part("Kasa_Cord", Vector3.new(head.Size.X * 1.04, w * 0.05, w * 0.05), Color3.fromRGB(60, 40, 30))
	weld(list, folder, head, cord, CFrame.new(0, -head.Size.Y * 0.38, -head.Size.Z * 0.18) * CFrame.Angles(math.rad(-25), 0, 0))
end

local function strap(list, folder, upper, x0, y0, x1, y1, z, color, width)
	local d = Vector3.new(x1 - x0, y1 - y0, 0)
	local s = part("Strap", Vector3.new(width, d.Magnitude, 0.05), color)
	local angle = math.atan2(-d.X, d.Y)
	weld(list, folder, upper, s, CFrame.new((x0 + x1) / 2, (y0 + y1) / 2, z) * CFrame.Angles(0, 0, angle))
end

function builders.Satchel(model, color, folder, list)
	local upper = model:FindFirstChild("UpperTorso")
	if not upper then
		return
	end
	local h = upper.Size * 0.5
	local dark = color:Lerp(Color3.new(0, 0, 0), 0.3)
	local size = Vector3.new(upper.Size.X * 0.42, upper.Size.Y * 0.42, upper.Size.Z * 0.32)
	local cf = CFrame.new(h.X * 0.35, -h.Y * 0.62, h.Z + size.Z / 2 + 0.02)
	local bag = weld(list, folder, upper, part("Satchel", size, color, Enum.Material.Leather), cf)
	weld(list, folder, upper, part("Satchel_Flap", Vector3.new(size.X * 1.04, size.Y * 0.5, 0.05), dark, Enum.Material.Leather),
		cf * CFrame.new(0, size.Y * 0.27, size.Z / 2 + 0.01))
	weld(list, folder, upper, part("Satchel_Buckle", Vector3.new(size.X * 0.16, size.Y * 0.16, 0.06), Config.Cloak.ClaspColor, Enum.Material.Metal),
		cf * CFrame.new(0, size.Y * 0.04, size.Z / 2 + 0.04))
	-- the strap from the left shoulder down across the chest and the back to the bag's side
	strap(list, folder, upper, -h.X * 0.7, h.Y, h.X * 0.75, -h.Y * 0.6, -h.Z - 0.04, dark, upper.Size.X * 0.07)
	strap(list, folder, upper, -h.X * 0.7, h.Y, h.X * 0.15, -h.Y * 0.4, h.Z + 0.04, dark, upper.Size.X * 0.07)
	return { bag }
end

function builders.Pack(model, color, folder, list)
	local upper = model:FindFirstChild("UpperTorso")
	if not upper then
		return
	end
	local h = upper.Size * 0.5
	local dark = color:Lerp(Color3.new(0, 0, 0), 0.35)
	local size = Vector3.new(upper.Size.X * 0.72, upper.Size.Y * 0.95, upper.Size.Z * 0.5)
	local cf = CFrame.new(0, -h.Y * 0.05, h.Z + size.Z / 2 + 0.03)
	local body = weld(list, folder, upper, part("Pack", size, color, Enum.Material.Fabric), cf)
	weld(list, folder, upper, part("Pack_Pocket", Vector3.new(size.X * 0.7, size.Y * 0.38, size.Z * 0.3), dark, Enum.Material.Fabric),
		cf * CFrame.new(0, -size.Y * 0.2, size.Z / 2 + size.Z * 0.14))
	-- wooden frame rails at the sides
	for _, sx in ipairs({ -1, 1 }) do
		weld(list, folder, upper, part("Pack_Rail", Vector3.new(0.07, size.Y * 1.12, 0.07), Color3.fromRGB(96, 66, 40), Enum.Material.Wood),
			cf * CFrame.new(sx * (size.X / 2 + 0.04), size.Y * 0.04, size.Z * 0.2))
	end
	-- the rolled blanket across the top
	local roll = weld(list, folder, upper, part("Pack_Roll", Vector3.new(size.X * 1.25, size.Z * 0.75, size.Z * 0.75), Color3.fromRGB(150, 128, 98), Enum.Material.Fabric, Enum.PartType.Cylinder),
		cf * CFrame.new(0, size.Y / 2 + size.Z * 0.3, 0))
	-- shoulder straps down the front of the chest
	for _, sx in ipairs({ -1, 1 }) do
		strap(list, folder, upper, sx * h.X * 0.42, h.Y, sx * h.X * 0.5, -h.Y * 0.55, -h.Z - 0.04, dark, upper.Size.X * 0.08)
	end
	return { body, roll }
end

function builders.Waraji(model, color, folder, list)
	local cord = Color3.fromRGB(90, 62, 40)
	for _, side in ipairs({ "Left", "Right" }) do
		local foot = model:FindFirstChild(side .. "Foot")
		if foot then
			local f = foot.Size
			weld(list, folder, foot, part("Waraji_Sole", Vector3.new(f.X * 1.08, f.Y * 0.22, f.Z * 1.06), color, Enum.Material.Fabric),
				CFrame.new(0, -f.Y * 0.45, 0)) -- wrapped round the bottom of the foot, barely below it
			for _, z in ipairs({ -0.3, 0.05 }) do
				weld(list, folder, foot, part("Waraji_Band", Vector3.new(f.X * 1.06, f.Y * 0.2, f.Z * 0.09), cord),
					CFrame.new(0, f.Y * 0.1, z * f.Z) * CFrame.Angles(math.rad(-12), 0, 0))
			end
		end
		local shin = model:FindFirstChild(side .. "ShinD")
		if shin then
			local s = shin.Size
			weld(list, folder, shin, part("Waraji_Tie", Vector3.new(s.X * 1.1, s.Y * 0.08, s.Z * 1.1), cord),
				CFrame.new(0, -s.Y * 0.4, 0))
		end
	end
end

-- builds the piece's look on this fighter; returns its parts and, for a bag, the parts a cape
-- should stay out of
function GearView.Build(view, model, color, folder)
	local list = {}
	local builder = builders[view]
	local colliders = builder and builder(model, color, folder, list)
	return list, colliders
end

function GearView.Has(view)
	return builders[view] ~= nil
end

return GearView
