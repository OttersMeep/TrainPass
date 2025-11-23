-- Encryption/Decryption Gateway
-- Interfaces between wireless modems (external) and wired modems (internal servers)
-- Encrypts outgoing messages, decrypts incoming messages
-- Verifies signatures from deposit machines

local ecc = require("ecc")

local gateway = {}

-- Modems
gateway.wiredModem = nil
gateway.wirelessModem = nil

-- Gateway's own keypair for encryption
gateway.privateKey = nil
gateway.publicKey = nil

-- Channels
gateway.wirelessChannel = 1000 -- External channel for wireless clients
gateway.wiredChannel = 105 -- Gateway's internal wired channel
gateway.balanceManagerChannel = 102 -- Balance manager's channel
gateway.ledgerChannel = 100

-- Deposit machine registry (machineId -> publicKey)
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

-- Register a deposit machine
function gateway.registerDepositMachine(machineId, publicKey)
    gateway.depositMachines[machineId] = publicKey
    print("Registered deposit machine: " .. machineId)
end

-- Verify deposit machine signature
function gateway.verifyDepositSignature(machineId, message, signature)
    local publicKey = gateway.depositMachines[machineId]
    if not publicKey then
        return false, "Deposit machine not registered"
    end
    
    local ecc = require("ecc")
    local isValid = ecc.verify(publicKey, message, signature)
    
    return isValid, isValid and nil or "Invalid signature"
end

-- Encrypt message for wireless transmission (outgoing to clients)
function gateway.encryptMessage(message)
    local packet = {
        data = message,
        timestamp = os.epoch("utc")
    }
    
    -- Sign with gateway's private key for authenticity
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
    
    return data, nil
end

-- Handle deposit request from wireless
function gateway.handleDepositRequest(data, replyChannel)
    -- Verify it's from a registered deposit machine
    if not data.depositMachineId or not data.signature then
        gateway.sendWireless(replyChannel, {
            success = false,
            error = "Missing machine ID or signature"
        })
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
        })
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
    
    gateway.wiredModem.transmit(
        gateway.balanceManagerChannel,
        gateway.wirelessChannel,
        textutils.serialize(request)
    )
    
    -- Wait for response from balance manager
    local timer = os.startTimer(10)
    while true do
        local event, side, channel, respChannel, message = os.pullEvent()
        
        if event == "modem_message" and channel == gateway.wirelessChannel then
            os.cancelTimer(timer)
            local response = textutils.unserialize(message)
            gateway.sendWireless(replyChannel, response)
            
            if response and response.success then
                print(string.format("Deposit: %d to %s via %s", 
                    data.amount, data.accountId, data.depositMachineId))
            end
            return
        elseif event == "timer" and side == timer then
            gateway.sendWireless(replyChannel, {
                success = false,
                error = "Internal server timeout"
            })
            return
        end
    end
end

-- Handle card payment request
function gateway.handleCardPayment(data, replyChannel)
    -- Get account by card UUID
    local getAccountReq = {
        action = "GET_ACCOUNT_BY_CARD",
        cardUUID = data.cardUUID
    }
    
    gateway.wiredModem.transmit(
        gateway.balanceManagerChannel,
        gateway.wirelessChannel,
        textutils.serialize(getAccountReq)
    )
    
    -- Wait for account info
    local timer = os.startTimer(5)
    local accountId = nil
    
    while true do
        local event, side, channel, respChannel, message = os.pullEvent()
        
        if event == "modem_message" and channel == gateway.wirelessChannel then
            os.cancelTimer(timer)
            local response = textutils.unserialize(message)
            
            if not response or not response.success or not response.account then
                gateway.sendWireless(replyChannel, {
                    success = false,
                    error = "Card not registered"
                })
                return
            end
            
            accountId = response.account.accountId
            break
        elseif event == "timer" and side == timer then
            gateway.sendWireless(replyChannel, {
                success = false,
                error = "Internal server timeout"
            })
            return
        end
    end
    
    -- Charge the vendor
    local chargeReq = {
        action = "CHARGE_VENDOR",
        accountId = accountId,
        vendorId = data.vendorId,
        vendorType = data.vendorType or "GENERIC",
        amount = data.amount,
        metadata = data.metadata or {}
    }
    
    gateway.wiredModem.transmit(
        gateway.balanceManagerChannel,
        gateway.wirelessChannel,
        textutils.serialize(chargeReq)
    )
    
    -- Wait for charge response
    timer = os.startTimer(5)
    while true do
        local event, side, channel, respChannel, message = os.pullEvent()
        
        if event == "modem_message" and channel == gateway.wirelessChannel then
            os.cancelTimer(timer)
            local response = textutils.unserialize(message)
            gateway.sendWireless(replyChannel, response)
            
            if response and response.success then
                print(string.format("Card payment: %d from card %s at %s", 
                    data.amount, data.cardUUID:sub(1, 8), data.vendorId))
            end
            return
        elseif event == "timer" and side == timer then
            gateway.sendWireless(replyChannel, {
                success = false,
                error = "Internal server timeout"
            })
            return
        end
    end
end

-- Send wireless response
function gateway.sendWireless(channel, data)
    local encrypted = gateway.encryptMessage(data, nil)
    gateway.wirelessModem.transmit(channel, gateway.wirelessChannel, encrypted)
end

function gateway.sendWired(channel, data)
    gateway.wiredModem.transmit(channel, gateway.wiredChannel, textutils.serialize(data))
end

-- Handle machine registration (from wired network - server manager)
function gateway.handleMachineRegistration(data, replyChannel)
    print("DEBUG: handleMachineRegistration called")
    print("  machineId: " .. tostring(data.machineId))
    print("  publicKey exists: " .. tostring(data.publicKey ~= nil))
    print("  replyChannel: " .. tostring(replyChannel))
    
    if not data.machineId or not data.publicKey then
        print("  ERROR: Missing data, sending failure")
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
    
    -- Send success response to the replyChannel (not balanceManagerChannel)
    local response = {
        success = true,
        machineId = data.machineId
    }
    print("  Sending response: " .. textutils.serialize(response))
    print("  To channel: " .. replyChannel)
    gateway.wiredModem.transmit(replyChannel, gateway.wiredChannel, textutils.serialize(response))
    print("  Response sent!")
end

-- Handle wireless message
function gateway.handleWirelessMessage(message, replyChannel)
    print("DEBUG [Gateway]: Received wireless message on reply channel " .. replyChannel)
    
    local data, err = gateway.decryptMessage(message)
    
    print("DEBUG [Gateway]: Decryption result - data: " .. tostring(data ~= nil) .. ", err: " .. tostring(err))
    
    if not data then
        print("DEBUG [Gateway]: Decryption failed, sending error response")
        gateway.sendWireless(replyChannel, {
            success = false,
            error = err or "Decryption failed"
        })
        return
    end
    
    print("DEBUG [Gateway]: Request type: " .. tostring(data.requestType))
    
    -- Route based on request type
    if data.requestType == "DEPOSIT" then
        gateway.handleDepositRequest(data, replyChannel)
    elseif data.requestType == "CARD_PAYMENT" then
        gateway.handleCardPayment(data, replyChannel)
    elseif data.requestType == "GET_ACCOUNT_BY_CARD" then
        gateway.handleGetAccountByCard(data, replyChannel)
    elseif data.requestType == "CREATE_ACCOUNT" then
        print("DEBUG [Gateway]: Routing to handleCreateAccount")
        gateway.handleCreateAccount(data, replyChannel)
    elseif data.requestType == "GET_ACCOUNT_BY_USERNAME" then
        gateway.handleGetAccountByUsername(data, replyChannel)
    elseif data.requestType == "ADD_CARD" then
        gateway.handleAddCard(data, replyChannel)
    elseif data.requestType == "REMOVE_CARD" then
        gateway.handleRemoveCard(data, replyChannel)
    elseif data.requestType == "GET_ACCOUNT" then
        gateway.handleGetAccount(data, replyChannel)
    else
        print("DEBUG [Gateway]: Unknown request type")
        gateway.sendWireless(replyChannel, {
            success = false,
            error = "Unknown request type"
        })
    end
end

-- Handle GET_ACCOUNT_BY_CARD request
function gateway.handleGetAccountByCard(data, replyChannel)
    print(textutils.serialize(data))
    if not data.cardUUID then
        gateway.sendWireless(replyChannel, {
            success = false,
            error = "Missing cardUUID"
        })
        return
    end
    
    -- Forward to balance manager
    local request = {
        action = "GET_ACCOUNT_BY_CARD",
        cardUUID = data.cardUUID
    }
    
    gateway.wiredModem.transmit(
        gateway.balanceManagerChannel,
        gateway.wirelessChannel,
        textutils.serialize(request)
    )
    
    -- Wait for response from balance manager
    local timer = os.startTimer(10)
    while true do
        local event, side, channel, respChannel, message = os.pullEvent()
        
        if event == "modem_message" and channel == gateway.wiredChannel then
            os.cancelTimer(timer)
            local response = textutils.unserialize(message)
            
            if response and response.success and response.account then
                gateway.sendWireless(replyChannel, {
                    success = true,
                    accountId = response.account.accountId
                })
            else
                gateway.sendWireless(replyChannel, {
                    success = false,
                    error = response and response.error or "Card not registered"
                })
            end
            return
        elseif event == "timer" then
            gateway.sendWireless(replyChannel, {
                success = false,
                error = "Internal server timeout"
            })
            return
        end
    end
end

-- Handle CREATE_ACCOUNT request
function gateway.handleCreateAccount(data, replyChannel)
    print("DEBUG [Gateway]: handleCreateAccount called")
    print("  username: " .. tostring(data.username))
    print("  replyChannel: " .. tostring(replyChannel))
    
    if not data.username then
        print("DEBUG [Gateway]: Missing username, sending error")
        gateway.sendWireless(replyChannel, {
            success = false,
            error = "Missing username"
        })
        return
    end
    
    -- Forward to balance manager
    local request = {
        action = "CREATE_ACCOUNT",
        username = data.username,
        publicKey = nil,  -- Portal accounts don't need public keys
        initialBalance = 0,
        cardUUIDs = {}  -- Empty initially, cards added later
    }
    
    print("DEBUG [Gateway]: Sending to balance manager on channel " .. gateway.balanceManagerChannel)
    print("  Request: " .. textutils.serialize(request))
    
    gateway.wiredModem.transmit(
        gateway.balanceManagerChannel,
        gateway.wiredChannel,
        textutils.serialize(request)
    )
    
    print("DEBUG [Gateway]: Waiting for response from balance manager...")
    
    -- Wait for response from balance manager
    local timer = os.startTimer(10)
    while true do
        local event, side, channel, respChannel, message = os.pullEvent()
        
        if event == "modem_message" and channel == gateway.wiredChannel then
            os.cancelTimer(timer)
            print("DEBUG [Gateway]: Received response from balance manager")
            local response = textutils.unserialize(message)
            print("  Response: " .. textutils.serialize(response))
            gateway.sendWireless(replyChannel, response)
            return
        elseif event == "timer" then
            print("DEBUG [Gateway]: Timeout waiting for balance manager")
            gateway.sendWireless(replyChannel, {
                success = false,
                error = "Internal server timeout"
            })
            return
        end
    end
end

-- Handle GET_ACCOUNT_BY_USERNAME request
function gateway.handleGetAccountByUsername(data, replyChannel)
    if not data.username then
        gateway.sendWireless(replyChannel, {
            success = false,
            error = "Missing username"
        })
        return
    end
    
    -- Need to search through all accounts - forward to balance manager
    local request = {
        action = "GET_ACCOUNT_BY_USERNAME",
        username = data.username
    }
    
    gateway.wiredModem.transmit(
        gateway.balanceManagerChannel,
        gateway.wirelessChannel,
        textutils.serialize(request)
    )
    
    -- Wait for response from balance manager
    local timer = os.startTimer(10)
    while true do
        local event, side, channel, respChannel, message = os.pullEvent()
        
        if event == "modem_message" and channel == gateway.wiredChannel then
            os.cancelTimer(timer)
            local response = textutils.unserialize(message)
            gateway.sendWireless(replyChannel, response)
            return
        elseif event == "timer" then
            gateway.sendWireless(replyChannel, {
                success = false,
                error = "Internal server timeout"
            })
            return
        end
    end
end

-- Handle ADD_CARD request
function gateway.handleAddCard(data, replyChannel)
    if not data.accountId or not data.cardUUID then
        gateway.sendWireless(replyChannel, {
            success = false,
            error = "Missing accountId or cardUUID"
        })
        return
    end
    
    -- Forward to balance manager
    local request = {
        action = "ADD_CARD",
        accountId = data.accountId,
        cardUUID = data.cardUUID
    }
    
    gateway.wiredModem.transmit(
        gateway.balanceManagerChannel,
        gateway.wirelessChannel,
        textutils.serialize(request)
    )
    
    -- Wait for response from balance manager
    local timer = os.startTimer(10)
    while true do
        local event, side, channel, respChannel, message = os.pullEvent()
        
        if event == "modem_message" and channel == gateway.wiredChannel then
            os.cancelTimer(timer)
            local response = textutils.unserialize(message)
            gateway.sendWireless(replyChannel, response)
            return
        elseif event == "timer" then
            gateway.sendWireless(replyChannel, {
                success = false,
                error = "Internal server timeout"
            })
            return
        end
    end
end

-- Handle REMOVE_CARD request
function gateway.handleRemoveCard(data, replyChannel)
    if not data.accountId or not data.cardUUID then
        gateway.sendWireless(replyChannel, {
            success = false,
            error = "Missing accountId or cardUUID"
        })
        return
    end
    
    -- Forward to balance manager
    local request = {
        action = "REMOVE_CARD",
        accountId = data.accountId,
        cardUUID = data.cardUUID
    }
    
    gateway.wiredModem.transmit(
        gateway.balanceManagerChannel,
        gateway.wirelessChannel,
        textutils.serialize(request)
    )
    
    -- Wait for response from balance manager
    local timer = os.startTimer(10)
    while true do
        local event, side, channel, respChannel, message = os.pullEvent()
        
        if event == "modem_message" and channel == gateway.wiredChannel then
            os.cancelTimer(timer)
            local response = textutils.unserialize(message)
            gateway.sendWireless(replyChannel, response)
            return
        elseif event == "timer" then
            gateway.sendWireless(replyChannel, {
                success = false,
                error = "Internal server timeout"
            })
            return
        end
    end
end

-- Handle GET_ACCOUNT request
function gateway.handleGetAccount(data, replyChannel)
    if not data.accountId then
        gateway.sendWireless(replyChannel, {
            success = false,
            error = "Missing accountId"
        })
        return
    end
    
    -- Forward to balance manager
    local request = {
        action = "GET_ACCOUNT",
        accountId = data.accountId
    }
    
    gateway.wiredModem.transmit(
        gateway.balanceManagerChannel,
        gateway.wirelessChannel,
        textutils.serialize(request)
    )
    
    -- Wait for response from balance manager
    local timer = os.startTimer(10)
    while true do
        local event, side, channel, respChannel, message = os.pullEvent()
        
        if event == "modem_message" and channel == gateway.wiredChannel then
            os.cancelTimer(timer)
            local response = textutils.unserialize(message)
            gateway.sendWireless(replyChannel, response)
            return
        elseif event == "timer" then
            gateway.sendWireless(replyChannel, {
                success = false,
                error = "Internal server timeout"
            })
            return
        end
    end
end


-- Handle wired message (from internal servers)
function gateway.handleWiredMessage(message, replyChannel)
    local data = textutils.unserialize(message)
    
    if not data then
        return
    end
    
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

-- Load deposit machine registry
function gateway.load(filename)
    filename = filename or "gateway.dat"
    if not fs.exists(filename) then return false end
    
    local file = fs.open(filename, "r")
    if not file then return false end
    
    local data = textutils.unserialize(file.readAll())
    file.close()
    
    if data then
        gateway.depositMachines = data.depositMachines or {}
        print("Loaded " .. #gateway.depositMachines .. " deposit machines")
        return true
    end
    
    return false
end

-- Save deposit machine registry
function gateway.save(filename)
    filename = filename or "gateway.dat"
    local file = fs.open(filename, "w")
    if not file then return false end
    
    file.write(textutils.serialize({
        depositMachines = gateway.depositMachines
    }))
    file.close()
    return true
end

-- Main loop
function gateway.run()
    print("Gateway running...")
    gateway.load()
    
    local lastSave = os.epoch("utc")
    
    while true do
        local event, side, channel, replyChannel, message, distance = os.pullEvent("modem_message")
        
        -- Check if from wireless (external)
        if side == peripheral.getName(gateway.wirelessModem) and channel == gateway.wirelessChannel then
            gateway.handleWirelessMessage(message, replyChannel)
        -- Check if from wired (internal - server manager)
        elseif side == peripheral.getName(gateway.wiredModem) and channel == gateway.wiredChannel then
            gateway.handleWiredMessage(message, replyChannel)
        end
        
        -- Auto-save every 5 minutes
        if os.epoch("utc") - lastSave > 300000 then
            gateway.save()
            lastSave = os.epoch("utc")
        end
    end
end

return gateway
