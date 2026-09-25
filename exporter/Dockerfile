FROM python:3.13-slim

# Without this, Python block-buffers stdout when it isn't a TTY, so log
# output doesn't reach `docker logs` promptly — confirmed during design by
# running the exporter and finding its logs weren't flushed until exit.
ENV PYTHONUNBUFFERED=1

RUN useradd -u 1000 -m exporter
WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY rcon.py exporter.py .

USER exporter

EXPOSE 8000

CMD ["python3", "exporter.py"]
