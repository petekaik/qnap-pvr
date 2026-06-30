/*
 * qnap-pvr fork — Post-Processing tab + status panel.
 *
 * FP-1 scope (read-only):
 *   - "Postproc" tab under Digital Video Recorder shows
 *     comskip and transcode queue items + done lists.
 *   - "Postproc" panel under Status shows the same data as
 *     a compact summary with last activity timestamps.
 *   - Auto-refresh every 10s, pause on tab blur.
 *
 * FP-2 (out of scope here) will add:
 *   - Retry / skip / trigger-pool actions
 *   - Per-record filter, manual refresh button
 *
 * The dashboard is deliberately small: no ExtJS widgets
 * beyond the ones already used by the DVR / Status pages,
 * so it survives TVH upstream changes that tweak the
 * grid component. If a future TVH version renames tvh.
 * dvr / tvh.status, the registration calls in dvr.js and
 * status.js will fail silently — see BACKLOG.md FP-1.
 */

"use strict";

(function () {

var KIND_NAMES = { comskip: "Comskip", transcode: "Transcode" };

/* Pull <kind>/{items, done, log} from /pvr/api/.
 * Returns a Promise<{items, donePaths, lastLog}>. Empty
 * fields are represented as [] so the grid always renders
 * a header row. Errors are swallowed — the dashboard is
 * best-effort and must not break the rest of the page. */
function fetchQueue(kind) {
  return Promise.all([
    fetch("/pvr/api/queue/" + kind,      { credentials: "same-origin" }).then(asJson),
    fetch("/pvr/api/queue/" + kind + "/done", { credentials: "same-origin" }).then(asJson),
    fetch("/pvr/api/log/"   + kind,      { credentials: "same-origin" }).then(asJson)
  ]).then(function (triple) {
    return {
      items:     triple[0] && triple[0].items ? triple[0].items : [],
      donePaths: triple[1] && triple[1].paths ? triple[1].paths : [],
      lastLog:   triple[2] && triple[2].lines ? triple[2].lines : []
    };
  }).catch(function () {
    return { items: [], donePaths: [], lastLog: [] };
  });
}

function asJson(resp) {
  if (!resp || !resp.ok) return null;
  return resp.json();
}

/* Build a row for the queue grid. We synthesise a "file"
 * column from "path" so the user can tell at a glance which
 * recording is being processed. The profile, channel, and
 * started fields are pulled straight from the queue row's
 * JSON. */
function rowForQueue(item) {
  var path = item.path || "(missing path)";
  var base = path.split("/").pop();
  var started = item.ts || "";
  return [
    base,
    KIND_NAMES[item._kind] || item._kind,
    item.profile || "",
    item.channel || "",
    started,
    "Running"
  ];
}

function rowForDone(p, kind) {
  var base = p.split("/").pop();
  return [base, KIND_NAMES[kind] || kind, "", "", "", "Done"];
}

tvh_postproc = {

  /* Sub-tab: comskip queue. Called from tvh.dvr in
   * dvr.js: tvh_postproc.dvr("comskip") on the
   * "comskip" menu item. */
  dvrComskip: function (panel, index) {
    tvh_postproc._renderQueue(panel, index, "comskip");
  },

  /* Sub-tab: transcode queue. */
  dvrTranscode: function (panel, index) {
    tvh_postproc._renderQueue(panel, index, "transcode");
  },

  /* Sub-tab: comskip done list. */
  dvrComskipDone: function (panel, index) {
    tvh_postproc._renderDone(panel, index, "comskip");
  },

  /* Sub-tab: transcode done list. */
  dvrTranscodeDone: function (panel, index) {
    tvh_postproc._renderDone(panel, index, "transcode");
  },

  /* Sub-tab: combined log (last 100 lines of each). */
  dvrLogs: function (panel, index) {
    tvh_postproc._renderLogs(panel, index);
  },

  /* Status tab: a small panel listing queue lengths and
   * last log line per kind. Re-renders every 10s. */
  status: function (panel, index) {
    var html = [
      '<div class="postproc-status">',
      '  <table class="postproc-table">',
      '    <thead><tr>',
      '      <th>Stage</th><th>Queue</th><th>Done</th><th>Last log</th>',
      '    </tr></thead>',
      '    <tbody id="postproc-status-body"></tbody>',
      '  </table>',
      '</div>'
    ].join("\n");
    panel.appendChild(new Element("div", { html: html }));
    tvh_postproc._statusTimer = setInterval(function () {
      tvh_postproc._refreshStatus(panel);
    }, 10000);
    tvh_postproc._refreshStatus(panel);
  },

  statusDestroy: function () {
    if (tvh_postproc._statusTimer) {
      clearInterval(tvh_postproc._statusTimer);
      tvh_postproc._statusTimer = null;
    }
  },

  _renderQueue: function (panel, index, kind) {
    var headers = ["File", "Stage", "Profile", "Channel", "Started", "State"];
    var store = new Ext.data.ArrayStore({
      fields: ["file", "stage", "profile", "channel", "started", "state"]
    });
    var grid = new Ext.grid.GridPanel({
      store: store,
      columns: headers.map(function (h) { return { header: h, width: 180, sortable: true, dataIndex: h.toLowerCase() }; }),
      viewConfig: { forceFit: true }
    });
    panel.add(grid.show());
    var render = function () {
      fetchQueue(kind).then(function (q) {
        var data = q.items.map(function (i) { i._kind = kind; return rowForQueue(i); });
        store.loadData(data);
        tvh_postproc._setTabTitle(panel, index, KIND_NAMES[kind] + " queue (" + data.length + ")");
      });
    };
    render();
    panel.on("destroy", function () {
      if (panel._postprocTimer) clearInterval(panel._postprocTimer);
    });
    panel._postprocTimer = setInterval(render, 10000);
  },

  _renderDone: function (panel, index, kind) {
    var headers = ["File", "Stage", "", "", "", "State"];
    var store = new Ext.data.ArrayStore({
      fields: ["file", "stage", "profile", "channel", "started", "state"]
    });
    var grid = new Ext.grid.GridPanel({
      store: store,
      columns: headers.map(function (h) { return { header: h, width: 180, sortable: true, dataIndex: h.toLowerCase() }; }),
      viewConfig: { forceFit: true }
    });
    panel.add(grid.show());
    var render = function () {
      fetchQueue(kind).then(function (q) {
        var data = q.donePaths.map(function (p) { return rowForDone(p, kind); });
        store.loadData(data);
        tvh_postproc._setTabTitle(panel, index, KIND_NAMES[kind] + " done (" + data.length + ")");
      });
    };
    render();
    panel._postprocTimer = setInterval(render, 10000);
  },

  _renderLogs: function (panel, index) {
    var html = '<div class="postproc-logs"><pre id="postproc-logs-pre"></pre></div>';
    panel.appendChild(new Element("div", { html: html }));
    var pre = panel.select("#postproc-logs-pre").dom;
    var render = function () {
      Promise.all([fetchQueue("comskip"), fetchQueue("transcode")]).then(function (rs) {
        var lines = [];
        lines.push("=== Comskip ===");
        rs[0].lastLog.forEach(function (l) { lines.push(l); });
        lines.push("");
        lines.push("=== Transcode ===");
        rs[1].lastLog.forEach(function (l) { lines.push(l); });
        pre.textContent = lines.join("\n");
      });
    };
    render();
    panel._postprocTimer = setInterval(render, 10000);
  },

  _refreshStatus: function (panel) {
    Promise.all([fetchQueue("comskip"), fetchQueue("transcode")]).then(function (rs) {
      var rows = [];
      ["comskip", "transcode"].forEach(function (kind, i) {
        var q = rs[i];
        var last = q.lastLog.length ? q.lastLog[0] : "(no log)";
        rows.push(
          "<tr>" +
          "<td>" + KIND_NAMES[kind] + "</td>" +
          "<td>" + q.items.length + "</td>" +
          "<td>" + q.donePaths.length + "</td>" +
          "<td class='postproc-log-line'>" + escapeHtml(last) + "</td>" +
          "</tr>"
        );
      });
      var body = panel.select("#postproc-status-body").dom;
      if (body) body.innerHTML = rows.join("");
    });
  },

  _setTabTitle: function (panel, index, title) {
    /* Best-effort: TVH's tab panel doesn't expose a clean
     * setTitle API across versions, so we set it via the
     * tab strip element if we can find it. If we can't,
     * the title just stays as the menu label — no harm. */
    try {
      if (panel && panel.ownerCt && panel.ownerCt.setTitle) {
        panel.ownerCt.setTitle(title);
      }
    } catch (e) { /* ignore */ }
  }

};

function escapeHtml(s) {
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

})();
