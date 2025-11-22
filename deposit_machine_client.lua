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
    modem.transmit(
        atm.config.gatewayChannel,
        atm.config.responseChannel,
        textutils.serialize(requestData)
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

-- Colors
local colorBg = colors.gray
local colorPrimary = colors.blue
local colorSuccess = colors.green
local colorError = colors.red
local colorText = colors.white

-- Home Screen
local homeFrame = main:addFrame()
    :setPosition(1, 1)
    :setSize("parent.w", "parent.h")
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
    :setText("Enter Account ID:")
    :setPosition(2, 5)
    :setForeground(colorText)

local accountInput = homeFrame:addInput()
    :setPosition(2, 6)
    :setSize(20, 1)
    :setBackground(colors.black)
    :setForeground(colors.white)

local statusLabel = homeFrame:addLabel()
    :setText("")
    :setPosition(2, 8)
    :setForeground(colorText)

local loginBtn = homeFrame:addButton()
    :setText("Login")
    :setPosition(2, 10)
    :setSize(10, 3)
    :setBackground(colorPrimary)
    :setForeground(colors.white)

-- Menu Screen
local menuFrame = main:addFrame()
    :setPosition(1, 1)
    :setSize("parent.w", "parent.h")
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
    :setSize("parent.w", "parent.h")
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
    :setSize("parent.w", "parent.h")
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

-- Login
loginBtn:onClick(function()
    local accountId = accountInput:getValue()
    if accountId == "" then
        statusLabel:setText("Please enter account ID"):setForeground(colorError)
        return
    end
    
    statusLabel:setText("Checking account..."):setForeground(colors.yellow)
    basalt.update()
    
    local success, balance = atm.checkBalance(accountId)
    if success then
        atm.currentAccount = accountId
        atm.currentBalance = balance
        menuAccountLabel:setText("Account: " .. accountId)
        menuBalanceLabel:setText("Balance: " .. balance)
        homeFrame:setVisible(false)
        menuFrame:setVisible(true)
    else
        statusLabel:setText("Error: " .. balance):setForeground(colorError)
    end
end)

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
end)

-- Confirm deposit
depositConfirmBtn:onClick(function()
    -- Lock hopper (prevent more items)
    redstone.setOutput(atm.config.inventorySide, true)
    
    if atm.diamondsInserted == 0 then
        depositFrame:setVisible(false)
        menuFrame:setVisible(true)
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
end)

-- Go to withdraw screen
withdrawBtn:onClick(function()
    withdrawInput:setValue("")
    withdrawValueLabel:setText("Cost: 0")
    menuFrame:setVisible(false)
    withdrawFrame:setVisible(true)
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
    else
        withdrawValueLabel:setText("Error: " .. balance):setForeground(colorError)
    end
end)

-- Cancel withdrawal
withdrawCancelBtn:onClick(function()
    withdrawFrame:setVisible(false)
    menuFrame:setVisible(true)
end)

-- Logout
logoutBtn:onClick(function()
    atm.currentAccount = nil
    atm.currentBalance = 0
    accountInput:setValue("")
    statusLabel:setText("")
    menuFrame:setVisible(false)
    homeFrame:setVisible(true)
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
        depositActive = depositFrame:isVisible()
        
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

-- Start threads
parallel.waitForAny(
    function()
        basalt.autoUpdate()
    end,
    diamondDetectionThread
)
