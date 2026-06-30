/**
 * tvheadend.postproc — qnap-pvr fork
 *
 * Post-Processing -välilehti ja Status-paneeli PVR-post-processing-
 * jonoille (comskip + transcode). Moduuli käyttää pvr-queue-exposer
 * -nimistä HTTP-bridgeä (pvr_internal-verkossa, port 8765) joka
 * lukee queue-tiedostot ja palauttaa JSON-muodossa.
 *
 * Kaksi julkista funktiota:
 *
 *   tvheadend.postproc.dvr(panel, index)
 *     Lisää Post-Processing -välilehden DVR-paneeliin. Sisältää
 *     kaksi subtabia (Comskip ja Transcode), joista kummassakin on
 *     Queue-lista ja Done-lista.
 *
 *   tvheadend.postproc.status(panel)
 *     Lisää Post-Processing -yhteenvetopaneelin Status-välilehdelle.
 *     KPI-tyyli: aktiiviset / jonossa / valmistuneet / virheet.
 *
 * Päivitys: molemmat näkymät pollataan 10s välein. Pollaus ei
 * tarvitse comet-WS-yhteyttä, koska pvr-queue-exposer ei lähetä
 * push-notifikaatioita.
 */

tvheadend.postproc = function() {

    // -------------------------------------------------------------
    // Konfig — pvr-queue-exposer -palvelimen osoite
    // -------------------------------------------------------------
    // The browser runs on the LAN and cannot resolve the
    // in-compose hostname 'pvr-queue-exposer' (which lives on
    // the isolated `pvr_internal` Docker network). To make the
    // bridge reachable, compose.yml attaches pvr-queue-exposer
    // to the macvlan network with a fixed LAN IP. This URL
    // points at that macvlan interface. It can be overridden at
    // runtime by setting window.PVR_EXPOSER_URL before this
    // module's bundle loads — see .env.example for how the
    // build-time default is sourced.
    var EXPOSER_URL = window.PVR_EXPOSER_URL || '__PVR_EXPOSER_LAN_URL__';
    var REFRESH_MS = 10000;
    var FETCH_TIMEOUT_MS = 5000;

    // -------------------------------------------------------------
    // Apu: HTTP-pyyntö JSON-muodossa
    // -------------------------------------------------------------
    function fetch_json(path, callback) {
        Ext.Ajax.request({
            url: EXPOSER_URL + path,
            method: 'GET',
            timeout: FETCH_TIMEOUT_MS,
            success: function (resp) {
                try {
                    callback(null, Ext.decode(resp.responseText));
                } catch (e) {
                    callback(e, null);
                }
            },
            failure: function (resp, opts) {
                callback(new Error('HTTP ' + resp.status + ' for ' + path), null);
            }
        });
    }

    // -------------------------------------------------------------
    // Renderöinti: polkulista
    // -------------------------------------------------------------
    // Muodostaa HTML-taulukon polku-listasta. Polut ovat pitkiä
    // (sisältävät päivämäärän ja hakemistorakenteen), joten ne
    // katkaistaan näytön leveyden mukaan ja näytetään
    // title-attribuutissa kokonaisuudessaan.
    function render_paths_html(paths, empty_msg) {
        if (!paths || paths.length === 0) {
            return '<div class="x-grid-empty">' + _(empty_msg) + '</div>';
        }
        var html = '<table class="x-grid3-row-table" style="width:100%">';
        html += '<thead><tr class="x-grid3-hd-row">';
        html += '<td class="x-grid3-hd" style="width:30px">#</td>';
        html += '<td class="x-grid3-hd">' + _('Path') + '</td>';
        html += '</tr></thead><tbody>';
        var max = Math.min(paths.length, 100);  // rajataan 100:aan
        for (var i = 0; i < max; i++) {
            var p = paths[i];
            html += '<tr class="x-grid3-row">';
            html += '<td>' + (i + 1) + '</td>';
            html += '<td style="overflow:hidden;text-overflow:ellipsis;white-space:nowrap" title="' + Ext.util.Format.htmlEncode(p) + '">';
            html += Ext.util.Format.htmlEncode(p);
            html += '</td></tr>';
        }
        if (paths.length > max) {
            html += '<tr class="x-grid3-row"><td colspan="2"><i>... ' + (paths.length - max) + ' more</i></td></tr>';
        }
        html += '</tbody></table>';
        return html;
    }

    // -------------------------------------------------------------
    // Renderöinti: JSONL-jono (path + aikaleima)
    // -------------------------------------------------------------
    function render_jsonl_queue_html(items, empty_msg) {
        if (!items || items.length === 0) {
            return '<div class="x-grid-empty">' + _(empty_msg) + '</div>';
        }
        var html = '<table class="x-grid3-row-table" style="width:100%">';
        html += '<thead><tr class="x-grid3-hd-row">';
        html += '<td class="x-grid3-hd" style="width:30px">#</td>';
        html += '<td class="x-grid3-hd">' + _('Path') + '</td>';
        html += '<td class="x-grid3-hd" style="width:180px">' + _('Added') + '</td>';
        html += '</tr></thead><tbody>';
        var max = Math.min(items.length, 100);
        for (var i = 0; i < max; i++) {
            var it = items[i];
            var p = it.path || '?';
            var added = it.added || '';
            html += '<tr class="x-grid3-row">';
            html += '<td>' + (i + 1) + '</td>';
            html += '<td style="overflow:hidden;text-overflow:ellipsis;white-space:nowrap" title="' + Ext.util.Format.htmlEncode(p) + '">';
            html += Ext.util.Format.htmlEncode(p);
            html += '</td>';
            html += '<td>' + Ext.util.Format.htmlEncode(added) + '</td>';
            html += '</tr>';
        }
        if (items.length > max) {
            html += '<tr class="x-grid3-row"><td colspan="3"><i>... ' + (items.length - max) + ' more</i></td></tr>';
        }
        html += '</tbody></table>';
        return html;
    }

    // -------------------------------------------------------------
    // Yhteinen refresher — yksinkertainen setInterval-jakso
    // -------------------------------------------------------------
    function attach_auto_refresh(panel, render_fn) {
        render_fn();  // ensimmäinen haku välittömästi
        var iv = setInterval(render_fn, REFRESH_MS);
        panel.on('destroy', function () { clearInterval(iv); });
    }

    // -------------------------------------------------------------
    // J1+J2: DVR — Post-Processing -välilehti
    // -------------------------------------------------------------
    // Käyttää tvheadend.dvr() -funktiokutsun jälkeen annettua
    // TabPanel-paneelia. Lisätään kaksi subtabia: Comskip ja
    // Transcode.
    function dvr(parent_panel, index) {
        var p = new Ext.TabPanel({
            activeTab: 0,
            autoScroll: true,
            title: _('Post-Processing'),
            iconCls: 'queue',
            items: []
        });

        // ---- Comskip subtab ----
        var cs_queue_panel = new Ext.Panel({
            title: _('Queue'),
            autoScroll: true,
            html: '<div class="x-grid-empty">' + _('Loading...') + '</div>'
        });
        var cs_done_panel = new Ext.Panel({
            title: _('Done'),
            autoScroll: true,
            html: '<div class="x-grid-empty">' + _('Loading...') + '</div>'
        });
        var cs = new Ext.TabPanel({
            activeTab: 0,
            autoScroll: true,
            title: _('Comskip'),
            items: [cs_queue_panel, cs_done_panel]
        });

        function refresh_cs() {
            fetch_json('/api/queue/comskip', function (err, data) {
                if (err) {
                    cs_queue_panel.body.update(
                        '<div class="x-grid-empty">' + _('Error: ') + err.message + '</div>'
                    );
                    return;
                }
                cs_queue_panel.body.update(render_jsonl_queue_html(data.items, 'Queue empty'));
            });
            fetch_json('/api/queue/comskip/done', function (err, data) {
                if (err) {
                    cs_done_panel.body.update(
                        '<div class="x-grid-empty">' + _('Error: ') + err.message + '</div>'
                    );
                    return;
                }
                cs_done_panel.body.update(render_paths_html(data.paths, 'No done entries'));
            });
        }
        attach_auto_refresh(cs, refresh_cs);

        // ---- Transcode subtab ----
        var tc_queue_panel = new Ext.Panel({
            title: _('Queue'),
            autoScroll: true,
            html: '<div class="x-grid-empty">' + _('Loading...') + '</div>'
        });
        var tc_done_panel = new Ext.Panel({
            title: _('Done'),
            autoScroll: true,
            html: '<div class="x-grid-empty">' + _('Loading...') + '</div>'
        });
        var tc = new Ext.TabPanel({
            activeTab: 0,
            autoScroll: true,
            title: _('Transcode'),
            items: [tc_queue_panel, tc_done_panel]
        });

        function refresh_tc() {
            fetch_json('/api/queue/transcode', function (err, data) {
                if (err) {
                    tc_queue_panel.body.update(
                        '<div class="x-grid-empty">' + _('Error: ') + err.message + '</div>'
                    );
                    return;
                }
                tc_queue_panel.body.update(render_jsonl_queue_html(data.items, 'Queue empty'));
            });
            fetch_json('/api/queue/transcode/done', function (err, data) {
                if (err) {
                    tc_done_panel.body.update(
                        '<div class="x-grid-empty">' + _('Error: ') + err.message + '</div>'
                    );
                    return;
                }
                tc_done_panel.body.update(render_paths_html(data.paths, 'No done entries'));
            });
        }
        attach_auto_refresh(tc, refresh_tc);

        p.add(cs);
        p.add(tc);
        parent_panel.add(p);
    }

    // -------------------------------------------------------------
    // J3: Status — Post-Processing -paneeli
    // -------------------------------------------------------------
    // KPI-tyyli: 4 numeroa (comskip-jono, comskip-done, transcode-jono,
    // transcode-done) + 2 virhelaskuria (comskip FAIL 24h, transcode FAIL 24h).
    function status(parent_panel) {
        var panel = new Ext.Panel({
            title: _('Post-Processing'),
            autoScroll: true,
            html: '<div class="x-grid-empty">' + _('Loading...') + '</div>'
        });

        function render_kpi(s) {
            // s.comskip ja s.transcode objekteja, joissa queue_count,
            // done_count, failures_24h
            var cs = s.comskip || {};
            var tc = s.transcode || {};
            var html = '<div style="padding:12px;display:flex;flex-wrap:wrap;gap:12px">';
            html += kpi_card(_('Comskip queue'), cs.queue_count || 0, 'recordings');
            html += kpi_card(_('Comskip done'), cs.done_count || 0, 'recordings');
            html += kpi_card(_('Comskip failures (24h)'), cs.failures_24h || 0, 'errors');
            html += kpi_card(_('Transcode queue'), tc.queue_count || 0, 'recordings');
            html += kpi_card(_('Transcode done'), tc.done_count || 0, 'recordings');
            html += kpi_card(_('Transcode failures (24h)'), tc.failures_24h || 0, 'errors');
            html += '</div>';
            html += '<div style="padding:0 12px 12px;font-size:11px;color:#888">';
            html += _('Source: pvr-queue-exposer · Refresh: every 10s · ') + new Date().toLocaleString();
            html += '</div>';
            return html;
        }
        function kpi_card(label, value, kind) {
            var color = kind === 'errors' && value > 0 ? '#c0392b' : '#2c3e50';
            return '<div style="border:1px solid #ddd;border-radius:6px;padding:14px 18px;min-width:140px;background:#fafafa">' +
                '<div style="font-size:11px;text-transform:uppercase;color:#7f8c8d;letter-spacing:0.5px">' + label + '</div>' +
                '<div style="font-size:32px;font-weight:600;color:' + color + ';line-height:1.1;margin-top:4px">' + value + '</div>' +
                '</div>';
        }

        function refresh() {
            fetch_json('/api/status', function (err, data) {
                if (err) {
                    panel.body.update(
                        '<div class="x-grid-empty">' + _('Error: ') + err.message +
                        '<br><br>' + _('Source: ') + EXPOSER_URL + '</div>'
                    );
                    return;
                }
                panel.body.update(render_kpi(data));
            });
        }
        attach_auto_refresh(panel, refresh);

        parent_panel.add(panel);
    }

    // Julkiset API:t
    return {
        dvr: dvr,
        status: status,
        // FP1:lle varataan:
        // skip: function (path, kind) {...},
        // trigger: function (kind) {...}
    };

}();