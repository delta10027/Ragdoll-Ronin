--[[
	Runtime: what the shared simulation modules need to know about where they run.

	  ServerAuthority  true when Workspace.AuthorityMode is Server. That property is not readable by
	                   game scripts (RobloxScriptSecurity), so unless a read succeeds this comes
	                   from Config.Network.ServerAuthority, which must be kept in sync with it. The controllers then run inside
	                   RunService:BindToSimulation on the server AND on the owning client (client
	                   prediction with rollback, see SimState); otherwise only on the server.
	  now()            the clock for every time stored in simulation state (state timers, recoil,
	                   parry window). Under server authority this is time(): synchronised between
	                   client and server and rewound on rollback. os.clock() is neither.
	  Debug            diagnostics hooks; no-ops unless the server installs DebugService.
]]
local Runtime = {}

local Config = require(script.Parent.Parent.Config)

local ok, isServer = pcall(function()
	return workspace.AuthorityMode == Enum.AuthorityMode.Server
end)
if ok then
	Runtime.ServerAuthority = isServer == true
else
	Runtime.ServerAuthority = Config.Network.ServerAuthority == true
end

function Runtime.now()
	if Runtime.ServerAuthority then
		return time()
	end
	return os.clock()
end

local function noop() end
Runtime.Debug = { Log = noop, Transition = noop, Attr = noop }

return Runtime
