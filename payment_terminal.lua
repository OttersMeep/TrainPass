-- Payment Terminal for TrainPass Banking System
-- Processes card payments via magstripe cards

local terminal = {}

-- Configuration (will be overridden by machine_config.lua if it exists)
terminal.config = {
    machineID = "TERMINAL_001",
    vendorType = "TERMINAL",
    defaultAmount = 10,
    location = "Payment Terminal",
    gatewayChannel = 1000,
    responseChannel = nil 
}

-- Load configuration from machine_config.lua if it exists
if fs.exists("machine_config.lua") then
    local machineConfig = dofile("machine_config.lua")
    if machineConfig then
        terminal.config.machineID = machineConfig.machineID or terminal.config.machineID
        terminal.config.vendorType = machineConfig.vendorType or terminal.config.vendorType
        terminal.config.defaultAmount = machineConfig.defaultAmount or terminal.config.defaultAmount
        terminal.config.location = machineConfig.location or terminal.config.location
        terminal.config.gatewayChannel = machineConfig.gatewayChannel or terminal.config.gatewayChannel
        terminal.config.privateKey = machineConfig.privateKey or terminal.config.privateKey
        terminal.config.gatewayPublicKey = machineConfig.gatewayPublicKey or terminal.config.gatewayPublicKey
    else
        error("Wrongly Provisioned Terminal! Please Return To XXXXXXXXX")
end

-- Find wireless modem
local modem = peripheral.find("modem", function(name, modem)
    return modem.isWireless()
end)

if not modem then
    error("No wireless modem found! Payment terminal requires wireless modem.")
end

if not terminal.config.privateKey or type(terminal.config.privateKey) ~= "table" then
    error("Private key not configured or invalid!")
end

if not terminal.config.gatewayPublicKey or type(terminal.config.gatewayPublicKey) ~= "table" then
    error("Gateway public key not configured or invalid!")
end

print("Configuration loaded successfully")
print("Machine ID: " .. terminal.config.machineId)

-- Derive shared secret for encryption
terminal.sharedSecret = ecc.exchange(terminal.config.privateKey, terminal.config.gatewayPublicKey)
print("Shared secret derived")

local cardReader = peripheral.find("card_reader")
if not cardReader then
    error("No card reader found! terminal requires card reader to process payments")
end
print("Card reader detected: " .. peripheral.getName(cardReader))

-- Find wireless modem
local modem = peripheral.find("modem", function(name, modem)
    return modem.isWireless()
end)

if not modem then
    error("No wireless modem found! terminal requires wireless modem.")
end

-- Generate unique response channel
terminal.config.responseChannel = 3000 + math.random(1, 6999)
modem.open(terminal.config.responseChannel)

-- State
terminal.currentUser = nil
terminal.currentAccount = nil
terminal.waitingForResponse = false

-- Send request to gateway
function terminal.sendRequest(requestData)
    terminal.waitingForResponse = true
    
    -- Encrypt the request data with the shared secret
    local serializedData = textutils.serialize(requestData.data)
    local encryptedData = ecc.encrypt(serializedData, terminal.sharedSecret)
    
    -- Send encrypted packet with machine ID
    modem.transmit(
        terminal.config.gatewayChannel,
        terminal.config.responseChannel,
        textutils.serialize({
            machineId = terminal.config.machineId,
            encryptedData = encryptedData,
            timestamp = requestData.timestamp
        })
    )
end

function terminal.waitForResponse(timeout)
    timeout = timeout or 10
    local timer = os.startTimer(timeout)
    
    while true do
        local event, p1, p2, p3, p4 = os.pullEvent()
        
        if event == "modem_message" and p2 == terminal.config.responseChannel then
            os.cancelTimer(timer)
            terminal.waitingForResponse = false
            local packet = textutils.unserialize(p4)
            
            -- Handle encrypted packet from gateway
            if packet and type(packet) == "table" and packet.encryptedData then
                -- Decrypt using shared secret
                local success, decrypted = pcall(ecc.decrypt, packet.encryptedData, terminal.sharedSecret)
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
                    
                    -- Now unserialize the string into a Lua table
                    local response = textutils.unserialize(responseStr)
                    
                    if type(response) == "table" then
                        return response
                    else
                        return nil, "Invalid response format"
                    end
                else
                    return nil, "Decryption failed"
                end
            end
            
            -- Fallback for unencrypted messages
            return packet
        elseif event == "timer" and p1 == timer then
            terminal.waitingForResponse = false
            return nil, "Timeout"
        end
    end
end

-- Generate unique response channel
terminal.config.responseChannel = 2000 + math.random(1, 8999)
modem.open(terminal.config.responseChannel)

print("=== TrainPass Payment Terminal ===")
print("Vendor ID: " .. terminal.config.machineID)
print("Type: " .. terminal.config.vendorType)
print("Location: " .. terminal.config.location)
print("Default Amount: " .. terminal.config.defaultAmount)
print("")

-- Process payment
function terminal.processPayment(cardUUID, amount)
    amount = amount or terminal.config.defaultAmount
    
    print("Processing payment...")
    print("Card: " .. cardUUID)
    print("Amount: " .. amount)
    
    -- Create payment packet
    local packet = {
        data = {
            requestType = "CARD_PAYMENT",
            cardUUID = cardUUID,
            machineID = terminal.config.machineID,
            vendorType = terminal.config.vendorType,
            amount = amount,
            metadata = {
                location = terminal.config.location,
                timestamp = os.epoch("utc")
            }
        },
        timestamp = os.epoch("utc")
    }
    -- Send to gateway
    terminal.sendRequest(packet)
    
    response = terminal.waitForResponse(30)
    if response and response.success then
        print("Payment Done")
        print("New Bal: " .. response.balance)
        return true, response.balance
    else
        print("DECLINED")
        print(response.error or "Unknown Error")
        return false, response.error

/*
    local timer = os.startTimer(5)
    while true do
        local event, p1, p2, p3, p4, p5 = os.pullEvent()
        
        if event == "modem_message" and p2 == terminal.config.responseChannel then
            os.cancelTimer(timer)
            local response = textutils.unserialize(p4)
            
            if response then
                if response.success then
                    print("SUCCESS!")
                    print("New balance: " .. response.balance)
                    return true, response.balance
                else
                    print("DECLINED: " .. (response.error or "Unknown error"))
                    return false, response.error
                end
            end
        elseif event == "timer" and p1 == timer then
            print("ERROR: Payment timeout")
            return false, "Timeout"
        end
    end
    */
end

-- Wait for card swipe (manual input for testing)
function terminal.waitForCardSwipe()
    print("")
    print("=== Ready for Payment ===")
    print("Enter card UUID (or 'q' to quit):")
    write("> ")
    local uuid = read()
    
    if uuid == "q" or uuid == "quit" or uuid == "" then
        return nil
    end
    
    return uuid
end

-- Get custom amount
function terminal.getAmount()
    write("Amount (default " .. terminal.config.defaultAmount .. "): ")
    local input = read()
    
    if input == "" then
        return terminal.config.defaultAmount
    end
    
    local amount = tonumber(input)
    if amount and amount > 0 then
        return amount
    else
        print("Invalid amount, using default")
        return terminal.config.defaultAmount
    end
end

-- Main loop
function terminal.run()
    print("Terminal ready. Waiting for card swipes...")
    print("")
    
    while true do
        local cardUUID = terminal.waitForCardSwipe()
        
        if not cardUUID then
            print("Shutting down...")
            break
        end
        
        local amount = terminal.getAmount()
        
        local success, result = terminal.processPayment(cardUUID, amount)
        
        if success then
            -- Success feedback
            term.setTextColor(colors.green)
            print("[S] Payment approved!")
            term.setTextColor(colors.white)
            sleep(2)
        else
            -- Failure feedback
            term.setTextColor(colors.red)
            print("[F] Payment failed")
            term.setTextColor(colors.white)
            sleep(2)
        end
    end
end

-- Start the terminal
terminal.run()
