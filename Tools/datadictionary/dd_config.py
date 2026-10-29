"""
Data dictionary configuration: parts, modules, table purposes, column notes and how logical relations are inferred.

Edit this file when a module is reworked or a new one is added:
  * new table      -> add it to the right module's "tables" (until then it is listed under "Other ... tables")
  * new module     -> add a dict(code=..., part=..., name=..., intro=..., tables=[...]) to MODULES
  * new part       -> add it to PARTS and give it name patterns in PART_RULES
  * descriptions   -> TABLE_DESC / COL_DESC here, or better MS_Description in the SQL script (it takes precedence)
  * codes / types  -> COL_DESC (e.g. "P = paid, U = unpaid")
  * logical links  -> ALIAS / CONTEXT_ALIAS / OVERRIDE / CONDITIONAL
Then run: python3 Tools/datadictionary/update_data_dictionary.py
"""

PARTS = [
    ("A", "Common Foundation (shared by OPD and LAB)",
     "Tables that both OPD and LAB depend on: the organisation, users, patient registration, billing and payment, "
     "cancellations, cash closing, membership and the master approval workflow."),
    ("B", "OPD (Out-Patient Department)",
     "Doctors, schedules, OPD services, the OPD visit and token, clinical records (EMR), vaccination, certificates "
     "and the doctor revenue-share settlement."),
    ("C", "LAB (Laboratory Information System)",
     "Test masters, profiles and packages, microbiology, rate cards and B2B partners, order booking, sample "
     "logistics, result entry and approval, quality control, consumption and the doctor incentive programme."),
]

MODULES = [
    # ── Part A ──────────────────────────────────────────────────────────────────────────────
    dict(code="A1", part="A", name="Organisation & Settings",
         intro="The company (tenant), its branches, departments and per-branch hospital settings. Every OPD and LAB "
               "record carries CompanyId and, for operational records, the branch it belongs to. Printed documents "
               "(bills, reports) use the print templates assigned per branch.",
         tables=["CompanyMaster", "Branchmaster", "HospitalSettings", "DepartmentMaster",
                 "PrintTemplate", "PrintTemplateVersion", "PrintTemplateAssignment"]),
    dict(code="A2", part="A", name="Users, Roles & Branch Access",
         intro="Application logins and what they may do. A user works in one or more branches (UserBranches) and "
               "holds roles per branch (Userroles). Franchise and corporate logins are Users rows with User_Type F / C "
               "and ReferenceUserID pointing at the franchise or corporate.",
         tables=["Users", "roles", "Userroles", "UserBranches"]),
    dict(code="A3", part="A", name="Geography & Patient Lookups",
         intro="Reference lists used on the patient and address forms: country > state > district > city > area, and "
               "the demographic lookups (identity document type, marital status, occupation, religion, relation, "
               "language, disability).",
         tables=["CountryMaster", "StateMaster", "DistrictMaster", "CityMaster", "AreaMaster",
                 "IdentificationTypeMaster", "MaritalStatusMaster", "OccupationMaster", "ReligionMaster",
                 "RelationMaster", "LanguageMaster", "DisabilityTypeMaster"]),
    dict(code="A4", part="A", name="Patient Registration",
         intro="One PatientMaster row per person (UHID = PatientCode), shared by OPD visits, lab orders, membership "
               "and certificates. Patient codes are numbered per branch and financial year. Referral doctors are "
               "external doctors who refer patients.",
         tables=["PatientMaster", "PatientCodeCounter", "ReferralDoctorMaster"]),
    dict(code="A5", part="A", name="Billing, Payment & Receipts",
         intro="A single billing engine for every module. PaymentHeader is the bill (ModuleCode + ModuleRefId point "
               "at the OPD visit, lab order, membership card or pharmacy sale), PaymentLineItem holds the billed lines "
               "with discount and GST, PaymentDetail holds each payment received (mode, reference, receipt number).",
         tables=["PaymentHeader", "PaymentLineItem", "PaymentDetail", "PaymentMethodMaster", "DiscountTypeMaster",
                 "ReceiptSequence", "ReceiptNoFormatMap", "BillingSubmission"]),
    dict(code="A6", part="A", name="Cancellation & Refund",
         intro="Full or partial cancellation of an OPD or LAB bill, the cancelled lines and the refund paid out. "
               "Cancellation numbers run per module, branch and financial year.",
         tables=["BillCancellation", "BillCancellationItem", "BillRefund", "CancellationSequence"]),
    dict(code="A7", part="A", name="Cashier Day-end Closing",
         intro="Each cashier's day-end hand-over per module (OPD / LAB): expected vs counted cash, the per-mode "
               "summary lines and the petty-cash floats included. A supervisor verifies or sends it back.",
         tables=["CashClosing", "CashClosingLine", "CashClosingPetty"]),
    dict(code="A8", part="A", name="Membership & Loyalty",
         intro="Membership plans with benefits, the cards issued to a primary patient and family members, and the "
               "points ledger (earn, redeem, expiry). Redemption is confirmed by OTP.",
         tables=["MembershipPlan", "MembershipPlanBenefit", "MembershipCard", "MembershipCardMember",
                 "MembershipLedger", "MembershipRedeemOtp", "MembershipPointsWhatsAppLog"]),
    dict(code="A9", part="A", name="Master Approval Workflow",
         intro="Maker / checker on masters (Franchise Setup, Corporate Master, Investigation Profile / Package and "
               "pharmacy adjustments). The matrix names the approvers company-wise or per branch; every submission is "
               "an ApprovalRequest with the old and new values.",
         tables=["ApprovalModule", "ApprovalMatrix", "ApprovalMatrixApprover", "ApprovalRequest"]),

    # ── Part B ──────────────────────────────────────────────────────────────────────────────
    dict(code="B1", part="B", name="Doctors & Specialities",
         intro="Consulting doctors, their specialities and sub-specialities, the departments and branches they work "
               "in, and clinical units headed by a consultant.",
         tables=["DoctorMaster", "DoctorSpecialityMaster", "DoctorSubSpecialityMaster", "DoctorDepartmentMap",
                 "DoctorBranchMap", "ClinicalUnitMaster"]),
    dict(code="B2", part="B", name="Rooms & Doctor Schedules",
         intro="Consultation rooms, which doctor sits where, the weekly OPD schedule (slots, capacity) and the "
               "exceptions (leave, holidays) that block a schedule.",
         tables=["DoctorRoomMaster", "DoctorRoomMapping", "DoctorScheduleMaster", "DoctorScheduleException"]),
    dict(code="B3", part="B", name="OPD Services & Visit Rules",
         intro="The OPD service catalogue (consultation, registration and other services with charges and GST), the "
               "consultation fee each doctor charges, and per-doctor / speciality rules for a visit.",
         tables=["ServiceMaster", "DoctorConsultingFeeMap", "DoctorVisitProcessConfig"]),
    dict(code="B4", part="B", name="OPD Visit, Billing & Token",
         intro="An OPD visit (PatientOPDService) with its service lines, the OPD bill number and daily token. Its "
               "bill is a PaymentHeader with ModuleCode = 'OPD' and the visit's OPDServiceId. Token status changes "
               "are logged for the queue monitor.",
         tables=["PatientOPDService", "PatientOPDServiceItem", "OPDBillSequence", "OPDTokenSequence", "OPDTokenStatusLog"]),
    dict(code="B5", part="B", name="Clinical Records (EMR) & Teleconsultation",
         intro="Configurable consultation templates (sections and fields per speciality), the consultation record of "
               "a visit, vitals, and video consultations.",
         tables=["EmrTemplates", "EmrTemplateSections", "EmrTemplateFields", "EmrTemplateSpecialityMap",
                 "EmrPatientConsultation", "EmrInvestigationMaster", "EmrMedicationMaster", "PatientVitals",
                 "tbl_VideoConsultation", "tbl_VideoSystemConfig"]),
    dict(code="B6", part="B", name="Vaccination, Certificates & Consent",
         intro="Vaccines given to a patient, medical certificates issued from a visit (numbered per branch, type and "
               "year), the doctors allowed to sign them, and consent form templates.",
         tables=["VaccineMaster", "PatientVaccination", "CertificateTypeMaster", "CertificatePurposeMaster",
                 "CertificateDoctorProfile", "CertificateSequence", "PatientCertificate", "CertificateNotificationLog",
                 "ConsentMaster"]),
    dict(code="B7", part="B", name="Doctor Revenue Share & Settlement",
         intro="How much of a bill is the doctor's share (commission configuration), the share computed per visit / "
               "bill (disbursal), approved adjustments, and the periodic settlement paid to the doctor with TDS.",
         tables=["DoctorCommissionConfig", "DoctorPayoutProfile", "DoctorDisbursal", "DoctorBillingAdjustment",
                 "DoctorSettlement"]),

    # ── Part C ──────────────────────────────────────────────────────────────────────────────
    dict(code="C1", part="C", name="Test Classification & Lab Masters",
         intro="The building blocks of a test: department > category > sub-category, sample type (specimen and "
               "container), method, unit, analyzer, sample rejection reasons, reporting conditions and miscellaneous "
               "charges (e.g. home collection).",
         tables=["LabTestCategoryMaster", "LabTestSubCategoryMaster", "LabSampleTypeMaster", "LabTestMethodMaster",
                 "LabUnitMaster", "tbl_mst_analyzer", "LabSampleRejectionMaster", "LabSampleRejectionReasonMaster",
                 "LabReportingConditionMaster", "LabMiscChargeMaster"]),
    dict(code="C2", part="C", name="Investigation, Profile & Package",
         intro="The test catalogue (LabInvestigationMaster) with its reference ranges, select options, formulae and "
               "descriptive templates; profiles and packages that bundle tests; reflex rules that suggest a follow-up "
               "test; and LOINC terminology mapping.",
         tables=["LabInvestigationMaster", "LabInvestigationProfileHeader", "LabInvestigationProfileDetail",
                 "LabReferenceRangeMaster", "LabParameterOptionMaster", "LabFormulaParameterMaster",
                 "LabDescriptiveTestTemplate", "LabReflexRule", "InvestigationLoincMapping", "LoincConcept", "StageLoinc"]),
    dict(code="C3", part="C", name="Microbiology",
         intro="Organisms, antibiotics and antibiotic panels for culture & sensitivity reporting, interpretive "
               "breakpoints (CLSI / EUCAST) and expert rules.",
         tables=["LabOrganismMaster", "LabAntibioticMaster", "LabAntibioticPanelMaster", "LabAntibioticPanelDetail",
                 "LabBreakpointMaster", "LabExpertRuleMaster"]),
    dict(code="C4", part="C", name="Rate Cards, Franchise & Corporate (B2B)",
         intro="Price lists (B2C, Franchise, Corporate rate cards), franchise partners with credit limit, prepaid "
               "wallet and pre-printed barcode series, and corporate clients with their negotiated rates.",
         tables=["LabRateCardMaster", "LabRateCardDetail", "LabFranchiseMaster", "LabFranchiseCreditLimitMaster",
                 "LabFranchiseWallet", "LabFranchiseWalletTransaction", "LabFranchiseBarcodeSeries",
                 "LabFranchiseBarcodePool", "CorporateMaster", "CorporateHospitalRateMaster"]),
    dict(code="C5", part="C", name="Lab Order Booking & B2B Invoicing",
         intro="A lab bill (LabOrder) for a patient, walk-in (B2C) or through a franchise / corporate (B2B), with its "
               "test / profile lines and misc charges. Its payment is a PaymentHeader with ModuleCode = 'LAB'. B2B "
               "orders are invoiced periodically to the partner.",
         tables=["LabOrder", "LabOrderItem", "LabOrderMiscCharge", "LabReflexRecommendation", "LabAiSuggestionFeedback",
                 "B2BInvoice", "B2BInvoiceItem"]),
    dict(code="C6", part="C", name="Sample Collection & Logistics",
         intro="One SampleCollection row per test (or profile) of an order: barcode, collection status, transfer "
               "between branches, receipt at the processing lab and outsourcing. Every status change is logged.",
         tables=["SampleCollection", "SampleCollectionStatus", "LabSampleStatusLog", "SampleTransferAudit",
                 "LabOutsourceTracking", "LabBarcodeConfig", "LabBarcodeSequence"]),
    dict(code="C7", part="C", name="Result Entry, Approval & Report Dispatch",
         intro="Results per test (labentrydetails) through draft > entry > validation > approval, the pathologist "
               "approval flow and its sign-offs, un-approval history, critical value communication, report remarks, "
               "default signatories and the e-mail / WhatsApp dispatch log.",
         tables=["labentrydetails", "Reportentrystatus", "LabReportTestRemarks", "LabCriticalCommunication",
                 "LabApprovalFlow", "LabApprovalFlowLevel", "LabApprovalFlowApprover", "LabReportApproval",
                 "LabReportUnapproval", "LabReportDefaultSignatory", "LabReportEmailLog", "LabReportWhatsAppLog",
                 "LabExternalDocument", "LabFtpSettings"]),
    dict(code="C8", part="C", name="Quality Control & Equipment",
         intro="Internal QC (control materials, lots, targets, runs and Westgard results), external quality "
               "assessment (EQAS programmes, cycles and results), CAPA, and the equipment register with calibration, "
               "preventive maintenance and breakdowns.",
         tables=["IqcMaterial", "IqcLot", "IqcTarget", "IqcRun", "IqcResult", "QcEqasProgram", "QcEqasProgramTest",
                 "QcEqasCycle", "QcEqasResult", "QcCapa", "QcEquipmentType", "QcEquipment", "QcEquipmentCalibration",
                 "QcEquipmentMaintenance", "QcEquipmentBreakdown"]),
    dict(code="C9", part="C", name="Bill of Materials & Reagent Consumption",
         intro="Reagents and consumables used per test on an analyzer (BOM, versioned) and per sample type (kit), and "
               "the consumption posted when samples are processed, priced at item cost.",
         tables=["BomTest", "BomTestLine", "BomSampleKit", "QcConsumption", "QcConsumptionLine", "QcConsumptionLog"]),
    dict(code="C10", part="C", name="Doctor Incentive Programme (Doctor IP)",
         intro="Commission paid to referring doctors on lab business: the commission scheme per doctor (by "
               "department / category / test), the periodic computation over lab orders, and access control for the "
               "Doctor IP screens.",
         tables=["Doctor_IP_Hdr", "Doctor_IP_Dtl", "Doctor_IP_Commission_Hdr", "Doctor_IP_Commission_Dtl",
                 "Doctor_IP_Commission_RunLog", "DoctorIpAccessSetting", "DoctorIpAccessLog"]),
]

TABLE_DESC = {
    # A1
    "CompanyMaster": "The company (tenant) using the system: legal name, GSTIN, PAN, contact and logo.",
    "Branchmaster": "Branches of the company. IsHOBranch marks the head office; IsLab marks a branch that runs a laboratory.",
    "HospitalSettings": "Per-branch settings: letterhead details, OPD registration validity, notification switches, lab behaviour (barcode at billing, sample collection mandatory, pathologist approval, critical value rules) and print options.",
    "DepartmentMaster": "Departments (clinical and lab, e.g. Haematology, Biochemistry). Lab tests, categories, methods and analyzers belong to a department.",
    "PrintTemplate": "Designable print layouts (bills, reports) per company, with a working draft and the published layout.",
    "PrintTemplateVersion": "Every published version of a print template, kept for history and roll-back.",
    "PrintTemplateAssignment": "Which print template a branch uses for each kind of document.",
    # A2
    "Users": "Application logins. User_Type: U = system user, D = doctor, F = franchise, C = corporate; ReferenceUserID links an external login to its franchise / corporate. Also holds staff attributes (phlebotomist, pathologist, technician).",
    "roles": "Roles (Administrator, Manager, Doctor, Receptionist, Franchise ...). Permissions are granted to roles.",
    "Userroles": "Roles held by a user, optionally per branch.",
    "UserBranches": "Branches a user may sign in to, with the employee code used in that branch.",
    # A3
    "CountryMaster": "Countries with their currency.",
    "StateMaster": "States / provinces of a country.",
    "DistrictMaster": "Districts of a state.",
    "CityMaster": "Cities / towns of a district.",
    "AreaMaster": "Areas / localities of a city (used for home collection routing).",
    "IdentificationTypeMaster": "Identity document types (Aadhaar, PAN, passport ...).",
    "MaritalStatusMaster": "Marital status values.",
    "OccupationMaster": "Occupation values.",
    "ReligionMaster": "Religion values.",
    "RelationMaster": "Relationship to the patient (self, spouse, father ...), used for guardians and membership family members.",
    "LanguageMaster": "Preferred communication languages.",
    "DisabilityTypeMaster": "Disability types (RPwD Act categories) used on disability certificates.",
    # A4
    "PatientMaster": "One row per patient (UHID = PatientCode): demographics, contact, address, identity document, referral doctor, home collection location and patient-portal login.",
    "PatientCodeCounter": "Running number for patient codes per branch and financial year.",
    "ReferralDoctorMaster": "External doctors who refer patients (for lab orders and patient registration).",
    # A5
    "PaymentHeader": "The bill of any module (ModuleCode LAB / OPD / MEM / PHR, ModuleRefId = the record billed): totals, line and header discount, GST, round-off, amount paid, balance and payment status, membership points.",
    "PaymentLineItem": "Billed lines of a PaymentHeader: original amount, line discount, membership discount, GST split and net amount. ModuleLineRefId points at the module's own line.",
    "PaymentDetail": "Each payment received against a bill: payment method, amount, reference (UPI / cheque / card) and receipt number.",
    "PaymentMethodMaster": "Payment methods and which reference details each one requires.",
    "DiscountTypeMaster": "Discount types allowed at billing (percentage band or flat amount).",
    "ReceiptSequence": "Running receipt number per branch and financial year.",
    "ReceiptNoFormatMap": "Old receipt numbers mapped to the new numbering format after a one-time conversion.",
    "BillingSubmission": "Guard against duplicate bills: one row per save request (request key, items signature, stage).",
    # A6
    "BillCancellation": "A cancellation of an OPD or LAB bill (F = full, P = partial) with the amount and reason.",
    "BillCancellationItem": "The bill lines cancelled and the amount reversed per line (with GST).",
    "BillRefund": "Money refunded to the patient against a cancellation.",
    "CancellationSequence": "Running cancellation number per module, branch and financial year.",
    # A7
    "CashClosing": "A cashier's day-end closing for one module: opening float, cash in / out, petty cash, expected vs counted cash, denominations, hand-over and supervisor verification.",
    "CashClosingLine": "Per-mode / per-module totals included in a closing (cash and non-cash).",
    "CashClosingPetty": "Petty-cash floats settled in a closing.",
    # A8
    "MembershipPlan": "Membership plans: fee, validity, family size, points earning / redemption rules and expiry.",
    "MembershipPlanBenefit": "Discounts and free services a plan gives, by scope (all / department / test ...).",
    "MembershipCard": "A membership card issued to a primary patient: plan, validity, fee receipt, points balance and status.",
    "MembershipCardMember": "Patients covered by a card (primary and family members).",
    "MembershipLedger": "Points and discount movements of a card (issue, earn, redeem, reverse, expiry) with running balance.",
    "MembershipRedeemOtp": "One-time passwords sent to confirm a points redemption.",
    "MembershipPointsWhatsAppLog": "WhatsApp messages sent for points earned / redeemed.",
    # A9
    "ApprovalModule": "Masters that can be put under approval.",
    "ApprovalMatrix": "Approval set-up per company and module: company-wise (C, approved in head office) or branch-wise (B).",
    "ApprovalMatrixApprover": "Approvers of a matrix: active system users with a Manager role.",
    "ApprovalRequest": "A submitted new record or change awaiting approval, with old / new values; status P pending, A approved, S sent back, X replaced.",
    # B1
    "DoctorMaster": "Doctors (consulting and referral): registration number, specialities, contact and linked login.",
    "DoctorSpecialityMaster": "Medical specialities (General Medicine, Paediatrics ...).",
    "DoctorSubSpecialityMaster": "Sub-specialities within a speciality.",
    "DoctorDepartmentMap": "Departments a doctor works in.",
    "DoctorBranchMap": "Branches a doctor consults at.",
    "ClinicalUnitMaster": "Clinical units of a department / speciality headed by a consultant in charge.",
    # B2
    "DoctorRoomMaster": "Consultation rooms per branch and floor.",
    "DoctorRoomMapping": "Rooms a doctor uses.",
    "DoctorScheduleMaster": "Weekly OPD schedule per doctor, branch and room: day, time, slot length and patient limits.",
    "DoctorScheduleException": "Dates a doctor's schedule does not apply (leave, holiday, extra session).",
    # B3
    "ServiceMaster": "OPD service catalogue: consultation and other services with charges, GST and discount rules.",
    "DoctorConsultingFeeMap": "The consultation service (fee) a doctor charges in a branch, with follow-up grace time.",
    "DoctorVisitProcessConfig": "Rules for a visit by speciality / doctor: payment timing, vitals / diagnosis / ICD-10 required, billing required.",
    # B4
    "PatientOPDService": "An OPD visit: patient, consulting doctor, schedule slot, visit date, OPD bill number, token number and visit status.",
    "PatientOPDServiceItem": "Services billed in an OPD visit (consultation, registration, other services).",
    "OPDBillSequence": "Running bill number per branch, financial year and module.",
    "OPDTokenSequence": "Running token number per branch, day and module (OPD / LAB / B2B).",
    "OPDTokenStatusLog": "Token and visit status changes of an OPD visit, for the queue monitor and audit.",
    # B5
    "EmrTemplates": "Consultation (EMR) templates.",
    "EmrTemplateSections": "Sections of an EMR template.",
    "EmrTemplateFields": "Fields of a template section: type, options and whether required.",
    "EmrTemplateSpecialityMap": "Specialities that use a template.",
    "EmrPatientConsultation": "The consultation record of an OPD visit: template data (JSON), referral and follow-up.",
    "EmrInvestigationMaster": "Investigations a doctor can advise from the consultation screen.",
    "EmrMedicationMaster": "Medicines a doctor can prescribe from the consultation screen.",
    "PatientVitals": "Vitals recorded for a patient: height, weight, BMI, BP, pulse, SpO2, temperature, glucose, pain score.",
    "tbl_VideoConsultation": "Video consultations of an OPD visit: meeting links for doctor and patient, schedule and status.",
    "tbl_VideoSystemConfig": "Video consultation provider settings.",
    # B6
    "VaccineMaster": "Vaccines with dose schedule, default route / site and UIP flag.",
    "PatientVaccination": "A vaccine dose given to a patient: batch, expiry, route, site and next due date.",
    "CertificateTypeMaster": "Certificate types (fitness, sickness, disability ...) with numbering prefix, validity and fee service.",
    "CertificatePurposeMaster": "Purposes offered per certificate type.",
    "CertificateDoctorProfile": "Doctors allowed to sign certificates, with registration details, signature and stamp.",
    "CertificateSequence": "Running certificate number per branch, type and financial year.",
    "PatientCertificate": "A medical certificate for a patient: type, purpose, validity, body (JSON), fee, status D draft / I issued / C cancelled and verification token.",
    "CertificateNotificationLog": "E-mail / WhatsApp messages sent for a certificate.",
    "ConsentMaster": "Consent form templates by type, procedure and language, with version and witness rule.",
    # B7
    "DoctorCommissionConfig": "Doctor revenue-share rules by doctor / speciality / revenue type / service / corporate / TPA, with validity.",
    "DoctorPayoutProfile": "How a doctor is paid: payee, PAN, TDS and bank / UPI details.",
    "DoctorDisbursal": "The doctor's share computed per visit / bill line, its approval and payment status, and the settlement it was paid in.",
    "DoctorBillingAdjustment": "Approved adjustments (recoveries, additions) to a doctor's share.",
    "DoctorSettlement": "A periodic settlement to a doctor: gross share, recoveries, TDS, net payable, approval and payment.",
    # C1
    "LabTestCategoryMaster": "Test categories within a department; whether a barcode / sample collection is required.",
    "LabTestSubCategoryMaster": "Sub-categories within a test category.",
    "LabSampleTypeMaster": "Sample (specimen) types: container, volume, storage temperature and rejection criteria.",
    "LabTestMethodMaster": "Test methods (e.g. ELISA, CLIA) per department.",
    "LabUnitMaster": "Units of measurement for results and sample quantity, with conversion factor.",
    "tbl_mst_analyzer": "Analyzers (instruments) per department and their interface protocol.",
    "LabSampleRejectionMaster": "Standard sample rejection codes and reasons.",
    "LabSampleRejectionReasonMaster": "Sample rejection reasons offered at collection / receipt, optionally per sample type.",
    "LabReportingConditionMaster": "Standard conditions / disclaimers printed on reports, per branch.",
    "LabMiscChargeMaster": "Miscellaneous charges added to a lab bill (home collection, urgent ...), with GST and discount rules.",
    # C2
    "LabInvestigationMaster": "The test catalogue: name, reporting name, department / category / sub-category, sample type, method, unit, reporting type, TAT, NABL, MRP, applicability (age / gender) and documents required at billing.",
    "LabInvestigationProfileHeader": "Profiles (Profile_Type 1, built on a profile test) and packages (Profile_Type 2, with discount and validity dates).",
    "LabInvestigationProfileDetail": "Tests included in a profile / package, in print sequence.",
    "LabReferenceRangeMaster": "Normal / critical reference ranges per test by age, gender, pregnancy trimester, method and unit.",
    "LabParameterOptionMaster": "Fixed result options of a 'Select' test (e.g. Positive / Negative) and which are abnormal.",
    "LabFormulaParameterMaster": "Calculated tests: the formula over other tests and the rounding.",
    "LabDescriptiveTestTemplate": "Report templates for descriptive / imaging tests: sections, default content and imaging details.",
    "LabReflexRule": "Reflex rules: when a trigger test result meets a condition, suggest another test.",
    "InvestigationLoincMapping": "LOINC code mapped to a test, with review and approval.",
    "LoincConcept": "LOINC terminology (imported reference data).",
    "StageLoinc": "Staging table for LOINC import jobs.",
    # C3
    "LabOrganismMaster": "Micro-organisms with Gram type, category and WHONET code.",
    "LabAntibioticMaster": "Antibiotics with class, route and WHONET code.",
    "LabAntibioticPanelMaster": "Antibiotic panels per Gram type / organism category / sample type.",
    "LabAntibioticPanelDetail": "Antibiotics of a panel with display order and tier.",
    "LabBreakpointMaster": "Interpretive breakpoints (S / R) per organism and antibiotic, standard (CLSI / EUCAST) and method.",
    "LabExpertRuleMaster": "Expert rules (intrinsic resistance, alerts) applied to culture results.",
    # C4
    "LabRateCardMaster": "A rate card (price list) per branch and type: B2C, Franchise or Corporate, with validity.",
    "LabRateCardDetail": "Rates of a rate card per test / profile / package, and whether discount is allowed.",
    "LabFranchiseMaster": "Franchise partners (collection centres, franchise labs, pickup points): onboarding, agreement, suspension, notification / barcode / report header options and credit-limit bypass.",
    "LabFranchiseCreditLimitMaster": "Credit terms of a franchise: prepaid wallet or postpaid credit, limit, days, grace, deposit and interest.",
    "LabFranchiseWallet": "Current wallet balance of a prepaid franchise.",
    "LabFranchiseWalletTransaction": "Wallet top-ups (CREDIT) and bill deductions (DEBIT) with balance after.",
    "LabFranchiseBarcodeSeries": "Pre-printed barcode series issued to a franchise.",
    "LabFranchiseBarcodePool": "Individual barcodes of a series and their use (order, sample, test) or void.",
    "CorporateMaster": "Corporate clients billed on credit: type, validity, credit limit / days and billing cycle.",
    "CorporateHospitalRateMaster": "Negotiated corporate rates / discounts per service type and service.",
    # C5
    "LabOrder": "A lab bill / order: patient, branch, bill number, token, collection type, phlebotomist, B2B partner (AgentType + B2BAgentID), referral doctor, documents (prescription, OVD, consent) and totals.",
    "LabOrderItem": "Tests (Type I) and profiles / packages (Type P) ordered, with B2C price and B2B rate.",
    "LabOrderMiscCharge": "Miscellaneous charges on an order with discount, membership discount and GST.",
    "LabReflexRecommendation": "Reflex test suggestions raised on an order and what the user did with them.",
    "LabAiSuggestionFeedback": "Feedback on AI test suggestions (accepted / dismissed) to improve future suggestions.",
    "B2BInvoice": "A periodic invoice to a franchise (F) or corporate (C) for its B2B orders: totals, paid, balance and status.",
    "B2BInvoiceItem": "Lab orders included in a B2B invoice.",
    # C6
    "SampleCollection": "One row per test / profile sample of an order: barcode, collection status and time, department / category, transfer between branches, receipt, outsourcing and rejection.",
    "SampleCollectionStatus": "Sample collection statuses (Pending, Collected, Re-collect, Rejected).",
    "LabSampleStatusLog": "Every sample status change with who, when and the rejection reason.",
    "SampleTransferAudit": "Transfers of samples between branches and their receipt.",
    "LabOutsourceTracking": "Samples sent to an outside lab and when the result came back.",
    "LabBarcodeConfig": "Barcode format per branch (prefix, digits, sample type suffix).",
    "LabBarcodeSequence": "Running barcode number per branch and financial year.",
    # C7
    "labentrydetails": "The result of a test on a sample: value / template, abnormal flag, remarks, report status and the draft / submit / validate / approve timestamps.",
    "Reportentrystatus": "Report statuses (Draft, Report Entry, Validated, Re-collected, Approved).",
    "LabReportTestRemarks": "Remarks printed on the report per test / profile group of an order.",
    "LabCriticalCommunication": "Critical value communication: who was informed, how, when, read-back, and message delivery.",
    "LabApprovalFlow": "Pathologist approval flows per branch / department / categories with the number of levels.",
    "LabApprovalFlowLevel": "Levels of an approval flow.",
    "LabApprovalFlowApprover": "Users who approve at a level.",
    "LabReportApproval": "Each approval sign-off of a test result (level, final level, approver, date).",
    "LabReportUnapproval": "Un-authorisation of an approved result: previous / new status, reason and previous approvers.",
    "LabReportDefaultSignatory": "Default signatories printed on reports per branch / department and slot.",
    "LabReportEmailLog": "E-mails of final reports (sent, failed, skipped) with attempts.",
    "LabReportWhatsAppLog": "WhatsApp messages of final reports with attempts.",
    # C8
    "IqcMaterial": "Internal QC control materials (level, matrix, manufacturer).",
    "IqcLot": "Lots of a control material with expiry and open dates.",
    "IqcTarget": "Target mean / SD of a lot per analyzer and test, and the Westgard rules applied.",
    "IqcRun": "A QC run on an analyzer for a test: rule violations, root cause, corrective action and CAPA.",
    "IqcResult": "Values of a QC run per target with Z-score and flags.",
    "QcEqasProgram": "External quality assessment programmes the lab is enrolled in.",
    "QcEqasProgramTest": "Tests covered by an EQAS programme.",
    "QcEqasCycle": "Cycles (samples) of an EQAS programme with due / submitted / evaluated dates.",
    "QcEqasResult": "Our result vs target per test in a cycle, Z-score and performance.",
    "QcCapa": "Corrective and preventive actions raised from QC, EQAS or equipment events.",
    "QcEquipmentType": "Equipment types with default calibration and preventive maintenance frequency.",
    "QcEquipment": "Equipment register: asset, make / model / serial, location, warranty / AMC contract and status.",
    "QcEquipmentCalibration": "Calibrations of equipment with certificate and next due date.",
    "QcEquipmentMaintenance": "Preventive / corrective maintenance done on equipment.",
    "QcEquipmentBreakdown": "Equipment breakdowns: problem, vendor call, resolution, cost and QC verification.",
    # C9
    "BomTest": "Bill of materials of a test on an analyzer (versioned): rerun and dead-volume allowance.",
    "BomTestLine": "Items (reagents / consumables) and quantities of a test BOM.",
    "BomSampleKit": "Items consumed per sample of a sample type (tube, needle ...).",
    "QcConsumption": "Consumption posted for a test / profile of an order: BOM used, store and material cost.",
    "QcConsumptionLine": "Items consumed with quantity and cost.",
    "QcConsumptionLog": "Errors raised while posting consumption.",
    # C10
    "Doctor_IP_Hdr": "Doctor incentive scheme: doctor, speciality, branch, validity and payout frequency.",
    "Doctor_IP_Dtl": "Commission rate of a scheme by department / category / sub-category / test or profile.",
    "Doctor_IP_Commission_Hdr": "A computed commission statement for a doctor and period.",
    "Doctor_IP_Commission_Dtl": "Lab order lines in a commission statement with billed amount and commission.",
    "Doctor_IP_Commission_RunLog": "Runs of the automatic commission computation.",
    "DoctorIpAccessSetting": "Access code and lock-out settings protecting the Doctor IP screens.",
    "DoctorIpAccessLog": "Access attempts to the Doctor IP screens.",
}

# Column notes that a name alone does not explain (codes, meanings).
COL_DESC = {
    ("Users", "User_Type"): "Login type: U = system user, D = doctor, F = franchise, C = corporate.",
    ("Users", "ReferenceUserID"): "For a franchise / corporate login: the Franchise_ID / Corporate_ID it belongs to.",
    ("Branchmaster", "IsHOBranch"): "1 = head office branch (company-wise approvals are worked here).",
    ("Branchmaster", "IsLab"): "1 = the branch runs a laboratory.",
    ("PatientMaster", "PatientCode"): "UHID shown to users, numbered per branch and financial year.",
    ("PatientMaster", "IsLoginGenerated"): "1 = a patient-portal login has been created.",
    ("PaymentHeader", "ModuleCode"): "Module billed: LAB = lab order, OPD = OPD visit, MEM = membership card, PHR = pharmacy sale.",
    ("PaymentHeader", "ModuleRefId"): "ID of the record billed in that module (LabOrder.LabOrderId for LAB, PatientOPDService.OPDServiceId for OPD ...).",
    ("PaymentHeader", "PaymentStatus"): "P = paid, R = partially paid, U = unpaid.",
    ("PaymentHeader", "HeaderDiscountType"): "Bill-level discount: P = percentage, M = amount, D = department-wise.",
    ("PaymentHeader", "NetAmount"): "Bill amount after all discounts, with GST and round-off.",
    ("PaymentHeader", "BalanceDue"): "NetAmount - TotalPaid.",
    ("PaymentLineItem", "ServiceType"): "Kind of line: Test, Profile, Package, Consulting, Service, Misc, Membership.",
    ("PaymentLineItem", "ModuleLineRefId"): "The module's own line (LabOrderItem / PatientOPDServiceItem).",
    ("PaymentDetail", "ReceiptNo"): "Receipt number printed for this payment.",
    ("BillCancellation", "CancellationType"): "F = full, P = partial.",
    ("BillCancellation", "ModuleCode"): "LAB or OPD.",
    ("BillCancellation", "ModuleRefId"): "LabOrder.LabOrderId (LAB) or PatientOPDService.OPDServiceId (OPD).",
    ("CashClosing", "Status"): "S = submitted, B = sent back, V = verified.",
    ("CashClosing", "Module"): "LAB or OPD.",
    ("CashClosingLine", "Kind"): "Type of total in the line (receipt, refund, petty cash ...).",
    ("MembershipLedger", "TxnType"): "ISSUE, MEMBER, EARN, REDEEM, DISCOUNT, REVERSE, RESTORE, STATUS (expiry / status change).",
    ("MembershipCard", "Status"): "Active or Blocked.",
    ("MembershipPlanBenefit", "Scope"): "What the benefit applies to (All, department, test ...); ScopeRefId names the item.",
    ("ApprovalMatrix", "Scope"): "C = company-wise (approved in the head office branch), B = branch-wise.",
    ("ApprovalRequest", "Action_Type"): "CREATE = new record (kept inactive until approved), UPDATE = change to an approved record.",
    ("ApprovalRequest", "Status"): "P = pending, A = approved, S = sent back, X = replaced by a newer submission / closed.",
    ("ApprovalRequest", "Old_Values"): "JSON list of {Field, Value} before the change (UPDATE).",
    ("ApprovalRequest", "New_Values"): "JSON list of {Field, Value} submitted.",
    ("ApprovalRequest", "Payload"): "UPDATE: the save request applied when approved.",
    ("ApprovalRequest", "Entity_ID"): "ID of the record in the module's master (Franchise_ID, Corporate_ID, Profile_ID ...).",
    ("PatientOPDService", "Status"): "Visit status: Registered, Consulting, Completed.",
    ("PatientOPDService", "TokenNo"): "Daily token number in the queue.",
    ("ServiceMaster", "ServiceType"): "Consulting or Service.",
    ("ServiceMaster", "IsRegistration"): "1 = registration fee service.",
    ("PatientCertificate", "Status"): "D = draft, I = issued, C = cancelled.",
    ("PatientCertificate", "VerifyToken"): "Token in the QR code used to verify the certificate online.",
    ("DoctorDisbursal", "VisitId"): "The OPD visit (PatientOPDService.OPDServiceId).",
    ("DoctorDisbursal", "BillId"): "The bill (PaymentHeader.PaymentHeaderId).",
    ("LabInvestigationMaster", "Reporting_Type"): "How the result is entered: Numeric, Select, Text, Descriptive, Template, Culture, Image.",
    ("LabInvestigationMaster", "Reporting_Name"): "Name printed on the report (defaults to the test name).",
    ("LabInvestigationMaster", "Age_Operator"): "With Applicable_Age: the age the test applies to (e.g. >=, <).",
    ("LabInvestigationMaster", "OVD_Document"): "1 = an officially valid identity document is required at billing.",
    ("LabInvestigationMaster", "Has_External_Document"): "1 = the test has an external document.",
    ("LabInvestigationMaster", "Status"): "1 = active (offered in billing), 0 = inactive.",
    ("LabInvestigationProfileHeader", "Profile_Type"): "1 = profile (Test_ID = its profile test), 2 = package.",
    ("LabInvestigationProfileHeader", "Status"): "1 = active (offered in billing), 0 = inactive / awaiting approval.",
    ("LabRateCardMaster", "Rate_Type"): "B2C, Franchise or Corporate.",
    ("LabRateCardDetail", "Item_Type"): "Test, Profile or Package.",
    ("LabRateCardDetail", "Item_ID"): "Test_ID (Test) or Profile_ID (Profile / Package).",
    ("LabFranchiseMaster", "Franchise_Type"): "1 = collection centre, 2 = franchise lab, 3 = pickup point, 4 = marketing.",
    ("LabFranchiseMaster", "Status"): "1 = suspended (see Suspension_Reason), 0 = working.",
    ("LabFranchiseMaster", "IsActive"): "1 = active; a franchise awaiting approval is kept 0.",
    ("LabFranchiseCreditLimitMaster", "Credit_Facility_Type"): "1 = prepaid (wallet, no credit terms), 2 = postpaid (credit).",
    ("LabFranchiseWalletTransaction", "TransactionType"): "CREDIT = top-up, DEBIT = bill deducted.",
    ("LabFranchiseBarcodePool", "Status"): "1 = available, 2 = used (voided barcodes carry VoidedDate).",
    ("CorporateMaster", "Corporate_Type"): "Services covered: ALL, OPD, IPD, LAB, MED, GENERAL.",
    ("CorporateMaster", "Status"): "1 = active, 0 = inactive / awaiting approval.",
    ("LabOrder", "CollectionType"): "Lab (walk-in), Home Collection or B2BCollector.",
    ("LabOrder", "IsB2B"): "1 = booked for a franchise / corporate (B2B), 0 = B2C.",
    ("LabOrder", "AgentType"): "B2B partner type: F = franchise, C = corporate.",
    ("LabOrder", "B2BAgentID"): "Franchise_ID (AgentType F) or Corporate_ID (AgentType C).",
    ("LabOrder", "B2BTotal"): "Order total at the partner's B2B rates.",
    ("LabOrderItem", "Type"): "I = investigation (test), P = profile / package.",
    ("LabOrderItem", "InvestigationId"): "LabInvestigationMaster.Test_ID when Type = I, LabInvestigationProfileHeader.Profile_ID when Type = P.",
    ("LabOrderItem", "B2BRate"): "Rate charged to the B2B partner.",
    ("B2BInvoice", "PartnerType"): "F = franchise, C = corporate.",
    ("B2BInvoice", "PartnerId"): "Franchise_ID (F) or Corporate_ID (C).",
    ("B2BInvoice", "Status"): "U = unpaid, R = partially paid, P = paid, C = cancelled.",
    ("SampleCollection", "CollectionstatusID"): "Collection status (SampleCollectionStatus).",
    ("SampleCollection", "IsoutSource"): "1 = sent to an outside lab.",
    ("SampleCollection", "DepartmentD"): "Legacy column (misspelt duplicate of DepartmentID); not used.",
    ("SampleCollection", "TestsubcategotyID"): "Legacy column (misspelt duplicate of TestsubcategoryID); not used.",
    ("SampleCollection", "RequiresManualBarcode"): "1 = a barcode must be entered by hand (pre-printed sticker).",
    ("LabSampleStatusLog", "Source"): "Where the change came from (TRIGGER, BACKFILL ...).",
    ("SampleTransferAudit", "ActionType"): "TRANSFER or RECEIVE.",
    ("labentrydetails", "ReportStatusId"): "Report status (Reportentrystatus): Draft > Report Entry > Validated > Approved.",
    ("labentrydetails", "AbnormalFlag"): "Flag against the reference range (H / L / critical).",
    ("labentrydetails", "Template_Html"): "Result body for template / descriptive tests.",
    ("LabCriticalCommunication", "ReadBack"): "1 = the person informed read the value back.",
    ("LabReportApproval", "IsFinalLevel"): "1 = the last level of the flow (result released).",
    ("LabReportEmailLog", "Status"): "Sent, Failed or Skipped.",
    ("Doctor_IP_Dtl", "Item_Type"): "Test or Profile.",
    ("Doctor_IP_Dtl", "Test_ID"): "Test_ID (Item_Type Test) or Profile_ID (Item_Type Profile).",
    ("Doctor_IP_Commission_Dtl", "Item_Type"): "Test or Profile.",
    ("Doctor_IP_Commission_Dtl", "Test_ID"): "Test_ID or Profile_ID according to Item_Type.",
}

# Conditional (type-dependent) references: shown as relations of type 'Conditional'.
CONDITIONAL = {
    ("PaymentHeader", "ModuleRefId"): ["LabOrder", "PatientOPDService", "MembershipCard"],
    ("BillCancellation", "ModuleRefId"): ["LabOrder", "PatientOPDService"],
    ("BillRefund", "ModuleRefId"): ["LabOrder", "PatientOPDService"],
    ("BillingSubmission", "ModuleRefId"): ["LabOrder", "PatientOPDService"],
    ("PaymentLineItem", "ModuleLineRefId"): ["LabOrderItem", "PatientOPDServiceItem"],
    ("LabOrder", "B2BAgentID"): ["LabFranchiseMaster", "CorporateMaster"],
    ("B2BInvoice", "PartnerId"): ["LabFranchiseMaster", "CorporateMaster"],
    ("LabOrderItem", "InvestigationId"): ["LabInvestigationMaster", "LabInvestigationProfileHeader"],
    ("LabRateCardDetail", "Item_ID"): ["LabInvestigationMaster", "LabInvestigationProfileHeader"],
    ("Doctor_IP_Dtl", "Test_ID"): ["LabInvestigationMaster", "LabInvestigationProfileHeader"],
    ("Doctor_IP_Commission_Dtl", "Test_ID"): ["LabInvestigationMaster", "LabInvestigationProfileHeader"],
    ("ApprovalRequest", "Entity_ID"): ["LabFranchiseMaster", "CorporateMaster", "LabInvestigationProfileHeader"],
}
CONDITION_TEXT = {
    ("PaymentHeader", "ModuleRefId"): "by ModuleCode",
    ("BillCancellation", "ModuleRefId"): "by ModuleCode",
    ("BillRefund", "ModuleRefId"): "by ModuleCode",
    ("BillingSubmission", "ModuleRefId"): "by ModuleCode",
    ("PaymentLineItem", "ModuleLineRefId"): "by the bill's ModuleCode",
    ("LabOrder", "B2BAgentID"): "by AgentType",
    ("B2BInvoice", "PartnerId"): "by PartnerType",
    ("LabOrderItem", "InvestigationId"): "by Type",
    ("LabRateCardDetail", "Item_ID"): "by Item_Type",
    ("Doctor_IP_Dtl", "Test_ID"): "by Item_Type",
    ("Doctor_IP_Commission_Dtl", "Test_ID"): "by Item_Type",
    ("ApprovalRequest", "Entity_ID"): "by Module_Code",
}

# Logical references not declared as foreign keys: normalised column name -> table.
ALIAS = {
    "patientid": "PatientMaster", "primarypatientid": "PatientMaster",
    "laborderid": "LabOrder", "laborderitemid": "LabOrderItem",
    "investigationid": "LabInvestigationMaster", "testid": "LabInvestigationMaster",
    "triggertestid": "LabInvestigationMaster", "suggesttestid": "LabInvestigationMaster",
    "samplecollectionid": "SampleCollection", "labentrydetailid": "labentrydetails",
    "branchid": "Branchmaster", "sourcebranchid": "Branchmaster", "targetbranchid": "Branchmaster",
    "parentbranchid": "Branchmaster", "issuebranchid": "Branchmaster", "samplebranchid": "Branchmaster",
    "createdbranchid": "Branchmaster",
    "companyid": "CompanyMaster",
    "doctorid": "DoctorMaster", "consultingdoctorid": "DoctorMaster", "refertodoctorid": "DoctorMaster",
    "consultantinchargedoctorid": "DoctorMaster", "refdoctorid": "DoctorMaster",
    "referraldoctorid": "ReferralDoctorMaster",
    "specialityid": "DoctorSpecialityMaster", "refertospecialityid": "DoctorSpecialityMaster",
    "primaryspecialityid": "DoctorSpecialityMaster", "secondaryspecialityid": "DoctorSpecialityMaster",
    "subspecialityid": "DoctorSubSpecialityMaster",
    "deptid": "DepartmentMaster", "departmentid": "DepartmentMaster",
    "categoryid": "LabTestCategoryMaster", "testcategoryid": "LabTestCategoryMaster",
    "subcategoryid": "LabTestSubCategoryMaster", "testsubcategoryid": "LabTestSubCategoryMaster",
    "sampletypeid": "LabSampleTypeMaster", "applicablesampletypeid": "LabSampleTypeMaster",
    "methodid": "LabTestMethodMaster",
    "unitid": "LabUnitMaster", "samplequantityunitid": "LabUnitMaster",
    "profileid": "LabInvestigationProfileHeader", "packageid": "LabInvestigationProfileHeader",
    "franchiseid": "LabFranchiseMaster", "corporateid": "CorporateMaster",
    "analyzerid": "tbl_mst_analyzer",
    "organismid": "LabOrganismMaster", "antibioticid": "LabAntibioticMaster", "panelid": "LabAntibioticPanelMaster",
    "flowid": "LabApprovalFlow", "levelid": "LabApprovalFlowLevel",
    "opdserviceid": "PatientOPDService", "feeopdserviceid": "PatientOPDService", "visitid": "PatientOPDService",
    "serviceid": "ServiceMaster", "feeserviceid": "ServiceMaster",
    "scheduleid": "DoctorScheduleMaster", "roomid": "DoctorRoomMaster", "floorid": "FloorMaster",
    "consultationid": "EmrPatientConsultation",
    "paymentheaderid": "PaymentHeader", "feepaymentheaderid": "PaymentHeader", "usedpaymentheaderid": "PaymentHeader",
    "billid": "PaymentHeader",
    "paymentdetailid": "PaymentDetail", "paymentmethodid": "PaymentMethodMaster",
    "cardid": "MembershipCard", "renewedfromcardid": "MembershipCard", "membershipcardid": "MembershipCard",
    "planid": "MembershipPlan", "ledgerid": "MembershipLedger",
    "cancellationid": "BillCancellation",
    "certificateid": "PatientCertificate", "reissueofid": "PatientCertificate",
    "purposeid": "CertificatePurposeMaster", "vaccineid": "VaccineMaster",
    "invoiceid": "B2BInvoice", "seriesid": "LabFranchiseBarcodeSeries", "ratecardid": "LabRateCardMaster",
    "miscchargeid": "LabMiscChargeMaster", "labordermiscchargeid": "LabOrderMiscCharge",
    "settlementid": "DoctorSettlement", "disbursalid": "DoctorDisbursal", "commissionconfigid": "DoctorCommissionConfig",
    "doctoriphdrid": "Doctor_IP_Hdr", "commissionhdrid": "Doctor_IP_Commission_Hdr",
    "bomid": "BomTest", "itemid": "InvItem", "consumptionid": "QcConsumption", "storeid": "InvStore",
    "capaid": "QcCapa", "equipmentid": "QcEquipment", "programid": "QcEqasProgram", "programtestid": "QcEqasProgramTest",
    "cycleid": "QcEqasCycle", "lotid": "IqcLot", "materialid": "IqcMaterial", "targetid": "IqcTarget", "runid": "IqcRun",
    "supplierid": "InvSupplier", "vendorid": "InvSupplier", "contractvendorid": "InvSupplier",
    "countryid": "CountryMaster", "stateid": "StateMaster", "districtid": "DistrictMaster", "cityid": "CityMaster",
    "areaid": "AreaMaster",
    "religionid": "ReligionMaster", "occupationid": "OccupationMaster", "maritalstatusid": "MaritalStatusMaster",
    "identificationtypeid": "IdentificationTypeMaster", "relationid": "RelationMaster", "languageid": "LanguageMaster",
    "sectionid": "EmrTemplateSections", "matrixid": "ApprovalMatrix",
    "reportstatusid": "Reportentrystatus", "collectionstatusid": "SampleCollectionStatus",
    "rejectionreasonid": "LabSampleRejectionReasonMaster",
    "procedureid": "ProcedureMaster", "insurancetpaid": "InsuranceTPAMaster",
    "loinccode": "LoincConcept",
}

# Table-specific overrides of the alias (None = no reference).
OVERRIDE = {
    ("LabReflexRecommendation", "Rule_ID"): "LabReflexRule",
    ("LabSampleStatusLog", "FromStatusId"): "SampleCollectionStatus",
    ("LabSampleStatusLog", "ToStatusId"): "SampleCollectionStatus",
    ("LabReportUnapproval", "PreviousStatusId"): "Reportentrystatus",
    ("LabReportUnapproval", "NewStatusId"): "Reportentrystatus",
    ("EmrPatientConsultation", "TemplateId"): "EmrTemplates",
    ("EmrTemplateSpecialityMap", "TemplateId"): "EmrTemplates",
    ("EmrTemplateSections", "TemplateId"): "EmrTemplates",
    ("PrintTemplateVersion", "TemplateId"): "PrintTemplate",
    ("PrintTemplateAssignment", "TemplateId"): "PrintTemplate",
    ("QcEquipment", "TypeId"): "QcEquipmentType",
    ("CertificateDoctorProfile", "DoctorId"): "DoctorMaster",
    ("ApprovalMatrix", "Module_Code"): "ApprovalModule",
    ("ApprovalRequest", "Module_Code"): "ApprovalModule",
    ("CertificateTypeMaster", "FeeServiceId"): "ServiceMaster",
    ("ShiftMaster", "ShiftMaster_ID"): None,
    ("Users", "ShiftSlotId"): None, ("Users", "AssignedZoneId"): None, ("Users", "LabTechnicianShiftSlotId"): None,
    ("LabRateCardMaster", "B2CIdentity_ID"): None,
    ("MembershipPlanBenefit", "ScopeRefId"): None,
    ("CorporateHospitalRateMaster", "ReferenceMaster_ID"): None,
    ("LabFranchiseWalletTransaction", "ReferenceId"): None,
    ("QcCapa", "SourceId"): None,
    ("StageLoinc", "LoincCode"): None,
}

# Columns that refer to a user (Users.Id) when they are integers.
USER_COL = r"^(Created|Modified|Updated|LastModified|Approved|Prepared|Paid|Closed|Cancelled|Voided|Used|Received|Sent|Transferred|Action|Verified|Requested|Actioned|Recorded|Entered|Consumed|Computed|Generated|Issued|Published|Assigned|Triggered|Unapproved|Changed|Reported|Resolved|Corrected|Proposed|Bypass_Updated|Discount(Approved|Entered)|PreviousApproved|Done|Rejected|Collected|Phlebotomist)_?(By|ById|ByUserId)?$|^(UserId|RecordedByUserId|TriggeredByUserId|ResponsibleUserId|HandedToUserId|LinkedUserId|PhlebotomistId|Created_By|Updated_By|GivenBy)$"

LOOKUP_TABLES = ["SampleCollectionStatus", "Reportentrystatus", "PaymentMethodMaster", "ApprovalModule", "QcEquipmentType"]

# ══ Parts D, E, F: Pharmacy, Accounts, Inventory ══════════════════════════════════════════════════
PARTS += [
    ("D", "Pharmacy",
     "Drug masters, pricing, purchasing (indent > purchase order > goods receipt), batch-wise stock with every "
     "movement in a stock ledger, adjustments, physical stock verification, branch transfers, sales and returns, and "
     "the scheduled-drug register."),
    ("E", "Accounts",
     "Double-entry accounting: chart of accounts, vouchers and the general ledger that LAB, OPD, membership, B2B and "
     "pharmacy transactions post into; petty cash; employee expense claims; and quotations / invoices raised to "
     "clients."),
    ("F", "Inventory (Lab Stores)",
     "Item master for reagents and consumables used by the laboratory, their stores and suppliers. Consumption against "
     "these items is posted by the LAB bill of materials (module C9)."),
]

MODULES += [
    dict(code="D1", part="D", name="Drug & Item Masters",
         intro="The medicine / item master and its classifications: generic, manufacturer, category tree, dosage form, "
               "unit of measure, drug schedule (H, H1, X, NDPS ...), HSN code with GST history, branch-level rack and "
               "reorder settings, and the reasons used on returns and adjustments.",
         tables=["PhItem", "PhItemBranch", "PhGeneric", "PhManufacturer", "PhCategory", "PhDosageForm", "PhUom",
                 "PhDrugSchedule", "PhHsn", "PhHsnRateHistory", "PhReason"]),
    dict(code="D2", part="D", name="Pricing, Customers & Document Numbering",
         intro="How the selling price is worked out (price rules by patient type, discount schemes), credit customers, "
               "and the document number series (sale, GRN, PO, return ...) per branch.",
         tables=["PhPriceRule", "PhDiscountScheme", "PhCustomer", "PhNumberSeries", "PhNumberCounter"]),
    dict(code="D3", part="D", name="Suppliers & Purchasing",
         intro="Suppliers with drug licence and credit terms; purchase indent > purchase order > goods receipt (GRN) "
               "creating batches; purchase returns; and supplier payments allocated to GRNs. Posted GRNs and returns "
               "post to accounts.",
         tables=["PhSupplier", "PhPurchaseIndent", "PhPurchaseIndentDtl", "PhPurchaseOrder", "PhPurchaseOrderDtl",
                 "PhGrn", "PhGrnDtl", "PhPurchaseReturn", "PhPurchaseReturnDtl", "PhSupplierPayment",
                 "PhSupplierPaymentAlloc"]),
    dict(code="D4", part="D", name="Batches, Stock & Stock Control",
         intro="Stock is held per branch and batch (PhStock); every receipt, sale, return, transfer and adjustment "
               "writes a PhStockLedger row. Batch corrections, stock adjustments / write-offs and physical stock "
               "counts go through approval; transfers move stock between branches.",
         tables=["PhBatch", "PhStock", "PhStockLedger", "PhBatchCorrection", "PhAdjustment", "PhAdjustmentDtl",
                 "PhStockCount", "PhStockCountDtl", "PhTransfer", "PhTransferDtl"]),
    dict(code="D5", part="D", name="Sales, Returns & Schedule Register",
         intro="Pharmacy sales to patients or walk-in customers (billed through PaymentHeader with ModuleCode = 'PHR'), "
               "sale returns with refund, and the register of scheduled drugs dispensed (H1, X, NDPS).",
         tables=["PhSale", "PhSaleDtl", "PhSaleReturn", "PhSaleReturnDtl", "PhScheduleRegister"]),
    dict(code="E1", part="E", name="Chart of Accounts & Accounting Settings",
         intro="Ledger groups and ledgers with opening balances, which ledger each payment mode posts to per branch, "
               "accounting rules (approvals, back-dating, financial year start) and the period lock per branch.",
         tables=["Acc_LedgerGroup", "Acc_LedgerMaster", "Acc_PaymentModeLedger", "Acc_Settings", "Acc_BranchLock"]),
    dict(code="E2", part="E", name="Vouchers & General Ledger",
         intro="Every accounting entry is an Acc_LedgerTransaction (voucher number per type, branch and year) with "
               "debit / credit lines. Business transactions (lab bills, receipts, refunds, discounts, B2B settlement, "
               "wallet, membership, cash closing, pharmacy) post automatically, identified by ReferenceType / "
               "ReferenceId; manual vouchers are entered as Acc_Voucher and post on approval.",
         tables=["Acc_VoucherType", "Acc_VoucherSequence", "Acc_LedgerTransaction", "Acc_LedgerTransactionDetail",
                 "Acc_Voucher", "Acc_VoucherLine", "Acc_Attachment"]),
    dict(code="E3", part="E", name="Petty Cash & Petty Expenses",
         intro="Petty-cash counters with a custodian and float, float issues / replenishments / returns, day closing "
               "of the counter, and petty expense vouchers by expense head and payee, with approval.",
         tables=["Acc_PettyCashCounter", "Acc_PettyCashFloat", "Acc_PettyCashClosing", "Acc_ExpenseHead", "Acc_Payee",
                 "Acc_PettyExpense", "Acc_PettyExpenseLine"]),
    dict(code="E4", part="E", name="Employee Expense Claims",
         intro="Employees claim travel and other expenses with receipts; the claim is approved and then reimbursed / "
               "settled.",
         tables=["ExpenseCategoryMaster", "ExpenseRequest", "ExpenseRequestLine", "ExpenseRequestLineAttachment",
                 "ExpenseRequestApprovalHistory"]),
    dict(code="E5", part="E", name="Client Quotations & Invoices",
         intro="Quotations and GST invoices raised to client parties (subscription / service plans), payments received "
               "against invoices, signatories, and the payment modes and bank accounts printed on them.",
         tables=["PartyMaster", "PricingModelMaster", "Quotation", "QuotationLine", "QuotationSignatories", "Invoice",
                 "InvoiceLine", "InvoiceSignatories", "InvoicePayment", "InvoicePaymentLine", "PaymentMode", "BankMaster"]),
    dict(code="F1", part="F", name="Inventory Items, Stores & Suppliers",
         intro="Reagents and consumables (lot / expiry tracking, purchase and consumption units, stock levels, average "
               "cost), the stores they are kept in (main / bench) and approved suppliers.",
         tables=["InvItem", "InvItemCategory", "InvUnit", "InvStore", "InvSupplier"]),
]

TABLE_DESC.update({
    "PhItem": "Pharmacy item (medicine / consumable): generic, manufacturer, category, dosage form, strength, pack, drug schedule, HSN, purchase / sale units and conversion, flags (cold chain, high alert, LASA, returnable, prescription required) and stock levels.",
    "PhItemBranch": "Branch-level settings of an item: rack, reorder level, min / max quantity, stocked or not.",
    "PhGeneric": "Generic (salt) names with therapeutic class.",
    "PhManufacturer": "Drug manufacturers / marketers.",
    "PhCategory": "Item category tree (ParentCategoryId).",
    "PhDosageForm": "Dosage forms (tablet, syrup, injection ...).",
    "PhUom": "Units of measure for purchase and sale (strip, bottle, tablet ...).",
    "PhDrugSchedule": "Drug schedules and their rules: prescription required, register required, narcotic, label warning.",
    "PhHsn": "HSN codes with current GST and cess rate.",
    "PhHsnRateHistory": "History of GST / cess rate changes of an HSN code.",
    "PhReason": "Reasons for adjustments, cancellations, purchase / sale / IPD returns.",
    "PhPriceRule": "Selling price rule by patient type and category: price basis (MRP / MRP less %) and priority.",
    "PhDiscountScheme": "Discount schemes by category or customer type with minimum bill and validity.",
    "PhCustomer": "Registered pharmacy customers (credit customers, institutions) with credit limit, scheme and ledger.",
    "PhNumberSeries": "Document number series per branch and document type (prefix, padding, yearly reset).",
    "PhNumberCounter": "Last number used of a series per financial year.",
    "PhSupplier": "Pharmacy suppliers: GSTIN, PAN, drug licence and validity, credit days, bank details and ledger.",
    "PhPurchaseIndent": "Purchase indent (request to buy) raised by a branch, with approval.",
    "PhPurchaseIndentDtl": "Items and quantities requested in an indent, with stock at the time.",
    "PhPurchaseOrder": "Purchase order to a supplier (from an indent or direct), with approval and e-mail.",
    "PhPurchaseOrderDtl": "Items of a purchase order: quantity, free quantity, rate, discount, GST and quantity received.",
    "PhGrn": "Goods receipt note against a supplier invoice / PO: amounts, GST, due date; posting creates batches and stock.",
    "PhGrnDtl": "Items received: batch, expiry, MRP, quantity, free quantity, rate, GST and landed cost.",
    "PhPurchaseReturn": "Return of stock to a supplier with reason and GST.",
    "PhPurchaseReturnDtl": "Batches and quantities returned to the supplier.",
    "PhSupplierPayment": "Payment made to a supplier.",
    "PhSupplierPaymentAlloc": "How a supplier payment is allocated against GRNs (bills).",
    "PhBatch": "Batches of an item: batch number, manufacturing / expiry date, MRP, purchase rate, landed cost, GST, supplier; can be blocked.",
    "PhStock": "Quantity on hand per branch and batch.",
    "PhStockLedger": "Every stock movement per branch and batch: document type / number, quantity in / out, balance after and unit cost.",
    "PhBatchCorrection": "Correction of a batch's number, expiry or MRP, with approval.",
    "PhAdjustment": "Stock adjustment / write-off (expiry, damage) document with disposal details, witnesses and approval.",
    "PhAdjustmentDtl": "Batches and quantity changes of an adjustment.",
    "PhStockCount": "Physical stock verification: frozen time, scope, approval and the adjustment it produced.",
    "PhStockCountDtl": "System vs counted quantity per batch.",
    "PhTransfer": "Stock transfer request / dispatch / receipt between branches.",
    "PhTransferDtl": "Items requested, batches dispatched and quantities received in a transfer.",
    "PhSale": "Pharmacy sale bill to a patient or walk-in customer: prescriber, prescription, price type, discount, GST, paid, returned and balance.",
    "PhSaleDtl": "Items sold: batch, quantity, MRP, price, discount, GST, cost and quantity returned.",
    "PhSaleReturn": "Return against a sale with refund mode and amount.",
    "PhSaleReturnDtl": "Sale lines returned.",
    "PhScheduleRegister": "Register of scheduled drugs dispensed (patient, prescriber, prescription, quantity) as required by law.",
    "Acc_LedgerGroup": "Ledger groups (chart of accounts tree): Asset, Liability, Income, Expense.",
    "Acc_LedgerMaster": "Ledgers (accounts) with group, type (cash, bank, party, tax ...) and opening balance.",
    "Acc_PaymentModeLedger": "The ledger each payment method posts to, per branch.",
    "Acc_Settings": "Accounting rules per company: petty-cash approval limits, voucher approval, back-dating, financial year start, GST input credit.",
    "Acc_BranchLock": "Books of a branch locked up to a date (no postings before it).",
    "Acc_VoucherType": "Voucher types (Sales, Receipt, Payment, Journal, Contra, Petty Cash, Purchase, Credit / Debit Note, Opening Balance).",
    "Acc_VoucherSequence": "Running voucher number per company, branch, voucher type and financial year.",
    "Acc_LedgerTransaction": "An accounting entry (voucher): type, number, date, source (ReferenceType / ReferenceId), amount, narration, status and reversal.",
    "Acc_LedgerTransactionDetail": "Debit / credit lines of an accounting entry by ledger.",
    "Acc_Voucher": "A manually entered voucher with approval; posts an Acc_LedgerTransaction when approved.",
    "Acc_VoucherLine": "Debit / credit lines of a manual voucher.",
    "Acc_Attachment": "Files attached to a voucher or petty expense.",
    "Acc_PettyCashCounter": "Petty-cash counter of a branch: custodian, float amount, its ledger and funding ledger.",
    "Acc_PettyCashFloat": "Money issued to, replenished to or returned from a petty-cash counter.",
    "Acc_PettyCashClosing": "Day closing of a petty-cash counter: book vs counted cash and denominations.",
    "Acc_ExpenseHead": "Expense heads for petty expenses, mapped to a ledger, with limits.",
    "Acc_Payee": "Regular payees of petty expenses.",
    "Acc_PettyExpense": "Petty expense voucher: payee, bill, amount, approval and posting.",
    "Acc_PettyExpenseLine": "Expense heads and amounts (with GST) of a petty expense.",
    "ExpenseCategoryMaster": "Categories of employee expense claims.",
    "ExpenseRequest": "An employee's expense claim: approver, status, totals, approval and reimbursement / settlement.",
    "ExpenseRequestLine": "Expense items of a claim (travel, accommodation ...) with amount and receipt.",
    "ExpenseRequestLineAttachment": "Receipts attached to a claim line.",
    "ExpenseRequestApprovalHistory": "Actions taken on a claim (submit, approve, reject, settle).",
    "PartyMaster": "Client parties quoted / invoiced (name, contact, GSTIN, PAN).",
    "PricingModelMaster": "Pricing models offered (e.g. subscription, per transaction).",
    "Quotation": "Quotation to a party with GST totals and validity.",
    "QuotationLine": "Lines of a quotation (plan / item, quantity, rate, discount, GST).",
    "QuotationSignatories": "Users who sign a quotation.",
    "Invoice": "GST invoice to a party (optionally from a quotation) with totals, received amount and status.",
    "InvoiceLine": "Lines of an invoice.",
    "InvoiceSignatories": "Users who sign an invoice.",
    "InvoicePayment": "Payment received against an invoice (receipt).",
    "InvoicePaymentLine": "Payment modes of an invoice payment (card, bank, reference).",
    "PaymentMode": "Payment modes used on client invoices.",
    "BankMaster": "Company bank accounts / UPI printed on invoices.",
    "InvItem": "Inventory item (reagent / consumable): category, purchase and consumption units, pack size, rate, GST, HSN, storage, stability, stock levels, lot / expiry tracking and average cost.",
    "InvItemCategory": "Item categories and whether lots / expiry are tracked or the item is a QC material.",
    "InvUnit": "Units for inventory items.",
    "InvStore": "Stores per branch (main store or department bench store).",
    "InvSupplier": "Approved suppliers of inventory items.",
})

COL_DESC.update({
    ("PhItem", "ScheduleCode"): "Drug schedule (PhDrugSchedule): G, H, H1, X, NDPS, OTC.",
    ("PhItem", "ConversionQty"): "Sale units in one purchase unit (e.g. 10 tablets per strip).",
    ("PhItem", "IsLasa"): "1 = look-alike / sound-alike drug.",
    ("PhPriceRule", "PriceBasis"): "MRP or MRP_LESS (MRP less RatePercent).",
    ("PhPriceRule", "PatientType"): "WALKIN, STAFF, IPD_CASH, IPD_CORPORATE, IPD_INSURANCE.",
    ("PhNumberSeries", "DocType"): "Document: SALE, SRET, GRN, PO, PIND, PRET, SPAY, ADJ, BCOR, PCNT, TRF, INDT, IPDI, IPDR, BIND.",
    ("PhReason", "ReasonType"): "ADJUSTMENT, CANCEL, PURCHASE_RETURN, SALE_RETURN, IPD_RETURN.",
    ("PhStockLedger", "DocType"): "Movement source: GRN, SALE, SRET, PRET, ADJ, TRF ...",
    ("PhStockLedger", "DocId"): "ID of the source document (by DocType).",
    ("PhSale", "CustomerKind"): "PATIENT (registered patient) or WALKIN.",
    ("PhSale", "Status"): "POSTED or CANCELLED (a held bill carries HoldLabel).",
    ("PhGrn", "Status"): "DRAFT or POSTED.",
    ("PhPurchaseOrder", "Status"): "DRAFT, APPROVED, PARTIAL, CLOSED, CANCELLED.",
    ("PhSaleReturn", "RefundMode"): "CASH, CARD, UPI, NEFT or ADJUST (set off against the bill).",
    ("PhSaleReturn", "RefundId"): "The refund (BillRefund.RefundId).",
    ("Acc_LedgerGroup", "GroupType"): "Asset, Liability, Income or Expense.",
    ("Acc_LedgerMaster", "LedgerType"): "CASH, BANK, PARTY, TAX, PETTY, INCOME, EXPENSE, GENERAL ...",
    ("Acc_LedgerMaster", "OpeningBalanceType"): "Dr or Cr.",
    ("Acc_LedgerTransaction", "ReferenceType"): "What posted it: LAB_BILL, LAB_RECEIPT, LAB_REFUND, LAB_CANCEL, LAB_DISCOUNT, LAB_MEMDISC, LAB_ROUNDOFF, B2B_LAB_BILL, B2B_SETTLEMENT, B2B_WALLET_TOPUP, B2B_WALLET_PAY, MEM_CARD, CASH_CLOSE, pharmacy documents, MANUAL_VCH ...",
    ("Acc_LedgerTransaction", "ReferenceId"): "ID of the source record of that ReferenceType.",
    ("Acc_LedgerTransaction", "Status"): "P = posted, C = cancelled (a reversal entry is posted; both stay in the books).",
    ("Acc_LedgerTransaction", "IsManual"): "1 = entered as a manual voucher.",
    ("Acc_PettyCashFloat", "Kind"): "ISSUE, REPLENISH or RETURN.",
    ("Acc_PettyExpense", "Status"): "S = submitted, A = approved (posted), R = rejected, C = cancelled.",
    ("Acc_Voucher", "Status"): "S = submitted, A = approved (posted), R = rejected, C = cancelled.",
    ("Acc_Attachment", "RefType"): "VOUCHER or PETTY_EXP.",
    ("Acc_Attachment", "RefId"): "Acc_Voucher.VoucherId or Acc_PettyExpense.ExpenseId (by RefType).",
    ("Acc_PaymentModeLedger", "MethodCode"): "Payment method (PaymentMethodMaster.MethodCode).",
    ("InvStore", "StoreType"): "Main or Bench.",
})

CONDITIONAL.update({
    ("PaymentHeader", "ModuleRefId"): ["LabOrder", "PatientOPDService", "MembershipCard", "PhSale"],
    ("PhStockLedger", "DocId"): ["PhGrn", "PhSale", "PhSaleReturn", "PhPurchaseReturn", "PhAdjustment", "PhTransfer"],
    ("Acc_Attachment", "RefId"): ["Acc_Voucher", "Acc_PettyExpense"],
})
CONDITION_TEXT.update({("PhStockLedger", "DocId"): "by DocType", ("Acc_Attachment", "RefId"): "by RefType"})

# alias by module (table name pattern) - checked before ALIAS
CONTEXT_ALIAS = [
    (r"^Ph", {"itemid": "PhItem", "supplierid": "PhSupplier", "categoryid": "PhCategory", "batchid": "PhBatch",
              "grnid": "PhGrn", "saleid": "PhSale", "saledtlid": "PhSaleDtl", "poid": "PhPurchaseOrder",
              "podtlid": "PhPurchaseOrderDtl", "indentid": "PhPurchaseIndent", "adjustmentid": "PhAdjustment",
              "stockcountid": "PhStockCount", "transferid": "PhTransfer", "reasonid": "PhReason",
              "schemeid": "PhDiscountScheme", "customerid": "PhCustomer", "seriesid": "PhNumberSeries",
              "uomid": "PhUom", "purchaseuomid": "PhUom", "saleuomid": "PhUom", "hsnid": "PhHsn",
              "genericid": "PhGeneric", "manufacturerid": "PhManufacturer", "dosageformid": "PhDosageForm",
              "frombranchid": "Branchmaster", "tobranchid": "Branchmaster", "ledgerid": "Acc_LedgerMaster",
              "refundid": "BillRefund"}),
    (r"^(Invoice|Quotation)", {"invoiceid": "Invoice", "quotationid": "Quotation", "partyid": "PartyMaster",
                               "paymentid": "InvoicePayment", "paymentmodeid": "PaymentMode", "bankid": "BankMaster"}),
    (r"^(Acc_|CashClosing)", {"transactionid": "Acc_LedgerTransaction", "reversaloftransactionid": "Acc_LedgerTransaction",
                              "ledgerid": "Acc_LedgerMaster", "fundingledgerid": "Acc_LedgerMaster",
                              "sourceledgerid": "Acc_LedgerMaster", "parentgroupid": "Acc_LedgerGroup",
                              "counterid": "Acc_PettyCashCounter", "expenseheadid": "Acc_ExpenseHead",
                              "defaultexpenseheadid": "Acc_ExpenseHead", "vouchertypeid": "Acc_VoucherType",
                              "voucherid": "Acc_Voucher", "expenseid": "Acc_PettyExpense", "floatid": "Acc_PettyCashFloat"}),
    (r"^Expense", {"requestid": "ExpenseRequest", "requestlineid": "ExpenseRequestLine",
                   "expensecategoryid": "ExpenseCategoryMaster"}),
    (r"^Inv(Item|Store|Supplier)$", {"categoryid": "InvItemCategory", "departmentid": "DepartmentMaster"}),
]

OVERRIDE.update({
    ("Acc_LedgerTransaction", "ReferenceId"): None,
    ("PhStockCount", "Scope"): None,
})

# references to a non-key column
EXTRA_REF = {("Acc_PaymentModeLedger", "MethodCode"): ("PaymentMethodMaster", "MethodCode")}

LOOKUP_TABLES += ["Acc_VoucherType", "Acc_LedgerGroup", "PhDrugSchedule"]
COL_DESC.update({
    ("Acc_LedgerTransaction", "ReversalOfTransactionId"): "For a reversal entry: the entry it reverses.",
    ("PhCategory", "ParentCategoryId"): "Parent category (category tree).",
    ("Acc_LedgerGroup", "ParentGroupId"): "Parent group (chart of accounts tree).",
})


# Tables a part picks up automatically when they are not in any module yet (name patterns).
PART_RULES = {
    "A": [r"^(Payment|Bill(Cancellation|Refund|ingSubmission)|Cancellation|CashClosing|Membership|Receipt|Approval)",
          r"^Patient(Master|CodeCounter)$"],
    "B": [r"^(OPD|Doctor(?!_IP|Ip)|Emr|PatientOPD|PatientVitals|PatientVaccination|PatientCertificate|Certificate|Vaccine|tbl_Video)"],
    "C": [r"^(Lab|lab|Sample|B2B|Bom|Iqc|Qc|InvestigationLoinc|Loinc|StageLoinc|Reportentry|Corporate|Doctor_IP|DoctorIp|tbl_mst_analyzer)"],
    "D": [r"^Ph[A-Z]"],
    "E": [r"^(Acc_|Expense|Invoice|Quotation)"],
    "F": [r"^Inv(?!oice|estigation)"],
}
# never picked up automatically
EXCLUDE = [r"^__", r"^tmp", r"(?i)backup|_bak$|_old$"]
