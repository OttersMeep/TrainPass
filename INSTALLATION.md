# TrainPass Installation Guide

Complete instructions for downloading and installing the TrainPass Banking System from GitHub to your ComputerCraft computers.

## Repository Information

**GitHub Repository:** `OttersMeep/TrainPass`  
**Base URL:** `https://raw.githubusercontent.com/OttersMeep/TrainPass/main/`

## Prerequisites

- ComputerCraft or CC:Tweaked installed
- HTTP API enabled in ComputerCraft config
- Advanced Computers (for all servers and clients)
- Wired modems for server room
- Wireless modems for gateway and clients
- Disk drive for Server Manager

## Quick Installation Scripts

### Universal Downloader

Use this helper script on any computer to download files:

```lua
-- download.lua - Universal file downloader
local baseUrl = "https://raw.githubusercontent.com/OttersMeep/TrainPass/main/"

local function downloadFile(filename)
    print("Downloading " .. filename .. "...")
    local url = baseUrl .. filename
    local response = http.get(url)
    
    if not response then
        print("ERROR: Failed to download " .. filename)
        return false
    end
    
    local content = response.readAll()
    response.close()
    
    local file = fs.open(filename, "w")
    file.write(content)
    file.close()
    
    print("  Downloaded: " .. filename)
    return true
end

-- Get list of files to download from arguments
local args = {...}
if #args == 0 then
    print("Usage: download <file1> <file2> ...")
    print("Example: download ecc.lua ledger_server.lua start_ledger.lua")
    return
end

print("=== TrainPass Downloader ===")
print("Repository: OttersMeep/TrainPass")
print("")

local success = 0
local failed = 0

for _, filename in ipairs(args) do
    if downloadFile(filename) then
        success = success + 1
    else
        failed = failed + 1
    end
end

print("")
print("Complete! Success: " .. success .. ", Failed: " .. failed)
```

Save this as `download.lua` on each computer, then use it to download the required files.

## Server Room Installation

The server room consists of 4 computers connected via wired modems.

### Computer 1: Ledger Server

```lua
-- Paste this entire command block:
local files = {"ecc.lua", "ledger_server.lua", "start_ledger.lua"}
local base = "https://raw.githubusercontent.com/OttersMeep/TrainPass/main/"
for _, f in ipairs(files) do
    print("Downloading " .. f)
    local r = http.get(base .. f)
    if r then
        local file = fs.open(f, "w")
        file.write(r.readAll())
        file.close()
        r.close()
    end
end
print("Done! Run: lua start_ledger.lua")
```

**Or using wget:**
```bash
wget https://raw.githubusercontent.com/OttersMeep/TrainPass/main/ecc.lua ecc.lua
wget https://raw.githubusercontent.com/OttersMeep/TrainPass/main/ledger_server.lua ledger_server.lua
wget https://raw.githubusercontent.com/OttersMeep/TrainPass/main/start_ledger.lua start_ledger.lua
```

**Then start:**
```bash
lua start_ledger.lua
```

---

### Computer 2: Balance Manager

```lua
-- Paste this entire command block:
local files = {"ecc.lua", "balance_manager.lua", "start_balance_manager.lua"}
local base = "https://raw.githubusercontent.com/OttersMeep/TrainPass/main/"
for _, f in ipairs(files) do
    print("Downloading " .. f)
    local r = http.get(base .. f)
    if r then
        local file = fs.open(f, "w")
        file.write(r.readAll())
        file.close()
        r.close()
    end
end
print("Done! Run: lua start_balance_manager.lua")
```

**Or using wget:**
```bash
wget https://raw.githubusercontent.com/OttersMeep/TrainPass/main/ecc.lua ecc.lua
wget https://raw.githubusercontent.com/OttersMeep/TrainPass/main/balance_manager.lua balance_manager.lua
wget https://raw.githubusercontent.com/OttersMeep/TrainPass/main/start_balance_manager.lua start_balance_manager.lua
```

**Then start:**
```bash
lua start_balance_manager.lua
```

---

### Computer 3: Key Generator

```lua
-- Paste this entire command block:
local files = {"ecc.lua", "key_generator.lua", "start_key_generator.lua"}
local base = "https://raw.githubusercontent.com/OttersMeep/TrainPass/main/"
for _, f in ipairs(files) do
    print("Downloading " .. f)
    local r = http.get(base .. f)
    if r then
        local file = fs.open(f, "w")
        file.write(r.readAll())
        file.close()
        r.close()
    end
end
print("Done! Run: lua start_key_generator.lua")
```

**Or using wget:**
```bash
wget https://raw.githubusercontent.com/OttersMeep/TrainPass/main/ecc.lua ecc.lua
wget https://raw.githubusercontent.com/OttersMeep/TrainPass/main/key_generator.lua key_generator.lua
wget https://raw.githubusercontent.com/OttersMeep/TrainPass/main/start_key_generator.lua start_key_generator.lua
```

**Then start:**
```bash
lua start_key_generator.lua
```

---

### Computer 4: Gateway

**IMPORTANT:** Gateway needs BOTH wired AND wireless modems!

```lua
-- Paste this entire command block:
local files = {"ecc.lua", "gateway.lua", "start_gateway.lua"}
local base = "https://raw.githubusercontent.com/OttersMeep/TrainPass/main/"
for _, f in ipairs(files) do
    print("Downloading " .. f)
    local r = http.get(base .. f)
    if r then
        local file = fs.open(f, "w")
        file.write(r.readAll())
        file.close()
        r.close()
    end
end
print("Done! Run: lua start_gateway.lua")
```

**Or using wget:**
```bash
wget https://raw.githubusercontent.com/OttersMeep/TrainPass/main/ecc.lua ecc.lua
wget https://raw.githubusercontent.com/OttersMeep/TrainPass/main/gateway.lua gateway.lua
wget https://raw.githubusercontent.com/OttersMeep/TrainPass/main/start_gateway.lua start_gateway.lua
```

**Then start:**
```bash
lua start_gateway.lua
```

---

### Computer 5: Server Manager (Optional but Recommended)

**Requirements:** Wired modem, disk drive on RIGHT side, dropper on TOP, hopper on BOTTOM

```lua
-- Paste this entire command block:
local files = {"ecc.lua", "server_manager.lua", "start_server_manager.lua", "deposit_machine_client.lua", "payment_terminal.lua"}
local base = "https://raw.githubusercontent.com/OttersMeep/TrainPass/main/"
for _, f in ipairs(files) do
    print("Downloading " .. f)
    local r = http.get(base .. f)
    if r then
        local file = fs.open(f, "w")
        file.write(r.readAll())
        file.close()
        r.close()
    end
end
print("Done! Run: lua start_server_manager.lua")
```

**Or using wget:**
```bash
wget https://raw.githubusercontent.com/OttersMeep/TrainPass/main/ecc.lua ecc.lua
wget https://raw.githubusercontent.com/OttersMeep/TrainPass/main/server_manager.lua server_manager.lua
wget https://raw.githubusercontent.com/OttersMeep/TrainPass/main/start_server_manager.lua start_server_manager.lua
wget https://raw.githubusercontent.com/OttersMeep/TrainPass/main/deposit_machine_client.lua deposit_machine_client.lua
wget https://raw.githubusercontent.com/OttersMeep/TrainPass/main/payment_terminal.lua payment_terminal.lua
```

**Then start:**
```bash
lua start_server_manager.lua
```

**Usage:**
```bash
> register deposit 10      # Provision 10 deposit machines
> register terminal 5      # Provision 5 payment terminals
> list                     # List registered machines
```

---

## Manual Client Installation (Without Server Manager)

### Deposit Machine

```lua
-- Paste this entire command block:
local files = {"ecc.lua", "deposit_machine_client.lua"}
local base = "https://raw.githubusercontent.com/OttersMeep/TrainPass/main/"
for _, f in ipairs(files) do
    print("Downloading " .. f)
    local r = http.get(base .. f)
    if r then
        local file = fs.open(f, "w")
        file.write(r.readAll())
        file.close()
        r.close()
    end
end
print("Done! Edit deposit_machine_client.lua to configure, then run it")
```

**Configure before running:**
1. Edit `deposit_machine_client.lua`
2. Set `machineId`, `privateKey`, `diamondValue`, `chestSide`
3. Run: `lua deposit_machine_client.lua`

---

### Payment Terminal

```lua
-- Paste this entire command block:
local files = {"ecc.lua", "payment_terminal.lua"}
local base = "https://raw.githubusercontent.com/OttersMeep/TrainPass/main/"
for _, f in ipairs(files) do
    print("Downloading " .. f)
    local r = http.get(base .. f)
    if r then
        local file = fs.open(f, "w")
        file.write(r.readAll())
        file.close()
        r.close()
    end
end
print("Done! Edit payment_terminal.lua to configure, then run it")
```

**Configure before running:**
1. Edit `payment_terminal.lua`
2. Set `vendorId`, `vendorType`, `defaultAmount`, `location`
3. Integrate with your magstripe mod
4. Run: `lua payment_terminal.lua`

---

## Pastebin Alternative (If GitHub is blocked)

If your server blocks GitHub, upload files to pastebin.com and use:

```bash
pastebin get <code> filename.lua
```

Example:
```bash
pastebin get AbCd1234 ecc.lua
pastebin get EfGh5678 ledger_server.lua
pastebin get IjKl9012 start_ledger.lua
```

---

## One-Line Installer (Advanced)

Install the entire server room with one command on each computer:

**Ledger:**
```bash
wget run https://raw.githubusercontent.com/OttersMeep/TrainPass/main/install_ledger.lua
```

**Balance Manager:**
```bash
wget run https://raw.githubusercontent.com/OttersMeep/TrainPass/main/install_balance.lua
```

**Key Generator:**
```bash
wget run https://raw.githubusercontent.com/OttersMeep/TrainPass/main/install_keygen.lua
```

**Gateway:**
```bash
wget run https://raw.githubusercontent.com/OttersMeep/TrainPass/main/install_gateway.lua
```

**Server Manager:**
```bash
wget run https://raw.githubusercontent.com/OttersMeep/TrainPass/main/install_manager.lua
```

*(Note: Create these installer scripts if you want one-line setup)*

---

## Verification

After downloading files on each server, verify:

```bash
ls
```

**Expected files per server:**

- **Ledger:** `ecc.lua`, `ledger_server.lua`, `start_ledger.lua`
- **Balance Manager:** `ecc.lua`, `balance_manager.lua`, `start_balance_manager.lua`
- **Key Generator:** `ecc.lua`, `key_generator.lua`, `start_key_generator.lua`
- **Gateway:** `ecc.lua`, `gateway.lua`, `start_gateway.lua`
- **Server Manager:** `ecc.lua`, `server_manager.lua`, `start_server_manager.lua`, `deposit_machine_client.lua`, `payment_terminal.lua`

---

## Startup Order

Start servers in this order:

1. **Ledger Server** (channel 100)
2. **Key Generator** (channel 102)
3. **Balance Manager** (channel 101)
4. **Gateway** (wireless 1000, wired 101)
5. **Server Manager** (optional)

Each server will display a startup message when ready.

---

## Troubleshooting

### HTTP is disabled
Edit `config/computercraft-server.toml` or `config/computercraft-common.toml`:
```toml
[http]
    enabled = true
```

### Download fails
- Check internet connection
- Verify HTTP is enabled in ComputerCraft config
- Try using pastebin instead
- Manually copy files via disk drive

### File not found
- Verify repository name: `OttersMeep/TrainPass`
- Check branch name (main/master)
- Ensure file exists in repository

### Permission denied
- Make sure you're using an Advanced Computer (not Basic Computer)
- Check disk space: `df`

---

## Updates

To update files, simply re-download them:

```bash
delete ecc.lua
delete ledger_server.lua
delete start_ledger.lua
# Then re-run download commands
```

Or use:
```bash
wget https://raw.githubusercontent.com/OttersMeep/TrainPass/main/ecc.lua ecc.lua
```

**Note:** Back up `.dat` files before updating!

---

## Complete File List

| File | Used By | Purpose |
|------|---------|---------|
| `ecc.lua` | All | Cryptography library |
| `ledger_server.lua` | Ledger | Transaction logging |
| `balance_manager.lua` | Balance Manager | Account management |
| `key_generator.lua` | Key Generator | Keypair generation |
| `gateway.lua` | Gateway | Network gateway |
| `server_manager.lua` | Server Manager | Machine provisioning |
| `deposit_machine_client.lua` | Deposit Machines | Diamond deposits |
| `payment_terminal.lua` | Payment Terminals | Card payments |
| `start_ledger.lua` | Ledger | Startup script |
| `start_balance_manager.lua` | Balance Manager | Startup script |
| `start_key_generator.lua` | Key Generator | Startup script |
| `start_gateway.lua` | Gateway | Startup script |
| `start_server_manager.lua` | Server Manager | Startup script |

---

## Support

- **Documentation:** See `README.md` and `DISTRIBUTED_ARCHITECTURE.md` in the repository
- **Issues:** Report on GitHub: `https://github.com/OttersMeep/TrainPass/issues`
- **Deployment Guide:** See `DEPLOYMENT.md` for detailed setup instructions

---

## Quick Start Summary

```bash
# On each server, paste the appropriate download block above
# Then start servers in order:

# Server 1 (Ledger)
lua start_ledger.lua

# Server 2 (Balance Manager)  
lua start_balance_manager.lua

# Server 3 (Key Generator)
lua start_key_generator.lua

# Server 4 (Gateway)
lua start_gateway.lua

# Server 5 (Server Manager - optional)
lua start_server_manager.lua
```

Your banking system is now installed and running! 🎉
