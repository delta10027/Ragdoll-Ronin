--[[
	Spacing: fighters keep a minimum distance from each other (Config.Movement.PersonalSpace), so a
	duel is fought at sword's length instead of by walking into the other body. Inside that distance
	the commanded walk loses its component toward the other fighter and gains a gentle push away;
	both fighters do this, so they part evenly. Only upright fighters keep their distance: you can
	still close in on someone who is down.

	Shared: the server and a predicting client run the same rule (a client sees the other fighter's
	replicated position, so near another fighter it may be corrected slightly).
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.RagdollRonin
local Config = require(Shared.Config)
local StateDefs = require(Shared.StateDefs)

local Spacing = {}

local M = Config.Movement
local fighters = {}

local function consider(inst)
	if inst:IsA("Model") and inst:GetAttribute("RR_Fighter") == true then
		fighters[inst] = true
	end
end
workspace.ChildAdded:Connect(consider)
workspace.ChildRemoved:Connect(function(inst)
	fighters[inst] = nil
end)
for _, c in ipairs(workspace:GetChildren()) do
	consider(c)
end

-- vel: commanded horizontal velocity (world). Returns it adjusted for nearby upright fighters.
function Spacing.Adjust(f, vel)
	local pelvis = f.Parts.LowerTorso
	if not pelvis then
		return vel
	end
	local me = pelvis.Position
	for model in pairs(fighters) do
		if model ~= f.Model then
			local st = model:GetAttribute("State")
			local other = st and StateDefs.Upright[st] and model:FindFirstChild("LowerTorso")
			if other then
				local d = Vector3.new(me.X - other.Position.X, 0, me.Z - other.Position.Z)
				local dist = d.Magnitude
				if dist < M.PersonalSpace and dist > 1e-3 then
					local away = d / dist
					local toward = -vel:Dot(away)
					if toward > 0 then
						vel += away * toward
					end
					vel += away * math.min(M.WalkSpeed, (M.PersonalSpace - dist) * M.PersonalSpacePush)
				end
			end
		end
	end
	return vel
end

return Spacing
