--[[
	Ragdoll Ronin - combat/character state machine definition (shared).
	The server owns the live state; clients read it from the fighter model's "State" attribute.
]]

local StateDefs = {}

StateDefs.States = {
	"Idle", "Moving", "Attacking", "Blocking", "Kicking", "Staggered", "OffBalance",
	"Falling", "GroundedRecovery", "Recovering", "SeverelyInjured", "Dead",
}

local function set(list)
	local t = {}
	for _, v in ipairs(list) do
		t[v] = true
	end
	return t
end

-- Allowed transitions. Anything not listed is rejected (and logged in debug mode).
StateDefs.Transitions = {
	Idle = set({ "Moving", "Attacking", "Blocking", "Kicking", "Staggered", "OffBalance", "Falling", "SeverelyInjured", "Dead" }),
	Moving = set({ "Idle", "Attacking", "Blocking", "Kicking", "Staggered", "OffBalance", "Falling", "SeverelyInjured", "Dead" }),
	Attacking = set({ "Idle", "Moving", "Blocking", "Kicking", "Staggered", "OffBalance", "Falling", "SeverelyInjured", "Dead" }),
	Blocking = set({ "Idle", "Moving", "Attacking", "Kicking", "Staggered", "OffBalance", "Falling", "SeverelyInjured", "Dead" }),
	Kicking = set({ "Idle", "Moving", "Staggered", "OffBalance", "Falling", "SeverelyInjured", "Dead" }),
	Staggered = set({ "Idle", "OffBalance", "Falling", "SeverelyInjured", "Dead" }),
	OffBalance = set({ "Idle", "Staggered", "Falling", "SeverelyInjured", "Dead" }),
	Falling = set({ "GroundedRecovery", "SeverelyInjured", "Dead" }),
	GroundedRecovery = set({ "Recovering", "Falling", "SeverelyInjured", "Dead" }),
	Recovering = set({ "Idle", "Falling", "GroundedRecovery", "SeverelyInjured", "Dead" }),
	SeverelyInjured = set({ "GroundedRecovery", "Falling", "Dead" }),
	Dead = set({}),
}

-- States in which the body is actively held upright (support force + upright torque)
StateDefs.Upright = set({ "Idle", "Moving", "Attacking", "Blocking", "Kicking", "Staggered", "OffBalance" })
-- States in which the fighter is on (or going to) the ground
StateDefs.Ground = set({ "Falling", "GroundedRecovery", "SeverelyInjured" })
-- States that accept player combat/move intent directly
StateDefs.Controllable = set({ "Idle", "Moving", "Attacking", "Blocking" })

return StateDefs
