--[[
	HitDetection: continuous (swept) blade collision. Touched events are not used.

	Between the blade's pose after the previous physics step and its pose now, the motion is
	subdivided (CFrame:Lerp = linear position + slerped rotation, so arcs are followed) so the
	tip never travels more than SubstepDistance per substep. For every substep, each blade sample
	point (guard -> tip, edge side) casts a ray from its old to its new world position.

	Rays use the RR_HitQuery collision group, which only sees fighter bodies and blades (never the
	world or debris), and exclude the attacker's own model.

	Returns hits sorted by time-of-contact T in [0,1] across the frame, earliest per part.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.RagdollRonin.Config)
local SwordBuilder = require(script.Parent.SwordBuilder)
local Registry = require(script.Parent.Registry)

local HitDetection = {}
local C = Config.Combat
local SAMPLES = SwordBuilder.SamplePoints()

local params = RaycastParams.new()
params.FilterType = Enum.RaycastFilterType.Exclude
params.CollisionGroup = "RR_HitQuery"
params.IgnoreWater = true

-- Raycasts never report a part they START inside. A blade that is already resting in an
-- opponent's guard volume (e.g. wound up right next to it) would pass straight through the guard,
-- so guard volumes of blocking fighters are also tested with an explicit point-in-box check.
local function guardVolumes(f)
	local list = {}
	for _, other in pairs(Registry.ById) do
		if other ~= f and not other.Dead and other.Sword and other.Block and other.Block.Active then
			table.insert(list, other.Sword.ParryZone)
		end
	end
	return list
end

local function inside(zone, p)
	local l = zone.CFrame:PointToObjectSpace(p)
	local h = zone.Size / 2
	return math.abs(l.X) <= h.X and math.abs(l.Y) <= h.Y and math.abs(l.Z) <= h.Z
end

-- Broadphase: can anything this blade could hit be near it at all? (a fighter's body and blade
-- stay within REACH of its pelvis). Saves the raycasts for every swing nobody is in range of.
local REACH = 8 + Config.Sword.BladeLength
local function anyoneNear(f, center, radius)
	for _, other in pairs(Registry.ById) do
		local pelvis = other ~= f and not other.Removed and other.Parts.LowerTorso
		if pelvis and (pelvis.Position - center).Magnitude < radius + REACH then
			return true
		end
	end
	return false
end

function HitDetection.Sweep(f, sweep)
	local prevCF, cf, dt = sweep.PrevCF, sweep.CF, sweep.Dt
	local tip = SAMPLES[#SAMPLES]
	local travel = (cf:PointToWorldSpace(tip) - prevCF:PointToWorldSpace(tip)).Magnitude
	if not anyoneNear(f, cf.Position, travel + Config.Sword.BladeLength) then
		return {}
	end
	params.FilterDescendantsInstances = { f.Model }
	local zones = guardVolumes(f)
	local n = math.clamp(math.ceil(travel / C.SubstepDistance), 1, C.MaxSubsteps)

	local earliest = {} -- part -> hit
	for i = 1, n do
		local cfA = prevCF:Lerp(cf, (i - 1) / n)
		local cfB = prevCF:Lerp(cf, i / n)
		for k, lp in ipairs(SAMPLES) do
			local a = cfA:PointToWorldSpace(lp)
			local b = cfB:PointToWorldSpace(lp)
			local d = b - a
			local len = d.Magnitude
			for _, zone in ipairs(zones) do
				if inside(zone, a) or inside(zone, b) then
					local t = (i - 1) / n + 0.001 * k
					local old = earliest[zone]
					if not old or t < old.T then
						earliest[zone] = {
							Part = zone,
							Position = inside(zone, a) and a or b,
							Normal = Vector3.yAxis,
							T = t,
							Sample = k,
							PointVel = (cf:PointToWorldSpace(lp) - prevCF:PointToWorldSpace(lp)) / dt,
						}
					end
				end
			end
			if len > 1e-3 then
				local res = workspace:Raycast(a, d, params)
				if res then
					local t = ((i - 1) + (res.Position - a).Magnitude / len) / n
					local old = earliest[res.Instance]
					if not old or t < old.T then
						earliest[res.Instance] = {
							Part = res.Instance,
							Position = res.Position,
							Normal = res.Normal,
							T = t,
							Sample = k,
							-- world velocity of this blade point over the frame
							PointVel = (cf:PointToWorldSpace(lp) - prevCF:PointToWorldSpace(lp)) / dt,
						}
					end
				end
			end
		end
	end
	local hits = {}
	for _, h in pairs(earliest) do
		table.insert(hits, h)
	end
	table.sort(hits, function(x, y)
		return x.T < y.T
	end)
	return hits
end

HitDetection.SampleCount = #SAMPLES
return HitDetection
