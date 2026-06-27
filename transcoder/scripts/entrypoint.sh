#!/bin/sh
# Container entrypoint for the PVR transcoder/comskip images.
# Role is selected via the CONTAINER_ROLE environment variable.
#
# - comskip:   starts the comskip worker pool in the foreground.
# - transcode: installs a crontab for transcode-pool.sh and keeps alive.

ROLE="${CONTAINER_ROLE:-transcode}"
CRON_EXPR="${TRANSCODE_CRON:-0 2 * * *}"
CRON_USER="${TRANSCODE_USER:-root}"

mkdir -p /var/log /media/transcoded /transcoder/queue

echo "[entrypoint] role=$ROLE"

case "$ROLE" in
  comskip)
    exec /bin/sh /etc/transcoder/comskip-pool.sh
    ;;

  transcode)
    mkdir -p /etc/cron.d
    printf '%s %s /bin/sh /etc/transcoder/transcode-pool.sh\n' "$CRON_EXPR" "$CRON_USER" > /etc/cron.d/transcoder
    chmod 0644 /etc/cron.d/transcoder

    printf 'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\nSHELL=/bin/sh\nMAILTO=""\n'

    echo "[entrypoint] crontab:"
    cat /etc/cron.d/transcoder

    touch /var/log/cron.log /var/log/transcode-nightly.log

    service cron start >/dev/null 2>&1 || cron >/dev/null 2>&1

    exec tail -f /var/log/cron.log /var/log/transcode-nightly.log
    ;;

  *)
    echo "[entrypoint] unknown role '$ROLE'; expected 'comskip' or 'transcode'" >&2
    exit 1
    ;;
esac
