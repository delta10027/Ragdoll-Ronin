--[[
	CreativeMenu: M opens a drawer on the right of the screen with two tabs.
	  Items    every item there is (Config.Items): search by name, filter by slot, click one (or
	           its +) to give it to yourself (server Loadout "Give", when Config.Inventory.Creative).
	           Clear empties your grid.
	  Weather  the server's wind and rain, for everyone: wind speed and rain sliders, a compass to
	           point the wind (drag it), and presets.
	While it is open the mouse is free and the fighter takes no input (ctx.MenuOpen).
]]
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage:WaitForChild("RagdollRonin"):WaitForChild("Config"))
local Theme = require(script.Parent.UITheme)
local ItemArt = require(script.Parent.ItemArt)
local ItemTooltip = require(script.Parent.ItemTooltip)
local InventoryClient = require(script.Parent.InventoryClient)

local CreativeMenu = {}
local C = Theme.Colors
local IT = Config.Items
local W = Config.Wind
local R = Config.Rain
local Q = Enum.EasingStyle.Quint
local WIDTH = 400
local COMPASS = { "N", "NW", "W", "SW", "S", "SE", "E", "NE" } -- yaw 0 blows toward -Z (N), 90 toward -X
local FILTERS = { "All", "Head", "Neck", "Back", "Legs", "Boots", "Books" }
local PRESETS = {
	{ "Calm", 0, 0 },
	{ "Breeze", 12, 0 },
	{ "Rain", 18, 0.5 },
	{ "Storm", 42, 1 },
	{ "Gale", 60, 0.25 },
}

local ui = {}
local open = false
local tab = "Items"
local filter = "All"
local query = ""

local function windNow()
	local speed = workspace:GetAttribute("WindSpeed")
	local yaw = workspace:GetAttribute("WindYaw")
	return typeof(speed) == "number" and speed or W.Speed, typeof(yaw) == "number" and yaw or W.Yaw
end

local function rainNow()
	local r = workspace:GetAttribute("RainIntensity")
	return typeof(r) == "number" and r or R.Intensity
end

-- at most one request every 0.1 s while dragging, and always the last one
local function throttled(send)
	local lastSent, queued = 0, nil
	return function(...)
		local args = table.pack(...)
		local now = os.clock()
		if now - lastSent >= 0.1 then
			lastSent = now
			send(table.unpack(args, 1, args.n))
		else
			if not queued then
				task.delay(0.1 - (now - lastSent), function()
					lastSent = os.clock()
					send(table.unpack(queued, 1, queued.n))
					queued = nil
				end)
			end
			queued = args
		end
	end
end

local sendWind = throttled(function(speed, yaw)
	InventoryClient.Send("Wind", speed, yaw)
end)
local sendRain = throttled(function(r)
	InventoryClient.Send("Rain", r)
end)

------------------------------------------------------------------ items tab
local function itemMatches(key)
	local def = IT[key]
	if filter == "Books" and def.Kind ~= "Book" then
		return false
	elseif filter ~= "All" and filter ~= "Books" and def.Slot ~= filter then
		return false
	end
	if query == "" then
		return true
	end
	local hay = string.lower(def.Label .. " " .. (def.Slot or "") .. " " .. InventoryClient.Describe(key))
	return string.find(hay, query, 1, true) ~= nil
end

local function refreshItems()
	local shown = 0
	for _, row in ipairs(ui.Rows) do
		local on = itemMatches(row.Key)
		row.Frame.Visible = on
		if on then
			shown += 1
		end
	end
	ui.Empty.Visible = shown == 0
	for name, chip in pairs(ui.Chips) do
		local on = name == filter
		Theme.tween(chip, 0.15, { BackgroundColor3 = on and C.Accent or C.Cell, TextColor3 = on and C.Text or C.Muted })
	end
	local data = InventoryClient.Data
	ui.Count.Text = string.format("Carrying %d / %d", #data.Items, data.Capacity)
	ui.Count.TextColor3 = #data.Items >= data.Capacity and C.Bad or C.Muted
end

local function itemRow(parent, key, order)
	local def = IT[key]
	local b = Theme.button(parent, "", 14, {
		Size = UDim2.new(1, 0, 0, 58),
		BackgroundColor3 = C.Cell,
		LayoutOrder = order,
	})
	Theme.corner(b, 8)
	local stroke = Theme.stroke(b, C.CellEdge, 1)
	local iconBox = Theme.new("Frame", { Position = UDim2.fromOffset(6, 5), Size = UDim2.fromOffset(48, 48), BackgroundColor3 = C.Panel, Parent = b })
	Theme.corner(iconBox, 6)
	ItemArt.Icon(key).Parent = iconBox
	Theme.new("Frame", {
		Position = UDim2.fromOffset(0, 12),
		Size = UDim2.fromOffset(3, 34),
		BackgroundColor3 = InventoryClient.Accent(key, Theme),
		BorderSizePixel = 0,
		Parent = b,
	})
	Theme.text(b, def.Label, 16, { Position = UDim2.fromOffset(66, 9), Size = UDim2.new(1, -120, 0, 20), FontFace = Theme.Fonts.Medium })
	Theme.text(b, InventoryClient.Describe(key), 12, {
		Position = UDim2.fromOffset(66, 31),
		Size = UDim2.new(1, -120, 0, 16),
		TextColor3 = InventoryClient.Accent(key, Theme):Lerp(C.Muted, 0.4),
	})
	local plus = Theme.text(b, "+", 24, {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -14, 0.5, 0),
		Size = UDim2.fromOffset(28, 28),
		FontFace = Theme.Fonts.Medium,
		TextColor3 = C.Muted,
		TextXAlignment = Enum.TextXAlignment.Center,
	})
	Theme.corner(plus, 14)
	local scale = Theme.scaleOf(b)
	b.MouseEnter:Connect(function()
		Theme.tween(b, 0.12, { BackgroundColor3 = C.CellHover })
		Theme.tween(stroke, 0.12, { Color = C.Gold })
		Theme.tween(plus, 0.12, { TextColor3 = C.Gold, Rotation = 90 })
		ItemTooltip.Show(key, "Click to give yourself one")
	end)
	b.MouseLeave:Connect(function()
		Theme.tween(b, 0.18, { BackgroundColor3 = C.Cell })
		Theme.tween(stroke, 0.18, { Color = C.CellEdge })
		Theme.tween(plus, 0.18, { TextColor3 = C.Muted, Rotation = 0 })
		ItemTooltip.Hide(key)
	end)
	b.Activated:Connect(function()
		InventoryClient.Send("Give", key)
		-- a press and a flash
		scale.Scale = 0.96
		Theme.tween(scale, 0.25, { Scale = 1 }, Enum.EasingStyle.Back)
		b.BackgroundColor3 = C.Gold:Lerp(C.Cell, 0.6)
		Theme.tween(b, 0.35, { BackgroundColor3 = C.CellHover })
	end)
	return { Frame = b, Key = key }
end

local function buildItems(page)
	-- search
	local search = Theme.new("Frame", { Size = UDim2.new(1, 0, 0, 38), BackgroundColor3 = C.Cell, Parent = page })
	Theme.corner(search, 8)
	local sStroke = Theme.stroke(search, C.CellEdge, 1)
	local glyph = Theme.searchGlyph(search, 16, C.Muted)
	glyph.Position = UDim2.new(0, 12, 0.5, -8)
	local box = Theme.new("TextBox", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(38, 0),
		Size = UDim2.new(1, -46, 1, 0),
		FontFace = Theme.Fonts.Body,
		TextSize = 15,
		TextColor3 = C.Text,
		PlaceholderText = "Search all items",
		PlaceholderColor3 = C.Faint,
		TextXAlignment = Enum.TextXAlignment.Left,
		ClearTextOnFocus = false,
		Text = "",
		Parent = search,
	})
	box.Focused:Connect(function()
		Theme.tween(sStroke, 0.15, { Color = C.Gold })
	end)
	box.FocusLost:Connect(function()
		Theme.tween(sStroke, 0.2, { Color = C.CellEdge })
	end)
	box:GetPropertyChangedSignal("Text"):Connect(function()
		query = string.lower(box.Text)
		refreshItems()
	end)
	ui.Search = box

	-- filter chips
	local chips = Theme.new("Frame", { Position = UDim2.fromOffset(0, 48), Size = UDim2.new(1, 0, 0, 28), BackgroundTransparency = 1, Parent = page })
	Theme.new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder, Parent = chips })
	ui.Chips = {}
	for i, name in ipairs(FILTERS) do
		local chip = Theme.button(chips, name, 13, {
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.fromOffset(0, 28),
			BackgroundColor3 = C.Cell,
			TextColor3 = C.Muted,
			LayoutOrder = i,
		})
		Theme.corner(chip, 14)
		local pad = Theme.pad(chip, 0)
		pad.PaddingLeft, pad.PaddingRight = UDim.new(0, 11), UDim.new(0, 11)
		chip.Activated:Connect(function()
			filter = name
			refreshItems()
		end)
		ui.Chips[name] = chip
	end

	-- the list
	local list = Theme.new("ScrollingFrame", {
		Position = UDim2.fromOffset(0, 86),
		Size = UDim2.new(1, 0, 1, -130),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = C.Faint,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		Parent = page,
	})
	local lp = Theme.pad(list, 2)
	lp.PaddingRight = UDim.new(0, 8)
	Theme.new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder, Parent = list })
	ui.Rows = {}
	for i, key in ipairs(IT.Order) do
		table.insert(ui.Rows, itemRow(list, key, i))
	end
	ui.Empty = Theme.text(list, "Nothing matches", 14, { TextColor3 = C.Faint, TextXAlignment = Enum.TextXAlignment.Center, LayoutOrder = 1000, Visible = false })

	-- footer: how full the grid is, and clear
	ui.Count = Theme.text(page, "", 13, { AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 0, 1, -6), Size = UDim2.new(0.6, 0, 0, 22) })
	local clear = Theme.button(page, "Clear inventory", 13, {
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, 0, 1, -2),
		Size = UDim2.fromOffset(130, 32),
		BackgroundColor3 = C.Cell,
		TextColor3 = C.Bad,
	})
	Theme.corner(clear, 8)
	Theme.stroke(clear, C.CellEdge, 1)
	Theme.hover(clear, { StrokeHover = C.Bad })
	clear.Activated:Connect(function()
		InventoryClient.Send("Clear")
	end)
	InventoryClient.OnChanged(refreshItems)
	refreshItems()
end

------------------------------------------------------------------ weather tab
-- a slider: drag along the track; onChange(value 0..1, final)
local function slider(parent, y, label, onChange)
	local holder = Theme.new("Frame", { Position = UDim2.fromOffset(0, y), Size = UDim2.new(1, 0, 0, 56), BackgroundTransparency = 1, Parent = parent })
	Theme.text(holder, label, 14, { Size = UDim2.new(0.5, 0, 0, 20), FontFace = Theme.Fonts.Medium })
	local value = Theme.text(holder, "", 14, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.new(0.5, 0, 0, 20),
		TextXAlignment = Enum.TextXAlignment.Right,
		TextColor3 = C.Gold,
	})
	local track = Theme.new("TextButton", {
		Position = UDim2.fromOffset(0, 30),
		Size = UDim2.new(1, 0, 0, 6),
		BackgroundColor3 = C.Cell,
		AutoButtonColor = false,
		Text = "",
		Parent = holder,
	})
	Theme.corner(track, 3)
	local fill = Theme.new("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = C.Accent, BorderSizePixel = 0, Parent = track })
	Theme.corner(fill, 3)
	local knob = Theme.new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0, 0.5),
		Size = UDim2.fromOffset(18, 18),
		BackgroundColor3 = C.Text,
		ZIndex = 2,
		Parent = track,
	})
	Theme.corner(knob, 9)
	Theme.stroke(knob, C.Accent, 2)
	local knobScale = Theme.scaleOf(knob)
	local dragging = false
	local s = {}
	function s.Set(t, text)
		if not dragging then
			Theme.tween(fill, 0.2, { Size = UDim2.fromScale(t, 1) })
			Theme.tween(knob, 0.2, { Position = UDim2.fromScale(t, 0.5) })
		end
		value.Text = text
	end
	local function at(x, final)
		local t = math.clamp((x - track.AbsolutePosition.X) / track.AbsoluteSize.X, 0, 1)
		fill.Size = UDim2.fromScale(t, 1)
		knob.Position = UDim2.fromScale(t, 0.5)
		onChange(t, final)
	end
	track.InputBegan:Connect(function(io)
		if io.UserInputType == Enum.UserInputType.MouseButton1 or io.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			Theme.tween(knobScale, 0.12, { Scale = 1.25 })
			at(UserInputService:GetMouseLocation().X, false)
		end
	end)
	UserInputService.InputChanged:Connect(function(io)
		if dragging and (io.UserInputType == Enum.UserInputType.MouseMovement or io.UserInputType == Enum.UserInputType.Touch) then
			at(UserInputService:GetMouseLocation().X, false)
		end
	end)
	UserInputService.InputEnded:Connect(function(io)
		if dragging and (io.UserInputType == Enum.UserInputType.MouseButton1 or io.UserInputType == Enum.UserInputType.Touch) then
			dragging = false
			Theme.tween(knobScale, 0.15, { Scale = 1 })
			at(UserInputService:GetMouseLocation().X, true)
		end
	end)
	return s
end

local function windFeel(speed)
	return speed >= W.FullSpeed and "gale" or speed >= W.HighSpeed and "strong" or speed >= W.CalmSpeed and "breeze" or "calm"
end

local function rainFeel(r)
	return r <= 0 and "off" or r <= 0.25 and "drizzle" or r <= 0.5 and "rain" or r <= 0.75 and "heavy" or "downpour"
end

local function refreshWeather()
	if not ui.Speed then
		return
	end
	local speed, yaw = windNow()
	ui.Speed.Set(speed / W.MaxSpeed, string.format("%d  ·  %s", speed, windFeel(speed)))
	local r = rainNow()
	ui.Rain.Set(r, string.format("%d%%  ·  %s", math.round(r * 100), rainFeel(r)))
	if not ui.Turning then
		Theme.tween(ui.Arrow, 0.25, { Rotation = -yaw })
	end
	ui.Dir.Text = string.format("Blowing toward %s  (%d°)", COMPASS[math.round((yaw % 360) / 45) % 8 + 1], yaw % 360)
end

local function buildWeather(page)
	Theme.text(page, "For everyone on the server", 12, { TextColor3 = C.Faint, Size = UDim2.new(1, 0, 0, 16) })
	ui.Speed = slider(page, 26, "Wind speed", function(t)
		local _, yaw = windNow()
		local speed = math.round(t * W.MaxSpeed)
		sendWind(speed, yaw)
	end)

	-- the compass: screen up is north (-Z); the arrow points where the wind blows
	local dial = Theme.new("TextButton", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 96),
		Size = UDim2.fromOffset(170, 170),
		BackgroundColor3 = C.Cell,
		AutoButtonColor = false,
		Text = "",
		Parent = page,
	})
	Theme.corner(dial, 85)
	local dialStroke = Theme.stroke(dial, C.CellEdge, 1)
	local inner = Theme.new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(120, 120), BackgroundTransparency = 1, Parent = dial })
	Theme.corner(inner, 60)
	Theme.stroke(inner, C.CellEdge, 1, 0.5)
	for i, name in ipairs({ "N", "E", "S", "W" }) do
		local a = math.rad((i - 1) * 90)
		Theme.text(dial, name, 13, {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, math.sin(a) * 72, 0.5, -math.cos(a) * 72),
			Size = UDim2.fromOffset(20, 18),
			FontFace = name == "N" and Theme.Fonts.Strong or Theme.Fonts.Body,
			TextColor3 = name == "N" and C.Gold or C.Muted,
			TextXAlignment = Enum.TextXAlignment.Center,
		})
	end
	for i = 0, 7 do
		local a = math.rad(i * 45 + 22.5)
		Theme.new("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, math.sin(a) * 72, 0.5, -math.cos(a) * 72),
			Size = UDim2.fromOffset(2, 2),
			BackgroundColor3 = C.Faint,
			BorderSizePixel = 0,
			Parent = dial,
		})
	end
	-- the arrow: a frame as big as the dial, turned; the shaft and head point up inside it
	local arrow = Theme.new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(120, 120), BackgroundTransparency = 1, ZIndex = 2, Parent = dial })
	Theme.new("Frame", { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 18), Size = UDim2.fromOffset(3, 70), BackgroundColor3 = C.Accent, BorderSizePixel = 0, ZIndex = 2, Parent = arrow })
	local head = Theme.new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0, 20), Size = UDim2.fromOffset(14, 14), Rotation = 45, BackgroundTransparency = 1, ZIndex = 2, Parent = arrow })
	-- the head: two sides of a turned square, as an open chevron
	Theme.new("Frame", { Size = UDim2.new(1, 0, 0, 3), BackgroundColor3 = C.Accent, BorderSizePixel = 0, ZIndex = 2, Parent = head })
	Theme.new("Frame", { Size = UDim2.new(0, 3, 1, 0), BackgroundColor3 = C.Accent, BorderSizePixel = 0, ZIndex = 2, Parent = head })
	local hub = Theme.new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(12, 12), BackgroundColor3 = C.Gold, ZIndex = 3, Parent = arrow })
	Theme.corner(hub, 6)
	ui.Arrow = arrow
	ui.Dir = Theme.text(page, "", 13, { Position = UDim2.fromOffset(0, 272), TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = C.Muted })

	local function aim(final)
		local m = UserInputService:GetMouseLocation()
		local c = dial.AbsolutePosition + dial.AbsoluteSize / 2
		local v = m - c
		if v.Magnitude < 4 then
			return
		end
		-- clockwise screen angle from up; yaw counts the other way round (90 = west)
		local screen = math.deg(math.atan2(v.X, -v.Y))
		local yaw = math.round(-screen / 15) * 15 % 360
		arrow.Rotation = -yaw
		ui.Dir.Text = string.format("Blowing toward %s  (%d°)", COMPASS[math.round(yaw / 45) % 8 + 1], yaw)
		local speed = windNow()
		sendWind(speed, yaw)
		if final then
			ui.Turning = false
		end
	end
	dial.InputBegan:Connect(function(io)
		if io.UserInputType == Enum.UserInputType.MouseButton1 or io.UserInputType == Enum.UserInputType.Touch then
			ui.Turning = true
			Theme.tween(dialStroke, 0.15, { Color = C.Gold })
			aim(false)
		end
	end)
	UserInputService.InputChanged:Connect(function(io)
		if ui.Turning and (io.UserInputType == Enum.UserInputType.MouseMovement or io.UserInputType == Enum.UserInputType.Touch) then
			aim(false)
		end
	end)
	UserInputService.InputEnded:Connect(function(io)
		if ui.Turning and (io.UserInputType == Enum.UserInputType.MouseButton1 or io.UserInputType == Enum.UserInputType.Touch) then
			Theme.tween(dialStroke, 0.2, { Color = C.CellEdge })
			aim(true)
		end
	end)

	ui.Rain = slider(page, 304, "Rain", function(t)
		sendRain(math.round(t * 20) / 20)
	end)

	-- presets
	Theme.text(page, "Presets", 14, { Position = UDim2.fromOffset(0, 372), FontFace = Theme.Fonts.Medium })
	local row = Theme.new("Frame", { Position = UDim2.fromOffset(0, 398), Size = UDim2.new(1, 0, 0, 34), BackgroundTransparency = 1, Parent = page })
	Theme.new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6), Parent = row })
	for _, p in ipairs(PRESETS) do
		local b = Theme.button(row, p[1], 13, { Size = UDim2.new(1 / #PRESETS, -5, 1, 0), BackgroundColor3 = C.Cell })
		Theme.corner(b, 8)
		Theme.stroke(b, C.CellEdge, 1)
		Theme.hover(b)
		b.Activated:Connect(function()
			local _, yaw = windNow()
			InventoryClient.Send("Wind", p[2], yaw)
			task.delay(0.06, function()
				InventoryClient.Send("Rain", p[3])
			end)
		end)
	end

	for _, attr in ipairs({ "WindSpeed", "WindYaw", "RainIntensity" }) do
		workspace:GetAttributeChangedSignal(attr):Connect(refreshWeather)
	end
	refreshWeather()
end

------------------------------------------------------------------ the drawer
local function selectTab(name)
	tab = name
	for n, t in pairs(ui.Tabs) do
		local on = n == name
		Theme.tween(t.Button, 0.15, { TextColor3 = on and C.Text or C.Muted })
		t.Page.Visible = on
	end
	local b = ui.Tabs[name].Button
	Theme.tween(ui.Underline, 0.25, {
		Position = UDim2.fromOffset(b.AbsolutePosition.X - ui.TabRow.AbsolutePosition.X, 82),
		Size = UDim2.fromOffset(b.AbsoluteSize.X, 2),
	})
	local page = ui.Tabs[name].Page
	page.Position = UDim2.fromOffset(12, 108)
	Theme.tween(page, 0.25, { Position = UDim2.fromOffset(0, 108) })
end

function CreativeMenu.IsOpen()
	return open
end

function CreativeMenu.Toggle(ctx)
	open = not open
	ui.Gui.Enabled = true
	if open then
		ui.Drawer.Position = UDim2.new(1, 20, 0.5, 0)
		Theme.tween(ui.Drawer, 0.35, { Position = UDim2.new(1, -16, 0.5, 0) }, Q)
		Theme.tween(ui.Shade, 0.35, { BackgroundTransparency = 0.6 }, Q)
		refreshItems()
		refreshWeather()
		task.defer(selectTab, tab)
	else
		ItemTooltip.Hide()
		if ui.Search then
			ui.Search:ReleaseFocus()
		end
		Theme.tween(ui.Drawer, 0.25, { Position = UDim2.new(1, WIDTH + 40, 0.5, 0) }, Q, Enum.EasingDirection.In)
		Theme.tween(ui.Shade, 0.25, { BackgroundTransparency = 1 }, Q)
	end
	ctx.SyncMenus()
end

function CreativeMenu.Init(ctx, playerGui)
	local gui = Theme.new("ScreenGui", {
		Name = "RR_Creative",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = 22,
		Parent = playerGui,
	})
	ui.Gui = gui
	-- a shade over the right of the screen behind the drawer
	ui.Shade = Theme.new("Frame", {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.new(0, WIDTH + 200, 1, 0),
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 1,
		Parent = gui,
	})
	Theme.new("UIGradient", { Transparency = NumberSequence.new(1, 0), Parent = ui.Shade })

	local drawer = Theme.new("Frame", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, WIDTH + 40, 0.5, 0),
		Size = UDim2.new(0, WIDTH, 1, -80),
		BackgroundColor3 = C.Panel,
		BackgroundTransparency = 0.02,
		Active = true,
		Parent = gui,
	})
	Theme.corner(drawer, 12)
	Theme.stroke(drawer, C.PanelEdge, 1)
	Theme.pad(drawer, 20)
	ui.Drawer = drawer

	Theme.text(drawer, "Creative", 24, { Size = UDim2.new(1, 0, 0, 30), FontFace = Theme.Fonts.Title })
	Theme.text(drawer, "M  close", 13, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 8),
		Size = UDim2.fromOffset(100, 18),
		TextXAlignment = Enum.TextXAlignment.Right,
		TextColor3 = C.Faint,
	})
	local tabRow = Theme.new("Frame", { Position = UDim2.fromOffset(0, 50), Size = UDim2.new(1, 0, 0, 36), BackgroundTransparency = 1, Parent = drawer })
	Theme.new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 22), SortOrder = Enum.SortOrder.LayoutOrder, Parent = tabRow })
	ui.TabRow = tabRow
	Theme.new("Frame", { Position = UDim2.fromOffset(0, 85), Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = C.CellEdge, BorderSizePixel = 0, Parent = drawer })
	-- under the chosen tab (placed by selectTab)
	ui.Underline = Theme.new("Frame", { Position = UDim2.fromOffset(0, 82), Size = UDim2.fromOffset(40, 2), BackgroundColor3 = C.Accent, BorderSizePixel = 0, Parent = drawer })
	ui.Tabs = {}
	for i, name in ipairs({ "Items", "Weather" }) do
		local b = Theme.button(tabRow, name, 16, {
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.fromOffset(0, 32),
			BackgroundTransparency = 1,
			FontFace = Theme.Fonts.Strong,
			TextColor3 = C.Muted,
			LayoutOrder = i,
		})
		local page = Theme.new("Frame", { Position = UDim2.fromOffset(0, 108), Size = UDim2.new(1, 0, 1, -108), BackgroundTransparency = 1, Visible = false, Parent = drawer })
		ui.Tabs[name] = { Button = b, Page = page }
		b.Activated:Connect(function()
			selectTab(name)
		end)
	end
	buildItems(ui.Tabs.Items.Page)
	buildWeather(ui.Tabs.Weather.Page)
	ui.Tabs.Items.Page.Visible = true
end

-- server refusal (Feedback "LoadoutRefused")
function CreativeMenu.Refused(reason)
	Theme.toast(ui.Gui, tostring(reason))
end

return CreativeMenu
