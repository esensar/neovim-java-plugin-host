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

local function build_temp_pom_xml(specs)
	local list = {
		'<?xml version="1.0" encoding="UTF-8"?>',
		'<project xmlns="http://maven.apache.org/POM/4.0.0"',
		'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"',
		'xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 http://maven.apache.org/xsd/maven-4.0.0.xsd">',
		"    <modelVersion>4.0.0</modelVersion>",
		"    <groupId>com.ensarsarajcic.neovim.java-plugin-host</groupId>",
		"    <artifactId>fake</artifactId>",
		"    <version>1.0.0</version>",
		"    <dependencies>",
	}

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

	local lines = build_temp_pom_xml(jars)
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
	else
		callback()
	end
end

---@class JavaPluginHostJarSpec
---@field group_id string
---@field artifact_id string
---@field version string

---@class JavaPluginHostHostedPluginOpts
---@field name string|JavaPluginHostJarSpec|nil fill name <groupId>:<artifactId>:<version>
---@field repository string|nil custom repository to use, uses system default otherwise

---@class JavaPluginHostCommonHostOpts
---@field enabled boolean|nil set to false to disable common host and hosted plugins
---@field name string|JavaPluginHostJarSpec|nil can be set to change common host
---@field main_class_name string|nil if changing common host, also define main class name
---@field hosted_plugins List[JavaPluginHostJarSpec]|nil list of plugins to host

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

local last_level = "info"

local function handle_stderr(channel_id, data)
	local parts = vim.split(data[1], " ")
	if #parts >= 2 then
		local new_level = string.lower(parts[2])
		if log[new_level] then
			last_level = new_level
		end
	end
	log[last_level](data[1], " -- RPC Channel: " .. channel_id)
end

M.log_level = "info"

---Start up the host and all plugins
---@param opts JavaPluginHostSetupOpts
function M.setup(opts)
	vim.fn.mkdir(plugin_host_directory, "p")
	opts = opts or {}
	opts.rplugins = opts.rplugins or {}
	opts.common_host = opts.common_host or {}
	opts.common_host.hosted_plugins = opts.common_host.hosted_plugins or {}
	opts.common_host.name = opts.common_host.name
		or {
			group_id = "com.ensarsarajcic.neovim.java",
			artifact_id = "plugins-common-host",
			version = "0.4.1",
		}
	opts.common_host.main_class_name = opts.common_host.main_class_name or default_main_class_name

	if opts.log_level then
		config.log_level = opts.log_level
	end

	local classpath = opts.classpath_extras or {}
	if opts.rplugins.load_class then
		vim.list_extend(classpath, vim.api.nvim_get_runtime_file("rplugin/java/*.class"))
	end
	if opts.common_host.enabled ~= false then
		fetch_plugins(opts.common_host, function()
			vim.list_extend(classpath, { jars_directory .. "*" })
			if opts.rplugins.load_hosted ~= false then
				vim.list_extend(classpath, vim.api.nvim_get_runtime_file("rplugin/hosted-jar/*.jar", true))
			end
			vim.fn.jobstart({
				"java",
				"-classpath",
				vim.fn.join(classpath, ":"),
				opts.common_host.main_class_name,
			}, {
				rpc = true,
				on_stderr = function(channel_id, data, _)
					handle_stderr(channel_id, data)
				end,
			})
			vim.notify("Java plugin host started successfully!")
		end)
	end

	if opts.rplugins.load_standalone then
		local rplugin_jars = vim.api.nvim_get_runtime_file("rplugin/jar/*.jar", true)
		for _, jar in ipairs(rplugin_jars) do
			vim.fn.jobstart({
				"java",
				"-jar",
				jar,
			}, {
				rpc = true,
				on_stderr = function(channel_id, data, _)
					handle_stderr(channel_id, data)
				end,
			})
		end
	end

	if opts.rplugins.compile_java then
		local source_files = vim.api.nvim_get_runtime_file("rplugin/java/*.java", true)
		for _, source_file in ipairs(source_files) do
			executor.run_command("javac", {
				args = {
					"-cp",
					"-classpath",
					vim.fn.join(classpath, ":"),
					source_file,
				},
			}, function(code, _)
				if code > 0 then
					vim.notify("Compilation for " .. source_file .. " failed!", vim.log.levels.ERROR)
				end
			end)
		end
	end
end

return M
