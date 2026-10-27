--[[
	ItemTooltip: the card that follows the cursor over an item in the menus: its name, what it
	is (InventoryClient.Describe, in the item's accent), its description and a hint line.
	Hidden while something is being dragged.
]]
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage:WaitForChild("RagdollRonin"):WaitForChild("Config"))
local Theme = require(script.Parent.UITheme)
local InventoryClient = require(script.Parent.InventoryClient)
local DragDrop = require(script.Parent.DragDrop)

local ItemTooltip = {}
local C = Theme.Colors
local ui = {}
local showing

function ItemTooltip.Show(key, hint, extra)
	local def = Config.Items[key]
	if not def or not ui.Frame then
		return
	end
	showing = key
	ui.Title.Text = def.Label
	ui.Kind.Text = InventoryClient.Describe(key)
	ui.Kind.TextColor3 = InventoryClient.Accent(key, Theme)
	ui.Desc.Text = def.Description or ""
	ui.Extra.Text = extra or ""
	ui.Extra.Visible = extra ~= nil
	ui.Hint.Text = hint or ""
	ui.Hint.Visible = hint ~= nil
	ui.Frame.Visible = true
	ui.Frame.BackgroundTransparency = 0.04
	local scale = Theme.scaleOf(ui.Frame)
	scale.Scale = 0.94
	Theme.tween(scale, 0.12, { Scale = 1 })
end

function ItemTooltip.Hide(key)
	if key == nil or key == showing then
		showing = nil
		if ui.Frame then
			ui.Frame.Visible = false
		end
	end
end

function ItemTooltip.Init(playerGui)
	local gui = Theme.new("ScreenGui", {
		Name = "RR_Tooltip",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = 45,
		Parent = playerGui,
	})
	local f = Theme.new("Frame", {
		Name = "Tooltip",
		Size = UDim2.fromOffset(250, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = C.Panel,
		Visible = false,
		ZIndex = 60,
		Parent = gui,
	})
	Theme.corner(f, 8)
	Theme.stroke(f, C.PanelEdge, 1)
	Theme.pad(f, 12)
	Theme.new("UIListLayout", { Padding = UDim.new(0, 3), SortOrder = Enum.SortOrder.LayoutOrder, Parent = f })
	local function line(order, font, size, color)
		local l = Theme.text(f, "", size, {
			FontFace = font,
			TextColor3 = color,
			TextWrapped = true,
			AutomaticSize = Enum.AutomaticSize.Y,
			Size = UDim2.new(1, 0, 0, 0),
			LayoutOrder = order,
			ZIndex = 61,
		})
		return l
	end
	ui.Frame = f
	ui.Title = line(1, Theme.Fonts.Title, 17, C.Text)
	ui.Kind = line(2, Theme.Fonts.Medium, 13, C.Armour)
	ui.Desc = line(3, Theme.Fonts.Body, 13, C.Muted)
	ui.Extra = line(4, Theme.Fonts.Medium, 13, C.Bad)
	ui.Hint = line(5, Theme.Fonts.Body, 12, C.Faint)

	RunService.RenderStepped:Connect(function()
		if not f.Visible then
			return
		end
		if DragDrop.Dragging() then
			f.Visible = false
			showing = nil
			return
		end
		local m = UserInputService:GetMouseLocation()
		local screen = gui.AbsoluteSize
		local size = f.AbsoluteSize
		local x = m.X + 18
		local y = m.Y + 18
		if x + size.X > screen.X - 8 then
			x = m.X - size.X - 14
		end
		if y + size.Y > screen.Y - 8 then
			y = screen.Y - size.Y - 8
		end
		f.Position = UDim2.fromOffset(x, y)
	end)
end

return ItemTooltip
