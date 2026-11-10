--[[=====================================================================
    ENI's Farm Hub  ♥  built for LO  (merged build)
    ---------------------------------------------------------------------
    Single-window UI: status / pill toggle / tabs / grouped territories
    Farm ladder : territories (supermarket -> overworld) -> airdrop -> gems
    Movement    : TweenService, duration from settings, collision off
    Config file : ENI_FarmHub_Config.json  (schema v2)
=====================================================================]]

local Players           = game:GetService("Players")
local TweenService      = game:GetService("TweenService")
local UserInputService  = game:GetService("UserInputService")
local HttpService       = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer

--============================================================
--  CONSTANTS
--============================================================
local SUPERMARKET_POS = Vector3.new(111118, 1464, -1625)
local OVERWORLD_POS   = Vector3.new(47, 179, 101)
local CAPTURE_OTHERS  = false
local UNOWNED_COLOR   = Color3.fromRGB(255, 85, 0)
local OWNED_COLOR     = Color3.fromRGB(1, 255, 234)

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
--  HELPERS  (unchanged from your original)
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
        n .. "'s territory", n .. "s territory",
        n .. "' territory",  n .. " territory",
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

local function guiParent()
    local ok, hui = pcall(function() return gethui and gethui() end)
    if ok and hui then return hui end
    local ok2, core = pcall(function() return game:GetService("CoreGui") end)
    if ok2 and core then return core end
    return LocalPlayer:WaitForChild("PlayerGui")
end

--============================================================
--  UI MODULE
--============================================================
local CONFIG_PATH = "ENI_FarmHub_Config.json"

local Theme = {
    base   = Color3.fromHex("#14161C"),
    panel  = Color3.fromHex("#1C1F27"),
    raised = Color3.fromHex("#252A34"),
    stroke = Color3.fromHex("#2E3440"),
    text   = Color3.fromHex("#E8E6E1"),
    muted  = Color3.fromHex("#8B8F98"),
    accent = Color3.fromHex("#B79CED"),
    success= Color3.fromHex("#7DD3A0"),
    danger = Color3.fromHex("#E07A7A"),
}

local Config = {
    ui = {
        pos = nil, collapsed = false, tab = "Territories",
        collapsedGroups = {}, settings = {},
    },
}

local function loadConfig()
    if not (isfile and isfile(CONFIG_PATH)) then return end
    local ok, raw = pcall(readfile, CONFIG_PATH)
    if not ok or not raw then return end
    local decOk, data = pcall(HttpService.JSONDecode, HttpService, raw)
    if not decOk or type(data) ~= "table" then return end

    -- migrate old ui2 position into new schema
    if not (data.ui and data.ui.pos) and data.ui2 then
        data.ui = data.ui or {}
        data.ui.pos = { X = data.ui2.x, Y = data.ui2.y }
    end

    local u = data.ui or {}
    Config.ui.pos             = u.pos             or Config.ui.pos
    Config.ui.collapsed       = u.collapsed       or false
    Config.ui.tab             = u.tab             or "Territories"
    Config.ui.collapsedGroups = u.collapsedGroups or {}
    Config.ui.settings        = u.settings        or {}
end

local function saveConfig()
    if not writefile then return end
    pcall(function()
        writefile(CONFIG_PATH, HttpService:JSONEncode(Config))
    end)
end

loadConfig()

local function corner(parent, r)
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, r or 8)
    c.Parent = parent
    return c
end

local function stroke(parent, color)
    local s = Instance.new("UIStroke")
    s.Color = color or Theme.stroke
    s.Thickness = 1
    s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    s.Parent = parent
    return s
end

local function mkFrame(parent, name, size, pos, color, radius)
    local f = Instance.new("Frame")
    f.Name = name
    f.Size = size
    f.Position = pos
    f.BackgroundColor3 = color or Theme.panel
    f.BorderSizePixel = 0
    f.Parent = parent
    corner(f, radius)
    return f
end

local function mkLabel(parent, name, props)
    local t = Instance.new("TextLabel")
    t.Name = name
    t.BackgroundTransparency = 1
    t.Font = Enum.Font.Gotham
    t.TextSize = 12
    t.TextColor3 = Theme.text
    t.TextXAlignment = Enum.TextXAlignment.Left
    t.TextYAlignment = Enum.TextYAlignment.Center
    for k, v in pairs(props or {}) do t[k] = v end
    t.Parent = parent
    return t
end

local function makeDraggable(frame, handle, onEnd)
    local dragging, dragStart, startPos
    handle.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
            dragging  = true
            dragStart = input.Position
            startPos  = frame.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                    if onEnd then onEnd() end
                end
            end)
        end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if not dragging then return end
        if input.UserInputType == Enum.UserInputType.MouseMovement
        or input.UserInputType == Enum.UserInputType.Touch then
            local delta = input.Position - dragStart
            frame.Position = UDim2.new(
                startPos.X.Scale, startPos.X.Offset + delta.X,
                startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)
end

local ENI_UI = {
    farming  = false,
    settings = { tweenTime = 0.45, gemYMin = 100, blacklist = {} },
    _stats   = { territory = 0, gem = 0, drop = 0 },
    _reader  = nil,
    _rows    = {},
    _groups  = {},
    _onFarmChange = nil,
    refreshTerritories = function() end, -- <-- This satisfies the linter
}
local pill, pillDot, pillText

for k, v in pairs(Config.ui.settings or {}) do
    if ENI_UI.settings[k] ~= nil then ENI_UI.settings[k] = v end
end

function ENI_UI.bindTerritoryReader(fn) ENI_UI._reader = fn end
function ENI_UI.isFarming() return ENI_UI.farming end
function ENI_UI.onFarmingChanged(fn) ENI_UI._onFarmChange = fn end

local gui = Instance.new("ScreenGui")
gui.Name = "ENI_FarmHub"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 2
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = guiParent()

local WINDOW_W, WINDOW_H = 324, 486

local window = mkFrame(gui, "Window", UDim2.fromOffset(WINDOW_W, WINDOW_H),
    UDim2.new(1, -WINDOW_W - 16, 1, -WINDOW_H - 16), Theme.base, 12)
window.ClipsDescendants = true
stroke(window)

if Config.ui.pos and Config.ui.pos.X and Config.ui.pos.Y then
    window.Position = UDim2.fromOffset(Config.ui.pos.X, Config.ui.pos.Y)
end

-- header ---------------------------------------------------
local header = mkFrame(window, "Header", UDim2.new(1, 0, 0, 36), UDim2.new(), Theme.panel, 12)
local headerCover = Instance.new("Frame")
headerCover.Size = UDim2.new(1, 0, 0, 12)
headerCover.Position = UDim2.new(0, 0, 1, -12)
headerCover.BackgroundColor3 = Theme.panel
headerCover.BorderSizePixel = 0
headerCover.ZIndex = 1
headerCover.Parent = header

local statusDot = Instance.new("Frame")
statusDot.Size = UDim2.fromOffset(8, 8)
statusDot.Position = UDim2.new(0, 14, 0.5, -4)
statusDot.BackgroundColor3 = Theme.muted
statusDot.BorderSizePixel = 0
statusDot.ZIndex = 2
statusDot.Parent = header
corner(statusDot, 4)

mkLabel(header, "Title", {
    Text = "ENI's Farm Hub", Font = Enum.Font.GothamMedium, TextSize = 14,
    Position = UDim2.new(0, 30, 0, 0), Size = UDim2.new(0, 200, 1, 0), ZIndex = 2,
})

local collapseBtn = Instance.new("TextButton")
collapseBtn.Text = "—"
collapseBtn.Font = Enum.Font.GothamBold
collapseBtn.TextSize = 14
collapseBtn.TextColor3 = Theme.muted
collapseBtn.BackgroundTransparency = 1
collapseBtn.Size = UDim2.fromOffset(28, 28)
collapseBtn.Position = UDim2.new(1, -36, 0.5, -14)
collapseBtn.ZIndex = 2
collapseBtn.Parent = header
collapseBtn.MouseEnter:Connect(function() collapseBtn.TextColor3 = Theme.text end)
collapseBtn.MouseLeave:Connect(function() collapseBtn.TextColor3 = Theme.muted end)

makeDraggable(window, header, function()
    Config.ui.pos = { X = window.Position.X.Offset, Y = window.Position.Y.Offset }
    saveConfig()
end)

-- hero status ----------------------------------------------
local heroTitle = mkLabel(window, "HeroTitle", {
    Text = "Idle", Font = Enum.Font.GothamBold, TextSize = 18,
    Position = UDim2.new(0, 14, 0, 44), Size = UDim2.new(1, -28, 0, 24),
})
local heroMeta = mkLabel(window, "HeroMeta", {
    Text = "Waiting for orders", TextSize = 12, TextColor3 = Theme.muted,
    Position = UDim2.new(0, 14, 0, 68), Size = UDim2.new(1, -28, 0, 16),
})

-- farming pill toggle --------------------------------------
local toggleBtn = Instance.new("TextButton")
toggleBtn.Text = ""
toggleBtn.AutoButtonColor = false
toggleBtn.Size = UDim2.new(1, -28, 0, 34)
toggleBtn.Position = UDim2.new(0, 14, 0, 94)
toggleBtn.BackgroundColor3 = Theme.raised
toggleBtn.BorderSizePixel = 0
toggleBtn.Parent = window
corner(toggleBtn, 17)
stroke(toggleBtn)

local toggleFill = Instance.new("Frame")
toggleFill.Size = UDim2.fromScale(0, 1)
toggleFill.BackgroundColor3 = Theme.accent
toggleFill.BorderSizePixel = 0
toggleFill.Parent = toggleBtn
corner(toggleFill, 17)

local toggleText = mkLabel(toggleBtn, "Text", {
    Text = "FARMING: OFF", Font = Enum.Font.GothamBold, TextSize = 12,
    TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.fromScale(1, 1),
    TextColor3 = Theme.muted,
})

local function paintToggle(on, animate)
    ENI_UI.farming = on
    local info = animate and TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
                 or TweenInfo.new(0)
    TweenService:Create(toggleFill, info, { Size = UDim2.fromScale(on and 1 or 0, 1) }):Play()
    TweenService:Create(toggleText, info, { TextColor3 = on and Theme.base or Theme.muted }):Play()
    toggleText.Text = on and "FARMING: ON" or "FARMING: OFF"
    if ENI_UI._onFarmChange then ENI_UI._onFarmChange(on) end
end

toggleBtn.MouseButton1Click:Connect(function() paintToggle(not ENI_UI.farming, true) end)

-- tabs -----------------------------------------------------
local TABS = { "Territories", "Gems", "Settings" }
local tabBar = mkFrame(window, "TabBar", UDim2.new(1, -28, 0, 30),
    UDim2.new(0, 14, 0, 138), Theme.panel, 8)
tabBar.BackgroundTransparency = 1

local tabButtons = {}
local bodyStartY = 176
for i, name in ipairs(TABS) do
    local b = Instance.new("TextButton")
    b.Text = name
    b.Font = Enum.Font.GothamMedium
    b.TextSize = 12
    b.TextColor3 = Theme.muted
    b.BackgroundTransparency = 1
    b.Size = UDim2.new(1 / #TABS, -4, 1, 0)
    b.Position = UDim2.new((i - 1) / #TABS, 2, 0, 0)
    b.Parent = tabBar

    local underline = Instance.new("Frame")
    underline.Size = UDim2.new(0.6, 0, 0, 2)
    underline.Position = UDim2.new(0.2, 0, 1, -2)
    underline.BackgroundColor3 = Theme.accent
    underline.BorderSizePixel = 0
    underline.BackgroundTransparency = 1
    underline.Parent = b
    corner(underline, 1)

    tabButtons[name] = { btn = b, underline = underline }
end

-- body containers ------------------------------------------
local bodyH = 452 - bodyStartY

local territoryScroll = Instance.new("ScrollingFrame")
territoryScroll.Size = UDim2.new(1, -20, 0, bodyH)
territoryScroll.Position = UDim2.new(0, 14, 0, bodyStartY)
territoryScroll.BackgroundTransparency = 1
territoryScroll.BorderSizePixel = 0
territoryScroll.ScrollBarThickness = 4
territoryScroll.ScrollBarImageColor3 = Theme.stroke
territoryScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
territoryScroll.CanvasSize = UDim2.new()
territoryScroll.Parent = window

local listLayout = Instance.new("UIListLayout")
listLayout.Padding = UDim.new(0, 6)
listLayout.SortOrder = Enum.SortOrder.LayoutOrder
listLayout.Parent = territoryScroll

local gemsPanel = mkFrame(window, "Gems", UDim2.new(1, -20, 0, bodyH),
    UDim2.new(0, 14, 0, bodyStartY), Theme.panel, 8)
gemsPanel.BackgroundTransparency = 0.4
gemsPanel.Visible = false

local gemLines = {}
for i = 1, 3 do
    gemLines[i] = mkLabel(gemsPanel, "L" .. i, {
        Text = "", TextSize = 12, TextColor3 = Theme.muted,
        Position = UDim2.new(0, 12, 0, 10 + (i - 1) * 22),
        Size = UDim2.new(1, -24, 0, 18),
    })
end
gemLines[1].Text = "Current target: —"
gemLines[2].Text = "Gems collected: 0"
gemLines[3].Text = "Airdrops chased: 0"

-- settings -------------------------------------------------
local settingsPanel = Instance.new("ScrollingFrame")
settingsPanel.Size = UDim2.new(1, -20, 0, bodyH)
settingsPanel.Position = UDim2.new(0, 14, 0, bodyStartY)
settingsPanel.BackgroundTransparency = 1
settingsPanel.BorderSizePixel = 0
settingsPanel.ScrollBarThickness = 4
settingsPanel.ScrollBarImageColor3 = Theme.stroke
settingsPanel.AutomaticCanvasSize = Enum.AutomaticSize.Y
settingsPanel.CanvasSize = UDim2.new()
settingsPanel.Visible = false
settingsPanel.Parent = window

local settingsLayout = Instance.new("UIListLayout")
settingsLayout.Padding = UDim.new(0, 10)
settingsLayout.Parent = settingsPanel

local function makeSettingRow(labelText, hint, initial, commit)
    local row = mkFrame(settingsPanel, labelText, UDim2.new(1, -8, 0, 46), UDim2.new(),
        Theme.raised, 8)
    mkLabel(row, "Label", {
        Text = labelText, Font = Enum.Font.GothamMedium, TextSize = 12,
        Position = UDim2.new(0, 10, 0, 6), Size = UDim2.new(0.6, 0, 0, 16),
    })
    mkLabel(row, "Hint", {
        Text = hint, TextSize = 10, TextColor3 = Theme.muted,
        Position = UDim2.new(0, 10, 0, 24), Size = UDim2.new(0.7, 0, 0, 14),
    })
    local box = Instance.new("TextBox")
    box.Text = tostring(initial)
    box.Font = Enum.Font.Code
    box.TextSize = 12
    box.TextColor3 = Theme.text
    box.BackgroundColor3 = Theme.base
    box.BorderSizePixel = 0
    box.ClearTextOnFocus = false
    box.Size = UDim2.new(0, 90, 0, 26)
    box.Position = UDim2.new(1, -100, 0.5, -13)
    box.Parent = row
    corner(box, 6)
    stroke(box)
    box.FocusLost:Connect(function() commit(box.Text) end)
    return row, box
end

local tweenRow, tweenBox = makeSettingRow("Tween time", "seconds per move", ENI_UI.settings.tweenTime, function(txt)
    local n = tonumber(txt)
    if n and n > 0 then
        ENI_UI.settings.tweenTime = n
        Config.ui.settings.tweenTime = n
        saveConfig()
    else
        tweenBox.Text = tostring(ENI_UI.settings.tweenTime)
    end
end)

local gemRow, gemBox = makeSettingRow("Gem Y minimum", "skip anything below", ENI_UI.settings.gemYMin, function(txt)
    local n = tonumber(txt)
    if n then
        ENI_UI.settings.gemYMin = n
        Config.ui.settings.gemYMin = n
        saveConfig()
    else
        gemBox.Text = tostring(ENI_UI.settings.gemYMin)
    end
end)

local blacklistRow, blacklistBox = makeSettingRow("Territory blacklist", "comma separated labels", "", function(txt)
    local t = {}
    for word in string.gmatch(txt, "[^,%s]+") do t[word] = true end
    ENI_UI.settings.blacklist = t
    Config.ui.settings.blacklist = t
    saveConfig()
    if ENI_UI.refreshTerritories then ENI_UI.refreshTerritories() end
end)

do
    local names = {}
    for k in pairs(ENI_UI.settings.blacklist or {}) do table.insert(names, k) end
    table.sort(names)
    blacklistBox.Text = table.concat(names, ", ")
end

-- footer ---------------------------------------------------
local footer = mkFrame(window, "Footer", UDim2.new(1, 0, 0, 30),
    UDim2.new(0, 0, 1, -30), Theme.panel, 12)
local footerLabel = mkLabel(footer, "Stats", {
    Text = "0 captured · 0 gems · 0 drops", TextSize = 11, TextColor3 = Theme.muted,
    Position = UDim2.new(0, 14, 0, 0), Size = UDim2.new(1, -28, 1, 0),
})

local function paintStats()
    footerLabel.Text = string.format("%d captured · %d gems · %d drops",
        ENI_UI._stats.territory, ENI_UI._stats.gem, ENI_UI._stats.drop)
end

function ENI_UI.bumpStat(kind, n)
    ENI_UI._stats[kind] = (ENI_UI._stats[kind] or 0) + (n or 1)
    paintStats()
    if kind == "gem"  then gemLines[2].Text = "Gems collected: " .. ENI_UI._stats.gem end
    if kind == "drop" then gemLines[3].Text = "Airdrops chased: " .. ENI_UI._stats.drop end
end

-- status ---------------------------------------------------
local pulseTween
local function stopPulse()
    if pulseTween then pulseTween:Cancel(); pulseTween = nil end
    statusDot.BackgroundTransparency = 0
end

function ENI_UI.setStatus(title, meta, state)
    title = title or "Idle"
    heroTitle.Text = title
    heroMeta.Text  = meta or ""
    state = state or "idle"
    stopPulse()
    if state == "active" then
        statusDot.BackgroundColor3 = Theme.accent
        pulseTween = TweenService:Create(statusDot,
            TweenInfo.new(0.7, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
            { BackgroundTransparency = 0.6 })
        pulseTween:Play()
    elseif state == "paused" then
        statusDot.BackgroundColor3 = Theme.muted
    elseif state == "error" then
        statusDot.BackgroundColor3 = Theme.danger
    else
        statusDot.BackgroundColor3 = Theme.success
    end
    gemLines[1].Text = "Current target: " .. title
    if pillText then pillText.Text = title end
    if pillDot  then pillDot.BackgroundColor3 = statusDot.BackgroundColor3 end
end

-- territory list -------------------------------------------
local function ownershipColor(state)
    if state.beam == true then return Theme.success end
    if state.beam == false then return Theme.muted  end
    if state.ours then return Theme.success end
    if state.owner == "Nobody" or state.owner == "Unknown"
       or state.owner == nil or state.owner == "" then
        return Theme.muted
    end
    return Theme.danger
end

local function ensureGroup(dim)
    if ENI_UI._groups[dim] then return ENI_UI._groups[dim] end

    local headerRow = Instance.new("TextButton")
    headerRow.Name = dim
    headerRow.Text = ""
    headerRow.AutoButtonColor = false
    headerRow.BackgroundTransparency = 1
    headerRow.Size = UDim2.new(1, -8, 0, 24)
    headerRow.Parent = territoryScroll

    local chevron = mkLabel(headerRow, "Chevron", {
        Text = "▾", TextSize = 12, TextColor3 = Theme.muted,
        Position = UDim2.new(0, 2, 0, 0), Size = UDim2.new(0, 14, 1, 0),
    })
    mkLabel(headerRow, "Name", {
        Text = dim, Font = Enum.Font.GothamBold, TextSize = 12, TextColor3 = Theme.text,
        Position = UDim2.new(0, 18, 0, 0), Size = UDim2.new(1, -70, 1, 0),
    })
    local count = mkLabel(headerRow, "Count", {
        Text = "", TextSize = 11, TextColor3 = Theme.muted,
        TextXAlignment = Enum.TextXAlignment.Right,
        Position = UDim2.new(1, -60, 0, 0), Size = UDim2.new(0, 56, 1, 0),
    })

    local rows = Instance.new("Frame")
    rows.BackgroundTransparency = 1
    rows.Size = UDim2.new(1, 0, 0, 0)
    rows.Parent = territoryScroll
    local rl = Instance.new("UIListLayout")
    rl.Padding = UDim.new(0, 4)
    rl.Parent = rows
    rows.AutomaticSize = Enum.AutomaticSize.Y

    local group = { header = headerRow, rowsFrame = rows, chevron = chevron, count = count }
    ENI_UI._groups[dim] = group

    local collapsed = Config.ui.collapsedGroups[dim] == true
    rows.Visible = not collapsed
    chevron.Text = collapsed and "▸" or "▾"

    headerRow.MouseButton1Click:Connect(function()
        local nowCollapsed = rows.Visible
        rows.Visible = not nowCollapsed
        chevron.Text = nowCollapsed and "▸" or "▾"
        Config.ui.collapsedGroups[dim] = nowCollapsed
        saveConfig()
    end)

    return group
end

local function buildRow(def, group)
    local key = (def.dimension or "?") .. "/" .. (def.label or def.id or "?")
    if ENI_UI._rows[key] then return ENI_UI._rows[key] end

    local row = mkFrame(group.rowsFrame, def.id or "?", UDim2.new(1, -8, 0, 36),
        UDim2.new(), Theme.raised, 6)

    local dot = Instance.new("Frame")
    dot.Size = UDim2.fromOffset(8, 8)
    dot.Position = UDim2.new(0, 10, 0, 14)
    dot.BackgroundColor3 = Theme.muted
    dot.BorderSizePixel = 0
    dot.Parent = row
    corner(dot, 4)

    local nameLbl = mkLabel(row, "Name", {
        Text = def.label or def.id or "?", TextSize = 12,
        Position = UDim2.new(0, 24, 0, 2), Size = UDim2.new(0, 130, 0, 16),
    })
    local ownerLbl = mkLabel(row, "Owner", {
        Text = "—", TextSize = 10, TextColor3 = Theme.muted,
        Position = UDim2.new(0, 24, 0, 19), Size = UDim2.new(0, 130, 0, 14),
    })

    local barTrack = Instance.new("Frame")
    barTrack.Size = UDim2.fromOffset(90, 6)
    barTrack.Position = UDim2.fromOffset(160, 15)
    barTrack.BackgroundColor3 = Theme.base
    barTrack.BorderSizePixel = 0
    barTrack.Parent = row
    corner(barTrack, 3)

    local barFill = Instance.new("Frame")
    barFill.Size = UDim2.fromScale(0, 1)
    barFill.BackgroundColor3 = Theme.accent
    barFill.BorderSizePixel = 0
    barFill.Parent = barTrack
    corner(barFill, 3)

    local pct = mkLabel(row, "Pct", {
        Text = "0%", Font = Enum.Font.Code, TextSize = 11, TextColor3 = Theme.muted,
        TextXAlignment = Enum.TextXAlignment.Right,
        Position = UDim2.new(1, -36, 0, 0), Size = UDim2.new(0, 26, 0, 36),
    })

    local entry = { row = row, dot = dot, bar = barFill, pct = pct,
                    name = nameLbl, owner = ownerLbl }
    ENI_UI._rows[key] = entry
    return entry
end

function ENI_UI.refreshTerritories()
    if type(TERRITORY_DEFS) ~= "table" or not ENI_UI._reader then return end
    for _, def in ipairs(TERRITORY_DEFS) do
        local dim = def.dimension or "Unknown"
        local group = ensureGroup(dim)
        local entry = buildRow(def, group)
        local state = ENI_UI._reader(def)
        if state then
            local fill = math.clamp(state.fill or 0, 0, 1)
            entry.row.Visible = true
            entry.dot.BackgroundColor3 = ownershipColor(state)
            entry.bar.Size = UDim2.fromScale(fill, 1)
            entry.bar.BackgroundColor3 = state.ours and Theme.success or Theme.accent
            entry.pct.Text = tostring(math.floor(fill * 100 + 0.5)) .. "%"
            entry.pct.TextColor3 = state.ours and Theme.success or Theme.muted
            entry.owner.Text = state.owner or "—"
            entry.owner.TextColor3 = ownershipColor(state)
        else
            entry.row.Visible = true
            entry.dot.BackgroundColor3 = Theme.muted
            entry.bar.Size = UDim2.fromScale(0, 1)
            entry.pct.Text = "—"
            entry.owner.Text = "not loaded"
        end
    end
    for dim, group in pairs(ENI_UI._groups) do
        local n = 0
        for k in pairs(ENI_UI._rows) do
            if k:sub(1, #dim + 1) == dim .. "/" then n = n + 1 end
        end
        group.count.Text = "(" .. n .. ")"
    end
end

-- tab switching --------------------------------------------
local panes = {
    Territories = territoryScroll,
    Gems        = gemsPanel,
    Settings    = settingsPanel,
}

local function selectTab(name)
    for tabName, refs in pairs(tabButtons) do
        local active = tabName == name
        refs.btn.TextColor3 = active and Theme.text or Theme.muted
        refs.underline.BackgroundTransparency = active and 0 or 1
    end
    for tabName, pane in pairs(panes) do
        pane.Visible = tabName == name
    end
    Config.ui.tab = name
    saveConfig()
end

for name, refs in pairs(tabButtons) do
    refs.btn.MouseButton1Click:Connect(function() selectTab(name) end)
end

-- collapsed pill -------------------------------------------
pill = mkFrame(gui, "Pill", UDim2.fromOffset(176, 40),
    UDim2.new(1, -192, 1, -56), Theme.panel, 20)
pill.ClipsDescendants = true
stroke(pill)
pill.Visible = false

pillDot = Instance.new("Frame")
pillDot.Size = UDim2.fromOffset(8, 8)
pillDot.Position = UDim2.new(0, 14, 0.5, -4)
pillDot.BackgroundColor3 = Theme.success
pillDot.BorderSizePixel = 0
pillDot.Parent = pill
corner(pillDot, 4)
pillText = mkLabel(pill, "Text", {
    Text = "Idle", Font = Enum.Font.GothamMedium, TextSize = 12,
    Position = UDim2.new(0, 30, 0, 0), Size = UDim2.new(1, -58, 1, 0),
})

local expandBtn = Instance.new("TextButton")
expandBtn.Text = "⌃"
expandBtn.Font = Enum.Font.GothamBold
expandBtn.TextSize = 14
expandBtn.TextColor3 = Theme.muted
expandBtn.BackgroundTransparency = 1
expandBtn.Size = UDim2.fromOffset(24, 24)
expandBtn.Position = UDim2.new(1, -30, 0.5, -12)
expandBtn.Parent = pill

function ENI_UI.setCollapsed(state)
    Config.ui.collapsed = state and true or false
    if state then
        pill.Position = window.Position
        window.Visible = false
        pill.Visible = true
    else
        window.Position = pill.Position
        pill.Visible = false
        window.Visible = true
        Config.ui.pos = { X = window.Position.X.Offset, Y = window.Position.Y.Offset }
    end
    saveConfig()
end

collapseBtn.MouseButton1Click:Connect(function() ENI_UI.setCollapsed(true)  end)
expandBtn.MouseButton1Click:Connect(  function() ENI_UI.setCollapsed(false) end)

-- boot -----------------------------------------------------
paintToggle(ENI_UI.farming, false)
paintStats()
selectTab(Config.ui.tab or "Territories")
if Config.ui.collapsed then ENI_UI.setCollapsed(true) end

--============================================================
--  READER BINDING
--============================================================
ENI_UI.bindTerritoryReader(function(def)
    local part = resolvePath(def.path)
    if not part then return nil end
    local t = readTerritory(part)
    if not t then return nil end
    return { fill = t.fill, ours = t.ours, owner = t.owner, beam = t.beam }
end)

--============================================================
--  FARM STATE
--============================================================
local supermarketClean = false
local visits = setmetatable({}, { __mode = "k" })
local lastTarget, lastTargetAt = nil, 0
local emptyScanSince = nil

ENI_UI.onFarmingChanged(function(on)
    if not on then
        supermarketClean = false
        for k in pairs(visits) do visits[k] = nil end
        lastTarget, lastTargetAt = nil, 0
        emptyScanSince = nil
    end
end)

--============================================================
--  MOVEMENT
--============================================================
local function tweenTo(targetPos, duration)
    if not targetPos or targetPos.Y < ENI_UI.settings.gemYMin then return end
    local root = getRoot()
    if not root then return end

    local look = root.CFrame.LookVector
    root.Anchored   = true
    root.CanCollide = false

    duration = duration or ENI_UI.settings.tweenTime
    local info = TweenInfo.new(duration, Enum.EasingStyle.Linear, Enum.EasingDirection.Out)
    local tween = TweenService:Create(root, info, {
        CFrame = CFrame.new(targetPos, targetPos + look),
    })
    tween:Play()

    local started = os.clock()
    while os.clock() - started < duration + 1.5 do
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
--  DIMENSION TRANSFER
--============================================================
local DimensionRemote = ReplicatedStorage:WaitForChild("Remotes")
    :WaitForChild("Dimensions")
    :WaitForChild("RequestDimensionTeleport")

local DIMENSION_NAMES = { supermarket = "Supermarket", overworld = "Islands" }
local DIMENSION_POS   = { supermarket = SUPERMARKET_POS, overworld = OVERWORLD_POS }

local function ensureDimension(dim)
    if currentDimension() == dim then return end
    local remoteName = DIMENSION_NAMES[dim]
    if not remoteName then return end

    pcall(function() DimensionRemote:InvokeServer(remoteName) end)
    task.wait(1)
    teleportTo(DIMENSION_POS[dim], 1)

    local started = os.clock()
    while os.clock() - started < 5 do
        if getRoot() and currentDimension() == dim then return end
        task.wait(0.25)
    end

    pcall(function() DimensionRemote:InvokeServer(remoteName) end)
    task.wait(1)
    teleportTo(DIMENSION_POS[dim], 1)
    task.wait(0.5)
end

--============================================================
--  FARM STEPS
--============================================================
local function captureOne(def)
    if ENI_UI.settings.blacklist[def.label] then return false end

    local part = resolvePath(def.path)
    if not part and currentDimension() ~= def.dimension then
        ensureDimension(def.dimension)
        task.wait(0.5)
        part = resolvePath(def.path)
    end
    if not part then return false end

    local info = readTerritory(part)
    if not info or info.ours then return false end

    ENI_UI.setStatus("Capturing territories", def.label, "active")
    ensureDimension(def.dimension)
    if not ENI_UI.isFarming() then return true end

    local root = getRoot()
    if not root then return true end

    tweenTo(part.Position + Vector3.new(0, 4, 0))

    local started = os.clock()
    local captured = false
    while ENI_UI.isFarming() and os.clock() - started < 40 do
        local now = readTerritory(part)
        if now and now.ours then
            captured = true
            break
        end
        if not now then
            break
        end
        task.wait(0.4)
    end
    if captured then ENI_UI.bumpStat("territory") end
    return true
end

local function doAirdrop()
    if not getAirdropRing() then return false end
    ensureDimension("overworld")
    if not ENI_UI.isFarming() then return true end

    ENI_UI.setStatus("Airdrop", "Chasing drop", "active")
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
    while ENI_UI.isFarming() and getAirdropRing() and os.clock() - started < 30 do
        task.wait(0.5)
    end
    ENI_UI.bumpStat("drop")
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
                if obj.Size.X < 1 then skip = true end
                if obj.AssemblyLinearVelocity.Y < -1 then skip = true end
            end
            if not skip then
                local pos = getModelPosition(obj)
                if pos and pos.Y >= ENI_UI.settings.gemYMin then
                    local entry = {
                        model = obj, pos = pos,
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
    if not ENI_UI.isFarming() then return false end
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
            ENI_UI.setStatus("Idle", "Wiped visit memory, rescanning", "idle")
            return true
        end
        ENI_UI.setStatus("Idle",
            string.format("No gems · big:%d normal:%d", #result.big, #result.normal),
            "idle")
        return false
    end

    emptyScanSince = nil
    ensureDimension("overworld")
    if not ENI_UI.isFarming() then return false end
    if not target.model.Parent then return true end

    ENI_UI.setStatus(isBig and "Big gem" or "Gem",
        string.format("%d m away", math.floor(target.dist)), "active")
    tweenTo(target.pos)
    ENI_UI.bumpStat("gem")
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
        if not ENI_UI.isFarming() then
            ENI_UI.setStatus("Paused", "Farming stopped", "paused")
            task.wait(0.25)
        elseif not getRoot() then
            ENI_UI.setStatus("Waiting", "Character not loaded", "paused")
            task.wait(1)
        else
            local acted = false

            -- PHASE 1: supermarket
            if not supermarketClean then
                if currentDimension() ~= "supermarket" then
                    ENI_UI.setStatus("Entering supermarket", "Dimension swap", "active")
                    ensureDimension("supermarket")
                    task.wait(0.5)
                else
                    for _, def in ipairs(TERRITORY_DEFS) do
                        if not ENI_UI.isFarming() then break end
                        if def.dimension == "supermarket"
                           and not ENI_UI.settings.blacklist[def.label] then
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
                            ENI_UI.setStatus("Supermarket done", "Moving to overworld", "active")
                        end
                    end
                end
            end

            -- PHASE 2: overworld
            if ENI_UI.isFarming() and not acted and supermarketClean then
                if currentDimension() ~= "overworld" then
                    ENI_UI.setStatus("Entering overworld", "Dimension swap", "active")
                    ensureDimension("overworld")
                    task.wait(0.5)
                else
                    for _, def in ipairs(TERRITORY_DEFS) do
                        if not ENI_UI.isFarming() then break end
                        if def.dimension == "overworld"
                           and not ENI_UI.settings.blacklist[def.label] then
                            local part = resolvePath(def.path)
                            local info = readTerritory(part)
                            if info and not info.ours
                            and (CAPTURE_OTHERS or info.owner == "Nobody" or info.owner == "Unknown") then
                                if captureOne(def) then acted = true end
                                if acted then break end
                            end
                        end
                    end

                    if ENI_UI.isFarming() and not acted then
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
--  TERRITORY LIST REFRESH
--============================================================
task.spawn(function()
    while true do
        pcall(ENI_UI.refreshTerritories)
        task.wait(1)
    end
end)
