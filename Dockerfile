FROM alpine:3.21

# Install all required packages during build time
# Use postgresql17-client to match PostgreSQL 17 server version
RUN apk add --no-cache \
    bash \
    curl \
    docker-cli \
    jq \
    tzdata \
    dcron \
    postgresql17-client

# Create docker group with GID 988 (matching host docker group)
# This allows access to /var/run/docker.sock when mounted
RUN addgroup -g 988 docker

# Create user david:david with UID/GID 1000, and add to docker group
RUN addgroup -g 1000 david && \
    adduser -u 1000 -G david -s /bin/bash -D david && \
    adduser david docker

# Create crontab directory structure for user crontabs
# dcron uses /var/spool/cron/crontabs/USERNAME for user crontabs
RUN mkdir -p /var/spool/cron/crontabs && \
    chmod 755 /var/spool/cron/crontabs && \
    mkdir -p /home/david/logs && \
    chown -R david:david /home/david

# Default entrypoint will be overridden in docker-compose.yml
# This ensures packages are available at runtime

