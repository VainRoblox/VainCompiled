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
local prediction = vain.Libraries.prediction

local function notif(...)
	return vain:CreateNotification(...)
end

--[[
	Tribes 3v3 (place 72169370437173, universe 10768498581, by Snick Co). A single
	round-based place - the lobby and the match run in the same place.

	The combat is custom: no Roblox Tools held in hand, no TouchTransmitters, no Teams. A
	swing is the client calling the game's own Controller, which runs a Detect pass and sends
	the hit list to the server over a WeaponAction remote - the client chooses who it hit.
	This file finds those modules so the combat modules can drive them directly, which is the
	only way to land a hit here and the only honest source of who is a teammate.
]]

-- The combat modules, found once and cached. require returns the same table the game's own
-- scripts hold, so a hook here is a hook on what the game actually runs.
local combat = {}

--[[
	Finds the combat folder and requires its modules.

	The folder is the one holding a Controller module beside a Handlers folder with a Melee
	module and a Util module - the shape the game's own bootstrap relies on. Searched under
	the player's scripts and ReplicatedStorage rather than the whole game, because those are
	where client modules live and walking everything each call is far too much.
]]
local function resolveCombat()
	if combat.Controller then
		return combat
	end

	local roots = {lplr:FindFirstChild('PlayerScripts'), replicatedStorage}
	for _, place in roots do
		if not place then continue end
		for _, d in place:GetDescendants() do
			if d:IsA('ModuleScript') and d.Name == 'Controller' then
				local parent = d.Parent
				local handlers = parent and parent:FindFirstChild('Handlers')
				if handlers and handlers:FindFirstChild('Melee') and parent:FindFirstChild('Util') then
					combat.root = parent
					pcall(function() combat.Util = require(parent.Util) end)
					pcall(function() combat.Melee = require(handlers.Melee) end)
					pcall(function() combat.Controller = require(parent.Controller) end)
					if combat.Controller then
						return combat
					end
				end
			end
		end
	end
	return combat
end

--[[
	A single hook on Melee.Detect, shared by Reach and Killaura.

	Detect is the function every melee swing calls to pick who it hit, from a range, a cone
	angle and a cap - and the client's choice is what the server is told. Widening its
	arguments is therefore the whole of Reach and the targeting half of Killaura, and both
	done in one place so they compose instead of fighting over the same function.

	Installed once and left in. When nothing has set anything it adds zero to the range and
	changes neither the arc nor the cap, so an idle hook is a plain passthrough rather than
	something to tear back out and race over.
]]
local detect = {reach = 0, minRange = nil, arc = nil, minTargets = nil}
local detectHooked = false

local function hookDetect()
	if detectHooked then return true end
	local c = resolveCombat()
	if not (c.Melee and type(c.Melee.Detect) == 'function') then
		return false
	end
	local real = c.Melee.Detect
	c.Melee.Detect = function(self, range, arc, maxTargets)
		range = (range or 8) + detect.reach
		-- Killaura sets a floor so a swing reaches as far as the module is set to find
		-- targets, not only the weapon's own reach.
		if detect.minRange and detect.minRange > range then range = detect.minRange end
		if detect.arc then arc = detect.arc end
		if detect.minTargets then maxTargets = math.max(maxTargets or 1, detect.minTargets) end
		return real(self, range, arc, maxTargets)
	end
	detectHooked = true
	return true
end

--[[
	Whether a character is on your team, asked of the game itself.

	Util.IsTeammate is the exact test the game runs before it will let a swing hit someone,
	so using it means Vain draws the line in precisely the same place the game does, with
	none of the attribute guessing a custom team system would otherwise need.
]]
local function isTeammate(character)
	local c = resolveCombat()
	if c.Util and type(c.Util.IsTeammate) == 'function' then
		local ok, mate = pcall(c.Util.IsTeammate, character)
		if ok then
			return mate == true, true
		end
	end
	return false, false
end

-- Replaces the library's check for this game only. entitylib calls it when an entity is
-- added and whenever it re-evaluates Targetable, so every module that filters on Targetable
-- filters teammates here for free.
entitylib.targetCheck = function(entity)
	if not entity.Player then
		return true
	end

	-- Ranked players stay protected here too.
	if not select(2, whitelist:get(entity.Player)) then
		return false
	end

	if entity.TeamCheck then
		return entity:TeamCheck()
	end

	local character = entity.Character
	if character then
		local mate, known = isTeammate(character)
		if known then
			return not mate
		end
	end

	-- The game's own check could not be reached yet. Left targetable, which is the
	-- behaviour without this file - better than hiding real enemies.
	return true
end

--[[
	The Controller's live weapon state, reached through its own dispatch closure.

	u5 - the table holding the equipped handler, character and humanoid - is a local the
	Controller never exposes, so Auto Block reads it from the upvalues of Dispatch, which
	closes over it. It is picked out by the fields it carries at all times (baseSpeed,
	shotId, killStreak), so a build that reorders upvalues still finds the right table rather
	than guessing by position. Everything that reads it tolerates nil, because the hook is
	only there to make Auto Block safe - never to block it working at all.
]]
local function handlerState()
	local c = resolveCombat()
	if not (c.Controller and type(c.Controller.Dispatch) == 'function' and debug and debug.getupvalues) then
		return nil
	end
	local ok, ups = pcall(debug.getupvalues, c.Controller.Dispatch)
	if not ok or type(ups) ~= 'table' then
		return nil
	end
	for _, v in pairs(ups) do
		if type(v) == 'table' and v.baseSpeed ~= nil and v.shotId ~= nil and v.killStreak ~= nil then
			return v
		end
	end
	return nil
end

vain.Libraries.tribes = {
	prediction = prediction,
	resolveCombat = resolveCombat,
	isTeammate = isTeammate,
	handlerState = handlerState,

	-- Whether the equipped weapon can block at all. Secondary on a weapon that cannot is a
	-- heavy or a lunge, so Auto Block checks this before it ever presses it.
	canBlock = function()
		local s = handlerState()
		return s ~= nil and s.handler ~= nil and s.handler.tuning ~= nil and s.handler.tuning.block ~= nil
	end,
	isBlocking = function()
		local s = handlerState()
		return s ~= nil and s.handler ~= nil and s.handler.blocking == true
	end,

	-- Reach and Killaura reach the shared Detect hook through these rather than touching the
	-- game's modules themselves, so neither has to know the other exists.
	hookDetect = hookDetect,
	setReach = function(extra)
		hookDetect()
		detect.reach = extra or 0
	end,
	setSwingDetect = function(arc, minTargets, minRange)
		hookDetect()
		detect.arc = arc
		detect.minTargets = minTargets
		detect.minRange = minRange
	end,
	clearSwingDetect = function()
		detect.arc = nil
		detect.minTargets = nil
		detect.minRange = nil
	end,

	--[[
		A one-shot dump of the other players, for anything the source does not already answer
		- a side source the game's own check somehow misses, or the loadout a player carries.
		It walks the player, character, backpack and leaderstats and lists every attribute,
		value and child model, because a loadout here is Tools in the backpack keyed by a
		SlotIndex attribute. Run it near an enemy and send the output.
	]]
	probe = function()
		local lines = {}

		local function dump(label, container, deep)
			if not container then return end
			local ok, attrs = pcall(function() return container:GetAttributes() end)
			if ok then
				for key, value in attrs do
					table.insert(lines, label..' attr '..tostring(key)..' = '..tostring(value)..' ('..typeof(value)..')')
				end
			end
			for _, child in container:GetChildren() do
				if child:IsA('ValueBase') then
					table.insert(lines, label..' value '..child.Name..' = '..tostring(child.Value))
				elseif deep and (child:IsA('Model') or child:IsA('Folder') or child:IsA('Tool')) then
					local slot = child:GetAttribute('SlotIndex')
					table.insert(lines, label..' child '..child.ClassName..' "'..child.Name..'"'..(slot and (' slot '..tostring(slot)) or ''))
				end
			end
		end

		for _, player in playersService:GetPlayers() do
			if player == lplr then continue end
			table.insert(lines, '== '..player.Name..' ==')
			dump('player', player, false)
			dump('character', player.Character, true)
			dump('backpack', player:FindFirstChildOfClass('Backpack'), true)
			dump('leaderstats', player:FindFirstChild('leaderstats'), false)
			if #lines > 200 then break end
		end

		local text = table.concat(lines, '\n')
		print('[Vain] Tribes probe:\n'..text)
		pcall(function() setclipboard(text) end)
		notif('Vain', 'Tribes probe copied to clipboard and printed to console', 10, 'check')
		return text
	end
}

--[[
	Found once, at load, not lazily in a hot path.

	The combat folder is copied into PlayerScripts a moment after you join, and requiring its
	modules can yield while they wait for their own children - neither of which belongs in a
	Heartbeat or a targetCheck that runs every frame. So the search is done here, retried
	until it lands, and everything after reads the cached result instantly. If it never
	lands, Killaura and Reach have nothing to drive, and that is said plainly rather than
	leaving them looking broken.
]]
task.spawn(function()
	for _ = 1, 60 do
		if resolveCombat().Controller then
			hookDetect()
			return
		end
		task.wait(1)
	end
	notif('Vain', 'Tribes: combat system not found - Killaura and Reach will not work. Rejoin if this persists.', 15, 'alert')
end)


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

			--[[
				RenderStepped, not BindToRenderStep.

				The aim has to be the last word on the camera each frame, and RenderStepped is
				the last render event before the frame draws - it fires after the game's own
				camera has placed itself, so writing the look here is what the game then reads.
				BindToRenderStep would do the same by priority, but executor threads are not
				always allowed to call it, and a capability error there switched the whole
				module off - which is the aimbot that "did not work".

				The game reads aim as its camera's position and look direction (GetAimRay
				returns Ray.new(camera.CFrame.Position, camera.CFrame.LookVector)), so keeping
				the camera's own position and only turning it to the target lands on exactly
				the ray a swing or shot travels down.
			]]
			Aimbot:Clean(runService.RenderStepped:Connect(function(dt)
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
				-- the cone, rather than re-picking every frame. Without it the aim snaps
				-- between two enemies standing near each other and lands on neither.
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

				-- From the camera's own position, so the result is the ray the game reads.
				local goal = CFrame.new(gameCamera.CFrame.Position, part.Position)
				if Smoothing.Value <= 0 then
					gameCamera.CFrame = goal
				else
					-- Framerate independent off the real frame time, so the feel does not
					-- change with FPS. A plain per-frame lerp moves twice as fast at 120.
					local alpha = 1 - math.exp(-(1 / math.max(Smoothing.Value, 0.001)) * dt)
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
		-- FOVColor is created after this toggle, and Default = true makes the GUI run this
		-- Function the moment the toggle is built - while FOVColor is still nil. Guarded so
		-- that first call does not index a setting that does not exist yet.
		if FOVColor and FOVColor.Object then
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


run(function()
	--[[
		Auto Block.
	
		Raises your guard when an enemy near you is facing your way - the moment a swing is most
		likely coming - and lowers it again when the threat passes, so you block the hit without
		holding guard up the whole fight. Blocking is the game's own Secondary on a weapon that
		can block; on a weapon that cannot, Secondary is a heavy or a lunge, so this never
		presses it unless the equipped weapon actually guards. That check reads the live handler
		through base, which is also why a true parry - blocking only in the split second a swing
		lands - is left for later: the timing has to come from the attacker's swing, not from how
		near they are.
	
		Facing is the tell it uses: an enemy within range whose look is turned toward you is
		treated as a threat. It is not frame-perfect, but it blocks the hits that a held guard
		would, without giving up your own swings the rest of the time.
	]]
	local AutoBlock
	local Range
	local Angle
	local tribes = vain.Libraries.tribes
	
	-- Held, so the guard is raised and dropped exactly once rather than re-sent every frame.
	local blocking = false
	
	local function setBlock(controller, on)
		if on == blocking then return end
		blocking = on
		if controller and controller.Dispatch then
			pcall(controller.Dispatch, 'Secondary', on)
		end
	end
	
	-- Whether an enemy near you is turned toward you. The dot of the enemy's look against the
	-- direction from them to you rises as they face you; the slider is that cone in degrees.
	local function threatNear()
		if not entitylib.isAlive then return false end
		local me = entitylib.character.RootPart
		if not me then return false end
	
		local threshold = math.cos(math.rad(Angle.Value / 2))
		for _, entity in entitylib.List do
			local root = entity.RootPart
			if entity.Targetable and root then
				local delta = me.Position - root.Position
				local dist = delta.Magnitude
				if dist <= Range.Value and dist > 0.05 then
					if root.CFrame.LookVector:Dot(delta.Unit) >= threshold then
						return true
					end
				end
			end
		end
		return false
	end
	
	AutoBlock = vain.Categories.Combat:CreateModule({
		Name = 'Auto Block',
		Function = function(callback)
			if callback then
				AutoBlock:Clean(runService.Heartbeat:Connect(function()
					local controller = tribes.resolveCombat().Controller
					if not (controller and controller.Dispatch) then
						return
					end
	
					-- Never guard with a weapon that does not guard - Secondary there is an
					-- attack, not a block.
					if not tribes.canBlock() then
						setBlock(controller, false)
						return
					end
	
					setBlock(controller, threatNear())
				end))
	
				AutoBlock:Clean(function()
					setBlock(tribes.resolveCombat().Controller, false)
				end)
			else
				setBlock(tribes.resolveCombat().Controller, false)
			end
		end,
		Tooltip = 'Raises your guard when an enemy faces you'
	})
	Range = AutoBlock:CreateSlider({
		Name = 'Range',
		Tooltip = 'How close an enemy must be to guard against them',
		Min = 4,
		Max = 30,
		Default = 12,
		Suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})
	Angle = AutoBlock:CreateSlider({
		Name = 'Facing Angle',
		Tooltip = 'How directly an enemy must face you to count as a threat\nWider guards against more',
		Min = 10,
		Max = 180,
		Default = 80,
		Suffix = 'degrees'
	})
	
end)

run(function()
	--[[
		Killaura.
	
		The swing is the game's own: when an enemy is in range this presses Primary through the
		Controller exactly as holding the mouse would, and the game runs its Detect pass and
		sends the hits itself. Nothing here fakes a hit packet - it drives the real attack - so
		it respects the weapon's cooldown and combo and carries the equip token the server checks,
		which a hand-built packet would get wrong.
	
		Detect only looks down a cone in front of you, so on its own it would hit nobody you were
		not already facing. While this is on it widens that cone through the shared Detect hook,
		so a swing lands on whoever is around you rather than only what is dead ahead, and the
		cone is put back the moment there is nothing to hit or the module goes off.
	]]
	local Killaura
	local Targets
	local Range
	local Angle
	local Max
	local Mouse
	local tribes = vain.Libraries.tribes
	
	-- Held, not clicked: pressing and releasing every frame fights the game's own combo timing,
	-- while holding lets it swing on its own cooldown the way the mouse would. This tracks
	-- whether we are currently holding so it is released exactly once.
	local holding = false
	
	local function release(controller)
		if holding then
			holding = false
			tribes.clearSwingDetect()
			if controller and controller.Dispatch then
				pcall(controller.Dispatch, 'Primary', false)
			end
		end
	end
	
	-- Whether any enemy the module is allowed to hit is within range. Uses the library's own
	-- list, so the team check in base has already removed teammates.
	local function enemyInRange()
		if not entitylib.isAlive then return false end
		local here = entitylib.character.RootPart
		if not here then return false end
		local plrs = entitylib.AllPosition({
			Range = Range.Value,
			Part = 'RootPart',
			Players = Targets.Players.Enabled,
			NPCs = Targets.NPCs.Enabled,
			Limit = 1
		})
		return #plrs > 0
	end
	
	Killaura = vain.Categories.Combat:CreateModule({
		Name = 'Killaura',
		Function = function(callback)
			if callback then
				tribes.hookDetect()
				if not tribes.resolveCombat().Controller then
					notif('Killaura', 'Combat system not found yet - try again in a match', 6, 'alert')
				end
	
				Killaura:Clean(runService.Heartbeat:Connect(function()
					local controller = tribes.resolveCombat().Controller
					if not (controller and controller.Dispatch) then
						return
					end
	
					-- Hold only while the mouse is down, when that is asked for.
					if Mouse.Enabled and not inputService:IsMouseButtonPressed(0) then
						release(controller)
						return
					end
	
					if not enemyInRange() then
						release(controller)
						return
					end
	
					-- Widen the game's Detect so the swing reaches who is around, not only
					-- ahead: the chosen cone, cap, and a reach floor matching the range the
					-- module looks for targets at, so a swing lands as far as it will swing.
					tribes.setSwingDetect(Angle.Value, Max.Value, Range.Value)
	
					if not holding then
						holding = true
						pcall(controller.Dispatch, 'Primary', true)
					end
				end))
	
				Killaura:Clean(function()
					release(tribes.resolveCombat().Controller)
				end)
			else
				release(tribes.resolveCombat().Controller)
			end
		end,
		Tooltip = 'Swings at enemies around you automatically'
	})
	Targets = Killaura:CreateTargets({
		Players = true,
		Tooltip = 'Which entities it swings at'
	})
	Range = Killaura:CreateSlider({
		Name = 'Range',
		Tooltip = 'How close an enemy must be before it swings\nYour weapon\'s own reach still applies to the hit',
		Min = 4,
		Max = 30,
		Default = 14,
		Suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})
	Angle = Killaura:CreateSlider({
		Name = 'Angle',
		Tooltip = 'How wide a cone the swing hits in\n180 hits all around you',
		Min = 1,
		Max = 180,
		Default = 180,
		Suffix = 'degrees'
	})
	Max = Killaura:CreateSlider({
		Name = 'Max Targets',
		Tooltip = 'How many enemies one swing may hit',
		Min = 1,
		Max = 6,
		Default = 3
	})
	Mouse = Killaura:CreateToggle({
		Name = 'Require Mouse',
		Tooltip = 'Only swings while you hold left click'
	})
	
end)

run(function()
	--[[
		Reach.
	
		A Tribes melee swing calls Detect(range, arc, maxTargets) to decide who it hit, and the
		list it returns is what the client sends the server - the server is told who was hit, it
		does not work it out. So adding to that range is the whole of reach here: the swings you
		already throw simply find targets a few studs further out, through the game's own path,
		with no extra packet and nothing the server did not already expect from a swing.
	
		The hook itself lives in base, shared with Killaura, so the two never fight over Detect.
	]]
	local Reach
	local Range
	local tribes = vain.Libraries.tribes
	
	Reach = vain.Categories.Combat:CreateModule({
		Name = 'Reach',
		Function = function(callback)
			if callback then
				if not tribes.hookDetect() then
					notif('Reach', 'Combat system not found yet - try again in a match', 6, 'alert')
				end
				tribes.setReach(Range.Value)
			else
				tribes.setReach(0)
			end
		end,
		Tooltip = 'Makes your melee hits reach further'
	})
	Range = Reach:CreateSlider({
		Name = 'Extra Range',
		Tooltip = 'Studs added to your weapon\'s reach',
		Min = 0,
		Max = 20,
		Default = 6,
		Decimal = 10,
		Function = function(val)
			if Reach.Enabled then
				tribes.setReach(val)
			end
		end,
		Suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})
	
end)

run(function()
	--[[
		Hitbox.
	
		Grows the hit part on enemy bodies so shots are easier to land. It helps the ranged
		weapons - bow, gun, thrown - because those hit-test against the body a projectile passes
		through, so a bigger body is a bigger thing to hit. Melee does not gain from it: a melee
		swing picks targets by distance, not by overlap, so Reach is what widens melee - this is
		its ranged counterpart.
	
		Only enemies are touched, through the same Targetable check the rest of the client uses,
		and every part is put back exactly as it was the moment the module goes off or the body
		leaves range, so nothing is left altered behind you.
	]]
	local Hitbox
	local Targets
	local Size
	
	-- part -> its real size, so it can be restored to the stud for stud. Keyed by the part so
	-- a respawned body with a fresh part is grown on its own terms.
	local original = {}
	
	local function restore(part)
		if part and original[part] then
			pcall(function()
				part.Size = original[part]
			end)
			original[part] = nil
		end
	end
	
	local function restoreAll()
		for part in original do
			restore(part)
		end
	end
	
	local function partsOf(entity)
		-- The root carries the body's position; the head is the other thing shots are aimed at.
		return {entity.RootPart, entity.Head}
	end
	
	Hitbox = vain.Categories.Blatant:CreateModule({
		Name = 'Hitbox',
		Function = function(callback)
			if callback then
				Hitbox:Clean(runService.Heartbeat:Connect(function()
					local wanted = {}
	
					for _, entity in entitylib.List do
						local allow = entity.Targetable
							and (entity.Player and Targets.Players.Enabled or (entity.NPC and Targets.NPCs.Enabled))
						if not allow then continue end
	
						for _, part in partsOf(entity) do
							if part then
								wanted[part] = true
								if not original[part] then
									original[part] = part.Size
								end
								local size = Size.Value
								part.Size = Vector3.new(size, size, size)
							end
						end
					end
	
					-- Anything grown last pass that is no longer a wanted enemy part - died,
					-- left range, changed team - is handed back its real size at once.
					for part in original do
						if not wanted[part] then
							restore(part)
						end
					end
				end))
	
				Hitbox:Clean(restoreAll)
			else
				restoreAll()
			end
		end,
		Tooltip = 'Grows enemy hitboxes so ranged shots land easier\nUse Reach for melee'
	})
	Targets = Hitbox:CreateTargets({
		Players = true,
		Tooltip = 'Whose hitboxes to grow'
	})
	Size = Hitbox:CreateSlider({
		Name = 'Size',
		Tooltip = 'How large to make each hit part',
		Min = 2,
		Max = 30,
		Default = 10,
		Suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})
	
end)

run(function()
	--[[
		Combat Logger.
	
		Tribes ships no Roblox Tools and no TouchTransmitters - its weapons are a custom combat
		system that talks to the server over its own remotes - so the universal Killaura, which
		swings a Tool and fires a Touched interest, lands nothing here. A Tribes Killaura has to
		fire the real remote instead, and the place file keeps its scripts as stripped bytecode,
		so the only way to learn that remote is to watch the live client send it.
	
		This is that watch. While it is on it hooks the one method every remote call goes
		through and prints the combat-looking ones - name, how it was called, and a readable dump
		of the arguments - once each, so a single swing of each weapon reveals exactly what to
		replay. Turn it on, hit a dummy or an enemy with each weapon, then send the console
		output and the Killaura can be built against it.
	]]
	local CombatLogger
	local Everything
	local Clear
	
	-- One line per unique remote+method, so a weapon swung fifty times is logged once rather
	-- than flooding the console. Cleared by the Clear button and on enable.
	local seen = {}
	
	-- Names worth printing. A live game fires movement and replication remotes constantly, and
	-- drowning the hit call in those is the opposite of useful, so by default only the combat
	-- ones come through. Everything turns the filter off when a weapon's remote is named
	-- something unexpected.
	local COMBAT_WORDS = {
		'hit', 'combat', 'melee', 'damage', 'attack', 'swing', 'strike',
		'axe', 'club', 'dagger', 'harpoon', 'bow', 'arrow', 'spear', 'projectile', 'throw'
	}
	
	local function interesting(name)
		if Everything.Enabled then return true end
		local lower = name:lower()
		for _, word in COMBAT_WORDS do
			if lower:find(word, 1, true) then return true end
		end
		return false
	end
	
	-- A short, readable form of one argument. The hit remote's payload is the whole point, so
	-- this spells out the things a hit carries - who, where, which part - rather than just
	-- their types.
	local function describe(value, depth)
		local kind = typeof(value)
		if kind == 'Instance' then
			return value.ClassName..'('..value.Name..')'
		elseif kind == 'Vector3' then
			return ('Vector3(%.1f, %.1f, %.1f)'):format(value.X, value.Y, value.Z)
		elseif kind == 'CFrame' then
			local p = value.Position
			return ('CFrame@(%.1f, %.1f, %.1f)'):format(p.X, p.Y, p.Z)
		elseif kind == 'table' then
			if depth and depth > 1 then return 'table' end
			local parts = {}
			for k, v in value do
				table.insert(parts, tostring(k)..'='..describe(v, (depth or 0) + 1))
				if #parts >= 8 then
					table.insert(parts, '...')
					break
				end
			end
			return '{'..table.concat(parts, ', ')..'}'
		elseif kind == 'string' then
			return '"'..value..'"'
		end
		return tostring(value)
	end
	
	local function dumpArgs(args)
		local parts = {}
		for i = 1, args.n do
			parts[i] = describe(args[i])
		end
		return table.concat(parts, ', ')
	end
	
	local function log(method, remote, args)
		local ok, name = pcall(function()
			return remote.Name
		end)
		name = ok and name or '?'
		if not interesting(name) then return end
	
		local key = method..':'..name
		if seen[key] then return end
		seen[key] = true
	
		local line = ('[Tribes] %s %s(%s)'):format(method, name, dumpArgs(args))
		print(line)
		-- Each new remote is announced, so you know the swing registered without watching the
		-- console - and the full detail is there when you go to copy it.
		notif('Combat Logger', name..' logged', 4)
	end
	
	CombatLogger = vain.Categories.Utility:CreateModule({
		Name = 'Combat Logger',
		Function = function(callback)
			if not callback then
				return
			end
			table.clear(seen)
	
			-- hookmetamethod on __namecall catches every FireServer / InvokeServer in one place,
			-- which is where a custom combat system sends its hits. The original is kept and
			-- called so the game plays normally while this watches.
			local ok = pcall(function()
				local mt = getrawmetatable(game)
				local old
				old = hookmetamethod(game, '__namecall', function(self, ...)
					local method = getnamecallmethod()
					if method == 'FireServer' or method == 'InvokeServer' then
						local args = table.pack(...)
						-- Logging must not throw into the game's call path, and must not run with
						-- the game's identity, so it is guarded and the identity is reset first.
						pcall(function()
							if vain.ThreadFix then
								setthreadidentity(8)
							end
							log(method, self, args)
						end)
					end
					return old(self, ...)
				end)
				-- Undo the hook when the module is switched off, so it does not keep logging or
				-- leave a dead hook behind.
				CombatLogger:Clean(function()
					pcall(function()
						hookmetamethod(game, '__namecall', old)
					end)
				end)
			end)
	
			if not ok then
				notif('Combat Logger', 'Could not hook remotes on this executor', 8, 'alert')
				CombatLogger:Toggle()
			else
				notif('Combat Logger', 'Watching. Hit an enemy with each weapon, then send the console output.', 10)
			end
		end,
		Tooltip = 'Prints the combat remotes the game fires'
	})
	Everything = CombatLogger:CreateToggle({
		Name = 'Log Everything',
		Tooltip = 'Logs every remote, not just combat ones'
	})
	Clear = CombatLogger:CreateButton({
		Name = 'Clear Seen',
		Tooltip = 'Logs each remote once more',
		Function = function()
			table.clear(seen)
			notif('Combat Logger', 'Cleared', 3)
		end
	})
	
end)