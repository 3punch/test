-- ProfessorBuilder (ModuleScript, Server)
-- Builds the Professor NPC as a canonical R6 block rig (same part sizes and the
-- same part layout as a real Roblox R6 character) so that Humanoid:MoveTo and
-- PathfindingService behave exactly as they do for a player character.
--
-- How the joints are built:
--   Every body part is first placed at its canonical R6 position (relative to
--   the HumanoidRootPart, which sits at the Torso center):
--       Head        Torso + (0,   +2,   0)
--       Left Arm    Torso + (-1.5,  0,  0)
--       Right Arm   Torso + (+1.5,  0,  0)
--       Left Leg    Torso + (-0.5, -2,  0)
--       Right Leg   Torso + (+0.5, -2,  0)
--   The Motor6D joints are then created with C1 = identity and
--   C0 = Part0.CFrame:ToObjectSpace(Part1.CFrame), which reproduces exactly that
--   layout. (Canonical rigs split the same transform between C0 and C1; deriving
--   C0 from real part positions removes any chance of a typo'd offset producing
--   a rig that is assembled wrong and breaks Humanoid movement.)
local ProfessorBuilder = {}

local BODY_COLOR = Color3.fromRGB(45, 40, 40)
local LEG_COLOR = Color3.fromRGB(30, 28, 28)
local SKIN_COLOR = Color3.fromRGB(225, 200, 180)

local TEMPLATE_NAME = "ProfessorTemplate"

-- Canonical R6 part layout, relative to the Torso center. The Torso (and the
-- HumanoidRootPart, which shares its position) sits 3 studs above the origin so
-- nothing is embedded in the floor when the template is created.
local TORSO_ORIGIN = Vector3.new(0, 3, 0)
local LAYOUT = {
	Torso = TORSO_ORIGIN,
	HumanoidRootPart = TORSO_ORIGIN,
	Head = TORSO_ORIGIN + Vector3.new(0, 2, 0),
	["Left Arm"] = TORSO_ORIGIN + Vector3.new(-1.5, 0, 0),
	["Right Arm"] = TORSO_ORIGIN + Vector3.new(1.5, 0, 0),
	["Left Leg"] = TORSO_ORIGIN + Vector3.new(-0.5, -2, 0),
	["Right Leg"] = TORSO_ORIGIN + Vector3.new(0.5, -2, 0),
}

-- Joint name -> { Part0, Part1 } (canonical R6 directions)
local JOINTS = {
	{ "RootJoint", "HumanoidRootPart", "Torso" },
	{ "Neck", "Torso", "Head" },
	{ "Left Shoulder", "Torso", "Left Arm" },
	{ "Right Shoulder", "Torso", "Right Arm" },
	{ "Left Hip", "Torso", "Left Leg" },
	{ "Right Hip", "Torso", "Right Leg" },
}

local function makePart(model, name, size, color, canCollide)
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Color = color
	part.Material = Enum.Material.SmoothPlastic
	part.CanCollide = canCollide
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Anchored = false
	-- Place the part at its canonical spot before the joints are created; the
	-- joints below are derived from these positions.
	part.CFrame = CFrame.new(LAYOUT[name])
	part.Parent = model
	return part
end

local function makeJoint(name, part0, part1)
	local joint = Instance.new("Motor6D")
	joint.Name = name
	joint.Part0 = part0
	joint.Part1 = part1
	joint.C0 = part0.CFrame:ToObjectSpace(part1.CFrame)
	joint.C1 = CFrame.new()
	joint.Parent = part0
	return joint
end

-- Build a canonical R6 block rig from scratch.
function ProfessorBuilder._buildCanonicalR6()
	local model = Instance.new("Model")
	model.Name = TEMPLATE_NAME

	local parts = {}
	parts.HumanoidRootPart = makePart(model, "HumanoidRootPart", Vector3.new(2, 2, 1), BODY_COLOR, false)
	parts.HumanoidRootPart.Transparency = 1
	parts.Torso = makePart(model, "Torso", Vector3.new(2, 2, 1), BODY_COLOR, true)
	parts.Head = makePart(model, "Head", Vector3.new(2, 2, 2), SKIN_COLOR, false)
	parts["Left Arm"] = makePart(model, "Left Arm", Vector3.new(1, 2, 1), BODY_COLOR, false)
	parts["Right Arm"] = makePart(model, "Right Arm", Vector3.new(1, 2, 1), BODY_COLOR, false)
	parts["Left Leg"] = makePart(model, "Left Leg", Vector3.new(1, 2, 1), LEG_COLOR, false)
	parts["Right Leg"] = makePart(model, "Right Leg", Vector3.new(1, 2, 1), LEG_COLOR, false)

	-- Flat face (built-in Roblox texture) so the head is not blank
	local face = Instance.new("Decal")
	face.Name = "Face"
	face.Face = Enum.NormalId.Front
	face.Texture = "rbxasset://textures/face.png"
	face.Parent = parts.Head

	-- Canonical R6 joints. Part0/Part1 direction matters: RootJoint must go
	-- HumanoidRootPart -> Torso, Neck Torso -> Head, Shoulders/Hips Torso -> limb.
	for _, spec in ipairs(JOINTS) do
		makeJoint(spec[1], parts[spec[2]], parts[spec[3]])
	end

	local hum = Instance.new("Humanoid")
	hum.Name = "Humanoid"
	hum.WalkSpeed = 12
	hum.JumpPower = 0
	hum.JumpHeight = 0
	hum.MaxHealth = 100000
	hum.Health = 100000
	hum.AutoRotate = true
	hum.Parent = model

	model.PrimaryPart = parts.HumanoidRootPart
	return model
end

-- The template is built once and cloned for every round.
local _cachedTemplate = nil
local function getR6Template()
	if not _cachedTemplate then
		_cachedTemplate = ProfessorBuilder._buildCanonicalR6()
	end
	return _cachedTemplate
end

-- Attach a small decorative part to a body part with a Weld (Massless so the
-- physics of the rig is unchanged).
local function decorate(model, name, size, color, material, parentPart, offset)
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Color = color
	part.Material = material
	part.CanCollide = false
	part.Massless = true
	part.Anchored = false
	part.CFrame = parentPart.CFrame * offset
	part.Parent = model

	local weld = Instance.new("Weld")
	weld.Name = name .. "Weld"
	weld.Part0 = parentPart
	weld.Part1 = part
	weld.C0 = offset
	weld.Parent = parentPart
	return part
end

function ProfessorBuilder.Build()
	local model = getR6Template():Clone()
	model.Name = "Professor"

	local torso = model:WaitForChild("Torso")
	local head = model:WaitForChild("Head")
	local root = model:WaitForChild("HumanoidRootPart")

	-- White shirt panel + red tie (welded to the Torso)
	decorate(model, "ShirtFront", Vector3.new(1.7, 0.9, 0.1),
		Color3.fromRGB(235, 230, 215), Enum.Material.SmoothPlastic, torso,
		CFrame.new(0, 0.25, 0.55))
	decorate(model, "Tie", Vector3.new(0.25, 1.2, 0.08),
		Color3.fromRGB(120, 25, 25), Enum.Material.SmoothPlastic, torso,
		CFrame.new(0, -0.3, 0.56))

	-- Dark sunken eyes (welded to the Head, in front of the face decal)
	for side = -1, 1, 2 do
		local eye = decorate(model, "Eye", Vector3.new(0.35, 0.15, 0.04),
			Color3.fromRGB(20, 20, 20), Enum.Material.SmoothPlastic, head,
			CFrame.new(side * 0.4, 0.15, 1.01))
		eye.Name = side < 0 and "LeftEye" or "RightEye"
	end

	-- Speed-burst warning light above the head (off until a burst winds up)
	local warnLight = decorate(model, "BurstLight", Vector3.new(0.6, 0.6, 0.6),
		Color3.fromRGB(255, 70, 70), Enum.Material.Neon, head, CFrame.new(0, 1.5, 0))
	warnLight.Transparency = 1
	local pointLight = Instance.new("PointLight")
	pointLight.Name = "BurstPointLight"
	pointLight.Brightness = 0
	pointLight.Range = 25
	pointLight.Color = Color3.fromRGB(255, 60, 60)
	pointLight.Parent = warnLight

	-- Humanoid configuration (Config values are applied by ProfessorAI on Start)
	local hum = model:WaitForChild("Humanoid")
	hum.WalkSpeed = 12
	hum.JumpPower = 0
	hum.JumpHeight = 0
	hum.MaxHealth = 100000
	hum.Health = 100000
	hum.AutoRotate = true

	-- Sound placeholders. Every SoundId is intentionally empty; drop asset ids in
	-- later (or replace the whole Sounds folder) to add audio.
	local sounds = Instance.new("Folder")
	sounds.Name = "Sounds"
	local function makeSound(name, props)
		local s = Instance.new("Sound")
		s.Name = name
		for k, v in pairs(props or {}) do
			s[k] = v
		end
		s.Parent = sounds
		return s
	end
	makeSound("Footstep", { Volume = 0.35, RollOffMaxDistance = 40 })
	makeSound("Chase", { Volume = 0.25, Looped = true, RollOffMaxDistance = 60 })
	makeSound("BurstWarning", { Volume = 0.6 })
	makeSound("BurstActive", { Volume = 0.4, Looped = true })
	makeSound("Catch", { Volume = 0.7 })
	sounds.Parent = model

	-- Invisible ForceField so stray damage can never kill the NPC
	local forceField = Instance.new("ForceField")
	forceField.Name = "ProfessorForceField"
	forceField.Visible = false
	forceField.Parent = model

	-- Park the whole rig at the template position until ProfessorAI:Start moves it.
	root.CFrame = CFrame.new(TORSO_ORIGIN)
	model.PrimaryPart = root
	return model
end

return ProfessorBuilder
