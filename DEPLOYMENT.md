# TrainPass Banking System - Deployment Guide

Complete step-by-step instructions for deploying the distributed banking system in your Minecraft world with ComputerCraft.

## Prerequisites

### Hardware Requirements
- **4 Advanced Computers** (for server room)
- **4 Wired Modems** (one per server)
- **1 Wireless Modem** (for gateway)
- **Networking Cables** (to connect the 4 servers)
- **1+ Advanced Computers** (for each deposit machine)
- **1+ Wireless Modems** (for each deposit machine)
- **1+ Chests** (for diamond deposits)

### Software Requirements
- ComputerCraft or CC:Tweaked installed
- All `.lua` files from this repository

## Part 1: Server Room Setup

### Step 1.1: Physical Setup

1. **Build the server room** (secure location recommended)
   - Place 4 Advanced Computers in a row or square
   - Attach a **wired modem** to each computer
   - Connect all wired modems with **networking cables**
   - For the **Gateway computer**, attach a **wireless modem** in addition to the wired modem

2. **Label your computers** (recommended for identification):
   ```lua
   -- On each computer, run:
   label set "Ledger-Server"
   label set "Balance-Manager"
   label set "Key-Generator"
   label set "Gateway"
   ```

3. **Verify network connectivity**:
   ```lua
   -- On each computer, check modems:
   lua
   > peripheral.getNames()
   -- Should show wired modem (and wireless on gateway)
   ```

### Step 1.2: File Upload

Transfer these files to **ALL FOUR** server computers:
- `ecc.lua`

Then transfer the specific files to each server:

**Ledger Server:**
- `ledger_server.lua`
- `start_ledger.lua`

**Balance Manager:**
- `balance_manager.lua`
- `start_balance_manager.lua`

**Key Generator:**
- `key_generator.lua`
- `start_key_generator.lua`

**Gateway:**
- `gateway.lua`
- `start_gateway.lua`

#### File Transfer Methods

**Option A: Pastebin (easiest)**
```lua
-- On each computer:
pastebin get <code> ecc.lua
pastebin get <code> ledger_server.lua
pastebin get <code> start_ledger.lua
-- Repeat for each file
```

**Option B: Disk Drive**
1. Place files on a floppy disk in real computer
2. Insert disk in ComputerCraft disk drive
3. Copy files: `copy disk/filename.lua filename.lua`

**Option C: HTTP Download**
```lua
-- If you host files on a web server:
wget("http://yourserver.com/ecc.lua", "ecc.lua")
```

### Step 1.3: Configure Channels (Optional)

The default channels are:
- Ledger: 100
- Balance Manager: 101
- Key Generator: 102
- Gateway Wireless: 1000

If you need to change these, edit the channel numbers at the top of each file.

### Step 1.4: Start Servers (Important Order!)

Start servers in this order:

**1. Ledger Server (Computer 1)**
```lua
lua start_ledger.lua
```
Wait for: `"Ledger server started on channel 100"`

**2. Key Generator (Computer 3)**
```lua
lua start_key_generator.lua
```
Wait for: `"Key generator started on channel 102"`

**3. Balance Manager (Computer 2)**
```lua
lua start_balance_manager.lua
```
Wait for: `"Balance manager started on channel 101"`

**4. Gateway (Computer 4) - DON'T START YET!**

### Step 1.5: Configure Gateway

Before starting the gateway, you need to register any deposit machines you'll use.

Edit `start_gateway.lua`:

```lua
-- Find this section:
gateway.registeredMachines = {
    -- ["MACHINE_ID"] = "publicKey"
}

-- Add your deposit machines (you'll generate keys in Step 2):
gateway.registeredMachines = {
    ["DEPOSIT_001"] = "your-public-key-here",
    ["DEPOSIT_002"] = "another-public-key-here",
}
```

**NOTE:** You can add machines later by editing this file and restarting the gateway.

**5. Now start Gateway (Computer 4)**
```lua
lua start_gateway.lua
```
Wait for: `"Gateway started. Wireless on channel 1000, wired on channel 101"`

### Step 1.6: Verify Server Room

All four servers should now be running. Check each console for errors.

**Test connectivity between servers:**
```lua
-- On Balance Manager console, press Ctrl+T to stop
-- Then run a test:
lua
> dofile("balance_manager.lua")
-- Should load without errors
```

**Quick verification checklist:**
- [ ] All 4 servers show startup messages
- [ ] No error messages in any console
- [ ] Wired modems are connected (cables show connection)
- [ ] Gateway has both wired AND wireless modems
- [ ] Each server has `ecc.lua` in its directory

## Part 2: Deposit Machine Setup

### Step 2.1: Generate Keypair for Deposit Machine

**On the Key Generator server**, you need to manually request a keypair:

```lua
-- Press Ctrl+T to pause the server
-- Then run:
lua
> local ecc = require("ecc")
> local private, public = ecc.keypair(ecc.random.random())
> print("Private Key: " .. private)
> print("Public Key: " .. public)
-- COPY BOTH KEYS! You'll need them.
```

**Save these keys securely!** The private key will go on the deposit machine, the public key registers with the gateway.

### Step 2.2: Register Machine with Gateway

Add the public key to the gateway's `start_gateway.lua`:

```lua
gateway.registeredMachines = {
    ["DEPOSIT_001"] = "the-public-key-you-just-generated",
}
```

Then **restart the gateway**:
```lua
-- On Gateway computer, press Ctrl+T
lua start_gateway.lua
```

### Step 2.3: Physical Deposit Machine Setup

1. **Place an Advanced Computer**
2. **Attach a Wireless Modem** (any side)
3. **Place a Chest** (default: on top of computer, can be any side)
4. **Label the computer** (optional):
   ```lua
   label set "Deposit-001"
   ```

### Step 2.4: Upload Deposit Machine Files

Transfer these files to the deposit machine:
- `ecc.lua`
- `deposit_machine_client.lua`

### Step 2.5: Configure Deposit Machine

Edit `deposit_machine_client.lua` on the deposit machine:

```lua
-- Find this section at the top:
depositMachine.machineId = "DEPOSIT_001"  -- Must match gateway registration!
depositMachine.privateKey = "paste-private-key-here"  -- From Step 2.1
depositMachine.diamondValue = 100  -- Balance units per diamond
depositMachine.chestSide = "top"  -- Side where chest is attached
depositMachine.gatewayChannel = 1000
```

**CRITICAL:** The `machineId` must exactly match what you registered in the gateway!

### Step 2.6: Start Deposit Machine

```lua
lua deposit_machine_client.lua
```

Wait for: `"Deposit machine DEPOSIT_001 started. Place diamonds to deposit."`

### Step 2.7: Test Deposit Machine

1. Create a test account (see Part 3)
2. At deposit machine, enter account ID
3. Place diamonds in chest
4. Machine should count diamonds and process deposit
5. Check balance on account manager

## Part 3: Account Creation

You'll need a way to create accounts. Here's a simple account creation terminal:

### Step 3.1: Create Account Manager Terminal

Create a new file `create_account.lua`:

```lua
-- Load ECC library
local ecc = require("ecc")

-- Get wired modem for internal network
local modem = peripheral.find("modem")
if not modem then
    error("No modem found!")
end

local KEY_GEN_CHANNEL = 102
local BALANCE_MGR_CHANNEL = 101

-- Open channels
modem.open(9999)  -- Response channel

print("=== TrainPass Account Creator ===")
print("")

-- Get username
write("Enter username: ")
local username = read()

-- Get initial balance
write("Enter initial balance (default 0): ")
local balanceInput = read()
local initialBalance = tonumber(balanceInput) or 0

-- Get card UUIDs
print("Enter magstripe card UUIDs (one per line, empty to finish):")
local cardUUIDs = {}
while true do
    write("Card UUID " .. (#cardUUIDs + 1) .. ": ")
    local uuid = read()
    if uuid == "" then
        break
    end
    table.insert(cardUUIDs, uuid)
end

print("")
print("Generating keypair...")

-- Request keypair from key generator
modem.transmit(KEY_GEN_CHANNEL, 9999, textutils.serialize({
    requestType = "GENERATE_KEYPAIR",
    timestamp = os.epoch("utc")
}))

-- Wait for keypair
local timer = os.startTimer(5)
local publicKey, privateKey
while true do
    local event, p1, p2, p3, p4, p5 = os.pullEvent()
    if event == "modem_message" and p2 == 9999 then
        local response = textutils.unserialize(p4)
        if response and response.success then
            publicKey = response.publicKey
            privateKey = response.privateKey
            break
        end
    elseif event == "timer" and p1 == timer then
        error("Timeout waiting for keypair!")
    end
end

print("Keypair generated!")
print("")
print("Creating account...")

-- Create account
local accountId = string.sub(publicKey, 1, 12)  -- Use first 12 chars as ID
modem.transmit(BALANCE_MGR_CHANNEL, 9999, textutils.serialize({
    requestType = "CREATE_ACCOUNT",
    username = username,
    publicKey = publicKey,
    initialBalance = initialBalance,
    cardUUIDs = cardUUIDs,
    timestamp = os.epoch("utc")
}))

-- Wait for confirmation
timer = os.startTimer(5)
while true do
    local event, p1, p2, p3, p4, p5 = os.pullEvent()
    if event == "modem_message" and p2 == 9999 then
        local response = textutils.unserialize(p4)
        if response and response.success then
            print("Account created successfully!")
            print("")
            print("==========================================")
            print("ACCOUNT ID: " .. accountId)
            print("USERNAME: " .. username)
            print("BALANCE: " .. initialBalance)
            if #cardUUIDs > 0 then
                print("CARDS: " .. #cardUUIDs .. " linked")
            end
            print("")
            print("PRIVATE KEY (SAVE THIS!):")
            print(privateKey)
            print("==========================================")
            print("")
            print("WARNING: Store the private key securely!")
            print("It cannot be recovered if lost.")
            break
        else
            error("Failed to create account: " .. (response.error or "Unknown error"))
        end
    elseif event == "timer" and p1 == timer then
        error("Timeout waiting for account creation!")
    end
end
```

### Step 3.2: Place Account Creation Terminal

1. **Place an Advanced Computer** near the server room
2. **Attach a Wired Modem** and connect to server network
3. **Upload files**: `ecc.lua`, `create_account.lua`
4. **Run**: `lua create_account.lua`

### Step 3.3: Create Your First Account

Follow the prompts:
1. Enter username (e.g., "Steve")
2. Enter initial balance (e.g., 1000)
3. Enter card UUIDs (get from your magstripe mod)
4. **SAVE THE PRIVATE KEY!** Write it down or store securely

## Part 4: Payment Terminal Setup (For Your Magstripe Mod)

### Step 4.1: Create Payment Terminal Code

Create `payment_terminal.lua`:

```lua
-- Configuration
local config = {
    vendorId = "GATE_001",  -- Unique vendor ID
    vendorType = "FAREGATE",  -- FAREGATE, SHOP, TOLL, etc.
    defaultAmount = 10,  -- Default charge amount
    gatewayChannel = 1000,
    responseChannel = 2000,
    location = "Station A"  -- Descriptive location
}

-- Find wireless modem
local modem = peripheral.find("modem")
if not modem then
    error("No wireless modem found!")
end

-- Open response channel
modem.open(config.responseChannel)

print("=== Payment Terminal " .. config.vendorId .. " ===")
print("Type: " .. config.vendorType)
print("Location: " .. config.location)
print("")

-- Main payment function
function processPayment(cardUUID, amount)
    amount = amount or config.defaultAmount
    
    print("Processing payment...")
    print("Card: " .. cardUUID)
    print("Amount: " .. amount)
    
    -- Create payment packet
    local packet = {
        data = {
            requestType = "CARD_PAYMENT",
            cardUUID = cardUUID,
            vendorId = config.vendorId,
            vendorType = config.vendorType,
            amount = amount,
            metadata = {
                location = config.location,
                timestamp = os.epoch("utc")
            }
        },
        timestamp = os.epoch("utc")
    }
    
    -- Send to gateway
    modem.transmit(config.gatewayChannel, config.responseChannel, textutils.serialize(packet))
    
    -- Wait for response
    local timer = os.startTimer(5)
    while true do
        local event, p1, p2, p3, p4, p5 = os.pullEvent()
        if event == "modem_message" and p2 == config.responseChannel then
            local response = textutils.unserialize(p4)
            if response then
                if response.success then
                    print("SUCCESS! New balance: " .. response.balance)
                    -- Add your gate opening code here
                    -- openGate()
                    return true
                else
                    print("DECLINED: " .. (response.error or "Unknown error"))
                    return false
                end
            end
        elseif event == "timer" and p1 == timer then
            print("ERROR: Payment timeout")
            return false
        end
    end
end

-- Integration point with your magstripe mod
-- Replace this with your actual mod integration
function waitForCardSwipe()
    print("Waiting for card swipe...")
    -- This is where you'd integrate with your magstripe mod
    -- Example: local uuid = yourMagstripeMod.getCardUUID()
    
    -- For testing, you can manually enter UUIDs:
    write("Enter card UUID: ")
    local uuid = read()
    return uuid
end

-- Main loop
while true do
    local cardUUID = waitForCardSwipe()
    if cardUUID and cardUUID ~= "" then
        local success = processPayment(cardUUID)
        if success then
            sleep(2)  -- Keep success message visible
        else
            sleep(3)  -- Keep error message visible
        end
        print("")
        print("Ready for next payment...")
    end
    sleep(0.1)
end
```

### Step 4.2: Deploy Payment Terminals

1. **Place Advanced Computer** at each payment location (faregate, shop, etc.)
2. **Attach Wireless Modem**
3. **Upload** `payment_terminal.lua`
4. **Configure** vendor ID, type, and location in the file
5. **Run**: `lua payment_terminal.lua`

### Step 4.3: Integrate with Your Magstripe Mod

Replace the `waitForCardSwipe()` function with your actual mod integration:

```lua
function waitForCardSwipe()
    -- Your magstripe mod integration here
    -- This is mod-specific, examples:
    
    -- If using peripheral:
    local reader = peripheral.find("magstripe_reader")
    local event, uuid = os.pullEvent("magstripe_swipe")
    return uuid
    
    -- Or however your mod exposes card data
end
```

## Part 5: Verification & Testing

### Test 1: Account Creation
1. Create a test account with initial balance
2. Note the account ID and link a test card UUID
3. Verify account shows in Balance Manager console

### Test 2: Diamond Deposit
1. Go to deposit machine
2. Enter account ID
3. Place 5 diamonds in chest
4. Verify balance increases by 500
5. Check Ledger Server shows deposit transaction

### Test 3: Card Payment
1. Go to payment terminal
2. Swipe/enter card UUID
3. Verify payment processes
4. Check balance decreases
5. Check Ledger Server shows vendor charge transaction

### Test 4: Multiple Cards
1. Create account with 2 card UUIDs
2. Test payment with first card - should work
3. Test payment with second card - should work
4. Test payment with unknown card - should fail

### Test 5: Insufficient Funds
1. Create account with 5 balance
2. Attempt payment of 10
3. Should decline with insufficient funds error

### Test 6: Server Persistence
1. Make several transactions
2. Stop a server (Ctrl+T)
3. Restart server
4. Verify data persisted (check .dat files)

## Part 6: Production Deployment

### Security Considerations

1. **Protect the server room** - build in secure, claimed area
2. **Backup .dat files** regularly - copy to safe location
3. **Protect private keys** - never share deposit machine private keys
4. **Monitor logs** - check server consoles for suspicious activity

### Scaling

**Adding more deposit machines:**
1. Generate new keypair
2. Register public key in gateway
3. Deploy new machine with unique ID
4. Restart gateway

**Adding more payment terminals:**
1. Copy payment_terminal.lua
2. Change vendorId and vendorType
3. Deploy to new location
4. No server restart needed!

**Multiple gateways** (for large worlds):
1. Add additional gateway computers
2. Configure different wireless channels
3. Connect to same wired network
4. Update client configs

### Monitoring

Check these regularly:

**Balance Manager:**
- Number of active accounts
- Total balance in circulation
- Recent transactions

**Ledger Server:**
- Transaction count
- No duplicate transaction IDs
- Hash chain integrity

**Gateway:**
- Failed authentication attempts
- Message volume
- Response times

### Maintenance

**Daily:**
- Check server consoles for errors
- Verify all servers running

**Weekly:**
- Backup all .dat files
- Review transaction logs
- Check disk space

**Monthly:**
- Audit account balances
- Review vendor transaction patterns
- Update deposit machine registrations

## Troubleshooting

### Deposit Machine Can't Connect
- Check wireless modem attached
- Verify gateway is running
- Confirm channel 1000 is correct
- Check deposit machine is registered in gateway

### Payment Terminal Declined
- Verify card UUID is linked to account
- Check account has sufficient balance
- Confirm gateway is running
- Check wireless modem range

### Server Not Responding
- Check wired modem connections
- Verify networking cables connected
- Restart server
- Check for error messages in console

### Data Loss
- Check for .dat files in server directory
- Restore from backup if available
- Servers auto-save every 5 minutes

### Signature Verification Failed
- Confirm deposit machine ID matches registration
- Check private key is correct
- Verify public key in gateway matches
- Restart gateway to reload registrations

## Support

For issues or questions:
1. Check `DISTRIBUTED_ARCHITECTURE.md` for API details
2. Review server console logs for errors
3. Test each component individually
4. Verify network connectivity between servers

## Quick Reference Card

```
SERVER STARTUP ORDER:
1. Ledger (channel 100)
2. Key Generator (channel 102)
3. Balance Manager (channel 101)
4. Gateway (wireless 1000, wired 101)

DEFAULT CHANNELS:
- Ledger: 100
- Balance Manager: 101
- Key Generator: 102
- Gateway: 1000

FILES PER SERVER:
All: ecc.lua
Ledger: ledger_server.lua, start_ledger.lua
Balance: balance_manager.lua, start_balance_manager.lua
KeyGen: key_generator.lua, start_key_generator.lua
Gateway: gateway.lua, start_gateway.lua

DEPOSIT MACHINE:
Files: ecc.lua, deposit_machine_client.lua
Needs: privateKey, machineId, wireless modem, chest

PAYMENT TERMINAL:
Files: payment_terminal.lua
Needs: vendorId, vendorType, wireless modem
Integration: waitForCardSwipe() function

BACKUP FILES:
- ledger.dat
- balance_manager.dat
- key_generator.dat
- gateway.dat
```

---

**Your banking system is now deployed! 🎉**

Players can deposit diamonds, swipe cards, and make payments across your Minecraft world.
