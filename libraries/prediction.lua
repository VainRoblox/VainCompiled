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

	Two separate questions, and the whole job is not letting them contaminate each other.

	Where will the target be? That is their own physics: they carry on at the speed they
	are moving, they fall at their own gravity if they are off the ground, and they stop
	when they reach the floor - the floor under where they are going, not the one they left.

	How do I throw at a point? That is textbook ballistics. For a launch speed and a gravity
	there are two arcs onto any reachable point, and the flatter one arrives soonest, which
	leaves the target the least time to walk out of it.

	They are coupled only through the flight time, so they are solved by passing that back
	and forth: guess it, predict where they will be, solve the arc onto that point, take the
	flight time that arc really implies, repeat. It settles in two or three passes, and every
	step has an answer whenever the shot is possible at all.

	The projectile model is the game's own, taken from its projectile controller:

	    x(t) = vx*t + x0      y(t) = -0.5*g*t^2 + vy*t + y0      z(t) = vz*t + z0

	which is plain ballistics with no drag, so nothing here is an approximation of it.
]]

--[[
	The angle that puts a shot onto a fixed point.

	For a speed and a gravity there are two arcs onto a point: the flat one and the lobbed
	one. Nothing under the root means the point cannot be reached at that speed at all,
	which is a real answer and not a failure to converge.
]]
local function launchAngle(speed, gravity, flat, rise, high)
	local v2 = speed * speed
	local inner = v2 * v2 - gravity * (gravity * flat * flat + 2 * rise * v2)
	if inner < 0 then return nil end

	local root = math.sqrt(inner)
	return math.atan((v2 + (high and root or -root)) / (gravity * flat))
end

local function ballisticAim(origin, speed, gravity, point, high)
	local flatVec = Vector3.new(point.X - origin.X, 0, point.Z - origin.Z)
	local flat = flatVec.Magnitude
	if flat < 0.01 or gravity <= 0 or speed <= 0 then return nil end

	local angle = launchAngle(speed, gravity, flat, point.Y - origin.Y, high)
	if not angle or angle ~= angle then return nil end

	local axis = Vector3.new(-flatVec.Z, 0, flatVec.X)
	if axis.Magnitude < 1e-6 then return nil end
	return CFrame.fromAxisAngle(axis.Unit, angle) * (flatVec.Unit * speed)
end

--[[
	origin, projectileSpeed, gravity  - the shot, from the game's own projectile meta.
	targetPos                         - the point being aimed at, whichever part that is.
	targetVelocity                    - how they are moving right now.
	playerGravity                     - the gravity THEY fall at, which is not always the
	                                    world's: balloons, the void kit and an owl grab all
	                                    change it.
	playerHeight                      - their root's height above the floor when standing.
	playerJump                        - non-nil when they are known to be jumping, carrying
	                                    the jump speed, since a fresh jump is often not in
	                                    the sampled velocity yet.
	params                            - raycast filter for the map, used for the floor and
	                                    for checking the arc is clear.
	extra                             - optional: { rootPosition, lifetime }.
]]
function module.SolveTrajectory(origin, projectileSpeed, gravity, targetPos, targetVelocity, playerGravity, playerHeight, playerJump, params, extra)
	if not (origin and targetPos) then return nil end
	if not projectileSpeed or projectileSpeed <= 0 then return nil end

	gravity = gravity or 0
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

	local FLOOR_REACH = 600
	local function floorUnder(x, y, z)
		local hit = workspace:Raycast(Vector3.new(x, y, z), Vector3.new(0, -FLOOR_REACH, 0), params)
		return hit and hit.Position.Y or nil
	end

	--[[
		How high the aimed-at point sits above the floor when they are standing on it.

		Everything about the vertical prediction hangs off this, and it is the part that was
		wrong before: the floor was found and the prediction clamped to the floor ITSELF, so
		a target who jumped was predicted to land with the aimed-at part at ground level -
		the shot went to their feet, or into the floor.

		It also cannot be assumed to be the root's height, because the caller chooses what to
		aim at and it is frequently the head. Given the root, the offset between the two is
		exact; without it, what they are standing at right now is a good measurement, and the
		root height is the last resort.
	]]
	local groundNow = floorUnder(targetPos.X, targetPos.Y + 2, targetPos.Z)
	local aboveFloor = groundNow and (targetPos.Y - groundNow) or nil

	local vy = targetVelocity.Y
	-- A jump that has just started is often not in the sampled velocity yet, and missing it
	-- means predicting somebody who is about to rise six studs as standing still.
	if playerJump and playerJump > 0 and vy < 1 then vy = playerJump end

	local rootHeight = (playerHeight and playerHeight > 0) and playerHeight or 3
	local airborne = math.abs(vy) > 1
		or (aboveFloor ~= nil and aboveFloor > rootHeight + 2.5)

	local standHeight
	if extra.rootPosition then
		standHeight = rootHeight + (targetPos.Y - extra.rootPosition.Y)
	elseif aboveFloor and not airborne then
		standHeight = aboveFloor
	else
		standHeight = rootHeight
	end

	local driftX, driftZ = targetVelocity.X, targetVelocity.Z

	--[[
		Where they will be, by their own physics.

		Airborne, they follow their jump or their fall and stop when they reach the floor
		they are heading for. On foot they keep their height above the ground rather than
		their height in the world, so somebody running down a slope or off a bridge is
		predicted going down with it - and they fall no faster than gravity allows, so
		running off a ledge is not predicted as dropping instantly.
	]]
	local function predictAt(flight)
		local x = targetPos.X + driftX * flight
		local z = targetPos.Z + driftZ * flight

		local y
		if airborne then
			y = targetPos.Y + vy * flight - 0.5 * fall * flight * flight
		else
			y = targetPos.Y - 0.5 * fall * flight * flight
		end

		local floor = floorUnder(x, math.max(targetPos.Y, y) + 2, z)
		if floor then
			local resting = floor + standHeight
			if y < resting then
				y = resting
			elseif not airborne and y > resting then
				-- Following the ground upward: a walk up a slope or a stair.
				y = resting
			end
		end

		return Vector3.new(x, y, z)
	end

	--[[
		Guess, aim, and let the answer correct the guess.

		The first guess is the straight distance over the speed, which is always a little
		short because an arc is longer than the line it spans. Solving gives a launch
		velocity whose horizontal part, over the horizontal distance, is the flight time that
		shot really takes; feeding that back moves the predicted point, and after a couple of
		passes neither moves.
	]]
	local function solveArc(high)
		if gravity <= 0 or projectileSpeed <= 0 then return nil end

		local flight = (targetPos - origin).Magnitude / projectileSpeed
		local velocity, point

		for _ = 1, 6 do
			point = predictAt(flight)
			velocity = ballisticAim(origin, projectileSpeed, gravity, point, high)
			if not velocity then return nil end

			local flat = Vector3.new(point.X - origin.X, 0, point.Z - origin.Z).Magnitude
			local across = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
			if across < 0.01 then break end

			local settled = flat / across
			local moved = math.abs(settled - flight)
			flight = settled
			if moved < 1e-3 then break end
		end

		if extra.lifetime and flight > extra.lifetime then return nil end
		return velocity, flight
	end

	--[[
		Whether the shot can get there, walked along the arc.

		A straight line is not the path an arrow takes: it calls a target behind a low wall
		unreachable when an arc clears it, and one under an overhang reachable when the arc
		buries itself in the ceiling.
	]]
	local function arcClear(velocity, flight)
		local previous, steps = origin, 8
		for i = 1, steps do
			local at = flight * (i / steps)
			local point = origin + velocity * at - Vector3.new(0, 0.5 * gravity * at * at, 0)
			if workspace:Raycast(previous, point - previous, params) then return false end
			previous = point
		end
		return true
	end

	if gravity > 0 then
		local velocity, flight = solveArc(false)
		if velocity then
			-- Over it, when through it is not an option. Only when the flat shot is known
			-- blocked and the lobbed one is known clear, so a shot that lands today still
			-- lands.
			if params then
				local blocked = workspace:Raycast(origin, targetPos - origin, params)
				if blocked and not arcClear(velocity, flight) then
					local lobbed, lobbedFlight = solveArc(true)
					if lobbed and arcClear(lobbed, lobbedFlight) then
						return origin + lobbed, lobbed.Unit, lobbedFlight
					end
				end
			end

			return origin + velocity, velocity.Unit, flight
		end
		return nil
	end

	--[[
		Nothing that falls, so it is a straight line - but still a moving target.

		The lead is iterated for the same reason the arc is: leading to where they are now
		gives a flight time, which gives a better lead, which gives a better flight time.
	]]
	local flight = (targetPos - origin).Magnitude / projectileSpeed
	local point
	for _ = 1, 4 do
		point = predictAt(flight)
		local span = (point - origin).Magnitude
		if span <= 0 then return nil end
		local settled = span / projectileSpeed
		local moved = math.abs(settled - flight)
		flight = settled
		if moved < 1e-3 then break end
	end

	if extra.lifetime and flight > extra.lifetime then return nil end

	local direction = point - origin
	if direction.Magnitude <= 0 then return nil end
	return origin + direction.Unit * projectileSpeed, direction.Unit, flight
end

return module
