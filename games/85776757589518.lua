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
run(function()
	local AutoFarm, SafeHP, RecoverHP, HoverHeight, EnemyOffset, FarmDelay, UseTeleport, HealSwap, DodgeAttacks, BossHeight

	-- ── Boss detection + attack dodging ────────────────────────────────────
	-- Every boss/enemy AREA attack is telegraphed to the client over a BridgeNet2
	-- 'precastHitbox' bridge: Cube {cframe,size} or Circle {position,radius}, each with
	-- a delayUntilAttack lead time. We attach a second listener to that same bridge,
	-- remember each danger zone, and step out of it before it lands. This dodges EVERY
	-- boss's telegraphed attacks without hardcoding a single boss.
	local dangers = {}
	local dodgeReady = false
	local function setupDodge()
		if dodgeReady then return end
		dodgeReady = true
		pcall(function()
			local util = replicatedStorage:FindFirstChild('Utility')
			local bn = util and util:FindFirstChild('BridgeNet2')
			if not bn then return end
			local BridgeNet2 = require(bn)
			local bridge = BridgeNet2.ReferenceBridge('precastHitbox')
			bridge:Connect(function(data)
				if type(data) ~= 'table' then return end
				local start = tonumber(data.startTime) or workspace:GetServerTimeNow()
				local delay = tonumber(data.delayUntilAttack) or 0.3
				local expire = start + delay + 0.4 -- stay clear until just after the hit resolves
				if typeof(data.cframe) == 'CFrame' and typeof(data.size) == 'Vector3' then
					table.insert(dangers, { kind = 'cube', cf = data.cframe, size = data.size, expire = expire })
				elseif typeof(data.position) == 'Vector3' and tonumber(data.radius) then
					table.insert(dangers, { kind = 'circle', pos = data.position, radius = tonumber(data.radius), expire = expire })
				end
			end)
		end)
	end

	-- boss fight active? the bossRoom's fightingBoss flag is the game's own signal.
	local function bossActive()
		local dungeon = workspace:FindFirstChild('dungeon')
		local bossRoom = dungeon and dungeon:FindFirstChild('bossRoom')
		local fb = bossRoom and bossRoom:FindFirstChild('fightingBoss')
		return fb ~= nil and fb:IsA('BoolValue') and fb.Value == true
	end

	-- is pos inside danger zone d (with a horizontal safety margin)?
	local function inDanger(pos, d, margin)
		if d.kind == 'circle' then
			local dx, dz = pos.X - d.pos.X, pos.Z - d.pos.Z
			return (dx * dx + dz * dz) <= (d.radius + margin) ^ 2
		else
			local lp = d.cf:PointToObjectSpace(pos)
			local h = d.size * 0.5
			return math.abs(lp.X) <= h.X + margin and math.abs(lp.Z) <= h.Z + margin
				and math.abs(lp.Y) <= h.Y + 8
		end
	end

	-- nearest position OUTSIDE danger zone d (horizontal push-out).
	local function safeSpot(pos, d, margin)
		if d.kind == 'circle' then
			local dir = Vector3.new(pos.X - d.pos.X, 0, pos.Z - d.pos.Z)
			dir = dir.Magnitude > 0.1 and dir.Unit or Vector3.new(1, 0, 0)
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

	-- purge expired zones; if we're standing in one, return where to step to (else nil).
	local function dodgeTarget(pos)
		local now = workspace:GetServerTimeNow()
		for i = #dangers, 1, -1 do
			if now > dangers[i].expire then table.remove(dangers, i) end
		end
		local margin = 5
		for _, d in dangers do
			if inDanger(pos, d, margin) then return safeSpot(pos, d, margin + 3) end
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
	local enemyCache, lastScan = {}, 0
	local function enemyPart(m)
		return m.PrimaryPart or m:FindFirstChild('HumanoidRootPart') or m:FindFirstChild('Torso')
			or m:FindFirstChild('UpperTorso') or m:FindFirstChildWhichIsA('BasePart')
	end
	local function rescan()
		enemyCache = {}
		pcall(function()
			for _, d in workspace:GetDescendants() do
				if d:IsA('Humanoid') and d.Health > 0 then
					local m = d.Parent
					-- only real dungeon mobs: a Model living under an 'enemyFolder'
					-- (NOT town NPCs, players, pets or decorations).
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
	local function nearestEnemy(pos)
		if os.clock() - lastScan > 1.5 or #enemyCache == 0 then rescan() end
		local best, bestPart, bestDist
		for i = #enemyCache, 1, -1 do
			local m = enemyCache[i]
			local hum = m and m.Parent and m:FindFirstChildOfClass('Humanoid')
			local part = m and enemyPart(m)
			if not (m and m.Parent and hum and hum.Health > 0 and part) then
				table.remove(enemyCache, i)
			else
				local dist = (part.Position - pos).Magnitude
				if not bestDist or dist < bestDist then best, bestPart, bestDist = m, part, dist end
			end
		end
		return best, bestPart
	end

	-- Heal-swap: when HP is low, if the inventory has heal spell(s), save the current
	-- loadout, switch to the best spell-power (mage) weapon + 1-2 heal spells, cast them
	-- to full HP while floating safe, then restore the original loadout. Returns false
	-- (so the caller falls back to float-and-regen) if there's no heal spell.
	local function healSwap()
		local getStorage, equip, abilityUsed = remote('reloadInvy'), remote('equipItem'), remote('abilityUsed')
		if not (getStorage and equip and abilityUsed) then return false end
		local storage = getStorage:InvokeServer()
		if type(storage) ~= 'table' or type(storage.abilities) ~= 'table' then return false end

		-- heal spells in inventory (detected by name, e.g. "Chain Heal" / "Universal Heal")
		local heals = {}
		for id, item in pairs(storage.abilities) do
			if tostring(fv(item, 'name') or ''):lower():find('heal') then
				table.insert(heals, tostring(id):sub(9))
			end
		end
		if #heals == 0 then return false end

		-- remember the current loadout (weapon + q/e abilities), whatever set it is
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

		-- switch to the best spell-power weapon + the heal spell(s)
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

		-- cast the heals until full HP (staying floated out of reach)
		local t0 = os.clock()
		while AutoFarm.Enabled and os.clock() - t0 < 12 do
			local char = lplr.Character
			local hum = char and char:FindFirstChildOfClass('Humanoid')
			local hrp = char and char:FindFirstChild('HumanoidRootPart')
			if not (hum and hrp) then break end
			if hum.MaxHealth > 0 and hum.Health / hum.MaxHealth >= 0.98 then break end
			hrp.CFrame = CFrame.new(hrp.Position.X, hrp.Position.Y + HoverHeight.Value, hrp.Position.Z)
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

		-- restore the original loadout (mage or warrior — whatever it was)
		if savedWeapon then pcall(function() equip:InvokeServer('weapon', savedWeapon) end) end
		if savedQ then pcall(function() equip:InvokeServer('ability', savedQ, 'q') end) end
		if savedE then pcall(function() equip:InvokeServer('ability', savedE, 'e') end) end
		return true
	end

	AutoFarm = vain.Categories.Blatant:CreateModule({
		Name = 'Auto Farm',
		Tooltip = 'Clears the whole dungeon automatically: kills every enemy with your weapon + Q/E, and floats to safety to recover HP so you never die. Teleports onto enemies (may trip anti-cheat on some servers).',
		Function = function(callback)
			if not callback then return end
			local weaponUsed = remote('weaponUsed')
			local abilityUsed = remote('abilityUsed')
			local retreating = false
			repeat
				pcall(function()
					local char = lplr.Character
					local hrp = char and char:FindFirstChild('HumanoidRootPart')
					local hum = char and char:FindFirstChildOfClass('Humanoid')
					if not (char and hrp and hum) then return end
					local peaceful = lplr:FindFirstChild('peaceful')
					if peaceful and peaceful.Value == true then return end -- in town/lobby, nothing to farm
					
					-- DODGE (top priority): if we're standing in a telegraphed attack, get out NOW.
					if DodgeAttacks.Enabled then
						local safe = dodgeTarget(hrp.Position)
						if safe then
							hum.PlatformStand = false
							hrp.Anchored = false
							hrp.CFrame = CFrame.new(safe)
							hrp.AssemblyLinearVelocity = Vector3.zero
							return
						end
					end

					-- safety: drop into retreat below SafeHP, resume once RecoverHP reached
					local hpFrac = hum.MaxHealth > 0 and hum.Health / hum.MaxHealth or 1
					if hpFrac <= SafeHP.Value / 100 then retreating = true end
					if retreating then
						hum.PlatformStand = true
						hrp.Anchored = false
						hrp.CFrame = CFrame.new(hrp.Position.X, hrp.Position.Y + HoverHeight.Value, hrp.Position.Z)
						hrp.AssemblyLinearVelocity = Vector3.zero
						-- heal-swap first (heals to full + restores loadout); if it can't
						-- (no heal spell owned) fall back to waiting for natural regen.
						if HealSwap.Enabled and healSwap() then
							retreating = false
							hum.PlatformStand = false
							hrp.Anchored = false
							return
						end
						if hpFrac >= math.min(RecoverHP.Value / 100, 0.98) then
							retreating = false
							hum.PlatformStand = false
							hrp.Anchored = false
						end
						return
					end

					local target, part = nearestEnemy(hrp.Position)
					if target and part then
						local busy = char:FindFirstChild('busyCasting')
						if UseTeleport.Enabled then
							-- hover beside the enemy and FACE it in full 3D (pitch on X AND Y so
							-- swing + abilities travel INTO it, not over its head).
							local ep = part.Position
							local dir = (hrp.Position - ep) * Vector3.new(1, 0, 1)
							dir = dir.Magnitude > 0.1 and dir.Unit or Vector3.new(0, 0, 1)
							-- while a boss is being fought, hover higher (bosses have big ground attacks)
							local height = bossActive() and BossHeight.Value or EnemyOffset.Value
							local myPos = ep + dir * 4 + Vector3.new(0, height, 0)
							hrp.Anchored = false
							-- PlatformStand disables the Humanoid's auto-upright, so the pitched
							-- look-at HOLDS instead of snapping back every frame (that snap-back
							-- was the "Y axis is buggy" jitter). It is NOT anchoring, so the game
							-- still sees us as a live target and combat works both ways.
							hum.PlatformStand = true
							hrp.CFrame = CFrame.lookAt(myPos, ep)
							hrp.AssemblyLinearVelocity = Vector3.zero
						else
							hrp.Anchored = false
							hum.PlatformStand = false
							hum:Move((part.Position - hrp.Position) * Vector3.new(1, 0, 1))
							faceNearest()
						end
						if not (busy and busy.Value ~= false) then
							swing(char, weaponUsed)
							castAbilities(abilityUsed)
						end
					else
						-- room clear: unanchor and nudge forward to trigger the next room
						hrp.Anchored = false
						hum.PlatformStand = false
						hum:Move(hrp.CFrame.LookVector * Vector3.new(1, 0, 1))
					end
				end)
				task.wait(FarmDelay.Value)
			until not AutoFarm.Enabled
			pcall(function()
				local ch = lplr.Character
				local hum = ch and ch:FindFirstChildOfClass('Humanoid')
				local hrp = ch and ch:FindFirstChild('HumanoidRootPart')
				if hum then hum.PlatformStand = false end
				if hrp then hrp.Anchored = false end -- never leave the character stuck anchored
			end)
		end,
	})
	SafeHP = AutoFarm:CreateSlider({ Name = 'Retreat below HP', Min = 5, Max = 90, Default = 55, Suffix = '%',
		Tooltip = 'Anchor high out of reach and stop fighting when your HP drops below this. Raise it if you still die.' })
	RecoverHP = AutoFarm:CreateSlider({ Name = 'Resume at HP', Min = 20, Max = 100, Default = 85, Suffix = '%',
		Tooltip = 'Come back down and resume once HP recovers to this.' })
	HoverHeight = AutoFarm:CreateSlider({ Name = 'Retreat Height', Min = 20, Max = 400, Default = 150, Suffix = ' studs',
		Tooltip = 'How high to float above the map while recovering (out of enemy reach).' })
	EnemyOffset = AutoFarm:CreateSlider({ Name = 'Attack Height', Min = 0, Max = 30, Default = 8, Suffix = ' studs',
		Tooltip = 'Studs above each enemy. The character now pitches to aim DOWN at the enemy (held by PlatformStand), so you can hover safely up here and abilities still land. Lower it toward 0 if you want your short-range swing to connect too.' })
	FarmDelay = AutoFarm:CreateSlider({ Name = 'Loop Delay', Min = 0, Max = 0.5, Default = 0.1, Decimal = 100, Suffix = 's',
		Tooltip = 'Time between farm ticks (attack + reposition).' })
	UseTeleport = AutoFarm:CreateToggle({ Name = 'Teleport to Enemies', Default = true,
		Tooltip = 'On: instantly reposition onto each enemy (fast, may trip anti-cheat). Off: walk to them (slower, safer).' })
	HealSwap = AutoFarm:CreateToggle({ Name = 'Heal Swap when low', Default = true,
		Tooltip = 'When low, if you own a heal spell: swap to best spell-power weapon + 1-2 heals, heal to full, then restore your set. Requires the game to allow mid-run equipping.' })
		DodgeAttacks = AutoFarm:CreateToggle({ Name = 'Dodge Attacks', Default = true,
			Tooltip = "Reads the game's own attack telegraphs (the neon danger zones bosses/enemies cast) and steps you out before they hit. Works on every boss, no per-boss setup." })
		BossHeight = AutoFarm:CreateSlider({ Name = 'Boss Attack Height', Min = 0, Max = 60, Default = 16, Suffix = ' studs',
			Tooltip = 'Attack height used automatically while a boss is being fought - bosses have bigger ground attacks, so it hovers higher than the normal Attack Height. Combined with Dodge Attacks you should take little to no damage.' })
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