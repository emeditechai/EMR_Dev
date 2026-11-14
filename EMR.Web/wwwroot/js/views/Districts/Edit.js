// moved from Views/Districts/Edit.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
        document.getElementById('CountryId').addEventListener('change', function () {
            const countryId = this.value;
            const stateSelect = document.getElementById('StateId');
            stateSelect.innerHTML = '<option value="">-- Select State --</option>';
            if (!countryId) return;
            fetch(`/States/GetByCountry?countryId=${countryId}`)
                .then(r => r.json())
                .then(data => {
                    data.forEach(s => {
                        const opt = document.createElement('option');
                        opt.value = s.stateId; opt.text = s.stateName;
                        stateSelect.appendChild(opt);
                    });
                });
        });
    
