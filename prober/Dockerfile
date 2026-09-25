FROM alpine:3.20
RUN apk add --no-cache curl bash jq ca-certificates
WORKDIR /app
COPY probe.sh /app/probe.sh
RUN chmod +x /app/probe.sh
# prober 自身不监听端口：healthcheck 只查主进程活着
HEALTHCHECK --interval=60s --timeout=10s --start-period=10s --retries=3 \
    CMD pgrep -f probe.sh >/dev/null 2>&1 || exit 1
CMD ["/app/probe.sh"]
