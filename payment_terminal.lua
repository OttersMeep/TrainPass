-- Payment Terminal for TrainPass Banking System
-- Processes card payments via magstripe cards

local terminal = {}

-- Configuration (will be overridden by machine_config.lua if it exists)
terminal.config = {
    vendorId = "TERMINAL_001",
    vendorType = "TERMINAL",
    defaultAmount = 10,
    location = "Payment Terminal",
    gatewayChannel = 1000,
    responseChannel = nil  -- Will be set dynamically
}

-- Load configuration from machine_config.lua if it exists
if fs.exists("machine_config.lua") then
    local machineConfig = dofile("machine_config.lua")
    if machineConfig then
        terminal.config.vendorId = machineConfig.vendorId or terminal.config.vendorId
        terminal.config.vendorType = machineConfig.vendorType or terminal.config.vendorType
        terminal.config.defaultAmount = machineConfig.defaultAmount or terminal.config.defaultAmount
        terminal.config.location = machineConfig.location or terminal.config.location
        terminal.config.gatewayChannel = machineConfig.gatewayChannel or terminal.config.gatewayChannel
    end
end

-- Find wireless modem
local modem = peripheral.find("modem", function(name, modem)
    return modem.isWireless()
end)

if not modem then
    error("No wireless modem found! Payment terminal requires wireless modem.")
end

-- Generate unique response channel
terminal.config.responseChannel = 2000 + math.random(1, 8999)
modem.open(terminal.config.responseChannel)

print("=== TrainPass Payment Terminal ===")
print("Vendor ID: " .. terminal.config.vendorId)
print("Type: " .. terminal.config.vendorType)
print("Location: " .. terminal.config.location)
print("Default Amount: " .. terminal.config.defaultAmount)
print("")

-- Process payment
function terminal.processPayment(cardUUID, amount)
    amount = amount or terminal.config.defaultAmount
    
    print("Processing payment...")
    print("Card: " .. cardUUID)
    print("Amount: " .. amount)
    
    -- Create payment packet
    local packet = {
        data = {
            requestType = "CARD_PAYMENT",
            cardUUID = cardUUID,
            vendorId = terminal.config.vendorId,
            vendorType = terminal.config.vendorType,
            amount = amount,
            metadata = {
                location = terminal.config.location,
                timestamp = os.epoch("utc")
            }
        },
        timestamp = os.epoch("utc")
    }
    
    -- Send to gateway
    modem.transmit(
        terminal.config.gatewayChannel,
        terminal.config.responseChannel,
        textutils.serialize(packet)
    )
    
    -- Wait for response
    local timer = os.startTimer(5)
    while true do
        local event, p1, p2, p3, p4, p5 = os.pullEvent()
        
        if event == "modem_message" and p2 == terminal.config.responseChannel then
            os.cancelTimer(timer)
            local response = textutils.unserialize(p4)
            
            if response then
                if response.success then
                    print("SUCCESS!")
                    print("New balance: " .. response.balance)
                    return true, response.balance
                else
                    print("DECLINED: " .. (response.error or "Unknown error"))
                    return false, response.error
                end
            end
        elseif event == "timer" and p1 == timer then
            print("ERROR: Payment timeout")
            return false, "Timeout"
        end
    end
end

-- Wait for card swipe (manual input for testing)
function terminal.waitForCardSwipe()
    print("")
    print("=== Ready for Payment ===")
    print("Enter card UUID (or 'q' to quit):")
    write("> ")
    local uuid = read()
    
    if uuid == "q" or uuid == "quit" or uuid == "" then
        return nil
    end
    
    return uuid
end

-- Get custom amount
function terminal.getAmount()
    write("Amount (default " .. terminal.config.defaultAmount .. "): ")
    local input = read()
    
    if input == "" then
        return terminal.config.defaultAmount
    end
    
    local amount = tonumber(input)
    if amount and amount > 0 then
        return amount
    else
        print("Invalid amount, using default")
        return terminal.config.defaultAmount
    end
end

-- Main loop
function terminal.run()
    print("Terminal ready. Waiting for card swipes...")
    print("")
    
    while true do
        local cardUUID = terminal.waitForCardSwipe()
        
        if not cardUUID then
            print("Shutting down...")
            break
        end
        
        local amount = terminal.getAmount()
        
        local success, result = terminal.processPayment(cardUUID, amount)
        
        if success then
            -- Success feedback
            term.setTextColor(colors.green)
            print("✓ Payment approved!")
            term.setTextColor(colors.white)
            sleep(2)
        else
            -- Failure feedback
            term.setTextColor(colors.red)
            print("✗ Payment failed")
            term.setTextColor(colors.white)
            sleep(2)
        end
    end
end

-- Start the terminal
terminal.run()
