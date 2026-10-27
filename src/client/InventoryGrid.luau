--[[
	InventoryGrid: the grid of carried items (InventoryClient.Data.Items), used by the inventory
	and the sword screen. A search box (by name, slot or kind) and the cells used / capacity on top,
	one cell per slot of capacity below (a bag adds cells), and a discard strip that shows while an
	item is dragged.
	  drag a cell onto another cell     move it there
	  drag a cell onto a slot / socket  (theirs: equip it, set the book)
	  drag a slot / socket onto the grid  take it off (the payload's Return)
	  right-click a cell                opts.OnQuick(index, key)
	opts: Columns, Usable(key) -> bool (others are dimmed and can't be dragged), Hint(key) -> the
	tooltip's hint line, OnQuick.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage:WaitForChild("RagdollRonin"):WaitForChild("Config"))
local Theme = require(script.Parent.UITheme)
local ItemArt = require(script.Parent.ItemArt)
local DragDrop = require(script.Parent.DragDrop)
local ItemTooltip = require(script.Parent.ItemTooltip)
local InventoryClient = require(script.Parent.InventoryClient)

local InventoryGrid = {}
InventoryGrid.__index = InventoryGrid
local C = Theme.Colors
local IT = Config.Items

local CELL = 72
local GAP = 8

local function matches(key, query)
	if query == "" then
		return true
	end
	local def = IT[key]
	local hay = string.lower(table.concat({ def.Label, def.Slot or "", def.Kind == "Book" and "book incantation" or "",
		InventoryClient.Describe(key) }, " "))
	return string.find(hay, query, 1, true) ~= nil
end

function InventoryGrid.new(parent, opts)
	opts = opts or {}
	local self = setmetatable({}, InventoryGrid)
	self.Opts = opts
	self.Cells = {}
	self.Query = ""
	local columns = opts.Columns or 6
	local width = columns * CELL + (columns - 1) * GAP + 16

	local root = Theme.new("Frame", { Name = "Grid", BackgroundTransparency = 1, Size = UDim2.new(0, width, 1, 0), Parent = parent })
	self.Frame = root

	-- search box, top left
	local search = Theme.new("Frame", {
		Size = UDim2.new(1, -96, 0, 36),
		BackgroundColor3 = C.Cell,
		Parent = root,
	})
	Theme.corner(search, 8)
	local searchStroke = Theme.stroke(search, C.CellEdge, 1)
	local glyph = Theme.searchGlyph(search, 16, C.Muted)
	glyph.Position = UDim2.new(0, 12, 0.5, -8)
	local box = Theme.new("TextBox", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(38, 0),
		Size = UDim2.new(1, -46, 1, 0),
		FontFace = Theme.Fonts.Body,
		TextSize = 15,
		TextColor3 = C.Text,
		PlaceholderText = "Search items",
		PlaceholderColor3 = C.Faint,
		TextXAlignment = Enum.TextXAlignment.Left,
		ClearTextOnFocus = false,
		Text = "",
		Parent = search,
	})
	box.Focused:Connect(function()
		Theme.tween(searchStroke, 0.15, { Color = C.Gold })
	end)
	box.FocusLost:Connect(function()
		Theme.tween(searchStroke, 0.2, { Color = C.CellEdge })
	end)
	box:GetPropertyChangedSignal("Text"):Connect(function()
		self.Query = string.lower(box.Text)
		self:Refresh(InventoryClient.Data)
	end)
	self.Search = box

	self.Count = Theme.text(root, "", 15, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -8, 0, 0),
		Size = UDim2.fromOffset(84, 36),
		TextXAlignment = Enum.TextXAlignment.Right,
		FontFace = Theme.Fonts.Medium,
		TextColor3 = C.Muted,
	})

	local scroll = Theme.new("ScrollingFrame", {
		Position = UDim2.fromOffset(0, 48),
		Size = UDim2.new(1, 0, 1, -48),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = C.Faint,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		Parent = root,
	})
	Theme.pad(scroll, 4)
	Theme.new("UIGridLayout", {
		CellSize = UDim2.fromOffset(CELL, CELL),
		CellPadding = UDim2.fromOffset(GAP, GAP),
		FillDirectionMaxCells = columns,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = scroll,
	})
	self.Scroll = scroll
	local scrollStroke = Theme.stroke(scroll, C.Gold, 1, 1)
	-- the grid takes back what is dragged off a slot or the socket
	DragDrop.Target(scroll, {
		Priority = 1,
		Accepts = function(p)
			return p.Return ~= nil
		end,
		Drop = function(p)
			p.Return()
		end,
		Highlight = function(state)
			Theme.tween(scrollStroke, 0.15, { Transparency = state == "Over" and 0.2 or state == "Can" and 0.7 or 1 })
		end,
	})

	-- discard strip under the grid, shown while a grid item is dragged
	local discard = Theme.new("TextLabel", {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, 4),
		Size = UDim2.new(1, -8, 0, 38),
		BackgroundColor3 = Color3.fromRGB(48, 22, 22),
		BackgroundTransparency = 1,
		FontFace = Theme.Fonts.Medium,
		TextSize = 14,
		TextColor3 = C.Bad,
		TextTransparency = 1,
		Text = "Drop here to discard",
		ZIndex = 5,
		Visible = false,
		Parent = root,
	})
	Theme.corner(discard, 8)
	local discardStroke = Theme.stroke(discard, C.Bad, 1, 1)
	DragDrop.Target(discard, {
		Priority = 3,
		Accepts = function(p)
			return p.From == "Grid"
		end,
		Drop = function(p)
			InventoryClient.Send("Discard", p.Index, p.Key)
		end,
		Highlight = function(state)
			if state == "Off" then
				Theme.tween(discard, 0.15, { BackgroundTransparency = 1, TextTransparency = 1 })
				Theme.tween(discardStroke, 0.15, { Transparency = 1 })
				task.delay(0.16, function()
					if not DragDrop.Dragging() then
						discard.Visible = false
					end
				end)
			else
				discard.Visible = true
				Theme.tween(discard, 0.15, { BackgroundTransparency = state == "Over" and 0.05 or 0.35, TextTransparency = 0 })
				Theme.tween(discardStroke, 0.15, { Transparency = state == "Over" and 0 or 0.5 })
			end
		end,
	})

	self:Refresh(InventoryClient.Data)
	InventoryClient.OnChanged(function(data)
		self:Refresh(data)
	end)
	return self
end

function InventoryGrid:_usable(key)
	return key ~= nil and (not self.Opts.Usable or self.Opts.Usable(key))
end

function InventoryGrid:_cell(i)
	local cell = self.Cells[i]
	if cell then
		return cell
	end
	local b = Theme.button(self.Scroll, "", 14, { LayoutOrder = i, BackgroundColor3 = C.Cell, ClipsDescendants = false })
	Theme.corner(b, 8)
	local stroke = Theme.stroke(b, C.CellEdge, 1)
	local holder = Theme.new("Frame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(4, 4),
		Size = UDim2.new(1, -8, 1, -8),
		Parent = b,
	})
	local bar = Theme.new("Frame", {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -5),
		Size = UDim2.new(0.4, 0, 0, 3),
		BorderSizePixel = 0,
		BackgroundTransparency = 1,
		Parent = b,
	})
	Theme.corner(bar, 2)
	local scale = Theme.scaleOf(b)
	cell = { Button = b, Stroke = stroke, Holder = holder, Bar = bar, Scale = scale, Index = i }
	self.Cells[i] = cell

	b.MouseEnter:Connect(function()
		if DragDrop.Dragging() then
			return
		end
		if cell.Key then
			Theme.tween(b, 0.12, { BackgroundColor3 = C.CellHover })
			Theme.tween(scale, 0.12, { Scale = 1.05 })
			Theme.tween(stroke, 0.12, { Color = C.Gold })
			ItemTooltip.Show(cell.Key, self.Opts.Hint and self.Opts.Hint(cell.Key) or nil)
		end
	end)
	b.MouseLeave:Connect(function()
		if not cell.Over then
			Theme.tween(b, 0.18, { BackgroundColor3 = C.Cell })
			Theme.tween(stroke, 0.18, { Color = C.CellEdge })
		end
		Theme.tween(scale, 0.18, { Scale = 1 })
		ItemTooltip.Hide(cell.Key)
	end)
	b.MouseButton2Click:Connect(function()
		if cell.Key and self.Opts.OnQuick and self:_usable(cell.Key) then
			ItemTooltip.Hide()
			self.Opts.OnQuick(cell.Index, cell.Key)
		end
	end)
	DragDrop.Source(b, function()
		local key = cell.Key
		if not self:_usable(key) then
			return nil
		end
		return {
			Key = key,
			Index = cell.Index,
			From = "Grid",
			Icon = function()
				return ItemArt.Icon(key)
			end,
			OnStart = function()
				cell.Dragged = true
				Theme.tween(holder, 0.12, { Position = UDim2.fromOffset(4, 10) })
				for _, d in ipairs(holder:GetChildren()) do
					if d:IsA("ViewportFrame") then
						Theme.tween(d, 0.12, { ImageTransparency = 0.7 })
					end
				end
			end,
			OnEnd = function()
				cell.Dragged = false
				Theme.tween(holder, 0.15, { Position = UDim2.fromOffset(4, 4) })
				for _, d in ipairs(holder:GetChildren()) do
					if d:IsA("ViewportFrame") then
						Theme.tween(d, 0.15, { ImageTransparency = self:_usable(cell.Key) and 0 or 0.65 })
					end
				end
			end,
		}
	end)
	-- dropping another grid item here moves it to this cell
	DragDrop.Target(b, {
		Priority = 2,
		Accepts = function(p)
			return p.From == "Grid" and p.Index ~= cell.Index
		end,
		Drop = function(p)
			local to = math.min(cell.Index, #InventoryClient.Data.Items)
			if to ~= p.Index then
				InventoryClient.Send("Move", p.Index, to)
			end
		end,
		Highlight = function(state)
			cell.Over = state == "Over"
			Theme.tween(stroke, 0.12, { Color = state == "Over" and C.Gold or C.CellEdge, Thickness = state == "Over" and 2 or 1 })
			Theme.tween(b, 0.12, { BackgroundColor3 = state == "Over" and C.CellHover or C.Cell })
		end,
	})
	return cell
end

function InventoryGrid:_setKey(cell, key, animate)
	if cell.Key == key then
		return
	end
	cell.Key = key
	for _, d in ipairs(cell.Holder:GetChildren()) do
		d:Destroy()
	end
	if key then
		local icon = ItemArt.Icon(key)
		icon.Parent = cell.Holder
		cell.Bar.BackgroundColor3 = InventoryClient.Accent(key, Theme)
		cell.Bar.BackgroundTransparency = 0.15
		if animate then
			cell.Scale.Scale = 0.7
			Theme.tween(cell.Scale, 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
		end
	else
		cell.Bar.BackgroundTransparency = 1
	end
end

function InventoryGrid:Refresh(data)
	local items = data.Items
	local capacity = math.max(data.Capacity, #items)
	self.Count.Text = string.format("%d / %d", #items, data.Capacity)
	self.Count.TextColor3 = #items >= data.Capacity and C.Bad or C.Muted
	local filtering = self.Query ~= ""
	for i = 1, math.max(capacity, #self.Cells) do
		if i > capacity then
			local cell = self.Cells[i]
			if cell then
				self:_setKey(cell, nil)
				cell.Button.Visible = false
			end
		else
			local cell = self:_cell(i)
			local key = items[i]
			self:_setKey(cell, key, self.Shown)
			cell.Button.Visible = if key then matches(key, self.Query) else not filtering
			local usable = key == nil or self:_usable(key)
			for _, d in ipairs(cell.Holder:GetChildren()) do
				if d:IsA("ViewportFrame") then
					d.ImageTransparency = usable and 0 or 0.65
				end
			end
			cell.Button.BackgroundTransparency = usable and 0 or 0.4
		end
	end
end

-- the cells pop in one after another, in a wave from the top left
function InventoryGrid:Intro()
	self.Shown = true
	local columns = self.Opts.Columns or 6
	for i, cell in ipairs(self.Cells) do
		if cell.Button.Visible then
			local row, col = (i - 1) // columns, (i - 1) % columns
			local delay = (row + col) * 0.025
			cell.Scale.Scale = 0.55
			Theme.tween(cell.Scale, 0.32, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out, delay)
		end
	end
end

function InventoryGrid:Hidden()
	self.Shown = false
	ItemTooltip.Hide()
end

return InventoryGrid
