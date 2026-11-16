--[[
	=====================================================================
	TORNADO INTERCEPT HELPER  -  LocalScript
	Letakkan di: StarterPlayer > StarterPlayerScripts

	Fitur:
	 1. Kecepatan & arah gerak tornado (regresi linear dari posisi)
	 2. Kecepatan mobil (kendaraan yang sedang dinaiki)
	 3. Titik intercept: tornado tiba = waktu tempuh mobil + 3 menit
	 4. Prediksi touchdown + pencarian tornado terbesar
	 5. UI: panel info, kompas, radar + penanda 3D di dunia game

	Tombol: H = sembunyikan / tampilkan semua UI
	=====================================================================
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

--------------------------------------------------------------------
-- 0. KONFIGURASI  (ubah sesuai game kamu)
--------------------------------------------------------------------
local CONFIG = {
	-- Deteksi tornado
	TORNADO_NAMES = { "tornado", "Tornado" },  -- nama Model/Part yang dicari (harus persis sama)
	TOUCHDOWN_ATTRIBUTE = "TouchedDown",       -- Attribute boolean pada tornado (opsional)

	-- Satuan & arah
	STUD_TO_METER = 0.28,
	SPEED_UNIT = "kmh",                        -- "kmh" atau "mph"
	NORTH_IS_NEG_Z = true,                     -- Utara = arah -Z (bawaan Roblox)

	-- Sampling
	SAMPLE_INTERVAL = 0.2,                     -- detik antar pengukuran
	TORNADO_WINDOW = 8,                        -- jendela regresi tornado (detik)
	CAR_WINDOW = 1.5,                          -- jendela regresi mobil (detik)
	MIN_SPAN = 1.0,                            -- data minimal (detik) sebelum regresi dipakai
	MIN_MOVE_SPEED = 0.5,                      -- studs/s, di bawah ini dianggap diam
	CAR_SMOOTH_TAU = 4,                        -- perataan kecepatan rencana mobil (detik)
	MIN_PLAN_SPEED = 60,                       -- studs/s, kecepatan rencana minimum

	-- Intercept
	INTERCEPT_BUFFER = 180,                    -- 3 menit: tornado tiba = mobil tiba + ini

	-- Touchdown & ukuran
	TOUCHDOWN_CLEARANCE = 6,                   -- studs, dasar corong <= ini dianggap menyentuh tanah
	TOUCHDOWN_HORIZON = 300,                   -- detik, patokan peluang turun
	GROWTH_HORIZON = 180,                      -- detik, proyeksi pertumbuhan lebar
	GROUND_RAY_LENGTH = 6000,

	-- Visual 3D
	TRACK_PREVIEW_SECONDS = 180,               -- panjang garis jalur tornado (detik perjalanan)
	TRACK_MAX_STUDS = 6000,
}

local RADAR_RANGES = { 400, 800, 1500, 3000, 6000, 12000 } -- studs
local radarIdx = 3

--------------------------------------------------------------------
-- 1. UTILITAS
--------------------------------------------------------------------
local function clamp(x, lo, hi)
	return math.max(lo, math.min(hi, x))
end

local function flat(v)
	return Vector3.new(v.X, 0, v.Z)
end

local function new(class, props, parent)
	local obj = Instance.new(class)
	for k, v in pairs(props) do
		obj[k] = v
	end
	obj.Parent = parent
	return obj
end

local function toMeters(studs)
	return studs * CONFIG.STUD_TO_METER
end

local function fmtSpeed(studsPerSec)
	local ms = studsPerSec * CONFIG.STUD_TO_METER
	if CONFIG.SPEED_UNIT == "mph" then
		return string.format("%d mph", math.floor(ms * 2.23694 + 0.5))
	end
	return string.format("%d km/h", math.floor(ms * 3.6 + 0.5))
end

local function fmtDist(studs)
	local m = toMeters(studs)
	if m >= 1000 then
		return string.format("%.2f km", m / 1000)
	end
	return string.format("%d m", math.floor(m + 0.5))
end

local function fmtTime(sec)
	if not sec or sec ~= sec or sec == math.huge then
		return "--:--"
	end
	sec = math.max(0, math.floor(sec + 0.5))
	if sec >= 3600 then
		return ">1 jam"
	end
	return string.format("%02d:%02d", sec // 60, sec % 60)
end

local WIND = { "U", "TL", "T", "TG", "S", "BD", "B", "BL" } -- Utara, Timur Laut, Timur, Tenggara, Selatan, Barat Daya, Barat, Barat Laut

-- Arah dalam derajat dari Utara, searah jarum jam
local function bearingOf(v)
	local north, east
	if CONFIG.NORTH_IS_NEG_Z then
		north, east = -v.Z, v.X
	else
		north, east = v.Z, -v.X
	end
	return math.deg(math.atan2(east, north)) % 360
end

local function windName(deg)
	return WIND[(math.floor((deg + 22.5) / 45) % 8) + 1]
end

local NORTH_VEC = CONFIG.NORTH_IS_NEG_Z and Vector3.new(0, 0, -1) or Vector3.new(0, 0, 1)

local function sizeClass(widthStuds)
	local m = toMeters(widthStuds)
	if m < 30 then
		return "Kecil"
	elseif m < 100 then
		return "Sedang"
	elseif m < 300 then
		return "Besar"
	elseif m < 800 then
		return "Sangat besar"
	end
	return "Raksasa (wedge)"
end

-- Kemiringan garis regresi (least squares) dari field `key` terhadap waktu
local function slope(samples, key)
	local n, tm, vm = 0, 0, 0
	for _, s in ipairs(samples) do
		local v = s[key]
		if v then
			n += 1
			tm += s.t
			vm += v
		end
	end
	if n < 4 then
		return 0
	end
	tm /= n
	vm /= n
	local num, den = 0, 0
	local tmin, tmax = math.huge, -math.huge
	for _, s in ipairs(samples) do
		local v = s[key]
		if v then
			local d = s.t - tm
			num += d * (v - vm)
			den += d * d
			if s.t < tmin then tmin = s.t end
			if s.t > tmax then tmax = s.t end
		end
	end
	if tmax - tmin < CONFIG.MIN_SPAN or den < 1e-9 then
		return 0
	end
	return num / den
end

local function prune(samples, now, window)
	while #samples > 2 and now - samples[1].t > window do
		table.remove(samples, 1)
	end
end

--------------------------------------------------------------------
-- 2. STATE
--------------------------------------------------------------------
local hud = Instance.new("Folder")
hud.Name = "TornadoInterceptHUD"
hud.Parent = Workspace

local car = {
	part = nil,
	parts = {},
	pos = Vector3.zero,
	vel = Vector3.zero,
	speed = 0,
	ema = 0,
	emaInit = false,
	planSpeed = CONFIG.MIN_PLAN_SPEED,
	samples = {},
	inVehicle = false,
}

local candidates = {} -- [Instance] = true
local tracks = {}     -- [Instance] = record
local nextId = 1
local state = { list = {}, target = nil, biggest = nil, icpt = nil }
local mode = "BIGGEST" -- "BIGGEST" | "NEAREST"

--------------------------------------------------------------------
-- 3. DETEKSI TORNADO
--------------------------------------------------------------------
local NAME_SET = {}
for _, n in ipairs(CONFIG.TORNADO_NAMES) do
	NAME_SET[n] = true
end

local function isCandidate(inst)
	if not (inst:IsA("Model") or inst:IsA("BasePart")) then
		return false
	end
	return NAME_SET[inst.Name] == true
end

local function hasCandidateAncestor(inst)
	local p = inst.Parent
	while p and p ~= Workspace do
		if isCandidate(p) then
			return true
		end
		p = p.Parent
	end
	return false
end

local function tryAdd(inst)
	if candidates[inst] or not isCandidate(inst) then
		return
	end
	if inst:IsDescendantOf(hud) or hasCandidateAncestor(inst) then
		return
	end
	if inst:IsA("Model") and inst:FindFirstChildOfClass("Humanoid") then
		return
	end
	candidates[inst] = true
end

local function refreshCandidates()
	for inst in pairs(candidates) do
		if not inst:IsDescendantOf(Workspace) or hasCandidateAncestor(inst) then
			candidates[inst] = nil
		end
	end
end

-- Semua Part bernama "tornado"/"Tornado" dalam parent yang sama dianggap SATU tornado.
-- Model bernama tornado = satu tornado sendiri.
local function buildGroups()
	local groups = {}
	for inst in pairs(candidates) do
		if inst:IsA("Model") then
			groups[inst] = { key = inst, model = inst, parts = {} }
		else
			local key = inst.Parent or Workspace
			local g = groups[key]
			if not g then
				g = { key = key, model = nil, parts = {} }
				groups[key] = g
			end
			table.insert(g.parts, inst)
		end
	end
	return groups
end

-- Pusat & ukuran gabungan semua part (bounding box sejajar sumbu dunia)
local function measure(g)
	if g.model then
		local cf, size = g.model:GetBoundingBox()
		return cf.Position, size
	end
	local minX, minY, minZ = math.huge, math.huge, math.huge
	local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
	local any = false
	for _, p in ipairs(g.parts) do
		local cf, s = p.CFrame, p.Size
		local r, u, l = cf.RightVector, cf.UpVector, cf.LookVector
		local hx = (math.abs(r.X) * s.X + math.abs(u.X) * s.Y + math.abs(l.X) * s.Z) / 2
		local hy = (math.abs(r.Y) * s.X + math.abs(u.Y) * s.Y + math.abs(l.Y) * s.Z) / 2
		local hz = (math.abs(r.Z) * s.X + math.abs(u.Z) * s.Y + math.abs(l.Z) * s.Z) / 2
		local pos = cf.Position
		minX, maxX = math.min(minX, pos.X - hx), math.max(maxX, pos.X + hx)
		minY, maxY = math.min(minY, pos.Y - hy), math.max(maxY, pos.Y + hy)
		minZ, maxZ = math.min(minZ, pos.Z - hz), math.max(maxZ, pos.Z + hz)
		any = true
	end
	if not any then
		return nil, nil
	end
	return Vector3.new((minX + maxX) / 2, (minY + maxY) / 2, (minZ + maxZ) / 2),
		Vector3.new(maxX - minX, maxY - minY, maxZ - minZ)
end

--------------------------------------------------------------------
-- 4. RAYCAST TANAH
--------------------------------------------------------------------
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.RespectCanCollide = true

local function refreshRayFilter()
	local list = { hud }
	local char = player.Character
	if char then
		table.insert(list, char)
	end
	for _, p in ipairs(car.parts) do
		table.insert(list, p)
	end
	for inst in pairs(candidates) do
		table.insert(list, inst)
	end
	rayParams.FilterDescendantsInstances = list
end

local function castGround(x, z, fromY)
	local r = Workspace:Raycast(
		Vector3.new(x, fromY, z),
		Vector3.new(0, -CONFIG.GROUND_RAY_LENGTH, 0),
		rayParams
	)
	return r and r.Position.Y or nil
end

--------------------------------------------------------------------
-- 5. LANGKAH 2: KECEPATAN MOBIL
--------------------------------------------------------------------
local function updateCar(now, dt)
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local seat = hum and hum.SeatPart
	local part

	if seat then
		part = seat
		car.inVehicle = true
		car.parts = seat:GetConnectedParts(true)
	else
		part = char and char:FindFirstChild("HumanoidRootPart")
		car.inVehicle = false
		car.parts = {}
	end

	car.part = part
	if not part then
		return
	end

	local p = part.Position
	car.pos = p
	table.insert(car.samples, { t = now, x = p.X, z = p.Z })
	prune(car.samples, now, CONFIG.CAR_WINDOW)

	-- kecepatan dari turunan posisi (regresi) dan dari fisika; pakai fisika jika valid
	local posVel = Vector3.new(slope(car.samples, "x"), 0, slope(car.samples, "z"))
	local phys = flat(part.AssemblyLinearVelocity)
	car.vel = (phys.Magnitude > 0.5) and phys or posVel
	car.speed = car.vel.Magnitude

	-- kecepatan rencana: rata-rata halus, tidak boleh di bawah minimum
	if not car.emaInit then
		car.ema = car.speed
		car.emaInit = true
	else
		car.ema += (car.speed - car.ema) * (1 - math.exp(-dt / CONFIG.CAR_SMOOTH_TAU))
	end
	car.planSpeed = math.max(car.ema, CONFIG.MIN_PLAN_SPEED)
end

--------------------------------------------------------------------
-- 6. LANGKAH 1 & 4: TRACKING TORNADO (kecepatan, arah, touchdown, ukuran)
--------------------------------------------------------------------
local function updateTornado(g, now)
	local center, size = measure(g)
	if not center then
		return
	end
	local inst = g.model or g.parts[1]

	local rec = tracks[g.key]
	if not rec then
		rec = { inst = g.key, id = nextId, name = inst.Name, samples = {}, peakWidth = 0, ready = false }
		nextId += 1
		tracks[g.key] = rec
	end

	local width = math.max(size.X, size.Z)
	local height = size.Y
	local baseY = center.Y - height / 2
	local topY = center.Y + height / 2

	local gy = castGround(center.X, center.Z, baseY + 60) or castGround(center.X, center.Z, topY + 300)
	local clearance = gy and (baseY - gy) or nil

	rec.pos = center
	rec.width, rec.height = width, height
	rec.baseY, rec.topY = baseY, topY
	rec.groundY = gy
	rec.clearance = clearance
	rec.sampleTime = now

	local samples = rec.samples
	table.insert(samples, { t = now, x = center.X, z = center.Z, w = width, c = clearance })
	prune(samples, now, CONFIG.TORNADO_WINDOW)

	local n = #samples
	rec.ready = n >= 5 and (samples[n].t - samples[1].t) >= CONFIG.MIN_SPAN

	-- Kecepatan & arah gerak
	local rawVel = Vector3.new(slope(samples, "x"), 0, slope(samples, "z"))
	if rec.ready then
		if rec.velS == nil then
			rec.velS = rawVel
		else
			rec.velS = rec.velS:Lerp(rawVel, 0.12) -- peredam: arah berubah pelan, tidak goyang
		end
	end
	rec.vel = rec.velS or Vector3.zero
	rec.speed = rec.vel.Magnitude
	rec.heading = (rec.speed >= CONFIG.MIN_MOVE_SPEED) and bearingOf(rec.vel) or nil

	-- Ukuran & potensi terbesar
	rec.peakWidth = math.max(rec.peakWidth, width)
	rec.widthRate = slope(samples, "w")
	local projected = width + clamp(rec.widthRate * CONFIG.GROWTH_HORIZON, -width, width * 2)
	rec.potentialWidth = math.max(width, rec.peakWidth, projected)

	-- Touchdown
	rec.clearanceRate = slope(samples, "c")
	local attr = inst:GetAttribute(CONFIG.TOUCHDOWN_ATTRIBUTE)
	local grounded
	if typeof(attr) == "boolean" then
		grounded = attr
	elseif clearance then
		grounded = clearance <= CONFIG.TOUCHDOWN_CLEARANCE
	end
	rec.grounded = grounded
	rec.tdETA = nil

	if grounded then
		rec.tdProb, rec.tdText = 1, "SUDAH DI TANAH"
	elseif grounded == nil then
		rec.tdProb, rec.tdText = nil, "Tanah tidak terdeteksi"
	else
		local rate = rec.clearanceRate
		if clearance and rec.ready and rate < -0.05 then
			rec.tdETA = (clearance - CONFIG.TOUCHDOWN_CLEARANCE) / -rate
			rec.tdProb = clamp(1 - rec.tdETA / CONFIG.TOUCHDOWN_HORIZON, 0.05, 0.95)
			rec.tdText = "TURUN dalam ~" .. fmtTime(rec.tdETA)
		elseif rate > 0.05 then
			rec.tdProb, rec.tdText = 0, "NAIK / MENGHILANG"
		else
			rec.tdProb, rec.tdText = 0.05, "TETAP DI UDARA"
		end
	end
end

--------------------------------------------------------------------
-- 7. LANGKAH 3: HITUNG TITIK INTERCEPT
--   Cari t (waktu tempuh mobil) sehingga:
--     posisi tornado pada (t + buffer) berjarak speed * t dari mobil.
--   P = Ttornado + V * (t + buffer),   |P - Cmobil| = s * t
--   -> persamaan kuadrat: (V.V - s^2) t^2 + 2 (D.V) t + D.D = 0
--      dengan D = Ttornado + V*buffer - Cmobil
--------------------------------------------------------------------
local function solveIntercept(carPos, carSpeed, tPos, tVel, buffer)
	local V = flat(tVel)
	local D = flat(tPos) + V * buffer - flat(carPos)
	local a = V:Dot(V) - carSpeed * carSpeed
	local b = 2 * D:Dot(V)
	local c = D:Dot(D)
	local t

	if math.abs(a) < 1e-6 then
		if math.abs(b) < 1e-9 then
			if c < 1e-6 then t = 0 end
		else
			local r = -c / b
			if r >= 0 then t = r end
		end
	else
		local disc = b * b - 4 * a * c
		if disc >= 0 then
			local sq = math.sqrt(disc)
			local r1, r2 = (-b - sq) / (2 * a), (-b + sq) / (2 * a)
			if r1 > r2 then r1, r2 = r2, r1 end
			if r1 >= 0 then
				t = r1
			elseif r2 >= 0 then
				t = r2
			end
		end
	end

	if not t then
		return { ok = false }
	end

	local point = flat(tPos) + V * (t + buffer)
	return {
		ok = true,
		tCar = t,
		tTornado = t + buffer,
		point = point,
		dist = (point - flat(carPos)).Magnitude,
	}
end

--------------------------------------------------------------------
-- 8. UI
--------------------------------------------------------------------
local COLORS = {
	bg = Color3.fromRGB(14, 18, 26),
	line = Color3.fromRGB(60, 72, 92),
	text = Color3.fromRGB(235, 240, 248),
	dim = Color3.fromRGB(140, 152, 172),
	accent = Color3.fromRGB(255, 170, 40),
	good = Color3.fromRGB(90, 225, 140),
	bad = Color3.fromRGB(255, 95, 95),
	cyan = Color3.fromRGB(80, 200, 255),
	purple = Color3.fromRGB(190, 120, 255),
}

local screen = new("ScreenGui", {
	Name = "TornadoInterceptUI",
	ResetOnSpawn = false,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	DisplayOrder = 20,
}, playerGui)

local ui = {}

-- Panel info (kiri atas)
local panel = new("Frame", {
	Name = "Panel",
	Position = UDim2.fromOffset(12, 12),
	Size = UDim2.fromOffset(320, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundColor3 = COLORS.bg,
	BackgroundTransparency = 0.12,
	BorderSizePixel = 0,
}, screen)
new("UICorner", { CornerRadius = UDim.new(0, 10) }, panel)
new("UIStroke", { Color = COLORS.line, Thickness = 1 }, panel)
new("UIPadding", {
	PaddingTop = UDim.new(0, 8),
	PaddingBottom = UDim.new(0, 8),
	PaddingLeft = UDim.new(0, 10),
	PaddingRight = UDim.new(0, 10),
}, panel)
new("UIListLayout", { Padding = UDim.new(0, 3), SortOrder = Enum.SortOrder.LayoutOrder }, panel)

local order = 0
local function nextOrder()
	order += 1
	return order
end

local function header(text)
	return new("TextLabel", {
		Size = UDim2.new(1, 0, 0, 22),
		BackgroundTransparency = 1,
		Text = text,
		Font = Enum.Font.GothamBold,
		TextSize = 12,
		TextColor3 = COLORS.accent,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		LayoutOrder = nextOrder(),
	}, panel)
end

local function row(label)
	local f = new("Frame", {
		Size = UDim2.new(1, 0, 0, 18),
		BackgroundTransparency = 1,
		LayoutOrder = nextOrder(),
	}, panel)
	new("TextLabel", {
		Size = UDim2.new(0.36, 0, 1, 0),
		BackgroundTransparency = 1,
		Text = label,
		Font = Enum.Font.Gotham,
		TextSize = 13,
		TextColor3 = COLORS.dim,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, f)
	return new("TextLabel", {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 0),
		Size = UDim2.new(0.64, 0, 1, 0),
		BackgroundTransparency = 1,
		Text = "-",
		Font = Enum.Font.GothamMedium,
		TextSize = 13,
		TextColor3 = COLORS.text,
		TextXAlignment = Enum.TextXAlignment.Right,
		TextTruncate = Enum.TextTruncate.AtEnd,
	}, f)
end

-- Judul + tombol mode target
local titleRow = new("Frame", {
	Size = UDim2.new(1, 0, 0, 26),
	BackgroundTransparency = 1,
	LayoutOrder = nextOrder(),
}, panel)
new("TextLabel", {
	Size = UDim2.new(0.5, 0, 1, 0),
	BackgroundTransparency = 1,
	Text = "TORNADO INTERCEPT",
	Font = Enum.Font.GothamBold,
	TextSize = 14,
	TextColor3 = COLORS.text,
	TextXAlignment = Enum.TextXAlignment.Left,
}, titleRow)
ui.modeBtn = new("TextButton", {
	AnchorPoint = Vector2.new(1, 0.5),
	Position = UDim2.new(1, 0, 0.5, 0),
	Size = UDim2.fromOffset(124, 22),
	BackgroundColor3 = COLORS.line,
	Text = "Target: Terbesar",
	Font = Enum.Font.GothamMedium,
	TextSize = 12,
	TextColor3 = COLORS.text,
}, titleRow)
new("UICorner", { CornerRadius = UDim.new(0, 6) }, ui.modeBtn)

header("TORNADO (TARGET)")
ui.tName = row("Target")
ui.tSpeed = row("Kecepatan gerak")
ui.tDir = row("Arah gerak")
ui.tSize = row("Ukuran")

header("MOBIL")
ui.cSpeed = row("Kecepatan")
ui.cPlan = row("Kec. rencana")

ui.iHeader = header("INTERCEPT")
ui.iDist = row("Jarak titik")
ui.iCar = row("Mobil tiba")
ui.iTor = row("Tornado tiba")
ui.iPos = row("Koordinat")

header("TOUCHDOWN")
ui.dStat = row("Status")
ui.dProb = row("Peluang turun")
ui.dInfo = row("Dasar corong")

header("TORNADO TERBESAR")
ui.bName = row("Kandidat")
ui.bSize = row("Lebar")
ui.bInfo = row("Kelas")

-- Grup kanan (kompas + radar)
local RADAR_SIZE = 220
local HALF = RADAR_SIZE / 2
local COMPASS_SIZE = 104
local CC = COMPASS_SIZE / 2

local rightGroup = new("Frame", {
	AnchorPoint = Vector2.new(1, 0.5),
	Position = UDim2.new(1, -12, 0.5, 0),
	Size = UDim2.fromOffset(RADAR_SIZE, COMPASS_SIZE + 8 + RADAR_SIZE),
	BackgroundTransparency = 1,
}, screen)
new("UIListLayout", {
	Padding = UDim.new(0, 8),
	SortOrder = Enum.SortOrder.LayoutOrder,
	HorizontalAlignment = Enum.HorizontalAlignment.Center,
}, rightGroup)

-- Kompas
local compass = new("Frame", {
	Size = UDim2.fromOffset(COMPASS_SIZE, COMPASS_SIZE),
	BackgroundColor3 = COLORS.bg,
	BackgroundTransparency = 0.12,
	BorderSizePixel = 0,
	LayoutOrder = 1,
}, rightGroup)
new("UICorner", { CornerRadius = UDim.new(1, 0) }, compass)
new("UIStroke", { Color = COLORS.line, Thickness = 1 }, compass)

ui.compassText = new("TextLabel", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromOffset(44, 30),
	BackgroundTransparency = 1,
	Text = "--",
	Font = Enum.Font.GothamBold,
	TextSize = 12,
	TextColor3 = COLORS.text,
}, compass)
ui.compassPointer = new("TextLabel", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Size = UDim2.fromOffset(24, 24),
	BackgroundTransparency = 1,
	Text = "▲",
	Font = Enum.Font.GothamBold,
	TextSize = 22,
	TextColor3 = COLORS.accent,
	Visible = false,
}, compass)
ui.compassNorth = new("TextLabel", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Size = UDim2.fromOffset(16, 16),
	BackgroundTransparency = 1,
	Text = "U",
	Font = Enum.Font.GothamBold,
	TextSize = 13,
	TextColor3 = COLORS.bad,
}, compass)

-- Radar (atas = arah kamera)
local radar = new("Frame", {
	Name = "Radar",
	Size = UDim2.fromOffset(RADAR_SIZE, RADAR_SIZE),
	BackgroundColor3 = Color3.fromRGB(10, 16, 22),
	BackgroundTransparency = 0.1,
	BorderSizePixel = 0,
	ClipsDescendants = true,
	LayoutOrder = 2,
}, rightGroup)
new("UICorner", { CornerRadius = UDim.new(0, 10) }, radar)
new("UIStroke", { Color = COLORS.line, Thickness = 1 }, radar)

local function ring(scale)
	local r = new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(scale, scale),
		BackgroundTransparency = 1,
	}, radar)
	new("UICorner", { CornerRadius = UDim.new(1, 0) }, r)
	new("UIStroke", { Color = COLORS.line, Transparency = 0.4, Thickness = 1 }, r)
end
ring(0.5)
ring(1)

local function uiLine(color, thickness)
	return new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(2, thickness),
		ZIndex = 2,
		Visible = false,
	}, radar)
end
ui.routeLine = uiLine(COLORS.cyan, 1)
ui.trackLine = uiLine(COLORS.accent, 2)

ui.icptDot = new("Frame", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Size = UDim2.fromOffset(12, 12),
	BackgroundColor3 = COLORS.good,
	BorderSizePixel = 0,
	ZIndex = 4,
	Visible = false,
}, radar)

new("TextLabel", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromOffset(18, 18),
	BackgroundTransparency = 1,
	Text = "▲",
	Font = Enum.Font.GothamBold,
	TextSize = 16,
	TextColor3 = COLORS.text,
	ZIndex = 5,
}, radar)

ui.rangeLbl = new("TextLabel", {
	AnchorPoint = Vector2.new(0, 1),
	Position = UDim2.new(0, 6, 1, -4),
	Size = UDim2.fromOffset(80, 14),
	BackgroundTransparency = 1,
	Text = "",
	Font = Enum.Font.Gotham,
	TextSize = 11,
	TextColor3 = COLORS.dim,
	TextXAlignment = Enum.TextXAlignment.Left,
	ZIndex = 5,
}, radar)

local function zoomButton(text, x, delta)
	local b = new("TextButton", {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, x, 0, 6),
		Size = UDim2.fromOffset(24, 22),
		BackgroundColor3 = COLORS.line,
		Text = text,
		Font = Enum.Font.GothamBold,
		TextSize = 14,
		TextColor3 = COLORS.text,
		ZIndex = 6,
	}, radar)
	new("UICorner", { CornerRadius = UDim.new(0, 5) }, b)
	b.MouseButton1Click:Connect(function()
		radarIdx = clamp(radarIdx + delta, 1, #RADAR_RANGES)
	end)
end
zoomButton("+", -34, -1) -- zoom in = jangkauan lebih kecil
zoomButton("−", -6, 1)

local radarDots = {}
local function makeDot(rec)
	local dot = new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(10, 10),
		BackgroundColor3 = COLORS.bad,
		BorderSizePixel = 0,
		ZIndex = 3,
	}, radar)
	new("UICorner", { CornerRadius = UDim.new(1, 0) }, dot)
	new("TextLabel", {
		Position = UDim2.new(1, 2, 0, -4),
		Size = UDim2.fromOffset(24, 12),
		BackgroundTransparency = 1,
		Text = "#" .. rec.id,
		Font = Enum.Font.GothamBold,
		TextSize = 10,
		TextColor3 = COLORS.text,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, dot)
	return dot
end

ui.modeBtn.MouseButton1Click:Connect(function()
	mode = (mode == "BIGGEST") and "NEAREST" or "BIGGEST"
	state.target = nil
	ui.modeBtn.Text = (mode == "BIGGEST") and "Target: Terbesar" or "Target: Terdekat"
end)

--------------------------------------------------------------------
-- 9. PENANDA 3D DI DUNIA GAME (hanya terlihat oleh pemain ini)
--------------------------------------------------------------------
local PILLAR_H = 250

local function mkPart(name, color, transparency, shape)
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	p.Color = color
	p.Transparency = transparency
	p.Size = Vector3.one
	if shape then
		p.Shape = shape
	end
	return p
end

local function show(part, visible)
	part.Parent = visible and hud or nil
end

local function mkBillboard(adornee, color, offsetY, w, h)
	local bb = new("BillboardGui", {
		Adornee = adornee,
		AlwaysOnTop = true,
		Size = UDim2.fromOffset(w, h),
		StudsOffset = Vector3.new(0, offsetY, 0),
		LightInfluence = 0,
	}, adornee)
	return new("TextLabel", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		TextSize = 14,
		TextColor3 = color,
		TextStrokeTransparency = 0.35,
		TextStrokeColor3 = Color3.new(0, 0, 0),
		TextWrapped = true,
		Text = "",
	}, bb)
end

local pillar = mkPart("HUD_Pillar", COLORS.good, 0.35)
local disk = mkPart("HUD_Disk", COLORS.good, 0.4, Enum.PartType.Cylinder)
local routeLine = mkPart("HUD_Route", COLORS.cyan, 0.55)
local trackLine = mkPart("HUD_Track", COLORS.accent, 0.2)
local headL = mkPart("HUD_HeadL", COLORS.accent, 0.2)
local headR = mkPart("HUD_HeadR", COLORS.accent, 0.2)
local tagTarget = mkPart("HUD_TagA", COLORS.accent, 1)
local tagBiggest = mkPart("HUD_TagB", COLORS.purple, 1)

local lblPillar = mkBillboard(pillar, COLORS.good, PILLAR_H / 2 + 6, 240, 44)
local lblTarget = mkBillboard(tagTarget, COLORS.accent, 0, 240, 56)
local lblBiggest = mkBillboard(tagBiggest, COLORS.purple, 0, 240, 56)

local function setLine(part, a, b, thickness)
	local len = (b - a).Magnitude
	if len < 0.1 then
		return
	end
	part.Size = Vector3.new(thickness, thickness, len)
	part.CFrame = CFrame.lookAt((a + b) / 2, b)
end

--------------------------------------------------------------------
-- 10. UPDATE TEKS (dipanggil setiap sampling)
--------------------------------------------------------------------
local function setRows(rows, text)
	for _, r in ipairs(rows) do
		r.Text = text
		r.TextColor3 = COLORS.text
	end
end

local function updateTexts()
	local tg, bg, ic = state.target, state.biggest, state.icpt

	ui.cSpeed.Text = fmtSpeed(car.speed) .. (car.inVehicle and "" or "  (jalan kaki)")
	ui.cPlan.Text = fmtSpeed(car.planSpeed)
	ui.iHeader.Text = string.format("INTERCEPT  (tornado tiba = mobil + %s)", fmtTime(CONFIG.INTERCEPT_BUFFER))

	if not tg then
		ui.tName.Text = "Tornado tidak ditemukan"
		ui.tName.TextColor3 = COLORS.bad
		setRows({ ui.tSpeed, ui.tDir, ui.tSize, ui.iDist, ui.iCar, ui.iTor, ui.iPos, ui.dStat, ui.dProb, ui.dInfo, ui.bName, ui.bSize, ui.bInfo }, "-")
		ui.compassText.Text = "--"
		lblPillar.Text, lblTarget.Text, lblBiggest.Text = "", "", ""
		return
	end

	-- Target
	ui.tName.Text = string.format("#%d %s", tg.id, tg.name)
	ui.tName.TextColor3 = COLORS.accent
	if not tg.ready then
		ui.tSpeed.Text = "mengukur..."
		ui.tDir.Text = "mengukur..."
	else
		ui.tSpeed.Text = fmtSpeed(tg.speed)
		if tg.heading then
			ui.tDir.Text = string.format("%s  (%d°)", windName(tg.heading), math.floor(tg.heading + 0.5))
		else
			ui.tDir.Text = "diam"
		end
	end
	ui.tSize.Text = string.format("%s × %s", fmtDist(tg.width), fmtDist(tg.height))
	ui.compassText.Text = tg.heading and string.format("%s\n%d°", windName(tg.heading), math.floor(tg.heading + 0.5)) or "--"

	-- Intercept
	local icText = ""
	if ic and ic.ok then
		local P = ic.point
		ui.iDist.Text = fmtDist(ic.dist)
		ui.iCar.Text = fmtTime(ic.tCar)
		ui.iTor.Text = fmtTime(ic.tTornado)
		ui.iPos.Text = string.format("X %d   Z %d", math.floor(P.X + 0.5), math.floor(P.Z + 0.5))
		ui.iDist.TextColor3 = COLORS.good
		icText = string.format("INTERCEPT\n%s • tiba %s", fmtDist(ic.dist), fmtTime(ic.tCar))
	elseif ic then
		ui.iDist.Text = "Tidak bisa dicegat"
		ui.iDist.TextColor3 = COLORS.bad
		ui.iCar.Text, ui.iTor.Text, ui.iPos.Text = "-", "-", "-"
	else
		ui.iDist.Text = "menunggu data tornado..."
		ui.iDist.TextColor3 = COLORS.dim
		ui.iCar.Text, ui.iTor.Text, ui.iPos.Text = "-", "-", "-"
	end
	lblPillar.Text = icText

	-- Touchdown
	ui.dStat.Text = tg.tdText or "-"
	ui.dStat.TextColor3 = tg.grounded and COLORS.bad or (tg.tdETA and COLORS.accent or COLORS.good)
	if tg.tdProb then
		local extra = ""
		if ic and ic.ok and tg.tdETA then
			extra = (tg.tdETA <= ic.tTornado) and "  • sebelum tiba" or "  • setelah tiba"
		end
		ui.dProb.Text = string.format("%d%%%s", math.floor(tg.tdProb * 100 + 0.5), extra)
	else
		ui.dProb.Text = "-"
	end
	if tg.clearance then
		ui.dInfo.Text = string.format("%s  (%+.1f m/s)", fmtDist(math.max(0, tg.clearance)), toMeters(tg.clearanceRate))
	else
		ui.dInfo.Text = "-"
	end

	-- Tornado terbesar
	if bg then
		ui.bName.Text = string.format("#%d %s%s", bg.id, bg.name, bg == tg and "  (= target)" or "")
		ui.bName.TextColor3 = COLORS.purple
		ui.bSize.Text = string.format("%s → potensi %s", fmtDist(bg.width), fmtDist(bg.potentialWidth))
		ui.bInfo.Text = sizeClass(bg.potentialWidth) .. (bg.grounded and "  • di tanah" or "")
	end

	-- Label 3D
	local function tagText(rec, title)
		local spd = rec.ready and fmtSpeed(rec.speed) or "..."
		local dir = rec.heading and windName(rec.heading) or "-"
		return string.format("%s #%d\n%s • %s\nLebar %s", title, rec.id, spd, dir, fmtDist(rec.width))
	end
	lblTarget.Text = tagText(tg, "TARGET")
	lblBiggest.Text = (bg and bg ~= tg) and tagText(bg, "TERBESAR") or ""
end

--------------------------------------------------------------------
-- 11. SIKLUS SAMPLING
--------------------------------------------------------------------
local function sample(now, dt)
	updateCar(now, dt)
	refreshCandidates()
	refreshRayFilter()

	local groups = buildGroups()
	for _, g in pairs(groups) do
		updateTornado(g, now)
	end

	local list = {}
	for key, rec in pairs(tracks) do
		if groups[key] then
			table.insert(list, rec)
		else
			tracks[key] = nil
		end
	end
	table.sort(list, function(a, b) return a.id < b.id end)
	state.list = list

	-- Cari tornado terbesar & terdekat
	local biggest, nearest
	local bestW, bestD = -1, math.huge
	for _, rec in ipairs(list) do
		if rec.potentialWidth > bestW then
			bestW = rec.potentialWidth
			biggest = rec
		end
		local d = (flat(rec.pos) - flat(car.pos)).Magnitude
		rec.distance = d
		if d < bestD then
			bestD = d
			nearest = rec
		end
	end
	state.biggest = biggest

	-- Kunci target: pindah hanya jika kandidat baru jauh lebih besar / lebih dekat
	local pick = (mode == "BIGGEST") and biggest or nearest
	local cur = state.target
	if cur and pick and pick ~= cur and tracks[cur.inst] == cur and groups[cur.inst] then
		local better
		if mode == "BIGGEST" then
			better = pick.potentialWidth > cur.potentialWidth * 1.3
		else
			better = pick.distance < cur.distance * 0.7
		end
		if not better then
			pick = cur
		end
	end
	state.target = pick

	-- Intercept untuk target
	local icpt = nil
	local tg = state.target
	if tg and tg.ready then
		icpt = solveIntercept(car.pos, car.planSpeed, tg.pos, tg.vel, CONFIG.INTERCEPT_BUFFER)
		if icpt.ok then
			-- Titik dikunci: hanya bergeser kalau selisih baru cukup besar, itupun pelan-pelan
			local flatP = icpt.point
			local prev = state.icptFlat
			if prev and state.icptTarget == tg then
				local jump = (flatP - prev).Magnitude
				if jump < math.max(40, icpt.dist * 0.03) then
					flatP = prev
				else
					flatP = prev:Lerp(flatP, 0.25)
				end
			end
			state.icptFlat = flatP
			state.icptTarget = tg

			local gy = castGround(flatP.X, flatP.Z, car.pos.Y + 500) or car.pos.Y
			icpt.point = Vector3.new(flatP.X, gy, flatP.Z)
			icpt.dist = (flatP - flat(car.pos)).Magnitude
			icpt.tCar = icpt.dist / car.planSpeed
			icpt.tTornado = icpt.tCar + CONFIG.INTERCEPT_BUFFER
		end
	end
	if not (icpt and icpt.ok) then
		state.icptFlat = nil
	end
	state.icpt = icpt

	updateTexts()
end

--------------------------------------------------------------------
-- 12. RENDER (tiap frame): radar, kompas, penanda 3D
--------------------------------------------------------------------
local function livePos(rec, now)
	local dt = clamp(now - rec.sampleTime, 0, 0.5)
	return rec.pos + flat(rec.vel) * dt
end

local function setUiLine(line, x1, y1, x2, y2)
	local dx, dy = x2 - x1, y2 - y1
	local len = math.sqrt(dx * dx + dy * dy)
	if len < 1 then
		line.Visible = false
		return
	end
	if len > 800 then
		x2, y2 = x1 + dx * 800 / len, y1 + dy * 800 / len
		len = 800
	end
	line.Visible = true
	line.Size = UDim2.fromOffset(len, line.Size.Y.Offset)
	line.Position = UDim2.fromOffset((x1 + x2) / 2, (y1 + y2) / 2)
	line.Rotation = math.deg(math.atan2(dy, dx))
end

local function render()
	local cam = Workspace.CurrentCamera
	if not cam or not screen.Enabled then
		return
	end
	local now = os.clock()

	local cf = cam.CFrame
	local look = flat(cf.LookVector)
	if look.Magnitude < 0.05 then
		look = flat(cf.UpVector)
	end
	look = look.Unit
	local right = Vector3.new(-look.Z, 0, look.X)

	local part = car.part
	local cpos = (part and part.Parent) and part.Position or car.pos
	local tg, bg, ic = state.target, state.biggest, state.icpt

	-- ===== Radar =====
	local range = RADAR_RANGES[radarIdx]
	local scale = HALF / range
	ui.rangeLbl.Text = "R " .. fmtDist(range)

	local function place(dot, rel)
		local x = rel:Dot(right) * scale
		local y = -rel:Dot(look) * scale
		local limit = HALF - 8
		local m = math.max(math.abs(x), math.abs(y))
		local clipped = m > limit
		if clipped then
			x, y = x * limit / m, y * limit / m
		end
		dot.Position = UDim2.fromOffset(HALF + x, HALF + y)
		dot.BackgroundTransparency = clipped and 0.55 or 0
	end

	for inst, dot in pairs(radarDots) do
		if not tracks[inst] then
			dot:Destroy()
			radarDots[inst] = nil
		end
	end
	for _, rec in ipairs(state.list) do
		local dot = radarDots[rec.inst]
		if not dot then
			dot = makeDot(rec)
			radarDots[rec.inst] = dot
		end
		local isTarget, isBig = rec == tg, rec == bg
		dot.BackgroundColor3 = isTarget and COLORS.accent or (isBig and COLORS.purple or COLORS.bad)
		local sz = isTarget and 14 or 10
		dot.Size = UDim2.fromOffset(sz, sz)
		place(dot, livePos(rec, now) - cpos)
	end

	-- garis jalur tornado target di radar
	if tg and tg.ready and tg.heading then
		local rel = livePos(tg, now) - cpos
		local x1 = HALF + rel:Dot(right) * scale
		local y1 = HALF - rel:Dot(look) * scale
		if math.abs(x1 - HALF) < HALF * 3 and math.abs(y1 - HALF) < HALF * 3 then
			local d = flat(tg.vel).Unit
			local L = math.min(800, tg.speed * CONFIG.TRACK_PREVIEW_SECONDS * scale)
			setUiLine(ui.trackLine, x1, y1, x1 + d:Dot(right) * L, y1 - d:Dot(look) * L)
		else
			ui.trackLine.Visible = false
		end
	else
		ui.trackLine.Visible = false
	end

	-- titik intercept di radar
	if ic and ic.ok then
		local rel = ic.point - cpos
		place(ui.icptDot, rel)
		ui.icptDot.Visible = true
		local x = HALF + rel:Dot(right) * scale
		local y = HALF - rel:Dot(look) * scale
		setUiLine(ui.routeLine, HALF, HALF, x, y)
	else
		ui.icptDot.Visible = false
		ui.routeLine.Visible = false
	end

	-- ===== Kompas =====
	local nth = math.atan2(NORTH_VEC:Dot(right), NORTH_VEC:Dot(look))
	ui.compassNorth.Position = UDim2.fromOffset(CC + math.sin(nth) * 44, CC - math.cos(nth) * 44)
	if tg and tg.ready and tg.heading then
		local d = flat(tg.vel).Unit
		local th = math.atan2(d:Dot(right), d:Dot(look))
		ui.compassPointer.Visible = true
		ui.compassPointer.Rotation = math.deg(th)
		ui.compassPointer.Position = UDim2.fromOffset(CC + math.sin(th) * 28, CC - math.cos(th) * 28)
	else
		ui.compassPointer.Visible = false
	end

	-- ===== Penanda 3D =====
	-- titik intercept
	if ic and ic.ok then
		local P = ic.point
		local w = clamp(ic.dist * 0.01, 4, 30)
		pillar.Size = Vector3.new(w, PILLAR_H, w)
		pillar.CFrame = CFrame.new(P.X, P.Y + PILLAR_H / 2, P.Z)
		local dia = clamp(ic.dist * 0.02, 30, 140)
		disk.Size = Vector3.new(0.6, dia, dia)
		disk.CFrame = CFrame.new(P.X, P.Y + 0.5, P.Z) * CFrame.Angles(0, 0, math.rad(90))
		setLine(routeLine, Vector3.new(cpos.X, cpos.Y + 2, cpos.Z), Vector3.new(P.X, P.Y + 2, P.Z), 1.2)
		show(pillar, true)
		show(disk, true)
		show(routeLine, true)
	else
		show(pillar, false)
		show(disk, false)
		show(routeLine, false)
	end

	-- garis + panah arah gerak tornado
	if tg and tg.ready and tg.heading then
		local lp = livePos(tg, now)
		local gy = tg.groundY or cpos.Y
		local start = Vector3.new(lp.X, gy + 3, lp.Z)
		local dir = flat(tg.vel).Unit
		local len = clamp(tg.speed * CONFIG.TRACK_PREVIEW_SECONDS, 50, CONFIG.TRACK_MAX_STUDS)
		local tip = start + dir * len
		local thick = clamp(len / 400, 3, 10)
		setLine(trackLine, start, tip, thick)

		local headLen = clamp(len * 0.08, 20, 90)
		local tipCF = CFrame.lookAt(tip, tip + dir)
		headL.Size = Vector3.new(thick, thick, headLen)
		headR.Size = Vector3.new(thick, thick, headLen)
		headL.CFrame = tipCF * CFrame.Angles(0, math.rad(28), 0) * CFrame.new(0, 0, headLen / 2)
		headR.CFrame = tipCF * CFrame.Angles(0, math.rad(-28), 0) * CFrame.new(0, 0, headLen / 2)
		show(trackLine, true)
		show(headL, true)
		show(headR, true)
	else
		show(trackLine, false)
		show(headL, false)
		show(headR, false)
	end

	-- label di atas tornado (target & terbesar)
	if tg then
		local lp = livePos(tg, now)
		tagTarget.Position = Vector3.new(lp.X, tg.topY + 25, lp.Z)
		show(tagTarget, true)
	else
		show(tagTarget, false)
	end
	if bg and bg ~= tg then
		local lp = livePos(bg, now)
		tagBiggest.Position = Vector3.new(lp.X, bg.topY + 25, lp.Z)
		show(tagBiggest, true)
	else
		show(tagBiggest, false)
	end
end

--------------------------------------------------------------------
-- 13. INPUT & LOOP UTAMA
--------------------------------------------------------------------
UserInputService.InputBegan:Connect(function(input, processed)
	if processed then
		return
	end
	if input.KeyCode == Enum.KeyCode.H then
		local v = not screen.Enabled
		screen.Enabled = v
		hud.Parent = v and Workspace or nil
	end
end)

-- Deteksi tornado: event baru + scan awal (dipecah agar tidak lag)
Workspace.DescendantAdded:Connect(tryAdd)
task.spawn(function()
	local count = 0
	for _, d in ipairs(Workspace:GetDescendants()) do
		tryAdd(d)
		count += 1
		if count % 4000 == 0 then
			task.wait()
		end
	end
end)

local acc = 0
local lastWarn = 0
RunService.Heartbeat:Connect(function(dt)
	acc += dt
	if acc >= CONFIG.SAMPLE_INTERVAL then
		local step = acc
		acc = 0
		local ok, err = pcall(sample, os.clock(), step)
		if not ok and os.clock() - lastWarn > 5 then
			lastWarn = os.clock()
			warn("[TornadoIntercept] error:", err)
		end
	end
end)

RunService.RenderStepped:Connect(function()
	local ok, err = pcall(render)
	if not ok and os.clock() - lastWarn > 5 then
		lastWarn = os.clock()
		warn("[TornadoIntercept] render error:", err)
	end
end)
