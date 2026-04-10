"""
    Trim-safe logging primitives for Mongoose.jl.

    `@info` / `@warn` / `@error` route through `Base.CoreLogging`
    (abstract dispatch on `global_logger()`), which may be silently
    dropped or crash in `juliac --trim=safe` compiled binaries.

    These functions write directly to `Core.stdout` / `Core.stderr` —
    concrete boot-time `IOStream` values that survive aggressive code
    trimming and have no platform-specific ABI naming differences
    (unlike `ccall(:write, ...)` vs `ccall(:_write, ...)` on Windows).

    Color support is detected once at module load via `isatty` and cached
    as a constant, so there is zero overhead on the hot logging path.

    The exception-printing path accepts an explicit backtrace captured with
    `catch_backtrace()` at the call site (inside the catch block), and wraps
    both `showerror` and `Base.show_backtrace` in try/catch so the output
    degrades gracefully to the exception type name if specialisations are
    stripped in a trimmed binary.
"""

# Detect color support once at module-load time (trim-safe: plain ccall).
# isatty(1) = stdout, isatty(2) = stderr.
# Windows CRT exports _isatty; POSIX systems export isatty.
@static if Sys.iswindows()
    const _STDOUT_COLOR = ccall(:_isatty, Cint, (Cint,), Cint(1)) != 0
    const _STDERR_COLOR = ccall(:_isatty, Cint, (Cint,), Cint(2)) != 0
else
    const _STDOUT_COLOR = ccall(:isatty, Cint, (Cint,), Cint(1)) != 0
    const _STDERR_COLOR = ccall(:isatty, Cint, (Cint,), Cint(2)) != 0
end

# ANSI escape codes
const _R  = "\e[0m"       # reset
const _B  = "\e[1m"       # bold
const _D  = "\e[2m"       # dim
const _CY = "\e[36m"      # cyan  — info
const _YL = "\e[33m"      # yellow — warn
const _RD = "\e[31m"      # red   — error

# Raw pre-formatted output to stdout — used by the styled (ANSI) log paths.
@noinline _print(s::String) = print(Core.stdout, s)

# ---------------------------------------------------------------------------
# Plain-text structured log lines
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# Error with exception + backtrace
# Call as: _log_error("msg", e, catch_backtrace())  inside a catch block.
# The backtrace must be captured at the call site — catch_backtrace() is only
# valid in the dynamic scope of the catch block.
# ---------------------------------------------------------------------------

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
