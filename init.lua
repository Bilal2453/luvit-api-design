local uv = require("uv")

return function(main, ...)
    -- Seed Lua's RNG
    math.randomseed(os.time())

    local success, err = xpcall(function(...)
        main(...)

        uv.run()
    end, function(err)
        return debug.traceback(err)
    end, ...)

    if success then
        os.exit(0)
    else
        io.stderr:write("uncaught exception: " .. err .. "\n")
        os.exit(1)
    end
end
