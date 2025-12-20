FROM alpine:3.19

# Install all required packages during build time
RUN apk add --no-cache \
    bash \
    curl \
    docker-cli \
    jq \
    tzdata \
    dcron

# Default entrypoint will be overridden in docker-compose.yml
# This ensures packages are available at runtime

