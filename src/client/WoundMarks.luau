--[[
	WoundMarks: draws the wound marks the server announces (server BloodFX.WoundMark, WoundEvent
	remote), welded to the body part where the blade went in. Local parts in a folder of their own:
	they never replicate, never touch the body's network ownership, and never count as a change of
	the fighter's structure. At most Config.Anatomy.MaxWoundMarks per fighter (oldest recycled);
	a mark goes with its body part.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage:WaitForChild("RagdollRonin"):WaitForChild("Config"))

local WoundMarks = {}
local BLOOD = Color3.fromRGB(110, 8, 12)
local folder
local byModel = setmetatable({}, { __mode = "k" }) -- fighter model -> { marks, oldest first }

local function add(part, offset, size)
	if typeof(part) ~= "Instance" or not part:IsA("BasePart") or not part:IsDescendantOf(workspace)
		or typeof(offset) ~= "CFrame" or typeof(size) ~= "Vector3" then
		return
	end
	local model = part:FindFirstAncestorWhichIsA("Model") or part
	local list = byModel[model]
	if not list then
		list = {}
		byModel[model] = list
	end
	if #list >= Config.Anatomy.MaxWoundMarks then
		local old = table.remove(list, 1)
		if old then
			old:Destroy()
		end
	end
	local m = Instance.new("Part")
	m.Name = "Wound"
	m.Size = size
	m.CFrame = part.CFrame * offset
	m.Color = BLOOD
	m.Material = Enum.Material.SmoothPlastic
	m.Massless = true
	m.CanCollide, m.CanQuery, m.CanTouch, m.CastShadow = false, false, false, false
	local w = Instance.new("WeldConstraint")
	w.Part0 = part
	w.Part1 = m
	w.Parent = m
	m.Parent = folder
	table.insert(list, m)
	part.Destroying:Once(function()
		m:Destroy()
	end)
	part.AncestryChanged:Connect(function(_, parent)
		if not parent then
			m:Destroy()
		end
	end)
end

function WoundMarks.Init(ctx)
	folder = Instance.new("Folder")
	folder.Name = "RR_WoundMarks"
	folder.Parent = workspace
	ctx.Remotes:WaitForChild("WoundEvent").OnClientEvent:Connect(add)
end

return WoundMarks
