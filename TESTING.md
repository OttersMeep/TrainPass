# TrainPass Testing Guide

Complete guide for testing your TrainPass banking system in ComputerCraft.

## Testing Environment Setup

### Option 1: Single Player World (Easiest)
1. Create new Minecraft world with CC:Tweaked
2. Build server room with 4-5 computers
3. Test locally

### Option 2: Creative Server
1. Join creative server
2. Build test area in claimed chunk
3. Test with multiple players

## Quick Test Setup

### Minimal Test (1 Computer)

You can test basic functionality with just ONE computer:

```lua
-- test_basic.lua
-- Basic test of cryptography and serialization

local ecc = require("ecc")

print("=== TrainPass Basic Test ===")
print("")

-- Test 1: ECC Library
print("Test 1: ECC Keypair Generation")
local private, public = ecc.keypair(ecc.random.random())
print("  Private: " .. string.sub(private, 1, 32) .. "...")
print("  Public: " .. string.sub(public, 1, 32) .. "...")
print("  ✓ PASS")
print("")

-- Test 2: SHA-256
print("Test 2: SHA-256 Hashing")
local hash = ecc.sha256.digest("test data")
print("  Hash: " .. hash:toHex())
print("  ✓ PASS")
print("")

-- Test 3: Signing
print("Test 3: Message Signing")
local message = "test message"
local signature = ecc.sign(private, message)
print("  Signature: " .. string.sub(signature, 1, 32) .. "...")
print("  ✓ PASS")
print("")

-- Test 4: Verification
print("Test 4: Signature Verification")
local valid = ecc.verify(public, message, signature)
if valid then
    print("  ✓ PASS - Signature valid")
else
    print("  ✗ FAIL - Signature invalid")
end
print("")

print("=== All Basic Tests Complete ===")
```

### Full System Test (5 Computers)

Set up the complete server room as described in INSTALLATION.md.

## Test Scenarios

### Test 1: Server Startup

**What to test:** All servers start without errors

**Steps:**
1. Start Ledger Server - should show "Ledger server started on channel 100"
2. Start Key Generator - should show "Key generator started on channel 102"
3. Start Balance Manager - should show "Balance manager started on channel 101"
4. Start Gateway - should show "Gateway started. Wireless on channel 1000, wired on channel 101"

**Expected:** All servers running, no error messages

---

### Test 2: Account Creation

**What to test:** Creating accounts with card UUIDs

**Create test account terminal:**

```lua
-- test_create_account.lua
-- Run on computer with wired modem connected to server room

local modem = peripheral.find("modem")
if not modem then error("No modem found") end

modem.open(9999)

print("=== Create Test Account ===")

-- Request keypair
print("Requesting keypair...")
modem.transmit(102, 9999, textutils.serialize({
    requestType = "GENERATE_KEYPAIR",
    timestamp = os.epoch("utc")
}))

local timer = os.startTimer(5)
local publicKey, privateKey

while true do
    local event, p1, p2, p3, p4 = os.pullEvent()
    if event == "modem_message" and p2 == 9999 then
        local response = textutils.unserialize(p4)
        if response and response.success then
            publicKey = response.publicKey
            privateKey = response.privateKey
            break
        end
    elseif event == "timer" and p1 == timer then
        error("Timeout!")
    end
end

print("Got keypair!")

-- Create account
print("Creating account...")
local accountId = string.sub(publicKey, 1, 12)

modem.transmit(101, 9999, textutils.serialize({
    requestType = "CREATE_ACCOUNT",
    username = "TestUser",
    publicKey = publicKey,
    initialBalance = 1000,
    cardUUIDs = {"test-card-001", "test-card-002"},
    timestamp = os.epoch("utc")
}))

timer = os.startTimer(5)
while true do
    local event, p1, p2, p3, p4 = os.pullEvent()
    if event == "modem_message" and p2 == 9999 then
        local response = textutils.unserialize(p4)
        if response then
            if response.success then
                print("")
                print("=== ACCOUNT CREATED ===")
                print("Account ID: " .. accountId)
                print("Username: TestUser")
                print("Balance: 1000")
                print("Cards: test-card-001, test-card-002")
                print("")
                print("Test cards for payment terminal:")
                print("  test-card-001")
                print("  test-card-002")
            else
                print("ERROR: " .. (response.error or "Unknown"))
            end
            break
        end
    elseif event == "timer" and p1 == timer then
        error("Timeout!")
    end
end
```

**Expected:** Account created with balance 1000 and 2 cards

---

### Test 3: Card Payment

**What to test:** Payment terminal processes card payments

**Steps:**
1. Create test account (Test 2)
2. Start payment terminal:
   ```lua
   lua payment_terminal.lua
   ```
3. Enter card UUID: `test-card-001`
4. Enter amount: `10`

**Expected:**
- Payment approved
- Balance decreases from 1000 to 990
- Success message displayed

---

### Test 4: Insufficient Funds

**What to test:** System declines payments when balance too low

**Steps:**
1. Use test account with 1000 balance
2. Try to pay 1500

**Expected:**
- Payment declined
- Error message: "Insufficient funds"
- Balance unchanged

---

### Test 5: Invalid Card

**What to test:** System declines unknown card UUIDs

**Steps:**
1. Enter card UUID: `invalid-card-999`
2. Try to pay 10

**Expected:**
- Payment declined
- Error message: "Card not registered" or "Account not found"

---

### Test 6: Deposit Machine (Without Server Manager)

**What to test:** Manual deposit machine setup

**Steps:**
1. Generate keypair for deposit machine:
   ```lua
   local ecc = require("ecc")
   local private, public = ecc.keypair(ecc.random.random())
   print("Private: " .. private)
   print("Public: " .. public)
   ```
2. Register with gateway (manually add to `start_gateway.lua`)
3. Edit `deposit_machine_client.lua` with machine ID and private key
4. Run deposit machine
5. Enter test account ID
6. Place diamonds in chest (use creative mode)

**Expected:**
- Machine counts diamonds
- Balance increases
- Confirmation message

---

### Test 7: Server Manager Batch Provisioning

**What to test:** Automated machine provisioning

**Setup:**
1. Build dropper system:
   ```
   [Dropper with Advanced Computers] ← Fill with computers
              ↓ (redstone on TOP)
           [Hopper]
              ↓
         [Disk Drive] ← Manager (RIGHT side)
              ↓
    [Locked Hopper] (redstone on BOTTOM)
              ↓
         [Collection Chest]
   ```

2. Start server manager:
   ```lua
   lua start_server_manager.lua
   ```

**Steps:**
1. Command: `register deposit 3`
2. Watch as 3 computers are provisioned
3. Collect computers from bottom
4. Place one computer and turn on
5. Attach wireless modem
6. Attach chest

**Expected:**
- 3 computers labeled DEPOSIT_001, DEPOSIT_002, DEPOSIT_003
- Each computer auto-starts on boot
- Each has unique private key
- All registered with gateway

---

### Test 8: Multiple Simultaneous Payments

**What to test:** System handles concurrent transactions

**Setup:**
1. Create 3 test accounts
2. Set up 3 payment terminals
3. Make payments at same time

**Expected:**
- All payments process successfully
- No conflicts or errors
- Balances update correctly

---

### Test 9: Server Restart/Persistence

**What to test:** Data persists after server restart

**Steps:**
1. Create account with balance 1000
2. Make payment of 100 (balance = 900)
3. Stop Balance Manager (Ctrl+T)
4. Restart Balance Manager
5. Make another payment of 50

**Expected:**
- Balance is 900 after restart (not 1000)
- Payment processes correctly
- Balance becomes 850

**Check data files:**
```bash
ls *.dat
# Should see: ledger.dat, balance_manager.dat, key_generator.dat, gateway.dat
```

---

### Test 10: Transaction Audit

**What to test:** All transactions logged in ledger

**Query ledger manually:**

```lua
-- test_query_ledger.lua
local modem = peripheral.find("modem")
modem.open(9999)

print("Querying ledger...")

modem.transmit(100, 9999, textutils.serialize({
    action = "QUERY_BY_ACCOUNT",
    accountId = "your-account-id-here",
    limit = 10
}))

local timer = os.startTimer(5)
while true do
    local event, p1, p2, p3, p4 = os.pullEvent()
    if event == "modem_message" and p2 == 9999 then
        local response = textutils.unserialize(p4)
        if response and response.transactions then
            print("")
            print("=== Transaction History ===")
            for i, tx in ipairs(response.transactions) do
                print(i .. ". Type: " .. tx.type)
                print("   Amount: " .. tx.amount)
                print("   Time: " .. os.date("%Y-%m-%d %H:%M:%S", tx.timestamp / 1000))
                if tx.vendor then
                    print("   Vendor: " .. tx.vendor)
                end
                print("")
            end
            break
        end
    elseif event == "timer" and p1 == timer then
        error("Timeout!")
    end
end
```

**Expected:**
- All transactions listed
- CREATE_ACCOUNT transaction
- VENDOR_CHARGE transactions
- DEPOSIT transactions (if any)

---

## Common Issues & Solutions

### Issue: "No modem found"
**Solution:** Attach wireless modem to client, wired modem to servers

### Issue: "Timeout waiting for response"
**Solution:** 
- Check server is running
- Verify wired modems connected with cables
- Check channel numbers match

### Issue: "Card not registered"
**Solution:** 
- Verify card UUID exists in account
- Check account was created successfully
- Use exact UUID (case-sensitive)

### Issue: "Signature verification failed"
**Solution:**
- Check private key matches public key
- Verify machine registered in gateway
- Ensure deposit machine has correct machine ID

### Issue: Payment terminal shows gibberish
**Solution:** Gateway encrypts messages - this is normal. Check gateway logs for actual errors.

---

## Automated Test Suite

Create comprehensive test suite:

```lua
-- test_suite.lua
-- Automated testing for TrainPass

local tests = {}
local passed = 0
local failed = 0

function tests.run(name, fn)
    print("Running: " .. name)
    local ok, err = pcall(fn)
    if ok then
        print("  ✓ PASS")
        passed = passed + 1
    else
        print("  ✗ FAIL: " .. err)
        failed = failed + 1
    end
    print("")
end

-- Test: ECC Library
tests.run("ECC Keypair Generation", function()
    local ecc = require("ecc")
    local priv, pub = ecc.keypair(ecc.random.random())
    assert(priv and pub, "Keypair generation failed")
end)

-- Test: Account Creation
tests.run("Account Creation", function()
    -- Add account creation test
end)

-- Add more tests...

print("=== Test Results ===")
print("Passed: " .. passed)
print("Failed: " .. failed)
print("Total: " .. (passed + failed))
```

---

## Performance Testing

### Stress Test: Rapid Payments

```lua
-- stress_test.lua
local modem = peripheral.find("modem")
local count = 100
local startTime = os.epoch("utc")

for i = 1, count do
    -- Send payment request
    -- Wait for response
end

local endTime = os.epoch("utc")
local duration = (endTime - startTime) / 1000
print("Processed " .. count .. " payments in " .. duration .. " seconds")
print("Rate: " .. (count / duration) .. " payments/second")
```

---

## Debug Mode

Enable debug output in servers by adding at the top:

```lua
local DEBUG = true

local function log(message)
    if DEBUG then
        print("[DEBUG] " .. message)
    end
end
```

---

## Testing Checklist

Before going to production:

- [ ] All 4 servers start without errors
- [ ] Account creation works
- [ ] Card payments process correctly
- [ ] Insufficient funds declined
- [ ] Invalid cards declined
- [ ] Deposits work (if using)
- [ ] Data persists after restart
- [ ] Multiple simultaneous payments work
- [ ] Transaction audit shows all transactions
- [ ] Backup and restore works

---

## Getting Help

If tests fail:
1. Check server console logs for errors
2. Verify wired modem connections
3. Check channel numbers in configs
4. Review DISTRIBUTED_ARCHITECTURE.md
5. Open issue on GitHub: https://github.com/OttersMeep/TrainPass/issues

---

**Ready to test!** Start with Test 1 (Server Startup) and work your way through.
