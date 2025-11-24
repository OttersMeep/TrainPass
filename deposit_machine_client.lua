local ecc = require("ecc")
if not fs.exists("basalt.lua") then
    print("Downloading Basalt UI library...")
    shell.run("wget", "run", "https://basalt.madefor.cc/install.lua", "release", "latest.lua", "basalt.lua")
    if not fs.exists("basalt.lua") then
        error("Failed to download Basalt! Please install manually.")
    end
end
local basalt = require("basalt")

local atm = {}

-- Configuration (will be overridden by machine_config.lua if it exists)
atm.config = {
    machineId = "DEPOSIT_005",
    privateKey = "",  -- Set this!
    diamondValue = 100,  -- Balance units per diamond
    sourceBarrelName = "minecraft:barrel_0",  -- Source barrel for deposits (networked)
    junkChestName = "minecraft:chest_0",  -- Target chest for non-diamond items (networked)
    diamondDispenserName = "minecraft:dispenser_0",  -- Target dispenser for diamonds (networked)
    monitorSide = "top",  -- Side with monitor (default top, auto-detect if nil)
    gatewayChannel = 1000,
    responseChannel = nil  -- Will be set dynamically
}

-- Load configuration from machine_config.lua if it exists
if fs.exists("machine_config.lua") then
    local machineConfig = dofile("machine_config.lua")
    if machineConfig then
        atm.config.machineId = machineConfig.machineId or atm.config.machineId
        -- Deserialize private key if it's a string
        if type(machineConfig.privateKey) == "string" then
            atm.config.privateKey = textutils.unserialize(machineConfig.privateKey)
        else
            atm.config.privateKey = machineConfig.privateKey
        end
        -- Deserialize gateway public key if it's a string
        if type(machineConfig.gatewayPublicKey) == "string" then
            atm.config.gatewayPublicKey = textutils.unserialize(machineConfig.gatewayPublicKey)
        else
            atm.config.gatewayPublicKey = machineConfig.gatewayPublicKey
        end
        atm.config.diamondValue = machineConfig.diamondValue or atm.config.diamondValue
        atm.config.sourceBarrelName = machineConfig.sourceBarrelName or atm.config.sourceBarrelName
        atm.config.junkChestName = machineConfig.junkChestName or atm.config.junkChestName
        atm.config.diamondDispenserName = machineConfig.diamondDispenserName or atm.config.diamondDispenserName
        atm.config.gatewayChannel = machineConfig.gatewayChannel or atm.config.gatewayChannel
        atm.config.monitorSide = machineConfig.monitorSide or atm.config.monitorSide
    end
end

-- Validate configuration
if not atm.config.privateKey or type(atm.config.privateKey) ~= "table" then
    error("Private key not configured or invalid! Type: " .. type(atm.config.privateKey))
end

if not atm.config.gatewayPublicKey or type(atm.config.gatewayPublicKey) ~= "table" then
    error("Gateway public key not configured or invalid! Type: " .. type(atm.config.gatewayPublicKey))
end

print("Configuration loaded successfully")
print("Private key: " .. #atm.config.privateKey .. " bytes")
print("Gateway public key: " .. #atm.config.gatewayPublicKey .. " bytes")

-- Derive shared secret for encryption
atm.sharedSecret = ecc.exchange(atm.config.privateKey, atm.config.gatewayPublicKey)
print("Shared secret derived: " .. #atm.sharedSecret .. " bytes")

-- Find source barrel (via wired modem network)
local sourceBarrel = peripheral.wrap(atm.config.sourceBarrelName)
if not sourceBarrel then
    error("No source barrel found with name: " .. atm.config.sourceBarrelName .. "! Check wired modem network.")
end
print("Source barrel connected: " .. atm.config.sourceBarrelName)

-- Find junk chest (via wired modem network)
local junkChest = peripheral.wrap(atm.config.junkChestName)
if not junkChest then
    error("No junk chest found with name: " .. atm.config.junkChestName .. "! Check wired modem network.")
end
print("Junk chest connected: " .. atm.config.junkChestName)

-- Find diamond dispenser (via wired modem network)
local diamondDispenser = peripheral.wrap(atm.config.diamondDispenserName)
if not diamondDispenser then
    error("No diamond dispenser found with name: " .. atm.config.diamondDispenserName .. "! Check wired modem network.")
end
print("Diamond dispenser connected: " .. atm.config.diamondDispenserName)

-- Find monitor
local monitor = nil
if atm.config.monitorSide then
    -- Use specified side
    monitor = peripheral.wrap(atm.config.monitorSide)
    if not monitor then
        error("No monitor found on " .. atm.config.monitorSide .. " side!")
    end
else
    -- Auto-detect monitor
    monitor = peripheral.find("monitor")
    if not monitor then
        print("WARNING: No monitor found. Using computer terminal.")
    end
end

if monitor then
    print("Monitor detected: " .. peripheral.getName(monitor))
    print("Monitor size: " .. monitor.getSize())
end

-- Find card reader
local cardReader = peripheral.find("card_reader")
if not cardReader then
    print("WARNING: No card reader found. Manual account entry only.")
else
    print("Card reader detected: " .. peripheral.getName(cardReader))
end

-- Find wireless modem
local modem = peripheral.find("modem", function(name, modem)
    return modem.isWireless()
end)

if not modem then
    error("No wireless modem found! ATM requires wireless modem.")
end

-- Generate unique response channel
atm.config.responseChannel = 3000 + math.random(1, 6999)
modem.open(atm.config.responseChannel)

-- State
atm.currentAccount = nil
atm.currentBalance = 0
atm.diamondsInserted = 0
atm.waitingForResponse = false

-- Send request to gateway
function atm.sendRequest(requestData)
    atm.waitingForResponse = true
    
    -- Encrypt the request data with the shared secret
    local serializedData = textutils.serialize(requestData.data)
    local encryptedData = ecc.encrypt(serializedData, atm.sharedSecret)
    
    -- Send encrypted packet with machine ID for key derivation
    modem.transmit(
        atm.config.gatewayChannel,
        atm.config.responseChannel,
        textutils.serialize({
            machineId = atm.config.machineId,  -- Gateway needs this to derive shared secret
            encryptedData = encryptedData,
            timestamp = requestData.timestamp
        })
    )
end

-- Wait for response with timeout
function atm.waitForResponse(timeout)
    timeout = timeout or 10
    local timer = os.startTimer(timeout)
    
    while true do
        local event, p1, p2, p3, p4 = os.pullEvent()
        
        if event == "modem_message" and p2 == atm.config.responseChannel then
            os.cancelTimer(timer)
            atm.waitingForResponse = false
            local packet = textutils.unserialize(p4)
            
            -- Handle encrypted packet from gateway
            if packet and type(packet) == "table" and packet.encryptedData then
                -- Decrypt using shared secret
                local success, decrypted = pcall(ecc.decrypt, packet.encryptedData, atm.sharedSecret)
                if success then
                    -- FIX: If decrypt returns a byte array (table), convert it to a string first
                    if type(decrypted) == "table" then
                        local chars = {}
                        for i = 1, #decrypted do
                            chars[i] = string.char(decrypted[i])
                        end
                        decrypted = table.concat(chars)
                    end

                    local response = textutils.unserialize(decrypted)
                    return response
                else
                    print("Error: Failed to decrypt response from gateway")
                    return nil, "Decryption failed"
                end
            end
            
            -- Fallback for unencrypted messages (legacy or plain errors)
            return packet
        elseif event == "timer" and p1 == timer then
            atm.waitingForResponse = false
            return nil, "Timeout"
        end
    end
end

-- Look up account by card UUID
function atm.getAccountByCard(cardUUID)
    local timestamp = os.epoch("utc")
    
    print("Looking up account for card: " .. tostring(cardUUID))
    
    atm.sendRequest({
        data = {
            requestType = "GET_ACCOUNT_BY_CARD",
            cardUUID = cardUUID,
            depositMachineId = atm.config.machineId,
            timestamp = timestamp
        },
        timestamp = timestamp
    })
    
    print("Request sent, waiting for response...")
    local response, err = atm.waitForResponse(10)
    print("Response received: " .. textutils.serialize(response or {error = err}))
    
    if response and response.success and response.accountId then
        return true, response.accountId
    else
        return false, response and response.error or err or "Card not registered"
    end
end

-- Check balance
function atm.checkBalance(accountId)
    local timestamp = os.epoch("utc")
    
    atm.sendRequest({
        data = {
            requestType = "GET_ACCOUNT",
            accountId = accountId,
            timestamp = timestamp
        },
        timestamp = timestamp
    })
    
    local response, err = atm.waitForResponse(10)
    if response and response.success and response.account then
        return true, response.account.balance
    else
        return false, response and response.error or err
    end
end

-- Process deposit
function atm.processDeposit(accountId, diamonds)
    local amount = diamonds * atm.config.diamondValue
    local timestamp = os.epoch("utc")
    
    -- Create signature for the request
    local signedMessage = accountId .. amount .. timestamp
    local signature = ecc.sign(atm.config.privateKey, signedMessage)
    
    atm.sendRequest({
        data = {
            requestType = "DEPOSIT",
            depositMachineId = atm.config.machineId,
            accountId = accountId,
            amount = amount,
            timestamp = timestamp,
            signature = signature
        },
        timestamp = timestamp
    })
    
    local response, err = atm.waitForResponse(10)
    if response and response.success then
        return true, response.balance
    else
        return false, response and response.error or err
    end
end

-- Process withdrawal
function atm.processWithdrawal(accountId, diamonds)
    local amount = diamonds * atm.config.diamondValue
    local timestamp = os.epoch("utc")
    
    -- Create signature for the request (negative amount for withdrawal)
    local signedMessage = accountId .. (-amount) .. timestamp
    local signature = ecc.sign(atm.config.privateKey, signedMessage)
    
    atm.sendRequest({
        data = {
            requestType = "DEPOSIT",
            depositMachineId = atm.config.machineId,
            accountId = accountId,
            amount = -amount,  -- Negative amount = withdrawal
            timestamp = timestamp,
            signature = signature
        },
        timestamp = timestamp
    })
    
    local response, err = atm.waitForResponse(10)
    if response and response.success then
        -- Pull diamonds from dispenser (they should already be there)
        return true, response.balance
    else
        return false, response and response.error or err
    end
end

-- Helper: Check if item is a diamond
local function isDiamond(itemName)
    return itemName == "minecraft:diamond"
end

-- Helper: Count diamonds in source barrel
local function countDiamondsInBarrel()
    local totalDiamonds = 0
    
    for slot = 1, sourceBarrel.size() do
        local item = sourceBarrel.getItemDetail(slot)
        if item and isDiamond(item.name) then
            totalDiamonds = totalDiamonds + item.count
        end
    end
    
    return totalDiamonds
end

-- Helper: Process items in source barrel (sort diamonds from junk)
local function processBarrelItems()
    local diamondCount = 0
    local junkCount = 0
    
    -- Go through each slot in source barrel
    for slot = 1, sourceBarrel.size() do
        local item = sourceBarrel.getItemDetail(slot)
        if item then
            if isDiamond(item.name) then
                -- Move diamonds to dispenser
                local moved = sourceBarrel.pushItems(atm.config.diamondDispenserName, slot)
                diamondCount = diamondCount + moved
            else
                -- Move junk to junk chest
                local moved = sourceBarrel.pushItems(atm.config.junkChestName, slot)
                junkCount = junkCount + moved
            end
        end
    end
    
    return diamondCount, junkCount
end

-- Helper: Clear source barrel (return all items to junk chest)
local function clearBarrel()
    for slot = 1, sourceBarrel.size() do
        local item = sourceBarrel.getItemDetail(slot)
        if item then
            sourceBarrel.pushItems(atm.config.junkChestName, slot)
        end
    end
end

-- Create Basalt UI
local main
if monitor then
    -- Use monitor for UI
    -- Set text scale to 0.5 to make text smaller and fit more on screen
    monitor.setTextScale(0.5)
    main = basalt.createFrame():setTerm(monitor)
    term.clear()
    term.setCursorPos(1, 1)
    print("=== TrainPass ATM ===")
    print("Machine: " .. atm.config.machineId)
    print("")
    print("UI displayed on monitor")
    print("Press X to exit")
else
    -- Use computer terminal
    main = basalt.createFrame()
end

-- Initialize state
main:initializeState("currentScreen", "home")
main:initializeState("monitoringBarrel", false)

-- Get terminal size (after setting text scale)
local termWidth, termHeight
if monitor then
    termWidth, termHeight = monitor.getSize()
else
    termWidth, termHeight = term.getSize()
end

-- Colors
local colorBg = colors.gray
local colorPrimary = colors.blue
local colorSuccess = colors.green
local colorError = colors.red
local colorText = colors.white

-- Home Screen
local homeFrame = main:addFrame()
    :setPosition(1, 1)
    :setSize(termWidth, termHeight)
    :setBackground(colorBg)

homeFrame:addLabel()
    :setText("TrainPass ATM")
    :setPosition(1, 2)
    :setForeground(colorPrimary)

homeFrame:addLabel()
    :setText("Machine: " .. atm.config.machineId)
    :setPosition(1, 3)
    :setForeground(colors.lightGray)

homeFrame:addLabel()
    :setText("Please swipe your card")
    :setPosition(1, 5)
    :setForeground(colorText)

local statusLabel = homeFrame:addLabel()
    :setText(cardReader and "Ready" or "ERROR: No card reader!")
    :setPosition(1, 7)
    :setForeground(cardReader and colorSuccess or colorError)

-- Menu Screen
local menuFrame = main:addFrame()
    :setPosition(1, 1)
    :setSize(termWidth, termHeight)
    :setBackground(colorBg)
    :setVisible(false)

local menuBalanceLabel = menuFrame:addLabel()
    :setText("")
    :setPosition(1, 1)
    :setForeground(colorSuccess)

local checkBalanceBtn = menuFrame:addButton()
    :setText("Check Balance")
    :setPosition(2, 3)
    :setSize((termWidth-2), 1)
    :setBackground(colorPrimary)
    :setForeground(colors.white)

local depositBtn = menuFrame:addButton()
    :setText("Load Balance")
    :setPosition(2, 5)
    :setSize((termWidth-2), 1)
    :setBackground(colorPrimary)
    :setForeground(colors.white)

local withdrawBtn = menuFrame:addButton()
    :setText("Withdraw")
    :setPosition(2, 7)
    :setSize((termWidth-2), 1)
    :setBackground(colorPrimary)
    :setForeground(colors.white)

local logoutBtn = menuFrame:addButton()
    :setText("Logout")
    :setPosition(2, 9)
    :setSize((termWidth-2), 1)
    :setBackground(colorError)
    :setForeground(colors.white)

-- Deposit Screen
local depositFrame = main:addFrame()
    :setPosition(1, 1)
    :setSize(termWidth, termHeight)
    :setBackground(colorBg)
    :setVisible(false)

depositFrame:addLabel()
    :setText("Load Balance")
    :setPosition(2, 2)
    :setForeground(colorPrimary)

depositFrame:addLabel()
    :setText("Insert diamonds into barrel")
    :setPosition(2, 4)
    :setForeground(colorText)

local depositCountLabel = depositFrame:addLabel()
    :setText("Diamonds inserted: 0")
    :setPosition(2, 6)
    :setForeground(colors.yellow)

local depositValueLabel = depositFrame:addLabel()
    :setText("Value: 0")
    :setPosition(2, 7)
    :setForeground(colorSuccess)

local depositConfirmBtn = depositFrame:addButton()
    :setText("Confirm Deposit")
    :setPosition(2, 10)
    :setSize(16, 3)
    :setBackground(colorSuccess)
    :setForeground(colors.white)

local depositCancelBtn = depositFrame:addButton()
    :setText("Cancel")
    :setPosition(19, 10)
    :setSize(10, 3)
    :setBackground(colorError)
    :setForeground(colors.white)

-- Withdraw Screen
local withdrawFrame = main:addFrame()
    :setPosition(1, 1)
    :setSize(termWidth, termHeight)
    :setBackground(colorBg)
    :setVisible(false)

withdrawFrame:addLabel()
    :setText("Withdraw Diamonds")
    :setPosition(2, 2)
    :setForeground(colorPrimary)

withdrawFrame:addLabel()
    :setText("Enter number of diamonds:")
    :setPosition(2, 4)
    :setForeground(colorText)

local withdrawInput = withdrawFrame:addInput()
    :setPosition(2, 5)
    :setSize(10, 1)
    :setBackground(colors.black)
    :setForeground(colors.white)

local withdrawValueLabel = withdrawFrame:addLabel()
    :setText("Cost: 0")
    :setPosition(2, 7)
    :setForeground(colors.yellow)

local withdrawConfirmBtn = withdrawFrame:addButton()
    :setText("Withdraw")
    :setPosition(2, 10)
    :setSize(12, 3)
    :setBackground(colorSuccess)
    :setForeground(colors.white)

local withdrawCancelBtn = withdrawFrame:addButton()
    :setText("Cancel")
    :setPosition(15, 10)
    :setSize(10, 3)
    :setBackground(colorError)
    :setForeground(colors.white)

-- Event Handlers

-- Check Balance
checkBalanceBtn:onClick(function(self)
    menuBalanceLabel:setText("Checking..."):setForeground(colors.yellow)
    
    basalt.schedule(function()
        local success, balance = atm.checkBalance(atm.currentAccount)
        if success then
            atm.currentBalance = balance
            menuBalanceLabel:setText("Balance: " .. balance):setForeground(colorSuccess)
        else
            menuBalanceLabel:setText("Error: " .. balance):setForeground(colorError)
        end
    end)
end)

-- Timer for barrel monitoring
local barrelMonitorTimer = nil

-- Go to deposit screen
depositBtn:onClick(function()
    -- Clear any leftover items from barrel
    clearBarrel()
    
    atm.diamondsInserted = 0
    depositCountLabel:setText("Diamonds inserted: 0")
    depositValueLabel:setText("Value: 0")
    
    menuFrame:setVisible(false)
    depositFrame:setVisible(true)
    main:setState("currentScreen", "deposit")
    
    -- Start monitoring barrel
    main:setState("monitoringBarrel", true)
    barrelMonitorTimer = os.startTimer(0.5)
end)

-- Confirm deposit
depositConfirmBtn:onClick(function()
    main:setState("monitoringBarrel", false)
    
    if barrelMonitorTimer then
        os.cancelTimer(barrelMonitorTimer)
        barrelMonitorTimer = nil
    end
    
    depositCountLabel:setText("Processing items..."):setForeground(colors.yellow)
    
    basalt.schedule(function()
        -- Process items (move diamonds to dispenser, junk to chest)
        local diamonds, junk = processBarrelItems()
        
        if junk > 0 then
            depositValueLabel:setText(junk .. " junk item(s) rejected"):setForeground(colorError)
            sleep(2)
        end
        
        if diamonds == 0 then
            depositCountLabel:setText("No diamonds to deposit"):setForeground(colorError)
            sleep(2)
            depositFrame:setVisible(false)
            menuFrame:setVisible(true)
            main:setState("currentScreen", "menu")
            return
        end
        
        depositCountLabel:setText("Depositing " .. diamonds .. " diamonds..."):setForeground(colors.yellow)
        
        local success, balance = atm.processDeposit(atm.currentAccount, diamonds)
        if success then
            atm.currentBalance = balance
            menuBalanceLabel:setText("Balance: " .. balance)
            depositCountLabel:setText("Deposit successful!"):setForeground(colorSuccess)
            sleep(2)
            
            depositFrame:setVisible(false)
            menuFrame:setVisible(true)
            main:setState("currentScreen", "menu")
        else
            depositCountLabel:setText("Error: " .. balance):setForeground(colorError)
        end
    end)
end)

-- Cancel deposit
depositCancelBtn:onClick(function()
    main:setState("monitoringBarrel", false)
    
    if barrelMonitorTimer then
        os.cancelTimer(barrelMonitorTimer)
        barrelMonitorTimer = nil
    end
    
    -- Return all items from barrel to junk chest
    clearBarrel()
    
    atm.diamondsInserted = 0
    depositFrame:setVisible(false)
    menuFrame:setVisible(true)
    main:setState("currentScreen", "menu")
end)

-- Go to withdraw screen
withdrawBtn:onClick(function()
    withdrawInput:setValue("")
    withdrawValueLabel:setText("Cost: 0")
    menuFrame:setVisible(false)
    withdrawFrame:setVisible(true)
    main:setState("currentScreen", "withdraw")
end)

-- Update withdraw cost
withdrawInput:onChange(function(self)
    local diamonds = tonumber(self:getValue()) or 0
    local cost = diamonds * atm.config.diamondValue
    withdrawValueLabel:setText("Cost: " .. cost)
end)

-- Confirm withdrawal
withdrawConfirmBtn:onClick(function()
    local diamonds = tonumber(withdrawInput:getValue()) or 0
    if diamonds <= 0 then
        return
    end
    
    local cost = diamonds * atm.config.diamondValue
    if cost > atm.currentBalance then
        withdrawValueLabel:setText("Insufficient funds!"):setForeground(colorError)
        return
    end
    
    withdrawValueLabel:setText("Processing..."):setForeground(colors.yellow)
    
    basalt.schedule(function()
        local success, balance = atm.processWithdrawal(atm.currentAccount, diamonds)
        if success then
            atm.currentBalance = balance
            menuBalanceLabel:setText("Balance: " .. balance)
            
            -- Note: Diamonds should be dispensed by the dispenser block automatically
            withdrawValueLabel:setText("Collect your diamonds!"):setForeground(colorSuccess)
            sleep(2)
            
            withdrawFrame:setVisible(false)
            menuFrame:setVisible(true)
            main:setState("currentScreen", "menu")
        else
            withdrawValueLabel:setText("Error: " .. balance):setForeground(colorError)
        end
    end)
end)

-- Cancel withdrawal
withdrawCancelBtn:onClick(function()
    withdrawFrame:setVisible(false)
    menuFrame:setVisible(true)
    main:setState("currentScreen", "menu")
end)

-- Logout
logoutBtn:onClick(function()
    atm.currentAccount = nil
    atm.currentBalance = 0
    statusLabel:setText("Ready"):setForeground(colorSuccess)
    menuFrame:setVisible(false)
    homeFrame:setVisible(true)
    main:setState("currentScreen", "home")
end)

-- Register timer event for barrel monitoring
basalt.onEvent("timer", function(timerId)
    if timerId == barrelMonitorTimer then
        local monitoring = main:getState("monitoringBarrel")
        
        if monitoring and main:getState("currentScreen") == "deposit" then
            -- Count diamonds in barrel
            local diamonds = countDiamondsInBarrel()
            
            -- Update display
            depositCountLabel:setText("Diamonds in barrel: " .. diamonds)
            depositValueLabel:setText("Value: " .. (diamonds * atm.config.diamondValue))
                :setForeground(diamonds > 0 and colors.green or colorText)
            
            -- Restart timer
            barrelMonitorTimer = os.startTimer(0.5)
        end
    end
end)

-- Register custom event for card_read
basalt.onEvent("card_read", function(info)
    if not cardReader then return end
    
    if info and info.data then
        local currentScreen = main:getState("currentScreen")
        
        if currentScreen == "home" then
            -- Beep and light to indicate card read
            cardReader.beep(1000)
            cardReader.setLight("YELLOW", true)
            sleep(0.1)
            cardReader.setLight("YELLOW", false)
            
            statusLabel:setText("Reading card..."):setForeground(colors.yellow)
            
            basalt.schedule(function()
                -- Look up account from card UUID
                local success, accountId = atm.getAccountByCard(info.data)
                if not success then
                    statusLabel:setText("Error: " .. tostring(accountId)):setForeground(colorError)
                    
                    -- Error beep and light
                    cardReader.setLight("RED", true)
                    cardReader.beep(500)
                    sleep(0.1)
                    cardReader.beep(400)
                    sleep(0.3)
                    cardReader.setLight("RED", false)
                else
                    statusLabel:setText("Checking balance..."):setForeground(colors.yellow)
                    
                    -- Get balance for this account
                    local balSuccess, balance = atm.checkBalance(accountId)
                    if balSuccess then
                        atm.currentAccount = accountId
                        atm.currentBalance = balance
                        menuBalanceLabel:setText("Balance: " .. balance)
                        
                        -- Success beep and light
                        cardReader.setLight("GREEN", true)
                        cardReader.beep(1500)
                        sleep(0.1)
                        cardReader.beep(1800)
                        sleep(0.2)
                        cardReader.setLight("GREEN", false)
                        
                        homeFrame:setVisible(false)
                        menuFrame:setVisible(true)
                        main:setState("currentScreen", "menu")
                    else
                        statusLabel:setText("Error: " .. tostring(balance)):setForeground(colorError)
                        
                        -- Error beep and light
                        cardReader.setLight("RED", true)
                        cardReader.beep(500)
                        sleep(0.1)
                        cardReader.beep(400)
                        sleep(0.3)
                        cardReader.setLight("RED", false)
                    end
                end
            end)
        elseif currentScreen == "menu" then
            -- Update card with current balance (verify card matches current account)
            basalt.schedule(function()
                local success, accountId = atm.getAccountByCard(info.data)
                if success and accountId == atm.currentAccount then
                    cardReader.beep(1200)
                    cardReader.setLight("GREEN", true)
                    sleep(0.1)
                    cardReader.setLight("GREEN", false)
                end
            end)
        end
    end
end)

-- Start Basalt (it will handle all events automatically)
basalt.run()