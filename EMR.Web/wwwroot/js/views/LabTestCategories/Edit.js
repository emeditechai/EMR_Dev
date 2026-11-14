// moved from Views/LabTestCategories/Edit.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
        document.getElementById('statusSwitch')?.addEventListener('change', function() {
            document.getElementById('statusLabel').textContent = this.checked ? 'Active' : 'Inactive';
        });
        document.getElementById('barcodeSwitch')?.addEventListener('change', function() {
            document.getElementById('barcodeLabel').textContent = this.checked ? 'Yes' : 'No';
        });
        document.getElementById('sampleSwitch')?.addEventListener('change', function() {
            document.getElementById('sampleLabel').textContent = this.checked ? 'Yes' : 'No';
        });
    
