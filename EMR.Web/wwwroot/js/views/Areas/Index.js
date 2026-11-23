// moved from Views/Areas/Index.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
        const tsCountry = new TomSelect('#fCountry', {
            placeholder: 'Search country...', allowEmptyOption: true,
            onChange: function (val) {
                tsState.clear(); tsState.clearOptions();
                tsState.addOption({ value: '', text: 'All States' });
                tsDistrict.clear(); tsDistrict.clearOptions();
                tsDistrict.addOption({ value: '', text: 'All Districts' });
                tsCity.clear(); tsCity.clearOptions();
                tsCity.addOption({ value: '', text: 'All Cities' });
                if (!val) return;
                fetch(`/States/GetByCountry?countryId=${val}`)
                    .then(r => r.json())
                    .then(data => {
                        data.forEach(s => tsState.addOption({ value: s.stateId, text: s.stateName }));
                        tsState.refreshOptions(false);
                    });
            }
        });
        const tsState = new TomSelect('#fState', {
            placeholder: 'Search state...', allowEmptyOption: true,
            onChange: function (val) {
                tsDistrict.clear(); tsDistrict.clearOptions();
                tsDistrict.addOption({ value: '', text: 'All Districts' });
                tsCity.clear(); tsCity.clearOptions();
                tsCity.addOption({ value: '', text: 'All Cities' });
                if (!val) return;
                fetch(`/Districts/GetByState?stateId=${val}`)
                    .then(r => r.json())
                    .then(data => {
                        data.forEach(d => tsDistrict.addOption({ value: d.districtId, text: d.districtName }));
                        tsDistrict.refreshOptions(false);
                    });
            }
        });
        const tsDistrict = new TomSelect('#fDistrict', {
            placeholder: 'Search district...', allowEmptyOption: true,
            onChange: function (val) {
                tsCity.clear(); tsCity.clearOptions();
                tsCity.addOption({ value: '', text: 'All Cities' });
                if (!val) return;
                fetch(`/Cities/GetByDistrict?districtId=${val}`)
                    .then(r => r.json())
                    .then(data => {
                        data.forEach(c => tsCity.addOption({ value: c.cityId, text: c.cityName }));
                        tsCity.refreshOptions(false);
                    });
            }
        });
        const tsCity = new TomSelect('#fCity', {
            placeholder: 'Search city...', allowEmptyOption: true,
            onChange: function () { document.getElementById('filterForm').submit(); }
        });
    
