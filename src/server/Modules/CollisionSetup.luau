--[[
	Collision groups.
	  RR_Core   torso/pelvis/neck/head. Collide with world and with OTHER fighters' cores (bodies shove).
	            Own core pairs are excluded with NoCollisionConstraints.
	  RR_Limb   arms/legs. Collide with world only: no self-collision, no limb tangling between fighters.
	  RR_Sword  visual sword parts never physically collide (strikes are resolved by swept queries).
	  RR_Blade  one invisible collider per sword: collides only with other RR_Blade colliders, so
	            swords physically block each other (no world, body or debris contact).
	  RR_Debris severed limbs, dropped swords, corpses: world + other debris only.
	  RR_HitQuery    raycast group for blade sweeps: sees Core, Limb, Sword only (ignores world/debris).
	  RR_GroundQuery raycast group for ground probes and camera: sees the world only.
]]
local PhysicsService = game:GetService("PhysicsService")

local CollisionSetup = {}

local G = {
	Core = "RR_Core",
	Limb = "RR_Limb",
	Sword = "RR_Sword",
	Blade = "RR_Blade",
	Debris = "RR_Debris",
	HitQuery = "RR_HitQuery",
	GroundQuery = "RR_GroundQuery",
}
CollisionSetup.Groups = G

function CollisionSetup.Init()
	for _, name in pairs(G) do
		if not PhysicsService:IsCollisionGroupRegistered(name) then
			PhysicsService:RegisterCollisionGroup(name)
		end
	end
	local function set(a, b, v)
		PhysicsService:CollisionGroupSetCollidable(a, b, v)
	end
	local D = "Default"
	-- Core
	set(G.Core, D, true)
	set(G.Core, G.Core, true)
	set(G.Core, G.Limb, false)
	set(G.Core, G.Sword, false)
	set(G.Core, G.Debris, false)
	set(G.Core, G.HitQuery, true)
	set(G.Core, G.GroundQuery, false)
	-- Limb
	set(G.Limb, D, true)
	set(G.Limb, G.Limb, false)
	set(G.Limb, G.Sword, false)
	set(G.Limb, G.Debris, false)
	set(G.Limb, G.HitQuery, true)
	set(G.Limb, G.GroundQuery, false)
	-- Sword
	set(G.Sword, D, false)
	set(G.Sword, G.Sword, false)
	set(G.Sword, G.Debris, false)
	set(G.Sword, G.HitQuery, true)
	set(G.Sword, G.GroundQuery, false)
	-- Blade colliders: other blades only
	set(G.Blade, D, false)
	set(G.Blade, G.Blade, true)
	set(G.Blade, G.Core, false)
	set(G.Blade, G.Limb, false)
	set(G.Blade, G.Sword, false)
	set(G.Blade, G.Debris, false)
	set(G.Blade, G.HitQuery, false)
	set(G.Blade, G.GroundQuery, false)
	-- Debris
	set(G.Debris, D, true)
	set(G.Debris, G.Debris, true)
	set(G.Debris, G.HitQuery, false)
	set(G.Debris, G.GroundQuery, false)
	-- Queries
	set(G.HitQuery, D, false)
	set(G.HitQuery, G.HitQuery, false)
	set(G.HitQuery, G.GroundQuery, false)
	set(G.GroundQuery, D, true)
	set(G.GroundQuery, G.GroundQuery, false)
end

return CollisionSetup
