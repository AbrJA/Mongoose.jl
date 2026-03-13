const MG_EV_POLL = Cint(2)          # For polling
const MG_EV_CLOSE = Cint(9)         # For closing connections
const MG_EV_HTTP_MSG = Cint(11)     # For full requests
const MG_EV_WS_OPEN = Cint(12)      # WebSocket connection opened
const MG_EV_WS_MSG = Cint(13)       # WebSocket message received
const MG_EV_WS_CTL = Cint(14)       # WebSocket control frame

const MG_MAX_HTTP_HEADERS = 30      # Maximum number of HTTP headers allowed
const MG_MGR_SIZE = 256             # Upper bound for mg_mgr struct size in bytes
