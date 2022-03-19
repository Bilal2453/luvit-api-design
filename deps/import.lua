local luvi_path = require("luvipath")
local luvi = require("luvi")
local uv = require("uv")

local luvi_bundle = luvi.bundle

local function normalizePath(path)
    local bundled_path = string.match(path, "^bundle:/(.+)")

    if bundled_path then
        return 'bundle:' .. luvi_path.pathJoin("/", bundled_path)
    else
        return luvi_path.pathJoin("/", path)
    end
end

-- dependency names are not allowed to have special segments, as they allow traversing the directory tree.
local function isValidDependency(name)
    if name == "" then
        return false
    end

    for segment in string.gmatch(name, "([^/]+)") do
        if segment == "." or segment == ".." then
            return false
        end
    end

    return true
end

---@class std.import
local importlib = {}

-- This is where we store the modules we've already imported.
package.imported = {}

local stat_cache = {}

local function statFile(path)
    assert(type(path) == "string", "path must be a string")

    if stat_cache[path] then
        return stat_cache[path]
    end

    local bundled_path = string.match(path, "^bundle:/(.+)")

    local stat, err
    if bundled_path then
        stat, err = luvi_bundle.stat(bundled_path)
    else
        stat, err = uv.fs_stat(path)
    end

    if not stat then
        return nil, err
    end

    stat_cache[path] = stat

    return stat
end

local function readFile(path)
    assert(type(path) == "string", "path must be a string")

    local bundled_path = string.match(path, "^bundle:/(.+)")

    if bundled_path then
        return luvi_bundle.readfile(bundled_path)
    else
        local stat, fd, data, err

        stat, err = statFile(path)

        if not stat then
            return nil, err
        end

        fd, err = uv.fs_open(path, "r", 0)
        if err then
            -- if we can't open the file, evict it from the cache, because it may not be accessible anymore
            if stat_cache[path] then
                stat_cache[path] = nil
            end

            return nil, err
        end

        data, err = uv.fs_read(fd, stat.size, 0)

        uv.fs_close(fd)

        return data, err
    end
end

---@class std.import.Module
local Module = import("class").create("std.import.Module")
importlib.Module = Module

---@param entrypoint path_t
---@param parent? std.import.Module
---@param package? boolean
function Module:init(entrypoint, parent, package)
    self.is_bundle = entrypoint:sub(1, 7) == "bundle:"

    if self.is_bundle then
        local unbundled = string.sub(entrypoint, 8)

        self.file = "bundle:" .. normalizePath(unbundled)
    else
        self.file = normalizePath(entrypoint)
    end

    ---@type string
    self.dir = string.match(self.file, "^(.+)/[^/]+$")

    if parent then
        self.absolute_root = parent.absolute_root

        if package then
            self.package_root = parent.dir
        else
            self.package_root = parent.package_root
        end
    else
        self.absolute_root = self.dir
        self.package_root = self.dir
    end

    self.exports = {}

    function self.importFn(...)
        return self:import(...)
    end
end

---@param name string
---@param attempt_libs boolean
---@param path_attempts? table
---@return string
---@error nil, string
function Module:resolveRelative(name, attempt_libs, path_attempts)
    assert(type(name) == "string", "name must be a string")
    assert(type(attempt_libs) == "boolean", "attempt_libs must be a boolean")
    assert(path_attempts == nil or type(path_attempts) == "table", "path_attempts must be a table if provided")

    local path_relative = normalizePath(self.dir .. "/" .. name)

    if path_relative:sub(1, #self.package_root) ~= self.package_root then
        return nil, "attempt to leave project root"
    end

    if statFile(path_relative) then
        return path_relative, "relative"
    elseif path_attempts then
        table.insert(path_attempts, "no file '" .. path_relative .. "'")
    end

    if attempt_libs then
        return self:resolveLibrary(name, path_attempts)
    end

    return nil, "file not found"
end

---@param name string
---@param path_attempts? table
---@return string
---@error nil, string
function Module:resolveLibrary(name, path_attempts)
    assert(type(name) == "string", "name must be a string")
    assert(path_attempts == nil or type(path_attempts) == "table", "path_attempts must be a table if provided")

    if not isValidDependency(name) then
        return nil, "invalid dependency name"
    end

    local path_libs_single = self.package_root .. "/libs" .. normalizePath(name)

    if statFile(path_libs_single) then
        return path_libs_single, "library"
    elseif path_attempts then
        table.insert(path_attempts, "no file '" .. path_libs_single .. "'")
    end

    if not self.is_bundle then
        return importlib.bundle:resolveLibrary(name, path_attempts)
    else
        return nil, "library not found"
    end
end

---@param name string
---@param path_attempts? table
---@return string
---@error nil, string
function Module:resolvePackage(name, path_attempts)
    assert(type(name) == "string", "name must be a string")
    assert(path_attempts == nil or type(path_attempts) == "table", "path_attempts must be a table if provided")

    if not isValidDependency(name) then
        return nil, "invalid dependency name"
    end

    local path_deps_single = self.absolute_root .. "/deps" .. normalizePath(name) .. ".lua"
    local path_deps_directory = self.absolute_root .. "/deps" .. normalizePath(name) .. "/init.lua"

    if statFile(path_deps_single) then
        return path_deps_single, "package"
    elseif path_attempts then
        table.insert(path_attempts, "no file '" .. path_deps_single .. "'")
    end

    if statFile(path_deps_directory) then
        return path_deps_directory, "package"
    elseif path_attempts then
        table.insert(path_attempts, "no file '" .. path_deps_directory .. "'")
    end

    if not self.is_bundle then
        return importlib.bundle:resolvePackage(name, path_attempts)
    else
        return nil, "package not found"
    end
end

---@param name string
---@param path_attempts? table
---@return string
---@error nil, string
function Module:resolve(name, path_attempts)
    assert(type(name) == "string", "name must be a string")
    assert(path_attempts == nil or type(path_attempts) == "table", "path_attempts must be a table if provided")

    if string.sub(name, -4) == ".lua" then
        return self:resolveRelative(name, true, path_attempts)
    else
        return self:resolvePackage(name, path_attempts)
    end
end

---@param name string
---@return std.fs.stat_info
function Module:stat(name)
    assert(type(name) == "string", "name must be a string")

    local path = self:resolveRelative(name, false)

    return statFile(path)
end

---@param name string
---@return string
function Module:load(name)
    assert(type(name) == "string", "name must be a string")

    local path = self:resolveRelative(name, false)

    return readFile(path)
end

local error_padding = "\n        "

---@param name string
---@vararg any
---@return any
function Module:import(name, ...)
    assert(type(name) == "string", "name must be a string")

    local path_attempts = {}

    local path, kind, data, fn, err

    path, err = self:resolve(name, path_attempts)
    if not path then
        local message = err .. ": '" .. name .. "'"
        if #path_attempts > 0 then
            message = message .. ":" .. error_padding .. table.concat(path_attempts, error_padding)
        end

        error(message)
    else
        kind = err
    end

    if package.imported[path] then
        return package.imported[path].exports
    end

    data, err = readFile(path)
    if not data then
        error("error loading module '" .. name .. "' from file '" .. path .. "':" .. error_padding .. err)
    end

    ---@type std.import.Module
    local new_module = Module(path, self, kind == "package")

    local environment = setmetatable({
        module = new_module,
        import = new_module.importFn,
    }, {__index = _G})

    fn = assert(load(data, path, "t", environment))
    if not fn then
        error("error loading module '" .. name .. "' from file '" .. path .. "':" .. error_padding .. err)
    end

    local ret = fn(...)

    if ret ~= nil then
        new_module.exports = ret
    end

    package.imported[path] = new_module

    return new_module.exports
end

importlib.bundle = Module("bundle:/main.lua")

return importlib
