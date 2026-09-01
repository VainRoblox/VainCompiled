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
local function scanEnemyParts()
	_enemyParts = {}
	pcall(function()
		for _, d in workspace:GetDescendants() do
			if d:IsA('Humanoid') and d.Health > 0 then
				local m = d.Parent
				if m and m:IsA('Model') and not playersService:GetPlayerFromCharacter(m) and m:FindFirstAncestor('enemyFolder') then
					local part = m.PrimaryPart or m:FindFirstChild('HumanoidRootPart') or m:FindFirstChildWhichIsA('BasePart')
					if part then table.insert(_enemyParts, part) end
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
			setupDodge()
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
					for _, slot in { 'q', 'e' } do
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
	local AutoFarm, SafeHP, RecoverHP, AttackRange, KeepDistance, KeepAway, FarmDelay, HealSwap, DodgeAttacks, UsePathfinding, Strafe, Movement, ShiftLock, Debug

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
	local lastStep = os.clock()

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
	local function groundAt(position, fallbackY)
		local skip = {lplr.Character}
		for _, m in enemyCache do
			if m and m.Parent then
				table.insert(skip, m)
			end
		end
		groundParams.FilterDescendantsInstances = skip

		local hit = workspace:Raycast(position + Vector3.new(0, 12, 0), Vector3.new(0, -80, 0), groundParams)
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

		The room is fenced by a Barriers folder full of parts, and a dodge that chose a spot
		on the far side of one could never get there: the step refused it, the search offered
		it again next tick, and the farm stood announcing a dodge it would never take. That
		is the stall.

		Tested by geometry rather than by raycast, because these are exactly the sort of part
		that is built unqueryable - a ray would pass straight through the very wall we are
		trying to respect. Each part becomes a box in its own space, which is cheap enough
		for the dozen or so a room has, and correct whatever their query flags say.
	]]
	local barrierParts, barrierScan = {}, 0

	local function refreshBarriers()
		if os.clock() - barrierScan < 3 and #barrierParts > 0 then return end
		barrierScan = os.clock()

		barrierParts = {}
		local folder = workspace:FindFirstChild('Barriers')
		if not folder then return end
		for _, d in folder:GetDescendants() do
			if d:IsA('BasePart') then
				table.insert(barrierParts, d)
			end
		end
	end

	local function insideBarrier(pos, margin)
		margin = margin or 2
		for _, part in barrierParts do
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
	local function crossesBarrier(from, to)
		if #barrierParts == 0 then return false end
		for i = 1, 6 do
			if insideBarrier(from:Lerp(to, i / 6), 1) then return true end
		end
		return false
	end

	local dangers = {}
	local dodgeReady = false
	local seenZones = 0

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
		Attack models, every part of them.

		These arrive as whole models dropped into the workspace - npcMageSpikes from a Dark
		Mage, bigMageBeam from the demon - and rather than trying to work out which part
		inside is the dangerous one, every part is treated as dangerous. Naming has already
		proved a dead end twice: precast only exists in one dungeon, and matching words in
		the model's name needs a list that is only ever as complete as what has been seen.

		The one guard kept is that nothing counts unless there is something to fight. That
		is what stops a repeat of the lobby, where scenery arriving in an empty world was
		read as an attack and the farm stood dodging decorations before the match began.
	]]
	local function watchAttackModels()
		--[[
			Descendants, not children.

			These do not all land at the top of the workspace: some are parented into the
			dungeon or a room, and watching only direct children missed those entirely
			while appearing to work perfectly on the ones that did.

			Nested models are NOT skipped. That filter was added to avoid registering the
			same parts twice and it threw away real attacks instead - the spikes that
			arrive inside another model were exactly the case it dropped. Registering a
			part twice costs nothing, since both copies expire together and standing
			outside a zone twice is the same as standing outside it once.
		]]
		workspace.DescendantAdded:Connect(function(object)
			if not object:IsA('Model') then return end
			if object:FindFirstChildOfClass('Humanoid') then return end
			if playersService:GetPlayerFromCharacter(object) then return end

			-- Nothing casts anything when there is nothing alive to cast it.
			if #enemyCache == 0 then return end

			local expire = workspace:GetServerTimeNow() + 12
			local added = 0

			-- BasePart rather than Part on purpose: plenty of these are built from meshes,
			-- and a MeshPart hurts exactly as much as a brick does.
			for _, part in object:GetDescendants() do
				if part:IsA('BasePart') then
					-- Shape only exists on a plain Part; anything else is treated as a box.
					local circle = part:IsA('Part') and part.Shape == Enum.PartType.Cylinder
					table.insert(dangers, {
						kind = circle and 'circle' or 'cube',
						part = part,
						cf = part.CFrame,
						pos = part.Position,
						size = part.Size,
						radius = part.Size.Y * 0.5,
						expire = expire,
					})
					added += 1
				end
			end

			if added > 0 then
				seenZones += added
				say(string.format('attack %s: %d parts', object.Name, added))
			end
		end)
	end

	local function setupDodge()
		if dodgeReady then return end
		dodgeReady = true

		local watched, watchErr = pcall(watchAttackModels)
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

	local function inDanger(pos, d, margin)
		if d.kind == 'circle' then
			-- Height matters for these too: a ring cast on the floor below is not one we
			-- are standing in, and treating it as one kept the dodge running with nowhere
			-- sensible to go.
			if math.abs(pos.Y - d.pos.Y) > 25 then return false end
			local dx, dz = pos.X - d.pos.X, pos.Z - d.pos.Z
			return (dx * dx + dz * dz) <= (d.radius + margin) ^ 2
		else
			local lp = d.cf:PointToObjectSpace(pos)
			local h = d.size * 0.5
			return math.abs(lp.X) <= h.X + margin and math.abs(lp.Z) <= h.Z + margin
				and math.abs(lp.Y) <= h.Y + 8
		end
	end

	local function safeSpot(pos, d, margin)
		if d.kind == 'circle' then
			--[[
				Cast on your feet, a ring leaves no direction to run: the vector from its
				centre to you is nothing, and normalising nothing is what sent the dodge
				somewhere useless. Facing decides it instead - sideways, so it steps out of
				the ring rather than backing away from whatever is in front of it.
			]]
			local dir = Vector3.new(pos.X - d.pos.X, 0, pos.Z - d.pos.Z)
			if dir.Magnitude <= 0.1 then
				local hrp = lplr.Character and lplr.Character:FindFirstChild('HumanoidRootPart')
				local look = hrp and hrp.CFrame.LookVector or Vector3.new(0, 0, 1)
				dir = Vector3.new(-look.Z, 0, look.X)
				dir = dir.Magnitude > 0.1 and dir.Unit or Vector3.new(1, 0, 0)
			else
				dir = dir.Unit
			end
			return Vector3.new(d.pos.X, pos.Y, d.pos.Z) + dir * (d.radius + margin)
		else
			local lp = d.cf:PointToObjectSpace(pos)
			local h = d.size * 0.5
			local exitX = (h.X + margin) - math.abs(lp.X)
			local exitZ = (h.Z + margin) - math.abs(lp.Z)
			local nlp
			if exitX <= exitZ then
				nlp = Vector3.new((h.X + margin) * (lp.X >= 0 and 1 or -1), lp.Y, lp.Z)
			else
				nlp = Vector3.new(lp.X, lp.Y, (h.Z + margin) * (lp.Z >= 0 and 1 or -1))
			end
			return d.cf:PointToWorldSpace(nlp)
		end
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
	-- Reaching further than before, because giving up and standing in the fire is worse
	-- than a long walk: with the walls now respected there is always somewhere legal, and
	-- this keeps widening until it finds it.
	local DODGE_RINGS = {8, 13, 19, 27, 38, 50, 64, 80}
	local DODGE_SAMPLES = 24

	-- A zone backed by a model is measured from it each pass and is over when it goes.
	local function liveZone(d)
		if not d.part then return true end
		if not d.part.Parent then return false end

		-- Re-read every pass: these are tweened into place while the warning plays, so
		-- where the zone was when it appeared is not where it lands.
		if d.kind == 'circle' then
			d.pos = d.part.Position
			d.radius = d.part.Size.Y * 0.5
		else
			d.cf = d.part.CFrame
			d.size = d.part.Size
		end
		return true
	end

	local function anyDanger(pos, margin)
		for _, d in dangers do
			if inDanger(pos, d, margin) then return true end
		end
		return false
	end

	local function dodgeTarget(pos, anchor, ideal)
		local now = workspace:GetServerTimeNow()
		for i = #dangers, 1, -1 do
			local d = dangers[i]
			if now > d.expire or not liveZone(d) then table.remove(dangers, i) end
		end
		if #dangers == 0 then return nil end

		local margin = 5
		if not anyDanger(pos, margin) then return nil end

		refreshBarriers()

		-- Flying needs no floor, and demanding one is why it never dodged: every candidate
		-- was thrown out for having nothing underneath it, which is the normal state of
		-- affairs when you are in the air.
		local needFooting = mode() ~= 'Fly'

		--[[
			Straight out first, before sweeping for somewhere nice.

			Rings only offer points on a circle, and the shortest way out of a long lane is
			rarely on one - it will happily pick a spot the same distance away that runs
			along the lane rather than across it. The way out of a box is perpendicular to
			its nearest face, and out of a ring is directly outward, which is the shortest
			escape that exists and therefore the only one that beats a timer.

			Each zone we are standing in is asked where its edge is, and the nearest answer
			that is legal wins. Only if none of them are does the sweep below run, which is
			for the awkward case where every direct exit is blocked or inside another zone.
		]]
		local quickest, quickestDist
		for _, d in dangers do
			if inDanger(pos, d, margin) then
				local exit = safeSpot(pos, d, margin + 3)
				local travel = (exit - pos).Magnitude
				if (not quickestDist or travel < quickestDist)
					and (not needFooting or groundAt(exit, pos.Y))
					and not anyDanger(exit, margin + 3)
					and not insideBarrier(exit, 2)
					and not crossesBarrier(pos, exit) then
					quickest, quickestDist = exit, travel
				end
			end
		end
		if quickest then return quickest end

		for _, radius in DODGE_RINGS do
			local best, bestScore
			for i = 0, DODGE_SAMPLES - 1 do
				local angle = (i / DODGE_SAMPLES) * math.pi * 2
				local candidate = pos + Vector3.new(math.cos(angle), 0, math.sin(angle)) * radius

				-- Somewhere there is actually floor. Without this the search happily
				-- returned spots over a ledge or inside geometry, the step refused them
				-- every tick, and the farm stood still announcing a dodge it could not
				-- take - which is exactly what standing still while logging looked like.
				local footing = not needFooting or groundAt(candidate, pos.Y)

				if footing
					and not anyDanger(candidate, margin + 3)
					and not insideBarrier(candidate, 2)
					and not crossesBarrier(pos, candidate) then
					--[[
						Scored on staying in the fight, not on getting away from it.

						Picking whichever safe spot was furthest from every enemy meant
						every dodge was a retreat: it would leave the fight, walk back, and
						lose more time to the walking than the attack would ever have cost.

						So the spot that best keeps the target at fighting range wins, and
						crowding is a penalty rather than the whole score - enough to stop
						it stepping into the middle of a pack, not enough to send it to the
						far side of the room.
					]]
					--[[
						Weighted so that closing is cheap and backing off is expensive.

						Scoring purely on how near the ideal range a spot is treats a step
						back and a step in as equally good, and the ring behind is always
						the emptier one - so it drifted away from the fight every time.
						Overshooting inward costs a third of what falling back does, which
						turns a dodge into an approach whenever the geometry allows it.
					]]
					-- How long it takes to get there comes first: a spot that is perfect and
					-- unreachable in time is worth nothing.
					local score = (candidate - pos).Magnitude * 1.5

					if anchor then
						local gap = (candidate - anchor).Magnitude
						local want = ideal or 12
						score += gap > want and (gap - want) * 1.5 or (want - gap) * 0.5
					end

					for _, m in enemyCache do
						local part = m and m.Parent and enemyPart(m)
						if part then
							local gap = (part.Position - candidate).Magnitude
							if gap < 12 then score += (12 - gap) * 2 end
						end
					end

					if not bestScore or score < bestScore then best, bestScore = candidate, score end
				end
			end
			if best then return best end
		end

		return nil
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

		for _, slot in { 'q', 'e' } do
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
	local function rescan()
		enemyCache = {}
		pcall(function()
			for _, d in workspace:GetDescendants() do
				if d:IsA('Humanoid') and d.Health > 0 then
					local m = d.Parent
					if m and m:IsA('Model') and enemyPart(m)
						and not playersService:GetPlayerFromCharacter(m)
						and m:FindFirstAncestor('enemyFolder') then
						table.insert(enemyCache, m)
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

	local function nearestEnemy(pos)
		if os.clock() - lastScan > 1.5 or #enemyCache == 0 then rescan() end

		local best, bestPart, bestDist
		local anyBest, anyPart, anyDist

		for i = #enemyCache, 1, -1 do
			local m = enemyCache[i]
			local hum = m and m.Parent and m:FindFirstChildOfClass('Humanoid')
			local part = m and enemyPart(m)
			if not (m and m.Parent and hum and hum.Health > 0 and part) then
				table.remove(enemyCache, i)
			else
				local dist = (part.Position - pos).Magnitude
				if not anyDist or dist < anyDist then anyBest, anyPart, anyDist = m, part, dist end
				if (not bestDist or dist < bestDist) and reachable(pos, part) then
					best, bestPart, bestDist = m, part, dist
				end
			end
		end

		-- Falling back to the unreachable one on purpose: with the room already clear, the
		-- only thing left is whatever is through the next door, and walking at it is how
		-- the door gets opened.
		if best then return best, bestPart, bestDist end
		return anyBest, anyPart, anyDist
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
	local function stepTo(hrp, hum, goal)
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
		local function place(desired)
			local delta3 = desired - hrp.Position
			if delta3.Magnitude > full then
				desired = hrp.Position + delta3.Unit * full
			end
			hrp.CFrame = CFrame.new(desired) * (hrp.CFrame - hrp.CFrame.Position)
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
			if y then
				place(Vector3.new(target.X, y, target.Z))
				return
			end
		end

		for _, fraction in {0.6, 0.3} do
			local target = hrp.Position + direction * (full * fraction)
			local y = groundAt(target, hrp.Position.Y)
			if y then
				place(Vector3.new(target.X, y, target.Z))
				return
			end
		end

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
		groundParams.FilterDescendantsInstances = {lplr.Character}
		local below = workspace:Raycast(target + Vector3.new(0, 12, 0), Vector3.new(0, -400, 0), groundParams)
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
		if moving() then
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

	local waypoints, waypointIndex, pathGoal, pathBuiltAt = nil, 1, nil, 0

	local function clearPath()
		waypoints, waypointIndex, pathGoal = nil, 1, nil
	end

	local function buildPath(hrp, goal)
		local path = pathfindingService:CreatePath({
			AgentRadius = 3,
			AgentHeight = 6,
			AgentCanJump = true,
			WaypointSpacing = 8
		})
		local ok = pcall(path.ComputeAsync, path, hrp.Position, goal)
		if ok and path.Status == Enum.PathStatus.Success then
			waypoints, waypointIndex, pathGoal, pathBuiltAt = path:GetWaypoints(), 2, goal, os.clock()
			return true
		end
		clearPath()
		return false
	end

	local function walkTo(hum, hrp, goal, direct)
		-- Stepping and flying go where they are pointed, so they follow the route
		-- themselves rather than handing the humanoid a waypoint and hoping.
		if moving() then
			stepTo(hrp, hum, goal)
			return
		end

		-- Straight there when it is close and the route is unlikely to matter.
		if direct or not (UsePathfinding and UsePathfinding.Enabled) then
			hum:MoveTo(goal)
			return
		end

		local stale = not waypoints
			or not pathGoal
			or (pathGoal - goal).Magnitude > 12
			or os.clock() - pathBuiltAt > 3
			or waypointIndex > #waypoints

		if stale and not buildPath(hrp, goal) then
			-- No route found - walk at it anyway rather than standing still.
			hum:MoveTo(goal)
			return
		end

		local wp = waypoints[waypointIndex]
		if not wp then
			clearPath()
			hum:MoveTo(goal)
			return
		end

		if wp.Action == Enum.PathWaypointAction.Jump then
			hum.Jump = true
		end

		if (Vector3.new(wp.Position.X, hrp.Position.Y, wp.Position.Z) - hrp.Position).Magnitude < 5 then
			waypointIndex += 1
		end
		hum:MoveTo(wp.Position)
	end

	--[[
		Where to go once a room is empty.

		Rooms are streamed in by the server as the run progresses, so there is no map to
		read ahead of time - only whatever is currently under workspace.dungeon. The one
		furthest from where the run started is the one being opened up, so that is the way
		forward. Falling back to walking ahead keeps it moving if that lookup finds
		nothing rather than leaving it standing in a cleared room.
	]]
	local runOrigin
	local function nextRoomGoal(hrp)
		local dungeon = workspace:FindFirstChild('dungeon')
		if not dungeon then return nil end

		local best, bestDist
		for _, room in dungeon:GetChildren() do
			local ok, pivot = pcall(function() return room:GetPivot().Position end)
			if ok and pivot then
				local dist = (pivot - runOrigin).Magnitude
				if not bestDist or dist > bestDist then best, bestDist = pivot, dist end
			end
		end

		-- Already standing in the furthest room, so there is nothing further to aim at.
		if best and (best - hrp.Position).Magnitude < 15 then return nil end
		return best
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
	local function healSwap()
		local getStorage, equip, abilityUsed = remote('reloadInvy'), remote('equipItem'), remote('abilityUsed')
		if not (getStorage and equip and abilityUsed) then
			say('heal swap: a remote is missing (reloadInvy/equipItem/abilityUsed)')
			return false
		end

		local ok, storage = pcall(function() return getStorage:InvokeServer() end)
		if not ok or type(storage) ~= 'table' or type(storage.abilities) ~= 'table' then
			say('heal swap: could not read your storage')
			return false
		end

		local heals, owned = {}, 0
		for id, item in pairs(storage.abilities) do
			owned += 1
			if tostring(fv(item, 'name') or ''):lower():find('heal') then
				table.insert(heals, tostring(id):sub(9))
			end
		end
		if #heals == 0 then
			say(string.format('heal swap: none of your %d abilities is a heal, waiting for regen instead', owned))
			return false
		end
		say(string.format('heal swap: %d heal(s) found, switching', #heals))

		local savedWeapon, savedQ, savedE
		if type(storage.weapons) == 'table' then
			for id, item in pairs(storage.weapons) do
				if item.equipped == true then savedWeapon = tostring(id):sub(8) break end
			end
		end
		for id, item in pairs(storage.abilities) do
			local eq = item.equipped
			if type(eq) == 'table' then
				if eq.q then savedQ = tostring(id):sub(9) end
				if eq.e then savedE = tostring(id):sub(9) end
			end
		end

		local bestW, bestSP
		if type(storage.weapons) == 'table' then
			for id, item in pairs(storage.weapons) do
				local sp = tonumber(fv(item, 'spellPower')) or 0
				if not bestSP or sp > bestSP then bestW, bestSP = tostring(id):sub(8), sp end
			end
		end
		if bestW then pcall(function() equip:InvokeServer('weapon', bestW) end) end
		pcall(function() equip:InvokeServer('ability', heals[1], 'q') end)
		if #heals >= 2 then pcall(function() equip:InvokeServer('ability', heals[2], 'e') end) end
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

			for _, slot in { 'q', 'e' } do
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

		if savedWeapon then pcall(function() equip:InvokeServer('weapon', savedWeapon) end) end
		if savedQ then pcall(function() equip:InvokeServer('ability', savedQ, 'q') end) end
		if savedE then pcall(function() equip:InvokeServer('ability', savedE, 'e') end) end
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

			AutoFarm:Clean(runService.Heartbeat:Connect(function()
				if not moving() or not moveGoal then return end
				-- Nobody has renewed this in a while, so it is somewhere we used to want
				-- to be rather than somewhere we are going.
				if os.clock() - moveSetAt > 1 then
					moveGoal = nil
					return
				end
				local char = lplr.Character
				local hrp = char and char:FindFirstChild('HumanoidRootPart')
				local hum = char and char:FindFirstChildOfClass('Humanoid')
				if hrp and hum then
					stepTo(hrp, hum, moveGoal)
				end
			end))

			local weaponUsed = remote('weaponUsed')
			local abilityUsed = remote('abilityUsed')
			local retreating = false

			local startChar = lplr.Character
			local startHrp = startChar and startChar:FindFirstChild('HumanoidRootPart')
			runOrigin = startHrp and startHrp.Position or Vector3.zero

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

					local target, part, dist = nearestEnemy(hrp.Position)

					-- DODGE first: standing in a telegraphed attack costs more than a turn
					-- spent fighting, so this outranks everything below it.
					if DodgeAttacks.Enabled then
						watchProjectiles()
						local band = (math.min(KeepDistance.Value, AttackRange.Value - 2) + AttackRange.Value) * 0.5
						local safe = dodgeTarget(hrp.Position, part and part.Position or nil, band)
							or projectileDodge(hrp.Position)
						if safe then
							clearPath()
							say(string.format('dodging to %.0f studs away', (safe - hrp.Position).Magnitude))
							goTo(hum, hrp, safe)
							return
						end
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
						local _, part, dist = nearestEnemy(hrp.Position)
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

						--[[
							Fight from a band, not from a spot.

							Walking to attack range and standing there is what was getting
							us killed: melee enemies close the last few studs themselves
							and then simply hit us until the HP threshold noticed, by which
							point a pack had already surrounded us.

							So there is a near edge as well as a far one. Inside it, back
							off - while still swinging, since anything already in reach
							stays in reach as we give ground. Held below the far edge so
							the two can never cross and leave nowhere to stand.
						]]
						local keep = math.min(KeepDistance.Value, reach - 2)
						local away = (hrp.Position - part.Position) * Vector3.new(1, 0, 1)
						away = away.Magnitude > 0.1 and away.Unit or hrp.CFrame.LookVector

						local push, crowded = crowding(hrp.Position, keep)

						if crowded > 0 then
							-- Anything at all inside the keep distance takes priority over
							-- circling: get clear of the pack first, then resume.
							clearPath()
							local out = push.Magnitude > 0.1 and push.Unit or away
							goTo(hum, hrp, hrp.Position + out * (keep + 10))
						elseif (dist or 0) < keep then
							clearPath()
							goTo(hum, hrp, hrp.Position + away * ((keep - (dist or 0)) + 8))
						elseif (dist or math.huge) > reach then
							-- Close the gap. Pathfinding while far, straight in once near,
							-- because a route recomputed around a moving enemy is worse
							-- than walking at it.
							walkTo(hum, hrp, part.Position, (dist or 0) < 25)
						elseif Strafe ~= nil and Strafe.Enabled then
							clearPath()

							local ideal = (keep + reach) * 0.5
							local tangent = Vector3.new(-away.Z, 0, away.X)

							-- Reconsidered on a timer rather than every tick, but chosen by
							-- which side is emptier rather than simply alternating.
							if os.clock() > strafeUntil then
								strafeDir = clearestTangent(hrp.Position, part.Position, tangent, ideal)
								strafeUntil = os.clock() + 2
							end

							goTo(hum, hrp, part.Position + (away * ideal) + (tangent * strafeDir * 14))
						else
							clearPath()
							-- Stop walking and hold position while swinging, so the hit is
							-- thrown from where the server already believes we are.
							hum:MoveTo(hrp.Position)
						end
						--[[
							Turned only to attack, never while walking.

							faceNearest writes the root part's CFrame, and doing that every
							tick resets the humanoid's physics state - which cancels the
							walk MoveTo had just started. The character turned to face its
							target and then stood there, every time. Harmless in the old
							version because that teleported anyway; fatal once movement
							depends on actually walking.

							One write immediately before the swing is enough to aim, and
							far too rare to interfere with getting anywhere.
						]]
						if (dist or math.huge) <= reach and not (busy and busy.Value ~= false) then
							faceNearest()
							swing(char, weaponUsed)
							castAbilities(abilityUsed)
						end
					else
						-- Room clear: head for whatever the server has opened up.
						local goal = nextRoomGoal(hrp)
						if goal then
							walkTo(hum, hrp, goal)
						else
							clearPath()
							goTo(hum, hrp, hrp.Position + hrp.CFrame.LookVector * 20)
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
	KeepDistance = AutoFarm:CreateSlider({ Name = 'Keep Distance', Min = 0, Max = 50, Default = 9, Suffix = ' studs',
		Tooltip = 'Never let an enemy get closer than this while fighting - back away instead, still attacking. Held below Attack Range (default 9)' })
	KeepAway = AutoFarm:CreateSlider({ Name = 'Keep Away', Min = 20, Max = 200, Default = 70, Suffix = ' studs',
		Tooltip = 'How far to put between you and the nearest enemy while recovering (default 70)' })
	AttackRange = AutoFarm:CreateSlider({ Name = 'Attack Range', Min = 4, Max = 60, Default = 12, Suffix = ' studs',
		Tooltip = 'How close to get before swinging. Melee wants this low, a staff can sit further back (default 12)' })
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
		Tooltip = "Reads the game's own attack telegraphs and walks you out before they land. Works on every boss, no per-boss setup" })
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

	for _, slot in {'q', 'e'} do
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