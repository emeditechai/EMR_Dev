/*
 * Email composer (Utility > Campaigns, SQLScripts/2299): heading, rich message with merge-field chips, details rows,
 * note and closing - the same design format as Utility > Email Templates (EmailTemplateDesigner on the server).
 * Markup: Views/Shared/_EmailComposer.cshtml. Needs jQuery, Bootstrap and Quill 1.3.
 *
 *   const c = EmailComposer.init({ fields: [{code,label,sample}], design: {...}, onChange: fn });
 *   c.getDesign(); c.setDesign(d); c.setFields(f); c.insertInto(inputElement, code);
 */
(function () {
    'use strict';
    const H = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
    let registered = false;

    function init(opts) {
        let fields = opts.fields || [];
        const onChange = opts.onChange || function () { };
        const labelOf = code => (fields.find(f => f.code === code) || { label: code }).label;

        if (!registered) {
            const Embed = Quill.import('blots/embed');
            class FieldBlot extends Embed {
                static create(code) {
                    const n = super.create();
                    n.setAttribute('data-field', code); n.setAttribute('contenteditable', 'false');
                    n.textContent = (window.EmailComposer._label || (c => c))(code);
                    return n;
                }
                static value(node) { return node.getAttribute('data-field'); }
            }
            FieldBlot.blotName = 'field'; FieldBlot.tagName = 'span'; FieldBlot.className = 'ql-field';
            Quill.register(FieldBlot);
            registered = true;
        }
        window.EmailComposer._label = labelOf;

        const quill = new Quill('#ecMessage', { theme: 'snow', modules: { toolbar: '#ecToolbar' }, placeholder: 'Write your message...' });
        const toChips = html => (html || '').replace(/\{\{\s*([A-Za-z][A-Za-z0-9_]*)\s*\}\}/g, (m, c) => `<span class="ql-field" data-field="${H(c)}">${H(labelOf(c))}</span>`);
        function messageHtml() {
            const root = quill.root.cloneNode(true);
            root.querySelectorAll('.ql-field').forEach(n => n.replaceWith(document.createTextNode('{{' + n.getAttribute('data-field') + '}}')));
            return root.innerHTML === '<p><br></p>' ? '' : root.innerHTML;
        }

        function rowHtml(r) {
            return `<div class="ec-row">
                <input class="form-control form-control-sm r-label" maxlength="80" placeholder="e.g. Date" value="${H(r.label)}" />
                <div class="input-group input-group-sm">
                    <input class="form-control r-value" maxlength="200" placeholder="Text or a field" value="${H(r.value)}" />
                    <button type="button" class="btn ec-field-btn dropdown-toggle" data-bs-toggle="dropdown" data-insert="row"><i class="bi bi-plus-circle"></i></button>
                    <ul class="dropdown-menu dropdown-menu-end ec-field-menu"></ul>
                </div>
                <div class="d-flex">
                    <button type="button" class="btn-icon r-star ${r.highlight ? 'on' : ''}" title="Make the value stand out"><i class="bi ${r.highlight ? 'bi-star-fill' : 'bi-star'}"></i></button>
                    <button type="button" class="btn-icon r-up" title="Move up"><i class="bi bi-arrow-up"></i></button>
                    <button type="button" class="btn-icon r-down" title="Move down"><i class="bi bi-arrow-down"></i></button>
                    <button type="button" class="btn-icon del r-del" title="Remove"><i class="bi bi-trash"></i></button>
                </div></div>`;
        }

        function fillMenus() {
            const items = fields.map(f => `<li><a class="dropdown-item" href="#" data-code="${H(f.code)}">${H(f.label)} <small>e.g. ${H(f.sample)}</small></a></li>`).join('');
            $('.ec-field-menu').html(items || '<li><span class="dropdown-item-text small text-muted">No fields</span></li>');
        }

        function setDesign(d) {
            d = d || {};
            $('#ecHeading').val(d.heading || '');
            quill.setContents([]);
            quill.clipboard.dangerouslyPasteHTML(toChips(d.message || ''));
            $('#ecRows').html((d.rows || []).map(rowHtml).join(''));
            $('#ecNote').val(d.noteText || '');
            $('#ecNoteStyle').val(d.noteStyle || 'info');
            $('#ecClosing').val(d.closing || '');
            $('#ecSignature').val(d.signature || '');
            fillMenus();
        }

        function getDesign() {
            return {
                heading: $('#ecHeading').val().trim(),
                message: messageHtml(),
                rows: $('#ecRows .ec-row').map(function () {
                    return { label: $(this).find('.r-label').val().trim(), value: $(this).find('.r-value').val().trim(), highlight: $(this).find('.r-star').hasClass('on') };
                }).get().filter(r => r.label || r.value),
                noteText: $('#ecNote').val().trim(), noteStyle: $('#ecNoteStyle').val(),
                closing: $('#ecClosing').val().trim(), signature: $('#ecSignature').val().trim()
            };
        }

        function insertInto(input, code) {
            const text = '{{' + code + '}}';
            const s = input.selectionStart ?? input.value.length, e = input.selectionEnd ?? s;
            input.value = input.value.slice(0, s) + text + input.value.slice(e);
            input.focus(); input.setSelectionRange(s + text.length, s + text.length);
            $(input).trigger('input');
        }

        let lastRange = null;
        quill.on('selection-change', r => { if (r) lastRange = r; });
        quill.on('text-change', () => onChange());

        $(document).on('click', '.ec-field-menu .dropdown-item[data-code]', function (e) {
            e.preventDefault();
            const code = this.dataset.code, target = $(this).closest('.ec-field-menu').prev('[data-insert]').data('insert');
            if (target === 'quill') {
                const at = (lastRange || quill.getSelection() || { index: Math.max(0, quill.getLength() - 1) }).index;
                quill.insertEmbed(at, 'field', code, 'user'); quill.insertText(at + 1, ' ', 'user'); quill.setSelection(at + 2, 0);
            } else if (target === 'newrow') {
                $('#ecRows').append(rowHtml({ label: labelOf(code), value: '{{' + code + '}}', highlight: false })); fillMenus();
            } else if (target === 'row') {
                insertInto($(this).closest('.input-group').find('.r-value')[0], code);
            } else {
                insertInto($(target)[0], code);
            }
            onChange();
        });
        $('#ecAddRow').on('click', () => { $('#ecRows').append(rowHtml({ label: '', value: '', highlight: false })); fillMenus(); $('#ecRows .r-label').last().focus(); onChange(); });
        $('#ecRows').on('click', '.r-del', function () { $(this).closest('.ec-row').remove(); onChange(); })
            .on('click', '.r-up', function () { const r = $(this).closest('.ec-row'); r.prev('.ec-row').before(r); onChange(); })
            .on('click', '.r-down', function () { const r = $(this).closest('.ec-row'); r.next('.ec-row').after(r); onChange(); })
            .on('click', '.r-star', function () { $(this).toggleClass('on').find('i').toggleClass('bi-star bi-star-fill'); onChange(); })
            .on('input', 'input', () => onChange());
        $('#ecHeading, #ecNote, #ecNoteStyle, #ecClosing, #ecSignature').on('input change', () => onChange());

        setDesign(opts.design);
        return {
            getDesign, setDesign, insertInto, fillMenus,
            setFields(f) { const d = getDesign(); fields = f || []; window.EmailComposer._label = labelOf; setDesign(d); },
            fields: () => fields
        };
    }

    window.EmailComposer = { init };
})();
