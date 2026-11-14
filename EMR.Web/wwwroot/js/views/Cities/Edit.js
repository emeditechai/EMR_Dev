// moved from Views/Cities/Edit.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
        document.getElementById('CountryId').addEventListener('change', function () {
            const countryId = this.value;
            const stateSelect = document.getElementById('StateId');
            const districtSelect = document.getElementById('DistrictId');
            stateSelect.innerHTML = '<option value="">-- Select State --</option>';
            districtSelect.innerHTML = '<option value="">-- Select District --</option>';
            if (!countryId) return;
            fetch(`/States/GetByCountry?countryId=${countryId}`)
                .then(r => r.json())
                .then(data => data.forEach(s => {
                    const opt = document.createElement('option');
                    opt.value = s.stateId; opt.text = s.stateName;
                    stateSelect.appendChild(opt);
                }));
        });

        document.getElementById('StateId').addEventListener('change', function () {
            const stateId = this.value;
            const districtSelect = document.getElementById('DistrictId');
            districtSelect.innerHTML = '<option value="">-- Select District --</option>';
            if (!stateId) return;
            fetch(`/Districts/GetByState?stateId=${stateId}`)
                .then(r => r.json())
                .then(data => data.forEach(d => {
                    const opt = document.createElement('option');
                    opt.value = d.districtId; opt.text = d.districtName;
                    districtSelect.appendChild(opt);
                }));
        });
    
