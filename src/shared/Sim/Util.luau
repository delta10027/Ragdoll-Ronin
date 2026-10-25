-- Small math helpers shared by server modules.
local Util = {}

function Util.isFinite(x)
	return typeof(x) == "number" and x == x and x ~= math.huge and x ~= -math.huge
end

function Util.flat(v)
	return Vector3.new(v.X, 0, v.Z)
end

function Util.unit(v, fallback)
	local m = v.Magnitude
	if m < 1e-6 then
		return fallback or Vector3.zero
	end
	return v / m
end

function Util.smoothstep(t)
	t = math.clamp(t, 0, 1)
	return t * t * (3 - 2 * t)
end

-- Wrap an angle difference into [-pi, pi]
function Util.angleDelta(from, to)
	return (to - from + math.pi) % (2 * math.pi) - math.pi
end

function Util.approachAngle(cur, target, maxStep)
	local d = Util.angleDelta(cur, target)
	if math.abs(d) <= maxStep then
		return target
	end
	return cur + math.sign(d) * maxStep
end

-- Yaw (rotation about +Y) of a CFrame's look vector, matching CFrame.Angles(0, yaw, 0)
function Util.yawOf(cf)
	local look = cf.LookVector
	return math.atan2(-look.X, -look.Z)
end

function Util.closestPointOnSegment(p, a, b)
	local ab = b - a
	local len2 = ab:Dot(ab)
	if len2 < 1e-9 then
		return a
	end
	local t = math.clamp((p - a):Dot(ab) / len2, 0, 1)
	return a + ab * t
end

-- Angle between the rotations of two CFrames (radians)
function Util.rotationDelta(a, b)
	local _, angle = (a.Rotation:Inverse() * b.Rotation):ToAxisAngle()
	return math.abs(angle)
end

-- Rotate unit vector `cur` toward unit vector `target` by at most maxAngle radians
function Util.rotateToward(cur, target, maxAngle)
	local d = math.clamp(cur:Dot(target), -1, 1)
	local angle = math.acos(d)
	if angle <= maxAngle or angle < 1e-4 then
		return target
	end
	local axis = cur:Cross(target)
	if axis.Magnitude < 1e-4 then
		-- opposite vectors: pick any perpendicular axis
		axis = cur:Cross(Vector3.yAxis)
		if axis.Magnitude < 1e-4 then
			axis = cur:Cross(Vector3.xAxis)
		end
	end
	return CFrame.fromAxisAngle(axis.Unit, maxAngle):VectorToWorldSpace(cur)
end

-- Spherical interpolation between unit vectors a and b (constant angular rate)
function Util.slerpUnit(a, b, t)
	if t <= 0 then
		return a
	elseif t >= 1 then
		return b
	end
	local angle = math.acos(math.clamp(a:Dot(b), -1, 1))
	if angle < 1e-4 then
		return b
	end
	local axis = a:Cross(b)
	if axis.Magnitude < 1e-6 then
		-- opposite vectors: any perpendicular axis works
		axis = Util.perpendicular(Vector3.yAxis, a, Vector3.xAxis):Cross(a)
	end
	return CFrame.fromAxisAngle(axis.Unit, angle * t):VectorToWorldSpace(a)
end

-- Rotate a toward b about unit axis n by fraction t (both taken perpendicular to n). Opposite
-- vectors always roll the same way (positive about n) so the result is continuous and repeatable.
function Util.rollToward(a, b, n, t)
	local pa = Util.perpendicular(a, n, nil)
	local pb = Util.perpendicular(b, n, nil)
	if not pa or not pb then
		return b
	end
	local angle = math.atan2(pa:Cross(pb):Dot(n), pa:Dot(pb))
	if angle < -math.pi + 1e-3 then
		angle = math.pi
	end
	return CFrame.fromAxisAngle(n, angle * t):VectorToWorldSpace(pa)
end

-- Remove the component of v along unit axis n and normalise; fallback if degenerate
function Util.perpendicular(v, n, fallback)
	local p = v - n * v:Dot(n)
	if p.Magnitude < 1e-4 then
		return fallback
	end
	return p.Unit
end

return Util
