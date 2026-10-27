--[[
	SoundFX: positional combat sounds from Config.Sounds (slots: Slash, Block, Parry, Clash, Cut,
	Sever, Decapitation, KickLanded, KickBlocked). The server picks the sound and tells every client
	(SoundEvent remote); each client plays it where it happens (client SoundPlayer, which preloads
	every id when it starts).
	A slot with no ids uses its Fallback slot, or plays nothing. Play(name, position, after) also
	plays slot `after` at the same place once the first sound has finished (straight away when
	the first slot is empty).
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
local remote = ReplicatedStorage.RagdollRonin.Remotes.SoundEvent
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

-- { id, volume, speed } of a random sound of the slot, or nil
local function pick(name)
	local slot, ids = resolve(name)
	if not slot then
		return nil
	end
	local lo, hi = slot.PitchMin or 1, slot.PitchMax or 1
	return { ids[math.random(1, #ids)], slot.Volume or 1, lo + (hi - lo) * math.random() }
end

function SoundFX.Play(name, position, after)
	if typeof(position) ~= "Vector3" then
		return false
	end
	local snd = pick(name)
	local nextSnd = after and pick(after)
	if not snd then
		snd, nextSnd = nextSnd, nil
	end
	if not snd then
		return false
	end
	-- every client plays it itself (client SoundPlayer): a sound the server creates is deleted
	-- when the server thinks it has finished, which for a short sound is before a client that is
	-- still downloading it ever plays it
	remote:FireAllClients(snd[1], position, snd[2], snd[3], nextSnd)
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
