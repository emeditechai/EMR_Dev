/* IPD Patient > OT tab (Phase 8, SQLScripts/2492). Config window.IpdOt = { id, base, open, consultant, diagnosis, can: {...} }.
   Flow of a booking: book -> consents -> pre-op checklist -> patient in OT -> WHO Sign In -> anaesthesia start -> WHO Time Out -> incision
   -> closure -> WHO Sign Out -> out of OT -> surgery note signed -> complete -> OT charges. Every rule is checked again in the procedures. */
(function () {
    'use strict';
    const C = window.IpdOt; if (!C || !document.getElementById('tab-ot')) return;
    const E = v => Ipd.esc(v), $ = id => document.getElementById(id), base = C.base;
    const PH = { PREOP: 'Pre-op checklist', SIGNIN: 'WHO Sign In', TIMEOUT: 'WHO Time Out', SIGNOUT: 'WHO Sign Out' };
    const PHASES = ['PREOP', 'SIGNIN', 'TIMEOUT', 'SIGNOUT'];
    const TIMES = [['InOtAt', 'In OT'], ['AnaesStartAt', 'Anaesthesia start'], ['IncisionAt', 'Incision'], ['ClosureAt', 'Closure'],
                   ['AnaesEndAt', 'Anaesthesia end'], ['OutOtAt', 'Out of OT'], ['RecoveryOutAt', 'Out of recovery']];
    let D = null, L = null, loaded = false;

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
    const num = id => v(id) === '' ? null : Number(v(id));
    const field = (id, label, input, col = 'col-md-4') => `<div class="${col}"><label class="form-label small fw-semibold" for="${id}">${label}</label>${input}</div>`;
    const txt = (id, val, max = 300, ph = '') => `<input id="${id}" class="form-control form-control-sm" maxlength="${max}" value="${E(val ?? '')}" placeholder="${E(ph)}" />`;
    const area = (id, val, rows = 3) => `<textarea id="${id}" class="form-control form-control-sm" rows="${rows}">${E(val ?? '')}</textarea>`;
    const nbox = (id, val, min, max, step = 1) => `<input id="${id}" type="number" class="form-control form-control-sm" min="${min}" max="${max}" step="${step}" value="${val ?? ''}" />`;
    const of = (rows, key) => (rows || []).filter(r => r.OtBookingId === key);
    const consentOf = (b, purpose) => of(D.consents, b.OtBookingId).some(k => purpose === 'SURG' ? /urg|perat/i.test(k.ConsentType) : /naesth|nesth/i.test(k.ConsentType));

    async function load() {
        try {
            [D, L] = await Promise.all([Ipd.get(base + 'Data?id=' + C.id), L ? Promise.resolve(L) : IpdOtBook.lookups(base)]);
            render();
        } catch (e) { $('otList').innerHTML = `<div class="alert alert-danger m-0">${E(e.message)}</div>`; }
    }

    // ── cards ──────────────────────────────────────────────────────────────────────────────────────────────────
    function render() {
        $('otBookBtn').classList.toggle('d-none', !(C.open && C.can.book));
        const list = D.bookings || [];
        if (!list.length) { $('otList').innerHTML = '<div class="ipd-soon"><div class="fs-3 mb-2"><i class="bi bi-heart-pulse"></i></div><div class="fw-semibold">No OT booked for this patient.</div></div>'; return; }
        $('otList').innerHTML = list.map(card).join('');
    }

    function steps(b) {
        const done = new Set(of(D.checklists, b.OtBookingId).map(c => c.Phase));
        const note = of(D.notes, b.OtBookingId)[0], an = of(D.anaesthesia, b.OtBookingId)[0];
        const s = [
            ['Consent', b.HasSurgicalConsent && (!b.AnaesthetistId || b.HasAnaesConsent)],
            ['Pre-op', done.has('PREOP')], ['In OT', !!b.InOtAt], ['Sign In', done.has('SIGNIN')], ['Time Out', done.has('TIMEOUT')],
            ['Sign Out', done.has('SIGNOUT')], ['Note signed', note && note.Status === 'SIGNED'],
            ...(b.AnaesthesiaTypeId ? [['Anaesthesia signed', an && an.SignedAt]] : []),
            ['Completed', b.Status === 'COMPLETED'], ['Charges', b.ChargesPosted]
        ];
        let next = b.Status !== 'CANCELLED';
        return s.map(([t, ok]) => { const cls = ok ? 'done' : (next ? (next = false, 'next') : ''); return `<span class="ot-step ${cls}"><i class="bi ${ok ? 'bi-check-circle-fill' : 'bi-circle'}"></i>${t}</span>`; }).join('');
    }

    function card(b) {
        const id = b.OtBookingId, st = b.Status, open = C.open && st !== 'CANCELLED';
        const done = new Set(of(D.checklists, id).map(c => c.Phase));
        const nextPhase = PHASES.find(p => !done.has(p));
        const note = of(D.notes, id)[0], an = of(D.anaesthesia, id)[0];
        const imps = of(D.implants, id).filter(i => i.Status === 'ACTIVE');
        const charges = (D.charges || []).filter(c => c.OtBookingId === id && c.Status === 'POSTED');
        const btn = (act, icon, label, cls = 'outline-secondary') => `<button type="button" class="btn btn-sm btn-${cls}" data-act="${act}" data-id="${id}"><i class="bi ${icon} me-1"></i>${label}</button>`;
        const a = [];
        if (open && st === 'SCHEDULED' && C.can.book) a.push(btn('edit', 'bi-pencil', 'Change'), btn('cancel', 'bi-x-octagon', 'Cancel', 'outline-danger'));
        if (open && st !== 'COMPLETED' && C.can.consent) a.push(btn('consent', 'bi-pen', 'Record consent'));
        if (open && st !== 'COMPLETED' && nextPhase && C.can.checklist && (nextPhase === 'PREOP' || st === 'IN_OT')) a.push(btn('check:' + nextPhase, 'bi-ui-checks', PH[nextPhase], 'outline-primary'));
        if (open && st !== 'COMPLETED' && C.can.progress) a.push(btn('times', 'bi-clock-history', st === 'SCHEDULED' ? 'Patient in OT' : 'OT times', 'outline-danger'));
        if (open && st !== 'SCHEDULED' && (C.can.note || C.can.sign)) a.push(btn('note', 'bi-journal-medical', note ? (note.Status === 'SIGNED' ? 'Surgery note (signed)' : 'Surgery note (draft)') : 'Surgery note'));
        if (open && b.AnaesthesiaTypeId && (C.can.anaesthesia || an)) a.push(btn('anaes', 'bi-lungs', an && an.SignedAt ? 'Anaesthesia record (signed)' : 'Anaesthesia record'));
        if (open && st !== 'SCHEDULED' && C.can.implant) a.push(btn('implant', 'bi-nut', 'Implants & consumables'));
        if (open && st === 'IN_OT' && C.can.progress && done.has('SIGNOUT') && b.OutOtAt) a.push(btn('complete', 'bi-check2-circle', 'Complete surgery', 'success'));
        if (open && st === 'COMPLETED' && !b.ChargesPosted && C.can.charge && C.open) a.push(btn('charges', 'bi-cash-stack', 'Post OT charges', 'success'));
        if (open && b.ChargesPosted && C.can.reverse) a.push(btn('reverse', 'bi-arrow-counterclockwise', 'Reverse OT charges', 'outline-danger'));
        a.push(btn('print', 'bi-printer', 'OT record'));
        const times = TIMES.filter(([k]) => b[k]).map(([k, t]) => `<div><span class="text-muted">${t}</span><b>${Ipd.dt(b[k])}</b></div>`).join('');
        return `<div class="ot-card">
          <div class="ot-card-head"><div>
              <h6>${E(b.ProcedureName)}${b.Laterality && b.Laterality !== 'NA' ? ` <small class="text-muted">(${E(b.Laterality.toLowerCase())})</small>` : ''}
                 <span class="ot-st ${st}">${st === 'IN_OT' ? 'In OT' : st.toLowerCase()}</span>
                 ${b.SurgeryType === 'EMERGENCY' ? '<span class="ot-st IN_OT">emergency</span>' : ''}
                 ${b.IsUnplannedReturn ? `<span class="ot-st IN_OT" title="${E(b.ReturnReason)}">unplanned return</span>` : ''}</h6>
              <div class="meta">${E(b.BookingNo)} · ${E(b.OtName)} · ${Ipd.dt(b.ScheduledStart)} – ${new Date(b.ScheduledEnd).toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit' })}</div></div>
            <div class="text-end small">${b.ChargedNet ? `Charged <b>${Ipd.money(b.ChargedNet)}</b>` : ''}${st === 'CANCELLED' ? `<div class="text-danger">Cancelled: ${E(b.CancelReason)}</div>` : ''}</div></div>
          ${st !== 'CANCELLED' ? `<div class="ot-steps">${steps(b)}</div>` : ''}
          <div class="ot-body"><div class="ot-grid">
              <div><div class="k">Surgeon</div>${E(b.SurgeonName)}</div><div><div class="k">Assistant</div>${E(b.AssistantName || '—')}</div>
              <div><div class="k">Anaesthetist</div>${E(b.AnaesthetistName || '—')}</div><div><div class="k">Anaesthesia</div>${E(b.AnaesthesiaType || '—')}</div>
              <div><div class="k">Nurses</div>${E([b.ScrubNurse, b.CirculatingNurse].filter(Boolean).join(' / ') || '—')}</div><div><div class="k">Pre-op diagnosis</div>${E(b.PreOpDiagnosis || '—')}</div>
              ${b.SurgeryMinutes != null ? `<div><div class="k">Surgery time</div>${b.SurgeryMinutes} min${b.OtMinutes != null ? ` (OT ${b.OtMinutes} min)` : ''}</div>` : ''}
              <div><div class="k">Consents</div>${b.HasSurgicalConsent ? '✔ surgical' : '<span class="text-danger">surgical missing</span>'}${b.AnaesthetistId ? (b.HasAnaesConsent ? ' · ✔ anaesthesia' : ' · <span class="text-danger">anaesthesia missing</span>') : ''}</div>
          </div>
          ${times ? `<div class="ot-times">${times}</div>` : ''}
          ${imps.length ? `<div class="mt-2 small"><b>Implants / surgical items / consumables:</b> ${imps.map(i => `${E(i.ItemName)}${i.BatchNo ? ' · batch ' + E(i.BatchNo) : ''}${i.SerialNo ? ' · s/n ' + E(i.SerialNo) : ''} × ${Number(i.Qty)}`).join('; ')}</div>` : ''}
          ${charges.length ? `<div class="mt-1 small text-muted">${charges.length} OT charge line(s) on the bill.</div>` : ''}
          </div>
          <div class="ot-actions">${a.join('')}</div></div>`;
    }

    // ── actions ────────────────────────────────────────────────────────────────────────────────────────────────
    $('otBookBtn')?.addEventListener('click', () => IpdOtBook.open({ base, admissionId: C.id, patientLabel: window.IpdPage ? `${window.IpdPage.patientName} · ${window.IpdPage.ipNo} · ${window.IpdPage.bedLabel || ''}` : '', consultant: C.consultant, diagnosis: C.diagnosis, onSaved: load }));
    $('otList').addEventListener('click', async e => {
        const btnEl = e.target.closest('button[data-act]'); if (!btnEl) return;
        const b = (D.bookings || []).find(x => x.OtBookingId === Number(btnEl.dataset.id)); if (!b) return;
        const act = btnEl.dataset.act;
        if (act === 'edit') IpdOtBook.open({ base, admissionId: C.id, booking: b, patientLabel: b.ProcedureName, onSaved: load });
        else if (act === 'cancel') {
            const reason = await Ipd.reason('Cancel OT booking ' + b.BookingNo + '?'); if (reason == null) return;
            const r = await Ipd.post(base + 'Cancel?bookingId=' + b.OtBookingId, { reason });
            if (!r.success) return Ipd.error(r.error); Ipd.toast('OT booking cancelled'); load();
        }
        else if (act === 'consent') consent(b);
        else if (act.startsWith('check:')) checklist(b, act.split(':')[1]);
        else if (act === 'times') times(b, false);
        else if (act === 'complete') times(b, true);
        else if (act === 'note') note(b);
        else if (act === 'anaes') anaesthesia(b);
        else if (act === 'implant') implants(b);
        else if (act === 'charges') charges(b);
        else if (act === 'reverse') {
            const reason = await Ipd.reason('Reverse the OT charges of ' + b.BookingNo + '?'); if (reason == null) return;
            const r = await Ipd.post(base + 'ReverseCharges?bookingId=' + b.OtBookingId, { reason });
            if (!r.success) return Ipd.error(r.error); Ipd.toast('OT charges reversed'); load();
        }
        else if (act === 'print') window.open(base + 'PrintRecord?bookingId=' + b.OtBookingId, '_blank');
    });

    // consent: the workspace's consent dialog, tied to the booking and pre-set to the missing form
    function consent(b) {
        const hid = $('cnOtBooking'), modalEl = $('consentModal');
        if (!hid || !modalEl) { Ipd.error('The consent dialog is not available on this page.'); return; }
        hid.value = b.OtBookingId; hid.dataset.procedure = b.ProcedureName;
        const lbl = $('cnOtLabel'); lbl.textContent = 'For OT booking ' + b.BookingNo + ': ' + b.ProcedureName; lbl.classList.remove('d-none');
        const want = !b.HasSurgicalConsent ? 'SURG' : 'ANAES';
        const pick = (L.consents || []).find(c => c.Purpose === want);
        bootstrap.Modal.getOrCreateInstance(modalEl).show();
        if (pick) {
            let tries = 0;
            const t = setInterval(() => {
                const sel = $('cnId');
                if (sel && sel.querySelector(`option[value="${pick.Id}"]`)) { clearInterval(t); sel.value = pick.Id; sel.dispatchEvent(new Event('change')); }
                else if (++tries > 30) clearInterval(t);
            }, 100);
        }
    }
    document.addEventListener('ipd:consent-saved', () => { Ipd.toast('Consent recorded for the OT booking'); load(); });

    // checklist of a phase
    function checklist(b, phase) {
        const items = (L.checklist || []).filter(i => i.Phase === phase).sort((x, y) => x.Sort - y.Sort);
        const auto = { SURG_CONSENT: b.HasSurgicalConsent, ANAES_CONSENT: b.AnaesthetistId ? b.HasAnaesConsent : null };
        const row = i => {
            const choices = i.Kind === 'INFO' ? ['YES', 'NO'] : (i.AllowNa ? ['YES', 'NA'] : ['YES']);
            let pre = '';
            if (i.Code in auto) pre = auto[i.Code] === true ? 'YES' : (auto[i.Code] === null && i.AllowNa ? 'NA' : '');
            const lockAuto = i.Code in auto;
            return `<div class="ot-check-item ${i.Kind === 'INFO' ? 'info' : ''}" data-code="${i.Code}">
                <div class="txt">${E(i.ItemText)}${lockAuto ? `<div class="small ${pre === 'YES' ? 'text-success' : 'text-danger'}">${pre === 'YES' ? 'Recorded for this booking' : pre === 'NA' ? 'No anaesthetist on the booking' : 'Not recorded yet: use Record consent'}</div>` : ''}</div>
                <div class="btn-group" role="group">${choices.map(c => `<input type="radio" class="btn-check" name="ck_${i.Code}" id="ck_${i.Code}_${c}" value="${c}" ${pre === c ? 'checked' : ''} ${lockAuto ? 'disabled' : ''} />
                    <label class="btn btn-outline-${c === 'NO' ? 'secondary' : c === 'NA' ? 'secondary' : 'success'}" for="ck_${i.Code}_${c}">${c === 'NA' ? 'N/A' : c === 'YES' ? (i.Kind === 'INFO' ? 'Yes' : 'Done') : 'No'}</label>`).join('')}</div>
                <input class="form-control form-control-sm" style="max-width:180px" maxlength="200" placeholder="Note" data-note /></div>`;
        };
        modal('otCheckModal', `<i class="bi bi-ui-checks me-1 text-primary"></i>${PH[phase]} · ${E(b.BookingNo)}`,
            `<div class="small text-muted mb-2">${E(b.ProcedureName)} · every item must be confirmed; a "No" stops the checklist.</div>${items.map(row).join('')}
             <div class="mt-3">${field('ckRemarks', 'Remarks', txt('ckRemarks', '', 500), 'col-12')}</div>`,
            `<button type="button" class="btn btn-primary" id="ckSave"><i class="bi bi-check2-all me-1"></i>Complete ${PH[phase]}</button>`);
        $('ckSave').onclick = async ev => {
            const answers = items.map(i => {
                const el = document.querySelector(`input[name="ck_${i.Code}"]:checked`);
                return { code: i.Code, answer: el ? el.value : '', note: document.querySelector(`.ot-check-item[data-code="${i.Code}"] [data-note]`).value.trim() };
            });
            const missing = items.find(i => !answers.find(a => a.code === i.Code).answer);
            if (missing) { Ipd.error('Not answered: ' + missing.ItemText); return; }
            ev.target.disabled = true;
            const r = await Ipd.post(base + 'SaveChecklist?bookingId=' + b.OtBookingId, { phase, answers: JSON.stringify(answers), remarks: v('ckRemarks') });
            ev.target.disabled = false;
            if (!r.success) return Ipd.error(r.error);
            hide('otCheckModal'); Ipd.toast(PH[phase] + ' completed'); load();
        };
    }

    // OT times (and complete)
    function times(b, complete) {
        const now = Ipd.local(new Date());
        const first = TIMES.findIndex(([k]) => !b[k]);
        modal('otTimesModal', `<i class="bi bi-clock-history me-1 text-danger"></i>${complete ? 'Complete surgery' : 'OT times'} · ${E(b.BookingNo)}`,
            `<div class="small text-muted mb-2">Times must follow each other. Each needs its checklist: in OT after the pre-op checklist, anaesthesia after Sign In, incision after Time Out, out of OT after Sign Out.</div>
             <div class="row g-2">${TIMES.map(([k, t], i) => `<div class="col-md-6"><label class="form-label small fw-semibold" for="tm_${k}">${t}</label>
                <div class="input-group input-group-sm"><input type="datetime-local" class="form-control" id="tm_${k}" value="${b[k] ? Ipd.local(b[k]) : ''}" />
                <button type="button" class="btn btn-outline-secondary" data-now="${k}">Now</button><button type="button" class="btn btn-outline-secondary" data-clear="${k}" title="Clear">×</button></div></div>`).join('')}</div>
             ${complete ? '<div class="alert alert-info small mt-3 mb-0">Completing needs the incision, closure and out-of-OT times, the anaesthesia times (when anaesthesia was given) and the signed surgery note. After that, OT charges can be posted.</div>' : ''}`,
            `<button type="button" class="btn btn-${complete ? 'success' : 'danger'}" id="tmSave"><i class="bi bi-check2 me-1"></i>${complete ? 'Complete surgery' : 'Save times'}</button>`);
        if (!complete && first >= 0 && !b[TIMES[first][0]]) $('tm_' + TIMES[first][0]).value = now;
        document.getElementById('otTimesModal').onclick = e => {
            const n = e.target.closest('[data-now]'), c = e.target.closest('[data-clear]');
            if (n) $('tm_' + n.dataset.now).value = Ipd.local(new Date());
            if (c) $('tm_' + c.dataset.clear).value = '';
        };
        $('tmSave').onclick = async ev => {
            const body = { complete };
            TIMES.forEach(([k]) => { body[k.charAt(0).toLowerCase() + k.slice(1)] = v('tm_' + k) || null; });
            ev.target.disabled = true;
            const r = await Ipd.post(base + 'SaveTimes?bookingId=' + b.OtBookingId, body);
            ev.target.disabled = false;
            if (!r.success) return Ipd.error(r.error);
            hide('otTimesModal'); Ipd.toast(complete ? 'Surgery completed' : 'OT times saved'); load();
        };
    }

    // surgery note
    function note(b) {
        const n = of(D.notes, b.OtBookingId)[0] || {}, signed = n.Status === 'SIGNED';
        const ro = signed ? !C.can.sign : !C.can.note && !C.can.sign;
        modal('otNoteModal', `<i class="bi bi-journal-medical me-1"></i>Surgery note · ${E(b.BookingNo)} ${signed ? `<span class="ot-st COMPLETED">signed v${n.Version}</span>` : n.OtBookingId ? '<span class="ot-st SCHEDULED">draft</span>' : ''}`,
            `${signed ? `<div class="alert alert-success small py-2">Signed by ${E(n.SignedByName)} on ${Ipd.dt(n.SignedAt)}${n.Amendments ? ` · amended ${n.Amendments} time(s)` : ''}.${C.can.sign ? ' A change needs a reason; the signed version is kept.' : ''}</div>` : ''}
             <div class="row g-2">
              ${field('nProc', 'Procedure performed *', txt('nProc', n.ProcedurePerformed || b.ProcedureName, 500), 'col-md-8')}${field('nCond', 'Condition at end', txt('nCond', n.PatientCondition || 'Stable', 100), 'col-md-4')}
              ${field('nDx', 'Post-op diagnosis', txt('nDx', n.PostOpDiagnosis || b.PreOpDiagnosis, 500), 'col-md-6')}${field('nInd', 'Indication', txt('nInd', n.Indication, 1000), 'col-md-6')}
              ${field('nFind', 'Findings', area('nFind', n.Findings), 'col-12')}${field('nDet', 'Procedure details (steps) *', area('nDet', n.ProcedureDetails, 5), 'col-12')}
              ${field('nSpec', 'Specimens', txt('nSpec', n.Specimens, 500), 'col-md-6')}<div class="col-md-2 d-flex align-items-end"><div class="form-check"><input class="form-check-input" type="checkbox" id="nHisto" ${n.SpecimenToHistopath ? 'checked' : ''} /><label class="form-check-label small" for="nHisto">To histopathology</label></div></div>
              ${field('nBlood', 'Blood loss (ml)', nbox('nBlood', n.BloodLossMl, 0, 50000), 'col-md-2')}${field('nDrains', 'Drains', txt('nDrains', n.Drains, 300), 'col-md-2')}
              ${field('nComp', 'Complications', txt('nComp', n.Complications || 'Nil', 1000), 'col-md-6')}${field('nClos', 'Closure', txt('nClos', n.Closure, 300), 'col-md-6')}
              ${field('nPlan', 'Post-op plan / orders *', area('nPlan', n.PostOpPlan, 3), 'col-12')}
              ${signed && C.can.sign ? field('nAmend', 'Reason for the change *', txt('nAmend', '', 300), 'col-12') : ''}
             </div>`,
            ro ? '' : `${!signed && C.can.note ? '<button type="button" class="btn btn-outline-primary" id="nDraft">Save draft</button>' : ''}${C.can.sign ? `<button type="button" class="btn btn-primary" id="nSign"><i class="bi bi-pen me-1"></i>${signed ? 'Save amendment &amp; sign' : 'Sign note'}</button>` : ''}`, 'modal-xl');
        if (ro) document.querySelectorAll('#otNoteModal input, #otNoteModal textarea').forEach(el => el.disabled = true);
        const send = async (sign, el) => {
            const body = { procedurePerformed: v('nProc'), patientCondition: v('nCond'), postOpDiagnosis: v('nDx'), indication: v('nInd'), findings: v('nFind'),
                procedureDetails: v('nDet'), specimens: v('nSpec'), specimenToHistopath: $('nHisto').checked, bloodLossMl: num('nBlood'), drains: v('nDrains'),
                complications: v('nComp'), closure: v('nClos'), postOpPlan: v('nPlan'), sign, amendReason: $('nAmend') ? v('nAmend') : null };
            el.disabled = true;
            const r = await Ipd.post(base + 'SaveNote?bookingId=' + b.OtBookingId, body);
            el.disabled = false;
            if (!r.success) return Ipd.error(r.error);
            hide('otNoteModal'); Ipd.toast(sign ? 'Surgery note signed' : 'Draft saved'); load();
        };
        $('nDraft') && ($('nDraft').onclick = e => send(false, e.target));
        $('nSign') && ($('nSign').onclick = e => send(true, e.target));
    }

    // anaesthesia record
    function anaesthesia(b) {
        const a = of(D.anaesthesia, b.OtBookingId)[0] || {}, signed = !!a.SignedAt, ro = signed || !C.can.anaesthesia;
        const drugs = a.Drugs ? JSON.parse(a.Drugs) : [], mon = a.Monitoring ? JSON.parse(a.Monitoring) : [];
        const dRow = (d = {}) => `<tr><td><input class="form-control form-control-sm" data-k="at" type="time" value="${E(d.at || '')}" /></td><td><input class="form-control form-control-sm" data-k="drug" value="${E(d.drug || '')}" /></td>
            <td><input class="form-control form-control-sm" data-k="dose" value="${E(d.dose || '')}" /></td><td><input class="form-control form-control-sm" data-k="route" value="${E(d.route || 'IV')}" /></td><td><button type="button" class="btn btn-sm btn-link text-danger p-0" data-del>×</button></td></tr>`;
        const mRow = (m = {}) => `<tr>${['at', 'hr', 'sbp', 'dbp', 'spo2', 'etco2', 'temp'].map(k => `<td><input class="form-control form-control-sm" data-k="${k}" ${k === 'at' ? 'type="time"' : 'type="number"'} value="${E(m[k] ?? '')}" /></td>`).join('')}<td><button type="button" class="btn btn-sm btn-link text-danger p-0" data-del>×</button></td></tr>`;
        const types = (L.anaesthesiaTypes || []).map(t => `<option value="${t.Id}" ${(a.AnaesthesiaTypeId || b.AnaesthesiaTypeId) === t.Id ? 'selected' : ''}>${E(t.Name)}</option>`).join('');
        const asa = ['I', 'II', 'III', 'IV', 'V', 'VI', 'IE', 'IIE', 'IIIE', 'IVE', 'VE'].map(g => `<option ${a.AsaGrade === g ? 'selected' : ''}>${g}</option>`).join('');
        modal('otAnaesModal', `<i class="bi bi-lungs me-1"></i>Anaesthesia record · ${E(b.BookingNo)} ${signed ? '<span class="ot-st COMPLETED">signed</span>' : ''}`,
            `${signed ? `<div class="alert alert-success small py-2">Signed by ${E(a.SignedByName)} on ${Ipd.dt(a.SignedAt)}: it cannot be changed.</div>` : ''}
            <div class="row g-2">
              ${field('aType', 'Anaesthesia given', `<select id="aType" class="form-select form-select-sm"><option value="">—</option>${types}</select>`, 'col-md-4')}
              ${field('aAsa', 'ASA grade', `<select id="aAsa" class="form-select form-select-sm"><option value="">—</option>${asa}</select>`, 'col-md-2')}
              ${field('aMp', 'Mallampati', `<select id="aMp" class="form-select form-select-sm"><option value="">—</option>${[1, 2, 3, 4].map(x => `<option ${a.Mallampati === x ? 'selected' : ''}>${x}</option>`).join('')}</select>`, 'col-md-2')}
              ${field('aNpo', 'Nil by mouth since', `<input type="datetime-local" id="aNpo" class="form-control form-control-sm" value="${a.NpoSince ? Ipd.local(a.NpoSince) : ''}" />`, 'col-md-4')}
              ${field('aAirway', 'Airway assessment', txt('aAirway', a.Airway, 300), 'col-md-6')}${field('aCom', 'Co-morbidities', txt('aCom', a.Comorbidities, 500), 'col-md-6')}
              ${field('aPre', 'Pre-anaesthetic notes', area('aPre', a.PreAnaesNotes, 2), 'col-md-6')}${field('aTech', 'Technique', area('aTech', a.Technique, 2), 'col-md-6')}
              ${field('aDev', 'Airway device', txt('aDev', a.AirwayDevice, 150, 'e.g. ETT 7.5 cuffed / LMA 4'), 'col-md-4')}
              <div class="col-12"><div class="d-flex justify-content-between align-items-center"><b class="small">Drugs</b>${ro ? '' : '<button type="button" class="btn btn-sm btn-link" id="aAddDrug">+ drug</button>'}</div>
                <table class="table table-sm ot-rowtable mb-1"><thead><tr><th style="width:110px">Time</th><th>Drug</th><th>Dose</th><th style="width:90px">Route</th><th></th></tr></thead><tbody id="aDrugs">${(drugs.length ? drugs : [{}]).map(dRow).join('')}</tbody></table></div>
              <div class="col-12"><div class="d-flex justify-content-between align-items-center"><b class="small">Intra-op monitoring</b>${ro ? '' : '<button type="button" class="btn btn-sm btn-link" id="aAddMon">+ reading</button>'}</div>
                <table class="table table-sm ot-rowtable mb-1"><thead><tr><th style="width:110px">Time</th><th>HR</th><th>SBP</th><th>DBP</th><th>SpO2</th><th>EtCO2</th><th>Temp</th><th></th></tr></thead><tbody id="aMon">${(mon.length ? mon : [{}]).map(mRow).join('')}</tbody></table></div>
              ${field('aFl', 'IV fluids (ml)', nbox('aFl', a.FluidsMl, 0, 50000), 'col-md-3')}${field('aBl', 'Blood given (ml)', nbox('aBl', a.BloodGivenMl, 0, 50000), 'col-md-3')}
              ${field('aUo', 'Urine (ml)', nbox('aUo', a.UrineMl, 0, 50000), 'col-md-3')}${field('aLoss', 'Blood loss (ml)', nbox('aLoss', a.BloodLossMl, 0, 50000), 'col-md-3')}
              ${field('aCompl', 'Complications', txt('aCompl', a.Complications || 'Nil', 1000), 'col-md-8')}${field('aAld', 'Aldrete score (0-10)', nbox('aAld', a.AldreteScore, 0, 10), 'col-md-4')}
              ${field('aRec', 'Recovery notes', area('aRec', a.RecoveryNotes, 2), 'col-12')}
            </div>`,
            ro ? '' : '<button type="button" class="btn btn-outline-primary" id="aDraft">Save</button><button type="button" class="btn btn-primary" id="aSign"><i class="bi bi-pen me-1"></i>Sign</button>', 'modal-xl');
        const m = $('otAnaesModal');
        if (ro) m.querySelectorAll('input, select, textarea').forEach(el => el.disabled = true);
        m.onclick = e => { if (e.target.closest('[data-del]')) e.target.closest('tr').remove(); };
        $('aAddDrug') && ($('aAddDrug').onclick = () => $('aDrugs').insertAdjacentHTML('beforeend', dRow()));
        $('aAddMon') && ($('aAddMon').onclick = () => $('aMon').insertAdjacentHTML('beforeend', mRow()));
        const rows = (tb, numeric) => [...$(tb).querySelectorAll('tr')].map(tr => {
            const o = {}; tr.querySelectorAll('[data-k]').forEach(i => { const x = i.value.trim(); if (x !== '') o[i.dataset.k] = numeric && i.dataset.k !== 'at' ? Number(x) : x; }); return o;
        }).filter(o => Object.keys(o).length > (numeric ? 1 : 0) && (numeric || o.drug));
        const send = async (sign, el) => {
            const body = { anaesthesiaTypeId: num('aType'), asaGrade: v('aAsa') || null, mallampati: num('aMp'), npoSince: v('aNpo') || null, airway: v('aAirway'),
                comorbidities: v('aCom'), preAnaesNotes: v('aPre'), technique: v('aTech'), airwayDevice: v('aDev'), drugs: JSON.stringify(rows('aDrugs', false)),
                monitoring: JSON.stringify(rows('aMon', true)), fluidsMl: num('aFl'), bloodGivenMl: num('aBl'), urineMl: num('aUo'), bloodLossMl: num('aLoss'),
                complications: v('aCompl'), aldreteScore: num('aAld'), recoveryNotes: v('aRec'), sign };
            if (sign && !(await Ipd.confirm('Sign the anaesthesia record?', 'A signed record cannot be changed.', 'Sign'))) return;
            el.disabled = true;
            const r = await Ipd.post(base + 'SaveAnaesthesia?bookingId=' + b.OtBookingId, body);
            el.disabled = false;
            if (!r.success) return Ipd.error(r.error);
            hide('otAnaesModal'); Ipd.toast(sign ? 'Anaesthesia record signed' : 'Anaesthesia record saved'); load();
        };
        $('aDraft') && ($('aDraft').onclick = e => send(false, e.target));
        $('aSign') && ($('aSign').onclick = e => send(true, e.target));
    }

    // implants, surgical items and consumables: issued from pharmacy stock (category of the type, saleable batches only)
    const CATS = { IMPLANT: 'Implants', SURGICAL: 'Surgical', CONSUMABLE: 'Consumables' };
    function implants(b) {
        const list = of(D.implants, b.OtBookingId);
        let picked = null, batches = [], timer = null;
        modal('otImpModal', `<i class="bi bi-nut me-1"></i>Implants, surgical items &amp; OT consumables · ${E(b.BookingNo)}`,
            `<div class="table-responsive mb-3"><table class="table table-sm ot-rowtable"><thead><tr><th>Type</th><th>Item</th><th>Batch</th><th>Expiry</th><th>Serial</th><th class="text-end">Qty</th><th class="text-end">Charged</th><th>Issue</th><th></th></tr></thead>
             <tbody>${list.length ? list.map(i => `<tr class="${i.Status === 'REMOVED' ? 'text-muted text-decoration-line-through' : ''}"><td>${{ IMPLANT: 'Implant', SURGICAL: 'Surgical', CONSUMABLE: 'Consumable' }[i.ItemType] || E(i.ItemType)}</td>
                <td>${E(i.ItemName)}${i.Manufacturer ? `<div class="small text-muted">${E(i.Manufacturer)}</div>` : ''}</td><td>${E(i.BatchNo || '')}</td><td>${Ipd.date(i.ExpiryDate)}</td><td>${E(i.SerialNo || '')}</td>
                <td class="text-end">${Number(i.Qty)}</td><td class="text-end">${i.ChargeNet ? Ipd.money(i.ChargeNet) : '—'}</td><td class="small">${E(i.IssueNo || '')}</td>
                <td>${i.Status === 'ACTIVE' && C.open ? `<button type="button" class="btn btn-sm btn-link text-danger p-0" data-rm="${i.ImplantId}">Remove</button>` : E(i.RemoveReason || '')}</td></tr>`).join('') : '<tr><td colspan="9" class="text-muted">Nothing recorded.</td></tr>'}</tbody></table></div>
             <div class="row g-2 border-top pt-3">
               ${field('iType', 'Type', '<select id="iType" class="form-select form-select-sm"><option value="IMPLANT">Implant</option><option value="SURGICAL">Surgical</option><option value="CONSUMABLE">Consumable</option></select>', 'col-md-2')}
               ${field('iStore', 'Store', '<select id="iStore" class="form-select form-select-sm"></select>', 'col-md-3')}
               <div class="col-md-7 position-relative"><label class="form-label small fw-semibold" for="iItem">Item * <span class="text-muted fw-normal" id="iCatHint"></span></label>
                 <input id="iItem" class="form-control form-control-sm" autocomplete="off" placeholder="Type to search items with stock" />
                 <div id="iList" class="list-group position-absolute w-100 shadow-sm d-none" style="z-index:1070;max-height:260px;overflow:auto"></div></div>
               ${field('iBatch', 'Batch (nearest expiry first)', '<select id="iBatch" class="form-select form-select-sm" disabled><option value="">Choose the item first</option></select>', 'col-md-5')}
               ${field('iQty', 'Qty *', nbox('iQty', 1, 0.001, 9999, 'any'), 'col-md-2')}
               ${field('iSerial', 'Serial no. (implant)', txt('iSerial', '', 80), 'col-md-2')}
               <div class="col-md-3"><label class="form-label small fw-semibold">Price</label><div class="form-control-plaintext small" id="iPrice">—</div></div>
               ${field('iRem', 'Remarks', txt('iRem', '', 300), 'col-12')}
               <div class="col-12 small text-muted">Only items of the pharmacy category <b id="iCatName"></b> with saleable stock (not expired or blocked) can be chosen. The item is issued from the store against the IP number:
                 stock goes down, the price comes from the batch and the payer's price rule, and it is charged to the IP bill. Removing it returns it to the store.</div>
             </div>`,
            '<button type="button" class="btn btn-primary" id="iSave"><i class="bi bi-box-arrow-up-right me-1"></i>Issue to OT</button>', 'modal-xl');
        const reset = () => { picked = null; batches = []; $('iItem').value = ''; $('iBatch').innerHTML = '<option value="">Choose the item first</option>'; $('iBatch').disabled = true; $('iPrice').textContent = '—'; };
        const search = async () => {
            const type = v('iType'); $('iCatName').textContent = CATS[type]; $('iCatHint').textContent = '· ' + CATS[type] + ' category';
            let r;
            try { r = await Ipd.get(`${base}StockItems?itemType=${type}&q=${encodeURIComponent(v('iItem'))}&storeId=${v('iStore') || ''}`); } catch (e) { return Ipd.error(e.message); }
            if (!$('iStore').options.length) $('iStore').innerHTML = (r.stores || []).map(x => `<option value="${x.StoreId}" ${x.IsDefault ? 'selected' : ''}>${E(x.StoreName)}</option>`).join('');
            const items = r.items || [], hasCat = ((r.hasCategory || [])[0] || {}).HasCategory;
            $('iList').innerHTML = items.length ? items.map(x => `<button type="button" class="list-group-item list-group-item-action py-1" data-item="${x.ItemId}">
                    <div class="d-flex justify-content-between"><span class="fw-semibold">${E(x.ItemName)}</span><span class="badge text-bg-success">${Number(x.Stock)} in stock</span></div>
                    <div class="small text-muted">${E(x.ItemCode)}${x.ManufacturerName ? ' · ' + E(x.ManufacturerName) : ''} · ${E(x.CategoryName)} · nearest expiry ${Ipd.date(x.NearestExpiry)}</div></button>`).join('')
                : `<div class="list-group-item small text-danger">${!hasCat ? `There is no "${CATS[type]}" category in the pharmacy (Master › Pharmacy › Category).`
                    : `No ${CATS[type].toLowerCase()} item${v('iItem') ? ' matching "' + E(v('iItem')) + '"' : ''} with stock in this store. Receive stock (GRN) or choose another store.`}</div>`;
            $('iList').classList.remove('d-none');
            $('iList')._items = items;
        };
        $('iType').onchange = () => { reset(); search(); };
        $('iStore').onchange = () => { reset(); search(); };
        $('iItem').oninput = () => { picked = null; $('iBatch').disabled = true; clearTimeout(timer); timer = setTimeout(search, 250); };
        $('iItem').onfocus = () => search();
        $('iList').onclick = async e => {
            const btnEl = e.target.closest('[data-item]'); if (!btnEl) return;
            picked = ($('iList')._items || []).find(x => x.ItemId === Number(btnEl.dataset.item));
            $('iItem').value = picked.ItemName; $('iList').classList.add('d-none');
            try { batches = await Ipd.get(`${base}Batches?itemId=${picked.ItemId}&storeId=${v('iStore')}`) || []; } catch (err) { return Ipd.error(err.message); }
            if (!batches.length) { $('iBatch').innerHTML = '<option value="">No saleable batch</option>'; return; }
            $('iBatch').innerHTML = batches.map(x => `<option value="${x.BatchId}">${E(x.BatchNo)} · exp ${Ipd.date(x.ExpiryDate)} · ${Number(x.Stock)} in stock</option>`).join('');
            $('iBatch').disabled = false; $('iBatch').onchange();
        };
        $('iBatch').onchange = () => { const x = batches.find(y => y.BatchId === Number(v('iBatch'))); $('iPrice').textContent = x ? `MRP ${Ipd.money(x.UnitMrp)} per unit · GST ${Number(x.GstPercent)}%` : '—'; };
        document.addEventListener('click', e => { if (!e.target.closest('#iList') && e.target.id !== 'iItem') $('iList')?.classList.add('d-none'); });
        $('otImpModal').onclick = async e => {
            const rm = e.target.closest('[data-rm]'); if (!rm) return;
            const reason = await Ipd.reason('Remove this item?', 'Reason (the item goes back to the store and the charge is reversed)'); if (reason == null) return;
            const r = await Ipd.post(base + 'RemoveImplant?implantId=' + rm.dataset.rm, { reason });
            if (!r.success) return Ipd.error(r.error);
            Ipd.toast('Removed and returned to the store'); await load(); implants((D.bookings || []).find(x => x.OtBookingId === b.OtBookingId));
        };
        $('iSave').onclick = async ev => {
            if (!picked) return Ipd.error('Choose the item from the list (only items with stock can be chosen).');
            const bt = batches.find(y => y.BatchId === Number(v('iBatch'))), qty = num('iQty') || 0;
            if (!bt) return Ipd.error('Choose the batch.');
            if (qty <= 0) return Ipd.error('Enter the quantity.');
            if (qty > Number(bt.Stock)) return Ipd.error(`Only ${Number(bt.Stock)} of ${picked.ItemName} batch ${bt.BatchNo} in stock.`);
            if (v('iType') === 'IMPLANT' && !v('iSerial') && !(await Ipd.confirm('No serial number?', 'Implants usually carry a serial number on the sticker. Issue without it?', 'Issue'))) return;
            ev.target.disabled = true;
            const r = await Ipd.post(base + 'AddImplant?bookingId=' + b.OtBookingId, { itemType: v('iType'), itemId: picked.ItemId, batchId: bt.BatchId, storeId: Number(v('iStore')) || null,
                qty, serialNo: v('iSerial') || null, remarks: v('iRem') || null });
            ev.target.disabled = false;
            if (!r.success) return Ipd.error(r.error);
            Ipd.toast('Issued to OT' + (r.data && r.data.IssueNo ? ': ' + r.data.IssueNo : '')); await load(); implants((D.bookings || []).find(x => x.OtBookingId === b.OtBookingId));
        };
        search();
    }

    // OT charges: preview from the tariffs, rates editable with RATE_EDIT
    async function charges(b) {
        let rows;
        try { rows = await Ipd.get(base + 'ChargePreview?bookingId=' + b.OtBookingId); } catch (e) { return Ipd.error(e.message); }
        const pkg = rows.length && rows[0].InPackage;
        modal('otChgModal', `<i class="bi bi-cash-stack me-1 text-success"></i>Post OT charges · ${E(b.BookingNo)}`,
            `<div class="small text-muted mb-2">${E(b.ProcedureName)} · rates from Procedure Tariff, Anaesthesia Rate and OT Tariff of the patient's tariff category.${pkg ? ' <b class="text-primary">The package covers OT: lines post at ₹0.</b>' : ''}</div>
             <table class="table table-sm ot-lines"><thead><tr><th style="width:30px"></th><th>Charge</th><th>Doctor</th><th>Source</th><th class="text-end">Rate (₹)</th></tr></thead><tbody>
             ${rows.map(r => `<tr><td><input type="checkbox" class="form-check-input" data-code="${r.Code}" ${r.Rate > 0 ? 'checked' : ''} /></td><td>${E(r.Name)}${r.UsedFallback ? ' <span class="badge text-bg-warning">default category</span>' : ''}</td>
                <td>${E(r.DoctorName || '')}</td><td class="small text-muted">${E(r.Source)}</td>
                <td class="text-end"><input type="number" class="form-control form-control-sm text-end ms-auto" min="0" step="0.01" data-rate="${r.Code}" data-master="${r.Rate}" value="${Number(r.Rate).toFixed(2)}" ${C.can.rate ? '' : 'readonly'} /></td></tr>`).join('')}
             </tbody><tfoot><tr><th colspan="4" class="text-end">Total</th><th class="text-end" id="chgTotal"></th></tr></tfoot></table>
             ${C.can.rate ? '' : '<div class="small text-muted"><i class="bi bi-lock me-1"></i>Changing a rate needs the IPD Patient › Change rate permission; a line without a rate cannot be posted.</div>'}`,
            '<button type="button" class="btn btn-success" id="chgPost"><i class="bi bi-check2 me-1"></i>Post to IP bill</button>');
        const m = $('otChgModal');
        const total = () => { let t = 0; m.querySelectorAll('[data-code]').forEach(c => { if (c.checked) t += Number(m.querySelector(`[data-rate="${c.dataset.code}"]`).value) || 0; }); $('chgTotal').textContent = Ipd.money(t); };
        m.oninput = total; m.onchange = total; total();
        $('chgPost').onclick = async ev => {
            const lines = [...m.querySelectorAll('[data-code]')].filter(c => c.checked).map(c => ({ code: c.dataset.code, rate: Number(m.querySelector(`[data-rate="${c.dataset.code}"]`).value) || 0 })).filter(l => l.rate > 0);
            if (!lines.length) return Ipd.error('Choose at least one charge with a rate.');
            ev.target.disabled = true;
            const r = await Ipd.post(base + 'PostCharges?bookingId=' + b.OtBookingId, { lines });
            ev.target.disabled = false;
            if (!r.success) return Ipd.error(r.error);
            hide('otChgModal'); Ipd.toast(`OT charges posted: ${r.data.Lines} line(s), ${Ipd.money(r.data.Total)}`); load();
        };
    }

    // load when the tab is first shown (or now, if the page opened on it)
    const tabBtn = document.querySelector('[data-tab="ot"]');
    tabBtn?.addEventListener('shown.bs.tab', () => { if (!loaded) { loaded = true; load(); } });
    if ($('tab-ot').classList.contains('active')) { loaded = true; load(); }
})();
