--[[
	ArmorView: draws every fighter's armour (server Armor: model attributes "Armor_<piece>" = hits
	left) as local shells welded over the covered body parts. When a piece breaks (hits reach 0)
	its shells come off and tumble away. The Cloak is built by CloakView instead (collar, mantle
	and a simulated cape). Local parts only: nothing replicates, the bodies'
	physics and network ownership are untouched.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")
local Shared = ReplicatedStorage:WaitForChild("RagdollRonin")
local Config = require(Shared:WaitForChild("Config"))
local Anatomy = require(Shared:WaitForChild("Anatomy"))
local CloakView = require(script.Parent.CloakView)

local ArmorView = {}
local AR = Config.Armor
local folder
local shells = setmetatable({}, { __mode = "k" }) -- model -> piece -> { shell parts }

local function shellFor(part, piece, color)
	local s = Instance.new("Part")
	s.Name = "Armor_" .. piece
	local size = part.Size + Vector3.one * (2 * AR.Inflate)
	local cf = part.CFrame
	if piece == "Helmet" then
		-- a kabuto over the top of the head, the face left open
		size = Vector3.new(size.X, part.Size.Y * 0.55, size.Z)
		cf = cf * CFrame.new(0, part.Size.Y * 0.3, 0)
	end
	s.Size = size
	s.CFrame = cf
	s.Color = color
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
		local def = AR.Pieces[piece]
		local list = {}
		if piece == "Cloak" then
			list = CloakView.Build(model, def.Color, folder)
		end
		for _, seg in ipairs(def.Segments) do
			for _, name in ipairs(Anatomy.SegmentParts[seg] or {}) do
				local part = model:FindFirstChild(name)
				if part and part:IsA("BasePart") then
					table.insert(list, shellFor(part, piece, def.Color))
				end
			end
		end
		shells[model] = shells[model] or {}
		shells[model][piece] = list
	else
		clear(model, piece, hits == 0) -- 0: broken; nil: taken off
	end
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
