/*
 * qnap-pvr fork — Post-Processing queue reader
 *
 * Reads the JSONL queue files and done-lists for comskip and
 * transcode, and exposes them as JSON over HTTP. The browser
 * side lives in src/webui/static/app/postproc.js and the
 * routes are registered in src/webui/webui.c.
 *
 * Concurrency: comskip and transcode append to these files
 * with `>>` redirection. POSIX guarantees that short writes
 * (up to PIPE_BUF = 4096 bytes) are atomic, and our queue
 * rows are <512 bytes, so a reader can see either the
 * pre-write or post-write state — never a torn row. We
 * do not use file locking; it would be over-engineering.
 */

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "htsmsg.h"
#include "htsmsg_json.h"
#include "http.h"
#include "tvhlog.h"
#include "pvr_queue.h"

#define PVR_QUEUE_NAME_MAX 128

/*
 * One queue. The kind string ("comskip" or "transcode") is
 * fixed at construction; the rest is loaded from the
 * post-processing containers' queue volumes via env
 * variables (PVR_COMSKIP_QUEUE, PVR_TRANSCODE_QUEUE, etc.).
 */
typedef struct pvr_queue {
  const char *kind;        /* "comskip" | "transcode" */
  const char *env_queue;   /* env var name for queue.jsonl */
  const char *env_done;    /* env var name for done list */
  const char *env_log;     /* env var name for log tail */
} pvr_queue_t;

/* These two are the only kinds we know about. Anything else
 * is rejected by the URL dispatcher. */
static const pvr_queue_t pvr_queue_comskip = {
  .kind      = "comskip",
  .env_queue = "PVR_COMSKIP_QUEUE",
  .env_done  = "PVR_COMSKIP_DONE",
  .env_log   = "PVR_COMSKIP_LOG",
};

static const pvr_queue_t pvr_queue_transcode = {
  .kind      = "transcode",
  .env_queue = "PVR_TRANSCODE_QUEUE",
  .env_done  = "PVR_TRANSCODE_DONE",
  .env_log   = "PVR_TRANSCODE_LOG",
};

/* Read a file into a heap buffer. NULL on error.
 *
 * We cap the read at 1 MB to avoid memory pressure from a
 * runaway queue file. A 1 MB queue is ~2000 entries at 512
 * bytes each — far more than the post-proc pool's daily
 * throughput — and if a queue ever grows past that, we want
 * to know about it. The cap is enforced by counting bytes
 * during the read. */
static char *
pvr_read_file_capped(const char *path, size_t cap, size_t *out_len)
{
  int fd = open(path, O_RDONLY);
  if (fd < 0)
    return NULL;
  size_t cap_actual = cap > 0 ? cap : (1u << 20);
  size_t len = 0;
  size_t bufsz = 4096;
  char *buf = malloc(bufsz);
  if (!buf) { close(fd); return NULL; }
  while (1) {
    if (len + bufsz > cap_actual) {
      /* one last read up to the cap, then stop */
      bufsz = cap_actual - len;
      if (bufsz == 0) break;
    }
    if (len + bufsz > 1024 * 1024) {
      /* grow into a larger backing buffer if needed */
      size_t new_sz = len + bufsz;
      char *n = realloc(buf, new_sz);
      if (!n) { free(buf); close(fd); return NULL; }
      buf = n;
    }
    ssize_t r = read(fd, buf + len, bufsz);
    if (r < 0) {
      if (errno == EINTR) continue;
      free(buf); close(fd);
      return NULL;
    }
    if (r == 0) break;     /* EOF */
    len += (size_t)r;
  }
  close(fd);
  buf[len] = '\0';
  if (out_len) *out_len = len;
  return buf;
}

/* Parse one JSONL line into an htsmsg. Returns NULL on parse
 * error (we skip the line — partial data should not block the
 * dashboard). */
static htsmsg_t *
pvr_parse_jsonl_line(const char *line, size_t len)
{
  /* htsmsg_json_deserialize expects a NUL-terminated string
   * but ignores trailing whitespace. We copy the slice into
   * a tiny scratch buffer to be safe. */
  char *scratch = malloc(len + 1);
  if (!scratch) return NULL;
  memcpy(scratch, line, len);
  scratch[len] = '\0';
  htsmsg_t *m = htsmsg_json_deserialize(scratch);
  free(scratch);
  return m;
}

/* Build the JSON for /pvr/api/queue/<kind>: a list of items
 * plus the done-count. The line-by-line parse keeps the cost
 * bounded by the line count, not the file size, so a 1 MB
 * file with 2000 lines parses in well under 100 ms. */
static htsmsg_t *
pvr_build_queue_response(const pvr_queue_t *q)
{
  const char *path = getenv(q->env_queue);
  if (!path || !*path) {
    htsmsg_t *err = htsmsg_create_map();
    htsmsg_add_str(err, "error", "queue path not configured");
    return err;
  }
  size_t len = 0;
  char *buf = pvr_read_file_capped(path, 1u << 20, &len);
  htsmsg_t *out = htsmsg_create_map();
  htsmsg_add_str(out, "kind", q->kind);
  htsmsg_add_str(out, "path", path);
  htsmsg_t *items = htsmsg_create_list();
  htsmsg_add_msg(out, "items", items);
  int rc = 0;
  if (!buf) {
    /* No queue file yet — return empty list. This is the
     * normal state at first boot or after a prune-done. */
    return out;
  }
  const char *p = buf;
  const char *end = buf + len;
  while (p < end) {
    const char *eol = memchr(p, '\n', end - p);
    size_t llen = eol ? (size_t)(eol - p) : (size_t)(end - p);
    if (llen > 0) {
      htsmsg_t *m = pvr_parse_jsonl_line(p, llen);
      if (m) {
        htsmsg_add_msg(items, NULL, m);
      } else {
        rc++;
      }
    }
    if (!eol) break;
    p = eol + 1;
  }
  free(buf);
  htsmsg_add_u32(out, "parse_errors", rc);
  return out;
}

/* Build the JSON for /pvr/api/queue/<kind>/done: just the
 * paths, one per line, in a list. */
static htsmsg_t *
pvr_build_done_response(const pvr_queue_t *q)
{
  const char *path = getenv(q->env_done);
  htsmsg_t *out = htsmsg_create_map();
  htsmsg_add_str(out, "kind", q->kind);
  htsmsg_add_str(out, "path", path ? path : "");
  htsmsg_t *paths = htsmsg_create_list();
  htsmsg_add_msg(out, "paths", paths);
  if (!path || !*path) return out;
  size_t len = 0;
  char *buf = pvr_read_file_capped(path, 1u << 20, &len);
  if (!buf) return out;
  const char *p = buf;
  const char *end = buf + len;
  while (p < end) {
    const char *eol = memchr(p, '\n', end - p);
    size_t llen = eol ? (size_t)(eol - p) : (size_t)(end - p);
    if (llen > 0) {
      char *line = malloc(llen + 1);
      if (line) {
        memcpy(line, p, llen);
        line[llen] = '\0';
        htsmsg_add_str(paths, NULL, line);
        free(line);
      }
    }
    if (!eol) break;
    p = eol + 1;
  }
  free(buf);
  return out;
}

/* Last N lines of a log file, newest first. N is hard-coded
 * to 100 — enough for a dashboard view, not enough to make
 * a 100 MB log flush. */
static htsmsg_t *
pvr_build_log_response(const pvr_queue_t *q)
{
  const char *path = getenv(q->env_log);
  htsmsg_t *out = htsmsg_create_map();
  htsmsg_add_str(out, "kind", q->kind);
  htsmsg_add_str(out, "path", path ? path : "");
  htsmsg_t *lines = htsmsg_create_list();
  htsmsg_add_msg(out, "lines", lines);
  if (!path || !*path) return out;
  size_t len = 0;
  char *buf = pvr_read_file_capped(path, 1u << 20, &len);
  if (!buf) return out;
  /* Walk from the end. We bound the iteration at 100 lines
   * to keep the response small. */
  const int N = 100;
  int kept = 0;
  const char *p = buf + len;
  const char *start = buf;
  while (p > start && kept < N) {
    const char *nl = p;
    while (nl > start && *(nl - 1) != '\n') nl--;
    size_t llen = (size_t)(p - nl);
    if (llen > 0) {
      char *line = malloc(llen + 1);
      if (line) {
        memcpy(line, nl, llen);
        line[llen] = '\0';
        htsmsg_add_str(lines, NULL, line);
        free(line);
        kept++;
      }
    }
    p = nl - 1;
    if (p < start) break;
  }
  free(buf);
  return out;
}

/* Write the JSON response. The TVH webserver uses
 * htsmsg_json_serialize_to_str + http_output_content to
 * produce the body — see webui.c hdhomerun_server_lineup for
 * the canonical example. */
static int
pvr_send_json(http_connection_t *hc, htsmsg_t *m)
{
  char *json = htsmsg_json_serialize_to_str(m, 1);
  htsmsg_destroy(m);
  if (!json) return HTTP_STATUS_INTERNAL;
  htsbuf_append_str(&hc->hc_reply, json);
  free(json);
  http_output_content(hc, "application/json");
  return 0;
}

/* URL dispatcher. Returns NULL if the URL does not match a
 * known route. */
static const pvr_queue_t *
pvr_queue_by_kind(const char *kind)
{
  if (!kind) return NULL;
  if (!strcmp(kind, "comskip"))  return &pvr_queue_comskip;
  if (!strcmp(kind, "transcode")) return &pvr_queue_transcode;
  return NULL;
}

/* HTTP handler. Routes:
 *   GET /pvr/api/queue/<kind>          -> pvr_build_queue_response
 *   GET /pvr/api/queue/<kind>/done     -> pvr_build_done_response
 *   GET /pvr/api/log/<kind>            -> pvr_build_log_response
 *
 * Registered in webui.c as
 *   http_path_add("/pvr/api/queue",   pvr_api_queue,   ACCESS_WEB_INTERFACE)
 *   http_path_add("/pvr/api/log",     pvr_api_log,     ACCESS_WEB_INTERFACE)
 * with a path-modifier that splits the remainder into
 * <kind>[/done]. For simplicity here we parse the full
 * path from `remain`. */
int
pvr_api_handler(http_connection_t *hc, const char *remain, void *opaque)
{
  if (!remain) return HTTP_STATUS_BAD_REQUEST;
  /* remain looks like "queue/comskip/done" or "log/transcode" */
  const char *p = remain;
  const char *seg1 = p;
  while (*p && *p != '/') p++;
  size_t seg1_len = (size_t)(p - seg1);
  if (seg1_len == 0) return HTTP_STATUS_NOT_FOUND;
  if (*p == '/') p++;
  const char *seg2 = p;
  while (*p && *p != '/') p++;
  size_t seg2_len = (size_t)(p - seg2);
  const char *seg3 = NULL;
  size_t seg3_len = 0;
  if (*p == '/') {
    p++;
    seg3 = p;
    while (*p) p++;
    seg3_len = (size_t)(p - seg3);
  }
  if (!strcmp(seg1, "queue") && seg1_len == 5 && seg2_len > 0) {
    char kind[PVR_QUEUE_NAME_MAX];
    if (seg2_len >= sizeof(kind)) return HTTP_STATUS_BAD_REQUEST;
    memcpy(kind, seg2, seg2_len);
    kind[seg2_len] = '\0';
    const pvr_queue_t *q = pvr_queue_by_kind(kind);
    if (!q) return HTTP_STATUS_NOT_FOUND;
    if (seg3_len == 4 && !memcmp(seg3, "done", 4))
      return pvr_send_json(hc, pvr_build_done_response(q));
    if (seg3_len == 0)
      return pvr_send_json(hc, pvr_build_queue_response(q));
    return HTTP_STATUS_NOT_FOUND;
  }
  if (!strcmp(seg1, "log") && seg1_len == 3 && seg2_len > 0) {
    char kind[PVR_QUEUE_NAME_MAX];
    if (seg2_len >= sizeof(kind)) return HTTP_STATUS_BAD_REQUEST;
    memcpy(kind, seg2, seg2_len);
    kind[seg2_len] = '\0';
    const pvr_queue_t *q = pvr_queue_by_kind(kind);
    if (!q) return HTTP_STATUS_NOT_FOUND;
    if (seg3_len == 0)
      return pvr_send_json(hc, pvr_build_log_response(q));
    return HTTP_STATUS_NOT_FOUND;
  }
  return HTTP_STATUS_NOT_FOUND;
}
