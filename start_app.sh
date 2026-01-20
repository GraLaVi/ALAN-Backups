#!/bin/bash

if [ "$#" -lt 1 ]; then
  echo "Usage: $0 <action>"
  echo ""
  echo "actions:"
  echo "--build - Build image and start container"
  echo "--up    - Start container from image"
  echo "--down  - Stop and delete container"
  echo "--stop  - Stop container"
  echo "--logs  - View backup service logs"
  exit 1
fi

export HOST_HOSTNAME=$(hostname)

if [ "$1" = "--build" ]; then
    docker compose -f docker-compose.yml -f docker-compose.prod.yml up --build -d
elif [ "$1" = "--up" ]; then
    docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d
elif [ "$1" = "--down" ]; then
    docker compose -f docker-compose.yml -f docker-compose.prod.yml down -v
elif [ "$1" = "--stop" ]; then
    docker compose -f docker-compose.yml -f docker-compose.prod.yml down
elif [ "$1" = "--logs" ]; then
    docker compose -f docker-compose.yml -f docker-compose.prod.yml logs backup
fi
