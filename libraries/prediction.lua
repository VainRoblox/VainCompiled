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

-- Solve for the flight time `t` of a projectile fired from `origin` at
-- `projectileSpeed` under downward `gravity` so that it intercepts a target
-- starting at `targetPos` and moving at constant `targetVelocity`. This is the
-- classic ballistic-intercept quartic: we want |aimDir|*speed such that, after
-- time t, the projectile (origin + dir*speed*t - 0.5*g*t^2 ŷ) meets the target
-- (targetPos + targetVelocity*t). Squaring the speed constraint gives a quartic
-- in t with the coefficients below. Returns the earliest positive real root.
local function solveInterceptTime(origin, projectileSpeed, gravity, targetPos, targetVelocity)
	local disp = targetPos - origin
	local p, q, r = targetVelocity.X, targetVelocity.Y, targetVelocity.Z
	local h, j, k = disp.X, disp.Y, disp.Z
	local l = -0.5 * gravity

	local solutions = module.solveQuartic(
		l * l,
		-2 * q * l,
		q * q - 2 * j * l - projectileSpeed * projectileSpeed + p * p + r * r,
		2 * j * q + 2 * h * p + 2 * k * r,
		j * j + h * h + k * k
	)

	if not solutions then return nil end

	local bestT = math.huge
	for _, v in solutions do
		if v > 0 and v < bestT then
			bestT = v
		end
	end
	return bestT < math.huge and bestT or nil
end

function module.SolveTrajectory(origin, projectileSpeed, gravity, targetPos, targetVelocity, playerGravity, playerHeight, playerJump, params)
	--[[
		Two different questions about the floor, asked separately.

		"Are they standing on something" only wants to know about the ground directly
		under their feet, so it stays a short ray - lengthening it would call somebody at
		the top of a jump grounded, because their vertical velocity passes through zero
		there, and the shot would then be aimed where they are rather than where they fall
		to.

		"Where will they land" is a different question and needs to see much further. It
		was being answered with the same short ray, so anyone actually falling - off a
		bridge, off an island, the most common way a target moves in this game - returned
		nothing, the clamp below never fired, and the parabola was free to predict them
		tens of studs underground. The shot went into the floor.
	]]
	local groundHit = workspace:Raycast(targetPos, Vector3.new(0, -playerHeight - 0.5, 0), params)
	local grounded = groundHit ~= nil and math.abs(targetVelocity.Y) <= 0.1

	local FLOOR_REACH = 512
	local function floorUnder(position)
		local hit = workspace:Raycast(position, Vector3.new(0, -FLOOR_REACH, 0), params)
		return hit and hit.Position.Y or nil
	end

	-- The target accelerates under their own gravity over the projectile's
	-- flight, so their intercept position is a parabola, not a straight line.
	-- Flight time depends on that position and vice-versa, so iterate: solve a
	-- linear-motion intercept, then re-aim at where gravity will have carried
	-- the target by that time, and re-solve. Converges in a couple of passes.
	local effectiveTargetPos = targetPos
	local effectiveTargetVel = targetVelocity
	local applyGravity = (not grounded) and playerGravity and playerGravity > 0 and math.abs(targetVelocity.Y) > 0.01

	local t = solveInterceptTime(origin, projectileSpeed, gravity, effectiveTargetPos, effectiveTargetVel)

	if applyGravity and t then
		-- Five rather than three: each pass is one quartic solve, and a target falling
		-- fast moves far enough between passes that three did not always settle.
		for _ = 1, 5 do
			-- predicted target position at flight time t, including their fall
			local fallY = targetVelocity.Y * t - 0.5 * playerGravity * t * t
			local predicted = targetPos + Vector3.new(targetVelocity.X * t, fallY, targetVelocity.Z * t)

			--[[
				Stopped at the floor they are heading for.

				Which is not the floor they left: someone falling off a bridge is moving
				sideways as well as down, and the ground under where they land can be a
				different height entirely - a lower island, or the map below the gap. So
				the floor is looked up under the predicted position rather than under the
				position they started from.
			]]
			local floor = floorUnder(Vector3.new(predicted.X, targetPos.Y, predicted.Z))
			if floor and predicted.Y < floor then
				predicted = Vector3.new(predicted.X, floor, predicted.Z)
			end

			-- the velocity the solver should assume to reach `predicted` in t,
			-- so the quartic lead and the gravity-curved point stay consistent
			effectiveTargetPos = targetPos
			effectiveTargetVel = (predicted - targetPos) / t
			local newT = solveInterceptTime(origin, projectileSpeed, gravity, effectiveTargetPos, effectiveTargetVel)
			if not newT then break end
			if math.abs(newT - t) < 1e-3 then t = newT break end
			t = newT
		end

		--[[
			The lead and the flight time have to belong to each other.

			effectiveTargetVel is worked out to reach the predicted point in the t of that
			pass, and then t is replaced by the solve that follows it. Aiming with the two
			mismatched puts the shot at targetPos + vel * newT rather than at the point the
			velocity was derived for, which scales the whole lead by newT/oldT.

			That is harmless when the lead is small and badly wrong when it is not: someone
			rising out of a jump carries most of their lead vertically, so the error lands
			the shot well over their head, which is exactly where it was going.
		]]
		if t then
			local fallY = targetVelocity.Y * t - 0.5 * playerGravity * t * t
			local settled = targetPos + Vector3.new(targetVelocity.X * t, fallY, targetVelocity.Z * t)
			local floor = floorUnder(Vector3.new(settled.X, targetPos.Y, settled.Z))
			if floor and settled.Y < floor then
				settled = Vector3.new(settled.X, floor, settled.Z)
			end
			effectiveTargetPos = targetPos
			effectiveTargetVel = (settled - targetPos) / t
		end
	end

	if t then
		local disp = effectiveTargetPos - origin
		local p, q, r = effectiveTargetVel.X, effectiveTargetVel.Y, effectiveTargetVel.Z
		local h, j, k = disp.X, disp.Y, disp.Z
		local l = -0.5 * gravity
		local d = (h + p * t) / t
		local e = (j + q * t - l * t * t) / t
		local f2 = (k + r * t) / t
		local aimDir = Vector3.new(d, e, f2).Unit
		return origin + Vector3.new(d, e, f2), aimDir, t
	elseif gravity == 0 then
		-- straight-line fallback for non-ballistic projectiles
		local disp = targetPos - origin
		local p, q, r = targetVelocity.X, targetVelocity.Y, targetVelocity.Z
		local h, j, k = disp.X, disp.Y, disp.Z
		local ft = disp.Magnitude / projectileSpeed
		local d = (h + p * ft) / ft
		local e = (j + q * ft) / ft
		local f = (k + r * ft) / ft
		return origin + Vector3.new(d, e, f)
	end
end

return module
