// moved from Views/Areas/Create.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
        document.getElementById('CountryId').addEventListener('change', function () {
            const countryId = this.value;
            document.getElementById('StateId').innerHTML = '<option value="">-- Select State --</option>';
            document.getElementById('DistrictId').innerHTML = '<option value="">-- Select District --</option>';
            document.getElementById('CityId').innerHTML = '<option value="">-- Select City --</option>';
            if (!countryId) return;
            fetch(`/States/GetByCountry?countryId=${countryId}`)
                .then(r => r.json())
                .then(data => data.forEach(s => addOption('StateId', s.stateId, s.stateName)));
        });

        document.getElementById('StateId').addEventListener('change', function () {
            const stateId = this.value;
            document.getElementById('DistrictId').innerHTML = '<option value="">-- Select District --</option>';
            document.getElementById('CityId').innerHTML = '<option value="">-- Select City --</option>';
            if (!stateId) return;
            fetch(`/Districts/GetByState?stateId=${stateId}`)
                .then(r => r.json())
                .then(data => data.forEach(d => addOption('DistrictId', d.districtId, d.districtName)));
        });

        document.getElementById('DistrictId').addEventListener('change', function () {
            const districtId = this.value;
            document.getElementById('CityId').innerHTML = '<option value="">-- Select City --</option>';
            if (!districtId) return;
            fetch(`/Cities/GetByDistrict?districtId=${districtId}`)
                .then(r => r.json())
                .then(data => data.forEach(c => addOption('CityId', c.cityId, c.cityName)));
        });

        function addOption(selectId, value, text) {
            const opt = document.createElement('option');
            opt.value = value; opt.text = text;
            document.getElementById(selectId).appendChild(opt);
        }
    
