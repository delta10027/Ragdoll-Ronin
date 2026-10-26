--[[
	InputPacket: the client's input packet (CombatInput, unreliable, ~60 per second) packed into a
	buffer instead of a list of remote arguments, about a third of the bytes:
	  u32 seq, f32 moveX, moveZ, yaw, aimU, aimV, u8 buttons                       (25 bytes)
	  Owner mode adds the client's report of its own simulation:
	  u8 state (index in StateDefs.States), u8 flags (guard, bound, sheathed, incanting),
	  f32 balance, aimU, aimV, aimVU, aimVV, u32 ack                                (51 bytes)
	The server validates every value it reads (NetService), as before.
]]
local StateDefs = require(script.Parent.Parent.StateDefs)

local InputPacket = {}
local BASE, FULL = 25, 51
local STATE_INDEX = {}
for i, s in ipairs(StateDefs.States) do
	STATE_INDEX[s] = i
end

-- r (optional) = { State, Balance, Guard, AimU, AimV, AimVU, AimVV, Bound, Ack, Sheathed, Incanting }
function InputPacket.Encode(seq, mx, mz, yaw, u, v, buttons, r)
	local b = buffer.create(r and FULL or BASE)
	buffer.writeu32(b, 0, seq % 4294967296)
	buffer.writef32(b, 4, mx)
	buffer.writef32(b, 8, mz)
	buffer.writef32(b, 12, yaw)
	buffer.writef32(b, 16, u)
	buffer.writef32(b, 20, v)
	buffer.writeu8(b, 24, buttons)
	if r then
		buffer.writeu8(b, 25, STATE_INDEX[r.State] or 0)
		buffer.writeu8(b, 26, (r.Guard and 1 or 0) + (r.Bound and 2 or 0) + (r.Sheathed and 4 or 0) + (r.Incanting and 8 or 0))
		buffer.writef32(b, 27, r.Balance)
		buffer.writef32(b, 31, r.AimU)
		buffer.writef32(b, 35, r.AimV)
		buffer.writef32(b, 39, r.AimVU)
		buffer.writef32(b, 43, r.AimVV)
		buffer.writeu32(b, 47, math.clamp(r.Ack, 0, 4294967295))
	end
	return b
end

-- Returns seq, mx, mz, yaw, u, v, buttons, report-or-nil; nil when the packet is malformed.
-- The report's State is nil for an unknown state index.
function InputPacket.Decode(b)
	if typeof(b) ~= "buffer" then
		return nil
	end
	local len = buffer.len(b)
	if len ~= BASE and len ~= FULL then
		return nil
	end
	local seq = buffer.readu32(b, 0)
	local mx, mz = buffer.readf32(b, 4), buffer.readf32(b, 8)
	local yaw, u, v = buffer.readf32(b, 12), buffer.readf32(b, 16), buffer.readf32(b, 20)
	local buttons = buffer.readu8(b, 24)
	local r
	if len == FULL then
		local flags = buffer.readu8(b, 26)
		r = {
			State = StateDefs.States[buffer.readu8(b, 25)],
			Guard = flags % 2 == 1,
			Bound = math.floor(flags / 2) % 2 == 1,
			Sheathed = math.floor(flags / 4) % 2 == 1,
			Incanting = math.floor(flags / 8) % 2 == 1,
			Balance = buffer.readf32(b, 27),
			AimU = buffer.readf32(b, 31),
			AimV = buffer.readf32(b, 35),
			AimVU = buffer.readf32(b, 39),
			AimVV = buffer.readf32(b, 43),
			Ack = buffer.readu32(b, 47),
		}
	end
	return seq, mx, mz, yaw, u, v, buttons, r
end

return InputPacket
