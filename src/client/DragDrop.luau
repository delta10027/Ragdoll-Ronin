--[[
	DragDrop: dragging items between the menus' cells (inventory grid, equipment slots, the sword's
	book socket).
	  Source(button, getPayload, onClick)   pressing on button and moving starts a drag of
	                               getPayload() (nil: nothing to drag); a press without a move
	                               calls onClick.
	  Target(frame, spec)          spec.Accepts(payload) -> bool, spec.Drop(payload),
	                               spec.Highlight(state): "Off" | "Can" (a drag that fits is
	                               under way) | "Over" (and the cursor is on it); spec.Priority:
	                               the higher wins where targets overlap
	A payload is a table with at least Key (the item) and Icon (a function making the picture that
	follows the cursor). While dragging, the ghost follows the mouse, a little tilted; dropped on
	a target that accepts it, it shrinks into it; anywhere else it flies back and fades.
]]
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Theme = require(script.Parent.UITheme)

local DragDrop = {}

local layer -- ScreenGui above the menus for the ghost
local targets = {}
local pending -- { Payload, Start, Source }
local drag -- { Payload, Ghost, Over, Source }

local function within(obj, pos)
	local p, s = obj.AbsolutePosition, obj.AbsoluteSize
	return pos.X >= p.X and pos.X <= p.X + s.X and pos.Y >= p.Y and pos.Y <= p.Y + s.Y
end

local function inside(obj, pos)
	if not obj.Parent or not obj.Visible or not within(obj, pos) then
		return false
	end
	-- every ancestor up to the ScreenGui must be shown, and the point inside those that clip
	-- (a cell scrolled out of its grid is not under the cursor)
	local a = obj.Parent
	while a and a:IsA("GuiObject") do
		if not a.Visible or (a.ClipsDescendants and not within(a, pos)) then
			return false
		end
		a = a.Parent
	end
	return not (a and a:IsA("ScreenGui") and not a.Enabled)
end

local function targetAt(pos, payload)
	local best
	for _, t in ipairs(targets) do
		if t.Frame.Parent and inside(t.Frame, pos) and t.Spec.Accepts(payload) then
			if not best or (t.Spec.Priority or 0) > (best.Spec.Priority or 0) then
				best = t
			end
		end
	end
	return best
end

local function highlightAll(payload)
	for _, t in ipairs(targets) do
		if t.Spec.Highlight and t.Frame.Parent then
			t.Spec.Highlight(payload and t.Spec.Accepts(payload) and "Can" or "Off")
		end
	end
end

local function begin(p)
	local ghost = Theme.new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(72, 72),
		BackgroundColor3 = Theme.Colors.Cell,
		BackgroundTransparency = 0.15,
		ZIndex = 100,
		Parent = layer,
	})
	Theme.corner(ghost, 8)
	Theme.stroke(ghost, Theme.Colors.Gold, 1.5)
	local icon = p.Payload.Icon()
	icon.ZIndex = 101
	icon.Parent = ghost
	local scale = Theme.scaleOf(ghost)
	scale.Scale = 0.8
	Theme.tween(scale, 0.18, { Scale = 1.05 }, Enum.EasingStyle.Back)
	Theme.tween(ghost, 0.18, { Rotation = -6 })
	drag = { Payload = p.Payload, Ghost = ghost, Source = p.Source, Touch = p.Touch, Home = p.Source.AbsolutePosition + p.Source.AbsoluteSize / 2 }
	if p.Payload.OnStart then
		p.Payload.OnStart()
	end
	highlightAll(p.Payload)
end

local function move(pos)
	if not drag then
		return
	end
	drag.Ghost.Position = UDim2.fromOffset(pos.X, pos.Y)
	local over = targetAt(pos, drag.Payload)
	if over ~= drag.Over then
		if drag.Over and drag.Over.Spec.Highlight then
			drag.Over.Spec.Highlight("Can")
		end
		drag.Over = over
		if over and over.Spec.Highlight then
			over.Spec.Highlight("Over")
		end
	end
end

local function finish(pos)
	local d = drag
	drag = nil
	local over = targetAt(pos, d.Payload)
	highlightAll(nil)
	if d.Payload.OnEnd then
		d.Payload.OnEnd()
	end
	local ghost = d.Ghost
	local scale = Theme.scaleOf(ghost)
	if over then
		local c = over.Frame.AbsolutePosition + over.Frame.AbsoluteSize / 2
		Theme.tween(ghost, 0.14, { Position = UDim2.fromOffset(c.X, c.Y), Rotation = 0, BackgroundTransparency = 1 })
		Theme.tween(scale, 0.14, { Scale = 0.6 })
		over.Spec.Drop(d.Payload)
	else
		Theme.tween(ghost, 0.22, { Position = UDim2.fromOffset(d.Home.X, d.Home.Y), Rotation = 0, BackgroundTransparency = 1 })
		Theme.tween(scale, 0.22, { Scale = 0.85 })
	end
	task.delay(0.24, function()
		ghost:Destroy()
	end)
end

local function press(button, getPayload, onClick, touch)
	if drag then
		return
	end
	-- (GetMouseLocation, not io.Position: the same space as the menus, which ignore the GUI inset)
	pending = { Payload = getPayload(), Start = UserInputService:GetMouseLocation(), Source = button, Click = onClick, Touch = touch }
end

function DragDrop.Source(button, getPayload, onClick)
	-- a button's own press: InputBegan is not reliably passed on by a GuiButton for its button
	button.MouseButton1Down:Connect(function()
		press(button, getPayload, onClick, false)
	end)
	button.InputBegan:Connect(function(io)
		if io.UserInputType == Enum.UserInputType.Touch then
			press(button, getPayload, onClick, true)
		end
	end)
end

function DragDrop.Target(frame, spec)
	table.insert(targets, { Frame = frame, Spec = spec })
end

function DragDrop.Dragging()
	return drag ~= nil
end

-- cancel a drag (the menu closed)
function DragDrop.Cancel()
	pending = nil
	if drag then
		local d = drag
		drag = nil
		highlightAll(nil)
		if d.Payload.OnEnd then
			d.Payload.OnEnd()
		end
		d.Ghost:Destroy()
	end
end

function DragDrop.Init(_ctx, playerGui)
	layer = Theme.new("ScreenGui", {
		Name = "RR_Drag",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = 40,
		Parent = playerGui,
	})
	-- follow the mouse every frame while a button is held (movement and release events can be
	-- swallowed by the GUI under the cursor), and act when it is let go
	local function released(pos)
		if drag then
			finish(pos)
		elseif pending then
			local p = pending
			pending = nil
			if p.Click then
				p.Click()
			end
		end
	end
	RunService.RenderStepped:Connect(function()
		if not pending and not drag then
			return
		end
		local pos = UserInputService:GetMouseLocation()
		local touch = (pending and pending.Touch) or (drag and drag.Touch)
		if not touch and not UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) then
			released(pos)
			return
		end
		if pending and not drag and pending.Payload and (pos - pending.Start).Magnitude > 6 then
			begin(pending)
			pending = nil
		end
		move(pos)
	end)
	UserInputService.InputEnded:Connect(function(io)
		if io.UserInputType == Enum.UserInputType.Touch then
			released(UserInputService:GetMouseLocation())
		end
	end)
end

return DragDrop
