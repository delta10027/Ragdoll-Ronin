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
if not game:IsLoaded() then
	game.Loaded:Wait() -- the shared simulation modules are required as a whole folder
end
local Shared = ReplicatedStorage:WaitForChild("RagdollRonin")
local Remotes = Shared:WaitForChild("Remotes")

local CameraController = require(script.CameraController)
local InputController = require(script.InputController)
local CombatCursorUI = require(script.CombatCursorUI)
local AnatomyUI = require(script.AnatomyUI)
local DebugOverlay = require(script.DebugOverlay)
local Prediction = require(script.Prediction)
local SoundPlayer = require(script.SoundPlayer)
local WoundMarks = require(script.WoundMarks)
local LockOn = require(script.LockOn)
local ArmorView = require(script.ArmorView)
local InventoryClient = require(script.InventoryClient)
local DragDrop = require(script.DragDrop)
local ItemTooltip = require(script.ItemTooltip)
local MainMenu = require(script.MainMenu)
local CreativeMenu = require(script.CreativeMenu)
local ChatBubbles = require(script.ChatBubbles)
local WindView = require(script.WindView)
local WindScreenFX = require(script.WindScreenFX)
local WeatherView = require(script.WeatherView)
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")

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
	MenuOpen = false,
}
-- a menu opened or closed: the mouse is free and the fighter takes no input while any is open
function ctx.SyncMenus()
	ctx.MenuOpen = MainMenu.IsOpen() or CreativeMenu.IsOpen()
end
-- server refusal (Feedback "LoadoutRefused", via CombatCursorUI)
function ctx.LoadoutRefused(reason)
	if CreativeMenu.IsOpen() then
		CreativeMenu.Refused(reason)
	else
		MainMenu.Refused(reason)
	end
end

-- TAB is the game's menu, so Roblox's player list (also on TAB) is turned off
task.spawn(function()
	for _ = 1, 20 do
		if pcall(StarterGui.SetCoreGuiEnabled, StarterGui, Enum.CoreGuiType.PlayerList, false) then
			break
		end
		task.wait(0.5)
	end
end)

local function isFighter(model)
	return model ~= nil and model:GetAttribute("RR_Fighter") == true
end

local function onCharacter(model)
	if isFighter(model) then
		ctx.Fighter = model
		Prediction.OnNewFighter(ctx, model)
		CameraController.OnNewFighter(ctx, model)
		CombatCursorUI.OnNewFighter(ctx, model)
		AnatomyUI.OnNewFighter(ctx, model)
		InventoryClient.OnNewFighter(ctx, model)
	end
end
player:GetPropertyChangedSignal("Character"):Connect(function()
	onCharacter(player.Character)
end)

Prediction.Init(ctx)
CameraController.Init(ctx)
InputController.Init(ctx)
CombatCursorUI.Init(ctx)
AnatomyUI.Init(ctx)
DebugOverlay.Init(ctx)
SoundPlayer.Init(ctx)
WoundMarks.Init(ctx)
LockOn.Init(ctx)
ArmorView.Init(ctx)
InventoryClient.Init(ctx)
DragDrop.Init(ctx, gui.Parent)
ItemTooltip.Init(gui.Parent)
MainMenu.Init(ctx, gui.Parent)
CreativeMenu.Init(ctx, gui.Parent)
ChatBubbles.Init(ctx)
WindView.Init(ctx)
WindScreenFX.Init(ctx)
WeatherView.Init(ctx)
onCharacter(player.Character)

RunService:BindToRenderStep("RR_Input", Enum.RenderPriority.Input.Value + 1, function(dt)
	InputController.Update(ctx, dt)
end)
-- TAB opens the menu (Backspace: back to its diamonds), M the creative menu, H hides the combat
-- disk, K locks on
UserInputService.InputBegan:Connect(function(io, processed)
	if processed or GuiService.MenuIsOpen then
		return
	end
	if io.KeyCode == Enum.KeyCode.Tab then
		if CreativeMenu.IsOpen() then
			CreativeMenu.Toggle(ctx)
		end
		MainMenu.Toggle(ctx)
	elseif io.KeyCode == Enum.KeyCode.Backspace and MainMenu.IsOpen() then
		MainMenu.Back()
	elseif io.KeyCode == Enum.KeyCode.M then
		if MainMenu.IsOpen() then
			MainMenu.Close(ctx)
		end
		CreativeMenu.Toggle(ctx)
	elseif io.KeyCode == Enum.KeyCode.H then
		CombatCursorUI.ToggleDisk()
	elseif io.KeyCode == Enum.KeyCode.K then
		LockOn.Toggle(ctx)
	end
end)

RunService:BindToRenderStep("RR_Camera", Enum.RenderPriority.Camera.Value + 2, function(dt)
	LockOn.Update(ctx, dt)
	CameraController.Update(ctx, dt)
	InputController.ApplyMouseMode(ctx)
end)
RunService:BindToRenderStep("RR_UI", Enum.RenderPriority.Last.Value, function(dt)
	CombatCursorUI.Update(ctx, dt)
	AnatomyUI.Update(ctx, dt)
	DebugOverlay.Update(ctx, dt)
	WindScreenFX.Update(ctx, dt)
	WeatherView.Update(ctx, dt)
end)
