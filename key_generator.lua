-- Key Generator Server - Keypair Generation
-- Generates ECC keypairs for new accounts
-- Connected via wired modem to other servers

local keyGenerator = {}

-- Wired modem
keyGenerator.modem = nil
keyGenerator.serverChannel = 102 -- Internal server channel

-- Key storage
keyGenerator.generatedKeys = {} -- History of generated keys

-- Initialize
function keyGenerator.init()
    -- Find wired modem
    keyGenerator.modem = peripheral.find("modem", function(name, modem)
        return modem.isWireless() == false
    end)
    
    if not keyGenerator.modem then
        error("No wired modem found!")
    end
    
    keyGenerator.modem.open(keyGenerator.serverChannel)
    print("Key Generator initialized on channel " .. keyGenerator.serverChannel)
end

-- Generate a keypair for an account
function keyGenerator.generateKeypair(accountId)
    local ecc = require("ecc")
    
    -- Generate keypair (random if no accountId seed)
    local privateKey, publicKey = ecc.keypair()
    
    -- Store in history
    table.insert(keyGenerator.generatedKeys, {
        accountId = accountId,
        publicKey = publicKey,
        timestamp = os.epoch("utc"),
        -- Note: Private key is NOT stored on key generator
        -- It should be given to the client and deleted from memory
    })
    
    return {
        publicKey = publicKey,
        privateKey = privateKey
    }
end

-- Handle incoming requests
function keyGenerator.handleRequest(message)
    print("Received message: " .. tostring(message))
    local request = textutils.unserialize(message)
    if not request then 
        print("Failed to unserialize message")
        return nil 
    end
    
    print("Request action: " .. tostring(request.action))
    
    if request.action == "GENERATE_KEYPAIR" then
        print("Generating keypair...")
        local keys = keyGenerator.generateKeypair(request.accountId)
        print("Keypair generated successfully")
        return {
            success = true,
            publicKey = keys.publicKey,
            privateKey = keys.privateKey
        }
    end
    
    print("Unknown action: " .. tostring(request.action))
    return { success = false, error = "Unknown action" }
end

-- Save key history
function keyGenerator.save(filename)
    filename = filename or "key_generator.dat"
    local file = fs.open(filename, "w")
    if not file then return false end
    
    -- Only save public keys and metadata (never private keys)
    file.write(textutils.serialize({
        generatedKeys = keyGenerator.generatedKeys
    }))
    file.close()
    return true
end

-- Load key history
function keyGenerator.load(filename)
    filename = filename or "key_generator.dat"
    if not fs.exists(filename) then return false end
    
    local file = fs.open(filename, "r")
    if not file then return false end
    
    local data = textutils.unserialize(file.readAll())
    file.close()
    
    if data then
        keyGenerator.generatedKeys = data.generatedKeys or {}
        return true
    end
    
    return false
end

-- Main server loop
function keyGenerator.run()
    print("Key Generator running...")
    keyGenerator.load()
    
    local lastSave = os.epoch("utc")
    
    while true do
        local event, side, channel, replyChannel, message = os.pullEvent("modem_message")
        
        local response = keyGenerator.handleRequest(message)
        if response then
            keyGenerator.modem.transmit(replyChannel, channel, textutils.serialize(response))
        end
        
        -- Auto-save every 5 minutes
        if os.epoch("utc") - lastSave > 300000 then
            keyGenerator.save()
            lastSave = os.epoch("utc")
        end
    end
end

return keyGenerator
