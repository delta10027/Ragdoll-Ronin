--[[
	UITheme: the menus' look (TAB menu, inventory, sword, creative menu) and small builders for it.
	Fonts: Merriweather for titles, Builder Sans for everything else.
]]
local TweenService = game:GetService("TweenService")

local Theme = {}

Theme.Colors = {
	Backdrop = Color3.fromRGB(6, 5, 7),
	Panel = Color3.fromRGB(19, 17, 20),
	PanelEdge = Color3.fromRGB(70, 60, 52),
	Cell = Color3.fromRGB(30, 27, 31),
	CellHover = Color3.fromRGB(44, 40, 44),
	CellEdge = Color3.fromRGB(56, 50, 52),
	Accent = Color3.fromRGB(200, 60, 48), -- vermilion
	Gold = Color3.fromRGB(208, 172, 102),
	Text = Color3.fromRGB(238, 231, 220),
	Muted = Color3.fromRGB(150, 140, 130),
	Faint = Color3.fromRGB(96, 88, 84),
	Bad = Color3.fromRGB(236, 112, 96),
	Good = Color3.fromRGB(140, 196, 120),
	Armour = Color3.fromRGB(122, 152, 196),
	Cosmetic = Color3.fromRGB(176, 164, 150),
	Book = Color3.fromRGB(232, 124, 62),
}

Theme.Fonts = {
	Title = Font.new("rbxasset://fonts/families/Merriweather.json", Enum.FontWeight.Bold),
	Body = Font.new("rbxasset://fonts/families/BuilderSans.json", Enum.FontWeight.Regular),
	Medium = Font.new("rbxasset://fonts/families/BuilderSans.json", Enum.FontWeight.Medium),
	Strong = Font.new("rbxasset://fonts/families/BuilderSans.json", Enum.FontWeight.Bold),
}

-- Instance.new with properties (Parent last) and children
function Theme.new(class, props, children)
	local inst = Instance.new(class)
	local parent
	for k, v in pairs(props or {}) do
		if k == "Parent" then
			parent = v
		else
			inst[k] = v
		end
	end
	for _, c in ipairs(children or {}) do
		c.Parent = inst
	end
	inst.Parent = parent
	return inst
end

function Theme.corner(parent, radius)
	return Theme.new("UICorner", { CornerRadius = UDim.new(0, radius or 6), Parent = parent })
end

function Theme.stroke(parent, color, thickness, transparency)
	return Theme.new("UIStroke", {
		Color = color or Theme.Colors.CellEdge,
		Thickness = thickness or 1,
		Transparency = transparency or 0,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Parent = parent,
	})
end

function Theme.pad(parent, px)
	return Theme.new("UIPadding", {
		PaddingTop = UDim.new(0, px),
		PaddingBottom = UDim.new(0, px),
		PaddingLeft = UDim.new(0, px),
		PaddingRight = UDim.new(0, px),
		Parent = parent,
	})
end

-- a TextLabel: Body font, Text colour, left aligned, no background
function Theme.text(parent, text, size, props)
	local l = Theme.new("TextLabel", {
		BackgroundTransparency = 1,
		FontFace = Theme.Fonts.Body,
		TextSize = size or 14,
		TextColor3 = Theme.Colors.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = text or "",
		Size = UDim2.new(1, 0, 0, (size or 14) + 6),
	})
	for k, v in pairs(props or {}) do
		l[k] = v
	end
	l.Parent = parent
	return l
end

-- a plain text button (no auto colouring: the caller animates hover)
function Theme.button(parent, text, size, props)
	local b = Theme.new("TextButton", {
		AutoButtonColor = false,
		BackgroundColor3 = Theme.Colors.Cell,
		BorderSizePixel = 0,
		FontFace = Theme.Fonts.Medium,
		TextSize = size or 14,
		TextColor3 = Theme.Colors.Text,
		Text = text or "",
	})
	for k, v in pairs(props or {}) do
		b[k] = v
	end
	b.Parent = parent
	return b
end

function Theme.tween(inst, time, props, style, direction, delay)
	local t = TweenService:Create(inst, TweenInfo.new(time, style or Enum.EasingStyle.Quint, direction or Enum.EasingDirection.Out, 0, false, delay or 0), props)
	t:Play()
	return t
end

-- a UIScale on the object (made once)
function Theme.scaleOf(obj)
	local s = obj:FindFirstChildOfClass("UIScale")
	if not s then
		s = Theme.new("UIScale", { Parent = obj })
	end
	return s
end

-- hover feedback for a button: background, stroke and a slight grow
function Theme.hover(button, opts)
	opts = opts or {}
	local stroke = button:FindFirstChildOfClass("UIStroke")
	local base = button.BackgroundColor3
	local scale = Theme.scaleOf(button)
	button.MouseEnter:Connect(function()
		Theme.tween(button, 0.15, { BackgroundColor3 = opts.Hover or Theme.Colors.CellHover })
		Theme.tween(scale, 0.15, { Scale = opts.Grow or 1.03 })
		if stroke then
			Theme.tween(stroke, 0.15, { Color = opts.StrokeHover or Theme.Colors.Gold })
		end
	end)
	button.MouseLeave:Connect(function()
		Theme.tween(button, 0.2, { BackgroundColor3 = opts.Base or base })
		Theme.tween(scale, 0.2, { Scale = 1 })
		if stroke then
			Theme.tween(stroke, 0.2, { Color = opts.StrokeBase or Theme.Colors.CellEdge })
		end
	end)
end

-- a magnifying glass drawn from frames (size px square)
function Theme.searchGlyph(parent, size, color)
	local holder = Theme.new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(size, size), Parent = parent })
	local ring = Theme.new("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(size * 0.68, size * 0.68),
		Parent = holder,
	})
	Theme.corner(ring, size)
	Theme.stroke(ring, color, 2)
	Theme.new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(size * 0.78, size * 0.78),
		Size = UDim2.fromOffset(2, size * 0.42),
		Rotation = -45,
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		Parent = holder,
	})
	return holder
end

-- a short message that drops in at the top of the screen and fades out
function Theme.toast(gui, text, color)
	local t = Theme.new("TextLabel", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 40),
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 36),
		BackgroundColor3 = Theme.Colors.Panel,
		BackgroundTransparency = 1,
		FontFace = Theme.Fonts.Medium,
		TextSize = 15,
		TextColor3 = color or Theme.Colors.Bad,
		TextTransparency = 1,
		Text = text,
		ZIndex = 50,
		Parent = gui,
	})
	Theme.corner(t, 8)
	local pad = Theme.pad(t, 0)
	pad.PaddingLeft, pad.PaddingRight = UDim.new(0, 16), UDim.new(0, 16)
	local stroke = Theme.stroke(t, color or Theme.Colors.Bad, 1, 1)
	Theme.tween(t, 0.25, { Position = UDim2.new(0.5, 0, 0, 64), BackgroundTransparency = 0.05, TextTransparency = 0 })
	Theme.tween(stroke, 0.25, { Transparency = 0.4 })
	task.delay(2.4, function()
		Theme.tween(t, 0.3, { Position = UDim2.new(0.5, 0, 0, 52), BackgroundTransparency = 1, TextTransparency = 1 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		Theme.tween(stroke, 0.3, { Transparency = 1 })
		task.delay(0.35, function()
			t:Destroy()
		end)
	end)
end

return Theme
