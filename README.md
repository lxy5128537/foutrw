# foutrw

fout (fanout-slim VPN tunnel) + xapp (WSS proxy) combined for Railway deployment.

## Architecture

```
Internet → xapp (WSS :8080) → fout (SOCKS5 :10000) → VPN Gate nodes
```

## Components

- **fout** — VPN Gate dual-tunnel auto-failover SOCKS5 proxy (openvpn + netns isolation)
- **xapp** — WebSocket tunnel with ECH/TLS support

## Quick Start

```bash
docker build -t foutrw .
docker run -e COUNTRY=JP -p 8080:8080 foutrw
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `COUNTRY` | (none) | VPN node country code (JP/KR/US) |
| `SOCKS_PORT` | `10000` | fout SOCKS5 listen port |
| `XAPP_PORT` | `8080` | xapp WSS listen port |
| `LOG` | (none) | Set `1` for verbose logging |
