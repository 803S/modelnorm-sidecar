FROM alpine:3.20
RUN apk add --no-cache curl bash jq ca-certificates python3 docker-cli
WORKDIR /app
COPY probe.sh /app/probe.sh
COPY passive_health.py /app/passive_health.py
RUN chmod +x /app/probe.sh /app/passive_health.py

# prober 通过 /var/run/docker.sock 读 new-api 的日志做被动检测（只读，零请求）
# healthcheck：probe.sh 主进程或 passive 扫描任一活着即健康
HEALTHCHECK --interval=60s --timeout=10s --start-period=10s --retries=3 \
    CMD pgrep -f "probe.sh|passive_health" >/dev/null 2>&1 || exit 1
CMD ["/app/probe.sh"]
