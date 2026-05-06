FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1

# ── System deps ──────────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y \
    python3 python3-pip curl wget git \
    libssl-dev libz-dev cmake build-essential \
    && rm -rf /var/lib/apt/lists/*

# ── Install zsign ─────────────────────────────────────────────────────────────
RUN git clone --depth=1 https://github.com/zhlynn/zsign.git /tmp/zsign \
    && cd /tmp/zsign \
    && g++ -O3 -std=c++11 \
        common/base64.cpp common/json.cpp common/common.cpp common/md5.cpp \
        openssl.cpp signing.cpp main.cpp \
        -o /usr/local/bin/zsign \
        -lssl -lcrypto -lz \
    && chmod +x /usr/local/bin/zsign \
    && rm -rf /tmp/zsign

# ── Install anisette-v3 server ────────────────────────────────────────────────
RUN wget -q \
    https://github.com/Dadoum/anisette-v3-server/releases/latest/download/anisette-v3-server-x86_64-unknown-linux-gnu.zip \
    -O /tmp/anisette.zip \
    && unzip -q /tmp/anisette.zip -d /usr/local/bin/ \
    && chmod +x /usr/local/bin/anisette-v3-server \
    && rm /tmp/anisette.zip

# ── Python dependencies ───────────────────────────────────────────────────────
WORKDIR /app
COPY requirements.txt .
RUN pip3 install --no-cache-dir -r requirements.txt

# ── Copy app code ─────────────────────────────────────────────────────────────
COPY . .

# ── Startup script ────────────────────────────────────────────────────────────
COPY start.sh /start.sh
RUN chmod +x /start.sh

EXPOSE 8000

CMD ["/start.sh"]
