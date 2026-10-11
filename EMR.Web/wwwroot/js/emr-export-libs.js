/* Loads the Excel / PDF export libraries only when an export is asked for, from the application's own copies
 * (wwwroot/lib), so a report page does not download and run ~1.3 MB of script before it can show its data.
 * No dependencies.
 *
 *   EmrExportLibs.excel().then(() => XLSX...)             SheetJS
 *   EmrExportLibs.pdf().then(() => window.jspdf.jsPDF...)  jsPDF + autoTable
 *   EmrExportLibs.run(button, 'excel' | 'pdf', fn)         loads, shows the button as busy, then runs fn
 *   EmrExportLibs.guard(selector, 'excel' | 'pdf')         same, for a button whose page already has its own export code
 */
window.EmrExportLibs = (function () {
    // application root, taken from this script's own address (works under a virtual directory too)
    const me = document.currentScript && document.currentScript.src || '';
    const root = me.indexOf('/js/') > 0 ? me.substring(0, me.indexOf('/js/')) : '';
    // the version in the address lets the browser keep these files (they never change under one version)
    const FILES = {
        xlsx: root + '/lib/xlsx/xlsx.full.min.js?v=0.18.5',
        jspdf: root + '/lib/jspdf/jspdf.umd.min.js?v=2.5.1',
        autotable: root + '/lib/jspdf-autotable/jspdf.plugin.autotable.min.js?v=3.5.28'
    };
    const pending = {};

    function load(key) {
        if (!pending[key]) {
            pending[key] = new Promise((resolve, reject) => {
                const s = document.createElement('script');
                s.src = FILES[key];
                s.onload = resolve;
                s.onerror = () => { delete pending[key]; reject(new Error('Could not load the export library. Check the connection and try again.')); };
                document.head.appendChild(s);
            });
        }
        return pending[key];
    }

    const excel = () => window.XLSX ? Promise.resolve() : load('xlsx');
    // autoTable attaches itself to jsPDF, so jsPDF goes first
    const pdf = () => (window.jspdf ? Promise.resolve() : load('jspdf'))
        .then(() => (window.jspdf.jsPDF.API && window.jspdf.jsPDF.API.autoTable) ? undefined : load('autotable'));

    function run(button, kind, fn) {
        const el = button && button.jquery ? button[0] : button;
        if (el) { if (el.dataset.busy) return; el.dataset.busy = '1'; el.classList.add('disabled'); }
        const done = () => { if (el) { delete el.dataset.busy; el.classList.remove('disabled'); } };
        return (kind === 'pdf' ? pdf() : excel())
            .then(fn)
            .catch(err => { (window.Swal ? Swal.fire({ icon: 'error', title: 'Export failed', text: err.message || String(err) }) : alert(err.message || err)); })
            .then(done, done);
    }

    const ready = kind => kind === 'pdf'
        ? !!(window.jspdf && window.jspdf.jsPDF.API && window.jspdf.jsPDF.API.autoTable)
        : !!window.XLSX;

    // For pages with their own export code: the first click on the button fetches the library, then the
    // click is repeated so the page's handler runs exactly as before.
    function guard(selector, kind) {
        document.querySelectorAll(selector).forEach(btn => btn.addEventListener('click', function (e) {
            if (ready(kind)) return;
            e.stopImmediatePropagation(); e.preventDefault();
            run(btn, kind, () => btn.click());
        }, true));
    }

    return { excel, pdf, run, guard };
})();
