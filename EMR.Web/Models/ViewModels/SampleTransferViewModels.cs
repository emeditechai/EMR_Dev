using System;
using System.Collections.Generic;
using EMR.Web.Models.DTOs;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Models.ViewModels
{
    public class SampleTransferDashboardViewModel
    {
        public int BranchId { get; set; }
        public string? BranchName { get; set; }
        public DateTime FromDate { get; set; }
        public DateTime ToDate { get; set; }
        public string DateFilterType { get; set; } = "CollectionDate";
        public string TransferStatusFilter { get; set; } = "Ready";
        public string? Search { get; set; }
        public int? DepartmentId { get; set; }
        public int? CategoryId { get; set; }
        public int? SubCategoryId { get; set; }
        public List<SelectListItem> DepartmentOptions { get; set; } = new();
        public List<SelectListItem> CategoryOptions { get; set; } = new();
        public List<SelectListItem> SubCategoryOptions { get; set; } = new();
        public SampleTransferStatsDto Stats { get; set; } = new();
        public SampleTransferReceiveStatsDto ReceiveStats { get; set; } = new();
        public List<SampleTransferEligibleItemDto> Items { get; set; } = new();
        public List<SelectListItem> TargetBranches { get; set; } = new();
    }
}
