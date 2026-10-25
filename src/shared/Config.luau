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
}

Config.Network = {
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
	StanceKneeBend = math.rad(16),
}

Config.Drives = {
	PelvisTorquePerMass = 1400, -- upright torque = this * body mass * state tone
	PelvisResponsiveness = 45,
	Joint = {
		Waist = { Torque = 4000, Responsiveness = 45 },
		Neck = { Torque = 1200, Responsiveness = 40 },
		Head = { Torque = 700, Responsiveness = 40 },
		Shoulder = { Torque = 1000, Responsiveness = 40 },
		Wrist = { Torque = 120, Responsiveness = 30 },
		Hip = { Torque = 2200, Responsiveness = 45 },
		Ankle = { Torque = 500, Responsiveness = 35 },
		Elbow = { Torque = 900, Speed = 14 },
		Knee = { Torque = 2200, Speed = 14 },
	},
	HandForce = 3500,
	HandResponsiveness = 60,
	HandMaxVelocity = 46, -- physical cap on hand speed (server-side swing speed limit)
	HandTorque = 1800,
	HandAngResponsiveness = 60,
	HandMaxAngularVelocity = 40,
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
	GuardBlendRate = 20,
	ReadyBlendRate = 10,
	ClientSensitivity = 0.0042, -- disk radii per mouse pixel while M1/M2 held
	CameraSensitivity = 0.0035, -- radians per mouse pixel otherwise
	GripSpreadX = 0.95,
	GripSpreadY = 0.85,
	GripBaseY = -0.05,
	GripDepth = 1.0,
	ThrustDepth = 0.55,
	BladeOutward = 1.25,
	BladeLift = 0.2,
	CrossBodyDepth = 0.45, -- extra forward reach when the sword hand crosses to the left
	GuardRadius = 0.75,
	GuardBaseY = 0.25,
	GuardDepth = 1.25,
	GuardBladeFraction = 0.35, -- how far up the blade the guard meets the threatened line
	GuardHandDepth = 1.05, -- the guard never pulls the hands closer to the chest than this
	-- Key poses: grip position (unscaled, upper-torso space: +X right, +Y up, -Z forward) and blade
	-- direction. Idle: two-handed, hands low in front of the hips, blade angled up and forward.
	ReadyGrip = Vector3.new(0.08, -0.75, -1.45),
	ReadyBlade = Vector3.new(-0.08, 0.62, -0.78),
	-- Windup: cursor pushed up past WindupStart draws the sword back over the head (hands above
	-- the forehead, blade pointing back behind the head), so pulling the cursor down from there is
	-- a full vertical cut. WindupPosLead > 1 lifts the hands before the blade rotates back over the
	-- head so the blade clears it.
	WindupStart = 0.45,
	WindupPosLead = 1.3,
	WindupGrip = Vector3.new(0.1, 2.3, -0.75),
	WindupBlade = Vector3.new(0.05, 0.4, 0.92),
	WindupSpreadX = 0.4, -- grip shift per unit of cursor u while wound up (diagonal windups)
	WindupBladeOutward = 0.3,
	-- High guard (M2 with the cursor up): blade held flat across in front of the top of the head,
	-- tip to the right, hands up at the front-left of the forehead, to stop vertical cuts. (The
	-- tip must go right: the left hand holds the pommel end, so it has to be the hand further left.)
	HighGuardStart = 0.55, -- cursor direction (vertical component) where the high-guard layout begins
	HighGuardDrop = 1.3, -- how far the guard sits below HighGuardGrip with the cursor near the centre
	HighGuardGrip = Vector3.new(-0.15, 2.15, -0.9),
	HighGuardBlade = Vector3.new(0.98, 0.1, -0.15),
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
	FocusHeight = 0.9,
	FollowSharpness = 14,
	MinPitch = -0.75,
	MaxPitch = 0.45,
}

return Config
