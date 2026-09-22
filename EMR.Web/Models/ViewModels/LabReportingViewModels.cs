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
    }

    /// <summary>Initial filter values of the Lab Report Dispatch dashboard.</summary>
    public class LabReportDispatchPageViewModel
    {
        public DateTime FromDate { get; set; } = DateTime.Today;
        public DateTime ToDate { get; set; } = DateTime.Today;
    }
}
