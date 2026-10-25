--[[
	BleedingService: one bounded tick (Config.Blood.TickInterval) for all fighters - no per-wound loops.
	bleed rate = segment wounds (clot exponentially) + damaged organs/vessels (no clotting,
	             proportional to damage) + severed stumps (clot slowly)
	Consequences: capabilities weaken (UpdateCaps), incapacitation, death at the lethal threshold.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.RagdollRonin
local Config = require(Shared.Config)
local Anatomy = require(Shared.Anatomy)
local Registry = require(script.Parent.Registry)
local AnatomyService = require(script.Parent.AnatomyService)
local BloodFX = require(script.Parent.BloodFX)

local BleedingService = {}
local B = Config.Blood

function BleedingService.Tick(dt, killFn)
	for _, f in ipairs(Registry.List()) do
		if not f.Dead then
			local A = f.Anatomy
			local rate = 0
			local woundDecay = math.exp(-B.WoundClotRate * dt)
			for _, rec in pairs(A.Segments) do
				if rec.Bleeding > 0 then
					rec.Bleeding *= woundDecay
					if rec.Bleeding < 0.2 then
						rec.Bleeding = 0
					end
					rate += rec.Bleeding
				end
			end
			for _, o in ipairs(Anatomy.Organs) do
				local h = A.Organs[o.Name].Health
				if h < 100 then
					rate += o.BleedRate * (1 - h / 100)
				end
			end
			local stumpDecay = math.exp(-B.StumpClotRate * dt)
			for _, s in pairs(A.Stumps) do
				s.Rate *= stumpDecay
				rate += s.Rate
			end
			rate = math.min(rate, B.MaxBleedRate)
			local prevBlood = A.Blood
			A.BleedRate = rate
			A.Blood = math.max(0, A.Blood - rate * dt)
			if rate > 0 or prevBlood ~= A.Blood then
				f.AnatomyDirty = true
			end
			AnatomyService.EvaluateVitals(f)
			AnatomyService.UpdateCaps(f)
			BloodFX.Update(f)
			f.Model:SetAttribute("BloodFrac", math.floor(A.Blood / B.Max * 100) / 100)
			local reason = AnatomyService.CheckFatal(f)
			if reason and killFn then
				killFn(f, reason)
			end
		else
			BloodFX.Update(f)
		end
	end
end

return BleedingService
