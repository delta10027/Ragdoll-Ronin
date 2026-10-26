--[[
	BloodFX: bounded server-side visuals (replicate to everyone).
	  * wound marks at contact points (drawn by the clients, see WoundMark)
	  * one particle emitter per bleeding source, rate driven by the bleeding model
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.RagdollRonin.Config)

local BloodFX = {}
local BLOOD = Color3.fromRGB(110, 8, 12)

-- Wound marks are drawn by every client (client WoundMarks), welded where the blade went in: a
-- part the server welded to a body would join that body's assembly, which resets its network
-- ownership (a hitch for the player who was hit, on every hit) and rebuilds their fighter record.
local woundRemote = ReplicatedStorage.RagdollRonin.Remotes.WoundEvent
function BloodFX.WoundMark(f, part, position, normal, severity)
	if not part or not part.Parent then
		return
	end
	local sev = math.clamp(severity, 0, 1)
	local size = Vector3.new(0.08 + 0.12 * sev, 0.25 + 0.35 * sev, 0.03)
	local n = (normal and normal.Magnitude > 0.5) and normal.Unit or Vector3.yAxis
	local cf = CFrame.lookAt(position, position + n) * CFrame.Angles(0, 0, math.random() * math.pi)
	woundRemote:FireAllClients(part, part.CFrame:ToObjectSpace(cf), size)
end

local function newEmitter(parent)
	local pe = Instance.new("ParticleEmitter")
	pe.Name = "Blood"
	pe.Texture = "rbxasset://textures/particles/smoke_main.dds"
	pe.Color = ColorSequence.new(BLOOD)
	pe.LightEmission = 0
	pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.12), NumberSequenceKeypoint.new(1, 0.04) })
	pe.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.1), NumberSequenceKeypoint.new(1, 0.8) })
	pe.Lifetime = NumberRange.new(0.4, 0.8)
	pe.Speed = NumberRange.new(2, 6)
	pe.SpreadAngle = Vector2.new(35, 35)
	pe.Acceleration = Vector3.new(0, -40, 0)
	pe.Rate = 0
	pe.Parent = parent
	return pe
end

-- key: segment name or "stump:<boundary>"
function BloodFX.Source(f, key, part, worldCF)
	f.BleedSources = f.BleedSources or {}
	local src = f.BleedSources[key]
	if src and src.Emitter.Parent then
		return src
	end
	local count = 0
	for _ in pairs(f.BleedSources) do
		count += 1
	end
	if count >= Config.Anatomy.MaxBleedEmitters then
		return nil
	end
	local att = Instance.new("Attachment")
	att.Name = "BleedAtt"
	att.CFrame = part.CFrame:ToObjectSpace(worldCF)
	att.Parent = part
	src = { Emitter = newEmitter(att), Attachment = att }
	f.BleedSources[key] = src
	return src
end

function BloodFX.Burst(part, position, amount)
	if not part or not part.Parent then
		return
	end
	local att = Instance.new("Attachment")
	att.CFrame = part.CFrame:ToObjectSpace(CFrame.new(position))
	att.Parent = part
	local pe = newEmitter(att)
	pe.Speed = NumberRange.new(6, 14)
	pe:Emit(math.clamp(math.floor(amount), 4, 40))
	game:GetService("Debris"):AddItem(att, 1.5)
end

-- Drive emitter rates from the bleeding model (called from the bleed tick)
function BloodFX.Update(f)
	if not f.BleedSources then
		return
	end
	local A = f.Anatomy
	for key, src in pairs(f.BleedSources) do
		if not src.Emitter.Parent then
			f.BleedSources[key] = nil
		else
			local rate
			local boundary = key:match("^stump:(.+)$")
			if boundary then
				local s = A.Stumps[boundary]
				rate = s and s.Rate or 0
			else
				local rec = A.Segments[key]
				rate = rec and rec.Bleeding or 0
			end
			if f.Dead then
				rate *= 0.3
			end
			src.Emitter.Rate = math.clamp(rate * 0.35, 0, 60)
		end
	end
end

return BloodFX
