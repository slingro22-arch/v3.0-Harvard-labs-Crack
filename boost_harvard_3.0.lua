-- =====================================================================
-- Harvard Labs v3.0 — Boost + Landing Detection wrapper
-- Upload as: boost_harvard_3.0.lua  (same repo as the original)
-- Load with:
--   loadstring(game:HttpGet(
--     "https://raw.githubusercontent.com/harvrdlabs/v3.0-Harvard-labs-Crack/refs/heads/main/boost_harvard_3.0.lua"))()
-- =====================================================================

local ORIGINAL_URL = "https://raw.githubusercontent.com/slingro22-arch/v3.0-Harvard-labs-Crack/refs/heads/main/leaked_harvard_3.0"

-- ============ Tuning =================================================
local BOOST       = 1.5     -- attack radius / reach / standoff multiplier
local DETECT_ONLY = true    -- only fire when the attack can actually land
local DETECT_HOLD = 0.2     -- stay "armed" this long after target leaves
local CACHE_HZ    = 15      -- detection recompute rate
local DRAW_HUD    = true    -- show detection ring in the world
-- =====================================================================

-- 1. Fetch the original ------------------------------------------------
local http = game:HttpGet
if type(http) ~= "function" and syn and syn.request then
    http = function(url) return syn.request({ Url = url, Method = "GET" }).Body end
elseif type(http) ~= "function" and request then
    http = function(url) return request({ Url = url, Method = "GET" }).Body end
end
if type(http) ~= "function" then error("[Boost] no HTTP fetch available") end

local source = http(ORIGINAL_URL)
if type(source) ~= "string" or #source < 1000 then
    error("[Boost] original fetch returned nothing (URL dead or blocked)")
end

local chunk, err = loadstring(source, "=HarvardOriginal")
if not chunk then error("[Boost] original failed to compile: " .. tostring(err)) end
chunk()   -- runs the whole original, builds context, starts farming

-- 2. Locate the live shared context ------------------------------------
local context
for _ = 1, 100 do
    for _, v in ipairs(getgc(true)) do
        if type(v) == "table"
            and type(rawget(v, "CFG")) == "table"
            and type(rawget(v, "RT"))  == "table"
            and type(v.CFG.aoeRadius)   == "number"
            and type(v.RT.farmEnabled)  == "boolean"
        then
            context = v; break
        end
    end
    if context then break end
    task.wait(0.1)
end
if not context then error("[Boost] context not found in getgc") end

local CFG, RT = context.CFG, context.RT
_G = _G or {}; getgenv = getgenv or function() return _G end

-- 3. Attack radius scale -----------------------------------------------
local KEYS = {
    "aoeRadius", "aoeDistance",
    "abilityRadius", "abilityRangeKnown",
    "aimReach", "attackRange",
    "castStartAt", "castProbe", "rangeMargin",
    "mobStandoff", "rangedStandoff",
    "bossStandoff", "mageStandoff",
    "odinIdleR", "hubKeepOut",
    "fieldReach", "fanRadius",
}

local function scale(t, m)
    for _, k in ipairs(KEYS) do
        if type(t[k]) == "number" then t[k] = t[k] * m end
    end
    if type(t.aoeKnown) == "table" then
        for _, entry in pairs(t.aoeKnown) do
            if type(entry) == "table" then
                for _, k in ipairs({ "x", "z", "place" }) do
                    if type(entry[k]) == "number" then entry[k] = entry[k] * m end
                end
            end
        end
    end
end

if type(context.PERSIST) == "table" then
    for i = #context.PERSIST, 1, -1 do
        for _, k in ipairs(KEYS) do
            if context.PERSIST[i] == k then table.remove(context.PERSIST, i) break end
        end
    end
end

scale(CFG, BOOST)

if type(context.applyClassProfile) == "function" then
    local orig = context.applyClassProfile
    context.applyClassProfile = function(...)
        local ok = orig(...); if ok then scale(CFG, BOOST) end; return ok
    end
end
if type(context.loadConfig) == "function" then
    local orig = context.loadConfig
    context.loadConfig = function(...)
        local ok = orig(...); if ok then scale(CFG, BOOST) end; return ok
    end
end

-- 4. Landing detection -------------------------------------------------
local cacheAt, cacheOK, cacheTgt = 0, false, nil
local lastHitAt, lastTgt = 0, nil

local function detectNow()
    if type(context.engageReady) ~= "function"
        or type(context.canHit)     ~= "function" then
        return true, nil
    end
    local me  = game:GetService("Players").LocalPlayer
    local hrp = me.Character and me.Character:FindFirstChild("HumanoidRootPart")
    local RD  = context.RD
    if not hrp or not RD or not RD.enemies then return false, nil end
    local pos = hrp.Position
    local best, bestD = nil, math.huge
    for _, enemy in ipairs(RD.enemies) do
        if enemy.root and enemy.root.Parent
            and enemy.humanoid and enemy.humanoid.Health > 0
            and enemy.x and enemy.z then
            local d = (enemy.x - pos.X)^2 + (enemy.z - pos.Z)^2
            if d < bestD then
                local inReach, covered = false, false
                pcall(function() inReach = context.engageReady(pos, enemy) end)
                if inReach then
                    pcall(function() covered = context.canHit(pos, enemy) end)
                    if covered then best, bestD = enemy, d end
                end
            end
        end
    end
    return best ~= nil, best
end

local function detection()
    local now = os.clock()
    if now - cacheAt < 1 / CACHE_HZ then return cacheOK, cacheTgt end
    cacheAt = now
    local ok, t = detectNow()
    if ok then lastHitAt, lastTgt = now, t
    elseif now - lastHitAt < DETECT_HOLD then ok, t = true, lastTgt end
    cacheOK, cacheTgt = ok, t
    return ok, t
end

local function detectionRange()
    local reach = (context.fireReach and context.fireReach()) or 40
    local rad = 0
    if context.aoeLanding then
        local ok, _, r = pcall(context.aoeLanding)
        if ok and type(r) == "number" then rad = r end
    end
    return reach + rad
end

-- 5. Gate casts (buffs skip the gate) ----------------------------------
local function gate(fn)
    if type(fn) ~= "function" then return fn end
    return function(slot, ...)
        if not fn(slot, ...) then return false end
        if not DETECT_ONLY then return true end
        if context.isBuffSlot and context.isBuffSlot(slot) then return true end
        return (detection())
    end
end
if type(context.gsSlotReady) == "function" then
    context.gsSlotReady = gate(context.gsSlotReady)
end
if type(context.slotReady) == "function" then
    context.slotReady = gate(context.slotReady)
end

-- 6. Public status + HUD ring ------------------------------------------
local status = { range = detectionRange(), canFire = false, target = nil, at = os.clock() }
getgenv().HLBoostStatus  = status
getgenv().HLBoostRange   = detectionRange
getgenv().HLBoostCanFire = detection

local hudPart
if DRAW_HUD and context.NOVIS ~= true then
    pcall(function()
        local folder = workspace:FindFirstChild("HLBoostHUD")
        if not folder then
            folder = Instance.new("Folder"); folder.Name = "HLBoostHUD"; folder.Parent = workspace
        end
        hudPart = folder:FindFirstChild("detectRange")
        if not hudPart then
            hudPart = Instance.new("Part")
            hudPart.Name, hudPart.Anchored          = "detectRange", true
            hudPart.CanCollide, hudPart.CanQuery    = false, false
            hudPart.CanTouch, hudPart.CastShadow    = false, false
            hudPart.Material, hudPart.Shape         = Enum.Material.Neon, Enum.PartType.Cylinder
            hudPart.Color, hudPart.Transparency     = Color3.fromRGB(80, 200, 255), 0.88
            hudPart.Size, hudPart.Parent            = Vector3.new(0.1, 2, 2), folder
        end
    end)
end

task.spawn(function()
    while not RT.destroyed do
        task.wait(0.1)
        local ok, target = detection()
        local range = detectionRange()
        status.at, status.range = os.clock(), range
        status.canFire, status.target = ok, target
        if hudPart and hudPart.Parent then
            local char = game:GetService("Players").LocalPlayer.Character
            local hrp  = char and char:FindFirstChild("HumanoidRootPart")
            if hrp then
                local d = range * 2
                hudPart.Size   = Vector3.new(0.1, d, d)
                hudPart.CFrame = CFrame.new(hrp.Position) * CFrame.Angles(0, 0, math.rad(90))
                hudPart.Color  = ok and Color3.fromRGB(80, 255, 120)
                                     or Color3.fromRGB(80, 200, 255)
            end
        end
    end
end)

print(("[Boost] loaded | x%.2f | detection %s | range ~%.0f studs")
    :format(BOOST, DETECT_ONLY and "ON" or "OFF", detectionRange()))
