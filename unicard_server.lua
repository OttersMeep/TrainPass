-- UniCard Server
-- Secure key-value storage for payment cards
-- Each key can only be modified by the application that created it

local ecc = require("ecc")
local unicardServer = {}

-- Storage
unicardServer.storage = {}   -- cardUUID -> { key -> { value, ownerPublicKey, createdAt, updatedAt } }
unicardServer.services = {}  -- serviceId -> { publicKey, allowedKeys, createdAt }

local function serializePublicKey(pk)
    return pk and textutils.serialize(pk) or nil
end

local function findServiceByPublicKey(publicKey)
    local needle = serializePublicKey(publicKey)
    if not needle then return nil, nil end
    for id, svc in pairs(unicardServer.services) do
        if serializePublicKey(svc.publicKey) == needle then
            return id, svc
        end
    end
    return nil, nil
end

-- Configuration
unicardServer.config = {
    serverChannel = 200,
    modem = nil,
    dataFile = "unicard_data.dat"
}

-- Initialize the server
function unicardServer.init(serverChannel)

        -- Load or generate UC Server keypair (recycle your code)
    if fs.exists("server_keys.dat") then
        local file = fs.open("server_keys.dat", "r")
        if file then
            local data = textutils.unserialize(file.readAll())
            file.close()
            unicardServer.privateKey = data.privateKey
            unicardServer.publicKey = data.publicKey
            print("Loaded UC Server keypair")
        end
    end
    -- huh guys this looks familiar almost like this exact thing was in gateway.lua no wayyyy
    if not unicardServer.privateKey then
    print("Generating new UC SERVER keypair...")
    unicardServer.privateKey, unicardServer.publicKey = ecc.keypair()
    
    -- Save keypair
    local file = fs.open("server_keys.dat", "w")
    if file
        file.write(textutils.serialize({
            privateKey = unicardServer.privateKey,
            publicKey = unicardServer.publicKey
        }))
        file.close()
        print("Gateway keypair saved")
    end

    unicardServer.config.serverChannel = serverChannel or 200
    
    -- Find wireless modem (UniCard uses wireless, separate from TrainPass network)
    unicardServer.config.modem = peripheral.find("modem", function(name, modem)
        return modem.isWireless()
    end)
    
    if not unicardServer.config.modem then
        error("No wireless modem found for UniCard server")
    end
    
    unicardServer.config.modem.open(unicardServer.config.serverChannel)
    print("UniCard Server initialized on channel " .. unicardServer.config.serverChannel)
    
    -- Load existing data
    unicardServer.load()
end

-- Save data to disk
function unicardServer.save()
    local file = fs.open(unicardServer.config.dataFile, "w")
    if file then
        file.write(textutils.serialize({
            storage = unicardServer.storage,
            services = unicardServer.services
        }))
        file.close()
        return true
    end
    return false
end

-- Load data from disk
function unicardServer.load()
    if fs.exists(unicardServer.config.dataFile) then
        local file = fs.open(unicardServer.config.dataFile, "r")
        if file then
            local data = file.readAll()
            file.close()
            local decoded = textutils.unserialize(data) or {}
            unicardServer.storage = decoded.storage or {}
            unicardServer.services = decoded.services or {}
            local cardCount = 0
            for _ in pairs(unicardServer.storage) do cardCount = cardCount + 1 end
            local svcCount = 0
            for _ in pairs(unicardServer.services) do svcCount = svcCount + 1 end
            print("Loaded UniCard data: " .. cardCount .. " cards, " .. svcCount .. " services")
            return true
        end
    end
    unicardServer.storage = {}
    unicardServer.services = {}
    return false
end

-- Verify request signature
local function verifySignature(request)
    if not request.signature or not request.publicKey or not request.timestamp then
        return false, "Missing signature, publicKey, or timestamp"
    end
    
    -- Reconstruct the signed data
    local signatureData = textutils.serialize({
        requestType = request.requestType,
        cardUUID = request.cardUUID,
        key = request.key,
        timestamp = request.timestamp
    })
    
    -- Verify signature
    local valid = ecc.verify(request.publicKey, signatureData, request.signature)
    
    if not valid then
        return false, "Invalid signature"
    end
    
    return true, nil
end

-- Check if public key owns a specific key on a card and is allowed for this service
local function checkOwnership(cardUUID, key, publicKey)
    local serviceId, service = findServiceByPublicKey(publicKey)
    if not serviceId then
        return false, "Service not registered"
    end

    local allowed = false
    for _, k in ipairs(service.allowedKeys or {}) do
        if k == key then
            allowed = true
            break
        end
    end
    if not allowed then
        return false, "Field not allowed for this service"
    end

    if not unicardServer.storage[cardUUID] then
        return true
    end
    
    local cardData = unicardServer.storage[cardUUID]
    if not cardData[key] then
        return true
    end
    
    local ownerSerialized = serializePublicKey(cardData[key].ownerPublicKey)
    local requesterSerialized = serializePublicKey(publicKey)
    
    if ownerSerialized ~= requesterSerialized then
        return false, "Field owned by different service"
    end
    return true
end

-- Handle GET_KEY request
local function handleGetField(request)
    local cardUUID = request.cardUUID
    local key = request.key
    
    if not unicardServer.storage[cardUUID] then
        return { success = false, error = "Card not found" }
    end
    
    if not unicardServer.storage[cardUUID][key] then
        return { success = false, error = "Key not found" }
    end
    
    local data = unicardServer.storage[cardUUID][key]
    
    return {
        success = true,
        value = data.value
    }
end

-- Handle SET_KEY request
local function handleSetField(request)
    local cardUUID = request.cardUUID
    local key = request.key
    local value = request.value
    local publicKey = request.publicKey
    
    local ok, ownershipErr = checkOwnership(cardUUID, key, publicKey)
    if not ok then
        return { success = false, error = ownershipErr or "Access denied" }
    end
    
    -- Initialize card storage if needed
    if not unicardServer.storage[cardUUID] then
        unicardServer.storage[cardUUID] = {}
    end
    
    -- Store the key
    unicardServer.storage[cardUUID][key] = {
        value = value,
        ownerPublicKey = publicKey,
        createdAt = unicardServer.storage[cardUUID][key] and unicardServer.storage[cardUUID][key].createdAt or os.epoch("utc"),
        updatedAt = os.epoch("utc")
    }
    
    -- Save to disk
    unicardServer.save()
    
    return { success = true }
end

-- Handle DELETE_KEY request
local function handleDeleteField(request)
    local cardUUID = request.cardUUID
    local key = request.key
    local publicKey = request.publicKey
    
    if not unicardServer.storage[cardUUID] then
        return { success = false, error = "Card not found" }
    end
    
    if not unicardServer.storage[cardUUID][key] then
        return { success = false, error = "Key not found" }
    end
    
    local ok, ownershipErr = checkOwnership(cardUUID, key, publicKey)
    if not ok then
        return { success = false, error = ownershipErr or "Access denied" }
    end
    
    -- Delete the key
    unicardServer.storage[cardUUID][key] = nil
    
    -- Save to disk
    unicardServer.save()
    
    return { success = true }
end

-- Handle LIST_KEYS request
local function handleListField(request)
    local cardUUID = request.cardUUID
    local publicKey = request.publicKey
    
    if not unicardServer.storage[cardUUID] then
        return { success = true, keys = {} }
    end
    
    -- List keys owned by this public key
    local keys = {}
    local publicKeySerialized = textutils.serialize(publicKey)
    
    for key, data in pairs(unicardServer.storage[cardUUID]) do
        local ownerSerialized = textutils.serialize(data.ownerPublicKey)
        if ownerSerialized == publicKeySerialized then
            table.insert(keys, key)
        end
    end
    
    return {
        success = true,
        keys = keys
    }
end

-- Handle incoming request
local function handleRequest(request, replyChannel)
    -- Verify signature
    local valid, err = verifySignature(request)
    if not valid then
        return {
            success = false,
            error = err or "Signature verification failed"
        }
    end
    
    -- Route to appropriate handler
    if request.requestType == "GET_FIELD" then
        return handleGetField(request)
    elseif request.requestType == "SET_FIELD" then
        return handleSetField(request)
    elseif request.requestType == "DELETE_FIELD" then
        return handleDeleteField(request)
    elseif request.requestType == "LIST_FIELD" then
        return handleListField(request)
    else
        return {
            success = false,
            error = "Unknown request type: " .. tostring(request.requestType)
        }
    end
end

-- Service management helpers -------------------------------------------------

local function splitFields(str)
    local out = {}
    if not str or str == "" then return out end
    for field in string.gmatch(str, "[^,]+") do
        local trimmed = field:gsub("^%s*(.-)%s*$", "%1")
        if trimmed ~= "" then table.insert(out, trimmed) end
    end
    return out
end

local function mergeFields(existing, newFields)
    local set, merged = {}, {}
    for _, k in ipairs(existing or {}) do
        if not set[k] then table.insert(merged, k) end
        set[k] = true
    end
    for _, k in ipairs(newFields or {}) do
        if not set[k] then table.insert(merged, k) end
        set[k] = true
    end
    return merged
end

local function saveKeypairToDisk(serviceId, privateKey, publicKey)
    local driveName = peripheral.find("drive")
    if not driveName then
        return false, "No disk drive found"
    end
    if not disk.isPresent(driveName) then
        return false, "No disk inserted"
    end
    local mount = disk.getMountPath(driveName)
    if not mount then
        return false, "Disk not mounted"
    end

    local base = fs.combine(mount, serviceId)
    local pubPath = "uc_server_public.key"
    local privPath = base .. "_private.key"

    local pubFile = fs.open(pubPath, "w")
    local privFile = fs.open(privPath, "w")
    if not pubFile or not privFile then
        if pubFile then pubFile.close() end
        if privFile then privFile.close() end
        return false, "Failed to write key files"
    end
    pubFile.write(textutils.serialize(unicardServer.publicKey))
    privFile.write(textutils.serialize(privateKey))
    pubFile.close()
    privFile.close()
    return true
end

local function deleteKeypairFromDisk(serviceId)
    local driveName = peripheral.find("drive")
    if not driveName or not disk.isPresent(driveName) then return end
    local mount = disk.getMountPath(driveName)
    if not mount then return end
    local base = fs.combine(mount, serviceId)
    local pubPath = base .. "_public.key"
    local privPath = base .. "_private.key"
    if fs.exists(pubPath) then fs.delete(pubPath) end
    if fs.exists(privPath) then fs.delete(privPath) end
end

local function registerService(serviceId, fields)
    if unicardServer.services[serviceId] then
        return false, "Service already exists"
    end
    local privateKey, publicKey = ecc.keypair()
    unicardServer.services[serviceId] = {
        publicKey = publicKey,
        allowedKeys = fields,
        createdAt = os.epoch("utc")
    }
    unicardServer.save()
    local ok, err = saveKeypairToDisk(serviceId, privateKey, publicKey)
    if not ok then
        return false, "Created service but failed to save to disk: " .. (err or "unknown")
    end
    return true, "Service created and keypair saved to disk"
end

local function addFields(serviceId, fields)
    local svc = unicardServer.services[serviceId]
    if not svc then return false, "Service not found" end
    svc.allowedKeys = mergeFields(svc.allowedKeys, fields)
    unicardServer.save()
    return true
end

local function listFields(serviceId)
    local svc = unicardServer.services[serviceId]
    if not svc then return nil, "Service not found" end
    return svc.allowedKeys or {}
end

local function removeService(serviceId)
    if not unicardServer.services[serviceId] then
        return false, "Service not found"
    end
    unicardServer.services[serviceId] = nil
    deleteKeypairFromDisk(serviceId)
    unicardServer.save()
    return true
end

local function runShell()
    while true do
        io.write("unicard> ")
        local line = read()
        if not line then break end
        local cmd, rest = line:match("^(%S+)%s*(.*)$")
        if not cmd or cmd == "" then goto continue end

        if cmd == "exit" or cmd == "quit" then
            print("Exiting shell (server still running). Press Ctrl+T to stop server.")
            break
        elseif cmd == "new" then
            local sub, args = rest:match("^(%S+)%s+(.+)$")
            if sub ~= "service" then
                print("Usage: new service <serviceID> <fields>")
                goto continue
            end
            local serviceId, fieldsStr = args:match("^(%S+)%s+(.+)$")
            if not serviceId or not fieldsStr then
                print("Usage: new service <serviceID> <fields>")
                goto continue
            end
            local fields = splitFields(fieldsStr)
            local ok, msg = registerService(serviceId, fields)
            if ok then print(msg) else print("Error: " .. tostring(msg)) end
        elseif cmd == "add" then
            local sub, args = rest:match("^(%S+)%s+(.+)$")
            if sub ~= "field" then
                print("Usage: add field <serviceID> <fields>")
                goto continue
            end
            local serviceId, fieldsStr = args:match("^(%S+)%s+(.+)$")
            if not serviceId or not fieldsStr then
                print("Usage: add field <serviceID> <fields>")
                goto continue
            end
            local fields = splitFields(fieldsStr)
            local ok, err = addFields(serviceId, fields)
            if ok then print("Fields added.") else print("Error: " .. tostring(err)) end
        elseif cmd == "list" then
            local sub, serviceId = rest:match("^(%S+)%s+(%S+)$")
            if sub ~= "fields" or not serviceId then
                print("Usage: list fields <serviceID>")
                goto continue
            end
            local fields, err = listFields(serviceId)
            if fields then
                print("Fields: " .. table.concat(fields, ", "))
            else
                print("Error: " .. tostring(err))
            end
        elseif cmd == "remove" then
            local sub, serviceId = rest:match("^(%S+)%s+(%S+)$")
            if sub ~= "service" or not serviceId then
                print("Usage: remove service <serviceID>")
                goto continue
            end
            local ok, err = removeService(serviceId)
            if ok then print("Service removed and keypair deleted.") else print("Error: " .. tostring(err)) end
        else
            print("Commands: new service <id> <fields> | add field <id> <fields> | list fields <id> | remove service <id> | exit")
        end

        ::continue::
    end
end

-- Main server loop
local function runServerLoop()
    print("UniCard Server running...")
    print("Listening on channel " .. unicardServer.config.serverChannel)
    print("Press Ctrl+T to stop")
    
    while true do
        local event, side, channel, replyChannel, message = os.pullEvent("modem_message")
        if channel == unicardServer.config.serverChannel then
            local request = textutils.unserialize(message)
            if request then
                local response = handleRequest(request, replyChannel)
                unicardServer.config.modem.transmit(
                    replyChannel,
                    unicardServer.config.serverChannel,
                    textutils.serialize(response)
                )
            end
        end
    end
end

function unicardServer.run()
    parallel.waitForAny(runServerLoop, runShell)
end

-- Start the server
unicardServer.init()
unicardServer.run()
