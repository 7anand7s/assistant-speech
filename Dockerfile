FROM python:3.11-slim

# ffmpeg: mp3 encoding (engines.py) and the long-lived streaming encoder (streaming.py).
# espeak-ng is NOT needed from apt - the espeakng_loader wheel bundles it.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY *.py ./

# models/ and flagged_log.jsonl are bind-mounted at runtime (see docker-compose.yml)
EXPOSE 8880
CMD ["python", "app.py"]
