/* Quality & Compliance module - shared page helpers (SQLScripts/2247+).
   Every call returns { success, data | message }; a refused business rule shows its message as is. */
window.QC = (function () {
    const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
    const num = (n, d = 2) => (n === null || n === undefined || n === '') ? '' : Number(n).toLocaleString('en-IN', { minimumFractionDigits: d, maximumFractionDigits: d });
    const qty = n => (n === null || n === undefined || n === '') ? '' : Number(n).toLocaleString('en-IN', { maximumFractionDigits: 4 });
    const money = n => (n === null || n === undefined || n === '') ? '—' : '₹' + num(n);
    const date = s => { if (!s) return ''; const d = new Date(s); return isNaN(d) ? '' : d.toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' }); };
    const dateTime = s => { if (!s) return ''; const d = new Date(s); return isNaN(d) ? '' : d.toLocaleString('en-GB', { day: '2-digit', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' }); };

    async function get(url, params) {
        const q = new URLSearchParams();
        Object.entries(params || {}).forEach(([k, v]) => { if (v !== null && v !== undefined && v !== '') q.append(k, v); });
        const r = await fetch(url + (q.toString() ? '?' + q : ''), { headers: { 'Accept': 'application/json' } });
        if (r.status === 403) return { success: false, message: 'You do not have permission for this action.' };
        try { return await r.json(); } catch (e) { return { success: false, message: 'The server did not answer. Please try again.' }; }
    }

    async function post(url, body) {
        // null fields are left out: a null for a required number would fail binding of the whole request;
        // left out it arrives as 0 and the procedure refuses it with its own message
        const json = JSON.stringify(body || {}, (k, v) => (v === null && k !== '' ? undefined : v));
        const r = await fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json', 'Accept': 'application/json' }, body: json });
        if (r.status === 403) return { success: false, message: 'You do not have permission for this action.' };
        try { return await r.json(); } catch (e) { return { success: false, message: 'The server did not answer. Please try again.' }; }
    }

    function ok(msg) {
        if (window.Swal) Swal.fire({ icon: 'success', title: msg, timer: 1600, showConfirmButton: false, toast: true, position: 'top-end' });
    }
    function fail(msg) {
        if (window.Swal) Swal.fire({ icon: 'warning', title: 'Not saved', text: msg || 'Please try again.', confirmButtonColor: '#0d6efd' });
        else alert(msg);
    }
    async function confirm(title, text, confirmText) {
        if (!window.Swal) return window.confirm(title + '\n' + (text || ''));
        const r = await Swal.fire({ icon: 'question', title, text, showCancelButton: true, confirmButtonText: confirmText || 'Yes', confirmButtonColor: '#dc3545' });
        return r.isConfirmed;
    }

    /** <option>s from [{Id, Name}] (PascalCase rows from the server). */
    function options(list, selected, placeholder) {
        return (placeholder !== undefined ? `<option value="">${esc(placeholder)}</option>` : '') +
            (list || []).map(o => `<option value="${o.Id}" ${String(o.Id) === String(selected ?? '') ? 'selected' : ''}>${esc(o.Name)}</option>`).join('');
    }

    /** A form's named fields to an object: numbers as numbers, checkboxes as booleans, blanks as null. */
    function formData(form) {
        const o = {};
        form.querySelectorAll('[name]').forEach(el => {
            if (el.type === 'checkbox') { o[el.name] = el.checked; return; }
            const v = (el.value ?? '').trim();
            if (v === '') { o[el.name] = null; return; }
            o[el.name] = el.dataset.type === 'number' ? Number(v) : v;
        });
        return o;
    }

    function fill(form, row) {
        form.querySelectorAll('[name]').forEach(el => {
            const key = Object.keys(row || {}).find(k => k.toLowerCase() === el.name.toLowerCase());
            const v = key ? row[key] : null;
            if (el.type === 'checkbox') el.checked = !!v;
            else el.value = v === null || v === undefined ? '' : v;
        });
    }

    function statusBadge(on) {
        return on ? '<span class="badge bg-success-subtle text-success border border-success-subtle rounded-pill px-3"><i class="bi bi-check-circle-fill me-1"></i>Active</span>'
                  : '<span class="badge bg-danger-subtle text-danger border border-danger-subtle rounded-pill px-3"><i class="bi bi-x-circle-fill me-1"></i>Inactive</span>';
    }

    /** Searchable item picker (Select2 when loaded) over Item Master rows; onPick gets the chosen row. */
    function itemPicker(select, items, modalEl, onPick) {
        select.innerHTML = '<option value=""></option>' + (items || []).map(i =>
            `<option value="${i.ItemId}">${esc(i.ItemCode)} - ${esc(i.ItemName)} (${esc(i.ConsumptionUnit)})</option>`).join('');
        const pick = () => { const id = +select.value; if (!id) return; onPick(items.find(x => x.ItemId === id)); };
        if (window.jQuery && jQuery.fn.select2) {
            const $s = jQuery(select);
            if ($s.data('select2')) $s.select2('destroy');
            $s.select2({ theme: 'bootstrap-5', width: '100%', placeholder: 'Search item by name or code...', allowClear: true, dropdownParent: jQuery(modalEl) });
            $s.off('select2:select').on('select2:select', pick);
        } else select.onchange = pick;
    }
    function clearPicker(select) {
        if (window.jQuery && jQuery.fn.select2 && jQuery(select).data('select2')) jQuery(select).val('').trigger('change');
        else select.value = '';
    }

    return { esc, num, qty, money, date, dateTime, get, post, ok, fail, confirm, options, formData, fill, statusBadge, itemPicker, clearPicker };
})();
