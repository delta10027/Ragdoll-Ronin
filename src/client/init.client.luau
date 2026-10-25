--[[
	Ragdoll Ronin - client bootstrap.
	The client only samples input, runs the camera, draws UI and sends intent. It never decides
	hits, damage or death (see ServerScriptService.RagdollRonin).
]]
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local Shared = ReplicatedStorage:WaitForChild("RagdollRonin")
local Remotes = Shared:WaitForChild("Remotes")

local CameraController = require(script.CameraController)
local InputController = require(script.InputController)
local CombatCursorUI = require(script.CombatCursorUI)
local AnatomyUI = require(script.AnatomyUI)
local DebugOverlay = require(script.DebugOverlay)

-- default Roblox movement controls are irrelevant for the custom fighter
task.spawn(function()
	local ok, pm = pcall(function()
		return require(player:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule", 10))
	end)
	if ok and pm then
		pcall(function()
			pm:GetControls():Disable()
		end)
	end
end)

-- Escape menu "Reset Character" -> server-side death (no Humanoid exists to kill)
task.spawn(function()
	local resetEvent = Instance.new("BindableEvent")
	resetEvent.Event:Connect(function()
		Remotes.CombatAction:FireServer("Reset")
	end)
	for _ = 1, 20 do
		if pcall(StarterGui.SetCore, StarterGui, "ResetButtonCallback", resetEvent) then
			break
		end
		task.wait(0.5)
	end
end)

local gui = Instance.new("ScreenGui")
gui.Name = "RagdollRoninHUD"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.DisplayOrder = 5
gui.Parent = player:WaitForChild("PlayerGui")

local ctx = {
	Player = player,
	Gui = gui,
	Remotes = Remotes,
	Fighter = nil,
}

local function isFighter(model)
	return model ~= nil and model:GetAttribute("RR_Fighter") == true
end

local function onCharacter(model)
	if isFighter(model) then
		ctx.Fighter = model
		CameraController.OnNewFighter(ctx, model)
		CombatCursorUI.OnNewFighter(ctx, model)
		AnatomyUI.OnNewFighter(ctx, model)
	end
end
player:GetPropertyChangedSignal("Character"):Connect(function()
	onCharacter(player.Character)
end)

CameraController.Init(ctx)
InputController.Init(ctx)
CombatCursorUI.Init(ctx)
AnatomyUI.Init(ctx)
DebugOverlay.Init(ctx)
onCharacter(player.Character)

RunService:BindToRenderStep("RR_Input", Enum.RenderPriority.Input.Value + 1, function(dt)
	InputController.Update(ctx, dt)
end)
RunService:BindToRenderStep("RR_Camera", Enum.RenderPriority.Camera.Value + 2, function(dt)
	CameraController.Update(ctx, dt)
	InputController.ApplyMouseMode(ctx)
end)
RunService:BindToRenderStep("RR_UI", Enum.RenderPriority.Last.Value, function(dt)
	CombatCursorUI.Update(ctx, dt)
	AnatomyUI.Update(ctx, dt)
	DebugOverlay.Update(ctx, dt)
end)
