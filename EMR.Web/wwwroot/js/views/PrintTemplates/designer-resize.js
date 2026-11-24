// Print Templates designer: free sizing by mouse drag (head office only).
//   - every block (data field, text, page number, logo, image, barcode, line): its side edge sets its own width as a % of
//     its column, so e.g. the NABH line can be made narrower without shrinking the column and the blocks beside it.
//     Left- / centre-aligned blocks: the right edge; right-aligned blocks: the left edge. Double-click the edge: full width.
//   - every row: its bottom-left edge sets the row's lowest height (mm). Double-click: back to "as tall as its content".
// The designer (Views/PrintTemplates/Designer.cshtml) calls PdResize.attach after each canvas render.
(function () {
    'use strict';

    const SIZED = ['field', 'text', 'pageinfo', 'logo', 'image'];   // the block's box takes Width % (PrintLayout.SizedBox)
    const WIDTH = SIZED.concat(['barcode', 'line']);                  // these two apply Width % to what they draw
    const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));
    const fmt = n => (Math.round(n * 10) / 10).toString();

    function tipFor(el) { const t = document.createElement('div'); t.className = 'pd-tip'; el.appendChild(t); return t; }

    function blockWidth(canvas, api) {
        canvas.querySelectorAll('.ptpl-block[data-path]').forEach(blockEl => {
            const s = api.parse(blockEl.dataset.path), b = s.block;
            if (!b || !WIDTH.includes(b.type)) return;
            const right = b.align === 'right', centre = b.align === 'center';
            const h = api.handle('pd-h-w ' + (right ? 'pd-h-w-left' : 'pd-h-w-right'),
                'Drag to change the width of this block (double-click: full width of the column)');
            blockEl.appendChild(h);
            h.addEventListener('dblclick', ev => {
                ev.preventDefault(); ev.stopPropagation();
                if ((b.widthPct || 100) >= 100) return;
                api.select(blockEl.dataset.path); api.change(() => b.widthPct = 100);
            });
            h.addEventListener('mousedown', ev => {
                if (ev.button !== 0) return;
                const colEl = blockEl.closest('.ptpl-col'), cs = getComputedStyle(colEl);
                const colW = colEl.clientWidth - parseFloat(cs.paddingLeft) - parseFloat(cs.paddingRight);
                const w0 = b.widthPct || 100, sign = right ? -1 : 1, factor = centre ? 2 : 1;
                const tip = tipFor(blockEl);
                const calc = dx => clamp(Math.round((w0 + sign * factor * dx / colW * 100) * 2) / 2, 5, 100);
                api.track(ev, dx => {
                    const n = calc(dx);
                    if (SIZED.includes(b.type)) {
                        blockEl.style.width = n + '%';
                        blockEl.style.alignSelf = right ? 'flex-end' : centre ? 'center' : 'flex-start';
                    } else if (b.type === 'line') {
                        const line = blockEl.firstElementChild; if (line) line.style.width = n + '%';
                    }
                    tip.textContent = `width ${fmt(n)}% of the column (${fmt(n / 100 * colW / api.pxPerMm())} mm)`;
                }, dx => {
                    const n = calc(dx);
                    if (n === w0) { api.render(); return; }
                    api.select(blockEl.dataset.path);
                    api.change(() => b.widthPct = n);
                }, 'ew-resize');
            });
        });
    }

    function rowHeight(canvas, api) {
        canvas.querySelectorAll('.ptpl-row[data-path]').forEach(rowEl => {
            const s = api.parse(rowEl.dataset.path), row = s.row;
            if (!row) return;
            const h = api.handle('pd-h-rowh', 'Drag to set the height of this row (double-click: as tall as its content)');
            rowEl.appendChild(h);
            h.addEventListener('dblclick', ev => {
                ev.preventDefault(); ev.stopPropagation();
                if (!row.minHeightMm) return;
                api.select(rowEl.dataset.path); api.change(() => row.minHeightMm = 0);
            });
            h.addEventListener('mousedown', ev => {
                if (ev.button !== 0) return;
                const ppm = api.pxPerMm(), start = rowEl.getBoundingClientRect().height / ppm, h0 = row.minHeightMm || 0;
                const tip = tipFor(rowEl);
                const calc = dy => clamp(Math.round((start + dy / ppm) * 2) / 2, 0, 60);
                api.track(ev, (dx, dy) => { const mm = calc(dy); rowEl.style.minHeight = mm + 'mm'; tip.textContent = 'row at least ' + fmt(mm) + ' mm'; },
                    (dx, dy) => {
                        if (Math.abs(dy) < 3) { api.render(); return; }
                        const mm = calc(dy);
                        if (mm === h0) { api.render(); return; }
                        api.select(rowEl.dataset.path);
                        api.change(() => row.minHeightMm = mm);
                    }, 'ns-resize');
            });
        });
    }

    window.PdResize = {
        attach(canvas, api) { blockWidth(canvas, api); rowHeight(canvas, api); }
    };
})();
