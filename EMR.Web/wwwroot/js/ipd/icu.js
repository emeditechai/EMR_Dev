/* IPD Patient > ICU Chart (Phase 8, SQLScripts/2493). Config window.IpdIcu = { id, base, open, billOpen, can: { chart, correct, transfer } }.
   Flowsheet entries are never edited: a wrong one is struck out with a reason (ICU_CORRECT) and entered again. */
(function () {
    'use strict';
    const C = window.IpdIcu; if (!C || !document.getElementById('tab-icu')) return;
    const E = v => Ipd.esc(v), $ = id => document.getElementById(id), base = C.base;
    let D = null, loaded = false;

    // ranges outside which a reading is shown red (adult ICU defaults)
    const ABN = { Hr: [50, 120], Sbp: [90, 180], Map: [65, 110], Rr: [10, 30], SpO2: [92, 100], TempC: [36, 38.3], Gcs: [9, 15], Glucose: [70, 250] };
    const abn = (k, x) => x != null && ABN[k] && (Number(x) < ABN[k][0] || Number(x) > ABN[k][1]);
    const ROWS = [
        ['Vitals', [['Hr', 'Heart rate /min'], ['BP', 'BP mmHg'], ['Map', 'MAP'], ['Rr', 'Resp. rate /min'], ['SpO2', 'SpO2 %'], ['TempC', 'Temp °C'], ['Cvp', 'CVP'], ['EtCo2', 'EtCO2']]],
        ['Neuro', [['Gcs', 'GCS (E/V/M)'], ['Rass', 'RASS'], ['PainScore', 'Pain 0-10']]],
        ['Metabolic', [['Glucose', 'Glucose mg/dl']]],
        ['Intake / output (ml)', [['IntakeMl', 'Intake'], ['UrineMl', 'Urine'], ['OtherOutputMl', 'Other output']]],
        ['Ventilator', [['VentMode', 'Mode'], ['FiO2', 'FiO2 %'], ['Peep', 'PEEP'], ['TidalVolume', 'Tidal vol. ml'], ['SetRate', 'Set rate'], ['Pip', 'PIP'], ['PressureSupport', 'Pressure support']]],
        ['', [['Notes', 'Notes'], ['RecordedByName', 'Recorded by']]]
    ];
    const cell = (o, k) => {
        if (k === 'BP') return o.Sbp != null ? `${o.Sbp}/${o.Dbp}` : '';
        if (k === 'Gcs') return o.Gcs != null ? `${o.Gcs} (${o.GcsE}/${o.GcsV}/${o.GcsM})` : '';
        const x = o[k]; return x == null ? '' : (typeof x === 'number' ? String(Number(x)) : x);
    };
    const tm = d => new Date(d).toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit', hour12: false });

    function modal(id, title, body, footer) {
        let m = $(id);
        if (!m) { m = document.createElement('div'); m.className = 'modal fade'; m.id = id; m.tabIndex = -1; document.body.appendChild(m); }
        m.innerHTML = `<div class="modal-dialog modal-lg modal-dialog-scrollable"><div class="modal-content"><div class="modal-header"><h6 class="modal-title fw-bold">${title}</h6>
            <button type="button" class="btn-close" data-bs-dismiss="modal" aria-label="Close"></button></div><div class="modal-body">${body}</div>
            <div class="modal-footer"><button type="button" class="btn btn-outline-secondary" data-bs-dismiss="modal">Close</button>${footer}</div></div></div>`;
        bootstrap.Modal.getOrCreateInstance(m).show();
    }
    const hide = id => bootstrap.Modal.getInstance($(id))?.hide();
    const v = id => $(id) ? $(id).value.trim() : '';
    const n = id => v(id) === '' ? null : Number(v(id));
    const f = (id, label, input, col = 'col-6 col-md-3') => `<div class="${col}"><label class="form-label small fw-semibold" for="${id}">${label}</label>${input}</div>`;
    const nb = (id, min, max, step = 1) => `<input id="${id}" type="number" class="form-control form-control-sm" min="${min}" max="${max}" step="${step}" />`;
    const window_ = () => { const h = Number($('icuWindow').value) || 24, to = new Date(); return { fromAt: Ipd.local(new Date(to.getTime() - h * 3600000)), toAt: Ipd.local(to) }; };

    async function load() {
        const w = window_();
        try { D = await Ipd.get(`${base}Data?id=${C.id}&fromAt=${encodeURIComponent(w.fromAt)}&toAt=${encodeURIComponent(w.toAt)}`); render(); }
        catch (e) { $('icuBody').innerHTML = `<div class="alert alert-danger m-0">${E(e.message)}</div>`; }
    }

    function render() {
        const s = (D.state || [])[0] || {}, stays = D.stays || [], obs = D.observations || [];
        const inIcu = !!s.InIcuNow, canChart = C.can.chart && C.open && inIcu;
        if (!inIcu && !stays.length) {
            $('icuBody').innerHTML = `<div class="ipd-soon"><div class="fs-3 mb-2"><i class="bi bi-activity"></i></div><div class="fw-semibold mb-1">The patient has not been in an ICU bed.</div>
                <div class="small">Shift the patient to an ICU bed from <b>Bed &amp; Transfers</b> (ICU shift); the ICU chart opens for ICU beds.</div></div>`;
            return;
        }
        const cur = stays.find(x => !x.OutAt), ret = stays.some(x => x.IsReturn48h);
        const lastMin = s.LastObservedAt ? Math.round((Date.now() - new Date(s.LastObservedAt)) / 60000) : null;
        const vent = (D.devices || []).find(d => d.Status === 'ACTIVE' && !d.StopAt && /^(VENT|NIV)$/i.test(d.HeadCode));
        const runInf = (D.infusions || []).filter(i => i.Status === 'RUNNING');
        let h = `<div class="icu-state">
            <div><small>Now</small><b>${inIcu ? E(s.BedNumber) + ' · ' + E(s.WardName) : 'Not in ICU'}</b>${ret ? ' <span class="icu-badge ret">return &lt; 48 h</span>' : ''}</div>
            <div><small>ICU tariff</small><b>${s.IcuName ? E(s.IcuName) : '<span class="text-muted fw-normal">Bed / Room Tariff</span>'}</b>${s.TariffFallback ? ' <span class="badge text-bg-warning">default category</span>' : ''}</div>
            <div><small>In ICU since</small><b>${cur ? Ipd.dt(cur.InAt) : '—'}</b>${cur ? `<div class="small text-muted">${Number(cur.Hours).toFixed(1)} h</div>` : ''}</div>
            <div><small>Last observation</small><b>${s.LastObservedAt ? Ipd.dt(s.LastObservedAt) : '—'}</b>${lastMin != null && inIcu && lastMin > 60 ? ` <span class="icu-badge late">${lastMin} min ago</span>` : ''}</div>
            <div><small>Support</small><b>${vent ? '<span class="icu-badge vent">' + E(vent.HeadName) + '</span>' : 'No ventilator'}</b><div class="small text-muted">${runInf.length} infusion(s) running</div></div>
          </div>`;
        if (canChart) h += `<div class="d-flex gap-2 flex-wrap mb-3"><button type="button" class="btn btn-sm btn-primary" id="icuAddObs"><i class="bi bi-plus-lg me-1"></i>Observation</button>
            <button type="button" class="btn btn-sm btn-outline-primary" id="icuAddInf"><i class="bi bi-droplet me-1"></i>Start infusion</button>
            <button type="button" class="btn btn-sm btn-outline-primary" id="icuAddDev"><i class="bi bi-cpu me-1"></i>Start device</button></div>`;
        // flowsheet: one column per observation of the window
        if (obs.length) {
            h += `<div class="ipdx-card mb-3"><div class="table-responsive"><table class="table table-sm table-bordered mb-0 icu-flow"><thead><tr><th>Time</th>${obs.map(o =>
                `<th class="${o.Status === 'STRUCK' ? 'struck' : ''}" title="${Ipd.dt(o.ObservedAt)}${o.Status === 'STRUCK' ? ' · struck: ' + E(o.StruckReason) : ''}">${tm(o.ObservedAt)}<div class="small fw-normal text-muted">${new Date(o.ObservedAt).toLocaleDateString('en-GB', { day: '2-digit', month: 'short' })}</div>
                ${o.Status === 'ACTIVE' && C.can.correct ? `<button type="button" class="btn btn-link btn-sm p-0 text-danger" data-strike="OBS:${o.ObservationId}" title="Strike out">×</button>` : ''}</th>`).join('')}</tr></thead><tbody>`;
            ROWS.forEach(([g, rows]) => {
                if (g) h += `<tr class="grp"><th colspan="${obs.length + 1}">${g}</th></tr>`;
                rows.forEach(([k, label]) => {
                    if (!obs.some(o => cell(o, k) !== '')) return;
                    h += `<tr><th>${label}</th>${obs.map(o => {
                        const x = cell(o, k), bad = o.Status === 'ACTIVE' && (k === 'BP' ? abn('Sbp', o.Sbp) : abn(k, o[k]));
                        return `<td class="${o.Status === 'STRUCK' ? 'struck' : bad ? 'abn' : ''}">${E(x)}</td>`;
                    }).join('')}</tr>`;
                });
            });
            h += '</tbody></table></div></div>';
        } else h += '<div class="alert alert-light border small">No observation in this window.</div>';
        // infusions
        const inf = D.infusions || [];
        h += `<div class="ipdx-card mb-3"><div class="px-3 pt-3"><h6 class="fw-bold mb-2"><i class="bi bi-droplet me-1 text-primary"></i>Infusions</h6></div><div class="table-responsive"><table class="table ipdx-table mb-0">
            <thead><tr><th>Drug / fluid</th><th>Concentration</th><th class="text-end">Rate ml/h</th><th>Dose</th><th>Started</th><th>Status</th><th></th></tr></thead><tbody>
            ${inf.length ? inf.map(i => `<tr><td class="fw-semibold">${E(i.Drug)}</td><td>${E(i.Concentration || '')}</td><td class="text-end">${Number(i.RateMlHr)}</td><td>${E(i.Dose || '')}</td>
                <td>${Ipd.dt(i.StartAt)}</td><td>${i.Status === 'RUNNING' ? '<span class="badge text-bg-success">Running</span>' : `Stopped ${Ipd.dt(i.StopAt)}`}</td>
                <td class="text-nowrap">${i.Status === 'RUNNING' && C.can.chart && C.open ? `<button type="button" class="btn btn-sm btn-outline-primary" data-inf="RATE:${i.InfusionId}">Rate</button> <button type="button" class="btn btn-sm btn-outline-secondary" data-inf="STOP:${i.InfusionId}">Stop</button>` : ''}
                ${C.can.correct ? ` <button type="button" class="btn btn-sm btn-link text-danger" data-strike="INFUSION:${i.InfusionId}" title="Entered by mistake">×</button>` : ''}</td></tr>
                ${(D.events || []).filter(e => e.InfusionId === i.InfusionId && e.EventType === 'RATE').map(e => `<tr class="small text-muted"><td colspan="2" class="ps-4">↳ rate changed</td><td class="text-end">${Number(e.RateMlHr)}</td><td>${E(e.Dose || '')}</td><td>${Ipd.dt(e.EventAt)}</td><td colspan="2">${E(e.CreatedByName || '')}</td></tr>`).join('')}`).join('')
                : '<tr><td colspan="7" class="text-muted small">No infusion in this window.</td></tr>'}</tbody></table></div></div>`;
        // devices
        const dev = D.devices || [];
        h += `<div class="ipdx-card mb-3"><div class="px-3 pt-3"><h6 class="fw-bold mb-0"><i class="bi bi-cpu me-1 text-primary"></i>Devices</h6><small class="text-muted">A device that is an optional head of the ICU tariff is charged for every day it is in use.</small></div>
            <div class="table-responsive"><table class="table ipdx-table mb-0"><thead><tr><th>Device</th><th>Started</th><th>Stopped</th><th class="text-end">Hours</th><th></th></tr></thead><tbody>
            ${dev.length ? dev.map(d => `<tr class="${d.Status === 'STRUCK' ? 'text-muted text-decoration-line-through' : ''}"><td class="fw-semibold">${E(d.HeadName)} <small class="text-muted">${E(d.HeadCode)}</small></td>
                <td>${Ipd.dt(d.StartAt)}</td><td>${d.StopAt ? Ipd.dt(d.StopAt) : (d.Status === 'ACTIVE' ? '<span class="badge text-bg-success">In use</span>' : '')}</td><td class="text-end">${Number(d.Hours).toFixed(1)}</td>
                <td class="text-nowrap">${d.Status === 'ACTIVE' && !d.StopAt && C.can.chart && C.billOpen ? `<button type="button" class="btn btn-sm btn-outline-secondary" data-devstop="${d.DeviceId}">Stop</button>` : ''}
                ${d.Status === 'ACTIVE' && C.can.correct && C.billOpen ? ` <button type="button" class="btn btn-sm btn-link text-danger" data-strike="DEVICE:${d.DeviceId}" title="Entered by mistake">×</button>` : E(d.StruckReason || '')}</td></tr>`).join('')
                : '<tr><td colspan="5" class="text-muted small">No device recorded.</td></tr>'}</tbody></table></div></div>`;
        // stays and I/O
        const io = D.io || [];
        h += `<div class="row g-3"><div class="col-lg-7"><div class="ipdx-card"><div class="px-3 pt-3"><h6 class="fw-bold mb-2">ICU stays</h6></div><table class="table ipdx-table mb-0">
            <thead><tr><th>#</th><th>In</th><th>Out</th><th class="text-end">Hours</th><th>Return within 48 h</th></tr></thead><tbody>
            ${stays.map(x => `<tr><td>${x.StayNo}</td><td>${Ipd.dt(x.InAt)}</td><td>${x.OutAt ? Ipd.dt(x.OutAt) : '<span class="badge text-bg-danger">in ICU</span>'}</td><td class="text-end">${Number(x.Hours).toFixed(1)}</td>
                <td>${x.IsReturn48h ? `<span class="icu-badge ret">Yes · ${Number(x.HoursSincePrev).toFixed(1)} h after leaving</span>` : '—'}</td></tr>`).join('')}</tbody></table></div></div>
          <div class="col-lg-5"><div class="ipdx-card"><div class="px-3 pt-3"><h6 class="fw-bold mb-2">Intake / output (08:00 – 08:00)</h6></div><table class="table ipdx-table mb-0">
            <thead><tr><th>Day</th><th class="text-end">In</th><th class="text-end">Urine</th><th class="text-end">Other</th><th class="text-end">Balance</th></tr></thead><tbody>
            ${io.length ? io.map(x => `<tr><td>${Ipd.date(x.Day)}</td><td class="text-end">${x.IntakeMl}</td><td class="text-end">${x.UrineMl}</td><td class="text-end">${x.OtherOutputMl}</td>
                <td class="text-end fw-semibold ${x.BalanceMl > 0 ? 'text-primary' : 'text-danger'}">${x.BalanceMl > 0 ? '+' : ''}${x.BalanceMl}</td></tr>`).join('') : '<tr><td colspan="5" class="text-muted small">No intake / output recorded.</td></tr>'}</tbody></table></div></div></div>`;
        $('icuBody').innerHTML = h;
    }

    // ── entry dialogs ──────────────────────────────────────────────────────────────────────────────────────────
    function addObservation() {
        modal('icuObsModal', '<i class="bi bi-plus-lg me-1"></i>ICU observation', `<div class="row g-2">
            ${f('oAt', 'Time *', `<input type="datetime-local" id="oAt" class="form-control form-control-sm" value="${Ipd.local(new Date())}" />`, 'col-12 col-md-4')}
            <div class="col-12"><b class="small text-muted">Vitals</b></div>
            ${f('oHr', 'HR /min', nb('oHr', 0, 300))}${f('oSbp', 'BP systolic', nb('oSbp', 0, 300))}${f('oDbp', 'BP diastolic', nb('oDbp', 0, 200))}${f('oRr', 'Resp. rate', nb('oRr', 0, 80))}
            ${f('oSpo2', 'SpO2 %', nb('oSpo2', 0, 100, 0.1))}${f('oTemp', 'Temp °C', nb('oTemp', 25, 45, 0.1))}${f('oCvp', 'CVP', nb('oCvp', -10, 40))}${f('oEt', 'EtCO2', nb('oEt', 0, 150))}
            <div class="col-12"><b class="small text-muted">Neuro / metabolic</b></div>
            ${f('oE', 'GCS eyes 1-4', nb('oE', 1, 4))}${f('oV', 'GCS verbal 1-5', nb('oV', 1, 5))}${f('oM', 'GCS motor 1-6', nb('oM', 1, 6))}${f('oRass', 'RASS -5..+4', nb('oRass', -5, 4))}
            ${f('oPain', 'Pain 0-10', nb('oPain', 0, 10))}${f('oGlu', 'Glucose mg/dl', nb('oGlu', 0, 1500, 0.1))}
            <div class="col-12"><b class="small text-muted">Intake / output since the last entry (ml)</b></div>
            ${f('oIn', 'Intake', nb('oIn', 0, 10000))}${f('oUo', 'Urine', nb('oUo', 0, 10000))}${f('oOo', 'Other output', nb('oOo', 0, 10000))}
            <div class="col-12"><b class="small text-muted">Ventilator</b></div>
            ${f('oMode', 'Mode', '<input id="oMode" class="form-control form-control-sm" maxlength="30" list="oModes" /><datalist id="oModes"><option>VC-AC</option><option>PC-AC</option><option>SIMV</option><option>PSV</option><option>CPAP</option><option>BiPAP</option><option>HFNO</option></datalist>')}
            ${f('oFio2', 'FiO2 % 21-100', nb('oFio2', 21, 100))}${f('oPeep', 'PEEP', nb('oPeep', 0, 30, 0.5))}${f('oVt', 'Tidal vol. ml', nb('oVt', 0, 2000))}
            ${f('oSet', 'Set rate', nb('oSet', 0, 80))}${f('oPip', 'PIP', nb('oPip', 0, 80))}${f('oPs', 'Pressure support', nb('oPs', 0, 60))}
            ${f('oNotes', 'Notes', '<input id="oNotes" class="form-control form-control-sm" maxlength="500" />', 'col-12')}</div>`,
            '<button type="button" class="btn btn-primary" id="oSave"><i class="bi bi-check2 me-1"></i>Save</button>');
        $('oSave').onclick = async ev => {
            const body = { observedAt: v('oAt'), hr: n('oHr'), sbp: n('oSbp'), dbp: n('oDbp'), rr: n('oRr'), spO2: n('oSpo2'), tempC: n('oTemp'), cvp: n('oCvp'), etCo2: n('oEt'),
                gcsE: n('oE'), gcsV: n('oV'), gcsM: n('oM'), rass: n('oRass'), painScore: n('oPain'), glucose: n('oGlu'), intakeMl: n('oIn'), urineMl: n('oUo'), otherOutputMl: n('oOo'),
                ventMode: v('oMode') || null, fiO2: n('oFio2'), peep: n('oPeep'), tidalVolume: n('oVt'), setRate: n('oSet'), pip: n('oPip'), pressureSupport: n('oPs'), notes: v('oNotes') || null };
            if (!body.observedAt) return Ipd.error('Enter the time.');
            ev.target.disabled = true;
            const r = await Ipd.post(base + 'AddObservation?id=' + C.id, body);
            ev.target.disabled = false;
            if (!r.success) return Ipd.error(r.error);
            hide('icuObsModal'); Ipd.toast('Observation saved'); load();
        };
    }

    function infusion(kind, inf) {
        const start = kind === 'START';
        modal('icuInfModal', `<i class="bi bi-droplet me-1"></i>${start ? 'Start infusion' : kind === 'RATE' ? 'Change rate · ' + E(inf.Drug) : 'Stop infusion · ' + E(inf.Drug)}`, `<div class="row g-2">
            ${start ? f('iDrug', 'Drug / fluid *', '<input id="iDrug" class="form-control form-control-sm" maxlength="150" placeholder="e.g. Noradrenaline" />', 'col-md-6') + f('iConc', 'Concentration', '<input id="iConc" class="form-control form-control-sm" maxlength="100" placeholder="e.g. 4 mg in 50 ml NS" />', 'col-md-6') : ''}
            ${kind !== 'STOP' ? f('iRate', 'Rate ml/h *', nb('iRate', 0, 1000, 0.1)) + f('iDose', 'Dose', '<input id="iDose" class="form-control form-control-sm" maxlength="100" placeholder="e.g. 0.1 mcg/kg/min" />') : ''}
            ${start ? f('iRoute', 'Route', '<input id="iRoute" class="form-control form-control-sm" maxlength="30" value="IV (central)" />') : ''}
            ${f('iAt', 'Time *', `<input type="datetime-local" id="iAt" class="form-control form-control-sm" value="${Ipd.local(new Date())}" />`)}
            ${f('iRem', kind === 'STOP' ? 'Reason' : 'Remarks', '<input id="iRem" class="form-control form-control-sm" maxlength="300" />', 'col-12')}</div>`,
            `<button type="button" class="btn btn-primary" id="iSave">${start ? 'Start' : kind === 'RATE' ? 'Change rate' : 'Stop'}</button>`);
        if (inf && $('iRate')) { $('iRate').value = Number(inf.RateMlHr); $('iDose').value = inf.Dose || ''; }
        $('iSave').onclick = async ev => {
            const body = { infusionId: inf ? inf.InfusionId : null, eventType: kind, drug: v('iDrug') || null, concentration: v('iConc') || null, rateMlHr: n('iRate'),
                dose: v('iDose') || null, route: v('iRoute') || null, eventAt: v('iAt') || null, remarks: v('iRem') || null };
            ev.target.disabled = true;
            const r = await Ipd.post(base + 'Infusion?id=' + C.id, body);
            ev.target.disabled = false;
            if (!r.success) return Ipd.error(r.error);
            hide('icuInfModal'); Ipd.toast('Saved'); load();
        };
    }

    function device(stopId) {
        const heads = D.deviceHeads || [];
        modal('icuDevModal', `<i class="bi bi-cpu me-1"></i>${stopId ? 'Stop device' : 'Start device'}`, `<div class="row g-2">
            ${stopId ? '' : f('dHead', 'Device *', `<select id="dHead" class="form-select form-select-sm">${heads.map(x => `<option value="${E(x.Code)}" data-name="${E(x.Name)}">${E(x.Name)}${x.Rate ? ' · ' + Ipd.money(x.Rate) + ' ' + E(x.BillingFrequency || '') : ''}</option>`).join('')}</select>`, 'col-md-8')}
            ${f('dAt', 'Time *', `<input type="datetime-local" id="dAt" class="form-control form-control-sm" value="${Ipd.local(new Date())}" />`, 'col-md-4')}
            ${f('dRem', 'Remarks', '<input id="dRem" class="form-control form-control-sm" maxlength="300" />', 'col-12')}</div>`,
            `<button type="button" class="btn btn-primary" id="dSave">${stopId ? 'Stop' : 'Start'}</button>`);
        $('dSave').onclick = async ev => {
            const sel = $('dHead');
            const body = stopId ? { deviceId: stopId, at: v('dAt') || null, remarks: v('dRem') || null }
                : { headCode: sel.value, headName: sel.selectedOptions[0]?.dataset.name, at: v('dAt') || null, remarks: v('dRem') || null };
            ev.target.disabled = true;
            const r = await Ipd.post(base + 'Device?id=' + C.id, body);
            ev.target.disabled = false;
            if (!r.success) return Ipd.error(r.error);
            hide('icuDevModal'); Ipd.toast(stopId ? 'Device stopped' : 'Device started'); load();
        };
    }

    $('icuBody').addEventListener('click', async e => {
        const t = e.target.closest('button'); if (!t) return;
        if (t.id === 'icuAddObs') return addObservation();
        if (t.id === 'icuAddInf') return infusion('START');
        if (t.id === 'icuAddDev') return device(null);
        if (t.dataset.inf) { const [k, id] = t.dataset.inf.split(':'); return infusion(k, (D.infusions || []).find(i => i.InfusionId === Number(id))); }
        if (t.dataset.devstop) return device(Number(t.dataset.devstop));
        if (t.dataset.strike) {
            const [kind, id] = t.dataset.strike.split(':');
            const reason = await Ipd.reason('Strike out this entry?', 'Reason (the entry stays visible, struck through)'); if (reason == null) return;
            const r = await Ipd.post(base + 'Strike', { kind, id: Number(id), reason });
            if (!r.success) return Ipd.error(r.error);
            Ipd.toast('Struck out'); load();
        }
    });
    $('icuWindow').addEventListener('change', load);
    $('icuPrint').addEventListener('click', () => { const w = window_(); window.open(`${base}PrintChart?id=${C.id}&fromAt=${encodeURIComponent(w.fromAt)}&toAt=${encodeURIComponent(w.toAt)}`, '_blank'); });

    const tabBtn = document.querySelector('[data-tab="icu"]');
    tabBtn?.addEventListener('shown.bs.tab', () => { if (!loaded) { loaded = true; load(); } });
    if ($('tab-icu').classList.contains('active')) { loaded = true; load(); }
})();
