--[[
	SoundFX: positional combat sounds from Config.Sounds (slots: Slash, Block, Parry, Clash, Cut,
	Sever, Decapitation, KickLanded, KickBlocked). Played by the server at the place it happens, on
	an attachment under Terrain, so every client nearby hears it; cleaned up when it ends.
	A slot with no ids uses its Fallback slot, or plays nothing.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.RagdollRonin.Config)
local Runtime = require(ReplicatedStorage.RagdollRonin.Sim.Runtime)

local SoundFX = {}
local SND = Config.Sounds
local lastSlash = setmetatable({}, { __mode = "k" })

local function assetId(id)
	if typeof(id) == "number" then
		return "rbxassetid://" .. math.floor(id)
	elseif typeof(id) == "string" and id ~= "" then
		return id:find("://") and id or ("rbxassetid://" .. id)
	end
	return nil
end

-- the slot that actually has sounds (following Fallback), or nil
local function resolve(name)
	for _ = 1, 4 do
		local slot = SND[name]
		if typeof(slot) ~= "table" then
			return nil
		end
		if slot.Ids and #slot.Ids > 0 then
			return slot
		end
		name = slot.Fallback
		if not name then
			return nil
		end
	end
	return nil
end

function SoundFX.Play(name, position)
	local slot = resolve(name)
	if not slot or typeof(position) ~= "Vector3" then
		return
	end
	local id = assetId(slot.Ids[math.random(1, #slot.Ids)])
	if not id then
		return
	end
	local att = Instance.new("Attachment")
	att.Name = "RR_Sound_" .. name
	att.WorldPosition = position
	local s = Instance.new("Sound")
	s.SoundId = id
	s.Volume = slot.Volume or 1
	local lo, hi = slot.PitchMin or 1, slot.PitchMax or 1
	s.PlaybackSpeed = lo + (hi - lo) * math.random()
	s.RollOffMode = Enum.RollOffMode.InverseTapered
	s.RollOffMaxDistance = SND.RollOffMaxDistance or 120
	s.Parent = att
	att.Parent = workspace.Terrain
	s.Ended:Once(function()
		att:Destroy()
	end)
	task.delay(10, function() -- (never loaded, or never ended)
		if att.Parent then
			att:Destroy()
		end
	end)
	s:Play()
end

function SoundFX.Init()
	-- shared modules (stroke start in SwordController.Track) play through Runtime.Sound
	Runtime.Sound = function(name, position, f)
		if name == "Slash" and f then
			local now = os.clock()
			if lastSlash[f] and now - lastSlash[f] < (SND.SlashCooldown or 0) then
				return
			end
			lastSlash[f] = now
		end
		SoundFX.Play(name, position)
	end
end

return SoundFX
