function mg_serve!(args...; kwargs...)
    @warn "mg_serve! is deprecated. Use serve instead."
end

function mg_shutdown!(args...; kwargs...)
    @warn "mg_shutdown! is deprecated. Use shutdown instead."
end

function mg_register!(args...; kwargs...)
    @warn "mg_register! is deprecated. Use register instead."
end

function mg_http_reply(args...; kwargs...)
    @warn "mg_http_reply is deprecated"
end

function mg_json_reply(args...; kwargs...)
    @warn "mg_json_reply is deprecated"
end

function mg_text_reply(args...; kwargs...)
    @warn "mg_text_reply is deprecated"
end

function mg_method(args...; kwargs...)
    @warn "mg_method is deprecated. Use message.method instead."
end

function mg_uri(args...; kwargs...)
    @warn "mg_uri is deprecated. Use message.uri instead."
    return message.uri
end

function mg_query(args...; kwargs...)
    @warn "mg_query is deprecated. Use message.query instead."
end

function mg_proto(args...; kwargs...)
    @warn "mg_proto is deprecated. Use message.proto instead."
end

function mg_body(args...; kwargs...)
    @warn "mg_body is deprecated. Use message.body instead."
end

function mg_message(args...; kwargs...)
    @warn "mg_message is deprecated. Use message.message instead."
end

function mg_headers(args...; kwargs...)
    @warn "mg_headers is deprecated. Use message.headers instead."
end
