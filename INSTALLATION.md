# TrainPass Installation Guide
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

### Ledger Server
```
download ledger_server.lua startup.lua
```
### Balance Manager
```
download balance_manager.lua startup.lua ecc.lua
```
### Gateway Server
```
dowload gateway.lua startup.lua ecc.lua
```
### Keygen Server
```
download key_generator_server.lua startup.lua ecc.lua
```
### Server Registration
```
download deposit_machine_client.lua account_portal.lua ecc.lua server_manager.lua startup.lua
```
