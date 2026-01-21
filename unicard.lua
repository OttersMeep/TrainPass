-- UniCard Client Library
-- Provides secure key-value storage for payment cards
-- Each key is owned by the application that created it (verified by signature)

local ecc = require("ecc")
local unicard = {}

-- Configuration
unicard.config = {
    serverChannel = 200,
    privateKey = nil,
    publicKey = nil,
    serviceId = nil,
    modem = nil,
    responseTimeout = 10
}

-- Initialize the UniCard client
-- @param privateKey: ECC private key for signing requests
-- @param publicKey: ECC public key (optional, will be derived if not provided)
-- @param serverChannel: Channel to communicate with UniCard server (default: 200)
-- @param serviceId: Identifier for this client/service (required so the server can pick the right secret)
function unicard.init(privateKey, publicKey, serverChannel, serviceId)
    if not privateKey then
        error("Private key required for UniCard initialization")
    end
    
    unicard.config.privateKey = privateKey
    unicard.config.publicKey = publicKey
    unicard.config.serverChannel = serverChannel or 200
    unicard.config.serviceId = serviceId or unicard.config.serviceId
    if not unicard.config.serviceId then
        error("Service ID required for UniCard initialization")
    end
    
    -- Find wireless modem (UniCard uses wireless to communicate with server)
    unicard.config.modem = peripheral.find("modem", function(name, modem)
        return modem.isWireless()
    end)
    
    if not unicard.config.modem then
        error("No wireless modem found for UniCard client")
    end
    
    return true
end

-- Send encrypted and signed request to UniCard server
local function sendRequest(requestData)
    local timestamp = os.epoch("utc")
    
    -- Add timestamp (no signature needed)
    requestData.timestamp = timestamp
    
    -- Derive shared secret (client has both halves of the UniCard keypair)
    local sharedSecret = ecc.exchange(unicard.config.privateKey, unicard.config.publicKey)

    -- Serialize and encrypt
    local responseChannel = 3000 + math.random(1, 6999)
    unicard.config.modem.open(responseChannel)
    
    local serialized = textutils.serialize(requestData)
    local encrypted = ecc.encrypt(serialized, sharedSecret)

    unicard.config.modem.transmit(
        unicard.config.serverChannel,
        responseChannel,
        textutils.serialize({
            serviceId = unicard.config.serviceId,
            encryptedData = encrypted
        })
    )
    
    -- Wait for response
    local timer = os.startTimer(unicard.config.responseTimeout)
    -- p4 = textutils.serialise(true,ecc.encrypt(response,decryption)))
    while true do
        local event, p1, p2, p3, p4 = os.pullEvent()
        
        if event == "modem_message" and p2 == responseChannel then
            os.cancelTimer(timer)
            unicard.config.modem.close(responseChannel)
            local packet = textutils.unserialize(p4)

            if packet and type(packet) == "table" and packet.encryptedData then
                local success, decrypted = pcall(ecc.decrypt, packet.encryptedData, sharedSecret)
                if success then
                    return true,decrypted
                else
                    return nil, "Decryption failed"
                end
            end

            return packet
        elseif event == "timer" and p1 == timer then
            unicard.config.modem.close(responseChannel)
            return nil, "Timeout"
        end
    end
end

-- Get a value from a card
-- @param key: The key to retrieve
-- @param cardUUID: The card's UUID
-- @return value, error
function unicard.getKey(key, cardUUID)
    if not unicard.config.privateKey then
        return nil, "UniCard not initialized"
    end
    
    if not key or not cardUUID then
        return nil, "Key and cardUUID required"
    end
    
    local success, response = sendRequest({
        requestType = "GET_FIELD",
        cardUUID = cardUUID,
        key = key
    })
    
    if not response then
        return nil, err or "No response from server"
    end
    
    if success then
        return response.value, nil
    else
        return nil, response.error or "Unknown error"
    end
end

-- Set a value on a card
-- @param key: The key to set
-- @param value: The value to store (must be serializable)
-- @param cardUUID: The card's UUID
-- @return success, error
function unicard.setKey(key, value, cardUUID)
    if not unicard.config.privateKey then
        return false, "UniCard not initialized"
    end
    
    if not key or not cardUUID then
        return false, "Key and cardUUID required"
    end
    
    -- Value can be nil to delete
    local success, response = sendRequest({
        requestType = "SET_FIELD",
        cardUUID = cardUUID,
        key = key,
        value = value
    })
    
    if not response then
        return false, err or "No response from server"
    end
    
    if success then
        return true, nil
    else
        return false, response.error or "Unknown error"
    end
end

-- Delete a key from a card
-- @param key: The key to delete
-- @param cardUUID: The card's UUID
-- @return success, error
function unicard.deleteKey(key, cardUUID)
    if not unicard.config.privateKey then
        return false, "UniCard not initialized"
    end
    
    if not key or not cardUUID then
        return false, "Key and cardUUID required"
    end
    
    local success, response = sendRequest({
        requestType = "DELETE_FIELD",
        cardUUID = cardUUID,
        key = key
    })
    
    if not response then
        return false, err or "No response from server"
    end
    
    if success then
        return true, nil
    else
        return false, response.error or "Unknown error"
    end
end

-- List all keys on a card (readable by this application)
-- @param cardUUID: The card's UUID
-- @return keys table, error
function unicard.listKeys(cardUUID)
    if not unicard.config.privateKey then
        return nil, "UniCard not initialized"
    end
    
    if not cardUUID then
        return nil, "cardUUID required"
    end
    
    local success, response = sendRequest({
        requestType = "LIST_FIELD",
        cardUUID = cardUUID
    })
    
    if not response then
        return nil, err or "No response from server"
    end
    
    if success then
        return response.keys or {}, nil
    else
        return nil, response.error or "Unknown error"
    end
end
return unicard