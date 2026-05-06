#!/bin/bash
set -e

PORT="${PORT:-8000}"

echo "==> Starting anisette-v3 server on port 6969..."
/usr/local/bin/anisette-v3-server &

echo "==> Waiting for anisette server to be ready..."
sleep 3

echo "==> Starting FastAPI signing server on port $PORT..."
exec uvicorn main:app --host 0.0.0.0 --port "$PORT"
