// Settings > Audit Notification Setup (SQLScripts/2397, 2528): notification areas, each with its events. Per branch and
// event: on / off, the users who get it, and - where the event supports them - WhatsApp / e-mail, "also the doctor" and
// the daily send time. The areas and their events come from the server, so a new area needs no change here.
(function () {
    const root = document.getElementById('anRoot');
    if (!root) return;
    const U = root.dataset;
    const token = () => document.querySelector('input[name="__RequestVerificationToken"]').value;
    const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
    const fmt = s => s ? new Date(s).toLocaleString('en-GB', { day: '2-digit', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' }) : '';
    let data = null;
    let area = (location.hash || '').replace('#', '') || null;

    const moduleClass = m => (m === 'OPD' ? 'opd' : m === 'LAB' ? 'lab' : 'other');
    const eventsOf = code => data.events.filter(e => e.areaCode === code);

    function userOption(u) {
        const contact = [u.mobile || 'no mobile', u.email].filter(Boolean).join(' · ');
        const label = `${u.name} · ${contact}${u.username && u.username !== u.name && u.username !== u.email ? ' · ' + u.username : ''}`;
        return `<option value="${u.userId}" ${u.mobile ? '' : 'data-nomobile="1"'}>${esc(label)}</option>`;
    }

    // ── the areas ──
    function renderAreas() {
        $('#anAreas').html(data.areas.map(a => {
            const ev = eventsOf(a.areaCode), on = ev.filter(e => e.isEnabled).length;
            return `<button type="button" class="an-area ${a.areaCode === area ? 'active' : ''}" data-area="${esc(a.areaCode)}">
                <span class="an-area-icon"><i class="bi ${esc(a.icon || 'bi-bell')}"></i></span>
                <span class="flex-grow-1 text-start">
                    <span class="d-block fw-semibold an-area-title">${esc(a.title)}</span>
                    <span class="d-block an-area-sub">${on} of ${ev.length} on</span>
                </span>
                <span class="an-area-dot ${on ? 'on' : ''}" title="${on ? 'Some notifications on' : 'All off'}"></span>
            </button>`;
        }).join(''));
        const a = data.areas.find(x => x.areaCode === area);
        $('#anAreaHead').html(a ? `<div class="d-flex align-items-center gap-3">
                <div class="an-area-icon lg"><i class="bi ${esc(a.icon || 'bi-bell')}"></i></div>
                <div><div class="fw-bold fs-5">${esc(a.title)}</div><div class="small text-muted">${esc(a.description || '')}</div></div>
            </div>` : '');
    }

    // ── an event's options strip (only what it supports) ──
    function optionsHtml(e) {
        const parts = [];
        parts.push(`<div class="an-opt"><span class="an-opt-l">Send by</span>
            <label class="an-chip ${e.sendWhatsApp ? 'on' : ''}"><input type="checkbox" class="an-wa" ${e.sendWhatsApp ? 'checked' : ''} ${e.supportsEmail ? '' : 'disabled'}><i class="bi bi-whatsapp"></i> WhatsApp</label>
            ${e.supportsEmail ? `<label class="an-chip ${e.sendEmail ? 'on' : ''}"><input type="checkbox" class="an-mail" ${e.sendEmail ? 'checked' : ''}><i class="bi bi-envelope"></i> E-mail</label>` : ''}
        </div>`);
        if (e.hasThreshold)
            parts.push(`<div class="an-opt"><span class="an-opt-l">Alert when discount is above</span>
                <div class="input-group input-group-sm an-pct-group"><input type="number" min="0.01" max="99.99" step="0.01" class="form-control an-pct text-end" value="${esc(e.thresholdPct ?? 10)}"><span class="input-group-text">%</span></div>
                <span class="small text-muted">of the bill amount - discount given by % or by ₹; membership discount not counted. OPD and LAB B2C bills.</span></div>`);
        if (e.supportsDoctor)
            parts.push(`<div class="an-opt"><div class="form-check form-switch m-0">
                <input class="form-check-input an-doctor" type="checkbox" role="switch" id="doc_${esc(e.eventCode)}" ${e.notifyDoctor ? 'checked' : ''}>
                <label class="form-check-label small" for="doc_${esc(e.eventCode)}">Also send to the <b>doctor</b> <span class="text-muted">(Doctor Master mobile / e-mail)</span></label></div></div>`);
        if (e.isDaily)
            parts.push(`<div class="an-opt"><span class="an-opt-l">Send daily at</span>
                <input type="time" class="form-control form-control-sm an-time" value="${esc(e.sendTime || '07:00')}">
                <span class="small text-muted">${e.lastRunAt ? 'Last sent ' + fmt(e.lastRunAt) : 'Not sent yet'}</span>
                <button type="button" class="btn btn-outline-primary btn-sm an-now" title="Send today's roster to the doctors and users now"><i class="bi bi-send me-1"></i>Send today's now</button></div>`);
        return `<div class="an-opts">${parts.join('')}</div>`;
    }

    function renderEvents() {
        const users = data.users || [];
        const chosen = code => (data.recipients || []).filter(r => r.eventCode === code).map(r => String(r.userId));
        const ev = eventsOf(area);
        $('#anEvents').html(ev.length ? ev.map(e => `
            <div class="col-12 ${ev.length > 1 ? 'col-xxl-6' : ''}">
                <div class="an-card an-event p-3 h-100 ${e.isEnabled ? 'is-on' : ''}" data-code="${esc(e.eventCode)}">
                    <div class="d-flex align-items-start gap-3">
                        <div class="an-icon ${moduleClass(e.module)}"><i class="bi ${esc(e.icon || 'bi-bell')}"></i></div>
                        <div class="flex-grow-1">
                            <div class="d-flex align-items-center gap-2 flex-wrap">
                                <span class="fw-bold">${esc(e.title)}</span>
                                <span class="badge an-mod ${moduleClass(e.module)} border">${esc(e.module)}</span>
                                ${e.isDaily ? '<span class="badge bg-info-subtle text-info-emphasis border">Daily</span>' : ''}
                                <span class="badge rounded-pill ${e.isEnabled ? 'bg-success' : 'bg-secondary'} an-state">${e.isEnabled ? 'ON' : 'OFF'}</span>
                            </div>
                            <div class="small text-muted">${esc(e.description || '')}</div>
                        </div>
                        <div class="form-check form-switch m-0" title="On / off">
                            <input class="form-check-input an-enabled" type="checkbox" role="switch" ${e.isEnabled ? 'checked' : ''} style="width:2.6em;height:1.4em;cursor:pointer">
                        </div>
                    </div>
                    ${optionsHtml(e)}
                    <label class="form-label small fw-semibold mt-3 mb-1"><i class="bi bi-people me-1"></i>${e.supportsDoctor ? 'Also send to these users' : 'Send to'}</label>
                    <select class="form-select an-users" multiple data-placeholder="Choose users…">${users.map(userOption).join('')}</select>
                    <div class="d-flex align-items-center justify-content-between mt-2 gap-2 flex-wrap">
                        <span class="small an-msg text-muted">${e.modifiedDate ? 'Last saved ' + fmt(e.modifiedDate) : 'Not set up yet'}</span>
                        <div class="d-flex gap-2">
                            <button type="button" class="btn btn-outline-success btn-sm an-test" title="Send a sample to the users saved for this notification (never to doctors)"><i class="bi bi-send-check me-1"></i>Send test</button>
                            <button type="button" class="btn btn-primary btn-sm an-save"><i class="bi bi-save me-1"></i>Save</button>
                        </div>
                    </div>
                </div>
            </div>`).join('') : '<div class="col-12 text-muted small">No notification in this area yet.</div>');

        $('#anEvents .an-event').each(function () {
            $(this).find('.an-users').val(chosen(this.dataset.code)).select2({
                theme: 'bootstrap-5', width: '100%', placeholder: 'Choose users…', closeOnSelect: false,
                templateResult: o => o.element && o.element.dataset.nomobile ? $('<span class="text-muted">' + esc(o.text) + ' <i class="bi bi-exclamation-triangle text-warning"></i></span>') : o.text
            });
        });
    }

    function renderLog() {
        const all = $('#anLogAll').is(':checked');
        const rows = (data.log || []).filter(l => all || (l.areaCode || 'AUDIT') === area);
        $('#anLog').html(rows.length ? rows.map(l => `<tr>
            <td class="ps-3 text-nowrap">${fmt(l.createdDate)}</td><td>${esc(l.eventTitle || l.eventCode)}</td>
            <td class="font-monospace small">${esc(l.refNo || '')}</td>
            <td>${esc(l.recipientName || '')}<div class="text-muted" style="font-size:.72rem">${esc(l.phone || '')}</div></td>
            <td><i class="bi ${l.channel === 'EMAIL' ? 'bi-envelope text-primary' : 'bi-whatsapp text-success'}" title="${l.channel === 'EMAIL' ? 'E-mail' : 'WhatsApp'}"></i></td>
            <td><span class="badge an-status ${l.status === 'Sent' ? 'bg-success' : l.status === 'Skipped' ? 'bg-secondary' : 'bg-danger'}">${esc(l.status)}</span></td>
            <td class="text-muted">${esc(l.detail || '')}</td></tr>`).join('') : '<tr><td colspan="7" class="ps-3 text-muted">Nothing sent yet.</td></tr>');
    }

    function render() {
        if (!data.areas.some(a => a.areaCode === area)) area = data.areas[0]?.areaCode || null;
        if (data.branchName) $('#anBranch').html('<i class="bi bi-building me-1"></i>' + esc(data.branchName));
        $('#kAreas').text(data.areas.length);
        $('#kOn').text(`${data.events.filter(e => e.isEnabled).length} / ${data.events.length}`);
        $('#kUsers').text(new Set((data.recipients || []).map(r => r.userId)).size);
        $('#kSent').text((data.log || []).filter(l => l.status === 'Sent').length);
        renderAreas(); renderEvents(); renderLog();
    }

    async function load() {
        try {
            const r = await (await fetch(U.dataUrl)).json();
            if (!r.success) return;
            r.areas = r.areas || [];
            data = r; render();
        } catch { $('#anEvents').html('<div class="col-12 text-danger small">Could not load the setup.</div>'); }
    }

    function note($c, text, cls) { $c.find('.an-msg').attr('class', 'small an-msg ' + cls).text(text); }

    async function post(url, body, $c, $btn) {
        const b = new FormData(); Object.entries(body).forEach(([k, v]) => v !== undefined && b.append(k, v)); b.append('__RequestVerificationToken', token());
        $btn.prop('disabled', true);
        try {
            const r = await (await fetch(url, { method: 'POST', body: b })).json();
            if (!r.needsForce) note($c, r.message, r.success ? 'text-success' : 'text-danger');
            return r;
        } catch { note($c, 'Could not reach the server.', 'text-danger'); return { success: false }; }
        finally { $btn.prop('disabled', false); }
    }

    async function refreshLog() {
        const r = await (await fetch(U.dataUrl)).json();
        if (r.success) { data.log = r.log; data.events = r.events; $('#kSent').text(r.log.filter(l => l.status === 'Sent').length); renderLog(); }
    }

    // ── events ──
    $('#anAreas').on('click', '.an-area', function () {
        area = this.dataset.area;
        history.replaceState(null, '', '#' + area);
        renderAreas(); renderEvents(); renderLog();
    });
    const dirty = el => note($(el).closest('.an-event'), 'Not saved yet - press Save.', 'text-warning-emphasis');
    $('#anEvents').on('change', '.an-enabled', function () {
        const on = this.checked;
        $(this).closest('.an-event').toggleClass('is-on', on).find('.an-state').toggleClass('bg-success', on).toggleClass('bg-secondary', !on).text(on ? 'ON' : 'OFF');
        dirty(this);
    });
    $('#anEvents').on('change', '.an-wa, .an-mail', function () { $(this).closest('.an-chip').toggleClass('on', this.checked); dirty(this); });
    $('#anEvents').on('change input', '.an-users, .an-doctor, .an-time, .an-pct', function () { dirty(this); });

    $('#anEvents').on('click', '.an-save', async function () {
        const $c = $(this).closest('.an-event'), code = $c.data('code'), e = data.events.find(x => x.eventCode === code) || {};
        const body = { eventCode: code, isEnabled: $c.find('.an-enabled').is(':checked'), userIds: ($c.find('.an-users').val() || []).join(',') };
        if (e.supportsEmail) { body.sendWhatsApp = $c.find('.an-wa').is(':checked'); body.sendEmail = $c.find('.an-mail').is(':checked'); }
        if (e.supportsDoctor) body.notifyDoctor = $c.find('.an-doctor').is(':checked');
        if (e.isDaily) body.sendTime = $c.find('.an-time').val() || '07:00';
        if (e.hasThreshold) {
            const pct = Number($c.find('.an-pct').val());
            if (!(pct > 0 && pct < 100)) { note($c, 'Enter the discount percentage (more than 0, less than 100).', 'text-danger'); $c.find('.an-pct').focus(); return; }
            body.thresholdPct = pct;
        }
        const r = await post(U.saveUrl, body, $c, $(this));
        if (r.success) { await load(); note($(`.an-event[data-code="${code}"]`), r.message, 'text-success'); }
    });
    $('#anEvents').on('click', '.an-test', async function () {
        const $c = $(this).closest('.an-event');
        await post(U.testUrl, { eventCode: $c.data('code') }, $c, $(this));
        await refreshLog();
    });
    $('#anEvents').on('click', '.an-now', async function () {
        const $c = $(this).closest('.an-event'), $b = $(this), code = $c.data('code');
        const ask = async (title, text) => !window.Swal || (await Swal.fire({ icon: 'question', title, text, showCancelButton: true, confirmButtonText: 'Send' })).isConfirmed;
        if (!await ask("Send today's roster now?", 'Every doctor with a session today (and the chosen users) gets it now. The scheduled send then skips today.')) return;
        let r = await post(U.nowUrl, { eventCode: code }, $c, $b);
        if (r.needsForce) {
            if (!await ask('Already sent today', r.message)) { note($c, 'Not sent.', 'text-muted'); return; }
            r = await post(U.nowUrl, { eventCode: code, force: true }, $c, $b);
        }
        const msg = r.message; await load(); if (msg) note($(`.an-event[data-code="${code}"]`), msg, r.success ? 'text-success' : 'text-danger');
    });
    $('input[name="anLogScope"]').on('change', () => data && renderLog());
    $('#anReload').on('click', load);
    load();
})();
