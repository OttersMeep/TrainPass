-- Server Management and Provisioning System
-- Handles registration of deposit machines and key distribution

local serverManager = {}

-- Configuration
serverManager.config = {
    keyGenChannel = 102,
    gatewayChannel = 105,  -- For registering with gateway
    diskSide = "right",  -- Side where disk drive is attached
    responseChannel = 103,
    dataFile = "server_manager.dat",
    -- Batch deployment redstone configuration
    dispenserSide = "top",     -- Side with dropper/dispenser (dispenses computer into disk drive)
    ejectorSide = "bottom"     -- Side with hopper lock (ejects computer from disk drive)
}

-- Data storage
serverManager.registeredMachines = {}

-- Find wired modem
local modem = peripheral.find("modem", function(name, modem)
    return modem.isWireless() == false
end)

if not modem then
    error("No wired modem found! Server manager requires wired modem.")
end

-- Open channels
modem.open(serverManager.config.responseChannel)

print("=== Server Manager Started ===")
print("Wired modem: " .. peripheral.getName(modem))
print("Listening on channel: " .. serverManager.config.responseChannel)
print("")

-- Save data to disk
function serverManager.save()
    local file = fs.open(serverManager.config.dataFile, "w")
    if file then
        file.write(textutils.serialize({
            registeredMachines = serverManager.registeredMachines
        }))
        file.close()
        return true
    end
    return false
end

-- Load data from disk
function serverManager.load()
    if fs.exists(serverManager.config.dataFile) then
        local file = fs.open(serverManager.config.dataFile, "r")
        if file then
            local data = textutils.unserialize(file.readAll())
            file.close()
            if data then
                serverManager.registeredMachines = data.registeredMachines or {}
                print("Loaded " .. #serverManager.registeredMachines .. " registered machines")
                return true
            end
        end
    end
    return false
end

-- Request keypair from key generator
function serverManager.requestKeypair()
    print("Requesting keypair from key generator...")
    print("  Sending to channel: " .. serverManager.config.keyGenChannel)
    print("  Reply channel: " .. serverManager.config.responseChannel)
    
    modem.transmit(serverManager.config.keyGenChannel, serverManager.config.responseChannel, textutils.serialize({
        action = "GENERATE_KEYPAIR",
        timestamp = os.epoch("utc")
    }))
    
    -- Wait for response
    local timer = os.startTimer(10)
    while true do
        local event, side, channel, replyChannel, message, distance = os.pullEvent()
        
        if event == "modem_message" and channel == serverManager.config.responseChannel then
            print("  Received response on channel " .. channel)
            local response = textutils.unserialize(message)
            print("  Response: " .. textutils.serialize(response))
            if response and response.success then
                os.cancelTimer(timer)
                return response.publicKey, response.privateKey
            elseif response and not response.success then
                os.cancelTimer(timer)
                return nil, nil, response.error or "Unknown error"
            end
        elseif event == "timer" and side == timer then
            return nil, nil, "Timeout waiting for keypair"
        end
    end
end

-- Generate machine ID using UUID
function serverManager.generateMachineId(machineType)
    -- Generate a random UUID (version 4 style)
    local template = 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'
    local uuid = string.gsub(template, '[xy]', function(c)
        local v = (c == 'x') and math.random(0, 0xf) or math.random(8, 0xb)
        return string.format('%x', v)
    end)
    
    return uuid
end

-- Request gateway's public key for encryption
function serverManager.getGatewayPublicKey()
    print("Requesting gateway public key...")
    
    modem.transmit(serverManager.config.gatewayChannel, serverManager.config.responseChannel, textutils.serialize({
        requestType = "GET_PUBLIC_KEY",
        timestamp = os.epoch("utc")
    }))
    
    -- Wait for response
    local timer = os.startTimer(10)
    while true do
        local event, side, channel, replyChannel, message, distance = os.pullEvent()
        
        if event == "modem_message" and channel == serverManager.config.responseChannel then
            local response = textutils.unserialize(message)
            if response and response.success and response.publicKey then
                os.cancelTimer(timer)
                print("  Received gateway public key")
                return response.publicKey
            elseif response and not response.success then
                os.cancelTimer(timer)
                return nil, response.error or "Unknown error"
            end
        elseif event == "timer" and side == timer then
            return nil, "Timeout waiting for gateway public key"
        end
    end
end

-- Register machine with gateway
function serverManager.registerWithGateway(machineId, publicKey)
    print("Registering " .. machineId .. " with gateway...")
    
    modem.transmit(serverManager.config.gatewayChannel, serverManager.config.responseChannel, textutils.serialize({
        requestType = "REGISTER_MACHINE",
        machineId = machineId,
        publicKey = publicKey,
        timestamp = os.epoch("utc")
    }))
    
    -- Wait for response
    local timer = os.startTimer(10)
    while true do
        local event, side, channel, replyChannel, message, distance = os.pullEvent()
        
        if event == "modem_message" and channel == serverManager.config.responseChannel then
            local response = textutils.unserialize(message)
            if response then
                os.cancelTimer(timer)
                if response.success then
                    return true, nil
                else
                    return false, response.error
                end
            end
        elseif event == "timer" and side == timer then
            return false, "Timeout waiting for gateway"
        end
    end
end

-- Write configuration to disk
function serverManager.writeToDisk(machineId, privateKey, machineType, config)
    local diskSide = serverManager.config.diskSide
    
    -- Check if disk drive exists
    if not peripheral.isPresent(diskSide) then
        return false, "No disk drive found on " .. diskSide .. " side"
    end
    
    -- Check if disk is inserted
    if not disk.isPresent(diskSide) then
        return false, "No disk inserted in drive"
    end
    
    print("  Getting mount path for disk on " .. diskSide)
    local mountPath = disk.getMountPath(diskSide)
    if not mountPath then
        return false, "Could not get disk mount path"
    end
    
    print("  Writing to disk at: " .. mountPath)
    
    -- Copy ecc.lua library
    if fs.exists("ecc.lua") then
        fs.copy("ecc.lua", fs.combine(mountPath, "ecc.lua"))
    else
        return false, "ecc.lua not found on server manager"
    end

        if fs.exists("basalt.lua") then
        fs.copy("basalt.lua", fs.combine(mountPath, "basalt.lua"))
    else
        return false, "basalt.lua not found on server manager"
    end
    
    -- Check if there's a template machine_config.lua to use
    local useTemplate = fs.exists("machine_config_template.lua")
    
    if useTemplate then
        -- Copy template and modify it
        local template = fs.open("machine_config_template.lua", "r")
        local configFile = fs.open(fs.combine(mountPath, "machine_config.lua"), "w")
        
        if not template or not configFile then
            if template then template.close() end
            if configFile then configFile.close() end
            return false, "Could not read template or create config file"
        end
        
        -- Read and modify template
        local templateContent = template.readAll()
        template.close()
        
        -- Serialize the private key (it's a byte table)
        local serializedPrivateKey = textutils.serialize(privateKey)
        local serializedGatewayPublicKey = textutils.serialize(config.gatewayPublicKey or {})
        
        -- Replace placeholders with actual values
        -- Use string format with %% to escape special pattern characters
        templateContent = templateContent:gsub("%%MACHINE_ID%%", machineId)
        templateContent = templateContent:gsub("%%PRIVATE_KEY%%", function() return serializedPrivateKey end)
        templateContent = templateContent:gsub("%%MACHINE_TYPE%%", machineType)
        templateContent = templateContent:gsub("%%GATEWAY_CHANNEL%%", tostring(config.gatewayChannel or 1000))
        templateContent = templateContent:gsub("%%GATEWAY_PUBLIC_KEY%%", function() return serializedGatewayPublicKey end)
        
        configFile.write(templateContent)
        configFile.close()
    else
        -- Create configuration file from scratch (old method)
        local configFile = fs.open(fs.combine(mountPath, "machine_config.lua"), "w")
        if not configFile then
            return false, "Could not create config file on disk"
        end
        
        configFile.writeLine("-- Machine Configuration")
        configFile.writeLine("-- Generated by Server Manager on " .. os.date("%Y-%m-%d %H:%M:%S"))
        configFile.writeLine("")
        configFile.writeLine("return {")
        configFile.writeLine('    machineId = "' .. machineId .. '",')
        configFile.writeLine('    privateKey = ' .. textutils.serialize(privateKey) .. ',')
        configFile.writeLine('    machineType = "' .. machineType .. '",')
        
        -- Add additional config options
        if config then
            for key, value in pairs(config) do
                if type(value) == "string" then
                    configFile.writeLine('    ' .. key .. ' = "' .. value .. '",')
                elseif type(value) == "number" then
                    configFile.writeLine('    ' .. key .. ' = ' .. value .. ',')
                elseif type(value) == "boolean" then
                    configFile.writeLine('    ' .. key .. ' = ' .. tostring(value) .. ',')
                end
            end
        end
        
        configFile.writeLine("}")
        configFile.close()
    end
    
    -- Copy appropriate client file
    local clientFile = nil
    if machineType == "deposit" then
        clientFile = "deposit_machine_client.lua"
    elseif machineType == "terminal" then
        clientFile = "payment_terminal.lua"
    end
    
    if clientFile and fs.exists(clientFile) then
        fs.copy(clientFile, fs.combine(mountPath, clientFile))
    end
    
    -- Create startup file
    local startupFile = fs.open(fs.combine(mountPath, "startup.lua"), "w")
    if startupFile then
        startupFile.writeLine("-- Auto-generated startup file")
        startupFile.writeLine('print("Loading machine configuration...")')
        startupFile.writeLine('local config = dofile("machine_config.lua")')
        startupFile.writeLine('print("Machine ID: " .. config.machineId)')
        
        if clientFile then
            startupFile.writeLine('print("Starting ' .. machineType .. ' client...")')
            startupFile.writeLine('shell.run("' .. clientFile .. '")')
        end
        
        startupFile.close()
    end
    
    -- Create README
    local readmeFile = fs.open(fs.combine(mountPath, "README.txt"), "w")
    if readmeFile then
        readmeFile.writeLine("TrainPass Banking System - Machine Configuration")
        readmeFile.writeLine("===============================================")
        readmeFile.writeLine("")
        readmeFile.writeLine("Machine ID: " .. machineId)
        readmeFile.writeLine("Machine Type: " .. machineType)
        readmeFile.writeLine("Generated: " .. os.date("%Y-%m-%d %H:%M:%S"))
        readmeFile.writeLine("")
        readmeFile.writeLine("READY TO DEPLOY - All files configured!")
        readmeFile.writeLine("")
        readmeFile.writeLine("This computer has been pre-configured with:")
        readmeFile.writeLine("  - Unique machine ID and private key")
        readmeFile.writeLine("  - Client software")
        readmeFile.writeLine("  - Auto-start on boot")
        readmeFile.writeLine("")
        readmeFile.writeLine("Deployment steps:")
        readmeFile.writeLine("1. Place computer at target location")
        readmeFile.writeLine("2. Attach wireless modem")
        if machineType == "deposit" then
            readmeFile.writeLine("3. Attach chest for diamond deposits")
        end
        readmeFile.writeLine("3. Turn on computer - it will start automatically!")
        readmeFile.writeLine("")
        readmeFile.writeLine("IMPORTANT: Keep private key secure!")
        readmeFile.close()
    end
    
    -- Label the disk
    disk.setLabel(diskSide, machineId)
    
    return true, nil
end

-- Dispense computer into disk drive (pulse redstone on top)
function serverManager.dispenseComputer()
    redstone.setOutput(serverManager.config.dispenserSide, true)
    sleep(0.1)
    redstone.setOutput(serverManager.config.dispenserSide, false)
    sleep(0.5)  -- Wait for computer to fall into disk drive
end

-- Eject computer from disk drive (pulse redstone on bottom to unlock hopper)
function serverManager.ejectComputer()
    redstone.setOutput(serverManager.config.ejectorSide, false)  -- Unlock hopper
    sleep(0.5)  -- Wait for computer to fall through
    redstone.setOutput(serverManager.config.ejectorSide, true)   -- Lock hopper again
    sleep(0.3)
end

-- Wait for disk to be ready
function serverManager.waitForDisk()
    local timeout = 10  -- 10 seconds
    local start = os.epoch("utc")
    
    print("  Waiting for disk on side: " .. serverManager.config.diskSide)
    
    while not disk.isPresent(serverManager.config.diskSide) do
        if os.epoch("utc") - start > timeout * 1000 then
            return false, "Timeout waiting for disk"
        end
        sleep(0.1)
    end
    
    print("  Disk detected, waiting for mount...")
    
    -- Wait for disk to fully mount and get a valid mount path
    -- (Computers auto-mount when inserted, but it takes a moment)
    local mountPath = nil
    start = os.epoch("utc")
    while not mountPath do
        if os.epoch("utc") - start > timeout * 1000 then
            return false, "Timeout waiting for disk to mount"
        end
        sleep(0.1)
        mountPath = disk.getMountPath(serverManager.config.diskSide)
    end
    
    print("  Disk mounted at: " .. mountPath)
    return true
end

-- Provision new machine (full process)
function serverManager.provisionMachine(machineType, additionalConfig)
    -- Step 1: Generate machine ID
    local machineId = serverManager.generateMachineId(machineType)
    
    -- Step 2: Request keypair
    local publicKey, privateKey, err = serverManager.requestKeypair()
    if not publicKey then
        return false, "Failed to generate keypair: " .. (err or "unknown error")
    end
    
    -- Step 3: Get gateway's public key for encryption
    local gatewayPublicKey, err = serverManager.getGatewayPublicKey()
    if not gatewayPublicKey then
        return false, "Failed to get gateway public key: " .. (err or "unknown error")
    end
    
    -- Step 4: Register with gateway
    local success, err = serverManager.registerWithGateway(machineId, publicKey)
    if not success then
        print(success)
        return false, "Failed to register with gateway: " .. (err or "unknown error")
    end
    
    -- Step 5: Write to disk
    local config = additionalConfig or {}
    config.gatewayChannel = 1000
    config.gatewayPublicKey = gatewayPublicKey  -- Include gateway's public key
    
    success, err = serverManager.writeToDisk(machineId, privateKey, machineType, config)
    if not success then
        return false, "Failed to write to disk: " .. (err or "unknown error")
    end
    
    -- Step 6: Store in local registry
    table.insert(serverManager.registeredMachines, {
        machineId = machineId,
        machineType = machineType,
        publicKey = publicKey,
        registeredAt = os.epoch("utc"),
        status = "provisioned"
    })
    serverManager.save()
    
    return true, machineId
end

-- Batch provision machines
function serverManager.batchProvision(machineType, count, config)
    print("")
    print("=== Batch Provisioning ===")
    print("Type: " .. machineType)
    print("Count: " .. count)
    print("")
    
    local successCount = 0
    local failedCount = 0
    local machineIds = {}
    
    for i = 1, count do
        print("[" .. i .. "/" .. count .. "] Provisioning " .. machineType .. "...")
        
        -- Dispense computer into disk drive
        print("  Dispensing computer...")
        serverManager.dispenseComputer()
        
        -- Wait for disk to be ready
        local success, err = serverManager.waitForDisk()
        if not success then
            print("  ERROR: " .. err)
            failedCount = failedCount + 1
            -- Try to eject anyway
            serverManager.ejectComputer()
            sleep(1)
            goto continue
        end
        
        -- Provision the machine
        print("  Generating keypair...")
        print("  Registering with gateway...")
        print("  Writing to disk...")
        
        success, machineId = serverManager.provisionMachine(machineType, config)
        
        if success then
            print("  SUCCESS: " .. machineId)
            successCount = successCount + 1
            table.insert(machineIds, machineId)
        else
            print("  ERROR: " .. machineId)  -- machineId contains error message
            failedCount = failedCount + 1
        end
        
        -- Eject computer from disk drive
        print("  Ejecting computer...")
        serverManager.ejectComputer()
        
        sleep(0.5)  -- Brief pause between machines
        
        ::continue::
    end
    
    print("")
    print("=================================")
    print("Batch Provisioning Complete!")
    print("Success: " .. successCount)
    print("Failed: " .. failedCount)
    print("=================================")
    print("")
    
    if #machineIds > 0 then
        print("Provisioned machines:")
        for _, id in ipairs(machineIds) do
            print("  - " .. id)
        end
        print("")
    end
    
    return successCount, failedCount
end

-- List all registered machines
function serverManager.listMachines()
    print("")
    print("=== Registered Machines ===")
    if #serverManager.registeredMachines == 0 then
        print("No machines registered yet")
        return
    end
    
    for i, machine in ipairs(serverManager.registeredMachines) do
        print(i .. ". " .. machine.machineId .. " (" .. machine.machineType .. ")")
        print("   Public Key: " .. string.sub(machine.publicKey, 1, 32) .. "...")
        print("   Registered: " .. os.date("%Y-%m-%d %H:%M:%S", machine.registeredAt / 1000))
        print("   Status: " .. machine.status)
    end
    print("")
end

-- Parse command line arguments
function serverManager.parseCommand(input)
    local parts = {}
    for word in input:gmatch("%S+") do
        table.insert(parts, word)
    end
    return parts
end

-- Command line interface
function serverManager.cli()
    print("")
    print("=== Server Manager CLI ===")
    print("Commands:")
    print("  register <deposit|terminal> [number] - Provision machines (default 1)")
    print("  list - List registered machines")
    print("  help - Show this help")
    print("  exit - Exit program")
    print("")
    
    while true do
        write("> ")
        local input = read()
        
        if not input or input == "" then
            goto continue
        end
        
        local parts = serverManager.parseCommand(input)
        local command = parts[1]
        
        if command == "register" then
            local machineType = parts[2]
            local count = tonumber(parts[3]) or 1
            
            if not machineType then
                print("ERROR: Missing machine type. Usage: register <deposit|terminal> [number]")
                goto continue
            end
            
            if machineType ~= "deposit" and machineType ~= "terminal" then
                print("ERROR: Invalid machine type. Must be 'deposit' or 'terminal'")
                goto continue
            end
            
            if count < 1 or count > 100 then
                print("ERROR: Invalid count. Must be between 1 and 100")
                goto continue
            end
            
            -- Get default config based on type
            local config = {}
            if machineType == "deposit" then
                config.diamondValue = 100
                config.chestSide = "top"
            elseif machineType == "terminal" then
                config.vendorId = "AUTO_" .. os.epoch("utc")
                config.vendorType = "TERMINAL"
                config.defaultAmount = 10
                config.location = "Auto-provisioned"
            end
            
            -- Start batch provisioning
            serverManager.batchProvision(machineType, count, config)
            
        elseif command == "list" then
            serverManager.listMachines()
            
        elseif command == "help" then
            print("")
            print("Commands:")
            print("  register <deposit|terminal> [number]")
            print("    Provision one or more machines")
            print("    Examples:")
            print("      register deposit       - Provision 1 deposit machine")
            print("      register deposit 5     - Provision 5 deposit machines")
            print("      register terminal 10   - Provision 10 payment terminals")
            print("")
            print("  list")
            print("    Show all registered machines")
            print("")
            print("  help")
            print("    Show this help message")
            print("")
            print("  exit")
            print("    Exit the program")
            print("")
            
        elseif command == "exit" or command == "quit" then
            print("Shutting down server manager...")
            break
            
        else
            print("ERROR: Unknown command '" .. command .. "'. Type 'help' for usage.")
        end
        
        ::continue::
    end
end

-- Initialize
serverManager.load()

-- Lock the ejector hopper initially
redstone.setOutput(serverManager.config.ejectorSide, true)

-- Auto-save every 5 minutes
local function autoSave()
    while true do
        sleep(300)  -- 5 minutes
        serverManager.save()
        print("[" .. os.date("%H:%M:%S") .. "] Auto-saved")
    end
end

-- Start CLI with auto-save in parallel
parallel.waitForAny(
    function()
        serverManager.cli()
    end,
    autoSave
)

print("Server Manager stopped")
