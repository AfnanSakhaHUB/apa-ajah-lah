--[[ DITO TORNADO AI  |  LocalScript -> StarterPlayer > StarterPlayerScripts
  - Scan semua part berna­ma "road" (Road/Roads/RoadsNewJersey...) -> titik jalan transparan (folder Workspace.DitoNodes)
  - Prediksi kecepatan + arah tornado (regresi 4s / 12s / 30s), pilih arah paling efisien
  - Rumus intersep: jarak_tornado_ke_titik = kecepatan_tornado * (waktu_mobil_tiba + 2 menit), lalu DIKUNCI
  - Dito AI Service  : intersep tornado (gas sampai batas mobil, belokan dihaluskan)
  - Dito Run Tornado : peringatan -> masuk mobil -> kabur 100 mph ke titik aman (dikunci)
  - Toggle OFF -> auto rem sampai berhenti
  - TREK (garis cyan neon) = rute paling efisien di atas jalan; mobil mengikuti trek ini
  - Kecepatan maks AI diatur lewat kotak "Max speed" di UI (atau C.MaxMph)
]]
local Players, RunService, CAS = game:GetService("Players"), game:GetService("RunService"), game:GetService("ContextActionService")
local lp = Players.LocalPlayer
local pgui = lp:WaitForChild("PlayerGui")

local C = {
	MPH = 1.5966,          -- 1 mph = 1.5966 stud/s (1 stud = 0.28 m). Sesuaikan jika game kamu beda skala
	LeadSec = 60,         -- mobil harus tiba 2 menit sebelum tornado
	NodeSpacing = 14, LinkDist = 26, MinRoadLen = 6,
	MaxNodeParts = 15000,  -- batas part titik jalan
	DebugNodes = false,    -- true = titik jalan terlihat
	MaxMph = 120,          -- kecepatan maks AI (bisa diubah lewat kotak "Max speed" di UI)
	ShowTrack = true,      -- gambar trek (garis cyan) di atas jalan
	AccelG = 0.25, BrakeG = 0.6, LatG = 0.7, Grip = 6, SteerSmooth = 4,
	FleeMph = 100, WarnDist = 1200, DangerDist = 500, DangerR = 260,
	MaxSearch = 8000, MaxEscape = 4500, MaxLateral = 250, MinTornSpeed = 2,
	BlockInput = true,     -- blok WASD saat AI menyetir
	FlipForward = false,   -- true jika depan mobil terbalik (kursi menghadap belakang)
}

---------------------------------------------------------------- util
local function flat(v) return Vector3.new(v.X, 0, v.Z) end
local function key(cx, cz) return cx * 100003 + cz end
local function hasRoad(n) return string.find(string.lower(n), "road", 1, true) ~= nil end
local function mk(cls, props, parent)
	local o = Instance.new(cls)
	for k, v in pairs(props) do o[k] = v end
	o.Parent = parent
	return o
end
local function mmss(s) local i = math.floor(math.max(0, s)); return string.format("%d:%02d", i // 60, i % 60) end
local DIRS = {"Utara", "Timur Laut", "Timur", "Tenggara", "Selatan", "Barat Daya", "Barat", "Barat Laut"}
local function headingOf(vx, vz)
	local b = (math.deg(math.atan2(vx, -vz)) + 360) % 360
	return b, DIRS[(math.floor((b + 22.5) / 45) % 8) + 1]
end

for _, n in ipairs({"DitoNodes", "DitoMarkers"}) do local o = workspace:FindFirstChild(n); if o then o:Destroy() end end
local nodesFolder = mk("Folder", {Name = "DitoNodes"}, workspace)
local markFolder = mk("Folder", {Name = "DitoMarkers"}, workspace)

---------------------------------------------------------------- state
local NP, ADJ, GRID = {}, {}, {}
local ready, dirty, building, lastBuild = false, false, false, 0
local services = {ai = false, run = false}
local intercept, escape, esc, intStatus = nil, nil, {state = "idle"}, nil
local torn, tornPos, lastFind, hist = nil, nil, 0, {}
local SI = setmetatable({}, {__mode = "k"})   -- info per kursi
local D = {mode = "off", omega = 0, planAt = 0, speed = 0}
local busy, relockAt = {i = false, e = false, p = false}, 0

local function seatNow() local h = lp.Character and lp.Character:FindFirstChildOfClass("Humanoid"); return h and h.SeatPart end
local function charPos() local r = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart"); return r and r.Position end
local function getStartPos() local s = seatNow(); return s and s.Position or charPos() end
local function estTop()
	local s = seatNow(); local i = s and SI[s]; local u = C.MaxMph * C.MPH
	return (i and i.peak > 25) and math.min(u, i.peak) or u
end

---------------------------------------------------------------- road graph
local function isRoadPart(p)
	if not p:IsA("BasePart") or p:IsDescendantOf(nodesFolder) or p:IsDescendantOf(markFolder) then return false end
	if p.Parent and p.Parent:FindFirstChildOfClass("Humanoid") then return false end
	local a = p
	while a and a ~= workspace do
		if hasRoad(a.Name) then return true end
		a = a.Parent
	end
	return false
end

local function buildGraph()
	if building then return end
	building, dirty = true, false
	local parts, all = {}, workspace:GetDescendants()
	for i, d in ipairs(all) do
		if isRoadPart(d) then parts[#parts + 1] = d end
		if i % 4000 == 0 then task.wait() end
	end
	local np, adj, own = {}, {}, {}
	for pi, p in ipairs(parts) do
		local cf, sz = p.CFrame, p.Size
		local axes, dims = {cf.RightVector, cf.UpVector, cf.LookVector}, {sz.X, sz.Y, sz.Z}
		local ti = 1
		for k = 2, 3 do if dims[k] < dims[ti] then ti = k end end
		local up = axes[ti]
		if up.Y < 0 then up = -up end
		if math.abs(up.Y) > 0.5 then
			local li
			for k = 1, 3 do if k ~= ti and (not li or dims[k] > dims[li]) then li = k end end
			local L = dims[li]
			if L >= C.MinRoadLen then
				local center = cf.Position + up * (dims[ti] / 2 + 0.3)
				local n, prevI = math.max(1, math.ceil(L / C.NodeSpacing)), nil
				for k = 0, n do
					local idx = #np + 1
					np[idx], adj[idx], own[idx] = center + axes[li] * (-L / 2 + L * k / n), {}, pi
					if prevI then table.insert(adj[idx], prevI); table.insert(adj[prevI], idx) end
					prevI = idx
				end
			end
		end
		if pi % 200 == 0 then task.wait() end
	end
	local g = {}
	for i, pos in ipairs(np) do
		local k = key(math.floor(pos.X / 32), math.floor(pos.Z / 32))
		g[k] = g[k] or {}
		table.insert(g[k], i)
	end
	for i, pos in ipairs(np) do
		local cx, cz = math.floor(pos.X / 32), math.floor(pos.Z / 32)
		for dx = -1, 1 do for dz = -1, 1 do
			local c = g[key(cx + dx, cz + dz)]
			if c then for _, j in ipairs(c) do
				if j > i and own[j] ~= own[i] and math.abs(np[j].Y - pos.Y) < 12 and (np[j] - pos).Magnitude <= C.LinkDist then
					table.insert(adj[i], j); table.insert(adj[j], i)
				end
			end end
		end end
		if i % 3000 == 0 then task.wait() end
	end
	NP, ADJ, GRID = np, adj, g
	ready, lastBuild, building = true, os.clock(), false
	nodesFolder:ClearAllChildren()
	local step = math.max(1, math.ceil(#np / C.MaxNodeParts))
	for i = 1, #np, step do
		mk("Part", {Name = "DitoNode", Size = Vector3.one, Anchored = true, CanCollide = false, CanTouch = false, CanQuery = false,
			CastShadow = false, Material = Enum.Material.Neon, Color = Color3.fromRGB(0, 255, 140),
			Transparency = C.DebugNodes and 0.4 or 1, Position = np[i]}, nodesFolder)
		if i % (250 * step) == 0 then task.wait() end
	end
end
workspace.DescendantAdded:Connect(function(d) if d:IsA("BasePart") and isRoadPart(d) then dirty = true end end)

local function nearestNode(pos, maxR)
	local cx, cz, best, bd = math.floor(pos.X / 32), math.floor(pos.Z / 32), nil, math.huge
	for r = 0, math.ceil(maxR / 32) do
		for dx = -r, r do for dz = -r, r do
			if math.max(math.abs(dx), math.abs(dz)) == r then
				local c = GRID[key(cx + dx, cz + dz)]
				if c then for _, i in ipairs(c) do
					local d = (NP[i] - pos).Magnitude
					if d < bd then bd, best = d, i end
				end end
			end
		end end
		if best and bd <= r * 32 then break end
	end
	if best and bd <= maxR then return best, bd end
end

---------------------------------------------------------------- pathfinding (A* / Dijkstra)
local Heap = {}
Heap.__index = Heap
function Heap.new() return setmetatable({n = 0, v = {}, p = {}}, Heap) end
function Heap:push(val, pri)
	local n = self.n + 1; self.n = n
	local v, p, i = self.v, self.p, n
	while i > 1 do
		local par = i // 2
		if p[par] <= pri then break end
		v[i], p[i] = v[par], p[par]; i = par
	end
	v[i], p[i] = val, pri
end
function Heap:pop()
	local n = self.n
	if n == 0 then return nil end
	local v, p = self.v, self.p
	local top, lv, lp_ = v[1], v[n], p[n]
	v[n], p[n] = nil, nil
	n -= 1; self.n = n
	if n > 0 then
		local i = 1
		while true do
			local c = i * 2
			if c > n then break end
			if c < n and p[c + 1] < p[c] then c += 1 end
			if p[c] >= lp_ then break end
			v[i], p[i] = v[c], p[c]; i = c
		end
		v[i], p[i] = lv, lp_
	end
	return top
end

-- goal=nil -> flood (Dijkstra). blocked(i, jarakJalan) -> true = node dilarang
local function search(s, goal, maxCost, blocked)
	local np, adj = NP, ADJ
	local dist, prev, closed, heap = {[s] = 0}, {}, {}, Heap.new()
	local gp = goal and np[goal]
	heap:push(s, gp and (np[s] - gp).Magnitude or 0)
	local cnt = 0
	while true do
		local u = heap:pop()
		if not u then break end
		if not closed[u] then
			closed[u] = true
			if u == goal then break end
			cnt += 1
			if cnt % 2500 == 0 then task.wait() end
			local du, pu = dist[u], np[u]
			for _, v in ipairs(adj[u]) do
				if not closed[v] then
					local nd = du + (np[v] - pu).Magnitude
					if nd < (dist[v] or math.huge) and nd <= maxCost and not (blocked and blocked(v, nd)) then
						dist[v], prev[v] = nd, u
						heap:push(v, nd + (gp and (np[v] - gp).Magnitude or 0))
					end
				end
			end
		end
	end
	return dist, prev, np
end

local function smoothPath(pts)
	for _ = 1, 3 do   -- Chaikin: belokan dihaluskan
		if #pts < 3 then break end
		local o = {pts[1]}
		for i = 1, #pts - 1 do
			o[#o + 1] = pts[i]:Lerp(pts[i + 1], 0.25)
			o[#o + 1] = pts[i]:Lerp(pts[i + 1], 0.75)
		end
		o[#o + 1] = pts[#pts]; pts = o
	end
	local res, need = {pts[1]}, 8
	for i = 1, #pts - 1 do
		local a, b = pts[i], pts[i + 1]
		local seg, pos = (b - a).Magnitude, 0
		while seg > 0 and seg - pos >= need do pos += need; res[#res + 1] = a:Lerp(b, pos / seg); need = 8 end
		need -= (seg - pos)
	end
	if (res[#res] - pts[#pts]).Magnitude > 1 then res[#res + 1] = pts[#pts] end
	return res
end

-- profil kecepatan: batas belokan (gaya lateral) + pengereman mundur dari ujung rute
local function buildProfile(pts)
	local n, g = #pts, workspace.Gravity
	local aLat, aBr = C.LatG * g, C.BrakeG * g * 0.8
	local cum, v = {0}, {}
	for i = 2, n do cum[i] = cum[i - 1] + (pts[i] - pts[i - 1]).Magnitude end
	for i = 1, n do
		local k = 0
		if i > 1 and i < n then
			local a, b = flat(pts[i] - pts[i - 1]), flat(pts[i + 1] - pts[i])
			if a.Magnitude > 0.01 and b.Magnitude > 0.01 then
				k = math.acos(math.clamp(a.Unit:Dot(b.Unit), -1, 1)) / ((a.Magnitude + b.Magnitude) / 2)
			end
		end
		v[i] = k > 1e-4 and math.sqrt(aLat / k) or 1000
	end
	v[n] = 0
	for i = n - 1, 1, -1 do v[i] = math.min(v[i], math.sqrt(v[i + 1] ^ 2 + 2 * aBr * (cum[i + 1] - cum[i]))) end
	return cum, v
end

---------------------------------------------------------------- tornado tracking
local function findTornado()
	for _, d in ipairs(workspace:GetDescendants()) do
		if string.lower(d.Name) == "tornado" and (d:IsA("Model") or d:IsA("BasePart") or d:IsA("Folder")) then torn = d; return end
	end
end
local function posOf(i)
	if i:IsA("BasePart") then return i.Position end
	if i:IsA("Model") then
		if i.PrimaryPart then return i.PrimaryPart.Position end
		return (i:GetBoundingBox()).Position
	end
	local n, s = 0, Vector3.zero
	for _, d in ipairs(i:GetDescendants()) do
		if d:IsA("BasePart") then n += 1; s += d.Position; if n >= 60 then break end end
	end
	if n > 0 then return s / n end
end
local function updateTornado()
	if torn and not torn.Parent then torn = nil end
	if not torn and os.clock() - lastFind > 3 then lastFind = os.clock(); findTornado() end
	local p = torn and posOf(torn)
	tornPos = p
	if p then
		local l = hist[#hist]
		if l and math.sqrt((l.x - p.X) ^ 2 + (l.z - p.Z) ^ 2) > 400 then hist = {} end
		hist[#hist + 1] = {t = os.clock(), x = p.X, z = p.Z}
		while hist[1] and os.clock() - hist[1].t > 35 do table.remove(hist, 1) end
	end
end
-- regresi linear posisi vs waktu dalam jendela w detik -> vx, vz (stud/s)
local function velWindow(w)
	local now, n, st, sx, sz, stt, stx, stz = os.clock(), 0, 0, 0, 0, 0, 0, 0
	for i = #hist, 1, -1 do
		local h = hist[i]; local t = h.t - now
		if t < -w then break end
		n += 1; st += t; sx += h.x; sz += h.z; stt += t * t; stx += t * h.x; stz += t * h.z
	end
	if n < 6 then return nil end
	local den = n * stt - st * st
	if den < 1e-6 then return nil end
	return (n * stx - st * sx) / den, (n * stz - st * sz) / den
end
-- kandidat arah gerak tornado (jangka pendek, menengah, panjang, rata-rata)
local function candidates()
	local out, sx, sz, n = {}, 0, 0, 0
	for _, w in ipairs({4, 12, 30}) do
		local vx, vz = velWindow(w)
		if vx then
			local sp = math.sqrt(vx * vx + vz * vz)
			if sp >= C.MinTornSpeed then
				out[#out + 1] = {vx = vx, vz = vz, v = sp, dx = vx / sp, dz = vz / sp}
				sx += vx; sz += vz; n += 1
			end
		end
	end
	if n > 1 then
		local sp = math.sqrt(sx * sx + sz * sz) / n
		if sp >= C.MinTornSpeed then
			local l = math.sqrt(sx * sx + sz * sz)
			out[#out + 1] = {vx = sx / n, vz = sz / n, v = sp, dx = sx / l, dz = sz / l}
		end
	end
	return out
end

local function makeBlocker(vf)
	if not tornPos then return nil end
	local vx, vz = velWindow(12); vx, vz = vx or 0, vz or 0
	local T0 = tornPos
	return function(i, d)
		local t, p = d / vf, NP[i]
		local dx, dz = p.X - (T0.X + vx * t), p.Z - (T0.Z + vz * t)
		return dx * dx + dz * dz < C.DangerR ^ 2
	end
end

---------------------------------------------------------------- lokasi intersep (dikunci)
local function computeIntercept()
	if busy.i or not ready or not tornPos then return end
	busy.i = true
	local ok, err = pcall(function()
		local cs = candidates()
		if #cs == 0 then intStatus = "Menunggu tornado bergerak / mengukur kecepatan..."; return end
		local start = getStartPos()
		local s = start and nearestNode(start, 500)
		if not s then intStatus = "Tidak ada jalan di dekat kamu"; return end
		local dist, _, np = search(s, nil, C.MaxSearch)
		local vAvg, T0, best = 0.6 * estTop(), tornPos, nil
		for i, d in pairs(dist) do
			local p = np[i]
			local rx, rz = p.X - T0.X, p.Z - T0.Z
			local tc = d / vAvg                                  -- waktu mobil tiba
			for _, c in ipairs(cs) do
				local along = rx * c.dx + rz * c.dz              -- jarak di trek tornado
				if along > c.v * C.LeadSec * 0.7 then
					local lat = math.abs(rx * c.dz - rz * c.dx)  -- jarak titik jalan ke trek
					if lat <= C.MaxLateral then
						-- rumus: jarak = kecepatan_tornado * (waktu_mobil + 2 menit)
						local cost = math.abs(along - c.v * (tc + C.LeadSec)) + 2.5 * lat
						if not best or cost < best.cost then best = {cost = cost, i = i, c = c, d = d, lat = lat} end
					end
				end
			end
		end
		if best then
			intercept = {pos = np[best.i], dx = best.c.dx, dz = best.c.dz, v = best.c.v, eta = best.d / vAvg, dist = best.d, lat = best.lat}
			intStatus = nil
		else intStatus = "Tidak ada jalan yang pas di trek tornado" end
	end)
	if not ok then warn("[Dito] intercept:", err) end
	busy.i = false
end

local function computeEscape()
	if busy.e or not ready or not tornPos then return end
	busy.e = true
	local ok, err = pcall(function()
		local start = getStartPos()
		local s = start and nearestNode(start, 500)
		if not s then return end
		local vf, T0 = C.FleeMph * C.MPH, tornPos
		local dist, _, np = search(s, nil, C.MaxEscape, makeBlocker(vf))
		local vx, vz = velWindow(12); vx, vz = vx or 0, vz or 0
		local sp = math.sqrt(vx * vx + vz * vz)
		local moving = sp > C.MinTornSpeed
		local dx, dz = moving and vx / sp or 0, moving and vz / sp or 0
		local bestI, bestS
		for pass = 1, 2 do
			for i, d in pairs(dist) do
				if d >= (pass == 1 and 500 or 100) then
					local p, t = np[i], d / vf + 20
					local sc = math.sqrt((p.X - (T0.X + vx * t)) ^ 2 + (p.Z - (T0.Z + vz * t)) ^ 2)
					local rx, rz = p.X - T0.X, p.Z - T0.Z
					local lat = (moving and rx * dx + rz * dz > 0) and math.abs(rx * dz - rz * dx) or math.sqrt(rx * rx + rz * rz)
					sc = math.min(sc, lat, 1800) - 0.08 * d
					if not bestS or sc > bestS then bestI, bestS = i, sc end
				end
			end
			if bestI then break end
		end
		if bestI then escape = {pos = np[bestI], flee = true} end
	end)
	if not ok then warn("[Dito] escape:", err) end
	busy.e = false
end

---------------------------------------------------------------- rute
-- gambar trek: garis neon cyan di atas jalan mengikuti rute yang sudah dihaluskan
local trackParts = {}
local function drawTrack(pts)
	local n = pts and #pts or 0
	local stride, k = math.max(1, math.ceil(n / 500)), 0
	if C.ShowTrack and n > 1 then
		for i = 1, n - 1, stride do
			k += 1
			local a = pts[i] + Vector3.new(0, 0.5, 0)
			local b = pts[math.min(n, i + stride)] + Vector3.new(0, 0.5, 0)
			local p = trackParts[k]
			if not p then
				p = mk("Part", {Name = "DitoTrackSeg", Anchored = true, CanCollide = false, CanQuery = false, CanTouch = false,
					CastShadow = false, Material = Enum.Material.Neon, Color = Color3.fromRGB(0, 200, 255), Transparency = 0.25}, markFolder)
				trackParts[k] = p
			end
			p.Size = Vector3.new(2.5, 0.3, math.max(0.5, (b - a).Magnitude))
			p.CFrame = CFrame.lookAt((a + b) / 2, b)
		end
	end
	for i = #trackParts, k + 1, -1 do trackParts[i]:Destroy(); trackParts[i] = nil end
end

local function replan(lock)
	if busy.p or not ready then return end
	busy.p = true
	D.planAt = os.clock()
	local ok, err = pcall(function()
		local seat = seatNow()
		local p0 = seat and seat.Position or charPos()
		if not p0 then return end
		local s, g = nearestNode(p0, 500), nearestNode(lock.pos, 120)
		if not (s and g) then D.pts, D.lock = nil, lock; return end
		local blk = lock.flee and makeBlocker(C.FleeMph * C.MPH) or nil
		local _, prev, np = search(s, g, C.MaxSearch * 1.5, blk)
		if s ~= g and not prev[g] then _, prev, np = search(s, g, C.MaxSearch * 1.5) end
		if s ~= g and not prev[g] then D.pts, D.lock = nil, lock; return end
		local raw, u = {}, g
		while u do raw[#raw + 1] = np[u]; u = prev[u] end
		for i = 1, #raw // 2 do raw[i], raw[#raw + 1 - i] = raw[#raw + 1 - i], raw[i] end
		seat = seatNow()
		local ref = seat or (lp.Character and lp.Character:FindFirstChild("HumanoidRootPart"))
		if not ref then return end
		local pos, look = ref.Position, ref.CFrame.LookVector
		local fwd = flat(C.FlipForward and -look or look)
		while #raw > 2 and (raw[1] - pos):Dot(fwd) < 0 and (raw[1] - pos).Magnitude < 45 do table.remove(raw, 1) end
		table.insert(raw, 1, pos)
		local pts = smoothPath(raw)
		local cum, vp = buildProfile(pts)
		D.pts, D.cum, D.vp, D.idx, D.lock, D.arrived, D.dev = pts, cum, vp, 1, lock, false, 0
		D.vCap = lock.flee and C.FleeMph * C.MPH or nil
		D.preview = not seat
		drawTrack(pts)
		D.planAt = os.clock()
	end)
	if not ok then warn("[Dito] replan:", err) end
	busy.p = false
end

---------------------------------------------------------------- driver (tiap frame)
local blocking = false
local function setBlock(on)
	if on == blocking or not C.BlockInput then return end
	blocking = on
	if on then
		CAS:BindActionAtPriority("DitoBlock", function() return Enum.ContextActionResult.Sink end, false, 3000,
			Enum.KeyCode.W, Enum.KeyCode.A, Enum.KeyCode.S, Enum.KeyCode.D,
			Enum.KeyCode.Up, Enum.KeyCode.Down, Enum.KeyCode.Left, Enum.KeyCode.Right)
	else CAS:UnbindAction("DitoBlock") end
end

local function step(dt)
	local seat = seatNow()
	if not seat then
		if D.mode ~= "off" then D.mode = "off" end
		setBlock(false); return
	end
	local root = seat.AssemblyRootPart or seat
	local look = seat.CFrame.LookVector
	local fwd = flat(C.FlipForward and -look or look)
	if fwd.Magnitude < 0.05 then return end
	fwd = fwd.Unit
	local right = fwd:Cross(Vector3.yAxis)
	local vel = root.AssemblyLinearVelocity
	local fv = flat(vel)
	local speed = fv.Magnitude
	local info = SI[seat]
	if not info then info = {peak = 0}; SI[seat] = info end
	if math.abs(vel.Y) < 25 and speed > info.peak then info.peak = speed end
	D.speed = speed
	local mode = D.mode
	if mode == "off" or (mode == "path" and not D.pts) then setBlock(false); return end
	setBlock(true)

	local g, mass = workspace.Gravity, root.AssemblyMass
	local aBr, aLat = C.BrakeG * g, C.LatG * g
	local lim = aLat / math.max(speed, 8)
	local pos = seat.Position
	local vDes, omT = 0, 0
	local cap = math.min(C.MaxMph * C.MPH, D.vCap or math.huge)   -- batas kecepatan yang kamu atur
	if mode == "path" then
		local pts, n = D.pts, #D.pts
		local best, bd = D.idx, math.huge
		for i = D.idx, math.min(n, D.idx + 25) do
			local d = flat(pts[i] - pos).Magnitude
			if d < bd then bd, best = d, i end
		end
		D.idx, D.dev = best, bd
		local Ld, j = math.clamp(8 + speed * 0.55, 14, 90), best
		while j < n and flat(pts[j] - pos).Magnitude < Ld do j += 1 end
		local to, alpha = flat(pts[j] - pos), 0
		if to.Magnitude > 0.5 then
			local tu = to.Unit
			alpha = math.atan2(fwd:Cross(tu).Y, fwd:Dot(tu))                      -- + = target di kiri
			local kappa = 2 * math.sin(alpha) / math.max(to.Magnitude, 6)       -- pure pursuit
			omT = math.max(speed, 8) * kappa * math.clamp(speed / 3, 0.35, 1)
		end
		omT = math.clamp(omT, -lim, lim)
		vDes = math.min(D.vp[math.min(best + 1, n)], cap) * (1 - 0.6 * math.clamp(math.abs(alpha) / 1.2, 0, 1))
		if D.cum[n] - D.cum[best] > 20 then vDes = math.max(vDes, 6) end
		if flat(pts[n] - pos).Magnitude < 16 then D.mode, D.arrived = "hold", true end
	end

	-- deteksi apakah mobil merespon throttle bawaan (VehicleSeat)
	if info.native == nil then
		if not seat:IsA("VehicleSeat") then info.native = false
		elseif mode == "path" and vDes > speed + 5 then
			info.t0, info.s0 = info.t0 or os.clock(), info.s0 or speed
			if os.clock() - info.t0 > 1.4 then info.native = (speed - info.s0) > 4; info.t0, info.s0 = nil, nil end
		else info.t0, info.s0 = nil, nil end
	end

	local err = vDes - speed
	local aAvail = C.AccelG * g * math.max(0, 1 - (speed / cap) ^ 2)   -- tenaga turun mendekati kecepatan maks
	local aDes = math.clamp(err * 2, -aBr, aAvail)
	if mode ~= "path" then aDes = speed > 0.8 and -aBr or 0; omT = 0 end

	D.omega += (omT - D.omega) * math.min(1, dt * C.SteerSmooth)     -- belokan dihaluskan
	if seat:IsA("VehicleSeat") then
		pcall(function()
			seat.ThrottleFloat = (D.mode == "path") and math.clamp(err / 10, 0, 1) or 0
			seat.SteerFloat = math.clamp(-D.omega / lim, -1, 1)
		end)
	end

	local imp = Vector3.zero
	if aDes > 0 then
		if info.native == false then imp += fwd * aDes * mass * dt end
	elseif aDes < 0 and speed > 0.4 then
		imp -= fv.Unit * math.min(-aDes, speed * 0.9 / dt) * mass * dt
	end
	imp -= right * vel:Dot(right) * mass * math.clamp(dt * C.Grip, 0, 1)   -- grip ban
	root:ApplyImpulse(imp)
	local av = root.AssemblyAngularVelocity
	root.AssemblyAngularVelocity = Vector3.new(av.X, D.omega, av.Z)

	if (D.mode == "hold" or D.mode == "stop") and speed < 1.2 then
		root.AssemblyLinearVelocity = Vector3.new(0, vel.Y, 0)
		if D.mode == "stop" then D.mode = "off" end
	end
end
RunService:BindToRenderStep("DitoDrive", Enum.RenderPriority.Input.Value + 1, step)

---------------------------------------------------------------- UI
local gui = mk("ScreenGui", {Name = "DitoTornadoUI", ResetOnSpawn = false, DisplayOrder = 50}, pgui)
local frame = mk("Frame", {Size = UDim2.fromOffset(270, 350), Position = UDim2.fromOffset(10, 70), BackgroundColor3 = Color3.fromRGB(18, 20, 26),
	BackgroundTransparency = 0.1, BorderSizePixel = 0, Active = true, Draggable = true}, gui)
mk("UICorner", {CornerRadius = UDim.new(0, 10)}, frame)
mk("TextLabel", {Size = UDim2.new(1, 0, 0, 26), BackgroundTransparency = 1, Text = "DITO TORNADO AI", TextColor3 = Color3.fromRGB(255, 170, 60),
	Font = Enum.Font.GothamBold, TextSize = 15}, frame)
local info = mk("TextLabel", {Position = UDim2.fromOffset(10, 28), Size = UDim2.new(1, -20, 0, 160), BackgroundTransparency = 1,
	TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top, TextWrapped = true, RichText = true,
	Font = Enum.Font.Gotham, TextSize = 12, TextColor3 = Color3.new(1, 1, 1), Text = ""}, frame)
local function btn(y)
	local b = mk("TextButton", {Position = UDim2.fromOffset(10, y), Size = UDim2.new(1, -20, 0, 32), Font = Enum.Font.GothamBold, TextSize = 13,
		TextColor3 = Color3.new(1, 1, 1), BackgroundColor3 = Color3.fromRGB(60, 64, 76), BorderSizePixel = 0}, frame)
	mk("UICorner", {CornerRadius = UDim.new(0, 8)}, b)
	return b
end
local bAI, bRun, bLoc = btn(194), btn(230), btn(266)
bLoc.Text = "Ubah Lokasi"
mk("TextLabel", {Position = UDim2.fromOffset(10, 306), Size = UDim2.fromOffset(140, 30), BackgroundTransparency = 1, Text = "Max speed AI (mph):",
	TextXAlignment = Enum.TextXAlignment.Left, Font = Enum.Font.Gotham, TextSize = 12, TextColor3 = Color3.new(1, 1, 1)}, frame)
local boxMax = mk("TextBox", {Position = UDim2.fromOffset(160, 306), Size = UDim2.fromOffset(100, 30), Text = tostring(C.MaxMph),
	Font = Enum.Font.GothamBold, TextSize = 14, TextColor3 = Color3.new(1, 1, 1), BackgroundColor3 = Color3.fromRGB(40, 44, 56),
	BorderSizePixel = 0, ClearTextOnFocus = false}, frame)
mk("UICorner", {CornerRadius = UDim.new(0, 8)}, boxMax)
boxMax.FocusLost:Connect(function()
	local v = tonumber(boxMax.Text)
	if v then C.MaxMph = math.clamp(v, 10, 300) end   -- berlaku langsung, tanpa hitung ulang rute
	boxMax.Text = tostring(C.MaxMph)
end)
local banner = mk("TextLabel", {AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 8), Size = UDim2.fromOffset(440, 48),
	BackgroundColor3 = Color3.fromRGB(200, 20, 20), Text = "⚠ TORNADO DEKAT! MASUK KE MOBIL SEKARANG!", TextColor3 = Color3.new(1, 1, 1),
	Font = Enum.Font.GothamBlack, TextSize = 18, TextWrapped = true, Visible = false, BorderSizePixel = 0}, gui)
mk("UICorner", {CornerRadius = UDim.new(0, 8)}, banner)

local function refreshBtn()
	bAI.Text = "Dito AI Service: " .. (services.ai and "ON" or "OFF")
	bRun.Text = "Dito Run Tornado: " .. (services.run and "ON" or "OFF")
	bAI.BackgroundColor3 = services.ai and Color3.fromRGB(40, 150, 70) or Color3.fromRGB(60, 64, 76)
	bRun.BackgroundColor3 = services.run and Color3.fromRGB(40, 150, 70) or Color3.fromRGB(60, 64, 76)
end
refreshBtn()

local function mkMarker(col, txt)
	local p = mk("Part", {Name = "DitoMarker", Anchored = true, CanCollide = false, CanQuery = false, CanTouch = false, CastShadow = false,
		Material = Enum.Material.Neon, Color = col, Transparency = 0.35, Size = Vector3.new(5, 320, 5)}, nil)
	local bb = mk("BillboardGui", {Size = UDim2.fromOffset(210, 34), StudsOffset = Vector3.new(0, 170, 0), AlwaysOnTop = true, Adornee = p}, p)
	local l = mk("TextLabel", {Size = UDim2.fromScale(1, 1), BackgroundTransparency = 0.3, BackgroundColor3 = Color3.new(0, 0, 0), TextColor3 = col,
		Font = Enum.Font.GothamBold, TextSize = 14, Text = txt}, bb)
	return p, l
end
local mI, lI = mkMarker(Color3.fromRGB(255, 120, 0), "INTERSEP")
local mE, lE = mkMarker(Color3.fromRGB(60, 255, 120), "TITIK AMAN")
local line = mk("Part", {Name = "DitoTrack", Anchored = true, CanCollide = false, CanQuery = false, CanTouch = false, CastShadow = false,
	Material = Enum.Material.Neon, Color = Color3.fromRGB(255, 60, 60), Transparency = 0.4, Size = Vector3.new(1.5, 1.5, 1)}, nil)

---------------------------------------------------------------- kontrol service
local function setService(n, on)
	if on then
		local o = n == "ai" and "run" or "ai"
		if services[o] then services[o] = false end
		services[n] = true
		D.mode, D.pts, D.lock = "off", nil, nil
		if n == "run" then esc.state, escape = "idle", nil end
	else
		services[n] = false
		if n == "run" then esc.state, escape = "idle", nil end
		D.mode = (seatNow() and D.speed > 1.5) and "stop" or "off"   -- OFF => auto rem & berhenti
	end
	refreshBtn()
end
bAI.Activated:Connect(function() setService("ai", not services.ai) end)
bRun.Activated:Connect(function() setService("run", not services.run) end)
bLoc.Activated:Connect(function()
	intercept, escape, relockAt = nil, nil, 0
	intStatus = "Menghitung ulang lokasi..."
	if esc.state == "safe" then esc.state = "flee" end
end)

---------------------------------------------------------------- loop utama (4x per detik)
local function tick()
	if dirty and not building and os.clock() - lastBuild > 8 then task.spawn(buildGraph) end
	updateTornado()
	local seat = seatNow()
	local me = seat and seat.Position or charPos()

	-- lokasi intersep: dikunci sampai tornado melewatinya
	if intercept and tornPos then
		local rel = tornPos - intercept.pos
		if rel.X * intercept.dx + rel.Z * intercept.dz > 25 then
			intercept, relockAt, intStatus = nil, os.clock() + 4, "Tornado sudah lewat. Menghitung lokasi baru..."
		end
	end
	if not intercept and tornPos and ready and os.clock() >= relockAt then task.spawn(computeIntercept) end

	-- Dito Run Tornado: idle -> warning -> flee -> safe
	local tdist = (tornPos and me) and flat(me - tornPos).Magnitude or nil
	if services.run and tdist then
		local st, seated = esc.state, seat ~= nil
		if st == "idle" then
			if tdist <= C.WarnDist then esc.state = seated and "flee" or "warning" end
		elseif st == "warning" then
			if seated then esc.state = "flee" elseif tdist > C.WarnDist * 1.3 then esc.state = "idle"; escape = nil end
		elseif st == "flee" then
			if not seated then esc.state = "warning"
			elseif not escape then task.spawn(computeEscape)
			elseif D.lock == escape and D.arrived then esc.state = "safe" end
		elseif st == "safe" then
			if not seated then esc.state = tdist <= C.WarnDist and "warning" or "idle"; if esc.state == "idle" then escape = nil end
			elseif tdist < C.DangerDist then escape, esc.state = nil, "flee"
			elseif tdist > C.WarnDist * 1.5 then esc.state, escape = "idle", nil end
		end
	end

	-- rute + mode driver
	local cur = (services.ai and intercept) or (services.run and (esc.state == "flee" or esc.state == "safe") and escape) or nil
	if cur and ready and not busy.p then
		local age = os.clock() - D.planAt
		if D.lock ~= cur or (D.preview and seat) or (D.mode == "path" and ((not D.pts and age > 3) or ((D.dev or 0) > 40 and age > 3) or age > 15)) then
			task.spawn(replan, cur)
		end
	end
	if (not cur or not D.pts) and #trackParts > 0 then drawTrack(nil) end
	if services.ai or services.run then
		local want = "off"
		if seat and cur then want = (D.lock == cur and D.arrived) and "hold" or "path" end
		if want == "off" then
			if D.mode == "path" or D.mode == "hold" then D.mode = seat and "stop" or "off" end
		else D.mode = want end
	end

	-- marker
	if intercept then
		mI.Position = intercept.pos + Vector3.new(0, 150, 0); mI.Parent = markFolder
		lI.Text = string.format("INTERSEP • %.0f studs", me and flat(me - intercept.pos).Magnitude or 0)
		if tornPos then
			local a = Vector3.new(tornPos.X, intercept.pos.Y + 3, tornPos.Z)
			local b = intercept.pos + Vector3.new(intercept.dx * 400, 3, intercept.dz * 400)
			line.Size = Vector3.new(1.5, 1.5, math.max(1, (b - a).Magnitude))
			line.CFrame = CFrame.lookAt((a + b) / 2, b); line.Parent = markFolder
		end
	else mI.Parent, line.Parent = nil, nil end
	if escape and services.run then
		mE.Position = escape.pos + Vector3.new(0, 150, 0); mE.Parent = markFolder
		lE.Text = string.format("TITIK AMAN • %.0f studs", me and flat(me - escape.pos).Magnitude or 0)
	else mE.Parent = nil end

	-- UI
	banner.Visible = services.run and esc.state == "warning"
	if banner.Visible then banner.BackgroundColor3 = (math.floor(os.clock() * 4) % 2 == 0) and Color3.fromRGB(200, 20, 20) or Color3.fromRGB(255, 120, 0) end
	local L = {}
	if not ready then L[#L + 1] = "Jalan: memindai..."
	else L[#L + 1] = string.format("Jalan: %d titik", #NP) end
	local vx, vz = velWindow(12)
	if not vx then vx, vz = velWindow(4) end
	if tornPos then
		if vx then
			local sp = math.sqrt(vx * vx + vz * vz)
			local b, name = headingOf(vx, vz)
			L[#L + 1] = string.format("<b>Tornado</b>: %.0f mph (%.0f stud/s)", sp / C.MPH, sp)
			local a1x, a1z = velWindow(4)
			local a2x, a2z = velWindow(30)
			local turn = ""
			if a1x and a2x then
				local ang = math.deg(math.acos(math.clamp((a1x * a2x + a1z * a2z) / (math.sqrt(a1x ^ 2 + a1z ^ 2) * math.sqrt(a2x ^ 2 + a2z ^ 2) + 1e-6), -1, 1)))
				if ang > 20 then turn = string.format(" <font color='#ffaa33'>(berbelok ~%.0f°)</font>", ang) end
			end
			L[#L + 1] = string.format("Arah: %s (%03.0f°)%s", name, b, turn)
		else L[#L + 1] = "Tornado: mengukur kecepatan..." end
		if tdist then L[#L + 1] = string.format("Jarak ke tornado: %.0f studs", tdist) end
	else L[#L + 1] = "<font color='#ff6666'>Tornado tidak ditemukan</font>" end
	if intercept then
		local te = tornPos and ((intercept.pos.X - tornPos.X) * intercept.dx + (intercept.pos.Z - tornPos.Z) * intercept.dz) / intercept.v or 0
		L[#L + 1] = string.format("<b>Intersep</b> (terkunci): mobil %s | tornado tiba %s", mmss(intercept.eta), mmss(te))
	else L[#L + 1] = "Intersep: " .. (intStatus or "menghitung...") end
	if services.run then
		local names = {idle = "aman, memantau", warning = "<font color='#ff4444'>PERINGATAN! masuk mobil</font>", flee = "kabur 100 mph", safe = "sudah di titik aman"}
		L[#L + 1] = "Run Tornado: " .. names[esc.state]
	end
	if D.mode == "path" and not D.pts and (services.ai or services.run) then L[#L + 1] = "<font color='#ffaa33'>Rute jalan belum ketemu...</font>" end
	if D.mode == "stop" then L[#L + 1] = "Mengerem sampai berhenti..." end
	L[#L + 1] = string.format("Mobil: %.0f mph", D.speed / C.MPH)
	info.Text = table.concat(L, "\n")
end

task.spawn(buildGraph)
task.spawn(function()
	while true do
		task.wait(0.25)
		local ok, err = pcall(tick)
		if not ok then warn("[Dito] tick:", err) end
	end
end)
