local run = function(func) func() end
local cloneref = cloneref or function(obj) return obj end

local playersService = cloneref(game:GetService('Players'))
local inputService = cloneref(game:GetService('UserInputService'))
local replicatedStorage = cloneref(game:GetService('ReplicatedStorage'))
local runService = cloneref(game:GetService('RunService'))
local collectionService = cloneref(game:GetService('CollectionService'))
local lightingService = cloneref(game:GetService('Lighting'))

local gameCamera = workspace.CurrentCamera
local lplr = playersService.LocalPlayer
local vain = shared.vain
local entitylib = vain.Libraries.entity
local targetinfo = vain.Libraries.targetinfo
local whitelist = vain.Libraries.whitelist

local function notif(...)
	return vain:CreateNotification(...)
end

-- Rivals does not put players on Roblox Teams, which is the whole problem the universal
-- aim modules have here: entitylib.targetCheck falls back to Player.Team, and with
-- lplr.Team nil it returns true for everybody - so every module treats teammates as
-- valid targets.
--
-- Where the team actually lives is not something that can be assumed, so this reads the
-- places a Roblox game realistically keeps it and uses the first that answers. If none
-- do, it says so rather than guessing: returning "unknown" leaves targeting exactly as
-- it is today instead of silently deciding half the lobby is friendly.
local TEAM_KEYS = {'Team', 'TeamName', 'TeamId', 'Side', 'Squad'}

local function teamOf(player)
	if not player then return nil end

	-- Roblox Teams, in case some modes do use them.
	if player.Team then return tostring(player.Team) end

	for _, key in TEAM_KEYS do
		local value = player:GetAttribute(key)
		if value ~= nil then return tostring(value) end
	end

	local character = player.Character
	if character then
		for _, key in TEAM_KEYS do
			local value = character:GetAttribute(key)
			if value ~= nil then return tostring(value) end
		end
	end

	local stats = player:FindFirstChild('leaderstats')
	if stats then
		for _, key in TEAM_KEYS do
			local value = stats:FindFirstChild(key)
			if value and value.Value ~= nil then return tostring(value.Value) end
		end
	end

	return nil
end

-- Replaces the library's check for this game only. Overriding this one function is
-- enough: entitylib calls it when an entity is added and again whenever it re-evaluates
-- Targetable, so every module that filters on Targetable picks this up for free.
entitylib.targetCheck = function(entity)
	if not entity.Player then
		return true
	end

	-- Replacing the library's check means replacing all of it, and this half was missing:
	-- ranked players were protected everywhere except here, so an Owner was as targetable
	-- as anybody else in this game alone.
	if not select(2, whitelist:get(entity.Player)) then
		return false
	end

	if entity.TeamCheck then
		return entity:TeamCheck()
	end

	local mine, theirs = teamOf(lplr), teamOf(entity.Player)
	if mine == nil or theirs == nil then
		-- Team could not be determined for one of us. Left targetable, which is the
		-- behaviour without this file at all - better than hiding real enemies.
		return true
	end

	return mine ~= theirs
end

-- Said once, because silently aiming at teammates is worse than being told the team
-- source needs finding.
task.spawn(function()
	task.wait(10)
	if teamOf(lplr) == nil then
		notif('Vain', 'Rivals: could not work out which team you are on, so teammates are not being filtered. Run the team probe and send the output.', 15, 'alert')
	end
end)

vain.Libraries.rivals = {
	teamOf = teamOf,
	teamKeys = TEAM_KEYS
}


local Aimbot
local Targets
local Part
local FOV
local Range
local Smoothing
local Sticky
local RequireMouse
local ShowFOV
local FOVColor
local CircleObject
local current

-- Screen-space distance from the crosshair, in pixels, plus whether the point is even
-- in front of the camera. Picking by world angle instead would happily lock onto
-- something behind you at a shallow angle.
local function screenDistance(position)
	local point, onScreen = gameCamera:WorldToViewportPoint(position)
	if not onScreen then return nil end

	local centre = gameCamera.ViewportSize / 2
	return (Vector2.new(point.X, point.Y) - centre).Magnitude
end

local function partOf(entity)
	if Part.Value == 'Head' then return entity.Head or entity.RootPart end
	if Part.Value == 'Body' then return entity.RootPart end
	-- Nearest: whichever of the two currently sits closer to the crosshair, so a target
	-- peeking with only their head showing is still tracked.
	local head, root = entity.Head, entity.RootPart
	if not head then return root end
	if not root then return head end

	local headDist = screenDistance(head.Position)
	local rootDist = screenDistance(root.Position)
	if not headDist then return root end
	if not rootDist then return head end
	return headDist <= rootDist and head or root
end

local function findTarget()
	local best, bestDist

	for _, entity in entitylib.List do
		-- Targetable is what carries the team check from base.lua, so teammates never
		-- reach this loop.
		if not entity.Targetable then continue end
		if entity.Player and not Targets.Players.Enabled then continue end
		if entity.NPC and not Targets.NPCs.Enabled then continue end

		local part = partOf(entity)
		if not part then continue end
		if not entitylib.isAlive then return nil end
		if (part.Position - entitylib.character.RootPart.Position).Magnitude > Range.Value then continue end

		local dist = screenDistance(part.Position)
		if not dist or dist > FOV.Value then continue end

		if Targets.Walls.Enabled and entitylib.Wallcheck(gameCamera.CFrame.Position, part.Position) then
			continue
		end

		if not bestDist or dist < bestDist then
			best, bestDist = entity, dist
		end
	end

	return best
end

Aimbot = vain.Categories.Combat:CreateModule({
	Name = 'Aimbot',
	Function = function(callback)
		if CircleObject then
			CircleObject.Visible = callback and ShowFOV.Enabled
		end

		if callback then
			current = nil

			Aimbot:Clean(runService.RenderStepped:Connect(function()
				if CircleObject then
					CircleObject.Position = inputService:GetMouseLocation()
					CircleObject.Radius = FOV.Value
				end

				if not entitylib.isAlive then
					current = nil
					return
				end

				if RequireMouse.Enabled and not inputService:IsMouseButtonPressed(0) then
					current = nil
					return
				end

				-- Sticky keeps the current target until it dies, leaves range or leaves
				-- the cone, rather than re-picking every frame. Without it the aim
				-- snaps between two enemies standing near each other and lands on
                -- neither.
				if Sticky.Enabled and current and current.Targetable and current.Character and current.Character.Parent then
					local part = partOf(current)
					local dist = part and screenDistance(part.Position)
					if not (dist and dist <= FOV.Value) then
						current = nil
					end
				else
					current = nil
				end

				current = current or findTarget()
				if not current then return end

				local part = partOf(current)
				if not part then return end

				targetinfo.Targets[current] = tick() + 1

				local goal = CFrame.new(gameCamera.CFrame.Position, part.Position)
				if Smoothing.Value <= 0 then
					gameCamera.CFrame = goal
				else
					-- Framerate independent, so the feel does not change with FPS. A
					-- plain per-frame lerp moves twice as fast at 120 as at 60.
					local alpha = 1 - math.exp(-(1 / math.max(Smoothing.Value, 0.001)) * runService.RenderStepped:Wait())
					gameCamera.CFrame = gameCamera.CFrame:Lerp(goal, math.clamp(alpha, 0, 1))
				end
			end))
		else
			current = nil
		end
	end,
	Tooltip = 'Aims at the closest enemy to your crosshair\nTeammates are excluded by the team check in this game\'s base'
})
Targets = Aimbot:CreateTargets({
	Players = true,
	Walls = true,
	Tooltip = 'Which entities this is allowed to aim at'
})
Part = Aimbot:CreateDropdown({
	Name = 'Target Part',
	Tooltip = 'Which part to aim at',
	List = {'Nearest', 'Head', 'Body'},
	Tooltips = {
		Nearest = 'Whichever of the head or body is closer to your crosshair',
		Head = 'Always the head',
		Body = 'Always the torso, which is easier to keep on target'
	}
})
FOV = Aimbot:CreateSlider({
	Name = 'FOV',
	Tooltip = 'How far from your crosshair a target may be, in pixels',
	Min = 10,
	Max = 800,
	Default = 160,
	Function = function(val)
		if CircleObject then
			CircleObject.Radius = val
		end
	end,
	Suffix = 'px'
})
Range = Aimbot:CreateSlider({
	Name = 'Range',
	Tooltip = 'How far away a target may be, in studs',
	Min = 10,
	Max = 2000,
	Default = 1000,
	Suffix = function(val)
		return val == 1 and 'stud' or 'studs'
	end
})
Smoothing = Aimbot:CreateSlider({
	Name = 'Smoothing',
	Tooltip = 'How long the aim takes to settle on a target\n0 snaps instantly',
	Min = 0,
	Max = 1,
	Default = 0.12,
	Decimal = 100,
	Suffix = 'seconds'
})
Sticky = Aimbot:CreateToggle({
	Name = 'Sticky',
	Tooltip = 'Keeps the current target until it leaves your FOV, instead of re-picking every frame',
	Default = true
})
RequireMouse = Aimbot:CreateToggle({
	Name = 'Require mouse down',
	Tooltip = 'Only aims while you hold left click',
	Default = true
})
ShowFOV = Aimbot:CreateToggle({
	Name = 'Show FOV',
	Tooltip = 'Draws the FOV circle around your cursor',
	Function = function(callback)
		if FOVColor.Object then
			FOVColor.Object.Visible = callback
		end
		if CircleObject then
			CircleObject.Visible = callback and Aimbot.Enabled
		end
	end,
	Default = true
})
FOVColor = Aimbot:CreateColorSlider({
	Name = 'FOV Color',
	Tooltip = 'Colour of the FOV circle',
	Function = function(hue, sat, val, opacity)
		if CircleObject then
			CircleObject.Color = Color3.fromHSV(hue, sat, val)
			CircleObject.Transparency = opacity
		end
	end,
	Darker = true
})

run(function()
	CircleObject = Drawing.new('Circle')
	CircleObject.Thickness = 2
	CircleObject.Filled = false
	CircleObject.Radius = FOV.Value
	CircleObject.Color = Color3.fromHSV(FOVColor.Hue, FOVColor.Sat, FOVColor.Value)
	CircleObject.Transparency = FOVColor.Opacity
	CircleObject.Visible = false

	vain:Clean(function()
		CircleObject:Remove()
	end)
end)
