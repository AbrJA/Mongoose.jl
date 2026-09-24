"""
    FFI constants for the Mongoose C library.
    Event types, struct sizes, and protocol constants.
"""

# Event types from mongoose.h
const MG_EV_OPEN = Cint(1)          # Connection created (partially initialized)
const MG_EV_POLL = Cint(2)          # Periodic poll event (most frequent)
const MG_EV_ACCEPT = Cint(5)        # Incoming connection accepted
const MG_EV_READ = Cint(7)          # Data received from socket
const MG_EV_CLOSE = Cint(9)         # Connection closed
const MG_EV_HTTP_HDRS = Cint(10)    # HTTP headers complete (body may follow)
const MG_EV_HTTP_MSG = Cint(11)     # Full HTTP message received
const MG_EV_WS_OPEN = Cint(12)     # WebSocket connection opened
const MG_EV_WS_MSG = Cint(13)      # WebSocket message received
const MG_EV_WS_CTL = Cint(14)      # WebSocket control frame

# Mongoose Log Levels
const MG_LL_NONE = Cint(0)
const MG_LL_ERROR = Cint(1)
const MG_LL_INFO = Cint(2)
const MG_LL_DEBUG = Cint(3)
const MG_LL_VERBOSE = Cint(4)

const MG_MAX_HTTP_HEADERS = 30      # Maximum number of HTTP headers (from mongoose.h)

# Upper bound for mg_mgr struct size in bytes.
# Validated against Mongoose C v7.21.0 (actual: 128 bytes).
# If you upgrade Mongoose_jll, verify this is still sufficient.
const MG_MGR_SIZE = 256

# WebSocket opcodes (RFC 6455)
const WS_OP_TEXT = Cint(1)
const WS_OP_BINARY = Cint(2)
const WS_OP_CLOSE = Cint(8)
const WS_OP_PING = Cint(9)
const WS_OP_PONG = Cint(10)

# RFC 6455 §7.4.1 close codes used by the framework for protocol violations.
const WS_CLOSE_PROTOCOL_ERROR = 1002
const WS_CLOSE_INVALID_PAYLOAD = 1007
const WS_CLOSE_MESSAGE_TOO_BIG = 1009

# Default limits
const MAX_BODY_BYTES = 1_048_576  # 1 MB default max body size
const DEFAULT_MAX_HEADER_BYTES = 64 * 1024  # 64 KiB default request-header cap
const DEFAULT_SEND_BUFFER_BYTES = 1_048_576  # 1 MiB unsent data per connection (streams + WS)
const DRAIN_TIMEOUT_MS = 5000    # 5s shutdown drain timeout

# Empirically verified ceiling of the C receive buffer on the current
# Mongoose_jll build: an 8 MiB body round-trips, a 10 MiB body resets the
# connection. Configured limits above this are unenforceable (the socket dies
# before the application-level 413 can be produced).
const C_RECV_CEILING_BYTES = 8 * 1024 * 1024
