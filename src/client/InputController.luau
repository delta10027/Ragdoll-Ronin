--[[
	InputController: samples input and sends INTENT to the server (~60 Hz, unreliable channel).

	Mouse mapping (mouse is locked to the screen centre, raw deltas are used, so it works the same
	in every mouse mode and on any resolution):
	  * no button held: mouse turns the camera; the fighter turns to face the camera yaw
	  * M1 held: mouse moves the combat cursor (unit disk) -> continuous sword control
	  * M2 held: mouse moves the combat cursor -> guard placement
	  * releasing both: the cursor relaxes back to the ready stance (the server does the same)
	  * C: teep (push kick). A tap is held for KICK_HOLD seconds so the simulation always sees it.
	  * CTRL (held): crouch
	  * 1: draw / sheathe the sword (CombatAction "Sheath")
	Packet: seq, moveX, moveZ, yaw, aimU, aimV, buttons (bit0 = M1, bit1 = M2, bit2 = kick, bit3 = crouch)
]]
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage:WaitForChild("RagdollRonin"):WaitForChild("Config"))
local CameraController = require(script.Parent.CameraController)
local Sim = ReplicatedStorage:WaitForChild("RagdollRonin"):WaitForChild("Sim")
local Runtime = require(Sim:WaitForChild("Runtime"))
local SimInput = require(Sim:WaitForChild("SimInput"))
local SwordController = require(Sim:WaitForChild("SwordController"))

local InputController = {}
local A = Config.Aim
local KICK_HOLD = 0.12

function InputController.Init(ctx)
	local s = {
		AimU = A.ReadyU,
		AimV = A.ReadyV,
		M1 = false,
		M2 = false,
		Kick = false,
		KickUntil = 0,
		Crouch = false,
		Move = Vector3.zero,
		History = {},
		Seq = 0,
		LastSend = 0,
		LastButtons = 0,
		PressTime = 0,
	}
	ctx.Input = s

	UserInputService.InputBegan:Connect(function(io, processed)
		if processed or GuiService.MenuIsOpen then
			return
		end
		if io.UserInputType == Enum.UserInputType.MouseButton1 then
			s.M1 = true
			s.PressTime = os.clock()
		elseif io.UserInputType == Enum.UserInputType.MouseButton2 then
			s.M2 = true
			s.PressTime = os.clock()
		elseif io.KeyCode == Enum.KeyCode.Space then
			ctx.Remotes.CombatAction:FireServer("Recover")
			if ctx.Prediction and ctx.Prediction.Owner then
				ctx.Prediction.RecoverPending = true -- this client runs its own fighter (Owner mode)
			end
		elseif io.KeyCode == Enum.KeyCode.C then
			s.KickUntil = os.clock() + KICK_HOLD
		elseif io.KeyCode == Enum.KeyCode.One then
			ctx.Remotes.CombatAction:FireServer("Sheath")
		elseif io.KeyCode == Enum.KeyCode.V then
			CameraController.ToggleFront(ctx)
		end
	end)
	UserInputService.InputEnded:Connect(function(io)
		if io.UserInputType == Enum.UserInputType.MouseButton1 then
			s.M1 = false
		elseif io.UserInputType == Enum.UserInputType.MouseButton2 then
			s.M2 = false
		end
	end)
end

local function key(k)
	return UserInputService:IsKeyDown(k) and 1 or 0
end

function InputController.Update(ctx, dt)
	local s = ctx.Input
	local blocked = GuiService.MenuIsOpen or UserInputService:GetFocusedTextBox() ~= nil
	if GuiService.MenuIsOpen then
		s.M1, s.M2 = false, false
	end

	s.Kick = not blocked and os.clock() < s.KickUntil
	s.Crouch = not blocked and (UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) or UserInputService:IsKeyDown(Enum.KeyCode.RightControl))
	local delta = blocked and Vector2.zero or UserInputService:GetMouseDelta()
	if s.M1 or s.M2 then
		s.AimU += delta.X * A.ClientSensitivity
		s.AimV -= delta.Y * A.ClientSensitivity
		local r = math.sqrt(s.AimU * s.AimU + s.AimV * s.AimV)
		if r > 1 then
			s.AimU, s.AimV = s.AimU / r, s.AimV / r
		end
		-- a blocked attack: the cursor stops where the blades met and can only be drawn back
		local bind = s.M1 and InputController.Bind(ctx)
		if bind then
			s.AimU, s.AimV = SwordController.ConstrainCursor(s.AimU, s.AimV, bind)
		end
	else
		CameraController.Rotate(ctx, delta.X, delta.Y)
		local k = math.min(1, 8 * dt)
		s.AimU += (A.ReadyU - s.AimU) * k
		s.AimV += (A.ReadyV - s.AimV) * k
	end

	local mv = Vector3.zero
	if not blocked then
		local fwd = key(Enum.KeyCode.W) - key(Enum.KeyCode.S)
		local right = key(Enum.KeyCode.D) - key(Enum.KeyCode.A)
		mv = Vector3.new(right, 0, -fwd)
		if mv.Magnitude > 0 then
			mv = mv.Unit
		end
	end
	s.Move = CFrame.Angles(0, ctx.Camera.Yaw, 0):VectorToWorldSpace(mv)

	local now = os.clock()
	table.insert(s.History, { t = now, u = s.AimU, v = s.AimV })
	while #s.History > 2 and now - s.History[1].t > 0.3 do
		table.remove(s.History, 1)
	end

	-- server authority: intent goes through InputActions every frame (predicted locally, replayed
	-- on the server) instead of the RemoteEvent
	if Runtime.ServerAuthority then
		SimInput.Fire(ctx.Player, s.Move, ctx.Camera.Yaw, s.AimU, s.AimV, s.M1, s.M2, s.Kick, s.Crouch)
		return
	end

	-- a button press/release goes out immediately instead of waiting for the next send slot
	local buttons = (s.M1 and 1 or 0) + (s.M2 and 2 or 0) + (s.Kick and 4 or 0) + (s.Crouch and 8 or 0)
	if buttons ~= s.LastButtons or now - s.LastSend >= 1 / Config.Network.ClientSendRate then
		s.LastButtons = buttons
		s.LastSend = now
		s.Seq += 1
		local p = ctx.Prediction
		local f = p and p.Owner and p.Fighter
		if f and f.State then
			-- Owner mode: also report this client's simulation of its fighter (server OwnerSync)
			local aim = f.Aim
			ctx.Remotes.CombatInput:FireServer(s.Seq, s.Move.X, s.Move.Z, ctx.Camera.Yaw, s.AimU, s.AimV, buttons,
				f.State, f.Balance or 0, f.Block.Active == true, aim.U, aim.V, aim.VU, aim.VV, aim.Bind ~= nil, p.Ack)
		else
			ctx.Remotes.CombatInput:FireServer(s.Seq, s.Move.X, s.Move.Z, ctx.Camera.Yaw, s.AimU, s.AimV, buttons)
		end
	end
end

-- The fighter's bound attack (see SwordController.Bind), or nil: the predicted copy under server
-- authority, otherwise the server's
function InputController.Bind(ctx)
	local model = ctx.Fighter
	if not model or not model.Parent then
		return nil
	end
	local ut, lt = model:FindFirstChild("UpperTorso"), model:FindFirstChild("LowerTorso")
	if ut and lt and lt:GetAttribute("S_State") ~= nil then
		local u = ut:GetAttribute("S_BindU")
		if u == nil then
			return nil
		end
		return { U = u, V = ut:GetAttribute("S_BindV") or 0, DU = ut:GetAttribute("S_BindDU") or 0, DV = ut:GetAttribute("S_BindDV") or -1 }
	end
	local p, d = model:GetAttribute("AimBind"), model:GetAttribute("AimBindDir")
	if typeof(p) == "Vector3" and typeof(d) == "Vector3" then
		return { U = p.X, V = p.Y, DU = d.X, DV = d.Y }
	end
	return nil
end

-- Recent cursor motion (disk units per second) over the last `window` seconds
function InputController.MotionVector(ctx, window)
	local h = ctx.Input.History
	local n = #h
	if n < 2 then
		return 0, 0
	end
	local last = h[n]
	local first = h[1]
	for i = n - 1, 1, -1 do
		if last.t - h[i].t >= window then
			first = h[i]
			break
		end
	end
	local dt = math.max(last.t - first.t, 1e-3)
	return (last.u - first.u) / dt, (last.v - first.v) / dt
end

function InputController.ApplyMouseMode(ctx)
	local free = GuiService.MenuIsOpen
	UserInputService.MouseBehavior = free and Enum.MouseBehavior.Default or Enum.MouseBehavior.LockCenter
	UserInputService.MouseIconEnabled = free
end

return InputController
