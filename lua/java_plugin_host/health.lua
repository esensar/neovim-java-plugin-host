local health
if vim.fn.has("nvim-0.8") == 1 then
	health = vim.health
else
	health = require("health")
end

return {
	check = function()
		health.report_start("External dependencies")

		local required_executables = { "mvn" }
		for _, executable in ipairs(required_executables) do
			if vim.fn.has("win32") == 1 then
				executable = executable .. ".exe"
			end
			if vim.fn.executable(executable) == 0 then
				health.report_error(
					executable
						.. " is not executable! You won't be able to use common host or plugins from maven repositories!"
				)
			else
				local handle = io.popen(executable .. " --version")
				local version = handle:read("*a")
				handle:close()
				health.report_ok(version)
			end
		end
	end,
}
