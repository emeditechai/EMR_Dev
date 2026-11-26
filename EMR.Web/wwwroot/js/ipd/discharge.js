/* IPD Patient > Discharge (Phase 7, SQLScripts/2557). Config window.IpdDis = { id, base, admBase, attendants, can: {...} }.
   Flow: advice -> clearances (pharmacy, LAB, nursing, TPA) -> final bill (Billing tab) -> settlement -> summary signed -> gate pass
   (bed released to housekeeping) -> OPD follow-up; LAMA / DAMA form and death record by type. Every rule is checked again in the
   procedures. Page URLs (prints, OPD booking) come from the server, encrypted. */
(function () {
    'use strict';
    const C = window.IpdDis; if (!C || !document.getElementById('tab-discharge')) return;
    const E = v => Ipd.esc(v), $ = id => document.getElementById(id), base = C.base;
    const TYPE = { NORMAL: 'Normal discharge', LAMA: 'LAMA (left against medical advice)', DAMA: 'DAMA (discharge against medical advice)', ABSCONDED: 'Absconded', TRANSFER: 'Transfer to another hospital', DEATH: 'Death' };
    const COND = { STABLE: 'Stable', IMPROVED: 'Improved', UNCHANGED: 'Unchanged', DETERIORATED: 'Deteriorated', CRITICAL: 'Critical', EXPIRED: 'Expired' };
    const DEPT = { PHARMACY: ['Pharmacy', 'bi-capsule'], LAB: ['LAB / Radiology', 'bi-droplet-half'], NURSING: ['Nursing', 'bi-clipboard2-pulse'], TPA: ['TPA / Insurance', 'bi-shield-plus'] };
    const CHECK = {
        PHARMACY: [['RETURNS', 'Unused medicines and consumables returned to pharmacy'], ['WARD_STOCK', 'Ward stock of the patient reconciled'], ['INDENTS', 'No indent left open'], ['DISCHARGE_MEDS', 'Discharge medicines (TTO) dispensed or prescribed']],
        LAB: [['SAMPLES', 'No test waiting for a sample'], ['REPORTS', 'Reports given, or how pending reports will reach the patient noted'], ['FILMS', 'Imaging films / CDs handed over']],
        NURSING: [['IV', 'IV cannula removed, site checked'], ['LINES', 'Catheter / drains / lines removed (or care explained)'], ['VITALS', 'Vitals recorded at discharge'], ['MEDS', 'Discharge medicines and dosing explained'],
                  ['EDU', 'Discharge education given (diet, wound care, warning signs)'], ['BELONGINGS', 'Belongings and valuables returned'], ['DOCS', 'Reports, films and documents handed over'], ['WRISTBAND', 'Identification band removed at exit']],
        TPA: [['FINAL_AUTH', 'Final authorisation received from the TPA'], ['DOCS', 'Claim documents signed by the patient'], ['QUERY', 'No TPA query open']]
    };
    const LAMA_RISKS = 'The doctor has explained that the treatment is not complete and that leaving now may lead to worsening of the illness, complications, permanent disability or death. The patient / attendant understands these risks, takes full responsibility for the decision and will not hold the hospital, its doctors or staff responsible. The patient may return at any time and is advised to continue treatment elsewhere without delay.';
    let D = null, doctors = [];

    // ── helpers ────────────────────────────────────────────────────────────────────────────────────────────────
    function modal(id, title, body, footer, size = 'modal-lg') {
        let m = $(id);
        if (!m) { m = document.createElement('div'); m.className = 'modal fade'; m.id = id; m.tabIndex = -1; document.body.appendChild(m); }
        m.innerHTML = `<div class="modal-dialog ${size} modal-dialog-scrollable"><div class="modal-content">
            <div class="modal-header"><h6 class="modal-title fw-bold">${title}</h6><button type="button" class="btn-close" data-bs-dismiss="modal" aria-label="Close"></button></div>
            <div class="modal-body">${body}</div><div class="modal-footer"><button type="button" class="btn btn-outline-secondary" data-bs-dismiss="modal">Close</button>${footer || ''}</div></div></div>`;
        bootstrap.Modal.getOrCreateInstance(m).show();
        return m;
    }
    const hide = id => bootstrap.Modal.getInstance($(id))?.hide();
    const v = id => { const el = $(id); return el ? el.value.trim() : ''; };
    const chk = id => !!$(id)?.checked;
    const field = (id, label, input, col = 'col-md-4') => `<div class="${col}"><label class="form-label small fw-semibold" for="${id}">${label}</label>${input}</div>`;
    const txt = (id, val, max = 300, ph = '') => `<input id="${id}" class="form-control form-control-sm" maxlength="${max}" value="${E(val ?? '')}" placeholder="${E(ph)}" />`;
    const area = (id, val, rows = 3) => `<textarea id="${id}" class="form-control form-control-sm" rows="${rows}">${E(val ?? '')}</textarea>`;
    const sel = (id, opts, val, blank = 'Choose…') => `<select id="${id}" class="form-select form-select-sm">${blank ? `<option value="">${blank}</option>` : ''}${opts.map(([k, t]) => `<option value="${E(k)}" ${String(k) === String(val ?? '') ? 'selected' : ''}>${E(t)}</option>`).join('')}</select>`;
    const docOpts = () => doctors.map(d => [d.DoctorId, d.DoctorName]);
    const hm = m => m == null ? '—' : (m >= 60 ? Math.floor(m / 60) + ' h ' + (m % 60) + ' m' : m + ' m');
    const one = rows => (rows || [])[0] || null;
    async function post(action, body, okMsg) {
        try { const r = await Ipd.post(base + action + '?id=' + C.id, body); Ipd.toast(okMsg); await load(); return r || true; }
        catch (e) { Ipd.error(e.message); return null; }
    }
    const goTab = key => document.querySelector(`[data-bs-target="#tab-${key}"]`)?.click();

    async function load() {
        try { D = await Ipd.get(base + 'Data?id=' + C.id); doctors = D.doctors || []; render(); }
        catch (e) { $('disBody').innerHTML = `<div class="alert alert-danger m-0">${E(e.message)}</div>`; }
    }

    // ── render ─────────────────────────────────────────────────────────────────────────────────────────────────
    function render() {
        const h = one(D.header) || {}, d = one(D.discharge), open = h.IsOpen && h.Status !== 'CANCELLED';
        const bal = h.PatientBalance == null ? null : Number(h.PatientBalance);
        const settled = h.BillId && bal != null && Math.abs(bal) <= 0.5;
        const signed = (D.summaries || []).find(s => s.Status === 'SIGNED');
        const needSummary = d && ['NORMAL', 'TRANSFER', 'DEATH'].includes(d.DischargeType);
        const steps = [
            ['Advice', d && d.AdvisedAt], ['Clearances', d && h.ClearancesPending === 0 ? (h.ClearedAt || d.AdvisedAt) : null], ['Final bill', h.BillAt],
            ['Settled', settled ? (h.LastPaymentAfterBill || h.BillAt) : null], ['Summary signed', signed && signed.SignedAt], ['Gate pass', h.GatePassAt], ['Bed ready', h.BedReadyAt]
        ];
        const over = d && h.TatMinutes > h.TatTargetMinutes;
        let x = `<div class="dis-flow">${steps.map(([t, at], i) => `<div class="dis-flow-step ${at ? 'done' : ''}"><span class="n">${at ? '<i class="bi bi-check-lg"></i>' : i + 1}</span><b>${t}</b><small>${at ? Ipd.dt(at) : 'pending'}</small></div>`).join('')}
            ${d ? `<div class="dis-flow-tat ${over ? 'over' : ''}"><small>Discharge TAT</small><b>${hm(h.TatMinutes)}</b><small>target ${hm(h.TatTargetMinutes)}${d.Status === 'ADVISED' ? ' · running' : ''}</small></div>` : ''}</div>`;

        // advice
        if (!d) {
            x += card('bi-clipboard-check', 'Discharge advice', 'The consultant advises the discharge; the clearances start from here',
                `<p class="small text-muted mb-2">${open ? 'No discharge advised yet.' : 'The patient is not admitted.'}</p>
                 ${open && C.can.advise ? '<button type="button" class="btn btn-sm btn-primary" data-act="advise"><i class="bi bi-clipboard-check me-1"></i>Advise discharge</button>' : ''}`);
            $('disBody').innerHTML = x + followCard(h);
            return;
        }
        x += card('bi-clipboard-check', 'Discharge advice', `${E(TYPE[d.DischargeType])} · advised by ${E(d.AdvisedByDoctorName)} on ${Ipd.dt(d.AdvisedAt)}`,
            `<div class="row g-2 small"><div class="col-md-3"><span class="text-muted">Planned</span><div class="fw-semibold">${Ipd.dt(d.PlannedAt) || '—'}</div></div>
             <div class="col-md-5"><span class="text-muted">Remarks</span><div>${E(d.AdviceRemarks) || '—'}</div></div>
             ${d.TransferTo ? `<div class="col-md-4"><span class="text-muted">Transferred to</span><div>${E(d.TransferTo)}</div></div>` : ''}</div>
             ${d.Status === 'ADVISED' && C.can.advise ? `<div class="mt-2 d-flex gap-2"><button type="button" class="btn btn-sm btn-light border" data-act="advise"><i class="bi bi-pencil me-1"></i>Change</button>
                ${h.Status !== 'BILL_FINAL' ? '<button type="button" class="btn btn-sm btn-outline-danger" data-act="cancelAdvice"><i class="bi bi-x-circle me-1"></i>Cancel advice</button>' : ''}</div>` : ''}`);

        // clearances
        const lp = D.labPending || [];
        x += card('bi-ui-checks', 'Clearances', 'Every department clears the patient before the gate pass',
            `<div class="dis-clear">${(D.clearances || []).map(c => {
                const [title, icon] = DEPT[c.Dept]; let info = '';
                if (c.Dept === 'PHARMACY' && h.OpenIndents > 0) info = `<div class="text-danger small"><i class="bi bi-exclamation-triangle me-1"></i>${h.OpenIndents} indent(s) still open</div>`;
                if (c.Dept === 'LAB' && lp.length) info = `<div class="small ${h.LabNotCollected > 0 ? 'text-danger' : 'text-warning'}"><i class="bi bi-hourglass-split me-1"></i>${lp.length} not reported: ${lp.slice(0, 4).map(l => E(l.ItemName) + (l.ItemStatus === 'NOT_COLLECTED' ? ' (no sample)' : '')).join(', ')}${lp.length > 4 ? '…' : ''}</div>`;
                if (c.Dept === 'TPA' && h.TpaWaiting) info = `<div class="text-danger small"><i class="bi bi-hourglass-split me-1"></i>Waiting for the TPA (${E(h.TpaWaiting.replace('_', ' ').toLowerCase())})</div>`;
                const can = C.can.clear[c.Dept] && d.Status === 'ADVISED';
                return `<div class="dis-clear-item st-${c.Status}"><div class="d-flex align-items-center gap-2"><i class="bi ${icon}"></i><b>${title}</b>
                    <span class="ms-auto dis-badge st-${c.Status}">${c.Status === 'CLEARED' ? 'Cleared' : c.Status === 'NA' ? 'Not needed' : 'Pending'}</span></div>
                    ${c.Status !== 'PENDING' ? `<div class="small text-muted">${E(c.ClearedByName || '')} ${Ipd.dt(c.ClearedAt)}</div>` : ''}${c.Remarks ? `<div class="small fst-italic">${E(c.Remarks)}</div>` : ''}${info}
                    ${can ? (c.Status === 'PENDING' ? `<button type="button" class="btn btn-sm btn-success mt-2" data-act="clear" data-dept="${c.Dept}"><i class="bi bi-check2-square me-1"></i>Clear</button>`
                        : `<button type="button" class="btn btn-sm btn-link p-0 mt-1" data-act="reopen" data-dept="${c.Dept}">Reopen</button>`) : ''}</div>`; }).join('')}</div>`);

        // final bill and settlement
        x += card('bi-receipt', 'Final bill and settlement', 'Made on the Billing tab; the gate pass needs the patient share settled',
            h.BillId ? `<div class="small">Bill <b class="font-monospace">${E(h.BillNo)}</b> on ${Ipd.dt(h.BillAt)} ·
                ${bal > 0.5 ? `<span class="text-danger fw-semibold">balance due ${Ipd.money(bal)}</span>` : bal < -0.5 ? `<span class="text-warning fw-semibold">refund due ${Ipd.money(-bal)}</span>` : '<span class="text-success fw-semibold">settled</span>'}</div>
                ${!settled && d.Status === 'ADVISED' ? '<button type="button" class="btn btn-sm btn-light border mt-2" data-act="billing"><i class="bi bi-cash-coin me-1"></i>Collect / refund on the Billing tab</button>' : ''}`
                : `<div class="small text-muted">No final bill yet.${h.ClearancesPending > 0 ? ' Finish the clearances first (pharmacy returns cannot be taken after the bill).' : ''}</div>
                   ${d.Status === 'ADVISED' ? '<button type="button" class="btn btn-sm btn-primary mt-2" data-act="billing"><i class="bi bi-receipt me-1"></i>Open the Billing tab</button>' : ''}`);

        // summary
        const sums = D.summaries || [], draft = sums.find(s => s.Status === 'DRAFT');
        const isDeath = d.DischargeType === 'DEATH';
        x += card('bi-file-earmark-medical', isDeath ? 'Death summary' : 'Discharge summary', `NABH content, signed by the consultant, versioned${needSummary ? ' · required for the gate pass' : ' · optional for this type'}`,
            `${sums.length ? `<table class="table table-sm ipdx-table mb-2"><thead><tr><th>Version</th><th>Status</th><th>Signed by</th><th>Signed at</th><th>Amendment</th><th></th></tr></thead><tbody>
                ${sums.map(s => `<tr class="${s.Status === 'SUPERSEDED' ? 'text-muted' : ''}"><td>v${s.Version}</td><td><span class="dis-badge st-${s.Status}">${E(s.Status.toLowerCase())}</span></td><td>${E(s.SignedByDoctorName)}${s.SignedOnBehalf ? `<div class="small text-warning">on behalf · by ${E(s.SignedByUserName)}</div>` : ''}</td><td>${Ipd.dt(s.SignedAt)}</td>
                <td class="small">${E(s.AmendReason)}</td><td class="text-end"><a class="btn btn-sm btn-light border" target="_blank" href="${E((D.prints.versions || {})[s.SummaryId] || D.prints.summary)}"><i class="bi bi-printer"></i></a></td></tr>`).join('')}</tbody></table>` : '<p class="small text-muted mb-2">Not written yet.</p>'}
             ${(C.can.summary || canAnySign()) && h.Status !== 'CANCELLED' ? `<button type="button" class="btn btn-sm btn-primary" data-act="summary"><i class="bi bi-pencil-square me-1"></i>${draft ? 'Continue the draft' : signed ? 'Amend (new version)' : 'Write the summary'}</button>` : ''}`);

        // LAMA / DAMA
        if (['LAMA', 'DAMA'].includes(d.DischargeType)) {
            const l = one(D.lama);
            x += card('bi-exclamation-octagon', d.DischargeType + ' form', 'Risks explained, signed by the patient / attendant, a witness and the doctor',
                l ? `<div class="small">Signed by <b>${E(l.SignedByName)}</b>${l.SignedByRelation ? ' (' + E(l.SignedByRelation) + ')' : ''} on ${Ipd.dt(l.RecordedAt)} · witness ${E(l.WitnessName)} · explained by ${E(l.ExplainedByDoctorName)}</div>
                    <div class="mt-2 d-flex gap-2"><a class="btn btn-sm btn-light border" target="_blank" href="${E(D.prints.lama)}"><i class="bi bi-printer me-1"></i>Print</a>
                    ${C.can.lama && d.Status === 'ADVISED' ? '<button type="button" class="btn btn-sm btn-outline-danger" data-act="lamaVoid">Void</button>' : ''}</div>`
                  : `<p class="small text-muted mb-2">Not recorded.</p>${C.can.lama && d.Status === 'ADVISED' ? '<button type="button" class="btn btn-sm btn-danger" data-act="lama"><i class="bi bi-pen me-1"></i>Record the form</button>' : ''}`);
        }
        // death
        if (isDeath) {
            const r = one(D.death);
            x += card('bi-heartbreak', 'Death record', 'Cause of death for MCCD Form 4 / 4A, death register, body handover',
                r ? `<div class="small"><b class="font-monospace">${E(r.DeathRegNo)}</b> · died ${Ipd.dt(r.DeathAt)} · certified by ${E(r.CertifiedByDoctorName)}</div>
                    <div class="small">I (a) ${E(r.CauseImmediate)}${r.CauseAntecedent ? ' ← (b) ' + E(r.CauseAntecedent) : ''}${r.CauseUnderlying ? ' ← (c) ' + E(r.CauseUnderlying) : ''} · ${E(r.MannerOfDeath.toLowerCase())}${r.PoliceIntimated ? ' · police: ' + E(r.PoliceStation) : ''}</div>
                    <div class="mt-2 d-flex gap-2"><a class="btn btn-sm btn-light border" target="_blank" href="${E(D.prints.death)}"><i class="bi bi-printer me-1"></i>MCCD Form ${E(r.FormType)}</a>
                    ${C.can.death ? '<button type="button" class="btn btn-sm btn-light border" data-act="death"><i class="bi bi-pencil me-1"></i>Correct</button>' : ''}
                    ${C.can.death && d.Status === 'ADVISED' ? '<button type="button" class="btn btn-sm btn-outline-danger" data-act="deathVoid">Void</button>' : ''}</div>`
                  : `<p class="small text-muted mb-2">Not recorded.</p>${C.can.death && d.Status === 'ADVISED' ? '<button type="button" class="btn btn-sm btn-dark" data-act="death"><i class="bi bi-pen me-1"></i>Record the death</button>' : ''}`);
        }

        // gate pass
        if (d.Status === 'DISCHARGED') {
            x += card('bi-door-open', 'Gate pass', 'The patient has left; the bed went to housekeeping',
                `<div class="small"><b class="font-monospace">${E(d.GatePassNo)}</b> on ${Ipd.dt(d.GatePassAt)} by ${E(d.GatePassByName)} · handed over to ${E(d.HandedOverTo) || '—'}${d.HandedOverRelation ? ' (' + E(d.HandedOverRelation) + ')' : ''}
                 ${d.TransportMode ? ' · ' + E(d.TransportMode) : ''}${d.IsCreditDischarge ? ` · <span class="text-danger">credit discharge ${Ipd.money(d.CreditAmount)}: ${E(d.CreditReason)}</span>` : ''}</div>
                 <a class="btn btn-sm btn-light border mt-2" target="_blank" href="${E(D.prints.gatePass)}"><i class="bi bi-printer me-1"></i>Print gate pass</a>`);
        } else {
            const req = [
                ['Clearances done', h.ClearancesPending === 0], ['Final bill made', !!h.BillId], ['No OT scheduled or in progress', h.OpenOt === 0],
                ['Patient share settled' + (bal > 0.5 ? ` (due ${Ipd.money(bal)}${C.can.credit ? ', or credit discharge' : ''})` : bal < -0.5 ? ` (refund ${Ipd.money(-bal)} first)` : ''), settled],
                ...(needSummary ? [['Summary signed by the consultant', !!signed]] : []),
                ...(['LAMA', 'DAMA'].includes(d.DischargeType) ? [['LAMA / DAMA form recorded', !!h.LamaId]] : []),
                ...(isDeath ? [['Death recorded', !!h.DeathId]] : [])
            ];
            const ready = req.every(r => r[1]) || (C.can.credit && req.filter(r => !r[1]).length === 1 && bal > 0.5);
            x += card('bi-door-open', 'Gate pass', 'Closes the admission and releases the bed to housekeeping',
                `<ul class="dis-req">${req.map(([t, ok]) => `<li class="${ok ? 'ok' : ''}"><i class="bi ${ok ? 'bi-check-circle-fill' : 'bi-circle'}"></i>${t}</li>`).join('')}</ul>
                 ${C.can.gatePass ? `<button type="button" class="btn btn-sm btn-success" data-act="gatePass" ${ready ? '' : 'disabled'}><i class="bi bi-door-open me-1"></i>Issue gate pass</button>` : ''}`);
        }
        $('disBody').innerHTML = x + followCard(h);
    }

    function card(icon, title, sub, body) {
        return `<div class="reg-section mb-3"><div class="reg-section-header"><div class="sec-icon blue"><i class="bi ${icon}"></i></div>
            <div class="flex-grow-1"><h6 class="fw-bold mb-0">${title}</h6><small class="text-muted">${sub}</small></div></div><div class="reg-section-body">${body}</div></div>`;
    }

    function followCard(h) {
        const f = D.followUps || [];
        return card('bi-calendar-check', 'OPD follow-up', 'Booked from the doctor\'s OPD roster; printed on the discharge summary; closed when the OPD visit is booked',
            `${f.length ? `<table class="table table-sm ipdx-table mb-2"><thead><tr><th>Date</th><th>Slot</th><th>Doctor</th><th>Notes</th><th>Status</th><th></th></tr></thead><tbody>
                ${f.map(r => `<tr class="${r.Status === 'CANCELLED' ? 'text-muted text-decoration-line-through' : ''}"><td>${Ipd.date(r.FollowUpDate)}</td><td>${E(r.SlotTime) || '—'}</td><td>${E(r.DoctorName)}</td><td class="small">${E(r.Notes)}</td>
                <td class="small">${r.Status === 'VISITED' ? `<span class="badge bg-success-subtle text-success-emphasis">Visited</span><div class="text-muted">OPD ${E(r.OPDBillNo) || '#' + r.OpdServiceId}${r.VisitedAt ? ' · ' + Ipd.dt(r.VisitedAt) : ''}</div>` : r.Status === 'BOOKED' ? '<span class="badge bg-primary-subtle text-primary-emphasis">Booked</span>' : `<span class="badge bg-secondary-subtle text-secondary-emphasis">Cancelled</span>${r.CancelReason ? '<div class="text-muted">' + E(r.CancelReason) + '</div>' : ''}`}</td><td class="text-end text-nowrap">${r.Status === 'BOOKED' && D.opd[r.FollowUpId] ? `<a class="btn btn-sm btn-light border" target="_blank" href="${E(D.opd[r.FollowUpId])}" title="Register the OPD visit for this slot"><i class="bi bi-box-arrow-up-right me-1"></i>OPD booking</a>` : ''}
                ${r.Status === 'BOOKED' && C.can.followUp ? `<button type="button" class="btn btn-sm btn-link text-danger" data-act="fuCancel" data-fid="${r.FollowUpId}">Cancel</button>` : ''}</td></tr>`).join('')}</tbody></table>` : '<p class="small text-muted mb-2">No follow-up booked.</p>'}
             ${C.can.followUp && h.Status !== 'CANCELLED' ? '<button type="button" class="btn btn-sm btn-outline-primary" data-act="followUp"><i class="bi bi-calendar-plus me-1"></i>Book follow-up</button>' : ''}`);
    }

    // ── actions ────────────────────────────────────────────────────────────────────────────────────────────────
    function adviseDialog() {
        const d = one(D.discharge) || {}, h = one(D.header) || {};
        modal('disAdvM', 'Discharge advice', `<div class="row g-2">
            ${field('daType', 'Discharge type *', sel('daType', Object.entries(TYPE), d.DischargeType || 'NORMAL', ''), 'col-md-6')}
            ${field('daDoc', 'Advised by (consultant) *', sel('daDoc', docOpts(), d.AdvisedByDoctorId || h.ConsultantDoctorId), 'col-md-6')}
            ${field('daAt', 'Planned discharge', `<input type="datetime-local" id="daAt" class="form-control form-control-sm" value="${d.PlannedAt ? Ipd.local(new Date(d.PlannedAt)) : ''}" />`, 'col-md-6')}
            <div class="col-md-6" id="daToBox">${field('daTo', 'Transferred to (hospital, reason) *', txt('daTo', d.TransferTo), 'col-12')}</div>
            ${field('daRem', 'Remarks / circumstances', area('daRem', d.AdviceRemarks, 2), 'col-12')}</div>`,
            '<button type="button" class="btn btn-primary" id="daSave">Save</button>', 'modal-lg');
        const sync = () => { $('daToBox').style.display = v('daType') === 'TRANSFER' ? '' : 'none'; };
        $('daType').addEventListener('change', sync); sync();
        $('daSave').onclick = async () => {
            if (await post('Advise', { dischargeType: v('daType'), advisedByDoctorId: Number(v('daDoc')) || 0, plannedAt: v('daAt') || null, remarks: v('daRem') || null, transferTo: v('daType') === 'TRANSFER' ? v('daTo') : null }, 'Discharge advice saved')) hide('disAdvM');
        };
    }

    function clearDialog(dept) {
        const items = CHECK[dept];
        modal('disClrM', DEPT[dept][0] + ' clearance', `<table class="table table-sm align-middle"><tbody>${items.map(([k, t]) => `<tr><td>${E(t)}</td>
            <td class="text-end text-nowrap"><div class="btn-group btn-group-sm" role="group"><input type="radio" class="btn-check" name="ck${k}" id="ck${k}d" value="DONE"><label class="btn btn-outline-success" for="ck${k}d">Done</label>
            <input type="radio" class="btn-check" name="ck${k}" id="ck${k}n" value="NA"><label class="btn btn-outline-secondary" for="ck${k}n">N/A</label></div></td></tr>`).join('')}</tbody></table>
            ${field('ckRem', 'Remarks', area('ckRem', '', 2), 'col-12')}`,
            '<button type="button" class="btn btn-outline-success" id="ckAll">All done</button><button type="button" class="btn btn-success" id="ckSave">Clear</button>', 'modal-lg');
        $('ckAll').onclick = () => items.forEach(([k]) => { $('ck' + k + 'd').checked = true; });
        $('ckSave').onclick = async () => {
            const ans = items.map(([k]) => ({ code: k, answer: document.querySelector(`input[name="ck${k}"]:checked`)?.value || '' }));
            if (ans.some(a => !a.answer)) return Ipd.error('Answer every item (Done or N/A).');
            if (await post('Clear', { dept, action: 'CLEAR', checklist: JSON.stringify(ans), remarks: v('ckRem') || null }, 'Clearance done')) hide('disClrM');
        };
    }

    // discharge summary form
    const dxRow = (x = {}) => `<div class="row g-1 mb-1 dx-row"><div class="col-md-3"><select class="form-select form-select-sm dx-kind">${[['PRIMARY', 'Primary'], ['SECONDARY', 'Secondary'], ['COMORBID', 'Co-morbidity']].map(([k, t]) => `<option value="${k}" ${x.kind === k ? 'selected' : ''}>${t}</option>`).join('')}</select></div>
        <div class="col-md-2"><input class="form-control form-control-sm dx-code font-monospace" placeholder="ICD-10" value="${E(x.code || '')}" /></div>
        <div class="col-md-6"><input class="form-control form-control-sm dx-title" placeholder="Diagnosis" value="${E(x.title || '')}" /></div>
        <div class="col-md-1"><button type="button" class="btn btn-sm btn-link text-danger dx-del" title="Remove"><i class="bi bi-x-lg"></i></button></div></div>`;
    const mdRow = (x = {}) => `<tr class="md-row">${['drug', 'dose', 'route', 'frequency', 'duration', 'instructions'].map(k => `<td><input class="form-control form-control-sm md-${k}" value="${E(x[k] || '')}" ${k === 'drug' ? 'placeholder="Type to search…"' : ''} /></td>`).join('')}
        <td><button type="button" class="btn btn-sm btn-link text-danger md-del"><i class="bi bi-x-lg"></i></button></td></tr>`;
    const bindDx = row => Ipd.icdSuggest(row.querySelector('.dx-code'), row.querySelector('.dx-title'), C.admBase + 'IcdSearch');
    // Drug: type to search Master > EMR Medication; picking fills the drug, and the dose / route when still empty
    function bindMd(row) {
        const inp = row.querySelector('.md-drug'); if (!inp || inp.dataset.bound) return;
        inp.dataset.bound = '1'; inp.setAttribute('autocomplete', 'off');
        const cell = inp.parentElement; cell.style.position = 'relative';
        const box = document.createElement('div'); box.className = 'sug-list list-group dis-med-sug'; cell.appendChild(box);
        let t, items = [], idx = 0;
        const close = () => { box.style.display = 'none'; };
        const draw = () => {
            box.innerHTML = items.map((m, i) => `<button type="button" class="list-group-item list-group-item-action py-1 px-2 small ${i === idx ? 'active' : ''}" data-i="${i}">
                <b>${E(m.MedicationName)}</b>${m.GenericName ? ` <span class="text-muted">· ${E(m.GenericName)}</span>` : ''}${m.Strength ? ` <span class="badge text-bg-light border">${E(m.Strength)}</span>` : ''}</button>`).join('')
                || '<div class="list-group-item small text-muted py-1 px-2">Not in EMR Medication master: the typed name is kept.</div>';
            box.style.display = 'block';
        };
        const pick = i => {
            const m = items[i]; if (!m) return;
            inp.value = m.MedicationName;
            const dose = row.querySelector('.md-dose'), route = row.querySelector('.md-route');
            if (dose && !dose.value.trim() && m.Strength) dose.value = m.Strength;
            if (route && !route.value.trim() && m.RouteOfAdministration) route.value = m.RouteOfAdministration;
            close(); row.querySelector('.md-frequency')?.focus();
        };
        inp.addEventListener('input', () => {
            clearTimeout(t); const q = inp.value.trim();
            if (q.length < 2) { close(); return; }
            t = setTimeout(async () => { try { items = await Ipd.get(base + 'Medicines?q=' + encodeURIComponent(q)) || []; idx = 0; draw(); } catch { close(); } }, 250);
        });
        inp.addEventListener('keydown', e => {
            if (box.style.display !== 'block' || !items.length) return;
            if (e.key === 'ArrowDown' || e.key === 'ArrowUp') { e.preventDefault(); idx = (idx + (e.key === 'ArrowDown' ? 1 : -1) + items.length) % items.length; draw(); }
            else if (e.key === 'Enter') { e.preventDefault(); pick(idx); }
            else if (e.key === 'Escape') close();
        });
        inp.addEventListener('blur', () => setTimeout(close, 200));
        box.addEventListener('mousedown', e => { const b = e.target.closest('[data-i]'); if (b) { e.preventDefault(); pick(Number(b.dataset.i)); } });
    }

    const canAnySign = () => C.can.sign || C.can.onBehalf;
    // who signs: a doctor login signs as itself; the on-behalf bypass (DISCHARGE_SUMMARY_ONBEHALF) may pick any consultant, with a reason
    function signerBlock(h) {
        if (!canAnySign()) return '';
        const mine = h.MyDoctorId, opts = C.can.onBehalf ? docOpts() : docOpts().filter(([id]) => Number(id) === Number(mine));
        if (!opts.length) return `<div class="alert alert-warning py-2 small mt-2 mb-0">Your login is not linked to a doctor (Doctor Master), so you cannot sign; only a user with "sign on behalf" can.</div>`;
        const def = C.can.onBehalf ? (mine && !C.can.sign ? h.ConsultantDoctorId : (mine || h.ConsultantDoctorId)) : mine;
        return `<div class="row g-2 mt-2 border-top pt-2">${field('smSigner', 'Signed by (consultant)', sel('smSigner', opts, C.can.sign && mine ? mine : def, ''), 'col-md-5')}
            <div class="col-md-7" id="smObBox">${field('smOb', 'Reason for signing on behalf *', txt('smOb', '', 300, 'e.g. consultant approved on phone, out of station'), 'col-12')}</div>
            <div class="col-12 small" id="smSignHint"></div></div>`;
    }

    async function summaryDialog() {
        const sums = D.summaries || [], cur = sums.find(s => s.Status === 'DRAFT') || sums.find(s => s.Status === 'SIGNED') || {};
        const amending = !sums.find(s => s.Status === 'DRAFT') && !!sums.find(s => s.Status === 'SIGNED');
        const h = one(D.header) || {}, dis = one(D.discharge) || {};
        let pre = null;
        if (!cur.SummaryId) { try { pre = await Ipd.get(base + 'Prefill?id=' + C.id); } catch { pre = null; } }
        const pa = pre ? one(pre.admission) || {} : {};
        const dx = cur.Diagnoses ? JSON.parse(cur.Diagnoses) : (pa.ProvisionalDiagnosis || pa.DiagnosisCode ? [{ kind: 'PRIMARY', code: pa.DiagnosisCode || '', title: pa.DiagnosisTitle || pa.ProvisionalDiagnosis || '' }] : [{ kind: 'PRIMARY' }]);
        const meds = cur.Medicines ? JSON.parse(cur.Medicines) : [];
        const procs = cur.Procedures ?? (pre ? (pre.procedures || []).map(p => `${Ipd.date(p.DoneAt)} – ${p.Name}${p.DoctorName ? ' (' + p.DoctorName + ')' : ''}`).join('\n') : '');
        const inv = cur.Investigations ?? (pre ? (pre.investigations || []).map(i => `${Ipd.date(i.OrderDate)} – ${i.ItemName}: ${i.ItemStatus}`).join('\n') : '');
        const isDeath = dis.DischargeType === 'DEATH';
        const m = modal('disSumM', (isDeath ? 'Death summary' : 'Discharge summary') + (amending ? ' · amendment (new version)' : cur.Version ? ' · v' + cur.Version + ' draft' : ''), `
            ${amending ? `<div class="alert alert-warning py-2 small">The signed summary stays on record; this becomes the next version once signed.</div>${field('smAmend', 'Reason for the amendment *', txt('smAmend', ''), 'col-12')}` : ''}
            <div class="sec-h">Diagnoses (ICD-10) *</div><div id="smDx">${dx.map(dxRow).join('')}</div><button type="button" class="btn btn-sm btn-link px-0" id="smDxAdd">+ Add diagnosis</button>
            <div class="row g-2 mt-1">
              ${field('smPc', 'Presenting complaints / reason for admission', area('smPc', cur.PresentingComplaints ?? pa.ReasonForAdmission, 2), 'col-md-6')}
              ${field('smHi', 'History of present illness', area('smHi', cur.HistoryOfIllness, 2), 'col-md-6')}
              ${field('smPh', 'Past history', area('smPh', cur.PastHistory, 2), 'col-md-6')}
              ${field('smAl', 'Allergies', txt('smAl', cur.Allergies ?? pa.KnownAllergies, 500), 'col-md-6')}
              ${field('smEx', 'Examination at admission', area('smEx', cur.Examination, 2), 'col-md-6')}
              ${field('smIn', 'Key investigations', area('smIn', inv, 3), 'col-md-6')}
              ${field('smPr', 'Procedures / surgeries', area('smPr', procs, 3), 'col-md-6')}
              ${field('smCo', 'Course in hospital *', area('smCo', cur.CourseInHospital, 4), 'col-md-6')}
              ${field('smCd', 'Condition at discharge *', sel('smCd', Object.entries(COND), cur.ConditionAtDischarge || (isDeath ? 'EXPIRED' : '')), 'col-md-4')}
              ${field('smCn', 'Condition notes (vitals, wound, mobility)', txt('smCn', cur.ConditionNotes, 1000), 'col-md-8')}
            </div>
            ${isDeath ? '' : `<div class="sec-h mt-2">Medicines on discharge</div>
            <table class="table table-sm mb-1"><thead><tr><th>Drug</th><th>Dose</th><th>Route</th><th>Frequency</th><th>Duration</th><th>Instructions</th><th></th></tr></thead><tbody id="smMd">${meds.map(mdRow).join('')}</tbody></table>
            <button type="button" class="btn btn-sm btn-link px-0" id="smMdAdd">+ Add medicine</button>
            ${pre && (pre.medicines || []).length ? `<button type="button" class="btn btn-sm btn-link" id="smMdCopy">Copy from medicines issued in the last 48 h (${pre.medicines.length})</button>` : ''}
            <div class="row g-2 mt-1">
              ${field('smDi', 'Diet', txt('smDi', cur.Diet, 500), 'col-md-6')}${field('smAc', 'Activity', txt('smAc', cur.Activity, 500), 'col-md-6')}
              ${field('smAd', 'Advice on discharge', area('smAd', cur.Advice, 2), 'col-md-6')}
              ${field('smWs', 'When to come back at once (warning signs)', area('smWs', cur.WarningSigns ?? 'Fever above 101 °F, breathlessness, chest pain, bleeding, severe pain, vomiting, fainting, reduced urine.', 2), 'col-md-6')}
              ${field('smFu', 'Follow-up', txt('smFu', cur.FollowUp ?? ((D.followUps || []).filter(f => f.Status === 'BOOKED').map(f => `${Ipd.date(f.FollowUpDate)} ${f.SlotTime || ''} – ${f.DoctorName}`).join('; ')), 500), 'col-md-6')}
              ${field('smEc', 'Emergency contact *', txt('smEc', cur.EmergencyContact ?? pa.EmergencyContact), 'col-md-6')}
            </div>`}
            ${signerBlock(h)}`,
            `${C.can.summary || canAnySign() ? '<button type="button" class="btn btn-outline-primary" id="smDraft">Save draft</button>' : ''}${canAnySign() ? '<button type="button" class="btn btn-success" id="smSign"><i class="bi bi-pen me-1"></i>Sign</button>' : ''}`, 'modal-xl');
        syncSigner();
        m.querySelectorAll('.dx-row').forEach(bindDx);
        m.addEventListener('click', e => { const del = e.target.closest('.dx-del, .md-del'); if (del) del.closest('.dx-row, .md-row').remove(); });
        $('smDxAdd').onclick = () => { $('smDx').insertAdjacentHTML('beforeend', dxRow()); bindDx($('smDx').lastElementChild); };
        const addMd = x => { $('smMd').insertAdjacentHTML('beforeend', mdRow(x)); bindMd($('smMd').lastElementChild); return $('smMd').lastElementChild; };
        m.querySelectorAll('.md-row').forEach(bindMd);
        if ($('smMdAdd')) $('smMdAdd').onclick = () => addMd().querySelector('.md-drug').focus();
        if ($('smMdCopy')) $('smMdCopy').onclick = () => pre.medicines.forEach(x => addMd({ drug: x.ItemName }));
        function syncSigner() {
            const s = $('smSigner'); if (!s) return;
            const own = h.MyDoctorId && Number(s.value) === Number(h.MyDoctorId);
            $('smObBox').style.display = own ? 'none' : '';
            $('smSignHint').innerHTML = own ? '<i class="bi bi-person-check me-1 text-success"></i>You sign as yourself.'
                : '<i class="bi bi-person-badge me-1 text-warning"></i>Signing <b>on behalf</b> of the consultant: your name and the reason are recorded and printed.';
        }
        $('smSigner')?.addEventListener('change', syncSigner);
        // mandatory fields: marked in red with their message, first one scrolled into view (the SP checks the same rules)
        function checkSummary(sign, onBehalf) {
            m.querySelectorAll('.is-invalid').forEach(x => x.classList.remove('is-invalid'));
            m.querySelectorAll('.sm-err').forEach(x => x.remove());
            const bad = [];
            const need = (el, msg) => {
                if (!el) return;
                el.classList.add('is-invalid');
                el.insertAdjacentHTML('afterend', `<div class="invalid-feedback d-block sm-err">${E(msg)}</div>`);
                el.addEventListener(el.tagName === 'SELECT' ? 'change' : 'input', () => { el.classList.remove('is-invalid'); el.nextElementSibling?.classList.contains('sm-err') && el.nextElementSibling.remove(); }, { once: true });
                bad.push({ el, msg });
            };
            if (amending && !v('smAmend')) need($('smAmend'), 'Enter the reason for the amendment.');
            if (sign) {
                if (![...m.querySelectorAll('.dx-title')].some(x => x.value.trim())) need(m.querySelector('.dx-title'), 'Enter at least one final diagnosis.');
                if (!v('smCo')) need($('smCo'), 'Enter the course in hospital.');
                if (!v('smCd')) need($('smCd'), 'Choose the condition at discharge.');
                if ($('smEc') && !['DEATH', 'ABSCONDED'].includes(dis.DischargeType) && !v('smEc')) need($('smEc'), 'Enter the emergency contact (NABH).');
                if (!v('smSigner')) need($('smSigner'), 'Choose the consultant signing the summary.');
                else if (onBehalf && !v('smOb')) need($('smOb'), 'Enter why you are signing on behalf of the consultant.');
            }
            if (!bad.length) return true;
            bad[0].el.scrollIntoView({ behavior: 'smooth', block: 'center' });
            bad[0].el.focus({ preventScroll: true });
            const title = sign ? 'Complete these before signing' : 'Complete these before saving';
            if (window.Swal) Swal.fire({ icon: 'warning', title, html: `<ul class="text-start mb-0">${bad.map(b => `<li>${E(b.msg)}</li>`).join('')}</ul>` });
            else Ipd.error(title + ': ' + bad.map(b => b.msg).join(' '));
            return false;
        }
        const save = async sign => {
            const dxs = [...m.querySelectorAll('.dx-row')].map(r => ({ kind: r.querySelector('.dx-kind').value, code: r.querySelector('.dx-code').value.trim(), title: r.querySelector('.dx-title').value.trim() })).filter(x => x.title || x.code);
            const mds = [...m.querySelectorAll('.md-row')].map(r => Object.fromEntries(['drug', 'dose', 'route', 'frequency', 'duration', 'instructions'].map(k => [k, r.querySelector('.md-' + k).value.trim()]))).filter(x => x.drug);
            const onBehalf = sign && !(h.MyDoctorId && Number(v('smSigner')) === Number(h.MyDoctorId));
            if (!checkSummary(sign, onBehalf)) return;
            if (sign && !(await Ipd.confirm('Sign the summary?', (onBehalf ? 'You sign <b>on behalf of</b> the consultant. ' : '') + 'A signed summary is changed only as an amendment with a reason.', 'Sign'))) return;
            const body = {
                diagnoses: JSON.stringify(dxs), presentingComplaints: v('smPc') || null, historyOfIllness: v('smHi') || null, pastHistory: v('smPh') || null, allergies: v('smAl') || null,
                examination: v('smEx') || null, investigations: v('smIn') || null, procedures: v('smPr') || null, courseInHospital: v('smCo') || null,
                conditionAtDischarge: v('smCd') || null, conditionNotes: v('smCn') || null, medicines: mds.length ? JSON.stringify(mds) : null,
                diet: v('smDi') || null, activity: v('smAc') || null, advice: v('smAd') || null, warningSigns: v('smWs') || null, followUp: v('smFu') || null,
                emergencyContact: v('smEc') || null, sign, signedByDoctorId: Number(v('smSigner')) || null, amendReason: amending ? v('smAmend') : null, onBehalfReason: onBehalf ? v('smOb') : null
            };
            if (await post('SaveSummary', body, sign ? 'Summary signed' : 'Draft saved')) hide('disSumM');
        };
        if ($('smDraft')) $('smDraft').onclick = () => save(false);
        if ($('smSign')) $('smSign').onclick = () => save(true);
    }

    function lamaDialog() {
        const dis = one(D.discharge) || {}, h = one(D.header) || {}, att = (C.attendants || [])[0] || {};
        const pad = (id, label) => `<div class="col-md-4"><label class="form-label small fw-semibold">${label}</label><canvas id="${id}" class="dis-pad"></canvas><button type="button" class="btn btn-sm btn-link px-0" data-clear="${id}">Clear</button></div>`;
        const m = modal('disLamaM', dis.DischargeType + ' form', `<div class="row g-2">
            ${field('lmReason', 'Why the patient is leaving *', area('lmReason', dis.AdviceRemarks, 2), 'col-12')}
            ${field('lmRisks', 'Risks explained *', area('lmRisks', LAMA_RISKS, 4), 'col-12')}
            ${field('lmDoc', 'Explained by (doctor) *', sel('lmDoc', docOpts(), h.ConsultantDoctorId), 'col-md-4')}
            ${field('lmName', 'Signed by (patient or attendant) *', txt('lmName', att.Name || '', 150), 'col-md-4')}
            ${field('lmRel', 'Relation', txt('lmRel', att.Relation || 'Self', 50), 'col-md-4')}
            ${field('lmWit', 'Witness *', txt('lmWit', '', 150), 'col-md-4')}
            <div class="w-100"></div>${pad('lmSig', 'Patient / attendant signature or thumb *')}${pad('lmWsig', 'Witness signature')}${pad('lmDsig', 'Doctor signature')}</div>`,
            '<button type="button" class="btn btn-danger" id="lmSave">Save form</button>', 'modal-xl');
        const pads = {};
        m.addEventListener('shown.bs.modal', () => ['lmSig', 'lmWsig', 'lmDsig'].forEach(id => { pads[id] = pads[id] || Ipd.signaturePad($(id)); pads[id].fit(); }), { once: true });
        m.addEventListener('click', e => { const c = e.target.closest('[data-clear]'); if (c) pads[c.dataset.clear]?.clear(); });
        $('lmSave').onclick = async () => {
            const sig = pads.lmSig?.dataUrl() || '';
            if (!sig) return Ipd.error('The patient / attendant must sign on the pad.');
            if (await post('Lama', { reason: v('lmReason'), risksExplained: v('lmRisks'), explainedByDoctorId: Number(v('lmDoc')) || null, signedByName: v('lmName'), signedByRelation: v('lmRel') || null,
                witnessName: v('lmWit'), signature: sig, witnessSignature: pads.lmWsig?.dataUrl() || null, doctorSignature: pads.lmDsig?.dataUrl() || null }, 'Form recorded')) hide('disLamaM');
        };
    }

    function deathDialog() {
        const r = one(D.death) || {}, h = one(D.header) || {}, female = /^f/i.test(h.Gender || '');
        const now = Ipd.local(new Date());
        const ci = (k, label, val, iv) => `<div class="col-md-8">${`<label class="form-label small fw-semibold" for="dt${k}">${label}</label>`}${txt('dt' + k, val)}</div><div class="col-md-4"><label class="form-label small fw-semibold" for="dt${k}I">Interval onset to death</label>${txt('dt' + k + 'I', iv, 50, 'e.g. 3 days')}</div>`;
        modal('disDeathM', 'Death record · MCCD', `<div class="row g-2">
            ${field('dtAt', 'Date &amp; time of death *', `<input type="datetime-local" id="dtAt" class="form-control form-control-sm" value="${r.DeathAt ? Ipd.local(new Date(r.DeathAt)) : now}" />`, 'col-md-4')}
            ${field('dtForm', 'MCCD form', sel('dtForm', [['4', 'Form 4 (hospital / institutional)'], ['4A', 'Form 4A (non-institutional)']], r.FormType || '4', ''), 'col-md-4')}
            ${field('dtDoc', 'Certified by (doctor) *', sel('dtDoc', docOpts(), r.CertifiedByDoctorId || h.ConsultantDoctorId), 'col-md-4')}
            <div class="col-12 sec-h">Part I – disease or condition directly leading to death, and the conditions that led to it</div>
            ${ci('A', '(a) Immediate cause *', r.CauseImmediate, r.IntervalImmediate)}${ci('B', '(b) Due to (antecedent cause)', r.CauseAntecedent, r.IntervalAntecedent)}
            ${ci('C', '(c) Due to (underlying cause)', r.CauseUnderlying, r.IntervalUnderlying)}
            ${field('dtIcd', 'Underlying cause ICD-10', txt('dtIcd', r.UnderlyingIcd, 10), 'col-md-3')}${field('dtIcdT', 'ICD title', txt('dtIcdT', ''), 'col-md-9')}
            ${field('dtOther', 'Part II – other significant conditions contributing to death', txt('dtOther', r.OtherConditions, 500), 'col-12')}
            ${field('dtManner', 'Manner of death *', sel('dtManner', [['NATURAL', 'Natural'], ['ACCIDENT', 'Accident'], ['SUICIDE', 'Suicide'], ['HOMICIDE', 'Homicide'], ['PENDING', 'Pending investigation']], r.MannerOfDeath || 'NATURAL', ''), 'col-md-4')}
            ${female ? field('dtPreg', 'Pregnancy *', sel('dtPreg', [['NOT_PREGNANT', 'Not pregnant'], ['PREGNANT', 'Pregnant at death'], ['WITHIN_42D', 'Within 42 days of delivery / abortion'], ['NA', 'Not applicable (age)']], r.PregnancyStatus), 'col-md-4')
                     + `<div class="col-md-4 pt-4"><div class="form-check"><input class="form-check-input" type="checkbox" id="dtDel" ${r.DeliveryInvolved ? 'checked' : ''}><label class="form-check-label small" for="dtDel">Delivery involved</label></div></div>` : ''}
            <div class="col-md-4 pt-2"><div class="form-check"><input class="form-check-input" type="checkbox" id="dtPol" ${r.PoliceIntimated || h.IsMlc ? 'checked' : ''}><label class="form-check-label small" for="dtPol">Police intimated${h.IsMlc ? ' (MLC)' : ''}</label></div></div>
            ${field('dtPs', 'Police station', txt('dtPs', r.PoliceStation, 150), 'col-md-4')}
            <div class="col-md-4 pt-2"><div class="form-check"><input class="form-check-input" type="checkbox" id="dtPm" ${r.PostMortem ? 'checked' : ''}><label class="form-check-label small" for="dtPm">Post-mortem</label></div></div>
            ${field('dtBody', 'Body handed over to', txt('dtBody', r.BodyHandedTo, 150), 'col-md-4')}${field('dtBodyR', 'Relation', txt('dtBodyR', r.BodyHandedRelation, 50), 'col-md-4')}
            ${field('dtBodyAt', 'Handed over at', `<input type="datetime-local" id="dtBodyAt" class="form-control form-control-sm" value="${r.BodyHandedAt ? Ipd.local(new Date(r.BodyHandedAt)) : ''}" />`, 'col-md-4')}
            ${field('dtRem', 'Remarks', txt('dtRem', r.Remarks, 500), 'col-12')}</div>`,
            '<button type="button" class="btn btn-dark" id="dtSave">Save</button>', 'modal-xl');
        Ipd.icdSuggest($('dtIcd'), $('dtIcdT'), C.admBase + 'IcdSearch');
        $('dtSave').onclick = async () => {
            if (await post('Death', {
                deathAt: v('dtAt') || null, formType: v('dtForm'), causeImmediate: v('dtA'), intervalImmediate: v('dtAI') || null, causeAntecedent: v('dtB') || null, intervalAntecedent: v('dtBI') || null,
                causeUnderlying: v('dtC') || null, intervalUnderlying: v('dtCI') || null, underlyingIcd: v('dtIcd') || null, otherConditions: v('dtOther') || null, mannerOfDeath: v('dtManner'),
                pregnancyStatus: female ? v('dtPreg') || null : 'NA', deliveryInvolved: chk('dtDel'), policeIntimated: chk('dtPol'), policeStation: v('dtPs') || null, postMortem: chk('dtPm'),
                certifiedByDoctorId: Number(v('dtDoc')) || null, bodyHandedTo: v('dtBody') || null, bodyHandedRelation: v('dtBodyR') || null, bodyHandedAt: v('dtBodyAt') || null, remarks: v('dtRem') || null
            }, 'Death record saved')) hide('disDeathM');
        };
    }

    function gatePassDialog() {
        const h = one(D.header) || {}, d = one(D.discharge) || {}, att = (C.attendants || [])[0] || {}, bal = Number(h.PatientBalance || 0);
        const dr = one(D.death) || {};
        modal('disGpM', 'Gate pass', `<div class="row g-2">
            ${field('gpTo', d.DischargeType === 'DEATH' ? 'Body handed over to *' : 'Handed over to *', txt('gpTo', dr.BodyHandedTo || att.Name || '', 150), 'col-md-4')}
            ${field('gpRel', 'Relation', txt('gpRel', dr.BodyHandedRelation || att.Relation || '', 50), 'col-md-4')}
            ${field('gpPh', 'Phone', txt('gpPh', att.Phone || '', 20), 'col-md-4')}
            ${field('gpTr', 'Transport', sel('gpTr', [['Own vehicle', 'Own vehicle'], ['Hospital ambulance', 'Hospital ambulance'], ['Private ambulance', 'Private ambulance'], ['Hearse van', 'Hearse van'], ['Walking', 'Walking'], ['Wheelchair to vehicle', 'Wheelchair to vehicle']], d.DischargeType === 'TRANSFER' ? 'Hospital ambulance' : 'Own vehicle', ''), 'col-md-4')}
            ${field('gpRem', 'Remarks', txt('gpRem', '', 500), 'col-md-8')}
            ${bal > 0.5 && C.can.credit ? `<div class="col-12"><div class="alert alert-warning py-2 small mb-1">Balance due ${Ipd.money(bal)}. A credit discharge lets the patient leave with it due.</div>
               <div class="form-check"><input class="form-check-input" type="checkbox" id="gpCr"><label class="form-check-label small" for="gpCr">Credit discharge</label></div>${txt('gpCrR', '', 300, 'Reason (e.g. corporate employee, approved by MS)')}</div>` : ''}</div>`,
            '<button type="button" class="btn btn-success" id="gpSave"><i class="bi bi-door-open me-1"></i>Issue gate pass</button>', 'modal-lg');
        $('gpSave').onclick = async () => {
            if (!(await Ipd.confirm('Issue the gate pass?', 'The admission is closed and the bed is released to housekeeping. This cannot be undone.', 'Issue'))) return;
            const r = await post('GatePass', { handedOverTo: v('gpTo') || null, handedOverRelation: v('gpRel') || null, handedOverPhone: v('gpPh') || null, transportMode: v('gpTr') || null,
                remarks: v('gpRem') || null, credit: chk('gpCr'), creditReason: v('gpCrR') || null }, 'Patient discharged');
            if (r) { hide('disGpM'); window.open(D.prints.gatePass, '_blank'); setTimeout(() => location.reload(), 800); }
        };
    }

    function followUpDialog() {
        const h = one(D.header) || {};
        const tomorrow = new Date(Date.now() + 7 * 864e5).toISOString().slice(0, 10);
        modal('disFuM', 'Book OPD follow-up', `<div class="row g-2">
            ${field('fuDoc', 'Doctor *', sel('fuDoc', docOpts(), h.ConsultantDoctorId), 'col-md-6')}
            ${field('fuDate', 'Date *', `<input type="date" id="fuDate" class="form-control form-control-sm" value="${tomorrow}" min="${new Date().toISOString().slice(0, 10)}" />`, 'col-md-6')}
            <div class="col-12"><label class="form-label small fw-semibold">Slot (doctor's OPD roster)</label><div id="fuSlots" class="dis-slots small text-muted">Choose the doctor and the date.</div></div>
            ${field('fuNotes', 'Notes', txt('fuNotes', '', 300, 'e.g. suture removal, review with reports'), 'col-12')}</div>`,
            '<button type="button" class="btn btn-primary" id="fuSave">Book</button>', 'modal-lg');
        let slot = null;
        const loadSlots = async () => {
            slot = null; const box = $('fuSlots');
            if (!v('fuDoc') || !v('fuDate')) return;
            box.textContent = 'Loading…';
            try {
                const r = await Ipd.get(base + 'Slots?doctorId=' + v('fuDoc') + '&date=' + v('fuDate'));
                if (r.hasException) { box.innerHTML = `<span class="text-danger">Doctor not available: ${E(r.exceptionReason)}</span>`; return; }
                const s = r.slots || [];
                box.innerHTML = s.length ? s.map((x, i) => `<button type="button" class="btn btn-sm ${x.isAvailable ? 'btn-outline-primary' : 'btn-outline-secondary'} me-1 mb-1" data-i="${i}" ${x.isAvailable ? '' : 'disabled'}>${E(x.slotTime)}</button>`).join('')
                    + '<div class="text-muted mt-1">No slot = follow-up on the date without a time.</div>' : 'No OPD roster for that day: the follow-up is booked on the date without a slot.';
                box.onclick = e => { const b = e.target.closest('[data-i]'); if (!b) return; box.querySelectorAll('.active').forEach(z => z.classList.remove('active')); b.classList.add('active'); slot = s[Number(b.dataset.i)]; };
            } catch (e) { box.innerHTML = `<span class="text-danger">${E(e.message)}</span>`; }
        };
        $('fuDoc').addEventListener('change', loadSlots); $('fuDate').addEventListener('change', loadSlots); loadSlots();
        $('fuSave').onclick = async () => {
            if (await post('FollowUp', { doctorId: Number(v('fuDoc')) || null, followUpDate: v('fuDate') || null, scheduleId: slot ? slot.scheduleId : null, slotTime: slot ? slot.slotTime : null, notes: v('fuNotes') || null }, 'Follow-up booked')) hide('disFuM');
        };
    }

    document.getElementById('tab-discharge').addEventListener('click', async e => {
        const b = e.target.closest('[data-act]'); if (!b) return;
        const act = b.dataset.act;
        if (act === 'advise') adviseDialog();
        else if (act === 'cancelAdvice') { const r = await Ipd.reason('Cancel the discharge advice?'); if (r) post('CancelAdvice', { reason: r }, 'Discharge advice cancelled'); }
        else if (act === 'clear') clearDialog(b.dataset.dept);
        else if (act === 'reopen') { const r = await Ipd.reason('Reopen the ' + DEPT[b.dataset.dept][0] + ' clearance?'); if (r) post('Clear', { dept: b.dataset.dept, action: 'REOPEN', remarks: r }, 'Clearance reopened'); }
        else if (act === 'billing') goTab('billing');
        else if (act === 'summary') summaryDialog();
        else if (act === 'lama') lamaDialog();
        else if (act === 'lamaVoid') { const r = await Ipd.reason('Void the LAMA / DAMA form?'); if (r) post('Lama', { voidReason: r }, 'Form voided'); }
        else if (act === 'death') deathDialog();
        else if (act === 'deathVoid') { const r = await Ipd.reason('Void the death record?'); if (r) post('Death', { voidReason: r }, 'Death record voided'); }
        else if (act === 'gatePass') gatePassDialog();
        else if (act === 'followUp') followUpDialog();
        else if (act === 'fuCancel') { const r = await Ipd.reason('Cancel the follow-up?'); if (r) post('FollowUp', { followUpId: Number(b.dataset.fid), cancelReason: r }, 'Follow-up cancelled'); }
    });

    // load when the tab is first shown (or at once when it opens on it)
    const tabBtn = document.querySelector('[data-bs-target="#tab-discharge"]');
    let loaded = false;
    const first = () => { if (!loaded) { loaded = true; load(); } };
    if (document.getElementById('tab-discharge').classList.contains('active')) first();
    tabBtn?.addEventListener('shown.bs.tab', first);
})();
