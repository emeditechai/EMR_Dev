// moved from Views/LabReporting/_DeltaTrendPopup.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
    (function () {
        let pop = null, owner = null, seq = 0;
        const H = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
        const num = v => { const n = parseFloat(String(v ?? '').replace(/,/g, '').trim()); return isFinite(n) && /^[-+]?[\d.,]+$/.test(String(v).trim()) ? n : null; };
        const fmt = n => (Math.round(n * 100) / 100).toString();

        function close() {
            pop?.remove(); pop = null;
            owner?.classList.remove('active'); owner?.setAttribute('aria-expanded', 'false');
            owner = null;
        }

        function flagOf(v, low, high) {
            if (v === null) return '';
            if (low !== null && v < low) return 'L';
            if (high !== null && v > high) return 'H';
            return '';
        }

        // oldest -> newest, left to right; normal range shaded; "Now" = the value typed in the row, when there is one
        function chart(points, low, high, unit) {
            const W = 336, Ht = 150, L = 38, R = 14, T = 18, B = 30;
            const vals = points.map(p => p.v).concat([low, high].filter(x => x !== null));
            let min = Math.min(...vals), max = Math.max(...vals);
            if (min === max) { min -= Math.abs(min) * 0.1 || 1; max += Math.abs(max) * 0.1 || 1; }
            const pad = (max - min) * 0.12; min -= pad; max += pad;
            const x = i => points.length === 1 ? (L + W - R) / 2 : L + i * (W - L - R) / (points.length - 1);
            const y = v => T + (max - v) * (Ht - T - B) / (max - min);

            let svg = `<svg class="dt-chart" viewBox="0 0 ${W} ${Ht}" role="img" aria-label="Trend of the last ${points.length} results">`;
            if (low !== null && high !== null) {
                svg += `<rect x="${L}" y="${y(high)}" width="${W - L - R}" height="${Math.max(1, y(low) - y(high))}" fill="#dcfce7" opacity="0.8"/>`;
            }
            [low, high].forEach(r => {
                if (r !== null) svg += `<line x1="${L}" x2="${W - R}" y1="${y(r)}" y2="${y(r)}" stroke="#16a34a" stroke-dasharray="3 3" stroke-width="1"/>`
                    + `<text x="${L - 4}" y="${y(r) + 3}" font-size="9" text-anchor="end" fill="#15803d">${H(fmt(r))}</text>`;
            });
            svg += `<line x1="${L}" x2="${L}" y1="${T - 6}" y2="${Ht - B}" stroke="#e2e8f0"/><line x1="${L}" x2="${W - R}" y1="${Ht - B}" y2="${Ht - B}" stroke="#e2e8f0"/>`;

            const hist = points.filter(p => !p.now);
            if (hist.length > 1) svg += `<polyline fill="none" stroke="#6366f1" stroke-width="2" stroke-linejoin="round" points="${hist.map((p) => `${x(points.indexOf(p))},${y(p.v)}`).join(' ')}"/>`;
            const nowP = points.find(p => p.now);
            if (nowP && hist.length) {
                const last = hist[hist.length - 1];
                svg += `<line x1="${x(points.indexOf(last))}" y1="${y(last.v)}" x2="${x(points.indexOf(nowP))}" y2="${y(nowP.v)}" stroke="#6366f1" stroke-width="1.5" stroke-dasharray="4 3"/>`;
            }
            points.forEach((p, i) => {
                const f = flagOf(p.v, low, high);
                const color = f === 'H' ? '#dc2626' : f === 'L' ? '#2563eb' : '#16a34a';
                svg += p.now
                    ? `<circle cx="${x(i)}" cy="${y(p.v)}" r="4.5" fill="#fff" stroke="${color}" stroke-width="2"/>`
                    : `<circle cx="${x(i)}" cy="${y(p.v)}" r="4" fill="${color}" stroke="#fff" stroke-width="1.5"/>`;
                svg += `<text x="${x(i)}" y="${y(p.v) - 8}" font-size="10" font-weight="700" text-anchor="middle" fill="#0f172a">${H(fmt(p.v))}</text>`;
                svg += `<text x="${x(i)}" y="${Ht - B + 13}" font-size="9" text-anchor="middle" fill="${p.now ? '#4f46e5' : '#64748b'}">${H(p.label)}</text>`;
            });
            if (unit) svg += `<text x="4" y="10" font-size="9" fill="#94a3b8">${H(unit)}</text>`;
            return svg + '</svg>';
        }

        function render(btn, items) {
            const low = num(btn.dataset.low), high = num(btn.dataset.high), unit = btn.dataset.unit || '';
            if (!items.length) return '<div class="dt-empty">No earlier results for this test.</div>';

            // graph: numeric results only, oldest first, plus the value being entered now
            const pts = items.slice().reverse().map(it => ({ v: num(it.value), label: (it.date || '').slice(0, 6) })).filter(p => p.v !== null);
            const nowInput = btn.closest('tr')?.querySelector('.result-val-numeric-input');
            const nowV = nowInput ? num(nowInput.value) : null;
            if (nowV !== null && pts.length) pts.push({ v: nowV, label: 'Now', now: true });

            let html = '';
            if (pts.filter(p => !p.now).length >= 1) {
                html += chart(pts, low, high, unit);
                html += `<div class="dt-legend">${low !== null && high !== null ? `<span><i style="background:#bbf7d0"></i>Normal ${H(fmt(low))} - ${H(fmt(high))}</span>` : ''}`
                      + `<span><i style="background:#16a34a"></i>Normal</span><span><i style="background:#dc2626"></i>High</span><span><i style="background:#2563eb"></i>Low</span>`
                      + (nowV !== null ? `<span><i style="background:#fff;border:2px solid #6366f1"></i>Now (not saved)</span>` : '') + `</div>`;
            } else {
                html += '<div class="dt-legend">These results are not numbers, so there is no graph.</div>';
            }

            html += '<table class="dt-table"><thead><tr><th>Date</th><th>Bill No</th><th class="dt-val">Result</th></tr></thead><tbody>';
            items.forEach(it => {
                const f = flagOf(num(it.value), low, high);
                html += `<tr><td>${H(it.date)}<div class="dt-bill">${H(it.time)}</div></td>`
                      + `<td class="dt-bill">${H(it.billNo)}${it.approved ? '' : ' <span title="Not approved yet">*</span>'}</td>`
                      + `<td class="dt-val">${H(it.value)} <span class="dt-bill">${H(it.unit || unit)}</span>${f ? `<span class="dt-flag dt-flag-${f}">${f}</span>` : ''}</td></tr>`;
            });
            html += '</tbody></table>';
            if (items.some(it => !it.approved)) html += '<div class="dt-legend mt-1 mb-0">* result not approved yet</div>';
            return html;
        }

        function place(btn) {
            const r = btn.getBoundingClientRect(), w = pop.offsetWidth, h = pop.offsetHeight;
            let left = window.scrollX + r.left + r.width / 2 - w / 2;
            left = Math.max(window.scrollX + 12, Math.min(left, window.scrollX + document.documentElement.clientWidth - w - 12));
            const below = r.bottom + 8 + h <= window.innerHeight || r.top - 8 - h < 0;
            pop.style.left = left + 'px';
            pop.style.top = (window.scrollY + (below ? r.bottom + 8 : r.top - 8 - h)) + 'px';
        }

        async function open(btn) {
            close();
            owner = btn; btn.classList.add('active'); btn.setAttribute('aria-expanded', 'true');
            const my = ++seq;
            pop = document.createElement('div');
            pop.className = 'dt-pop';
            pop.setAttribute('role', 'dialog');
            pop.innerHTML = `<div class="dt-pop-head"><i class="bi bi-graph-up text-primary"></i>
                    <div class="dt-title">${H(btn.dataset.name)}<div class="dt-sub">Last 5 results${btn.dataset.unit ? ' (' + H(btn.dataset.unit) + ')' : ''}</div></div>
                    <button type="button" class="dt-pop-close" aria-label="Close">&times;</button></div>
                <div class="dt-pop-body"><div class="dt-empty"><span class="spinner-border spinner-border-sm me-1"></span>Loading...</div></div>`;
            document.body.appendChild(pop);
            pop.querySelector('.dt-pop-close').addEventListener('click', close);
            place(btn);

            let body;
            try {
                const res = await fetch(`/LabReporting/DeltaHistoryJson?labOrderId=${encodeURIComponent(btn.dataset.order)}&investigationId=${encodeURIComponent(btn.dataset.inv)}`,
                    { headers: { 'X-Requested-With': 'XMLHttpRequest', 'Accept': 'application/json' } });
                const data = await res.json();
                body = data.success ? render(btn, data.items || []) : `<div class="dt-empty">${H(data.message || 'Previous results could not be loaded.')}</div>`;
            } catch {
                body = '<div class="dt-empty">Previous results could not be loaded.</div>';
            }
            if (my !== seq || !pop) return;
            pop.querySelector('.dt-pop-body').innerHTML = body;
            place(btn);
        }

        document.addEventListener('click', function (e) {
            const btn = e.target.closest('.delta-trend-btn');
            if (btn) { e.preventDefault(); e.stopPropagation(); btn === owner ? close() : open(btn); return; }
            if (pop && !pop.contains(e.target)) close();
        });
        document.addEventListener('keydown', e => { if (e.key === 'Escape' && pop) { const b = owner; close(); b?.focus(); } });
        window.addEventListener('resize', () => { if (pop && owner) place(owner); });
    })();
