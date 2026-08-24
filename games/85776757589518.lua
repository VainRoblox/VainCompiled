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

	return model:FindFirstChild('HumanoidRootPart') ~= nil
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
	local Distance
	local Height
	local Method
	local ReturnHome
	local homeCF
	
	-- Attacks the way universal Killaura does, because it is the one approach that needs no
	-- knowledge of the game's own combat code: activate whatever is held, and fire the touch
	-- interests on the target so a touch-driven hitbox registers. If Dungeon Quest turns out
	-- to deal damage through a remote instead, this is the half that will need replacing -
	-- the finding, approaching and cycling around it all still hold.
	local function attack(entity)
		local character = lplr.Character
		if not character then return end
	
		local tool = character:FindFirstChildOfClass('Tool')
		if tool then
			pcall(function()
				tool:Activate()
			end)
		end
	
		if not firetouchinterest then return end
	
		local handle = tool and tool:FindFirstChild('Handle')
		if not handle then return end
	
		for _, part in entity.Character:GetDescendants() do
			if part:IsA('BasePart') then
				pcall(firetouchinterest, handle, part, 0)
				pcall(firetouchinterest, handle, part, 1)
			end
		end
	end
	
	local function nearestEnemy()
		return entitylib.EntityPosition({
			Part = 'RootPart',
			Range = math.huge,
			Players = false,
			NPCs = true
			-- No Sort: the default already orders by distance, and this field expects a
			-- comparator function rather than a name.
		})
	end
	
	AutoFarm = vain.Categories.Blatant:CreateModule({
		Name = 'AutoFarm',
		Function = function(callback)
			if callback then
				homeCF = entitylib.isAlive and entitylib.character.RootPart.CFrame or nil
	
				task.spawn(function()
					repeat
						-- Wrapped, and yielding outside the guard, so a bad pass cannot spin
						-- and one error does not end the farm for the session.
						local ok = pcall(function()
							if not entitylib.isAlive then return end
	
							local entity = nearestEnemy()
							if not entity or not entity.RootPart then
								-- Nothing left in the room. Optionally sit still rather than
								-- hovering wherever the last kill happened.
								if ReturnHome.Enabled and homeCF then
									entitylib.character.RootPart.CFrame = homeCF
								end
								return
							end
	
							local root = entitylib.character.RootPart
							-- Held above and behind rather than inside the target: standing
							-- in the same space tends to push you around, and above keeps
							-- melee swings reaching down onto it.
							local goal = entity.RootPart.CFrame * CFrame.new(0, Height.Value, Distance.Value)
	
							if Method.Value == 'Teleport' then
								root.CFrame = goal
							else
								-- Walk instead, for anything that objects to being moved in
								-- one step. Slower, and it will not cross gaps.
								local direction = (goal.Position - root.Position)
								if direction.Magnitude > 1 then
									entitylib.character.Humanoid:MoveTo(goal.Position)
								end
							end
	
							root.AssemblyLinearVelocity = Vector3.zero
							targetinfo.Targets[entity] = tick() + 1
							attack(entity)
						end)
	
						task.wait(ok and 0.1 or 0.4)
					until not AutoFarm.Enabled
	
					if ReturnHome.Enabled and homeCF and entitylib.isAlive then
						pcall(function()
							entitylib.character.RootPart.CFrame = homeCF
						end)
					end
				end)
			end
		end,
		Tooltip = 'Finds the nearest enemy, moves to it and attacks until the room is clear'
	})
	Method = AutoFarm:CreateDropdown({
		Name = 'Method',
		Tooltip = 'How to get to the enemy',
		List = {'Teleport', 'Walk'},
		Tooltips = {
			Teleport = 'Moves you straight there - fast, and the more obvious of the two',
			Walk = 'Walks there instead, which will not cross gaps'
		}
	})
	Distance = AutoFarm:CreateSlider({
		Name = 'Distance',
		Tooltip = 'How far to sit from the enemy',
		Min = 1,
		Max = 20,
		Default = 6,
		Suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})
	Height = AutoFarm:CreateSlider({
		Name = 'Height',
		Tooltip = 'How far above the enemy to sit\nKeeps you out of its way while staying in melee reach',
		Min = 0,
		Max = 30,
		Default = 8,
		Suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})
	ReturnHome = AutoFarm:CreateToggle({
		Name = 'Return on clear',
		Tooltip = 'Goes back to where you switched this on once nothing is left',
		Default = true
	})
	
end)