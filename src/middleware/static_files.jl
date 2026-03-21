"""
    Static file serving middleware.
"""

const DEFAULT_MIME_TYPES = Dict{String,String}(
    ".html" => "text/html; charset=utf-8",
    ".htm"  => "text/html; charset=utf-8",
    ".css"  => "text/css; charset=utf-8",
    ".js"   => "application/javascript; charset=utf-8",
    ".mjs"  => "application/javascript; charset=utf-8",
    ".json" => "application/json; charset=utf-8",
    ".xml"  => "application/xml; charset=utf-8",
    ".svg"  => "image/svg+xml; charset=utf-8",
    ".txt"  => "text/plain; charset=utf-8",
    ".md"   => "text/markdown; charset=utf-8",
    ".wasm" => "application/wasm",
    ".png"  => "image/png",
    ".jpg"  => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".gif"  => "image/gif",
    ".ico"  => "image/x-icon",
    ".webp" => "image/webp",
    ".woff" => "font/woff",
    ".woff2"=> "font/woff2",
    ".ttf"  => "font/ttf",
    ".pdf"  => "application/pdf",
)

"""
    StaticFiles <: Middleware

Middleware that serves static files from a directory.
Created via the [`static_files`](@ref) factory function.
"""
struct StaticFiles <: Middleware
    url_prefix::String
    directory::String
    index_file::String
end

function (mw::StaticFiles)(request::AbstractRequest, params::Vector{Any}, next)
    uri = String(request.uri)
    startswith(uri, mw.url_prefix) || return next()

    # Extract relative path after prefix
    rel = uri[ncodeunits(mw.url_prefix)+1:end]

    # Strip query string
    qidx = findfirst('?', rel)
    qidx !== nothing && (rel = rel[1:prevind(rel, qidx)])

    # Strip leading slashes
    while startswith(rel, "/")
        rel = rel[nextind(rel, 1):end]
    end

    # Default to index file for empty path
    isempty(rel) && (rel = mw.index_file)

    # Resolve and guard against path traversal
    filepath = normpath(joinpath(mw.directory, rel))
    startswith(filepath, mw.directory) || return Response(403, ContentType.text, "403 Forbidden")

    isfile(filepath) || return next()

    mime = _mime_type(filepath)
    content = read(filepath, String)
    return Response(200, "Content-Type: $mime\r\n", content)
end

function _mime_type(filepath::String)
    idx = findlast('.', filepath)
    idx === nothing && return "application/octet-stream"
    ext = lowercase(filepath[idx:end])
    return get(DEFAULT_MIME_TYPES, ext, "application/octet-stream")
end

"""
    static_files(directory; prefix="/static", index="index.html") → StaticFiles

Create a middleware that serves files from `directory` under the given URL `prefix`.

# Example
```julia
use!(server, static_files("public"; prefix="/static"))
# GET /static/style.css  →  serves public/style.css
# GET /static/           →  serves public/index.html
```
"""
function static_files(directory::String; prefix::String="/static", index::String="index.html")
    dir = rstrip(abspath(directory), '/')
    isdir(dir) || throw(ArgumentError("static_files: directory does not exist: $dir"))
    # Ensure directory path ends with / for secure startswith check
    dir = dir * "/"
    # Normalize prefix: must start with /, must not end with /
    p = startswith(prefix, "/") ? prefix : "/" * prefix
    endswith(p, "/") && length(p) > 1 && (p = p[1:end-1])
    return StaticFiles(p, dir, index)
end
