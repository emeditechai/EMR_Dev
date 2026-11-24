/* Settings > Notification Languages (SQLScripts/2543). Config: window.NotifyPage */
(function () {
    'use strict';
    const P = window.NotifyPage, $ = id => document.getElementById(id), esc = v => Ipd.esc(v);
    let d = null;

    // the English text of each notification (as sent today) comes with the event (NotifyEvent.Ref*, SQLScripts/2544)
    const english = (e, ch) => ch === 'EMAIL'
        ? { subject: e.RefEmailSubject, heading: e.RefEmailHeading, body: e.RefEmailBody }
        : { body: e.RefWhatsApp };
    const SAMPLE = { PatientName: 'Ramesh Kumar', CardHolderName: 'Ramesh Kumar', CustomerName: 'Ramesh Kumar', HospitalName: 'City Care Hospital',
                     PharmacyName: 'City Care Pharmacy', BranchName: 'City Care Hospital', BillNo: 'LAB/HO2627000425', TokenNo: 'LAB-HO-0012', Amount: '1,250.00',
                     BillDate: new Date().toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' }), HospitalAddress: '12 Park Street, Kolkata',
                     DoctorName: 'Dr. A. Sen', PatientCode: 'HO000123', Code: '482913', Points: '100', PointsValue: '100.00', CardNo: 'MC-000045', PlanName: 'Gold' };
    // as the server fills it (EMR.Common.NotifyText.Fill): optional parts {#Key}..{/Key} / {^Key}..{/Key}, then {Key}
    const fill = (t, v) => {
        let s = String(t || '');
        for (let i = 0; i < 10 && s.includes('{/'); i++) {
            const n = s.replace(/\{([#^])(\w+)\}([\s\S]*?)\{\/\2\}/g, (m, op, k, inner) => {
                const has = v[k] != null && String(v[k]).trim() !== '' && String(v[k]) !== '0';
                return (op === '#') === has ? inner : '';
            });
            if (n === s) break;
            s = n;
        }
        return s.replace(/\{(\w+)\}/g, (m, k) => k in v ? v[k] : m);
    };
    const CH = { WHATSAPP: 'WhatsApp', EMAIL: 'E-mail' };

    async function load() {
        try {
            d = await Ipd.get(P.base + 'Data');
            if (!$('fEvent').options.length) $('fEvent').innerHTML = (d.events || []).map(e => `<option value="${esc(e.EventCode)}">${esc(e.Name)}</option>`).join('');
            render();
        } catch (e) { $('rows').innerHTML = `<tr><td colspan="7" class="text-danger small p-3">${esc(e.message)}</td></tr>`; }
    }
    const ev = () => (d.events || []).find(e => e.EventCode === $('fEvent').value) || {};

    function render() {
        const e = ev();
        $('evInfo').innerHTML = `<b>${esc(e.Name || '')}</b> · ${esc(e.Description || '')}<br>Placeholders: <code>${esc(e.Placeholders || '')}</code>`;
        const list = (d.templates || []).filter(t => t.EventCode === e.EventCode);
        $('rows').innerHTML = list.map(t => `<tr class="${t.IsActive ? '' : 'text-muted'}">
            <td class="fw-semibold">${esc(t.LanguageName)}</td><td>${CH[t.Channel] || t.Channel}</td><td>${t.BranchId ? esc(t.BranchName) : '<span class="text-muted">All branches</span>'}</td>
            <td style="max-width:560px">${t.Subject ? `<div class="small fw-semibold">${esc(t.Subject)}</div>` : ''}<div class="small text-truncate">${esc(t.Body)}</div></td>
            <td>${t.IsActive ? '<span class="ipd-pill info">Active</span>' : '<span class="ipd-pill muted">Off</span>'}</td>
            <td class="small">${t.ModifiedDate || t.CreatedDate ? Ipd.date(t.ModifiedDate || t.CreatedDate) : ''}<div class="text-muted">${esc(t.ChangedByName || '')}</div></td>
            <td class="text-end"><button type="button" class="btn btn-sm btn-light border py-0" data-id="${t.TemplateId}"><i class="bi bi-${P.canEdit ? 'pencil' : 'eye'}"></i></button></td></tr>`).join('')
            || '<tr><td colspan="7" class="text-muted small p-3">No texts yet: every patient gets the English message.</td></tr>';
        document.querySelectorAll('#rows [data-id]').forEach(b => b.addEventListener('click', () => edit((d.templates || []).find(t => t.TemplateId === +b.dataset.id))));
    }

    async function edit(t) {
        const e = ev(), langs = (d.languages || []), branches = d.branches || [];
        const chans = (e.Channels || 'WHATSAPP').split(',');
        const ph = (e.Placeholders || '').split(',').filter(Boolean);
        const ro = !P.canEdit ? 'disabled' : '';
        const r = await Swal.fire({
            title: t ? 'Notification text' : 'Add notification text', width: 900, showCancelButton: P.canEdit, showConfirmButton: P.canEdit, confirmButtonText: 'Save', focusConfirm: false,
            html: `<div class="text-start small row g-2">
                <div class="col-md-4"><label class="form-label fw-semibold">Language</label><select id="nLang" class="form-select form-select-sm" ${ro}>${langs.map(l => `<option value="${l.LanguageId}" ${t && t.LanguageId === l.LanguageId ? 'selected' : (!t && l.LanguageCode === 'hi' ? 'selected' : '')}>${esc(l.LanguageName)}</option>`).join('')}</select></div>
                <div class="col-md-4"><label class="form-label fw-semibold">Channel</label><select id="nCh" class="form-select form-select-sm" ${ro}>${chans.map(c => `<option value="${c}" ${t && t.Channel === c ? 'selected' : ''}>${CH[c] || c}</option>`).join('')}</select></div>
                <div class="col-md-4"><label class="form-label fw-semibold">Branch</label><select id="nBr" class="form-select form-select-sm" ${ro}><option value="">All branches</option>${branches.map(b => `<option value="${b.BranchId}" ${t && t.BranchId === b.BranchId ? 'selected' : ''}>${esc(b.BranchName)}</option>`).join('')}</select></div>
                <div class="col-md-7"><div class="nEmail"><label class="form-label fw-semibold">Subject</label><input id="nSub" class="form-control form-control-sm" maxlength="300" value="${esc(t ? t.Subject || '' : '')}" ${ro}>
                    <label class="form-label fw-semibold mt-2">Heading</label><input id="nHead" class="form-control form-control-sm" maxlength="200" value="${esc(t ? t.Heading || '' : '')}" ${ro}></div>
                    <label class="form-label fw-semibold mt-2">Message <span class="text-muted fw-normal">(blank line = new paragraph)</span></label>
                    <textarea id="nBody" class="form-control form-control-sm" rows="11" ${ro}>${esc(t ? t.Body : '')}</textarea>
                    <div class="mt-1">${ph.map(p => `<button type="button" class="btn btn-sm btn-light border py-0 me-1 mb-1 nPh" data-ph="${esc(p)}" ${ro}>${esc(p)}</button>`).join('')}</div>
                    <div class="form-check form-switch mt-1"><input id="nAct" type="checkbox" class="form-check-input" ${!t || t.IsActive ? 'checked' : ''} ${ro}><label class="form-check-label" for="nAct">Active</label></div></div>
                <div class="col-md-5"><label class="form-label fw-semibold">English (as sent today)</label><div id="nRef" class="border rounded p-2 bg-light" style="white-space:pre-wrap;font-size:.78rem;max-height:170px;overflow:auto"></div>
                    <label class="form-label fw-semibold mt-2">Preview (sample patient)</label><div id="nPrev" class="border rounded p-2" style="white-space:pre-wrap;font-size:.8rem;max-height:220px;overflow:auto"></div></div></div>`,
            didOpen: () => {
                const upd = () => {
                    const ch = $('nCh').value, ref = english(e, ch);
                    document.querySelector('.nEmail').style.display = ch === 'EMAIL' ? '' : 'none';
                    $('nRef').textContent = (ref.subject ? 'Subject: ' + ref.subject + '\n' : '') + (ref.heading ? 'Heading: ' + ref.heading + '\n\n' : '') + (ref.body || '—');
                    $('nPrev').textContent = (ch === 'EMAIL' ? fill($('nSub').value, SAMPLE) + '\n\n' : '') + fill($('nBody').value, SAMPLE);
                };
                ['nCh', 'nSub', 'nBody'].forEach(id => $(id).addEventListener('input', upd));
                $('nCh').addEventListener('change', upd);
                document.querySelectorAll('.nPh').forEach(b => b.addEventListener('click', () => {
                    const ta = $('nBody'), s = ta.selectionStart ?? ta.value.length;
                    ta.value = ta.value.slice(0, s) + b.dataset.ph + ta.value.slice(ta.selectionEnd ?? s); ta.focus(); upd();
                }));
                upd();
            },
            preConfirm: () => {
                const v = { templateId: t ? t.TemplateId : null, eventCode: e.EventCode, channel: $('nCh').value, languageId: Number($('nLang').value),
                            branchId: $('nBr').value ? Number($('nBr').value) : null, subject: $('nSub').value.trim() || null, heading: $('nHead').value.trim() || null,
                            body: $('nBody').value.trim(), isActive: $('nAct').checked };
                if (!v.body) { Swal.showValidationMessage('Enter the message.'); return false; }
                if (v.channel === 'EMAIL' && !v.subject) { Swal.showValidationMessage('Enter the e-mail subject.'); return false; }
                return v;
            }
        });
        if (!r.isConfirmed) return;
        const x = await Ipd.post(P.base + 'Save', r.value);
        if (!x.success) return Ipd.error(x.error);
        Ipd.toast('Saved'); load();
    }

    $('fEvent').addEventListener('change', render);
    $('add')?.addEventListener('click', () => edit(null));
    load();
})();
