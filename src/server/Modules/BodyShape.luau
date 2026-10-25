--[[
	BodyShape: the fighter's own core volumes (upper torso, pelvis, neck, head) as boxes in
	UPPER-TORSO space, used to keep posed arms and the sword out of the body. Limbs and blades do
	not physically collide with their own core (see CollisionSetup), so without this the IK and pose
	targets happily pass straight through the chest or head.
	Approximation: the boxes are rigid in torso space (waist/neck twist is ignored).
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.RagdollRonin
local Config = require(Shared.Config)
local Anatomy = require(Shared.Anatomy)

local BodyShape = {}

local S = Config.Scale
local boxes = {}
local torsoCenter = Anatomy.PartByName.UpperTorso.Center
for _, name in ipairs({ "UpperTorso", "LowerTorso", "Neck", "Head" }) do
	local def = Anatomy.PartByName[name]
	table.insert(boxes, { Name = name, C = (def.Center - torsoCenter) * S, H = def.Size * 0.5 * S })
end
BodyShape.Boxes = boxes

local headOnly = {}
for _, b in ipairs(boxes) do
	if b.Name == "Head" or b.Name == "Neck" then
		table.insert(headOnly, b)
	end
end

-- signed distance from p to an axis-aligned box (negative inside)
local function sdBox(p, b)
	local d = p - b.C
	local qx, qy, qz = math.abs(d.X) - b.H.X, math.abs(d.Y) - b.H.Y, math.abs(d.Z) - b.H.Z
	local ox, oy, oz = math.max(qx, 0), math.max(qy, 0), math.max(qz, 0)
	return math.sqrt(ox * ox + oy * oy + oz * oz) + math.min(math.max(qx, qy, qz), 0)
end

-- how deep a sphere of radius r at p sinks into the body (sum over volumes, 0 when clear)
function BodyShape.Penetration(p, r, headOnlyFlag)
	local pen = 0
	for _, b in ipairs(headOnlyFlag and headOnly or boxes) do
		local sd = sdBox(p, b)
		if sd < r then
			pen += r - sd
		end
	end
	return pen
end

-- outward direction and depth of the deepest contact of a sphere at p (nil when clear)
function BodyShape.Contact(p, r, headOnlyFlag)
	local best, bestPen = nil, 0
	for _, b in ipairs(headOnlyFlag and headOnly or boxes) do
		local sd = sdBox(p, b)
		if r - sd > bestPen then
			bestPen = r - sd
			best = b
		end
	end
	if not best then
		return nil
	end
	local d = p - best.C
	local h = best.H
	local c = Vector3.new(math.clamp(d.X, -h.X, h.X), math.clamp(d.Y, -h.Y, h.Y), math.clamp(d.Z, -h.Z, h.Z))
	local out = d - c
	if out.Magnitude > 1e-4 then
		return out.Unit, bestPen
	end
	-- centre inside the box: leave through the nearest face
	local qx, qy, qz = h.X - math.abs(d.X), h.Y - math.abs(d.Y), h.Z - math.abs(d.Z)
	if qx <= qy and qx <= qz then
		return Vector3.new(d.X >= 0 and 1 or -1, 0, 0), bestPen
	elseif qy <= qz then
		return Vector3.new(0, d.Y >= 0 and 1 or -1, 0), bestPen
	end
	return Vector3.new(0, 0, d.Z >= 0 and 1 or -1), bestPen
end

-- move a sphere of radius r at p until it no longer overlaps the body
function BodyShape.PushOut(p, r)
	for _ = 1, 4 do
		local n, pen = BodyShape.Contact(p, r)
		if not n then
			break
		end
		p += n * (pen + 1e-3)
	end
	return p
end

return BodyShape
