// moved from Views/Cities/Index.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
        const tsCountry = new TomSelect('#fCountry', {
            placeholder: 'Search country...', allowEmptyOption: true,
            onChange: function (val) {
                tsState.clear(); tsState.clearOptions();
                tsState.addOption({ value: '', text: 'All States' });
                tsDistrict.clear(); tsDistrict.clearOptions();
                tsDistrict.addOption({ value: '', text: 'All Districts' });
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
            onChange: function () { document.getElementById('filterForm').submit(); }
        });
    
