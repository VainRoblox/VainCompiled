local isfile = isfile or function(file)
	local suc, res = pcall(function()
		return readfile(file)
	end)
	return suc and res ~= nil and res ~= ''
end
local delfile = delfile or function(file)
	writefile(file, '')
end

local function downloadFile(path, func)
	--[[
		An emptied file counts as missing.

		delfile's fallback writes an empty file rather than deleting, and a host with a
		real isfile then reports that as present - so the file would never be fetched
		again and the client would sit on nothing. Only assets are checked this way; a
		.lua is already handled by the watermark.
	]]
	local cached = isfile(path)
	if cached and not path:find('%.lua') then
		local ok, data = pcall(readfile, path)
		if not ok or data == '' then
			cached = false
		end
	end

	if not cached then
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

--[[
	Drops cached assets whether or not they carry a watermark.

	wipeFolder can only remove files holding the download watermark, and that watermark is
	a Lua comment - so it is never written into a png, and a png is therefore never
	removed. downloadFile only fetches a file that is missing, so once an image has been
	cached it is cached for good and no update can replace it.

	That is not theoretical: clients that loaded during a build with different artwork are
	still showing it, and nothing short of deleting the files by hand would fix them.
	Keyed on the commit rather than run every time, since re-downloading eighty images on
	every injection would be worse than the problem.
]]
local function wipeAssets()
	if not isfolder('vain/assets') then return end
	for _, entry in listfiles('vain/assets') do
		if isfolder(entry) then
			for _, file in listfiles(entry) do
				pcall(delfile, file)
			end
		else
			pcall(delfile, entry)
		end
	end
end

--[[
	A one-time forced reset of everything cached, for clients left on a bad build.

	The watermark wipe cannot touch images, and keying the asset wipe on the commit only
	helps a client that reaches this code with a cache it can compare - it does nothing
	for one holding a stale guis/new.lua or a half written folder. Bumping this number
	clears the lot once, on every client, whatever state it is in.

	Raise it only to force that: a reset costs everyone one slower injection.
]]
local CACHE_VERSION = '2'

local function forceReset()
	if isfile('vain/profiles/cache.txt') and readfile('vain/profiles/cache.txt') == CACHE_VERSION then
		return
	end
	for _, folder in {'vain/assets', 'vain/games', 'vain/guis', 'vain/libraries'} do
		if isfolder(folder) then
			for _, entry in listfiles(folder) do
				if isfolder(entry) then
					for _, file in listfiles(entry) do
						pcall(delfile, file)
					end
				else
					pcall(delfile, entry)
				end
			end
		end
	end
	-- main.lua lives directly in vain/ and is wiped by name rather than by walking the
	-- folder, so that profiles and the loader itself are left alone.
	pcall(delfile, 'vain/main.lua')
	pcall(writefile, 'vain/profiles/cache.txt', CACHE_VERSION)
	print('[Vain] cache reset')
end

local function wipeFolder(path)
	if not isfolder(path) then return end
	for _, file in listfiles(path) do
		if file:find('loader') then continue end
		if isfile(file) and select(1, readfile(file):find('--This watermark is used to delete the file if its cached, remove it to make the file persist after vain updates.')) == 1 then
			delfile(file)
		end
	end
end

for _, folder in {'vain', 'vain/games', 'vain/profiles', 'vain/assets', 'vain/libraries', 'vain/guis'} do
	if not isfolder(folder) then
		makefolder(folder)
	end
end

if not shared.VainDeveloper then
	local ok, page = pcall(function()
		-- The no-cache flag matters as much here as it does in downloadFile, which
		-- passes it for the same reason: executors cache HTTP responses, and a cached
		-- copy of this page hands back the previous commit hash, which re-pins every
		-- download below to the old build. That looks exactly like re-injecting never
		-- picking anything up. The query string is ignored by GitHub and defeats any
		-- cache that keys on the URL alone.
		return game:HttpGet('https://github.com/VainRoblox/VainCompiled?nocache='..tick(), true)
	end)

	local commit
	if ok and type(page) == 'string' then
		local ind = page:find('currentOid')
		commit = ind and page:sub(ind + 13, ind + 52) or nil
		commit = commit and #commit == 40 and commit or nil
	end
	commit = commit or 'main'

	-- Every URL downloadFile builds is based on this file, so it has to be rewritten
	-- on each run. Leaving it stale pins the entire client to whichever commit was
	-- cached at the time and no amount of re-injecting will ever fetch an update.
	writefile('vain/profiles/commit.txt', commit)
	-- Printed so a stale client is obvious: if this hash does not change between
	-- injections after a push, the update is being cached rather than fetched.
	print('[Vain] loading commit ' .. commit)

	-- Drop the cached copies so the commit above is actually pulled. 'vain' itself
	-- has to be included because main.lua lives there - clearing only the
	-- subfolders left the old entry point in place. wipeFolder only removes files
	-- carrying the download watermark, so saved profiles and downloaded assets stay.
	forceReset()

	for _, folder in {'vain', 'vain/games', 'vain/guis', 'vain/libraries'} do
		wipeFolder(folder)
	end

	-- Assets are tracked separately because they cannot carry the watermark. The commit
	-- they were fetched at is recorded beside them and they are dropped when it moves.
	local assetsAt = isfile('vain/profiles/assets.txt') and readfile('vain/profiles/assets.txt') or ''
	if assetsAt ~= commit then
		wipeAssets()
		writefile('vain/profiles/assets.txt', commit)
	end
end

return loadstring(downloadFile('vain/main.lua'), 'main')()