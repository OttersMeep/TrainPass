-- TrainPass ATM Machine with Basalt UI
-- Full-featured deposit/withdrawal machine
-- Supports: Balance loading, balance checking, withdrawals

-- Check for Basalt
if not fs.exists("basalt.lua") then
    print("Downloading Basalt UI library...")
    shell.run("wget", "run", "https://basalt.madefor.cc/install.lua", "release", "latest.lua", "basalt.lua")
    if not fs.exists("basalt.lua") then
        error("Failed to download Basalt! Please install manually.")
    end
end

local basalt = require("basalt")
local ecc = require("ecc")

local atm = {}

-- Configuration (will be overridden by machine_config.lua if it exists)
atm.config = {
    machineId = "DEPOSIT_005",
    privateKey = "",  -- Set this!
    diamondValue = 100,  -- Balance units per diamond
    dispenserSide = "back",  -- Side to pulse for dispensing diamonds
    inventorySide = "right",  -- Side with hopper for diamond detection (also receives lock signal)
    monitorSide = "top",  -- Side with monitor (default top, auto-detect if nil)
    gatewayChannel = 1000,
    responseChannel = nil  -- Will be set dynamically
}

-- Load configuration from machine_config.lua if it exists
if fs.exists("machine_config.lua") then
    local machineConfig = dofile("machine_config.lua")
    if machineConfig then
        atm.config.machineId = machineConfig.machineId or atm.config.machineId
        atm.config.privateKey = machineConfig.privateKey or atm.config.privateKey
        atm.config.diamondValue = machineConfig.diamondValue or atm.config.diamondValue
        atm.config.dispenserSide = machineConfig.dispenserSide or atm.config.dispenserSide
        atm.config.inventorySide = machineConfig.inventorySide or atm.config.inventorySide
        atm.config.gatewayChannel = machineConfig.gatewayChannel or atm.config.gatewayChannel
        atm.config.monitorSide = machineConfig.monitorSide or atm.config.monitorSide
    end
end

-- Validate configuration
if atm.config.privateKey == "" then
    error("Private key not configured! Edit deposit_machine_client.lua or machine_config.lua")
end

-- Find inventory (hopper on right)
local inventory = peripheral.wrap(atm.config.inventorySide)
if not inventory then
    error("No inventory found on " .. atm.config.inventorySide .. " side! Need hopper for diamond detection.")
end

print("Inventory detected: " .. peripheral.getType(atm.config.inventorySide))

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

-- Initialize hopper lock (locked by default - prevents items from entering)
-- Redstone output on the same side as the hopper
redstone.setOutput(atm.config.inventorySide, true)

-- State
atm.currentAccount = nil
atm.currentBalance = 0
atm.diamondsInserted = 0
atm.waitingForResponse = false

-- Sign deposit request
function atm.signDeposit(accountId, amount, timestamp)
    local message = accountId .. amount .. timestamp
    local signature = ecc.sign(atm.config.privateKey, message)
    return signature
end

-- Send request to gateway
function atm.sendRequest(requestData)
    atm.waitingForResponse = true
    
    -- Encrypt the request data with the gateway's public key
    local serializedData = textutils.serialize(requestData.data)
    local encryptedData = ecc.encrypt(serializedData, atm.config.gatewayPublicKey)
    
    -- Send encrypted packet
    modem.transmit(
        atm.config.gatewayChannel,
        atm.config.responseChannel,
        textutils.serialize({
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
            local response = textutils.unserialize(p4)
            return response
        elseif event == "timer" and p1 == timer then
            atm.waitingForResponse = false
            return nil, "Timeout"
        end
    end
end

-- Look up account by card UUID
function atm.getAccountByCard(cardUUID)
    local timestamp = os.epoch("utc")
    local signature = atm.signDeposit(cardUUID, 0, timestamp)
    
    atm.sendRequest({
        data = {
            requestType = "GET_ACCOUNT_BY_CARD",
            cardUUID = cardUUID,
            timestamp = timestamp,
            signature = signature
        },
        timestamp = timestamp
    })
    
    local response, err = atm.waitForResponse(10)
    if response and response.success and response.accountId then
        return true, response.accountId
    else
        return false, response and response.error or err or "Card not registered"
    end
end

-- Check balance
function atm.checkBalance(accountId)
    local timestamp = os.epoch("utc")
    local signature = atm.signDeposit(accountId, 0, timestamp)
    
    atm.sendRequest({
        data = {
            requestType = "DEPOSIT",
            depositMachineId = atm.config.machineId,
            accountId = accountId,
            amount = 0,  -- 0 amount = balance check
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

-- Process deposit
function atm.processDeposit(accountId, diamonds)
    local amount = diamonds * atm.config.diamondValue
    local timestamp = os.epoch("utc")
    local signature = atm.signDeposit(accountId, amount, timestamp)
    
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

-- Dispense diamond
function atm.dispenseDiamond()
    redstone.setOutput(atm.config.dispenserSide, true)
    sleep(0.1)
    redstone.setOutput(atm.config.dispenserSide, false)
end

-- Process withdrawal
function atm.processWithdrawal(accountId, diamonds)
    local amount = diamonds * atm.config.diamondValue
    local timestamp = os.epoch("utc")
    local signature = atm.signDeposit(accountId, -amount, timestamp)  -- Negative for withdrawal
    
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
        -- Dispense diamonds
        for i = 1, diamonds do
            atm.dispenseDiamond()
            sleep(0.3)
        end
        return true, response.balance
    else
        return false, response and response.error or err
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

-- Frame visibility tracking
local currentScreen = "home"  -- "home", "menu", "deposit", "withdraw"

-- Home Screen
local homeFrame = main:addFrame()
    :setPosition(1, 1)
    :setSize(termWidth, termHeight)
    :setBackground(colorBg)

homeFrame:addLabel()
    :setText("TrainPass ATM")
    :setPosition(2, 2)
    :setForeground(colorPrimary)

homeFrame:addLabel()
    :setText("Machine: " .. atm.config.machineId)
    :setPosition(2, 3)
    :setForeground(colors.lightGray)

homeFrame:addLabel()
    :setText("Please swipe your card")
    :setPosition(2, 5)
    :setForeground(colorText)
    :setFontSize(2)

local statusLabel = homeFrame:addLabel()
    :setText(cardReader and "Ready" or "ERROR: No card reader!")
    :setPosition(2, 7)
    :setForeground(cardReader and colorSuccess or colorError)

-- Menu Screen
local menuFrame = main:addFrame()
    :setPosition(1, 1)
    :setSize(termWidth, termHeight)
    :setBackground(colorBg)
    :setVisible(false)

menuFrame:addLabel()
    :setText("Account Menu")
    :setPosition(2, 2)
    :setForeground(colorPrimary)

local menuAccountLabel = menuFrame:addLabel()
    :setText("")
    :setPosition(2, 3)
    :setForeground(colors.lightGray)

local menuBalanceLabel = menuFrame:addLabel()
    :setText("")
    :setPosition(2, 4)
    :setForeground(colorSuccess)

local checkBalanceBtn = menuFrame:addButton()
    :setText("Check Balance")
    :setPosition(2, 6)
    :setSize(15, 3)
    :setBackground(colorPrimary)
    :setForeground(colors.white)

local depositBtn = menuFrame:addButton()
    :setText("Load Balance")
    :setPosition(18, 6)
    :setSize(15, 3)
    :setBackground(colorPrimary)
    :setForeground(colors.white)

local withdrawBtn = menuFrame:addButton()
    :setText("Withdraw")
    :setPosition(2, 10)
    :setSize(15, 3)
    :setBackground(colorPrimary)
    :setForeground(colors.white)

local logoutBtn = menuFrame:addButton()
    :setText("Logout")
    :setPosition(18, 10)
    :setSize(15, 3)
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
    :setText("Insert diamonds to load balance")
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
checkBalanceBtn:onClick(function()
    menuBalanceLabel:setText("Checking..."):setForeground(colors.yellow)
    basalt.update()
    
    local success, balance = atm.checkBalance(atm.currentAccount)
    if success then
        atm.currentBalance = balance
        menuBalanceLabel:setText("Balance: " .. balance):setForeground(colorSuccess)
    else
        menuBalanceLabel:setText("Error: " .. balance):setForeground(colorError)
    end
end)

-- Go to deposit screen
depositBtn:onClick(function()
    atm.diamondsInserted = 0
    depositCountLabel:setText("Diamonds inserted: 0")
    depositValueLabel:setText("Value: 0")
    
    -- Unlock hopper (allow items to enter)
    redstone.setOutput(atm.config.inventorySide, false)
    
    menuFrame:setVisible(false)
    depositFrame:setVisible(true)
    currentScreen = "deposit"
end)

-- Confirm deposit
depositConfirmBtn:onClick(function()
    -- Lock hopper (prevent more items)
    redstone.setOutput(atm.config.inventorySide, true)
    
    if atm.diamondsInserted == 0 then
        depositFrame:setVisible(false)
        menuFrame:setVisible(true)
        currentScreen = "menu"
        return
    end
    
    depositCountLabel:setText("Processing..."):setForeground(colors.yellow)
    basalt.update()
    
    local success, balance = atm.processDeposit(atm.currentAccount, atm.diamondsInserted)
    if success then
        atm.currentBalance = balance
        menuBalanceLabel:setText("Balance: " .. balance)
        depositFrame:setVisible(false)
        menuFrame:setVisible(true)
        currentScreen = "menu"
    else
        depositCountLabel:setText("Error: " .. balance):setForeground(colorError)
    end
end)

-- Cancel deposit
depositCancelBtn:onClick(function()
    -- Lock hopper (prevent more items)
    redstone.setOutput(atm.config.inventorySide, true)
    
    atm.diamondsInserted = 0
    depositFrame:setVisible(false)
    menuFrame:setVisible(true)
    currentScreen = "menu"
end)

-- Go to withdraw screen
withdrawBtn:onClick(function()
    withdrawInput:setValue("")
    withdrawValueLabel:setText("Cost: 0")
    menuFrame:setVisible(false)
    withdrawFrame:setVisible(true)
    currentScreen = "withdraw"
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
    basalt.update()
    
    local success, balance = atm.processWithdrawal(atm.currentAccount, diamonds)
    if success then
        atm.currentBalance = balance
        menuBalanceLabel:setText("Balance: " .. balance)
        withdrawFrame:setVisible(false)
        menuFrame:setVisible(true)
        currentScreen = "menu"
    else
        withdrawValueLabel:setText("Error: " .. balance):setForeground(colorError)
    end
end)

-- Cancel withdrawal
withdrawCancelBtn:onClick(function()
    withdrawFrame:setVisible(false)
    menuFrame:setVisible(true)
    currentScreen = "menu"
end)

-- Logout
logoutBtn:onClick(function()
    atm.currentAccount = nil
    atm.currentBalance = 0
    statusLabel:setText("Ready"):setForeground(colorSuccess)
    menuFrame:setVisible(false)
    homeFrame:setVisible(true)
    currentScreen = "home"
end)

-- Helper: Check if item is a diamond
local function isDiamond(itemName)
    return itemName == "minecraft:diamond"
end

-- Helper: Clear inventory
local function clearInventory()
    local size = inventory.size()
    for slot = 1, size do
        local item = inventory.getItemDetail(slot)
        if item then
            inventory.pushItems(atm.config.dispenserSide, slot)
        end
    end
end

-- Diamond detection thread using inventory API
local function diamondDetectionThread()
    local depositActive = false
    local errorMessage = nil
    
    while true do
        local wasDepositActive = depositActive
        depositActive = (currentScreen == "deposit")
        
        -- Just entered deposit screen
        if depositActive and not wasDepositActive then
            -- Reset state
            atm.diamondsInserted = 0
            errorMessage = nil
            -- Start with hopper unlocked
            redstone.setOutput(atm.config.inventorySide, false)
        end
        
        -- Just left deposit screen
        if not depositActive and wasDepositActive then
            -- Lock hopper
            redstone.setOutput(atm.config.inventorySide, true)
        end
        
        if depositActive then
            -- Check for items in inventory
            local hasItem = false
            for slot = 1, inventory.size() do
                local item = inventory.getItemDetail(slot)
                if item then
                    hasItem = true
                    break
                end
            end
            
            if hasItem then
                -- Lock hopper while processing
                redstone.setOutput(atm.config.inventorySide, true)
                
                -- Check all items
                local validDiamonds = 0
                local invalidItems = 0
                
                for slot = 1, inventory.size() do
                    local item = inventory.getItemDetail(slot)
                    if item then
                        if isDiamond(item.name) then
                            validDiamonds = validDiamonds + item.count
                            -- Remove diamonds from inventory
                            inventory.pushItems(atm.config.dispenserSide, slot)
                        else
                            invalidItems = invalidItems + 1
                            -- Return invalid item
                            inventory.pushItems(atm.config.dispenserSide, slot)
                        end
                    end
                end
                
                if validDiamonds > 0 then
                    atm.diamondsInserted = atm.diamondsInserted + validDiamonds
                    depositCountLabel:setText("Diamonds inserted: " .. atm.diamondsInserted)
                    depositValueLabel:setText("Value: " .. (atm.diamondsInserted * atm.config.diamondValue))
                        :setForeground(colors.green)
                    errorMessage = nil
                end
                
                if invalidItems > 0 then
                    errorMessage = "Invalid item(s) rejected!"
                    depositValueLabel:setText(errorMessage)
                        :setForeground(colors.red)
                end
                
                -- Wait a moment before unlocking again
                sleep(0.3)
                
                -- Unlock hopper for next item
                redstone.setOutput(atm.config.inventorySide, false)
            end
        end
        
        sleep(0.05)
    end
end

-- Card reader thread
local function cardReaderThread()
    if not cardReader then return end
    
    while true do
        local event, info = os.pullEvent("card_read")
        
        if event == "card_read" and info and info.data then
            -- Only process cards on home or menu screen
            if currentScreen == "home" then
                -- Beep and light to indicate card read
                cardReader.beep(1000)
                cardReader.setLight("YELLOW", true)
                sleep(0.1)
                cardReader.setLight("YELLOW", false)
                
                statusLabel:setText("Reading card..."):setForeground(colors.yellow)
                basalt.update()
                
                -- Look up account from card UUID
                local success, accountId = atm.getAccountByCard(info.data)
                if not success then
                    statusLabel:setText("Error: " .. accountId):setForeground(colorError)
                    
                    -- Error beep and light
                    cardReader.setLight("RED", true)
                    cardReader.beep(500)
                    sleep(0.1)
                    cardReader.beep(400)
                    sleep(0.3)
                    cardReader.setLight("RED", false)
                else
                    statusLabel:setText("Checking balance..."):setForeground(colors.yellow)
                    basalt.update()
                    
                    -- Get balance for this account
                    local balSuccess, balance = atm.checkBalance(accountId)
                    if balSuccess then
                        atm.currentAccount = accountId
                        atm.currentBalance = balance
                        menuAccountLabel:setText("Account: " .. accountId)
                        menuBalanceLabel:setText("Balance: " .. balance)
                        
                        -- Write balance to card
                        cardReader.write(info.data, "Balance: " .. balance)
                        
                        -- Success beep and light
                        cardReader.setLight("GREEN", true)
                        cardReader.beep(1500)
                        sleep(0.1)
                        cardReader.beep(1800)
                        sleep(0.2)
                        cardReader.setLight("GREEN", false)
                        
                        homeFrame:setVisible(false)
                        menuFrame:setVisible(true)
                        currentScreen = "menu"
                    else
                        statusLabel:setText("Error: " .. balance):setForeground(colorError)
                        
                        -- Error beep and light
                        cardReader.setLight("RED", true)
                        cardReader.beep(500)
                        sleep(0.1)
                        cardReader.beep(400)
                        sleep(0.3)
                        cardReader.setLight("RED", false)
                    end
                end
            elseif currentScreen == "menu" then
                -- Update card with current balance (verify card matches current account)
                local success, accountId = atm.getAccountByCard(info.data)
                if success and accountId == atm.currentAccount then
                    cardReader.write(info.data, "Balance: " .. atm.currentBalance)
                    cardReader.beep(1200)
                    cardReader.setLight("GREEN", true)
                    sleep(0.1)
                    cardReader.setLight("GREEN", false)
                end
            end
        end
    end
end

-- Start threads
parallel.waitForAny(
    function()
        basalt.run()
    end,
    diamondDetectionThread,
    cardReaderThread
)
