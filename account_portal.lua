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

local debugMonitor = peripheral.find("monitor")
if debugMonitor then
    debugMonitor.setTextScale(0.5)
    debugMonitor.clear()
    debugMonitor.setCursorPos(1,1)
    debugMonitor.write("Debug Monitor Active")
    local _, h = debugMonitor.getSize()
    debugMonitor.setCursorPos(1, 2)
end

function portal.log(text)
    if not debugMonitor then return end
    local w, h = debugMonitor.getSize()
    local x, y = debugMonitor.getCursorPos()
    
    debugMonitor.write(tostring(text))
    
    if y >= h then
        debugMonitor.scroll(1)
        debugMonitor.setCursorPos(1, h)
    else
        debugMonitor.setCursorPos(1, y + 1)
    end
end

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
            local packet = textutils.unserialize(p4)
            
            -- Handle encrypted packet from gateway
            if packet and type(packet) == "table" and packet.encryptedData then
                -- Decrypt using shared secret
                local success, decrypted = pcall(ecc.decrypt, packet.encryptedData, portal.sharedSecret)
                if success then
                    local responseStr = decrypted
                    
                    -- FIX: If decrypt returns a byte array (table), convert it to a string first
                    if type(decrypted) == "table" then
                        local chars = {}
                        for i = 1, #decrypted do
                            chars[i] = string.char(decrypted[i])
                        end
                        responseStr = table.concat(chars)
                    end
                    
                    portal.log("Decrypted: " .. tostring(responseStr))
                    
                    -- Now unserialize the string into a Lua table
                    local response = textutils.unserialize(responseStr)
                    
                    if type(response) == "table" then
                        return response
                    else
                        portal.log("Error: Unserialized data is not a table")
                        return nil, "Invalid response format"
                    end
                else
                    return nil, "Decryption failed"
                end
            end
            
            -- Fallback for unencrypted messages
            return packet
        elseif event == "timer" and p1 == timer then
            portal.waitingForResponse = false
            return nil, "Timeout"
        end
    end
end

-- Create account
function portal.createAccount(username, password)
    local timestamp = os.epoch("utc")
    
    portal.sendRequest({
        data = {
            requestType = "CREATE_ACCOUNT",
            username = username,
            password = password,  -- Send plain password (encrypted in transit)
            portalId = portal.config.machineId,
            timestamp = timestamp
        },
        timestamp = timestamp
    })
    
    local response, err = portal.waitForResponse(30)
    if response and response.success and response.accountId then
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
            requestType = "LOGIN",
            username = username,
            password = password,  -- Send plain password (encrypted in transit)
            timestamp = timestamp
        },
        timestamp = timestamp
    })
    
    local response, err = portal.waitForResponse(10)
    if response and response.success and response.account then
        return true, response.account
    else
        return false, response and response.error or err or "Login failed"
    end
end

-- Add card to account
function portal.addCard(accountId, cardUUID, nickname)
    local timestamp = os.epoch("utc")
    
    portal.sendRequest({
        data = {
            requestType = "ADD_CARD",
            accountId = accountId,
            cardUUID = cardUUID,
            nickname = nickname,
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

local function generateUUID()
    local template = 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'
    return string.gsub(template, '[xy]', function(c)
        local v = (c == 'x') and math.random(0, 0xf) or math.random(8, 0xb)
        return string.format('%x', v)
    end)
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

local main = basalt.createFrame()
    :initializeState("currentScreen", "home")
    :initializeState("createUsername", "")
    :initializeState("createPassword", "")
    :initializeState("loginUsername", "")
    :initializeState("loginPassword", "")
    :initializeState("currentUser", nil)
    :initializeState("currentAccount", nil)
    :initializeState("waitingForCardClick", nil)
    :initializeState("pendingCardUUID", nil)
    :initializeState("cardNickname", "")

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
    :bind("text", "createUsername")

createFrame:addLabel()
    :setText("Password:")
    :setPosition(2, 7)
    :setForeground(colorText)

local createPasswordInput = createFrame:addInput({replaceChar="*"})
    :setPosition(2, 8)
    :setSize(20, 1)
    :setBackground(colors.black)
    :setForeground(colors.white)
    :bind("text", "createPassword")

local createConfirmBtn = createFrame:addButton()
    :setText("Create")
    :setPosition(2, 10)
    :setSize(10, 3)
    :setBackground(colorSuccess)
    :setForeground(colors.white)

local createCancelBtn = createFrame:addButton()
    :setText("Cancel")
    :setPosition(13, 10)
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
    :bind("text", "loginUsername")

loginFrame:addLabel()
    :setText("Password:")
    :setPosition(2, 7)
    :setForeground(colorText)

local loginPasswordInput = loginFrame:addInput({replaceChar="*"})
    :setPosition(2, 8)
    :setSize(20, 1)
    :setBackground(colors.black)
    :setForeground(colors.white)
    :bind("text", "loginPassword")

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
    :setText("Card Nickname:")
    :setPosition(2, 4)
    :setForeground(colorText)

local addCardNicknameInput = addCardFrame:addInput()
    :setPosition(2, 5)
    :setSize(20, 1)
    :setBackground(colors.black)
    :setForeground(colors.white)
    :bind("text", "cardNickname")

local addCardStep2Label = addCardFrame:addLabel()
    :setText("Then swipe card to add:")
    :setPosition(2, 7)
    :setForeground(colorText)

local addCardStatusLabel = addCardFrame:addLabel()
    :setText("Waiting for input...")
    :setPosition(2, 9)
    :setForeground(colors.yellow)

local addCardStartBtn = addCardFrame:addButton()
    :setText("Start Write")
    :setPosition(2, 11)
    :setSize(12, 3)
    :setBackground(colorPrimary)
    :setForeground(colors.white)

local addCardCancelBtn = addCardFrame:addButton()
    :setText("Cancel")
    :setPosition(15, 11)
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
    :setText("Select card to remove:")
    :setPosition(2, 4)
    :setForeground(colorText)

local cardList = removeCardFrame:addList()
    :setPosition(2, 5)
    :setSize(termWidth - 4, termHeight - 8)
    :setBackground(colors.black)
    :setForeground(colors.white)
    :setSelectionColor(colors.blue, colors.white)

local removeCardStatusLabel = removeCardFrame:addLabel()
    :setText("")
    :setPosition(2, termHeight - 2)
    :setForeground(colors.yellow)

local removeCardBackBtn = removeCardFrame:addButton()
    :setText("Back")
    :setPosition(termWidth - 8, 2)
    :setSize(6, 1)
    :setBackground(colorError)
    :setForeground(colors.white)

-- Go to create account screen
createAccountBtn:onClick(function()
    main:setState("createUsername", "")
    main:setState("createPassword", "")
    createStatusLabel:setText("")
    homeFrame:setVisible(false)
    createFrame:setVisible(true)
    main:setState("currentScreen", "create")
end)

-- Go to login screen
loginBtn:onClick(function()
    main:setState("loginUsername", "")
    main:setState("loginPassword", "")
    loginStatusLabel:setText("")
    homeFrame:setVisible(false)
    loginFrame:setVisible(true)
    main:setState("currentScreen", "login")
end)

-- Create account confirm
createConfirmBtn:onClick(function()
    local username = main:getState("createUsername")
    local password = main:getState("createPassword")
    
    if username == "" or password == "" then
        createStatusLabel:setText("Username and password required"):setForeground(colorError)
        return
    end
    
    createStatusLabel:setText("Creating account..."):setForeground(colors.yellow)
    
    -- Schedule the network operation to run after UI updates
    basalt.schedule(function()
        local success, result = portal.createAccount(username, password)
        if success then
            createStatusLabel:setText("Account created! You can now login."):setForeground(colorSuccess)
            os.sleep(2)
            createFrame:setVisible(false)
            homeFrame:setVisible(true)
            main:setState("currentScreen", "home")
        else
            createStatusLabel:setText("Error: " .. tostring(result)):setForeground(colorError)
        end
    end)
end)

-- Create account cancel
createCancelBtn:onClick(function()
    createFrame:setVisible(false)
    homeFrame:setVisible(true)
    main:setState("currentScreen", "home")
end)

-- Login confirm
loginConfirmBtn:onClick(function()
    local username = main:getState("loginUsername")
    local password = main:getState("loginPassword")
    
    if username == "" or password == "" then
        loginStatusLabel:setText("Username and password required"):setForeground(colorError)
        return
    end
    
    loginStatusLabel:setText("Logging in..."):setForeground(colors.yellow)
    
    -- Schedule the network operation to run after UI updates
    basalt.schedule(function()
        local success, account = portal.login(username, password)
        if success then
            main:setState("currentUser", username)
            main:setState("currentAccount", account)
            
            -- Update menu
            menuUsernameLabel:setText("User: " .. username)
            menuBalanceLabel:setText("Balance: " .. account.balance)
            menuCardsLabel:setText("Cards: " .. #account.cardUUIDs)
            
            loginFrame:setVisible(false)
            menuFrame:setVisible(true)
            main:setState("currentScreen", "menu")
        else
            loginStatusLabel:setText("Error: " .. tostring(account)):setForeground(colorError)
        end
    end)
end)

-- Login cancel
loginCancelBtn:onClick(function()
    loginFrame:setVisible(false)
    homeFrame:setVisible(true)
    main:setState("currentScreen", "home")
end)

addCardBtn:onClick(function()
    main:setState("cardNickname", "")
    addCardStatusLabel:setText("Enter nickname & click Start"):setForeground(colors.yellow)
    addCardStartBtn:show()
    menuFrame:setVisible(false)
    addCardFrame:setVisible(true)
    main:setState("currentScreen", "add_card_setup")
end)

-- Start card write process
addCardStartBtn:onClick(function()
    local nickname = main:getState("cardNickname")
    if nickname == "" then
        addCardStatusLabel:setText("Nickname required!"):setForeground(colorError)
        return
    end

    addCardStartBtn:hide()
    addCardStatusLabel:setText("Preparing card..."):setForeground(colors.yellow)
    main:setState("currentScreen", "add_card_wait")
    
    -- Generate new UUID and write to card reader immediately
    local newUUID = generateUUID()
    local currentUser = main:getState("currentUser")
    
    portal.log("Generated UUID: " .. newUUID)
    portal.log("Writing to card reader...")
    
    -- Write nickname to card for user convenience
    cardReader.write(newUUID, nickname)
    
    portal.log("Card reader ready")
    addCardStatusLabel:setText("Tap card to add..."):setForeground(colors.yellow)
    
    -- Store the UUID for when the card is tapped
    main:setState("pendingCardUUID", newUUID)
end)

-- Go to remove card screen
removeCardBtn:onClick(function()
    removeCardStatusLabel:setText("Loading cards..."):setForeground(colors.yellow)
    menuFrame:setVisible(false)
    removeCardFrame:setVisible(true)
    main:setState("currentScreen", "remove_card")
    
    cardList:clear()
    local account = main:getState("currentAccount")
    
    -- Assuming account.cards is a list of objects {uuid, nickname}
    -- If legacy data (just UUID strings), handle gracefully
    if account.cards then
        for _, card in pairs(account.cards) do
            local label = (card.nickname or "Unknown") .. " (" .. string.sub(card.uuid, 1, 8) .. "...)"
            cardList:addItem(label, nil, card.uuid)
        end
    elseif account.cardUUIDs then
        -- Legacy support
        for _, uuid in pairs(account.cardUUIDs) do
            cardList:addItem("Card (" .. string.sub(uuid, 1, 8) .. "...)")
        end
    end
    removeCardStatusLabel:setText("")
end)

-- Handle card list selection for removal
cardList:onChange(function(self, item)
    if not item then return end
    local uuidToRemove = item.args[1] -- We stored UUID in args
    if not uuidToRemove then return end -- Legacy list item might not have args set up right if not careful

    removeCardStatusLabel:setText("Removing..."):setForeground(colors.yellow)
    
    basalt.schedule(function()
        local currentAccount = main:getState("currentAccount")
        local success, err = portal.removeCard(currentAccount.accountId, uuidToRemove)
        
        if success then
            removeCardStatusLabel:setText("Card removed!"):setForeground(colorSuccess)
            os.sleep(1)
            
            -- Refresh account info
            local _, account = portal.getAccountInfo(currentAccount.accountId)
            if account then
                main:setState("currentAccount", account)
                -- Refresh list
                cardList:clear()
                if account.cards then
                    for _, card in pairs(account.cards) do
                        local label = (card.nickname or "Unknown") .. " (" .. string.sub(card.uuid, 1, 8) .. "...)"
                        cardList:addItem(label, nil, card.uuid)
                    end
                end
            end
        else
            removeCardStatusLabel:setText("Error: " .. tostring(err)):setForeground(colorError)
        end
    end)
end)

-- Add card cancel
addCardCancelBtn:onClick(function()
    addCardFrame:setVisible(false)
    menuFrame:setVisible(true)
    main:setState("currentScreen", "menu")
end)

-- Remove card back
removeCardBackBtn:onClick(function()
    removeCardFrame:setVisible(false)
    menuFrame:setVisible(true)
    main:setState("currentScreen", "menu")
end)

-- Logout
menuLogoutBtn:onClick(function()
    main:setState("currentUser", nil)
    main:setState("currentAccount", nil)
    menuFrame:setVisible(false)
    homeFrame:setVisible(true)
    main:setState("currentScreen", "home")
end)


basalt.onEvent("card_read", function(info)
    if info and info.data then
        local screen = main:getState("currentScreen")
        
        if screen == "add_card_wait" then
            -- Card was tapped, now add it to the account
            local newUUID = main:getState("pendingCardUUID")
            local nickname = main:getState("cardNickname")
            local currentAccount = main:getState("currentAccount")
            
            portal.log("Card tapped with UUID: " .. tostring(info.data))
            
            if newUUID then
                addCardStatusLabel:setText("Adding card..."):setForeground(colors.yellow)
                
                basalt.schedule(function()
                    local success, err = portal.addCard(currentAccount.accountId, newUUID, nickname)
                    if success then
                        addCardStatusLabel:setText("Card added!"):setForeground(colorSuccess)
                        cardReader.beep(1500)
                        
                        -- Refresh account info
                        local _, account = portal.getAccountInfo(currentAccount.accountId)
                        if account then
                            main:setState("currentAccount", account)
                            menuCardsLabel:setText("Cards: " .. (account.cards and #account.cards or #account.cardUUIDs))
                        end
                        
                        os.sleep(2)
                        main:setState("pendingCardUUID", nil)
                        addCardFrame:setVisible(false)
                        menuFrame:setVisible(true)
                        main:setState("currentScreen", "menu")
                    else
                        addCardStatusLabel:setText("Error: " .. tostring(err)):setForeground(colorError)
                        cardReader.beep(500)
                    end
                end)
            end
        end
    end
end)


-- Start Basalt (it will handle all events automatically)
basalt.run()