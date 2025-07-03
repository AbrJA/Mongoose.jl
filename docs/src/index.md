# Mongoose.jl

**Mongoose.jl** is a Julia package that provides a lightweight and efficient interface for building HTTP servers and web applications. It leverages the [Mongoose C library](https://github.com/cesanta/mongoose) to deliver fast, embeddable web server capabilities directly from Julia code. The package is designed for simplicity and ease of use. With `Mongoose.jl`, users can define routes, handle HTTP requests, and serve dynamic or static content with minimal setup.

## Instalation

```julia
] add https://github.com/AbrJA/Mongoose.jl.git
```

## Quick start

**Important:** The handler functions always should have two arguments `conn::MgConnection` and `request::MgHttpMessage`

```julia
using Mongoose

function test_json(conn, request)
    mg_json_reply(conn, 200, "{\"message\":\"Hi JSON!\"}")
end

function test_text(conn, request)
    mg_text_reply(conn, 200, "Hi TEXT!")
end

mg_register("GET", "/json", test_json)
mg_register("GET", "/text", test_text)

mg_serve()
mg_shutdown()
```

## Examples
More comprehensive examples demonstrating various use cases and features can be found on the Examples page.

## API
The full API documentation, including all functions and types, is available on the API page.

## Contributing
Contributions are welcome! Please see the Contributing page for guidelines.

## License
This package is distributed under the GPL-2 License.
