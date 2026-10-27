--[[
	MainMenu: TAB opens the game's menu. The screen darkens and blurs, and two diamonds spin in
	one after the other: the sword (WeaponPanel) and the fighter (CharacterPanel, the inventory).
	Hovering a diamond lifts it and turns its inner ring; clicking it sends the other away and
	unrolls that screen from the middle like a scroll, between two gold rods. Back (or Backspace)
	rolls it up again and brings the diamonds back; TAB closes the menu from anywhere.
	While it is open the mouse is free and the fighter takes no input (ctx.MenuOpen, see
	ctx.SyncMenus in the client bootstrap).
]]
local Lighting = game:GetService("Lighting")
local Theme = require(script.Parent.UITheme)
local DragDrop = require(script.Parent.DragDrop)
local ItemTooltip = require(script.Parent.ItemTooltip)
local CharacterPanel = require(script.Parent.CharacterPanel)
local WeaponPanel = require(script.Parent.WeaponPanel)

local MainMenu = {}
local C = Theme.Colors

local PANEL = Vector2.new(1000, 600)
local DIAMOND = 128 -- side of the square, turned 45 degrees
local Q, BACK, SINE = Enum.EasingStyle.Quint, Enum.EasingStyle.Back, Enum.EasingStyle.Sine
local OUT, IN = Enum.EasingDirection.Out, Enum.EasingDirection.In

local ui = {}
local state = "Closed" -- Closed | Hub | Weapon | Character
local generation = 0 -- bumped on every change, so a stale delayed step does nothing
local diamonds = {}
local panels = {}
local blur

local function later(t, fn)
	local g = generation
	task.delay(t, function()
		if g == generation then
			fn()
		end
	end)
end

------------------------------------------------------------------ glyphs
local function bar(parent, x, y, w, h, color, rot, radius)
	local f = Theme.new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(x, y),
		Size = UDim2.fromOffset(w, h),
		Rotation = rot or 0,
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		Parent = parent,
	})
	if radius then
		Theme.corner(f, radius)
	end
	return f
end

-- a katana drawn upright in an 80 x 80 frame, then tilted so the tip points up and right
local function swordGlyph(parent)
	local g = Theme.new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(80, 80), BackgroundTransparency = 1, Rotation = 40, Parent = parent })
	bar(g, 40, 29, 5, 46, C.Text, 0, 1) -- blade
	bar(g, 41.2, 29, 1.6, 44, Color3.fromRGB(255, 255, 255)) -- edge
	bar(g, 40, 6, 3.6, 3.6, C.Text, 45) -- tip
	bar(g, 40, 54, 20, 4, C.Gold, 0, 2) -- tsuba
	bar(g, 40, 64, 5.5, 17, Color3.fromRGB(60, 48, 44), 0, 1) -- tsuka
	for i = 0, 2 do
		bar(g, 40, 58.5 + i * 5, 6.5, 1.5, C.Gold, i % 2 == 0 and 25 or -25)
	end
	bar(g, 40, 73.5, 7, 3, C.Gold, 0, 1) -- kashira
	return g
end

-- a fighter's bust: head and shoulders
local function playerGlyph(parent)
	local g = Theme.new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(80, 80), BackgroundTransparency = 1, Parent = parent })
	bar(g, 40, 25, 24, 24, C.Text, 0, 12) -- head
	bar(g, 40, 55, 44, 26, C.Text, 0, 13) -- shoulders
	bar(g, 40, 66, 44, 8, C.Text) -- squared off at the bottom
	bar(g, 40, 44.5, 10, 5, C.Gold) -- the collar
	return g
end

------------------------------------------------------------------ diamonds
local function diamond(parent, x, title, sub, glyph, onClick)
	local d = {}
	local holder = Theme.new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, x, 0.5, -10),
		Size = UDim2.fromOffset(200, 260),
		BackgroundTransparency = 1,
		Parent = parent,
	})
	d.Holder = holder
	d.Scale = Theme.scaleOf(holder)
	local function rotated(size, z)
		return Theme.new("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromOffset(100, 100),
			Size = UDim2.fromOffset(size, size),
			Rotation = 45,
			BackgroundTransparency = 1,
			ZIndex = z,
			Parent = holder,
		})
	end
	d.Glow = rotated(DIAMOND, 1)
	d.Glow.BackgroundColor3 = C.Accent
	Theme.corner(d.Glow, 10)
	d.GlowScale = Theme.scaleOf(d.Glow)
	d.Burst = rotated(DIAMOND, 1)
	Theme.corner(d.Burst, 10)
	d.BurstStroke = Theme.stroke(d.Burst, C.Gold, 1.5, 1)
	d.BurstScale = Theme.scaleOf(d.Burst)
	d.Main = rotated(DIAMOND, 2)
	d.Main.BackgroundColor3 = C.Panel
	Theme.corner(d.Main, 10)
	d.MainStroke = Theme.stroke(d.Main, C.Gold, 1.5, 1)
	Theme.new("UIGradient", {
		Rotation = 45,
		Color = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(150, 140, 140)),
		Parent = d.Main,
	})
	d.Inner = rotated(DIAMOND - 22, 3)
	Theme.corner(d.Inner, 7)
	d.InnerStroke = Theme.stroke(d.Inner, C.Gold, 1, 1)
	local glyphHolder = Theme.new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(100, 100), Size = UDim2.fromOffset(80, 80), BackgroundTransparency = 1, ZIndex = 4, Parent = holder })
	glyph(glyphHolder)
	d.Glyph = Theme.scaleOf(glyphHolder)
	d.Title = Theme.text(holder, title, 20, {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromOffset(100, 200),
		Size = UDim2.fromOffset(200, 26),
		FontFace = Theme.Fonts.Title,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextTransparency = 1,
	})
	d.Sub = Theme.text(holder, sub, 13, {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromOffset(100, 228),
		Size = UDim2.fromOffset(200, 18),
		TextColor3 = C.Muted,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextTransparency = 1,
	})
	local hit = Theme.new("TextButton", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(100, 100),
		Size = UDim2.fromOffset(DIAMOND * 1.2, DIAMOND * 1.2),
		BackgroundTransparency = 1,
		Text = "",
		ZIndex = 5,
		Parent = holder,
	})
	hit.MouseEnter:Connect(function()
		if state ~= "Hub" or not d.Ready then
			return
		end
		Theme.tween(d.Scale, 0.2, { Scale = 1.08 }, Q)
		Theme.tween(d.Glow, 0.25, { BackgroundTransparency = 0.72 })
		Theme.tween(d.GlowScale, 0.3, { Scale = 1.18 }, Q)
		Theme.tween(d.Inner, 0.45, { Rotation = 135 }, Q)
		Theme.tween(d.InnerStroke, 0.2, { Transparency = 0.1 })
		Theme.tween(d.Title, 0.2, { TextColor3 = C.Gold })
	end)
	hit.MouseLeave:Connect(function()
		if state ~= "Hub" or not d.Ready then
			return
		end
		Theme.tween(d.Scale, 0.25, { Scale = 1 }, Q)
		Theme.tween(d.Glow, 0.25, { BackgroundTransparency = 1 })
		Theme.tween(d.GlowScale, 0.3, { Scale = 1 }, Q)
		Theme.tween(d.Inner, 0.45, { Rotation = 45 }, Q)
		Theme.tween(d.InnerStroke, 0.2, { Transparency = 0.55 })
		Theme.tween(d.Title, 0.2, { TextColor3 = C.Text })
	end)
	hit.Activated:Connect(function()
		if state == "Hub" and d.Ready then
			onClick()
		end
	end)
	table.insert(diamonds, d)
	return d
end

-- spin and grow in, after `delay`
local function diamondIn(d, delay)
	d.Ready = false
	d.Holder.Visible = true
	d.Scale.Scale = 0.45
	d.Main.Rotation, d.Inner.Rotation = -45, -135
	d.Main.BackgroundTransparency = 1
	d.MainStroke.Transparency, d.InnerStroke.Transparency = 1, 1
	d.Glow.BackgroundTransparency, d.GlowScale.Scale = 1, 1
	d.Glyph.Scale = 0
	d.Title.TextTransparency, d.Sub.TextTransparency = 1, 1
	d.Title.TextColor3 = C.Text
	d.Title.Position = UDim2.fromOffset(100, 212)
	d.Sub.Position = UDim2.fromOffset(100, 240)
	Theme.tween(d.Scale, 0.55, { Scale = 1 }, BACK, OUT, delay)
	Theme.tween(d.Main, 0.6, { Rotation = 45, BackgroundTransparency = 0.04 }, Q, OUT, delay)
	Theme.tween(d.MainStroke, 0.4, { Transparency = 0 }, Q, OUT, delay)
	Theme.tween(d.Inner, 0.8, { Rotation = 45 }, Q, OUT, delay)
	Theme.tween(d.InnerStroke, 0.5, { Transparency = 0.55 }, Q, OUT, delay + 0.1)
	Theme.tween(d.Glyph, 0.45, { Scale = 1 }, BACK, OUT, delay + 0.16)
	Theme.tween(d.Title, 0.4, { TextTransparency = 0, Position = UDim2.fromOffset(100, 200) }, Q, OUT, delay + 0.22)
	Theme.tween(d.Sub, 0.4, { TextTransparency = 0, Position = UDim2.fromOffset(100, 228) }, Q, OUT, delay + 0.28)
	-- a ring bursting out as it lands
	d.BurstScale.Scale = 1
	d.BurstStroke.Transparency = 1
	later(delay + 0.3, function()
		d.BurstStroke.Transparency = 0.1
		Theme.tween(d.BurstScale, 0.7, { Scale = 1.7 }, Q)
		Theme.tween(d.BurstStroke, 0.7, { Transparency = 1 }, Q)
	end)
	later(delay + 0.4, function()
		d.Ready = true
	end)
end

-- leave: the chosen one swells and fades, the other shrinks away
local function diamondOut(d, chosen)
	d.Ready = false
	local t = chosen and 0.32 or 0.22
	Theme.tween(d.Scale, t, { Scale = chosen and 1.3 or 0.6 }, Q, chosen and OUT or IN)
	Theme.tween(d.Main, t, { BackgroundTransparency = 1, Rotation = chosen and 90 or 0 }, Q)
	Theme.tween(d.MainStroke, t, { Transparency = 1 }, Q)
	Theme.tween(d.InnerStroke, t * 0.7, { Transparency = 1 }, Q)
	Theme.tween(d.Glow, t, { BackgroundTransparency = 1 }, Q)
	Theme.tween(d.Glyph, t, { Scale = chosen and 1.25 or 0 }, Q)
	Theme.tween(d.Title, t * 0.7, { TextTransparency = 1 }, Q)
	Theme.tween(d.Sub, t * 0.7, { TextTransparency = 1 }, Q)
	if chosen then
		-- the glyph is solid: let it go once the rest has faded
		later(t * 0.8, function()
			Theme.tween(d.Glyph, 0.12, { Scale = 0 }, Q, IN)
		end)
	end
end

------------------------------------------------------------------ panels
local function makePanel(title, subtitle)
	local p = {}
	local root = Theme.new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(PANEL.X, PANEL.Y),
		BackgroundTransparency = 1,
		Visible = false,
		Parent = ui.Stage,
	})
	p.Root = root
	local sheet = Theme.new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(0, PANEL.Y),
		BackgroundColor3 = C.Panel,
		BackgroundTransparency = 0.02,
		ClipsDescendants = true,
		Parent = root,
	})
	Theme.new("UIGradient", {
		Rotation = 90,
		Color = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(200, 196, 196)),
		Parent = sheet,
	})
	p.Sheet = sheet
	local content = Theme.new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(PANEL.X, PANEL.Y),
		BackgroundTransparency = 1,
		Parent = sheet,
	})
	p.Content = content
	-- the scroll's rods, top to bottom past the sheet
	p.Rods = {}
	for _, sx in ipairs({ -1, 1 }) do
		local rod = Theme.new("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(8, PANEL.Y + 28),
			BackgroundColor3 = C.Gold,
			BorderSizePixel = 0,
			ZIndex = 3,
			Parent = root,
		})
		Theme.corner(rod, 4)
		Theme.new("UIGradient", {
			Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, Color3.fromRGB(120, 92, 50)),
				ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 226, 160)),
				ColorSequenceKeypoint.new(1, Color3.fromRGB(120, 92, 50)),
			}),
			Parent = rod,
		})
		table.insert(p.Rods, { Frame = rod, Side = sx })
	end

	-- header: back, title, close hint
	local back = Theme.button(content, "‹  Back", 15, {
		Position = UDim2.fromOffset(28, 22),
		Size = UDim2.fromOffset(92, 34),
		BackgroundColor3 = C.Cell,
	})
	Theme.corner(back, 8)
	Theme.stroke(back, C.CellEdge, 1)
	Theme.hover(back)
	back.Activated:Connect(function()
		MainMenu.Back()
	end)
	Theme.text(content, title, 26, {
		Position = UDim2.fromOffset(136, 16),
		Size = UDim2.fromOffset(400, 32),
		FontFace = Theme.Fonts.Title,
	})
	Theme.text(content, subtitle, 13, {
		Position = UDim2.fromOffset(137, 48),
		Size = UDim2.fromOffset(500, 18),
		TextColor3 = C.Muted,
	})
	Theme.text(content, "TAB  close", 13, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -28, 0, 30),
		Size = UDim2.fromOffset(120, 18),
		TextXAlignment = Enum.TextXAlignment.Right,
		TextColor3 = C.Faint,
	})
	return p
end

local function unroll(p)
	p.Root.Visible = true
	p.Sheet.Size = UDim2.fromOffset(0, PANEL.Y)
	Theme.tween(p.Sheet, 0.55, { Size = UDim2.fromOffset(PANEL.X, PANEL.Y) }, Q)
	for _, rod in ipairs(p.Rods) do
		rod.Frame.Position = UDim2.fromScale(0.5, 0.5)
		rod.Frame.BackgroundTransparency = 0
		Theme.tween(rod.Frame, 0.55, { Position = UDim2.new(0.5, rod.Side * (PANEL.X / 2 + 2), 0.5, 0) }, Q)
	end
	p.Panel:Opened()
end

local function rollUp(p, t, done)
	p.Panel:Closed()
	DragDrop.Cancel()
	ItemTooltip.Hide()
	Theme.tween(p.Sheet, t, { Size = UDim2.fromOffset(0, PANEL.Y) }, Q, IN)
	for _, rod in ipairs(p.Rods) do
		Theme.tween(rod.Frame, t, { Position = UDim2.fromScale(0.5, 0.5) }, Q, IN)
		Theme.tween(rod.Frame, 0.12, { BackgroundTransparency = 1 }, Q, IN, t)
	end
	later(t + 0.12, function()
		p.Root.Visible = false
		if done then
			done()
		end
	end)
end

------------------------------------------------------------------ states
local function showHub()
	state = "Hub"
	ui.Hub.Visible = true
	ui.HubTitle.TextTransparency = 1
	Theme.tween(ui.HubTitle, 0.5, { TextTransparency = 0.2 }, Q, OUT, 0.05)
	ui.Line.Size = UDim2.fromOffset(0, 1)
	Theme.tween(ui.Line, 0.6, { Size = UDim2.fromOffset(460, 1) }, Q, OUT, 0.15)
	ui.LineGem.Rotation = 0
	Theme.tween(ui.LineGem, 0.6, { Rotation = 225 }, Q, OUT, 0.15)
	for i, d in ipairs(diamonds) do
		diamondIn(d, 0.06 + (i - 1) * 0.1)
	end
end

local function hideHub(chosen)
	for _, d in ipairs(diamonds) do
		diamondOut(d, d == chosen)
	end
	Theme.tween(ui.HubTitle, 0.2, { TextTransparency = 1 }, Q)
	Theme.tween(ui.Line, 0.25, { Size = UDim2.fromOffset(0, 1) }, Q, IN)
	later(0.34, function()
		ui.Hub.Visible = false
	end)
end

local function open(name, chosen)
	generation += 1
	hideHub(chosen)
	state = name
	later(0.22, function()
		unroll(panels[name])
	end)
end

function MainMenu.IsOpen()
	return state ~= "Closed"
end

function MainMenu.Open(ctx)
	if state ~= "Closed" then
		return
	end
	generation += 1
	ui.Root.Visible = true
	ui.Backdrop.BackgroundTransparency = 1
	Theme.tween(ui.Backdrop, 0.35, { BackgroundTransparency = 0.38 }, Q)
	blur.Size = 0
	blur.Enabled = true
	Theme.tween(blur, 0.35, { Size = 14 }, Q)
	showHub()
	ctx.SyncMenus()
end

function MainMenu.Close(ctx)
	if state == "Closed" then
		return
	end
	generation += 1
	local p = panels[state]
	if p then
		rollUp(p, 0.22)
	else
		hideHub(nil)
	end
	state = "Closed"
	Theme.tween(ui.Backdrop, 0.3, { BackgroundTransparency = 1 }, Q, OUT, 0.08)
	Theme.tween(blur, 0.3, { Size = 0 }, Q, OUT, 0.08)
	later(0.4, function()
		ui.Root.Visible = false
		blur.Enabled = false
	end)
	ctx.SyncMenus()
end

function MainMenu.Toggle(ctx)
	if state == "Closed" then
		MainMenu.Open(ctx)
	else
		MainMenu.Close(ctx)
	end
end

-- from a screen back to the diamonds
function MainMenu.Back()
	local p = panels[state]
	if not p then
		return
	end
	generation += 1
	state = "Hub"
	for _, d in ipairs(diamonds) do
		d.Ready = false
	end
	rollUp(p, 0.3, function()
		showHub()
	end)
end

function MainMenu.Init(ctx, playerGui)
	blur = Instance.new("BlurEffect")
	blur.Name = "RR_MenuBlur"
	blur.Size = 0
	blur.Enabled = false
	blur.Parent = Lighting

	local gui = Theme.new("ScreenGui", {
		Name = "RR_MainMenu",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 20,
		Parent = playerGui,
	})
	ui.Gui = gui
	local root = Theme.new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Visible = false, Parent = gui })
	ui.Root = root
	ui.Backdrop = Theme.new("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = C.Backdrop,
		BackgroundTransparency = 1,
		Active = true, -- clicks on the backdrop don't reach the game
		Parent = root,
	})
	-- darker toward the edges
	local vignette = Theme.new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0, Parent = ui.Backdrop })
	Theme.new("UIGradient", {
		Rotation = 90,
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.35),
			NumberSequenceKeypoint.new(0.3, 1),
			NumberSequenceKeypoint.new(0.7, 1),
			NumberSequenceKeypoint.new(1, 0.35),
		}),
		Parent = vignette,
	})

	-- everything else scales down to fit small screens
	local stage = Theme.new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Parent = root })
	ui.Stage = stage
	local fit = Theme.new("UIScale", { Parent = stage })
	local function refit()
		local s = gui.AbsoluteSize
		fit.Scale = math.clamp(math.min((s.X - 40) / PANEL.X, (s.Y - 60) / (PANEL.Y + 40)), 0.45, 1)
	end
	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(refit)
	refit()

	-- the hub: a title, two diamonds and a line under them
	local hub = Theme.new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Visible = false, Parent = stage })
	ui.Hub = hub
	ui.HubTitle = Theme.text(hub, "RAGDOLL  RONIN", 16, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, -190),
		Size = UDim2.fromOffset(400, 24),
		FontFace = Theme.Fonts.Title,
		TextColor3 = C.Gold,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextTransparency = 1,
	})
	ui.Line = Theme.new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, 150),
		Size = UDim2.fromOffset(0, 1),
		BackgroundColor3 = C.Gold,
		BorderSizePixel = 0,
		Parent = hub,
	})
	Theme.new("UIGradient", {
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.5, 0.3),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Parent = ui.Line,
	})
	ui.LineGem = Theme.new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, 150),
		Size = UDim2.fromOffset(7, 7),
		BackgroundColor3 = C.Gold,
		BorderSizePixel = 0,
		Parent = hub,
	})
	Theme.text(hub, "TAB  close", 13, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, 190),
		Size = UDim2.fromOffset(200, 18),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = C.Faint,
	})
	local weapon, character
	weapon = diamond(hub, -140, "Weapon", "Katana · incantations", swordGlyph, function()
		open("Weapon", weapon)
	end)
	character = diamond(hub, 140, "Character", "Inventory · equipment", playerGlyph, function()
		open("Character", character)
	end)

	local wp = makePanel("Weapon", "Your katana and the incantation set on it")
	wp.Panel = WeaponPanel.new(wp.Content, ctx)
	panels.Weapon = wp
	local cp = makePanel("Inventory", "What you carry and what you wear")
	cp.Panel = CharacterPanel.new(cp.Content, ctx)
	panels.Character = cp
end

-- server refusal (Feedback "LoadoutRefused")
function MainMenu.Refused(reason)
	Theme.toast(ui.Gui, tostring(reason))
end

return MainMenu
