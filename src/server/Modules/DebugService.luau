--[[
	DebugService: development-only diagnostics, off by default.
	Enable at runtime (server): workspace:SetAttribute("RR_Debug", true)
	When enabled: state transitions and hit reports are printed, contact points are marked in the
	world, and the client overlay shows the fighter's debug attributes.
	Key event attributes (LastBlock, LastInjury, SeverResult, DeathReason, RecoveryPhase...) are
	always written on the fighter model because they are cheap and event-driven.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")
local Config = require(ReplicatedStorage.RagdollRonin.Config)

local DebugService = {}

function DebugService.Init()
	if workspace:GetAttribute("RR_Debug") == nil then
		workspace:SetAttribute("RR_Debug", Config.Debug.Enabled)
	end
end

function DebugService.Enabled()
	return workspace:GetAttribute("RR_Debug") == true
end

function DebugService.Log(...)
	if DebugService.Enabled() then
		print("[RR]", ...)
	end
end

function DebugService.Transition(f, from, to, reason)
	if DebugService.Enabled() and Config.Debug.PrintTransitions then
		print(string.format("[RR] %s: %s -> %s (%s)", f.Name, from, to, tostring(reason)))
	end
end

local markerFolder
function DebugService.Marker(position, color, size)
	if not DebugService.Enabled() then
		return
	end
	if not markerFolder or not markerFolder.Parent then
		markerFolder = Instance.new("Folder")
		markerFolder.Name = "RR_DebugMarkers"
		markerFolder.Parent = workspace
	end
	local p = Instance.new("Part")
	p.Shape = Enum.PartType.Ball
	p.Size = Vector3.one * (size or 0.35)
	p.Anchored = true
	p.CanCollide, p.CanQuery, p.CanTouch, p.CastShadow = false, false, false, false
	p.Material = Enum.Material.Neon
	p.Color = color or Color3.new(1, 0, 0)
	p.Position = position
	p.Parent = markerFolder
	Debris:AddItem(p, Config.Debug.ContactMarkerLifetime)
end

-- Event attribute (always on)
function DebugService.Attr(f, name, value)
	if f.Model and f.Model.Parent then
		f.Model:SetAttribute(name, value)
	end
end

-- High frequency attributes, throttled and only while debugging
function DebugService.Tick(f)
	if not DebugService.Enabled() then
		return
	end
	local now = os.clock()
	if f.NextDebugAttr and now < f.NextDebugAttr then
		return
	end
	f.NextDebugAttr = now + 1 / Config.Debug.AttributeRate
	local m = f.Model
	m:SetAttribute("SwordSpeed", math.floor((f.Attack and f.Attack.TipSpeed or 0) * 10) / 10)
	m:SetAttribute("Balance", math.floor(f.Balance or 0))
	m:SetAttribute("BleedRate", math.floor((f.Anatomy and f.Anatomy.BleedRate or 0) * 10) / 10)
	m:SetAttribute("Blood", math.floor(f.Anatomy and f.Anatomy.Blood or 0))
	m:SetAttribute("LegSupport", math.floor((f.Caps and f.Caps.LegSupport or 0) * 100) / 100)
	m:SetAttribute("Height", f.Ground and math.floor(f.Ground.Height * 100) / 100 or -1)
end

return DebugService
