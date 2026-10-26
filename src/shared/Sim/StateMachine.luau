--[[
	StateMachine: the single authority over a fighter's state. Every controller reads f.State;
	only this module writes it, and only along transitions allowed by StateDefs.
	Listeners run on every transition (sword controller ends strokes, etc.).
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StateDefs = require(ReplicatedStorage.RagdollRonin.StateDefs)
local Runtime = require(script.Parent.Runtime)

local StateMachine = {}
local listeners = {}

function StateMachine.OnTransition(fn)
	table.insert(listeners, fn)
end

function StateMachine.Init(f)
	f.State = "Idle"
	f.StateTime = Runtime.now()
	f.StateData = {}
	f.StateHistory = {}
	f.Model:SetAttribute("State", "Idle")
end

function StateMachine.Elapsed(f)
	return Runtime.now() - f.StateTime
end

function StateMachine.Can(f, to)
	local allowed = StateDefs.Transitions[f.State]
	return allowed ~= nil and allowed[to] == true
end

local function apply(f, to, reason, data)
	local from = f.State
	f.State = to
	f.StateTime = Runtime.now()
	f.StateData = data or {}
	table.insert(f.StateHistory, string.format("%.2f %s->%s (%s)", Runtime.now(), from, to, tostring(reason)))
	if #f.StateHistory > 20 then
		table.remove(f.StateHistory, 1)
	end
	if f.Model.Parent then
		f.Model:SetAttribute("State", to)
		f.Model:SetAttribute("StateReason", string.sub(tostring(reason), 1, 50)) -- (attribute strings are capped at 50)
	end
	f.AnatomyDirty = true
	Runtime.Debug.Transition(f, from, to, reason)
	for _, fn in ipairs(listeners) do
		fn(f, from, to, reason)
	end
end

-- Returns true if the transition happened
function StateMachine.Set(f, to, reason, data)
	if f.State == to then
		return false
	end
	if not StateMachine.Can(f, to) then
		Runtime.Debug.Log("rejected transition", f.Name, f.State, "->", to, reason)
		return false
	end
	apply(f, to, reason, data)
	return true
end

-- Owner mode (server OwnerSync): adopt the state the owning client's simulation is in, whatever
-- the table says - that client is the one simulating the body
function StateMachine.Mirror(f, to, data)
	if f.State == to or f.State == "Dead" then
		return
	end
	apply(f, to, "Owner", data)
end

-- Death bypasses the table (any living state may die)
function StateMachine.ForceDead(f, reason)
	if f.State == "Dead" then
		return
	end
	apply(f, "Dead", reason, {})
end

return StateMachine
