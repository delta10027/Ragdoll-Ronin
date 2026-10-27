--[[
	Ragdoll Ronin - central tuning.
	Every gameplay number lives here (body geometry/organ data lives in Anatomy).
	Shared by server and client. Units: studs, seconds, studs/s unless noted.
]]

local S = 0.8 -- global body scale (Anatomy dimensions are authored unscaled)

local Config = {}
Config.Scale = S

-- Development-only diagnostics. Toggle at runtime with workspace:SetAttribute("RR_Debug", true)
Config.Debug = {
	Enabled = false,
	PrintTransitions = true,
	PrintHits = true,
	ContactMarkerLifetime = 1.5,
	AttributeRate = 10, -- Hz for high-frequency debug attributes (sword speed)
	DevToolsInStudio = true, -- ServerStorage.RR_DevCommand bindable (Studio only)
	TestDummies = true, -- spawn a line of respawning practice dummies when the first player joins (server TestDummies)
	TestDummyLine = { Distance = 22, Spacing = 8, FaceRange = 30 }, -- studs in front of the spawn (-Z), studs between
	-- dummies, and how close a player must be for a dummy to turn and face them
	TestDummyTiming = {
		StartDelay = 2, -- seconds after spawning before a dummy starts its behaviour (it stands up first)
		SwingPeriod = 3, -- one swing every this many seconds
		WindupTime = 0.8, -- holding the wind-up
		CutHoldTime = 0.6, -- holding the end of the cut before letting go
	},
}

Config.Network = {
	-- How fighters are simulated. Must match Workspace.AuthorityMode, which game scripts cannot read
	-- (RobloxScriptSecurity), so it is mirrored here; see Shared.Sim.Runtime.
	--   "Owner"            AuthorityMode = Automatic. Each player's client simulates their own fighter
	--                      (no input delay) and reports its stance; the server simulates the dummies,
	--                      decides every hit, block and reaction and sends those back (server OwnerSync).
	--                      The owner's body is trusted, so this is for testing, not public servers.
	--   "ServerAuthority"  AuthorityMode = Server. The server simulates everyone; the owning client
	--                      predicts its fighter with rollback (Shared.Sim.SimState).
	--   "Server"           AuthorityMode = Automatic. The server simulates everyone; clients only send
	--                      input (a network round trip of input delay).
	Mode = "Owner",
	ClientSendRate = 60, -- input packets per second (plus one immediately on every button press/release)
	BucketCapacity = 30,
	BucketRefillPerSecond = 100, -- hard cap on accepted input packets
	InputTimeout = 0.6, -- stale input -> neutral (buttons released, no movement)
	ActionCooldown = 0.25,
	AnatomySyncInterval = 0.2,
}

Config.Physics = {
	LimbDensity = 0.8,
	TorsoDensity = 1.0,
	SwordDensity = 0.35,
	Friction = 0.6,
	FootFriction = 0.4,
	JointFriction = 3, -- BallSocket MaxFrictionTorque: damps limp limbs so ragdolls settle
}

Config.Movement = {
	WalkSpeed = 13,
	Acceleration = 120, -- horizontal control authority when upright (studs/s^2)
	StaggerAcceleration = 18, -- lower authority so hits visibly push the body
	AttackSpeedMult = 0.6,
	BlockSpeedMult = 0.5,
	StaggerSpeedMult = 0.3,
	OffBalanceSpeedMult = 0.45,
	KneelSpeedMult = 0.22,
	TurnRate = math.rad(540),
	PersonalSpace = 4.0 * S, -- fighters cannot walk closer than this (pelvis to pelvis, see Sim.Spacing):
	-- close enough that the middle of the blade reaches the other torso with the arms extended
	PersonalSpacePush = 6, -- 1/s: how firmly fighters inside that distance are eased apart
	AttackTurnRate = math.rad(260),
	StandHeight = 3.62 * S, -- pelvis centre above ground
	KneelHeightFactor = 0.66,
	KneelLegSupport = 0.75, -- below this leg support the fighter fights from a kneel
	HeightChangeRate = 2.0, -- studs/s the stance height target may change
	SupportStiffness = 140, -- 1/s^2 spring that holds the pelvis at stand height
	SupportDamping = 22, -- 1/s
	MaxSupportAccel = 2.6, -- * gravity
	GroundProbeExtra = 1.6,
	GroundedTolerance = 0.9,
	-- walk cycle (MotorController.standLegs). Each leg has a stance phase, foot planted and sliding
	-- back under the hip exactly as fast as the body moves, and a swing phase lifting it forward;
	-- the leg angles are solved (thigh + shin IK) to reach that foot point, so the feet never skate.
	-- Stride (one full cycle, two steps) grows slower than speed (speed ^ StrideExponent), as in
	-- human gait, so both step length and cadence rise: a slow walk takes short, slow steps (about
	-- 1.8 steps/s), full speed is a run (about 3.2 steps/s).
	StrideMax = 10 * S, -- at WalkSpeed
	StrideExponent = 0.7,
	DutyWalk = 0.62, -- part of the cycle each foot is on the ground, slow (double support)...
	DutyRun = 0.44, -- ...at most, at full speed; less where the leg cannot reach (a run's flight phase)
	GaitKneeDip = math.rad(24), -- extra knee bend at mid stance at full stride (the body rides lower)
	GaitReach = 1.04, -- how far a planted leg reaches (x leg length; the foot rolls heel to toe)
	SwingLift = 0.35 * S, -- foot clearance in mid swing, slow...
	SwingLiftRun = 0.8 * S, -- ...and at full speed (the heel comes up behind)
	GaitBlendRate = 6, -- 1/s: how fast the stride follows a change of speed (starting, stopping)
	GaitBob = 0.07 * S, -- walking: pelvis rises over the standing leg, dips as the weight changes feet
	GaitPelvisYaw = math.rad(7), -- the pelvis turns with the stepping leg...
	GaitShoulderYaw = math.rad(6), -- ...and the shoulders the other way (arms free only)
	GaitLean = math.rad(6), -- extra forward lean at full speed
	ArmSwing = math.rad(32), -- free arms swing opposite to the legs (shoulder pitch at full stride)
	WalkArmElbow = math.rad(5), -- walking: the arms hang almost straight and swing from the shoulder
	-- SHIFT (held, sword sheathed, moving forward): sprint. The arms bend and pump; the walk
	-- blends into it with the stride (MotorController.standLegs / hangArms)
	SprintSpeedMult = 1.7,
	SprintMinAhead = 0.5, -- move direction . facing needed to sprint (no sprinting backwards)
	SprintArmSwing = math.rad(55), -- shoulder pitch at full sprint stride
	SprintElbow = math.rad(88), -- elbow bend while sprinting...
	SprintElbowPump = math.rad(16), -- ...more as the arm drives forward, less as it swings back
	SprintArmOut = math.rad(4), -- arms carried a little closer to the body
	SprintLean = math.rad(9), -- extra forward lean at full sprint
	-- sprint legs: past walking speed the stride grows only as speed ^ SprintStrideExponent, so the
	-- extra speed comes mostly from faster steps (about 4.5 steps/s at full sprint instead of 3.3)
	SprintStrideExponent = 0.3,
	DutySprint = 0.34, -- each foot is down for less of the cycle: a longer flight phase
	SprintLiftExtra = 1.1 * S, -- extra foot height in the swing loop (the heel kicks up toward the seat)
	-- sprint swing loop (MotorController.standLegs): after toe-off the foot keeps travelling BACK
	-- and up (heel kick), then the knee drives it through high and forward, it reaches out in front
	-- of the landing point and paws back down onto it - one full loop per stride
	SprintKickBack = 1.0 * S, -- how much further behind the toe-off point the heel kicks
	SprintLiftPeak = 0.38, -- part of the swing at which the foot is highest (early: up behind)
	SprintReachForward = 0.45 * S, -- how far past the landing point the foot reaches before pawing back
	SprintToePoint = math.rad(35), -- toes point down/back through the heel kick
	SprintKneeDip = math.rad(10), -- extra knee bend at mid stance (the body rides lower, legs drive harder)
	StanceKneeBend = math.rad(16), -- least knee bend; more when the pelvis is lower (crouch, pushed down)
	CrouchHeightFactor = 0.78, -- CTRL: stance height while crouching
	CrouchSpeedMult = 0.5,
	-- leg geometry for the standing knee bend (studs, scaled): hip pivot below the pelvis centre,
	-- thigh and shin lengths, ankle pivot to sole
	HipDrop = 0.45 * S,
	ThighLength = 1.45 * S,
	ShinLength = 1.45 * S,
	AnkleToSole = 0.3 * S,
}

Config.Drives = {
	PelvisTorquePerMass = 1400, -- upright torque = this * body mass * state tone
	PelvisResponsiveness = 45,
	Joint = {
		Waist = { Torque = 4000, Responsiveness = 45 },
		Neck = { Torque = 1200, Responsiveness = 40 },
		Head = { Torque = 700, Responsiveness = 40 },
		Shoulder = { Torque = 1000, Responsiveness = 40 },
		Wrist = { Torque = 400, Responsiveness = 40 }, -- the sword wrist is posed by the arm solve too (MotorController)
		Hip = { Torque = 2200, Responsiveness = 45 },
		Ankle = { Torque = 500, Responsiveness = 35 },
		Elbow = { Torque = 900, Speed = 14 },
		Knee = { Torque = 2200, Speed = 14 },
	},
	-- arm solve (MotorController): the elbow swivel / sword roll search and how fast the arm may move
	-- toward a new answer, so branch changes swing the elbow round instead of snapping it
	Arm = {
		SwivelRate = 10, -- rad/s
		RollRate = 8, -- rad/s
		RollCost = 0.05, -- per radian the sword is rolled away from the edge SwordController asked for
		SwivelCost = 0.02, -- per radian of elbow swivel away from the natural down-and-out elbow
		Hysteresis = 0.01, -- per radian of change from the current swivel / roll
	},
	HandForce = 3500,
	BlockHandMult = 1.6, -- sword hand drive strength while blocking, so a held guard stops a swing
	HandResponsiveness = 60,
	HandMaxVelocity = 46, -- physical cap on hand speed (server-side swing speed limit)
	HandTorque = 1800,
	HandAngResponsiveness = 60,
	HandMaxAngularVelocity = 40,
	-- the sword target turns toward the requested pose at most this fast (rad/s): blade direction,
	-- then roll about the blade. Below what the hand can follow, so the hand drive never ends up
	-- half a turn behind and swinging the wrong way round.
	HandTurnRate = 20,
	HandRollRate = 40,
	OffHandForce = 900,
	OffHandResponsiveness = 45,
	-- Drive targets are only rewritten when they change by more than this (limits replication churn)
	TargetAngleEpsilon = math.rad(0.6),
	TargetPosEpsilon = 0.01,
	-- Engine convention for HingeConstraint.TargetAngle (verified in Studio play tests)
	HingeSign = 1,
}

Config.Sword = {
	BladeLength = 3.3 * S,
	BladeWidth = 0.2 * S, -- edge-to-spine
	BladeThickness = 0.06 * S,
	HandleLength = 1.05 * S,
	HandleWidth = 0.2 * S,
	GuardDiameter = 0.55 * S,
	GuardThickness = 0.08 * S,
	ParryZoneWidth = 0.95 * S, -- guard interception tolerance volume around the blade
	ColliderPadding = 0.1 * S, -- the solid blade collider is this much fatter than the visual blade on each side
	ColliderFriction = 0.25, -- low, so a blocked blade can slide off along the guard
	SampleCount = 7, -- swept sample points along the blade
	WeaponFactor = 1.0,
}

-- Mapping from the 2D combat cursor (unit disk, u right / v up) to sword poses
Config.Aim = {
	ReadyU = 0.05,
	ReadyV = 0.3,
	Gain = 32, -- how quickly the controller cursor chases the player's cursor (1/s)
	MaxSpeed = 9, -- server cap on cursor speed (disk radii per second)
	Accel = 70, -- inertia of the controller cursor (1/s)
	EdgeTurnRate = math.rad(1600),
	EdgeMinSpeed = 0.5,
	LagSlowStart = math.rad(45), -- sword target this far behind the cursor's pose: the cursor slows...
	LagStop = math.rad(90), -- ...and stops here until the target catches up (see SwordController.UpdateAim)
	-- a blocked, parried or clashing attack is BOUND to the blade it met: the cursor stops there and
	-- can only be drawn back (SwordController.Bind), so a blocked cut must be pulled out and retried
	BindRebound = 0.12, -- disk radii the cursor is knocked back from where the blades met
	BindRelease = 0.3, -- drawing the cursor back this far frees the sword (as does releasing M1)
	BindSlack = 0.1, -- sideways play of a bound cursor (widens as it is drawn back)
	BindMinSpeed = 0.3, -- slower than this at contact: the push is taken to be toward the disk centre
	GuardBlendRate = 20,
	ReadyBlendRate = 10,
	ClientSensitivity = 0.0042, -- disk radii per mouse pixel while M1/M2 held
	CameraSensitivity = 0.0035, -- radians per mouse pixel otherwise
	-- Key poses: grip position (unscaled, upper-torso space: +X right, +Y up, -Z forward) and blade
	-- direction. Idle: two-handed, hands low in front of the hips, blade angled up and forward.
	ReadyGrip = Vector3.new(0.08, -0.75, -1.45),
	ReadyBlade = Vector3.new(-0.08, 0.62, -0.78),
	-- Attack (M1): every point out at the rim of the disk is a drawn-back or finished sword
	-- position (AttackKeys, one per 45 degrees clockwise from straight up); the centre of the disk
	-- is AttackCenter, blade straight ahead with the arms extended (a thrust). Between them the
	-- blade turns from the rim key toward straight ahead, so dragging the cursor from one side of
	-- the disk through the middle to the other is one cut, in the plane real katana cuts use:
	--   top -> bottom            vertical cut from overhead
	--   top right -> bottom left kesa-giri: from hasso (hands by the right shoulder, blade up and
	--                            back) down across the body, finishing at the left hip with the
	--                            blade out to the side
	--   right -> left            horizontal cut: drawn back over the right shoulder with the torso
	--                            and hips wound up, sweeping round to wrap over the left shoulder
	-- (and every cut the other way). Each key also has a body twist (radians of waist yaw, + =
	-- turned left; the hips turn HipTwist of it on top) and a windup weight: while held at a windup
	-- key the edge already faces the coming cut back through the centre.
	AttackRimFull = 0.9, -- cursor radius at which the rim key is reached
	AttackPosLead = 1.3, -- > 1: hands reach the rim position before the blade finishes turning, so
	-- drawing the cursor in from a windup first swings the blade over, then brings the hands through
	RimPrepStart = 0.6, -- cursor radius where the windup edge pre-aim starts
	HipTwist = 0.4, -- the hips turn this fraction of the body twist, on top of the waist
	AttackCenter = { Grip = Vector3.new(0, 0.15, -1.55), Blade = Vector3.new(0, 0.12, -1) },
	AttackKeys = {
		{ Grip = Vector3.new(0.1, 2.3, -0.75), Blade = Vector3.new(0.05, 0.4, 0.92), Windup = 1, Twist = 0 }, -- overhead
		{ Grip = Vector3.new(0.8, 0.6, -1.1), Blade = Vector3.new(0.35, 0.65, 0.68), Windup = 1, Twist = -0.4 }, -- hasso: hands in front of the right shoulder, elbows down, blade tilted back
		{ Grip = Vector3.new(0.55, 0.45, -1.1), Blade = Vector3.new(0.85, 0.15, 0.5), Windup = 1, Twist = -0.65 }, -- wound up to the right (hands in front of the chest, elbow low)
		{ Grip = Vector3.new(0.25, -0.5, -1.4), Blade = Vector3.new(0.7, -0.25, -0.65), Windup = 0, Twist = -0.45 }, -- finish at the right hip
		{ Grip = Vector3.new(0.1, -0.7, -1.3), Blade = Vector3.new(0, -0.6, -0.8), Windup = 0, Twist = 0 }, -- finish low in front
		{ Grip = Vector3.new(-0.1, -0.5, -1.45), Blade = Vector3.new(-0.7, -0.25, -0.65), Windup = 0, Twist = 0.5 }, -- finish at the left hip
		{ Grip = Vector3.new(-0.5, 0.6, -0.9), Blade = Vector3.new(-0.85, 0.15, 0.5), Windup = 1, Twist = 0.6 }, -- wound up to the left
		{ Grip = Vector3.new(-0.4, 0.8, -0.8), Blade = Vector3.new(-0.3, 0.7, 0.65), Windup = 1, Twist = 0.35 }, -- hasso, left shoulder
	},
	-- Guard (M2): one key per 45 degrees clockwise from straight up, each held OUT beyond the body
	-- on its side so a real swing meets the blade before it reaches the body. Near the disk centre
	-- the guard blends into GuardCenter (flat across in front of the chin).
	-- Up: flat across above the forehead, hands as far left as the right arm reaches and the torso
	-- turned a little left, so the blade (not the hands) covers the head against a vertical cut.
	-- Sides: blade upright beside the body, tip up, against horizontal and diagonal cuts; the upper
	-- diagonals raise it with the tip leaning in over the head. The left hand holds the pommel end,
	-- so it is always the lower / further-left hand. Edge: the roll of the blade, fixed per key and
	-- chosen for the least arm strain, so moving the guard never spins the sword in the hands.
	-- Twist: body twist as for attack keys (the torso turns toward the threatened side).
	GuardRimStart = 0.3,
	GuardRimFull = 0.85,
	GuardCenter = { Grip = Vector3.new(-0.15, 1.15, -1.15), Blade = Vector3.new(0.98, 0.1, -0.15), Edge = Vector3.new(-0.13, 0.98, -0.18), Twist = 0 },
	GuardKeys = {
		{ Grip = Vector3.new(-0.35, 2.1, -0.85), Blade = Vector3.new(0.95, 0.12, 0.2), Edge = Vector3.new(-0.12, 0.99, 0), Twist = 0.3 }, -- up
		{ Grip = Vector3.new(0.5, 1.1, -1.2), Blade = Vector3.new(-0.45, 0.88, -0.15), Edge = Vector3.new(0.6, 0.3, -0.75), Twist = -0.2 }, -- up-right
		{ Grip = Vector3.new(0.7, 0.35, -1.15), Blade = Vector3.new(0.12, 0.99, -0.05), Edge = Vector3.new(0.5, -0.1, -0.85), Twist = -0.3 }, -- right
		{ Grip = Vector3.new(0.75, -0.45, -1.25), Blade = Vector3.new(0.45, -0.85, -0.25), Edge = Vector3.new(-0.89, -0.43, -0.15), Twist = -0.2 }, -- down-right
		{ Grip = Vector3.new(0.15, -0.7, -1.4), Blade = Vector3.new(-0.1, -0.97, -0.22), Edge = Vector3.new(-0.96, 0.15, -0.22), Twist = 0 }, -- down
		{ Grip = Vector3.new(-0.2, -0.5, -1.25), Blade = Vector3.new(-0.5, -0.82, -0.25), Edge = Vector3.new(-0.86, 0.46, 0.21), Twist = 0.2 }, -- down-left
		{ Grip = Vector3.new(-0.75, 0.4, -1.3), Blade = Vector3.new(-0.12, 0.99, -0.05), Edge = Vector3.new(-0.6, 0, -0.8), Twist = 0.3 }, -- left
		{ Grip = Vector3.new(-0.75, 1.0, -1.2), Blade = Vector3.new(0.5, 0.85, -0.15), Edge = Vector3.new(-0.6, 0.3, -0.75), Twist = 0.25 }, -- up-left
	},
}

Config.Combat = {
	RefSpeed = 26, -- blade speed (relative) that produces PowerScale with full commitment
	PowerScale = 10,
	MaxPower = 20,
	StrokeStartSpeed = 15, -- tip speed relative to pelvis that opens a damaging stroke
	StrokeEndSpeed = 8,
	StrokeEndHold = 0.09,
	ReversalDot = -0.25, -- sharp reversal starts a new stroke
	CommitmentDistance = 3.5, -- momentum arc (below) for a fully committed stroke
	MinCommitment = 0.35,
	MomentumWindow = 0.3, -- seconds of tip motion the momentum arc is measured over
	MinMomentumArc = 1.6, -- studs: a body hit whose tip covered less than this in the window does no damage
	-- (a fast spin of the sword round a small circle never covers more than the circle's width)
	FollowThroughTime = 0.18,
	SubstepDistance = 0.5, -- max tip travel per sweep substep
	MaxSubsteps = 6,
	MaxPlausibleTipSpeed = 120, -- anything faster is treated as a glitch/exploit and ignored
	ReachMargin = 1.5,
	GuardTimeTolerance = 0.2, -- fraction of a frame by which a guard contact may trail a body contact and still intercept
	MinDamagingPower = 0.6, -- below this a contact is just a touch
	StaggerPower = 3.2,
	KnockdownPower = 8.5,
	ArmInterruptPower = 1.0,
	HitDVPerPower = 2.2, -- velocity change applied to the struck segment
	MaxHitDV = 26,
	MaxBodyHitDV = 12, -- the same, for hits that cannot knock over (not head or legs): no shove tips the body
	KnockdownDV = 16,
	DeflectDV = 28,
	ParryDeflectDV = 42,
	RecoilTime = 0.35,
	RecoilHandScale = 0.3,
	StaggerTime = 0.45,
	HeavyStaggerTime = 0.75,
	ParryStaggerTime = 0.8,
	SegmentCooldown = 0.25, -- same blade cannot re-strike the same segment within this window
	ThrustAxialDot = 0.72,
	CutEdgeDot = 0.35,
	BluntQuality = 0.45,
}

-- Teep (C): a Muay Thai push kick with the lead (left) leg. The knee comes up to the chest with the
-- foot tucked under it, the hips drive forward and the leg extends straight into the opponent's
-- belly, sole first and toes pulled back, with the torso leaning back to counterbalance and the
-- hands kept up in guard; then the knee snaps back to the chamber and the foot steps down.
-- It pushes rather than hurts: a clean teep shoves the target back and staggers it. Only a flat
-- guard held close to the centre of the circle (the cross block in front of the chin) stops it.
Config.Kick = {
	Leg = "Left",
	ChamberTime = 0.16, -- knee up
	ExtendTime = 0.12, -- leg out
	HoldTime = 0.1, -- fully extended
	RetractTime = 0.24, -- back to the chamber, then the foot down
	Cooldown = 0.35, -- after the kick before the next one
	-- poses (degrees): hip flexion, knee bend, ankle (toes up +) relative to the pelvis
	Chamber = { Hip = 108, Knee = 115, Ankle = 25 },
	Extend = { Hip = 86, Knee = 6, Ankle = 6 }, -- with the lean: thigh ~12 deg above level, sole square to the target
	Lean = 16, -- pelvis/torso lean back while extended (degrees)
	SupportKnee = 10, -- standing leg knee bend
	LungeSpeed = 7, -- studs/s forward drive of the hips while extending
	MoveMult = 0.25, -- walking speed while kicking
	HandsGrip = Vector3.new(0.05, 0.35, -1.15), -- sword held up in guard (upper-torso space, unscaled)
	HandsBlade = Vector3.new(-0.1, 0.85, -0.5),
	-- contact (server KickResolver)
	ActiveReach = 1.5 * S, -- foot this far in front of the pelvis: the kick can land
	FootRadius = 0.6 * S,
	KnockbackDV = 15, -- studs/s given to the whole body of a target the kick lands on
	KnockbackUp = 2,
	HitStaggerTime = 0.6,
	HitBalanceCost = 30,
	BlockMaxRadius = 0.45, -- guard cursor radius: only a flat block this close to the centre stops a teep
	BlockedPushDV = 5, -- a blocked teep still nudges the defender
	BlockedBalanceCost = 8,
	BlockedStaggerTime = 0.3, -- the kicker, bounced off the guard
}

-- Sheathing (1): players spawn with the katana in its saya, worn edge up through the obi on the
-- left hip with the hilt angled forward across the belly, so the right hand can reach it
Config.Sheath = {
	StartSheathed = true, -- players' fighters (dummies always spawn with the sword drawn)
	Mouth = Vector3.new(-0.5, 0.1, -0.55), -- scabbard mouth, pelvis space (unscaled; +X right, -Z forward)
	BladeDir = Vector3.new(-0.3, -0.35, 0.89), -- the scabbard runs back, down and out from the mouth
	Color = Color3.fromRGB(28, 22, 24),
}

-- Drawing and sheathing are animated like an iaido draw (SwordController, Shared.Sim.Draw):
--   draw     reach: the right hand crosses to the hilt, the left hand takes the scabbard mouth
--              (thumb on the tsuba) and the torso turns left;
--            pull:  the right hand draws the blade forward along the scabbard, edge up, while the
--              left hand pulls the scabbard back (saya-biki) until the tip clears the mouth;
--            swing: the blade swings forward into the guard in front of the body, the left hand
--              leaves the scabbard for the hilt (two hands) and the scabbard settles back.
--   sheathe  the reverse (noto): the blade turns edge up and brings its tip back to the mouth with
--            the scabbard pulled back, slides home, the hands let go.
Config.Draw = {
	ReachTime = 0.28,
	PullTime = 0.38,
	SwingTime = 0.32,
	AlignTime = 0.4, -- sheathe: tip to the mouth
	InsertTime = 0.45, -- sheathe: slide home
	ReleaseTime = 0.2, -- sheathe: hands back to the sides
	Twist = 0.6, -- torso turn (radians, + = left) that brings the right shoulder to the hilt
	SayaBiki = 0.9, -- studs the left hand pulls the scabbard back along itself
	ClearMargin = 0.05, -- studs past the mouth the tip travels before the blade turns
}

-- Bow (G): a standing rei. The body bends forward from the hips with the back straight, the gaze
-- following it down, holds, and straightens up again. Any other action (moving, M1, M2, C, 1) ends
-- it at once. With the sword drawn the blade is lowered in front, tip down and forward.
Config.Bow = {
	DownTime = 1.0,
	HoldTime = 1.6,
	UpTime = 1.0,
	Angle = 75, -- forward bend of the upper body (degrees)
	HipShare = 0.6, -- part of it taken at the hips (the pelvis tips), the rest at the waist (cone 40)
	HeadDown = 20, -- extra nod of the head (degrees)
	Grip = Vector3.new(0.35, -1.2, -1.0), -- drawn sword lowered (upper-torso space, unscaled)
	Blade = Vector3.new(0.1, 0.35, -0.93), -- (the torso is bent far forward: this points down and ahead)
}

-- Armour and clothing: the pieces a fighter wears, each in one equipment slot of the inventory
-- (TAB > Character, Config.Inventory). Armour pieces cover body segments: a damaging hit on a
-- covered segment is stopped (the blade bounces off: only PowerThrough of it reaches the body, as
-- a blunt blow) and costs the piece one of its Hits; at 0 the piece breaks off and the body under
-- it is exposed. Neck, torso, arms and hands are never covered: the gaps to aim for.
-- Equipping armour only works out of combat (not hit for EquipCooldown seconds) and restores it.
-- Cosmetic pieces cover no segments: they never stop a blow, never break, and go on any time.
-- View: how the client draws it (ArmorView: "Shell" plates over the segments, "Helmet" a kabuto
-- over the crown; CloakView: "Cloak", "Cape", "Scarf"; GearView: "Kasa", "Satchel", "Pack",
-- "Waraji"). The keys are the item keys of Config.Items.
Config.Armor = {
	PowerThrough = 0.2,
	EquipCooldown = 8,
	Order = { "Kabuto", "Kasa", "Cloak", "Cape", "Scarf", "Satchel", "TravelPack", "Suneate", "Kogake", "Waraji" },
	Pieces = {
		Kabuto = { Label = "Kabuto", Hits = 3, Segments = { "Head" }, Color = Color3.fromRGB(30, 28, 30), View = "Helmet" },
		Kasa = { Label = "Kasa", Cosmetic = true, Hits = 1, Segments = {}, Color = Color3.fromRGB(196, 164, 104), View = "Kasa" },
		Cloak = { Label = "Cloak", Cosmetic = true, Hits = 1, Segments = {}, Color = Color3.fromRGB(78, 20, 26), View = "Cloak" },
		Cape = { Label = "Travelling Cape", Cosmetic = true, Hits = 1, Segments = {}, Color = Color3.fromRGB(36, 40, 52), View = "Cape" },
		Scarf = { Label = "Scarf", Cosmetic = true, Hits = 1, Segments = {}, Color = Color3.fromRGB(176, 44, 40), View = "Scarf" },
		Satchel = { Label = "Satchel", Cosmetic = true, Hits = 1, Segments = {}, Color = Color3.fromRGB(112, 76, 48), View = "Satchel" },
		TravelPack = { Label = "Travel Pack", Cosmetic = true, Hits = 1, Segments = {}, Color = Color3.fromRGB(88, 70, 50), View = "Pack" },
		Suneate = { Label = "Suneate", Hits = 4, Segments = { "LeftThigh", "LeftShin", "RightThigh", "RightShin" }, Color = Color3.fromRGB(38, 36, 40), View = "Shell" },
		Kogake = { Label = "Kogake", Hits = 3, Segments = { "LeftFoot", "RightFoot" }, Color = Color3.fromRGB(44, 40, 44), View = "Shell" },
		Waraji = { Label = "Waraji", Cosmetic = true, Hits = 1, Segments = {}, Color = Color3.fromRGB(200, 170, 110), View = "Waraji" },
	},
	Inflate = 0.07 * S, -- shell thickness over each body part
}

-- The inventory (TAB > Character): a grid of the items a player carries and five equipment slots.
-- Kept by the server (Loadout) for the session and mirrored to the owner as the StringValue
-- "RR_Inventory" (JSON) under the Player. A bag in the Back slot adds its Capacity to the grid. The incantation
-- book set on the sword (TAB > Weapon) is the one J casts.
Config.Inventory = {
	Capacity = 16, -- grid cells without a bag
	Slots = { "Head", "Neck", "Back", "Legs", "Boots" },
	SlotHints = { Head = "Helmets, hats", Neck = "Scarves, cloaks, capes", Back = "Bags", Legs = "Leg armour", Boots = "Boots" },
	Starter = { "Kabuto", "Cloak", "Suneate", "BookFire" }, -- what a player joins with
	Creative = true, -- the creative menu (M) may give items (false: nobody can)
}

-- Every item there is (the creative menu, M, lists them in Order). Kind "Wear" goes in Slot
-- (its look and armour are Config.Armor.Pieces[key]); "Book" carries an incantation
-- (Config.Incantations) and is set on the sword. Capacity: extra grid cells a bag gives.
Config.Items = {
	Order = { "Kabuto", "Kasa", "Cloak", "Cape", "Scarf", "Satchel", "TravelPack", "Suneate", "Kogake", "Waraji", "BookFire" },
	Kabuto = { Kind = "Wear", Slot = "Head", Description = "A lacquered war helmet. Turns aside blows to the head." },
	Kasa = { Kind = "Wear", Slot = "Head", Description = "A wide straw hat against sun and rain." },
	Cloak = { Kind = "Wear", Slot = "Neck", Description = "A heavy cloak with a mantle over the shoulders. Flows in the wind." },
	Cape = { Kind = "Wear", Slot = "Neck", Description = "A long, light cape for the road." },
	Scarf = { Kind = "Wear", Slot = "Neck", Description = "A scarf wound about the neck, its ends trailing behind." },
	Satchel = { Kind = "Wear", Slot = "Back", Capacity = 6, Description = "A small leather bag on a strap." },
	TravelPack = { Kind = "Wear", Slot = "Back", Capacity = 12, Description = "A framed pack with a rolled blanket on top." },
	Suneate = { Kind = "Wear", Slot = "Legs", Description = "Plated guards over the thighs and shins." },
	Kogake = { Kind = "Wear", Slot = "Boots", Description = "Armoured foot covers." },
	Waraji = { Kind = "Wear", Slot = "Boots", Description = "Woven straw sandals, tied at the ankle." },
	BookFire = { Kind = "Book", Label = "Book of Fire", Incantation = "Fire", Color = Color3.fromRGB(176, 52, 28), Description = "Set on the sword, its incantation makes the blade burn." },
}
for _, key in ipairs(Config.Items.Order) do
	local item = Config.Items[key]
	if item.Kind == "Wear" then
		item.Label = Config.Armor.Pieces[key].Label
	end
end

-- Wind (Shared.Sim.Wind): one wind for the whole server, blowing toward a compass yaw at Speed
-- studs/s. Kept on the workspace (attributes "WindSpeed", "WindYaw") so every client sees it;
-- anyone can change it from the creative menu (M, Weather). It drives the faint wave streaks drawn around
-- the camera (client WindView), the Cloak's cape, and, once strong, the fighters themselves:
-- walking into it is slower, and from HighSpeed a fighter with the sword sheathed walking into it
-- raises the left forearm across the face and leans in (instead of swinging that arm).
Config.Wind = {
	-- >>> WIND SOUND: put your audio asset id here (e.g. 1234567890 or "rbxassetid://1234567890").
	-- A looped ambience; louder and slightly higher pitched the stronger the wind. "" = no sound.
	SoundId = "93035214379043",
	SoundVolume = { 0.05, 0.9 }, -- at CalmSpeed .. at MaxSpeed (silent below CalmSpeed)
	SoundPitch = { 0.9, 1.15 }, -- at CalmSpeed .. at MaxSpeed
	Speed = 8, -- at server start
	Yaw = 45, -- degrees: 0 blows toward -Z (the spawn's forward), 90 toward -X
	MaxSpeed = 60,
	SpeedStep = 5, -- menu - / +
	YawStep = 45, -- menu turn left / right
	HighSpeed = 25, -- above this the fighters feel it (and cover their faces)...
	FullSpeed = 50, -- ...fully from here
	IntoSlow = 0.45, -- walking straight into full wind loses this fraction of the walk speed
	-- covering the face: the left elbow comes forward in front of the chest and the forearm runs up
	-- across the face to the hand by the right temple, while the head tucks down and turns right
	-- into the arm (upper-torso space, unscaled: +X the fighter's right, +Y up, -Z forward; the
	-- face is about Y 1.3 to 2.3, Z -0.5). Chosen by measuring how much of the face the arm hides
	-- from the front, a raised camera and either side, keeping the arm out of the head.
	CoverElbowDir = Vector3.new(0.57, 0.29, -0.77), -- from the left shoulder: forward, in, a little up
	CoverHand = Vector3.new(0.7, 1.8, -1.1), -- reached for along the forearm (as far as it goes)
	CoverLean = 10, -- degrees of extra forward lean while covering the face
	CoverHeadDown = 40, -- degrees the head tucks down (about 35 net of the lean it rides on)
	CoverHeadTurn = 25, -- degrees the head turns right, into the arm
	-- streaks (client WindView): each a short wavy trail flying downwind near the camera
	Wisps = 36, -- at FullSpeed (fewer in lighter wind, none below CalmSpeed)
	CalmSpeed = 2,
	WispRadius = 55, -- studs around the camera they appear in
	WispLife = { 2.0, 3.5 }, -- seconds, random in range
	WispWave = 0.6, -- studs of up-and-down wave...
	WispWavelength = 10, -- ...one wave every this many studs downwind
	WispTransparency = 0.82, -- the trail's most opaque point (1 = invisible)
	WispTrailLength = 9, -- studs of trail behind each wisp's head
}

-- Rain (client WeatherView): one rain for the whole server, Intensity 0 (off) .. 1 (downpour), kept
-- on the workspace (attribute "RainIntensity") and changed from the creative menu (M, Weather) like the
-- wind. Each client draws it around its own camera: streaks that slant with the wind, splashes on
-- the ground nearby, a slightly darker, greyer grade, and the rain sound below.
Config.Rain = {
	-- >>> RAIN SOUND: put your audio asset id here (e.g. 1234567890 or "rbxassetid://1234567890").
	-- A looped ambience; its volume follows the intensity. "" = no sound.
	SoundId = "1516791621",
	SoundVolume = 0.8, -- at full intensity
	Intensity = 0, -- at server start
	Step = 0.25, -- menu - / +
	Area = 100, -- studs: square of rain around the camera
	Height = 45, -- studs above the camera the drops start
	FallSpeed = { 75, 95 }, -- studs/s
	WindDrift = 0.6, -- how much of the wind's velocity the drops carry (slant)
	MaxDrops = 3200, -- drops per second at full intensity
	DropSize = 0.18, -- studs
	DropSquash = -2.6, -- ParticleEmitter.Squash: negative stretches each drop along its fall into a streak
	DropColor = Color3.fromRGB(195, 210, 228),
	DropTransparency = 0.35,
	MaxSplashes = 500, -- per second at full intensity
	SplashArea = 70, -- studs: square of splashes around the camera
	Darken = -0.06, -- ColorCorrection brightness at full intensity
	Desaturate = -0.15, -- ColorCorrection saturation at full intensity
}

-- The cloth of the Cloak, Cape and Scarf (client CloakView): Cols x Rows points pinned across the
-- back of the shoulders (a Scarf: two narrow tails at the back of the neck), simulated locally on
-- every client (verlet, fixed Step) and drawn as panels. It falls under gravity, is pushed by the
-- wind (Config.Wind) and trails the fighter's motion; the torso, legs, a bag and the ground keep
-- it out. Styles: each piece's shape (Collar, Mantle (0 = none), Clasp, the cloth's size, Strips:
-- the x offsets of its separate strips).
Config.Cloak = {
	Thickness = 0.06 * S,
	Step = 1 / 60,
	Iterations = 6, -- constraint passes per step (higher: less stretch)
	GravityScale = 0.45, -- of workspace.Gravity: cloth falls floatier than a body
	Drag = 3, -- per second, pulls the cloth toward the wind's velocity
	Gust = 0.4, -- the wind swells and falls by this fraction
	Flutter = 0.5, -- per-point wind variation (ripples along the cape)
	BodyMargin = 0.1 * S, -- the cape keeps this far off the torso and legs
	SimDistance = 150, -- farther from the camera the cape is hidden and not simulated
	ClaspColor = Color3.fromRGB(196, 158, 70),
	Styles = {
		Cloak = { Collar = 0.7, Mantle = 0.18, Clasp = true, Cols = 4, Rows = 8, Length = 3.3 * S, TopWidth = 1.7 * S, BottomWidth = 2.3 * S },
		Cape = { Collar = 0, Mantle = 0.07, Clasp = true, Cols = 4, Rows = 9, Length = 3.8 * S, TopWidth = 1.8 * S, BottomWidth = 2.0 * S },
		Scarf = { Collar = 1.0, Mantle = 0, Clasp = false, Cols = 2, Rows = 6, Length = 1.7 * S, TopWidth = 0.3 * S, BottomWidth = 0.26 * S, Strips = { -0.13 * S, 0.16 * S } },
	},
}

-- Incantations (J, from the book set on the sword: TAB > Weapon): the fighter holds the sword level across the
-- chest and runs the free hand along the flat from the guard to the tip (Shared.Sim.Incant);
-- the blade then takes the incantation for Duration seconds ("Incantation : Fire" in chat).
Config.Incant = {
	RaiseTime = 0.4, -- the blade comes level across the chest, the left hand to the guard
	RubTime = 1.0, -- the hand runs along the flat to the tip
	HoldTime = 0.3,
	LowerTime = 0.4,
	Grip = Vector3.new(0.85, 0.3, -1.15), -- right hand (upper-torso space, unscaled)
	Blade = Vector3.new(-1, 0.06, -0.12), -- the blade points left across the body
	Edge = Vector3.new(0, 0, -1), -- edge forward, flat up under the hand
	HandAbove = 0.2, -- the palm rides this far above the blade's centre line (scaled)
}
Config.Incantations = {
	Order = { "Fire" },
	Fire = {
		Label = "Fire",
		Duration = 25, -- seconds the blade burns
		Cooldown = 35, -- from the start of one incantation to the next
		PowerMult = 1.2, -- a burning blade strikes harder (cuts, blocks it pushes through)
		BurnTime = 3, -- a body part it wounds burns this long...
		BurnIntegrityPerSecond = 6, -- ...losing this much integrity per second (of 100)
		BurnBalancePerSecond = 4,
	},
}

-- Sound effects (server SoundFX). Put Roblox audio asset ids in Ids, as numbers or
-- "rbxassetid://..." strings; with several, one is picked at random each time. A slot left empty
-- plays nothing, or its Fallback slot's sound. Played in the world where it happens, so everyone
-- nearby hears it. Pitch is varied randomly between PitchMin and PitchMax.
Config.Sounds = {
	Slash = { Ids = { 135315310485417 }, Volume = 0.6, PitchMin = 0.92, PitchMax = 1.1 }, -- a swing starts (whoosh)
	Block = { Ids = { 7058511852 }, Volume = 0.9, PitchMin = 0.95, PitchMax = 1.05 }, -- blade stopped by a guard
	Parry = { Ids = { 7058511334 }, Volume = 1, PitchMin = 0.97, PitchMax = 1.03, Fallback = "Block" }, -- block raised just in time
	Clash = { Ids = {}, Volume = 0.9, PitchMin = 0.9, PitchMax = 1.1, Fallback = "Block" }, -- two swings meet, or a glance
	Cut = { Ids = { 133125472113214, 140462043853173 }, Volume = 0.8, PitchMin = 0.9, PitchMax = 1.1 }, -- a blade wounds a body
	Sever = { Ids = { 140325083438865 }, Volume = 0.9, PitchMin = 0.9, PitchMax = 1.05, Fallback = "Cut" }, -- a limb is cut off
	Decapitation = { Ids = { 140325083438865 }, Volume = 1, PitchMin = 0.95, PitchMax = 1.05, Fallback = "Sever" },
	KickLanded = { Ids = { 135240815029802 }, Volume = 0.9, PitchMin = 0.9, PitchMax = 1.1 }, -- a teep lands
	KickBlocked = { Ids = { 136811265205147 }, Volume = 0.8, PitchMin = 0.95, PitchMax = 1.05, Fallback = "Block" }, -- a teep checked by the guard
	Draw = { Ids = {}, Volume = 0.8, PitchMin = 0.95, PitchMax = 1.05 }, -- drawing the katana (1)
	Sheathe = { Ids = {}, Volume = 0.8, PitchMin = 0.95, PitchMax = 1.05 }, -- sheathing it
	ArmorHit = { Ids = {}, Volume = 0.9, PitchMin = 0.85, PitchMax = 1.0, Fallback = "Block" }, -- a blade stopped by armour
	ArmorBreak = { Ids = {}, Volume = 1, PitchMin = 0.9, PitchMax = 1.0, Fallback = "Clash" }, -- an armour piece breaks
	Incantation = { Ids = {}, Volume = 0.9, PitchMin = 1, PitchMax = 1 }, -- an incantation takes hold of the blade
	FireHit = { Ids = {}, Volume = 0.8, PitchMin = 0.9, PitchMax = 1.1 }, -- a burning blade sets a body part alight
	RollOffMaxDistance = 120,
	SlashCooldown = 0.2, -- per fighter: fast back-and-forth strokes do not stack whooshes
	HitSoundCooldown = 0.4, -- per attacker: one cut sound for a blade passing through several body parts
}

Config.Block = {
	Strength = 16,
	ParryWindow = 0.3,
	ParryMinQuality = 0.55,
	MinQuality = 0.3, -- below this the attack glances along the guard
	OverpowerRatio = 2.0,
	BalanceCostPerPower = 4,
	GlanceEnergyMult = 0.55,
	OverpowerEnergyMult = 0.5,
	BeatEnergyMult = 0.75,
	ClashRecoilMult = 0.6,
	FrontTolerance = -0.15,
}

Config.Balance = {
	Max = 100,
	Regen = 24,
	OffBalanceThreshold = 35,
	RecoverAt = 60,
	CostPerPower = 6.5,
	LocationMult = {
		Head = 1.3, Neck = 1.2, UpperTorso = 1.0, LowerTorso = 1.15,
		Arm = 0.45, Hand = 0.3, Thigh = 1.35, Shin = 1.5, Foot = 1.4,
	},
	-- only a major hit to the head or the legs knocks a fighter over (CombatResolver.react): a cut
	-- anywhere else staggers at most, and cannot take balance below BodyHitFloor
	KnockdownClasses = { Head = true, Thigh = true, Shin = true, Foot = true },
	BodyHitFloor = 8,
	AttackingMult = 1.25,
	BlockingMult = 0.85,
	OffBalanceMult = 1.5,
	TiltFallAngle = math.rad(52),
	TiltFallTime = 0.15,
	UngroundedFallTime = 0.55,
}

Config.Recovery = {
	MinFallTime = 0.6,
	SettleSpeed = 3.5,
	MaxFallTime = 2.5,
	BraceTime = 0.9, -- time on the ground before an automatic attempt
	RampTime = 1.5, -- strength ramp of an attempt (divided by leg support)
	Timeout = 3.4,
	StableTime = 0.25,
	SuccessUpDot = math.cos(math.rad(22)),
	SuccessHeightFrac = 0.82,
	MaxSuccessSpeed = 7,
	RetryBaseDelay = 0.6,
	RetryMaxDelay = 2.5,
	ManualMinGroundTime = 0.35,
	RestoredBalance = 55,
	MinLegSupport = 0.2,
	UprightTorqueScale = 0.85,
}

Config.Anatomy = {
	DamagePerPower = 4.2,
	DepthPerPower = 0.9, -- unscaled studs of penetration per unit of power above resistance
	KindDamage = { Cut = 1.0, Thrust = 0.8, Blunt = 0.55 },
	KindPenetration = { Cut = 1.0, Thrust = 1.35, Blunt = 0.12 },
	KindBleed = { Cut = 1.0, Thrust = 0.85, Blunt = 0.12 },
	StoppedDamageMult = 0.45,
	EnergyRemaining = { Stopped = 0.4, Wound = 0.55, Severed = 0.6 }, -- stroke energy kept after a contact
	BleedPerDamage = 0.55, -- ml/s of bleeding per point of segment damage
	DisableBelow = 15, -- integrity below which a segment stops functioning
	BladeHalfWidth = 0.12 * S,
	OrganDamagePerPower = 11,
	ConcussionPower = 6,
	ConcussionDamage = 6,
	SeverIntegrityWeight = 0.55, -- how much existing damage lowers the sever threshold
	DisarmHandIntegrity = 20,
	MaxWoundMarks = 14,
	MaxBleedEmitters = 8,
}

Config.Blood = {
	Max = 5000, -- ml
	WeakAt = 0.72,
	VeryWeakAt = 0.58,
	Incapacitated = 0.5,
	Lethal = 0.4,
	TickInterval = 0.25,
	WoundClotRate = 0.03, -- per second (exponential)
	StumpClotRate = 0.008,
	MaxBleedRate = 900,
}

Config.Dismemberment = {
	DebrisLifetime = 25,
	MaxDebrisModels = 30,
	SeverDVPerPower = 1.6,
	MaxSeverDV = 22,
	CorpseLifetime = 20,
}

Config.Lifecycle = {
	RespawnDelay = 5,
	SpawnRadius = 16,
	FirstSpawnDelay = 0.5,
}

Config.Camera = {
	Offset = Vector3.new(2.0, 0.7, 9.5), -- right, up, back (over the shoulder)
	FrontOffset = Vector3.new(0, 0.7, 9.5), -- front view (V): centred, looking back at the fighter
	FocusHeight = 0.9,
	FollowSharpness = 14,
	MinPitch = -0.75,
	MaxPitch = 0.45,
	-- lock-on (K, client LockOn): a spinning diamond marks the fighter K would lock onto (the one
	-- nearest the middle of the screen); locked, the camera (and so the facing) follows them
	LockRange = 60, -- studs: candidates
	LockBreakRange = 90, -- studs: a lock is dropped beyond this
	LockScreenRadius = 0.4, -- candidates within this fraction of the screen from its centre
	LockTurnSharpness = 10, -- 1/s: how quickly the camera swings round to the target
	LockPitchBias = -0.12, -- the camera looks slightly down past the target
}

return Config
