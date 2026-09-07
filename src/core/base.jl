"""
    AbstractRequest — protocol for transport-agnostic requests.

    `Request` is the default implementation. Transport adapters construct
    their own request objects (or reuse `Request`) and the protocol layer
    never crosses into FFI types.
"""
abstract type AbstractRequest end