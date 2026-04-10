"""
    Trim-safe logging primitives for Mongoose.jl.

    `@info` / `@warn` / `@error` route through `Base.CoreLogging`
    (abstract dispatch on `global_logger()`), which may be silently
    dropped or crash in `juliac --trim=safe` compiled binaries.

    These functions write directly to `Core.stdout` / `Core.stderr` —
    concrete boot-time `IOStream` values that survive aggressive code
    trimming and have no platform-specific ABI naming differences
    (unlike `ccall(:write, ...)` vs `ccall(:_write, ...)` on Windows).

    The exception-printing path wraps `sprint(showerror, e)` in a
    try/catch so that if `showerror` specialisations are trimmed the
    output degrades gracefully to the exception type name rather than
    crashing.
"""

# Raw pre-formatted output to stdout — used by the styled (ANSI) log paths.
@noinline _print(s::String) = print(Core.stdout, s)

# Add colors?
# Plain-text structured log lines — used when styled=false or in trim=safe binaries.
@noinline _log_info(msg::String)  = print(Core.stdout, "[Info] [Mongoose] ", msg, "\n")
@noinline _log_warn(msg::String)  = print(Core.stderr, "[Warn] [Mongoose] ", msg, "\n")
@noinline _log_error(msg::String) = print(Core.stderr, "[Error] [Mongoose] ", msg, "\n")

@noinline function _log_error(msg::String, e::Exception)
    estr = try
        sprint(showerror, e)
    catch
        string(nameof(typeof(e)))
    end
    print(Core.stderr, "[Error] [Mongoose] ", msg, ": ", estr, "\n")
end
