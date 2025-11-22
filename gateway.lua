-- Encryption/Decryption Gateway
-- Interfaces between wireless modems (external) and wired modems (internal servers)
-- Encrypts outgoing messages, decrypts incoming messages
-- Verifies signatures from deposit machines

local gateway = {}

-- Modems
gateway.wiredModem = nil
gateway.wirelessModem = nil

-- Channels
gateway.wirelessChannel = 1000 -- External channel for wireless clients
gateway.balanceManagerChannel = 101
gateway.ledgerChannel = 100

-- Deposit machine registry (machineId -> publicKey)
gateway.depositMachines = {}

-- Initialize
function gateway.init()
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
    
    gateway.wiredModem.open(gateway.balanceManagerChannel)
    gateway.wirelessModem.open(gateway.wirelessChannel)
    
    print("Gateway initialized")
    print("Wireless channel: " .. gateway.wirelessChannel)
    print("Internal channels: " .. gateway.balanceManagerChannel)
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

-- Encrypt message for wireless transmission
function gateway.encryptMessage(message, recipientPublicKey)
    -- In a full implementation, use ECC encryption here
    -- For now, we'll use signing to ensure authenticity
    local ecc = require("ecc")
    
    local packet = {
        data = message,
        timestamp = os.epoch("utc"),
        signature = nil -- Would sign with server's private key
    }
    
    return textutils.serialize(packet)
end

-- Decrypt incoming wireless message
function gateway.decryptMessage(encryptedMessage)
    -- In a full implementation, decrypt with ECC here
    local packet = textutils.unserialize(encryptedMessage)
    
    if not packet or not packet.data then
        return nil, "Invalid packet format"
    end
    
    -- Verify timestamp (prevent replay attacks)
    local age = os.epoch("utc") - packet.timestamp
    if age > 60000 then -- 60 seconds
        return nil, "Packet too old"
    end
    
    return packet.data, nil
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

-- Handle machine registration (from wired network - server manager)
function gateway.handleMachineRegistration(data, replyChannel)
    if not data.machineId or not data.publicKey then
        gateway.wiredModem.transmit(replyChannel, gateway.balanceManagerChannel, textutils.serialize({
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
    gateway.wiredModem.transmit(replyChannel, gateway.balanceManagerChannel, textutils.serialize({
        success = true,
        machineId = data.machineId
    }))
end

-- Handle wireless message
function gateway.handleWirelessMessage(message, replyChannel)
    local data, err = gateway.decryptMessage(message)
    
    if not data then
        gateway.sendWireless(replyChannel, {
            success = false,
            error = err or "Decryption failed"
        })
        return
    end
    
    -- Route based on request type
    if data.requestType == "DEPOSIT" then
        gateway.handleDepositRequest(data, replyChannel)
    elseif data.requestType == "CARD_PAYMENT" then
        gateway.handleCardPayment(data, replyChannel)
    else
        gateway.sendWireless(replyChannel, {
            success = false,
            error = "Unknown request type"
        })
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
        elseif side == peripheral.getName(gateway.wiredModem) and channel == gateway.balanceManagerChannel then
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
