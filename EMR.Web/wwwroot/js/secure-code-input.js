/*
 * Masked code entry that browsers do not treat as a password field.
 *   <input type="text" class="secure-code" data-target="HiddenFieldId" />
 *   <input type="hidden" id="HiddenFieldId" name="Code" />
 *
 * - No type="password" anywhere, so the browser never offers to save the code.
 * - Characters are shown as bullets; the real value lives only in the hidden field.
 * - Paste, drop, copy, cut and the context menu are blocked: the code must be typed.
 * - The caret is kept at the end, so text is only ever appended or removed from the end.
 * - An element with data-reveal="<input id>" toggles showing the typed characters.
 */
(function () {
    'use strict';
    var BULLET = '•';
    var BLOCKED_INPUT = /^(insertFromPaste|insertFromPasteAsQuotation|insertFromDrop|insertFromYank|insertReplacementText|insertLink)$/;

    function setup(inp) {
        var target = document.getElementById(inp.getAttribute('data-target'));
        if (!target) return;
        var value = '';
        var shown = false;

        ['autocomplete', 'autocorrect', 'autocapitalize'].forEach(function (a) { inp.setAttribute(a, 'off'); });
        inp.setAttribute('spellcheck', 'false');
        inp.setAttribute('data-lpignore', 'true');   // LastPass
        inp.setAttribute('data-1p-ignore', 'true');  // 1Password
        inp.setAttribute('data-form-type', 'other'); // Dashlane
        inp.removeAttribute('name');
        inp.value = '';
        target.value = '';

        function caretToEnd() {
            var n = inp.value.length;
            try { inp.setSelectionRange(n, n); } catch (e) { /* not focusable yet */ }
        }
        function draw() {
            inp.value = shown ? value : new Array(value.length + 1).join(BULLET);
            target.value = value;
            caretToEnd();
        }

        inp.addEventListener('beforeinput', function (e) {
            if (BLOCKED_INPUT.test(e.inputType || '')) e.preventDefault();
        });
        inp.addEventListener('input', function () {
            var raw = inp.value;
            if (shown) {
                value = raw;
            } else {
                // Bullets are the characters already typed; anything else is new text at the end.
                var kept = (raw.match(new RegExp(BULLET, 'g')) || []).length;
                value = value.slice(0, kept) + raw.split(BULLET).join('');
            }
            draw();
        });
        ['paste', 'drop', 'dragover', 'copy', 'cut', 'contextmenu', 'dragstart'].forEach(function (ev) {
            inp.addEventListener(ev, function (e) { e.preventDefault(); });
        });
        inp.addEventListener('keydown', function (e) {
            var k = (e.key || '').toLowerCase();
            if ((e.ctrlKey || e.metaKey) && (k === 'v' || k === 'c' || k === 'x' || k === 'a' || k === 'z' || k === 'y')) e.preventDefault();
            if (e.shiftKey && k === 'insert') e.preventDefault();
            if (['arrowleft', 'arrowright', 'arrowup', 'arrowdown', 'home', 'end', 'pageup', 'pagedown'].indexOf(k) >= 0) e.preventDefault();
        });
        ['focus', 'click', 'mouseup', 'select'].forEach(function (ev) {
            inp.addEventListener(ev, function () { setTimeout(caretToEnd, 0); });
        });

        document.querySelectorAll('[data-reveal="' + inp.id + '"]').forEach(function (btn) {
            btn.addEventListener('click', function () {
                shown = !shown;
                var icon = btn.querySelector('i');
                if (icon) { icon.classList.toggle('bi-eye', !shown); icon.classList.toggle('bi-eye-slash', shown); }
                draw();
                inp.focus();
            });
        });

        // Clear everything if the page is restored from the back/forward cache.
        window.addEventListener('pageshow', function () { value = ''; shown = false; draw(); });
    }

    function init() {
        document.querySelectorAll('input.secure-code').forEach(setup);
    }
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init); else init();
})();
