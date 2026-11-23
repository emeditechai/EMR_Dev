// Pharmacy > Sales > POS (SQLScripts/2348). Keyboard-first counter billing. Amounts are a preview with the same rules as the
// server (PharmacySaleService), which works everything out again when the bill is saved.
(function () {
    'use strict';
    const esc = v => String(v ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
    const num = v => { const n = parseFloat(v); return isFinite(n) ? n : 0; };
    const r2 = v => Math.round((v + Number.EPSILON) * 100) / 100;
    const money = v => r2(v).toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
    const q3 = v => (Math.round(v * 1000) / 1000).toLocaleString('en-IN');
    const mon = d => d ? new Date(d).toLocaleDateString('en-GB', { month: 'short', year: '2-digit' }) : '';
    const $ = id => document.getElementById(id);
    const token = () => document.querySelector('input[name="__RequestVerificationToken"]').value;
    const toast = (icon, title) => Swal.fire({ toast: true, position: 'top-end', icon, title, timer: 2200, showConfirmButton: false });
    const getJson = url => fetch(url, { headers: { 'X-Requested-With': 'XMLHttpRequest' } }).then(r => r.ok ? r.json() : []).catch(() => []);
    const postJson = (url, body) => fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json', 'RequestVerificationToken': token(), 'X-Requested-With': 'XMLHttpRequest' }, body: JSON.stringify(body) })
        .then(async r => r.ok ? r.json() : { error: r.status === 403 ? 'You do not have permission for this action.' : 'The server could not save it (' + r.status + ').' });

    window.PhPos = function (cfg) {
        let kind = 'WALKIN', patient = null, customer = null, doctorId = null, holdId = null, seq = 0;
        let lines = [], pays = [];
        // SQLScripts/2406: linked OPD prescription, clinical alerts, loyalty
        let rx = null, alerts = [], loyalty = null;

        // ── counter (selling store): remembered per branch on this computer; changing it empties the bill ──
        const storeSel = $('posStore');
        const storeKey = 'phPosStore:' + (cfg.branchId || '');
        try { const saved = localStorage.getItem(storeKey); if (saved && storeSel && storeSel.tagName === 'SELECT' && [...storeSel.options].some(o => o.value === saved)) storeSel.value = saved; } catch { }
        const storeQ = () => storeSel && storeSel.value ? '&storeId=' + encodeURIComponent(storeSel.value) : '';
        if (storeSel && storeSel.tagName === 'SELECT') storeSel.addEventListener('change', () => {
            try { localStorage.setItem(storeKey, storeSel.value); } catch { }
            if (lines.length) { reset(); toast('info', 'Counter changed: the bill was cleared.'); }
        });

        // ── customer ─────────────────────────────────────────────────────────────────────────────────
        function renderCustomer() {
            const box = $('custBox');
            if (kind === 'WALKIN') {
                // SQLScripts/2412: mobile first - a returning walk-in's name and address come from the last bill
                box.innerHTML = `<div class="row g-2"><div class="col-md-3"><label class="form-label">Mobile</label><input id="wMobile" class="form-control num" placeholder="10-digit mobile" maxlength="10" inputmode="numeric" autocomplete="off"></div>
                    <div class="col-md-4"><label class="form-label">Name</label><input id="wName" class="form-control" placeholder="Customer name" maxlength="150"></div>
                    <div class="col-md-5"><label class="form-label">Address</label><input id="wAddress" class="form-control" placeholder="Needed for Schedule H1 / X" maxlength="300"></div></div>`;
                $('wName').addEventListener('input', rxCheck); $('wAddress').addEventListener('input', rxCheck);
                // SQLScripts/2409: a walk-in's wallet is on the mobile number
                let mt; $('wMobile').addEventListener('input', () => {
                    $('wMobile').value = $('wMobile').value.replace(/\D/g, '').slice(0, 10);
                    clearTimeout(mt); mt = setTimeout(() => { customerExtras(); walkinLookup(); }, 350);
                });
                $('wMobile').addEventListener('keydown', e => { if (e.key === 'Enter') { e.preventDefault(); ($('wName').value ? $('itemSearch') : $('wName')).focus(); } });
                $('wMobile').insertAdjacentHTML('afterend', '<div class="small mt-1" id="wHint"></div>');
            } else {
                const sel = kind === 'PATIENT' ? patient : customer;
                if (sel) {
                    box.innerHTML = `<label class="form-label">${kind === 'PATIENT' ? 'Patient' : 'Credit customer'}</label><div class="pos-chip"><div class="text-truncate"><i class="bi ${kind === 'PATIENT' ? 'bi-person-vcard' : 'bi-wallet2'} me-1" style="color:var(--pos-accent)"></i><b>${esc(sel.name)}</b>
                        <span class="small text-muted ms-1">${kind === 'PATIENT' ? 'UHID ' + esc(sel.uhid) + ' · ' : ''}${esc(sel.mobile || '')}</span>
                        ${kind === 'CUSTOMER' ? `<span class="small ms-2 ${sel.credit ? 'text-success' : 'text-muted'}">${sel.credit ? `credit limit ₹${money(sel.creditLimit)} · due ₹${money(sel.outstanding)}` : 'no credit'}</span>` : ''}
                        ${kind === 'CUSTOMER' && sel.type === 'STAFF' ? '<span class="badge bg-info-subtle text-info-emphasis ms-1">staff price</span>' : ''}</div>
                        <button type="button" class="btn btn-sm btn-link p-0" id="custChange">Change</button></div>`;
                    $('custChange').onclick = () => { if (kind === 'PATIENT') patient = null; else customer = null; renderCustomer(); refreshPrices(); };
                } else {
                    box.innerHTML = `<label class="form-label">${kind === 'PATIENT' ? 'Find patient' : 'Find credit customer'}</label><div class="position-relative"><input id="custSearch" class="form-control" autocomplete="off"
                        placeholder="${kind === 'PATIENT' ? 'UHID, mobile or name (F4)' : 'Name or mobile (F4)'}">
                        <div id="custList" class="pos-drop simple d-none"></div></div>`;
                    picker($('custSearch'), $('custList'), q => getJson((kind === 'PATIENT' ? cfg.urls.patients : cfg.urls.customers) + '?q=' + encodeURIComponent(q)),
                        r => `<div><div class="nm">${esc(r.name)}</div><div class="sub">${kind === 'PATIENT' ? 'UHID ' + esc(r.uhid) + (r.lastDoctor ? ' · last seen by ' + esc(r.lastDoctor) : '') : (r.credit ? 'credit ₹' + money(r.creditLimit) + ' · due ₹' + money(r.outstanding) : 'no credit')}</div></div>
                              <span class="sub num">${esc(r.mobile || '')}</span>`,
                        r => {
                            if (kind === 'PATIENT') { patient = r; if (r.lastDoctor && !$('docName').value) { $('docName').value = r.lastDoctor; doctorId = r.lastDoctorId; } }
                            else customer = r;
                            renderCustomer(); refreshPrices(); focusSearch();
                        }, 1);
                }
            }
            rxCheck(); customerExtras(); clinKey = ''; clinicalSoon();
        }
        document.querySelectorAll('input[name=ck]').forEach(r => r.addEventListener('change', () => { kind = r.value; renderCustomer(); refreshPrices(); totals(); }));

        // returning walk-in (SQLScripts/2412): fill name / address from the last bill; offer the registered patient
        let lookedUp = '';
        async function walkinLookup() {
            const m = ($('wMobile')?.value || '').trim(), hint = $('wHint');
            if (!hint) return;
            if (!/^[6-9]\d{9}$/.test(m)) { hint.innerHTML = m.length === 10 ? '<span class="text-danger">Mobile must start with 6-9.</span>' : ''; lookedUp = ''; return; }
            if (m === lookedUp) return;
            lookedUp = m;
            const r = await getJson(cfg.urls.walkin + '?mobile=' + m);
            if ($('wMobile')?.value.trim() !== m) return;
            const last = r && r.last, pts = (r && r.patients) || [];
            if (last) {
                if (!$('wName').value.trim()) $('wName').value = last.Name || '';
                if (!$('wAddress').value.trim()) $('wAddress').value = last.Address || '';
                rxCheck();
            }
            hint.innerHTML = (last ? `<span class="text-success"><i class="bi bi-person-check me-1"></i>Returning buyer · ${last.Bills} bill(s), last ${new Date(last.LastBillDate).toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' })}</span>` : '<span class="text-muted">New buyer</span>')
                + (pts.length ? `<div>${pts.map((p, k) => `<a href="#" class="me-2" data-pt="${k}"><i class="bi bi-person-vcard me-1"></i>Bill as patient ${esc(p.name)} (${esc(p.uhid)})</a>`).join('')}</div>` : '');
            hint.querySelectorAll('[data-pt]').forEach(a => a.onclick = ev => {
                ev.preventDefault();
                patient = pts[a.dataset.pt]; kind = 'PATIENT'; document.querySelector('input[name=ck][value=PATIENT]').checked = true;
                renderCustomer(); refreshPrices(); totals(); focusSearch();
            });
        }

        // ── who the bill is for: OPD prescriptions, loyalty points, credit reference (SQLScripts/2406) ──────
        const member = () => kind === 'PATIENT' && patient ? { patientId: patient.id } : kind === 'CUSTOMER' && customer ? { customerId: customer.id }
            : kind === 'WALKIN' && cfg.settings.LoyaltyWalkinByMobile && /^[6-9]\d{9}$/.test(($('wMobile')?.value || '').trim()) ? { mobile: $('wMobile').value.trim() } : null;
        let extrasFor = '', loyFilled = null;
        async function customerExtras() {
            const m = member(), key = JSON.stringify(m || {}) + kind;
            if (key === extrasFor) return;
            extrasFor = key;
            if (rx && !(kind === 'PATIENT' && patient)) { rx = null; renderRx(); }
            // credit reference for corporate / insurance credit
            const ct = kind === 'CUSTOMER' && customer ? customer.type : null;
            $('creditRefBox').classList.toggle('d-none', !(ct === 'CORPORATE' || ct === 'INSURANCE'));
            $('creditRefLbl').textContent = ct === 'INSURANCE' ? 'Policy / claim no.' : 'Employee ID / authorisation no.';
            // loyalty
            // a member discount filled in for the previous buyer goes away with them (SQLScripts/2408)
            if (loyFilled != null && num($('billDisc').value) === loyFilled) $('billDisc').value = 0;
            loyFilled = null;
            loyalty = null; $('loyRedeem').value = 0;
            if (cfg.settings.LoyaltyEnabled && m) {
                const l = await getJson(cfg.urls.loyalty + '?' + new URLSearchParams(m));
                if (l && l.Enabled && l.IsMember) loyalty = l;
            }
            $('loyRow').classList.toggle('d-none', !loyalty);
            const loyDisc = loyalty && loyalty.LoyaltyType === 'DISCOUNT';
            $('loyRedeem').classList.toggle('d-none', !!loyDisc);
            if (loyDisc) {   // SQLScripts/2407/2408: the member's loyalty % is the default bill discount, no points
                $('loyInfo').innerHTML = `<span class="badge bg-success-subtle text-success border">Member discount ${num(loyalty.DiscountPercent)}% - set as bill discount</span>`;
                if (num($('billDisc').value) < num(loyalty.DiscountPercent)) { $('billDisc').value = num(loyalty.DiscountPercent); loyFilled = num(loyalty.DiscountPercent); }
                render();
            } else if (loyalty) {   // wallet (SQLScripts/2409): use points from earlier bills; this bill's credit comes after
                const can = loyalty.Points >= loyalty.MinRedeem && loyalty.Points > 0;
                const extra = [loyalty.Pending > 0 ? `${q3(loyalty.Pending)} pending` : '', loyalty.ExpiringSoon > 0 ? `<span class="text-danger">${q3(loyalty.ExpiringSoon)} expire by ${new Date(loyalty.NextExpiry).toLocaleDateString('en-GB', { day: '2-digit', month: 'short' })}</span>` : ''].filter(Boolean).join(' · ');
                $('loyOtpBox').classList.toggle('d-none', !(can && loyalty.RedeemOtp));
                $('loyInfo').innerHTML = `<i class="bi bi-wallet2 me-1"></i>Wallet <b>${q3(loyalty.Points)}</b> pts = ₹${money(loyalty.Points * loyalty.PointValue)}${can ? ` · up to ${num(loyalty.MaxRedeemPercent)}% of bill` : loyalty.Points > 0 ? ` · usable from ${loyalty.MinRedeem}` : ''}${extra ? '<br>' + extra : ''}<br><span class="text-success">This bill earns ${num(loyalty.EarnPercent)}%${loyalty.MinBillToEarn > 0 ? ` (bill ≥ ₹${money(loyalty.MinBillToEarn)})` : ''}</span>`;
                $('loyRedeem').disabled = !can; $('loyRedeem').max = loyalty.Points;
            }
            // OPD prescriptions of the patient
            const box = $('rxPanel');
            if (cfg.settings.RxLinkEnabled && kind === 'PATIENT' && patient && !rx) {
                const list = await getJson(cfg.urls.rxList + '?patientId=' + patient.id);
                box.classList.toggle('d-none', !list.length);
                box.innerHTML = list.length ? `<div class="alert alert-info py-1 px-2 small mb-0 d-flex align-items-center gap-2"><i class="bi bi-file-medical"></i>
                    <span><b>${list.length}</b> OPD prescription(s) in the last 30 days.</span>
                    <button type="button" class="btn btn-sm btn-primary py-0 ms-auto" id="rxPick"><i class="bi bi-download me-1"></i>Load prescription</button></div>` : '';
                $('rxPick') && ($('rxPick').onclick = () => pickRx(list));
            } else if (!rx) { box.classList.add('d-none'); box.innerHTML = ''; }
            totals();
        }
        $('loyRedeem').addEventListener('input', () => totals());
        $('loyOtpSend').addEventListener('click', async () => {
            const m = member(); if (!m) return;
            $('loyOtpSend').disabled = true;
            const r = await postJson(cfg.urls.loyaltyOtp, { PatientId: m.patientId || null, CustomerId: m.customerId || null, Mobile: m.mobile || null });
            toast(r.success ? 'success' : 'error', r.message || 'Could not send the OTP.');
            setTimeout(() => $('loyOtpSend').disabled = false, 30000);
            $('loyOtp').focus();
        });
        const loyPct = () => loyalty && loyalty.LoyaltyType === 'DISCOUNT' ? num(loyalty.DiscountPercent) : 0;
        const redeemValue = () => {
            if (!loyalty || loyalty.LoyaltyType === 'DISCOUNT') return 0;
            const pts = Math.min(Math.floor(num($('loyRedeem').value)), loyalty.Points);
            return pts > 0 ? r2(pts * loyalty.PointValue) : 0;
        };

        async function pickRx(list) {
            const r = await Swal.fire({
                title: 'OPD prescriptions', width: 680, showCancelButton: true, showConfirmButton: false, cancelButtonText: 'Close',
                html: `<div class="list-group text-start">${list.map((c, k) => `<button type="button" class="list-group-item list-group-item-action" data-c="${k}">
                    <div class="d-flex justify-content-between"><b>${new Date(c.VisitDate).toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' })} · ${esc(c.DoctorName || '')}</b>
                    <span class="small">${c.Medicines} medicine(s)</span></div>
                    <div class="small text-muted">${esc(c.OPDBillNo || '')}${c.DispensedOn ? ` · <span class="text-warning-emphasis">already dispensed on bill ${esc(c.DispensedOn)}</span>` : ''}</div></button>`).join('')}</div>`,
                didOpen: el => el.querySelectorAll('[data-c]').forEach(b => b.addEventListener('click', () => { Swal.close(); loadRx(list[b.dataset.c]); }))
            });
            return r;
        }
        async function loadRx(c) {
            const d = await getJson(cfg.urls.rxLines + '?consultationId=' + c.ConsultationId + storeQ());
            if (!d || !d.head) { toast('error', 'Prescription not found.'); return; }
            const h = d.head;
            rx = { id: h.ConsultationId, no: h.OPDBillNo, date: h.VisitDate, lines: d.lines.map(x => ({ ...x, reason: '' })) };
            $('docName').value = h.DoctorName || ''; $('docReg').value = h.DoctorRegNo || ''; doctorId = h.DoctorId || null;
            $('rxNo').value = h.OPDBillNo || ('OPD-' + h.ConsultationId); $('rxDate').value = String(h.VisitDate).slice(0, 10);
            // add the suggested brand of each medicine (one pack / unit to start with)
            for (const m of rx.lines) {
                if (!m.SuggestedItemId || lines.some(l => l.item.genericId === m.GenericId)) continue;
                const found = (await getJson(cfg.urls.items + '?genericId=' + m.GenericId + storeQ())).find(x => x.itemId === m.SuggestedItemId);
                if (found) await addItem(found);
            }
            renderRx(); rxCheck(); focusSearch();
        }
        const NOT_GIVEN = ['Out of stock', 'Patient declined', 'Patient already has it', 'Substituted on doctor\'s advice', 'Buying elsewhere'];
        function renderRx() {
            const box = $('rxPanel');
            if (!rx) { box.classList.add('d-none'); box.innerHTML = ''; extrasFor = ''; return; }
            box.classList.remove('d-none');
            box.innerHTML = `<div class="border rounded p-2" style="background:#f8fafc">
                <div class="d-flex align-items-center gap-2 small mb-1"><i class="bi bi-file-medical text-primary"></i><b>OPD prescription ${esc(rx.no || '')}</b>
                    <span class="text-muted">${new Date(rx.date).toLocaleDateString('en-GB')}</span>
                    <button type="button" class="btn btn-sm btn-link p-0 ms-auto" id="rxDrop">unlink</button></div>
                <table class="table table-sm mb-0 small align-middle"><tbody>${rx.lines.map((m, k) => {
                    const given = m.GenericId && lines.some(l => l.item.genericId === m.GenericId);
                    m.status = given ? 'DISPENSED' : 'NOT_DISPENSED';
                    m.itemId = given ? lines.find(l => l.item.genericId === m.GenericId).item.itemId : null;
                    return `<tr><td style="width:22px">${given ? '<i class="bi bi-check-circle-fill text-success"></i>' : '<i class="bi bi-circle text-danger"></i>'}</td>
                        <td><b>${esc(m.MedicationName)}</b> <span class="text-muted">${esc([m.Dose, m.Frequency, m.Instructions].filter(Boolean).join(' · '))}</span>
                            <div class="text-muted">${m.GenericId ? esc(m.GenericName) + (m.Mapped ? '' : ' <span class="badge bg-warning-subtle text-warning-emphasis border" title="Matched by name - check strength; map it in Master > OPD Medicine Mapping">auto</span>') : '<span class="text-danger">No pharmacy generic mapped</span>'}</div></td>
                        <td class="text-end" style="width:230px">${given ? '<span class="text-success">on the bill</span>'
                            : `<div class="d-flex gap-1 justify-content-end">${m.GenericId && m.BrandsInStock ? `<button type="button" class="btn btn-sm btn-outline-primary py-0" data-rxadd="${k}">Add</button>` : ''}
                               <select class="form-select form-select-sm" data-rxwhy="${k}" style="max-width:170px"><option value="">Not given because…</option>${NOT_GIVEN.map(w => `<option ${m.reason === w ? 'selected' : ''}>${esc(w)}</option>`).join('')}</select></div>`}</td></tr>`;
                }).join('')}</tbody></table></div>`;
            $('rxDrop').onclick = () => { rx = null; renderRx(); customerExtras(); };
            box.querySelectorAll('[data-rxwhy]').forEach(sel => sel.onchange = () => { rx.lines[sel.dataset.rxwhy].reason = sel.value; });
            box.querySelectorAll('[data-rxadd]').forEach(b => b.onclick = async () => {
                const m = rx.lines[b.dataset.rxadd];
                const subs = (await getJson(cfg.urls.items + '?genericId=' + m.GenericId + storeQ())).filter(x => x.stock > 0);
                if (subs.length) await addItem(subs.find(x => x.itemId === m.SuggestedItemId) || subs[0]);
            });
        }

        // ── clinical safety checks: re-run whenever the items change ───────────────────────────────────
        let clinTimer, clinKey = '';
        function clinicalSoon() {
            if (!cfg.settings.ClinicalChecksEnabled) return;
            clearTimeout(clinTimer);
            clinTimer = setTimeout(async () => {
                const ids = [...new Set(lines.map(l => l.item.itemId))].sort(), m = member() || {};
                const key = ids.join(',') + JSON.stringify(m);
                if (key === clinKey) return;
                clinKey = key;
                alerts = ids.length ? await postJson(cfg.urls.clinical, { PatientId: m.patientId || null, CustomerId: m.customerId || null, ItemIds: ids }) : [];
                if (!Array.isArray(alerts)) alerts = [];
                renderAlerts();
            }, 400);
        }
        function renderAlerts() {
            const box = $('clinBox');
            box.classList.toggle('d-none', !alerts.length);
            const cls = s => s === 'MAJOR' ? 'danger' : s === 'MODERATE' ? 'warning' : 'secondary';
            const ico = k => k === 'ALLERGY' ? 'bi-exclamation-octagon-fill' : k === 'DUPLICATE' ? 'bi-files' : 'bi-arrow-left-right';
            box.innerHTML = alerts.map(a => `<div class="alert alert-${cls(a.severity)} py-1 px-2 small mb-1"><i class="bi ${ico(a.kind)} me-1"></i>
                <b>${esc(a.kind === 'INTERACTION' ? 'Interaction' : a.kind === 'ALLERGY' ? 'Allergy' : 'Duplicate therapy')} (${esc(a.severity.toLowerCase())})</b> - ${esc(a.title || '')}:
                ${esc(a.message)}${a.advice ? `<div class="fst-italic">${esc(a.advice)}</div>` : ''}</div>`).join('');
        }
        const priceType = () => kind === 'CUSTOMER' && customer?.type === 'STAFF' ? 'STAFF' : 'WALKIN';

        // generic dropdown picker (keyboard)
        function picker(input, list, fetcher, row, pick, min = 2, head = '', rowClass = () => '') {
            let res = [], act = -1, t;
            const draw = () => {
                list.innerHTML = res.length ? head + res.map((r, k) => `<a href="#" class="dr ${k === act ? 'active' : ''} ${rowClass(r)}" data-k="${k}">${row(r)}</a>`).join('')
                    : '<div class="empty"><i class="bi bi-search me-1"></i>Nothing found.</div>';
                list.classList.remove('d-none');
                list.querySelector('.dr.active')?.scrollIntoView({ block: 'nearest' });
            };
            input.addEventListener('input', () => { clearTimeout(t); const q = input.value.trim(); if (q.length < min) { list.classList.add('d-none'); return; }
                t = setTimeout(async () => { res = await fetcher(q); act = res.length ? 0 : -1; draw(); }, 220); });
            input.addEventListener('keydown', e => {
                if (list.classList.contains('d-none')) return;
                if (e.key === 'ArrowDown') { e.preventDefault(); act = Math.min(res.length - 1, act + 1); draw(); }
                else if (e.key === 'ArrowUp') { e.preventDefault(); act = Math.max(0, act - 1); draw(); }
                else if (e.key === 'Enter') { e.preventDefault(); if (res[act]) { list.classList.add('d-none'); pick(res[act]); } }
                else if (e.key === 'Escape') list.classList.add('d-none');
            });
            list.addEventListener('mousedown', e => { const a = e.target.closest('[data-k]'); if (a) { e.preventDefault(); list.classList.add('d-none'); pick(res[a.dataset.k]); } });
            input.addEventListener('blur', () => setTimeout(() => list.classList.add('d-none'), 150));
        }

        // doctor
        picker($('docName'), $('docList'), q => getJson(cfg.urls.doctors + '?q=' + encodeURIComponent(q)), r => `<span class="nm">${esc(r.name)}</span><span class="sub">${esc(r.regNo || '')}</span>`,
            r => { $('docName').value = r.name; $('docReg').value = r.regNo || ''; doctorId = r.id; $('rxNo').focus(); });
        $('docName').addEventListener('input', () => { doctorId = null; rxCheck(); });
        $('rxNo').addEventListener('input', rxCheck);

        function rxCheck() {
            const rx = lines.some(l => l.item.rxRequired), reg = lines.some(l => l.item.registerRequired);
            $('docName').classList.toggle('rx-need', rx && !$('docName').value.trim());
            $('rxNo').classList.toggle('rx-need', rx && !$('rxNo').value.trim());
            $('docLbl').classList.toggle('req', rx); $('rxLbl').classList.toggle('req', rx);
            if (kind === 'WALKIN' && $('wName')) { $('wName').classList.toggle('rx-need', reg && !$('wName').value.trim()); $('wAddress').classList.toggle('rx-need', reg && !$('wAddress').value.trim()); }
            const w = lines.filter(l => l.item.labelWarning || l.item.isHighAlert || l.item.isLasa);
            $('rxWarn').classList.toggle('d-none', !rx && !w.length);
            $('rxWarn').innerHTML = (rx ? `<div class="alert alert-danger py-1 px-2 small"><i class="bi bi-prescription2 me-1"></i>An item needing a prescription is on the bill: doctor and prescription no. are required${reg ? '; Schedule H1 / X: patient name and address go to the register' : ''}.</div>` : '')
                + w.filter(l => l.item.isHighAlert || l.item.isLasa).map(l => `<div class="alert alert-warning py-1 px-2 small"><i class="bi bi-exclamation-octagon me-1"></i>${esc(l.item.itemName)}: ${l.item.isHighAlert ? 'HIGH-ALERT medicine - double check dose. ' : ''}${l.item.isLasa ? 'Look-alike / sound-alike - confirm the pack.' : ''}</div>`).join('');
        }

        // ── items ────────────────────────────────────────────────────────────────────────────────────
        const sch = c => `<span class="badge sch sch-${esc(c)}">${esc(c)}</span>`;
        const ITEM_HEAD = '<div class="dh"><span>Item</span><span>Generic · maker</span><span>Pack</span><span class="text-end">Stock</span><span class="text-end">MRP</span><span>Exp</span><span>Rack</span></div>';
        function itemRow(r) {
            const packs = r.conversionQty > 1 ? `<div class="sub">${q3(r.stock / r.conversionQty)} ${esc(r.purchaseUom)}</div>` : '';
            return `<span><div class="nm">${r.formShort ? `<span class="ph-form-tag">${esc(r.formShort)}</span>` : ''}${esc(r.itemName)} ${sch(r.scheduleCode)}
                        ${r.isColdChain ? '<i class="bi bi-snow text-info" title="cold chain"></i>' : ''}${r.isHighAlert ? ' <i class="bi bi-exclamation-octagon-fill text-danger" title="high alert"></i>' : ''}${r.isLasa ? ' <i class="bi bi-eye-fill text-warning" title="look-alike / sound-alike"></i>' : ''}</div>
                    ${r.strength ? `<div class="sub">${esc(r.strength)}</div>` : ''}</span>
                <span class="sub">${esc(r.genericName || '')}<div>${esc(r.manufacturerName || '')}</div></span>
                <span class="sub">${esc(r.packSize || (r.conversionQty > 1 ? r.conversionQty + ' ' + r.saleUom : r.saleUom))}</span>
                <span class="text-end num"><b class="${r.stock > 0 ? 'text-success' : 'text-danger'}">${r.stock > 0 ? q3(r.stock) + ' ' + esc(r.saleUom) : 'Nil'}</b>${r.stock > 0 ? packs : (r.genericId ? '<div class="sub"><u data-subs="' + r.genericId + '">substitutes</u></div>' : '')}</span>
                <span class="text-end num">${r.packMrp ? '₹' + money(r.packMrp) : '—'}</span>
                <span class="sub">${r.nearestExpiry ? mon(r.nearestExpiry) : ''}</span>
                <span class="sub">${esc(r.rackNo || '')}</span>`;
        }
        const search = $('itemSearch'), list = $('itemList');
        let lastResults = [];
        // GS1 DataMatrix (SQLScripts/2404): a scanned 2D pack code finds the item by GTIN and bills that very batch
        const gs1 = q => cfg.settings.Gs1ScanEnabled && window.PhGs1 ? PhGs1.parse(q) : null;
        search.addEventListener('keydown', async e => {
            if (e.key !== 'Enter') return;
            const g = gs1(search.value);
            if (!g) return;
            e.preventDefault(); e.stopImmediatePropagation(); list.classList.add('d-none');
            await scanned(g);
        });
        picker(search, list, async q => { const g = gs1(q); return (lastResults = await getJson(cfg.urls.items + '?q=' + encodeURIComponent(g ? g.gtin : q) + storeQ())); },
            itemRow, addItem, 2, ITEM_HEAD, r => r.stock > 0 ? '' : 'oos');

        async function scanned(g) {
            search.value = '';
            const today = new Date().toISOString().slice(0, 10);
            if (g.expiry && g.expiry < today) { Swal.fire({ icon: 'error', title: 'Expired pack', text: `Batch ${g.batch || ''} expired on ${g.expiry}. Do not sell it.` }); return; }
            const found = (await getJson(cfg.urls.items + '?q=' + encodeURIComponent(g.gtin) + storeQ()))[0];
            if (!found) { Swal.fire({ icon: 'warning', title: 'Pack not in Item Master', text: `No item has the barcode / GTIN ${g.gtin}. Add it to the item's Barcode (EAN / GTIN) in Item Master.` }); return; }
            const line = lines.find(l => l.item.itemId === found.itemId && g.batch && l.batchId && l.batches.find(b => b.batchId === l.batchId)?.batchNo?.toUpperCase() === g.batch);
            if (line) {   // same pack scanned again: one more pack (or unit)
                line.qtyIn = num(line.qtyIn) + 1; render(); toast('success', `${found.itemName}: ${line.qtyIn} ${line.mode === 'P' ? found.purchaseUom : found.saleUom}`); focusSearch(); return;
            }
            await addItem(found, g.batch);
            focusSearch();
        }
        list.addEventListener('mousedown', async e => {
            const s = e.target.closest('[data-subs]');
            if (!s) return;
            e.preventDefault(); e.stopPropagation();
            const subs = await getJson(cfg.urls.items + '?genericId=' + s.dataset.subs + storeQ());
            list.innerHTML = '<div class="sec"><i class="bi bi-arrow-left-right me-1"></i>Substitutes - same generic, in stock first</div>' + ITEM_HEAD
                + subs.map((r, k) => `<a href="#" class="dr ${r.stock > 0 ? '' : 'oos'}" data-sub="${k}">${itemRow(r)}</a>`).join('');
            list.onmousedown = ev => { const a = ev.target.closest('[data-sub]'); if (a) { ev.preventDefault(); list.classList.add('d-none'); addItem(subs[a.dataset.sub]); list.onmousedown = null; } };
        }, true);
        const focusSearch = () => { search.value = ''; search.focus(); };

        // out of stock: offer in-stock brands of the same generic (Hospital Settings > MED > Suggest Substitute Brands)
        async function outOfStock(it) {
            if (!cfg.settings.SubstituteSuggest || !it.genericId) { toast('warning', it.itemName + ' is out of stock.'); return; }
            const subs = (await getJson(cfg.urls.items + '?genericId=' + it.genericId + storeQ())).filter(r => r.stock > 0 && r.itemId !== it.itemId);
            if (!subs.length) { toast('warning', it.itemName + ' is out of stock, and no other brand of ' + (it.genericName || 'this generic') + ' is in stock.'); return; }
            const r = await Swal.fire({
                title: it.itemName + ' is out of stock', width: 640, showCancelButton: true, showConfirmButton: false, cancelButtonText: 'Close',
                html: `<div class="text-start small text-muted mb-2">Same generic: <b>${esc(it.genericName || '')}</b>${it.strength ? ' · ' + esc(it.strength) : ''}. Pick a substitute (tell the customer):</div>
                       <div class="list-group text-start">${subs.slice(0, 8).map((x, k) => `<button type="button" class="list-group-item list-group-item-action d-flex justify-content-between align-items-center" data-sub="${k}">
                         <span><b>${esc(x.itemName)}</b> <span class="small text-muted">${esc(x.strength || '')} · ${esc(x.manufacturerName || '')}</span>${x.strength && it.strength && x.strength !== it.strength ? ' <span class="badge bg-warning-subtle text-warning-emphasis">different strength</span>' : ''}</span>
                         <span class="small num">${q3(x.stock)} ${esc(x.saleUom)} · ${x.packMrp ? '₹' + money(x.packMrp) : ''}</span></button>`).join('')}</div>`,
                didOpen: el => el.querySelectorAll('[data-sub]').forEach(b => b.addEventListener('click', () => { Swal.close(); addItem(subs[b.dataset.sub]); }))
            });
            return r;
        }

        async function addItem(it, scanBatch) {
            if (it.stock <= 0) { outOfStock(it); return; }
            const existing = scanBatch ? null : lines.find(l => l.item.itemId === it.itemId && !l.batchId);
            if (existing) { render(); const q = document.querySelector(`[data-key="${existing.key}"] [data-f=qty]`); q && (q.focus(), q.select()); return; }
            const batches = await getJson(cfg.urls.batches + '?itemId=' + it.itemId + storeQ());
            if (!batches.length) { toast('warning', 'No sellable batch (expired or within ' + cfg.settings.MinShelfLifeSaleDays + ' days of expiry).'); return; }
            let batchId = null;
            if (scanBatch) {
                const b = batches.find(x => String(x.batchNo).toUpperCase() === scanBatch);
                if (b) batchId = b.batchId;
                else Swal.fire({ icon: 'warning', title: 'Batch not in sellable stock', text: `Scanned batch ${scanBatch} of ${it.itemName} is not in this counter's sellable stock (not received, blocked, or too close to expiry). Billed from the first-expiry batch - check the pack in hand.` });
            }
            const l = { key: ++seq, item: it, batches, batchId, mode: it.conversionQty > 1 && !it.allowLooseSale ? 'P' : (it.conversionQty > 1 ? 'P' : 'U'), qtyIn: 1, disc: 0, rate: 0, unitMrp: batches[0].unitMrp };
            lines.push(l);
            await price(l);
            render(); rxCheck();
            const q = document.querySelector(`[data-key="${l.key}"] [data-f=qty]`); q && (q.focus(), q.select());
            search.value = '';
        }
        async function price(l) {
            const b = l.batchId ? l.batches.find(x => x.batchId === l.batchId) : l.batches[0];
            l.unitMrp = b.unitMrp;
            l.rate = num(await getJson(`${cfg.urls.price}?itemId=${l.item.itemId}&batchId=${b.batchId}&priceType=${priceType()}`)) || b.unitMrp;
        }
        async function refreshPrices() { for (const l of lines) await price(l); render(); }
        const units = l => l.mode === 'P' ? num(l.qtyIn) * l.item.conversionQty : num(l.qtyIn);
        function calc(l) {
            const d = l.item.isDiscountAllowed ? Math.min(100, num(l.disc) + num($('billDisc').value)) : 0;
            l.amount = r2(units(l) * l.rate * (1 - d / 100));
            l.taxable = r2(l.amount * 100 / (100 + l.item.gstPercent));
            l.gst = l.amount - l.taxable; l.mrpAmt = units(l) * l.unitMrp; l.effDisc = d;
        }

        function render() {
            $('emptyLines').classList.toggle('d-none', lines.length > 0);
            $('lines').innerHTML = lines.map((l, i) => {
                calc(l);
                const it = l.item, conv = it.conversionQty;
                const stockUnits = l.batchId ? (l.batches.find(b => b.batchId === l.batchId)?.stock || 0) : l.batches.reduce((s, b) => s + b.stock, 0);
                const short = units(l) > stockUnits;
                return `<tr data-key="${l.key}" class="${short ? 'short' : ''}" title="${short ? 'More than the sellable stock (' + q3(stockUnits) + ')' : ''}">
                    <td class="sn">${i + 1}</td>
                    <td class="it"><div class="it-nm">${it.formShort ? `<span class="ph-form-tag">${esc(it.formShort)}</span>` : ''}${esc(it.itemName)} ${sch(it.scheduleCode)}
                        ${it.isColdChain ? '<i class="bi bi-snow text-info" title="cold chain"></i>' : ''}${it.isHighAlert ? ' <i class="bi bi-exclamation-octagon-fill text-danger" title="high alert"></i>' : ''}${it.isLasa ? ' <i class="bi bi-eye-fill text-warning" title="LASA"></i>' : ''}</div>
                        <div class="it-sub">${esc(it.genericName || '')}${it.rackNo ? ' · rack ' + esc(it.rackNo) : ''} · stock <span class="${short ? 'text-danger fw-bold' : ''}">${q3(stockUnits)}</span>
                        ${cfg.settings.RefillReminderEnabled ? ` · <label class="mb-0" title="Days this medicine lasts - a WhatsApp refill reminder is sent before it runs out">lasts <input class="form-control form-control-sm d-inline-block num py-0 px-1" data-f="days" type="number" min="0" max="365" value="${l.days || ''}" style="width:52px;height:22px"> days</label>` : ''}</div></td>
                    <td><select class="form-select" data-f="batch" style="min-width:160px"><option value="">Auto (first expiry)</option>
                        ${l.batches.map(b => `<option value="${b.batchId}" ${l.batchId === b.batchId ? 'selected' : ''}>${esc(b.batchNo)} · ${mon(b.expiryDate)} · ₹${money(b.packMrp)} · ${q3(b.stock)}</option>`).join('')}</select></td>
                    <td><div class="qty"><input class="form-control num" data-f="qty" type="number" min="0" step="1" value="${l.qtyIn}">
                        ${conv > 1 ? `<select class="form-select" data-f="mode" ${it.allowLooseSale ? '' : 'disabled'}><option value="P" ${l.mode === 'P' ? 'selected' : ''}>${esc(it.purchaseUom)}</option><option value="U" ${l.mode === 'U' ? 'selected' : ''}>${esc(it.saleUom)}</option></select>`
                                   : `<span class="unit">${esc(it.saleUom)}</span>`}</div>
                        ${conv > 1 ? `<div class="it-sub text-end">${q3(units(l))} ${esc(it.saleUom)}</div>` : ''}</td>
                    <td class="text-end num">${money(l.unitMrp * (l.mode === 'P' ? conv : 1))}</td>
                    <td class="text-end num">${money(l.rate * (l.mode === 'P' ? conv : 1))}${l.rate < l.unitMrp ? '<span class="tag rule" title="price rule">rule</span>' : ''}</td>
                    <td class="text-end"><input class="form-control text-end num ms-auto" data-f="disc" type="number" min="0" max="100" step="0.5" value="${l.disc}" style="width:66px" ${it.isDiscountAllowed ? '' : 'disabled title="No discount on this item"'}></td>
                    <td class="text-end num text-muted">${num(it.gstPercent).toFixed(0)}</td>
                    <td class="text-end num amt" data-c="amt">${money(l.amount)}</td>
                    <td><button type="button" class="del" data-del title="Remove (Ctrl+Del)"><i class="bi bi-x-circle-fill"></i></button></td></tr>`;
            }).join('');
            totals();
            if (rx) renderRx();
            clinicalSoon();
        }
        $('lines').addEventListener('input', e => {
            const tr = e.target.closest('tr'); if (!tr) return;
            const l = lines.find(x => x.key == tr.dataset.key), f = e.target.dataset.f;
            if (f === 'days') { l.days = Math.max(0, Math.min(365, parseInt(e.target.value) || 0)); return; }
            if (f === 'qty') l.qtyIn = e.target.value; else if (f === 'disc') l.disc = e.target.value; else return;
            calc(l); tr.querySelector('[data-c=amt]').innerHTML = money(l.amount); totals();
        });
        $('lines').addEventListener('change', async e => {
            const tr = e.target.closest('tr'); if (!tr) return;
            const l = lines.find(x => x.key == tr.dataset.key), f = e.target.dataset.f;
            if (f === 'batch') { l.batchId = e.target.value ? +e.target.value : null; await price(l); }
            if (f === 'mode') { const u = units(l); l.mode = e.target.value; l.qtyIn = l.mode === 'P' ? Math.max(1, Math.round(u / l.item.conversionQty)) : u; }
            if (f === 'qty' || f === 'batch' || f === 'mode' || f === 'disc') render();   // (days: kept on the line, no re-render)
        });
        $('lines').addEventListener('click', e => { if (e.target.closest('[data-del]')) { const tr = e.target.closest('tr'); lines = lines.filter(x => x.key != tr.dataset.key); render(); rxCheck(); focusSearch(); } });
        $('lines').addEventListener('keydown', e => { if (e.key === 'Enter' && e.target.dataset.f) { e.preventDefault(); render(); focusSearch(); } });
        $('billDisc').addEventListener('input', () => {
            if (num($('billDisc').value) - loyPct() > cfg.settings.MaxManualDiscountPercent && !cfg.canDiscount) toast('warning', `Above ${cfg.settings.MaxManualDiscountPercent}%: needs a user with the Discount permission.`);
            render();
        });

        // ── totals and payment ───────────────────────────────────────────────────────────────────────
        let net = 0;
        function totals() {
            let mrp = 0, amt = 0, tax = 0, gst = 0;
            lines.forEach(l => { calc(l); mrp += l.mrpAmt; amt += l.amount; tax += l.taxable; gst += l.gst; });
            // loyalty points used: a discount before GST, at most the branch's % of the bill (the server checks again)
            let red = redeemValue();
            if (loyalty && red > 0) {
                const cap = r2(amt * num(loyalty.MaxRedeemPercent) / 100);
                if (red > cap) { red = cap; $('loyRedeem').classList.add('is-invalid'); $('loyRedeem').title = `Up to ₹${money(cap)} (${num(loyalty.MaxRedeemPercent)}% of the bill)`; }
                else { $('loyRedeem').classList.remove('is-invalid'); $('loyRedeem').title = ''; }
                if (amt > 0) { const f = (amt - red) / amt; tax = r2(tax * f); gst = r2(gst * f); }
                amt = r2(amt - red);
            }
            net = cfg.settings.RoundOffBill ? Math.round(amt) : r2(amt);
            $('tNet').textContent = '₹ ' + money(net); $('tMrp').textContent = money(mrp); $('tDisc').textContent = money(mrp - amt);
            $('tTax').textContent = money(tax); $('tGst').textContent = money(gst); $('tRound').textContent = money(net - amt);
            $('tItems').textContent = `${lines.length} item${lines.length === 1 ? '' : 's'}`; $('tSave').textContent = mrp - net > 0.5 ? `You save ₹${money(mrp - net)}` : '';
            $('fItems').textContent = lines.length; $('fUnits').textContent = q3(lines.reduce((s, l) => s + units(l), 0));
            $('fMrp').textContent = money(mrp); $('fSave').textContent = money(Math.max(0, mrp - net));
            payTotals();
        }
        function renderPays() {
            $('pays').innerHTML = pays.map((p, i) => `<div class="pos-pay ${p.method === 'CASH' ? '' : 'ref'}" data-i="${i}"><span class="m">${esc(p.method === 'CASH' ? 'Cash' : p.method === 'CHEQUE' ? 'Cheque' : p.method)}</span>
                <input class="form-control num" data-p="amount" type="number" min="0" step="0.01" value="${p.amount}" placeholder="${p.method === 'CASH' ? 'Received' : 'Amount'}">
                ${p.method === 'CASH' ? '' : `<input class="form-control" data-p="ref" value="${esc(p.ref || '')}" placeholder="${p.method === 'CARD' ? 'Last 4 / approval' : p.method === 'UPI' ? 'UPI ref' : 'Ref no.'}" maxlength="50">`}
                <button class="x" type="button" data-pdel title="Remove"><i class="bi bi-x-circle-fill"></i></button></div>`).join('');
            document.querySelectorAll('#payBtns [data-m]').forEach(b => b.classList.toggle('on', pays.some(p => p.method === b.dataset.m)));
            payTotals();
        }
        function payTotals() {
            const cash = pays.filter(p => p.method === 'CASH').reduce((s, p) => s + num(p.amount), 0), other = pays.filter(p => p.method !== 'CASH').reduce((s, p) => s + num(p.amount), 0);
            const paid = Math.min(net, cash + other), change = cash > 0 ? Math.max(0, cash + other - net) : 0, due = r2(net - paid);
            $('tPaid').textContent = money(paid); $('tDue').textContent = money(due);
            $('dueLbl').textContent = due > 0 && kind === 'CUSTOMER' && customer?.credit ? 'On credit' : 'Balance';
            $('tDue').className = due > 0 ? 'text-danger' : '';
            $('changeRow').classList.toggle('d-none', change <= 0); $('tChange').textContent = '₹ ' + money(change);
        }
        function addPay(m) {
            if (cfg.settings.SplitPaymentEnabled === false && pays.length && !pays.some(x => x.method === m)) {
                pays = []; renderPays();   // split payment is off for this branch: the new method replaces the old one
            }
            let p = pays.find(x => x.method === m);
            if (!p) { const paid = pays.reduce((s, x) => s + num(x.amount), 0); p = { method: m, amount: Math.max(0, r2(net - paid)) || '', ref: '' }; pays.push(p); renderPays(); }
            const box = $('pays').querySelector(`[data-i="${pays.indexOf(p)}"] [data-p=${m === 'CASH' ? 'amount' : 'ref'}]`); box && (box.focus(), box.select && box.select());
        }
        document.querySelectorAll('#payBtns [data-m]').forEach(b => b.addEventListener('click', () => addPay(b.dataset.m)));
        $('pays').addEventListener('input', e => { const g = e.target.closest('[data-i]'); if (!g) return; pays[g.dataset.i][e.target.dataset.p] = e.target.value; payTotals(); });
        $('pays').addEventListener('click', e => { if (e.target.closest('[data-pdel]')) { pays.splice(+e.target.closest('[data-i]').dataset.i, 1); renderPays(); } });
        $('pays').addEventListener('keydown', e => { if (e.key === 'Enter') { e.preventDefault(); save(); } });
        // quick cash: Exact = what is left after card / UPI; a note adds to the cash received
        $('quickCash').addEventListener('click', e => {
            const q = e.target.closest('[data-q]')?.dataset.q; if (!q) return;
            let cash = pays.find(p => p.method === 'CASH');
            if (!cash) { cash = { method: 'CASH', amount: 0, ref: '' }; pays.push(cash); }
            const other = pays.filter(p => p.method !== 'CASH').reduce((s, p) => s + num(p.amount), 0);
            cash.amount = q === 'exact' ? Math.max(0, r2(net - other)) : r2(num(cash.amount) + num(q));
            renderPays();
        });

        // ── save / hold / recall ─────────────────────────────────────────────────────────────────────
        function request() {
            const w = id => $(id) ? $(id).value.trim() || null : null;
            return {
                StoreId: storeSel && storeSel.value ? +storeSel.value : null, HoldId: holdId, CustomerKind: kind, PatientId: kind === 'PATIENT' ? patient?.id : null, CustomerId: kind === 'CUSTOMER' ? customer?.id : null,
                CustomerName: kind === 'WALKIN' ? w('wName') : null, Mobile: kind === 'WALKIN' ? w('wMobile') : null, Address: kind === 'WALKIN' ? w('wAddress') : null,
                DoctorId: doctorId, DoctorName: w('docName'), DoctorRegNo: w('docReg'), RxNo: w('rxNo'), RxDate: w('rxDate'), BillDiscPercent: num($('billDisc').value),
                Lines: lines.map(l => ({ ItemId: l.item.itemId, BatchId: l.batchId, Qty: units(l), DiscPercent: num(l.disc), DaysSupply: l.days || null })),
                Payments: pays.filter(p => num(p.amount) > 0).map(p => ({ Method: p.method, Amount: num(p.amount), Ref: p.ref || null })),
                ConsultationId: rx ? rx.id : null,
                RxLines: rx ? rx.lines.map(m => ({ Seq: m.Seq, Status: m.status, ItemId: m.itemId, Reason: m.reason || null })) : [],
                RedeemPoints: loyalty && loyalty.LoyaltyType !== 'DISCOUNT' ? Math.max(0, Math.floor(num($('loyRedeem').value))) : 0,
                RedeemOtp: loyalty && loyalty.RedeemOtp ? ($('loyOtp').value.trim() || null) : null,
                CreditRefNo: $('creditRefBox').classList.contains('d-none') ? null : ($('creditRef').value.trim() || null),
                AlertReason: null
            };
        }
        let busy = false;
        async function save() {
            if (busy || !$('btnSave') || $('btnSave').disabled) return;
            if (!lines.length) { toast('info', 'Add an item first.'); focusSearch(); return; }
            if (kind !== 'WALKIN' && !(kind === 'PATIENT' ? patient : customer)) { toast('info', kind === 'PATIENT' ? 'Pick the patient.' : 'Pick the credit customer.'); return; }
            if (!pays.length && net > 0 && !(kind === 'CUSTOMER' && customer?.credit)) { addPay('CASH'); return; }
            if (rx) {
                renderRx();
                const missing = rx.lines.find(m => m.status !== 'DISPENSED' && !m.reason);
                if (missing) { Swal.fire({ icon: 'warning', title: 'Prescription not complete', text: `${missing.MedicationName} is prescribed but not on the bill: add it, or pick why it is not given.` }); return; }
            }
            const body = request();
            if (cfg.settings.ClinicalChecksEnabled && lines.length) {
                clinKey = ''; clearTimeout(clinTimer);
                const ids = [...new Set(lines.map(l => l.item.itemId))], m = member() || {};
                alerts = await postJson(cfg.urls.clinical, { PatientId: m.patientId || null, CustomerId: m.customerId || null, ItemIds: ids });
                if (!Array.isArray(alerts)) alerts = [];
                renderAlerts();
                if (alerts.length) {
                    const major = alerts.find(a => a.severity === 'MAJOR' && a.kind === 'INTERACTION');
                    if (major && cfg.settings.MajorInteractionBlock) { Swal.fire({ icon: 'error', title: 'Sale blocked', text: `Major interaction - ${major.title}: ${major.message}` }); return; }
                    const r = await Swal.fire({
                        icon: alerts.some(a => a.severity === 'MAJOR') ? 'error' : 'warning', title: `${alerts.length} clinical alert(s)`, width: 640,
                        html: `<div class="text-start small">${alerts.map(a => `<div class="mb-1"><b>${esc(a.title || '')}</b>: ${esc(a.message)}</div>`).join('')}</div>`,
                        input: 'text', inputLabel: 'Reason to go ahead (recorded with the bill)', inputPlaceholder: 'e.g. Prescriber confirmed, counselled patient',
                        showCancelButton: true, confirmButtonText: 'Dispense anyway', inputValidator: v => !v || !v.trim() ? 'A reason is required.' : null
                    });
                    if (!r.isConfirmed) return;
                    body.AlertReason = r.value.trim();
                }
            }
            busy = true; $('btnSave').disabled = true;
            const res = await postJson(cfg.urls.save, body);
            busy = false; $('btnSave').disabled = false;
            if (!res.success) { Swal.fire({ icon: 'error', title: 'Not saved', text: res.error || 'Please check the bill.' }); return; }
            const fmt = $('printFmt').value;
            if (fmt) window.open(`${cfg.urls.print}?id=${res.saleId}&format=${fmt}`, '_blank', 'width=900,height=900');
            showLast(res, fmt);
            Swal.fire({ icon: 'success', title: `Bill ${res.saleNo}`, html: `Net ₹${money(res.netAmount)}${res.change > 0 ? `<div class="fs-4 fw-bold text-success mt-2">Return change ₹${money(res.change)}</div>` : ''}${res.balanceDue > 0 ? `<div class="text-danger mt-1">On credit ₹${money(res.balanceDue)}</div>` : ''}${res.pointsRedeemed > 0 ? `<div class="small mt-1">${q3(res.pointsRedeemed)} points used</div>` : ''}${res.loyaltyDiscount > 0 ? `<div class="small text-success mt-1">Member discount ₹${money(res.loyaltyDiscount)}</div>` : ''}${res.pointsEarned > 0 ? `<div class="small text-success mt-1"><i class="bi bi-wallet2 me-1"></i>${q3(res.pointsEarned)} points credited to the wallet</div>` : ''}`,
                confirmButtonText: 'New bill', showDenyButton: true, denyButtonText: 'Open bill' })
                .then(r => { if (r.isDenied) location.href = `${cfg.urls.bill}?id=${res.saleId}`; });
            reset();
        }
        function showLast(res, fmt) {
            const box = $('lastBill'); if (!box) return;
            box.innerHTML = `<i class="bi bi-clock-history me-1"></i>Last bill <b>${esc(res.saleNo)}</b> · ₹${money(res.netAmount)}${res.change > 0 ? ` · change ₹${money(res.change)}` : ''}
                <span class="float-end"><a href="${cfg.urls.print}?id=${res.saleId}&format=${encodeURIComponent(fmt || '80MM')}" target="_blank"><i class="bi bi-printer me-1"></i>Reprint</a>
                · <a href="${cfg.urls.bill}?id=${res.saleId}">Open</a></span>`;
            box.classList.remove('d-none');
        }
        function setMode() {
            const m = $('billMode'); if (!m) return;
            m.className = 'pos-pill ' + (holdId ? 'held' : 'mode');
            m.innerHTML = holdId ? '<i class="bi bi-pause-circle"></i>Recalled held bill' : '<i class="bi bi-plus-circle"></i>New bill';
        }
        async function hold() {
            if (!lines.length) { toast('info', 'Nothing to hold.'); return; }
            const r = await Swal.fire({ title: 'Hold this bill', input: 'text', inputLabel: 'Label (customer / token)', inputValue: $('wName')?.value || patient?.name || customer?.name || '', showCancelButton: true });
            if (!r.isConfirmed) return;
            const body = request(); body.HoldLabel = r.value || null;
            const res = await postJson(cfg.urls.hold, body);
            if (!res.success) { Swal.fire({ icon: 'error', title: 'Not held', text: res.error }); return; }
            toast('success', 'Bill held.'); reset(); heldCount();
        }
        async function heldCount() { const h = await getJson(cfg.urls.held); $('heldCount') && ($('heldCount').textContent = h.length || ''); return h; }
        async function showHeld() {
            const h = await heldCount();
            $('heldRows').innerHTML = h.length ? h.map(x => `<tr><td>${new Date(x.saleDate).toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' })}</td><td>${esc(x.holdLabel || x.customerName || '—')}</td>
                <td class="text-end">${x.lines}</td><td class="text-end">${money(x.netAmount)}</td><td class="small">${esc(x.createdByName || '')}</td>
                <td class="text-end"><button class="btn btn-sm btn-primary" data-recall="${x.saleId}">Recall</button> <button class="btn btn-sm btn-outline-danger" data-discard="${x.saleId}"><i class="bi bi-trash"></i></button></td></tr>`).join('')
                : '<tr><td colspan="6" class="text-center text-muted py-4">No held bills.</td></tr>';
            bootstrap.Modal.getOrCreateInstance($('heldModal')).show();
        }
        $('heldRows').addEventListener('click', async e => {
            const rc = e.target.closest('[data-recall]'), dc = e.target.closest('[data-discard]');
            if (rc) { bootstrap.Modal.getInstance($('heldModal')).hide(); await recall(+rc.dataset.recall); }
            if (dc && (await Swal.fire({ title: 'Discard this held bill?', icon: 'warning', showCancelButton: true })).isConfirmed) {
                const fd = new FormData(); fd.append('id', dc.dataset.discard); fd.append('__RequestVerificationToken', token());
                await fetch(cfg.urls.discard, { method: 'POST', body: fd }); showHeld();
            }
        });
        async function recall(id) {
            if (lines.length && !(await Swal.fire({ title: 'Replace the current bill?', icon: 'question', showCancelButton: true })).isConfirmed) return;
            const d = await getJson(cfg.urls.recall + '?id=' + id);
            if (!d || !d.bill) { toast('error', 'Held bill not found.'); return; }
            reset(); holdId = id;
            const b = d.bill;
            kind = b.customerKind; document.querySelector(`input[name=ck][value=${kind}]`).checked = true;
            if (kind === 'PATIENT') patient = { id: b.patientId, uhid: b.patientCode, name: b.customerName, mobile: b.mobile };
            if (kind === 'CUSTOMER') { const c = await getJson(cfg.urls.customers + '?q=' + encodeURIComponent(b.mobile || b.customerName)); customer = c.find(x => x.id === b.customerId) || null; }
            renderCustomer();
            if (kind === 'WALKIN') { $('wName').value = b.customerName || ''; $('wMobile').value = b.mobile || ''; $('wAddress').value = b.address || ''; }
            $('docName').value = b.doctorName || ''; $('docReg').value = b.doctorRegNo || ''; $('rxNo').value = b.rxNo || ''; doctorId = b.doctorId; $('billDisc').value = b.billDiscPercent || 0;
            const qty = {};
            b.lines.forEach(l => qty[l.itemId] = (qty[l.itemId] || 0) + l.qty);
            for (const [itemId, q] of Object.entries(qty)) {
                const it = d.items.find(x => x.itemId == itemId); if (!it) continue;
                const batches = await getJson(cfg.urls.batches + '?itemId=' + itemId + storeQ());
                if (!batches.length) { toast('warning', it.itemName + ': no sellable stock now.'); continue; }
                const l = { key: ++seq, item: it, batches, batchId: null, mode: 'U', qtyIn: q, disc: b.lines.find(x => x.itemId == itemId).discPercent - (b.billDiscPercent || 0), rate: 0 };
                if (it.conversionQty > 1 && q % it.conversionQty === 0) { l.mode = 'P'; l.qtyIn = q / it.conversionQty; }
                l.disc = Math.max(0, l.disc); await price(l); lines.push(l);
            }
            render(); rxCheck(); setMode(); toast('success', 'Held bill recalled.'); focusSearch();
        }
        function reset() {
            lines = []; pays = []; patient = null; customer = null; doctorId = null; holdId = null;
            rx = null; alerts = []; loyalty = null; extrasFor = ''; loyFilled = null; clinKey = ''; renderRx(); renderAlerts();
            $('loyRedeem').value = 0; $('loyOtp').value = ''; $('loyOtpBox').classList.add('d-none'); $('creditRef').value = ''; $('loyRow').classList.add('d-none'); $('creditRefBox').classList.add('d-none');
            ['docName', 'docReg', 'rxNo', 'rxDate'].forEach(id => $(id).value = ''); $('billDisc').value = 0;
            renderCustomer(); render(); renderPays(); setMode(); focusSearch();
        }
        $('btnSave') && $('btnSave').addEventListener('click', save);
        $('btnHold') && $('btnHold').addEventListener('click', hold);
        $('btnHeld') && $('btnHeld').addEventListener('click', showHeld);
        $('btnClear').addEventListener('click', async () => { if (!lines.length || (await Swal.fire({ title: 'Clear this bill?', icon: 'warning', showCancelButton: true })).isConfirmed) reset(); });
        let lastEsc = 0;
        document.addEventListener('keydown', e => {
            const k = e.key;
            if (k === 'F2') { e.preventDefault(); focusSearch(); }
            else if (k === 'F4') { e.preventDefault(); (kind === 'WALKIN' ? $('wMobile') : $('custSearch') || $('custChange'))?.focus(); }
            else if (k === 'F6') { e.preventDefault(); addPay(pays[0]?.method || 'CASH'); }
            else if (k === 'F7') { e.preventDefault(); $('btnHeld') && showHeld(); }
            else if (k === 'F8') { e.preventDefault(); $('btnHold') && hold(); }
            else if (k === 'F10') { e.preventDefault(); save(); }
            else if (k === 'Delete' && e.ctrlKey) {
                const tr = document.activeElement?.closest('#lines tr'); if (!tr) return;
                e.preventDefault(); lines = lines.filter(x => x.key != tr.dataset.key); render(); rxCheck(); focusSearch();
            }
            else if (k === 'Escape' && !document.querySelector('.modal.show, .swal2-container')) { if (Date.now() - lastEsc < 600 && lines.length) $('btnClear').click(); lastEsc = Date.now(); }
        });

        $('btnFull')?.addEventListener('click', () => document.fullscreenElement ? document.exitFullscreen() : document.documentElement.requestFullscreen?.().catch(() => {}));
        const tick = () => { const c = $('posClock'); if (c) c.textContent = new Date().toLocaleString('en-GB', { day: '2-digit', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit', hour12: true }); };
        tick(); setInterval(tick, 30000);

        renderCustomer(); render(); renderPays(); setMode(); heldCount();
        if (cfg.recall) recall(cfg.recall); else setTimeout(focusSearch, 100);
    };
})();
