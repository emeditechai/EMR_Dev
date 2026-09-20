using System.Globalization;
using EMR.Web.Models.DTOs;
using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;

namespace EMR.Web.Services;

/// <summary>
/// Builds the printable Lab Report model. Pure (no I/O) so the rules can be tested in isolation.
///
/// Rules
///  - Only tests that are Validated (status 3) or Approved (status 5) with a value are printed;
///    pending / submitted / draft / re-collect / rejected tests are left out.
///  - "NOT APPROVED" watermark: shown when any printed test is validated but not yet approved.
///  - "Final Report": every active test of the order is approved; otherwise "Provisional Report".
///  - A new page starts for every Department + Test Category. Within a page: Package heading -> Profile
///    heading -> tests, and standalone investigations each get their own heading. A package or profile
///    is never split across sections: it is placed under the section of its first test.
/// </summary>
public static class LabReportPrintBuilder
{
    private const int StatusValidated = 3;
    private const int StatusApproved = 5;

    public static LabReportPrintViewModel Build(
        LabReportingOrderDetailDto detail,
        LabOrderDetailDto? order,
        LabReportPrintMetaDto? meta,
        HospitalSettings? settings,
        BranchMaster? billingBranch,
        string printedBy,
        DateTime now)
    {
        var items = detail.Items ?? new List<LabReportingItemDto>();
        var activeItems = items.Where(IsActiveTest).ToList();
        var included = IncludedItems(activeItems);

        var sampleMeta = (meta?.Samples ?? new List<LabReportSampleMetaDto>())
            .GroupBy(s => s.SamplecollectionID)
            .ToDictionary(g => g.Key, g => g.First());

        var remarksByKey = (detail.GroupRemarks ?? new List<LabReportGroupRemarkDto>())
            .Where(r => !string.IsNullOrWhiteSpace(r.GroupKey) && !string.IsNullOrWhiteSpace(r.LabRemarks))
            .GroupBy(r => r.GroupKey, StringComparer.OrdinalIgnoreCase)
            .ToDictionary(g => g.Key, g => g.First().LabRemarks!, StringComparer.OrdinalIgnoreCase);

        var summary = Summarize(detail);

        var vm = new LabReportPrintViewModel
        {
            LabOrderId = detail.LabOrderId,
            BillNo = detail.BillNo,
            TokenNo = detail.TokenNo,
            IncludedTestCount = summary.IncludedTestCount,
            ExcludedTestCount = summary.ExcludedTestCount,
            IsFinal = summary.IsFinal,
            ShowNotApprovedWatermark = summary.ShowNotApprovedWatermark,
            PrintedBy = printedBy,
            PrintedOn = now
        };

        FillLetterhead(vm, settings);
        FillPatient(vm, detail, order);
        FillClient(vm, detail, order, meta, settings, billingBranch);

        // ── Specimen timestamps ───────────────────────────────────────────────
        vm.Barcodes = string.Join(", ", included.Select(i => i.BarcodeNo).Where(b => !string.IsNullOrWhiteSpace(b)).Distinct());
        var collectedTimes = included
            .Where(i => i.Samplecollectiondate.HasValue)
            .Select(i => i.Samplecollectiondate!.Value.Date + (i.Samplecollectiontime ?? TimeSpan.Zero))
            .ToList();
        vm.Collected = collectedTimes.Count > 0 ? collectedTimes.Min() : null;

        var receivedTimes = included
            .Select(i => sampleMeta.TryGetValue(i.SamplecollectionID, out var m) ? m.ReceivedDate : null)
            .Where(d => d.HasValue)
            .Select(d => d!.Value)
            .ToList();
        vm.Received = receivedTimes.Count > 0 ? receivedTimes.Min() : null;

        var reportedTimes = included
            .Select(i => i.ApprovedDate ?? i.ValidatedDate)
            .Where(d => d.HasValue)
            .Select(d => d!.Value)
            .ToList();
        vm.Reported = reportedTimes.Count > 0 ? reportedTimes.Max() : null;

        vm.Sections = BuildSections(included, sampleMeta, remarksByKey);
        vm.HasCritical = vm.Sections.SelectMany(s => s.Groups).SelectMany(g => g.Rows).Any(r => r.IsCritical);

        FillSignatories(vm, meta);
        FillProcessingLab(vm, meta, detail);

        return vm;
    }

    /// <summary>The print-state rules on their own: what prints, whether it is final, and whether it is watermarked.</summary>
    public static (int IncludedTestCount, int ExcludedTestCount, bool IsFinal, bool ShowNotApprovedWatermark) Summarize(LabReportingOrderDetailDto detail)
    {
        var activeItems = (detail.Items ?? new List<LabReportingItemDto>()).Where(IsActiveTest).ToList();
        var included = IncludedItems(activeItems);

        return (
            included.Count,
            activeItems.Count - included.Count,
            activeItems.Count > 0 && activeItems.All(i => HasValue(i) && i.ReportStatusId == StatusApproved),
            included.Any(i => i.ReportStatusId != StatusApproved));
    }

    private static List<LabReportingItemDto> IncludedItems(List<LabReportingItemDto> activeItems) =>
        activeItems
            .Where(i => HasValue(i) && (i.ReportStatusId == StatusValidated || i.ReportStatusId == StatusApproved))
            .ToList();

    // ═════════════════════════ header / patient / client ═════════════════════════

    private static void FillLetterhead(LabReportPrintViewModel vm, HospitalSettings? s)
    {
        if (s == null) return;
        if (!string.IsNullOrWhiteSpace(s.HospitalName)) vm.HospitalName = s.HospitalName;
        vm.HospitalLogoPath = s.LogoPath;
        vm.HospitalAddress = s.Address;
        vm.HospitalPhone = s.ContactNumber1;
        vm.HospitalEmail = s.EmailAddress;
        vm.HospitalWebsite = s.Website;
        vm.RegistrationNumber = s.RegistrationNumber;
        // "Not Applied" / "None" is not worth printing on a report letterhead
        var nabh = s.NabhStatus?.Trim();
        bool showNabh = !string.IsNullOrWhiteSpace(nabh)
            && !new[] { "not applied", "n/a", "na", "none", "not applicable" }.Contains(nabh!.ToLowerInvariant());
        if (showNabh)
        {
            vm.NabhLine = string.IsNullOrWhiteSpace(s.NabhCertificateNo)
                ? $"NABH: {s.NabhStatus}"
                : $"NABH: {s.NabhStatus} (Cert. No. {s.NabhCertificateNo})";
        }
    }

    private static void FillPatient(LabReportPrintViewModel vm, LabReportingOrderDetailDto detail, LabOrderDetailDto? order)
    {
        vm.PatientName = order?.PatientName ?? detail.PatientName;
        vm.PatientCode = order?.PatientCode ?? detail.PatientCode;
        vm.PatientPhone = order?.PhoneNumber ?? detail.PhoneNumber;
        vm.PatientAddress = order?.Address ?? detail.Address;

        var gender = order?.Gender ?? detail.Gender;
        var age = order != null && !string.IsNullOrWhiteSpace(order.FormattedAge)
            ? order.FormattedAge
            : (detail.Age.HasValue ? $"{detail.Age} Y" : string.Empty);
        vm.AgeGender = string.IsNullOrWhiteSpace(age)
            ? (gender ?? "—")
            : (string.IsNullOrWhiteSpace(gender) ? age : $"{age} /{gender}");
    }

    /// <summary>
    /// Client box. B2C billing: the billing Branch (code / name / address / phone).
    /// B2B billing: the Franchise or Company the order was billed to (labels follow the partner type).
    /// </summary>
    private static void FillClient(LabReportPrintViewModel vm, LabReportingOrderDetailDto detail, LabOrderDetailDto? order,
                                   LabReportPrintMetaDto? meta, HospitalSettings? settings, BranchMaster? branch)
    {
        var partner = meta?.Client;
        if (partner != null || order?.IsB2B == true)
        {
            var isFranchise = partner != null
                ? string.Equals(partner.ClientType, "FRANCHISE", StringComparison.OrdinalIgnoreCase)
                : !string.Equals(order?.AgentType, "C", StringComparison.OrdinalIgnoreCase);

            vm.ClientLabel = isFranchise ? "Franchise" : "Company";
            vm.ClientCode = partner?.Code ?? order?.AgentCode;
            vm.ClientName = partner?.Name ?? order?.AgentName;
            vm.ClientAddress = partner?.Address;   // franchises have no address on record
            vm.ClientPhone = partner?.Phone;
            return;
        }

        vm.ClientLabel = "Branch";
        vm.ClientCode = branch?.BranchCode;
        vm.ClientName = branch?.BranchName ?? order?.BranchName ?? detail.BranchName;
        vm.ClientAddress = !string.IsNullOrWhiteSpace(settings?.Address) ? settings!.Address : branch?.Address;
        vm.ClientPhone = settings?.ContactNumber1;
    }

    private static void FillSignatories(LabReportPrintViewModel vm, LabReportPrintMetaDto? meta)
    {
        if (meta?.Signatories == null) return;

        List<LabReportSignatory> Pick(string role) => meta.Signatories
            .Where(s => string.Equals(s.SignRole, role, StringComparison.OrdinalIgnoreCase) && !string.IsNullOrWhiteSpace(s.FullName))
            .GroupBy(s => s.UserId)
            .Select(g => g.First())
            .Select(s => new LabReportSignatory
            {
                Name = s.FullName!,
                Qualification = s.IsPathologist ? "Pathologist" : null,
                RegistrationNo = !string.IsNullOrWhiteSpace(s.RegistrationNo) ? s.RegistrationNo : s.CertificationNo
            })
            .ToList();

        vm.ValidatedBy = Pick("VALIDATED");
        vm.ApprovedBy = Pick("APPROVED");
    }

    private static void FillProcessingLab(LabReportPrintViewModel vm, LabReportPrintMetaDto? meta, LabReportingOrderDetailDto detail)
    {
        var lab = meta?.ProcessingLab;
        if (lab == null)
        {
            vm.ProcessingLabName = detail.BranchName;
            return;
        }

        vm.ProcessingLabName = lab.BranchName;
        vm.ProcessingLabAddress = string.Join(", ", new[] { lab.Address, lab.City, lab.State, lab.Pincode }
            .Where(p => !string.IsNullOrWhiteSpace(p)));
    }

    // ═════════════════════════ results: sections / groups / rows ═════════════════════════

    private sealed class Unit
    {
        public string Key = string.Empty;
        public string? PackageName;
        public string DepartmentName = "General";
        public string CategoryName = "Other";
        public int CategoryOrder = 9999;
        public List<SubGroup> SubGroups = new();
    }

    private sealed class SubGroup
    {
        public string Key = string.Empty;
        public string? Title;
        public List<LabReportingItemDto> Items = new();
    }

    private static List<LabReportSection> BuildSections(
        List<LabReportingItemDto> included,
        Dictionary<long, LabReportSampleMetaDto> sampleMeta,
        Dictionary<string, string> remarksByKey)
    {
        // 1. Top-level units (package | profile | standalone test) in first-appearance order.
        var units = new List<Unit>();
        var unitByKey = new Dictionary<string, Unit>();

        foreach (var item in included)
        {
            string unitKey;
            string subKey;
            string? subTitle;
            string? packageName = null;

            bool hasPackage = HasName(item.PackageName);
            bool hasProfile = HasName(item.ProfileName);
            string profKey = $"PRF_{item.ProfileId?.ToString() ?? item.ProfileName}";

            if (hasPackage)
            {
                unitKey = $"PKG_{item.PackageId?.ToString() ?? item.PackageName}";
                packageName = item.PackageName;
                subKey = hasProfile ? profKey : $"{unitKey}#direct";
                subTitle = hasProfile ? item.ProfileName : null;
            }
            else if (hasProfile)
            {
                unitKey = profKey;
                subKey = profKey;
                subTitle = item.ProfileName;
            }
            else
            {
                unitKey = $"INV_{item.InvestigationID}";
                subKey = unitKey;
                subTitle = item.TestName;
            }

            if (!unitByKey.TryGetValue(unitKey, out var unit))
            {
                // A unit's home section is decided by its FIRST test so a profile/package is never split.
                sampleMeta.TryGetValue(item.SamplecollectionID, out var m);
                unit = new Unit
                {
                    Key = unitKey,
                    PackageName = packageName,
                    DepartmentName = string.IsNullOrWhiteSpace(m?.DepartmentName) ? (item.DepartmentName ?? "General") : m!.DepartmentName!,
                    CategoryName = string.IsNullOrWhiteSpace(m?.CategoryName) ? "Other" : m!.CategoryName!,
                    CategoryOrder = m?.CategoryOrder ?? 9999
                };
                unitByKey[unitKey] = unit;
                units.Add(unit);
            }

            var sub = unit.SubGroups.FirstOrDefault(s => s.Key == subKey);
            if (sub == null)
            {
                sub = new SubGroup { Key = subKey, Title = subTitle };
                unit.SubGroups.Add(sub);
            }
            sub.Items.Add(item);
        }

        // 2. Sections: Department -> Category (display order), each one starts a new printed page.
        var sections = new List<LabReportSection>();
        var ordered = units
            .Select((u, idx) => (u, idx))
            .OrderBy(x => x.u.DepartmentName, StringComparer.OrdinalIgnoreCase)
            .ThenBy(x => x.u.CategoryOrder)
            .ThenBy(x => x.u.CategoryName, StringComparer.OrdinalIgnoreCase)
            .ThenBy(x => x.idx);

        foreach (var (unit, _) in ordered)
        {
            var section = sections.FirstOrDefault(s =>
                string.Equals(s.DepartmentName, unit.DepartmentName, StringComparison.OrdinalIgnoreCase) &&
                string.Equals(s.CategoryName, unit.CategoryName, StringComparison.OrdinalIgnoreCase));
            if (section == null)
            {
                section = new LabReportSection { DepartmentName = unit.DepartmentName, CategoryName = unit.CategoryName };
                sections.Add(section);
            }

            bool firstOfPackage = true;
            foreach (var sub in unit.SubGroups)
            {
                var group = new LabReportGroup
                {
                    PackageHeading = unit.PackageName != null && firstOfPackage ? unit.PackageName : null,
                    Title = sub.Title,
                    SampleType = string.Join(" / ", sub.Items
                        .Select(i => i.SampleTypeName)
                        .Where(n => !string.IsNullOrWhiteSpace(n))
                        .Select(n => n!.Trim().ToUpperInvariant())
                        .Distinct()),
                    Rows = sub.Items.Select(BuildRow).ToList(),
                    Notes = BuildNotes(sub, remarksByKey)
                };
                firstOfPackage = false;
                section.Groups.Add(group);
            }

            // Package-level lab remark goes under the last group of the package.
            if (unit.PackageName != null && remarksByKey.TryGetValue(unit.Key, out var pkgRemark) && section.Groups.Count > 0)
            {
                section.Groups[^1].Notes.AddRange(SplitLines(pkgRemark));
            }
        }

        return sections;
    }

    private static List<string> BuildNotes(SubGroup sub, Dictionary<string, string> remarksByKey)
    {
        var notes = new List<string>();

        // Group-level lab remark (same GroupKey scheme the Entry page uses: PRF_<id|name> / INV_<id>)
        var groupKey = sub.Key.StartsWith("PRF_", StringComparison.Ordinal)
            ? sub.Key
            : $"INV_{sub.Items[0].InvestigationID}";
        if (remarksByKey.TryGetValue(groupKey, out var groupRemark))
        {
            notes.AddRange(SplitLines(groupRemark));
        }
        else
        {
            var fallback = sub.Items.Select(i => i.GroupLabRemarks).FirstOrDefault(r => !string.IsNullOrWhiteSpace(r));
            if (!string.IsNullOrWhiteSpace(fallback)) notes.AddRange(SplitLines(fallback));
        }

        // Per-test remarks / interpretation
        foreach (var item in sub.Items)
        {
            var remark = item.Remarks?.Trim();
            if (string.IsNullOrWhiteSpace(remark)) continue;

            var line = sub.Items.Count > 1 ? $"{item.TestName}: {remark}" : remark;
            if (!notes.Contains(line, StringComparer.OrdinalIgnoreCase)) notes.Add(line);
        }

        return notes;
    }

    private static LabReportRow BuildRow(LabReportingItemDto item)
    {
        var (flagText, abnormal, critical) = ResolveFlag(item);
        var result = (item.TestValue ?? string.Empty).Trim();

        return new LabReportRow
        {
            TestName = item.TestName,
            Result = result,
            FlagText = flagText,
            IsAbnormal = abnormal,
            IsCritical = critical,
            RefRange = string.IsNullOrWhiteSpace(item.ReferenceRange) ? string.Empty : item.ReferenceRange.Trim(),
            Unit = item.UnitName?.Trim() ?? string.Empty,
            Method = item.MethodName?.Trim() ?? string.Empty,
            IsApproved = item.ReportStatusId == StatusApproved,
            IsLongText = result.Length > 40 || result.Contains('\n')
        };
    }

    /// <summary>H / L from the stored flag (or computed from the reference limits), and "*" for critical values.</summary>
    internal static (string FlagText, bool IsAbnormal, bool IsCritical) ResolveFlag(LabReportingItemDto item)
    {
        var raw = (item.AbnormalFlag ?? string.Empty).Trim();
        bool critical = raw.Equals("Critical", StringComparison.OrdinalIgnoreCase);

        string direction = raw.Equals("H", StringComparison.OrdinalIgnoreCase) ? "H"
                         : raw.Equals("L", StringComparison.OrdinalIgnoreCase) ? "L"
                         : string.Empty;

        if (direction.Length == 0 &&
            decimal.TryParse(item.TestValue, NumberStyles.Any, CultureInfo.InvariantCulture, out var value))
        {
            if (item.HighValue.HasValue && value > item.HighValue.Value) direction = "H";
            else if (item.LowValue.HasValue && value < item.LowValue.Value) direction = "L";
        }

        var text = critical
            ? (direction.Length > 0 ? $"* {direction}" : "*")
            : direction;

        return (text, direction.Length > 0 || critical, critical);
    }

    // ═════════════════════════ helpers ═════════════════════════

    private static bool IsActiveTest(LabReportingItemDto i) => i.CollectionstatusID != 3 && i.CollectionstatusID != 4;
    private static bool HasValue(LabReportingItemDto i) => !string.IsNullOrWhiteSpace(i.TestValue);
    private static bool HasName(string? n) => !string.IsNullOrWhiteSpace(n) && n != "—";

    private static IEnumerable<string> SplitLines(string text) =>
        text.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries)
            .Select(l => l.Trim())
            .Where(l => l.Length > 0);
}
