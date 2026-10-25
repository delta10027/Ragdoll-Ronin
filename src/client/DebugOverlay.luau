--[[
	DebugOverlay: development-only readout of the server's debug attributes on your fighter.
	Hidden unless workspace attribute RR_Debug is true (set it on the server).
]]
local DebugOverlay = {}
local label
local nextUpdate = 0
local FIELDS = {
	"State", "StateReason", "AttackPhase", "SwordSpeed", "Balance", "Height", "LegSupport",
	"LastContact", "LastTargetSegment", "LastBlock", "LastInjury", "BleedRate", "Blood",
	"SeverResult", "RecoveryPhase", "DeathReason",
}

function DebugOverlay.Init(ctx)
	label = Instance.new("TextLabel")
	label.Name = "DebugOverlay"
	label.BackgroundColor3 = Color3.new(0, 0, 0)
	label.BackgroundTransparency = 0.45
	label.Position = UDim2.fromOffset(10, 60)
	label.Size = UDim2.fromOffset(430, 250)
	label.Font = Enum.Font.Code
	label.TextSize = 12
	label.TextColor3 = Color3.fromRGB(180, 255, 180)
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Top
	label.TextWrapped = true
	label.Visible = false
	label.Parent = ctx.Gui
end

function DebugOverlay.Update(ctx)
	local on = workspace:GetAttribute("RR_Debug") == true
	label.Visible = on
	if not on or os.clock() < nextUpdate then
		return
	end
	nextUpdate = os.clock() + 0.1
	local m = ctx.Fighter
	if not m then
		label.Text = "no fighter"
		return
	end
	local lines = { "RAGDOLL RONIN DEBUG", "Prediction: " .. (ctx.PredictionStatus and ctx.PredictionStatus() or "?") }
	for _, k in ipairs(FIELDS) do
		local v = m:GetAttribute(k)
		if v ~= nil then
			table.insert(lines, k .. ": " .. tostring(v))
		end
	end
	label.Text = table.concat(lines, "\n")
end

return DebugOverlay
