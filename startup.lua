-- TrainPass Universal Startup Script
-- Detects which component is present and launches the appropriate program

term.clear()
term.setCursorPos(1, 1)
print("TrainPass System Starting...")

-- Detect which component this is
if fs.exists("deposit_machine_client.lua") then
    print("Detected: Deposit Machine")
    
    -- Load configuration to check testing mode
    local config = {testing = true}
    if fs.exists("machine_config.lua") then
        local machineConfig = dofile("machine_config.lua")
        if machineConfig and machineConfig.testing ~= nil then
            config.testing = machineConfig.testing
        end
    end
    print(config.testing)
    
    while true do
        -- Delete any existing authentication flag
        if fs.exists(".admin_authenticated") then
            fs.delete(".admin_authenticated")
        end
        
        -- Run the deposit machine client with error handling
        local success, err = pcall(function()
            shell.run("deposit_machine_client.lua")
        end)
        
        -- Check if admin authenticated
        if fs.exists(".admin_authenticated") then
            -- Admin authenticated - clean up and exit to shell
            fs.delete(".admin_authenticated")
            term.clear()
            term.setCursorPos(1, 1)
            print("Admin authenticated. Exiting...")
            break
        elseif not success then
            -- Program exited with error
            term.clear()
            term.setCursorPos(1, 1)
            print("Error occurred:")
            print(tostring(err))
            
            if config.testing then
                -- Testing mode - don't shutdown, exit to shell
                print("")
                print("Testing mode enabled - not shutting down")
                break
            else
                -- Production mode - shutdown on error
                print("")
                print("Shutting down computer...")
                os.shutdown()
            end
        else
            -- Unauthorized termination - shutdown computer
            term.clear()
            term.setCursorPos(1, 1)
            print("Unauthorized termination detected!")
            print("Shutting down computer...")
            os.shutdown()
        end
    end

elseif fs.exists("ledger_server.lua") then
    print("Detected: Ledger Server")
    shell.run("ledger_server.lua")

elseif fs.exists("gateway.lua") then
    print("Detected: Gateway")
    shell.run("gateway.lua")

elseif fs.exists("balance_manager.lua") then
    print("Detected: Balance Manager")
    shell.run("balance_manager.lua")

elseif fs.exists("server_manager.lua") then
    print("Detected: Server Manager")
    shell.run("server_manager.lua")

elseif fs.exists("key_generator.lua") then
    print("Detected: Key Generator")
    shell.run("key_generator.lua")

elseif fs.exists("account_portal.lua") then
    print("Detected: Account Portal")
    shell.run("account_portal.lua")

elseif fs.exists("payment_terminal.lua") then
    print("Detected: Payment Terminal")
    shell.run("payment_terminal.lua")

else
    print("ERROR: No TrainPass component detected!")
    print("Unable to determine which program to run.")
    print("")
    print("Place this startup file in a folder with one of:")
    print("  - deposit_machine_client.lua")
    print("  - ledger_server.lua")
    print("  - gateway.lua")
    print("  - balance_manager.lua")
    print("  - server_manager.lua")
    print("  - key_generator.lua")
    print("  - account_portal.lua")
    print("  - payment_terminal.lua")
end
