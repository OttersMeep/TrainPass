-- Start Server Manager
-- Manages machine provisioning and key distribution

print("Starting Server Manager...")
print("")
print("This server handles:")
print("  - Batch machine provisioning")
print("  - Keypair generation")
print("  - Gateway registration")
print("  - Automatic key distribution")
print("")
print("Requirements:")
print("  - Wired modem (connected to server network)")
print("  - Disk drive on RIGHT side")
print("  - Dropper/Dispenser on TOP (dispenses computers)")
print("  - Hopper lock on BOTTOM (ejects computers)")
print("")

-- Check for disk drive
if not peripheral.isPresent("right") or peripheral.getType("right") ~= "drive" then
    print("WARNING: No disk drive found on right side!")
    print("Please attach a disk drive.")
    print("")
end

-- Check for ecc.lua
if not fs.exists("ecc.lua") then
    error("ecc.lua not found! Cannot copy to machines.")
end

-- Check for client files
local warnings = {}
if not fs.exists("deposit_machine_client.lua") then
    table.insert(warnings, "deposit_machine_client.lua not found")
end
if not fs.exists("payment_terminal.lua") then
    table.insert(warnings, "payment_terminal.lua not found")
end

if #warnings > 0 then
    print("WARNING: Missing client files:")
    for _, warning in ipairs(warnings) do
        print("  - " .. warning)
    end
    print("Some provisioning operations may fail.")
    print("")
end

print("Hardware Setup:")
print("  TOP: Dropper with Advanced Computers → hopper → disk drive")
print("  BOTTOM: Locked hopper (for ejecting)")
print("")
print("Usage:")
print("  register <deposit|terminal> [number]")
print("    Examples:")
print("      register deposit       - Provision 1 deposit machine")
print("      register deposit 10    - Provision 10 deposit machines")
print("      register terminal 5    - Provision 5 payment terminals")
print("")
print("Press any key to start...")
read()

-- Run server manager
dofile("server_manager.lua")
