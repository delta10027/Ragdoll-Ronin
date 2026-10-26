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
	StrideLength = 3.0 * S,
	GaitHipAmplitude = math.rad(30),
	GaitKneeAmplitude = math.rad(50),
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
	CommitmentDistance = 3.5, -- tip travel for a fully committed stroke
	MinCommitment = 0.35,
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
}

return Config
