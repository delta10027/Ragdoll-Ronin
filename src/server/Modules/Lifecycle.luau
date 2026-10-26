--[[
	Lifecycle: spawning, death, respawning and cleanup for custom fighters.

	Players.CharacterAutoLoads is disabled so Roblox never spawns a default rig. The server builds
	a custom fighter and assigns it as Player.Character (it has no Humanoid). Death is decided only
	by the anatomy/blood rules; the corpse stays physically simulated, then becomes debris when the
	player respawns after Config.Lifecycle.RespawnDelay. Death is processed exactly once.
]]
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.RagdollRonin.Config)
local Registry = require(script.Parent.Registry)
local CharacterBuilder = require(script.Parent.CharacterBuilder)
local AnatomyService = require(script.Parent.AnatomyService)
local Input = require(ReplicatedStorage.RagdollRonin.Sim.Input)
local BalanceController = require(ReplicatedStorage.RagdollRonin.Sim.BalanceController)
local SwordController = require(ReplicatedStorage.RagdollRonin.Sim.SwordController)
local StateMachine = require(ReplicatedStorage.RagdollRonin.Sim.StateMachine)
local Dismemberment = require(script.Parent.Dismemberment)
local Feedback = require(script.Parent.Feedback)
local DebugService = require(script.Parent.DebugService)
local Draw = require(ReplicatedStorage.RagdollRonin.Sim.Draw)
local Loadout = require(script.Parent.Loadout)

local Lifecycle = {}

local GI_COLORS = {
	Color3.fromRGB(46, 58, 92), Color3.fromRGB(110, 34, 38), Color3.fromRGB(40, 78, 56),
	Color3.fromRGB(88, 70, 40), Color3.fromRGB(70, 46, 96), Color3.fromRGB(36, 84, 96),
}

local groundParams = RaycastParams.new()
groundParams.CollisionGroup = "RR_GroundQuery"

local function spawnCFrame(position)
	local center = Vector3.zero
	local spawnLoc = workspace:FindFirstChildWhichIsA("SpawnLocation", true)
	if spawnLoc then
		center = spawnLoc.Position
	end
	local pos = position
	if not pos then
		local a = math.random() * math.pi * 2
		local r = Config.Lifecycle.SpawnRadius * (0.4 + 0.6 * math.random())
		pos = center + Vector3.new(math.cos(a) * r, 0, math.sin(a) * r)
	end
	local hit = workspace:Raycast(pos + Vector3.new(0, 50, 0), Vector3.new(0, -200, 0), groundParams)
	local ground = hit and hit.Position or pos
	local toCenter = Vector3.new(center.X - ground.X, 0, center.Z - ground.Z)
	local yaw = toCenter.Magnitude > 0.5 and math.atan2(-toCenter.X, -toCenter.Z) or 0
	return CFrame.new(ground) * CFrame.Angles(0, yaw, 0), yaw
end

-- opts: { Name, Position, Yaw, RespawnDummy, Behavior, Label }. A respawning dummy comes back with the
-- same opts (same place, facing and behaviour, see TestDummies).
function Lifecycle.Spawn(player, opts)
	opts = opts or {}
	local cf, yaw = spawnCFrame(opts.Position)
	if opts.Yaw then
		yaw = opts.Yaw
		cf = CFrame.new(cf.Position) * CFrame.Angles(0, yaw, 0)
	end
	local id = Registry.NewId()
	local name = opts.Name or (player and player.Name) or ("Dummy" .. id)
	local gi = GI_COLORS[((player and player.UserId or id) % #GI_COLORS) + 1]
	local data = CharacterBuilder.Build(cf, { Name = name, GiColor = gi })

	local f = {
		Id = id,
		Name = name,
		Player = player,
		IsDummy = player == nil,
		RespawnDummy = opts.RespawnDummy,
		SpawnOpts = opts,
		SpawnYaw = yaw,
		Behavior = opts.Behavior,
		Model = data.Model,
		Parts = data.Parts,
		DetachedParts = {},
		Joints = data.Joints,
		Adjacency = data.Adjacency,
		Drives = data.Drives,
		Sword = data.Sword,
		TotalMass = data.TotalMass,
		DriveCache = setmetatable({}, { __mode = "k" }),
		ArmState = { Swivel = 0, Roll = 0, SwivelL = 0 },
		Dead = false,
		SpawnTime = os.clock(),
	}
	data.Model:SetAttribute("FighterId", id)
	if player then
		data.Model:SetAttribute("OwnerUserId", player.UserId)
	end

	AnatomyService.Create(f)
	Input.Init(f, yaw)
	BalanceController.Init(f, yaw)
	SwordController.Init(f)
	StateMachine.Init(f)

	if opts.Label then
		local head = data.Parts.Head
		local gui = Instance.new("BillboardGui")
		gui.Name = "Label"
		gui.Size = UDim2.fromOffset(190, 40)
		gui.StudsOffsetWorldSpace = Vector3.new(0, 1.6, 0)
		gui.AlwaysOnTop = true
		gui.MaxDistance = 80
		local text = Instance.new("TextLabel")
		text.Size = UDim2.fromScale(1, 1)
		text.BackgroundTransparency = 1
		text.TextColor3 = Color3.new(1, 1, 1)
		text.TextStrokeTransparency = 0.3
		text.Font = Enum.Font.GothamMedium
		text.TextSize = 14
		text.Text = opts.Label
		text.Parent = gui
		gui.Parent = head
	end
	data.Model.Parent = workspace
	CharacterBuilder.ClaimOwnership(data.Model)
	Registry.Add(f)
	if player then
		Loadout.Apply(f) -- armour and incantation chosen in the loadout menu
		player.Character = data.Model
		if Config.Sheath.StartSheathed then
			Draw.Attach(f, false, true) -- players start with the katana in its saya (1 draws it)
		end
	end
	f.AnatomyDirty = true
	DebugService.Log("spawned", name, "mass", data.TotalMass)
	return f
end

function Lifecycle.Despawn(f, keepCorpse)
	if f.Removed then
		return
	end
	f.Removed = true
	Registry.Remove(f)
	local model = f.Model
	-- The engine destroys a player's previous Character model when the character is reassigned,
	-- so the corpse keeps the body's contents in a separate model.
	if keepCorpse and model.Parent and f.Player then
		local corpse = Instance.new("Model")
		corpse.Name = model.Name
		corpse.Parent = Registry.DebrisFolder()
		for _, c in ipairs(model:GetChildren()) do
			c.Parent = corpse
		end
		corpse.PrimaryPart = corpse:FindFirstChild("LowerTorso")
		if f.Player.Character == model then
			f.Player.Character = nil
		end
		model:Destroy()
		model = corpse
	elseif f.Player and f.Player.Character == model then
		f.Player.Character = nil
	end
	if keepCorpse and model.Parent then
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("AlignOrientation") or d:IsA("AlignPosition") or d:IsA("LinearVelocity") or d:IsA("VectorForce") then
				d:Destroy()
			elseif d:IsA("HingeConstraint") then
				d.ActuatorType = Enum.ActuatorType.None
			elseif d:IsA("BasePart") then
				d.CollisionGroup = "RR_Debris"
				d.CanQuery = false
			end
		end
		model.Name = "Corpse_" .. f.Name
		model.Parent = Registry.DebrisFolder()
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("BasePart") then
				pcall(d.SetNetworkOwnershipAuto, d)
			end
		end
		Dismemberment.TrackDebris(model, Config.Dismemberment.CorpseLifetime)
	else
		model:Destroy()
	end
end

function Lifecycle.Respawn(f)
	if f.Removed then
		return
	end
	local player = f.Player
	local respawnDummy = f.RespawnDummy
	local name = f.Name
	Lifecycle.Despawn(f, true)
	if player and player.Parent then
		Lifecycle.Spawn(player)
	elseif respawnDummy then
		Lifecycle.Spawn(nil, f.SpawnOpts or { Name = name, RespawnDummy = true })
	end
end

-- Single entry point for death. Idempotent.
function Lifecycle.Kill(f, reason, killer)
	if f.Dead then
		return
	end
	f.Dead = true
	f.DeathReason = reason
	SwordController.EndStroke(f, "Dead")
	StateMachine.ForceDead(f, reason)
	DebugService.Attr(f, "DeathReason", reason)
	f.AnatomyDirty = true
	Feedback.Send(f, "Died", { Reason = reason, Respawn = Config.Lifecycle.RespawnDelay })
	if killer and killer ~= f then
		Feedback.Send(killer, "Killed", { Target = f.Name, Reason = reason })
	end
	print(string.format("[RR] %s died: %s", f.Name, reason))
	task.delay(Config.Lifecycle.RespawnDelay, function()
		Lifecycle.Respawn(f)
	end)
end

-- Detects bodies that were destroyed or fell out of the world
function Lifecycle.Validate(f)
	local pelvis = f.Parts.LowerTorso
	if not f.Model.Parent or not pelvis or not pelvis:IsDescendantOf(workspace) then
		if not f.Dead then
			Lifecycle.Kill(f, "Body lost")
		end
		return false
	end
	if not f.Dead and pelvis.Position.Y < workspace.FallenPartsDestroyHeight + 25 then
		Lifecycle.Kill(f, "Fell out of the world")
	end
	return true
end

function Lifecycle.Init()
	Players.CharacterAutoLoads = false
	local function onPlayer(player)
		task.delay(Config.Lifecycle.FirstSpawnDelay, function()
			if player.Parent and not Registry.ByPlayer[player] then
				Lifecycle.Spawn(player)
			end
		end)
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, p in ipairs(Players:GetPlayers()) do
		onPlayer(p)
	end
	Players.PlayerRemoving:Connect(function(player)
		local f = Registry.ByPlayer[player]
		if f then
			Lifecycle.Despawn(f, false)
		end
	end)
end

return Lifecycle
