FROM docker.m.daocloud.io/openresty/openresty:alpine

# 注意：openresty 镜像的主配置在 /usr/local/openresty/nginx/conf/nginx.conf，
# 该主配置内部会 `include /etc/nginx/conf.d/*.conf;`（位于 http 块内）。
# 因此我们只需提供 conf.d/default.conf（http 级指令+server 都在这里）。
COPY default.conf /etc/nginx/conf.d/default.conf

EXPOSE 3000
CMD ["/usr/local/openresty/bin/openresty", "-g", "daemon off;"]
