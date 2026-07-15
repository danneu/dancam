# Event wire reference

`contract/events/README.md` and the JSON files beside it are the canonical event wire
contract. This chapter is a non-owning projection for the book. The rationale for
snapshot-first SSE and heartbeat liveness lives in the
[transport boundary](../design/boundary/transport.md); clip identity and removal
semantics are owned by [Pi storage](../design/pi/storage.md), recorder lifecycle
events by [Pi recording](../design/pi/recording.md), and client event folding by
[app architecture](../design/app/architecture.md).

{{#include ../../contract/events/README.md}}
