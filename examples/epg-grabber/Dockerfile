FROM node:lts-alpine

# Install tools required by the grabber and the init scripts.
RUN apk add --no-cache socat git bash curl grep coreutils tzdata

WORKDIR /app

# Clone the iptv-org/epg repository at build time.
# The entrypoint runs git pull at runtime, so this is only a starting state.
RUN git clone --depth 1 https://github.com/iptv-org/epg.git /tmp/epg \
    && mv /tmp/epg/* /tmp/epg/.git /app/ \
    && rm -rf /tmp/epg

RUN npm install

COPY ./epg-grabber/entrypoint.sh /entrypoint.sh
COPY ./epg-grabber/generate-channels.sh /app/generate-channels.sh
RUN chmod +x /entrypoint.sh /app/generate-channels.sh

ENTRYPOINT ["/entrypoint.sh"]
