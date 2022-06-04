---@brief [[
---Internal library for logging
---Parts of this are taken from https://github.com/nvim-lua/plenary.nvim/blob/master/lua/plenary/log.lua
---This was done to avoid dependency on plenary.nvim, but a lot of people probably already use it anyways,
---so maybe this can be removed at a later point
---@brief ]]
local config = require("java_plugin_host.config")
local M = {}

M.logfile = string.format("%s/%s.log", vim.api.nvim_call_function("stdpath", { "cache" }), "java_plugin_host")

M.level = config.log_level

-- Level configuration
M.modes = {
	{ name = "trace", hl = "Comment" },
	{ name = "debug", hl = "Comment" },
	{ name = "info", hl = "None" },
	{ name = "warn", hl = "WarningMsg" },
	{ name = "error", hl = "ErrorMsg" },
	{ name = "fatal", hl = "ErrorMsg" },
}

M.levels = {}
for i, v in ipairs(M.modes) do
	M.levels[v.name] = i
end

local make_string = function(...)
	local t = {}
	for i = 1, select("#", ...) do
		t[#t + 1] = vim.inspect(select(i, ...))
	end
	return table.concat(t, " ")
end

function M.log_at_level(level, level_config, message_maker, ...)
	-- Return early if we're below the config.level
	if level < M.levels[M.level] then
		return
	end
	local nameupper = level_config.name:upper()

	local msg = message_maker(...)

	local fp = assert(io.open(M.logfile, "a"))
	local str = string.format("[%-6s%s]: %s\n", nameupper, os.date(), msg)
	fp:write(str)
	fp:close()
end

for i, x in ipairs(M.modes) do
	-- log.info("these", "are", "separated")
	M[x.name] = function(...)
		return M.log_at_level(i, x, make_string, ...)
	end

	-- log.fmt_info("These are %s strings", "formatted")
	M[("fmt_%s"):format(x.name)] = function(...)
		return M.log_at_level(i, x, function(...)
			local passed = { ... }
			local fmt = table.remove(passed, 1)
			local inspected = {}
			for _, v in ipairs(passed) do
				table.insert(inspected, vim.inspect(v))
			end
			return string.format(fmt, unpack(inspected))
		end, ...)
	end
end

return M
