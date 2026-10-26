--[[
	Prediction (only when Workspace.AuthorityMode = Server): runs your own fighter's controllers
	locally inside RunService:BindToSimulation - the same balance/state, sword aim and motor step
	the server runs, fed by the same InputActions - so movement and the sword respond on the frame
	the input happens instead of a network round trip later.

	The engine compares this prediction with the server's authoritative state and, on a mismatch
	(a hit, a block, a stagger: things only the server decides), rolls back and resimulates.
	SimState keeps the controllers' Lua-side state in attributes so it rolls back too.
	Other fighters are not predicted (their inputs are unknown here); they show the server's state,
	which is slightly in the past. Their blade colliders are switched off in this client's
	simulation: colliding the predicted sword with a stale copy of theirs would predict a clash at
	the wrong place and then be corrected again. Clashes and blocks are decided by the server and
	arrive as one correction instead.

	Owner mode (Config.Network.Mode = "Owner", AuthorityMode Automatic): this client owns its
	fighter's physics, so the same step simply runs here in PreSimulation, fed straight from
	InputController, and nothing is rolled back. What the server decides about the fighter (hits'
	reactions, binds, recoil, death, impulses) arrives over the SimEvent remote and is applied at the
	start of the next step; the input packets report this simulation back (InputController,
	server OwnerSync). Other fighters' blades stay solid: they are the server's, so meeting one
	stops this sword physically right here.
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
	Owner = false, -- Owner mode
	Ack = 0, -- last server event applied (Owner mode)
	Pending = {},
	InitModel = nil,
	RecoverPending = false,
}

local SimState, SimInput, StateMachine, BalanceController, SwordController, MotorController
local Config = require(ReplicatedStorage.RagdollRonin:WaitForChild("Config"))

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

-- Owner mode: apply what the server decided (OwnerSync.Flush) to this client's simulation
local function applyServerEvents(f)
	local now = Runtime.now()
	local pending = state.Pending
	state.Pending = {}
	for _, ev in ipairs(pending) do
		if ev.Id == f.Id and ev.Seq then
			local st = ev.State
			if st then
				local data = {}
				for k, v in pairs(st.Data or {}) do
					data[k] = v
				end
				if data.Left then
					data.Until = now + data.Left
					data.Left = nil
				end
				if st.To == "Dead" then
					StateMachine.ForceDead(f, st.Reason)
				elseif f.State == st.To then
					for k, v in pairs(data) do -- e.g. a stagger made longer
						f.StateData[k] = v
					end
				else
					StateMachine.Set(f, st.To, st.Reason, data)
				end
			end
			if ev.Balance then
				f.Balance = math.clamp(f.Balance + ev.Balance, 0, Config.Balance.Max)
			end
			if ev.Recoil then
				f.Attack.RecoilUntil = math.max(f.Attack.RecoilUntil or 0, now + ev.Recoil)
			end
			if ev.Bind and f.State == "Attacking" then
				local aim = f.Aim
				aim.U, aim.V, aim.VU, aim.VV = ev.Bind.U, ev.Bind.V, 0, 0
				aim.Bind = ev.Bind
			end
			state.Ack = math.max(state.Ack, ev.Seq)
		end
	end
end

local function ownerInput(ctx, f)
	local s = ctx.Input
	local i = f.Input
	if s then
		i.Move = s.Move
		i.Yaw = ctx.Camera and ctx.Camera.Yaw or i.Yaw
		i.AimU, i.AimV = s.AimU, s.AimV
		i.M1, i.M2, i.Kick = s.M1, s.M2, s.Kick
	end
	return i
end

local function ownerStep(ctx, dt)
	local f = state.Fighter
	if not f or not SimState.Load(f) then
		return
	end
	if state.InitModel ~= state.Model then
		-- first step on this body: the server's starting times are on the server's clock
		state.InitModel = state.Model
		f.StateTime = Runtime.now()
		f.Attack.RecoilUntil = 0
		f.Attack.ReleaseTime = nil
		f.Block.StartTime = 0
		f.KickReadyAt = 0
	end
	applyServerEvents(f)
	if state.RecoverPending then
		state.RecoverPending = false
		BalanceController.RequestRecover(f)
	end
	local inp = ownerInput(ctx, f)
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
	if not Runtime.ServerAuthority and not Runtime.OwnerPhysics then
		return
	end
	state.Enabled = true
	state.Owner = Runtime.OwnerPhysics
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
	if state.Owner then
		ctx.Remotes:WaitForChild("SimEvent").OnClientEvent:Connect(function(ev)
			if typeof(ev) ~= "table" then
				return
			end
			if ev.Impulse then
				local part = ev.Impulse.Part
				if typeof(part) == "Instance" and part:IsA("BasePart") and typeof(ev.Impulse.J) == "Vector3" then
					part:ApplyImpulse(ev.Impulse.J)
				end
			elseif ev.Seq then
				table.insert(state.Pending, ev)
			end
		end)
		RunService.PreSimulation:Connect(function(dt)
			local ok, err = pcall(ownerStep, ctx, dt)
			if not ok and os.clock() - lastErr > 2 then
				lastErr = os.clock()
				warn("[RR] owner step error: " .. tostring(err))
			end
		end)
		RunService.RenderStepped:Connect(function()
			if state.Model and (state.Dirty or not state.Fighter) then
				rebuild(ctx)
			end
		end)
		return
	end
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

	-- other fighters are shown as the server has them, never predicted, and their swords do not
	-- collide with the predicted one locally
	local function consider(inst)
		if inst:IsA("Model") and inst:GetAttribute("RR_Fighter") == true and inst ~= state.Model then
			setPrediction(inst, Enum.PredictionMode.Off)
			local katana = inst:FindFirstChild("Katana")
			local collider = katana and katana:FindFirstChild("BladeCollider")
			if collider then
				collider.CanCollide = false
			end
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
	state.Ack = 0
	state.Pending = {}
	if not state.Owner then
		setPrediction(model, Enum.PredictionMode.On)
	end
	local function dirty()
		state.Dirty = true
	end
	table.insert(state.Connections, model.DescendantAdded:Connect(dirty))
	table.insert(state.Connections, model.DescendantRemoving:Connect(dirty))
end

-- for the debug overlay
function Prediction.Status(ctx)
	if not state.Enabled then
		return "off (Config.Network.Mode is Server)"
	end
	if state.Owner then
		return string.format("owner (%s), server events applied %d", state.Fighter and "simulating" or "waiting for fighter", state.Ack)
	end
	return string.format("%s, rollbacks/s %d", state.Fighter and "predicting" or "waiting for fighter", state.RollbackRate)
end

return Prediction
