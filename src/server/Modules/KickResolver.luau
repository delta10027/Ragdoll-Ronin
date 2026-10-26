--[[
	KickResolver: lands teeps (Config.Kick, Shared.Sim.Kick). Post-physics, for every fighter in the
	Kicking state whose kicking foot is out in front of the pelvis (ActiveReach), the foot's volume
	is checked against the other fighters' bodies and blades. Each kick lands on one fighter, once.

	  blocked  the target holds a flat guard close to the centre of the circle (cursor radius within
	           BlockMaxRadius: the cross block in front of the chin) and faces the kick. The teep is
	           checked: the defender is only nudged, the kicker bounces off and is staggered briefly.
	  landed   any other target: the whole body is shoved back (KnockbackDV), the target staggers and
	           loses balance; with no balance left it is knocked down. A teep is a push: no damage.
	The pelvis' replicated facing is used (not FacingYaw), so this also works for a fighter its
	owner simulates (Owner mode); impulses and reactions reach the owner through Runtime.Impulse
	and OwnerSync.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.RagdollRonin
local Config = require(Shared.Config)
local StateDefs = require(Shared.StateDefs)
local Util = require(Shared.Sim.Util)
local Runtime = require(Shared.Sim.Runtime)
local Kick = require(Shared.Sim.Kick)
local BalanceController = require(Shared.Sim.BalanceController)
local Registry = require(script.Parent.Registry)
local Feedback = require(script.Parent.Feedback)
local DebugService = require(script.Parent.DebugService)

local KickResolver = {}
local K = Config.Kick

local params = OverlapParams.new()
params.FilterType = Enum.RaycastFilterType.Exclude
params.CollisionGroup = "RR_HitQuery"

local function facingOf(f)
	local pelvis = f.Parts.LowerTorso
	return Util.unit(Util.flat(pelvis.CFrame.LookVector), Vector3.zAxis)
end

-- velocity change for the whole body (each part by its own mass, so welded parts sharing an
-- assembly are not pushed twice)
local function shove(f, dv)
	for _, part in pairs(f.Parts) do
		if part.Parent then
			Runtime.Impulse(part, dv * part:GetMass())
		end
	end
end

local function blocks(def, dir)
	if def.State ~= "Blocking" or not def.Block.Active or not def.Sword then
		return false
	end
	local aim = def.Aim
	if math.sqrt(aim.U * aim.U + aim.V * aim.V) > K.BlockMaxRadius then
		return false -- side and high guards do not cover the belly
	end
	return facingOf(def):Dot(-dir) > 0.3
end

local function resolve(att, def, dir, at)
	DebugService.Marker(at, Color3.fromRGB(255, 220, 60), 0.4)
	if blocks(def, dir) then
		shove(def, dir * K.BlockedPushDV)
		def.Balance -= K.BlockedBalanceCost
		shove(att, -dir * K.BlockedPushDV)
		BalanceController.Stagger(att, K.BlockedStaggerTime, -dir, "Teep blocked")
		Feedback.Send(att, "KickBlocked", {})
		Feedback.Send(def, "BlockedKick", {})
		DebugService.Log(att.Name, "teep blocked by", def.Name)
		return
	end
	shove(def, dir * K.KnockbackDV + Vector3.new(0, K.KnockbackUp, 0))
	if StateDefs.Upright[def.State] then
		def.Balance -= K.HitBalanceCost
		if def.Balance <= 0 then
			BalanceController.KnockDown(def, dir, 10, "Teeped over")
		else
			BalanceController.Stagger(def, K.HitStaggerTime, dir, "Teep")
		end
	end
	Feedback.Send(att, "KickLanded", { Target = def.Name })
	Feedback.Send(def, "Kicked", {})
	DebugService.Log(att.Name, "teep landed on", def.Name, "balance", def.Balance)
end

function KickResolver.Step(f)
	if f.Dead or f.State ~= "Kicking" then
		return
	end
	local foot = f.Parts[Kick.Leg .. "Foot"]
	local pelvis = f.Parts.LowerTorso
	if not foot or not foot.Parent or not pelvis then
		return
	end
	if f.KickStamp ~= f.StateTime then -- a new kick
		f.KickStamp = f.StateTime
		f.KickLanded = false
	end
	if f.KickLanded then
		return
	end
	local dir = facingOf(f)
	if (foot.Position - pelvis.Position):Dot(dir) < K.ActiveReach then
		return
	end
	params.FilterDescendantsInstances = { f.Model }
	for _, part in ipairs(workspace:GetPartBoundsInRadius(foot.Position, K.FootRadius, params)) do
		local target = Registry.FromPart(part)
		if target and target ~= f and not target.Dead then
			f.KickLanded = true
			resolve(f, target, dir, foot.Position)
			return
		end
	end
end

return KickResolver
