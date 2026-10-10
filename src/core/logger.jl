"""
    Request logging middleware.
    Logs method, URI, status, and response time for each request.
    Supports plain text and structured (JSON) output formats.
"""

"""
    _escape(s) → String

Escape a string for safe embedding in a JSON value (handles \\, ", control chars).
"""
function _escape(s::AbstractString)
    needs_escape = false
    for c in s
        if c == '"' || c == '\\' || c < ' '
            needs_escape = true
            break
        end
    end
    needs_escape || return String(s)

    io = IOBuffer()
    for c in s
        if c == '"'
            write(io, "\\\"")
        elseif c == '\\'
            write(io, "\\\\")
        elseif c == '\n'
            write(io, "\\n")
        elseif c == '\r'
            write(io, "\\r")
        elseif c == '\t'
            write(io, "\\t")
        elseif c < ' '
            write(io, "\\u")
            write(io, string(UInt16(c); base=16, pad=4))
        else
            write(io, c)
        end
    end
    return String(take!(io))
end

"""
    Logger — Request logging middleware.
    Logs each request's method, URI, status code, and elapsed time.
"""
struct Logger{O} <: AbstractMiddleware
    threshold_ns::Int
    output::O
    structured::Bool
end

function (mw::Logger)(request::Request, next::Function)
    t0 = time_ns()
    response = try
        next()
    catch
        # Throwing handlers still get one access-log line (single write, no interleave).
        elapsed_ns = time_ns() - t0
        elapsed_ns >= mw.threshold_ns &&
            _log_request(mw, request, 500, elapsed_ns / 1_000_000, "")
        rethrow()
    end
    elapsed_ns = time_ns() - t0

    if elapsed_ns >= mw.threshold_ns
        elapsed_ms = elapsed_ns / 1_000_000
        status = response isa Response ? response.status : 0
        rid = response isa Response ? get(response.headers, "x-request-id", "") : ""
        _log_request(mw, request, status, elapsed_ms, rid)
    end

    return response
end

# Replace control bytes so a hostile request target cannot forge extra log
# lines or inject terminal escapes (structured mode escapes via `_escape`).
function _printable(s::AbstractString)::String
    needs = false
    for b in codeunits(s)
        (b < 0x20 || b == 0x7f) && (needs = true; break)
    end
    needs || return String(s)
    io = IOBuffer(sizehint=ncodeunits(s))
    for b in codeunits(s)
        write(io, (b < 0x20 || b == 0x7f) ? UInt8('?') : b)
    end
    return String(take!(io))
end

# Trim-safe UTC ISO timestamp (`Libc.strftime` pulls in non-trim-safe printing).
function _iso_utc(t::Float64)::String
    secs = floor(Int64, t)
    days = fld(secs, 86400)
    rem = secs - days * 86400
    hh = rem ÷ 3600
    mm = (rem % 3600) ÷ 60
    ss = rem % 60
    z = days + 719468
    era = fld(z >= 0 ? z : z - 146096, 146097)
    doe = z - era * 146097
    yoe = (doe - doe ÷ 1460 + doe ÷ 36524 - doe ÷ 146096) ÷ 365
    y = yoe + era * 400
    doy = doe - (365 * yoe + yoe ÷ 4 - yoe ÷ 100)
    mp = (5 * doy + 2) ÷ 153
    d = doy - (153 * mp + 2) ÷ 5 + 1
    m = mp < 10 ? mp + 3 : mp - 9
    y += m <= 2
    io = IOBuffer(sizehint = 19)
    _write_digits(io, y, 4);  write(io, '-')
    _write_digits(io, m, 2);  write(io, '-')
    _write_digits(io, d, 2);  write(io, 'T')
    _write_digits(io, hh, 2); write(io, ':')
    _write_digits(io, mm, 2); write(io, ':')
    _write_digits(io, ss, 2)
    return String(take!(io))
end

# Zero-padded decimal digits without `lpad` (`Base.repeat` is not trim-safe).
@inline function _write_digits(io::IO, x::Int, width::Int)
    for shift in (width - 1):-1:0
        write(io, UInt8('0') + UInt8((x ÷ 10^shift) % 10))
    end
    return nothing
end

function _log_request(mw::Logger, request::Request, status::Int,
                      elapsed_ms::Float64, rid::String)
    io = IOBuffer(sizehint=160)
    if mw.structured
        # JSON structured log line (no dependency — manual formatting)
        method = uppercase(String(request.method))
        print(io,
            "{\"method\":\"", method,
            "\",\"uri\":\"", _escape(request.uri),
            "\",\"status\":", status,
            ",\"duration\":", round(elapsed_ms; digits=2),
            ",\"request_id\":\"", _escape(rid),
            "\",\"ts\":\"", _iso_utc(time()),
            "\"}\n")
    else
        print(io, uppercase(String(request.method)), " ", _printable(request.uri),
              " → ", status, " (", round(elapsed_ms; digits=2), "ms)")
        isempty(rid) || print(io, " id=", rid)
        print(io, '\n')
    end
    write(mw.output, take!(io))
    return nothing
end

"""
    logger(; threshold_ms=0, output=stderr, structured=false)

Create a request-logging middleware.

# Keyword Arguments
- `threshold_ms::Int`: Only log requests slower than this (default: `0` = log
  all) in milliseconds.
- `output::IO`: IO stream for log output (default: `stderr`).
- `structured::Bool`: If `true`, emit one JSON object per line (default: `false`).

# Example
```julia
server = use(server, logger())                         # plain text, all requests
server = use(server, logger(threshold_ms=100))         # only slow requests
server = use(server, logger(structured=true))          # JSON structured logs
```
"""
logger(; threshold_ms::Int=0, output::IO=stderr, structured::Bool=false) =
    Logger(threshold_ms * 1_000_000, output, structured)

Base.show(io::IO, mw::Logger) =
    print(io, "Logger(threshold_ms=", mw.threshold_ns ÷ 1_000_000, mw.structured ? ", structured" : "", ")")
