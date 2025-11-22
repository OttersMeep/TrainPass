-- Run each server startup script on its dedicated computer

-- LEDGER SERVER (Computer 1)
local ledger = require("ledger_server")
ledger.init()
ledger.run()
