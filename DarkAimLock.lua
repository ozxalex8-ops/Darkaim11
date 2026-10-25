          E  lock on / off        Q / Z  next / previous target        K  hide the window
    ]]

    local Players = game:GetService("Players")
    local UserInputService = game:GetService("UserInputService")
    local RunService = game:GetService("RunService")
    local Workspace = game:GetService("Workspace")
    local HttpService = game:GetService("HttpService")
    local TweenService = game:GetService("TweenService")
    local ReplicatedStorage = game:GetService("ReplicatedStorage")

    local localPlayer = Players.LocalPlayer
    local playerGui = localPlayer:WaitForChild("PlayerGui")

    --------------------------------------------------------------------------------
    -- Constants
    --------------------------------------------------------------------------------
    local VERSION = "v11.2"
    local GUI_NAME = "DarkAimLock"
    local LEGACY_GUI_NAME = "DarkAimPro"             -- the old window: closed automatically so two scripts never fight
    local TRAINING_FOLDER_NAME = "TrainingTargets"
    local SETTINGS_REMOTE_NAME = "DarkAimProSettings" -- RemoteFunction created by DarkAimProSettingsServer
    local SAVE_DEBOUNCE = 4
    local REQUEST_TIMEOUT = 8
    local LOST_GRACE = 0.25
    local FLICK_TRAVEL = 60
    local MARKER_SIZE = 26
    local PANEL_TRANSPARENCY = 0.14
    -- Teams are read from the Teams service first. Games that keep teams in attributes / values instead are read from
    -- these names (on the player, its character, or its leaderstats). Add your game's own name here if needed.
    local TEAM_ATTRIBUTE_NAMES = { "Team", "TeamName", "TeamId", "Faction", "Clan", "Crew", "Party", "Squad", "Guild" }

    local renderStepName = "DarkAimLock_" .. HttpService:GenerateGUID(false)

    local AIM_PARTS = {
        Head = { "Head", "HumanoidRootPart" },
        Torso = { "UpperTorso", "Torso", "HumanoidRootPart" },
        Root = { "HumanoidRootPart" },
    }

    local Config = {
        Keybind = Enum.KeyCode.E,
        SwitchKey = Enum.KeyCode.Q,
        SwitchPrevKey = Enum.KeyCode.Z,
        MenuKey = Enum.KeyCode.K,
        IgnoreKey = Enum.KeyCode.N,

        ActivationMode = "Toggle",
        AimPart = "Head",
        LockStyle = "Hard",
        Smoothness = 0.25,
        Prediction = 0,
        Mode360 = false,
        FOV = 180,
        MaxDistance = 500,
        Priority = "Crosshair",
        LostBehavior = "Reacquire",
        KeepThroughWalls = true,
        BreakOnFlick = false,

        TargetPlayers = true,
        TargetTraining = true,
        IgnoreTeammates = true,
        IgnoreFriends = false,
        WallCheck = false,

        SpawnPattern = "Jump",
        SpawnCount = 3,

        ShowHUD = true,
        ShowFOV = true,
    }

    local Limits = {
        FOV = { Min = 60, Max = 350, Step = 10 },
        Smoothness = { Min = 0.02, Max = 0.6, Step = 0.01 },
        Prediction = { Min = 0, Max = 0.3, Step = 0.01 },
        MaxDistance = { Min = 50, Max = 1000, Step = 10 },
        SpawnCount = { Min = 1, Max = 6, Step = 1 },
    }

    local ENUM_VALUES = {
        ActivationMode = { "Toggle", "Hold" },
        AimPart = { "Head", "Torso", "Root" },
        LockStyle = { "Hard", "Smooth" },
        Priority = { "Crosshair", "Distance", "Lowest HP" },
        LostBehavior = { "Release", "Reacquire" },
        SpawnPattern = { "Static", "Strafe", "Jump" },
    }

    local SETTING_KEYS = {
        "ActivationMode", "AimPart", "LockStyle", "Smoothness", "Prediction", "Mode360", "FOV", "MaxDistance",
        "Priority", "LostBehavior", "KeepThroughWalls", "BreakOnFlick",
        "TargetPlayers", "TargetTraining", "IgnoreTeammates", "IgnoreFriends", "WallCheck",
        "SpawnPattern", "SpawnCount", "ShowHUD", "ShowFOV",
    }
    local BIND_KEYS = { "Keybind", "SwitchKey", "SwitchPrevKey", "MenuKey", "IgnoreKey" }
    local BIND_LABELS = {
        Keybind = "Lock on / off",
        SwitchKey = "Next target",
        SwitchPrevKey = "Previous target",
        MenuKey = "Hide window",
        IgnoreKey = "Never lock the current target",
    }

    local COLORS = {
        Background = Color3.fromRGB(11, 13, 19),
        Card = Color3.fromRGB(26, 30, 43),
        Element = Color3.fromRGB(40, 47, 66),
        Border = Color3.fromRGB(86, 100, 138),
        Accent = Color3.fromRGB(96, 150, 255),
        Text = Color3.fromRGB(240, 243, 250),
        Muted = Color3.fromRGB(150, 159, 180),
        Green = Color3.fromRGB(80, 230, 160),
        Red = Color3.fromRGB(255, 105, 120),
        Warn = Color3.fromRGB(255, 200, 90),
    }

    local State = {
        Enabled = false,
        Destroyed = false,
        UIVisible = true,
        WaitingFor = nil,
        Tab = "AIM",
        Target = nil,
        Searching = false,
        LostTime = 0,
        HoldActive = false,
        MouseTravel = 0,
        PopKey = nil,
        DraggingPanel = false,
        DraggingSlider = nil,
    }

    local connections = {}
    local function track(connection)
        table.insert(connections, connection)
        return connection
    end

    --------------------------------------------------------------------------------
    -- Settings: validation, save, load
    --------------------------------------------------------------------------------
    -- a loaded value is only accepted if it has the right type AND is inside the valid range / option list
    local function sanitizeValue(key, v)
        local expected = type(Config[key])
        if v == nil or type(v) ~= expected then return nil end
        if expected == "number" then
            if v ~= v or v == math.huge or v == -math.huge then return nil end
            local limits = Limits[key]
            if limits then v = math.clamp(v, limits.Min, limits.Max) end
            if key == "SpawnCount" then v = math.floor(v + 0.5) end
            return v
        elseif expected == "string" then
            local allowed = ENUM_VALUES[key]
            if allowed and table.find(allowed, v) then return v end
            return nil
        end
        return v
    end

    local function serializeBind(bind)
        return { Type = (bind.EnumType == Enum.KeyCode) and "KeyCode" or "UserInputType", Name = bind.Name }
    end

    local function deserializeBind(d)
        if type(d) ~= "table" or type(d.Name) ~= "string" then return nil end
        if d.Type == "KeyCode" then
            local ok, item = pcall(function() return Enum.KeyCode:FromName(d.Name) end)
            if ok and item and item ~= Enum.KeyCode.Unknown and item ~= Enum.KeyCode.Escape then return item end
        elseif d.Type == "UserInputType" and (d.Name == "MouseButton2" or d.Name == "MouseButton3") then
            return Enum.UserInputType[d.Name]
        end
        return nil
    end

    local Persist = {
        Remote = nil,
        Ready = false,   -- true only after the settings were loaded (or confirmed new)
        Pending = false, -- a debounced save is scheduled
        Saving = false,  -- a save call is in flight
        Dirty = false,   -- something changed while a save was in flight
        Failures = 0,
        LastSignature = nil,
        Status = "Loading...",
    }

    local function buildPayload()
        local payload = { Version = 2, Config = {}, Binds = {} }
        for _, key in ipairs(SETTING_KEYS) do payload.Config[key] = Config[key] end
        for _, key in ipairs(BIND_KEYS) do payload.Binds[key] = serializeBind(Config[key]) end
        return payload
    end

    local function stable(value)
        if type(value) == "table" then
            local keys = {}
            for k in pairs(value) do table.insert(keys, tostring(k)) end
            table.sort(keys)
            local parts = {}
            for _, k in ipairs(keys) do table.insert(parts, k .. "=" .. stable(value[k])) end
            return "{" .. table.concat(parts, ",") .. "}"
        end
        return tostring(value)
    end

    -- RemoteFunction call with a timeout and class validation. Returns ok, result.
    local function invokeWithTimeout(remote, timeout, ...)
        if typeof(remote) ~= "Instance" or not remote:IsA("RemoteFunction") then
            return false, "invalid RemoteFunction"
        end
        local args = table.pack(...)
        local done, ok, result = false, false, nil
        task.spawn(function()
            ok, result = pcall(function() return remote:InvokeServer(table.unpack(args, 1, args.n)) end)
            done = true
        end)
        local started = os.clock()
        while not done and os.clock() - started < timeout do task.wait(0.05) end
        if not done then return false, "timeout" end
        return ok, result
    end

    local refreshUI -- defined with the UI

    local scheduleSave
    local function saveNow(force)
        if not Persist.Ready or not Persist.Remote then return end
        if State.Destroyed and not force then return end
        if Persist.Saving then Persist.Dirty = true; return end -- a change is never dropped: it is saved after this call

        local payload = buildPayload()
        local signature = stable(payload)
        if signature == Persist.LastSignature then return end

        Persist.Saving = true
        local ok, response = invokeWithTimeout(Persist.Remote, REQUEST_TIMEOUT, "Save", payload)
        Persist.Saving = false

        local saved = ok and (response == true or (type(response) == "table" and response.Status == "OK"))
        if saved then
            Persist.LastSignature = signature
            Persist.Failures = 0
            Persist.Status = "Synced"
        else
            Persist.Failures += 1
            local message = (ok and type(response) == "table" and response.Message) or (ok and "bad response") or tostring(response)
            Persist.Status = "Save failed: " .. tostring(message)
            warn("[DarkAimLock] settings save failed: " .. tostring(message))
        end

        if not State.Destroyed then
            if saved and Persist.Dirty then
                Persist.Dirty = false
                scheduleSave()
            elseif not saved and Persist.Failures < 5 then
                Persist.Dirty = false
                scheduleSave(10) -- a real retry
            end
            if refreshUI then refreshUI() end
        end
    end

    scheduleSave = function(delay)
        if not Persist.Ready or Persist.Pending or State.Destroyed then return end
        Persist.Pending = true
        task.delay(delay or SAVE_DEBOUNCE, function()
            Persist.Pending = false
            saveNow(false)
        end)
    end

    local function applyLoadedData(data)
        if type(data) ~= "table" then return false end
        if type(data.Config) == "table" then
            for _, key in ipairs(SETTING_KEYS) do
                local v = sanitizeValue(key, data.Config[key])
                if v ~= nil then Config[key] = v end
            end
        end
        if type(data.Binds) == "table" then
            for _, key in ipairs(BIND_KEYS) do
                local bind = deserializeBind(data.Binds[key])
                if bind then Config[key] = bind end
            end
        end
        return true
    end

    --------------------------------------------------------------------------------
    -- Previous windows
    --------------------------------------------------------------------------------
    local function unbindRenderStep(name)
        pcall(function() RunService:UnbindFromRenderStep(name) end)
    end

    do
        local legacy = playerGui:FindFirstChild(LEGACY_GUI_NAME)
        if legacy then legacy:Destroy() end -- the old script cleans itself up when its window is destroyed
        local previous = playerGui:FindFirstChild(GUI_NAME)
        if previous then
            local old = previous:GetAttribute("RenderStep")
            if old then unbindRenderStep(old) end
            previous:Destroy()
        end
    end

    --------------------------------------------------------------------------------
    -- UI helpers
    --------------------------------------------------------------------------------
    local function create(className, props, parent)
        local instance = Instance.new(className)
        for property, value in pairs(props or {}) do instance[property] = value end
        instance.Parent = parent
        return instance
    end

    local function corner(instance, radius)
        create("UICorner", { CornerRadius = UDim.new(0, radius or 8) }, instance)
    end

    local function stroke(instance, color, thickness, transparency)
        return create("UIStroke", {
            Color = color,
            Thickness = thickness or 1,
            Transparency = transparency or 0.5,
            ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
        }, instance)
    end

    local function label(parent, text, size, position, options)
        options = options or {}
        return create("TextLabel", {
            BackgroundTransparency = 1,
            Text = text,
            Size = size,
            Position = position or UDim2.new(),
            Font = options.Font or Enum.Font.GothamMedium,
            TextSize = options.TextSize or 13,
            TextColor3 = options.Color or COLORS.Text,
            TextXAlignment = options.Align or Enum.TextXAlignment.Left,
            TextYAlignment = Enum.TextYAlignment.Center,
            TextTruncate = Enum.TextTruncate.AtEnd,
        }, parent)
    end

    local function button(parent, text, size, position)
        local b = create("TextButton", {
            Size = size,
            Position = position or UDim2.new(),
            BackgroundColor3 = COLORS.Element,
            BackgroundTransparency = 0.25,
            Text = text,
            TextColor3 = COLORS.Text,
            TextSize = 12,
            Font = Enum.Font.GothamSemibold,
            AutoButtonColor = true,
            BorderSizePixel = 0,
        }, parent)
        corner(b, 8)
        return b
    end

    local function isPointerBegin(input)
        return input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch
    end
    local function isPointerMove(input)
        return input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch
    end

    --------------------------------------------------------------------------------
    -- Screen overlay (FOV circle, crosshair, marker, HUD, toast)
    --------------------------------------------------------------------------------
    local gui = create("ScreenGui", {
        Name = GUI_NAME, ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 20,
    }, playerGui)
    gui:SetAttribute("RenderStep", renderStepName)

    local fovCircle = create("Frame", {
        Name = "FOVCircle", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
        Size = UDim2.fromOffset(Config.FOV * 2, Config.FOV * 2), BackgroundTransparency = 1, Visible = false,
    }, gui)
    corner(fovCircle, 1000)
    stroke(fovCircle, COLORS.Accent, 1.5, 0.55)

    local crosshair = create("Frame", {
        Name = "Crosshair", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
        Size = UDim2.fromOffset(6, 6), BackgroundColor3 = COLORS.Accent, BorderSizePixel = 0, Visible = false,
    }, gui)
    corner(crosshair, 3)

    local marker = create("Frame", {
        Name = "LockMarker", AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(MARKER_SIZE, MARKER_SIZE),
        Rotation = 45, BackgroundTransparency = 1, Visible = false,
    }, gui)
    corner(marker, 5)
    local markerStroke = stroke(marker, COLORS.Red, 2, 0)

    local hud = create("Frame", {
        Name = "TargetHUD", AnchorPoint = Vector2.new(0.5, 0), Size = UDim2.fromOffset(270, 34),
        BackgroundTransparency = 1, Visible = false,
    }, gui)
    local hudName = label(hud, "", UDim2.new(1, 0, 0, 16), UDim2.new(), { Align = Enum.TextXAlignment.Center, TextSize = 11 })
    local hudBarBack = create("Frame", {
        Size = UDim2.new(0.7, 0, 0, 5), AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 21),
        BackgroundColor3 = COLORS.Element, BorderSizePixel = 0,
    }, hud)
    corner(hudBarBack, 5)
    local hudBarFill = create("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = COLORS.Green, BorderSizePixel = 0 }, hudBarBack)
    corner(hudBarFill, 5)

    local toast = label(gui, "", UDim2.fromOffset(380, 24), UDim2.new(0.5, 0, 0, 18), {
        Align = Enum.TextXAlignment.Center, TextSize = 13, Font = Enum.Font.GothamSemibold,
    })
    toast.AnchorPoint = Vector2.new(0.5, 0)
    toast.TextTransparency = 1
    local toastToken = 0
    local function notify(text)
        toastToken += 1
        local token = toastToken
        toast.Text = text
        toast.TextTransparency = 0
        task.delay(1.8, function()
            if token ~= toastToken or State.Destroyed then return end
            TweenService:Create(toast, TweenInfo.new(0.4), { TextTransparency = 1 }):Play()
        end)
    end

    --------------------------------------------------------------------------------
    -- Window (semi-transparent, rounded)
    --------------------------------------------------------------------------------
    local panel = create("Frame", {
        Name = "Window", Size = UDim2.fromOffset(336, 540), Position = UDim2.new(0, 24, 0.5, -270),
        BackgroundColor3 = COLORS.Background, BackgroundTransparency = PANEL_TRANSPARENCY, BorderSizePixel = 0,
    }, gui)
    corner(panel, 18)
    stroke(panel, COLORS.Border, 1.2, 0.45)

    local header = create("Frame", { Name = "Header", Size = UDim2.new(1, 0, 0, 58), BackgroundTransparency = 1 }, panel)
    create("Frame", {
        Size = UDim2.fromOffset(4, 30), Position = UDim2.fromOffset(16, 14), BackgroundColor3 = COLORS.Accent, BorderSizePixel = 0,
    }, header)
    label(header, "DARK AIM", UDim2.fromOffset(160, 22), UDim2.fromOffset(30, 9), { TextSize = 17, Font = Enum.Font.GothamBold })
    label(header, "LOCK-ON  ·  " .. VERSION, UDim2.fromOffset(200, 14), UDim2.fromOffset(30, 33), { TextSize = 9, Color = COLORS.Muted })
    local hideButton = button(header, "–", UDim2.fromOffset(30, 30), UDim2.new(1, -46, 0, 14))
    hideButton.TextSize = 18

    local statusCard = create("Frame", {
        Position = UDim2.fromOffset(14, 62), Size = UDim2.new(1, -28, 0, 62),
        BackgroundColor3 = COLORS.Card, BackgroundTransparency = 0.35, BorderSizePixel = 0,
    }, panel)
    corner(statusCard, 12)
    local statusValue = label(statusCard, "●  OFF", UDim2.fromOffset(170, 24), UDim2.fromOffset(14, 8), {
        TextSize = 16, Font = Enum.Font.GothamBold, Color = COLORS.Red,
    })
    local statusSub = label(statusCard, "Idle", UDim2.new(1, -120, 0, 18), UDim2.fromOffset(14, 34), { TextSize = 11, Color = COLORS.Muted })
    local toggleButton = button(statusCard, "ENABLE", UDim2.fromOffset(86, 34), UDim2.new(1, -100, 0.5, -17))
    toggleButton.BackgroundColor3 = COLORS.Accent
    toggleButton.BackgroundTransparency = 0.1

    local tabBar = create("Frame", { Position = UDim2.fromOffset(14, 132), Size = UDim2.new(1, -28, 0, 32), BackgroundTransparency = 1 }, panel)
    create("UIListLayout", {
        FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder,
    }, tabBar)

    local pagesHolder = create("Frame", {
        Position = UDim2.fromOffset(14, 172), Size = UDim2.new(1, -28, 1, -186), BackgroundTransparency = 1, ClipsDescendants = true,
    }, panel)

    local refreshers = {}
    local function onRefresh(callback) table.insert(refreshers, callback) end

    local pages, tabButtons, orders = {}, {}, {}

    local function newPage(name, order)
        local page = create("ScrollingFrame", {
            Name = name, Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, BorderSizePixel = 0,
            ScrollBarThickness = 3, ScrollBarImageColor3 = COLORS.Border, CanvasSize = UDim2.new(),
            AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollingDirection = Enum.ScrollingDirection.Y, Visible = false,
        }, pagesHolder)
        create("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }, page)
        create("UIPadding", { PaddingRight = UDim.new(0, 6), PaddingBottom = UDim.new(0, 8) }, page)
        pages[name] = page

        local tab = button(tabBar, name, UDim2.new(1 / 3, -4, 1, 0), UDim2.new())
        tab.LayoutOrder = order
        tabButtons[name] = tab
        track(tab.Activated:Connect(function()
            State.Tab = name
            refreshUI()
        end))
        return page
    end

    local aimPage = newPage("AIM", 1)
    local targetsPage = newPage("TARGETS", 2)
    local keysPage = newPage("KEYS", 3)

    local function addRow(page, height)
        orders[page] = (orders[page] or 0) + 1
        local row = create("Frame", {
            Size = UDim2.new(1, 0, 0, height), BackgroundColor3 = COLORS.Card, BackgroundTransparency = 0.45,
            BorderSizePixel = 0, LayoutOrder = orders[page],
        }, page)
        corner(row, 10)
        return row
    end

    local function addSection(page, text)
        orders[page] = (orders[page] or 0) + 1
        local l = label(page, text, UDim2.new(1, 0, 0, 18), UDim2.new(), { TextSize = 10, Color = COLORS.Muted, Font = Enum.Font.GothamBold })
        l.LayoutOrder = orders[page]
    end

    local function setConfig(key, value)
        Config[key] = value
        refreshUI()
        scheduleSave()
    end

    -- segmented control: 2-4 options side by side
    local function addSegmented(page, text, key, options)
        local row = addRow(page, 56)
        label(row, text, UDim2.new(1, -20, 0, 18), UDim2.fromOffset(10, 5), { TextSize = 12 })
        local bar = create("Frame", {
            Position = UDim2.fromOffset(10, 25), Size = UDim2.new(1, -20, 0, 26), BackgroundColor3 = COLORS.Element,
            BackgroundTransparency = 0.4, BorderSizePixel = 0,
        }, row)
        corner(bar, 8)
        create("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 3), SortOrder = Enum.SortOrder.LayoutOrder }, bar)
        create("UIPadding", { PaddingTop = UDim.new(0, 2), PaddingBottom = UDim.new(0, 2) }, bar)
        local n = #options
        local buttons = {}
        for i, option in ipairs(options) do
            local b = button(bar, option, UDim2.new(1 / n, -3 * (n - 1) / n, 1, 0), UDim2.new())
            b.LayoutOrder = i
            b.TextSize = 11
            buttons[option] = b
            track(b.Activated:Connect(function() setConfig(key, option) end))
        end
        onRefresh(function()
            for option, b in pairs(buttons) do
                local on = Config[key] == option
                b.BackgroundColor3 = on and COLORS.Accent or COLORS.Element
                b.BackgroundTransparency = on and 0.05 or 1
                b.TextColor3 = on and COLORS.Text or COLORS.Muted
            end
        end)
    end

    local function addToggle(page, text, key)
        local row = addRow(page, 36)
        label(row, text, UDim2.new(1, -70, 1, 0), UDim2.fromOffset(10, 0), { TextSize = 12 })
        local track_ = create("TextButton", {
            Size = UDim2.fromOffset(40, 20), Position = UDim2.new(1, -52, 0.5, -10), Text = "", AutoButtonColor = false,
            BackgroundColor3 = COLORS.Element, BorderSizePixel = 0,
        }, row)
        corner(track_, 10)
        local knob = create("Frame", {
            Size = UDim2.fromOffset(14, 14), Position = UDim2.fromOffset(3, 3), BackgroundColor3 = COLORS.Text, BorderSizePixel = 0,
        }, track_)
        corner(knob, 7)
        track(track_.Activated:Connect(function() setConfig(key, not Config[key]) end))
        onRefresh(function()
            local on = Config[key]
            TweenService:Create(knob, TweenInfo.new(0.12), { Position = on and UDim2.fromOffset(23, 3) or UDim2.fromOffset(3, 3) }):Play()
            TweenService:Create(track_, TweenInfo.new(0.12), { BackgroundColor3 = on and COLORS.Accent or COLORS.Element }):Play()
        end)
    end

    local function addSlider(page, text, key, limits, format)
        local row = addRow(page, 50)
        label(row, text, UDim2.new(0.6, 0, 0, 22), UDim2.fromOffset(10, 4), { TextSize = 12 })
        local value = label(row, "", UDim2.new(0.4, -20, 0, 22), UDim2.new(0.6, 10, 0, 4), {
            Align = Enum.TextXAlignment.Right, Color = COLORS.Accent, TextSize = 12,
        })
        local rail = create("Frame", {
            Position = UDim2.fromOffset(10, 33), Size = UDim2.new(1, -20, 0, 6), BackgroundColor3 = COLORS.Element, BorderSizePixel = 0,
        }, row)
        corner(rail, 3)
        local fill = create("Frame", { Size = UDim2.fromScale(0.5, 1), BackgroundColor3 = COLORS.Accent, BorderSizePixel = 0 }, rail)
        corner(fill, 3)
        local hit = create("TextButton", {
            Size = UDim2.new(1, 0, 0, 24), Position = UDim2.new(0, 0, 0.5, -12), BackgroundTransparency = 1, Text = "", AutoButtonColor = false,
        }, rail)
        local function setFromX(x)
            local width = rail.AbsoluteSize.X
            if width < 1 then return end
            local a = math.clamp((x - rail.AbsolutePosition.X) / width, 0, 1)
            local raw = limits.Min + a * (limits.Max - limits.Min)
            local snapped = math.round(raw / limits.Step) * limits.Step
            local clamped = math.clamp(snapped, limits.Min, limits.Max)
            if clamped ~= clamped then return end
            setConfig(key, math.round(clamped * 1000) / 1000)
        end
        track(hit.InputBegan:Connect(function(input)
            if isPointerBegin(input) then
                State.DraggingSlider = setFromX
                setFromX(input.Position.X)
            end
        end))
        onRefresh(function()
            value.Text = string.format(format, Config[key])
            fill.Size = UDim2.fromScale(math.clamp((Config[key] - limits.Min) / (limits.Max - limits.Min), 0, 1), 1)
        end)
    end

    local function addKeybind(page, text, key)
        local row = addRow(page, 36)
        label(row, text, UDim2.new(1, -120, 1, 0), UDim2.fromOffset(10, 0), { TextSize = 12 })
        local b = button(row, "", UDim2.fromOffset(94, 26), UDim2.new(1, -104, 0.5, -13))
        track(b.Activated:Connect(function()
            State.WaitingFor = key
            refreshUI()
        end))
        onRefresh(function()
            b.Text = State.WaitingFor == key and "Press a key..." or Config[key].Name
            b.TextColor3 = State.WaitingFor == key and COLORS.Warn or COLORS.Text
        end)
    end

    local function addButtons(page, buttons)
        local row = addRow(page, 40)
        create("UIListLayout", {
            FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center,
            Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder,
        }, row)
        create("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }, row)
        local n = #buttons
        for i, def in ipairs(buttons) do
            local b = button(row, def.Text, UDim2.new(1 / n, -6 * (n - 1) / n, 0, 28), UDim2.new())
            b.LayoutOrder = i
            track(b.Activated:Connect(def.Callback))
        end
    end

    local function addInfo(page, text, getter)
        local row = addRow(page, 30)
        label(row, text, UDim2.new(0.45, 0, 1, 0), UDim2.fromOffset(10, 0), { TextSize = 12, Color = COLORS.Muted })
        local value = label(row, "", UDim2.new(0.55, -20, 1, 0), UDim2.new(0.45, 10, 0, 0), {
            Align = Enum.TextXAlignment.Right, TextSize = 11, Color = COLORS.Accent,
        })
        onRefresh(function() value.Text = getter() end)
    end

    --------------------------------------------------------------------------------
    -- State changes
    --------------------------------------------------------------------------------
    local function setStatus(text)
        if statusSub.Text ~= text then statusSub.Text = text end
    end

    function refreshUI()
        statusValue.Text = State.Enabled and "●  LOCK ON" or "●  OFF"
        statusValue.TextColor3 = State.Enabled and COLORS.Green or COLORS.Red
        toggleButton.Text = State.Enabled and "DISABLE" or "ENABLE"
        toggleButton.BackgroundColor3 = State.Enabled and COLORS.Element or COLORS.Accent
        fovCircle.Size = UDim2.fromOffset(Config.FOV * 2, Config.FOV * 2)
        fovCircle.Visible = State.Enabled and Config.ShowFOV and not Config.Mode360
        crosshair.Visible = State.Enabled
        panel.Visible = State.UIVisible
        if not State.Enabled then
            marker.Visible = false
            hud.Visible = false
        end
        for name, page in pairs(pages) do
            local active = State.Tab == name
            page.Visible = active
            local tab = tabButtons[name]
            tab.BackgroundColor3 = active and COLORS.Accent or COLORS.Element
            tab.BackgroundTransparency = active and 0.1 or 0.45
            tab.TextColor3 = active and COLORS.Text or COLORS.Muted
        end
        for _, callback in ipairs(refreshers) do callback() end
    end

    local function setUIVisible(visible)
        State.UIVisible = visible
        refreshUI()
        if not visible then notify("Window hidden  ·  press " .. Config.MenuKey.Name .. " to show it") end
    end

    local function setEnabled(value)
        if not value then State.HoldActive = false end
        if State.Enabled == value then return end
        State.Enabled = value
        State.Target = nil
        State.LostTime = 0
        State.Searching = value
        State.MouseTravel = 0
        State.PopKey = nil
        marker.Visible = false
        hud.Visible = false
        setStatus(value and "Searching..." or "Idle")
        refreshUI()
    end

    --------------------------------------------------------------------------------
    -- Practice dummies (client-side): Static / Strafe / Jump
    --------------------------------------------------------------------------------
    local Dummies = {}
    local dummyConnection = nil

    local function clearDummies()
        if dummyConnection then
            dummyConnection:Disconnect()
            dummyConnection = nil
        end
        for model in pairs(Dummies) do model:Destroy() end
        table.clear(Dummies)
        local folder = Workspace:FindFirstChild(TRAINING_FOLDER_NAME)
        if folder and #folder:GetChildren() == 0 then folder:Destroy() end -- no empty folder left behind
    end

    local function dummyPart(name, size, color, shape, parent)
        return create("Part", {
            Name = name, Size = size, Color = color, Shape = shape or Enum.PartType.Block,
            Material = Enum.Material.SmoothPlastic, Anchored = true, CanCollide = false,
            TopSurface = Enum.SurfaceType.Smooth, BottomSurface = Enum.SurfaceType.Smooth,
        }, parent)
    end

    local function buildDummy(index)
        local model = Instance.new("Model")
        model.Name = "Dummy" .. index
        local root = dummyPart("HumanoidRootPart", Vector3.new(2, 2, 1), COLORS.Accent, nil, model)
        root.Transparency = 1
        dummyPart("Torso", Vector3.new(2, 2, 1), COLORS.Accent, nil, model)
        local head = dummyPart("Head", Vector3.new(1.3, 1.3, 1.3), COLORS.Warn, Enum.PartType.Ball, model)
        head.Position = Vector3.new(0, 1.6, 0)
        model.PrimaryPart = root
        local humanoid = Instance.new("Humanoid")
        humanoid.RequiresNeck = false
        humanoid.BreakJointsOnDeath = false
        humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
        humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
        humanoid.MaxHealth = 100
        humanoid.Health = math.random(40, 100)
        humanoid.Parent = model
        return model
    end

    local function updateDummies(dt)
        if dt <= 0 then return end
        for model, data in pairs(Dummies) do
            if model.Parent then
                data.Time += dt
                local t = data.Time + data.Phase
                local offset = Vector3.zero
                if data.Pattern == "Strafe" then
                    offset = data.Right * (math.sin(t * 0.7) * 14)
                elseif data.Pattern == "Jump" then
                    -- hops up to 9 studs while strafing: the case the lock has to survive
                    offset = data.Right * (math.sin(t * 0.5) * 8) + Vector3.new(0, math.abs(math.sin(t * 2.2)) * 9, 0)
                end
                local newPos = data.Origin + offset
                model:SetAttribute("DarkAimVelocity", (newPos - data.LastPosition) / dt)
                data.LastPosition = newPos
                local look = Vector3.new(data.Center.X, newPos.Y, data.Center.Z)
                if (look - newPos).Magnitude > 1e-3 then
                    model:PivotTo(CFrame.lookAt(newPos, look))
                else
                    model:PivotTo(CFrame.new(newPos))
                end
            end
        end
    end

    local function spawnDummies()
        local cam = Workspace.CurrentCamera
        if not cam then return end
        clearDummies()
        local folder = Workspace:FindFirstChild(TRAINING_FOLDER_NAME)
        if not folder then
            folder = Instance.new("Folder")
            folder.Name = TRAINING_FOLDER_NAME
            folder.Parent = Workspace
        end
        local char = localPlayer.Character
        local root = char and char:FindFirstChild("HumanoidRootPart")
        local center = root and root.Position or cam.CFrame.Position
        local flat = Vector3.new(cam.CFrame.LookVector.X, 0, cam.CFrame.LookVector.Z)
        if flat.Magnitude < 1e-3 then flat = Vector3.new(0, 0, -1) end
        flat = flat.Unit
        local count = Config.SpawnCount
        for i = 1, count do
            local model = buildDummy(i)
            local spread = (i - (count + 1) / 2) * math.rad(16)
            local dir = CFrame.fromAxisAngle(Vector3.yAxis, spread):VectorToWorldSpace(flat)
            local pos = center + dir * 45
            Dummies[model] = {
                Pattern = Config.SpawnPattern, Origin = pos, Right = dir:Cross(Vector3.yAxis).Unit,
                Center = center, Phase = (i - 1) * 0.9, Time = 0, LastPosition = pos,
            }
            model:PivotTo(CFrame.lookAt(pos, Vector3.new(center.X, pos.Y, center.Z)))
            model.Parent = folder
        end
        if Config.SpawnPattern ~= "Static" then
            dummyConnection = RunService.Heartbeat:Connect(updateDummies)
        end
        notify(string.format("Spawned %d dummies (%s)", count, Config.SpawnPattern))
    end

    --------------------------------------------------------------------------------
    -- Targeting
    --------------------------------------------------------------------------------
    local raycastParams = RaycastParams.new()
    raycastParams.FilterType = Enum.RaycastFilterType.Exclude
    raycastParams.RespectCanCollide = true

    local function getAimPart(model)
        if model:IsA("BasePart") then return model end
        for _, name in ipairs(AIM_PARTS[Config.AimPart] or AIM_PARTS.Head) do
            local part = model:FindFirstChild(name)
            if part and part:IsA("BasePart") then return part end
        end
        if model:IsA("Model") then return model.PrimaryPart end
        return nil
    end

    local function isAlive(model)
        local humanoid = model:FindFirstChildOfClass("Humanoid")
        return humanoid == nil or humanoid.Health > 0
    end

    local function getHealth(model)
        local humanoid = model:FindFirstChildOfClass("Humanoid")
        if humanoid and humanoid.MaxHealth > 0 then return humanoid.Health, humanoid.MaxHealth end
        return nil
    end

    local function getVelocity(part, model)
        local published = model:GetAttribute("DarkAimVelocity")
        if typeof(published) == "Vector3" then return published end
        return part.AssemblyLinearVelocity
    end

    -- An empty value ("", false, 0) means "no team": two players without a team are NOT teammates.
    local function validTeamValue(value)
        return value ~= nil and value ~= "" and value ~= false and value ~= 0
    end

    -- The team of a player as a comparable value, plus where it was found (nil when the team is unknown).
    -- Order: Teams service, TeamColor (legacy teams without a Team object), then attributes / values named like a team
    -- (see TEAM_ATTRIBUTE_NAMES) on the player, its character, or its leaderstats.
    local function teamKey(player)
        if player.Team then return player.Team, "Teams service" end
        if not player.Neutral then return player.TeamColor, "TeamColor" end
        for _, name in ipairs(TEAM_ATTRIBUTE_NAMES) do
            local fromPlayer = player:GetAttribute(name)
            if validTeamValue(fromPlayer) then return fromPlayer, "player attribute " .. name end
            local char = player.Character
            local fromCharacter = char and char:GetAttribute(name)
            if validTeamValue(fromCharacter) then return fromCharacter, "character attribute " .. name end
        end
        for _, holder in ipairs({ player, player:FindFirstChild("leaderstats") }) do
            for _, name in ipairs(TEAM_ATTRIBUTE_NAMES) do
                local child = holder:FindFirstChild(name)
                if child and child:IsA("ValueBase") and validTeamValue(child.Value) then
                    return child.Value, "value " .. child:GetFullName()
                end
            end
        end
        return nil, "none"
    end

    local function isTeammate(player)
        local mine = teamKey(localPlayer)
        return mine ~= nil and teamKey(player) == mine
    end

    -- friends (cached: IsFriendsWith yields) and a manual "never lock" list (this session)
    local friendCache = {}
    local ignoredPlayers = {}

    local function refreshFriend(player)
        if player == localPlayer then return end
        task.spawn(function()
            local ok, result = pcall(function() return localPlayer:IsFriendsWith(player.UserId) end)
            if ok then friendCache[player.UserId] = result end
        end)
    end
    for _, player in ipairs(Players:GetPlayers()) do refreshFriend(player) end
    track(Players.PlayerAdded:Connect(refreshFriend))

    local function ignoredCount()
        local count = 0
        for _ in pairs(ignoredPlayers) do count += 1 end
        return count
    end

    -- Diagnostic: shows exactly what the script sees for every player (full list in the Output window).
    local function checkTeams()
        local mine, mineSource = teamKey(localPlayer)
        local lines = { string.format("[DarkAimLock] you: team=%s (%s)", tostring(mine), mineSource) }
        local teammates, others = 0, 0
        for _, player in ipairs(Players:GetPlayers()) do
            if player ~= localPlayer then
                local key, source = teamKey(player)
                local mate = mine ~= nil and key == mine
                if mate then teammates += 1 else others += 1 end
                table.insert(lines, string.format("  %s: team=%s (%s) -> %s%s%s",
                    player.DisplayName, tostring(key), source, mate and "TEAMMATE" or "not a teammate",
                    friendCache[player.UserId] and " · friend" or "", ignoredPlayers[player.UserId] and " · ignored" or ""))
            end
        end
        print(table.concat(lines, "\n"))
        if mine == nil then
            notify("No team found for you: your game does not use Teams or the names in TEAM_ATTRIBUTE_NAMES (see Output)")
        else
            notify(string.format("Teams: %d teammate(s), %d other(s)  ·  details in Output", teammates, others))
        end
    end

    -- Always works, whatever the game uses for teams: stop locking this player.
    local function ignoreCurrent()
        local target = State.Target
        if not target then notify("Lock a player first, then press the ignore key"); return end
        if target.Kind ~= "Player" then notify("Only players can be added to the ignore list"); return end
        ignoredPlayers[target.Key.UserId] = true
        State.LostTime = LOST_GRACE -- leave this target on the next frame
        notify(target.Name .. " will never be locked (ignore list: " .. ignoredCount() .. ")")
        refreshUI()
    end

    local function clearIgnored()
        table.clear(ignoredPlayers)
        notify("Ignore list cleared")
        refreshUI()
    end

    local function getModel(candidate)
        if candidate.Kind == "Player" then return candidate.Key.Character end
        return candidate.Model
    end

    local function isAllowed(candidate)
        if candidate.Kind == "Training" then return Config.TargetTraining end
        if candidate.Kind == "Player" then
            return Config.TargetPlayers and candidate.Key.Parent ~= nil
                and not ignoredPlayers[candidate.Key.UserId]
                and not (Config.IgnoreFriends and friendCache[candidate.Key.UserId])
                and not (Config.IgnoreTeammates and isTeammate(candidate.Key))
        end
        return false
    end

    local function compareStable(a, b)
        if a.Rank ~= b.Rank then return a.Rank < b.Rank end
        if a.Order ~= b.Order then return a.Order < b.Order end
        return a.Name < b.Name
    end

    local function collectCandidates()
        local list = {}
        if Config.TargetPlayers then
            for _, player in ipairs(Players:GetPlayers()) do
                if player ~= localPlayer then
                    local candidate = { Key = player, Name = player.DisplayName, Kind = "Player", Rank = 1, Order = player.UserId }
                    if isAllowed(candidate) and player.Character then table.insert(list, candidate) end
                end
            end
        end
        if Config.TargetTraining then
            local folder = Workspace:FindFirstChild(TRAINING_FOLDER_NAME)
            if folder then
                for i, object in ipairs(folder:GetChildren()) do
                    table.insert(list, { Key = object, Model = object, Name = object.Name, Kind = "Training", Rank = 2, Order = i })
                end
            end
        end
        return list
    end

    local function hasLineOfSight(cam, targetPosition, targetModel)
        local ignore = { targetModel }
        local char = localPlayer.Character
        if char then table.insert(ignore, char) end
        raycastParams.FilterDescendantsInstances = ignore
        local origin = cam.CFrame.Position
        return Workspace:Raycast(origin, targetPosition - origin, raycastParams) == nil
    end

    -- The aim point is the REAL position of the aim part. Prediction only uses the horizontal speed, so a jump
    -- (vertical speed) can never push the aim point away from the part.
    local function getAimData(candidate, cam)
        local model = getModel(candidate)
        if not model or not model.Parent or not isAlive(model) then return nil end
        local part = getAimPart(model)
        if not part then return nil end
        if (part.Position - cam.CFrame.Position).Magnitude > Config.MaxDistance then return nil end
        local aim = part.Position
        if Config.Prediction > 0 then
            local velocity = getVelocity(part, model)
            aim += Vector3.new(velocity.X, 0, velocity.Z) * Config.Prediction
        end
        return part, model, aim
    end

    local function validateLock(candidate, cam)
        if not isAllowed(candidate) then return nil end
        local part, model, aim = getAimData(candidate, cam)
        if not part then return nil end
        if Config.WallCheck and not Config.KeepThroughWalls and not hasLineOfSight(cam, part.Position, model) then
            return nil
        end
        return aim
    end

    local function acquisitionScore(candidate, cam, center)
        local part, model, aim = getAimData(candidate, cam)
        if not part then return nil end
        local gate
        if Config.Mode360 then
            local offset = aim - cam.CFrame.Position
            if offset.Magnitude < 1e-3 then return nil end
            gate = math.deg(math.acos(math.clamp(cam.CFrame.LookVector:Dot(offset.Unit), -1, 1)))
        else
            local point, onScreen = cam:WorldToViewportPoint(aim)
            if not onScreen or point.Z <= 0 then return nil end
            gate = (Vector2.new(point.X, point.Y) - center).Magnitude
            if gate > Config.FOV then return nil end
        end
        if Config.WallCheck and not hasLineOfSight(cam, part.Position, model) then return nil end
        local score = gate
        if Config.Priority == "Distance" then
            score = (part.Position - cam.CFrame.Position).Magnitude
        elseif Config.Priority == "Lowest HP" then
            local health = getHealth(model)
            score = (health or 1e6) + gate * 0.001
        end
        return score, aim
    end

    local function collectRanked(cam)
        local viewport = cam.ViewportSize
        local center = Vector2.new(viewport.X / 2, viewport.Y / 2)
        local ranked = {}
        for _, candidate in ipairs(collectCandidates()) do
            local score, aim = acquisitionScore(candidate, cam, center)
            if score then table.insert(ranked, { Candidate = candidate, Score = score, AimPosition = aim }) end
        end
        table.sort(ranked, function(a, b) return a.Score < b.Score end)
        return ranked
    end

    local function collectSwitchList(cam)
        local list = {}
        for _, candidate in ipairs(collectCandidates()) do
            local part, model = getAimData(candidate, cam)
            if part and (not Config.WallCheck or hasLineOfSight(cam, part.Position, model)) then
                table.insert(list, candidate)
            end
        end
        if State.Target then
            local found = false
            for _, candidate in ipairs(list) do
                if candidate.Key == State.Target.Key then found = true; break end
            end
            if not found and validateLock(State.Target, cam) then table.insert(list, State.Target) end
        end
        table.sort(list, compareStable)
        return list
    end

    local function lockOn(candidate)
        State.Target = candidate
        State.LostTime = 0
        State.Searching = false
    end

    local function switchTarget(direction)
        local cam = Workspace.CurrentCamera
        if not cam then return end
        if not State.Target then
            local best = collectRanked(cam)[1]
            if best then lockOn(best.Candidate) end
            return
        end
        local list = collectSwitchList(cam)
        if #list == 0 then return end
        local index = 0
        for i, candidate in ipairs(list) do
            if candidate.Key == State.Target.Key then index = i; break end
        end
        local nextIndex
        if index == 0 then
            nextIndex = direction > 0 and 1 or #list
        else
            nextIndex = (index - 1 + direction) % #list + 1
        end
        local candidate = list[nextIndex]
        if candidate.Key ~= State.Target.Key then lockOn(candidate) end
    end

    local function handleTargetLost()
        State.Target = nil
        State.LostTime = 0
        State.PopKey = nil
        marker.Visible = false
        hud.Visible = false
        if Config.LostBehavior == "Release" then
            setEnabled(false)
        else
            State.Searching = true
        end
    end

    --------------------------------------------------------------------------------
    -- Marker + HUD
    --------------------------------------------------------------------------------
    local popTween = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

    local function playLockPop(candidate)
        if State.PopKey == candidate.Key then return end
        State.PopKey = candidate.Key
        marker.Size = UDim2.fromOffset(MARKER_SIZE * 2, MARKER_SIZE * 2)
        TweenService:Create(marker, popTween, { Size = UDim2.fromOffset(MARKER_SIZE, MARKER_SIZE) }):Play()
    end

    local function updateMarker(cam, aim)
        local viewport = cam.ViewportSize
        local center = Vector2.new(viewport.X / 2, viewport.Y / 2)
        local point, onScreen = cam:WorldToViewportPoint(aim)
        local position = Vector2.new(point.X, point.Y)
        local offscreen = (not onScreen) or point.Z <= 0
        if offscreen then
            local direction = position - center
            if point.Z < 0 then direction = -direction end
            if direction.Magnitude < 1e-3 then direction = Vector2.new(0, 1) end
            local margin = 40
            local sx = (center.X - margin) / math.max(math.abs(direction.X), 1e-3)
            local sy = (center.Y - margin) / math.max(math.abs(direction.Y), 1e-3)
            position = center + direction * math.min(sx, sy)
        end
        marker.Position = UDim2.fromOffset(position.X, position.Y)
        markerStroke.Color = offscreen and COLORS.Warn or COLORS.Red
        marker.Visible = true
        hud.Position = UDim2.fromOffset(position.X, position.Y + MARKER_SIZE)
        return offscreen
    end

    local function updateHUD(candidate, offscreen, distance)
        if not Config.ShowHUD or offscreen then
            hud.Visible = false
            return
        end
        hud.Visible = true
        local text = string.format("%s  ·  %.0f studs", candidate.Name, distance)
        if candidate.Kind == "Player" then
            local key = teamKey(candidate.Key)
            text = text .. "  ·  team: " .. (key ~= nil and tostring(key) or "none")
        end
        if hudName.Text ~= text then hudName.Text = text end
        local model = getModel(candidate)
        local health, maxHealth
        if model then health, maxHealth = getHealth(model) end
        if health then
            local fraction = math.clamp(health / maxHealth, 0, 1)
            hudBarBack.Visible = true
            hudBarFill.Size = UDim2.fromScale(fraction, 1)
            hudBarFill.BackgroundColor3 = COLORS.Red:Lerp(COLORS.Green, fraction)
        else
            hudBarBack.Visible = false
        end
    end

    --------------------------------------------------------------------------------
    -- Tabs content
    --------------------------------------------------------------------------------
    addSection(aimPage, "LOCK")
    addSegmented(aimPage, "Aim part", "AimPart", { "Head", "Torso", "Root" })
    addSegmented(aimPage, "Lock style", "LockStyle", { "Hard", "Smooth" })
    addSlider(aimPage, "Smoothness (Smooth style)", "Smoothness", Limits.Smoothness, "%.2f")
    addSlider(aimPage, "Prediction (horizontal only)", "Prediction", Limits.Prediction, "%.2fs")
    addSegmented(aimPage, "Target priority", "Priority", { "Crosshair", "Distance", "Lowest HP" })
    addSegmented(aimPage, "When the target is lost", "LostBehavior", { "Release", "Reacquire" })
    addSegmented(aimPage, "Activation", "ActivationMode", { "Toggle", "Hold" })
    addSection(aimPage, "ACQUISITION")
    addSlider(aimPage, "Field of view", "FOV", Limits.FOV, "%d px")
    addToggle(aimPage, "360° lock", "Mode360")
    addToggle(aimPage, "Release on a fast mouse flick", "BreakOnFlick")

    addSection(targetsPage, "WHO CAN BE LOCKED")
    addToggle(targetsPage, "Players", "TargetPlayers")
    addToggle(targetsPage, "Practice targets", "TargetTraining")
    addToggle(targetsPage, "Ignore teammates", "IgnoreTeammates")
    addButtons(targetsPage, { { Text = "Check teams (details in Output)", Callback = checkTeams } })
    addToggle(targetsPage, "Ignore friends", "IgnoreFriends")
    addButtons(targetsPage, { { Text = "Ignore current target", Callback = ignoreCurrent }, { Text = "Clear ignore list", Callback = clearIgnored } })
    addInfo(targetsPage, "Ignored players (this session)", function() return tostring(ignoredCount()) end)
    addToggle(targetsPage, "Wall check (acquire)", "WallCheck")
    addToggle(targetsPage, "Keep the lock through walls", "KeepThroughWalls")
    addSlider(targetsPage, "Max distance", "MaxDistance", Limits.MaxDistance, "%d studs")
    addSection(targetsPage, "PRACTICE DUMMIES (client-side)")
    addSegmented(targetsPage, "Pattern", "SpawnPattern", { "Static", "Strafe", "Jump" })
    addSlider(targetsPage, "Count", "SpawnCount", Limits.SpawnCount, "%d")
    addButtons(targetsPage, { { Text = "Spawn", Callback = spawnDummies }, { Text = "Clear", Callback = clearDummies } })

    addSection(keysPage, "KEYS (click, then press the new key)")
    for _, key in ipairs(BIND_KEYS) do addKeybind(keysPage, BIND_LABELS[key], key) end
    addSection(keysPage, "DISPLAY")
    addToggle(keysPage, "Target HUD", "ShowHUD")
    addToggle(keysPage, "FOV circle", "ShowFOV")
    addSection(keysPage, "SETTINGS")
    addInfo(keysPage, "Storage", function() return Persist.Status end)

    --------------------------------------------------------------------------------
    -- Cleanup
    --------------------------------------------------------------------------------
    local function destroy()
        if State.Destroyed then return end -- safe to call more than once
        State.Destroyed = true
        task.spawn(function() saveNow(true) end) -- final save (force: runs although State.Destroyed is set)
        State.Enabled = false
        State.Target = nil
        State.HoldActive = false
        State.DraggingPanel = false
        State.DraggingSlider = nil
        unbindRenderStep(renderStepName)
        clearDummies()
        for _, connection in ipairs(connections) do connection:Disconnect() end
        table.clear(connections)
        if gui.Parent then gui:Destroy() end
    end

    addButtons(keysPage, { { Text = "Unload script", Callback = destroy } })

    --------------------------------------------------------------------------------
    -- Events
    --------------------------------------------------------------------------------
    track(toggleButton.Activated:Connect(function() setEnabled(not State.Enabled) end))
    track(hideButton.Activated:Connect(function() setUIVisible(false) end))
    track(gui.Destroying:Connect(destroy))
    if script then track(script.Destroying:Connect(destroy)) end

    local dragStart = Vector3.zero
    local panelStart = Vector2.zero

    track(header.InputBegan:Connect(function(input)
        if isPointerBegin(input) and input.Position.X < header.AbsolutePosition.X + header.AbsoluteSize.X - 56 then
            State.DraggingPanel = true
            dragStart = input.Position
            panelStart = panel.AbsolutePosition
        end
    end))

    track(UserInputService.InputChanged:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseMovement and State.Enabled
            and not State.DraggingPanel and not State.DraggingSlider then
            State.MouseTravel += input.Delta.Magnitude
        end
        if not isPointerMove(input) then return end
        if State.DraggingSlider then
            State.DraggingSlider(input.Position.X)
        elseif State.DraggingPanel then
            local cam = Workspace.CurrentCamera
            local delta = input.Position - dragStart
            local x = panelStart.X + delta.X
            local y = panelStart.Y + delta.Y
            if cam then
                local viewport = cam.ViewportSize
                x = math.clamp(x, 0, math.max(0, viewport.X - panel.AbsoluteSize.X))
                y = math.clamp(y, 0, math.max(0, viewport.Y - panel.AbsoluteSize.Y))
            end
            panel.Position = UDim2.fromOffset(x, y)
        end
    end))

    local function matchesBind(input, bind)
        return input.KeyCode == bind or input.UserInputType == bind
    end

    -- assign a key; refuse a key that another action already uses
    local function assignBind(key, bind)
        State.WaitingFor = nil
        for _, other in ipairs(BIND_KEYS) do
            if other ~= key and Config[other] == bind then
                refreshUI()
                notify(bind.Name .. " is already used by \"" .. BIND_LABELS[other] .. "\"")
                return false
            end
        end
        Config[key] = bind
        refreshUI()
        scheduleSave()
        return true
    end

    track(UserInputService.InputEnded:Connect(function(input)
        if isPointerBegin(input) then
            State.DraggingPanel = false
            State.DraggingSlider = nil
        end
        if Config.ActivationMode == "Hold" and State.HoldActive and matchesBind(input, Config.Keybind) then
            setEnabled(false)
        end
    end))

    track(UserInputService.WindowFocusReleased:Connect(function()
        State.DraggingPanel = false
        State.DraggingSlider = nil
        if State.HoldActive then setEnabled(false) end
    end))

    track(UserInputService.InputBegan:Connect(function(input, gameProcessed)
        if State.WaitingFor then
            local key = State.WaitingFor
            if input.UserInputType == Enum.UserInputType.Keyboard then
                if input.KeyCode == Enum.KeyCode.Escape then
                    State.WaitingFor = nil -- cancel
                    refreshUI()
                elseif input.KeyCode ~= Enum.KeyCode.Unknown then
                    assignBind(key, input.KeyCode)
                end
            elseif input.UserInputType == Enum.UserInputType.MouseButton2
                or input.UserInputType == Enum.UserInputType.MouseButton3 then
                assignBind(key, input.UserInputType)
            end
            return
        end
        if gameProcessed then return end

        if matchesBind(input, Config.MenuKey) then
            setUIVisible(not State.UIVisible)
            return
        end
        if matchesBind(input, Config.Keybind) then
            if Config.ActivationMode == "Hold" then
                State.HoldActive = true
                setEnabled(true)
            else
                setEnabled(not State.Enabled)
            end
        elseif State.Enabled and matchesBind(input, Config.SwitchKey) then
            switchTarget(1)
        elseif State.Enabled and matchesBind(input, Config.SwitchPrevKey) then
            switchTarget(-1)
        elseif State.Enabled and matchesBind(input, Config.IgnoreKey) then
            ignoreCurrent()
        end
    end))

    --------------------------------------------------------------------------------
    -- Lock loop
    --------------------------------------------------------------------------------
    -- Bound at the LAST render priority: the aim part is read after animations and character updates of the same
    -- frame, and the camera is set right before it is drawn. That is what keeps the lock exact on a moving target.
    RunService:BindToRenderStep(renderStepName, Enum.RenderPriority.Last.Value, function(dt)
        if State.Destroyed or not State.Enabled then return end
        local cam = Workspace.CurrentCamera
        if not cam then return end

        local travel = State.MouseTravel
        State.MouseTravel = 0
        if Config.BreakOnFlick and State.Target and travel > FLICK_TRAVEL then
            setEnabled(false)
            return
        end

        local aimPosition
        if State.Target then
            aimPosition = validateLock(State.Target, cam)
            if aimPosition then
                State.LostTime = 0
            else
                State.LostTime += dt
                if State.LostTime < LOST_GRACE then
                    setStatus("Target unavailable...")
                    return
                end
                handleTargetLost()
                if not State.Enabled then return end
            end
        end

        if not State.Target and State.Searching then
            local best = collectRanked(cam)[1]
            if best then
                lockOn(best.Candidate)
                aimPosition = best.AimPosition
            end
        end

        if not State.Target or not aimPosition then
            marker.Visible = false
            hud.Visible = false
            setStatus(Config.Mode360 and "Searching... (360°)" or "Searching...")
            return
        end

        local camPosition = cam.CFrame.Position
        local toTarget = aimPosition - camPosition
        local distance = toTarget.Magnitude
        setStatus(string.format("%s  ·  %s  ·  %.0f studs", State.Target.Name, Config.AimPart, distance))

        if distance > 1e-3 then
            local desired = CFrame.lookAt(camPosition, aimPosition)
            if Config.LockStyle == "Hard" then
                cam.CFrame = desired -- exact: no smoothing, nothing can trail behind a jump
            else
                local fraction = 1 - (1 - Config.Smoothness) ^ (dt * 60)
                cam.CFrame = cam.CFrame:Lerp(desired, math.clamp(fraction, 0, 1))
            end
        end

        playLockPop(State.Target)
        local offscreen = updateMarker(cam, aimPosition)
        updateHUD(State.Target, offscreen, distance)
    end)

    --------------------------------------------------------------------------------
    -- Start
    --------------------------------------------------------------------------------
    local function loadSettings()
        local remote = ReplicatedStorage:WaitForChild(SETTINGS_REMOTE_NAME, 5)
        if State.Destroyed then return end
        if not remote then
            Persist.Status = "Not saved (no server script)"
            refreshUI()
            return
        end
        if not remote:IsA("RemoteFunction") then
            Persist.Status = "Not saved (" .. SETTINGS_REMOTE_NAME .. " must be a RemoteFunction)"
            warn("[DarkAimLock] " .. Persist.Status)
            refreshUI()
            return
        end
        Persist.Remote = remote
        for attempt = 1, 3 do
            local ok, response = invokeWithTimeout(remote, REQUEST_TIMEOUT, "Load")
            if State.Destroyed then return end
            if ok and type(response) == "table" and response.Status == "OK" then
                local hasData = response.Data ~= nil
                local applied = hasData and applyLoadedData(response.Data)
                Persist.Ready = true
                Persist.Status = (not hasData) and "New player" or (applied and "Synced" or "Saved data invalid (ignored)")
                Persist.LastSignature = stable(buildPayload())
                refreshUI()
                if applied then notify("Settings loaded") end
                return
            end
            local message = (ok and type(response) == "table" and response.Message) or (ok and "bad response") or tostring(response)
            Persist.Status = string.format("Load failed (%d/3): %s", attempt, tostring(message))
            refreshUI()
            task.wait(3)
        end
        Persist.Status = "Unavailable (not saving)"
        refreshUI()
    end

    task.spawn(loadSettings)
    refreshUI()
end
