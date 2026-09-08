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
	The flatter of the two angles that reaches a fixed point.

	Textbook ballistics: for a given speed and gravity there are two arcs onto a point,
	and the smaller angle is the one that gets there soonest, which is the one that leaves
	the target least time to walk out of it. Nothing under the root means the point cannot
	be reached at that speed at all.
]]
--[[
	Aiming a thrown thing, the way it is actually done.

	The intercept quartic this used to solve is the elegant answer and the wrong tool. It
	asks for the flight time of a shot at a moving target in one equation, and at range
	that equation stops having a positive root: the flight time grows, the target's own
	velocity comes to dominate it, and it returns nothing rather than a long shot. Nothing
	aimed and nothing fired, which is why it worked up close and not further out.

	The two halves are separated instead, which is what the clients that work do. Guess
	how long the shot is in the air, work out where the target will be by then, and solve
	the plain ballistic angle onto that fixed point. Then do it again with the flight time
	the solution actually implies. Two or three passes and it stops moving.

	Every part of that has an answer whenever the shot is physically possible, and the one
	place it can fail - the point being further than the projectile can reach at all - is
	a real no rather than a solver giving up.
]]

--[[
	The angle that puts a shot onto a fixed point.

	Textbook ballistics: for a speed and a gravity there are two arcs onto a point, the
	flat one and the lobbed one. Flat is preferred everywhere - it arrives soonest, which
	leaves the target the least time to walk out of it - and lobbed is what clears a wall.
	Nothing under the root means the point cannot be reached at that speed at all.
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

function module.SolveTrajectory(origin, projectileSpeed, gravity, targetPos, targetVelocity, playerGravity, playerHeight, playerJump, params)
	--[[
		Two different questions about the floor, asked separately.

		"Are they standing on something" wants the ground under their feet, so it stays a
		short ray - lengthening it would call somebody at the top of a jump grounded, since
		their vertical velocity passes through zero there, and the shot would be aimed at
		the apex rather than where they fall to.

		"Where will they land" needs to see much further, and answering it with that same
		short ray meant anyone actually falling returned nothing, the clamp never fired,
		and they were predicted tens of studs underground.
	]]
	local groundHit = workspace:Raycast(targetPos, Vector3.new(0, -playerHeight - 0.5, 0), params)
	local grounded = groundHit ~= nil and math.abs(targetVelocity.Y) <= 0.1
	local applyGravity = (not grounded) and playerGravity and playerGravity > 0

	local FLOOR_REACH = 512
	local function floorUnder(position)
		local hit = workspace:Raycast(position, Vector3.new(0, -FLOOR_REACH, 0), params)
		return hit and hit.Position.Y or nil
	end

	-- Where they will be after this long, carried by their own motion and their own fall,
	-- and stopped at the floor they are heading for rather than the one they left.
	local function predictAt(flight)
		local predicted = targetPos + targetVelocity * flight
		if applyGravity then
			predicted -= Vector3.new(0, 0.5 * playerGravity * flight * flight, 0)
		end

		local floor = floorUnder(Vector3.new(predicted.X, targetPos.Y, predicted.Z))
		if floor and predicted.Y < floor then
			predicted = Vector3.new(predicted.X, floor, predicted.Z)
		end
		return predicted
	end

	--[[
		Guess, aim, and let the answer correct the guess.

		The first flight time is the straight distance over the projectile's speed, which
		is close but always short - an arc is longer than the line it spans. Solving gives
		a launch velocity, and its horizontal part over the horizontal distance is the
		flight time that shot really takes. Feeding that back moves the predicted point,
		and after a pass or two neither changes.
	]]
	local function solveArc(high)
		if gravity <= 0 or projectileSpeed <= 0 then return nil end

		local flight = (targetPos - origin).Magnitude / projectileSpeed
		local velocity, point

		for _ = 1, 4 do
			point = predictAt(flight)
			velocity = ballisticAim(origin, projectileSpeed, gravity, point, high)
			if not velocity then return nil end

			local flat = Vector3.new(point.X - origin.X, 0, point.Z - origin.Z).Magnitude
			local across = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
			if across < 0.01 then break end

			local settled = flat / across
			if math.abs(settled - flight) < 1e-3 then
				flight = settled
				break
			end
			flight = settled
		end

		return velocity, flight
	end

	--[[
		Whether the shot can get there, walked along the arc.

		A straight line is not the path an arrow takes: it calls a target behind a low wall
		unreachable when an arc clears it, and one under an overhang reachable when the arc
		buries itself in the ceiling. Only the map is in the filter the caller passes down,
		so the target's own body cannot count as an obstruction.
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

	local velocity, flight = solveArc(false)
	if velocity then
		-- Over it, when going through it is not an option. Only taken when the flat shot
		-- is known blocked and the lobbed one is known clear, so a shot that lands today
		-- still lands.
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

	if gravity == 0 then
		-- Straight line for anything that does not fall.
		local flight = (targetPos - origin).Magnitude / projectileSpeed
		if flight <= 0 then return nil end
		local point = targetPos + targetVelocity * flight
		local direction = (point - origin)
		if direction.Magnitude <= 0 then return nil end
		return origin + direction.Unit * projectileSpeed, direction.Unit, flight
	end
end

return module
