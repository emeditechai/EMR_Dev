/* Shimmer (skeleton) loading for report dashboards. No dependencies; injects its own styles once.
 *
 *   EmrShimmer.on(selector)            shimmer over existing elements (their content is hidden, not removed)
 *   EmrShimmer.off(selector)
 *   EmrShimmer.kpiCards(n)             HTML of n placeholder widgets (Bootstrap columns)
 *   EmrShimmer.chartBlock(heightPx)    HTML of one placeholder graph
 *   EmrShimmer.listBlock(rows, cols)   HTML of a placeholder list
 *   EmrShimmer.stage(steps, alive)     runs the steps one paint apart, in order: widgets, then graphs, then lists.
 *                                      alive() returning false (a newer load started) stops the remaining steps.
 */
window.EmrShimmer = (function () {
    const GAP_MS = 140;

    const css = `
@keyframes emr-sk-move { 0% { background-position: 100% 0; } 100% { background-position: -100% 0; } }
.emr-sk-bar, .emr-sk.is-loading::after {
    background: linear-gradient(100deg, #e9eef4 30%, #f6f8fb 50%, #e9eef4 70%);
    background-size: 200% 100%;
    animation: emr-sk-move 1.3s linear infinite;
}
.emr-sk.is-loading { position: relative; overflow: hidden; pointer-events: none; }
.emr-sk.is-loading > * { visibility: hidden !important; }
.emr-sk.is-loading::after { content: ""; position: absolute; inset: 0; border-radius: inherit; }
.emr-sk-card { background: #fff; border: 1px solid #e2e8f0; border-radius: .75rem; padding: .85rem 1rem; height: 100%; }
.emr-sk-bar { display: block; height: .7rem; border-radius: .35rem; margin-bottom: .55rem; }
.emr-sk-bar.lg { height: 1.4rem; }
.emr-sk-bar.sm { height: .55rem; margin-bottom: 0; }
.emr-sk-chart { display: flex; align-items: flex-end; gap: 2%; padding-top: .5rem; }
.emr-sk-chart > .emr-sk-bar { flex: 1; margin: 0; border-radius: .3rem .3rem 0 0; }
.emr-sk-list { padding: .25rem 1rem .75rem; }
.emr-sk-list .emr-sk-line { display: flex; gap: 1.25rem; padding: .7rem 0; border-bottom: 1px solid #eef2f6; }
.emr-sk-list .emr-sk-line > .emr-sk-bar { flex: 1; margin: 0; }
.emr-sk-list .emr-sk-line > .emr-sk-bar:first-child { flex: 0 0 2.5rem; }
@media (prefers-reduced-motion: reduce) { .emr-sk-bar, .emr-sk.is-loading::after { animation: none; } }
@media print { .emr-sk-gen { display: none !important; } .emr-sk.is-loading::after { display: none; } .emr-sk.is-loading > * { visibility: visible !important; } }
`;
    const style = document.createElement('style');
    style.setAttribute('data-emr-shimmer', '');
    style.textContent = css;
    document.head.appendChild(style);

    const all = selector => typeof selector === 'string' ? document.querySelectorAll(selector) : (selector.length !== undefined ? selector : [selector]);

    function on(selector) {
        Array.prototype.forEach.call(all(selector), el => { el.classList.add('emr-sk', 'is-loading'); el.setAttribute('aria-busy', 'true'); });
    }
    function off(selector) {
        Array.prototype.forEach.call(all(selector), el => { el.classList.remove('is-loading'); el.removeAttribute('aria-busy'); });
    }

    const widths = [55, 70, 40, 62, 48, 75, 58, 66];
    function kpiCards(n) {
        let html = '';
        for (let i = 0; i < n; i++) {
            html += `<div class="col-6 col-lg emr-sk-gen" aria-hidden="true"><div class="emr-sk-card">
                <span class="emr-sk-bar" style="width:${widths[i % widths.length]}%"></span>
                <span class="emr-sk-bar lg" style="width:${widths[(i + 3) % widths.length]}%"></span>
                <span class="emr-sk-bar sm" style="width:${widths[(i + 5) % widths.length]}%"></span></div></div>`;
        }
        return html;
    }

    const heights = [45, 70, 55, 85, 60, 95, 50, 75, 65, 88, 42, 72];
    function chartBlock(heightPx) {
        const h = heightPx || 200;
        return `<div class="emr-sk-card emr-sk-gen mb-2" aria-hidden="true" style="height:auto">
            <span class="emr-sk-bar" style="width:28%"></span>
            <div class="emr-sk-chart" style="height:${h}px">${heights.map(p => `<span class="emr-sk-bar" style="height:${p}%"></span>`).join('')}</div></div>`;
    }

    function listBlock(rows, cols) {
        const r = rows || 8, c = cols || 6;
        let html = '<div class="emr-sk-list emr-sk-gen" aria-hidden="true">';
        for (let i = 0; i < r; i++) {
            html += '<div class="emr-sk-line">';
            for (let j = 0; j < c; j++) html += '<span class="emr-sk-bar"></span>';
            html += '</div>';
        }
        return html + '</div>';
    }

    function stage(steps, alive) {
        let i = 0;
        const stillAlive = () => !alive || alive();
        (function next() {
            if (i >= steps.length || !stillAlive()) return;
            requestAnimationFrame(() => {
                if (!stillAlive()) return;
                try { steps[i](); }
                finally { i++; if (i < steps.length) setTimeout(next, GAP_MS); }
            });
        })();
    }

    return { on, off, kpiCards, chartBlock, listBlock, stage };
})();
