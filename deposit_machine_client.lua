-- Deposit Machine Client
-- Uses unique private key to sign deposit requests
-- Communicates with gateway via wireless modem

local depositMachine = {}

-- Configuration
depositMachine.machineId = "DEPOSIT_" .. os.getComputerID()
depositMachine.privateKey = nil -- Must be set during registration
depositMachine.publicKey = nil
depositMachine.chestSide = "top"
depositMachine.diamondValue = 100
depositMachine.gatewayChannel = 1000

-- Modem
depositMachine.modem = nil

-- Initialize
function depositMachine.init(privateKey, publicKey)
    depositMachine.privateKey = privateKey
    depositMachine.publicKey = publicKey
    
    -- Find wireless modem
    depositMachine.modem = peripheral.find("modem", function(name, modem)
        return modem.isWireless() == true
    end)
    
    if not depositMachine.modem then
        error("No wireless modem found!")
    end
    
    local responseChannel = math.random(2000, 60000)
    depositMachine.modem.open(responseChannel)
    
    print("Deposit Machine initialized")
    print("Machine ID: " .. depositMachine.machineId)
    print("Response channel: " .. responseChannel)
    
    return responseChannel
end

-- Sign a deposit request
function depositMachine.signDeposit(accountId, amount, timestamp)
    local ecc = require("ecc")
    
    -- Create message to sign
    local message = accountId .. amount .. timestamp
    
    -- Sign with private key
    local signature = ecc.sign(depositMachine.privateKey, message)
    
    return signature
end

-- Count diamonds in chest
function depositMachine.countDiamonds()
    local chest = peripheral.wrap(depositMachine.chestSide)
    if not chest then
        return 0, "Chest not found"
    end
    
    local total = 0
    for slot = 1, chest.size() do
        local item = chest.getItemDetail(slot)
        if item and item.name == "minecraft:diamond" then
            total = total + item.count
        end
    end
    
    return total, nil
end

-- Clear diamonds from chest
function depositMachine.clearDiamonds()
    local chest = peripheral.wrap(depositMachine.chestSide)
    if not chest then return false end
    
    for slot = 1, chest.size() do
        local item = chest.getItemDetail(slot)
        if item and item.name == "minecraft:diamond" then
            chest.pushItems("bottom", slot)
        end
    end
    
    return true
end

-- Process deposit
function depositMachine.processDeposit(accountId, diamondCount)
    local amount = diamondCount * depositMachine.diamondValue
    local timestamp = os.epoch("utc")
    
    -- Sign the deposit
    local signature = depositMachine.signDeposit(accountId, amount, timestamp)
    
    -- Create encrypted packet
    local packet = {
        data = {
            requestType = "DEPOSIT",
            depositMachineId = depositMachine.machineId,
            accountId = accountId,
            amount = amount,
            timestamp = timestamp,
            signature = signature
        },
        timestamp = timestamp,
        signature = nil -- Gateway will verify deposit signature
    }
    
    -- Send to gateway
    local responseChannel = depositMachine.modem.getChannels()[1]
    depositMachine.modem.transmit(
        depositMachine.gatewayChannel,
        responseChannel,
        textutils.serialize(packet)
    )
    
    -- Wait for response
    local timer = os.startTimer(15)
    while true do
        local event, side, channel, replyChannel, message = os.pullEvent()
        
        if event == "modem_message" and channel == responseChannel then
            os.cancelTimer(timer)
            local encrypted = message
            local response = textutils.unserialize(encrypted)
            
            if response and response.data then
                return response.data.success, response.data
            end
            return false, response
        elseif event == "timer" and side == timer then
            return false, { error = "Gateway timeout" }
        end
    end
end

-- Main UI loop
function depositMachine.runUI()
    term.clear()
    term.setCursorPos(1, 1)
    
    print("================================")
    print("   Diamond Deposit Machine")
    print("================================")
    print()
    print("Machine ID: " .. depositMachine.machineId)
    print()
    print("Ready to accept deposits")
    print()
    
    while true do
        write("Enter Account ID: ")
        local accountId = read()
        
        if accountId and accountId ~= "" then
            print()
            print("Place diamonds in chest and press Enter...")
            read()
            
            print("Counting diamonds...")
            local diamondCount, err = depositMachine.countDiamonds()
            
            if err then
                print("ERROR: " .. err)
            elseif diamondCount == 0 then
                print("No diamonds found in chest")
            else
                local amount = diamondCount * depositMachine.diamondValue
                print(string.format("Found %d diamonds (value: %d)", diamondCount, amount))
                print()
                print("Processing deposit...")
                
                local success, response = depositMachine.processDeposit(accountId, diamondCount)
                
                if success then
                    print()
                    print("=== DEPOSIT SUCCESSFUL ===")
                    print("Transaction ID: " .. (response.transactionId or "N/A"))
                    print("New Balance: " .. (response.newBalance or "N/A"))
                    print("==========================")
                    
                    -- Clear chest
                    depositMachine.clearDiamonds()
                    print("Chest cleared")
                else
                    print()
                    print("DEPOSIT FAILED:")
                    print(response.error or "Unknown error")
                    print()
                    print("Diamonds NOT accepted")
                end
            end
        end
        
        print()
        print("---")
        print()
        sleep(1)
    end
end

-- Save keys to secure location
function depositMachine.saveKeys(filename)
    filename = filename or ".deposit_keys"
    local file = fs.open(filename, "w")
    if not file then return false end
    
    file.write(textutils.serialize({
        machineId = depositMachine.machineId,
        privateKey = depositMachine.privateKey,
        publicKey = depositMachine.publicKey
    }))
    file.close()
    
    -- Make file read-only if possible
    return true
end

-- Load keys from secure location
function depositMachine.loadKeys(filename)
    filename = filename or ".deposit_keys"
    if not fs.exists(filename) then return false end
    
    local file = fs.open(filename, "r")
    if not file then return false end
    
    local data = textutils.unserialize(file.readAll())
    file.close()
    
    if data then
        depositMachine.machineId = data.machineId
        depositMachine.privateKey = data.privateKey
        depositMachine.publicKey = data.publicKey
        return true
    end
    
    return false
end

return depositMachine
