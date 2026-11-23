// moved from Views/GovernmentSchemes/Create.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
        const presets = {
            PMJAY: {
                code: 'PMJAY-01',
                name: 'Ayushman Bharat – Pradhan Mantri Jan Arogya Yojana (PM-JAY)',
                type: 'Central Government',
                authority: 'National Health Authority (NHA)',
                coverage: 500000,
                preAuth: true,
                biometric: true,
                abha: true,
                copay: 0,
                days: 7,
                bed: 'General Ward',
                tms: 'https://tms.pmjay.gov.in',
                nhaCode: 'PMJAY_V2',
                idType: 'PM-JAY Golden Card / Aadhaar / Ration Card',
                remarks: '100% Cashless secondary & tertiary hospitalisation coverage up to Rs 5 Lakh per family per year.'
            },
            CGHS: {
                code: 'CGHS-DEL',
                name: 'Central Government Health Scheme (CGHS)',
                type: 'Central Government',
                authority: 'Ministry of Health & Family Welfare (MoHFW)',
                coverage: 0,
                preAuth: true,
                biometric: true,
                abha: true,
                copay: 0,
                days: 15,
                bed: 'Semi-Private / Private as per Pay Matrix',
                tms: 'https://cghs.nic.in',
                nhaCode: 'CGHS_CENTRAL',
                idType: 'CGHS Plastic Card / Beneficiary ID',
                remarks: 'Comprehensive healthcare for central government employees and pensioners.'
            },
            ECHS: {
                code: 'ECHS-HQ',
                name: 'Ex-Servicemen Contributory Health Scheme (ECHS)',
                type: 'Defence / Ex-Servicemen',
                authority: 'Central Organisation ECHS / Ministry of Defence',
                coverage: 0,
                preAuth: true,
                biometric: true,
                abha: false,
                copay: 0,
                days: 30,
                bed: 'As per Rank / Entitlement',
                tms: 'https://echs.gov.in',
                nhaCode: 'ECHS_DEFENCE',
                idType: 'ECHS 64Kb Smart Card',
                remarks: 'Cashless treatment for Armed Forces veterans, war widows, and legitimate dependents.'
            },
            STATE: {
                code: 'SWS-WB',
                name: 'Swasthya Sathi Scheme',
                type: 'State Government',
                authority: 'State Health Agency - Government of West Bengal',
                coverage: 500000,
                preAuth: true,
                biometric: true,
                abha: false,
                copay: 0,
                days: 7,
                bed: 'General Ward',
                tms: 'https://swasthyasathi.gov.in',
                nhaCode: 'SWS_WB_01',
                idType: 'Swasthya Sathi Smart Card (Family Head: Female)',
                remarks: 'Flagship universal health insurance scheme of Government of West Bengal covering up to Rs 5 Lakh per family per annum.'
            },
            ESIC: {
                code: 'ESIC-HQ',
                name: 'Employees State Insurance Corporation (ESIC)',
                type: 'Social Security / Labour',
                authority: 'Ministry of Labour & Employment - ESIC',
                coverage: 0,
                preAuth: true,
                biometric: true,
                abha: true,
                copay: 0,
                days: 15,
                bed: 'General Ward',
                tms: 'https://esic.gov.in',
                nhaCode: 'ESIC_SOCIAL',
                idType: 'ESIC Pehchan Card / IP Number',
                remarks: 'Full medical care and cash benefits for insured persons and dependent family members.'
            },
            PSU: {
                code: 'PSU-SAIL',
                name: 'Steel Authority of India Ltd (SAIL) Mediclaim Scheme',
                type: 'PSU / Autonomous Body',
                authority: 'SAIL Corporate Medical Directorate',
                coverage: 400000,
                preAuth: true,
                biometric: false,
                abha: false,
                copay: 5,
                days: 30,
                bed: 'As per Grade (Non-Executive / Executive)',
                tms: 'https://sail.co.in',
                nhaCode: 'PSU_SAIL_MED',
                idType: 'SAIL Medical Booklet / Employee ID',
                remarks: 'Indoor hospitalisation coverage for serving and retired employees of Steel Authority of India Ltd.'
            }
        };

        function applyPreset(key) {
            const p = presets[key];
            if (!p) return;

            document.getElementById('SchemeCode').value = p.code;
            document.getElementById('SchemeName').value = p.name;
            document.getElementById('SchemeType').value = p.type;
            document.getElementById('AuthorityName').value = p.authority;
            document.getElementById('AnnualCoverageLimit').value = p.coverage;
            document.getElementById('PreAuthMandatory').checked = p.preAuth;
            document.getElementById('BiometricAuthRequired').checked = p.biometric;
            document.getElementById('AbhaCreationMandatory').checked = p.abha;
            document.getElementById('CoPayPercentage').value = p.copay;
            document.getElementById('MaxClaimSubmissionDays').value = p.days;
            document.getElementById('DefaultBedCategory').value = p.bed;
            document.getElementById('TMSPortalUrl').value = p.tms;
            document.getElementById('NHA_SchemeCode').value = p.nhaCode;
            document.getElementById('BeneficiaryIdType').value = p.idType;
            document.getElementById('SpecialRemarks').value = p.remarks;

            syncJsonPreview();
        }

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
    
