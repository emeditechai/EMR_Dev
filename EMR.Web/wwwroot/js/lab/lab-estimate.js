/* LAB > B2C Bill Estimate (SQLScripts/2451). The screen only picks items and the discount asked for; every rate, discount,
   GST and total comes from the server (LabEstimate/Calc -> usp_LabEstimate_Compute), and Generate works it out again. */
(function () {
    'use strict';
    const P = window.EsPage, $ = id => document.getElementById(id), E = Ipd.esc, M = Ipd.money;
    const KIND = { T: 'Test', R: 'Profile', P: 'Package', M: 'Charge' };
    const iso = d => new Date(d.getTime() - d.getTimezoneOffset() * 60000).toISOString().slice(0, 10);
    let catalog = [], misc = [], items = [], calc = null, deptRows = {}, patientId = null, timer = null, seq = 0, current = null, hi = -1;

    // ── catalog (branch B2C rate list, filtered by gender / age as B2C Booking) ─────────────────────────────────
    async function loadCatalog() {
        $('eTestInfo').textContent = 'Loading rate list…';
        try {
            const q = new URLSearchParams({ gender: $('eGender').value, ageInYears: $('eAge').value });
            catalog = (await Ipd.get(P.base + 'Tests?' + q) || []).map(t => ({
                kind: t.isPackage ? 'P' : 'T', type: t.isPackage ? 'P' : t.isProfileTest ? 'R' : 'T', id: t.investigationId,
                code: t.testCode || '', name: t.testName || '', rate: Number(t.mrp ?? t.MRP) || 0, disc: !!t.isDiscountAllowed, sample: t.sampleType || '', tat: t.tatHours ?? t.TATHours, out: !!t.isOutsourced }))
                .filter(c => c.id > 0 && c.name);   // web JSON is camelCase (anonymous objects from LabEstimateController)
            $('eTestInfo').textContent = `${catalog.length} items on the B2C rate list` + ($('eGender').value || $('eAge').value ? ' (for this gender / age)' : '');
        } catch (e) { $('eTestInfo').textContent = e.message; }
    }
    const key = x => x.kind + x.id;

    function showList() {
        const q = $('eTestQ').value.trim().toLowerCase(), k = $('eKind').value;
        if (!q && !k) { $('eTestList').classList.add('d-none'); return; }
        const added = new Set(items.map(key));
        const list = catalog.filter(c => (!k || c.type === k) && (!q || c.name.toLowerCase().includes(q) || c.code.toLowerCase().includes(q))).slice(0, 60);
        hi = list.findIndex(c => !added.has(key(c)));
        $('eTestList').innerHTML = list.length ? list.map((c, i) => `<div class="it${added.has(key(c)) ? ' added' : ''}${i === hi ? ' on' : ''}" data-k="${key(c)}">
            <span class="es-pill ${c.type}">${KIND[c.type]}</span><span class="flex-fill"><b>${E(c.name)}</b> <small class="text-muted">${E(c.code)}${c.sample ? ' · ' + E(c.sample) : ''}${c.out ? ' · outsourced' : ''}</small></span>
            ${c.disc ? '' : '<small class="text-warning-emphasis" title="The rate card allows no discount">no disc.</small>'}<b class="text-nowrap">${M(c.rate)}</b></div>`).join('')
            : '<div class="it text-muted">No match on the B2C rate list.</div>';
        $('eTestList').classList.remove('d-none');
    }
    // the tests inside a profile / package (nested profiles included), cached per item
    const incCache = {};
    async function includesOf(c) {
        if (c.type === 'T') return [];
        const k = key(c);
        if (!incCache[k]) incCache[k] = (await Ipd.get(P.base + 'Includes?' + new URLSearchParams({ kind: c.kind, id: c.id })) || []).map(t => ({ id: t.TestId, name: t.TestName }));
        return incCache[k];
    }
    const warn = (title, text) => Swal.fire({ icon: 'warning', title, text, confirmButtonColor: '#0d6efd' });
    const ask = (title, text, yes) => Swal.fire({ icon: 'question', title, text, showCancelButton: true, confirmButtonColor: '#0d6efd', cancelButtonColor: '#6c757d', confirmButtonText: yes, cancelButtonText: 'Cancel' }).then(r => r.isConfirmed);

    // the same checks as B2C Booking when a test is added (the server refuses an overlap too)
    async function addItem(c, qty) {
        $('eTestQ').value = ''; $('eTestList').classList.add('d-none');
        if (!(c.rate > 0)) return warn('Price not set', `${c.name} has a price of ₹0.00 and cannot be added. Set its rate in the rate card first.`);
        if (items.some(x => key(x) === key(c))) return warn('Already Added', `${c.name} is already added to the estimate.`);
        let inc;
        try { inc = await includesOf(c); } catch (e) { return Ipd.error(e.message); }
        const panels = items.filter(x => x.type === 'R' || x.type === 'P');
        for (const x of panels) if (!x.inc) { try { x.inc = await includesOf(x); } catch { x.inc = []; } }
        // 1. a test or profile already inside an added profile / package
        if (c.type !== 'P') {
            const parent = panels.find(x => x.inc.some(t => t.id === c.id));
            if (parent) return warn('Already Included', `'${c.name}' is already included in the added ${parent.type === 'P' ? 'package' : 'profile'} '${parent.name}'. It cannot be added separately.`);
        }
        // 2. adding a profile / package: tests (and, for a package, profiles) already added that it contains
        if (c.type !== 'T') {
            const inside = items.filter(x => x.kind !== 'M' && (x.type === 'T' || (c.type === 'P' && x.type === 'R')) && inc.some(t => t.id === x.id));
            if (inside.length) {
                const what = inside.some(x => x.type === 'R') ? 'Profile Already Added' : 'Individual Test Already Added';
                const names = inside.map(x => `'${x.name}'`).join(', ');
                if (!await ask(what, `${names} ${inside.length > 1 ? 'are' : 'is'} already added, but included in the ${c.type === 'P' ? 'package' : 'profile'} '${c.name}'. Remove ${inside.length > 1 ? 'them' : 'it'} and add the complete ${c.type === 'P' ? 'package' : 'profile'} instead?`,
                    `Yes, replace with ${c.type === 'P' ? 'package' : 'profile'}`)) return;
                const drop = new Set(inside.map(key)); items = items.filter(x => !drop.has(key(x)));
            }
            // 3. panels sharing tests: a notice only, never blocks (as B2C Booking)
            const shared = [...new Set(panels.filter(x => items.includes(x)).flatMap(x => x.inc.filter(t => inc.some(i => i.id === t.id)).map(t => t.name)))];
            if (shared.length) Ipd.toast(`Note: ${shared.slice(0, 4).join(', ')}${shared.length > 4 ? '…' : ''} also in another added panel`, 'info');
        }
        items.push({ kind: c.kind, id: c.id, qty: qty || 1, name: c.name, type: c.type, seq: ++seq, inc });
        recalc();
    }
    $('eTestQ').addEventListener('input', showList);
    $('eKind').addEventListener('change', () => { showList(); $('eTestQ').focus(); });
    $('eTestQ').addEventListener('keydown', e => {
        const its = [...$('eTestList').querySelectorAll('.it[data-k]')];
        if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
            e.preventDefault(); if (!its.length) return;
            hi = (hi + (e.key === 'ArrowDown' ? 1 : -1) + its.length) % its.length;
            its.forEach((x, i) => x.classList.toggle('on', i === hi)); its[hi].scrollIntoView({ block: 'nearest' });
        } else if (e.key === 'Enter') { e.preventDefault(); if (its[hi]) addItem(catalog.find(c => key(c) === its[hi].dataset.k)); }
        else if (e.key === 'Escape') $('eTestList').classList.add('d-none');
    });
    $('eTestList').addEventListener('mousedown', e => { const it = e.target.closest('.it[data-k]'); if (it) { e.preventDefault(); addItem(catalog.find(c => key(c) === it.dataset.k)); } });
    $('eTestQ').addEventListener('blur', () => setTimeout(() => $('eTestList').classList.add('d-none'), 150));

    // misc charges
    $('eMiscAdd').addEventListener('click', () => {
        const m = misc.find(x => String(x.MiscChargeId) === $('eMisc').value), q = parseInt($('eMiscQty').value, 10);
        if (!m) return Ipd.toast('Choose a misc charge', 'info');
        if (!(q >= 1 && q <= 99)) return Ipd.toast('Quantity 1 to 99', 'info');
        const ex = items.find(x => x.kind === 'M' && x.id === m.MiscChargeId);
        if (ex) ex.qty = q; else items.push({ kind: 'M', id: m.MiscChargeId, qty: q, name: m.ChargeName, type: 'M', seq: ++seq });
        $('eMisc').value = ''; $('eMiscQty').value = 1; recalc();
    });

    $('eRows').addEventListener('click', e => {
        const b = e.target.closest('button[data-rm]'); if (!b) return;
        items = items.filter(x => key(x) !== b.dataset.rm); recalc();
    });
    $('eRows').addEventListener('change', e => {
        const q = e.target.closest('input[data-q]'); if (!q) return;
        const it = items.find(x => key(x) === q.dataset.q), v = parseInt(q.value, 10);
        if (it && v >= 1 && v <= 99) { it.qty = v; recalc(); } else q.value = it ? it.qty : 1;
    });

    // ── discount ───────────────────────────────────────────────────────────────────────────────────────────────
    const mode = () => document.querySelector('input[name="dm"]:checked')?.value || '';
    function discountBody() {
        const m = P.can.discount ? mode() : '';
        if (m === 'P' || m === 'F') return { discType: m, discValue: Number($('dValue').value) || 0 };
        if (m === 'D') return { discType: 'D', discValue: 0, deptDisc: Object.entries(deptRows).filter(([, r]) => Number(r.value) > 0).map(([k, r]) => ({ key: k, type: r.type, value: Number(r.value) })) };
        return { discType: null, discValue: 0 };
    }
    if (P.can.discount) {
        $('dMode').addEventListener('change', () => {
            const m = mode();
            $('dOverall').classList.toggle('d-none', !(m === 'P' || m === 'F')); $('dDept').classList.toggle('d-none', m !== 'D');
            $('dUnit').textContent = m === 'F' ? '₹' : '%'; $('dQuick').classList.toggle('d-none', m !== 'P');
            recalc();
        });
        $('dValue').addEventListener('input', () => recalc());
        $('dQuick').addEventListener('click', e => { const b = e.target.closest('button[data-pct]'); if (b) { $('dValue').value = b.dataset.pct; recalc(); } });
        $('dRows').addEventListener('input', e => {
            const tr = e.target.closest('tr[data-k]'); if (!tr) return;
            const r = deptRows[tr.dataset.k] || (deptRows[tr.dataset.k] = { type: 'P', value: '' });
            if (e.target.matches('select')) r.type = e.target.value; else r.value = e.target.value;
            recalc();
        });
    }

    // ── server calculation ─────────────────────────────────────────────────────────────────────────────────────
    function recalc() { clearTimeout(timer); timer = setTimeout(runCalc, 250); renderRowsPending(); }
    function renderRowsPending() { if (!items.length) { calc = null; render(); } }
    async function runCalc() {
        if (!items.some(x => x.kind !== 'M')) { calc = null; render(); if (items.length) setMsg('Add at least one test, profile or package.'); return; }
        const body = Object.assign({ items: items.map(x => ({ kind: x.kind, id: x.id, qty: x.qty })), patientId }, discountBody());
        try {
            const r = await Ipd.post(P.base + 'Calc', body);
            if (!r.success) { setMsg(r.error); return; }
            const d = r.data || {};
            if (!d.totals || d.totals.Success === false) { setMsg(d.totals ? d.totals.Error : 'Could not work out the estimate.'); markBad(true); renderMember(d); return; }
            setMsg(''); markBad(false); calc = d; render();
            renderMember(d);
        } catch (e) { setMsg(e.message || 'Could not reach the server.'); }
    }
    function setMsg(m) { const el = $('dMsg'); if (el) { el.textContent = m || ''; el.classList.toggle('d-none', !m); } else if (m) Ipd.toast(m, 'warning'); if (m && $('btnGen')) $('btnGen').disabled = true; }
    function markBad(b) { if (b && $('btnGen')) $('btnGen').disabled = true; }

    function render() {
        const lines = calc ? calc.lines || [] : [], t = calc ? calc.totals || {} : {};
        // rows in the order the screen sent them (the server numbers them the same way)
        $('eRows').innerHTML = items.length ? items.map((x, i) => {
            const l = lines[i] || {};
            return `<tr><td class="text-muted">${i + 1}</td><td><div class="fw-semibold">${E(x.name)}</div><small class="text-muted">${E(l.ItemCode || '')}</small></td>
                <td><span class="es-pill ${x.type}">${KIND[x.type]}</span>${l.DiscountAllowed === false || l.DiscountAllowed === 0 ? ' <small class="text-warning-emphasis">no disc.</small>' : ''}</td>
                <td class="small">${E(l.GroupName || '')}${l.SampleType ? '<br><span class="text-muted">' + E(l.SampleType) + '</span>' : ''}${Number(l.GstPercent) > 0 ? '<br><span class="text-muted">GST ' + Number(l.GstPercent) + '%</span>' : ''}</td>
                <td class="num">${x.kind === 'M' ? `<input type="number" min="1" max="99" class="form-control form-control-sm d-inline-block text-end" style="width:62px" value="${x.qty}" data-q="${key(x)}" aria-label="Quantity" />` : 1}</td>
                <td class="num">${l.Amount != null ? M(l.Amount) : '…'}</td><td class="num text-danger">${Number(l.DiscountAmount) + Number(l.MemberDiscount || 0) > 0 ? '−' + M(Number(l.DiscountAmount) + Number(l.MemberDiscount || 0)) : '—'}${l.MemberRule ? `<div class="small" style="color:#4338ca" title="Membership benefit"><i class="bi bi-person-vcard me-1"></i>${E(l.MemberRule)}</div>` : ''}</td>
                <td class="num fw-semibold">${l.LineTotal != null ? M(l.LineTotal) : '…'}</td>
                <td class="text-end"><button type="button" class="btn btn-sm btn-link text-danger p-0" data-rm="${key(x)}" title="Remove" aria-label="Remove"><i class="bi bi-x-circle"></i></button></td></tr>`;
        }).join('') : '<tr><td colspan="9" class="text-center text-muted py-4">Add tests to see the estimate.</td></tr>';
        $('tGross').textContent = M(t.GrossAmount); $('tElig').textContent = M(t.EligibleAmount);
        $('tDisc').textContent = '−' + M(t.DiscountAmount);
        $('tMem').textContent = '−' + M(t.MemberDiscount); $('tMemRow').classList.toggle('d-none', !(Number(t.MemberDiscount) > 0)); $('tGst').textContent = M(t.GstAmount); $('tGstRow').classList.toggle('d-none', !(Number(t.GstAmount) > 0));
        $('tNet').textContent = M(t.NetAmount);
        $('tTat').textContent = calc && Number(t.MaxTatHours) > 0 ? `${t.TestCount} test(s) · reports usually within ${Number(t.MaxTatHours)} h of collection` : '';
        if (P.can.discount) renderDept(calc ? calc.heads || [] : []);
        if ($('btnGen')) $('btnGen').disabled = !calc;
    }
    function renderDept(heads) {
        const keep = {}; heads.forEach(h => keep[h.GroupKey] = deptRows[h.GroupKey] || { type: 'P', value: '' }); deptRows = keep;
        if (document.activeElement && document.activeElement.closest('#dRows')) {   // typing: update the amounts only
            heads.forEach(h => { const c = document.querySelector(`#dRows tr[data-k="${h.GroupKey}"] .dd`); if (c) c.textContent = Number(h.DAmount) > 0 ? '−' + M(h.DAmount) : '—'; });
            return;
        }
        $('dRows').innerHTML = heads.length ? heads.map(h => { const r = deptRows[h.GroupKey], off = !(Number(h.Eligible) > 0);
            return `<tr data-k="${E(h.GroupKey)}"><td><div class="fw-semibold">${E(h.GroupName)}</div><small class="text-muted">${h.Tests} item(s)${Number(h.NonEligible) > 0 ? ' · ' + M(h.NonEligible) + ' not discountable' : ''}</small></td>
                <td class="num">${M(h.Eligible)}</td>
                <td><select class="form-select form-select-sm" ${off ? 'disabled' : ''} aria-label="Type"><option value="P"${r.type === 'P' ? ' selected' : ''}>%</option><option value="F"${r.type === 'F' ? ' selected' : ''}>₹</option></select></td>
                <td><input type="number" min="0" step="any" class="form-control form-control-sm text-end" value="${E(r.value)}" ${off ? 'disabled title="Nothing in this head allows a discount"' : ''} aria-label="Value" /></td>
                <td class="num text-danger dd">${Number(h.DAmount) > 0 ? '−' + M(h.DAmount) : '—'}</td></tr>`; }).join('')
            : '<tr><td colspan="5" class="text-muted small">Add tests first.</td></tr>';
    }

    // membership card of the registered patient (as the B2C bill): plan benefits apply by themselves; a benefit on tests
    // blocks a manual discount (the server refuses it too); points are redeemed only at billing (OTP to the card holder)
    function renderMember(d) {
        const c = d && d.membership, b = d && d.benefit, t = (d && d.totals) || {};
        const blocks = Number(t.MemberTestDiscount) > 0;
        if (P.can.discount) {
            ['dMode', 'dOverall', 'dDept'].forEach(id => $(id).classList.toggle('es-dis', blocks));
            if (blocks && mode()) { $('dmN').checked = true; $('dMode').dispatchEvent(new Event('change')); }
        }
        if (!patientId || !c) {
            $('memBox').classList.toggle('d-none', !patientId);
            $('memBox').innerHTML = patientId ? '<span class="text-muted"><i class="bi bi-person-vcard me-1"></i>No active membership card for this patient.</span>' : '';
            return;
        }
        $('memBox').classList.remove('d-none');
        $('memBox').innerHTML = `<div class="t"><i class="bi bi-person-vcard me-1"></i>Membership ${E(c.CardNo)} · ${E(b ? b.PlanName : '')}</div>
            <div>Valid till ${Ipd.date(c.ValidTo)}${c.FreeHomeCollection ? ' · free home collection' : ''}</div>
            <div>Benefit on this estimate: <b>${M(t.MemberDiscount)}</b>${blocks ? ' · <span class="text-danger">manual discount not allowed with a membership benefit</span>' : ''}</div>
            ${Number(c.PointsBalance) > 0 ? `<div class="text-muted">Points ${Number(c.PointsBalance)} (worth ${M(c.PointsValue)}) can be redeemed at billing with the card holder's OTP.</div>` : ''}`;
    }

    // ── patient ────────────────────────────────────────────────────────────────────────────────────────────────
    let pTimer;
    $('eMobile').addEventListener('input', e => {
        e.target.value = e.target.value.replace(/\D/g, '').slice(0, 10); e.target.classList.remove('is-invalid');
        if (patientId) { patientId = null; $('ePatTag').textContent = ''; recalc(); }
        clearTimeout(pTimer);
        // as B2C Booking: suggestions from 3 digits (OPD patient search), the first one ready for Enter
        if (e.target.value.length >= 3) pTimer = setTimeout(findPatients, 300); else hidePat();
    });
    $('eMobile').addEventListener('blur', () => setTimeout(hidePat, 150));
    $('eMobile').addEventListener('keydown', e => {
        const its = [...$('ePatList').querySelectorAll('.it[data-id]')];
        if ($('ePatList').classList.contains('d-none') || !its.length) return;
        if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
            e.preventDefault(); pIdx = (pIdx + (e.key === 'ArrowDown' ? 1 : -1) + its.length) % its.length;
            its.forEach((x, i) => x.classList.toggle('on', i === pIdx)); its[pIdx].scrollIntoView({ block: 'nearest' });
        } else if (e.key === 'Enter') { e.preventDefault(); if (its[pIdx]) pickPatient(its[pIdx].dataset.id); }
        else if (e.key === 'Escape' || e.key === 'Tab') hidePat();
    });
    let pIdx = -1;
    function hidePat() { $('ePatList').classList.add('d-none'); pIdx = -1; }
    async function findPatients() {
        const v = $('eMobile').value;
        try {
            const list = await Ipd.get(P.base + 'Patients?search=' + encodeURIComponent(v)) || [];
            if ($('eMobile').value !== v) return;   // typed on meanwhile
            if (!list.length) { hidePat(); return; }
            pIdx = 0;
            $('ePatList').innerHTML = list.map((p, i) => `<div class="it${i === 0 ? ' on' : ''}" data-id="${p.patientId}"><span class="flex-fill">
                <span class="fw-semibold">${E(p.fullName)}</span> <span class="badge text-bg-info text-dark font-monospace">${E(p.patientCode || '')}</span>
                ${p.relationName ? `<span class="badge text-bg-primary">${E(p.relationName)}</span>` : ''}${p.bloodGroup ? ` <span class="badge text-bg-danger">${E(p.bloodGroup)}</span>` : ''}
                <br><small class="text-muted">${E(p.phoneNumber || '')}${p.gender ? ' · ' + E(p.gender) : ''}</small></span></div>`).join('');
            $('ePatList').classList.remove('d-none');
        } catch { hidePat(); }
    }
    $('ePatList').addEventListener('mousedown', e => { const it = e.target.closest('.it[data-id]'); if (it) { e.preventDefault(); pickPatient(it.dataset.id); } });
    async function pickPatient(id) {
        hidePat();
        try {
            const p = await Ipd.get(P.base + 'Patient?id=' + id);
            patientId = p.patientId; $('eMobile').value = String(p.phoneNumber || '').replace(/\D/g, '').slice(-10);
            $('eName').value = [p.firstName, p.lastName].filter(Boolean).join(' ').trim();
            const sal = [...$('eSal').options].find(o => o.text.replace('.', '').toLowerCase() === String(p.salutation || '').replace('.', '').toLowerCase());
            $('eSal').value = sal ? sal.value : '';
            $('eGender').value = ['Male', 'Female', 'Other'].includes(p.gender) ? p.gender : ''; $('eAge').value = p.ageYears ?? ''; $('eEmail').value = p.emailId || '';
            ['eMobile', 'eName', 'eAge', 'eEmail'].forEach(x => $(x).classList.remove('is-invalid'));
            $('ePatTag').innerHTML = `<i class="bi bi-person-check text-success me-1"></i>Registered patient ${E(p.patientCode || '')}`;
            loadCatalog(); recalc();
        } catch (err) { Ipd.error(err.message); }
    }
    ['eGender', 'eAge'].forEach(id => $(id).addEventListener('change', loadCatalog));

    function validPatient() {
        const bad = [];
        if (!/^[6-9]\d{9}$/.test($('eMobile').value)) bad.push('eMobile');
        if ($('eName').value.trim().length < 2) bad.push('eName');
        const a = $('eAge').value; if (a !== '' && !(Number(a) >= 0 && Number(a) <= 130)) bad.push('eAge');
        const m = $('eEmail').value.trim(); if (m && !/^[^\s@]+@[^\s@]+\.[^\s@.]{2,}$/.test(m)) bad.push('eEmail');
        ['eMobile', 'eName', 'eAge', 'eEmail'].forEach(id => $(id).classList.toggle('is-invalid', bad.includes(id)));
        if (bad.length) $(bad[0]).focus();
        return !bad.length;
    }
    ['eName', 'eAge', 'eEmail'].forEach(id => $(id).addEventListener('input', () => $(id).classList.remove('is-invalid')));

    // ── generate ───────────────────────────────────────────────────────────────────────────────────────────────
    $('btnGen')?.addEventListener('click', async function () {
        if (!validPatient()) return;
        if (!calc) return Ipd.error('Add tests first.');
        const body = Object.assign({
            items: items.map(x => ({ kind: x.kind, id: x.id, qty: x.qty })), patientId, salutation: $('eSal').value || null, patientName: $('eName').value.trim(),
            gender: $('eGender').value || null, ageYears: $('eAge').value === '' ? null : Number($('eAge').value), mobile: $('eMobile').value,
            emailId: $('eEmail').value.trim() || null, refDoctorId: Number($('eDoctor').value) || null, validDays: Number($('eValid').value), remarks: $('eRemarks').value.trim() || null
        }, discountBody());
        this.disabled = true;
        try {
            const r = await Ipd.post(P.base + 'Save', body);
            if (!r.success) { this.disabled = false; return Ipd.error(r.error); }
            Ipd.toast('Estimate ' + r.data.EstimateNo + ' generated');
            openEstimate(r.data.EstimateId);
        } catch (e) { this.disabled = false; Ipd.error(e.message); }
    });

    async function openEstimate(id) {
        try {
            const d = await Ipd.get(P.base + 'Get?id=' + id), h = d.header; current = h;
            const st = h.Status === 'CANCELLED' ? '<span class="badge text-bg-danger">Cancelled</span>' : h.IsExpired ? '<span class="badge text-bg-secondary">Expired</span>' : '<span class="badge text-bg-success">Valid</span>';
            $('doneTitle').textContent = 'Estimate ' + h.EstimateNo;
            $('doneInfo').innerHTML = `<div class="d-flex justify-content-between"><div><b>${E((h.Salutation ? h.Salutation + ' ' : '') + h.PatientName)}</b><div class="small text-muted">${E(h.Mobile)} · ${Ipd.dt(h.EstimateDate)}</div></div><div class="text-end">${st}<div class="small text-muted">valid till ${Ipd.date(h.ValidTill)}</div></div></div>
                <div class="es-grand mt-2"><span>${(d.lines || []).filter(l => l.ItemKind !== 'M').length} test(s)${Number(h.DiscountAmount) > 0 ? ' · discount ' + M(h.DiscountAmount) : ''}${Number(h.MembershipDiscount) > 0 ? ' · membership ' + M(h.MembershipDiscount) : ''}</span><b>${M(h.NetAmount)}</b></div>
                ${h.SentCount ? `<div class="small text-success mt-2"><i class="bi bi-check2-all me-1"></i>Sent ${h.SentCount} time(s), last to ${E(h.LastSentTo || '')} on ${Ipd.dt(h.LastSentDate)}</div>` : ''}
                ${h.Status === 'CANCELLED' ? `<div class="small text-danger mt-2">Cancelled: ${E(h.CancelReason || '')}</div>` : ''}
                ${P.can.cancel && h.Status !== 'CANCELLED' ? '<button type="button" class="btn btn-link btn-sm text-danger px-0 mt-2" id="btnCancelEst"><i class="bi bi-x-octagon me-1"></i>Cancel this estimate</button>' : ''}`;
            $('btnPrint').href = P.base + 'Print?id=' + id; $('btnPdf').href = P.base + 'Pdf?id=' + id;
            if ($('sendMobile')) { $('sendMobile').value = h.Mobile; $('sendBox').classList.toggle('d-none', h.Status === 'CANCELLED'); }
            bootstrap.Modal.getOrCreateInstance($('doneModal')).show();
        } catch (e) { Ipd.error(e.message); }
    }

    $('btnSend')?.addEventListener('click', async function () {
        const m = $('sendMobile').value.trim();
        if (!/^[6-9]\d{9}$/.test(m)) { $('sendMobile').classList.add('is-invalid'); return; }
        $('sendMobile').classList.remove('is-invalid'); this.disabled = true;
        try {
            const r = await Ipd.post(P.base + 'Send?id=' + current.EstimateId, { mobile: m });
            if (!r.success) return Ipd.error(r.error);
            Ipd.toast('Sent to ' + r.data.sentTo + ' on WhatsApp'); openEstimate(current.EstimateId);
        } finally { this.disabled = false; }
    });
    $('sendMobile')?.addEventListener('input', e => { e.target.value = e.target.value.replace(/\D/g, '').slice(0, 10); });
    $('doneInfo').addEventListener('click', async e => {
        if (e.target.closest('#btnCancelEst')) {
            const res = await Swal.fire({ title: 'Cancel this estimate?', input: 'text', inputLabel: 'Reason', inputValidator: v => !v.trim() && 'Enter the reason', showCancelButton: true, confirmButtonText: 'Cancel estimate', confirmButtonColor: '#dc3545' });
            if (!res.isConfirmed) return;
            const r = await Ipd.post(P.base + 'Cancel?id=' + current.EstimateId, { reason: res.value.trim() });
            if (!r.success) return Ipd.error(r.error);
            Ipd.toast('Estimate cancelled'); openEstimate(current.EstimateId); if ($('listPane').classList.contains('show')) loadList();
        }
    });

    function reset() {
        items = []; calc = null; deptRows = {}; patientId = null;
        ['eMobile', 'eName', 'eAge', 'eEmail', 'eRemarks', 'eTestQ'].forEach(id => { $(id).value = ''; $(id).classList.remove('is-invalid'); });
        $('eSal').value = ''; $('eGender').value = ''; $('eDoctor').value = ''; $('eValid').value = '7'; $('ePatTag').textContent = '';
        if (P.can.discount) { $('dmN').checked = true; $('dValue').value = ''; $('dMode').dispatchEvent(new Event('change')); }
        setMsg(''); render(); renderMember(null); loadCatalog(); $('eMobile').focus();
    }
    $('btnNew').addEventListener('click', reset);
    $('btnAnother').addEventListener('click', () => { bootstrap.Modal.getInstance($('doneModal'))?.hide(); reset(); });

    // ── list ───────────────────────────────────────────────────────────────────────────────────────────────────
    async function loadList() {
        $('lRows').innerHTML = '<tr><td colspan="8" class="text-center text-muted py-3">Loading…</td></tr>';
        try {
            const rows = await Ipd.get(P.base + 'List?' + new URLSearchParams({ fromDate: $('lFrom').value, toDate: $('lTo').value, status: $('lStatus').value, search: $('lSearch').value.trim() })) || [];
            const badge = { ACTIVE: 'success', EXPIRED: 'secondary', CANCELLED: 'danger' }, label = { ACTIVE: 'Valid', EXPIRED: 'Expired', CANCELLED: 'Cancelled' };
            $('lRows').innerHTML = rows.length ? rows.map(r => `<tr><td><div class="fw-semibold">${E(r.EstimateNo)}</div><small class="text-muted">${Ipd.dt(r.EstimateDate)} · ${E(r.CreatedByName || '')}</small></td>
                <td>${E(r.PatientName)}<br><small class="text-muted">${E(r.Mobile)}</small></td><td class="num">${r.TestCount}</td><td class="num">${M(r.GrossAmount)}</td>
                <td class="num text-danger">${Number(r.DiscountAmount) > 0 ? '−' + M(r.DiscountAmount) : '—'}</td><td class="num fw-semibold">${M(r.NetAmount)}</td>
                <td><span class="badge text-bg-${badge[r.DisplayStatus]}">${label[r.DisplayStatus]}</span>${r.SentCount ? ' <i class="bi bi-whatsapp text-success" title="Sent"></i>' : ''}</td>
                <td class="text-end"><button type="button" class="btn btn-sm btn-outline-primary" data-open="${r.EstimateId}">Open</button></td></tr>`).join('')
                : '<tr><td colspan="8" class="text-center text-muted py-3">No estimates.</td></tr>';
        } catch (e) { $('lRows').innerHTML = `<tr><td colspan="8" class="text-danger p-3">${E(e.message)}</td></tr>`; }
    }
    $('btnList').addEventListener('click', () => { bootstrap.Offcanvas.getOrCreateInstance($('listPane')).show(); loadList(); });
    $('lShow').addEventListener('click', loadList);
    $('lSearch').addEventListener('keydown', e => { if (e.key === 'Enter') loadList(); });
    $('lRows').addEventListener('click', e => { const b = e.target.closest('button[data-open]'); if (b) openEstimate(+b.dataset.open); });

    // ── start ──────────────────────────────────────────────────────────────────────────────────────────────────
    (async () => {
        const t = new Date(); $('lFrom').value = iso(new Date(t.getFullYear(), t.getMonth(), 1)); $('lTo').value = iso(t);
        loadCatalog();
        try { misc = await Ipd.get(P.base + 'MiscCharges') || []; misc.forEach(m => $('eMisc').add(new Option(`${m.ChargeName} - ₹${Number(m.Amount).toFixed(2)}${m.IsGstRequired ? ' + GST ' + Number(m.GstPercentage) + '%' : ''}${m.IsDiscountable ? '' : ' (no discount)'}`, m.MiscChargeId))); } catch { }
        try { (await Ipd.get(P.base + 'Doctors') || []).forEach(d => $('eDoctor').add(new Option(d.DoctorName, d.DoctorId))); } catch { }
        render(); $('eMobile').focus();
    })();
})();
