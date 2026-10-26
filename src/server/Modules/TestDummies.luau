--[[
	TestDummies: a line of respawning practice dummies, spawned once when the first player joins
	(Config.Debug.TestDummies). Each is an ordinary fighter driven by an input override, so it runs
	through exactly the same controllers, hit detection and anatomy as a player; after dying it
	respawns at the same spot with the same behaviour (Lifecycle keeps its spawn options).

	Like a player, a dummy turns to face the nearest player's fighter in range (FaceRange) and
	otherwise its spawn direction; it can be hit, staggered, knocked down, cut apart and killed like
	anyone else. Its head label shows its state and remaining blood.

	Behaviours (inputs as a player would give them; aim u = right, v = up on the combat circle):
	  SwingHorizontal  every SwingPeriod: wind up at the right, cut through to the left, release
	  SwingVertical    every SwingPeriod: wind up overhead, cut down to the bottom, release
	  BlockHigh        holds the high guard (M2, cursor up)
	  BlockSide        holds the side guard on its left - the side a right-handed horizontal cut
	                   (right to left) from someone facing it arrives on
	  Idle             stands in the ready stance
]]
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.RagdollRonin.Config)
local Input = require(ReplicatedStorage.RagdollRonin.Sim.Input)
local Registry = require(script.Parent.Registry)
local Util = require(ReplicatedStorage.RagdollRonin.Sim.Util)

local TestDummies = {}

local T = Config.Debug.TestDummyTiming

-- one swing cycle: wind up at `from`, cut to `to`, then let go until the next period
local function swing(t, from, to)
	local c = t % T.SwingPeriod
	if c < T.WindupTime then
		return { M1 = true, AimU = from.X, AimV = from.Y }
	elseif c < T.WindupTime + T.CutHoldTime then
		return { M1 = true, AimU = to.X, AimV = to.Y }
	end
	return {}
end

local BEHAVIORS = {
	SwingHorizontal = function(t)
		return swing(t, Vector2.new(1, 0), Vector2.new(-1, 0))
	end,
	SwingVertical = function(t)
		return swing(t, Vector2.new(0, 1), Vector2.new(0, -1))
	end,
	BlockHigh = function()
		return { M2 = true, AimU = 0, AimV = 1 }
	end,
	BlockSide = function()
		return { M2 = true, AimU = -1, AimV = 0 }
	end,
	Idle = function()
		return {}
	end,
}

local LINE = {
	{ Behavior = "SwingHorizontal", Label = "Swings horizontally" },
	{ Behavior = "BlockHigh", Label = "Blocks high" },
	{ Behavior = "Idle", Label = "Idle" },
	{ Behavior = "BlockSide", Label = "Blocks horizontal cuts" },
	{ Behavior = "SwingVertical", Label = "Swings vertically" },
}

local function spawnLine(spawn)
	local center = Vector3.zero
	local loc = workspace:FindFirstChildWhichIsA("SpawnLocation", true)
	if loc then
		center = loc.Position
	end
	local L = Config.Debug.TestDummyLine
	for i, d in ipairs(LINE) do
		local x = (i - (#LINE + 1) / 2) * L.Spacing
		spawn(nil, {
			Name = "Dummy_" .. d.Behavior,
			Position = center + Vector3.new(x, 0, -L.Distance),
			Yaw = math.pi, -- facing +Z, toward the spawn
			RespawnDummy = true,
			Behavior = d.Behavior,
			Label = d.Label,
		})
	end
end

-- yaw toward the nearest living player's fighter within range (BalanceController's convention)
local function faceYaw(f)
	local me = f.Parts.LowerTorso
	if not me then
		return f.SpawnYaw
	end
	local best, bestDist = nil, Config.Debug.TestDummyLine.FaceRange
	for _, other in ipairs(Registry.List()) do
		local p = other.Player and not other.Dead and other.Parts.LowerTorso
		if p then
			local d = Util.flat(p.Position - me.Position)
			if d.Magnitude < bestDist then
				best, bestDist = d, d.Magnitude
			end
		end
	end
	if not best or bestDist < 0.5 then
		return f.SpawnYaw
	end
	return math.atan2(-best.X, -best.Z)
end

local function updateLabel(f)
	local head = f.Parts.Head
	local gui = head and head:FindFirstChild("Label")
	local text = gui and gui:FindFirstChildWhichIsA("TextLabel")
	if text then
		local blood = f.Anatomy and f.Anatomy.Blood / Config.Blood.Max or 1
		text.Text = string.format("%s\n%s  ·  blood %d%%", f.SpawnOpts.Label or f.Name, f.State or "?", math.floor(blood * 100 + 0.5))
	end
end

-- api: { Spawn = Lifecycle.Spawn }
function TestDummies.Init(api)
	if not Config.Debug.TestDummies then
		return
	end
	local spawned = false
	local function onPlayer()
		if spawned then
			return
		end
		spawned = true
		task.delay(Config.Lifecycle.FirstSpawnDelay, spawnLine, api.Spawn)
	end
	Players.PlayerAdded:Connect(onPlayer)
	if #Players:GetPlayers() > 0 then
		onPlayer()
	end

	-- drive every behaviour dummy's input (as if a player held the buttons and moved the mouse)
	local labelAccum = 0
	RunService.Heartbeat:Connect(function(dt)
		local now = os.clock()
		labelAccum += dt
		local refreshLabels = labelAccum >= 0.2
		if refreshLabels then
			labelAccum = 0
		end
		for _, f in ipairs(Registry.List()) do
			local behavior = f.Behavior and BEHAVIORS[f.Behavior]
			if behavior and not f.Dead then
				if refreshLabels then
					updateLabel(f)
				end
				local i = Input.Neutral()
				i.Yaw = faceYaw(f)
				local t = now - (f.SpawnTime or now) - T.StartDelay
				if t >= 0 then
					for k, v in pairs(behavior(t)) do
						i[k] = v
					end
				end
				f.InputOverride = i
			end
		end
	end)
end

return TestDummies
