# TrainPass Banking System - Distributed Architecture

A distributed banking system for Minecraft with ComputerCraft, designed for processing payments via magstripe cards and managing diamond deposits with cryptographic security.

## System Architecture

The system uses a **distributed server architecture** with 4 specialized servers in a "server room" connected via wired modems, and remote clients connected via wireless modems.

### Server Room (4 Computers with Wired Modems)

1. **Ledger Server** - Immutable transaction logging
2. **Balance Manager** - Account and balance management
3. **Key Generator** - ECC keypair generation
4. **Gateway** - Encryption/decryption and wireless interface

### External Clients (Wireless)

- **Deposit Machines** - Accept diamonds, sign deposits with private keys
- **Payment Terminals** - Accept magstripe card payments (integrates with your mod)

## Key Features

✅ **Magstripe Card Support** - Multiple UUIDs per account  
✅ **Signed Deposits** - Deposit machines authenticate with unique keypairs  
✅ **Distributed Architecture** - Separation of concerns, scalable  
✅ **Secure Communication** - Encrypted wireless, secure wired network  
✅ **Audit Trail** - Complete transaction logging with hashing  
✅ **Vendor System** - Support for faregates, shops, tolls, etc.

## Files Overview

### Core Server Files
- `ledger_server.lua` - Transaction logging server
- `balance_manager.lua` - Account and balance management server
- `key_generator.lua` - Keypair generation server
- `gateway.lua` - Encryption/decryption gateway

### Client Files
- `deposit_machine_client.lua` - Deposit machine with signature support

### Startup Scripts
- `start_ledger.lua` - Start ledger server
- `start_balance_manager.lua` - Start balance manager
- `start_key_generator.lua` - Start key generator
- `start_gateway.lua` - Start gateway
- `start_server_room.lua` - Instructions for all servers

### Libraries
- `ecc.lua` - Elliptic curve cryptography (SHA-256, signing, verification)

### Documentation
- `DISTRIBUTED_ARCHITECTURE.md` - Complete architecture documentation
- `README.md` - This file

## Quick Start

### Server Room Setup

**Requirements:**
- 4 computers with wired modems (connected together)
- Gateway computer needs BOTH wired AND wireless modems

**Installation:**

1. **Ledger Server (Computer 1):**
   ```lua
   -- Upload files: ecc.lua, ledger_server.lua, start_ledger.lua
   lua start_ledger.lua
   ```

2. **Balance Manager (Computer 2):**
   ```lua
   -- Upload files: ecc.lua, balance_manager.lua, start_balance_manager.lua
   lua start_balance_manager.lua
   ```

3. **Key Generator (Computer 3):**
   ```lua
   -- Upload files: ecc.lua, key_generator.lua, start_key_generator.lua
   lua start_key_generator.lua
   ```

4. **Gateway (Computer 4 - needs wired + wireless modems):**
   ```lua
   -- Upload files: ecc.lua, gateway.lua, start_gateway.lua
   -- Edit start_gateway.lua to register deposit machines first!
   lua start_gateway.lua
   ```

### Deposit Machine Setup

1. **Generate keypair** for the machine (contact key generator)
2. **Register** machine ID and public key with gateway
3. **Upload files** to deposit machine computer:
   - `ecc.lua`
   - `deposit_machine_client.lua`
4. **Configure** the machine with its private key
5. **Run:** `lua deposit_machine_client.lua`

## Data Structures

### Account
```lua
{
    accountId = "abc123def456",
    username = "playerName",
    publicKey = "...",
    balance = 1000,
    cardUUIDs = {                   -- Magstripe card UUIDs
        "uuid-1111-2222-3333",
        "uuid-4444-5555-6666"
    },
    createdAt = 1234567890,
    active = true
}
```

### Transaction
```lua
{
    id = 1,
    timestamp = 1234567890,
    accountId = "abc123def456",
    type = "VENDOR_CHARGE",
    amount = -50,
    vendor = "GATE_001",
    vendorType = "FAREGATE",
    metadata = {},
    hash = "..."                    -- SHA-256 integrity hash
}
```

## Network Configuration

### Wired Network (Server Room - Internal)
- **Channel 100:** Ledger Server
- **Channel 101:** Balance Manager  
- **Channel 102:** Key Generator
- **Secure:** Physical network, no encryption needed

### Wireless Network (External)
- **Channel 1000:** Gateway endpoint
- **Encrypted:** All messages encrypted
- **Authenticated:** Deposit machines sign with private keys

## How It Works

### Deposit Flow
1. Player enters account ID at deposit machine
2. Player places diamonds in chest
3. Machine counts diamonds (e.g., 5 × 100 = 500)
4. Machine signs deposit: `sign(privateKey, accountId+amount+timestamp)`
5. Machine sends encrypted request to gateway
6. Gateway verifies signature
7. Gateway forwards to balance manager
8. Balance manager updates balance
9. Balance manager logs to ledger
10. Confirmation sent back to machine
11. Machine clears diamonds from chest

### Card Payment Flow
1. Player swipes magstripe card at terminal
2. Terminal sends card UUID + amount to gateway
3. Gateway queries balance manager for account by UUID
4. Balance manager checks balance
5. Balance manager charges account
6. Balance manager logs to ledger
7. Confirmation sent to terminal
8. Terminal completes transaction (open gate, dispense item, etc.)

### Account Creation Flow
1. Request sent to key generator for keypair
2. Key generator creates and returns keypair
3. Request sent to balance manager with username, publicKey, initial balance, and card UUIDs
4. Balance manager creates account
5. Balance manager logs to ledger
6. Account ID and private key returned to user (private key must be stored securely!)

## Security Model

### Deposit Machines
- Each machine has unique ECC keypair
- Public key registered with gateway
- Private key stored only on machine
- All deposits signed with private key
- Gateway verifies signature before processing
- Timestamps prevent replay attacks

### Magstripe Cards
- Each card has unique UUID (from your separate mod)
- Multiple cards can be linked to one account
- Server-side validation only
- No balance data stored on card
- UUID → Account lookup on balance manager

### Gateway Security
- Only wireless endpoint
- Encrypts all external communication
- Verifies all signatures
- Validates timestamps
- Routes to internal servers via wired network
- Internal network is physically secure

## Integration with Your Magstripe Mod

From your mod, send payment requests like this:

```lua
-- Get card UUID from your mod
local cardUUID = yourMod.getCardUUID()

-- Create payment packet
local packet = {
    data = {
        requestType = "CARD_PAYMENT",
        cardUUID = cardUUID,
        vendorId = "GATE_001",
        vendorType = "FAREGATE",  -- or "SHOP", "TOLL", etc.
        amount = 10,
        metadata = {
            location = "Station A",
            timestamp = os.epoch("utc")
        }
    },
    timestamp = os.epoch("utc")
}

-- Send to gateway
modem.transmit(1000, responseChannel, textutils.serialize(packet))

-- Wait for response
-- Response will contain success/failure and new balance
```

## Vendor Types

The system supports any vendor type:
- `"FAREGATE"` - Train station gates
- `"SHOP"` - Player shops
- `"TOLL"` - Road/bridge tolls
- `"VENDING"` - Vending machines
- `"PARKING"` - Parking meters
- Any custom type you define

## Configuration

Each server has configuration at the top of its file:

**Balance Manager:**
```lua
balanceManager.config = {
    minBalance = 0,
    maxBalance = 999999,
    defaultVendorPrice = 10,
    enableOverdraft = false
}
```

**Deposit Machine:**
```lua
depositMachine.diamondValue = 100  -- Balance per diamond
depositMachine.chestSide = "top"
```

**Gateway:**
```lua
gateway.wirelessChannel = 1000
gateway.balanceManagerChannel = 101
```

## Maintenance

### Auto-Save
All servers auto-save every 5 minutes to `.dat` files:
- `ledger.dat`
- `balance_manager.dat`
- `key_generator.dat`
- `gateway.dat`

### Backups
Copy the `.dat` files periodically for backups.

### Monitoring
- Check server console logs
- Query ledger for transaction history
- Balance manager shows account stats

## API Reference

See `DISTRIBUTED_ARCHITECTURE.md` for complete API documentation including:
- All server request/response formats
- Message signing requirements
- Error codes and handling
- Transaction types
- Security considerations

## Advantages

1. **Scalable** - Can add more balance managers or gateways
2. **Secure** - Wired network isolates critical servers
3. **Reliable** - If one server fails, others continue
4. **Auditable** - Complete transaction history in ledger
5. **Flexible** - Easy to add new features to specific servers
6. **Card Support** - Native magstripe UUID integration
7. **Authenticated Deposits** - Cryptographically signed

## License

This project uses ECC cryptography code from the ComputerCraft community. The banking system is provided for use in ComputerCraft/Minecraft environments.

## Documentation

- `DISTRIBUTED_ARCHITECTURE.md` - Complete architecture with diagrams
- `README.md` - This file

For detailed setup instructions, API documentation, and troubleshooting, see `DISTRIBUTED_ARCHITECTURE.md`.
