-- Key Generator Server - Keypair Generation
-- Generates ECC keypairs for new accounts
-- Connected via wired modem to other servers

local keyGenerator = {}
local serviceName = "pasmo"

-- Wired modem
keyGenerator.modem = nil
keyGenerator.serverChannel = 102 -- Internal server channel

-- Key storage
keyGenerator.generatedKeys = {} -- History of generated keys
keyGenerator.unicardService = nil -- Single UniCard service keypair metadata (public, allowedKeys)
keyGenerator.unicardPrivateKey = nil -- Loaded from disk (never serialized to data file)

-- Disk helpers for UniCard keypair
local function findDiskDrive()
    return peripheral.find("drive")
end

local function loadUniCardKeypairFromDisk()
    local drive = findDiskDrive()
    if not drive then
        return nil, nil, "No disk present"
    end
    local driveName = peripheral.getName(drive)
    if not disk.isPresent(driveName) then
        return nil, nil, "No disk present"
    end
    local mount = disk.getMountPath(driveName)
    if not mount then
        return nil, nil, "Disk not mounted"
    end
    local pubPath = fs.combine(mount, "uc_server_public.key")
    local privPath = fs.combine(mount, serviceName .. "_private.key")
    if not (fs.exists(pubPath) and fs.exists(privPath)) then
        return nil, nil, "Key files not found on disk"
    end
    local pubFile = fs.open(pubPath, "r")
    local privFile = fs.open(privPath, "r")
    if not pubFile or not privFile then
        if pubFile then pubFile.close() end
        if privFile then privFile.close() end
        return nil, nil, "Failed to read key files"
    end
    local publicKey = textutils.unserialize(pubFile.readAll())
    local privateKey = textutils.unserialize(privFile.readAll())
    pubFile.close()
    privFile.close()
    if not publicKey or not privateKey then
        return nil, nil, "Key files corrupted"
    end
    return publicKey, privateKey, nil
end

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
    local privateKey, publicKey = ecc.keypair()
    
    -- Store in history
    table.insert(keyGenerator.generatedKeys, {
        accountId = accountId,
        publicKey = publicKey,
        timestamp = os.epoch("utc"),
        -- Note that we don't store the private key!
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
    elseif request.action == "GET_UNICARD_KEY" then
        -- Ensure we have the UniCard keypair loaded (from disk-only storage)
        if not keyGenerator.unicardService or not keyGenerator.unicardPrivateKey then
            local pub, priv, err = loadUniCardKeypairFromDisk()
            if not (pub and priv) then
                return { success = false, error = "UniCard keypair missing on disk: " .. tostring(err) }
            end
            keyGenerator.unicardPrivateKey = priv
            keyGenerator.unicardService = keyGenerator.unicardService or {}
            keyGenerator.unicardService.publicKey = pub
            keyGenerator.unicardService.allowedKeys = keyGenerator.unicardService.allowedKeys or {}
            keyGenerator.unicardService.createdAt = keyGenerator.unicardService.createdAt or os.epoch("utc")
        end

        return {
            success = true,
            publicKey = keyGenerator.unicardService.publicKey,
            privateKey = keyGenerator.unicardPrivateKey,
            allowedFields = keyGenerator.unicardService.allowedKeys or {}
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
        generatedKeys = keyGenerator.generatedKeys,
        unicardService = keyGenerator.unicardService
    }))
    file.close()
    return true
end

-- Load key history
function keyGenerator.load(filename)
    filename = filename or "key_generator.dat"
    if fs.exists(filename) then
        local file = fs.open(filename, "r")
        if file then
            local data = textutils.unserialize(file.readAll())
            file.close()
            if data then
                keyGenerator.generatedKeys = data.generatedKeys or {}
                keyGenerator.unicardService = data.unicardService or nil
            end
        end
    end

    -- Always try to load the UniCard keypair from disk
    local pub, priv = loadUniCardKeypairFromDisk()
    if pub and priv then
        keyGenerator.unicardPrivateKey = priv
        if not keyGenerator.unicardService then
            keyGenerator.unicardService = {
                publicKey = pub,
                privateKey = priv,
                allowedKeys = {},
                createdAt = os.epoch("utc")
            }
        end
    end

    return true
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
loadedPub, loadedPriv = loadUniCardKeypairFromDisk()
keyGenerator.init()
keyGenerator.run()

return keyGenerator
