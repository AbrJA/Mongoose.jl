"""
    Logging for Mongoose.jl — trim=safe compatible.

    All log calls use `print(Core.stdout/stderr, …)` with concrete String
    dispatch, fully compatible with `juliac --trim=safe` AOT compilation.

    Source location (file and line number) is captured at compile time by the
    `@log_info`, `@log_warn`, and `@log_error` macros and embedded as string
    literals in the generated code — zero runtime cost, no abstract dispatch.

    Usage:
        @log_info  "Server ready"
        @log_warn  "Queue full"
        @log_error "Handler failed"
        @log_error "Handler failed" exception
        @log_error "Handler failed" exception catch_backtrace()
"""

# ── Underlying @noinline implementations ──────────────────────────────────────

@noinline function _log_info_impl(file::String, line::Int, msg::String)
    print(Core.stdout, "[Info] [Mongoose] " * file * ":" * string(line) * " — " * msg * "\n")
end

@noinline function _log_warn_impl(file::String, line::Int, msg::String)
    print(Core.stderr, "[Warn] [Mongoose] " * file * ":" * string(line) * " — " * msg * "\n")
end

# Errors don't include a call-site — the catch block location is not useful.
# The component= field in the message and the exception type identify the issue.
@noinline function _log_error_impl(msg::String)
    print(Core.stderr, "[Error] [Mongoose] " * msg * "\n")
end

@noinline function _log_error_impl(msg::String, @nospecialize(e))
    estr = try
        String(nameof(typeof(e)))
    catch
        "unknown error"
    end
    print(Core.stderr, "[Error] [Mongoose] " * msg * "\n        exception=" * estr * "\n")
end

# ── Macros ──────────────────────────────────────────────────────────────
#
macro log_info(msg)
    file = basename(string(__source__.file))
    line = __source__.line
    :(_log_info_impl($file, $line, $(esc(msg))))
end

macro log_warn(msg)
    file = basename(string(__source__.file))
    line = __source__.line
    :(_log_warn_impl($file, $line, $(esc(msg))))
end

macro log_error(msg)
    :(_log_error_impl($(esc(msg))))
end

macro log_error(msg, e)
    :(_log_error_impl($(esc(msg)), $(esc(e))))
end

macro log_error(msg, e, bt)
    :(_log_error_impl($(esc(msg)), $(esc(e))))
end

# ── Lifecycle helpers ──────────────────────────────────────────────────────────

function _logstart(server::AbstractServer, url::String)
    s_routes  = string(_routecount(server.core.router))
    s_mw      = string(length(server.core.middlewares))
    s_mounts  = string(length(server.core.mounts))
    s_workers = string(server isa Async ? server.nworkers : 0)
    s_threads = string(Threads.nthreads())
    io = Core.stdout
    print(io, "\n")
    printstyled(io, "🚀 Mongoose started\n"; bold=true, color=:cyan)
    printstyled(io, "  URL:     "; color=:light_black)
    printstyled(io, url * "\n"; underline=true, color=:blue)
    printstyled(io, "  API:     "; color=:light_black)
    printstyled(io, s_routes * " routes • " * s_mw * " middleware • " * s_mounts * " mounts\n"; color=:green)
    printstyled(io, "  Type:    "; color=:light_black)
    print(io, String(nameof(typeof(server))) * "\n")
    printstyled(io, "  System:  "; color=:light_black)
    printstyled(io, s_workers * " workers • " * s_threads * " threads\n"; color=:green)
    print(io, "\n")
end

function _logstop(server::AbstractServer)
    printstyled(Core.stdout, "🛑 Mongoose shutting down...\n"; bold=true, color=:red)
end

function _logstopped(server::AbstractServer)
    printstyled(Core.stdout, "✅ Mongoose stopped.\n"; bold=true, color=:green)
end
