# foutrw - fout (VPN Gate) + xapp (WSS入口)
# Railway 部署: 需要 --device=/dev/net/tun --cap-add=NET_ADMIN

# === 阶段1: 构建 ===
FROM golang:1.23-bookworm AS builder
WORKDIR /src

# 构建 xapp
COPY go.mod go.sum ./
COPY xapp.go process_linux.go process_other.go embed.go dlxapp.html ./
RUN go mod download && CGO_ENABLED=0 go build \
    -trimpath -ldflags "-w -s" -o /out/xapp .

# 构建 fout
COPY fanout/ ./fanout/
RUN cd fanout && CGO_ENABLED=0 go build \
    -trimpath -ldflags "-w -s" -o /out/fout .

# === 阶段2: 运行时 ===
FROM debian:bookworm-slim

# openvpn post-install 需要这个目录
RUN mkdir -p /run/sendsigs.omit.d

RUN apt-get update && apt-get install -y --no-install-recommends \
    openvpn iproute2 iptables curl ca-certificates tzdata procps \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /out/fout /usr/local/bin/fout
COPY --from=builder /out/xapp /usr/local/bin/xapp
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/fout /usr/local/bin/xapp /usr/local/bin/entrypoint.sh

EXPOSE 10000 8080
ENV TZ=Asia/Shanghai
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
