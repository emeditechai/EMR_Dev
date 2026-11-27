/* IPD Patient > Nursing (Phase 3, SQLScripts/2562-2565): eMAR, vitals with NEWS2, intake / output, nursing notes, nursing assessment and
   care plan, Morse / Braden risk, SBAR handover, incidents, and the doctor's instructions to acknowledge.
   Config window.IpdNurse = { id, base, open, can: { assess, chart, mar, handover, incident, done, correct } }.
   Entries are never edited: a wrong one is struck out with a reason (CLIN_CORRECT) and charted again. */
(function () {
    'use strict';
    const C = window.IpdNurse, U = window.IpdClinUi;
    if (!C || !U || !document.getElementById('tab-nursing')) return;
    const { E, $ } = U, base = C.base;
    let D = null, loaded = false, pane = 'mar', day = new Date(); day.setHours(0, 0, 0, 0);

    const st = () => (D.state || [])[0] || {};
    const canWrite = () => !!st().ClinicalOpen && C.open;
    const dayRange = () => { const f = new Date(day), t = new Date(day); t.setDate(t.getDate() + 1); t.setMinutes(t.getMinutes() - 1); return { f, t }; };

    async function load() {
        const { f, t } = dayRange();
        try { D = await Ipd.get(`${base}NursingData?id=${C.id}&fromAt=${encodeURIComponent(Ipd.local(f))}&toAt=${encodeURIComponent(Ipd.local(t))}`); render(); }
        catch (e) { $('nurBody').innerHTML = `<div class="alert alert-danger m-0">${E(e.message)}</div>`; }
    }

    function strip() {
        const s = st();
        const vDue = s.VitalsDueAt && new Date(s.VitalsDueAt) < new Date();
        const doses = D.doses || [], over = doses.filter(d => d.DoseStatus === 'OVERDUE').length, due = doses.filter(d => d.DoseStatus === 'DUE').length;
        const naSigned = s.NursingAssessStatus === 'SIGNED';
        return `<div class="clin-strip">
            <div><small>Last vitals</small><b>${s.LastVitalsAt ? U.news2Badge(s.LastNews2, s.LastNews2Risk) + ' <span class="small fw-normal text-muted">' + U.ago(s.LastVitalsAt) + '</span>' : '<span class="text-muted fw-normal">none yet</span>'}</b>
                <div class="small ${vDue ? 'text-danger' : 'text-muted'}">next ${U.dueText(s.VitalsDueAt)}</div></div>
            <div><small>Medicines today</small><b>${over ? `<span class="text-danger">${over} overdue</span>` : ''}${over && due ? ' · ' : ''}${due ? `<span class="text-warning-emphasis">${due} due now</span>` : ''}${!over && !due ? '<span class="text-muted fw-normal">nothing due now</span>' : ''}</b></div>
            <div><small>Nursing assessment</small><b>${naSigned ? '<span class="text-success"><i class="bi bi-check-circle-fill me-1"></i>Signed</span>' : `<span class="${new Date(s.NursingAssessDueAt) < new Date() ? 'text-danger' : 'text-warning-emphasis'}">${s.NursingAssessStatus === 'DRAFT' ? 'Draft' : 'Not done'} · ${U.dueText(s.NursingAssessDueAt)}</span>`}</b></div>
            <div><small>Fall · pressure ulcer</small><b>${U.riskBadge('MORSE', s.MorseRisk)} ${U.riskBadge('BRADEN', s.BradenRisk)}</b></div>
            <div><small>Diet · allergies</small><b>${E(s.CurrentDiet || 'No diet order')}</b><div class="small ${s.KnownAllergies ? 'text-danger' : 'text-muted'}">${E(s.KnownAllergies || 'No allergies recorded')}</div></div>
        </div>`;
    }

    function instructions() {
        const ins = D.instructions || [];
        if (!ins.length) return '';
        return `<div class="ipdx-card mb-3 clin-instr"><div class="fw-semibold small mb-1"><i class="bi bi-bell me-1"></i>Doctor's instructions</div>${ins.map(o => `<div class="d-flex justify-content-between align-items-center gap-2 py-1 border-top">
            <div class="small">${o.Priority !== 'ROUTINE' ? `<span class="badge ${o.Priority === 'STAT' ? 'text-bg-danger' : 'text-bg-warning'}">${o.Priority}</span> ` : ''}<b>${o.OrderType === 'DIET' ? E(o.DietType) : o.OrderType === 'SERVICE' ? E(o.ServiceName) + ' × ' + Number(o.Qty) : 'Instruction'}</b>
                ${o.Details ? ' · ' + E(o.Details) : ''} <span class="text-muted">· ${E(o.DoctorName)}, ${Ipd.dt(o.OrderedAt)}${o.Source !== 'DIRECT' ? ' · ' + o.Source.toLowerCase() : ''}</span></div>
            <div class="text-nowrap">${!o.AckAt && C.can.mar && canWrite() ? `<button type="button" class="btn btn-sm btn-outline-primary" data-ack="${o.OrderId}">Seen</button>` : o.AckAt ? '<span class="small text-success"><i class="bi bi-check2"></i> seen</span>' : ''}
                ${o.OrderType === 'SERVICE' && C.can.done && canWrite() ? ` <button type="button" class="btn btn-sm btn-success" data-done="${o.OrderId}">Done</button>` : ''}</div></div>`).join('')}</div>`;
    }

    function render() {
        const panes = [['mar', 'eMAR', 'bi-capsule'], ['vitals', 'Vitals · NEWS2', 'bi-heart-pulse'], ['io', 'Intake / Output', 'bi-droplet'], ['notes', 'Notes', 'bi-journal'],
            ['assess', 'Assessment & Care plan', 'bi-clipboard2-check'], ['risk', 'Fall / Pressure risk', 'bi-exclamation-triangle'], ['handover', 'Handover', 'bi-arrow-left-right'], ['incident', 'Incidents', 'bi-flag']];
        $('nurBody').innerHTML = strip() + instructions() + `<ul class="nav nav-pills clin-pills mb-3">${panes.map(([k, t, i]) =>
            `<li class="nav-item"><button type="button" class="nav-link ${pane === k ? 'active' : ''}" data-pane="${k}"><i class="bi ${i} me-1"></i>${t}</button></li>`).join('')}</ul><div id="nurPane"></div>`;
        ({ mar: renderMar, vitals: renderVitals, io: renderIo, notes: renderNotes, assess: renderAssess, risk: renderRisk, handover: renderHandover, incident: renderIncidents })[pane]();
    }

    const dayNav = () => `<div class="d-flex align-items-center gap-2 mb-2"><button type="button" class="btn btn-sm btn-outline-secondary" data-day="-1"><i class="bi bi-chevron-left"></i></button>
        <b>${day.toLocaleDateString('en-GB', { weekday: 'short', day: '2-digit', month: 'short', year: 'numeric' })}</b>
        <button type="button" class="btn btn-sm btn-outline-secondary" data-day="1"><i class="bi bi-chevron-right"></i></button>
        <button type="button" class="btn btn-sm btn-link" data-day="0">Today</button></div>`;

    // ── eMAR ───────────────────────────────────────────────────────────────────────────────────────────────────
    function renderMar() {
        const os = D.medOrders || [], doses = D.doses || [];
        let h = dayNav();
        if (!os.length) { $('nurPane').innerHTML = h + '<div class="ipd-soon py-4"><div class="small">No medicine orders on this day. The doctor writes them on the Clinical tab.</div></div>'; return; }
        h += `<div class="small text-muted mb-2">Click a dose to chart it. A dose more than ${st().LateMinutes} min from its time needs a reason; a high-alert medicine needs a second nurse.</div>
            <div class="ipdx-card"><div class="table-responsive"><table class="table table-sm align-middle mb-0 clin-mar"><thead><tr><th style="min-width:240px">Medicine</th><th>Doses</th></tr></thead><tbody>`;
        os.forEach(o => {
            const ds = doses.filter(d => d.OrderId === o.OrderId), prn = o.FrequencyKind === 'PRN';
            const chips = ds.map(d => {
                const cls = { GIVEN: 'd-given', HELD: 'd-held', REFUSED: 'd-refused', OVERDUE: 'd-over', DUE: 'd-due', UPCOMING: 'd-up' }[d.DoseStatus];
                const tm = d.DueAt ? U.time(d.DueAt) : 'SOS ' + U.time(d.GivenAt);
                const tip = d.MarId ? `${d.Outcome.toLowerCase()} ${Ipd.dt(d.GivenAt)} by ${d.RecordedByName}${d.Reason ? ' · ' + d.Reason : ''}${d.WitnessName ? ' · checked by ' + d.WitnessName : ''}` : d.DoseStatus.toLowerCase();
                return `<button type="button" class="clin-dose ${cls}" data-dose="${o.OrderId}|${d.DueAt || ''}|${d.MarId || ''}" title="${E(tip)}">${tm}${d.MarId ? ' <i class="bi ' + (d.Outcome === 'GIVEN' ? 'bi-check2' : 'bi-x') + '"></i>' : ''}</button>`;
            }).join('');
            h += `<tr class="${o.Status === 'ACTIVE' ? '' : 'text-muted'}"><td><b>${E(o.DrugName)}</b> ${E(o.Dose)} · ${E(o.Route)}${o.IsHighAlert ? ' <span class="badge text-bg-danger">high alert</span>' : ''}
                <div class="small text-muted">${E(o.FrequencyName)} · ${E(o.DoctorName)}${o.Source !== 'DIRECT' ? ` · <span class="${o.CountersignedAt ? '' : 'text-warning-emphasis'}">${o.Source.toLowerCase()}${o.CountersignedAt ? '' : ', not countersigned'}</span>` : ''}${o.Status !== 'ACTIVE' ? ' · ' + o.Status.toLowerCase() + (o.StopReason ? ': ' + E(o.StopReason) : '') : ''}${o.Instructions ? '<br>' + E(o.Instructions) : ''}</div></td>
                <td>${chips}${prn && o.Status === 'ACTIVE' && C.can.mar && canWrite() ? `<button type="button" class="btn btn-sm btn-outline-primary ms-1" data-sos="${o.OrderId}">Give SOS dose</button>` : ''}${!chips && !prn ? '<span class="small text-muted">no dose on this day</span>' : ''}</td></tr>`;
        });
        $('nurPane').innerHTML = h + '</tbody></table></div></div>';
    }

    function doseModal(orderId, dueAt, sos) {
        const o = D.medOrders.find(x => x.OrderId === orderId);
        const late = dueAt && Math.abs(Date.now() - new Date(dueAt)) / 60000 > st().LateMinutes;
        U.modal('nurDoseModal', `${E(o.DrugName)} ${E(o.Dose)} · ${E(o.Route)}`, `
            ${o.IsHighAlert ? '<div class="alert alert-danger py-2 small"><i class="bi bi-exclamation-triangle me-1"></i>High-alert medicine: a second nurse double-checks drug, dose, route and patient.</div>' : ''}
            <div class="small text-muted mb-2">${sos ? 'SOS / when-needed dose' : 'Dose of ' + Ipd.dt(dueAt)}${late ? ' · <span class="text-danger">outside the on-time window: write why</span>' : ''}</div>
            <div class="btn-group mb-2" role="group">${['GIVEN', 'HELD', 'REFUSED'].map((x, i) => `<input type="radio" class="btn-check" name="dOut" id="dOut${x}" value="${x}" ${i === 0 ? 'checked' : ''}><label class="btn btn-sm btn-outline-${x === 'GIVEN' ? 'success' : x === 'HELD' ? 'warning' : 'danger'}" for="dOut${x}">${x[0] + x.slice(1).toLowerCase()}</label>`).join('')}</div>
            <div class="row g-2">${U.field('dAt', 'Time', U.when('dAt'), 'col-6 col-md-4')}${U.field('dDose', 'Dose given', U.text('dDose', o.Dose), 'col-6 col-md-4')}
            ${U.field('dSite', 'Site (injection)', U.text('dSite', '', 'placeholder="e.g. left deltoid"'), 'col-12 col-md-4')}
            ${U.field('dWhy', sos ? 'Indication (why given)' : 'Reason (held / refused / late)', U.text('dWhy', '', 'maxlength="300"'), 'col-12', !!sos)}
            ${o.IsHighAlert ? U.field('dWit', 'Second nurse (double-check)', U.text('dWit'), 'col-12 col-md-6', true) : ''}</div>`,
            '<button type="button" class="btn btn-primary" id="dSave">Save</button>', '');
        $('dSave').addEventListener('click', async () => {
            const out = document.querySelector('input[name="dOut"]:checked').value;
            const r = await U.save(`${base}Mar?orderId=${orderId}`, { dueAt: dueAt || null, outcome: out, givenAt: U.v('dAt') || null, doseGiven: U.v('dDose'), site: U.v('dSite') || null,
                reason: U.v('dWhy') || null, witnessName: o.IsHighAlert ? U.v('dWit') || null : null }, 'Dose ' + out.toLowerCase());
            if (r) { U.hide('nurDoseModal'); load(); }
        });
    }

    // ── vitals ─────────────────────────────────────────────────────────────────────────────────────────────────
    function renderVitals() {
        const vs = D.vitals || [];
        let h = C.can.chart && canWrite() ? '<button type="button" class="btn btn-sm btn-primary mb-2" id="vNew"><i class="bi bi-plus-lg me-1"></i>Record vitals</button>' : '';
        if (!vs.length) { $('nurPane').innerHTML = h + '<div class="ipd-soon py-4"><div class="small">No vitals charted in the last days.</div></div>'; return; }
        h += `<div class="ipdx-card"><div class="table-responsive"><table class="table table-sm align-middle mb-0"><thead><tr><th>Time</th><th>NEWS2</th><th>RR</th><th>SpO2</th><th>O2</th><th>BP</th><th>Pulse</th><th>ACVPU</th><th>Temp</th><th>Pain</th><th>Sugar</th><th>By</th><th></th></tr></thead><tbody>`;
        vs.forEach(v => {
            const s = v.Status === 'STRUCK';
            h += `<tr class="${s ? 'clin-struck' : ''}" title="${s ? 'Struck out: ' + E(v.StruckReason) : E(v.Notes || '')}"><td class="text-nowrap small">${Ipd.dt(v.ObservedAt)}</td><td>${s ? '' : U.news2Badge(v.News2, v.News2Risk)}</td>
                <td>${v.Rr ?? ''}</td><td>${v.SpO2 != null ? Number(v.SpO2) : ''}</td><td class="small">${v.OnOxygen ? E(v.O2Device || 'O2') + (v.O2FlowLpm ? ' ' + Number(v.O2FlowLpm) + ' l' : '') : v.OnOxygen === false ? 'air' : ''}</td>
                <td>${v.Sbp != null ? v.Sbp + '/' + v.Dbp : ''}</td><td>${v.Pulse ?? ''}</td><td>${E(v.Consciousness || '')}</td><td>${v.TempC != null ? Number(v.TempC) : ''}</td><td>${v.PainScore ?? ''}</td><td>${v.Glucose != null ? Number(v.Glucose) : ''}</td>
                <td class="small">${E(v.RecordedByName)}</td><td>${!s && C.can.correct && canWrite() ? `<button type="button" class="btn btn-sm btn-link text-danger p-0" data-strike="VITAL:${v.VitalId}" title="Strike out">×</button>` : ''}</td></tr>`;
        });
        $('nurPane').innerHTML = h + '</tbody></table></div></div>';
    }
    function vitalsModal() {
        U.modal('nurVitModal', 'Record vitals', `<div class="row g-2">
            ${U.field('vAt', 'Time', U.when('vAt'), 'col-6 col-md-4')}
            ${U.field('vRr', 'Resp. rate /min', U.num('vRr', 0, 80), 'col-6 col-md-2')}${U.field('vSp', 'SpO2 %', U.num('vSp', 0, 100, 0.1), 'col-6 col-md-2')}
            ${U.field('vO2', 'Breathing', U.sel('vO2', [['0', 'Room air'], ['1', 'On oxygen']]), 'col-6 col-md-2')}${U.field('vFlow', 'O2 l/min', U.num('vFlow', 0, 60, 0.5), 'col-6 col-md-2')}
            ${U.field('vDev', 'O2 device', U.sel('vDev', ['Nasal cannula', 'Face mask', 'Venturi mask', 'Non-rebreather mask', 'High-flow nasal', 'NIV', 'Ventilator'], '', '--'), 'col-6 col-md-4')}
            ${U.field('vSbp', 'BP systolic', U.num('vSbp', 0, 300), 'col-6 col-md-2')}${U.field('vDbp', 'diastolic', U.num('vDbp', 0, 200), 'col-6 col-md-2')}
            ${U.field('vHr', 'Pulse /min', U.num('vHr', 0, 300), 'col-6 col-md-2')}
            ${U.field('vCon', 'Consciousness', U.sel('vCon', [['A', 'A · Alert'], ['C', 'C · New confusion'], ['V', 'V · Responds to voice'], ['P', 'P · Responds to pain'], ['U', 'U · Unresponsive']], 'A'), 'col-6 col-md-4')}
            ${U.field('vT', 'Temp °C', U.num('vT', 25, 45, 0.1), 'col-6 col-md-2')}${U.field('vPain', 'Pain 0-10', U.num('vPain', 0, 10), 'col-6 col-md-2')}
            ${U.field('vGlu', 'Blood sugar mg/dl', U.num('vGlu', 0, 1500, 0.1), 'col-6 col-md-2')}${U.field('vWt', 'Weight kg', U.num('vWt', 0.3, 400, 0.1), 'col-6 col-md-2')}
            ${U.field('vNote', 'Notes', U.text('vNote', '', 'maxlength="500"'), 'col-12')}</div>
            <div class="small text-muted mt-1">NEWS2 is worked out when RR, SpO2, breathing, BP, pulse, consciousness and temperature are all entered.</div>`,
            '<button type="button" class="btn btn-primary" id="vSave">Save</button>');
        $('vSave').addEventListener('click', async () => {
            const onO2 = U.v('vO2') === '1';
            const r = await U.save(`${base}Vital?id=${C.id}`, { observedAt: U.v('vAt') || null, rr: U.n('vRr'), spO2: U.n('vSp'), onOxygen: onO2, o2Device: onO2 ? U.v('vDev') || null : null,
                o2FlowLpm: onO2 ? U.n('vFlow') : null, sbp: U.n('vSbp'), dbp: U.n('vDbp'), pulse: U.n('vHr'), consciousness: U.v('vCon') || null, tempC: U.n('vT'),
                painScore: U.n('vPain'), glucose: U.n('vGlu'), weightKg: U.n('vWt'), notes: U.v('vNote') || null });
            if (!r) return;
            U.hide('nurVitModal');
            await Swal.fire({ icon: r.News2Risk === 'HIGH' || r.News2Risk === 'MEDIUM' ? 'warning' : r.News2Risk === 'LOW_MEDIUM' ? 'info' : 'success',
                title: r.News2 != null ? 'NEWS2 ' + r.News2 : 'Vitals saved', html: E(U.news2Advice(r.News2, r.News2Risk)) });
            load();
        });
    }

    // ── intake / output ────────────────────────────────────────────────────────────────────────────────────────
    const IN = [['ORAL', 'Oral'], ['IV', 'IV fluids'], ['RT_FEED', 'Ryle\'s tube feed'], ['BLOOD', 'Blood / products'], ['OTHER', 'Other']];
    const OUT = [['URINE', 'Urine'], ['DRAIN', 'Drain'], ['VOMIT', 'Vomit'], ['STOOL', 'Stool'], ['ASPIRATE', 'RT aspirate'], ['OTHER', 'Other']];
    function renderIo() {
        const rows = (D.io || []), act = rows.filter(r => r.Status === 'ACTIVE');
        const tin = act.filter(r => r.Direction.trim() === 'IN').reduce((a, r) => a + r.VolumeMl, 0), tout = act.filter(r => r.Direction.trim() === 'OUT').reduce((a, r) => a + r.VolumeMl, 0);
        let h = dayNav() + `<div class="clin-strip mb-2"><div><small>Intake</small><b>${tin} ml</b></div><div><small>Output</small><b>${tout} ml</b></div>
            <div><small>Balance</small><b class="${tin - tout < 0 ? 'text-danger' : 'text-success'}">${tin - tout > 0 ? '+' : ''}${tin - tout} ml</b></div></div>`;
        if (C.can.chart && canWrite()) h += `<div class="ipdx-card mb-2"><div class="row g-2 align-items-end">
            ${U.field('ioDir', 'Type', U.sel('ioDir', [['IN', 'Intake'], ['OUT', 'Output']]), 'col-6 col-md-2')}
            ${U.field('ioCat', 'What', U.sel('ioCat', IN), 'col-6 col-md-3')}${U.field('ioMl', 'ml', U.num('ioMl', 1, 10000), 'col-4 col-md-2')}
            ${U.field('ioAt', 'Time', U.when('ioAt'), 'col-8 col-md-3')}<div class="col-12 col-md-2"><button type="button" class="btn btn-sm btn-primary w-100" id="ioSave">Add</button></div></div></div>`;
        if (rows.length) {
            h += '<div class="ipdx-card"><table class="table table-sm align-middle mb-0"><thead><tr><th>Time</th><th>Type</th><th>What</th><th class="text-end">ml</th><th>By</th><th></th></tr></thead><tbody>';
            rows.forEach(r => {
                const s = r.Status === 'STRUCK', lbl = [...IN, ...OUT].find(x => x[0] === r.Category)?.[1] || r.Category;
                h += `<tr class="${s ? 'clin-struck' : ''}" title="${s ? 'Struck out: ' + E(r.StruckReason) : ''}"><td class="small">${Ipd.dt(r.At)}</td><td>${r.Direction.trim() === 'IN' ? 'Intake' : 'Output'}</td><td>${E(lbl)}</td><td class="text-end">${r.VolumeMl}</td>
                    <td class="small">${E(r.RecordedByName)}</td><td>${!s && C.can.correct && canWrite() ? `<button type="button" class="btn btn-sm btn-link text-danger p-0" data-strike="IO:${r.IoId}">×</button>` : ''}</td></tr>`;
            });
            h += '</tbody></table></div>';
        }
        $('nurPane').innerHTML = h;
        $('ioDir')?.addEventListener('change', () => { $('ioCat').innerHTML = (U.v('ioDir') === 'IN' ? IN : OUT).map(([k, t]) => `<option value="${k}">${t}</option>`).join(''); });
    }

    // ── nursing notes ──────────────────────────────────────────────────────────────────────────────────────────
    function renderNotes() {
        const ns = D.notes || [];
        let h = C.can.chart && canWrite() ? `<div class="ipdx-card mb-2">${U.area('nnText', '', 2, 2000)}<div class="d-flex gap-2 mt-2 align-items-center">
            ${U.sel('nnShift', [['', 'Shift (auto)'], ['MORNING', 'Morning'], ['EVENING', 'Evening'], ['NIGHT', 'Night']])}<button type="button" class="btn btn-sm btn-primary" id="nnSave">Add note</button></div></div>` : '';
        ns.forEach(n => {
            const s = n.Status === 'STRUCK';
            h += `<div class="ipdx-card mb-2 ${s ? 'clin-struck' : ''}"><div class="small text-muted d-flex justify-content-between"><span>${Ipd.dt(n.NoteAt)} · ${E((n.Shift || '').toLowerCase())} shift · ${E(n.RecordedByName)}</span>
                ${!s && C.can.correct && canWrite() ? `<button type="button" class="btn btn-sm btn-link text-danger p-0" data-strike="NNOTE:${n.NoteId}">Strike out</button>` : ''}</div>
                <div style="white-space:pre-wrap">${E(n.Note)}</div>${s ? `<div class="small text-danger">Struck out: ${E(n.StruckReason)}</div>` : ''}</div>`;
        });
        if (!ns.length && !h) h = '<div class="ipd-soon py-4"><div class="small">No nursing notes.</div></div>';
        $('nurPane').innerHTML = h;
    }

    // ── nursing assessment and care plan ─────────────────────────────────────────────────────────────────────────
    const NF = [['generalCondition', 'General condition', ['Good', 'Fair', 'Poor', 'Critical'], 1], ['consciousness', 'Consciousness', ['Alert', 'Drowsy', 'Confused', 'Unconscious'], 1],
        ['allergies', 'Allergies', null, 1], ['mobility', 'Mobility', ['Independent', 'Needs help', 'Bed-bound'], 1], ['skin', 'Skin condition', ['Intact', 'Pressure area red', 'Wound / ulcer', 'Rash'], 1],
        ['diet', 'Diet / appetite', null], ['elimination', 'Bladder / bowel', null], ['pain', 'Pain (0-10, site)', null], ['lines', 'Lines / tubes / drains', null],
        ['psychosocial', 'Psycho-social / religious needs', null], ['education', 'Education needs (patient / family)', null], ['notes', 'Other observations', null]];
    function renderAssess() {
        // the nursing assessment is read with the Clinical tab's data
        Ipd.get(`${C.clinBase}Data?id=${C.id}`).then(cd => {
            const all = (cd.assessments || []).filter(a => a.Kind === 'NURSING'), a = all.find(x => x.Status !== 'SUPERSEDED');
            const data = a ? JSON.parse(a.Data || '{}') : {}, signed = a && a.Status === 'SIGNED', w = C.can.assess && canWrite();
            let h = '';
            if (signed) h += `<div class="ipdx-card mb-3"><div class="d-flex justify-content-between mb-2"><div><span class="badge text-bg-success">signed</span> <span class="small text-muted">${Ipd.dt(a.SignedAt)} by ${E(a.SignedByName)} · version ${a.Version}</span></div>
                ${w ? '<button type="button" class="btn btn-sm btn-outline-primary" id="naAmend">Amend</button>' : ''}</div><dl class="row small mb-0">${NF.filter(f => data[f[0]]).map(f => `<dt class="col-md-3">${f[1]}</dt><dd class="col-md-9">${E(data[f[0]])}</dd>`).join('')}</dl></div>`;
            else h += nurForm(data, w, a);
            $('nurPane').innerHTML = `<h6 class="fw-bold">Nursing initial assessment</h6>` + h + carePlan();
            if (signed) $('naAmend')?.addEventListener('click', () => { const box = document.createElement('div'); box.innerHTML = nurForm(data, true, null, true); $('nurPane').querySelector('.ipdx-card').replaceWith(box); });
        }).catch(e => { $('nurPane').innerHTML = `<div class="alert alert-danger">${E(e.message)}</div>`; });
    }
    function nurForm(data, w, a, amend) {
        return `<div class="ipdx-card mb-3"><div class="row g-2">${NF.map(([k, t, opts, req]) => U.field('na_' + k, t, opts ? U.sel('na_' + k, opts, data[k] || '', '--') : U.text('na_' + k, data[k] || (k === 'allergies' ? (st().KnownAllergies || '') : '')), 'col-12 col-md-4', !!req)).join('')}
            ${amend ? U.field('naReason', 'Reason for the amendment', U.text('naReason'), 'col-12', true) : ''}</div>
            ${w ? `<div class="d-flex gap-2 mt-2"><button type="button" class="btn btn-sm btn-outline-primary" data-nasave="0">Save draft</button><button type="button" class="btn btn-sm btn-success" data-nasave="1"><i class="bi bi-pen me-1"></i>Sign</button></div>` : ''}
            ${a && a.Status === 'DRAFT' ? `<div class="small text-muted mt-1">Draft saved ${Ipd.dt(a.ModifiedDate || a.CreatedDate)}</div>` : ''}</div>`;
    }
    const PROBLEMS = ['Risk of falls', 'Risk of pressure ulcer', 'Acute pain', 'Risk of infection', 'Impaired mobility', 'Fluid volume deficit', 'Impaired breathing',
        'Imbalanced nutrition', 'Anxiety', 'Knowledge deficit (disease / medicines)', 'Self-care deficit', 'Impaired skin integrity'];
    function carePlan() {
        const ps = D.plans || [], w = C.can.assess && canWrite();
        let h = `<h6 class="fw-bold mt-3">Care plan</h6>`;
        if (w) h += `<div class="ipdx-card mb-2"><div class="row g-2">
            <div class="col-12 col-md-4"><label class="form-label small fw-semibold mb-1" for="cpProb">Problem *</label><input id="cpProb" class="form-control form-control-sm" list="cpProbList" maxlength="300" />
                <datalist id="cpProbList">${PROBLEMS.map(p => `<option value="${E(p)}">`).join('')}</datalist></div>
            ${U.field('cpGoal', 'Goal', U.text('cpGoal', '', 'maxlength="500"'), 'col-12 col-md-4', true)}${U.field('cpInt', 'Interventions', U.text('cpInt', '', 'maxlength="1000"'), 'col-12 col-md-4', true)}</div>
            <button type="button" class="btn btn-sm btn-primary mt-2" id="cpSave">Add to care plan</button></div>`;
        if (!ps.length) return h + '<div class="small text-muted">No care plan problems yet.</div>';
        return h + `<div class="ipdx-card"><table class="table table-sm align-middle mb-0"><thead><tr><th>Problem</th><th>Goal</th><th>Interventions</th><th>Status</th><th></th></tr></thead><tbody>${ps.map(p => `<tr>
            <td><b>${E(p.Problem)}</b><div class="small text-muted">${Ipd.dt(p.CreatedDate)} · ${E(p.CreatedByName)}</div></td><td class="small">${E(p.Goal)}</td><td class="small">${E(p.Interventions)}</td>
            <td class="small">${p.Status === 'ACTIVE' ? '<span class="badge text-bg-primary">active</span>' : `<span class="badge text-bg-success">resolved</span><div>${E(p.Evaluation || '')}</div>`}</td>
            <td class="text-end text-nowrap">${p.Status === 'ACTIVE' && w ? `<button type="button" class="btn btn-sm btn-outline-success" data-resolve="${p.PlanId}">Evaluate &amp; close</button>` : ''}
                ${p.Status === 'ACTIVE' && C.can.correct && canWrite() ? `<button type="button" class="btn btn-sm btn-link text-danger p-0 ms-1" data-strike="PLAN:${p.PlanId}">×</button>` : ''}</td></tr>`).join('')}</tbody></table></div>`;
    }

    // ── risk scores ────────────────────────────────────────────────────────────────────────────────────────────
    const MORSE = [['history', 'History of falling (last 3 months)', [[0, 'No'], [25, 'Yes']]], ['secondary', 'Secondary diagnosis', [[0, 'No'], [15, 'Yes']]],
        ['aid', 'Ambulatory aid', [[0, 'None / bed rest / nurse assist'], [15, 'Crutches / cane / walker'], [30, 'Furniture']]], ['iv', 'IV / heparin lock', [[0, 'No'], [20, 'Yes']]],
        ['gait', 'Gait', [[0, 'Normal / bed rest / wheelchair'], [10, 'Weak'], [20, 'Impaired']]], ['mental', 'Mental status', [[0, 'Oriented to own ability'], [15, 'Forgets limitations']]]];
    const BRADEN = [['sensory', 'Sensory perception', [[1, 'Completely limited'], [2, 'Very limited'], [3, 'Slightly limited'], [4, 'No impairment']]],
        ['moisture', 'Moisture', [[1, 'Constantly moist'], [2, 'Very moist'], [3, 'Occasionally moist'], [4, 'Rarely moist']]],
        ['activity', 'Activity', [[1, 'Bedfast'], [2, 'Chairfast'], [3, 'Walks occasionally'], [4, 'Walks frequently']]],
        ['mobility', 'Mobility', [[1, 'Completely immobile'], [2, 'Very limited'], [3, 'Slightly limited'], [4, 'No limitation']]],
        ['nutrition', 'Nutrition', [[1, 'Very poor'], [2, 'Probably inadequate'], [3, 'Adequate'], [4, 'Excellent']]],
        ['friction', 'Friction and shear', [[1, 'Problem'], [2, 'Potential problem'], [3, 'No apparent problem']]]];
    function renderRisk() {
        const rs = D.risks || [], s = st(), w = C.can.chart && canWrite();
        const card = (kind, title, score, level, at, hint) => `<div class="col-12 col-md-6"><div class="ipdx-card h-100"><div class="d-flex justify-content-between"><b>${title}</b>
            ${w ? `<button type="button" class="btn btn-sm btn-primary" data-risk="${kind}">Assess</button>` : ''}</div>
            <div class="mt-2">${score != null ? `<span class="fs-4 fw-bold me-2">${score}</span>${U.riskBadge(kind, level)} <span class="small text-muted">${U.ago(at)}</span>` : '<span class="text-muted">Not assessed yet</span>'}</div><div class="small text-muted mt-1">${hint}</div></div></div>`;
        let h = `<div class="row g-2 mb-3">${card('MORSE', 'Morse fall scale', s.MorseScore, s.MorseRisk, s.MorseAt, '0-24 low · 25-44 moderate · 45+ high. Reassess daily and after a fall or a change.')}
            ${card('BRADEN', 'Braden scale (pressure ulcer)', s.BradenScore, s.BradenRisk, s.BradenAt, '19+ no risk · 15-18 mild · 13-14 moderate · 10-12 high · 9 or less very high.')}</div>`;
        if (rs.length) h += `<div class="ipdx-card"><table class="table table-sm mb-0"><thead><tr><th>Time</th><th>Scale</th><th>Score</th><th>Risk</th><th>Interventions</th><th>By</th><th></th></tr></thead><tbody>${rs.map(r => {
            const x = r.Status === 'STRUCK';
            return `<tr class="${x ? 'clin-struck' : ''}"><td class="small">${Ipd.dt(r.AssessedAt)}</td><td>${r.Kind === 'MORSE' ? 'Morse' : 'Braden'}</td><td>${r.Score}</td><td>${U.riskBadge(r.Kind, r.RiskLevel)}</td>
                <td class="small">${E(r.Interventions || '')}</td><td class="small">${E(r.RecordedByName)}</td><td>${!x && C.can.correct && canWrite() ? `<button type="button" class="btn btn-sm btn-link text-danger p-0" data-strike="RISK:${r.RiskId}">×</button>` : ''}</td></tr>`;
        }).join('')}</tbody></table></div>`;
        $('nurPane').innerHTML = h;
    }
    function riskModal(kind) {
        const items = kind === 'MORSE' ? MORSE : BRADEN;
        U.modal('nurRiskModal', kind === 'MORSE' ? 'Morse fall scale' : 'Braden scale', items.map(([k, t, opts]) => `<div class="mb-2"><div class="small fw-semibold">${t}</div>
            <div class="d-flex flex-wrap gap-1">${opts.map(([p, l]) => `<input type="radio" class="btn-check" name="rk_${k}" id="rk_${k}_${p}" value="${p}"><label class="btn btn-sm btn-outline-secondary" for="rk_${k}_${p}">${l} <span class="badge text-bg-light">${p}</span></label>`).join('')}</div></div>`).join('')
            + `<div class="mt-2">Score: <b id="rkScore">—</b> <span id="rkLevel"></span></div>${U.field('rkInt', 'Interventions in place', U.text('rkInt', '', 'placeholder="e.g. bed rails up, call bell, non-slip footwear / 2-hourly turning, air mattress"'), 'col-12')}`,
            '<button type="button" class="btn btn-primary" id="rkSave">Save</button>');
        const read = () => { const a = {}; let all = true; items.forEach(([k]) => { const c = document.querySelector(`input[name="rk_${k}"]:checked`); if (c) a[k] = Number(c.value); else all = false; }); return { a, all }; };
        $('nurRiskModal').addEventListener('change', () => {
            const { a, all } = read(), sc = Object.values(a).reduce((x, y) => x + y, 0);
            $('rkScore').textContent = all ? sc : '—';
            $('rkLevel').innerHTML = !all ? '' : kind === 'MORSE' ? U.riskBadge(kind, sc >= 45 ? 'HIGH' : sc >= 25 ? 'MODERATE' : 'LOW')
                : U.riskBadge(kind, sc <= 9 ? 'VERY_HIGH' : sc <= 12 ? 'HIGH' : sc <= 14 ? 'MODERATE' : sc <= 18 ? 'MILD' : 'NONE');
        });
        $('rkSave').addEventListener('click', async () => {
            const { a, all } = read();
            if (!all) { Ipd.error('Answer every item.'); return; }
            const r = await U.save(`${base}Risk?id=${C.id}`, { kind, answers: JSON.stringify(a), interventions: U.v('rkInt') || null });
            if (r) { U.hide('nurRiskModal'); Ipd.toast(`${kind === 'MORSE' ? 'Morse' : 'Braden'} ${r.Score} · ${String(r.RiskLevel).replace('_', ' ').toLowerCase()} risk`); load(); }
        });
    }

    // ── SBAR handover ──────────────────────────────────────────────────────────────────────────────────────────
    function renderHandover() {
        const hs = D.handovers || [], w = C.can.handover && canWrite();
        let h = w ? '<button type="button" class="btn btn-sm btn-primary mb-2" id="hoNew"><i class="bi bi-plus-lg me-1"></i>Hand over (SBAR)</button>' : '';
        if (!hs.length) { $('nurPane').innerHTML = h + '<div class="ipd-soon py-4"><div class="small">No handovers yet.</div></div>'; return; }
        hs.forEach(x => {
            h += `<div class="ipdx-card mb-2"><div class="d-flex justify-content-between flex-wrap"><div class="small"><b>${E(x.Shift.toLowerCase())} shift</b> · ${Ipd.dt(x.HandoverAt)} · by ${E(x.GivenByName)}</div>
                <div class="small">${x.ReceivedAt ? `<span class="text-success"><i class="bi bi-check2"></i> taken over by ${E(x.ReceivedByName)} ${Ipd.dt(x.ReceivedAt)}</span>` : w ? `<button type="button" class="btn btn-sm btn-success" data-receive="${x.HandoverId}">Take over</button>` : '<span class="text-warning-emphasis">not taken over</span>'}</div></div>
                <div class="clin-soap">${[['S', x.Situation], ['B', x.Background], ['A', x.AssessmentText], ['R', x.Recommendation]].filter(y => y[1]).map(([k, t]) => `<div><b>${k}</b><span>${E(t)}</span></div>`).join('')}</div></div>`;
        });
        $('nurPane').innerHTML = h;
    }
    function handoverModal() {
        const s = st();
        U.modal('nurHoModal', 'Shift handover (SBAR)', `<div class="row g-2">
            ${U.field('hoShift', 'Shift handing over', U.sel('hoShift', [['', 'Current shift'], ['MORNING', 'Morning'], ['EVENING', 'Evening'], ['NIGHT', 'Night']]), 'col-12 col-md-4')}
            ${U.field('hoS', 'S · Situation (what is happening now)', U.area('hoS', '', 2, 1000), 'col-12', true)}
            ${U.field('hoB', 'B · Background (diagnosis, history, treatment)', U.area('hoB', '', 2, 1000), 'col-12')}
            ${U.field('hoA', 'A · Assessment (vitals, NEWS2, concerns)', U.area('hoA', s.LastVitalsAt ? `NEWS2 ${s.LastNews2 ?? '—'} (${U.ago(s.LastVitalsAt)})` : '', 2, 1000), 'col-12', true)}
            ${U.field('hoR', 'R · Recommendation (what the next shift must do)', U.area('hoR', '', 2, 1000), 'col-12', true)}</div>`,
            '<button type="button" class="btn btn-primary" id="hoSave">Save handover</button>');
        $('hoSave').addEventListener('click', async () => {
            if (await U.save(`${base}Handover?id=${C.id}`, { shift: U.v('hoShift') || null, situation: U.v('hoS'), background: U.v('hoB') || null, assessmentText: U.v('hoA'), recommendation: U.v('hoR') }, 'Handover saved')) { U.hide('nurHoModal'); load(); }
        });
    }

    // ── incidents ──────────────────────────────────────────────────────────────────────────────────────────────
    const ITYPES = [['FALL', 'Patient fall'], ['MEDICATION', 'Medication error'], ['PRESSURE_INJURY', 'Pressure injury'], ['NEEDLE_STICK', 'Needle-stick injury'], ['IV_SITE', 'IV site (phlebitis / extravasation)'],
        ['EQUIPMENT', 'Equipment failure'], ['BEHAVIOUR', 'Violent / absconding behaviour'], ['OTHER', 'Other']];
    const SEV = [['NEAR_MISS', 'Near miss'], ['NO_HARM', 'No harm'], ['MILD', 'Mild harm'], ['MODERATE', 'Moderate harm'], ['SEVERE', 'Severe harm'], ['DEATH', 'Death']];
    function renderIncidents() {
        const is = D.incidents || [], w = C.can.incident;
        let h = w && canWrite() ? '<button type="button" class="btn btn-sm btn-danger mb-2" id="incNew"><i class="bi bi-flag me-1"></i>Report an incident</button>' : '';
        if (!is.length) { $('nurPane').innerHTML = h + '<div class="ipd-soon py-4"><div class="small">No incidents reported.</div></div>'; return; }
        h += `<div class="ipdx-card"><table class="table table-sm align-middle mb-0"><thead><tr><th>When</th><th>Type</th><th>Severity</th><th>What happened</th><th>Status</th><th></th></tr></thead><tbody>${is.map(i => `<tr>
            <td class="small">${Ipd.dt(i.OccurredAt)}<div class="text-muted">${E(i.ReportedByName)}</div></td><td>${E(ITYPES.find(x => x[0] === i.IncidentType)?.[1] || i.IncidentType)}</td>
            <td><span class="badge ${['SEVERE', 'DEATH', 'MODERATE'].includes(i.Severity) ? 'text-bg-danger' : 'text-bg-warning'}">${E(SEV.find(x => x[0] === i.Severity)?.[1])}</span></td>
            <td class="small">${E(i.Description)}${i.ImmediateAction ? '<div class="text-muted">Action: ' + E(i.ImmediateAction) + '</div>' : ''}</td>
            <td class="small">${i.Status === 'OPEN' ? '<span class="badge text-bg-warning">open</span>' : `<span class="badge text-bg-success">closed</span><div>${E(i.Closure || '')}</div>`}</td>
            <td>${i.Status === 'OPEN' && w ? `<button type="button" class="btn btn-sm btn-outline-success" data-incclose="${i.IncidentId}">Close</button>` : ''}</td></tr>`).join('')}</tbody></table></div>`;
        $('nurPane').innerHTML = h;
    }
    function incidentModal() {
        U.modal('nurIncModal', 'Report an incident', `<div class="row g-2">
            ${U.field('inType', 'Type', U.sel('inType', ITYPES, '', '-- choose --'), 'col-12 col-md-6', true)}${U.field('inSev', 'Severity', U.sel('inSev', SEV, '', '-- choose --'), 'col-12 col-md-6', true)}
            ${U.field('inAt', 'When it happened', U.when('inAt'), 'col-12 col-md-6', true)}${U.field('inLoc', 'Where', U.text('inLoc', '', 'placeholder="e.g. bedside, bathroom"'), 'col-12 col-md-6')}
            ${U.field('inDesc', 'What happened', U.area('inDesc', '', 3, 2000), 'col-12', true)}
            ${U.field('inAct', 'Immediate action taken', U.area('inAct', '', 2, 1000), 'col-12')}
            <div class="col-12"><div class="form-check"><input class="form-check-input" type="checkbox" id="inDoc" /><label class="form-check-label small" for="inDoc">Doctor informed</label></div></div></div>`,
            '<button type="button" class="btn btn-danger" id="inSave">Report</button>');
        $('inSave').addEventListener('click', async () => {
            if (await U.save(`${base}Incident?id=${C.id}`, { incidentType: U.v('inType'), severity: U.v('inSev'), occurredAt: U.v('inAt') || null, location: U.v('inLoc') || null,
                description: U.v('inDesc'), immediateAction: U.v('inAct') || null, doctorInformed: U.chk('inDoc') }, 'Incident reported')) { U.hide('nurIncModal'); load(); }
        });
    }

    // ── events ─────────────────────────────────────────────────────────────────────────────────────────────────
    document.getElementById('tab-nursing').addEventListener('click', async e => {
        const t = e.target.closest('button'); if (!t) return;
        if (t.dataset.pane) { pane = t.dataset.pane; render(); return; }
        if (t.dataset.day != null) { const d = Number(t.dataset.day); if (d === 0) { day = new Date(); day.setHours(0, 0, 0, 0); } else day.setDate(day.getDate() + d); load(); return; }
        if (t.dataset.dose) {
            const [oid, due, mar] = t.dataset.dose.split('|');
            if (mar) { if (C.can.correct && canWrite()) U.strike(base, 'MAR', Number(mar), load); return; }
            if (!C.can.mar || !canWrite()) return;
            const d = (D.doses || []).find(x => x.OrderId === Number(oid) && x.DueAt && new Date(x.DueAt).getTime() === new Date(due).getTime());
            if (d && d.DoseStatus === 'UPCOMING') { Ipd.toast('This dose is not due yet', 'info'); return; }
            doseModal(Number(oid), due);
            return;
        }
        if (t.dataset.sos) { doseModal(Number(t.dataset.sos), null, true); return; }
        if (t.dataset.ack) { if (await U.save(`${C.clinBase}AckOrder`, { orderId: Number(t.dataset.ack) }, 'Marked as seen')) load(); return; }
        if (t.dataset.done) {
            if (!(await Ipd.confirm('Mark this service done?', 'It is charged to the patient\'s bill.', 'Done'))) return;
            if (await U.save(`${C.clinBase}OrderDone`, { orderId: Number(t.dataset.done) }, 'Done and charged')) load();
            return;
        }
        if (t.dataset.strike) { const [k, id] = t.dataset.strike.split(':'); U.strike(C.clinBase, k, Number(id), load); return; }
        if (t.id === 'vNew') { vitalsModal(); return; }
        if (t.id === 'ioSave') {
            if (await U.save(`${base}IntakeOutput?id=${C.id}`, { direction: U.v('ioDir'), category: U.v('ioCat'), volumeMl: U.n('ioMl'), at: U.v('ioAt') || null }, 'Saved')) load();
            return;
        }
        if (t.id === 'nnSave') { if (await U.save(`${base}NursingNote?id=${C.id}`, { note: U.v('nnText'), shift: U.v('nnShift') || null }, 'Note added')) load(); return; }
        if (t.dataset.nasave != null) {
            const data = {}; NF.forEach(([k]) => { const x = U.v('na_' + k); if (x) data[k] = x; });
            if (await U.save(`${base}SaveNursingAssessment?id=${C.id}`, { data: JSON.stringify(data), sign: t.dataset.nasave === '1', amendReason: $('naReason') ? U.v('naReason') : null },
                t.dataset.nasave === '1' ? 'Nursing assessment signed' : 'Draft saved')) load();
            return;
        }
        if (t.id === 'cpSave') { if (await U.save(`${base}CarePlan?id=${C.id}`, { problem: U.v('cpProb'), goal: U.v('cpGoal'), interventions: U.v('cpInt') }, 'Added to the care plan')) load(); return; }
        if (t.dataset.resolve) {
            const ev = await Ipd.reason('Evaluate and close', 'Evaluation (goal met / not met and why)'); if (!ev) return;
            if (await U.save(`${base}CarePlan?id=${C.id}`, { planId: Number(t.dataset.resolve), resolve: true, evaluation: ev }, 'Closed')) load();
            return;
        }
        if (t.dataset.risk) { riskModal(t.dataset.risk); return; }
        if (t.id === 'hoNew') { handoverModal(); return; }
        if (t.dataset.receive) { if (await U.save(`${base}Handover?id=${C.id}`, { handoverId: Number(t.dataset.receive), receive: true }, 'Handover taken over')) load(); return; }
        if (t.id === 'incNew') { incidentModal(); return; }
        if (t.dataset.incclose) {
            const cl = await Ipd.reason('Close the incident', 'Closure (root cause and corrective / preventive action)'); if (!cl) return;
            if (await U.save(`${base}Incident?id=${C.id}`, { incidentId: Number(t.dataset.incclose), close: true, closure: cl }, 'Incident closed')) load();
        }
    });

    const btn = document.querySelector('[data-bs-target="#tab-nursing"]');
    btn?.addEventListener('shown.bs.tab', () => { if (!loaded) { loaded = true; load(); } });
    if (document.getElementById('tab-nursing').classList.contains('active')) { loaded = true; load(); }
})();
