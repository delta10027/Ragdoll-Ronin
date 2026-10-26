--[[
	SheathService: draws and sheathes the katana (key 1, CombatAction "Sheath").

	Sheathed, the sword sits in its saya on the left hip (CharacterBuilder): welded to the scabbard
	instead of the hand, its blade and solid collider switched off so nothing can hit or clash with
	it, and the fighter cannot attack or block (f.Sheathed: the controllers treat the hands as empty
	and the arms hang). Drawing puts it back in the right hand exactly as it was built.
	Players spawn sheathed (Config.Sheath.StartSheathed); a crippled or lost sword hand cannot draw.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.RagdollRonin
local Config = require(Shared.Config)
local StateDefs = require(Shared.StateDefs)
local SwordController = require(Shared.Sim.SwordController)
local SoundFX = require(script.Parent.SoundFX)

local SheathService = {}

local function canDraw(f)
	local hand = f.Parts.RightHand
	return hand ~= nil and hand.Parent ~= nil and f.Drives.HandPos ~= nil and f.Caps.SwordArm > 0.05
		and f.Anatomy.Segments.RightHand.Integrity >= Config.Anatomy.DisarmHandIntegrity
end

-- returns true if the sword moved
function SheathService.Set(f, sheathed)
	local sw = f.Sword
	if not sw or f.Dead or (f.Sheathed == true) == sheathed or not sw.Saya or not sw.Saya.Parent then
		return false
	end
	if sheathed then
		SwordController.EndStroke(f, "Sheathed")
		if f.Aim then
			f.Aim.Bind = nil
		end
		sw.GripJoint.Enabled = false
		sw.Model:PivotTo(f.Parts.LowerTorso.CFrame * sw.SheathLocal)
		sw.SheathWeld.Enabled = true
	else
		if not canDraw(f) then
			return false
		end
		sw.SheathWeld.Enabled = false
		sw.Model:PivotTo(f.Parts.RightHand.CFrame * sw.HandLocal)
		sw.GripJoint.Enabled = true
	end
	f.Sheathed = sheathed
	sw.Blade.CanQuery = not sheathed
	if sw.Collider then
		sw.Collider.CanCollide = not sheathed
	end
	if sw.ParryZone then
		sw.ParryZone.CanQuery = false
	end
	if f.Block then
		f.Block.Active = false
	end
	sw.Handle.AssemblyLinearVelocity = f.Parts.LowerTorso.AssemblyLinearVelocity
	sw.Handle.AssemblyAngularVelocity = Vector3.zero
	f.Attack.PrevBladeCF = nil -- no stroke from the jump between hip and hand
	f.Model:SetAttribute("Sheathed", sheathed)
	f.OwnershipDirty = 3 -- the sword joined another assembly: re-pin ownership
	SoundFX.Play(sheathed and "Sheathe" or "Draw", sw.Handle.Position)
	return true
end

function SheathService.Toggle(f)
	if not StateDefs.Upright[f.State] or f.State == "Kicking" then
		return false
	end
	return SheathService.Set(f, not f.Sheathed)
end

return SheathService
