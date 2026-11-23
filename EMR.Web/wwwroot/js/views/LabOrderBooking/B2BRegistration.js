// moved from Views/LabOrderBooking/B2BRegistration.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
    document.addEventListener('DOMContentLoaded', function () {
        const type = document.getElementById('ddlAgentType'), partner = document.getElementById('ddlAgentId');
        if (!type || !partner) return;
        // Franchise / Company lists only partners of the chosen type; "All" types = all partners
        type.addEventListener('change', function () {
            const t = type.value;
            [...partner.options].forEach(o => { if (o.value) o.hidden = !!t && o.dataset.type !== t; });
            partner.value = '';
            partner.disabled = !t;
            type.form.submit();
        });
        partner.addEventListener('change', () => partner.form.submit());
    });
