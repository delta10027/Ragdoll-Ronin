--[[
	ChatBubbles: shows TextChatService bubble chat over the fighters.
	Roblox's automatic bubbles look for the speaker's Character rig (a Humanoid and
	BubbleChatConfiguration.AdorneeName, "HumanoidRootPart" by default), which the custom fighter
	doesn't have, so they never appear. Instead every received message is shown with
	TextChatService:DisplayBubble over the speaker's fighter Head. AdorneeName is left at its default
	so Roblox's own bubble can't show up as a duplicate if it ever finds the rig.
	A severed head goes to debris, and the speaker's bubbles go with it.
]]
local Players = game:GetService("Players")
local TextChatService = game:GetService("TextChatService")

local ChatBubbles = {}

local OFFSET = 1.2 -- studs above the head, clear of the dummies' name labels

local function speakerHead(message)
	local source = message.TextSource
	local speaker = source and Players:GetPlayerByUserId(source.UserId)
	local model = speaker and speaker.Character
	local head = model and model:FindFirstChild("Head")
	if head and head:IsA("BasePart") then
		return head
	end
	return nil
end

function ChatBubbles.Init(_ctx)
	task.spawn(function()
		local config = TextChatService:FindFirstChildOfClass("BubbleChatConfiguration")
			or TextChatService:WaitForChild("BubbleChatConfiguration", 10)
		if config then
			pcall(function()
				config.Enabled = true
				config.VerticalStudsOffset = OFFSET
			end)
		end
	end)

	TextChatService.MessageReceived:Connect(function(message)
		if message.Text == "" then
			return
		end
		local head = speakerHead(message)
		if head then
			local ok, err = pcall(TextChatService.DisplayBubble, TextChatService, head, message.Text)
			if not ok then
				warn("[ChatBubbles] DisplayBubble failed:", err)
			end
		end
	end)
end

return ChatBubbles
