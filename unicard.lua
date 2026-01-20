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
    modem = nil,
    responseTimeout = 10
}

-- Initialize the UniCard client
-- @param privateKey: ECC private key for signing requests
-- @param publicKey: ECC public key (optional, will be derived if not provided)
-- @param serverChannel: Channel to communicate with UniCard server (default: 200)
function unicard.init(privateKey, publicKey, serverChannel)
    if not privateKey then
        error("Private key required for UniCard initialization")
    end
    
    unicard.config.privateKey = privateKey
    unicard.config.publicKey = publicKey or ecc.publicKey(privateKey)
    unicard.config.serverChannel = serverChannel or 200
    
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
    
    -- Sign the request
    local signatureData = textutils.serialize({
        requestType = requestData.requestType,
        cardUUID = requestData.cardUUID,
        key = requestData.key,
        timestamp = timestamp
    })
    local signature = ecc.sign(unicard.config.privateKey, signatureData)
    
    -- Add signature and public key to request
    requestData.signature = signature
    requestData.publicKey = unicard.config.publicKey
    requestData.timestamp = timestamp
    
    -- Serialize and send
    local responseChannel = 3000 + math.random(1, 6999)
    unicard.config.modem.open(responseChannel)
    
    unicard.config.modem.transmit(
        unicard.config.serverChannel,
        responseChannel,
        textutils.serialize(requestData)
    )
    
    -- Wait for response
    local timer = os.startTimer(unicard.config.responseTimeout)
    
    while true do
        local event, p1, p2, p3, p4 = os.pullEvent()
        
        if event == "modem_message" and p2 == responseChannel then
            os.cancelTimer(timer)
            unicard.config.modem.close(responseChannel)
            local response = textutils.unserialize(p4)
            return response
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
    
    local response, err = sendRequest({
        requestType = "GET_KEY",
        cardUUID = cardUUID,
        key = key
    })
    
    if not response then
        return nil, err or "No response from server"
    end
    
    if response.success then
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
    local response, err = sendRequest({
        requestType = "SET_KEY",
        cardUUID = cardUUID,
        key = key,
        value = value
    })
    
    if not response then
        return false, err or "No response from server"
    end
    
    if response.success then
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
    
    local response, err = sendRequest({
        requestType = "DELETE_KEY",
        cardUUID = cardUUID,
        key = key
    })
    
    if not response then
        return false, err or "No response from server"
    end
    
    if response.success then
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
    
    local response, err = sendRequest({
        requestType = "LIST_KEYS",
        cardUUID = cardUUID
    })
    
    if not response then
        return nil, err or "No response from server"
    end
    
    if response.success then
        return response.keys or {}, nil
    else
        return nil, response.error or "Unknown error"
    end
end

return unicard
