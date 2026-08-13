repeat task.wait() until game:IsLoaded()
if shared.vain then shared.vain:Uninject() end

local vain
local loadstring = function(...)
	local res, err = loadstring(...)
	if err and vain then
		vain:CreateNotification('Vain', 'Failed to load : '..err, 30, 'alert')
	end
	return res
end
local queue_on_teleport = queue_on_teleport or function() end
local isfile = isfile or function(file)
	local suc, res = pcall(function()
		return readfile(file)
	end)
	return suc and res ~= nil and res ~= ''
end
local cloneref = cloneref or function(obj)
	return obj
end
local playersService = cloneref(game:GetService('Players'))

local function downloadFile(path, func)
	if not isfile(path) then
		local suc, res = pcall(function()
			return game:HttpGet('https://raw.githubusercontent.com/VainRoblox/VainCompiled/'..readfile('vain/profiles/commit.txt')..'/'..select(1, path:gsub('vain/', '')), true)
		end)
		if not suc or res == '404: Not Found' then
			error(res)
		end
		if path:find('.lua') then
			res = '--This watermark is used to delete the file if its cached, remove it to make the file persist after vain updates.\n'..res
		end
		writefile(path, res)
	end
	return (func or readfile)(path)
end

local function finishLoading()
	vain.Init = nil
	vain:Load()
	task.spawn(function()
		repeat
			vain:Save()
			task.wait(10)
		until not vain.Loaded
	end)

	local teleportedServers
	vain:Clean(playersService.LocalPlayer.OnTeleport:Connect(function()
		if (not teleportedServers) and (not shared.VainIndependent) then
			teleportedServers = true
			local teleportScript = [[
				shared.vainreload = true
				if shared.VainDeveloper then
					loadstring(readfile('vain/loader.lua'), 'loader')()
				else
					loadstring(game:HttpGet('https://raw.githubusercontent.com/VainRoblox/VainCompiled/'..readfile('vain/profiles/commit.txt')..'/loader.lua', true), 'loader')()
				end
			]]
			if shared.VainDeveloper then
				teleportScript = 'shared.VainDeveloper = true\n'..teleportScript
			end
			if shared.VainCustomProfile then
				teleportScript = 'shared.VainCustomProfile = "'..shared.VainCustomProfile..'"\n'..teleportScript
			end
			vain:Save()
			queue_on_teleport(teleportScript)
		end
	end))

	if not shared.vainreload then
		if not vain.Categories then return end
		if vain.Categories.Main.Options['GUI bind indicator'].Enabled then
			vain:CreateNotification('Finished Loading', vain.VainButton and 'Press the button in the top right to open GUI' or 'Press '..table.concat(vain.Keybind, ' + '):upper()..' to open GUI', 5)
		end
	end
end

if not isfile('vain/profiles/gui.txt') then
	writefile('vain/profiles/gui.txt', 'new')
end
local gui = readfile('vain/profiles/gui.txt')

if not isfolder('vain/assets/'..gui) then
	makefolder('vain/assets/'..gui)
end
vain = loadstring(downloadFile('vain/guis/'..gui..'.lua'), 'gui')()
shared.vain = vain

if not shared.VainIndependent then
	loadstring(downloadFile('vain/games/universal.lua'), 'universal')()
	if isfile('vain/games/'..game.PlaceId..'.lua') then
		loadstring(readfile('vain/games/'..game.PlaceId..'.lua'), tostring(game.PlaceId))(...)
	else
		if not shared.VainDeveloper then
			local suc, res = pcall(function()
				return game:HttpGet('https://raw.githubusercontent.com/VainRoblox/VainCompiled/'..readfile('vain/profiles/commit.txt')..'/games/'..game.PlaceId..'.lua', true)
			end)
			if suc and res ~= '404: Not Found' then
				loadstring(downloadFile('vain/games/'..game.PlaceId..'.lua'), tostring(game.PlaceId))(...)
			end
		end
	end
	finishLoading()
else
	vain.Init = finishLoading
	return vain
end