/* IPD Patient - flow-gap fixes (SQLScripts/2570-2576). Config window.IpdGap = { id, base, admBase, open, status, gender, bloodGroup,
   allergies, codeStatus, isolationType, can: { allergy, codeStatus, isolation, escalate, ack, medRecon, transfusion, restraint, newborn, billAdjust, billAdjustCancel } }.
   Banner: allergy status, code status, isolation. Clinical tab: escalations, medication reconciliation, code status history.
   Nursing tab: escalations, blood transfusion, restraint, newborn link. Billing tab (after the discharge): supplementary bill / credit note.
   Every rule is checked again by the procedures; page URLs (prints, other admissions) come from the server, encrypted. */
(function () {
    'use strict';
    const G = window.IpdGap; if (!G) return;
    const $ = id => document.getElementById(id), E = v => Ipd.esc(v), base = G.base, can = G.can || {};
    let doctors = null;

    // ── small helpers ──────────────────────────────────────────────────────────────────────────────────────────
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
    const n = id => { const x = v(id); return x === '' ? null : Number(x); };
    const chk = id => !!$(id)?.checked;
    const field = (id, label, input, col = 'col-md-6', req) => `<div class="${col}"><label class="form-label small fw-semibold" for="${id}">${label}${req ? ' <span class="text-danger">*</span>' : ''}</label>${input}</div>`;
    const txt = (id, val = '', ph = '', max = 300) => `<input id="${id}" class="form-control form-control-sm" maxlength="${max}" value="${E(val ?? '')}" placeholder="${E(ph)}" />`;
    const area = (id, val = '', rows = 2) => `<textarea id="${id}" class="form-control form-control-sm" rows="${rows}">${E(val ?? '')}</textarea>`;
    const sel = (id, opts, val, blank = '-- choose --') => `<select id="${id}" class="form-select form-select-sm">${blank ? `<option value="">${blank}</option>` : ''}${opts.map(([k, t]) => `<option value="${E(k)}" ${String(k) === String(val ?? '') ? 'selected' : ''}>${E(t)}</option>`).join('')}</select>`;
    const yn = (id, label) => `<div class="col-6 col-md-3"><label class="form-label small fw-semibold d-block">${label}</label><div class="btn-group btn-group-sm" role="group">
        <input type="radio" class="btn-check" name="${id}" id="${id}Y" value="1"><label class="btn btn-outline-success" for="${id}Y">Yes</label>
        <input type="radio" class="btn-check" name="${id}" id="${id}N" value="0"><label class="btn btn-outline-danger" for="${id}N">No</label></div></div>`;
    const ynv = id => { const c = document.querySelector(`input[name="${id}"]:checked`); return c ? c.value === '1' : null; };
    async function post(action, body, ok, q = '') {
        const r = await Ipd.post(`${base}${action}?id=${G.id}${q}`, body);
        if (!r.success) { Ipd.error(r.error); return null; }
        if (ok) Ipd.toast(ok);
        return r.data || {};
    }
    async function docs() {
        if (doctors) return doctors;
        try { const lk = await Ipd.get(G.admBase + 'PatientLookups'); doctors = (lk.doctors || []).map(d => [d.DoctorId, d.DoctorName || d.FullName]); }
        catch { doctors = []; }
        return doctors;
    }
    const card = (icon, color, title, sub, body, id) => `<div class="reg-section mb-3" ${id ? `id="${id}"` : ''}><div class="reg-section-header"><div class="sec-icon ${color}"><i class="bi ${icon}"></i></div>
        <div class="flex-grow-1"><h6 class="fw-bold mb-0">${title}</h6><small class="text-muted">${sub}</small></div></div><div class="reg-section-body">${body}</div></div>`;

    // ── banner: allergy status, code status, isolation ─────────────────────────────────────────────────────────
    const CODE = { FULL: 'Full resuscitation', DNR: 'DNR (do not resuscitate)', DNI: 'DNI (do not intubate)', DNR_DNI: 'DNR + DNI', LIMITED: 'Limited treatment' };
    const ISO = { CONTACT: 'Contact', DROPLET: 'Droplet', AIRBORNE: 'Airborne', PROTECTIVE: 'Protective (reverse)' };
    function allergyDialog() {
        const none = /^(no known|nkda|nil|none)/i.test(G.allergies || '');
        modal('gapAlgM', '<i class="bi bi-exclamation-triangle me-1 text-danger"></i>Allergy status', `
            <div class="form-check mb-2"><input class="form-check-input" type="checkbox" id="gaNone" ${none ? 'checked' : ''}><label class="form-check-label" for="gaNone">No known allergies (NKDA)</label></div>
            ${field('gaText', 'Allergies (medicines, food, others) and the reaction', area('gaText', none ? '' : G.allergies, 3), 'col-12')}
            <div class="small text-muted mt-1">Write each allergy separated by commas, e.g. "Penicillin (rash), Sulfa, Peanuts". The medicine orders and the MAR are checked against it.</div>`,
            '<button type="button" class="btn btn-danger" id="gaSave">Save</button>', '');
        $('gaNone').addEventListener('change', () => { $('gaText').disabled = chk('gaNone'); });
        $('gaText').disabled = none;
        $('gaSave').onclick = async () => {
            const r = await post('SaveAllergy', { allergies: v('gaText') || null, noKnownAllergy: chk('gaNone') }, 'Allergy status saved');
            if (r) { hide('gapAlgM'); setTimeout(() => location.reload(), 500); }
        };
    }
    async function codeDialog() {
        const ds = await docs();
        let hist = [];
        try { hist = await Ipd.get(`${base}CodeStatus?id=${G.id}`) || []; } catch { /* list only */ }
        modal('gapCodeM', '<i class="bi bi-heart-pulse me-1 text-danger"></i>Code status', `<div class="row g-2">
            ${field('gcCode', 'Code status', sel('gcCode', Object.entries(CODE), G.codeStatus || 'FULL', ''), 'col-md-6', true)}
            ${field('gcDoc', 'Decided by (doctor)', sel('gcDoc', ds, ''), 'col-md-6', true)}
            ${field('gcWith', 'Discussed with', txt('gcWith', '', 'patient / relative name'), 'col-md-6')}
            ${field('gcRel', 'Relation', txt('gcRel', '', 'self, son, wife…', 50), 'col-md-6')}
            ${field('gcWhy', 'Clinical reason', area('gcWhy', ''), 'col-12')}
            ${field('gcLim', 'Limited treatment: what is / is not to be done', area('gcLim', ''), 'col-12')}</div>
            <div class="small text-muted mt-1">A login linked to a doctor records the doctor's own decision. DNR / DNI / limited need with whom it was discussed and the reason.</div>
            ${hist.length ? '<hr><div class="small fw-semibold mb-1">History</div><table class="table table-sm small mb-0"><tbody>' + hist.map(x => `<tr><td>${Ipd.dt(x.RecordedAt)}</td><td><b>${E(CODE[x.CodeStatus] || x.CodeStatus)}</b></td><td>Dr ${E(x.DoctorName)}${x.DiscussedWith ? ' · with ' + E(x.DiscussedWith) + (x.Relation ? ' (' + E(x.Relation) + ')' : '') : ''}${x.Reason ? '<div class="text-muted">' + E(x.Reason) + '</div>' : ''}${x.Limits ? '<div class="text-muted">Limits: ' + E(x.Limits) + '</div>' : ''}</td><td class="text-muted">${E(x.RecordedByName)}</td></tr>`).join('') + '</tbody></table>' : ''}`,
            can.codeStatus && G.open ? '<button type="button" class="btn btn-danger" id="gcSave">Save</button>' : '');
        $('gcSave')?.addEventListener('click', async () => {
            const r = await post('SaveCodeStatus', { codeStatus: v('gcCode'), doctorId: n('gcDoc'), discussedWith: v('gcWith') || null, relation: v('gcRel') || null, reason: v('gcWhy') || null, limits: v('gcLim') || null }, 'Code status saved');
            if (r) { hide('gapCodeM'); setTimeout(() => location.reload(), 500); }
        });
    }
    function isolationDialog() {
        modal('gapIsoM', '<i class="bi bi-shield-exclamation me-1 text-warning"></i>Isolation', `<div class="row g-2">
            ${field('giType', 'Isolation', sel('giType', Object.entries(ISO), G.isolationType || '', 'No isolation (end it)'), 'col-md-5')}
            ${field('giWhy', 'Reason', txt('giWhy', '', 'e.g. MRSA, open TB, H1N1, neutropenia; or why it ends'), 'col-md-7', true)}</div>
            <div class="small text-muted mt-2">Shown on the banner and the bed board: staff use the precautions of the type (PPE, single room / cohort, negative pressure for airborne).</div>`,
            '<button type="button" class="btn btn-warning" id="giSave">Save</button>', '');
        $('giSave').onclick = async () => {
            const r = await post('SaveIsolation', { isolationType: v('giType') || null, reason: v('giWhy') || null }, 'Isolation saved');
            if (r) { hide('gapIsoM'); setTimeout(() => location.reload(), 500); }
        };
    }
    document.addEventListener('click', e => {
        const t = e.target.closest('[data-gap]'); if (!t) return;
        e.preventDefault();
        ({ allergy: () => can.allergy && allergyDialog(), code: codeDialog, isolation: () => can.isolation && isolationDialog(), escalations: () => document.querySelector('[data-bs-target="#tab-nursing"]')?.click() })[t.dataset.gap]?.();
    });

    // ── escalations (Clinical + Nursing tabs) ──────────────────────────────────────────────────────────────────
    async function escalationsHtml() {
        let rows = [];
        try { rows = await Ipd.get(`${base}Escalations?id=${G.id}`) || []; } catch (e) { return `<div class="text-danger small">${E(e.message)}</div>`; }
        const open = rows.filter(r => r.Status !== 'CLOSED');
        const head = (can.escalate && G.open) ? '<button type="button" class="btn btn-sm btn-danger mb-2" data-esc="raise"><i class="bi bi-telephone-outbound me-1"></i>Call the doctor</button>' : '';
        if (!rows.length) return head + '<div class="small text-muted">No escalation. NEWS2 medium / high (or a single red score) calls the consultant automatically.</div>';
        return head + `<div class="table-responsive"><table class="table table-sm align-middle mb-0"><tbody>${rows.slice(0, 10).map(r => `<tr class="${r.Status === 'CLOSED' ? 'text-muted' : ''}">
            <td class="small text-nowrap">${Ipd.dt(r.RaisedAt)}<div class="text-muted">${E(r.RaisedByName)}</div></td>
            <td><span class="badge ${r.RiskLevel === 'HIGH' ? 'text-bg-danger' : r.Source === 'MANUAL' ? 'text-bg-secondary' : 'text-bg-warning'}">${E(r.Source)}${r.Score != null ? ' ' + r.Score : ''}</span> ${E(r.Details || '')}
                ${r.Response ? `<div class="small text-success"><i class="bi bi-reply me-1"></i>${E(r.Response)} · ${E(r.AckByName || '')} ${Ipd.dt(r.AckAt)} (${r.MinutesToAck} min)</div>` : ''}</td>
            <td class="small">${{ OPEN: '<span class="text-danger fw-semibold">waiting for the doctor</span>', ACK: '<span class="text-warning-emphasis">acknowledged</span>', CLOSED: 'closed' }[r.Status]}</td>
            <td class="text-end text-nowrap">${r.Status === 'OPEN' && can.ack ? `<button type="button" class="btn btn-sm btn-success" data-esc="ack" data-eid="${r.EscalationId}">Respond</button>` : ''}
                ${r.Status === 'ACK' && can.escalate ? `<button type="button" class="btn btn-sm btn-light border" data-esc="close" data-eid="${r.EscalationId}">Close</button>` : ''}</td></tr>`).join('')}</tbody></table></div>
            ${open.length ? '' : ''}`;
    }
    async function escalationAction(kind, eid) {
        const label = { raise: ['Call the doctor', 'What you see (vitals, symptoms)'], ack: ['Doctor\'s response', 'Seen / advice / plan (e.g. "Seen, O2 4 l, repeat NEWS2 in 30 min")'], close: ['Close the escalation', 'Outcome (e.g. NEWS2 back to 2)'] }[kind];
        const text = await Ipd.reason(label[0], label[1]); if (!text) return;
        if (await post('EscalationAction', { action: kind.toUpperCase(), escalationId: eid ? Number(eid) : null, text }, 'Saved')) refreshPanels();
    }

    // ── medication reconciliation (Clinical tab) ───────────────────────────────────────────────────────────────
    const ACT = [['CONTINUE', 'Continue'], ['HOLD', 'Hold'], ['CHANGE', 'Change'], ['STOP', 'Stop']];
    async function reconHtml() {
        let rows = [];
        try { rows = await Ipd.get(`${base}MedRecon?id=${G.id}`) || []; } catch (e) { return `<div class="text-danger small">${E(e.message)}</div>`; }
        const one = st => rows.find(r => r.Stage === st);
        const block = st => {
            const r = one(st), lines = r && r.Lines ? JSON.parse(r.Lines) : [];
            return `<div class="col-12 col-lg-6"><div class="ipdx-card p-2 h-100"><div class="d-flex justify-content-between align-items-center"><b>${st === 'ADMISSION' ? 'At admission (home medicines)' : 'At discharge'}</b>
                ${can.medRecon && G.open ? `<button type="button" class="btn btn-sm btn-outline-primary" data-recon="${st}">${r ? 'Redo' : 'Record'}</button>` : ''}</div>
                ${!r ? `<div class="small ${st === 'ADMISSION' ? 'text-danger' : 'text-muted'} mt-1">${st === 'ADMISSION' ? 'Not recorded: needed before the discharge summary is signed.' : 'Not recorded.'}</div>`
                    : r.NoHomeMeds ? '<div class="small text-success mt-1">No regular medicines.</div>'
                    : `<table class="table table-sm small mb-0 mt-1"><tbody>${lines.map(l => `<tr><td>${E(l.drug)}</td><td>${E(l.dose || '')} ${E(l.frequency || '')}</td><td><b>${E(l.action)}</b>${l.note ? ' · ' + E(l.note) : ''}</td></tr>`).join('')}</tbody></table>`}
                ${r ? `<div class="small text-muted">${Ipd.dt(r.DoneAt)} · ${E(r.DoctorName ? 'Dr ' + r.DoctorName : r.DoneByName)}${r.Source ? ' · from ' + E(r.Source) : ''}</div>` : ''}</div></div>`;
        };
        return `<div class="row g-2">${block('ADMISSION')}${block('DISCHARGE')}</div>`;
    }
    function reconDialog(stage) {
        const line = (i) => `<div class="row g-1 mb-1 rc-line" data-i="${i}"><div class="col-md-4">${txt('rcD' + i, '', 'medicine')}</div><div class="col-md-2">${txt('rcO' + i, '', 'dose', 60)}</div>
            <div class="col-md-2">${txt('rcF' + i, '', 'frequency', 40)}</div><div class="col-md-2">${sel('rcA' + i, ACT, 'CONTINUE', '')}</div><div class="col-md-2">${txt('rcN' + i, '', 'why (stop / change / hold)', 200)}</div></div>`;
        let count = 3;
        modal('gapRcM', `Medication reconciliation · ${stage === 'ADMISSION' ? 'admission' : 'discharge'}`, `
            <div class="form-check mb-2"><input class="form-check-input" type="checkbox" id="rcNone"><label class="form-check-label" for="rcNone">No regular medicines</label></div>
            <div id="rcLines">${[0, 1, 2].map(line).join('')}</div><button type="button" class="btn btn-sm btn-link px-0" id="rcAdd">+ another medicine</button>
            <div class="row g-2 mt-1">${field('rcSrc', 'Source', txt('rcSrc', '', 'patient, attendant, old prescription', 100))}${field('rcNotes', 'Notes', txt('rcNotes', '', '', 500))}</div>`,
            '<button type="button" class="btn btn-primary" id="rcSave">Save</button>', 'modal-xl');
        $('rcAdd').onclick = () => { $('rcLines').insertAdjacentHTML('beforeend', line(count++)); };
        $('rcSave').onclick = async () => {
            const lines = [...document.querySelectorAll('.rc-line')].map(x => { const i = x.dataset.i; return { drug: v('rcD' + i), dose: v('rcO' + i), frequency: v('rcF' + i), action: v('rcA' + i), note: v('rcN' + i) }; }).filter(l => l.drug);
            const r = await post('SaveMedRecon', { stage, noHomeMeds: chk('rcNone'), lines: JSON.stringify(lines), source: v('rcSrc') || null, notes: v('rcNotes') || null }, 'Reconciliation saved');
            if (r) { hide('gapRcM'); refreshPanels(); }
        };
    }

    // ── transfusion, restraint, newborn (Nursing tab) ──────────────────────────────────────────────────────────
    const COMP = { WB: 'Whole blood', PRBC: 'Packed red cells', FFP: 'Fresh frozen plasma', PLT: 'Platelets (RDP)', SDP: 'Platelets (SDP / apheresis)', CRYO: 'Cryoprecipitate' };
    const GROUPS = ['A+', 'A-', 'B+', 'B-', 'AB+', 'AB-', 'O+', 'O-'].map(g => [g, g]);
    let S = null;
    async function safetyHtml() {
        try { S = await Ipd.get(`${base}Safety?id=${G.id}`); } catch (e) { return `<div class="text-danger small">${E(e.message)}</div>`; }
        const ts = S.transfusions || [], rs = S.restraints || [], mother = (S.mother || [])[0], babies = S.babies || [];
        const tRow = t => {
            const next = { ORDERED: ['check', 'Bedside check'], CHECKED: ['start', 'Start'], STARTED: [t.Vitals15 ? 'complete' : 'vitals15', t.Vitals15 ? 'Complete' : '15-min vitals'] }[t.Status];
            return `<tr class="${['COMPLETED', 'CANCELLED', 'STOPPED'].includes(t.Status) ? 'text-muted' : ''}"><td><b>${E(COMP[t.Component] || t.Component)}</b> × ${t.Units}<div class="small text-muted">${E(t.Indication)} · Dr ${E(t.DoctorName)} · ${Ipd.dt(t.OrderedAt)}</div></td>
                <td class="small">Patient ${E(t.PatientBloodGroup)}${t.BagNo ? ` · bag ${E(t.BagNo)} ${E(t.BagBloodGroup)} · exp ${Ipd.date(t.BagExpiry)} · checked with ${E(t.CheckedBy2Name)}` : ''}</td>
                <td class="small">${t.Status.toLowerCase()}${t.Vitals15Due ? ' <span class="text-danger fw-semibold">· 15-min vitals due</span>' : ''}${t.Reaction ? `<div class="text-danger">REACTION: ${E(t.ReactionType)} - ${E(t.ReactionAction)}</div>` : ''}${t.StartAt ? `<div>${Ipd.dt(t.StartAt)}${t.EndAt ? ' → ' + Ipd.dt(t.EndAt) : ''}${t.VolumeMl ? ' · ' + t.VolumeMl + ' ml' : ''}</div>` : ''}</td>
                <td class="text-end text-nowrap">${can.transfusion && G.open && next ? `<button type="button" class="btn btn-sm btn-primary" data-tr="${next[0]}" data-tid="${t.TransfusionId}">${next[1]}</button>` : ''}
                    ${can.transfusion && G.open && t.Status === 'STARTED' ? `<button type="button" class="btn btn-sm btn-outline-danger" data-tr="reaction" data-tid="${t.TransfusionId}">Reaction</button>` : ''}
                    ${can.transfusion && G.open && ['ORDERED', 'CHECKED'].includes(t.Status) ? `<button type="button" class="btn btn-sm btn-link text-danger p-0" data-tr="cancel" data-tid="${t.TransfusionId}">Cancel</button>` : ''}</td></tr>`;
        };
        const rRow = r => `<tr class="${r.Status === 'ENDED' ? 'text-muted' : ''}"><td><b>${r.Kind === 'PHYSICAL' ? 'Physical' : 'Chemical'}</b> ${E(r.Device || '')}<div class="small text-muted">${E(r.Reason)} · tried: ${E(r.AlternativesTried)} · Dr ${E(r.DoctorName)}</div></td>
            <td class="small">${Ipd.dt(r.StartAt)}${r.EndAt ? ' → ' + Ipd.dt(r.EndAt) + ' · ' + E(r.EndReason) : `<div class="${r.CheckOverdue ? 'text-danger fw-semibold' : ''}">next check ${Ipd.dt(r.NextCheckDue)}</div><div class="${r.OrderExpired ? 'text-danger fw-semibold' : 'text-muted'}">order valid to ${Ipd.dt(r.OrderValidTo)}</div>`}</td>
            <td class="text-end text-nowrap">${can.restraint && G.open && r.Status === 'ACTIVE' ? `<button type="button" class="btn btn-sm btn-primary" data-rs="check" data-rid="${r.RestraintId}">Check</button>
                <button type="button" class="btn btn-sm btn-light border" data-rs="renew" data-rid="${r.RestraintId}">Renew</button>
                <button type="button" class="btn btn-sm btn-outline-success" data-rs="end" data-rid="${r.RestraintId}">Release</button>` : ''}</td></tr>`;
        let h = `<div class="d-flex flex-wrap gap-2 mb-2">${can.transfusion && G.open ? '<button type="button" class="btn btn-sm btn-outline-danger" data-tr="order"><i class="bi bi-droplet-fill me-1"></i>Order transfusion</button>' : ''}
            ${can.restraint && G.open && !rs.some(r => r.Status === 'ACTIVE') ? '<button type="button" class="btn btn-sm btn-outline-secondary" data-rs="start"><i class="bi bi-person-lock me-1"></i>Apply restraint</button>' : ''}
            ${can.newborn && G.open && !mother ? '<button type="button" class="btn btn-sm btn-outline-primary" data-nb="link"><i class="bi bi-person-hearts me-1"></i>Link to the mother (newborn)</button>' : ''}</div>`;
        if (ts.length) h += `<div class="small fw-semibold">Blood transfusion</div><div class="table-responsive"><table class="table table-sm align-middle mb-2"><tbody>${ts.map(tRow).join('')}</tbody></table></div>`;
        if (rs.length) h += `<div class="small fw-semibold">Restraint</div><div class="table-responsive"><table class="table table-sm align-middle mb-2"><tbody>${rs.map(rRow).join('')}</tbody></table></div>`;
        if (mother) h += `<div class="small"><i class="bi bi-person-hearts me-1"></i>Newborn of <a href="${E(S.links.mother)}">${E(mother.MotherName)} (${E(mother.MotherIpNo)})</a>: born ${Ipd.dt(mother.BirthAt)}, ${mother.BirthWeightKg} kg, ${E(mother.DeliveryType)}${mother.Apgar1 != null ? `, Apgar ${mother.Apgar1}/${mother.Apgar5 ?? '-'}` : ''}${mother.GestationWeeks ? `, ${mother.GestationWeeks} weeks` : ''}</div>`;
        if (babies.length) h += `<div class="small"><i class="bi bi-person-hearts me-1"></i>Babies: ${babies.map(b => `<a href="${E(S.links['baby' + b.AdmissionId])}">${E(b.BabyName)} (${E(b.BabyIpNo)})</a> ${b.BirthWeightKg} kg`).join(', ')}</div>`;
        if (!ts.length && !rs.length && !mother && !babies.length) h += '<div class="small text-muted">No transfusion, restraint or newborn link on this admission.</div>';
        return h;
    }
    async function transfusionStep(step, tid) {
        if (step === 'cancel') { const reason = await Ipd.reason('Cancel the transfusion?', 'Reason'); if (reason && await post('SaveTransfusion', { action: 'CANCEL', transfusionId: Number(tid), reason }, 'Cancelled')) refreshPanels(); return; }
        let body = '', title = '';
        if (step === 'order') {
            const ds = await docs();
            title = 'Order blood transfusion';
            body = `<div class="row g-2">${field('tfComp', 'Component', sel('tfComp', Object.entries(COMP), 'PRBC', ''), 'col-md-5', true)}${field('tfUnits', 'Units', '<input id="tfUnits" type="number" min="1" max="20" value="1" class="form-control form-control-sm">', 'col-md-2', true)}
                ${field('tfPg', 'Patient blood group', sel('tfPg', GROUPS, G.bloodGroup || ''), 'col-md-5', true)}${field('tfInd', 'Indication', txt('tfInd', '', 'e.g. Hb 6.2 g/dL symptomatic'), 'col-12', true)}
                ${field('tfDoc', 'Ordered by', sel('tfDoc', ds, ''), 'col-md-6', true)}${field('tfCon', 'Consent signed by', txt('tfCon', '', 'patient / relative'), 'col-md-4', true)}${field('tfRel', 'Relation', txt('tfRel', '', '', 50), 'col-md-2')}</div>`;
        } else if (step === 'check') {
            title = 'Bedside check (two people)';
            body = `<div class="alert alert-info py-2 small">Check at the bedside with a second person: patient identity (wristband), bag number, blood group, expiry and the compatibility report.</div><div class="row g-2">
                ${field('tfBag', 'Bag no.', txt('tfBag', '', '', 40), 'col-md-4', true)}${field('tfBg', 'Bag blood group', sel('tfBg', GROUPS, ''), 'col-md-4', true)}${field('tfExp', 'Bag expiry', '<input id="tfExp" type="date" class="form-control form-control-sm">', 'col-md-4', true)}
                ${field('tfX', 'Crossmatch / compatibility no.', txt('tfX', '', '', 40), 'col-md-6', true)}${field('tfC2', 'Second checker', txt('tfC2', '', 'name'), 'col-md-6', true)}</div>`;
        } else if (['start', 'vitals15', 'complete', 'reaction'].includes(step)) {
            title = { start: 'Start: vitals before', vitals15: 'Vitals 15 minutes after the start', complete: 'Complete: vitals at the end', reaction: 'Transfusion reaction: stop' }[step];
            body = `<div class="row g-2">${field('tfVit', 'Vitals (BP, pulse, temperature, RR, SpO2)', txt('tfVit', '', 'BP 120/80, P 88, T 98.6, RR 18, SpO2 98', 200), 'col-12', step !== 'reaction')}
                ${['complete', 'reaction'].includes(step) ? field('tfVol', 'Volume transfused (ml)', '<input id="tfVol" type="number" min="1" max="2000" class="form-control form-control-sm">', 'col-md-4', step === 'complete') : ''}
                ${step === 'reaction' ? field('tfRt', 'Reaction', txt('tfRt', '', 'fever, chills, rash, breathlessness, hypotension', 100), 'col-md-8', true) + field('tfRa', 'What was done', area('tfRa', 'Transfusion stopped, line kept open with NS, doctor informed, bag and sample sent to the blood bank'), 'col-12', true) : ''}</div>`;
        }
        modal('gapTfM', title, body, '<button type="button" class="btn btn-danger" id="tfSave">Save</button>');
        $('tfSave').onclick = async () => {
            const b = { action: step.toUpperCase(), transfusionId: tid ? Number(tid) : null };
            if (step === 'order') Object.assign(b, { component: v('tfComp'), units: n('tfUnits'), patientBloodGroup: v('tfPg') || null, indication: v('tfInd'), doctorId: n('tfDoc'), consentBy: v('tfCon'), consentRelation: v('tfRel') || null });
            if (step === 'check') Object.assign(b, { bagNo: v('tfBag'), bagBloodGroup: v('tfBg'), bagExpiry: v('tfExp') || null, crossmatchNo: v('tfX'), checkedBy2Name: v('tfC2') });
            if (['start', 'vitals15', 'complete', 'reaction'].includes(step)) Object.assign(b, { vitals: v('tfVit') || null, volumeMl: n('tfVol'), reactionType: v('tfRt') || null, reactionAction: v('tfRa') || null });
            if (await post('SaveTransfusion', b, 'Saved')) { hide('gapTfM'); refreshPanels(); }
        };
    }
    async function restraintStep(step, rid) {
        if (step === 'end') {
            const reason = await Ipd.reason('Release the restraint', 'Why (calm, oriented, no longer needed)');
            if (reason && await post('SaveRestraint', { action: 'END', restraintId: Number(rid), reason }, 'Released')) refreshPanels();
            return;
        }
        let body;
        if (step === 'renew') {
            const ds = await docs();
            body = `<div class="row g-2">${field('rsDoc', 'Renewed by (doctor)', sel('rsDoc', ds, ''), 'col-md-6', true)}${field('rsWhy', 'Why it is still needed', txt('rsWhy', ''), 'col-md-6', true)}</div>`;
        } else if (step === 'start') {
            const ds = await docs();
            body = `<div class="row g-2">${field('rsKind', 'Kind', sel('rsKind', [['PHYSICAL', 'Physical'], ['CHEMICAL', 'Chemical']], 'PHYSICAL', ''), 'col-md-4', true)}${field('rsDev', 'Device / drug', txt('rsDev', '', 'wrist restraint, mittens / haloperidol 5 mg IM', 100), 'col-md-8')}
                ${field('rsWhy', 'Why it is needed', txt('rsWhy', '', 'risk to self / others, pulling lines'), 'col-12', true)}${field('rsAlt', 'Alternatives tried first', txt('rsAlt', '', 'attendant, reorientation, sitter, bed alarm'), 'col-12', true)}
                ${field('rsDoc', 'Ordered by', sel('rsDoc', ds, ''), 'col-md-6', true)}${field('rsFam', 'Family informed', txt('rsFam', '', 'name / relation', 150), 'col-md-6')}</div>
                <div class="small text-muted mt-1">Checks every 2 hours (circulation, skin, food / toilet / position, still needed); the order is valid for 24 hours, then the doctor renews it.</div>`;
        } else {
            body = `<div class="row g-2">${yn('rcCirc', 'Circulation fine')}${yn('rcSkin', 'Skin fine')}${yn('rcNeeds', 'Needs met (fluids, toilet, position)')}${yn('rcStill', 'Still needed')}
                ${field('rcNote', 'Notes', txt('rcNote', ''), 'col-12')}</div>`;
        }
        modal('gapRsM', step === 'start' ? 'Apply restraint (doctor\'s order)' : step === 'renew' ? 'Renew the restraint order (24 hours)' : 'Restraint check', body, '<button type="button" class="btn btn-primary" id="rsSave">Save</button>');
        $('rsSave').onclick = async () => {
            const b = step === 'renew' ? { action: 'RENEW', restraintId: Number(rid), doctorId: n('rsDoc'), reason: v('rsWhy') }
                : step === 'start'
                ? { action: 'START', kind: v('rsKind'), device: v('rsDev') || null, reason: v('rsWhy'), alternativesTried: v('rsAlt'), doctorId: n('rsDoc'), familyInformed: v('rsFam') || null }
                : { action: 'CHECK', restraintId: Number(rid), circulationOk: ynv('rcCirc'), skinOk: ynv('rcSkin'), needsMet: ynv('rcNeeds'), stillNeeded: ynv('rcStill'), notes: v('rcNote') || null };
            if (await post('SaveRestraint', b, 'Saved')) { hide('gapRsM'); refreshPanels(); }
        };
    }
    function newbornDialog() {
        modal('gapNbM', 'Link this newborn to the mother\'s admission', `<div class="row g-2">
            ${field('nbMother', 'Mother\'s IP no.', txt('nbMother', '', 'IP/…', 40), 'col-md-6', true)}${field('nbAt', 'Time of birth', `<input id="nbAt" type="datetime-local" class="form-control form-control-sm" value="${Ipd.local()}">`, 'col-md-6', true)}
            ${field('nbWt', 'Birth weight (kg)', '<input id="nbWt" type="number" step="0.01" min="0.3" max="7" class="form-control form-control-sm">', 'col-md-4', true)}
            ${field('nbDel', 'Delivery', sel('nbDel', [['NORMAL', 'Normal'], ['ASSISTED', 'Assisted (vacuum / forceps)'], ['LSCS', 'LSCS']], 'NORMAL', ''), 'col-md-4', true)}
            ${field('nbGa', 'Gestation (weeks)', '<input id="nbGa" type="number" min="20" max="45" class="form-control form-control-sm">', 'col-md-4')}
            ${field('nbA1', 'Apgar 1 min', '<input id="nbA1" type="number" min="0" max="10" class="form-control form-control-sm">', 'col-md-3')}${field('nbA5', 'Apgar 5 min', '<input id="nbA5" type="number" min="0" max="10" class="form-control form-control-sm">', 'col-md-3')}
            ${field('nbOrd', 'Baby no. (twins)', '<input id="nbOrd" type="number" min="1" max="5" value="1" class="form-control form-control-sm">', 'col-md-3')}${field('nbRem', 'Remarks', txt('nbRem', ''), 'col-md-3')}</div>
            <div class="small text-muted mt-1">Register the baby as a patient first (normal registration) and admit it (cradle beside the mother, or NICU); then link it here.</div>`,
            '<button type="button" class="btn btn-primary" id="nbSave">Link</button>');
        $('nbSave').onclick = async () => {
            const r = await post('LinkNewborn', { motherIpNo: v('nbMother'), birthAt: v('nbAt') || null, birthWeightKg: n('nbWt'), deliveryType: v('nbDel'), gestationWeeks: n('nbGa'), apgar1: n('nbA1'), apgar5: n('nbA5'), babyOrder: n('nbOrd') || 1, remarks: v('nbRem') || null }, 'Newborn linked');
            if (r) { hide('gapNbM'); refreshPanels(); }
        };
    }

    // ── after the discharge: supplementary bill / credit note (Billing tab) ────────────────────────────────────
    const HEADS = [['LAB', 'Laboratory'], ['RADIOLOGY', 'Radiology / Imaging'], ['PHARMACY', 'Pharmacy'], ['CONSUMABLE', 'Consumables'], ['PROCEDURE', 'Procedures'], ['OT', 'Operation Theatre'],
        ['DOCTOR', 'Doctor Visits'], ['BED', 'Bed & Nursing'], ['ICU', 'ICU'], ['SERVICE', 'Other Services']];
    let A = null;
    async function adjustHtml() {
        try { A = await Ipd.get(`${base}BillAdjustments?id=${G.id}`); } catch (e) { return `<div class="text-danger small">${E(e.message)}</div>`; }
        const docs = A.docs || [], bal = ((A.balance || [])[0] || {}).BalanceNow;
        let h = `<div class="d-flex flex-wrap gap-2 align-items-center mb-2">
            ${can.billAdjust ? '<button type="button" class="btn btn-sm btn-outline-primary" data-adj="SUPP"><i class="bi bi-plus-circle me-1"></i>Supplementary bill</button><button type="button" class="btn btn-sm btn-outline-success" data-adj="CRED"><i class="bi bi-dash-circle me-1"></i>Credit note</button>' : ''}
            <span class="small ms-auto">Balance on the bill now: <b class="${bal > 0 ? 'text-danger' : 'text-success'}">${bal > 0 ? Ipd.money(bal) + ' due' : bal < 0 ? Ipd.money(-bal) + ' refundable' : 'settled'}</b></span></div>`;
        h += docs.length ? `<table class="table table-sm align-middle mb-0"><tbody>${docs.map(d => `<tr class="${d.Status === 'CANCELLED' ? 'text-muted text-decoration-line-through' : ''}">
            <td><span class="badge ${d.Kind === 'SUPP' ? 'text-bg-primary' : 'text-bg-success'}">${d.Kind === 'SUPP' ? 'Supplementary' : 'Credit note'}</span> <b class="font-monospace">${E(d.DocNo)}</b><div class="small text-muted">${Ipd.dt(d.DocAt)} · ${E(d.CreatedByName)}</div></td>
            <td class="small">${E(d.Reason)}${d.CancelReason ? `<div>cancelled: ${E(d.CancelReason)}</div>` : ''}</td><td class="text-end fw-semibold">${Ipd.money(d.Net)}</td>
            <td class="text-end text-nowrap"><a class="btn btn-sm btn-light border" target="_blank" href="${E(A.prints[String(d.AdjId)])}"><i class="bi bi-printer"></i></a>
                ${d.Status === 'ACTIVE' && can.billAdjustCancel ? `<button type="button" class="btn btn-sm btn-link text-danger p-0 ms-1" data-adjcancel="${d.AdjId}">Cancel</button>` : ''}</td></tr>`).join('')}</tbody></table>`
            : '<div class="small text-muted">Charges found after the discharge (late reports, items missed) go on a supplementary bill; a correction in the patient\'s favour is a credit note. The final bill stays as it is.</div>';
        return h;
    }
    function adjustDialog(kind) {
        const credit = kind === 'CRED', lines = (A && A.billLines) || [];
        const line = i => `<div class="row g-1 mb-1 adj-line" data-i="${i}">
            ${credit ? `<div class="col-md-4">${sel('ajL' + i, lines.map(l => [l.BillLineId, `${l.HeadName}: ${l.ItemName} (${Ipd.num(l.Net)})`]), '', 'a bill line (optional)')}</div>` : ''}
            <div class="col-md-2">${sel('ajH' + i, HEADS, credit ? 'SERVICE' : 'LAB', '')}</div><div class="col-md-${credit ? 2 : 4}">${txt('ajN' + i, '', 'particulars', 250)}</div>
            <div class="col-md-1"><input id="ajQ${i}" type="number" min="0.001" step="any" value="1" class="form-control form-control-sm" title="Qty"></div>
            <div class="col-md-2"><input id="ajR${i}" type="number" min="0.01" step="0.01" class="form-control form-control-sm" placeholder="rate"></div>
            <div class="col-md-1"><input id="ajG${i}" type="number" min="0" max="28" step="0.01" value="0" class="form-control form-control-sm" title="GST %"></div></div>`;
        let count = 2;
        modal('gapAdjM', credit ? 'Credit note (in the patient\'s favour)' : 'Supplementary bill (charges after the discharge)', `
            <div id="ajLines">${[0, 1].map(line).join('')}</div><button type="button" class="btn btn-sm btn-link px-0" id="ajAdd">+ another line</button>
            ${field('ajWhy', 'Reason', txt('ajWhy', '', credit ? 'e.g. returned medicines, wrong charge on the bill' : 'e.g. culture report after discharge'), 'col-12', true)}
            <div class="small text-muted mt-1">${credit ? 'Posted as a credit note against the final bill; the over-payment can then be refunded on the Billing tab.' : 'Posted as a sales voucher against the patient; collect it with Collect Payment.'}</div>`,
            `<button type="button" class="btn ${credit ? 'btn-success' : 'btn-primary'}" id="ajSave">Save</button>`, 'modal-xl');
        if (credit) document.getElementById('ajLines').addEventListener('change', e => {
            const s = e.target.closest('select[id^="ajL"]'); if (!s) return;
            const i = s.id.slice(3), l = lines.find(x => String(x.BillLineId) === s.value); if (!l) return;
            $('ajH' + i).value = l.Head; $('ajN' + i).value = l.ItemName; $('ajR' + i).value = l.Rate; $('ajQ' + i).value = 1; $('ajG' + i).value = l.GstPercent || 0;
        });
        $('ajAdd').onclick = () => { $('ajLines').insertAdjacentHTML('beforeend', line(count++)); };
        $('ajSave').onclick = async () => {
            const ls = [...document.querySelectorAll('.adj-line')].map(x => { const i = x.dataset.i; return { head: v('ajH' + i), itemName: v('ajN' + i), qty: n('ajQ' + i), rate: n('ajR' + i), gstPercent: n('ajG' + i) || 0, billLineId: credit ? n('ajL' + i) : null }; })
                .filter(l => l.itemName && l.rate);
            if (!(await Ipd.confirm(credit ? 'Make the credit note?' : 'Make the supplementary bill?', 'It is posted to the accounts now (cancel it later with a reason if needed).', 'Save'))) return;
            const r = await post('SaveBillAdjustment', { kind, lines: JSON.stringify(ls), reason: v('ajWhy') }, (credit ? 'Credit note ' : 'Supplementary bill ') + 'saved');
            if (r) { hide('gapAdjM'); setTimeout(() => location.reload(), 600); }
        };
    }

    // ── panels ─────────────────────────────────────────────────────────────────────────────────────────────────
    function ensure(tabId, panelId, html) {
        const tab = $(tabId); if (!tab) return null;
        let p = $(panelId);
        if (!p) { p = document.createElement('div'); p.id = panelId; tab.prepend(p); }
        p.innerHTML = html;
        return p;
    }
    async function refreshPanels() {
        if ($('tab-clinical')) {
            ensure('tab-clinical', 'gapClin', card('bi-shield-check', 'red', 'Safety & records', 'Escalations to the doctor and medication reconciliation (NABH)',
                '<div class="small fw-semibold mb-1">Escalations</div><div id="gapEscC" class="mb-3"><span class="small text-muted">Loading…</span></div><div class="small fw-semibold mb-1">Medication reconciliation</div><div id="gapRecon"><span class="small text-muted">Loading…</span></div>'));
            const [e1, r1] = await Promise.all([escalationsHtml(), reconHtml()]);
            if ($('gapEscC')) $('gapEscC').innerHTML = e1;
            if ($('gapRecon')) $('gapRecon').innerHTML = r1;
        }
        if ($('tab-nursing')) {
            ensure('tab-nursing', 'gapNurse', card('bi-shield-plus', 'red', 'Escalation, transfusion, restraint', 'Call the doctor; blood transfusion with the bedside check; restraint with 2-hourly checks; newborn link',
                '<div id="gapEscN" class="mb-3"><span class="small text-muted">Loading…</span></div><div id="gapSafety"><span class="small text-muted">Loading…</span></div>'));
            const [e2, s2] = await Promise.all([escalationsHtml(), safetyHtml()]);
            if ($('gapEscN')) $('gapEscN').innerHTML = e2;
            if ($('gapSafety')) $('gapSafety').innerHTML = s2;
        }
        if ($('tab-billing') && G.status === 'DISCHARGED') {
            ensure('tab-billing', 'gapAdj', card('bi-receipt', 'blue', 'After the discharge', 'Supplementary bill / credit note against the final bill', '<div id="gapAdjBody"><span class="small text-muted">Loading…</span></div>'));
            const a = await adjustHtml();
            if ($('gapAdjBody')) $('gapAdjBody').innerHTML = a;
        }
    }
    document.addEventListener('click', e => {
        const t = e.target.closest('[data-esc],[data-recon],[data-tr],[data-rs],[data-nb],[data-adj],[data-adjcancel]'); if (!t) return;
        if (t.dataset.esc) escalationAction(t.dataset.esc, t.dataset.eid);
        else if (t.dataset.recon) reconDialog(t.dataset.recon);
        else if (t.dataset.tr) transfusionStep(t.dataset.tr, t.dataset.tid);
        else if (t.dataset.rs) restraintStep(t.dataset.rs, t.dataset.rid);
        else if (t.dataset.nb) newbornDialog();
        else if (t.dataset.adj) adjustDialog(t.dataset.adj);
        else if (t.dataset.adjcancel) (async () => {
            const reason = await Ipd.reason('Cancel this document?', 'Reason (the voucher is reversed)'); if (!reason) return;
            const r = await Ipd.post(`${base}CancelBillAdjustment?adjId=${t.dataset.adjcancel}`, { reason });
            if (!r.success) { Ipd.error(r.error); return; }
            Ipd.toast('Cancelled'); setTimeout(() => location.reload(), 600);
        })();
    });
    refreshPanels();
})();
