--[[
	SoundFX: positional combat sounds from Config.Sounds (slots: Slash, Block, Parry, Clash, Cut,
	Sever, Decapitation, KickLanded, KickBlocked). Played by the server at the place it happens, on
	an attachment under Terrain, so every client nearby hears it; cleaned up when it ends.
	A slot with no ids uses its Fallback slot, or plays nothing.
	Every id is preloaded at startup. One that fails to load is reported in the output
	("[RR] sound ... failed to load") and skipped from then on, so the slot uses its other ids or
	its Fallback. In Studio, ServerStorage.RR_DevCommand:Invoke("playSound", "Cut") plays a slot
	at the first player's fighter.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContentProvider = game:GetService("ContentProvider")
local Config = require(ReplicatedStorage.RagdollRonin.Config)
local Runtime = require(ReplicatedStorage.RagdollRonin.Sim.Runtime)

local SoundFX = {}
local SND = Config.Sounds
local lastSlash = setmetatable({}, { __mode = "k" })
local failed = {} -- asset id string -> true once it failed to load

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
		if slot.Ids then
			local good = {}
			for _, raw in ipairs(slot.Ids) do
				local id = assetId(raw)
				if id and not failed[id] then
					table.insert(good, id)
				end
			end
			if #good > 0 then
				return slot, good
			end
		end
		name = slot.Fallback
		if not name then
			return nil
		end
	end
	return nil
end

function SoundFX.Play(name, position)
	local slot, ids = resolve(name)
	if not slot or typeof(position) ~= "Vector3" then
		return false
	end
	local id = ids[math.random(1, #ids)]
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
	return true
end

-- load every configured id once and report the ones Roblox refuses
local function preload()
	local sounds, slotOf = {}, {}
	for name, slot in pairs(SND) do
		if typeof(slot) == "table" and slot.Ids then
			for _, raw in ipairs(slot.Ids) do
				local id = assetId(raw)
				if id and not slotOf[id] then
					local snd = Instance.new("Sound")
					snd.SoundId = id
					table.insert(sounds, snd)
					slotOf[id] = name
				end
			end
		end
	end
	if #sounds == 0 then
		return
	end
	local ok, err = pcall(ContentProvider.PreloadAsync, ContentProvider, sounds, function(id, status)
		if status ~= Enum.AssetFetchStatus.Success then
			failed[id] = true
			warn(string.format("[RR] sound %s (%s) failed to load: %s. Check the id is an Audio asset this place may use.",
				tostring(slotOf[id]), id, tostring(status)))
		end
	end)
	if not ok then
		warn("[RR] sound preload error: " .. tostring(err))
	end
	local loaded = 0
	for _, snd in ipairs(sounds) do
		if not failed[snd.SoundId] then
			loaded += 1
		end
		snd:Destroy()
	end
	print(string.format("[RR] sounds: %d of %d loaded", loaded, #sounds))
end

function SoundFX.Init()
	task.spawn(preload)
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
