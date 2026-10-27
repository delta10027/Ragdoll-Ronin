--[[
	WeaponPanel: the sword (TAB > Weapon). On the left the katana, turning slowly, with its
	incantation socket below; on the right the inventory (InventoryGrid), where only books can be
	picked up.
	  drag a book onto the socket or the sword   set it (it swaps with the book there)
	  drag the socket's book onto the grid       take it off
	  right-click                                set it / take it off
	A book on the sword is the incantation J casts with the sword drawn; the blade glows its colour.
]]
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage:WaitForChild("RagdollRonin"):WaitForChild("Config"))
local Theme = require(script.Parent.UITheme)
local ItemArt = require(script.Parent.ItemArt)
local DragDrop = require(script.Parent.DragDrop)
local ItemTooltip = require(script.Parent.ItemTooltip)
local InventoryClient = require(script.Parent.InventoryClient)
local InventoryGrid = require(script.Parent.InventoryGrid)

local WeaponPanel = {}
WeaponPanel.__index = WeaponPanel
local C = Theme.Colors
local IT = Config.Items
local IC = Config.Incantations

local SOCKET = 64
local SWORD_TILT = CFrame.Angles(0, 0, math.rad(-58)) -- tip up to the right

local function isBook(key)
	return IT[key] and IT[key].Kind == "Book"
end

function WeaponPanel.new(content, ctx)
	local self = setmetatable({ Ctx = ctx, Clock = 0 }, WeaponPanel)

	local left = Theme.new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(32, 70), Size = UDim2.fromOffset(400, 500), Parent = content })

	-- the sword
	local vf, world = ItemArt.Viewport({
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 0),
		Size = UDim2.fromOffset(400, 300),
		Parent = left,
	})
	vf.LightDirection = Vector3.new(-0.3, -0.6, -1)
	local katana, blade, edge = ItemArt.Katana()
	self.Base = SWORD_TILT * CFrame.new(0, -(Config.Sword.BladeLength + Config.Sword.HandleLength) * 0.25, 0)
	katana:PivotTo(self.Base)
	katana.Parent = world
	-- the incantation's glow along the blade
	local glow = blade:Clone()
	glow.Name = "Glow"
	glow.Size = blade.Size * Vector3.new(1.9, 1.02, 2.6)
	glow.Material = Enum.Material.Neon
	glow.Transparency = 1
	glow.Parent = katana
	self.Katana, self.Blade, self.Edge, self.Glow = katana, blade, edge, glow
	self.EdgeColor = edge.Color
	self.Center = ItemArt.Frame(vf, katana:GetChildren(), 180, 0, 1.12)
	self.View = vf
	local viewStroke = Theme.stroke(vf, C.Gold, 1, 1)
	DragDrop.Target(vf, {
		Priority = 1,
		Accepts = function(p)
			return p.From == "Grid" and isBook(p.Key)
		end,
		Drop = function(p)
			InventoryClient.Send("Socket", p.Index, p.Key)
		end,
		Highlight = function(state)
			Theme.tween(viewStroke, 0.15, { Transparency = state == "Over" and 0.3 or 1 })
		end,
	})

	Theme.text(left, "Katana", 24, {
		Position = UDim2.fromOffset(0, 300),
		Size = UDim2.new(1, 0, 0, 30),
		FontFace = Theme.Fonts.Title,
		TextXAlignment = Enum.TextXAlignment.Center,
	})
	Theme.text(left, string.format("Blade %.1f studs  ·  one incantation", Config.Sword.BladeLength), 13, {
		Position = UDim2.fromOffset(0, 332),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = C.Muted,
	})

	-- the socket: a diamond set into a band
	local socketArea = Theme.new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 368),
		Size = UDim2.fromOffset(SOCKET * 1.5, SOCKET * 1.5),
		BackgroundTransparency = 1,
		Parent = left,
	})
	for _, sx in ipairs({ -1, 1 }) do
		local band = Theme.new("Frame", {
			AnchorPoint = Vector2.new(sx > 0 and 0 or 1, 0.5),
			Position = UDim2.new(0.5, sx * SOCKET * 0.78, 0.5, 0),
			Size = UDim2.fromOffset(90, 1),
			BackgroundColor3 = C.Gold,
			BorderSizePixel = 0,
			Parent = socketArea,
		})
		Theme.new("UIGradient", {
			Rotation = sx > 0 and 0 or 180,
			Transparency = NumberSequence.new(0.3, 1),
			Parent = band,
		})
	end
	local diamond = Theme.new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(SOCKET, SOCKET),
		Rotation = 45,
		BackgroundColor3 = C.Cell,
		Parent = socketArea,
	})
	Theme.corner(diamond, 6)
	local dStroke = Theme.stroke(diamond, C.Gold, 1.5, 0.3)
	local ring = Theme.new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(SOCKET, SOCKET),
		Rotation = 45,
		BackgroundTransparency = 1,
		Parent = socketArea,
	})
	Theme.corner(ring, 6)
	local ringStroke = Theme.stroke(ring, C.Book, 2, 1)
	local ringScale = Theme.scaleOf(ring)
	local socket = Theme.button(socketArea, "", 14, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(SOCKET, SOCKET),
		BackgroundTransparency = 1,
	})
	local icon = Theme.new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(6, 6), Size = UDim2.new(1, -12, 1, -12), Parent = socket })
	local empty = Theme.text(socket, "+", 22, {
		Size = UDim2.fromScale(1, 1),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = C.Faint,
	})
	local socketScale = Theme.scaleOf(socketArea)
	self.Socket = { Area = socketArea, Diamond = diamond, Stroke = dStroke, Ring = ring, RingStroke = ringStroke, RingScale = ringScale, Icon = icon, Empty = empty, Scale = socketScale }

	Theme.text(left, "INCANTATION", 12, {
		Position = UDim2.fromOffset(0, 368 + SOCKET * 1.5 + 2),
		FontFace = Theme.Fonts.Strong,
		TextColor3 = C.Muted,
		TextXAlignment = Enum.TextXAlignment.Center,
	})
	self.Info = Theme.text(left, "", 13, {
		Position = UDim2.fromOffset(0, 368 + SOCKET * 1.5 + 22),
		Size = UDim2.new(1, 0, 0, 34),
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = C.Muted,
	})

	local function hover(on)
		if self.SocketGlow then
			return
		end
		Theme.tween(socketScale, 0.15, { Scale = on and 1.06 or 1 })
		Theme.tween(diamond, 0.15, { BackgroundColor3 = on and C.CellHover or C.Cell })
		Theme.tween(dStroke, 0.15, { Transparency = on and 0 or 0.3 })
	end
	socket.MouseEnter:Connect(function()
		if DragDrop.Dragging() then
			return
		end
		hover(true)
		if self.Book then
			ItemTooltip.Show(self.Book, "Drag onto the grid · right-click to take off")
		end
	end)
	socket.MouseLeave:Connect(function()
		hover(false)
		ItemTooltip.Hide(self.Book)
	end)
	socket.MouseButton2Click:Connect(function()
		if self.Book then
			ItemTooltip.Hide()
			InventoryClient.Send("Unsocket")
		end
	end)
	DragDrop.Source(socket, function()
		local key = self.Book
		if not key then
			return nil
		end
		return {
			Key = key,
			From = "Socket",
			Icon = function()
				return ItemArt.Icon(key)
			end,
			Return = function()
				InventoryClient.Send("Unsocket")
			end,
		}
	end)
	DragDrop.Target(socket, {
		Priority = 2,
		Accepts = function(p)
			return p.From == "Grid" and isBook(p.Key)
		end,
		Drop = function(p)
			InventoryClient.Send("Socket", p.Index, p.Key)
		end,
		Highlight = function(state)
			self.SocketGlow = state ~= "Off"
			Theme.tween(socketScale, 0.18, { Scale = state == "Over" and 1.14 or state == "Can" and 1.06 or 1 }, Enum.EasingStyle.Back)
			Theme.tween(dStroke, 0.15, { Transparency = state == "Off" and 0.3 or 0, Thickness = state == "Over" and 2.5 or 1.5 })
			Theme.tween(diamond, 0.15, { BackgroundColor3 = state == "Off" and C.Cell or C.CellHover })
		end,
	})

	-- the divider
	local divider = Theme.new("Frame", {
		Position = UDim2.fromOffset(456, 84),
		Size = UDim2.new(0, 1, 1, -116),
		BackgroundColor3 = C.Gold,
		BorderSizePixel = 0,
		Parent = content,
	})
	Theme.new("UIGradient", {
		Rotation = 90,
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.15, 0.55),
			NumberSequenceKeypoint.new(0.85, 0.55),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Parent = divider,
	})

	local right = Theme.new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(480, 84), Size = UDim2.new(0, 488, 1, -116), Parent = content })
	self.Grid = InventoryGrid.new(right, {
		Columns = 6,
		Usable = isBook,
		OnQuick = function(index, key)
			InventoryClient.Send("Socket", index, key)
		end,
		Hint = function()
			return "Drag onto the sword · right-click to set it"
		end,
	})

	Theme.text(content, "Drag an incantation book onto the sword  ·  J casts it with the sword drawn", 12, {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -10),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = C.Faint,
	})

	RunService.RenderStepped:Connect(function(dt)
		if not self.Open then
			return
		end
		self.Clock += dt
		local t = self.Clock
		-- a slow turn and float, around the middle of the sword
		local spin = CFrame.new(self.Center) * CFrame.Angles(0, math.sin(t * 0.6) * 0.45, 0) * CFrame.new(0, math.sin(t * 1.3) * 0.06, 0) * CFrame.new(-self.Center)
		katana:PivotTo(spin * self.Base)
		if self.Book then
			glow.Transparency = 0.72 + 0.1 * math.sin(t * 4)
		end
	end)

	InventoryClient.OnChanged(function(data)
		self:Refresh(data)
	end)
	return self
end

function WeaponPanel:Refresh(data)
	local key = data.Book
	local s = self.Socket
	if key ~= self.Book then
		self.Book = key
		for _, d in ipairs(s.Icon:GetChildren()) do
			d:Destroy()
		end
		s.Empty.Visible = key == nil
		local color = key and (IT[key].Glow or IT[key].Color or C.Book)
		if key then
			ItemArt.Icon(key).Parent = s.Icon
			self.Glow.Color = color
			Theme.tween(self.Edge, 0.4, { Color = color:Lerp(Color3.new(1, 1, 1), 0.45) })
			if self.Open then
				-- the socket takes it: a pop and a ring rushing out
				s.Scale.Scale = 0.8
				Theme.tween(s.Scale, 0.4, { Scale = 1 }, Enum.EasingStyle.Back)
				s.RingStroke.Color = color
				s.RingStroke.Transparency = 0
				s.RingScale.Scale = 1
				Theme.tween(s.RingScale, 0.6, { Scale = 1.9 })
				Theme.tween(s.RingStroke, 0.6, { Transparency = 1 })
			end
		else
			self.Glow.Transparency = 1
			Theme.tween(self.Edge, 0.3, { Color = self.EdgeColor })
		end
	end
	local def = key and IT[key]
	local inc = def and IC[def.Incantation]
	self.Info.Text = inc and string.format("%s  ·  J with the sword drawn  ·  lasts %d s, every %d s", def.Label, inc.Duration, inc.Cooldown)
		or "Drag an incantation book here"
	self.Info.TextColor3 = inc and (def.Gem or def.Color or C.Book):Lerp(C.Text, 0.4) or C.Faint
end

function WeaponPanel:Opened()
	self.Open = true
	self:Refresh(InventoryClient.Data)
	self.Grid:Intro()
	local s = self.Socket
	s.Scale.Scale = 0.4
	Theme.tween(s.Scale, 0.45, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out, 0.15)
	s.Diamond.Rotation = -45
	Theme.tween(s.Diamond, 0.6, { Rotation = 45 }, Enum.EasingStyle.Quint, Enum.EasingDirection.Out, 0.15)
end

function WeaponPanel:Closed()
	self.Open = false
	self.Grid:Hidden()
end

return WeaponPanel
