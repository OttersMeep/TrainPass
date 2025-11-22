# TrainPass Banking System - Distributed Architecture

## System Overview

The TrainPass banking system uses a **distributed server architecture** with specialized servers in a "server room" connected via wired modems, and remote clients (deposit machines, payment terminals) connected via wireless modems.

```
┌─────────────────────────────────────────────────────────────────────┐
│                         SERVER ROOM                                  │
│  ┌────────────────────────────────────────────────────────────────┐ │
│  │          WIRED MODEM NETWORK (Internal, Secure)                │ │
│  │                                                                 │ │
│  │   ┌──────────────┐   ┌──────────────┐   ┌──────────────┐    │ │
│  │   │   Ledger     │   │   Balance    │   │     Key      │    │ │
│  │   │   Server     │   │   Manager    │   │  Generator   │    │ │
│  │   │  (Ch 100)    │   │  (Ch 101)    │   │  (Ch 102)    │    │ │
│  │   └──────────────┘   └──────────────┘   └──────────────┘    │ │
│  │          │                   │                   │            │ │
│  │          └───────────────────┴───────────────────┘            │ │
│  │                              │                                 │ │
│  │                    ┌─────────▼─────────┐                      │ │
│  │                    │     Gateway       │                      │ │
│  │                    │  (Encryption/     │                      │ │
│  │                    │   Decryption)     │                      │ │
│  │                    │  Wired + Wireless │                      │ │
│  │                    └─────────┬─────────┘                      │ │
│  └──────────────────────────────┼────────────────────────────────┘ │
└────────────────────────────────┼─────────────────────────────────┘
                                  │ Wireless Channel 1000
                                  │ (External, Encrypted)
        ┌─────────────────────────┼─────────────────────────┐
        │                         │                         │
   ┌────▼─────┐             ┌────▼─────┐            ┌────▼─────┐
   │ Deposit  │             │ Payment  │            │ Payment  │
   │ Machine  │             │ Terminal │            │ Terminal │
   │  (Signs  │             │ (Magstrip│            │ (Magstrip│
   │   with   │             │  e Cards)│            │  e Cards)│
   │ Private  │             └──────────┘            └──────────┘
   │   Key)   │
   └──────────┘
```

## Server Components

### 1. Ledger Server (Channel 100)
**Purpose:** Immutable transaction log for audit trail

**Responsibilities:**
- Log all transactions with timestamps and hashes
- Query transactions by account or vendor
- Provide transaction integrity verification
- Auto-save transaction log periodically

**Files:** `ledger_server.lua`, `start_ledger.lua`

**API:**
- `LOG` - Log a transaction
- `QUERY_ACCOUNT` - Get transactions for an account
- `QUERY_VENDOR` - Get transactions for a vendor
- `GET` - Get specific transaction by ID

### 2. Balance Manager (Channel 101)
**Purpose:** Account management and balance tracking

**Responsibilities:**
- Manage account creation and deletion
- Track account balances
- Associate payment card UUIDs with accounts
- Process deposits and vendor charges
- Handle transfers between accounts
- Communicate with ledger for transaction logging

**Files:** `balance_manager.lua`, `start_balance_manager.lua`

**API:**
- `CREATE_ACCOUNT` - Create new account with card UUIDs
- `GET_ACCOUNT` - Get account by ID
- `GET_ACCOUNT_BY_CARD` - Look up account by card UUID
- `ADD_CARD` - Add payment card to account
- `REMOVE_CARD` - Remove payment card from account
- `DEPOSIT` - Process deposit (from deposit machine)
- `CHARGE_VENDOR` - Charge vendor transaction
- `CAN_AFFORD` - Check if account can afford amount
- `TRANSFER` - Transfer between accounts

### 3. Key Generator (Channel 102)
**Purpose:** Generate ECC keypairs for new accounts and deposit machines

**Responsibilities:**
- Generate secure ECC keypairs
- Maintain history of public keys generated
- Never store private keys (given to client immediately)

**Files:** `key_generator.lua`, `start_key_generator.lua`

**API:**
- `GENERATE_KEYPAIR` - Generate new ECC keypair

### 4. Gateway (Channel 1000 wireless, Internal wired)
**Purpose:** Secure gateway between external clients and internal servers

**Responsibilities:**
- Encrypt/decrypt wireless communications
- Verify signatures from deposit machines
- Route requests to appropriate internal servers
- Maintain registry of authorized deposit machines
- Handle card payment requests
- Prevent replay attacks

**Files:** `gateway.lua`, `start_gateway.lua`

**External API:**
- `DEPOSIT` - Deposit request from deposit machine (requires signature)
- `CARD_PAYMENT` - Payment via magstripe card UUID

## External Clients

### Deposit Machines
**Purpose:** Accept diamonds and deposit to accounts

**Authentication:** Each deposit machine has a unique private key that signs deposit requests

**Workflow:**
1. User enters account ID
2. User places diamonds in chest
3. Machine counts diamonds (e.g., 5 diamonds = 500 balance)
4. Machine creates signed deposit request:
   - Message: `accountId + amount + timestamp`
   - Signature: `sign(privateKey, message)`
5. Machine sends encrypted request to gateway
6. Gateway verifies signature against registered public key
7. Gateway forwards to balance manager
8. Balance manager updates balance and logs to ledger
9. Response sent back through gateway to machine
10. Machine clears diamonds from chest

**Files:** `deposit_machine_client.lua`

**Security:**
- Each deposit machine registered with gateway (machineId -> publicKey)
- Private key stored securely on deposit machine
- Signature verification prevents unauthorized deposits
- Timestamp prevents replay attacks

### Payment Terminals (Magstripe Cards)
**Purpose:** Accept payments via magstripe card UUIDs

**Card Format:** Each card has a unique UUID (from your separate mod)

**Workflow:**
1. Player swipes magstripe card at terminal
2. Terminal reads card UUID
3. Terminal sends payment request to gateway:
   - Card UUID
   - Vendor ID
   - Vendor type (FAREGATE, SHOP, etc.)
   - Amount
   - Metadata (item info, etc.)
4. Gateway queries balance manager for account by card UUID
5. Balance manager finds account associated with UUID
6. Balance manager checks if account can afford
7. Balance manager charges account
8. Balance manager logs to ledger
9. Response sent back through gateway
10. Terminal completes transaction (open gate, dispense item, etc.)

**Integration with your mod:**
- Your magstripe mod provides the UUID
- You call the banking system API with the UUID
- Banking system handles the rest

## Data Structures

### Account
```lua
{
    accountId = "abc123def456",     -- 16-char hex ID
    username = "playerName",        -- Display name
    publicKey = "...",              -- ECC public key
    balance = 1000,                 -- Current balance
    cardUUIDs = {                   -- List of authorized card UUIDs
        "uuid-1111-2222-3333",
        "uuid-4444-5555-6666"
    },
    createdAt = 1234567890,         -- Creation timestamp
    active = true                   -- Account status
}
```

### Transaction
```lua
{
    id = 1,                         -- Sequential transaction ID
    timestamp = 1234567890,         -- When transaction occurred
    accountId = "abc123def456",     -- Account involved
    type = "VENDOR_CHARGE",         -- Transaction type
    amount = -50,                   -- Amount (negative = debit)
    vendor = "GATE_001",            -- Vendor/machine ID
    vendorType = "FAREGATE",        -- Type of vendor
    metadata = {                    -- Additional info
        item = "Train Ticket",
        location = "Station A"
    },
    hash = "..."                    -- SHA-256 hash for integrity
}
```

### Deposit Machine Registry
```lua
{
    ["DEPOSIT_123"] = "publicKeyHex...",
    ["DEPOSIT_456"] = "publicKeyHex...",
    -- machineId -> publicKey mapping
}
```

### Card to Account Mapping
```lua
{
    ["uuid-1111-2222-3333"] = "abc123def456",
    ["uuid-4444-5555-6666"] = "abc123def456",
    ["uuid-7777-8888-9999"] = "def456ghi789",
    -- cardUUID -> accountId mapping
}
```

## Network Topology

### Internal Network (Wired Modems)
- **Secure and fast** communication between servers
- **No encryption needed** (physical security)
- **Low latency** for inter-server communication
- **Channels:**
  - 100: Ledger Server
  - 101: Balance Manager
  - 102: Key Generator

### External Network (Wireless Modems)
- **Encrypted** communication with clients
- **Signature verification** for security
- **Channel 1000:** Gateway endpoint
- **Random response channels** for clients

## Security Model

### Deposit Machines
1. **Registration:** Each machine registered with gateway (ID + public key)
2. **Signing:** Each deposit signed with machine's private key
3. **Verification:** Gateway verifies signature before processing
4. **Replay Protection:** Timestamps prevent old requests

### Magstripe Cards
1. **UUID Uniqueness:** Each card has unique UUID
2. **Account Association:** Multiple cards can link to one account
3. **Server-side Validation:** All checks done on server
4. **No data on card:** Card only contains UUID, not balance

### Gateway
1. **Encryption:** All external communication encrypted
2. **Firewall:** Only gateway has wireless access
3. **Request Validation:** All requests validated before routing
4. **Rate Limiting:** Can add to prevent DoS

## Setup Instructions

### Server Room Setup

1. **Place 4 computers with wired modems**
   - Connect all via wired modem network
   - Ensure they can communicate on internal channels

2. **Ledger Server (Computer 1):**
   ```
   wget https://... ledger_server.lua
   wget https://... start_ledger.lua
   lua start_ledger.lua
   ```

3. **Balance Manager (Computer 2):**
   ```
   wget https://... balance_manager.lua
   wget https://... start_balance_manager.lua
   lua start_balance_manager.lua
   ```

4. **Key Generator (Computer 3):**
   ```
   wget https://... key_generator.lua
   wget https://... start_key_generator.lua
   lua start_key_generator.lua
   ```

5. **Gateway (Computer 4):**
   - Requires BOTH wired and wireless modems
   ```
   wget https://... gateway.lua
   wget https://... start_gateway.lua
   -- Edit to register deposit machines
   lua start_gateway.lua
   ```

### Deposit Machine Setup

1. **Generate keypair:**
   - Contact key generator server
   - Receive private and public keys
   - Store private key securely on machine

2. **Register with gateway:**
   - Provide machine ID and public key to admin
   - Admin adds to gateway's deposit machine registry

3. **Configure and run:**
   ```
   wget https://... deposit_machine_client.lua
   lua deposit_machine_client.lua
   ```

### Payment Terminal Integration

From your magstripe mod, call:
```lua
-- When card is swiped
local cardUUID = getCardUUID() -- From your mod

-- Send payment request
local success, response = sendPaymentRequest({
    requestType = "CARD_PAYMENT",
    cardUUID = cardUUID,
    vendorId = "GATE_001",
    vendorType = "FAREGATE",
    amount = 10,
    metadata = { location = "Station A" }
})

if success then
    -- Open gate, complete transaction
else
    -- Show error: response.error
end
```

## Advantages of This Architecture

1. **Separation of Concerns:** Each server has one job
2. **Scalability:** Can add more balance managers if needed
3. **Security:** Wired network is secure, gateway protects wireless
4. **Audit Trail:** Ledger provides complete transaction history
5. **Flexibility:** Easy to add new features to specific servers
6. **Reliability:** If one server fails, others keep running
7. **Card Support:** Native support for magstripe card UUIDs
8. **Signed Deposits:** Deposit machines authenticate with signatures

## Transaction Flow Examples

### Example 1: Deposit Diamonds
```
Player → Deposit Machine → Gateway → Balance Manager → Ledger
                              ↓           ↓              ↓
                         [Verify     [Update      [Log
                          Signature]  Balance]    Transaction]
                              ↓           ↓              ↓
Player ← Deposit Machine ← Gateway ← Balance Manager
         [Confirmation]
```

### Example 2: Card Payment at Faregate
```
Player Swipes Card → Terminal → Gateway → Balance Manager
                                   ↓           ↓
                            [Find Account  [Check Balance
                             by UUID]       & Charge]
                                   ↓           ↓
                               Ledger ← Balance Manager
                                   ↓
Player ← Terminal ← Gateway ← [Log Transaction]
[Gate Opens]
```

### Example 3: Account Creation with Cards
```
Admin → Account Terminal → Gateway → Key Generator
                            ↓           ↓
                        [Generate  [Create
                         Keypair]   Keypair]
                            ↓           ↓
                        Balance Manager
                            ↓
                        [Create Account
                         with cardUUIDs]
                            ↓
                         Ledger
                            ↓
Admin ← Account Terminal ← [Log Creation]
[Account ID + Private Key]
```

## Configuration Files

Each server can be configured:

- **Ledger:** Auto-save interval, file location
- **Balance Manager:** Balance limits, default prices
- **Key Generator:** Key strength, generation algorithm
- **Gateway:** Wireless channel, encryption settings
- **Deposit Machines:** Diamond value, chest location

## Monitoring & Maintenance

### Health Checks
- Each server reports uptime and status
- Gateway monitors connection to each server
- Auto-restart on crash

### Backups
- Each server auto-saves every 5 minutes
- Manual backup: Copy `.dat` files
- Restore: Place `.dat` files and restart

### Logs
- Ledger contains full transaction history
- Each server logs important events
- Gateway logs all external requests

This architecture provides a robust, secure, and scalable banking system for your Minecraft world with full support for magstripe card payments and signed deposit transactions!
