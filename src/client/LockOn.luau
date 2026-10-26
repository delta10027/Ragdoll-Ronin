--[[
	LockOn: K locks the camera onto another fighter (Config.Camera, Lock*).
	A spinning diamond floats over the fighter K would lock onto: the living fighter in range
	nearest the middle of the screen (white). Locked (red), the camera swings round to keep them in
	front, so the fighter faces them too (the camera yaw is the requested facing); the mouse still
	tilts the camera up and down. K again, the target dying or getting too far away drops the lock.
	The diamond is a local part: nobody else sees it.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage:WaitForChild("RagdollRonin"):WaitForChild("Config"))

local LockOn = {}
local CC = Config.Camera
local IDLE = Color3.fromRGB(240, 240, 240)
local LOCKED = Color3.fromRGB(255, 60, 50)

local fighters = {} -- every fighter model in the workspace
local function consider(inst)
	if inst:IsA("Model") and inst:GetAttribute("RR_Fighter") == true then
		fighters[inst] = true
	end
end

local function alive(model)
	return model ~= nil and model.Parent ~= nil and fighters[model] == true
		and model:GetAttribute("State") ~= "Dead" and model:FindFirstChild("Head") ~= nil
end

local function candidate(ctx)
	local cam = workspace.CurrentCamera
	local me = ctx.Fighter
	local myPos = me and me:FindFirstChild("LowerTorso") and me.LowerTorso.Position
	if not myPos then
		return nil
	end
	local vp = cam.ViewportSize
	local centre = vp / 2
	local best, bestD = nil, math.min(vp.X, vp.Y) * CC.LockScreenRadius
	for model in pairs(fighters) do
		if model ~= me and alive(model) then
			local head = model.Head.Position
			if (head - myPos).Magnitude <= CC.LockRange then
				local p, onScreen = cam:WorldToViewportPoint(head)
				if onScreen then
					local d = (Vector2.new(p.X, p.Y) - centre).Magnitude
					if d < bestD then
						best, bestD = model, d
					end
				end
			end
		end
	end
	return best
end

function LockOn.Init(ctx)
	ctx.Lock = { Target = nil, Candidate = nil }
	workspace.ChildAdded:Connect(consider)
	workspace.ChildRemoved:Connect(function(inst)
		fighters[inst] = nil
	end)
	for _, c in ipairs(workspace:GetChildren()) do
		consider(c)
	end
	local d = Instance.new("Part")
	d.Name = "RR_LockDiamond"
	d.Size = Vector3.new(0.55, 0.55, 0.08)
	d.Material = Enum.Material.Neon
	d.Anchored = true
	d.CanCollide, d.CanQuery, d.CanTouch, d.CastShadow = false, false, false, false
	d.Transparency = 1
	d.Parent = workspace.CurrentCamera -- (never streamed, never replicated)
	ctx.Lock.Diamond = d
end

-- K
function LockOn.Toggle(ctx)
	local l = ctx.Lock
	if l.Target then
		l.Target = nil
	else
		l.Target = l.Candidate
	end
end

-- Render step, before the camera: keep the lock valid and place the diamond
function LockOn.Update(ctx, dt)
	local l = ctx.Lock
	if not l then
		return
	end
	local me = ctx.Fighter
	local myPelvis = me and me:FindFirstChild("LowerTorso")
	if l.Target then
		local head = alive(l.Target) and l.Target:FindFirstChild("Head")
		if not head or not myPelvis or (head.Position - myPelvis.Position).Magnitude > CC.LockBreakRange then
			l.Target = nil
		end
	end
	l.Candidate = not l.Target and candidate(ctx) or nil
	local shown = l.Target or l.Candidate
	local d = l.Diamond
	if d.Parent ~= workspace.CurrentCamera then
		d.Parent = workspace.CurrentCamera
	end
	if not shown then
		d.Transparency = 1
		return
	end
	local locked = shown == l.Target
	local t = os.clock()
	local bob = math.sin(t * 3) * 0.08
	d.Color = locked and LOCKED or IDLE
	d.Transparency = locked and 0 or 0.35
	d.Size = locked and Vector3.new(0.7, 0.7, 0.1) or Vector3.new(0.55, 0.55, 0.08)
	d.CFrame = CFrame.new(shown.Head.Position + Vector3.new(0, 1.6 + bob, 0))
		* CFrame.Angles(0, t * (locked and 5 or 2.5), 0) * CFrame.Angles(0, 0, math.rad(45))
end

-- the camera yaw and pitch that look from `from` at the locked target, or nil when not locked
function LockOn.Aim(ctx, from)
	local l = ctx.Lock
	local head = l and l.Target and l.Target:FindFirstChild("Head")
	if not head then
		return nil
	end
	local d = head.Position - from
	local flat = Vector3.new(d.X, 0, d.Z)
	if flat.Magnitude < 0.5 then
		return nil
	end
	return math.atan2(-d.X, -d.Z), math.atan2(d.Y, flat.Magnitude) + CC.LockPitchBias
end

return LockOn
