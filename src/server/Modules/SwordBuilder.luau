--[[
	SwordBuilder: a functional katana.

	Sword frame convention (shared with hit detection and aim):
	  +Y  blade axis, toward the tip
	  +X  cutting-edge direction (the spine faces -X)
	  +Z  flat of the blade
	The grip attachment "GripAtt" on the handle uses this frame, and is welded to the hand's
	"SwordGrip" attachment (the grip joint). The off hand pulls toward "OffGripAtt".
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.RagdollRonin.Config)

local SwordBuilder = {}

local function mk(model, name, size, cf, color, material, shape)
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	if shape then
		p.Shape = shape
	end
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	p.CastShadow = false
	p.CollisionGroup = "RR_Sword"
	p.CustomPhysicalProperties = PhysicalProperties.new(Config.Physics.SwordDensity, 0.3, 0, 1, 1)
	p.Parent = model
	return p
end

local function weld(a, b)
	local w = Instance.new("WeldConstraint")
	w.Part0 = a
	w.Part1 = b
	w.Parent = a
	return w
end

-- gripCF: world frame (sword convention) where the right hand holds the sword
function SwordBuilder.Build(gripCF)
	local C = Config.Sword
	local model = Instance.new("Model")
	model.Name = "Katana"

	local HL, BL = C.HandleLength, C.BladeLength
	local handleCF = gripCF * CFrame.new(0, -0.25 * HL, 0)
	local handle = mk(model, "Handle", Vector3.new(C.HandleWidth, HL, C.HandleWidth * 0.8), handleCF, Color3.fromRGB(30, 24, 22), Enum.Material.Fabric)
	-- tsuba (cylinder axis is local X, rotate so it lies across the blade axis)
	local guardCF = handleCF * CFrame.new(0, HL / 2 + C.GuardThickness / 2, 0) * CFrame.Angles(0, 0, math.pi / 2)
	local guard = mk(model, "Tsuba", Vector3.new(C.GuardThickness, C.GuardDiameter, C.GuardDiameter), guardCF, Color3.fromRGB(70, 58, 30), Enum.Material.Metal, Enum.PartType.Cylinder)
	local bladeCF = handleCF * CFrame.new(0, HL / 2 + C.GuardThickness + BL / 2, 0)
	local blade = mk(model, "Blade", Vector3.new(C.BladeWidth, BL, C.BladeThickness), bladeCF, Color3.fromRGB(150, 156, 166), Enum.Material.Metal)
	blade.CanQuery = true -- blade-on-blade contacts (clashes) are found by sweeps
	blade:SetAttribute("SwordPart", "Blade")
	-- hamon / cutting edge strip on the +X side so the edge direction is readable
	local edge = mk(model, "Edge", Vector3.new(C.BladeWidth * 0.22, BL * 0.98, C.BladeThickness * 1.08), bladeCF * CFrame.new(C.BladeWidth * 0.4, -BL * 0.01, 0), Color3.fromRGB(235, 238, 242), Enum.Material.SmoothPlastic)
	-- tip wedge (cosmetic)
	local tip = Instance.new("WedgePart")
	tip.Name = "Kissaki"
	local tipLen = C.BladeWidth * 1.6
	tip.Size = Vector3.new(C.BladeThickness, C.BladeWidth, tipLen)
	-- wedge local: -Z is the point, -Y the flat (spine) side. Map wedge Z -> -blade Y, wedge Y -> blade X (edge)
	tip.CFrame = bladeCF * CFrame.new(0, BL / 2 + tipLen / 2, 0)
		* CFrame.fromMatrix(Vector3.zero, Vector3.new(0, 0, -1), Vector3.new(1, 0, 0), Vector3.new(0, -1, 0))
	tip.Color = blade.Color
	tip.Material = Enum.Material.Metal
	tip.CanCollide, tip.CanTouch, tip.CanQuery, tip.CastShadow = false, false, false, false
	tip.CollisionGroup = "RR_Sword"
	tip.CustomPhysicalProperties = PhysicalProperties.new(Config.Physics.SwordDensity, 0.3, 0, 1, 1)
	tip.Parent = model
	-- invisible guard-interception volume, queryable only while the owner is blocking
	local zone = mk(model, "ParryZone", Vector3.new(C.ParryZoneWidth, BL, C.ParryZoneWidth), bladeCF, Color3.new(0.3, 0.6, 1))
	zone.Transparency = 1
	zone.Massless = true
	zone:SetAttribute("SwordPart", "Guard")
	-- solid blade volume (pommel to tip) that collides ONLY with other fighters' colliders, so
	-- swords physically stop each other where they meet instead of passing through. Slightly
	-- fatter than the visual blade so fast blades cannot tunnel through each other in one step.
	local pad = C.ColliderPadding
	local reachLen = HL + C.GuardThickness + BL
	local collider = mk(model, "BladeCollider", Vector3.new(C.BladeWidth + pad * 2, reachLen, C.BladeThickness + pad * 2),
		handleCF * CFrame.new(0, reachLen / 2 - HL / 2, 0), Color3.new(1, 0.4, 0.2))
	collider.Transparency = 1
	collider.Massless = true
	collider.CanCollide = true
	collider.CollisionGroup = "RR_Blade"
	collider.CustomPhysicalProperties = PhysicalProperties.new(Config.Physics.SwordDensity, C.ColliderFriction, 0, 1, 1)

	for _, p in ipairs({ guard, blade, edge, tip, zone, collider }) do
		weld(handle, p)
	end

	local gripAtt = Instance.new("Attachment")
	gripAtt.Name = "GripAtt"
	gripAtt.CFrame = CFrame.new(0, 0.25 * HL, 0)
	gripAtt.Parent = handle
	local offGrip = Instance.new("Attachment")
	offGrip.Name = "OffGripAtt"
	offGrip.CFrame = CFrame.new(0, -0.3 * HL, 0)
	offGrip.Parent = handle

	model.PrimaryPart = handle
	return {
		Model = model,
		Handle = handle,
		Blade = blade,
		ParryZone = zone,
		Collider = collider,
		GripAtt = gripAtt,
		OffGripAtt = offGrip,
		TipLocal = Vector3.new(0, BL / 2, 0),
	}
end

-- Blade-local sample points from near the guard to the tip, biased to the edge side
function SwordBuilder.SamplePoints()
	local C = Config.Sword
	local pts = {}
	local y0, y1 = -C.BladeLength / 2 + 0.12, C.BladeLength / 2
	for k = 0, C.SampleCount - 1 do
		local t = k / (C.SampleCount - 1)
		table.insert(pts, Vector3.new(C.BladeWidth * 0.3, y0 + (y1 - y0) * t, 0))
	end
	return pts
end

return SwordBuilder
