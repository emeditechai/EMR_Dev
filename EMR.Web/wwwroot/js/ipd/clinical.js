/* IPD Patient > Clinical (Phase 3, SQLScripts/2562-2565): doctor's initial assessment, rounds / progress notes, CPOE orders and
   cross-consultation. Config window.IpdClin = { id, base, phBase, open, consultant, can: { assess, note, order, countersign, consult, correct, indent, labTab } }.
   A login linked to a doctor (Doctor Master) orders and signs directly; anyone else writes a verbal / telephone order for a doctor to countersign. */
(function () {
    'use strict';
    const C = window.IpdClin, U = window.IpdClinUi;
    if (!C || !U || !document.getElementById('tab-clinical')) return;
    const { E, $ } = U, base = C.base;
    let D = null, loaded = false, pane = 'orders';

    const ROUTES = [['PO', 'Oral (PO)'], ['IV', 'Intravenous (IV)'], ['IM', 'Intramuscular (IM)'], ['SC', 'Subcutaneous (SC)'], ['SL', 'Sublingual'],
        ['INH', 'Inhalation'], ['NEB', 'Nebulisation'], ['TOP', 'Topical'], ['PR', 'Per rectal'], ['PV', 'Per vaginal'], ['RT', 'Ryle\'s tube'], ['ID', 'Intradermal'],
        ['EYE', 'Eye'], ['EAR', 'Ear'], ['NASAL', 'Nasal'], ['TD', 'Transdermal'], ['OTHER', 'Other']];
    const DIETS = ['Normal diet', 'Soft diet', 'Semi-solid diet', 'Liquid diet', 'Clear liquid diet', 'Diabetic diet', 'Low salt diet', 'Renal diet', 'Cardiac diet',
        'High protein diet', 'Low fat diet', 'NPO (nothing by mouth)', 'Ryle\'s tube feed', 'Other'];
    const PRI = [['ROUTINE', 'Routine'], ['URGENT', 'Urgent'], ['STAT', 'STAT']];

    const st = () => (D.state || [])[0] || {};
    const isDoctor = () => !!st().MyDoctorId;
    const canWrite = () => !!st().ClinicalOpen && C.open;

    async function load() {
        try { D = await Ipd.get(`${base}Data?id=${C.id}`); render(); }
        catch (e) { $('clinBody').innerHTML = `<div class="alert alert-danger m-0">${E(e.message)}</div>`; }
    }

    // ── header strip ───────────────────────────────────────────────────────────────────────────────────────────
    function strip() {
        const s = st(), docA = (D.assessments || []).find(a => a.Kind === 'DOCTOR' && a.Status !== 'SUPERSEDED');
        const signed = docA && docA.Status === 'SIGNED';
        const due = new Date(s.DoctorAssessDueAt) < new Date();
        const pend = (D.orders || []).filter(o => o.Source !== 'DIRECT' && !o.CountersignedAt && o.Status !== 'CANCELLED');
        const over = pend.filter(o => o.CountersignOverdue);
        const waiting = (D.consults || []).filter(c => c.Status === 'REQUESTED');
        return `<div class="clin-strip">
            <div><small>Doctor's initial assessment</small><b>${signed ? '<span class="text-success"><i class="bi bi-check-circle-fill me-1"></i>Signed</span>'
                : `<span class="${due ? 'text-danger' : 'text-warning-emphasis'}">${docA ? 'Draft' : 'Not done'} · ${U.dueText(s.DoctorAssessDueAt)}</span>`}</b></div>
            <div><small>Verbal / telephone orders</small><b>${pend.length ? `<span class="${over.length ? 'text-danger' : 'text-warning-emphasis'}">${pend.length} to countersign${over.length ? ` · ${over.length} overdue` : ''}</span>` : '<span class="text-muted fw-normal">none pending</span>'}</b></div>
            <div><small>Cross-consultations</small><b>${waiting.length ? `<span class="text-warning-emphasis">${waiting.length} waiting</span>` : '<span class="text-muted fw-normal">none waiting</span>'}</b></div>
            <div><small>Allergies</small><b class="${s.KnownAllergies ? 'text-danger' : 'text-muted fw-normal'}">${E(s.KnownAllergies || 'None recorded')}</b></div>
            <div><small>You are</small><b>${isDoctor() ? '<i class="bi bi-person-badge me-1"></i>' + E(s.MyDoctorName) : '<span class="text-muted fw-normal">not a doctor login (orders are verbal)</span>'}</b></div>
        </div>`;
    }

    function render() {
        const panes = [['orders', 'Orders', 'bi-prescription2'], ['notes', 'Rounds & Notes', 'bi-journal-text'], ['assess', 'Initial Assessment', 'bi-clipboard2-check'], ['consult', 'Cross-consultation', 'bi-people']];
        $('clinBody').innerHTML = strip() + `<ul class="nav nav-pills clin-pills mb-3">${panes.map(([k, t, i]) =>
            `<li class="nav-item"><button type="button" class="nav-link ${pane === k ? 'active' : ''}" data-pane="${k}"><i class="bi ${i} me-1"></i>${t}</button></li>`).join('')}</ul><div id="clinPane"></div>`;
        ({ orders: renderOrders, notes: renderNotes, assess: renderAssess, consult: renderConsults })[pane]();
    }

    // ── orders ─────────────────────────────────────────────────────────────────────────────────────────────────
    function orderText(o) {
        if (o.OrderType === 'MED') return `<b>${E(o.DrugName)}</b> ${E(o.Dose)} · ${E(o.Route)} · ${E(o.FrequencyName || o.FrequencyCode)}${o.IsHighAlert ? ' <span class="badge text-bg-danger">high alert</span>' : ''}
            <div class="small text-muted">from ${Ipd.dt(o.StartAt)}${o.EndAt ? ' to ' + Ipd.dt(o.EndAt) : ''}${o.Details ? ' · ' + E(o.Details) : ''}${o.IndentId ? ' · <i class="bi bi-capsule"></i> indent sent' : ''}</div>`;
        if (o.OrderType === 'SERVICE') return `<b>${E(o.ServiceName)}</b> × ${Number(o.Qty)} <span class="small text-muted">(${o.ServiceKind === 'PROCEDURE' ? 'procedure' : 'service'})</span>${o.DoneAt ? `<div class="small text-success">done ${Ipd.dt(o.DoneAt)} · charged</div>` : ''}`;
        if (o.OrderType === 'DIET') return `<b>${E(o.DietType)}</b>${o.Details ? ' · ' + E(o.Details) : ''}`;
        return E(o.Details);
    }
    const TYPE = { MED: 'Prescription', SERVICE: 'Service / procedure', DIET: 'Diet', NURSING: 'Nursing instruction' };

    function renderOrders() {
        const os = D.orders || [], my = st().MyDoctorId, w = canWrite() && C.can.order;
        let h = '';
        if (w) h += `<div class="d-flex flex-wrap gap-2 mb-2">
            <button type="button" class="btn btn-sm btn-primary" data-new="DIET"><i class="bi bi-egg-fried me-1"></i>Diet</button>
            <button type="button" class="btn btn-sm btn-outline-primary" data-new="NURSING"><i class="bi bi-chat-square-text me-1"></i>Nursing instruction</button>
            <span class="vr mx-1"></span>
            <button type="button" class="btn btn-sm btn-outline-secondary" data-go-tab="procedures"><i class="bi bi-scissors me-1"></i>Procedures</button>
            <button type="button" class="btn btn-sm btn-outline-secondary" data-go-tab="indent"><i class="bi bi-capsule-pill me-1"></i>Medicines</button>
            ${C.can.labTab ? '<button type="button" class="btn btn-sm btn-outline-secondary" data-go-tab="lab"><i class="bi bi-droplet-half me-1"></i>LAB / Radiology</button>' : ''}</div>`;
        if (w && !isDoctor()) h += `<div class="alert alert-warning py-2 small"><i class="bi bi-telephone me-1"></i>Your login is not linked to a doctor: an order you write is a <b>verbal / telephone order</b> of the doctor you choose, read back to the doctor and countersigned by the doctor within ${st().CountersignHours} hours.</div>`;
        if (!os.length) { $('clinPane').innerHTML = h + '<div class="ipd-soon py-4"><div class="small">No orders yet. Medicines are prescribed on the Medicines tab (they feed the nurses\' eMAR); procedures, LAB and radiology are on their own tabs.</div></div>'; return; }
        h += `<div class="ipdx-card"><div class="table-responsive"><table class="table table-sm align-middle mb-0 clin-orders"><thead><tr><th>Order</th><th>Doctor</th><th>Ordered</th><th>Status</th><th class="text-end">Actions</th></tr></thead><tbody>`;
        os.forEach(o => {
            const active = o.Status === 'ACTIVE', verbal = o.Source !== 'DIRECT';
            const acts = [];
            if (verbal && !o.CountersignedAt && o.Status !== 'CANCELLED' && C.can.countersign && my && my === o.DoctorId) acts.push(`<button type="button" class="btn btn-sm btn-success" data-act="Countersign" data-id="${o.OrderId}">Countersign</button>`);
            if (active && o.OrderType === 'MED' && o.ItemId && !o.IndentId && C.can.indent && C.can.order && st().BillOpen) acts.push(`<button type="button" class="btn btn-sm btn-outline-primary" data-indent="${o.OrderId}">To pharmacy</button>`);
            if (active && C.can.order && canWrite()) acts.push(`<button type="button" class="btn btn-sm btn-outline-secondary" data-act="StopOrder" data-id="${o.OrderId}">Stop</button>`,
                `<button type="button" class="btn btn-sm btn-link text-danger p-0 ms-1" data-act="CancelOrder" data-id="${o.OrderId}" title="Cancel an order entered in error">Cancel</button>`);
            h += `<tr class="${active ? '' : 'text-muted'}"><td><span class="clin-type t-${o.OrderType}">${TYPE[o.OrderType]}</span>${o.Priority !== 'ROUTINE' ? ` <span class="badge ${o.Priority === 'STAT' ? 'text-bg-danger' : 'text-bg-warning'}">${o.Priority}</span>` : ''}<div>${orderText(o)}</div></td>
                <td class="small">${E(o.DoctorName)}</td>
                <td class="small text-nowrap">${Ipd.dt(o.OrderedAt)}<div class="text-muted">${E(o.OrderedByName)}</div>
                    ${verbal ? `<span class="badge ${o.CountersignedAt ? 'text-bg-success' : o.CountersignOverdue ? 'text-bg-danger' : 'text-bg-warning'}">${o.Source.toLowerCase()}${o.CountersignedAt ? ' · countersigned' : o.CountersignOverdue ? ' · countersign overdue' : ' · ' + U.dueText(o.CountersignDueAt).replace('due in', 'countersign in')}</span>` : ''}</td>
                <td class="small">${{ ACTIVE: '<span class="badge text-bg-primary">active</span>', COMPLETED: '<span class="badge text-bg-success">completed</span>', STOPPED: '<span class="badge text-bg-secondary">stopped</span>', CANCELLED: '<span class="badge text-bg-light border">cancelled</span>' }[o.Status]}
                    ${o.AckAt ? `<div class="text-muted">seen by ${E(o.AckByName)}</div>` : active ? '<div class="text-warning-emphasis">not yet seen by nurse</div>' : ''}${o.StopReason ? `<div class="text-muted">${E(o.StopReason)}</div>` : ''}</td>
                <td class="text-end text-nowrap">${acts.join(' ')}</td></tr>`;
        });
        $('clinPane').innerHTML = h + '</tbody></table></div></div>';
    }

    // who-ordered block for a non-doctor login (verbal / telephone)
    function verbalBlock() {
        if (isDoctor()) return '';
        return `<div class="col-12"><div class="clin-verbal">
            <div class="row g-2">${U.field('oDoc', 'Doctor who gave the order', U.sel('oDoc', (D.doctors || []).map(d => [d.DoctorId, d.FullName]), C.consultant || st().ConsultantDoctorId), 'col-12 col-md-5', true)}
            ${U.field('oSrc', 'Given', U.sel('oSrc', [['TELEPHONE', 'By telephone'], ['VERBAL', 'In person (verbal)']]), 'col-6 col-md-3', true)}
            <div class="col-12 col-md-4 d-flex align-items-end"><div class="form-check"><input class="form-check-input" type="checkbox" id="oRead" /><label class="form-check-label small" for="oRead">Read back to the doctor and confirmed</label></div></div></div>
            <div class="small text-muted mt-1">The doctor countersigns it within ${st().CountersignHours} hours.</div></div></div>`;
    }
    const who = () => isDoctor() ? {} : { doctorId: U.n('oDoc'), source: U.v('oSrc'), readBack: U.chk('oRead') };

    function newOrder(type) {
        let body = '';
        if (type === 'MED') {
            const fr = (D.frequencies || []).map(f => [f.FrequencyCode, f.FrequencyName]);
            body = `<div class="row g-2">
                <div class="col-12 position-relative"><label class="form-label small fw-semibold mb-1" for="oDrug">Medicine <span class="text-danger">*</span></label>
                    <input id="oDrug" class="form-control form-control-sm" placeholder="Type to search the pharmacy item list, or type the name" autocomplete="off" />
                    <div id="oDrugSug" class="sug-list list-group" style="display:none"></div><div id="oDrugInfo" class="small mt-1"></div></div>
                ${U.field('oDose', 'Dose', U.text('oDose', '', 'placeholder="e.g. 500 mg, 1 tab, 10 units"'), 'col-6 col-md-3', true)}
                ${U.field('oRoute', 'Route', U.sel('oRoute', ROUTES, 'PO'), 'col-6 col-md-3', true)}
                ${U.field('oFreq', 'Frequency', U.sel('oFreq', fr, 'BD'), 'col-6 col-md-3', true)}
                ${U.field('oDays', 'Days', U.num('oDays', 1, 90, 1, ''), 'col-6 col-md-3')}
                ${U.field('oStart', 'Start', U.when('oStart'), 'col-6 col-md-4', true)}
                ${U.field('oPri', 'Priority', U.sel('oPri', PRI, 'ROUTINE'), 'col-6 col-md-3')}
                ${U.field('oNote', 'Instructions', U.text('oNote', '', 'placeholder="e.g. after food, slow IV over 30 min" maxlength="1000"'), 'col-12 col-md-5')}
                <div class="col-12 ${C.can.indent && st().BillOpen ? '' : 'd-none'}" id="oIndentRow"><div class="d-flex align-items-center gap-2 flex-wrap">
                    <div class="form-check"><input class="form-check-input" type="checkbox" id="oIndent" checked /><label class="form-check-label small" for="oIndent">Also send to the pharmacy (indent on the Medicines tab)</label></div>
                    <input id="oIndentQty" type="number" class="form-control form-control-sm" style="width:110px" min="1" step="1" placeholder="Qty" />
                    <span class="small text-muted" id="oUom"></span></div></div>
                ${verbalBlock()}</div>`;
        } else if (type === 'SERVICE') {
            body = `<div class="row g-2">
                <div class="col-12 position-relative"><label class="form-label small fw-semibold mb-1" for="oSvc">Service / procedure <span class="text-danger">*</span></label>
                    <input id="oSvc" class="form-control form-control-sm" placeholder="Type to search Hospital Services and Procedures" autocomplete="off" />
                    <div id="oSvcSug" class="sug-list list-group" style="display:none"></div><div id="oSvcInfo" class="small mt-1 text-muted">Charged to the bill when the nurse marks it done.</div></div>
                ${U.field('oQty', 'Quantity', U.num('oQty', 1, 100, 1, 1), 'col-6 col-md-3', true)}
                ${U.field('oPri', 'Priority', U.sel('oPri', PRI, 'ROUTINE'), 'col-6 col-md-3')}
                ${U.field('oNote', 'Instructions', U.text('oNote', '', 'maxlength="1000"'), 'col-12 col-md-6')}
                ${verbalBlock()}</div>`;
        } else if (type === 'DIET') {
            body = `<div class="row g-2">${U.field('oDiet', 'Diet', U.sel('oDiet', DIETS, '', '-- choose --'), 'col-12 col-md-6', true)}
                ${U.field('oNote', 'Details', U.text('oNote', '', 'placeholder="e.g. 1800 kcal, fluid restriction 1.5 l/day" maxlength="1000"'), 'col-12 col-md-6')}
                <div class="col-12 small text-muted">A new diet order replaces the running one.</div>${verbalBlock()}</div>`;
        } else {
            body = `<div class="row g-2">${U.field('oNote', 'Instruction', U.area('oNote', '', 3, 1000), 'col-12', true)}
                ${U.field('oPri', 'Priority', U.sel('oPri', PRI, 'ROUTINE'), 'col-6 col-md-3')}${verbalBlock()}</div>`;
        }
        U.modal('clinOrderModal', 'New order · ' + TYPE[type], body, '<button type="button" class="btn btn-primary" id="oSave">Save order</button>');
        let pick = null;
        if (type === 'MED') suggest('oDrug', 'oDrugSug', async q => (await Ipd.get(`${C.phBase}IndentItems?id=${C.id}&q=${encodeURIComponent(q)}`)).items || [],
            x => `${E(x.ItemName)}${x.IsHighAlert ? ' <span class="badge text-bg-danger">high alert</span>' : ''} <span class="small text-muted">· stock ${Number(x.Stock || 0)} ${E(x.SaleUom || '')}</span>`,
            x => { pick = x; $('oDrug').value = x.ItemName; $('oDrugInfo').innerHTML = x.IsHighAlert ? '<span class="text-danger"><i class="bi bi-exclamation-triangle me-1"></i>High-alert medicine: the nurse needs a second check to give it.</span>' : ''; $('oUom').textContent = x.SaleUom || ''; },
            () => { pick = null; $('oDrugInfo').innerHTML = ''; });
        if (type === 'MED') {
            // quantity for the pharmacy = doses a day x days (STAT = 1); the user can change it
            const fq = () => {
                const f = (D.frequencies || []).find(x => x.FrequencyCode === U.v('oFreq')), days = U.n('oDays');
                const perDay = f ? (f.Kind === 'STAT' ? 1 : f.Kind === 'PRN' ? 0 : String(f.TimesCsv || '').split(',').filter(Boolean).length) : 0;
                const q = f && f.Kind === 'STAT' ? 1 : perDay && days ? perDay * days : null;
                if (q && !$('oIndentQty').dataset.typed) $('oIndentQty').value = q;
            };
            ['oFreq', 'oDays'].forEach(id => $(id).addEventListener('input', fq));
            $('oFreq').addEventListener('change', fq);
            $('oIndentQty').addEventListener('input', () => { $('oIndentQty').dataset.typed = '1'; });
        }
        if (type === 'SERVICE') suggest('oSvc', 'oSvcSug', async q => await Ipd.get(`${base}Services?q=${encodeURIComponent(q)}`) || [],
            x => `${E(x.Name)} <span class="small text-muted">· ${x.Kind === 'PROCEDURE' ? 'procedure' : 'service'}${x.Code ? ' · ' + E(x.Code) : ''}</span>`, x => { pick = x; $('oSvc').value = x.Name; }, () => { pick = null; });
        $('oSave').addEventListener('click', async () => {
            const b = Object.assign({ orderType: type, priority: U.v('oPri') || 'ROUTINE', details: U.v('oNote') || null }, who());
            if (type === 'MED') Object.assign(b, { itemId: pick ? pick.ItemId : null, drugName: pick ? null : (U.v('oDrug') || null), dose: U.v('oDose'), route: U.v('oRoute'),
                frequencyCode: U.v('oFreq'), startAt: U.v('oStart') || null, durationDays: U.n('oDays') });
            if (type === 'SERVICE') { if (!pick) { Ipd.error('Choose the service or procedure from the list.'); return; } Object.assign(b, { serviceKind: pick.Kind, refId: pick.RefId, qty: U.n('oQty') }); }
            if (type === 'DIET') b.dietType = U.v('oDiet');
            const sendIndent = type === 'MED' && pick && C.can.indent && st().BillOpen && U.chk('oIndent');
            if (sendIndent && !(U.n('oIndentQty') > 0)) { Ipd.error('Enter the quantity to send to the pharmacy.'); return; }
            $('oSave').disabled = true;
            try {
                const r = await U.save(`${base}SaveOrder?id=${C.id}`, b, null);
                if (!r) return;
                Ipd.toast(r.Source !== 'DIRECT' ? 'Verbal order saved: the doctor countersigns it' : 'Order saved');
                if (sendIndent) await sendToPharmacy(r.OrderId, pick.ItemId, U.n('oIndentQty'), b.priority, b.doctorId);
                U.hide('clinOrderModal'); load();
                document.dispatchEvent(new CustomEvent('ipd:indent-changed'));
            } finally { const s = $('oSave'); if (s) s.disabled = false; }
        });
    }

    async function sendToPharmacy(orderId, itemId, qty, priority, doctorId) {
        const r = await Ipd.post(`${C.phBase}IndentSave?id=${C.id}`, { lines: [{ itemId, qty }], doctorId: doctorId || st().MyDoctorId || null, priority: priority === 'ROUTINE' ? 'ROUTINE' : priority });
        if (!r.success) { Ipd.error('The order is saved, but the indent was not sent: ' + (r.error || '')); return; }
        Ipd.toast('Indent ' + (r.data.IndentNo || '') + ' sent to the pharmacy');
        if (r.data.IndentId) await Ipd.post(`${base}LinkIndent`, { orderId, indentId: r.data.IndentId });
    }

    /** search-as-you-type list under an input */
    function suggest(inputId, boxId, fetcher, label, onPick, onClear) {
        const inp = $(inputId), box = $(boxId); let t, items = [], idx = 0;
        const draw = () => { box.innerHTML = items.map((x, i) => `<button type="button" class="list-group-item list-group-item-action sug py-2 px-3 ${i === idx ? 'active' : ''}" data-i="${i}">${label(x)}</button>`).join(''); box.style.display = items.length ? 'block' : 'none'; };
        inp.addEventListener('input', () => {
            onClear(); clearTimeout(t); const q = inp.value.trim();
            if (q.length < 2) { box.style.display = 'none'; return; }
            t = setTimeout(async () => { try { items = await fetcher(q); } catch { items = []; } idx = 0; draw(); }, 250);
        });
        inp.addEventListener('keydown', e => {
            if (box.style.display !== 'block') return;
            if (e.key === 'ArrowDown' || e.key === 'ArrowUp') { e.preventDefault(); idx = (idx + (e.key === 'ArrowDown' ? 1 : -1) + items.length) % items.length; draw(); }
            else if (e.key === 'Enter') { e.preventDefault(); onPick(items[idx]); box.style.display = 'none'; }
            else if (e.key === 'Escape') box.style.display = 'none';
        });
        box.addEventListener('mousedown', e => e.preventDefault());
        box.addEventListener('click', e => { const b = e.target.closest('[data-i]'); if (b) { onPick(items[Number(b.dataset.i)]); box.style.display = 'none'; } });
    }

    // ── rounds & notes ─────────────────────────────────────────────────────────────────────────────────────────
    const NOTE = { ROUND: 'Daily round', PROGRESS: 'Progress note', CROSS: 'Cross-consultation' };
    function renderNotes() {
        const ns = D.notes || [], w = canWrite() && C.can.note, my = st().MyDoctorId;
        let h = w ? `<div class="d-flex flex-wrap gap-2 mb-2"><button type="button" class="btn btn-sm btn-primary" data-note="ROUND"><i class="bi bi-plus-lg me-1"></i>Round note</button>
            <button type="button" class="btn btn-sm btn-outline-primary" data-note="PROGRESS"><i class="bi bi-plus-lg me-1"></i>Progress note</button>
            ${st().AutoVisitCharge ? '<span class="small text-muted align-self-center">Signing a round charges the doctor\'s visit (once a day).</span>' : ''}</div>` : '';
        if (!ns.length) { $('clinPane').innerHTML = h + '<div class="ipd-soon py-4"><div class="small">No notes yet.</div></div>'; return; }
        ns.forEach(n => {
            const struck = n.Status === 'STRUCK', draft = n.Status === 'DRAFT';
            h += `<div class="ipdx-card clin-note ${struck ? 'struck' : ''} mb-2"><div class="d-flex justify-content-between flex-wrap gap-2">
                <div><span class="clin-type t-${n.NoteType}">${NOTE[n.NoteType]}</span> <b>${E(n.DoctorName)}</b> <span class="small text-muted">${Ipd.dt(n.NoteAt)}</span>
                    ${draft ? '<span class="badge text-bg-warning ms-1">draft</span>' : struck ? `<span class="badge text-bg-secondary ms-1" title="${E(n.StruckReason)}">struck out</span>` : '<span class="badge text-bg-success ms-1">signed</span>'}
                    ${n.ChargeId ? `<span class="badge text-bg-light border ms-1"><i class="bi bi-receipt me-1"></i>visit ${Ipd.money(n.ChargeAmount)}</span>` : n.ChargeNote && n.Status === 'SIGNED' ? `<span class="small text-muted ms-1">${E(n.ChargeNote)}</span>` : ''}</div>
                <div class="text-nowrap">${draft && w && my === n.DoctorId ? `<button type="button" class="btn btn-sm btn-success" data-edit-note="${n.NoteId}">Open &amp; sign</button>` : draft && w ? `<button type="button" class="btn btn-sm btn-outline-secondary" data-edit-note="${n.NoteId}">Edit draft</button>` : ''}
                    ${!struck && C.can.correct && canWrite() ? `<button type="button" class="btn btn-sm btn-link text-danger" data-strike="PNOTE:${n.NoteId}">Strike out</button>` : ''}</div></div>
                <div class="clin-soap">${[['S', n.Subjective], ['O', n.Objective], ['A', n.Assessment], ['P', n.PlanText]].filter(x => x[1]).map(([k, t]) => `<div><b>${k}</b><span>${E(t)}</span></div>`).join('')}</div>
                ${struck ? `<div class="small text-danger">Struck out: ${E(n.StruckReason)}</div>` : ''}</div>`;
        });
        $('clinPane').innerHTML = h;
    }

    function noteModal(type, note, consult) {
        const n = note || {}, my = st().MyDoctorId;
        const docSel = my ? '' : U.field('nDoc', 'Doctor', U.sel('nDoc', (D.doctors || []).map(d => [d.DoctorId, d.FullName]), n.DoctorId || st().ConsultantDoctorId), 'col-12 col-md-6', true);
        const body = `${consult ? `<div class="alert alert-info py-2 small"><b>Asked by ${E(consult.FromDoctorName)}:</b> ${E(consult.Reason)}</div>` : ''}
            ${my ? '' : '<div class="alert alert-warning py-2 small">Your login is not a doctor: the note is saved as a draft for the doctor to sign.</div>'}
            <div class="row g-2">${docSel}${U.field('nAt', 'Time', U.when('nAt', n.NoteAt), 'col-6 col-md-4')}
            ${U.field('nS', 'S · Subjective (complaints, how the patient feels)', U.area('nS', n.Subjective), 'col-12')}
            ${U.field('nO', 'O · Objective (examination, vitals, results)', U.area('nO', n.Objective), 'col-12')}
            ${U.field('nA', 'A · Assessment (diagnosis, progress)', U.area('nA', n.Assessment), 'col-12', true)}
            ${U.field('nP', 'P · Plan (treatment, orders, next steps)', U.area('nP', n.PlanText), 'col-12', true)}</div>`;
        U.modal('clinNoteModal', (NOTE[type] || 'Note') + (note ? ' (draft)' : ''), body,
            `<button type="button" class="btn btn-outline-primary" id="nDraft">Save draft</button>${my ? '<button type="button" class="btn btn-success" id="nSign"><i class="bi bi-pen me-1"></i>Sign</button>' : ''}`);
        const go = async sign => {
            if (sign && !(await Ipd.confirm('Sign this note?', 'A signed note cannot be changed (only struck out with a reason).' + (type !== 'PROGRESS' && st().AutoVisitCharge ? '<br>The visit is charged to the bill (once a day).' : ''), 'Sign'))) return;
            const r = await U.save(`${base}SaveNote?id=${C.id}`, { noteId: n.NoteId || null, noteType: type, doctorId: my ? null : U.n('nDoc'), noteAt: U.v('nAt') || null,
                subjective: U.v('nS'), objective: U.v('nO'), assessment: U.v('nA'), planText: U.v('nP'), sign, crossConsultId: consult ? consult.ConsultId : (n.CrossConsultId || null) });
            if (!r) return;
            Ipd.toast(sign ? 'Note signed' + (r.ChargeNote ? ' · ' + r.ChargeNote : '') : 'Draft saved');
            U.hide('clinNoteModal'); load();
        };
        $('nDraft').addEventListener('click', () => go(false));
        $('nSign')?.addEventListener('click', () => go(true));
    }

    // ── doctor's initial assessment ────────────────────────────────────────────────────────────────────────────
    const AF = [['chiefComplaints', 'Chief complaints', 1], ['historyOfIllness', 'History of present illness', 1], ['pastHistory', 'Past medical / surgical history'],
        ['medications', 'Current medicines'], ['familyHistory', 'Family / personal history'], ['allergies', 'Allergies'], ['examination', 'General and systemic examination', 1],
        ['provisionalDiagnosis', 'Provisional diagnosis', 1], ['investigations', 'Investigations planned'], ['plan', 'Plan of care (treatment, goals, expected stay)', 1],
        ['nutritionScreen', 'Nutritional screening'], ['painScore', 'Pain assessment']];
    function renderAssess() {
        const all = (D.assessments || []).filter(a => a.Kind === 'DOCTOR'), cur = all.find(a => a.Status !== 'SUPERSEDED');
        const data = cur ? JSON.parse(cur.Data || '{}') : {}, signed = cur && cur.Status === 'SIGNED';
        const w = canWrite() && C.can.assess;
        let h = `<div class="small text-muted mb-2">NABH: the doctor's initial assessment is done within ${Math.round((new Date(st().DoctorAssessDueAt) - new Date(st().AdmissionAt)) / 3600000)} hours of admission (${Ipd.dt(st().DoctorAssessDueAt)}). Fields with * are needed to sign.</div>`;
        if (signed) {
            h += `<div class="ipdx-card mb-2"><div class="d-flex justify-content-between flex-wrap gap-2 mb-2"><div><span class="badge text-bg-success">signed</span> <b>${E(cur.DoctorName)}</b> <span class="small text-muted">${Ipd.dt(cur.SignedAt)} · version ${cur.Version}${cur.AmendReason ? ' · amended: ' + E(cur.AmendReason) : ''}</span></div>
                ${w && isDoctor() ? '<button type="button" class="btn btn-sm btn-outline-primary" id="aAmend"><i class="bi bi-pencil me-1"></i>Amend</button>' : ''}</div>
                <dl class="row small mb-0">${AF.filter(f => data[f[0]]).map(f => `<dt class="col-md-3">${f[1]}</dt><dd class="col-md-9" style="white-space:pre-wrap">${E(data[f[0]])}</dd>`).join('')}</dl></div>`;
        } else h += assessForm(data, w, cur);
        const old = all.filter(a => a.Status === 'SUPERSEDED');
        if (old.length) h += `<details class="small"><summary class="text-muted">Earlier versions (${old.length})</summary>${old.map(a => `<div class="mt-1">Version ${a.Version} · ${E(a.DoctorName)} · signed ${Ipd.dt(a.SignedAt)}</div>`).join('')}</details>`;
        $('clinPane').innerHTML = h;
    }
    function assessForm(data, w, cur, amend) {
        return `<div class="ipdx-card"><div class="row g-2">${AF.map(([k, t, req]) => U.field('af_' + k, t, U.area('af_' + k, data[k] || '', k === 'examination' || k === 'historyOfIllness' ? 3 : 2), 'col-12 col-md-6', !!req)).join('')}</div>
            ${amend ? U.field('afReason', 'Reason for the amendment', U.text('afReason'), 'col-12', true) : ''}
            ${w ? `<div class="d-flex gap-2 mt-2"><button type="button" class="btn btn-sm btn-outline-primary" data-asave="0">Save draft</button>${isDoctor() ? '<button type="button" class="btn btn-sm btn-success" data-asave="1"><i class="bi bi-pen me-1"></i>Sign</button>' : '<span class="small text-muted align-self-center">A doctor signs it.</span>'}</div>` : ''}
            ${cur ? `<div class="small text-muted mt-1">${cur.Status === 'DRAFT' ? 'Draft saved ' + Ipd.dt(cur.ModifiedDate || cur.CreatedDate) + ' by ' + E(cur.CreatedByName) : ''}</div>` : ''}</div>`;
    }
    async function saveAssess(sign, amend) {
        const data = {}; AF.forEach(([k]) => { const x = U.v('af_' + k); if (x) data[k] = x; });
        const r = await U.save(`${base}SaveAssessment?id=${C.id}`, { data: JSON.stringify(data), sign, amendReason: amend ? U.v('afReason') : null }, sign ? 'Assessment signed' : 'Draft saved');
        if (r) load();
    }

    // ── cross-consultation ─────────────────────────────────────────────────────────────────────────────────────
    function renderConsults() {
        const cs = D.consults || [], my = st().MyDoctorId, w = canWrite();
        let h = w && C.can.consult ? '<button type="button" class="btn btn-sm btn-primary mb-2" id="cxNew"><i class="bi bi-plus-lg me-1"></i>Ask a doctor</button>' : '';
        if (!cs.length) { $('clinPane').innerHTML = h + '<div class="ipd-soon py-4"><div class="small">No cross-consultations.</div></div>'; return; }
        h += '<div class="ipdx-card"><table class="table table-sm align-middle mb-0"><thead><tr><th>To</th><th>Asked by</th><th>Question</th><th>Status</th><th></th></tr></thead><tbody>';
        cs.forEach(c => {
            h += `<tr><td><b>${E(c.ToDoctorName)}</b>${c.Urgency === 'URGENT' ? ' <span class="badge text-bg-danger">urgent</span>' : ''}</td>
                <td class="small">${E(c.FromDoctorName)}<div class="text-muted">${Ipd.dt(c.RequestedAt)}</div></td><td class="small">${E(c.Reason)}</td>
                <td class="small">${{ REQUESTED: '<span class="badge text-bg-warning">waiting</span> ' + U.ago(c.RequestedAt), SEEN: '<span class="badge text-bg-success">seen</span> ' + Ipd.dt(c.SeenAt), CANCELLED: '<span class="badge text-bg-light border">cancelled</span> ' + E(c.CancelReason || '') }[c.Status]}</td>
                <td class="text-end text-nowrap">${c.Status === 'REQUESTED' && w && C.can.note && my === c.ToDoctorId ? `<button type="button" class="btn btn-sm btn-success" data-answer="${c.ConsultId}">Answer</button>` : ''}
                    ${c.Status === 'REQUESTED' && w && C.can.consult ? `<button type="button" class="btn btn-sm btn-link text-danger" data-cxcancel="${c.ConsultId}">Cancel</button>` : ''}</td></tr>`;
        });
        $('clinPane').innerHTML = h + '</tbody></table></div>';
    }
    function consultModal() {
        U.modal('clinCxModal', 'Ask a doctor (cross-consultation)', `<div class="row g-2">
            ${U.field('cxDoc', 'Doctor', U.sel('cxDoc', (D.doctors || []).filter(d => d.DoctorId !== st().MyDoctorId).map(d => [d.DoctorId, d.FullName]), '', '-- choose --'), 'col-12 col-md-7', true)}
            ${U.field('cxUrg', 'Urgency', U.sel('cxUrg', [['ROUTINE', 'Routine'], ['URGENT', 'Urgent']]), 'col-12 col-md-5')}
            ${U.field('cxWhy', 'Question for the doctor', U.area('cxWhy', '', 3, 1000), 'col-12', true)}</div>
            <div class="small text-muted mt-1">The doctor answers with a cross-consultation note; signing it charges the cross-consultation visit.</div>`,
            '<button type="button" class="btn btn-primary" id="cxSave">Send request</button>');
        $('cxSave').addEventListener('click', async () => {
            if (await U.save(`${base}CrossConsult?id=${C.id}`, { toDoctorId: U.n('cxDoc'), urgency: U.v('cxUrg'), reason: U.v('cxWhy') }, 'Request sent')) { U.hide('clinCxModal'); load(); }
        });
    }

    // ── events ─────────────────────────────────────────────────────────────────────────────────────────────────
    document.getElementById('tab-clinical').addEventListener('click', async e => {
        const t = e.target.closest('button,a'); if (!t) return;
        if (t.dataset.pane) { pane = t.dataset.pane; render(); return; }
        if (t.dataset.new) { newOrder(t.dataset.new); return; }
        if (t.dataset.goTab) { document.querySelector(`[data-bs-target="#tab-${t.dataset.goTab}"]`)?.click(); return; }
        if (t.dataset.act) {
            const id = Number(t.dataset.id), a = t.dataset.act;
            let reason = null;
            if (a === 'StopOrder') { reason = await Ipd.reason('Stop this order?', 'Reason (e.g. course complete, changed to oral)'); if (!reason) return; }
            if (a === 'CancelOrder') { reason = await Ipd.reason('Cancel this order (entered in error)?', 'Reason'); if (!reason) return; }
            if (a === 'Countersign' && !(await Ipd.confirm('Countersign this order?', 'You confirm you gave this verbal / telephone order.', 'Countersign'))) return;
            if (await U.save(`${base}${a}`, { orderId: id, reason }, { StopOrder: 'Order stopped', CancelOrder: 'Order cancelled', Countersign: 'Countersigned' }[a])) load();
            return;
        }
        if (t.dataset.indent) {
            const o = D.orders.find(x => x.OrderId === Number(t.dataset.indent));
            const r = await Swal.fire({ title: 'Send to the pharmacy', html: `${E(o.DrugName)} ${E(o.Dose)}`, input: 'number', inputLabel: 'Quantity', inputAttributes: { min: 1, step: 1 },
                showCancelButton: true, confirmButtonText: 'Send', inputValidator: v => (!v || Number(v) <= 0) ? 'Enter the quantity.' : undefined });
            if (r.isConfirmed) { await sendToPharmacy(o.OrderId, o.ItemId, Number(r.value), o.Priority, o.DoctorId); load(); }
            return;
        }
        if (t.dataset.note) { noteModal(t.dataset.note); return; }
        if (t.dataset.editNote) { const n = D.notes.find(x => x.NoteId === Number(t.dataset.editNote)); noteModal(n.NoteType, n, n.CrossConsultId ? D.consults.find(c => c.ConsultId === n.CrossConsultId) : null); return; }
        if (t.dataset.strike) { const [k, id] = t.dataset.strike.split(':'); U.strike(base, k, Number(id), load); return; }
        if (t.dataset.asave != null) { saveAssess(t.dataset.asave === '1', !!$('afReason')); return; }
        if (t.id === 'aAmend') {
            const cur = (D.assessments || []).find(a => a.Kind === 'DOCTOR' && a.Status !== 'SUPERSEDED');
            $('clinPane').innerHTML = '<div class="alert alert-info py-2 small">Amending the signed assessment: the signed version is kept and a new version is signed.</div>' + assessForm(JSON.parse(cur.Data || '{}'), true, null, true);
            return;
        }
        if (t.id === 'cxNew') { consultModal(); return; }
        if (t.dataset.answer) { const c = D.consults.find(x => x.ConsultId === Number(t.dataset.answer)); noteModal('CROSS', null, c); return; }
        if (t.dataset.cxcancel) {
            const reason = await Ipd.reason('Cancel the request?', 'Reason'); if (!reason) return;
            if (await U.save(`${base}CrossConsult?id=${C.id}`, { consultId: Number(t.dataset.cxcancel), cancel: true, cancelReason: reason }, 'Request cancelled')) load();
        }
    });

    // Medicines tab > "Prescribe (dose & frequency)": the same prescription form (it needs the Clinical data: frequencies, doctors, state)
    document.addEventListener('click', async e => {
        if (!e.target.closest('.ipd-prescribe')) return;
        if (!D) { try { D = await Ipd.get(`${base}Data?id=${C.id}`); } catch (er) { Ipd.error(er.message); return; } }
        if (!canWrite()) { Ipd.error('The patient is not in hospital any more: medicines cannot be prescribed.'); return; }
        newOrder('MED');
    });

    // load when the tab is first shown (or the page opens on it)
    const btn = document.querySelector('[data-bs-target="#tab-clinical"]');
    btn?.addEventListener('shown.bs.tab', () => { if (!loaded) { loaded = true; load(); } });
    if (document.getElementById('tab-clinical').classList.contains('active')) { loaded = true; load(); }
    window.IpdClinReload = load;
})();
