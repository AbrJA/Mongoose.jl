@testset "TestClient" begin
    app = App()
    get!(app, "/hello") do req
        text("Hello World")
    end
    get!(app, "/json") do req
        json((message="hi", count=42))
    end
    post!(app, "/echo") do req
        text("Got: $(req.body)")
    end
    get!(app, "/query") do req
        q = query(req, "name", "unknown")
        text("Hello $q")
    end

    client = Mongoose.TestClient(app)

    @testset "GET text response" begin
        resp = client(:get, "/hello")
        @test resp.status == 200
        @test resp.body == "Hello World"
    end

    @testset "GET JSON response" begin
        resp = client(:get, "/json")
        @test resp.status == 200
        @test contains(resp.body, "\"message\"")
        @test contains(resp.body, "\"hi\"")
    end

    @testset "POST with body" begin
        resp = client(:post, "/echo"; body="test data")
        @test resp.status == 200
        @test resp.body == "Got: test data"
    end

    @testset "Query parameters" begin
        resp = client(:get, "/query"; query=Dict("name" => "Julia"))
        @test resp.status == 200
        @test contains(resp.body, "Julia")
    end

    @testset "404 for missing route" begin
        resp = client(:get, "/nonexistent")
        @test resp.status == 404
    end

    @testset "405 for wrong method" begin
        resp = client(:post, "/hello")
        @test resp.status == 405
    end
end

@testset "HTTPError via TestClient" begin
    struct ErrUser
        name::String
        age::Int
    end

    app = App()
    get!(app, "/teapot") do req
        throw(ImATeapotError("short and stout"))
    end
    get!(app, "/gone") do req
        throw(NotFoundError("user 7 missing"))
    end
    get!(app, "/conflict") do req
        throw(ConflictError("duplicate email"))
    end
    post!(app, "/valid") do req
        validate(req, ErrUser)
    end
    post!(app, "/valid/json") do req
        json(validate(req, ErrUser))
    end

    client = Mongoose.TestClient(app)

    @testset "error_status / showerror on the types" begin
        e = NotFoundError("user 7 missing")
        @test Mongoose.error_status(e) == 404
        @test e isa Mongoose.HTTPError
        @test occursin("Not Found (404): user 7 missing", sprint(showerror, e))
        @test BadRequestError === HTTPError{400}
        @test occursin("Too Many Requests (429): slow down", sprint(showerror, TooManyRequestsError("slow down")))
    end

    @testset "automatic fallback to Response" begin
        r = client(:get, "/gone")
        @test r.status == 404
        @test r.body == "user 7 missing"
        @test get(r.headers, "content-type", "") == "text/plain"

        r = client(:get, "/conflict")
        @test r.status == 409

        r = client(:get, "/teapot")
        @test r.status == 418
        @test r.body == "short and stout"
    end

    @testset "ValidationError defaults to 422" begin
        r = client(:post, "/valid"; body="not json")
        @test r.status == 422
        r = client(:post, "/valid/json"; body=JSON.json(Dict("name" => "Alice")))
        @test r.status == 422
    end

    @testset "onerror! registration beats the automatic mapping" begin
        ae = App()
        get!(ae, "/g") do req; throw(NotFoundError("boom")) end
        onerror!(ae, NotFoundError) do req, e
            text("custom: $(e.message)"; status=404)
        end
        c = Mongoose.TestClient(ae)
        r = c(:get, "/g")
        @test r.status == 404
        @test r.body == "custom: boom"
    end
end

@testset "Stateful FakeTransport (owner checks, one response/stream, close cascade)" begin
    app = App()
    get!(app, "/events") do req
        sse(req) do w
            emit(w; data="a")
            emit(w; data="b")
        end
    end

    @testset "Streamed response is bound to one registered stream" begin
        t = FakeTransport(app)
        resp = t(:get, "/events")
        @test resp.status == 200
        @test String(resp.body) == "data: a\n\ndata: b\n\n"

        @test length(t.streams) == 1                      # owned by this transport
        st = t.streams[1]
        @test st isa Mongoose.FakeStream
        @test st.open == false && st.done == true         # delivered → closed
        @test st.error === nothing

        # A second request is a NEW stream, not a re-response on the old one.
        t(:get, "/events")
        @test length(t.streams) == 2
        @test t.stream_seq == 2
    end

    @testset "One response per stream: writes after delivery raise" begin
        t = FakeTransport(app)
        t(:get, "/events")
        st = t.streams[1]
        writer = Mongoose.FakeStreamWriter(st)
        @test !isopen(writer)
        @test_throws Mongoose.StreamClosedError write(writer, "late chunk")
        @test_throws Mongoose.StreamClosedError write(writer, UInt8[1, 2])
        @test !occursin("late chunk", String(st.io.data))
    end

    @testset "Close cascade: close! closes owned streams and rejects requests" begin
        t = FakeTransport(app)
        t(:get, "/events")
        st = t.streams[1]
        cwriter = Mongoose.FakeStreamWriter(st)  # hypothetical in-flight writer
        close!(t)
        @test t.closed == true
        @test !isopen(cwriter)
        @test_throws Mongoose.StreamClosedError write(cwriter, "after cascade")
        @test_throws Mongoose.StreamClosedError t(:get, "/events")
    end

    @testset "Producer exceptions are recorded on the stream, not rethrown" begin
        s2 = App()
        get!(s2, "/crash") do req
            sse(req) do w
                emit(w; data="before")
                error("producer blew up")
            end
        end
        t = FakeTransport(s2)
        resp = t(:get, "/crash")
        # Partial body is still delivered; the failure is recorded.
        @test occursin("data: before", String(resp.body))
        st = t.streams[1]
        @test st.error isa ErrorException
        @test st.done == true
    end
end

