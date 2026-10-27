--[[
	ArmorView: draws every fighter's armour (server Armor: model attributes "Armor_<piece>" = hits
	left) as local shells welded over the covered body parts. When a piece breaks (hits reach 0)
	its shells come off and tumble away (a Do's with its lacing). Cloth (Cloak, Cape, Scarf, Haori) is built by CloakView, the
	rest of the clothing (hat, bags, sandals) by GearView, by the piece's View. Local parts only:
	nothing replicates, the bodies' physics and network ownership are untouched.
	BuildPiece also dresses the inventory's figure and draws the item icons (ItemArt).
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")
local Shared = ReplicatedStorage:WaitForChild("RagdollRonin")
local Config = require(Shared:WaitForChild("Config"))
local Anatomy = require(Shared:WaitForChild("Anatomy"))
local CloakView = require(script.Parent.CloakView)
local GearView = require(script.Parent.GearView)

local ArmorView = {}
local AR = Config.Armor
local folder
local shells = setmetatable({}, { __mode = "k" }) -- model -> piece -> { shell parts }

local function shellFor(part, piece, def, folder)
	local s = Instance.new("Part")
	s.Name = "Armor_" .. piece
	local size = part.Size + Vector3.one * (2 * AR.Inflate)
	local cf = part.CFrame
	if def.View == "Do" then
		-- a closer fit, so a haori goes on over it
		size = part.Size + Vector3.one * (2 * AR.Inflate * 0.7)
	elseif def.View == "Helmet" then
		-- a kabuto over the top of the head, the face left open
		size = Vector3.new(size.X, part.Size.Y * 0.55, size.Z)
		cf = cf * CFrame.new(0, part.Size.Y * 0.3, 0)
	end
	s.Size = size
	s.CFrame = cf
	s.Color = def.Color
	s.Material = Enum.Material.SmoothPlastic
	s.Reflectance = 0.08
	s.Massless = true
	s.CanCollide, s.CanQuery, s.CanTouch, s.CastShadow = false, false, false, false
	local w = Instance.new("WeldConstraint")
	w.Part0 = part
	w.Part1 = s
	w.Parent = s
	s.Parent = folder
	return s
end

-- a Do's lames: bands of lacing around each torso shell
local LAMES = { UpperTorso = { -0.62, -0.22, 0.18 }, LowerTorso = { -0.45, 0.15 } }
local function lacing(shell, partName, def, folder, list)
	for _, y in ipairs(LAMES[partName] or {}) do
		local band = Instance.new("Part")
		band.Name = shell.Name .. "_Lacing"
		band.Size = Vector3.new(shell.Size.X + 0.016, shell.Size.Y * 0.05, shell.Size.Z + 0.016)
		band.CFrame = shell.CFrame * CFrame.new(0, shell.Size.Y * 0.5 * y, 0)
		band.Color = def.Lacing or def.Color
		band.Material = Enum.Material.Fabric
		band.Massless = true
		band.CanCollide, band.CanQuery, band.CanTouch, band.CastShadow = false, false, false, false
		local w = Instance.new("WeldConstraint")
		w.Part0 = shell
		w.Part1 = band
		w.Parent = band
		band.Parent = folder
		table.insert(list, band)
	end
end

local function clear(model, piece, shatter)
	local byPiece = shells[model]
	local list = byPiece and byPiece[piece]
	if not list then
		return
	end
	byPiece[piece] = nil
	for _, s in ipairs(list) do
		if shatter and s.Parent then
			-- the broken plates fall off
			local weld = s:FindFirstChildOfClass("WeldConstraint")
			if weld then
				weld:Destroy()
			end
			s.Massless = false
			s.CanCollide = true
			s.CollisionGroup = "RR_Debris"
			s.AssemblyLinearVelocity = Vector3.new(math.random() * 8 - 4, 6 + math.random() * 4, math.random() * 8 - 4)
			s.AssemblyAngularVelocity = Vector3.new(math.random() * 10 - 5, math.random() * 10 - 5, math.random() * 10 - 5)
			Debris:AddItem(s, 3)
		else
			s:Destroy()
		end
	end
end

local function refresh(model, piece)
	local hits = model:GetAttribute("Armor_" .. piece)
	local byPiece = shells[model]
	local has = byPiece and byPiece[piece] ~= nil
	if typeof(hits) == "number" and hits > 0 then
		if has then
			return
		end
		shells[model] = shells[model] or {}
		shells[model][piece] = ArmorView.BuildPiece(model, piece, folder)
	else
		clear(model, piece, hits == 0) -- 0: broken; nil: taken off
	end
end

-- builds piece's look on model into folder; returns its parts. opts go to CloakView (a figure in a
-- ViewportFrame: Wind, Static)
function ArmorView.BuildPiece(model, piece, into, opts)
	local def = AR.Pieces[piece]
	if not def then
		return {}
	end
	local list = {}
	if Config.Cloak.Styles[def.View] then
		list = CloakView.Build(model, def.View, def.Colors or { Main = def.Color }, into, opts)
	elseif GearView.Has(def.View) then
		local colliders
		list, colliders = GearView.Build(def.View, model, def.Color, into)
		if colliders then
			CloakView.AddColliders(model, colliders)
		end
	end
	for _, seg in ipairs(def.Segments) do
		for _, name in ipairs(Anatomy.SegmentParts[seg] or {}) do
			local part = model:FindFirstChild(name)
			if part and part:IsA("BasePart") then
				local shell = shellFor(part, piece, def, into)
				table.insert(list, shell)
				if def.View == "Do" then
					lacing(shell, name, def, into, list)
				end
			end
		end
	end
	return list
end

local function watch(model)
	if not model:IsA("Model") or model:GetAttribute("RR_Fighter") ~= true then
		return
	end
	for _, piece in ipairs(AR.Order) do
		model:GetAttributeChangedSignal("Armor_" .. piece):Connect(function()
			refresh(model, piece)
		end)
		refresh(model, piece)
	end
end

function ArmorView.Init(ctx)
	folder = Instance.new("Folder")
	folder.Name = "RR_Armor"
	folder.Parent = workspace
	CloakView.Init(ctx)
	workspace.ChildAdded:Connect(watch)
	workspace.ChildRemoved:Connect(function(model)
		local byPiece = shells[model]
		if byPiece then
			for piece in pairs(byPiece) do
				clear(model, piece, false)
			end
		end
	end)
	for _, c in ipairs(workspace:GetChildren()) do
		watch(c)
	end
end

return ArmorView
