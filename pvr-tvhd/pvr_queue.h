/*
 * qnap-pvr fork — Post-Processing queue reader, public API.
 *
 * The implementation lives in pvr_queue.c. This header is the
 * only thing webui.c needs to see in order to register the
 * HTTP routes for /pvr/api/queue and /pvr/api/log.
 */

#ifndef TVHEADEND_PVR_QUEUE_H_
#define TVHEADEND_PVR_QUEUE_H_

#include "http.h"

/* HTTP handler. Registered in webui.c as
 *   http_path_add("/pvr/api/queue", NULL, pvr_api_handler, ACCESS_WEB_INTERFACE);
 *   http_path_add("/pvr/api/log",   NULL, pvr_api_handler, ACCESS_WEB_INTERFACE);
 *
 * Routes (parsed from `remain`):
 *   /pvr/api/queue/<kind>          -> JSON queue + done_count
 *   /pvr/api/queue/<kind>/done     -> JSON list of done paths
 *   /pvr/api/log/<kind>            -> JSON last 100 log lines
 *
 * The <kind> is one of "comskip" or "transcode". Unknown kinds
 * return 404. Path-modifier parsing is in pvr_queue.c.
 */
int pvr_api_handler(http_connection_t *hc, const char *remain, void *opaque);

#endif /* TVHEADEND_PVR_QUEUE_H_ */
