@testset "FakeTransport" begin
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

    client = Mongoose.FakeTransport(app)

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

@testset "HTTPError via FakeTransport" begin
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

    client = Mongoose.FakeTransport(app)

    @testset "errorstatus / showerror on the types" begin
        e = NotFoundError("user 7 missing")
        @test Mongoose.errorstatus(e) == 404
        @test e isa Mongoose.HTTPError
        @test occursin("Not Found (404): user 7 missing", sprint(showerror, e))
        @test BadRequestError === HTTPError{400}
        @test BadGatewayError === HTTPError{502}
        @test ServiceUnavailableError === HTTPError{503}
        @test GatewayTimeoutError === HTTPError{504}
        @test Mongoose.errorstatus(ServiceUnavailableError("down")) == 503
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
        c = Mongoose.FakeTransport(ae)
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

@testset "FakeTransport header input forms" begin
    app = App()
    get!(app, "/h") do req; text(get(req.headers, "x-a", "none")) end
    post!(app, "/j") do req; text(get(req.headers, "content-type", "none")) end
    client = Mongoose.FakeTransport(app)

    @test String(client(:get, "/h"; headers=Headers(["x-a" => "1"])).body) == "1"
    @test String(client(:get, "/h"; headers=("x-a" => "1",)).body) == "1"
    @test String(client(:get, "/h"; headers=["x-a" => "1"]).body) == "1"
    @test String(client(:get, "/h").body) == "none"

    # The JSON convenience still injects Content-Type alongside extra headers.
    resp = client(:post, "/j", Dict("a" => 1); headers=("x-a" => "1",))
    @test occursin("application/json", String(resp.body))
end


@testset "HTTPError alias coverage" begin
    aliases = (
        (BadRequestError, 400), (UnauthorizedError, 401), (PaymentRequiredError, 402),
        (ForbiddenError, 403), (NotFoundError, 404), (MethodNotAllowedError, 405),
        (NotAcceptableError, 406), (ProxyAuthenticationRequiredError, 407),
        (RequestTimeoutError, 408), (ConflictError, 409), (GoneError, 410),
        (LengthRequiredError, 411), (PreconditionFailedError, 412),
        (PayloadTooLargeError, 413), (URITooLongError, 414),
        (UnsupportedMediaTypeError, 415), (RangeNotSatisfiableError, 416),
        (ExpectationFailedError, 417), (ImATeapotError, 418),
        (MisdirectedRequestError, 421), (UnprocessableEntityError, 422),
        (LockedError, 423), (FailedDependencyError, 424), (TooEarlyError, 425),
        (UpgradeRequiredError, 426), (PreconditionRequiredError, 428),
        (TooManyRequestsError, 429), (RequestHeaderFieldsTooLargeError, 431),
        (UnavailableForLegalReasonsError, 451), (InternalServerError, 500),
        (BadGatewayError, 502), (ServiceUnavailableError, 503),
        (GatewayTimeoutError, 504), (HTTPVersionNotSupportedError, 505),
        (VariantAlsoNegotiatesError, 506), (InsufficientStorageError, 507),
        (LoopDetectedError, 508), (NotExtendedError, 510),
        (NetworkAuthenticationRequiredError, 511),
    )
    for (T, code) in aliases
        @test errorstatus(T("m")) == code
        @test !isempty(Mongoose.statusreason(code))
        @test occursin(string(code), sprint(showerror, T("m")))
    end
    # 501 deliberately has no alias (Base owns NotImplementedError); the
    # parametric form still works and carries a reason phrase.
    @test :NotImplementedError ∉ names(Mongoose)
    @test errorstatus(HTTPError{501}("m")) == 501
    @test Mongoose.statusreason(501) == "Not Implemented"
end
