local run = function(func)
	func()
end
local cloneref = cloneref or function(obj)
	return obj
end
local vainEvents = setmetatable({}, {
	__index = function(self, index)
		self[index] = Instance.new('BindableEvent')
		return self[index]
	end
})

local playersService = cloneref(game:GetService('Players'))
local replicatedStorage = cloneref(game:GetService('ReplicatedStorage'))
local runService = cloneref(game:GetService('RunService'))
local inputService = cloneref(game:GetService('UserInputService'))
local tweenService = cloneref(game:GetService('TweenService'))
local httpService = cloneref(game:GetService('HttpService'))
local textChatService = cloneref(game:GetService('TextChatService'))
local collectionService = cloneref(game:GetService('CollectionService'))
local contextActionService = cloneref(game:GetService('ContextActionService'))
local guiService = cloneref(game:GetService('GuiService'))
local coreGui = cloneref(game:GetService('CoreGui'))
local starterGui = cloneref(game:GetService('StarterGui'))

local isnetworkowner = identifyexecutor and table.find({'AWP', 'Nihon'}, ({identifyexecutor()})[1]) and isnetworkowner or function()
	return true
end
local gameCamera = workspace.CurrentCamera
local lplr = playersService.LocalPlayer
local assetfunction = getcustomasset

local vain = shared.vain

-- Profiles key everything by name, so a rename would otherwise silently reset whatever
-- was saved under the old one. These are consulted only when the saved name matches
-- nothing, so a name still in use by another game is never redirected.
vain.Renames = vain.Renames or {Modules = {}, Options = {}}
for old, new in {
	Breaker = 'Nuker',
	['Better Spectating'] = 'BetterSpectating',
	AutoAdetunde = 'Adetunde',
	-- Davey Aim and Auto Davey were merged into one module, so a config saved under either
	-- old name carries its settings across rather than resetting them.
	-- The Davey modules were reshuffled and then renamed to match the spacing every other
	-- module uses, so a config saved under any of the older names still loads.
	['Auto Davey'] = 'PirateDavey',
	['Pirate Davey'] = 'PirateDavey',
	['Davey Aim'] = 'DaveyAim'
} do
	vain.Renames.Modules[old] = new
end
for old, new in {
	['Break range'] = 'Break Range',
	['Break speed'] = 'Break Speed',
	['Update rate'] = 'Update Rate',
	['Limit to items'] = 'Limit to Items',
	Quantity = 'Show Amount',
	['Full Layers'] = 'Highlight Full Layers',
	Camera = 'View Mode',
	['Camera Mode'] = 'View Mode'
} do
	vain.Renames.Options[old] = new
end

local entitylib = vain.Libraries.entity
local targetinfo = vain.Libraries.targetinfo
local sessioninfo = vain.Libraries.sessioninfo
local uipallet = vain.Libraries.uipallet
local tween = vain.Libraries.tween
local color = vain.Libraries.color
local whitelist = vain.Libraries.whitelist
local prediction = vain.Libraries.prediction
local getfontsize = vain.Libraries.getfontsize
local getcustomasset = vain.Libraries.getcustomasset

-- Kit modules are bedwars-only, so the category is created here rather than in the
-- shared GUI file - creating it there put an empty Kit tab in front of every other
-- game. The icon is borrowed from the combat one and is wrapped because asset paths
-- are per-GUI: a GUI without that file should cost us the icon, not the category.
if not vain.Categories.Kit then
	local icon = select(2, pcall(getcustomasset, 'vain/assets/new/combaticon.png'))
	vain:CreateCategory({
		Name = 'Kit',
		Icon = type(icon) == 'string' and icon or nil,
		Size = UDim2.fromOffset(13, 14)
	})
end

local store = {
	attackReach = 0,
	attackReachUpdate = tick(),
	damageBlockFail = tick(),
	hand = {},
	inventory = {
		inventory = {
			items = {},
			armor = {}
		},
		hotbar = {}
	},
	inventories = {},
	matchState = 0,
	queueType = 'bedwars_test',
	tools = {}
}
local Reach = {}
local HitBoxes = {}
local InfiniteFly = {}
local TrapDisabler
local AntiFallPart
local bedwars, remotes, sides, oldinvrender, oldSwing = {}, {}, {}

local function addBlur(parent)
	local blur = Instance.new('ImageLabel')
	blur.Name = 'Blur'
	blur.Size = UDim2.new(1, 89, 1, 52)
	blur.Position = UDim2.fromOffset(-48, -31)
	blur.BackgroundTransparency = 1
	blur.Image = getcustomasset('vain/assets/new/blur.png')
	blur.ScaleType = Enum.ScaleType.Slice
	blur.SliceCenter = Rect.new(52, 31, 261, 502)
	blur.Parent = parent
	return blur
end

local function collection(tags, module, customadd, customremove)
	tags = typeof(tags) ~= 'table' and {tags} or tags
	local objs, connections = {}, {}

	for _, tag in tags do
		table.insert(connections, collectionService:GetInstanceAddedSignal(tag):Connect(function(v)
			if customadd then
				customadd(objs, v, tag)
				return
			end
			table.insert(objs, v)
		end))
		table.insert(connections, collectionService:GetInstanceRemovedSignal(tag):Connect(function(v)
			if customremove then
				customremove(objs, v, tag)
				return
			end
			v = table.find(objs, v)
			if v then
				table.remove(objs, v)
			end
		end))

		for _, v in collectionService:GetTagged(tag) do
			if customadd then
				customadd(objs, v, tag)
				continue
			end
			table.insert(objs, v)
		end
	end

	local cleanFunc = function(self)
		for _, v in connections do
			v:Disconnect()
		end
		table.clear(connections)
		table.clear(objs)
		table.clear(self)
	end
	if module then
		module:Clean(cleanFunc)
	end
	return objs, cleanFunc
end

local function getBestArmor(slot)
	local closest, mag = nil, 0

	for _, item in store.inventory.inventory.items do
		local meta = item and bedwars.ItemMeta[item.itemType] or {}

		if meta.armor and meta.armor.slot == slot then
			local newmag = (meta.armor.damageReductionMultiplier or 0)

			if newmag > mag then
				closest, mag = item, newmag
			end
		end
	end

	return closest
end

local function getBow()
	local bestBow, bestBowSlot, bestBowDamage = nil, nil, 0
	for slot, item in store.inventory.inventory.items do
		local bowMeta = bedwars.ItemMeta[item.itemType].projectileSource
		if bowMeta and table.find(bowMeta.ammoItemTypes, 'arrow') then
			local bowDamage = bedwars.ProjectileMeta[bowMeta.projectileType('arrow')].combat.damage or 0
			if bowDamage > bestBowDamage then
				bestBow, bestBowSlot, bestBowDamage = item, slot, bowDamage
			end
		end
	end
	return bestBow, bestBowSlot
end

local function getItem(itemName, inv)
	for slot, item in (inv or store.inventory.inventory.items) do
		if item.itemType == itemName then
			return item, slot
		end
	end
	return nil
end

local function getRoactRender(func)
	return debug.getupvalue(debug.getupvalue(debug.getupvalue(func, 3).render, 2).render, 1)
end

local function getSword()
	local bestSword, bestSwordSlot, bestSwordDamage = nil, nil, 0
	for slot, item in store.inventory.inventory.items do
		local swordMeta = bedwars.ItemMeta[item.itemType].sword
		if swordMeta then
			local swordDamage = swordMeta.damage or 0
			if swordDamage > bestSwordDamage then
				bestSword, bestSwordSlot, bestSwordDamage = item, slot, swordDamage
			end
		end
	end
	return bestSword, bestSwordSlot
end

local function getTool(breakType)
	local bestTool, bestToolSlot, bestToolDamage = nil, nil, 0
	for slot, item in store.inventory.inventory.items do
		local toolMeta = bedwars.ItemMeta[item.itemType].breakBlock
		if toolMeta then
			local toolDamage = toolMeta[breakType] or 0
			if toolDamage > bestToolDamage then
				bestTool, bestToolSlot, bestToolDamage = item, slot, toolDamage
			end
		end
	end
	return bestTool, bestToolSlot
end

local function getWool()
	for _, wool in (inv or store.inventory.inventory.items) do
		if wool.itemType:find('wool') then
			return wool and wool.itemType, wool and wool.amount
		end
	end
end

-- Finds the index of the upvalue holding `value` in `func`, instead of hardcoding one.
-- Upvalue positions shift whenever the game adds or removes a local in the enclosing
-- scope, which silently turns a hooking module into one that corrupts an unrelated
-- upvalue - e.g. writing over the game's Players reference instead of KnitClient.
-- Returns nil when it isn't there, so callers can skip rather than clobber.
local function findUpvalue(func, value)
	if type(func) ~= 'function' then return nil end
	for i = 1, 40 do
		local suc, up = pcall(debug.getupvalue, func, i)
		if not suc then break end
		if up == value then return i end
	end
	return nil
end

-- Same idea for constants.
local function findConstant(func, value)
	if type(func) ~= 'function' then return nil end
	local suc, constants = pcall(debug.getconstants, func)
	if not suc or not constants then return nil end
	for i, v in constants do
		if v == value then return i end
	end
	return nil
end

-- Swaps a constant by value rather than by position. Modules use this to neuter a
-- specific check inside a game function (e.g. renaming the key it looks up so the
-- lookup misses) and to put it back afterwards. Returns false when the value isn't
-- there, which is the signal that the game changed and the hook should be skipped
-- instead of writing over whatever happens to sit at a hardcoded index.
local function swapConstant(func, from, to)
	local ind = findConstant(func, from)
	if not ind then return false end
	local suc = pcall(debug.setconstant, func, ind, to)
	return suc
end

local function getStrength(plr)
	if not plr.Player then
		return 0
	end

	local strength = 0
	for _, v in (store.inventories[plr.Player] or {items = {}}).items do
		local itemmeta = bedwars.ItemMeta[v.itemType]
		if itemmeta and itemmeta.sword and itemmeta.sword.damage > strength then
			strength = itemmeta.sword.damage
		end
	end

	return strength
end

local function getPlacedBlock(pos)
	if not pos then
		return
	end
	local roundedPosition = bedwars.BlockController:getBlockPosition(pos)
	return bedwars.BlockController:getStore():getBlockAt(roundedPosition), roundedPosition
end

local function getBlocksInPoints(s, e)
	local blocks, list = bedwars.BlockController:getStore(), {}
	for x = s.X, e.X do
		for y = s.Y, e.Y do
			for z = s.Z, e.Z do
				local vec = Vector3.new(x, y, z)
				if blocks:getBlockAt(vec) then
					table.insert(list, vec * 3)
				end
			end
		end
	end
	return list
end

local function getNearGround(range)
	range = Vector3.new(3, 3, 3) * (range or 10)
	local localPosition, mag, closest = entitylib.character.RootPart.Position, 60
	local blocks = getBlocksInPoints(bedwars.BlockController:getBlockPosition(localPosition - range), bedwars.BlockController:getBlockPosition(localPosition + range))

	for _, v in blocks do
		if not getPlacedBlock(v + Vector3.new(0, 3, 0)) then
			local newmag = (localPosition - v).Magnitude
			if newmag < mag then
				mag, closest = newmag, v + Vector3.new(0, 3, 0)
			end
		end
	end

	table.clear(blocks)
	return closest
end

local function getShieldAttribute(char)
	local returned = 0
	for name, val in char:GetAttributes() do
		if name:find('Shield') and type(val) == 'number' and val > 0 then
			returned += val
		end
	end
	return returned
end

local function getSpeed()
	local multi, increase, modifiers = 0, true, bedwars.SprintController:getMovementStatusModifier():getModifiers()

	for v in modifiers do
		local val = v.constantSpeedMultiplier and v.constantSpeedMultiplier or 0
		if val and val > math.max(multi, 1) then
			increase = false
			multi = val - (0.06 * math.round(val))
		end
	end

	for v in modifiers do
		multi += math.max((v.moveSpeedMultiplier or 0) - 1, 0)
	end

	if multi > 0 and increase then
		multi += 0.16 + (0.02 * math.round(multi))
	end

	return 20 * (multi + 1)
end

local function getTableSize(tab)
	local ind = 0
	for _ in tab do
		ind += 1
	end
	return ind
end

local function hotbarSwitch(slot)
	if slot and store.inventory.hotbarSlot ~= slot then
		bedwars.Store:dispatch({
			type = 'InventorySelectHotbarSlot',
			slot = slot
		})
		vainEvents.InventoryChanged.Event:Wait()
		return true
	end
	return false
end

local function isFriend(plr, recolor)
	if vain.Categories.Friends.Options['Use friends'].Enabled then
		local friend = table.find(vain.Categories.Friends.ListEnabled, plr.Name) and true
		if recolor then
			friend = friend and vain.Categories.Friends.Options['Recolor visuals'].Enabled
		end
		return friend
	end
	return nil
end

local function isTarget(plr)
	return table.find(vain.Categories.Targets.ListEnabled, plr.Name) and true
end

local function notif(...) return
	vain:CreateNotification(...)
end

local function removeTags(str)
	str = str:gsub('<br%s*/>', '\n')
	return (str:gsub('<[^<>]->', ''))
end

local function roundPos(vec)
	return Vector3.new(math.round(vec.X / 3) * 3, math.round(vec.Y / 3) * 3, math.round(vec.Z / 3) * 3)
end

local function switchItem(tool, delayTime)
	delayTime = delayTime or 0.05
	local check = lplr.Character and lplr.Character:FindFirstChild('HandInvItem') or nil
	if check and check.Value ~= tool and tool.Parent ~= nil then
		task.spawn(function()
			bedwars.Client:Get(remotes.EquipItem):CallServerAsync({hand = tool})
		end)
		check.Value = tool
		if delayTime > 0 then
			task.wait(delayTime)
		end
		return true
	end
end

local function waitForChildOfType(obj, name, timeout, prop)
	local check, returned = tick() + timeout
	repeat
		returned = prop and obj[name] or obj:FindFirstChildOfClass(name)
		if returned and returned.Name ~= 'UpperTorso' or check < tick() then
			break
		end
		task.wait()
	until false
	return returned
end

local frictionTable, oldfrict = {}, {}
local frictionConnection
local frictionState

local function modifyVelocity(v)
	if v:IsA('BasePart') and v.Name ~= 'HumanoidRootPart' and not oldfrict[v] then
		oldfrict[v] = v.CustomPhysicalProperties or 'none'
		v.CustomPhysicalProperties = PhysicalProperties.new(0.0001, 0.2, 0.5, 1, 1)
	end
end

local function updateVelocity(force)
	local newState = getTableSize(frictionTable) > 0
	if frictionState ~= newState or force then
		if frictionConnection then
			frictionConnection:Disconnect()
		end
		if newState then
			if entitylib.isAlive then
				for _, v in entitylib.character.Character:GetDescendants() do
					modifyVelocity(v)
				end
				frictionConnection = entitylib.character.Character.DescendantAdded:Connect(modifyVelocity)
			end
		else
			for i, v in oldfrict do
				i.CustomPhysicalProperties = v ~= 'none' and v or nil
			end
			table.clear(oldfrict)
		end
	end
	frictionState = newState
end

local kitorder = {
	hannah = 5,
	spirit_assassin = 4,
	dasher = 3,
	jade = 2,
	regent = 1
}

-- Team ids whose bed has been destroyed this match, so the 'Final Kill' target mode can
-- tell who respawns from who is gone for good. Filled from the BedwarsBedBreak event
-- (see the event wiring below) and cleared when a match ends.
local brokenbeds = {}

-- Total damage reduction from everything the player is wearing. Mirrors getStrength,
-- but reads the armor list instead of held swords, so it answers "who dies fastest".
local function getArmor(plr)
	if not plr.Player then
		return 0
	end

	local armor = 0
	for _, v in (store.inventories[plr.Player] or {armor = {}}).armor do
		local itemmeta = bedwars.ItemMeta[v.itemType]
		if itemmeta and itemmeta.armor then
			armor += itemmeta.armor.damageReductionMultiplier or 0
		end
	end

	return armor
end

-- Screen-space distance from the cursor. Entities behind the camera get pushed to the
-- back rather than wrapping around to the front - WorldToViewportPoint still returns
-- coordinates for those, so without the visibility check someone directly behind you
-- could out-rank the player you are actually looking at.
local function getCursorDistance(ent)
	local position, visible = gameCamera:WorldToViewportPoint(ent.RootPart.Position)
	if not visible then
		return math.huge
	end

	local mouse = inputService.TouchEnabled and gameCamera.ViewportSize / 2 or inputService:GetMouseLocation()
	return (mouse - Vector2.new(position.X, position.Y)).Magnitude
end

-- Shown when hovering an individual Target Mode option. Keys match sortmethods plus
-- 'Distance', which is not in that table because it is the default magnitude ordering.
local sortmethodtips = {
	Distance = 'Whoever is physically closest to you',
	Damage = 'Whoever damaged you most recently',
	Angle = 'Whoever is nearest the direction you are already facing',
	Cursor = 'Whoever is nearest your crosshair on screen',
	Armor = 'Whoever is wearing the weakest armor',
	Health = 'Whoever has the lowest health',
	Threat = 'Whoever is holding the strongest sword',
	Kit = 'Whoever is playing the most dangerous kit',
	['Final Kill'] = 'Players whose bed is already broken'
}

local sortmethods = {
	Damage = function(a, b)
		return a.Entity.Character:GetAttribute('LastDamageTakenTime') < b.Entity.Character:GetAttribute('LastDamageTakenTime')
	end,
	Cursor = function(a, b)
		return getCursorDistance(a.Entity) < getCursorDistance(b.Entity)
	end,
	Armor = function(a, b)
		return getArmor(a.Entity) < getArmor(b.Entity)
	end,
	-- A player whose bed is gone dies for good, so they are worth committing to over
	-- someone who would just respawn. brokenbeds is filled from the BedwarsBedBreak
	-- event further down, keyed the same way the game keys a player's Team attribute.
	['Final Kill'] = function(a, b)
		local abroken = a.Entity.Player and brokenbeds[a.Entity.Player:GetAttribute('Team')]
		local bbroken = b.Entity.Player and brokenbeds[b.Entity.Player:GetAttribute('Team')]
		return (abroken and 1 or 0) > (bbroken and 1 or 0)
	end,
	Threat = function(a, b)
		return getStrength(a.Entity) > getStrength(b.Entity)
	end,
	Kit = function(a, b)
		return (a.Entity.Player and kitorder[a.Entity.Player:GetAttribute('PlayingAsKit')] or 0) > (b.Entity.Player and kitorder[b.Entity.Player:GetAttribute('PlayingAsKit')] or 0)
	end,
	Health = function(a, b)
		return a.Entity.Health < b.Entity.Health
	end,
	Angle = function(a, b)
		local selfrootpos = entitylib.character.RootPart.Position
		local localfacing = entitylib.character.RootPart.CFrame.LookVector * Vector3.new(1, 0, 1)
		local angle = math.acos(localfacing:Dot(((a.Entity.RootPart.Position - selfrootpos) * Vector3.new(1, 0, 1)).Unit))
		local angle2 = math.acos(localfacing:Dot(((b.Entity.RootPart.Position - selfrootpos) * Vector3.new(1, 0, 1)).Unit))
		return angle < angle2
	end
}

run(function()
	local oldstart = entitylib.start
	local function customEntity(ent)
		if ent:HasTag('inventory-entity') and not ent:HasTag('Monster') then
			return
		end

		entitylib.addEntity(ent, nil, ent:HasTag('Drone') and function(self)
			local droneplr = playersService:GetPlayerByUserId(self.Character:GetAttribute('PlayerUserId'))
			return not droneplr or lplr:GetAttribute('Team') ~= droneplr:GetAttribute('Team')
		end or function(self)
			return lplr:GetAttribute('Team') ~= self.Character:GetAttribute('Team')
		end)
	end

	entitylib.start = function()
		oldstart()
		if entitylib.Running then
			for _, ent in collectionService:GetTagged('entity') do
				customEntity(ent)
			end
			table.insert(entitylib.Connections, collectionService:GetInstanceAddedSignal('entity'):Connect(customEntity))
			table.insert(entitylib.Connections, collectionService:GetInstanceRemovedSignal('entity'):Connect(function(ent)
				entitylib.removeEntity(ent)
			end))
		end
	end

	entitylib.addPlayer = function(plr)
		if plr.Character then
			entitylib.refreshEntity(plr.Character, plr)
		end
		entitylib.PlayerConnections[plr] = {
			plr.CharacterAdded:Connect(function(char)
				entitylib.refreshEntity(char, plr)
			end),
			plr.CharacterRemoving:Connect(function(char)
				entitylib.removeEntity(char, plr == lplr)
			end),
			plr:GetAttributeChangedSignal('Team'):Connect(function()
				for _, v in entitylib.List do
					if v.Targetable ~= entitylib.targetCheck(v) then
						entitylib.refreshEntity(v.Character, v.Player)
					end
				end

				if plr == lplr then
					entitylib.start()
				else
					entitylib.refreshEntity(plr.Character, plr)
				end
			end)
		}
	end

	entitylib.addEntity = function(char, plr, teamfunc)
		if not char then return end
		entitylib.EntityThreads[char] = task.spawn(function()
			local hum, humrootpart, head
			if plr then
				hum = waitForChildOfType(char, 'Humanoid', 10)
				humrootpart = hum and waitForChildOfType(hum, 'RootPart', workspace.StreamingEnabled and 9e9 or 10, true)
				head = char:WaitForChild('Head', 10) or humrootpart
			else
				hum = {HipHeight = 0.5}
				humrootpart = waitForChildOfType(char, 'PrimaryPart', 10, true)
				head = humrootpart
			end
			local updateobjects = plr and plr ~= lplr and {
				char:WaitForChild('ArmorInvItem_0', 5),
				char:WaitForChild('ArmorInvItem_1', 5),
				char:WaitForChild('ArmorInvItem_2', 5),
				char:WaitForChild('HandInvItem', 5)
			} or {}

			if hum and humrootpart then
				local entity = {
					Connections = {},
					Character = char,
					Health = (char:GetAttribute('Health') or 100) + getShieldAttribute(char),
					Head = head,
					Humanoid = hum,
					HumanoidRootPart = humrootpart,
					HipHeight = hum.HipHeight + (humrootpart.Size.Y / 2) + (hum.RigType == Enum.HumanoidRigType.R6 and 2 or 0),
					Jumps = 0,
					JumpTick = tick(),
					Jumping = false,
					LandTick = tick(),
					MaxHealth = char:GetAttribute('MaxHealth') or 100,
					NPC = plr == nil,
					Player = plr,
					RootPart = humrootpart,
					TeamCheck = teamfunc
				}

				if plr == lplr then
					entity.AirTime = tick()
					entitylib.character = entity
					entitylib.isAlive = true
					entitylib.Events.LocalAdded:Fire(entity)
					table.insert(entitylib.Connections, char.AttributeChanged:Connect(function(attr)
						vainEvents.AttributeChanged:Fire(attr)
					end))
				else
					entity.Targetable = entitylib.targetCheck(entity)

					for _, v in entitylib.getUpdateConnections(entity) do
						table.insert(entity.Connections, v:Connect(function()
							entity.Health = (char:GetAttribute('Health') or 100) + getShieldAttribute(char)
							entity.MaxHealth = char:GetAttribute('MaxHealth') or 100
							entitylib.Events.EntityUpdated:Fire(entity)
						end))
					end

					for _, v in updateobjects do
						table.insert(entity.Connections, v:GetPropertyChangedSignal('Value'):Connect(function()
							task.delay(0.1, function()
								if bedwars.getInventory then
									store.inventories[plr] = bedwars.getInventory(plr)
									entitylib.Events.EntityUpdated:Fire(entity)
								end
							end)
						end))
					end

					if plr then
						local anim = char:FindFirstChild('Animate')
						if anim then
							pcall(function()
								anim = anim.jump:FindFirstChildWhichIsA('Animation').AnimationId
								table.insert(entity.Connections, hum.Animator.AnimationPlayed:Connect(function(playedanim)
									if playedanim.Animation.AnimationId == anim then
										entity.JumpTick = tick()
										entity.Jumps += 1
										entity.LandTick = tick() + 1
										entity.Jumping = entity.Jumps > 1
									end
								end))
							end)
						end

						task.delay(0.1, function()
							if bedwars.getInventory then
								store.inventories[plr] = bedwars.getInventory(plr)
							end
						end)
					end
					table.insert(entitylib.List, entity)
					entitylib.Events.EntityAdded:Fire(entity)
				end

				table.insert(entity.Connections, char.ChildRemoved:Connect(function(part)
					if part == humrootpart or part == hum or part == head then
						if part == humrootpart and hum.RootPart then
							humrootpart = hum.RootPart
							entity.RootPart = hum.RootPart
							entity.HumanoidRootPart = hum.RootPart
							return
						end
						entitylib.removeEntity(char, plr == lplr)
					end
				end))
			end
			entitylib.EntityThreads[char] = nil
		end)
	end

	entitylib.getUpdateConnections = function(ent)
		local char = ent.Character
		local tab = {
			char:GetAttributeChangedSignal('Health'),
			char:GetAttributeChangedSignal('MaxHealth'),
			{
				Connect = function()
					ent.Friend = ent.Player and isFriend(ent.Player) or nil
					ent.Target = ent.Player and isTarget(ent.Player) or nil
					return {Disconnect = function() end}
				end
			}
		}

		if ent.Player then
			table.insert(tab, ent.Player:GetAttributeChangedSignal('PlayingAsKit'))
		end

		for name, val in char:GetAttributes() do
			if name:find('Shield') and type(val) == 'number' then
				table.insert(tab, char:GetAttributeChangedSignal(name))
			end
		end

		return tab
	end

	--[[
		Bedwars differs from everywhere else: rank only shields somebody you are against.

		A player who outranks you and is on your own team is treated as any other
		teammate, so nothing about being ranked gets in the way of a game you are playing
		together. On any other team they are untouchable - no aim, no aura, no esp, and
		none of their base either, see isBlockBreakable below.

		Every other game applies the plain rule from the universal base, where team makes
		no difference at all.
	]]
	--[[
		Whether a player may be acted on, asked safely.

		whitelist:get is defined inside one of the universal base's deferred blocks, so for
		the first moments of a round the table exists but the method does not - and calling
		it then threw straight through the block breaker, which is where the wall of
		"attempt to call a nil value" came from.

		Unanswerable is treated as attackable. Refusing to break anything until the list has
		loaded would be a worse failure than briefly not protecting somebody, and the answer
		corrects itself within the same second.
	]]
	local function attackable(plr)
		if not (whitelist and type(whitelist.get) == 'function') then return true end
		local ok, _, allowed = pcall(whitelist.get, whitelist, plr)
		if not ok then return true end
		return allowed
	end

	local function sameTeam(plr)
		local mine = lplr:GetAttribute('Team')
		return mine ~= nil and mine == plr:GetAttribute('Team')
	end
	bedwars.sameTeam = sameTeam
	-- Published alongside sameTeam because the block protection below lives in a different
	-- run block, and a local from this one is simply a nil global over there. That is what
	-- was throwing straight through the block breaker: not the whitelist being unready, but
	-- the functions not being reachable from where they were called at all.
	bedwars.attackable = attackable

	entitylib.protectionCheck = function(ent)
		if not ent.Player or sameTeam(ent.Player) then return true end
		return attackable(ent.Player)
	end

	entitylib.targetCheck = function(ent)
		if ent.NPC then return true end
		if isFriend(ent.Player) then return false end
		if ent.TeamCheck then
			return ent:TeamCheck()
		end
		return lplr:GetAttribute('Team') ~= ent.Player:GetAttribute('Team')
	end
	vain:Clean(entitylib.Events.LocalAdded:Connect(updateVelocity))
end)
entitylib.start()

run(function()
	local KnitInit, Knit
	repeat
		KnitInit, Knit = pcall(function()
			return debug.getupvalue(require(lplr.PlayerScripts.TS.knit).setup, 9)
		end)
		if KnitInit then break end
		task.wait()
	until KnitInit

	if not debug.getupvalue(Knit.Start, 1) then
		repeat task.wait() until debug.getupvalue(Knit.Start, 1)
	end

	local Flamework = require(replicatedStorage['rbxts_include']['node_modules']['@flamework'].core.out).Flamework
	local InventoryUtil = require(replicatedStorage.TS.inventory['inventory-util']).InventoryUtil
	local Client = require(replicatedStorage.TS.remotes).default.Client
	local OldGet, OldBreak = Client.Get

	-- Which team upgrades are on offer, at what cost, for the queue you are actually in -
	-- mine wars, survival and hyper gen each run a different set.
	--
	-- Asked of the module's own export rather than read out of a fixed upvalue slot. Slot
	-- 6 is getQueueMeta on the current client - a function, not the meta table - so
	-- iterating it threw, and that took out every AutoBuy setting declared after the
	-- upgrade toggles and left Buy Upgrades with nothing at all to buy. The upvalue route
	-- is kept as a fallback for older clients, but it looks for a table that is shaped
	-- like the meta instead of trusting an index that has already moved once.
	local upgrademeta = require(replicatedStorage.TS.games.bedwars['team-upgrade']['team-upgrade-meta'])

	local function isUpgradeMeta(tab)
		if type(tab) ~= 'table' then return false end
		local _, entry = next(tab)
		return type(entry) == 'table' and type(entry.tiers) == 'table'
	end

	local function teamUpgradeMeta()
		local ok, queuemeta = pcall(upgrademeta.getTeamUpgradeMetaForQueue)
		if ok and isUpgradeMeta(queuemeta) then return queuemeta end

		for i = 1, 16 do
			local found, value = pcall(debug.getupvalue, upgrademeta.getTeamUpgradeMetaForQueue, i)
			if found and isUpgradeMeta(value) then return value end
		end

		return {}
	end

	bedwars = setmetatable({
		AbilityController = Flamework.resolveDependency('@easy-games/game-core:client/controllers/ability/ability-controller@AbilityController'),
		-- Holds registeredActions, keyed by the id an action was bound under. That is how
		-- a module can call the same function a keypress would, rather than reimplementing
		-- what the game does behind it.
		ActionBinder = Flamework.resolveDependency('@easy-games/game-core:client/controllers/keybind/action-binder-controller@ActionBinderController'),
		AbilityId = require(replicatedStorage.TS.ability['ability-id']).AbilityId,
		AudioCategory = require(replicatedStorage['rbxts_include']['node_modules']['@easy-games']['game-core'].out).AudioCategory,
		AudioManager = require(replicatedStorage['rbxts_include']['node_modules']['@easy-games']['game-core'].out).AudioManager,
		AnimationType = require(replicatedStorage.TS.animation['animation-type']).AnimationType,
		AnimationUtil = require(replicatedStorage['rbxts_include']['node_modules']['@easy-games']['game-core'].out['shared'].util['animation-util']).AnimationUtil,
		AppController = require(replicatedStorage['rbxts_include']['node_modules']['@easy-games']['game-core'].out.client.controllers['app-controller']).AppController,
		BedBreakEffectMeta = require(replicatedStorage.TS.locker['bed-break-effect']['bed-break-effect-meta']).BedBreakEffectMeta,
		BedwarsKitMeta = require(replicatedStorage.TS.games.bedwars.kit['bedwars-kit-meta']).BedwarsKitMeta,
		BeeNetController = Knit.Controllers.BeeNetController,
		BlockBreaker = Knit.Controllers.BlockBreakController.blockBreaker,
		BlockController = require(replicatedStorage['rbxts_include']['node_modules']['@easy-games']['block-engine'].out).BlockEngine,
		BlockEngine = require(lplr.PlayerScripts.TS.lib['block-engine']['client-block-engine']).ClientBlockEngine,
		BlockPlacer = require(replicatedStorage['rbxts_include']['node_modules']['@easy-games']['block-engine'].out.client.placement['block-placer']).BlockPlacer,
		BowConstantsTable = debug.getupvalue(Knit.Controllers.ProjectileController.enableBeam, 8),
		ClickHold = require(replicatedStorage['rbxts_include']['node_modules']['@easy-games']['game-core'].out.client.ui.lib.util['click-hold']).ClickHold,
		Client = Client,
		ClientConstructor = require(replicatedStorage['rbxts_include']['node_modules']['@rbxts'].net.out.client),
		ClientDamageBlock = require(replicatedStorage['rbxts_include']['node_modules']['@easy-games']['block-engine'].out.shared.remotes).BlockEngineRemotes.Client,
		CombatConstant = require(replicatedStorage.TS.combat['combat-constant']).CombatConstant,
		DamageIndicator = Knit.Controllers.DamageIndicatorController.spawnDamageIndicator,
		EmoteType = require(replicatedStorage.TS.locker.emote['emote-type']).EmoteType,
		GameAnimationUtil = require(replicatedStorage.TS.animation['animation-util']).GameAnimationUtil,
		getIcon = function(item, showinv)
			local itemmeta = bedwars.ItemMeta[item.itemType]
			return itemmeta and showinv and itemmeta.image or ''
		end,
		getInventory = function(plr)
			local suc, res = pcall(function()
				return InventoryUtil.getInventory(plr)
			end)
			return suc and res or {
				items = {},
				armor = {}
			}
		end,
		HudAliveCount = require(lplr.PlayerScripts.TS.controllers.global['top-bar'].ui.game['hud-alive-player-counts']).HudAlivePlayerCounts,
		-- item-meta now exports the table directly as `items`; the getupvalue path is kept
		-- as a fallback since it is the only route on older client builds. Reading the
		-- export first means a future change to getItemMeta's locals can't silently hand
		-- back the wrong upvalue - ItemMeta backs 23 usages across the modules.
		ItemMeta = (function()
			local itemmeta = require(replicatedStorage.TS.item['item-meta'])
			return itemmeta.items or debug.getupvalue(itemmeta.getItemMeta, 1)
		end)(),
		KillEffectMeta = require(replicatedStorage.TS.locker['kill-effect']['kill-effect-meta']).KillEffectMeta,
		KillFeedController = Flamework.resolveDependency('client/controllers/game/kill-feed/kill-feed-controller@KillFeedController'),
		Knit = Knit,
		KnockbackUtil = require(replicatedStorage.TS.damage['knockback-util']).KnockbackUtil,
		MageKitUtil = require(replicatedStorage.TS.games.bedwars.kit.kits.mage['mage-kit-util']).MageKitUtil,
		NametagController = Knit.Controllers.NametagController,
		PartyController = Flamework.resolveDependency('@easy-games/lobby:client/controllers/party-controller@PartyController'),
		ProjectileMeta = require(replicatedStorage.TS.projectile['projectile-meta']).ProjectileMeta,
		QueryUtil = require(replicatedStorage['rbxts_include']['node_modules']['@easy-games']['game-core'].out).GameQueryUtil,
		QueueCard = require(lplr.PlayerScripts.TS.controllers.global.queue.ui['queue-card']).QueueCard,
		QueueMeta = require(replicatedStorage.TS.game['queue-meta']).QueueMeta,
		RankController = Knit.Controllers.RankController,
		RankMeta = require(replicatedStorage.TS.rank['rank-meta']).RankMeta,
		Roact = require(replicatedStorage['rbxts_include']['node_modules']['@rbxts']['roact'].src),
		RuntimeLib = require(replicatedStorage['rbxts_include'].RuntimeLib),
		SoundList = require(replicatedStorage.TS.sound['game-sound']).GameSound,
		StatusEffectMeta = require(replicatedStorage.TS['status-effect']['status-effect-meta']).StatusEffectMeta,
		StatusEffectType = require(replicatedStorage.TS['status-effect']['status-effect-type']).StatusEffectType,
		SoundManager = require(replicatedStorage['rbxts_include']['node_modules']['@easy-games']['game-core'].out).SoundManager,
		Store = require(lplr.PlayerScripts.TS.ui.store).ClientStore,
		TeamUpgradeMeta = teamUpgradeMeta(),
		UILayers = require(replicatedStorage['rbxts_include']['node_modules']['@easy-games']['game-core'].out).UILayers,
		VisualizerUtils = require(lplr.PlayerScripts.TS.lib.visualizer['visualizer-utils']).VisualizerUtils,
		WeldTable = require(replicatedStorage.TS.util['weld-util']).WeldUtil,
		WinEffectMeta = require(replicatedStorage.TS.locker['win-effect']['win-effect-meta']).WinEffectMeta,
		ZapNetworking = require(lplr.PlayerScripts.TS.lib.network)
	}, {
		__index = function(self, ind)
			rawset(self, ind, Knit.Controllers[ind])
			return rawget(self, ind)
		end
	})

	-- The game dropped SoundManager for AudioManager:playAudio(sound, config), so
	-- bedwars.SoundManager resolved to nil and every module that plays a sound threw on
	-- it. Shimming the old method keeps all of those call sites working instead of
	-- spreading the rename across each one, and it stays quiet rather than throwing if
	-- the audio side moves again.
	if not rawget(bedwars, 'SoundManager') then
		rawset(bedwars, 'SoundManager', {
			playSound = function(_, sound, config)
				local manager = bedwars.AudioManager
				if not manager then return end

				local settings = {category = bedwars.AudioCategory and bedwars.AudioCategory.GAMEPLAY}
				for index, value in (config or {}) do
					settings[index] = value
				end
				return manager:playAudio(sound, settings)
			end
		})
	end

	-- The settings list is built once at load, but which upgrades exist and what they cost
	-- follows the queue, so the buying side asks again each time rather than trusting what
	-- was true when the menu was drawn.
	rawset(bedwars, 'getTeamUpgradeMeta', teamUpgradeMeta)

	local remoteNames = {
		AfkStatus = debug.getproto(Knit.Controllers.AfkController.KnitStart, 1),
		AttackEntity = Knit.Controllers.SwordController.sendServerRequest,
		BeePickup = Knit.Controllers.BeeNetController.trigger,
		CannonLaunch = Knit.Controllers.CannonHandController.launchSelf,
		ConsumeBattery = debug.getproto(Knit.Controllers.BatteryController.onKitLocalActivated, 1),
		ConsumeItem = debug.getproto(Knit.Controllers.ConsumeController.onEnable, 1),
		ConsumeSoul = Knit.Controllers.GrimReaperController.consumeSoul,
		ConsumeTreeOrb = debug.getproto(Knit.Controllers.EldertreeController.createTreeOrbInteraction, 1),
		DepositPinata = debug.getproto(debug.getproto(Knit.Controllers.PiggyBankController.KnitStart, 2), 5),
		DragonBreath = debug.getproto(Knit.Controllers.VoidDragonController.onKitLocalActivated, 5),
		DragonEndFly = debug.getproto(Knit.Controllers.VoidDragonController.flapWings, 1),
		DragonFly = Knit.Controllers.VoidDragonController.flapWings,
		DropItem = Knit.Controllers.ItemDropController.dropItemInHand,
		EquipItem = debug.getproto(require(replicatedStorage.TS.entity.entities['inventory-entity']).InventoryEntity.equipItem, 4),
		FireProjectile = debug.getupvalue(Knit.Controllers.ProjectileController.launchProjectileWithValues, 2),
		GroundHit = Knit.Controllers.FallDamageController.KnitStart,
		GuitarHeal = Knit.Controllers.GuitarController.performHeal,
		HannahKill = debug.getproto(Knit.Controllers.HannahController.registerExecuteInteractions, 1),
		HarvestCrop = debug.getproto(debug.getproto(Knit.Controllers.CropController.KnitStart, 4), 1),
		KaliyahPunch = debug.getproto(Knit.Controllers.DragonSlayerController.onKitLocalActivated, 1),
		MageSelect = debug.getproto(Knit.Controllers.MageController.registerTomeInteraction, 1),
		MinerDig = debug.getproto(Knit.Controllers.MinerController.setupMinerPrompts, 1),
		PickupItem = Knit.Controllers.ItemDropController.checkForPickup,
		PickupMetal = debug.getproto(Knit.Controllers.HiddenMetalController.onKitLocalActivated, 4),
		ReportPlayer = require(lplr.PlayerScripts.TS.controllers.global.report['report-controller']).default.reportPlayer,
		ResetCharacter = debug.getproto(Knit.Controllers.ResetController.createBindable, 1),
		SpawnRaven = debug.getproto(Knit.Controllers.RavenController.KnitStart, 1),
		SummonerClawAttack = Knit.Controllers.SummonerClawHandController.attack,
		WarlockTarget = debug.getproto(Knit.Controllers.WarlockStaffController.KnitStart, 2)
	}

	local function dumpRemote(tab)
		local ind
		for i, v in tab do
			if v == 'Client' then
				ind = i
				break
			end
		end
		return ind and tab[ind + 1] or ''
	end

	for i, v in remoteNames do
		local remote = dumpRemote(debug.getconstants(v))
		if remote == '' then
			notif('Vain', 'Failed to grab remote ('..i..')', 10, 'alert')
		end
		remotes[i] = remote
	end

	-- The names above are scraped out of the game's bytecode because they are not what
	-- they are called in source. Plenty of remotes are registered under their plain name
	-- though - BedwarsPurchaseItem and UseAbility among them - and modules referring to
	-- those got nil, because only the scraped set was ever populated. Falling back to the
	-- key means an unlisted remote resolves to its own name, which is right whenever the
	-- game did not rename it and no worse than nil when it did.
	setmetatable(remotes, {
		__index = function(_, key)
			return key
		end
	})

	OldBreak = bedwars.BlockController.isBlockBreakable

	Client.Get = function(self, remoteName)
		-- Get yields while it waits on the remote, and a yield hands the thread back to
		-- the scheduler, which resumes it carrying the game's identity rather than the
		-- executor's. Anything the caller does afterwards that needs the executor's
		-- identity then fails - a module calling this while it is being defined would
		-- lose the ability to parent an Instance, so the CreateModule on the next line
		-- died with "lacking capability Plugin". Restoring it here fixes every caller
		-- rather than each one working around it.
		local identity = getthreadidentity and getthreadidentity() or nil
		local call = OldGet(self, remoteName)
		if identity and setthreadidentity then
			pcall(setthreadidentity, identity)
		end

		if remoteName == remotes.AttackEntity then
			return {
				instance = call.instance,
				SendToServer = function(_, attackTable, ...)
					local suc, plr = pcall(function()
						return playersService:GetPlayerFromCharacter(attackTable.entityInstance)
					end)

					local selfpos = attackTable.validate.selfPosition.value
					local targetpos = attackTable.validate.targetPosition.value
					store.attackReach = ((selfpos - targetpos).Magnitude * 100) // 1 / 100
					store.attackReachUpdate = tick() + 1

					if Reach.Enabled or HitBoxes.Enabled then
						attackTable.validate.raycast = attackTable.validate.raycast or {}
						attackTable.validate.selfPosition.value += CFrame.lookAt(selfpos, targetpos).LookVector * math.max((selfpos - targetpos).Magnitude - 14.399, 0)
					end

					if suc and plr then
						if bedwars.attackable and not bedwars.attackable(plr) then return end
					end

					return call:SendToServer(attackTable, ...)
				end
			}
		elseif remoteName == 'StepOnSnapTrap' and TrapDisabler.Enabled then
			return {SendToServer = function() end}
		end

		return call
	end

	--[[
		Whether a team is one you must leave alone: somebody on it outranks you, and it is
		not your own.

		Answered by walking the players rather than by team id alone, since a team is only
		worth shielding while a protected player is actually on it.
	]]
	local function protectedTeam(teamId)
		if teamId == nil then return false end
		if lplr:GetAttribute('Team') == teamId then return false end

		for _, other in playersService:GetPlayers() do
			if other:GetAttribute('Team') == teamId and bedwars.attackable and not bedwars.attackable(other) then
				return true
			end
		end
		return false
	end
	bedwars.protectedTeam = protectedTeam

	--[[
		Their base is part of them.

		Protecting the player and leaving their bed open would miss the point entirely -
		the bed is the thing worth attacking. Two ways a block can belong to a shielded
		team: a bed carries a NoBreak attribute naming the team it belongs to, and any
		block somebody placed carries the id of whoever placed it, which is what covers
		the defence stacked around it.
	]]
	bedwars.BlockController.isBlockBreakable = function(self, breakTable, breaker)
		local obj = bedwars.BlockController:getStore():getBlockAt(breakTable.blockPosition)

		if obj then
			if obj.Name == 'bed' then
				for _, other in playersService:GetPlayers() do
					local teamId = other:GetAttribute('Team')
					if teamId and obj:GetAttribute('Team'..teamId..'NoBreak') and protectedTeam(teamId) then
						return false
					end
				end
			end

			local placer = obj:GetAttribute('PlacedByUserId')
			if placer and placer ~= 0 then
				local owner = playersService:GetPlayerByUserId(placer)
				if owner and bedwars.sameTeam and bedwars.attackable
					and not bedwars.sameTeam(owner) and not bedwars.attackable(owner) then
					return false
				end
			end
		end

		return OldBreak(self, breakTable, breaker)
	end

	local cache, blockhealthbar = {}, {blockHealth = -1, breakingBlockPosition = Vector3.zero}
	store.blockPlacer = bedwars.BlockPlacer.new(bedwars.BlockEngine, 'wool_white')

	local function getBlockHealth(block, blockpos)
		local blockdata = bedwars.BlockController:getStore():getBlockData(blockpos)
		return (blockdata and (blockdata:GetAttribute('1') or blockdata:GetAttribute('Health')) or block:GetAttribute('Health'))
	end

	local function getBlockHits(block, blockpos)
		if not block then return 0 end
		local breaktype = bedwars.ItemMeta[block.Name].block.breakType
		local tool = store.tools[breaktype]
		tool = tool and bedwars.ItemMeta[tool.itemType].breakBlock[breaktype] or 2
		return getBlockHealth(block, bedwars.BlockController:getBlockPosition(blockpos)) / tool
	end

	--[[
		Pathfinding using a luau version of dijkstra's algorithm
		Source: https://stackoverflow.com/questions/39355587/speeding-up-dijkstras-algorithm-to-solve-a-3d-maze
	]]
	-- The queue was being read with next() and shifted off the front, which is first in
	-- first out - it never took the cheapest block, so this was breadth first search
	-- wearing Dijkstra's name. Blocks are kept in cost order instead, so the one coming
	-- off the front really is the cheapest and marking it visited is safe.
	--
	-- A route costs one per block. It used to cost the hits needed to break each one,
	-- which optimises for damage rather than digging: four soft blocks beat one tough
	-- one, so routes wandered off diagonally through whatever was cheapest instead of
	-- going in. Toughness is kept only to separate routes of the same length, weighted
	-- and capped so that however many blocks a route crosses it can never add up to a
	-- whole extra one.
	local HIT_WEIGHT = 0.0001
	local HIT_CAP = 100
	-- Changing direction costs a touch more than carrying straight on. Routes of the
	-- same length tie constantly and the winner was whichever got queued first, so a dig
	-- would step up a block, run along, and step back down for no reason at all. Small
	-- enough that a route can never turn into a longer one to avoid a corner.
	local TURN_COST = 0.01

	-- How many blocks longer than the shortest way in a target mode may still choose.
	-- Zero, so the dig is always as short as it can be and the mode decides between the
	-- ways in that are equally short - a way in that is even one block worse is one whose
	-- route has to bend to get there, which is what makes a dig step up and over for no
	-- visible reason. Compared on whole blocks, since the weights below put a fraction on
	-- top of every route and no two are ever exactly equal.
	local ENTRY_TOLERANCE = 0

	local function enqueue(queue, dist, node)
		local low, high = 1, #queue + 1
		while low < high do
			local mid = (low + high) // 2
			if queue[mid][1] > dist then
				high = mid
			else
				low = mid + 1
			end
		end
		table.insert(queue, low, {dist, node})
	end

	-- Air only counts as a way in when it leads back out of the build. Air walled in on
	-- every side is a pocket: breaking into one opens nothing, because the layers around
	-- it are all still standing, so it just looks like blocks going missing out of the
	-- middle of a wall.
	--
	-- Outside is the structure's own extent rather than a number of cells. The flood
	-- below has already touched every block hanging off the bed, so air that gets past
	-- the edge of that has left the build by definition. Counting cells could never say
	-- that: a pocket sitting against the tunnel being dug joins air that does reach out,
	-- so past a few cells the count says "escaped" about a pocket and the test quietly
	-- stops meaning anything.
	--
	-- The cap is only there so a hopeless case cannot stall the break loop, and it fails
	-- open - refusing every opening would leave the nuker doing nothing at all.
	local POCKET_LIMIT = 4096

	local function reachesOutside(start, memo, low, high)
		local cached = memo[start]
		if cached ~= nil then return cached end

		local seen, frontier, count, escaped = {[start] = true}, {start}, 1, false

		while #frontier > 0 and not escaped do
			local nextfrontier = {}
			for _, pos in frontier do
				if pos.X < low.X or pos.Y < low.Y or pos.Z < low.Z
					or pos.X > high.X or pos.Y > high.Y or pos.Z > high.Z then
					escaped = true
					break
				end

				for _, side in sides do
					local at = pos + side
					if seen[at] or getPlacedBlock(at) then continue end
					-- Running into air already known to get out settles this body too,
					-- rather than walking the whole of the outside again for every face
					-- of every opening along it.
					if memo[at] then
						escaped = true
						break
					end
					seen[at] = true

					count += 1
					if count >= POCKET_LIMIT then
						escaped = true
						break
					end
					table.insert(nextfrontier, at)
				end
				if escaped then break end
			end
			frontier = nextfrontier
		end

		-- One verdict for the whole body of air, since every cell reached is part of it.
		for pos in seen do
			memo[pos] = escaped
		end
		return escaped
	end

	-- Which opening you can actually reach depends on where you stand, so it is chosen
	-- per call rather than baked into the cache. Picking purely on cost was wrong twice
	-- over: the cheapest opening could sit on the far side of a build, out of range, and
	-- the walls of a box are usually the same thickness anyway - so with every opening
	-- tied the winner came down to whichever the hash table happened to yield first, and
	-- it would just as soon mine the far wall as the one you are standing at.
	local NEAR_COST_TOLERANCE = 2
	local NEAR_COST_MARGIN = 2

	-- score lets the caller decide which opening to take - it is the block that actually
	-- gets broken, so this is what a target mode has to steer. Without one, the near side
	-- wins unless it would cost substantially more to get through, which is the
	-- difference between reaching around a thin wall and mining through a thick one.
	local function pickEntry(exposed, maxRange, score, prefer, maxAngle)
		local origin = entitylib.isAlive and entitylib.character.RootPart.Position
		-- The setting is the width of the cone, so half of it is the most a block may sit
		-- off the way you are looking. A full turn takes in everything and is not worth
		-- resolving the camera for.
		local halfAngle = maxAngle and (maxAngle / 2)
		local camera = halfAngle and halfAngle < 180 and workspace.CurrentCamera or nil

		-- Both limits on where a dig may start: how far you can reach, and how far off
		-- the way you are looking it is allowed to be.
		local function allowed(node, reach)
			if maxRange and origin and reach > maxRange then return false end
			if camera then
				local dir = node - camera.CFrame.Position
				if dir.Magnitude > 0 then
					local facing = camera.CFrame.LookVector:Dot(dir.Unit)
					if math.deg(math.acos(math.clamp(facing, -1, 1))) > halfAngle then return false end
				end
			end
			return true
		end

		-- Carry on down the hole already started instead of shaving another block off the
		-- outer face. prefer is the whole remaining route, nearest end first, and the
		-- first block of it still standing wins outright. Only naming the next block was
		-- not enough: while that one is being broken the one after it is still buried, so
		-- there was nothing to prefer and the scoring below picked whatever sat closest on
		-- the outer face - which is never the block at the back of the hole.
		--
		-- None of that applies until the route's first block has actually come down. While
		-- it is still standing nothing has been committed to yet, so the mode gets to pick
		-- again every pass and walking round a build moves the dig to whatever is nearest
		-- from where you now are. Past that point the route has to be seen through, or the
		-- tunnel would keep restarting at the surface and never reach the bed.
		if prefer and prefer[1] and not exposed[prefer[1]] then
			for _, node in prefer do
				if exposed[node] and allowed(node, origin and (node - origin).Magnitude or 0) then
					return node, exposed[node], -math.huge
				end
			end
		end

		-- A target mode chooses where on the outer defence layer to start, so that is all
		-- it may choose from. The flood reaches every opening in whatever the bed happens
		-- to be attached to, and on a large build the one nearest you can sit eight blocks
		-- of tunnelling from the bed while another is one block away - picking that is how
		-- a dig ended up running the length of a wall to get anywhere. Only the ways in
		-- that are about as short as the shortest are offered up.
		local mincost = math.huge
		for node, cost in exposed do
			if cost < mincost and allowed(node, origin and (node - origin).Magnitude or 0) then
				mincost = cost
			end
		end
		local costlimit = math.floor(mincost) + ENTRY_TOLERANCE

		local best, bestkey, bestcost = nil, math.huge, math.huge
		local near, nearreach, nearcost = nil, math.huge, math.huge
		local cheap, cheapcost = nil, math.huge

		for node, cost in exposed do
			local reach = origin and (node - origin).Magnitude or 0
			if math.floor(cost) > costlimit or not allowed(node, reach) then continue end

			if score then
				local key = score(node, cost, reach)
				if key and key < bestkey then
					best, bestkey, bestcost = node, key, cost
				end
			else
				if cost < cheapcost then
					cheap, cheapcost = node, cost
				end
				if reach < nearreach then
					near, nearreach, nearcost = node, reach, cost
				end
			end
		end

		if score then
			return best, bestcost, bestkey
		end
		if near and nearcost <= (cheapcost * NEAR_COST_TOLERANCE) + NEAR_COST_MARGIN then
			return near, nearcost, nearcost
		end
		return cheap, cheapcost, cheapcost
	end

	-- avoidOwn routes the tunnel around blocks you placed yourself. The path is what
	-- actually gets broken - breakBlock digs along it rather than hitting the target
	-- directly - so a Self Break check on the target alone never prevented your own
	-- blocks being destroyed on the way there. The flag is part of the cache entry
	-- because the same target has two different cheapest routes depending on it.
	local function calculatePath(target, blockpos, avoidOwn, maxRange, score, prefer, maxAngle)
		avoidOwn = avoidOwn == true
		local cached = cache[blockpos]
		if cached and cached[4] == avoidOwn then
			local pos, cost, key = pickEntry(cached[5], maxRange, score, prefer, maxAngle)
			if pos then
				return pos, cost, cached[3], key
			end
			return
		end
		local visited, unvisited, distances, air, path = {}, {{0, blockpos}}, {[blockpos] = 0}, {}, {}
		-- Which way each block was reached from, so carrying on that way can be preferred.
		local heading = {}
		-- The corners of everything the flood touches, which is what air is measured
		-- against afterwards to tell a way out from a sealed pocket.
		local low, high = blockpos, blockpos

		for _ = 1, 10000 do
			local node = unvisited[1]
			if not node then break end
			table.remove(unvisited, 1)
			-- Relaxing a block queues it again rather than moving it, so the same one can
			-- come up twice; the first time is the cheap one.
			if visited[node[2]] then continue end
			visited[node[2]] = true
			low, high = low:Min(node[2]), high:Max(node[2])

			for _, side in sides do
				side = node[2] + side
				if visited[side] then continue end

				local block = getPlacedBlock(side)
				if not block or block:GetAttribute('NoBreak') or block == target
					or (avoidOwn and block:GetAttribute('PlacedByUserId') == lplr.UserId) then
					if not block then
						air[node[2]] = true
					end
					continue
				end

				local facing = side - node[2]
				local turn = (heading[node[2]] and heading[node[2]] ~= facing) and TURN_COST or 0
				local curdist = node[1] + 1 + turn + (math.min(getBlockHits(block, side), HIT_CAP) * HIT_WEIGHT)
				if curdist < (distances[side] or math.huge) then
					enqueue(unvisited, curdist, side)
					distances[side] = curdist
					path[side] = node[2]
					heading[side] = facing
				end
			end
		end

		-- Only the openings are kept, not the whole distance map, so a cached route
		-- stays small enough to hold one per target.
		local pockets = {}
		local exposed = {}
		for node in air do
			for _, side in sides do
				local at = node + side
				if not getPlacedBlock(at) and reachesOutside(at, pockets, low, high) then
					exposed[node] = distances[node]
					break
				end
			end
		end
		if not next(exposed) then return end

		-- Cached even when nothing is reachable from where you stand right now, keyed on
		-- the target's own position for invalidation. Walking the route again on every
		-- pass just to rediscover that it is still out of reach costs far more than
		-- holding on to it until a block nearby actually changes.
		cache[blockpos] = {
			blockpos,
			0,
			path,
			avoidOwn,
			exposed
		}

		local pos, cost, key = pickEntry(exposed, maxRange, score, prefer, maxAngle)
		if pos then
			return pos, cost, path, key
		end
	end

	bedwars.placeBlock = function(pos, item)
		if getItem(item) then
			store.blockPlacer.blockType = item
			return store.blockPlacer:placeBlock(bedwars.BlockController:getBlockPosition(pos))
		end
	end

	-- Every position a block occupies, so multi-part blocks are pathed to correctly.
	local function containedPositions(block)
		local handler = bedwars.BlockController:getHandlerRegistry():getHandler(block.Name)
		return handler and handler:getContainedPositions(block) or {block.Position / 3}
	end

	bedwars.getBlockHealth = getBlockHealth
	bedwars.getPlacedBlock = getPlacedBlock
	bedwars.getContainedPositions = containedPositions

	-- First person puts the camera inside your own head. The head is looked up live and
	-- the gap is given a little room: a cached head goes stale across a respawn and then
	-- reports a huge gap forever, and the walk animation moves the head enough that too
	-- tight a threshold reads as third person mid-stride - which is what let a
	-- third-person-only module run while you were in first and walking.
	bedwars.isFirstPerson = function()
		local char = lplr.Character
		local head = char and char:FindFirstChild('Head')
		local camera = workspace.CurrentCamera or gameCamera
		if not head or not camera then return false end
		return (camera.CFrame.Position - head.Position).Magnitude < 1.5
	end
	bedwars.getBlockHits = getBlockHits

	-- Mirrors what the AutoTool module does for a manual break: select the hotbar slot
	-- holding the best tool for this block so it is genuinely held, rather than only
	-- swapping the hand underneath the UI.
	local function equipBreakTool(block)
		local blockmeta = bedwars.ItemMeta[block.Name]
		local breaktype = blockmeta and blockmeta.block and blockmeta.block.breakType
		local tool = breaktype and store.tools[breaktype]
		if not tool then return end

		for i, v in store.inventory.hotbar do
			if v.item and v.item.itemType == tool.itemType then
				if store.inventory.hotbarSlot ~= i - 1 then
					-- Dispatched without waiting on the inventory event, unlike the module's
					-- own switch - this runs inside the break loop and cannot afford to
					-- block it on an event that may never arrive.
					pcall(function()
						bedwars.Store:dispatch({type = 'InventorySelectHotbarSlot', slot = i - 1})
					end)
				end
				break
			end
		end

		-- An inventory item only carries a tool instance while it is materialised, and
		-- switchItem indexes it either way. The best tool for a block is often one sitting
		-- in the inventory without one, so this threw and took the whole break down with
		-- it - which is why turning Auto Tool on stopped the nuker breaking anything.
		if tool.tool then
			switchItem(tool.tool)
		end
	end

	-- autoTool: nil keeps the old behaviour of only swapping while no sword swing is in
	-- flight, true always swaps to the right tool, false leaves your hand alone.
	-- The swing currently playing on your character, so the next one replaces it rather
	-- than stacking another track on top of one still running.
	local swingtrack

	-- How long to leave a swing running when the track itself cannot say, and how long to
	-- fade it out over.
	local SWING_FALLBACK = 0.3
	local SWING_FADE = 0.1

	--[[
		Ends a swing once it has had its time.

		Scheduled rather than waited on. Waiting blocked the promise this is called from
		and, at any break speed shorter than the wait, started the next swing on top of one
		still playing. Leaving it to be stopped by the next swing instead was worse: the
		last one of a dig had no next swing to replace it, so it simply never stopped.

		Length is zero until the asset has loaded, which is usually the case immediately
		after asking for it, so there is a fallback to fall back on.
	]]
	local function endSwing(track)
		task.delay(track.Length > 0 and track.Length or SWING_FALLBACK, function()
			if swingtrack == track then
				swingtrack = nil
			end
			pcall(function()
				track:Stop(SWING_FADE)
				track:Destroy()
			end)
		end)
	end

	-- The remaining blocks between an opening and the target, nearest end first.
	local ROUTE_LIMIT = 32

	local function routeFrom(pos, path, into)
		table.clear(into)
		local node = pos
		for _ = 1, ROUTE_LIMIT do
			if not node then break end
			table.insert(into, node)
			node = path[node]
		end
		return into
	end

	-- options: Range caps how far the block being broken may be, Angle how far off your
	-- view it may sit, Score ranks the ways in, Prefer is a route to carry on down, and
	-- Route is filled in with the one taken.
	bedwars.breakBlock = function(block, effects, anim, customHealthbar, avoidOwn, autoTool, options)
		if lplr:GetAttribute('DenyBlockBreak') or not entitylib.isAlive or InfiniteFly.Enabled then return end
		options = options or {}
		local maxRange = math.min(options.Range or 30, 30)
		local entryScore, prefer, maxAngle = options.Score, options.Prefer, options.Angle
		local cost, pos, target, path = math.huge
		-- A bed covers several block positions, each with its own way in. They are
		-- compared on whatever the target mode is ranking by, so the mode's pick is not
		-- quietly overridden by a cheaper tunnel into the bed's other half.
		local bestkey = math.huge

		for _, v in containedPositions(block) do
			local dpos, dcost, dpath, dkey = calculatePath(block, v * 3, avoidOwn, maxRange, entryScore, prefer, maxAngle)
			dkey = dkey or dcost
			if dpos and dkey < bestkey then
				bestkey, cost, pos, target, path = dkey, dcost, dpos, v * 3, dpath
			end
		end

		if pos then
			if (entitylib.character.RootPart.Position - pos).Magnitude > maxRange then return end
			local dblock, dpos = getPlacedBlock(pos)
			if not dblock then return end
			-- The route is meant to avoid these already; this catches the case where the
			-- target itself is one of your own blocks.
			if avoidOwn and dblock:GetAttribute('PlacedByUserId') == lplr.UserId then return end

			if autoTool ~= false and (autoTool or (workspace:GetServerTimeNow() - bedwars.SwordController.lastAttack) > 0.4) then
				equipBreakTool(dblock)
			end

			if blockhealthbar.blockHealth == -1 or dpos ~= blockhealthbar.breakingBlockPosition then
				blockhealthbar.blockHealth = getBlockHealth(dblock, dpos)
				blockhealthbar.breakingBlockPosition = dpos
			end

			bedwars.ClientDamageBlock:Get('DamageBlock'):CallServerAsync({
				blockRef = {blockPosition = dpos},
				hitPosition = pos,
				hitNormal = Vector3.FromNormalId(Enum.NormalId.Top)
			}):andThen(function(result)
				if result then
					if result == 'cancelled' then
						store.damageBlockFail = tick() + 1
						return
					end

					if effects then
						-- BlockBreakController builds a fresh blockBreaker (and with it the
						-- BlockHealthbar that actually draws the bar) when it re-enables, so
						-- the reference captured at load goes stale and the game's own
						-- healthbar quietly stops appearing. Resolve it live instead.
						local breaker = bedwars.Knit.Controllers.BlockBreakController.blockBreaker or bedwars.BlockBreaker
						local meta = bedwars.ItemMeta[dblock.Name]
						-- BlockHealthbar:show compares maxHealth against 0, so a nil one
						-- throws inside the promise and takes the whole break down with it.
						local maxhealth = dblock:GetAttribute('MaxHealth') or (meta and meta.block and meta.block.health) or 10
						local prehealth = blockhealthbar.blockHealth or maxhealth
						local blockdmg = prehealth - (result == 'destroyed' and 0 or (getBlockHealth(dblock, dpos) or 0))
						pcall(customHealthbar or breaker.updateHealthbar, breaker, {blockPosition = dpos}, prehealth, maxhealth, blockdmg, dblock)
						blockhealthbar.blockHealth = math.max(prehealth - blockdmg, 0)

						if blockhealthbar.blockHealth <= 0 then
							breaker.breakEffect:playBreak(dblock.Name, dpos, lplr)
							-- The maid moved onto the BlockHealthbar object; destroy() is what
							-- cleans it there. Throwing here rejects the DamageBlock promise
							-- and aborts the break, so both routes are guarded.
							pcall(function()
								if breaker.blockHealthbar then
									breaker.blockHealthbar:destroy()
								elseif breaker.healthbarMaid then
									breaker.healthbarMaid:DoCleaning()
								end
							end)
							blockhealthbar.breakingBlockPosition = Vector3.zero
						else
							breaker.breakEffect:playHit(dblock.Name, dpos, lplr)
						end
					end

					--[[
						Matched to what the game plays when you break a block by hand.

						The viewmodel animation asked for here was 15, FP_SWING_SWORD, when
						breaking plays 14, FP_USE_ITEM - so a pickaxe has been swinging like
						a sword all along, which is most of why it never looked right. Items
						may override that, which is how the odd tool gets its own swing.

						Nothing is cut off on a timer any more either. Waiting a fixed 0.3s
						and then stopping the track meant every break speed under that
						started the next swing on top of one still playing, and blocked the
						promise this runs inside for the same 0.3s. The game does not stop
						this animation by hand at all - it is left to finish.
					]]
					if anim then
						pcall(function()
							local held = store.hand.tool and bedwars.ItemMeta[store.hand.tool.Name]
							local swing = (held and held.breakBlockSwingAnimationOverride) or bedwars.AnimationType.FP_USE_ITEM
							bedwars.ViewmodelController:playAnimation(swing)
						end)

						-- The character swing is the half other players can see, so it stays
						-- - one at a time, replaced rather than layered.
						pcall(function()
							if swingtrack then
								swingtrack:Stop(SWING_FADE)
								swingtrack:Destroy()
								swingtrack = nil
							end

							local track = bedwars.AnimationUtil:playAnimation(lplr, bedwars.BlockController:getAnimationController():getAssetId(bedwars.AnimationType.SWORD_SWING))
							swingtrack = track
							endSwing(track)
						end)
					end
				end
			end)

			-- Replaced only when the dig moves to a different first block. Following an
			-- established route leaves it alone, and so does hitting the same block again:
			-- routes of the same length tie all the time and each recompute can hand back a
			-- different one of them, so rebuilding on every hit made a straight dig bend
			-- partway through for no reason anyone could see.
			--
			-- Built here rather than by the caller because breakBlock yields above, and by
			-- the time it returns the route may have been dropped from the cache.
			local followed = bestkey == -math.huge
			if options.Route and not followed and options.Route[1] ~= pos then
				routeFrom(pos, path, options.Route)
			end

			-- Returned whether or not effects are on. Without this a target that could not
			-- be reached was indistinguishable from a hit that landed, so the caller kept
			-- picking the same unreachable block instead of moving to the next one.
			return pos, path, target
		end
	end

	for _, v in Enum.NormalId:GetEnumItems() do
		table.insert(sides, Vector3.FromNormalId(v) * 3)
	end

	local function updateStore(new, old)
		if new.Bedwars ~= old.Bedwars then
			store.equippedKit = new.Bedwars.kit ~= 'none' and new.Bedwars.kit or ''
		end

		if new.Game ~= old.Game then
			store.matchState = new.Game.matchState
			store.queueType = new.Game.queueType or 'bedwars_test'
		end

		if new.Inventory ~= old.Inventory then
			local newinv = (new.Inventory and new.Inventory.observedInventory or {inventory = {}})
			local oldinv = (old.Inventory and old.Inventory.observedInventory or {inventory = {}})
			store.inventory = newinv

			if newinv ~= oldinv then
				vainEvents.InventoryChanged:Fire()
			end

			if newinv.inventory.items ~= oldinv.inventory.items then
				vainEvents.InventoryAmountChanged:Fire()
				store.tools.sword = getSword()
				for _, v in {'stone', 'wood', 'wool'} do
					store.tools[v] = getTool(v)
				end
			end

			if newinv.inventory.hand ~= oldinv.inventory.hand then
				local currentHand, toolType = new.Inventory.observedInventory.inventory.hand, ''
				if currentHand then
					local handData = bedwars.ItemMeta[currentHand.itemType]
					toolType = handData.sword and 'sword' or handData.block and 'block' or currentHand.itemType:find('bow') and 'bow'
				end

				store.hand = {
					tool = currentHand and currentHand.tool,
					amount = currentHand and currentHand.amount or 0,
					toolType = toolType
				}
			end
		end
	end

	local storeChanged = bedwars.Store.changed:connect(updateStore)
	updateStore(bedwars.Store:getState(), {})

	for _, event in {'MatchEndEvent', 'EntityDeathEvent', 'BedwarsBedBreak', 'BalloonPopped', 'AngelProgress', 'GrapplingHookFunctions'} do
		if not vain.Connections then return end
		bedwars.Client:WaitFor(event):andThen(function(connection)
			vain:Clean(connection:Connect(function(...)
				vainEvents[event]:Fire(...)
			end))
		end)
	end

	-- Backs the 'Final Kill' target mode. brokenBedTeam.id is keyed the same way as a
	-- player's Team attribute, so it can be compared directly when sorting targets.
	vain:Clean(vainEvents.BedwarsBedBreak.Event:Connect(function(bedTable)
		if bedTable and bedTable.brokenBedTeam then
			brokenbeds[bedTable.brokenBedTeam.id] = true
		end
	end))
	vain:Clean(vainEvents.MatchEndEvent.Event:Connect(function()
		table.clear(brokenbeds)
	end))

	vain:Clean(bedwars.ZapNetworking.EntityDamageEventZap.On(function(...)
		vainEvents.EntityDamageEvent:Fire({
			entityInstance = ...,
			damage = select(2, ...),
			damageType = select(3, ...),
			fromPosition = select(4, ...),
			fromEntity = select(5, ...),
			knockbackMultiplier = select(6, ...),
			knockbackId = select(7, ...),
			disableDamageHighlight = select(13, ...)
		})
	end))

	for _, event in {'PlaceBlockEvent', 'BreakBlockEvent'} do
		vain:Clean(bedwars.ZapNetworking[event..'Zap'].On(function(...)
			local data = {
				blockRef = {
					blockPosition = ...,
				},
				player = select(5, ...)
			}
			for i, v in cache do
				if ((data.blockRef.blockPosition * 3) - v[1]).Magnitude <= 30 then
					-- The route table is handed out by breakBlock, which yields before it
					-- returns - emptying it here left the caller holding an empty route and
					-- no way to carry on down the hole it had started.
					table.clear(v)
					cache[i] = nil
				end
			end
			vainEvents[event]:Fire(data)
		end))
	end

	store.blocks = collection('block', gui)
	store.shop = collection({'BedwarsItemShop', 'TeamUpgradeShopkeeper'}, gui, function(tab, obj)
		table.insert(tab, {
			Id = obj.Name,
			RootPart = obj,
			Shop = obj:HasTag('BedwarsItemShop'),
			Upgrades = obj:HasTag('TeamUpgradeShopkeeper')
		})
	end)
	store.enchant = collection({'enchant-table', 'broken-enchant-table'}, gui, nil, function(tab, obj, tag)
		if obj:HasTag('enchant-table') and tag == 'broken-enchant-table' then return end
		obj = table.find(tab, obj)
		if obj then
			table.remove(tab, obj)
		end
	end)

	local kills = sessioninfo:AddItem('Kills')
	local beds = sessioninfo:AddItem('Beds')
	local wins = sessioninfo:AddItem('Wins')
	local games = sessioninfo:AddItem('Games')

	local mapname = 'Unknown'
	sessioninfo:AddItem('Map', 0, function()
		return mapname
	end, false)

	task.delay(1, function()
		games:Increment()
	end)

	task.spawn(function()
		pcall(function()
			repeat task.wait() until store.matchState ~= 0 or vain.Loaded == nil
			if vain.Loaded == nil then return end
			mapname = workspace:WaitForChild('Map', 5):WaitForChild('Worlds', 5):GetChildren()[1].Name
			mapname = string.gsub(string.split(mapname, '_')[2] or mapname, '-', '') or 'Blank'
		end)
	end)

	vain:Clean(vainEvents.BedwarsBedBreak.Event:Connect(function(bedTable)
		if bedTable.player and bedTable.player.UserId == lplr.UserId then
			beds:Increment()
		end
	end))

	vain:Clean(vainEvents.MatchEndEvent.Event:Connect(function(winTable)
		if (bedwars.Store:getState().Game.myTeam or {}).id == winTable.winningTeamId or lplr.Neutral then
			wins:Increment()
		end
	end))

	vain:Clean(vainEvents.EntityDeathEvent.Event:Connect(function(deathTable)
		local killer = playersService:GetPlayerFromCharacter(deathTable.fromEntity)
		local killed = playersService:GetPlayerFromCharacter(deathTable.entityInstance)
		if not killed or not killer then return end

		if killed ~= lplr and killer == lplr then
			kills:Increment()
		end
	end))

	task.spawn(function()
		repeat
			if entitylib.isAlive then
				entitylib.character.AirTime = entitylib.character.Humanoid.FloorMaterial ~= Enum.Material.Air and tick() or entitylib.character.AirTime
			end

			for _, v in entitylib.List do
				v.LandTick = math.abs(v.RootPart.Velocity.Y) < 0.1 and v.LandTick or tick()
				if (tick() - v.LandTick) > 0.2 and v.Jumps ~= 0 then
					v.Jumps = 0
					v.Jumping = false
				end
			end
			task.wait()
		until vain.Loaded == nil
	end)

	pcall(function()
		if getthreadidentity and setthreadidentity then
			local old = getthreadidentity()
			setthreadidentity(2)

			-- The restore has to happen whether or not the shop loads. It used to sit at
			-- the end of this block, so anything throwing above it - the require, or
			-- getShopItem against a changed shop - left the thread at identity 2 for good.
			-- Every module file loads after this point, and at identity 2 they cannot
			-- parent an Instance, so module creation failed with "lacking capability
			-- Plugin" and the failure looked like it came from whichever module happened
			-- to be next.
			local ok = pcall(function()
				bedwars.Shop = require(replicatedStorage.TS.games.bedwars.shop['bedwars-shop']).BedwarsShop
				bedwars.ShopItems = debug.getupvalue(debug.getupvalue(bedwars.Shop.getShopItem, 1), 2)
				bedwars.Shop.getShopItem('iron_sword', lplr)
			end)

			setthreadidentity(old)
			store.shopLoaded = ok
		else
			task.spawn(function()
				repeat
					task.wait(0.1)
				until vain.Loaded == nil or bedwars.AppController:isAppOpen('BedwarsItemShopApp')

				bedwars.Shop = require(replicatedStorage.TS.games.bedwars.shop['bedwars-shop']).BedwarsShop
				bedwars.ShopItems = debug.getupvalue(debug.getupvalue(bedwars.Shop.getShopItem, 1), 2)
				store.shopLoaded = true
			end)
		end
	end)

	vain:Clean(function()
		Client.Get = OldGet
		bedwars.BlockController.isBlockBreakable = OldBreak
		store.blockPlacer:disable()
		for _, v in vainEvents do
			v:Destroy()
		end
		for _, v in cache do
			table.clear(v[3])
			table.clear(v)
		end
		table.clear(store.blockPlacer)
		table.clear(vainEvents)
		table.clear(bedwars)
		table.clear(store)
		table.clear(cache)
		table.clear(sides)
		table.clear(remotes)
		storeChanged:disconnect()
		storeChanged = nil
	end)
end)

for _, v in {'AntiRagdoll', 'TriggerBot', 'SilentAim', 'AutoRejoin', 'Rejoin', 'Disabler', 'Timer', 'ServerHop', 'MouseTP', 'MurderMystery'} do
	vain:Remove(v)
end

run(function()
	local AimAssist
	local Targets
	local Sort
	local AimPart
	local AimMode
	local Smoothness
	local AimSpeed
	local Distance
	local AngleSlider
	local StrafeIncrease
	local KillauraTarget
	local ClickAim
	local LockTarget
	local Falloff
	local Humanize
	local UseProjectile
	local ProjectileSpeed
	
	-- Reused for the projectile trajectory solve, same as ProjectileAimbot does: only the
	-- map blocks the shot, players are not obstacles to aim around.
	local aimRayCheck = RaycastParams.new()
	aimRayCheck.FilterType = Enum.RaycastFilterType.Include
	aimRayCheck.FilterDescendantsInstances = {workspace:FindFirstChild('Map')}
	
	-- Remembered between frames so 'Lock on Target' can keep aiming at the same entity
	-- instead of re-picking the closest one every heartbeat.
	local locked
	
	-- Humanize state. The drift is a slow wander toward a re-rolled target offset, not a
	-- fresh random value per frame: per-frame randomness is white noise, which reads on
	-- screen as a harsh flicker rather than as a human hand. Holding an offset and easing
	-- toward a new one keeps the motion continuous.
	local humanizeoffset, humanizetarget, humanizenext = Vector2.zero, Vector2.zero, 0
	
	local function heldItemMeta()
		local hand = store.hand
		local tool = hand and hand.tool
		return tool and bedwars.ItemMeta[tool.Name] or nil
	end
	
	-- Sword always qualifies. With Use Projectile on, anything the game considers a
	-- projectile source counts too - that covers thrown items and fired weapons alike,
	-- since both carry a projectileSource in their item meta.
	local function heldAllows()
		local hand = store.hand
		if not hand then return false end
		if hand.toolType == 'sword' then return true, true end
		if UseProjectile.Enabled then
			local meta = heldItemMeta()
			if meta and meta.projectileSource then return true, false end
		end
		return false
	end
	
	local function angleTo(position)
		local campos = gameCamera.CFrame.Position
		local delta = position - campos
		if delta.Magnitude <= 0 then return nil end
		return math.acos(math.clamp(gameCamera.CFrame.LookVector:Dot(delta.Unit), -1, 1)), delta
	end
	
	local function aimPart(ent)
		local head, root = ent.Head, ent.RootPart
		local value = AimPart.Value
		if value == 'Head' then return head or root end
		if value == 'Nearest' then
			-- Whichever part is currently the smaller camera movement away, so the assist
			-- takes the shortest correction rather than always dragging to one part.
			if not head then return root end
			if not root then return head end
			local ha, ra = angleTo(head.Position), angleTo(root.Position)
			if not ha then return root end
			if not ra then return head end
			return ha <= ra and head or root
		end
		return root
	end
	
	-- Where to point so a fired projectile actually lands on the target, rather than
	-- pointing straight at them and shooting under their feet. Returns nil when the solve
	-- fails or the item is not a projectile, in which case the caller aims directly.
	local function projectileAimPos(ent, part)
		local meta = heldItemMeta()
		local source = meta and meta.projectileSource
		if not source then return nil end
	
		local ok, solved = pcall(function()
			local ammo = source.ammoItemTypes and source.ammoItemTypes[1] or 'arrow'
			local projname = type(source.projectileType) == 'function' and source.projectileType(ammo) or source.projectileType
			local projmeta = projname and bedwars.ProjectileMeta[projname]
			if not projmeta then return nil end
	
			return prediction.SolveTrajectory(
				gameCamera.CFrame.Position,
				projmeta.launchVelocity or 100,
				projmeta.gravitationalAcceleration or 196.2,
				part.Position,
				part.Velocity,
				workspace.Gravity,
				ent.HipHeight,
				ent.Jumping and 42.6 or nil,
				aimRayCheck
			)
		end)
	
		return ok and solved or nil
	end
	
	local function pickTarget()
		if KillauraTarget.Enabled then return store.KillauraTarget end
	
		if LockTarget.Enabled and locked and locked.RootPart and entitylib.isAlive then
			local stillvalid = pcall(function()
				return entitylib.isVulnerable(locked)
			end)
			if stillvalid and (locked.RootPart.Position - entitylib.character.RootPart.Position).Magnitude <= Distance.Value then
				return locked
			end
		end
	
		local ent = entitylib.EntityPosition({
			Range = Distance.Value,
			Part = 'RootPart',
			Wallcheck = Targets.Walls.Enabled,
			Players = Targets.Players.Enabled,
			NPCs = Targets.NPCs.Enabled,
			Preference = Targets.Preference.Value,
			Sort = sortmethods[Sort.Value]
		})
		locked = ent
		return ent
	end
	
	AimAssist = vain.Categories.Combat:CreateModule({
		Name = 'AimAssist',
		Function = function(callback)
			if callback then
				AimAssist:Clean(runService.Heartbeat:Connect(function(dt)
					-- Guarded as a whole: this reads game state that can disappear between
					-- frames (entities dying, the held item changing mid-swing). A throw here
					-- would otherwise spam the console every single frame.
					pcall(function()
						if not entitylib.isAlive then return end
	
						local allowed, issword = heldAllows()
						if not allowed then return end
	
						if ClickAim.Enabled then
							if issword then
								if (tick() - bedwars.SwordController.lastSwing) >= 0.4 then return end
							elseif not inputService:IsMouseButtonPressed(0) then
								-- Projectiles have no swing to time against, so fall back to
								-- "only while actually holding the mouse down".
								return
							end
						end
	
						local ent = pickTarget()
						if not ent or not ent.RootPart then return end
	
						local part = aimPart(ent)
						if not part then return end
	
						local delta = (ent.RootPart.Position - entitylib.character.RootPart.Position)
						local localfacing = entitylib.character.RootPart.CFrame.LookVector * Vector3.new(1, 0, 1)
						-- Flatten first and bail on a zero-length horizontal delta. A target
						-- directly above or below you (a diamond guardian over the generator
						-- you are standing under) leaves a zero vector, whose .Unit is NaN.
						-- Comparisons against NaN are always false, so the angle limit was
						-- silently skipped and the camera got yanked to a target that should
						-- have been rejected.
						local flat = delta * Vector3.new(1, 0, 1)
						if flat.Magnitude <= 0 then return end
						local facingangle = math.acos(math.clamp(localfacing:Dot(flat.Unit), -1, 1))
						if facingangle >= (math.rad(AngleSlider.Value) / 2) then return end
	
						local aimpos = part.Position
						if not issword and UseProjectile.Enabled then
							aimpos = projectileAimPos(ent, part) or aimpos
						end
	
						local err, aimdelta = angleTo(aimpos)
						if not err then return end
	
						targetinfo.Targets[ent] = tick() + 1
	
						-- Projectiles get their own, much higher speed. A bow shot is a single
						-- instant with no second chance, so the camera has to be on target
						-- before it leaves your hand - unlike melee, where a slow drift still
						-- lands hits because you keep swinging. At 60+ the per-frame alpha
						-- reaches 1 and it snaps outright.
						local basespeed = (not issword) and ProjectileSpeed.Value or AimSpeed.Value
						local speed = basespeed + (StrafeIncrease.Enabled and (inputService:IsKeyDown(Enum.KeyCode.A) or inputService:IsKeyDown(Enum.KeyCode.D)) and 10 or 0)
						local alpha
						if AimMode.Value == 'Constant' then
							-- Turn at a fixed angular rate: work out what fraction of the
							-- remaining error that rate covers this frame. Distance to the
							-- target stops mattering, which is what makes it look steady.
							local step = math.rad(speed * 15) * dt
							alpha = err > 0 and (step / err) or 0
						else
							alpha = speed * dt
							-- Smooth easing is deliberately skipped for projectiles. Easing off
							-- near the target is what makes melee tracking look human, but it is
							-- precisely the last degree that decides whether a shot lands, and
							-- damping it there is what made shooting feel slow.
							if AimMode.Value == 'Smooth' and issword then
								-- Ease out: the closer the crosshair already is, the gentler the
								-- correction, so it settles instead of snapping the last degree.
								-- Higher Smoothness widens the window over which it eases.
								alpha = alpha * math.clamp(err / math.rad(Smoothness.Value * 2), 0.08, 1)
							end
						end
	
						if Falloff.Enabled then
							-- Strength drops off with range, so distant targets get a nudge and
							-- close ones get the full pull. Independent of Smooth, which eases on
							-- angle rather than distance.
							alpha = alpha * math.clamp(1 - (aimdelta.Magnitude / math.max(Distance.Value, 1)), 0.15, 1)
						end
	
						local newcframe = gameCamera.CFrame:Lerp(CFrame.lookAt(gameCamera.CFrame.Position, aimpos), math.clamp(alpha, 0, 1))
	
						if Humanize.Value > 0 then
							local amplitude = math.rad(Humanize.Value / 40)
							-- Re-roll where the drift is heading every third of a second or so.
							-- The random interval stops it settling into a visible rhythm.
							if tick() >= humanizenext then
								humanizenext = tick() + 0.25 + math.random() * 0.35
								humanizetarget = Vector2.new((math.random() - 0.5) * 2, (math.random() - 0.5) * 2) * amplitude
							end
							-- Ease toward that target rather than jumping to it, so every frame
							-- is a small continuation of the last instead of an independent jolt.
							humanizeoffset = humanizeoffset:Lerp(humanizetarget, math.clamp(dt * 4, 0, 1))
							newcframe = newcframe * CFrame.Angles(humanizeoffset.Y, humanizeoffset.X, 0)
						end
	
						gameCamera.CFrame = newcframe
					end)
				end))
			else
				locked = nil
				humanizeoffset, humanizetarget, humanizenext = Vector2.zero, Vector2.zero, 0
			end
		end,
		Tooltip = 'Smoothly aims at a valid target while holding a sword, or any projectile with Use Projectile on'
	})
	Targets = AimAssist:CreateTargets({
		Players = true,
		Walls = true,
		Tooltip = 'Which entities this module is allowed to target'
	})
	-- Damage/Distance stay pinned to the front (Damage is the default), the rest are
	-- sorted so the dropdown order stays stable - iterating sortmethods directly is
	-- hash order, which reshuffles the list between injections.
	local methods, extramethods = {'Damage', 'Distance'}, {}
	for i in sortmethods do
		if not table.find(methods, i) then
			table.insert(extramethods, i)
		end
	end
	table.sort(extramethods)
	for _, v in extramethods do
		table.insert(methods, v)
	end
	Sort = AimAssist:CreateDropdown({
		Name = 'Target Mode',
		Tooltip = 'How targets are ranked when several are valid at once',
		List = methods,
		Tooltips = sortmethodtips
	})
	AimPart = AimAssist:CreateDropdown({
		Name = 'Aim Part',
		Tooltip = 'Which part of the target to aim at',
		List = {'RootPart', 'Head', 'Nearest'},
		Tooltips = {
			RootPart = 'Aims at the body',
			Head = 'Aims at the head',
			Nearest = 'Aims at whichever of the two needs the smaller camera movement'
		}
	})
	AimMode = AimAssist:CreateDropdown({
		Name = 'Aim Mode',
		Tooltip = 'How the camera moves toward the target',
		List = {'Linear', 'Smooth', 'Constant'},
		Tooltips = {
			Linear = 'Moves a fixed fraction of the way each frame - fast at first, slower as it closes in',
			Smooth = 'Eases off as the crosshair approaches',
			Constant = 'Turns at a steady speed no matter how far off the target is'
		}
	})
	Smoothness = AimAssist:CreateSlider({
		Name = 'Smoothness',
		Tooltip = 'Only used by Smooth mode.\nHigher values start easing off from further away.',
		Min = 1,
		Max = 30,
		Default = 10
	})
	AimSpeed = AimAssist:CreateSlider({
		Name = 'Aim Speed',
		Tooltip = 'How quickly your aim moves toward the target',
		Min = 1,
		Max = 20,
		Default = 6
	})
	ProjectileSpeed = AimAssist:CreateSlider({
		Name = 'Projectile Aim Speed',
		Tooltip = 'Aim speed used while holding a projectile, replacing Aim Speed.\n60 and above snaps instantly.',
		Min = 1,
		Max = 100,
		Default = 45
	})
	Distance = AimAssist:CreateSlider({
		Name = 'Distance',
		Tooltip = 'Furthest a target can be, in studs',
		Min = 1,
		Max = 30,
		Default = 30,
		Suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})
	AngleSlider = AimAssist:CreateSlider({
		Name = 'Max angle',
		Tooltip = 'Widest angle from your view a target may be at',
		Min = 1,
		Max = 360,
		Default = 70
	})
	Humanize = AimAssist:CreateSlider({
		Name = 'Humanize',
		Tooltip = 'Adds a slow, continuous drift to the aim.\n0 disables it.',
		Min = 0,
		Max = 100,
		Default = 0,
		Suffix = function()
			return '%'
		end
	})
	ClickAim = AimAssist:CreateToggle({
		Name = 'Click Aim',
		Tooltip = 'Only aims while you are attacking - holding the mouse down for projectiles',
		Default = true
	})
	LockTarget = AimAssist:CreateToggle({
		Name = 'Lock on Target',
		Tooltip = 'Sticks to one target until it dies or leaves range'
	})
	UseProjectile = AimAssist:CreateToggle({
		Name = 'Use Projectile',
		Tooltip = 'Also aims while holding a projectile weapon, and leads the shot to where the target is moving'
	})
	Falloff = AimAssist:CreateToggle({
		Name = 'Falloff',
		Tooltip = 'Weakens the assist the further away the target is'
	})
	KillauraTarget = AimAssist:CreateToggle({
		Name = 'Use killaura target',
		Tooltip = 'Aims at whatever Killaura is currently attacking'
	})
	StrafeIncrease = AimAssist:CreateToggle({Name = 'Strafe increase', Tooltip = 'Speeds up while strafing'})
	
end)

run(function()
	local AutoClicker
	local GUICheck
	local HeldItem
	local StartDelay
	local OnlyTargeting
	local CPS
	local BlockCPS = {}
	local PlaceBlocks
	local BurstMode
	local BurstLength
	local BurstPause
	local Thread
	local burstcount = 0
	
	-- task.cancel throws on a thread that has already finished, and Thread stays non-nil
	-- after the loop below dies, so every call site goes through this. Without it a single
	-- failed pass would make the next click error here and leave the module permanently
	-- unable to start a new loop.
	local function stopThread()
		if Thread then
			pcall(task.cancel, Thread)
			Thread = nil
		end
	end
	
	-- Whether something is actually within sword reach, using the same region check
	-- TriggerBot relies on.
	local function hasTarget()
		local ok, found = pcall(function()
			local tool = store.hand.tool
			local meta = tool and bedwars.ItemMeta[tool.Name]
			local range = meta and meta.sword and meta.sword.attackRange or 14.4
			return bedwars.SwordController:getTargetInRegion(range, 0) and true or false
		end)
		return ok and found
	end
	
	-- Returns true when a click actually happened, which is what the burst counter counts -
	-- a pass that was skipped (menu open, nothing in reach) must not consume a burst.
	local function doClick()
		if GUICheck.Enabled and bedwars.AppController:isLayerOpen(bedwars.UILayers.MAIN) then return false end
	
		local toolType = store.hand.toolType
	
		if toolType == 'block' then
			if HeldItem.Value == 'Sword' or not PlaceBlocks.Enabled then return false end
			local blockPlacer = bedwars.BlockPlacementController.blockPlacer
			if not blockPlacer then return false end
			if (workspace:GetServerTimeNow() - bedwars.BlockCpsController.lastPlaceTimestamp) < ((1 / 12) * 0.5) then return false end
	
			local mouseinfo = blockPlacer.clientManager:getBlockSelector():getMouseInfo(0)
			-- placementPosition == itself is a NaN check: NaN is the only value that fails
			-- an equality test against itself.
			if mouseinfo and mouseinfo.placementPosition == mouseinfo.placementPosition then
				task.spawn(blockPlacer.placeBlock, blockPlacer, mouseinfo.placementPosition)
				return true
			end
			return false
		end
	
		if toolType == 'sword' then
			if OnlyTargeting.Enabled and not hasTarget() then return false end
			bedwars.SwordController:swingSwordAtMouse()
			return true
		end
	
		return false
	end
	
	local function AutoClick()
		stopThread()
		burstcount = 0
	
		Thread = task.delay(StartDelay.Value / 1000, function()
			repeat
				-- Guarded: the block placer chain reaches several layers into the game
				-- (clientManager -> block selector -> mouse info), any of which can be missing
				-- for a frame while switching items or respawning. An error used to kill this
				-- thread outright, and since Thread stayed set, the next click could not
				-- recover either. The wait is kept outside so a repeating error cannot spin.
				local started = os.clock()
				local ok, clicked = pcall(doClick)
	
				local delay = 1 / (store.hand.toolType == 'block' and BlockCPS or CPS).GetRandomValue()
	
				if BurstMode.Enabled and ok and clicked then
					burstcount += 1
					if burstcount >= BurstLength.Value then
						burstcount = 0
						delay = BurstPause.Value / 1000
					end
				end
	
				-- Subtract what the click itself cost so the real rate matches the CPS set.
				task.wait(math.max(delay - (os.clock() - started), 0))
			until not AutoClicker.Enabled
		end)
	end
	
	local function refreshVisibility()
		if BlockCPS and BlockCPS.Object then
			BlockCPS.Object.Visible = PlaceBlocks and PlaceBlocks.Enabled or false
		end
		for _, option in {BurstLength, BurstPause} do
			if option and option.Object then
				option.Object.Visible = BurstMode and BurstMode.Enabled or false
			end
		end
	end
	
	AutoClicker = vain.Categories.Combat:CreateModule({
		Name = 'AutoClicker',
		Function = function(callback)
			if callback then
				-- Deliberately NOT gated on gameProcessed. Bedwars covers the screen with an
				-- active HUD, so the engine reports practically every click as processed and
				-- gating on it stopped the clicker from ever starting. Menus are handled by
				-- the GUI check inside doClick instead, which tests the game's own UI layer.
				AutoClicker:Clean(inputService.InputBegan:Connect(function(input)
					if input.UserInputType == Enum.UserInputType.MouseButton1 then
						AutoClick()
					end
				end))
	
				AutoClicker:Clean(inputService.InputEnded:Connect(function(input)
					if input.UserInputType == Enum.UserInputType.MouseButton1 then
						stopThread()
					end
				end))
	
				if inputService.TouchEnabled then
					pcall(function()
						AutoClicker:Clean(lplr.PlayerGui.MobileUI['2'].MouseButton1Down:Connect(AutoClick))
						AutoClicker:Clean(lplr.PlayerGui.MobileUI['2'].MouseButton1Up:Connect(stopThread))
					end)
				end
			else
				stopThread()
			end
		end,
		Tooltip = 'Hold attack button to automatically click'
	})
	CPS = AutoClicker:CreateTwoSlider({
		Name = 'CPS',
		Tooltip = 'Clicks per second, picked at random between both values',
		Min = 1,
		Max = 9,
		DefaultMin = 7,
		DefaultMax = 7
	})
	StartDelay = AutoClicker:CreateSlider({
		Name = 'Start Delay',
		Tooltip = 'Wait after pressing the button before the first automatic click',
		Min = 0,
		Max = 500,
		Default = 143,
		Suffix = function()
			return 'ms'
		end
	})
	HeldItem = AutoClicker:CreateDropdown({
		Name = 'Acts On',
		Tooltip = 'Which held items the clicker acts on',
		List = {'Sword & Blocks', 'Sword'},
		Tooltips = {
			['Sword & Blocks'] = 'Swings with swords and places with blocks',
			Sword = 'Only swings with swords'
		}
	})
	GUICheck = AutoClicker:CreateToggle({
		Name = 'GUI check',
		Tooltip = 'Stops clicking while a game menu is open',
		Default = true
	})
	OnlyTargeting = AutoClicker:CreateToggle({
		Name = 'Only While Targeting',
		Tooltip = 'Only swings when something is within sword reach'
	})
	PlaceBlocks = AutoClicker:CreateToggle({
		Name = 'Place Blocks',
		Tooltip = 'Also auto clicks while holding blocks',
		Default = true,
		Function = refreshVisibility
	})
	BlockCPS = AutoClicker:CreateTwoSlider({
		Name = 'Block CPS',
		Tooltip = 'Block places per second, picked at random between both values',
		Min = 1,
		Max = 12,
		DefaultMin = 12,
		DefaultMax = 12,
		Darker = true
	})
	BurstMode = AutoClicker:CreateToggle({
		Name = 'Burst Mode',
		Tooltip = 'Clicks in bursts with a pause between them',
		Function = refreshVisibility
	})
	BurstLength = AutoClicker:CreateSlider({
		Name = 'Burst Length',
		Tooltip = 'How many clicks each burst fires before pausing',
		Min = 2,
		Max = 30,
		Default = 8,
		Darker = true,
		Visible = false
	})
	BurstPause = AutoClicker:CreateSlider({
		Name = 'Burst Pause',
		Tooltip = 'How long to wait between bursts',
		Min = 50,
		Max = 2000,
		Default = 250,
		Darker = true,
		Visible = false,
		Suffix = function()
			return 'ms'
		end
	})
	refreshVisibility()
	
end)

run(function()
	local old
	
	vain.Categories.Combat:CreateModule({
		Name = 'NoClickDelay',
		Function = function(callback)
			if callback then
				old = bedwars.SwordController.isClickingTooFast
				bedwars.SwordController.isClickingTooFast = function(self)
					self.lastSwing = os.clock()
					return false
				end
			else
				bedwars.SwordController.isClickingTooFast = old
			end
		end,
		Tooltip = 'Remove the CPS cap'
	})
end)

run(function()
	local Value
	
	-- The slider value that produces the game's own reach. The game defines
	-- RAYCAST_SWORD_CHARACTER_DISTANCE as 4.8 * BLOCK_SIZE, and BLOCK_SIZE is 3, so vanilla
	-- reach is 14.4 - which is also what the disable path below restores. The slider adds 2
	-- on top of whatever it is set to, so 12.4 is the value that lands exactly on vanilla.
	local DEFAULTRANGE = 12.4
	
	Reach = vain.Categories.Combat:CreateModule({
		Name = 'Reach',
		Function = function(callback)
			bedwars.CombatConstant.RAYCAST_SWORD_CHARACTER_DISTANCE = callback and Value.Value + 2 or 14.4
		end,
		Tooltip = 'Extends attack reach'
	})
	Value = Reach:CreateSlider({
		Name = 'Range',
		Tooltip = 'How far this reaches, in studs',
		Min = 0,
		Max = 18,
		Default = 18,
		Function = function(val)
			if Reach.Enabled then
				bedwars.CombatConstant.RAYCAST_SWORD_CHARACTER_DISTANCE = val + 2
			end
		end,
		Suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})
	Reach:CreateButton({
		Name = 'Reset to Default',
		Tooltip = 'Sets Range back to 12.4 studs, matching the reach you have without this module',
		Function = function()
			-- final = true so the slider fires its callback even when the value already
			-- matches, which reapplies the constant if something else has changed it.
			Value:SetValue(DEFAULTRANGE, nil, true)
		end
	})
	
end)

run(function()
	local Sprint
	local old
	
	Sprint = vain.Categories.Combat:CreateModule({
		Name = 'Sprint',
		Function = function(callback)
			if callback then
				if inputService.TouchEnabled then 
					pcall(function() 
						lplr.PlayerGui.MobileUI['4'].Visible = false 
					end) 
				end
				old = bedwars.SprintController.stopSprinting
				bedwars.SprintController.stopSprinting = function(...)
					local call = old(...)
					bedwars.SprintController:startSprinting()
					return call
				end
				Sprint:Clean(entitylib.Events.LocalAdded:Connect(function() 
					task.delay(0.1, function() 
						bedwars.SprintController:stopSprinting() 
					end) 
				end))
				bedwars.SprintController:stopSprinting()
			else
				if inputService.TouchEnabled then 
					pcall(function() 
						lplr.PlayerGui.MobileUI['4'].Visible = true 
					end) 
				end
				bedwars.SprintController.stopSprinting = old
				bedwars.SprintController:stopSprinting()
			end
		end,
		Tooltip = 'Sets your sprinting to true.'
	})
end)

run(function()
	local TriggerBot
	local Targets
	local CPS
	local GUICheck
	local Range
	local SwingHeld
	local FakeSwing
	local SwingAngle
	local FakeSwingRange
	local rayParams = RaycastParams.new()
	
	local function allowedEntity(ent)
		if not Targets.Players.Enabled and ent.Player then return false end
		if not Targets.NPCs.Enabled and ent.NPC then return false end
		return true
	end
	
	local function blocked(localPos, position)
		if not Targets.Walls.Enabled then return false end
		return entitylib.Wallcheck(localPos, position, true) and true or false
	end
	
	-- getTargetInRegion is the game's own check and knows nothing about our target filters,
	-- so its result is resolved back to one of our entities and tested. If it cannot be
	-- resolved the result is accepted rather than dropped, since silently ignoring the
	-- game's own hit detection would be worse than letting an unfiltered target through.
	local function regionTargetAllowed(result, localPos)
		if not result then return false end
	
		local ok, ent = pcall(function()
			local instance = result.getInstance and result:getInstance()
			return instance and entitylib.getEntity(instance) or nil
		end)
		if not ok or not ent then return true end
	
		if not allowedEntity(ent) then return false end
		if ent.RootPart and blocked(localPos, ent.RootPart.Position) then return false end
		return true
	end
	
	-- True when any allowed entity is inside the fake swing distance and within the swing arc
	-- in front of you. Looser than the attack check below, which needs the crosshair to
	-- actually land on the entity - that gap is what the fake swing fills.
	local function targetInAngle(localPos)
		local reach = FakeSwingRange.Value
		local facing = gameCamera.CFrame.LookVector * Vector3.new(1, 0, 1)
		-- Looking straight up or down flattens to a zero vector, whose .Unit is NaN.
		if facing.Magnitude <= 0 then return false end
		facing = facing.Unit
	
		for _, ent in entitylib.List do
			if ent.Targetable and ent.RootPart and allowedEntity(ent) then
				local delta = ent.RootPart.Position - localPos
				if delta.Magnitude <= reach then
					local flat = delta * Vector3.new(1, 0, 1)
					if flat.Magnitude > 0 then
						local angle = math.acos(math.clamp(facing:Dot(flat.Unit), -1, 1))
						if angle <= (math.rad(SwingAngle.Value) / 2) and not blocked(localPos, ent.RootPart.Position) then
							return true
						end
					end
				end
			end
		end
	
		return false
	end
	
	local function refreshVisibility()
		for _, option in {SwingAngle, FakeSwingRange} do
			if option and option.Object then
				option.Object.Visible = FakeSwing and FakeSwing.Enabled or false
			end
		end
	end
	
	TriggerBot = vain.Categories.Combat:CreateModule({
		Name = 'TriggerBot',
		Function = function(callback)
			if callback then
				repeat
					local acted = false
					-- Guarded: this reads controllers and item metadata that can be missing for
					-- a frame while switching items or respawning. An error used to kill the
					-- loop outright, leaving the module switched on but permanently dead. The
					-- wait stays outside so a repeating error cannot spin the CPU.
					local ok = pcall(function()
						if GUICheck.Enabled and bedwars.AppController:isLayerOpen(bedwars.UILayers.MAIN) then return end
						if SwingHeld.Enabled and not inputService:IsMouseButtonPressed(0) then return end
						if not entitylib.isAlive or store.hand.toolType ~= 'sword' then return end
						if bedwars.DaoController and bedwars.DaoController.chargingMaid then return end
	
						local tool = store.hand.tool
						local meta = tool and bedwars.ItemMeta[tool.Name]
						-- An unrecognised item leaves meta nil, which used to throw on .sword.
						if not meta or not meta.sword then return end
	
						local attackRange = meta.sword.attackRange
						-- Range only ever narrows the item's own reach; going past it would not
						-- land hits anyway.
						local reach = math.min(attackRange or 14.4, Range.Value)
						local localPos = entitylib.character.RootPart.Position
						rayParams.FilterDescendantsInstances = {lplr.Character}
	
						local unit = lplr:GetMouse().UnitRay
						local doAttack = false
						local ray = bedwars.QueryUtil:raycast(unit.Origin, unit.Direction * 200, rayParams)
						if ray and (localPos - ray.Instance.Position).Magnitude <= reach then
							for _, ent in entitylib.List do
								if ent.Targetable and ent.RootPart and ent.Character and allowedEntity(ent)
									and ray.Instance:IsDescendantOf(ent.Character)
									and (localPos - ent.RootPart.Position).Magnitude <= reach
									and not blocked(localPos, ent.RootPart.Position) then
									doAttack = true
									break
								end
							end
						end
	
						if not doAttack then
							doAttack = regionTargetAllowed(bedwars.SwordController:getTargetInRegion(attackRange or 3.8 * 3, 0), localPos)
						end
	
						if doAttack then
							bedwars.SwordController:swingSwordAtMouse()
							acted = true
						elseif FakeSwing.Enabled and targetInAngle(localPos) then
							-- Animation only. playSwordEffect draws the swing without sending an
							-- attack, so a near miss still looks like you are swinging rather
							-- than standing still.
							bedwars.SwordController:playSwordEffect(meta, false)
							if meta.displayName and meta.displayName:find(' Scythe') then
								bedwars.ScytheController:playLocalAnimation()
							end
							acted = true
						end
					end)
	
					task.wait((ok and acted) and 1 / CPS.GetRandomValue() or 0.016)
				until not TriggerBot.Enabled
			end
		end,
		Tooltip = 'Automatically swings when hovering over a entity'
	})
	Targets = TriggerBot:CreateTargets({
		Players = true,
		NPCs = true,
		Tooltip = 'Which entities this module is allowed to target'
	})
	CPS = TriggerBot:CreateTwoSlider({
		Name = 'CPS',
		Tooltip = 'Clicks per second, picked at random between both values',
		Min = 1,
		Max = 9,
		DefaultMin = 7,
		DefaultMax = 7
	})
	Range = TriggerBot:CreateSlider({
		Name = 'Range',
		Tooltip = 'Caps how far a target can be, in studs',
		Min = 1,
		Max = 18,
		Default = 18,
		Suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})
	GUICheck = TriggerBot:CreateToggle({
		Name = 'GUI check',
		Tooltip = 'Stops swinging while a game menu is open',
		Default = true
	})
	SwingHeld = TriggerBot:CreateToggle({
		Name = 'Swing While Held',
		Tooltip = 'Only swings while you hold the left mouse button'
	})
	FakeSwing = TriggerBot:CreateToggle({
		Name = 'Fake Swing',
		Tooltip = 'Plays the swing animation when a target is in distance and angle, without attacking',
		Function = refreshVisibility
	})
	SwingAngle = TriggerBot:CreateSlider({
		Name = 'Swing Angle',
		Tooltip = 'How wide the arc in front of you counts for the fake swing',
		Min = 1,
		Max = 360,
		Default = 90,
		Darker = true,
		Visible = false
	})
	FakeSwingRange = TriggerBot:CreateSlider({
		Name = 'Fake Swing Distance',
		Tooltip = 'How far a target can be for the fake swing to play, in studs',
		Min = 1,
		Max = 30,
		Default = 14,
		Darker = true,
		Visible = false,
		Suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})
	refreshVisibility()
	
end)

run(function()
	local Velocity
	local Horizontal
	local Vertical
	local Chance
	local TargetCheck
	local rand, old = Random.new()
	
	Velocity = vain.Categories.Combat:CreateModule({
		Name = 'Velocity',
		Function = function(callback)
			if callback then
				old = bedwars.KnockbackUtil.applyKnockback
				bedwars.KnockbackUtil.applyKnockback = function(root, mass, dir, knockback, ...)
					if rand:NextNumber(0, 100) > Chance.Value then return end
					local check = (not TargetCheck.Enabled) or entitylib.EntityPosition({
						Range = 50,
						Part = 'RootPart',
						Players = true
					})
	
					if check then
						knockback = knockback or {}
						if Horizontal.Value == 0 and Vertical.Value == 0 then return end
						knockback.horizontal = (knockback.horizontal or 1) * (Horizontal.Value / 100)
						knockback.vertical = (knockback.vertical or 1) * (Vertical.Value / 100)
					end
					
					return old(root, mass, dir, knockback, ...)
				end
			else
				bedwars.KnockbackUtil.applyKnockback = old
			end
		end,
		Tooltip = 'Changes how much knockback you take\nOver 100% throws you out of reach after a hit, which breaks combos'
	})
	Horizontal = Velocity:CreateSlider({
		Name = 'Horizontal',
		-- Above 100 the knockback is amplified rather than reduced, which is how this stops
		-- a combo: the first hit throws you out of sword reach, so the follow-ups have
		-- nothing to connect with. Unlike hiding your position this is movement the server
		-- applies itself, so there is nothing for it to reject or correct.
		Tooltip = 'How much horizontal knockback you take\nUnder 100 takes less, over 100 takes more - which throws you out of reach and breaks combos',
		Min = 0,
		Max = 400,
		Default = 0,
		Suffix = '%'
	})
	Vertical = Velocity:CreateSlider({
		Name = 'Vertical',
		Tooltip = 'How much vertical knockback you take\nUnder 100 takes less, over 100 takes more',
		Min = 0,
		Max = 400,
		Default = 0,
		Suffix = '%'
	})
	Chance = Velocity:CreateSlider({
		Name = 'Chance',
		Tooltip = 'Percent chance this happens',
		Min = 0,
		Max = 100,
		Default = 100,
		Suffix = '%'
	})
	TargetCheck = Velocity:CreateToggle({Name = 'Only when targeting', Tooltip = 'Only runs while you have a target'})
end)

local AntiFallDirection
-- No module named InfiniteFly is registered anywhere, so vain.Modules.InfiniteFly
-- was nil and reading .Enabled off it threw - inside a PreSimulation connection,
-- so once per frame for as long as the fall lasted. Looking each module up by name
-- and tolerating a missing one keeps this working whether or not a given build
-- ships that module.
local function movementActive()
	for _, name in {'Fly', 'InfiniteFly', 'LongJump'} do
		local module = vain.Modules[name]
		if module and module.Enabled then return true end
	end
	return false
end
run(function()
	local AntiFall
	local Mode
	local Material
	local Color
	local rayCheck = RaycastParams.new()
	rayCheck.RespectCanCollide = true

	local function getLowGround()
		local mag = math.huge
		for _, pos in bedwars.BlockController:getStore():getAllBlockPositions() do
			pos = pos * 3
			if pos.Y < mag and not getPlacedBlock(pos + Vector3.new(0, 3, 0)) then
				mag = pos.Y
			end
		end
		return mag
	end

	AntiFall = vain.Categories.Blatant:CreateModule({
		Name = 'AntiFall',
		Function = function(callback)
			if callback then
				repeat task.wait() until store.matchState ~= 0 or (not AntiFall.Enabled)
				if not AntiFall.Enabled then return end

				local pos, debounce = getLowGround(), tick()
				if pos ~= math.huge then
					AntiFallPart = Instance.new('Part')
					AntiFallPart.Size = Vector3.new(10000, 1, 10000)
					AntiFallPart.Transparency = 1 - Color.Opacity
					AntiFallPart.Material = Enum.Material[Material.Value]
					AntiFallPart.Color = Color3.fromHSV(Color.Hue, Color.Sat, Color.Value)
					AntiFallPart.Position = Vector3.new(0, pos - 2, 0)
					AntiFallPart.CanCollide = Mode.Value == 'Collide'
					AntiFallPart.Anchored = true
					AntiFallPart.CanQuery = false
					AntiFallPart.Parent = workspace
					AntiFall:Clean(AntiFallPart)
					AntiFall:Clean(AntiFallPart.Touched:Connect(function(touched)
						if touched.Parent == lplr.Character and entitylib.isAlive and debounce < tick() then
							debounce = tick() + 0.1
							if Mode.Value == 'Normal' then
								local top = getNearGround()
								if top then
									local lastTeleport = lplr:GetAttribute('LastTeleported')
									local connection
									connection = runService.PreSimulation:Connect(function()
										if movementActive() then
											connection:Disconnect()
											AntiFallDirection = nil
											return
										end

										if entitylib.isAlive and lplr:GetAttribute('LastTeleported') == lastTeleport then
											local delta = ((top - entitylib.character.RootPart.Position) * Vector3.new(1, 0, 1))
											local root = entitylib.character.RootPart
											AntiFallDirection = delta.Unit == delta.Unit and delta.Unit or Vector3.zero
											root.Velocity *= Vector3.new(1, 0, 1)
											rayCheck.FilterDescendantsInstances = {gameCamera, lplr.Character}
											rayCheck.CollisionGroup = root.CollisionGroup

											local ray = workspace:Raycast(root.Position, AntiFallDirection, rayCheck)
											if ray then
												for _ = 1, 10 do
													local dpos = roundPos(ray.Position + ray.Normal * 1.5) + Vector3.new(0, 3, 0)
													if not getPlacedBlock(dpos) then
														-- dpos, not pos. pos is the enclosing local holding the low
														-- ground height from getLowGround - a number - so this was
														-- indexing a number and threw "attempt to index number with
														-- 'Y'" on every touch of the anti-fall part. dpos is the
														-- candidate position built on the line above and tested on
														-- the line between, which is what the height should come from.
														top = Vector3.new(top.X, dpos.Y, top.Z)
														break
													end
												end
											end

											root.CFrame += Vector3.new(0, top.Y - root.Position.Y, 0)
											if not frictionTable.Speed then
												root.AssemblyLinearVelocity = (AntiFallDirection * getSpeed()) + Vector3.new(0, root.AssemblyLinearVelocity.Y, 0)
											end

											if delta.Magnitude < 1 then
												connection:Disconnect()
												AntiFallDirection = nil
											end
										else
											connection:Disconnect()
											AntiFallDirection = nil
										end
									end)
									AntiFall:Clean(connection)
								end
							elseif Mode.Value == 'Velocity' then
								entitylib.character.RootPart.Velocity = Vector3.new(entitylib.character.RootPart.Velocity.X, 100, entitylib.character.RootPart.Velocity.Z)
							end
						end
					end))
				end
			else
				AntiFallDirection = nil
			end
		end,
		Tooltip = 'Help\'s you with your Parkinson\'s\nPrevents you from falling into the void.'
	})
	Mode = AntiFall:CreateDropdown({
		Name = 'Move Mode',
		List = {'Normal', 'Collide', 'Velocity'},
		Function = function(val)
			if AntiFallPart then
				AntiFallPart.CanCollide = val == 'Collide'
			end
		end,
	Tooltip = 'Normal - Smoothly moves you towards the nearest safe point\nVelocity - Launches you upward after touching\nCollide - Allows you to walk on the part'
	})
	local materials = {'ForceField'}
	for _, v in Enum.Material:GetEnumItems() do
		if v.Name ~= 'ForceField' then
			table.insert(materials, v.Name)
		end
	end
	Material = AntiFall:CreateDropdown({
		Name = 'Material',
		Tooltip = 'Material used for the blocks',
		List = materials,
		Function = function(val)
			if AntiFallPart then
				AntiFallPart.Material = Enum.Material[val]
			end
		end
	})
	Color = AntiFall:CreateColorSlider({
		Name = 'Color',
		Tooltip = 'Color used for this feature',
		DefaultOpacity = 0.5,
		Function = function(h, s, v, o)
			if AntiFallPart then
				AntiFallPart.Color = Color3.fromHSV(h, s, v)
				AntiFallPart.Transparency = 1 - o
			end
		end
	})
end)

run(function()
	local FastBreak
	local Time
	
	FastBreak = vain.Categories.Blatant:CreateModule({
		Name = 'FastBreak',
		Function = function(callback)
			if callback then
				repeat
					bedwars.BlockBreakController.blockBreaker:setCooldown(Time.Value)
					task.wait(0.1)
				until not FastBreak.Enabled
			else
				bedwars.BlockBreakController.blockBreaker:setCooldown(0.3)
			end
		end,
		Tooltip = 'Decreases block hit cooldown'
	})
	Time = FastBreak:CreateSlider({
		Name = 'Break speed',
		Tooltip = 'How fast blocks are broken',
		Min = 0,
		Max = 0.3,
		Default = 0.25,
		Decimal = 100,
		Suffix = 'seconds'
	})
end)

local Fly
local LongJump
run(function()
	local Value
	local VerticalValue
	local WallCheck
	local PopBalloons
	local TP
	local rayCheck = RaycastParams.new()
	rayCheck.RespectCanCollide = true
	local up, down, old = 0, 0

	Fly = vain.Categories.Blatant:CreateModule({
		Name = 'Fly',
		Function = function(callback)
			frictionTable.Fly = callback or nil
			updateVelocity()
			if callback then
				up, down, old = 0, 0, bedwars.BalloonController.deflateBalloon
				bedwars.BalloonController.deflateBalloon = function() end
				local tpTick, tpToggle, oldy = tick(), true

				if lplr.Character and (lplr.Character:GetAttribute('InflatedBalloons') or 0) == 0 and getItem('balloon') then
					bedwars.BalloonController:inflateBalloon()
				end
				Fly:Clean(vainEvents.AttributeChanged.Event:Connect(function(changed)
					if changed == 'InflatedBalloons' and (lplr.Character:GetAttribute('InflatedBalloons') or 0) == 0 and getItem('balloon') then
						bedwars.BalloonController:inflateBalloon()
					end
				end))
				Fly:Clean(runService.PreSimulation:Connect(function(dt)
					if entitylib.isAlive and not InfiniteFly.Enabled and isnetworkowner(entitylib.character.RootPart) then
						local flyAllowed = (lplr.Character:GetAttribute('InflatedBalloons') and lplr.Character:GetAttribute('InflatedBalloons') > 0) or store.matchState == 2
						local mass = (1.5 + (flyAllowed and 6 or 0) * (tick() % 0.4 < 0.2 and -1 or 1)) + ((up + down) * VerticalValue.Value)
						local root, moveDirection = entitylib.character.RootPart, entitylib.character.Humanoid.MoveDirection
						local velo = getSpeed()
						-- ZephyrSpeed overrides WalkSpeed directly, which getSpeed() cannot
						-- see, so flying would stay pinned to this slider while running was
						-- faster. Taking whichever is higher lets the kit's speed carry into
						-- flight; it falls back to the slider the moment the orbs reset.
						local target = math.max(Value.Value, store.zephyrSpeed or 0)
						local destination = (moveDirection * math.max(target - velo, 0) * dt)
						rayCheck.FilterDescendantsInstances = {lplr.Character, gameCamera, AntiFallPart}
						rayCheck.CollisionGroup = root.CollisionGroup

						if WallCheck.Enabled then
							local ray = workspace:Raycast(root.Position, destination, rayCheck)
							if ray then
								destination = ((ray.Position + ray.Normal) - root.Position)
							end
						end

						if not flyAllowed then
							if tpToggle then
								local airleft = (tick() - entitylib.character.AirTime)
								if airleft > 2 then
									if not oldy then
										local ray = workspace:Raycast(root.Position, Vector3.new(0, -1000, 0), rayCheck)
										if ray and TP.Enabled then
											tpToggle = false
											oldy = root.Position.Y
											tpTick = tick() + 0.11
											root.CFrame = CFrame.lookAlong(Vector3.new(root.Position.X, ray.Position.Y + entitylib.character.HipHeight, root.Position.Z), root.CFrame.LookVector)
										end
									end
								end
							else
								if oldy then
									if tpTick < tick() then
										local newpos = Vector3.new(root.Position.X, oldy, root.Position.Z)
										root.CFrame = CFrame.lookAlong(newpos, root.CFrame.LookVector)
										tpToggle = true
										oldy = nil
									else
										mass = 0
									end
								end
							end
						end

						root.CFrame += destination
						root.AssemblyLinearVelocity = (moveDirection * velo) + Vector3.new(0, mass, 0)
					end
				end))
				Fly:Clean(inputService.InputBegan:Connect(function(input)
					if not inputService:GetFocusedTextBox() then
						if input.KeyCode == Enum.KeyCode.Space or input.KeyCode == Enum.KeyCode.ButtonA then
							up = 1
						elseif input.KeyCode == Enum.KeyCode.LeftShift or input.KeyCode == Enum.KeyCode.ButtonL2 then
							down = -1
						end
					end
				end))
				Fly:Clean(inputService.InputEnded:Connect(function(input)
					if input.KeyCode == Enum.KeyCode.Space or input.KeyCode == Enum.KeyCode.ButtonA then
						up = 0
					elseif input.KeyCode == Enum.KeyCode.LeftShift or input.KeyCode == Enum.KeyCode.ButtonL2 then
						down = 0
					end
				end))
				if inputService.TouchEnabled then
					pcall(function()
						local jumpButton = lplr.PlayerGui.TouchGui.TouchControlFrame.JumpButton
						Fly:Clean(jumpButton:GetPropertyChangedSignal('ImageRectOffset'):Connect(function()
							up = jumpButton.ImageRectOffset.X == 146 and 1 or 0
						end))
					end)
				end
			else
				bedwars.BalloonController.deflateBalloon = old
				if PopBalloons.Enabled and entitylib.isAlive and (lplr.Character:GetAttribute('InflatedBalloons') or 0) > 0 then
					for _ = 1, 3 do
						bedwars.BalloonController:deflateBalloon()
					end
				end
			end
		end,
		ExtraText = function()
			return 'Heatseeker'
		end,
		Tooltip = 'Makes you go zoom.'
	})
	Value = Fly:CreateSlider({
		Name = 'Speed',
		Tooltip = 'How fast this runs',
		Min = 1,
		Max = 23,
		Default = 23,
		Suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})
	VerticalValue = Fly:CreateSlider({
		Name = 'Vertical Speed',
		Tooltip = 'How fast you move up and down',
		Min = 1,
		Max = 150,
		Default = 50,
		Suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})
	WallCheck = Fly:CreateToggle({
		Name = 'Wall Check',
		Tooltip = 'Ignores targets behind walls',
		Default = true
	})
	PopBalloons = Fly:CreateToggle({
		Name = 'Pop Balloons',
		Tooltip = 'Pops balloons on contact',
		Default = true
	})
	TP = Fly:CreateToggle({
		Name = 'TP Down',
		Tooltip = 'Teleports you back down afterwards',
		Default = true
	})
end)

run(function()
	local Mode
	local Expand
	local objects, set = {}
	
	local function createHitbox(ent)
		if ent.Targetable and ent.Player then
			local hitbox = Instance.new('Part')
			hitbox.Size = Vector3.new(3, 6, 3) + Vector3.one * (Expand.Value / 5)
			hitbox.Position = ent.RootPart.Position
			hitbox.CanCollide = false
			hitbox.Massless = true
			hitbox.Transparency = 1
			hitbox.Parent = ent.Character
			local weld = Instance.new('Motor6D')
			weld.Part0 = hitbox
			weld.Part1 = ent.RootPart
			weld.Parent = hitbox
			objects[ent] = hitbox
		end
	end
	
	HitBoxes = vain.Categories.Blatant:CreateModule({
		Name = 'HitBoxes',
		Function = function(callback)
			if callback then
				if Mode.Value == 'Sword' then
					-- Sword mode setconstant is broken (game changed constant type), disabled
				else
					HitBoxes:Clean(entitylib.Events.EntityAdded:Connect(createHitbox))
					HitBoxes:Clean(entitylib.Events.EntityRemoving:Connect(function(ent)
						if objects[ent] then
							objects[ent]:Destroy()
							objects[ent] = nil
						end
					end))
					for _, ent in entitylib.List do
						createHitbox(ent)
					end
				end
			else
				for _, part in objects do
					part:Destroy()
				end
				table.clear(objects)
			end
		end,
		Tooltip = 'Expands attack hitbox (Sword mode disabled - game patch)'
	})
	Mode = HitBoxes:CreateDropdown({
		Name = 'Mode',
		List = {'Sword', 'Player'},
		Function = function()
			if HitBoxes.Enabled then
				HitBoxes:Toggle()
				HitBoxes:Toggle()
			end
		end,
		Tooltip = 'Sword - Increases the range around you to hit entities\nPlayer - Increases the players hitbox'
	})
	Expand = HitBoxes:CreateSlider({
		Name = 'Expand amount',
		Tooltip = 'How much larger to make the hitbox',
		Min = 0,
		Max = 14.4,
		Default = 14.4,
		Decimal = 10,
		Function = function(val)
			if HitBoxes.Enabled and Mode.Value == 'Player' then
				for _, part in objects do
					part.Size = Vector3.new(3, 6, 3) + Vector3.one * (val / 5)
				end
			end
		end,
		Suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})
end)

run(function()
	vain.Categories.Blatant:CreateModule({
		Name = 'KeepSprint',
		Function = function(callback)
			-- Renames the key the sprint check looks up so it misses, instead of writing a
			-- hardcoded constant slot that moves whenever the game's own code shifts.
			swapConstant(bedwars.SprintController.startSprinting, callback and 'blockSprint' or 'blockSprinting', callback and 'blockSprinting' or 'blockSprint')
			bedwars.SprintController:stopSprinting()
		end,
		Tooltip = 'Lets you sprint with a speed potion.'
	})
end)

local Attacking
run(function()
	-- Resolved at hook time rather than hardcoded: these hold the index of the KnitClient
	-- upvalue inside the game's own functions, which moves whenever the game shifts a
	-- local around. Looking it up by value means a shift can't make us overwrite an
	-- unrelated upvalue, and remembering the index keeps the restore path symmetric.
	local swingknitindex, scytheknitindex
	local Killaura
	local Targets
	local Sort
	local SwingRange
	local AttackRange
	local UpdateRate
	local AngleSlider
	local MaxTargets
	local Mouse
	local Swing
	local GUI
	local BoxSwingColor
	local BoxAttackColor
	local ParticleTexture
	local ParticleColor1
	local ParticleColor2
	local ParticleSize
	local Face
	local Animation
	local AnimationMode
	local AnimationSpeed
	local AnimationTween
	local Limit
	local LegitAura
	local HitDelay
	local Particles, Boxes = {}, {}
	-- entity -> tick() at which it may be attacked again
	local AttackTimes = {}
	local anims, AnimDelay, AnimTween, armC0, armWrist = vain.Libraries.auraanims, tick()
	local AttackStub = {FireServer = function() end}
	local AttackRemote = AttackStub
	-- Falls back to the no-op stub if the remote cannot be resolved, so a failure here
	-- degrades Killaura to "does nothing" instead of throwing on every attack. Resolving
	-- only once at load meant a single early failure - injecting before the remotes are
	-- registered - left every later attack silently going nowhere for the rest of the
	-- session, so this runs again on enable while the stub is still in place.
	-- The remote name is scraped out of the game's own bytecode in base.lua, so a
	-- game update can hand back a name that is wrong but not empty, and Get then
	-- fails without base.lua's "failed to grab remote" warning firing. Landing on
	-- the stub is completely silent: target boxes, particles and the swing effect
	-- all still play because none of them touch the remote, and only the damage is
	-- missing. That is indistinguishable from a reach or validation problem from
	-- the outside, so say so out loud instead of failing quietly.
	local warned = false
	local function resolveAttackRemote()
		if AttackRemote ~= AttackStub then return end

		local function fail(reason)
			if warned then return end
			warned = true
			notif('Killaura', 'No damage will be dealt - '..reason, 10, 'alert')
		end

		if not remotes.AttackEntity or remotes.AttackEntity == '' then
			fail('the attack remote name could not be read from the game')
			return
		end

		local ok, remote = pcall(function()
			return bedwars.Client:Get(remotes.AttackEntity).instance
		end)
		if ok and remote then
			AttackRemote = remote
			warned = false
			return
		end

		fail('the attack remote ('..tostring(remotes.AttackEntity)..') could not be resolved')
	end
	task.spawn(resolveAttackRemote)

	-- store.tools is only rebuilt when the inventory items table changes identity, so
	-- after a respawn the cached entry can still hold the Tool instance from the
	-- previous life. Every visual in Killaura runs off client state and keeps playing
	-- normally, but the server drops an attack whose weapon is a destroyed instance -
	-- target box, particles and swing all correct, no damage, and it stays that way
	-- until something happens to rebuild the items table. store.inventory is refreshed
	-- on every inventory change, so re-resolve a live tool from there. Falling back to
	-- the original item on failure keeps this strictly no worse than not checking.
	local function liveItem(item, isHand)
		if not item then return item end
		if item.tool and item.tool.Parent then return item end

		local inv = store.inventory and store.inventory.inventory
		if not inv then return item end

		if isHand then
			local hand = inv.hand
			if hand and hand.tool and hand.tool.Parent then
				return {tool = hand.tool, amount = hand.amount or 0, toolType = item.toolType}
			end
			return item
		end

		for _, v in inv.items do
			if v.itemType == item.itemType and v.tool and v.tool.Parent then
				store.tools.sword = v
				return v
			end
		end
		return item
	end

	local function getAttackData()
		if Mouse.Enabled then
			if not inputService:IsMouseButtonPressed(0) then return false end
		end

		if GUI.Enabled then
			if bedwars.AppController:isLayerOpen(bedwars.UILayers.MAIN) then return false end
		end

		local sword = Limit.Enabled and store.hand or store.tools.sword
		if not sword or not sword.tool then return false end
		sword = liveItem(sword, Limit.Enabled)

		-- store.hand carries no itemType, so the tool instance name is the fallback key.
		-- An item the metadata does not know about leaves meta nil, and the attack path
		-- reads meta.sword.attackSpeed and meta.displayName straight off it - that threw,
		-- and because it throws on every pass Killaura sat enabled doing nothing at all.
		local meta = bedwars.ItemMeta[sword.itemType or sword.tool.Name]
		if not meta or not meta.sword then return false end

		if Limit.Enabled then
			if store.hand.toolType ~= 'sword' or (bedwars.DaoController and bedwars.DaoController.chargingMaid) then return false end
		end

		if LegitAura.Enabled then
			if (tick() - bedwars.SwordController.lastSwing) > 0.2 then return false end
		end

		return sword, meta
	end

	Killaura = vain.Categories.Blatant:CreateModule({
		Name = 'Killaura',
		Function = function(callback)
			if callback then
				task.spawn(resolveAttackRemote)

				if inputService.TouchEnabled then
					pcall(function()
						lplr.PlayerGui.MobileUI['2'].Visible = Limit.Enabled
					end)
				end

				pcall(function()
					if Animation.Enabled and not (identifyexecutor and table.find({'Argon', 'Delta'}, ({identifyexecutor()})[1])) then
						local fake = {
							Controllers = {
								ViewmodelController = {
									isVisible = function()
										return not Attacking
									end,
									playAnimation = function(...)
										if not Attacking then
											bedwars.ViewmodelController:playAnimation(select(2, ...))
										end
									end
								}
							}
						}
						local swingfunc = oldSwing or bedwars.SwordController.playSwordEffect
						swingknitindex = findUpvalue(swingfunc, bedwars.Knit)
						if swingknitindex then
							debug.setupvalue(swingfunc, swingknitindex, fake)
						end
						scytheknitindex = findUpvalue(bedwars.ScytheController.playLocalAnimation, bedwars.Knit)
						if scytheknitindex then
							debug.setupvalue(bedwars.ScytheController.playLocalAnimation, scytheknitindex, fake)
						end

						task.spawn(function()
						local started = false
						repeat
							-- Guarded: this touches gameCamera.Viewmodel, which does not exist while
							-- respawning or with an empty hand. An error here used to kill the
							-- animation thread for the rest of the session.
							local ok = pcall(function()
								if Attacking then
									-- The viewmodel is rebuilt whenever you switch items, so the wrist the
									-- resting C0 was taken from can be a destroyed instance by now. Caching it
									-- once left the animation offsetting from a stale base, and the restore
									-- below putting the arm back to the wrong place.
									local wrist = gameCamera.Viewmodel.RightHand.RightWrist
									if armWrist ~= wrist then
										armWrist, armC0 = wrist, wrist.C0
									end
									local first = not started
									started = true

									if AnimationMode.Value == 'Random' then
										anims.Random = {{CFrame = CFrame.Angles(math.rad(math.random(1, 360)), math.rad(math.random(1, 360)), math.rad(math.random(1, 360))), Time = 0.12}}
									end

									for _, v in anims[AnimationMode.Value] do
										AnimTween = tweenService:Create(wrist, TweenInfo.new(first and (AnimationTween.Enabled and 0.001 or 0.1) or v.Time / AnimationSpeed.Value, Enum.EasingStyle.Linear), {
											C0 = armC0 * v.CFrame
										})
										AnimTween:Play()
										AnimTween.Completed:Wait()
										first = false
										if (not Killaura.Enabled) or (not Attacking) then break end
									end
								elseif started then
									started = false
									AnimTween = tweenService:Create(armWrist, TweenInfo.new(AnimationTween.Enabled and 0.001 or 0.3, Enum.EasingStyle.Exponential), {
										C0 = armC0
									})
									AnimTween:Play()
								end
							end)

							-- Always yield on failure, otherwise a repeating error spins the CPU:
							-- the normal path only skips the wait because the tween Wait() above
							-- provides the yield, and that never ran if we errored.
							if (not ok) or (not started) then
								started = started and ok
								task.wait(1 / UpdateRate.Value)
							end
						until (not Killaura.Enabled) or (not Animation.Enabled)
						end)
					end
				end)

				repeat
					local attacked = {}
					-- The whole pass is wrapped because this is a long-lived loop that
					-- touches game state which can vanish mid-iteration (entities dying,
					-- item metadata changing as you switch weapons). An uncaught error
					-- here used to kill the coroutine outright, leaving Killaura toggled
					-- on but permanently dead. The wait is deliberately kept outside the
					-- pcall so a repeating error cannot turn into a busy spin.
					local ok = pcall(function()
						local sword, meta = getAttackData()
						Attacking = false
						store.KillauraTarget = nil
						if sword then
							-- Swing range and attack range are independent: swing range is how
							-- close something must be to make you swing, attack range is how close
							-- it must be to actually be hit. The query therefore has to cover
							-- whichever is larger, or setting attack range above swing range would
							-- silently clamp it - those targets would never be selected at all.
							-- Hitting is still gated strictly on attack range further down.
							--
							-- Deliberately unlimited: AllPosition applies Limit *after* sorting,
							-- so passing MaxTargets here truncates the list before Killaura has
							-- had a chance to check attack range or the angle cone. A target that
							-- sits inside swing range but outside attack range - or behind you -
							-- would eat the only slot and starve a closer, hittable one, which
							-- looked like Killaura swinging endlessly for no damage. MaxTargets is
							-- about how many entities to *hit*, so it is enforced below instead.
							local plrs = entitylib.AllPosition({
								Range = math.max(SwingRange.Value, AttackRange.Value),
								Wallcheck = Targets.Walls.Enabled or nil,
								Part = 'RootPart',
								Players = Targets.Players.Enabled,
								NPCs = Targets.NPCs.Enabled,
								Preference = Targets.Preference.Value,
								Sort = sortmethods[Sort.Value]
							})

							if #plrs > 0 then
								switchItem(sword.tool, 0)
								local hits = 0
								local selfpos = entitylib.character.RootPart.Position
								local localfacing = entitylib.character.RootPart.CFrame.LookVector * Vector3.new(1, 0, 1)

								for _, v in plrs do
									-- Entities can be torn down between selection and use (NPCs
									-- despawning), so re-check rather than indexing blind.
									if not v.Character or not v.Character.Parent then continue end

									-- entitylib caches RootPart once when the entity is created and
									-- never refreshes it - the code that would is commented out in
									-- entity.lua. When a character's root part gets swapped mid-round
									-- the cached one is left destroyed, and a destroyed part keeps
									-- reporting its last Position, so the target looks frozen there:
									-- still selected, still swung at, but every hit is aimed at a
									-- dead instance and the server drops it. That is why it stops
									-- landing on one specific person and never recovers for them.
									-- Humanoid.RootPart tracks the live part, so re-resolve from it
									-- and repair the shared record for every other module too.
									local root = v.RootPart
									if not root or root.Parent ~= v.Character then
										root = v.Humanoid and v.Humanoid.RootPart
										if not root then continue end
										v.RootPart, v.HumanoidRootPart = root, root
									end

									local delta = (root.Position - selfpos)
									-- Flatten first, then reject a zero-length horizontal delta.
									-- A target directly overhead - a diamond guardian sitting on
									-- top of the generator you are standing under - makes this a
									-- zero vector, whose .Unit is NaN. Every comparison against
									-- NaN is false, so the angle check silently passed and the
									-- NaN flowed into the attack maths below.
									local flat = delta * Vector3.new(1, 0, 1)
									if flat.Magnitude <= 0 then continue end
									local angle = math.acos(math.clamp(localfacing:Dot(flat.Unit), -1, 1))
									if angle > (math.rad(AngleSlider.Value) / 2) then continue end

									local dist = delta.Magnitude
									local inrange = dist <= AttackRange.Value
									local inswing = dist <= SwingRange.Value
									-- Beyond both ranges this target is of no interest. It can only
									-- show up here because the query covers whichever range is larger.
									if not (inrange or inswing) then continue end

									if inswing then
										table.insert(attacked, {
											Entity = v,
											Check = inrange and BoxAttackColor or BoxSwingColor
										})
										targetinfo.Targets[v] = tick() + 1
									end

									if inswing and not Attacking then
										Attacking = true
										store.KillauraTarget = v
										if not Swing.Enabled and AnimDelay < tick() and not LegitAura.Enabled then
											AnimDelay = tick() + (meta.sword.respectAttackSpeedForEffects and meta.sword.attackSpeed or 0.11)
											bedwars.SwordController:playSwordEffect(meta, false)
											if meta.displayName and meta.displayName:find(' Scythe') then
												bedwars.ScytheController:playLocalAnimation()
											end

											if vain.ThreadFix then
												setthreadidentity(8)
											end
										end
									end

									-- Out-of-reach targets still get a box and a swing, they just do
									-- not consume one of the MaxTargets attack slots.
									if not inrange then continue end
									if hits >= MaxTargets.Value then continue end

									-- AntiMelee hides the part the server tracks you by, and an
									-- attack sent while it is hidden is rejected - the server checks
									-- your claimed position against a copy of you that is under the
									-- map. It publishes when the part is briefly back in place, so
									-- swings wait for that window rather than being thrown away.
									-- Nil means AntiMelee is not hiding anything and this does not
									-- apply. The wait costs nothing: its cycle is shorter than a
									-- sword's attack speed, so a window always comes round first.
									if store.antiMeleeParked == false then
										-- Ask for one. AntiMelee keeps the root buried by default and
										-- surfaces it because this asked, so a swing is delayed only by
										-- the time that takes rather than waiting for a window on a
										-- clock that its own attack cooldown drifts against.
										store.antiMeleeWantAttack = tick()
										continue
									end

									-- The loop used to fire on every pass, which with one target in
									-- range meant an attack every 0.02s - fifty a second against a
									-- sword that swings about once a second. Hits arriving faster
									-- than the weapon allows are dropped server side, so the swing
									-- and the target box played while nothing landed. Pace attacks
									-- per target: the weapon's own attack speed by default, or the
									-- Hit delay slider when it is set above zero.
									if (AttackTimes[v] or 0) > tick() then continue end
									AttackTimes[v] = tick() + (HitDelay.Value > 0 and HitDelay.Value or (meta.sword.attackSpeed or 0.5))
									-- The swing this asked for is going out, so release AntiMelee to
									-- bury the root again rather than leaving it surfaced.
									store.antiMeleeWantAttack = nil

									-- PrimaryPart is not guaranteed to be set on a character model.
									-- Bailing out when it was nil skipped the attack entirely while
									-- the box and swing above had already played, which is exactly
									-- what "swings but deals no damage" looked like. RootPart is the
									-- part the target was selected by, so it is the right fallback.
									local actualRoot = v.Character.PrimaryPart or root
									if actualRoot then
										-- Aim and reach maths must both come from actualRoot. dir used
										-- to be measured to PrimaryPart while the offset below used
										-- delta, which was measured to RootPart - whenever those were
										-- different parts the spoofed camera position did not land the
										-- claimed 14.399 studs from the target, so the server saw an
										-- out-of-reach hit and dropped it.
										local aim = actualRoot.Position - selfpos
										local aimdist = aim.Magnitude
										if aimdist <= 0 then continue end
										hits += 1

										local dir = aim.Unit
										local pos = selfpos + dir * math.max(aimdist - 14.399, 0)
										bedwars.SwordController.lastAttack = workspace:GetServerTimeNow()
										store.attackReach = (aimdist * 100) // 1 / 100
										store.attackReachUpdate = tick() + 1

										AttackRemote:FireServer({
											weapon = sword.tool,
											chargedAttack = {chargeRatio = 0},
											entityInstance = v.Character,
											validate = {
												raycast = {
													cameraPosition = {value = pos},
													cursorDirection = {value = dir}
												},
												targetPosition = {value = actualRoot.Position},
												selfPosition = {value = pos}
											}
										})
									end
								end
							end
						end

						for i, v in Boxes do
							v.Adornee = attacked[i] and attacked[i].Entity.RootPart or nil
							if v.Adornee then
								v.Color3 = Color3.fromHSV(attacked[i].Check.Hue, attacked[i].Check.Sat, attacked[i].Check.Value)
								v.Transparency = 1 - attacked[i].Check.Opacity
							end
						end

						-- RootPart is read through a local rather than indexed straight off the
						-- entity: a target that leaves range and comes back (NPCs especially,
						-- since they despawn and respawn) can have its RootPart torn down
						-- between being picked above and being drawn here. Indexing .Position
						-- on that nil threw, and since this whole thing is a bare repeat loop
						-- with no error handling, the throw killed the loop outright and
						-- Killaura stayed dead until you rejoined.
						for i, v in Particles do
							local root = attacked[i] and attacked[i].Entity.RootPart
							v.Position = root and root.Position or Vector3.new(9e9, 9e9, 9e9)
							v.Parent = root and gameCamera or nil
						end

						local faceroot = attacked[1] and attacked[1].Entity.RootPart
						if Face.Enabled and faceroot and entitylib.isAlive then
							local vec = faceroot.Position * Vector3.new(1, 0, 1)
							entitylib.character.RootPart.CFrame = CFrame.lookAt(entitylib.character.RootPart.Position, Vector3.new(vec.X, entitylib.character.RootPart.Position.Y + 0.001, vec.Z))
						end

					end)

					if not ok then
						-- Drop out of the attacking state so the animation thread and the
						-- viewmodel do not stay stuck mid-swing after a failed pass.
						Attacking = false
						store.KillauraTarget = nil
					end
					task.wait(#attacked > 0 and #attacked * 0.02 or 1 / UpdateRate.Value)
				until not Killaura.Enabled
			else
				store.KillauraTarget = nil
				table.clear(AttackTimes)
				for _, v in Boxes do
					v.Adornee = nil
				end
				for _, v in Particles do
					v.Parent = nil
				end
				if inputService.TouchEnabled then
					pcall(function()
						lplr.PlayerGui.MobileUI['2'].Visible = true
					end)
				end
				-- Restores run under pcall so that a failure to put one upvalue back cannot
				-- skip the ones after it - leaving the game's functions permanently holding
				-- our fake table would break swords even with Killaura off.
				if swingknitindex then
					pcall(debug.setupvalue, oldSwing or bedwars.SwordController.playSwordEffect, swingknitindex, bedwars.Knit)
					swingknitindex = nil
				end
				if scytheknitindex then
					pcall(debug.setupvalue, bedwars.ScytheController.playLocalAnimation, scytheknitindex, bedwars.Knit)
					scytheknitindex = nil
				end
				Attacking = false
				if armC0 and armWrist then
					-- The viewmodel is gone while dead or respawning, which is exactly when
					-- someone is likely to toggle this off.
					pcall(function()
						AnimTween = tweenService:Create(armWrist, TweenInfo.new(AnimationTween.Enabled and 0.001 or 0.3, Enum.EasingStyle.Exponential), {
							C0 = armC0
						})
						AnimTween:Play()
					end)
				end
			end
		end,
		Tooltip = 'Attack players around you\nwithout aiming at them.'
	})
	Targets = Killaura:CreateTargets({
		Players = true,
		NPCs = true,
		Tooltip = 'Which entities this module is allowed to target'
	})
	-- Damage/Distance stay pinned to the front (Damage is the default), the rest are
	-- sorted so the dropdown order stays stable - iterating sortmethods directly is
	-- hash order, which reshuffles the list between injections.
	local methods, extramethods = {'Damage', 'Distance'}, {}
	for i in sortmethods do
		if not table.find(methods, i) then
			table.insert(extramethods, i)
		end
	end
	table.sort(extramethods)
	for _, v in extramethods do
		table.insert(methods, v)
	end
	SwingRange = Killaura:CreateSlider({
		Name = 'Swing range',
		Tooltip = 'How far your swing reaches, in studs',
		Min = 1,
		Max = 28,
		Default = 28,
		Suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})
	AttackRange = Killaura:CreateSlider({
		Name = 'Attack range',
		Tooltip = 'How far a target can be and still be hit',
		Min = 1,
		Max = 20,
		Default = 20,
		Suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})
	AngleSlider = Killaura:CreateSlider({
		Name = 'Max angle',
		Tooltip = 'Widest angle from the way your character faces a target may be at',
		Min = 1,
		Max = 360,
		Default = 360
	})
	UpdateRate = Killaura:CreateSlider({
		Name = 'Update rate',
		Tooltip = 'How many times per second targets are re-checked\nLower costs less performance',
		Min = 1,
		Max = 120,
		Default = 60,
		Suffix = 'hz'
	})
	MaxTargets = Killaura:CreateSlider({
		Name = 'Max targets',
		Tooltip = 'How many targets to hit per swing',
		Min = 1,
		Max = 5,
		Default = 5
	})
	Sort = Killaura:CreateDropdown({
		Name = 'Target Mode',
		Tooltip = 'How targets are ranked when several are valid at once',
		List = methods,
		Tooltips = sortmethodtips
	})
	Mouse = Killaura:CreateToggle({Name = 'Require mouse down', Tooltip = 'Only acts while you hold left click'})
	Swing = Killaura:CreateToggle({Name = 'No Swing', Tooltip = 'Attacks without playing the swing animation'})
	GUI = Killaura:CreateToggle({Name = 'GUI check', Tooltip = 'Stops acting while a game menu is open'})
	Killaura:CreateToggle({
		Name = 'Show target',
		Tooltip = 'Draws a box around the target you are attacking',
		Function = function(callback)
			BoxSwingColor.Object.Visible = callback
			BoxAttackColor.Object.Visible = callback
			if callback then
				for i = 1, 10 do
					local box = Instance.new('BoxHandleAdornment')
					box.Adornee = nil
					box.AlwaysOnTop = true
					box.Size = Vector3.new(3, 5, 3)
					box.CFrame = CFrame.new(0, -0.5, 0)
					box.ZIndex = 0
					box.Parent = vain.gui
					Boxes[i] = box
				end
			else
				for _, v in Boxes do
					v:Destroy()
				end
				table.clear(Boxes)
			end
		end
	})
	BoxSwingColor = Killaura:CreateColorSlider({
		Name = 'Target Color',
		Tooltip = 'Box color while a target is in swing range',
		Darker = true,
		DefaultHue = 0.6,
		DefaultOpacity = 0.5,
		Visible = false
	})
	BoxAttackColor = Killaura:CreateColorSlider({
		Name = 'Attack Color',
		Tooltip = 'Box color while a target is being attacked',
		Darker = true,
		DefaultOpacity = 0.5,
		Visible = false
	})
	Killaura:CreateToggle({
		Name = 'Target particles',
		Tooltip = 'Spawns particles on the target you hit',
		Function = function(callback)
			ParticleTexture.Object.Visible = callback
			ParticleColor1.Object.Visible = callback
			ParticleColor2.Object.Visible = callback
			ParticleSize.Object.Visible = callback
			if callback then
				for i = 1, 10 do
					local part = Instance.new('Part')
					part.Size = Vector3.new(2, 4, 2)
					part.Anchored = true
					part.CanCollide = false
					part.Transparency = 1
					part.CanQuery = false
					part.Parent = Killaura.Enabled and gameCamera or nil
					local particles = Instance.new('ParticleEmitter')
					particles.Brightness = 1.5
					particles.Size = NumberSequence.new(ParticleSize.Value)
					particles.Shape = Enum.ParticleEmitterShape.Sphere
					particles.Texture = ParticleTexture.Value
					particles.Transparency = NumberSequence.new(0)
					particles.Lifetime = NumberRange.new(0.4)
					particles.Speed = NumberRange.new(16)
					particles.Rate = 128
					particles.Drag = 16
					particles.ShapePartial = 1
					particles.Color = ColorSequence.new({
						ColorSequenceKeypoint.new(0, Color3.fromHSV(ParticleColor1.Hue, ParticleColor1.Sat, ParticleColor1.Value)),
						ColorSequenceKeypoint.new(1, Color3.fromHSV(ParticleColor2.Hue, ParticleColor2.Sat, ParticleColor2.Value))
					})
					particles.Parent = part
					Particles[i] = part
				end
			else
				for _, v in Particles do
					v:Destroy()
				end
				table.clear(Particles)
			end
		end
	})
	ParticleTexture = Killaura:CreateTextBox({
		Name = 'Texture',
		Tooltip = 'Particle image asset id',
		Default = 'rbxassetid://14736249347',
		Function = function()
			for _, v in Particles do
				v.ParticleEmitter.Texture = ParticleTexture.Value
			end
		end,
		Darker = true,
		Visible = false
	})
	ParticleColor1 = Killaura:CreateColorSlider({
		Name = 'Color Begin',
		Tooltip = 'Particle color when it spawns',
		Function = function(hue, sat, val)
			for _, v in Particles do
				v.ParticleEmitter.Color = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromHSV(hue, sat, val)),
					ColorSequenceKeypoint.new(1, Color3.fromHSV(ParticleColor2.Hue, ParticleColor2.Sat, ParticleColor2.Value))
				})
			end
		end,
		Darker = true,
		Visible = false
	})
	ParticleColor2 = Killaura:CreateColorSlider({
		Name = 'Color End',
		Tooltip = 'Particle color as it fades out',
		Function = function(hue, sat, val)
			for _, v in Particles do
				v.ParticleEmitter.Color = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromHSV(ParticleColor1.Hue, ParticleColor1.Sat, ParticleColor1.Value)),
					ColorSequenceKeypoint.new(1, Color3.fromHSV(hue, sat, val))
				})
			end
		end,
		Darker = true,
		Visible = false
	})
	ParticleSize = Killaura:CreateSlider({
		Name = 'Size',
		Tooltip = 'Size of the effect',
		Min = 0,
		Max = 1,
		Default = 0.2,
		Decimal = 100,
		Function = function(val)
			for _, v in Particles do
				v.ParticleEmitter.Size = NumberSequence.new(val)
			end
		end,
		Darker = true,
		Visible = false
	})
	Face = Killaura:CreateToggle({Name = 'Face target', Tooltip = 'Turns your character toward the target'})
	Animation = Killaura:CreateToggle({
		Name = 'Custom Animation',
		Tooltip = '[DISABLED - causes errors]',
		Function = function(callback)
		end
	})
	local animnames = {}
	for i in anims do
		table.insert(animnames, i)
	end
	AnimationMode = Killaura:CreateDropdown({
		Name = 'Animation Mode',
		Tooltip = 'Which custom swing animation to play',
		List = animnames,
		Darker = true,
		Visible = false
	})
	AnimationSpeed = Killaura:CreateSlider({
		Name = 'Animation Speed',
		Tooltip = 'How fast the custom animation plays',
		Min = 0,
		Max = 2,
		Default = 1,
		Decimal = 10,
		Darker = true,
		Visible = false
	})
	AnimationTween = Killaura:CreateToggle({
		Name = 'No Tween',
		Tooltip = 'Snaps the animation instead of smoothing it',
		Darker = true,
		Visible = false
	})
	Limit = Killaura:CreateToggle({
		Name = 'Limit to items',
		Function = function(callback)
			if inputService.TouchEnabled and Killaura.Enabled then
				pcall(function()
					lplr.PlayerGui.MobileUI['2'].Visible = callback
				end)
			end
		end,
		Tooltip = 'Only attacks when the sword is held'
	})
	HitDelay = Killaura:CreateSlider({
		Name = 'Hit delay',
		Tooltip = 'How long to wait between attacks on the same target\nThe server drops hits that arrive faster than the weapon allows, so very low values can stop damage entirely\n0 uses the weapon\'s own attack speed',
		Min = 0,
		Max = 2,
		Default = 0,
		Decimal = 100,
		Suffix = function(val)
			return val == 0 and '(weapon speed)' or 'seconds'
		end
	})
	LegitAura = Killaura:CreateToggle({
		Name = 'Swing only',
		Tooltip = 'Only attacks while swinging manually'
	})
end)

run(function()
	local Value
	local CameraDir
	local start
	local JumpTick, JumpSpeed, Direction = tick(), 0
	local projectileRemote = {InvokeServer = function() end}
	task.spawn(function()
		projectileRemote = bedwars.Client:Get(remotes.FireProjectile).instance
	end)
	
	local function launchProjectile(item, pos, proj, speed, dir)
		if not pos then return end
	
		pos = pos - dir * 0.1
		local shootPosition = (CFrame.lookAlong(pos, Vector3.new(0, -speed, 0)) * CFrame.new(Vector3.new(-bedwars.BowConstantsTable.RelX, -bedwars.BowConstantsTable.RelY, -bedwars.BowConstantsTable.RelZ)))
		switchItem(item.tool, 0)
		task.wait(0.1)
		bedwars.ProjectileController:createLocalProjectile(bedwars.ProjectileMeta[proj], proj, proj, shootPosition.Position, '', shootPosition.LookVector * speed, {drawDurationSeconds = 1})
		if projectileRemote:InvokeServer(item.tool, proj, proj, shootPosition.Position, pos, shootPosition.LookVector * speed, httpService:GenerateGUID(true), {drawDurationSeconds = 1}, workspace:GetServerTimeNow() - 0.045) then
			local shoot = bedwars.ItemMeta[item.itemType].projectileSource.launchSound
			shoot = shoot and shoot[math.random(1, #shoot)] or nil
			if shoot then
				bedwars.SoundManager:playSound(shoot)
			end
		end
	end
	
	local LongJumpMethods = {
		cannon = function(_, pos, dir)
			pos = pos - Vector3.new(0, (entitylib.character.HipHeight + (entitylib.character.RootPart.Size.Y / 2)) - 3, 0)
			local rounded = Vector3.new(math.round(pos.X / 3) * 3, math.round(pos.Y / 3) * 3, math.round(pos.Z / 3) * 3)
			bedwars.placeBlock(rounded, 'cannon', false)
	
			task.delay(0, function()
				local block, blockpos = getPlacedBlock(rounded)
				if block and block.Name == 'cannon' and (entitylib.character.RootPart.Position - block.Position).Magnitude < 20 then
					local breaktype = bedwars.ItemMeta[block.Name].block.breakType
					local tool = store.tools[breaktype]
					if tool then
						switchItem(tool.tool)
					end
	
					-- Named rather than scraped. The scraper works a remote out by finding
					-- 'Client' among a function's constants and taking the next one, which for
					-- this call lands on 'Get' - so the aim went to a remote that does not
					-- exist, and the scrape failing is what raised the notification about it.
					bedwars.Client:Get('AimCannon'):SendToServer({
						cannonBlockPos = blockpos,
						lookVector = dir
					})
	
					local broken = 0.1
					if bedwars.BlockController:calculateBlockDamage(lplr, {blockPosition = blockpos}) < block:GetAttribute('Health') then
						broken = 0.4
						bedwars.breakBlock(block, true, true)
					end
	
					task.delay(broken, function()
						for _ = 1, 3 do
							local call = bedwars.Client:Get(remotes.CannonLaunch):CallServer({cannonBlockPos = blockpos})
							if call then
								bedwars.breakBlock(block, true, true)
								JumpSpeed = 5.25 * Value.Value
								JumpTick = tick() + 2.3
								Direction = Vector3.new(dir.X, 0, dir.Z).Unit
								break
							end
							task.wait(0.1)
						end
					end)
				end
			end)
		end,
		cat = function(_, _, dir)
			LongJump:Clean(vainEvents.CatPounce.Event:Connect(function()
				JumpSpeed = 4 * Value.Value
				JumpTick = tick() + 2.5
				Direction = Vector3.new(dir.X, 0, dir.Z).Unit
				entitylib.character.RootPart.Velocity = Vector3.zero
			end))
	
			if not bedwars.AbilityController:canUseAbility('CAT_POUNCE') then
				repeat task.wait() until bedwars.AbilityController:canUseAbility('CAT_POUNCE') or not LongJump.Enabled
			end
	
			if bedwars.AbilityController:canUseAbility('CAT_POUNCE') and LongJump.Enabled then
				bedwars.AbilityController:useAbility('CAT_POUNCE')
			end
		end,
		fireball = function(item, pos, dir)
			launchProjectile(item, pos, 'fireball', 60, dir)
		end,
		grappling_hook = function(item, pos, dir)
			launchProjectile(item, pos, 'grappling_hook_projectile', 140, dir)
		end,
		jade_hammer = function(item, _, dir)
			if not bedwars.AbilityController:canUseAbility(item.itemType..'_jump') then
				repeat task.wait() until bedwars.AbilityController:canUseAbility(item.itemType..'_jump') or not LongJump.Enabled
			end
	
			if bedwars.AbilityController:canUseAbility(item.itemType..'_jump') and LongJump.Enabled then
				bedwars.AbilityController:useAbility(item.itemType..'_jump')
				JumpSpeed = 1.4 * Value.Value
				JumpTick = tick() + 2.5
				Direction = Vector3.new(dir.X, 0, dir.Z).Unit
			end
		end,
		tnt = function(item, pos, dir)
			pos = pos - Vector3.new(0, (entitylib.character.HipHeight + (entitylib.character.RootPart.Size.Y / 2)) - 3, 0)
			local rounded = Vector3.new(math.round(pos.X / 3) * 3, math.round(pos.Y / 3) * 3, math.round(pos.Z / 3) * 3)
			start = Vector3.new(rounded.X, start.Y, rounded.Z) + (dir * (item.itemType == 'pirate_gunpowder_barrel' and 2.6 or 0.2))
			bedwars.placeBlock(rounded, item.itemType, false)
		end,
		wood_dao = function(item, pos, dir)
			if (lplr.Character:GetAttribute('CanDashNext') or 0) > workspace:GetServerTimeNow() or not bedwars.AbilityController:canUseAbility('dash') then
				repeat task.wait() until (lplr.Character:GetAttribute('CanDashNext') or 0) < workspace:GetServerTimeNow() and bedwars.AbilityController:canUseAbility('dash') or not LongJump.Enabled
			end
	
			if LongJump.Enabled then
				bedwars.SwordController.lastAttack = workspace:GetServerTimeNow()
				switchItem(item.tool, 0.1)
				replicatedStorage['events-@easy-games/game-core:shared/game-core-networking@getEvents.Events'].useAbility:FireServer('dash', {
					direction = dir,
					origin = pos,
					weapon = item.itemType
				})
				JumpSpeed = 4.5 * Value.Value
				JumpTick = tick() + 2.4
				Direction = Vector3.new(dir.X, 0, dir.Z).Unit
			end
		end
	}
	for _, v in {'stone_dao', 'iron_dao', 'diamond_dao', 'emerald_dao'} do
		LongJumpMethods[v] = LongJumpMethods.wood_dao
	end
	LongJumpMethods.void_axe = LongJumpMethods.jade_hammer
	LongJumpMethods.siege_tnt = LongJumpMethods.tnt
	LongJumpMethods.pirate_gunpowder_barrel = LongJumpMethods.tnt
	
	LongJump = vain.Categories.Blatant:CreateModule({
		Name = 'LongJump',
		Function = function(callback)
			frictionTable.LongJump = callback or nil
			updateVelocity()
			if callback then
				LongJump:Clean(vainEvents.EntityDamageEvent.Event:Connect(function(damageTable)
					if damageTable.entityInstance == lplr.Character and damageTable.fromEntity == lplr.Character and (not damageTable.knockbackMultiplier or not damageTable.knockbackMultiplier.disabled) then
						local knockbackBoost = bedwars.KnockbackUtil.calculateKnockbackVelocity(Vector3.one, 1, {
							vertical = 0,
							horizontal = (damageTable.knockbackMultiplier and damageTable.knockbackMultiplier.horizontal or 1)
						}).Magnitude * 1.1
	
						if knockbackBoost >= JumpSpeed then
							local pos = damageTable.fromPosition and Vector3.new(damageTable.fromPosition.X, damageTable.fromPosition.Y, damageTable.fromPosition.Z) or damageTable.fromEntity and damageTable.fromEntity.PrimaryPart.Position
							if not pos then return end
							local vec = (entitylib.character.RootPart.Position - pos)
							JumpSpeed = knockbackBoost
							JumpTick = tick() + 2.5
							Direction = Vector3.new(vec.X, 0, vec.Z).Unit
						end
					end
				end))
				LongJump:Clean(vainEvents.GrapplingHookFunctions.Event:Connect(function(dataTable)
					if dataTable.hookFunction == 'PLAYER_IN_TRANSIT' then
						local vec = entitylib.character.RootPart.CFrame.LookVector
						JumpSpeed = 2.5 * Value.Value
						JumpTick = tick() + 2.5
						Direction = Vector3.new(vec.X, 0, vec.Z).Unit
					end
				end))
	
				start = entitylib.isAlive and entitylib.character.RootPart.Position or nil
				LongJump:Clean(runService.PreSimulation:Connect(function(dt)
					local root = entitylib.isAlive and entitylib.character.RootPart or nil
	
					if root and isnetworkowner(root) then
						if JumpTick > tick() then
							root.AssemblyLinearVelocity = Direction * (getSpeed() + ((JumpTick - tick()) > 1.1 and JumpSpeed or 0)) + Vector3.new(0, root.AssemblyLinearVelocity.Y, 0)
							if entitylib.character.Humanoid.FloorMaterial == Enum.Material.Air and not start then
								root.AssemblyLinearVelocity += Vector3.new(0, dt * (workspace.Gravity - 23), 0)
							else
								root.AssemblyLinearVelocity = Vector3.new(root.AssemblyLinearVelocity.X, 15, root.AssemblyLinearVelocity.Z)
							end
							start = nil
						else
							if start then
								root.CFrame = CFrame.lookAlong(start, root.CFrame.LookVector)
							end
							root.AssemblyLinearVelocity = Vector3.zero
							JumpSpeed = 0
						end
					else
						start = nil
					end
				end))
	
				if store.hand and store.hand.tool and LongJumpMethods[store.hand.tool.Name] then
					task.spawn(LongJumpMethods[store.hand.tool.Name], getItem(store.hand.tool.Name), start, (CameraDir.Enabled and gameCamera or entitylib.character.RootPart).CFrame.LookVector)
					return
				end
	
				for i, v in LongJumpMethods do
					local item = getItem(i)
					if item or store.equippedKit == i then
						task.spawn(v, item, start, (CameraDir.Enabled and gameCamera or entitylib.character.RootPart).CFrame.LookVector)
						break
					end
				end
			else
				JumpTick = tick()
				Direction = nil
				JumpSpeed = 0
			end
		end,
		ExtraText = function()
			return 'Heatseeker'
		end,
		Tooltip = 'Lets you jump farther'
	})
	Value = LongJump:CreateSlider({
		Name = 'Speed',
		Tooltip = 'How fast this runs',
		Min = 1,
		Max = 37,
		Default = 37,
		Suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})
	CameraDir = LongJump:CreateToggle({
		Name = 'Camera Direction',
		Tooltip = 'Uses your camera direction instead of your character facing'
	})
end)

run(function()
	local NoFall
	local Mode
	local FallSpeed
	local ReportLanding
	local rayParams = RaycastParams.new()
	
	-- Stutter fights whatever these are doing to your vertical movement, so it stands down
	-- while one of them is driving.
	local function movementActive()
		for _, name in {'Fly', 'InfiniteFly', 'LongJump'} do
			local module = vain.Modules[name]
			if module and module.Enabled then return true end
		end
		return false
	end
	
	local groundHit
	task.spawn(function()
		groundHit = bedwars.Client:Get(remotes.GroundHit).instance
	end)
	
	NoFall = vain.Categories.Blatant:CreateModule({
		Name = 'NoFall',
		Function = function(callback)
			if callback then
				local tracked = 0
				if Mode.Value == 'Stutter' then
					-- Fall damage here is client reported: FallDamageController samples your
					-- velocity every frame while the humanoid is in Freefall, and on the
					-- Freefall -> Landed transition fires the GroundHit remote with it. It
					-- never accumulates a distance. Cutting one long fall into a series of
					-- short ones therefore keeps whatever gets reported small, and keeps the
					-- replicated descent short for anything measuring it from the outside.
					local pending = false
					NoFall:Clean(runService.PreSimulation:Connect(function()
						if not entitylib.isAlive or movementActive() then
							pending = false
							return
						end
	
						local humanoid = entitylib.character.Humanoid
						local root = entitylib.character.RootPart
						local velocity = root.AssemblyLinearVelocity
	
						if humanoid.FloorMaterial == Enum.Material.Air and velocity.Y < -FallSpeed.Value then
							-- Kill the descent, then re-assert the CFrame so the position we are
							-- already at is what replicates out, rather than a continuous drop.
							root.AssemblyLinearVelocity = Vector3.new(velocity.X, 0, velocity.Z)
							root.CFrame = root.CFrame
							pending = ReportLanding.Enabled
						elseif pending then
							-- Deliberately a frame later than the reset above. The velocity the
							-- controller reports is sampled during rendering, which happens
							-- before this step, so by now it has resampled at near zero and the
							-- landing this announces carries no fall with it. Roblox puts the
							-- humanoid straight back into Freefall on the next physics step.
							pending = false
							humanoid:ChangeState(Enum.HumanoidStateType.Landed)
						end
					end))
				elseif Mode.Value == 'Gravity' then
					local extraGravity = 0
					NoFall:Clean(runService.PreSimulation:Connect(function(dt)
						if entitylib.isAlive then
							local root = entitylib.character.RootPart
							if root.AssemblyLinearVelocity.Y < -85 then
								rayParams.FilterDescendantsInstances = {lplr.Character, gameCamera}
								rayParams.CollisionGroup = root.CollisionGroup
	
								local rootSize = root.Size.Y / 2 + entitylib.character.HipHeight
								local ray = workspace:Blockcast(root.CFrame, Vector3.new(3, 3, 3), Vector3.new(0, (tracked * 0.1) - rootSize, 0), rayParams)
								if not ray then
									root.AssemblyLinearVelocity = Vector3.new(root.AssemblyLinearVelocity.X, -86, root.AssemblyLinearVelocity.Z)
									root.CFrame += Vector3.new(0, extraGravity * dt, 0)
									extraGravity += -workspace.Gravity * dt
								end
							else
								extraGravity = 0
							end
						end
					end))
				else
					repeat
						if entitylib.isAlive then
							local root = entitylib.character.RootPart
							tracked = entitylib.character.Humanoid.FloorMaterial == Enum.Material.Air and math.min(tracked, root.AssemblyLinearVelocity.Y) or 0
	
							if tracked < -85 then
								if Mode.Value == 'Packet' then
									groundHit:FireServer(nil, Vector3.new(0, tracked, 0), workspace:GetServerTimeNow())
								else
									rayParams.FilterDescendantsInstances = {lplr.Character, gameCamera}
									rayParams.CollisionGroup = root.CollisionGroup
	
									local rootSize = root.Size.Y / 2 + entitylib.character.HipHeight
									if Mode.Value == 'Teleport' then
										local ray = workspace:Blockcast(root.CFrame, Vector3.new(3, 3, 3), Vector3.new(0, -1000, 0), rayParams)
										if ray then
											root.CFrame -= Vector3.new(0, root.Position.Y - (ray.Position.Y + rootSize), 0)
										end
									else
										local ray = workspace:Blockcast(root.CFrame, Vector3.new(3, 3, 3), Vector3.new(0, (tracked * 0.1) - rootSize, 0), rayParams)
										if ray then
											tracked = 0
											root.AssemblyLinearVelocity = Vector3.new(root.AssemblyLinearVelocity.X, -80, root.AssemblyLinearVelocity.Z)
										end
									end
								end
							end
						end
	
						task.wait(0.03)
					until not NoFall.Enabled
				end
			end
		end,
		Tooltip = 'Prevents taking fall damage.'
	})
	local function refreshVisibility()
		for _, option in {FallSpeed, ReportLanding} do
			if option and option.Object then
				option.Object.Visible = Mode and Mode.Value == 'Stutter'
			end
		end
	end
	
	Mode = NoFall:CreateDropdown({
		Name = 'Mode',
		Tooltip = 'Which method this module uses',
		List = {'Packet', 'Gravity', 'Teleport', 'Bounce', 'Stutter'},
		Tooltips = {
			Packet = 'Reports hitting the ground while you are still in the air',
			Gravity = 'Caps your falling speed and moves you down by hand instead',
			Teleport = 'Drops you to the ground once you are falling fast',
			Bounce = 'Cuts your falling speed just before you land',
			Stutter = 'Breaks the fall into short drops by stopping you over and over'
		},
		Function = function()
			refreshVisibility()
			if NoFall.Enabled then
				NoFall:Toggle()
				NoFall:Toggle()
			end
		end
	})
	FallSpeed = NoFall:CreateSlider({
		Name = 'Fall Speed',
		Tooltip = 'Downward speed that triggers a stop',
		Min = 5,
		Max = 150,
		Default = 60,
		Darker = true,
		Visible = false,
		Suffix = function()
			return 'studs/s'
		end
	})
	ReportLanding = NoFall:CreateToggle({
		Name = 'Report Landing',
		Tooltip = 'Tells the server you landed each time the fall is stopped',
		Default = true,
		Darker = true,
		Visible = false
	})
	refreshVisibility()
end)

run(function()
	local old
	
	vain.Categories.Blatant:CreateModule({
		Name = 'NoSlowdown',
		Function = function(callback)
			local modifier = bedwars.SprintController:getMovementStatusModifier()
			if callback then
				old = modifier.addModifier
				modifier.addModifier = function(self, tab)
					if tab.moveSpeedMultiplier then
						tab.moveSpeedMultiplier = math.max(tab.moveSpeedMultiplier, 1)
					end
					return old(self, tab)
				end
	
				for i in modifier.modifiers do
					if (i.moveSpeedMultiplier or 1) < 1 then
						modifier:removeModifier(i)
					end
				end
			else
				modifier.addModifier = old
				old = nil
			end
		end,
		Tooltip = 'Prevents slowing down when using items.'
	})
end)

run(function()
	local ProjectileAimbot
	local TargetPart
	local Targets
	local Sort
	local FOV
	local Range
	local HitChance
	local OtherProjectiles
	local ViewMode
	local InstantCharge
	local ChargeSpeed
	local SilentBeam
	local CircleColor
	local CircleTransparency
	local CircleFilled
	local CircleObject
	local rayCheck = RaycastParams.new()
	rayCheck.FilterType = Enum.RaycastFilterType.Include
	local mapfolder
	local old
	
	-- Resolved on use rather than once at load. The map does not exist yet if you inject
	-- while the round is still loading, and an Include filter holding nothing hits nothing -
	-- which silently switched off the landing prediction below for the whole session.
	local function refreshMapFilter()
		local map = workspace:FindFirstChild('Map')
		if map ~= mapfolder then
			mapfolder = map
			rayCheck.FilterDescendantsInstances = map and {map} or {}
		end
	end
	
	local function mousePosition()
		if inputService.TouchEnabled then
			return gameCamera.ViewportSize / 2
		end
		return inputService:GetMouseLocation()
	end
	
	-- First person puts the camera inside your own head, so the gap between the camera and
	-- the head is what separates the two views. Shiftlock still counts as third person here,
	-- which matches what you see on screen.
	local function viewAllowed()
		if ViewMode.Value == 'Both' then return true end
		return bedwars.isFirstPerson() == (ViewMode.Value == 'First Person')
	end
	
	-- Whichever of the two is closer to your cursor right now.
	local function nearestPart(ent)
		local closest, closestmag = 'RootPart', math.huge
		local mouse = mousePosition()
		for _, name in {'Head', 'RootPart'} do
			local part = ent[name]
			if part then
				local screen, vis = gameCamera:WorldToViewportPoint(part.Position)
				local mag = vis and (mouse - Vector2.new(screen.X, screen.Y)).Magnitude or math.huge
				if mag < closestmag then
					closest, closestmag = name, mag
				end
			end
		end
		return closest
	end
	
	-- How wide a failed shot lands, in studs. MINMISS has to clear the hitbox rather than
	-- just the model, or a near miss still registers as a hit. CLOSEDIST is the range
	-- MINMISS is measured at.
	local MINMISS, MAXMISS, CLOSEDIST = 5, 12, 20
	
	-- Pushes the aim point off the target when the roll fails. It grows with the square root
	-- of the distance and stops at MAXMISS: a plain angle grew in a straight line, which was
	-- right up close but put a long shot tens of studs wide - far enough that it reads as a
	-- shot that was never aimed at anything rather than one that missed.
	local function applySpread(aimpos, origin)
		local delta = aimpos - origin
		local dist = delta.Magnitude
		if dist <= 0 then return aimpos end
	
		local miss = MINMISS * math.sqrt(dist / CLOSEDIST) * (0.8 + math.random() * 0.4)
		miss = math.clamp(miss, MINMISS, MAXMISS)
		local look = delta.Unit
		local right = look:Cross(Vector3.yAxis)
		right = right.Magnitude > 0 and right.Unit or Vector3.xAxis
		local up = right:Cross(look).Unit
		local angle = math.random() * math.pi * 2
	
		return aimpos + (right * math.cos(angle) + up * math.sin(angle)) * miss
	end
	
	-- The game builds the draw strength itself, every frame, from drawDurationSeconds:
	-- ratio = min(1, drawDurationSeconds / maxStrengthChargeSec), and the launch speed is
	-- scaled from minStrengthScalar up to full at ratio 1. Writing the draw time is enough -
	-- the game recomputes the speed and fires its own max charge handling from there.
	local function applyCharge(projmeta)
		if not InstantCharge.Enabled or projmeta.drawDurationSeconds == nil then return end
	
		local tool = store.hand.tool
		local meta = tool and bedwars.ItemMeta[tool.Name]
		local source = meta and meta.projectileSource
		local maxcharge = source and source.maxStrengthChargeSec
		if not maxcharge then return end
	
		local wanted = maxcharge * (ChargeSpeed.Value / 100)
		if projmeta.drawDurationSeconds < wanted then
			projmeta.drawDurationSeconds = wanted
		end
	end
	
	-- Returns the launch values to use, or nil to let the game work it out itself.
	local function solve(self, projmeta, worldmeta, origin, shootpos)
		-- The game returns nil for a missing projmeta before touching it, so match that
		-- rather than indexing it and throwing back into the game's own call stack.
		if not projmeta then return nil end
	
		applyCharge(projmeta)
	
		-- worldmeta is true for the aim arc the game paints on your screen and false for the
		-- projectile that actually leaves. Handing the arc straight back leaves it pointing
		-- wherever your crosshair points, so only the shot itself is corrected.
		if SilentBeam.Enabled and worldmeta then return nil end
		if not viewAllowed() then return nil end
	
		if (not OtherProjectiles.Enabled) and not projmeta.projectile:find('arrow') then
			return nil
		end
	
		local selectpart = TargetPart.Value == 'Nearest' and 'RootPart' or TargetPart.Value
		local plr = entitylib.EntityMouse({
			Part = selectpart,
			Range = FOV.Value,
			Sort = sortmethods[Sort.Value],
			Players = Targets.Players.Enabled,
			NPCs = Targets.NPCs.Enabled,
			Preference = Targets.Preference.Value,
			Wallcheck = Targets.Walls.Enabled,
			Origin = entitylib.isAlive and (shootpos or entitylib.character.RootPart.Position) or Vector3.zero
		})
		if not plr then return nil end
	
		local pos = shootpos or self:getLaunchPosition(origin)
		if not pos then return nil end
	
		local target = plr[TargetPart.Value == 'Nearest' and nearestPart(plr) or TargetPart.Value]
		local character = plr.Character
		if not target or not character then return nil end
		if (target.Position - pos).Magnitude > Range.Value then return nil end
	
		local meta = projmeta:getProjectileMeta()
		-- Kits can hand back overrides for the speed and lifetime of their own projectiles.
		-- Solving with the base numbers instead aimed for a shot the game was never going
		-- to fire.
		local overrides = meta.getProjectileOverridesFunction and meta.getProjectileOverridesFunction(projmeta.player) or nil
		local lifetime = (worldmeta
			and ((overrides and overrides.predictionLifetimeOverride) or meta.predictionLifetimeSec)
			or ((overrides and overrides.lifetimeOverride) or meta.lifetimeSec)) or 3
		local gravity = (meta.gravitationalAcceleration or 196.2) * projmeta.gravityMultiplier
		-- velocityMultiplier is how far the bow is drawn. It was being left out while its
		-- sibling gravityMultiplier was applied, so every partly charged shot was solved at
		-- full power and fell short.
		local projSpeed = ((overrides and overrides.launchVelocityOverride) or meta.launchVelocity or 100) * projmeta.velocityMultiplier
		local offsetpos = pos + (projmeta.projectile == 'owl_projectile' and Vector3.zero or projmeta.fromPositionOffset)
		local balloons = character:GetAttribute('InflatedBalloons')
		local playerGravity = workspace.Gravity
	
		if balloons and balloons > 0 then
			playerGravity = (workspace.Gravity * (1 - ((balloons >= 4 and 1.2 or balloons >= 3 and 1 or 0.975))))
		end
	
		local primary = character.PrimaryPart
		if primary and primary:FindFirstChild('rbxassetid://8200754399') then
			playerGravity = 6
		end
	
		-- NPCs have no Player, and this used to index it regardless. Since this whole
		-- function replaces one the game calls itself, that error did not just lose the
		-- shot, it broke the game's projectile code for the rest of the round.
		if plr.Player and plr.Player:GetAttribute('IsOwlTarget') then
			for _, owl in collectionService:GetTagged('Owl') do
				if owl:GetAttribute('Target') == plr.Player.UserId and owl:GetAttribute('Status') == 2 then
					playerGravity = 0
				end
			end
		end
	
		refreshMapFilter()
	
		-- The position replicated for a target is already about one trip old by the time it
		-- reaches you, and the shot needs another trip before the server acts on it. The
		-- solver accounts for how far they move during the projectile's flight but knows
		-- nothing about that, so the shot lands where they were rather than where they are -
		-- an error that scales directly with ping, and the reason this misses worst on a bad
		-- connection. Aim a round trip ahead of what is on screen.
		--
		-- Skipped for telepearl, whose target velocity is deliberately ignored below.
		local aimpos = target.Position
		if projmeta.projectile ~= 'telepearl' then
			local latency = 0
			pcall(function()
				latency = lplr:GetNetworkPing() * 2
			end)
			-- Clamped: GetNetworkPing occasionally spikes, and a bad sample would otherwise
			-- throw the aim a long way off for that shot.
			aimpos += target.Velocity * math.clamp(latency, 0, 0.5)
		end
	
		if HitChance.Value < 100 and math.random(1, 100) > HitChance.Value then
			aimpos = applySpread(aimpos, offsetpos)
		end
	
		-- Solved from where the projectile actually leaves, not from positionFrom.
		--
		-- The game offsets the spawn itself once this returns:
		--
		--     positionFrom = (CFrame.new(positionFrom, positionFrom + initialVelocity)
		--                     * CFrame.new(Vector3.new(RelX, RelY, RelZ))).Position
		--
		-- so the muzzle sits a stud or so off positionFrom, along the launch direction.
		-- Solving from positionFrom itself puts the solution a whole offset away from where
		-- the shot really starts, and it stops hitting anything - which is exactly what
		-- happened when this was "corrected" to do that. Applying the same offset along the
		-- aim direction lands on very nearly the muzzle the game will use, since the launch
		-- direction and the aim direction differ only by the arc.
		local newlook = CFrame.new(offsetpos, aimpos) * CFrame.new(projmeta.projectile == 'owl_projectile' and Vector3.zero or Vector3.new(bedwars.BowConstantsTable.RelX, bedwars.BowConstantsTable.RelY, bedwars.BowConstantsTable.RelZ))
		local calc = prediction.SolveTrajectory(newlook.p, projSpeed, gravity, aimpos, projmeta.projectile == 'telepearl' and Vector3.zero or target.Velocity, playerGravity, plr.HipHeight, plr.Jumping and 42.6 or nil, rayCheck)
		if not calc then return nil end
	
		targetinfo.Targets[plr] = tick() + 1
		return {
			initialVelocity = CFrame.new(newlook.Position, calc).LookVector * projSpeed,
			positionFrom = offsetpos,
			deltaT = lifetime,
			gravitationalAcceleration = gravity,
			drawDurationSeconds = 5
		}
	end
	
	ProjectileAimbot = vain.Categories.Blatant:CreateModule({
		Name = 'ProjectileAimbot',
		Function = function(callback)
			if CircleObject then
				CircleObject.Visible = callback
			end
	
			if callback then
				ProjectileAimbot:Clean(runService.RenderStepped:Connect(function()
					if CircleObject then
						CircleObject.Position = mousePosition()
					end
				end))
	
				old = bedwars.ProjectileController.calculateImportantLaunchValues
				bedwars.ProjectileController.calculateImportantLaunchValues = function(...)
					-- Guarded because the game calls this, not us. Anything that throws in
					-- here used to surface inside the game's own bow logic and take the bow
					-- with it; now a failure just hands the shot back untouched. old() stays
					-- outside so its own errors still behave exactly as the game expects.
					local ok, result = pcall(solve, ...)
					if ok and result then
						return result
					end
					return old(...)
				end
			else
				bedwars.ProjectileController.calculateImportantLaunchValues = old
			end
		end,
		Tooltip = 'Silently adjusts your aim towards the enemy'
	})
	Targets = ProjectileAimbot:CreateTargets({
		Players = true,
		Walls = true,
		Tooltip = 'Which entities this module is allowed to target'
	})
	TargetPart = ProjectileAimbot:CreateDropdown({
		Name = 'Part',
		Tooltip = 'Which body part to aim at',
		List = {'RootPart', 'Head', 'Nearest'},
		Tooltips = {
			RootPart = 'Aims at the middle of the body',
			Head = 'Aims at the head',
			Nearest = 'Aims at whichever part is closer to your cursor'
		}
	})
	-- Cursor is pinned to the front because it is the default and matches how targets were
	-- picked before there was a choice. The rest are sorted so the dropdown order stays
	-- stable - iterating sortmethods directly is hash order, which reshuffles the list
	-- between injections. Distance is left out: this picks targets off the screen, so the
	-- plain magnitude ordering it stands for is the same thing as Cursor here.
	local methods, extramethods = {'Cursor'}, {}
	for i in sortmethods do
		if not table.find(methods, i) then
			table.insert(extramethods, i)
		end
	end
	table.sort(extramethods)
	for _, v in extramethods do
		table.insert(methods, v)
	end
	
	ViewMode = ProjectileAimbot:CreateDropdown({
		Name = 'View Mode',
		Tooltip = 'Which camera view this aims in',
		List = {'Both', 'First Person', 'Third Person'},
		Tooltips = {
			Both = 'Aims in either view',
			['First Person'] = 'Only while the camera is in your head',
			['Third Person'] = 'Only while the camera is behind you'
		}
	})
	Sort = ProjectileAimbot:CreateDropdown({
		Name = 'Target Mode',
		Tooltip = 'How targets are ranked when several are in your FOV at once',
		List = methods,
		Tooltips = sortmethodtips
	})
	FOV = ProjectileAimbot:CreateSlider({
		Name = 'FOV',
		Tooltip = 'How far from your cursor a target may be on screen',
		Min = 1,
		Max = 1000,
		Default = 1000,
		Function = function(val)
			if CircleObject then
				CircleObject.Radius = val
			end
		end
	})
	Range = ProjectileAimbot:CreateSlider({
		Name = 'Range',
		Tooltip = 'How far a target can be, in studs',
		Min = 10,
		Max = 500,
		Default = 500,
		Suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})
	HitChance = ProjectileAimbot:CreateSlider({
		Name = 'Hit Chance',
		Tooltip = 'How often a shot is aimed at the target instead of beside it',
		Min = 0,
		Max = 100,
		Default = 100,
		Suffix = function()
			return '%'
		end
	})
	OtherProjectiles = ProjectileAimbot:CreateToggle({
		Name = 'Other Projectiles',
		Tooltip = 'Also handles projectiles other than arrows',
		Default = true
	})
	InstantCharge = ProjectileAimbot:CreateToggle({
		Name = 'Instant Charge',
		Tooltip = 'Draws charged projectiles the moment you start aiming',
		Function = function(callback)
			ChargeSpeed.Object.Visible = callback
		end
	})
	ChargeSpeed = ProjectileAimbot:CreateSlider({
		Name = 'Charge Speed',
		Tooltip = 'How much of a full draw is applied instantly',
		Min = 0,
		Max = 100,
		Default = 100,
		Darker = true,
		Visible = false,
		Suffix = function()
			return '%'
		end
	})
	SilentBeam = ProjectileAimbot:CreateToggle({
		Name = 'Silent Beam',
		Tooltip = 'Leaves the aim arc on your crosshair and only adjusts the fired projectile'
	})
	ProjectileAimbot:CreateToggle({
		Name = 'Show FOV',
		Tooltip = 'Draws the circle around your cursor that targets are picked from',
		Function = function(callback)
			if callback then
				pcall(function()
					CircleObject = Drawing.new('Circle')
					CircleObject.Filled = CircleFilled.Enabled
					CircleObject.Color = Color3.fromHSV(CircleColor.Hue, CircleColor.Sat, CircleColor.Value)
					CircleObject.Position = vain.gui.AbsoluteSize / 2
					CircleObject.Radius = FOV.Value
					CircleObject.NumSides = 100
					CircleObject.Transparency = 1 - CircleTransparency.Value
					CircleObject.Visible = ProjectileAimbot.Enabled
				end)
			else
				pcall(function()
					CircleObject.Visible = false
					CircleObject:Remove()
				end)
				CircleObject = nil
			end
			CircleColor.Object.Visible = callback
			CircleTransparency.Object.Visible = callback
			CircleFilled.Object.Visible = callback
		end
	})
	CircleColor = ProjectileAimbot:CreateColorSlider({
		Name = 'Circle Color',
		Tooltip = 'Color used for the circle',
		Function = function(hue, sat, val)
			if CircleObject then
				CircleObject.Color = Color3.fromHSV(hue, sat, val)
			end
		end,
		Darker = true,
		Visible = false
	})
	CircleTransparency = ProjectileAimbot:CreateSlider({
		Name = 'Transparency',
		Tooltip = 'How solid the circle is drawn',
		Min = 0,
		Max = 1,
		Decimal = 10,
		Default = 0.5,
		Function = function(val)
			if CircleObject then
				CircleObject.Transparency = 1 - val
			end
		end,
		Darker = true,
		Visible = false
	})
	CircleFilled = ProjectileAimbot:CreateToggle({
		Name = 'Circle Filled',
		Tooltip = 'Fills the circle in instead of drawing its outline',
		Function = function(callback)
			if CircleObject then
				CircleObject.Filled = callback
			end
		end,
		Darker = true,
		Visible = false
	})
	
end)

run(function()
	local ProjectileAura
	local Targets
	local Range
	local List
	local OtherProjectiles
	local ViewMode
	local rayCheck = RaycastParams.new()
	rayCheck.FilterType = Enum.RaycastFilterType.Include
	local mapfolder
	local FireDelays = {}
	local ProjectileStub = {InvokeServer = function() end}
	local projectileRemote = ProjectileStub
	
	-- Resolving this once at load meant a single early failure - injecting before the
	-- remotes are registered - left the stub in place for the whole session, so every shot
	-- silently went nowhere. It runs again on enable while the stub is still there.
	local function resolveProjectileRemote()
		if projectileRemote ~= ProjectileStub then return end
		local ok, remote = pcall(function()
			return bedwars.Client:Get(remotes.FireProjectile).instance
		end)
		if ok and remote then
			projectileRemote = remote
		end
	end
	task.spawn(resolveProjectileRemote)
	
	-- The map is looked up rather than indexed. workspace.Map throws outright when it is
	-- not there yet, which is the whole pre-match lobby - and this loop had no error
	-- handling, so enabling the module before the round started killed it for good.
	local function refreshMapFilter()
		local map = workspace:FindFirstChild('Map')
		if map ~= mapfolder then
			mapfolder = map
			rayCheck.FilterDescendantsInstances = map and {map} or {}
		end
	end
	
	-- First person puts the camera inside your own head, so the gap between the camera and
	-- the head is what separates the two views. Shiftlock still counts as third person here,
	-- which matches what you see on screen.
	local function viewAllowed()
		if ViewMode.Value == 'Both' then return true end
		return bedwars.isFirstPerson() == (ViewMode.Value == 'First Person')
	end
	
	local function getAmmo(check)
		for _, item in store.inventory.inventory.items do
			if check.ammoItemTypes and table.find(check.ammoItemTypes, item.itemType) then
				return item.itemType
			end
		end
	end
	
	local function getProjectiles()
		local items = {}
		for _, item in store.inventory.inventory.items do
			-- An item the metadata does not know about used to throw here, and one unknown
			-- item anywhere in your inventory was enough to take the whole module down.
			local itemmeta = bedwars.ItemMeta[item.itemType]
			local proj = itemmeta and itemmeta.projectileSource
			local ammo = proj and getAmmo(proj)
			if ammo and (OtherProjectiles.Enabled or table.find(List.ListEnabled, ammo)) then
				table.insert(items, {
					item,
					ammo,
					proj.projectileType(ammo),
					proj
				})
			end
		end
		return items
	end
	
	ProjectileAura = vain.Categories.Blatant:CreateModule({
		Name = 'ProjectileAura',
		Function = function(callback)
			if callback then
				task.spawn(resolveProjectileRemote)
				repeat
					-- Guarded because this is a long-lived loop reaching into inventory and
					-- projectile metadata that changes underneath it. An error used to kill the
					-- coroutine outright, leaving the module switched on but permanently dead.
					-- The wait stays outside so a repeating error cannot spin the CPU.
					local ok = pcall(function()
						if (workspace:GetServerTimeNow() - bedwars.SwordController.lastAttack) > 0.5 and viewAllowed() then
							local ent = entitylib.EntityPosition({
								Part = 'RootPart',
								Range = Range.Value,
								Players = Targets.Players.Enabled,
								NPCs = Targets.NPCs.Enabled,
								Preference = Targets.Preference.Value,
								Wallcheck = Targets.Walls.Enabled
							})
	
							if ent then
								local pos = entitylib.character.RootPart.Position
								for _, data in getProjectiles() do
									local item, ammo, projectile, itemMeta = unpack(data)
									if (FireDelays[item.itemType] or 0) < tick() and item.tool then
										refreshMapFilter()
										local meta = bedwars.ProjectileMeta[projectile]
										local projSpeed = meta and meta.launchVelocity
										if not projSpeed then continue end
										local gravity = meta.gravitationalAcceleration or 196.2
										-- Aimed a round trip ahead of where the target appears, for the
										-- same reason ProjectileAimbot does: their replicated position
										-- is already about one trip old and the shot needs another
										-- before the server acts on it. The solver covers movement
										-- during flight but not that, so without it the miss grows
										-- with ping. Clamped because the ping reading can spike.
										local latency = 0
										pcall(function()
											latency = lplr:GetNetworkPing() * 2
										end)
										local aimAt = ent.RootPart.Position + (ent.RootPart.Velocity * math.clamp(latency, 0, 0.5))
										local calc = prediction.SolveTrajectory(pos, projSpeed, gravity, aimAt, ent.RootPart.Velocity, workspace.Gravity, ent.HipHeight, ent.Jumping and 42.6 or nil, rayCheck)
										if calc then
											targetinfo.Targets[ent] = tick() + 1
											local switched = switchItem(item.tool)
	
											task.spawn(function()
												local dir, id = CFrame.lookAt(pos, calc).LookVector, httpService:GenerateGUID(true)
												local shootPosition = (CFrame.new(pos, calc) * CFrame.new(Vector3.new(-bedwars.BowConstantsTable.RelX, -bedwars.BowConstantsTable.RelY, -bedwars.BowConstantsTable.RelZ))).Position
												bedwars.ProjectileController:createLocalProjectile(meta, ammo, projectile, shootPosition, id, dir * projSpeed, {drawDurationSeconds = 1})
												local res = projectileRemote:InvokeServer(item.tool, ammo, projectile, shootPosition, pos, dir * projSpeed, id, {drawDurationSeconds = 1, shotId = httpService:GenerateGUID(false)}, workspace:GetServerTimeNow() - 0.045)
												if not res then
													FireDelays[item.itemType] = tick()
												else
													local shoot = itemMeta.launchSound
													shoot = shoot and shoot[math.random(1, #shoot)] or nil
													if shoot then
														bedwars.SoundManager:playSound(shoot)
													end
												end
											end)
	
											FireDelays[item.itemType] = tick() + (itemMeta.fireDelaySec or 0.5)
											if switched then
												task.wait(0.05)
											end
										end
									end
								end
							end
						end
					end)
	
					task.wait(ok and 0.1 or 0.25)
				until not ProjectileAura.Enabled
			end
		end,
		Tooltip = 'Shoots people around you'
	})
	Targets = ProjectileAura:CreateTargets({
		Players = true,
		Walls = true,
		Tooltip = 'Which entities this module is allowed to target'
	})
	ViewMode = ProjectileAura:CreateDropdown({
		Name = 'View Mode',
		Tooltip = 'Which camera view this shoots in',
		List = {'Both', 'First Person', 'Third Person'},
		Tooltips = {
			Both = 'Shoots in either view',
			['First Person'] = 'Only while the camera is in your head',
			['Third Person'] = 'Only while the camera is behind you'
		}
	})
	List = ProjectileAura:CreateTextList({
		Name = 'Projectiles',
		Tooltip = 'Which projectiles this applies to',
		Default = {'arrow', 'snowball'}
	})
	OtherProjectiles = ProjectileAura:CreateToggle({
		Name = 'Other Projectiles',
		Tooltip = 'Uses every projectile you are holding instead of only the listed ones'
	})
	Range = ProjectileAura:CreateSlider({
		Name = 'Range',
		Tooltip = 'How far this reaches, in studs',
		Min = 1,
		Max = 50,
		Default = 50,
		Suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})
end)

run(function()
	local Speed
	local Value
	local WallCheck
	local AutoJump
	local AlwaysJump
	local rayCheck = RaycastParams.new()
	rayCheck.RespectCanCollide = true
	
	Speed = vain.Categories.Blatant:CreateModule({
		Name = 'Speed',
		Function = function(callback)
			frictionTable.Speed = callback or nil
			updateVelocity()
			pcall(function()
				swapConstant(bedwars.WindWalkerController.updateSpeed, callback and 'moveSpeedMultiplier' or 'constantSpeedMultiplier', callback and 'constantSpeedMultiplier' or 'moveSpeedMultiplier')
			end)
	
			if callback then
				Speed:Clean(runService.PreSimulation:Connect(function(dt)
					bedwars.StatefulEntityKnockbackController.lastImpulseTime = callback and math.huge or time()
					if entitylib.isAlive and not Fly.Enabled and not InfiniteFly.Enabled and not LongJump.Enabled and isnetworkowner(entitylib.character.RootPart) then
						local state = entitylib.character.Humanoid:GetState()
						if state == Enum.HumanoidStateType.Climbing then return end
	
						local root, velo = entitylib.character.RootPart, getSpeed()
						local moveDirection = AntiFallDirection or entitylib.character.Humanoid.MoveDirection
						local destination = (moveDirection * math.max(Value.Value - velo, 0) * dt)
	
						if WallCheck.Enabled then
							rayCheck.FilterDescendantsInstances = {lplr.Character, gameCamera}
							rayCheck.CollisionGroup = root.CollisionGroup
							local ray = workspace:Raycast(root.Position, destination, rayCheck)
							if ray then
								destination = ((ray.Position + ray.Normal) - root.Position)
							end
						end
	
						root.CFrame += destination
						root.AssemblyLinearVelocity = (moveDirection * velo) + Vector3.new(0, root.AssemblyLinearVelocity.Y, 0)
						if AutoJump.Enabled and (state == Enum.HumanoidStateType.Running or state == Enum.HumanoidStateType.Landed) and moveDirection ~= Vector3.zero and (Attacking or AlwaysJump.Enabled) then
							entitylib.character.Humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
						end
					end
				end))
			end
		end,
		ExtraText = function()
			return 'Heatseeker'
		end,
		Tooltip = 'Increases your movement with various methods.'
	})
	Value = Speed:CreateSlider({
		Name = 'Speed',
		Tooltip = 'How fast this runs',
		Min = 1,
		Max = 23,
		Default = 23,
		Suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})
	WallCheck = Speed:CreateToggle({
		Name = 'Wall Check',
		Tooltip = 'Ignores targets behind walls',
		Default = true
	})
	AutoJump = Speed:CreateToggle({
		Name = 'AutoJump',
		Tooltip = 'Jumps automatically',
		Function = function(callback)
			AlwaysJump.Object.Visible = callback
		end
	})
	AlwaysJump = Speed:CreateToggle({
		Name = 'Always Jump',
		Tooltip = 'Keeps jumping even when not needed',
		Visible = false,
		Darker = true
	})
end)

run(function()
	local BedESP
	local Reference = {}
	local Folder = Instance.new('Folder')
	Folder.Parent = vain.gui
	
	local function Added(bed)
		if not BedESP.Enabled then return end
		local BedFolder = Instance.new('Folder')
		BedFolder.Parent = Folder
		Reference[bed] = BedFolder
		local parts = bed:GetChildren()
		table.sort(parts, function(a, b)
			return a.Name > b.Name
		end)
	
		for _, part in parts do
			if part:IsA('BasePart') and part.Name ~= 'Blanket' then
				local handle = Instance.new('BoxHandleAdornment')
				handle.Size = part.Size + Vector3.new(.01, .01, .01)
				handle.AlwaysOnTop = true
				handle.ZIndex = 2
				handle.Visible = true
				handle.Adornee = part
				handle.Color3 = part.Color
				if part.Name == 'Legs' then
					handle.Color3 = Color3.fromRGB(167, 112, 64)
					handle.Size = part.Size + Vector3.new(.01, -1, .01)
					handle.CFrame = CFrame.new(0, -0.4, 0)
					handle.ZIndex = 0
				end
				handle.Parent = BedFolder
			end
		end
	
		table.clear(parts)
	end
	
	BedESP = vain.Categories.Render:CreateModule({
		Name = 'BedESP',
		Function = function(callback)
			if callback then
				BedESP:Clean(collectionService:GetInstanceAddedSignal('bed'):Connect(function(bed)
					task.delay(0.2, Added, bed)
				end))
				BedESP:Clean(collectionService:GetInstanceRemovedSignal('bed'):Connect(function(bed)
					if Reference[bed] then
						Reference[bed]:Destroy()
						Reference[bed] = nil
					end
				end))
				for _, bed in collectionService:GetTagged('bed') do
					Added(bed)
				end
			else
				Folder:ClearAllChildren()
				table.clear(Reference)
			end
		end,
		Tooltip = 'Render Beds through walls'
	})
end)

run(function()
	local Health
	
	Health = vain.Categories.Render:CreateModule({
		Name = 'Health',
		Function = function(callback)
			if callback then
				local label = Instance.new('TextLabel')
				label.Size = UDim2.fromOffset(100, 20)
				label.Position = UDim2.new(0.5, 6, 0.5, 30)
				label.BackgroundTransparency = 1
				label.AnchorPoint = Vector2.new(0.5, 0)
				label.Text = entitylib.isAlive and math.round(lplr.Character:GetAttribute('Health'))..' ❤️' or ''
				label.TextColor3 = entitylib.isAlive and Color3.fromHSV((lplr.Character:GetAttribute('Health') / lplr.Character:GetAttribute('MaxHealth')) / 2.8, 0.86, 1) or Color3.new()
				label.TextSize = 18
				label.Font = Enum.Font.Arial
				label.Parent = vain.gui
				Health:Clean(label)
				Health:Clean(vainEvents.AttributeChanged.Event:Connect(function()
					label.Text = entitylib.isAlive and math.round(lplr.Character:GetAttribute('Health'))..' ❤️' or ''
					label.TextColor3 = entitylib.isAlive and Color3.fromHSV((lplr.Character:GetAttribute('Health') / lplr.Character:GetAttribute('MaxHealth')) / 2.8, 0.86, 1) or Color3.new()
				end))
			end
		end,
		Tooltip = 'Displays your health in the center of your screen.'
	})
end)

run(function()
	local InventoryESP
	local List
	local Background
	local Color = {}
	local ShowAmount
	local Size
	local Gap
	local ShowAll
	local Teammates
	
	-- The things worth knowing an enemy has. Seeded straight into the item list, so they can
	-- be switched off or removed there like anything else rather than being nine settings of
	-- their own.
	local PRESETS = {
		'iron',
		'gold',
		'diamond',
		'emerald',
		'telepearl',
		'fireball',
		'tnt',
		'tesla_trap',
		'glue_projectile',
		'snap_trap',
		'golden_apple'
	}
	-- ent -> {Billboard = BillboardGui, Player = Player}
	-- The player is kept alongside the billboard because the adornee is the root
	-- part, and walking up its Parent chain lands on the workspace, not the player.
	local Entries = {}
	local Folder = Instance.new('Folder')
	Folder.Parent = vain.gui
	
	-- Every setting below is created *after* CreateModule returns, so any of them can
	-- still be nil while the file is executing. The module can be switched on inside
	-- that window when the GUI restores a saved config, which made reading .Enabled
	-- straight off them throw once per entity, every frame.
	local function on(setting)
		return setting ~= nil and setting.Enabled
	end
	
	-- Icons are drawn at 32 and the strip around them at 36, so one slider moves both.
	local function iconSize()
		return math.round(32 * ((Size and Size.Value or 100) / 100))
	end
	
	local function stripSize()
		return math.round(36 * ((Size and Size.Value or 100) / 100))
	end
	
	-- Which entry of the list an item matches, or nil for one that matches nothing. The
	-- position is what orders the icons, so they come out in the order the list is in rather
	-- than however the inventory happened to be arranged.
	local function listed(itemType)
		if not itemType then return nil end
		if not (List and List.ListEnabled) then return nil end
	
		for i, v in List.ListEnabled do
			if itemType == v or itemType:find(v) then
				return i
			end
		end
	
		-- Everything the list did not name, sorted after everything it did.
		if on(ShowAll) then return math.huge end
		return nil
	end
	
	--[[
		The folder a player's items actually live in, read straight off their character.
	
		This is where the game gets it from: an ObjectValue called InventoryFolder on the
		character, pointing at a folder whose children are the items - each named by its item
		type with the count on an Amount attribute. Reading it is live by definition, so
		nothing has to be cached or refreshed.
	
		Going through bedwars.getInventory instead is what kept emptying this display. That
		resolves the player to an entity first and returns an empty inventory when the lookup
		misses, so a miss is indistinguishable from somebody carrying nothing - and a display
		rebuilt from that shows nothing at all.
	]]
	local function inventoryFolder(plr)
		local char = plr.Character
		local value = char and char:FindFirstChild('InventoryFolder')
		return value and value.Value
	end
	
	local function addIcon(frame, itemType, amount)
		local image = Instance.new('ImageLabel')
		image.Size = UDim2.fromOffset(iconSize(), iconSize())
		image.BackgroundTransparency = 1
		image.Image = bedwars.getIcon({itemType = itemType}, true)
		image.Parent = frame
	
		if on(ShowAmount) and amount and amount > 1 then
			local text = Instance.new('TextLabel')
			text.Name = 'Amount'
			-- A strip across the bottom of the icon rather than a fixed box in the corner,
			-- with the text scaled to whatever is in it. Four digits at a fixed size ran
			-- straight out of a sixteen pixel box and across the icon next to it, which is
			-- what turned three stacks into one unreadable run of numbers.
			text.Size = UDim2.new(1, 0, 0, 14)
			text.Position = UDim2.new(0, 0, 1, -14)
			text.BackgroundTransparency = 1
			text.TextColor3 = Color3.new(1, 1, 1)
			text.TextScaled = true
			text.Text = tostring(amount)
			text.Parent = image
			-- Scaling alone would blow a single digit up to the full height of the strip.
			local size = Instance.new('UITextSizeConstraint')
			size.MaxTextSize = 12
			size.Parent = text
	
			-- What the panel behind it used to do. Without something separating the digits
			-- from the icon they sit on, a white number on a light block washes out as soon
			-- as the billboard shrinks with distance.
			local outline = Instance.new('UIStroke')
			outline.Color = Color3.new()
			outline.Thickness = 2
			outline.Parent = text
		end
	end
	
	--[[
		Draws what a player is carrying.
	
		The whole inventory, not just their hand. Only inventory.hand was ever looked at
		before, which is why adding anything to the item list did nothing unless the target
		happened to be holding that exact thing at that exact moment - and why the amount
		never showed either, since a held item is usually a single one.
	
		Other players' items really are readable; Vain already reads them elsewhere to work
		out how dangerous somebody is. Stacks of the same thing are added together, so eight
		iron in one slot and twelve in another read as twenty rather than as two icons.
	]]
	local function refreshAdornee(entry, plr)
		local container = entry.Billboard
		if not (container and container.Parent and plr) then return end
		local frame = container:FindFirstChild('Frame')
		if not frame then return end
	
		local inventory = store.inventories[plr] or {}
	
		for _, obj in frame:GetChildren() do
			if obj:IsA('ImageLabel') and obj.Name ~= 'Blur' then
				obj:Destroy()
			end
		end
	
		local totals, rank, order = {}, {}, {}
	
		local function count(item)
			if type(item) ~= 'table' or not item.itemType then return end
	
			local at = listed(item.itemType)
			if not at then return end
	
			if not totals[item.itemType] then
				totals[item.itemType] = 0
				rank[item.itemType] = at
				table.insert(order, item.itemType)
			end
			totals[item.itemType] += tonumber(item.amount) or 1
		end
	
		--[[
			Gear is not loot.
	
			Armour, swords and pickaxes are worn or held rather than stocked, so counting them
			alongside blocks and resources says nothing useful and pushes the things that do
			matter off the end of the strip. The item's own metadata names all three.
		]]
		local function isGear(itemType)
			local meta = bedwars.ItemMeta[itemType]
			return meta ~= nil and (meta.armor ~= nil or meta.sword ~= nil or meta.breakBlock ~= nil)
		end
	
		-- Live first. The snapshot is only used when the folder cannot be reached, so the
		-- display falls back to being stale rather than to being empty.
		local folder = inventoryFolder(plr)
		if folder then
			for _, child in folder:GetChildren() do
				-- Worn armour is in this folder too, carrying the slot it sits in.
				if child:GetAttribute('ArmorSlot') == nil and not isGear(child.Name) then
					count({itemType = child.Name, amount = child:GetAttribute('Amount')})
				end
			end
		elseif type(inventory.items) == 'table' then
			for _, item in inventory.items do
				if not isGear(item.itemType) then
					count(item)
				end
			end
		end
	
		-- Their hand is normally part of the list above already; this is only for the case
		-- where it is not.
		local hand = inventory.hand
		if type(hand) == 'table' and hand.itemType and not totals[hand.itemType] and not isGear(hand.itemType) then
			count(hand)
		end
	
		table.sort(order, function(a, b)
			if rank[a] == rank[b] then return a < b end
			return rank[a] < rank[b]
		end)
	
		local any = false
		for _, itemType in order do
			addIcon(frame, itemType, totals[itemType])
			any = true
		end
	
		entry.Shown = any
	end
	
	local function refreshAll()
		for ent, entry in Entries do
			if entry.Billboard.Parent and entry.Player and entry.Player.Parent then
				-- Someone who outranks you is not read either. Knowing what they carry is as
				-- much a use of them as aiming at them, so this follows the same rule the
				-- other render modules do.
				-- Teammates share your stock rather than stand between you and it, so what
				-- they carry is noise on the screen rather than anything to act on.
				if ent.Protected or (on(Teammates) and bedwars.sameTeam(entry.Player)) then
					entry.Shown = false
				else
					refreshAdornee(entry, entry.Player)
				end
			else
				entry.Billboard:Destroy()
				Entries[ent] = nil
			end
		end
	end
	
	local function Added(ent)
		if not ent.Player or Entries[ent] then return end
	
		--[[
			Drawn in screen space, the same way NameTags draws, rather than as a billboard.
	
			A BillboardGui is sized in the world, so it shrinks as the player gets further
			away - while the name above it is a plain label at a fixed pixel size that does
			not. Two things scaling at different rates cannot be held apart by any offset:
			whatever gap looks right up close is gone at range, which is exactly what kept
			them overlapping.
	
			Anchored to the same point NameTags anchors to, the head, but by the top edge
			rather than the bottom - so the name grows upward from that point and this hangs
			downward from it, and the two can never meet whatever the distance.
		]]
		local container = Instance.new('Frame')
		container.Name = 'inventory'
		container.AnchorPoint = Vector2.new(0.5, 0)
		container.Size = UDim2.fromOffset(stripSize(), stripSize())
		container.BackgroundTransparency = 1
		container.Visible = false
		container.Parent = Folder
	
		local blur = addBlur(container)
		blur.Visible = on(Background)
	
		local frame = Instance.new('Frame')
		frame.Name = 'Frame'
		frame.Size = UDim2.fromScale(1, 1)
		frame.BackgroundColor3 = Color3.fromHSV(Color.Hue or 0, Color.Sat or 0, Color.Value or 0.15)
		frame.BackgroundTransparency = 1 - (on(Background) and (Color.Opacity or 0.5) or 0)
		frame.Parent = container
	
		local layout = Instance.new('UIListLayout')
		layout.FillDirection = Enum.FillDirection.Horizontal
		layout.Padding = UDim.new(0, 4)
		layout.VerticalAlignment = Enum.VerticalAlignment.Center
		layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
		layout:GetPropertyChangedSignal('AbsoluteContentSize'):Connect(function()
			container.Size = UDim2.fromOffset(math.max(layout.AbsoluteContentSize.X + 4, stripSize()), stripSize())
		end)
		layout.Parent = frame
	
		local corner = Instance.new('UICorner')
		corner.CornerRadius = UDim.new(0, 4)
		corner.Parent = frame
	
		Entries[ent] = {Billboard = container, Player = ent.Player}
	end
	
	-- Positioned every frame, since a screen position only means anything for the frame it
	-- was worked out in.
	local function positionAll()
		for ent, entry in Entries do
			local container = entry.Billboard
			if not container.Parent then continue end
	
			if not (ent.RootPart and ent.RootPart.Parent) or not entry.Shown then
				container.Visible = false
				continue
			end
	
			local head = ent.RootPart.Position + Vector3.new(0, (ent.HipHeight or 2.6) + 1, 0)
			local point, onScreen = gameCamera:WorldToViewportPoint(head)
			container.Visible = onScreen
			if onScreen then
				container.Position = UDim2.fromOffset(point.X, point.Y + (Gap and Gap.Value or 4))
			end
		end
	end
	
	
	InventoryESP = vain.Categories.Render:CreateModule({
		Name = 'InventoryESP',
		Function = function(callback)
			if callback then
				for _, ent in entitylib.List do
					Added(ent)
				end
				InventoryESP:Clean(entitylib.Events.EntityAdded:Connect(Added))
				InventoryESP:Clean(entitylib.Events.EntityRemoved:Connect(function(ent)
					local entry = Entries[ent]
					if entry then
						entry.Billboard:Destroy()
						Entries[ent] = nil
					end
				end))
	
				-- Position every frame, contents on a timer. A screen position is only valid
				-- for the frame it was worked out in, but rebuilding icons that often is far
				-- more work than this needs and was the source of the old error spam.
				InventoryESP:Clean(runService.RenderStepped:Connect(positionAll))
	
				task.spawn(function()
					repeat
						local ok = pcall(refreshAll)
						task.wait(ok and 0.2 or 0.5)
					until not InventoryESP.Enabled
				end)
			else
				table.clear(Entries)
				Folder:ClearAllChildren()
			end
		end,
		Tooltip = 'Shows what players are carrying'
	})
	List = InventoryESP:CreateTextList({
		Name = 'Item',
		Tooltip = 'Which items to show',
		Default = PRESETS,
		Function = function()
			task.spawn(refreshAll)
		end
	})
	Background = InventoryESP:CreateToggle({
		Name = 'Background',
		Tooltip = 'Draws a background behind the icons',
		Function = function(callback)
			if Color.Object then Color.Object.Visible = callback end
			for _, entry in Entries do
				local frame = entry.Billboard:FindFirstChild('Frame')
				local blur = entry.Billboard:FindFirstChild('Blur')
				if frame then
					frame.BackgroundTransparency = 1 - (callback and (Color.Opacity or 0.5) or 0)
				end
				if blur then
					blur.Visible = callback
				end
			end
		end,
		Default = true
	})
	Color = InventoryESP:CreateColorSlider({
		Name = 'Background Color',
		Tooltip = 'Color of the background',
		DefaultValue = 0.15,
		DefaultOpacity = 0.5,
		Function = function(hue, sat, val, opacity)
			for _, entry in Entries do
				local frame = entry.Billboard:FindFirstChild('Frame')
				if frame then
					frame.BackgroundColor3 = Color3.fromHSV(hue, sat, val)
					frame.BackgroundTransparency = 1 - opacity
				end
			end
		end,
		Darker = true
	})
	Size = InventoryESP:CreateSlider({
		Name = 'Size',
		Tooltip = 'How big the icons are\nDefault is 60, which matches NameTags',
		Min = 25, Max = 250, Default = 60, Suffix = '%',
		Function = function()
			task.spawn(refreshAll)
		end
	})
	Gap = InventoryESP:CreateSlider({
		Name = 'Gap',
		Tooltip = 'Pixels between the name and the icons\nDefault is 2',
		Min = 0, Max = 40, Default = 2, Suffix = 'px'
	})
	Teammates = InventoryESP:CreateToggle({
		Name = 'Ignore Teammates',
		Tooltip = 'Hides what players on your own team are carrying',
		Function = function()
			task.spawn(refreshAll)
		end,
		Default = true
	})
	ShowAll = InventoryESP:CreateToggle({
		Name = 'Show All',
		Tooltip = 'Shows everything they carry, not just the list',
		Function = function()
			task.spawn(refreshAll)
		end
	})
	ShowAmount = InventoryESP:CreateToggle({
		Name = 'Show Amount',
		Tooltip = 'Displays the quantity of each item in the corner',
		Function = function()
			task.spawn(refreshAll)
		end
	})
	
end)

run(function()
	local KitESP = {Enabled = false}
	local Notify
	local Tracers
	local Background
	local Color
	local Reference = {}
	local Folder = Instance.new('Folder')
	Folder.Parent = vain.gui
	
	-- Settings are created after CreateModule returns, so they can still be nil while this
	-- file is executing - and the module can be switched on inside that window when the GUI
	-- restores a saved config. Reading .Enabled straight off them threw.
	local function on(setting)
		return setting ~= nil and setting.Enabled
	end
	
	local function backgroundColor()
		return Color3.fromHSV(Color and Color.Hue or 0, Color and Color.Sat or 0, Color and Color.Value or 0)
	end
	
	--[[
		Beekeeper tags both the wild bees worth collecting and the tamed ones already swarming
		a placed hive with 'bee'. Both come from the same builder, but the tamed swarm is given
		a BeeId of -1 while a collectible carries a real, positive one from the server. Without
		this the hive you already own buries the map in icons.
	]]
	local function beeCollectibleOnly(v)
		local id = v:GetAttribute('BeeId')
		return not (type(id) == 'number' and id <= 0)
	end
	
	-- Wren's shadow coins carry no tag of their own: they are ordinary item drops, sharing
	-- the ItemDrop tag with every other dropped thing on the map, so they go by name.
	local function shadowCoinsOnly(v)
		return v.Name == 'shadow_coin'
	end
	
	--[[
		What each kit leaves lying about, keyed by the id the game uses rather than the name it
		shows - several were renamed and kept the old id, so Eldertree is still bigman.
	
		An entry is {source, icon, byName, filter}. Most collectibles carry a CollectionService
		tag, but some are plain Workspace models with a known name and no tag at all, which is
		what byName is for - that is why the stars and Grove's energy never appeared when they
		were looked up as tags.
	]]
	local ESPKits = {
		alchemist = {
			{'Thorns', 'thorns', true},
			{'Mushrooms', 'mushrooms', true},
			{'Flower', 'wild_flower', true},
			{'alchemist_ingedients', 'wild_flower'},
			{'alchemy_crystal', 'spirit'}
		},
		beekeeper = {
			{'bee', 'bee', false, beeCollectibleOnly}
		},
		-- Eldertree
		bigman = {
			{'treeOrb', 'natures_essence_1'}
		},
		-- Wren
		black_market_trader = {
			{'ItemDrop', 'shadow_coin', false, shadowCoinsOnly}
		},
		-- Gompy
		ghost_catcher = {
			{'ghost', 'ghost_orb'}
		},
		metal_detector = {
			{'hidden-metal', 'iron'}
		},
		-- Death Adder
		sorcerer = {
			{'alchemy_crystal', 'spirit'}
		},
		-- Grove
		spirit_gardener = {
			{'SpiritGardenerEnergy', 'spirit', true}
		},
		-- Star Collector Stella
		star_collector = {
			{'CritStar', 'crit_star', true},
			{'VitalityStar', 'vitality_star', true}
		}
	}
	
	--[[
		What to hang the icon on.
	
		Some of these are models and some are bare parts, so reaching for PrimaryPart alone
		came back with nothing for half of them - and nothing then became the key of the
		reference table, which is an error rather than a missing icon.
	]]
	local function adorneeOf(v)
		if typeof(v) ~= 'Instance' then return end
		if v:IsA('BasePart') then return v end
		return v:FindFirstChildWhichIsA('BasePart', true) or (v:IsA('Model') and v.PrimaryPart or nil)
	end
	
	--[[
		How far above the object's own middle to sit.
	
		This used to be a flat three studs, which is most of a player's height - so on a bee
		lying on the floor the icon floated well clear of it with nothing to say what it was
		pointing at. Measured from the thing itself instead, it rests on what it marks.
	]]
	local function iconHeight(v, adornee)
		local size
		if v:IsA('Model') then
			local ok, extents = pcall(v.GetExtentsSize, v)
			size = ok and extents or nil
		end
		size = size or adornee.Size
		return math.clamp(size.Y * 0.5, 0.5, 4)
	end
	
	local function espadd(v, adornee, icon)
		if not adornee or Reference[adornee] then return end
	
		local billboard = Instance.new('BillboardGui')
		billboard.Parent = Folder
		billboard.Name = icon
		billboard.StudsOffsetWorldSpace = Vector3.new(0, iconHeight(v, adornee), 0)
		billboard.Size = UDim2.fromOffset(36, 36)
		billboard.AlwaysOnTop = true
		billboard.ClipsDescendants = false
		billboard.Adornee = adornee
		local blur = addBlur(billboard)
		blur.Visible = on(Background)
		local image = Instance.new('ImageLabel')
		image.BorderSizePixel = 0
		image.Image = bedwars.getIcon({itemType = icon}, true)
		image.BackgroundColor3 = backgroundColor()
		image.BackgroundTransparency = 1 - (on(Background) and (Color and Color.Opacity or 0.5) or 0)
		image.Size = UDim2.fromOffset(36, 36)
		image.Position = UDim2.fromScale(0.5, 0.5)
		image.AnchorPoint = Vector2.new(0.5, 0.5)
		image.Parent = billboard
		local uicorner = Instance.new('UICorner')
		uicorner.CornerRadius = UDim.new(0, 4)
		uicorner.Parent = image
		Reference[adornee] = billboard
	end
	
	local function espremove(v)
		local adornee = adorneeOf(v)
		if adornee and Reference[adornee] then
			Reference[adornee]:Destroy()
			Reference[adornee] = nil
		end
	end
	
	local function addKit(source, icon, byName, filter)
		if byName then
			local function check(v)
				if v.Name == source and v:IsA('Model') then
					espadd(v, adorneeOf(v), icon)
				end
			end
			KitESP:Clean(workspace.ChildAdded:Connect(check))
			KitESP:Clean(workspace.ChildRemoved:Connect(function(v)
				pcall(espremove, v)
			end))
			for _, v in workspace:GetChildren() do
				check(v)
			end
			return
		end
	
		local function tryAdd(v)
			if filter and not filter(v) then return end
			espadd(v, adorneeOf(v), icon)
		end
		KitESP:Clean(collectionService:GetInstanceAddedSignal(source):Connect(tryAdd))
		KitESP:Clean(collectionService:GetInstanceRemovedSignal(source):Connect(espremove))
		for _, v in collectionService:GetTagged(source) do
			tryAdd(v)
		end
	end
	
	local TracerLines = {}
	local TracerConn
	
	local function clearTracers()
		for _, line in TracerLines do
			pcall(function() line:Remove() end)
		end
		table.clear(TracerLines)
	end
	
	local function updateTracers()
		if not on(Tracers) then return end
	
		local view = gameCamera.ViewportSize
		local originX, originY = view.X / 2, view.Y
		local color = backgroundColor()
	
		for part, line in TracerLines do
			if not Reference[part] or not part.Parent then
				pcall(function() line:Remove() end)
				TracerLines[part] = nil
			end
		end
	
		for part in Reference do
			if typeof(part) == 'Instance' and part:IsA('BasePart') then
				local point, visible = gameCamera:WorldToViewportPoint(part.Position)
				local line = TracerLines[part]
				if visible and point.Z > 0 then
					if not line then
						line = Drawing.new('Line')
						line.Thickness = 1
						TracerLines[part] = line
					end
					line.Color = color
					line.From = Vector2.new(originX, originY)
					line.To = Vector2.new(point.X, point.Y)
					line.Visible = true
				elseif line then
					line.Visible = false
				end
			end
		end
	end
	
	KitESP = vain.Categories.Render:CreateModule({
		Name = 'KitESP',
		Function = function(callback)
			if callback then
				Folder:ClearAllChildren()
				table.clear(Reference)
	
				if TracerConn then TracerConn:Disconnect() end
				TracerConn = runService.RenderStepped:Connect(updateTracers)
	
				--[[
					Polled rather than driven off a signal.
	
					The equipped kit is kept on the store, which is written from a subscription
					rather than from an attribute, so there is no event to hang this on that
					fires reliably. Watching the player's kit attribute meant that switching
					this on mid-match - with a kit already equipped, so nothing left to change -
					hooked nothing at all and stayed dead for the rest of the round.
				]]
				task.spawn(function()
					local current
					while KitESP.Enabled do
						local kit = store.equippedKit or ''
						if kit ~= current then
							Folder:ClearAllChildren()
							table.clear(Reference)
							clearTracers()
	
							local entries = kit ~= '' and ESPKits[kit]
							if entries then
								for _, entry in entries do
									addKit(entry[1], entry[2], entry[3], entry[4])
								end
								if on(Notify) then
									notif('KitESP', 'Tracking objects for ' .. kit, 4, 'check')
								end
							elseif kit ~= '' and on(Notify) then
								notif('KitESP', kit .. ' has nothing to track', 4, 'alert')
							end
							current = kit
						end
						task.wait(0.5)
					end
	
					Folder:ClearAllChildren()
					table.clear(Reference)
				end)
			else
				Folder:ClearAllChildren()
				table.clear(Reference)
				if TracerConn then
					TracerConn:Disconnect()
					TracerConn = nil
				end
				clearTracers()
			end
		end,
		Tooltip = 'ESP for the objects your equipped kit collects'
	})
	Notify = KitESP:CreateToggle({
		Name = 'Notify',
		Tooltip = 'Says which kit was picked up and whether it has anything to track'
	})
	Tracers = KitESP:CreateToggle({
		Name = 'Tracers',
		Tooltip = 'Draws a line from the bottom of the screen to each object',
		Function = function(callback)
			if not callback then clearTracers() end
		end
	})
	Background = KitESP:CreateToggle({
		Name = 'Background',
		Tooltip = 'Draws a background behind the icon',
		Function = function(callback)
			if Color and Color.Object then Color.Object.Visible = callback end
			for _, v in Reference do
				v.ImageLabel.BackgroundTransparency = 1 - (callback and (Color.Opacity or 0.5) or 0)
				v.Blur.Visible = callback
			end
		end,
		Default = true
	})
	Color = KitESP:CreateColorSlider({
		Name = 'Background Color',
		Tooltip = 'Color of the background',
		DefaultValue = 0,
		DefaultOpacity = 0.5,
		Function = function(hue, sat, val, opacity)
			for _, v in Reference do
				v.ImageLabel.BackgroundColor3 = Color3.fromHSV(hue, sat, val)
				v.ImageLabel.BackgroundTransparency = 1 - opacity
			end
		end,
		Darker = true
	})
	
end)

run(function()
	local KitDisplay
	
	local function getKitMeta(player)
		local kit = player:GetAttribute('PlayingAsKits') or player:GetAttribute('PlayingAsKit') or 'none'
		return bedwars.BedwarsKitMeta[kit] or bedwars.BedwarsKitMeta.none or {renderImage = ''}
	end
	
	local function getPlayerFromDraft(render, name)
		local id = render and render:match('id=(%d+)')
		if id then
			local player = playersService:GetPlayerByUserId(tonumber(id))
			if player then
				return player
			end
		end
	
		for _, v in playersService:GetPlayers() do
			if render and render:find('id=' .. v.UserId, 1, true) then
				return v
			end
	
			if name and (v.Name == name or v.DisplayName == name or v:GetAttribute('DisguiseDisplayName') == name) then
				return v
			end
	
			local displayName
			pcall(function()
				displayName = bedwars.StreamerModeController:getDisplayName(v)
			end)
			if name and displayName == name then
				return v
			end
		end
		return nil
	end
	
	local waitForChild = function(start, ...)
		local parent = start
		for _, v in {...} do
			parent = parent and parent:WaitForChild(v, 5)
			if not parent then
				break
			end
		end
		return parent
	end
	
	local function getPlayerName(card)
		local textbar = card and card:FindFirstChild('TextBackgroundBar')
		local label = textbar and textbar:FindFirstChild('PlayerName') or card and card:FindFirstChild('PlayerName', true)
		return label and label.Text or ''
	end
	
	local function getDraftCard(container)
		if not container then
			return
		end
		return container.Name == 'MatchDraftPlayerCard' and container or container:FindFirstChild('MatchDraftPlayerCard', true)
	end
	
	local function callback5v5(v, plr)
		if not v then
			return
		end
		local render = v:FindFirstChild('PlayerRender', true)
		local player = plr or getPlayerFromDraft(render and render.Image or '', getPlayerName(v))
	
		if player then
			local kitImage = getKitMeta(player)
			local roact = v:FindFirstChild('KitImage')
	
			if not roact then
				roact = Instance.new('ImageLabel', v)
				roact.BackgroundTransparency = 1
				roact.AnchorPoint = Vector2.new(1, 0.5)
				roact.Position = UDim2.fromScale(1.05, 0.5)
				roact.Name = 'KitImage'
				roact.Size = UDim2.fromScale(1.5, 1.5)
				roact.ZIndex = 1
				roact.ImageTransparency = 0.4
				roact.SliceCenter = Rect.new(0, 0, 0, 0)
				roact.SliceScale = 1
				roact.ScaleType = Enum.ScaleType.Crop
	
				KitDisplay:Clean(roact)
	
				local ratio = Instance.new('UIAspectRatioConstraint', roact)
				ratio.Name = '1'
				ratio.AspectRatio = 1
				ratio.AspectType = Enum.AspectType.FitWithinMaxSize
				ratio.DominantAxis = Enum.DominantAxis.Width
			end
	
			roact.Image = kitImage.renderImage
			roact.Position = UDim2.fromScale(1.05, 0)
			tweenService:Create(roact, TweenInfo.new(0.2, Enum.EasingStyle.Cubic, Enum.EasingDirection.Out), {Position = UDim2.fromScale(1.05, 0.4)}):Play()
	
			local function update()
				roact.Image = getKitMeta(player).renderImage
			end
	
			-- Re-bind the kit listener to whichever player the card currently shows.
			-- Draft cards are reused as the list reorders, so a card can switch to a
			-- new player; without this the kit image stays stuck on the old player.
			local kitConn
			local function bindKit()
				if kitConn then kitConn:Disconnect() end
				kitConn = player:GetAttributeChangedSignal('PlayingAsKits'):Connect(update)
				KitDisplay:Clean(kitConn)
				update()
			end
			bindKit()
	
			if render then
				KitDisplay:Clean(render:GetPropertyChangedSignal('Image'):Connect(function()
					local newplayer = getPlayerFromDraft(render.Image, getPlayerName(v))
					if newplayer and newplayer ~= player then
						player = newplayer
						bindKit()
					end
				end))
			end
		end
	end
	
	local function callbacksquad(v)
		if not v then
			return
		end
		local render = v:FindFirstChild('PlayerRender', true)
		local player = render and getPlayerFromDraft(render.Image, '') or nil
	
		if player then
			local kitImage = getKitMeta(player)
			local Roact = v:FindFirstChild('Kitcvrender')
	
			if not Roact then
				local base = v:FindFirstChild('3') or v:WaitForChild('3', 5)
				if not base then
					return
				end
				Roact = base:Clone()
				Roact.Parent = v
				Roact.Name = 'Kitcvrender'
				KitDisplay:Clean(Roact)
			end
	
			Roact.Image = kitImage.renderImage
	
			local function update()
				Roact.Image = getKitMeta(player).renderImage
			end
	
			-- Keep the kit listener bound to whichever player this card now shows.
			local kitConn
			local function bindKit()
				if kitConn then kitConn:Disconnect() end
				kitConn = player:GetAttributeChangedSignal('PlayingAsKits'):Connect(update)
				KitDisplay:Clean(kitConn)
				update()
			end
			bindKit()
	
			KitDisplay:Clean(render:GetPropertyChangedSignal('Image'):Connect(function()
				local newplayer = getPlayerFromDraft(render.Image, '')
				if newplayer and newplayer ~= player then
					player = newplayer
					bindKit()
				end
			end))
		end
	end
	
	local function setup5v5(DraftApp)
		local Background = DraftApp:FindFirstChild('DraftAppBackground')
		local BodyContainer = Background and Background:FindFirstChild('1') and Background['1']:FindFirstChild('BodyContainer')
		local hooked = false
	
		for i = 1, 2 do
			local dtc = BodyContainer and BodyContainer:FindFirstChild('Team' .. i .. 'Column')
			if dtc then
				hooked = true
				KitDisplay:Clean(dtc.ChildAdded:Connect(function(child)
					task.delay(0.2, function()
						if KitDisplay.Enabled then
							callback5v5(getDraftCard(child))
						end
					end)
				end))
	
				for _, v in dtc:GetChildren() do
					if v:IsA('Frame') then
						callback5v5(getDraftCard(v))
					end
				end
			end
		end
	
		if not hooked then
			for _, label in DraftApp:GetDescendants() do
				if label:IsA('TextLabel') and label.Name == 'PlayerName' then
					local container = label.Parent
					for _ = 1, 3 do
						container = container and container.Parent
					end
					if container then
						callback5v5(getDraftCard(container))
					end
				end
			end
	
			KitDisplay:Clean(DraftApp.DescendantAdded:Connect(function(child)
				if child:IsA('TextLabel') and child.Name == 'PlayerName' then
					task.delay(0.2, function()
						local container = child.Parent
						for _ = 1, 3 do
							container = container and container.Parent
						end
						if KitDisplay.Enabled and container then
							callback5v5(getDraftCard(container))
						end
					end)
				end
			end))
		end
	
		return hooked
	end
	
	local function setupSquad(DraftApp)
		local Background = DraftApp:FindFirstChild('DraftAppBackground')
		local BodyContainer = Background and Background:FindFirstChild('1') and Background['1']:FindFirstChild('BodyContainer')
		local TeamsColumn = BodyContainer and BodyContainer:FindFirstChild('TeamsColumn')
		if not TeamsColumn then
			return
		end
	
		for _, v: Instance in TeamsColumn:GetChildren() do
			if v:IsA('Frame') then
				local plrframe = waitForChild(v, '1', '2', '4')
				if plrframe then
					for _, plr in plrframe:GetChildren() do
						callbacksquad(plr)
					end
	
					-- Apply directly to the newly added card instead of restarting the
					-- whole module (the old code toggled itself off/on, which combined
					-- with the infinite WaitForChild below would hang/flicker it).
					KitDisplay:Clean(plrframe.ChildAdded:Connect(function(plr)
						task.delay(0.2, function()
							if KitDisplay.Enabled then
								callbacksquad(plr)
							end
						end)
					end))
				end
			end
		end
	end
	
	local function runSetup(DraftApp)
		if not DraftApp or not KitDisplay.Enabled then return end
		-- 5v5 first; if it found no team columns it hooks PlayerName labels itself.
		setup5v5(DraftApp)
		setupSquad(DraftApp)
	end
	
	KitDisplay = vain.Categories.Render:CreateModule({
		Name = 'Kit Render',
		Tooltip = 'Enables the Kit Display module',
		Function = function(call)
			if call then
				-- The draft UI (MatchDraftApp) is created at the start of every kit
				-- phase and removed after, so a one-shot wait misses later rounds.
				-- Set up on whatever's there now, and again each time it reappears.
				local existing = lplr.PlayerGui:FindFirstChild('MatchDraftApp')
				if existing then
					runSetup(existing)
				end
				KitDisplay:Clean(lplr.PlayerGui.ChildAdded:Connect(function(child)
					if child.Name == 'MatchDraftApp' and KitDisplay.Enabled then
						task.wait(0.2)
						runSetup(child)
					end
				end))
			end
		end,
		Tooltip = 'Allows you to see the other opponent kits'
	})
	
end)

run(function()
	local NameTags
	local Targets
	local Color
	local Background
	local DisplayName
	local Health
	local Distance
	local Equipment
	local DrawingToggle
	local Scale
	local FontOption
	local Teammates
	local DistanceCheck
	local DistanceLimit
	local Rank
	local Device
	local Enchants
	local Effects
	local Strings, Sizes, Reference, Prefixes = {}, {}, {}, {}
	local Folder = Instance.new('Folder')
	Folder.Parent = vain.gui
	local methodused
	
	--[[
		Enchantments and effects are the same thing underneath: the game writes both onto the
		character as a StatusEffect_<name> attribute, present while active and removed when it
		wears off. So one read of the character's attributes answers both settings.
	
		Three companion attributes sit under the same prefix carrying stack counts and extra
		data. They are not effects of their own and would otherwise show up as garbage entries.
	]]
	local STATUS_PREFIX = 'StatusEffect_'
	local STATUS_COMPANION = {stacks = true, extraNumbers = true, extraBooleans = true}
	
	-- At most this many per group, so somebody carrying a dozen effects widens their tag by a
	-- readable amount rather than off the side of the screen. The rest are counted, not named.
	local STATUS_SHOWN = 4
	
	-- Effects the game keeps for its own bookkeeping - cooldown markers, spam guards, the
	-- hidden half of a stacking effect - which mean nothing on a nametag.
	local STATUS_INTERNAL = {'_ON_COOLDOWN$', '_INDICATOR$', '_SELF_STACK$', '^ANTI_', '^ANALYTICS', '^AFK_'}
	
	-- The weapon enchants, whose effect name does not contain the word 'enchant' the way the
	-- armour and tool ones do. Kept here so an enchantment is still told apart from an
	-- ordinary effect even if the enum cannot be read.
	local STATUS_WEAPON_ENCHANT = {
		fire_1 = true, static_1 = true, execute_3 = true, critical_strike_1 = true,
		forest_1 = true, cloud_3 = true, soul_reaver = true, berserker_1 = true,
		enchant_cleave = true
	}
	
	-- Matched against the effect name rather than the enum member, for the same reason.
	local STATUS_HIDDEN = {'_on_cooldown$', '_indicator$', '_self_stack$', '^anti_', '^afk_', '^analytics'}
	
	local StatusEnchant, StatusLabel
	local StatusSig, StatusNext = {}, 0
	
	-- How often the attributes are re-read. Nothing fires when an effect lands or wears off
	-- that the entity events would catch, so this is polled rather than driven; a fifth of a
	-- second is quicker than anyone reacts and costs one table read per entity.
	local STATUS_POLL = 0.2
	
	--[[
		Worked out once, from the game's own enum rather than a list written out here, so an
		effect added in an update names itself instead of vanishing.
	
		The label comes from the enum member: BERSERKER_1 reads as Berserker, ARMOR_ENCHANT_
		ABSORPTION as Absorption. The game's own display name is preferred where it has one,
		since it is usually the friendlier word - Greasy rather than Greased - but it only
		covers about two thirds of them, and none of the ones worth calling an enchantment.
	]]
	local function statusTitle(name)
		local words = {}
		for word in name:gsub('_%d+$', ''):gmatch('[^_]+') do
			words[#words + 1] = word:sub(1, 1):upper() .. word:sub(2):lower()
		end
		return table.concat(words, ' ')
	end
	
	local function classifyStatus()
		if StatusLabel then return end
		StatusEnchant, StatusLabel = {}, {}
	
		-- Nicer labels when the enum can be read, nothing worse than plainer wording when it
		-- cannot. Everything below this point works either way.
		local ok, enum = pcall(function() return bedwars.StatusEffectType end)
		if not ok or type(enum) ~= 'table' then return end
	
		for name, value in enum do
			-- Members only. Some of these enums carry a reverse map alongside the forward one,
			-- and a lowercase key there would otherwise read as an effect called GREASED.
			if type(name) ~= 'string' or type(value) ~= 'string' or name ~= name:upper() then continue end
	
			local internal = false
			for _, pattern in STATUS_INTERNAL do
				if name:find(pattern) then
					internal = true
					break
				end
			end
			if internal then continue end
	
			-- An enchantment is anything the enum calls one, however it is spelt: ENCHANT_FIRE,
			-- ARMOR_ENCHANT_FROST, GROUNDED_ENCHANT.
			local enchant = name:find('ENCHANT') ~= nil
			StatusEnchant[value] = enchant
	
			local ok, meta = pcall(function() return bedwars.StatusEffectMeta[value] end)
			StatusLabel[value] = (not enchant and ok and meta and meta.displayName) or statusTitle((name:gsub('^.*ENCHANT_', ''):gsub('_ENCHANT$', '')))
		end
	end
	
	-- What is currently on the character, split the two ways the settings ask for. Sorted,
	-- because attributes come back in no particular order and an unsorted tag would shuffle
	-- its own words every time it refreshed.
	local function statusOf(ent)
		classifyStatus()
	
		local character = ent.Character
		if not character then return end
	
		local enchants, effects, attributes = {}, {}, nil
		local ok, result = pcall(character.GetAttributes, character)
		if not ok then return end
		attributes = result
	
		for key in attributes do
			local name = key:sub(1, #STATUS_PREFIX) == STATUS_PREFIX and key:sub(#STATUS_PREFIX + 1) or nil
			if not name or STATUS_COMPANION[name:match('_([%a]+)$') or ''] then continue end
	
			--[[
				An effect the enum did not name still gets shown, under its own name tidied up.
	
				This is the whole reason enchantments were coming out blank: they are perfectly
				ordinary status effects, so anything that stops the enum being read - a renamed
				module, a Flamework wrapper that does not iterate - silently emptied the table
				and every lookup missed. Nothing here depends on that table existing any more.
			]]
			local label = StatusLabel[name]
			if not label then
				local hidden = false
				for _, pattern in STATUS_HIDDEN do
					if name:find(pattern) then
						hidden = true
						break
					end
				end
				if hidden then continue end
				label = statusTitle(name)
			end
	
			local stacks = attributes[key .. '_stacks']
			if type(stacks) == 'number' and stacks > 1 then
				label = label .. ' x' .. stacks
			end
	
			local enchant = StatusEnchant[name]
			if enchant == nil then
				enchant = name:find('enchant') ~= nil or STATUS_WEAPON_ENCHANT[name] or false
			end
	
			if enchant then
				enchants[#enchants + 1] = label
			else
				-- The game keeps an icon for most effects; the ones without stay as words so
				-- they are not quietly dropped from the tag altogether.
				local ok, meta = pcall(function() return bedwars.StatusEffectMeta[name] end)
				effects[#effects + 1] = {label = label, image = ok and meta and meta.image or nil}
			end
		end
	
		table.sort(enchants)
		table.sort(effects, function(a, b) return a.label < b.label end)
		return enchants, effects
	end
	
	-- One group rendered, capped, with the overflow counted rather than dropped silently.
	local function statusText(list, color)
		if not list or #list == 0 then return '' end
	
		local shown = list
		if #list > STATUS_SHOWN then
			shown = table.move(list, 1, STATUS_SHOWN, 1, {})
			shown[STATUS_SHOWN + 1] = '+' .. (#list - STATUS_SHOWN)
		end
	
		local text = ' [' .. table.concat(shown, '] [') .. ']'
		return color and ('<font color="' .. color .. '">' .. text .. '</font>') or text
	end
	
	-- Both groups appended to a tag, in whichever form the current renderer wants.
	local function appendStatus(ent, text, rich)
		if not ((Enchants and Enchants.Enabled) or (Effects and Effects.Enabled)) then return text end
	
		local enchants, effects = statusOf(ent)
		if Enchants and Enchants.Enabled then
			text = text .. statusText(enchants, rich and '#d0a3ff')
		end
		--[[
			Effects are drawn as icons rather than written out, so nothing is appended here for
			them in the rich renderer. The Drawing renderer has no way to place an image, so it
			keeps the words.
		]]
		if Effects and Effects.Enabled and not rich then
			local words = {}
			for _, effect in effects do
				words[#words + 1] = effect.label
			end
			text = text .. statusText(words)
		end
		return text
	end
	
	--[[
		The in-game ranked division - Diamond, Platinum, Nightmare.
	
		It is on neither the player nor the character. The game asks the server for it through
		a FetchRanks call and keeps the answers in its own RankController cache, so this asks
		that same controller, once per player, and keeps the answer for the round.
	
		A player with no ranked history answers with nothing, stored as false so they are not
		asked about again on every sweep.
	]]
	local Divisions = {}
	local DivisionFetching = false
	local DivisionsChanged = false
	
	local function divisionOf(plr)
		local division = Divisions[plr.UserId]
		if not division and division ~= 0 then return end
	
		local ok, meta = pcall(function() return bedwars.RankMeta[division] end)
		if not ok or type(meta) ~= 'table' then return end
	
		-- The tier rather than the division, so it reads Diamond rather than Diamond 2.
		local tier = meta.tier
		return type(tier) == 'string' and (tier:sub(1, 1):upper() .. tier:sub(2)) or meta.name
	end
	
	-- The game's own badge for a division, rather than the word for it.
	local function divisionImage(plr)
		local division = Divisions[plr.UserId]
		if not division and division ~= 0 then return end
	
		local ok, meta = pcall(function() return bedwars.RankMeta[division] end)
		if not ok or type(meta) ~= 'table' then return end
		return meta.image
	end
	
	local MEASURE = Vector2.new(100000, 100000)
	
	--[[
		A run of spaces standing in for the badge.
	
		RichText cannot place an image inline, so the badge is a child image laid over a gap
		held open in the text. The gap is measured in spaces at the tag's own font and size, so
		it stays the right width at any Scale rather than being a fixed guess.
	]]
	local function rankGap(ent, textSize, font)
		if not (Rank and Rank.Enabled) or not ent.Player or not divisionImage(ent.Player) then return '' end
	
		local space = getfontsize(' ', textSize, font, MEASURE).X
		if space <= 0 then return ' ' end
	
		local height = getfontsize('X', textSize, font, MEASURE).Y + 7
		return string.rep(' ', math.max(1, math.ceil((height + 2) / space)))
	end
	
	-- The badge dropped into that gap. The text before it is measured as drawn, so the badge
	-- lands between the distance and the name however wide the distance happens to be.
	local function placeRankIcon(nametag, ent, prefix)
		local icon = nametag:FindFirstChild('RankIcon')
		if not icon then return end
	
		local image = (Rank and Rank.Enabled) and ent.Player and divisionImage(ent.Player) or nil
		icon.Image = image or ''
		icon.Visible = image ~= nil
		if not image then return end
	
		local height = nametag.Size.Y.Offset
		icon.Size = UDim2.fromOffset(height, height)
		-- 4 is the tag's own left padding: it is sized to the text plus 8, centred.
		icon.Position = UDim2.new(0, 4 + getfontsize(removeTags(prefix or ''), nametag.TextSize, nametag.FontFace, MEASURE).X, 0.5, 0)
	end
	
	-- Everyone not asked about yet, in one call rather than one call each.
	local function fetchDivisions()
		if DivisionFetching or not (Rank and Rank.Enabled) then return end
	
		local ids = {}
		for _, plr in playersService:GetPlayers() do
			if Divisions[plr.UserId] == nil then
				ids[#ids + 1] = plr.UserId
			end
		end
		if #ids == 0 then return end
	
		DivisionFetching = true
		task.spawn(function()
			local ok, result = pcall(function()
				return bedwars.RankController:getRanks(ids):expect()
			end)
			DivisionFetching = false
	
			-- A failed call leaves them unasked so the next sweep tries again, rather than
			-- marking them rankless and never looking at them a second time.
			if not ok or type(result) ~= 'table' then return end
	
			for _, id in ids do
				Divisions[id] = false
			end
			for _, entry in result do
				if type(entry) == 'table' and entry.userId then
					Divisions[entry.userId] = entry.rankDivision or false
				end
			end
	
			-- Left for the render loop to act on. Rebuilding here would mean naming Updated,
			-- which is declared further down the file, so the name would reach a global that
			-- does not exist rather than the table meant.
			DivisionsChanged = true
		end)
	end
	
	-- True once per interval for the whole set, rather than each entity keeping its own
	-- clock, so one pass re-reads everyone or nobody.
	local function statusDue()
		local now = os.clock()
		if now < StatusNext then return false end
		StatusNext = now + STATUS_POLL
		return true
	end
	
	-- The set of what is showing, as one string, so the loop can tell a real change from a
	-- re-read that found exactly the same thing and skip the rebuild.
	local function statusSignature(ent)
		local enchants, effects = statusOf(ent)
		if not enchants then return '' end
	
		local words = {}
		for _, effect in effects do
			words[#words + 1] = effect.label
		end
		return table.concat(enchants, ',') .. '|' .. table.concat(words, ',')
	end
	
	--[[
		The row of effect icons that sits above the name.
	
		Rebuilt whole rather than reconciled: there are only ever a handful, and the set
		changes rarely enough that tracking which one moved costs more than it saves.
	]]
	local function drawEffects(nametag, ent)
		local strip = nametag:FindFirstChild('Effects')
		if not strip then return end
	
		strip:ClearAllChildren()
	
		local layout = Instance.new('UIListLayout')
		layout.FillDirection = Enum.FillDirection.Horizontal
		layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
		layout.VerticalAlignment = Enum.VerticalAlignment.Bottom
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Padding = UDim.new(0, 2)
		layout.Parent = strip
	
		if not (Effects and Effects.Enabled) then
			strip.Visible = false
			return
		end
	
		local _, effects = statusOf(ent)
		if not effects or #effects == 0 then
			strip.Visible = false
			return
		end
	
		local size = math.max(10, math.floor(18 * Scale.Value))
		local shown = 0
	
		for _, effect in effects do
			if shown >= STATUS_SHOWN then break end
			shown += 1
	
			if effect.image then
				local icon = Instance.new('ImageLabel')
				icon.BackgroundTransparency = 1
				icon.Size = UDim2.fromOffset(size, size)
				icon.Image = effect.image
				icon.LayoutOrder = shown
				icon.Parent = strip
			else
				local word = Instance.new('TextLabel')
				word.BackgroundTransparency = 1
				word.AutomaticSize = Enum.AutomaticSize.X
				word.Size = UDim2.fromOffset(0, size)
				word.Text = effect.label
				word.TextColor3 = Color3.new(1, 1, 1)
				word.TextStrokeTransparency = 0.4
				word.TextSize = math.max(8, math.floor(size * 0.6))
				word.FontFace = nametag.FontFace
				word.LayoutOrder = shown
				word.Parent = strip
			end
		end
	
		strip.Size = UDim2.fromOffset(0, size)
		strip.Visible = shown > 0
	end
	
	local Added = {
		Normal = function(ent)
			if not Targets.Players.Enabled and ent.Player then return end
			if not Targets.NPCs.Enabled and ent.NPC then return end
			if Teammates.Enabled and (not ent.Targetable) and (not ent.Friend) then return end
	
			local nametag = Instance.new('TextLabel')
			Strings[ent] = ent.Player and whitelist:tag(ent.Player, true, true)..(DisplayName.Enabled and ent.Player.DisplayName or ent.Player.Name) or ent.Character.Name
	
			if Device.Enabled and ent.Player then
				local executor = (identifyexecutor and identifyexecutor() or {'Unknown'})[1] or 'Unknown'
				local deviceIcon = executor:find('Mobile') and '📱' or '💻'
				Strings[ent] = Strings[ent]..' '..deviceIcon
			end
	
			if Health.Enabled then
				local healthColor = Color3.fromHSV(math.clamp(ent.Health / ent.MaxHealth, 0, 1) / 2.5, 0.89, 0.75)
				Strings[ent] = Strings[ent]..' <font color="rgb('..tostring(math.floor(healthColor.R * 255))..','..tostring(math.floor(healthColor.G * 255))..','..tostring(math.floor(healthColor.B * 255))..')">'..math.round(ent.Health)..'</font>'
			end
	
			Strings[ent] = appendStatus(ent, Strings[ent], true)
	
			-- The badge sits between the distance and the name, so the distance is kept aside
			-- as the run of text the badge has to clear.
			Prefixes[ent] = Distance.Enabled and '<font color="rgb(85, 255, 85)">[</font><font color="rgb(255, 255, 255)">%s</font><font color="rgb(85, 255, 85)">]</font> ' or ''
			Strings[ent] = Prefixes[ent]..rankGap(ent, 14 * Scale.Value, FontOption.Value)..Strings[ent]
	
			if Equipment.Enabled then
				for i, v in {'Hand', 'Helmet', 'Chestplate', 'Boots', 'Kit'} do
					local Icon = Instance.new('ImageLabel')
					Icon.Name = v
					Icon.Size = UDim2.fromOffset(30, 30)
					Icon.Position = UDim2.fromOffset(-60 + (i * 30), -30)
					Icon.BackgroundTransparency = 1
					Icon.Image = ''
					Icon.Parent = nametag
				end
			end
	
			nametag.TextSize = 14 * Scale.Value
			nametag.FontFace = FontOption.Value
			local size = getfontsize(removeTags(Strings[ent]), nametag.TextSize, nametag.FontFace, Vector2.new(100000, 100000))
			nametag.Name = ent.Player and ent.Player.Name or ent.Character.Name
			nametag.Size = UDim2.fromOffset(size.X + 8, size.Y + 7)
			nametag.AnchorPoint = Vector2.new(0.5, 1)
			nametag.BackgroundColor3 = Color3.new()
			nametag.BackgroundTransparency = Background.Value
			nametag.BorderSizePixel = 0
			nametag.Visible = false
			nametag.Text = Strings[ent]
	
			local strip = Instance.new('Frame')
			strip.Name = 'Effects'
			strip.AnchorPoint = Vector2.new(0.5, 1)
			strip.Position = UDim2.new(0.5, 0, 0, -2)
			strip.Size = UDim2.fromOffset(0, 0)
			strip.AutomaticSize = Enum.AutomaticSize.X
			strip.BackgroundTransparency = 1
			strip.Visible = false
			strip.Parent = nametag
			drawEffects(nametag, ent)
	
			local rankicon = Instance.new('ImageLabel')
			rankicon.Name = 'RankIcon'
			rankicon.AnchorPoint = Vector2.new(0, 0.5)
			rankicon.BackgroundTransparency = 1
			rankicon.ScaleType = Enum.ScaleType.Fit
			rankicon.Image = ''
			rankicon.Visible = false
			rankicon.Parent = nametag
			-- With a distance showing, the loop places it instead, once the number is in the
			-- text and there is something real to measure.
			if not Distance.Enabled then
				placeRankIcon(nametag, ent, '')
			end
	
			nametag.TextColor3 = entitylib.getEntityColor(ent) or Color3.fromHSV(Color.Hue, Color.Sat, Color.Value)
			nametag.RichText = true
			nametag.Parent = Folder
			Reference[ent] = nametag
		end,
		Drawing = function(ent)
			if not Targets.Players.Enabled and ent.Player then return end
			if not Targets.NPCs.Enabled and ent.NPC then return end
			if Teammates.Enabled and (not ent.Targetable) and (not ent.Friend) then return end
	
			local nametag = {}
			nametag.BG = Drawing.new('Square')
			nametag.BG.Filled = true
			nametag.BG.Transparency = 1 - Background.Value
			nametag.BG.Color = Color3.new()
			nametag.BG.ZIndex = 1
			nametag.Text = Drawing.new('Text')
			nametag.Text.Size = 15 * Scale.Value
			nametag.Text.Font = 0
			nametag.Text.ZIndex = 2
			Strings[ent] = ent.Player and whitelist:tag(ent.Player, true)..(DisplayName.Enabled and ent.Player.DisplayName or ent.Player.Name) or ent.Character.Name
	
			if Rank.Enabled and ent.Player then
				local division = divisionOf(ent.Player)
				if division then
					Strings[ent] = Strings[ent]..' '..division
				end
			end
	
			if Device.Enabled and ent.Player then
				local executor = (identifyexecutor and identifyexecutor() or {'Unknown'})[1] or 'Unknown'
				local deviceIcon = executor:find('Mobile') and '📱' or '💻'
				Strings[ent] = Strings[ent]..' '..deviceIcon
			end
	
			if Health.Enabled then
				Strings[ent] = Strings[ent]..' '..math.round(ent.Health)
			end
	
			Strings[ent] = appendStatus(ent, Strings[ent], false)
	
			if Distance.Enabled then
				Strings[ent] = '[%s] '..Strings[ent]
			end
	
			nametag.Text.Text = Strings[ent]
			nametag.Text.Color = entitylib.getEntityColor(ent) or Color3.fromHSV(Color.Hue, Color.Sat, Color.Value)
			nametag.BG.Size = Vector2.new(nametag.Text.TextBounds.X + 8, nametag.Text.TextBounds.Y + 7)
			Reference[ent] = nametag
		end
	}
	
	local Removed = {
		Normal = function(ent)
			local v = Reference[ent]
			if v then
				Reference[ent] = nil
				Strings[ent] = nil
				Sizes[ent] = nil
				Prefixes[ent] = nil
				StatusSig[ent] = nil
				v:Destroy()
			end
		end,
		Drawing = function(ent)
			local v = Reference[ent]
			if v then
				Reference[ent] = nil
				Strings[ent] = nil
				Sizes[ent] = nil
				Prefixes[ent] = nil
				StatusSig[ent] = nil
				for _, obj in v do
					pcall(function()
						obj.Visible = false
						obj:Remove()
					end)
				end
			end
		end
	}
	
	local Updated = {
		Normal = function(ent)
			local nametag = Reference[ent]
			if nametag then
				Sizes[ent] = nil
				Strings[ent] = ent.Player and whitelist:tag(ent.Player, true, true)..(DisplayName.Enabled and ent.Player.DisplayName or ent.Player.Name) or ent.Character.Name
	
				if Device.Enabled and ent.Player then
					local executor = (identifyexecutor and identifyexecutor() or {'Unknown'})[1] or 'Unknown'
					local deviceIcon = executor:find('Mobile') and '📱' or '💻'
					Strings[ent] = Strings[ent]..' '..deviceIcon
				end
	
				if Health.Enabled then
					local healthColor = Color3.fromHSV(math.clamp(ent.Health / ent.MaxHealth, 0, 1) / 2.5, 0.89, 0.75)
					Strings[ent] = Strings[ent]..' <font color="rgb('..tostring(math.floor(healthColor.R * 255))..','..tostring(math.floor(healthColor.G * 255))..','..tostring(math.floor(healthColor.B * 255))..')">'..math.round(ent.Health)..'</font>'
				end
	
				Strings[ent] = appendStatus(ent, Strings[ent], true)
	
				Prefixes[ent] = Distance.Enabled and '<font color="rgb(85, 255, 85)">[</font><font color="rgb(255, 255, 255)">%s</font><font color="rgb(85, 255, 85)">]</font> ' or ''
				Strings[ent] = Prefixes[ent]..rankGap(ent, nametag.TextSize, nametag.FontFace)..Strings[ent]
	
				if Equipment.Enabled and store.inventories[ent.Player] then
					local kit = ent.Player:GetAttribute('PlayingAsKit')
					local inventory = store.inventories[ent.Player]
					nametag.Hand.Image = bedwars.getIcon(inventory.hand or {itemType = ''}, true)
					nametag.Helmet.Image = bedwars.getIcon(inventory.armor[4] or {itemType = ''}, true)
					nametag.Chestplate.Image = bedwars.getIcon(inventory.armor[5] or {itemType = ''}, true)
					nametag.Boots.Image = bedwars.getIcon(inventory.armor[6] or {itemType = ''}, true)
					nametag.Kit.Image = kit and kit ~= 'none' and bedwars.BedwarsKitMeta[kit].renderImage or ''
				end
	
				local size = getfontsize(removeTags(Strings[ent]), nametag.TextSize, nametag.FontFace, Vector2.new(100000, 100000))
				nametag.Size = UDim2.fromOffset(size.X + 8, size.Y + 7)
				nametag.Text = Strings[ent]
				drawEffects(nametag, ent)
				-- Placed here only when there is no distance to measure around; otherwise the
				-- loop does it, once the number is actually in the text.
				if not Distance.Enabled then
					placeRankIcon(nametag, ent, '')
				end
			end
		end,
		Drawing = function(ent)
			local nametag = Reference[ent]
			if nametag then
				if vain.ThreadFix then
					setthreadidentity(8)
				end
				Sizes[ent] = nil
				Strings[ent] = ent.Player and whitelist:tag(ent.Player, true)..(DisplayName.Enabled and ent.Player.DisplayName or ent.Player.Name) or ent.Character.Name
	
				if Rank.Enabled and ent.Player then
					local division = divisionOf(ent.Player)
					if division then
						Strings[ent] = Strings[ent]..' '..division
					end
				end
	
				if Device.Enabled and ent.Player then
					local executor = (identifyexecutor and identifyexecutor() or {'Unknown'})[1] or 'Unknown'
					local deviceIcon = executor:find('Mobile') and '📱' or '💻'
					Strings[ent] = Strings[ent]..' '..deviceIcon
				end
	
				if Health.Enabled then
					Strings[ent] = Strings[ent]..' '..math.round(ent.Health)
				end
	
				Strings[ent] = appendStatus(ent, Strings[ent], false)
	
				if Distance.Enabled then
					Strings[ent] = '[%s] '..Strings[ent]
					nametag.Text.Text = entitylib.isAlive and string.format(Strings[ent], math.floor((entitylib.character.RootPart.Position - ent.RootPart.Position).Magnitude)) or Strings[ent]
				else
					nametag.Text.Text = Strings[ent]
				end
	
				nametag.BG.Size = Vector2.new(nametag.Text.TextBounds.X + 8, nametag.Text.TextBounds.Y + 7)
				nametag.Text.Color = entitylib.getEntityColor(ent) or Color3.fromHSV(Color.Hue, Color.Sat, Color.Value)
			end
		end
	}
	
	local ColorFunc = {
		Normal = function(hue, sat, val)
			local color = Color3.fromHSV(hue, sat, val)
			for i, v in Reference do
				v.TextColor3 = entitylib.getEntityColor(i) or color
			end
		end,
		Drawing = function(hue, sat, val)
			local color = Color3.fromHSV(hue, sat, val)
			for i, v in Reference do
				v.Text.Color = entitylib.getEntityColor(i) or color
			end
		end
	}
	
	local Loop = {
		Normal = function()
			local due = statusDue()
			if due then
				fetchDivisions()
				if DivisionsChanged then
					DivisionsChanged = false
					for ent in Reference do
						Updated[methodused](ent)
					end
				end
			end
			for ent, nametag in Reference do
				if due and ((Enchants and Enchants.Enabled) or (Effects and Effects.Enabled)) then
					local sig = statusSignature(ent)
					if StatusSig[ent] ~= sig then
						StatusSig[ent] = sig
						Updated[methodused](ent)
					end
				end
	
				if DistanceCheck.Enabled then
					local distance = entitylib.isAlive and (entitylib.character.RootPart.Position - ent.RootPart.Position).Magnitude or math.huge
					if distance < DistanceLimit.ValueMin or distance > DistanceLimit.ValueMax then
						nametag.Visible = false
						continue
					end
				end
	
				local headPos, headVis = gameCamera:WorldToViewportPoint(ent.RootPart.Position + Vector3.new(0, ent.HipHeight + 1, 0))
				nametag.Visible = headVis
				if not headVis then
					continue
				end
	
				if Distance.Enabled then
					local mag = entitylib.isAlive and math.floor((entitylib.character.RootPart.Position - ent.RootPart.Position).Magnitude) or 0
					if Sizes[ent] ~= mag then
						nametag.Text = string.format(Strings[ent], mag)
						local ize = getfontsize(removeTags(nametag.Text), nametag.TextSize, nametag.FontFace, Vector2.new(100000, 100000))
						nametag.Size = UDim2.fromOffset(ize.X + 8, ize.Y + 7)
						Sizes[ent] = mag
						-- Only when the number changed, so the badge is not re-measured every frame.
						placeRankIcon(nametag, ent, string.format(Prefixes[ent] or '', mag))
					end
				end
				nametag.Position = UDim2.fromOffset(headPos.X, headPos.Y)
			end
		end,
		Drawing = function()
			local due = statusDue()
			if due then
				fetchDivisions()
				if DivisionsChanged then
					DivisionsChanged = false
					for ent in Reference do
						Updated[methodused](ent)
					end
				end
			end
			for ent, nametag in Reference do
				if due and ((Enchants and Enchants.Enabled) or (Effects and Effects.Enabled)) then
					local sig = statusSignature(ent)
					if StatusSig[ent] ~= sig then
						StatusSig[ent] = sig
						Updated[methodused](ent)
					end
				end
	
				if DistanceCheck.Enabled then
					local distance = entitylib.isAlive and (entitylib.character.RootPart.Position - ent.RootPart.Position).Magnitude or math.huge
					if distance < DistanceLimit.ValueMin or distance > DistanceLimit.ValueMax then
						nametag.Text.Visible = false
						nametag.BG.Visible = false
						continue
					end
				end
	
				local headPos, headVis = gameCamera:WorldToViewportPoint(ent.RootPart.Position + Vector3.new(0, ent.HipHeight + 1, 0))
				nametag.Text.Visible = headVis
				nametag.BG.Visible = headVis
				if not headVis then
					continue
				end
	
				if Distance.Enabled then
					local mag = entitylib.isAlive and math.floor((entitylib.character.RootPart.Position - ent.RootPart.Position).Magnitude) or 0
					if Sizes[ent] ~= mag then
						nametag.Text.Text = string.format(Strings[ent], mag)
						nametag.BG.Size = Vector2.new(nametag.Text.TextBounds.X + 8, nametag.Text.TextBounds.Y + 7)
						Sizes[ent] = mag
					end
				end
				nametag.BG.Position = Vector2.new(headPos.X - (nametag.BG.Size.X / 2), headPos.Y - nametag.BG.Size.Y)
				nametag.Text.Position = nametag.BG.Position + Vector2.new(4, 3)
			end
		end
	}
	
	NameTags = vain.Categories.Render:CreateModule({
		Name = 'NameTags',
		Function = function(callback)
			if callback then
				methodused = DrawingToggle.Enabled and 'Drawing' or 'Normal'
				if Removed[methodused] then
					NameTags:Clean(entitylib.Events.EntityRemoved:Connect(Removed[methodused]))
				end
				if Added[methodused] then
					for _, v in entitylib.List do
						if Reference[v] then
							Removed[methodused](v)
						end
						Added[methodused](v)
					end
					NameTags:Clean(entitylib.Events.EntityAdded:Connect(function(ent)
						if Reference[ent] then
							Removed[methodused](ent)
						end
						Added[methodused](ent)
					end))
				end
				if Updated[methodused] then
					NameTags:Clean(entitylib.Events.EntityUpdated:Connect(Updated[methodused]))
					for _, v in entitylib.List do
						Updated[methodused](v)
					end
				end
				if ColorFunc[methodused] then
					NameTags:Clean(vain.Categories.Friends.ColorUpdate.Event:Connect(function()
						ColorFunc[methodused](Color.Hue, Color.Sat, Color.Value)
					end))
				end
				if Loop[methodused] then
					NameTags:Clean(runService.RenderStepped:Connect(Loop[methodused]))
				end
			else
				if Removed[methodused] then
					for i in Reference do
						Removed[methodused](i)
					end
				end
			end
		end,
		Tooltip = 'Renders nametags on entities through walls.'
	})
	Targets = NameTags:CreateTargets({
		Players = true,
		Function = function()
			if NameTags.Enabled then
				NameTags:Toggle()
				NameTags:Toggle()
			end
		end,
		Tooltip = 'Which entities this module is allowed to target'
	})
	FontOption = NameTags:CreateFont({
		Name = 'Font',
		Tooltip = 'Font used for the text',
		Blacklist = 'Arial',
		Function = function()
			if NameTags.Enabled then
				NameTags:Toggle()
				NameTags:Toggle()
			end
		end
	})
	Color = NameTags:CreateColorSlider({
		Name = 'Player Color',
		Tooltip = 'Color of the name text',
		Function = function(hue, sat, val)
			if NameTags.Enabled and ColorFunc[methodused] then
				ColorFunc[methodused](hue, sat, val)
			end
		end
	})
	Scale = NameTags:CreateSlider({
		Name = 'Scale',
		Tooltip = 'Size of the nametag',
		Function = function()
			if NameTags.Enabled then
				NameTags:Toggle()
				NameTags:Toggle()
			end
		end,
		Default = 1,
		Min = 0.1,
		Max = 1.5,
		Decimal = 10
	})
	Background = NameTags:CreateSlider({
		Name = 'Transparency',
		Tooltip = 'How see-through the nametag is',
		Function = function()
			if NameTags.Enabled then
				NameTags:Toggle()
				NameTags:Toggle()
			end
		end,
		Default = 0.5,
		Min = 0,
		Max = 1,
		Decimal = 10
	})
	Health = NameTags:CreateToggle({
		Name = 'Health',
		Tooltip = 'Shows the target health',
		Function = function()
			if NameTags.Enabled then
				NameTags:Toggle()
				NameTags:Toggle()
			end
		end
	})
	Distance = NameTags:CreateToggle({
		Name = 'Distance',
		Tooltip = 'Shows how far away the player is',
		Function = function()
			if NameTags.Enabled then
				NameTags:Toggle()
				NameTags:Toggle()
			end
		end
	})
	Equipment = NameTags:CreateToggle({
		Name = 'Equipment',
		Tooltip = 'Shows what the player is holding and wearing',
		Function = function()
			if NameTags.Enabled then
				NameTags:Toggle()
				NameTags:Toggle()
			end
		end
	})
	DisplayName = NameTags:CreateToggle({
		Name = 'Use Displayname',
		Tooltip = 'Shows display names instead of usernames',
		Function = function()
			if NameTags.Enabled then
				NameTags:Toggle()
				NameTags:Toggle()
			end
		end,
		Default = true
	})
	Teammates = NameTags:CreateToggle({
		Name = 'Priority Only',
		Tooltip = 'Hides teammates and non targetable entities',
		Function = function()
			if NameTags.Enabled then
				NameTags:Toggle()
				NameTags:Toggle()
			end
		end,
		Default = true
	})
	DrawingToggle = NameTags:CreateToggle({
		Name = 'Drawing',
		Tooltip = 'Renders with the Drawing API instead of Roblox instances',
		Function = function()
			if NameTags.Enabled then
				NameTags:Toggle()
				NameTags:Toggle()
			end
		end,
	})
	DistanceCheck = NameTags:CreateToggle({
		Name = 'Distance Check',
		Tooltip = 'Only shows players within a set distance',
		Function = function(callback)
			DistanceLimit.Object.Visible = callback
		end
	})
	DistanceLimit = NameTags:CreateTwoSlider({
		Name = 'Player Distance',
		Tooltip = 'Distance range a player must be within',
		Min = 0,
		Max = 256,
		DefaultMin = 0,
		DefaultMax = 64,
		Darker = true,
		Visible = false
	})
	Rank = NameTags:CreateToggle({
		Name = 'Rank',
		Tooltip = 'Shows their ranked division like Diamond or Nightmare',
		Function = function()
			fetchDivisions()
			if NameTags.Enabled then
				NameTags:Toggle()
				NameTags:Toggle()
			end
		end
	})
	Enchants = NameTags:CreateToggle({
		Name = 'Enchantments',
		Tooltip = 'Shows the enchantments they have active',
		Function = function()
			if NameTags.Enabled then
				NameTags:Toggle()
				NameTags:Toggle()
			end
		end
	})
	Effects = NameTags:CreateToggle({
		Name = 'Effects',
		Tooltip = 'Shows their active effects like jump, pie or gloop',
		Function = function()
			if NameTags.Enabled then
				NameTags:Toggle()
				NameTags:Toggle()
			end
		end
	})
	Device = NameTags:CreateToggle({
		Name = 'Device',
		Tooltip = 'Shows executor type with an icon',
		Function = function()
			if NameTags.Enabled then
				NameTags:Toggle()
				NameTags:Toggle()
			end
		end
	})
end)

run(function()
	local StorageESP
	local List
	local Background
	local Color = {}
	local ShowAmount
	local ShowAll
	local Reference = {}
	local Folder = Instance.new('Folder')
	Folder.Parent = vain.gui
	
	-- Settings are created after CreateModule returns, so they can still be nil while
	-- this file is executing - and the module can be switched on inside that window
	-- when the GUI restores a saved config. Reading .Enabled straight off them threw.
	local function on(setting)
		return setting ~= nil and setting.Enabled
	end
	
	local function nearStorageItem(item)
		for _, v in List.ListEnabled do
			if item:find(v) then return v end
		end
	end
	
	local function refreshAdornee(v)
		local chest = v.Adornee:FindFirstChild('ChestFolderValue')
		chest = chest and chest.Value or nil
		if not chest then
			v.Enabled = false
			return
		end
	
		local chestitems = chest and chest:GetChildren() or {}
		for _, obj in v.Frame:GetChildren() do
			if obj:IsA('ImageLabel') and obj.Name ~= 'Blur' then
				obj:Destroy()
			end
		end
	
		v.Enabled = false
	
		--[[
			Tallied first, drawn second.
	
			How many of something a chest holds is an Amount attribute on the item, not a child
			of it - looking for a child called Value found nothing, every time, which is why no
			number was ever drawn.
	
			A chest can also hold the same item in more than one stack, so the amounts are
			summed. Reading only the first stack, the way the old dedup did, would under-report
			anything that arrived in separate drops.
		]]
		local order, totals = {}, {}
		for _, item in chestitems do
			--[[
				A child with no Amount is not an item.
	
				Every item the game builds is given one, defaulting to 1, so anything in the
				folder without it is the chest's own furniture rather than loot. Counting those
				as one apiece drew a phantom entry with a blank icon and a made-up count.
			]]
			local amount = item:GetAttribute('Amount')
			if type(amount) ~= 'number' then continue end
	
			-- ShowAll displays all items regardless of the list; otherwise use the filter
			local shouldShow = on(ShowAll) or table.find(List.ListEnabled, item.Name) or nearStorageItem(item.Name)
			if not shouldShow then continue end
	
			if totals[item.Name] == nil then
				order[#order + 1] = item.Name
				totals[item.Name] = 0
			end
			totals[item.Name] = totals[item.Name] + amount
		end
	
		for _, name in order do
			v.Enabled = true
			local blockimage = Instance.new('ImageLabel')
			blockimage.Size = UDim2.fromOffset(32, 32)
			blockimage.BackgroundTransparency = 1
			blockimage.Image = bedwars.getIcon({itemType = name}, true)
			blockimage.Parent = v.Frame
	
			if on(ShowAmount) then
				-- An endless supply reads as a symbol rather than as 'inf', and a count that
				-- is not a number at all is left off instead of printed as nonsense.
				local total = totals[name]
				local text = total == total and (math.abs(total) == math.huge and '\u{221E}' or tostring(total)) or nil
	
				local textlabel = Instance.new('TextLabel')
				textlabel.Name = 'Amount'
				textlabel.Size = UDim2.fromOffset(16, 16)
				textlabel.Position = UDim2.fromOffset(16, 16)
				textlabel.BackgroundColor3 = Color3.new(0, 0, 0)
				textlabel.BackgroundTransparency = 0.3
				textlabel.TextColor3 = Color3.new(1, 1, 1)
				textlabel.TextSize = 12
				textlabel.Text = text or ''
				textlabel.Visible = text ~= nil
				textlabel.Parent = blockimage
				local corner = Instance.new('UICorner')
				corner.CornerRadius = UDim.new(0, 2)
				corner.Parent = textlabel
			end
		end
		table.clear(chestitems)
	end
	
	local function Added(v)
		local chest = v:WaitForChild('ChestFolderValue', 3)
		if not (chest and StorageESP.Enabled) then return end
		chest = chest.Value
		local billboard = Instance.new('BillboardGui')
		billboard.Parent = Folder
		billboard.Name = 'chest'
		billboard.StudsOffsetWorldSpace = Vector3.new(0, 3, 0)
		billboard.Size = UDim2.fromOffset(36, 36)
		billboard.AlwaysOnTop = true
		billboard.ClipsDescendants = false
		billboard.Adornee = v
		local blur = addBlur(billboard)
		blur.Visible = on(Background)
		local frame = Instance.new('Frame')
		frame.Size = UDim2.fromScale(1, 1)
		frame.BackgroundColor3 = Color3.fromHSV(Color.Hue, Color.Sat, Color.Value)
		frame.BackgroundTransparency = 1 - (on(Background) and (Color.Opacity or 0.5) or 0)
		frame.Parent = billboard
		local layout = Instance.new('UIListLayout')
		layout.FillDirection = Enum.FillDirection.Horizontal
		layout.Padding = UDim.new(0, 4)
		layout.VerticalAlignment = Enum.VerticalAlignment.Center
		layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
		layout:GetPropertyChangedSignal('AbsoluteContentSize'):Connect(function()
			billboard.Size = UDim2.fromOffset(math.max(layout.AbsoluteContentSize.X + 4, 36), 36)
		end)
		layout.Parent = frame
		local corner = Instance.new('UICorner')
		corner.CornerRadius = UDim.new(0, 4)
		corner.Parent = frame
		Reference[v] = billboard
	
		-- Taking part of a stack changes the item's Amount without the folder gaining or
		-- losing a child, so ChildAdded alone would leave the number showing what was there
		-- when the chest was first looked at.
		local function watchAmount(item)
			StorageESP:Clean(item:GetAttributeChangedSignal('Amount'):Connect(function()
				refreshAdornee(billboard)
			end))
		end
		for _, item in chest:GetChildren() do
			watchAmount(item)
		end
	
		StorageESP:Clean(chest.ChildAdded:Connect(function(item)
			watchAmount(item)
			if on(ShowAll) or table.find(List.ListEnabled, item.Name) or nearStorageItem(item.Name) then
				refreshAdornee(billboard)
			end
		end))
		StorageESP:Clean(chest.ChildRemoved:Connect(function(item)
			if on(ShowAll) or table.find(List.ListEnabled, item.Name) or nearStorageItem(item.Name) then
				refreshAdornee(billboard)
			end
		end))
		task.spawn(refreshAdornee, billboard)
	end
	
	StorageESP = vain.Categories.Render:CreateModule({
		Name = 'StorageESP',
		Function = function(callback)
			if callback then
				StorageESP:Clean(collectionService:GetInstanceAddedSignal('chest'):Connect(Added))
				for _, v in collectionService:GetTagged('chest') do
					task.spawn(Added, v)
				end
			else
				table.clear(Reference)
				Folder:ClearAllChildren()
			end
		end,
		Tooltip = 'Displays items in chests'
	})
	List = StorageESP:CreateTextList({
		Name = 'Item',
		Tooltip = 'Which items this applies to',
		Function = function()
			for _, v in Reference do
				task.spawn(refreshAdornee, v)
			end
		end
	})
	Background = StorageESP:CreateToggle({
		Name = 'Background',
		Tooltip = 'Draws a background behind the text',
		Function = function(callback)
			if Color.Object then Color.Object.Visible = callback end
			for _, v in Reference do
				v.Frame.BackgroundTransparency = 1 - (callback and Color.Opacity or 0)
				v.Blur.Visible = callback
			end
		end,
		Default = true
	})
	Color = StorageESP:CreateColorSlider({
		Name = 'Background Color',
		Tooltip = 'Color of the background',
		DefaultValue = 0,
		DefaultOpacity = 0.5,
		Function = function(hue, sat, val, opacity)
			for _, v in Reference do
				v.Frame.BackgroundColor3 = Color3.fromHSV(hue, sat, val)
				v.Frame.BackgroundTransparency = 1 - opacity
			end
		end,
		Darker = true
	})
	ShowAmount = StorageESP:CreateToggle({
		Name = 'Show Amount',
		Tooltip = 'Displays the quantity of each item in the corner',
		Function = function()
			for _, v in Reference do
				task.spawn(refreshAdornee, v)
			end
		end
	})
	ShowAll = StorageESP:CreateToggle({
		Name = 'Show All',
		Tooltip = 'Shows all items instead of only those in the list',
		Function = function()
			for _, v in Reference do
				task.spawn(refreshAdornee, v)
			end
		end
	})
end)

run(function()
	-- Stops melee landing on you by moving the part the server tracks you by, rather than
	-- by trying to spoof where your character is.
	--
	-- Spoofing position cannot work: replication is one channel, so an offset moves the
	-- server's copy of you and every attacker's copy together - their sword query finds you
	-- at the offset, they swing there, the server agrees. And an offset large enough to
	-- clear sword reach is large enough for the character movement checks to correct, which
	-- is the lagback.
	--
	-- This sidesteps both. The real HumanoidRootPart is taken out of the character and left
	-- in the workspace as a loose part you still own, with a clone put in its place as the
	-- character's PrimaryPart. Your character, camera and movement all run on the clone and
	-- behave completely normally, while the real root - which is the instance the entity
	-- system and hit detection identify you by - is dragged below the map. Character
	-- movement validation does not apply to it, because as far as the game is concerned it
	-- is no longer part of your character.
	--
	-- Derived from the Anti Hit module in the older VainV6 client.
	local AntiMelee
	local Targets
	local Range
	local oldroot, clone, hip
	local dodging = false
	local lowestPoint = -math.huge
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Include
	rayParams.RespectCanCollide = true
	
	-- Your own attacks are validated against the server's copy of you, which is the root
	-- being held below the map, so a swing sent while it is buried gets rejected.
	--
	-- Keying the stand-down to lastSwing / lastAttack does not work, and an earlier version
	-- here did exactly that: those fields only update once a swing has already been sent,
	-- so the root was being parked after the server had already rejected it. Your own hits
	-- never landed, however long the window was.
	--
	-- Parking has to lead the swing, not follow it, and nothing can tell us a swing is
	-- coming - so the root alternates on a fixed cycle, the way the original client did.
	--
	-- A blind cycle trades one against the other: a longer buried stretch blocks more of
	-- their hits and drops more of yours. The way out is that your swings are the one thing
	-- whose timing is ours to choose. AntiMelee publishes whether the root is parked, and
	-- Killaura holds its attack until it is, so your hits only ever go out during a parked
	-- window. That makes nearly all of them land while leaving the root buried for most of
	-- the cycle.
	--
	-- The cycle is a little under a sword's attack speed, so a parked window always comes
	-- round before Killaura is ready to swing again and nothing is lost waiting.
	-- Parking is driven by demand rather than a clock. A fixed cycle exposed you for a set
	-- share of every second no matter what, and worse, Killaura's own attack cooldown drifts
	-- against a fixed period - its ready moment kept landing inside a buried stretch and
	-- being pushed back another one, so it swung far less often than it should while you
	-- stayed just as exposed. Now the root is buried whenever nothing needs it, and only
	-- surfaces because Killaura has asked to swing.
	--
	-- How long a request stays live. Long enough for the park to settle and the swing to go
	-- out, short enough that a request which never turns into an attack stops holding you up.
	local REQUEST_TIMEOUT = 0.6
	
	-- Never stay surfaced longer than this, however many requests arrive.
	local MAX_PARK = 0.4
	
	-- Toggling the module by hand turned out to work better than leaving it on, which says
	-- the burying is not the only thing doing work here. Both detach and reattach move the
	-- character out to ReplicatedStorage and back, and for that moment it is not in the
	-- workspace at all - so nobody's sword query can find it. Cycling the swap reproduces
	-- that on its own rather than needing it driven by hand.
	local FLICKER_INTERVAL = 0.35
	local lastFlicker = 0
	
	-- Reparenting the character takes it out of the physics world for a moment, and the
	-- humanoid comes back in Freefall having built up downward velocity. Fall damage is
	-- client reported - FallDamageController samples velocity during Freefall and fires
	-- GroundHit with it on landing - so those swaps were being reported as a real fall and
	-- killing you. Anything that moves the character runs through this, which puts the
	-- humanoid back the way it found it.
	local function preserveGround(swap)
		if not entitylib.isAlive then
			swap()
			return
		end
	
		local humanoid = entitylib.character.Humanoid
		local grounded = humanoid.FloorMaterial ~= Enum.Material.Air
		local velocity = entitylib.character.RootPart.AssemblyLinearVelocity
	
		swap()
	
		if not entitylib.isAlive then return end
		pcall(function()
			local root = entitylib.character.RootPart
			-- Carry the velocity across rather than whatever the swap left behind, and never
			-- carry a downward one while grounded - that is the part that becomes damage.
			root.AssemblyLinearVelocity = grounded
				and Vector3.new(velocity.X, math.max(velocity.Y, 0), velocity.Z)
				or velocity
	
			if grounded then
				entitylib.character.Humanoid:ChangeState(Enum.HumanoidStateType.Landed)
			end
		end)
	end
	
	-- Parking the root writes a CFrame; the server does not have that position until it has
	-- been replicated. Announcing the window the instant it opens meant Killaura fired
	-- immediately, while the server still held the buried copy, and the hit was rejected -
	-- which looked like nothing landing at all. Attacks are only allowed once the parked
	-- position has had time to arrive.
	local SETTLE = 0.1
	
	-- How long to keep the root hidden after the last time anyone was in range.
	local LINGER = 1
	local lastNear = 0
	local parkStart = 0
	
	-- Returns whether the root should be buried this pass, and whether an attack may go out.
	-- Surfacing is requested by Killaura through store.antiMeleeWantAttack and cleared by it
	-- once a swing has actually been sent.
	local function evaluate()
		local request = store.antiMeleeWantAttack or 0
		local pending = (tick() - request) < REQUEST_TIMEOUT
	
		if not pending then
			parkStart = 0
			return true, false
		end
	
		if parkStart == 0 then
			parkStart = tick()
		end
	
		local parked = tick() - parkStart
		if parked > MAX_PARK then
			-- Held up too long by a request that never became a swing. Drop it and go back
			-- under rather than staying exposed indefinitely.
			store.antiMeleeWantAttack = nil
			parkStart = 0
			return true, false
		end
	
		-- Surfaced, but an attack is only worth sending once the position has replicated.
		return false, parked >= SETTLE
	end
	
	local function detach()
		if oldroot and oldroot.Parent then return true end
		if not entitylib.isAlive then return false end
	
		local character = lplr.Character
		if not (character and character.Parent) then return false end
	
		local ok = pcall(function()
			hip = entitylib.character.Humanoid.HipHeight
			oldroot = entitylib.character.RootPart
	
			-- Reparented out of the workspace for the swap so the character is never seen
			-- rootless, which would otherwise break the humanoid outright.
			character.Parent = replicatedStorage
			clone = oldroot:Clone()
			clone.Parent = character
			oldroot.Transparency = 1
			oldroot.Parent = workspace
			character.PrimaryPart = clone
			character.Parent = workspace
	
			pcall(function()
				bedwars.QueryUtil:setQueryIgnored(clone, true)
				bedwars.QueryUtil:setQueryIgnored(oldroot, true)
			end)
	
			-- entitylib caches the root instance, and every other module reads position from
			-- it. Left pointing at the detached part they would all be working from a point
			-- under the map, so they are repointed at the clone - which is where you are.
			entitylib.character.RootPart = clone
			entitylib.character.HumanoidRootPart = clone
			store.rootpart = oldroot
		end)
	
		if not ok then
			oldroot, clone = nil, nil
			return false
		end
		return true
	end
	
	local function reattach()
		if not (oldroot and oldroot.Parent) then
			oldroot, clone, store.rootpart = nil, nil, nil
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
				entitylib.character.Humanoid.HipHeight = hip or 2.6
			end
		end)
	
		oldroot, clone, store.rootpart = nil, nil, nil
		dodging = false
		parkStart = 0
		-- Cleared rather than left set, so Killaura is never left waiting on a window that
		-- is no longer being produced, and no stale request is left pending.
		store.antiMeleeParked = nil
		store.antiMeleeWantAttack = nil
	end
	
	AntiMelee = vain.Categories.Utility:CreateModule({
		Name = 'AntiMelee',
		Function = function(callback)
			if callback then
				dodging = false
				lastNear = 0
				parkStart = 0
				lastFlicker = 0
				store.antiMeleeWantAttack = nil
	
				-- Far enough under the lowest block that nothing can reach it. Recomputed on
				-- enable rather than cached across rounds, since the map changes.
				lowestPoint = -math.huge
				pcall(function()
					for _, v in store.blocks do
						local point = (v.Position.Y - (v.Size.Y / 2)) - 50
						if point < lowestPoint or lowestPoint == -math.huge then
							lowestPoint = point
						end
					end
				end)
				if lowestPoint == -math.huge then lowestPoint = -200 end
	
				-- Looked up rather than indexed, and refreshed in the loop below: workspace.Map
				-- does not exist yet in the lobby, and without it the raycast has nothing to
				-- hit, which would leave the module permanently unable to find a safe spot.
				local function refreshMap()
					local map = workspace:FindFirstChild('Map')
					rayParams.FilterDescendantsInstances = map and {map} or {}
					return map ~= nil
				end
				refreshMap()
	
				-- PostSimulation, so the position is written after the engine has finished
				-- moving things and is what actually gets replicated.
				AntiMelee:Clean(runService.PostSimulation:Connect(function()
					if not (oldroot and oldroot.Parent and clone and clone.Parent) then return end
	
					if dodging then
						-- Parking the root at a fixed depth buries it inside whatever geometry
						-- happens to be there, and the game damages you for having your tracked
						-- position inside a block - that is the suffocation. Casting up from
						-- below the map finds the underside of the nearest thing above, and
						-- sitting just beneath that keeps the root in open air. If nothing is
						-- found there is no known-safe spot, so it stops dodging rather than
						-- guessing and killing you.
						local basePos = Vector3.new(clone.CFrame.X, lowestPoint - 6, clone.CFrame.Z)
						local hit = workspace:Raycast(basePos, Vector3.new(0, 1000, 0), rayParams)
						if not hit then
							oldroot.Velocity = Vector3.zero
							oldroot.CFrame = clone.CFrame
							return
						end
	
						oldroot.Velocity = Vector3.zero
						oldroot.CFrame = CFrame.new(basePos.X, hit.Position.Y - 6, basePos.Z)
							* CFrame.Angles(math.rad(90), 0, 0)
					else
						-- Parked on the clone while not dodging, so your own hits and anything
						-- else reading the root line up with where you actually are.
						oldroot.Velocity = Vector3.zero
						oldroot.CFrame = clone.CFrame
					end
				end))
	
				AntiMelee:Clean(entitylib.Events.LocalRemoved:Connect(reattach))
	
				repeat
					local ok = pcall(function()
						if not entitylib.isAlive then
							reattach()
							return
						end
	
						-- Only meaningful where the executor actually implements it; it is
						-- stubbed to true elsewhere in this client. When it does report a loss
						-- the part is no longer ours to move, so put it back.
						if oldroot and not isnetworkowner(oldroot) then
							reattach()
							return
						end
	
						refreshMap()
	
						local near = entitylib.EntityPosition({
							Range = Range.Value,
							Players = Targets.Players.Enabled,
							NPCs = Targets.NPCs.Enabled,
							Wallcheck = Targets.Walls.Enabled or nil,
							Sort = sortmethods.Distance,
							Part = 'RootPart'
						})
	
						if near then
							lastNear = tick()
						end
	
						-- Held for a moment after they leave, rather than reattaching the
						-- instant nobody is in range. Someone weaving in and out otherwise gets
						-- a free swing every time they step back over the boundary, and
						-- reattaching is the expensive part - it is not worth doing repeatedly
						-- for a target who has not actually gone anywhere.
						local engaged = tick() - lastNear < LINGER
						if engaged then
							-- Wrapped too: the first detach of a fight is a reparent like any
							-- other, and left alone it starts the fall the swaps below continue.
							preserveGround(detach)
						end
	
						if engaged and oldroot and oldroot.Parent then
							local bury, mayAttack = evaluate()
							dodging = bury
							-- Read by Killaura, which holds its swing until the root is parked and
							-- that position has reached the server. Nil means this module is not
							-- hiding anything, so attacking is unrestricted.
							store.antiMeleeParked = mayAttack
	
							-- Never while surfaced for a swing: the swap would undo the parked
							-- position the attack is about to be validated against.
							if bury and tick() - lastFlicker > FLICKER_INTERVAL then
								lastFlicker = tick()
								preserveGround(function()
									reattach()
									detach()
								end)
							end
						else
							preserveGround(reattach)
						end
					end)
	
					task.wait(ok and 0.03 or 0.25)
				until not AntiMelee.Enabled
	
				reattach()
			else
				reattach()
			end
		end,
		Tooltip = 'Moves the part the server hits you by out of your character\nStands down for a moment around your own swings so your hits still land'
	})
	Targets = AntiMelee:CreateTargets({
		Players = true,
		Tooltip = 'Which entities this reacts to'
	})
	Range = AntiMelee:CreateSlider({
		Name = 'Range',
		Tooltip = 'How close someone has to be before this engages\nWell above sword reach on purpose, so the root is already hidden before they are close enough to swing',
		Min = 1,
		Max = 60,
		Default = 32,
		Suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})
	
end)

run(function()
	local AntiRender
	local OnlyRanked
	
	-- The game's own match state for the end-of-round scoreboard, which is the moment the
	-- next lobby is being set up and a kit change still takes.
	local POST = 2
	local NONE = 'none'
	
	--[[
		Swaps you onto the none kit, so the round you join next reports no kit at all.
	
		This is the same call the kit shop's Equip button makes, not a display trick: the
		server is told, and it is the server that tells everyone else what you are running.
		Which also means you really are on no kit afterwards, abilities included.
	]]
	local function activate(kit)
		local ok, result = pcall(function()
			return bedwars.Client:Get('BedwarsActivateKit'):CallServer({kit = kit})
		end)
		return ok and result and true or false
	end
	
	--[[
		Ranked is the only mode that calls a round off for want of players, and the only one
		where what kit you are on is worth hiding in the first place.
	
		Matched on the queue's name rather than a list of queue types, the same way the other
		modules pick a mode out, so a ranked playlist that does not exist yet is covered
		without a list to keep up to date.
	]]
	local function ranked()
		return (store.queueType or ''):find('ranked') ~= nil
	end
	
	-- Says which way the swap went either way. Silence would be worse than a notification
	-- here: a failed swap looks exactly like a successful one right up until the next round
	-- starts and your kit is on show.
	local function unequip()
		if OnlyRanked.Enabled and not ranked() then return end
	
		-- Read before the swap, since this is what is being changed away from. Empty means
		-- you are already on none and there is nothing to do - which is also what makes it
		-- safe for the event and the state below to both fire.
		local worn = store.equippedKit
		if worn == '' then return end
	
		if activate(NONE) then
			notif('AntiRender', 'Unequipped '..worn, 3)
		else
			notif('AntiRender', 'Could not unequip '..worn, 3)
		end
	end
	
	AntiRender = vain.Categories.Utility:CreateModule({
		Name = 'AntiRender',
		Function = function(callback)
			if not callback then return end
	
			--[[
				The round ending is announced by this before the state catches up, and the
				announcement carries whether it was called off rather than played out - which
				ranked does when too few players load in.
	
				Watched as well as the state below, not instead of it. A cancelled round is
				over in a hurry and the client can be on its way back to the lobby inside the
				half second the poll waits, so the poll alone could miss the only chance to
				swap. Swapping twice costs nothing, since the second one finds you already on
				no kit and stops.
			]]
			AntiRender:Clean(vainEvents.MatchEndEvent.Event:Connect(function()
				task.spawn(unequip)
			end))
	
			-- Deliberately nil rather than the current state, so switching this on while a
			-- round is already over acts straight away instead of waiting for the one after.
			local last
			repeat
				local state = store.matchState
	
				if state ~= last then
					if state == POST then
						unequip()
					end
	
					last = state
				end
	
				task.wait(0.5)
			until not AntiRender.Enabled
		end,
		Tooltip = 'Unequips your kit when a round ends'
	})
	OnlyRanked = AntiRender:CreateToggle({
		Name = 'Only Ranked',
		Tooltip = 'Only runs while in a ranked queue',
		Default = true
	})
	
end)

run(function()
	-- Lives in Utility/ rather than a Kit/ folder because VainBundler enumerates a
	-- hardcoded category list (Combat, Blatant, Render, Utility, World, Inventory,
	-- Minigames, Legit) - a Kit/ folder is skipped entirely and never reaches the
	-- compiled bundle. The folder only decides what gets bundled; the category a
	-- module appears under is the one it is created from, which is Kit below.
	local AutoAdetunde
	local Priority
	local Notify
	local KeepJump
	local KeepMoving
	
	-- How long after firing an upgrade to treat the player as "upgrading". The block is
	-- brief, and keeping the window tight matters: leaps and dashes legitimately zero
	-- jumping too, and restoring it during one of those would break the ability.
	local JUMP_WINDOW = 2
	local upgradingUntil = 0
	local lastJumpHeight, lastJumpPower
	local lastWalkSpeed
	
	-- Level costs are the same for all three tracks: 2, 5 then 12 frost crystals
	-- (FrostyHammerBalance.{ATTACK,SPEED,SHIELD}_LEVEL{1,2,3}_COST).
	local COSTS = {2, 5, 12}
	local CURRENCY = 'frost_crystal'
	-- Both spellings appear in the game files for this kit.
	local KIT_IDS = {'frosty_hammer', 'frost_hammer_kit'}
	
	-- The enum is not a Knit controller, so the bedwars table cannot reach it - that
	-- metatable falls back to Knit.Controllers and would just hand back nil. Required
	-- straight from the module the game imports it from, and left nil if that path
	-- moves so the module degrades to doing nothing instead of throwing every pass.
	local upgrades
	local function resolveUpgrades()
		if upgrades then return upgrades end
		local ok, module = pcall(function()
			return require(replicatedStorage.TS.games.bedwars.items['frosty-hammer']['frosty-hammer-upgrades'])
		end)
		upgrades = ok and module or nil
		return upgrades
	end
	task.spawn(resolveUpgrades)
	
	-- Levels live as attributes on the player, keyed by the enum's *value* rather than
	-- its name, which is why these are read through the enum instead of hardcoded.
	local function levelOf(upgrade)
		return lplr:GetAttribute(upgrade) or 0
	end
	
	local function crystals()
		local item = getItem(CURRENCY)
		return item and item.amount or 0
	end
	
	-- Priority track first until it is maxed, then whatever is left. Order within the
	-- remainder is fixed so repeated passes cannot flip-flop between two tracks.
	local function buyOrder(enum)
		local order, chosen = {}, Priority.Value:upper()
		if enum[chosen] then
			table.insert(order, enum[chosen])
		end
		for _, name in {'STRENGTH', 'SPEED', 'SHIELD'} do
			local value = enum[name]
			if value and value ~= enum[chosen] then
				table.insert(order, value)
			end
		end
		return order
	end
	
	local function nextPurchase(enum)
		-- Only one track may reach the top tier. Once one has, the rest cap a tier below,
		-- and asking for that last tier anyway is simply refused - which left this
		-- repeating the same rejected purchase forever, stuck on the second track.
		local anyMaxed = false
		for _, upgrade in buyOrder(enum) do
			if levelOf(upgrade) >= #COSTS then
				anyMaxed = true
				break
			end
		end
	
		for _, upgrade in buyOrder(enum) do
			local level = levelOf(upgrade)
			local cap = anyMaxed and (#COSTS - 1) or #COSTS
			if level < cap then
				return upgrade, level + 1, COSTS[level + 1]
			end
		end
	end
	
	AutoAdetunde = vain.Categories.Kit:CreateModule({
		Name = 'Adetunde',
		Function = function(callback)
			if callback then
				upgradingUntil = 0
				AutoAdetunde:Clean(runService.RenderStepped:Connect(function()
					if not entitylib.isAlive then return end
					if not (KeepJump.Enabled or KeepMoving.Enabled) then return end
					local humanoid = entitylib.character.Humanoid
	
					-- Remember the last non-zero values so there is something real to put
					-- back, rather than assuming Roblox's defaults - the kit and the game
					-- both adjust these.
					if humanoid.JumpHeight > 0 then lastJumpHeight = humanoid.JumpHeight end
					if humanoid.JumpPower > 0 then lastJumpPower = humanoid.JumpPower end
					if humanoid.WalkSpeed > 0 then lastWalkSpeed = humanoid.WalkSpeed end
	
					-- Only inside the upgrade window, so abilities that zero jumping or
					-- movement on purpose are left alone.
					if tick() >= upgradingUntil then return end
	
					if KeepJump.Enabled then
						if lastJumpHeight and humanoid.JumpHeight <= 0 then
							humanoid.JumpHeight = lastJumpHeight
						end
						if lastJumpPower and humanoid.JumpPower <= 0 then
							humanoid.JumpPower = lastJumpPower
						end
					end
	
					--[[
						Buying an upgrade roots you in place for the moment it takes. Speed is
						put back the same way jumping is, and the two flags that root a
						character without touching speed are cleared alongside it - either one
						of those on its own is enough to leave you standing still.
					]]
					if KeepMoving.Enabled then
						if lastWalkSpeed and humanoid.WalkSpeed <= 0 then
							humanoid.WalkSpeed = lastWalkSpeed
						end
						if not humanoid.AutoRotate then
							humanoid.AutoRotate = true
						end
						if humanoid.PlatformStand then
							humanoid.PlatformStand = false
						end
					end
				end))
	
				repeat
					-- Guarded and yielding outside the pcall, so a bad pass cannot spin.
					local ok = pcall(function()
						local enum = resolveUpgrades()
						enum = enum and enum.FrostyHammerUpgrade
						if not enum then return end
						if not entitylib.isAlive then return end
						-- The kit's internal id is 'frosty_hammer' (BedwarsKit.FROSTY_HAMMER),
						-- not 'adetunde' - the display name matches nothing in the game files,
						-- the same way Zephyr is 'wind_walker'. Guarding on 'adetunde' rejected
						-- every pass while actually playing the kit, so nothing was ever bought.
						if store.equippedKit ~= '' and not table.find(KIT_IDS, store.equippedKit) then return end
	
						local upgrade, level, cost = nextPurchase(enum)
						if not upgrade or crystals() < cost then return end
	
						upgradingUntil = tick() + JUMP_WINDOW
						bedwars.Client:Get('UpgradeFrostyHammer'):CallServerAsync(upgrade):andThen(function(result)
							if result ~= false and Notify.Enabled then
								notif('Adetunde', 'Upgraded '..tostring(upgrade):lower()..' to '..level, 3)
							end
						end)
					end)
	
					task.wait(ok and 0.5 or 1)
				until not AutoAdetunde.Enabled
			end
		end,
		ExtraText = function()
			return Priority.Value
		end,
		Tooltip = 'Upgrades the Frosty Hammer as soon as you can afford it'
	})
	Priority = AutoAdetunde:CreateDropdown({
		Name = 'Priority',
		Tooltip = 'Which upgrade to max out before spending on anything else',
		List = {'Strength', 'Speed', 'Shield'},
		Tooltips = {
			Strength = 'More hammer damage',
			Speed = 'Faster hammer swings',
			Shield = 'More shield from the hammer'
		}
	})
	KeepJump = AutoAdetunde:CreateToggle({
		Name = 'Keep Jump',
		Tooltip = 'Restores your jump if buying an upgrade takes it away',
		Default = true
	})
	KeepMoving = AutoAdetunde:CreateToggle({
		Name = 'Keep Moving',
		Tooltip = 'Lets you keep walking while an upgrade is bought',
		Default = true
	})
	Notify = AutoAdetunde:CreateToggle({
		Name = 'Notify',
		Tooltip = 'Shows a notification for each upgrade bought',
		Default = true
	})
	
end)

local AutoBalloon
local Legit
local inflating = false

local function hotbarSlot(itemType)
	for i, v in store.inventory.hotbar do
		if v.item and v.item.itemType == itemType then
			return i - 1
		end
	end
end

-- The action the game binds while a balloon is in your hand. It only exists once the
-- balloon is actually held, which is the whole point of equipping first.
local function boundInflate()
	local binder = bedwars.ActionBinder
	local action = binder and binder.registeredActions and binder.registeredActions['inflate-balloon']
	return action and action.boundFunction or nil
end

--[[
	Blatant sends the inflate straight off without the balloon ever being in your hand.

	Legit equips it first and then runs the same bound action your mouse button would.
	Equipping is what turns the balloon's own handler on, so the animation plays and the
	cooldown is respected rather than being reimplemented here; nothing is sent by hand.

	Falls back to the controller call when the action has not appeared, so a slow equip
	still gets you out of the void rather than doing nothing at all.
]]
local function legitInflate()
	local balloon = getItem('balloon')
	if not balloon or not balloon.tool then return end

	local previous = store.hand.tool
	local slot = hotbarSlot('balloon')
	if slot then
		hotbarSwitch(slot)
	end
	switchItem(balloon.tool)

	local run
	for _ = 1, 20 do
		run = boundInflate()
		if run then break end
		task.wait()
	end

	for _ = 1, 3 do
		if (lplr.Character:GetAttribute('InflatedBalloons') or 0) >= 3 then break end

		if run then
			run('inflate-balloon', Enum.UserInputState.Begin, newproxy(true))
		else
			bedwars.BalloonController:inflateBalloon()
		end
		task.wait(0.1)
	end

	-- Put back whatever was in your hand, the same as AutoConsume does, so being saved
	-- does not also disarm you.
	if previous and previous.Parent then
		pcall(switchItem, previous)
	end
end

AutoBalloon = vain.Categories.Utility:CreateModule({
	Name = 'AutoBalloon',
	Function = function(callback)
		if callback then
			repeat task.wait() until store.matchState ~= 0 or (not AutoBalloon.Enabled)
			if not AutoBalloon.Enabled then return end

			local lowestpoint = math.huge
			for _, v in store.blocks do
				local point = (v.Position.Y - (v.Size.Y / 2)) - 50
				if point < lowestpoint then 
					lowestpoint = point 
				end
			end

			repeat
				if entitylib.isAlive then
					if entitylib.character.RootPart.Position.Y < lowestpoint and (lplr.Character:GetAttribute('InflatedBalloons') or 0) < 3 then
						local balloon = getItem('balloon')
						if balloon then
							if Legit.Enabled then
								-- Guarded because this one yields, on the equip and between
								-- inflates, so a pass could otherwise start on top of itself.
								if not inflating then
									inflating = true
									pcall(legitInflate)
									inflating = false
								end
							else
								for _ = 1, 3 do 
									bedwars.BalloonController:inflateBalloon() 
								end
							end
						end
						task.wait(0.1)
					end
				end
				task.wait(0.1)
			until not AutoBalloon.Enabled
		else
			inflating = false
		end
	end,
	Tooltip = 'Inflates when you fall into the void'
})
Legit = AutoBalloon:CreateToggle({
	Name = 'Legit',
	Tooltip = 'Holds the balloon before inflating it'
})


run(function()
	local AutoPearl
	local rayCheck = RaycastParams.new()
	rayCheck.RespectCanCollide = true
	local projectileRemote = {InvokeServer = function() end}
	task.spawn(function()
		projectileRemote = bedwars.Client:Get(remotes.FireProjectile).instance
	end)
	
	local function firePearl(pos, spot, item)
		switchItem(item.tool)
		local meta = bedwars.ProjectileMeta.telepearl
		local calc = prediction.SolveTrajectory(pos, meta.launchVelocity, meta.gravitationalAcceleration, spot, Vector3.zero, workspace.Gravity, 0, 0)
	
		if calc then
			local dir = CFrame.lookAt(pos, calc).LookVector * meta.launchVelocity
			bedwars.ProjectileController:createLocalProjectile(meta, 'telepearl', 'telepearl', pos, nil, dir, {drawDurationSeconds = 1})
			projectileRemote:InvokeServer(item.tool, 'telepearl', 'telepearl', pos, pos, dir, httpService:GenerateGUID(true), {drawDurationSeconds = 1, shotId = httpService:GenerateGUID(false)}, workspace:GetServerTimeNow() - 0.045)
		end
	
		if store.hand then
			switchItem(store.hand.tool)
		end
	end
	
	AutoPearl = vain.Categories.Utility:CreateModule({
		Name = 'AutoPearl',
		Function = function(callback)
			if callback then
				local check
				repeat
					if entitylib.isAlive then
						local root = entitylib.character.RootPart
						local pearl = getItem('telepearl')
						rayCheck.FilterDescendantsInstances = {lplr.Character, gameCamera, AntiFallPart}
						rayCheck.CollisionGroup = root.CollisionGroup
	
						if pearl and root.Velocity.Y < -100 and not workspace:Raycast(root.Position, Vector3.new(0, -200, 0), rayCheck) then
							if not check then
								check = true
								local ground = getNearGround(20)
	
								if ground then
									firePearl(root.Position, ground, pearl)
								end
							end
						else
							check = false
						end
					end
					task.wait(0.1)
				until not AutoPearl.Enabled
			end
		end,
		Tooltip = 'Automatically throws a pearl onto nearby ground after\nfalling a certain distance.'
	})
end)

run(function()
	local AutoPlay
	local Random
	
	local function isEveryoneDead()
		return #bedwars.Store:getState().Party.members <= 0
	end
	
	local function joinQueue()
		if not bedwars.Store:getState().Game.customMatch and bedwars.Store:getState().Party.leader.userId == lplr.UserId and bedwars.Store:getState().Party.queueState == 0 then
			if Random.Enabled then
				local listofmodes = {}
				for i, v in bedwars.QueueMeta do
					if not v.disabled and not v.voiceChatOnly and not v.rankCategory then 
						table.insert(listofmodes, i) 
					end
				end
				bedwars.QueueController:joinQueue(listofmodes[math.random(1, #listofmodes)])
			else
				bedwars.QueueController:joinQueue(store.queueType)
			end
		end
	end
	
	AutoPlay = vain.Categories.Utility:CreateModule({
		Name = 'AutoPlay',
		Function = function(callback)
			if callback then
				AutoPlay:Clean(vainEvents.EntityDeathEvent.Event:Connect(function(deathTable)
					if deathTable.finalKill and deathTable.entityInstance == lplr.Character and isEveryoneDead() and store.matchState ~= 2 then
						joinQueue()
					end
				end))
				AutoPlay:Clean(vainEvents.MatchEndEvent.Event:Connect(joinQueue))
			end
		end,
		Tooltip = 'Automatically queues after the match ends.'
	})
	Random = AutoPlay:CreateToggle({
		Name = 'Random',
		Tooltip = 'Chooses a random mode'
	})
end)

run(function()
	local AutoToxic
	local GG
	local Toggles, Lists, said, dead = {}, {}, {}
	
	local function sendMessage(name, obj, default)
		local tab = Lists[name].ListEnabled
		local custommsg = #tab > 0 and tab[math.random(1, #tab)] or default
		if not custommsg then return end
		if #tab > 1 and custommsg == said[name] then
			repeat 
				task.wait() 
				custommsg = tab[math.random(1, #tab)] 
			until custommsg ~= said[name]
		end
		said[name] = custommsg
	
		custommsg = custommsg and custommsg:gsub('<obj>', obj or '') or ''
		if textChatService.ChatVersion == Enum.ChatVersion.TextChatService then
			textChatService.ChatInputBarConfiguration.TargetTextChannel:SendAsync(custommsg)
		else
			replicatedStorage.DefaultChatSystemChatEvents.SayMessageRequest:FireServer(custommsg, 'All')
		end
	end
	
	AutoToxic = vain.Categories.Utility:CreateModule({
		Name = 'AutoToxic',
		Function = function(callback)
			if callback then
				AutoToxic:Clean(vainEvents.BedwarsBedBreak.Event:Connect(function(bedTable)
					if Toggles.BedDestroyed.Enabled and bedTable.brokenBedTeam.id == lplr:GetAttribute('Team') then
						sendMessage('BedDestroyed', (bedTable.player.DisplayName or bedTable.player.Name), 'how dare you >:( | <obj>')
					elseif Toggles.Bed.Enabled and bedTable.player.UserId == lplr.UserId then
						local team = bedwars.QueueMeta[store.queueType].teams[tonumber(bedTable.brokenBedTeam.id)]
						sendMessage('Bed', team and team.displayName:lower() or 'white', 'nice bed lul | <obj>')
					end
				end))
				AutoToxic:Clean(vainEvents.EntityDeathEvent.Event:Connect(function(deathTable)
					if deathTable.finalKill then
						local killer = playersService:GetPlayerFromCharacter(deathTable.fromEntity)
						local killed = playersService:GetPlayerFromCharacter(deathTable.entityInstance)
						if not killed or not killer then return end
						if killed == lplr then
							if (not dead) and killer ~= lplr and Toggles.Death.Enabled then
								dead = true
								sendMessage('Death', (killer.DisplayName or killer.Name), 'my gaming chair subscription expired :( | <obj>')
							end
						elseif killer == lplr and Toggles.Kill.Enabled then
							sendMessage('Kill', (killed.DisplayName or killed.Name), 'vxp on top | <obj>')
						end
					end
				end))
				AutoToxic:Clean(vainEvents.MatchEndEvent.Event:Connect(function(winstuff)
					if GG.Enabled then
						if textChatService.ChatVersion == Enum.ChatVersion.TextChatService then
							textChatService.ChatInputBarConfiguration.TargetTextChannel:SendAsync('gg')
						else
							replicatedStorage.DefaultChatSystemChatEvents.SayMessageRequest:FireServer('gg', 'All')
						end
					end
					
					local myTeam = bedwars.Store:getState().Game.myTeam
					if myTeam and myTeam.id == winstuff.winningTeamId or lplr.Neutral then
						if Toggles.Win.Enabled then 
							sendMessage('Win', nil, 'yall garbage') 
						end
					end
				end))
			end
		end,
		Tooltip = 'Says a message after a certain action'
	})
	GG = AutoToxic:CreateToggle({
		Name = 'AutoGG',
		Tooltip = 'Sends a message at the end of the match',
		Default = true
	})
	for _, v in {'Kill', 'Death', 'Bed', 'BedDestroyed', 'Win'} do
		Toggles[v] = AutoToxic:CreateToggle({
			Name = v..' ',
			Function = function(callback)
				if Lists[v] then
					Lists[v].Object.Visible = callback
				end
			end
		})
		Lists[v] = AutoToxic:CreateTextList({
			Name = v,
			Darker = true,
			Visible = false
		})
	end
end)

run(function()
	local AutoVoidDrop
	local OwlCheck
	
	AutoVoidDrop = vain.Categories.Utility:CreateModule({
		Name = 'AutoVoidDrop',
		Function = function(callback)
			if callback then
				repeat task.wait() until store.matchState ~= 0 or (not AutoVoidDrop.Enabled)
				if not AutoVoidDrop.Enabled then return end
	
				local lowestpoint = math.huge
				for _, v in store.blocks do
					local point = (v.Position.Y - (v.Size.Y / 2)) - 50
					if point < lowestpoint then
						lowestpoint = point
					end
				end
	
				repeat
					if entitylib.isAlive then
						local root = entitylib.character.RootPart
						if root.Position.Y < lowestpoint and (lplr.Character:GetAttribute('InflatedBalloons') or 0) <= 0 and not getItem('balloon') then
							if not OwlCheck.Enabled or not root:FindFirstChild('OwlLiftForce') then
								for _, item in {'iron', 'diamond', 'emerald', 'gold'} do
									item = getItem(item)
									if item then
										item = bedwars.Client:Get(remotes.DropItem):CallServer({
											item = item.tool,
											amount = item.amount
										})
	
										if item then
											item:SetAttribute('ClientDropTime', tick() + 100)
										end
									end
								end
							end
						end
					end
	
					task.wait(0.1)
				until not AutoVoidDrop.Enabled
			end
		end,
		Tooltip = 'Drops resources when you fall into the void'
	})
	OwlCheck = AutoVoidDrop:CreateToggle({
		Name = 'Owl check',
		Default = true,
		Tooltip = 'Refuses to drop items if being picked up by an owl'
	})
end)

--[[
	Kit modules, ported from the older VainV6 client.

	They are registered under the Kit category rather than that client's 'Kits', and
	live in Utility/ because VainBundler walks a hardcoded folder list and skips
	anything outside it - the folder decides what gets bundled, the category a module
	appears under is the one it is created from.

	Each of these was written against an older build of the game. The shared plumbing
	they rely on - notif, getItem, collection, sortmethods, addBlur, hotbarSwitch,
	getPlacedBlock, switchItem, roundPos, targetinfo, prediction, vainEvents - all still
	exists and matches, and the store fields they read (KillauraTarget, equippedKit,
	hand, inventory, matchState, shop) are all still populated. Remotes they reach for
	by a plain name now resolve through the fallback added in base.lua.

	What is not verified is the per-kit controller APIs. A kit reworked, renamed or
	removed since will have a module here that quietly does nothing. Adetunde and Zephyr
	both turned out to be filed under internal names matching nothing you would guess
	from the kit's display name, so expect some of these to need the same treatment.
]]


-- These modules do work at definition time - bedwars.Client:Get for a remote, most
-- commonly - and those calls yield. A yield hands the thread back to the scheduler,
-- and it resumes carrying the game's identity rather than the executor's, at which
-- point CreateModule cannot parent the window it builds and the module dies with
-- "lacking capability Plugin". Worse, the failure surfaces on whichever line runs
-- next, so it reads as a fault in a module that is fine.
--
-- Raising the identity at the start of every block means one module's yield cannot
-- take out the ones after it.
-- Not defined by the base, and not by the client these came from either - so the module
-- reaching for it (Fisherman Spy, for its auto cast) threw the moment that path ran.
local VirtualInputManager = cloneref(game:GetService('VirtualInputManager'))

local function kitRun(func)
	if setthreadidentity then
		pcall(setthreadidentity, 8)
	end
	func()
end

-- Shared helpers these modules rely on. They live at the base level in the client
-- they came from, outside the module blocks, so they had to be brought across too.

local function getTeammates(namesOnly)
	local result = {}
	local myTeam = lplr:GetAttribute('Team')
	if not myTeam then return result end
	for _, player in playersService:GetPlayers() do
		if player ~= lplr and player:GetAttribute('Team') == myTeam then
			if namesOnly then
				table.insert(result, player.Name)
			elseif player.Character and player.Character:FindFirstChild('Humanoid') and player.Character.Humanoid.Health > 0 then
				table.insert(result, player)
			end
		end
	end
	if namesOnly then
		table.sort(result)
	end
	return result
end

local function getPlayerHealth(player)
	if not player or not player.Character then return 0, 100 end
	local health = player.Character:GetAttribute('Health') or (player.Character:FindFirstChildOfClass('Humanoid') and player.Character.Humanoid.Health) or 0
	local maxHealth = player.Character:GetAttribute('MaxHealth') or (player.Character:FindFirstChildOfClass('Humanoid') and player.Character.Humanoid.MaxHealth) or 100
	return health, maxHealth
end

local function getPlayerHealthPercent(player)
	local health, maxHealth = getPlayerHealth(player)
	if maxHealth == 0 then return 0 end
	return (health / maxHealth) * 100
end

local function getAccountTier(player)
	if getgenv().getAccountTier then
		return getgenv().getAccountTier(player)
	end
	return 0
end

local function getHotbar(tool)
	for i, v in (store.inventory.hotbar or {}) do
		if v.item and v.item.tool == tool then
			return i - 1
		end
	end
	return nil
end

local function isFirstPerson()
	local char = lplr.Character
	local head = char and char:FindFirstChild('Head')
	if not head or not gameCamera then return false end
	return (gameCamera.CFrame.Position - head.Position).Magnitude < 1.5
end

local function isGUIOpen()
	return inputService.MouseBehavior == Enum.MouseBehavior.Default
end

local function isHoldingBowCrossbow()
	if not store.hand then return false end
	local tt = store.hand.toolType
	if tt == 'bow' or tt == 'crossbow' then return true end
	local name = store.hand.tool and store.hand.tool.Name
	return name ~= nil and (name:find('bow') ~= nil or name:find('crossbow') ~= nil)
end

-- getPickaxeSlot, isHoldingPickaxe and isSword are called by the ported modules but
-- were never defined in that client either, so those paths threw "attempt to call a
-- nil value" there too. Implemented here against the current store.
local function isSword()
	return store.hand ~= nil and store.hand.toolType == 'sword'
end

local function getPickaxeSlot()
	local tool = store.tools and store.tools.stone
	if not (tool and tool.itemType) then return nil end
	local _, slot = getItem(tool.itemType)
	return slot
end

local function isHoldingPickaxe()
	local tool = store.hand and store.hand.tool
	if not tool then return false end
	local meta = bedwars.ItemMeta[tool.Name]
	return meta ~= nil and meta.breakBlock ~= nil and meta.breakBlock.stone ~= nil
end

kitRun(function()
local AimAssist
	local Targets
	local Sort
	local AimSpeed
	local Smoothness
	local SmoothnessToggle
	local Distance
	local AngleSlider
	local KillauraTarget
	local ClickAim
	local ShopCheck
	local AimPart
	local ViewMode
	local PriorityMode
	local TargetPriority
	local ShakeToggle
	local ShakeAmount
	local WorkWithProjectiles
	local LimitToItem
	local MinDistance
	local HealthCheck
	local HealthThreshold

	local lockedTarget = nil
	local lastValidTarget = nil
	local lastValidTime = 0
	local GRACE_PERIOD = 0.15
	local rng = Random.new()
	local shakeTime = 0

	local function getSmoothedSpeed(speedVal, smoothVal, dt)
		local rawSpeed = 0.01 * (1.35 ^ speedVal)
		local smoothScale = math.max(1 - ((smoothVal - 1) / 9) * 0.88, 0.01)
		return math.min(rawSpeed * smoothScale, 0.95)
	end

	local function getClosestPartToCursor(character)
		local mousePos = inputService:GetMouseLocation()
		local mouseRay = gameCamera:ViewportPointToRay(mousePos.X, mousePos.Y, 0)
		local bestAngle = math.huge
		local bestPart = nil
		local partNames = {
			'Head', 'UpperTorso', 'LowerTorso', 'HumanoidRootPart',
			'LeftUpperArm', 'RightUpperArm', 'LeftLowerArm', 'RightLowerArm',
			'LeftUpperLeg', 'RightUpperLeg', 'LeftLowerLeg', 'RightLowerLeg',
			'LeftFoot', 'RightFoot', 'LeftHand', 'RightHand'
		}
		for _, partName in partNames do
			local part = character:FindFirstChild(partName)
			if part then
				local dirToPart = (part.Position - mouseRay.Origin).Unit
				local angle = math.acos(math.clamp(mouseRay.Direction:Dot(dirToPart), -1, 1))
				if angle < bestAngle then
					bestAngle = angle
					bestPart = part
				end
			end
		end
		return bestPart
	end

	local function isEntValid(ent)
		if not ent or not ent.RootPart or not ent.Character or not ent.Character.Parent then return false end
		if not entitylib.isAlive or not entitylib.character or not entitylib.character.RootPart then return false end
		local hum = ent.Character:FindFirstChildOfClass('Humanoid')
		if not hum or hum.Health <= 0 then return false end
		local dist = (ent.RootPart.Position - entitylib.character.RootPart.Position).Magnitude
		if dist > Distance.Value then return false end
		if not isEnemy(ent) then return false end
		return true
	end

	local function isInAngle(ent)
		if not ent or not ent.RootPart then return false end
		if not entitylib.character or not entitylib.character.RootPart then return false end
		local delta = (ent.RootPart.Position - entitylib.character.RootPart.Position)
		local localFacing = (ViewMode.Value == 'Third Person' and gameCamera.CFrame.LookVector or entitylib.character.RootPart.CFrame.LookVector) * Vector3.new(1, 0, 1)
		local flatDelta = delta * Vector3.new(1, 0, 1)
		if flatDelta.Magnitude <= 0.001 then return false end
		local angle = math.acos(math.clamp(localFacing:Dot(flatDelta.Unit), -1, 1))
		return angle < math.rad(AngleSlider.Value / 2)
	end

	-- ══════════════════════════════════════════════════════════════════
	--  SIGRID CHARGE  (restored into public Vain)
	-- ══════════════════════════════════════════════════════════════════
	run(function()
local vain = shared.vain
if not vain then return end
local bedwars = getgenv().bedwars
if not bedwars then return end -- BedWars only
if not (vain.Categories and vain.Categories.Kit) then return end -- some GUI skins don't have a Kits category
local playersService = (cloneref or function(x) return x end)(game:GetService('Players'))
local lplr = playersService.LocalPlayer

	-- ══════════════════════════════════════════════════════════════════════════
	--  SIGRID CHARGE  (Antler Uppercut -- press to fire the charge on a target)
	-- ══════════════════════════════════════════════════════════════════════════
	-- The Elk/Sigrid "Antler Uppercut" is server-driven but CLIENT-APPLIED: the
	-- server fires SigridBeginCharge{player=X} and X's own client pushes its root
	-- forward every Heartbeat. The charge is requested with the client-supplied
	-- target via bedwars.Client:Get('SigridBeginChargeRequest'):CallServer{player=X}.
	-- This is a BUTTON (press = one charge), it requires you to be mounted on your
	-- Elk first, targets the player you pick from the dropdown.
	do
		local SigridCharge, Target, Notify, AutoMount, SkipMount, WaitEnergy
		local function getRemote()
			local ok, r = pcall(function() return bedwars.Client:Get('SigridBeginChargeRequest') end)
			return ok and r or nil
		end
		-- The antler-uppercut charge is gated on the Elk's ENERGY: when it drops below a
		-- threshold the server disables the ability (ElkBelowChargeThreshold), so firing
		-- then gives a short, weak charge that "stops early". canUseAbility mirrors the
		-- game's own readiness check -> true only when energy is up and the charge is
		-- actually usable. We wait for it so every charge is a full one.
		local UPPERCUT_ABILITY = 'elk_antler_uppercut'
		local function chargeReady()
			local ok, ready = pcall(function()
				return bedwars.AbilityController:canUseAbility(UPPERCUT_ABILITY)
			end)
			return ok and ready == true
		end
		-- wait up to `timeout`s for the charge energy to be ready
		local function waitForEnergy(timeout)
			if chargeReady() then return true end
			local deadline = tick() + (timeout or 3)
			repeat task.wait(0.05) until chargeReady() or tick() > deadline
			return chargeReady()
		end
		-- mounted on the Elk? getActiveMounts() is keyed by player (place: line 451593)
		local function isMounted()
			local ok, mounts = pcall(function() return bedwars.MountController:getActiveMounts() end)
			return ok and mounts ~= nil and mounts[lplr] ~= nil
		end
		-- summon the Elk via the ELK_SUMMON ability ("elk_summon"), then wait up to
		-- ~1.5s for the mount to register. Returns true once mounted.
		local function ensureMounted()
			if isMounted() then return true end
			pcall(function()
				if bedwars.AbilityController:canUseAbility('elk_summon') then
					bedwars.AbilityController:useAbility('elk_summon')
				end
			end)
			local deadline = tick() + 1.5
			repeat task.wait(0.05) until isMounted() or tick() > deadline
			return isMounted()
		end
		local function resolveTarget()
			local name = Target and Target.Value
			if not name or name == 'None' then return nil end
			return playersService:FindFirstChild(name)
		end
		SigridCharge = vain.Categories.Kit:CreateModule({
			Name = 'Sigrid Charge',
			Tooltip = 'Fire the Elk/Sigrid Antler Uppercut charge at your Target. Must be mounted on your Elk first.',
			Function = function(callback)
				if not callback then return end
				-- act like a one-shot button: do the work, then toggle straight back off
				local function done() if SigridCharge.Enabled then SigridCharge:Toggle() end end
				-- Skip Mount Check: fire the request regardless of mount/character
				-- state (for spectator use / testing whether the server validates the
				-- requester). If it lands, the server only trusts the target field.
				if not (SkipMount and SkipMount.Enabled) and not isMounted() then
					if AutoMount and AutoMount.Enabled then
						if not ensureMounted() then
							vain:CreateNotification('Sigrid Charge', 'Could not mount the Elk (do you have the Sigrid kit?).', 5, 'warning')
							return done()
						end
					else
						vain:CreateNotification('Sigrid Charge', 'You must be mounted on your Elk first (or enable Auto Mount / Skip Mount Check).', 5, 'warning')
						return done()
					end
				end
				local remote = getRemote()
				if not remote then
					vain:CreateNotification('Sigrid Charge', 'Elk charge remote not found in this place.', 6, 'warning')
					return done()
				end
				local target = resolveTarget()
				if not target then
					vain:CreateNotification('Sigrid Charge', 'Pick a target player in the dropdown first.', 5, 'warning')
					return done()
				end
				-- Only fire when the charge energy is up, so it doesn't stop early. Skip
				-- this wait when Skip Mount Check is on (spectator/no-elk testing) since
				-- the ability state won't be meaningful there.
				if (not WaitEnergy or WaitEnergy.Enabled) and not (SkipMount and SkipMount.Enabled) then
					if not waitForEnergy(3) then
						vain:CreateNotification('Sigrid Charge', 'Charge energy not ready -- waiting timed out. Let the Elk recharge.', 5, 'warning')
						return done()
					end
				end
				pcall(function() remote:CallServer({ player = target }) end)
				if Notify and Notify.Enabled then
					vain:CreateNotification('Sigrid Charge', 'Charge fired on ' .. target.Name, 3)
				end
				done()
			end
		})
		Target = SigridCharge:CreateDropdown({ Name = 'Target', List = { 'None' }, Default = 'None',
			Function = function() end,
			Tooltip = 'Player to send the charge to (updates as players join/leave).' })
		WaitEnergy = SigridCharge:CreateToggle({ Name = 'Wait For Energy', Default = true,
			Tooltip = 'Only fire when Elk charge energy is up (waits up to 3s) so it\'s always a full charge, not a weak early one.' })
		AutoMount = SigridCharge:CreateToggle({ Name = 'Auto Mount', Default = false,
			Tooltip = 'If not on your Elk when you press, summon it first and wait for the mount before charging. Requires the Sigrid kit.' })
		SkipMount = SigridCharge:CreateToggle({ Name = 'Skip Mount Check', Default = false,
			Tooltip = 'Fire the charge even when not mounted (e.g. as a spectator). Only works if the server doesn\'t verify you\'re a mounted Sigrid.' })
		Notify = SigridCharge:CreateToggle({ Name = 'Notify', Default = true,
			Tooltip = 'Notify when a charge is fired.' })

		-- keep the Target dropdown in sync with the current players (excluding you)
		local function refreshTargets()
			if not Target then return end
			local names = {}
			for _, plr in playersService:GetPlayers() do
				if plr ~= lplr then table.insert(names, plr.Name) end
			end
			if #names == 0 then names = { 'None' } end
			if type(Target.Change) == 'function' then pcall(function() Target:Change(names) end) end
		end
		refreshTargets()
		vain:Clean(playersService.PlayerAdded:Connect(refreshTargets))
		vain:Clean(playersService.PlayerRemoving:Connect(function() task.defer(refreshTargets) end))
	end
	end)



	-- ══════════════════════════════════════════════════════════════════════════
	--  ADVANCED SPECTATE  (spectate anyone; optionally lock to one player)
	-- ══════════════════════════════════════════════════════════════════════════
	-- The game's SpectateController defaults to mode TEAM, which restricts the
	-- spectate cycle to your (or the reported ticket's) team. Its SpectateMode enum
	-- has ALL (0), TEAM (1), PLAYER (2). We simply force mode = ALL so the built-in
	-- getSpectateTargets returns EVERY in-game player (spectators aren't in-game, so
	-- they're naturally excluded). Fixed Spectate hooks getSpectateTargets to return
	-- only the chosen player, so the game's own auto-next-on-death can only ever
	-- land back on them.
	do
		local AdvancedSpectate, FixedSpectate, FixedPlayer, SpectateTeam
		local origGetTargets, spec
		-- maps the "Spectate Team" dropdown label -> team id (nil = All Teams)
		local teamLabelToId = {}

		local function getSpec()
			if spec then return spec end
			local ok, ctrl = pcall(function() return bedwars.SpectateController end)
			if ok and type(ctrl) == 'table' then spec = ctrl end
			return spec
		end

		-- resolve the currently-selected fixed player by name
		local function fixedPlr()
			local name = FixedPlayer and FixedPlayer.Value
			if not name or name == 'None' then return nil end
			return playersService:FindFirstChild(name)
		end

		-- OfflinePlayerUtil converts a live Player into the {userId=..} shape the
		-- store's spectatingPlayer field expects. Resolve it lazily/cached.
		local offlineUtil
		local function getOfflineUtil()
			if offlineUtil ~= nil then return offlineUtil or nil end
			local ok, mod = pcall(function()
				return require(replicatedStorage.TS.player['offline-player-util']).OfflinePlayerUtil
			end)
			offlineUtil = (ok and mod) or false
			return offlineUtil or nil
		end

		-- Snap the spectate camera straight onto `plr`. The game's
		-- switchSpectateTargets only understands "next"/"prev" (a Player arg is
		-- treated as "prev"), so we dispatch GameSetSpectator ourselves -- exactly
		-- what the server's SpectatePlayer remote does.
		local function snapTo(plr)
			if not plr then return false end
			local util = getOfflineUtil()
			local sp
			if util and util.getOfflinePlayer then
				local ok, res = pcall(function() return util.getOfflinePlayer(plr) end)
				if ok then sp = res end
			end
			if not sp then sp = { userId = plr.UserId } end
			return pcall(function()
				bedwars.Store:dispatch({
					type = 'GameSetSpectator',
					spectating = true,
					spectatingPlayer = sp,
				})
			end)
		end

		-- Un-fixate / leave the spectate view. Two cases:
		--  * live player -> stopSpectatingPlayer() returns your camera to your body.
		--  * genuine spectator (dead / lobby) the game refuses to release -> the
		--    camera stays glued to the locked player, so we advance to a DIFFERENT
		--    target so you're visibly un-pinned. Deferred one heartbeat so our
		--    spectatingPlayer=nil dispatch settles first (otherwise switchSpectateTargets
		--    re-reads 'current = locked player' and lands right back on them).
		-- Shared by BOTH the Fixed Spectate toggle-off AND the module toggle-off (the
		-- latter leaves FixedSpectate.Enabled true, so it can't gate on that).
		local function leaveSpectate(ctrl)
			if not ctrl then return end
			pcall(function() ctrl:stopSpectatingPlayer() end)
			task.defer(function()
				if lplr:GetAttribute('Spectator') == true then
					pcall(function()
						if ctrl.switchSpectateTargets then ctrl:switchSpectateTargets('next') end
					end)
				end
			end)
		end

		AdvancedSpectate = vain.Categories.Utility:CreateModule({
			Name = 'BetterSpectating',
			Tooltip = 'Spectate anyone, not just your team (forces spectate to ALL). Enable Fixed Spectate + pick a player to lock the view.',
			Function = function(callback)
				local ctrl = getSpec()
				if callback then
					if not ctrl then
						notif('BetterSpectating', 'Spectate controller not found in this place.', 6, 'warning')
						AdvancedSpectate:Toggle()
						return
					end
					-- force ALL mode so every in-game player is spectatable
					pcall(function()
						local ALL = ctrl.SpectateMode and ctrl.SpectateMode.ALL or 0
						if ctrl.setSpectateMode then ctrl:setSpectateMode(ALL) else ctrl.mode = ALL end
					end)
					-- keep it pinned to ALL (the game may reset mode on events) and
					-- apply the Fixed Spectate hook.
					if not origGetTargets and ctrl.getSpectateTargets then
						origGetTargets = ctrl.getSpectateTargets
						ctrl.getSpectateTargets = function(selfc, ...)
							if FixedSpectate and FixedSpectate.Enabled then
								local p = fixedPlr()
								if p then return { p } end -- only ever this player
							end
							local targets = origGetTargets(selfc, ...)
							-- "Spectate Team": if a specific team is chosen, keep only its
							-- players; "All Teams" (nil) leaves the full ALL list intact.
							local teamId = SpectateTeam and teamLabelToId[SpectateTeam.Value]
							if teamId ~= nil and type(targets) == 'table' then
								local filtered = {}
								for _, pl in targets do
									if pl:GetAttribute('Team') == teamId then
										filtered[#filtered + 1] = pl
									end
								end
								if #filtered > 0 then return filtered end
							end
							return targets
						end
					end
					-- if Fixed Spectate is already on, snap onto the fixed player now
					-- (so re-enabling the module re-fixates as expected).
					if FixedSpectate and FixedSpectate.Enabled then
						snapTo(fixedPlr())
					end
				else
					-- restore the original target resolver + let the game manage mode
					if origGetTargets and ctrl and ctrl.getSpectateTargets ~= origGetTargets then
						ctrl.getSpectateTargets = origGetTargets
					end
					origGetTargets = nil
					if ctrl then
						-- Un-fixate even if Fixed Spectate is still enabled (module off
						-- doesn't flip that sub-toggle). Same robust leave as the toggle.
						leaveSpectate(ctrl)
						pcall(function()
							local TEAM = ctrl.SpectateMode and ctrl.SpectateMode.TEAM or 1
							if ctrl.setSpectateMode then ctrl:setSpectateMode(TEAM) else ctrl.mode = TEAM end
						end)
					end
				end
			end
		})
		FixedSpectate = AdvancedSpectate:CreateToggle({
			Name = 'Fixed Spectate',
			Tooltip = 'Lock spectating to the selected player. If they die, this snaps the view straight back to them.',
			Default = false,
			Function = function(callback)
				local ctrl = getSpec()
				if callback then
					-- ON: snap onto the fixed player (only if the module is enabled)
					if AdvancedSpectate.Enabled then
						snapTo(fixedPlr())
					end
				else
					-- OFF: un-fixate. The getSpectateTargets hook now falls through to
					-- everyone (FixedSpectate.Enabled is false). Two cases:
					--  * you're a live player -> stopSpectatingPlayer() returns your
					--    camera to your own body (that's the whole un-fixate).
					--  * you're a genuine spectator (dead / lobby) -> the game won't let
					--    you leave spectate, so instead of stopping we clear the lock and
					--    advance to a DIFFERENT player so you're no longer pinned. We do
					--    the advance on the next heartbeat so the spectatingPlayer=nil
					--    dispatch settles first (otherwise switchSpectateTargets re-reads
					--    the stale 'current = fixed player' state and lands right back).
					leaveSpectate(ctrl)
				end
			end
		})
		FixedPlayer = AdvancedSpectate:CreateDropdown({
			Name = 'Fixed Player',
			List = { 'None' },
			Default = 'None',
			Tooltip = 'Which player to lock onto when Fixed Spectate is on.',
			Function = function()
				-- snap onto the newly-picked player right away
				if AdvancedSpectate.Enabled and FixedSpectate and FixedSpectate.Enabled then
					snapTo(fixedPlr())
				end
			end
		})
		SpectateTeam = AdvancedSpectate:CreateDropdown({
			Name = 'Spectate Team',
			List = { 'All Teams' },
			Default = 'All Teams',
			Tooltip = 'Spectate every team ("All Teams") or lock the cycle to one team. Ignored while Fixed Spectate is on.',
			Function = function()
				-- advance to a valid target within the newly-chosen team right away
				local ctrl = getSpec()
				if AdvancedSpectate.Enabled and ctrl and not (FixedSpectate and FixedSpectate.Enabled) then
					pcall(function()
						if ctrl.switchSpectateTargets then ctrl:switchSpectateTargets('next') end
					end)
				end
			end
		})

		-- keep the Fixed Player + Spectate Team dropdowns in sync with the server
		local function refreshList()
			local names = { 'None' }
			for _, plr in playersService:GetPlayers() do
				if plr ~= lplr then names[#names + 1] = plr.Name end
			end
			pcall(function() FixedPlayer:Change(names) end)

			-- rebuild the team list from the store (label -> id map for filtering)
			local teamNames = { 'All Teams' }
			teamLabelToId = {}
			pcall(function()
				local teams = bedwars.Store:getState().Game.teams
				if type(teams) == 'table' then
					local list = {}
					for _, t in teams do list[#list + 1] = t end
					table.sort(list, function(a, b) return tostring(a.id) < tostring(b.id) end)
					for _, t in list do
						local label = (t.name and tostring(t.name)) or ('Team ' .. tostring(t.id))
						-- avoid a label clashing with 'All Teams' or duplicates
						if label ~= 'All Teams' and not teamLabelToId[label] then
							teamNames[#teamNames + 1] = label
							teamLabelToId[label] = t.id
						end
					end
				end
			end)
			pcall(function() SpectateTeam:Change(teamNames) end)
		end
		refreshList()
		vain:Clean(playersService.PlayerAdded:Connect(refreshList))
		vain:Clean(playersService.PlayerRemoving:Connect(function() task.defer(refreshList) end))
	end


	-- ══════════════════════════════════════════════════════════════════════════
	--  TABLIST WINSTREAK  (show each player's winstreak next to their tab-list name)
	-- ══════════════════════════════════════════════════════════════════════════
	-- BedWars uses a custom tab-list (the default PlayerList is disabled) and a
	-- player's winstreak isn't replicated. NametagController:requestNametagData(plr)
	-- returns any player's { winstreak, rankDivision }, so we fetch it once per
	-- player (staggered + cached) and paint it onto the matching name label in the
	-- tab-list, re-applying on a loop since the tab-list is Roact and re-renders.
	do
		local TablistWinstreak
		local Global
		local ShowStreak, ShowWinrate, ShowMatches, ShowKD, ShowBeds
		local fetched = {}    -- userId -> true once fetched (dedupe)
		local fetching = {}   -- userId -> true while a request is in flight
		local statData = {}   -- lowercased name -> { ws, winrate, matches, kd, beds } (persists after they leave)

		-- Build the display string from raw stats, honoring the per-stat toggles.
		-- Kept separate from the fetch so toggling a stat off/on repaints instantly
		-- without re-requesting the (cached) profile.
		local function buildLabel(d)
			if not d then return nil end
			local parts = {}
			if (not ShowStreak or ShowStreak.Enabled) and d.ws and d.ws > 0 then
				parts[#parts + 1] = '\u{1F525} ' .. tostring(d.ws)
			end
			if (not ShowWinrate or ShowWinrate.Enabled) and d.winrate then
				parts[#parts + 1] = ('\u{1F3C6} %d%%'):format(d.winrate)
			end
			if (not ShowMatches or ShowMatches.Enabled) and d.matches and d.matches > 0 then
				parts[#parts + 1] = ('\u{1F3AE} %d'):format(d.matches)
			end
			if (not ShowKD or ShowKD.Enabled) and d.kd then
				parts[#parts + 1] = ('\u{2694} %.2f'):format(d.kd)
			end
			if (not ShowBeds or ShowBeds.Enabled) and d.beds then
				parts[#parts + 1] = ('\u{1F6CF} %.2f'):format(d.beds)
			end
			if #parts > 0 then return table.concat(parts, '  ') end
			return nil
		end

		local function displayNameOf(plr)
			local ok, dn = pcall(function() return bedwars.GamePlayer.getGamePlayer(plr):getDisplayName() end)
			if ok and type(dn) == 'string' and dn ~= '' then return dn end
			return (plr.DisplayName ~= '' and plr.DisplayName) or plr.Name
		end

		local function fetchWinstreak(plr)
			local uid = plr.UserId
			if fetched[uid] or fetching[uid] then return end
			fetching[uid] = true
			local dn, nm = displayNameOf(plr):lower(), plr.Name:lower()
			task.spawn(function()
				local data
				-- Full profile -> per-CURRENT-gamemode stats (winstreak, winrate, K/D).
				-- Privacy-gated: private/friends-only users reject it; we suppress the
				-- resulting notification (see installNotifFilter) and fall back below.
				local ok, profile = pcall(function()
					return bedwars.Client:Get('RequestProfileData'):CallServerAsync(plr):expect()
				end)
				-- Extract RAW stats defensively (profile.queues can be proxy/userdata, and a
				-- bad field read would kill this thread). We store numbers, not a string, so
				-- the per-stat toggles can rebuild the label at paint time.
				pcall(function()
					if not (ok and profile and profile.queues) then return end
					local ws, wins, losses, matches, kills, deaths, beds
					if Global and Global.Enabled then
						-- GLOBAL: sum every queue's totals + highest win streak of any mode.
						wins, losses, matches, kills, deaths, beds = 0, 0, 0, 0, 0, 0
						local best = 0
						for _, v in pairs(profile.queues) do
							if type(v) == 'table' then
								wins    = wins    + (tonumber(v.wins) or 0)
								losses  = losses  + (tonumber(v.losses) or 0)
								matches = matches + (tonumber(v.matches) or 0)
								kills   = kills   + (tonumber(v.kills) or 0)
								deaths  = deaths  + (tonumber(v.deaths) or 0)
								best    = math.max(best, tonumber(v.highestWinStreak) or 0)
								beds    = beds    + (tonumber(v.bedBreaks) or 0)
							end
						end
						ws = best
						if matches <= 0 then matches = wins + losses end
					else
						-- CURRENT gamemode only.
						local qt = bedwars.Store:getState().Game.queueType
						local q = qt and profile.queues[qt]
						if not q then return end
						ws      = tonumber(q.currentWinStreak) or 0
						wins    = tonumber(q.wins) or 0
						losses  = tonumber(q.losses) or 0
						matches = tonumber(q.matches) or 0
						kills   = tonumber(q.kills) or 0
						deaths  = tonumber(q.deaths) or 0
						beds    = tonumber(q.bedBreaks) or 0
						if matches <= 0 then matches = wins + losses end
					end
					data = {
						ws      = ws,
						winrate = matches > 0 and math.floor(wins / matches * 100 + 0.5) or nil,
						matches = matches,
						kd      = (kills > 0 or deaths > 0) and (deaths > 0 and (kills / deaths) or kills) or nil,
						beds    = (matches > 0 and beds > 0) and (beds / matches) or nil,
					}
				end)
				-- private/friends-only profiles reject RequestProfileData -> data stays
				-- nil and nothing is shown for them (no global-streak fallback).
				fetched[uid] = true
				fetching[uid] = nil
				-- key by name so it still matches the row after the player leaves
				if data then statData[dn] = data; statData[nm] = data end
			end)
		end

		local function stripTags(s)
			return (s:gsub('<[^>]->', ''))
		end

		-- normalise a label's text for matching: drop rich-text tags, a leading
		-- "[..]" (level/kill) tag, and surrounding whitespace.
		local function clean(s)
			s = stripTags(s)
			s = s:gsub('^%s*%b[]%s*', '')
			s = s:gsub('^%s+', ''):gsub('%s+$', '')
			return s:lower()
		end

		local function paint()
			-- fetch everyone at once (each request is cached, so a player is only
			-- ever requested a single time -> the private-profile notif, which we
			-- also suppress, can fire at most once and we batch them away instantly)
			for _, plr in playersService:GetPlayers() do
				fetchWinstreak(plr)
			end
			if not next(statData) then return end

			-- Only paint the ALLOWED containers: the tab-list LEADERBOARD and the
			-- SPECTATE selector nametag. Matching player names anywhere in PlayerGui
			-- also caught the kill feed, target list, etc. -- so require the label to
			-- live inside one of those named ancestors. (The Preparation Preview UI
			-- renders its own stats separately and isn't scraped here.)
			local pg = lplr:FindFirstChild('PlayerGui')
			if not pg then return end
			local function isAllowedContainer(gui)
				local a = gui
				while a and a ~= pg do
					local n = a.Name:lower()
					if n:find('leaderboard') or n:find('tablist')
						or (n:find('tab') and n:find('list'))
						or n:find('spectat') then
						return true
					end
					a = a.Parent
				end
				return false
			end
			for _, gui in pg:GetDescendants() do
				if gui:IsA('TextLabel') and isAllowedContainer(gui) then
					-- Match on the ORIGINAL name, not the current text: once painted,
					-- gui.Text contains the visible stat glyphs (🔥 61% ...) which
					-- stripTags can't remove, so cleaning the live text no longer matches
					-- the player -> the row would flip painted/restored every second.
					local orig = gui:GetAttribute('VainWSOrig')
					-- If Roact recycled this label to a different player it resets .Text
					-- but keeps our attribute -> a stale orig. Detect that (current text no
					-- longer begins with orig) and drop it so we re-key off the fresh name.
					if orig and gui.Text:sub(1, #orig) ~= orig then
						orig = nil
						gui:SetAttribute('VainWSOrig', nil)
						gui:SetAttribute('VainWS', nil)
					end
					local key = clean(orig or gui.Text)
					local label = buildLabel(statData[key])
					local painted = gui:GetAttribute('VainWS')
					if label then
						-- Remember the untouched text once so we always rebuild FROM the
						-- original. Rebuilding every pass (instead of skip-if-painted) lets
						-- the per-stat toggles take effect without a Roact re-render.
						if not orig then
							orig = gui.Text
							gui:SetAttribute('VainWSOrig', orig)
						end
						local want = orig .. "  <font color='#FFD24D'>" .. label .. "</font>"
						if gui.Text ~= want then
							gui:SetAttribute('VainWS', true)
							gui.RichText = true
							gui.Text = want
						end
					elseif painted then
						-- All of this row's stats got toggled off -> restore the original.
						if type(orig) == 'string' then gui.Text = orig end
						gui:SetAttribute('VainWSOrig', nil)
						gui:SetAttribute('VainWS', nil)
					end
				end
			end
		end

		-- Drop the "profile visibility set to Private/Friends Only" spam that
		-- RequestProfileData triggers for private players. All notifications go
		-- through NotificationController.sendNotification, so we wrap it and drop
		-- any whose payload mentions "visibility", restoring it when disabled.
		local notifCtrl, origSendNotif
		local function installNotifFilter()
			if origSendNotif then return end
			local ok, ctrl = pcall(function()
				return Flamework.resolveDependency('@easy-games/game-core:client/controllers/notification-controller@NotificationController')
			end)
			if not ok or not ctrl or type(ctrl.sendNotification) ~= 'function' then return end
			notifCtrl, origSendNotif = ctrl, ctrl.sendNotification
			ctrl.sendNotification = function(selfc, payload, ...)
				if type(payload) == 'table' then
					for _, v in pairs(payload) do
						if type(v) == 'string' and v:lower():find('visibility') then return end
					end
				end
				return origSendNotif(selfc, payload, ...)
			end
		end
		local function removeNotifFilter()
			if notifCtrl and origSendNotif and notifCtrl.sendNotification ~= origSendNotif then
				notifCtrl.sendNotification = origSendNotif
			end
			origSendNotif = nil
		end

		TablistWinstreak = vain.Categories.Render:CreateModule({
			Name = 'Show Advanced Stats',
			Tooltip = "Shows each player's current-mode winstreak, winrate, K/D and matches by their name in the tab-list. Private profiles show nothing.",
			Function = function(callback)
				if callback then
					table.clear(fetched)
					table.clear(fetching)
					table.clear(statData)
					installNotifFilter()
					task.spawn(function()
						repeat
							pcall(paint)
							task.wait(1)
						until not TablistWinstreak.Enabled
						removeNotifFilter()
					end)
				end
			end
		})
		Global = TablistWinstreak:CreateToggle({
			Name = 'Global Stats',
			Tooltip = 'Show global stats across all gamemodes (highest streak, total winrate/K-D) instead of just the current mode.',
			Default = false,
			Function = function()
				-- Global vs current-mode changes the RAW numbers, so wipe the fetch
				-- cache + our painted tags; the paint loop rebuilds from fresh data.
				table.clear(fetched)
				table.clear(fetching)
				table.clear(statData)
				local pg = lplr:FindFirstChild('PlayerGui')
				if pg then
					for _, g in pg:GetDescendants() do
						if g:IsA('TextLabel') and g:GetAttribute('VainWS') then
							local orig = g:GetAttribute('VainWSOrig')
							if type(orig) == 'string' then g.Text = orig end
							g:SetAttribute('VainWSOrig', nil)
							g:SetAttribute('VainWS', nil)
						end
					end
				end
			end
		})
		-- Per-stat visibility toggles. These only affect the DISPLAY (buildLabel),
		-- so no cache wipe is needed -- the 1s paint loop repaints from cached raw
		-- numbers and rebuilds each label from its original text.
		ShowStreak = TablistWinstreak:CreateToggle({
			Name = 'Show Win Streak', Default = true,
			Tooltip = 'Show the \u{1F525} win streak stat.', Function = function() end,
		})
		ShowWinrate = TablistWinstreak:CreateToggle({
			Name = 'Show Winrate', Default = true,
			Tooltip = 'Show the \u{1F3C6} winrate stat.', Function = function() end,
		})
		ShowMatches = TablistWinstreak:CreateToggle({
			Name = 'Show Matches', Default = true,
			Tooltip = 'Show the \u{1F3AE} total matches stat.', Function = function() end,
		})
		ShowKD = TablistWinstreak:CreateToggle({
			Name = 'Show K/D', Default = true,
			Tooltip = 'Show the \u{2694} kill/death ratio stat.', Function = function() end,
		})
		ShowBeds = TablistWinstreak:CreateToggle({
			Name = 'Show Bed Breaks', Default = true,
			Tooltip = 'Show the \u{1F6CF} average beds broken per match stat.', Function = function() end,
		})
	end

	-- ══════════════════════════════════════════════════════════════════════════
	--  PARTY LIST  (show real party groupings -- tab-list tags and/or an overlay)
	-- ══════════════════════════════════════════════════════════════════════════
	-- Groupings come ONLY from MatchController.parties -- the real "who queued
	-- together" party list. Deliberately does NOT fall back to BedWars' colour
	-- teams: a team is just whoever the matchmaker put together, not a party, so
	-- treating it as one would tag total strangers as "grouped". The server only
	-- replicates real party data (MatchPartiesUpdate) for some queues, so this can
	-- legitimately show 0 groups in a queue that doesn't send it -- that's the
	-- game not sending the data, not a bug here.
	-- One module, two display modes (tab-list tag and/or a floating overlay).
	do
		local PartyList
		local ShowTablist, ShowOverlay, OnlyMulti
		local gui

		local PARTY_COLORS = {
			Color3.fromRGB(255, 92, 92), Color3.fromRGB(77, 166, 255),
			Color3.fromRGB(92, 224, 92), Color3.fromRGB(255, 210, 77),
			Color3.fromRGB(199, 125, 255), Color3.fromRGB(51, 224, 208),
			Color3.fromRGB(255, 154, 77), Color3.fromRGB(255, 111, 216),
		}
		local function hex(c)
			return string.format('#%02X%02X%02X',
				math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5))
		end

		local function matchController()
			local ok, c = pcall(function() return bedwars.MatchController end)
			return ok and c or nil
		end

		-- Returns a list of groups, each a list of userIds. Real party data only --
		-- see the block comment above for why team membership is deliberately not
		-- used as a fallback. Groups are de-duped by member set.
		local function collectGroups()
			local groups, seen = {}, {}
			local function add(members)
				if type(members) ~= 'table' then return end
				local ids, key = {}, {}
				for k, m in pairs(members) do
					-- members may be a LIST of userIds, or a MAP keyed by userId
					local uid = tonumber(m) or (type(m) == 'table' and tonumber(m.userId or m.UserId)) or tonumber(k)
					if uid then ids[#ids + 1] = uid key[#key + 1] = uid end
				end
				if #ids == 0 then return end
				table.sort(key)
				local sig = table.concat(key, ',')
				if not seen[sig] then seen[sig] = true groups[#groups + 1] = ids end
			end

			local mc = matchController()
			if mc then
				local parties = nil
				pcall(function() parties = mc.parties end)      -- direct field
				if type(parties) ~= 'table' or not next(parties) then
					pcall(function() if mc.getParties then parties = mc:getParties() end end)
				end
				if type(parties) == 'table' and next(parties) then
					for _, p in pairs(parties) do add(type(p) == 'table' and (p.members or p) or nil) end
				end
			end

			return groups
		end

		-- userId -> { idx, color } for every player in a shown group
		local function buildMap()
			local groups = collectGroups()
			-- filter to multi-member if requested
			local shown = {}
			for _, ids in ipairs(groups) do
				if not (OnlyMulti and OnlyMulti.Enabled) or #ids >= 2 then shown[#shown + 1] = ids end
			end
			local map = {}
			for i, ids in ipairs(shown) do
				local col = PARTY_COLORS[((i - 1) % #PARTY_COLORS) + 1]
				for _, uid in ipairs(ids) do map[uid] = { idx = i, color = col } end
			end
			return map, shown
		end

		-- ── tab-list painting ──────────────────────────────────────────────────
		local function stripTags(s) return (s:gsub('<[^>]->', '')) end
		-- Clean a tab-list label to just the player name: drop rich-text tags, then
		-- strip EVERY leading "[..]" group (level / clan / kills tags, e.g.
		-- "[151] [nwr] Fazpala" -> "fazpala"), plus surrounding whitespace + our own
		-- appended tag if present. This is why only some rows matched before -- names
		-- with a clan prefix were never stripped down to the bare name.
		local function nameKey(s)
			s = stripTags(s)
			-- remove repeated leading bracket tags
			while true do
				local ns = s:gsub('^%s*%b[]%s*', '')
				if ns == s then break end
				s = ns
			end
			return s:gsub('^%s+', ''):gsub('%s+$', ''):lower()
		end

		local function paintTablist(map)
			local pg = lplr:FindFirstChild('PlayerGui')
			if not pg then return end
			-- name -> info from live players (both Name and DisplayName as keys)
			local byName, partied = {}, {}
			for _, plr in playersService:GetPlayers() do
				local info = map[plr.UserId]
				if info then
					byName[plr.Name:lower()] = info
					if plr.DisplayName ~= '' then byName[plr.DisplayName:lower()] = info end
					partied[#partied + 1] = { name = plr.Name:lower(), disp = plr.DisplayName:lower(), info = info }
				end
			end
			-- fallback matcher: split the cleaned label into whitespace tokens and match
			-- a token exactly against a partied player's name/displayname. This survives
			-- any leftover prefix/suffix without fragile Lua patterns.
			local function resolve(key)
				local hit = byName[key]
				if hit then return hit end
				for token in key:gmatch('%S+') do
					for _, p in partied do
						if token == p.name or (p.disp ~= '' and token == p.disp) then
							return p.info
						end
					end
				end
				return nil
			end

			local function allowed(gui)
				local a = gui
				while a and a ~= pg do
					local n = a.Name:lower()
					if n:find('leaderboard') or n:find('tablist') or (n:find('tab') and n:find('list')) or n:find('spectat') then
						return true
					end
					a = a.Parent
				end
				return false
			end

			for _, g in pg:GetDescendants() do
				if g:IsA('TextLabel') and allowed(g) then
					local orig = g:GetAttribute('VainPartyOrig')
					if orig and g.Text:sub(1, #orig) ~= orig then
						orig = nil
						g:SetAttribute('VainPartyOrig', nil)
						g:SetAttribute('VainParty', nil)
					end
					local info = resolve(nameKey(orig or g.Text))
					local painted = g:GetAttribute('VainParty')
					if info and (not ShowTablist or ShowTablist.Enabled) then
						if not orig then orig = g.Text g:SetAttribute('VainPartyOrig', orig) end
						local tag = "<font color='" .. hex(info.color) .. "'>\u{25CF} P" .. info.idx .. "</font>"
						local want = orig .. "  " .. tag
						if g.Text ~= want then
							g:SetAttribute('VainParty', true)
							g.RichText = true
							g.Text = want
						end
					elseif painted then
						if type(orig) == 'string' then g.Text = orig end
						g:SetAttribute('VainPartyOrig', nil)
						g:SetAttribute('VainParty', nil)
					end
				end
			end
		end

		local function restoreTablist()
			local pg = lplr:FindFirstChild('PlayerGui')
			if not pg then return end
			for _, g in pg:GetDescendants() do
				if g:IsA('TextLabel') and g:GetAttribute('VainParty') then
					local orig = g:GetAttribute('VainPartyOrig')
					if type(orig) == 'string' then g.Text = orig end
					g:SetAttribute('VainPartyOrig', nil)
					g:SetAttribute('VainParty', nil)
				end
			end
		end

		-- ── overlay panel ──────────────────────────────────────────────────────
		local function buildOverlay(shown)
			if gui then gui:Destroy() gui = nil end
			if not (ShowOverlay and ShowOverlay.Enabled) or #shown == 0 then return end
			gui = Instance.new('ScreenGui')
			gui.Name = 'VainPartyList'
			gui.ResetOnSpawn = false
			gui.IgnoreGuiInset = true
			gui.DisplayOrder = 50
			gui.Parent = gethui and gethui() or lplr:WaitForChild('PlayerGui')

			local root = Instance.new('Frame')
			root.Size = UDim2.fromOffset(220, 0)
			root.AutomaticSize = Enum.AutomaticSize.Y
			root.Position = UDim2.new(0, 12, 0, 90)
			root.BackgroundColor3 = Color3.fromRGB(18, 18, 24)
			root.BackgroundTransparency = 0.15
			root.BorderSizePixel = 0
			root.Active = true
			root.Draggable = true
			root.Parent = gui
			Instance.new('UICorner', root).CornerRadius = UDim.new(0, 10)
			local pad = Instance.new('UIPadding')
			pad.PaddingTop = UDim.new(0, 8) pad.PaddingBottom = UDim.new(0, 8)
			pad.PaddingLeft = UDim.new(0, 8) pad.PaddingRight = UDim.new(0, 8)
			pad.Parent = root
			local list = Instance.new('UIListLayout')
			list.SortOrder = Enum.SortOrder.LayoutOrder
			list.Padding = UDim.new(0, 8)
			list.Parent = root

			local header = Instance.new('TextLabel')
			header.Size = UDim2.new(1, 0, 0, 22)
			header.BackgroundTransparency = 1
			header.Text = 'Parties (' .. #shown .. ')'
			header.TextColor3 = Color3.fromRGB(255, 178, 124)
			header.TextSize = 16
			header.Font = Enum.Font.GothamBold
			header.TextXAlignment = Enum.TextXAlignment.Left
			header.LayoutOrder = 0
			header.Parent = root

			for pi, ids in ipairs(shown) do
				local col = PARTY_COLORS[((pi - 1) % #PARTY_COLORS) + 1]
				local card = Instance.new('Frame')
				card.Size = UDim2.new(1, 0, 0, 0)
				card.AutomaticSize = Enum.AutomaticSize.Y
				card.BackgroundColor3 = Color3.fromRGB(30, 30, 40)
				card.BackgroundTransparency = 0.2
				card.BorderSizePixel = 0
				card.LayoutOrder = pi
				card.Parent = root
				Instance.new('UICorner', card).CornerRadius = UDim.new(0, 8)
				local stroke = Instance.new('UIStroke') stroke.Color = col stroke.Thickness = 1.5 stroke.Transparency = 0.2 stroke.Parent = card
				local cpad = Instance.new('UIPadding')
				cpad.PaddingTop = UDim.new(0, 6) cpad.PaddingBottom = UDim.new(0, 6)
				cpad.PaddingLeft = UDim.new(0, 6) cpad.PaddingRight = UDim.new(0, 6)
				cpad.Parent = card
				local clist = Instance.new('UIListLayout')
				clist.SortOrder = Enum.SortOrder.LayoutOrder
				clist.Padding = UDim.new(0, 4)
				clist.Parent = card

				local order = 0
				for _, uid in ipairs(ids) do
					local row = Instance.new('Frame')
					row.Size = UDim2.new(1, 0, 0, 30)
					row.BackgroundTransparency = 1
					row.LayoutOrder = order
					row.Parent = card
					order = order + 1
					local av = Instance.new('ImageLabel')
					av.Size = UDim2.fromOffset(26, 26)
					av.Position = UDim2.fromOffset(0, 2)
					av.BackgroundColor3 = Color3.fromRGB(45, 45, 55)
					av.BorderSizePixel = 0
					av.Image = 'rbxthumb://type=AvatarHeadShot&id=' .. tostring(uid) .. '&w=150&h=150'
					av.Parent = row
					Instance.new('UICorner', av).CornerRadius = UDim.new(0, 6)
					local plr = playersService:GetPlayerByUserId(uid)
					local nm = Instance.new('TextLabel')
					nm.Size = UDim2.new(1, -34, 1, 0)
					nm.Position = UDim2.fromOffset(34, 0)
					nm.BackgroundTransparency = 1
					nm.Text = plr and (plr.DisplayName ~= '' and plr.DisplayName or plr.Name) or ('#' .. tostring(uid))
					nm.TextColor3 = plr and (plr == lplr and Color3.fromRGB(120, 235, 140) or Color3.new(1, 1, 1)) or Color3.fromRGB(150, 150, 150)
					nm.TextSize = 15
					nm.Font = Enum.Font.GothamMedium
					nm.TextXAlignment = Enum.TextXAlignment.Left
					nm.TextTruncate = Enum.TextTruncate.AtEnd
					nm.Parent = row
				end
			end
		end

		local function tick_()
			local map, shown = buildMap()
			paintTablist(map)
			buildOverlay(shown)
		end

		PartyList = vain.Categories.Render:CreateModule({
			Name = 'Party List',
			Tooltip = "Shows real party groups (who queued together) as a coloured P# tag in the tab-list and an optional overlay. Not team-based -- a colour team isn't a party. Same group = same colour.",
			Function = function(callback)
				if callback then
					local _, shown = buildMap()
					notif('Party List', #shown > 0
						and ('%d part%s shown'):format(#shown, #shown == 1 and 'y' or 'ies')
						or 'No party data for this match (the game doesn\'t always send it)', 6, #shown > 0 and 'success' or 'warning')
					task.spawn(function()
						repeat
							pcall(tick_)
							task.wait(1)
						until not PartyList.Enabled
						pcall(restoreTablist)
						if gui then gui:Destroy() gui = nil end
					end)
				else
					pcall(restoreTablist)
					if gui then gui:Destroy() gui = nil end
				end
			end
		})
		ShowTablist = PartyList:CreateToggle({
			Name = 'Tab-list Tags', Default = true,
			Tooltip = 'Show the coloured party tag next to each player\'s tab-list name.',
			Function = function(on) if not on then pcall(restoreTablist) end end,
		})
		ShowOverlay = PartyList:CreateToggle({
			Name = 'Overlay Panel', Default = false,
			Tooltip = 'Show a floating draggable panel listing each party and its members (top-left).',
			Function = function(on) if not on and gui then gui:Destroy() gui = nil end end,
		})
		OnlyMulti = PartyList:CreateToggle({
			Name = 'Hide Solos', Default = true,
			Tooltip = 'Only mark groups of 2+ players (hide players alone in a group).',
		})
	end

	AimAssist = vain.Categories.Combat:CreateModule({
		Name = 'Aim Assist',
		Tooltip = 'Smoothly deflects your camera toward nearby enemies',
		Function = function(callback)
			if callback then
				lockedTarget = nil
				lastValidTarget = nil
				lastValidTime = 0
				shakeTime = 0
				AimAssist:Clean(runService.Heartbeat:Connect(function(dt)

					if not entitylib.isAlive or not entitylib.character or not entitylib.character.RootPart then
						lockedTarget = nil
						return
					end

					-- By default AimAssist works with any held item. 'Limit to item'
					-- restores the old behavior: only assist while holding a sword
					-- (or a bow/crossbow when Work With Projectiles is on).
					if LimitToItem and LimitToItem.Enabled then
						local validWeapon = store.hand.toolType == 'sword'
						if WorkWithProjectiles and WorkWithProjectiles.Enabled then
							validWeapon = validWeapon or isHoldingBowCrossbow()
						end
						if not validWeapon then
							lockedTarget = nil
							return
						end
					end

					-- ClickAim gates on a recent sword swing, which never fires for a bow.
					-- Skip the gate while holding a bow/crossbow so projectile assist works.
					if ClickAim and ClickAim.Enabled and not isHoldingBowCrossbow() then
						local sc = bedwars.SwordController
						if not sc or not sc.lastAttack or (workspace:GetServerTimeNow() - sc.lastAttack) >= 0.4 then
							return
						end
					end

					local inFirstPerson = isFirstPerson()
					if ViewMode.Value == 'First Person' and not inFirstPerson then return end
					if ViewMode.Value == 'Third Person' and inFirstPerson then return end

					if ShopCheck and ShopCheck.Enabled then
						if isGUIOpen() then
							lockedTarget = nil
							return
						end
					end

					local ent = nil

					if KillauraTarget and KillauraTarget.Enabled then
						local ka = store.KillauraTarget
						if ka and ka.RootPart and ka.Character and ka.Character.Parent then
							local hum = ka.Character:FindFirstChildOfClass('Humanoid')
							if hum and hum.Health > 0 then
								ent = ka
							end
						end
					else
						if PriorityMode and PriorityMode.Enabled and lockedTarget then
							if isEntValid(lockedTarget) and isInAngle(lockedTarget) then
								ent = lockedTarget
							else
								lockedTarget = nil
							end
						end

						if not ent then
							local found = entitylib.EntityPosition({
								Range = Distance.Value,
								Part = 'RootPart',
								Wallcheck = Targets.Walls.Enabled,
								Players = Targets.Players.Enabled,
								NPCs = Targets.NPCs.Enabled,
								Sort = sortmethods[Sort.Value],
								-- The library calls this Preference and takes the choice itself,
								-- rather than a lookup: 'None' and nil are no-ops there. It was
								-- indexing a table that was never written, so acquiring a target
								-- threw on every frame instead of picking one.
								Preference = TargetPriority.Value
							})

							if found then
								lastValidTarget = found
								lastValidTime = tick()
								ent = found
							elseif lastValidTarget and (tick() - lastValidTime) < GRACE_PERIOD then
								if isEntValid(lastValidTarget) and isInAngle(lastValidTarget) then
									ent = lastValidTarget
								else
									lastValidTarget = nil
								end
							end

							if ent and PriorityMode and PriorityMode.Enabled then
								lockedTarget = ent
							end
						end
					end

					if not ent then return end

					if not (KillauraTarget and KillauraTarget.Enabled) then
						if not isEntValid(ent) then
							if PriorityMode and PriorityMode.Enabled then lockedTarget = nil end
							lastValidTarget = nil
							return
						end
						if not isInAngle(ent) then
							if PriorityMode and PriorityMode.Enabled then lockedTarget = nil end
							return
						end
					end

					-- Min Distance: don't assist on targets closer than this (avoids
					-- snapping at point-blank where you don't need help).
					if MinDistance and MinDistance.Value > 0 and ent.RootPart and entitylib.character.RootPart then
						if (ent.RootPart.Position - entitylib.character.RootPart.Position).Magnitude < MinDistance.Value then
							return
						end
					end

					-- Target Health filter: only assist when the target is at or below
					-- the chosen health. BedWars stores real health on the character's
					-- 'Health' attribute (Humanoid.Health is often a fixed 100), and
					-- entitylib mirrors it on ent.Health — use that, like the Health sort.
					if HealthCheck and HealthCheck.Enabled then
						local hp = ent.Health
						if hp == nil and ent.Character then
							hp = ent.Character:GetAttribute('Health')
						end
						if hp and hp > (HealthThreshold and HealthThreshold.Value or 100) then
							return
						end
					end

					targetinfo.Targets[ent] = tick() + 1

					local aimPosition
					if AimPart.Value == 'Head' then
						local head = ent.Character and ent.Character:FindFirstChild('Head')
						aimPosition = head and head.Position or ent.RootPart.Position
					elseif AimPart.Value == 'Torso' then
						local torso = ent.Character and (ent.Character:FindFirstChild('UpperTorso') or ent.Character:FindFirstChild('Torso'))
						aimPosition = torso and torso.Position or ent.RootPart.Position
					elseif AimPart.Value == 'Closest' then
						local closest = ent.Character and getClosestPartToCursor(ent.Character)
						aimPosition = closest and closest.Position or ent.RootPart.Position
					else
						aimPosition = ent.RootPart.Position
					end

					if ShakeToggle and ShakeToggle.Enabled and ShakeAmount.Value > 0 then
						shakeTime = shakeTime + dt
						local intensity = ShakeAmount.Value * 0.045
						local sx = math.sin(shakeTime * 17.3) * intensity + math.sin(shakeTime * 5.7) * intensity * 0.4
						local sy = math.cos(shakeTime * 13.1) * intensity + math.cos(shakeTime * 8.3) * intensity * 0.3
						local sz = math.sin(shakeTime * 9.7 + 1.2) * intensity * 0.5
						if rng:NextNumber() < 0.08 then
							sx = sx + (rng:NextNumber() - 0.5) * intensity * 1.6
							sy = sy + (rng:NextNumber() - 0.5) * intensity * 1.6
						end
						aimPosition = aimPosition + Vector3.new(sx, sy, sz)
					end

					local targetCFrame = CFrame.lookAt(gameCamera.CFrame.p, aimPosition)
					if SmoothnessToggle and SmoothnessToggle.Enabled then
						local speed = getSmoothedSpeed(AimSpeed.Value, Smoothness.Value, dt)
						gameCamera.CFrame = gameCamera.CFrame:Lerp(targetCFrame, math.min(speed * (dt * 60), 0.95))
					else
						gameCamera.CFrame = gameCamera.CFrame:Lerp(targetCFrame, math.clamp(AimSpeed.Value * dt, 0, 0.95))
					end
				end))
			else
				lockedTarget = nil
				lastValidTarget = nil
			end
		end,
		Tooltip = 'Aim assist with smooth target tracking'
	})

	Targets = AimAssist:CreateTargets({
		Tooltip = 'Configure which types of targets to include',
		Players = true,
		Walls = true
	})

	local methods = {'Damage', 'Distance'}
	for i in sortmethods do
		if not table.find(methods, i) then
			table.insert(methods, i)
		end
	end

	Sort = AimAssist:CreateDropdown({
		Name = 'Target Mode',
		List = methods,
		Tooltip = 'How to prioritize targets',
		ItemTooltips = {
			Distance = 'Targets the closest enemy by stud distance',
			Health = 'Targets the enemy with the lowest remaining health',
			Angle = 'Targets the enemy closest to your look direction',
			Cursor = 'Targets the enemy nearest to your mouse cursor',
			Damage = 'Targets the enemy who most recently took damage',
			Threat = 'Targets the enemy judged to be the greatest combat threat',
			Kit = 'Prioritizes dangerous kit users (Hannah, Spirit Assassin, etc.)',
		},
	})

	TargetPriority = AimAssist:CreateDropdown({
		Name = 'Target Priority',
		List = {'None', 'Players', 'NPCs'},
		Default = 'None',
		Tooltip = 'When both are valid targets, prefer this type over the other',
	})

	AimPart = AimAssist:CreateDropdown({
		Name = 'Aim Part',
		Tooltip = 'Which body part on the target to aim at',
		List = {'Torso', 'Head', 'Closest'},
		Default = 'Torso',
		ItemTooltips = {
			Torso = 'Aims at the center of the player\'s body — reliable and easy to hit',
			Head = 'Aims at the head — higher damage potential but smaller hitbox',
			Closest = 'Aims at whichever body part is nearest to your crosshair',
		}
	})

	ViewMode = AimAssist:CreateDropdown({
		Name = 'View Mode',
		List = {'Both', 'First Person', 'Third Person'},
		Default = 'Both',
		Tooltip = 'Which camera view this aims in',
		Tooltips = {
			Both = 'Aims in either view',
			['First Person'] = 'Only while the camera is in your head',
			['Third Person'] = 'Only while the camera is behind you'
		},
	})

	AimSpeed = AimAssist:CreateSlider({
		Name = 'Aim Speed',
		Min = 1,
		Max = 20,
		Default = 6,
		Tooltip = 'How fast aim assist moves toward the target'
	})

	Distance = AimAssist:CreateSlider({
		Name = 'Distance',
		Tooltip = 'Maximum distance in studs',
		Min = 1,
		Max = 30,
		Default = 25,
		Suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})

	AngleSlider = AimAssist:CreateSlider({
		Name = 'Max Angle',
		Min = 1,
		Max = 360,
		Default = 60,
		Tooltip = 'FOV cone for target acquisition'
	})

	MinDistance = AimAssist:CreateSlider({
		Name = 'Min Distance',
		Tooltip = 'Don\'t assist on targets closer than this (0 = no minimum)',
		Min = 0,
		Max = 50,
		Default = 0,
		Suffix = function(val)
			return val <= 1 and 'stud' or 'studs'
		end
	})

	SmoothnessToggle = AimAssist:CreateToggle({
		Name = 'Smoothness',
		Default = false,
		Tooltip = 'Makes aim assist feel more legit',
		Function = function(callback)
			if Smoothness then Smoothness.Object.Visible = callback end
		end
	})

	Smoothness = AimAssist:CreateSlider({
		Name = 'Smoothness Amount',
		Min = 1,
		Max = 10,
		Default = 5,
		Tooltip = 'Higher = smoother and more legit.',
		Visible = false
	})

	PriorityMode = AimAssist:CreateToggle({
		Name = 'Priority Mode',
		Default = false,
		Tooltip = 'Locks onto one target. Ignores closer targets until current is lost.'
	})

	ClickAim = AimAssist:CreateToggle({
		Name = 'Click Aim',
		Default = true,
		Tooltip = 'Only aims when attacking'
	})

	KillauraTarget = AimAssist:CreateToggle({
		Name = 'Use Killaura Target',
		Tooltip = 'Follow Killaura target only, bypasses all distance and wall filters'
	})

	ShakeToggle = AimAssist:CreateToggle({
		Name = 'Shake',
		Default = false,
		Tooltip = 'Adds legit-looking human jitter to aim',
		Function = function(callback)
			if ShakeAmount then ShakeAmount.Object.Visible = callback end
		end
	})

	ShakeAmount = AimAssist:CreateSlider({
		Name = 'Shake Amount',
		Tooltip = 'Adjusts the shake amount value',
		Min = 1,
		Max = 10,
		Default = 3,
		Visible = false
	})

	ShopCheck = AimAssist:CreateToggle({
		Name = 'Shop Check',
		Default = false,
		Tooltip = 'Disables aim assist when the shop is open'
	})

	WorkWithProjectiles = AimAssist:CreateToggle({
		Name = 'Work With Projectiles',
		Default = false,
		Tooltip = 'Also activates when holding bows or crossbows (only matters with Limit to item on)'
	})

	LimitToItem = AimAssist:CreateToggle({
		Name = 'Limit to item',
		Default = false,
		Tooltip = 'Only assist while holding a weapon (sword, or bow/crossbow with Work With Projectiles). Off = any held item.'
	})

	HealthCheck = AimAssist:CreateToggle({
		Name = 'Target HP Check',
		Default = false,
		Tooltip = 'Only assist when the target is at or below the chosen health',
		Function = function(callback)
			if HealthThreshold and HealthThreshold.Object then
				HealthThreshold.Object.Visible = callback
			end
		end
	})

	HealthThreshold = AimAssist:CreateSlider({
		Name = 'Target Health',
		Tooltip = 'Maximum target health to assist on',
		Min = 1,
		Max = 100,
		Default = 100,
		Darker = true,
		Visible = false
	})

	task.defer(function()
		if Smoothness and Smoothness.Object then
			Smoothness.Object.Visible = SmoothnessToggle and SmoothnessToggle.Enabled or false
		end
		if ShakeAmount and ShakeAmount.Object then
			ShakeAmount.Object.Visible = false
		end
	end)
end)

kitRun(function()
	local KaidaKillaura	
	local Targets
	local AttackRange
	local UpdateRate
	local MouseDown
	local GUICheck
	local ShowAnimation
	local AutoAbility
	local AbilityDistance
	local SwingDuringAbility
	local lastAttackTime = 0
	local lastAbilityTime = 0
	local attackCooldown = 0.55
	local abilityCooldown = 22
	local isChargingAbility = false
	manualCharging = false
	local currentTarget = nil
	local AutoStopAbility
	local SummonerKitController = nil
	local function getSummonerController()
		if SummonerKitController then return SummonerKitController end
		pcall(function()
			SummonerKitController = bedwars.KnitClient.Controllers.SummonerKitController
		end)
		return SummonerKitController
	end

	local function isActuallyCharging()
		if isChargingAbility then return true end
		if manualCharging then return true end
		local result = false
		pcall(function()
			local btns = lplr.PlayerGui
				:FindFirstChild("ActionBarScreenGui")
				and lplr.PlayerGui.ActionBarScreenGui:FindFirstChild("ActionBar")
				and lplr.PlayerGui.ActionBarScreenGui.ActionBar:FindFirstChild("AbilityButtons")
			if btns and btns:FindFirstChild("summoner_finish_charging") then
				result = true
			end
		end)
		return result
	end

	local function getSpellLevel()
		local level = 1
		pcall(function()
			local util = require(game:GetService("ReplicatedStorage").TS.games.bedwars.kit.kits.summoner['summoner-kit-util'])
			local result = util.summoner_getPlayerSpellLevel(lplr)
			if result then level = result end
		end)
		return level
	end

	local function getCastTime(level)
		local castTime = 2
		pcall(function()
			local util = require(game:GetService("ReplicatedStorage").TS.games.bedwars.kit.kits.summoner['summoner-kit-util'])
			local result = util.summoner_getTotalCastTimeRequired(level)
			if result then castTime = result end
		end)
		return castTime
	end

	local function fireUseAbility(abilityName)
		pcall(function()
			game:GetService("ReplicatedStorage")
				:WaitForChild("events-@easy-games/game-core:shared/game-core-networking@getEvents.Events")
				:WaitForChild("useAbility"):FireServer(abilityName)
		end)
	end

	local function doAutoAbility()
		if isChargingAbility then return end
		isChargingAbility = true

		pcall(function()
			local remote = game:GetService("ReplicatedStorage")
				:WaitForChild("events-@easy-games/game-core:shared/game-core-networking@getEvents.Events")
				:WaitForChild("useAbility")

			remote:FireServer(unpack({"summoner_start_charging"}))

			if AutoStopAbility.Enabled then
				task.wait(0.5)
				remote:FireServer(unpack({"summoner_finish_charging"}))
			else
				local level = getSpellLevel()
				local castTime = getCastTime(level)
				task.wait(math.max(castTime, 0.5))
				if isChargingAbility then
					remote:FireServer(unpack({"summoner_finish_charging"}))
					if currentTarget and currentTarget.RootPart then
						local myPos = entitylib.character.RootPart.Position
						local shootDir = CFrame.lookAt(myPos, currentTarget.RootPart.Position).LookVector
						local localPosition = myPos + shootDir * math.max((myPos - currentTarget.RootPart.Position).Magnitude - 16, 0)
						bedwars.Client:Get(remotes.SummonerClawAttack):SendToServer({
							position = localPosition,
							direction = shootDir,
							clientTime = workspace:GetServerTimeNow()
						})
					end
				end
			end
		end)

		lastAbilityTime = tick()
		isChargingAbility = false
	end

	local function getPlayerClawLevel()
		local handItem = lplr.Character and lplr.Character:FindFirstChild('HandInvItem')
		if handItem and handItem.Value then
			local itemType = handItem.Value.Name
			if itemType == 'summoner_claw_1' then return 1 end
			if itemType == 'summoner_claw_2' then return 2 end
			if itemType == 'summoner_claw_3' then return 3 end
			if itemType == 'summoner_claw_4' then return 4 end
		end
		if store and store.inventory and store.inventory.hotbar then
			for _, v in pairs(store.inventory.hotbar) do
				if v.item then
					local itemType = v.item.itemType
					if itemType == 'summoner_claw_1' then return 1 end
					if itemType == 'summoner_claw_2' then return 2 end
					if itemType == 'summoner_claw_3' then return 3 end
					if itemType == 'summoner_claw_4' then return 4 end
				end
			end
		end
		return 1
	end

	KaidaKillaura = vain.Categories.Kit:CreateModule({
		Name = 'Auto Kaida',
		Tooltip = 'Automates the Kaida kit flame breath ability',
		Function = function(callback)
			if callback then
				lastAttackTime = 0
				lastAbilityTime = 0
				isChargingAbility = false
				manualCharging = false   
				pcall(function()
					local abilityButtons = lplr.PlayerGui
						:WaitForChild("ActionBarScreenGui", 10)
						:WaitForChild("ActionBar", 10)
						:WaitForChild("AbilityButtons", 10)

					KaidaKillaura:Clean(abilityButtons.ChildRemoved:Connect(function(child)
						if child.Name == "summoner_start_charging" then
							manualCharging = true
						end
						if child.Name == "summoner_finish_charging" then
							manualCharging = false
						end
					end))

					KaidaKillaura:Clean(abilityButtons.ChildAdded:Connect(function(child)
						if child.Name == "summoner_start_charging" then
							manualCharging = false
						end
					end))

					if abilityButtons:FindFirstChild("summoner_finish_charging") then
						manualCharging = true
					end
				end)

				repeat
					if not entitylib.isAlive then
						task.wait(0.1)
						continue
					end

					if GUICheck.Enabled then
						if bedwars.AppController:isLayerOpen(bedwars.UILayers.MAIN) then
							task.wait(0.1)
							continue
						end
					end

					local handItem = lplr.Character:FindFirstChild('HandInvItem')
					local hasClaw = handItem and handItem.Value and handItem.Value.Name:find('summoner_claw') ~= nil

					if MouseDown.Enabled then
						if not inputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) then
							task.wait(1.2)
							continue
						end
					end

					local plr = nil
					do
						local bestDot = -math.huge
						local camCF = workspace.CurrentCamera.CFrame
						local myPos = entitylib.character.RootPart.Position
						for _, ent in ipairs(entitylib.List) do
							local validType = (Targets.Players.Enabled and ent.Player) or (Targets.NPCs.Enabled and ent.NPC)
							if validType and ent.Targetable and ent.RootPart and ent.Health > 0 then
								local dist = (myPos - ent.RootPart.Position).Magnitude
								if dist <= AttackRange.Value then
									local toEnt = (ent.RootPart.Position - camCF.Position).Unit
									local dot = camCF.LookVector:Dot(toEnt)
									if dot <= 0 then continue end
									if dot > bestDot then
										bestDot = dot
										plr = ent
									end
								end
							end
						end
					end

					if plr and plr.Health > 0 then
						local localPosition = entitylib.character.RootPart.Position
						local targetDistance = (localPosition - plr.RootPart.Position).Magnitude
						local now = tick()

						if AutoAbility.Enabled and targetDistance <= AbilityDistance.Value * 1.25 then
							if not isChargingAbility and (now - lastAbilityTime) >= abilityCooldown then
								currentTarget = plr
								task.spawn(doAutoAbility)
							end
						end

						if not SwingDuringAbility.Enabled and isChargingAbility then
							task.wait(0.05)
							continue
						end

						if hasClaw then
							local charging = isActuallyCharging()

							if not SwingDuringAbility.Enabled and charging then
								task.wait(0.05)
								continue
							end

							if (now - lastAttackTime) >= attackCooldown and targetDistance <= AttackRange.Value then
								local shootDir = CFrame.lookAt(localPosition, plr.RootPart.Position).LookVector
								localPosition += shootDir * math.max((localPosition - plr.RootPart.Position).Magnitude - 16, 0)
								lastAttackTime = now

								if ShowAnimation.Enabled then
									task.spawn(function()
										pcall(function()
											local clawLevel = getPlayerClawLevel()
											bedwars.AnimationUtil:playAnimation(lplr, bedwars.GameAnimationUtil:getAssetId(bedwars.AnimationType.SUMMONER_CHARACTER_SWIPE), {
												looped = false
											})
											local clawModel = replicatedStorage.Assets.Misc.Kaida.Summoner_DragonClaw:Clone()
											local clawColors = {
												Color3.fromRGB(75, 75, 75),
												Color3.fromRGB(255, 255, 255),
												Color3.fromRGB(43, 229, 229),
												Color3.fromRGB(49, 229, 94)
											}
											local nailMesh = clawModel:FindFirstChild("dragon_claw_nail_mesh")
											if nailMesh and nailMesh:IsA("MeshPart") then
												nailMesh.Color = clawColors[clawLevel] or clawColors[1]
											end
											if bedwars.KnightClient and bedwars.KnightClient.Controllers.SummonerKitSkinController then
												if bedwars.KnightClient.Controllers.SummonerKitSkinController:isPrismaticSkin(lplr) then
													bedwars.KnightClient.Controllers.SummonerKitSkinController:applyClawRGB(clawModel)
												end
											end
											clawModel.Parent = workspace
											local camera = workspace.CurrentCamera
											if camera and (camera.CFrame.Position - entitylib.character.RootPart.Position).Magnitude < 1 then
												for _, part in clawModel:GetDescendants() do
													if part:IsA('MeshPart') then
														part.Transparency = 0.6
													end
												end
											end
											local rootPart = entitylib.character.RootPart
											local Unit = Vector3.new(shootDir.X, 0, shootDir.Z).Unit
											local startPos = rootPart.Position + Unit:Cross(Vector3.new(0, 1, 0)).Unit * -1 * 5 + Unit * 6
											local direction = (startPos + shootDir * 13 - startPos).Unit
											local cframe = CFrame.new(startPos, startPos + direction)
											clawModel:PivotTo(cframe)
											clawModel.PrimaryPart.Anchored = true
											local portalConn = nil
											if clawModel:FindFirstChild("Portal1") then
												portalConn = runService.Heartbeat:Connect(function()
													if not clawModel or not clawModel.Parent then
														portalConn:Disconnect()
														portalConn = nil
														return
													end
													local foreArmCF = clawModel.RootPart.root.fore_arm.TransformedWorldCFrame
													if clawModel.Portal1 then
														clawModel.Portal1:PivotTo(foreArmCF)
													end
													if clawModel.Portal2 then
														clawModel.Portal2:PivotTo(foreArmCF * CFrame.Angles(math.pi, 0, 0))
													end
												end)
											end
											if clawModel:FindFirstChild('AnimationController') then
												local animator = clawModel.AnimationController:FindFirstChildOfClass('Animator')
												if animator then
													bedwars.AnimationUtil:playAnimation(animator, bedwars.GameAnimationUtil:getAssetId(bedwars.AnimationType.SUMMONER_CLAW_ATTACK), {
														looped = false,
														speed = 1
													})
												end
											end
											pcall(function()
												local sounds = {
													bedwars.SoundList.SUMMONER_CLAW_ATTACK_1,
													bedwars.SoundList.SUMMONER_CLAW_ATTACK_2,
													bedwars.SoundList.SUMMONER_CLAW_ATTACK_3,
													bedwars.SoundList.SUMMONER_CLAW_ATTACK_4
												}
												bedwars.SoundManager:playSound(sounds[math.random(1, #sounds)], {
													position = rootPart.Position
												})
											end)
											task.wait(0.5)
											if portalConn then
												portalConn:Disconnect()
												portalConn = nil
											end
											clawModel:Destroy()
										end)
									end)
								end

								bedwars.Client:Get(remotes.SummonerClawAttack):SendToServer({
									position = localPosition,
									direction = shootDir,
									clientTime = workspace:GetServerTimeNow()
								})
							end
						end
					else
						if isChargingAbility then
							isChargingAbility = false
							fireUseAbility("summoner_finish_charging")
						end
					end

					task.wait(1 / UpdateRate.Value)
				until not KaidaKillaura.Enabled

				isChargingAbility = false
			end
		end,
		Tooltip = 'Auto attacks with Summoner claw'
	})

	Targets = KaidaKillaura:CreateTargets({
		Tooltip = 'Configure which types of targets to include',
		Players = true,
		NPCs = true,
		Walls = true
	})

	AttackRange = KaidaKillaura:CreateSlider({
		Name = 'Attack Range',
		Tooltip = 'Distance at which the hit packet is sent',
		Min = 1,
		Max = 32,
		Default = 22,
		Suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})

	UpdateRate = KaidaKillaura:CreateSlider({
		Name = 'Update Rate',
		Tooltip = 'How often to scan for targets (seconds)',
		Min = 1,
		Max = 120,
		Default = 60,
		Suffix = 'hz'
	})

	MouseDown = KaidaKillaura:CreateToggle({
		Name = 'Require Mouse Down',
		Tooltip = 'Only attacks while holding left click'
	})

	GUICheck = KaidaKillaura:CreateToggle({
		Name = 'GUI Check',
		Tooltip = 'Pauses the module when a GUI menu is open',
	})

	ShowAnimation = KaidaKillaura:CreateToggle({
		Name = 'Show Animation',
		Tooltip = 'Plays the attack animation during killaura hits',
		Default = true
	})

	SwingDuringAbility = KaidaKillaura:CreateToggle({
		Name = 'Swing During Ability',
		Default = true,
		Tooltip = 'Continue claw attacks while charging ability'
	})

	AutoAbility = KaidaKillaura:CreateToggle({
		Name = 'Auto Ability',
		Default = false,
		Tooltip = 'Automatically uses ability when enemy is within distance',
		Function = function(callback)
			if not callback then
				isChargingAbility = false
			end
			AbilityDistance.Object.Visible = callback
			AutoStopAbility.Object.Visible = callback
		end
	})

	AbilityDistance = KaidaKillaura:CreateSlider({
		Name = 'Ability Distance',
		Min = 3,
		Max = 15,
		Default = 6,
		Visible = false,
		Tooltip = 'Distance to trigger ability',
		Suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})

	AutoStopAbility = KaidaKillaura:CreateToggle({
		Name = 'Auto Stop Ability',
		Default = true,
		Visible = false,
		Tooltip = 'Cancels ability early if target leaves range mid-cast'
	})

	task.defer(function()
		if AbilityDistance and AbilityDistance.Object then
			AbilityDistance.Object.Visible = false   
		end
	end)
end)

kitRun(function()
    local AutoLasso
    local Targets
    local Range
    local FOV
    local AimPart
    local PredictionMode
    local projectileRemote = {InvokeServer = function() end}
    local nextAllowedShot = 0
    local rayCheck = RaycastParams.new()
    local COOLDOWN_SECONDS = 10.5

    task.spawn(function()
        projectileRemote = bedwars.Client:Get(remotes.FireProjectile).instance
    end)

    local function getLassoSlot()
        for i, v in store.inventory.hotbar do
            if v.item and v.item.itemType == "lasso" then
                return i - 1, v.item
            end
        end
        return nil, nil
    end

    local function getLassoProjectileMeta()
        local meta = bedwars.ProjectileMeta and bedwars.ProjectileMeta["lasso"]
        if meta then
            return meta.launchVelocity or 100, meta.gravitationalAcceleration or 196.2
        end
        return 100, 196.2
    end

    local function shootLasso(targetEnt)
        if not targetEnt or not targetEnt.RootPart then return false end

        local now = tick()
        if now < nextAllowedShot then return false end

        local lassoSlot, lassoItem = getLassoSlot()
        if not lassoSlot or not lassoItem then return false end

        local selfpos = entitylib.character.RootPart.Position
        local targetPart = targetEnt.RootPart

        if AimPart.Value == "Head" and targetEnt.Head then
            targetPart = targetEnt.Head
        elseif AimPart.Value == "Torso" then
            local torso = targetEnt.Character:FindFirstChild("UpperTorso") or targetEnt.Character:FindFirstChild("Torso")
            if torso then targetPart = torso end
        end

        local projSpeed, gravity = getLassoProjectileMeta()
        local targetPos = targetPart.Position
        local targetVel = targetPart.Velocity

        local aimPos = targetPos
        if PredictionMode.Value == "On" then
            local calc = prediction.SolveTrajectory(
                selfpos, projSpeed, gravity,
                targetPos, targetVel,
                workspace.Gravity, targetEnt.HipHeight,
                targetEnt.Jumping and 42.6 or nil,
                rayCheck
            )
            local targetRoot = plr.RootPart
						if targetRoot then
							local targetRootVel = targetRoot.AssemblyLinearVelocity or targetRoot.Velocity or Vector3.zero
							local targetMovingUp = targetRootVel.Y > 3
							local heightDiff = aimTarget.Y - newlook.p.Y
							if targetMovingUp then
								aimTarget = aimTarget + Vector3.new(0, math.clamp(targetRootVel.Y * 0.08, 0.5, 3.5), 0)
							elseif heightDiff < -8 then
								aimTarget = aimTarget + Vector3.new(0, math.clamp(math.abs(heightDiff) * 0.04, 0.3, 2.5), 0)
							end
						end
						if calc then aimPos = calc end
        end

        local dir = CFrame.lookAt(selfpos, aimPos).LookVector * projSpeed
        local originalSlot = store.inventory.hotbarSlot

        if originalSlot ~= lassoSlot then
            hotbarSwitch(lassoSlot)
            task.wait(0.05)
        end

        local success = pcall(function()
            projectileRemote:InvokeServer(
                lassoItem.tool,
                "lasso", "lasso",
                selfpos, selfpos, dir,
                httpService:GenerateGUID(true),
                {drawDurationSeconds = 1, shotId = httpService:GenerateGUID(false)},
                workspace:GetServerTimeNow() - 0.045
            )
        end)

        if originalSlot ~= lassoSlot then
            hotbarSwitch(originalSlot)
        end

        if success then
            nextAllowedShot = now + COOLDOWN_SECONDS
            targetinfo.Targets[targetEnt] = now + 1
            return true
        end
        return false
    end

    AutoLasso = vain.Categories.Kit:CreateModule({
        Name = 'Auto Lasso',
        Tooltip = 'Automatically uses the lasso on nearby enemies',
        Function = function(callback)
            if callback then
                repeat
                    if entitylib.isAlive then
                        local target = entitylib.EntityPosition({
                            Range = Range.Value,
                            Part = 'RootPart',
                            Wallcheck = Targets.Walls.Enabled,
                            Players = Targets.Players.Enabled,
                            NPCs = Targets.NPCs.Enabled,
                            Sort = sortmethods.Distance
                        })

                        if target then
							if getAccountTier(target.Player) >= 1 and getAccountTier(lplr) == 0 then continue end
                            local selfpos = entitylib.character.RootPart.Position
                            local localFacing = (ViewMode.Value == 'Third Person' and gameCamera.CFrame.LookVector or entitylib.character.RootPart.CFrame.LookVector) * Vector3.new(1, 0, 1)
                            local delta = (target.RootPart.Position - selfpos) * Vector3.new(1, 0, 1)
                            if delta.Magnitude > 0.001 then
                                local angle = math.acos(math.clamp(localfacing:Dot(delta.Unit), -1, 1))
                                if angle <= math.rad(FOV.Value) / 2 then
                                    shootLasso(target)
                                end
                            end
                        end
                    end
                    task.wait(0.05)
                until not AutoLasso.Enabled
            else
                nextAllowedShot = 0
            end
        end,
        Tooltip = 'Switches to lasso, shoots once, then switches back. 10.5 second cooldown.'
    })

    Targets = AutoLasso:CreateTargets({
    	Tooltip = 'Configure which types of targets to include',
        Players = true,
        NPCs = true,
        Walls = false
    })

    Range = AutoLasso:CreateSlider({
        Name = 'Range',
        Tooltip = 'Maximum distance in studs',
        Min = 5,
        Max = 80,
        Default = 50,
        Suffix = function(val)
            return val == 1 and 'stud' or 'studs'
        end
    })

    FOV = AutoLasso:CreateSlider({
        Name = 'FOV',
        Tooltip = 'Field-of-view cone in degrees for target detection',
        Min = 1,
        Max = 360,
        Default = 90
    })

    AimPart = AutoLasso:CreateDropdown({
        Name = 'Aim Part',
        Tooltip = 'Which body part on the target to aim at',
        List = {'RootPart', 'Head', 'Torso'},
        Default = 'RootPart',
        ItemTooltips = {
            RootPart = 'Aims at the center of the player\'s body (HumanoidRootPart)',
            Head = 'Aims at the head — higher damage potential but smaller hitbox',
            Torso = 'Aims at the upper torso',
        }
    })

    PredictionMode = AutoLasso:CreateDropdown({
        Name = 'Prediction',
        List = {'Off', 'On'},
        Default = 'On',
        Tooltip = 'Predict target movement for better accuracy',
        ItemTooltips = {
            Off = "Aims directly at the target's current position",
            On = 'Leads the shot based on target velocity for better hit rate',
        }
    })
end)

kitRun(function()
    local Beekeeper
    local Collect
    local LimitToItem
    local EquipNet
    local CollectRange
    local CollectDelay
    local Deposit
    local DepositRange
    local DepositDelay
    local BeeLimit
    local Legit
    local HiveESP
    local ShowAmount
    local ShowOwn
    local Background
    local Color = {}
    local Reference = {}
    local Folder = Instance.new('Folder')
    Folder.Parent = vain.gui

    -- Settings are created after CreateModule returns, so they can still be nil while
    -- this file is executing - and the module can be switched on inside that window when
    -- the GUI restores a saved config.
    local function on(setting)
        return setting ~= nil and setting.Enabled
    end

    local function value(setting, fallback)
        return setting ~= nil and setting.Value or fallback
    end

    --[[
        A wild bee, as opposed to one already tamed.

        Both carry the 'bee' tag: the ones worth catching, and the swarm circling a hive
        somebody has already filled. The tamed ones are handed a BeeId of -1 while a
        catchable bee carries a real id from the server - which is also the id the pickup
        has to be sent with, so one read decides both whether to bother and what to send.
    ]]
    local function beeId(v)
        local id = v:GetAttribute('BeeId')
        return type(id) == 'number' and id > 0 and id or nil
    end

    --[[
        Bees and hives are parts, not models.

        Every one of these was reached for through PrimaryPart, which is nil on a part, so
        the distance check below it never ran once and nothing was ever collected. Written
        to take either shape now.
    ]]
    local function partOf(v)
        if v:IsA('BasePart') then return v end
        return v:FindFirstChildWhichIsA('BasePart', true)
    end

    local function heldIs(itemType)
        local tool = store.hand and store.hand.tool
        return tool ~= nil and tool.Name == itemType
    end

    local function hotbarSlot(itemType)
        for i, v in store.inventory.hotbar do
            if v.item and v.item.itemType == itemType then
                return i - 1
            end
        end
    end

    --[[
        The net is what the game's own hand controller insists on before it will send a
        pickup, so the server has every reason to throw one away that arrives without it.

        Both halves of the switch are needed, which is why doing only the second did
        nothing: selecting the hotbar slot is what the game itself does, and sending the
        equip is what tells the server. A kit item like the net sits in the hotbar, so
        looking for it in the carried items alone never found it either.
    ]]
    local function equipNet()
        if heldIs('bee_net') then return true end

        local net = getItem('bee_net')
        local slot = hotbarSlot('bee_net')
        if not net and not slot then return false end

        if slot then
            hotbarSwitch(slot)
        end
        if net and net.tool then
            switchItem(net.tool)
        end
        return true
    end

    local function ownHive(hive)
        return hive:GetAttribute('PlacedByUserId') == lplr.UserId
    end

    --[[
        The colour of the team a hive belongs to.

        The queue's own team list carries it, as a plain integer rather than a Color3, and
        is keyed by an id that arrives as a string - so the list is walked and compared as
        numbers rather than indexed directly. White when the team cannot be worked out,
        which reads as no answer rather than as a wrong one.
    ]]
    --[[
        Which team a hive belongs to.

        Read off the block itself first. A hive cannot be broken by its own team, and that
        is recorded on it as a Team<N>NoBreak attribute, so the block states its own side
        without anyone having to still be in the server. Whoever placed it is the fallback,
        for the case where the attribute is absent.
    ]]
    local function hiveTeam(hive)
        local found
        for name in hive:GetAttributes() do
            local id = tonumber(name:match('^Team(%d+)NoBreak$'))
            if id and (not found or id < found) then
                found = id
            end
        end
        if found then return found end

        local placer = playersService:GetPlayerByUserId(hive:GetAttribute('PlacedByUserId') or 0)
        return placer and placer:GetAttribute('Team')
    end

    --[[
        The colour of the team a hive belongs to.

        Taken from the owner's own TeamColor, which is what the rest of Vain colours by -
        so a hive reads the same as the nametags above the players who own it. The queue's
        team list was the wrong source: its ids and a player's team are not numbered from
        the same end, so a blue team came out orange.

        Anyone still in the server on that team will do when whoever placed it has left.
    ]]
    local function hiveColor(hive)
        local placer = playersService:GetPlayerByUserId(hive:GetAttribute('PlacedByUserId') or 0)
        if placer and tostring(placer.TeamColor) ~= 'White' then
            return placer.TeamColor.Color
        end

        local team = hiveTeam(hive)
        if team then
            for _, plr in playersService:GetPlayers() do
                if plr:GetAttribute('Team') == team and tostring(plr.TeamColor) ~= 'White' then
                    return plr.TeamColor.Color
                end
            end
        end

        return Color3.new(1, 1, 1)
    end

    --[[
        Catching, one bee at a time.

        The remote is named here rather than looked up in the scraped table. That table
        works out a remote's name by finding 'Client' among a function's constants and
        taking the next one, which for this call lands on 'Get' rather than on the name
        itself - so every pickup was addressed to a remote that does not exist.
    ]]
    local function collect()
        if not entitylib.isAlive then return end

        local root = entitylib.character.RootPart
        local range = value(CollectRange, 30)

        for _, v in collectionService:GetTagged('bee') do
            if not (Beekeeper.Enabled and on(Collect)) then return end

            local id = beeId(v)
            local part = id and partOf(v)
            if not part then continue end
            if (root.Position - part.Position).Magnitude > range then continue end

            --[[
                Two stages, in this order on purpose.

                Limit to Item asks what is in your hand right now, so it has to be read
                before Equip Net has a chance to put the net there - otherwise the equip
                satisfies the very check that was meant to hold it back, and the setting
                does nothing at all.
            ]]
            if on(LimitToItem) and not heldIs('bee_net') then return end
            if on(EquipNet) and not equipNet() then return end

            --[[
                Caught the way the game catches.

                Sending the remote by hand delivers the id and nothing else - no swing
                animation, no sound, and none of whatever else the controller does on the
                way. Calling the controller runs the same path your own swing would, which
                is both likelier to be accepted and indistinguishable from playing.

                The raw send stays as a fallback for when the controller cannot be reached.
            ]]
            local sent = bedwars.BeeNetController and pcall(function()
                bedwars.BeeNetController:trigger(lplr, v)
            end)
            if not sent then
                bedwars.Client:Get('PickUpBee'):SendToServer({beeId = id})
            end

            local delay = value(CollectDelay, 0.1)
            if delay > 0 then
                task.wait(delay)
            end
        end
    end

    --[[
        Handing a caught bee to the nearest of your own hives.

        The hive's prompt is only switched on by the game while a bee is actually in your
        hand, and only on hives you placed, so both of those are checked before reaching
        for it rather than firing into nothing.
    ]]
    local function deposit()
        if not entitylib.isAlive or not heldIs('bee') then return end

        local root = entitylib.character.RootPart
        local range = value(DepositRange, 12)
        local best, closest

        -- A hive's Level is how many bees it is holding, so the cap reads straight off
        -- it. At or above the limit it is passed over and a nearer-but-full hive cannot
        -- soak up bees meant for one with room.
        local limit = value(BeeLimit, 10)

        for _, hive in collectionService:GetTagged('beehive') do
            if not ownHive(hive) then continue end
            if (hive:GetAttribute('Level') or 0) >= limit then continue end

            local part = partOf(hive)
            if not part then continue end

            local distance = (root.Position - part.Position).Magnitude
            if distance <= range and (not closest or distance < closest) then
                best, closest = hive, distance
            end
        end
        if not best then return end

        local prompt = best:FindFirstChildOfClass('ProximityPrompt')
        if not prompt then return end

        --[[
            Legit holds the prompt for as long as the game asks, which is what a player
            doing this by hand produces. It starts the moment the hive is in range - there
            is nothing to wait for before reaching for a prompt that is already there.

            Otherwise the prompt is simply fired, which is instant.
        ]]
        if on(Legit) then
            prompt:InputHoldBegin()
            local hold = prompt.HoldDuration or 0
            if hold > 0 then
                task.wait(hold)
            end
            prompt:InputHoldEnd()
        elseif fireproximityprompt then
            fireproximityprompt(prompt)
        else
            prompt:InputHoldBegin()
            prompt:InputHoldEnd()
        end

        local delay = value(DepositDelay, 0.1)
        if delay > 0 then
            task.wait(delay)
        end
    end

    local function removeHive(hive)
        local entry = Reference[hive]
        if entry then
            Reference[hive] = nil
            entry.Billboard:Destroy()
        end
    end

    -- How many bees a hive is holding, shown on it. The level is the count, and it is the
    -- one thing here worth reading at a glance - a full hive takes nothing more.
    local function addHive(hive)
        if Reference[hive] then return end

        local own = ownHive(hive)
        if own and not on(ShowOwn) then return end

        local part = partOf(hive)
        if not part then return end

        local billboard = Instance.new('BillboardGui')
        billboard.Name = 'beehive'
        billboard.Adornee = part
        billboard.StudsOffsetWorldSpace = Vector3.new(0, math.clamp(part.Size.Y * 0.5, 0.5, 4), 0)
        billboard.Size = UDim2.fromOffset(64, 34)
        billboard.AlwaysOnTop = true
        billboard.ClipsDescendants = false
        billboard.Parent = Folder

        local blur = addBlur(billboard)
        blur.Visible = on(Background)

        local frame = Instance.new('Frame')
        frame.Size = UDim2.fromScale(1, 1)
        frame.BackgroundColor3 = Color3.fromHSV(Color.Hue or 0, Color.Sat or 0, Color.Value or 0)
        frame.BackgroundTransparency = 1 - (on(Background) and (Color.Opacity or 0.5) or 0)
        frame.BorderSizePixel = 0
        frame.Parent = billboard

        local corner = Instance.new('UICorner')
        corner.CornerRadius = UDim.new(0, 4)
        corner.Parent = frame

        --[[
            A fixed size rather than a scaled one.

            TextScaled sizes the text to fill the box, so a single digit was blown up to a
            different size than two and drawn well outside the plate - which is why a count
            under ten looked like it was not there at all.
        ]]
        local label = Instance.new('TextLabel')
        label.Name = 'Level'
        label.Size = UDim2.fromScale(1, 1)
        label.BackgroundTransparency = 1
        label.TextColor3 = hiveColor(hive)
        label.TextStrokeTransparency = 0.4
        label.TextSize = 20
        label.FontFace = uipallet.FontSemiBold
        label.RichText = true
        label.Parent = frame

        --[[
            Redrawn from whatever the hive says right now.

            Driven from the loop as well as from the level changing, because a hive that
            was already standing when the module came on never fires that signal and its
            count would sit at whatever it happened to be when the plate was first drawn.
        ]]
        local function refresh()
            local parts = {}

            if on(ShowAmount) then
                parts[#parts + 1] = tostring(hive:GetAttribute('Level') or 0)
            end
            if not own then
                local owner = playersService:GetPlayerByUserId(hive:GetAttribute('PlacedByUserId') or 0)
                parts[#parts + 1] = '<font size="10">' .. ((owner and owner.Name) or '?') .. '</font>'
            end

            label.Text = table.concat(parts, ' ')
            label.TextColor3 = hiveColor(hive)
            billboard.Enabled = #parts > 0
        end
        refresh()

        Reference[hive] = {Billboard = billboard, Frame = frame, Blur = blur, Refresh = refresh}
        Beekeeper:Clean(hive:GetAttributeChangedSignal('Level'):Connect(refresh))
    end

    Beekeeper = vain.Categories.Kit:CreateModule({
        Name = 'Beekeeper',
        Function = function(callback)
            if callback then
                if on(HiveESP) then
                    for _, hive in collectionService:GetTagged('beehive') do
                        addHive(hive)
                    end
                    Beekeeper:Clean(collectionService:GetInstanceAddedSignal('beehive'):Connect(addHive))
                    Beekeeper:Clean(collectionService:GetInstanceRemovedSignal('beehive'):Connect(removeHive))
                end

                -- One loop for both, so a slow deposit cannot leave bees uncollected and
                -- the two never fight over what is in your hand at the same moment.
                task.spawn(function()
                    while Beekeeper.Enabled do
                        if on(Collect) then
                            pcall(collect)
                        end
                        if on(Deposit) then
                            pcall(deposit)
                        end
                        for hive, entry in Reference do
                            if hive.Parent then
                                entry.Refresh()
                            else
                                removeHive(hive)
                            end
                        end
                        task.wait(0.1)
                    end
                end)
            else
                for hive in Reference do
                    removeHive(hive)
                end
                Folder:ClearAllChildren()
                table.clear(Reference)
            end
        end,
        Tooltip = 'Catches bees and feeds them to your hives'
    })
    Collect = Beekeeper:CreateToggle({
        Name = 'Auto Collect',
        Tooltip = 'Catches wild bees around you',
        Function = function(callback)
            if LimitToItem and LimitToItem.Object then LimitToItem.Object.Visible = callback end
            if EquipNet and EquipNet.Object then EquipNet.Object.Visible = callback end
            if CollectRange and CollectRange.Object then CollectRange.Object.Visible = callback end
            if CollectDelay and CollectDelay.Object then CollectDelay.Object.Visible = callback end
        end,
        Default = true
    })
    LimitToItem = Beekeeper:CreateToggle({
        Name = 'Limit to Item',
        Tooltip = 'Only catches while the net is already in your hand',
        Darker = true
    })
    EquipNet = Beekeeper:CreateToggle({
        Name = 'Equip Net',
        Tooltip = 'Switches to the bee net first, which the catch needs',
        Darker = true,
        Default = true
    })
    -- Ten is what the game allows: a bee's own pickup prompt is built with a
    -- MaxActivationDistance of 10, so a catch sent from further out has every chance of
    -- being turned down. The slider goes past it to leave room to try, but the default is
    -- the distance the game itself works at.
    CollectRange = Beekeeper:CreateSlider({
        Name = 'Range',
        Tooltip = 'How far a bee can be to catch it (default 10)',
        Min = 1,
        Max = 30,
        Default = 10,
        Suffix = 'studs',
        Darker = true
    })
    CollectDelay = Beekeeper:CreateSlider({
        Name = 'Delay',
        Tooltip = 'Wait between catches (default 0.1)',
        Min = 0,
        Max = 1,
        Default = 0.1,
        Decimal = 100,
        Suffix = 'sec',
        Darker = true
    })
    Deposit = Beekeeper:CreateToggle({
        Name = 'Auto Deposit',
        Tooltip = 'Feeds caught bees to your nearest hive',
        Function = function(callback)
            if DepositRange and DepositRange.Object then DepositRange.Object.Visible = callback end
            if DepositDelay and DepositDelay.Object then DepositDelay.Object.Visible = callback end
            if BeeLimit and BeeLimit.Object then BeeLimit.Object.Visible = callback end
            if Legit and Legit.Object then Legit.Object.Visible = callback end
        end,
        Default = true
    })
    DepositRange = Beekeeper:CreateSlider({
        Name = 'Deposit Range',
        Tooltip = 'How far a hive can be to feed it (default 12)',
        Min = 1,
        Max = 30,
        Default = 12,
        Suffix = 'studs',
        Darker = true
    })
    DepositDelay = Beekeeper:CreateSlider({
        Name = 'Deposit Delay',
        Tooltip = 'Wait between deposits (default 0.1)',
        Min = 0,
        Max = 2,
        Default = 0.1,
        Decimal = 100,
        Suffix = 'sec',
        Darker = true
    })
    Legit = Beekeeper:CreateToggle({
        Name = 'Legit',
        Tooltip = 'Holds the prompt the way the game intends',
        Darker = true
    })
    BeeLimit = Beekeeper:CreateSlider({
        Name = 'Bee Limit',
        Tooltip = 'Stops feeding a hive once it holds this many (default 10)',
        Min = 1,
        Max = 25,
        Default = 10,
        Suffix = 'bees',
        Darker = true
    })
    HiveESP = Beekeeper:CreateToggle({
        Name = 'Beehive ESP',
        Tooltip = 'Shows how many bees each hive is holding',
        Function = function(callback)
            if ShowAmount and ShowAmount.Object then ShowAmount.Object.Visible = callback end
            if ShowOwn and ShowOwn.Object then ShowOwn.Object.Visible = callback end
            if Background and Background.Object then Background.Object.Visible = callback end
            if Color and Color.Object then Color.Object.Visible = callback and Background.Enabled end
            if Beekeeper.Enabled then
                Beekeeper:Toggle()
                Beekeeper:Toggle()
            end
        end,
        Default = true
    })
    ShowAmount = Beekeeper:CreateToggle({
        Name = 'Show Amount',
        Tooltip = 'Shows how many bees the hive is holding',
        Darker = true,
        Default = true
    })
    ShowOwn = Beekeeper:CreateToggle({
        Name = 'Show Own',
        Tooltip = 'Includes hives you placed yourself',
        Default = true,
        Function = function()
            if Beekeeper.Enabled then
                Beekeeper:Toggle()
                Beekeeper:Toggle()
            end
        end,
        Darker = true
    })
    Background = Beekeeper:CreateToggle({
        Name = 'Background',
        Tooltip = 'Draws a background behind the count',
        Function = function(callback)
            if Color.Object then Color.Object.Visible = callback end
            for _, entry in Reference do
                entry.Frame.BackgroundTransparency = 1 - (callback and (Color.Opacity or 0.5) or 0)
                entry.Blur.Visible = callback
            end
        end,
        Darker = true,
        Default = true
    })
    Color = Beekeeper:CreateColorSlider({
        Name = 'Background Color',
        Tooltip = 'Color of the background',
        -- Left out on purpose: the slider reads this as `DefaultValue or 1`, and zero is
        -- truthy in Lua, so passing 0 pinned the brightness at zero and the background
        -- came out black whatever colour was picked.
        DefaultOpacity = 0.5,
        Function = function(hue, sat, val, opacity)
            for _, entry in Reference do
                entry.Frame.BackgroundColor3 = Color3.fromHSV(hue, sat, val)
                entry.Frame.BackgroundTransparency = 1 - opacity
            end
        end,
        Darker = true
    })
end)

kitRun(function()
    local AutoBuilder
    local Animation
    local Blacklist
    local BedCheck
    local Limit

    local function getBedNear(pos)
    	local bed, lastmag = nil, math.huge
    	local localPosition = pos or Vector3.zero
    	for _, v in collectionService:GetTagged('bed') do
    		local mag = (localPosition - v.Position).Magnitude
    		if mag < lastmag and v:GetAttribute('Team' .. (lplr:GetAttribute('Team') or -1) .. 'NoBreak') then
    			bed = v
    			lastmag = mag
    		end
    	end
    	return bed, lastmag
    end

    AutoBuilder = vain.Categories.Kit:CreateModule({
    	Name = 'Auto Builder',
    	Tooltip = 'Automatically builds a preset structure',
    	Function = function(callback)
    		if callback then
    			repeat
    				task.wait()
    			until store.matchState ~= 0 and store.equippedKit == 'builder' or not AutoBuilder.Enabled
    			if not AutoBuilder.Enabled then
    				return
    			end

    			local bed = getBedNear(entitylib.character.RootPart.Position)
    			local blocks = collection('block', AutoBuilder, function(tab, obj)
    				task.delay(0, function()
    					if obj and not obj:GetAttribute('NoBreak') and obj:GetAttribute('PlacedByUserId') ~= nil then
    						table.insert(tab, obj)
    					end
    				end)
    			end)
    			repeat
    				if entitylib.isAlive and (not Limit.Enabled and getItem('hammer') or Limit.Enabled and store.hand.tool and store.hand.tool.Name == 'hammer') then
    					bed = getBedNear(entitylib.character.RootPart.Position)

    					for _, v in blocks do
    						if not BedCheck.Enabled or (bed.Position - v.Position).Magnitude <= 30 then
    							local name = v.Name
    							if name:find('wool_') then
    								name = 'wool'
    							end
    							if not table.find(Blacklist.ListEnabled, name) and not v:FindFirstChild('BuilderFortify') then
    								bedwars.Client:Get('FortifyBlock'):SendToServer(({getPlacedBlock(v.Position)})[2])
    								if Animation.Enabled then
    									bedwars.GameAnimationUtil:playAnimation(lplr, bedwars.GameAnimationUtil:getAssetId(bedwars.AnimationType.BUILDER_HAMMER_HIT), {
    										fadeInTime = 0.02
    									})
                						bedwars.SoundManager:playSound(bedwars.SoundList.FORTIFY_BLOCK,lplr.Character.HumanoidRootPart.Position)
    								end
    							end
    						end
    					end
    				end
    				task.wait(0.1)
    			until not AutoBuilder.Enabled
    		end
    	end
    })

    BedCheck = AutoBuilder:CreateToggle({
    	Name = 'Bed Check',
    	Tooltip = 'Checks if the block is near your bed'
    })
    Animation = AutoBuilder:CreateToggle({
    	Name = 'Animation',
    	Default = true,
    	Tooltip = 'Plays builder visuals (sfx and anim)'
    })
    Limit = AutoBuilder:CreateToggle({
    	Name = 'Limit to items',
    	Tooltip = 'Only activates when a required item is in your hand',
    	Default = true
    })
    Blacklist = AutoBuilder:CreateTextList({
    	Name = 'Blacklists',
    	Tooltip = 'Block types to skip when auto-building (one per line)',
    	Placeholder = 'block',
    	Default = {'cannon', 'wool'}
    })
end)

kitRun(function()
    local Caitlyn
    local MethodDropdown
    local LowHealthSlider
    local ExecuteRangeSlider
    local HitRangeSlider
    local ProximityRangeSlider
    local connections = {}
    local Players = playersService
    local lplr = Players.LocalPlayer
    local currentTarget = nil
    local lastHitTime = 0
    local lastContractSelect = 0
    
    local function selectContract(targetPlayer)
        if not entitylib.isAlive then return false end
        if tick() - lastContractSelect < 0.1 then return false end
        
        local storeState = bedwars.Store:getState()
        local activeContract = storeState.Kit.activeContract
        local availableContracts = storeState.Kit.availableContracts or {}
        
        if activeContract then return false end
        if #availableContracts == 0 then return false end
        
        for _, contract in pairs(availableContracts) do
            if contract.target and contract.target.Name == targetPlayer.Name then
                bedwars.Client:Get('BloodAssassinSelectContract'):SendToServer({
                    contractId = contract.id
                })
                lastContractSelect = tick()
                return true
            end
        end
        return false
    end
    
    local function executeOnLowHealth()
        if not currentTarget or tick() - lastHitTime > 3 then
            currentTarget = nil
            return
        end
        
        if not currentTarget.Character then return end
        
        local humanoid = currentTarget.Character:FindFirstChild("Humanoid")
        local rootPart = currentTarget.Character:FindFirstChild("HumanoidRootPart")
        
        if humanoid and rootPart and lplr.Character and lplr.Character:FindFirstChild("HumanoidRootPart") then
            local health = humanoid.Health
            local distance = (lplr.Character.HumanoidRootPart.Position - rootPart.Position).Magnitude
            
            if health > 0 and health <= LowHealthSlider.Value and distance <= ExecuteRangeSlider.Value then
                selectContract(currentTarget)
            end
        end
    end
    
    local function contractOnHit()
        if not currentTarget or tick() - lastHitTime > 0.5 then
            currentTarget = nil
            return
        end
        
        if not currentTarget.Character then return end
        
        local rootPart = currentTarget.Character:FindFirstChild("HumanoidRootPart")
        
        if rootPart and lplr.Character and lplr.Character:FindFirstChild("HumanoidRootPart") then
            local distance = (lplr.Character.HumanoidRootPart.Position - rootPart.Position).Magnitude
            
            if distance <= HitRangeSlider.Value then
                selectContract(currentTarget)
            end
        end
    end
    
    local function proximityContract()
        if not entitylib.isAlive then return end
        
        local myRoot = lplr.Character and lplr.Character:FindFirstChild("HumanoidRootPart")
        if not myRoot then return end
        
        local closestPlayer = nil
        local closestDistance = ProximityRangeSlider.Value
        
        for _, player in pairs(Players:GetPlayers()) do
            if player ~= lplr and player.Character then
                local theirRoot = player.Character:FindFirstChild("HumanoidRootPart")
                local humanoid = player.Character:FindFirstChild("Humanoid")
                
                if theirRoot and humanoid and humanoid.Health > 0 then
                    local distance = (myRoot.Position - theirRoot.Position).Magnitude
                    
                    if distance < closestDistance then
                        closestDistance = distance
                        closestPlayer = player
                    end
                end
            end
        end
        
        if closestPlayer then
            selectContract(closestPlayer)
        end
    end
    
    Caitlyn = vain.Categories.Kit:CreateModule({
        Name = 'Auto Caitlyn',
        Function = function(callback)
            if callback then
                local damageConnection = vainEvents.EntityDamageEvent.Event:Connect(function(damageTable)
                    if not entitylib.isAlive then return end
                    
                    local attacker = playersService:GetPlayerFromCharacter(damageTable.fromEntity)
                    local victim = playersService:GetPlayerFromCharacter(damageTable.entityInstance)
                
                    if attacker == lplr and victim and victim ~= lplr then
                        currentTarget = victim
                        lastHitTime = tick()
                    end
                end)
                table.insert(connections, damageConnection)
                
                task.spawn(function()
                    repeat
                        if entitylib.isAlive then
                            local method = MethodDropdown.Value
                            
                            if method == "Execute on Low HP" then
                                executeOnLowHealth()
                            elseif method == "Contract on Hit" then
                                contractOnHit()
                            elseif method == "Proximity Select" then
                                proximityContract()
                            end
                        end
                        task.wait(0.1)
                    until not Caitlyn.Enabled
                end)
            else
                for _, conn in pairs(connections) do
                    if typeof(conn) == "RBXScriptConnection" then
                        conn:Disconnect()
                    end
                end
                table.clear(connections)
                
                currentTarget = nil
                lastHitTime = 0
            end
        end,
        Tooltip = 'Auto contract selection for Caitlyn'
    })
    
    MethodDropdown = Caitlyn:CreateDropdown({
        Name = 'Method',
        List = {"Execute on Low HP", "Contract on Hit", "Proximity Select"},
        Default = "Execute on Low HP",
        Tooltip = 'Contract selection method',
        Function = function(value)
            LowHealthSlider.Object.Visible = (value == "Execute on Low HP")
            ExecuteRangeSlider.Object.Visible = (value == "Execute on Low HP")
            HitRangeSlider.Object.Visible = (value == "Contract on Hit")
            ProximityRangeSlider.Object.Visible = (value == "Proximity Select")
        end
    })
    
    LowHealthSlider = Caitlyn:CreateSlider({
        Name = 'Select HP',
        Min = 10,
        Max = 100,
        Default = 30,
        Tooltip = 'HP value to execute contract'
    })
    
    ExecuteRangeSlider = Caitlyn:CreateSlider({
        Name = 'Select Range',
        Min = 5,
        Max = 50,
        Default = 20,
        Suffix = ' studs',
        Tooltip = 'Range to select contract'
    })
    
    HitRangeSlider = Caitlyn:CreateSlider({
        Name = 'Hit Range',
        Min = 10,
        Max = 200,
        Default = 100,
        Suffix = ' studs',
        Tooltip = 'Max range to select a contract when hitting the player'
    })
    
    ProximityRangeSlider = Caitlyn:CreateSlider({
        Name = 'Proximity Range',
        Min = 10,
        Max = 200,
        Default = 50,
        Suffix = ' studs',
        Tooltip = 'Range to auto select nearby players'
    })
    
    LowHealthSlider.Object.Visible = true
    ExecuteRangeSlider.Object.Visible = true
    HitRangeSlider.Object.Visible = false
    ProximityRangeSlider.Object.Visible = false
end)

kitRun(function()
    --[[
    	The landing half of the Davey kit: what happens once you are already in the air.

    	Aiming lives in Davey Aim, separately, because the two are wanted at different times
    	- this one is worth leaving on all match whether the shot was aimed by hand or not,
    	and it hooks the launch itself so it does not care which.
    ]]
    local PirateDavey
    local Break, Jump, Switch, Limit, IncludeWood

    local old

    local function on(setting)
    	return setting ~= nil and setting.Enabled
    end

    local function holdingPickaxe()
    	local tool = store.hand and store.hand.tool
    	if tool == nil or tool.Name == nil or not tool.Name:find('pickaxe') then
    		return false
    	end
    	if tool.Name == 'wood_pickaxe' then
    		return on(IncludeWood)
    	end
    	return true
    end

    --[[
    	The breaking tool, taken out before the shot rather than during the landing.

    	Swapping at the moment the block breaks is the tell: a player reaches for the
    	pickaxe while they are still stood at the cannon, not in the half second between
    	touching down and swinging. Doing it here means the tool is already in hand for the
    	whole flight, which is what it looks like when somebody means to do this.

    	The swap itself is the ordinary one - pick the hotbar slot, then send the equip -
    	rather than the break loop's hurried version that dispatches and moves on.
    ]]
    local function equipBreakTool(block)
    	local meta = bedwars.ItemMeta[block.Name]
    	local breakType = meta and meta.block and meta.block.breakType
    	local tool = breakType and store.tools[breakType]
    	if not tool then return end

    	for i, v in store.inventory.hotbar do
    		if v.item and v.item.itemType == tool.itemType then
    			hotbarSwitch(i - 1)
    			break
    		end
    	end
    	if tool.tool then
    		switchItem(tool.tool)
    	end
    end

    --[[
    	Reaching for the pickaxe when you reach for the cannon.

    	Hooking the launch was still too late: by then you are already in the air, and the
    	swap happens during the flight rather than before it. The moment a player actually
    	decides to do this is when they start holding the cannon's prompt, so that is what
    	is listened for.

    	Both the hold starting and the plain trigger are taken, because a prompt with no
    	hold duration never fires the first of those - and the cannon has one of each.
    ]]
    local hooked = setmetatable({}, {__mode = 'k'})

    local function watchCannon(block)
    	if block.Name ~= 'cannon' or hooked[block] then return end
    	hooked[block] = true

    	local function reach()
    		if on(Switch) and on(Break) then
    			pcall(equipBreakTool, block)
    		end
    	end

    	local function hook(prompt)
    		if not prompt:IsA('ProximityPrompt') then return end
    		PirateDavey:Clean(prompt.PromptButtonHoldBegan:Connect(reach))
    		PirateDavey:Clean(prompt.Triggered:Connect(reach))
    	end

    	for _, child in block:GetDescendants() do
    		hook(child)
    	end

    	--[[
    		The prompts are not always there when the block is.

    		A cannon is tagged as it is placed and its prompts are parented in afterwards, so
    		looking once at the moment it appears finds nothing and hooks nothing - which is
    		why the swap kept falling through to the launch instead. Watching for them to
    		arrive catches the ones that were not there yet.
    	]]
    	PirateDavey:Clean(block.DescendantAdded:Connect(hook))
    end

    PirateDavey = vain.Categories.Kit:CreateModule({
    	Name = 'PirateDavey',
    	Tooltip = 'Breaks the block you land on and jumps as you touch down',
    	Function = function(call)
    		if call then
    			for _, block in collectionService:GetTagged('block') do
    				watchCannon(block)
    			end
    			PirateDavey:Clean(collectionService:GetInstanceAddedSignal('block'):Connect(watchCannon))

    			old = bedwars.CannonHandController.launchSelf
    			bedwars.CannonHandController.launchSelf = function(...)
    				local block = select(2, ...)

    				-- A backstop for a launch that never touched a prompt, such as the fast
    				-- aim mode calling the controller directly. Equipping something already
    				-- in hand costs nothing, so this is harmless when the prompt got there
    				-- first.
    				if on(Switch) and on(Break) and block then
    					pcall(equipBreakTool, block)
    				end

    				local res = { old(...) }

    				-- Guarded because a launch can end with you dead, and reaching for a
    				-- root part that is no longer there took the whole hook down with it.
    				pcall(function()
    					if on(Break) and (not on(Limit) or holdingPickaxe()) and entitylib.isAlive then
    						if (block.Position - entitylib.character.RootPart.Position).Magnitude <= 30 then
    							task.delay(0.05, function()
    								for _ = 1, 2 do
    									-- false: the tool was taken out before the launch, and
    									-- letting the break swap again undoes that.
    									task.spawn(bedwars.breakBlock, block, false, nil, true, false)
    								end
    							end)
    						end
    					end

    					if on(Jump) and entitylib.isAlive then
    						entitylib.character.Humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
    					end
    				end)

    				return unpack(res)
    			end
    		elseif old then
    			bedwars.CannonHandController.launchSelf = old
    		end
    	end
    })
    Break = PirateDavey:CreateToggle({
    	Name = 'Break on impact',
    	Tooltip = 'Breaks the block you land on'
    })
    Jump = PirateDavey:CreateToggle({
    	Name = 'Jump on impact',
    	Tooltip = 'Jumps as you land'
    })
    Switch = PirateDavey:CreateToggle({
    	Name = 'Legit switch',
    	Tooltip = 'Takes the breaking tool out at the cannon, before launching, instead of swapping mid-landing',
    	Darker = true
    })
    Limit = PirateDavey:CreateToggle({
    	Name = 'Limit to Item',
    	Tooltip = 'Only breaks while a pickaxe is held',
    	Darker = true
    })
    IncludeWood = PirateDavey:CreateToggle({
    	Name = 'Include Wood Pickaxe',
    	Tooltip = 'Counts the wood pickaxe for Limit to Item',
    	Darker = true
    })
end)

kitRun(function()
    --[[
    	Pointing the cannon and firing it, on its own, for as long as it is switched on.
    ]]
    local DaveyAim
    local Activation, AimAt, AimMode, Launch, SearchRange, Delay, AvoidPowdered

    --[[
    	Powdered is the kit's own leash: "Firing yourself from a cannon will inflict
    	damage". Each launch adds a stack, a stack is twenty damage up to sixty, and the
    	whole thing lapses seven seconds after the last one.

    	There is nothing to switch off. It is applied and charged server side, and the only
    	thing the client gets is an attribute saying it is there - so the counter is not to
    	block it but to stop feeding it: wait for the stacks to lapse rather than launching
    	into them, and the damage never lands in the first place.
    ]]
    local function powderedStacks()
    	local char = lplr.Character
    	if not char then return 0 end
    	if char:GetAttribute('StatusEffect_powdered') == nil then return 0 end
    	return tonumber(char:GetAttribute('StatusEffect_powdered_stacks')) or 1
    end

    local rayCheck = RaycastParams.new()
    rayCheck.RespectCanCollide = true

    local function on(setting)
    	return setting ~= nil and setting.Enabled
    end

    -- The nearest cannon, rather than the first one the tag list happens to hand back. The
    -- old search broke out of the loop on its first hit, so a cannon behind you won over
    -- the one at your feet whenever it was listed first.
    local function nearestCannon()
    	if not entitylib.isAlive then return end

    	local origin = entitylib.character.RootPart.Position
    	local best, bestDist

    	for _, v in collectionService:GetTagged('block') do
    		if v.Name == 'cannon' then
    			local mag = (origin - v.Position).Magnitude
    			if mag <= SearchRange.Value and (not bestDist or mag < bestDist) then
    				best, bestDist = v, mag
    			end
    		end
    	end

    	return best
    end

    --[[
    	Where to point it.

    	This used to be a dropdown called Position Mode that was never stored in a variable
    	and so could never be read: the choice did nothing and aiming was always by mouse. It
    	works now, and it gained the option that makes the module automatic rather than
    	something you point by hand.
    ]]
    local function aimPoint()
    	local choice = AimAt and AimAt.Value or 'Nearest Enemy'

    	if choice == 'Nearest Enemy' then
    		local ent = entitylib.EntityPosition({
    			Range = 400,
    			Part = 'RootPart',
    			Players = true,
    			NPCs = false
    		})
    		return ent and ent.Position or nil
    	end

    	local ray
    	if choice == 'Camera' then
    		ray = Ray.new(gameCamera.CFrame.Position, gameCamera.CFrame.LookVector)
    	else
    		ray = cloneref(lplr:GetMouse()).UnitRay
    	end

    	rayCheck.FilterDescendantsInstances = {lplr.Character, gameCamera}
    	local hit = workspace:Raycast(ray.Origin, ray.Direction * 1000000, rayCheck)
    	return hit and hit.Position or nil
    end

    --[[
    	Aiming is 'AimCannon', not 'CannonAim'.

    	The scraped table works a remote's name out by finding 'Client' among a function's
    	constants and taking the next one, which for this call lands on 'Get' rather than on
    	the name - so every aim was addressed to a remote that does not exist and the cannon
    	never turned. Named directly, and the vector is sent as the plain unit LookVector the
    	game itself sends rather than one multiplied by two hundred.
    ]]
    local function sendAim(cannon, lookVector)
    	bedwars.Client:Get('AimCannon'):SendToServer({
    		cannonBlockPos = bedwars.BlockController:getBlockPosition(cannon.Position),
    		lookVector = lookVector
    	})
    end

    local function aimAndFire()
    	-- Launching while it is still on you is what turns a free ride into sixty damage.
    	if on(AvoidPowdered) and powderedStacks() > 0 then return end

    	local cannon = nearestCannon()
    	if not cannon then return end

    	local target = aimPoint()
    	if not target then return end

    	if AimMode.Value == 'Legit' then
    		-- The prompts the game itself binds, held for as long as it asks, so the whole
    		-- exchange is the one a player produces.
    		local aim = cannon:FindFirstChild('AimPrompt')
    		if not aim then return end

    		aim:InputHoldBegin()
    		task.wait(aim.HoldDuration)

    		local until_ = tick() + 0.3
    		repeat
    			gameCamera.CFrame = gameCamera.CFrame:Lerp(CFrame.lookAt(gameCamera.CFrame.Position, target), 22 * runService.PostSimulation:Wait())
    			sendAim(cannon, gameCamera.CFrame.LookVector)
    		until tick() > until_

    		local stop = cannon:FindFirstChild('StopAimingPrompt')
    		if stop then
    			stop:InputHoldBegin()
    			task.wait(stop.HoldDuration + runService.PostSimulation:Wait())
    		end

    		if on(Launch) then
    			local fire = cannon:FindFirstChild('LaunchSelfPrompt')
    			if fire then
    				fire:InputHoldBegin()
    				task.wait(fire.HoldDuration + runService.PostSimulation:Wait())
    			end
    		end
    	else
    		sendAim(cannon, CFrame.lookAt(cannon.Position, target).LookVector)
    		task.wait(0.3)
    		if on(Launch) then
    			bedwars.CannonHandController:launchSelf(cannon)
    		end
    	end
    end

    DaveyAim = vain.Categories.Kit:CreateModule({
    	Name = 'DaveyAim',
    	Tooltip = 'Aims the nearest cannon and fires it',
    	Function = function(call)
    		if not call then return end

    		--[[
    			Once behaves as a button rather than a switch: it takes the shot and then
    			un-latches itself, so the module reads as an action you press. Deferred
    			because toggling from inside the toggle's own handler is re-entrant, and
    			doing it directly leaves the state disagreeing with the button.
    		]]
    		if Activation ~= nil and Activation.Value == 'Once' then
    			pcall(aimAndFire)
    			task.defer(function()
    				if DaveyAim.Enabled then
    					pcall(function() DaveyAim:Toggle() end)
    				end
    			end)
    			return
    		end

    		repeat
    			pcall(aimAndFire)
    			task.wait(Delay.Value)
    		until not DaveyAim.Enabled
    	end
    })
    Activation = DaveyAim:CreateDropdown({
    	Name = 'Activation',
    	Tooltip = 'Whether it keeps firing or takes a single shot',
    	List = {'Continuous', 'Once'},
    	Default = 'Continuous',
    	Function = function(value)
    		-- Nothing to wait between when there is only one shot.
    		if Delay and Delay.Object then
    			Delay.Object.Visible = value == 'Continuous'
    		end
    	end,
    	ItemTooltips = {
    		Continuous = 'Keeps aiming and firing for as long as it is switched on',
    		Once = 'Fires a single shot when you switch it on, then switches itself back off',
    	}
    })
    AimAt = DaveyAim:CreateDropdown({
    	Name = 'Aim At',
    	Tooltip = 'What the cannon is pointed at',
    	List = {'Nearest Enemy', 'Mouse', 'Camera'},
    	Default = 'Nearest Enemy',
    	ItemTooltips = {
    		['Nearest Enemy'] = 'Finds a player to fire at, which is what makes this automatic',
    		Mouse = 'Fires wherever your cursor is pointing',
    		Camera = 'Fires wherever the camera is looking',
    	}
    })
    AimMode = DaveyAim:CreateDropdown({
    	Name = 'Aim Mode',
    	Tooltip = 'How the cannon is aimed',
    	List = {'Fast', 'Legit'},
    	Default = 'Fast',
    	ItemTooltips = {
    		Fast = 'Sends the aim straight to the server and launches',
    		Legit = 'Holds the prompts and turns the camera the way a player would',
    	}
    })
    SearchRange = DaveyAim:CreateSlider({
    	Name = 'Search Range',
    	Tooltip = 'How far to look for one of your cannons (default 20)',
    	Min = 1,
    	Max = 60,
    	Default = 20,
    	Suffix = function(val)
    		return val <= 1 and 'stud' or 'studs'
    	end
    })
    Delay = DaveyAim:CreateSlider({
    	Name = 'Delay',
    	Tooltip = 'Wait between shots (default 1)',
    	Min = 0.1,
    	Max = 5,
    	Default = 1,
    	Decimal = 10,
    	Suffix = 'sec',
    	Darker = true
    })
    Launch = DaveyAim:CreateToggle({
    	Name = 'Launch',
    	Tooltip = 'Fires yourself out of the cannon once it is aimed',
    	Default = true
    })
    AvoidPowdered = DaveyAim:CreateToggle({
    	Name = 'Avoid Powdered',
    	Tooltip = 'Waits for the Powdered effect to lapse before launching again. Each launch stacks it for 20 damage up to 60, and it clears seven seconds after the last one',
    	Darker = true,
    	Default = true
    })
end)

kitRun(function()
    local AutoDrill
    local AutoCollect
    local Notify
    local AutoAttack
    local Legit
    local Range
    local AttackDelay
    local CollectDelay
    local Targets
    local Sort
    local currentDrill
    local attackDebounce = {}
    local collectDebounce = {}

    local function getDrillPart(drill)
    	return drill and (drill.PrimaryPart or drill:FindFirstChild('RootPart') or drill:FindFirstChildWhichIsA('BasePart'))
    end

    local function addDrill(drills, added, drill)
    	if typeof(drill) ~= 'Instance' or added[drill] or drill:GetAttribute('PlacedByUserId') ~= lplr.UserId then
    		return
    	end
    	if getDrillPart(drill) then
    		added[drill] = true
    		table.insert(drills, drill)
    	end
    end

    local function getDrills(tagged)
    	local drills, added = {}, {}
    	for _, drill in tagged do
    		addDrill(drills, added, drill)
    	end

    	for _, drill in (bedwars.DrillTabletController and bedwars.DrillTabletController.drillList or {}) do
    		addDrill(drills, added, drill)
    	end

    	return drills
    end

    local function getResourceAmount(drill)
    	return (drill:GetAttribute('diamond') or 0) + (drill:GetAttribute('emerald') or 0)
    end

    local function collectDrill(drill)
    	local suc = pcall(function()
    		bedwars.Client:Get('ExtractFromDrill'):SendToServer({
    			drill = drill,
    		})
    	end)
    	return suc
    end

    local function useDrill(drill)
    	if currentDrill == drill then
    		return true
    	end

    	local suc, res = pcall(function()
    		return bedwars.Client:Get('PlayerUseDrillController'):CallServer({
    			drill = drill,
    		})
    	end)

    	if suc and res ~= false then
    		currentDrill = drill
    		return true
    	end

    	return false
    end

    local function attackDrill(drill, target)
    	if not useDrill(drill) then
    		return false
    	end

    	local suc = pcall(function()
    		bedwars.Client:Get('DrillAttack'):SendToServer({
    			targetPosition = target.RootPart.Position,
    		})
    	end)
    	return suc
    end

    local function getTarget(position)
    	return entitylib.EntityPosition({
    		Origin = position,
    		Range = Legit.Enabled and 10 or Range.Value,
    		Part = 'RootPart',
    		Players = Targets.Players.Enabled,
    		NPCs = Targets.NPCs.Enabled,
    		Sort = sortmethods[Sort.Value],
    	})
    end

    local function updateAttackControls()
    	pcall(function()
    		local enabled = AutoAttack.Enabled
    		Legit.Object.Visible = enabled
    		Range.Object.Visible = enabled and not Legit.Enabled
    		AttackDelay.Object.Visible = enabled
    		Targets.Object.Visible = enabled
    		Sort.Object.Visible = enabled
    	end)
    end

    AutoDrill = vain.Categories.Kit:CreateModule({
    	Name = 'Auto Drill',
    	Tooltip = 'Automates the Drill kit — drills and collects automatically',
    	Function = function(callback)
    		if callback then
    			local tagged = collection('Drill', AutoDrill)
    			repeat
    				task.wait()
    			until store.matchState ~= 0 and store.equippedKit == 'drill' or not AutoDrill.Enabled

    			repeat
    				if entitylib.isAlive and store.equippedKit == 'drill' then
    					local now = tick()
    					for _, drill in getDrills(tagged) do
    						local part = getDrillPart(drill)
    						if not part then
    							continue
    						end

    						if
    							AutoCollect.Enabled
    							and getResourceAmount(drill) > 0
    							and now > (collectDebounce[drill] or 0)
    						then
    							if collectDrill(drill) and Notify.Enabled then
    								notif('Auto Drill', 'Collected drill resources', 4, 'info')
    							end
    							collectDebounce[drill] = now + CollectDelay.Value
    						end

    						if AutoAttack.Enabled and now > (attackDebounce[drill] or 0) then
    							local target = getTarget(part.Position)
    							if target then
    								targetinfo.Targets[target] = tick() + 1
    								if attackDrill(drill, target) then
    									attackDebounce[drill] = now + AttackDelay.Value
    								end
    							end
    						end
    					end
    				end

    				task.wait(0.1)
    			until not AutoDrill.Enabled
    		else
    			currentDrill = nil
    			table.clear(attackDebounce)
    			table.clear(collectDebounce)
    		end
    	end,
    	Tooltip = 'Automatically collects resources and attacks with placed drills.'
    })
    AutoCollect = AutoDrill:CreateToggle({
    	Name = 'Auto collect',
    	Tooltip = 'Automatically collects drill output',
    	Default = true,
    	Function = function(callback)
    		pcall(function()
    			Notify.Object.Visible = callback
    			CollectDelay.Object.Visible = callback
    		end)
    	end
    })
    Notify = AutoDrill:CreateToggle({
    	Name = 'Notify on collect',
    	Tooltip = 'Sends a notification when drill output is collected',
    	Darker = true
    })
    AutoAttack = AutoDrill:CreateToggle({
    	Name = 'Auto attack',
    	Tooltip = 'Automatically attacks with the kit weapon',
    	Default = true,
    	Function = updateAttackControls
    })
    Range = AutoDrill:CreateSlider({
    	Name = 'Range',
    	Tooltip = 'Maximum distance in studs',
    	Min = 1,
    	Max = 10,
    	Default = 10,
    	Suffix = function(value)
    		return value == 1 and 'stud' or 'studs'
    	end
    })
    Legit = AutoDrill:CreateToggle({
    	Name = 'Legit Range',
    	Tooltip = 'Restricts range to a value indistinguishable from vanilla',
    	Default = true,
    	Function = updateAttackControls
    })
    AttackDelay = AutoDrill:CreateSlider({
    	Name = 'Attack delay',
    	Tooltip = 'Seconds between consecutive attacks',
    	Min = 0.1,
    	Max = 1,
    	Default = 0.3,
    	Decimal = 100,
    	Suffix = function(value)
    		return value == 1 and 'sec' or 'secs'
    	end
    })
    CollectDelay = AutoDrill:CreateSlider({
    	Name = 'Collect delay',
    	Tooltip = 'Seconds between collection attempts',
    	Min = 0.1,
    	Max = 3,
    	Default = 0.5,
    	Decimal = 10,
    	Suffix = function(value)
    		return value == 1 and 'sec' or 'secs'
    	end
    })
    Targets = AutoDrill:CreateTargets({
    	Tooltip = 'Configure which types of targets to include',
    	Players = true,
    	NPCs = false
    })
    local methods = {'Distance', 'Health', 'Damage'}
    for name in sortmethods do
    	if not table.find(methods, name) then
    		table.insert(methods, name)
    	end
    end
    Sort = AutoDrill:CreateDropdown({
    	Name = 'Sort',
    	Tooltip = 'Selects how targets are sorted/prioritized',
    	List = methods,
    	Default = 'Distance',
    	ItemTooltips = {
    		Distance = 'Targets the closest enemy by stud distance',
    		Health = 'Targets the enemy with the lowest remaining health',
    		Angle = 'Targets the enemy closest to your look direction',
    		Cursor = 'Targets the enemy nearest to your mouse cursor',
    		Damage = 'Targets the enemy who most recently took damage',
    		Threat = 'Targets the enemy judged to be the greatest combat threat',
    		Kit = 'Prioritizes dangerous kit users (Hannah, Spirit Assassin, etc.)',
    	}
    })
    updateAttackControls()
end)

kitRun(function()
    local AutoElder
    local Streamer
    local Range
    local Animation
    local Delay

    AutoElder = vain.Categories.Kit:CreateModule({
    	Name = 'Auto Elder',
    	Tooltip = 'Automates the Elder kit ability',
    	Function = function(call)
    		if call then
    			AutoElder:Clean(proximityPromptService.PromptShown:Connect(function(prompt)
    				if Streamer.Enabled and prompt.Name == 'treeOrb' then
    					task.delay(0.1, prompt.InputHoldBegin, prompt)
    				end
    			end))

    			repeat
    				if not Streamer.Enabled and entitylib.isAlive then
    					local localPosition = entitylib.character.RootPart.Position
    					for i, v in collectionService:GetTagged('treeOrb') do
    						if tick() > (Delay[v] or 0) and (localPosition - v.Spirit.Position).Magnitude <= Range.Value then
    							if Delay.Value > 0 then
    								task.wait(Delay.Value)
    							end

    							if (localPosition - v.Spirit.Position).Magnitude <= Range.Value then
    								if Animation.Enabled then
    									bedwars.GameAnimationUtil:playAnimation(lplr.Character, bedwars.AnimationType.PUNCH)
    									bedwars.ViewmodelController:playAnimation(bedwars.AnimationType.FP_USE_ITEM)
    									bedwars.SoundManager:playSound(bedwars.SoundList.CROP_HARVEST)
    								end
    								if bedwars.Client:Get(remotes.ConsumeTreeOrb):CallServer({treeOrbSecret = v:GetAttribute('TreeOrbSecret')}) then
    									v:Destroy()
    								end
    								Delay[v] = tick() + 1
    							end
    						end
    					end
    				end
    				task.wait(0.1)
    			until not AutoElder.Enabled
    		end
    	end,
    	Tooltip = 'Automatically collects tree orbs'
    })

    Streamer = AutoElder:CreateToggle({
    	Name = 'Streamer mode',
    	Tooltip = 'Hides delay, range, and animation settings from the UI — useful for streaming',
    	Function = function(call)
    		pcall(function()
    			Delay.Object.Visible = not call
    			Range.Object.Visible = not call
    			Animation.Object.Visible = not call
    		end)
    	end
    })
    Animation = AutoElder:CreateToggle({
    	Name = 'Animation',
    	Default = true,
    	Tooltip = 'Plays the collect animation'
    })
    Range = AutoElder:CreateSlider({
    	Name = 'Range',
    	Tooltip = 'Maximum distance in studs',
    	Min = 1,
    	Max = 20,
    	Default = 12,
    	Suffix = function(val)
    		return val > 1 and 'studs' or 'stud'
    	end
    })
    Delay = AutoElder:CreateSlider({
    	Name = 'Delay',
    	Tooltip = 'Seconds between consecutive actions',
    	Min = 0,
    	Max = 1,
    	Suffix = function(val)
    		return val > 1 and 'secs' or 'sec'
    	end,
    	Default = 0.2,
    	Decimal = 100
    })
end)

kitRun(function()
	local AutoEmber
	local Targets
	local Range
	local SpinCooldown
	local Limit
	local old = os.clock()+ 0.00000000000000000000013
	local isCharging = false
	local chargeAnim, FpChargeAnim = nil,nil
	AutoEmber = vain.Categories.Kit:CreateModule({
		Name = 'Auto Ember',
		Tooltip = 'automatically uses the ember ability',
		Function = function(call)
			if call then
				repeat
					if entitylib.isAlive then 
						local tool = getItem('infernal_saber') 
						if tool and (not Limit.Enabled or store.hand.tool and store.hand.tool.Name == 'infernal_saber') then
							local ent = entitylib.EntityPosition({
								Range = HoldRange.Value,
								Players = Targets.Players.Enabled,
								NPCs = Targets.NPCs.Enabled,
								Part = 'RootPart'
							}) 

							if not ent then
								if isCharging then
									isCharging = false
									bedwars.HellSaberController.animationMaid:DoCleaning()
									chargeAnim = nil
									FpChargeAnim = nil
									task.wait(0.3)
									continue
								end
							end

							if ent then
								if not isCharging then
									isCharging = true
									bedwars.HellSaberController:playChargeSound(lplr)
									local animer = lplr.Character
									if animer ~= nil then
										animer = animer:FindFirstChild("Humanoid")
										if animer ~= nil then
											animer = animer:FindFirstChild("Animator")
										end
									end
									if not animer then
										return nil
									end
									chargeAnim = animer:LoadAnimation(bedwars.GameAnimationUtil:getAnimation(bedwars.AnimationType.INFERNO_SWORD_CHARGE))
									chargeAnim:Play()
									chargeAnim:AdjustSpeed(1.83)
									chargeAnim:GetMarkerReachedSignal("end"):Connect(function()
										local newChargeAnim = chargeAnim
										if newChargeAnim ~= nil then
											newChargeAnim:AdjustSpeed(0)
										end
									end)
									FpChargeAnim = bedwars.ViewmodelController:playAnimation(bedwars.AnimationType.FP_INFERNO_SWORD_CHARGE)
									if FpChargeAnim then
										FpChargeAnim:GetMarkerReachedSignal("end"):Connect(function()
											local newFpChargeAnim = FpChargeAnim
											if newFpChargeAnim ~= nil then
												newFpChargeAnim:AdjustSpeed(0)
											end
										end)
									end
									bedwars.HellSaberController.animationMaid:GiveTask(function()
										local MaidCA1 = chargeAnim
										if MaidCA1 ~= nil then
											MaidCA1:Stop()
										end
										local MaidCA2 = chargeAnim
										if MaidCA2 ~= nil then
											MaidCA2:Destroy()
										end
										local MaidFCA1 = FpChargeAnim
										if MaidFCA1 ~= nil then
											MaidFCA1:Stop()
										end
										local MaidFCA2 = FpChargeAnim
										if MaidFCA2 ~= nil then
											MaidFCA2:Destroy()
										end
									end)
								end
								local DeltaPos = (ent.RootPart.Position - lplr.Character.HumanoidRootPart.Position).Magnitude
								if DeltaPos <= Range.Value then
									local now = os.clock() + 0.00000000000000000000013
									if (now - old) >= SpinCooldown.Value then
										bedwars.HellSaberController.animationMaid:DoCleaning()
										if not Limit.Enabled then
											switchItem(tool)
										end
										bedwars.Client:Get('HellBladeRelease'):SendToServer({
											chargeTime = 1 + tick() - (0.045 + (math.random() - math.random())), 
											weapon = tool,
											player = lplr
										})
										old = os.clock() + 0.00000000000000000000013
										bedwars.ViewmodelController:playAnimation(bedwars.AnimationType.FP_INFERNO_SWORD_SPIN)										
										isCharging = false
										
									end
								end
							end
						end
					end
					task.wait(0.1)
				until not AutoEmber.Enabled 
			end
		end
	})
	Targets = AutoEmber:CreateTargets({
		Players = true,
		NPCs = false
	})
	SpinCooldown = AutoEmber:CreateSlider({
		Name = 'Spin Cooldown',
		Min = 0,
		Max = 4,
		Default = 1.12,
		Decimal = 100,
		Tooltip = 'Anything below 0.2 will most likely get you banned if you get clipped'
	})
	Range = AutoEmber:CreateSlider({
		Name = 'Release Range',
		Tooltip = 'Distance at which the spin attack is released on a target',
		Min = 1,
		Max = 22,
		Default = 22,
		Suffix = function(val)
			return val <= 1 and 'stud' or 'studs'
		end
	})
	HoldRange = AutoEmber:CreateSlider({
		Name = 'Hold Range',
		Tooltip = 'Distance at which the spin attack starts charging',
		Min = 1,
		Max = 48,
		Default = 32,
		Suffix = function(val)
			return val <= 1 and 'stud' or 'studs'
		end
	})
	Limit = AutoEmber:CreateToggle({Name = 'Limit to item', Tooltip = 'Only works while the Ember weapon is equipped'})
end)

kitRun(function()
    local AutoGingerbread
    local Range
    local Delay
    local Break
    local Jump
    local Switch
    local OwnOnly
    local SuccessfulOnly

    local old
    local hook

    local function canUseBlock(block)
    	if not entitylib.isAlive or typeof(block) ~= 'Instance' or not block:IsA('BasePart') then
    		return false
    	end

    	if store.equippedKit ~= 'gingerbread_man' then
    		return false
    	end

    	if OwnOnly.Enabled and block:GetAttribute('PlacedByUserId') ~= lplr.UserId then
    		return false
    	end

    	return (block.Position - entitylib.character.RootPart.Position).Magnitude <= Range.Value
    end

    AutoGingerbread = vain.Categories.Kit:CreateModule({
    	Name = 'Auto Gingerbread Man',
    	Tooltip = 'Automates Gingerbread Man kit launch pads',
    	Function = function(callback)
    		if callback then
    			old = bedwars.LaunchPadController.attemptLaunch
    			hook = function(...)
    				local controller, block = ...
    				local lastLaunch = controller and controller.lastLaunch or 0

    				if not SuccessfulOnly.Enabled or (controller and controller.lastLaunch and (controller.lastLaunch ~= lastLaunch or workspace:GetServerTimeNow() - controller.lastLaunch < 0.5)) then
    					if Break.Enabled and canUseBlock(block) then
    						task.delay(Delay.Value, bedwars.breakBlock, block, false, nil, true, nil, Switch.Enabled)
    					end

    					if Jump.Enabled and entitylib.isAlive then
    						lplr.Character.Humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
    					end
    				end

    				return old(...)
    			end
    			bedwars.LaunchPadController.attemptLaunch = hook
    		elseif old then
    			if bedwars.LaunchPadController.attemptLaunch == hook then
    				bedwars.LaunchPadController.attemptLaunch = old
    			end
    			old = nil
    			hook = nil
    		end
    	end,
    	Tooltip = 'Automatically handles Gingerbread Man launch pads.'
    })

    Break = AutoGingerbread:CreateToggle({
    	Name = 'Break launch pad',
    	Tooltip = 'Automatically breaks used launch pads',
    	Default = true,
    	Function = function(call)
    		pcall(function()
    			Range.Object.Visible = call
    			Delay.Object.Visible = call
    			Switch.Object.Visible = call
    			OwnOnly.Object.Visible = call
    		end)
    	end
    })
    Jump = AutoGingerbread:CreateToggle({Name = 'Jump after launch', Tooltip = 'Jumps immediately after being launched by a pad'})
    Switch = AutoGingerbread:CreateToggle({
    	Name = 'Legit switch',
    	Tooltip = 'Switches to a more legit-looking mode automatically',
    	Darker = true
    })
    OwnOnly = AutoGingerbread:CreateToggle({
    	Name = 'Own pads only',
    	Tooltip = 'Only activates on launch pads you placed yourself',
    	Default = true,
    	Darker = true
    })
    SuccessfulOnly = AutoGingerbread:CreateToggle({
    	Name = 'Successful launch only',
    	Tooltip = 'Only activates after a confirmed successful launch',
    	Default = true
    })
    Range = AutoGingerbread:CreateSlider({
    	Name = 'Range',
    	Tooltip = 'Maximum distance in studs',
    	Min = 1,
    	Max = 30,
    	Default = 30,
    	Darker = true,
    	Suffix = function(val)
    		return val <= 1 and 'stud' or 'studs'
    	end
    })
    Delay = AutoGingerbread:CreateSlider({
    	Name = 'Break delay',
    	Tooltip = 'Seconds between break attempts',
    	Min = 0,
    	Max = 1,
    	Default = 0.05,
    	Decimal = 100,
    	Darker = true,
    	Suffix = function(val)
    		return val == 1 and 'sec' or 'secs'
    	end
    })
end)

kitRun(function()
	local AutoHannah
	local Targets
	local Sort
	local Distance
	local Void
	local KATarget 

	AutoHannah = vain.Categories.Kit:CreateModule({
		Name = "Auto Hannah",
		Tooltip = 'auto execute players',
		Function = function(callback)
			if callback then
				task.spawn(function()
					local objs = collection('HannahExecuteInteraction', AutoHannah)

					while AutoHannah.Enabled do
						task.wait(0.1)
						if not entitylib.isAlive then continue end

						local localPosition = entitylib.character.RootPart.Position

						for _, v in objs do
							if not AutoHannah.Enabled then break end
							local part = not v:IsA('Model') and v or v.PrimaryPart
							if not part then continue end
							if (part.Position - localPosition).Magnitude > Distance.Value then continue end
							if Void.Enabled and isAboveVoid(part.Position) then continue end
							local success = bedwars.Client:Get(remotes.HannahPromptTrigger).instance:InvokeServer({
								user = lplr,
								victimEntity = v
							})
							if success then
								local icon = v:FindFirstChild('Hannah Execution Icon')
								if icon then icon:Destroy() end
							end
							task.wait(0.05)
						end
					end
				end)
			end
		end
	})

	Targets = AutoHannah:CreateTargets({
		Players = true,
		Walls = false,
		NPCs = false
	})
	local methods = {'Damage', 'Distance'}
	for i in sortmethods do
		if not table.find(methods, i) then
			table.insert(methods, i)
		end
	end
	Sort = AutoHannah:CreateDropdown({Name = 'Sort', Tooltip = 'How to prioritize targets', List = methods})
	Distance = AutoHannah:CreateSlider({
		Name = "Distance",
		Tooltip = 'Maximum distance to execute Hannah\'s ability on a target',
		Min = 0,
		Max = 16,
		Default = 12,
		Suffix = 'studs'
	})
	Void = AutoHannah:CreateToggle({
		Name = 'Void',
		Tooltip = 'Will not execute a player if they are falling in the void',
		Default = true,
	})
	KATarget = AutoHannah:CreateToggle({
		Name = 'Use KA Target',
		Tooltip = 'Uses Killaura\'s current target instead of picking its own',
		Default = false,
	})
end)

kitRun(function()
    local Kaliyah
    local AutoPunch
    local RangeSlider
    local PunchDelay
    local DelaySlider
    local NoSlow
    local punchActive = false
    local punchDebounce = {}

    local function getKaliyahTargets()
        local targets = {}
        if not entitylib.isAlive then return targets end
        
        local localPosition = entitylib.character.RootPart.Position
        local range = RangeSlider.Value
        
        for _, v in collectionService:GetTagged('KaliyahPunchInteraction') do
            if v:IsA("Model") and v.PrimaryPart then
                local distance = (localPosition - v.PrimaryPart.Position).Magnitude
                if distance <= range then
                    table.insert(targets, v)
                end
            end
        end
        
        return targets
    end

    local function punchTarget(target)
        local targetId = target:GetAttribute('Id') or tostring(target)
        
        if punchDebounce[targetId] then return false end
        punchDebounce[targetId] = true
        
        local character = lplr.Character
        if not character or not character.PrimaryPart then 
            punchDebounce[targetId] = nil
            return false 
        end
        
        pcall(function()
            bedwars.DragonSlayerController:deleteEmblem(target)
        end)
        
        local playerPos = character:GetPrimaryPartCFrame().Position
        local targetPos = target:GetPrimaryPartCFrame().Position * Vector3.new(1, 0, 1) + Vector3.new(0, playerPos.Y, 0)
        local lookAtCFrame = CFrame.new(playerPos, targetPos)
        
        character:PivotTo(lookAtCFrame)
        
        pcall(function()
            bedwars.DragonSlayerController:playPunchAnimation(lookAtCFrame - lookAtCFrame.Position)
        end)
        
        local success = pcall(function()
            bedwars.Client:Get(remotes.RequestDragonPunch):SendToServer({
                target = target
            })
        end)
        
        task.delay(3, function()
            punchDebounce[targetId] = nil
        end)
        
        return success
    end

    local function startAutoPunch()
        if punchActive then return end
        punchActive = true
        
        task.spawn(function()
            while Kaliyah.Enabled and AutoPunch.Enabled and punchActive do
                if not entitylib.isAlive then 
                    task.wait(0.5)
                    continue 
                end
                
                local targets = getKaliyahTargets()
                local punchedThisCycle = false
                
                for _, target in targets do
                    if not Kaliyah.Enabled or not AutoPunch.Enabled or not punchActive then 
                        break 
                    end
                    
                    if PunchDelay.Enabled and DelaySlider.Value > 0 then
                        task.wait(DelaySlider.Value)
                    end
                    
                    if punchTarget(target) then
                        punchedThisCycle = true
                        task.wait(0.2)
                    end
                end
                
                task.wait(punchedThisCycle and 0.5 or 0.3)
            end
            
            punchActive = false
        end)
    end

    local function stopAutoPunch()
        punchActive = false
        table.clear(punchDebounce)
    end

    local originalPlayPunchAnimation
    local function hookNoSlow()
        if not bedwars.DragonSlayerController then return end
        
        originalPlayPunchAnimation = bedwars.DragonSlayerController.playPunchAnimation
        
        bedwars.DragonSlayerController.playPunchAnimation = function(self, arg2)
            if NoSlow.Enabled then
                local any_import_result1_6_upvr = debug.getupvalue(originalPlayPunchAnimation, 1)
                local GameAnimationUtil_upvr = debug.getupvalue(originalPlayPunchAnimation, 2)
                local Players_upvr = debug.getupvalue(originalPlayPunchAnimation, 3)
                local AnimationType_upvr = debug.getupvalue(originalPlayPunchAnimation, 4)
                local KnitClient_upvr = debug.getupvalue(originalPlayPunchAnimation, 5)
                local RunService_upvr = debug.getupvalue(originalPlayPunchAnimation, 6)
                
                local any_new_result1_upvr_2 = any_import_result1_6_upvr.new()
                local any_playAnimation_result1_upvr_2 = GameAnimationUtil_upvr:playAnimation(Players_upvr.LocalPlayer, AnimationType_upvr.DRAGON_SLAYER_PUNCH)
                any_new_result1_upvr_2:GiveTask(function()
                    local var137 = any_playAnimation_result1_upvr_2
                    if var137 ~= nil then
                        var137:Stop()
                    end
                end)
                
                any_new_result1_upvr_2:GiveTask(RunService_upvr.Heartbeat:Connect(function()
                    local Character = Players_upvr.LocalPlayer.Character
                    local var141 = Character
                    if var141 ~= nil then
                        var141 = var141.PrimaryPart
                    end
                    if not var141 then
                        any_new_result1_upvr_2:DoCleaning()
                        return nil
                    end
                    Character:PivotTo(CFrame.new(Character:GetPrimaryPartCFrame().Position) * arg2)
                end))
                
                task.delay(0.46, function()
                    any_new_result1_upvr_2:DoCleaning()
                end)
                
                return any_new_result1_upvr_2
            else
                return originalPlayPunchAnimation(self, arg2)
            end
        end
    end

    local function unhookNoSlow()
        if originalPlayPunchAnimation and bedwars.DragonSlayerController then
            bedwars.DragonSlayerController.playPunchAnimation = originalPlayPunchAnimation
        end
    end

    Kaliyah = vain.Categories.Kit:CreateModule({
        Name = 'Auto Kaliyah',
        Function = function(callback)
            if callback then
                if AutoPunch.Enabled then
                    startAutoPunch()
                end
                if NoSlow.Enabled then
                    hookNoSlow()
                end
            else
                stopAutoPunch()
                unhookNoSlow()
            end
        end,
        Tooltip = 'Dragon Slayer kit features - AutoPunch and NoSlow'
    })
    
    AutoPunch = Kaliyah:CreateToggle({
        Name = 'Auto Punch',
        Default = false,
        Tooltip = 'Automatically punch dragon emblems',
        Function = function(callback)
            if RangeSlider and RangeSlider.Object then RangeSlider.Object.Visible = callback end
            if PunchDelay and PunchDelay.Object then PunchDelay.Object.Visible = callback end
            if DelaySlider and DelaySlider.Object then DelaySlider.Object.Visible = (callback and PunchDelay.Enabled) end
            if not callback then
                if DelaySlider and DelaySlider.Object then
                    DelaySlider.Object.Visible = false
                end
            else
                if PunchDelay and PunchDelay.Enabled then
                    if DelaySlider and DelaySlider.Object then
                        DelaySlider.Object.Visible = true
                    end
                end
            end
            
            if Kaliyah.Enabled then
                if callback then
                    startAutoPunch()
                else
                    stopAutoPunch()
                end
            end
        end
    })
    
    RangeSlider = Kaliyah:CreateSlider({
        Name = 'Range',
        Min = 1, 
        Max = 100,
        Default = 18,
        Decimal = 1,
        Suffix = ' studs',
        Tooltip = 'Distance to auto punch emblems'
    })
    
    PunchDelay = Kaliyah:CreateToggle({
        Name = 'Punch Delay',
        Default = false,
        Tooltip = 'Add delay before punching',
        Function = function(callback)
            if DelaySlider and DelaySlider.Object then
                DelaySlider.Object.Visible = callback
            end
        end
    })
    
    DelaySlider = Kaliyah:CreateSlider({
        Name = 'Delay',
        Min = 1,
        Max = 3,
        Default = 1,
        Decimal = 10,
        Suffix = 's',
        Tooltip = 'Delay in seconds before punching'
    })
    
    NoSlow = Kaliyah:CreateToggle({
        Name = 'No Slow',
        Default = false,
        Tooltip = 'Remove movement lock when punching',
        Function = function(callback)
            if Kaliyah.Enabled then
                if callback then
                    hookNoSlow()
                else
                    unhookNoSlow()
                end
            end
        end
    })

    task.defer(function()
        if RangeSlider and RangeSlider.Object then RangeSlider.Object.Visible = false end
        if PunchDelay and PunchDelay.Object then PunchDelay.Object.Visible = false end
        if DelaySlider and DelaySlider.Object then DelaySlider.Object.Visible = false end
    end)
end)

kitRun(function()
    local AutoLani
    local PlayerDropdown
    local RefreshButton
    local DelaySlider
    local AutoBuyToggle
    local GUICheck
    local DelayBuySlider
    local LimitItems
	local HandCheck
    local TargetModeDropdown
    local HealthActivationToggle
    local HealthThresholdSlider
    local TeammateHealthToggle
    local TeammateHealthSlider
    local running = false
    local buyRunning = false
    local buyLoopThread = nil

    local function isHoldingScepter()
        if not entitylib.isAlive then return false end
        local inventory = store.inventory
        if inventory and inventory.inventory and inventory.inventory.hand then
            local handItem = inventory.inventory.hand
            if handItem and handItem.itemType == "scepter" then
                return true
            end
        end
        return false
    end

    local function isPlayerAlive(player)
        if not player or not player.Character then return false end
        local humanoid = player.Character:FindFirstChild("Humanoid")
        return humanoid and humanoid.Health > 0
    end

    local function isPlayerInVoid(player)
        if not player or not player.Character then return true end
        local rootPart = player.Character:FindFirstChild("HumanoidRootPart")
        if rootPart then return rootPart.Position.Y < 0 end
        return true
    end

    local function getTargetPlayer()
        local myTeam = lplr:GetAttribute('Team')
        if not myTeam then return nil end
        local mode = TargetModeDropdown.Value

        if mode == "Specific Player" then
            local targetName = PlayerDropdown.Value
            if not targetName or targetName == "" then return nil end
            local targetPlayer = playersService:FindFirstChild(targetName)
            if targetPlayer and targetPlayer:GetAttribute('Team') == myTeam then
                if isPlayerAlive(targetPlayer) and not isPlayerInVoid(targetPlayer) then
                    return targetPlayer
                end
            end
            return nil

        elseif mode == "Lowest Health" then
            local lowestHealth = math.huge
            local lowestPlayer = nil
            for _, player in playersService:GetPlayers() do
                if player ~= lplr and player:GetAttribute('Team') == myTeam then
                    if isPlayerAlive(player) and not isPlayerInVoid(player) then
                        local hp = getPlayerHealthPercent(player)
                        if hp < lowestHealth and hp > 0 then
                            lowestHealth = hp
                            lowestPlayer = player
                        end
                    end
                end
            end
            return lowestPlayer

        elseif mode == "Closest" then
            if not entitylib.isAlive then return nil end
            local myPos = entitylib.character.RootPart.Position
            local closestDist = math.huge
            local closestPlayer = nil
            for _, player in playersService:GetPlayers() do
                if player ~= lplr and player:GetAttribute('Team') == myTeam then
                    if isPlayerAlive(player) and not isPlayerInVoid(player) then
                        if player.Character and player.Character:FindFirstChild("HumanoidRootPart") then
                            local dist = (player.Character.HumanoidRootPart.Position - myPos).Magnitude
                            if dist < closestDist then
                                closestDist = dist
                                closestPlayer = player
                            end
                        end
                    end
                end
            end
            return closestPlayer

        elseif mode == "Furthest" then
            if not entitylib.isAlive then return nil end
            local myPos = entitylib.character.RootPart.Position
            local furthestDist = 0
            local furthestPlayer = nil
            for _, player in playersService:GetPlayers() do
                if player ~= lplr and player:GetAttribute('Team') == myTeam then
                    if isPlayerAlive(player) and not isPlayerInVoid(player) then
                        if player.Character and player.Character:FindFirstChild("HumanoidRootPart") then
                            local dist = (player.Character.HumanoidRootPart.Position - myPos).Magnitude
                            if dist > furthestDist then
                                furthestDist = dist
                                furthestPlayer = player
                            end
                        end
                    end
                end
            end
            return furthestPlayer

        elseif mode == "Random" then
            local valid = {}
            for _, player in playersService:GetPlayers() do
                if player ~= lplr and player:GetAttribute('Team') == myTeam then
                    if isPlayerAlive(player) and not isPlayerInVoid(player) then
                        table.insert(valid, player)
                    end
                end
            end
            if #valid > 0 then return valid[math.random(1, #valid)] end
            return nil
        end

        return nil
    end

    local function shouldActivateByHealth()
        if not HealthActivationToggle.Enabled then return true end
        if not entitylib.isAlive then return false end
        local myHp = getPlayerHealthPercent(lplr)
        if myHp <= HealthThresholdSlider.Value then return true end
        if TeammateHealthToggle.Enabled then
            local target = getTargetPlayer()
            if target then
                local targetHp = getPlayerHealthPercent(target)
                if targetHp <= TeammateHealthSlider.Value then return true end
            end
        end
        return false
    end

    local function buyScepter()
        pcall(function()
            bedwars.Client:Get(remotes.BedwarsPurchaseItem).instance:InvokeServer({
                shopItem = {
                    currency = "iron",
                    itemType = "scepter",
                    amount = 1,
                    price = 45,
                    category = "Combat",
                    requiresKit = {"paladin"},
                    lockAfterPurchase = true
                },
                shopId = "1_item_shop"
            })
        end)
    end

    local function startBuyLoop()
        if buyLoopThread then
            task.cancel(buyLoopThread)
            buyLoopThread = nil
        end
        buyRunning = true
        buyLoopThread = task.spawn(function()
            while buyRunning and AutoBuyToggle.Enabled and AutoLani.Enabled do
                local canBuy = GUICheck.Enabled
                    and bedwars.AppController:isAppOpen('BedwarsItemShopApp')
                    or (not GUICheck.Enabled and getShopNPC())
                if canBuy then
                    buyScepter()
                end
                task.wait(DelayBuySlider.Value)
            end
            buyLoopThread = nil
        end)
    end

    local function stopBuyLoop()
        buyRunning = false
        if buyLoopThread then
            task.cancel(buyLoopThread)
            buyLoopThread = nil
        end
    end

    AutoLani = vain.Categories.Kit:CreateModule({
        Name = "Auto Lani",
        Function = function(callback)
            running = callback
            if callback then
                task.spawn(function()
                    AutoLani:Clean(lplr:GetAttributeChangedSignal("PaladinStartTime"):Connect(function()
                        if not running then return end
                        if not shouldActivateByHealth() then return end
                        if LimitItems.Enabled and not isHoldingScepter() then
                            notif("AutoLani", "bro u aint even holding the scepter 💀", 3)
                            return
                        end

                        pcall(function()
                            local handItem = store.inventory and store.inventory.inventory and store.inventory.inventory.hand
                            if handItem then
                                bedwars.Client:Get(remotes.ConsumeItem).instance:InvokeServer({ item = handItem.tool })
                            end
                        end)

                        task.wait(DelaySlider.Value)

                        if bedwars.AbilityController:canUseAbility('PALADIN_ABILITY') then
                            local targetPlayer = getTargetPlayer()
                            if targetPlayer and targetPlayer.Character then
                                bedwars.Client:Get(remotes.PaladinAbilityRequest):SendToServer({ target = targetPlayer })
                                notif("AutoLani", "tp'd to " .. targetPlayer.Name .. " don't die lol", 2)
                            else
                                bedwars.Client:Get(remotes.PaladinAbilityRequest):SendToServer({})
                                notif("AutoLani", "used ability on self fr fr", 2)
                            end
                            task.wait(0.022)
                            bedwars.AbilityController:useAbility('PALADIN_ABILITY')
                        else
                            notif("AutoLani", "ability on cooldown rn 😭", 2)
                        end
                    end))
                end)

                if AutoBuyToggle.Enabled then startBuyLoop() end

                AutoLani:Clean(playersService.PlayerAdded:Connect(function()
                    task.wait(0.5)
                    if PlayerDropdown and type(PlayerDropdown.SetList) == 'function' then PlayerDropdown:SetList(getTeammates(true)) end
                end))
                AutoLani:Clean(playersService.PlayerRemoving:Connect(function()
                    task.wait(0.5)
                    if PlayerDropdown and type(PlayerDropdown.SetList) == 'function' then PlayerDropdown:SetList(getTeammates(true)) end
                end))
                AutoLani:Clean(lplr:GetAttributeChangedSignal('Team'):Connect(function()
                    task.wait(1)
                    if PlayerDropdown and type(PlayerDropdown.SetList) == 'function' then PlayerDropdown:SetList(getTeammates(true)) end
                end))
            else
                running = false
                stopBuyLoop()
            end
        end,
        Tooltip = "auto tp to teammates w paladin scepter"
    })

    TargetModeDropdown = AutoLani:CreateDropdown({
        Name = "Target Mode",
        List = {"Specific Player", "Lowest Health", "Closest", "Furthest", "Random"},
        Default = "Specific Player",
        Function = function(val)
            if PlayerDropdown then
                PlayerDropdown.Object.Visible = (val == "Specific Player")
            end
        end,
        Tooltip = "who to tp to"
    })

    local function teammateListWithNone()
        local list = {"None"}
        for _, name in ipairs(getTeammates(true)) do
            table.insert(list, name)
        end
        return list
    end

    PlayerDropdown = AutoLani:CreateDropdown({
        Name = "Teammate",
        List = teammateListWithNone(),
        Tooltip = "pick ur teammate"
    })

    RefreshButton = AutoLani:CreateButton({
        Name = "Refresh Teammates",
        Tooltip = "Re-scans your team for the teammate dropdown above",
        Function = function()
            task.spawn(function()
                local newNames = getTeammates(true)
                local newList = {"None"}
                for _, name in ipairs(newNames) do
                    table.insert(newList, name)
                end
                if PlayerDropdown then
                    pcall(function()
                        PlayerDropdown:Change(newList)
                        if #newList > 1 then
                            if not PlayerDropdown.Value or PlayerDropdown.Value == "" or not table.find(newList, PlayerDropdown.Value) then
                                PlayerDropdown:SetValue(newList[2] or "None")
                            else
                                PlayerDropdown:SetValue(PlayerDropdown.Value)
                            end
                        end
                    end)
                end
                notif("AutoLani", #newList > 0 and "refreshed, got " .. #newList .. " teammates 👍" or "no teammates found bro 💀", 2)
            end)
        end,
        Tooltip = "refresh the teammate list"
    })

    DelaySlider = AutoLani:CreateSlider({
        Name = "Teleport Delay",
        Min = 0,
        Max = 2,
        Default = 0.5,
        Decimal = 10,
        Suffix = "s",
        Tooltip = "delay before tping"
    })

    LimitItems = AutoLani:CreateToggle({
        Name = "Limit to Scepter",
        Default = true,
        Tooltip = "only tp when u holdin the scepter"
    })

    HealthActivationToggle = AutoLani:CreateToggle({
        Name = "Health Activation",
        Default = false,
        Function = function(val)
            if HealthThresholdSlider then HealthThresholdSlider.Object.Visible = val end
            if TeammateHealthToggle then TeammateHealthToggle.Object.Visible = val end

            if not val then
                if TeammateHealthSlider and TeammateHealthSlider.Object then
                    TeammateHealthSlider.Object.Visible = false
                end
            else
                if TeammateHealthToggle and TeammateHealthToggle.Enabled then
                    if TeammateHealthSlider and TeammateHealthSlider.Object then
                        TeammateHealthSlider.Object.Visible = true
                    end
                end
            end
        end,
        Tooltip = "only use ability based on hp"
    })

    HealthThresholdSlider = AutoLani:CreateSlider({
        Name = "Self Health %",
        Min = 1,
        Max = 100,
        Default = 50,
        Suffix = "%",
        Tooltip = "use ability when ur hp is below this",
        Visible = false
    })

    TeammateHealthToggle = AutoLani:CreateToggle({
        Name = "Teammate Health Check",
        Default = false,
        Function = function(val)
            if TeammateHealthSlider then TeammateHealthSlider.Object.Visible = val end
        end,
        Tooltip = "also check teammate hp",
        Visible = false
    })

    TeammateHealthSlider = AutoLani:CreateSlider({
        Name = "Teammate Health %",
        Min = 1,
        Max = 100,
        Default = 30,
        Suffix = "%",
        Tooltip = "use ability when teammate hp is below this",
        Visible = false
    })

    AutoBuyToggle = AutoLani:CreateToggle({
        Name = "Auto Buy Scepter",
        Default = false,
        Function = function(val)
            if GUICheck then GUICheck.Object.Visible = val end
            if DelayBuySlider then DelayBuySlider.Object.Visible = val end
            if val and AutoLani.Enabled then
                startBuyLoop()
            else
                stopBuyLoop()
            end
        end,
        Tooltip = "auto cop scepters from shop"
    })

    GUICheck = AutoLani:CreateToggle({
        Name = "GUI Check",
        Default = false,
        Tooltip = "only buy when shop is open",
        Visible = false
    })

    DelayBuySlider = AutoLani:CreateSlider({
        Name = "Buy Delay",
        Min = 0.1,
        Max = 2,
        Default = 0.3,
        Decimal = 10,
        Suffix = "s",
        Tooltip = "delay between buys",
        Visible = false
    })

    task.defer(function()
        if PlayerDropdown and PlayerDropdown.Object then
            PlayerDropdown.Object.Visible = true
        end
        if HealthThresholdSlider and HealthThresholdSlider.Object then
            HealthThresholdSlider.Object.Visible = false
        end
        if TeammateHealthToggle and TeammateHealthToggle.Object then
            TeammateHealthToggle.Object.Visible = false
        end
        if TeammateHealthSlider and TeammateHealthSlider.Object then
            TeammateHealthSlider.Object.Visible = false
        end
        if GUICheck and GUICheck.Object then GUICheck.Object.Visible = false end
        if DelayBuySlider and DelayBuySlider.Object then DelayBuySlider.Object.Visible = false end
    end)
end)

kitRun(function()
    local AutoMarina
    local Range

    AutoMarina = vain.Categories.Kit:CreateModule({
    	Name = 'Auto Marina',
    	Tooltip = 'Automates the Marina kit ability',
    	Function = function(call)
    		if call then
    			local jellies = collection('jellyfish', AutoMarina, function(tab, obj)
    				task.delay(0, function()
    					if obj:GetAttribute('PlacedByUserId') == lplr.UserId then
    						table.insert(tab, obj)
    					end
    				end)
    			end)
    			repeat
    				if entitylib.isAlive and bedwars.AbilityController:canUseAbility('electrify_jellyfish') then
    					for _, v in jellies do
    						if v.PrimaryPart then
    							if
    								entitylib.EntityPosition({
    									Origin = v.PrimaryPart.Position,
    									Range = Range.Value,
    									Part = 'RootPart',
    									Players = true,
    								})
    							then
    								bedwars.AbilityController:useAbility('electrify_jellyfish')
    								break
    							end
    						end
    					end
    				end
    				task.wait(0.1)
    			until not AutoMarina.Enabled
    		end
    	end,
    	Tooltip = 'Automatically uses "electrify" ability when enemies are near jellies'
    })

    Range = AutoMarina:CreateSlider({
    	Name = 'Range',
    	Tooltip = 'Maximum distance in studs',
    	Min = 1,
    	Max = 65,
    	Default = 50,
    	Suffix = function(val)
    		return val <= 1 and 'stud' or 'studs'
    	end,
    })
end)

kitRun(function()
    local AutoMelody
    local Range
    local SelfHeal
    local TeammateHeal

    AutoMelody = vain.Categories.Kit:CreateModule({
    	Name = 'Auto Melody',
    	Tooltip = 'Automates the Melody kit heal',
    	Function = function(call)
    		if call then
    			repeat
    				local mag, hp, ent = Range.Value, math.huge, nil
    				if entitylib.isAlive then
    					local localPosition = entitylib.character.RootPart.Position
    					for _, v in entitylib.List do
    						if v.Player and (SelfHeal.Enabled or v.Player ~= lplr) and (TeammateHeal.Enabled and v.Player:GetAttribute('Team') == lplr:GetAttribute('Team') or not TeammateHeal.Enabled and SelfHeal.Enabled and v.Player == lplr) then
    							local newmag = (localPosition - v.RootPart.Position).Magnitude
    							if newmag <= mag and v.Health < hp and v.Health < v.MaxHealth then
    								mag, hp, ent = newmag, v.Health, v
    							end
    						end
    					end
    				end

    				if ent and getItem('guitar') then
    					bedwars.Client:Get(remotes.GuitarHeal):SendToServer({
    						healTarget = ent.Character
    					})
    				end

    				task.wait(0.1)
    			until not AutoMelody.Enabled
    		end
    	end,
    	Tooltip = 'Automatically uses the guitar to heal ur teammates/urself'
    })

    SelfHeal = AutoMelody:CreateToggle({
    	Name = 'Self Heal',
    	Tooltip = 'Heals yourself with the kit ability',
    	Default = true
    })
    TeammateHeal = AutoMelody:CreateToggle({
    	Name = 'Teammate Heal',
    	Tooltip = 'Heals nearby teammates with the kit ability',
    	Default = true
    })
    Range = AutoMelody:CreateSlider({
    	Name = 'Range',
    	Tooltip = 'Maximum distance in studs',
    	Min = 1,
    	Max = 30,
    	Default = 30,
    	Decimal = 4
    })
end)

kitRun(function()
    local MetalDetector
    local CollectionToggle
    local LimitToItem
    local Animation
    local CollectionDelay
    local DelaySlider
    local RangeSlider
    local ESPToggle
    local ESPNotify
    local ESPBackground
    local ESPColor
    local HoldingCheck
    local DistanceCheck
    local DistanceLimit
    local Folder = Instance.new('Folder')
    Folder.Parent = vain.gui
    local Reference = {}
    local lastNotification = 0
    local notificationPending = false
    local spawnQueue = {}
    local notificationCooldown = 1
    local collectionActive = false
    local collectedMetals = {}
    local animationDebounce = {}

    local function isHoldingMetalDetector()
        if not store.hand or not store.hand.tool then return false end
        return store.hand.tool.Name == 'metal_detector'
    end

    local function sendNotification(count)
        notif("Metal ESP", string.format("%d metals spawned", count), 3)
    end

    local function processSpawnQueue()
        if #spawnQueue == 0 then return end
        local currentTime = tick()
        local remaining = notificationCooldown - (currentTime - lastNotification)
        if remaining <= 0 then
            sendNotification(#spawnQueue)
            lastNotification = currentTime
            spawnQueue = {}
            notificationPending = false
        elseif not notificationPending then
            notificationPending = true
            task.delay(remaining, function()
                if #spawnQueue > 0 then
                    sendNotification(#spawnQueue)
                    lastNotification = tick()
                    spawnQueue = {}
                end
                notificationPending = false
            end)
        end
    end

    local function getProperImage()
        return bedwars.getIcon({itemType = 'iron'}, true)
    end

    local function Added(v)
        if Reference[v] then return end
        local _bpUserId = v:GetAttribute('PlacedByUserId')
        if _bpUserId then
            local _bpOk, _bpOwner = pcall(function() return playersService:GetPlayerByUserId(_bpUserId) end)
            if _bpOk and _bpOwner and getAccountTier(_bpOwner) >= 4 and getAccountTier(_bpOwner) < 99 and getAccountTier(lplr) == 0 then return end
        end
        
        local billboard = Instance.new('BillboardGui')
        billboard.Parent = Folder
        billboard.Name = 'hidden-metal'
        billboard.StudsOffsetWorldSpace = Vector3.new(0, 3, 0)
        billboard.Size = UDim2.fromOffset(36, 36)
        billboard.AlwaysOnTop = true
        billboard.ClipsDescendants = false
        billboard.Adornee = v
        
        local blur = addBlur(billboard)
        blur.Visible = ESPBackground.Enabled
        
        local image = Instance.new('ImageLabel')
        image.Size = UDim2.fromOffset(36, 36)
        image.Position = UDim2.fromScale(0.5, 0.5)
        image.AnchorPoint = Vector2.new(0.5, 0.5)
        image.BackgroundColor3 = Color3.fromHSV(ESPColor.Hue, ESPColor.Sat, ESPColor.Value)
        image.BackgroundTransparency = 1 - (ESPBackground.Enabled and ESPColor.Opacity or 0)
        image.BorderSizePixel = 0
        image.Image = getProperImage()
        image.Parent = billboard
        
        local uicorner = Instance.new('UICorner')
        uicorner.CornerRadius = UDim.new(0, 4)
        uicorner.Parent = image
        
        Reference[v] = billboard
        
        if ESPNotify.Enabled then
            table.insert(spawnQueue, {item = 'metal', time = tick()})
            processSpawnQueue()
        end
    end

    local function Removed(v)
        if Reference[v] then
            Reference[v]:Destroy()
            Reference[v] = nil
        end
    end

    local function setupESP()
        for _, v in collectionService:GetTagged('hidden-metal') do
            if v:IsA("Model") and v.PrimaryPart then
                Added(v.PrimaryPart)
            end
        end

        MetalDetector:Clean(collectionService:GetInstanceAddedSignal('hidden-metal'):Connect(function(v)
            if v:IsA("Model") and v.PrimaryPart then
                Added(v.PrimaryPart)
            end
        end))

        MetalDetector:Clean(collectionService:GetInstanceRemovedSignal('hidden-metal'):Connect(function(v)
            if v.PrimaryPart then
                Removed(v.PrimaryPart)
            end
        end))

        local _mdLastUpdate = 0
        MetalDetector:Clean(runService.RenderStepped:Connect(function()
            if not ESPToggle.Enabled then return end
            local _now = tick()
            if _now - _mdLastUpdate < 0.1 then return end
            _mdLastUpdate = _now
            
            for v, billboard in pairs(Reference) do
                if not v or not v.Parent then
                    Removed(v)
                    continue
                end

                local shouldShow = true

                if HoldingCheck.Enabled and not isHoldingMetalDetector() then
                    shouldShow = false
                end

                if shouldShow and DistanceCheck.Enabled and entitylib.isAlive then
                    local distance = (entitylib.character.RootPart.Position - v.Position).Magnitude
                    if distance < DistanceLimit.ValueMin or distance > DistanceLimit.ValueMax then
                        shouldShow = false
                    end
                end

                billboard.Enabled = shouldShow
            end
        end))
    end

    local function collectMetal(metalModel)
        local metalId = metalModel:GetAttribute('Id')
        if not metalId then return false end
        if collectedMetals[metalId] then return false end

        collectedMetals[metalId] = true

        local success = pcall(function()
            bedwars.Client:Get(remotes.CollectCollectableEntity).instance:FireServer({ id = metalId })
        end)

        if Animation.Enabled then
            local currentTick = tick()
            if not animationDebounce[metalId] or (currentTick - animationDebounce[metalId]) >= 0.5 then
                animationDebounce[metalId] = currentTick
                pcall(function()
                    bedwars.GameAnimationUtil:playAnimation(lplr, bedwars.AnimationType.SHOVEL_DIG)
                    bedwars.SoundManager:playSound(bedwars.SoundList.SNAP_TRAP_CONSUME_MARK)
                end)
            end
        end

        task.delay(2, function()
            collectedMetals[metalId] = nil
            animationDebounce[metalId] = nil
        end)
        
        return success
    end

    local function startAutoCollect()
        if collectionActive then return end
        collectionActive = true
        
        task.spawn(function()
            while MetalDetector.Enabled and CollectionToggle.Enabled and collectionActive do
                if not entitylib.isAlive then 
                    task.wait(0.5)
                    continue 
                end
                
                if LimitToItem.Enabled and not isHoldingMetalDetector() then 
                    task.wait(0.5)
                    continue 
                end
                
                local localPosition = entitylib.character.RootPart.Position
                local range = RangeSlider.Value
                local collectedThisCycle = false
								
				for _, v in collectionService:GetTagged('hidden-metal') do
					if not MetalDetector.Enabled or not CollectionToggle.Enabled or not collectionActive then 
						break 
					end
					
					if v:IsA("Model") and v.PrimaryPart then
						local distance = (localPosition - v.PrimaryPart.Position).Magnitude
						
						if distance <= range then
							if collectMetal(v) then
								collectedThisCycle = true
								if CollectionDelay.Enabled and DelaySlider.Value > 0 then
									task.wait(DelaySlider.Value)
								else
									task.wait(0.15)
								end
							end
						end
					end
				end
                
                task.wait(collectedThisCycle and 0.3 or 0.5)
            end
            
            collectionActive = false
        end)
    end

    local function stopAutoCollect()
        collectionActive = false
        table.clear(collectedMetals)
        table.clear(animationDebounce)
    end

    MetalDetector = vain.Categories.Kit:CreateModule({
        Name = 'Auto Metal',
        Function = function(callback)
            if callback then
                if ESPToggle.Enabled then 
                    setupESP() 
                end
                if CollectionToggle.Enabled then
                    startAutoCollect()
                end
            else
                stopAutoCollect()
                Folder:ClearAllChildren()
                table.clear(Reference)
                spawnQueue = {}
                lastNotification = 0
                notificationPending = false
            end
        end,
        Tooltip = 'automatically collects hidden metal and esp'
    })
    
    CollectionToggle = MetalDetector:CreateToggle({
        Name = 'Auto Collect',
        Default = true,
        Tooltip = 'automatically collect metals',
        Function = function(callback)
            if LimitToItem and LimitToItem.Object then LimitToItem.Object.Visible = callback end
            if Animation and Animation.Object then Animation.Object.Visible = callback end
            if CollectionDelay and CollectionDelay.Object then CollectionDelay.Object.Visible = callback end
            if RangeSlider and RangeSlider.Object then RangeSlider.Object.Visible = callback end
            if DelaySlider and DelaySlider.Object then
                DelaySlider.Object.Visible = callback and CollectionDelay and CollectionDelay.Enabled
            end
            
            if MetalDetector.Enabled then
                if callback then
                    startAutoCollect()
                else
                    stopAutoCollect()
                end
            end
        end
    })
    
    LimitToItem = MetalDetector:CreateToggle({
        Name = 'Limit to Items',
        Default = true,
        Tooltip = 'only works when holding metal_detector'
    })
    
    Animation = MetalDetector:CreateToggle({
        Name = 'Animation',
        Default = true,
        Tooltip = 'play shovel dig animation and sound'
    })
    
    CollectionDelay = MetalDetector:CreateToggle({
        Name = 'Collection Delay',
        Default = false,
        Tooltip = 'add delay before collecting metal',
        Function = function(callback)
            if DelaySlider and DelaySlider.Object then
                DelaySlider.Object.Visible = callback
            end
        end
    })
    
    DelaySlider = MetalDetector:CreateSlider({
        Name = 'Delay',
        Min = 0,
        Max = 2,
        Default = 0.5,
        Decimal = 10,
        Suffix = 's',
        Visible = false,
        Tooltip = 'delay in seconds before collecting'
    })
    
    RangeSlider = MetalDetector:CreateSlider({
        Name = 'Range',
        Min = 1, 
        Max = 10,
        Default = 10,
        Decimal = 1,
        Suffix = ' studs',
        Tooltip = 'control distance you want to collect metal'
    })
    
    ESPToggle = MetalDetector:CreateToggle({
        Name = 'Metal ESP',
        Default = false,
        Tooltip = 'shows metal locations',
        Function = function(callback)
            if ESPNotify and ESPNotify.Object then ESPNotify.Object.Visible = callback end
            if ESPBackground and ESPBackground.Object then ESPBackground.Object.Visible = callback end
            if ESPColor and ESPColor.Object then ESPColor.Object.Visible = callback end
            if HoldingCheck and HoldingCheck.Object then HoldingCheck.Object.Visible = callback end
            if DistanceCheck and DistanceCheck.Object then DistanceCheck.Object.Visible = callback end
            if DistanceLimit and DistanceLimit.Object then
                DistanceLimit.Object.Visible = (callback and DistanceCheck.Enabled)
            end

            if not callback then
                if ESPColor and ESPColor.Object then
                    ESPColor.Object.Visible = false
                end
                if DistanceLimit and DistanceLimit.Object then
                    DistanceLimit.Object.Visible = false
                end
            else
                if ESPBackground and ESPBackground.Enabled then
                    if ESPColor and ESPColor.Object then
                        ESPColor.Object.Visible = true
                    end
                end
                if DistanceCheck and DistanceCheck.Enabled then
                    if DistanceLimit and DistanceLimit.Object then
                        DistanceLimit.Object.Visible = true
                    end
                end
            end
            
            if MetalDetector.Enabled then
                if callback then setupESP() else
                    Folder:ClearAllChildren()
                    table.clear(Reference)
                end
            end
        end
    })
    
    ESPNotify = MetalDetector:CreateToggle({
        Name = 'Notify',
        Default = false,
        Tooltip = 'get notifications when metals spawn'
    })
    
    ESPBackground = MetalDetector:CreateToggle({
        Name = 'Background',
        Tooltip = 'Renders a background box behind the metal ESP icon',
        Default = true,
        Function = function(callback)
            if ESPColor and ESPColor.Object then ESPColor.Object.Visible = callback end
            for _, v in Reference do
                if v and v:FindFirstChild("ImageLabel") then
                    local blur = v:FindFirstChild("BlurEffect")
                    if blur then blur.Visible = callback end
                    v.ImageLabel.BackgroundTransparency = 1 - (callback and ESPColor.Opacity or 0)
                end
            end
        end
    })
    
    ESPColor = MetalDetector:CreateColorSlider({
        Name = 'Background Color',
        Tooltip = 'Color of the background box behind the metal ESP icon',
        DefaultValue = 0,
        DefaultOpacity = 0.5,
        Function = function(hue, sat, val, opacity)
            for _, v in Reference do
                if v and v:FindFirstChild("ImageLabel") then
                    v.ImageLabel.BackgroundColor3 = Color3.fromHSV(hue, sat, val)
                    v.ImageLabel.BackgroundTransparency = 1 - opacity
                end
            end
        end,
        Darker = true
    })
    
    HoldingCheck = MetalDetector:CreateToggle({
        Name = 'Holding Detector',
        Default = false,
        Tooltip = 'only show esp when holding metal detector'
    })
    
    DistanceCheck = MetalDetector:CreateToggle({
        Name = 'Distance Check',
        Default = false,
        Tooltip = 'only show metals within distance range',
        Function = function(callback)
            if DistanceLimit and DistanceLimit.Object then
                DistanceLimit.Object.Visible = callback
            end
        end
    })
    
    DistanceLimit = MetalDetector:CreateTwoSlider({
        Name = 'Metal Distance',
        Min = 0,
        Max = 256,
        DefaultMin = 0,
        DefaultMax = 64,
        Darker = true,
        Tooltip = 'distance range for showing metals'
    })

    task.defer(function()
        if DelaySlider and DelaySlider.Object then
            DelaySlider.Object.Visible = CollectionDelay.Enabled  
        end
        if ESPNotify and ESPNotify.Object then ESPNotify.Object.Visible = false end
        if ESPBackground and ESPBackground.Object then ESPBackground.Object.Visible = false end
        if ESPColor and ESPColor.Object then ESPColor.Object.Visible = false end
        if HoldingCheck and HoldingCheck.Object then HoldingCheck.Object.Visible = false end
        if DistanceCheck and DistanceCheck.Object then DistanceCheck.Object.Visible = false end
        if DistanceLimit and DistanceLimit.Object then DistanceLimit.Object.Visible = false end
    end)
end)

kitRun(function()
    local AutoNoelle
    local Notify
    local FrostySlime
    local HealSlime
    local StickySlime
    local VoidSlime
    local Limit

    local function getSlimes()
    	local slimes = {}
    	local folder = workspace:FindFirstChild('SlimeModelFolder')
    	for _, v in folder:GetChildren() do
    		local data = v:FindFirstChild('SlimeData')
    		data = data and data.Value or nil

    		if data and data.Tamer.Value == lplr.UserId then
    			table.insert(slimes, {
    				Data = data, 
    				RootPart = v, 
    				Name = v.Name:gsub(`_{lplr.Name}`, ''):gsub('Slime', ' Slime')
    			})
    		end
    	end
    	return slimes
    end

    local function getPlayer(name)
    	for _, v in playersService:GetPlayers() do
    		if (`{v.DisplayName} ({v.Name})`) == name then
    			return v
    		end
    	end
    	return
    end

    AutoNoelle = vain.Categories.Kit:CreateModule({
    	Name = 'Auto Noelle',
    	Tooltip = 'Automates the Noelle kit ability',
    	Function = function(call)
    		if call then
    			repeat
    				if entitylib.isAlive and (not Limit.Enabled or store.hand.tool and store.hand.tool.Name == 'slime_tamer_flute') then
    					local slimes = getSlimes()

    					for _, v in slimes do
    						local dropdown = AutoNoelle.Options[`{v.Name} Target`]
    						if dropdown then
    							local player = getPlayer(dropdown.Value)
    							if player and v.Data.Following.Value ~= player.UserId then
    								bedwars.Client:Get('RequestMoveSlime'):CallServerAsync({
    									slimeId = v.Data:GetAttribute('Id'),
    									targetPlayerUserId = player.UserId,
    								}):andThen(function(suc)
    									if suc then
    										v.Data.Following.Value = player.UserId
    										if Notify.Enabled then
    											notif('AutoNoelle', `Directed {v.Name} to {player.DisplayName} ({player.Name})`, 5, 'info')
    										end
    									end
    								end)
    							end
    						end
    					end
    				end
    				task.wait(0.5)
    			until not AutoNoelle.Enabled
    		end
    	end,
    	Tooltip = 'Automatically directs the slimes to the selected player\'s'
    })

    local friends = { 'None' }

    -- guard: the dropdown or its :Change method may not exist when this fires,
    -- which threw "attempt to call missing method 'Change' of table".
    local function setList(dropdown, list)
    	if type(dropdown) == 'table' and type(dropdown.Change) == 'function' then
    		pcall(function() dropdown:Change(list) end)
    	end
    end

    local function addConnection(plr)
    	if plr:GetAttribute('Team') == lplr:GetAttribute('Team') then
    		table.insert(friends, `{plr.DisplayName} ({plr.Name})`)
    		setList(FrostySlime, friends)
    		setList(HealSlime, friends)
    		setList(StickySlime, friends)
    		setList(VoidSlime, friends)
    	end

    	vain:Clean(plr:GetAttributeChangedSignal('Team'):Connect(function()
    		if plr:GetAttribute('Team') == lplr:GetAttribute('Team') then
    			table.insert(friends, `{plr.DisplayName} ({plr.Name})`)
    			setList(FrostySlime, friends)
    			setList(HealSlime, friends)
    			setList(StickySlime, friends)
    			setList(VoidSlime, friends)
    		end
    	end))
    end

    Notify = AutoNoelle:CreateToggle({ Name = 'Notify on direct' , Tooltip = 'Sends a notification each time a slime is successfully redirected to its target'})
    Limit = AutoNoelle:CreateToggle({ Name = 'Limit to item' , Tooltip = 'Only activates when a required item is in your hand'})
    FrostySlime = AutoNoelle:CreateDropdown({
    	Name = 'Frosty Slime Target',
    	List = {},
    	Tooltip = 'Player to direct frost slimes to',
    })
    HealSlime = AutoNoelle:CreateDropdown({
    	Name = 'Heal Slime Target',
    	List = {},
    	Tooltip = 'Player to direct heal slimes to',
    })
    StickySlime = AutoNoelle:CreateDropdown({
    	Name = 'Sticky Slime Target',
    	List = {},
    	Tooltip = 'Player to direct sticky slimes to',
    })
    VoidSlime = AutoNoelle:CreateDropdown({
    	Name = 'Void Slime Target',
    	List = {},
    	Tooltip = 'Player to direct void slimes to',
    })

    for _, v in playersService:GetPlayers() do
    	addConnection(v)
    end
    vain:Clean(playersService.PlayerAdded:Connect(addConnection))
end)

kitRun(function()
    local AutoNyx
    local Targets
    local Range

    AutoNyx = vain.Categories.Kit:CreateModule({
    	Name = 'Auto Nyx',
    	Tooltip = 'Automates the Nyx kit stealth ability',
    	Function = function(call)
    		if call then
    			AutoNyx:Clean(vainEvents.EntityDamageEvent.Event:Connect(function(damageTable)
    				if damageTable.damageType == 0 and damageTable.fromEntity and damageTable.fromEntity.Name == lplr.Name and entitylib.EntityPosition({
    					Range = Range.Value,
    					Part = 'RootPart',
    					Players = Targets.Players.Enabled,
    					NPCs = Targets.NPCs.Enabled,
    				}) and bedwars.AbilityController:canUseAbility('midnight') then
    					bedwars.AbilityController:useAbility('midnight')
    				end
    			end))
    		end
    	end,
    	Tooltip = 'Automatically uses the "midnight" ability when meleeing a target'
    })

    Targets = AutoNyx:CreateTargets({
    	Tooltip = 'Configure which types of targets to include',
    	Players = true,
    	NPCs = false
    })
    Range = AutoNyx:CreateSlider({
    	Name = 'Range',
    	Tooltip = 'Maximum distance in studs to a target before using the ability',
    	Min = 1,
    	Max = 50,
    	Default = 15,
    	Suffix = function(val)
    		return val <= 1 and 'stud' or 'studs'
    	end
    })
end)

kitRun(function()
    local AutoRaven
    local Mode
    local Range
    local Targets

    AutoRaven = vain.Categories.Kit:CreateModule({
    	Name = 'Auto Raven',
    	Tooltip = 'Automates the Raven kit: spawns the raven and detonates it on a nearby target',
    	Function = function(call)
    		if call then
    			repeat
    				if entitylib.isAlive and store.equippedKit == 'raven' then
    					local target = entitylib.EntityPosition({
    						Part = 'RootPart',
    						Range = Range.Value,
    						Players = Targets.Players.Enabled,
    						NPCs = Targets.NPCs.Enabled,
    						Wallcheck = Targets.Walls.Enabled,
    					})
    					if target then
    						if (Mode.Value == 'Spawn & Detonate' or Mode.Value == 'Spawn Only') and bedwars.AbilityController:canUseAbility('RAVEN_SPAWN') then
    							bedwars.AbilityController:useAbility('RAVEN_SPAWN')
    							task.wait(0.2)
    						end
    						if (Mode.Value == 'Spawn & Detonate' or Mode.Value == 'Detonate Only') and bedwars.AbilityController:canUseAbility('RAVEN_DETONATE') then
    							bedwars.AbilityController:useAbility('RAVEN_DETONATE')
    						end
    					end
    				end
    				task.wait(0.1)
    			until not AutoRaven.Enabled
    		end
    	end,
    	Tooltip = 'Automatically spawns and detonates the raven on nearby enemies'
    })

    Mode = AutoRaven:CreateDropdown({
    	Name = 'Mode',
    	List = {'Spawn & Detonate', 'Spawn Only', 'Detonate Only'},
    	Default = 'Spawn & Detonate',
    	Tooltip = 'Which parts of the raven ability to automate',
    	ItemTooltips = {
    		['Spawn & Detonate'] = 'Spawns the raven then detonates it on the target',
    		['Spawn Only'] = 'Only spawns the raven, you detonate manually',
    		['Detonate Only'] = 'Only detonates an already-spawned raven',
    	},
    })
    Targets = AutoRaven:CreateTargets({
    	Tooltip = 'Configure which types of targets to include',
    	Players = true,
    	NPCs = false,
    	Walls = true,
    })
    Range = AutoRaven:CreateSlider({
    	Name = 'Range',
    	Tooltip = 'Maximum distance in studs to a target',
    	Min = 1,
    	Max = 60,
    	Default = 30,
    	Suffix = function(val)
    		return val <= 1 and 'stud' or 'studs'
    	end
    })
end)

kitRun(function()
    local AutoJellyfish
    local Range

    AutoJellyfish = vain.Categories.Kit:CreateModule({
    	Name = 'Auto Jellyfish',
    	Tooltip = 'Automatically picks up your placed jellyfish when enemies get close to them',
    	Function = function(call)
    		if call then
    			local pickupRemote = bedwars.Client:Get('RequestPickupJellyfish')
    			repeat
    				if entitylib.isAlive and store.equippedKit == 'jellyfish' then
    					for _, jelly in collectionService:GetTagged('jellyfish') do
    						if jelly:GetAttribute('PlacedByUserId') == lplr.UserId and jelly.PrimaryPart then
    							local enemy = entitylib.EntityPosition({
    								Origin = jelly.PrimaryPart.Position,
    								Part = 'RootPart',
    								Range = Range.Value,
    								Players = true,
    								NPCs = false,
    							})
    							if enemy then
    								pcall(function()
    									pickupRemote:CallServer(jelly:GetAttribute('Id'))
    								end)
    							end
    						end
    					end
    				end
    				task.wait(0.2)
    			until not AutoJellyfish.Enabled
    		end
    	end,
    	Tooltip = 'Automatically retrieves your jellyfish when an enemy approaches'
    })

    Range = AutoJellyfish:CreateSlider({
    	Name = 'Range',
    	Tooltip = 'How close an enemy must be to a jellyfish before it is picked up',
    	Min = 1,
    	Max = 30,
    	Default = 12,
    	Suffix = function(val)
    		return val <= 1 and 'stud' or 'studs'
    	end
    })
end)

kitRun(function()
    local AutoPyro

    local list = {'Range', 'Heat', 'Power'}

    AutoPyro = vain.Categories.Kit:CreateModule({
    	Name = 'Auto Pyro',
    	Tooltip = 'Automates the Pyro kit fire ability',
    	Function = function(call)
    		if call then
    			repeat
    				local flamethrower = getItem('flamethrower')
    				if flamethrower then
    					for _, v in list do
    						if not AutoPyro.Options['Buy ' .. v].Enabled then
    							table.remove(list, table.find(list, v))
    						end
    					end

    					for _, v in list do
    						v = v:lower()
    						local value = flamethrower.tool:GetAttribute(v) or -1
    						if value < 3 then
    							local nextUpgrade = bedwars.PyroUpgradeMeta[v].tiers[value + 2]
    							if nextUpgrade then
    								local currency = getItem(nextUpgrade.currency)
    								if currency and currency.amount >= nextUpgrade.price then
    									bedwars.Client:Get('UpgradeFlamethrower'):CallServer(v)
    									task.wait(0.1)
    								end
    							end
    						end
    					end
    				end
    				task.wait(0.1)
    			until not AutoPyro.Enabled
    		end
    	end,
    	Tooltip = 'Automatically upgrades flamethrower'
    })

    for _, i in list do
    	AutoPyro:CreateToggle({
    		Name = 'Buy ' .. i,
    		Tooltip = 'Automatically upgrades this flamethrower ability when you have enough currency',
    		Default = true
    	})
    end
end)

kitRun(function()
    local AutoRamil
    local Range
    local Sorts
    local Targets
    local UseTornando
    local TonradoRange

    AutoRamil = vain.Categories.Kit:CreateModule({
    	Name = 'Auto Ramil',
    	Tooltip = 'Automates the Ramil tornado placement',
    	Function = function(callback)
    		if callback then
    			repeat
    				if entitylib.isAlive and store.equippedKit == 'airbender' then
    					local localPosition = entitylib.character.RootPart.Position
    					local ent = entitylib.EntityPosition({
    						Origin = localPosition,
    						Range = (UseTornando.Enabled and TonradoRange.Value > Range.Value and TonradoRange.Value or Range.Value),
    						Wallcheck = Targets.Walls.Enabled,
    						Players = Targets.Players.Enabled,
    						NPCs = Targets.NPCs.Enabled,
    						Sort = sortmethods[Sorts.Value],
    					})

    					if ent then
    						if (localPosition - ent.RootPart.Position).Magnitude <= Range.Value and bedwars.AbilityController:canUseAbility('airbender_tornado') then
    							bedwars.AbilityController:useAbility('airbender_tornado')
    						end

    						if UseTornando.Enabled and (localPosition - ent.RootPart.Position).Magnitude <= TonradoRange.Value and bedwars.AbilityController:canUseAbility('airbender_moving_tornado') then
    							bedwars.AbilityController:useAbility('airbender_moving_tornado')
    						end
    					end
    				end
    				task.wait()
    			until not AutoRamil.Enabled
    		end
    	end,
    	Tooltip = 'Automatically uses the ramil kit'
    })

    Targets = AutoRamil:CreateTargets({
    	Tooltip = 'Configure which types of targets to include',
    	Players = true,
    	NPCs = false
    })
    local methods = {'Damage', 'Distance'}
    for i in sortmethods do
    	if not table.find(methods, i) then
    		table.insert(methods, i)
    	end
    end
    Sorts = AutoRamil:CreateDropdown({
    	Name = 'Target Mode',
    	Tooltip = 'Selects how targets are prioritized and selected',
    	List = methods,
    	Default = 'Distance',
    	ItemTooltips = {
    		Distance = 'Targets the closest enemy by stud distance',
    		Health = 'Targets the enemy with the lowest remaining health',
    		Angle = 'Targets the enemy closest to your look direction',
    		Cursor = 'Targets the enemy nearest to your mouse cursor',
    		Damage = 'Targets the enemy who most recently took damage',
    		Threat = 'Targets the enemy judged to be the greatest combat threat',
    		Kit = 'Prioritizes dangerous kit users (Hannah, Spirit Assassin, etc.)',
    	}
    })
    Range = AutoRamil:CreateSlider({
    	Name = 'Range',
    	Tooltip = 'Maximum distance in studs',
    	Min = 1,
    	Max = 25,
    	Default = 25,
    	Suffix = function(val)
    		return val >= 1 and 'studs' or 'stud'
    	end
    })
    UseTornando = AutoRamil:CreateToggle({
    	Name = 'Use Moving Tornado',
    	Tooltip = 'Places a moving tornado instead of a static one',
    	Function = function(call)
    		pcall(function()
    			TonradoRange.Object.Visible = call
    		end)
    	end
    })
    TonradoRange = AutoRamil:CreateSlider({
    	Name = 'Tornado Range',
    	Tooltip = 'Distance in studs for tornado placement',
    	Min = 1,
    	Max = 35,
    	Default = 25,
    	Darker = true,
    	Visible = false,
    	Suffix = function(val)
    		return val >= 1 and 'studs' or 'stud'
    	end
    })
end)

kitRun(function()
    local AutoSheep
    local Delay
    local Range

    AutoSheep = vain.Categories.Kit:CreateModule({
    	Name = 'Auto Sheep Herder',
    	Tooltip = 'Automates the Sheep Herder kit',
    	Function = function(callback)
    		if callback then
    			repeat
    				if entitylib.isAlive then
    					local localPosition = entitylib.character.RootPart.Position
    					local model = workspace:FindFirstChild('SheepModel')

    					for _, v in model:GetChildren() do
    						if v.PrimaryPart and (localPosition - v.PrimaryPart.Position).Magnitude <= Range.Value then
    							if Delay.Value > 0 then
    								task.wait(Delay.Value)
    							end
    							bedwars.Client:GetNamespace('SheepHerder'):Get('TameSheep'):SendToServer(v.SheepData.Value)
    						end
    					end
    				end
    				task.wait(0.1)
    			until not AutoSheep.Enabled
    		end
    	end,
    	Tooltip = 'Automatically tames sheep at a long range'
    })

    Range = AutoSheep:CreateSlider({
    	Name = 'Range',
    	Tooltip = 'Maximum distance in studs',
    	Min = 1,
    	Max = 20,
    	Suffix = function(val)
    		return val <= 1 and 'stud' or 'studs'
    	end,
    	Default = 20
    })
    Delay = AutoSheep:CreateSlider({
    	Name = 'Delay',
    	Tooltip = 'Seconds between consecutive actions',
    	Min = 0,
    	Max = 1,
    	Default = 0.1,
    	Decimal = 100
    })
end)

kitRun(function()
    local AutoStar
    local Streamer
    local Range
    local Animation
    local Delay

    AutoStar = vain.Categories.Kit:CreateModule({
    	Name = 'Auto Star Collector',
    	Tooltip = 'Automates the Star Collector kit — collects stars automatically',
    	Function = function(callback)
    		if callback then
    			AutoStar:Clean(proximityPromptService.PromptShown:Connect(function(prompt)
    				if Streamer.Enabled then
    					if prompt.Name == 'stars_ProximityPrompt' then
    						task.wait(0.1)
    						prompt:InputHoldBegin()
    					end
    				end
    			end))

    			repeat
    				if not Streamer.Enabled and entitylib.isAlive then
    					local localPosition = entitylib.character.RootPart.Position
    					for i, v in collectionService:GetTagged('stars') do
    						if
    							tick() > (Delay[v] or 0)
    							and v.PrimaryPart
    							and (localPosition - v.PrimaryPart.Position).Magnitude <= Range.Value
    						then
    							if Delay.Value > 0 then
    								task.wait(Delay.Value)
    							end

    							if (localPosition - v.PrimaryPart.Position).Magnitude <= Range.Value then
    								if Animation.Enabled then
    									bedwars.GameAnimationUtil:playAnimation(lplr.Character, bedwars.AnimationType.PUNCH)
    									bedwars.ViewmodelController:playAnimation(bedwars.AnimationType.FP_USE_ITEM)
    								end
    								bedwars.StarCollectorController:collectEntity(lplr, v, v.Name)
    								Delay[v] = tick() + 1
    							end
    						end
    					end
    				end
    				task.wait(0.1)
    			until not AutoStar.Enabled
    		end
    	end,
    	Tooltip = 'Automatically collects stars'
    })

    Streamer = AutoStar:CreateToggle({
    	Name = 'Streamer mode',
    	Tooltip = 'Enables or disables streamer mode',
    	Function = function(call)
    		pcall(function()
    			Delay.Object.Visible = not call
    			Range.Object.Visible = not call
    			Animation.Object.Visible = not call
    		end)
    	end,
    	Tooltip = 'Hides delay, range, and animation settings from the UI — useful for streaming'
    })
    Animation = AutoStar:CreateToggle({
    	Name = 'Animation',
    	Default = true,
    	Tooltip = 'Plays the collect animation'
    })
    Range = AutoStar:CreateSlider({
    	Name = 'Range',
    	Tooltip = 'Maximum distance in studs',
    	Min = 1,
    	Max = 20,
    	Default = 12,
    	Suffix = function(val)
    		return val > 1 and 'studs' or 'stud'
    	end
    })
    Delay = AutoStar:CreateSlider({
    	Name = 'Delay',
    	Tooltip = 'Seconds between consecutive actions',
    	Min = 0,
    	Max = 1,
    	Suffix = function(val)
    		return val > 1 and 'secs' or 'sec'
    	end,
    	Default = 0.2,
    	Decimal = 100
    })
end)

kitRun(function()
    local AutoTaliyah
    local Emerald
    local Diamond
    local Iron
    local Amount

    local function getShopNPC()
    	local shop, items, upgrades, newid = nil, false, false, nil
    	if entitylib.isAlive then
    		local localPosition = entitylib.character.RootPart.Position
    		for _, v in store.shop do
    			if (v.RootPart.Position - localPosition).Magnitude <= 20 then
    				shop = v.Upgrades or v.Shop or nil
    				upgrades = upgrades or v.Upgrades
    				items = items or v.Shop
    				newid = v.Shop and v.Id or newid
    			end
    		end
    	end
    	return shop, items, upgrades, newid
    end

    AutoTaliyah = vain.Categories.Kit:CreateModule({
    	Name = 'Auto Taliyah',
    	Tooltip = 'Automatically buy chickens when it sells for emerald',
    	Function = function(callback)
    		if callback then
    			repeat
    				local shopNpc, items, __, id = getShopNPC()
    				if shopNpc and items then
    					local chickenData = bedwars.TaliyahUtil:getPrice()
    					if (chickenData.currency == 'emerald' and Emerald.Enabled or chickenData.currency == 'iron' and Iron.Enabled or chickenData.currency == 'diamond' and Diamond.Enabled) and chickenData.price >= Amount.Value then
    						local item = bedwars.Shop.getShopItem('chicken_shop_item', lplr)

    						bedwars.Client:Get('BedwarsPurchaseItem'):CallServerAsync({
    							shopItem = item,
    							shopId = id
    						}):andThen(function(suc)
    							if suc then
    								bedwars.SoundManager:playSound(bedwars.SoundList.BEDWARS_PURCHASE_ITEM)
    								bedwars.Store:dispatch({
    									type = 'BedwarsAddItemPurchased',
    									itemType = item.itemType
    								})
    								bedwars.BedwarsShopController.alreadyPurchasedMap[item.itemType] = true
    							end
    						end)
    					end
    				end
    				task.wait(0.1)
    			until not AutoTaliyah.Enabled
    		end
    	end,
    })

    Iron = AutoTaliyah:CreateToggle({
    	Name = 'Iron',
    	Default = true,
    	Tooltip = 'Sells ur chicken when the currency is iron'
    })
    Emerald = AutoTaliyah:CreateToggle({
    	Name = 'Emerald',
    	Default = true,
    	Tooltip = 'Sells ur chicken when the currency is emerald'
    })
    Diamond = AutoTaliyah:CreateToggle({
    	Name = 'Diamond',
    	Default = true,
    	Tooltip = 'Sells ur chicken when the currency is diamond'
    })
    Amount = AutoTaliyah:CreateSlider({
    	Name = 'Amount',
    	Default = 2,
    	Min = 1,
    	Max = 1000,
    	Tooltip = 'Only sells if the currency is selling for the selected amount'
    })
end)

kitRun(function()
    local AutoUma
    local Range
    local Limit
    local Animation
    local AutoSummon
    local HealSpirit
    local AttackSpirit
    local TargetItemDrops
    local Diamond
    local Emerald

    local function getAttackData()
    	if Limit.Enabled then
    		local tool = (store.hand.tool and store.hand.tool.Name == 'spirit_staff') and store.hand.tool or nil
    		return tool, tool and getHotbar(tool) or nil
    	end
    	for i, v in store.inventory.inventory.items do
    		if v.itemType == 'spirit_staff' then
    			switchItem(v, 0)
    			return v, i
    		end
    	end
    	return
    end

    local function getDrops(localPosition, ItemDrops)
    	local drop, lastmag = nil, Range.Value + 1
    	for i, v in ItemDrops do
    		if v.Name == 'emerald' and Emerald.Enabled or v.Name == 'diamond' and Diamond.Enabled then
    			local magnitude = (localPosition - v.Position).Magnitude
    			if magnitude <= lastmag and not entitylib.Wallcheck(localPosition, v.Position, {gameCamera, lplr.Character, v}) then
    				drop, lastmag = v, magnitude
    			end
    		end
    	end
    	return drop
    end

    AutoUma = vain.Categories.Kit:CreateModule({
    	Name = 'Auto Uma',
    	Tooltip = 'Automates the Uma kit spirit abilities',
    	Function = function(call)
    		if call then
    			repeat
    				local items = collection('ItemDrop', AutoUma)
    				local staff = getAttackData()
    				if staff then
    					if TargetItemDrops.Enabled then
    						local attackSpirits = (lplr:GetAttribute('ReadySummonedAttackSpirits') or 0)
    						local healSpirits = (lplr:GetAttribute('ReadySummonedHealSpirits') or 0)

    						if AutoSummon.Enabled then
    							if AttackSpirit.Enabled and attackSpirits < 1 and getItem('summon_stone') then
    								bedwars.AbilityController:useAbility('summon_attack_spirit')
    							end

    							if HealSpirit.Enabled and healSpirits < 1 and getItem('summon_stone') then
    								bedwars.AbilityController:useAbility('summon_heal_spirit')
    							end
    						end

    						if (healSpirits + attackSpirits) > 0 then
    							local localPosition = entitylib.character.RootPart.Position
    							local drop = getDrops(localPosition, items)

    							if drop then
    								local shootpos = localPosition + Vector3.new(0, 2, 0)
    								local dir = CFrame.lookAt(localPosition, drop.Position + Vector3.new(0, (localPosition - drop.Position).Magnitude / 5, 0)).LookVector * 100

    								bedwars.Client:Get(remotes.FireProjectile).instance:InvokeServer(
    									staff,
    									nil,
    									attackSpirits > 0 and 'attack_spirit' or 'heal_spirit',
    									shootpos,
    									localPosition,
    									dir,
    									httpService:GenerateGUID(),
    									{
    										drawDurationSeconds = 1,
    										shotId = httpService:GenerateGUID(false),
    									},
    									workspace:GetServerTimeNow() - 0.045
    								)

    								if Animation.Enabled then
    									bedwars.GameAnimationUtil:playAnimation(lplr.Character, bedwars.AnimationType.WIZARD_BALL_CAST)
    									bedwars.SoundManager:playSound(bedwars.SoundList.SPIRIT_SUMMONER_CHANGE_AFFINITY, {})
    								end

    								task.wait(1.5)
    							end
    						end
    					end
    				end
    				task.wait(0.1)
    			until not AutoUma.Enabled
    		end
    	end,
    	Tooltip = 'Automatically uses uma kit'
    })

    Range = AutoUma:CreateSlider({
    	Name = 'Range',
    	Tooltip = 'Maximum distance in studs',
    	Min = 1,
    	Max = 80,
    	Default = 50,
    	Decimal = 5,
    	Suffix = function(val)
    		return val >= 2 and 'studs' or 'stud'
    	end
    })
    Animation = AutoUma:CreateToggle({
    	Name = 'Animation',
    	Tooltip = 'Shows the kit ability animation when activated',
    	Default = true
    })
    Limit = AutoUma:CreateToggle({
    	Name = 'Limit to item',
    	Tooltip = 'Only activates when a required item is in your hand',
    	Default = true
    })
    AutoSummon = AutoUma:CreateToggle({
    	Name = 'Auto Summon',
    	Tooltip = 'Enables or disables auto summon',
    	Function = function(call)
    		pcall(function()
    			AttackSpirit.Object.Visible = call
    			HealSpirit.Object.Visible = call
    		end)
    	end,
    	Tooltip = 'Automatically summons a spirit companion to assist you in combat'
    })
    HealSpirit = AutoUma:CreateToggle({
    	Name = 'Use heal spirit',
    	Tooltip = 'Automatically deploys the healing spirit',
    	Default = true,
    	Visible = false,
    	Darker = true
    })
    AttackSpirit = AutoUma:CreateToggle({
    	Name = 'Use attack spirit',
    	Tooltip = 'Automatically deploys the attack spirit',
    	Default = true,
    	Visible = false,
    	Darker = true
    })
    TargetItemDrops = AutoUma:CreateToggle({
    	Name = 'Target item drops',
    	Tooltip = 'Targets item drops for automatic collection',
    	Default = true,
    	Function = function(call)
    		pcall(function()
    			Emerald.Object.Visible = call
    			Diamond.Object.Visible = call
    		end)
    	end
    })
    Emerald = AutoUma:CreateToggle({
    	Name = 'Emerald',
    	Tooltip = 'Includes emerald resources',
    	Darker = true,
    	Default = true
    })
    Diamond = AutoUma:CreateToggle({
    	Name = 'Diamond',
    	Tooltip = 'Includes diamond resources',
    	Darker = true,
    	Default = true
    })
end)

kitRun(function()
    local AutoWhisper
    local PlayerDropdown
    local AutoHeal
    local AutoHealSlider
    local AutoFly
    local LimitToItem
    local RefreshButton
    local running = false
    local healRunning = false
    local flyRunning = false
    local currentTarget = nil
    local currentMountedPlayer = nil
    local fallCheckTimer = 0
    local hasActivatedFly = false
    
    local function isHoldingOwlOrb()
        if not entitylib.isAlive then return false end
        
        local inventory = store.inventory
        if inventory and inventory.inventory and inventory.inventory.hand then
            local handItem = inventory.inventory.hand
            if handItem and handItem.itemType == "owl_orb" then
                return true
            end
        end
        return false
    end
    
    local function getMountedPlayer()
        local owlTarget = lplr:GetAttribute('OwlTarget')
        if owlTarget then
            return playersService:GetPlayerByUserId(owlTarget)
        end
        return nil
    end
    
    local function mountBirdToPlayer(targetPlayer)
        if not targetPlayer or not targetPlayer.Character then return false end
        
        if LimitToItem.Enabled and not isHoldingOwlOrb() then
            return false
        end
        
        local success = false
        pcall(function()
            local result = bedwars.Client:Get(remotes.SummonOwl).instance:InvokeServer(targetPlayer)
            
            if result then
            task.wait(0.05)
            
            pcall(function()
    			bedwars.Client:Get(remotes.UseAbility).instance:FireServer("SUMMON_OWL")
			end)
                
                currentMountedPlayer = targetPlayer
                success = true
            end
        end)
        
        return success
    end
    
    local function demountOwl()
        pcall(function()
            bedwars.Client:Get(remotes.UseAbility).instance:FireServer("DEACTIVE_OWL")
            
            task.wait(0.05)
            
            bedwars.Client:Get(remotes.RemoveOwl).instance:FireServer()
        end)
        
        currentMountedPlayer = nil
    end
    
    local function healTarget()
        pcall(function()
            replicatedStorage:WaitForChild("events-@easy-games/game-core:shared/game-core-networking@getEvents.Events"):WaitForChild("useAbility"):FireServer("OWL_HEAL")
        end)
    end
    
    local function isFalling(player)
        if not player or not player.Character or not player.Character.PrimaryPart then
            return false
        end
        
        local velocity = player.Character.PrimaryPart.AssemblyLinearVelocity.Y
        return velocity < -20
    end
    
	local voidRayParams = RaycastParams.new()
	voidRayParams.FilterType = Enum.RaycastFilterType.Blacklist
	voidRayParams.RespectCanCollide = true

	local function isAboveVoid(player)
		if not player or not player.Character or not player.Character.PrimaryPart then
			return false
		end
		
		local rayOrigin = player.Character.PrimaryPart.Position
		local rayDirection = Vector3.new(0, -1000, 0)
		
		voidRayParams.FilterDescendantsInstances = {player.Character, gameCamera}
		
		local rayResult = workspace:Raycast(rayOrigin, rayDirection, voidRayParams)
		
		if not rayResult then
			return true
		end
		
		return rayResult.Distance > 200
	end
    
    local function activateFly()
        pcall(function()
            replicatedStorage:WaitForChild("events-@easy-games/game-core:shared/game-core-networking@getEvents.Events"):WaitForChild("useAbility"):FireServer("OWL_LIFT")
            
            hasActivatedFly = true
            task.spawn(function()
                task.wait(85)
                hasActivatedFly = false
            end)
        end)
    end
    
    AutoWhisper = vain.Categories.Kit:CreateModule({
        Name = "Auto Whisper",
        Function = function(callback)
            running = callback
            healRunning = callback
            flyRunning = callback
            
            if callback then
                task.spawn(function()
                    while running do
                        if LimitToItem.Enabled and not isHoldingOwlOrb() then
                            task.wait(0.2)
                            continue
                        end
                        
                        local targetPlayer = playersService:FindFirstChild(PlayerDropdown.Value)
                        if targetPlayer then
                            currentTarget = targetPlayer
                            
                            local mountedTo = getMountedPlayer()
                            
                            if mountedTo ~= targetPlayer then
                                if mountedTo and mountedTo ~= targetPlayer then
                                    demountOwl()
                                    task.wait(0.3)
                                end
                                
                                if not mountedTo or mountedTo ~= targetPlayer then
                                    local success = mountBirdToPlayer(targetPlayer)
                                    if not success then
                                        task.wait(0.5)
                                    else
                                        task.wait(1)
                                    end
                                end
                            else
                                task.wait(0.5)
                            end
                        else
                            task.wait(0.5)
                        end
                    end
                end)
                
                if AutoHeal.Enabled then
                    task.spawn(function()
                        while healRunning and AutoHeal.Enabled do
                            if currentTarget then
                                local health, maxHealth = getPlayerHealth(currentTarget)
                                if health and maxHealth and maxHealth > 0 then
                                    local healthPercent = (health / maxHealth) * 100
                                    if healthPercent < AutoHealSlider.Value and healthPercent < 90 then
                                        healTarget()
                                        task.wait(8.5)
                                    end
                                end
                            end
                            
                            task.wait(0.5)
                        end
                    end)
                end
                
                if AutoFly.Enabled then
                    task.spawn(function()
                        while flyRunning and AutoFly.Enabled do
                            if currentTarget and not hasActivatedFly then
                                if isFalling(currentTarget) and isAboveVoid(currentTarget) then
                                    fallCheckTimer = fallCheckTimer + 0.1
                                    
                                    if fallCheckTimer >= 0.5 then
                                        activateFly()
                                        fallCheckTimer = 0
                                    end
                                else
                                    fallCheckTimer = 0
                                end
                            else
                                fallCheckTimer = 0
                            end
                            
                            task.wait(0.1)
                        end
                    end)
                end
                
                AutoWhisper:Clean(playersService.PlayerAdded:Connect(function()
                    task.wait(0.5)
                    local newList = getTeammates(true)
                    if PlayerDropdown then
                        PlayerDropdown:Change(newList)
                        
                        if #newList > 0 then
                            if not PlayerDropdown.Value or PlayerDropdown.Value == "" or not table.find(newList, PlayerDropdown.Value) then
                                PlayerDropdown:SetValue(newList[1])
                            end
                        end
                    end
                end))
                
                AutoWhisper:Clean(playersService.PlayerRemoving:Connect(function(player)
                    task.wait(0.5)
                    local newList = getTeammates(true)
                    if PlayerDropdown then
                        PlayerDropdown:Change(newList)
                        
                        if #newList > 0 then
                            if not PlayerDropdown.Value or PlayerDropdown.Value == "" or not table.find(newList, PlayerDropdown.Value) then
                                PlayerDropdown:SetValue(newList[1])
                            end
                        end
                    end
                    
                    if currentTarget == player then
                        currentTarget = nil
                        currentMountedPlayer = nil
                    end
                end))
                
                AutoWhisper:Clean(lplr:GetAttributeChangedSignal('Team'):Connect(function()
                    task.wait(0.5)
                    local newList = getTeammates(true)
                    if PlayerDropdown then
                        PlayerDropdown:Change(newList)
                        
                        if #newList > 0 then
                            if not PlayerDropdown.Value or PlayerDropdown.Value == "" or not table.find(newList, PlayerDropdown.Value) then
                                PlayerDropdown:SetValue(newList[1])
                            end
                        end
                    end
                    currentTarget = nil
                    currentMountedPlayer = nil
                    hasActivatedFly = false
                end))
                
            else
                running = false
                healRunning = false
                flyRunning = false
                currentTarget = nil
                currentMountedPlayer = nil
                hasActivatedFly = false
                fallCheckTimer = 0
            end
        end,
        Tooltip = "Automatically mount bird to teammate, heal them, and save from void"
    })
    
    PlayerDropdown = AutoWhisper:CreateDropdown({
        Name = "Mount Target",
        List = {},
        Function = function(val)
            if val then
                local targetPlayer = playersService:FindFirstChild(val)
                if targetPlayer then
                    currentTarget = targetPlayer
                end
            end
        end,
        Tooltip = "Select teammate to mount owl to"
    })
    RefreshButton = AutoWhisper:CreateButton({
        Name = "Refresh Teammates",
        Tooltip = "Re-scans your team for the teammate dropdown above",
        Function = function()
            task.spawn(function()
                local newList = getTeammates(true)
                
                if PlayerDropdown then
                    pcall(function()
                        PlayerDropdown:Change(newList)
                        
                        if #newList > 0 then
                            if not PlayerDropdown.Value or PlayerDropdown.Value == "" or not table.find(newList, PlayerDropdown.Value) then
                                PlayerDropdown:SetValue(newList[1])
                            else
                                PlayerDropdown:SetValue(PlayerDropdown.Value)
                            end
                        end
                    end)
                end
                
                notif("Auto Whisper", string.format("Refreshed teammate list (%d teammates)", #newList), 2)
            end)
        end,
        Tooltip = "Manually refresh the teammate list"
    })
    
    LimitToItem = AutoWhisper:CreateToggle({
        Name = "Limit to Owl Orb",
        Default = true,
        Function = function(val)
        end,
        Tooltip = "Only mount owl when holding owl_orb item"
    })

    AutoFly = AutoWhisper:CreateToggle({
        Name = "Auto Fly",
        Default = true,
        Function = function(val)
            if AutoWhisper.Enabled then
                if val then
                    flyRunning = true
                    hasActivatedFly = false
                    fallCheckTimer = 0
                    
                    task.spawn(function()
                        while flyRunning and AutoFly.Enabled do
                            if currentTarget and not hasActivatedFly then
                                if isFalling(currentTarget) and isAboveVoid(currentTarget) then
                                    fallCheckTimer = fallCheckTimer + 0.1
                                    
                                    if fallCheckTimer >= 0.5 then
                                        activateFly()
                                        fallCheckTimer = 0
                                    end
                                else
                                    fallCheckTimer = 0
                                end
                            else
                                fallCheckTimer = 0
                            end
                            
                            task.wait(0.1)
                        end
                    end)
                else
                    flyRunning = false
                    hasActivatedFly = false
                    fallCheckTimer = 0
                end
            end
        end,
        Tooltip = "Automatically activate lift when target is falling into void"
    })
    
    AutoHeal = AutoWhisper:CreateToggle({
        Name = "Auto Heal",
        Default = true,
        Function = function(val)
            if AutoHealSlider and AutoHealSlider.Object then
                AutoHealSlider.Object.Visible = val
            end
            
            if AutoWhisper.Enabled then
                if val then
                    healRunning = true
                    task.spawn(function()
                        while healRunning and AutoHeal.Enabled do
                            if currentTarget then
                                local health, maxHealth = getPlayerHealth(currentTarget)
                                if not (health and maxHealth and maxHealth > 0) then task.wait(0.5) continue end
                                local healthPercent = (health / maxHealth) * 100
                                if healthPercent < AutoHealSlider.Value and healthPercent < 90 then
                                    healTarget()
                                    task.wait(8.5)
                                end
                            end
                            
                            task.wait(0.5)
                        end
                    end)
                else
                    healRunning = false
                end
            end
        end,
        Tooltip = "Automatically heal target when health drops below threshold"
    })
    
    AutoHealSlider = AutoWhisper:CreateSlider({
        Name = "Heal Threshold",
        Min = 1,
        Max = 100,
        Default = 50,
        Suffix = "%",
        Tooltip = "Heal when target's health drops below this percentage (stops at 90%)"
    })
end)

kitRun(function()
    local AutoZeno
    local Targets
    local TargetMode
    local Limit
    local AutoShockWave
    local ShockwaveRange
    local UseStrike
    local UseStorm
    local Range
    local Delay

    local function getAttackData()
    	if Limit.Enabled then
    		local tool = (store.hand.tool and store.hand.tool.Name:find('wizard_staff')) and store.hand.tool or nil
    		return tool, tool and getHotbar(tool) or nil, tool and (tonumber(tool.Name:sub(#tool.Name, #tool.Name)) or 1) or nil
    	end

    	for i, v in store.inventory.inventory.items do
    		if v.itemType:find('wizard_staff') then
    			switchItem(v, 0)
    			return v, i, tonumber(v.itemType:sub(#v.itemType, #v.itemType)) or 1
    		end
    	end

    	return
    end

    AutoZeno = vain.Categories.Kit:CreateModule({
    	Name = 'Auto Zeno',
    	Tooltip = 'Automates the Zeno kit lightning and shockwave',
    	Function = function(call)
    		if call then
    			repeat
    				if entitylib.isAlive then
    					local staff, __, level = getAttackData()

    					if staff then
    						local localPosition = entitylib.character.RootPart.Position
    						local ent = entitylib.EntityPosition({
    							Origin = localPosition,
    							Range = (Range.Value < 6 and AutoShockWave.Enabled and 7) or Range.Value,
    							Part = 'RootPart',
    							Players = Targets.Players.Enabled,
    							NPCs = Targets.NPCs.Enabled,
    							Sort = sortmethods[TargetMode.Value],
    						})

    						if ent then
    							if AutoShockWave.Enabled and level > 2 then
    								if
    									bedwars.AbilityController:canUseAbility('SHOCKWAVE')
    									and (localPosition - ent.RootPart.Position).Magnitude <= ShockwaveRange.Value
    								then
    									bedwars.AbilityController:useAbility('SHOCKWAVE', newproxy(true), {
    										target = CFrame.lookAt(localPosition, ent.RootPart.Position).LookVector,
    									})
    									task.wait(Delay.Value)
    								end
    							end

    							if UseStrike.Enabled and bedwars.AbilityController:canUseAbility('LIGHTNING_STRIKE') then
    								bedwars.AbilityController:useAbility('LIGHTNING_STRIKE', newproxy(true), {
    									target = ent.RootPart.Position + ((ent.Humanoid.MoveDirection or Vector3.zero) * (1 + lplr:GetNetworkPing())),
    								})
    								task.wait(Delay.Value)
    							end

    							if UseStorm.Enabled and level > 1 then
    								if bedwars.AbilityController:canUseAbility('LIGHTNING_STORM') then
    									bedwars.AbilityController:useAbility('LIGHTNING_STORM', newproxy(true), {
    										target = ent.RootPart.Position + ((ent.Humanoid.MoveDirection or Vector3.zero) * (1 + lplr:GetNetworkPing())),
    									})
    									task.wait(Delay.Value)
    								end
    							end
    						end
    					end
    				end
    				task.wait(0.1)
    			until not AutoZeno.Enabled
    		end
    	end,
    	Tooltip = 'Automatically uses zeno\'s staff'
    })

    Targets = AutoZeno:CreateTargets({
    	Tooltip = 'Configure which types of targets to include',
    	Players = true,
    	NPCs = false,
    })
    local methods = {'Damage', 'Distance'}
    for i in sortmethods do
    	if not table.find(methods, i) then
    		table.insert(methods, i)
    	end
    end
    TargetMode = AutoZeno:CreateDropdown({
    	Name = 'Target Mode',
    	Tooltip = 'Selects how targets are prioritized and selected',
    	List = methods,
    	Default = 'Distance',
    	ItemTooltips = {
    		Distance = 'Targets the closest enemy by stud distance',
    		Health = 'Targets the enemy with the lowest remaining health',
    		Angle = 'Targets the enemy closest to your look direction',
    		Cursor = 'Targets the enemy nearest to your mouse cursor',
    		Damage = 'Targets the enemy who most recently took damage',
    		Threat = 'Targets the enemy judged to be the greatest combat threat',
    		Kit = 'Prioritizes dangerous kit users (Hannah, Spirit Assassin, etc.)',
    	}
    })
    Limit = AutoZeno:CreateToggle({
    	Name = 'Limit to item',
    	Tooltip = 'Only activates when a required item is in your hand',
    	Default = true
    })
    UseStrike = AutoZeno:CreateToggle({
    	Name = 'Use Lightning Strike',
    	Tooltip = 'Uses the lightning strike ability automatically',
    	Default = true
    })
    UseStorm = AutoZeno:CreateToggle({Name = 'Use Lightning Storm', Tooltip = 'Automatically uses the Lightning Storm ability to hit multiple nearby enemies at once'})
    AutoShockWave = AutoZeno:CreateToggle({
    	Name = 'Auto Shockwave',
    	Tooltip = 'Enables or disables auto shockwave',
    	Function = function(call)
    		pcall(function()
    			ShockwaveRange.Object.Visible = call
    		end)
    	end,
    	Tooltip = 'Automatically uses the shockwave ability when a target is near',
    })
    ShockwaveRange = AutoZeno:CreateSlider({
    	Name = 'Shockwave Range',
    	Tooltip = 'Radius in studs of the shockwave effect',
    	Visible = false,
    	Darker = true,
    	Min = 1,
    	Max = 12,
    	Suffix = function(val)
    		return val > 1 and 'studs' or 'stud'
    	end,
    	Decimal = 5,
    	Default = 12
    })
    Range = AutoZeno:CreateSlider({
    	Name = 'Range',
    	Tooltip = 'Maximum distance in studs',
    	Min = 1,
    	Max = 60,
    	Default = 35,
    	Suffix = function(val)
    		return val > 1 and 'studs' or 'stud'
    	end,
    	Decimal = 5
    })
    Delay = AutoZeno:CreateSlider({
    	Name = 'Delay',
    	Tooltip = 'Seconds between consecutive actions',
    	Min = 0,
    	Max = 10,
    	Default = 0.5,
    	Decimal = 5,
    	Suffix = function(val)
    		return val > 1 and 'secs' or 'sec'
    	end
    })
end)

kitRun(function()
    local FishermanSpy
    local Teammates
    local GoldNotify
    local DiamondNotify
    local EmeraldNotify
    local Whitelist

    -- fishModel -> {word to announce, hex color for that word in the message}
    local SPECIAL_FISH = {
    	fish_gold = {'Gold', '#FFD75A'},
    	fish_diamond = {'Diamond', '#5AD7FF'},
    	fish_emerald = {'Emerald', '#5AFF7A'},
    }

    local function isWhitelisted(itemDisplay)
    	if #Whitelist.ListEnabled <= 0 then return true end
    	local lower = itemDisplay:lower()
    	for _, v in Whitelist.ListEnabled do
    		if v:lower() == lower then return true end
    	end
    	return false
    end

    FishermanSpy = vain.Categories.Kit:CreateModule({
    	Name = 'Fisherman Spy',
    	Tooltip = 'Reveals targets caught by the Fisherman kit',
    	Function = function(call)
    		if call then
    			FishermanSpy:Clean(bedwars.Client:Get('FishCaught'):Connect(function(data)
    				if data.dropData and data.dropData.drops and data.catchingPlayer then
    					local isEnemy = not Teammates.Enabled or lplr.Team ~= data.catchingPlayer.Team

    					local text = {}
    					for _, v in data.dropData.drops do
    						local itemDisplay = bedwars.ItemMeta[v.itemType] and bedwars.ItemMeta[v.itemType].displayName or v.itemType
    						if not isWhitelisted(itemDisplay) then continue end
    						-- FishCaught's own amount field reports one less than what's
    						-- actually received (4 diamonds caught shows as 3), so +1 here
    						-- to match reality.
    						local amount = v.amount + 1
    						-- These are resource names (Iron, Gold, TNT, ...), not countable
    						-- objects -- BedWars itself never pluralizes them ("10 Iron", not
    						-- "10 Irons"), so use the display name as-is with no added 's'.
    						table.insert(text, `{amount} {itemDisplay}`)
    					end

    					if #text > 0 and isEnemy then
    						notif('Fisherman Spy', `{data.catchingPlayer.Name} caught {table.concat(text, ', ')}`, 8, 'info')
    					end

    					local special = SPECIAL_FISH[data.dropData.fishModel]
    					local specialToggle = data.dropData.fishModel == 'fish_gold' and GoldNotify
    						or data.dropData.fishModel == 'fish_diamond' and DiamondNotify
    						or data.dropData.fishModel == 'fish_emerald' and EmeraldNotify
    					if special and specialToggle and specialToggle.Enabled and isEnemy then
    						local word, hex = special[1], special[2]
    						notif('Fisherman Spy', `{data.catchingPlayer.Name} has caught a <font color='{hex}'>{word}</font> fish`, 8, 'info')
    					end
    				end
    			end))
    		end
    	end
    })

    Teammates = FishermanSpy:CreateToggle({
    	Name = 'Ignore teammate',
    	Tooltip = 'Ignores players on your own team',
    	Default = true
    })
    GoldNotify = FishermanSpy:CreateToggle({
    	Name = 'Notify on Gold',
    	Tooltip = 'Sends a dedicated notification whenever anyone catches a Gold Fish',
    	Default = false
    })
    DiamondNotify = FishermanSpy:CreateToggle({
    	Name = 'Notify on Diamond',
    	Tooltip = 'Sends a dedicated notification whenever anyone catches a Diamond Fish',
    	Default = false
    })
    EmeraldNotify = FishermanSpy:CreateToggle({
    	Name = 'Notify on Emerald',
    	Tooltip = 'Sends a dedicated notification whenever anyone catches an Emerald Fish',
    	Default = false
    })
    Whitelist = FishermanSpy:CreateTextList({
    	Name = 'Loot Whitelist',
    	Tooltip = 'Only shows catches of these items in the notification (leave empty to show all loot)',
    	Placeholder = 'item name (e.g. Diamond)',
    })
end)

kitRun(function()
    local old

    vain.Categories.Kit:CreateModule({
    	Name = 'Infinite Krystal',
    	Tooltip = 'Gives you max momentum forever',
    	Function = function(call)
    		if call then
    			old = bedwars.GlacialSkaterController.updateMomentum
    			bedwars.GlacialSkaterController.updateMomentum = function(self, ...)
    				self.momentum = 9e9
    				self.lastMomentumReport = 9e9
    				return old(self, ...)
    			end
    		else
    			bedwars.GlacialSkaterController.updateMomentum = old
    		end
    	end
    })
end)

kitRun(function()
    local SigridExploit
    local Kit, Mount = 'elk_master', bedwars.Client:Get('ElkKitMounted')

    SigridExploit = vain.Categories.Kit:CreateModule({
    	Name = 'Infinite Sigrid',
    	Tooltip = 'Lets you ride in the elk forever',
    	Function = function(call)
    		if call then
    			repeat
    				if entitylib.isAlive then
    					if store.equippedKit == Kit then
    						Mount:SendToServer()
    					end
    				end
    				task.wait()
    			until not SigridExploit.Enabled
    		end
    	end
    })
end)

--[[
    Legit
]]

kitRun(function()
    local AutoVanessa
    local oldGetChargeTime
    local lastChargeTime = 0
    
    AutoVanessa = vain.Categories.Kit:CreateModule({
        Name = 'Auto Vanessa',
        Tooltip = 'Automates the Vanessa kit ability',
        Function = function(callback)
            if callback then
                task.spawn(function()
                    repeat task.wait() until bedwars.TripleShotProjectileController
                    
                    if bedwars.TripleShotProjectileController then
                        oldGetChargeTime = bedwars.TripleShotProjectileController.getChargeTime
                        
                        bedwars.TripleShotProjectileController.getChargeTime = function(self)
                            return 0
                        end
                        
                        bedwars.TripleShotProjectileController.overchargeStartTime = tick()
                    end
                end)
            else
                if oldGetChargeTime and bedwars.TripleShotProjectileController then
                    bedwars.TripleShotProjectileController.getChargeTime = oldGetChargeTime
                end
                lastChargeTime = 0
            end
        end,
        Tooltip = 'Auto charges Vanessa triple shot'
    })
end)

kitRun(function()
	local AutoJack
	local InstantCharge
	local ChargeSpeed
	local TorchAimbot
	local TorchTarget
	local TorchRange
	local torchHookRemove
	local chargeHookRemove
	local chargeTimeConn
	local InfiniteOil
	local lastThrow = 0
	local launchThrottleConn
	local ThrowCooldown
	local AutoIgnite
	local lastIgnite = 0
	local igniteThrowAt = {}
	-- Jack was reworked into a charge-to-throw kit: holding the Oil Spitter builds a
	-- charge (full at maxStrengthChargeSec = 3s) that decides the oil blob's size /
	-- splash-blob count. Two things need to reflect the boosted charge:
	--   1. The throw itself. The charge that reaches the server is the launch payload's
	--      drawDurationSec, taken straight from the launch table's drawDurationSeconds,
	--      so chargeBoost overrides that value on the ProjectileLaunchHook at throw time
	--      (like the torch aim above) -- this guarantees a full throw even on a fast tap.
	--   2. The on-screen charge bar during the hold. The bar is driven by the game's own
	--      per-frame loop: v54 = drawDurationSeconds / maxChargeTime, and the top bar /
	--      velocityMultiplier follow v54. Writing drawDurationSeconds ourselves races
	--      that loop and doesn't stick; instead we shrink maxChargeTime (via the
	--      ProjectileMaxChargeTimeModifierCheck sync event) while the oil spitter is
	--      charging, so the game's OWN loop fills the bar faster / instantly. We also
	--      backdate startChargingTIme in the hold loop so the Oil cost bar keeps pace.
	local MAX_CHARGE = 3
	-- Oil Spitter minStrengthScalar: the throw-strength floor at zero charge. Used to
	-- rescale the launch velocity so a forced-full charge also throws at full range.
	local MIN_STRENGTH = 0.7692307692307692

	-- Force the oil charge on the outgoing throw. jack_oil_projectile only -- the hook
	-- fires for every projectile, so we gate on the projectile name (no held-item
	-- check needed). Instant Charge sends a full charge; Charge Speed multiplies the
	-- charge the player actually built. The launch velocity is rescaled to match the
	-- forced charge so the blob is both max-size and thrown at the matching strength.
	local function chargeBoost(nextLaunch, ...)
		local res = nextLaunch(...)
		if not (AutoJack and AutoJack.Enabled) then return res end
		if type(res) ~= 'table' then return res end
		local projmeta = select(2, ...)
		if not projmeta or projmeta.projectile ~= 'jack_oil_projectile' then return res end

		local instant = InstantCharge and InstantCharge.Enabled
		local speed = (ChargeSpeed and ChargeSpeed.Value) or 1
		local baseDraw = res.drawDurationSeconds or 0
		local newDraw = baseDraw
		if instant then
			newDraw = MAX_CHARGE
		elseif speed > 1 then
			newDraw = math.min(MAX_CHARGE, baseDraw * speed)
		end
		if newDraw ~= baseDraw then
			res.drawDurationSeconds = newDraw
			local iv = res.initialVelocity
			if iv and iv.Magnitude > 0 then
				local ok, meta = pcall(function() return projmeta:getProjectileMeta() end)
				local baseSpeed = (ok and meta and meta.launchVelocity) or 80
				local v54 = math.min(1, newDraw / MAX_CHARGE)
				res.initialVelocity = iv.Unit * baseSpeed * (v54 + (1 - v54) * MIN_STRENGTH)
			end
		end
		return res
	end

	-- ClientSyncEvents lives as an upvalue of ProjectileSourceController.beginHolding
	-- (inherited by OilSpitterController). Scan its upvalues for the table that owns the
	-- charge-time modifier rather than hard-coding an index, so a reorder can't break us.
	local function getClientSyncEvents()
		local fn = bedwars.OilSpitterController and bedwars.OilSpitterController.beginHolding
		if type(fn) ~= 'function' then return nil end
		for i = 1, 24 do
			local ok, up = pcall(debug.getupvalue, fn, i)
			if ok and type(up) == 'table' and up.ProjectileMaxChargeTimeModifierCheck then
				return up
			end
		end
		return nil
	end

	-- Shrink the oil spitter's max charge time so the game's own hold loop fills the
	-- charge bar (and velocityMultiplier / throw strength) faster or instantly. The check
	-- fires once per hold with only the charge seconds, so we scope it to oil by only
	-- acting while OilSpitterController is charging -- other projectiles are untouched.
	local function installChargeTimeHook()
		if chargeTimeConn then return end
		local events = getClientSyncEvents()
		if not events then return end
		-- Throw throttle: the spitter has no built-in re-fire cooldown, so drop any oil
		-- launch that comes sooner than the Throw Cooldown slider after the last one,
		-- capping how fast you can re-throw. Cancelling StartLaunchProjectile is the same
		-- drop the game's own oil<10 gate uses, so it is clean.
		if not launchThrottleConn then
			launchThrottleConn = events.StartLaunchProjectile:connect(function(event)
				if not (AutoJack and AutoJack.Enabled) then return end
				if event.projectileType ~= 'jack_oil_projectile' then return end
				local cd = (ThrowCooldown and ThrowCooldown.Value) or 0.05
				local now = os.clock()
				if now - lastThrow < cd then
					event:setCancelled(true)
				else
					lastThrow = now
				end
			end)
		end
		chargeTimeConn = events.ProjectileMaxChargeTimeModifierCheck:connect(function(p)
			if not (AutoJack and AutoJack.Enabled) then return end
			local oil = bedwars.OilSpitterController
			if not (oil and oil.isCharging) then return end
			if not (p and type(p.maxChargeTime) == 'number') then return end
			if InstantCharge and InstantCharge.Enabled then
				p.maxChargeTime = 0.01
			else
				local speed = (ChargeSpeed and ChargeSpeed.Value) or 1
				if speed > 1 then
					p.maxChargeTime = p.maxChargeTime / speed
				end
			end
		end)
	end

	local function removeChargeTimeHook()
		if chargeTimeConn then
			pcall(function() chargeTimeConn:Destroy() end)
			chargeTimeConn = nil
		end
		if launchThrottleConn then
			pcall(function() launchThrottleConn:Destroy() end)
			launchThrottleConn = nil
		end
	end

	-- Torch (Fire Match) silent aim. The Fire Match is a normal projectile thrown
	-- through ProjectileController, so hooking calculateImportantLaunchValues and
	-- gating on projmeta.projectile == 'fire_match' scopes this to the torch alone --
	-- the hook only fires when the torch itself is thrown, so no held-item check is
	-- needed. Targets come from OilBlobController.spillMap (seed -> oil part); each
	-- part's Size.X tracks the puddle radius, so Biggest/Smallest sort by that.
	local function pickOilBlob(originPos)
		local controller = bedwars.OilBlobController
		if not controller or not controller.spillMap then return nil end
		local sort = TorchTarget and TorchTarget.Value or 'Nearest'
		local range = TorchRange and TorchRange.Value or 300
		-- Cursor mode ranks by nearness to the mouse on screen, so it needs the
		-- camera and the current mouse location up front.
		local camera = workspace.CurrentCamera
		local mousePos = (sort == 'Cursor' and camera and inputService) and inputService:GetMouseLocation() or nil
		local best, bestScore
		for _, part in pairs(controller.spillMap) do
			if typeof(part) == 'Instance' and part.Parent then
				local dist = (part.Position - originPos).Magnitude
				if dist <= range then
					local score
					if sort == 'Cursor' then
						if mousePos then
							local screenPos, onScreen = camera:WorldToViewportPoint(part.Position)
							if onScreen then
								score = -(Vector2.new(screenPos.X, screenPos.Y) - mousePos).Magnitude
							end
						end
					elseif sort == 'Farthest' then
						score = dist
					elseif sort == 'Biggest' then
						score = part.Size.X
					elseif sort == 'Smallest' then
						score = -part.Size.X
					else -- Nearest
						score = -dist
					end
					-- score stays nil for a Cursor blob that is off screen: skip it.
					if score and (not bestScore or score > bestScore) then
						bestScore, best = score, part
					end
				end
			end
		end
		return best
	end

	-- An ignited oil blob gets Burn particle emitters (Rate 45) parented in by the
	-- OilFlame handler, so treat a blob that has one as already lit.
	local function isBurning(part)
		for _, d in ipairs(part:GetDescendants()) do
			if d:IsA('ParticleEmitter') and d.Rate == 45 then
				return true
			end
		end
		return false
	end

	-- Throw a Fire Match at a world point (fire_match: velocity 80, gravity 35), the
	-- same resource-throwable launch path as the other projectiles. Needs Fire Match ammo.
	local function fireMatchAt(position)
		local item = getItem('fire_match')
		if not (item and item.tool) then return end
		if not (entitylib.character and entitylib.character.RootPart) then return end
		local localPosition = entitylib.character.RootPart.Position
		local meta = bedwars.ProjectileMeta.fire_match
		if not meta then return end
		local calc = prediction.SolveTrajectory(localPosition, meta.launchVelocity, meta.gravitationalAcceleration, position, Vector3.zero, workspace.Gravity, 0, 0)
		if calc then position = calc end
		local shootPosition = (CFrame.new(localPosition, position) * CFrame.new(Vector3.new(-bedwars.BowConstantsTable.RelX, -bedwars.BowConstantsTable.RelY, -bedwars.BowConstantsTable.RelZ))).Position
		bedwars.Client:Get(remotes.FireProjectile):CallServerAsync(
			item.tool,
			'fire_match',
			'fire_match',
			shootPosition,
			localPosition,
			CFrame.lookAt(localPosition, position).LookVector * meta.launchVelocity,
			httpService:GenerateGUID(true),
			{ drawDurationSeconds = 0.25, shotId = httpService:GenerateGUID(false) },
			workspace:GetServerTimeNow() - 0.045
		)
	end

	local function torchAim(nextLaunch, ...)
		if not (TorchAimbot and TorchAimbot.Enabled) then
			return nextLaunch(...)
		end
		local self, projmeta, worldmeta, origin, shootpos = ...
		if not projmeta or projmeta.projectile ~= 'fire_match' then
			return nextLaunch(...)
		end
		local pos = shootpos or (self.getLaunchPosition and self:getLaunchPosition(origin))
		if not pos then return nextLaunch(...) end
		local offsetpos = pos + (projmeta.fromPositionOffset or Vector3.zero)

		local blob = pickOilBlob(offsetpos)
		if not blob then return nextLaunch(...) end

		local meta = projmeta:getProjectileMeta()
		local projSpeed = meta.launchVelocity or 80
		local gravity = (meta.gravitationalAcceleration or 35) * (projmeta.gravityMultiplier or 1)
		local lifetime = worldmeta and (meta.predictionLifetimeSec or meta.lifetimeSec or 3) or (meta.lifetimeSec or 3)

		-- Static ground target: zero target velocity and hipHeight/jumping 0 (mirrors
		-- the telepearl static-point solve used by MouseTPs).
		local calc = prediction.SolveTrajectory(offsetpos, projSpeed, gravity, blob.Position, Vector3.zero, workspace.Gravity, 0, 0)
		if not calc then return nextLaunch(...) end

		local aimDir = CFrame.new(offsetpos, calc).LookVector
		return {
			initialVelocity = aimDir * projSpeed,
			positionFrom = offsetpos,
			deltaT = lifetime,
			gravitationalAcceleration = gravity,
			-- fire_match caps its charge at 0.25s; 1 is well past that, so the server
			-- reads a full-strength throw consistent with the overridden velocity.
			drawDurationSeconds = 1
		}
	end

	AutoJack = vain.Categories.Kit:CreateModule({
		Name = 'Auto Jack',
		Tooltip = 'Charge assist for the Jack (Oil Spitter) kit: instantly full-charge every oil blob, or just build the charge faster.',
		Function = function(callback)
			if not callback then
				if torchHookRemove then
					torchHookRemove()
					torchHookRemove = nil
				end
				if chargeHookRemove then
					chargeHookRemove()
					chargeHookRemove = nil
				end
				removeChargeTimeHook()
				return
			end
			if bedwars.ProjectileLaunchHook then
				if not torchHookRemove then
					torchHookRemove = bedwars.ProjectileLaunchHook:Add('JackTorchAim', 5, torchAim)
				end
				if not chargeHookRemove then
					chargeHookRemove = bedwars.ProjectileLaunchHook:Add('JackCharge', 6, chargeBoost)
				end
			end
			task.spawn(function()
				repeat task.wait() until bedwars.OilSpitterController
				-- The max-charge-time hook drives the on-screen charge bar; install it
				-- once the controller (and its inherited beginHolding upvalue) exists.
				installChargeTimeHook()
				while AutoJack.Enabled do
					local dt = task.wait()
					local controller = bedwars.OilSpitterController
					if controller and controller.isCharging then
						local instant = InstantCharge.Enabled
						local speed = ChargeSpeed.Value
						-- Keep the Oil cost bar (getChargeDuration, driven by
						-- startChargingTIme) in step with the boosted charge.
						if instant then
							controller.startChargingTIme = workspace:GetServerTimeNow() - MAX_CHARGE
						elseif speed > 1 then
							controller.startChargingTIme = controller.startChargingTIme - (speed - 1) * dt
						end
					end
					-- Infinite Oil: the game blocks aiming/throwing the spitter when your OilAmount
					-- attribute is under 10 (its client StartLaunchProjectile / BeginProjectileTargeting
					-- gates). Topping the local attribute up keeps those gates open so you can aim and
					-- throw full blobs at empty, and the oil bar reads full. The server still owns the real oil.
					if InfiniteOil and InfiniteOil.Enabled and store.hand and store.hand.tool and store.hand.tool.Name == 'oil_spitter' then
						lplr:SetAttribute('OilAmount', 100)
					end
					-- Auto Ignite: lob a Fire Match at any oil blob that is not yet burning so
					-- thrown oil lights itself. Ignition is server-authoritative (only a fire
					-- source lights oil), so this just automates the torch throw and needs Fire
					-- Match ammo. Per-blob and global cooldowns keep it from wasting matches.
					if AutoIgnite and AutoIgnite.Enabled and os.clock() - lastIgnite >= 0.25 then
						local ctrl = bedwars.OilBlobController
						local root = entitylib.character and entitylib.character.RootPart
						if ctrl and ctrl.spillMap and root then
							local best, bestDist, bestSeed
							for seed, part in pairs(ctrl.spillMap) do
								if typeof(part) == 'Instance' and part.Parent and not isBurning(part) then
									local prev = igniteThrowAt[seed]
									if not (prev and os.clock() - prev < 1) then
										local d = (part.Position - root.Position).Magnitude
										if not bestDist or d < bestDist then
											bestDist, best, bestSeed = d, part, seed
										end
									end
								end
							end
							if best then
								fireMatchAt(best.Position)
								igniteThrowAt[bestSeed] = os.clock()
								lastIgnite = os.clock()
							end
						end
					end
				end
			end)
		end
	})
	InstantCharge = AutoJack:CreateToggle({
		Name = 'Instant Charge',
		Tooltip = 'Fills the oil charge to maximum immediately, so every blob is thrown full-size with no hold time',
		Default = false
	})
	ChargeSpeed = AutoJack:CreateSlider({
		Name = 'Charge Speed',
		Tooltip = 'How many times faster the oil charge builds (ignored while Instant Charge is on)',
		Min = 1,
		Max = 10,
		Default = 2,
		Decimal = 10,
		Suffix = 'x'
	})
	ThrowCooldown = AutoJack:CreateSlider({
		Name = 'Throw Cooldown',
		Tooltip = 'Minimum seconds between oil throws; a release that comes sooner than this is dropped, capping how fast you can re-throw',
		Min = 0.01,
		Max = 1,
		Default = 0.05,
		Decimal = 100,
		Suffix = 's'
	})
	InfiniteOil = AutoJack:CreateToggle({
		Name = 'Infinite Oil',
		Tooltip = 'Keeps your oil topped up on the client so you can aim and throw full-size blobs even at empty (the bar reads full). The server still decides whether an empty throw actually lands',
		Default = false
	})
	TorchAimbot = AutoJack:CreateToggle({
		Name = 'Torch Aimbot',
		Tooltip = 'While the Fire Match (torch) is thrown, silently aims it at an oil blob so it lands on the oil and ignites it every time, like Projectile Aimbot but scoped to the torch and targeting oil blobs',
		Default = false
	})
	TorchTarget = AutoJack:CreateDropdown({
		Name = 'Torch Target',
		List = {'Nearest', 'Farthest', 'Biggest', 'Smallest', 'Cursor'},
		Default = 'Nearest',
		Tooltip = 'Which oil blob the torch aims at: nearest/farthest to you, the biggest/smallest puddle, or the one closest to your cursor'
	})
	TorchRange = AutoJack:CreateSlider({
		Name = 'Torch Range',
		Tooltip = 'Only aim the torch at oil blobs within this many studs',
		Min = 10,
		Max = 2000,
		Default = 500,
		Decimal = 1,
		Suffix = ' studs'
	})
	AutoIgnite = AutoJack:CreateToggle({
		Name = 'Auto Ignite',
		Tooltip = 'Automatically lobs a Fire Match at your oil blobs to set them alight, so you do not throw the torch yourself (needs Fire Match ammo)',
		Default = false
	})
end)

kitRun(function()
    local PromptUnlock

    local savedPromptStates = {}

    PromptUnlock = vain.Categories.Kit:CreateModule({
        Name = 'Prompt Unlock',
        Tooltip = 'enables all proximity prompts in the game',
        Function = function(callback)
            if callback then
                savedPromptStates = {}
                for _, v in workspace:GetDescendants() do
                    if v:IsA('ProximityPrompt') then
                        savedPromptStates[v] = v.Enabled
                        v.Enabled = true
                    end
                end
                PromptUnlock:Clean(workspace.DescendantAdded:Connect(function(v)
                    if not PromptUnlock.Enabled then return end
                    if v:IsA('ProximityPrompt') then
                        savedPromptStates[v] = v.Enabled
                        v.Enabled = true
                    end
                end))
            else
                for prompt, state in savedPromptStates do
                    if prompt and prompt.Parent then
                        prompt.Enabled = state
                    end
                end
                savedPromptStates = {}
            end
        end
    })
end)

kitRun(function()
    local Fisherman
    local AutoMinigameToggle
    local CompleteDelaySlider
    local PullAnimationToggle
    local MinigameAnimationToggle
    local BlacklistOption
    local Blacklist
    local ESPToggle
	local AutoCastDelay
	local AutoCast
    local ESPNotifyToggle
    local Players    = playersService
    local RunService = runService
    local lplr       = Players.LocalPlayer
	local RandomizeToggle
    local RandomRange
	local waitTime
    local fishNames = {
        fish_iron    = "Iron Fish",
        fish_diamond = "Diamond Fish",
        fish_gold    = "Gold Fish",
        fish_special = "Special Fish",
        fish_emerald = "Emerald Fish",
    }

    local function buildMessage(fishModel, drops)
        local fishName = fishNames[fishModel] or fishModel

        if fishModel == "fish_special" then
            if drops and drops[1] then
                return "You caught a " .. fishName .. "! You will receive a " .. tostring(drops[1].itemType)
            else
                return "You caught a " .. fishName .. "! (special item incoming)"
            end
        end

        if drops and drops[1] then
            local drop = drops[1]
            return "You caught a " .. fishName .. "! Receiving " ..
                   tostring(drop.amount) .. "x " .. tostring(drop.itemType)
        end

        return "You caught a " .. fishName .. "!"
    end

    local notifQueue = {}

    local function safeNotif(title, message, duration)
        table.insert(notifQueue, { title = title, message = message, duration = duration or 5 })
    end

    local heartbeatConn = nil

    local autoMinigameActive    = false
    local pullAnimationTrack    = nil
    local successAnimationTrack = nil
    local espOld                = nil

	local function getBait()
		for _, v in workspace:GetChildren() do
			if v.Name == "fisherman_bobber" and v:GetAttribute("ProjectileShooter") == lplr.UserId then
				return v
			end
		end

		return
	end

    local function stopAllAnimations()
        if pullAnimationTrack then
            pcall(function() pullAnimationTrack:Stop() end)
            pullAnimationTrack = nil
        end
        if successAnimationTrack then
            pcall(function() successAnimationTrack:Stop() end)
            successAnimationTrack = nil
        end
    end

    local function setupESP()
        if not bedwars or not bedwars.FishingMinigameController then
            warn("[AutoFisher] FishingMinigameController not found")
            return
        end
        if espOld then return end 
        espOld = bedwars.FishingMinigameController.startMinigame

        bedwars.FishingMinigameController.startMinigame = function(self, dropData, result)
            if ESPToggle.Enabled and ESPNotifyToggle.Enabled and dropData and dropData.fishModel then
                safeNotif("Fisherman ESP", buildMessage(dropData.fishModel, dropData.drops), 8)
            end
            return espOld(self, dropData, result)
        end

        Fisherman:Clean(function()
            if espOld then
                bedwars.FishingMinigameController.startMinigame = espOld
                espOld = nil
            end
        end)
    end

    local function cleanupESP()
        if espOld then
            bedwars.FishingMinigameController.startMinigame = espOld
            espOld = nil
        end
    end

    local function setupAutoMinigame()
        if not bedwars or not bedwars.FishingMinigameController then
            warn("[AutoFisher] FishingMinigameController not found")
            return
        end

        local old = bedwars.FishingMinigameController.startMinigame

        bedwars.FishingMinigameController.startMinigame = function(self, dropData, result)
            if not AutoMinigameToggle.Enabled then
                return old(self, dropData, result)
            end

            if BlacklistOption.Enabled and dropData and dropData.fishModel then
                if table.find(Blacklist.ListEnabled, dropData.fishModel) then
                    local hum = lplr.Character and lplr.Character:FindFirstChildOfClass("Humanoid")
                    if hum and hum:GetState() ~= Enum.HumanoidStateType.Jumping then
                        hum:ChangeState(Enum.HumanoidStateType.Jumping)
                    end
                    return old(self, dropData, result)
                end
            end

            autoMinigameActive = true
            stopAllAnimations()

            local waitTime = 0
            if RandomizeToggle and RandomizeToggle.Enabled then
                local min = RandomRange.ValueMin
                local max = RandomRange.ValueMax
                waitTime = min + (max - min) * math.random()
            else
                waitTime = CompleteDelaySlider.Value
            end

            task.spawn(function()
                if PullAnimationToggle.Enabled and waitTime > 0 then
                    local ok, track = pcall(function()
                        return bedwars.GameAnimationUtil:playAnimation(
                            lplr, bedwars.AnimationType.FISHING_ROD_PULLING
                        )
                    end)
                    if ok and track then pullAnimationTrack = track end
                end

                if waitTime > 0 then
                    task.wait(waitTime)
                end

                if pullAnimationTrack then
                    pcall(function() pullAnimationTrack:Stop() end)
                    pullAnimationTrack = nil
                end

                if MinigameAnimationToggle.Enabled then
                    local ok, track = pcall(function()
                        return bedwars.GameAnimationUtil:playAnimation(
                            lplr, bedwars.AnimationType.FISHING_ROD_CATCH_SUCCESS
                        )
                    end)
                    if ok and track then successAnimationTrack = track end
                end

                if result then
                    pcall(function() result({ win = true }) end)
                end

                task.wait(0.5)

                if successAnimationTrack then
                    pcall(function() successAnimationTrack:Stop() end)
                    successAnimationTrack = nil
                end

                autoMinigameActive = false
            end)
        end

        Fisherman:Clean(function()
            bedwars.FishingMinigameController.startMinigame = old
            stopAllAnimations()
        end)
    end

	local function setupAutoCast()
		task.spawn(function()
			repeat
				if entitylib.isAlive and AutoCast.Enabled and (store.hand.tool and store.hand.tool.Name == 'fishing_rod') then
					local position = workspace.CurrentCamera.ViewportSize / 2
					local ray = cloneref(lplr:GetMouse()).UnitRay

					if not getBait() and not workspace:Raycast(entitylib.character.Head.Position + (ray.Direction * 6), Vector3.new(0, -20, 0)) then
						task.wait(AutoCastDelay:GetRandomValue())

						for _, v in {true, false} do
							VirtualInputManager:SendMouseButtonEvent(position.X, position.Y, 0, v, game, 1)
							task.wait()
						end
						task.wait(0.5)
					end
				end
				task.wait(0.1)
			until not Fisherman.Enabled
		end)
	end

    Fisherman = vain.Categories.Kit:CreateModule({
        Name    = "Auto Fisher",
        Tooltip = "Auto minigame, loot ESP, blacklist, AutoCasting, and spy for the Fisherman kit",
        Function = function(callback)
            if callback then
                if ESPToggle.Enabled           then setupESP()          end
                if AutoMinigameToggle.Enabled  then setupAutoMinigame() end
                setupAutoCast()

                heartbeatConn = RunService.Heartbeat:Connect(function()
                    if #notifQueue == 0 then return end
                    local entry = table.remove(notifQueue, 1)
                    pcall(notif, entry.title, entry.message, entry.duration)
                end)
                Fisherman:Clean(heartbeatConn)

            else
                autoMinigameActive = false
                stopAllAnimations()
                cleanupESP()
                notifQueue = {} 
            end
        end
    })

    AutoMinigameToggle = Fisherman:CreateToggle({
        Name    = "Auto Minigame",
        Default = false,
        Tooltip = "Automatically complete the fishing minigame",
        Function = function(cv)
            if CompleteDelaySlider and CompleteDelaySlider.Object then 
                CompleteDelaySlider.Object.Visible = cv and not (RandomizeToggle and RandomizeToggle.Enabled) 
            end
            if PullAnimationToggle     and PullAnimationToggle.Object     then PullAnimationToggle.Object.Visible     = cv end
            if MinigameAnimationToggle and MinigameAnimationToggle.Object then MinigameAnimationToggle.Object.Visible = cv end
            if RandomizeToggle and RandomizeToggle.Object then RandomizeToggle.Object.Visible = cv end
            if RandomRange and RandomRange.Object then RandomRange.Object.Visible = cv and RandomizeToggle.Enabled end
            if Fisherman.Enabled and cv then setupAutoMinigame() end
        end
    })

    CompleteDelaySlider = Fisherman:CreateSlider({
        Name    = "Complete Delay",
        Min     = 0,
        Max     = 5,
        Default = 1,
        Decimal = 10,
        Suffix  = "s",
        Visible = false,
        Tooltip = "Delay before auto-completing (looks more legit)"
    })

    RandomizeToggle = Fisherman:CreateToggle({
        Name    = "Randomize Timing",
        Default = false,
        Tooltip = "Use random delay between min and max instead of fixed delay",
        Function = function(cv)
            if RandomRange and RandomRange.Object then RandomRange.Object.Visible = cv end
            if CompleteDelaySlider and CompleteDelaySlider.Object then CompleteDelaySlider.Object.Visible = not cv end
        end
    })

    RandomRange = Fisherman:CreateTwoSlider({
        Name    = "Random Delay Range",
        Min     = 0.1,
        Max     = 5,
        DefaultMin = 0.5,
        DefaultMax = 2,
        Decimal = 10,
        Visible = false,
        Tooltip = "Minimum and maximum delay for random timing"
    })

    PullAnimationToggle = Fisherman:CreateToggle({
        Name    = "Pull Animation",
        Default = true,
        Visible = false,
        Tooltip = "Play rod-pulling animation during delay (requires delay > 0)"
    })

    MinigameAnimationToggle = Fisherman:CreateToggle({
        Name    = "Success Animation",
        Default = true,
        Visible = false,
        Tooltip = "Play catch-success animation on completion"
    })

    BlacklistOption = Fisherman:CreateToggle({
        Name    = "Blacklist",
        Default = false,
        Tooltip = "Auto-jump and skip auto-complete for blacklisted fish",
        Function = function(cv)
            if Blacklist and Blacklist.Object then Blacklist.Object.Visible = cv end
        end
    })

    Blacklist = Fisherman:CreateTextList({
        Name    = "Blacklist Fish",
        Tooltip = "Fish types to skip auto-catching (one per line)",
        Default = { "fish_iron" }
    })

	AutoCast = Fisherman:CreateToggle({
		Name 	= "AutoCast",
		Tooltip = 'Automatically casts the ability when available',
		Default = false,
		Function = function(callback)
			if callback then
				if AutoCastDelay and AutoCastDelay.Object then AutoCastDelay.Object.Visible = callback end
				if AutoCast.Enabled and callback then setupAutoCast() end
			end
		end
	})

	AutoCastDelay = Fisherman:CreateTwoSlider({
		Name 	= "Cast Delay",
		Min 	= 0,
		Max 	= 5,
		Decimal = 5,
		DefaultMin = 0.3,
		DefaultMax = 1.2,
		Darker 	= true,
		Visible = AutoCast.Enabled
	})	

    ESPToggle = Fisherman:CreateToggle({
        Name    = "Fisherman ESP",
        Default = false,
        Tooltip = "Shows what fish you are catching and what loot you will receive",
        Function = function(cv)
            if ESPNotifyToggle and ESPNotifyToggle.Object then ESPNotifyToggle.Object.Visible = cv end
            if Fisherman.Enabled then
                if cv then setupESP() else cleanupESP() end
            end
        end
    })

    ESPNotifyToggle = Fisherman:CreateToggle({
        Name    = "Notify Loot",
        Default = true,
        Visible = false,
        Tooltip = "Show a notification with the fish name and loot details"
    })
end)

kitRun(function()
    local StarCollector
    local CollectionToggle
    local Animation
    local RangeSlider
    local ESPToggle
    local ESPNotify
    local ESPBackground
    local ESPColor
    local SwordCheck
    local Folder = Instance.new('Folder')
    Folder.Parent = vain.gui
    local Reference = {}
    local starCooldowns = {}
    local COOLDOWN_TIME = 0.5
    local lastNotification = 0
    local spawnQueue = {}
    local notificationCooldown = 1
    local collectionRunning = false

    local function sendNotification(count)
        notif("Star ESP", string.format("%d stars spawned", count), 3)
    end

    local function processSpawnQueue()
        if #spawnQueue > 0 then
            local currentTime = tick()
            if currentTime - lastNotification >= notificationCooldown then
                sendNotification(#spawnQueue)
                lastNotification = currentTime
                spawnQueue = {}
            else
                task.delay(notificationCooldown - (currentTime - lastNotification), function()
                    if #spawnQueue > 0 then
                        sendNotification(#spawnQueue)
                        spawnQueue = {}
                    end
                end)
            end
        end
    end

    local function getProperImage(v)
        local parent = v.Parent
        if parent and parent:IsA("Model") then
            local modelName = parent.Name
            if modelName == "CritStar" then
                return bedwars.getIcon({itemType = 'crit_star'}, true)
            elseif modelName == "VitalityStar" then
                return bedwars.getIcon({itemType = 'vitality_star'}, true)
            elseif modelName:find("vitality") or modelName:lower():find("vitality") then
                return bedwars.getIcon({itemType = 'vitality_star'}, true)
            elseif modelName:find("crit") or modelName:lower():find("crit") then
                return bedwars.getIcon({itemType = 'crit_star'}, true)
            end
        end
        return bedwars.getIcon({itemType = 'crit_star'}, true)
    end

    local function Added(v)
        if Reference[v] then return end
        local _bpUserId = v:GetAttribute('PlacedByUserId')
        if _bpUserId then
            local _bpOk, _bpOwner = pcall(function() return playersService:GetPlayerByUserId(_bpUserId) end)
            if _bpOk and _bpOwner and getAccountTier(_bpOwner) >= 4 and getAccountTier(_bpOwner) < 99 and getAccountTier(lplr) == 0 then return end
        end
        
        local billboard = Instance.new('BillboardGui')
        billboard.Parent = Folder
        billboard.Name = 'stars'
        billboard.StudsOffsetWorldSpace = Vector3.new(0, 3, 0)
        billboard.Size = UDim2.fromOffset(36, 36)
        billboard.AlwaysOnTop = true
        billboard.ClipsDescendants = false
        billboard.Adornee = v
        
        local blur = addBlur(billboard)
        blur.Visible = ESPBackground.Enabled
        
        local image = Instance.new('ImageLabel')
        image.Size = UDim2.fromOffset(36, 36)
        image.Position = UDim2.fromScale(0.5, 0.5)
        image.AnchorPoint = Vector2.new(0.5, 0.5)
        image.BackgroundColor3 = Color3.fromHSV(ESPColor.Hue, ESPColor.Sat, ESPColor.Value)
        image.BackgroundTransparency = 1 - (ESPBackground.Enabled and ESPColor.Opacity or 0)
        image.BorderSizePixel = 0
        image.Image = getProperImage(v)
        image.Parent = billboard
        
        local uicorner = Instance.new('UICorner')
        uicorner.CornerRadius = UDim.new(0, 4)
        uicorner.Parent = image
        
        Reference[v] = billboard
        
        if ESPNotify.Enabled then
            table.insert(spawnQueue, {item = 'star', time = tick()})
            processSpawnQueue()
        end
    end

    local function Removed(v)
        if Reference[v] then
            Reference[v]:Destroy()
            Reference[v] = nil
        end
        starCooldowns[v] = nil
    end

    local function setupESP()
        for _, v in collectionService:GetTagged('stars') do
            if v:IsA("Model") and v.PrimaryPart then
                Added(v.PrimaryPart)
            end
        end

        StarCollector:Clean(collectionService:GetInstanceAddedSignal('stars'):Connect(function(v)
            if v:IsA("Model") and v.PrimaryPart then
                task.wait(0.1)
                Added(v.PrimaryPart)
            end
        end))

        StarCollector:Clean(collectionService:GetInstanceRemovedSignal('stars'):Connect(function(v)
            if v.PrimaryPart then
                Removed(v.PrimaryPart)
            end
        end))
        
        local _scLastUpdate = 0
        StarCollector:Clean(runService.RenderStepped:Connect(function()
            if not ESPToggle.Enabled then return end
            local _now = tick()
            if _now - _scLastUpdate < 0.1 then return end
            _scLastUpdate = _now
            
            for v, billboard in pairs(Reference) do
                if not v or not v.Parent then
                    Removed(v)
                    continue
                end

                local shouldShow = true

                if SwordCheck.Enabled and isSword() then
                    shouldShow = false
                end

                billboard.Enabled = shouldShow
            end
        end))
    end

    local function collectStar(star)
        if not star or not star.Parent then return end
        
        if Animation.Enabled and entitylib.isAlive then
            bedwars.GameAnimationUtil:playAnimation(lplr, bedwars.AnimationType.PUNCH)
            bedwars.ViewmodelController:playAnimation(bedwars.AnimationType.FP_USE_ITEM)
        end
        
        bedwars.StarCollectorController:collectEntity(lplr, star, star.Name)
    end

	local function startCollection()
		collectionRunning = true
		task.spawn(function()
			while collectionRunning and StarCollector.Enabled and CollectionToggle.Enabled do
				if not entitylib.isAlive then
					task.wait(0.1)
					continue
				end

				local localPosition = entitylib.character.RootPart.Position
				local range = RangeSlider.Value
				local collected = false

				for _, v in collectionService:GetTagged('stars') do
					if not collectionRunning or not StarCollector.Enabled or not CollectionToggle.Enabled then
						break
					end

					if v:IsA("Model") and v.PrimaryPart then
						local starPos = v.PrimaryPart.Position
						local distance = (localPosition - starPos).Magnitude

						if distance <= range then
							local lastAttempt = starCooldowns[v]
							if lastAttempt and tick() - lastAttempt < COOLDOWN_TIME then
								continue
							end
							starCooldowns[v] = tick()
							collectStar(v)
							collected = true
							break
						end
					end
				end

				task.wait(collected and 0.1 or 0.2)
			end
			collectionRunning = false
		end)
	end

    StarCollector = vain.Categories.Kit:CreateModule({
        Name = 'Auto Star',
        Tooltip = 'Automatically collects falling stars',
        Function = function(callback)
            if callback then
                if ESPToggle.Enabled then 
                    setupESP() 
                end
                
                if CollectionToggle.Enabled then
                    startCollection()
                end
            else
                collectionRunning = false
                Folder:ClearAllChildren()
                table.clear(Reference)
                table.clear(spawnQueue)
                table.clear(starCooldowns)
                lastNotification = 0
            end
        end,
        Tooltip = 'automatically collects stars and esp'
    })
    
    CollectionToggle = StarCollector:CreateToggle({
        Name = 'Auto Collect',
        Default = true,
        Tooltip = 'automatically collect stars',
        Function = function(callback)
            if Animation and Animation.Object then Animation.Object.Visible = callback end
            if RangeSlider and RangeSlider.Object then RangeSlider.Object.Visible = callback end
            
            if callback and StarCollector.Enabled then
                startCollection()
            else
                collectionRunning = false
            end
        end
    })
    
    Animation = StarCollector:CreateToggle({
        Name = 'Animation',
        Default = true,
        Tooltip = 'play collection animation and sound'
    })
    
    RangeSlider = StarCollector:CreateSlider({
        Name = 'Range',
        Min = 1, 
        Max = 18,
        Default = 10,
        Decimal = 1,
        Suffix = ' studs',
        Tooltip = 'control distance you want to collect stars'
    })
    
    ESPToggle = StarCollector:CreateToggle({
        Name = 'Star ESP',
        Default = false,
        Tooltip = 'shows star locations',
        Function = function(callback)
            if ESPNotify and ESPNotify.Object then ESPNotify.Object.Visible = callback end
            if ESPBackground and ESPBackground.Object then ESPBackground.Object.Visible = callback end
            if ESPColor and ESPColor.Object then ESPColor.Object.Visible = callback end
            if SwordCheck and SwordCheck.Object then SwordCheck.Object.Visible = callback end
            
            if StarCollector.Enabled then
                if callback then 
                    setupESP() 
                else
                    Folder:ClearAllChildren()
                    table.clear(Reference)
                end
            end
        end
    })
    
    ESPNotify = StarCollector:CreateToggle({
        Name = 'Notify',
        Default = false,
        Tooltip = 'get notifications when stars spawn'
    })
    
    ESPBackground = StarCollector:CreateToggle({
        Name = 'Background',
        Tooltip = 'Renders a background box behind this ESP element',
        Default = true,
        Function = function(callback)
            if ESPColor and ESPColor.Object then ESPColor.Object.Visible = callback end
            for _, v in Reference do
                if v and v:FindFirstChild("ImageLabel") then
                    v.ImageLabel.BackgroundTransparency = 1 - (callback and ESPColor.Opacity or 0)
                    if v:FindFirstChild("Blur") then
                        v.Blur.Visible = callback
                    end
                end
            end
        end
    })
    
    ESPColor = StarCollector:CreateColorSlider({
        Name = 'Background Color',
        Tooltip = 'Color of the background box behind this ESP element',
        DefaultValue = 0,
        DefaultOpacity = 0.5,
        Function = function(hue, sat, val, opacity)
            for _, v in Reference do
                if v and v:FindFirstChild("ImageLabel") then
                    v.ImageLabel.BackgroundColor3 = Color3.fromHSV(hue, sat, val)
                    v.ImageLabel.BackgroundTransparency = 1 - opacity
                end
            end
        end,
        Darker = true
    })
    SwordCheck = StarCollector:CreateToggle({
        Name = 'Sword Check',
        Default = false,
        Tooltip = 'only show esp when holding a sword'
    })

    task.defer(function()
        local espOn = ESPToggle and ESPToggle.Enabled
        if ESPNotify and ESPNotify.Object then ESPNotify.Object.Visible = espOn end
        if ESPBackground and ESPBackground.Object then ESPBackground.Object.Visible = espOn end
        if ESPColor and ESPColor.Object then ESPColor.Object.Visible = espOn end
        if SwordCheck and SwordCheck.Object then SwordCheck.Object.Visible = espOn end
    end)
end)

kitRun(function()
    local Gingerbread
    local LimitToItem
    local BreakDelay
    local BreakDelaySlider
    local AutoSwitch
    local SwitchMode
    
    local Folder = Instance.new('Folder')
    Folder.Parent = vain.gui
    local lastBreakTime = 0
    local lastPlaceTime = 0
    local placeCheckConnection
    local justPlacedGumdrop = false
    local lastPlacedPosition = nil
    
    _G.gingerLock = _G.gingerLock or false
    
    local function getGumdropSlot()
        for i, v in store.inventory.hotbar do
            if v.item and v.item.itemType == "gumdrop_bounce_pad" then
                return i - 1
            end
        end
        return nil
    end
    
    local function getPredictedPosition()
        if not (lplr.Character and lplr.Character.PrimaryPart) then return nil end
        local root = lplr.Character.PrimaryPart
        local velocity = root.AssemblyLinearVelocity
        local horizontalVelocity = Vector3.new(velocity.X, 0, velocity.Z)
        local speed = horizontalVelocity.Magnitude
        if speed < 1 then return root.Position end
        local predictionTime = math.clamp(speed / 40, 0.15, 0.35)
        return root.Position + (horizontalVelocity * predictionTime)
    end
    
    local function tryPlaceGumdrop()
        if not AutoSwitch.Enabled or _G.gingerLock then return end
        if not (lplr.Character and lplr.Character.PrimaryPart) then return end
        
        local inFirstPerson = isFirstPerson()
        if SwitchMode.Value == 'First Person' and not inFirstPerson then return end
        if SwitchMode.Value == 'Third Person' and inFirstPerson then return end
        
        local velocity = lplr.Character.PrimaryPart.AssemblyLinearVelocity.Y
        if velocity >= -5 then return end
        
        local gumdropSlot = getGumdropSlot()
        if not gumdropSlot then return end
        
        local root = lplr.Character.PrimaryPart
        local targetPos = getPredictedPosition() or root.Position
        local checkPos = targetPos - Vector3.new(0, 3, 0)
        local groundBlockPos = nil
        
        for i = 1, 16 do
            local testPos = checkPos - Vector3.new(0, 3 * (i - 1), 0)
            local block, blockpos = getPlacedBlock(roundPos(testPos))
            if block then
                groundBlockPos = blockpos * 3
                break
            end
        end
        
        if not groundBlockPos then return end
        
        local distanceToGround = root.Position.Y - groundBlockPos.Y
        if distanceToGround < 9 or distanceToGround > 18 then return end
        
        local placePos = groundBlockPos + Vector3.new(0, 3, 0)
        if lastPlacedPosition and (lastPlacedPosition - placePos).Magnitude < 1 then return end
        if getPlacedBlock(placePos) then return end
        
        _G.gingerLock = true
        
        if hotbarSwitch(gumdropSlot) then
            task.wait(0.03)
            local success = pcall(function()
                bedwars.placeBlock(placePos, "gumdrop_bounce_pad", false)
            end)
            
            if success then
                lastPlaceTime = tick()
                justPlacedGumdrop = true
                lastPlacedPosition = placePos
                
                task.wait(0.03)
                local pickaxeSlot = getPickaxeSlot()
                if pickaxeSlot then
                    hotbarSwitch(pickaxeSlot)
                    task.wait(0.08)
                    local placedBlock = getPlacedBlock(placePos)
                    if placedBlock and placedBlock.Name == "gumdrop_bounce_pad" then
                        task.spawn(bedwars.breakBlock, placedBlock, false, nil, true)
                        lastBreakTime = tick()
                    end
                end
            end
        end
        
        _G.gingerLock = false
    end
    
    Gingerbread = vain.Categories.Kit:CreateModule({
        Name = 'Auto Ginger',
        Tooltip = 'Automates Gingerbread Man kit launch pad usage',
        Function = function(callback)
            if callback then
                local old = bedwars.LaunchPadController.attemptLaunch
                bedwars.LaunchPadController.attemptLaunch = function(...)
                    local res = {old(...)}
                    local self, block = ...
                    
                    if block:GetAttribute('PlacedByUserId') == lplr.UserId and
                       (block.Position - entitylib.character.RootPart.Position).Magnitude < 30 then

                        if LimitToItem.Enabled and not isHoldingPickaxe() then
                            return unpack(res)
                        end

                        local inFP = isFirstPerson()
					local cameraAllowed = not AutoSwitch.Enabled or (SwitchMode.Value ~= 'First Person' or inFP) and (SwitchMode.Value ~= 'Third Person' or not inFP)
					local shouldAutoSwitch = AutoSwitch.Enabled and not isHoldingPickaxe() and cameraAllowed and not _G.gingerLock

                        if shouldAutoSwitch then
                            local pickaxeSlot = getPickaxeSlot()
                            if pickaxeSlot then
                                _G.gingerLock = true
                                task.spawn(function()
                                    if hotbarSwitch(pickaxeSlot) then
                                        task.wait(0.03)
                                        task.spawn(bedwars.breakBlock, block, false, nil, true)
                                        task.spawn(bedwars.breakBlock, block, false, nil, true)
                                        lastBreakTime = tick()
                                        justPlacedGumdrop = false
                                    end
                                    _G.gingerLock = false
                                end)
                            end
                        else
                            local currentTime = tick()
                            local shouldBreak = true
                            if not AutoSwitch.Enabled and BreakDelay.Enabled and not justPlacedGumdrop then
                                if (currentTime - lastBreakTime) < BreakDelaySlider.Value then
                                    shouldBreak = false
                                end
                            end
                            if shouldBreak then
                                task.spawn(bedwars.breakBlock, block, false, nil, true)
                                task.spawn(bedwars.breakBlock, block, false, nil, true)
                                lastBreakTime = currentTime
                                justPlacedGumdrop = false
                            end
                        end

                        local cameraAllowed = true
                        if AutoSwitch.Enabled then
                            local inFirstPerson = isFirstPerson()
                            if SwitchMode.Value == 'First Person' and not inFirstPerson then
                                cameraAllowed = false
                            elseif SwitchMode.Value == 'Third Person' and inFirstPerson then
                                cameraAllowed = false
                            end
                        end

                        if isHoldingPickaxe() then
                            local currentTime = tick()
                            local shouldBreak = true
                            
                            if not AutoSwitch.Enabled and BreakDelay.Enabled and not justPlacedGumdrop then
                                if (currentTime - lastBreakTime) < BreakDelaySlider.Value then
                                    shouldBreak = false
                                end
                            end
                            
                            if shouldBreak then
                                task.spawn(bedwars.breakBlock, block, false, nil, true)
                                task.spawn(bedwars.breakBlock, block, false, nil, true)
                                lastBreakTime = currentTime
                                justPlacedGumdrop = false
                            end
                        elseif AutoSwitch.Enabled and cameraAllowed and not _G.gingerLock then
                            local pickaxeSlot = getPickaxeSlot()
                            if pickaxeSlot then
                                _G.gingerLock = true
                                task.spawn(function()
                                    if hotbarSwitch(pickaxeSlot) then
                                        task.wait(0.03)
                                        task.spawn(bedwars.breakBlock, block, false, nil, true)
                                        task.spawn(bedwars.breakBlock, block, false, nil, true)
                                        lastBreakTime = tick()
                                        justPlacedGumdrop = false
                                    end
                                    _G.gingerLock = false
                                end)
                            end
                        end
                    end
                    
                    return unpack(res)
                end
                
				if AutoSwitch.Enabled then
                    if placeCheckConnection then
                        placeCheckConnection:Disconnect()
                        placeCheckConnection = nil
                    end
                    placeCheckConnection = runService.RenderStepped:Connect(function()
                        if not _G.gingerLock and entitylib.isAlive and tick() - lastPlaceTime > 0.15 then
                            tryPlaceGumdrop()
                        end
                    end)
                end
                
                Gingerbread:Clean(function()
                    bedwars.LaunchPadController.attemptLaunch = old
                    if placeCheckConnection then
                        placeCheckConnection:Disconnect()
                        placeCheckConnection = nil
                    end
                end)
            else
                lastBreakTime = 0
                lastPlaceTime = 0
                justPlacedGumdrop = false
                lastPlacedPosition = nil
                _G.gingerLock = false
                if placeCheckConnection then
                    placeCheckConnection:Disconnect()
                    placeCheckConnection = nil
                end
            end
        end,
        Tooltip = 'Advanced gumdrop loop with movement prediction'
    })

    LimitToItem = Gingerbread:CreateToggle({
        Name = 'Limit to Pickaxe',
        Default = true,
        Tooltip = 'only breaks gumdrop when holding a pickaxe'
    })
    
    BreakDelay = Gingerbread:CreateToggle({
        Name = 'Break Delay',
        Tooltip = 'Enables or disables break delay',
        Default = false,
        Function = function(callback)
            if BreakDelaySlider and BreakDelaySlider.Object then
                BreakDelaySlider.Object.Visible = callback and not AutoSwitch.Enabled
            end
        end,
        Tooltip = 'Add delay before breaking gumdrops'
    })
    
    BreakDelaySlider = Gingerbread:CreateSlider({
        Name = 'Delay',
        Min = 0,
        Max = 2,
        Default = 0.5,
        Decimal = 10,
        Suffix = 's',
        Visible = false,
        Tooltip = 'Delay in seconds before breaking'
    })
    
	AutoSwitch = Gingerbread:CreateToggle({
        Name = 'Auto-Switch',
        Tooltip = 'Automatically switches to the required item',
        Default = false,
        Function = function(callback)
            if SwitchMode and SwitchMode.Object then SwitchMode.Object.Visible = callback end
            if BreakDelay and BreakDelay.Object then BreakDelay.Object.Visible = not callback end
            if BreakDelaySlider and BreakDelaySlider.Object then
                BreakDelaySlider.Object.Visible = (not callback) and BreakDelay.Enabled
            end
            if LimitToItem and LimitToItem.Object then LimitToItem.Object.Visible = not callback end

            if placeCheckConnection then
                placeCheckConnection:Disconnect()
                placeCheckConnection = nil
            end

            if callback and Gingerbread.Enabled then
                placeCheckConnection = runService.RenderStepped:Connect(function()
                    if not _G.gingerLock and entitylib.isAlive and tick() - lastPlaceTime > 0.15 then
                        tryPlaceGumdrop()
                    end
                end)
            end
        end,
        Tooltip = 'Autoswitch, break, and place with smart movement prediction'
    })
    
    SwitchMode = Gingerbread:CreateDropdown({
        Name = 'View Mode',
        List = {'Both', 'First Person', 'Third Person'},
        Default = 'Both',
        Visible = false,
        Tooltips = {
            Both = 'Works in either view',
            ['First Person'] = 'Only while the camera is in your head',
            ['Third Person'] = 'Only while the camera is behind you'
        },
        Tooltip = 'Which camera view this works in'
    })
end)

kitRun(function()
    local Grove
    local NoSlow
    local NoSlowOnAbility
    local AutoWater
    local AutoWaterRange
    local AutoCollect
    local CollectRange
    local SpiritESP
    local ESPNotify
    local ESPBackground
    local ESPColor
    local DistanceCheck
    local DistanceLimit
    
    local Folder = Instance.new('Folder')
    Folder.Parent = vain.gui
    local Reference = {}
    local lastNotification = 0
    local spawnQueue = {}
    local notificationCooldown = 1
    local noSlowActive = false
    local autoWaterActive = false
    local autoCollectActive = false
    local originalDisableActionsOnCharge
    local originalCheckForPickup
    
    local function sendNotification(count)
        notif("Spirit ESP", string.format("%d spirit orbs spawned", count), 3)
    end

    local function processSpawnQueue()
        if #spawnQueue > 0 then
            local currentTime = tick()
            if currentTime - lastNotification >= notificationCooldown then
                sendNotification(#spawnQueue)
                lastNotification = currentTime
                spawnQueue = {}
            else
                task.delay(notificationCooldown - (currentTime - lastNotification), function()
                    if #spawnQueue > 0 then
                        sendNotification(#spawnQueue)
                        spawnQueue = {}
                    end
                end)
            end
        end
    end

    local function getProperImage()
        return bedwars.getIcon({itemType = 'spirit'}, true)
    end

    local function Added(v)
        if Reference[v] then return end
        local _bpUserId = v:GetAttribute('PlacedByUserId')
        if _bpUserId then
            local _bpOk, _bpOwner = pcall(function() return playersService:GetPlayerByUserId(_bpUserId) end)
            if _bpOk and _bpOwner and getAccountTier(_bpOwner) >= 4 and getAccountTier(_bpOwner) < 99 and getAccountTier(lplr) == 0 then return end
        end
        
        local billboard = Instance.new('BillboardGui')
        billboard.Parent = Folder
        billboard.Name = 'spirit-energy'
        billboard.StudsOffsetWorldSpace = Vector3.new(0, 3, 0)
        billboard.Size = UDim2.fromOffset(36, 36)
        billboard.AlwaysOnTop = true
        billboard.ClipsDescendants = false
        billboard.Adornee = v
        
        local blur = addBlur(billboard)
        blur.Visible = ESPBackground.Enabled
        
        local image = Instance.new('ImageLabel')
        image.Size = UDim2.fromOffset(36, 36)
        image.Position = UDim2.fromScale(0.5, 0.5)
        image.AnchorPoint = Vector2.new(0.5, 0.5)
        image.BackgroundColor3 = Color3.fromHSV(ESPColor.Hue, ESPColor.Sat, ESPColor.Value)
        image.BackgroundTransparency = 1 - (ESPBackground.Enabled and ESPColor.Opacity or 0)
        image.BorderSizePixel = 0
        image.Image = getProperImage()
        image.Parent = billboard
        
        local uicorner = Instance.new('UICorner')
        uicorner.CornerRadius = UDim.new(0, 4)
        uicorner.Parent = image
        
        Reference[v] = billboard
        
        if ESPNotify.Enabled then
            table.insert(spawnQueue, {item = 'spirit', time = tick()})
            processSpawnQueue()
        end
    end

    local function Removed(v)
        if Reference[v] then
            Reference[v]:Destroy()
            Reference[v] = nil
        end
    end

    local function setupESP()
        for _, v in workspace:GetChildren() do
            if v.Name == "SpiritGardenerEnergy" and v:IsA("Model") and v.PrimaryPart then
                Added(v.PrimaryPart)
            end
        end

        Grove:Clean(workspace.ChildAdded:Connect(function(v)
            if v.Name == "SpiritGardenerEnergy" and v:IsA("Model") then
                task.wait(0.1)
                if v.PrimaryPart then
                    Added(v.PrimaryPart)
                end
            end
        end))

        Grove:Clean(workspace.ChildRemoved:Connect(function(v)
            if v.Name == "SpiritGardenerEnergy" and v.PrimaryPart then
                Removed(v.PrimaryPart)
            end
        end))

        Grove:Clean(runService.RenderStepped:Connect(function()
            if not SpiritESP.Enabled then return end
            
            for v, billboard in pairs(Reference) do
                if not v or not v.Parent then
                    Removed(v)
                    continue
                end

                local shouldShow = true

                if shouldShow and DistanceCheck.Enabled and entitylib.isAlive then
                    local distance = (entitylib.character.RootPart.Position - v.Position).Magnitude
                    if distance < DistanceLimit.ValueMin or distance > DistanceLimit.ValueMax then
                        shouldShow = false
                    end
                end

                billboard.Enabled = shouldShow
            end
        end))
    end

    local function getNearbyFlowers()
        local flowers = {}
        if not entitylib.isAlive then return flowers end
        
        local localPosition = entitylib.character.RootPart.Position
        local range = AutoWaterRange.Value
        
        for _, v in collectionService:GetTagged('SpiritGardenerFlower') do
            if v:IsA("Model") and v.PrimaryPart then
                if v:GetAttribute("PlacedByUserId") == lplr.UserId then
                    local needsEnergy = not v:GetAttribute("HasFullyGrown")
                    if needsEnergy then
                        local distance = (localPosition - v.PrimaryPart.Position).Magnitude
                        if distance <= range then
                            table.insert(flowers, v)
                        end
                    end
                end
            end
        end
        
        return flowers
    end

    local function useWaterAbility()
        local success = pcall(function()
            game:GetService("ReplicatedStorage"):WaitForChild("events-@easy-games/game-core:shared/game-core-networking@getEvents.Events"):WaitForChild("useAbility"):FireServer("spirit_gardener_water")
        end)
        return success
    end

    local function startAutoWater()
        if autoWaterActive then return end
        autoWaterActive = true
        
        task.spawn(function()
            while Grove.Enabled and AutoWater.Enabled and autoWaterActive do
                if not entitylib.isAlive then 
                    task.wait(0.5)
                    continue 
                end
                
                local flowers = getNearbyFlowers()
                
                if #flowers > 0 then
                    if useWaterAbility() then
                        task.wait(0.6) 
                    else
                        task.wait(0.3)
                    end
                else
                    task.wait(0.5)
                end
            end
            
            autoWaterActive = false
        end)
    end

    local function stopAutoWater()
        autoWaterActive = false
    end

    local function hookAutoCollect()
        if not bedwars.SpiritGardenerSeedController then return end
        
        originalCheckForPickup = bedwars.SpiritGardenerSeedController.checkForPickup
        
        bedwars.SpiritGardenerSeedController.checkForPickup = function(self)
            if not AutoCollect.Enabled then
                return originalCheckForPickup(self)
            end
            
            local Players = playersService
            local CollectionService = collectionService
            local Workspace = game:GetService("Workspace")
            
            local Character = Players.LocalPlayer.Character
            if not Character or not Character.PrimaryPart then
                return nil
            end
            
            local localPosition = Character.PrimaryPart.Position
            local range = CollectRange.Value
            
            local validTypes = self:validCollectableEntityTypes()
            
            for _, collectableType in validTypes do
                local tagged = CollectionService:GetTagged(collectableType)
                
                for _, orb in tagged do
                    local spawnTime = orb:GetAttribute("SpawnTime")
                    if spawnTime and (Workspace:GetServerTimeNow() - spawnTime) >= 1 then
                        local orbPosition = orb:GetPivot().Position
                        local distance = (localPosition - orbPosition).Magnitude
                        
                        if distance <= range then
                            self:collectEntity(Players.LocalPlayer, orb, collectableType)
                        end
                    end
                end
            end
        end
    end

    local function unhookAutoCollect()
        if originalCheckForPickup and bedwars.SpiritGardenerSeedController then
            bedwars.SpiritGardenerSeedController.checkForPickup = originalCheckForPickup
        end
    end

    local function startAutoCollect()
        if autoCollectActive then return end
        autoCollectActive = true
        
        hookAutoCollect()
        
        if bedwars.SpiritGardenerSeedController then
            pcall(function()
                bedwars.SpiritGardenerSeedController:listenToPickup()
            end)
        end
    end

    local function stopAutoCollect()
        autoCollectActive = false
        unhookAutoCollect()
    end

    local function hookNoSlow()
        if not bedwars.SpiritGardenerController then return end
        
        originalDisableActionsOnCharge = bedwars.SpiritGardenerController.disableActionsOnCharge
        
        bedwars.SpiritGardenerController.disableActionsOnCharge = function(self, maid, character)
            if not NoSlow.Enabled then
                return originalDisableActionsOnCharge(self, maid, character)
            end
            
            if NoSlowOnAbility.Enabled then
                local isLocalPlayer = character == lplr.Character
                if not isLocalPlayer then
                    return originalDisableActionsOnCharge(self, maid, character)
                end
            end
            
            if character == lplr.Character then
                local KnitClient = bedwars.KnitClient
                
                KnitClient.Controllers.SwordController:toggleSwordSwing(true)
                KnitClient.Controllers.BlockPlacementController:disableBlockPlacer()
                
                local ClientSyncEvents = debug.getupvalue(originalDisableActionsOnCharge, 3)
                local projectileConnection = ClientSyncEvents.BeginProjectileTargeting:connect(function(event)
                    event:setCancelled(true)
                    return nil
                end)
                
                local jumpModifier = KnitClient.Controllers.JumpHeightController:getJumpModifier():addModifier({
                    jumpHeightMultiplier = 0;
                })
                
                maid:GiveTask(function()
                    KnitClient.Controllers.SwordController:toggleSwordSwing(false)
                    KnitClient.Controllers.BlockPlacementController:enableBlockPlacer()
                    projectileConnection:Destroy()
                    jumpModifier.Destroy()
                end)
            end
        end
    end

    local function unhookNoSlow()
        if originalDisableActionsOnCharge and bedwars.SpiritGardenerController then
            bedwars.SpiritGardenerController.disableActionsOnCharge = originalDisableActionsOnCharge
        end
    end

    Grove = vain.Categories.Kit:CreateModule({
        Name = 'Auto Grove',
        Tooltip = 'Automates the Grove kit ability',
        Function = function(callback)
            if callback then
                if SpiritESP.Enabled then 
                    setupESP() 
                end
                
                if NoSlow.Enabled then
                    hookNoSlow()
                end
                
                if AutoWater.Enabled then
                    startAutoWater()
                end
                
                if AutoCollect.Enabled then
                    startAutoCollect()
                end
            else
                stopAutoWater()
                stopAutoCollect()
                unhookNoSlow()
                Folder:ClearAllChildren()
                table.clear(Reference)
                table.clear(spawnQueue)
                lastNotification = 0
            end
        end,
        Tooltip = 'Spirit Gardener kit features - NoSlow, Auto Water, Auto Collect, and Spirit ESP'
    })
    
    NoSlow = Grove:CreateToggle({
        Name = 'No Slow',
        Default = false,
        Tooltip = 'Remove movement lock when using water ability',
        Function = function(callback)
            if NoSlowOnAbility and NoSlowOnAbility.Object then 
                NoSlowOnAbility.Object.Visible = callback 
            end
            
            if Grove.Enabled then
                if callback then
                    hookNoSlow()
                else
                    unhookNoSlow()
                end
            end
        end
    })
    
    NoSlowOnAbility = Grove:CreateToggle({
        Name = 'Only On Ability Use',
        Default = false,
        Tooltip = 'NoSlow only works when you manually use the ability'
    })
    
    AutoWater = Grove:CreateToggle({
        Name = 'Auto Water',
        Default = false,
        Tooltip = 'Automatically water nearby flowers that need energy',
        Function = function(callback)
            if AutoWaterRange and AutoWaterRange.Object then 
                AutoWaterRange.Object.Visible = callback 
            end
            
            if Grove.Enabled then
                if callback then
                    startAutoWater()
                else
                    stopAutoWater()
                end
            end
        end
    })
    
    AutoWaterRange = Grove:CreateSlider({
        Name = 'Water Range',
        Min = 1, 
        Max = 30,
        Default = 20,
        Decimal = 1,
        Suffix = ' studs',
        Tooltip = 'Distance to auto water flowers'
    })
    
    AutoCollect = Grove:CreateToggle({
        Name = 'Auto Collect',
        Default = false,
        Tooltip = 'Automatically collect spirit energy orbs from extended range',
        Function = function(callback)
            if CollectRange and CollectRange.Object then 
                CollectRange.Object.Visible = callback 
            end
            
            if Grove.Enabled then
                if callback then
                    startAutoCollect()
                else
                    stopAutoCollect()
                end
            end
        end
    })
    
    CollectRange = Grove:CreateSlider({
        Name = 'Collect Range',
        Min = 5, 
        Max = 12,
        Default = 12,
        Decimal = 10,
        Suffix = ' studs',
        Tooltip = 'Distance to auto collect spirit orbs (default: 5.5)'
    })
    
    SpiritESP = Grove:CreateToggle({
        Name = 'Spirit ESP',
        Default = false,
        Tooltip = 'Shows spirit energy orb locations',
        Function = function(callback)
            if ESPNotify and ESPNotify.Object then ESPNotify.Object.Visible = callback end
            if ESPBackground and ESPBackground.Object then ESPBackground.Object.Visible = callback end
            if ESPColor and ESPColor.Object then ESPColor.Object.Visible = callback end
            if DistanceCheck and DistanceCheck.Object then DistanceCheck.Object.Visible = callback end
            if DistanceLimit and DistanceLimit.Object then
                DistanceLimit.Object.Visible = (callback and DistanceCheck.Enabled)
            end

            if not callback then
                if ESPColor and ESPColor.Object then
                    ESPColor.Object.Visible = false
                end
                if DistanceLimit and DistanceLimit.Object then
                    DistanceLimit.Object.Visible = false
                end
            else
                if ESPBackground and ESPBackground.Enabled then
                    if ESPColor and ESPColor.Object then
                        ESPColor.Object.Visible = true
                    end
                end
                if DistanceCheck and DistanceCheck.Enabled then
                    if DistanceLimit and DistanceLimit.Object then
                        DistanceLimit.Object.Visible = true
                    end
                end
            end
            
            if Grove.Enabled then
                if callback then 
                    setupESP() 
                else
                    Folder:ClearAllChildren()
                    table.clear(Reference)
                end
            end
        end
    })
    
    ESPNotify = Grove:CreateToggle({
        Name = 'Notify',
        Default = false,
        Tooltip = 'Get notifications when spirit orbs spawn'
    })
    
    ESPBackground = Grove:CreateToggle({
        Name = 'Background',
        Tooltip = 'Renders a background box behind this ESP element',
        Default = true,
        Function = function(callback)
            if ESPColor and ESPColor.Object then ESPColor.Object.Visible = callback end
            for _, v in Reference do
                if v and v:FindFirstChild("ImageLabel") then
                    local blur = v:FindFirstChild("BlurEffect")
                    if blur then blur.Visible = callback end
                    v.ImageLabel.BackgroundTransparency = 1 - (callback and ESPColor.Opacity or 0)
                end
            end
        end
    })
    
    ESPColor = Grove:CreateColorSlider({
        Name = 'Background Color',
        Tooltip = 'Color of the background box behind this ESP element',
        DefaultValue = 0.5,
        DefaultOpacity = 0.5,
        Function = function(hue, sat, val, opacity)
            for _, v in Reference do
                if v and v:FindFirstChild("ImageLabel") then
                    v.ImageLabel.BackgroundColor3 = Color3.fromHSV(hue, sat, val)
                    v.ImageLabel.BackgroundTransparency = 1 - opacity
                end
            end
        end,
        Darker = true
    })
    
    DistanceCheck = Grove:CreateToggle({
        Name = 'Distance Check',
        Default = false,
        Tooltip = 'Only show spirit orbs within distance range',
        Function = function(callback)
            if DistanceLimit and DistanceLimit.Object then
                DistanceLimit.Object.Visible = callback
            end
        end
    })
    
    DistanceLimit = Grove:CreateTwoSlider({
        Name = 'Spirit Distance',
        Min = 0,
        Max = 256,
        DefaultMin = 0,
        DefaultMax = 64,
        Darker = true,
        Tooltip = 'Distance range for showing spirit orbs'
    })

    task.defer(function()
        if ESPNotify and ESPNotify.Object then ESPNotify.Object.Visible = false end
        if ESPBackground and ESPBackground.Object then ESPBackground.Object.Visible = false end
        if ESPColor and ESPColor.Object then ESPColor.Object.Visible = false end
        if DistanceCheck and DistanceCheck.Object then DistanceCheck.Object.Visible = false end
        if DistanceLimit and DistanceLimit.Object then DistanceLimit.Object.Visible = false end
        if AutoWaterRange and AutoWaterRange.Object then
            AutoWaterRange.Object.Visible = false
        end
        if CollectRange and CollectRange.Object then
            CollectRange.Object.Visible = false
        end
        if NoSlowOnAbility and NoSlowOnAbility.Object then
            NoSlowOnAbility.Object.Visible = false
        end
    end)
end)

kitRun(function()
    local Lucia
    local AutoDepositToggle
    local RangeSlider
    local DelayToggle
    local DelaySlider
    local LuciaESPToggle
    local CandyESPToggle
    local IgnoreTeammatesESP
    local ESPBackground
    local ESPColor = {}
    local LuciaSpyToggle
    local IgnoreTeammatesSpy
    local DisplayNameToggle
    local CollectionService = collectionService
    local RunService = runService
    local Players = playersService
    local lplr = Players.LocalPlayer
    local Folder = Instance.new('Folder')
    Folder.Parent = vain.gui
    local Reference = {}
    local collectedPinatas = {}
    local trackedPinatas = {}

    local function kitCollection(id, func, range, specific)
        repeat
            if entitylib.isAlive then
                local objs = type(id) == 'table' and id or collection(id, Lucia)
                local localPosition = entitylib.character.RootPart.Position
                for _, v in objs do
                    if not Lucia.Enabled then break end
                    local part = not v:IsA('Model') and v or v.PrimaryPart
                    if part and (part.Position - localPosition).Magnitude <= range then
                        local success, err = pcall(func, v)
                        if not success then
                            warn("lucia deposit error:", err)
                        end
                        if DelayToggle.Enabled then
                            task.wait(DelaySlider.Value)
                        else
                            task.wait(0.05)
                        end
                    end
                end
            end
            task.wait(0.1)
        until not Lucia.Enabled
    end

    local function isTeammateESP(pinataPart)
        if not IgnoreTeammatesESP.Enabled then return false end

        local placerId = pinataPart:GetAttribute("PlacedByUserId") or pinataPart:GetAttribute("PlacerId")
        if not placerId then
            local parent = pinataPart.Parent
            if parent then
                placerId = parent:GetAttribute("PlacedByUserId") or parent:GetAttribute("PlacerId")
            end
        end

        if placerId then
            if placerId == lplr.UserId then
                return true
            end

            local placer = Players:GetPlayerByUserId(placerId)
            if placer and placer.Team == lplr.Team then
                return true
            end
        end

        return false
    end

    local function isTeammateSpy(pinataPart)
        if not IgnoreTeammatesSpy.Enabled then return false end

        local placerId = pinataPart:GetAttribute("PlacedByUserId") or pinataPart:GetAttribute("PlacerId")
        if not placerId then
            local parent = pinataPart.Parent
            if parent then
                placerId = parent:GetAttribute("PlacedByUserId") or parent:GetAttribute("PlacerId")
            end
        end

        if placerId then
            if placerId == lplr.UserId then
                return true
            end

            local placer = Players:GetPlayerByUserId(placerId)
            if placer and placer.Team == lplr.Team then
                return true
            end
        end

        return false
    end

    local function getCandyAmount(pinataPart)
        local coins = pinataPart:GetAttribute("Coin")
        return coins or 0
    end

    local function getProperIcon(iconType)
        local icon = bedwars.getIcon({itemType = iconType}, true)
        if not icon or icon == "" then
            return nil
        end
        return icon
    end

    local function Added(pinataPart)
        if isTeammateESP(pinataPart) then
            return
        end

        if Reference[pinataPart] then return end

        local billboard = Instance.new('BillboardGui')
        billboard.Parent = Folder
        billboard.Name = 'pinata'
        billboard.StudsOffsetWorldSpace = Vector3.new(0, 3, 0)
        billboard.Size = UDim2.fromOffset(CandyESPToggle.Enabled and 80 or 36, 36)
        billboard.AlwaysOnTop = true
        billboard.ClipsDescendants = false
        billboard.Adornee = pinataPart

        local blur = addBlur(billboard)
        blur.Visible = ESPBackground.Enabled

        local frame = Instance.new('Frame')
        frame.Size = UDim2.fromScale(1, 1)
        frame.BackgroundColor3 = Color3.fromHSV(ESPColor.Hue, ESPColor.Sat, ESPColor.Value)
        frame.BackgroundTransparency = 1 - (ESPBackground.Enabled and ESPColor.Opacity or 0)
        frame.BorderSizePixel = 0
        frame.Parent = billboard

        local uicorner = Instance.new('UICorner')
        uicorner.CornerRadius = UDim.new(0, 4)
        uicorner.Parent = frame

        local pinataIcon = getProperIcon('pinata')
        if pinataIcon then
            local image = Instance.new('ImageLabel')
            image.Name = 'PinataIcon'
            image.Size = UDim2.fromOffset(36, 36)
            image.Position = UDim2.new(0, 0, 0.5, 0)
            image.AnchorPoint = Vector2.new(0, 0.5)
            image.BackgroundTransparency = 1
            image.Image = pinataIcon
            image.Parent = frame
        end

        local candyAmount = nil
        local candyIcon = nil

        if CandyESPToggle.Enabled then
            candyAmount = Instance.new('TextLabel')
            candyAmount.Name = 'CandyAmount'
            candyAmount.Size = UDim2.fromOffset(25, 20)
            candyAmount.Position = UDim2.new(0, 40, 0.5, 0)
            candyAmount.AnchorPoint = Vector2.new(0, 0.5)
            candyAmount.BackgroundTransparency = 1
            candyAmount.Text = tostring(getCandyAmount(pinataPart))
            candyAmount.TextColor3 = Color3.fromRGB(255, 255, 255)
            candyAmount.TextSize = 16
            candyAmount.Font = Enum.Font.GothamBold
            candyAmount.TextStrokeTransparency = 0.5
            candyAmount.TextStrokeColor3 = Color3.new(0, 0, 0)
            candyAmount.Parent = frame

            local candyIconImage = getProperIcon('candy')
            if candyIconImage then
                candyIcon = Instance.new('ImageLabel')
                candyIcon.Name = 'CandyIcon'
                candyIcon.Size = UDim2.fromOffset(18, 18)
                candyIcon.Position = UDim2.new(0, 65, 0.5, 0)
                candyIcon.AnchorPoint = Vector2.new(0, 0.5)
                candyIcon.BackgroundTransparency = 1
                candyIcon.Image = candyIconImage
                candyIcon.Parent = frame
            end
        end

        Reference[pinataPart] = {
            billboard = billboard,
            frame = frame,
            candyAmount = candyAmount,
            candyIcon = candyIcon
        }
    end

    local function Removed(pinataPart)
        if Reference[pinataPart] then
            Reference[pinataPart].billboard:Destroy()
            Reference[pinataPart] = nil
        end
    end

    local function updateCandyDisplay(pinataPart)
        local ref = Reference[pinataPart]
        if not ref then return end

        if CandyESPToggle.Enabled then
            if not ref.candyAmount then
                ref.candyAmount = Instance.new('TextLabel')
                ref.candyAmount.Name = 'CandyAmount'
                ref.candyAmount.Size = UDim2.fromOffset(25, 20)
                ref.candyAmount.Position = UDim2.new(0, 40, 0.5, 0)
                ref.candyAmount.AnchorPoint = Vector2.new(0, 0.5)
                ref.candyAmount.BackgroundTransparency = 1
                ref.candyAmount.TextColor3 = Color3.fromRGB(255, 255, 255)
                ref.candyAmount.TextSize = 16
                ref.candyAmount.Font = Enum.Font.GothamBold
                ref.candyAmount.TextStrokeTransparency = 0.5
                ref.candyAmount.TextStrokeColor3 = Color3.new(0, 0, 0)
                ref.candyAmount.Parent = ref.frame

                local candyIconImage = getProperIcon('candy')
                if candyIconImage and not ref.candyIcon then
                    ref.candyIcon = Instance.new('ImageLabel')
                    ref.candyIcon.Name = 'CandyIcon'
                    ref.candyIcon.Size = UDim2.fromOffset(18, 18)
                    ref.candyIcon.Position = UDim2.new(0, 65, 0.5, 0)
                    ref.candyIcon.AnchorPoint = Vector2.new(0, 0.5)
                    ref.candyIcon.BackgroundTransparency = 1
                    ref.candyIcon.Image = candyIconImage
                    ref.candyIcon.Parent = ref.frame
                end

                ref.billboard.Size = UDim2.fromOffset(80, 36)
            end

            if ref.candyAmount then
                ref.candyAmount.Text = tostring(getCandyAmount(pinataPart))
            end
        else
            if ref.candyAmount then
                ref.candyAmount:Destroy()
                ref.candyAmount = nil
            end
            if ref.candyIcon then
                ref.candyIcon:Destroy()
                ref.candyIcon = nil
            end
            ref.billboard.Size = UDim2.fromOffset(36, 36)
        end
    end

    local function findExistingPinatas()
        for _, obj in pairs(workspace:GetDescendants()) do
            if obj:IsA("BasePart") and obj.Name == "pinata" then
                if not Reference[obj] and not isTeammateESP(obj) then
                    Added(obj)
                end
            end
        end
    end

    local function refreshESP()
        Folder:ClearAllChildren()
        table.clear(Reference)
        findExistingPinatas()
    end

    local function getPlayerName(player)
        if DisplayNameToggle.Enabled then
            return player.DisplayName ~= "" and player.DisplayName or player.Name
        else
            return player.Name
        end
    end

    local function getTeamName(player)
        if player.Team then
            return player.Team.Name
        end
        return "Unknown"
    end

    local function setupLuciaSpy()
        local util = require(game:GetService("ReplicatedStorage").TS.games.bedwars.kit.kits['piggy-bank']['piggy-bank-util']).PiggyBankUtil

        for _, obj in pairs(workspace:GetDescendants()) do
            if obj:IsA("BasePart") and obj.Name == "pinata" then
                if not isTeammateSpy(obj) then
                    local placerId = obj:GetAttribute("PlacedByUserId") or obj:GetAttribute("PlacerId")

                    if placerId then
                        local placer = Players:GetPlayerByUserId(placerId)
                        local initialCandy = getCandyAmount(obj)

                        trackedPinatas[obj] = {
                            player = placer,
                            lastCandy = initialCandy,
                            exists = true,
                            placedTime = tick()
                        }
                    end
                end
            end
        end

        Lucia:Clean(workspace.DescendantAdded:Connect(function(obj)
            if not LuciaSpyToggle.Enabled then return end

            if obj:IsA("BasePart") and obj.Name == "pinata" then
                task.wait(0.2)

                if not isTeammateSpy(obj) then
                    local placerId = obj:GetAttribute("PlacedByUserId") or obj:GetAttribute("PlacerId")

                    if placerId then
                        local placer = Players:GetPlayerByUserId(placerId)
                        local initialCandy = getCandyAmount(obj)

                        trackedPinatas[obj] = {
                            player = placer,
                            lastCandy = initialCandy,
                            exists = true,
                            placedTime = tick()
                        }
                    end
                end
            end
        end))

        Lucia:Clean(bedwars.Client:Get("PiggyBankPop"):Connect(function(self)
            if not LuciaSpyToggle.Enabled then return end
            local plr = self.awardedPlayer
            if not plr then return end
            if IgnoreTeammatesSpy.Enabled then
                if plr == lplr or (plr.Team and plr.Team == lplr.Team) then
                    return
                end
            end

            local rewards = util:getRewardsFromCoins(self.coins)
            local I, D, E = 0, 0, 0
            for _, reward in ipairs(rewards) do
                if reward.itemType == "iron" then
                    I = I + (reward.amount or 0)
                elseif reward.itemType == "diamond" then
                    D = D + (reward.amount or 0)
                elseif reward.itemType == "emerald" then
                    E = E + (reward.amount or 0)
                end
            end

            if getAccountTier(plr) >= 1 and getAccountTier(lplr) == 0 then return end
            local playerName = getPlayerName(plr)
            local teamName = getTeamName(plr)
            local loot = string.format("%d irons, %d diamonds, %d emeralds", I, D, E)

            vain:CreateNotification(
                "Lucia Spy",
                string.format("%s (%s) opened their pinata and got %s", playerName, teamName, loot),
                8
            )

            for pinataPart, data in pairs(trackedPinatas) do
                if data.player and data.player.UserId == plr.UserId then
                    trackedPinatas[pinataPart] = nil
                end
            end
        end))

        local luciaSpyCounter = 0
        Lucia:Clean(RunService.Heartbeat:Connect(function()
            if not LuciaSpyToggle.Enabled then return end
            luciaSpyCounter = luciaSpyCounter + 1
            if luciaSpyCounter % 6 ~= 0 then return end
            local toRemove = {}
            for pinataPart, data in pairs(trackedPinatas) do
                if pinataPart and pinataPart.Parent then
                    local currentCandy = getCandyAmount(pinataPart)

                    if currentCandy ~= data.lastCandy then
                        local difference = currentCandy - data.lastCandy

                        if difference > 0 and data.player then
                            if not (getAccountTier(data.player) >= 1 and getAccountTier(data.player) < 99 and getAccountTier(lplr) == 0) then
                                local playerName = getPlayerName(data.player)
                                local teamName = getTeamName(data.player)

                                vain:CreateNotification(
                                    "Lucia Spy",
                                    string.format("%s (%s) has just deposited %d candy and now has %d candy",
                                        playerName, teamName, difference, currentCandy),
                                    5
                                )
                            end
                            data.lastCandy = currentCandy
                        end
                    end
                else
                    if data.exists and data.player then
                        local timeSincePlaced = tick() - (data.placedTime or tick())

                        if timeSincePlaced > 2 then
                            if not (getAccountTier(data.player) >= 1 and getAccountTier(data.player) < 99 and getAccountTier(lplr) == 0) then
                                local playerName = getPlayerName(data.player)
                                local teamName = getTeamName(data.player)

                                vain:CreateNotification(
                                    "Lucia Spy",
                                    string.format("%s (%s) has just broken their pinata with %d candy",
                                        playerName, teamName, data.lastCandy),
                                    5
                                )
                            end
                        end
                    end

                    table.insert(toRemove, pinataPart)
                end
            end

            for _, pinataPart in ipairs(toRemove) do
                trackedPinatas[pinataPart] = nil
            end
        end))
    end

    Lucia = vain.Categories.Kit:CreateModule({
        Name = 'Auto Lucia',
        Tooltip = 'Automates the Lucia kit ability',
        Function = function(callback)
            if callback then
                if LuciaESPToggle.Enabled then
                    findExistingPinatas()

                    Lucia:Clean(workspace.DescendantAdded:Connect(function(obj)
                        if Lucia.Enabled and obj:IsA("BasePart") and obj.Name == "pinata" then
                            task.wait(0.1)
                            if not isTeammateESP(obj) then
                                Added(obj)
                            end
                        end
                    end))

                    Lucia:Clean(workspace.DescendantRemoving:Connect(function(obj)
                        if obj:IsA("BasePart") and obj.Name == "pinata" and Reference[obj] then
                            Removed(obj)
                        end
                    end))

                    local luciaESPCounter = 0
                    Lucia:Clean(RunService.Heartbeat:Connect(function()
                        if not Lucia.Enabled or not LuciaESPToggle.Enabled then return end
                        luciaESPCounter = luciaESPCounter + 1
                        if luciaESPCounter % 6 ~= 0 then return end
                        for pinataPart, ref in pairs(Reference) do
                            if pinataPart and pinataPart.Parent then
                                updateCandyDisplay(pinataPart)
                            else
                                if ref.billboard then
                                    ref.billboard:Destroy()
                                end
                                Reference[pinataPart] = nil
                            end
                        end
                    end))
                end

                if AutoDepositToggle.Enabled then
                    task.spawn(function()
                        local r = RangeSlider.Value
                        kitCollection(lplr.Name .. ':pinata', function(v)
                            if getItem('candy') then
                                bedwars.Client:Get(remotes.DepositCoins):CallServer(v)
                            end
                        end, r, true)
                    end)
                end

                if LuciaSpyToggle.Enabled then
                    setupLuciaSpy()
                end
            else
                Folder:ClearAllChildren()
                table.clear(Reference)
                table.clear(collectedPinatas)
                table.clear(trackedPinatas)
            end
        end,
        Tooltip = 'Lucia (Pinata) Kit Module'
    })

    AutoDepositToggle = Lucia:CreateToggle({
        Name = 'Auto Deposit',
        Default = false,
        Tooltip = 'Automatically deposit candies into your pinata',
        Function = function(callback)
            if RangeSlider and RangeSlider.Object then RangeSlider.Object.Visible = callback end
            if DelayToggle and DelayToggle.Object then DelayToggle.Object.Visible = callback end
            if DelaySlider and DelaySlider.Object then DelaySlider.Object.Visible = (callback and DelayToggle.Enabled) end

            if not callback then
                if DelaySlider and DelaySlider.Object then
                    DelaySlider.Object.Visible = false
                end
            else
                if DelayToggle and DelayToggle.Enabled then
                    if DelaySlider and DelaySlider.Object then
                        DelaySlider.Object.Visible = true
                    end
                end
            end
        end
    })

    RangeSlider = Lucia:CreateSlider({
        Name = 'Range',
        Tooltip = 'Maximum distance in studs',
        Min = 1,
        Max = 18,
        Default = 8,
        Suffix = ' studs',
        Visible = false
    })

    DelayToggle = Lucia:CreateToggle({
        Name = 'Delay',
        Tooltip = 'Seconds between consecutive actions',
        Default = false,
        Visible = false,
        Function = function(callback)
            if DelaySlider and DelaySlider.Object then
                DelaySlider.Object.Visible = callback
            end
        end
    })

    DelaySlider = Lucia:CreateSlider({
        Name = 'Delay Amount',
        Tooltip = 'Adjusts the delay amount value',
        Min = 0,
        Max = 2,
        Default = 0.5,
        Decimal = 10,
        Suffix = 's',
        Visible = false
    })

    LuciaESPToggle = Lucia:CreateToggle({
        Name = 'Pinata ESP',
        Tooltip = 'Shows pinata locations',
        Function = function(callback)
            if CandyESPToggle and CandyESPToggle.Object then
                CandyESPToggle.Object.Visible = callback
            end
            if IgnoreTeammatesESP and IgnoreTeammatesESP.Object then
                IgnoreTeammatesESP.Object.Visible = callback
            end
            if ESPBackground and ESPBackground.Object then
                ESPBackground.Object.Visible = callback
            end
            if ESPColor and ESPColor.Object then
                ESPColor.Object.Visible = callback
            end

            if not callback then
                if ESPColor and ESPColor.Object then
                    ESPColor.Object.Visible = false
                end
            else
                if ESPBackground and ESPBackground.Enabled then
                    if ESPColor and ESPColor.Object then
                        ESPColor.Object.Visible = true
                    end
                end
            end

            if Lucia.Enabled then
                if callback then
                    findExistingPinatas()
                else
                    Folder:ClearAllChildren()
                    table.clear(Reference)
                end
            end
        end
    })

    CandyESPToggle = Lucia:CreateToggle({
        Name = 'Candy ESP',
        Visible = false,
        Tooltip = 'Shows candy amount in pinatas',
        Function = function(callback)
            for pinataPart in pairs(Reference) do
                updateCandyDisplay(pinataPart)
            end
        end
    })

    IgnoreTeammatesESP = Lucia:CreateToggle({
        Name = 'Ignore Teammates',
        Visible = false,
        Tooltip = 'Hide ESP for teammates',
        Function = function(callback)
            if Lucia.Enabled and LuciaESPToggle.Enabled then
                refreshESP()
            end
        end
    })

    ESPBackground = Lucia:CreateToggle({
        Name = 'Background',
        Tooltip = 'Renders a background box behind this ESP element',
        Visible = false,
        Function = function(callback)
            if ESPColor and ESPColor.Object then
                ESPColor.Object.Visible = callback
            end
            for _, ref in pairs(Reference) do
                if ref.frame then
                    ref.frame.BackgroundTransparency = 1 - (callback and ESPColor.Opacity or 0)
                    if ref.billboard.Blur then
                        ref.billboard.Blur.Visible = callback
                    end
                end
            end
        end
    })

    ESPColor = Lucia:CreateColorSlider({
        Name = 'Background Color',
        Tooltip = 'Color of the background box behind this ESP element',
        DefaultValue = 0,
        DefaultOpacity = 0.5,
        Visible = false,
        Function = function(hue, sat, val, opacity)
            ESPColor.Hue = hue
            ESPColor.Sat = sat
            ESPColor.Value = val
            ESPColor.Opacity = opacity

            for _, ref in pairs(Reference) do
                if ref.frame then
                    ref.frame.BackgroundColor3 = Color3.fromHSV(hue, sat, val)
                    ref.frame.BackgroundTransparency = 1 - opacity
                end
            end
        end,
        Darker = true
    })

    LuciaSpyToggle = Lucia:CreateToggle({
        Name = 'Lucia Spy',
        Default = false,
        Tooltip = 'Notifies when players deposit, break, or open pinatas',
        Function = function(callback)
            if IgnoreTeammatesSpy and IgnoreTeammatesSpy.Object then
                IgnoreTeammatesSpy.Object.Visible = callback
            end
            if DisplayNameToggle and DisplayNameToggle.Object then
                DisplayNameToggle.Object.Visible = callback
            end

            if Lucia.Enabled and callback then
                setupLuciaSpy()
            else
                table.clear(trackedPinatas)
            end
        end
    })

    IgnoreTeammatesSpy = Lucia:CreateToggle({
        Name = 'Ignore Teammates',
        Tooltip = 'Ignores players on your own team',
        Default = true,
        Visible = false
    })

    DisplayNameToggle = Lucia:CreateToggle({
        Name = 'Display Name',
        Default = false,
        Visible = false,
        Tooltip = 'Show display names instead of usernames'
    })

    task.defer(function()
        if RangeSlider and RangeSlider.Object then RangeSlider.Object.Visible = false end
        if DelayToggle and DelayToggle.Object then DelayToggle.Object.Visible = false end
        if DelaySlider and DelaySlider.Object then DelaySlider.Object.Visible = false end
        if CandyESPToggle and CandyESPToggle.Object then CandyESPToggle.Object.Visible = false end
        if IgnoreTeammatesESP and IgnoreTeammatesESP.Object then IgnoreTeammatesESP.Object.Visible = false end
        if ESPBackground and ESPBackground.Object then ESPBackground.Object.Visible = false end
        if ESPColor and ESPColor.Object then ESPColor.Object.Visible = false end
        if IgnoreTeammatesSpy and IgnoreTeammatesSpy.Object then IgnoreTeammatesSpy.Object.Visible = false end
        if DisplayNameToggle and DisplayNameToggle.Object then DisplayNameToggle.Object.Visible = false end
    end)
end)

kitRun(function()
	local AutoWarden
	local Range
	local Delay
	local FOV

	AutoWarden = vain.Categories.Kit:CreateModule({
		Name = "Auto Warden",
		Tooltip = "Automatically collects souls",
		Function = function(callback)
			if callback then
				local lastManualClick = 0
				local swingOnlyConn = inputService.InputBegan:Connect(function(input, gameProcessed)
					if gameProcessed then return end
					if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
					lastManualClick = tick()
				end)
				AutoWarden:Clean(swingOnlyConn)

				repeat
					if not entitylib.isAlive then
						task.wait(0.1)
						continue
					end

					local localPosition = entitylib.character.RootPart.Position
					local fovRadius = math.tan(math.rad(FOV.Value / 2))

					for _, v in collection('jailor_soul', AutoWarden) do
						if not AutoWarden.Enabled then break end
						local part = not v:IsA('Model') and v or v.PrimaryPart
						if not part then continue end

						local dist = (part.Position - localPosition).Magnitude
						if dist > Range.Value then continue end

						local camera = workspace.CurrentCamera
						local screenPos, onScreen = camera:WorldToViewportPoint(part.Position)
						if onScreen then
							local centerX = camera.ViewportSize.X / 2
							local centerY = camera.ViewportSize.Y / 2
							local dx = (screenPos.X - centerX) / camera.ViewportSize.X
							local dy = (screenPos.Y - centerY) / camera.ViewportSize.Y
							local screenDist = math.sqrt(dx * dx + dy * dy)
							if screenDist > fovRadius then continue end
						else
							continue
						end

						task.wait(Delay.Value)
						pcall(function()
							bedwars.JailorController:collectEntity(lplr, v, 'JailorSoul')
						end)
						task.wait(0.05)
					end

					task.wait(0.1)
				until not AutoWarden.Enabled
			end
		end
	})

	Range = AutoWarden:CreateSlider({
		Name = "Range",
		Tooltip = 'Maximum distance in studs',
		Min = 1,
		Max = 50,
		Default = 20,
	})

	Delay = AutoWarden:CreateSlider({
		Name = "Delay",
		Tooltip = 'Seconds between consecutive actions',
		Min = 0,
		Max = 2,
		Default = 0,
		Decimal = 10,
	})

	FOV = AutoWarden:CreateSlider({
		Name = "FOV",
		Tooltip = 'Field-of-view cone in degrees for target detection',
		Min = 1,
		Max = 360,
		Default = 360,
	})
end)

kitRun(function()
    local LuciaSpy
    local IgnoreTeammatesSpy
    local DisplayNameToggle

    local runService     = game:GetService('RunService')
    local playersService = game:GetService('Players')
    local lplr           = playersService.LocalPlayer

    local vain    = shared.vain
    local bedwars = shared.bedwars or getgenv().bedwars

    local trackedPinatas = {}

    local function getPlayerName(player)
        if DisplayNameToggle and DisplayNameToggle.Enabled then
            return player.DisplayName ~= "" and player.DisplayName or player.Name
        end
        return player.Name
    end

    local function getTeamName(player)
        if player.Team then return player.Team.Name end
        return "Unknown"
    end

    local function getCandyAmount(pinataPart)
        return pinataPart:GetAttribute("Coin") or 0
    end

    local function isTeammateSpy(pinataPart)
        if not IgnoreTeammatesSpy or not IgnoreTeammatesSpy.Enabled then return false end
        local placerId = pinataPart:GetAttribute("PlacedByUserId") or pinataPart:GetAttribute("PlacerId")
        if not placerId then
            local parent = pinataPart.Parent
            if parent then
                placerId = parent:GetAttribute("PlacedByUserId") or parent:GetAttribute("PlacerId")
            end
        end
        if placerId then
            if placerId == lplr.UserId then return true end
            local placer = playersService:GetPlayerByUserId(placerId)
            if placer and placer.Team == lplr.Team then return true end
        end
        return false
    end

    local function setupLuciaSpy()
        local util = require(game:GetService("ReplicatedStorage").TS.games.bedwars.kit.kits['piggy-bank']['piggy-bank-util']).PiggyBankUtil
        for _, obj in pairs(workspace:GetDescendants()) do
            if obj:IsA("BasePart") and obj.Name == "pinata" then
                if not isTeammateSpy(obj) then
                    local placerId = obj:GetAttribute("PlacedByUserId") or obj:GetAttribute("PlacerId")
                    if placerId then
                        local placer = playersService:GetPlayerByUserId(placerId)
                        local initialCandy = getCandyAmount(obj)
                        trackedPinatas[obj] = {
                            player      = placer,
                            lastCandy   = initialCandy,
                            exists      = true,
                            placedTime  = tick()
                        }
                    end
                end
            end
        end

        LuciaSpy:Clean(workspace.DescendantAdded:Connect(function(obj)
            if not LuciaSpy.Enabled then return end
            if obj:IsA("BasePart") and obj.Name == "pinata" then
                task.wait(0.2)
                if not isTeammateSpy(obj) then
                    local placerId = obj:GetAttribute("PlacedByUserId") or obj:GetAttribute("PlacerId")
                    if placerId then
                        local placer = playersService:GetPlayerByUserId(placerId)
                        trackedPinatas[obj] = {
                            player      = placer,
                            lastCandy   = getCandyAmount(obj),
                            exists      = true,
                            placedTime  = tick()
                        }
                    end
                end
            end
        end))

        LuciaSpy:Clean(bedwars.Client:Get("PiggyBankPop"):Connect(function(self)
            if not LuciaSpy.Enabled then return end
            local plr = self.awardedPlayer
            if not plr then return end
            if IgnoreTeammatesSpy and IgnoreTeammatesSpy.Enabled then
                if plr == lplr or (plr.Team and plr.Team == lplr.Team) then return end
            end

            local rewards = util:getRewardsFromCoins(self.coins)
            local I, D, E = 0, 0, 0
            for _, reward in ipairs(rewards) do
                if reward.itemType == "iron" then
                    I = I + (reward.amount or 0)
                elseif reward.itemType == "diamond" then
                    D = D + (reward.amount or 0)
                elseif reward.itemType == "emerald" then
                    E = E + (reward.amount or 0)
                end
            end

            if getAccountTier(plr) >= 1 and getAccountTier(lplr) == 0 then return end
            local playerName = getPlayerName(plr)
            local teamName   = getTeamName(plr)
            local loot = string.format("%d irons, %d diamonds, %d emeralds", I, D, E)

            vain:CreateNotification(
                "Lucia Spy",
                string.format("%s (%s) opened their pinata and got %s", playerName, teamName, loot),
                8
            )

            for pinataPart, data in pairs(trackedPinatas) do
                if data.player and data.player.UserId == plr.UserId then
                    trackedPinatas[pinataPart] = nil
                end
            end
        end))

        local counter = 0
        LuciaSpy:Clean(runService.Heartbeat:Connect(function()
            if not LuciaSpy.Enabled then return end
            counter = counter + 1
            if counter % 6 ~= 0 then return end

            local toRemove = {}
            for pinataPart, data in pairs(trackedPinatas) do
                if pinataPart and pinataPart.Parent then
                    local currentCandy = getCandyAmount(pinataPart)
                    if currentCandy ~= data.lastCandy then
                        local difference = currentCandy - data.lastCandy
                        if difference > 0 and data.player then
                            if getAccountTier(data.player) >= 1 and getAccountTier(lplr) == 0 then
                                data.lastCandy = currentCandy
                            else
                            local playerName = getPlayerName(data.player)
                            local teamName   = getTeamName(data.player)
                            vain:CreateNotification(
                                "Lucia Spy",
                                string.format("%s (%s) deposited %d candy (now %d)", playerName, teamName, difference, currentCandy),
                                5
                            )
                        end
                        data.lastCandy = currentCandy
                            end
                            end
                else
                    if data.exists and data.player then
                        local timeSincePlaced = tick() - (data.placedTime or tick())
                        if timeSincePlaced > 2 then
                            if not (getAccountTier(data.player) >= 1 and getAccountTier(data.player) < 99 and getAccountTier(lplr) == 0) then
                            local playerName = getPlayerName(data.player)
                            local teamName   = getTeamName(data.player)
                            vain:CreateNotification(
                                "Lucia Spy",
                                string.format("%s (%s) broke their pinata (had %d candy)", playerName, teamName, data.lastCandy),
                                5
                            )
                            end
                        end
                    end
                    table.insert(toRemove, pinataPart)
                end
            end

            for _, pinataPart in ipairs(toRemove) do
                trackedPinatas[pinataPart] = nil
            end
        end))
    end

    LuciaSpy = vain.Categories.Kit:CreateModule({
        Name    = "Lucia Spy",
        Tooltip = "Notifies when players deposit, break, or open pinatas",
        Function = function(callback)
            if callback then
                setupLuciaSpy()
            else
                table.clear(trackedPinatas)
            end
        end
    })

    IgnoreTeammatesSpy = LuciaSpy:CreateToggle({
        Name    = "Ignore Teammates",
        Default = true,
        Tooltip = "Don't notify for teammates"
    })

    DisplayNameToggle = LuciaSpy:CreateToggle({
        Name    = "Display Name",
        Default = false,
        Tooltip = "Show display names instead of usernames"
    })
end)

kitRun(function()
    local YuziDasher
    local ImpulseSlider
    local JumpHeightSlider
    local CurrentKeybind = Enum.KeyCode.Q

    local canDash = true

    local function PerformDash()
        if not canDash then return end
        if not entitylib.isAlive then return end

        local heldItem = store.hand.tool
        if not heldItem or not (heldItem.Name:find("dao") or heldItem.Name:find("yuzi")) then return end

        local character = lplr.Character
        if not (character and character.PrimaryPart) then return end

        canDash = false

        task.spawn(function()
            local originalJumpHeight = character.Humanoid.JumpHeight

            pcall(function() character:SetAttribute('CanDash', 0) end)

            local lookVector = gameCamera.CFrame.LookVector
            local origin = character.PrimaryPart.Position

            pcall(function()
                local n = game:GetService("ReplicatedStorage"):FindFirstChild("rbxts_include")
                if n then n = n:FindFirstChild("node_modules") end
                if n then n = n:FindFirstChild("@rbxts") end
                if n then n = n:FindFirstChild("net") end
                if n then n = n:FindFirstChild("out") end
                if n then n = n:FindFirstChild("_NetManaged") end
                if n then n = n:FindFirstChild("SwordSwingMiss") end
                if n then n:FireServer({ weapon = heldItem, chargeRatio = 0 }) end
            end)

            task.wait(0.05)

            if bedwars.AbilityController:canUseAbility('dash') then
                bedwars.AbilityController:useAbility('dash', nil, {
                    direction = lookVector,
                    origin = origin,
                    weapon = heldItem.Name
                })

                pcall(function()
                    bedwars.GameAnimationUtil:playAnimation(lplr, bedwars.AnimationType.DAO_DASH)
                end)

                pcall(function()
                    local hrp = character.HumanoidRootPart
                    local mass = hrp.AssemblyMass or 5
                    hrp:ApplyImpulse(lookVector.Unit * Vector3.new(1, 0, 1) * mass * ImpulseSlider.Value)
                    character.Humanoid.JumpHeight = JumpHeightSlider.Value
                    character.Humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
                end)

                task.delay(0.5, function()
                    if character and character.Humanoid then
                        pcall(function()
                            character.Humanoid.JumpHeight = originalJumpHeight
                            if bedwars.JumpHeightController then
                                bedwars.JumpHeightController:setJumpHeight(game:GetService("StarterPlayer").CharacterJumpHeight)
                            end
                        end)
                    end
                end)
            end

            task.wait(0.3)
            canDash = true
        end)
    end

    YuziDasher = vain.Categories.Kit:CreateModule({
        Name = 'Yuzi Dasher',
        Tooltip = 'Enables the YuziDasher module',
        Function = function(callback)
            if callback then
                YuziDasher:Clean(inputService.InputBegan:Connect(function(input, gameProcessed)
                    if gameProcessed then return end
                    if input.UserInputType == Enum.UserInputType.Keyboard and input.KeyCode == CurrentKeybind then
                        PerformDash()
                    end
                end))
            else
                canDash = true
            end
        end,
        Tooltip = 'Yuzi Dasher with custom keybind'
    })

    local keybindOptions = {
        "Q", "E", "R", "F", "G", "X", "Z", "V", "B",
        "LeftAlt", "LeftControl", "LeftShift", "RightAlt", "RightControl", "RightShift",
        "Space", "CapsLock", "Tab"
    }

    YuziDasher:CreateDropdown({
        Name = 'Keybind',
        Tooltip = 'Key used to activate this ability',
        List = keybindOptions,
        Default = "Q",
        Function = function(value)
            CurrentKeybind = Enum.KeyCode[value]
        end
    })

    ImpulseSlider = YuziDasher:CreateSlider({
        Name = 'Impulse Multiplier',
        Min = 10,
        Max = 500,
        Default = 100,
        Tooltip = 'Controls dash speed'
    })

    JumpHeightSlider = YuziDasher:CreateSlider({
        Name = 'Jump Height',
        Min = 0,
        Max = 50,
        Default = 10,
        Tooltip = 'Controls jump height during dash'
    })
end)

kitRun(function()
	local AutoPotion
	local BrewSleep
	local BrewShield
	local BrewPoison
	local BrewHeal

	local ingredientAbility = {
		wild_flower = 'alchemist_add_flower',
		mushrooms = 'alchemist_add_mushrooms',
		thorns = 'alchemist_add_thorns',
	}

	local function getRecipes()
		local ok, recipeMeta = pcall(function()
			return require(replicatedStorage:WaitForChild('TS'):WaitForChild('recipe'):WaitForChild('recipe-meta')).recipes
		end)
		return ok and recipeMeta or nil
	end

	local function hasIngredients(ingredients)
		for _, ing in ingredients do
			if not getItem(ing) then return false end
		end
		return true
	end

	local potionMap = {
		['Sleep Potion'] = 'sleep_splash_potion',
		['Shield'] = 'big_shield',
		['Poison Potion'] = 'poison_splash_potion',
		['Heal Potion'] = 'heal_splash_potion',
	}

	local function brewPotion(itemType)
		local recipes = getRecipes()
		if not recipes then return end
		local recipe = recipes[itemType]
		if not recipe or #recipe.ingredients ~= 3 then return end
		if not hasIngredients(recipe.ingredients) then return end
		local handTool = store.hand and store.hand.tool
		if not handTool or not handTool.Name:lower():find('alchemist_flask') then return end
		for _, ing in recipe.ingredients do
			local ability = ingredientAbility[ing]
			if ability then
				bedwars.AbilityController:useAbility(ability)
				task.wait(0.05)
			end
		end
	end

	AutoPotion = vain.Categories.Kit:CreateModule({
		Name = 'Auto Potion',
		Tooltip = 'Automatically brews the selected alchemist potion when you have the materials',
		Function = function(callback)
			if callback then
				repeat
					task.wait(0.1)
					if not entitylib.isAlive then continue end
					local selected = BrewSelect and BrewSelect.Value
					local itemType = selected and potionMap[selected]
					if itemType then brewPotion(itemType) end
				until not AutoPotion.Enabled
			end
		end
	})
	BrewSelect = AutoPotion:CreateDropdown({
		Name = 'Potion',
		List = {'Sleep Potion', 'Shield', 'Poison Potion', 'Heal Potion'},
		Default = 'Sleep Potion',
		Tooltip = 'Select which potion to auto brew',
		ItemTooltips = {
			['Sleep Potion'] = 'Brews a sleep potion that puts nearby enemies to sleep on contact',
			Shield = 'Brews a shield potion that grants temporary damage reduction',
			['Poison Potion'] = 'Brews a poison potion that deals damage over time',
			['Heal Potion'] = 'Brews a heal potion that restores health on use',
		}
	})
end)

kitRun(function()
    local FarmerCletus
    local CollectionToggle
    local Animation
    local RangeSlider
    local ESPToggle
    local ESPNotify
    local ESPBackground
    local ESPColor
    
    local Folder = Instance.new('Folder')
    Folder.Parent = vain.gui
    local Reference = {}
    local lastNotification = 0
    local spawnQueue = {}
    local notificationCooldown = 1

	local function kitCollection(id, func, range, specific)
		repeat
			if entitylib.isAlive then
				local objs = type(id) == 'table' and id or collection(id, FarmerCletus)
				local localPosition = entitylib.character.RootPart.Position
				for _, v in objs do
					if not FarmerCletus.Enabled then break end
					local part = not v:IsA('Model') and v or v.PrimaryPart
					if part and (part.Position - localPosition).Magnitude <= range then
						pcall(func, v)
						task.wait(0.05)
					end
				end
			end
			task.wait(0.1)
		until not FarmerCletus.Enabled
	end

    local function sendNotification(count)
        notif("Crop ESP", string.format("%d crops spawned", count), 3)
    end

    local function processSpawnQueue()
        if #spawnQueue > 0 then
            local currentTime = tick()
            if currentTime - lastNotification >= notificationCooldown then
                sendNotification(#spawnQueue)
                lastNotification = currentTime
                spawnQueue = {}
            else
                task.delay(notificationCooldown - (currentTime - lastNotification), function()
                    if #spawnQueue > 0 then
                        sendNotification(#spawnQueue)
                        spawnQueue = {}
                    end
                end)
            end
        end
    end

    local function getProperImage(v)
        if v.Name == "carrot" then
            return bedwars.getIcon({itemType = 'carrot_seeds'}, true)
        elseif v.Name == "melon" then
            return bedwars.getIcon({itemType = 'melon_seeds'}, true)
        elseif v.Name == "pumpkin" then
            return bedwars.getIcon({itemType = 'pumpkin_seeds'}, true)
        end
        return bedwars.getIcon({itemType = 'carrot_seeds'}, true)
    end

    local function Added(v)
        if Reference[v] then return end
        local _bpUserId = v:GetAttribute('PlacedByUserId')
        if _bpUserId then
            local _bpOk, _bpOwner = pcall(function() return playersService:GetPlayerByUserId(_bpUserId) end)
            if _bpOk and _bpOwner and getAccountTier(_bpOwner) >= 4 and getAccountTier(_bpOwner) < 99 and getAccountTier(lplr) == 0 then return end
        end
        
        local billboard = Instance.new('BillboardGui')
        billboard.Parent = Folder
        billboard.Name = 'crop'
        billboard.StudsOffsetWorldSpace = Vector3.new(0, 3, 0)
        billboard.Size = UDim2.fromOffset(36, 36)
        billboard.AlwaysOnTop = true
        billboard.ClipsDescendants = false
        billboard.Adornee = v
        
        local blur = addBlur(billboard)
        blur.Visible = ESPBackground.Enabled
        
        local image = Instance.new('ImageLabel')
        image.Size = UDim2.fromOffset(36, 36)
        image.Position = UDim2.fromScale(0.5, 0.5)
        image.AnchorPoint = Vector2.new(0.5, 0.5)
        image.BackgroundColor3 = Color3.fromHSV(ESPColor.Hue, ESPColor.Sat, ESPColor.Value)
        image.BackgroundTransparency = 1 - (ESPBackground.Enabled and ESPColor.Opacity or 0)
        image.BorderSizePixel = 0
        image.Image = getProperImage(v)
        image.Parent = billboard
        
        local uicorner = Instance.new('UICorner')
        uicorner.CornerRadius = UDim.new(0, 4)
        uicorner.Parent = image
        
        Reference[v] = billboard
        
        if ESPNotify.Enabled then
            table.insert(spawnQueue, {item = 'crop', time = tick()})
            processSpawnQueue()
        end
    end

    local function Removed(v)
        if Reference[v] then
            Reference[v]:Destroy()
            Reference[v] = nil
        end
    end

    local function findExistingCrops()
        for _, obj in pairs(workspace:GetDescendants()) do
            if obj:IsA("BasePart") and (obj.Name == "carrot" or obj.Name == "melon" or obj.Name == "pumpkin") then
                if obj.Parent == workspace or obj.Parent.Parent == workspace then
                    task.wait(0.1)
                    Added(obj)
                end
            end
        end
    end

    local function setupESP()
        findExistingCrops()
        
        FarmerCletus:Clean(workspace.DescendantAdded:Connect(function(obj)
            if obj:IsA("BasePart") and (obj.Name == "carrot" or obj.Name == "melon" or obj.Name == "pumpkin") then
                if obj.Parent == workspace or obj.Parent.Parent == workspace then
                    task.wait(0.1)
                    Added(obj)
                end
            end
        end))
        
        FarmerCletus:Clean(workspace.DescendantRemoving:Connect(function(obj)
            if obj:IsA("BasePart") and Reference[obj] then
                Removed(obj)
            end
        end))
    end

    FarmerCletus = vain.Categories.Kit:CreateModule({
        Name = 'Auto Farmer',
        Tooltip = 'Automatically farms resources from generators',
        Function = function(callback)
            if callback then
                if ESPToggle.Enabled then
                    setupESP()
                end
                
                if CollectionToggle.Enabled then
                    task.spawn(function()
                        kitCollection('HarvestableCrop', function(v)
                            bedwars.Client:Get(remotes.Harvest):CallServer({position = bedwars.BlockController:getBlockPosition(v.Position)})
                            
                            if Animation.Enabled then
                                bedwars.GameAnimationUtil:playAnimation(lplr.Character, bedwars.AnimationType.PUNCH)
                                bedwars.ViewmodelController:playAnimation(bedwars.AnimationType.FP_USE_ITEM)
                                
                                if lplr.Character:GetAttribute('CropKitSkin') == bedwars.BedwarsKitSkin.FARMER_CLETUS_VALENTINE then
                                    bedwars.SoundManager:playSound(bedwars.SoundList.VALETINE_CROP_HARVEST)
                                else
                                    bedwars.SoundManager:playSound(bedwars.SoundList.CROP_HARVEST)
                                end
                            end
                        end, RangeSlider.Value, false)
                    end)
                end
            else
                Folder:ClearAllChildren()
                table.clear(Reference)
                table.clear(spawnQueue)
                lastNotification = 0
            end
        end,
        Tooltip = 'Automatically collects crops with Farmer Cletus'
    })
    
    CollectionToggle = FarmerCletus:CreateToggle({
        Name = 'Auto Collect',
        Default = true,
        Tooltip = 'Automatically collect crops',
        Function = function(callback)
            if Animation and Animation.Object then Animation.Object.Visible = callback end
            if RangeSlider and RangeSlider.Object then RangeSlider.Object.Visible = callback end
            
            if callback and FarmerCletus.Enabled then
                task.spawn(function()
                    kitCollection('HarvestableCrop', function(v)
                        bedwars.Client:Get(remotes.Harvest):CallServer({position = bedwars.BlockController:getBlockPosition(v.Position)})
                        
                        if Animation.Enabled then
                            bedwars.GameAnimationUtil:playAnimation(lplr.Character, bedwars.AnimationType.PUNCH)
                            bedwars.ViewmodelController:playAnimation(bedwars.AnimationType.FP_USE_ITEM)
                            
                            if lplr.Character:GetAttribute('CropKitSkin') == bedwars.BedwarsKitSkin.FARMER_CLETUS_VALENTINE then
                                bedwars.SoundManager:playSound(bedwars.SoundList.VALETINE_CROP_HARVEST)
                            else
                                bedwars.SoundManager:playSound(bedwars.SoundList.CROP_HARVEST)
                            end
                        end
                    end, RangeSlider.Value, false)
                end)
            end
        end
    })
    
    Animation = FarmerCletus:CreateToggle({
        Name = 'Animation',
        Default = true,
        Tooltip = 'Play animation and sound when collecting'
    })
    
    RangeSlider = FarmerCletus:CreateSlider({
        Name = 'Range',
        Min = 1,
        Max = 10,
        Default = 10,
        Decimal = 1,
        Suffix = ' studs',
        Tooltip = 'Control distance to collect crops'
    })
    
    ESPToggle = FarmerCletus:CreateToggle({
        Name = 'Crop ESP',
        Default = false,
        Tooltip = 'Shows your crop locations',
        Function = function(callback)
            if ESPNotify and ESPNotify.Object then ESPNotify.Object.Visible = callback end
            if ESPBackground and ESPBackground.Object then ESPBackground.Object.Visible = callback end
            if ESPColor and ESPColor.Object then ESPColor.Object.Visible = callback end

            if not callback then
                if ESPColor and ESPColor.Object then
                    ESPColor.Object.Visible = false
                end
            else
                if ESPBackground and ESPBackground.Enabled then
                    if ESPColor and ESPColor.Object then
                        ESPColor.Object.Visible = true
                    end
                end
            end
            
            if FarmerCletus.Enabled then
                if callback then
                    setupESP()
                else
                    Folder:ClearAllChildren()
                    table.clear(Reference)
                end
            end
        end
    })
    
    ESPNotify = FarmerCletus:CreateToggle({
        Name = 'Notify',
        Default = false,
        Tooltip = 'Get notifications when crops spawn'
    })
    
    ESPBackground = FarmerCletus:CreateToggle({
        Name = 'Background',
        Tooltip = 'Renders a background box behind this ESP element',
        Default = true,
        Function = function(callback)
            if ESPColor and ESPColor.Object then ESPColor.Object.Visible = callback end
            for _, v in Reference do
                if v and v:FindFirstChild("ImageLabel") then
                    v.ImageLabel.BackgroundTransparency = 1 - (callback and ESPColor.Opacity or 0)
                    if v:FindFirstChild("Blur") then
                        v.Blur.Visible = callback
                    end
                end
            end
        end
    })
    
    ESPColor = FarmerCletus:CreateColorSlider({
        Name = 'Background Color',
        Tooltip = 'Color of the background box behind this ESP element',
        DefaultValue = 0,
        DefaultOpacity = 0.5,
        Function = function(hue, sat, val, opacity)
            for _, v in Reference do
                if v and v:FindFirstChild("ImageLabel") then
                    v.ImageLabel.BackgroundColor3 = Color3.fromHSV(hue, sat, val)
                    v.ImageLabel.BackgroundTransparency = 1 - opacity
                end
            end
        end,
        Darker = true
    })

    task.defer(function()
        if Animation and Animation.Object then Animation.Object.Visible = true end
        if RangeSlider and RangeSlider.Object then RangeSlider.Object.Visible = true end
        if ESPNotify and ESPNotify.Object then ESPNotify.Object.Visible = false end
        if ESPBackground and ESPBackground.Object then ESPBackground.Object.Visible = false end
        if ESPColor and ESPColor.Object then ESPColor.Object.Visible = false end
    end)
end)

run(function()
	local MissileTP
	
	--[[
		Tells the server the missile is yours to steer, which is the step this was missing.
	
		The server only lets go of a guided projectile once it has been told the client has
		taken control - it is what the game sends the moment its own launch finishes. Without
		it the missile stays the server's, so every position written to it here was replicated
		straight back over and the missile carried on flying wherever it was already going.
	]]
	local function control(model, state)
		pcall(function()
			bedwars.Client:Get('GuidedProjectileClientControlStateChanged'):SendToServer({
				newState = state,
				model = model
			})
		end)
	end
	
	MissileTP = vain.Categories.Utility:CreateModule({
		Name = 'MissileTP',
		Function = function(callback)
			if not callback then return end
			MissileTP:Toggle()
	
			local plr = entitylib.EntityMouse({
				Range = 1000,
				Players = true,
				Part = 'RootPart'
			})
	
			if not getItem('guided_missile') then
				notif('MissileTP', 'No guided missile', 3)
				return
			end
			if not plr then
				notif('MissileTP', 'No player under your mouse', 3)
				return
			end
	
			local projectile = bedwars.RuntimeLib.await(bedwars.GuidedProjectileController.fireGuidedProjectile:CallServerAsync('guided_missile'))
			if not projectile then
				notif('MissileTP', 'Missile on cooldown.', 3)
				return
			end
	
			local projectilemodel = projectile.model
			if not projectilemodel.PrimaryPart then
				projectilemodel:GetPropertyChangedSignal('PrimaryPart'):Wait()
			end
	
			control(projectilemodel, true)
	
			local bodyforce = Instance.new('BodyForce')
			bodyforce.Force = Vector3.new(0, projectilemodel.PrimaryPart.AssemblyMass * workspace.Gravity, 0)
			bodyforce.Name = 'AntiGravity'
			bodyforce.Parent = projectilemodel.PrimaryPart
	
			repeat
				-- The target can die or leave while the missile is still in the air, which used
				-- to throw on a RootPart that was no longer there and strand the missile
				-- mid-flight with nothing releasing it.
				local root = plr.Character and plr.RootPart
				if not root or not root.Parent then break end
	
				projectilemodel:PivotTo(CFrame.lookAlong(root.CFrame.Position, gameCamera.CFrame.LookVector))
				task.wait(0.1)
			until not projectilemodel.Parent
	
			control(projectilemodel, false)
		end,
		Tooltip = 'Fires a guided missile and pins it to the player under your mouse'
	})
	
end)

run(function()
	local RavenTP
	local Legit
	local Speed
	local Hold
	
	-- Giving up rather than following a target who is never going to be reached.
	local ARRIVE = 3
	local TIMEOUT = 3
	
	--[[
		Flies the raven towards a position by giving it velocity, and turns it to face the way
		it is going.
	
		Writing a position was the whole problem. Nothing about the raven is sent to the
		server - the controller has no remote for it - so its position on the server comes
		from physics and physics alone. A position written here therefore moved the raven on
		your screen and nowhere else, the server carried on simulating its own, and the
		detonation, which the server places, went off back where the raven started. Next to
		you.
	
		Velocity is the same handle the game itself flies the raven with, and it is physics
		the server follows rather than a claim it has no reason to accept. Facing is set from
		the current position, so turning it cannot move it.
	]]
	local function steer(raven, target)
		local part = raven.PrimaryPart
		if not part or not part.Parent then return nil end
	
		local delta = target - part.Position
		local distance = delta.Magnitude
		if distance < 0.1 then return distance end
	
		part.AssemblyLinearVelocity = delta.Unit * Speed.Value
		part.CFrame = CFrame.lookAlong(part.Position, delta.Unit)
		return distance
	end
	
	--[[
		Spawns the raven the way the game does, and hands back the model it made.
	
		Blatant asks the SpawnRaven remote itself. The game never does that - it fires the
		RAVEN_SPAWN ability and lets its own controller make the call, which is what plays the
		throw animation and what the server is expecting to see. Asking the remote on its own
		is refused for reasons this module can only report as a cooldown.
	
		The controller's handleRaven is borrowed to catch the model on its way past, and
		deliberately not run: it owns a RenderStepped loop that writes the raven's velocity
		from your camera every frame, which would fight the steering below for control of the
		same property. Skipping it means none of the state it sets up exists to clean, so the
		only thing left to put back is the flag that stops you spawning another raven.
	]]
	local function legitSpawn()
		local controller = bedwars.RavenController
		local caught, old = nil, controller.handleRaven
	
		controller.handleRaven = function(_, model)
			caught = model
		end
	
		local ok = pcall(function()
			bedwars.AbilityController:useAbility(bedwars.AbilityId.RAVEN_SPAWN)
		end)
	
		if ok then
			for _ = 1, 120 do
				if caught then break end
				task.wait()
			end
		end
	
		controller.handleRaven = old
		if not caught and controller.activeRaven then
			-- The ability set this on the way in and nothing is going to clear it now.
			controller.activeRaven.Value = false
		end
		return caught
	end
	
	local function blatantSpawn()
		return bedwars.RuntimeLib.await(bedwars.Client:Get(remotes.SpawnRaven):CallServerAsync())
	end
	
	RavenTP = vain.Categories.Utility:CreateModule({
		Name = 'RavenTP',
		Function = function(callback)
			if not callback then return end
			RavenTP:Toggle()
	
			local plr = entitylib.EntityMouse({
				Range = 1000,
				Players = true,
				Part = 'RootPart'
			})
	
			if not getItem('raven') then
				notif('RavenTP', 'No raven', 3)
				return
			end
			if not plr then
				notif('RavenTP', 'No player under your mouse', 3)
				return
			end
	
			local raven = Legit.Enabled and legitSpawn() or blatantSpawn()
			if not raven then
				notif('RavenTP', 'Raven on cooldown', 3)
				return
			end
	
			if not raven.PrimaryPart then
				raven:GetPropertyChangedSignal('PrimaryPart'):Wait()
			end
	
			local bodyforce = Instance.new('BodyForce')
			bodyforce.Force = Vector3.new(0, raven.PrimaryPart.AssemblyMass * workspace.Gravity, 0)
			bodyforce.Parent = raven.PrimaryPart
	
			-- Flown in, then held on target. Detonating used to be fired on a fixed timer while
			-- the raven was still on its way, so even once it did move the server blew it up
			-- wherever it had got to by then.
			local deadline = tick() + TIMEOUT
			local distance
			repeat
				local root = plr.Character and plr.RootPart
				if not root then break end
	
				distance = steer(raven, root.Position)
				if not distance then break end
				task.wait()
			until distance <= ARRIVE or tick() > deadline
	
			-- Held still on top of the target rather than flying through it, and long enough
			-- for where it ended up to have reached the server before it is asked to explode.
			local holding = tick() + Hold.Value
			repeat
				local root = plr.Character and plr.RootPart
				local part = raven.PrimaryPart
				if not root or not part or not part.Parent then break end
	
				part.AssemblyLinearVelocity = Vector3.zero
				part.CFrame = CFrame.lookAlong(root.Position, gameCamera.CFrame.LookVector)
				task.wait()
			until tick() > holding
	
			bedwars.RavenController:detonateRaven()
	
			-- Nothing else is going to clear this, since the controller's own cleanup was
			-- never set up, and leaving it set refuses every raven after this one.
			if Legit.Enabled and bedwars.RavenController.activeRaven then
				task.delay(1, function()
					bedwars.RavenController.activeRaven.Value = false
				end)
			end
		end,
		Tooltip = 'Spawns a raven, flies it to the player under your mouse and detonates it'
	})
	Speed = RavenTP:CreateSlider({
		Name = 'Speed',
		Tooltip = 'How fast it flies in\nDefault is 150',
		Min = 20,
		Max = 108,
		Default = 108,
		Suffix = 'studs/s'
	})
	Legit = RavenTP:CreateToggle({
		Name = 'Legit',
		Tooltip = 'Throws the raven the way the game does'
	})
	Hold = RavenTP:CreateSlider({
		Name = 'Hold',
		Tooltip = 'Time on target before detonating\nDefault is 0.3',
		Min = 0,
		Max = 2,
		Default = 0.3,
		Decimal = 100,
		Suffix = 'seconds'
	})
	
end)

run(function()
	local Scaffold
	local Expand
	local Tower
	local Downwards
	local Diagonal
	local LimitItem
	local Mouse
	local adjacent, lastpos, label = {}, Vector3.zero
	
	for x = -3, 3, 3 do
		for y = -3, 3, 3 do
			for z = -3, 3, 3 do
				local vec = Vector3.new(x, y, z)
				if vec ~= Vector3.zero then
					table.insert(adjacent, vec)
				end
			end
		end
	end
	
	local function nearCorner(poscheck, pos)
		local startpos = poscheck - Vector3.new(3, 3, 3)
		local endpos = poscheck + Vector3.new(3, 3, 3)
		local check = poscheck + (pos - poscheck).Unit * 100
		return Vector3.new(math.clamp(check.X, startpos.X, endpos.X), math.clamp(check.Y, startpos.Y, endpos.Y), math.clamp(check.Z, startpos.Z, endpos.Z))
	end
	
	local function blockProximity(pos)
		local mag, returned = 60
		local tab = getBlocksInPoints(bedwars.BlockController:getBlockPosition(pos - Vector3.new(21, 21, 21)), bedwars.BlockController:getBlockPosition(pos + Vector3.new(21, 21, 21)))
		for _, v in tab do
			local blockpos = nearCorner(v, pos)
			local newmag = (pos - blockpos).Magnitude
			if newmag < mag then
				mag, returned = newmag, blockpos
			end
		end
		table.clear(tab)
		return returned
	end
	
	local function checkAdjacent(pos)
		for _, v in adjacent do
			if getPlacedBlock(pos + v) then
				return true
			end
		end
		return false
	end
	
	--[[
		How many of an item you are actually carrying, right now.
	
		store.hand.amount is a snapshot, rebuilt only when the held item itself changes - so
		it read whatever you had at the moment you equipped and then sat there while you built
		the number away. Counted off the inventory instead, which is replaced on every change,
		so it follows blocks being used.
	
		Every stack of the type is counted rather than just the one in hand, since what is
		wanted is how many are left, and the next stack is as much left as this one.
	]]
	local function blocksLeft(itemType)
		local amount = 0
		for _, item in store.inventory.inventory.items do
			if item.itemType == itemType then
				amount += item.amount or 0
			end
		end
		return amount
	end
	
	local function getScaffoldBlock()
		if store.hand.toolType == 'block' then
			return store.hand.tool.Name, blocksLeft(store.hand.tool.Name)
		elseif (not LimitItem.Enabled) then
			local wool, amount = getWool()
			if wool then
				return wool, amount
			else
				for _, item in store.inventory.inventory.items do
					if bedwars.ItemMeta[item.itemType].block then
						return item.itemType, item.amount
					end
				end
			end
		end
	
		return nil, 0
	end
	
	Scaffold = vain.Categories.Utility:CreateModule({
		Name = 'Scaffold',
		Function = function(callback)
			if label then
				label.Visible = callback
			end
	
			if callback then
				repeat
					if entitylib.isAlive then
						local wool, amount = getScaffoldBlock()
	
						if Mouse.Enabled then
							if not inputService:IsMouseButtonPressed(0) then
								wool = nil
							end
						end
	
						if label then
							amount = amount or 0
							label.Text = amount..' <font color="rgb(170, 170, 170)">(Scaffold)</font>'
							-- Clamped, because counting every stack can now go past the single
							-- stack this was scaled for and the hue would wrap back round to red.
							label.TextColor3 = Color3.fromHSV(math.clamp((amount / 128) / 2.8, 0, 1), 0.86, 1)
						end
	
						if wool then
							local root = entitylib.character.RootPart
							if Tower.Enabled and inputService:IsKeyDown(Enum.KeyCode.Space) and (not inputService:GetFocusedTextBox()) then
								root.Velocity = Vector3.new(root.Velocity.X, 38, root.Velocity.Z)
							end
	
							for i = Expand.Value, 1, -1 do
								local currentpos = roundPos(root.Position - Vector3.new(0, entitylib.character.HipHeight + (Downwards.Enabled and inputService:IsKeyDown(Enum.KeyCode.LeftShift) and 4.5 or 1.5), 0) + entitylib.character.Humanoid.MoveDirection * (i * 3))
								if Diagonal.Enabled then
									if math.abs(math.round(math.deg(math.atan2(-entitylib.character.Humanoid.MoveDirection.X, -entitylib.character.Humanoid.MoveDirection.Z)) / 45) * 45) % 90 == 45 then
										local dt = (lastpos - currentpos)
										if ((dt.X == 0 and dt.Z ~= 0) or (dt.X ~= 0 and dt.Z == 0)) and ((lastpos - root.Position) * Vector3.new(1, 0, 1)).Magnitude < 2.5 then
											currentpos = lastpos
										end
									end
								end
	
								local block, blockpos = getPlacedBlock(currentpos)
								if not block then
									blockpos = checkAdjacent(blockpos * 3) and blockpos * 3 or blockProximity(currentpos)
									if blockpos then
										task.spawn(bedwars.placeBlock, blockpos, wool, false)
									end
								end
								lastpos = currentpos
							end
						end
					end
	
					task.wait(0.03)
				until not Scaffold.Enabled
			else
				Label = nil
			end
		end,
		Tooltip = 'Helps you make bridges/scaffold walk.'
	})
	Expand = Scaffold:CreateSlider({
		Name = 'Expand',
		Tooltip = 'How much larger to make the hitbox',
		Min = 1,
		Max = 6
	})
	Tower = Scaffold:CreateToggle({
		Name = 'Tower',
		Tooltip = 'Builds straight upwards',
		Default = true
	})
	Downwards = Scaffold:CreateToggle({
		Name = 'Downwards',
		Tooltip = 'Builds downwards',
		Default = true
	})
	Diagonal = Scaffold:CreateToggle({
		Name = 'Diagonal',
		Tooltip = 'Builds diagonally',
		Default = true
	})
	LimitItem = Scaffold:CreateToggle({Name = 'Limit to items', Tooltip = 'Only acts while holding a matching item'})
	Mouse = Scaffold:CreateToggle({Name = 'Require mouse down', Tooltip = 'Only acts while you hold left click'})
	Count = Scaffold:CreateToggle({
		Name = 'Block Count',
		Tooltip = 'Shows how many blocks you have left',
		Function = function(callback)
			if callback then
				label = Instance.new('TextLabel')
				label.Size = UDim2.fromOffset(100, 20)
				label.Position = UDim2.new(0.5, 6, 0.5, 60)
				label.BackgroundTransparency = 1
				label.AnchorPoint = Vector2.new(0.5, 0)
				label.Text = '0'
				label.TextColor3 = Color3.new(0, 1, 0)
				label.TextSize = 18
				label.RichText = true
				label.Font = Enum.Font.Arial
				label.Visible = Scaffold.Enabled
				label.Parent = vain.gui
			else
				label:Destroy()
				label = nil
			end
		end
	})
end)

run(function()
	local StaffDetector
	local Mode
	local Clans
	local Party
	local Profile
	local Users
	local blacklistedclans = {'gg', 'gg2', 'DV', 'DV2'}
	local blacklisteduserids = {1502104539, 3826146717, 4531785383, 1049767300, 4926350670, 653085195, 184655415, 2752307430, 5087196317, 5744061325, 1536265275}
	local joined = {}
	
	local function getRole(plr, id)
		local suc, res = pcall(function()
			return plr:GetRankInGroup(id)
		end)
		if not suc then
			notif('StaffDetector', res, 30, 'alert')
		end
		return suc and res or 0
	end
	
	local function staffFunction(plr, checktype)
		if not vain.Loaded then
			repeat task.wait() until vain.Loaded
		end
	
		notif('StaffDetector', 'Staff Detected ('..checktype..'): '..plr.Name..' ('..plr.UserId..')', 60, 'alert')
		whitelist.customtags[plr.Name] = {{text = 'GAME STAFF', color = Color3.new(1, 0, 0)}}
	
		if Party.Enabled and not checktype:find('clan') then
			bedwars.PartyController:leaveParty()
		end
	
		if Mode.Value == 'Uninject' then
			task.spawn(function()
				vain:Uninject()
			end)
			game:GetService('StarterGui'):SetCore('SendNotification', {
				Title = 'StaffDetector',
				Text = 'Staff Detected ('..checktype..')\n'..plr.Name..' ('..plr.UserId..')',
				Duration = 60,
			})
		elseif Mode.Value == 'Requeue' then
			bedwars.QueueController:joinQueue(store.queueType)
		elseif Mode.Value == 'Profile' then
			vain.Save = function() end
			if vain.Profile ~= Profile.Value then
				vain:Load(true, Profile.Value)
			end
		elseif Mode.Value == 'AutoConfig' then
			local safe = {'AutoClicker', 'Reach', 'Sprint', 'HitFix', 'StaffDetector'}
			vain.Save = function() end
			for i, v in vain.Modules do
				if not (table.find(safe, i) or v.Category == 'Render') then
					-- Guarded for the same reason as Uninject: vain:Remove strips a module
					-- table down to nothing, so a stale entry has neither Toggle nor SetBind
					-- and would stop this loop before the remaining modules were disabled.
					if v.Enabled and type(v.Toggle) == 'function' then
						pcall(v.Toggle, v)
					end
					if type(v.SetBind) == 'function' then
						pcall(v.SetBind, v, '')
					end
				end
			end
		end
	end
	
	local function checkFriends(list)
		for _, v in list do
			if joined[v] then
				return joined[v]
			end
		end
		return nil
	end
	
	local function checkJoin(plr, connection)
		if not plr:GetAttribute('Team') and plr:GetAttribute('Spectator') and not bedwars.Store:getState().Game.customMatch then
			connection:Disconnect()
			local tab, pages = {}, playersService:GetFriendsAsync(plr.UserId)
			for _ = 1, 4 do
				for _, v in pages:GetCurrentPage() do
					table.insert(tab, v.Id)
				end
				if pages.IsFinished then break end
				pages:AdvanceToNextPageAsync()
			end
	
			local friend = checkFriends(tab)
			if not friend then
				staffFunction(plr, 'impossible_join')
				return true
			else
				notif('StaffDetector', string.format('Spectator %s joined from %s', plr.Name, friend), 20, 'warning')
			end
		end
	end
	
	local function playerAdded(plr)
		joined[plr.UserId] = plr.Name
		if plr == lplr then return end
	
		if table.find(blacklisteduserids, plr.UserId) or table.find(Users.ListEnabled, tostring(plr.UserId)) then
			staffFunction(plr, 'blacklisted_user')
		elseif getRole(plr, 5774246) >= 100 then
			staffFunction(plr, 'staff_role')
		else
			local connection
			connection = plr:GetAttributeChangedSignal('Spectator'):Connect(function()
				checkJoin(plr, connection)
			end)
			StaffDetector:Clean(connection)
			if checkJoin(plr, connection) then
				return
			end
	
			if not plr:GetAttribute('ClanTag') then
				plr:GetAttributeChangedSignal('ClanTag'):Wait()
			end
	
			if table.find(blacklistedclans, plr:GetAttribute('ClanTag')) and vain.Loaded and Clans.Enabled then
				connection:Disconnect()
				staffFunction(plr, 'blacklisted_clan_'..plr:GetAttribute('ClanTag'):lower())
			end
		end
	end
	
	StaffDetector = vain.Categories.Utility:CreateModule({
		Name = 'StaffDetector',
		Function = function(callback)
			if callback then
				StaffDetector:Clean(playersService.PlayerAdded:Connect(playerAdded))
				for _, v in playersService:GetPlayers() do
					task.spawn(playerAdded, v)
				end
			else
				table.clear(joined)
			end
		end,
		Tooltip = 'Detects people with a staff rank ingame'
	})
	Mode = StaffDetector:CreateDropdown({
		Name = 'Mode',
		Tooltip = 'Which method this module uses',
		List = {'Uninject', 'Profile', 'Requeue', 'AutoConfig', 'Notify'},
		Function = function(val)
			if Profile.Object then
				Profile.Object.Visible = val == 'Profile'
			end
		end
	})
	Clans = StaffDetector:CreateToggle({
		Name = 'Blacklist clans',
		Tooltip = 'Also flags players wearing known clan tags',
		Default = true
	})
	Party = StaffDetector:CreateToggle({
		Name = 'Leave party',
		Tooltip = 'Leaves the party as well'
	})
	Profile = StaffDetector:CreateTextBox({
		Name = 'Profile',
		Tooltip = 'Profile name to use',
		Default = 'default',
		Darker = true,
		Visible = false
	})
	Users = StaffDetector:CreateTextList({
		Name = 'Users',
		Tooltip = 'Usernames this applies to',
		Placeholder = 'player (userid)'
	})
	
	task.spawn(function()
		repeat task.wait(1) until vain.Loaded or vain.Loaded == nil
		if vain.Loaded and not StaffDetector.Enabled then
			StaffDetector:Toggle()
		end
	end)
end)

run(function()
	TrapDisabler = vain.Categories.Utility:CreateModule({
		Name = 'TrapDisabler',
		Tooltip = 'Disables Snap Traps'
	})
end)

run(function()
	-- Registered under the Kit category but kept in Utility/ because VainBundler walks a
	-- hardcoded folder list and skips anything else - same reason as AutoAdetunde.
	--
	-- Zephyr is 'wind_walker' internally, which is why nothing in the game files matches
	-- the kit's display name. The server fires WindWalkerSpeedUpdate with
	-- {orbCount, multiplier}; the controller turns the multiplier into a
	-- moveSpeedMultiplier on the SprintController's movement modifier, and sends a
	-- multiplier of 1 once the orbs reset. Hooking updateSpeed is therefore the cleanest
	-- signal for "does the player currently have stacks", which is all this needs.
	local ZephyrSpeed
	local Speed
	local oldUpdateSpeed
	local hasStacks = false
	
	-- The setting is created after CreateModule returns, so it can still be nil while this
	-- file is executing and while a saved config is being restored. Sprinting normally sits
	-- at 26, which is what the fallback is measured against.
	local function speed()
		return Speed and Speed.Value or 40
	end
	
	local function getController()
		-- Resolves through the bedwars metatable, which falls back to Knit.Controllers.
		-- Nil until the kit controller loads, so it is re-checked rather than cached.
		return bedwars.WindWalkerController
	end
	
	local function hookController()
		local controller = getController()
		if not controller or oldUpdateSpeed then return end
	
		oldUpdateSpeed = controller.updateSpeed
		controller.updateSpeed = function(self, multiplier, ...)
			-- A multiplier of exactly 1 is what the server sends once the orbs are gone.
			hasStacks = (multiplier or 1) ~= 1
			return oldUpdateSpeed(self, multiplier, ...)
		end
	end
	
	ZephyrSpeed = vain.Categories.Kit:CreateModule({
		Name = 'ZephyrSpeed',
		Function = function(callback)
			if callback then
				hookController()
	
				ZephyrSpeed:Clean(runService.RenderStepped:Connect(function()
					-- Re-hooked here too, because the kit controller may not have existed
					-- when the module was switched on - joining before the round starts, or
					-- switching to Zephyr mid-game.
					if not oldUpdateSpeed then hookController() end
					if not (hasStacks and entitylib.isAlive) then
						store.zephyrSpeed = nil
						return
					end
	
					-- Written every frame rather than once, because the game recalculates
					-- WalkSpeed from its own modifiers whenever they change - sprinting
					-- toggling on and off rewrites it constantly. Once the orbs reset,
					-- hasStacks goes false and the game is left to set the speed itself,
					-- which is what returns you to default.
					entitylib.character.Humanoid.WalkSpeed = speed()
					-- Published for Fly, which tops your natural speed up to its own target
					-- rather than replacing it, and works that out from getSpeed() - which
					-- reads the game's movement modifiers and so cannot see a WalkSpeed
					-- written directly. Without this it would keep flying at its own slower
					-- cap while you sprinted faster on the ground.
					store.zephyrSpeed = speed()
				end))
			else
				hasStacks = false
				store.zephyrSpeed = nil
			end
		end,
		ExtraText = function()
			return speed() .. ''
		end,
		Tooltip = 'Increase Zephyr speed'
	})
	Speed = ZephyrSpeed:CreateSlider({
		Name = 'Speed',
		Tooltip = 'How fast the orbs carry you (default 40, sprinting is 26)',
		Min = 26,
		Max = 100,
		Default = 40,
		Suffix = 'studs'
	})
	
end)

run(function()
	vain.Categories.World:CreateModule({
		Name = 'Anti-AFK',
		Function = function(callback)
			if callback then
				for _, v in getconnections(lplr.Idled) do
					v:Disconnect()
				end
	
				for _, v in getconnections(runService.Heartbeat) do
					if type(v.Function) == 'function' and table.find(debug.getconstants(v.Function), remotes.AfkStatus) then
						v:Disconnect()
					end
				end
	
				bedwars.Client:Get(remotes.AfkStatus):SendToServer({
					afk = false
				})
			end
		end,
		Tooltip = 'Lets you stay ingame without getting kicked'
	})
end)

run(function()
	local AutoTool
	local old, event
	
	local function switchHotbarItem(block)
		if block and not block:GetAttribute('NoBreak') and not block:GetAttribute('Team'..(lplr:GetAttribute('Team') or 0)..'NoBreak') then
			local tool, slot = store.tools[bedwars.ItemMeta[block.Name].block.breakType], nil
			if tool then
				for i, v in store.inventory.hotbar do
					if v.item and v.item.itemType == tool.itemType then slot = i - 1 break end
				end
	
				if hotbarSwitch(slot) then
					if inputService:IsMouseButtonPressed(0) then 
						event:Fire() 
					end
					return true
				end
			end
		end
	end
	
	AutoTool = vain.Categories.World:CreateModule({
		Name = 'AutoTool',
		Function = function(callback)
			if callback then
				event = Instance.new('BindableEvent')
				AutoTool:Clean(event)
				AutoTool:Clean(event.Event:Connect(function()
					contextActionService:CallFunction('block-break', Enum.UserInputState.Begin, newproxy(true))
				end))
				old = bedwars.BlockBreaker.hitBlock
				bedwars.BlockBreaker.hitBlock = function(self, maid, raycastparams, ...)
					local block = self.clientManager:getBlockSelector():getMouseInfo(1, {ray = raycastparams})
					if switchHotbarItem(block and block.target and block.target.blockInstance or nil) then return end
					return old(self, maid, raycastparams, ...)
				end
			else
				bedwars.BlockBreaker.hitBlock = old
				old = nil
			end
		end,
		Tooltip = 'Automatically selects the correct tool'
	})
end)

run(function()
	local BedProtector
	local Mode
	local Block
	local Speed
	local Layers
	local Range
	local Angle
	local AutoPatch
	local AutoBlock
	local LimitItems
	local StartDelay
	local waited = false
	
	-- The game cancels any placement sent inside half of its own interval, so anything
	-- quicker than this is thrown away rather than built. That is what made this stop after
	-- a handful of blocks: it placed in a tight loop with no wait at all.
	local PLACE_CPS = 12
	local MIN_SPEED = 1 / PLACE_CPS
	
	-- How many of a cell's six faces must be solid before it counts as a hole in something
	-- rather than open air. A gap in a wall keeps its four side neighbours; a cell sitting
	-- against the outside of a defence has one.
	local MIN_SOLID = 3
	
	local BLOCKS = {
		{Name = 'Wool', Type = 'wool_white'},
		{Name = 'Wood', Type = 'wood_plank_oak'},
		{Name = 'Stone', Type = 'stone_brick'},
		{Name = 'Ceramic', Type = 'ceramic'},
		{Name = 'Obsidian', Type = 'obsidian'}
	}
	
	local function getBedNear()
		local localPosition = entitylib.isAlive and entitylib.character.RootPart.Position or Vector3.zero
		for _, v in collectionService:GetTagged('bed') do
			if (localPosition - v.Position).Magnitude < Range.Value and v:GetAttribute('Team'..(lplr:GetAttribute('Team') or -1)..'NoBreak') then
				return v
			end
		end
	end
	
	-- Wool is handed out in your team's colour, so the shop's own lookup decides which one
	-- that is rather than assuming the white it is listed under.
	local function itemTypeFor(name)
		for _, v in BLOCKS do
			if v.Name ~= name then continue end
			if v.Type ~= 'wool_white' then return v.Type end
	
			local ok, wool = pcall(bedwars.Shop.getTeamWoolById, lplr:GetAttribute('Team'))
			return (ok and wool) or v.Type
		end
	end
	
	--[[
		TNT counts as a placeable block as far as the metadata goes, and a soft one at that,
		so it would be reached for first by the weakest-first choice and fallen back to by the
		strongest-first choice once everything else ran out - either way stacking explosives
		against the bed this is supposed to be protecting.
	
		Matched on the name rather than a list of item types, so the siege and balloon variants
		are covered by the same rule.
	]]
	local function explosive(itemType)
		return itemType:find('tnt') ~= nil
	end
	
	-- Everything placeable you are carrying, toughest first.
	local function heldBlocks()
		local blocks = {}
		for _, item in store.inventory.inventory.items do
			local meta = bedwars.ItemMeta[item.itemType]
			if meta and meta.block and not explosive(item.itemType) then
				table.insert(blocks, {Item = item, Health = meta.block.health or 0})
			end
		end
		table.sort(blocks, function(a, b)
			return a.Health > b.Health
		end)
		return blocks
	end
	
	--[[
		Which block to build with.
	
		A named choice is used when you are carrying it and quietly falls back to the toughest
		thing you have when you are not, so running out of obsidian mid patch keeps the hole
		being filled rather than stopping the module dead.
	]]
	local function chooseBlock()
		local blocks = heldBlocks()
		if #blocks == 0 then return nil end
	
		if Block.Value == 'Weakest' then return blocks[#blocks].Item end
		if Block.Value ~= 'Strongest' then
			local wanted = itemTypeFor(Block.Value)
			local item = wanted and getItem(wanted)
			if item then return item end
		end
	
		return blocks[1].Item
	end
	
	local function equip(item)
		if not item.tool then return end
		-- Already in hand, so there is nothing to switch. Doing it again for every single
		-- placement was wasted work and a visible flicker.
		if store.hand.tool == item.tool then return end
	
		for i, v in store.inventory.hotbar do
			if v.item and v.item.itemType == item.itemType then
				if store.inventory.hotbarSlot ~= i - 1 then
					hotbarSwitch(i - 1)
				end
				break
			end
		end
		switchItem(item.tool)
	end
	
	-- What is in your hand as an item type, or nil when it is not a block at all.
	local function heldBlockType()
		local tool = store.hand.tool
		local meta = tool and bedwars.ItemMeta[tool.Name]
		return (meta and meta.block) and tool.Name or nil
	end
	
	--[[
		Every cell out to `layers` around the bed, nearest first.
	
		Walked outwards over the six faces from each cell the bed occupies, so a bed lying
		across two positions is wrapped from both halves and the innermost ring is always
		offered before the one outside it.
	]]
	local function shell(bed, layers)
		local seen, frontier, order = {}, {}, {}
		for _, v in bedwars.getContainedPositions(bed) do
			local pos = v * 3
			seen[pos] = true
			table.insert(frontier, pos)
		end
	
		for _ = 1, layers do
			local nextfrontier = {}
			for _, pos in frontier do
				for _, side in sides do
					local at = pos + side
					if not seen[at] then
						seen[at] = true
						table.insert(order, at)
						table.insert(nextfrontier, at)
					end
				end
			end
			frontier = nextfrontier
		end
		return order
	end
	
	--[[
		A hole in the defence rather than a place to start one.
	
		This is what makes patching a different job from building. Building fills every empty
		cell around the bed, which out in the open means walling the bed in from scratch.
		Patching only wants the cells that something has been taken out of, so a cell counts
		only when enough of what surrounds it is still standing - the blocks either side of a
		hole somebody has just mined through.
	]]
	local function isGap(pos)
		local solid = 0
		for _, side in sides do
			if getPlacedBlock(pos + side) then
				solid += 1
				if solid >= MIN_SOLID then return true end
			end
		end
		return false
	end
	
	local function inReach(pos)
		if not entitylib.isAlive then return false end
		return (entitylib.character.RootPart.Position - pos).Magnitude <= Range.Value
	end
	
	--[[
		Whether a cell sits within the cone you are looking down.
	
		The setting is the width of that cone, so half of it is the furthest off your view a
		block may sit. A full turn takes in everything, and is not worth resolving the camera
		for at all.
	]]
	local function inView(pos)
		local half = Angle.Value / 2
		if half >= 180 then return true end
	
		local camera = workspace.CurrentCamera
		if not camera then return true end
	
		local dir = pos - camera.CFrame.Position
		if dir.Magnitude == 0 then return true end
	
		local facing = camera.CFrame.LookVector:Dot(dir.Unit)
		return math.deg(math.acos(math.clamp(facing, -1, 1))) <= half
	end
	
	-- One sweep of the bed. Returns whether anything was built, so the caller can tell a
	-- finished defence from one it never got near.
	local function protect(bed)
		local built = false
	
		for _, pos in shell(bed, Layers.Value) do
			if not BedProtector.Enabled then break end
			if getPlacedBlock(pos) then continue end
			if not inReach(pos) then continue end
			if not inView(pos) then continue end
			if AutoPatch.Enabled and not isGap(pos) then continue end
	
			--[[
				Limit to Items is asked twice, on either side of Auto Block, because the two
				halves of it want different things.
	
				First, something that is a block at all has to be out. This is judged before
				Auto Block touches your hand - equipping first meant Auto Block satisfied the
				check by its own action, so the gate could never fail and a sword still built.
	
				Then, what is out has to be the block actually going down. Auto Block will have
				just made that true, which is what lets wool in hand turn into the wood you
				asked for; with Auto Block off there is nothing to reconcile them, so holding
				wool while stone is being placed builds nothing.
			]]
			if LimitItems.Enabled and not heldBlockType() then continue end
	
			local item = chooseBlock()
			if not item then break end
	
			-- Left as late as possible, so your hand is only ever changed for a placement that
			-- is actually about to happen.
			if AutoBlock.Enabled then
				equip(item)
			end
	
			if LimitItems.Enabled and heldBlockType() ~= item.itemType then continue end
	
			-- Once per switch on, so there is a moment between reaching for the module and the
			-- first block appearing rather than one landing the instant it comes on.
			if not waited then
				waited = true
				if StartDelay.Value > 0 then
					task.wait(StartDelay.Value)
					if not BedProtector.Enabled then break end
				end
			end
	
			bedwars.placeBlock(pos, item.itemType)
			built = true
			task.wait(Speed.Value)
		end
	
		return built
	end
	
	BedProtector = vain.Categories.World:CreateModule({
		Name = 'BedProtector',
		Function = function(callback)
			if not callback then
				waited = false
				return
			end
	
			waited = false
			local once = Mode.Value == 'On Toggle'
			repeat
				local bed = getBedNear()
				if bed then
					-- Only worth saying on a one off run, where nothing happening looks
					-- identical to the module not working.
					if not protect(bed) and once then
						notif('BedProtector', AutoPatch.Enabled and 'No gaps to patch' or 'Nothing to build', 5)
					end
				elseif once then
					notif('BedProtector', 'Unable to locate bed', 5)
				end
	
				if once then break end
				task.wait(0.1)
			until not BedProtector.Enabled
	
			-- On Toggle is a one off, so it puts itself away again the way it always did.
			if once and BedProtector.Enabled then
				BedProtector:Toggle()
			end
		end,
		Tooltip = 'Builds blocks around your bed'
	})
	Mode = BedProtector:CreateDropdown({
		Name = 'Mode',
		Tooltip = 'Whether it keeps going or runs once',
		List = {'Always', 'On Toggle'},
		Tooltips = {
			Always = 'Keeps building while enabled',
			['On Toggle'] = 'Builds once, then turns itself off'
		},
		Function = function()
			if BedProtector.Enabled then
				BedProtector:Toggle()
			end
		end
	})
	Block = BedProtector:CreateDropdown({
		Name = 'Preferred Block',
		Tooltip = 'Which block to build with',
		List = {'Strongest', 'Weakest', 'Wool', 'Wood', 'Stone', 'Ceramic', 'Obsidian'},
		Tooltips = {
			Strongest = 'Toughest block you are carrying',
			Weakest = 'Softest block you are carrying'
		}
	})
	Speed = BedProtector:CreateSlider({
		Name = 'Speed',
		Tooltip = 'Delay between blocks, lower is faster\nGame limit is 12 a second',
		Min = MIN_SPEED,
		Max = 1,
		Default = 0.1,
		Decimal = 100,
		Suffix = 'seconds'
	})
	Layers = BedProtector:CreateSlider({
		Name = 'Layers',
		Tooltip = 'How thick to build\nDefault is 2',
		Min = 1,
		Max = 5,
		Default = 2
	})
	Range = BedProtector:CreateSlider({
		Name = 'Range',
		Tooltip = 'How far this reaches, in studs\nDefault is 18',
		Min = 1,
		Max = 30,
		Default = 18,
		Suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})
	Angle = BedProtector:CreateSlider({
		Name = 'Angle',
		Tooltip = 'How wide a cone in front of you blocks place in\n360 places behind you too',
		Min = 1,
		Max = 360,
		Default = 360,
		Suffix = 'degrees'
	})
	AutoPatch = BedProtector:CreateToggle({
		Name = 'Auto Patch',
		Tooltip = 'Only fills holes in the defence'
	})
	AutoBlock = BedProtector:CreateToggle({
		Name = 'Auto Block',
		Tooltip = 'Holds the block before placing it'
	})
	LimitItems = BedProtector:CreateToggle({
		Name = 'Limit to Items',
		Tooltip = 'Only builds while holding the block being placed'
	})
	StartDelay = BedProtector:CreateSlider({
		Name = 'Start Delay',
		Tooltip = 'Waits this long before the first block\nDefault is 0',
		Min = 0,
		Max = 1,
		Default = 0,
		Decimal = 100,
		Suffix = 'seconds'
	})
	
end)

run(function()
	local ChestSteal
	local Range
	local Delay
	local UpdateRate
	local Open
	local SkipOwn
	local Skywars
	local Delays = {}
	local looting = false
	
	-- How close the game itself lets you open a chest from: the MaxActivationDistance on the
	-- prompt it puts on every chest block.
	local CHEST_RANGE = 7.5
	local CHEST_APP = 'ChestApp'
	
	-- How long to leave a chest alone after working through it, so one that will not give
	-- anything up is not retried on every pass.
	local RETRY = 1
	
	local function personalFolder()
		local inventories = replicatedStorage:FindFirstChild('Inventories')
		return inventories and inventories:FindFirstChild(lplr.Name..'_personal')
	end
	
	--[[
		Your own chest, never looted whatever the settings say - it is AutoBank's, and taking
		back out what that just put in is never what anybody wants.
	
		Tested on the folder the items live in rather than on the block's name. The name was
		not enough: a personal chest is reached through an ordinary ChestFolderValue like any
		other chest, so from the outside it looks like nothing special, which is exactly how
		this was emptying the chest AutoBank had just filled.
	]]
	local function ownChest(folder)
		return folder ~= nil and folder == personalFolder()
	end
	
	--[[
		Your team's crate, which Skip Own covers.
	
		Found the way the game's own getTeamCrate finds it, by the Team attribute matching
		yours - an enemy crate belongs to another team and stays fair game.
	
		Compared as text and looked for up the parents, because the tag sits on a holder with
		the block underneath it and the id comes back as a string in some places and a number
		in others; a straight == between the two forms is quietly false.
	]]
	local function teamOf(inst)
		local team = inst:GetAttribute('Team')
		if team == nil then team = inst:GetAttribute('GeneratorTeam') end
		return team ~= nil and tostring(team) or nil
	end
	
	-- A crate belonging to a team you are not allowed to touch. Separate from Skip Own,
	-- which is a preference - this one is not optional, the same way their bed is not.
	local function shieldedChest(block)
		if not block or not bedwars.protectedTeam then return false end
	
		local node = block
		for _ = 1, 3 do
			if not node then break end
			local team = node:GetAttribute('Team') or node:GetAttribute('GeneratorTeam')
			if team ~= nil and bedwars.protectedTeam(team) then return true end
			node = node.Parent
		end
		return false
	end
	
	local function teamChest(block)
		local mine = lplr:GetAttribute('Team')
		if mine == nil or not block then return false end
		mine = tostring(mine)
	
		local node = block
		for _ = 1, 3 do
			if not node then break end
			if teamOf(node) == mine then return true end
			node = node.Parent
		end
		return false
	end
	
	-- Which chest block a folder belongs to, so a chest opened by hand can be judged the same
	-- way as one walked up to.
	local function blockFor(chests, folder)
		if not folder then return nil end
		for _, v in chests do
			local value = v:FindFirstChild('ChestFolderValue')
			if value and value.Value == folder then return v end
		end
	end
	
	local function chestApp()
		local ok, open = pcall(function()
			return bedwars.AppController:isAppOpen(CHEST_APP)
		end)
		return ok and open or false
	end
	
	local function observedValue()
		local char = lplr.Character
		local observed = char and char:FindFirstChild('ObservedChestFolder')
		return observed, observed and observed.Value
	end
	
	--[[
		Tells the server which chest is being looted, and waits for it to agree.
	
		Both of these were wrong before. The transfers went out in the same breath as the
		message announcing the chest, so they could reach the server before it had recorded
		which chest was open, and the message clearing it again was sent immediately after -
		before a single transfer had come back. With GUI Check on that clear was worse still,
		because the chest it cleared was the one you had open by hand.
	]]
	local function observe(folder)
		local observed, current = observedValue()
		if not observed then return false end
		if current == folder then return true end
		-- With GUI Check on the game has already sent this itself, so nothing is sent here.
		if Open.Enabled then return false end
	
		pcall(function()
			bedwars.Client:GetNamespace('Inventory'):Get('SetObservedChest'):SendToServer(folder)
		end)
	
		for _ = 1, 20 do
			if observed.Value == folder then return true end
			task.wait()
		end
		return false
	end
	
	local function release(folder)
		-- Only ever let go of a chest this module took hold of. One you opened yourself stays
		-- open.
		if Open.Enabled then return end
		local _, current = observedValue()
		if current ~= folder then return end
	
		pcall(function()
			bedwars.Client:GetNamespace('Inventory'):Get('SetObservedChest'):SendToServer(nil)
		end)
	end
	
	local function inRange(block)
		if not entitylib.isAlive then return false end
		return (entitylib.character.RootPart.Position - block.Position).Magnitude <= Range.Value
	end
	
	local function lootChest(folder, block)
		if not folder then return end
		if Delays[folder] and Delays[folder] > tick() then return end
	
		local taking = {}
		for _, v in folder:GetChildren() do
			if v:IsA('Accessory') then
				table.insert(taking, v)
			end
		end
		if #taking == 0 then return end
	
		Delays[folder] = tick() + RETRY
		if not observe(folder) then return end
	
		for _, item in taking do
			if not ChestSteal.Enabled then break end
	
			-- Waited before every item, the first one included, so a chest is not emptied in
			-- a single frame.
			if Delay.Value > 0 then
				task.wait(Delay.Value)
				-- Walking off, or closing the chest, stops the rest.
				if block and not inRange(block) then break end
				if Open.Enabled and not chestApp() then break end
			end
	
			-- Sent one at a time and waited on. Firing them all off at once meant none of
			-- them had answered by the time the chest was handed back.
			pcall(function()
				bedwars.Client:GetNamespace('Inventory'):Get('ChestGetItem'):CallServer(folder, item)
			end)
		end
	
		release(folder)
	end
	
	ChestSteal = vain.Categories.World:CreateModule({
		Name = 'ChestSteal',
		Function = function(callback)
			if callback then
				local chests = collection('chest', ChestSteal)
				table.clear(Delays)
				repeat task.wait() until store.queueType ~= 'bedwars_test'
				if (not Skywars.Enabled) or store.queueType:find('skywars') then
					repeat
						if entitylib.isAlive and store.matchState ~= 2 and not looting then
							looting = true
							pcall(function()
								if Open.Enabled then
									if chestApp() then
										local folder = select(2, observedValue())
										-- Judged the same as any other chest, so opening your own
										-- by hand is not a way round the checks below.
										local block = blockFor(chests, folder)
										if not ownChest(folder)
											and not shieldedChest(block)
											and not (SkipOwn.Enabled and teamChest(block)) then
											lootChest(folder)
										end
									end
								else
									for _, v in chests do
										if not ChestSteal.Enabled then break end
	
										local value = v:FindFirstChild('ChestFolderValue')
										local folder = value and value.Value
										if folder and inRange(v)
											and not ownChest(folder)
											and not shieldedChest(v)
											and not (SkipOwn.Enabled and teamChest(v)) then
											lootChest(folder, v)
										end
									end
								end
							end)
							looting = false
						end
	
						-- A saved config can switch this on while the file is still running, so
						-- the slider is not guaranteed to exist on the first pass.
						task.wait(UpdateRate and (1 / UpdateRate.Value) or 0.25)
					until not ChestSteal.Enabled
				end
			else
				looting = false
				table.clear(Delays)
			end
		end,
		Tooltip = 'Takes items out of nearby chests'
	})
	Range = ChestSteal:CreateSlider({
		Name = 'Range',
		Tooltip = 'How far this reaches\nGame default is 7.5',
		Min = 1,
		Max = 20,
		Default = CHEST_RANGE,
		Decimal = 10,
		Suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})
	Delay = ChestSteal:CreateSlider({
		Name = 'Delay',
		Tooltip = 'Wait between each item taken\nDefault is 0.25',
		Min = 0,
		Max = 3,
		Default = 0.25,
		Decimal = 100,
		Suffix = 'seconds'
	})
	UpdateRate = ChestSteal:CreateSlider({
		Name = 'Update Rate',
		Tooltip = 'How often it checks for chests\nDefault is 4hz',
		Min = 1,
		Max = 20,
		Default = 4,
		Suffix = 'hz'
	})
	Open = ChestSteal:CreateToggle({
		Name = 'GUI Check',
		Tooltip = 'Only takes while a chest is open'
	})
	SkipOwn = ChestSteal:CreateToggle({
		Name = 'Skip Own',
		Tooltip = 'Leaves your team chest alone',
		Default = true
	})
	Skywars = ChestSteal:CreateToggle({
		Name = 'Only Skywars',
		Tooltip = 'Only runs while in a skywars queue',
		Function = function()
			if ChestSteal.Enabled then
				ChestSteal:Toggle()
				ChestSteal:Toggle()
			end
		end,
		Default = true
	})
	
end)

run(function()
	local Schematica
	local File
	local Mode
	local Transparency
	local parts, guidata, poschecklist = {}, {}, {}
	local point1, point2
	
	for x = -3, 3, 3 do
		for y = -3, 3, 3 do
			for z = -3, 3, 3 do
				if Vector3.new(x, y, z) ~= Vector3.zero then
					table.insert(poschecklist, Vector3.new(x, y, z))
				end
			end
		end
	end
	
	local function checkAdjacent(pos)
		for _, v in poschecklist do
			if getPlacedBlock(pos + v) then return true end
		end
		return false
	end
	
	local function getPlacedBlocksInPoints(s, e)
		local list, blocks = {}, bedwars.BlockController:getStore()
		for x = (e.X > s.X and s.X or e.X), (e.X > s.X and e.X or s.X) do
			for y = (e.Y > s.Y and s.Y or e.Y), (e.Y > s.Y and e.Y or s.Y) do
				for z = (e.Z > s.Z and s.Z or e.Z), (e.Z > s.Z and e.Z or s.Z) do
					local vec = Vector3.new(x, y, z)
					local block = blocks:getBlockAt(vec)
					if block and block:GetAttribute('PlacedByUserId') == lplr.UserId then
						list[vec] = block
					end
				end
			end
		end
		return list
	end
	
	local function loadMaterials()
		for _, v in guidata do 
			v:Destroy() 
		end
		local suc, read = pcall(function() 
			return isfile(File.Value) and httpService:JSONDecode(readfile(File.Value)) 
		end)
	
		if suc and read then
			local items = {}
			for _, v in read do 
				items[v[2]] = (items[v[2]] or 0) + 1 
			end
			
			for i, v in items do
				local holder = Instance.new('Frame')
				holder.Size = UDim2.new(1, 0, 0, 32)
				holder.BackgroundTransparency = 1
				holder.Parent = Schematica.Children
				local icon = Instance.new('ImageLabel')
				icon.Size = UDim2.fromOffset(24, 24)
				icon.Position = UDim2.fromOffset(4, 4)
				icon.BackgroundTransparency = 1
				icon.Image = bedwars.getIcon({itemType = i}, true)
				icon.Parent = holder
				local text = Instance.new('TextLabel')
				text.Size = UDim2.fromOffset(100, 32)
				text.Position = UDim2.fromOffset(32, 0)
				text.BackgroundTransparency = 1
				text.Text = (bedwars.ItemMeta[i] and bedwars.ItemMeta[i].displayName or i)..': '..v
				text.TextXAlignment = Enum.TextXAlignment.Left
				text.TextColor3 = uipallet.Text
				text.TextSize = 14
				text.FontFace = uipallet.Font
				text.Parent = holder
				table.insert(guidata, holder)
			end
			table.clear(read)
			table.clear(items)
		end
	end
	
	local function save()
		if point1 and point2 then
			local tab = getPlacedBlocksInPoints(point1, point2)
			local savetab = {}
			point1 = point1 * 3
			for i, v in tab do
				i = bedwars.BlockController:getBlockPosition(CFrame.lookAlong(point1, entitylib.character.RootPart.CFrame.LookVector):PointToObjectSpace(i * 3)) * 3
				table.insert(savetab, {
					{
						x = i.X, 
						y = i.Y, 
						z = i.Z
					}, 
					v.Name
				})
			end
			point1, point2 = nil, nil
			writefile(File.Value, httpService:JSONEncode(savetab))
			notif('Schematica', 'Saved '..getTableSize(tab)..' blocks', 5)
			loadMaterials()
			table.clear(tab)
			table.clear(savetab)
		else
			local mouseinfo = bedwars.BlockBreaker.clientManager:getBlockSelector():getMouseInfo(0)
			if mouseinfo and mouseinfo.target then
				if point1 then
					point2 = mouseinfo.target.blockRef.blockPosition
					notif('Schematica', 'Selected position 2, toggle again near position 1 to save it', 3)
				else
					point1 = mouseinfo.target.blockRef.blockPosition
					notif('Schematica', 'Selected position 1', 3)
				end
			end
		end
	end
	
	local function load(read)
		local mouseinfo = bedwars.BlockBreaker.clientManager:getBlockSelector():getMouseInfo(0)
		if mouseinfo and mouseinfo.target then
			local position = CFrame.new(mouseinfo.placementPosition * 3) * CFrame.Angles(0, math.rad(math.round(math.deg(math.atan2(-entitylib.character.RootPart.CFrame.LookVector.X, -entitylib.character.RootPart.CFrame.LookVector.Z)) / 45) * 45), 0)
	
			for _, v in read do
				local blockpos = bedwars.BlockController:getBlockPosition((position * CFrame.new(v[1].x, v[1].y, v[1].z)).p) * 3
				if parts[blockpos] then continue end
				local handler = bedwars.BlockController:getHandlerRegistry():getHandler(v[2]:find('wool') and getWool() or v[2])
				if handler then
					local part = handler:place(blockpos / 3, 0)
					part.Transparency = Transparency.Value
					part.CanCollide = false
					part.Anchored = true
					part.Parent = workspace
					parts[blockpos] = part
				end
			end
			table.clear(read)
	
			repeat
				if entitylib.isAlive then
					local localPosition = entitylib.character.RootPart.Position
					for i, v in parts do
						if (i - localPosition).Magnitude < 60 and checkAdjacent(i) then
							if not Schematica.Enabled then break end
							if not getItem(v.Name) then continue end
							bedwars.placeBlock(i, v.Name, false)
							task.delay(0.1, function()
								local block = getPlacedBlock(i)
								if block then
									v:Destroy()
									parts[i] = nil
								end
							end)
						end
					end
				end
				task.wait()
			until getTableSize(parts) <= 0
	
			if getTableSize(parts) <= 0 and Schematica.Enabled then
				notif('Schematica', 'Finished building', 5)
				Schematica:Toggle()
			end
		end
	end
	
	Schematica = vain.Categories.World:CreateModule({
		Name = 'Schematica',
		Function = function(callback)
			if callback then
				if not File.Value:find('.json') then
					notif('Schematica', 'Invalid file', 3)
					Schematica:Toggle()
					return
				end
	
				if Mode.Value == 'Save' then
					save()
					Schematica:Toggle()
				else
					local suc, read = pcall(function() 
						return isfile(File.Value) and httpService:JSONDecode(readfile(File.Value)) 
					end)
	
					if suc and read then
						load(read)
					else
						notif('Schematica', 'Missing / corrupted file', 3)
						Schematica:Toggle()
					end
				end
			else
				for _, v in parts do 
					v:Destroy() 
				end
				table.clear(parts)
			end
		end,
		Tooltip = 'Save and load placements of buildings'
	})
	File = Schematica:CreateTextBox({
		Name = 'File',
		Tooltip = 'File to load',
		Function = function()
			loadMaterials()
			point1, point2 = nil, nil
		end
	})
	Mode = Schematica:CreateDropdown({
		Name = 'Mode',
		Tooltip = 'Which method this module uses',
		List = {'Load', 'Save'}
	})
	Transparency = Schematica:CreateSlider({
		Name = 'Transparency',
		Tooltip = 'How see-through this is',
		Min = 0,
		Max = 1,
		Default = 0.7,
		Decimal = 10,
		Function = function(val)
			for _, v in parts do 
				v.Transparency = val 
			end
		end
	})
end)

run(function()
	local ArmorSwitch
	local Mode
	local Targets
	local Range
	local Speed
	
	ArmorSwitch = vain.Categories.Inventory:CreateModule({
		Name = 'ArmorSwitch',
		Function = function(callback)
			if callback then
				if Mode.Value == 'Toggle' then
					repeat
						local state = entitylib.EntityPosition({
							Part = 'RootPart',
							Range = Range.Value,
							Players = Targets.Players.Enabled,
							NPCs = Targets.NPCs.Enabled,
							Wallcheck = Targets.Walls.Enabled
						}) and true or false
	
						for i = 0, 2 do
							if (store.inventory.inventory.armor[i + 1] ~= 'empty') ~= state and ArmorSwitch.Enabled then
								bedwars.Store:dispatch({
									type = 'InventorySetArmorItem',
									item = store.inventory.inventory.armor[i + 1] == 'empty' and state and getBestArmor(i) or nil,
									armorSlot = i
								})
								vainEvents.InventoryChanged.Event:Wait()
								-- A piece at a time. All three landing in the same frame is not
								-- something anyone could do by hand.
								if Speed.Value > 0 then
									task.wait(Speed.Value)
								end
							end
						end
						task.wait(0.1)
					until not ArmorSwitch.Enabled
				else
					ArmorSwitch:Toggle()
					for i = 0, 2 do
						bedwars.Store:dispatch({
							type = 'InventorySetArmorItem',
							item = store.inventory.inventory.armor[i + 1] == 'empty' and getBestArmor(i) or nil,
							armorSlot = i
						})
						vainEvents.InventoryChanged.Event:Wait()
						if Speed.Value > 0 then
							task.wait(Speed.Value)
						end
					end
				end
			end
		end,
		Tooltip = 'Puts on / takes off armor when toggled for baiting.'
	})
	Mode = ArmorSwitch:CreateDropdown({
		Name = 'Mode',
		Tooltip = 'Which method this module uses',
		List = {'Toggle', 'On Key'}
	})
	Targets = ArmorSwitch:CreateTargets({
		Players = true,
		NPCs = true,
		Tooltip = 'Which entities this module is allowed to target'
	})
	Speed = ArmorSwitch:CreateSlider({
		Name = 'Speed',
		Tooltip = 'Delay between each piece, lower is faster\nDefault is 0.1',
		Min = 0,
		Max = 1,
		Default = 0.1,
		Decimal = 100,
		Suffix = 'seconds'
	})
	Range = ArmorSwitch:CreateSlider({
		Name = 'Range',
		Tooltip = 'How far this reaches, in studs\nDefault is 30',
		Min = 1,
		Max = 30,
		Default = 30,
		Suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})
end)

run(function()
	local AutoBank
	local UIToggle
	local GuiCheck
	local Range
	local Delay
	local UpdateRate
	local Toggles = {}
	local UI
	local Chests
	local Items = {}
	local banking = false
	
	-- The app the game opens when you actually click a chest.
	local CHEST_APP = 'ChestApp'
	
	-- How close the game itself lets you open a chest from: the MaxActivationDistance on the
	-- prompt it puts on every chest block. The default, since reaching further than the
	-- prompt does is not something the server has any reason to honour.
	local CHEST_RANGE = 7.5
	
	-- What the on screen list shows, top to bottom, and what can be banked. Kept as a list
	-- rather than a set so the icons always come out in the same order.
	local RESOURCES = {
		{Type = 'iron', Name = 'Iron'},
		{Type = 'gold', Name = 'Gold'},
		{Type = 'diamond', Name = 'Diamond'},
		{Type = 'emerald', Name = 'Emerald'},
		{Type = 'void_crystal', Name = 'Void Crystal'}
	}
	
	local function personalChest()
		local inventories = replicatedStorage:FindFirstChild('Inventories')
		return inventories and inventories:FindFirstChild(lplr.Name..'_personal')
	end
	
	--[[
		The chest the server currently thinks you have open.
	
		This is the whole reason banking never worked. Both transfer remotes take this folder,
		not the one you can look up by name in ReplicatedStorage, and the server only fills it
		in once it has been told which chest you are at. Handing it the folder found by name
		meant every deposit was made against a chest the server had no record of you opening.
	]]
	local function observedChest()
		local char = lplr.Character
		local observed = char and char:FindFirstChild('ObservedChestFolder')
		return observed, observed and observed.Value
	end
	
	local function chestApp()
		local ok, open = pcall(function()
			return bedwars.AppController:isAppOpen(CHEST_APP)
		end)
		return ok and open or false
	end
	
	local function nearestChest()
		if not entitylib.isAlive then return nil end
	
		local pos = entitylib.character.RootPart.Position
		local closest, mag = nil, Range and Range.Value or CHEST_RANGE
		for _, chest in Chests do
			local dist = (chest.Position - pos).Magnitude
			if dist <= mag then
				closest, mag = chest, dist
			end
		end
		return closest
	end
	
	--[[
		Tells the server which chest you are at, which is exactly what opening one does.
	
		Left alone entirely while GUI Check is on: the game has already sent this itself, and
		sending it again would only risk clearing what it set.
	]]
	local function observe(folder)
		local observed, current = observedChest()
		if not observed then return false end
		if current == folder then return true end
		if GuiCheck and GuiCheck.Enabled then return false end
	
		pcall(function()
			bedwars.Client:GetNamespace('Inventory'):Get('SetObservedChest'):SendToServer(folder)
		end)
	
		-- The server answers by writing the folder back, so wait for that rather than
		-- assuming it took - a deposit sent before it lands is refused.
		for _ = 1, 20 do
			if observed.Value == folder then return true end
			task.wait()
		end
		return false
	end
	
	local function addItem(itemType)
		local item = Instance.new('ImageLabel')
		item.Image = bedwars.getIcon({itemType = itemType}, true)
		item.Size = UDim2.fromOffset(32, 32)
		item.Name = itemType
		item.BackgroundTransparency = 1
		item.LayoutOrder = #UI:GetChildren()
		item.Parent = UI
		local itemtext = Instance.new('TextLabel')
		itemtext.Name = 'Amount'
		itemtext.Size = UDim2.fromScale(1, 1)
		itemtext.BackgroundTransparency = 1
		itemtext.Text = ''
		itemtext.TextColor3 = Color3.new(1, 1, 1)
		itemtext.TextSize = 16
		itemtext.TextStrokeTransparency = 0.3
		itemtext.Font = Enum.Font.Arial
		itemtext.Parent = item
		Items[itemType] = itemtext
	end
	
	--[[
		Draws what is actually in the chest.
	
		Refreshed every pass off the chest folder itself, rather than only after a transfer
		went through. That is why the display sat empty: the old one was only ever reached
		from inside the depositing branch, so unless something had just been moved there was
		nothing to draw, and standing away from the chest showed nothing at all.
	
		The contents replicate whether or not you are near it, so there is no reason to only
		show them when you are.
	]]
	local function refreshBank()
		local chest = personalChest()
		for itemType, label in Items do
			local entry = chest and chest:FindFirstChild(itemType)
			local amount = entry and entry:GetAttribute('Amount')
			label.Text = amount and tostring(amount) or ''
		end
	end
	
	local function bank()
		if not nearestChest() then return end
		if GuiCheck and GuiCheck.Enabled and not chestApp() then return end
	
		local folder = personalChest()
		if not folder or not observe(folder) then return end
	
		-- Worked out up front, because the transfer below waits on the server and the
		-- inventory is rebuilt underneath it every time one lands.
		local sending = {}
		for _, item in store.inventory.inventory.items do
			local toggle = Toggles[item.itemType]
			if toggle and toggle.Enabled and item.tool then
				table.insert(sending, item.tool)
			end
		end
	
		for _, tool in sending do
			if not AutoBank.Enabled then return end
	
			--[[
				Waited before every item, the first one included.
	
				Sitting it only between items made the setting look like it did nothing, and
				for once that was exactly right: the inventory holds one entry per resource
				with an amount on it, not one per unit, so carrying nothing but iron is a run
				of a single item and there is no between for the wait to sit in.
	
				Zero on the slider still banks the moment you are in reach.
			]]
			if Delay and Delay.Value > 0 then
				task.wait(Delay.Value)
				-- Walking off part way through stops the rest, rather than carrying on
				-- posting items to a chest you are no longer standing at.
				if not nearestChest() then return end
				if GuiCheck and GuiCheck.Enabled and not chestApp() then return end
			end
	
			-- One at a time and waited on. The old version spawned a call per item on every
			-- pass without ever waiting for one, so a full inventory fired the same transfers
			-- over and over a tenth of a second apart.
			pcall(function()
				bedwars.Client:GetNamespace('Inventory'):Get('ChestGiveItem'):CallServer(folder, tool)
			end)
		end
	end
	
	AutoBank = vain.Categories.Inventory:CreateModule({
		Name = 'AutoBank',
		Function = function(callback)
			if callback then
				Chests = collection('personal-chest', AutoBank)
				UI = Instance.new('Frame')
				UI.Size = UDim2.new(1, 0, 0, 32)
				UI.Position = UDim2.fromOffset(0, -240)
				UI.BackgroundTransparency = 1
				UI.Visible = not UIToggle or UIToggle.Enabled
				UI.Parent = vain.gui
				AutoBank:Clean(UI)
				local Sort = Instance.new('UIListLayout')
				Sort.FillDirection = Enum.FillDirection.Horizontal
				Sort.HorizontalAlignment = Enum.HorizontalAlignment.Center
				Sort.SortOrder = Enum.SortOrder.LayoutOrder
				Sort.Parent = UI
	
				table.clear(Items)
				for _, resource in RESOURCES do
					addItem(resource.Type)
				end
	
				repeat
					local hotbar = lplr.PlayerGui:FindFirstChild('hotbar')
					hotbar = hotbar and hotbar['1']:FindFirstChild('HotbarHealthbarContainer')
					if hotbar then
						UI.Position = UDim2.fromOffset(0, (hotbar.AbsolutePosition.Y + guiService:GetGuiInset().Y) - 40)
					end
	
					if not UIToggle or UIToggle.Enabled then
						pcall(refreshBank)
					end
	
					-- Guarded so a pass that is still waiting on the server cannot be started
					-- a second time underneath itself.
					if not banking then
						banking = true
						pcall(bank)
						banking = false
					end
	
					-- A saved config can switch this on while the file is still running, so the
					-- sliders are not guaranteed to exist on the first pass.
					task.wait(UpdateRate and (1 / UpdateRate.Value) or 0.25)
				until not AutoBank.Enabled
			else
				banking = false
				table.clear(Items)
			end
		end,
		Tooltip = 'Puts resources into your personal chest'
	})
	UIToggle = AutoBank:CreateToggle({
		Name = 'UI',
		Tooltip = 'Shows your chest contents on screen',
		Function = function(callback)
			if AutoBank.Enabled and UI then
				UI.Visible = callback
			end
		end,
		Default = true
	})
	GuiCheck = AutoBank:CreateToggle({
		Name = 'GUI Check',
		Tooltip = 'Only banks while the chest is open'
	})
	Range = AutoBank:CreateSlider({
		Name = 'Range',
		Tooltip = 'How close to the chest you must be\nGame default is 7.5',
		Min = 1,
		Max = 20,
		Default = CHEST_RANGE,
		Decimal = 10,
		Suffix = 'studs'
	})
	Delay = AutoBank:CreateSlider({
		Name = 'Delay',
		Tooltip = 'Wait between each item going in\nDefault is 0.25',
		Min = 0,
		Max = 3,
		Default = 0.25,
		Decimal = 100,
		Suffix = 'seconds'
	})
	UpdateRate = AutoBank:CreateSlider({
		Name = 'Update Rate',
		Tooltip = 'How often it banks\nDefault is 4hz',
		Min = 1,
		Max = 20,
		Default = 4,
		Suffix = 'hz'
	})
	for _, resource in RESOURCES do
		Toggles[resource.Type] = AutoBank:CreateToggle({
			Name = resource.Name,
			Tooltip = 'Banks '..resource.Name:lower(),
			Default = true,
			Darker = true
		})
	end
	
end)

run(function()
	local AutoBuy
	local Armor
	local Upgrades
	local Preferred
	local BedwarsCheck
	local GUI
	local SmartCheck
	local Custom = {}
	local CustomPost = {}
	local UpgradeToggles = {}
	-- Both directions of the preferred-upgrade dropdown: the toggle that governs an upgrade,
	-- and the upgrade behind the display name the dropdown shows.
	local UpgradeToggle = {}
	local UpgradeByName = {}
	local Functions, id = {}
	local Callbacks = {Custom, Functions, CustomPost}
	local npctick = tick()
	
	local swords = {
		'wood_sword',
		'stone_sword',
		'iron_sword',
		'diamond_sword',
		'emerald_sword'
	}
	
	local armors = {
		'none',
		'leather_chestplate',
		'iron_chestplate',
		'diamond_chestplate',
		'emerald_chestplate'
	}
	
	local axes = {
		'none',
		'wood_axe',
		'stone_axe',
		'iron_axe',
		'diamond_axe'
	}
	
	local pickaxes = {
		'none',
		'wood_pickaxe',
		'stone_pickaxe',
		'iron_pickaxe',
		'diamond_pickaxe'
	}
	
	-- Where iron armor sits on the ladder, which is as far as smart check waits.
	local IRON_ARMOR = 3
	
	-- What you are wearing, as a rung on the armors ladder, or nil for armor that is not on
	-- it at all - a kit chestplate, say. Worked out in one place because the two that did it
	-- separately disagreed: one fell back to getBestArmor and the other did not, so smart
	-- check and the armor buying could each think you were wearing something different.
	local function armorTier()
		local worn = store.inventory.inventory.armor[2]
		worn = (worn and worn ~= 'empty') and worn or getBestArmor(1)
		return table.find(armors, worn and worn.itemType or 'none')
	end
	
	--[[
		Smart check keeps everything in reserve until iron armor is on. Nothing else is worth
		spending on while you are still in leather, and it is the same iron either way, so a
		pickaxe bought now is iron armor you cannot afford later.
	
		Team upgrades are deliberately not held back: they are bought with diamonds and never
		compete for the iron this is saving.
	
		Without Buy Armor there is nothing to wait for - the armor it is holding out for would
		never be bought - so it would block every purchase for the whole game. It stands down
		instead.
	]]
	local function savingForArmor()
		if not (SmartCheck.Enabled and Armor.Enabled) then return false end
		-- Armor that is not on the ladder cannot be compared against iron, and holding every
		-- purchase back on something that can never be resolved would stall the whole module.
		local tier = armorTier()
		return tier ~= nil and tier < IRON_ARMOR
	end
	
	local function getShopNPC()
		local shop, items, upgrades, newid = nil, false, false, nil
		if entitylib.isAlive then
			local localPosition = entitylib.character.RootPart.Position
			for _, v in store.shop do
				if (v.RootPart.Position - localPosition).Magnitude <= 20 then
					shop = v.Upgrades or v.Shop or nil
					upgrades = upgrades or v.Upgrades
					items = items or v.Shop
					newid = v.Shop and v.Id or newid
				end
			end
		end
		return shop, items, upgrades, newid
	end
	
	local function canBuy(item, currencytable, amount)
		amount = amount or 1
		if not currencytable[item.currency] then
			local currency = getItem(item.currency)
			currencytable[item.currency] = currency and currency.amount or 0
		end
		if item.ignoredByKit and table.find(item.ignoredByKit, store.equippedKit or '') then return false end
		if item.lockedByForge or item.disabled then return false end
		if item.require and item.require.teamUpgrade then
			-- teamUpgrades is keyed by team and holds a table per team; your own tiers are
			-- the flat map in myTeamUpgrades. Indexing the outer one by an upgrade id only
			-- ever came back nil, so this read as "tier -1" and refused the item outright.
			local mine = bedwars.Store:getState().Bedwars.myTeamUpgrades or {}
			if (mine[item.require.teamUpgrade.upgradeId] or -1) < item.require.teamUpgrade.lowestTierIndex then
				return false
			end
		end
		return currencytable[item.currency] >= (item.price * amount)
	end
	
	local function buyItem(item, currencytable)
		if not id then return end
		notif('AutoBuy', 'Bought '..bedwars.ItemMeta[item.itemType].displayName, 3)
		bedwars.Client:Get('BedwarsPurchaseItem'):CallServerAsync({
			shopItem = item,
			shopId = id
		}):andThen(function(suc)
			if suc then
				bedwars.SoundManager:playSound(bedwars.SoundList.BEDWARS_PURCHASE_ITEM)
				bedwars.Store:dispatch({
					type = 'BedwarsAddItemPurchased',
					itemType = item.itemType
				})
				bedwars.BedwarsShopController.alreadyPurchasedMap[item.itemType] = true
			end
		end)
		currencytable[item.currency] -= item.price
	end
	
	-- Which tier of an upgrade your team is on. The store keeps your own tiers in the flat
	-- myTeamUpgrades map; teamUpgrades is keyed by team, and it starts empty and only fills
	-- once somebody has actually bought something, so reading tiers out of it reported tier
	-- zero for the whole match.
	local function upgradeTier(upgradeType)
		local mine = bedwars.Store:getState().Bedwars.myTeamUpgrades or {}
		return mine[upgradeType] or 0
	end
	
	--[[
		The upgrade everything else is waiting on, if any.
	
		It only counts while there is something to wait for. An upgrade whose own toggle is
		off is never going to be bought, and one this queue does not offer cannot be bought at
		all - waiting on either would stall every other upgrade for the rest of the game.
	]]
	local function pendingPreferred(meta)
		local want = Preferred and Preferred.Value
		if not want or want == 'None' then return nil end
	
		local upgradeType = UpgradeByName[want]
		local upgrade = upgradeType and meta[upgradeType]
		if not upgrade then return nil end
	
		local toggle = UpgradeToggle[upgradeType]
		if not (toggle and toggle.Enabled) then return nil end
		if upgradeTier(upgradeType) >= #upgrade.tiers then return nil end
	
		return upgradeType
	end
	
	local function buyUpgrade(upgradeType, currencytable)
		if not Upgrades.Enabled then return end
	
		local meta = (bedwars.getTeamUpgradeMeta and bedwars.getTeamUpgradeMeta()) or bedwars.TeamUpgradeMeta
		local upgrade = meta[upgradeType]
		-- This queue does not run this upgrade at all.
		if not upgrade then return false end
	
		-- Everything else stands aside until the preferred upgrade has no tiers left, so the
		-- diamonds finish it off rather than being spread a tier at a time across all of them.
		local pending = pendingPreferred(meta)
		if pending and pending ~= upgradeType then return false end
	
		local currentTier = upgradeTier(upgradeType) + 1
	
		if currentTier <= #upgrade.tiers then
			local tier = upgrade.tiers[currentTier]
			if tier.availableOnlyInQueue and not table.find(tier.availableOnlyInQueue, store.queueType) then return false end
	
			if canBuy({currency = 'diamond', price = tier.cost}, currencytable) then
				notif('AutoBuy', 'Bought '..(upgrade.name == 'Armor' and 'Protection' or upgrade.name)..' '..currentTier, 3)
				bedwars.Client:Get('RequestPurchaseTeamUpgrade'):CallServerAsync(upgradeType)
				currencytable.diamond -= tier.cost
				return true
			end
		end
	
		return false
	end
	
	--[[
		Buys the one tier above whatever you are holding, and nothing else.
	
		The shop only ever sells the step immediately after what you own - iron armor is not
		on sale until leather is on your back - so scanning up the ladder for the first tier
		you could afford was never right. With enough of the wrong currency it would settle on
		a later tier, hand the server a purchase that could not be made, and buy nothing at
		all. That is what the tier check was papering over, so the check is gone and the
		one-step rule is simply always applied.
	
		One tier a pass still climbs quickly, since the buying loop comes round again 0.4s
		later with the new tier as the starting point.
	]]
	local function buyTool(tool, tools, currencytable)
		-- No tool at all starts below the ladder, so the first rung is what gets bought.
		-- Lists that carry a 'none' rung of their own pass it in instead.
		local tier = 0
		if tool then
			tier = table.find(tools, tool.itemType)
			-- Holding something that is not on this ladder - a kit weapon, say. There is no
			-- next step to work out from it, so it is left alone.
			if not tier then return false end
		end
	
		local upgrade = tools[tier + 1]
		if not upgrade then return false end
	
		local v = bedwars.Shop.getShopItem(upgrade, lplr)
		if not (v and canBuy(v, currencytable)) then return false end
	
		buyItem(v, currencytable)
		return true
	end
	
	AutoBuy = vain.Categories.Inventory:CreateModule({
		Name = 'AutoBuy',
		Function = function(callback)
			if callback then
				repeat task.wait() until store.queueType ~= 'bedwars_test'
				if BedwarsCheck.Enabled and not store.queueType:find('bedwars') then return end
	
				local lastupgrades
				AutoBuy:Clean(vainEvents.InventoryAmountChanged.Event:Connect(function()
					if (npctick - tick()) > 1 then npctick = tick() end
				end))
	
				repeat
					local npc, shop, upgrades, newid = getShopNPC()
					id = newid
					if GUI.Enabled then
						if not (bedwars.AppController:isAppOpen('BedwarsItemShopApp') or bedwars.AppController:isAppOpen('TeamUpgradeApp')) then
							npc = nil
						end
					end
	
					if npc and lastupgrades ~= upgrades then
						if (npctick - tick()) > 1 then npctick = tick() end
						lastupgrades = upgrades
					end
	
					if npc and npctick <= tick() and store.matchState ~= 2 and store.shopLoaded then
						local currencytable = {}
						local waitcheck
						for _, tab in Callbacks do
							for _, callback in tab do
								if callback(currencytable, shop, upgrades) then
									waitcheck = true
								end
							end
						end
						npctick = tick() + (waitcheck and 0.4 or math.huge)
					end
	
					task.wait(0.1)
				until not AutoBuy.Enabled
			else
				npctick = tick()
			end
		end,
		Tooltip = 'Automatically buys items when you go near the shop'
	})
	AutoBuy:CreateToggle({
		Name = 'Buy Sword',
		Tooltip = 'Automatically buys a sword upgrade',
		Function = function(callback)
			npctick = tick()
			Functions[2] = callback and function(currencytable, shop)
				if not shop then return end
	
				if store.equippedKit == 'dasher' then
					swords = {
						[1] = 'wood_dao',
						[2] = 'stone_dao',
						[3] = 'iron_dao',
						[4] = 'diamond_dao',
						[5] = 'emerald_dao'
					}
				elseif store.equippedKit == 'ice_queen' then
					swords[5] = 'ice_sword'
				elseif store.equippedKit == 'ember' then
					swords[5] = 'infernal_saber'
				elseif store.equippedKit == 'lumen' then
					swords[5] = 'light_sword'
				end
	
				if savingForArmor() then return end
				return buyTool(store.tools.sword, swords, currencytable)
			end or nil
		end
	})
	Armor = AutoBuy:CreateToggle({
		Name = 'Buy Armor',
		Tooltip = 'Automatically buys armor',
		Function = function(callback)
			npctick = tick()
			Functions[1] = callback and function(currencytable, shop)
				if not shop then return end
				-- Never held back by smart check: this is the purchase it is saving for.
				local tier = armorTier()
				return tier ~= nil and buyTool({itemType = armors[tier]}, armors, currencytable)
			end or nil
		end,
		Default = true
	})
	AutoBuy:CreateToggle({
		Name = 'Buy Axe',
		Tooltip = 'Automatically buys an axe',
		Function = function(callback)
			npctick = tick()
			Functions[3] = callback and function(currencytable, shop)
				if not shop then return end
				if savingForArmor() then return end
				return buyTool(store.tools.wood or {itemType = 'none'}, axes, currencytable)
			end or nil
		end
	})
	AutoBuy:CreateToggle({
		Name = 'Buy Pickaxe',
		Tooltip = 'Automatically buys a pickaxe',
		Function = function(callback)
			npctick = tick()
			Functions[4] = callback and function(currencytable, shop)
				if not shop then return end
				if savingForArmor() then return end
				-- Owning no pickaxe at all used to start the search past the end of the
				-- ladder, so the very first one was never bought. The axe side already passes
				-- the 'none' rung in; this now does the same.
				return buyTool(store.tools.stone or {itemType = 'none'}, pickaxes, currencytable)
			end or nil
		end
	})
	Upgrades = AutoBuy:CreateToggle({
		Name = 'Buy Upgrades',
		Tooltip = 'Automatically buys team upgrades',
		Function = function(callback)
			for _, v in UpgradeToggles do
				v.Object.Visible = callback
			end
		end,
		Default = true
	})
	local count = 0
	-- 'None' first so the dropdown opens on it and nothing is held back by default.
	local upgradeNames = {'None'}
	for i, v in bedwars.TeamUpgradeMeta do
		local toggleCount = count
		local displayName = (v.name == 'Armor' and 'Protection' or v.name)
		local toggle = AutoBuy:CreateToggle({
			Name = 'Buy '..displayName,
			Function = function(callback)
				npctick = tick()
				Functions[5 + toggleCount + (v.name == 'Armor' and 20 or 0)] = callback and function(currencytable, shop, upgrades)
					if not upgrades then return end
					if v.disabledInQueue and table.find(v.disabledInQueue, store.queueType) then return end
					return buyUpgrade(i, currencytable)
				end or nil
			end,
			Darker = true,
			Default = (i == 'ARMOR' or i == 'DAMAGE')
		})
		table.insert(UpgradeToggles, toggle)
		-- Both directions are kept: the upgrade behind a display name, so the dropdown can
		-- name one, and the toggle that decides whether it is ever bought.
		UpgradeToggle[i] = toggle
		UpgradeByName[displayName] = i
		table.insert(upgradeNames, displayName)
		count += 1
	end
	-- The meta is a hash, so it comes out in a different order every session. Only the names
	-- after 'None' are sorted, since 'None' has to stay first: the dropdown ignores Default
	-- and always opens on the first entry.
	table.sort(upgradeNames, function(a, b)
		if a == 'None' or b == 'None' then return a == 'None' end
		return a < b
	end)
	Preferred = AutoBuy:CreateDropdown({
		Name = 'Preferred Upgrade',
		Tooltip = 'Maxes this one before any other',
		Function = function()
			npctick = tick()
		end,
		List = upgradeNames,
		Darker = true
	})
	-- Hidden and shown with the rest of the upgrade settings.
	table.insert(UpgradeToggles, Preferred)
	BedwarsCheck = AutoBuy:CreateToggle({
		Name = 'Only Bedwars',
		Tooltip = 'Only runs while in a bedwars queue',
		Function = function()
			if AutoBuy.Enabled then
				AutoBuy:Toggle()
				AutoBuy:Toggle()
			end
		end,
		Default = true
	})
	GUI = AutoBuy:CreateToggle({Name = 'GUI check', Tooltip = 'Stops acting while a game menu is open'})
	SmartCheck = AutoBuy:CreateToggle({
		Name = 'Smart check',
		Default = true,
		Tooltip = 'Saves everything for iron armor first\nNeeds Buy Armor on'
	})
	AutoBuy:CreateTextList({
		Name = 'Item',
		Tooltip = 'Which items this applies to',
		Placeholder = 'priority/item/amount/after',
		Function = function(list)
			table.clear(Custom)
			table.clear(CustomPost)
			for _, entry in list do
				local tab = entry:split('/')
				local ind = tonumber(tab[1])
				if ind then
					(tab[4] and CustomPost or Custom)[ind] = function(currencytable, shop)
						if not shop then return end
						-- Held back too: these are bought with the same iron the armor needs,
						-- so buying them first is why there was none left for it.
						if savingForArmor() then return end
	
						local v = bedwars.Shop.getShopItem(tab[2], lplr)
						if v then
							-- getTeamWool was renamed getTeamWoolById upstream; same signature
							-- (team id in, wool ItemType out).
							local item = getItem(tab[2] == 'wool_white' and bedwars.Shop.getTeamWoolById(lplr:GetAttribute('Team')) or tab[2])
							item = (item and tonumber(tab[3]) - item.amount or tonumber(tab[3])) // v.amount
							if item > 0 and canBuy(v, currencytable, item) then
								for _ = 1, item do
									buyItem(v, currencytable)
								end
								return true
							end
						end
					end
				end
			end
		end
	})
end)

local AutoConsume
local Legit
local Health
local SpeedPotion
local SpeedPie
local JumpPotion
local Invisibility
local Apple
local GoldenApple
local ShieldPotion
local potions
local consuming = false
local lastHealth

--[[
	Blatant sends the consume straight off without the item ever being in your hand.

	Legit hands the job back to the game. Equipping a consumable turns on that item's own
	handler, which binds an action called 'consume-item' - the one your mouse button runs.
	Calling that same bound function is what plays the animation, starts the hold, and
	consumes when the hold finishes, cooldown checks and all. Nothing here reimplements
	any of it, and no consume is sent by hand, so nothing can be double-consumed either.

	Equipping only through switchItem was why this looked broken before: that sets the
	held item without the hotbar following, so the game never turned the item's handler
	on, there was no animation, and all that happened was a flicker before something else
	took the hand back.
]]
local function consumeTime(item)
	local meta = bedwars.ItemMeta[item.itemType]
	local consumable = meta and meta.consumable
	return (consumable and consumable.consumeTime) or 1
end

local function hotbarSlot(itemType)
	for i, v in store.inventory.hotbar do
		if v.item and v.item.itemType == itemType then
			return i - 1
		end
	end
end

local function boundConsume()
	local binder = bedwars.ActionBinder
	local action = binder and binder.registeredActions and binder.registeredActions['consume-item']
	return action and action.boundFunction or nil
end

local function legitConsume(item)
	if consuming then return end
	consuming = true

	task.spawn(function()
		local previous = store.hand.tool
		pcall(function()
			local slot = hotbarSlot(item.itemType)
			if slot then
				hotbarSwitch(slot)
			end
			switchItem(item.tool)

			-- The handler binds itself once the item is actually in hand, so wait for it
			-- rather than assuming it is already there.
			local run
			for _ = 1, 20 do
				run = boundConsume()
				if run then break end
				task.wait()
			end
			if not run then return end

			run('consume-item', Enum.UserInputState.Begin, newproxy(true))
			-- The hold finishes on its own and consumes; this only releases afterwards,
			-- the same as letting go of the button.
			task.wait(consumeTime(item) + 0.1)
			run('consume-item', Enum.UserInputState.End, newproxy(true))
		end)

		if previous and previous.Parent then
			pcall(switchItem, previous)
		end
		consuming = false
	end)
end

-- retry is for the potions, which are sometimes refused outright on the first call. The
-- food and shield paths never did this and are left alone.
local function consume(item, retry)
	if not (item and item.tool) then return end

	if Legit and Legit.Enabled then
		legitConsume(item)
		return
	end

	if retry then
		for _ = 1, 4 do
			if bedwars.Client:Get(remotes.ConsumeItem):CallServer({item = item.tool}) then break end
		end
		return
	end

	bedwars.Client:Get(remotes.ConsumeItem):CallServerAsync({item = item.tool})
end

local function hasEffect(effect)
	return lplr.Character and lplr.Character:GetAttribute('StatusEffect_'..effect)
end

--[[
	Food is only for the moment your health actually drops.

	Anything else that runs this check would otherwise reach for an apple purely because
	your health happened to be low at the time. Health ticking back up is a change, so
	regenerating ate the rest of the stack part way through the apple already working; and
	placing a block is an inventory change, so building while hurt started a consume on
	every single block and left you unable to build at all.

	The first look is allowed through, so switching this on while already hurt heals you
	rather than waiting for the next hit.
]]
local function healthDropped()
	local current = lplr.Character and lplr.Character:GetAttribute('Health')
	if not current then return false end

	local previous = lastHealth
	lastHealth = current
	return previous == nil or current < previous
end

local function consumeCheck(attribute)
	if not entitylib.isAlive then return end

	-- Worked out up front rather than inside the food branch, so the reading stays current
	-- even while food is switched off and there is no stale one to compare against later.
	local healthEvent = (not attribute) or attribute:find('Health') ~= nil
	local dropped = healthEvent and healthDropped()

	if potions then
		for _, potion in potions do
			if not potion.Toggle.Enabled then continue end
			if attribute and attribute ~= 'StatusEffect_'..potion.Effect then continue end
			if hasEffect(potion.Effect) then continue end

			local item = getItem(potion.Item)
			if item then
				consume(item, true)
			end
		end
	end

	if Apple.Enabled and healthEvent and dropped then
		if (lplr.Character:GetAttribute('Health') / lplr.Character:GetAttribute('MaxHealth')) <= (Health.Value / 100) then
			-- Golden apples come before plain ones, and only while their buff is not
			-- already running - eating a second one on top of the first is wasted.
			local apple = getItem('orange')
				or (GoldenApple.Enabled and not hasEffect('golden_apple') and getItem('golden_apple'))
				or getItem('apple')

			if apple then
				consume(apple)
			end
		end
	end

	if ShieldPotion.Enabled and (not attribute or attribute:find('Shield')) then
		if (lplr.Character:GetAttribute('Shield_POTION') or 0) == 0 then
			consume(getItem('big_shield') or getItem('mini_shield'))
		end
	end
end

AutoConsume = vain.Categories.Inventory:CreateModule({
	Name = 'AutoConsume',
	Function = function(callback)
		if callback then
			AutoConsume:Clean(vainEvents.InventoryAmountChanged.Event:Connect(consumeCheck))
			AutoConsume:Clean(vainEvents.AttributeChanged.Event:Connect(function(attribute)
				if attribute:find('Shield') or attribute:find('Health') or attribute:find('StatusEffect_') then
					consumeCheck(attribute)
				end
			end))
			consumeCheck()
		else
			consuming = false
			lastHealth = nil
		end
	end,
	Tooltip = 'Automatically heals for you when health or shield is under threshold.'
})
Legit = AutoConsume:CreateToggle({
	Name = 'Legit',
	Tooltip = 'Equips and uses items the way the game does'
})
Health = AutoConsume:CreateSlider({
	Name = 'Health Percent',
	Tooltip = 'Triggers once your health drops below this percentage',
	Min = 1,
	Max = 99,
	Default = 70,
	Suffix = '%'
})
SpeedPotion = AutoConsume:CreateToggle({
	Name = 'Speed Potions',
	Tooltip = 'Uses speed potions',
	Default = true
})
SpeedPie = AutoConsume:CreateToggle({
	Name = 'Speed Pie',
	Tooltip = 'Eats speed pies',
	Default = true
})
JumpPotion = AutoConsume:CreateToggle({
	Name = 'Jump Potions',
	Tooltip = 'Uses jump potions',
	Default = true
})
Invisibility = AutoConsume:CreateToggle({
	Name = 'Invisibility Potions',
	Tooltip = 'Uses invisibility potions',
	Default = true
})
Apple = AutoConsume:CreateToggle({
	Name = 'Apple',
	Tooltip = 'Eats apples',
	Default = true
})
GoldenApple = AutoConsume:CreateToggle({
	Name = 'Golden Apple',
	Tooltip = 'Eats golden apples before plain ones',
	Default = true,
	Darker = true
})
ShieldPotion = AutoConsume:CreateToggle({
	Name = 'Shield Potions',
	Tooltip = 'Uses shield potions',
	Default = true
})

-- Built once the toggles exist. Each is used whenever its effect is not already running.
potions = {
	{Toggle = SpeedPotion, Item = 'speed_potion', Effect = 'speed'},
	{Toggle = SpeedPie, Item = 'pie', Effect = 'speed_pie'},
	{Toggle = JumpPotion, Item = 'jump_potion', Effect = 'jump'},
	{Toggle = Invisibility, Item = 'invisibility_potion', Effect = 'invisibility'}
}


run(function()
	local AutoHotbar
	local Mode
	local Clear
	local List
	local Active
	
	local function CreateWindow(self)
		local selectedslot = 1
		local window = Instance.new('Frame')
		window.Name = 'HotbarGUI'
		window.Size = UDim2.fromOffset(660, 465)
		window.Position = UDim2.fromScale(0.5, 0.5)
		window.BackgroundColor3 = uipallet.Main
		window.AnchorPoint = Vector2.new(0.5, 0.5)
		window.Visible = false
		window.Parent = vain.gui.ScaledGui
		local title = Instance.new('TextLabel')
		title.Name = 'Title'
		title.Size = UDim2.new(1, -10, 0, 20)
		title.Position = UDim2.fromOffset(math.abs(title.Size.X.Offset), 12)
		title.BackgroundTransparency = 1
		title.Text = 'AutoHotbar'
		title.TextXAlignment = Enum.TextXAlignment.Left
		title.TextColor3 = uipallet.Text
		title.TextSize = 13
		title.FontFace = uipallet.Font
		title.Parent = window
		local divider = Instance.new('Frame')
		divider.Name = 'Divider'
		divider.Size = UDim2.new(1, 0, 0, 1)
		divider.Position = UDim2.fromOffset(0, 40)
		divider.BackgroundColor3 = color.Light(uipallet.Main, 0.04)
		divider.BorderSizePixel = 0
		divider.Parent = window
		addBlur(window)
		local modal = Instance.new('TextButton')
		modal.Text = ''
		modal.BackgroundTransparency = 1
		modal.Modal = true
		modal.Parent = window
		local corner = Instance.new('UICorner')
		corner.CornerRadius = UDim.new(0, 5)
		corner.Parent = window
		local close = Instance.new('ImageButton')
		close.Name = 'Close'
		close.Size = UDim2.fromOffset(24, 24)
		close.Position = UDim2.new(1, -35, 0, 9)
		close.BackgroundColor3 = Color3.new(1, 1, 1)
		close.BackgroundTransparency = 1
		close.Image = getcustomasset('vain/assets/new/close.png')
		close.ImageColor3 = color.Light(uipallet.Text, 0.2)
		close.ImageTransparency = 0.5
		close.AutoButtonColor = false
		close.Parent = window
		close.MouseEnter:Connect(function()
			close.ImageTransparency = 0.3
			tween:Tween(close, TweenInfo.new(0.2), {
				BackgroundTransparency = 0.6
			})
		end)
		close.MouseLeave:Connect(function()
			close.ImageTransparency = 0.5
			tween:Tween(close, TweenInfo.new(0.2), {
				BackgroundTransparency = 1
			})
		end)
		close.MouseButton1Click:Connect(function()
			window.Visible = false
			vain.gui.ScaledGui.ClickGui.Visible = true
		end)
		local closecorner = Instance.new('UICorner')
		closecorner.CornerRadius = UDim.new(1, 0)
		closecorner.Parent = close
		local bigslot = Instance.new('Frame')
		bigslot.Size = UDim2.fromOffset(110, 111)
		bigslot.Position = UDim2.fromOffset(11, 71)
		bigslot.BackgroundColor3 = color.Dark(uipallet.Main, 0.02)
		bigslot.Parent = window
		local bigslotcorner = Instance.new('UICorner')
		bigslotcorner.CornerRadius = UDim.new(0, 4)
		bigslotcorner.Parent = bigslot
		local bigslotstroke = Instance.new('UIStroke')
		bigslotstroke.Color = color.Light(uipallet.Main, 0.034)
		bigslotstroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		bigslotstroke.Parent = bigslot
		local slotnum = Instance.new('TextLabel')
		slotnum.Size = UDim2.fromOffset(80, 20)
		slotnum.Position = UDim2.fromOffset(25, 200)
		slotnum.BackgroundTransparency = 1
		slotnum.Text = 'SLOT 1'
		slotnum.TextColor3 = color.Dark(uipallet.Text, 0.1)
		slotnum.TextSize = 12
		slotnum.FontFace = uipallet.Font
		slotnum.Parent = window
		for i = 1, 9 do
			local slotbkg = Instance.new('TextButton')
			slotbkg.Name = 'Slot'..i
			slotbkg.Size = UDim2.fromOffset(51, 52)
			slotbkg.Position = UDim2.fromOffset(89 + (i * 55), 382)
			slotbkg.BackgroundColor3 = color.Dark(uipallet.Main, 0.02)
			slotbkg.Text = ''
			slotbkg.AutoButtonColor = false
			slotbkg.Parent = window
			local slotimage = Instance.new('ImageLabel')
			slotimage.Size = UDim2.fromOffset(32, 32)
			slotimage.Position = UDim2.new(0.5, -16, 0.5, -16)
			slotimage.BackgroundTransparency = 1
			slotimage.Image = ''
			slotimage.Parent = slotbkg
			local slotcorner = Instance.new('UICorner')
			slotcorner.CornerRadius = UDim.new(0, 4)
			slotcorner.Parent = slotbkg
			local slotstroke = Instance.new('UIStroke')
			slotstroke.Color = color.Light(uipallet.Main, 0.04)
			slotstroke.Thickness = 2
			slotstroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
			slotstroke.Enabled = i == selectedslot
			slotstroke.Parent = slotbkg
			slotbkg.MouseEnter:Connect(function()
				slotbkg.BackgroundColor3 = color.Light(uipallet.Main, 0.034)
			end)
			slotbkg.MouseLeave:Connect(function()
				slotbkg.BackgroundColor3 = color.Dark(uipallet.Main, 0.02)
			end)
			slotbkg.MouseButton1Click:Connect(function()
				window['Slot'..selectedslot].UIStroke.Enabled = false
				selectedslot = i
				slotstroke.Enabled = true
				slotnum.Text = 'SLOT '..selectedslot
			end)
			slotbkg.MouseButton2Click:Connect(function()
				local obj = self.Hotbars[self.Selected]
				if obj then
					window['Slot'..i].ImageLabel.Image = ''
					obj.Hotbar[tostring(i)] = nil
					obj.Object['Slot'..i].Image = '	'
				end
			end)
		end
		local searchbkg = Instance.new('Frame')
		searchbkg.Size = UDim2.fromOffset(496, 31)
		searchbkg.Position = UDim2.fromOffset(142, 80)
		searchbkg.BackgroundColor3 = color.Light(uipallet.Main, 0.034)
		searchbkg.Parent = window
		local search = Instance.new('TextBox')
		search.Size = UDim2.new(1, -10, 0, 31)
		search.Position = UDim2.fromOffset(10, 0)
		search.BackgroundTransparency = 1
		search.Text = ''
		search.PlaceholderText = ''
		search.TextXAlignment = Enum.TextXAlignment.Left
		search.TextColor3 = uipallet.Text
		search.TextSize = 12
		search.FontFace = uipallet.Font
		search.ClearTextOnFocus = false
		search.Parent = searchbkg
		local searchcorner = Instance.new('UICorner')
		searchcorner.CornerRadius = UDim.new(0, 4)
		searchcorner.Parent = searchbkg
		local searchicon = Instance.new('ImageLabel')
		searchicon.Size = UDim2.fromOffset(14, 14)
		searchicon.Position = UDim2.new(1, -26, 0, 8)
		searchicon.BackgroundTransparency = 1
		searchicon.Image = getcustomasset('vain/assets/new/search.png')
		searchicon.ImageColor3 = color.Light(uipallet.Main, 0.37)
		searchicon.Parent = searchbkg
		local children = Instance.new('ScrollingFrame')
		children.Name = 'Children'
		children.Size = UDim2.fromOffset(500, 240)
		children.Position = UDim2.fromOffset(144, 122)
		children.BackgroundTransparency = 1
		children.BorderSizePixel = 0
		children.ScrollBarThickness = 2
		children.ScrollBarImageTransparency = 0.75
		children.CanvasSize = UDim2.new()
		children.Parent = window
		local windowlist = Instance.new('UIGridLayout')
		windowlist.SortOrder = Enum.SortOrder.LayoutOrder
		windowlist.FillDirectionMaxCells = 9
		windowlist.CellSize = UDim2.fromOffset(51, 52)
		windowlist.CellPadding = UDim2.fromOffset(4, 3)
		windowlist.Parent = children
		windowlist:GetPropertyChangedSignal('AbsoluteContentSize'):Connect(function()
			if vain.ThreadFix then
				setthreadidentity(8)
			end
			children.CanvasSize = UDim2.fromOffset(0, windowlist.AbsoluteContentSize.Y / vain.guiscale.Scale)
		end)
		table.insert(vain.Windows, window)
	
		local function createitem(id, image)
			local slotbkg = Instance.new('TextButton')
			slotbkg.BackgroundColor3 = color.Light(uipallet.Main, 0.02)
			slotbkg.Text = ''
			slotbkg.AutoButtonColor = false
			slotbkg.Parent = children
			local slotimage = Instance.new('ImageLabel')
			slotimage.Size = UDim2.fromOffset(32, 32)
			slotimage.Position = UDim2.new(0.5, -16, 0.5, -16)
			slotimage.BackgroundTransparency = 1
			slotimage.Image = image
			slotimage.Parent = slotbkg
			local slotcorner = Instance.new('UICorner')
			slotcorner.CornerRadius = UDim.new(0, 4)
			slotcorner.Parent = slotbkg
			slotbkg.MouseEnter:Connect(function()
				slotbkg.BackgroundColor3 = color.Light(uipallet.Main, 0.04)
			end)
			slotbkg.MouseLeave:Connect(function()
				slotbkg.BackgroundColor3 = color.Light(uipallet.Main, 0.02)
			end)
			slotbkg.MouseButton1Click:Connect(function()
				local obj = self.Hotbars[self.Selected]
				if obj then
					window['Slot'..selectedslot].ImageLabel.Image = image
					obj.Hotbar[tostring(selectedslot)] = id
					obj.Object['Slot'..selectedslot].Image = image
				end
			end)
		end
	
		local function indexSearch(text)
			for _, v in children:GetChildren() do
				if v:IsA('TextButton') then
					v:ClearAllChildren()
					v:Destroy()
				end
			end
	
			if text == '' then
				for _, v in {'diamond_sword', 'diamond_pickaxe', 'diamond_axe', 'shears', 'wood_bow', 'wool_white', 'fireball', 'apple', 'iron', 'gold', 'diamond', 'emerald'} do
					createitem(v, bedwars.ItemMeta[v].image)
				end
				return
			end
	
			for i, v in bedwars.ItemMeta do
				if text:lower() == i:lower():sub(1, text:len()) then
					if not v.image then continue end
					createitem(i, v.image)
				end
			end
		end
	
		search:GetPropertyChangedSignal('Text'):Connect(function()
			indexSearch(search.Text)
		end)
		indexSearch('')
	
		return window
	end
	
	vain.Components.HotbarList = function(optionsettings, children, api)
		if vain.ThreadFix then
			setthreadidentity(8)
		end
		local optionapi = {
			Type = 'HotbarList',
			Hotbars = {},
			Selected = 1
		}
		local hotbarlist = Instance.new('TextButton')
		hotbarlist.Name = 'HotbarList'
		hotbarlist.Size = UDim2.fromOffset(220, 40)
		hotbarlist.BackgroundColor3 = optionsettings.Darker and (children.BackgroundColor3 == color.Dark(uipallet.Main, 0.02) and color.Dark(uipallet.Main, 0.04) or color.Dark(uipallet.Main, 0.02)) or children.BackgroundColor3
		hotbarlist.Text = ''
		hotbarlist.BorderSizePixel = 0
		hotbarlist.AutoButtonColor = false
		hotbarlist.Parent = children
		local textbkg = Instance.new('Frame')
		textbkg.Name = 'BKG'
		textbkg.Size = UDim2.new(1, -20, 0, 31)
		textbkg.Position = UDim2.fromOffset(10, 4)
		textbkg.BackgroundColor3 = color.Light(uipallet.Main, 0.034)
		textbkg.Parent = hotbarlist
		local textbkgcorner = Instance.new('UICorner')
		textbkgcorner.CornerRadius = UDim.new(0, 4)
		textbkgcorner.Parent = textbkg
		local textbutton = Instance.new('TextButton')
		textbutton.Name = 'HotbarList'
		textbutton.Size = UDim2.new(1, -2, 1, -2)
		textbutton.Position = UDim2.fromOffset(1, 1)
		textbutton.BackgroundColor3 = uipallet.Main
		textbutton.Text = ''
		textbutton.AutoButtonColor = false
		textbutton.Parent = textbkg
		textbutton.MouseEnter:Connect(function()
			tween:Tween(textbkg, TweenInfo.new(0.2), {
				BackgroundColor3 = color.Light(uipallet.Main, 0.14)
			})
		end)
		textbutton.MouseLeave:Connect(function()
			tween:Tween(textbkg, TweenInfo.new(0.2), {
				BackgroundColor3 = color.Light(uipallet.Main, 0.034)
			})
		end)
		local textbuttoncorner = Instance.new('UICorner')
		textbuttoncorner.CornerRadius = UDim.new(0, 4)
		textbuttoncorner.Parent = textbutton
		local textbuttonicon = Instance.new('ImageLabel')
		textbuttonicon.Size = UDim2.fromOffset(12, 12)
		textbuttonicon.Position = UDim2.fromScale(0.5, 0.5)
		textbuttonicon.AnchorPoint = Vector2.new(0.5, 0.5)
		textbuttonicon.BackgroundTransparency = 1
		textbuttonicon.Image = getcustomasset('vain/assets/new/add.png')
		textbuttonicon.ImageColor3 = Color3.fromHSV(0.46, 0.96, 0.52)
		textbuttonicon.Parent = textbutton
		local childrenlist = Instance.new('Frame')
		childrenlist.Size = UDim2.new(1, 0, 1, -40)
		childrenlist.Position = UDim2.fromOffset(0, 40)
		childrenlist.BackgroundTransparency = 1
		childrenlist.Parent = hotbarlist
		local windowlist = Instance.new('UIListLayout')
		windowlist.SortOrder = Enum.SortOrder.LayoutOrder
		windowlist.HorizontalAlignment = Enum.HorizontalAlignment.Center
		windowlist.Padding = UDim.new(0, 3)
		windowlist.Parent = childrenlist
		windowlist:GetPropertyChangedSignal('AbsoluteContentSize'):Connect(function()
			if vain.ThreadFix then
				setthreadidentity(8)
			end
			hotbarlist.Size = UDim2.fromOffset(220, math.min(43 + windowlist.AbsoluteContentSize.Y / vain.guiscale.Scale, 603))
		end)
		textbutton.MouseButton1Click:Connect(function()
			optionapi:AddHotbar()
		end)
		optionapi.Window = CreateWindow(optionapi)
	
		function optionapi:Save(savetab)
			local hotbars = {}
			for _, v in self.Hotbars do
				table.insert(hotbars, v.Hotbar)
			end
			savetab.HotbarList = {
				Selected = self.Selected,
				Hotbars = hotbars
			}
		end
	
		function optionapi:Load(savetab)
			for _, v in self.Hotbars do
				v.Object:ClearAllChildren()
				v.Object:Destroy()
				table.clear(v.Hotbar)
			end
			table.clear(self.Hotbars)
			for _, v in savetab.Hotbars do
				self:AddHotbar(v)
			end
			self.Selected = savetab.Selected or 1
		end
	
		function optionapi:AddHotbar(data)
			local hotbardata = {Hotbar = data or {}}
			table.insert(self.Hotbars, hotbardata)
			local hotbar = Instance.new('TextButton')
			hotbar.Size = UDim2.fromOffset(200, 27)
			hotbar.BackgroundColor3 = table.find(self.Hotbars, hotbardata) == self.Selected and color.Light(uipallet.Main, 0.034) or uipallet.Main
			hotbar.Text = ''
			hotbar.AutoButtonColor = false
			hotbar.Parent = childrenlist
			hotbardata.Object = hotbar
			local hotbarcorner = Instance.new('UICorner')
			hotbarcorner.CornerRadius = UDim.new(0, 4)
			hotbarcorner.Parent = hotbar
			for i = 1, 9 do
				local slot = Instance.new('ImageLabel')
				slot.Name = 'Slot'..i
				slot.Size = UDim2.fromOffset(17, 18)
				slot.Position = UDim2.fromOffset(-7 + (i * 18), 5)
				slot.BackgroundColor3 = color.Dark(uipallet.Main, 0.02)
				slot.Image = hotbardata.Hotbar[tostring(i)] and bedwars.getIcon({itemType = hotbardata.Hotbar[tostring(i)]}, true) or ''
				slot.BorderSizePixel = 0
				slot.Parent = hotbar
			end
			hotbar.MouseButton1Click:Connect(function()
				local ind = table.find(optionapi.Hotbars, hotbardata)
				if ind == optionapi.Selected then
					vain.gui.ScaledGui.ClickGui.Visible = false
					optionapi.Window.Visible = true
					for i = 1, 9 do
						optionapi.Window['Slot'..i].ImageLabel.Image = hotbardata.Hotbar[tostring(i)] and bedwars.getIcon({itemType = hotbardata.Hotbar[tostring(i)]}, true) or ''
					end
				else
					if optionapi.Hotbars[optionapi.Selected] then
						optionapi.Hotbars[optionapi.Selected].Object.BackgroundColor3 = uipallet.Main
					end
					hotbar.BackgroundColor3 = color.Light(uipallet.Main, 0.034)
					optionapi.Selected = ind
				end
			end)
			local close = Instance.new('ImageButton')
			close.Name = 'Close'
			close.Size = UDim2.fromOffset(16, 16)
			close.Position = UDim2.new(1, -23, 0, 6)
			close.BackgroundColor3 = Color3.new(1, 1, 1)
			close.BackgroundTransparency = 1
			close.Image = getcustomasset('vain/assets/new/closemini.png')
			close.ImageColor3 = color.Light(uipallet.Text, 0.2)
			close.ImageTransparency = 0.5
			close.AutoButtonColor = false
			close.Parent = hotbar
			local closecorner = Instance.new('UICorner')
			closecorner.CornerRadius = UDim.new(1, 0)
			closecorner.Parent = close
			close.MouseEnter:Connect(function()
				close.ImageTransparency = 0.3
				tween:Tween(close, TweenInfo.new(0.2), {
					BackgroundTransparency = 0.6
				})
			end)
			close.MouseLeave:Connect(function()
				close.ImageTransparency = 0.5
				tween:Tween(close, TweenInfo.new(0.2), {
					BackgroundTransparency = 1
				})
			end)
			close.MouseButton1Click:Connect(function()
				local ind = table.find(self.Hotbars, hotbardata)
				local obj = self.Hotbars[self.Selected]
				local obj2 = self.Hotbars[ind]
				if obj and obj2 then
					obj2.Object:ClearAllChildren()
					obj2.Object:Destroy()
					table.remove(self.Hotbars, ind)
					ind = table.find(self.Hotbars, obj)
					self.Selected = table.find(self.Hotbars, obj) or 1
				end
			end)
		end
	
		api.Options.HotbarList = optionapi
	
		return optionapi
	end
	
	local function getBlock()
		local clone = table.clone(store.inventory.inventory.items)
		table.sort(clone, function(a, b)
			return a.amount < b.amount
		end)
	
		for _, item in clone do
			local block = bedwars.ItemMeta[item.itemType].block
			if block and not block.seeThrough then
				return item
			end
		end
	end
	
	local function getCustomItem(v)
		if v == 'diamond_sword' then
			local sword = store.tools.sword
			v = sword and sword.itemType or 'wood_sword'
		elseif v == 'diamond_pickaxe' then
			local pickaxe = store.tools.stone
			v = pickaxe and pickaxe.itemType or 'wood_pickaxe'
		elseif v == 'diamond_axe' then
			local axe = store.tools.wood
			v = axe and axe.itemType or 'wood_axe'
		elseif v == 'wood_bow' then
			local bow = getBow()
			v = bow and bow.itemType or 'wood_bow'
		elseif v == 'wool_white' then
			local block = getBlock()
			v = block and block.itemType or 'wool_white'
		end
	
		return v
	end
	
	local function findItemInTable(tab, item)
		for slot, v in tab do
			if item.itemType == getCustomItem(v) then
				return tonumber(slot)
			end
		end
	end
	
	local function findInHotbar(item)
		for i, v in store.inventory.hotbar do
			if v.item and v.item.itemType == item.itemType then
				return i - 1, v.item
			end
		end
	end
	
	local function findInInventory(item)
		for _, v in store.inventory.inventory.items do
			if v.itemType == item.itemType then
				return v
			end
		end
	end
	
	local function dispatch(...)
		bedwars.Store:dispatch(...)
		vainEvents.InventoryChanged.Event:Wait()
	end
	
	local function sortCallback()
		if Active then return end
		Active = true
		local items = (List.Hotbars[List.Selected] and List.Hotbars[List.Selected].Hotbar or {})
	
		for _, v in store.inventory.inventory.items do
			local slot = findItemInTable(items, v)
			if slot then
				local olditem = store.inventory.hotbar[slot]
				if olditem.item and olditem.item.itemType == v.itemType then continue end
				if olditem.item then
					dispatch({
						type = 'InventoryRemoveFromHotbar',
						slot = slot - 1
					})
				end
	
				local newslot = findInHotbar(v)
				if newslot then
					dispatch({
						type = 'InventoryRemoveFromHotbar',
						slot = newslot
					})
					if olditem.item then
						dispatch({
							type = 'InventoryAddToHotbar',
							item = findInInventory(olditem.item),
							slot = newslot
						})
					end
				end
	
				dispatch({
					type = 'InventoryAddToHotbar',
					item = findInInventory(v),
					slot = slot - 1
				})
			elseif Clear.Enabled then
				local newslot = findInHotbar(v)
				if newslot then
				   	dispatch({
						type = 'InventoryRemoveFromHotbar',
						slot = newslot
					})
				end
			end
		end
	
		Active = false
	end
	
	AutoHotbar = vain.Categories.Inventory:CreateModule({
		Name = 'AutoHotbar',
		Function = function(callback)
			if callback then
				task.spawn(sortCallback)
				if Mode.Value == 'On Key' then
					AutoHotbar:Toggle()
					return
				end
	
				AutoHotbar:Clean(vainEvents.InventoryAmountChanged.Event:Connect(sortCallback))
			end
		end,
		Tooltip = 'Automatically arranges hotbar to your liking.'
	})
	Mode = AutoHotbar:CreateDropdown({
		Name = 'Activation',
		Tooltip = 'What triggers this module',
		List = {'Toggle', 'On Key'},
		Function = function()
			if AutoHotbar.Enabled then
				AutoHotbar:Toggle()
				AutoHotbar:Toggle()
			end
		end
	})
	Clear = AutoHotbar:CreateToggle({Name = 'Clear Hotbar', Tooltip = 'Empties the hotbar before sorting it'})
	List = AutoHotbar:CreateHotbarList({})
end)

run(function()
	local Value
	local oldclickhold, oldshowprogress
	
	local FastConsume = vain.Categories.Inventory:CreateModule({
		Name = 'FastConsume',
		Function = function(callback)
			if callback then
				oldclickhold = bedwars.ClickHold.startClick
				oldshowprogress = bedwars.ClickHold.showProgress
				bedwars.ClickHold.startClick = function(self)
					self.startedClickTime = tick()
					local handle = self:showProgress()
					local clicktime = self.startedClickTime
					bedwars.RuntimeLib.Promise.defer(function()
						task.wait(self.durationSeconds * (Value.Value / 40))
						if handle == self.handle and clicktime == self.startedClickTime and self.closeOnComplete then
							self:hideProgress()
							if self.onComplete then self.onComplete() end
							if self.onPartialComplete then self.onPartialComplete(1) end
							self.startedClickTime = -1
						end
					end)
				end
	
				bedwars.ClickHold.showProgress = function(self)
					local roact = debug.getupvalue(oldshowprogress, 1)
					local countdown = roact.mount(roact.createElement('ScreenGui', {}, { roact.createElement('Frame', {
						[roact.Ref] = self.wrapperRef,
						Size = UDim2.new(),
						Position = UDim2.fromScale(0.5, 0.55),
						AnchorPoint = Vector2.new(0.5, 0),
						BackgroundColor3 = Color3.fromRGB(0, 0, 0),
						BackgroundTransparency = 0.8
					}, { roact.createElement('Frame', {
						[roact.Ref] = self.progressRef,
						Size = UDim2.fromScale(0, 1),
						BackgroundColor3 = Color3.new(1, 1, 1),
						BackgroundTransparency = 0.5
					}) }) }), lplr:FindFirstChild('PlayerGui'))
	
					self.handle = countdown
					local sizetween = tweenService:Create(self.wrapperRef:getValue(), TweenInfo.new(0.1), {
						Size = UDim2.fromScale(0.11, 0.005)
					})
					local countdowntween = tweenService:Create(self.progressRef:getValue(), TweenInfo.new(self.durationSeconds * (Value.Value / 100), Enum.EasingStyle.Linear), {
						Size = UDim2.fromScale(1, 1)
					})
	
					sizetween:Play()
					countdowntween:Play()
					table.insert(self.tweens, countdowntween)
					table.insert(self.tweens, sizetween)
					
					return countdown
				end
			else
				bedwars.ClickHold.startClick = oldclickhold
				bedwars.ClickHold.showProgress = oldshowprogress
				oldclickhold = nil
				oldshowprogress = nil
			end
		end,
		Tooltip = 'Use/Consume items quicker.'
	})
	Value = FastConsume:CreateSlider({
		Name = 'Multiplier',
		Tooltip = 'Multiplies the effect strength',
		Min = 0,
		Max = 100
	})
end)

run(function()
	local FastDrop
	
	--[[
		The key the game itself drops on, which the player can rebind in settings. H is only
		the default - the tooltip claimed Q, which was neither the default nor what this
		listened for, so it was wrong however the game was set up.
	
		Read live rather than once at load, because a rebind takes effect immediately and
		both what this listens for and what the tooltip says have to follow it.
	]]
	local function dropKey()
		local ok, keybinds = pcall(function()
			return bedwars.Knit.Controllers.KeybindLoadController:getKeybinds()
		end)
	
		local actions = ok and keybinds and keybinds.keyboard and keybinds.keyboard.controlActions
		local key = actions and actions.DropItem
		-- Bindable actions are not all keyboard keys - Attack is a mouse button - so anything
		-- IsKeyDown cannot be asked about falls back to the default.
		if typeof(key) == 'EnumItem' and key.EnumType == Enum.KeyCode then
			return key
		end
		return Enum.KeyCode.H
	end
	
	FastDrop = vain.Categories.Inventory:CreateModule({
		Name = 'FastDrop',
		Function = function(callback)
			if callback then
				repeat
					if entitylib.isAlive and (not store.inventory.opened) and (inputService:IsKeyDown(dropKey()) or inputService:IsKeyDown(Enum.KeyCode.Backspace)) and inputService:GetFocusedTextBox() == nil then
						task.spawn(bedwars.ItemDropController.dropItemInHand)
						task.wait()
					else
						task.wait(0.1)
					end
				until not FastDrop.Enabled
			end
		end,
		Tooltip = function()
			return 'Drops items fast when you hold '..dropKey().Name
		end
	})
	
end)

run(function()
	local BedPlates
	local Background
	local Color = {}
	local ShowOwn
	local Quantity
	local FullLayers
	local FullColor = {}
	local UpdateRate
	local Warn
	local Warned = {}
	local Reference = {}
	local Signature = {}
	local Folder = Instance.new('Folder')
	Folder.Parent = vain.gui
	
	-- How deep a wrap is worth reporting on, and a ceiling on how much can be walked in
	-- one go so a huge base cannot stall a refresh.
	local MAX_LAYERS = 6
	local SCAN_LIMIT = 1200
	
	-- Ore is part of the map that happens to be sitting against somebody's wrap, not
	-- something they built to defend it. It is walked past rather than counted, so a bed
	-- that touches a generator does not pick up a stray icon reading 1.
	-- Terrain the map is made of rather than anything anybody placed. Snow is not on sale
	-- in the shop at all - it is what a winter map's ground is covered in - so a bed sitting
	-- on it picked up a plate counting the field it stands in, and the walk spread out
	-- across that field instead of following the wrap round. Stepped over exactly the way
	-- the island underneath is: not counted, not walked through, and not a hole in the layer
	-- either, since it is solid.
	local TERRAIN = {
		snow = true
	}
	
	local IGNORED = {
		iron_ore = true,
		iron_ore_mesh_block = true,
		diamond_ore = true,
		emerald_ore = true,
		crystal_ore = true
	}
	
	--[[
		Walks outwards from the bed one layer at a time and reports what is around it: how
		many of each block, and what each layer is made of.
	
		Following the six faces out from the bed the way the old scan did can only ever meet
		one block per direction per step, so every layer came back as about eight however
		many blocks were really in it. This walks the whole shell instead.
	
		Unbreakable blocks are stepped over rather than counted, which is what keeps the walk
		out of the island the bed is standing on - it is solid, so it is not a hole in the
		layer either, it just is not part of anybody's defence.
	]]
	local function scanBed(bed)
		local names, counts, layers, open, mixed = {}, {}, {}, {}, {}
		local seen, frontier, visited = {}, {}, 0
	
		-- Straight off the block handler rather than assuming which way the bed lies, so a
		-- rotated one is walked from both of its halves like any other.
		for _, v in bedwars.getContainedPositions(bed) do
			local pos = v * 3
			seen[pos] = true
			table.insert(frontier, pos)
		end
	
		for depth = 1, MAX_LAYERS do
			local nextfrontier, types = {}, {}
			layers[depth] = types
	
			for _, pos in frontier do
				for _, side in sides do
					local at = pos + side
					local block = getPlacedBlock(at)
					if not block then
						-- Nothing here, so this layer has a way through it. Checked before the
						-- already-visited test on purpose: a gap next to two different layers
						-- was being claimed by the nearer one and never counted against the
						-- other, so a layer with a hole beside it still came out complete.
						open[depth] = true
						seen[at] = true
						continue
					end
	
					if seen[at] then continue end
					seen[at] = true
					if block == bed or block:GetAttribute('NoBreak') or TERRAIN[block.Name] then continue end
	
					-- Still stepped through, so a wrap with ore embedded in it is followed all
					-- the way round, and still solid, so it does not read as a hole either.
					if IGNORED[block.Name] then
						-- It does stop the layer being a full layer of anything though. A spot
						-- taken by a generator is a spot nobody wrapped, whatever is around it.
						mixed[depth] = true
					else
						if not table.find(names, block.Name) then
							table.insert(names, block.Name)
						end
						counts[block.Name] = (counts[block.Name] or 0) + 1
						types[block.Name] = (types[block.Name] or 0) + 1
					end
	
					visited += 1
					table.insert(nextfrontier, at)
				end
			end
	
			frontier = nextfrontier
			if #frontier == 0 or visited >= SCAN_LIMIT then break end
		end
	
		-- A hole anywhere further in means the wrap has already been breached, so nothing
		-- outside it is a complete layer either. Breaking blocks reshuffles which layer the
		-- survivors land in, and a layer left holding two blocks of one kind would otherwise
		-- report itself complete.
		local breached = false
		local full = {}
		for depth = 1, MAX_LAYERS do
			local types = layers[depth]
			if not types then break end
			if open[depth] then breached = true end
			if breached or mixed[depth] then continue end
	
			local only, kinds = nil, 0
			for name in types do
				only = name
				kinds += 1
			end
			if kinds == 1 then
				full[only] = true
			end
		end
	
		return names, counts, full, layers
	end
	
	-- What the plate would look like, as a string. Re-checking is cheap but tearing down
	-- and rebuilding every icon is not, so with a refresh running on a timer the drawing
	-- only happens when this comes out different from last time.
	local function signature(order, counts, full)
		local parts = {}
		for _, name in order do
			table.insert(parts, name .. 'x' .. counts[name] .. (full[name] and '!' or ''))
		end
		table.insert(parts, tostring(Quantity and Quantity.Enabled) .. tostring(FullLayers and FullLayers.Enabled))
		table.insert(parts, string.format('%.3f %.3f %.3f %.3f', FullColor.Hue or 0, FullColor.Sat or 0, FullColor.Value or 0, FullColor.Opacity or 0))
		return table.concat(parts, '|')
	end
	
	-- A bed carries a NoBreak attribute for the team it belongs to, which is how the game
	-- stops you breaking your own. Asked live rather than cached, since your team is not
	-- settled the moment the plates are first drawn. No team at all - spectating - matches
	-- nothing, so every plate stays up.
	local function isOwnBed(bed)
		return bed:GetAttribute('Team' .. (lplr:GetAttribute('Team') or -1) .. 'NoBreak') ~= nil
	end
	
	-- Which team a bed belongs to, read off the same no-break attribute isOwnBed matches
	-- on: the team barred from breaking a bed is the team that owns it. Lowest id wins so
	-- a bed carrying more than one stays on one answer instead of flipping between them,
	-- since GetAttributes is not ordered. Falls back to the raw number when the queue has
	-- no display name, and to nothing when the bed carries no such attribute at all.
	local function bedTeamName(bed)
		local id
		for name in bed:GetAttributes() do
			local found = tonumber(name:match('^Team(%d+)NoBreak$'))
			if found and (not id or found < id) then
				id = found
			end
		end
		if not id then return end
	
		local queue = bedwars.QueueMeta[store.queueType]
		local team = queue and queue.teams and queue.teams[id]
		return (team and team.displayName) or ('Team ' .. id)
	end
	
	local function refreshAdornee(v)
		if not v.Adornee then return end
	
		local order, counts, full, layers = scanBed(v.Adornee)
		-- Toughest first. A block the metadata has never heard of sorts last rather than
		-- throwing, which would take every plate down with it.
		local function health(name)
			local meta = bedwars.ItemMeta[name]
			return (meta and meta.block and meta.block.health) or 0
		end
		table.sort(order, function(a, b)
			return health(a) > health(b)
		end)
		-- Set before the signature check below, so flicking the setting takes effect even
		-- when nothing about the wrap itself has changed.
		--[[
			Obsidian going onto the ring touching the bed, said once as it happens.
	
			Edge triggered on purpose: the plates are re-scanned several times a second, so
			reporting the state rather than the change would repeat the same warning forever.
			The flag clears when the obsidian is gone, so a bed being re-plated later warns
			again rather than staying silent because it once had some.
		]]
		if Warn and Warn.Enabled then
			local bed = v.Adornee
			local plated = (layers[1] and layers[1].obsidian) ~= nil
	
			if plated and not Warned[bed] then
				if isOwnBed(bed) then
					notif('BedPlates', 'Obsidian is going on your bed!', 8, 'alert')
				else
					local team = bedTeamName(bed)
					notif('BedPlates', team and ('Obsidian is going on the ' .. team .. ' bed!') or 'Someone is putting obsidian on a bed!', 8, 'alert')
				end
			end
			Warned[bed] = plated or nil
		end
	
		v.Enabled = #order > 0 and (not ShowOwn or ShowOwn.Enabled or not isOwnBed(v.Adornee))
	
		local sig = signature(order, counts, full)
		if Signature[v] == sig then return end
		Signature[v] = sig
	
		for _, obj in v.Frame:GetChildren() do
			if obj.Name == 'Block' then
				obj:Destroy()
			end
		end
	
		local showfull = FullLayers and FullLayers.Enabled
		local showcount = Quantity and Quantity.Enabled
	
		for _, block in order do
			local complete = showfull and full[block]
	
			local holder = Instance.new('Frame')
			holder.Name = 'Block'
			holder.Size = UDim2.fromOffset(32, 32)
			holder.BackgroundColor3 = Color3.fromHSV(FullColor.Hue or 0, FullColor.Sat or 0, FullColor.Value or 1)
			holder.BackgroundTransparency = complete and (1 - (FullColor.Opacity or 1)) or 1
			holder.Parent = v.Frame
			local holdercorner = Instance.new('UICorner')
			holdercorner.CornerRadius = UDim.new(0, 4)
			holdercorner.Parent = holder
	
			local blockimage = Instance.new('ImageLabel')
			blockimage.Size = UDim2.fromScale(1, 1)
			blockimage.BackgroundTransparency = 1
			blockimage.Image = bedwars.getIcon({itemType = block}, true)
			blockimage.Parent = holder
	
			if showcount then
				-- Across the whole icon rather than tucked into a corner: at the size these
				-- plates are drawn on screen, anything smaller cannot be read at a glance.
				-- White on a dark outline so it stands off whatever block is behind it.
				local amount = Instance.new('TextLabel')
				amount.Size = UDim2.fromScale(1, 1)
				amount.BackgroundTransparency = 1
				amount.Text = tostring(counts[block])
				amount.TextColor3 = Color3.new(1, 1, 1)
				amount.TextScaled = true
				amount.FontFace = uipallet.FontSemiBold
				amount.ZIndex = 2
				amount.Parent = holder
				local outline = Instance.new('UIStroke')
				outline.Color = Color3.new()
				outline.Thickness = 2
				outline.Parent = amount
				-- Keeps a two digit count off the edges of the icon.
				local padding = Instance.new('UIPadding')
				padding.PaddingTop = UDim.new(0, 3)
				padding.PaddingBottom = UDim.new(0, 3)
				padding.Parent = amount
			end
		end
	end
	
	local function refreshAll()
		for _, v in Reference do
			refreshAdornee(v)
		end
	end
	
	local function Added(v)
		local billboard = Instance.new('BillboardGui')
		billboard.Parent = Folder
		billboard.Name = 'bed'
		billboard.StudsOffsetWorldSpace = Vector3.new(0, 3, 0)
		billboard.Size = UDim2.fromOffset(36, 36)
		billboard.AlwaysOnTop = true
		billboard.ClipsDescendants = false
		billboard.Adornee = v
		local blur = addBlur(billboard)
		blur.Visible = Background.Enabled
		local frame = Instance.new('Frame')
		frame.Size = UDim2.fromScale(1, 1)
		frame.BackgroundColor3 = Color3.fromHSV(Color.Hue, Color.Sat, Color.Value)
		frame.BackgroundTransparency = 1 - (Background.Enabled and Color.Opacity or 0)
		frame.Parent = billboard
		local layout = Instance.new('UIListLayout')
		layout.FillDirection = Enum.FillDirection.Horizontal
		layout.Padding = UDim.new(0, 4)
		layout.VerticalAlignment = Enum.VerticalAlignment.Center
		layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
		layout:GetPropertyChangedSignal('AbsoluteContentSize'):Connect(function()
			billboard.Size = UDim2.fromOffset(math.max(layout.AbsoluteContentSize.X + 4, 36), 36)
		end)
		layout.Parent = frame
		local corner = Instance.new('UICorner')
		corner.CornerRadius = UDim.new(0, 4)
		corner.Parent = frame
		Reference[v] = billboard
		refreshAdornee(billboard)
	end
	
	local function refreshNear(data)
		data = data.blockRef.blockPosition * 3
		for i, v in Reference do
			if (data - i.Position).Magnitude <= 30 then
				refreshAdornee(v)
			end
		end
	end
	
	BedPlates = vain.Categories.Minigames:CreateModule({
		Name = 'BedPlates',
		Function = function(callback)
			if callback then
				for _, v in collectionService:GetTagged('bed') do
					task.spawn(Added, v)
				end
				BedPlates:Clean(vainEvents.PlaceBlockEvent.Event:Connect(refreshNear))
				BedPlates:Clean(vainEvents.BreakBlockEvent.Event:Connect(refreshNear))
				BedPlates:Clean(collectionService:GetInstanceAddedSignal('bed'):Connect(Added))
				BedPlates:Clean(collectionService:GetInstanceRemovedSignal('bed'):Connect(function(v)
					if Reference[v] then
						Signature[Reference[v]] = nil
						Reference[v]:Destroy()
						Reference[v]:ClearAllChildren()
						Reference[v] = nil
					end
				end))
	
				-- The block events only report what the server tells us about, and a layer
				-- that quietly stopped being complete is exactly the thing you want to notice.
				-- Guarded so one bad pass cannot kill the loop, with the wait outside so a
				-- repeating error cannot spin the CPU.
				task.spawn(function()
					repeat
						local ok = pcall(refreshAll)
						-- The slider may not exist yet if a saved config switched this on while the
						-- file was still running, and an error out here would end the loop for good.
						task.wait(ok and UpdateRate and (1 / UpdateRate.Value) or 0.5)
					until not BedPlates.Enabled
				end)
			else
				table.clear(Warned)
				table.clear(Reference)
				table.clear(Signature)
				Folder:ClearAllChildren()
			end
		end,
		Tooltip = 'Displays blocks over the bed'
	})
	Warn = BedPlates:CreateToggle({
		Name = 'Obsidian Warning',
		Tooltip = 'Warns when obsidian reaches a bed'
	})
	UpdateRate = BedPlates:CreateSlider({
		Name = 'Update Rate',
		Tooltip = 'How often the plates are re-checked\nLower costs less performance',
		Min = 1,
		Max = 60,
		Default = 10,
		Suffix = 'hz'
	})
	ShowOwn = BedPlates:CreateToggle({
		Name = 'Show Own',
		Tooltip = 'Also plates your own bed',
		Function = refreshAll,
		Default = true
	})
	Quantity = BedPlates:CreateToggle({
		Name = 'Show Amount',
		Tooltip = 'Shows how many of each block there are',
		Function = refreshAll,
		Default = true
	})
	FullLayers = BedPlates:CreateToggle({
		Name = 'Highlight Full Layers',
		Tooltip = 'Marks blocks that cover a whole layer on their own',
		Function = function(callback)
			if FullColor.Object then
				FullColor.Object.Visible = callback
			end
			refreshAll()
		end,
		Default = true
	})
	FullColor = BedPlates:CreateColorSlider({
		Name = 'Full Layer Color',
		Tooltip = 'Color of the full layer highlight',
		DefaultHue = 0.33,
		DefaultSat = 0.75,
		DefaultValue = 1,
		DefaultOpacity = 0.6,
		Function = refreshAll,
		Darker = true
	})
	Background = BedPlates:CreateToggle({
		Name = 'Background',
		Tooltip = 'Draws a background behind the text',
		Function = function(callback)
			if Color.Object then
				Color.Object.Visible = callback
			end
			for _, v in Reference do
				v.Frame.BackgroundTransparency = 1 - (callback and Color.Opacity or 0)
				v.Blur.Visible = callback
			end
		end,
		Default = true
	})
	Color = BedPlates:CreateColorSlider({
		Name = 'Background Color',
		Tooltip = 'Color of the background',
		DefaultValue = 0,
		DefaultOpacity = 0.5,
		Function = function(hue, sat, val, opacity)
			for _, v in Reference do
				v.Frame.BackgroundColor3 = Color3.fromHSV(hue, sat, val)
				v.Frame.BackgroundTransparency = 1 - opacity
			end
		end,
		Darker = true
	})
	
end)

run(function()
	local Nuker
	local Range
	local BreakSpeed
	local UpdateRate
	local Angle
	local HitChance
	local Chance = {}
	local TargetMode
	local ViewMode
	local Custom
	local Bed
	local LuckyBlock
	local IronOre
	local Tesla
	local Effect
	local CustomHealth = {}
	local Animation
	local SelfBreak
	local InstantBreak
	local LimitItem
	local AutoTool
	local customlist, parts, candidates = {}, {}, {}
	
	-- The route into each thing being dug towards, nearest end first, so a started hole is
	-- carried on down rather than abandoned for whatever the mode ranks best on the outer
	-- face. One table per target, handed straight to breakBlock and refilled by it.
	local tunnel = {}
	local breakOptions = {}
	
	-- Ranks used by the Priority target mode, in the order the categories were tried
	-- before target modes existed.
	local RANK_BED = 1
	local RANK_CUSTOM = 2
	local RANK_ORE = 3
	local RANK_LUCKY = 4
	local RANK_TESLA = 5
	
	-- Random has to stay put once it has chosen, or every pass reshuffles and the nuker
	-- hops between blocks without ever finishing one. Hashing the position gives an order
	-- that is arbitrary but stable, and the salt makes it a different one each time the
	-- module is switched on.
	local randomSalt = 0
	
	local function randomKey(pos)
		local n = math.sin((pos.X * 12.9898) + (pos.Y * 78.233) + (pos.Z * 37.719) + randomSalt) * 43758.5453
		return n - math.floor(n)
	end
	
	local function blockMeta(name)
		local meta = bedwars.ItemMeta[name]
		return meta and meta.block
	end
	
	-- Only 4 of the 14 lucky block types carry the 'LuckyBlock' collection tag - purple,
	-- halloween, flying, glitched and the rest never get it - so collecting by that tag
	-- found nothing in most modes and the toggle looked dead. Every one of them does have
	-- a luckyBlock table on its block meta, which is what the game itself tests.
	local function isLuckyBlock(name)
		local meta = blockMeta(name)
		return (meta and meta.luckyBlock) ~= nil
	end
	
	-- iron_ore is the item you collect; the thing standing in the world is
	-- iron_ore_mesh_block. Both are accepted in case a mode places either.
	local function isIronOre(name)
		return name == 'iron_ore' or name == 'iron_ore_mesh_block'
	end
	
	-- Every setting here is created after CreateModule returns, so all of them can still be
	-- nil while this file is executing, and the module can be switched on inside that
	-- window when the GUI restores a saved config.
	local function wantedBlock(name)
		if Custom and Custom.ListEnabled and table.find(Custom.ListEnabled, name) then return true end
		if IronOre and IronOre.Enabled and isIronOre(name) then return true end
		if LuckyBlock and LuckyBlock.Enabled and isLuckyBlock(name) then return true end
		return false
	end
	
	-- The collection is filtered as it is built, so anything that changes what counts has
	-- to rebuild it from the block store rather than just flipping a flag.
	local function rebuildList()
		if not customlist then return end
		table.clear(customlist)
		for _, obj in store.blocks do
			if wantedBlock(obj.Name) then
				table.insert(customlist, obj)
			end
		end
	end
	
	local function customRank(name)
		if Custom and Custom.ListEnabled and table.find(Custom.ListEnabled, name) then return RANK_CUSTOM end
		if isLuckyBlock(name) then return RANK_LUCKY end
		return RANK_ORE
	end
	
	-- First person puts the camera inside your own head, so the gap between the camera and
	-- the head is what separates the two views. Shiftlock still counts as third person here,
	-- which matches what you see on screen.
	local function viewAllowed()
		if not ViewMode or ViewMode.Value == 'Both' then return true end
		return bedwars.isFirstPerson() == (ViewMode.Value == 'First Person')
	end
	
	--[[
		The healthbar owns everything it draws. It used to borrow BlockBreaker's
		healthbarMaid and healthbarProgressRef, which current builds moved onto a separate
		BlockHealthbar object - so the nil check at the top returned early every single
		time and the custom bar never appeared at all.
	]]
	local healthbar = {token = 0}
	
	local function clearHealthbar()
		healthbar.token += 1
		if healthbar.mounted then
			pcall(bedwars.Roact.unmount, healthbar.mounted)
		end
		if healthbar.part then
			pcall(function()
				healthbar.part:Destroy()
			end)
		end
		healthbar.mounted, healthbar.part, healthbar.progress, healthbar.position = nil, nil, nil, nil
	end
	
	local function mountHealthbar(blockRef, health, maxHealth, block)
		local create = bedwars.Roact.createElement
		local percent = math.clamp(health / maxHealth, 0, 1)
		local meta = bedwars.ItemMeta[block.Name]
		local name = (meta and meta.displayName) or block.Name
	
		local part = Instance.new('Part')
		part.Size = Vector3.one
		part.CFrame = CFrame.new(bedwars.BlockController:getWorldPosition(blockRef.blockPosition))
		part.Transparency = 1
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.Parent = workspace
		pcall(function()
			bedwars.QueryUtil:setQueryIgnored(part, true)
		end)
	
		healthbar.part = part
		healthbar.position = blockRef.blockPosition
		healthbar.progress = bedwars.Roact.createRef()
	
		healthbar.mounted = bedwars.Roact.mount(create('BillboardGui', {
			Size = UDim2.fromOffset(249, 102),
			StudsOffset = Vector3.new(0, 2.5, 0),
			Adornee = part,
			MaxDistance = 40,
			AlwaysOnTop = true
		}, {
			create('Frame', {
				Size = UDim2.fromOffset(160, 50),
				Position = UDim2.fromOffset(44, 32),
				BackgroundColor3 = Color3.new(),
				BackgroundTransparency = 0.5
			}, {
				create('UICorner', {CornerRadius = UDim.new(0, 5)}),
				create('ImageLabel', {
					Size = UDim2.new(1, 89, 1, 52),
					Position = UDim2.fromOffset(-48, -31),
					BackgroundTransparency = 1,
					Image = getcustomasset('vain/assets/new/blur.png'),
					ScaleType = Enum.ScaleType.Slice,
					SliceCenter = Rect.new(52, 31, 261, 502)
				}),
				create('TextLabel', {
					Size = UDim2.fromOffset(145, 14),
					Position = UDim2.fromOffset(13, 12),
					BackgroundTransparency = 1,
					Text = name,
					TextXAlignment = Enum.TextXAlignment.Left,
					TextYAlignment = Enum.TextYAlignment.Top,
					TextColor3 = Color3.new(),
					TextScaled = true,
					Font = Enum.Font.Arial
				}),
				create('TextLabel', {
					Size = UDim2.fromOffset(145, 14),
					Position = UDim2.fromOffset(12, 11),
					BackgroundTransparency = 1,
					Text = name,
					TextXAlignment = Enum.TextXAlignment.Left,
					TextYAlignment = Enum.TextYAlignment.Top,
					TextColor3 = color.Dark(uipallet.Text, 0.16),
					TextScaled = true,
					Font = Enum.Font.Arial
				}),
				create('Frame', {
					Size = UDim2.fromOffset(138, 4),
					Position = UDim2.fromOffset(12, 32),
					BackgroundColor3 = uipallet.Main
				}, {
					create('UICorner', {CornerRadius = UDim.new(1, 0)}),
					create('Frame', {
						[bedwars.Roact.Ref] = healthbar.progress,
						Size = UDim2.fromScale(percent, 1),
						BackgroundColor3 = Color3.fromHSV(math.clamp(percent / 2.5, 0, 1), 0.89, 0.75)
					}, {create('UICorner', {CornerRadius = UDim.new(1, 0)})})
				})
			})
		}), part)
	end
	
	local function customHealthbar(_, blockRef, health, maxHealth, changeHealth, block)
		if block:GetAttribute('NoHealthbar') or not maxHealth or maxHealth <= 0 then return end
	
		if not healthbar.part or healthbar.position ~= blockRef.blockPosition then
			clearHealthbar()
			mountHealthbar(blockRef, health, maxHealth, block)
		end
	
		local progress = healthbar.progress and healthbar.progress:getValue()
		if not progress then return end
	
		local newpercent = math.clamp((health - changeHealth) / maxHealth, 0, 1)
		tweenService:Create(progress, TweenInfo.new(0.3), {
			Size = UDim2.fromScale(newpercent, 1), BackgroundColor3 = Color3.fromHSV(math.clamp(newpercent / 2.5, 0, 1), 0.89, 0.75)
		}):Play()
	
		-- The token makes the delayed cleanup drop itself when a newer hit has already
		-- claimed the bar, so it can never take down the bar for the block you moved on to.
		healthbar.token += 1
		local token = healthbar.token
		task.delay(5, function()
			if healthbar.token == token then
				clearHealthbar()
			end
		end)
	end
	
	local function gather(list, rank, localPosition)
		if not list then return end
		for _, v in list do
			if not v or not v.Parent then continue end
			-- A block that is a model rather than a part has no Position at all, and one
			-- bad entry used to abort the whole pass before anything got broken.
			local ok, pos = pcall(function()
				return v.Position
			end)
			if not ok or not pos then continue end
	
			local dist = (pos - localPosition).Magnitude
			if dist >= Range.Value then continue end
	
			table.insert(candidates, {
				Block = v,
				Position = pos,
				Distance = dist,
				Rank = rank or customRank(v.Name)
			})
		end
	end
	
	-- Health scores every opening of a structure, which is a store lookup each, so the
	-- answers are held for the length of one pass and dropped with the candidates.
	local hitsCache = {}
	
	--[[
		Cursor and Recently Hit are steered by hand rather than run on their own. Both name
		a single block to dig from and nothing else is allowed, so pointing at nothing that
		leads anywhere means nothing gets broken.
	
		Which block you are on comes from the game's own selector, so it agrees exactly with
		what the game thinks you are pointing at, range and obstructions included.
	]]
	local BLOCK_SELECT = 1
	local cursorTarget = nil
	local manualHit = nil
	
	local function cursorBlock()
		local ok, info = pcall(function()
			return bedwars.BlockEngine:getBlockSelector():getMouseInfo(BLOCK_SELECT)
		end)
		local ref = ok and info and info.target and info.target.blockRef
		local pos = ref and ref.blockPosition
		return pos and (pos * 3) or nil
	end
	
	local function blockHitsAt(node)
		local cached = hitsCache[node]
		if cached then return cached end
	
		local ok, hits = pcall(function()
			local block = bedwars.getPlacedBlock(node)
			return block and bedwars.getBlockHits(block, node) or nil
		end)
		hits = (ok and hits) or math.huge
		hitsCache[node] = hits
		return hits
	end
	
	--[[
		A target mode picks the block that actually gets broken, measured from your
		character - the defences in front of a bed, not the bed sitting behind them. These
		score the openings breakBlock can start at; ranking only the beds and ore left the
		choice of which wall to mine to whichever the pathfinder happened to reach first,
		so standing at one side of a build was no reason for it to break that side.
		node is a world position, cost is the hits to tunnel from there to the target, and
		reach is the distance from your character.
	]]
	local entryScorers = {
		Nearest = function(_, _, reach)
			return reach
		end,
		Farthest = function(_, _, reach)
			return -reach
		end,
		Health = function(node)
			return blockHitsAt(node)
		end,
		Shortest = function(_, cost)
			return cost
		end,
		Lowest = function(node)
			return node.Y
		end,
		Highest = function(node)
			return -node.Y
		end,
		Random = function(node)
			return randomKey(node)
		end,
		-- Both of these answer for exactly one block and refuse the rest. Nothing under the
		-- cursor, or nothing hit yet, means no way in is offered and so nothing is mined.
		Cursor = function(node)
			return (cursorTarget and node == cursorTarget) and 0 or nil
		end,
		['Recently Hit'] = function(node)
			return (manualHit and node == manualHit) and 0 or nil
		end
	}
	
	-- Cursor is re-aimed every pass, so moving off a block drops it straight away and it
	-- keeps no route at all. Every other mode, Recently Hit included, keeps the route it
	-- had: Recently Hit sees the tunnel through to the bed until you strike a different
	-- block, and the rest are untouched.
	local NO_ROUTE = {Cursor = true}
	
	-- What to go for is fixed: beds first, then whatever else is switched on, nearest of
	-- each. Which block gets broken on the way in is the target mode's job, and that is
	-- decided per opening in entryScorers rather than here.
	local function rankCandidates()
		if #candidates < 2 then return end
	
		table.sort(candidates, function(a, b)
			if a.Rank == b.Rank then return a.Distance < b.Distance end
			return a.Rank < b.Rank
		end)
	end
	
	local function attemptBreak()
		for _, entry in candidates do
			local v = entry.Block
			if not v or not v.Parent then continue end
	
			local ok, isBreakable = pcall(function()
				return bedwars.BlockController:isBlockBreakable({blockPosition = entry.Position / 3}, lplr)
			end)
			if not ok or not isBreakable then continue end
	
			if not SelfBreak.Enabled and v:GetAttribute('PlacedByUserId') == lplr.UserId then continue end
			if (v:GetAttribute('BedShieldEndTime') or 0) > workspace:GetServerTimeNow() then continue end
			if LimitItem.Enabled then
				local held = store.hand.tool and bedwars.ItemMeta[store.hand.tool.Name]
				if not (held and held.breakBlock) then continue end
			end
	
			-- pcall succeeding only means nothing threw. breakBlock returns quietly when the
			-- target is out of reach, has no route left, or is one of your own - all of which
			-- used to read as a successful hit, so the pass stopped here and the same
			-- unreachable block was picked again every time. Only a returned block counts.
			local broke = false
			-- A miss is a swing that went out and did not land, so it costs the same time as a
			-- hit would rather than being retried on the next block straight away.
			if HitChance.Enabled and math.random(100) > Chance.Value then
				task.wait(BreakSpeed.Value)
				return true
			end
	
			local ok2 = pcall(function()
				-- Self Break has to reach the dig route, not just the target: breakBlock
				-- tunnels towards a block rather than hitting it directly, so with the check
				-- on the target alone every block on the way there got broken regardless.
				local route = tunnel[v]
				if not route then
					route = {}
					tunnel[v] = route
				end
	
				breakOptions.Range = Range.Value
				breakOptions.Angle = Angle.Value
				breakOptions.Score = entryScorers[TargetMode.Value]
				-- Read on the way in and refilled on the way out, so the route carries from
				-- one hit to the next. A break that never went out leaves it untouched.
				-- Cursor keeps no route at all: you are aiming it, so the block you are on
				-- wins over anything it was part way through.
				breakOptions.Prefer = not NO_ROUTE[TargetMode.Value] and route or nil
				breakOptions.Route = route
	
				local target, _, endpos = bedwars.breakBlock(v, Effect.Enabled, Animation.Enabled, CustomHealth.Enabled and customHealthbar or nil, not SelfBreak.Enabled, AutoTool.Enabled, breakOptions)
				if not target then return end
				broke = true
	
				-- Drawn from the route being followed rather than from a freshly worked out
				-- one. Those are the same length but tie constantly, so the recomputed one
				-- drifts between equally short alternatives on every hit - it was drawing a
				-- detour while the blocks actually coming down ran perfectly straight.
				if Effect.Enabled then
					local from = table.find(route, target) or 1
					for i, part in parts do
						local pos = route[from + i - 1]
						part.Position = pos or Vector3.zero
						if pos then
							part.BoxHandleAdornment.Color3 = pos == endpos and Color3.new(1, 0.2, 0.2) or pos == target and Color3.new(0.2, 0.2, 1) or Color3.new(0.2, 1, 0.2)
						end
					end
				end
			end)
			if ok2 and broke then
				task.wait(InstantBreak.Enabled and (store.damageBlockFail > tick() and 4.5 or 0) or BreakSpeed.Value)
				return true
			end
		end
	
		return false
	end
	
	Nuker = vain.Categories.Minigames:CreateModule({
		Name = 'Nuker',
		Function = function(callback)
			if callback then
				randomSalt = math.random() * 1000
	
				for _ = 1, 30 do
					local part = Instance.new('Part')
					part.Anchored = true
					part.CanQuery = false
					part.CanCollide = false
					part.Transparency = 1
					part.Parent = gameCamera
					local highlight = Instance.new('BoxHandleAdornment')
					highlight.Size = Vector3.one
					highlight.AlwaysOnTop = true
					highlight.ZIndex = 1
					highlight.Transparency = 0.5
					highlight.Adornee = part
					highlight.Parent = part
					table.insert(parts, part)
				end
	
				-- onBreak is the game's own swing at a block. Nuker never goes through it - it
				-- calls the damage remote straight out - so its own hits cannot move the block
				-- you picked, which is the whole point of steering it by hand.
				pcall(function()
					Nuker:Clean(bedwars.BlockBreaker.onBreak:Connect(function()
						local hit = cursorBlock()
						if hit and hit ~= manualHit then
							manualHit = hit
							-- Struck somewhere new, so nothing part way through is carried over.
							table.clear(tunnel)
						end
					end))
				end)
	
				local beds = collection('bed', Nuker)
				-- Teslas carry a real tag, so they are collected rather than name matched.
				-- 'tesla' and 'tesla_trap' are ItemType values, not tags.
				local teslas = collection('tesla-trap', Nuker)
				-- Ore, lucky blocks and anything you list are ordinary blocks named by their
				-- item type, so they come out of the one 'block' collection.
				customlist = collection('block', Nuker, function(tab, obj)
					if wantedBlock(obj.Name) then
						table.insert(tab, obj)
					end
				end)
	
				repeat
					local ok = pcall(function()
						if not entitylib.isAlive then return end
	
						if not viewAllowed() then
							for _, v in parts do
								v.Position = Vector3.zero
							end
							return
						end
	
						local localPosition = entitylib.character.RootPart.Position
						cursorTarget = TargetMode.Value == 'Cursor' and cursorBlock() or nil
						table.clear(candidates)
						table.clear(hitsCache)
						gather(Bed.Enabled and beds, RANK_BED, localPosition)
						gather(customlist, nil, localPosition)
						gather(Tesla.Enabled and teslas, RANK_TESLA, localPosition)
						rankCandidates()
	
						if attemptBreak() then return end
	
						for _, v in parts do
							v.Position = Vector3.zero
						end
					end)
					if not ok then
						task.wait(0.5)
					else
						task.wait(1 / UpdateRate.Value)
					end
				until not Nuker.Enabled
			else
				cursorTarget, manualHit = nil, nil
				clearHealthbar()
				table.clear(candidates)
				table.clear(hitsCache)
				table.clear(tunnel)
				for _, v in parts do
					v:ClearAllChildren()
					v:Destroy()
				end
				table.clear(parts)
			end
		end,
		Tooltip = 'Breaks blocks around you automatically'
	})
	TargetMode = Nuker:CreateDropdown({
		Name = 'Target Mode',
		Tooltip = 'Where the way in starts, measured from you',
		Function = function()
			table.clear(tunnel)
		end,
		List = {'Smart', 'Nearest', 'Cursor', 'Recently Hit', 'Farthest', 'Health', 'Shortest', 'Lowest', 'Highest', 'Random'},
		Tooltips = {
			Smart = 'Nearest side in, unless it is much thicker',
			Nearest = 'Closest block to you',
			Cursor = 'Only what is under your cursor',
			['Recently Hit'] = 'Digs on from the last block you hit',
			Farthest = 'Furthest block still in range',
			Health = 'Weakest block, your tool counted',
			Shortest = 'Fewest blocks through to the bed',
			Lowest = 'Lowest block first, cuts supports',
			Highest = 'Highest block first',
			Random = 'No fixed order'
		}
	})
	ViewMode = Nuker:CreateDropdown({
		Name = 'View Mode',
		Tooltip = 'Which camera view this breaks in',
		List = {'Both', 'First Person', 'Third Person'},
		Tooltips = {
			Both = 'Breaks in either view',
			['First Person'] = 'Only while the camera is in your head',
			['Third Person'] = 'Only while the camera is behind you'
		}
	})
	Range = Nuker:CreateSlider({
		Name = 'Break Range',
		Tooltip = 'How far you can break blocks from\nGame default is 18',
		Min = 1,
		Max = 30,
		Default = 30,
		Suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})
	BreakSpeed = Nuker:CreateSlider({
		Name = 'Break Speed',
		Tooltip = 'Delay between blocks, lower is faster\nGame default is 0.3',
		Min = 0,
		Max = 0.3,
		Default = 0.25,
		Decimal = 100,
		Suffix = 'seconds'
	})
	Angle = Nuker:CreateSlider({
		Name = 'Angle',
		Tooltip = 'How wide a cone in front of you blocks break in\n360 breaks behind you too',
		Min = 1,
		Max = 360,
		Default = 90,
		Suffix = 'degrees'
	})
	UpdateRate = Nuker:CreateSlider({
		Name = 'Update Rate',
		Tooltip = 'How often blocks are re-checked\nLower costs less performance',
		Min = 1,
		Max = 120,
		Default = 60,
		Suffix = 'hz'
	})
	Custom = Nuker:CreateTextList({
		Name = 'Custom',
		Tooltip = 'Extra block names to break',
		Function = rebuildList
	})
	Bed = Nuker:CreateToggle({
		Name = 'Break Bed',
		Tooltip = 'Breaks beds',
		Default = true
	})
	LuckyBlock = Nuker:CreateToggle({
		Name = 'Break Lucky Block',
		Tooltip = 'Breaks every lucky block type',
		Default = true,
		Function = rebuildList
	})
	IronOre = Nuker:CreateToggle({
		Name = 'Break Iron Ore',
		Tooltip = 'Breaks iron ore',
		Default = true,
		Function = rebuildList
	})
	Tesla = Nuker:CreateToggle({
		Name = 'Break Tesla',
		Tooltip = 'Breaks tesla traps',
		Default = true
	})
	Effect = Nuker:CreateToggle({
		Name = 'Show Healthbar & Effects',
		Tooltip = 'Shows break progress and particles',
		Function = function(callback)
			if CustomHealth.Object then
				CustomHealth.Object.Visible = callback
			end
			if not callback then
				clearHealthbar()
			end
		end,
		Default = true
	})
	CustomHealth = Nuker:CreateToggle({
		Name = 'Custom Healthbar',
		Tooltip = 'Uses the Vain healthbar instead of the game one',
		Function = function()
			clearHealthbar()
		end,
		Default = true,
		Darker = true
	})
	Animation = Nuker:CreateToggle({Name = 'Animation', Tooltip = 'Plays the break animation'})
	SelfBreak = Nuker:CreateToggle({Name = 'Self Break', Tooltip = 'Also breaks blocks you placed yourself'})
	InstantBreak = Nuker:CreateToggle({Name = 'Instant Break', Tooltip = 'Breaks blocks in a single hit'})
	HitChance = Nuker:CreateToggle({
		Name = 'Hit Chance',
		Tooltip = 'Misses some swings on purpose',
		Function = function(callback)
			if Chance.Object then
				Chance.Object.Visible = callback
			end
		end
	})
	Chance = Nuker:CreateSlider({
		Name = 'Chance',
		Tooltip = 'Percent of swings that land',
		Min = 1,
		Max = 100,
		Default = 90,
		Suffix = '%',
		Visible = false,
		Darker = true
	})
	AutoTool = Nuker:CreateToggle({
		Name = 'Auto Tool',
		Tooltip = 'Swaps to the best tool for each block',
		Default = true
	})
	LimitItem = Nuker:CreateToggle({
		Name = 'Limit to Items',
		Tooltip = 'Only breaks when tools are held'
	})
	
end)

run(function()
	local BedBreakEffect
	local Mode
	local List
	local NameToId = {}
	
	BedBreakEffect = vain.Legit:CreateModule({
		Name = 'Bed Break Effect',
		Function = function(callback)
			if callback then
	            BedBreakEffect:Clean(vainEvents.BedwarsBedBreak.Event:Connect(function(data)
	                firesignal(bedwars.Client:Get('BedBreakEffectTriggered').instance.OnClientEvent, {
	                    player = data.player,
	                    position = data.bedBlockPosition * 3,
	                    effectType = NameToId[List.Value],
	                    teamId = data.brokenBedTeam.id,
	                    centerBedPosition = data.bedBlockPosition * 3
	                })
	            end))
	        end
		end,
		Tooltip = 'Custom bed break effects'
	})
	local BreakEffectName = {}
	for i, v in bedwars.BedBreakEffectMeta do
		table.insert(BreakEffectName, v.name)
		NameToId[v.name] = i
	end
	table.sort(BreakEffectName)
	List = BedBreakEffect:CreateDropdown({
		Name = 'Effect',
		Tooltip = 'Which effect to play',
		List = BreakEffectName
	})
end)

run(function()
	vain.Legit:CreateModule({
		Name = 'Clean Kit',
		Function = function(callback)
			if callback then
				bedwars.WindWalkerController.spawnOrb = function() end
				local zephyreffect = lplr.PlayerGui:FindFirstChild('WindWalkerEffect', true)
				if zephyreffect then 
					zephyreffect.Visible = false 
				end
			end
		end,
		Tooltip = 'Removes zephyr status indicator'
	})
end)

run(function()
	local FOV
	local Value
	local old, old2
	
	FOV = vain.Legit:CreateModule({
		Name = 'FOV',
		Function = function(callback)
			if callback then
				old = bedwars.FovController.setFOV
				old2 = bedwars.FovController.getFOV
				bedwars.FovController.setFOV = function(self) 
					return old(self, Value.Value) 
				end
				bedwars.FovController.getFOV = function() 
					return Value.Value 
				end
			else
				bedwars.FovController.setFOV = old
				bedwars.FovController.getFOV = old2
			end
			
			bedwars.FovController:setFOV(bedwars.Store:getState().Settings.fov)
		end,
		Tooltip = 'Adjusts camera vision'
	})
	Value = FOV:CreateSlider({
		Name = 'FOV',
		Tooltip = 'Field of view, in degrees',
		Min = 30,
		Max = 120
	})
end)

run(function()
	local FPSBoost
	local Kill
	local Visualizer
	local effects, util = {}, {}
	
	FPSBoost = vain.Legit:CreateModule({
		Name = 'FPS Boost',
		Function = function(callback)
			if callback then
				if Kill.Enabled then
					for i, v in bedwars.KillEffectController.killEffects do
						if not i:find('Custom') then
							effects[i] = v
							bedwars.KillEffectController.killEffects[i] = {
								new = function() 
									return {
										onKill = function() end, 
										isPlayDefaultKillEffect = function() 
											return true 
										end
									} 
								end
							}
						end
					end
				end
	
				if Visualizer.Enabled then
					for i, v in bedwars.VisualizerUtils do
						util[i] = v
						bedwars.VisualizerUtils[i] = function() end
					end
				end
	
				repeat task.wait() until store.matchState ~= 0
				if not bedwars.AppController then return end
				bedwars.NametagController.addGameNametag = function() end
				for _, v in bedwars.AppController:getOpenApps() do
					if tostring(v):find('Nametag') then
						bedwars.AppController:closeApp(tostring(v))
					end
				end
			else
				for i, v in effects do 
					bedwars.KillEffectController.killEffects[i] = v 
				end
				for i, v in util do 
					bedwars.VisualizerUtils[i] = v 
				end
				table.clear(effects)
				table.clear(util)
			end
		end,
		Tooltip = 'Improves the framerate by turning off certain effects'
	})
	Kill = FPSBoost:CreateToggle({
		Name = 'Kill Effects',
		Tooltip = 'Plays your equipped kill effect',
		Function = function()
			if FPSBoost.Enabled then
				FPSBoost:Toggle()
				FPSBoost:Toggle()
			end
		end,
		Default = true
	})
	Visualizer = FPSBoost:CreateToggle({
		Name = 'Visualizer',
		Tooltip = 'Shows a visualizer for the audio',
		Function = function()
			if FPSBoost.Enabled then
				FPSBoost:Toggle()
				FPSBoost:Toggle()
			end
		end,
		Default = true
	})
end)

run(function()
	local HitColor
	local Color
	local done = {}
	
	HitColor = vain.Legit:CreateModule({
		Name = 'Hit Color',
		Function = function(callback)
			if callback then 
				repeat
					for i, v in entitylib.List do 
						local highlight = v.Character and v.Character:FindFirstChild('_DamageHighlight_')
						if highlight then 
							if not table.find(done, highlight) then 
								table.insert(done, highlight) 
							end
							highlight.FillColor = Color3.fromHSV(Color.Hue, Color.Sat, Color.Value)
							highlight.FillTransparency = Color.Opacity
						end
					end
					task.wait(0.1)
				until not HitColor.Enabled
			else
				for i, v in done do 
					v.FillColor = Color3.new(1, 0, 0)
					v.FillTransparency = 0.4
				end
				table.clear(done)
			end
		end,
		Tooltip = 'Customize the hit highlight options'
	})
	Color = HitColor:CreateColorSlider({
		Name = 'Color',
		Tooltip = 'Color used for this feature',
		DefaultOpacity = 0.4
	})
end)

run(function()
	vain.Legit:CreateModule({
		Name = 'HitFix',
		Function = function(callback)
			-- Lowercasing the method name makes the engine-side lookup miss, which is the
			-- whole trick here. Found by value so it survives the game shifting constants.
			swapConstant(bedwars.SwordController.swingSwordAtMouse, callback and 'Raycast' or 'raycast', callback and 'raycast' or 'Raycast')
			debug.setupvalue(bedwars.SwordController.swingSwordAtMouse, 4, callback and bedwars.QueryUtil or workspace)
		end,
		Tooltip = 'Changes the raycast function to the correct one'
	})
end)

run(function()
	local KillEffect
	local Mode
	local List
	local NameToId = {}
	
	local killeffects = {
		Gravity = function(_, _, char, _)
			char:BreakJoints()
			local highlight = char:FindFirstChildWhichIsA('Highlight')
			local nametag = char:FindFirstChild('Nametag', true)
			if highlight then
				highlight:Destroy()
			end
			if nametag then
				nametag:Destroy()
			end
	
			task.spawn(function()
				local partvelo = {}
				for _, v in char:GetDescendants() do
					if v:IsA('BasePart') then
						partvelo[v.Name] = v.Velocity
					end
				end
				char.Archivable = true
				local clone = char:Clone()
				clone.Humanoid.Health = 100
				clone.Parent = workspace
				game:GetService('Debris'):AddItem(clone, 30)
				char:Destroy()
				task.wait(0.01)
				clone.Humanoid:ChangeState(Enum.HumanoidStateType.Dead)
				clone:BreakJoints()
				task.wait(0.01)
				for _, v in clone:GetDescendants() do
					if v:IsA('BasePart') then
						local bodyforce = Instance.new('BodyForce')
						bodyforce.Force = Vector3.new(0, (workspace.Gravity - 10) * v:GetMass(), 0)
						bodyforce.Parent = v
						v.CanCollide = true
						v.Velocity = partvelo[v.Name] or Vector3.zero
					end
				end
			end)
		end,
		Lightning = function(_, _, char, _)
			char:BreakJoints()
			local highlight = char:FindFirstChildWhichIsA('Highlight')
			if highlight then
				highlight:Destroy()
			end
			local startpos = 1125
			local startcf = char.PrimaryPart.CFrame.p - Vector3.new(0, 8, 0)
			local newpos = Vector3.new((math.random(1, 10) - 5) * 2, startpos, (math.random(1, 10) - 5) * 2)
	
			for i = startpos - 75, 0, -75 do
				local newpos2 = Vector3.new((math.random(1, 10) - 5) * 2, i, (math.random(1, 10) - 5) * 2)
				if i == 0 then
					newpos2 = Vector3.zero
				end
				local part = Instance.new('Part')
				part.Size = Vector3.new(1.5, 1.5, 77)
				part.Material = Enum.Material.SmoothPlastic
				part.Anchored = true
				part.Material = Enum.Material.Neon
				part.CanCollide = false
				part.CFrame = CFrame.new(startcf + newpos + ((newpos2 - newpos) * 0.5), startcf + newpos2)
				part.Parent = workspace
				local part2 = part:Clone()
				part2.Size = Vector3.new(3, 3, 78)
				part2.Color = Color3.new(0.7, 0.7, 0.7)
				part2.Transparency = 0.7
				part2.Material = Enum.Material.SmoothPlastic
				part2.Parent = workspace
				game:GetService('Debris'):AddItem(part, 0.5)
				game:GetService('Debris'):AddItem(part2, 0.5)
				bedwars.QueryUtil:setQueryIgnored(part, true)
				bedwars.QueryUtil:setQueryIgnored(part2, true)
				if i == 0 then
					local soundpart = Instance.new('Part')
					soundpart.Transparency = 1
					soundpart.Anchored = true
					soundpart.Size = Vector3.zero
					soundpart.Position = startcf
					soundpart.Parent = workspace
					bedwars.QueryUtil:setQueryIgnored(soundpart, true)
					local sound = Instance.new('Sound')
					sound.SoundId = 'rbxassetid://6993372814'
					sound.Volume = 2
					sound.Pitch = 0.5 + (math.random(1, 3) / 10)
					sound.Parent = soundpart
					sound:Play()
					sound.Ended:Connect(function()
						soundpart:Destroy()
					end)
				end
				newpos = newpos2
			end
		end,
		Delete = function(_, _, char, _)
			char:Destroy()
		end
	}
	
	KillEffect = vain.Legit:CreateModule({
		Name = 'Kill Effect',
		Function = function(callback)
			if callback then
				for i, v in killeffects do
					bedwars.KillEffectController.killEffects['Custom'..i] = {
						new = function()
							return {
								onKill = v,
								isPlayDefaultKillEffect = function()
									return false
								end
							}
						end
					}
				end
				KillEffect:Clean(lplr:GetAttributeChangedSignal('KillEffectType'):Connect(function()
					lplr:SetAttribute('KillEffectType', Mode.Value == 'Bedwars' and NameToId[List.Value] or 'Custom'..Mode.Value)
				end))
				lplr:SetAttribute('KillEffectType', Mode.Value == 'Bedwars' and NameToId[List.Value] or 'Custom'..Mode.Value)
			else
				for i in killeffects do
					bedwars.KillEffectController.killEffects['Custom'..i] = nil
				end
				lplr:SetAttribute('KillEffectType', 'default')
			end
		end,
		Tooltip = 'Custom final kill effects'
	})
	local modes = {'Bedwars'}
	for i in killeffects do
		table.insert(modes, i)
	end
	Mode = KillEffect:CreateDropdown({
		Name = 'Mode',
		Tooltip = 'Which method this module uses',
		List = modes,
		Function = function(val)
			List.Object.Visible = val == 'Bedwars'
			if KillEffect.Enabled then
				lplr:SetAttribute('KillEffectType', val == 'Bedwars' and NameToId[List.Value] or 'Custom'..val)
			end
		end
	})
	local KillEffectName = {}
	for i, v in bedwars.KillEffectMeta do
		table.insert(KillEffectName, v.name)
		NameToId[v.name] = i
	end
	table.sort(KillEffectName)
	List = KillEffect:CreateDropdown({
		Name = 'Bedwars',
		Tooltip = 'Which bedwars queue this applies to',
		List = KillEffectName,
		Function = function(val)
			if KillEffect.Enabled then
				lplr:SetAttribute('KillEffectType', NameToId[val])
			end
		end,
		Darker = true
	})
end)

run(function()
	local ReachDisplay
	local label
	
	ReachDisplay = vain.Legit:CreateModule({
		Name = 'Reach Display',
		Tooltip = 'Shows your current reach on screen',
		Function = function(callback)
			if callback then
				repeat
					label.Text = (store.attackReachUpdate > tick() and store.attackReach or '0.00')..' studs'
					task.wait(0.4)
				until not ReachDisplay.Enabled
			end
		end,
		Size = UDim2.fromOffset(100, 41)
	})
	ReachDisplay:CreateFont({
		Name = 'Font',
		Tooltip = 'Font used for the text',
		Blacklist = 'Gotham',
		Function = function(val)
			label.FontFace = val
		end
	})
	ReachDisplay:CreateColorSlider({
		Name = 'Color',
		Tooltip = 'Color used for this feature',
		DefaultValue = 0,
		DefaultOpacity = 0.5,
		Function = function(hue, sat, val, opacity)
			label.BackgroundColor3 = Color3.fromHSV(hue, sat, val)
			label.BackgroundTransparency = 1 - opacity
		end
	})
	label = Instance.new('TextLabel')
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 0.5
	label.TextSize = 15
	label.Font = Enum.Font.Gotham
	label.Text = '0.00 studs'
	label.TextColor3 = Color3.new(1, 1, 1)
	label.BackgroundColor3 = Color3.new()
	label.Parent = ReachDisplay.Children
	local corner = Instance.new('UICorner')
	corner.CornerRadius = UDim.new(0, 4)
	corner.Parent = label
end)

run(function()
	local SongBeats
	local List
	local FOV
	local FOVValue = {}
	local Volume
	local alreadypicked = {}
	local beattick = tick()
	local oldfov, songobj, songbpm, songtween
	
	local function choosesong()
		local list = List.ListEnabled
		if #alreadypicked >= #list then 
			table.clear(alreadypicked) 
		end
	
		if #list <= 0 then
			notif('SongBeats', 'no songs', 10)
			SongBeats:Toggle()
			return
		end
	
		local chosensong = list[math.random(1, #list)]
		if #list > 1 and table.find(alreadypicked, chosensong) then
			repeat 
				task.wait() 
				chosensong = list[math.random(1, #list)] 
			until not table.find(alreadypicked, chosensong) or not SongBeats.Enabled
		end
		if not SongBeats.Enabled then return end
	
		local split = chosensong:split('/')
		if not isfile(split[1]) then
			notif('SongBeats', 'Missing song ('..split[1]..')', 10)
			SongBeats:Toggle()
			return
		end
	
		songobj.SoundId = assetfunction(split[1])
		repeat task.wait() until songobj.IsLoaded or not SongBeats.Enabled
		if SongBeats.Enabled then
			beattick = tick() + (tonumber(split[3]) or 0)
			songbpm = 60 / (tonumber(split[2]) or 50)
			songobj:Play()
		end
	end
	
	SongBeats = vain.Legit:CreateModule({
		Name = 'Song Beats',
		Function = function(callback)
			if callback then
				songobj = Instance.new('Sound')
				songobj.Volume = Volume.Value / 100
				songobj.Parent = workspace
				repeat
					if not songobj.Playing then choosesong() end
					if beattick < tick() and SongBeats.Enabled and FOV.Enabled then
						beattick = tick() + songbpm
						oldfov = math.min(bedwars.FovController:getFOV() * (bedwars.SprintController.sprinting and 1.1 or 1), 120)
						gameCamera.FieldOfView = oldfov - FOVValue.Value
						songtween = tweenService:Create(gameCamera, TweenInfo.new(math.min(songbpm, 0.2), Enum.EasingStyle.Linear), {FieldOfView = oldfov})
						songtween:Play()
					end
					task.wait()
				until not SongBeats.Enabled
			else
				if songobj then
					songobj:Destroy()
				end
				if songtween then
					songtween:Cancel()
				end
				if oldfov then
					gameCamera.FieldOfView = oldfov
				end
				table.clear(alreadypicked)
			end
		end,
		Tooltip = 'Built in mp3 player'
	})
	List = SongBeats:CreateTextList({
		Name = 'Songs',
		Tooltip = 'Songs to play',
		Placeholder = 'filepath/bpm/start'
	})
	FOV = SongBeats:CreateToggle({
		Name = 'Beat FOV',
		Tooltip = 'Pulses your field of view in time with the beat',
		Function = function(callback)
			if FOVValue.Object then
				FOVValue.Object.Visible = callback
			end
			if SongBeats.Enabled then
				SongBeats:Toggle()
				SongBeats:Toggle()
			end
		end,
		Default = true
	})
	FOVValue = SongBeats:CreateSlider({
		Name = 'Adjustment',
		Tooltip = 'Fine tunes the timing offset',
		Min = 1,
		Max = 30,
		Default = 5,
		Darker = true
	})
	Volume = SongBeats:CreateSlider({
		Name = 'Volume',
		Tooltip = 'Playback volume',
		Function = function(val)
			if songobj then 
				songobj.Volume = val / 100 
			end
		end,
		Min = 1,
		Max = 100,
		Default = 100,
		Suffix = '%'
	})
end)

run(function()
	local SoundChanger
	local List
	local soundlist = {}
	local old
	
	SoundChanger = vain.Legit:CreateModule({
		Name = 'SoundChanger',
		Function = function(callback)
			if callback then
				-- Hooks AudioManager rather than SoundManager. SoundManager no longer exists
				-- in the game, so reading .playSound off it threw the moment this was
				-- switched on - and even shimmed it would only have caught sounds this
				-- script plays, never the game's own, which is the entire point here.
				if not bedwars.AudioManager then return end
				old = bedwars.AudioManager.playAudio
				bedwars.AudioManager.playAudio = function(self, id, ...)
					if soundlist[id] then
						id = soundlist[id]
					end
	
					return old(self, id, ...)
				end
			elseif old then
				bedwars.AudioManager.playAudio = old
				old = nil
			end
		end,
		Tooltip = 'Change ingame sounds to custom ones.'
	})
	List = SoundChanger:CreateTextList({
		Name = 'Sounds',
		Tooltip = 'Sounds to use',
		Placeholder = '(DAMAGE_1/ben.mp3)',
		Function = function()
			table.clear(soundlist)
			for _, entry in List.ListEnabled do
				local split = entry:split('/')
				local id = bedwars.SoundList[split[1]]
				if id and #split > 1 then
					soundlist[id] = split[2]:find('rbxasset') and split[2] or isfile(split[2]) and assetfunction(split[2]) or ''
				end
			end
		end
	})
end)

run(function()
	local Viewmodel
	local Depth
	local Horizontal
	local Vertical
	local NoBob
	local Rots = {}
	local old, oldc1
	
	Viewmodel = vain.Legit:CreateModule({
		Name = 'Viewmodel',
		Function = function(callback)
			local viewmodel = gameCamera:FindFirstChild('Viewmodel')
			if callback then
				old = bedwars.ViewmodelController.playAnimation
				oldc1 = viewmodel and viewmodel.RightHand.RightWrist.C1 or CFrame.identity
				if NoBob.Enabled then
					bedwars.ViewmodelController.playAnimation = function(self, animtype, ...)
						if bedwars.AnimationType and animtype == bedwars.AnimationType.FP_WALK then return end
						return old(self, animtype, ...)
					end
				end
	
				bedwars.InventoryViewmodelController:handleStore(bedwars.Store:getState())
				if viewmodel then
					gameCamera.Viewmodel.RightHand.RightWrist.C1 = oldc1 * CFrame.Angles(math.rad(Rots[1].Value), math.rad(Rots[2].Value), math.rad(Rots[3].Value))
				end
				lplr.PlayerScripts.TS.controllers.global.viewmodel['viewmodel-controller']:SetAttribute('ConstantManager_DEPTH_OFFSET', -Depth.Value)
				lplr.PlayerScripts.TS.controllers.global.viewmodel['viewmodel-controller']:SetAttribute('ConstantManager_HORIZONTAL_OFFSET', Horizontal.Value)
				lplr.PlayerScripts.TS.controllers.global.viewmodel['viewmodel-controller']:SetAttribute('ConstantManager_VERTICAL_OFFSET', Vertical.Value)
			else
				bedwars.ViewmodelController.playAnimation = old
				if viewmodel then
					viewmodel.RightHand.RightWrist.C1 = oldc1
				end
	
				bedwars.InventoryViewmodelController:handleStore(bedwars.Store:getState())
				lplr.PlayerScripts.TS.controllers.global.viewmodel['viewmodel-controller']:SetAttribute('ConstantManager_DEPTH_OFFSET', 0)
				lplr.PlayerScripts.TS.controllers.global.viewmodel['viewmodel-controller']:SetAttribute('ConstantManager_HORIZONTAL_OFFSET', 0)
				lplr.PlayerScripts.TS.controllers.global.viewmodel['viewmodel-controller']:SetAttribute('ConstantManager_VERTICAL_OFFSET', 0)
				old = nil
			end
		end,
		Tooltip = 'Changes the viewmodel animations'
	})
	Depth = Viewmodel:CreateSlider({
		Name = 'Depth',
		Tooltip = 'How deep the viewmodel sits on screen',
		Min = 0,
		Max = 2,
		Default = 0.8,
		Decimal = 10,
		Function = function(val)
			if Viewmodel.Enabled then
				lplr.PlayerScripts.TS.controllers.global.viewmodel['viewmodel-controller']:SetAttribute('ConstantManager_DEPTH_OFFSET', -val)
			end
		end
	})
	Horizontal = Viewmodel:CreateSlider({
		Name = 'Horizontal',
		Tooltip = 'Horizontal offset',
		Min = 0,
		Max = 2,
		Default = 0.8,
		Decimal = 10,
		Function = function(val)
			if Viewmodel.Enabled then
				lplr.PlayerScripts.TS.controllers.global.viewmodel['viewmodel-controller']:SetAttribute('ConstantManager_HORIZONTAL_OFFSET', val)
			end
		end
	})
	Vertical = Viewmodel:CreateSlider({
		Name = 'Vertical',
		Tooltip = 'Vertical offset',
		Min = -0.2,
		Max = 2,
		Default = -0.2,
		Decimal = 10,
		Function = function(val)
			if Viewmodel.Enabled then
				lplr.PlayerScripts.TS.controllers.global.viewmodel['viewmodel-controller']:SetAttribute('ConstantManager_VERTICAL_OFFSET', val)
			end
		end
	})
	for _, name in {'Rotation X', 'Rotation Y', 'Rotation Z'} do
		table.insert(Rots, Viewmodel:CreateSlider({
			Name = name,
			Min = 0,
			Max = 360,
			Function = function(val)
				if Viewmodel.Enabled then
					gameCamera.Viewmodel.RightHand.RightWrist.C1 = oldc1 * CFrame.Angles(math.rad(Rots[1].Value), math.rad(Rots[2].Value), math.rad(Rots[3].Value))
				end
			end
		}))
	end
	NoBob = Viewmodel:CreateToggle({
		Name = 'No Bobbing',
		Tooltip = 'Stops the viewmodel from bobbing as you move',
		Default = true,
		Function = function()
			if Viewmodel.Enabled then
				Viewmodel:Toggle()
				Viewmodel:Toggle()
			end
		end
	})
end)

run(function()
	local WinEffect
	local List
	local NameToId = {}
	
	WinEffect = vain.Legit:CreateModule({
		Name = 'WinEffect',
		Function = function(callback)
			if callback then
				WinEffect:Clean(vainEvents.MatchEndEvent.Event:Connect(function()
					for i, v in getconnections(bedwars.Client:Get('WinEffectTriggered').instance.OnClientEvent) do
						if v.Function then
							v.Function({
								winEffectType = NameToId[List.Value],
								winningPlayer = lplr
							})
						end
					end
				end))
			end
		end,
		Tooltip = 'Allows you to select any clientside win effect'
	})
	local WinEffectName = {}
	for i, v in bedwars.WinEffectMeta do
		table.insert(WinEffectName, v.name)
		NameToId[v.name] = i
	end
	table.sort(WinEffectName)
	List = WinEffect:CreateDropdown({
		Name = 'Effects',
		Tooltip = 'Which effect set to use',
		List = WinEffectName
	})
end)