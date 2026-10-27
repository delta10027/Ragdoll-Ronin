--[[
	ChatBubbles: shows TextChatService bubble chat over the fighters.
	Bubbles adorn to BubbleChatConfiguration.AdorneeName in the speaker's Character, which defaults
	to "HumanoidRootPart". The custom fighter has no Humanoid rig, so bubbles are pointed at its
	Head instead. A severed head goes to debris, and the speaker's bubbles go with it.
]]
local TextChatService = game:GetService("TextChatService")

local ChatBubbles = {}

local ADORNEE = "Head"
local OFFSET = 1.2 -- studs above the head, clear of the dummies' name labels

local function configure(config)
	config.Enabled = true
	config.AdorneeName = ADORNEE
	config.VerticalStudsOffset = OFFSET
end

function ChatBubbles.Init(_ctx)
	task.spawn(function()
		local config = TextChatService:FindFirstChildOfClass("BubbleChatConfiguration")
			or TextChatService:WaitForChild("BubbleChatConfiguration", 10)
		if config then
			pcall(configure, config)
		end
	end)
end

return ChatBubbles
