-- Account Portal - Account Management Interface
-- Allows users to create accounts, add/remove payment cards
-- Uses username/password authentication with Basalt UI

-- Check for Basalt
if not fs.exists("basalt.lua") then
    print("Downloading Basalt UI library...")
    shell.run("wget", "run", "https://basalt.madefor.cc/install.lua", "release", "latest.lua", "basalt.lua")
    if not fs.exists("basalt.lua") then
        error("Failed to download Basalt! Please install manually.")
    end
end

local ecc = require("ecc")
local basalt = require("basalt")

local portal = {}

-- Configuration (will be overridden by machine_config.lua if it exists)
portal.config = {
    machineId = "PORTAL_001",
    privateKey = "",  -- Set via config
    gatewayPublicKey = "",  -- Set via config
    gatewayChannel = 1000,
    responseChannel = nil  -- Will be set dynamically
}

-- Load configuration from machine_config.lua if it exists
if fs.exists("machine_config.lua") then
    local machineConfig = dofile("machine_config.lua")
    if machineConfig then
        portal.config.machineId = machineConfig.machineId or portal.config.machineId
        portal.config.privateKey = machineConfig.privateKey or portal.config.privateKey
        portal.config.gatewayPublicKey = machineConfig.gatewayPublicKey or portal.config.gatewayPublicKey
        portal.config.gatewayChannel = machineConfig.gatewayChannel or portal.config.gatewayChannel
    end
end

-- Validate configuration
if not portal.config.privateKey or type(portal.config.privateKey) ~= "table" then
    error("Private key not configured or invalid!")
end

if not portal.config.gatewayPublicKey or type(portal.config.gatewayPublicKey) ~= "table" then
    error("Gateway public key not configured or invalid!")
end

print("Configuration loaded successfully")
print("Machine ID: " .. portal.config.machineId)

-- Derive shared secret for encryption
portal.sharedSecret = ecc.exchange(portal.config.privateKey, portal.config.gatewayPublicKey)
print("Shared secret derived")

-- Password storage (hashed)
portal.passwords = {}  -- accountId -> passwordHash

-- Find card reader
local cardReader = peripheral.find("card_reader")
if not cardReader then
    error("No card reader found! Portal requires card reader.")
end
print("Card reader detected: " .. peripheral.getName(cardReader))

-- Find wireless modem
local modem = peripheral.find("modem", function(name, modem)
    return modem.isWireless()
end)

if not modem then
    error("No wireless modem found! Portal requires wireless modem.")
end

-- Generate unique response channel
portal.config.responseChannel = 3000 + math.random(1, 6999)
modem.open(portal.config.responseChannel)

-- State
portal.currentUser = nil
portal.currentAccount = nil
portal.waitingForResponse = false

-- Hash password
function portal.hashPassword(password)
    return ecc.sha256.digest(password):toHex()
end

-- Send request to gateway
function portal.sendRequest(requestData)
    portal.waitingForResponse = true
    
    -- Encrypt the request data with the shared secret
    local serializedData = textutils.serialize(requestData.data)
    local encryptedData = ecc.encrypt(serializedData, portal.sharedSecret)
    
    -- Send encrypted packet with machine ID
    modem.transmit(
        portal.config.gatewayChannel,
        portal.config.responseChannel,
        textutils.serialize({
            machineId = portal.config.machineId,
            encryptedData = encryptedData,
            timestamp = requestData.timestamp
        })
    )
end

-- Wait for response with timeout
function portal.waitForResponse(timeout)
    timeout = timeout or 10
    local timer = os.startTimer(timeout)
    
    while true do
        local event, p1, p2, p3, p4 = os.pullEvent()
        
        if event == "modem_message" and p2 == portal.config.responseChannel then
            os.cancelTimer(timer)
            portal.waitingForResponse = false
            local response = textutils.unserialize(p4)
            return response
        elseif event == "timer" and p1 == timer then
            portal.waitingForResponse = false
            return nil, "Timeout"
        end
    end
end

-- Create account
function portal.createAccount(username, password, cardUUID)
    local timestamp = os.epoch("utc")
    
    portal.sendRequest({
        data = {
            requestType = "CREATE_ACCOUNT",
            username = username,
            cardUUID = cardUUID,
            portalId = portal.config.machineId,
            timestamp = timestamp
        },
        timestamp = timestamp
    })
    
    local response, err = portal.waitForResponse(10)
    if response and response.success and response.accountId then
        -- Store password hash locally
        portal.passwords[response.accountId] = portal.hashPassword(password)
        portal.savePasswords()
        return true, response.accountId
    else
        return false, response and response.error or err or "Account creation failed"
    end
end

-- Login with username and password
function portal.login(username, password)
    local timestamp = os.epoch("utc")
    
    portal.sendRequest({
        data = {
            requestType = "GET_ACCOUNT_BY_USERNAME",
            username = username,
            timestamp = timestamp
        },
        timestamp = timestamp
    })
    
    local response, err = portal.waitForResponse(10)
    if response and response.success and response.account then
        local accountId = response.account.accountId
        local storedHash = portal.passwords[accountId]
        local inputHash = portal.hashPassword(password)
        
        if storedHash == inputHash then
            return true, response.account
        else
            return false, "Invalid password"
        end
    else
        return false, response and response.error or err or "Account not found"
    end
end

-- Add card to account
function portal.addCard(accountId, cardUUID)
    local timestamp = os.epoch("utc")
    
    portal.sendRequest({
        data = {
            requestType = "ADD_CARD",
            accountId = accountId,
            cardUUID = cardUUID,
            timestamp = timestamp
        },
        timestamp = timestamp
    })
    
    local response, err = portal.waitForResponse(10)
    if response and response.success then
        return true
    else
        return false, response and response.error or err or "Failed to add card"
    end
end

-- Remove card from account
function portal.removeCard(accountId, cardUUID)
    local timestamp = os.epoch("utc")
    
    portal.sendRequest({
        data = {
            requestType = "REMOVE_CARD",
            accountId = accountId,
            cardUUID = cardUUID,
            timestamp = timestamp
        },
        timestamp = timestamp
    })
    
    local response, err = portal.waitForResponse(10)
    if response and response.success then
        return true
    else
        return false, response and response.error or err or "Failed to remove card"
    end
end

-- Get account info
function portal.getAccountInfo(accountId)
    local timestamp = os.epoch("utc")
    
    portal.sendRequest({
        data = {
            requestType = "GET_ACCOUNT",
            accountId = accountId,
            timestamp = timestamp
        },
        timestamp = timestamp
    })
    
    local response, err = portal.waitForResponse(10)
    if response and response.success and response.account then
        return true, response.account
    else
        return false, response and response.error or err or "Account not found"
    end
end

-- Save passwords to disk
function portal.savePasswords()
    local file = fs.open("portal_passwords.dat", "w")
    if file then
        file.write(textutils.serialize(portal.passwords))
        file.close()
    end
end

-- Load passwords from disk
function portal.loadPasswords()
    if fs.exists("portal_passwords.dat") then
        local file = fs.open("portal_passwords.dat", "r")
        if file then
            local data = textutils.unserialize(file.readAll())
            file.close()
            if data then
                portal.passwords = data
                print("Loaded password database")
            end
        end
    end
end

-- Load passwords
portal.loadPasswords()

-- Create Basalt UI
local main = basalt.createFrame()

local termWidth, termHeight = term.getSize()

-- Colors
local colorBg = colors.gray
local colorPrimary = colors.blue
local colorSuccess = colors.green
local colorError = colors.red
local colorText = colors.white

-- Current screen tracking
local currentScreen = "home"  -- "home", "create", "login", "menu", "add_card", "remove_card"

-- Home Screen
local homeFrame = main:addFrame()
    :setPosition(1, 1)
    :setSize(termWidth, termHeight)
    :setBackground(colorBg)

homeFrame:addLabel()
    :setText("TrainPass Portal")
    :setPosition(2, 2)
    :setForeground(colorPrimary)

homeFrame:addLabel()
    :setText("Account Management")
    :setPosition(2, 3)
    :setForeground(colors.lightGray)

local createAccountBtn = homeFrame:addButton()
    :setText("Create Account")
    :setPosition(2, 6)
    :setSize(20, 3)
    :setBackground(colorPrimary)
    :setForeground(colors.white)

local loginBtn = homeFrame:addButton()
    :setText("Login")
    :setPosition(2, 10)
    :setSize(20, 3)
    :setBackground(colorSuccess)
    :setForeground(colors.white)

local homeStatusLabel = homeFrame:addLabel()
    :setText("")
    :setPosition(2, 14)
    :setForeground(colorError)

-- Create Account Screen
local createFrame = main:addFrame()
    :setPosition(1, 1)
    :setSize(termWidth, termHeight)
    :setBackground(colorBg)
    :setVisible(false)

createFrame:addLabel()
    :setText("Create Account")
    :setPosition(2, 2)
    :setForeground(colorPrimary)

createFrame:addLabel()
    :setText("Username:")
    :setPosition(2, 4)
    :setForeground(colorText)

local createUsernameInput = createFrame:addInput()
    :setPosition(2, 5)
    :setSize(20, 1)
    :setBackground(colors.black)
    :setForeground(colors.white)

createFrame:addLabel()
    :setText("Password:")
    :setPosition(2, 7)
    :setForeground(colorText)

local createPasswordInput = createFrame:addInput()
    :setPosition(2, 8)
    :setSize(20, 1)
    :setBackground(colors.black)
    :setForeground(colors.white)
    :setInputType("password")

createFrame:addLabel()
    :setText("Swipe a card to register:")
    :setPosition(2, 10)
    :setForeground(colorText)

local createCardLabel = createFrame:addLabel()
    :setText("No card")
    :setPosition(2, 11)
    :setForeground(colors.yellow)

local createCardUUID = nil

local createConfirmBtn = createFrame:addButton()
    :setText("Create")
    :setPosition(2, 13)
    :setSize(10, 3)
    :setBackground(colorSuccess)
    :setForeground(colors.white)

local createCancelBtn = createFrame:addButton()
    :setText("Cancel")
    :setPosition(13, 13)
    :setSize(10, 3)
    :setBackground(colorError)
    :setForeground(colors.white)

local createStatusLabel = createFrame:addLabel()
    :setText("")
    :setPosition(2, 17)
    :setForeground(colorError)

-- Login Screen
local loginFrame = main:addFrame()
    :setPosition(1, 1)
    :setSize(termWidth, termHeight)
    :setBackground(colorBg)
    :setVisible(false)

loginFrame:addLabel()
    :setText("Login")
    :setPosition(2, 2)
    :setForeground(colorPrimary)

loginFrame:addLabel()
    :setText("Username:")
    :setPosition(2, 4)
    :setForeground(colorText)

local loginUsernameInput = loginFrame:addInput()
    :setPosition(2, 5)
    :setSize(20, 1)
    :setBackground(colors.black)
    :setForeground(colors.white)

loginFrame:addLabel()
    :setText("Password:")
    :setPosition(2, 7)
    :setForeground(colorText)

local loginPasswordInput = loginFrame:addInput()
    :setPosition(2, 8)
    :setSize(20, 1)
    :setBackground(colors.black)
    :setForeground(colors.white)
    :setInputType("password")

local loginConfirmBtn = loginFrame:addButton()
    :setText("Login")
    :setPosition(2, 10)
    :setSize(10, 3)
    :setBackground(colorSuccess)
    :setForeground(colors.white)

local loginCancelBtn = loginFrame:addButton()
    :setText("Cancel")
    :setPosition(13, 10)
    :setSize(10, 3)
    :setBackground(colorError)
    :setForeground(colors.white)

local loginStatusLabel = loginFrame:addLabel()
    :setText("")
    :setPosition(2, 14)
    :setForeground(colorError)

-- Menu Screen (after login)
local menuFrame = main:addFrame()
    :setPosition(1, 1)
    :setSize(termWidth, termHeight)
    :setBackground(colorBg)
    :setVisible(false)

menuFrame:addLabel()
    :setText("Account Menu")
    :setPosition(2, 2)
    :setForeground(colorPrimary)

local menuUsernameLabel = menuFrame:addLabel()
    :setText("")
    :setPosition(2, 3)
    :setForeground(colors.lightGray)

local menuBalanceLabel = menuFrame:addLabel()
    :setText("")
    :setPosition(2, 4)
    :setForeground(colorSuccess)

local menuCardsLabel = menuFrame:addLabel()
    :setText("")
    :setPosition(2, 5)
    :setForeground(colorText)

local addCardBtn = menuFrame:addButton()
    :setText("Add Card")
    :setPosition(2, 8)
    :setSize(15, 3)
    :setBackground(colorPrimary)
    :setForeground(colors.white)

local removeCardBtn = menuFrame:addButton()
    :setText("Remove Card")
    :setPosition(18, 8)
    :setSize(15, 3)
    :setBackground(colorPrimary)
    :setForeground(colors.white)

local menuLogoutBtn = menuFrame:addButton()
    :setText("Logout")
    :setPosition(2, 12)
    :setSize(15, 3)
    :setBackground(colorError)
    :setForeground(colors.white)

local menuStatusLabel = menuFrame:addLabel()
    :setText("")
    :setPosition(2, 16)
    :setForeground(colorError)

-- Add Card Screen
local addCardFrame = main:addFrame()
    :setPosition(1, 1)
    :setSize(termWidth, termHeight)
    :setBackground(colorBg)
    :setVisible(false)

addCardFrame:addLabel()
    :setText("Add Card")
    :setPosition(2, 2)
    :setForeground(colorPrimary)

addCardFrame:addLabel()
    :setText("Swipe card to add:")
    :setPosition(2, 4)
    :setForeground(colorText)

local addCardStatusLabel = addCardFrame:addLabel()
    :setText("Waiting for card...")
    :setPosition(2, 6)
    :setForeground(colors.yellow)

local addCardCancelBtn = addCardFrame:addButton()
    :setText("Cancel")
    :setPosition(2, 10)
    :setSize(10, 3)
    :setBackground(colorError)
    :setForeground(colors.white)

-- Remove Card Screen
local removeCardFrame = main:addFrame()
    :setPosition(1, 1)
    :setSize(termWidth, termHeight)
    :setBackground(colorBg)
    :setVisible(false)

removeCardFrame:addLabel()
    :setText("Remove Card")
    :setPosition(2, 2)
    :setForeground(colorPrimary)

removeCardFrame:addLabel()
    :setText("Swipe card to remove:")
    :setPosition(2, 4)
    :setForeground(colorText)

local removeCardStatusLabel = removeCardFrame:addLabel()
    :setText("Waiting for card...")
    :setPosition(2, 6)
    :setForeground(colors.yellow)

local removeCardCancelBtn = removeCardFrame:addButton()
    :setText("Cancel")
    :setPosition(2, 10)
    :setSize(10, 3)
    :setBackground(colorError)
    :setForeground(colors.white)

-- Event Handlers

-- Go to create account screen
createAccountBtn:onClick(function()
    createUsernameInput:setValue("")
    createPasswordInput:setValue("")
    createCardLabel:setText("No card")
    createCardUUID = nil
    createStatusLabel:setText("")
    homeFrame:setVisible(false)
    createFrame:setVisible(true)
    currentScreen = "create"
end)

-- Go to login screen
loginBtn:onClick(function()
    loginUsernameInput:setValue("")
    loginPasswordInput:setValue("")
    loginStatusLabel:setText("")
    homeFrame:setVisible(false)
    loginFrame:setVisible(true)
    currentScreen = "login"
end)

-- Create account confirm
createConfirmBtn:onClick(function()
    local username = createUsernameInput:getValue()
    local password = createPasswordInput:getValue()
    
    if username == "" or password == "" then
        createStatusLabel:setText("Username and password required"):setForeground(colorError)
        return
    end
    
    if not createCardUUID then
        createStatusLabel:setText("Please swipe a card"):setForeground(colorError)
        return
    end
    
    createStatusLabel:setText("Creating account..."):setForeground(colors.yellow)
    basalt.update()
    
    local success, result = portal.createAccount(username, password, createCardUUID)
    if success then
        createStatusLabel:setText("Account created!"):setForeground(colorSuccess)
        sleep(2)
        createFrame:setVisible(false)
        homeFrame:setVisible(true)
        currentScreen = "home"
    else
        createStatusLabel:setText("Error: " .. tostring(result)):setForeground(colorError)
    end
end)

-- Create account cancel
createCancelBtn:onClick(function()
    createFrame:setVisible(false)
    homeFrame:setVisible(true)
    currentScreen = "home"
end)

-- Login confirm
loginConfirmBtn:onClick(function()
    local username = loginUsernameInput:getValue()
    local password = loginPasswordInput:getValue()
    
    if username == "" or password == "" then
        loginStatusLabel:setText("Username and password required"):setForeground(colorError)
        return
    end
    
    loginStatusLabel:setText("Logging in..."):setForeground(colors.yellow)
    basalt.update()
    
    local success, account = portal.login(username, password)
    if success then
        portal.currentUser = username
        portal.currentAccount = account
        
        -- Update menu
        menuUsernameLabel:setText("User: " .. username)
        menuBalanceLabel:setText("Balance: " .. account.balance)
        menuCardsLabel:setText("Cards: " .. #account.cardUUIDs)
        
        loginFrame:setVisible(false)
        menuFrame:setVisible(true)
        currentScreen = "menu"
    else
        loginStatusLabel:setText("Error: " .. tostring(account)):setForeground(colorError)
    end
end)

-- Login cancel
loginCancelBtn:onClick(function()
    loginFrame:setVisible(false)
    homeFrame:setVisible(true)
    currentScreen = "login"
end)

-- Go to add card screen
addCardBtn:onClick(function()
    addCardStatusLabel:setText("Waiting for card..."):setForeground(colors.yellow)
    menuFrame:setVisible(false)
    addCardFrame:setVisible(true)
    currentScreen = "add_card"
end)

-- Go to remove card screen
removeCardBtn:onClick(function()
    removeCardStatusLabel:setText("Waiting for card..."):setForeground(colors.yellow)
    menuFrame:setVisible(false)
    removeCardFrame:setVisible(true)
    currentScreen = "remove_card"
end)

-- Add card cancel
addCardCancelBtn:onClick(function()
    addCardFrame:setVisible(false)
    menuFrame:setVisible(true)
    currentScreen = "menu"
end)

-- Remove card cancel
removeCardCancelBtn:onClick(function()
    removeCardFrame:setVisible(false)
    menuFrame:setVisible(true)
    currentScreen = "menu"
end)

-- Logout
menuLogoutBtn:onClick(function()
    portal.currentUser = nil
    portal.currentAccount = nil
    menuFrame:setVisible(false)
    homeFrame:setVisible(true)
    currentScreen = "home"
end)

-- Card reader thread
local function cardReaderThread()
    while true do
        local success, err = pcall(function()
            local event, info = os.pullEvent("card_read")
            
            if event == "card_read" and info and info.data then
                if currentScreen == "create" then
                    -- Register card for new account
                    createCardUUID = info.data
                    createCardLabel:setText("Card: " .. info.data:sub(1, 16) .. "..."):setForeground(colorSuccess)
                    cardReader.beep(1200)
                    
                elseif currentScreen == "add_card" then
                    -- Add card to current account
                    addCardStatusLabel:setText("Adding card..."):setForeground(colors.yellow)
                    basalt.update()
                    
                    local success, err = portal.addCard(portal.currentAccount.accountId, info.data)
                    if success then
                        addCardStatusLabel:setText("Card added!"):setForeground(colorSuccess)
                        cardReader.beep(1500)
                        sleep(2)
                        
                        -- Refresh account info
                        local _, account = portal.getAccountInfo(portal.currentAccount.accountId)
                        if account then
                            portal.currentAccount = account
                            menuCardsLabel:setText("Cards: " .. #account.cardUUIDs)
                        end
                        
                        addCardFrame:setVisible(false)
                        menuFrame:setVisible(true)
                        currentScreen = "menu"
                    else
                        addCardStatusLabel:setText("Error: " .. tostring(err)):setForeground(colorError)
                        cardReader.beep(500)
                    end
                    
                elseif currentScreen == "remove_card" then
                    -- Remove card from current account
                    removeCardStatusLabel:setText("Removing card..."):setForeground(colors.yellow)
                    basalt.update()
                    
                    local success, err = portal.removeCard(portal.currentAccount.accountId, info.data)
                    if success then
                        removeCardStatusLabel:setText("Card removed!"):setForeground(colorSuccess)
                        cardReader.beep(1500)
                        sleep(2)
                        
                        -- Refresh account info
                        local _, account = portal.getAccountInfo(portal.currentAccount.accountId)
                        if account then
                            portal.currentAccount = account
                            menuCardsLabel:setText("Cards: " .. #account.cardUUIDs)
                        end
                        
                        removeCardFrame:setVisible(false)
                        menuFrame:setVisible(true)
                        currentScreen = "menu"
                    else
                        removeCardStatusLabel:setText("Error: " .. tostring(err)):setForeground(colorError)
                        cardReader.beep(500)
                    end
                end
            end
        end)
        
        if not success then
            print("Card reader error: " .. tostring(err))
        end
    end
end

-- Start threads
parallel.waitForAll(
    function()
        basalt.run()
    end,
    cardReaderThread
)
