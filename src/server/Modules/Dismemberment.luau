--[[
	Dismemberment: physical separation of body segments.

	Engine reality: Roblox has no supported runtime API for slicing arbitrary meshes/parts along a
	plane at an arbitrary contact point. So the body is authored as modular sub-segments and every
	limb is severable at predefined anatomical boundaries (neck, mid upper arm, elbow, mid forearm,
	wrist, mid thigh, knee, mid shin, ankle). A cut severs the boundary nearest to the contact.

	Severing really detaches the geometry:
	  * the boundary's joint constraint / weld seam and its motor drive are destroyed
	  * every part distal to the boundary (graph walk over intact joints) moves into a debris model,
	    keeping its internal joints as a limp chain, with all motors disabled
	  * parts are unmapped from hit detection, switched to the debris collision group and given a
	    bounded impulse; sword/off-hand drives that depended on the lost parts are removed
	  * stump caps + a bleeding source are added; anatomy and capabilities are updated by the caller
	Debris has a lifetime and a global cap.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.RagdollRonin.Config)
local Registry = require(script.Parent.Registry)
local BloodFX = require(script.Parent.BloodFX)
local DebugService = require(script.Parent.DebugService)
local CharacterBuilder = require(script.Parent.CharacterBuilder)

local Dismemberment = {}
local debrisQueue = {}

function Dismemberment.TrackDebris(model, lifetime)
	table.insert(debrisQueue, model)
	while #debrisQueue > Config.Dismemberment.MaxDebrisModels do
		local old = table.remove(debrisQueue, 1)
		if old and old.Parent then
			old:Destroy()
		end
	end
	task.delay(lifetime, function()
		local i = table.find(debrisQueue, model)
		if i then
			table.remove(debrisQueue, i)
		end
		if model.Parent then
			model:Destroy()
		end
	end)
end

local NON_SOLID = { ParryZone = true, Wound = true, Stump = true }
local function toDebris(part)
	part.CollisionGroup = "RR_Debris"
	part.CanQuery = false
	-- limbs are non-colliding while their owner stands; debris must land on the world
	part.CanCollide = not (part.Massless or NON_SOLID[part.Name])
end

--[[
	Ownership hand-off for debris MUST be deferred. Destroying the joint does not split the physics
	mechanism until the next step; setting auto ownership on a debris part before that applies to
	the whole connected body, letting a nearby client take over simulating a live fighter (found in
	testing: bodies were launched by client-side simulation without the server's drives).
	After the split, debris goes to automatic ownership and the server re-claims the body.
]]
local function connectedToFighter(part)
	for _, p in ipairs(part:GetConnectedParts(true)) do
		if Registry.FromPart(p) then
			return true
		end
	end
	return false
end

local function releaseOwnership(model, f, attempt)
	attempt = attempt or 1
	task.delay(0.25, function()
		if not model.Parent then
			return
		end
		local parts = {}
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("BasePart") and not d.Anchored then
				if connectedToFighter(d) then
					-- mechanism not split yet (or still linked): keep everything server-owned, retry
					if attempt < 8 then
						releaseOwnership(model, f, attempt + 1)
					end
					return
				end
				table.insert(parts, d)
			end
		end
		for _, d in ipairs(parts) do
			pcall(d.SetNetworkOwnershipAuto, d)
		end
		if f and f.Model.Parent and not f.Removed then
			CharacterBuilder.ClaimOwnership(f.Model)
		end
	end)
end

-- Parts reachable from startPart through intact joints (the cut joint must already be marked)
local function collectDistal(f, startPart)
	local set = { [startPart] = true }
	local stack = { startPart }
	while #stack > 0 do
		local p = table.remove(stack)
		for _, edge in ipairs(f.Adjacency[p] or {}) do
			local j = f.Joints[edge.Joint]
			if j and not j.Severed and not set[edge.Part] and f.Parts[edge.Part] then
				set[edge.Part] = true
				table.insert(stack, edge.Part)
			end
		end
	end
	return set
end

local function stumpCap(part, pivot, axis, diameter)
	local perp = math.abs(axis.Y) < 0.9 and Vector3.yAxis or Vector3.xAxis
	local cap = Instance.new("Part")
	cap.Name = "Stump"
	cap.Shape = Enum.PartType.Cylinder
	cap.Size = Vector3.new(0.05, diameter, diameter)
	cap.CFrame = CFrame.fromMatrix(pivot, axis, perp:Cross(axis).Unit)
	cap.Color = Color3.fromRGB(120, 20, 24)
	cap.Material = Enum.Material.SmoothPlastic
	cap.Massless = true
	cap.CanCollide, cap.CanQuery, cap.CanTouch, cap.CastShadow = false, false, false, false
	cap.CollisionGroup = "RR_Debris"
	local w = Instance.new("WeldConstraint")
	w.Part0 = part
	w.Part1 = cap
	w.Parent = cap
	cap.Parent = part
	return cap
end

local function moveSwordToDebris(f, parentModel)
	local sword = f.Sword
	if not sword then
		return nil
	end
	Registry.UnmapPart(sword.Blade)
	Registry.UnmapPart(sword.ParryZone)
	for _, p in ipairs(sword.Model:GetDescendants()) do
		if p:IsA("BasePart") then
			toDebris(p)
		end
	end
	if f.Drives.OffPos then
		f.Drives.OffPos:Destroy()
		f.Drives.OffPos = nil
	end
	sword.Model.Parent = parentModel
	f.Sword = nil
	f.Model:SetAttribute("HasSword", false)
	return sword
end

local function recomputeMass(f)
	local m = 0
	for _, p in pairs(f.Parts) do
		m += p:GetMass()
	end
	if f.Sword then
		for _, p in ipairs(f.Sword.Model:GetDescendants()) do
			if p:IsA("BasePart") and not p.Massless then
				m += p:GetMass()
			end
		end
	end
	f.TotalMass = m
end

-- Returns the set of distal part names on success, nil if the boundary was already severed.
function Dismemberment.Sever(f, boundaryName, direction, power)
	local j = f.Joints[boundaryName]
	if not j or j.Severed or not f.Parts[j.ChildName] or not f.Parts[j.ParentName] then
		return nil
	end
	local parentPart = f.Parts[j.ParentName]
	local childPart = f.Parts[j.ChildName]
	local pivot = parentPart.CFrame:PointToWorldSpace(j.PivotLocal)
	local axis = childPart.CFrame.UpVector
	local diameter = math.min(childPart.Size.X, childPart.Size.Z) * 0.95

	j.Severed = true
	local distal = collectDistal(f, j.ChildName)

	-- 1. cut the boundary connection
	for _, inst in ipairs(j.Instances) do
		inst:Destroy()
	end
	j.Instances = {}

	-- the container is parented first so severed parts never leave the workspace (leaving and
	-- re-entering resets network ownership of the still-connected mechanism)
	local debrisModel = Instance.new("Model")
	debrisModel.Name = string.format("Severed_%s_%s", f.Name, boundaryName)
	debrisModel.Parent = Registry.DebrisFolder()

	-- 2. joints fully inside the severed piece become a limp, undriven chain
	for name, jj in pairs(f.Joints) do
		if not jj.Severed and distal[jj.ParentName] and distal[jj.ChildName] then
			jj.Severed = true
			jj.Detached = true
			for _, inst in ipairs(jj.Instances) do
				if inst:IsA("AlignOrientation") then
					inst:Destroy()
				elseif inst:IsA("HingeConstraint") then
					inst.ActuatorType = Enum.ActuatorType.None
					inst.Parent = debrisModel
				elseif inst:IsA("Constraint") or inst:IsA("WeldConstraint") then
					inst.Parent = debrisModel
				end
			end
		end
	end

	-- 3. drives that depended on the lost parts
	if distal.RightHand then
		for _, key in ipairs({ "HandPos", "HandOri" }) do
			if f.Drives[key] then
				f.Drives[key]:Destroy()
				f.Drives[key] = nil
			end
		end
		if not f.Sheathed then -- (a sheathed sword stays in its saya on the hip)
			moveSwordToDebris(f, debrisModel)
		end
	end
	if distal.LeftHand and f.Drives.OffPos then
		f.Drives.OffPos:Destroy()
		f.Drives.OffPos = nil
	end

	-- 4. move geometry
	local moved = {}
	for name in pairs(distal) do
		local p = f.Parts[name]
		Registry.UnmapPart(p)
		f.Parts[name] = nil
		f.DetachedParts[name] = p
		toDebris(p)
		p.Parent = debrisModel
		table.insert(moved, p)
	end
	f.OwnershipDirty = 3 -- stump cap welded to the body: re-claim after the engine merges it
	releaseOwnership(debrisModel, f)

	-- 5. stumps + blood
	stumpCap(parentPart, pivot, axis, diameter)
	stumpCap(childPart, pivot, axis, diameter)
	BloodFX.Source(f, "stump:" .. boundaryName, parentPart, CFrame.new(pivot))
	BloodFX.Burst(childPart, pivot, 25)

	-- 6. bounded separation impulse
	local dv = math.min(power * Config.Dismemberment.SeverDVPerPower, Config.Dismemberment.MaxSeverDV)
	local dir = (direction.Unit + Vector3.new(0, 0.3, 0)).Unit
	for _, p in ipairs(moved) do
		if p.AssemblyRootPart == p then
			p:ApplyImpulse(dir * dv * p.AssemblyMass)
		end
	end

	Dismemberment.TrackDebris(debrisModel, Config.Dismemberment.DebrisLifetime)
	recomputeMass(f)
	DebugService.Attr(f, "SeverResult", boundaryName)
	DebugService.Log(f.Name, "severed at", boundaryName)
	return distal
end

-- Lose the sword without losing the hand (crippled grip)
function Dismemberment.DropSword(f, impulse)
	if not f.Sword or f.Sheathed then
		return
	end
	local sword = f.Sword
	if sword.GripJoint then
		sword.GripJoint:Destroy()
	end
	local holder = Instance.new("Model")
	holder.Name = "DroppedSword_" .. f.Name
	holder.Parent = Registry.DebrisFolder()
	moveSwordToDebris(f, holder)
	f.OwnershipDirty = 3
	releaseOwnership(holder, f)
	if impulse then
		sword.Handle:ApplyImpulse(impulse * sword.Handle.AssemblyMass)
	end
	Dismemberment.TrackDebris(holder, Config.Dismemberment.DebrisLifetime)
	recomputeMass(f)
	DebugService.Attr(f, "SeverResult", "Disarmed")
end

Dismemberment.RecomputeMass = recomputeMass

return Dismemberment
