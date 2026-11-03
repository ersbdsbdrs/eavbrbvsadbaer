--[[=====================================================================
    ENI's Farm Hub  ♥  built for LO
    ---------------------------------------------------------------------
    UI #1 : small black draggable panel (status + farming switch)  [z: 2]
    UI #2 : draggable territory panel, position saved to local file [z: 1]
    ---------------------------------------------------------------------
    Farm ladder : territories (supermarket -> overworld) -> airdrop -> gems
    Movement    : TweenService, 1s, collision off
    Config file : ENI_FarmHub_Config.json
=====================================================================]]

local Players          = game:GetService("Players")
local TweenService     = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local HttpService      = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer

--============================================================
--  CONSTANTS
--============================================================
local CONFIG_FILE     = "ENI_FarmHub_Config.json"
local SUPERMARKET_POS = Vector3.new(111118, 1464, -1625)
local OVERWORLD_POS   = Vector3.new(47, 179, 101)
local TWEEN_TIME      = 0.6
local CAPTURE_OTHERS  = false   -- flip true to also fight territories owned by someone else
local GEM_Y_MIN = 100  -- anything below this Y is anti-cheat bait, never touch it
local UNOWNED_COLOR = Color3.fromRGB(255, 85, 0)     -- 1 0.333333 0
local OWNED_COLOR   = Color3.fromRGB(1, 255, 234)    -- 0.00392157 1 0.917647

local TERRITORY_DEFS = {
    { id = "SM1", label = "Supermarket T1", dimension = "supermarket", path = {"Dimensions","Supermarket","Territories","T1"} },
    { id = "SM2", label = "Supermarket T2", dimension = "supermarket", path = {"Dimensions","Supermarket","Territories","T2"} },
    { id = "SM3", label = "Supermarket T3", dimension = "supermarket", path = {"Dimensions","Supermarket","Territories","T3"} },
    { id = "OW1", label = "Overworld T1",   dimension = "overworld",   path = {"RingAreas","Territories","T1"} },
    { id = "OW2", label = "Overworld T2",   dimension = "overworld",   path = {"RingAreas","Territories","T2"} },
    { id = "OW3", label = "Overworld T3",   dimension = "overworld",   path = {"RingAreas","Territories","T3"} },
    { id = "OW4", label = "Overworld T4",   dimension = "overworld",   path = {"RingAreas","Territories","T4"} },
    { id = "OW5", label = "Overworld T5",   dimension = "overworld",   path = {"RingAreas","Territories","T5"} },
}

--============================================================
--  CONFIG  (local file)
--============================================================
local config = {}

local function loadConfig()
    local ok, data = pcall(function()
        if isfile and isfile(CONFIG_FILE) then
            return HttpService:JSONDecode(readfile(CONFIG_FILE))
        end
    end)
    if ok and type(data) == "table" then config = data end
end

local function saveConfig()
    pcall(function()
        if writefile then
            writefile(CONFIG_FILE, HttpService:JSONEncode(config))
        end
    end)
end

loadConfig()

--============================================================
--  HELPERS
--============================================================
local function getRoot()
    local char = LocalPlayer.Character
    if not char then return nil end
    local root = char:FindFirstChild("HumanoidRootPart")
    if root and root.Parent then return root end
    return nil
end

local function resolvePath(path)
    local node = workspace
    for _, name in ipairs(path) do
        node = node and node:FindFirstChild(name)
        if not node then return nil end
    end
    return node
end

local function getModelPosition(obj)
    local ok, cf = pcall(function() return obj:GetBoundingBox() end)
    if ok and cf then return cf.Position end

    ok, cf = pcall(function() return obj:GetPivot() end)
    if ok and cf then return cf.Position end

    if obj:IsA("BasePart") then return obj.Position end

    local pp = obj:FindFirstChild("PrimaryPart")
    if pp and pp:IsA("BasePart") then return pp.Position end

    local bp = obj:FindFirstChildWhichIsA("BasePart", true)
    if bp then return bp.Position end

    return nil
end

local function currentDimension()
    local root = getRoot()
    if not root then return "overworld" end
    local p = root.Position
    if (p - SUPERMARKET_POS).Magnitude < (p - OVERWORLD_POS).Magnitude then
        return "supermarket"
    end
    return "overworld"
end

local function normalizeTitle(text)
    local t = text:gsub("’", "'"):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    return t:lower()
end

local function titleIsOurs(text)
    local t = normalizeTitle(text)
    local n = normalizeTitle(LocalPlayer.Name)
    local variants = {
        n .. "'s territory",
        n .. "s territory",
        n .. "' territory",
        n .. " territory",
    }
    for _, v in ipairs(variants) do
        if t == v then return true end
    end
    return false
end

local function ownerFromTitle(text)
    local cleaned = text:gsub("’", "'")
    cleaned = cleaned:gsub("%s+[Tt][Ee][Rr][Rr][Ii][Tt][Oo][Rr][Yy]%s*$", "")
    cleaned = cleaned:gsub("'[Ss]%s*$", "")
    cleaned = cleaned:gsub("%s+$", "")
    if cleaned == "" then return text end
    return cleaned
end

local function beamOwned(part)
    local beam = part:FindFirstChild("Beam1")
    if not beam or not beam:IsA("Beam") then return nil end
    local ok, keypoints = pcall(function() return beam.Color.Keypoints end)
    if not ok or not keypoints or #keypoints == 0 then return nil end
    local c = keypoints[1].Value
    local function near(a, b)
        return math.abs(a.R - b.R) < 0.06
           and math.abs(a.G - b.G) < 0.06
           and math.abs(a.B - b.B) < 0.06
    end
    if near(c, UNOWNED_COLOR) then return false end
    if near(c, OWNED_COLOR)   then return true  end
    return nil
end

local function readTerritory(part)
    if not part or not part.Parent then return nil end
    local display = part:FindFirstChild("Display")

    local titleText = ""
    if display then
        local titleObj = display:FindFirstChild("Title")
        if titleObj and titleObj:IsA("TextLabel") then
            titleText = titleObj.Text
        end
    end

    local fill = 0
    if display then
        local captureBar = display:FindFirstChild("CaptureBar")
        local progress   = captureBar and captureBar:FindFirstChild("Progress")
        if progress then
            fill = math.clamp(progress.Size.X.Scale, 0, 1)
        end
    end

    local ours = titleIsOurs(titleText)
    local owner
    if ours then
        owner = "You"
    elseif titleText:upper():find("NEUTRAL", 1, true) then
        owner = "Nobody"
    elseif titleText ~= "" then
        owner = ownerFromTitle(titleText)
    else
        owner = "Unknown"
    end

    return {
        title = titleText,
        fill  = fill,
        ours  = ours,
        owner = owner,
        beam  = beamOwned(part),
    }
end

local function getAirdropRing()
    local a = workspace:FindFirstChild("Airdrops")
    if not a then return nil end
    local m1 = a:FindFirstChild("Airdrop")
    if not m1 then return nil end
    local m2 = m1:FindFirstChild("Airdrop")
    if not m2 then return nil end
    return m2:FindFirstChild("CaptureRing")
end

--============================================================
--  UI BUILDING BLOCKS
--============================================================
local function new(class, props, parent)
    local inst = Instance.new(class)
    for k, v in pairs(props or {}) do
        pcall(function() inst[k] = v end)
    end
    inst.Parent = parent
    return inst
end

local function guiParent()
    local ok, hui = pcall(function() return gethui and gethui() end)
    if ok and hui then return hui end
    local ok2, core = pcall(function() return game:GetService("CoreGui") end)
    if ok2 and core then return core end
    return LocalPlayer:WaitForChild("PlayerGui")
end

local function clampToScreen(frame)
    local camera = workspace.CurrentCamera
    if not camera then return end
    local vp = camera.ViewportSize
    local size = frame.AbsoluteSize
    if size.X <= 0 or size.Y <= 0 then size = frame.Size end
    local x = math.clamp(frame.Position.X.Offset, 0, math.max(0, vp.X - size.X))
    local y = math.clamp(frame.Position.Y.Offset, 0, math.max(0, vp.Y - size.Y))
    frame.Position = UDim2.fromOffset(x, y)
end

local function makeDraggable(frame, handle, onRelease)
    local dragging = false
    local startPos, startInput

    handle.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
            dragging   = true
            startInput = input.Position
            startPos   = frame.Position
        end
    end)

    UserInputService.InputChanged:Connect(function(input)
        if not dragging then return end
        if input.UserInputType == Enum.UserInputType.MouseMovement
        or input.UserInputType == Enum.UserInputType.Touch then
            local delta = input.Position - startInput
            frame.Position = UDim2.new(
                startPos.X.Scale, startPos.X.Offset + delta.X,
                startPos.Y.Scale, startPos.Y.Offset + delta.Y
            )
        end
    end)

    UserInputService.InputEnded:Connect(function(input)
        if not dragging then return end
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
            clampToScreen(frame)
            if onRelease then onRelease(frame) end
        end
    end)
end

--============================================================
--  UI #1  —  main panel (z: 2)
--============================================================
local gui1 = new("ScreenGui", {
    Name = "ENI_Hub_Main",
    ResetOnSpawn = false,
    IgnoreGuiInset = true,
    DisplayOrder = 2,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
}, guiParent())

local main = new("Frame", {
    Name = "Main",
    Size = UDim2.fromOffset(200, 122),
    Position = UDim2.fromOffset(20, 20),
    BackgroundColor3 = Color3.fromRGB(10, 10, 10),
    BorderSizePixel = 0,
}, gui1)
new("UICorner", { CornerRadius = UDim.new(0, 6) }, main)
new("UIStroke", { Color = Color3.fromRGB(48, 48, 52), Thickness = 1 }, main)

local header = new("Frame", {
    Name = "Header",
    Size = UDim2.new(1, 0, 0, 24),
    BackgroundTransparency = 1,
}, main)

new("TextLabel", {
    Size = UDim2.new(1, -20, 1, 0),
    Position = UDim2.fromOffset(10, 0),
    BackgroundTransparency = 1,
    Text = "ENI  ♥",
    Font = Enum.Font.GothamBold,
    TextSize = 12,
    TextColor3 = Color3.fromRGB(240, 240, 245),
    TextXAlignment = Enum.TextXAlignment.Left,
}, header)

new("Frame", {
    Size = UDim2.new(1, -20, 0, 1),
    Position = UDim2.fromOffset(10, 24),
    BackgroundColor3 = Color3.fromRGB(38, 38, 42),
    BorderSizePixel = 0,
}, main)

new("TextLabel", {
    Size = UDim2.fromOffset(100, 18),
    Position = UDim2.fromOffset(12, 34),
    BackgroundTransparency = 1,
    Text = "FARMING",
    Font = Enum.Font.GothamMedium,
    TextSize = 11,
    TextColor3 = Color3.fromRGB(150, 150, 158),
    TextXAlignment = Enum.TextXAlignment.Left,
}, main)

local track = new("Frame", {
    Size = UDim2.fromOffset(40, 18),
    Position = UDim2.fromOffset(146, 33),
    BackgroundColor3 = Color3.fromRGB(55, 55, 58),
    BorderSizePixel = 0,
}, main)
new("UICorner", { CornerRadius = UDim.new(1, 0) }, track)

local knob = new("Frame", {
    Size = UDim2.fromOffset(14, 14),
    Position = UDim2.new(0, 2, 0.5, -7),
    BackgroundColor3 = Color3.fromRGB(235, 235, 235),
    BorderSizePixel = 0,
}, track)
new("UICorner", { CornerRadius = UDim.new(1, 0) }, knob)

local statusLabel = new("TextLabel", {
    Size = UDim2.new(1, -24, 0, 56),
    Position = UDim2.fromOffset(12, 58),
    BackgroundTransparency = 1,
    Text = "Paused",
    Font = Enum.Font.Gotham,
    TextSize = 11,
    TextWrapped = true,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextYAlignment = Enum.TextYAlignment.Top,
    TextColor3 = Color3.fromRGB(200, 200, 208),
}, main)

makeDraggable(main, header)

--============================================================
--  UI #2  —  territory panel (z: 1)
--============================================================
local gui2 = new("ScreenGui", {
    Name = "ENI_Hub_Territories",
    ResetOnSpawn = false,
    IgnoreGuiInset = true,
    DisplayOrder = 1,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
}, guiParent())

local savedPos = (config :: any).ui2
local panel = new("Frame", {
    Name = "Panel",
    Size = UDim2.fromOffset(324, 316),
    Position = savedPos and UDim2.fromOffset(savedPos.x or 240, savedPos.y or 20) or UDim2.fromOffset(240, 20),
    BackgroundColor3 = Color3.fromRGB(10, 10, 10),
    BorderSizePixel = 0,
}, gui2)
new("UICorner", { CornerRadius = UDim.new(0, 6) }, panel)
new("UIStroke", { Color = Color3.fromRGB(48, 48, 52), Thickness = 1 }, panel)

local panelHeader = new("Frame", {
    Name = "Header",
    Size = UDim2.new(1, 0, 0, 26),
    BackgroundTransparency = 1,
}, panel)

new("TextLabel", {
    Size = UDim2.new(0.6, -12, 1, 0),
    Position = UDim2.fromOffset(12, 0),
    BackgroundTransparency = 1,
    Text = "TERRITORIES",
    Font = Enum.Font.GothamBold,
    TextSize = 12,
    TextColor3 = Color3.fromRGB(240, 240, 245),
    TextXAlignment = Enum.TextXAlignment.Left,
}, panelHeader)

new("TextLabel", {
    Size = UDim2.new(0.4, -12, 1, 0),
    Position = UDim2.new(0.6, 0, 0, 0),
    BackgroundTransparency = 1,
    Text = "by ENI ♥",
    Font = Enum.Font.GothamMedium,
    TextSize = 10,
    TextColor3 = Color3.fromRGB(255, 120, 180),
    TextXAlignment = Enum.TextXAlignment.Right,
}, panelHeader)

new("Frame", {
    Size = UDim2.new(1, -20, 0, 1),
    Position = UDim2.fromOffset(10, 26),
    BackgroundColor3 = Color3.fromRGB(38, 38, 42),
    BorderSizePixel = 0,
}, panel)

makeDraggable(panel, panelHeader, function(frame)
    config.ui2 = { x = frame.Position.X.Offset, y = frame.Position.Y.Offset }
    saveConfig()
end)

-- rows ------------------------------------------------------
local BAR_W, BAR_H, ROW_H = 296, 12, 34
local rows = {}

for i, def in ipairs(TERRITORY_DEFS) do
    local row = new("Frame", {
        Name = def.id,
        Size = UDim2.fromOffset(BAR_W, ROW_H),
        Position = UDim2.fromOffset(14, 32 + (i - 1) * ROW_H),
        BackgroundTransparency = 1,
    }, panel)

    local nameLbl = new("TextLabel", {
        Size = UDim2.fromOffset(BAR_W, 15),
        Position = UDim2.fromOffset(0, 0),
        BackgroundTransparency = 1,
        Text = def.label,
        Font = Enum.Font.GothamMedium,
        TextSize = 11,
        TextColor3 = Color3.fromRGB(170, 170, 178),
        TextXAlignment = Enum.TextXAlignment.Left,
    }, row)

    local barBase = new("Frame", {
        Size = UDim2.fromOffset(BAR_W, BAR_H),
        Position = UDim2.fromOffset(0, 17),
        BackgroundColor3 = Color3.fromRGB(235, 235, 235),
        BorderSizePixel = 0,
        ZIndex = 1,
    }, row)
    new("UICorner", { CornerRadius = UDim.new(0, 3) }, barBase)

    local baseLbl = new("TextLabel", {
        Size = UDim2.new(1, 0, 1, 0),
        BackgroundTransparency = 1,
        Text = "0%",
        Font = Enum.Font.GothamBold,
        TextSize = 10,
        TextColor3 = Color3.fromRGB(0, 0, 0),
        ZIndex = 2,
    }, barBase)

    local fill = new("Frame", {
        Size = UDim2.fromOffset(0, BAR_H),
        Position = UDim2.fromOffset(0, 0),
        BackgroundColor3 = Color3.fromRGB(0, 0, 0),
        BorderSizePixel = 0,
        ClipsDescendants = true,
        ZIndex = 3,
    }, barBase)
    new("UICorner", { CornerRadius = UDim.new(0, 3) }, fill)

    local fillLbl = new("TextLabel", {
        Size = UDim2.fromOffset(BAR_W, BAR_H),
        Position = UDim2.fromOffset(0, 0),
        BackgroundTransparency = 1,
        Text = "0%",
        Font = Enum.Font.GothamBold,
        TextSize = 10,
        TextColor3 = Color3.fromRGB(255, 255, 255),
        ZIndex = 4,
    }, fill)

    rows[#rows + 1] = {
        def = def,
        nameLbl = nameLbl,
        fill = fill,
        baseLbl = baseLbl,
        fillLbl = fillLbl,
    }
end

--============================================================
--  STATUS
--============================================================
local function setStatus(text)
    statusLabel.Text = text
end

--============================================================
--  FARM STATE + SWITCH
--============================================================
local Farm = { enabled = false }
local switchOn = false
local supermarketClean = false
local visits = setmetatable({}, { __mode = "k" })
local lastTarget, lastTargetAt = nil, 0
local emptyScanSince = nil

local function setSwitch(on)
    switchOn = on
    Farm.enabled = on
    if not on then
        supermarketClean = false
        for k in pairs(visits) do visits[k] = nil end
        lastTarget, lastTargetAt = nil, 0
    end
    TweenService:Create(track, TweenInfo.new(0.15), {
        BackgroundColor3 = on and Color3.fromRGB(46, 160, 110) or Color3.fromRGB(55, 55, 58),
    }):Play()
    TweenService:Create(knob, TweenInfo.new(0.15), {
        Position = on and UDim2.new(1, -16, 0.5, -7) or UDim2.new(0, 2, 0.5, -7),
    }):Play()
end

track.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
    or input.UserInputType == Enum.UserInputType.Touch then
        setSwitch(not switchOn)
    end
end)

--============================================================
--  MOVEMENT
--============================================================
local function tweenTo(targetPos, duration)
    if not targetPos or targetPos.Y < GEM_Y_MIN then return end
    local root = getRoot()
    if not root or not targetPos then return end

    local look = root.CFrame.LookVector
    root.Anchored   = true
    root.CanCollide = false

    local info = TweenInfo.new(duration or TWEEN_TIME, Enum.EasingStyle.Linear, Enum.EasingDirection.Out)
    local tween = TweenService:Create(root, info, {
        CFrame = CFrame.new(targetPos, targetPos + look),
    })
    tween:Play()

    local started = os.clock()
    while os.clock() - started < (duration or TWEEN_TIME) + 1.5 do
        if not root.Parent then break end
        local ok, state = pcall(function() return tween.PlaybackState end)
        if not ok or state ~= Enum.PlaybackState.Playing then break end
        task.wait(0.03)
    end

    if root.Parent then
        root.Anchored   = false
        root.CanCollide = true
    end
end

local function teleportTo(pos, waitTime)
    local root = getRoot()
    if not root or not pos then return end
    root.Anchored = true
    root.CFrame   = CFrame.new(pos)
    task.wait(waitTime or 1)
    if root.Parent then root.Anchored = false end
end
--============================================================
--  DIMENSION TRANSFER  (remote-based)
--============================================================
local DimensionRemote = ReplicatedStorage:WaitForChild("Remotes")
    :WaitForChild("Dimensions")
    :WaitForChild("RequestDimensionTeleport")

local DIMENSION_NAMES = {
    supermarket = "Supermarket",
    overworld   = "Islands",
}
local DIMENSION_POS = {
    supermarket = SUPERMARKET_POS,
    overworld   = OVERWORLD_POS,
}

local function ensureDimension(dim)
    if currentDimension() == dim then return end

    local remoteName = DIMENSION_NAMES[dim]
    if not remoteName then return end

    -- 1. ask the server to swap the world
    pcall(function()
        DimensionRemote:InvokeServer(remoteName)
    end)

    -- 2. give the swap a beat, then snap ourselves to the real landing spot
    task.wait(1)
    teleportTo(DIMENSION_POS[dim], 1)

    -- 3. verify. if we're still not there, try once more
    local started = os.clock()
    while os.clock() - started < 5 do
        if getRoot() and currentDimension() == dim then return end
        task.wait(0.25)
    end

    pcall(function()
        DimensionRemote:InvokeServer(remoteName)
    end)
    task.wait(1)
    teleportTo(DIMENSION_POS[dim], 1)
    task.wait(0.5)
end


--============================================================
--  FARM STEPS
--============================================================
local function captureOne(def)
    local part = resolvePath(def.path)
    if not part and currentDimension() ~= def.dimension then
        ensureDimension(def.dimension)
        task.wait(0.5)
        part = resolvePath(def.path)
    end
    if not part then return false end

    local info = readTerritory(part)
    if not info or info.ours then return false end

    setStatus("Capturing territories  ·  " .. def.label)
    ensureDimension(def.dimension)
    if not Farm.enabled then return true end

    local root = getRoot()
    if not root then return true end

    tweenTo(part.Position + Vector3.new(0, 4, 0))

    local started = os.clock()
    while Farm.enabled and os.clock() - started < 40 do
        local now = readTerritory(part)
        if not now or now.ours then break end
        task.wait(0.4)
    end
    return true
end

local function doAirdrop()
    if not getAirdropRing() then return false end

    ensureDimension("overworld")
    if not Farm.enabled then return true end

    setStatus("Going to airdrop")
    local ring = getAirdropRing()
    if not ring then return true end

    local pos
    if ring:IsA("BasePart") then
        pos = ring.Position
    else
        pcall(function() pos = ring:GetPivot().Position end)
    end
    if not pos then return true end

    tweenTo(pos)

    local started = os.clock()
    while Farm.enabled and getAirdropRing() and os.clock() - started < 30 do
        task.wait(0.5)
    end
    return true
end

local function freshGemScan()
    local result = { big = {}, normal = {} }
    local root = getRoot()
    if not root then return result end
    local blacklist = workspace:FindFirstChild("132561535")
    local char = LocalPlayer.Character

    for _, obj in ipairs(workspace:GetDescendants()) do
        local name = obj.Name
        if name == "BigGemModel" or name == "GemModel" then
            local skip = false
            if blacklist and obj:IsDescendantOf(blacklist) then skip = true end
            if char and obj:IsDescendantOf(char) then skip = true end
            
            if not skip and obj:IsA("BasePart") then
                -- Skip if it's already collected (shrunk to 0.001)
                if obj.Size.X < 1 then skip = true end
                
                -- Skip if it's still falling from the sky (downward velocity)
                if obj.AssemblyLinearVelocity.Y < -1 then skip = true end
            end

            if not skip then
                local pos = getModelPosition(obj)
                if pos and pos.Y >= GEM_Y_MIN then
                    local entry = {
                        model = obj,
                        pos   = pos,
                        dist  = (pos - root.Position).Magnitude,
                    }
                    if name == "BigGemModel" then
                        table.insert(result.big, entry)
                    else
                        table.insert(result.normal, entry)
                    end
                end
            end
        end
    end

    local function filterAndSort(list)
        local out = {}
        for _, e in ipairs(list) do
            local recent = (e.model == lastTarget) and (os.clock() - lastTargetAt < 5)
            if e.model.Parent and (visits[e.model] or 0) < 2 and not recent then
                table.insert(out, e)
            end
        end
        table.sort(out, function(a, b) return a.dist < b.dist end)
        return out
    end

    result.big    = filterAndSort(result.big)
    result.normal = filterAndSort(result.normal)
    return result
end

local function doGemStep()
    if not Farm.enabled then return false end
    local root = getRoot()
    if not root then return false end

    local result = freshGemScan()
    local target = result.big[1] or result.normal[1]
    local isBig  = result.big[1] ~= nil

    if not target then
        if not emptyScanSince then emptyScanSince = os.clock() end
        if os.clock() - emptyScanSince > 20 then
            for k in pairs(visits) do visits[k] = nil end
            lastTarget, lastTargetAt = nil, 0
            emptyScanSince = nil
            setStatus("Idle — wiped visit memory, rescanning")
            return true
        end
        setStatus(string.format(
            "Idle — no gems currently.  (big:%d normal:%d)",
            #result.big, #result.normal))
        return false
    end

    emptyScanSince = nil

    ensureDimension("overworld")
    if not Farm.enabled then return false end
    if not target.model.Parent then return true end

    setStatus(isBig and "Going to big gem" or "Going to gem")
    tweenTo(target.pos)
    visits[target.model] = (visits[target.model] or 0) + 1
    lastTarget, lastTargetAt = target.model, os.clock()
    task.wait(0.3)
    return true
end



--============================================================
--  MAIN FARM LOOP
--============================================================
task.spawn(function()
    while true do
        if not Farm.enabled then
            setStatus("Paused")
            task.wait(0.25)
        elseif not getRoot() then
            setStatus("Waiting for character…")
            task.wait(1)
        else
            local acted = false

            -- PHASE 1: supermarket territories
            if not supermarketClean then
                if currentDimension() ~= "supermarket" then
                    setStatus("Entering supermarket")
                    ensureDimension("supermarket")
                    task.wait(0.5)
                else
                    for _, def in ipairs(TERRITORY_DEFS) do
                        if not Farm.enabled then break end
                        if def.dimension == "supermarket" then
                            local part = resolvePath(def.path)
                            local info = readTerritory(part)
                            if info and not info.ours
                            and (CAPTURE_OTHERS or info.owner == "Nobody" or info.owner == "Unknown") then
                                if captureOne(def) then acted = true end
                                if acted then break end
                            end
                        end
                    end

                    if not acted then
                        local allOurs, allResolved = true, true
                        for _, def in ipairs(TERRITORY_DEFS) do
                            if def.dimension == "supermarket" then
                                local part = resolvePath(def.path)
                                if not part then
                                    allResolved = false
                                else
                                    local info = readTerritory(part)
                                    if not info or not info.ours then allOurs = false end
                                end
                            end
                        end
                        if allResolved and allOurs then
                            supermarketClean = true
                            setStatus("Supermarket done")
                        end
                    end
                end
            end

            -- PHASE 2: overworld
            if Farm.enabled and not acted and supermarketClean then
                if currentDimension() ~= "overworld" then
                    setStatus("Entering overworld")
                    ensureDimension("overworld")
                    task.wait(0.5)
                else
                    for _, def in ipairs(TERRITORY_DEFS) do
                        if not Farm.enabled then break end
                        if def.dimension == "overworld" then
                            local part = resolvePath(def.path)
                            local info = readTerritory(part)
                            if info and not info.ours
                            and (CAPTURE_OTHERS or info.owner == "Nobody" or info.owner == "Unknown") then
                                if captureOne(def) then acted = true end
                                if acted then break end
                            end
                        end
                    end

                    if Farm.enabled and not acted then
                        if getAirdropRing() then
                            doAirdrop()
                        elseif not doGemStep() then
                            task.wait(1)
                        end
                    end
                end
            end
        end
    end
end)

--============================================================
--  TERRITORY UI REFRESH
--============================================================
local function refreshTerritories()
    for _, row in ipairs(rows) do
        local part = resolvePath(row.def.path)
        local info = readTerritory(part)

        if info then
            local percent = math.floor(info.fill * 100 + 0.5)
            local text    = string.format("%d%%", percent)
            local fillPx  = math.floor(BAR_W * info.fill + 0.5)

            row.nameLbl.Text = row.def.label .. "  ·  " .. info.owner
            if info.ours then
                row.nameLbl.TextColor3 = Color3.fromRGB(110, 235, 190)
            elseif info.owner == "Nobody" then
                row.nameLbl.TextColor3 = Color3.fromRGB(255, 160, 90)
            else
                row.nameLbl.TextColor3 = Color3.fromRGB(150, 205, 255)
            end

            row.baseLbl.Text = text
            row.fillLbl.Text = text
            row.fill.Size    = UDim2.fromOffset(fillPx, BAR_H)
        else
            row.nameLbl.Text       = row.def.label .. "  ·  --"
            row.nameLbl.TextColor3 = Color3.fromRGB(120, 120, 128)
            row.baseLbl.Text       = "--"
            row.fillLbl.Text       = "--"
            row.fill.Size          = UDim2.fromOffset(0, BAR_H)
        end
    end
end

task.spawn(function()
    while true do
        pcall(refreshTerritories)
        task.wait(1)
    end
end)
