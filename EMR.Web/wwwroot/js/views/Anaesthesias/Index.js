// moved from Views/Anaesthesias/Index.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
        // Total calculation for Add Rate Modal
        function calcAddTotal() {
            var fee = parseFloat(document.querySelector('#addRateForm input[name="AnaesthetistFee"]').value) || 0;
            var con = parseFloat(document.querySelector('#addRateForm input[name="ConsumableCharge"]').value) || 0;
            var tot = fee + con;
            document.getElementById('addTotalRateDisplay').innerText = '₹' + tot.toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
        }
        document.querySelectorAll('.add-rate-calc').forEach(function (el) {
            el.addEventListener('input', calcAddTotal);
            el.addEventListener('change', calcAddTotal);
        });

        // Total calculation for Edit Rate Modal
        function calcEditTotal() {
            var fee = parseFloat(document.getElementById('editRateFee').value) || 0;
            var con = parseFloat(document.getElementById('editRateConsumable').value) || 0;
            var tot = fee + con;
            document.getElementById('editTotalRateDisplay').innerText = '₹' + tot.toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
        }
        document.querySelectorAll('.edit-rate-calc').forEach(function (el) {
            el.addEventListener('input', calcEditTotal);
            el.addEventListener('change', calcEditTotal);
        });

        // AJAX edit type modal
        function openEditTypeModal(id) {
            fetch('/Anaesthesias/GetTypeJson/' + id)
                .then(response => response.json())
                .then(data => {
                    document.getElementById('editTypeId').value = data.anaesthesiaTypeId;
                    document.getElementById('editTypeCode').value = data.typeCode;
                    document.getElementById('editTypeName').value = data.typeName;
                    document.getElementById('editTypeDesc').value = data.description || '';
                    document.getElementById('editTypeIsActive').checked = data.isActive;

                    var modal = new bootstrap.Modal(document.getElementById('editTypeModal'));
                    modal.show();
                })
                .catch(err => alert('Failed to load Anaesthesia Type details.'));
        }

        // AJAX edit rate modal
        function openEditRateModal(id) {
            fetch('/Anaesthesias/GetRateJson/' + id)
                .then(response => response.json())
                .then(data => {
                    document.getElementById('editRateId').value = data.anaesthesiaRateId;
                    document.getElementById('editRateProcId').value = data.procedureId;
                    document.getElementById('editRateTypeId').value = data.anaesthesiaTypeId;
                    document.getElementById('editRateFee').value = data.anaesthetistFee;
                    document.getElementById('editRateConsumable').value = data.consumableCharge;

                    if (data.effectiveFrom) {
                        document.getElementById('editRateEffectiveFrom').value = data.effectiveFrom.substring(0, 10);
                    }
                    if (data.effectiveTo) {
                        document.getElementById('editRateEffectiveTo').value = data.effectiveTo.substring(0, 10);
                    } else {
                        document.getElementById('editRateEffectiveTo').value = '';
                    }

                    document.getElementById('editRateDesc').value = data.description || '';
                    document.getElementById('editRateIsActive').checked = data.isActive;

                    calcEditTotal();

                    var modal = new bootstrap.Modal(document.getElementById('editRateModal'));
                    modal.show();
                })
                .catch(err => alert('Failed to load Anaesthesia Rate details.'));
        }
    
