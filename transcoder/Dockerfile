FROM alpine:latest

# Install ffmpeg for transcoding, coreutils for flock, dcron for scheduling,
# and python3 for robust JSONL parsing in the queue processor.
RUN apk add --no-cache \
        ffmpeg \
        coreutils \
        dcron \
        bash \
        python3 \
        ca-certificates

COPY scripts/post-recording.sh    /usr/local/bin/post-recording.sh
COPY scripts/nightly-transcode.sh /etc/transcoder/nightly-transcode.sh
COPY scripts/entrypoint.sh        /usr/local/bin/entrypoint.sh
COPY scripts/generate-nfo.py      /etc/transcoder/generate-nfo.py

RUN chmod +x /usr/local/bin/post-recording.sh \
             /etc/transcoder/nightly-transcode.sh \
             /usr/local/bin/entrypoint.sh \
             /etc/transcoder/generate-nfo.py

VOLUME ["/recordings", "/media/transcoded", "/transcoder/queue"]

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
