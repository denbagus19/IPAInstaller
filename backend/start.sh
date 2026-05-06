#!/bin/bash
set -e

echo "==> Starting anisette-v3 server on port 6969..."
/usr/local/bin/anisette-v3-server &

echo "==> Waiting for anisette server to be ready..."
sleep 3

echo "==> Starting FastAPI signing server on port 8000..."
exec uvicorn main:app --host 0.0.0.0 --port 8000
