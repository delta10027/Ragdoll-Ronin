--[[
	SoundPlayer: plays the combat sounds the server announces (server SoundFX, SoundEvent remote)
	at the place they happen. Every Config.Sounds id is preloaded when the client starts, so even a
	very short sound is ready the moment it is needed. Each sound lives on its own attachment under
	Terrain until it has finished; a sound sent with a next one ({ id, volume, speed }) plays that
	one at the same place as soon as it ends.
]]
local ContentProvider = game:GetService("ContentProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("RagdollRonin")
local Config = require(Shared:WaitForChild("Config"))

local SoundPlayer = {}
local SND = Config.Sounds
local templates = {} -- asset id -> preloaded Sound

local function assetId(id)
	if typeof(id) == "number" then
		return "rbxassetid://" .. math.floor(id)
	elseif typeof(id) == "string" and id ~= "" then
		return id:find("://") and id or ("rbxassetid://" .. id)
	end
	return nil
end

local function play(id, position, volume, speed, nextSnd)
	if typeof(id) ~= "string" or typeof(position) ~= "Vector3" then
		return
	end
	local att = Instance.new("Attachment")
	att.Name = "RR_Sound"
	att.WorldPosition = position
	local s = templates[id] and templates[id]:Clone() or Instance.new("Sound")
	s.SoundId = id
	s.Volume = typeof(volume) == "number" and volume or 1
	s.PlaybackSpeed = typeof(speed) == "number" and speed or 1
	s.RollOffMode = Enum.RollOffMode.InverseTapered
	s.RollOffMaxDistance = SND.RollOffMaxDistance or 120
	s.Parent = att
	att.Parent = workspace.Terrain
	s.Ended:Once(function()
		att:Destroy()
		if typeof(nextSnd) == "table" then
			play(nextSnd[1], position, nextSnd[2], nextSnd[3])
		end
	end)
	task.delay(15, function()
		if att.Parent then
			att:Destroy()
		end
	end)
	s:Play()
end

function SoundPlayer.Init(ctx)
	local list = {}
	for _, slot in pairs(SND) do
		if typeof(slot) == "table" and slot.Ids then
			for _, raw in ipairs(slot.Ids) do
				local id = assetId(raw)
				if id and not templates[id] then
					local s = Instance.new("Sound")
					s.SoundId = id
					templates[id] = s
					table.insert(list, s)
				end
			end
		end
	end
	task.spawn(function()
		pcall(ContentProvider.PreloadAsync, ContentProvider, list)
	end)
	ctx.Remotes:WaitForChild("SoundEvent").OnClientEvent:Connect(play)
end

return SoundPlayer
