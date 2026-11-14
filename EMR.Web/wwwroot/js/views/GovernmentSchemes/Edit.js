// moved from Views/GovernmentSchemes/Edit.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
        function syncJsonPreview() {
            const obj = {
                AnnualCoverageLimit: parseFloat(document.getElementById('AnnualCoverageLimit').value) || 0,
                PreAuthMandatory: document.getElementById('PreAuthMandatory').checked,
                BiometricAuthRequired: document.getElementById('BiometricAuthRequired').checked,
                AbhaCreationMandatory: document.getElementById('AbhaCreationMandatory').checked,
                CoPayPercentage: parseFloat(document.getElementById('CoPayPercentage').value) || 0,
                MaxClaimSubmissionDays: parseInt(document.getElementById('MaxClaimSubmissionDays').value) || 7,
                PackageRateDiscountPercent: parseFloat(document.getElementById('PackageRateDiscountPercent').value) || 0,
                DefaultBedCategory: document.getElementById('DefaultBedCategory').value || 'General Ward',
                TMSPortalUrl: document.getElementById('TMSPortalUrl').value || '',
                NHA_SchemeCode: document.getElementById('NHA_SchemeCode').value || '',
                BeneficiaryIdType: document.getElementById('BeneficiaryIdType').value || '',
                SpecialRemarks: document.getElementById('SpecialRemarks').value || ''
            };

            document.getElementById('RuleConfigJSON').value = JSON.stringify(obj, null, 2);
        }

        document.addEventListener('DOMContentLoaded', () => {
            syncJsonPreview();
        });
    
