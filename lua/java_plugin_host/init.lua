---@module java_plugin_host Main Java Plugin Host module - used to setup the plugin
---@brief [[
---Provides setup function
---@brief ]]
local executor = require("java_plugin_host.internal.executor")
local log = require("java_plugin_host.internal.log")
local config = require("java_plugin_host.config")

local M = {}

local plugin_host_directory = string.format("%s/java-plugin-host/", vim.fn.stdpath("data"))
local jars_directory = string.format("%s/jars/", plugin_host_directory)
local default_main_class_name = "com.ensarsarajcic.neovim.java.commonhost.CommonPluginHost"

local function spec_to_xml(spec)
	return "            <dependency><groupId>"
		.. spec.group_id
		.. "</groupId><artifactId>"
		.. spec.artifact_id
		.. "</artifactId><version>"
		.. spec.version
		.. "</version></dependency>"
end

local function repo_to_xml(spec)
	return "            <repository><id>" .. spec.id .. "</id><url>" .. spec.url .. "</url></repository>"
end

local function build_temp_pom_xml(specs, repo_specs)
	local list = {
		'<?xml version="1.0" encoding="UTF-8"?>',
		'<project xmlns="http://maven.apache.org/POM/4.0.0"',
		'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"',
		'xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 http://maven.apache.org/xsd/maven-4.0.0.xsd">',
		"    <modelVersion>4.0.0</modelVersion>",
		"    <groupId>com.ensarsarajcic.neovim.java-plugin-host</groupId>",
		"    <artifactId>fake</artifactId>",
		"    <version>1.0.0</version>",
		"    <repositories>",
	}
	vim.list_extend(list, vim.tbl_map(repo_to_xml, repo_specs))
	vim.list_extend(list, {
		"    </repositories>",
		"    <dependencies>",
	})

	vim.list_extend(list, vim.tbl_map(spec_to_xml, specs))

	vim.list_extend(list, {
		"    </dependencies>",
		"</project>",
	})
	return list
end

local function fetch_plugins(common_host_opts, callback)
	executor.ensure_executable("mvn")
	local common_host_name
	if type(common_host_opts.name) == "table" then
		vim.validate({
			["common_host.name.group_id"] = { common_host_opts.name.group_id, "string" },
			["common_host.name.artifact_id"] = { common_host_opts.name.artifact_id, "string" },
			["common_host.name.version"] = { common_host_opts.name.version, "string" },
		})
		common_host_name = common_host_opts.name
	else
		local items = vim.split(common_host_opts.name, ":")
		common_host_name = {
			group_id = items[1],
			artifact_id = items[2],
			version = items[3],
		}
	end
	local jars = {
		common_host_name,
	}
	for _, plugin in ipairs(common_host_opts.hosted_plugins) do
		vim.validate({
			["plugin.name"] = { plugin.name, { "string", "table" } },
		})
		if type(plugin.name) == "table" then
			vim.validate({
				["plugin.name.group_id"] = { plugin.name.group_id, "string" },
				["plugin.name.artifact_id"] = { plugin.name.artifact_id, "string" },
				["plugin.name.version"] = { plugin.name.version, "string" },
			})
		else
			local items = vim.split(plugin.name, ":")
			plugin.name = {
				group_id = items[1],
				artifact_id = items[2],
				version = items[3],
			}
		end
		table.insert(jars, plugin.name)
	end

	local lines = build_temp_pom_xml(jars, common_host_opts.custom_repositories)
	local existing_lines = {}
	if vim.fn.filereadable(plugin_host_directory .. "pom.xml") == 1 then
		existing_lines = vim.fn.readfile(plugin_host_directory .. "pom.xml")
	end
	local changes = true
	if #lines == #existing_lines then
		changes = false
		for i, v in ipairs(existing_lines) do
			if lines[i] ~= v then
				changes = true
				break
			end
		end
	end

	if changes then
		vim.fn.writefile(lines, plugin_host_directory .. "pom.xml")
	end
	executor.run_command("mvn", {
		args = { "clean", "package" },
		uv = {
			cwd = plugin_host_directory,
		},
	}, function(code, _)
		if code > 0 then
			vim.notify(
				"Installing java_plugin_host dependencies failed! Please check "
					.. plugin_host_directory
					.. " and try running `mvn package`",
				vim.log.levels.ERROR
			)
		else
			for _, old_jar in ipairs(vim.split(vim.fn.glob("~/.local/share/nvim/java-plugin-host/jars/*.jar"), "\n")) do
				os.remove(old_jar)
			end
			executor.run_command("mvn", {
				args = {
					"dependency:copy-dependencies",
					"-DprependGroupId=true",
					"-DoutputDirectory=" .. jars_directory,
				},
			}, function(_, _)
				callback()
			end)
		end
	end)
end

---@class JavaPluginHostJarSpec
---@field group_id string
---@field artifact_id string
---@field version string

---@class JavaPluginHostedPluginSpec
---@field name JavaPluginHostJarSpec|string

---@class JavaPluginHostRepositorySpec
---@field url string
---@field id string

---@class JavaPluginHostCommonHostOpts
---@field enabled boolean|nil set to false to disable common host and hosted plugins
---@field name string|JavaPluginHostJarSpec|nil can be set to change common host
---@field main_class_name string|nil if changing common host, also define main class name
---@field hosted_plugins List[JavaPluginHostJarSpec]|nil list of plugins to host
---@field custom_repositories List[JavaPluginHostRepositorySpec]|nil list of custom repositories

---@class JavaPluginHostRPluginsOpts
---@field load_hosted boolean|nil if true, host plugins from rplugin/hosted-jar - true by default
---@field load_standalone boolean|nil if true, load plugins from rplugin/jar as standalone jars
---@field load_class boolean|nil if true, load .class from rplugin/java into the classpath
---@field compile_java boolean|nil if true, compile .java from rplugin/java - set load_class to true to also load

---@class JavaPluginHostSetupOpts
---@field rplugins JavaPluginHostRPluginsOpts|nil configuration related to loading plugins from `rplugin`
---@field common_host JavaPluginHostCommonHostOpts|nil configuration related common plugin host
---@field classpath_extras List[string]|nil additional classpath entries
---@field log_level log_level|nil log level
---@field autostart boolean|nil set to false if you wish to manually start java plugins

local last_level = {}

local function handle_stderr(name, data)
	name = name or "common_host"
	local parts = vim.split(data[1], " ")
	if #parts >= 2 then
		local new_level = string.lower(parts[2])
		if log[new_level] then
			last_level[name] = new_level
		end
	end
	log.named(name)[last_level[name] or "info"](data[1])
end

M.log_level = "info"

local last_opts = nil
M.classpath = {}
local common_host_job_id = nil
local standalone_jobs = {}

local function rebuild_classpath(callback)
	M.classpath = last_opts.classpath_extras or {}
	if last_opts.rplugins.load_class then
		vim.list_extend(M.classpath, vim.api.nvim_get_runtime_file("rplugin/java", true))
	end
	if last_opts.common_host.enabled ~= false then
		fetch_plugins(last_opts.common_host, function()
			vim.list_extend(M.classpath, { jars_directory .. "*" })
			if last_opts.rplugins.load_hosted ~= false then
				vim.list_extend(M.classpath, vim.api.nvim_get_runtime_file("rplugin/hosted-jar/*.jar", true))
			end
			if last_opts.rplugins.compile_java then
				local source_files = vim.api.nvim_get_runtime_file("rplugin/java/**/*.java", true)
				if #source_files > 0 then
					local args = {
						"-classpath",
						vim.fn.join(M.classpath, ":"),
					}
					vim.list_extend(args, source_files)
					executor.run_command("javac", {
						args = args,
					}, function(code, _)
						if code > 0 then
							vim.notify("Compilation for java files failed!", vim.log.levels.ERROR)
						end
						callback()
					end)
				else
					callback()
				end
			else
				callback()
			end
		end)
	end
end

local function start_common_host()
	common_host_job_id = vim.fn.jobstart({
		"java",
		"-Dorg.slf4j.simpleLogger.defaultLogLevel=" .. config.log_level,
		"-classpath",
		vim.fn.join(M.classpath, ":"),
		last_opts.common_host.main_class_name,
	}, {
		rpc = true,
		on_stderr = function(_, data, _)
			handle_stderr(nil, data)
		end,
		on_exit = function(channel_id, code, event)
			if code > 0 then
				vim.notify("Common host exited with code: " .. code .. ". Message: " .. event, vim.log.levels.WARN)
			end
			if channel_id == common_host_job_id then
				common_host_job_id = nil
			end
		end,
	})
end

local function start_standalone_rplugins()
	if last_opts.rplugins.load_standalone then
		local rplugin_jars = vim.api.nvim_get_runtime_file("rplugin/jar/*.jar", true)
		for _, jar in ipairs(rplugin_jars) do
			local key = string.gsub(jar, "%W", "")
			local job_id = vim.fn.jobstart({
				"java",
				"-Dorg.slf4j.simpleLogger.defaultLogLevel=" .. config.log_level,
				"-jar",
				jar,
			}, {
				rpc = true,
				on_stderr = function(_, data, _)
					handle_stderr(key, data)
				end,
				on_exit = function(channel_id, code, event)
					local plugin
					for i, v in ipairs(standalone_jobs) do
						if v.job_id == channel_id then
							plugin = v
							table.remove(standalone_jobs, i)
							break
						end
					end
					plugin = plugin or {}
					if code > 0 then
						vim.notify(
							"Standalone plugin ("
								.. plugin.path
								.. ") exited with code "
								.. code
								.. ". Message: "
								.. event,
							vim.log.levels.WARN
						)
					end
				end,
			})
			table.insert(standalone_jobs, { job_id = job_id, key = key, path = jar })
		end
	end
end

---Start up the host and all plugins
---@param opts JavaPluginHostSetupOpts
function M.setup(opts)
	if last_opts ~= nil then
		return
	end
	vim.fn.mkdir(plugin_host_directory, "p")
	vim.fn.mkdir(log.logdir, "p")
	opts = opts or {}
	opts.rplugins = opts.rplugins or {}
	opts.common_host = opts.common_host or {}
	opts.common_host.hosted_plugins = opts.common_host.hosted_plugins or {}
	opts.common_host.custom_repositories = opts.common_host.custom_repositories or {}
	opts.common_host.name = opts.common_host.name
		or {
			group_id = "com.ensarsarajcic.neovim.java",
			artifact_id = "plugins-common-host",
			version = "0.4.6",
		}
	opts.common_host.main_class_name = opts.common_host.main_class_name or default_main_class_name

	if opts.log_level then
		config.log_level = opts.log_level
	end

	last_opts = opts
	rebuild_classpath(function()
		if opts.autostart ~= false then
			start_common_host()
		end
	end)

	if opts.autostart ~= false then
		start_standalone_rplugins()
	end

	vim.api.nvim_create_user_command("NeovimJavaLogs", function(c)
		local name = c.args
		if string.len(name) == 0 then
			name = nil
		end
		M.open_logs(name)
	end, {
		nargs = "?",
		desc = "Open neovim java plugin logs in a new buffer",
		complete = function(_)
			return vim.tbl_map(function(x)
				return x.key
			end, standalone_jobs)
		end,
	})
end

function M.rebuild_classpath(classpath_callback)
	rebuild_classpath(function()
		classpath_callback(M.classpath)
	end)
end

function M.restart()
	if common_host_job_id ~= nil or not vim.tbl_isempty(standalone_jobs) then
		M.stop()
		M.start()
	end
end

function M.start()
	if common_host_job_id == nil and vim.tbl_isempty(standalone_jobs) then
		start_common_host()
		start_standalone_rplugins()
	end
end

function M.stop()
	if common_host_job_id ~= nil then
		vim.fn.jobstop(common_host_job_id)
		common_host_job_id = nil
	end
	for _, v in ipairs(standalone_jobs) do
		vim.fn.jobstop(v.job_id)
	end
	standalone_jobs = {}
end

function M.open_logs(name)
	vim.cmd("edit " .. log.logfile(name))
end

function M.request(...)
	if common_host_job_id == nil then
		error("Common host is not started", vim.log.levels.ERROR)
	end
	vim.fn.rpcrequest(common_host_job_id, ...)
end

function M.notify(...)
	if common_host_job_id == nil then
		error("Common host is not started", vim.log.levels.ERROR)
	end
	vim.fn.rpcnotify(common_host_job_id, ...)
end

function M.get_standalone_jobs()
	return vim.deepcopy(standalone_jobs)
end

return M
