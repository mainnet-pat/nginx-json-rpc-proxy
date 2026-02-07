FROM openresty/openresty:alpine

# Install envsubst (part of gettext)
RUN apk add --no-cache gettext

# Copy Lua module
COPY lua/ /etc/nginx/lua/

# Copy nginx config template
COPY nginx.conf.template /etc/nginx/nginx.conf.template

# Copy entrypoint
COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

EXPOSE 8000

ENTRYPOINT ["/docker-entrypoint.sh"]
