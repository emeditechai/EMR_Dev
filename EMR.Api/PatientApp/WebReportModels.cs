// Copies of EMR.Web's data types for the patient app's report and bill PDFs (EMR.Web.Models.DTOs / ViewModels): the
// shapes EMR.Web reads from this API, so the copied report builder (LabReportPrintBuilder) prints exactly as EMR.Web does.
// EMR.Web's own report printing is left as it is; change both when the report changes.
#nullable disable warnings
using System.Text.Json.Serialization;

namespace EMR.Api.PatientApp;

// from EMR.Web/Models/DTOs/LabReportingDtos.cs
public class LabReportingOrderDetailDto
{
    public int LabOrderId { get; set; }
    public int BranchId { get; set; }
    public string? BranchName { get; set; }
    public int PatientId { get; set; }
    public string PatientCode { get; set; } = string.Empty;
    public string PatientName { get; set; } = string.Empty;
    public int? Age { get; set; }
    public string? Gender { get; set; }
    public System.DateTime? LmpDate { get; set; }   // 2453: last menstrual period (female patients)
    public string? PhoneNumber { get; set; }
    public string? EmailId { get; set; }
    public string? Address { get; set; }
    public DateTime OrderDate { get; set; }
    public DateTime? BookingDateTime { get; set; }
    public string? BillNo { get; set; }
    public string? TokenNo { get; set; }
    public bool IsUrgent { get; set; }
    public string CollectionType { get; set; } = "Lab";
    public int? PhlebotomistId { get; set; }
    public string? PhlebotomistName { get; set; }
    public int? ReferralDoctorId { get; set; }
    public string? ReferralDoctorName { get; set; }
    public string PaymentStatus { get; set; } = "U";
    public decimal TotalPaid { get; set; }
    public decimal BalanceDue { get; set; }
    public decimal TotalAmount { get; set; }
    public bool IsB2B { get; set; }
    public bool IsTransferred { get; set; }
    public int? SourceBranchId { get; set; }
    public string? SourceBranchName { get; set; }
    public DateTime? TransferredDate { get; set; }
    public string? TransferRemarks { get; set; }
    public int ReportStatusId { get; set; }
    public string? StatusCode { get; set; }
    public string ReportStatusName { get; set; } = "Pending Entry";
    public string ReportBadgeClass { get; set; } = "bg-secondary-subtle text-secondary border border-secondary-subtle";
    public DateTime? DraftedDate { get; set; }
    public DateTime? SubmittedDate { get; set; }
    public DateTime? ValidatedDate { get; set; }
    public DateTime? ApprovedDate { get; set; }
    public List<LabReportingItemDto> Items { get; set; } = new();
    public List<LabReportGroupRemarkDto> GroupRemarks { get; set; } = new();

    public LabReportingHierarchyDto GetHierarchy()
    {
        var hierarchy = new LabReportingHierarchyDto();
        if (Items == null || Items.Count == 0) return hierarchy;

        var pkgMap = new Dictionary<string, LabReportingPackageGroupDto>();
        var profMap = new Dictionary<string, LabReportingProfileGroupDto>();
        var testMap = new Dictionary<string, LabReportingStandaloneTestGroupDto>();

        var remarksMap = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        if (GroupRemarks != null)
        {
            foreach (var r in GroupRemarks)
            {
                if (!string.IsNullOrEmpty(r.GroupKey))
                {
                    remarksMap[r.GroupKey] = r.LabRemarks ?? "";
                }
            }
        }

        int groupIndex = 0;
        foreach (var item in Items)
        {
            bool hasProfile = !string.IsNullOrWhiteSpace(item.ProfileName) && item.ProfileName != "—";
            bool hasPackage = !string.IsNullOrWhiteSpace(item.PackageName) && item.PackageName != "—";

            if (hasPackage)
            {
                string pkgKey = $"PKG_{item.PackageId?.ToString() ?? item.PackageName}";
                if (!pkgMap.TryGetValue(pkgKey, out var pkgGrp))
                {
                    groupIndex++;
                    pkgGrp = new LabReportingPackageGroupDto
                    {
                        GroupId = $"grp_{groupIndex}",
                        PackageId = item.PackageId,
                        PackageName = item.PackageName!
                    };
                    if (remarksMap.TryGetValue(pkgKey, out var pkgRem))
                    {
                        pkgGrp.LabRemarks = pkgRem;
                    }
                    pkgMap[pkgKey] = pkgGrp;
                    hierarchy.Packages.Add(pkgGrp);
                }

                if (hasProfile)
                {
                    string profKey = $"PRF_{item.ProfileId?.ToString() ?? item.ProfileName}";
                    var profGrp = pkgGrp.Profiles.Find(p => p.ProfileName == item.ProfileName);
                    if (profGrp == null)
                    {
                        groupIndex++;
                        profGrp = new LabReportingProfileGroupDto
                        {
                            GroupId = $"grp_{groupIndex}",
                            ProfileId = item.ProfileId,
                            ProfileName = item.ProfileName!,
                            SharedBarcode = item.BarcodeNo,
                            CollectionstatusID = item.CollectionstatusID,
                            SampleCollectionStatus = item.SampleCollectionStatus,
                            SampleCollectionStatusCode = item.SampleCollectionStatusCode,
                            RejectionReasonId = item.RejectionReasonId,
                            RejectionReason = item.RejectionReason
                        };
                        if (remarksMap.TryGetValue(profKey, out var pRem))
                        {
                            profGrp.LabRemarks = pRem;
                        }
                        else if (!string.IsNullOrEmpty(item.GroupLabRemarks))
                        {
                            profGrp.LabRemarks = item.GroupLabRemarks;
                        }
                        pkgGrp.Profiles.Add(profGrp);
                    }
                    if (string.IsNullOrEmpty(profGrp.SharedBarcode) && !string.IsNullOrEmpty(item.BarcodeNo))
                    {
                        profGrp.SharedBarcode = item.BarcodeNo;
                    }
                    profGrp.Items.Add(item);
                }
                else
                {
                    pkgGrp.StandaloneItems.Add(item);
                }
            }
            else if (hasProfile)
            {
                string profKey = $"PRF_{item.ProfileId?.ToString() ?? item.ProfileName}";
                if (!profMap.TryGetValue(profKey, out var profGrp))
                {
                    groupIndex++;
                    profGrp = new LabReportingProfileGroupDto
                    {
                        GroupId = $"grp_{groupIndex}",
                        ProfileId = item.ProfileId,
                        ProfileName = item.ProfileName!,
                        SharedBarcode = item.BarcodeNo,
                        CollectionstatusID = item.CollectionstatusID,
                        SampleCollectionStatus = item.SampleCollectionStatus,
                        SampleCollectionStatusCode = item.SampleCollectionStatusCode,
                        RejectionReasonId = item.RejectionReasonId,
                        RejectionReason = item.RejectionReason
                    };
                    if (remarksMap.TryGetValue(profKey, out var pRem))
                    {
                        profGrp.LabRemarks = pRem;
                    }
                    else if (!string.IsNullOrEmpty(item.GroupLabRemarks))
                    {
                        profGrp.LabRemarks = item.GroupLabRemarks;
                    }
                    profMap[profKey] = profGrp;
                    hierarchy.StandaloneProfiles.Add(profGrp);
                }
                if (string.IsNullOrEmpty(profGrp.SharedBarcode) && !string.IsNullOrEmpty(item.BarcodeNo))
                {
                    profGrp.SharedBarcode = item.BarcodeNo;
                }
                profGrp.Items.Add(item);
            }
            else
            {
                hierarchy.StandaloneItems.Add(item);

                // Group standalone test by InvestigationID as individual test header
                string testKey = $"INV_{item.InvestigationID}";
                if (!testMap.TryGetValue(testKey, out var testGrp))
                {
                    groupIndex++;
                    testGrp = new LabReportingStandaloneTestGroupDto
                    {
                        GroupId = $"grp_tst_{groupIndex}",
                        SamplecollectionID = item.SamplecollectionID,
                        InvestigationId = item.InvestigationID,
                        TestCode = item.TestCode,
                        TestName = item.TestName,
                        SharedBarcode = item.BarcodeNo,
                        CollectionstatusID = item.CollectionstatusID,
                        SampleCollectionStatus = item.SampleCollectionStatus,
                        SampleCollectionStatusCode = item.SampleCollectionStatusCode,
                        RejectionReasonId = item.RejectionReasonId,
                        RejectionReason = item.RejectionReason
                    };
                    if (remarksMap.TryGetValue(testKey, out var tRem))
                    {
                        testGrp.LabRemarks = tRem;
                    }
                    else if (!string.IsNullOrEmpty(item.GroupLabRemarks))
                    {
                        testGrp.LabRemarks = item.GroupLabRemarks;
                    }
                    testMap[testKey] = testGrp;
                    hierarchy.StandaloneTestGroups.Add(testGrp);
                }
                if (string.IsNullOrEmpty(testGrp.SharedBarcode) && !string.IsNullOrEmpty(item.BarcodeNo))
                {
                    testGrp.SharedBarcode = item.BarcodeNo;
                }
                testGrp.Items.Add(item);
            }
        }

        return hierarchy;
    }
}

// from EMR.Web/Models/DTOs/LabReportingDtos.cs
public class LabReportingItemDto
{
    public long SamplecollectionID { get; set; }
    public int Laborderid { get; set; }
    public int InvestigationID { get; set; }
    public string TestCode { get; set; } = string.Empty;
    public string TestName { get; set; } = string.Empty;
    public int? DepartmentID { get; set; }
    public string? DepartmentName { get; set; }
    public string? MethodName { get; set; }
    public int? SampleTypeId { get; set; }
    public string? SampleTypeName { get; set; }
    public string? ContainerType { get; set; }
    public string? UnitName { get; set; }
    public string? ReportingType { get; set; }
    public string? BarcodeNo { get; set; }
    public DateTime? Samplecollectiondate { get; set; }
    public TimeSpan? Samplecollectiontime { get; set; }
    public int? ProfileId { get; set; }
    public string? ProfileName { get; set; }
    public int? PackageId { get; set; }
    public string? PackageName { get; set; }
    public string? ProfilePackageName { get; set; }
    public long? LabEntryDetailId { get; set; }
    public string? TestValue { get; set; }
    public string? TemplateHtml { get; set; }
    public string? Remarks { get; set; }
    public string? SpecialRemarks { get; set; }
    public int? RefRangeId { get; set; }
    public decimal? LowValue { get; set; }
    public decimal? HighValue { get; set; }
    /// <summary>'Critical Value' / 'Panic Value' when the matched reference range has that tier, else null.</summary>
    public string? RangeTier { get; set; }
    /// <summary>Critical / Panic limits: a result beyond them is flagged 'Critical' / 'Panic' (before L / H).</summary>
    public decimal? LowThreshold { get; set; }
    public decimal? HighThreshold { get; set; }
    public string? ReferenceRange { get; set; }
    public string? AbnormalFlag { get; set; }
    public int TATHours { get; set; } = 24;
    public string? PreviousTestValue { get; set; }
    public DateTime? PreviousOrderDate { get; set; }
    public string? PreviousUnitSymbol { get; set; }
    public int ReportStatusId { get; set; }
    public string ReportStatusName { get; set; } = "Pending Entry";
    public string ReportBadgeClass { get; set; } = "bg-secondary-subtle text-secondary border border-secondary-subtle";
    public DateTime? DraftedDate { get; set; }
    public DateTime? SubmittedDate { get; set; }
    public DateTime? ValidatedDate { get; set; }
    public DateTime? ApprovedDate { get; set; }
    public DateTime? LastSavedDate { get; set; }
    public bool IsTransferred { get; set; }
    public int? SourceBranchId { get; set; }
    public string? SourceBranchName { get; set; }
    public int? TargetBranchId { get; set; }
    public string? TargetBranchName { get; set; }
    /// <summary>
    /// The sample was transferred out of the branch currently viewing: the result was produced and approved at
    /// the target branch, so it is shown here (to be seen and printed) but nothing on it may be changed.
    /// </summary>
    public bool IsReadOnlyForBranch { get; set; }
    public DateTime? TransferredDate { get; set; }
    public string? TransferRemarks { get; set; }
    public int CollectionstatusID { get; set; } = 2;
    public string SampleCollectionStatus { get; set; } = "Collected";
    public string SampleCollectionStatusCode { get; set; } = "COLLECTED";
    public int? RejectionReasonId { get; set; }
    public string? RejectionReason { get; set; }
    public string? GroupLabRemarks { get; set; }
}

// from EMR.Web/Models/DTOs/LabReportingDtos.cs
public class LabReportGroupRemarkDto
{
    public string GroupKey { get; set; } = string.Empty;
    public string HeaderName { get; set; } = string.Empty;
    public int? ProfileId { get; set; }
    public int? InvestigationId { get; set; }
    public string? LabRemarks { get; set; }
}

// from EMR.Web/Models/DTOs/LabReportingDtos.cs
public class LabReportSampleMetaDto
{
    public long SamplecollectionID { get; set; }
    public int? DepartmentId { get; set; }
    public string? DepartmentName { get; set; }
    public int? CategoryId { get; set; }
    public string? CategoryName { get; set; }
    public int CategoryOrder { get; set; } = 9999;
    public string? SubCategoryName { get; set; }
    public DateTime? ReceivedDate { get; set; }
}

// from EMR.Web/Models/DTOs/LabReportingDtos.cs
public class LabReportPrintMetaDto
{
    public List<LabReportSampleMetaDto> Samples { get; set; } = new();
    public List<LabReportSignatoryDto> Signatories { get; set; } = new();
    public LabReportProcessingLabDto? ProcessingLab { get; set; }
    /// <summary>Null for B2C orders.</summary>
    public LabReportClientDto? Client { get; set; }
}

// from EMR.Web/Models/DTOs/LabReportSignoffDtos.cs
/// <summary>One approval level already signed for a bill - printed as a signature block on the report.</summary>
public class LabReportSignoffLevelDto
{
    public int LevelNo { get; set; }
    public int TotalLevels { get; set; }
    public string? LevelTitle { get; set; }
    public bool IsFinalLevel { get; set; }
    public int UserId { get; set; }
    public string? FullName { get; set; }
    public string? RegistrationNo { get; set; }
    public string? SignaturePath { get; set; }
    public bool IsPathologist { get; set; }
    /// <summary>Null for a signatory configured in Hospital Settings (nothing was signed).</summary>
    public DateTime? SignedOn { get; set; }
    public int TestsSigned { get; set; }
    /// <summary>FLOW (Pathologist Dashboard), ENTRY (Report Entry screen) or CONFIG (Hospital Settings signatories).</summary>
    public string? Source { get; set; }
}

// from EMR.Web/Models/DTOs/LabOrderDtos.cs
public class LabOrderDetailDto
{
    public int LabOrderId { get; set; }
    public int PatientId { get; set; }
    public int BranchId { get; set; }
    public string? BranchName { get; set; }
    public System.DateTime OrderDate { get; set; }
    public string? BillNo { get; set; }
    public string? TokenNo { get; set; }
    public string? BookingNo { get; set; }          // 2384
    public bool IsBookingRequired { get; set; }
    public bool IsUrgent { get; set; }
    public decimal TotalAmount { get; set; }
    public bool IsB2B { get; set; }
    public int? B2BAgentId { get; set; }
    public string? AgentType { get; set; }
    public string? AgentName { get; set; }
    public string? AgentCode { get; set; }
    public decimal? B2BTotal { get; set; }
    public int? ReferralDoctorId { get; set; }
    public string CollectionType { get; set; } = "Lab";
    public int? PhlebotomistId { get; set; }
    public string? PhlebotomistName { get; set; }
    public string? ReferralDoctorName { get; set; }
    /// <summary>Marketing executive tagged on the referral doctor (Doctor Master, SQLScripts/2442).</summary>
    public string? MarketingExecutiveName { get; set; }
    public string? MarketingExecutiveType { get; set; }
    public System.DateTime? BookingDate { get; set; }
    public bool IsActive { get; set; }
    public System.DateTime CreatedDate { get; set; }
    public string? CreatedByName { get; set; }
    public string? CreatedByUsername { get; set; }
    public string? PatientCode { get; set; }
    public string? BeneficiaryId { get; set; }   // LAB B2B government scheme order: LabOrder.Beneficiary_ID (SQLScripts/2535)
    public string? GovtSchemeName { get; set; }   // LabOrder.Govt_Scheme_Name (2535); null = not a scheme order
    public string? PatientName { get; set; }
    public string? PhoneNumber { get; set; }
    public string? EmailId { get; set; }
    public string? Gender { get; set; }
    public System.DateTime? LmpDate { get; set; }   // 2453: last menstrual period (female patients)
    public System.DateTime? DateOfBirth { get; set; }
    public int? Age { get; set; }
    public string FormattedAge => EMR.Common.AgeCalculator.FormatAgePattern(DateOfBirth, Age);
    public string? Address { get; set; }
    public int? PaymentHeaderId { get; set; }
    public string PaymentStatus { get; set; } = "U";
    public decimal TotalPaid { get; set; }
    public decimal BalanceDue { get; set; }
    public decimal NetAmount { get; set; }
    public decimal DiscountAmount { get; set; }
    public decimal RoundOffAmount { get; set; }
    /// <summary>Why the discount was given, who approved it and who entered it (null for bills discounted before these were recorded).</summary>
    public string? DiscountReason { get; set; }
    public string? DiscountApprovedByName { get; set; }
    public string? DiscountEnteredByName { get; set; }
    public System.DateTime? DiscountApprovedDate { get; set; }
    public List<LabOrderItemDetailDto> Items { get; set; } = new();
    public List<LabOrderPaymentDetailDto> Payments { get; set; } = new();
}

// from EMR.Web/ApiClients/Models/LabReportingConditionModels.cs
/// <summary>What the Lab Report PDF prints on its Conditions of Reporting page.</summary>
public class LabReportConditionsForReportModel
{
    /// <summary>False when the company has never configured any condition (the report then uses its built-in text).</summary>
    public bool HasConfiguration { get; set; }
    public List<string> Conditions { get; set; } = new();
}

// from EMR.Web/Models/DTOs/LabOrderDtos.cs
public class LabOrderPaymentDetailDto
{
    public int PaymentDetailId { get; set; }
    public string? MethodName { get; set; }
    public string? MethodCode { get; set; }
    public decimal PaidAmount { get; set; }
    public System.DateTime PaymentDate { get; set; }
    public string? ReceiptNo { get; set; }
    public string? TransactionRef { get; set; }
    public string? ChequeNo { get; set; }
    public string? BankName { get; set; }
    public string? UPIRefNo { get; set; }
    public string? CardLast4 { get; set; }
    public string? Notes { get; set; }
    public string? ReceivedByName { get; set; }
    public bool IsDueCollection { get; set; }
}

// from EMR.Web/Models/ViewModels/PrintBillViewModel.cs
public class PrintBillViewModel
{
    /// <summary>"A4" (default, portrait) or "A5L" (A5 landscape) - Hospital Settings > LAB > LAB Bill Print Page Size.</summary>
    public string PageSize { get; set; } = "A4";

    // ── Hospital / Branch Info ────────────────────────────────────────────────
    public string? HospitalName { get; set; }
    public string? HospitalType { get; set; }
    public string? RegistrationNumber { get; set; }
    public string? HospitalAddress { get; set; }
    public string? HospitalPhone { get; set; }
    public string? HospitalEmergencyPhone { get; set; }
    public string? HospitalEmail { get; set; }
    public string? HospitalWebsite { get; set; }
    public string? HospitalGSTIN { get; set; }
    public string? HospitalLogoPath { get; set; }
    public string? BranchName { get; set; }
    public string? NabhStatus { get; set; }
    public string? NabhCertificateNo { get; set; }
    public DateTime? NabhValidFrom { get; set; }
    public DateTime? NabhValidTo { get; set; }

    // ── Patient Info ──────────────────────────────────────────────────────────
    public string? PatientName { get; set; }
    public string? PatientCode { get; set; }
    public string? BeneficiaryId { get; set; }   // LAB B2B government scheme order: LabOrder.Beneficiary_ID (SQLScripts/2535)
    public string? GovtSchemeName { get; set; }   // LabOrder.Govt_Scheme_Name (2535); null = not a scheme order
    public string? PhoneNumber { get; set; }
    public string? EmailId { get; set; }
    public string? Gender { get; set; }
    public DateTime? LmpDate { get; set; }   // 2453: last menstrual period (female patients)
    public int? Age { get; set; }
    public DateTime? DateOfBirth { get; set; }
    public string FormattedAge => EMR.Common.AgeCalculator.FormatAgePattern(DateOfBirth, Age);
    public string? Address { get; set; }

    // ── Order Info ────────────────────────────────────────────────────────────
    public int LabOrderId { get; set; }
    public string? BillNo { get; set; }
    public string? TokenNo { get; set; }
    public string? BookingNo { get; set; }   // 2384: with "Is Booking Req"
    public DateTime OrderDate { get; set; }
    public DateTime CreatedDate { get; set; }
    public DateTime? BookingDate { get; set; }
    public string? CollectionType { get; set; }
    public string? PhlebotomistName { get; set; }
    /// <summary>Referring doctor recorded on this bill; null = self / not referred.</summary>
    public string? ReferralDoctorName { get; set; }
    public string? CreatedByName { get; set; }
    public string? CreatedByUsername { get; set; }
    public string? PrintedByName { get; set; }
    public bool IsB2B { get; set; }
    /// <summary>False = no hospital header / footer: printed from the application on pre-printed letterhead
    /// (B2C bill, Hospital Settings > LAB > Required B2C Bill Print Header, SQLScripts/2206). The bill link sent by
    /// email / WhatsApp (PrintBillAnonymous) always keeps them.</summary>
    public bool ShowHeaderFooter { get; set; } = true;
    public string? PartnerName { get; set; }
    public string? PartnerCode { get; set; }

    // ── Payment Summary ───────────────────────────────────────────────────────
    public decimal GrossAmount { get; set; }
    public decimal DiscountAmount { get; set; }
    public decimal RoundOffAmount { get; set; }
    public decimal GrandTotal { get; set; }
    public decimal ReceivedAmount { get; set; }
    /// <summary>MRP of tests cancelled after billing (shown as "Less: Cancelled tests").</summary>
    public decimal CancelledAmount { get; set; }
    /// <summary>Money refunded on the bill (ReceivedAmount is already net of it).</summary>
    public decimal RefundedAmount { get; set; }
    // membership points (B2C LAB): points used as payment and points earned on this bill
    public string? MembershipCardNo { get; set; }
    public decimal PointsRedeemed { get; set; }
    public decimal PointsRedeemedAmount { get; set; }
    public decimal PointsEarned { get; set; }
    public decimal MembershipDiscountAmount { get; set; }   // plan benefits (SQLScripts/2241), besides the manual Discount
    // GST on misc charges (SQLScripts/2240): added on top of the bill
    public decimal MiscCgstAmount { get; set; }
    public decimal MiscSgstAmount { get; set; }
    public decimal MiscGstAmount => MiscCgstAmount + MiscSgstAmount;
    public decimal Balance { get; set; }
    public string PaymentStatus { get; set; } = "U";
    public bool IsActive { get; set; }

    // ── Line Items ────────────────────────────────────────────────────────────
    public List<PrintBillLineItem> LineItems { get; set; } = new();

    // ── Payment Methods ───────────────────────────────────────────────────────
    public List<PrintBillPaymentRow> Payments { get; set; } = new();

    // ── Computed ──────────────────────────────────────────────────────────────
    public string AmountInWords => ConvertToWords(ReceivedAmount);

    private static string ConvertToWords(decimal amount)
    {
        if (amount == 0) return "Zero";
        var rupees = (long)Math.Floor(amount);
        var paise = (int)Math.Round((amount - rupees) * 100);
        var result = RupeesToWords(rupees);
        if (paise > 0) result += $" and {TwoDigitWords(paise)} Paise";
        return result + " Only";
    }

    private static readonly string[] Ones = { "", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine",
        "Ten", "Eleven", "Twelve", "Thirteen", "Fourteen", "Fifteen", "Sixteen", "Seventeen", "Eighteen", "Nineteen" };
    private static readonly string[] Tens = { "", "", "Twenty", "Thirty", "Forty", "Fifty", "Sixty", "Seventy", "Eighty", "Ninety" };

    private static string TwoDigitWords(int n)
    {
        if (n < 20) return Ones[n];
        return (Tens[n / 10] + (n % 10 > 0 ? " " + Ones[n % 10] : "")).Trim();
    }

    private static string RupeesToWords(long n)
    {
        if (n == 0) return "Zero";
        if (n < 0) return "Minus " + RupeesToWords(-n);
        var result = "";
        if (n >= 10000000) { result += RupeesToWords(n / 10000000) + " Crore "; n %= 10000000; }
        if (n >= 100000)   { result += RupeesToWords(n / 100000)   + " Lakh ";  n %= 100000;   }
        if (n >= 1000)     { result += RupeesToWords(n / 1000)     + " Thousand "; n %= 1000;   }
        if (n >= 100)      { result += Ones[n / 100] + " Hundred "; n %= 100; }
        if (n > 0)         { result += TwoDigitWords((int)n); }
        return result.Trim();
    }
}

// from EMR.Web/Models/ViewModels/PrintBillViewModel.cs
public class PrintBillLineItem
{
    public string? TestCode { get; set; }
    public string? TestName { get; set; }
    public string? SampleType { get; set; }
    public decimal MRP { get; set; }
    public decimal DiscountAmount { get; set; }
    public decimal Total => MRP - DiscountAmount;
    public bool IsActive { get; set; }
}

// from EMR.Web/Models/ViewModels/PrintBillViewModel.cs
public class PrintBillPaymentRow
{
    public string? MethodName { get; set; }
    public decimal PaidAmount { get; set; }
    public string? TransactionRef { get; set; }
    public string? ReceiptNo { get; set; }
    public DateTime? PaymentDate { get; set; }
    public string? ChequeNo { get; set; }
    public string? BankName { get; set; }
    public string? UPIRefNo { get; set; }
    public string? CardLast4 { get; set; }
    public string? ReceivedByName { get; set; }
    public bool IsDueCollection { get; set; }

    /// <summary>Mode details for the receipts table: UPI ref, card, cheque, bank, transaction ref.</summary>
    public string ModeDetails => string.Join(", ", new[]
    {
        string.IsNullOrWhiteSpace(UPIRefNo) ? null : "UPI Ref " + UPIRefNo.Trim(),
        string.IsNullOrWhiteSpace(CardLast4) ? null : "Card xxxx " + CardLast4.Trim(),
        string.IsNullOrWhiteSpace(ChequeNo) ? null : "Cheque No " + ChequeNo.Trim(),
        string.IsNullOrWhiteSpace(BankName) ? null : BankName.Trim(),
        string.IsNullOrWhiteSpace(TransactionRef) ? null : "Ref " + TransactionRef.Trim()
    }.Where(x => x != null));
}

// from EMR.Web/Models/DTOs/LabReportingDtos.cs
public class LabReportingHierarchyDto
{
    public List<LabReportingPackageGroupDto> Packages { get; set; } = new();
    public List<LabReportingProfileGroupDto> StandaloneProfiles { get; set; } = new();
    public List<LabReportingStandaloneTestGroupDto> StandaloneTestGroups { get; set; } = new();
    public List<LabReportingItemDto> StandaloneItems { get; set; } = new();
}

// from EMR.Web/Models/DTOs/LabReportingDtos.cs
public class LabReportSignatoryDto
{
    /// <summary>VALIDATED or APPROVED</summary>
    public string SignRole { get; set; } = string.Empty;
    public int UserId { get; set; }
    public string? FullName { get; set; }
    public string? RegistrationNo { get; set; }
    public string? CertificationNo { get; set; }
    public bool IsPathologist { get; set; }
    public DateTime? EventDate { get; set; }
}

// from EMR.Web/Models/DTOs/LabReportingDtos.cs
public class LabReportProcessingLabDto
{
    public int BranchId { get; set; }
    public string? BranchName { get; set; }
    public string? BranchCode { get; set; }
    public string? Address { get; set; }
    public string? City { get; set; }
    public string? State { get; set; }
    public string? Pincode { get; set; }
    public string? Phone { get; set; }
    public string? Email { get; set; }
}

// from EMR.Web/Models/DTOs/LabReportingDtos.cs
/// <summary>B2B partner an order was billed to. ClientType: FRANCHISE or COMPANY.</summary>
public class LabReportClientDto
{
    public string ClientType { get; set; } = string.Empty;
    public string? Code { get; set; }
    public string? Name { get; set; }
    public string? Address { get; set; }
    public string? Phone { get; set; }
    /// <summary>1: Prepaid (Wallet), 2: Postpaid (Credit), 3: Hybrid. Companies are always 2.</summary>
    public int CreditFacilityType { get; set; }
    public string CreditFacilityTypeName { get; set; } = string.Empty;
}

// from EMR.Web/Services/LabMiscCharges.cs
/// <summary>A misc line of a saved LAB bill (dbo.LabOrderMiscCharge, SQLScripts/2240).</summary>
public sealed class LabOrderMiscLine
{
    public int LabOrderMiscChargeId { get; set; }
    public int LabOrderId { get; set; }
    public int MiscChargeId { get; set; }
    public string ChargeName { get; set; } = "";
    public string ChargeType { get; set; } = "";
    public int Quantity { get; set; }
    public decimal UnitAmount { get; set; }
    public decimal Amount { get; set; }
    public bool IsDiscountable { get; set; }
    public bool IsGstRequired { get; set; }
    public decimal? GstPercentage { get; set; }
    public decimal DiscountAmount { get; set; }
    public decimal CgstAmount { get; set; }
    public decimal SgstAmount { get; set; }
    public decimal GstAmount { get; set; }
    public decimal NetAmount { get; set; }
    public bool IsActive { get; set; }
    public decimal MembershipDiscountAmount { get; set; }   // Free Home Collection (SQLScripts/2241), part of DiscountAmount

    /// <summary>The ModuleLineRefId of its payment line: negative, so it never matches a LabOrderItemId / InvestigationId.</summary>
    public int LineRefId => -LabOrderMiscChargeId;
    public string DisplayName => Quantity > 1 ? $"{ChargeName} x {Quantity}" : ChargeName;
}

// from EMR.Web/Models/DTOs/LabOrderDtos.cs
public class LabOrderItemDetailDto
{
    public int LabOrderItemId { get; set; }
    public int LabOrderId { get; set; }
    public int InvestigationId { get; set; }
    public string? TestCode { get; set; }
    public string? TestName { get; set; }
    public string? SampleType { get; set; }
    public string? TATHours { get; set; }
    public string? DepartmentName { get; set; }
    public string? CategoryName { get; set; }
    public string? SubCategoryName { get; set; }
    public string? Type { get; set; }
    public decimal Price { get; set; }
    public decimal? B2BRate { get; set; }
    public bool IsUrgent { get; set; }
    public decimal DiscountAmount { get; set; }
    public decimal NetAmount { get; set; }
    public bool IsActive { get; set; }
}

// from EMR.Web/Models/DTOs/LabReportingDtos.cs
public class LabReportingStandaloneTestGroupDto
{
    public string GroupId { get; set; } = string.Empty;
    public long SamplecollectionID { get; set; }
    public int InvestigationId { get; set; }
    public string TestCode { get; set; } = string.Empty;
    public string TestName { get; set; } = string.Empty;
    public string? SharedBarcode { get; set; }
    public string? LabRemarks { get; set; }
    public int CollectionstatusID { get; set; } = 2;
    public string SampleCollectionStatus { get; set; } = "Collected";
    public string SampleCollectionStatusCode { get; set; } = "COLLECTED";
    public int? RejectionReasonId { get; set; }
    public string? RejectionReason { get; set; }
    public List<LabReportingItemDto> Items { get; set; } = new();
}

// from EMR.Web/Models/DTOs/LabReportingDtos.cs
public class LabReportingProfileGroupDto
{
    public string GroupId { get; set; } = string.Empty;
    public int? ProfileId { get; set; }
    public string ProfileName { get; set; } = string.Empty;
    public string? SharedBarcode { get; set; }
    public string? LabRemarks { get; set; }
    public int CollectionstatusID { get; set; } = 2;
    public string SampleCollectionStatus { get; set; } = "Collected";
    public string SampleCollectionStatusCode { get; set; } = "COLLECTED";
    public int? RejectionReasonId { get; set; }
    public string? RejectionReason { get; set; }
    public List<LabReportingItemDto> Items { get; set; } = new();
}

// from EMR.Web/Models/DTOs/LabReportingDtos.cs
public class LabReportingPackageGroupDto
{
    public string GroupId { get; set; } = string.Empty;
    public int? PackageId { get; set; }
    public string PackageName { get; set; } = string.Empty;
    public string? LabRemarks { get; set; }
    public List<LabReportingProfileGroupDto> Profiles { get; set; } = new();
    public List<LabReportingItemDto> StandaloneItems { get; set; } = new();
}

// from EMR.Web/ApiClients/Models/LabParameterOptionModels.cs
public class LabParameterOptionModel
{
    public int Option_ID { get; set; }
    public int CompanyId { get; set; }
    public string Option_Code { get; set; } = string.Empty;
    public int Test_ID { get; set; }
    public string? Test_Name { get; set; }
    public string Option_Text { get; set; } = string.Empty;
    public int Display_Order { get; set; } = 1;
    public bool Is_Abnormal { get; set; } = false;
    public bool Is_Default { get; set; } = false;
    public bool Status { get; set; }
    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; }
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }
}

// from EMR.Web/Services/PrintTemplateRuntime.cs
/// <summary>What the printed document adds to the data points (bill / report number, dates, who printed it).</summary>
public class PrintDocInfo
{
    public string? DocNo { get; set; }
    public string? DocDate { get; set; }
    public string? TokenNo { get; set; }
    public string? CopyLabel { get; set; } = "Original";
    public string? ProcessingLab { get; set; }
    public string? PrintedAt { get; set; }
    public string? PrintedBy { get; set; }
    public string? CreatedBy { get; set; }
}

// from ApiClients/Models/ServiceBookingModels.cs
public class ServiceBookingDetail
{
    public int      OPDServiceId          { get; set; }
    public string?  OPDBillNo             { get; set; }
    public string?  TokenNo               { get; set; }
    public string   PatientCode           { get; set; } = string.Empty;
    public string? BeneficiaryId { get; set; }   // PatientMaster.BeneficiaryId (SQLScripts/2534)
    public string   PatientName           { get; set; } = string.Empty;
    public string?  PhoneNumber           { get; set; }
    public string?  Gender                { get; set; }
    public DateTime? DateOfBirth          { get; set; }
    public string?  ConsultingDoctorName  { get; set; }
    public DateTime VisitDate             { get; set; }
    public TimeSpan? AppointmentTime      { get; set; }
    public DateTime CreatedDate           { get; set; }
    public string?  CreatedByUser         { get; set; }
    public decimal  TotalAmount           { get; set; }
    public string   Status                { get; set; } = string.Empty;
    public List<ServiceBookingDetailItem> Items { get; set; } = new();

    // Computed — mirrors ViewModels
    public int? Age => DateOfBirth.HasValue
        ? (int)((DateTime.Today - DateOfBirth.Value.Date).TotalDays / 365.25)
        : null;
    public string FormattedAge => EMR.Common.AgeCalculator.FormatAgePattern(DateOfBirth, Age);
}

// from ApiClients/Models/ServiceBookingModels.cs
public class ServiceBookingDetailItem
{
    public int      ItemId          { get; set; }
    public string?  ServiceType     { get; set; }
    public string   ItemName        { get; set; } = string.Empty;
    public decimal  ServiceCharges  { get; set; }
    public bool     IsGstRequired   { get; set; }
    public decimal? GstPercentage   { get; set; }
}

// from Models/DTOs/LabReportDispatchDtos.cs
/// <summary>One test of a bill, as shown by the dispatch list's "view tests" modal.</summary>
public class LabReportDispatchTestDto
{
    public long SamplecollectionID { get; set; }
    public string? TestCode { get; set; }
    public string TestName { get; set; } = string.Empty;
    /// <summary>Numeric / Image / Text / Select / Descriptive - decides which print format applies.</summary>
    public string? ReportingType { get; set; }
    public string? DepartmentName { get; set; }
    public string? CategoryName { get; set; }
    public string? GroupName { get; set; }
    public string? SampleTypeName { get; set; }
    public string? ContainerType { get; set; }
    public string? BarcodeNo { get; set; }
    public int CollectionstatusID { get; set; }
    public string? SampleStatusName { get; set; }
    public string? RejectionReason { get; set; }
    public DateTime? CollectedOn { get; set; }
    public DateTime? ReceivedDate { get; set; }
    public bool IsTransferred { get; set; }
    public string? TargetBranchName { get; set; }
    public int ReportStatusId { get; set; }
    public string? ReportStatusName { get; set; }
    public DateTime? DraftedDate { get; set; }
    public DateTime? SubmittedDate { get; set; }
    public DateTime? ValidatedDate { get; set; }
    public DateTime? ApprovedDate { get; set; }
    public string? ApprovedByName { get; set; }
    public int? TatMinutes { get; set; }
}

// from Models/ViewModels/PaymentViewModels.cs
public class BillPaymentSummary
{
    public decimal SubTotal { get; set; }
    public string? DiscountType { get; set; }        // "P" = percent, "F" = flat, null = none
    public decimal DiscountValue { get; set; }
    public decimal DiscountAmount { get; set; }
    public decimal RoundOffAmount { get; set; }
    public decimal NetAmount { get; set; }
    public decimal TotalPaid { get; set; }
    public decimal BalanceDue { get; set; }
    public string PaymentStatus { get; set; } = "U";  // P=Paid R=Partial U=Unpaid
    public DateTime? PaidOn { get; set; }

    public decimal TotalCgstAmount { get; set; }
    public decimal TotalSgstAmount { get; set; }
    public decimal TotalIgstAmount { get; set; }

    public List<BillPaymentRow> Rows { get; set; } = [];
    public List<BillPaymentLineItem> LineItems { get; set; } = [];
}

// from Models/ViewModels/PaymentViewModels.cs
public class BillPaymentRow
{
    public string MethodName { get; set; } = string.Empty;
    public decimal PaidAmount { get; set; }
    public string? TransactionRef { get; set; }
    public string? ChequeNo { get; set; }
    public string? BankName { get; set; }
    public string? UPIRefNo { get; set; }
    public string? CardLast4 { get; set; }
    public string? ReceiptNo { get; set; }
}

// from Models/ViewModels/PaymentViewModels.cs
public class BillPaymentLineItem
{
    public int ModuleLineRefId { get; set; }
    public decimal CgstAmount { get; set; }
    public decimal SgstAmount { get; set; }
    public decimal IgstAmount { get; set; }
    public decimal NetLineAmount { get; set; }
}
