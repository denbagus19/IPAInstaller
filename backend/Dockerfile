FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1

# ── System deps ────────────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y \
    python3 python3-pip curl wget git pkg-config \
    libssl-dev cmake build-essential \
    && rm -rf /var/lib/apt/lists/*

# ── Install zsign (fast IPA signer) ──────────────────────────────────────────
RUN git clone --depth=1 https://github.com/zhlynn/zsign.git /tmp/zsign \
    && cd /tmp/zsign/build/linux \
    && make clean && make \
    && cp /tmp/zsign/bin/zsign /usr/local/bin/zsign \
    && chmod +x /usr/local/bin/zsign \
    && rm -rf /tmp/zsign

# ── Python dependencies ────────────────────────────────────────────────────────
WORKDIR /app
COPY backend/requirements.txt .
RUN pip3 install --no-cache-dir -r requirements.txt

# ── Copy app code ──────────────────────────────────────────────────────────────
COPY backend/ .

EXPOSE 8000

CMD ["sh", "-c", "uvicorn main:app --host 0.0.0.0 --port ${PORT:-8000}"]
