/* IPD Phase 8 - OT booking dialog (SQLScripts/2492), shared by the OT tab of the IPD Patient workspace and IPD > OT Schedule.
   IpdOtBook.open({ base, admissionId, patientLabel, booking, pickPatient, defaultStart, defaultOtId, consultant, diagnosis, onSaved })
   The stored procedure checks everything again: free OT / surgeon / anaesthetist / patient slot, active masters, anaesthesia rules. */
(function () {
    'use strict';
    const E = v => Ipd.esc(v);
    let L = null, modalEl = null;

    async function lookups(base) { if (!L) L = await Ipd.get(base + 'Lookups'); return L; }
    const opts = (rows, label, empty) => (empty !== undefined ? `<option value="">${E(empty)}</option>` : '') +
        (rows || []).map(r => `<option value="${r.Id}">${E(label(r))}</option>`).join('');

    function build() {
        modalEl = document.createElement('div');
        modalEl.className = 'modal fade'; modalEl.tabIndex = -1; modalEl.id = 'otBookModal';
        modalEl.innerHTML = `<div class="modal-dialog modal-xl modal-dialog-scrollable"><div class="modal-content">
          <div class="modal-header"><h6 class="modal-title fw-bold"><i class="bi bi-calendar-plus me-1 text-danger"></i><span id="obTitle">Book OT</span></h6>
            <button type="button" class="btn-close" data-bs-dismiss="modal" aria-label="Close"></button></div>
          <div class="modal-body"><div class="row g-3">
            <div class="col-12" id="obPatientWrap"><label class="form-label small fw-semibold" for="obPatient">Admitted patient <span class="text-danger">*</span></label>
                <select id="obPatient" class="form-select"></select></div>
            <div class="col-12 d-none" id="obPatientFixed"><div class="alert alert-light border py-2 mb-0 small" id="obPatientText"></div></div>
            <div class="col-md-4"><label class="form-label small fw-semibold" for="obOt">Operation theatre <span class="text-danger">*</span></label><select id="obOt" class="form-select"></select></div>
            <div class="col-md-5"><label class="form-label small fw-semibold" for="obProc">Procedure (Procedure Master)</label><select id="obProc" class="form-select"></select></div>
            <div class="col-md-3"><label class="form-label small fw-semibold" for="obSide">Side</label>
                <select id="obSide" class="form-select"><option value="">—</option><option value="LEFT">Left</option><option value="RIGHT">Right</option><option value="BILATERAL">Bilateral</option><option value="NA">Not applicable</option></select></div>
            <div class="col-md-8"><label class="form-label small fw-semibold" for="obProcName">Planned surgery (as it will appear on the OT list) <span class="text-danger">*</span></label>
                <input id="obProcName" class="form-control" maxlength="250" placeholder="Filled from the procedure; or type a surgery not in the master" /></div>
            <div class="col-md-4"><label class="form-label small fw-semibold d-block">Type <span class="text-danger">*</span></label>
                <div class="btn-group w-100" role="group"><input type="radio" class="btn-check" name="obType" id="obTypeE" value="ELECTIVE" checked /><label class="btn btn-outline-primary" for="obTypeE">Elective</label>
                <input type="radio" class="btn-check" name="obType" id="obTypeM" value="EMERGENCY" /><label class="btn btn-outline-danger" for="obTypeM">Emergency</label></div></div>
            <div class="col-md-4"><label class="form-label small fw-semibold" for="obSurgeon">Surgeon <span class="text-danger">*</span></label><select id="obSurgeon" class="form-select"></select></div>
            <div class="col-md-4"><label class="form-label small fw-semibold" for="obAsst">Assistant surgeon</label><select id="obAsst" class="form-select"></select></div>
            <div class="col-md-4"><label class="form-label small fw-semibold" for="obAnaes">Anaesthetist</label><select id="obAnaes" class="form-select"></select></div>
            <div class="col-md-4"><label class="form-label small fw-semibold" for="obAnaesType">Anaesthesia</label><select id="obAnaesType" class="form-select"></select></div>
            <div class="col-md-4"><label class="form-label small fw-semibold" for="obScrub">Scrub nurse</label><input id="obScrub" class="form-control" maxlength="150" /></div>
            <div class="col-md-4"><label class="form-label small fw-semibold" for="obCirc">Circulating nurse</label><input id="obCirc" class="form-control" maxlength="150" /></div>
            <div class="col-md-4"><label class="form-label small fw-semibold" for="obStart">OT start <span class="text-danger">*</span></label><input type="datetime-local" id="obStart" class="form-control" /></div>
            <div class="col-md-4"><label class="form-label small fw-semibold" for="obDur">Expected duration (minutes) <span class="text-danger">*</span></label><input type="number" id="obDur" class="form-control" min="10" max="1440" step="5" value="60" /></div>
            <div class="col-md-4"><label class="form-label small fw-semibold">Slot</label><div class="form-control-plaintext small" id="obSlot"></div></div>
            <div class="col-md-6"><label class="form-label small fw-semibold" for="obDx">Pre-op diagnosis</label><input id="obDx" class="form-control" maxlength="500" /></div>
            <div class="col-md-6"><label class="form-label small fw-semibold" for="obRemarks">Remarks</label><input id="obRemarks" class="form-control" maxlength="500" /></div>
            <div class="col-12"><div class="form-check"><input class="form-check-input" type="checkbox" id="obReturn" /><label class="form-check-label small fw-semibold" for="obReturn">Unplanned return to OT (NABH indicator)</label></div>
                <input id="obReturnReason" class="form-control mt-1 d-none" maxlength="300" placeholder="Reason for the return to OT (e.g. bleeding, wound dehiscence)" /></div>
          </div></div>
          <div class="modal-footer"><button type="button" class="btn btn-outline-secondary" data-bs-dismiss="modal">Close</button>
            <button type="button" class="btn btn-danger" id="obSave"><i class="bi bi-check2 me-1"></i>Save booking</button></div>
        </div></div>`;
        document.body.appendChild(modalEl);
        const $ = id => document.getElementById(id);
        $('obReturn').addEventListener('change', e => $('obReturnReason').classList.toggle('d-none', !e.target.checked));
        $('obProc').addEventListener('change', e => {
            const p = (L.procedures || []).find(x => String(x.Id) === e.target.value);
            if (!p) return;
            $('obProcName').value = p.Name;
            if (p.Minutes > 0) $('obDur').value = p.Minutes;
            slot();
        });
        ['obStart', 'obDur'].forEach(id => $(id).addEventListener('input', slot));
        function slot() {
            const s = $('obStart').value ? new Date($('obStart').value) : null, m = Number($('obDur').value) || 0;
            $('obSlot').textContent = s && m ? `${Ipd.dt(s)} → ${new Date(s.getTime() + m * 60000).toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit' })}` : '';
        }
        modalEl._slot = slot;
    }

    async function open(o) {
        if (!modalEl) build();
        const $ = id => document.getElementById(id);
        try { await lookups(o.base); } catch (e) { Ipd.error(e.message); return; }
        const docs = L.doctors || [];
        const anaesDocs = docs.slice().sort((a, b) => (b.IsAnaesthetist - a.IsAnaesthetist) || a.Name.localeCompare(b.Name));
        const docLabel = d => d.Name + (d.Speciality ? ' · ' + d.Speciality : '');
        $('obOt').innerHTML = opts(L.ots, r => r.Name + (r.EmergencyAvailable ? ' (emergency)' : ''), '-- Select --');
        $('obProc').innerHTML = opts(L.procedures, r => r.Name + (r.Category ? ' · ' + r.Category : ''), '-- Not in the master / choose --');
        $('obSurgeon').innerHTML = opts(docs, docLabel, '-- Select --');
        $('obAsst').innerHTML = opts(docs, docLabel, '— None —');
        $('obAnaes').innerHTML = opts(anaesDocs, d => (d.IsAnaesthetist ? '★ ' : '') + docLabel(d), '— None —');
        $('obAnaesType').innerHTML = opts(L.anaesthesiaTypes, r => r.Name, '— None —');
        const b = o.booking || null;
        modalEl.dataset.bookingId = b ? b.OtBookingId : '';
        modalEl.dataset.admissionId = o.admissionId || (b ? b.AdmissionId : '') || '';
        $('obTitle').textContent = b ? 'Change OT booking ' + b.BookingNo : 'Book OT';
        $('obPatientWrap').classList.toggle('d-none', !o.pickPatient || !!b);
        $('obPatientFixed').classList.toggle('d-none', !!o.pickPatient && !b);
        $('obPatientText').innerHTML = E(o.patientLabel || (b ? b.PatientName + ' · ' + b.IpNo : ''));
        $('obOt').value = b ? b.OtId : (o.defaultOtId || '');
        $('obProc').value = b && b.ProcedureId ? b.ProcedureId : '';
        $('obProcName').value = b ? b.ProcedureName : '';
        $('obSide').value = b && b.Laterality ? b.Laterality : '';
        (b && b.SurgeryType === 'EMERGENCY' ? $('obTypeM') : $('obTypeE')).checked = true;
        $('obSurgeon').value = b ? b.SurgeonId : (o.consultant || '');
        $('obAsst').value = b && b.AssistantSurgeonId ? b.AssistantSurgeonId : '';
        $('obAnaes').value = b && b.AnaesthetistId ? b.AnaesthetistId : '';
        $('obAnaesType').value = b && b.AnaesthesiaTypeId ? b.AnaesthesiaTypeId : '';
        $('obScrub').value = b ? (b.ScrubNurse || '') : ''; $('obCirc').value = b ? (b.CirculatingNurse || '') : '';
        const start = b ? new Date(b.ScheduledStart) : (o.defaultStart || (() => { const d = new Date(); d.setMinutes(0, 0, 0); d.setHours(d.getHours() + 1); return d; })());
        $('obStart').value = Ipd.local(start);
        $('obDur').value = b ? Math.round((new Date(b.ScheduledEnd) - new Date(b.ScheduledStart)) / 60000) : 60;
        $('obDx').value = b ? (b.PreOpDiagnosis || '') : (o.diagnosis || '');
        $('obRemarks').value = b ? (b.Remarks || '') : '';
        $('obReturn').checked = !!(b && b.IsUnplannedReturn); $('obReturnReason').value = b ? (b.ReturnReason || '') : '';
        $('obReturnReason').classList.toggle('d-none', !$('obReturn').checked);
        modalEl._slot();
        if (o.pickPatient && !b && window.jQuery && jQuery.fn.select2) {
            const $p = jQuery('#obPatient');
            if ($p.data('select2')) $p.select2('destroy');
            $p.empty().select2({
                theme: 'bootstrap-5', dropdownParent: jQuery(modalEl), placeholder: 'Search admitted patient: name, UHID, IP no. or mobile', minimumInputLength: 0,
                ajax: {
                    delay: 250, url: o.base + 'Patients', data: p => ({ search: p.term || '' }),
                    processResults: r => ({ results: ((r && r.data) || []).map(x => ({ id: x.AdmissionId, text: `${x.PatientName} · ${x.IpNo} · ${x.BedNumber || ''} ${x.WardName ? '(' + x.WardName + ')' : ''}`, consultant: x.ConsultantDoctorId, dx: x.ProvisionalDiagnosis })) })
                }
            }).on('select2:select', e => {
                if (e.params.data.consultant && !$('obSurgeon').value) $('obSurgeon').value = e.params.data.consultant;
                if (e.params.data.dx && !$('obDx').value) $('obDx').value = e.params.data.dx;
            });
        }
        $('obSave').onclick = async ev => {
            const adm = modalEl.dataset.admissionId || (o.pickPatient ? jQuery('#obPatient').val() : '');
            if (!adm) { Ipd.error('Choose the admitted patient.'); return; }
            if (!$('obOt').value || !$('obSurgeon').value || !$('obProcName').value.trim() || !$('obStart').value) { Ipd.error('Fill the OT, the planned surgery, the surgeon and the start time.'); return; }
            const body = {
                otBookingId: modalEl.dataset.bookingId ? Number(modalEl.dataset.bookingId) : null, otId: Number($('obOt').value),
                procedureId: $('obProc').value ? Number($('obProc').value) : null, procedureName: $('obProcName').value.trim(), laterality: $('obSide').value || null,
                surgeryType: document.querySelector('input[name="obType"]:checked').value, surgeonId: Number($('obSurgeon').value),
                assistantSurgeonId: $('obAsst').value ? Number($('obAsst').value) : null, anaesthetistId: $('obAnaes').value ? Number($('obAnaes').value) : null,
                anaesthesiaTypeId: $('obAnaesType').value ? Number($('obAnaesType').value) : null, scrubNurse: $('obScrub').value, circulatingNurse: $('obCirc').value,
                scheduledStart: $('obStart').value, durationMinutes: Number($('obDur').value) || 0, preOpDiagnosis: $('obDx').value, remarks: $('obRemarks').value,
                isUnplannedReturn: $('obReturn').checked, returnReason: $('obReturnReason').value
            };
            ev.target.disabled = true;
            const r = await Ipd.post(o.base + 'Book?id=' + adm, body);
            ev.target.disabled = false;
            if (!r.success) { Ipd.error(r.error); return; }
            bootstrap.Modal.getOrCreateInstance(modalEl).hide();
            Ipd.toast(body.otBookingId ? 'OT booking changed' : 'OT booked: ' + (r.data.BookingNo || ''));
            o.onSaved && o.onSaved(r.data);
        };
        bootstrap.Modal.getOrCreateInstance(modalEl).show();
    }

    window.IpdOtBook = { open, lookups };
})();
