/*
 * Utility > Help Center (SQLScripts/2300): the AI Help Assistant and the help drawer of every page.
 *   HelpAssistant.mount(containerElement, { pageCode, suggestions, placeholder, big })  - ask in plain words; the answer
 *       shows the steps, the screens to open, and where the step sits in the application's workflow (what comes next / before)
 *   HelpAssistant.flowHtml(workflow, { compact })  - a workflow as a stepper (done / you are here / next / optional)
 *   the drawer opens from the floating "Ask AI" button (Home dashboard), with the assistant on top and help for the current
 *   screen (the drawer's data-controller / data-action) below it
 */
(function () {
    'use strict';
    const H = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
    const token = () => document.querySelector('#emrHelpToken input[name="__RequestVerificationToken"]')?.value
                     || document.querySelector('input[name="__RequestVerificationToken"]')?.value || '';
    const articleUrl = code => (code || '').startsWith('PAGE:') ? '/Help/Page/' + encodeURIComponent(code.substring(5)) : '/Help/Article/' + encodeURIComponent(code || '');
    const linkHtml = l => {
        if (!l) return '';
        if ((l.note || '') === 'PAGE' || (l.code || '').startsWith('PAGE:') || l.url) {
            const code = (l.code || '').replace(/^PAGE:/, '');
            return `<a href="/Help/Page/${encodeURIComponent(code)}">${H(l.title)}</a>${l.path ? ` <span class="hp-muted">${H(l.path)}</span>` : ''}`;
        }
        return `<a href="${articleUrl(l.code)}">${l.note === 'FLOW' ? '<i class="bi bi-diagram-3 me-1"></i>' : ''}${H(l.title)}</a>`;
    };
    const kindLabel = k => ({ GUIDE: 'Guide', FAQ: 'FAQ', TROUBLE: 'Troubleshooting', PAGE: 'Screen', NEXT: 'Next step', BEFORE: 'Do this first', FLOW: 'Workflow' })[k] || '';

    async function post(url, data) {
        const body = new URLSearchParams(Object.assign({ __RequestVerificationToken: token() }, data));
        const r = await fetch(url, { method: 'POST', body, headers: { 'X-Requested-With': 'XMLHttpRequest' }, credentials: 'same-origin' });
        if (!r.ok) throw new Error('HTTP ' + r.status);
        return r.json();
    }

    /** A workflow as a stepper: done steps, the step asked about ("You are here"), the answer step ("Next" / "Do this first"). */
    function flowHtml(wf, opts) {
        if (!wf || !(wf.steps || []).length) return '';
        opts = opts || {};
        const cur = wf.current ?? -1, hi = wf.highlight ?? -1;
        const items = wf.steps.map((s, i) => {
            const cls = [i === cur ? 'is-current' : '', i === hi ? 'is-target' : '', cur >= 0 && i < cur && i !== hi ? 'is-done' : '', s.optional ? 'is-optional' : ''].join(' ');
            const tag = i === cur ? '<span class="hp-flow-tag hp-flow-tag-here">You are here</span>'
                      : i === hi ? `<span class="hp-flow-tag hp-flow-tag-next">${hi > cur ? 'Next' : 'Do this first'}</span>` : '';
            const title = s.page && s.page.url ? `<a href="${H(s.page.url)}" title="Open ${H(s.page.title)}">${H(s.title)}</a>` : H(s.title);
            const showDo = !opts.compact || i === cur || i === hi;
            return `<li class="${cls}"><span class="hp-flow-dot">${cur >= 0 && i < cur && i !== hi ? '<i class="bi bi-check-lg"></i>' : i + 1}</span>
                <div class="hp-flow-body"><div class="hp-flow-title">${title} ${tag}</div>
                ${s.optional && s.when ? `<div class="hp-flow-when"><i class="bi bi-signpost"></i> ${H(s.when)}</div>` : ''}
                ${showDo ? `<div class="hp-flow-do">${H(s.do)}${s.page && s.page.path ? ` <span class="hp-muted">· ${H(s.page.path)}</span>` : ''}</div>` : ''}</div></li>`;
        }).join('');
        return `<div class="hp-flow${opts.compact ? ' hp-flow-compact' : ''}">
            ${opts.noHead ? '' : `<div class="hp-flow-head"><i class="bi bi-diagram-3"></i> ${opts.label ? H(opts.label) + ': ' : ''}<a href="${articleUrl(wf.code)}">${H(wf.title)}</a></div>`}
            <ol class="hp-flow-steps">${items}</ol></div>`;
    }

    /** A data answer (SQLScripts/2321): key facts, a small table (rows open their record) and actions such as Open Bill. */
    function dataHtml(a) {
        const d = a.data || {};
        const safe = u => (typeof u === 'string' && u.startsWith('/') && !u.startsWith('//')) ? u : '#';
        const facts = (d.facts || []).length ? `<div class="hp-facts">${d.facts.map(f => `<div class="hp-fact"><span>${H(f.label)}</span><b class="${f.tone ? 'hp-tone-' + H(f.tone) : ''}">${H(f.value)}</b></div>`).join('')}</div>` : '';
        const table = (d.rows || []).length ? `<div class="hp-data-table"><table><thead><tr>${(d.columns || []).map(c => `<th>${H(c)}</th>`).join('')}</tr></thead><tbody>${
            d.rows.map(r => `<tr${r.url ? ` class="hp-row-link" data-url="${H(safe(r.url))}"` : ''}>${(r.cells || []).map(c => `<td>${H(c)}</td>`).join('')}</tr>`).join('')}</tbody></table></div>` : '';
        const actions = (d.actions || []).length ? `<div class="hp-chips">${d.actions.map(x => `<a class="hp-chip${x.primary ? ' hp-chip-primary' : ''}" href="${H(safe(x.url))}"${x.primary ? ' target="_blank" rel="noopener"' : ''}><i class="bi ${H(x.icon || 'bi-box-arrow-up-right')}"></i> ${H(x.title)}</a>`).join('')}</div>` : '';
        return `<div class="hp-answer hp-answer-data">
            <div class="hp-answer-head"><span class="hp-kind hp-kind-DATA"><i class="bi bi-database"></i> Live data</span><span class="hp-answer-title">${H(a.title)}</span></div>
            <div class="hp-answer-text">${H(a.text)}</div>${facts}${table}${actions}
            ${d.note ? `<div class="hp-muted small mt-2">${H(d.note)}</div>` : ''}
        </div>`;
    }

    function answerHtml(a, question) {
        if (a.kind === 'DATA') return dataHtml(a);
        if (!a.found) {
            return `<div class="hp-answer hp-answer-miss"><div class="hp-answer-text"><i class="bi bi-search me-1"></i>${H(a.text)}</div>
                ${(a.related || []).length ? `<div class="hp-answer-sub">Maybe one of these:</div><ul class="hp-links">${a.related.map(l => `<li>${linkHtml(l)}</li>`).join('')}</ul>` : ''}</div>`;
        }
        const flowFirst = a.kind === 'NEXT' || a.kind === 'BEFORE' || a.kind === 'FLOW';
        // the closest other topics, offered at once (choosing one also teaches the assistant)
        const alts = flowFirst ? [] : (a.related || []).filter(l => !(l.code || '').startsWith('FLOW.') && l.note !== 'FLOW').slice(0, 3);
        const wf = a.workflow ? flowHtml(a.workflow, { compact: a.kind !== 'FLOW', label: flowFirst ? 'Workflow' : 'Where this fits' }) : '';
        return `<div class="hp-answer">
            <div class="hp-answer-head"><span class="hp-kind hp-kind-${H(a.kind)}">${kindLabel(a.kind)}</span>
                ${a.source === 'AI' ? '<span class="hp-ai"><i class="bi bi-stars"></i> AI answer from the help content</span>' : ''}
                ${a.learned ? '<span class="hp-learned" title="Your team confirmed this answer, or an administrator taught it"><i class="bi bi-mortarboard"></i> Learned</span>' : ''}
                <a class="hp-answer-title" href="${articleUrl(a.code)}">${H(a.title)}</a></div>
            <div class="hp-answer-text">${H(a.text).replace(/\n/g, '<br>')}</div>
            ${alts.length ? `<div class="hp-alts hp-related" data-q="${H(question)}"><span>Not what you asked?</span>${alts.map(l => `<span data-code="${H(l.code)}">${linkHtml(Object.assign({}, l, { path: null }))}</span>`).join('')}</div>` : ''}
            ${a.kind !== 'FLOW' && a.source !== 'AI' && (a.steps || []).length ? `<div class="hp-answer-sub">${a.kind === 'NEXT' || a.kind === 'BEFORE' ? 'How to do it' : 'Steps'}</div><ol class="hp-steps">${a.steps.map(s => `<li>${H(s)}</li>`).join('')}</ol>` : ''}
            ${(a.pages || []).length && a.kind !== 'FLOW' ? `<div class="hp-answer-sub">Go to</div><div class="hp-chips">${a.pages.map(p => p.url ? `<a class="hp-chip" href="${H(p.url)}"><i class="bi bi-box-arrow-up-right"></i> ${H(p.title)}</a>` : '').join('')}</div>` : ''}
            ${wf}
            ${(a.related || []).length ? `<div class="hp-answer-sub">Related</div><ul class="hp-links hp-related" data-q="${H(question)}">${a.related.map(l => `<li data-code="${H(l.code)}">${linkHtml(l)}</li>`).join('')}</ul>` : ''}
            <div class="hp-feedback" data-code="${H(a.code)}" data-q="${H(question)}" data-kind="${H(a.kind)}" data-intent="${H(a.intent)}">Did this answer your question?
                <button type="button" class="btn btn-sm btn-outline-success" data-helpful="true"><i class="bi bi-hand-thumbs-up"></i> Yes</button>
                <button type="button" class="btn btn-sm btn-outline-secondary" data-helpful="false"><i class="bi bi-hand-thumbs-down"></i> No</button></div>
        </div>`;
    }

    function mount(el, opts) {
        opts = opts || {};
        const pageCode = () => (typeof opts.pageCode === 'function' ? opts.pageCode() : opts.pageCode) || '';
        el.innerHTML = `<form class="hp-ask${opts.big ? ' hp-ask-big' : ''}" autocomplete="off">
                <span class="hp-ask-icon"><i class="bi bi-stars"></i></span>
                <input type="text" class="form-control" maxlength="400" placeholder="${H(opts.placeholder || 'Ask anything - e.g. after creating a B2C bill, what is next?')}" aria-label="Ask the AI Help Assistant" />
                <button type="submit" class="btn hp-ask-btn"><i class="bi bi-send"></i><span class="d-none d-sm-inline ms-1">Ask</span></button>
            </form>
            ${opts.suggestions ? `<div class="hp-suggest">${opts.suggestions.map(s => `<button type="button" class="hp-suggest-chip">${H(s)}</button>`).join('')}</div>` : ''}
            <div class="hp-thread"></div>`;
        const form = el.querySelector('form'), input = el.querySelector('input'), thread = el.querySelector('.hp-thread');
        async function ask(q) {
            q = (q || '').trim();
            if (!q) return;
            const item = document.createElement('div');
            item.className = 'hp-qa';
            item.innerHTML = `<div class="hp-q"><i class="bi bi-person-circle"></i> ${H(q)}</div><div class="hp-a"><span class="hp-typing"><span></span><span></span><span></span></span> Thinking...</div>`;
            thread.prepend(item);
            try {
                const a = await post('/Help/Ask', { question: q, pageCode: pageCode() });
                item.querySelector('.hp-a').innerHTML = answerHtml(a, q);
                // "open bill LAB/HO2627000295": the bill opens at once (the Open Bill button stays if the browser blocks it)
                if (a.openUrl && a.openUrl.startsWith('/') && !a.openUrl.startsWith('//')) { try { window.open(a.openUrl, '_blank', 'noopener'); } catch (x) { } }
            } catch (e) {
                item.querySelector('.hp-a').innerHTML = '<div class="text-danger small">The assistant could not answer right now. Please try again.</div>';
            }
        }
        form.addEventListener('submit', e => { e.preventDefault(); ask(input.value); input.value = ''; });
        el.querySelectorAll('.hp-suggest-chip').forEach(b => b.addEventListener('click', () => ask(b.textContent)));
        el.addEventListener('click', async e => {
            const b = e.target.closest('.hp-feedback button');
            if (!b) return;
            const box = b.closest('.hp-feedback'), helpful = b.dataset.helpful === 'true';
            box.innerHTML = helpful ? '<span class="text-success"><i class="bi bi-check-circle"></i> Thanks - glad it helped.</span>'
                                    : '<span class="hp-muted"><i class="bi bi-info-circle"></i> Thanks - this question is passed to the administrator to improve the help. Try other words or browse the modules.</span>';
            try { await post('/Help/Feedback', { articleCode: box.dataset.code, question: box.dataset.q, pageCode: pageCode(), helpful, kind: box.dataset.kind || '', intent: box.dataset.intent || '' }); } catch (x) { }
        });
        // a row of a data answer opens its record (a bill, a patient)
        el.addEventListener('click', e => {
            const tr = e.target.closest('.hp-row-link');
            if (tr && tr.dataset.url && tr.dataset.url !== '#') window.open(tr.dataset.url, '_blank', 'noopener');
        });
        // a related topic opened from an answer: the assistant learns that it answers the question
        el.addEventListener('click', e => {
            const a = e.target.closest('.hp-related [data-code] a');
            if (!a) return;
            const li = a.closest('[data-code]'), q = a.closest('.hp-related').dataset.q;
            if (!li.dataset.code || li.dataset.code.startsWith('FLOW.')) return;
            const body = new URLSearchParams({ __RequestVerificationToken: token(), articleCode: li.dataset.code, question: q, pageCode: pageCode(), signal: 'CLICK' });
            try { navigator.sendBeacon ? navigator.sendBeacon('/Help/Feedback', body) : fetch('/Help/Feedback', { method: 'POST', body, credentials: 'same-origin', keepalive: true }); } catch (x) { }
        });
        return { ask, focus: () => input.focus() };
    }

    window.HelpAssistant = { mount, linkHtml, flowHtml };

    // workflows rendered by the help pages: <div class="hp-flow-host" data-flow="{json}" data-label="..." data-compact="1" data-big="1">
    document.addEventListener('DOMContentLoaded', function () {
        document.querySelectorAll('.hp-flow-host[data-flow]').forEach(el => {
            try {
                el.innerHTML = flowHtml(JSON.parse(el.dataset.flow), { compact: el.dataset.compact === '1', label: el.dataset.label, noHead: el.dataset.nohead === '1' });
                if (el.dataset.big === '1') el.firstElementChild?.classList.add('hp-flow-big');
            } catch (e) { }
        });
    });

    // ── the drawer of every page: the assistant on top, help for this screen below ──
    document.addEventListener('DOMContentLoaded', function () {
        const drawer = document.getElementById('emrHelpDrawer');   // carries the screen (data-controller / data-action)
        if (!drawer || !window.bootstrap) return;
        const body = drawer.querySelector('.hp-drawer-body'), askHost = drawer.querySelector('.hp-drawer-ask');
        let page = null, loaded = false, assistant = null;
        assistant = mount(askHost, {
            pageCode: () => page ? page.pageCode : '',
            placeholder: 'Ask anything about your work...',
            suggestions: ['What do I do after this screen?', 'What must be done before this?', 'Show the whole workflow']
        });
        drawer.addEventListener('shown.bs.offcanvas', () => assistant.focus());
        // open the panel and ask (the Ask AI box of the Home dashboard)
        window.HelpAssistant.askInPanel = q => { bootstrap.Offcanvas.getOrCreateInstance(drawer).show(); assistant.ask(q); };
        document.getElementById('homeAsk')?.addEventListener('submit', e => {
            e.preventDefault();
            const input = document.getElementById('homeAskInput');
            if (!input.value.trim()) { input.focus(); return; }
            window.HelpAssistant.askInPanel(input.value);
            input.value = '';
        });
        drawer.addEventListener('show.bs.offcanvas', async function () {
            if (loaded) return;
            loaded = true;
            try {
                const r = await fetch(`/Help/ForScreen?screen=${encodeURIComponent(drawer.dataset.controller || '')}&view=${encodeURIComponent(drawer.dataset.action || '')}`,
                    { headers: { 'X-Requested-With': 'XMLHttpRequest' }, credentials: 'same-origin' });
                const d = await r.json();
                page = d.found ? d.page : null;
                body.innerHTML = page ? pageHtml(page) : `<p class="hp-muted mb-0">No help is written for this screen yet - ask above or open the Help Center.</p>`;
            } catch (e) {
                body.innerHTML = '<p class="text-danger small">Help could not be loaded.</p>';
            }
        });
        // the floating button opens the same drawer
        document.getElementById('emrAskFab')?.addEventListener('click', () => bootstrap.Offcanvas.getOrCreateInstance(drawer).show());
    });

    function pageHtml(p) {
        const list = (items, f) => items.map(f).join('');
        const guide = (p.guides || [])[0];
        let h = `<div class="hp-crumb">${H(p.path)}</div><h3 class="hp-drawer-title">${H(p.title)}</h3>`;
        const wf = (p.workflows || [])[0];
        if (wf) h += flowHtml(wf, { compact: true, label: 'Where this screen fits' });
        if ((p.before || []).length) h += `<div class="hp-box hp-box-before mt-2"><div class="hp-box-title"><i class="bi bi-signpost-split"></i> Must be ready first</div><ul class="hp-links">${list(p.before.slice(0, 6), l => `<li>${linkHtml(l)}${l.note ? ` <span class="hp-muted">- ${H(l.note)}</span>` : ''}</li>`)}</ul></div>`;
        const steps = guide ? guide.steps : (p.generalSteps || []);
        h += `<div class="hp-box-title mt-3"><i class="bi bi-list-ol"></i> ${H(guide ? guide.title : 'How to use this page')}</div>`;
        h += `<ol class="hp-steps">${list(steps, s => `<li>${H(s)}</li>`)}</ol>`;
        if (guide && guide.tips.length) h += `<div class="hp-tips">${list(guide.tips, t => `<div><i class="bi bi-lightbulb"></i> ${H(t)}</div>`)}</div>`;
        if ((p.guides || []).length > 1) h += `<div class="hp-answer-sub">More guides</div><ul class="hp-links">${list(p.guides.slice(1), g => `<li><a href="/Help/Article/${encodeURIComponent(g.code)}">${H(g.title)}</a></li>`)}</ul>`;
        if ((p.actions || []).length) h += `<div class="hp-answer-sub">What you can do here</div><div class="hp-chips">${list(p.actions, a => `<span class="hp-chip hp-chip-plain">${H(a)}</span>`)}</div>`;
        if ((p.troubles || []).length) h += `<div class="hp-answer-sub">Problems?</div><ul class="hp-links">${list(p.troubles.slice(0, 4), l => `<li>${linkHtml(l)}</li>`)}</ul>`;
        if ((p.faqs || []).length) h += `<div class="hp-answer-sub">FAQs</div><ul class="hp-links">${list(p.faqs.slice(0, 4), l => `<li>${linkHtml(l)}</li>`)}</ul>`;
        h += `<a class="btn btn-sm btn-outline-primary mt-2" href="/Help/Page/${encodeURIComponent(p.pageCode)}"><i class="bi bi-book me-1"></i>Full help for this page</a>`;
        return h;
    }
})();
