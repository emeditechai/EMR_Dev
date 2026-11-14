// moved from Views/LabDashboard/Index.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
        var currentTabFilter = 'all';

        function setTabFilter(filter, el) {
            currentTabFilter = filter;
            document.querySelectorAll('.nav-pills-custom .nav-link').forEach(btn => btn.classList.remove('active'));
            el.classList.add('active');
            filterPatientTable();
        }

        function filterPatientTable() {
            var search = document.getElementById('patientSearchInput').value.toLowerCase().trim();
            var rows = document.querySelectorAll('#patientOrderTable tbody tr.patient-order-row');

            rows.forEach(function (row) {
                var rowText = row.innerText.toLowerCase();
                var isUrgent = row.getAttribute('data-urgent') === 'true';
                var isPending = row.getAttribute('data-pending') === 'true';
                var status = row.getAttribute('data-status') || '';
                var type = row.getAttribute('data-type') || '';

                // Search query match
                var matchesSearch = !search || rowText.includes(search);

                // Tab filter match
                var matchesTab = true;
                if (currentTabFilter === 'urgent') {
                    matchesTab = isUrgent;
                } else if (currentTabFilter === 'pending') {
                    matchesTab = isPending;
                } else if (currentTabFilter === 'collected') {
                    matchesTab = status.includes('collected');
                } else if (currentTabFilter === 'home') {
                    matchesTab = type === 'home';
                }

                if (matchesSearch && matchesTab) {
                    row.style.display = '';
                } else {
                    row.style.display = 'none';
                }
            });
        }

        function viewOrderSummaryModal(orderId, billNo, patientName, testSummary, status, amount) {
            document.getElementById('modalBillNo').innerText = billNo;
            document.getElementById('modalPatientName').innerText = patientName;
            document.getElementById('modalTests').innerText = testSummary || 'No specific tests found.';
            document.getElementById('modalStatus').innerText = status;
            document.getElementById('modalAmount').innerText = '₹' + parseFloat(amount).toFixed(2);
            document.getElementById('modalSampleColLink').href = '/SampleCollection/Index';

            var modal = new bootstrap.Modal(document.getElementById('orderSummaryModal'));
            modal.show();
        }

        // Initialize tooltips
        document.addEventListener("DOMContentLoaded", function () {
            var tooltipTriggerList = [].slice.call(document.querySelectorAll('[data-bs-toggle="tooltip"]'));
            tooltipTriggerList.map(function (tooltipTriggerEl) {
                return new bootstrap.Tooltip(tooltipTriggerEl);
            });
        });
    
