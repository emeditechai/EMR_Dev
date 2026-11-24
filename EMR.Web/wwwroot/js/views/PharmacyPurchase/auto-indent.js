// Pharmacy > Purchase > Auto Reorder, tab "Auto Indent Rules" (SQLScripts/2538).
// Per item: the supplier the indent goes to, the reorder level and Max level (purchase packs; saved on the item's branch
// record), and how much to indent - up to the Max level, or a fixed quantity. EMR.Web PharmacyAutoIndentWorker raises
// the indents right after stock goes out (Hospital Settings > MED > Auto Indent to Suppliers); "Run now" checks every rule.
// Server values come from window.PhAutoIndentCfg (Views/PharmacyPurchase/AutoReorder.cshtml).
(function () {
    'use strict';
    const cfg = window.PhAutoIndentCfg;
    if (!cfg) return;
    const $id = id => document.getElementById(id);
    const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
    const n = (v, d = 2) => Number(v || 0).toLocaleString('en-IN', { maximumFractionDigits: d });
    const num = v => { const x = parseFloat(v); return isFinite(x) ? x : 0; };
    const token = () => document.querySelector('input[name="__RequestVerificationToken"]')?.value || '';
    const toast = (icon, title) => window.Swal ? Swal.fire({ toast: true, position: 'top-end', icon, title, timer: 3500, showConfirmButton: false }) : alert(title);
    const supName = id => cfg.suppliers.find(s => String(s.id) === String(id))?.name || '';

    let rows = [], settings = null;
    const dirty = new Set(), ticked = new Set();

    // ── the model of one row: rule values (edited) on top of the item's numbers ──
    function edit(r) {
        if (!r._e) r._e = {
            supplierId: r.supplierId ?? r.lastSupplierId ?? '',
            reorderLevel: num(r.reorderLevel), maxQty: num(r.maxQty),
            qtyMode: r.qtyMode || 'MAX', fixedQty: r.fixedQty ?? '',
            isActive: r.ruleId ? !!r.ruleActive : true, remove: false
        };
        return r._e;
    }

    // what the next check would indent with the values on screen (same rule as fn_PhAutoIndentCalc)
    function preview(r) {
        const e = edit(r), avail = num(r.available), rl = num(e.reorderLevel), mx = num(e.maxQty);
        const has = !!r.ruleId || dirty.has(r.itemId);
        if (!has || e.remove) return { state: 'NORULE', qty: 0 };
        if (!e.isActive) return { state: 'OFF', qty: 0 };
        if (!e.supplierId) return { state: 'NOSUP', qty: 0 };
        const due = avail <= rl && (rl > 0 || e.qtyMode === 'FIXED');
        if (!due) return { state: num(r.openIndent) > 0 ? 'INDENTED' : 'OK', qty: 0 };
        const q = e.qtyMode === 'FIXED' ? Math.ceil(num(e.fixedQty)) : Math.max(0, Math.ceil(mx - avail));
        return { state: q > 0 ? 'DUE' : 'OK', qty: q };
    }

    function badge(p) {
        return ({
            NORULE: '<span class="badge bg-light text-secondary border">No rule</span>',
            OFF: '<span class="badge bg-secondary-subtle text-secondary">Off</span>',
            NOSUP: '<span class="badge bg-warning-subtle text-warning-emphasis">Pick supplier</span>',
            DUE: '<span class="badge bg-danger-subtle text-danger">Due</span>',
            INDENTED: '<span class="badge bg-info-subtle text-info-emphasis">Indented</span>',
            OK: '<span class="badge bg-success-subtle text-success">OK</span>'
        })[p.state] || '';
    }

    function supplierSelect(e) {
        return `<select class="form-select form-select-sm ai-in ai-sup" data-f="supplierId"><option value="">— pick —</option>` +
            cfg.suppliers.map(s => `<option value="${esc(s.id)}" ${String(s.id) === String(e.supplierId) ? 'selected' : ''}>${esc(s.name)}</option>`).join('') + '</select>';
    }

    function rowHtml(r) {
        const e = edit(r), p = preview(r), dis = cfg.canManage ? '' : 'disabled';
        const pack = r.purchaseUom ? `<div class="ar-why text-end">${esc(r.purchaseUom)}</div>` : '';
        return `<tr data-id="${r.itemId}" class="${dirty.has(r.itemId) ? 'table-warning' : ''} ${e.remove ? 'ar-off' : ''}">
            <td><input class="form-check-input ai-tick" type="checkbox" ${ticked.has(r.itemId) ? 'checked' : ''}></td>
            <td><div class="fw-semibold">${esc(r.itemName)} <span class="text-muted fw-normal small">${esc(r.packSize || '')}</span></div>
                <div class="ar-why">${esc(r.genericName || '')} · ${esc(r.itemCode)}${r.lastIndentNo ? ` · last auto indent <b>${esc(r.lastIndentNo)}</b>` : ''}${num(r.avgDaily) > 0 ? ` · sells ${n(r.avgDaily, 2)}/day` : ''}</div></td>
            <td class="num">${n(r.stockPacks)}</td>
            <td class="num">${num(r.onOrder) ? n(r.onOrder) : '–'}</td>
            <td class="num">${num(r.openIndent) ? n(r.openIndent) : '–'}</td>
            <td class="num"><input type="number" min="0" step="1" class="form-control form-control-sm ar-qty ai-in" data-f="reorderLevel" value="${e.reorderLevel}" ${dis}></td>
            <td class="num"><input type="number" min="0" step="1" class="form-control form-control-sm ar-qty ai-in" data-f="maxQty" value="${e.maxQty}" ${dis}></td>
            <td><div class="d-flex gap-1 align-items-center">
                <select class="form-select form-select-sm ai-in" data-f="qtyMode" style="width:110px" ${dis}>
                    <option value="MAX" ${e.qtyMode !== 'FIXED' ? 'selected' : ''}>Up to Max</option>
                    <option value="FIXED" ${e.qtyMode === 'FIXED' ? 'selected' : ''}>Fixed qty</option></select>
                <input type="number" min="1" step="1" class="form-control form-control-sm ar-qty ai-in ${e.qtyMode === 'FIXED' ? '' : 'd-none'}" data-f="fixedQty" value="${esc(e.fixedQty)}" placeholder="qty" ${dis}>
            </div></td>
            <td>${cfg.canManage ? supplierSelect(e) : esc(supName(e.supplierId) || '–')}</td>
            <td class="num ai-next">${p.qty > 0 ? `<b class="text-danger">${n(p.qty, 0)}</b>${pack}` : '–'}</td>
            <td class="ai-state">${badge(p)}</td>
            <td class="text-center"><div class="form-check form-switch d-inline-block m-0"><input class="form-check-input ai-in" type="checkbox" data-f="isActive" ${e.isActive ? 'checked' : ''} ${dis}></div></td>
            <td>${r.ruleId && cfg.canManage ? `<button type="button" class="btn btn-sm btn-link text-danger p-0 ai-del" title="Remove the rule (levels stay on the item)"><i class="bi bi-x-circle"></i></button>` : ''}</td>
        </tr>`;
    }

    function render() {
        const body = $id('aiBody');
        if (!rows.length) {
            const f = $id('aiFilter').value;
            body.innerHTML = `<tr><td colspan="13" class="text-muted small p-3">${f === 'RULES'
                ? 'No auto indent rules yet. Choose <b>Items without a rule</b> above, set the supplier and levels, and save.'
                : 'No items match.'}</td></tr>`;
        } else body.innerHTML = rows.map(rowHtml).join('');
        totals();
    }

    function refreshRow(r) {
        const tr = $id('aiBody').querySelector(`tr[data-id="${r.itemId}"]`);
        if (!tr) return;
        const p = preview(r), e = edit(r);
        tr.querySelector('.ai-next').innerHTML = p.qty > 0 ? `<b class="text-danger">${n(p.qty, 0)}</b>${r.purchaseUom ? `<div class="ar-why text-end">${esc(r.purchaseUom)}</div>` : ''}` : '–';
        tr.querySelector('.ai-state').innerHTML = badge(p);
        tr.classList.toggle('table-warning', dirty.has(r.itemId));
        tr.classList.toggle('ar-off', !!e.remove);
        tr.querySelector('[data-f="fixedQty"]')?.classList.toggle('d-none', e.qtyMode !== 'FIXED');
    }

    function totals() {
        $id('aiSel').textContent = ticked.size ? `${ticked.size} item(s) ticked.` : 'Nothing ticked.';
        $id('aiBulk').classList.toggle('d-none', !ticked.size || !cfg.canManage);
        $id('aiDirty').textContent = dirty.size ? `${dirty.size} unsaved change(s)` : '';
        $id('aiSave').disabled = !dirty.size || !cfg.canManage;
        $id('aiRunNow').disabled = !cfg.canManage;
    }

    function kpis() {
        const s = settings || {};
        $id('aiOff').classList.toggle('d-none', !!s.enabled);
        $id('aiRules').textContent = s.activeRules ?? '–';
        $id('aiDue').textContent = s.dueNow ?? '–';
        $id('aiAwait').textContent = s.awaitingApproval ?? '–';
        $id('aiStatus').innerHTML = s.enabled
            ? `<span class="text-success"><i class="bi bi-check-circle-fill me-1"></i>On</span> · checked ${s.lastCheckAt ? new Date(s.lastCheckAt).toLocaleString('en-IN', { day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit' }) : 'not yet'}`
            : `<span class="text-danger"><i class="bi bi-x-circle-fill me-1"></i>Off</span> · <a href="${cfg.urls.settings}">Hospital Settings &gt; MED</a>`;
    }

    async function load() {
        if (dirty.size && !confirm('Unsaved rule changes will be lost. Reload anyway?')) return;
        dirty.clear(); ticked.clear(); $id('aiChkAll').checked = false;
        $id('aiBody').innerHTML = '<tr><td colspan="13" class="text-muted small p-3">Loading…</td></tr>';
        const qs = new URLSearchParams({ filter: $id('aiFilter').value, supplierId: $id('aiSup').value, categoryId: $id('aiCat').value, search: $id('aiQ').value.trim() });
        [...qs.keys()].forEach(k => { if (!qs.get(k)) qs.delete(k); });
        try {
            const r = await fetch(`${cfg.urls.data}?${qs}`, { credentials: 'same-origin' });
            if (!r.ok) throw new Error();
            const d = await r.json();
            settings = d.settings; rows = d.rows || [];
        } catch { rows = []; toast('error', 'The rules could not be loaded.'); }
        kpis(); render();
    }

    const find = id => rows.find(r => r.itemId === +id);
    function markDirty(r) { dirty.add(r.itemId); refreshRow(r); totals(); }

    // ── edits in the grid ──
    $id('aiBody').addEventListener('change', ev => {
        const tr = ev.target.closest('tr[data-id]'); if (!tr) return;
        const r = find(tr.dataset.id); if (!r) return;
        if (ev.target.classList.contains('ai-tick')) { ev.target.checked ? ticked.add(r.itemId) : ticked.delete(r.itemId); totals(); return; }
        const f = ev.target.dataset.f; if (!f) return;
        const e = edit(r);
        e[f] = ev.target.type === 'checkbox' ? ev.target.checked : (['reorderLevel', 'maxQty', 'fixedQty'].includes(f) ? (ev.target.value === '' ? '' : num(ev.target.value)) : ev.target.value);
        e.remove = false;
        markDirty(r);
    });
    $id('aiBody').addEventListener('click', ev => {
        const b = ev.target.closest('.ai-del'); if (!b) return;
        const r = find(b.closest('tr').dataset.id); if (!r) return;
        edit(r).remove = !edit(r).remove;
        markDirty(r);
    });
    $id('aiChkAll').addEventListener('change', ev => {
        rows.forEach(r => ev.target.checked ? ticked.add(r.itemId) : ticked.delete(r.itemId));
        $id('aiBody').querySelectorAll('.ai-tick').forEach(c => c.checked = ev.target.checked);
        totals();
    });

    // ── bulk actions on the ticked items ──
    function eachTicked(fn) { rows.filter(r => ticked.has(r.itemId)).forEach(r => { fn(r, edit(r)); markDirty(r); }); render(); }
    $id('aiBulkSup').addEventListener('change', ev => { const v = ev.target.value; if (!v) return; eachTicked((r, e) => { e.supplierId = v; e.remove = false; }); ev.target.value = ''; });
    $id('aiBulkMode').addEventListener('change', ev => { const v = ev.target.value; if (!v) return; eachTicked((r, e) => { e.qtyMode = v; e.remove = false; }); ev.target.value = ''; });
    $id('aiLastSup').addEventListener('click', () => eachTicked((r, e) => { if (r.lastSupplierId) e.supplierId = r.lastSupplierId; }));
    $id('aiSuggest').addEventListener('click', () => {
        let none = 0;
        eachTicked((r, e) => {
            if (r.suggReorderLevel == null) { none++; return; }
            e.reorderLevel = Math.max(1, num(r.suggReorderLevel));
            e.maxQty = Math.max(e.reorderLevel + 1, num(r.suggMaxQty));
            e.remove = false;
        });
        if (none) toast('info', `${none} item(s) had no recent sales: levels left as they were.`);
    });
    $id('aiRemove').addEventListener('click', () => {
        const withRule = rows.filter(r => ticked.has(r.itemId) && r.ruleId);
        if (!withRule.length) { toast('info', 'None of the ticked items has a rule.'); return; }
        withRule.forEach(r => { edit(r).remove = true; dirty.add(r.itemId); });
        render();
    });

    // ── save ──
    $id('aiSave').addEventListener('click', async () => {
        const list = rows.filter(r => dirty.has(r.itemId)).map(r => {
            const e = edit(r);
            return { itemId: r.itemId, supplierId: e.supplierId ? +e.supplierId : null, reorderLevel: num(e.reorderLevel), maxQty: num(e.maxQty),
                     qtyMode: e.qtyMode, fixedQty: e.qtyMode === 'FIXED' && e.fixedQty !== '' ? num(e.fixedQty) : null, isActive: !!e.isActive, remove: !!e.remove && !!r.ruleId };
        }).filter(x => x.remove || !rows.find(r => r.itemId === x.itemId)._e.remove);
        if (!list.length) { dirty.clear(); render(); return; }
        const btn = $id('aiSave'); btn.disabled = true;
        try {
            const body = new URLSearchParams({ json: JSON.stringify(list), __RequestVerificationToken: token() });
            const r = await fetch(cfg.urls.save, { method: 'POST', body, credentials: 'same-origin' });
            const d = await r.json();
            if (!d.success) { window.Swal ? Swal.fire({ icon: 'warning', title: 'Not saved', html: esc(d.message).replace(/\n/g, '<br>') }) : alert(d.message); return; }
            toast('success', d.message);
            dirty.clear(); load();
        } catch { toast('error', 'Could not reach the server.'); }
        finally { totals(); }
    });

    // ── run now ──
    $id('aiRunNow').addEventListener('click', async () => {
        if (dirty.size) { toast('warning', 'Save the rule changes first.'); return; }
        const btn = $id('aiRunNow'); btn.disabled = true;
        try {
            const r = await fetch(cfg.urls.run, { method: 'POST', body: new URLSearchParams({ __RequestVerificationToken: token() }), credentials: 'same-origin' });
            const d = await r.json();
            const list = (d.indents || []).map(i => `<li><a href="${esc(i.url)}">${esc(i.indentNo)}</a> · ${esc(i.supplierName)} · ${i.lines} item(s)${i.isNew ? ' <span class="badge bg-primary-subtle text-primary">new</span>' : ' <span class="badge bg-secondary-subtle text-secondary">added</span>'}</li>`).join('');
            if (window.Swal) Swal.fire({ icon: d.success ? (list ? 'success' : 'info') : 'warning', title: d.success ? 'Auto indent check done' : 'Auto indent', html: `<div class="small">${esc(d.message)}</div>${list ? `<ul class="text-start small mt-2 mb-0">${list}</ul><div class="small text-muted mt-2">Submitted for approval (Purchase Indent).</div>` : ''}` });
            else alert(d.message);
            load();
        } catch { toast('error', 'Could not reach the server.'); }
        finally { btn.disabled = !cfg.canManage; }
    });

    // ── run log ──
    $id('aiLogBtn').addEventListener('click', async () => {
        $id('aiLogBody').innerHTML = '<tr><td colspan="6" class="text-muted p-3">Loading…</td></tr>';
        bootstrap.Modal.getOrCreateInstance($id('aiLog')).show();
        try {
            const r = await fetch(cfg.urls.log, { credentials: 'same-origin' });
            const list = await r.json();
            $id('aiLogBody').innerHTML = list.length ? list.map(l => `<tr class="${l.isError ? 'table-danger' : ''}">
                <td class="text-nowrap">${new Date(l.runAt).toLocaleString('en-IN', { day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit' })}</td>
                <td>${l.runType === 'MANUAL' ? 'Run now' : 'Automatic'}</td><td class="text-end">${l.itemsChecked}</td><td class="text-end">${l.linesRaised}</td>
                <td>${esc(l.message)}</td><td>${esc(l.runBy || 'System')}</td></tr>`).join('')
                : '<tr><td colspan="6" class="text-muted p-3">No runs yet. Automatic checks are logged only when they raise something.</td></tr>';
        } catch { $id('aiLogBody').innerHTML = '<tr><td colspan="6" class="text-danger p-3">The log could not be loaded.</td></tr>'; }
    });

    // ── filters ──
    ['aiFilter', 'aiSup', 'aiCat'].forEach(id => $id(id).addEventListener('change', load));
    $id('aiReload').addEventListener('click', load);
    let qTimer; $id('aiQ').addEventListener('input', () => { clearTimeout(qTimer); qTimer = setTimeout(load, 400); });
    window.addEventListener('beforeunload', ev => { if (dirty.size) { ev.preventDefault(); ev.returnValue = ''; } });

    load();
})();
