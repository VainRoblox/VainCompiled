local run = function(func) func() end
local cloneref = cloneref or function(obj) return obj end

local playersService = cloneref(game:GetService('Players'))
local inputService = cloneref(game:GetService('UserInputService'))
local runService = cloneref(game:GetService('RunService'))
-- Used as somewhere to park the character during a reparent, so it is never seen
-- rootless - see Godmode.
local replicatedStorage = cloneref(game:GetService('ReplicatedStorage'))
local collectionService = cloneref(game:GetService('CollectionService'))

local gameCamera = workspace.CurrentCamera
local lplr = playersService.LocalPlayer
local vain = shared.vain
local entitylib = vain.Libraries.entity
local targetinfo = vain.Libraries.targetinfo

local function notif(...)
	return vain:CreateNotification(...)
end

-- entitylib only registers players on its own - NPCs exist in its model but nothing
-- puts them there unless a game's base does it. In a dungeon crawler the enemies are
-- the entire point, so without this every module that can target NPCs has nothing to
-- work with here.
--
-- Detection is deliberately structural rather than name based: a model holding a
-- Humanoid, with health, that is not somebody's character. Matching on names would
-- need a list of every enemy type and would break with each content update.
local tracked = {}

local function isEnemy(model)
	if not model:IsA('Model') then return false end
	if playersService:GetPlayerFromCharacter(model) then return false end
	if model == lplr.Character then return false end

	local humanoid = model:FindFirstChildOfClass('Humanoid')
	if not (humanoid and humanoid.Health > 0) then return false end

	-- Humanoid.RootPart rather than a child named HumanoidRootPart: the name is a
	-- convention for player characters, and an NPC rigged any other way has a root
	-- without carrying that name. Requiring the name rejected enemies that were
	-- perfectly usable, which left nothing to farm.
	return humanoid.RootPart ~= nil
end

local function addEnemy(model)
	if tracked[model] or not isEnemy(model) then return end
	tracked[model] = true
	-- No player and no team function, so entitylib marks it NPC and targetable.
	entitylib.addEntity(model, nil, nil)
end

local function removeEnemy(model)
	if not tracked[model] then return end
	tracked[model] = nil
	entitylib.removeEntity(model)
end

run(function()
	for _, model in workspace:GetDescendants() do
		task.spawn(addEnemy, model)
	end

	vain:Clean(workspace.DescendantAdded:Connect(function(obj)
		-- A model is usually parented before its Humanoid arrives, so react to the
		-- Humanoid rather than the model and check upward from there.
		if obj:IsA('Humanoid') and obj.Parent then
			task.spawn(addEnemy, obj.Parent)
		end
	end))

	vain:Clean(workspace.DescendantRemoving:Connect(function(obj)
		if tracked[obj] then
			removeEnemy(obj)
		end
	end))

	vain:Clean(function()
		for model in tracked do
			entitylib.removeEntity(model)
		end
		table.clear(tracked)
	end)
end)

-- Shared between Godmode and AutoFarm. Godmode hides the part the game tracks you by,
-- which also stops your own attacks landing, since the server checks that same position
-- when you swing. So AutoFarm asks for the part to be put back for a moment, waits to be
-- told it has arrived, attacks, and Godmode hides it again.

-- Shared combat helpers.
--
-- These started inside AutoFarm and moved here when a second module needed them. Keeping
-- one copy matters more than it sounds: the ability keys took several attempts to get
-- right, and a duplicated set is one that quietly drifts out of step with the other.

local candidates = {}
local nextScan = 0
local nextAbility = 0
local abilityIndex = 1

local virtualInput = cloneref(game:GetService('VirtualInputManager'))

-- The game's actual ability keys, rather than a spread of guesses. The number row is
-- Roblox's backpack hotbar, so pressing those unequips the weapon rather than casting.
local ABILITY_KEYS = {
	Enum.KeyCode.Q,
	Enum.KeyCode.E
}

local HEALTH_KEYS = {'Health', 'HP', 'CurrentHealth', 'health'}

-- Finds enemies without going through entitylib.
--
-- entitylib only builds an entity when a model has a Humanoid - addEntity waits for one
-- and gives up silently without it. The boss has one, ordinary enemies here evidently do
-- not, which is exactly why the farm worked on the boss and ignored everything else. No
-- amount of widening the base's detection fixes that, because the library itself cannot
-- represent them, so this looks for them directly.
local function rootOf(model)
	if model.PrimaryPart then return model.PrimaryPart end
	for _, name in {'HumanoidRootPart', 'Torso', 'Root', 'UpperTorso', 'Head'} do
		local part = model:FindFirstChild(name)
		if part and part:IsA('BasePart') then return part end
	end
	return model:FindFirstChildWhichIsA('BasePart')
end

-- Something has to say "this is a thing with health", or every crate and door in the
-- dungeon becomes a target.
local function healthOf(model)
	local humanoid = model:FindFirstChildOfClass('Humanoid')
	if humanoid then return humanoid.Health end

	for _, key in HEALTH_KEYS do
		local attr = model:GetAttribute(key)
		if type(attr) == 'number' then return attr end

		local value = model:FindFirstChild(key)
		if value and value:IsA('ValueBase') and type(value.Value) == 'number' then
			return value.Value
		end
	end

	return nil
end

-- Distinct from isEnemy above, which decides what gets registered with entitylib and so
-- insists on a Humanoid. This one decides what is worth attacking, and most enemies here
-- have no Humanoid at all - that difference is the whole reason the farm looks for them
-- itself.
local function isFarmable(model)
	if not model:IsA('Model') then return false end
	if playersService:GetPlayerFromCharacter(model) then return false end
	if model == lplr.Character then return false end

	local health = healthOf(model)
	return health ~= nil and health > 0 and rootOf(model) ~= nil
end

-- Rebuilt on a timer rather than every pass: walking every descendant is far too much to
-- do several times a second, and enemies spawn once a room starts rather than
-- continuously, so a second-old list is fine.
local function rescan()
	if tick() < nextScan then return end
	nextScan = tick() + 1

	table.clear(candidates)
	for _, model in workspace:GetDescendants() do
		if isFarmable(model) then
			table.insert(candidates, model)
		end
	end
end

local function nearestEnemy()
	if not entitylib.isAlive then return nil end
	local origin = entitylib.character.RootPart.Position
	local best, bestRoot, bestDist

	for _, model in candidates do
		-- Re-checked rather than trusted: the list is up to a second old, and most of
		-- what is on it is in the middle of being killed.
		if model.Parent and isFarmable(model) then
			local root = rootOf(model)
			if root then
				local dist = (root.Position - origin).Magnitude
				if not bestDist or dist < bestDist then
					best, bestRoot, bestDist = model, root, dist
				end
			end
		end
	end

	return best, bestRoot
end

-- Nothing swings without something equipped, whatever the weapon is.
local function equipWeapon()
	local character = lplr.Character
	if not character then return end
	if character:FindFirstChildOfClass('Tool') then return end

	local backpack = lplr:FindFirstChildOfClass('Backpack')
	local spare = backpack and backpack:FindFirstChildOfClass('Tool')
	local humanoid = character:FindFirstChildOfClass('Humanoid')
	if spare and humanoid then
		pcall(function()
			humanoid:EquipTool(spare)
		end)
	end
end

local function swing()
	local centre = gameCamera.ViewportSize / 2
	pcall(function()
		virtualInput:SendMouseButtonEvent(centre.X, centre.Y, 0, true, game, 1)
		task.wait()
		virtualInput:SendMouseButtonEvent(centre.X, centre.Y, 0, false, game, 1)
	end)
end

-- Still one key per pass rather than both at once: a game will generally drop all but the
-- first of a burst. With only two keys each comes round twice a second, which is faster
-- than either cooldown, so nothing is held up waiting its turn.
-- Pressed every pass, with no rate limit of its own.
--
-- There is no reading a cooldown from here, but there is no need to: pressing an ability
-- that is still cooling does nothing at all. So the way to cast the moment one comes back
-- is simply to keep asking, and the old quarter second gate only meant an ability could
-- sit ready for a quarter second doing nothing.
--
-- The two keys are still separated by a frame rather than sent together, because a game
-- will generally act on the first of a burst and drop the rest.
local function useAbility()
	for _, key in ABILITY_KEYS do
		pcall(function()
			virtualInput:SendKeyEvent(true, key, false, game)
			task.wait()
			virtualInput:SendKeyEvent(false, key, false, game)
		end)
	end
end


-- Re-exported so the modules can share one implementation of each.
vain.Libraries.dungeonquest = {
	isEnemy = isEnemy,
	isFarmable = isFarmable,
	tracked = tracked,
	equipWeapon = equipWeapon,
	swing = swing,
	useAbility = useAbility,
	findEnemy = nearestEnemy,
	rescan = rescan,
	rootOf = rootOf,
	combat = {
		hidden = false,
		-- Set by AutoFarm when it wants to attack.
		wantAttack = 0,
		-- Set by Godmode once the surfaced position has had time to replicate.
		attackReady = false,
		-- Set by AutoFarm the moment it sees something on course to hit you, so Godmode
		-- can hide before it lands rather than after. AutoFarm already works this out for
		-- dodging, so it costs nothing to share.
		threat = 0
	}
}


run(function()
	local AutoFarm
	local warned = false
	local nextAbility = 0
	local abilityIndex = 1
	local candidates = {}
	local nextScan = 0
	local incoming = {}
	local currentRoot
	local autoRotate
	
	-- Dodging.
	--
	-- What counts as a projectile here is not something that can be looked up, so it is
	-- recognised by behaviour instead: a loose part, not part of anybody's body, travelling
	-- fast enough that it was fired rather than dropped. Anything matching is watched
	-- briefly then forgotten, since projectiles do not live long and a stale list is worse
	-- than none.
	local PROJECTILE_SPEED = 25
	local WATCH_FOR = 3
	-- How close it has to be heading, and how far ahead to care. Reacting to everything on
	-- the map would have you sidestepping shots that were never going to land.
	local DODGE_RADIUS = 10
	local LOOK_AHEAD = 1.5
	local DODGE_DISTANCE = 14
	
	-- Where to sit relative to the enemy.
	--
	-- Overhead, and high enough that ground melee cannot reach you - being hit back was
	-- killing runs. An earlier version blamed height for swings not landing, but attacks
	-- were going through tool:Activate then, which does nothing in this game at all; height
	-- was never why they missed. Now that a swing is a real click at the crosshair the limit
	-- is the weapon's own range, so height is free and worth taking.
	local STAND_OFF = 2
	-- Just inside melee reach. Higher was out of range of your own swings, and height is not
	-- what keeps you alive anyway - Godmode is, by moving the part you are hit through.
	--
	-- WeaponReach stretches the weapon's own hit check, so with that on there is room to
	-- stand further off. It is left short here regardless, because this has to work whether
	-- that module is on or not, and standing close costs nothing when it is.
	local STAND_UP = 7
	
	-- Attacking through tool:Activate and firetouchinterest does nothing here. That works in
	-- games whose damage comes off a touch or off the tool itself; this one runs combat
	-- through its own input handlers, which fire its own remotes. Simulating the input lets
	-- the game's own code do the rest, and whatever validation it applies is satisfied
	-- because these are its own attacks.
	local virtualInput = cloneref(game:GetService('VirtualInputManager'))
	
	-- The game's actual ability keys, rather than a spread of guesses.
	--
	-- Two earlier versions cycled a broad set hoping to land on the right ones. The number
	-- row turned out to be Roblox's backpack hotbar, so those presses were unequipping the
	-- weapon rather than casting, and the letters after that were no better than a guess.
	-- Pressing only what is bound means nothing is wasted and nothing has a side effect.
	local ABILITY_KEYS = {
		Enum.KeyCode.Q,
		Enum.KeyCode.E
	}
	
	-- The scan, the swing, the abilities and the equip check all live in the base now, so
	-- AutoKill shares one copy of each rather than carrying its own that drifts.
	local dq = vain.Libraries.dungeonquest
	
	AutoFarm = vain.Categories.Blatant:CreateModule({
		Name = 'AutoFarm',
		Function = function(callback)
			if callback then
				warned = false
				nextAbility = 0
				nextScan = 0
				table.clear(candidates)
				table.clear(incoming)
				AutoFarm:Clean(watchProjectiles())
	
				-- Aim is held every frame, not once per pass.
				--
				-- Setting it on the 0.15s loop left the character free to turn in between,
				-- because the humanoid rotates itself toward wherever it thinks you are
				-- heading - so swings kept going out while facing somewhere else. AutoRotate
				-- is switched off for the same reason, and put back when the module stops.
				AutoFarm:Clean(runService.PostSimulation:Connect(function()
					if not (currentRoot and currentRoot.Parent and entitylib.isAlive) then return end
	
					local me = entitylib.character.RootPart
					local targetPos = currentRoot.Position
					-- Aimed at the target itself, pitch included, rather than at a point level
					-- with you. Flattening it to the horizontal meant that standing above an
					-- enemy you faced its direction but never looked down at it, so swings
					-- went out over its head.
					me.CFrame = CFrame.new(me.CFrame.Position, targetPos)
					pcall(function()
						gameCamera.CFrame = CFrame.new(gameCamera.CFrame.Position, targetPos)
					end)
				end))
	
				AutoFarm:Clean(function()
					currentRoot = nil
					local character = lplr.Character
					local humanoid = character and character:FindFirstChildOfClass('Humanoid')
					if humanoid and autoRotate ~= nil then
						humanoid.AutoRotate = autoRotate
					end
				end)
	
				task.spawn(function()
					repeat
						-- Guarded, yielding outside, so one bad pass cannot spin or end the
						-- farm for the session.
						local ok = pcall(function()
							if not entitylib.isAlive then return end
	
							dq.rescan()
							local enemy, root = dq.findEnemy()
	
							-- Deliberately does nothing when there is nothing to do. An
							-- earlier version returned you to where you switched it on, every
							-- tenth of a second, which pinned you in place whenever nothing
							-- was found. Enemies also only appear once a room starts, so
							-- finding none early on is normal rather than a fault.
							if not enemy then
								currentRoot = nil
								if not warned then
									warned = true
									notif('AutoFarm', 'Waiting for enemies to spawn.', 6, 'info')
								end
								return
							end
	
							warned = false
							dq.equipWeapon()
	
							local me = entitylib.character.RootPart
							local targetPos = root.Position
	
							-- Approached from whichever side you are already on, so it does
							-- not drag you through the target every pass.
							local away = me.Position - targetPos
							away = Vector3.new(away.X, 0, away.Z)
							if away.Magnitude < 0.1 then
								local back = me.CFrame.LookVector * -1
								away = Vector3.new(back.X, 0, back.Z)
							end
	
							local spot = targetPos + (away.Unit * STAND_OFF) + Vector3.new(0, STAND_UP, 0)
	
							-- Stepped aside before being placed, rather than moved after, so
							-- the dodge is not immediately undone by the next pass putting
							-- you back over the enemy.
							local dodge = dodgeDirection(me.Position)
							if dodge then
								spot += dodge * DODGE_DISTANCE
							end
	
							currentRoot = root
	
							local humanoid = entitylib.character.Humanoid
							if humanoid then
								if autoRotate == nil then
									autoRotate = humanoid.AutoRotate
								end
								humanoid.AutoRotate = false
							end
	
							me.CFrame = CFrame.new(spot, targetPos)
							-- Zeroed so hovering above the floor does not turn into a fall.
							me.AssemblyLinearVelocity = Vector3.zero
	
							-- The camera has to point at the enemy too, not just the
							-- character. A swing is a click at the centre of the screen, so
							-- it hits whatever the camera is looking at - aiming the body
							-- alone left the crosshair wherever the camera happened to be.
							pcall(function()
								gameCamera.CFrame = CFrame.new(gameCamera.CFrame.Position, targetPos)
							end)
	
							-- Godmode hides the part the server identifies you by, and it
							-- checks that same position when you swing - so attacking while
							-- hidden is rejected. Ask for it back, wait to be told it has
							-- arrived, then attack. When Godmode is off there is nothing to
							-- wait for and this is skipped entirely.
							local combat = dq.combat
							if combat.hidden then
								combat.wantAttack = tick()
								if not combat.attackReady then return end
							end
	
							dq.swing()
							dq.useAbility()
						end)
	
						task.wait(ok and 0.15 or 0.4)
					until not AutoFarm.Enabled
				end)
			end
		end,
		Tooltip = 'Stands next to the nearest enemy, swings whatever is equipped and cycles abilities'
	})
	
end)

run(function()
	local AutoRestart
	local nextPress = 0
	
	-- Rather than trying to work out when a run has ended - which would mean knowing how
	-- this game tracks its own state - this watches for the button that offers the restart.
	-- That button is only on screen once the dungeon is over, whether it was cleared or
	-- everybody died, so its appearing is the signal. No knowledge of the game's internals
	-- is needed, and it cannot fire mid-run because the button is not there to find.
	-- Whole phrases only.
	--
	-- 'play' and 'again' were in here on their own, and since the search also looks at the
	-- labels inside a button, those matched almost any interface carrying the word - Play,
	-- Replay, PlayerList - and fired a restart in the middle of a run.
	local RESTART_WORDS = {
		'restart', 'play again', 'try again', 'start over', 'new run', 'next run', 'replay', 'requeue'
	}
	
	local virtualInput = cloneref(game:GetService('VirtualInputManager'))
	
	-- A run is over when everyone is dead, or when the final boss has been beaten. A restart
	-- button being on screen is not that: it turned out to be visible at other times too, so
	-- pressing on sight restarted runs that were still going.
	--
	-- Both conditions are only meaningful once a run has actually started, which is what
	-- seeing enemies establishes - otherwise sitting in the lobby, where nobody has a
	-- character and there is nothing to fight, reads as a finished run.
	local CLEARED_FOR = 3
	local sawEnemies = false
	local emptySince = 0
	
	local function everyoneDead()
		local anyAlive = false
		for _, player in playersService:GetPlayers() do
			local character = player.Character
			local humanoid = character and character:FindFirstChildOfClass('Humanoid')
			if humanoid and humanoid.Health > 0 then
				anyAlive = true
				break
			end
		end
		return not anyAlive
	end
	
	local function runOver()
		local dq = vain.Libraries.dungeonquest
		dq.rescan()
		local enemy = dq.findEnemy()
	
		if enemy then
			sawEnemies = true
			emptySince = 0
			-- Enemies are up, so whatever is on screen, this run is still going.
			return false
		end
	
		if not sawEnemies then return false end
	
		if everyoneDead() then return true end
	
		-- Nothing left to fight for a few seconds running: the boss is down. Held for a
		-- moment rather than acted on instantly, since a gap between waves also looks empty.
		if emptySince == 0 then
			emptySince = tick()
		end
		return (tick() - emptySince) >= CLEARED_FOR
	end
	
	-- The game keeps its own remote for this, under ReplicatedStorage.remotes, so the
	-- restart can be asked for directly instead of being mimed through the interface.
	-- Hunting for a button meant guessing at its label, and a guess that is close but wrong
	-- looks exactly like the module being broken.
	--
	-- The button is still used as a fallback: firing the remote is only right once a run has
	-- actually ended, and the button appearing is what says so.
	local function startRemote()
		local remotes = replicatedStorage:FindFirstChild('remotes')
		local remote = remotes and remotes:FindFirstChild('startDungeon')
		if not remote then return false end
	
		local ok = pcall(function()
			if remote:IsA('RemoteFunction') then
				remote:InvokeServer()
			else
				remote:FireServer()
			end
		end)
		return ok
	end
	
	-- A button is only really on screen if every frame above it is visible too, so this
	-- walks up rather than trusting the button's own Visible.
	local function onScreen(object)
		local current = object
		while current and current ~= lplr.PlayerGui do
			if current:IsA('GuiObject') and not current.Visible then return false end
			if current:IsA('ScreenGui') and not current.Enabled then return false end
			current = current.Parent
		end
		return true
	end
	
	local function matches(text)
		if not text or text == '' then return false end
		text = text:lower()
		for _, word in RESTART_WORDS do
			if text:find(word, 1, true) then return true end
		end
		return false
	end
	
	-- Checks the labels inside the button as well as the button itself.
	--
	-- A Roblox button usually carries no text of its own - the wording sits on a TextLabel
	-- parented inside it - so matching only the button's own Text and Name found nothing at
	-- all here, however right the word list was.
	local function looksLikeRestart(button)
		if matches(button.Name) then return true end
		if button:IsA('TextButton') and matches(button.Text) then return true end
	
		for _, child in button:GetDescendants() do
			if child:IsA('TextLabel') and matches(child.Text) then return true end
			if child:IsA('TextButton') and matches(child.Text) then return true end
		end
		return false
	end
	
	local function findRestartButton()
		local gui = lplr:FindFirstChildOfClass('PlayerGui')
		if not gui then return nil end
	
		for _, object in gui:GetDescendants() do
			if object:IsA('GuiButton') and looksLikeRestart(object) and onScreen(object) then
				-- Zero sized buttons are usually templates parked off to one side rather
				-- than anything a player could press.
				if object.AbsoluteSize.X > 0 and object.AbsoluteSize.Y > 0 then
					return object
				end
			end
		end
		return nil
	end
	
	local function press(button)
		-- The button's own handlers first: that is the same path a real press takes, and it
		-- does not care where the button sits on screen.
		local fired = false
		if getconnections then
			for _, signal in {button.Activated, button.MouseButton1Click} do
				local ok, connections = pcall(getconnections, signal)
				if ok and connections then
					for _, connection in connections do
						pcall(function()
							connection:Fire()
						end)
						fired = true
					end
				end
			end
		end
		if fired then return end
	
		-- Otherwise click where it actually is, which works whatever the button is wired to.
		local centre = button.AbsolutePosition + (button.AbsoluteSize / 2)
		pcall(function()
			virtualInput:SendMouseButtonEvent(centre.X, centre.Y, 0, true, game, 1)
			task.wait()
			virtualInput:SendMouseButtonEvent(centre.X, centre.Y, 0, false, game, 1)
		end)
	end
	
	AutoRestart = vain.Categories.Blatant:CreateModule({
		Name = 'AutoRestart',
		Function = function(callback)
			if callback then
				nextPress = 0
	
				task.spawn(function()
					repeat
						local ok = pcall(function()
							-- Spaced out so a screen that takes a moment to change is not
							-- pressed repeatedly - on a menu that reuses the same button that
							-- can end up undoing itself.
							if tick() < nextPress then return end
	
							-- The gate, not the button. A button appearing is not proof a run
							-- has ended, and acting on it alone restarted runs mid fight.
							if not runOver() then return end
	
							local button = findRestartButton()
	
							nextPress = tick() + 3
	
							-- Both: the remote is the reliable half, the press covers a build
							-- where the remote is named something else or expects arguments
							-- this does not send.
							local viaRemote = startRemote()
							-- The button is optional now: the remote is the reliable path, and
							-- a build that names it differently still has the button to fall
							-- back on.
							if button then
								press(button)
							end
	
							if viaRemote or button then
								sawEnemies = false
								emptySince = 0
								notif('AutoRestart', 'Dungeon over - starting again.', 4, 'info')
							end
						end)
	
						task.wait(ok and 0.5 or 1)
					until not AutoRestart.Enabled
				end)
			end
		end,
		Tooltip = 'Starts the dungeon over once it has ended, whether it was cleared or everyone died'
	})
	
end)

run(function()
	local Godmode
	local oldroot, clone, hip
	local hidden = false
	local warned = false
	
	-- Where to keep the detached root. Far enough that nothing in the room reaches it, and
	-- upward rather than downward - dropping it under the map risks whatever kill plane the
	-- dungeon has.
	local HIDE_OFFSET = Vector3.new(0, 2000, 0)
	
	-- Hiding the part also stops your own attacks landing, because the server checks that
	-- same position when you swing. So AutoFarm asks for it back for a moment, and it goes
	-- straight up again once the swing is away.
	--
	-- Moving a loose part is all this takes - no reparenting, which is the slow and fragile
	-- part - so surfacing costs a frame rather than a rebuild of the character.
	local combat = vain.Libraries.dungeonquest.combat
	
	-- Long enough for the surfaced position to reach the server before the attack does.
	-- Without this the swing goes out while the server still has you two thousand studs up
	-- and is rejected, which is the whole problem this is meant to solve.
	local SETTLE = 0.25
	
	-- How long a request stays live, so one that never becomes a swing cannot hold you out
	-- in the open indefinitely.
	local REQUEST_TIMEOUT = 0.6
	local surfacedAt = 0
	-- Counted so it is possible to tell an attack window never opening apart from one
	-- opening and the swing still doing nothing.
	local windowCount = 0
	
	-- Reactive rather than permanent.
	--
	-- Hiding all the time means every swing of yours has to buy a window first, and each of
	-- those windows is a moment you can be hit anyway. Staying out in the open and hiding the
	-- instant something actually hurts you costs one hit and covers everything after it,
	-- which is what a burst of damage from a pack of enemies actually looks like.
	--
	-- Health dropping is the one signal for this that needs no knowledge of the game: it is
	-- true whatever hit you, melee, ranged or otherwise.
	-- Hidden by default, which is the only arrangement that actually prevents hits.
	--
	-- Two reactive versions came before this and both were wrong. Hiding once health drops
	-- means always taking the hit that triggers it. Hiding on anything moving quickly nearby
	-- meant hiding almost permanently, because a dungeon is full of fast moving effect parts
	-- and debris - and since being hidden also blocks your own attacks, that is why the tool
	-- stopped landing. Neither reacted quickly enough to be worth what it cost.
	--
	-- So it stays hidden and surfaces only for the instant of your own swing.
	
	-- Damage aimed at you is worked out from where the server thinks you are, and where the
	-- server thinks you are comes from the part it identifies you by - which is yours to
	-- move, since you own your own character.
	--
	-- So the real root is taken out of the character and left in the workspace as a loose
	-- part, with a clone put in its place as the PrimaryPart. Your character, camera and
	-- movement all run on the clone and behave normally, while the part the game actually
	-- tracks sits far above the map where nothing can reach it. This is the same approach
	-- that works in bedwars.
	--
	-- It is not literal invulnerability: anything that damages you without checking position
	-- at all - a script that hits everyone in the room, a scripted death - goes straight
	-- through it.
	local function hide()
		if oldroot and oldroot.Parent then return true end
		if not entitylib.isAlive then return false end
	
		local character = lplr.Character
		if not (character and character.Parent) then return false end
	
		local ok = pcall(function()
			local humanoid = character:FindFirstChildOfClass('Humanoid')
			hip = humanoid and humanoid.HipHeight
			oldroot = entitylib.character.RootPart
	
			-- Moved out of the workspace for the swap so the character is never seen
			-- rootless, which breaks the humanoid outright.
			character.Parent = replicatedStorage
			clone = oldroot:Clone()
			clone.Parent = character
			oldroot.Transparency = 1
			oldroot.Parent = workspace
			character.PrimaryPart = clone
			character.Parent = workspace
	
			-- entitylib caches the root instance and everything else reads position from it.
			-- Left pointing at the detached part, AutoFarm would be working from a point two
			-- thousand studs up.
			entitylib.character.RootPart = clone
			entitylib.character.HumanoidRootPart = clone
		end)
	
		if not ok then
			oldroot, clone = nil, nil
			return false
		end
		return true
	end
	
	local function restore()
		if not (oldroot and oldroot.Parent) then
			oldroot, clone = nil, nil
			return
		end
	
		pcall(function()
			local character = lplr.Character
			if character and character.Parent then
				character.Parent = replicatedStorage
				oldroot.Parent = character
				if clone then
					oldroot.CFrame = clone.CFrame
					oldroot.Velocity = clone.Velocity
					clone:Destroy()
				end
				character.PrimaryPart = oldroot
				character.Parent = workspace
			end
	
			oldroot.CanCollide = true
			oldroot.Transparency = 1
	
			if entitylib.isAlive then
				entitylib.character.RootPart = oldroot
				entitylib.character.HumanoidRootPart = oldroot
				local humanoid = lplr.Character and lplr.Character:FindFirstChildOfClass('Humanoid')
				if humanoid and hip then
					humanoid.HipHeight = hip
				end
			end
		end)
	
		oldroot, clone = nil, nil
		hidden = false
		surfacedAt = 0
		-- Cleared so AutoFarm stops waiting on a window nothing is producing any more.
		combat.hidden = false
		combat.attackReady = false
	end
	
	Godmode = vain.Categories.Blatant:CreateModule({
		Name = 'Godmode',
		Function = function(callback)
			if callback then
				hidden = false
				warned = false
	
				-- Held in place every frame, because a loose part left alone simply falls.
				Godmode:Clean(runService.PostSimulation:Connect(function()
					if not (oldroot and oldroot.Parent and clone and clone.Parent) then return end
					oldroot.AssemblyLinearVelocity = Vector3.zero
	
					local wants = (tick() - (combat.wantAttack or 0)) < REQUEST_TIMEOUT
	
					if wants then
						if surfacedAt == 0 then
							surfacedAt = tick()
							windowCount += 1
						end
						-- Back where you actually are, so the swing is validated against a
						-- position that matches the enemy you are stood next to.
						oldroot.CFrame = clone.CFrame
						combat.attackReady = (tick() - surfacedAt) >= SETTLE
					else
						surfacedAt = 0
						combat.attackReady = false
						oldroot.CFrame = CFrame.new(clone.CFrame.Position + HIDE_OFFSET)
					end
				end))
	
				Godmode:Clean(entitylib.Events.LocalRemoved:Connect(restore))
	
				task.spawn(function()
					task.wait(12)
					if Godmode.Enabled and hidden then
						notif('Godmode', 'Hidden ok. Attack windows opened so far: ' .. windowCount .. '. Zero means AutoFarm never asked; a number with no damage means the swing is rejected anyway.', 12, 'info')
					end
				end)
	
				task.spawn(function()
					repeat
						local ok = pcall(function()
							if not entitylib.isAlive then
								restore()
								return
							end
	
							local ok = hide()
							if not ok then
								-- Said out loud rather than silently retried. The reparent can
								-- fail outright, and a silent failure here is indistinguishable
								-- from the technique simply not working on this game - which is
								-- the difference between a bug worth fixing and an approach
								-- worth abandoning.
								if not warned then
									warned = true
									notif('Godmode', 'Could not detach the root - this game will not allow the swap, so this module cannot work here.', 12, 'alert')
								end
								return
							end
	
							if not hidden then
								hidden = true
								combat.hidden = true
								if not warned then
									warned = true
									notif('Godmode', 'Hidden. Anything that damages you without checking where you are still applies.', 8, 'info')
								end
							end
						end)
	
						task.wait(ok and 0.2 or 0.5)
					until not Godmode.Enabled
	
					restore()
				end)
			else
				restore()
			end
		end,
		Tooltip = 'Moves the part the game hits you by out of reach the moment something damages you, then brings it back'
	})
	
end)

run(function()
	local WeaponReach
	local oldnamecall
	
	-- How far a swing should reach once extended, and how close to you a check has to start
	-- before it is treated as yours.
	local REACH = 60
	local ORIGIN_RADIUS = 12
	-- Only short checks are stretched. A long one is the game doing something else - line of
	-- sight, a camera check, a projectile - and lengthening those breaks more than it helps.
	local MELEE_LIMIT = 40
	
	-- Extends the hit check the weapon performs, rather than the weapon itself.
	--
	-- There is no reading this game's weapon code from here, so instead of guessing at its
	-- internals this works on what any melee hit check has to do regardless of how it is
	-- written: cast from about where you are, over a short distance. Anything matching that
	-- shape gets stretched, and everything else is passed through untouched.
	--
	-- If the hit is decided on the server, none of this reaches it - the client's own check
	-- is then only for show, and extending it changes nothing. That is the case this cannot
	-- cover and cannot detect from the outside.
	local function nearMe(position)
		if not entitylib.isAlive then return false end
		return (position - entitylib.character.RootPart.Position).Magnitude <= ORIGIN_RADIUS
	end
	
	WeaponReach = vain.Categories.Blatant:CreateModule({
		Name = 'WeaponReach',
		Function = function(callback)
			if callback then
				if not (hookmetamethod and getnamecallmethod) then
					notif('WeaponReach', 'Your executor cannot hook namecalls, so this cannot work here.', 10, 'alert')
					return
				end
	
				oldnamecall = hookmetamethod(game, '__namecall', function(...)
					local method = getnamecallmethod()
	
					-- Left alone unless it is a spatial query, and never for calls this
					-- client makes itself - that would catch Vain's own raycasts.
					if checkcaller() or (method ~= 'Raycast' and method ~= 'GetPartBoundsInRadius') then
						return oldnamecall(...)
					end
	
					local self, args = ..., {select(2, ...)}
	
					if method == 'Raycast' then
						local origin, direction = args[1], args[2]
						if typeof(origin) == 'Vector3' and typeof(direction) == 'Vector3'
							and direction.Magnitude <= MELEE_LIMIT and nearMe(origin) then
							-- Same direction, longer. Changing the direction as well would
							-- aim it somewhere the game did not intend.
							args[2] = direction.Unit * REACH
							return oldnamecall(self, unpack(args))
						end
					elseif method == 'GetPartBoundsInRadius' then
						local position, radius = args[1], args[2]
						if typeof(position) == 'Vector3' and type(radius) == 'number'
							and radius <= MELEE_LIMIT and nearMe(position) then
							args[2] = REACH
							return oldnamecall(self, unpack(args))
						end
					end
	
					return oldnamecall(...)
				end)
	
				WeaponReach:Clean(function()
					if oldnamecall and hookmetamethod then
						-- Put back by re-hooking with the original, since there is no
						-- unhook - leaving ours in place would keep stretching after the
						-- module is off.
						pcall(hookmetamethod, game, '__namecall', oldnamecall)
						oldnamecall = nil
					end
				end)
			end
		end,
		Tooltip = 'Stretches the hit check your weapon performs, so swings connect from further away'
	})
	
end)