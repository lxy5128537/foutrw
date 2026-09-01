# =============================================================
# foutrw - 多阶段构建 (fout + xapp)
# 阶段1: Go 编译 (xapp + fout 分别编译)
# 阶段2: Debian 运行时 (含 openvpn, iproute2, iptables)
# =============================================================

# ---------- 阶段 1: 构建 ----------
FROM golang:1.23-bookworm AS builder
WORKDIR /src

# --- 构建 xapp ---
COPY go.mod go.sum ./
RUN go mod download
COPY xapp.go process_linux.go process_other.go embed.go dlxapp.html ./
RUN CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH} \
    go build -trimpath -ldflags "-w -s" -o /out/xapp .

# --- 构建 fout ---
COPY fanout/ /src/fanout/
RUN cd /src/fanout && \
    CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH} \
    go build -trimpath -ldflags "-w -s" -o /out/fout .

# ---------- 阶段 2: 运行时 ----------
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    openvpn \
    iproute2 \
    iptables \
    curl \
    ca-certificates \
    tzdata \
    procps \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /out/fout /usr/local/bin/fout
COPY --from=builder /out/xapp /usr/local/bin/xapp
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/fout /usr/local/bin/xapp /usr/local/bin/entrypoint.sh

# fout SOCKS5 + xapp WSS
EXPOSE 10000 8080

ENV TZ=Asia/Shanghai

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
