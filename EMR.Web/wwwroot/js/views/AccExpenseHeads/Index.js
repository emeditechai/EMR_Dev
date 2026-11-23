// moved from Views/AccExpenseHeads/Index.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
        document.addEventListener('DOMContentLoaded', function () {
            var $ = function (id) { return document.getElementById(id); }, modal = new bootstrap.Modal($('headModal'));
            document.querySelectorAll('[data-acc-head]').forEach(function (btn) {
                btn.addEventListener('click', function () {
                    var d = btn.dataset, edit = d.accHead === 'edit';
                    $('hdTitle').textContent = edit ? 'Edit Expense Head' : 'Add Expense Head';
                    $('hdId').value = edit ? d.id : 0;
                    $('hdName').value = edit ? d.name : '';
                    $('hdLedger').value = edit ? d.ledger : '';
                    $('hdMax').value = edit ? (d.max || '') : '';
                    $('hdBill').value = edit ? (d.bill || '') : '';
                    $('hdActive').checked = edit ? d.active === '1' : true;
                    modal.show();
                });
            });
        });
    
