--[[
	Registry: owns the set of live fighters and the part -> fighter lookup used by hit detection.
	A part is mapped only while it is attached to a living body; severed limbs are unmapped.
]]
local Registry = {}

Registry.ById = {}
Registry.ByPlayer = {}
Registry.PartToFighter = {}
Registry.NextId = 0
local cachedList -- (Registry.List)

local debrisFolder
function Registry.DebrisFolder()
	if not debrisFolder or not debrisFolder.Parent then
		debrisFolder = workspace:FindFirstChild("RR_Debris") or Instance.new("Folder")
		debrisFolder.Name = "RR_Debris"
		debrisFolder.Parent = workspace
	end
	return debrisFolder
end

function Registry.NewId()
	Registry.NextId += 1
	return Registry.NextId
end

function Registry.Add(f)
	cachedList = nil
	Registry.ById[f.Id] = f
	if f.Player then
		Registry.ByPlayer[f.Player] = f
	end
	for _, part in pairs(f.Parts) do
		Registry.PartToFighter[part] = f
	end
	if f.Sword then
		Registry.PartToFighter[f.Sword.Blade] = f
		Registry.PartToFighter[f.Sword.ParryZone] = f
	end
end

function Registry.Remove(f)
	cachedList = nil
	Registry.ById[f.Id] = nil
	if f.Player and Registry.ByPlayer[f.Player] == f then
		Registry.ByPlayer[f.Player] = nil
	end
	for part, owner in pairs(Registry.PartToFighter) do
		if owner == f then
			Registry.PartToFighter[part] = nil
		end
	end
end

function Registry.UnmapPart(part)
	Registry.PartToFighter[part] = nil
end

function Registry.FromPart(part)
	return Registry.PartToFighter[part]
end

-- Snapshot array so callers can safely add/remove fighters while iterating: built once per change
-- of the set (Add/Remove make a new one, never change one a caller may be iterating), not on every
-- call (the update loops call this several times a frame). Callers must not modify it.
function Registry.List()
	if not cachedList then
		cachedList = {}
		for _, f in pairs(Registry.ById) do
			table.insert(cachedList, f)
		end
	end
	return cachedList
end

return Registry
