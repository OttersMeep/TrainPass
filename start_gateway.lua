-- Run gateway on dedicated computer (has both wired and wireless modems)

local gateway = require("gateway")

-- Register deposit machines here
-- gateway.registerDepositMachine("DEPOSIT_123", "publicKeyHex...")

gateway.init()
gateway.run()
