-- Encryption/Decryption Gateway
-- Interfaces between wireless modems (external) and wired modems (internal servers)
-- Encrypts outgoing messages, decrypts incoming messages
-- Verifies signatures from deposit machines
-- MULTI-THREADED: Handles concurrent requests

local ecc = require("ecc")

local gateway = {}
openTempChannels = {}

-- Modems
gateway.wiredModem = nil
gateway.wirelessModem = nil

-- Gateway's own keypair for encryption
gateway.privateKey = nil
gateway.publicKey = nil

-- Channels
gateway.wirelessChannel = 1000 -- External channel for wireless clients
gateway.wiredChannel = 105 -- Gateway's internal wired channel
gateway.balanceManagerChannel = 101 -- Balance manager's channel
gateway.ledgerChannel = 100 -- Ledger Channel
gateway.keyGenChannel = 102 -- This is where we do keygen

-- Machine registry (machineId -> publicKey)
gateway.depositMachines = {} 

-- Initialize
function gateway.init()
    -- Load or generate gateway keypair
    if fs.exists("gateway_keys.dat") then
        local file = fs.open("gateway_keys.dat", "r")
        if file then
            local data = textutils.unserialize(file.readAll())
            file.close()
            gateway.privateKey = data.privateKey
            gateway.publicKey = data.publicKey
            print("Loaded gateway keypair")
        end
    end
    
    if not gateway.privateKey then
        print("Generating new gateway keypair...")
        gateway.privateKey, gateway.publicKey = ecc.keypair()
        
        -- Save keypair
        local file = fs.open("gateway_keys.dat", "w")
        if file then
            file.write(textutils.serialize({
                privateKey = gateway.privateKey,
                publicKey = gateway.publicKey
            }))
            file.close()
            print("Gateway keypair saved")
        end
    end
    
    -- Find wired modem
    gateway.wiredModem = peripheral.find("modem", function(name, modem)
        return modem.isWireless() == false
    end)
    
    -- Find wireless modem
    gateway.wirelessModem = peripheral.find("modem", function(name, modem)
        return modem.isWireless() == true
    end)
    
    if not gateway.wiredModem then
        error("No wired modem found!")
    end
    
    if not gateway.wirelessModem then
        error("No wireless modem found!")
    end
    
    gateway.wiredModem.open(gateway.wiredChannel)
    gateway.wirelessModem.open(gateway.wirelessChannel)
    
    print("Gateway initialized")
    print("Wireless channel: " .. gateway.wirelessChannel)
    print("Wired channel: " .. gateway.wiredChannel)
    print("Balance Manager channel: " .. gateway.balanceManagerChannel)
end

-- Register a machine
function gateway.registerDepositMachine(machineId, publicKey)
    gateway.depositMachines[machineId] = publicKey
    print("Registered machine: " .. machineId)
end

-- Verify deposit machine signature
function gateway.verifyDepositSignature(machineId, message, signature)
    local publicKey = gateway.depositMachines[machineId]
    if not publicKey then
        return false, "Machine not registered"
    end
    
    local isValid = ecc.verify(publicKey, message, signature)
    
    return isValid, isValid and nil or "Invalid signature"
end

-- Encrypt message for wireless transmission (outgoing to clients)
function gateway.encryptMessage(message, machineId)
    -- If machineId is provided, we encrypt specifically for that machine using ECDH
    if machineId then
        local machinePublicKey = gateway.depositMachines[machineId]
        if machinePublicKey then
            -- Derive shared secret
            local sharedSecret = ecc.exchange(gateway.privateKey, machinePublicKey)
            local serializedData = textutils.serialize(message)
            -- Encrypt data
            local encryptedData = ecc.encrypt(serializedData, sharedSecret)
            
            local packet = {
                encryptedData = encryptedData,
                timestamp = os.epoch("utc")
            }
            return textutils.serialize(packet)
        else
            print("WARNING: No public key found for " .. tostring(machineId) .. ", falling back to signing")
        end
    end

    -- Fallback: Sign with gateway's private key for authenticity (no encryption)
    local packet = {
        data = message,
        timestamp = os.epoch("utc")
    }
    
    local signature = ecc.sign(gateway.privateKey, textutils.serialize(packet))
    packet.signature = signature
    
    return textutils.serialize(packet)
end

-- Decrypt incoming wireless message (from clients)
function gateway.decryptMessage(encryptedMessage)
    local packet = textutils.unserialize(encryptedMessage)
    
    if not packet or not packet.encryptedData or not packet.machineId then
        return nil, "Invalid packet format"
    end
    
    -- Verify timestamp (prevent replay attacks)
    if packet.timestamp then
        local age = os.epoch("utc") - packet.timestamp
        if age > 60000 then -- 60 seconds
            return nil, "Packet too old"
        end
    end
    
    -- Get the machine's public key
    local machinePublicKey = gateway.depositMachines[packet.machineId]
    if not machinePublicKey then
        return nil, "Machine not registered: " .. packet.machineId
    end
    
    -- Derive shared secret using gateway's private key and machine's public key
    local sharedSecret = ecc.exchange(gateway.privateKey, machinePublicKey)
    
    -- Decrypt with shared secret
    local success, decrypted = pcall(ecc.decrypt, packet.encryptedData, sharedSecret)
    if not success then
        return nil, "Decryption failed"
    end
    
    -- Parse decrypted data
    local data = textutils.unserialize(tostring(decrypted))
    if not data then
        return nil, "Invalid decrypted data format"
    end
    
    -- Return data AND machineId so we know who to reply to
    return data, nil, packet.machineId
end

-- Send wireless response
function gateway.sendWireless(channel, data, machineId)
    local encrypted = gateway.encryptMessage(data, machineId)
    gateway.wirelessModem.transmit(channel, gateway.wirelessChannel, encrypted)
end

function gateway.sendWired(channel, data)
    gateway.wiredModem.transmit(channel, gateway.wiredChannel, textutils.serialize(data))
end

-- Helper: Send request to balance manager using ephemeral channel for concurrency
-- This ensures that responses go to the correct thread
function gateway.sendToKeyServer(request)
    local tempChannel = math.random(20000, 65000)
    -- Ensure channel is not one of our main ones
    while tempChannel == gateway.wiredChannel or tempChannel == gateway.wirelessChannel or openTempChannels[tempChannel]==1 do
        tempChannel = math.random(20000, 65000)
    end
    openTempChannels[tempChannel]=1
    
    print("DEBUG [Gateway]: Opening temp channel " .. tempChannel .. " for request " .. request.action)
    gateway.wiredModem.open(tempChannel)
    
    -- Verify channel is open
    if not gateway.wiredModem.isOpen(tempChannel) then
        print("ERROR [Gateway]: Failed to open temp channel " .. tempChannel)
    end
    
    gateway.wiredModem.transmit(
        gateway.keyGenChannel,
        tempChannel,
        textutils.serialize(request)
    )
    
    local timer = os.startTimer(30)
    local response = nil
    
    print("DEBUG [Gateway]: Waiting for response on " .. tempChannel)
    
    while true do
        local event, side, channel, replyChannel, message = os.pullEvent()
        
        if event == "modem_message" then
            print("DEBUG [Gateway]: Thread saw message on " .. tostring(channel))
            if channel == tempChannel then
                print("DEBUG [Gateway]: Received response on temp channel " .. tempChannel)
                response = textutils.unserialize(message)
                break
            end
        elseif event == "timer" and side == timer then
            print("DEBUG [Gateway]: Timeout waiting for response on " .. tempChannel)
            break -- Timeout, response remains nil
        end
        print(event)
    end
    openTempChannels[tempChannel]=nil
    gateway.wiredModem.close(tempChannel)
    return response
end

function gateway.sendToBalanceManager(request)
    local tempChannel = math.random(20000, 65000)
    -- Ensure channel is not one of our main ones
    while tempChannel == gateway.wiredChannel or tempChannel == gateway.wirelessChannel or openTempChannels[tempChannel]==1 do
        tempChannel = math.random(20000, 65000)
    end
    openTempChannels[tempChannel]=1
    
    print("DEBUG [Gateway]: Opening temp channel " .. tempChannel .. " for request " .. request.action)
    gateway.wiredModem.open(tempChannel)
    
    -- Verify channel is open
    if not gateway.wiredModem.isOpen(tempChannel) then
        print("ERROR [Gateway]: Failed to open temp channel " .. tempChannel)
    end
    
    gateway.wiredModem.transmit(
        gateway.balanceManagerChannel,
        tempChannel,
        textutils.serialize(request)
    )
    
    local timer = os.startTimer(30)
    local response = nil
    
    print("DEBUG [Gateway]: Waiting for response on " .. tempChannel)
    
    while true do
        local event, side, channel, replyChannel, message = os.pullEvent()
        
        if event == "modem_message" then
            print("DEBUG [Gateway]: Thread saw message on " .. tostring(channel))
            if channel == tempChannel then
                print("DEBUG [Gateway]: Received response on temp channel " .. tempChannel)
                response = textutils.unserialize(message)
                break
            end
        elseif event == "timer" and side == timer then
            print("DEBUG [Gateway]: Timeout waiting for response on " .. tempChannel)
            break -- Timeout, response remains nil
        end
        print(event)
    end
    openTempChannels[tempChannel]=nil
    gateway.wiredModem.close(tempChannel)
    return response
end


-- Handle deposit request from wireless
function gateway.handleDepositRequest(data, replyChannel, machineId)
    -- Verify it's from a registered deposit machine
    if not data.depositMachineId or not data.signature then
        gateway.sendWireless(replyChannel, {
            success = false,
            error = "Missing machine ID or signature"
        }, machineId)
        return
    end
    
    -- Create message that was signed
    local signedMessage = data.accountId .. data.amount .. data.timestamp
    
    -- Verify signature
    local valid, err = gateway.verifyDepositSignature(
        data.depositMachineId,
        signedMessage,
        data.signature
    )
    
    if not valid then
        gateway.sendWireless(replyChannel, {
            success = false,
            error = "Signature verification failed: " .. (err or "unknown")
        }, machineId)
        print("Rejected deposit from " .. data.depositMachineId .. ": " .. (err or "unknown"))
        return
    end
    
    -- Forward to balance manager
    local request = {
        action = "DEPOSIT",
        accountId = data.accountId,
        amount = data.amount,
        depositMachineId = data.depositMachineId,
        signature = data.signature
    }
    
    local response = gateway.sendToBalanceManager(request)
    
    if response then
        gateway.sendWireless(replyChannel, response, machineId)
        if response.success then
            print(string.format("Deposit: %d to %s via %s", 
                data.amount, data.accountId, data.depositMachineId))
        end
    else
        gateway.sendWireless(replyChannel, {
            success = false,
            error = "Internal server timeout"
        }, machineId)
    end
end

-- Handle card payment request
function gateway.handleCardPayment(data, replyChannel, machineId)
    -- Get account by card UUID
    local getAccountReq = {
        action = "GET_ACCOUNT_BY_CARD",
        cardUUID = data.cardUUID
    }
    
    local accountResponse = gateway.sendToBalanceManager(getAccountReq)
    
    if not accountResponse or not accountResponse.success or not accountResponse.account then
        gateway.sendWireless(replyChannel, {
            success = false,
            error = "Card not registered"
        }, machineId)
        return
    end
    
    local accountId = accountResponse.account.accountId
    
    -- Charge the vendor
    local chargeReq = {
        action = "CHARGE_VENDOR",
        accountId = accountId,
        vendorId = data.vendorId,
        vendorType = data.vendorType or "GENERIC",
        amount = data.amount,
        metadata = data.metadata or {}
    }
    
    local chargeResponse = gateway.sendToBalanceManager(chargeReq)
    
    if chargeResponse then
        gateway.sendWireless(replyChannel, chargeResponse, machineId)
        if chargeResponse.success then
            print(string.format("Card payment: %d from card %s at %s", 
                data.amount, data.cardUUID:sub(1, 8), data.vendorId))
        end
    else
        gateway.sendWireless(replyChannel, {
            success = false,
            error = "Internal server timeout"
        }, machineId)
    end
end

-- Handle GET_ACCOUNT_BY_CARD request
function gateway.handleGetAccountByCard(data, replyChannel, machineId)
    if not data.cardUUID then
        gateway.sendWireless(replyChannel, { success = false, error = "Missing cardUUID" }, machineId)
        return
    end
    
    local request = { action = "GET_ACCOUNT_BY_CARD", cardUUID = data.cardUUID }
    local response = gateway.sendToBalanceManager(request)
    
    if response and response.success and response.account then
        gateway.sendWireless(replyChannel, {
            success = true,
            accountId = response.account.accountId
        }, machineId)
    else
        gateway.sendWireless(replyChannel, {
            success = false,
            error = response and response.error or "Card not registered"
        }, machineId)
    end
end

-- Handle UNICARD key request
function gateway.handleKeyReq(data, replyChannel, machineId)
    local request = { action = "GET_UNICARD_KEY" }
    local response = gateway.sendToKeyServer(request)
    
    if response and response.success and response.publicKey then
        gateway.sendWireless(replyChannel, response, machineId)
    else
        gateway.sendWireless(replyChannel, {
            success = false,
            error = response and response.error or "Error retrieving key"
        }, machineId)
    end
end

-- Handle CREATE_ACCOUNT request
function gateway.handleCreateAccount(data, replyChannel, machineId)
    print("DEBUG [Gateway]: handleCreateAccount called")
    
    if not data.username or not data.password then
        gateway.sendWireless(replyChannel, { success = false, error = "Missing username or password" }, machineId)
        return
    end
    
    -- Hash the password server-side
    local ecc = require("ecc")
    local passwordHash = ecc.sha256.digest(data.password):toHex()
    
    local request = {
        action = "CREATE_ACCOUNT",
        username = data.username,
        passwordHash = passwordHash,
        publicKey = nil,
        initialBalance = 0,
        cardUUIDs = {}
    }
    
    local response = gateway.sendToBalanceManager(request)
    
    if response then
        gateway.sendWireless(replyChannel, response, machineId)
    else
        gateway.sendWireless(replyChannel, { success = false, error = "Internal server timeout" }, machineId)
    end
end

-- Handle LOGIN request
function gateway.handleLogin(data, replyChannel, machineId)
    print("DEBUG [Gateway]: handleLogin called")
    
    if not data.username or not data.password then
        gateway.sendWireless(replyChannel, { success = false, error = "Missing username or password" }, machineId)
        return
    end
    
    local ecc = require("ecc")
    local passwordHash = ecc.sha256.digest(data.password):toHex()
    
    local request = {
        action = "LOGIN",
        username = data.username,
        passwordHash = passwordHash
    }
    
    local response = gateway.sendToBalanceManager(request)
    
    if response then
        gateway.sendWireless(replyChannel, response, machineId)
    else
        gateway.sendWireless(replyChannel, { success = false, error = "Internal server timeout" }, machineId)
    end
end

-- Handle GET_ACCOUNT_BY_USERNAME request
function gateway.handleGetAccountByUsername(data, replyChannel, machineId)
    if not data.username then
        gateway.sendWireless(replyChannel, { success = false, error = "Missing username" }, machineId)
        return
    end
    
    local request = { action = "GET_ACCOUNT_BY_USERNAME", username = data.username }
    local response = gateway.sendToBalanceManager(request)
    
    if response then
        gateway.sendWireless(replyChannel, response, machineId)
    else
        gateway.sendWireless(replyChannel, { success = false, error = "Internal server timeout" }, machineId)
    end
end

-- Handle ADD_CARD request
function gateway.handleAddCard(data, replyChannel, machineId)
    if not data.accountId or not data.cardUUID then
        gateway.sendWireless(replyChannel, { success = false, error = "Missing accountId or cardUUID" }, machineId)
        return
    end
    
    local request = { action = "ADD_CARD", accountId = data.accountId, cardUUID = data.cardUUID, name = data.name }
    local response = gateway.sendToBalanceManager(request)
    
    if response then
        gateway.sendWireless(replyChannel, response, machineId)
    else
        gateway.sendWireless(replyChannel, { success = false, error = "Internal server timeout" }, machineId)
    end
end

-- Handle REMOVE_CARD request
function gateway.handleRemoveCard(data, replyChannel, machineId)
    if not data.accountId or not data.cardUUID then
        gateway.sendWireless(replyChannel, { success = false, error = "Missing accountId or cardUUID" }, machineId)
        return
    end
    
    local request = { action = "REMOVE_CARD", accountId = data.accountId, cardUUID = data.cardUUID }
    local response = gateway.sendToBalanceManager(request)
    
    if response then
        gateway.sendWireless(replyChannel, response, machineId)
    else
        gateway.sendWireless(replyChannel, { success = false, error = "Internal server timeout" }, machineId)
    end
end

-- Handle GET_ACCOUNT request
function gateway.handleGetAccount(data, replyChannel, machineId)
    if not data.accountId then
        gateway.sendWireless(replyChannel, { success = false, error = "Missing accountId" }, machineId)
        return
    end
    
    local request = { action = "GET_ACCOUNT", accountId = data.accountId }
    local response = gateway.sendToBalanceManager(request)
    
    if response then
        gateway.sendWireless(replyChannel, response, machineId)
    else
        gateway.sendWireless(replyChannel, { success = false, error = "Internal server timeout" }, machineId)
    end
end


-- Handle wired message (from internal servers)
function gateway.handleWiredMessage(message, replyChannel)
    local data = textutils.unserialize(message)
    
    if not data then return end
    
    -- Route based on request type
    if data.requestType == "REGISTER_MACHINE" then
        gateway.handleMachineRegistration(data, replyChannel)
    elseif data.requestType == "GET_PUBLIC_KEY" then
        -- Return the gateway's public key for encryption
        gateway.sendWired(replyChannel, {
            success = true,
            publicKey = gateway.publicKey
        })
    end
end

-- Handle machine registration (from wired network - server manager)
function gateway.handleMachineRegistration(data, replyChannel)
    print("DEBUG: handleMachineRegistration called")
    
    if not data.machineId or not data.publicKey then
        gateway.wiredModem.transmit(replyChannel, gateway.wiredChannel, textutils.serialize({
            success = false,
            error = "Missing machineId or publicKey"
        }))
        return
    end
    
    -- Add to registered machines
    gateway.depositMachines[data.machineId] = data.publicKey
    
    -- Save to disk
    gateway.save()
    
    print("Registered machine: " .. data.machineId)
    
    -- Send success response
    local response = {
        success = true,
        machineId = data.machineId
    }
    gateway.wiredModem.transmit(replyChannel, gateway.wiredChannel, textutils.serialize(response))
end

-- Handle wireless message
function gateway.handleWirelessMessage(message, replyChannel)
    print("DEBUG [Gateway]: Received wireless message on reply channel " .. replyChannel)
    
    -- Decrypt and get machineId
    local data, err, machineId = gateway.decryptMessage(message)
    
    if not data then
        print("DEBUG [Gateway]: Decryption failed: " .. tostring(err))
        gateway.sendWireless(replyChannel, { success = false, error = err or "Decryption failed" }, nil)
        return
    end
    
    print("DEBUG [Gateway]: Request type: " .. tostring(data.requestType) .. " from " .. tostring(machineId))
    
    -- Route based on request type
    if data.requestType == "DEPOSIT" then
        gateway.handleDepositRequest(data, replyChannel, machineId)
    elseif data.requestType == "CARD_PAYMENT" then
        gateway.handleCardPayment(data, replyChannel, machineId)
    elseif data.requestType == "GET_ACCOUNT_BY_CARD" then
        gateway.handleGetAccountByCard(data, replyChannel, machineId)
    elseif data.requestType == "CREATE_ACCOUNT" then
        gateway.handleCreateAccount(data, replyChannel, machineId)
    elseif data.requestType == "GET_ACCOUNT_BY_USERNAME" then
        gateway.handleGetAccountByUsername(data, replyChannel, machineId)
    elseif data.requestType == "ADD_CARD" then
        gateway.handleAddCard(data, replyChannel, machineId)
    elseif data.requestType == "REMOVE_CARD" then
        gateway.handleRemoveCard(data, replyChannel, machineId)
    elseif data.requestType == "GET_ACCOUNT" then
        gateway.handleGetAccount(data, replyChannel, machineId)
    elseif data.requestType == "LOGIN" then
        gateway.handleLogin(data, replyChannel, machineId)
    elseif data.requestType == "GET_UNICARD_KEY" then
        gateway.handleKeyReq(data, replyChannel, machineId)
    else
        print("DEBUG [Gateway]: Unknown request type")
        gateway.sendWireless(replyChannel, { success = false, error = "Unknown request type" }, machineId)
    end
end

-- Load machine registry
function gateway.load(filename)
    filename = filename or "gateway.dat"
    if not fs.exists(filename) then return false end
    local file = fs.open(filename, "r")
    if not file then return false end
    local data = textutils.unserialize(file.readAll())
    file.close()
    if data then
        gateway.depositMachines = data.depositMachines or {}
        print("Loaded machines")
        return true
    end
    return false
end

-- Save machine registry
function gateway.save(filename)
    filename = filename or "gateway.dat"
    local file = fs.open(filename, "w")
    if not file then return false end
    file.write(textutils.serialize({ depositMachines = gateway.depositMachines }))
    file.close()
    return true
end

-- Main loop with threading
function gateway.run()
    print("Gateway running...")
    gateway.load()
    
    local lastSave = os.epoch("utc")
    local routines = {} -- Coroutine -> filter
    
    while true do
        local eventData = {os.pullEventRaw()}
        local event = eventData[1]
        
        if event == "terminate" then
            print("Terminating gateway...")
            break
        end
        
        -- 1. Spawn new threads for incoming messages
        if event == "modem_message" then
            local side, channel, replyChannel, message = eventData[2], eventData[3], eventData[4], eventData[5]
            
            local co = nil
            
            -- Wireless (External)
            if side == peripheral.getName(gateway.wirelessModem) and channel == gateway.wirelessChannel then
                co = coroutine.create(function()
                    gateway.handleWirelessMessage(message, replyChannel)
                end)
            
            -- Wired (Internal - Server Manager)
            elseif side == peripheral.getName(gateway.wiredModem) and channel == gateway.wiredChannel then
                co = coroutine.create(function()
                    gateway.handleWiredMessage(message, replyChannel)
                end)
            end
            
            if co then
                -- Start the thread
                local ok, result = coroutine.resume(co)
                if ok then
                    if coroutine.status(co) ~= "dead" then
                        -- FIX: If result is nil (no filter), use a placeholder so the key isn't deleted
                        routines[co] = result or "ALL"
                    end
                else
                    print("Error starting thread: " .. tostring(result))
                end
            end
        end
        
        -- 2. Resume existing threads
        local dead = {}
        for co, filter in pairs(routines) do
            -- FIX: Check for placeholder "ALL"
            if filter == "ALL" or filter == nil or filter == event then
                local ok, result = coroutine.resume(co, table.unpack(eventData))
                if not ok then
                    print("Thread error: " .. tostring(result))
                    dead[co] = true
                elseif coroutine.status(co) == "dead" then
                    dead[co] = true
                else
                    -- FIX: If result is nil (no filter), use a placeholder
                    routines[co] = result or "ALL"
                end
            end
        end
        
        for co in pairs(dead) do routines[co] = nil end
        
        -- Auto-save
        if os.epoch("utc") - lastSave > 300000 then
            gateway.save()
            lastSave = os.epoch("utc")
        end
    end
end

gateway.init()
gateway.run()

return gateway