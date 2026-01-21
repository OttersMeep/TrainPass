-- IMPORTANT- THESE ARE THE VARIABLES TO MODIFY IF YOU WANT TO REPURPOSE THIS SYSTEM

fieldName = "pasmo_account_id" -- This is the unicard field you'll be using
serviceId = "pasmo" -- This is the name of your UniCard service

local ecc = require("ecc")
local unicard = require("unicard")
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
    gatewayChannel = 1000,
    responseChannel = nil,  -- Will be set dynamically
    adminPassword = "Benchy",  -- Default admin password for termination
    testing = true  -- If true, don't shutdown on errors (for development)
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
        atm.config.gatewayChannel = machineConfig.gatewayChannel or atm.config.gatewayChannel
        atm.config.adminPassword = machineConfig.adminPassword or atm.config.adminPassword
        atm.config.testing = machineConfig.testing or atm.config.testing
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

-- Find wired modem
local wiredModem = peripheral.find("modem", function(name, modem)
    return not modem.isWireless()
end)

if not wiredModem then
    error("No wired modem found! Deposit machine requires wired modem for peripherals.")
end
print("Wired modem detected: " .. peripheral.getName(wiredModem))

-- Find input barrel (for receiving diamonds)
local barrel = peripheral.find("minecraft:barrel")
if not barrel then
    error("No barrel found! Deposit machine requires a barrel for diamond input.")
end
print("Input barrel detected: " .. peripheral.getName(barrel))

-- Find storage chest (for storing diamonds)
local storageChest = peripheral.find("minecraft:chest")
if not storageChest then
    error("No chest found! Deposit machine requires a chest for diamond storage.")
end
print("Storage chest detected: " .. peripheral.getName(storageChest))

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
atm.diamondTally = 0  -- Expected number of diamonds in storage

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

-- Look up account by card UUID using UniCard
function atm.getAccountByCard(cardUUID)
    -- Read account ID from UniCard server
    local accountId, err = unicard.getKey(fieldName, cardUUID)
    if not accountId then
        return false, err
    end
    
    return true, accountId
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
        return true, response.newBalance or response.balance
    else
        return false, response and response.error or err
    end
end

-- Process withdrawal
function atm.processWithdrawal(accountId, amount)
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
        return true, response.newBalance or response.balance
    else
        return false, response and response.error or err
    end
end



-- Helper: Count diamonds in storage chest
local function countDiamondsInChest()
    local totalDiamonds = 0
    local items = storageChest.list()
    
    for slot, item in pairs(items) do
        if item.name == "minecraft:diamond" then
            totalDiamonds = totalDiamonds + item.count
        end
    end
    
    return totalDiamonds
end

-- Helper: Save diamond tally to disk
local function saveDiamondTally()
    local file = fs.open("diamond_tally.dat", "w")
    if file then
        file.write(tostring(atm.diamondTally))
        file.close()
    end
end

-- Helper: Load diamond tally from disk
local function loadDiamondTally()
    if fs.exists("diamond_tally.dat") then
        local file = fs.open("diamond_tally.dat", "r")
        if file then
            local tally = tonumber(file.readAll())
            file.close()
            return tally or 0
        end
    end
    return nil
end

-- Helper: Transfer diamonds from barrel to storage chest
local function processBarrelDeposit()
    local items = barrel.list()
    local diamondSlots = {}
    
    -- Find all slots with diamonds
    for slot, item in pairs(items) do
        if item.name == "minecraft:diamond" then
            table.insert(diamondSlots, slot)
        end
    end
    
    -- Count diamonds before transfer
    local diamondsBefore = countDiamondsInChest()
    
    -- Transfer diamonds from barrel to chest
    for _, slot in ipairs(diamondSlots) do
        barrel.pushItems(peripheral.getName(storageChest), slot)
    end
    
    -- Count diamonds after transfer
    local diamondsAfter = countDiamondsInChest()
    
    -- Calculate how many were deposited
    local deposited = diamondsAfter - diamondsBefore
    
    -- Update the tally
    atm.diamondTally = diamondsAfter
    saveDiamondTally()
    
    return deposited
end

-- Helper: Transfer diamonds from chest to barrel for withdrawal
local function processChestWithdrawal(diamondsNeeded)
    local items = storageChest.list()
    local transferred = 0
    
    -- Transfer diamonds from chest to barrel
    for slot, item in pairs(items) do
        if item.name == "minecraft:diamond" and transferred < diamondsNeeded then
            local toTransfer = math.min(item.count, diamondsNeeded - transferred)
            local actuallyTransferred = storageChest.pushItems(peripheral.getName(barrel), slot, toTransfer)
            transferred = transferred + actuallyTransferred
            
            if transferred >= diamondsNeeded then
                break
            end
        end
    end
    
    -- Update the tally
    atm.diamondTally = atm.diamondTally - transferred
    saveDiamondTally()
    
    return transferred
end

-- Create Basalt UI on computer terminal
local main = basalt.createFrame()

-- Initialize state
main:initializeState("currentScreen", "home")

-- Get terminal size
local termWidth, termHeight = term.getSize()

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
    :setText("TrainPass Deposit")
    :setPosition(2, 2)
    :setForeground(colorPrimary)

homeFrame:addLabel()
    :setText("Please swipe your card")
    :setPosition(2, 4)
    :setForeground(colorText)

local statusLabel = homeFrame:addLabel()
    :setText(cardReader and "Ready" or "ERROR: No card reader!")
    :setPosition(2, 6)
    :setForeground(cardReader and colorSuccess or colorError)

homeFrame:addLabel()
    :setText("Admin Login:")
    :setPosition(2, termHeight - 4)
    :setForeground(colorText)

local adminPasswordInput = homeFrame:addInput({replaceChar="*"})
    :setPosition(2, termHeight - 3)
    :setSize(termWidth - 4, 1)
    :setBackground(colors.black)
    :setForeground(colors.white)

local adminLoginBtn = homeFrame:addButton()
    :setText("Exit")
    :setPosition(2, termHeight - 1)
    :setSize(10, 1)
    :setBackground(colors.orange)
    :setForeground(colors.white)

local adminStatusLabel = homeFrame:addLabel()
    :setText("")
    :setPosition(13, termHeight - 1)
    :setForeground(colorError)

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
    :setText("Deposit Diamonds")
    :setPosition(2, 5)
    :setSize((termWidth-4), 3)
    :setBackground(colorPrimary)
    :setForeground(colors.white)

local withdrawBtn = menuFrame:addButton()
    :setText("Withdraw Diamonds")
    :setPosition(2, 9)
    :setSize((termWidth-4), 3)
    :setBackground(colorPrimary)
    :setForeground(colors.white)

local logoutBtn = menuFrame:addButton()
    :setText("Logout")
    :setPosition(2, 13)
    :setSize((termWidth-4), 3)
    :setBackground(colorError)
    :setForeground(colors.white)

-- Deposit Screen
local depositFrame = main:addFrame()
    :setPosition(1, 1)
    :setSize(termWidth, termHeight)
    :setBackground(colorBg)
    :setVisible(false)

depositFrame:addLabel()
    :setText("Deposit Diamonds")
    :setPosition(2, 2)
    :setForeground(colorPrimary)

depositFrame:addLabel()
    :setText("Put diamonds in barrel")
    :setPosition(2, 4)
    :setForeground(colorText)

depositFrame:addLabel()
    :setText("then click Confirm")
    :setPosition(2, 5)
    :setForeground(colorText)

local depositStatusLabel = depositFrame:addLabel()
    :setText("")
    :setPosition(2, 7)
    :setForeground(colors.yellow)

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

local withdrawBalanceLabel = withdrawFrame:addLabel()
    :setText("")
    :setPosition(2, 4)
    :setForeground(colorSuccess)

withdrawFrame:addLabel()
    :setText("Diamonds to withdraw:")
    :setPosition(2, 6)
    :setForeground(colorText)

local withdrawInput = withdrawFrame:addInput()
    :setPosition(2, 7)
    :setSize(termWidth-4, 1)
    :setBackground(colors.black)
    :setForeground(colors.white)

local withdrawStatusLabel = withdrawFrame:addLabel()
    :setText("")
    :setPosition(2, 9)
    :setForeground(colors.yellow)

local withdrawConfirmBtn = withdrawFrame:addButton()
    :setText("Confirm")
    :setPosition(2, 11)
    :setSize(16, 3)
    :setBackground(colorSuccess)
    :setForeground(colors.white)

local withdrawCancelBtn = withdrawFrame:addButton()
    :setText("Cancel")
    :setPosition(19, 11)
    :setSize(10, 3)
    :setBackground(colorError)
    :setForeground(colors.white)

-- Theft Alert Screen
local theftFrame = main:addFrame()
    :setPosition(1, 1)
    :setSize(termWidth, termHeight)
    :setBackground(colorError)
    :setVisible(false)

theftFrame:addLabel()
    :setText("!!! THEFT ALERT !!!")
    :setPosition(2, 3)
    :setForeground(colors.white)

local theftDetailsLabel = theftFrame:addLabel()
    :setText("")
    :setPosition(2, 5)
    :setForeground(colors.white)

theftFrame:addLabel()
    :setText("Unauthorized diamond")
    :setPosition(2, 7)
    :setForeground(colors.white)

theftFrame:addLabel()
    :setText("removal detected!")
    :setPosition(2, 8)
    :setForeground(colors.white)

theftFrame:addLabel()
    :setText("Please contact an")
    :setPosition(2, 10)
    :setForeground(colors.white)

theftFrame:addLabel()
    :setText("administrator.")
    :setPosition(2, 11)
    :setForeground(colors.white)

-- Event Handlers

-- Admin Login
adminLoginBtn:onClick(function()
    local password = adminPasswordInput:getText()
    
    if password == atm.config.adminPassword then
        -- Correct password - save authentication flag and terminate
        local file = fs.open(".admin_authenticated", "w")
        file.write("true")
        file.close()
        os.queueEvent("terminate")
    else
        -- Incorrect password
        adminStatusLabel:setText("Incorrect password")
        adminPasswordInput:setText("")
        
        basalt.schedule(function()
            sleep(2)
            adminStatusLabel:setText("")
        end)
    end
end)

-- Check Balance
checkBalanceBtn:onClick(function(self)
    menuBalanceLabel:setText("Checking..."):setForeground(colors.yellow)
    
    basalt.schedule(function()
        local success, balance = atm.checkBalance(atm.currentAccount)
        if success then
            atm.currentBalance = balance
            menuBalanceLabel:setText("Balance: " .. balance):setForeground(colorSuccess)
        else
            menuBalanceLabel:setText("Error: " .. tostring(balance)):setForeground(colorError)
        end
    end)
end)

-- Go to deposit screen
depositBtn:onClick(function()
    depositStatusLabel:setText("")
    
    menuFrame:setVisible(false)
    depositFrame:setVisible(true)
    main:setState("currentScreen", "deposit")
end)

-- Go to withdraw screen
withdrawBtn:onClick(function()
    withdrawStatusLabel:setText("")
    withdrawInput:setText("")
    
    -- Show diamonds available
    local diamondsAvailable = math.floor(atm.currentBalance / atm.config.diamondValue)
    withdrawBalanceLabel:setText("Diamonds available: " .. diamondsAvailable)
    
    menuFrame:setVisible(false)
    withdrawFrame:setVisible(true)
    main:setState("currentScreen", "withdraw")
end)

-- Confirm deposit
depositConfirmBtn:onClick(function()
    depositStatusLabel:setText("Processing..."):setForeground(colors.yellow)
    
    basalt.schedule(function()
        -- Transfer diamonds from barrel to storage chest and count
        local diamonds = processBarrelDeposit()
        
        if diamonds == 0 then
            depositStatusLabel:setText("No diamonds found"):setForeground(colorError)
            sleep(2)
            depositFrame:setVisible(false)
            menuFrame:setVisible(true)
            main:setState("currentScreen", "menu")
            return
        end
        
        depositStatusLabel:setText("Depositing " .. diamonds .. " diamonds..."):setForeground(colors.yellow)
        
        local success, balance = atm.processDeposit(atm.currentAccount, diamonds)
        
        if success then
            if balance then
                atm.currentBalance = balance
                menuBalanceLabel:setText("Balance: " .. balance)
            end
            depositStatusLabel:setText("Deposited +" .. (diamonds * atm.config.diamondValue)):setForeground(colorSuccess)
            sleep(2)
            
            depositFrame:setVisible(false)
            menuFrame:setVisible(true)
            main:setState("currentScreen", "menu")
        else
            local errorMsg = tostring(balance or "Unknown error")
            depositStatusLabel:setText("Error: " .. errorMsg):setForeground(colorError)
        end
    end)
end)
-- Cancel deposit
depositCancelBtn:onClick(function()
    depositFrame:setVisible(false)
    menuFrame:setVisible(true)
    main:setState("currentScreen", "menu")
end)

-- Confirm withdrawal
withdrawConfirmBtn:onClick(function()
    local diamondsStr = withdrawInput:getText()
    local diamonds = math.floor(tonumber(diamondsStr) or 0)
    
    if not diamonds or diamonds <= 0 then
        withdrawStatusLabel:setText("Invalid amount"):setForeground(colorError)
        return
    end
    
    local diamondsAvailable = math.floor(atm.currentBalance / atm.config.diamondValue)
    if diamonds > diamondsAvailable then
        withdrawStatusLabel:setText("Not enough diamonds"):setForeground(colorError)
        return
    end
    
    withdrawStatusLabel:setText("Processing..."):setForeground(colors.yellow)
    
    basalt.schedule(function()
        -- Check how many diamonds are actually in storage
        local diamondsInStorage = countDiamondsInChest()
        local diamondsToWithdraw = math.min(diamonds, diamondsInStorage)
        
        if diamondsToWithdraw == 0 then
            withdrawStatusLabel:setText("Error: No diamonds in storage"):setForeground(colorError)
            return
        end
        
        -- Calculate amount to deduct based on what we can actually give
        local amount = diamondsToWithdraw * atm.config.diamondValue
        
        -- Deduct from account (send as negative)
        local success, newBalance = atm.processWithdrawal(atm.currentAccount, -amount)
        
        if not success then
            local errorMsg = tostring(newBalance or "Unknown error")
            withdrawStatusLabel:setText("Error: " .. errorMsg):setForeground(colorError)
            return
        end
        
        -- Transfer diamonds from chest to barrel
        local transferred = processChestWithdrawal(diamondsToWithdraw)
        
        if transferred < diamondsToWithdraw then
            withdrawStatusLabel:setText("Error: Transfer failed"):setForeground(colorError)
            -- TODO: Should reverse the withdrawal transaction here
            return
        end
        
        -- Update balance
        if newBalance then
            atm.currentBalance = newBalance
            menuBalanceLabel:setText("Balance: " .. newBalance)
        end
        
        -- Show appropriate message
        if diamondsToWithdraw < diamonds then
            withdrawStatusLabel:setText("Partial: " .. diamondsToWithdraw .. "/" .. diamonds .. " diamonds"):setForeground(colors.orange)
        else
            withdrawStatusLabel:setText("Withdrawn " .. diamondsToWithdraw .. " diamonds"):setForeground(colorSuccess)
        end
        sleep(2)
        
        withdrawFrame:setVisible(false)
        menuFrame:setVisible(true)
        main:setState("currentScreen", "menu")
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


local savedTally = loadDiamondTally()
if savedTally then
    atm.diamondTally = savedTally
    print("Loaded diamond tally from disk: " .. atm.diamondTally)
else
    atm.diamondTally = countDiamondsInChest()
    saveDiamondTally()
    print("Initial diamond tally: " .. atm.diamondTally)
end

function uniCardInit()
    local timestamp = os.epoch("utc")

    atm.sendRequest({
        data = {
            requestType = "GET_UNICARD_KEY",
            timestamp = timestamp
        },
        timestamp = timestamp
    })

    local response, err = atm.waitForResponse(10)

    if response and response.success then
        unicard.init(response.privateKey, response.publicKey, 200, serviceId)
    else
        print(textutils.serialize(response))
        error("BAD RESPONSE")
    end
end
uniCardInit()


basalt.schedule(function()
    -- Background task to blink redstone when storage is empty and detect theft
    local previousScreen = nil
    local theftDetected = false
    
    while true do
        local diamondsInStorage = countDiamondsInChest()
        
        -- Check for theft (diamonds removed without proper withdrawal)
        if diamondsInStorage ~= atm.diamondTally then
            local difference = diamondsInStorage - atm.diamondTally
            local moreOrLess = difference > 0 and "more" or "less"
            local absDiff = math.abs(difference)
            
            -- Show theft alert screen
            if not theftDetected then
                previousScreen = main:getState("currentScreen")
                theftDetected = true
                
                -- Hide all other screens
                homeFrame:setVisible(false)
                menuFrame:setVisible(false)
                depositFrame:setVisible(false)
                withdrawFrame:setVisible(false)
                
                -- Show theft alert
                theftFrame:setVisible(true)
                main:setState("currentScreen", "theft")
            end
            
            -- Update the theft details label continuously
            theftDetailsLabel:setText(diamondsInStorage .. " diamonds found, " .. absDiff .. " " .. moreOrLess .. " than expected!")
            -- Sound alarm - diamonds don't match expected!
            if cardReader then
                cardReader.beep(440)
                cardReader.setLight("RED",true)
            end
            sleep(0.15)
            cardReader.setLight("RED",false)
            sleep(0.15)
        elseif diamondsInStorage == 0 then
            -- Clear theft alert and restore previous screen
            if theftDetected then
                theftFrame:setVisible(false)
                theftDetected = false
                
                -- Restore previous screen
                if previousScreen == "home" then
                    homeFrame:setVisible(true)
                elseif previousScreen == "menu" then
                    menuFrame:setVisible(true)
                elseif previousScreen == "deposit" then
                    depositFrame:setVisible(true)
                elseif previousScreen == "withdraw" then
                    withdrawFrame:setVisible(true)
                else
                    homeFrame:setVisible(true)
                end
                main:setState("currentScreen", previousScreen or "home")
            end
            
            -- Blink redstone on the right when empty
            redstone.setOutput("right", true)
            sleep(0.5)
            redstone.setOutput("right", false)
            sleep(0.5)
        else
            -- Clear theft alert and restore previous screen
            if theftDetected then
                theftFrame:setVisible(false)
                theftDetected = false
                
                -- Restore previous screen
                if previousScreen == "home" then
                    homeFrame:setVisible(true)
                elseif previousScreen == "menu" then
                    menuFrame:setVisible(true)
                elseif previousScreen == "deposit" then
                    depositFrame:setVisible(true)
                elseif previousScreen == "withdraw" then
                    withdrawFrame:setVisible(true)
                else
                    homeFrame:setVisible(true)
                end
                main:setState("currentScreen", previousScreen or "home")
            end
            
            redstone.setOutput("right", true)
            sleep(2)
        end
    end
end)


basalt.run()