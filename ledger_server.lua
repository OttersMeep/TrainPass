-- Ledger Server - Transaction Logging
-- Records all transactions for audit trail
-- Connected via wired modem to other servers

local ledger = {}

-- Database
ledger.transactions = {}
ledger.transactionIndex = {}
ledger.counter = 0

-- Wired modem
ledger.modem = nil
ledger.serverChannel = 100 -- Internal server channel

-- Initialize ledger
function ledger.init()
    -- Find wired modem
    ledger.modem = peripheral.find("modem", function(name, modem)
        return modem.isWireless() == false
    end)
    
    if not ledger.modem then
        error("No wired modem found!")
    end
    
    ledger.modem.open(ledger.serverChannel)
    print("Ledger server initialized on channel " .. ledger.serverChannel)
end

-- Log a transaction
-- @param transaction: Transaction data
-- @return transactionId
function ledger.logTransaction(transaction)
    ledger.counter = ledger.counter + 1
    
    local entry = {
        id = ledger.counter,
        timestamp = os.epoch("utc"),
        accountId = transaction.accountId,
        type = transaction.type,
        amount = transaction.amount,
        vendor = transaction.vendor,
        vendorType = transaction.vendorType,
        metadata = transaction.metadata or {},
        hash = ledger.hashTransaction(transaction)
    }
    
    table.insert(ledger.transactions, entry)
    ledger.transactionIndex[entry.id] = entry
    
    return entry.id
end

-- Hash transaction for integrity
function ledger.hashTransaction(transaction)
    local ecc = require("ecc")
    local data = textutils.serialize(transaction)
    return ecc.sha256.digest(data):toHex()
end

-- Query transactions by account
function ledger.queryByAccount(accountId, limit)
    limit = limit or 50
    local results = {}
    
    for i = #ledger.transactions, 1, -1 do
        if ledger.transactions[i].accountId == accountId then
            table.insert(results, ledger.transactions[i])
            if #results >= limit then
                break
            end
        end
    end
    
    return results
end

-- Query transactions by vendor
function ledger.queryByVendor(vendorId, limit)
    limit = limit or 50
    local results = {}
    
    for i = #ledger.transactions, 1, -1 do
        if ledger.transactions[i].vendor == vendorId then
            table.insert(results, ledger.transactions[i])
            if #results >= limit then
                break
            end
        end
    end
    
    return results
end

-- Get transaction by ID
function ledger.getTransaction(transactionId)
    return ledger.transactionIndex[transactionId]
end

-- Handle incoming requests
function ledger.handleRequest(message)
    local request = textutils.unserialize(message)
    if not request then return nil end
    
    if request.action == "LOG" then
        local txId = ledger.logTransaction(request.transaction)
        return {
            success = true,
            transactionId = txId
        }
    elseif request.action == "QUERY_ACCOUNT" then
        local txs = ledger.queryByAccount(request.accountId, request.limit)
        return {
            success = true,
            transactions = txs
        }
    elseif request.action == "QUERY_VENDOR" then
        local txs = ledger.queryByVendor(request.vendorId, request.limit)
        return {
            success = true,
            transactions = txs
        }
    elseif request.action == "GET" then
        local tx = ledger.getTransaction(request.transactionId)
        return {
            success = true,
            transaction = tx
        }
    end
    
    return { success = false, error = "Unknown action" }
end

-- Save ledger to disk
function ledger.save(filename)
    filename = filename or "ledger.dat"
    local file = fs.open(filename, "w")
    if not file then return false end
    
    -- Only save transactions array, rebuild index on load
    file.write(textutils.serialize({
        transactions = ledger.transactions,
        counter = ledger.counter
    }))
    file.close()
    return true
end

-- Load ledger from disk
function ledger.load(filename)
    filename = filename or "ledger.dat"
    if not fs.exists(filename) then return false end
    
    local file = fs.open(filename, "r")
    if not file then return false end
    
    local data = textutils.unserialize(file.readAll())
    file.close()
    
    if data then
        ledger.transactions = data.transactions or {}
        ledger.counter = data.counter or 0
        
        -- Rebuild transactionIndex from transactions array
        ledger.transactionIndex = {}
        for _, transaction in ipairs(ledger.transactions) do
            ledger.transactionIndex[transaction.id] = transaction
        end
        return true
    end
    
    return false
end

-- Main server loop
function ledger.run()
    print("Ledger server running...")
    ledger.load()
    
    local lastSave = os.epoch("utc")
    
    while true do
        local event, side, channel, replyChannel, message = os.pullEvent("modem_message")
        
        local response = ledger.handleRequest(message)
        if response then
            ledger.modem.transmit(replyChannel, channel, textutils.serialize(response))
        end
        
        -- Auto-save every 5 minutes
        if os.epoch("utc") - lastSave > 300000 then
            ledger.save()
            lastSave = os.epoch("utc")
        end
    end
end

ledger.init()
ledger.run()

return ledger
