--[[
	Dungeon Quest lobby, ported from the VainV6 client.

	This is the second half of that client's Dungeon Quest support - the dungeon itself
	is the 85776757589518 folder. It is a separate place, so it needs its own folder:
	the loader dispatches on game.PlaceId, and lobby modules loaded under the dungeon's
	id would simply never run.

	Everything here is built on paths verified against the lobby place dump rather than
	guessed at, and all eight of the remotes it uses were checked against it again on
	the way in: createLobby, sellItemEvent, equipItem, getPlayerStorage, readyUp,
	startDungeon, startBossRaid and addPlayerToWhitelist.
]]

-- Dungeon Quest LOBBY (universe 9931749389) — Vain modules.
-- Lobby actions: create/start dungeon, ready up, boss raid, sell, equip.
-- Verified from the place dump: ReplicatedStorage.remotes.* ,
--   createLobby(name, difficulty, level, hardcore, friendsOnly, waveDefence),
--   sellItemEvent({weapon={ids},ability={},chest={},helmet={}}),
--   equipItem(category, uniqueItemNum[, slot]),
--   getPlayerStorage() -> {weapons,abilities,chests,helmets} keyed "<cat>_<id>".

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

local remotesFolder = replicatedStorage:FindFirstChild('remotes')
if not remotesFolder then pcall(function() remotesFolder = replicatedStorage:WaitForChild('remotes', 10) end) end
local function remote(name) return remotesFolder and remotesFolder:FindFirstChild(name) end

local function playerLevel()
	local ls = lplr:FindFirstChild('leaderstats')
	local lvl = ls and ls:FindFirstChild('Level')
	return (lvl and tonumber(lvl.Value)) or 1
end
-- field value helper: storage items may store a field as a number or as {Value=x}.
local function fv(item, key)
	local v = item[key]
	if type(v) == 'table' and v.Value ~= nil then v = v.Value end
	return v
end

-- ── Auto Start Dungeon ───────────────────────────────────────────────────────
run(function()
	local AutoStart, Dungeon, Difficulty, Hardcore, FriendsOnly, WaveDefence, BestDungeon, BestDifficulty, Buffer
	-- Dungeon names for the dropdown. Level requirements are per dungeon AND per
	-- difficulty and change across updates, so we ask the game itself via the
	-- getDungeonStats remote: getDungeonStats(name) -> { [difficulty] = { levelReq = N } }.
	local DUNGEONS = {
		'Desert Temple', 'Winter Outpost', 'The Underworld', 'Samurai Palace', 'The Canals',
		"King's Castle", 'Aquatic Temple', 'Enchanted Forest', 'Volcanic Chambers', 'Ghastly Harbor',
		'Pirate Island', 'Steampunk Sewers', 'Northern Lands', 'Orbital Outpost',
	}
	local names = {}
	for _, n in DUNGEONS do table.insert(names, n) end
	local statsCache = {}
	local function dungeonStats(name)
		if statsCache[name] == nil then
			local r = remote('getDungeonStats')
			local ok, res = pcall(function() return r and r:InvokeServer(name) end)
			statsCache[name] = (ok and type(res) == 'table') and res or false
		end
		return statsCache[name] or nil
	end
	-- level needed for (dungeon, difficulty), or nil if that difficulty isn't offered.
	local function levelReqFor(name, difficulty)
		local st = dungeonStats(name)
		local d = st and st[difficulty]
		return d and tonumber(d.levelReq) or nil
	end
	local DIFF_ORDER = { 'Easy', 'Medium', 'Insane', 'Nightmare' } -- ascending; only higher dungeons offer Nightmare
	-- hardest difficulty of `name` you can enter at your level (nil if you can't enter it at all).
	local function bestDifficultyOf(name, lvl)
		local best
		for _, diff in DIFF_ORDER do
			local req = levelReqFor(name, diff)
			if req and req <= lvl then best = diff end
		end
		return best
	end
	-- lowest level a dungeon needs on ANY difficulty = can you set foot in it?
	local function entryReq(name)
		local lo
		for _, diff in DIFF_ORDER do
			local req = levelReqFor(name, diff)
			if req and (not lo or req < lo) then lo = req end
		end
		return lo
	end
	-- highest dungeon you can enter (by its easiest difficulty) for your level (nil if none).
	local function bestDungeonName(lvl)
		local best, bestReq
		for _, n in DUNGEONS do
			local req = entryReq(n)
			if req and req <= lvl and (not bestReq or req > bestReq) then
				best, bestReq = n, req
			end
		end
		return best
	end

	AutoStart = vain.Categories.Blatant:CreateModule({
		Name = 'Auto Start Dungeon',
		Tooltip = 'Creates a lobby with your chosen settings and starts the run. Only fires while in the lobby/town.',
		Function = function(callback)
			if not callback then return end
			local createLobby = remote('createLobby')
			local startDungeon = remote('startDungeon')
			local readyUp = remote('readyUp')
			local notified = false
			repeat
				pcall(function()
					if not (createLobby and startDungeon) then return end
					local lvl = playerLevel()
					local name = BestDungeon.Enabled and bestDungeonName(lvl) or Dungeon.Value
					if not name then
						if not notified and vain and vain.CreateNotification then
							vain:CreateNotification('Vain DQ', 'No dungeon is enterable at your level (' .. lvl .. ').', 5, 'alert')
							notified = true
						end
						return
					end
					-- Best Difficulty: auto-pick the HARDEST difficulty of this dungeon you can do,
					-- otherwise use the Difficulty dropdown.
					local difficulty = BestDifficulty.Enabled and bestDifficultyOf(name, lvl) or Difficulty.Value
					if not difficulty then
						if not notified and vain and vain.CreateNotification then
							vain:CreateNotification('Vain DQ', 'Not high enough level for any difficulty of "' .. tostring(name) .. '".', 5, 'alert')
							notified = true
						end
						return
					end
					-- validate level BEFORE trying, so we never spam failed create calls.
					local req = levelReqFor(name, difficulty)
					if req and req > lvl then
						if not notified and vain and vain.CreateNotification then
							vain:CreateNotification('Vain DQ', '"' .. tostring(name) .. '" on ' .. tostring(difficulty) .. ' needs level ' .. req .. ' - you are ' .. lvl .. '.', 5, 'alert')
							notified = true
						end
						return
					end
					-- createLobby(name, difficulty, levelReq, hardcore, friendsOnly/private, waveDefence)
					-- returns true ONLY when the party is actually created -> start only then.
					local ok = createLobby:InvokeServer(name, difficulty, req or playerLevel(),
						Hardcore.Enabled, FriendsOnly.Enabled, WaveDefence.Enabled)
					if ok ~= true then
						if not notified and vain and vain.CreateNotification then
							vain:CreateNotification('Vain DQ', 'Create party failed for "' .. tostring(name)
								.. '" (' .. tostring(difficulty) .. '). Try again in a moment.', 5, 'alert')
							notified = true
						end
						return
					end
					notified = false
					task.wait(Buffer.Value)
					if readyUp then pcall(function() readyUp:FireServer() end) end
					task.wait(0.2)
					startDungeon:FireServer() -- starts the party -> teleports everyone into the dungeon
				end)
				task.wait(math.max(Buffer.Value + 3, 4))
			until not AutoStart.Enabled
		end,
	})
	Dungeon = AutoStart:CreateDropdown({ Name = 'Dungeon', List = names, Default = names[1],
		Tooltip = 'Which dungeon to run (ignored when Best Dungeon is on).' })
	Difficulty = AutoStart:CreateDropdown({ Name = 'Difficulty',
		List = { 'Easy', 'Medium', 'Insane', 'Nightmare' }, Default = 'Insane',
		Tooltip = 'Used only when Best Difficulty is OFF. Higher dungeons also offer Nightmare.' })
	BestDungeon = AutoStart:CreateToggle({ Name = 'Best Dungeon', Default = false,
		Tooltip = 'Auto-pick the highest-level dungeon you can currently enter.' })
	BestDifficulty = AutoStart:CreateToggle({ Name = 'Best Difficulty', Default = true,
		Tooltip = 'Auto-pick the HARDEST difficulty of the chosen dungeon you can do (Easy < Medium < Insane < Nightmare). Turn off to force the Difficulty dropdown.' })
	Hardcore = AutoStart:CreateToggle({ Name = 'Hardcore', Default = false })
	FriendsOnly = AutoStart:CreateToggle({ Name = 'Friends Only', Default = false })
	WaveDefence = AutoStart:CreateToggle({ Name = 'Wave Defence', Default = false })
	Buffer = AutoStart:CreateSlider({ Name = 'Buffer Interval', Min = 0, Max = 10, Default = 2, Decimal = 10, Suffix = 's',
		Tooltip = 'How long to wait after creating the lobby before starting.' })
end)

-- ── Auto Ready Up / Auto Boss Raid ───────────────────────────────────────────
local function looper(category, name, tooltip, remoteName, interval)
	run(function()
		local Module
		Module = category:CreateModule({
			Name = name, Tooltip = tooltip,
			Function = function(callback)
				if not callback then return end
				repeat
					pcall(function()
						local r = remote(remoteName)
						if r then r:FireServer() end
					end)
					task.wait(interval)
				until not Module.Enabled
			end,
		})
	end)
end
looper(vain.Categories.Blatant, 'Auto Ready Up', 'Automatically readies up in the party lobby.', 'readyUp', 1)
looper(vain.Categories.Blatant, 'Auto Boss Raid', 'Starts the boss raid as soon as the lobby is ready.', 'startBossRaid', 1)

-- ── Auto Sell ────────────────────────────────────────────────────────────────
run(function()
	local AutoSell, SellWeapons, SellAbilities, SellChests, SellHelmets, MaxRarity, KeepEquipped, SellInterval
	-- reloadInvy reports rarity lowercase ("rare"), so key + look up in lowercase.
	local RARITY = { common = 1, uncommon = 2, rare = 3, epic = 4, legendary = 5, divine = 6 }
	AutoSell = vain.Categories.Utility:CreateModule({
		Name = 'Auto Sell',
		Tooltip = 'Sells items of the chosen categories at or below a rarity threshold. Skips equipped gear.',
		Function = function(callback)
			if not callback then return end
			local getStorage = remote('reloadInvy')
			local sellEvt = remote('sellItemEvent')
			repeat
				pcall(function()
					if not (getStorage and sellEvt) then return end
					local storage = getStorage:InvokeServer()
					if type(storage) ~= 'table' then return end
					local maxR = RARITY[tostring(MaxRarity.Value):lower()] or 1
					local toSell = { weapon = {}, ability = {}, chest = {}, helmet = {} }
					local groups = {
						{ on = SellWeapons, sub = storage.weapons, cat = 'weapon', strip = 8 },
						{ on = SellAbilities, sub = storage.abilities, cat = 'ability', strip = 9 },
						{ on = SellChests, sub = storage.chests, cat = 'chest', strip = 7 },
						{ on = SellHelmets, sub = storage.helmets, cat = 'helmet', strip = 8 },
					}
					for _, g in groups do
						if g.on.Enabled and type(g.sub) == 'table' then
							for id, item in pairs(g.sub) do
								local rank = RARITY[tostring(fv(item, 'rarity') or ''):lower()]
								local eq = item.equipped
								local equipped = eq == true or (type(eq) == 'table' and (eq.q or eq.e or eq.q2 or eq.e2))
								if rank and rank <= maxR and not (KeepEquipped.Enabled and equipped) then
									local num = tonumber(tostring(id):sub(g.strip))
								if num then table.insert(toSell[g.cat], num) end
								end
							end
						end
					end
					if #toSell.weapon + #toSell.ability + #toSell.chest + #toSell.helmet > 0 then
						sellEvt:FireServer(toSell)
					end
				end)
				task.wait(SellInterval.Value)
			until not AutoSell.Enabled
		end,
	})
	SellWeapons = AutoSell:CreateToggle({ Name = 'Sell Weapons', Default = true })
	SellAbilities = AutoSell:CreateToggle({ Name = 'Sell Abilities', Default = false })
	SellChests = AutoSell:CreateToggle({ Name = 'Sell Chests (armor)', Default = true })
	SellHelmets = AutoSell:CreateToggle({ Name = 'Sell Helmets', Default = true })
	MaxRarity = AutoSell:CreateDropdown({ Name = 'Max Rarity to Sell',
		List = { 'Common', 'Uncommon', 'Rare', 'Epic', 'Legendary', 'Divine' }, Default = 'Rare',
		Tooltip = 'Sells items of this rarity and everything below it.' })
	KeepEquipped = AutoSell:CreateToggle({ Name = 'Keep Equipped', Default = true,
		Tooltip = 'Never sell items you currently have equipped.' })
	SellInterval = AutoSell:CreateSlider({ Name = 'Sell Interval', Min = 1, Max = 30, Default = 5, Suffix = 's' })
end)

-- ── Auto Equip Best ──────────────────────────────────────────────────────────
run(function()
	local AutoEquip, EquipClass, EquipInterval
	local RARITY = { common = 1, uncommon = 2, rare = 3, epic = 4, legendary = 5, divine = 6 }
	local function power(item)
		-- rank by the class's power stat; weapons expose physicalDamage rather than
		-- physicalPower, so a warrior checks both. If the inventory table carries no
		-- power stats, fall back to rarity so it still equips the best it can see.
		local fields = EquipClass.Value == 'Mage' and { 'spellPower' }
			or { 'physicalPower', 'physicalDamage' }
		local best = 0
		for _, k in fields do best = math.max(best, tonumber(fv(item, k)) or 0) end
		if best > 0 then return best end
		return RARITY[tostring(fv(item, 'rarity') or ''):lower()] or 0
	end
	AutoEquip = vain.Categories.Utility:CreateModule({
		Name = 'Auto Equip Best',
		Tooltip = 'Equips your highest-power gear for the chosen class (Warrior = physical power, Mage = spell power).',
		Function = function(callback)
			if not callback then return end
			local getStorage = remote('reloadInvy')
			local equip = remote('equipItem')
			repeat
				pcall(function()
					if not (getStorage and equip) then return end
					local storage = getStorage:InvokeServer()
					if type(storage) ~= 'table' then return end
					local groups = {
						{ sub = storage.weapons, cat = 'weapon', strip = 8 },
						{ sub = storage.chests, cat = 'chest', strip = 7 },
						{ sub = storage.helmets, cat = 'helmet', strip = 8 },
					}
					for _, g in groups do
						if type(g.sub) == 'table' then
							local bestId, bestPow, bestEq
							for id, item in pairs(g.sub) do
								local p = power(item)
								if not bestPow or p > bestPow then
									bestId, bestPow, bestEq = tostring(id):sub(g.strip), p, item.equipped
								end
							end
							if bestId and bestEq ~= true then
								equip:InvokeServer(g.cat, tonumber(bestId))
							end
						end
					end
				end)
				task.wait(EquipInterval.Value)
			until not AutoEquip.Enabled
		end,
	})
	EquipClass = AutoEquip:CreateDropdown({ Name = 'Class', List = { 'Warrior', 'Mage' }, Default = 'Warrior',
		Tooltip = 'Warrior maximizes physical power; Mage maximizes spell power.' })
	EquipInterval = AutoEquip:CreateSlider({ Name = 'Equip Interval', Min = 1, Max = 30, Default = 5, Suffix = 's' })
end)

--VAINEOF
