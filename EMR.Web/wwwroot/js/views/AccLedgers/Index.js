// moved from Views/AccLedgers/Index.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
        document.addEventListener('DOMContentLoaded', function () {
            var $ = function (id) { return document.getElementById(id); };
            var ledgerModal = new bootstrap.Modal($('ledgerModal')), groupModal = new bootstrap.Modal($('groupModal'));

            document.querySelectorAll('[data-acc-ledger]').forEach(function (btn) {
                btn.addEventListener('click', function () {
                    var d = btn.dataset, edit = d.accLedger === 'edit', system = d.system === '1', petty = d.type === 'PETTY';
                    $('lgTitle').textContent = edit ? 'Edit Ledger' : 'Add Ledger';
                    $('lgId').value = edit ? d.id : 0;
                    $('lgName').value = edit ? d.name : '';
                    $('lgGroup').value = edit ? d.group : '';
                    $('lgType').value = edit ? d.type : 'GENERAL';
                    $('lgOpening').value = edit ? d.opening : '0.00';
                    $('lgOpType').value = edit ? d.optype : 'Dr';
                    $('lgRemarks').value = edit ? (d.remarks || '') : '';
                    $('lgActive').checked = edit ? d.active === '1' : true;
                    // a system ledger keeps its name / group / type; a petty cash ledger belongs to its counter
                    $('lgName').readOnly = system || petty;
                    ['lgGroup', 'lgType'].forEach(function (id) { $(id).style.pointerEvents = (system || petty) ? 'none' : ''; $(id).classList.toggle('bg-light', system || petty); });
                    $('lgActive').onclick = system ? function () { return false; } : null;   // stays on: a disabled box would post "inactive"
                    $('lgOpening').readOnly = petty;
                    $('lgSystemNote').classList.toggle('d-none', !system);
                    $('lgType').querySelectorAll('option[data-petty="1"]').forEach(function (o) { o.hidden = !petty; });
                    ledgerModal.show();
                });
            });

            document.querySelectorAll('[data-acc-group]').forEach(function (btn) {
                btn.addEventListener('click', function () {
                    var d = btn.dataset, edit = d.accGroup === 'edit', system = d.system === '1';
                    $('grTitle').textContent = edit ? 'Edit Ledger Group' : 'Add Ledger Group';
                    $('grId').value = edit ? d.id : 0;
                    $('grName').value = edit ? d.name : '';
                    $('grType').value = edit ? d.type : 'Expense';
                    $('grParent').value = edit ? (d.parent || '') : '';
                    $('grActive').checked = edit ? d.active === '1' : true;
                    $('grName').readOnly = system;
                    $('grType').style.pointerEvents = system ? 'none' : ''; $('grType').classList.toggle('bg-light', system);
                    $('grActive').onclick = system ? function () { return false; } : null;
                    groupModal.show();
                });
            });
        });
    
