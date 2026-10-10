using System;
using System.Collections.Generic;
using EMR.Web.Models.DTOs;
using EMR.Web.ApiClients.Models;

using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Models.ViewModels
{
    public class LabReportingDashboardViewModel
    {
        public int BranchId { get; set; }
        public DateTime FromDate { get; set; }
        public DateTime ToDate { get; set; }
        public string DateFilterType { get; set; } = "BookingDate";
        public string StatusFilter { get; set; } = "All";
        public string? Search { get; set; }
        public int? DepartmentId { get; set; }
        public int? CategoryId { get; set; }
        public int? SubCategoryId { get; set; }
        public List<SelectListItem> DepartmentOptions { get; set; } = new();
        public List<SelectListItem> CategoryOptions { get; set; } = new();
        public List<SelectListItem> SubCategoryOptions { get; set; } = new();
        public LabReportingStatsDto Stats { get; set; } = new();
        public List<LabReportingHeaderDto> Headers { get; set; } = new();
        public List<LabReportStatusMasterDto> Statuses { get; set; } = new();
        /// <summary>True when the list is limited to the user's Department Access (User Master).</summary>
        public bool DepartmentScopeRestricted { get; set; }
        /// <summary>LAB departments the user may report on (empty + restricted = none assigned).</summary>
        public List<string> DepartmentScopeNames { get; set; } = new();
    }

    /// <summary>A calculated parameter on the Report Entry screen (Lab Master &gt; Lab Formula Component).</summary>
    public class LabFormulaTargetInfo
    {
        public string TestCode { get; set; } = string.Empty;
        public string TestName { get; set; } = string.Empty;
        /// <summary>The configured expression, e.g. <c>[TST0040]/[TST0041]</c>.</summary>
        public string Expression { get; set; } = string.Empty;
        /// <summary>The same expression with test names, for the hint under the field.</summary>
        public string Hint { get; set; } = string.Empty;
        public int RoundingPrecision { get; set; }
        public string? ValidityCondition { get; set; }
    }

    public class LabReportingEntryPageViewModel
    {
        public LabReportingOrderDetailDto Detail { get; set; } = new();
        public List<LabReportStatusMasterDto> Statuses { get; set; } = new();
        public List<SampleCollectionStatusMasterDto> SampleCollectionStatuses { get; set; } = new();
        public List<LabSampleRejectionReasonModel> RejectionReasons { get; set; } = new();
        /// <summary>Franchise / Company the order was billed to; null for B2C orders.</summary>
        public LabReportClientDto? B2BClient { get; set; }
        /// <summary>
        /// Hospital Settings > LAB > "Pathologist approval required" for this branch. When it is on, approval belongs
        /// to the Pathologist Dashboard and this screen must not offer an Approve button.
        /// </summary>
        public bool PathologistApprovalRequired { get; set; }

        /// <summary>
        /// Which reporting screen renders the shared Entry page. Lab Report Entry keeps the defaults; Microbiology
        /// Report Entry (Reporting Type Template) posts to its own controller and checks its own page permissions.
        /// </summary>
        public LabReportingScreen Screen { get; set; } = LabReportingScreen.Numeric;

        /// <summary>Picklist answers of every Select parameter on the order, by Test_ID (Lab Parameter Option Master).</summary>
        public Dictionary<int, List<LabPicklistOption>> PicklistOptions { get; set; } = new();

        /// <summary>Default narrative (Lab Descriptive Test Template) of each descriptive parameter not reported yet, by sample.</summary>
        public Dictionary<long, string> DescriptiveDefaults { get; set; } = new();
    }

    /// <summary>The controller, page code and titles of a reporting screen that uses the shared Entry page.</summary>
    public sealed record LabReportingScreen(string Controller, string PageCode, string ListTitle, string ReportingType, bool MixedTypes)
    {
        public static readonly LabReportingScreen Numeric =
            new("LabReporting", "LAB.LABREPORTING", "Lab Reporting Entry", "Numeric", false);
        public static readonly LabReportingScreen Microbiology =
            new("MicrobiologyReporting", "LAB.MICROBIOLOGYREPORTING", "Microbiology Report Entry", "Template", true);
    }

    /// <summary>One answer of a Select (picklist) parameter.</summary>
    public sealed record LabPicklistOption(string Text, bool IsAbnormal, bool IsDefault);

    /// <summary>Initial filter values of the Lab Report Dispatch dashboard.</summary>
    public class LabReportDispatchPageViewModel
    {
        public DateTime FromDate { get; set; } = DateTime.Today;
        public DateTime ToDate { get; set; } = DateTime.Today;
    }
}
