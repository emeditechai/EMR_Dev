/* Pharmacy > Sales > Sales Dashboard (SQLScripts/2568): daily trend by channel, money by payment mode, the custom
   date fields and clickable document rows. Data: <script type="application/json" id="psdData"> in the view. */
(function () {
    'use strict';
    const root = document.querySelector('.psd');
    const raw = document.getElementById('psdData');
    if (!root || !raw) return;
    const data = JSON.parse(raw.textContent || '{}');
    const inr = v => '₹ ' + Number(v || 0).toLocaleString('en-IN', { maximumFractionDigits: 0 });
    const css = getComputedStyle(root);
    const col = name => (css.getPropertyValue(name) || '').trim();
    const colors = { pos: col('--pos') || '#644098', direct: col('--direct') || '#0ea5e9', ipd: col('--ipd') || '#10b981' };

    // custom range: the dates show only for "Custom"
    const range = document.getElementById('psdRange');
    const custom = document.querySelectorAll('.psd-custom');
    const sync = () => custom.forEach(el => el.classList.toggle('d-none', range && range.value !== 'custom'));
    range?.addEventListener('change', () => { sync(); if (range.value !== 'custom') range.form.submit(); });
    sync();

    // rows open their bill / IPD patient
    document.querySelectorAll('.psd tr[data-href]').forEach(tr =>
        tr.addEventListener('click', e => { if (!e.target.closest('a,button')) window.location.href = tr.dataset.href; }));

    if (!window.Chart) return;
    const days = data.days || [];
    const trend = document.getElementById('psdTrend');
    if (trend && days.length) new Chart(trend, {
        type: 'bar',
        data: {
            labels: days.map(x => x.d),
            datasets: [
                { label: 'POS', data: days.map(x => x.pos), backgroundColor: colors.pos, borderRadius: 4, stack: 's', maxBarThickness: 26 },
                { label: 'Direct', data: days.map(x => x.direct), backgroundColor: colors.direct, borderRadius: 4, stack: 's', maxBarThickness: 26 },
                { label: 'IPD', data: days.map(x => x.ipd), backgroundColor: colors.ipd, borderRadius: 4, stack: 's', maxBarThickness: 26 }
            ]
        },
        options: {
            maintainAspectRatio: false, interaction: { mode: 'index', intersect: false },
            plugins: {
                legend: { position: 'bottom', labels: { usePointStyle: true, boxWidth: 8 } },
                tooltip: { callbacks: { label: c => c.dataset.label + ': ' + inr(c.parsed.y), footer: items => 'Total: ' + inr(items.reduce((a, i) => a + i.parsed.y, 0)) } }
            },
            scales: {
                x: { stacked: true, grid: { display: false }, ticks: { maxRotation: 0, autoSkip: true, maxTicksLimit: 12 } },
                y: { stacked: true, beginAtZero: true, ticks: { callback: v => v >= 1000 ? (v / 1000) + 'k' : v }, grid: { color: '#f1f5f9' } }
            }
        }
    });

    const modes = data.modes || [];
    const pie = document.getElementById('psdModes');
    if (pie && modes.length) new Chart(pie, {
        type: 'doughnut',
        data: { labels: modes.map(x => x.m), datasets: [{ data: modes.map(x => x.a), backgroundColor: [colors.pos, '#10b981', colors.direct, '#f59e0b', '#ef4444', '#64748b', '#a855f7'], borderWidth: 0 }] },
        options: { maintainAspectRatio: false, cutout: '66%', plugins: { legend: { position: 'right', labels: { usePointStyle: true, boxWidth: 8 } }, tooltip: { callbacks: { label: c => c.label + ': ' + inr(c.parsed) } } } }
    });
})();
