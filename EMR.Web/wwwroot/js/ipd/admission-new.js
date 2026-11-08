/* IpdAdmission/New.cshtml (IPD, SQLScripts/2422+): page script, moved out of the view so it is not compiled into EMR.Web.dll. Server values come in window.IpdPage. */
(function () {
    const C = window.IpdPage || {};
    const base = C.base, canWaive = !!C.canWaive, canBackdate = !!C.canBackdate, presetPatient = C.presetPatient || null, presetEstimate = C.presetEstimate || null;
    let presetBed = C.presetBed || null;
    const $ = window.jQuery, E = Ipd.esc;
    let L = null, beds = [], settings = {}, selectedBed = null, statusSeq = 0;
    const sig = { sigPatient: Ipd.signaturePad(document.getElementById('sigPatient')), sigWitness: Ipd.signaturePad(document.getElementById('sigWitness')) };
    document.querySelectorAll('[data-clear]').forEach(b => b.addEventListener('click', () => sig[b.dataset.clear].clear()));
    const newKey = () => (crypto.randomUUID ? crypto.randomUUID() : 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, c => { const r = Math.random() * 16 | 0; return (c === 'x' ? r : (r & 3 | 8)).toString(16); }));
    document.getElementById('RequestKey').value = newKey();
    document.getElementById('AdmissionAt').value = Ipd.local();

    function fill(id, rows, val, text, first) {
        const el = document.getElementById(id); if (!el) return;
        const keep = el.value;
        el.innerHTML = (first !== undefined ? `<option value="">${E(first)}</option>` : '') + (rows || []).map(r => `<option value="${E(r[val])}">${E(typeof text === 'function' ? text(r) : r[text])}</option>`).join('');
        if (keep) el.value = keep;
    }
    function s2() {
        $('.s2').each(function () { if (!$(this).data('select2')) $(this).select2({ theme: 'bootstrap-5', width: '100%', allowClear: false }); });
    }

    // ── lookups ─────────────────────────────────────────────────────────────────────────────────────────
    async function loadLookups() {
        L = await Ipd.get(base + 'Lookups');
        settings = (L.settings && L.settings[0]) || {};
        const ipdDocs = (L.doctors || []).filter(r => r.IsIpd);
const doc = r => r.DoctorName + (r.SpecialityName ? ' · ' + r.SpecialityName : r.DeptName ? ' · ' + r.DeptName : '');
        fill('AdmittingDoctorId', ipdDocs, 'DoctorId', r => r.DoctorName + ' · ' + r.IpdDeptNames, ipdDocs.length ? '-- Select --' : '-- No doctor with an IPD department --');
if (!ipdDocs.length) Ipd.toast('No doctor belongs to an IPD department. Map one in Master > Doctor.', 'warning');
        fill('ConsultantDoctorId', ipdDocs, 'DoctorId', r => r.DoctorName + ' · ' + r.IpdDeptNames, ipdDocs.length ? '-- Select --' : '-- No doctor with an IPD department --');
        fill('ReferralDoctorId', L.referralDoctors, 'DoctorId', r => r.DoctorName + (r.IsReferralDoctor ? ' (referral)' : ''), '-- None --');
        fill('DepartmentId', L.departments, 'DeptId', 'DeptName', '-- Select --');
        fill('TariffCategoryId', L.tariffCategories, 'TariffCategoryId', r => r.Name + ' (' + r.PatientCategory + ') · ' + (r.BedRates ? r.BedRates + ' bed rate' + (r.BedRates > 1 ? 's' : '') : 'no bed rates'), '-- Select --');
        fill('InsuranceTpaId', L.insurances, 'Id', r => r.Name + (r.Type ? ' · ' + r.Type : ''), '-- Select --');
        fill('CorporateId', L.corporates, 'Id', 'Name', '-- Select --');
        fill('SchemeId', L.schemes, 'Id', 'Name', '-- Select --');
        fill('PackageId', L.packages, 'Id', r => r.Name + ' · ' + Ipd.money(r.Amount), '-- No package --');
        fill('ConsentId', L.consents, 'Id', r => r.ConsentType + ' (' + r.Language + ')', '-- Not now --');
        fill('RelationId', L.relations, 'Id', 'Name', '-- Select --');
        fill('IdentificationTypeId', L.idTypes, 'Id', 'Name', '--');
        fill('ReligionId', L.religions, 'Id', 'Name', '--');
        fill('OccupationId', L.occupations, 'Id', 'Name', '--');
        fill('MaritalStatusId', L.maritalStatuses, 'Id', 'Name', '--');
        fill('LanguageId', L.languages, 'Id', 'Name', '--');
        fill('CountryId', L.countries, 'Id', 'Name', '--');
        const general = (L.consents || []).find(c => /general/i.test(c.ConsentType) && /english/i.test(c.Language)) || (L.consents || [])[0];
        if (general) document.getElementById('ConsentId').value = general.Id;
        document.getElementById('consentReq').classList.toggle('d-none', !settings.IpdConsentRequired);
        if (!document.getElementById('ExpectedDischargeAt').value) {
            const d = new Date(); d.setDate(d.getDate() + 3); d.setHours(settings.IpdDefaultDischargeHour ?? 11, 0, 0, 0);
            document.getElementById('ExpectedDischargeAt').value = Ipd.local(d);
        }
        s2();
        payerChanged(true);
        addPayRow();
        addAttendant(true);
    }

    // ── payer ───────────────────────────────────────────────────────────────────────────────────────────
    const payerCategory = { CASH: /cash|self/i, CORPORATE: /corporate/i, INSURANCE: /insurance|tpa/i, SCHEME: /government|scheme/i };
    function payerType() { return document.querySelector('input[name="PayerType"]:checked').value; }
    function payerChanged(initial) {
        const p = payerType();
        document.querySelectorAll('.payer-f').forEach(el => el.classList.toggle('d-none', !el.classList.contains('payer-' + p)));
        document.getElementById('lblPolicy').classList.toggle('req', p === 'INSURANCE');
        const tc = document.getElementById('TariffCategoryId');
        let pick = null;
        if (p === 'CASH' && settings.IpdDefaultTariffCategoryId) pick = (L.tariffCategories || []).find(t => t.TariffCategoryId === settings.IpdDefaultTariffCategoryId);
        // among the categories of this payer type, the one with the most bed rates (B2C before General alphabetically, but General has the rates)
pick = pick || (L.tariffCategories || []).filter(t => payerCategory[p].test(t.PatientCategory))
                                          .sort((a, b) => (b.BedRates || 0) - (a.BedRates || 0) || a.Name.localeCompare(b.Name))[0];
        if (pick) tc.value = pick.TariffCategoryId;
        loadBeds();
        updateMinAdvance();
    }
    document.querySelectorAll('input[name="PayerType"]').forEach(r => r.addEventListener('change', () => payerChanged(false)));
    document.getElementById('TariffCategoryId').addEventListener('change', loadBeds);

    // ── beds ────────────────────────────────────────────────────────────────────────────────────────────
    // a bed is selectable when Available, or Reserved for the patient on the form (Bed Board > Reserve)
    function selectable(b) {
        if (b.NoTariff) return false;   // a bed without a rate for the tariff category cannot be given
        if (b.BedStatus === 'Available') return true;
        if (b.BedStatus !== 'Reserved') return false;
        const pid = Number(document.getElementById('PatientId').value) || 0, ph = (document.getElementById('PhoneNumber').value || '').replace(/\D/g, '');
        return (pid && b.ResPatientId === pid) || (!b.ResPatientId && ph && (b.ResPhone || '').replace(/\D/g, '') === ph);
    }
    async function loadBeds() {
        const tc = document.getElementById('TariffCategoryId').value;
        try { beds = await Ipd.get(base + 'Beds?tariffCategoryId=' + encodeURIComponent(tc || '')); }
        catch (e) { document.getElementById('bedBoard').innerHTML = `<div class="text-danger small">${E(e.message)}</div>`; return; }
        if (selectedBed) selectedBed = beds.find(b => b.BedId === selectedBed.BedId) || null;
        if (presetBed) {   // opened from the Bed Board: that bed, and its ward's department
            const pb = beds.find(b => b.BedId === presetBed);
            if (pb && selectable(pb)) {
                selectedBed = pb; document.getElementById('BedId').value = pb.BedId;
                if (pb.WardDepartmentId && !document.getElementById('DepartmentId').value) $('#DepartmentId').val(pb.WardDepartmentId).trigger('change.select2');
            } else if (pb) Ipd.toast('Bed ' + pb.BedNumber + ' is ' + pb.BedStatus.toLowerCase() + ': choose a bed below.', 'warning');
            presetBed = null;
        }
        departmentChanged();
    }
    // Department -> its wards -> the bed categories in them (Master > Ward belongs to a department)
    const deptBeds = () => { const d = document.getElementById('DepartmentId').value; return beds.filter(b => !d || String(b.WardDepartmentId) === d); };
    function fillBedFilters() {
        const list = deptBeds(), wsel = document.getElementById('bedWard'), csel = document.getElementById('bedCat'), keepW = wsel.value;
        const wards = [...new Map(list.map(b => [b.WardId, b.WardName])).entries()];
        wsel.innerHTML = '<option value="">All wards</option>' + wards.map(([id, n]) => `<option value="${id}">${E(n)}</option>`).join('');
        wsel.value = wards.some(([id]) => String(id) === keepW) ? keepW : '';
        const keepC = csel.value, w = wsel.value;
        const cats = [...new Map(list.filter(b => !w || String(b.WardId) === w).map(b => [b.BedCategoryId, b.BedCategoryName])).entries()];
        csel.innerHTML = '<option value="">All bed categories</option>' + cats.map(([id, n]) => `<option value="${id}">${E(n)}</option>`).join('');
        csel.value = cats.some(([id]) => String(id) === keepC) ? keepC : '';
    }
    function departmentChanged() {
        if (selectedBed && !deptBeds().some(b => b.BedId === selectedBed.BedId)) { selectedBed = null; document.getElementById('BedId').value = ''; updateMinAdvance(); }
        fillBedFilters(); renderBeds();
    }
    $('#DepartmentId').on('change', departmentChanged);
    function renderBeds() {
        const w = document.getElementById('bedWard').value, c = document.getElementById('bedCat').value, free = document.getElementById('bedFreeOnly').checked;
        const list = deptBeds().filter(b => (!w || String(b.WardId) === w) && (!c || String(b.BedCategoryId) === c) && (!free || b.BedStatus === 'Available' || (selectedBed && b.BedId === selectedBed.BedId)));
        const groups = {};
        list.forEach(b => (groups[b.WardId] = groups[b.WardId] || { name: b.WardName, type: b.WardType, gender: b.WardGender, floor: b.FloorName, beds: [] }).beds.push(b));
        const html = Object.values(groups).map(g => {
            const freeCount = g.beds.filter(b => b.BedStatus === 'Available').length;
            return `<div class="bed-ward"><div class="bed-ward-title">${E(g.name)} <span class="ipd-pill muted">${E(g.type || '')}</span>${g.gender && !/unisex/i.test(g.gender) ? `<span class="ipd-pill info">${E(g.gender)}</span>` : ''}<span class="ipd-pill muted">${E(g.floor || '')}</span><span class="text-success">${freeCount} free</span></div>
            <div class="bed-grid">${g.beds.map(b => {
                const sel = selectedBed && selectedBed.BedId === b.BedId;
                const tcName = $('#TariffCategoryId option:selected').text().split(' (')[0];
                    const rate = b.NoTariff ? `<span class="text-danger" title="${E(b.RatedCategories ? 'Rates exist for: ' + b.RatedCategories : 'No rate in Master > Bed/Room Tariff')}">No ${E(tcName)} rate</span>${b.RatedCategories ? `<div class="small text-muted text-truncate">has: ${E(b.RatedCategories)}</div>` : ''}` : Ipd.money(b.DailyRate) + '/day';
                const who = b.BedStatus === 'Occupied' && b.PatientName ? `<div class="text-truncate">${E(b.PatientName)}</div>`
                        : b.BedStatus === 'Reserved' && b.ResPatientName ? `<div class="text-truncate">For ${E(b.ResPatientName)}</div>` : `<div>${rate}</div>`;
                return `<button type="button" class="bed-tile ${E(b.BedStatus)} ${sel ? 'selected' : ''}" data-bed="${b.BedId}" ${!selectable(b) && !sel ? 'disabled' : ''}
                          title="${E(b.BedCategoryName)} · Room ${E(b.RoomNumber)}${b.IsIcu ? ' · ICU' : ''}${b.IsIsolation ? ' · Isolation' : ''}">
                          <div class="bn">${E(b.BedNumber)} ${b.IsIcu ? '<span class="ipd-pill alert">ICU</span>' : ''}</div>
                          <div class="text-muted">${E(b.BedCategoryName)} · ${E(b.RoomNumber)}</div>${who}</button>`;
            }).join('')}</div></div>`;
        }).join('');
        document.getElementById('bedBoard').innerHTML = html || `<div class="text-muted small">No bed matches${document.getElementById('DepartmentId').value ? ' in the wards of this department' : ''}. Untick "Available only" to see every bed${document.getElementById('DepartmentId').value ? ', or choose another department' : ''}.</div>`;
        showSelectedBed();
    }
    document.getElementById('bedBoard').addEventListener('click', e => {
        const t = e.target.closest('.bed-tile'); if (!t || t.disabled) return;
        selectedBed = beds.find(b => b.BedId === Number(t.dataset.bed));
        document.getElementById('BedId').value = selectedBed ? selectedBed.BedId : '';
        renderBeds(); updateMinAdvance();
    });
    document.getElementById('bedWard').addEventListener('change', () => { fillBedFilters(); renderBeds(); });
    ['bedCat', 'bedFreeOnly'].forEach(id => document.getElementById(id).addEventListener('change', renderBeds));
    document.getElementById('btnBedRefresh').addEventListener('click', loadBeds);
    function showSelectedBed() {
        const box = document.getElementById('bedSelected');
        if (!selectedBed) { box.classList.add('d-none'); return; }
        const g = document.getElementById('Gender').value, wg = selectedBed.WardGender || '';
        const clash = g && /^(Male|Female)$/.test(wg) && /^(Male|Female)$/.test(g) && wg !== g;
        box.className = 'alert py-2 small ' + (clash ? 'alert-warning' : 'alert-primary');
        box.innerHTML = `<i class="bi bi-check2-circle me-1"></i>Bed <b>${E(selectedBed.BedNumber)}</b> · ${E(selectedBed.WardName)} · Room ${E(selectedBed.RoomNumber)} · ${E(selectedBed.BedCategoryName)} · `
            + (selectedBed.NoTariff ? '<b class="text-danger">no bed rate for this tariff category (Master &gt; Bed/Room Tariff' + (selectedBed.RatedCategories ? '; rates exist for ' + E(selectedBed.RatedCategories) : '') + ')</b>' : `<b>${Ipd.money(selectedBed.DailyRate)}</b> a day${Number(selectedBed.GstPercentage) > 0 ? ' + GST if above the room-rent limit' : ''}`)
            + (selectedBed.UsedFallback ? ' <span class="ipd-pill warn">default tariff rate</span>' : '')
            + (clash ? `<div class="mt-1"><b>${E(wg)} ward</b>: the patient is ${E(g.toLowerCase())}.</div>` : '');
    }
    document.getElementById('Gender').addEventListener('change', showSelectedBed);
// the admitting doctor's IPD department fills the Department when it is still empty
$('#AdmittingDoctorId').on('change', function () {
    const d = (L.doctors || []).find(x => String(x.DoctorId) === this.value);
    if (d && d.IpdDeptId && !document.getElementById('DepartmentId').value) $('#DepartmentId').val(d.IpdDeptId).trigger('change');
    if (d && !document.getElementById('ConsultantDoctorId').value) $('#ConsultantDoctorId').val(d.DoctorId).trigger('change');
});

    // ── minimum advance ─────────────────────────────────────────────────────────────────────────────────
    function minAdvance() {
        const days = Number(settings.IpdMinAdvanceDays) || 0;
        if (!days || payerType() !== 'CASH' || !selectedBed || selectedBed.NoTariff) return 0;
        return Math.round(Number(selectedBed.DailyRate) * days);
    }
    function updateMinAdvance() {
        const need = minAdvance(), hint = document.getElementById('minAdvanceHint');
        hint.classList.toggle('d-none', !need);
        hint.textContent = need ? `Minimum advance ${Ipd.money(need)} (${settings.IpdMinAdvanceDays} day(s) of the bed)` : '';
        const total = payTotal();
        document.getElementById('waiveBlock').classList.toggle('d-none', !(canWaive && need && total < need));
    }

    // ── payment rows ────────────────────────────────────────────────────────────────────────────────────
    function addPayRow() {
        const modes = (L.paymentModes || []).map(m => `<option value="${E(m.MethodCode)}">${E(m.MethodName)}</option>`).join('');
        const div = document.createElement('div');
        div.className = 'row g-2 mb-2 pay-row align-items-end';
        div.innerHTML = `<div class="col-5 col-md-3"><label class="form-label">Mode</label><select class="form-select pm">${modes}</select></div>
            <div class="col-7 col-md-3"><label class="form-label">Amount (₹)</label><input type="number" min="0" step="0.01" class="form-control pa num" /></div>
            <div class="col-10 col-md-5"><label class="form-label">Reference (UPI / card / cheque no.)</label><input class="form-control pr" maxlength="100" /></div>
            <div class="col-2 col-md-1"><button type="button" class="btn btn-outline-danger w-100 pdel" title="Remove"><i class="bi bi-trash"></i></button></div>`;
        document.getElementById('payRows').appendChild(div);
        div.querySelector('.pa').addEventListener('input', () => { renderTotal(); });
        div.querySelector('.pdel').addEventListener('click', () => { if (document.querySelectorAll('.pay-row').length > 1) div.remove(); renderTotal(); });
    }
    function payRows() {
        return [...document.querySelectorAll('.pay-row')].map(r => ({ Method: r.querySelector('.pm').value, Amount: Number(r.querySelector('.pa').value) || 0, Ref: r.querySelector('.pr').value.trim() }))
            .filter(p => p.Amount > 0);
    }
    function payTotal() { return payRows().reduce((s, p) => s + p.Amount, 0); }
    function renderTotal() { document.getElementById('payTotal').textContent = Ipd.money(payTotal()); updateMinAdvance(); }
    document.getElementById('btnAddPay').addEventListener('click', addPayRow);

    // ── attendants ──────────────────────────────────────────────────────────────────────────────────────
    function addAttendant(primary) {
        const ids = (L.idTypes || []).map(t => `<option value="${t.Id}">${E(t.Name)}</option>`).join('');
        const div = document.createElement('div');
        div.className = 'row g-2 mb-2 att-row';
        div.innerHTML = `<div class="col-12 col-md-3"><label class="form-label">Name</label><input class="form-control an" maxlength="150" /></div>
            <div class="col-6 col-md-2"><label class="form-label">Relation</label><input class="form-control ar" maxlength="50" /></div>
            <div class="col-6 col-md-2"><label class="form-label">Mobile</label><input class="form-control ap" maxlength="15" inputmode="numeric" /></div>
            <div class="col-6 col-md-2"><label class="form-label">ID Type</label><select class="form-select ait"><option value="">--</option>${ids}</select></div>
            <div class="col-6 col-md-2"><label class="form-label">ID No.</label><input class="form-control ain" maxlength="60" /></div>
            <div class="col-12 col-md-1 d-flex align-items-end">${primary ? '<span class="ipd-pill info">Primary</span>' : '<button type="button" class="btn btn-outline-danger w-100 adel"><i class="bi bi-trash"></i></button>'}</div>`;
        div.dataset.primary = primary ? '1' : '0';
        document.getElementById('attendants').appendChild(div);
        div.querySelector('.adel')?.addEventListener('click', () => div.remove());
    }
    document.getElementById('btnAddAttendant').addEventListener('click', () => addAttendant(false));
    function attendants() {
        return [...document.querySelectorAll('.att-row')].map(r => ({
            Name: r.querySelector('.an').value.trim(), Relation: r.querySelector('.ar').value.trim(), Phone: r.querySelector('.ap').value.trim(),
            IdTypeId: Number(r.querySelector('.ait').value) || null, IdNumber: r.querySelector('.ain').value.trim(), IsPrimary: r.dataset.primary === '1'
        })).filter(a => a.Name);
    }

    // ── MLC ─────────────────────────────────────────────────────────────────────────────────────────────
    document.getElementById('IsMlc').addEventListener('change', e => document.getElementById('mlcBlock').classList.toggle('d-none', !e.target.checked));
    const v = id => document.getElementById(id)?.value?.trim() || null;
    function mlc() {
        return { MlcNo: v('mlcNo'), Nature: v('mlcNature'), IncidentAt: v('mlcIncidentAt'), IncidentPlace: v('mlcPlace'), BroughtBy: v('mlcBroughtBy'),
                 BroughtByPhone: v('mlcBroughtPhone'), PoliceStation: v('mlcPolice'), InformedAt: v('mlcInformedAt'), OfficerName: v('mlcOfficer'), Remarks: v('mlcRemarks') };
    }

    // ── consent preview ─────────────────────────────────────────────────────────────────────────────────
    document.getElementById('btnConsentPreview').addEventListener('click', async () => {
        const id = document.getElementById('ConsentId').value; if (!id) return;
        try {
            const c = await Ipd.get(base + 'ConsentPreview?consentId=' + id);
            const name = [v('Salutation'), v('FirstName'), v('MiddleName'), v('LastName')].filter(Boolean).join(' ');
            const age = v('AgeYears') ? v('AgeYears') + ' Y' : '';
            const doctor = $('#ConsultantDoctorId option:selected').text();
            const map = { PatientName: name, UHID: v('PatientCode') || '(new)', IPDNo: '(given on admission)', Age: age, Gender: v('Gender') || '', DoctorName: doctor.replace(/^--.*$/, ''),
                          HospitalName: c.HospitalName || '', Relationship: v('ConsentSignedByRelation') || '', WitnessName: v('ConsentWitnessName') || '', Date: Ipd.date(new Date()),
                          Time: new Date().toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit' }), DepartmentName: $('#DepartmentId option:selected').text().replace(/^--.*$/, ''), OPDNo: '', ProcedureName: '' };
            const html = String(c.ContentHtml || '').replace(/\{\{(\w+)\}\}/g, (m, k) => k in map ? E(map[k]) : m);
            document.getElementById('consentTitle').textContent = c.ConsentType + ' · ' + c.Language + ' v' + c.Version;
            document.getElementById('consentBody').innerHTML = html;
            bootstrap.Modal.getOrCreateInstance(document.getElementById('consentModal')).show();
        } catch (e) { Ipd.error(e.message); }
    });

    // ── patient search & load (same endpoints as OPD / LAB, served for IPD) ─────────────────────────────
    function sugHtml(list) {
        return list.map((p, i) => `<button type="button" class="list-group-item list-group-item-action sug py-2 px-3 ${i === 0 ? 'active' : ''}" data-id="${p.patientId}">
            <div class="d-flex align-items-center gap-1 flex-wrap"><span class="fw-semibold">${E(p.fullName)}</span><span class="badge text-bg-info text-dark font-monospace">${E(p.patientCode)}</span>
            ${p.relationName ? `<span class="badge text-bg-primary">${E(p.relationName)}</span>` : ''}</div>
            <small class="text-muted">${E(p.phoneNumber || '')} · ${E(p.gender || '')}${p.formattedAge ? ' · ' + E(p.formattedAge) : ''}</small></button>`).join('');
    }
    function wireSuggest(input, box, urlFor, minLen) {
        let t, idx = 0;
        input.addEventListener('input', () => {
            clearTimeout(t);
            const val = input.value.trim();
            if (val.length < minLen) { box.style.display = 'none'; return; }
            t = setTimeout(async () => {
                const data = await Ipd.getRaw(urlFor(val));
                if (input === document.getElementById('PhoneNumber') && Number(document.getElementById('PatientId').value) > 0) return;
                if (data && data.length) { box.innerHTML = sugHtml(data); box.style.display = 'block'; idx = 0; }
                else if (input.id === 'searchInput') { box.innerHTML = '<div class="list-group-item small text-muted">No matching patient. Register below as a new patient.</div>'; box.style.display = 'block'; }
                else {
                    box.style.display = 'none';
                    const digits = val.replace(/\D/g, '');
                    if (digits.length === 10 && !document.getElementById('RelationId').value) {
                        const self = (L.relations || []).find(r => /^self$/i.test(r.Name)); if (self) document.getElementById('RelationId').value = self.Id;
                    }
                }
            }, 260);
        });
        input.addEventListener('keydown', e => {
            const items = [...box.querySelectorAll('.sug')]; if (box.style.display === 'none' || !items.length) return;
            if (e.key === 'ArrowDown' || e.key === 'ArrowUp') { e.preventDefault(); idx = (idx + (e.key === 'ArrowDown' ? 1 : -1) + items.length) % items.length; items.forEach((x, i) => x.classList.toggle('active', i === idx)); items[idx].scrollIntoView({ block: 'nearest' }); }
            else if (e.key === 'Enter') { e.preventDefault(); loadPatient(items[idx].dataset.id); }
            else if (e.key === 'Escape') box.style.display = 'none';
        });
        box.addEventListener('mousedown', e => e.preventDefault());
        box.addEventListener('click', e => { const b = e.target.closest('.sug'); if (b) loadPatient(b.dataset.id); });
        document.addEventListener('click', e => { if (!box.contains(e.target) && e.target !== input) box.style.display = 'none'; });
    }
    const searchUrl = val => {
        const type = document.getElementById('searchType').value, digits = /^\d+$/.test(val);
        if (type === 'code') return base + 'SearchPatientByCode?code=' + encodeURIComponent(val);
        if (type === 'phone' && digits) return base + 'SearchPatientByPhone?phone=' + encodeURIComponent(val);
        if (type === 'name' && digits && val.length >= 3) return base + 'SearchPatientByPhone?phone=' + encodeURIComponent(val);
        return base + 'SearchPatientByName?name=' + encodeURIComponent(val);
    };
    wireSuggest(document.getElementById('searchInput'), document.getElementById('topSug'), searchUrl, 2);
    wireSuggest(document.getElementById('PhoneNumber'), document.getElementById('phoneSug'), val => base + 'SearchPatientByPhone?phone=' + encodeURIComponent(val), 3);

    async function cascade(child, action, param, parentVal, valKey, textKey, select) {
        const el = document.getElementById(child);
        el.innerHTML = '<option value="">--</option>';
        if (parentVal) {
            const data = await Ipd.getRaw(base + action + '?' + param + '=' + parentVal) || [];
            data.forEach(r => el.append(new Option(r[textKey], r[valKey])));
        }
        if (select) el.value = select;
        $(el).trigger('change.select2');
    }
    $('#CountryId').on('change', function () { cascade('StateId', 'GetStatesByCountry', 'countryId', this.value, 'stateId', 'stateName'); ['DistrictId', 'CityId', 'AreaId'].forEach(i => { document.getElementById(i).innerHTML = '<option value="">--</option>'; }); });
    $('#StateId').on('change', function () { cascade('DistrictId', 'GetDistrictsByState', 'stateId', this.value, 'districtId', 'districtName'); });
    $('#DistrictId').on('change', function () { cascade('CityId', 'GetCitiesByDistrict', 'districtId', this.value, 'cityId', 'cityName'); });
    $('#CityId').on('change', function () { cascade('AreaId', 'GetAreasByCity', 'cityId', this.value, 'areaId', 'areaName'); });

    async function loadPatient(id) {
        document.getElementById('topSug').style.display = 'none'; document.getElementById('phoneSug').style.display = 'none';
        const p = await Ipd.getRaw(base + 'GetPatientDetails?id=' + id);
        if (!p) { Ipd.error('The patient could not be loaded.'); return; }
        const set = (k, val) => { const el = document.getElementById(k); if (el) el.value = val ?? ''; };
        set('PatientId', p.patientId); set('PatientCode', p.patientCode);
        ['PhoneNumber', 'SecondaryPhoneNumber', 'FirstName', 'MiddleName', 'LastName', 'EmailId', 'GuardianName', 'IdentificationNumber', 'KnownAllergies', 'AbhaNumber', 'AbhaAddress', 'Address', 'Pincode']
            .forEach(k => set(k, p[k.charAt(0).toLowerCase() + k.slice(1)]));
        set('PatientRemarks', p.remarks);
        ['Salutation', 'Gender', 'BloodGroup', 'RelationId', 'ReligionId', 'OccupationId', 'MaritalStatusId', 'LanguageId', 'IdentificationTypeId']
            .forEach(k => set(k, p[k.charAt(0).toLowerCase() + k.slice(1)]));
        set('DateOfBirth', p.dateOfBirth ? p.dateOfBirth.substring(0, 10) : '');
        set('AgeYears', p.ageYears); set('AgeMonths', p.ageMonths); set('AgeDays', p.ageDays);
        set('PhotoPath', p.photoPath || ''); set('IdentificationFilePath', p.identificationFilePath || '');
        const ph = document.getElementById('PhoneNumber'); ph.readOnly = true; ph.classList.add('bg-light'); ph.title = 'The phone of an existing patient is changed only in Patient Master > Edit';
        const img = document.getElementById('photoPreview'); if (p.photoPath) { img.src = p.photoPath; img.classList.remove('d-none'); } else img.classList.add('d-none');
        document.getElementById('idDocNote').innerHTML = p.identificationFilePath ? `On record: <a href="${E(p.identificationFilePath)}" target="_blank">view</a>` : '';
        const badge = document.getElementById('loadedBadge'); badge.textContent = p.patientCode; badge.classList.remove('d-none');
        document.getElementById('searchInput').value = `${p.firstName ?? ''} ${p.lastName ?? ''} (${p.patientCode})`;
        $('#CountryId').val(p.countryId || '').trigger('change.select2');
        if (p.countryId) {
            await cascade('StateId', 'GetStatesByCountry', 'countryId', p.countryId, 'stateId', 'stateName', p.stateId);
            if (p.stateId) await cascade('DistrictId', 'GetDistrictsByState', 'stateId', p.stateId, 'districtId', 'districtName', p.districtId);
            if (p.districtId) await cascade('CityId', 'GetCitiesByDistrict', 'districtId', p.districtId, 'cityId', 'cityName', p.cityId);
            if (p.cityId) await cascade('AreaId', 'GetAreasByCity', 'cityId', p.cityId, 'areaId', 'areaName', p.areaId);
        }
        if (!v('ConsentSignedByName')) set('ConsentSignedByName', [p.firstName, p.lastName].filter(Boolean).join(' '));
        showSelectedBed();
        Ipd.toast(`${p.firstName ?? ''} ${p.lastName ?? ''} (${p.patientCode}) loaded`);
        loadStatus(p.patientId);
        renderBeds();   // a bed reserved for this patient becomes selectable
    }

    async function loadStatus(patientId) {
        const box = document.getElementById('patientStatus'), seq = ++statusSeq;
        box.classList.add('d-none'); box.innerHTML = '';
        fill('EstimateId', [], 'EstimateId', 'EstimateNo', '-- None --');
        if (!(patientId > 0)) return;
        let s; try { s = await Ipd.get(base + 'PatientStatus?patientId=' + patientId); } catch { return; }
        if (seq !== statusSeq) return;
        const open = (s.open || [])[0], prev = s.previous || [], est = s.estimates || [];
        fill('EstimateId', est, 'EstimateId', r => `${r.EstimateNo} · ${Ipd.money(r.TotalAmount)} · ${Ipd.date(r.EstimateDate)}`, '-- None --');
        if (presetEstimate && est.some(e => e.EstimateId === presetEstimate)) document.getElementById('EstimateId').value = presetEstimate;
        let html = '';
        if (open) html += `<div class="alert alert-danger py-2 mb-2 small"><i class="bi bi-exclamation-octagon-fill me-1"></i>Already admitted: <b>${E(open.IpNo)}</b>, ${E(open.WardName || '')} bed ${E(open.BedNumber || '')} (${E(open.BranchName || '')}) since ${Ipd.dt(open.AdmissionAt)}.
            <a class="fw-semibold ms-1" href="${base}Patient/${open.AdmissionId}">Open the admission</a></div>`;
        if (prev.length) html += `<div class="small text-muted"><i class="bi bi-clock-history me-1"></i>Earlier stays: ${prev.map(a => `<a href="${base}Patient/${a.AdmissionId}" target="_blank">${E(a.IpNo)}</a> (${Ipd.date(a.AdmissionAt)})`).join(', ')}</div>`;
        if (est.length) html += `<div class="small text-success mt-1"><i class="bi bi-file-earmark-medical me-1"></i>${est.length} active pre-admission estimate(s): choose it under Payer &amp; Tariff.</div>`;
        if (html) { box.innerHTML = html; box.classList.remove('d-none'); }
        document.getElementById('btnAdmit').disabled = !!open;
    }

    document.getElementById('btnClearPatient').addEventListener('click', clearPatient);
    function clearPatient() {
        ['PatientId', 'PatientCode', 'PhotoPath', 'IdentificationFilePath'].forEach(k => document.getElementById(k).value = k === 'PatientId' ? '0' : '');
        ['PhoneNumber', 'SecondaryPhoneNumber', 'FirstName', 'MiddleName', 'LastName', 'EmailId', 'GuardianName', 'KnownAllergies', 'DateOfBirth', 'AgeYears', 'AgeMonths', 'AgeDays', 'Address', 'Pincode', 'IdentificationNumber', 'PatientRemarks', 'searchInput']
            .forEach(k => { const el = document.getElementById(k); if (el) el.value = ''; });
        ['Salutation', 'Gender', 'BloodGroup', 'RelationId'].forEach(k => document.getElementById(k).value = '');
        const ph = document.getElementById('PhoneNumber'); ph.readOnly = false; ph.classList.remove('bg-light'); ph.title = '';
        document.getElementById('loadedBadge').classList.add('d-none'); document.getElementById('photoPreview').classList.add('d-none');
        document.getElementById('idDocNote').innerHTML = '';
        loadStatus(0); document.getElementById('btnAdmit').disabled = false;
        if (selectedBed && !selectable(selectedBed)) { selectedBed = null; document.getElementById('BedId').value = ''; }
        renderBeds();
    }

    // DOB <-> age
    document.getElementById('DateOfBirth').addEventListener('change', e => {
        if (!e.target.value) return;
        const b = new Date(e.target.value), t = new Date();
        let y = t.getFullYear() - b.getFullYear(), m = t.getMonth() - b.getMonth(), d = t.getDate() - b.getDate();
        if (d < 0) { m--; d += new Date(t.getFullYear(), t.getMonth(), 0).getDate(); } if (m < 0) { y--; m += 12; }
        document.getElementById('AgeYears').value = y; document.getElementById('AgeMonths').value = m; document.getElementById('AgeDays').value = d;
    });
    ['AgeYears', 'AgeMonths', 'AgeDays'].forEach(id => document.getElementById(id).addEventListener('input', () => { document.getElementById('DateOfBirth').value = ''; }));
    document.getElementById('profilePictureFile').addEventListener('change', e => {
        const f = e.target.files[0], img = document.getElementById('photoPreview');
        if (f) { img.src = URL.createObjectURL(f); img.classList.remove('d-none'); }
    });

    // ── submit ──────────────────────────────────────────────────────────────────────────────────────────
    function payer() {
        const p = payerType(); if (p === 'CASH') return [];
        return [{ PayerType: p, InsuranceTpaId: p === 'INSURANCE' ? Number(v('InsuranceTpaId')) || null : null, CorporateId: p === 'CORPORATE' ? Number(v('CorporateId')) || null : null,
                  SchemeId: p === 'SCHEME' ? Number(v('SchemeId')) || null : null, PolicyNo: v('PolicyNo'), MemberId: v('MemberId'), CardHolderName: v('CardHolderName'),
                  RelationToHolder: v('RelationToHolder'), PolicyValidTo: v('PolicyValidTo'), EmployeeId: v('EmployeeId') }];
    }
    function check() {
        const need = [['PhoneNumber', 'the 10-digit mobile number', x => /^\d{10}$/.test(x)], ['FirstName', 'the first name'], ['LastName', 'the last name'], ['Gender', 'the gender'],
                      ['RelationId', 'the relation'], ['AdmittingDoctorId', 'the admitting doctor'], ['ConsultantDoctorId', 'the consultant'], ['TariffCategoryId', 'the tariff category']];
        for (const [id, what, ok] of need) { const val = v(id) || ''; if (!val || (ok && !ok(val))) { document.getElementById(id).focus(); return 'Enter ' + what + '.'; } }
        if (!v('DateOfBirth') && !(Number(v('AgeYears')) || Number(v('AgeMonths')) || Number(v('AgeDays')))) return 'Enter the age or date of birth.';
        if (!v('BedId')) return 'Choose a bed on the bed board.';
        const p = payerType();
        if (p === 'INSURANCE' && (!v('InsuranceTpaId') || !v('PolicyNo'))) return 'Choose the insurance / TPA and enter the policy number.';
        if (p === 'CORPORATE' && !v('CorporateId')) return 'Choose the corporate.';
        if (p === 'SCHEME' && !v('SchemeId')) return 'Choose the government scheme.';
        if (settings.IpdConsentRequired && !v('ConsentId')) return 'The general admission consent is required.';
        if (v('ConsentId') && !v('ConsentSignedByName')) return 'Enter who signed the consent.';
        const need2 = minAdvance(), total = payTotal();
        if (need2 && total < need2 && !canWaive) return `A minimum advance of ${Ipd.money(need2)} is needed for a cash patient.`;
        if (need2 && total < need2 && canWaive && !v('AdvanceWaiveReason')) return 'Enter the reason for admitting below the minimum advance.';
        return null;
    }
    let saving = false;
    document.getElementById('admForm').addEventListener('submit', async e => {
        e.preventDefault();
        if (saving) return;
        const problem = check(); if (problem) { Ipd.error(problem); return; }
        const pays = payRows();
        const summary = `<div class="text-start small"><div><b>${E([v('FirstName'), v('LastName')].join(' '))}</b> · ${E(v('PhoneNumber'))}</div>
            <div>Bed <b>${E(selectedBed.BedNumber)}</b> · ${E(selectedBed.WardName)} · ${E(Ipd.payer(payerType()))}</div>
            <div>Advance <b>${Ipd.money(payTotal())}</b>${pays.length > 1 ? ' (' + pays.length + ' modes)' : ''}</div></div>`;
        if (!await Ipd.confirm('Admit this patient?', summary, 'Admit')) return;
        const fd = new FormData(document.getElementById('admForm'));
        fd.set('PayerType', payerType());
        fd.set('IsMlc', document.getElementById('IsMlc').checked ? 'true' : 'false');
        fd.set('PayersJson', JSON.stringify(payer()));
        fd.set('AttendantsJson', JSON.stringify(attendants()));
        fd.set('MlcJson', JSON.stringify(mlc()));
        fd.set('PaymentsJson', JSON.stringify(pays));
        fd.set('ConsentSignature', v('ConsentId') ? sig.sigPatient.dataUrl() : '');
        fd.set('WitnessSignature', v('ConsentId') ? sig.sigWitness.dataUrl() : '');
        fd.set('AdmissionAt', canBackdate ? (v('AdmissionAt') || '') : '');   // without the Back-date permission the server takes the time of saving
        const card = document.getElementById('payerCardFile').files[0]; if (card) fd.set('payerCardFile', card); else fd.delete('payerCardFile');
        const btn = document.getElementById('btnAdmit');
        saving = true; btn.disabled = true; btn.innerHTML = '<span class="spinner-border spinner-border-sm me-2"></span>Admitting…';
        try {
            const r = await Ipd.postForm(base + 'Save', fd);
            if (r.patientId) document.getElementById('PatientId').value = r.patientId;   // a retry reuses the saved patient
            if (!r.success) { Ipd.error(r.error); if (/bed/i.test(r.error || '')) loadBeds(); return; }
            document.getElementById('doneIp').textContent = r.ipNo;
            document.getElementById('doneRcpt').textContent = r.receiptNo ? 'Advance receipt ' + r.receiptNo : 'No advance taken';
            document.getElementById('doneOpen').href = r.url;
            document.getElementById('doneFace').href = base + 'PrintFaceSheet/' + r.admissionId;
            document.getElementById('doneBand').href = base + 'PrintWristband/' + r.admissionId;
            const rc = document.getElementById('doneReceipt');
            if (r.advanceId) { rc.href = base + 'PrintReceipt/' + r.advanceId; rc.classList.remove('d-none'); }
            bootstrap.Modal.getOrCreateInstance(document.getElementById('doneModal')).show();
        } catch (err) { Ipd.error(err.message); }
        finally { saving = false; btn.disabled = false; btn.innerHTML = '<i class="bi bi-hospital me-2"></i>Admit Patient'; }
    });
    document.addEventListener('keydown', e => { if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 's') { e.preventDefault(); document.getElementById('btnAdmit').click(); } });
    document.getElementById('btnReset').addEventListener('click', () => window.location.reload());

    Ipd.icdSuggest(document.getElementById('DiagnosisCode'), document.getElementById('ProvisionalDiagnosis'), base + 'IcdSearch');
    loadLookups().then(() => { if (presetPatient) loadPatient(presetPatient); }).catch(e => Ipd.error(e.message));
})();
