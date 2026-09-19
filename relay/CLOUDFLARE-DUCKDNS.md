# DNS / TLS

## DuckDNS

For a simple VPS-only setup, use a DuckDNS hostname such as:

`yourname.duckdns.org`

Point it at the VPS using DuckDNS's update service. DuckDNS documents an HTTPS update endpoint:

`https://www.duckdns.org/update?domains=YOURNAME&token=YOURTOKEN`

See: https://www.duckdns.org/spec.jsp

The Android app can then connect to:

`wss://yourname.duckdns.org/relay`

with the relay session and token parameters.

For public TLS on a bare VPS, use an HTTPS reverse proxy or another TLS terminator in front of the Node relay.

## Cloudflare

A normal Cloudflare-proxied DNS hostname also supports WebSocket connections. Cloudflare documents
that proxied WebSockets work without additional origin changes, and recommends client/application
keepalives for long-lived connections.

See: https://developers.cloudflare.com/network/websockets/

For this project, either a DuckDNS hostname or a Cloudflare-managed hostname is suitable.
