--[[
	Prediction Library
	Source: https://devforum.roblox.com/t/predict-projectile-ballistics-including-gravity-and-motion/1842434
]]
local module = {}
local eps = 1e-9
local function isZero(d)
	return (d > -eps and d < eps)
end

local function cuberoot(x)
	return (x > 0) and math.pow(x, (1 / 3)) or -math.pow(math.abs(x), (1 / 3))
end

local function solveQuadric(c0, c1, c2)
	local s0, s1

	local p, q, D

	p = c1 / (2 * c0)
	q = c2 / c0
	D = p * p - q

	if isZero(D) then
		s0 = -p
		return s0
	elseif (D < 0) then
		return
	else -- if (D > 0)
		local sqrt_D = math.sqrt(D)

		s0 = sqrt_D - p
		s1 = -sqrt_D - p
		return s0, s1
	end
end

local function solveCubic(c0, c1, c2, c3)
	local s0, s1, s2

	local num, sub
	local A, B, C
	local sq_A, p, q
	local cb_p, D

	A = c1 / c0
	B = c2 / c0
	C = c3 / c0

	sq_A = A * A
	p = (1 / 3) * (-(1 / 3) * sq_A + B)
	q = 0.5 * ((2 / 27) * A * sq_A - (1 / 3) * A * B + C)

	cb_p = p * p * p
	D = q * q + cb_p

	if isZero(D) then
		if isZero(q) then -- one triple solution
			s0 = 0
			num = 1
		else -- one single and one double solution
			local u = cuberoot(-q)
			s0 = 2 * u
			s1 = -u
			num = 2
		end
	elseif (D < 0) then -- Casus irreducibilis: three real solutions
		local phi = (1 / 3) * math.acos(-q / math.sqrt(-cb_p))
		local t = 2 * math.sqrt(-p)

		s0 = t * math.cos(phi)
		s1 = -t * math.cos(phi + math.pi / 3)
		s2 = -t * math.cos(phi - math.pi / 3)
		num = 3
	else -- one real solution
		local sqrt_D = math.sqrt(D)
		local u = cuberoot(sqrt_D - q)
		local v = -cuberoot(sqrt_D + q)

		s0 = u + v
		num = 1
	end

	sub = (1 / 3) * A

	if (num > 0) then s0 = s0 - sub end
	if (num > 1) then s1 = s1 - sub end
	if (num > 2) then s2 = s2 - sub end

	return s0, s1, s2
end

function module.solveQuartic(c0, c1, c2, c3, c4)
	local s0, s1, s2, s3

	local coeffs = {}
	local z, u, v, sub
	local A, B, C, D
	local sq_A, p, q, r
	local num

	A = c1 / c0
	B = c2 / c0
	C = c3 / c0
	D = c4 / c0

	sq_A = A * A
	p = -0.375 * sq_A + B
	q = 0.125 * sq_A * A - 0.5 * A * B + C
	r = -(3 / 256) * sq_A * sq_A + 0.0625 * sq_A * B - 0.25 * A * C + D

	if isZero(r) then
		coeffs[3] = q
		coeffs[2] = p
		coeffs[1] = 0
		coeffs[0] = 1

		local results = {solveCubic(coeffs[0], coeffs[1], coeffs[2], coeffs[3])}
		num = #results
		s0, s1, s2 = results[1], results[2], results[3]
	else
		coeffs[3] = 0.5 * r * p - 0.125 * q * q
		coeffs[2] = -r
		coeffs[1] = -0.5 * p
		coeffs[0] = 1

		s0, s1, s2 = solveCubic(coeffs[0], coeffs[1], coeffs[2], coeffs[3])
		z = s0

		u = z * z - r
		v = 2 * z - p

		if isZero(u) then
			u = 0
		elseif (u > 0) then
			u = math.sqrt(u)
		else
			return
		end
		if isZero(v) then
			v = 0
		elseif (v > 0) then
			v = math.sqrt(v)
		else
			return
		end

		coeffs[2] = z - u
		coeffs[1] = q < 0 and -v or v
		coeffs[0] = 1

		do
			local results = {solveQuadric(coeffs[0], coeffs[1], coeffs[2])}
			num = #results
			s0, s1 = results[1], results[2]
		end

		coeffs[2] = z + u
		coeffs[1] = q < 0 and v or -v
		coeffs[0] = 1

		if (num == 0) then
			local results = {solveQuadric(coeffs[0], coeffs[1], coeffs[2])}
			num = num + #results
			s0, s1 = results[1], results[2]
		end
		if (num == 1) then
			local results = {solveQuadric(coeffs[0], coeffs[1], coeffs[2])}
			num = num + #results
			s1, s2 = results[1], results[2]
		end
		if (num == 2) then
			local results = {solveQuadric(coeffs[0], coeffs[1], coeffs[2])}
			num = num + #results
			s2, s3 = results[1], results[2]
		end
	end

	sub = 0.25 * A

	if (num > 0) then s0 = s0 - sub end
	if (num > 1) then s1 = s1 - sub end
	if (num > 2) then s2 = s2 - sub end
	if (num > 3) then s3 = s3 - sub end

	return {s3, s2, s1, s0}
end

--[[
	Aiming a thrown thing.

	Two questions, kept apart. Where will the target be at time t - their own motion, which
	is everything from the tracker down. And can a shot be there at t - which is exact rather
	than iterated. Launched at speed s under gravity g, reaching a point P at time t takes the
	velocity

	    v(t) = (P(t) - origin + 0.5*g*t^2*up) / t

	and the shot exists when |v(t)| is s. So the flight time is the root of

	    f(t) = |P(t) - origin + 0.5*g*t^2*up|^2 - (s*t)^2

	whose first root is the flat arc and whose second is the lobbed one. That holds for any
	motion at all - landing mid-flight, stepping off a ledge, turning round mid-strafe - where
	guessing a flight time and passing it back and forth settled on the wrong answer whenever
	the motion was not a straight line.

	The projectile model is the game's own: no drag, falling at the meta's gravity.
]]

local STEP = 1 / 60
local MAX_STATES = math.ceil(8 / STEP) + 2
local FLOOR_EVERY = 0.1
local HISTORY = 1.6
local FOOTPRINT = Vector3.new(2, 0.1, 2)
local horizontal = Vector3.new(1, 0, 1)

local function sampleBefore(samples, time)
	for i = #samples, 1, -1 do
		if samples[i].at <= time then
			return samples[i]
		end
	end
	return nil
end

--[[
	Following a target between shots.

	One velocity reading cannot say whether somebody is strafing back and forth, hopping, or
	flying from a hit, and that is most of what decides where they are half a second later.
	So roots are sampled every frame while an aimbot is on, and the history is read when a
	shot is solved.

	The velocity itself comes from the engine. A replicated character carries the velocity it
	was sent with and it changes the frame they change direction, where an average of
	positions trails every reversal by half its window - which aimed at the side of a strafe
	they had already left. Positions are still kept to check it against: a rig moved without
	physics has no velocity at all, and a spoofed one disagrees with where they really go.

	Keyed weakly so tracking a part never keeps it alive.
]]
local tracks = setmetatable({}, {__mode = 'k'})

function module.observe(root)
	if typeof(root) ~= 'Instance' then return nil end

	local now = os.clock()
	local track = tracks[root]
	if not track then
		track = {samples = {}, takeoffs = {}, disagree = 0}
		tracks[root] = track
	end

	local samples = track.samples
	local last = samples[#samples]
	if last and now - last.at < 1 / 90 then return track end

	local position, velocity = root.Position, root.AssemblyLinearVelocity
	if last then
		-- Further than they could have moved: a respawn, a teleport or a lag spike, and
		-- nothing from before it describes where they are now.
		local gap = now - last.at
		if (position - last.pos).Magnitude > math.max(25, (velocity.Magnitude + 80) * gap * 2) then
			table.clear(samples)
			table.clear(track.takeoffs)
			track.disagree, track.spoofed = 0, false
			last = nil
		end
	end

	local sample = {at = now, pos = position, vel = velocity}
	table.insert(samples, sample)
	while #samples > 2 and now - samples[1].at > HISTORY do
		table.remove(samples, 1)
	end

	local reference = sampleBefore(samples, now - 0.1)
	if reference and now - reference.at > 0.05 then
		local measured = (position - reference.pos) / (now - reference.at)
		sample.measured = measured

		-- A reversal or a hit disagrees for a few frames while the measurement catches up.
		-- Only a disagreement that lasts means the velocity is not describing the motion.
		local reported, moved = velocity * horizontal, measured * horizontal
		if (reported - moved).Magnitude > math.max(15, moved.Magnitude * 0.75) then
			track.disagree = math.min(track.disagree + 1, 30)
		else
			track.disagree = math.max(track.disagree - 1, 0)
		end
		if track.disagree >= 12 then
			track.spoofed = true
		elseif track.disagree == 0 then
			track.spoofed = false
		end
	end

	-- A takeoff: rising fast just after being on something. Going from falling to rising
	-- within a frame needs a floor in between, so a jump from standing and a hop off a
	-- landing both count.
	if last and velocity.Y > 12 and last.vel.Y <= 12 then
		local lowest = math.huge
		for i = #samples - 1, 1, -1 do
			if now - samples[i].at > 0.3 then break end
			lowest = math.min(lowest, samples[i].vel.Y)
		end
		if lowest <= 2 then
			table.insert(track.takeoffs, {at = now, speed = velocity.Y})
			if #track.takeoffs > 5 then
				table.remove(track.takeoffs, 1)
			end
		end
	end

	return track
end

local function velocityOf(track, sample)
	return track.spoofed and sample.measured or sample.vel
end

local function currentVelocity(track, fallback)
	local latest = track.samples[#track.samples]
	if not latest then return fallback end

	local reported, measured = velocityOf(track, latest), latest.measured
	-- Moving with no velocity at all: an anchored rig, a tweened NPC, CFrame movement.
	if measured and (reported * horizontal).Magnitude < 1 and (measured * horizontal).Magnitude > 3 then
		return Vector3.new(measured.X, reported.Y, measured.Z)
	end
	return reported
end

-- Kept for anything still calling it by its old name.
function module.smoothVelocity(part, fallback)
	local track = module.observe(part)
	return track and currentVelocity(track, fallback or Vector3.zero) or fallback or Vector3.zero
end

--[[
	Knocked back.

	A hit adds a burst of speed that their own movement then works off, so leading them by
	the speed they have straight after it puts the shot yards past where they stop. The burst
	is found as a sudden rise in horizontal speed; the speed from before it is what they go
	back to, and the rest fades - at a rate read off how much of it is already gone, once
	enough time has passed to read one.
]]
local function readKnockback(track, now, grounded)
	local samples = track.samples
	local count = #samples
	if count < 2 then return nil end

	local current = velocityOf(track, samples[count]) * horizontal
	for i = count, 2, -1 do
		local sample = samples[i]
		if now - sample.at > 0.7 then break end

		local before = velocityOf(track, samples[i - 1]) * horizontal
		local after = velocityOf(track, sample) * horizontal
		-- A reversal changes direction at the same speed. A hit adds speed.
		if (after - before).Magnitude > 22 and after.Magnitude > before.Magnitude + 12 then
			local burst = after - before
			local left = current - before
			if left.Magnitude < 6 or left:Dot(burst.Unit) < left.Magnitude * 0.5 then
				return nil
			end

			local rate = grounded and 8 or 2.5
			local elapsed = now - sample.at
			if elapsed > 0.08 and left.Magnitude < burst.Magnitude then
				rate = math.clamp(math.log(burst.Magnitude / left.Magnitude) / elapsed, 0.8, 12)
			end
			return {base = before, burst = left, rate = rate}
		end
	end
	return nil
end

--[[
	Strafing back and forth across the shot.

	Only the sideways part of their movement is read, because it is the only part a shot is
	sensitive to: an arrow flying at somebody passes through wherever they are along its
	path, but two studs to the side and it goes past. Leading a strafer by their current
	speed is the worst guess there is - it aims at the far end of a swing they will have
	turned back from before the arrow gets there.

	Every reversal marks one end of the swing. The last few give where both ends are, how
	long a swing takes and where along it they are now. Up to the next reversal the path is
	known. Past it, the moment of their next keypress is not, so the prediction settles
	towards the middle of the swing the further past it has to guess - which is where they
	are most likely to be.
]]
local function readStrafe(track, origin, now)
	local samples = track.samples
	local count = #samples
	if count < 10 then return nil end

	local latest = samples[count]
	local look = (latest.pos - origin) * horizontal
	if look.Magnitude < 2 then return nil end
	look = look.Unit
	local axis = Vector3.new(-look.Z, 0, look.X)

	local turns, direction, edge = {}, 0, nil
	for i = 1, count do
		local sample = samples[i]
		local speed = velocityOf(track, sample):Dot(axis)
		local along = sample.pos:Dot(axis)
		if math.abs(speed) > 4 then
			local moving = speed > 0 and 1 or -1
			if direction ~= 0 and moving ~= direction then
				table.insert(turns, {at = sample.at, edge = edge})
				edge = along
			end
			direction = moving
		end
		if direction > 0 then
			edge = edge and math.max(edge, along) or along
		elseif direction < 0 then
			edge = edge and math.min(edge, along) or along
		end
	end

	local n = #turns
	local speedNow = velocityOf(track, latest):Dot(axis)
	if n < 3 or math.abs(speedNow) <= 4 then return nil end

	local newest, older = turns[n].at - turns[n - 1].at, turns[n - 1].at - turns[n - 2].at
	local half = (newest + older) * 0.5
	if half < 0.08 or half > 1.2 or math.max(newest, older) > math.min(newest, older) * 2 then
		return nil
	end
	-- Stopped swinging and carried on one way.
	if now - turns[n].at > half * 1.6 + 0.1 then return nil end

	local near, far, oldest = turns[n].edge, turns[n - 1].edge, turns[n - 2].edge
	local width = math.abs(near - far)
	if width < 1 then return nil end

	local swing = width / half
	local middle = (near + far) * 0.5
	local middleAt = (turns[n].at + turns[n - 1].at) * 0.5
	local drift = 0
	if oldest then
		local previousAt = (turns[n - 1].at + turns[n - 2].at) * 0.5
		if middleAt - previousAt > 0.02 then
			drift = (middle - (far + oldest) * 0.5) / (middleAt - previousAt)
		end
	end
	drift = math.clamp(drift, -swing * 0.5, swing * 0.5)

	return {
		axis = axis,
		centre = middle + drift * (now - middleAt),
		drift = drift,
		reach = width * 0.5,
		swing = swing,
		half = half,
		direction = speedNow > 0 and 1 or -1,
		along = latest.pos:Dot(axis),
		speed = speedNow
	}
end

local function strafeAlong(strafe, t)
	local reach, swing = strafe.reach, strafe.swing
	local x = math.clamp(strafe.along - strafe.centre, -reach, reach)
	local direction, left, turnedAt = strafe.direction, t, nil
	for _ = 1, 24 do
		local needed = (direction > 0 and (reach - x) or (x + reach)) / swing
		if left <= needed then
			x += direction * swing * left
			break
		end
		x = direction * reach
		left -= needed
		turnedAt = turnedAt or (t - left)
		direction = -direction
	end
	if turnedAt then
		-- Past the reversal that can be seen coming, the swing is a guess, and the middle
		-- of it is where a guess is least wrong.
		x *= math.exp(-(t - turnedAt) / strafe.half)
	end
	return strafe.centre + strafe.drift * t + x
end

-- A footprint rather than a single ray, so somebody standing at the edge of a block is
-- standing on it instead of over whatever is below.
local function castDown(position, reach, params)
	local ok, hit = pcall(workspace.Blockcast, workspace, CFrame.new(position), FOOTPRINT, Vector3.new(0, -reach, 0), params)
	if not ok then
		hit = workspace:Raycast(position, Vector3.new(0, -reach, 0), params)
	end
	return hit and hit.Position.Y or nil
end

--[[
	Where a character will be, as a function of time.

	Horizontally: the speed they have, unless their history says they are working off a
	knockback or swinging back and forth. Vertically: their own physics, stepped once and
	reused for every time the solver asks about.

	The vertical is where the old prediction went wrong, both ways. Standing somebody was
	predicted falling unless a floor ray under them said otherwise, so any ray that missed -
	the edge of a block, a block outside the map filter - put the shot under their feet. And
	the game's jumping flag, which stays set for a whole chain of hops, was read as a jump
	starting now, so anyone on their way down from a hop was aimed over. Now standing people
	stay at their height unless the ground under them is found to end, and a hop only starts
	after they have landed.
]]
local function buildMotion(origin, rootPos, offset, velocity, fall, playerHeight, playerJump, floorParams, track, now)
	local rootHeight = (playerHeight and playerHeight > 0) and playerHeight or 3
	local floorNow = castDown(rootPos, 600, floorParams)
	local height = floorNow and rootPos.Y - floorNow
	-- Nothing found under them is not proof of nothing being there, so it does not make
	-- somebody who is not moving vertically start falling.
	local grounded = math.abs(velocity.Y) < 4 and (height == nil or height < rootHeight + 1.2)

	local stand = rootHeight
	if floorNow and grounded and math.abs(height - rootHeight) < 1.5 then
		stand = height
	end

	-- Off the ground but not falling the way gravity would make them: flying.
	local flying = false
	if not grounded and track and fall > 0 then
		local samples, oldest = track.samples, nil
		flying = true
		for i = #samples, 1, -1 do
			local sample = samples[i]
			if now - sample.at > 0.35 then break end
			oldest = sample
			if math.abs(velocityOf(track, sample).Y - velocity.Y) > math.max(fall * 0.1, 6) then
				flying = false
				break
			end
		end
		flying = flying and oldest ~= nil and now - oldest.at > 0.25
	end

	-- Hopping: seen taking off repeatedly, or flagged by the caller.
	local hopSpeed, hopEvery
	if track then
		local takeoffs = track.takeoffs
		local latest = takeoffs[#takeoffs]
		local gaps, span, speeds = 0, 0, latest and latest.speed or 0
		for i = #takeoffs, 2, -1 do
			local gap = takeoffs[i].at - takeoffs[i - 1].at
			if gap > 1.5 then break end
			gaps += 1
			span += gap
			speeds += takeoffs[i - 1].speed
		end
		if gaps > 0 and now - latest.at < (span / gaps) * 1.5 + 0.2 then
			hopEvery, hopSpeed = span / gaps, speeds / (gaps + 1)
		end
	end
	if not hopSpeed and playerJump and playerJump > 0 then
		hopSpeed = playerJump
	end
	if flying or fall <= 0 then
		hopSpeed = nil
	end

	-- The average height of a hop, for when which part of one they will be in is a guess.
	local groundGap, meanLift = 0.05, nil
	if hopSpeed then
		local airTime = 2 * hopSpeed / fall
		if hopEvery then
			groundGap = math.clamp(hopEvery - airTime, 0.02, 0.5)
		end
		meanLift = (hopSpeed * hopSpeed / (2 * fall)) * (2 / 3) * airTime / (airTime + groundGap)
	end

	-- With no floor found anywhere the casts cannot be trusted, and the lowest they have
	-- been lately is the best stand-in for the ground they will come down on.
	local lowest
	if not floorNow and track then
		for _, sample in track.samples do
			lowest = lowest and math.min(lowest, sample.pos.Y) or sample.pos.Y
		end
	end

	local knock = track and readKnockback(track, now, grounded)
	local strafe = track and not knock and readStrafe(track, origin, now)
	local base = velocity * horizontal
	local startFlat = rootPos * horizontal

	local function flatAt(t)
		local at
		if knock then
			at = startFlat + knock.base * t + knock.burst * ((1 - math.exp(-knock.rate * t)) / knock.rate)
		else
			at = startFlat + base * t
		end
		if strafe then
			at += strafe.axis * (strafeAlong(strafe, t) - (strafe.along + strafe.speed * t))
		end
		return at
	end

	local floors = {[0] = floorNow or false}
	local function restAt(t, point, fromY)
		local index = math.floor(t / FLOOR_EVERY)
		local known = floors[index]
		if known == nil then
			known = castDown(Vector3.new(point.X, fromY + 0.5, point.Z), 600, floorParams) or false
			floors[index] = known
		end
		if known then
			return known + stand
		end
		return lowest
	end

	local simY, simVy = rootPos.Y, grounded and 0 or velocity.Y
	local onGround, groundedFor, hops = grounded and not flying, 0, 0
	local states = {{y = simY, hops = 0, rest = floorNow and floorNow + stand or lowest}}

	local function advance()
		local t = #states * STEP
		local rest = restAt(t, flatAt(t), simY)

		if flying then
			simY += simVy * STEP
			if rest and simY < rest then
				simY = rest
			end
		else
			if onGround then
				if rest and rest > simY + 2.2 then
					-- Too tall to step onto. They are stopped by it, not lifted.
				elseif rest and rest >= simY - 0.6 then
					simY = rest
				elseif floorNow then
					-- The ground ends, or drops away, under where they are heading.
					onGround, simVy = false, 0
				end
				if onGround and hopSpeed then
					groundedFor += STEP
					if groundedFor >= groundGap then
						onGround, simVy, hops = false, hopSpeed, hops + 1
					end
				end
			end
			if not onGround then
				local nextY = simY + simVy * STEP - 0.5 * fall * STEP * STEP
				simVy -= fall * STEP
				if rest and simVy <= 0 and nextY <= rest and simY >= rest - 1.5 then
					nextY, simVy, onGround, groundedFor = rest, 0, true, 0
				end
				simY = nextY
			end
		end

		table.insert(states, {y = simY, hops = hops, rest = rest})
	end

	local function heightAt(t)
		local position = math.max(t, 0) / STEP
		local index = math.floor(position)
		local wanted = math.min(index + 2, MAX_STATES)
		while #states < wanted do
			advance()
		end

		local a = states[math.min(index + 1, #states)]
		local b = states[math.min(index + 2, #states)]
		local y = a.y + (b.y - a.y) * math.clamp(position - index, 0, 1)
		-- Hops they have not taken yet: the further ahead, the less the exact phase of one
		-- is worth, and the more their average height is.
		if b.hops > 0 and meanLift and b.rest then
			local trust = math.min(0.25 + 0.2 * b.hops, 0.8)
			y += (b.rest + meanLift - y) * trust
		end
		return y
	end

	return function(t)
		local point = flatAt(t)
		return Vector3.new(point.X, heightAt(t), point.Z) + offset
	end
end

--[[
	origin, projectileSpeed, gravity  - the shot, from the game's own projectile meta.
	targetPos                         - the point being aimed at, whichever part that is.
	targetVelocity                    - how they are moving right now.
	playerGravity                     - the gravity THEY fall at, which is not always the
	                                    world's: balloons, the void kit and an owl grab all
	                                    change it.
	playerHeight                      - their root's height above the floor when standing.
	playerJump                        - their takeoff speed when they are known to be hopping,
	                                    so every landing is followed by another hop. It is not
	                                    a jump happening now; their velocity already says that.
	params                            - raycast filter for what the shot collides with.
	extra                             - optional: {
	                                        root        - their root part; turns on everything
	                                                      read from their history,
	                                        rootPosition,
	                                        lifetime    - the longest the shot can fly,
	                                        floorParams - what can be stood on, when that is
	                                                      not the same as params
	                                    }
]]
function module.SolveTrajectory(origin, projectileSpeed, gravity, targetPos, targetVelocity, playerGravity, playerHeight, playerJump, params, extra)
	if not (origin and targetPos) then return nil end
	if not projectileSpeed or projectileSpeed <= 0 then return nil end

	gravity = math.max(gravity or 0, 0)
	targetVelocity = targetVelocity or Vector3.zero
	extra = extra or {}

	--[[
		Their gravity, sanity checked.

		Callers work this out from the game - balloons lighten you, the owl carries you,
		some kits float - and the arithmetic can produce zero or a negative number. Predicting
		a target that accelerates upward for ever is how an aimbot ends up pointing at the
		sky, so anything that is not a real downward pull means "they do not fall".
	]]
	local fall = playerGravity or 0
	if fall ~= fall or fall < 0 then fall = 0 end

	local now = os.clock()
	local root = extra.root
	if typeof(root) ~= 'Instance' or not root.Parent then
		root = nil
	end
	local track = root and module.observe(root)
	local rootPos = extra.rootPosition or (root and root.Position) or targetPos
	local velocity = track and currentVelocity(track, targetVelocity) or targetVelocity

	local floorParams = extra.floorParams or params
	if not floorParams and root then
		floorParams = RaycastParams.new()
		floorParams.FilterDescendantsInstances = {root.Parent}
		floorParams.RespectCanCollide = true
	end

	local aimAt
	if not root and velocity.Magnitude < 1e-3 and not (playerHeight and playerHeight > 0) then
		-- A spot, not somebody: nothing to predict.
		aimAt = function()
			return targetPos
		end
	else
		aimAt = buildMotion(origin, rootPos, targetPos - rootPos, velocity, fall, playerHeight, playerJump, floorParams, track, now)
	end

	local distance = (targetPos - origin).Magnitude
	if distance < 0.05 then return nil end

	local lift = Vector3.new(0, 0.5 * gravity, 0)
	local speedSquared = projectileSpeed * projectileSpeed

	local function required(t)
		return aimAt(t) - origin + lift * (t * t)
	end

	-- Below zero once a shot at this speed can be where they are by t.
	local function excess(t)
		local needed = required(t)
		return needed:Dot(needed) - speedSquared * t * t
	end

	-- Long enough for a lob, never longer than the shot lives.
	local horizon = distance / projectileSpeed * 3 + 0.6
	if gravity > 0 then
		horizon = math.max(horizon, 2 * projectileSpeed / gravity + 0.3)
	end
	horizon = math.min(horizon, extra.lifetime or 8, 8)

	--[[
		Stepping out along the flight time until the sign changes, then halving the step.

		The steps are packed towards zero, where the answer for a close target sits in a few
		hundredths of a second, and spread out towards the horizon, where only lobs live.
	]]
	local SCAN = 48
	local function scanTime(i)
		return horizon * (i / SCAN) ^ 1.6
	end

	local function crossing(fromIndex)
		local lastTime = scanTime(fromIndex)
		local wasReachable = excess(lastTime) < 0
		for i = fromIndex + 1, SCAN do
			local t = scanTime(i)
			local reachable = excess(t) < 0
			if reachable ~= wasReachable then
				local low, high = lastTime, t
				for _ = 1, 24 do
					local mid = (low + high) * 0.5
					if (excess(mid) < 0) == wasReachable then
						low = mid
					else
						high = mid
					end
				end
				return (low + high) * 0.5, i
			end
			lastTime, wasReachable = t, reachable
		end
		return nil
	end

	local flight, index = crossing(0)
	if not flight then return nil end

	local function launch(t)
		return required(t).Unit * projectileSpeed
	end

	local shot = launch(flight)

	--[[
		Whether the shot can get there, walked along the arc.

		A straight line is not the path an arrow takes: it calls a target behind a low wall
		unreachable when an arc clears it, and one under an overhang reachable when the arc
		buries itself in the ceiling.
	]]
	local function arcClear(launched, time)
		local previous, steps = origin, 8
		for i = 1, steps do
			local at = time * (i / steps)
			local point = origin + launched * at - Vector3.new(0, 0.5 * gravity * at * at, 0)
			if workspace:Raycast(previous, point - previous, params) then return false end
			previous = point
		end
		return true
	end

	-- Over it, when through it is not an option. Only when the flat shot is known blocked
	-- and the lobbed one is known clear, so a shot that lands today still lands.
	if gravity > 0 and params then
		if workspace:Raycast(origin, targetPos - origin, params) and not arcClear(shot, flight) then
			local lobbedFlight = crossing(index)
			if lobbedFlight then
				local lobbed = launch(lobbedFlight)
				if arcClear(lobbed, lobbedFlight) then
					shot, flight = lobbed, lobbedFlight
				end
			end
		end
	end

	return origin + shot, shot.Unit, flight
end

return module
