// moved from Views/LabMiscCharges/Create.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
        document.addEventListener('DOMContentLoaded', function () {
            var gst = document.getElementById('gstSwitch'), box = document.getElementById('gstPctBox'),
                pct = document.getElementById('GST_Percentage'), gstLbl = document.getElementById('gstLabel'),
                disc = document.getElementById('discSwitch'), discLbl = document.getElementById('discLabel');
            function syncGst() {
                var on = gst.checked;
                box.classList.toggle('d-none', !on);
                pct.disabled = !on;            // not posted (and not validated) when GST is not applicable
                if (!on) pct.value = '';
                gstLbl.textContent = on ? 'Yes' : 'No';
            }
            gst.addEventListener('change', function () { syncGst(); if (gst.checked) pct.focus(); });
            disc.addEventListener('change', function () { discLbl.textContent = disc.checked ? 'Yes' : 'No'; });
            syncGst();
        });
    
