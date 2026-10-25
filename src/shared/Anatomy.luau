--[[
	Ragdoll Ronin - anatomical layout (shared data).

	All dimensions are UNSCALED (multiply by Config.Scale). Rest pose: pelvis (LowerTorso)
	centre at the origin, fighter faces -Z, fighter's right is +X, every part has identity rotation.

	Long limbs are built from two physical sub-parts (P = proximal, D = distal) joined by a
	WeldConstraint. Those welds, and the real joints, are the predefined cut boundaries used by
	dismemberment (Roblox has no runtime mesh slicing, see Dismemberment).
]]

local Anatomy = {}

----------------------------------------------------------------- parts
local parts = {}
local function P(name, segment, size, center, group, color)
	table.insert(parts, { Name = name, Segment = segment, Size = size, Center = center, Group = group, Color = color })
end

P("LowerTorso", "LowerTorso", Vector3.new(1.6, 0.9, 0.9), Vector3.new(0, 0, 0), "Core", "Hakama")
P("UpperTorso", "UpperTorso", Vector3.new(1.9, 1.5, 1.0), Vector3.new(0, 1.2, 0), "Core", "Gi")
P("Neck", "Neck", Vector3.new(0.5, 0.5, 0.5), Vector3.new(0, 2.2, 0), "Core", "Skin")
P("Head", "Head", Vector3.new(1.0, 1.05, 1.0), Vector3.new(0, 2.975, 0), "Core", "Skin")

for _, side in ipairs({ "Right", "Left" }) do
	local sx = side == "Right" and 1 or -1
	local ax = 1.2 * sx
	P(side .. "UpperArmP", side .. "UpperArm", Vector3.new(0.48, 0.625, 0.48), Vector3.new(ax, 1.5875, 0), "Limb", "Gi")
	P(side .. "UpperArmD", side .. "UpperArm", Vector3.new(0.46, 0.625, 0.46), Vector3.new(ax, 0.9625, 0), "Limb", "Gi")
	P(side .. "ForearmP", side .. "Forearm", Vector3.new(0.42, 0.575, 0.42), Vector3.new(ax, 0.3625, 0), "Limb", "Sleeve")
	P(side .. "ForearmD", side .. "Forearm", Vector3.new(0.4, 0.575, 0.4), Vector3.new(ax, -0.2125, 0), "Limb", "Skin")
	P(side .. "Hand", side .. "Hand", Vector3.new(0.38, 0.45, 0.38), Vector3.new(ax, -0.725, 0), "Limb", "Skin")
	local lx = 0.42 * sx
	P(side .. "ThighP", side .. "Thigh", Vector3.new(0.62, 0.75, 0.62), Vector3.new(lx, -0.775, 0), "Limb", "Hakama")
	P(side .. "ThighD", side .. "Thigh", Vector3.new(0.58, 0.75, 0.58), Vector3.new(lx, -1.525, 0), "Limb", "Hakama")
	P(side .. "ShinP", side .. "Shin", Vector3.new(0.52, 0.725, 0.52), Vector3.new(lx, -2.2625, 0), "Limb", "Hakama")
	P(side .. "ShinD", side .. "Shin", Vector3.new(0.48, 0.725, 0.48), Vector3.new(lx, -2.9875, 0), "Limb", "Wrap")
	P(side .. "Foot", side .. "Foot", Vector3.new(0.5, 0.3, 1.0), Vector3.new(lx, -3.5, -0.22), "Limb", "Sandal")
end
Anatomy.Parts = parts

Anatomy.PartByName = {}
for _, p in ipairs(parts) do
	Anatomy.PartByName[p.Name] = p
end

Anatomy.Colors = {
	Skin = Color3.fromRGB(226, 186, 150),
	Gi = Color3.fromRGB(46, 58, 92),
	Sleeve = Color3.fromRGB(40, 50, 80),
	Hakama = Color3.fromRGB(34, 32, 36),
	Wrap = Color3.fromRGB(200, 196, 186),
	Sandal = Color3.fromRGB(92, 70, 48),
}

----------------------------------------------------------------- joints
-- Type: Ball (BallSocket + AlignOrientation drive), Hinge (servo HingeConstraint), Weld (sub-part seam)
-- Axis: limb direction used for BallSocket cone limits.
-- RotSign: +1 if flexing rotates the child positively about +X (elbow), -1 for knees.
-- Severable joints are cut boundaries; StumpBleed is ml/s from the wound left on the body.
local joints = {}
local function J(def)
	table.insert(joints, def)
end

J({ Name = "Waist", Parent = "LowerTorso", Child = "UpperTorso", Pivot = Vector3.new(0, 0.45, 0), Type = "Ball", Axis = "Up", Cone = 40, Twist = 45, DriveClass = "Waist" })
J({ Name = "NeckBase", Parent = "UpperTorso", Child = "Neck", Pivot = Vector3.new(0, 1.95, 0), Type = "Ball", Axis = "Up", Cone = 30, Twist = 50, DriveClass = "Neck", Severable = true, StumpBleed = 600, Label = "neck" })
J({ Name = "NeckHead", Parent = "Neck", Child = "Head", Pivot = Vector3.new(0, 2.45, 0), Type = "Ball", Axis = "Up", Cone = 35, Twist = 60, DriveClass = "Head" })

-- Wrist twist is wide because the rig has no separate forearm roll: it stands in for pronation/supination.
-- Shoulder twist is wide for the same reason (no collarbone or forearm roll either): sword poses need
-- about +-100 degrees of upper-arm rotation, and the arm IK keeps every pose inside these limits.
for _, side in ipairs({ "Right", "Left" }) do
	local sx = side == "Right" and 1 or -1
	local ax, lx = 1.2 * sx, 0.42 * sx
	J({ Name = side .. "Shoulder", Parent = "UpperTorso", Child = side .. "UpperArmP", Pivot = Vector3.new(ax, 1.7, 0), Type = "Ball", Axis = "Down", Cone = 175, Twist = 110, DriveClass = "Shoulder" })
	J({ Name = side .. "UpperArmMid", Parent = side .. "UpperArmP", Child = side .. "UpperArmD", Pivot = Vector3.new(ax, 1.275, 0), Type = "Weld", Severable = true, StumpBleed = 55, Label = "upper arm" })
	J({ Name = side .. "Elbow", Parent = side .. "UpperArmD", Child = side .. "ForearmP", Pivot = Vector3.new(ax, 0.65, 0), Type = "Hinge", RotSign = 1, FlexMin = -5, FlexMax = 150, DriveClass = "Elbow", Severable = true, StumpBleed = 40, Label = "elbow" })
	J({ Name = side .. "ForearmMid", Parent = side .. "ForearmP", Child = side .. "ForearmD", Pivot = Vector3.new(ax, 0.075, 0), Type = "Weld", Severable = true, StumpBleed = 30, Label = "forearm" })
	J({ Name = side .. "Wrist", Parent = side .. "ForearmD", Child = side .. "Hand", Pivot = Vector3.new(ax, -0.5, 0), Type = "Ball", Axis = "Down", Cone = 105, Twist = 165, DriveClass = "Wrist", Severable = true, StumpBleed = 22, Label = "wrist" })
	J({ Name = side .. "Hip", Parent = "LowerTorso", Child = side .. "ThighP", Pivot = Vector3.new(lx, -0.45, 0), Type = "Ball", Axis = "Down", Cone = 115, Twist = 35, DriveClass = "Hip" })
	J({ Name = side .. "ThighMid", Parent = side .. "ThighP", Child = side .. "ThighD", Pivot = Vector3.new(lx, -1.15, 0), Type = "Weld", Severable = true, StumpBleed = 70, Label = "thigh" })
	J({ Name = side .. "Knee", Parent = side .. "ThighD", Child = side .. "ShinP", Pivot = Vector3.new(lx, -1.9, 0), Type = "Hinge", RotSign = -1, FlexMin = -5, FlexMax = 150, DriveClass = "Knee", Severable = true, StumpBleed = 45, Label = "knee" })
	J({ Name = side .. "ShinMid", Parent = side .. "ShinP", Child = side .. "ShinD", Pivot = Vector3.new(lx, -2.625, 0), Type = "Weld", Severable = true, StumpBleed = 35, Label = "shin" })
	J({ Name = side .. "Ankle", Parent = side .. "ShinD", Child = side .. "Foot", Pivot = Vector3.new(lx, -3.35, 0), Type = "Ball", Axis = "Down", Cone = 40, Twist = 15, DriveClass = "Ankle", Severable = true, StumpBleed = 25, Label = "ankle" })
end
Anatomy.Joints = joints
Anatomy.JointByName = {}
for _, j in ipairs(joints) do
	Anatomy.JointByName[j.Name] = j
end

-- Pairs of core parts that must never collide with each other within one fighter
Anatomy.CoreNoCollide = {
	{ "LowerTorso", "UpperTorso" }, { "UpperTorso", "Neck" }, { "Neck", "Head" }, { "UpperTorso", "Head" },
}

----------------------------------------------------------------- segments
-- Resistance: power the outer structure absorbs before the blade penetrates (bone/muscle).
-- SeverPower: cut power (power * cut quality) needed to sever a healthy segment.
-- Boundaries: cut boundaries a strike on this segment may separate (nearest to contact wins).
local seg = {}
seg.Head = { Label = "Head", Region = "Head", Resistance = 3.2, Thickness = 1.0, BleedFactor = 1.0, BalanceClass = "Head" }
seg.Neck = { Label = "Neck", Region = "Neck", Resistance = 1.6, Thickness = 0.5, BleedFactor = 1.6, BalanceClass = "Neck", SeverPower = 6.5, Boundaries = { "NeckBase" } }
seg.UpperTorso = { Label = "Chest", Region = "Torso", Resistance = 2.6, Thickness = 1.0, BleedFactor = 1.1, BalanceClass = "UpperTorso" }
seg.LowerTorso = { Label = "Abdomen", Region = "Torso", Resistance = 2.0, Thickness = 0.9, BleedFactor = 1.0, BalanceClass = "LowerTorso" }
for _, side in ipairs({ "Right", "Left" }) do
	local s = side == "Right" and "R." or "L."
	seg[side .. "UpperArm"] = { Label = s .. "Upper arm", Region = "Arm", Side = side, Resistance = 1.6, Thickness = 0.48, BleedFactor = 0.8, BalanceClass = "Arm", SeverPower = 7.5, Boundaries = { side .. "UpperArmMid", side .. "Elbow" } }
	seg[side .. "Forearm"] = { Label = s .. "Forearm", Region = "Arm", Side = side, Resistance = 1.3, Thickness = 0.42, BleedFactor = 0.7, BalanceClass = "Arm", SeverPower = 6.0, Boundaries = { side .. "Elbow", side .. "ForearmMid", side .. "Wrist" } }
	seg[side .. "Hand"] = { Label = s .. "Hand", Region = "Hand", Side = side, Resistance = 0.9, Thickness = 0.38, BleedFactor = 0.5, BalanceClass = "Hand", SeverPower = 4.2, Boundaries = { side .. "Wrist" } }
	seg[side .. "Thigh"] = { Label = s .. "Thigh", Region = "Leg", Side = side, Resistance = 2.0, Thickness = 0.62, BleedFactor = 1.0, BalanceClass = "Thigh", SeverPower = 9.5, Boundaries = { side .. "ThighMid", side .. "Knee" } }
	seg[side .. "Shin"] = { Label = s .. "Shin", Region = "Leg", Side = side, Resistance = 1.6, Thickness = 0.52, BleedFactor = 0.8, BalanceClass = "Shin", SeverPower = 7.5, Boundaries = { side .. "Knee", side .. "ShinMid", side .. "Ankle" } }
	seg[side .. "Foot"] = { Label = s .. "Foot", Region = "Foot", Side = side, Resistance = 1.0, Thickness = 0.5, BleedFactor = 0.5, BalanceClass = "Foot", SeverPower = 5.0, Boundaries = { side .. "Ankle" } }
end
Anatomy.Segments = seg

Anatomy.SegmentParts = {}
for _, p in ipairs(parts) do
	Anatomy.SegmentParts[p.Segment] = Anatomy.SegmentParts[p.Segment] or {}
	table.insert(Anatomy.SegmentParts[p.Segment], p.Name)
end

----------------------------------------------------------------- organs
-- Logical hit regions (spheres) inside physical parts. Offset is relative to the part centre.
-- BleedRate: ml/s at full destruction (scaled by damage fraction).
-- Lethal: Threshold (health at/below which the rule fires), Delay (s until death, 0 = instant).
Anatomy.Organs = {
	{ Name = "Brain", Label = "Brain", Part = "Head", Segment = "Head", Offset = Vector3.new(0, 0.12, 0.05), Radius = 0.36, BleedRate = 40, Lethal = { Threshold = 40, Delay = 0 } },
	{ Name = "Carotid", Label = "Carotid arteries", Part = "Neck", Segment = "Neck", Offset = Vector3.new(0, 0, -0.08), Radius = 0.18, BleedRate = 320, Vessel = true },
	{ Name = "Heart", Label = "Heart", Part = "UpperTorso", Segment = "UpperTorso", Offset = Vector3.new(-0.18, 0.05, -0.12), Radius = 0.22, BleedRate = 160, Lethal = { Threshold = 30, Delay = 2.5 } },
	{ Name = "LungL", Label = "Left lung", Part = "UpperTorso", Segment = "UpperTorso", Offset = Vector3.new(-0.5, 0.15, 0.02), Radius = 0.32, BleedRate = 30 },
	{ Name = "LungR", Label = "Right lung", Part = "UpperTorso", Segment = "UpperTorso", Offset = Vector3.new(0.5, 0.15, 0.02), Radius = 0.32, BleedRate = 30 },
	{ Name = "Aorta", Label = "Aorta", Part = "UpperTorso", Segment = "UpperTorso", Offset = Vector3.new(-0.05, -0.15, 0.22), Radius = 0.18, BleedRate = 420, Vessel = true },
	{ Name = "Liver", Label = "Liver", Part = "LowerTorso", Segment = "LowerTorso", Offset = Vector3.new(0.38, 0.12, -0.08), Radius = 0.28, BleedRate = 90 },
	{ Name = "Stomach", Label = "Stomach", Part = "LowerTorso", Segment = "LowerTorso", Offset = Vector3.new(-0.32, 0.15, -0.12), Radius = 0.24, BleedRate = 20 },
	{ Name = "Intestines", Label = "Intestines", Part = "LowerTorso", Segment = "LowerTorso", Offset = Vector3.new(0, -0.12, -0.15), Radius = 0.33, BleedRate = 30 },
	{ Name = "FemoralR", Label = "R. femoral artery", Part = "RightThighP", Segment = "RightThigh", Offset = Vector3.new(-0.13, 0, -0.06), Radius = 0.14, BleedRate = 130, Vessel = true },
	{ Name = "FemoralL", Label = "L. femoral artery", Part = "LeftThighP", Segment = "LeftThigh", Offset = Vector3.new(0.13, 0, -0.06), Radius = 0.14, BleedRate = 130, Vessel = true },
	{ Name = "BrachialR", Label = "R. brachial artery", Part = "RightUpperArmD", Segment = "RightUpperArm", Offset = Vector3.new(-0.1, 0, 0), Radius = 0.1, BleedRate = 70, Vessel = true },
	{ Name = "BrachialL", Label = "L. brachial artery", Part = "LeftUpperArmD", Segment = "LeftUpperArm", Offset = Vector3.new(0.1, 0, 0), Radius = 0.1, BleedRate = 70, Vessel = true },
}
Anatomy.OrganByName = {}
Anatomy.OrgansBySegment = {}
for _, o in ipairs(Anatomy.Organs) do
	Anatomy.OrganByName[o.Name] = o
	Anatomy.OrgansBySegment[o.Segment] = Anatomy.OrgansBySegment[o.Segment] or {}
	table.insert(Anatomy.OrgansBySegment[o.Segment], o)
end

-- Pair lethal rule: both lungs destroyed -> respiratory failure
Anatomy.LungFailure = { Threshold = 20, Delay = 6 }

return Anatomy
