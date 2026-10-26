--[[
	Runtime: what the shared simulation modules need to know about where they run.

	  Mode             Config.Network.Mode ("Owner", "ServerAuthority" or "Server"). It must match
	                   Workspace.AuthorityMode, which game scripts cannot read (RobloxScriptSecurity):
	                   if a read ever succeeds and says Server, ServerAuthority mode is used.
	  ServerAuthority  Mode == "ServerAuthority": the controllers run inside RunService:BindToSimulation
	                   on the server AND on the owning client (prediction with rollback, see SimState).
	  OwnerPhysics     Mode == "Owner": each player's client runs its own fighter's controllers and
	                   owns its physics; the server runs everyone else (see server OwnerSync).
	  now()            the clock for every time stored in simulation state (state timers, recoil,
	                   parry window). Under server authority this is time(): synchronised between
	                   client and server and rewound on rollback. Otherwise os.clock(): each side only
	                   keeps its own times (OwnerSync sends durations, never times).
	  Impulse(part, j) apply an impulse; the server replaces it so impulses on a body a client
	                   simulates are sent to that client.
	  Sound(name, pos, f) play a Config.Sounds effect; no-op unless the server installs SoundFX.
	  Debug            diagnostics hooks; no-ops unless the server installs DebugService.
]]
local Runtime = {}

local Config = require(script.Parent.Parent.Config)

Runtime.Mode = Config.Network.Mode or "Owner"
local ok, isServer = pcall(function()
	return workspace.AuthorityMode == Enum.AuthorityMode.Server
end)
if ok and isServer then
	Runtime.Mode = "ServerAuthority"
end
Runtime.ServerAuthority = Runtime.Mode == "ServerAuthority"
Runtime.OwnerPhysics = Runtime.Mode == "Owner"

function Runtime.now()
	if Runtime.ServerAuthority then
		return time()
	end
	return os.clock()
end

function Runtime.Impulse(part, impulse)
	part:ApplyImpulse(impulse)
end

local function noop() end
Runtime.Sound = noop
Runtime.Debug = { Log = noop, Transition = noop, Attr = noop }

return Runtime
