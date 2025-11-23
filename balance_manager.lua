-- Balance Manager Server - Account & Balance Management
-- Manages accounts, balances, and payment card UUIDs
-- Connected via wired modem to other servers

local balanceManager = {}

-- Database
balanceManager.accounts = {}
balanceManager.cardToAccount = {} -- UUID -> accountId mapping
balanceManager.accountCounter = 0

-- Wired modem
balanceManager.modem = nil
balanceManager.serverChannel = 101 -- Internal server channel
balanceManager.ledgerChannel = 100
balanceManager.keyGenChannel = 102

-- Configuration
balanceManager.config = {
    minBalance = 0,
    maxBalance = 999999,
    defaultVendorPrice = 10,
    enableOverdraft = false
}

-- Initialize
function balanceManager.init()
    -- Find wired modem
    balanceManager.modem = peripheral.find("modem", function(name, modem)
        return modem.isWireless() == false
    end)
    
    if not balanceManager.modem then
        error("No wired modem found!")
    end
    
    balanceManager.modem.open(balanceManager.serverChannel)
    print("Balance Manager initialized on channel " .. balanceManager.serverChannel)
end

-- Generate unique account ID
function balanceManager.generateAccountId(username)
    balanceManager.accountCounter = balanceManager.accountCounter + 1
    local ecc = require("ecc")
    local hash = ecc.sha256.digest(username .. os.epoch("utc") .. balanceManager.accountCounter)
    return hash:toHex():sub(1, 16)
end

-- Create account
function balanceManager.createAccount(username, publicKey, initialBalance, cardUUIDs)
    print("DEBUG [Balance Manager]: createAccount called")
    print("  username: " .. tostring(username))
    print("  publicKey: " .. tostring(publicKey))
    print("  initialBalance: " .. tostring(initialBalance))
    print("  cardUUIDs: " .. textutils.serialize(cardUUIDs))
    
    initialBalance = initialBalance or 0
    cardUUIDs = cardUUIDs or {}
    
    if not username or username == "" then
        print("DEBUG [Balance Manager]: Username required - returning error")
        return nil, "Username required"
    end
    
    -- Check username uniqueness
    for _, account in pairs(balanceManager.accounts) do
        if account.username == username then
            print("DEBUG [Balance Manager]: Username already exists - returning error")
            return nil, "Username already exists"
        end
    end
    
    local accountId = balanceManager.generateAccountId(username)
    print("DEBUG [Balance Manager]: Generated accountId: " .. accountId)
    
    balanceManager.accounts[accountId] = {
        accountId = accountId,
        username = username,
        publicKey = publicKey,
        balance = initialBalance,
        cardUUIDs = cardUUIDs, -- List of valid payment card UUIDs
        createdAt = os.epoch("utc"),
        active = true
    }
    
    print("DEBUG [Balance Manager]: Account created in memory")
    
    -- Register card UUIDs
    for _, uuid in ipairs(cardUUIDs) do
        balanceManager.cardToAccount[uuid] = accountId
    end
    
    -- Log to ledger
    balanceManager.logToLedger({
        accountId = accountId,
        type = "ACCOUNT_CREATE",
        amount = initialBalance,
        metadata = { username = username }
    })
    
    print("DEBUG [Balance Manager]: Returning accountId: " .. accountId)
    return accountId, nil
end

-- Add payment card to account
function balanceManager.addCard(accountId, cardUUID)
    local account = balanceManager.accounts[accountId]
    if not account then
        return false, "Account not found"
    end
    
    -- Check if card already registered
    if balanceManager.cardToAccount[cardUUID] then
        return false, "Card already registered to another account"
    end
    
    table.insert(account.cardUUIDs, cardUUID)
    balanceManager.cardToAccount[cardUUID] = accountId
    
    return true, nil
end

-- Remove payment card from account
function balanceManager.removeCard(accountId, cardUUID)
    local account = balanceManager.accounts[accountId]
    if not account then
        return false, "Account not found"
    end
    
    -- Remove from account
    for i, uuid in ipairs(account.cardUUIDs) do
        if uuid == cardUUID then
            table.remove(account.cardUUIDs, i)
            break
        end
    end
    
    -- Remove from mapping
    balanceManager.cardToAccount[cardUUID] = nil
    
    return true, nil
end

-- Get account by card UUID
function balanceManager.getAccountByCard(cardUUID)
    local accountId = balanceManager.cardToAccount[cardUUID]
    if accountId then
        return balanceManager.accounts[accountId]
    end
    return nil
end

-- Get account by username
function balanceManager.getAccountByUsername(username)
    for _, account in pairs(balanceManager.accounts) do
        if account.username == username then
            return account
        end
    end
    return nil
end

-- Get account by ID
function balanceManager.getAccount(accountId)
    return balanceManager.accounts[accountId]
end

-- Deposit funds
function balanceManager.deposit(accountId, amount, depositMachineId, signature)
    if amount <= 0 then
        return nil, "Amount must be positive"
    end
    
    local account = balanceManager.getAccount(accountId)
    if not account then
        return nil, "Account not found"
    end
    
    if not account.active then
        return nil, "Account is inactive"
    end
    
    if account.balance + amount > balanceManager.config.maxBalance then
        return nil, "Deposit would exceed maximum balance"
    end
    
    -- Update balance
    account.balance = account.balance + amount
    
    -- Log to ledger
    local txId = balanceManager.logToLedger({
        accountId = accountId,
        type = "DEPOSIT",
        amount = amount,
        vendor = depositMachineId,
        vendorType = "DEPOSIT_MACHINE",
        metadata = { signature = signature }
    })
    
    return txId, account.balance, nil
end

-- Charge vendor (payment card transaction)
function balanceManager.chargeVendor(accountId, vendorId, vendorType, amount, metadata)
    if amount <= 0 then
        return nil, "Amount must be positive"
    end
    
    local account = balanceManager.getAccount(accountId)
    if not account then
        return nil, "Account not found"
    end
    
    if not account.active then
        return nil, "Account is inactive"
    end
    
    if account.balance < amount then
        return nil, "Insufficient funds"
    end
    
    -- Charge
    account.balance = account.balance - amount
    
    -- Log to ledger
    local txId = balanceManager.logToLedger({
        accountId = accountId,
        type = "VENDOR_CHARGE",
        amount = -amount,
        vendor = vendorId,
        vendorType = vendorType,
        metadata = metadata
    })
    
    return txId, account.balance, nil
end

-- Check if can afford
function balanceManager.canAfford(accountId, amount)
    local account = balanceManager.getAccount(accountId)
    if not account or not account.active then
        return false, 0
    end
    
    return account.balance >= amount, account.balance
end

-- Transfer between accounts
function balanceManager.transfer(fromAccountId, toAccountId, amount, memo)
    if amount <= 0 then
        return nil, "Amount must be positive"
    end
    
    local fromAccount = balanceManager.getAccount(fromAccountId)
    local toAccount = balanceManager.getAccount(toAccountId)
    
    if not fromAccount then return nil, "Source account not found" end
    if not toAccount then return nil, "Destination account not found" end
    if not fromAccount.active then return nil, "Source account is inactive" end
    if not toAccount.active then return nil, "Destination account is inactive" end
    
    if fromAccount.balance < amount then
        return nil, "Insufficient funds"
    end
    
    -- Transfer
    fromAccount.balance = fromAccount.balance - amount
    toAccount.balance = toAccount.balance + amount
    
    -- Log both sides
    local txId = balanceManager.logToLedger({
        accountId = fromAccountId,
        type = "TRANSFER_OUT",
        amount = -amount,
        vendor = toAccountId,
        vendorType = "TRANSFER",
        metadata = { memo = memo, toAccount = toAccountId }
    })
    
    balanceManager.logToLedger({
        accountId = toAccountId,
        type = "TRANSFER_IN",
        amount = amount,
        vendor = fromAccountId,
        vendorType = "TRANSFER",
        metadata = { memo = memo, fromAccount = fromAccountId, linkedTx = txId }
    })
    
    return txId, fromAccount.balance, nil
end

-- Log transaction to ledger server
function balanceManager.logToLedger(transaction)
    local request = {
        action = "LOG",
        transaction = transaction
    }
    
    balanceManager.modem.transmit(
        balanceManager.ledgerChannel,
        balanceManager.serverChannel,
        textutils.serialize(request)
    )
    
    -- Wait for response
    local timer = os.startTimer(5)
    while true do
        local event, side, channel, replyChannel, message = os.pullEvent()
        if event == "modem_message" and channel == balanceManager.serverChannel then
            local response = textutils.unserialize(message)
            if response and response.success then
                os.cancelTimer(timer)
                return response.transactionId
            end
        elseif event == "timer" and side == timer then
            return nil -- Timeout
        end
    end
end

-- Handle incoming requests
function balanceManager.handleRequest(message)
    local request = textutils.unserialize(message)
    if not request then return nil end
    
    if request.action == "CREATE_ACCOUNT" then
        local accountId, err = balanceManager.createAccount(
            request.username,
            request.publicKey,
            request.initialBalance,
            request.cardUUIDs
        )
        return {
            success = accountId ~= nil,
            accountId = accountId,
            error = err
        }
        
    elseif request.action == "GET_ACCOUNT" then
        local account = balanceManager.getAccount(request.accountId)
        return {
            success = account ~= nil,
            account = account
        }
        
    elseif request.action == "GET_ACCOUNT_BY_CARD" then
        local account = balanceManager.getAccountByCard(request.cardUUID)
        return {
            success = account ~= nil,
            account = account
        }
        
    elseif request.action == "GET_ACCOUNT_BY_USERNAME" then
        local account = balanceManager.getAccountByUsername(request.username)
        return {
            success = account ~= nil,
            account = account
        }
        
    elseif request.action == "ADD_CARD" then
        local success, err = balanceManager.addCard(request.accountId, request.cardUUID)
        return {
            success = success,
            error = err
        }
        
    elseif request.action == "REMOVE_CARD" then
        local success, err = balanceManager.removeCard(request.accountId, request.cardUUID)
        return {
            success = success,
            error = err
        }
        
    elseif request.action == "DEPOSIT" then
        local txId, balance, err = balanceManager.deposit(
            request.accountId,
            request.amount,
            request.depositMachineId,
            request.signature
        )
        return {
            success = txId ~= nil,
            transactionId = txId,
            newBalance = balance,
            error = err
        }
        
    elseif request.action == "CHARGE_VENDOR" then
        local txId, balance, err = balanceManager.chargeVendor(
            request.accountId,
            request.vendorId,
            request.vendorType,
            request.amount,
            request.metadata
        )
        return {
            success = txId ~= nil,
            transactionId = txId,
            newBalance = balance,
            error = err
        }
        
    elseif request.action == "CAN_AFFORD" then
        local canAfford, balance = balanceManager.canAfford(request.accountId, request.amount)
        return {
            success = true,
            canAfford = canAfford,
            balance = balance
        }
        
    elseif request.action == "TRANSFER" then
        local txId, balance, err = balanceManager.transfer(
            request.fromAccountId,
            request.toAccountId,
            request.amount,
            request.memo
        )
        return {
            success = txId ~= nil,
            transactionId = txId,
            newBalance = balance,
            error = err
        }
    end
    
    return { success = false, error = "Unknown action" }
end

-- Save to disk
function balanceManager.save(filename)
    filename = filename or "balance_manager.dat"
    local file = fs.open(filename, "w")
    if not file then return false end
    
    file.write(textutils.serialize({
        accounts = balanceManager.accounts,
        cardToAccount = balanceManager.cardToAccount,
        accountCounter = balanceManager.accountCounter
    }))
    file.close()
    return true
end

-- Load from disk
function balanceManager.load(filename)
    filename = filename or "balance_manager.dat"
    if not fs.exists(filename) then return false end
    
    local file = fs.open(filename, "r")
    if not file then return false end
    
    local data = textutils.unserialize(file.readAll())
    file.close()
    
    if data then
        balanceManager.accounts = data.accounts or {}
        balanceManager.cardToAccount = data.cardToAccount or {}
        balanceManager.accountCounter = data.accountCounter or 0
        return true
    end
    
    return false
end

-- Main server loop
function balanceManager.run()
    print("Balance Manager running...")
    balanceManager.load()
    
    local lastSave = os.epoch("utc")
    
    while true do
        local event, side, channel, replyChannel, message = os.pullEvent("modem_message")
        
        local response = balanceManager.handleRequest(message)
        if response then
            balanceManager.modem.transmit(replyChannel, channel, textutils.serialize(response))
        end
        
        -- Auto-save every 5 minutes
        if os.epoch("utc") - lastSave > 300000 then
            balanceManager.save()
            lastSave = os.epoch("utc")
        end
    end
end

return balanceManager
