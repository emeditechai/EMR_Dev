/* Create / Edit EMR Template (SQLScripts/2483): "Who uses this template" - one speciality (required) and, optionally, doctors of
   that speciality. Reloads the doctor list when the specialities change, keeps the doctors still valid, and says in plain
   words who will get the template. */
$(function () {
    'use strict';
    const $spec = $('#SelectedSpecialityIds'), $doc = $('.et-doctors'), $sum = $('#etSummary'), $active = $('#IsActive');
    if (!$spec.length || !$doc.length) return;
    $spec.select2({ theme: 'bootstrap-5', width: '100%', placeholder: $spec.data('placeholder'), allowClear: true });
    const specIds = () => { const v = $spec.val(); return Array.isArray(v) ? v.filter(Boolean) : (v ? [v] : []); };
    const esc = v => String(v ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

    const fmt = o => {
        if (!o.id) return o.text;
        const el = o.element, spec = el ? el.dataset.spec : '', other = el ? el.dataset.other : '';
        return $(`<div class="et-doc-opt"><div class="fw-semibold">${esc(o.text)}</div><div class="small text-muted">${esc(spec || '')}${other
            ? ` · <span class="text-danger"><i class="bi bi-exclamation-triangle"></i> already has “${esc(other)}”</span>` : ''}</div></div>`);
    };
    $doc.select2({ theme: 'bootstrap-5', width: '100%', allowClear: true, closeOnSelect: false, templateResult: fmt,
        templateSelection: o => o.text, language: { noResults: () => 'No active doctor in the chosen specialities' } });

    function summary() {
        const specs = $spec.find('option:selected').filter((_, o) => !!o.value).map((_, o) => o.text).get();
        const docs = $doc.find('option:selected').map((_, o) => ({ name: o.text, other: o.dataset.other })).get();
        const inactive = !$active.is(':checked');
        let html;
        if (!specs.length) {
            html = `<div class="et-sum et-sum-empty"><i class="bi bi-info-circle"></i><div>Choose the speciality first. Then leave <b>Doctors</b> empty to make this the
                speciality's default template, or pick doctors to give them their own template.</div></div>`;
        } else if (!docs.length) {
            html = specDefault && !inactive
                ? `<div class="et-sum et-sum-bad"><i class="bi bi-exclamation-octagon"></i><div><span class="badge text-bg-danger me-1">Cannot be saved as is</span>
                    <b>${esc(specs[0])}</b> already has the default template <b>“${esc(specDefault)}”</b>. A speciality can have only one default.
                    <div class="small mt-1">Choose <b>Doctors</b> above to make this a doctor-specific template, or deactivate “${esc(specDefault)}” first (or save this one as inactive).</div></div></div>`
                : `<div class="et-sum et-sum-spec"><i class="bi bi-diagram-3"></i><div><span class="badge text-bg-info me-1">Speciality default</span>
                Used for <b>every doctor</b> of ${specs.map(s => `<b>${esc(s)}</b>`).join(', ')} who has no template of their own.
                <div class="small text-muted mt-1">A speciality has only one active default template; each doctor of it can also have their own.</div></div></div>`;
        } else {
            const clash = docs.filter(d => d.other);
            html = `<div class="et-sum et-sum-doc"><i class="bi bi-person-badge"></i><div><span class="badge text-bg-warning me-1">Doctor-specific</span>
                Used only by ${docs.map(d => `<b>${esc(d.name)}</b>`).join(', ')}. Other doctors of ${specs.map(s => esc(s)).join(', ')} keep the speciality's default template.
                ${clash.length ? `<div class="small text-danger mt-1"><i class="bi bi-exclamation-triangle me-1"></i>${clash.map(d => `${esc(d.name)} already has “${esc(d.other)}”`).join('; ')} - a doctor can have only one active template.</div>` : ''}
                <div class="small text-muted mt-1">A consultation already saved keeps the template it was saved with.</div></div></div>`;
        }
        if (inactive) html += '<div class="small text-muted mt-2"><i class="bi bi-pause-circle me-1"></i>The template is inactive: nobody gets it until it is activated.</div>';
        $sum.html(html);
        $doc.prop('disabled', !specs.length);
    }

    let req = 0, specDefault = null;   // the speciality's current default template (another one), from the server
    async function loadDoctors() {
        const ids = specIds(), keep = new Set(($doc.val() || []).map(String)), mine = ++req;
        if (!ids.length) { specDefault = null; $doc.empty().trigger('change'); summary(); return; }
        const q = new URLSearchParams(); ids.forEach(i => q.append('specialityIds', i)); q.append('templateId', $doc.data('template-id') || 0); keep.forEach(d => q.append('doctorIds', d));
        let rows = [];
        try {
            const r = await fetch($doc.data('url') + '?' + q, { headers: { 'X-Requested-With': 'XMLHttpRequest' } });
            const j = r.ok ? await r.json() : null;
            rows = (j && j.doctors) || []; specDefault = (j && j.defaultTemplate) || null;
        } catch { rows = []; specDefault = null; }
        if (mine !== req) return;   // a newer change is on its way
        $doc.empty();
        rows.forEach(d => {
            const o = new Option(d.name, d.doctorId, false, keep.has(String(d.doctorId)));
            o.dataset.spec = d.specialityName || ''; o.dataset.other = d.otherTemplate || '';
            $doc.append(o);
        });
        const dropped = [...keep].filter(id => !rows.some(d => String(d.doctorId) === id)).length;
        $doc.trigger('change');
        summary();
        if (dropped && window.Swal) Swal.fire({ toast: true, position: 'top-end', timer: 3500, showConfirmButton: false, icon: 'info',
            title: `${dropped} doctor(s) removed: not of the chosen speciality.` });
    }

    $spec.on('change', loadDoctors);
    $doc.on('change', summary);
    $active.on('change', summary);
    summary();
    if (specIds().length) loadDoctors();   // the existing default of the speciality (Edit / copy) is known before saving
})();
