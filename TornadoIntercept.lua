--[[ DITO TORNADO AI v3  |  LocalScript -> StarterPlayer > StarterPlayerScripts
  Perubahan v3:
  - LEBIH CEPAT     : pemindaian jalan & rute memakai jatah waktu per frame (bukan per N iterasi), siklus utama 10x/detik,
					  kecepatan tornado terukur lebih awal, trek dasar langsung tampil lalu dihaluskan, dan trek tampil
					  sebagai pratinjau begitu titik intersep ada (tanpa menunggu toggle)
  - TREK MENGHINDAR : benda solid setinggi > 5 stud (C.ObstMinH) dihindari lewat LEKUKAN di trek (seluruh rute dipindai di awal);
					  mobil TIDAK direm / dihentikan karena rintangan
  - DEKATI TORNADO  : setelah tiba & berhenti di titik intersep dan masih ada waktu -> trek LURUS ke arah tornado (boleh di luar jalan,
                      melengkung menghindari benda solid); mobil baru berhenti setelah tornado dekat (C.ApproachStop)
  - Trek jalan juga boleh keluar jalan bila lekukan di jalan tidak cukup untuk menghindari benda solid (C.OffRoadAvoid)
  - PANAH PREDIKSI 3D: panah 3D (batang + kepala kerucut) dari tornado searah geraknya sepanjang C.PredLen (10000 stud), arah & kecepatan
                      dari regresi posisi tornado. Titik intersep (pilar oranye) diletakkan TEPAT di panah; penanda jarak + waktu tiba tiap 1000 stud
  Semua nilai bisa diubah di tabel C di bawah, atau lewat panel UI (bagian bawah panel bisa di-scroll).
]]
local Players, RunService, CAS = game:GetService("Players"), game:GetService("RunService"), game:GetService("ContextActionService")
local lp = Players.LocalPlayer
local pgui = lp:WaitForChild("PlayerGui")

local C = {
	MPH = 1.5966,          -- 1 mph = 1.5966 stud/s (1 stud = 0.28 m). Sesuaikan jika game kamu beda skala
	LeadSec = 120,         -- mobil harus tiba 2 menit sebelum tornado
	NodeSpacing = 14, LinkDist = 26, MinRoadLen = 6,
	MaxNodeParts = 15000,  -- batas part titik jalan
	DebugNodes = false,    -- true = titik jalan terlihat
	MaxMph = 120,          -- kecepatan maks AI (bisa diubah lewat kotak "Max speed" di UI)
	ShowTrack = true,      -- gambar trek (garis cyan) di atas jalan
	MaxTrackParts = 900,   -- batas jumlah part garis trek

	-- JALAN BESAR
	BigRoads = true,       -- utamakan jalan terlebar (skala terbesar)
	WidthPenalty = 1.6,    -- makin besar = makin menghindari jalan sempit (biaya rute jalan tersempit = x(1+nilai))
	TargetWidthFrac = 0.6, -- titik intersep hanya di jalan selebar >= 60% lebar referensi (jika ada)
	WidthBonus = 220,      -- bonus skor (setara stud) untuk jalan lebar saat memilih titik
	NoParallelLinks = true,-- jangan sambung titik tengah dua bagian jalan yang sejajar (mencegah zig-zag antar-lajur)

	-- TREK PRESISI
	CenterTrack = true,    -- geser trek ke tengah jalan (diukur dengan raycast kiri-kanan)
	CenterStep = 2, CenterMaxHalf = 44, MaxCenterShift = 24, EdgeHeightTol = 1.0,
	LaneOffset = 0,        -- geser jalur dari tengah (stud). + = kanan arah jalan, - = kiri
	TurnRadius = 30,       -- radius belokan tajam (stud). Makin kecil = belokan makin rapat
	SoftAngle = 12,        -- derajat. Tikungan lebih landai dari ini dihaluskan semaksimal mungkin
	PathStep = 3,          -- jarak antar titik trek (stud)
	SimplifyEps = 0.35,    -- toleransi penyederhanaan garis lurus (stud)

	-- PENGENDALI
	AccelG = 0.25, BrakeG = 0.6, LatG = 0.55,   -- LatG = gaya samping maks di belokan (g)
	StanleyK = 2.5,        -- kekuatan koreksi ke garis trek (makin besar = makin cepat kembali ke trek)
	StanleyV0 = 2, HeadK = 12, SteerSmooth = 40,
	RailGain = 2.5, RailMax = 5, Grip = 30,
	SpeedK = 7, SpeedLead = 0.22,
	ArriveTol = 1.2, EndSpeed = 1.5,

-- RINTANGAN (trek membelok menghindar; mobil TIDAK berhenti)
ObstDetect = true,     -- trek dibuat membelok menghindari benda solid
ObstMinH = 5,          -- hanya benda solid setinggi > 5 stud (dari permukaan jalan) yang dihindari
ObstLook = 12000,      -- seluruh rute dipindai sekaligus saat trek dibuat
ObstClear = 1.2,       -- tinggi dasar kotak pindai dari permukaan jalan (abaikan gundukan rendah)
ObstHeight = 3.2, ObstSide = 1.6, ObstMinSize = 1.2,   -- ObstSide = ruang kosong di kiri/kanan mobil (stud)
ObstOffsets = {3, 5, 7, 9, 12, 15, 19, 24, 30, 38},    -- besar lekukan (stud) yang dicoba, kecil dulu
ObstReroute = 3,       -- maks. ganti jalan bila rintangan tak bisa dihindari di jalurnya
ChordLen = 10, ObstMemory = 25,
BuildBudget = 0.012,   -- jatah detik per frame untuk pemindaian jalan/rute (besar = lebih cepat, FPS turun sesaat)
TickEvery = 0.1,       -- siklus utama (detik)
-- DEKATI TORNADO (setelah tiba di titik intersep & masih ada waktu)
Approach = true,       -- trek lurus ke arah tornado, boleh di luar jalan, melengkung menghindari benda solid
ApproachStop = 350,    -- berhenti saat jarak ke tornado <= nilai ini (stud) = "tornado sudah dekat"
ApproachRoom = 120,    -- fase dekati hanya mulai bila jarak tornado > ApproachStop + nilai ini
ApproachMaxLen = 6000, -- panjang trek maks (stud)
OffRoadAvoid = true,   -- trek jalan boleh keluar jalan untuk menghindar bila lekukan di jalan tak cukup
OffRoadOffsets = {4, 7, 10, 14, 19, 25, 32, 40, 52, 66, 82, 100},   -- besar lekukan di luar jalan (stud)

	FleeMph = 100, WarnDist = 1200, DangerDist = 500, DangerR = 260,
	MaxSearch = 8000, MaxEscape = 4500, MaxLateral = 250, MinTornSpeed = 2,

	-- PANAH PREDIKSI 3D (arah + kecepatan tornado -> panah sepanjang PredLen; titik intersep berada di panah ini)
	Predict = true,        -- tampilkan panah prediksi 3D
	PredLen = 10000,       -- panjang panah (stud)
	PredHeight = 45,       -- tinggi panah dari permukaan jalan intersep (stud)
	PredThick = 8,         -- tebal batang dekat kamera (stud); makin jauh otomatis menebal agar tetap terlihat
	PredScreen = 0.006,    -- tebal batang = jarak kamera x nilai ini (batas atas PredThick x 12)
	PredTick = 1000,       -- jarak antar penanda jarak/waktu di sepanjang panah (stud)
	LatWeight = 5,         -- bobot jarak titik jalan ke sumbu panah saat memilih intersep (besar = makin tepat di panah)
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

local sliceT = os.clock()
local function slice()   -- yield hanya bila jatah waktu frame habis (jauh lebih cepat dari task.wait per N iterasi)
	if os.clock() - sliceT > C.BuildBudget then task.wait(); sliceT = os.clock() end
end
local nodeGen = 0

for _, n in ipairs({"DitoNodes", "DitoMarkers"}) do local o = workspace:FindFirstChild(n); if o then o:Destroy() end end
local oldUI = pgui:FindFirstChild("DitoTornadoUI")
if oldUI then oldUI:Destroy() end
pcall(function() RunService:UnbindFromRenderStep("DitoDrive") end)
pcall(function() CAS:UnbindAction("DitoBlock") end)
local nodesFolder = mk("Folder", {Name = "DitoNodes"}, workspace)
local markFolder = mk("Folder", {Name = "DitoMarkers"}, workspace)

---------------------------------------------------------------- state
local NP, ADJ, GRID, ND, NW, WN = {}, {}, {}, {}, {}, {}   -- posisi, tetangga, grid, arah jalan, lebar, lebar ternormalisasi
local WidthRef, MaxWidth = 1, 0
local CEN, castN = {}, 0                                    -- cache geser-ke-tengah per titik
local BLK = {}                                              -- rintangan yang diingat {pos, r, t}
local ready, dirty, building, lastBuild = false, false, false, 0
local services = {ai = false, run = false}
local intercept, escape, esc, intStatus = nil, nil, {state = "idle"}, nil
local appr = nil   -- fase dekati tornado (trek lurus di luar jalan)
local torn, tornPos, lastFind, hist = nil, nil, 0, {}
local SI = setmetatable({}, {__mode = "k"})   -- info per kursi
local D = {mode = "off", omega = 0, planAt = 0, speed = 0, avoidAt = 0, scanAt = 0, filtAt = 0}
local busy, relockAt = {i = false, e = false, p = false}, 0

local function seatNow() local h = lp.Character and lp.Character:FindFirstChildOfClass("Humanoid"); return h and h.SeatPart end
local function charPos() local r = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart"); return r and r.Position end
local function getStartPos() local s = seatNow(); return s and s.Position or charPos() end
local function estTop()
	local s = seatNow(); local i = s and SI[s]; local u = C.MaxMph * C.MPH
	return (i and i.peak > 25) and math.min(u, i.peak) or u
end

---------------------------------------------------------------- ukuran mobil + filter raycast
local rp = RaycastParams.new()
rp.FilterType = Enum.RaycastFilterType.Exclude
rp.IgnoreWater = true

local function updateFilter(seat)
	local list = {nodesFolder, markFolder}
	if lp.Character then list[#list + 1] = lp.Character end
	if seat then
		list[#list + 1] = seat
		local ok, parts = pcall(function() return seat:GetConnectedParts(true) end)
		if ok then for _, p in ipairs(parts) do list[#list + 1] = p end end
	end
	rp.FilterDescendantsInstances = list
end

-- ukur kotak pembatas mobil di ruang lokal kursi (lebar, panjang, pusat)
local function measureCar(seat, info)
	local cf = seat.CFrame
	local lo, hi = Vector3.new(1e9, 1e9, 1e9), Vector3.new(-1e9, -1e9, -1e9)
	local any = false
	local ok, parts = pcall(function() return seat:GetConnectedParts(true) end)
	if not ok or #parts == 0 then parts = {seat} end
	for pass = 1, 2 do
		for _, p in ipairs(parts) do
			if p:IsA("BasePart") and (pass == 2 or p.CanCollide) and p.Size.Magnitude < 80 then
				local c = cf:PointToObjectSpace(p.Position)
				local _, _, _, r00, r01, r02, r10, r11, r12, r20, r21, r22 = cf:ToObjectSpace(p.CFrame):GetComponents()
				local s = p.Size
				local ex = (math.abs(r00) * s.X + math.abs(r01) * s.Y + math.abs(r02) * s.Z) / 2
				local ey = (math.abs(r10) * s.X + math.abs(r11) * s.Y + math.abs(r12) * s.Z) / 2
				local ez = (math.abs(r20) * s.X + math.abs(r21) * s.Y + math.abs(r22) * s.Z) / 2
				lo = Vector3.new(math.min(lo.X, c.X - ex), math.min(lo.Y, c.Y - ey), math.min(lo.Z, c.Z - ez))
				hi = Vector3.new(math.max(hi.X, c.X + ex), math.max(hi.Y, c.Y + ey), math.max(hi.Z, c.Z + ez))
				any = true
			end
		end
		if any then break end
	end
	if any then
		info.w = math.clamp(hi.X - lo.X, 4, 16)
		info.len = math.clamp(hi.Z - lo.Z, 6, 40)
		info.cx = math.clamp((lo.X + hi.X) / 2, -4, 4)
		info.cz = math.clamp((lo.Z + hi.Z) / 2, -10, 10)
	else
		info.w, info.len, info.cx, info.cz = 7, 14, 0, 0
	end
end

local function seatInfo(seat)
	local info = SI[seat]
	if not info then info = {peak = 0}; SI[seat] = info end
	if not info.w then measureCar(seat, info) end
	return info
end

-- posisi acuan mobil = pusat badan mobil (bukan kursi) + arah depan
local function carRef(seat)
	if not seat then
		local r = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
		if not r then return nil, nil end
		return r.Position, flat(r.CFrame.LookVector)
	end
	local info = seatInfo(seat)
	local look = seat.CFrame.LookVector
	return seat.CFrame:PointToWorldSpace(Vector3.new(info.cx, 0, info.cz)), flat(C.FlipForward and -look or look)
end

---------------------------------------------------------------- road graph
local roadCache = setmetatable({}, {__mode = "k"})
local ancCache = setmetatable({}, {__mode = "k"})
local function ancRoad(a)   -- a atau leluhurnya bernama "road" (di-cache per instance)
	if not a or a == workspace or a == game then return false end
	local v = ancCache[a]
	if v == nil then v = hasRoad(a.Name) or ancRoad(a.Parent); ancCache[a] = v end
	return v
end
local function isRoadPart(p)
	if not p:IsA("BasePart") or not ancRoad(p) then return false end
	if p:IsDescendantOf(nodesFolder) or p:IsDescendantOf(markFolder) then return false end
	if p.Parent and p.Parent:FindFirstChildOfClass("Humanoid") then return false end
	return true
end
local function isRoadCached(p)
	local v = roadCache[p]
	if v == nil then v = isRoadPart(p); roadCache[p] = v end
	return v
end

local function buildGraph()
	if building then return end
	building, dirty = true, false
	local parts, all = {}, workspace:GetDescendants()
	for i, d in ipairs(all) do
		if isRoadPart(d) then parts[#parts + 1] = d end
		if i % 500 == 0 then slice() end
	end
	local np, adj, own, nd, nw, isEnd, wlist = {}, {}, {}, {}, {}, {}, {}
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
			local L, W = dims[li], dims[6 - ti - li]          -- panjang & lebar jalan (sumbu ketiga = tebal)
			if L >= C.MinRoadLen then
				local dir = flat(axes[li])
				dir = dir.Magnitude > 0.05 and dir.Unit or Vector3.zAxis
				local center = cf.Position + up * (dims[ti] / 2 + 0.3)
				local n, prevI = math.max(1, math.ceil(L / C.NodeSpacing)), nil
				for k = 0, n do
					local idx = #np + 1
					np[idx], adj[idx], own[idx], nd[idx], nw[idx] = center + axes[li] * (-L / 2 + L * k / n), {}, pi, dir, W
					isEnd[idx] = (k == 0 or k == n)
					if prevI then table.insert(adj[idx], prevI); table.insert(adj[prevI], idx) end
					prevI = idx
				end
				wlist[#wlist + 1] = W
			end
		end
		if pi % 20 == 0 then slice() end
	end
	-- lebar referensi = persentil 90 (jalan "besar"); jalan lain dinilai relatif terhadapnya
	table.sort(wlist)
	local ref = math.max(1, wlist[math.max(1, math.floor(#wlist * 0.9))] or 1)
	local wnorm = {}
	for i = 1, #np do wnorm[i] = math.clamp(nw[i] / ref, 0.05, 1) end
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
					local okLink = true
					if C.NoParallelLinks and not isEnd[i] and not isEnd[j] then
						if math.abs(nd[i]:Dot(nd[j])) > 0.9 then okLink = false end   -- dua jalur sejajar: jangan lompat lajur
					end
					if okLink then table.insert(adj[i], j); table.insert(adj[j], i) end
				end
			end end
		end end
		if i % 100 == 0 then slice() end
	end
	NP, ADJ, GRID, ND, NW, WN = np, adj, g, nd, nw, wnorm
	WidthRef, MaxWidth = ref, wlist[#wlist] or 0
	CEN = {}
	ready, lastBuild, building = true, os.clock(), false
nodeGen += 1
local gen = nodeGen
task.spawn(function()   -- titik patokan dibuat di latar belakang; jalan sudah siap dipakai
	nodesFolder:ClearAllChildren()
	local step = math.max(1, math.ceil(#np / C.MaxNodeParts))
	for i = 1, #np, step do
		if gen ~= nodeGen then return end
		mk("Part", {Name = "DitoNode", Size = Vector3.one, Anchored = true, CanCollide = false, CanTouch = false, CanQuery = false,
			CastShadow = false, Material = Enum.Material.Neon, Color = Color3.fromRGB(0, 255, 140),
			Transparency = C.DebugNodes and 0.4 or 1, Position = np[i]}, nodesFolder)
		if i % (40 * step) == 0 then slice() end
	end
end)
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

---------------------------------------------------------------- trek di TENGAH jalan (ukur tepi kiri-kanan dengan raycast)
local DOWN = Vector3.new(0, -7, 0)
local function roadHit(x, z, y0)
	local r = workspace:Raycast(Vector3.new(x, y0 + 2, z), DOWN, rp)
	if not r then return false end
	if math.abs(r.Position.Y - y0) > C.EdgeHeightTol then return false end
	return isRoadCached(r.Instance)
end

-- jarak dari titik p ke tepi jalan sepanjang arah n (nil = tepi tidak ketemu: persimpangan / lapangan luas)
local function edgeDist(p, n, y0)
	local step, maxD = C.CenterStep, C.CenterMaxHalf
	local last, d, miss = 0, step, 0
	while d <= maxD do
		castN += 1
		if roadHit(p.X + n.X * d, p.Z + n.Z * d, y0) then last, miss = d, 0
		else
			miss += 1
			if miss >= 2 then break end   -- 1 celah kecil (garis/kerikil) diabaikan; 2 berturut-turut = tepi
		end
		d += step
	end
	if d > maxD then return nil end
	local lo, hi = last, last + step
	for _ = 1, 3 do
		local m = (lo + hi) / 2
		castN += 1
		if roadHit(p.X + n.X * m, p.Z + n.Z * m, y0) then lo = m else hi = m end
	end
	return (lo + hi) / 2
end

-- vektor geser (dunia) agar titik i tepat di tengah jalan; di-cache
local function centerShift(i)
	if not C.CenterTrack then return Vector3.zero end
	local c = CEN[i]
	if c then return c end
	local p, dir = NP[i], ND[i]
	local shift = Vector3.zero
	if p and dir then
		local lat = Vector3.new(-dir.Z, 0, dir.X)
		local y0 = p.Y - 0.3
		local R, L = edgeDist(p, lat, y0), edgeDist(p, -lat, y0)
		if R and L then
			shift = lat * math.clamp((R - L) / 2, -C.MaxCenterShift, C.MaxCenterShift)
		end
	end
	CEN[i] = shift
	return shift
end

---------------------------------------------------------------- pathfinding (A* / Dijkstra berbobot lebar jalan)
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

-- goal=nil -> flood (Dijkstra). blocked(i, jarakJalan) -> true = node dilarang.
-- dist = jarak NYATA di jalan; biaya (urutan prioritas) diberi penalti jalan sempit bila BigRoads aktif.
local function search(s, goal, maxCost, blocked)
	local np, adj, wn = NP, ADJ, WN
	local dist, cost, prev, closed, heap = {[s] = 0}, {[s] = 0}, {}, {}, Heap.new()
	local gp = goal and np[goal]
	local pen = C.BigRoads and C.WidthPenalty or 0
	heap:push(s, gp and (np[s] - gp).Magnitude or 0)
	local cnt = 0
	while true do
		local u = heap:pop()
		if not u then break end
		if not closed[u] then
			closed[u] = true
			if u == goal then break end
			cnt += 1
			if cnt % 150 == 0 then slice() end
			local du, cu, pu, wu = dist[u], cost[u], np[u], wn[u] or 1
			for _, v in ipairs(adj[u]) do
				if not closed[v] then
					local seg = (np[v] - pu).Magnitude
					local nd = du + seg
					local nc = cu + seg * (1 + pen * (1 - (wu + (wn[v] or 1)) * 0.5))
					if nc < (cost[v] or math.huge) and nd <= maxCost and not (blocked and blocked(v, nd)) then
						dist[v], cost[v], prev[v] = nd, nc, u
						heap:push(v, nc + (gp and (np[v] - gp).Magnitude or 0))
					end
				end
			end
		end
	end
	return dist, prev, np
end

---------------------------------------------------------------- geometri trek (belokan = busur lingkaran presisi)
local function cumulative(pts)
	local cum = {0}
	for i = 2, #pts do cum[i] = cum[i - 1] + (pts[i] - pts[i - 1]).Magnitude end
	return cum
end

local function dedupe(pts, minD)
	local out = {pts[1]}
	for i = 2, #pts do
		if (pts[i] - out[#out]).Magnitude >= minD then out[#out + 1] = pts[i] end
	end
	if #pts > 1 and out[#out] ~= pts[#pts] then out[#out] = pts[#pts] end   -- ujung rute selalu dipertahankan
	return out
end

-- Ramer-Douglas-Peucker (iteratif): buang titik yang sejajar garis lurus
local function simplify(pts, eps)
	local n = #pts
	if n < 3 then return pts end
	local keep, stack = {[1] = true, [n] = true}, {{1, n}}
	while #stack > 0 do
		local seg = table.remove(stack)
		local a, b = seg[1], seg[2]
		local pa, ab = pts[a], pts[b] - pts[a]
		local L = ab.Magnitude
		local dmax, idx = 0, nil
		for i = a + 1, b - 1 do
			local ap = pts[i] - pa
			local d = L < 1e-3 and ap.Magnitude or ap:Cross(ab).Magnitude / L
			if d > dmax then dmax, idx = d, i end
		end
		if idx and dmax > eps then
			keep[idx] = true
			stack[#stack + 1] = {a, idx}
			stack[#stack + 1] = {idx, b}
		end
	end
	local out = {}
	for i = 1, n do if keep[i] then out[#out + 1] = pts[i] end end
	return out
end

-- sudut tikungan diganti busur lingkaran yang menyinggung kedua kaki jalan.
-- belokan tajam (>= SoftAngle) memakai radius TurnRadius (dibatasi panjang kaki); tikungan landai dihaluskan maksimal.
local function filletPath(P)
	local n = #P
	if n < 3 then return P end
	local out = {P[1]}
	for i = 2, n - 1 do
		local vtx, A, B = P[i], P[i - 1], P[i + 1]
		local d1, d2 = flat(A - vtx), flat(B - vtx)
		local l1, l2 = d1.Magnitude, d2.Magnitude
		if l1 < 0.05 or l2 < 0.05 then
			out[#out + 1] = vtx
		else
			local u1, u2 = d1 / l1, d2 / l2
			local phi = math.acos(math.clamp(u1:Dot(u2), -1, 1))   -- sudut dalam di titik sudut
			local theta = math.pi - phi                           -- sudut belok
			if theta < math.rad(0.6) or phi < math.rad(4) then
				out[#out + 1] = vtx
			else
				local th = math.tan(theta / 2)
				local fa = (i == 2) and 0.95 or 0.5
				local fb = (i == n - 1) and 0.95 or 0.5
				local tmax = math.min(l1 * fa, l2 * fb)
				local rgeo = tmax / th
				local r = (math.deg(theta) < C.SoftAngle) and rgeo or math.min(C.TurnRadius, rgeo)
				local t = r * th
				local bis = u1 + u2
				local cen = vtx + (bis / bis.Magnitude) * (r / math.cos(theta / 2))
				local E1, E2 = vtx + u1 * t, vtx + u2 * t
				local y1 = vtx.Y + (A.Y - vtx.Y) * (t / l1)
				local y2 = vtx.Y + (B.Y - vtx.Y) * (t / l2)
				local a1 = math.atan2(E1.Z - cen.Z, E1.X - cen.X)
				local a2 = math.atan2(E2.Z - cen.Z, E2.X - cen.X)
				local sw = (a2 - a1 + math.pi) % (2 * math.pi) - math.pi
				local m = math.max(2, math.ceil(r * math.abs(sw) / C.PathStep))
				for q = 0, m do
					local ang = a1 + sw * q / m
					out[#out + 1] = Vector3.new(cen.X + r * math.cos(ang), y1 + (y2 - y1) * q / m, cen.Z + r * math.sin(ang))
				end
			end
		end
	end
	out[#out + 1] = P[n]
	return out
end

-- titik-titik rata dengan jarak tetap `step`
local function resample(poly, step)
	local out, carry = {poly[1]}, 0
	for i = 1, #poly - 1 do
		local a, b = poly[i], poly[i + 1]
		local seg = (b - a).Magnitude
		if seg > 1e-4 then
			local pos = step - carry
			while pos <= seg do
				out[#out + 1] = a:Lerp(b, pos / seg)
				pos += step
			end
			carry = seg - (pos - step)
		end
	end
	local last = poly[#poly]
	if (out[#out] - last).Magnitude > 0.05 then out[#out + 1] = last end
	return out
end

local function shapePath(P)
	local p = dedupe(P, 0.3)
	if #p < 2 then p[2] = p[1] + Vector3.new(0, 0, 0.5) end
	p = simplify(p, C.SimplifyEps)
	p = filletPath(p)
	p = resample(p, C.PathStep)
	if math.abs(C.LaneOffset) > 0.01 then
		local n, q = #p, {}
		for i = 1, n do
			local T = flat(p[math.min(n, i + 1)] - p[math.max(1, i - 1)])
			q[i] = T.Magnitude > 0.01 and (p[i] + T.Unit:Cross(Vector3.yAxis) * C.LaneOffset) or p[i]
		end
		p = q
	end
	if #p < 2 then p[2] = p[1] + Vector3.new(0, 0, 0.5) end
	return p
end

-- kelengkungan bertanda (+ = belok kiri) per titik
local function curvature(pts)
	local n, kap = #pts, {}
	for i = 1, n do kap[i] = 0 end
	if n < 3 then return kap end
	for i = 2, n - 1 do
		local d1, d2 = flat(pts[i] - pts[i - 1]), flat(pts[i + 1] - pts[i])
		local l1, l2 = d1.Magnitude, d2.Magnitude
		if l1 > 0.01 and l2 > 0.01 then
			kap[i] = math.atan2(d1:Cross(d2).Y, d1:Dot(d2)) / ((l1 + l2) / 2)
		end
	end
	kap[1], kap[n] = kap[2], kap[n - 1]
	local o = {}
	for i = 1, n do o[i] = (kap[math.max(1, i - 1)] + kap[i] + kap[math.min(n, i + 1)]) / 3 end
	return o
end

-- profil kecepatan: batas belokan (gaya samping LatG) + pengereman mundur dari ujung rute
local function buildProfile(pts, kap)
	local n, g = #pts, workspace.Gravity
	local aLat, aBr = C.LatG * g, C.BrakeG * g * 0.8
	local cum, v = cumulative(pts), {}
	for i = 1, n do
		local k = math.abs(kap[i])
		v[i] = k > 1e-4 and math.sqrt(aLat / k) or 1e4
	end
	v[n] = C.EndSpeed
	for i = n - 1, 1, -1 do v[i] = math.min(v[i], math.sqrt(v[i + 1] ^ 2 + 2 * aBr * (cum[i + 1] - cum[i]))) end
	return cum, v
end

-- proyeksi titik p ke polyline -> indeks segmen, parameter 0..1, jarak
local function projectOn(poly, p)
	local bi, bt, bd = 1, 0, math.huge
	for i = 1, #poly - 1 do
		local a, b = poly[i], poly[i + 1]
		local abx, abz = b.X - a.X, b.Z - a.Z
		local l2 = abx * abx + abz * abz
		local t = 0
		if l2 > 1e-6 then t = math.clamp(((p.X - a.X) * abx + (p.Z - a.Z) * abz) / l2, 0, 1) end
		local dx, dz = p.X - (a.X + abx * t), p.Z - (a.Z + abz * t)
		local d = dx * dx + dz * dz
		if d < bd then bd, bi, bt = d, i, t end
	end
	return bi, bt, math.sqrt(bd)
end

local function trimFrom(poly, bi, bt)
	local out = {poly[bi]:Lerp(poly[math.min(#poly, bi + 1)], bt)}
	for i = bi + 1, #poly do out[#out + 1] = poly[i] end
	return dedupe(out, 0.05)
end

---------------------------------------------------------------- deteksi rintangan solid di trek
local topCache = setmetatable({}, {__mode = "k"})
local function boxTop(cf, s)
	return cf.Position.Y + (math.abs(cf.UpVector.Y) * s.Y + math.abs(cf.RightVector.Y) * s.X + math.abs(cf.LookVector.Y) * s.Z) / 2
end
-- puncak benda: bagiannya sendiri, atau seluruh model bila modelnya kecil (pohon, tiang, bangunan kecil)
local function objTop(inst)
	local t = topCache[inst]
	if t then return t end
	t = boxTop(inst.CFrame, inst.Size)
	local m = inst:FindFirstAncestorOfClass("Model")
	if m then
		local ok, cf, sz = pcall(m.GetBoundingBox, m)
		if ok and sz.X < 150 and sz.Y < 250 and sz.Z < 150 then t = math.max(t, boxTop(cf, sz)) end
	end
	if inst.Anchored then topCache[inst] = t end
	return t
end

-- rintangan = benda solid setinggi > ObstMinH stud dari permukaan jalan (baseY). Yang lebih rendah / kecil / bergerak diabaikan.
local function obstacleHit(hit, baseY)
	local inst = hit.Instance
	if not inst or not inst.CanCollide then return false end
	if hit.Normal.Y > 0.65 then return false end                    -- permukaan datar menghadap atas = lantai / tanjakan
	if torn and inst:IsDescendantOf(torn) then return false end      -- tornado sendiri bukan rintangan
	if inst:IsA("BasePart") and not inst:IsA("Terrain") then
		local s = inst.Size
		if math.max(s.X, s.Y, s.Z) < C.ObstMinSize then return false end                                -- kerikil / puing kecil
		if not inst.Anchored and inst.AssemblyLinearVelocity.Magnitude > 3 then return false end         -- benda bergerak
		if objTop(inst) - baseY < C.ObstMinH then return false end                                      -- lebih rendah dari batas tinggi
	end
	return true
end

-- Blockcast; part yang bukan rintangan (tanjakan, puing kecil) diabaikan lalu dilempar ulang
local function castChord(cf, size, dirVec, baseY)
	local params = rp
	local own = false
	for _ = 1, 8 do
		local hit = workspace:Blockcast(cf, size, dirVec, params)
		if not hit then return nil end
		if obstacleHit(hit, baseY) then return hit end
		if not own then
			params = RaycastParams.new()
			params.FilterType = Enum.RaycastFilterType.Exclude
			params.IgnoreWater = true
			params.FilterDescendantsInstances = rp.FilterDescendantsInstances
			own = true
		end
		local f = params.FilterDescendantsInstances
		f[#f + 1] = hit.Instance
		params.FilterDescendantsInstances = f
	end
	return nil
end

-- pindai sepanjang trek dari indeks i0 sejauh `look` stud, lebar kotak = w. Return {dist, s, pos, inst} atau nil
local function scanPath(pts, cum, i0, look, w)
	local n = #pts
	local base, k, hgt = cum[i0], i0, C.ObstHeight
while k < n and cum[k] - base < look do
	slice()
		local e = k + 1
		while e < n and cum[e] - cum[k] < C.ChordLen do e += 1 end
		local a, b = pts[k], pts[e]
		local dv = b - a
		local len = dv.Magnitude
		if len > 0.3 then
			local u = dv / len
			local o = a + Vector3.new(0, C.ObstClear + hgt / 2, 0)
			local cf = CFrame.lookAt(o, o + u)
			local hit = castChord(cf, Vector3.new(w, hgt, 0.5), u * (len + 0.5), a.Y)
			if hit and hit.Distance < 0.05 then   -- sudah menempel di sisi (pagar dekat): coba kotak lebih sempit
				hit = castChord(cf, Vector3.new(w * 0.6, hgt, 0.5), u * (len + 0.5), a.Y)
			end
			if hit then
				return {dist = (cum[k] - base) + hit.Distance, s = cum[k] + hit.Distance, pos = hit.Position, inst = hit.Instance}
			end
		end
		k = e
	end
	return nil
end

local function obstacleSize(hit)
	local inst = hit.inst
	if inst and inst:IsA("BasePart") and not inst:IsA("Terrain") then
		local s = inst.Size
		return math.clamp(math.max(s.X, s.Z), 3, 70)
	end
	return 6
end

-- geser sebagian trek menyamping (profil halus) untuk menghindar. A + = kanan
local function offsetPath(pts, cum, s1, s2, ramp, A)
	local n, out = #pts, {}
	for i = 1, n do
		local s, f = cum[i], 0
		if s > s1 - ramp and s < s2 + ramp then
			if s < s1 then
				local t = (s - (s1 - ramp)) / ramp; f = t * t * (3 - 2 * t)
			elseif s <= s2 then f = 1
			else
				local t = 1 - (s - s2) / ramp; f = t * t * (3 - 2 * t)
			end
		end
		out[i] = pts[i]
		if f > 0 then
			local T = flat(pts[math.min(n, i + 1)] - pts[math.max(1, i - 1)])
			if T.Magnitude > 0.01 then out[i] = pts[i] + T.Unit:Cross(Vector3.yAxis) * (A * f) end
		end
	end
	return out
end

-- seluruh lebar mobil di sisi geser harus masih di atas jalan
local function onRoadSpan(pts, cum, sA, sB, A, w)
	local sign, n, lastS = (A >= 0) and 1 or -1, #pts, -1e9
	for i = 1, n do
		local s = cum[i]
		if s >= sA and s <= sB and s - lastS >= 6 then
			lastS = s
			local p = pts[i]
			local T = flat(pts[math.min(n, i + 1)] - pts[math.max(1, i - 1)])
			if T.Magnitude > 0.01 then
				local q = p + T.Unit:Cross(Vector3.yAxis) * (sign * (w / 2 + 0.5))
				local y0 = p.Y - 0.3
				if not roadHit(p.X, p.Z, y0) or not roadHit(q.X, q.Z, y0) then return false end
			end
		end
	end
	return true
end

local GDOWN = Vector3.new(0, -14, 0)
local function groundY(x, z, yRef)   -- tinggi tanah (boleh di luar jalan) di (x,z); nil bila tak ada / terlalu curam
	local r = workspace:Raycast(Vector3.new(x, yRef + 5, z), GDOWN, rp)
	if not r or r.Normal.Y < 0.5 then return nil end
	local y = r.Position.Y + 0.3
	if math.abs(y - yRef) > 6 then return nil end
	return y
end

-- lebar mobil di sisi geser harus masih ada tanah (versi luar-jalan dari onRoadSpan)
local function groundSpan(pts, cum, sA, sB, A, w)
	local sign, n, lastS = (A >= 0) and 1 or -1, #pts, -1e9
	for i = 1, n do
		local s = cum[i]
		if s >= sA and s <= sB and s - lastS >= 6 then
			lastS = s
			local p = pts[i]
			local T = flat(pts[math.min(n, i + 1)] - pts[math.max(1, i - 1)])
			if T.Magnitude > 0.01 then
				local q = p + T.Unit:Cross(Vector3.yAxis) * (sign * (w / 2 + 0.5))
				if not groundY(p.X, p.Z, p.Y) or not groundY(q.X, q.Z, p.Y) then return false end
			end
		end
	end
	return true
end

-- tinggi titik trek hasil geser disesuaikan ke tanah
local function regroundRange(pts, cum, sA, sB)
	for i = 1, #pts do
		local s = cum[i]
		if s >= sA and s <= sB then
			local p = pts[i]
			local y = groundY(p.X, p.Z, p.Y)
			if y then pts[i] = Vector3.new(p.X, y, p.Z) end
		end
	end
end

-- ujung rintangan yang menerus / berdekatan (bangunan lebar, deretan pohon) di sepanjang trek asli
local function obstacleEnd(pts, cum, hit, w)
	local n, sEnd, i = #pts, hit.s + obstacleSize(hit), 1
	for _ = 1, 80 do
		while i < n and cum[i] < sEnd do i += 1 end
		local h = scanPath(pts, cum, i, 35, w)
		if not h then break end
		sEnd = h.s + obstacleSize(h)
	end
	return sEnd
end

-- free=false: lekukan harus tetap di atas jalan. free=true: boleh di luar jalan (asal ada tanah).
local function tryBypass(pts, cum, hit, w, carLen, free)
	local n = #pts
	local s1 = hit.s - 3
	local s2 = (free and obstacleEnd(pts, cum, hit, w) or (hit.s + obstacleSize(hit))) + carLen
	for _, m in ipairs(free and C.OffRoadOffsets or C.ObstOffsets) do   -- lekukan kecil dulu, kiri/kanan bergantian
		if free or m + w / 2 <= C.CenterMaxHalf then
			local ramp = math.clamp(m * 9, 24, 200)                       -- lekukan landai: makin dalam makin panjang
			for _, A in ipairs({m, -m}) do
				local cand = offsetPath(pts, cum, s1, s2, ramp, A)
				local cc = cumulative(cand)
				local okSpan
				if free then okSpan = groundSpan(cand, cc, s1 - ramp, s2 + ramp, A, w)
				else okSpan = onRoadSpan(cand, cc, s1 - ramp, s2 + ramp, A, w) end
				if okSpan then
					if free then regroundRange(cand, cc, s1 - ramp, s2 + ramp); cc = cumulative(cand) end
					local ia = 1
					while ia < n and cc[ia] < s1 - ramp - 4 do ia += 1 end
					if not scanPath(cand, cc, ia, (s2 + ramp + 4) - cc[ia], w + 1.0) then
						local ie = n
						for i = ia, n do if cum[i] >= s2 + ramp then ie = i; break end end
						return cand, ie                                   -- ie = indeks pertama setelah lekukan
					end
				end
			end
		end
	end
	return nil
end

-- cari rintangan di SELURUH trek; lekukan di jalan dulu, lalu (bila perlu) di luar jalan. Return trek baru, rintangan yang tak bisa dihindari
local function avoidObstacles(pts, w, carLen, free)
	local from = 1
	for _ = 1, 200 do
		local cum = cumulative(pts)
		local hit = scanPath(pts, cum, from, C.ObstLook, w)
		if not hit then return pts, nil end
		local cand, ie
		if not free then cand, ie = tryBypass(pts, cum, hit, w, carLen, false) end
		if not cand and (free or C.OffRoadAvoid) then cand, ie = tryBypass(pts, cum, hit, w, carLen, true) end
		if not cand then return pts, hit end
		pts, from = cand, math.max(1, ie)
	end
	return pts, nil
end
local function pruneBlk()
	local now = os.clock()
	for i = #BLK, 1, -1 do if now - BLK[i].t > C.ObstMemory then table.remove(BLK, i) end end
end
local function obstBlocker()
	pruneBlk()
	if #BLK == 0 then return nil end
	return function(i)
		local p = NP[i]
		for _, b in ipairs(BLK) do
			local dx, dz = p.X - b.pos.X, p.Z - b.pos.Z
			if dx * dx + dz * dz < b.r * b.r and math.abs(p.Y - b.pos.Y) < 20 then return true end
		end
		return false
	end
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
	if n < 6 or hist[#hist].t - hist[#hist - n + 1].t < math.min(w * 0.5, 0.8) then return nil end
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

---------------------------------------------------------------- lokasi intersep (dikunci) - diutamakan di jalan besar
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
		for pass = 1, 2 do
			local wideOnly = (pass == 1) and C.BigRoads
			for i, d in pairs(dist) do
				local wn = WN[i] or 1
				if not wideOnly or wn >= C.TargetWidthFrac then
					local p = np[i]
					local rx, rz = p.X - T0.X, p.Z - T0.Z
					local tc = d / vAvg                                  -- waktu mobil tiba
					local wb = C.BigRoads and (1 - wn) * C.WidthBonus or 0
					for _, c in ipairs(cs) do
						local along = rx * c.dx + rz * c.dz              -- jarak di trek tornado
						if along > c.v * C.LeadSec * 0.7 then
							local lat = math.abs(rx * c.dz - rz * c.dx)  -- jarak titik jalan ke trek
							if lat <= C.MaxLateral then
								-- rumus: jarak = kecepatan_tornado * (waktu_mobil + 2 menit)
								local cost = math.abs(along - c.v * (tc + C.LeadSec)) + C.LatWeight * lat + wb
								if not best or cost < best.cost then best = {cost = cost, i = i, c = c, d = d, lat = lat} end
							end
						end
					end
				end
			end
			if best or not C.BigRoads then break end
		end
		if best then
			intercept = {pos = np[best.i], dx = best.c.dx, dz = best.c.dz, v = best.c.v, eta = best.d / vAvg, dist = best.d, lat = best.lat, width = (WN[best.i] or 1) * WidthRef}
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
					sc = math.min(sc, lat, 1800) - 0.08 * d + (C.BigRoads and (WN[i] or 1) * C.WidthBonus or 0)
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
-- gambar trek: garis neon cyan mengikuti rute (segmen adaptif: lurus panjang, busur pendek -> tetap akurat)
local trackParts = {}
local function drawTrack(pts)
	local n = pts and #pts or 0
	local segs = {}
	if C.ShowTrack and n > 1 then
		local tol = 0.1
		repeat
			segs = {}
			local i = 1
			while i < n do
				local j = i + 1
				while j < n do
					local a = pts[i]
					local ab = pts[j + 1] - a
					local L = ab.Magnitude
					local ok = L <= 60
					if ok then
						for m = i + 1, j do
							if (pts[m] - a):Cross(ab).Magnitude / math.max(L, 1e-6) > tol then ok = false; break end
						end
					end
					if not ok then break end
					j += 1
				end
				segs[#segs + 1] = {i, j}
				i = j
			end
			tol *= 2
		until #segs <= C.MaxTrackParts
	end
	for k, sg in ipairs(segs) do
		local a = pts[sg[1]] + Vector3.new(0, 0.5, 0)
		local b = pts[sg[2]] + Vector3.new(0, 0.5, 0)
		local p = trackParts[k]
		if not p then
			p = mk("Part", {Name = "DitoTrackSeg", Anchored = true, CanCollide = false, CanQuery = false, CanTouch = false,
				CastShadow = false, Material = Enum.Material.Neon, Color = Color3.fromRGB(0, 200, 255), Transparency = 0.25}, markFolder)
			trackParts[k] = p
		end
		p.Size = Vector3.new(1.8, 0.3, math.max(0.3, (b - a).Magnitude))
		p.CFrame = CFrame.lookAt((a + b) / 2, b)
	end
	for i = #trackParts, #segs + 1, -1 do trackParts[i]:Destroy(); trackParts[i] = nil end
end

-- rute graf -> titik tengah jalan -> garis lurus + busur -> titik rata. nil bila tidak ada rute.
local function buildBase(s, g, lock)
	local blkT = lock.flee and makeBlocker(C.FleeMph * C.MPH) or nil
	local blkO = obstBlocker()
	local function blkAll(i, d) return (blkT and blkT(i, d)) or (blkO and blkO(i)) or false end
	local function blkObs(i) return (blkO and blkO(i)) or false end
	local lim = C.MaxSearch * 1.5
	local _, prev = search(s, g, lim, (blkT or blkO) and blkAll or nil)
	if s ~= g and not prev[g] and blkT then _, prev = search(s, g, lim, blkO and blkObs or nil) end
	if s ~= g and not prev[g] and (blkT or blkO) then _, prev = search(s, g, lim) end
	if s ~= g and not prev[g] then return nil end
	local idxs, u = {}, g
	while u do idxs[#idxs + 1] = u; u = prev[u] end
	for i = 1, #idxs // 2 do idxs[i], idxs[#idxs + 1 - i] = idxs[#idxs + 1 - i], idxs[i] end
	local n, sh = #idxs, {}
	for k, i in ipairs(idxs) do
		sh[k] = centerShift(i)
		slice()
	end
	local P = {}
	for k, i in ipairs(idxs) do
		local v = sh[k]
		if k > 1 and k < n then v = (sh[k - 1] + sh[k] * 2 + sh[k + 1]) / 4 end   -- haluskan geseran antar titik
		P[k] = NP[i] + v
	end
	return shapePath(P)
end

local function obstacleRadius(hit, w)
	return math.clamp(obstacleSize(hit) / 2 + w / 2 + 6, 10, 45)
end

local function truncateAt(pts, s)   -- potong trek pada jarak s dari awal
	local out, cum = {pts[1]}, 0
	for i = 2, #pts do
		local d = (pts[i] - pts[i - 1]).Magnitude
		if cum + d >= s then
			out[#out + 1] = pts[i - 1]:Lerp(pts[i], (s - cum) / math.max(d, 1e-6))
			return out
		end
		cum += d
		out[#out + 1] = pts[i]
	end
	return out
end

-- trek LURUS dari mobil ke arah tornado, di luar jalan; berakhir di titik perkiraan "tornado dekat"; melengkung menghindari benda solid
local function buildApproach(p0, T, w, carLen)
	local d = flat(T - p0)
	local dist = d.Magnitude
	local vx, vz = velWindow(12)
	local vt = vx and math.sqrt(vx * vx + vz * vz) or (intercept and intercept.v) or 0
	local vc = math.max(D.speed, 0.5 * estTop(), 15)
	local x = math.min((dist - C.ApproachStop) / (1 + vt / vc), C.ApproachMaxLen)   -- mobil & tornado saling mendekat
	if dist < 1 or x < 10 then return {p0}, nil end                                   -- tak ada ruang tersisa: tetap di tempat
	local u = d / dist
	local y = groundY(p0.X, p0.Z, p0.Y) or (p0.Y - 2)
	local n = math.ceil(x / C.PathStep)
	local pts, miss = {Vector3.new(p0.X, y, p0.Z)}, 0
	for k = 1, n do
		local q = p0 + u * (x * k / n)
		local gy = groundY(q.X, q.Z, y)
		if gy and gy - y <= 3 then miss, y = 0, gy
		else
			miss += 1
			if miss >= 3 then for _ = 1, miss - 1 do pts[#pts] = nil end; break end   -- jurang / tembok: potong di sini
		end
		pts[#pts + 1] = Vector3.new(q.X, y, q.Z)
		if k % 20 == 0 then slice() end
	end
	local out, obs = avoidObstacles(pts, w, carLen, true)
	if obs then out = truncateAt(out, math.max(0, obs.s - carLen / 2 - 8)) end         -- benar-benar buntu: berhenti sebelum rintangan
	return out, obs
end

local function replan(lock)
	if busy.p or not ready then return end
	busy.p = true
	D.planAt, D.force = os.clock(), false
	local ok, err = pcall(function()
		local seat = seatNow()
		updateFilter(seat)
		local info = seat and seatInfo(seat) or nil
		local p0, fwd0 = carRef(seat)
		if not p0 then return end
		local cw = info and info.w or 7
		local w = cw + 2 * C.ObstSide
		local carLen = info and info.len or 14

		-- pasang trek ke driver + gambar (dipotong mulai dari posisi mobil saat ini)
		local function commit(pts, obs)
			local ref = carRef(seatNow()) or p0
			local bi, bt = projectOn(pts, ref)
			pts = trimFrom(pts, bi, bt)
			if #pts < 2 then pts[2] = pts[1] + (fwd0 and fwd0.Magnitude > 0.05 and fwd0.Unit or Vector3.zAxis) * 0.5 end
			local kap = curvature(pts)
			local cum, vp = buildProfile(pts, kap)
			D.pts, D.cum, D.vp, D.kap, D.idx, D.lock, D.arrived, D.dev = pts, cum, vp, kap, 1, lock, false, 0
			D.vCap = lock.flee and C.FleeMph * C.MPH or nil
			D.preview = seatNow() == nil
			D.obst, D.planPos, D.planAt = obs, ref, os.clock()
			drawTrack(pts)
		end

		if lock.approach then   -- fase dekati tornado: lurus ke tornado, di luar jalan
			if not tornPos then return end
			local pts, obs = buildApproach(p0, tornPos, w, carLen)
			commit(pts, obs)
			return
		end

		local s, g = nearestNode(p0, 500), nearestNode(lock.pos, 120)
		if not (s and g) then D.pts, D.lock = nil, lock; return end
		local function baseFrom()
			local base = buildBase(s, g, lock)
			if not base then return nil end
			local bi, bt = projectOn(base, carRef(seatNow()) or p0)
			return trimFrom(base, bi, bt)
		end

		local pts = baseFrom()
		if not pts then D.pts, D.lock = nil, lock; return end
		if D.lock ~= lock or not D.pts then commit(pts, nil) end    -- trek dasar langsung tampil, lalu dihaluskan di bawah
		if not C.ObstDetect then commit(pts, nil); return end

		local obs
		pts, obs = avoidObstacles(pts, w, carLen)                    -- seluruh rute: lekukan menghindari benda > 5 stud
		local tries = 0
		while obs and tries < C.ObstReroute do                       -- tak bisa dihindari di jalur ini: ganti jalan
			tries += 1
			BLK[#BLK + 1] = {pos = obs.pos, r = obstacleRadius(obs, w), t = os.clock()}
			local p2 = baseFrom()
			if not p2 then break end
			local pts2, obs2 = avoidObstacles(p2, w, carLen)
			if not obs2 or obs2.s > obs.s + 10 then pts, obs = pts2, obs2 else break end
		end
		if obs then pts, obs = avoidObstacles(pts, cw + 0.6, carLen) end   -- upaya terakhir: jarak samping lebih rapat
		commit(pts, obs)
	end)
	if not ok then warn("[Dito] replan:", err) end
	busy.p = false
end
local function replanNow() D.force = true end

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
	local info = seatInfo(seat)
	local root = seat.AssemblyRootPart or seat
	local look = seat.CFrame.LookVector
	local fwd = flat(C.FlipForward and -look or look)
	if fwd.Magnitude < 0.05 then return end
	fwd = fwd.Unit
	local right = fwd:Cross(Vector3.yAxis)
	local vel = root.AssemblyLinearVelocity
	local fv = flat(vel)
	local speed = fv.Magnitude
	if math.abs(vel.Y) < 25 and speed > info.peak then info.peak = speed end
	D.speed = speed
	local mode = D.mode
	if mode == "off" or (mode == "path" and not D.pts) then setBlock(false); return end
	setBlock(true)
	if os.clock() - D.filtAt > 1.5 then D.filtAt = os.clock(); updateFilter(seat) end

	local g, mass = workspace.Gravity, root.AssemblyMass
	local aBr, aLat = C.BrakeG * g, C.LatG * g
	local pos = seat.CFrame:PointToWorldSpace(Vector3.new(info.cx, 0, info.cz))   -- pusat badan mobil
	local cap = math.min(C.MaxMph * C.MPH, D.vCap or math.huge)                   -- batas kecepatan yang kamu atur
	local omFull = aLat / math.max(speed, 8)
	local vDes, omT, latDes, holdV = 0, 0, 0, nil

	if mode == "path" then
		local pts, n, cum, kap = D.pts, #D.pts, D.cum, D.kap
		-- proyeksi mobil ke trek (titik terdekat sebenarnya, bukan sekadar titik sampel)
		local bi, bt, bd = D.idx, 0, math.huge
		for i = math.max(1, D.idx - 2), math.min(n - 1, D.idx + 60) do
			local a, b = pts[i], pts[i + 1]
			local abx, abz = b.X - a.X, b.Z - a.Z
			local l2 = abx * abx + abz * abz
			local t = 0
			if l2 > 1e-6 then t = math.clamp(((pos.X - a.X) * abx + (pos.Z - a.Z) * abz) / l2, 0, 1) end
			local dx, dz = pos.X - (a.X + abx * t), pos.Z - (a.Z + abz * t)
			local d = dx * dx + dz * dz
			if d < bd then bd, bi, bt = d, i, t end
		end
		bd = math.sqrt(bd)
		local a, b = pts[bi], pts[bi + 1]
		local T = flat(b - a)
		T = T.Magnitude > 1e-4 and T.Unit or fwd
		local Q = a:Lerp(b, bt)
		local rT = T:Cross(Vector3.yAxis)                         -- kanan arah trek
		local e = flat(pos - Q):Dot(rT)                           -- + = mobil di kanan trek
		local alpha = math.atan2(fwd:Cross(T).Y, fwd:Dot(T))      -- + = trek di kiri arah mobil
		local kp = kap[bi] + (kap[bi + 1] - kap[bi]) * bt         -- kelengkungan trek (+ = kiri)
		local s = cum[bi] + (cum[bi + 1] - cum[bi]) * bt
		local rem = cum[n] - s
		D.idx, D.dev, D.e, D.rem = bi, bd, e, rem

		-- Stanley + feed-forward kelengkungan: mobil menempel di trek, belokan diikuti tepat
		local delta = alpha + math.atan(C.StanleyK * e / (math.max(speed, 3) + C.StanleyV0))
		omT = kp * speed + C.HeadK * delta
		local omMax = (aLat * 1.5) / math.max(speed, 6) * math.clamp(speed / 3, 0.3, 1)
		omT = math.clamp(omT, -omMax, omMax)
		-- tarikan menyamping halus ke garis tengah trek (menghilangkan sisa simpangan)
		local corr = rT * (-e * C.RailGain)
		if corr.Magnitude > C.RailMax then corr = corr.Unit * C.RailMax end
		latDes = corr:Dot(right) * math.clamp(speed / 6, 0, 1)


		-- kecepatan: profil belokan + berhenti tepat di ujung trek (tidak kurang / tidak lewat)
		local jl, lead = bi + 1, speed * C.SpeedLead
		while jl < n and cum[jl] - s < lead do jl += 1 end
		local vProf = math.min(D.vp[math.min(bi + 1, n)], D.vp[jl])
		local vCreep = math.clamp(rem * 2, 0.8, 3)
		local vStop = math.sqrt(2 * aBr * 0.75 * math.max(rem - 0.4, 0))
		vDes = math.min(vProf, cap, math.max(vStop, vCreep))
		if rem > C.ArriveTol then vDes = math.max(vDes, vCreep) end
		vDes = vDes * (1 - 0.6 * math.clamp(math.abs(alpha) / 1.2, 0, 1)) * (1 - 0.5 * math.clamp(math.abs(e) / 6, 0, 1))
		if rem > 20 then vDes = math.max(vDes, 6) end
		if rem < C.ArriveTol then D.mode, D.arrived = "hold", true end
	elseif mode == "hold" and D.pts then
		-- servo halus ke titik akhir trek (berhenti persis di titik tujuan)
		local to = flat(D.pts[#D.pts] - pos)
		local m = to.Magnitude
		if m > 20 then D.arrived = false
		elseif m > 0.25 then holdV = to.Unit * math.min(3, m * 2.5)
		else holdV = Vector3.zero end
		D.e, D.rem = 0, m
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
	local aDes = math.clamp(err * C.SpeedK, -aBr, aAvail)
	if mode ~= "path" then aDes = speed > 0.8 and -aBr or 0; omT = 0 end

	D.omega += (omT - D.omega) * math.min(1, dt * C.SteerSmooth)       -- yaw dihaluskan tipis
	if seat:IsA("VehicleSeat") then
		pcall(function()
			seat.ThrottleFloat = (D.mode == "path") and math.clamp(err / 10, 0, 1) or 0
			seat.SteerFloat = math.clamp(-D.omega / omFull, -1, 1)
		end)
	end

	local imp = Vector3.zero
	if aDes > 0 then
		if info.native == false then imp += fwd * aDes * mass * dt end
	elseif aDes < 0 and speed > 0.4 then
		imp -= fv.Unit * math.min(-aDes, speed * 0.9 / dt) * mass * dt
	end
	-- gaya sentripetal: vektor kecepatan ikut berputar bersama yaw -> tidak melebar di belokan
	local fvr = fv
	local ang = D.omega * dt
	if math.abs(ang) > 1e-5 and speed > 0.5 then
		local ca, sa = math.cos(ang), math.sin(ang)
		fvr = Vector3.new(fv.X * ca + fv.Z * sa, 0, -fv.X * sa + fv.Z * ca)
		imp += (fvr - fv) * mass
	end
	imp -= right * (fvr:Dot(right) - latDes) * mass * math.clamp(dt * C.Grip, 0, 1)   -- grip ban (tanpa selip samping)
	if holdV then imp = (holdV - fv) * mass * math.clamp(dt * C.Grip, 0, 1) end
	root:ApplyImpulse(imp)
	local av = root.AssemblyAngularVelocity
	root.AssemblyAngularVelocity = Vector3.new(av.X, D.omega, av.Z)

	if (D.mode == "stop" or (D.mode == "hold" and not holdV)) and speed < 1.2 then
		root.AssemblyLinearVelocity = Vector3.new(0, vel.Y, 0)
		if D.mode == "stop" then D.mode = "off" end
	end
end
RunService:BindToRenderStep("DitoDrive", Enum.RenderPriority.Input.Value + 1, step)

---------------------------------------------------------------- UI
local gui = mk("ScreenGui", {Name = "DitoTornadoUI", ResetOnSpawn = false, DisplayOrder = 50}, pgui)
local frame = mk("Frame", {Size = UDim2.fromOffset(292, 500), Position = UDim2.fromOffset(10, 70), BackgroundColor3 = Color3.fromRGB(18, 20, 26),
	BackgroundTransparency = 0.1, BorderSizePixel = 0, Active = true, Draggable = true}, gui)
mk("UICorner", {CornerRadius = UDim.new(0, 10)}, frame)
mk("TextLabel", {Size = UDim2.new(1, 0, 0, 26), BackgroundTransparency = 1, Text = "DITO TORNADO AI v2", TextColor3 = Color3.fromRGB(255, 170, 60),
	Font = Enum.Font.GothamBold, TextSize = 15}, frame)
local infoLbl = mk("TextLabel", {Position = UDim2.fromOffset(10, 28), Size = UDim2.new(1, -20, 0, 178), BackgroundTransparency = 1,
	TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top, TextWrapped = true, RichText = true,
	Font = Enum.Font.Gotham, TextSize = 12, TextColor3 = Color3.new(1, 1, 1), Text = ""}, frame)
local scroll = mk("ScrollingFrame", {Position = UDim2.fromOffset(0, 210), Size = UDim2.new(1, 0, 1, -214), BackgroundTransparency = 1,
	BorderSizePixel = 0, ScrollBarThickness = 4, CanvasSize = UDim2.fromOffset(0, 505), Active = true}, frame)

local function btn(y)
	local b = mk("TextButton", {Position = UDim2.fromOffset(10, y), Size = UDim2.new(1, -24, 0, 30), Font = Enum.Font.GothamBold, TextSize = 13,
		TextColor3 = Color3.new(1, 1, 1), BackgroundColor3 = Color3.fromRGB(60, 64, 76), BorderSizePixel = 0}, scroll)
	mk("UICorner", {CornerRadius = UDim.new(0, 8)}, b)
	return b
end
local bAI, bRun, bLoc = btn(0), btn(36), btn(72)
bLoc.Text = "Ubah Lokasi"

local function toggleBtn(y, label, k, onChange)
	local b = btn(y)
	local function refresh()
		b.Text = label .. ": " .. (C[k] and "ON" or "OFF")
		b.BackgroundColor3 = C[k] and Color3.fromRGB(40, 150, 70) or Color3.fromRGB(60, 64, 76)
	end
	refresh()
	b.Activated:Connect(function() C[k] = not C[k]; refresh(); if onChange then onChange() end end)
	return b
end
local function resetIntercept()
	intercept, relockAt, intStatus = nil, 0, "Menghitung ulang lokasi..."
	replanNow()
end
toggleBtn(108, "Jalan besar (skala terbesar)", "BigRoads", resetIntercept)
toggleBtn(144, "Trek di tengah jalan", "CenterTrack", replanNow)
toggleBtn(180, "Deteksi rintangan solid", "ObstDetect", function() D.obst = nil; replanNow() end)

local function numRow(y, label, k, lo, hi, onChange)
	mk("TextLabel", {Position = UDim2.fromOffset(10, y), Size = UDim2.fromOffset(172, 26), BackgroundTransparency = 1, Text = label,
		TextXAlignment = Enum.TextXAlignment.Left, Font = Enum.Font.Gotham, TextSize = 12, TextColor3 = Color3.new(1, 1, 1)}, scroll)
	local box = mk("TextBox", {Position = UDim2.fromOffset(186, y), Size = UDim2.fromOffset(84, 26), Text = tostring(C[k]),
		Font = Enum.Font.GothamBold, TextSize = 13, TextColor3 = Color3.new(1, 1, 1), BackgroundColor3 = Color3.fromRGB(40, 44, 56),
		BorderSizePixel = 0, ClearTextOnFocus = false}, scroll)
	mk("UICorner", {CornerRadius = UDim.new(0, 8)}, box)
	box.FocusLost:Connect(function()
		local v = tonumber(box.Text)
		if v then C[k] = math.clamp(v, lo, hi); if onChange then onChange() end end
		box.Text = tostring(C[k])
	end)
	return box
end
numRow(222, "Max speed AI (mph)", "MaxMph", 10, 300)                      -- berlaku langsung
numRow(252, "Radius belokan (stud)", "TurnRadius", 4, 200, replanNow)
numRow(282, "Gaya belok maks (g)", "LatG", 0.15, 1.2, replanNow)
numRow(312, "Geser jalur (+kanan, stud)", "LaneOffset", -20, 20, replanNow)
numRow(342, "Kekuatan koreksi trek", "StanleyK", 0.5, 6)
numRow(372, "Tinggi min. rintangan (stud)", "ObstMinH", 1, 30, replanNow)
numRow(402, "Berhenti saat tornado (stud)", "ApproachStop", 80, 1500)
toggleBtn(432, "Panah prediksi 3D", "Predict")
numRow(468, "Panjang panah (stud)", "PredLen", 500, 20000)

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

local function mkMarker(col, txt, h)
	local p = mk("Part", {Name = "DitoMarker", Anchored = true, CanCollide = false, CanQuery = false, CanTouch = false, CastShadow = false,
		Material = Enum.Material.Neon, Color = col, Transparency = 0.35, Size = Vector3.new(5, h, 5)}, nil)
	local bb = mk("BillboardGui", {Size = UDim2.fromOffset(230, 34), StudsOffset = Vector3.new(0, h / 2 + 10, 0), AlwaysOnTop = true, Adornee = p}, p)
	local l = mk("TextLabel", {Size = UDim2.fromScale(1, 1), BackgroundTransparency = 0.3, BackgroundColor3 = Color3.new(0, 0, 0), TextColor3 = col,
		Font = Enum.Font.GothamBold, TextSize = 14, Text = txt}, bb)
	return p, l
end
local mI, lI = mkMarker(Color3.fromRGB(255, 120, 0), "INTERSEP", 320)
local mE, lE = mkMarker(Color3.fromRGB(60, 255, 120), "TITIK AMAN", 320)
local mO, lO = mkMarker(Color3.fromRGB(255, 40, 40), "RINTANGAN", 40)
---------------------------------------------------------------- PANAH PREDIKSI 3D
-- Batang silinder + kepala kerucut (tumpukan cakram) dari posisi tornado, searah & sepanjang C.PredLen.
-- Arah & kecepatan = regresi posisi tornado (velWindow). Pilar intersep dipasang di proyeksi titik jalan ke sumbu panah,
-- garis oranye pendek menyambung ke titik jalan tempat mobil berhenti (bila ada selisih).
local PR = {shaft = {}, cone = {}, ticks = {}}
do
	local root = mk("Folder", {Name = "DitoPredict"}, markFolder)
	local RED, WHITE = Color3.fromRGB(255, 50, 50), Color3.fromRGB(255, 255, 255)
	local SEG, K, MAXTICK = 500, 12, 40
	local link = mk("Part", {Name = "DitoLink", Anchored = true, CanCollide = false, CanQuery = false, CanTouch = false, CastShadow = false,
		Material = Enum.Material.Neon, Color = Color3.fromRGB(255, 120, 0), Transparency = 0.3, Size = Vector3.new(1.5, 1.5, 1)}, nil)
	local function mkPart(shape, col, tr)
		return mk("Part", {Name = "DitoPred", Anchored = true, CanCollide = false, CanQuery = false, CanTouch = false, CastShadow = false,
			Material = Enum.Material.Neon, Color = col, Transparency = tr, Shape = shape, Size = Vector3.new(1, 1, 1)}, root)
	end
	local function mkTag(adornee, w, col)
		local bb = mk("BillboardGui", {Size = UDim2.fromOffset(w, 20), AlwaysOnTop = true, MaxDistance = math.huge, Adornee = adornee,
			ExtentsOffset = Vector3.new(0, 1.2, 0)}, adornee)
		return mk("TextLabel", {Size = UDim2.fromScale(1, 1), BackgroundTransparency = 0.35, BackgroundColor3 = Color3.new(0, 0, 0), TextColor3 = col,
			Font = Enum.Font.GothamBold, TextSize = 12, Text = ""}, bb)
	end
	local function cyl(p, a, b, len, th)   -- silinder Roblox: sumbu = X, jadi putar 90 derajat agar searah a -> b
		p.Size = Vector3.new(len, th, th)
		p.CFrame = CFrame.lookAt((a + b) / 2, b) * CFrame.Angles(0, math.rad(90), 0)
	end
	local function hide()
		root.Parent = nil
	end

	function PR.update(me)
		local cam = workspace.CurrentCamera
		local cpos = cam and cam.CFrame.Position or me or Vector3.zero
		local vx, vz = velWindow(12)
		if not vx then vx, vz = velWindow(4) end
		local sp = vx and math.sqrt(vx * vx + vz * vz) or 0
		if sp < C.MinTornSpeed then
			vx, vz, sp = nil, nil, 0
			if intercept then vx, vz, sp = intercept.dx * intercept.v, intercept.dz * intercept.v, intercept.v end
		end
		local on = C.Predict and tornPos ~= nil and vx ~= nil and sp >= C.MinTornSpeed
		local ax, az, lat = nil, nil, 0

		if on then
			local L = math.max(200, C.PredLen)
			local dx, dz = vx / sp, vz / sp
			local dir = Vector3.new(dx, 0, dz)
			local baseY = (intercept and intercept.pos.Y) or (me and me.Y) or tornPos.Y
			local o = Vector3.new(tornPos.X, baseY + C.PredHeight, tornPos.Z)
			local tip = o + dir * L
			root.Parent = markFolder

			-- kepala kerucut (ukuran ikut jarak kamera supaya tetap terlihat dari jauh) + batang
			local hl = math.clamp((tip - cpos).Magnitude * 0.05, 200, L * 0.12)
			local sl = L - hl
			local n = math.ceil(sl / SEG)
			for i = 1, n do
				local p = PR.shaft[i]
				if not p then p = mkPart(Enum.PartType.Cylinder, RED, 0.15); PR.shaft[i] = p end
				local s0, s1 = (i - 1) * SEG, math.min(i * SEG, sl)
				local a, b = o + dir * s0, o + dir * s1
				local th = math.clamp(((a + b) / 2 - cpos).Magnitude * C.PredScreen, C.PredThick, C.PredThick * 12)
				cyl(p, a, b, s1 - s0 + 0.3, th)
			end
			for i = #PR.shaft, n + 1, -1 do PR.shaft[i]:Destroy(); PR.shaft[i] = nil end
			local dia = hl * 0.4
			for k = 1, K do
				local p = PR.cone[k]
				if not p then p = mkPart(Enum.PartType.Cylinder, RED, 0.1); PR.cone[k] = p end
				local a, b = o + dir * (sl + (k - 1) * hl / K), o + dir * (sl + k * hl / K)
				cyl(p, a, b, hl / K + 0.3, math.max(1, dia * (1 - (k - 0.5) / K)))
			end

			-- pangkal panah (posisi tornado + kecepatan + arah)
			if not PR.tail then PR.tail = mkPart(Enum.PartType.Ball, WHITE, 0.1); PR.tailL = mkTag(PR.tail, 240, Color3.fromRGB(255, 200, 80)) end
			local ts = math.clamp((o - cpos).Magnitude * 0.012, 10, 150)
			PR.tail.Size = Vector3.new(ts, ts, ts); PR.tail.Position = o
			local brg, name = headingOf(vx, vz)
			PR.tailL.Text = string.format("TORNADO %.0f mph • %s %03.0f°", sp / C.MPH, name, brg)

			-- penanda jarak + waktu tiba tornado di sepanjang panah (jarak / kecepatan)
			local step = math.max(50, C.PredTick, L / MAXTICK)
			local nt = math.floor(L / step + 1e-6)
			for k = 1, nt do
				local t = PR.ticks[k]
				if not t then
					local ball = mkPart(Enum.PartType.Ball, WHITE, 0.1)
					t = {ball = ball, lbl = mkTag(ball, 128, WHITE)}
					PR.ticks[k] = t
				end
				local d = k * step
				local pos = o + dir * d
				local sz = math.clamp((pos - cpos).Magnitude * 0.012, 10, 150)
				t.ball.Size = Vector3.new(sz, sz, sz); t.ball.Position = pos
				t.lbl.Text = string.format("%d stud • %s", d, mmss(d / sp))
			end
			for k = #PR.ticks, nt + 1, -1 do PR.ticks[k].ball:Destroy(); PR.ticks[k] = nil end

			-- titik intersep = proyeksi titik jalan ke sumbu panah (selalu berada di panah)
			if intercept then
				local rx, rz = intercept.pos.X - tornPos.X, intercept.pos.Z - tornPos.Z
				local along = math.clamp(rx * dx + rz * dz, 0, L)
				lat = math.abs(rx * dz - rz * dx)
				ax, az = tornPos.X + dx * along, tornPos.Z + dz * along
			end
		else
			hide()
		end

		-- marker intersep: pilar oranye memotong panah; garis pendek ke titik jalan tempat mobil berhenti
		if intercept then
			local ip = intercept.pos
			mI.Position = Vector3.new(ax or ip.X, ip.Y + 150, az or ip.Z); mI.Parent = markFolder
			lI.Text = string.format("INTERSEP • %.0f studs", me and flat(me - ip).Magnitude or 0)
			if ax and lat > 2 then
				local a, b = Vector3.new(ax, ip.Y + 3, az), ip + Vector3.new(0, 3, 0)
				link.Size = Vector3.new(1.5, 1.5, math.max(1, (b - a).Magnitude))
				link.CFrame = CFrame.lookAt((a + b) / 2, b); link.Parent = markFolder
			else link.Parent = nil end
		else mI.Parent, link.Parent = nil, nil end
	end
end

---------------------------------------------------------------- kontrol service
local function setService(n, on)
	if on then
		local o = n == "ai" and "run" or "ai"
		if services[o] then services[o] = false end
		services[n] = true
		D.mode, D.obst = "off", nil
		if n == "run" then esc.state, escape = "idle", nil end
	else
		services[n] = false
		if n == "ai" then appr = nil end
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
		-- fase dekati: setelah tiba & berhenti di titik intersep dan masih ada waktu -> trek lurus ke arah tornado, berhenti saat tornado dekat
		if appr and (appr.base ~= intercept or not services.ai or not seat) then appr = nil end
		if C.Approach and not appr and services.ai and intercept and cur == intercept and seat and tornPos and tdist
			and D.lock == intercept and D.arrived and D.speed < 4 and tdist > C.ApproachStop + C.ApproachRoom then
			appr = {approach = true, base = intercept, pos = intercept.pos}
		end
		if appr then
			if not appr.done and tdist and D.lock == appr
				and tdist <= C.ApproachStop + D.speed ^ 2 / (2 * C.BrakeG * workspace.Gravity * 0.8) then appr.done = true end
			cur = appr
		end
	local tgt = cur or ((not services.run or esc.state == "idle") and intercept) or nil   -- pratinjau: trek tampil begitu titik intersep ada
	if tgt and ready and not busy.p then
		local age = os.clock() - D.planAt
		local need = D.lock ~= tgt or D.force or (D.preview and seat ~= nil)
			if not need and tgt.approach and not tgt.done and D.pts and age > 3 and (D.mode == "path" or D.mode == "hold")
				and tdist and tdist > C.ApproachStop + 40 then need = true end   -- trek diperbarui mengikuti gerak tornado
		if not need and D.mode == "path" then
			if not D.pts then need = age > 1
			elseif (D.dev or 0) > 40 and age > 3 then need = true
			elseif tgt.flee and age > 8 then need = true
			elseif age > 45 then need = true end
		elseif not need and D.pts and D.planPos and me and age > 2 and (D.mode == "off" or D.mode == "stop")
			and flat(me - D.planPos).Magnitude > 40 then
			need = true   -- pratinjau ikut posisi mobil
		end
		if need then task.spawn(replan, tgt) end
	end
	if (not tgt or not D.pts) and #trackParts > 0 then drawTrack(nil) end
	if services.ai or services.run then
		local want = "off"
		if seat and cur then
			want = (D.lock == cur and D.arrived) and "hold" or "path"
			if appr and cur == appr and appr.done and D.lock == appr then want = "hold" end   -- tornado dekat: rem halus lalu tahan
		end
		if want == "off" then
			if D.mode == "path" or D.mode == "hold" then D.mode = seat and "stop" or "off" end
		else D.mode = want end
	end

	-- marker
	PR.update(me)   -- panah prediksi 3D + marker intersep di panah
	if escape and services.run then
		mE.Position = escape.pos + Vector3.new(0, 150, 0); mE.Parent = markFolder
		lE.Text = string.format("TITIK AMAN • %.0f studs", me and flat(me - escape.pos).Magnitude or 0)
	else mE.Parent = nil end
	if D.obst and D.mode == "path" then
		mO.Position = D.obst.pos + Vector3.new(0, 20, 0); mO.Parent = markFolder
		lO.Text = string.format("RINTANGAN • %.0f studs", me and flat(me - D.obst.pos).Magnitude or 0)
	else mO.Parent = nil end

	-- UI
	banner.Visible = services.run and esc.state == "warning"
	if banner.Visible then banner.BackgroundColor3 = (math.floor(os.clock() * 4) % 2 == 0) and Color3.fromRGB(200, 20, 20) or Color3.fromRGB(255, 120, 0) end
	local L = {}
	if not ready then L[#L + 1] = "Jalan: memindai..."
	else L[#L + 1] = string.format("Jalan: %d titik | terlebar %.0f stud%s", #NP, MaxWidth, C.BigRoads and " | prioritas jalan besar" or "") end
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
		if C.BigRoads and intercept.width then L[#L + 1] = string.format("Jalan intersep: lebar ~%.0f stud", intercept.width) end
	else L[#L + 1] = "Intersep: " .. (intStatus or "menghitung...") end
	if services.run then
		local names = {idle = "aman, memantau", warning = "<font color='#ff4444'>PERINGATAN! masuk mobil</font>", flee = "kabur 100 mph", safe = "sudah di titik aman"}
		L[#L + 1] = "Run Tornado: " .. names[esc.state]
	end
	if D.mode == "path" and not D.pts and (services.ai or services.run) then L[#L + 1] = "<font color='#ffaa33'>Rute jalan belum ketemu...</font>" end
	if D.mode == "path" and D.pts then
		L[#L + 1] = string.format("Simpangan trek: %+.2f stud | sisa %.0f stud", D.e or 0, D.rem or 0)
	elseif D.mode == "hold" then
		L[#L + 1] = string.format("<font color='#66ff99'>Tiba di titik tujuan</font> (selisih %.2f stud)", D.rem or 0)
	end
	if appr then
		L[#L + 1] = appr.done and "<font color='#66ff99'>Tornado sudah dekat: berhenti</font>" or "<font color='#66ccff'>Mendekati tornado: trek lurus, boleh di luar jalan</font>"
	end
	if C.ObstDetect and (D.mode == "path" or D.mode == "hold") then
		if D.obst then
			local nm = D.obst.inst and D.obst.inst.Name or "?"
			L[#L + 1] = string.format("<font color='#ff5555'>RINTANGAN %.0f stud di depan (%s)</font>", (me and flat(me - D.obst.pos).Magnitude or D.obst.dist), nm)
		else L[#L + 1] = "Rintangan: jalur aman" end
	end
	if D.mode == "stop" then L[#L + 1] = "Mengerem sampai berhenti..." end
	L[#L + 1] = string.format("Mobil: %.0f mph", D.speed / C.MPH)
	infoLbl.Text = table.concat(L, "\n")
end

task.spawn(buildGraph)
task.spawn(function()
	while true do
		task.wait(C.TickEvery)
		local ok, err = pcall(tick)
		if not ok then warn("[Dito] tick:", err) end
	end
end)
