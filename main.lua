local luvi = require("luvi")

local function bootstapImport(name)
    local data = assert(luvi.bundle.readfile("deps/" .. name .. ".lua"))

    local environment = setmetatable({import = bootstapImport, bootstrapping = true}, {__index = _G})

    local fn = assert(load(data, "bootstrap:" .. name, "t", environment))

    return fn()
end

local bootstrapped_import = bootstapImport("import")
local importlib = bootstrapped_import.bundle:import("import")

local module, import = importlib.bundle, importlib.bundle.importFn

local function printVersion()
    local luvit_version = import("package.lua").version
    local luvi_version = luvi.version
    print("Luvit " .. luvit_version .. " (Luvi " .. luvi_version .. ")")
end

local function printUsage(argument, needs_argument)
    if needs_argument then
        print("'" .. argument .. "' needs argument")
    else
        print("unrecognized option '" .. argument .. "'")
    end

    print("usage: " .. args[0] .. " [options] [script [args]]")
    print([[
Available options are:
  -e chunk  Execute string 'chunk'
  -l name   Require library 'name' into global 'name'
  -i        Enter interactive mode after executing 'script'
  -v        Show version information
  --        Stop handling options
    ]])
end

return import("init.lua")(function(...)
    local options = {eval = {}, load = {}}

    local i = 1
    local arg = args[i]
    while arg do
        if string.sub(arg, 1, 2) == "--" then
            if arg == "--" then
                i = i + 1

                break
            else
                error("invalid argument: " .. arg)
            end
        end

        if string.sub(arg, 1, 1) ~= "-" then
            break
        else
            if arg == "-i" then
                options.interactive = true
                options.version = true
            elseif arg == "-v" then
                options.version = true
            elseif arg == "-e" then
                i = i + 1

                local next_arg = args[i]
                if not next_arg or string.sub(next_arg, 1, 1) == "-" then
                    return printUsage(arg, true)
                end

                table.insert(options.eval, next_arg)
            elseif arg == "-l" then
                i = i + 1

                local next_arg = args[i]
                if not next_arg or string.sub(next_arg, 1, 1) == "-" then
                    return printUsage(arg, true)
                end

                table.insert(options.load, next_arg)
            else
                return printUsage(arg, false)
            end
        end

        i = i + 1
        arg = args[i]
    end

    options.script = args[i]

    if options.version then
        printVersion()
    end

    for _, name in ipairs(options.load) do
        _G[name] = require(name)
    end

    for _, chunk in ipairs(options.eval) do
        local fn, err = load(chunk, "(command line)", "t")

        if not fn then
            print(args[0] .. ": " .. err)
        end

        fn()
    end


end, ...)
