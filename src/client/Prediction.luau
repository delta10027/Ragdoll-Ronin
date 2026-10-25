--[[
	Prediction (only when Workspace.AuthorityMode = Server): runs your own fighter's controllers
	locally inside RunService:BindToSimulation - the same balance/state, sword aim and motor step
	the server runs, fed by the same InputActions - so movement and the sword respond on the frame
	the input happens instead of a network round trip later.

	The engine compares this prediction with the server's authoritative state and, on a mismatch
	(a hit, a block, a stagger: things only the server decides), rolls back and resimulates.
	SimState keeps the controllers' Lua-side state in attributes so it rolls back too.
	Other fighters are not predicted (their inputs are unknown here); they show the server's state.
]]
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Sim = ReplicatedStorage:WaitForChild("RagdollRonin"):WaitForChild("Sim")
local Runtime = require(Sim:WaitForChild("Runtime"))

local Prediction = {}

local state = {
	Enabled = false,
	Model = nil,
	Fighter = nil,
	Dirty = false,
	Connections = {},
	Rollbacks = 0,
	RollbackRate = 0,
}

local SimState, SimInput, StateMachine, BalanceController, SwordController, MotorController

local function rebuild(ctx)
	local model = state.Model
	if not model or not model.Parent then
		state.Fighter = nil
		return
	end
	local f = SimState.BuildClient(model, ctx.Player)
	if f then
		state.Fighter = f
		state.Dirty = false
	end
end

local function step(ctx, dt)
	local f = state.Fighter
	if not f or not SimState.Load(f) then
		return
	end
	local inp = SimInput.Read(ctx.Player, f.Input)
	BalanceController.Update(f, dt, inp)
	SwordController.UpdateAim(f, dt, inp)
	MotorController.Apply(f, dt, inp)
	SimState.Store(f)
end

local function setPrediction(model, mode)
	pcall(RunService.SetPredictionMode, RunService, model, mode)
end

function Prediction.Init(ctx)
	ctx.Prediction = state
	ctx.PredictionStatus = function()
		return Prediction.Status(ctx)
	end
	if not Runtime.ServerAuthority then
		return
	end
	state.Enabled = true
	SimState = require(Sim.SimState)
	SimInput = require(Sim.SimInput)
	StateMachine = require(Sim.StateMachine)
	BalanceController = require(Sim.BalanceController)
	SwordController = require(Sim.SwordController)
	MotorController = require(Sim.MotorController)
	StateMachine.OnTransition(function(f, from, to)
		SwordController.OnTransition(f, from, to)
	end)

	local lastErr = 0
	RunService:BindToSimulation(function(dt)
		local ok, err = pcall(step, ctx, dt)
		if not ok and os.clock() - lastErr > 2 then
			lastErr = os.clock()
			warn("[RR] prediction step error: " .. tostring(err))
		end
	end, Enum.StepFrequency.Hz60)

	RunService.Rollback:Connect(function()
		state.Rollbacks += 1
		if state.Fighter then
			SimState.OnRollback(state.Fighter)
		end
	end)

	-- other fighters are shown as the server has them, never predicted
	local function consider(inst)
		if inst:IsA("Model") and inst:GetAttribute("RR_Fighter") == true and inst ~= state.Model then
			setPrediction(inst, Enum.PredictionMode.Off)
		end
	end
	workspace.ChildAdded:Connect(consider)
	for _, c in ipairs(workspace:GetChildren()) do
		consider(c)
	end

	-- (re)build the fighter record outside the simulation whenever the body's structure changes
	local window, windowStart = 0, os.clock()
	RunService.RenderStepped:Connect(function()
		if state.Model and (state.Dirty or not state.Fighter) then
			rebuild(ctx)
		end
		local now = os.clock()
		if now - windowStart >= 1 then
			state.RollbackRate = state.Rollbacks - window
			window, windowStart = state.Rollbacks, now
		end
	end)
end

function Prediction.OnNewFighter(ctx, model)
	if not state.Enabled then
		return
	end
	for _, c in ipairs(state.Connections) do
		c:Disconnect()
	end
	table.clear(state.Connections)
	state.Model = model
	state.Fighter = nil
	state.Dirty = true
	setPrediction(model, Enum.PredictionMode.On)
	local function dirty()
		state.Dirty = true
	end
	table.insert(state.Connections, model.DescendantAdded:Connect(dirty))
	table.insert(state.Connections, model.DescendantRemoving:Connect(dirty))
end

-- for the debug overlay
function Prediction.Status(ctx)
	if not state.Enabled then
		return "off (Workspace.AuthorityMode is not Server)"
	end
	return string.format("%s, rollbacks/s %d", state.Fighter and "predicting" or "waiting for fighter", state.RollbackRate)
end

return Prediction
