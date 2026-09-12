using System;
using System.Collections.Generic;
using EMR.Web.Models.DTOs;

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
    }

    public class LabReportingEntryPageViewModel
    {
        public LabReportingOrderDetailDto Detail { get; set; } = new();
        public List<LabReportStatusMasterDto> Statuses { get; set; } = new();
    }
}
