--[[
	Dungeon Quest, ported from the VainV6 client.

	This replaces an earlier implementation here that was written without access to the
	game's internals and guessed at most of them. Everything below is built on paths
	verified against the place dump, and the difference is not stylistic:

	  - enemies are models under an 'enemyFolder', not "anything with health"
	  - being in a dungeon is lplr.peaceful being false, not "enemies are visible"
	  - a swing is the equipped weapon Accessory's RemoteEvent plus remotes.weaponUsed,
	    not a simulated mouse click
	  - abilities carry a real cooldown value, so they can be cast the moment it clears
	    rather than by pressing keys and hoping
	  - a run is over at workspace.dungeonProgress == 'bossKilled' or
	    dungeon.bossRoom.dungeonFinished, by that exact path
	  - boss attacks are telegraphed over a BridgeNet2 'precastHitbox' bridge, so they
	    can be stepped out of before they land, for every boss, without naming any

	The helpers are re-exported at the end for the modules that stayed - AutoKill,
	Godmode and WeaponReach - so there is one implementation of each.
]]

-- Dungeon Quest (universe 9931749389) — Vain modules.
-- Remotes verified from the place dump: ReplicatedStorage.remotes.*
-- Combat: weapon Accessory RemoteEvent + weaponUsed; abilities via abilityUsed(slot, child).

local run = function(func)
	local ok, err = pcall(func)
	if not ok then
		local vain = shared.vain
		if vain and vain.CreateNotification then
			vain:CreateNotification('Vain DQ', 'Module failed to load: ' .. tostring(err), 5, 'alert')
		end
	end
end

local cloneref = cloneref or function(o) return o end
local playersService = cloneref(game:GetService('Players'))
local replicatedStorage = cloneref(game:GetService('ReplicatedStorage'))
local runService = cloneref(game:GetService('RunService'))
local httpService = cloneref(game:GetService('HttpService'))
local lplr = playersService.LocalPlayer
local vain = shared.vain

-- Guarded remote lookup so a missing/renamed remote can never error a module.
local remotesFolder = replicatedStorage:FindFirstChild('remotes')
if not remotesFolder then
	pcall(function() remotesFolder = replicatedStorage:WaitForChild('remotes', 10) end)
end
local function remote(name)
	return remotesFolder and remotesFolder:FindFirstChild(name)
end

-- True only while actually inside a dungeon (not town/lobby, not mid-cast).
local function inCombat()
	local char = lplr.Character
	local peaceful = lplr:FindFirstChild('peaceful')
	if not (char and peaceful and peaceful.Value == false) then return false, char end
	local busy = char:FindFirstChild('busyCasting')
	if busy and busy.Value ~= false then return false, char end
	return true, char
end

-- Shared enemy targeting: nearest live mob under an 'enemyFolder' (cached), plus a
-- helper to turn the character to face it. DQ weapon swings and abilities fire in
-- the character's LOOK direction, so facing the enemy is what makes them connect.
local _enemyParts, _enemyScan = {}, 0

--[[
	Read from the enemy folders, not from the whole workspace.

	Walking every descendant of the workspace once a second is cheap in an empty lobby and
	ruinous by the end of a dungeon: the rooms stream in as the run goes on, so the same
	loop is a few thousand instances at the start and a hundred thousand at the boss. That
	is lag that arrives gradually and has nothing to do with what the module is doing.

	Every enemy sits under a folder called enemyFolder, one per room, so those are found
	once and only their contents are read.
]]
local _enemyFolders, _enemyFolderScan = {}, 0

local function enemyFolders()
	if os.clock() - _enemyFolderScan < 4 and #_enemyFolders > 0 then return _enemyFolders end
	_enemyFolderScan = os.clock()

	local found = {}
	local function collect(root, depth)
		if not root or depth > 2 then return end
		for _, child in root:GetChildren() do
			if child.Name == 'enemyFolder' then
				table.insert(found, child)
			elseif child:IsA('Folder') or child:IsA('Model') then
				collect(child, depth + 1)
			end
		end
	end

	collect(workspace:FindFirstChild('dungeon'), 1)
	for _, child in workspace:GetChildren() do
		if child.Name == 'enemyFolder' then table.insert(found, child) end
	end

	_enemyFolders = found
	return _enemyFolders
end

local function scanEnemyParts()
	_enemyParts = {}
	pcall(function()
		for _, folder in enemyFolders() do
			if folder.Parent then
				for _, d in folder:GetDescendants() do
					if d:IsA('Humanoid') and d.Health > 0 then
						local m = d.Parent
						if m and m:IsA('Model') and not playersService:GetPlayerFromCharacter(m) then
							local part = m.PrimaryPart or m:FindFirstChild('HumanoidRootPart') or m:FindFirstChildWhichIsA('BasePart')
							if part then table.insert(_enemyParts, part) end
						end
					end
				end
			end
		end
	end)
	_enemyScan = os.clock()
end
local function nearestEnemyPart(pos)
	if os.clock() - _enemyScan > 1 or #_enemyParts == 0 then scanEnemyParts() end
	local best, bestDist
	for i = #_enemyParts, 1, -1 do
		local part = _enemyParts[i]
		if not (part and part.Parent) then
			table.remove(_enemyParts, i)
		else
			local dist = (part.Position - pos).Magnitude
			if not bestDist or dist < bestDist then best, bestDist = part, dist end
		end
	end
	return best
end
-- rotate the character to face the nearest enemy (horizontal), staying in place.
local function faceNearest()
	local char = lplr.Character
	local hrp = char and char:FindFirstChild('HumanoidRootPart')
	if not hrp then return end
	local part = nearestEnemyPart(hrp.Position)
	if part and (part.Position - hrp.Position).Magnitude > 0.5 then
		-- horizontal only: a Humanoid is force-kept upright, so PITCHING the RootPart
		-- just makes it fight our CFrame every frame (the Y-axis jitter). Keep it level.
		hrp.CFrame = CFrame.lookAt(hrp.Position, Vector3.new(part.Position.X, hrp.Position.Y, part.Position.Z))
	end
end

-- Incoming projectiles.
--
-- The precastHitbox bridge carries every boss's telegraphed AREA attack, which is why
-- dodging works for all of them without naming a single one - there is exactly one such
-- bridge in the place, so there is no per-boss channel to hook even if it were wanted.
-- What it does not carry is anything thrown: a projectile is just a part in flight.
--
-- So those are recognised by behaviour instead - a loose part, not part of anybody's
-- body, moving fast enough to have been fired rather than dropped - and watched from the
-- moment they appear, since one is in the air for a fraction of a second and anything
-- rebuilt on a timer would miss it.
local _incoming = {}
local PROJECTILE_SPEED = 25
local PROJECTILE_WATCH = 3
local PROJECTILE_RADIUS = 10
local PROJECTILE_LOOKAHEAD = 1.5
local PROJECTILE_STEP = 14
local _projectileHook
local _projectileSampler

--[[
	How fast a projectile is going, worked out by watching it rather than asking it.

	Nearly everything this game throws is moved with TweenService - there are hundreds of
	uses of it against a handful of the physics movers - and a tweened part reports an
	AssemblyLinearVelocity of zero however fast it is crossing the room. Reading that
	property was therefore rejecting every ranged attack in the game before it was ever
	considered, which is why none of them were dodged.

	Two positions a frame apart give the real answer whatever moved the part, so that is
	what is kept. The engine's own value is still preferred when it is not zero, since a
	genuinely physics-driven shot reports it exactly and for free.
]]
local function watchProjectiles()
	if _projectileHook then return end

	_projectileHook = workspace.DescendantAdded:Connect(function(object)
		if not object:IsA('BasePart') then return end
		-- Bodies are made of fast moving parts too, whenever their owner is running.
		local model = object:FindFirstAncestorWhichIsA('Model')
		if model and model:FindFirstChildOfClass('Humanoid') then return end
		_incoming[object] = {expiry = os.clock() + PROJECTILE_WATCH, pos = object.Position, at = os.clock()}
	end)

	-- Sampled every frame rather than once per farm tick: a shot is only in the air for
	-- a moment, and a tenth of a second between readings is most of its flight.
	_projectileSampler = runService.Heartbeat:Connect(function()
		local now = os.clock()
		for part, track in _incoming do
			if now > track.expiry or not part.Parent then
				_incoming[part] = nil
				continue
			end

			local position = part.Position
			local elapsed = now - track.at
			if elapsed > 0 then
				track.velocity = (position - track.pos) / elapsed
			end
			track.pos, track.at = position, now
		end
	end)
end

-- Where to step to get out of the way, or nil if nothing is actually coming at you.
--
-- Judged on the closest the thing will ever get on its current course rather than how far
-- away it is now, so a shot passing wide is ignored and only one genuinely heading at you
-- moves you.
local function projectileDodge(pos)
	for part, track in _incoming do
		if os.clock() > track.expiry or not part.Parent then
			_incoming[part] = nil
			continue
		end

		local velocity = part.AssemblyLinearVelocity
		if velocity.Magnitude < 1 then
			velocity = track.velocity or Vector3.zero
		end
		if velocity.Magnitude < PROJECTILE_SPEED then continue end

		local relative = part.Position - pos
		local closing = relative:Dot(velocity)
		-- Positive means it is already moving away.
		if closing >= 0 then continue end

		local time = -closing / velocity:Dot(velocity)
		if time > PROJECTILE_LOOKAHEAD then continue end
		if (relative + (velocity * time)).Magnitude > PROJECTILE_RADIUS then continue end

		-- Sideways relative to its travel, which is the shortest way out of its path.
		local sideways = Vector3.new(-velocity.Z, 0, velocity.X)
		if sideways.Magnitude < 0.1 then continue end
		return pos + (sideways.Unit * PROJECTILE_STEP)
	end
	return nil
end

-- A simple toggle that fires a no-arg remote on a loop (server ignores it when
-- the action isn't valid, so this is safe to leave running).
local function looper(category, name, tooltip, remoteName, interval, gate)
	run(function()
		local Module
		Module = category:CreateModule({
			Name = name,
			Tooltip = tooltip,
			Function = function(callback)
				if not callback then return end
				repeat
					pcall(function()
						if gate and not gate() then return end
						local r = remote(remoteName)
						if r then r:FireServer() end
					end)
					task.wait(interval)
				until not Module.Enabled
			end,
		})
	end)
end

-- ── Auto Attack ──────────────────────────────────────────────────────────────
run(function()
	local AutoAttack, AttackDelay
	AutoAttack = vain.Categories.Blatant:CreateModule({
		Name = 'Auto Attack',
		Tooltip = 'Automatically swings your equipped weapon while in a dungeon.',
		Function = function(callback)
			if not callback then return end
			-- No dodging here on purpose: setupDodge is a local of the Auto Farm block, so
			-- calling it from out here was a nil call that killed this module the moment it
			-- was switched on. Auto Attack swings; Auto Farm is what dodges.
			local weaponUsed = remote('weaponUsed')
			repeat
				pcall(function()
					local ok, char = inCombat()
					if not ok then return end
					faceNearest() -- point at the enemy so the swing lands
					local weapon
					for _, c in char:GetChildren() do
						if c:IsA('Accessory') and c:FindFirstChild('Weapon') then weapon = c break end
					end
					if not weapon then return end
					local rem = weapon:FindFirstChildOfClass('RemoteEvent')
					if rem then rem:FireServer() end
					if weaponUsed then weaponUsed:FireServer() end
				end)
				task.wait(AttackDelay.Value)
			until not AutoAttack.Enabled
		end,
	})
	AttackDelay = AutoAttack:CreateSlider({
		Name = 'Attack Delay', Min = 0, Max = 1, Default = 0.12, Decimal = 100, Suffix = 's',
		Tooltip = 'Delay between swings. Lower is faster; too low may be throttled server-side.',
	})
end)

-- ── Auto Skill ───────────────────────────────────────────────────────────────
run(function()
	local AutoSkill
	AutoSkill = vain.Categories.Blatant:CreateModule({
		Name = 'Auto Skill',
		Tooltip = 'Casts your Q and E abilities the instant they come off cooldown.',
		Function = function(callback)
			if not callback then return end
			local abilityUsed = remote('abilityUsed')
			repeat
				pcall(function()
					local ok = inCombat()
					if not (ok and abilityUsed) then return end
					faceNearest() -- point at the enemy so directional abilities go the right way
					for _, slot in { 'q', 'e', 'q2', 'e2' } do
						for _, child in lplr.Backpack:GetChildren() do
							if child:FindFirstChild('abilitySlot') and child.abilitySlot.Value == slot then
								local cd = child:FindFirstChild('cooldown')
								if not (cd and cd.Value > 0) then -- not on cooldown
									local le = child:FindFirstChild('localEvent')
									if le then le:Fire() end
									abilityUsed:FireServer(slot, child)
								end
								break
							end
						end
					end
				end)
				task.wait(0.1)
			until not AutoSkill.Enabled
		end,
	})
end)

-- ── Dungeon flow ───────────────────────────────────────────────────────
-- Auto Start Dungeon / Auto Ready Up / Auto Boss Raid are lobby actions -> they
-- live in the lobby file (games/77649408247578.lua).

-- Shared "the run is over" check: the game itself reads bossRoom.dungeonFinished
-- (a BoolValue) as its completion flag, so we do exactly the same. It is only true
-- once the final boss is dead / the run has actually ended, never mid-run.
local function dungeonOver()
	-- mirror the game's own isRunFinished(): boss raids flip workspace.dungeonProgress
	-- to "bossKilled"; normal dungeons flip workspace.dungeon.bossRoom.dungeonFinished.
	-- Must be the EXACT path - a recursive bossRoom search hit a wrong room reading true
	-- (that was the 'replays/lobbies immediately' bug).
	local dp = workspace:FindFirstChild('dungeonProgress')
	if dp and dp:IsA('StringValue') and dp.Value == 'bossKilled' then return true end
	local dungeon = workspace:FindFirstChild('dungeon')
	local bossRoom = dungeon and dungeon:FindFirstChild('bossRoom')
	local df = bossRoom and bossRoom:FindFirstChild('dungeonFinished')
	return df ~= nil and df:IsA('BoolValue') and df.Value == true
end

-- ── Auto Return to Lobby ──────────────────────────────────────────────────
run(function()
	local AutoReturn
	AutoReturn = vain.Categories.Utility:CreateModule({
		Name = 'Auto Return to Lobby',
		Tooltip = 'Returns to the lobby, but ONLY once the run is actually over (boss defeated / run finished) - never mid-dungeon.',
		Function = function(callback)
			if not callback then return end
			repeat
				pcall(function()
					if not dungeonOver() then return end
					local r = remote('ReturnToLobbyEvent')
					if r then r:FireServer() end
				end)
				task.wait(1)
			until not AutoReturn.Enabled
		end,
	})
end)

-- ── Auto Replay ──────────────────────────────────────────────────────────────────
-- Clicking Replay is a TWO-step popup: the Replay button opens a 'ReplayConfirmation'
-- dialog, then its confirm(Yes) button actually replays. That Replay button also
-- works mid-run, so we only click it once dungeonOver() is true (clicking it mid-run
-- was the 'restarts immediately' bug). Step 2 just answers the Yes popup.
run(function()
	local AutoReplay
	AutoReplay = vain.Categories.Blatant:CreateModule({
		Name = 'Auto Replay',
		Tooltip = 'When the run is over (final boss defeated) it clicks Replay and confirms the Yes popup so a fresh run starts. Does nothing mid-dungeon.',
		Function = function(callback)
			if not callback then return end
			repeat
				local acted = false
				pcall(function()
					if not firesignal then return end
					if not dungeonOver() then return end -- gate FIRST; nothing fires mid-run
					local pg = lplr:FindFirstChild('PlayerGui')
					if not pg then return end
					-- ReplayConfirmation is pre-cloned at dungeon start (Enabled=false) and its
					-- confirm(Yes) button is wired straight to doReplay(), so once the run is over we
					-- fire that Yes directly (no need to open the dialog first).
					local confirm = pg:FindFirstChild('ReplayConfirmation')
					local yesHolder = confirm and confirm:FindFirstChild('confirm', true)
					local yes = yesHolder and yesHolder:FindFirstChildWhichIsA('GuiButton', true)
					if yes then firesignal(yes.MouseButton1Click) acted = true return end
					-- fallback: open the confirm via the options-menu Replay button
					local btn = pg:FindFirstChild('ReplayDungeonButton', true)
					if btn and not btn:IsA('GuiButton') then btn = btn:FindFirstChildWhichIsA('GuiButton', true) end
					if btn and btn:IsA('GuiButton') then firesignal(btn.MouseButton1Click) acted = true end
				end)
				task.wait(acted and 2.5 or 0.5)
			until not AutoReplay.Enabled
		end,
	})
end)

-- ── Auto Start (begin the run) ─────────────────────────────────────────
-- Each half keys on its own button, because the two appear under different conditions.
--
-- The server asks for a ready by firing showReadyGui, whose handler clones
-- ReplicatedStorage.ui.readyButton into PlayerGui - but only while
-- workspace.dungeonProgress is "playersNotReady". It asks for a start by firing
-- showStartButton, whose handler clones ui.startButton into PlayerGui with no condition
-- attached at all.
--
-- That difference is what broke the previous attempt: it gated everything on
-- playersNotReady, which is the ready button's condition, so the start was blocked
-- outright whenever the state had already moved on. The attempt before that gated on
-- finding a ScreenGui named startButton and never fired the remotes without one.
--
-- The button existing is the signal in both cases, since the server only sends it when
-- it wants that action. Every start button in the place runs the same single line when
-- clicked - startDungeon:FireServer(), no arguments - so that is fired directly, with
-- the button clicked as well rather than instead.
run(function()
	local AutoStart, Mode
	local virtualInput = cloneref(game:GetService('VirtualInputManager'))
	local guiService = cloneref(game:GetService('GuiService'))

	local function clickInside(container)
		if not (container and firesignal) then return end
		for _, g in container:GetDescendants() do
			if g:IsA('GuiButton') then
				pcall(function() firesignal(g.MouseButton1Click) end)
				pcall(function() firesignal(g.Activated) end)
			end
		end
	end

	-- A real click at the button's position on screen, as though you had moved the mouse
	-- there and pressed it.
	--
	-- This is the fallback for when neither of the other two routes lands: firesignal is
	-- not available on every executor, and firing the remote assumes the button does
	-- nothing else worth doing. A genuine click goes through whatever the game has wired
	-- up, whatever that turns out to be.
	local function realClick(button)
		if not (button and button.AbsoluteSize.X > 0 and button.AbsoluteSize.Y > 0) then
			return false
		end

		-- AbsolutePosition is measured below the topbar, but the mouse coordinates this
		-- takes are measured from the very top of the window - so without adding the
		-- inset back the click lands about thirty pixels above the button, which on a
		-- small button means missing it entirely.
		local inset = guiService:GetGuiInset()
		local centre = button.AbsolutePosition + inset + (button.AbsoluteSize / 2)

		return (pcall(function()
			virtualInput:SendMouseButtonEvent(centre.X, centre.Y, 0, true, game, 1)
			task.wait()
			virtualInput:SendMouseButtonEvent(centre.X, centre.Y, 0, false, game, 1)
		end))
	end

	-- Roblox's own activation path, borrowed from how console controls work.
	--
	-- A GuiButton has no Activate method - only an Activated event, which cannot be
	-- called directly, which is why the routes above either fire the signal or click
	-- where the button sits. But setting GuiService.SelectedObject and sending a
	-- controller A press makes Roblox activate the selection itself, running whatever
	-- the button is wired to without needing firesignal and without depending on the
	-- button being where its coordinates say it is.
	local function activateSelected(button)
		return (pcall(function()
			local previous = guiService.SelectedObject
			guiService.SelectedObject = button
			virtualInput:SendKeyEvent(true, Enum.KeyCode.ButtonA, false, game)
			task.wait()
			virtualInput:SendKeyEvent(false, Enum.KeyCode.ButtonA, false, game)
			-- Put the selection back, so this does not leave the interface focused
			-- somewhere the player did not choose.
			guiService.SelectedObject = previous
		end))
	end

	-- Every visible button inside a container, largest first: the one that actually
	-- starts the run is the big obvious one, and clicking a small decorative sibling
	-- first can close the prompt before the real one is reached.
	local function clickForReal(container)
		if not container then return false end

		local buttons = {}
		for _, g in container:GetDescendants() do
			if g:IsA('GuiButton') and g.Visible then
				table.insert(buttons, g)
			end
		end
		table.sort(buttons, function(a, b)
			return (a.AbsoluteSize.X * a.AbsoluteSize.Y) > (b.AbsoluteSize.X * b.AbsoluteSize.Y)
		end)

		for _, g in buttons do
			-- Both, since they fail in different circumstances: the click misses if the
			-- button is not where its coordinates put it, and the selection route does
			-- nothing if the game has gamepad selection turned off.
			activateSelected(g)
			if realClick(g) then return true end
		end
		return false
	end

	AutoStart = vain.Categories.Blatant:CreateModule({
		Name = 'Auto Start',
		Tooltip = 'Readies up and starts the run the moment the game offers either.',
		Function = function(callback)
			if not callback then return end
			repeat
				pcall(function()
					local pg = lplr:FindFirstChild('PlayerGui')
					if not pg then return end

					local clickOnly = Mode.Value == 'Click Only'
					local ready = pg:FindFirstChild('readyButton')
					local start = pg:FindFirstChild('startButton')

					if ready then
						if clickOnly then
							clickForReal(ready)
						else
							local ru = remote('readyUp')
							if ru then pcall(function() ru:FireServer() end) end
							clickInside(ready)
							clickForReal(ready)
						end
					end

					if start then
						if clickOnly then
							clickForReal(start)
						else
							-- Host only, and ignored server side for everyone else, which
							-- is what makes it safe to send without working out whether
							-- you are.
							local sd = remote('startDungeon')
							if sd then pcall(function() sd:FireServer() end) end
							clickInside(start)
							clickForReal(start)
						end
					end
				end)
				task.wait(1)
			until not AutoStart.Enabled
		end,
	})
	Mode = AutoStart:CreateDropdown({
		Name = 'Mode',
		Tooltip = 'How the start is triggered',
		List = {'Everything', 'Click Only'},
		Tooltips = {
			Everything = 'Fires the remote, fires the button handlers, and clicks it for real',
			['Click Only'] = 'Just moves the mouse onto the button and clicks it, exactly as you would'
		}
	})
end)

-- ── Auto Farm (full dungeon clear) ───────────────────────────────────────────
-- Finds the nearest live enemy, positions ABOVE it (so ground melee whiffs),
-- and bursts it with weapon swing + both abilities. Safety: if HP drops below the
-- threshold it floats high out of reach and waits to recover, so it never dies.
-- When a room is clear it walks forward to trigger the next one.
--[[
	Clears a dungeon on foot.

	Everything here moves the character the way the game does: the humanoid is asked to
	walk, and that is all. No CFrame is written, nothing is anchored or platform-stood,
	and WalkSpeed and JumpPower are never touched - the server rubber-bands anything that
	arrives somewhere it could not have walked to, so the older version's hovering beside
	enemies and floating a hundred and fifty studs up to heal is exactly what it now
	refuses.

	Nothing here is per-dungeon or per-boss either, and it does not need to be. Enemies are
	whatever has a living Humanoid under an enemyFolder, so every mob in every dungeon is
	already covered; the boss is found from the game's own fightingBoss flag; and area
	attacks come from the precastHitbox telegraph the game sends for all of them.
]]
run(function()
	local AutoFarm, SafeHP, RecoverHP, AttackRange, AbilityRange, KeepDistance, KeepAway, FarmDelay, HealSwap, DodgeAttacks, UsePathfinding, Strafe, Movement, ShiftLock, Debug

	--[[
		How the character gets about, as one choice rather than two toggles.

		Walk hands the destination to the humanoid and lets it walk there, which is what a
		player does and what the server expects to see.

		Step TP places the character along the same route in small pieces, never further per
		second than a walk would have covered - which is precise enough to hold a strafe
		circle, but needs a floor under every step and so pays for ledges and corners.

		Fly is the same movement without needing the floor at all, rising to an enemy above
		you, and still at walk pace. The two used to be separate switches and Fly was only
		consulted from inside the step path, so turning it on while walking did nothing.
	]]
	local function mode()
		return Movement ~= nil and Movement.Value or 'Walk'
	end

	local function moving()
		return mode() ~= 'Walk'
	end

	--[[
		Chatter, which the Debug toggle controls.

		Anything that happens repeatedly - a telegraph seen, a dodge taken - is quiet unless
		asked for. It is called from setupDodge though, which runs once when the module is
		switched on, so turning Debug on afterwards would never show the one thing worth
		knowing: whether the hook installed at all.
	]]
	local function say(text)
		if not (Debug ~= nil and Debug.Enabled) then return end
		if vain and vain.CreateNotification then
			vain:CreateNotification('Auto Farm', text, 4, 'info')
		end
		warn('[Auto Farm] ' .. text)
	end

	-- Said once each, whatever the toggle says, because a hook that failed to install is
	-- not chatter - it is the difference between dodging and not.
	local function announce(text)
		warn('[Auto Farm] ' .. text)
		if vain and vain.CreateNotification then
			vain:CreateNotification('Auto Farm', text, 6, 'info')
		end
	end

	local pathfindingService = cloneref(game:GetService('PathfindingService'))

	-- ── Boss detection + attack dodging ────────────────────────────────────
	-- Every boss/enemy AREA attack is telegraphed to the client over a BridgeNet2
	-- 'precastHitbox' bridge: Cube {cframe,size} or Circle {position,radius}, each with
	-- a delayUntilAttack lead time. We attach a second listener to that same bridge,
	-- remember each danger zone, and walk out of it before it lands.
	-- Declared here rather than beside the targeting code below, because the attack watcher
	-- is built before that point and reads it: as a local further down it was simply not in
	-- scope yet, so the watcher captured a nil and threw on every model that arrived.
	local enemyCache, lastScan = {}, 0

	local function enemyPart(m)
		return m.PrimaryPart or m:FindFirstChild('HumanoidRootPart') or m:FindFirstChild('Torso')
			or m:FindFirstChild('UpperTorso') or m:FindFirstChildWhichIsA('BasePart')
	end

	local groundParams = RaycastParams.new()
	groundParams.FilterType = Enum.RaycastFilterType.Exclude
	groundParams.RespectCanCollide = true
	local lastStep = os.clock()

	--[[
		Floor is whatever you could stand on, and nothing else.

		Attack parts cannot be collided with, but a plain raycast hits them anyway - so a
		step aimed under a tall hitBox "landed" on top of it, read as a climb far higher
		than a step, and was refused. The stepper then fell back to a third of a step, over
		and over, for as long as the attack lasted: that is the slowdown while dodging.
		Respecting CanCollide means only real floor answers.

		The filter is rebuilt twice a second rather than per ray: the dodge search casts a
		ray for most of a few hundred candidates, and a fresh table of every enemy for each
		one was a large part of what the search cost.
	]]
	local footParams = RaycastParams.new()
	footParams.FilterType = Enum.RaycastFilterType.Exclude
	footParams.RespectCanCollide = true
	local footSkipAt = 0

	--[[
		The floor under a destination, and only the floor.

		The one thing excluded here used to be our own character, so a step aimed at a spot
		with a mob standing in it raycast onto the MOB and took its head for ground - which
		is how dodging a circle turned into climbing on top of whoever cast it. Bodies are
		skipped now, and so is anything a raycast should never have seen anyway.

		The height is also clamped: a walking player cannot rise four studs in a tenth of a
		second, so neither does this. A ledge that cannot be stepped onto is simply not
		stepped onto, rather than being climbed in one frame.
	]]
	-- How much higher a destination may be before it stops being a step and starts being a
	-- climb. Kept low on purpose: raising it let the farm haul itself up onto things it had
	-- no business standing on, which is what was drawing the correction.
	local MAX_RISE = 4
	local MAX_DROP = 24

	--[[
		The floor to stand on, or nothing at all.

		Carrying the old height across a gap is how you walk out over a ledge and fall: the
		step lands in mid air at the height it left, and gravity does the rest. So a
		destination with no floor under it is not somewhere to go, and neither is one at the
		bottom of a drop - that is a fall, not a step, and the sudden change in height is
		also exactly what the server pulls you back for.

		Returning nothing rather than a guess lets the caller shorten the step and try
		again, which is what edges along a walkway instead of stopping dead at it.
	]]
	local losParams = RaycastParams.new()
	losParams.FilterType = Enum.RaycastFilterType.Exclude
	losParams.RespectCanCollide = true

	local function refreshSkip()
		if os.clock() - footSkipAt < 0.5 then return end
		footSkipAt = os.clock()
		local skip = {lplr.Character}
		for _, m in enemyCache do
			if m and m.Parent then table.insert(skip, m) end
		end
		footParams.FilterDescendantsInstances = skip
		losParams.FilterDescendantsInstances = skip
	end

	--[[
		Whether a wall stands between two places.

		Nothing in the movement ever asked. Stepping checked for a floor at the far end and
		nothing in between, so a step aimed through a wall landed inside it - which is both
		"running into walls" and exactly the kind of move the server pulls you back for.

		Cast flat at root and chest height: low enough to catch a wall, high enough that a
		stair or a slope is not mistaken for one. Bodies are skipped, so an enemy standing
		in the way is not a wall; only collidable geometry counts.
	]]
	--[[
		The low pass matters for walking, not for seeing.

		Casting at the root and above misses everything shorter than the character's chest -
		crates, rubble, railings, the lip of a platform - all of which stop a walk dead. That
		is the farm pressed against an object making no progress while every check says the
		way ahead is clear.

		It is only asked for when the question is "can I walk there", because a knee-high
		ledge does not stop an ability, and treating it as cover would have the farm refusing
		perfectly good ground in a boss fight.
	]]
	local function clearLine(from, to, low)
		refreshSkip()
		local flat = Vector3.new(to.X - from.X, 0, to.Z - from.Z)
		if flat.Magnitude < 0.05 then return true end
		for _, lift in { 0, 1.5 } do
			if workspace:Raycast(from + Vector3.new(0, lift, 0), flat, losParams) then return false end
		end
		if low and workspace:Raycast(from - Vector3.new(0, 1.2, 0), flat, losParams) then return false end
		return true
	end

	-- The same question for a single step, reaching a little past it so the body does not
	-- end up with its shoulder inside the wall.
	local function wallBetween(from, to)
		refreshSkip()
		local flat = Vector3.new(to.X - from.X, 0, to.Z - from.Z)
		if flat.Magnitude < 0.05 then return false end
		local reach = flat.Unit * (flat.Magnitude + 1.5)
		if workspace:Raycast(from, reach, losParams) then return true end
		-- Knee height too: a step is climbed, a crate is walked into.
		return workspace:Raycast(from - Vector3.new(0, 1.2, 0), reach, losParams) ~= nil
	end

	local function groundAt(position, fallbackY)
		refreshSkip()

		local hit = workspace:Raycast(position + Vector3.new(0, 12, 0), Vector3.new(0, -80, 0), footParams)
		if not hit then return nil end

		local y = hit.Position.Y + 3
		if y > fallbackY + MAX_RISE then return nil end
		if y < fallbackY - MAX_DROP then return nil end
		return y
	end

	--[[
		Getting back on the floor after leaving it.

		Stepping refuses any destination without ground under it, so it never walks off an
		edge - but it cannot help once something else has put you over one. Knocked off by
		an attack, shoved by a pack, and every destination is now a long way below you, so
		every step is refused and you simply keep going down.

		So a fall is caught instead. Once the humanoid has been in freefall long enough that
		it is not a jump, the floor beneath is found and it is put back on it. The drop is
		bigger than a step, but it is downward and onto solid ground - which is where the
		fall was heading anyway, only without the death at the end of it.
	]]
	local fallingSince

	local function keepGrounded(hrp, hum)
		local state = hum:GetState()
		local falling = state == Enum.HumanoidStateType.Freefall

		if not falling then
			fallingSince = nil
			return false
		end

		fallingSince = fallingSince or os.clock()
		-- Short enough to catch a fall before it becomes a drop, long enough that an
		-- ordinary jump is left alone.
		if os.clock() - fallingSince < 0.3 then return false end

		groundParams.FilterDescendantsInstances = {lplr.Character}
		local hit = workspace:Raycast(hrp.Position, Vector3.new(0, -600, 0), groundParams)
		if not hit then return false end

		fallingSince = nil
		hrp.CFrame = CFrame.new(Vector3.new(hrp.Position.X, hit.Position.Y + 3, hrp.Position.Z))
			* (hrp.CFrame - hrp.CFrame.Position)
		hrp.AssemblyLinearVelocity = Vector3.zero
		say('caught a fall')
		return true
	end


	--[[
		The invisible walls, and staying inside them.

		The playable area is fenced by parts, and a dodge that chose a spot on the far side
		of one could never get there: the step refused it, the search offered it again next
		tick, and the farm stood announcing a dodge it would never take. That is the stall.
		Worse, a Step TP that crosses one is exactly what the server pulls you back for.

		Two folders matter and only one was ever read. 'Barriers' exists, but in this place
		it lives inside bossRoom - so looking for it under workspace found nothing at all,
		every run, and the walls have never actually been respected. The one that fences the
		rooms is 'borders', built at runtime, which is why it is searched for rather than
		resolved once.

		Tested by geometry rather than by raycast, because these are exactly the sort of part
		that is built unqueryable - a ray would pass straight through the very wall we are
		trying to respect. Each part becomes a box in its own space, which is cheap enough
		for the dozens a room has, and correct whatever their query flags say.
	]]
	local barrierParts, barrierScan, deepScan = {}, 0, -math.huge

	local function collectBorders(root, out, depth)
		if not root or depth > 3 then return end
		for _, child in root:GetChildren() do
			local name = child.Name
			if name == 'borders' or name == 'Barriers' then
				for _, d in child:GetDescendants() do
					if d:IsA('BasePart') then table.insert(out, d) end
				end
			elseif child:IsA('Folder') or child:IsA('Model') then
				collectBorders(child, out, depth + 1)
			end
		end
	end

	local function refreshBarriers()
		if os.clock() - barrierScan < 3 and #barrierParts > 0 then return end
		barrierScan = os.clock()

		local found = {}
		-- Walked from the few places a dungeon keeps them rather than over the whole
		-- workspace, which is tens of thousands of instances and is not something to do
		-- every three seconds.
		collectBorders(workspace:FindFirstChild('dungeon'), found, 1)
		collectBorders(workspace:FindFirstChild('Map'), found, 1)
		for _, child in workspace:GetChildren() do
			if child.Name == 'borders' or child.Name == 'Barriers' then
				for _, d in child:GetDescendants() do
					if d:IsA('BasePart') then table.insert(found, d) end
				end
			end
		end

		--[[
			The deep search, rarely.

			A recursive FindFirstChild over the workspace is a walk of every instance in the
			dungeon, and running it every three seconds - which is what happened anywhere
			the folders are not where they usually are, a boss room among them - costs more
			as the run goes on and the map streams in. Once every half minute is enough to
			pick one up if it appears late.
		]]
		if #found == 0 and os.clock() - deepScan > 30 then
			deepScan = os.clock()
			local folder = workspace:FindFirstChild('borders', true) or workspace:FindFirstChild('Barriers', true)
			if folder then
				for _, d in folder:GetDescendants() do
					if d:IsA('BasePart') then table.insert(found, d) end
				end
			end
		end

		-- Nothing found this pass does not mean the walls have gone: keep the last set
		-- rather than dropping every bound until the next deep search.
		if #found > 0 or #barrierParts == 0 then
			barrierParts = found
		end
	end

	-- Tested against a nearby subset when one is given: a room's worth of border parts
	-- is small, the whole map's is not, and the dodge search asks this hundreds of times.
	local function insideBarrier(pos, margin, parts)
		margin = margin or 2
		for _, part in (parts or barrierParts) do
			if part.Parent then
				local local_ = part.CFrame:PointToObjectSpace(pos)
				local half = part.Size * 0.5
				if math.abs(local_.X) <= half.X + margin
					and math.abs(local_.Y) <= half.Y + margin
					and math.abs(local_.Z) <= half.Z + margin then
					return true
				end
			end
		end
		return false
	end

	-- Walked in a few steps rather than tested at the ends, since a wall between two clear
	-- points is still a wall.
	local function crossesBarrier(from, to, parts)
		if #(parts or barrierParts) == 0 then return false end
		for i = 1, 6 do
			if insideBarrier(from:Lerp(to, i / 6), 1, parts) then return true end
		end
		return false
	end

	local dangers = {}
	local dodgeReady = false
	local seenZones = 0

	-- Set the instant a new attack part is registered, so the dodge replans on the frame it
	-- appears instead of waiting for the next farm tick. A tenth of a second is most of the
	-- warning on a fast attack, and it is the difference between stepping out and being hit.
	local dangerAdded = false

	-- Where the dodge is currently heading, held across frames so a plan is followed rather
	-- than recomputed into a different answer every frame.
	local dodgeGoal = nil

	-- When a search last came back empty while standing in an attack. Searching again
	-- every single frame while there is nowhere to go only drops the frame rate, and a
	-- lower frame rate is a slower dodge.
	local lastPlanFailed = 0

	-- A full search is a few hundred geometry tests and up to a hundred rays. Sixteen of
	-- them a second is plenty to react to anything; sixty is just a lower frame rate, and a
	-- lower frame rate is a slower dodge.
	local lastPlanAt = 0

	--[[
		Two timers that stop the farm arguing with itself.

		A dodge ends by stepping clear of an attack; the farm's very next tick sees the
		target further away than it likes and walks straight back toward it, into the zone
		it just left, which starts the next dodge. From outside that is a character shuffling
		forward and back on the spot and never fighting. Settling for a moment after a dodge
		breaks the loop.

		The second is for the opposite failure: when every spot the search offers turns out
		to be unreachable, dodging achieves nothing at all, and continuing to try it every
		frame just holds the farm still. Better to stop dodging briefly and let it act.
	]]
	local settleUntil, dodgeRestUntil = 0, 0

	--[[
		Spots the stepper would not actually go to.

		A dodge spot behind a wall, up a ledge or over a border is chosen, refused by every
		step, and then held for ever - and since the farm waits for a dodge to finish, the
		character stands still until something else happens. Spots that fail to move us are
		remembered for a few seconds so the search offers a different one instead.
	]]
	local badSpots = {}
	local dodgeStalls, dodgeLastPos, dodgeMovedAt = 0, nil, 0

	-- What the farm is currently fighting, so a dodge can be judged on whether it keeps
	-- the fight rather than only on how near it is. Set by the farm tick, read by the dodge.
	local fightTarget = nil

	--[[
		Declared up here, defined with the rest of the room logic further down.

		The dodge has to keep its chosen spot inside the room being fought, and the room
		helpers live several hundred lines below it. A local defined later in the same block
		is a nil GLOBAL to everything above it - it does not error at load, it simply reads
		as nil and throws when called - which is exactly how this file has broken before.
	]]
	local currentRoom, inRoom

	--[[
		The telegraph taken at its source.

		The module the game draws these with returns the very table it dispatches through,
		and its own handler looks the shape up on that table each time one arrives - so
		replacing the two entries on it puts us in front of every warning, with the exact
		numbers the game is about to draw, before it draws anything. No second listener on
		a bridge the game already owns, and nothing to recognise by sight.
	]]
	--[[
		Finding the table the game is actually dispatching through.

		Requiring the module looked right and did nothing: an executor keeps its own module
		cache, so `require` hands back a FRESH copy of PrecastHitbox - its own Cube and
		Circle, its own bridge connection - while the game carries on calling the original.
		The hook installed perfectly and never received a single telegraph, which is exactly
		what was reported.

		So the live table is looked for among everything already in memory instead: it is
		the one holding both a Cube and a Circle function, and it is the one the game's own
		handler indexes each time a warning arrives. Requiring stays as a fallback for
		executors without getgc, where it is better than nothing even if it is a copy.
	]]
	local function findPrecast()
		if getgc then
			local ok, found = pcall(function()
				for _, value in getgc(true) do
					if type(value) == 'table'
						and type(rawget(value, 'Cube')) == 'function'
						and type(rawget(value, 'Circle')) == 'function' then
						return value
					end
				end
			end)
			if ok and found then return found, 'live table' end
		end

		local modules = replicatedStorage:FindFirstChild('modules')
		local module = modules and modules:FindFirstChild('PrecastHitbox')
		if not module then return nil end

		local ok, required = pcall(require, module)
		if ok and type(required) == 'table' then return required, 'required copy' end
		return nil
	end

	local function hookPrecast(note)
		local precast, how = findPrecast()
		if not precast then error('PrecastHitbox not found', 0) end

		local oldCube, oldCircle = rawget(precast, 'Cube'), rawget(precast, 'Circle')
		if not (oldCube and oldCircle) then error('PrecastHitbox has no Cube/Circle', 0) end

		precast.Cube = function(cframe, size, delay, startTime, properties)
			note('cube', cframe, size, delay, startTime)
			return oldCube(cframe, size, delay, startTime, properties)
		end
		precast.Circle = function(position, radius, delay, startTime, properties)
			note('circle', position, radius, delay, startTime)
			return oldCircle(position, radius, delay, startTime, properties)
		end

		return how
	end

	--[[
		How long a telegraph is worth avoiding for.

		This was simply missing. Every call to it sat INSIDE the wrapper installed over the
		game's own Cube and Circle, so the nil call threw before the original ran - killing
		our registration and the game's own warning drawing with it, on every single
		telegraph. Both halves of the dodge looked installed and neither ever worked.

		The lead time is when it lands; a little past that is when it is over.
	]]
	local function windowFor(delay)
		return workspace:GetServerTimeNow() + (tonumber(delay) or 1) + 0.6
	end

	--[[
		Knowing an attack by name, from the game's own list of them.

		Every enemy attack in this game is a clone of something under
		ReplicatedStorage.enemyProjectiles - and the per-enemy attack models under
		enemyAssets - so the set of names in those two folders IS the set of things that
		can hurt you. Reading it at runtime means an update that adds a boss is covered
		without touching this file, which the old "every part of every model" guess never
		managed: it dodged loot, gibs and scenery, and that is a large part of why dodging
		looked like it never worked.

		A clone keeps its name and loses every other link to where it came from, so the
		name is what there is to match on.

		Your own spells are the one trap. They are cloned from ReplicatedStorage.projectiles
		and use the very same part names - hitBox above all - so matching names alone makes
		the farm flee from its own casts. Anything whose name also exists in that folder is
		therefore dropped, which costs only the handful of names the two share.
	]]
	local attackNames, ownNames = {}, {}

	local function learnNames()
		if next(attackNames) then return end

		--[[
			The attacks, not the pieces they are built from.

			Harvesting every descendant collected the mesh names inside each attack -
			Crystal, base, Ice, flame, circle, rock, even 't' and 'e' - and the dungeon's own
			scenery uses exactly those names. Rooms stream in during a run, so every
			matching rock and crystal on the map became a danger zone that never expired,
			and the dodge found nowhere left to stand.

			Only the entries themselves are names: whatever sits in the folder (recursing
			through the per-enemy subfolders) and the attack models directly inside a model
			that groups several. The damage volumes inside an attack are known separately
			by their own names, below.
		]]
		local function harvest(folder, into)
			if not folder then return end
			for _, child in folder:GetChildren() do
				if child:IsA('Folder') then
					harvest(child, into)
				elseif child:IsA('Model') or child:IsA('BasePart') then
					into[child.Name] = true
					if child:IsA('Model') then
						for _, inner in child:GetChildren() do
							if inner:IsA('Model') then into[inner.Name] = true end
						end
					end
				end
			end
		end

		harvest(replicatedStorage:FindFirstChild('projectiles'), ownNames)

		local enemy = {}
		harvest(replicatedStorage:FindFirstChild('enemyProjectiles'), enemy)
		harvest(replicatedStorage:FindFirstChild('enemyAssets'), enemy)

		-- Names so generic that matching them would catch the map itself. 'Part' is what
		-- the telegraph module calls its own hitboxes AND what every border part is
		-- called, so it can only ever come from the bridge hook, never from a name.
		local generic = {
			Part = true, Model = true, Folder = true, Union = true, MeshPart = true,
			Handle = true, PrimaryPart = true, primaryPart = true, Head = true,
			HumanoidRootPart = true, Torso = true, Attachment = true, Sound = true,
		}

		for name in enemy do
			if not generic[name] and not ownNames[name] then attackNames[name] = true end
		end
	end

	--[[
		What a part actually is, rather than what a box would say it is.

		A circle attack's hitBox is a sphere and its warning is a cylinder lying on its
		side; a lane is a block. Measuring all three as axis-aligned boxes is why dodges
		stepped to spots that were still inside the attack, and why some attacks read as
		far bigger than they are - the corners of a box around a 40-stud sphere stick out
		eight studs past it in every diagonal.

		Read fresh on every test, because these are tweened into place while the warning
		plays: where a zone was when it appeared is not where it lands.
	]]
	local function zoneShape(part)
		if not (part and part.Parent) then return nil end
		local shape = part:IsA('Part') and part.Shape or Enum.PartType.Block
		return part.CFrame, part.Size, shape
	end

	--[[
		The parts that can hurt you, watched from the instant they exist.

		Registered on sight rather than scanned for on a timer: an attack that is only
		dangerous for a second is one a tenth-of-a-second poll can miss entirely, and the
		whole point is to be moving before it lands.

		Anything worn by, or attached to, a character is skipped. Bosses wear their gear
		from these same folders, and a mark stuck to your own root ('lastBossCharMark',
		'firstBossPlayerOnFire') would otherwise be a danger zone that follows you around
		for ever - the farm would run from itself and never stop.
	]]
	-- The damage volumes, by the names the game gives them inside every attack model.
	local HITBOX_NAMES = {
		hitBox = true, precast = true, preCast = true, damagePrecast = true,
		innerHitbox = true, outerHitbox = true, leftHitbox = true, rightHitbox = true,
		innerPrecast = true, outerPrecast = true, leftPrecast = true, rightPrecast = true,
		circlePrecast = true, growingPrecast = true,
	}

	--[[
		Somewhere to be, not somewhere to avoid.

		The memory and safe-spot mechanics damage the whole arena EXCEPT these circles, and
		they are built from the same parts as everything else - a precast, in a model called
		thirdBossSafeSpot. Treated as danger, the dodge ran out of the one place the attack
		could not reach, straight into the part that could.
	]]
	local safeZones = {}

	local function isSafeName(name)
		return string.lower(name):find('safe') ~= nil or name:find('Good') ~= nil
	end

	local function registerDanger(part)
		if not part:IsA('BasePart') then return end

		local char = lplr.Character
		if char and part:IsDescendantOf(char) then return end

		local dungeon = workspace:FindFirstChild('dungeon')
		local map = workspace:FindFirstChild('Map')

		--[[
			Walked all the way up, because where an attack is parented varies.

			Most land at the top of the workspace, some inside a model that groups several,
			some inside the enemy that cast them. Stopping four levels up missed the deeper
			ones; skipping everything with a Humanoid above it missed the ones parented into
			their caster.
		]]
		local container, safe, scenery = nil, false, false
		local node = part
		for _ = 1, 16 do
			if not node or node == workspace or node == game then break end
			-- Worn, not thrown: bosses wear gear from these very folders.
			if node:IsA('Accessory') or node:IsA('Tool') then return end

			local name = node.Name
			if isSafeName(name) then safe = true end
			if node == dungeon or node == map then scenery = true end

			if node:IsA('Model') and node:FindFirstChildOfClass('Humanoid') then
				if playersService:GetPlayerFromCharacter(node) then return end
				-- An enemy's own body is not an attack; a model parented into it can be.
				if not container or container == part then return end
				break
			end

			if attackNames[name] and node ~= part then container = container or node end
			if attackNames[name] and node == part then container = part end
			node = node.Parent
		end

		local volume = HITBOX_NAMES[part.Name]

		if container then
			-- A bare part matched only by its own name, sitting in the map, is scenery that
			-- happens to share a name with an attack - a rock is a rock.
			if container == part and scenery and not volume then return end
		elseif volume then
			-- A lone hitbox with no attack around it. Your own spells always arrive inside
			-- a named model, so one on its own is the enemy's - unless it is on top of you.
			if part.Parent ~= workspace then return end
			local root = char and char:FindFirstChild('HumanoidRootPart')
			if root and (part.Position - root.Position).Magnitude < 4 then return end
		else
			return
		end

		if safe then
			if volume or part.Name:find('Precast') then table.insert(safeZones, part) end
			return
		end

		table.insert(dangers, {
			part = part,
			expire = workspace:GetServerTimeNow() + 14,
			born = os.clock(),
			pos = part.Position,
		})
		seenZones += 1
		dangerAdded = true
	end

	local function watchAttackParts()
		learnNames()

		workspace.DescendantAdded:Connect(function(object)
			registerDanger(object)
		end)
	end

	local function setupDodge()
		if dodgeReady then return end
		dodgeReady = true

		local watched, watchErr = pcall(watchAttackParts)
		announce(watched and 'attack watcher installed' or ('attack watcher FAILED: ' .. tostring(watchErr)))


		local hooked, how = pcall(hookPrecast, function(kind, a, b, delay)
			if kind == 'cube' and typeof(a) == 'CFrame' and typeof(b) == 'Vector3' then
				table.insert(dangers, {kind = 'cube', cf = a, size = b, expire = windowFor(delay)})
				seenZones += 1
				say(string.format('cube telegraph %.0fx%.0f in %.1fs', b.X, b.Z, tonumber(delay) or 0))
			elseif kind == 'circle' and typeof(a) == 'Vector3' and tonumber(b) then
				table.insert(dangers, {kind = 'circle', pos = a, radius = tonumber(b), expire = windowFor(delay)})
				seenZones += 1
				say(string.format('circle telegraph r=%.0f in %.1fs', tonumber(b), tonumber(delay) or 0))
			end
		end)
		announce(hooked and ('telegraph hook installed via ' .. tostring(how))
			or ('telegraph hook FAILED: ' .. tostring(how)))
		pcall(function()
			local util = replicatedStorage:FindFirstChild('Utility')
			local bn = util and util:FindFirstChild('BridgeNet2')
			if not bn then return end
			local BridgeNet2 = require(bn)
			local bridge = BridgeNet2.ReferenceBridge('precastHitbox')
			bridge:Connect(function(data)
				if type(data) ~= 'table' then return end
				local expire = windowFor(data.delayUntilAttack)
				if typeof(data.cframe) == 'CFrame' and typeof(data.size) == 'Vector3' then
					table.insert(dangers, { kind = 'cube', cf = data.cframe, size = data.size, expire = expire })
				elseif typeof(data.position) == 'Vector3' and tonumber(data.radius) then
					table.insert(dangers, { kind = 'circle', pos = data.position, radius = tonumber(data.radius), expire = expire })
				end
			end)
		end)
	end

	local function bossActive()
		local dungeon = workspace:FindFirstChild('dungeon')
		local bossRoom = dungeon and dungeon:FindFirstChild('bossRoom')
		local fb = bossRoom and bossRoom:FindFirstChild('fightingBoss')
		return fb ~= nil and fb:IsA('BoolValue') and fb.Value == true
	end

	--[[
		Standing in it, tested against the shape the part actually is.

		The character is a column, not a point. A lane's warning is a stud thick and lies on
		the floor, so testing your root - three studs up - against it says you are clear
		while your feet are standing in it. Three samples up the body settles that without
		pretending a capsule test is cheap enough to run four hundred times a frame.
	]]
	local CHARACTER_RADIUS = 2

	local function pointInZone(cf, size, shape, point, margin)
		local lp = cf:PointToObjectSpace(point)
		local h = size * 0.5

		if shape == Enum.PartType.Ball then
			local radius = math.min(size.X, size.Y, size.Z) * 0.5
			return lp.Magnitude <= radius + margin
		elseif shape == Enum.PartType.Cylinder then
			-- Roblox lays a cylinder along its X axis: X is the height of the disc, and
			-- the circular face is the Y/Z plane.
			local radius = math.min(size.Y, size.Z) * 0.5
			local flat = math.sqrt(lp.Y * lp.Y + lp.Z * lp.Z)
			return math.abs(lp.X) <= h.X + margin and flat <= radius + margin
		end

		return math.abs(lp.X) <= h.X + margin
			and math.abs(lp.Y) <= h.Y + margin
			and math.abs(lp.Z) <= h.Z + margin
	end

	local function inDanger(pos, d, margin)
		margin = (margin or 0) + CHARACTER_RADIUS

		-- A telegraph from the bridge has no part behind it, only the numbers the game was
		-- about to draw with.
		if not d.part then
			if d.kind == 'circle' then
				if math.abs(pos.Y - d.pos.Y) > 25 then return false end
				local dx, dz = pos.X - d.pos.X, pos.Z - d.pos.Z
				return (dx * dx + dz * dz) <= (d.radius + margin) ^ 2
			end
			local lp = d.cf:PointToObjectSpace(pos)
			local h = d.size * 0.5
			return math.abs(lp.X) <= h.X + margin and math.abs(lp.Z) <= h.Z + margin
				and math.abs(lp.Y) <= h.Y + 8
		end

		--[[
			The measurements taken on the last pass, or taken now if it is brand new.

			Where it is going is part of where it is: thrown attacks are tweened across the
			room, and a part tested where it stands this frame is one you step into next.
			Travel is carried two steps forward, a sweep a third of a second - far enough to
			matter, not so far that a turning beam paints the whole arena as lethal.
		]]
		local cf, size, shape = d.cf, d.size, d.shape
		local futures = d.futures
		if not cf then
			cf, size, shape = zoneShape(d.part)
			if not cf then return false end
			futures = nil
		end

		--[[
			One distance compare before any real work.

			Nearly every attack on screen is nowhere near the spot being considered, and
			proving that with a full shape test - three heights, each against every
			predicted position - is most of what a dodge spends its time on. A sphere around
			the part answers it in three subtractions.
		]]
		local centre = cf.Position
		local dx, dy, dz = pos.X - centre.X, pos.Y - centre.Y, pos.Z - centre.Z
		local reach = (d.bound or size.Magnitude * 0.5) + margin + (d.spread or 0) + 4
		if dx * dx + dy * dy + dz * dz > reach * reach then return false end

		for _, height in { 0, -2.6, 1.6 } do
			local point = pos + Vector3.new(0, height, 0)
			if pointInZone(cf, size, shape, point, margin) then return true end
			if futures then
				for _, future in futures do
					if pointInZone(future, size, shape, point, margin) then return true end
				end
			end
		end
		return false
	end

	--[[
		Somewhere clear of everything, not out of one thing.

		Stepping out of the zone you happen to be standing in is only a dodge when there is
		one zone. Four mages casting at once lay overlapping lanes across the whole floor,
		and the way out of the first is usually well inside the second - which is what
		"it does not really dodge" looks like from the outside.

		So instead of asking a zone where its edge is, this asks the floor where it is safe:
		rings of candidate spots at growing distance, nearest ring first, and the first ring
		with anything clear of EVERY zone wins. That works the same for a lane, a ring, or
		nine of them at once, without knowing which enemy cast what.

		Among equally close options it takes the one furthest from the pack, since a dodge
		that lands in the middle of the melee has only traded one kind of damage for another.
	]]
	--[[
		Tight rings, sampled finely.

		The nearest ring that works is the one that costs the least fighting time, and a
		finer sweep means the direction chosen is closer to the one actually wanted rather
		than the nearest of sixteen. Both make the dodge read as a sidestep instead of a
		trip across the room.
	]]
	--[[
		Still a threat, and how fast it is travelling.

		A zone backed by a part is over the moment the part goes, which is most of how these
		expire: the game removes them on impact. The rest is measuring travel, because the
		thrown attacks are moved with TweenService and a tweened part reports a velocity of
		zero however fast it is crossing the room. Two positions a frame apart give the real
		answer whatever moved it.
	]]
	local function liveZone(d)
		if not d.part then return true end
		if not d.part.Parent then return false end

		local now = os.clock()
		local position = d.part.Position
		local cf = d.part.CFrame

		if d.pos then
			local elapsed = now - (d.at or now)
			if elapsed > 0.01 then
				local travel = (position - d.pos) / elapsed
				-- Ignored below a walking pace: a warning settling into place is not a
				-- projectile, and leading it would push the dodge off a zone that is
				-- standing still.
				d.velocity = travel.Magnitude > 12 and travel or nil

				--[[
					Sweeping counts as moving, even when nothing moves.

					A beam that pivots about its caster hardly shifts its own centre - the
					far end crosses the room while the middle barely stirs - so measuring
					travel alone calls it stationary and the dodge steps neatly into where
					it is about to be. Turn rate is the honest measure for those, and the
					Evil Scientist's sweeps are exactly this shape.
				]]
				local facing = cf.LookVector
				if d.facing then
					local turn = math.atan2(facing.X, facing.Z) - math.atan2(d.facing.X, d.facing.Z)
					-- Round the short way, so passing north does not read as a full circle.
					if turn > math.pi then turn -= math.pi * 2 end
					if turn < -math.pi then turn += math.pi * 2 end
					local rate = turn / elapsed
					d.spin = math.abs(rate) > 0.15 and rate or nil
				end
				d.facing = facing
			end
		else
			d.facing = cf.LookVector
		end

		--[[
			Measured once here, not once per question asked about it.

			Every test of "is this spot inside this attack" used to read the part's CFrame,
			size and shape afresh and build its prediction table again - and a dodge asks
			that question a few hundred times per attack. With a barrage of projectiles in
			the air that is tens of thousands of property reads and table allocations for a
			single dodge, which is the lag that arrives exactly when the screen fills with
			attacks and the farm can least afford it.

			The geometry only changes when the part moves, so it is worked out on this pass
			and read from here afterwards.
		]]
		d.cf, d.size = cf, d.part.Size
		d.shape = d.part:IsA('Part') and d.part.Shape or Enum.PartType.Block
		d.bound = d.size.Magnitude * 0.5
		d.futures, d.spread = nil, 0

		if d.velocity or d.spin then
			local futures = {}
			if d.velocity then
				table.insert(futures, cf + d.velocity * 0.35)
				table.insert(futures, cf + d.velocity * 0.7)
				d.spread += d.velocity.Magnitude * 0.7
			end
			if d.spin then
				table.insert(futures, CFrame.new(cf.Position)
					* CFrame.Angles(0, d.spin * 0.3, 0)
					* (cf - cf.Position))
				d.spread += math.abs(d.spin) * 0.3 * d.bound
			end
			d.futures = futures
		end

		d.pos, d.at = position, now
		return true
	end

	-- Standing in a live safe circle, which the arena-wide attacks cannot reach.
	local function inSafeZone(pos)
		for i = #safeZones, 1, -1 do
			local part = safeZones[i]
			if not part.Parent then
				table.remove(safeZones, i)
			else
				local cf, size, shape = zoneShape(part)
				if cf and (pointInZone(cf, size, shape, pos, 1)
					or pointInZone(cf, size, shape, pos + Vector3.new(0, -2.6, 0), 1)) then
					return true
				end
			end
		end
		return false
	end

	--[[
		Where to stand when the floor itself is the attack.

		Several bosses damage the entire arena except for marked circles - Show Safe Spot,
		Show Safe Zones, Safe Color Zone, the memory patterns. Treating those circles as
		"not dangerous" is only half an answer: the dodge still went looking for open floor,
		and the open floor is the part that kills you. The answer to this mechanic is to
		walk into the circle and stay in it.
	]]
	local function nearestSafeSpot(pos)
		local best, bestDist
		for i = #safeZones, 1, -1 do
			local part = safeZones[i]
			if not part.Parent then
				table.remove(safeZones, i)
			else
				local cf = zoneShape(part)
				if cf then
					local point = Vector3.new(cf.Position.X, pos.Y, cf.Position.Z)
					local gap = (point - pos).Magnitude
					if not bestDist or gap < bestDist then best, bestDist = point, gap end
				end
			end
		end
		if not best then return nil end

		local y = groundAt(best, pos.Y)
		return y and Vector3.new(best.X, y, best.Z) or best
	end

	--[[
		Arena-wide, and therefore the kind a safe circle protects you from.

		A hundred studs was far too low a bar. The long sweeping lanes are two hundred studs
		end to end and are emphatically not covered by standing in a circle - but they were
		being written off as "the attack the safe zone saves you from" whenever anything
		with safe in its name was about, which is a dodge stepping calmly into a beam. Only
		the patterns that genuinely paint the whole floor qualify.
	]]
	local function hugeZone(d)
		if d.part then
			local size = d.part.Size
			return math.min(size.X, size.Z) >= 120 or math.max(size.X, size.Y, size.Z) >= 250
		end
		return (d.size and math.min(d.size.X, d.size.Z) >= 120) or ((d.radius or 0) >= 110)
	end

	local function zoneCounts(pos, d, margin, sheltered, ignore)
		if ignore and ignore[d] then return false end
		if sheltered and hugeZone(d) then return false end
		return inDanger(pos, d, margin)
	end

	local function anyDanger(pos, margin, ignore)
		local sheltered = #safeZones > 0 and inSafeZone(pos)
		for _, d in dangers do
			if zoneCounts(pos, d, margin, sheltered, ignore) then return true end
		end
		return false
	end

	-- How much of a hit a spot is, rather than whether it is one at all. With several
	-- overlapping attacks there is often nowhere fully clear, and the difference between
	-- standing in one and standing in three is the difference between living and not.
	local function dangerCount(pos, margin)
		local sheltered = #safeZones > 0 and inSafeZone(pos)
		local count = 0
		for _, d in dangers do
			if zoneCounts(pos, d, margin, sheltered) then count += 1 end
		end
		return count
	end

	local function dodgeTarget(pos)
		local now = workspace:GetServerTimeNow()
		for i = #dangers, 1, -1 do
			local d = dangers[i]
			if now > d.expire or not liveZone(d) then table.remove(dangers, i) end
		end
		if #dangers == 0 then return nil end

		--[[
			A barrage is mostly irrelevant to where we are standing.

			Some attacks fill the room with dozens of parts at once - the siege bot's green
			volley is the worst of them - and every one of those multiplies the cost of
			every spot considered. The ones far enough away to be no part of this decision
			are set aside for this pass rather than paid for; they are still tracked, and
			come back the moment they are near enough to matter.
		]]
		if #dangers > 45 then
			local ranked = {}
			for _, d in dangers do
				local centre = (d.cf and d.cf.Position) or d.pos or pos
				table.insert(ranked, { zone = d, gap = (centre - pos).Magnitude - (d.bound or 0) })
			end
			table.sort(ranked, function(a, b) return a.gap < b.gap end)

			local near = {}
			for index = 1, math.min(45, #ranked) do
				table.insert(near, ranked[index].zone)
			end
			dangers = near
		end

		local margin = 5
		if not anyDanger(pos, margin) then return nil end

		refreshBarriers()

		-- Flying needs no floor, and demanding one is why it never dodged: every candidate
		-- was thrown out for having nothing underneath it, which is the normal state of
		-- affairs when you are in the air.
		local needFooting = mode() ~= 'Fly'
		local room = currentRoom()

		--[[
			The nearest spot that is safe from everything, found by looking nearest first.

			Asking each zone where its own edge is answers the wrong question when several
			parts land at once: the way out of the first lane is usually well inside the
			second, so the dodge stepped from one attack into another and looked like it was
			not dodging at all. That is the case this is built for, since a pack of mages
			casting together is the normal state of a room rather than an edge case.

			So the whole question is "which reachable spot, clear of EVERY live part, is
			closest?" - and it is answered by generating candidates, sorting them by how far
			they are, and taking the first that survives. Sorted by distance means the first
			answer found is the best answer, so the search stops there rather than scoring a
			few hundred spots it will not use.

			Candidates are rings, plus the straight-out exit from each zone we are standing
			in: the shortest way out of a long lane is perpendicular to it and that direction
			is rarely on a ring.
		]]
		local candidates = {}

		local function offer(point)
			table.insert(candidates, {point = point, travel = (point - pos).Magnitude})
		end

		for _, d in dangers do
			if inDanger(pos, d, margin) then
				local cf, size, shape = nil, nil, nil
				if d.part then cf, size, shape = zoneShape(d.part) end

				if cf then
					-- Straight out of the nearest face, or straight away from the centre of
					-- a round one.
					local lp = cf:PointToObjectSpace(pos)
					local h = size * 0.5
					if shape == Enum.PartType.Block then
						local outX = (h.X + margin + CHARACTER_RADIUS + 2) * (lp.X >= 0 and 1 or -1)
						local outZ = (h.Z + margin + CHARACTER_RADIUS + 2) * (lp.Z >= 0 and 1 or -1)
						offer(cf:PointToWorldSpace(Vector3.new(outX, lp.Y, lp.Z)))
						offer(cf:PointToWorldSpace(Vector3.new(lp.X, lp.Y, outZ)))
					else
						local flat = Vector3.new(pos.X - cf.Position.X, 0, pos.Z - cf.Position.Z)
						local radius = math.max(size.X, size.Y, size.Z) * 0.5
						local away = flat.Magnitude > 0.1 and flat.Unit or Vector3.new(1, 0, 0)
						offer(Vector3.new(cf.Position.X, pos.Y, cf.Position.Z)
							+ away * (radius + margin + CHARACTER_RADIUS + 2))
					end
				end
			end
		end

		--[[
			Sampled finely enough to find the gaps, not just the way out.

			The patterns that matter most - a fan of long lanes, a ring of circles, a
			checkerboard - are mostly safe ground, in gaps a few studs wide between the
			parts. Sixteen directions on a ring steps over gaps like that entirely, and the
			only spots it does find are out past the whole pattern, which is the far side
			from whatever is casting. Closer rings and more directions per ring mean the gap
			between two lanes is offered as a candidate at all.
		]]
		for _, radius in { 6, 9, 13, 18, 24, 31, 40, 52, 66, 84 } do
			local samples = radius <= 13 and 16 or (radius <= 31 and 24 or 28)
			for i = 0, samples - 1 do
				local angle = (i / samples) * math.pi * 2
				offer(pos + Vector3.new(math.cos(angle), 0, math.sin(angle)) * radius)
			end
		end

		table.sort(candidates, function(a, b) return a.travel < b.travel end)

		--[[
			Somewhere less bad, when there is nowhere good.

			Several overlapping attacks frequently leave nowhere fully clear, and returning
			nothing means standing still in all of them - the worst of the options rather
			than the best. The least covered legal spot seen along the way is kept and used
			only if nothing clean turns up.
		]]
		--[[
			The zones we are already inside, which the way out has to cross.

			The path check used to reject any route that touched a zone at all - and every
			route out starts inside the zone being escaped, so every single one failed. Worse,
			a clean spot rejected that way was never kept as a fallback either, so the search
			came back empty and the dodge did not move. That was the whole of "barely dodges".
			Only zones we are not already in can make a path unsafe.
		]]
		local function escapingAt(m)
			local inside = {}
			for _, d in dangers do
				if inDanger(pos, d, m) then inside[d] = true end
			end
			return inside
		end

		--[[
			Rules that forbid where you are already standing are wrong, not strict.

			Standing on or beside a border part made every candidate "inside a barrier" or
			"crossing one", so nothing was ever legal. Likewise the room box: when the room
			the game says is current is not the one you are in, every spot was outside it.
			Both are only applied when you are properly inside what they describe.
		]]
		-- Only the border parts that could matter to a dodge from here.
		local nearBorders = {}
		for _, part in barrierParts do
			if part.Parent and (part.Position - pos).Magnitude - part.Size.Magnitude * 0.5 < 110 then
				table.insert(nearBorders, part)
			end
		end

		-- What we are fighting. Needed here as well as for scoring, because the room it
		-- stands in is the room the fight is in.
		local anchor = fightTarget and fightTarget.Parent and fightTarget.Position or nil

		local respectBorders = not insideBarrier(pos, 0, nearBorders)

		--[[
			The room is the arena, not merely wherever we happen to be standing.

			Bounding a dodge to the room only while already inside it meant that the instant
			one step carried us through the doorway, every rule about the room stopped
			applying - so the next dodge went further out, and the next further still. That
			is how the farm ends up in a corridor with the boss at full health: a sweeping
			attack is escaped most easily by leaving its reach entirely, and its reach ends
			outside the room.

			If the thing we are fighting is in the room, spots outside the room are not
			spots, whichever side of the doorway we are on.
		]]
		local respectRoom = room ~= nil
			and (inRoom(pos, room, 6) or (anchor ~= nil and inRoom(anchor, room, 6)))

		--[[
			Out of the attack and out of reach, not out of the attack and into the pack.

			The spot search knew about attacks and nothing else, so the nearest safe spot
			was regularly beside - or behind - the melee enemies that were chasing you,
			and the dodge delivered you straight to them. Enemies are a second kind of
			danger here: a spot has to be clear of attacks AND at least keep-distance from
			every enemy, and the way there must not carry you closer to one than you
			already are.

			When no spot manages both, the one with the most room from enemies wins among
			those clear of attacks, weighed against how far it is to walk.
		]]
		local bodies = {}
		for _, m in enemyCache do
			local part = m and m.Parent and enemyPart(m)
			local hum = part and m:FindFirstChildOfClass('Humanoid')
			if hum and hum.Health > 0 and (part.Position - pos).Magnitude < 120 then
				table.insert(bodies, part.Position)
			end
		end

		local keepClear = math.max(KeepDistance ~= nil and KeepDistance.Value or 0, 9)

		-- Spots that were chosen and could not be reached, forgotten after a few seconds.
		for i = #badSpots, 1, -1 do
			if os.clock() - badSpots[i].at > 4 then table.remove(badSpots, i) end
		end

		local function enemyGap(point)
			local nearest = math.huge
			for _, body in bodies do
				local dx, dz = body.X - point.X, body.Z - point.Z
				local gap = math.sqrt(dx * dx + dz * dz)
				if gap < nearest then nearest = gap end
			end
			return nearest
		end

		local startGap = enemyGap(pos)
		local pathGap = math.min(6, startGap)

		--[[
			Out of the attack, and still in the fight.

			Taking the nearest safe spot treats every direction as equal, and they are not:
			on a boss the free ground is nearly always the ground behind you, so the dodge
			walked out of the fight, every time - and the whole attack cycle got spent
			walking back in. Most boss patterns leave a gap that is closer to the boss than
			you are, and stepping into that one keeps you hitting it.

			So spots are scored rather than taken first-found: distance still counts, and
			ending further from the target than fighting range counts against a spot enough
			that an equally short step toward the boss beats one away from it. Once a safe
			spot exists, only spots a little closer or further are still worth considering,
			which keeps this from turning into a search of the whole room.
		]]
		local band = keepClear + 4
		local sheltered = #safeZones > 0 and inSafeZone(pos)

		-- One budget for the whole call, not one per pass: three passes each paying for
		-- eighty raycasts is what a dodge costing most of a frame looks like.
		local rays = 0

		local function search(useRoom, m, leash, needSight)
			local escaping = escapingAt(m)
			local fallback, fallbackCount = nil, dangerCount(pos, m)
			local detour = nil
			local roomy, roomyScore = nil, nil
			local best, bestScore, firstClear = nil, nil, nil

			for _, candidate in candidates do
				local point = candidate.point

				--[[
					A safe spot is in hand; how much further to keep looking.

					Sixteen studs was too tight whenever there was something to fight. The
					gap that keeps you on the boss is regularly on the far side of the lane
					you are standing in - a longer walk than the step backwards out of it,
					and the better move by a wide margin. With nothing to fight there is
					nothing to weigh against distance, so the tight window stands.
				]]
				if best and candidate.travel > firstClear + (anchor and 42 or 16) then break end

				local stale = false
				for _, bad in badSpots do
					if (bad.pos - point).Magnitude < 5 then stale = true break end
				end

				--[[
					Still in the fight, not merely out of the fire.

					Safety alone is maximised by leaving the arena, and on a boss that is
					exactly what it did: the far corner is always the clearest ground on the
					map. A dodge is a step within the fight, so spots are held to a radius of
					what we are fighting; only the final, desperate pass drops the leash.
				]]
				if not stale and leash and anchor and (point - anchor).Magnitude > leash then
					stale = true
				end

				-- Standing in the one circle the attack cannot reach: every step out of it
				-- is a step into the attack, however clear that ground looks.
				if not stale and sheltered and not inSafeZone(point) then
					stale = true
				end

				-- Attacks first, because they are the cheapest test that rejects most
				-- candidates; borders, room and the ground ray only for what survives.
				--[[
					Clear means clear by the margin being asked for, and no more.

					It used to demand the margin AND another three studs on top, which with
					the character's own width is about ten studs of empty floor in every
					direction. A fan of beams leaves gaps a good deal narrower than that, so
					every gap in the pattern read as unsafe and the only spots that passed
					were outside the whole fan - which is down the length of the beams, and
					is exactly the wrong way to run.
				]]
				local covered = stale and math.huge or dangerCount(point, m)
				local clear = covered == 0

				if (clear or covered < fallbackCount)
					and (not respectBorders or (not insideBarrier(point, 2, nearBorders)
						and not crossesBarrier(pos, point, nearBorders)))
					and (not useRoom or inRoom(point, room, 6)) then

					-- A spot with no floor under it is not a spot. This used to fall back
					-- to the height it was sampled at, which accepted ledges and gaps.
					local y
					if needFooting then
						-- Rays are the one expensive thing in here. Once a safe spot is in
						-- hand, stop paying for more of them; without one, keep looking,
						-- since an answer matters more than the frame it costs.
						if rays >= 110 and best then break end
						rays += 1
						y = groundAt(point, pos.Y)
					else
						y = point.Y
					end

					if y then
						local grounded = Vector3.new(point.X, y, point.Z)
						-- Behind a wall is not a spot: the step would clip into the wall, and
						-- the server pulls you back for arriving somewhere you could not walk.
						--[[
							A spot you cannot see the boss from is not a dodge, it is hiding.

							The room's bounds are the whole room model, doorway and entry
							corridor included, so "inside the room" still allowed the spot
							behind the door frame - and a sweeping attack is escaped most
							cheaply by stepping behind something solid. From there nothing
							can be hit and the fight never ends.

							Requiring sight of what we are fighting rules out every one of
							those: behind the pillar, through the doorway, round the corner.
						]]
						local reachable_ = clearLine(pos, grounded)
						if reachable_ and needSight and anchor then
							rays += 1
							reachable_ = clearLine(grounded, anchor)
						end

						if clear and reachable_ then
							--[[
								Sampled by distance, not in quarters.

								Four samples over a forty stud dodge is one test every ten
								studs, and a lane six studs wide fits between two of them
								without being noticed - so the route was declared clear and
								walked straight through the attack. Every few studs closes
								that, and short dodges cost no more than before.
							]]
							local span = (grounded - pos).Magnitude
							local steps = math.clamp(math.floor(span / 3), 3, 14)
							local safePath = true
							for step = 1, steps do
								local sample = pos:Lerp(grounded, step / steps)
								if anyDanger(sample, m, escaping) or enemyGap(sample) < pathGap then
									safePath = false
									break
								end
							end

							local gap = enemyGap(grounded)
							if safePath and gap >= keepClear then
								local score = candidate.travel
								if anchor then
									-- Only being too far is penalised. Closing on the boss is
									-- free, which is what turns a retreat into a sidestep in.
									local reach = (grounded - anchor).Magnitude
									score += math.max(0, reach - band) * 1.6
								end
								if not bestScore or score < bestScore then
									best, bestScore = grounded, score
									firstClear = firstClear or candidate.travel
								end
							end

							if safePath then
								local score = candidate.travel - math.min(gap, keepClear) * 3
								if not roomyScore or score < roomyScore then
									roomy, roomyScore = grounded, score
								end
							end
							-- Clear at the end but not on the way: still far better than
							-- staying, so it is kept rather than thrown away.
							detour = detour or grounded
						elseif not clear and reachable_ and covered < fallbackCount then
							fallback, fallbackCount = grounded, covered
						end
					end
				end
			end

			if best then return best, true end
			--[[
				A detour is the last thing to try, not the second.

				A detour is a spot that is clear when you arrive but whose route crosses an
				attack on the way - which is walking through the fire to stand beyond it, and
				from outside it looks exactly like dodging INTO an attack. The least-covered
				spot is always a genuine improvement on standing still, so it comes first.
			]]
			return roomy or fallback or detour, false
		end

		--[[
			A comfortable gap if there is one, a usable gap if there is not.

			Asking for one clearance and giving up is what sent the dodge out of the pattern
			instead of into it. A wide berth is worth having when the floor is mostly empty,
			but between two beams there is no wide berth to be had - and standing in the
			beam because the gap was three studs too narrow is not the better answer.

			So the same search is run again with less room demanded each time, and the first
			pass that finds anything wins. The last pass asks only for the character's own
			width and a little, which is what actually fits between two lanes.
		]]
		--[[
			Two passes, then one that gives up the rules.

			Each pass costs a sweep of every candidate, so three graded margins plus the
			relaxations was up to four sweeps for one dodge - at ten dodges a second while a
			boss casts, that is the frame rate. A comfortable berth and a tight one cover
			nearly every case between them.
		]]
		local spot
		for _, m in { margin, 2 } do
			local found, clean = search(respectRoom, m, 40, true)
			if clean then return found end
			spot = spot or found
		end

		-- Nothing fits the rules, so they come off: sight of the boss first, then the
		-- leash, then the room itself.
		local found, clean = search(respectRoom, 1.5, nil, false)
		if clean then return found end
		spot = spot or found

		if respectRoom then
			local wider, widerClean = search(false, 1.5, nil, false)
			if widerClean then return wider end
			spot = spot or wider
		end
		return spot
	end

	-- storage items may store a field as a plain value or as {Value=x}.
	local function fv(item, key)
		local v = item[key]
		if type(v) == 'table' and v.Value ~= nil then v = v.Value end
		return v
	end

	local function equippedWeapon(char)
		for _, c in char:GetChildren() do
			if c:IsA('Accessory') and c:FindFirstChild('Weapon') then return c end
		end
	end
	local function swing(char, weaponUsed)
		local w = equippedWeapon(char)
		if not w then return end
		local rem = w:FindFirstChildOfClass('RemoteEvent')
		if rem then rem:FireServer() end
		if weaponUsed then weaponUsed:FireServer() end
	end
	--[[
		Whether there is anything to cast at all.

		The farm holds its distance and fights with abilities, so "is one off cooldown"
		decides whether standing back is fighting or just standing. Asked before closing to
		weapon range rather than after, which is the whole point of the rework.
	]]
	-- Four of them, not two: the game has a second pair of ability slots, q2 and e2, and
	-- every part of this only ever looked at the first pair - so half of an equipped
	-- loadout was never cast at all.
	local ABILITY_SLOTS = { 'q', 'e', 'q2', 'e2' }

	local function abilityReady()
		for _, child in lplr.Backpack:GetChildren() do
			local slot = child:FindFirstChild('abilitySlot')
			if slot and table.find(ABILITY_SLOTS, slot.Value) then
				local cd = child:FindFirstChild('cooldown')
				if not (cd and cd.Value > 0) then return true end
			end
		end
		return false
	end

	--[[
		Pointed at what is being fought, rather than at whatever is nearest.

		Swings and abilities both fire along the character's look vector, and the nearest
		body is regularly not the one being fought - the farm holds its distance now, so
		something else wandering closer would have taken every cast with it.

		Horizontal only: a Humanoid is force-kept upright, so pitching the root just makes
		it fight our CFrame every frame.
	]]
	local function faceTarget(hrp, part)
		if not (hrp and part) then return end
		local flat = Vector3.new(part.Position.X, hrp.Position.Y, part.Position.Z)
		if (flat - hrp.Position).Magnitude < 0.5 then return end
		hrp.CFrame = CFrame.lookAt(hrp.Position, flat)
	end

	local function castAbilities(abilityUsed)
		--[[
			The game's own ability scripts reach for Character.Humanoid by name and without
			waiting, so firing one during a respawn - character parented, humanoid not yet -
			throws inside their code rather than ours. It happens on its own often enough to
			appear before Vain has even loaded, but there is no reason to add to it.

			Checked by name rather than by class for the same reason: that is the lookup
			their script actually performs.
		]]
		local char = lplr.Character
		if not (char and char:FindFirstChild('Humanoid') and char:FindFirstChild('HumanoidRootPart')) then
			return
		end

		for _, slot in ABILITY_SLOTS do
			for _, child in lplr.Backpack:GetChildren() do
				if child:FindFirstChild('abilitySlot') and child.abilitySlot.Value == slot then
					local cd = child:FindFirstChild('cooldown')
					if not (cd and cd.Value > 0) then
						local le = child:FindFirstChild('localEvent')
						if le then le:Fire() end
						if abilityUsed then abilityUsed:FireServer(slot, child) end
					end
					break
				end
			end
		end
	end

	-- cached list of enemy models (non-player Humanoids), refreshed periodically.
	--[[
		The folders enemies actually live in, found once instead of hunted for constantly.

		This used to walk every descendant of the workspace, twice a second, to find the
		humanoids. A dungeon streams its rooms in as you clear them, so that walk starts at
		a few thousand instances and ends at a hundred thousand - the farm ran well at the
		start of a run and progressively worse the further it got, which is exactly the lag
		that shows up by the boss.

		Enemies are always under a folder called enemyFolder, and there is one per room, so
		finding those folders once and reading their contents is the same answer for a
		thousandth of the work.
	]]
	local enemyFolders, enemyFolderScan = {}, 0

	local function refreshEnemyFolders()
		if os.clock() - enemyFolderScan < 4 and #enemyFolders > 0 then return end
		enemyFolderScan = os.clock()

		local found = {}
		local function collect(root, depth)
			if not root or depth > 2 then return end
			for _, child in root:GetChildren() do
				if child.Name == 'enemyFolder' then
					table.insert(found, child)
				elseif child:IsA('Folder') or child:IsA('Model') then
					collect(child, depth + 1)
				end
			end
		end

		collect(workspace:FindFirstChild('dungeon'), 1)
		for _, child in workspace:GetChildren() do
			if child.Name == 'enemyFolder' then table.insert(found, child) end
		end
		enemyFolders = found
	end

	local function rescan()
		enemyCache = {}
		refreshEnemyFolders()

		pcall(function()
			for _, folder in enemyFolders do
				if folder.Parent then
					for _, d in folder:GetDescendants() do
						if d:IsA('Humanoid') and d.Health > 0 then
							local m = d.Parent
							if m and m:IsA('Model') and enemyPart(m)
								and not playersService:GetPlayerFromCharacter(m) then
								table.insert(enemyCache, m)
							end
						end
					end
				end
			end
		end)
		lastScan = os.clock()
	end
	--[[
		Whether there is anything solid in the way.

		The nearest enemy by straight line is often one in the next room, behind a barrier
		the dungeon has not opened yet - so the farm would walk into a wall and stand there
		while the room it was actually in went unfought. Bodies are excluded from the check,
		since a mob standing between us and another mob is not an obstruction, and the
		telegraph parts exclude themselves by being unqueryable.
	]]
	local reachParams = RaycastParams.new()
	reachParams.FilterType = Enum.RaycastFilterType.Exclude

	local function reachable(from, part)
		local skip = {lplr.Character}
		for _, m in enemyCache do
			if m and m.Parent then table.insert(skip, m) end
		end
		reachParams.FilterDescendantsInstances = skip
		return workspace:Raycast(from, part.Position - from, reachParams) == nil
	end

	--[[
		Where the room actually is, taken from where its enemies stand.

		A room model's pivot is the centre of everything in it, barrier and scenery
		included, which can sit inside a wall. The spawn points are by definition places
		the game puts something that has to be reachable.
	]]
	local function roomPoint(room)
		local total, count = Vector3.zero, 0
		for _, d in room:GetDescendants() do
			if d:IsA('BasePart') and d.Name == 'spawn' then
				total += d.Position
				count += 1
			end
		end
		if count > 0 then return total / count end

		local ok, pivot = pcall(function() return room:GetPivot().Position end)
		return ok and pivot or nil
	end

	--[[
		Still shut, and therefore still the room to be in.

		Whether the game destroys a cleared room's barrier or only lets you through it is
		not something the place file answers, so this treats both as closed: gone counts
		as open, and so does one left standing with nothing solid in it.
	]]
	local function roomLocked(room)
		local barrier = room:FindFirstChild('barrier')
		if not barrier then return false end
		for _, d in barrier:GetDescendants() do
			if d:IsA('BasePart') and d.CanCollide then return true end
		end
		return false
	end

	--[[
		Room by room, in the order the game numbers them.

		This used to pick whichever room was furthest from where the run started and walk
		at it, which is the boss room from the first second - so it spent the run pressed
		against the barriers of rooms it had not cleared yet, and the fallback for being
		stuck was to head twenty studs forward.

		Every room carries an order and its own barrier. The room to be in is the lowest
		numbered one still shut; everything below it is done and everything above is not
		open yet. When they are all open the only thing left is the boss.
	]]
	--[[
		The room being fought, by the game's own numbering.

		Rooms cannot be told apart by name: a Desert Temple run has two separate Instances
		both called room6, at different places and different orders. The order value and
		the Instance are the identity.
	]]
	local function findCurrentRoom()
		local dungeon = workspace:FindFirstChild('dungeon')
		if not dungeon then return nil end

		local rooms = {}
		for _, room in dungeon:GetChildren() do
			local order = room:FindFirstChild('order')
			if order and order:IsA('IntValue') then
				table.insert(rooms, {room = room, order = order.Value})
			end
		end
		table.sort(rooms, function(a, b) return a.order < b.order end)

		for _, entry in rooms do
			if roomLocked(entry.room) then return entry.room end
		end

		--[[
			Every room open means the boss room is the room.

			Returning nothing here is why boss fights went wrong: with no room, the dodge had
			no bounds at all, so the safest ground it could find was out through the doorway
			and behind the wall - and having gone there it kept dodging the lanes that reach
			outside instead of walking back in. The boss sat at full health while the farm
			stood in a corridor.
		]]
		return dungeon:FindFirstChild('bossRoom')
	end

	--[[
		Remembered briefly, because it is asked constantly.

		Working out the room walks every room and every barrier part in each, and the
		dodge and the farm both ask several times a second. A room opens once a fight at
		most, so half a second stale costs nothing.
	]]
	local roomCache, roomCachedAt = nil, 0

	function currentRoom()
		if os.clock() - roomCachedAt > 0.5 or (roomCache and not roomCache.Parent) then
			roomCache, roomCachedAt = findCurrentRoom(), os.clock()
		end
		return roomCache
	end

	--[[
		Whether something is in this room, from the room's own bounds. Neighbouring rooms
		overlap slightly at the doorway, which only matters for something standing in it.

		The bounds are kept per room. Measuring a whole room model is expensive, and the
		dodge search used to do it once for every candidate spot - a few hundred times per
		dodge - which is a large part of why dodging dragged the frame rate down with it.
	]]
	local roomBoxes = setmetatable({}, {__mode = 'k'})

	function inRoom(position, room, margin)
		if not room then return true end

		local box = roomBoxes[room]
		if not box or os.clock() - box.at > 5 then
			local ok, cf, size = pcall(function() return room:GetBoundingBox() end)
			if not ok or not cf then return true end
			box = {cf = cf, size = size, at = os.clock()}
			roomBoxes[room] = box
		end

		margin = margin or 0
		local offset = box.cf:PointToObjectSpace(position)
		return math.abs(offset.X) <= box.size.X * 0.5 + margin
			and math.abs(offset.Z) <= box.size.Z * 0.5 + margin
	end

	--[[
		One room, one group at a time.

		This used to consider every enemy in the dungeon and take the closest, falling back
		to one it could not even reach. In a map whose rooms are 250 to 300 studs across
		and whose enemies stand in four separate clusters of four to eight, that means
		walking the length of a room at something on the far side, through two other
		clusters on the way, and pulling all of them. It also meant chasing things in the
		next room before this one was finished.

		Enemies outside the room being fought are ignored, so a room is left only when it
		is genuinely empty. Within the room it stays on the cluster it started - anything
		within 25 studs of the current target, the spacing the clusters actually separate
		at - until that cluster is dead, rather than drifting to whichever enemy happens
		to be nearest this frame.
	]]
	local CLUSTER = 25
	local engaged

	local function nearestEnemy(pos, room)
		if os.clock() - lastScan > 1.5 or #enemyCache == 0 then rescan() end

		local best, bestPart, bestDist
		local anyBest, anyPart, anyDist
		local engagedAlive = false

		for i = #enemyCache, 1, -1 do
			local m = enemyCache[i]
			local hum = m and m.Parent and m:FindFirstChildOfClass('Humanoid')
			local part = m and enemyPart(m)
			if not (m and m.Parent and hum and hum.Health > 0 and part) then
				if m == engaged then engaged = nil end
				table.remove(enemyCache, i)
			elseif inRoom(part.Position, room, 10) then
				if m == engaged then engagedAlive = true end

				local dist = (part.Position - pos).Magnitude
				-- Sticking with the group already pulled rather than the closest body.
				if engaged and engaged.Parent then
					local anchor = enemyPart(engaged)
					if anchor and (part.Position - anchor.Position).Magnitude > CLUSTER then
						continue
					end
				end

				if not anyDist or dist < anyDist then anyBest, anyPart, anyDist = m, part, dist end
				if (not bestDist or dist < bestDist) and reachable(pos, part) then
					best, bestPart, bestDist = m, part, dist
				end
			end
		end

		-- The group is down, so the next call is free to pick a fresh one.
		if engaged and not engagedAlive then engaged = nil end

		local pick, pickPart, pickDist = best, bestPart, bestDist
		if not pick then pick, pickPart, pickDist = anyBest, anyPart, anyDist end
		if pick and not engaged then engaged = pick end
		return pick, pickPart, pickDist
	end

	--[[
		Everything nearby, not just the one being hit.

		Spacing worked off the nearest enemy alone, so the strafe circle happily carried us
		through the other four standing around it - the one we were fighting was at a
		polite distance the whole way, and the rest were not considered at all.

		This adds up a push away from every enemy inside the keep distance, weighted by how
		close each one is, so a crowd shoves harder than a straggler and the way out points
		away from the crowd rather than away from whoever happens to be nearest.
	]]
	local function crowding(pos, keep)
		local push, count = Vector3.zero, 0
		for _, m in enemyCache do
			local part = m and m.Parent and enemyPart(m)
			if part then
				local away = (pos - part.Position) * Vector3.new(1, 0, 1)
				local distance = away.Magnitude
				if distance > 0.1 and distance < keep then
					push += away.Unit * ((keep - distance) / keep)
					count += 1
				end
			end
		end
		return push, count
	end

	-- Which way round is clearer. Circling into the rest of the pack is worse than
	-- circling away from it, so the two directions are compared before one is committed to.
	local function clearestTangent(pos, centre, tangent, ideal)
		local best, bestScore
		for _, dir in {1, -1} do
			local probe = centre + ((pos - centre) * Vector3.new(1, 0, 1)).Unit * ideal + tangent * dir * 14
			local _, crowded = crowding(probe, ideal)
			if not bestScore or crowded < bestScore then best, bestScore = dir, crowded end
		end
		return best or 1
	end

	--[[
		Walking, and only walking.

		Short hops are handed straight to the humanoid, which is what a player holding a
		key produces. Anything further, or anything the humanoid has stopped making
		progress towards, is routed through the game's own pathfinder so corridors, stairs
		and doorways are followed rather than walked into.

		The path is recomputed sparingly: enemies move, and rebuilding a route every tick
		costs more than it corrects.
	]]
	--[[
		Circling, rather than standing and taking it.

		Standing still inside attack range is what the red lanes are for: they are aimed
		where you are when the cast starts, and a stationary target is already standing in
		the answer. Walking a circle around the enemy instead means the lane lands behind
		you without anything having to notice it, keeps melee from settling into reach, and
		costs nothing - abilities fire on their own timer regardless of where the feet are.

		The direction is held for a few seconds at a time rather than chosen fresh each
		tick, since flipping constantly is how you end up jittering on the spot instead of
		actually going round.
	]]
	local strafeDir, strafeUntil = 1, 0

	--[[
		Moving in steps instead of asking the humanoid to walk.

		What the server objects to is arriving somewhere you could not have walked to, not
		the CFrame write itself - the old farm was pulled back for crossing a room in one
		frame, never for writing a position. So each step is capped at whatever your own
		WalkSpeed would have covered in the time since the last one, which produces exactly
		the studs per second a walking player produces.

		The gain over MoveTo is control: it goes precisely where it is sent, holds a strafe
		circle properly, and cannot be talked out of it by a humanoid that has decided to
		path somewhere else or to stop.

		Height is taken from the ground under the destination rather than carried across,
		so steps follow stairs and slopes instead of walking into them at knee height.
	]]
	local function stepTo(hrp, hum, goal, avoid)
		--[[
			Never walked back into what was just escaped.

			The dodge stepped out, handed control back, and the farm's very next move was
			straight back toward the enemy - through the zone - so it stood on the edge of
			the attack and took it anyway. Ordinary movement now refuses a step that would
			enter a live attack from outside one. The dodge itself passes no avoid, since
			its path is already planned through the zones it is escaping.
		]]
		local function blocked(point)
			if not avoid or #dangers == 0 then return false end
			if anyDanger(hrp.Position, 1) then return false end
			return anyDanger(point, 1)
		end

		-- A border is the anti-cheat's wall; walking onto one is being pulled back. Ignored
		-- while already standing on one, since then every direction would be refused.
		local function borderBlocked(point)
			if #barrierParts == 0 then return false end
			if insideBarrier(hrp.Position, 0) then return false end
			return insideBarrier(point, 1)
		end

		local function refused(point)
			return blocked(point) or wallBetween(hrp.Position, point) or borderBlocked(point)
		end

		local now = os.clock()
		local dt = math.clamp(now - lastStep, 0, 0.3)
		lastStep = now

		--[[
			Flying, which is the same move without the floor.

			Every awkward thing in this function exists because a walker needs somewhere to
			put its feet: ledges to refuse, corners to slide around, steps to shorten. None
			of that applies in the air, so the goal is simply travelled towards in three
			dimensions - including up to an enemy standing above you - at exactly the pace a
			walk would have covered. The distance per second the server sees is unchanged;
			only the need for ground beneath it goes away.
		]]
		if mode() == 'Fly' then
			local direct = goal - hrp.Position
			local range = direct.Magnitude
			if range < 0.5 then return end

			local speed = (hum.WalkSpeed > 0 and hum.WalkSpeed or 16)
			local travel = math.min(range, speed * dt)
			if refused(hrp.Position + direct.Unit * travel) then return end
			hrp.CFrame = CFrame.new(hrp.Position + direct.Unit * travel)
				* (hrp.CFrame - hrp.CFrame.Position)
			hrp.AssemblyLinearVelocity = Vector3.zero
			return
		end

		local delta = (goal - hrp.Position) * Vector3.new(1, 0, 1)
		local distance = delta.Magnitude
		if distance < 0.5 then return end

		-- Your own walk speed, which is the pace the server expects to see covered.
		local speed = (hum.WalkSpeed > 0 and hum.WalkSpeed or 16)
		local full = math.min(distance, speed * dt)
		local direction = delta.Unit

		--[[
			Every move leaves through here, and none of them may travel further than a walk.

			The budget used to cover the horizontal part only, while height was allowed to
			change by whatever the ground demanded - so stepping onto a ledge moved twelve
			studs upward in a single tick. The server measures the whole displacement, that
			is nothing a walking player produces, and it pulled us straight back.

			Clamping the finished vector keeps a climb honest: the same distance per second
			whether it is spent going along or going up, so a step onto a ledge simply takes
			a few ticks instead of one.
		]]
		--[[
			Height budgeted apart from distance, not out of it.

			Clamping the combined vector meant any change in height came out of the forward
			travel: on ground that is not perfectly flat - which is most of a dungeon - a
			step that rose even slightly moved less far along, every single time. That is
			the slowdown, and it got worse the rougher the floor.

			A walking player does not slow down on a ramp, so neither does this. Distance
			along the ground keeps the whole budget, and height gets a budget of its own,
			which is what stops a ledge being taken in one jump without taxing every
			ordinary step for it.
		]]
		local function place(desired)
			local flat = (desired - hrp.Position) * Vector3.new(1, 0, 1)
			if flat.Magnitude > full then
				flat = flat.Unit * full
			end

			local rise = math.clamp(desired.Y - hrp.Position.Y, -full, full)
			hrp.CFrame = CFrame.new(hrp.Position + flat + Vector3.new(0, rise, 0))
				* (hrp.CFrame - hrp.CFrame.Position)
		end

		--[[
			Around an obstruction rather than into it.

			Shortening the step when the way ahead had no floor meant every awkward corner
			cost most of the pace - a third of a step, taken ten times a second, is a crawl,
			and it is why dodges felt slow even though the budget was right.

			So the direction is tried either side first, at full length, which walks around
			a corner instead of edging up to it. Shortening stays as the last resort for
			somewhere genuinely tight.
		]]
		for _, turn in {0, 0.4, -0.4, 0.9, -0.9, 1.5, -1.5} do
			local aim = turn == 0 and direction or (CFrame.Angles(0, turn, 0) * direction)
			local target = hrp.Position + aim * full
			local y = groundAt(target, hrp.Position.Y)
			if y and not refused(Vector3.new(target.X, y, target.Z)) then
				place(Vector3.new(target.X, y, target.Z))
				return
			end
		end

		for _, fraction in {0.6, 0.3} do
			local target = hrp.Position + direction * (full * fraction)
			local y = groundAt(target, hrp.Position.Y)
			if y and not refused(Vector3.new(target.X, y, target.Z)) then
				place(Vector3.new(target.X, y, target.Z))
				return
			end
		end

		if refused(hrp.Position + direction * (full * 0.5)) then return end

		--[[
			Nothing underfoot anywhere along the way, so climb toward where we are going.

			Refusing to move at all was the safe answer and the wrong one: it is what left
			the farm announcing a dodge every tick and never taking it, because the spot it
			had chosen was up a step, across a gap, or on a platform above. Following the
			destination's own height instead means a ledge can be climbed onto and a fall
			can be climbed out of, and it is bounded by the same per-tick budget as any
			other step so it stays a walk rather than a leap.
		]]
		local target = hrp.Position + direction * (full * 0.5)

		--[[
			Even here there has to be something out there.

			This branch exists to climb a step the strict check refused, and it was the one
			path in this function that never asked whether there was a floor at all - which
			made it the way the farm walked off ledges. The search is deliberately deep,
			because the whole point is to reach ground the ordinary limits called too far;
			but no ground whatsoever means open air, and open air is a fall.
		]]
		--[[
			For climbing only, which is the whole reason this branch exists.

			It was reaching four hundred studs down for something to stand on, and over a
			pit it found the bottom of the pit - so it stepped out into the gap and fell.
			A destination that is not above us and has no footing is not a step up, it is
			a hole, and the answer to a hole is to stay where you are.
		]]
		if goal.Y <= hrp.Position.Y + 1 then return end

		groundParams.FilterDescendantsInstances = {lplr.Character}
		local below = workspace:Raycast(target + Vector3.new(0, 12, 0), Vector3.new(0, -MAX_DROP, 0), groundParams)
		if not below then return end

		local rise = math.clamp(goal.Y - hrp.Position.Y, -full, full)
		place(Vector3.new(target.X, hrp.Position.Y + rise, target.Z))
	end

	--[[
		One way in, so every branch below moves the same way and the setting decides how.

		Walking needs the extra care. MoveTo restarts the humanoid's walk from scratch every
		time it is called, so issuing one ten times a second - which is what strafing and
		dodging do, since both recompute their destination each tick - left it forever
		beginning a walk and never taking it. Only a goal that has actually moved is worth
		reissuing, and that is the difference between the two modes dodging and only one.
	]]
	--[[
		Stepping runs on its own clock.

		Movement used to happen once per farm tick, which is ten times a second - each step
		a tenth of a walk, taken as a jump. That is visibly coarse, and whenever a step was
		shortened it was genuinely slower than walking too. Where to go is still decided on
		the farm tick; getting there is left to a heartbeat, which covers the same ground
		per second in sixty small pieces rather than ten large ones.
	]]
	local moveGoal, moveSetAt = nil, 0

	--[[
		Kept fresh, both ways.

		Walking only reissued the order when the destination had moved more than a few
		studs, which sounds thrifty and is why it stood still: a strafe circle at a fixed
		radius rarely moves its target that far, so the humanoid finished the walk it had
		been given and was never given another. Reissuing on a timer as well fixes that,
		and costs nothing - MoveTo to where you are already heading is free.

		Flying and stepping had the mirror image. The destination is set by the farm tick
		and acted on by the heartbeat, so a tick that sets nothing leaves the heartbeat
		flying at whatever it was told last - which is how it ended up hovering over the
		spot where something used to be. A destination nobody has renewed is dropped.
	]]
	local lastGoal, lastIssued = nil, 0

	local function goTo(hum, hrp, goal)
		-- While attacks are live, even Walk mode moves by steps: the humanoid walks
		-- wherever it is sent with no idea what is on the floor, and stepping is the one
		-- movement that can refuse a step into an attack.
		if moving() or #dangers > 0 then
			if not moving() and lastGoal then
				hum:MoveTo(hrp.Position)
				lastGoal = nil
			end
			moveGoal, moveSetAt = goal, os.clock()
			return
		end
		moveGoal = nil

		local now = os.clock()
		if not lastGoal or (goal - lastGoal).Magnitude > 4 or now - lastIssued > 0.25 then
			lastGoal, lastIssued = goal, now
			hum:MoveTo(goal)
		end
	end

	--[[
		The route, kept between uses.

		It used to be built inline, which blocks: ComputeAsync yields, and the whole farm
		waited on it - no fighting, no movement - every time. Being rebuilt every three
		seconds, whenever the target moved, and thrown away whenever the farm strafed or
		backed off, that wait came round constantly. That is the "randomly stopping".

		Now it is worked out in the background while the old route keeps being followed,
		and stepping aside no longer discards it.
	]]
	local nav = {
		goal = nil, waypoints = nil, index = 1,
		builtAt = 0, building = false, failedAt = 0,
		lastPos = nil, movedAt = 0, calledAt = 0, resync = false,
	}

	local function clearPath()
		-- Kept, not discarded: stepping aside to strafe or dodge and carrying on to the
		-- same place is the normal case. It is only re-found on the route when resumed.
		nav.resync = true
	end

	local function snapToFloor(point)
		refreshSkip()
		local hit = workspace:Raycast(point + Vector3.new(0, 8, 0), Vector3.new(0, -60, 0), footParams)
		return hit and hit.Position or point
	end

	local function buildPath(from, goal)
		-- A build that never finished used to block every build after it for the rest of
		-- the run, which is a farm that stops pathing and stands still. It cannot wait
		-- longer than this, so after that it is treated as gone.
		if nav.building and os.clock() - nav.builtAt < 4 then return end
		nav.building, nav.builtAt = true, os.clock()

		task.spawn(function()
			--[[
				Sized for the doorways this game actually has.

				A three-stud radius does not fit through plenty of them, so the route came
				back as no route at all - and the fallback for that was to walk straight at
				the goal, through whatever wall was in the way.
			]]
			local path = pathfindingService:CreatePath({
				AgentRadius = 2,
				AgentHeight = 5,
				AgentCanJump = true,
				AgentCanClimb = false,
				WaypointSpacing = 6,
			})

			local function try(start, finish)
				local ok = pcall(path.ComputeAsync, path, start, finish)
				local points = ok and path:GetWaypoints() or {}
				return #points >= 2 and points or nil
			end

			-- Whatever happens in here, the build is over when this thread is: an error
			-- that left it marked as still running would stop the farm pathing for good.
			local ok, points = pcall(function()
				local target = snapToFloor(goal)
				-- A goal on an enemy or a spawn marker can read as occupied, and a start
				-- inside a slope as blocked; nudging up answers both. Failing that, half the
				-- way there is still progress, and the rest is found from wherever that ends.
				return try(from, target)
					or try(from + Vector3.new(0, 2, 0), target)
					or try(from, snapToFloor(from:Lerp(goal, 0.5)))
			end)
			if not ok then points = nil end

			nav.building = false
			if points then
				nav.waypoints, nav.index, nav.goal, nav.failedAt = points, 2, goal, 0
			else
				nav.waypoints, nav.goal, nav.failedAt = nil, goal, os.clock()
			end
		end)
	end

	--[[
		Walking a route, whichever way the feet are moving.

		Stepping used to skip pathfinding entirely and head straight at the goal, which is
		why Step TP walked into walls: told to reach an enemy in the next room it aimed
		through the wall between, the step refused every candidate against solid geometry,
		and it ground along the wall for as long as that enemy lived. Flying is the one mode
		that genuinely does not need a route, since nothing is in its way.

		So a route is built for walking and stepping alike, and the only difference is who
		is handed the waypoint: the humanoid, or the stepper.
	]]
	local function walkTo(hum, hrp, goal)
		local pos = hrp.Position
		local now = os.clock()
		refreshBarriers()

		--[[
			Progress is getting nearer, not merely moving.

			Measuring raw movement calls a character sliding along the face of a crate
			"moving", so the stuck check never fired and it scraped along the object
			indefinitely. What matters is whether the distance to where we are going is
			actually coming down.
		]]
		local flatGap = (Vector3.new(goal.X, 0, goal.Z) - Vector3.new(pos.X, 0, pos.Z)).Magnitude
		if now - nav.calledAt > 0.5 or not nav.lastGap or flatGap < nav.lastGap - 1.5 then
			nav.lastGap, nav.movedAt = flatGap, now
		end
		nav.calledAt = now
		local stuck = now - nav.movedAt > 1.5

		local pathing = UsePathfinding == nil or UsePathfinding.Enabled
		local open = clearLine(pos, goal, true)

		--[[
			Straight there only when straight there is actually open.

			"Close enough to walk at" used to be judged by distance alone, so an enemy
			twenty studs away on the other side of a wall was walked at, into the wall,
			for as long as it lived. Line of sight is the question that matters.
		]]
		if (open and not stuck) or not pathing then
			if stuck and not moving() then hum.Jump = true end
			goTo(hum, hrp, goal)
			return
		end

		local wps = nav.waypoints
		local goalMoved = not nav.goal or (nav.goal - goal).Magnitude > 10
		local finished = wps ~= nil and nav.index > #wps
		local wait = stuck and 0.4 or (nav.failedAt > 0 and 1.5 or 0.6)
		if (not wps or goalMoved or finished or stuck) and now - nav.builtAt > wait then
			buildPath(pos, goal)
			-- A fresh route gets a fair chance before it too is called stuck.
			if stuck then nav.movedAt = now end
		end

		--[[
			Wedged, and a new route will not help.

			Pressed into a corner or the side of an object, every route out starts with the
			step that is being refused, so rebuilding produces the same answer and it stays
			there. Stepping deliberately sideways breaks the contact, and from a stud to the
			left the route that exists becomes walkable again.
		]]
		if stuck and now < (nav.sidestepUntil or 0) and nav.sidestep then
			goTo(hum, hrp, nav.sidestep)
			return
		end

		if stuck and now - (nav.sidestepAt or 0) > 2 then
			local ahead = Vector3.new(goal.X - pos.X, 0, goal.Z - pos.Z)
			ahead = ahead.Magnitude > 0.1 and ahead.Unit or hrp.CFrame.LookVector
			local side = Vector3.new(-ahead.Z, 0, ahead.X)

			for _, dir in { 1, -1 } do
				local probe = pos + side * (12 * dir)
				local y = groundAt(probe, pos.Y)
				if y and clearLine(pos, probe, true) and not insideBarrier(probe, 1) then
					nav.sidestep = Vector3.new(probe.X, y, probe.Z)
					nav.sidestepUntil, nav.sidestepAt = now + 0.6, now
					if not moving() then hum.Jump = true end
					goTo(hum, hrp, nav.sidestep)
					return
				end
			end
		end

		wps = nav.waypoints
		if wps then
			-- Back on the route after stepping away from it, from the nearest point on it
			-- rather than from wherever it was left.
			if nav.resync then
				nav.resync = false
				local best, bestDist = nav.index, math.huge
				for i, wp in wps do
					local d = (wp.Position - pos).Magnitude
					if d < bestDist then best, bestDist = i, d end
				end
				nav.index = math.min(best + 1, #wps + 1)
			end

			while nav.index <= #wps do
				local wp = wps[nav.index].Position
				local flat = Vector3.new(wp.X - pos.X, 0, wp.Z - pos.Z).Magnitude
				if flat < 3.5 and math.abs(wp.Y - pos.Y) < 7 then
					nav.index += 1
				else
					break
				end
			end

			--[[
				Corners the route does not need.

				Waypoints six studs apart around every bend make a walk that visibly zig-zags,
				and it is part of why routes looked like they went odd ways. A later waypoint
				in plain sight, on floor, at about our height is walked at directly.
			]]
			for ahead = math.min(#wps, nav.index + 3), nav.index + 1, -1 do
				local wp = wps[ahead].Position + Vector3.new(0, 3, 0)
				if math.abs(wp.Y - pos.Y) < 3 and clearLine(pos, wp) and groundAt(pos:Lerp(wp, 0.5), pos.Y) then
					nav.index = ahead
					break
				end
			end

			local wp = wps[nav.index]
			if wp then
				if wp.Action == Enum.PathWaypointAction.Jump and not moving() then hum.Jump = true end
				goTo(hum, hrp, wp.Position + Vector3.new(0, 3, 0))
				return
			end
		end

		-- No route yet. Walking at the goal anyway is what put it into walls; if the way is
		-- not open it waits the moment it takes for the route to arrive.
		if open then
			goTo(hum, hrp, goal)
			return
		end

		--[[
			Waiting for a route is right; waiting for one that is never coming is not.

			Some goals simply have no route - a spawn point inside scenery, an enemy on a
			ledge - and standing there until the dungeon ends is the worst answer available.
			Once the wait has gone on, the most direct opening that actually has floor and
			no wall is taken, which at least gets us somewhere a route can be found from.
		]]
		if nav.failedAt > 0 or now - nav.builtAt > 1.5 then
			local best, bestScore
			for i = 0, 11 do
				local angle = (i / 12) * math.pi * 2
				local probe = pos + Vector3.new(math.cos(angle), 0, math.sin(angle)) * 14
				local y = groundAt(probe, pos.Y)
				if y and clearLine(pos, probe) and not insideBarrier(probe, 1) then
					local grounded = Vector3.new(probe.X, y, probe.Z)
					local score = (grounded - goal).Magnitude
					if not bestScore or score < bestScore then best, bestScore = grounded, score end
				end
			end
			if best then
				goTo(hum, hrp, best)
				return
			end
		end

		if not moving() then hum:MoveTo(pos) end
	end

	--[[
		Where to go once a room is empty.

		Rooms are streamed in by the server as the run progresses, so there is no map to
		read ahead of time - only whatever is currently under workspace.dungeon. The one
		furthest from where the run started is the one being opened up, so that is the way
		forward. Falling back to walking ahead keeps it moving if that lookup finds
		nothing rather than leaving it standing in a cleared room.
	]]
	local function nextRoomGoal(hrp)
		local dungeon = workspace:FindFirstChild('dungeon')
		if not dungeon then return nil end

		local room = currentRoom()
		if room then return roomPoint(room) end

		local boss = dungeon:FindFirstChild('bossRoom')
		local point = boss and roomPoint(boss)
		-- Standing in it already, so there is nothing further to walk at.
		if point and (point - hrp.Position).Magnitude < 15 then return nil end
		return point
	end

	-- Heal-swap: when HP is low, if the inventory has heal spell(s), save the current
	-- loadout, switch to the best spell-power (mage) weapon + 1-2 heal spells, cast them
	-- to full HP while backing away, then restore the original loadout.
	--[[
		Swapping to heals, when there is anything to swap to.

		Every way out of this used to be silent, so owning no heal spell and the remote
		having been renamed looked exactly alike from outside: nothing happened, no weapon
		changed, no reason given. Each is named now.

		The common one is simply not owning a heal. It is matched on the ability's name
		containing the word, so anything called Chain Heal or Universal Heal qualifies and
		a Rending Slice does not - which is the whole of it for most loadouts.
	]]
	--[[
		Heals are equipped by number, and there are four slots.

		Two things made this fail every time. The game's own equip call is
		equipItem:InvokeServer(kind, uniqueItemNum, slot) with the item number as a NUMBER -
		its inventory keys look like 'ability_12' and it does tonumber(key:sub(9)) before
		sending. This sent the string, which the server does not match against anything, so
		nothing was ever equipped.

		The second is the slots themselves: they are q, e, q2 and e2. Only the first two
		were saved and restored, so the other half of the loadout was quietly dropped.
	]]
	local HEAL_WORDS = { 'heal', 'rejuvenat', 'aura of life', 'life pulse', 'innervate', 'blessing' }

	local function itemNumber(key, prefix)
		return tonumber(tostring(key):sub(#prefix + 2))
	end

	--[[
		How long before anything equipped can be swapped out.

		The server refuses to equip over an ability that is still cooling, so a swap made
		straight after a cast is simply denied - and the denial is silent, which is a swap
		that looks like it did nothing at all. Both halves of the swap hit this: going in,
		whatever was just cast in the fight; coming back, the heals we have this moment
		finished casting.
	]]
	local function slotCooldown(slot)
		for _, child in lplr.Backpack:GetChildren() do
			local marker = child:FindFirstChild('abilitySlot')
			if marker and marker.Value == slot then
				local cd = child:FindFirstChild('cooldown')
				return cd and tonumber(cd.Value) or 0
			end
		end
		return 0
	end

	local function abilityCooldown()
		local worst = 0
		for _, slot in ABILITY_SLOTS do
			local left = slotCooldown(slot) or 0
			if left > worst then worst = left end
		end
		return worst
	end

	-- Waited out rather than pushed through, while still giving ground: standing in the
	-- fight waiting for a cooldown is how the retreat gets you killed anyway.
	local function waitForCooldowns(limit)
		local started = os.clock()
		while AutoFarm.Enabled and os.clock() - started < (limit or 10) do
			local left = abilityCooldown()
			if left <= 0 then return true end

			local char = lplr.Character
			local hrp = char and char:FindFirstChild('HumanoidRootPart')
			local hum = char and char:FindFirstChildOfClass('Humanoid')
			if hrp and hum then
				local _, part = nearestEnemy(hrp.Position, currentRoom())
				if part then
					local away = (hrp.Position - part.Position) * Vector3.new(1, 0, 1)
					away = away.Magnitude > 0.1 and away.Unit or hrp.CFrame.LookVector
					goTo(hum, hrp, hrp.Position + away * KeepAway.Value)
				end
			end

			task.wait(math.clamp(left, 0.1, 0.5))
		end
		return abilityCooldown() <= 0
	end

	local function healSwap()
		local getStorage, equip, abilityUsed = remote('reloadInvy'), remote('equipItem'), remote('abilityUsed')
		if not (getStorage and equip and abilityUsed) then
			say('heal swap: a remote is missing (reloadInvy/equipItem/abilityUsed)')
			return false
		end

		-- Asked before the inventory is even read, so a wait costs nothing but time.
		local cooling = abilityCooldown()
		if cooling > 0 then
			say(string.format('heal swap: waiting %.0fs for abilities to come off cooldown', cooling))
			if not waitForCooldowns(12) then
				say('heal swap: abilities still cooling, trying again shortly')
				return false
			end
		end

		local ok, storage = pcall(function() return getStorage:InvokeServer() end)
		if not ok or type(storage) ~= 'table' or type(storage.abilities) ~= 'table' then
			say('heal swap: could not read your storage')
			return false
		end

		local heals, owned = {}, 0
		for id, item in pairs(storage.abilities) do
			owned += 1
			local name = tostring(fv(item, 'name') or ''):lower()
			local isHeal = false
			for _, word in HEAL_WORDS do
				if name:find(word, 1, true) then isHeal = true break end
			end
			local num = itemNumber(id, 'ability')
			if isHeal and num then table.insert(heals, num) end
		end
		if #heals == 0 then
			say(string.format('heal swap: none of your %d abilities is a heal, waiting for regen instead', owned))
			return false
		end
		say(string.format('heal swap: %d heal(s) found, switching', #heals))

		local savedWeapon, saved = nil, {}
		if type(storage.weapons) == 'table' then
			for id, item in pairs(storage.weapons) do
				if item.equipped == true then savedWeapon = itemNumber(id, 'weapon') break end
			end
		end
		for id, item in pairs(storage.abilities) do
			local eq = item.equipped
			if type(eq) == 'table' then
				for _, slot in ABILITY_SLOTS do
					if eq[slot] then saved[slot] = itemNumber(id, 'ability') end
				end
			end
		end

		local bestW, bestSP
		if type(storage.weapons) == 'table' then
			for id, item in pairs(storage.weapons) do
				local sp = tonumber(fv(item, 'spellPower')) or 0
				if not bestSP or sp > bestSP then bestW, bestSP = itemNumber(id, 'weapon'), sp end
			end
		end

		-- The server answers these, so a refusal can be reported rather than looking like
		-- the swap simply did nothing.
		local function equipItem(kind, num, slot)
			if not num then return false end
			-- Tried more than once: a cooldown that ended a moment ago, or a slot the
			-- server was still settling, is a refusal that answers differently a breath
			-- later. Anything still refused after this is a real no.
			for attempt = 1, 3 do
				local sent, answer = pcall(function() return equip:InvokeServer(kind, num, slot) end)
				if sent and answer ~= false then return true end
				if attempt < 3 then task.wait(0.35) end
			end
			return false
		end

		--[[
			A heal already equipped is a swap that never has to happen.

			Every swap has to be undone later, and undoing it is the half that fails - the
			heal we just cast is on cooldown and the server will not equip over it. So if
			any slot already holds a heal, nothing is swapped at all: it just casts what is
			there, and there is nothing to restore.
		]]
		local healNumbers = {}
		for _, num in heals do healNumbers[num] = true end

		local swapped = false
		for _, slot in ABILITY_SLOTS do
			if saved[slot] and healNumbers[saved[slot]] then
				say('heal swap: a heal is already equipped, casting it')
				swapped = true
				break
			end
		end

		local placedIn = {}
		if not swapped then
			if bestW then equipItem('weapon', bestW) end

			-- Only the first pair is touched, so at most two slots have to go back.
			local placed, index = 0, 1
			for _, slot in { 'q', 'e' } do
				local heal = heals[index]
				if heal and equipItem('ability', heal, slot) then
					placedIn[slot] = heal
					placed += 1
					index += 1
				end
			end
			if placed == 0 then
				say('heal swap: the server refused to equip a heal (it may not allow swapping mid-dungeon)')
				return false
			end
		end
		task.wait(0.4)

		local t0 = os.clock()
		while AutoFarm.Enabled and os.clock() - t0 < 12 do
			local char = lplr.Character
			local hum = char and char:FindFirstChildOfClass('Humanoid')
			local hrp = char and char:FindFirstChild('HumanoidRootPart')
			if not (hum and hrp) then break end
			if hum.MaxHealth > 0 and hum.Health / hum.MaxHealth >= 0.98 then break end

			-- Still backing away while casting, so healing is done at a distance rather
			-- than standing in the fight waiting for it to land.
			local _, part = nearestEnemy(hrp.Position)
			if part then
				local away = (hrp.Position - part.Position) * Vector3.new(1, 0, 1)
				away = away.Magnitude > 0.1 and away.Unit or hrp.CFrame.LookVector
				hum:MoveTo(hrp.Position + away * 20)
			end

			for _, slot in ABILITY_SLOTS do
				for _, child in lplr.Backpack:GetChildren() do
					if child:FindFirstChild('abilitySlot') and child.abilitySlot.Value == slot then
						local cd = child:FindFirstChild('cooldown')
						if not (cd and cd.Value > 0) then
							local le = child:FindFirstChild('localEvent'); if le then le:Fire() end
							pcall(function() abilityUsed:FireServer(slot, child) end)
						end
						break
					end
				end
			end
			task.wait(0.2)
		end

		-- Nothing was swapped, so there is nothing to put back.
		if not next(placedIn) then return true end

		--[[
			Put back exactly what was there, once each slot will accept it.

			The heal we have this second finished casting is on cooldown, and the server
			refuses to equip over a cooling ability - so restoring immediately is the swap
			most certain to be denied, and being denied leaves you holding heals and a spell
			staff for the rest of the run.

			Each slot is therefore watched on its own and put back the moment that slot's
			cooldown ends, rather than all of them waiting on the longest one. A slot that
			held nothing before is emptied again rather than left with a heal in it.
		]]
		if savedWeapon then equipItem('weapon', savedWeapon) end

		local unequip = remote('unequipItem')
		local pending = {}
		for slot in placedIn do pending[slot] = true end

		local deadline = os.clock() + 90
		while next(pending) and AutoFarm.Enabled and os.clock() < deadline do
			local longest = 0

			for slot in pending do
				local left = slotCooldown(slot) or 0
				if left <= 0 then
					local want = saved[slot]
					local done
					if want then
						done = equipItem('ability', want, slot)
					elseif unequip then
						-- It held nothing before, so the heal we put there comes back out.
						local sent, answer = pcall(function()
							return unequip:InvokeServer('ability', placedIn[slot])
						end)
						done = sent and answer ~= false
					else
						done = true
					end
					if done then pending[slot] = nil end
				elseif left > longest then
					longest = left
				end
			end

			if not next(pending) then break end

			-- Still backing away while waiting it out, rather than standing in the fight.
			local char = lplr.Character
			local hrp = char and char:FindFirstChild('HumanoidRootPart')
			local hum = char and char:FindFirstChildOfClass('Humanoid')
			if hrp and hum then
				local _, part = nearestEnemy(hrp.Position, currentRoom())
				if part then
					local away = (hrp.Position - part.Position) * Vector3.new(1, 0, 1)
					away = away.Magnitude > 0.1 and away.Unit or hrp.CFrame.LookVector
					goTo(hum, hrp, hrp.Position + away * KeepAway.Value)
				end
			end

			task.wait(math.clamp(longest > 0 and longest or 0.5, 0.2, 1))
		end

		if next(pending) then
			local stuck = {}
			for slot in pending do table.insert(stuck, slot) end
			say('heal swap: healed, but ' .. table.concat(stuck, '/') .. ' would not go back (still cooling)')
		end
		return true
	end

	AutoFarm = vain.Categories.Blatant:CreateModule({
		Name = 'Auto Farm',
		Tooltip = 'Clears the dungeon: fights every enemy with your weapon and Q/E, dodges telegraphed attacks, and backs off to recover when hurt',
		Function = function(callback)
			if not callback then
				-- Handed back rather than left as we set it, so turning the farm off does
				-- not leave you unable to turn while walking.
				pcall(function()
					local hum = lplr.Character and lplr.Character:FindFirstChildOfClass('Humanoid')
					if hum then hum.AutoRotate = true end
				end)
				return
			end

			setupDodge()
			clearPath()
			moveGoal = nil
			dodgeGoal = nil

			-- Routes were recorded to disk by an older farm. Nothing reads them any more,
			-- and deleting them means no old copy of the farm can ever replay one either.
			pcall(function()
				if isfolder and delfolder and isfolder('vain/profiles/dqroutes') then
					delfolder('vain/profiles/dqroutes')
				end
			end)
			-- In the console (F9), so which build is running is never a guess.
			print('[Auto Farm] automatic pathing, no routes - dodge build 2')

			--[[
				Dodging runs on the frame, not on the farm tick.

				The tick is a tenth of a second and every part of a dodge was tied to it:
				noticing the attack, choosing the spot, and taking the step. On an attack
				that lands in under a second that is most of the warning spent waiting, and
				it is the largest single reason dodging "always failed".

				So this owns the whole dodge. It replans the instant a part appears, holds
				its plan while the plan is still good, and steps every frame - which is also
				the only way the step budget produces a full walking pace rather than ten
				coarse hops a second.
			]]
			AutoFarm:Clean(runService.Heartbeat:Connect(function()
				local char = lplr.Character
				local hrp = char and char:FindFirstChild('HumanoidRootPart')
				local hum = char and char:FindFirstChildOfClass('Humanoid')
				if not (hrp and hum) then return end

				if DodgeAttacks ~= nil and DodgeAttacks.Enabled then
					local pos = hrp.Position

					--[[
						Replanned only when the answer could have changed.

						Every frame is too often - the search is a few hundred geometry
						tests - and only on the farm tick is too rare. A new part landing,
						the chosen spot no longer being safe, or arriving are the three
						things that actually invalidate a plan, so those are what trigger
						one.
					]]
					local fresh = dangerAdded
					dangerAdded = false

					--[[
						A marked circle outranks every other kind of dodging.

						When a boss turns the whole arena into the attack, the only safe
						ground is the circle it marked - so this is not a question of finding
						clear floor, it is a question of being in that circle before the
						attack lands. Anything else the dodge might do is wrong here.
					]]
					if #safeZones > 0 and not inSafeZone(pos) then
						local refuge = nearestSafeSpot(pos)
						if refuge then
							if not dodgeGoal then
								clearPath()
								if not moving() then hum:MoveTo(pos) end
								say('moving into the safe zone')
							end
							dodgeGoal = refuge
							stepTo(hrp, hum, refuge)
							return
						end
					end

					-- Clear of it now, so the rest of the walk to a spot that mattered a
					-- moment ago is time the farm should have back. Judged a little wider
					-- than the danger itself, so it does not stop on the edge.
					if dodgeGoal and not anyDanger(pos, 7) then
						dodgeGoal = nil
						-- Clear of it: hold this ground for a moment rather than letting the
						-- farm walk straight back into what was just dodged.
						settleUntil = os.clock() + 0.4
					end

					-- Dodging has been getting nowhere, so leave it alone briefly.
					if os.clock() < dodgeRestUntil then
						dodgeGoal = nil
						return
					end

					local stale = not dodgeGoal
						or (dodgeGoal - pos).Magnitude < 1.5
						or anyDanger(dodgeGoal, 5)

					--[[
						A new part only changes the plan if it lands on the plan.

						Every part that appeared anywhere forced a fresh search, and a
						fresh search picks a slightly different spot - so with attacks
						arriving several a second the dodge changed direction several times
						a second, and zig-zagging on the spot covers far less ground than
						walking one way. Now a new part replans only when it covers the
						way there.
					]]
					if not stale and fresh then
						local mid = pos:Lerp(dodgeGoal, 0.5)
						stale = anyDanger(mid, 2) and not anyDanger(pos, 2)
					end

					if stale and not dodgeGoal and not fresh and os.clock() - lastPlanFailed < 0.15 then
						stale = false
					end

					-- Standing in the answer already: an attack landing on the spot we are
					-- walking to outranks the rate limit, which is there for comfort.
					local urgent = dodgeGoal ~= nil and anyDanger(dodgeGoal, 5)

					if stale and not urgent and os.clock() - lastPlanAt < 0.06 then
						stale = false
					end

					if stale then
						lastPlanAt = os.clock()
						local safe = dodgeTarget(pos) or projectileDodge(pos)
						if safe then
							if not dodgeGoal then
								clearPath()
								-- A humanoid mid-walk will keep walking while we step, and
								-- the two fight each other. Stop it once, here.
								if not moving() then hum:MoveTo(pos) end
								say(string.format('dodging to %.0f studs away', (safe - pos).Magnitude))
							end
							if not dodgeGoal then dodgeStalls = 0 end
							dodgeGoal = safe
						else
							if anyDanger(pos, 5) then lastPlanFailed = os.clock() end
							dodgeGoal = nil
						end
					end

					if dodgeGoal then
						--[[
							A plan that is not moving us is not a plan.

							Every step to this spot can be refused - a wall in the way, a
							ledge, a border - and nothing noticed: the goal stayed, the farm
							kept waiting for the dodge, and the character stood still. If we
							have not moved in half a second the spot is written off and
							another is asked for; after a few of those the dodge gives up and
							lets the farm act instead of freezing behind it.
						]]
						if not dodgeLastPos or (pos - dodgeLastPos).Magnitude > 0.6 then
							dodgeLastPos, dodgeMovedAt = pos, os.clock()
						elseif os.clock() - dodgeMovedAt > 0.5 then
							dodgeLastPos, dodgeMovedAt = pos, os.clock()
							table.insert(badSpots, {pos = dodgeGoal, at = os.clock()})
							dodgeStalls += 1
							dodgeGoal = dodgeStalls < 3 and dodgeTarget(pos) or nil
							if not dodgeGoal then
								lastPlanFailed = os.clock()
								-- Three spots in a row it could not reach: stop trying for a
								-- moment instead of standing here doing this.
								dodgeRestUntil = os.clock() + 0.7
								dodgeStalls = 0
							end
						end
					end

					if dodgeGoal then
						stepTo(hrp, hum, dodgeGoal)
						return
					end
				else
					dodgeGoal = nil
				end

				if not moveGoal then return end
				-- Nobody has renewed this in a while, so it is somewhere we used to want
				-- to be rather than somewhere we are going.
				if os.clock() - moveSetAt > 1 then
					moveGoal = nil
					return
				end
				stepTo(hrp, hum, moveGoal, true)
			end))

			local weaponUsed = remote('weaponUsed')
			local abilityUsed = remote('abilityUsed')
			local retreating = false

			--[[
				Errors are said out loud, once each.

				The body below runs inside a pcall so one bad frame cannot kill the farm,
				but swallowing the message meant any mistake in here looked identical to
				the farm simply deciding to do nothing - which is impossible to tell apart
				from outside, and is how a broken build gets reported as "it just stands
				there". Each distinct error is reported the first time it is seen.
			]]
			local reported = {}
			local function report(err)
				err = tostring(err)
				if reported[err] then return end
				reported[err] = true
				if vain and vain.CreateNotification then
					vain:CreateNotification('Auto Farm', err, 10, 'alert')
				end
				warn('[Auto Farm] ' .. err)
			end

			-- Counted so the two failure modes read differently: never seeing a telegraph is
			-- a detection problem, seeing them and still being hit is a movement one.
			task.spawn(function()
				while AutoFarm.Enabled do
					task.wait(5)
					if Debug ~= nil and Debug.Enabled then
						warn(string.format('[Auto Farm] %d telegraphs seen, %d live now', seenZones, #dangers))
					end
				end
			end)

			repeat
				local ok, err = pcall(function()
					local char = lplr.Character
					local hrp = char and char:FindFirstChild('HumanoidRootPart')
					local hum = char and char:FindFirstChildOfClass('Humanoid')
					if not (char and hrp and hum) then return end


					local peaceful = lplr:FindFirstChild('peaceful')
					if peaceful and peaceful.Value == true then return end

					--[[
						Nothing happens before the run does.

						peaceful only says you are not in town, which is already true while
						everyone stands on the platform waiting for the countdown - so the
						farm would set off into a dungeon that had not started, walking at
						enemies that were not there yet. The game keeps its own flag for
						this, and it is the honest answer.

						Absent, it is assumed started: some modes have no such flag, and
						refusing to farm in those would be worse than starting early in one.
					]]
					local started = workspace:FindFirstChild('dungeonStarted')
					if started and started:IsA('BoolValue') and started.Value ~= true then return end

					-- Before anything else: being in the air outranks every plan that
					-- assumes standing on something.
					if mode() == 'Step TP' and keepGrounded(hrp, hum) then
						return
					end

					--[[
						Facing held still while the feet move.

						MoveTo turns the humanoid to face wherever it is walking, so backing
						away from something turns your back on it: abilities go off behind
						you and every change of direction costs a turn before it costs a
						step. Switching AutoRotate off is what shift lock does, and it is
						not one of the things the game asks the client to report about
						itself, unlike speed and platform stand.

						The turn towards a target still happens, once, immediately before
						each swing - which is often enough to keep facing roughly right
						without a CFrame write every tick cancelling the walk.
					]]
					if ShiftLock ~= nil then
						hum.AutoRotate = not ShiftLock.Enabled
					end

					local room = currentRoom()
					local target, part, dist = nearestEnemy(hrp.Position, room)
					-- Handed to the dodge, so it knows which way keeps the fight.
					fightTarget = part

					-- DODGE first: standing in an attack costs more than a turn spent
					-- fighting, so a dodge in progress outranks everything below it. The
					-- stepping itself belongs to the heartbeat above; this only keeps the
					-- farm from issuing a walk that would fight it.
					if DodgeAttacks.Enabled then
						watchProjectiles()
						if dodgeGoal then return end
					end

					local hpFrac = hum.MaxHealth > 0 and hum.Health / hum.MaxHealth or 1
					if hpFrac <= SafeHP.Value / 100 then retreating = true end

					if retreating then
						--[[
							Backing off on foot.

							The old version floated out of reach, which is the one thing the
							server will not have. Walking away from whatever is nearest is
							the honest version of the same idea: it buys distance rather
							than immunity, so Keep Away decides how much.
						]]
						local _, part, dist = nearestEnemy(hrp.Position, currentRoom())
						if part and (dist or 0) < KeepAway.Value then
							local away = (hrp.Position - part.Position) * Vector3.new(1, 0, 1)
							away = away.Magnitude > 0.1 and away.Unit or hrp.CFrame.LookVector
							clearPath()
							goTo(hum, hrp, hrp.Position + away * KeepAway.Value)
						end

						if HealSwap.Enabled and healSwap() then
							retreating = false
							return
						end
						if hpFrac >= math.min(RecoverHP.Value / 100, 0.98) then
							retreating = false
						end
						return
					end

					if target and part then
						local busy = char:FindFirstChild('busyCasting')
						local reach = AttackRange.Value
						local spellReach = AbilityRange ~= nil and AbilityRange.Value or 35

						--[[
							Fought from just outside melee, not from across the room.

							A melee enemy's swing is a hitbox reaching about seven studs, so a
							couple of studs past that is already out of its reach. Every
							ability in the game covers far more: the smallest of them is about
							ten studs across from where you stand and most are thirty or more.
							Distance beyond melee reach therefore buys nothing and costs every
							cast that falls short.

							Holding anywhere inside Ability Range was the mistake. Set to
							forty, the farm parked forty studs out and threw every spell into
							empty floor - and since an ability with no published cooldown
							always reads as ready, it stood there doing it indefinitely. That
							is both "keeps so much distance" and one of the ways it froze.

							So the distance held is Keep Distance, floored just past melee
							reach, and Ability Range only decides when a cast is worth making.
						]]
						local keep = math.max(KeepDistance.Value, 9)
						local away = (hrp.Position - part.Position) * Vector3.new(1, 0, 1)
						away = away.Magnitude > 0.1 and away.Unit or hrp.CFrame.LookVector

						local gap = dist or math.huge
						-- A band rather than a line, so being a stud too far is not a reason
						-- to walk in and then straight back out again.
						local band = keep + 4

						-- Cast the moment it is in range, from wherever we are standing.
						if gap <= spellReach and not (busy and busy.Value ~= false) then
							faceTarget(hrp, part)
							castAbilities(abilityUsed)
						end

						--[[
							Deadbands, so held distance is a range and not a tightrope.

							Backing off at exactly Keep Distance and closing at exactly the
							far edge means a stud of drift either way starts a walk, and the
							walk overshoots, and it starts the opposite walk - the shuffle
							back and forth that never settles and never fights. A stud and a
							half of slack on each edge costs nothing and stops all of it.
						]]
						local push, crowded = crowding(hrp.Position, keep - 2)

						--[[
							Settling holds the ground taken; it never stands and takes a hit.

							Holding position outright after every dodge is a free swing for
							anything already in reach - which is what "randomly stops for a
							moment and gets hit" is. Giving ground to something too close
							outranks it, so only the walk back toward the target waits.
						]]
						local settling = os.clock() < settleUntil

						if crowded > 0 then
							-- Something is inside the distance we hold: give up just enough
							-- ground to be outside it again, not a retreat across the room.
							clearPath()
							local out = push.Magnitude > 0.1 and push.Unit or away
							goTo(hum, hrp, hrp.Position + out * 6)
						elseif gap < keep - 1.5 then
							clearPath()
							goTo(hum, hrp, hrp.Position + away * ((keep - gap) + 2))
						elseif settling then
							-- Nothing in reach, so the ground just taken is worth keeping for
							-- a moment rather than walking straight back into the attack.
							clearPath()
							if not moving() then hum:MoveTo(hrp.Position) end
						elseif gap > band + 1.5 then
							--[[
								Walked to where we want to stand, not into the enemy.

								The goal used to be the enemy's own position - a point inside
								a body, which the pathfinder rejects as occupied, and which
								the walk then presses into until something else interrupts.
								Standing distance out on our own side of it is both reachable
								and where we actually want to end up.
							]]
							walkTo(hum, hrp, part.Position + away * keep)
						elseif Strafe ~= nil and Strafe.Enabled then
							clearPath()

							local tangent = Vector3.new(-away.Z, 0, away.X)

							-- Reconsidered on a timer rather than every tick, but chosen by
							-- which side is emptier rather than simply alternating.
							if os.clock() > strafeUntil then
								strafeDir = clearestTangent(hrp.Position, part.Position, tangent, keep)
								strafeUntil = os.clock() + 2
							end

							goTo(hum, hrp, part.Position + (away * keep) + (tangent * strafeDir * 10))
						else
							clearPath()
							-- Stop walking and hold position while swinging, so the hit is
							-- thrown from where the server already believes we are.
							hum:MoveTo(hrp.Position)
						end
						--[[
							Turned only to attack, never while walking.

							faceTarget writes the root part's CFrame, and doing that every
							tick resets the humanoid's physics state - which cancels the
							walk MoveTo had just started. The character turned to face its
							target and then stood there, every time. Harmless in the old
							version because that teleported anyway; fatal once movement
							depends on actually walking.

							One write immediately before the swing is enough to aim, and
							far too rare to interfere with getting anywhere.
						]]
						if gap <= reach and not (busy and busy.Value ~= false) then
							faceTarget(hrp, part)
							swing(char, weaponUsed)
						end
					else
						local goal = nextRoomGoal(hrp)
						if goal then
							walkTo(hum, hrp, goal)
						else
							-- Nowhere to go. Walking twenty studs in whatever direction we
							-- happened to face was the old answer, and it is how the farm
							-- wandered off into walls between rooms.
							clearPath()
							if not moving() then hum:MoveTo(hrp.Position) end
						end
					end
				end)
				if not ok then report(err) end
				task.wait(FarmDelay and FarmDelay.Value or 0.1)
			until not AutoFarm.Enabled
		end,
	})
	SafeHP = AutoFarm:CreateSlider({ Name = 'Retreat below HP', Min = 5, Max = 90, Default = 45, Suffix = '%',
		Tooltip = 'Back away and stop fighting once your HP drops below this' })
	RecoverHP = AutoFarm:CreateSlider({ Name = 'Resume at HP', Min = 20, Max = 100, Default = 85, Suffix = '%',
		Tooltip = 'Return to the fight once HP recovers to this' })
	KeepDistance = AutoFarm:CreateSlider({ Name = 'Keep Distance', Min = 0, Max = 50, Default = 10, Suffix = ' studs',
		Tooltip = 'How far to stand from what you are fighting. Never goes below 9, which is just outside melee reach (default 10)' })
	KeepAway = AutoFarm:CreateSlider({ Name = 'Keep Away', Min = 20, Max = 200, Default = 70, Suffix = ' studs',
		Tooltip = 'How far to put between you and the nearest enemy while recovering (default 70)' })
	AttackRange = AutoFarm:CreateSlider({ Name = 'Attack Range', Min = 4, Max = 60, Default = 12, Suffix = ' studs',
		Tooltip = 'How close to get before swinging. Melee wants this low, a staff can sit further back (default 12)' })
	AbilityRange = AutoFarm:CreateSlider({ Name = 'Ability Range', Min = 10, Max = 120, Default = 25, Suffix = ' studs',
		Tooltip = 'Only cast Q/E at a target this close, so casts are not thrown away out of reach. Does not change where the farm stands (default 25)' })
	FarmDelay = AutoFarm:CreateSlider({ Name = 'Loop Delay', Min = 0, Max = 0.5, Default = 0.1, Decimal = 100, Suffix = 's',
		Tooltip = 'Time between farm ticks' })
	Debug = AutoFarm:CreateToggle({ Name = 'Debug', Default = false,
		Tooltip = 'Reports every telegraph seen and every dodge taken, so a dodge that is not happening can be told apart from one that is happening and not helping' })
	Movement = AutoFarm:CreateDropdown({
		Name = 'Movement',
		List = {'Walk', 'Step TP', 'Fly'},
		Default = 'Walk',
		Tooltip = 'How to get around',
		ItemTooltips = {
			Walk = 'Lets the humanoid walk there, which is what a player does',
			['Step TP'] = 'Places you along the route in small pieces, never faster than a walk. Precise, but needs a floor under every step',
			Fly = 'The same, through the air, rising to enemies above you. Still walk pace, but never blocked by ledges or corners',
		}
	})
	ShiftLock = AutoFarm:CreateToggle({ Name = 'Shift Lock', Default = true,
		Tooltip = 'Keeps you facing your target while moving instead of turning to face wherever you walk, so backing away from something still points your abilities at it' })
	Strafe = AutoFarm:CreateToggle({ Name = 'Strafe', Default = true,
		Tooltip = 'Circles the enemy while fighting instead of standing still, so the ground attacks aimed at you land where you were' })
	UsePathfinding = AutoFarm:CreateToggle({ Name = 'Pathfinding', Default = true,
		Tooltip = "Follows the game's own navigation around corners and up stairs instead of walking into walls. Turn off only if it gets stuck" })
	HealSwap = AutoFarm:CreateToggle({ Name = 'Heal Swap when low', Default = true,
		Tooltip = 'When low, if you own a heal spell: swap to best spell-power weapon and heals, heal to full while backing off, then restore your set' })
	DodgeAttacks = AutoFarm:CreateToggle({ Name = 'Dodge Attacks', Default = true,
		Tooltip = "Steps you out of every enemy attack part the game spawns, reading their names from the game's own attack list" })
end)


-- ── Strip Decorations ────────────────────────────────────────────────────────
run(function()
	local Strip, Effects

	-- Its own, because say() is a local of the farm's block and a nil global out here.
	local function tell(text)
		if vain and vain.CreateNotification then
			vain:CreateNotification('Vain DQ', text, 5, 'info')
		end
	end

	--[[
		Deleting the scenery the dungeon does not need.

		Everything the farm reads to get around is either solid or a marker: the floor and
		walls it raycasts, the barriers it reads a room's state from, the spawn points it
		aims at, and the enemies themselves. A part that cannot be collided with is none of
		those - it is decoration, and on these maps there is a great deal of it.

		Removing it cuts what the client has to render, and frame time is not cosmetic
		here: the farm decides where to stand once a tenth of a second, and a dodge it
		works out two frames late is a dodge it does not make.

		This does not come back. The scenery is gone until the dungeon is rejoined, which
		is why it is its own switch rather than something the farm does quietly.
	]]
	local function guarded(part)
		if part.CanCollide then return true end
		if part:IsA('SpawnLocation') then return true end

		-- The markers the room logic is built on: spawn points are what a room's position
		-- is averaged from, and a barrier is how it knows the room is still shut.
		local node = part
		for _ = 1, 6 do
			if not node or node == workspace then break end
			local name = node.Name
			if name == 'spawn' or name == 'barrier' or name == 'order' then return true end
			if node:FindFirstChildOfClass('Humanoid') then return true end
			node = node.Parent
		end
		return false
	end

	local VISUALS = {'ParticleEmitter', 'Trail', 'Beam', 'Smoke', 'Fire', 'Sparkles', 'PointLight', 'SpotLight', 'SurfaceLight'}

	Strip = vain.Categories.Utility:CreateModule({
		Name = 'Strip Decorations',
		Tooltip = 'Deletes scenery the farm never touches, to buy frame rate. Rejoin to get it back',
		Function = function(callback)
			if not callback then return end

			local dungeon = workspace:FindFirstChild('dungeon')
			if not dungeon then
				tell('no dungeon loaded to strip')
				Strip:Toggle()
				return
			end

			local removed = 0
			for _, object in dungeon:GetDescendants() do
				local ok = pcall(function()
					if object:IsA('BasePart') then
						if not guarded(object) then
							object:Destroy()
							removed += 1
						end
					elseif Effects.Enabled and table.find(VISUALS, object.ClassName) then
						object:Destroy()
						removed += 1
					end
				end)
				if not ok then break end
			end

			tell(removed .. ' decorations removed')
			Strip:Toggle()
		end
	})
	Effects = Strip:CreateToggle({
		Name = 'Effects too',
		Default = true,
		Tooltip = 'Also removes particles, beams and lights'
	})
end)

--VAINEOF


-- Shared attack helpers, for the modules kept alongside this file.
--
-- Auto Farm has its own copies of these as locals; they are duplicated here rather than
-- lifted out of it, because that module is working and reaching into it to restructure
-- it would risk that for no gain. Both follow the same verified path: the equipped
-- weapon is an Accessory carrying a 'Weapon' child, its RemoteEvent is the swing, and
-- abilities live in the Backpack with an 'abilitySlot' naming their key and a 'cooldown'
-- that is above zero while they are unavailable.
local function sharedWeapon(char)
	for _, c in char:GetChildren() do
		if c:IsA('Accessory') and c:FindFirstChild('Weapon') then return c end
	end
end

local function sharedSwing()
	local char = lplr.Character
	if not char then return end
	local weapon = sharedWeapon(char)
	if not weapon then return end

	local rem = weapon:FindFirstChildOfClass('RemoteEvent')
	if rem then pcall(function() rem:FireServer() end) end
	local used = remote('weaponUsed')
	if used then pcall(function() used:FireServer() end) end
end

-- Cast only when the cooldown has actually cleared, which is what makes this fire the
-- instant one comes back rather than pressing keys and hoping.
local function sharedCastAbilities()
	local abilityUsed = remote('abilityUsed')
	if not abilityUsed then return end

	for _, slot in {'q', 'e', 'q2', 'e2'} do
		for _, child in lplr.Backpack:GetChildren() do
			local marker = child:FindFirstChild('abilitySlot')
			if marker and marker.Value == slot then
				local cd = child:FindFirstChild('cooldown')
				if not (cd and cd.Value > 0) then
					local le = child:FindFirstChild('localEvent')
					if le then pcall(function() le:Fire() end) end
					pcall(function() abilityUsed:FireServer(slot, child) end)
				end
				break
			end
		end
	end
end

-- Every live enemy part, for anything that needs the whole set rather than the closest.
local function enemyParts()
	if os.clock() - _enemyScan > 1 or #_enemyParts == 0 then scanEnemyParts() end
	local list = {}
	for _, part in _enemyParts do
		if part and part.Parent then
			table.insert(list, part)
		end
	end
	return list
end

-- Re-exported for the modules kept alongside this file.
vain.Libraries.dungeonquest = {
	remote = remote,
	inCombat = inCombat,
	faceNearest = faceNearest,
	nearestEnemyPart = nearestEnemyPart,
	watchProjectiles = watchProjectiles,
	projectileDodge = projectileDodge,
	enemyParts = enemyParts,
	swing = sharedSwing,
	castAbilities = sharedCastAbilities,
	-- Set by Godmode, read by AutoKill: hiding the tracked root also stops your own
	-- hits landing, so an attack has to ask for it back first.
	combat = {
		hidden = false,
		wantAttack = 0,
		attackReady = false,
		threat = 0
	}
}


run(function()
	local AutoKill
	
	-- Hit and run, rather than standing next to what you are fighting.
	--
	-- AutoFarm parks alongside an enemy and stays there, which leaves it in reach of
	-- everything nearby for as long as the fight lasts. This darts to the nearest one, swings
	-- once, and is back where it started before anything can answer - so the only moment you
	-- are exposed is the swing itself.
	local dq = vain.Libraries.dungeonquest
	
	-- Where to sit for the swing: inside melee reach, with a little height so you are not
	-- standing inside the target and being shoved about by it.
	local STRIKE_OFFSET = Vector3.new(0, 6, 0)
	local STRIKE_RANGE = 4
	
	-- How long to stay before returning.
	--
	-- Not zero, however tempting. The swing is a click the game turns into a request, and
	-- returning in the same frame puts you home before that request is dealt with - so it
	-- arrives claiming a position you are no longer at and is thrown away. This is the
	-- shortest wait that still lets the hit count.
	local DWELL = 0.12
	
	-- How long to stay home between trips.
	--
	-- Without this the loop went straight back in - a tenth of a second away, a tenth of a
	-- second at the enemy - which is most of the time spent standing in reach and barely
	-- different from parking there. Waiting between strikes is what makes this hit and run
	-- rather than hit and stay, and it costs nothing: a weapon cannot swing faster than its
	-- own animation, so the extra trips were never landing anything anyway.
	local STRIKE_INTERVAL = 0.6
	local nextStrike = 0
	
	-- How far apart two enemies can be and still be caught by one swing. A guess at the
	-- weapon's arc rather than a known figure, so it errs small - clustering too eagerly
	-- would have you standing between enemies that a swing cannot actually reach.
	local CLUSTER_RADIUS = 12
	
	-- Picks where to strike, rather than what to strike.
	--
	-- Going to the nearest enemy hits exactly one per trip, and with a wait between trips
	-- that is what made clearing a room slow. Melee swings in an arc, so standing where
	-- several enemies overlap catches them together and the same number of trips does
	-- several times the work.
	--
	-- Ties go to whichever cluster is closest, so it is not crossing the room for a group no
	-- bigger than the one at its feet.
	local function bestCluster(origin)
		local roots = dq.enemyParts()
		if #roots == 0 then return nil end
	
		local bestCentre, bestCount, bestDist
	
		for _, root in roots do
			local centre, count = root.Position, 0
			local sum = Vector3.zero
	
			for _, other in roots do
				if (other.Position - root.Position).Magnitude <= CLUSTER_RADIUS then
					count += 1
					sum += other.Position
				end
			end
	
			-- The middle of the group rather than the enemy it was measured from, so the
			-- swing is centred on all of them instead of favouring one edge.
			centre = sum / count
			local dist = (centre - origin).Magnitude
	
			if not bestCount or count > bestCount or (count == bestCount and dist < bestDist) then
				bestCentre, bestCount, bestDist = centre, count, dist
			end
		end
	
		return bestCentre, bestCount
	end
	
	AutoKill = vain.Categories.Blatant:CreateModule({
		Name = 'AutoKill',
		Function = function(callback)
			if callback then
				nextStrike = 0
				task.spawn(function()
					repeat
						-- Guarded, yielding outside, so one bad pass cannot spin or end the
						-- module for the session.
						local ok = pcall(function()
							-- Only inside a dungeon: the game says so itself through peaceful
							-- and busyCasting, which is far better than inferring it from
							-- whether enemies happen to be visible.
							if not (entitylib.isAlive and dq.inCombat()) then return end
	
							-- Step out of anything thrown before darting in. Auto Farm covers
							-- boss area attacks through the game's own telegraph bridge; this
							-- is the other half, for things already in the air.
							dq.watchProjectiles()
							local dodge = dq.projectileDodge(entitylib.character.RootPart.Position)
							if dodge then
								local me = entitylib.character.RootPart
								me.CFrame = CFrame.new(dodge)
								me.AssemblyLinearVelocity = Vector3.zero
								return
							end
	
							-- Abilities are cast from here, before going anywhere. They do not
							-- need to be near the target, so casting them on the trip would
							-- only lengthen the time spent in reach.
							dq.castAbilities()
	
							if tick() < nextStrike then return end
	
							local me = entitylib.character.RootPart
							local targetCentre = bestCluster(me.Position)
							if not targetCentre then return end
							-- Captured before moving and returned to afterwards, so the trip
							-- leaves you exactly where you were rather than drifting a little
							-- further out with each one.
							local home = me.CFrame
	
							-- Approached from the side you are already on, and aimed at the
							-- target itself so the pitch is right - a swing is a click at the
							-- centre of the screen, so it lands wherever the camera looks.
							local targetPos = targetCentre
							local away = me.Position - targetPos
							away = Vector3.new(away.X, 0, away.Z)
							if away.Magnitude < 0.1 then
								local back = me.CFrame.LookVector * -1
								away = Vector3.new(back.X, 0, back.Z)
							end
	
							local spot = targetPos + (away.Unit * STRIKE_RANGE) + STRIKE_OFFSET
							me.CFrame = CFrame.new(spot, targetPos)
							me.AssemblyLinearVelocity = Vector3.zero
							pcall(function()
								gameCamera.CFrame = CFrame.new(gameCamera.CFrame.Position, targetPos)
							end)
	
							-- Godmode hides the part the server identifies you by and checks
							-- that same one when you swing, so a hit sent while hidden is
							-- rejected. Ask for it back and wait to be told it has arrived.
							-- With Godmode off there is nothing to wait for and this is skipped.
							if dq.combat.hidden then
								dq.combat.wantAttack = tick()
								if not dq.combat.attackReady then return end
							end
	
							nextStrike = tick() + STRIKE_INTERVAL
							dq.swing()
	
							task.wait(DWELL)
	
							-- Home again whatever happened in between. Wrapped because the
							-- character can be replaced mid trip, and being left parked on top
							-- of an enemy is the one outcome this module exists to avoid.
							pcall(function()
								if entitylib.isAlive then
									local back = entitylib.character.RootPart
									back.CFrame = home
									back.AssemblyLinearVelocity = Vector3.zero
								end
							end)
						end)
	
						task.wait(ok and 0.05 or 0.4)
					until not AutoKill.Enabled
				end)
			end
		end,
		Tooltip = 'Darts to wherever the most enemies are in reach, swings, and returns instantly'
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