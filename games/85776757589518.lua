local run = function(func) func() end
local cloneref = cloneref or function(obj) return obj end

local playersService = cloneref(game:GetService('Players'))
local inputService = cloneref(game:GetService('UserInputService'))
local runService = cloneref(game:GetService('RunService'))
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

vain.Libraries.dungeonquest = {
	isEnemy = isEnemy,
	tracked = tracked
}


run(function()
	local AutoFarm
	local warned = false
	
	-- Held above the enemy rather than beside it: standing in the same space shoves you
	-- around as it walks, and above keeps swings reaching down onto it.
	local OFFSET = Vector3.new(0, 8, 0)
	
	-- Attacks the way universal Killaura does, because it is the one approach that needs no
	-- knowledge of the game's own combat code: activate whatever is held, and fire the touch
	-- interests on the target so a touch driven hitbox registers.
	local function attack(entity)
		local character = lplr.Character
		if not character then return end
	
		local tool = character:FindFirstChildOfClass('Tool')
		if not tool then return end
	
		pcall(function()
			tool:Activate()
		end)
	
		if not firetouchinterest then return end
		local handle = tool:FindFirstChild('Handle')
		if not handle then return end
	
		for _, part in entity.Character:GetDescendants() do
			if part:IsA('BasePart') then
				pcall(firetouchinterest, handle, part, 0)
				pcall(firetouchinterest, handle, part, 1)
			end
		end
	end
	
	AutoFarm = vain.Categories.Blatant:CreateModule({
		Name = 'AutoFarm',
		Function = function(callback)
			if callback then
				warned = false
	
				task.spawn(function()
					repeat
						-- Guarded, yielding outside, so one bad pass cannot spin or end the
						-- farm for the session.
						local ok = pcall(function()
							if not entitylib.isAlive then return end
	
							local entity = entitylib.EntityPosition({
								Part = 'RootPart',
								Range = math.huge,
								Players = false,
								NPCs = true
							})
	
							-- Nothing to do. Deliberately does nothing at all rather than
							-- moving you anywhere: an earlier version returned you to where
							-- you switched it on, which meant that whenever no enemy was
							-- found it teleported you back every tenth of a second and you
							-- could not move at all. Being idle has to look like being idle.
							if not (entity and entity.RootPart) then
								if not warned then
									warned = true
									notif('AutoFarm', 'No enemies found. If there are some in front of you, they are not being detected - send me what the enemy models look like.', 12, 'alert')
								end
								return
							end
	
							warned = false
	
							local root = entitylib.character.RootPart
							root.CFrame = CFrame.new(entity.RootPart.Position + OFFSET)
							root.AssemblyLinearVelocity = Vector3.zero
	
							targetinfo.Targets[entity] = tick() + 1
							attack(entity)
						end)
	
						task.wait(ok and 0.1 or 0.4)
					until not AutoFarm.Enabled
				end)
			end
		end,
		Tooltip = 'Flies to the nearest enemy and attacks it until the room is clear'
	})
	
end)