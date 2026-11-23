// moved from Views/AccPayees/Index.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
        document.addEventListener('DOMContentLoaded', function () {
            var $ = function (id) { return document.getElementById(id); }, modal = new bootstrap.Modal($('payeeModal'));
            document.querySelectorAll('[data-acc-payee]').forEach(function (btn) {
                btn.addEventListener('click', function () {
                    var d = btn.dataset, edit = d.accPayee === 'edit';
                    $('pyTitle').textContent = edit ? 'Edit Payee' : 'Add Payee';
                    $('pyId').value = edit ? d.id : 0;
                    $('pyName').value = edit ? d.name : '';
                    $('pyPhone').value = edit ? (d.phone || '') : '';
                    $('pyGstin').value = edit ? (d.gstin || '') : '';
                    $('pyPan').value = edit ? (d.pan || '') : '';
                    $('pyHead').value = edit ? (d.head || '') : '';
                    $('pyRemarks').value = edit ? (d.remarks || '') : '';
                    $('pyActive').checked = edit ? d.active === '1' : true;
                    modal.show();
                });
            });
        });
    
