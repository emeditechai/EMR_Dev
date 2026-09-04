using System.Text.Json;
using EMR.Web.ApiClients;
using EMR.Web.ApiClients.Models;
using EMR.Web.Extensions;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Controllers;

[Authorize]
public class LabInvestigationProfilesController(
    ILabInvestigationProfileApiClient profileApiClient,
    ILabInvestigationApiClient investigationApiClient,
    ILabMasterDashboardService dashboardService,
    IAuditLogService auditLogService) : Controller
{
    [HttpGet]
    public async Task<IActionResult> Index(int? profileType = null, bool? status = null, string? search = null)
    {
        var companyId = User.GetCompanyId();

        try
        {
            var profiles = (await profileApiClient.GetListAsync(profileType, status, search, companyId)).ToList();
            var dashboard = await dashboardService.GetDashboardAsync(companyId, "LabInvestigationProfiles");

            var model = new LabInvestigationProfileIndexViewModel
            {
                Profiles = profiles,
                SelectedProfileType = profileType,
                SelectedStatus = status,
                SearchTerm = search,
                Dashboard = dashboard,
                ProfileTypeOptions = GetProfileTypeOptions(),
                StatusOptions = new List<SelectListItem>
                {
                    new() { Value = "true", Text = "Active Only", Selected = status == true },
                    new() { Value = "false", Text = "Inactive Only", Selected = status == false }
                }
            };

            return View(model);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Investigation Profile Master";
            return View("ApiDown");
        }
    }

    [HttpGet]
    public async Task<IActionResult> Create()
    {
        var model = new LabInvestigationProfileFormViewModel
        {
            CompanyId = User.GetCompanyId(),
            Profile_Type = 1,
            Profile_TAT_Hours = 24,
            Report_Print_Sequence = 1,
            Status = true,
            Applicable_Gender = "All"
        };

        await PopulateFormOptionsAsync(model);
        return View(model);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(LabInvestigationProfileFormViewModel model)
    {
        if (model.Profile_Type == 1)
        {
            if (!model.Test_ID.HasValue || model.Test_ID.Value <= 0)
            {
                ModelState.AddModelError(nameof(model.Test_ID), "Please select a Profile Test.");
            }
            else if (string.IsNullOrWhiteSpace(model.Profile_Name))
            {
                var test = await investigationApiClient.GetByIdAsync(model.Test_ID.Value);
                if (test != null)
                {
                    model.Profile_Name = test.Test_Name;
                }
            }
        }
        else // Package (2)
        {
            model.Test_ID = null;
            if (string.IsNullOrWhiteSpace(model.Profile_Name))
            {
                ModelState.AddModelError(nameof(model.Profile_Name), "Package Name is required.");
            }
        }

        if (!ModelState.IsValid)
        {
            await PopulateFormOptionsAsync(model);
            return View(model);
        }

        try
        {
            var details = JsonSerializer.Deserialize<List<LabInvestigationProfileDetailSaveModel>>(model.DetailsJson ?? "[]") ?? [];
            if (!details.Any())
            {
                ModelState.AddModelError(string.Empty, "At least one investigation test detail row must be added to the profile/package.");
                await PopulateFormOptionsAsync(model);
                return View(model);
            }

            var req = new LabInvestigationProfileSaveRequestModel
            {
                Profile_ID = null,
                CompanyId = User.GetCompanyId(),
                Profile_Name = model.Profile_Name,
                Profile_Type = model.Profile_Type,
                Test_ID = model.Test_ID,
                MRP = model.MRP,
                Discount_Pct = model.Profile_Type == 2 ? model.Discount_Pct : 0,
                Effective_Start_Date = model.Profile_Type == 2 ? model.Effective_Start_Date : null,
                Effective_End_Date = model.Profile_Type == 2 ? model.Effective_End_Date : null,
                Age_Operator = model.Age_Operator,
                Applicable_Age = model.Applicable_Age,
                Applicable_Gender = model.Applicable_Gender,
                Profile_TAT_Hours = model.Profile_TAT_Hours,
                Profile_NABL_Accredited = model.Profile_NABL_Accredited,
                Report_Print_Sequence = model.Report_Print_Sequence,
                Status = model.Status,
                UserId = User.GetUserId(),
                Details = details
            };

            var newId = await profileApiClient.SaveAsync(req);

            var typeName = model.Profile_Type == 2 ? "Package" : "Profile";
            await auditLogService.LogAsync(
                "Create Lab Investigation Profile",
                "Create",
                $"Created {typeName} '{model.Profile_Name}' with ID #{newId}",
                User.GetUserId(),
                User.GetCurrentBranchId() ?? 1
            );

            TempData["SuccessMessage"] = $"{typeName} '{model.Profile_Name}' saved successfully.";
            return RedirectToAction(nameof(Index));
        }
        catch (InvalidOperationException ex)
        {
            ModelState.AddModelError(string.Empty, ex.Message);
            await PopulateFormOptionsAsync(model);
            return View(model);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Create Investigation Profile";
            return View("ApiDown");
        }
    }

    [HttpGet]
    public async Task<IActionResult> Edit(int id)
    {
        try
        {
            var item = await profileApiClient.GetByIdAsync(id);
            if (item == null)
            {
                TempData["ErrorMessage"] = "Investigation Profile record not found.";
                return RedirectToAction(nameof(Index));
            }

            var detailRows = item.Details.Select(d => new LabInvestigationProfileDetailRowViewModel
            {
                Detail_ID = d.Detail_ID,
                Test_ID = d.Test_ID,
                Test_Code = d.Test_Code,
                Test_Name = d.Test_Name,
                Sequence = d.Sequence,
                TestMRP = d.TestMRP,
                Reporting_Type = d.Reporting_Type,
                DepartmentName = d.DepartmentName,
                CategoryName = d.CategoryName
            }).ToList();

            var model = new LabInvestigationProfileFormViewModel
            {
                Profile_ID = item.Header.Profile_ID,
                CompanyId = item.Header.CompanyId,
                Profile_Code = item.Header.Profile_Code,
                Profile_Name = item.Header.Profile_Name,
                Profile_Type = item.Header.Profile_Type,
                Test_ID = item.Header.Test_ID,
                MRP = item.Header.MRP,
                Discount_Pct = item.Header.Discount_Pct,
                Effective_Start_Date = item.Header.Effective_Start_Date,
                Effective_End_Date = item.Header.Effective_End_Date,
                Age_Operator = item.Header.Age_Operator,
                Applicable_Age = item.Header.Applicable_Age,
                Applicable_Gender = item.Header.Applicable_Gender,
                Profile_TAT_Hours = item.Header.Profile_TAT_Hours,
                Profile_NABL_Accredited = item.Header.Profile_NABL_Accredited,
                Report_Print_Sequence = item.Header.Report_Print_Sequence,
                Status = item.Header.Status,
                DetailsJson = JsonSerializer.Serialize(detailRows)
            };

            await PopulateFormOptionsAsync(model);
            return View(model);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Edit Investigation Profile";
            return View("ApiDown");
        }
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(int id, LabInvestigationProfileFormViewModel model)
    {
        if (id != model.Profile_ID)
            return BadRequest();

        if (model.Profile_Type == 1)
        {
            if (!model.Test_ID.HasValue || model.Test_ID.Value <= 0)
            {
                ModelState.AddModelError(nameof(model.Test_ID), "Please select a Profile Test.");
            }
            else if (string.IsNullOrWhiteSpace(model.Profile_Name))
            {
                var test = await investigationApiClient.GetByIdAsync(model.Test_ID.Value);
                if (test != null)
                {
                    model.Profile_Name = test.Test_Name;
                }
            }
        }
        else // Package (2)
        {
            model.Test_ID = null;
            if (string.IsNullOrWhiteSpace(model.Profile_Name))
            {
                ModelState.AddModelError(nameof(model.Profile_Name), "Package Name is required.");
            }
        }

        if (!ModelState.IsValid)
        {
            await PopulateFormOptionsAsync(model);
            return View(model);
        }

        try
        {
            var details = JsonSerializer.Deserialize<List<LabInvestigationProfileDetailSaveModel>>(model.DetailsJson ?? "[]") ?? [];
            if (!details.Any())
            {
                ModelState.AddModelError(string.Empty, "At least one investigation test detail row must be added to the profile/package.");
                await PopulateFormOptionsAsync(model);
                return View(model);
            }

            var req = new LabInvestigationProfileSaveRequestModel
            {
                Profile_ID = model.Profile_ID,
                CompanyId = model.CompanyId,
                Profile_Name = model.Profile_Name,
                Profile_Type = model.Profile_Type,
                Test_ID = model.Test_ID,
                MRP = model.MRP,
                Discount_Pct = model.Profile_Type == 2 ? model.Discount_Pct : 0,
                Effective_Start_Date = model.Profile_Type == 2 ? model.Effective_Start_Date : null,
                Effective_End_Date = model.Profile_Type == 2 ? model.Effective_End_Date : null,
                Age_Operator = model.Age_Operator,
                Applicable_Age = model.Applicable_Age,
                Applicable_Gender = model.Applicable_Gender,
                Profile_TAT_Hours = model.Profile_TAT_Hours,
                Profile_NABL_Accredited = model.Profile_NABL_Accredited,
                Report_Print_Sequence = model.Report_Print_Sequence,
                Status = model.Status,
                UserId = User.GetUserId(),
                Details = details
            };

            await profileApiClient.SaveAsync(req);

            var typeName = model.Profile_Type == 2 ? "Package" : "Profile";
            await auditLogService.LogAsync(
                "Update Lab Investigation Profile",
                "Edit",
                $"Updated Investigation {typeName} #{id} - '{model.Profile_Name}'",
                User.GetUserId(),
                User.GetCurrentBranchId() ?? 1
            );

            TempData["SuccessMessage"] = $"{typeName} '{model.Profile_Name}' updated successfully.";
            return RedirectToAction(nameof(Index));
        }
        catch (InvalidOperationException ex)
        {
            ModelState.AddModelError(string.Empty, ex.Message);
            await PopulateFormOptionsAsync(model);
            return View(model);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Edit Investigation Profile";
            return View("ApiDown");
        }
    }

    [HttpGet]
    public async Task<IActionResult> Details(int id)
    {
        try
        {
            var item = await profileApiClient.GetByIdAsync(id);
            if (item == null)
            {
                TempData["ErrorMessage"] = "Investigation Profile record not found.";
                return RedirectToAction(nameof(Index));
            }

            return View(item);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Investigation Profile Details";
            return View("ApiDown");
        }
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> ToggleStatus(int id, bool status)
    {
        try
        {
            var req = new LabInvestigationProfileToggleStatusRequestModel
            {
                Profile_ID = id,
                Status = status,
                UserId = User.GetUserId()
            };

            await profileApiClient.ToggleStatusAsync(req);

            await auditLogService.LogAsync(
                "Toggle Lab Investigation Profile Status",
                "ToggleStatus",
                $"Toggled status for Profile #{id} to {(status ? "Active" : "Inactive")}",
                User.GetUserId(),
                User.GetCurrentBranchId() ?? 1
            );

            TempData["SuccessMessage"] = "Status updated successfully.";
        }
        catch (Exception ex)
        {
            TempData["ErrorMessage"] = ex.Message;
        }

        return RedirectToAction(nameof(Index));
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Delete(int id)
    {
        try
        {
            await profileApiClient.DeleteAsync(id);

            await auditLogService.LogAsync(
                "Delete Lab Investigation Profile",
                "Delete",
                $"Deleted Lab Profile #{id}",
                User.GetUserId(),
                User.GetCurrentBranchId() ?? 1
            );

            TempData["SuccessMessage"] = "Investigation Profile deleted successfully.";
        }
        catch (Exception ex)
        {
            TempData["ErrorMessage"] = ex.Message;
        }

        return RedirectToAction(nameof(Index));
    }

    private async Task PopulateFormOptionsAsync(LabInvestigationProfileFormViewModel model)
    {
        model.ProfileTypeOptions = GetProfileTypeOptions();
        model.ProfileTestOptions = await GetProfileTestOptionsAsync();
        model.AgeOperatorOptions = GetAgeOperatorOptions();
        model.GenderOptions = GetGenderOptions();
        model.AvailableTestOptions = await GetActiveTestOptionsAsync();
    }

    private async Task<List<SelectListItem>> GetProfileTestOptionsAsync()
    {
        try
        {
            var tests = await investigationApiClient.GetListAsync(status: true);
            return tests
                .Where(t => t.IsProfileTest)
                .Select(t => new SelectListItem
                {
                    Value = t.Test_ID.ToString(),
                    Text = $"{t.Test_Name} ({t.Test_Code}) - ₹{t.MRP:N2}"
                }).ToList();
        }
        catch { return []; }
    }

    private async Task<List<SelectListItem>> GetActiveTestOptionsAsync()
    {
        try
        {
            var tests = await investigationApiClient.GetListAsync(status: true);
            return tests.Select(t => new SelectListItem
            {
                Value = t.Test_ID.ToString(),
                Text = $"{t.Test_Name} ({t.Test_Code}) - ₹{t.MRP:N2}"
            }).ToList();
        }
        catch { return []; }
    }

    private static List<SelectListItem> GetProfileTypeOptions()
    {
        return
        [
            new SelectListItem { Value = "1", Text = "Profile (Fixed Group)" },
            new SelectListItem { Value = "2", Text = "Package (Health Checkup Bundle)" }
        ];
    }

    private static List<SelectListItem> GetAgeOperatorOptions()
    {
        return
        [
            new SelectListItem { Value = "", Text = "-- No Age Limit --" },
            new SelectListItem { Value = "Exact", Text = "= (Exact Age)" },
            new SelectListItem { Value = "GreaterEqual", Text = ">= (Greater than or Equal)" },
            new SelectListItem { Value = "LessEqual", Text = "<= (Less than or Equal)" }
        ];
    }

    private static List<SelectListItem> GetGenderOptions()
    {
        return
        [
            new SelectListItem { Value = "All", Text = "All Genders" },
            new SelectListItem { Value = "Male", Text = "Male Only" },
            new SelectListItem { Value = "Female", Text = "Female Only" }
        ];
    }
}
