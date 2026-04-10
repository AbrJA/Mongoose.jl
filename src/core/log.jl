"""
    Trim-safe logging primitives for Mongoose.jl.

    Writes directly to `Core.stdout` / `Core.stderr` — concrete boot-time
    `IOStream` values that survive `juliac --trim=safe` without the abstract
    dispatch overhead of `@info` / `@warn` / `@error`. Color support is
    detected once at module load via `isatty` and cached, so there is zero
    overhead on the hot logging path.
"""

# Windows CRT exports _isatty; POSIX systems export isatty.
@static if Sys.iswindows()
    const _STDOUT_COLOR = ccall(:_isatty, Cint, (Cint,), Cint(1)) != 0
    const _STDERR_COLOR = ccall(:_isatty, Cint, (Cint,), Cint(2)) != 0
else
    const _STDOUT_COLOR = ccall(:isatty, Cint, (Cint,), Cint(1)) != 0
    const _STDERR_COLOR = ccall(:isatty, Cint, (Cint,), Cint(2)) != 0
end

const _R  = "\e[0m"
const _B  = "\e[1m"
const _D  = "\e[2m"
const _CY = "\e[36m"
const _YL = "\e[33m"
const _RD = "\e[31m"

"Write a pre-formatted ANSI string directly to stdout. Used by the styled log paths."
@noinline _print(s::String) = print(Core.stdout, s)

@noinline function _log_info(msg::String)
    if _STDOUT_COLOR
        print(Core.stdout, _CY, _B, "[ Info]", _R, " [Mongoose] ", msg, "\n")
    else
        print(Core.stdout, "[ Info] [Mongoose] ", msg, "\n")
    end
end

@noinline function _log_warn(msg::String)
    if _STDERR_COLOR
        print(Core.stderr, _YL, _B, "[ Warn]", _R, " [Mongoose] ", msg, "\n")
    else
        print(Core.stderr, "[ Warn] [Mongoose] ", msg, "\n")
    end
end

@noinline function _log_error(msg::String)
    if _STDERR_COLOR
        print(Core.stderr, _RD, _B, "[Error]", _R, " [Mongoose] ", msg, "\n")
    else
        print(Core.stderr, "[Error] [Mongoose] ", msg, "\n")
    end
end

"""
    _log_error(msg, e, bt=nothing)

Log an error with exception details and optional backtrace.
`bt` must be captured via `catch_backtrace()` inside the `catch` block.
Both `showerror` and `Base.show_backtrace` are wrapped in `try/catch` so the
output degrades gracefully to the exception type name in trimmed binaries.
"""
@noinline function _log_error(msg::String, e::Exception, bt=nothing)
    estr = try
        sprint(showerror, e)
    catch
        string(nameof(typeof(e)))
    end

    btstr = if bt !== nothing
        try
            buf = IOBuffer()
            Base.show_backtrace(buf, bt)
            String(take!(buf))
        catch
            ""
        end
    else
        ""
    end

    if _STDERR_COLOR
        print(Core.stderr, _RD, _B, "[Error]", _R, " [Mongoose] ", msg, "\n",
              "       ", _B, estr, _R, "\n")
        isempty(btstr) || print(Core.stderr, _D, btstr, _R, "\n")
    else
        print(Core.stderr, "[Error] [Mongoose] ", msg, "\n",
              "       ", estr, "\n")
        isempty(btstr) || print(Core.stderr, btstr, "\n")
    end
end
