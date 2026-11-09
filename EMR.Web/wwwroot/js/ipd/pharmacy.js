/* IPD Patient workspace > Medicines / Consumables tabs (Phase 4, SQLScripts/2437): issue batches against the IP number, return unused. */
(function () {
    'use strict';
    const P = window.IpdPh; if (!P) return;
    const E = Ipd.esc, cart = { PHARMACY: [], CONSUMABLE: [] };
    let doctors = null, stores = null;

    async function loadDoctors() {
        if (doctors) return doctors;
        try { const d = await Ipd.get(window.IpdBill.base + 'ChargeLookups?id=' + P.id); doctors = d.doctors || []; } catch { doctors = []; }
        return doctors;
    }
    async function initForm(box) {
        const head = box.dataset.head;
        if (!P.can.issue) { box.innerHTML = '<div class="small text-muted">You can see the issues; issuing needs the IPD Patient › Issue medicines permission.</div>'; return; }
        if (!P.open) { box.innerHTML = '<div class="small text-muted"><i class="bi bi-lock me-1"></i>The patient is not admitted (or the final bill is made): nothing can be issued.</div>'; return; }
        const docs = await loadDoctors();
        if (!stores) { try { stores = (await Ipd.get(P.base + 'PhItems?id=' + P.id + '&q=')).stores || []; } catch { stores = []; } }
        box.innerHTML = `<div class="row g-2 align-items-end">
            <div class="col-12 col-lg-5 position-relative"><label class="form-label small fw-semibold">Find ${head === 'CONSUMABLE' ? 'a consumable' : 'a medicine'} (name, code or barcode)</label>
                <input class="form-control p-find" autocomplete="off" placeholder="Type at least 2 letters" /><div class="sug-list list-group p-sug"></div></div>
            <div class="col-6 col-lg-2"><label class="form-label small fw-semibold">Store</label><select class="form-select p-store">${stores.map(s => `<option value="${s.StoreId}" ${s.IsDefault ? 'selected' : ''}>${E(s.StoreName)}</option>`).join('')}</select></div>
            <div class="col-6 col-lg-2"><label class="form-label small fw-semibold">Prescribed by</label><select class="form-select p-doc"><option value="">—</option>${docs.map(d => `<option value="${d.Id}" ${d.Id === P.consultant ? 'selected' : ''}>${E(d.Name)}</option>`).join('')}</select></div>
            <div class="col-12 col-lg-3"><label class="form-label small fw-semibold">Remarks</label><input class="form-control p-rem" maxlength="300" placeholder="e.g. ward indent no." /></div>
            <div class="col-12"><div class="p-cart"></div></div></div>`;
        const q = s => box.querySelector(s), find = q('.p-find'), sug = q('.p-sug');
        let t, hits = [], idx = 0;
        const renderSug = () => {
            sug.innerHTML = hits.map((x, i) => `<button type="button" class="list-group-item list-group-item-action sug py-2 px-3 ${i === idx ? 'active' : ''}" data-i="${i}">
                <b>${E(x.ItemName)}</b> <span class="text-muted small">${E(x.ItemCode || '')} · ${E(x.PackSize || '')}${x.ScheduleCode ? ' · Sch ' + E(x.ScheduleCode) : ''}</span>
                ${x.IsHighAlert ? '<span class="ipd-pill alert ms-1">High alert</span>' : ''}${x.IsLasa ? '<span class="ipd-pill warn ms-1">LASA</span>' : ''}
                <span class="float-end small">stock ${Number(x.Stock)}</span></button>`).join('');
            sug.style.display = hits.length ? 'block' : 'none';
        };
        find.addEventListener('input', () => {
            clearTimeout(t); const v = find.value.trim();
            if (v.length < 2) { hits = []; renderSug(); return; }
            t = setTimeout(async () => { try { hits = (await Ipd.get(P.base + 'PhItems?id=' + P.id + '&q=' + encodeURIComponent(v) + '&storeId=' + q('.p-store').value)).items || []; } catch { hits = []; } idx = 0; renderSug(); }, 250);
        });
        find.addEventListener('keydown', e => {
            if (sug.style.display !== 'block') return;
            if (e.key === 'ArrowDown' || e.key === 'ArrowUp') { e.preventDefault(); idx = (idx + (e.key === 'ArrowDown' ? 1 : -1) + hits.length) % hits.length; renderSug(); }
            else if (e.key === 'Enter') { e.preventDefault(); pick(hits[idx]); }
            else if (e.key === 'Escape') sug.style.display = 'none';
        });
        sug.addEventListener('mousedown', e => e.preventDefault());
        sug.addEventListener('click', e => { const b = e.target.closest('[data-i]'); if (b) pick(hits[Number(b.dataset.i)]); });
        document.addEventListener('click', e => { if (!sug.contains(e.target) && e.target !== find) sug.style.display = 'none'; });
        q('.p-store').addEventListener('change', () => { if (cart[head].length && !confirm('Changing the store clears the list. Continue?')) return; cart[head] = []; renderCart(); });

        async function pick(x) {
            if (!x) return;
            find.value = ''; hits = []; renderSug();
            let batches = [];
            try { batches = await Ipd.get(P.base + 'PhBatches?itemId=' + x.ItemId + '&storeId=' + q('.p-store').value) || []; } catch (e) { Ipd.error(e.message); return; }
            if (!batches.length) { Ipd.error('No saleable batch of this item in the store (expired, blocked or out of stock).'); return; }
            const b = batches[0];   // FEFO: nearest expiry first
            if (cart[head].some(c => c.BatchId === b.BatchId)) { Ipd.toast('Already in the list: change the quantity', 'info'); return; }
            cart[head].push({ ItemId: x.ItemId, Name: x.ItemName, Schedule: x.ScheduleCode, Batches: batches, BatchId: b.BatchId, Qty: 1 });
            renderCart();
        }
        function renderCart() {
            const c = cart[head];
            q('.p-cart').innerHTML = !c.length ? '<div class="small text-muted">Pick items above; the batch with the nearest expiry is chosen first (FEFO).</div>' : `
                <table class="table table-sm align-middle mb-2"><thead><tr><th>Item</th><th>Batch</th><th class="text-end">Stock</th><th style="width:110px">Qty</th><th class="text-end">MRP / unit</th><th></th></tr></thead><tbody>
                ${c.map((x, i) => { const b = x.Batches.find(y => y.BatchId === x.BatchId) || x.Batches[0];
                    return `<tr><td>${E(x.Name)}${x.Schedule ? ` <span class="badge text-bg-light border">Sch ${E(x.Schedule)}</span>` : ''}</td>
                    <td><select class="form-select form-select-sm p-batch" data-i="${i}">${x.Batches.map(y => `<option value="${y.BatchId}" ${y.BatchId === x.BatchId ? 'selected' : ''}>${E(y.BatchNo)} · exp ${Ipd.date(y.ExpiryDate)}</option>`).join('')}</select></td>
                    <td class="text-end">${Number(b.Stock)}</td>
                    <td><input type="number" class="form-control form-control-sm text-end p-qty" data-i="${i}" min="0.001" step="any" value="${x.Qty}" /></td>
                    <td class="text-end">${Ipd.money(b.UnitMrp)}</td>
                    <td class="text-end"><button type="button" class="btn btn-sm btn-light border text-danger p-del" data-i="${i}"><i class="bi bi-x-lg"></i></button></td></tr>`; }).join('')}
                </tbody></table>
                <div class="d-flex justify-content-between align-items-center"><span class="small text-muted">Price by the Price Rule for this payer, never above MRP.</span>
                <div class="d-flex gap-2"><button type="button" class="btn btn-light border p-clear">Clear</button><button type="button" class="btn btn-success p-save"><i class="bi bi-box-arrow-right me-1"></i>Issue ${c.length} item(s)</button></div></div>`;
        }
        q('.p-cart').addEventListener('change', e => {
            const b = e.target.closest('.p-batch'), qq = e.target.closest('.p-qty');
            if (b) { cart[head][Number(b.dataset.i)].BatchId = Number(b.value); renderCart(); }
            if (qq) cart[head][Number(qq.dataset.i)].Qty = Number(qq.value) || 0;
        });
        q('.p-cart').addEventListener('click', async e => {
            if (e.target.closest('.p-del')) { cart[head].splice(Number(e.target.closest('.p-del').dataset.i), 1); renderCart(); return; }
            if (e.target.closest('.p-clear')) { cart[head] = []; renderCart(); return; }
            const s = e.target.closest('.p-save'); if (!s) return;
            const c = cart[head];
            for (const x of c) {
                const b = x.Batches.find(y => y.BatchId === x.BatchId);
                if (!(x.Qty > 0)) return Ipd.error('Enter the quantity of ' + x.Name + '.');
                if (b && x.Qty > Number(b.Stock)) return Ipd.error(`Only ${Number(b.Stock)} of ${x.Name} batch ${b.BatchNo} in the store.`);
            }
            if (!await Ipd.confirm('Issue these items?', `${c.length} item(s), charged to the IP bill.`, 'Issue')) return;
            s.disabled = true;
            try {
                const r = await Ipd.post(P.base + 'Issue?id=' + P.id, { lines: c.map(x => ({ itemId: x.ItemId, batchId: x.BatchId, qty: x.Qty })), head, storeId: Number(q('.p-store').value) || null,
                    doctorId: Number(q('.p-doc').value) || null, remarks: q('.p-rem').value.trim() || null });
                if (!r.success) { Ipd.error(r.error); return; }
                Ipd.toast(`Issued ${r.data.IssueNo}: ${Ipd.money(r.data.Total)}`);
                cart[head] = []; q('.p-rem').value = ''; renderCart(); loadRows();
                if (window.IpdBillRefresh) window.IpdBillRefresh();
            } finally { s.disabled = false; }
        });
        renderCart();
    }

    async function loadRows() {
        for (const tb of document.querySelectorAll('.ipd-ph-rows')) {
            const head = tb.dataset.head, rt = document.querySelector(`.ipd-ph-returns[data-head="${head}"]`);
            let d;
            try { d = await Ipd.get(P.base + 'PhIssues?id=' + P.id + '&head=' + head); } catch (e) { tb.innerHTML = `<tr><td colspan="8" class="text-danger small">${E(e.message)}</td></tr>`; continue; }
            const rows = d.issues || [], rets = d.returns || [];
            tb.innerHTML = rows.length ? rows.map(r => `<tr>
                <td><div class="fw-semibold font-monospace small">${E(r.IssueNo)}</div><div class="small text-muted">${Ipd.dt(r.IssueAt)}</div></td>
                <td><div class="fw-semibold">${E(r.ItemName)}${r.ScheduleCode ? ` <span class="badge text-bg-light border">Sch ${E(r.ScheduleCode)}</span>` : ''}</div>
                    <div class="small text-muted">Batch ${E(r.BatchNo)} · exp ${Ipd.date(r.ExpiryDate)} · ${E(r.StoreName || '')}${r.DoctorName ? ' · Dr ' + E(r.DoctorName) : ''}</div></td>
                <td class="text-end">${Number(r.Qty)}</td><td class="text-end">${Number(r.ReturnedQty) ? Number(r.ReturnedQty) : '—'}</td>
                <td class="text-end">${Ipd.num(r.UnitPrice)}</td><td class="text-end fw-semibold">${Ipd.num(r.KeptAmount)}</td>
                <td class="small">${E(r.IssuedBy || '')}</td>
                <td class="text-end">${r.CanReturn && P.can.ret ? `<button type="button" class="btn btn-sm btn-light border p-ret" data-line="${r.LineId}" data-max="${Number(r.KeptQty)}" data-name="${E(r.ItemName)}" title="Return unused"><i class="bi bi-arrow-return-left"></i></button>` : ''}</td></tr>`).join('')
                : '<tr><td colspan="8" class="text-muted small">Nothing issued yet.</td></tr>';
            if (rt) rt.innerHTML = rets.length ? rets.map(r => `<tr><td><div class="font-monospace small fw-semibold">${E(r.IssueNo)}</div><div class="small text-muted">${Ipd.dt(r.IssueAt)} · from ${E(r.FromIssueNo)}</div></td>
                <td>${E(r.ItemName)} <span class="small text-muted">batch ${E(r.BatchNo)}</span></td><td class="text-end">${Number(r.Qty)}</td><td class="text-end">${Ipd.num(r.Amount)}</td>
                <td class="small">${E(r.Remarks || '')}</td><td class="small">${E(r.ReturnedBy || '')}</td></tr>`).join('') : '<tr><td colspan="6" class="text-muted small">No returns.</td></tr>';
        }
    }
    document.addEventListener('click', async e => {
        const b = e.target.closest('.p-ret'); if (!b || !window.Swal) return;
        const max = Number(b.dataset.max);
        const r = await Swal.fire({
            title: 'Return unused ' + b.dataset.name, html: `<div class="text-start small mb-2">Up to ${max} can be returned to the store.</div>
                <input id="rq" type="number" class="form-control mb-2" min="0.001" max="${max}" step="any" value="${max}" />
                <input id="rr" class="form-control" maxlength="300" placeholder="Reason (e.g. patient discharged, dose changed)" />`,
            showCancelButton: true, confirmButtonText: 'Return',
            preConfirm: () => { const qv = Number(document.getElementById('rq').value), rv = document.getElementById('rr').value.trim();
                if (!(qv > 0) || qv > max) { Swal.showValidationMessage('Enter a quantity up to ' + max + '.'); return false; }
                if (!rv) { Swal.showValidationMessage('Enter the reason.'); return false; } return { qv, rv }; }
        });
        if (!r.isConfirmed) return;
        const res = await Ipd.post(P.base + 'Return?id=' + P.id, { lines: [{ lineId: Number(b.dataset.line), qty: r.value.qv }], reason: r.value.rv });
        if (!res.success) return Ipd.error(res.error);
        Ipd.toast('Returned ' + res.data.IssueNo); loadRows();
        if (window.IpdBillRefresh) window.IpdBillRefresh();
    });

    document.querySelectorAll('.ipd-ph-form').forEach(initForm);
    loadRows();
})();
