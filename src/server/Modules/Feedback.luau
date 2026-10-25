-- Feedback: server -> client combat notifications for UI (never used as authority).
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local remote = ReplicatedStorage.RagdollRonin.Remotes.CombatFeedback

local Feedback = {}

function Feedback.Send(f, kind, info)
	if f and f.Player and f.Player.Parent then
		remote:FireClient(f.Player, kind, info or {})
	end
end

return Feedback
