// GS1 DataMatrix / GS1-128 pack codes (SQLScripts/2404): read the GTIN (01), expiry (17), manufacturing date (11),
// batch (10) and serial (21) from what a scanner types. Handles the FNC1 group separator (ASCII 29, or the
// "<GS>" text some scanners send), the "]d2" / "]C1" symbology prefix and the human-readable "(01)...(17)..." form.
// Returns null when the text is not a GS1 code (a plain EAN-13 barcode stays a normal search).
(function () {
    'use strict';
    const FIXED = { '00': 18, '01': 14, '02': 14, '11': 6, '13': 6, '15': 6, '16': 6, '17': 6 };
    const VAR = ['10', '21', '240', '30', '37', '90', '91', '92'];

    // YYMMDD -> yyyy-mm-dd ("00" day = last day of the month, as GS1 says)
    function date6(v) {
        if (!/^\d{6}$/.test(v)) return null;
        const y = 2000 + +v.slice(0, 2), m = +v.slice(2, 4); let d = +v.slice(4, 6);
        if (m < 1 || m > 12) return null;
        if (d === 0) d = new Date(y, m, 0).getDate();
        return `${y}-${String(m).padStart(2, '0')}-${String(d).padStart(2, '0')}`;
    }

    function parse(raw) {
        if (!raw) return null;
        let s = String(raw).trim().replace(/<GS>|\{GS\}|\\x1d|␝/gi, '\x1D');
        s = s.replace(/^\](d2|C1|e0|Q3)/, '');
        const out = {};
        if (/^\(\d{2,4}\)/.test(s)) {                       // (01)08901234567894(17)271231(10)AB123
            const re = /\((\d{2,4})\)([^(]*)/g; let m;
            while ((m = re.exec(s))) out[m[1]] = m[2].replace(/\x1D/g, '').trim();
        } else {
            if (!/^(01|02|00)\d/.test(s)) return null;
            let i = 0;
            while (i < s.length) {
                if (s[i] === '\x1D') { i++; continue; }
                const ai2 = s.substr(i, 2), ai3 = s.substr(i, 3);
                if (FIXED[ai2]) { out[ai2] = s.substr(i + 2, FIXED[ai2]); i += 2 + FIXED[ai2]; continue; }
                const ai = VAR.includes(ai3) ? ai3 : VAR.includes(ai2) ? ai2 : null;
                if (!ai) break;
                let j = s.indexOf('\x1D', i + ai.length);
                if (j < 0) {
                    // no separator: a fixed-length AI after a batch (e.g. ...10AB12317271231) is split off when it is a valid date
                    j = s.length;
                    if (ai === '10') {
                        const tail = s.slice(i + 2).match(/^(.+?)(17|11)(\d{6})$/);
                        if (tail && date6(tail[3])) { out[ai] = tail[1]; out[tail[2]] = tail[3]; i = s.length; continue; }
                    }
                }
                out[ai] = s.slice(i + ai.length, j); i = j;
            }
        }
        const gtin = (out['01'] || out['02'] || '').replace(/\D/g, '');
        if (gtin.length !== 14) return null;
        return {
            gtin,
            batch: (out['10'] || '').trim().toUpperCase() || null,
            expiry: date6(out['17'] || ''), mfg: date6(out['11'] || ''),
            serial: (out['21'] || '').trim() || null
        };
    }

    window.PhGs1 = { parse };
})();
