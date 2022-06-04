---@mod java_plugin_host.config Java plugin host plugin config module
---@brief [[
---Provides current plugin configuration
---Don't change directly, use `java_plugin_host.setup{}` instead
---Can be used for read-only access
---@brief ]]

local M = {}

---Current log level
---@type log_level
M.log_level = "info"

return M
