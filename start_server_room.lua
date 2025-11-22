-- Server Room Startup Script
-- Starts all four servers in the server room
-- Run this on the main control computer

print("================================")
print("  TrainPass Banking System")
print("  Server Room Initialization")
print("================================")
print()

-- Configuration
local LEDGER_ID = 1
local BALANCE_MANAGER_ID = 2
local KEY_GENERATOR_ID = 3
local GATEWAY_ID = 4

-- Helper function to send startup command to computer
local function startupServer(computerId, serverName, command)
    print("Starting " .. serverName .. " on computer " .. computerId .. "...")
    
    -- In a real setup, you'd use rednet or command computers
    -- For now, show instructions
    print("  -> On computer " .. computerId .. ", run: " .. command)
end

print("Starting servers...")
print()

startupServer(LEDGER_ID, "Ledger Server", "lua ledger_server.lua")
sleep(0.5)

startupServer(BALANCE_MANAGER_ID, "Balance Manager", "lua balance_manager.lua")
sleep(0.5)

startupServer(KEY_GENERATOR_ID, "Key Generator", "lua key_generator.lua")
sleep(0.5)

startupServer(GATEWAY_ID, "Gateway", "lua gateway.lua")
sleep(0.5)

print()
print("================================")
print("Server initialization complete!")
print()
print("Server Configuration:")
print("  Ledger Server:      Channel 100")
print("  Balance Manager:    Channel 101")
print("  Key Generator:      Channel 102")
print("  Gateway (Wireless): Channel 1000")
print()
print("Wired Network:")
print("  All servers connected via wired modems")
print()
print("Wireless Network:")
print("  Gateway handles all external communication")
print("  Deposit machines: Sign with private keys")
print("  Payment terminals: Send card UUIDs")
print()
print("================================")
