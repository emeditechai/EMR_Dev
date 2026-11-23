/* LAB billing > AI Prescription Assist: mark the area of the tests on the preview (drag a box). The area goes to the server
   as fractions "x,y,w,h" of the page; only that area is read, every word of it - far more reliable on a busy prescription.
   A PDF's first page is rendered on the server for the preview. No box = the whole page, as before. */
(function () {
    'use strict';
    const box = document.getElementById('rxCropBox'), img = document.getElementById('rxPreview');
    if (!box || !img) return;
    let sel = null, start = null, area = null, isRealImage = false;

    function ensureSel() {
        if (sel) return sel;
        sel = document.createElement('div');
        sel.style.cssText = 'position:absolute;border:2px solid #2563eb;background:rgba(37,99,235,.12);border-radius:4px;pointer-events:none;display:none;box-shadow:0 0 0 9999px rgba(15,23,42,.35)';
        box.appendChild(sel);
        const clearBtn = document.createElement('button');
        clearBtn.type = 'button'; clearBtn.className = 'btn btn-sm btn-light border position-absolute'; clearBtn.id = 'rxCropClear';
        clearBtn.style.cssText = 'top:6px;right:6px;display:none;font-size:.75rem'; clearBtn.innerHTML = '<i class="bi bi-x-lg me-1"></i>Whole page';
        clearBtn.addEventListener('click', e => { e.preventDefault(); clear(); });
        box.appendChild(clearBtn);
        return sel;
    }
    function hint(text) { const h = document.getElementById('rxCropHint'); if (h) h.innerHTML = text; }
    function clear() {
        area = null;
        if (sel) sel.style.display = 'none';
        const c = document.getElementById('rxCropClear'); if (c) c.style.display = 'none';
        hint(isRealImage ? '<i class="bi bi-bounding-box me-1"></i>Drag a box around the tests for the best reading' : '');
    }
    function pos(e) {
        const r = img.getBoundingClientRect();
        const p = e.touches ? e.touches[0] : e;
        return { x: Math.min(Math.max(p.clientX - r.left, 0), r.width), y: Math.min(Math.max(p.clientY - r.top, 0), r.height), w: r.width, h: r.height };
    }
    function draw(a, b) {
        const s = ensureSel();
        const x = Math.min(a.x, b.x), y = Math.min(a.y, b.y), w = Math.abs(a.x - b.x), h = Math.abs(a.y - b.y);
        s.style.left = (img.offsetLeft + x) + 'px'; s.style.top = (img.offsetTop + y) + 'px'; s.style.width = w + 'px'; s.style.height = h + 'px'; s.style.display = 'block';
        return { x, y, w, h };
    }
    function down(e) {
        if (!isRealImage) return;
        e.preventDefault(); start = pos(e);
    }
    function move(e) { if (!start) return; e.preventDefault(); draw(start, pos(e)); }
    function up(e) {
        if (!start) return;
        const end = e.changedTouches ? (() => { const r = img.getBoundingClientRect(), t = e.changedTouches[0]; return { x: Math.min(Math.max(t.clientX - r.left, 0), r.width), y: Math.min(Math.max(t.clientY - r.top, 0), r.height), w: r.width, h: r.height }; })() : pos(e);
        const r = draw(start, end); start = null;
        if (r.w < end.w * 0.05 || r.h < end.h * 0.03) { clear(); return; }   // a click, not a box
        area = [r.x / end.w, r.y / end.h, r.w / end.w, r.h / end.h].map(v => Math.round(v * 10000) / 10000);
        document.getElementById('rxCropClear').style.display = 'inline-block';
        hint('<i class="bi bi-check2-circle me-1 text-success"></i>Only the marked area will be read · drag again to change');
    }
    img.addEventListener('mousedown', down); window.addEventListener('mousemove', move); window.addEventListener('mouseup', up);
    img.addEventListener('touchstart', down, { passive: false }); window.addEventListener('touchmove', move, { passive: false }); window.addEventListener('touchend', up);
    img.addEventListener('load', () => {
        isRealImage = !/^data:image\/svg/.test(img.src);
        img.style.cursor = isRealImage ? 'crosshair' : 'default';
        clear();
    });

    async function pdfPreview(file, url) {
        const fd = new FormData();
        fd.append('prescription', file);
        fd.append('__RequestVerificationToken', (document.querySelector('input[name="__RequestVerificationToken"]') || {}).value || '');
        try {
            const r = await fetch(url, { method: 'POST', body: fd, headers: { 'X-Requested-With': 'XMLHttpRequest' } });
            if (!r.ok) return;
            const blob = await r.blob();
            img.src = URL.createObjectURL(blob);
        } catch { /* the document icon stays: the whole page is read */ }
    }

    window.RxCrop = { value: () => area ? area.join(',') : '', clear, pdfPreview };
})();
