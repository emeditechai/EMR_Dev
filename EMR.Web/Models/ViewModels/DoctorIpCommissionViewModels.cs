using EMR.Web.ApiClients.Models;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Models.ViewModels;

public class DoctorIpCommissionIndexViewModel
{
    public List<DoctorIpCommissionPendingModel> PendingItems { get; set; } = [];
    public List<DoctorIpCommissionListModel> ComputedItems { get; set; } = [];
    public int? SelectedDoctorId { get; set; }
    public DateTime FromDate { get; set; }
    public DateTime ToDate { get; set; }
    public string ActiveTab { get; set; } = "pending";
    public string? BranchName { get; set; }
    public int UnlockMinutesLeft { get; set; }
    public string ComputeMode { get; set; } = "Manual";
    public TimeSpan? AutoRunTime { get; set; }
    public List<SelectListItem> DoctorOptions { get; set; } = [];
}
