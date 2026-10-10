/*
 * Critical value communication (NABL; SQLScripts/2202) - the form in Views/Shared/_CriticalCommunicationModal.cshtml.
 *
 *   CriticalComm.ensure({ labOrderId, sampleIds, context })  -> Promise<boolean>
 *       Before a sign-off (context SIGNOFF = Pathologist Dashboard, ENTRY = Report Entry approval). Resolves true when
 *       nothing needs recording, or once recorded / skipped (skip only when no result is at its final sign-off);
 *       false when the user cancels. The server repeats the check, so this is the guide, not the guard.
 *       Hospital Settings > LAB > Critical Value Communication Required = No: resolves true at once, no form.
 *   CriticalComm.open({ labOrderId, sampleIds })               -> Promise<boolean>
 *       From the register (REGISTER): record, add a further attempt, or correct a record. Resolves true when saved.
 */
window.CriticalComm = (function () {
    const $m = () => $('#critCommModal');
    const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
    const pad = n => String(n).padStart(2, '0');
    const localNow = () => { const d = new Date(); return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`; };
    const fmtDT = s => { if (!s) return ''; const d = new Date(s); return isNaN(d) ? '' : d.toLocaleDateString('en-GB', { day: '2-digit', month: 'short' }) + ', ' + d.toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit' }); };
    const ROLE = { REFDOCTOR: 'Referring doctor', TREATDOCTOR: 'Treating doctor', PATIENT: 'Patient', ATTENDANT: 'Attendant', WARD: 'Ward / nurse', PARTNER: 'B2B partner', OTHER: 'Other' };
    const MODE = { PHONE: 'phone', INPERSON: 'in person', WHATSAPP: 'WhatsApp', SMS: 'SMS', EMAIL: 'email' };

    let state = null;   // { labOrderId, context, data, resolve, saved }

    function post(url, body) {
        return $.ajax({ url: url, type: 'POST', contentType: 'application/json', data: JSON.stringify(body) });
    }

    function statusHtml(r) {
        if (r.communicationStatus === 'INFORMED')
            return `<span class="badge bg-success-subtle text-success border border-success-subtle">Informed</span>
                    <div class="fs-9 text-muted">${esc(r.informedName)} · ${esc(MODE[r.informedMode] || r.informedMode)} · ${fmtDT(r.informedOn)}${r.readBack ? ' · read back' : ''}</div>
                    ${r.valueChangedSinceInformed ? '<div class="fs-9 text-danger">value changed since informed</div>' : ''}`;
        if (r.communicationStatus === 'ATTEMPTED')
            return `<span class="badge bg-warning-subtle text-warning-emphasis border border-warning-subtle">Attempted ×${r.attempts}</span>
                    <div class="fs-9 text-muted">${esc(r.lastName)} · ${fmtDT(r.lastOn)}${r.lastMessageStatus === 'QUEUED' ? ' · message sending' : ''}</div>`;
        return '<span class="badge bg-danger-subtle text-danger border border-danger-subtle">Not recorded</span>';
    }

    function render() {
        const d = state.data, c = d.contacts || {}, ctx = state.context;
        $('#ccBill').text(`${c.patientName || ''} (${c.patientCode || ''}) · Bill ${c.billNo || ''} · target: inform within ${c.targetMinutes || 30} min of the result`);
        const blocking = d.results.filter(r => r.blocksSignoff);
        $('#ccIntro').html(ctx === 'REGISTER'
            ? 'Record who was told about these results, a further attempt, or correct a record. Every record is kept in the history.'
            : (blocking.length
                ? `<b>${blocking.length} critical / panic result(s)</b> reach their final approval now. Record who was informed before approving. <b>Attempted, not reachable</b> with the reason also lets you approve.`
                : 'These results crossed a critical / panic threshold and nobody is recorded as informed yet. You can record it now or at the final sign-off.'));

        $('#ccResults').html(d.results.map(r => {
            const required = r.blocksSignoff;
            // before a sign-off the list holds only results nobody is recorded as informed of: all start ticked
            const checked = required || ctx !== 'REGISTER' || r.communicationStatus !== 'INFORMED';
            return `<tr>
                <td><input type="checkbox" class="form-check-input cc-pick-row" value="${r.sampleId}" ${checked ? 'checked' : ''} ${required ? 'disabled title="Required before approving"' : ''}></td>
                <td><div class="fw-semibold">${esc(r.testName)}${required ? ' <span class="badge bg-danger ms-1">Required</span>' : ''}</div>
                    <div class="fs-9 text-muted">${esc(r.profileName || '')}</div></td>
                <td class="text-nowrap"><span class="fw-bold">${esc(r.testValue)}</span> <span class="fs-9 text-muted">${esc(r.unit || '')}</span>
                    ${r.thresholdDir === 'H' ? '<i class="bi bi-arrow-up text-danger"></i>' : (r.thresholdDir === 'L' ? '<i class="bi bi-arrow-down text-primary"></i>' : '')}
                    <div><span class="badge ${r.severity === 'PANIC' ? 'bg-danger' : 'bg-warning text-dark'}">${r.severity === 'PANIC' ? 'Panic' : 'Critical'}</span></div></td>
                <td class="fs-9">${esc(r.threshold || 'flagged on entry')}</td>
                <td>${statusHtml(r)}</td></tr>`;
        }).join(''));

        // who can be informed: quick picks from the bill
        const picks = [];
        if (c.refDoctorName) picks.push({ key: 'REFDOCTOR', label: 'Referring doctor', name: c.refDoctorName, phone: c.refDoctorPhone, email: c.refDoctorEmail });
        picks.push({ key: 'PATIENT', label: 'Patient', name: c.patientName, phone: c.patientPhone, email: c.patientEmail });
        if (c.isB2B && c.partnerName) picks.push({ key: 'PARTNER', label: 'B2B partner', name: c.partnerName, phone: c.partnerPhone, email: c.partnerEmail });
        picks.push({ key: 'OTHER', label: 'Other', name: '', phone: '', email: '' });
        state.picks = picks;
        $('#ccPick').html(picks.map((p, i) => `<button type="button" class="btn btn-outline-secondary" data-i="${i}">${esc(p.label)}</button>`).join(''));

        // history (register)
        const hist = d.history || [];
        $('#ccHistoryBox').toggleClass('d-none', !hist.length);
        $('#ccHistory').html(hist.map(h => {
            const r = d.results.find(x => x.sampleId === h.sampleId) || {};
            return `<div class="py-1 border-bottom ${h.isActive ? '' : 'inactive'}">
                <b>${esc(r.testName || '')}</b> ${esc(h.resultValue)} · ${h.outcome === 'INFORMED' ? 'Informed' : 'Attempted'}: ${esc(h.informedName)}
                (${esc(ROLE[h.informedRole] || h.informedRole)}) by ${esc(MODE[h.mode] || h.mode)}${h.contactNo ? ' ' + esc(h.contactNo) : ''} at ${fmtDT(h.informedOn)}
                ${h.readBack ? ' · read back' : ''}${h.remarks ? ' · ' + esc(h.remarks) : ''}
                ${h.messageStatus ? ` · message ${esc(h.messageStatus.toLowerCase())}` : ''}
                <span class="text-muted">· recorded by ${esc(h.recordedBy || '')} ${fmtDT(h.recordedOn)}${h.isActive ? '' : ' · corrected'}</span></div>`;
        }).join(''));

        const anyInformed = d.results.some(r => r.informedId);
        $('#ccCorrectBox').toggleClass('d-none', !(ctx === 'REGISTER' && anyInformed));
        $('#ccCorrect').prop('checked', false);

        // the form starts as an informed phone call now, to the first suggested person
        setOutcome('INFORMED');
        $('#ccMode').val('PHONE'); $('#ccRole').val('REFDOCTOR');
        $('#ccName, #ccContact, #ccRemarks').val(''); $('#ccReadBack').prop('checked', false); $('#ccSend').prop('checked', true);
        $('#ccOn').val(localNow()).attr('max', localNow());
        pick(0);
        $('#ccSkip').toggleClass('d-none', !(ctx !== 'REGISTER' && !blocking.length));
        $('#ccSave span').text(ctx === 'REGISTER' ? 'Save' : 'Save & continue');
        $('#ccError').addClass('d-none');
    }

    function pick(i) {
        const p = state.picks[i]; if (!p) return;
        state.picked = p;
        $('#ccPick .btn').removeClass('active').filter(`[data-i="${i}"]`).addClass('active');
        $('#ccName').val(p.name || '');
        if (p.key !== 'OTHER') $('#ccRole').val(p.key);
        fillContact();
    }
    function fillContact() {
        const p = state.picked || {}, mode = $('#ccMode').val();
        $('#ccContact').val(mode === 'EMAIL' ? (p.email || '') : (mode === 'INPERSON' ? '' : (p.phone || '')));
        syncMode();
    }
    function syncMode() {
        const mode = $('#ccMode').val(), outcome = state.outcome;
        $('#ccContactLabel').text(mode === 'EMAIL' ? 'Email address *' : (mode === 'INPERSON' ? 'Contact (optional)' : (mode === 'PHONE' ? 'Number called *' : 'Number messaged *')));
        $('#ccContact').attr('type', mode === 'EMAIL' ? 'email' : 'text');
        const canSend = mode === 'WHATSAPP' || mode === 'EMAIL';
        $('#ccSendBox').toggleClass('d-none', !canSend || outcome !== 'INFORMED');
        $('#ccSendLabel').text(mode === 'EMAIL' ? 'Send this email now from eClinicPlus' : 'Send this WhatsApp message now from eClinicPlus');
    }
    function setOutcome(o) {
        state.outcome = o;
        $('.cc-outcome .btn').removeClass('active').filter(`[data-outcome="${o}"]`).addClass('active');
        $('#ccNameLabel').text(o === 'INFORMED' ? 'Person informed *' : 'Person you tried to reach *');
        $('#ccOnLabel').text(o === 'INFORMED' ? 'Informed at *' : 'Tried at *');
        $('#ccRemarksLabel').text(o === 'INFORMED' ? 'Remarks' : 'Why they could not be reached *');
        $('#ccReadBackBox').toggleClass('d-none', o !== 'INFORMED');
        syncMode();
    }

    function collect() {
        const ids = $('.cc-pick-row:checked').map(function () { return parseInt(this.value); }).get();
        const outcome = state.outcome, mode = $('#ccMode').val(), name = $('#ccName').val().trim(), contact = $('#ccContact').val().trim();
        const on = $('#ccOn').val(), remarks = $('#ccRemarks').val().trim();
        if (!ids.length) return { error: 'Tick at least one result.' };
        if (!name) return { error: outcome === 'INFORMED' ? 'Enter the name of the person informed.' : 'Enter the name of the person you tried to reach.' };
        if (['PHONE', 'WHATSAPP', 'SMS'].includes(mode) && !contact) return { error: 'Enter the number that was called / messaged.' };
        if (mode === 'EMAIL' && !/^\S+@\S+\.\S+$/.test(contact)) return { error: 'Enter the email address that was written to.' };
        if (!on) return { error: 'Enter the date and time.' };
        if (new Date(on) > new Date(Date.now() + 5 * 60000)) return { error: 'The date and time cannot be in the future.' };
        if (outcome === 'ATTEMPTED' && !remarks) return { error: 'Enter why the person could not be reached.' };
        const correct = $('#ccCorrect').is(':checked');
        const send = outcome === 'INFORMED' && (mode === 'WHATSAPP' || mode === 'EMAIL') && $('#ccSend').is(':checked');
        return {
            items: ids.map(id => {
                const r = state.data.results.find(x => x.sampleId === id) || {};
                return {
                    sampleId: id, outcome: outcome, informedName: name, informedRole: $('#ccRole').val(), contactNo: contact || null, mode: mode,
                    informedOn: on, readBack: outcome === 'INFORMED' && $('#ccReadBack').is(':checked'), remarks: remarks || null,
                    correctsId: correct && r.informedId ? r.informedId : null, sendMessage: send
                };
            })
        };
    }

    function show(labOrderId, context, data) {
        return new Promise(resolve => {
            state = { labOrderId, context, data, resolve, saved: false };
            render();
            const modal = bootstrap.Modal.getOrCreateInstance(document.getElementById('critCommModal'));
            $m().off('hidden.bs.modal.cc').on('hidden.bs.modal.cc', () => { if (state && !state.done) { state.done = true; resolve(state.saved); } });
            modal.show();
        });
    }

    function finish(result) {
        if (!state) return;
        state.saved = result; state.done = true;
        const resolve = state.resolve;
        bootstrap.Modal.getOrCreateInstance(document.getElementById('critCommModal')).hide();
        resolve(result);
    }

    function load(labOrderId, sampleIds, context) {
        return post($m().data('pending-url'), { labOrderId: labOrderId, sampleIds: sampleIds || null, context: context })
            .then(res => {
                if (!res || !res.success) throw new Error((res && res.message) || 'Could not load the critical values.');
                const data = res.data || {};
                data.results = data.results || [];
                return data;
            });
    }

    function failBox(msg) {
        if (window.Swal) Swal.fire({ icon: 'error', title: 'Critical value check', text: msg });
        else alert(msg);
    }

    // ── events ──
    $(document).on('click', '#critCommModal .cc-outcome .btn', function () { setOutcome($(this).data('outcome')); });
    $(document).on('click', '#ccPick .btn', function () { pick(parseInt($(this).data('i'))); });
    $(document).on('change', '#ccMode', fillContact);
    $(document).on('click', '#ccSkip', () => finish(true));
    $(document).on('click', '#ccSave', function () {
        const c = collect();
        if (c.error) { $('#ccError').text(c.error).removeClass('d-none'); return; }
        const $b = $(this).prop('disabled', true);
        const source = state.context === 'REGISTER' ? 'REGISTER' : state.context;
        post($m().data('record-url'), { labOrderId: state.labOrderId, source: source, items: c.items })
            .done(res => {
                $b.prop('disabled', false);
                if (res && res.success) {
                    if (window.toastr) toastr.success(res.message); else if (window.Swal) Swal.fire({ icon: 'success', title: 'Recorded', text: res.message, timer: 2200, showConfirmButton: false });
                    finish(true);
                } else $('#ccError').text((res && res.message) || 'Not saved. Please try again.').removeClass('d-none');
            })
            .fail(xhr => {
                $b.prop('disabled', false);
                $('#ccError').text(xhr.status === 403 ? 'You do not have permission to record critical value communication.' : 'Server error. Please try again.').removeClass('d-none');
            });
    });

    return {
        ensure: function (opts) {
            if (!$m().length) return Promise.resolve(true);
            return load(opts.labOrderId, opts.sampleIds, opts.context || 'ENTRY').then(data => {
                // switched off for this branch (Hospital Settings > LAB): approval as before
                if (!(data.contacts && data.contacts.communicationEnabled)) return true;
                // only results nobody is recorded as informed of, and not approved already
                data.results = data.results.filter(r => r.communicationStatus !== 'INFORMED' && r.reportStatusId !== 5);
                if (!data.results.length) return true;
                return show(opts.labOrderId, opts.context || 'ENTRY', data);
            }).catch(err => {
                // could not check: the server-side check still applies on approval
                console.warn('[CriticalComm]', err);
                return true;
            });
        },
        open: function (opts) {
            return load(opts.labOrderId, opts.sampleIds, 'REGISTER').then(data => {
                if (!(data.contacts && data.contacts.communicationEnabled)) { failBox('Critical value communication is switched off for this branch (Hospital Settings > LAB).'); return false; }
                if (!data.results.length) { failBox('This result is no longer a critical / panic value of this branch.'); return false; }
                return show(opts.labOrderId, 'REGISTER', data);
            }).catch(err => { failBox(err.message || 'Could not load the critical values.'); return false; });
        }
    };
})();
