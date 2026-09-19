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
public class LabReferenceRangesController(
    ILabReferenceRangeApiClient refRangeApiClient,
    ILabUnitApiClient unitApiClient,
    ILabMasterDashboardService dashboardService,
    IAuditLogService auditLogService) : Controller
{
    [HttpGet]
    public async Task<IActionResult> Index(int? testId = null, string? gender = null, bool? status = null, string? search = null)
    {
        var companyId = User.GetCompanyId();

        try
        {
            var items = (await refRangeApiClient.GetListAsync(testId, gender, status, search, companyId)).ToList();
            var numericTests = (await refRangeApiClient.GetNumericTestsAsync(companyId)).ToList();
            var dashboard = await dashboardService.GetDashboardAsync(companyId, "LabReferenceRanges");

            var model = new LabReferenceRangeIndexViewModel
            {
                ReferenceRanges = items,
                SelectedTestId = testId,
                SelectedGender = gender,
                SelectedStatus = status,
                SearchTerm = search,
                Dashboard = dashboard,
                TestOptions = numericTests.Select(t => new SelectListItem
                {
                    Value = t.Test_ID.ToString(),
                    Text = $"{t.Test_Name} ({t.Test_Code})",
                    Selected = testId == t.Test_ID
                }).ToList(),
                GenderOptions = GetGenderOptions(gender),
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
            ViewData["PageName"] = "Lab Reference Range Master";
            return View("ApiDown");
        }
    }

    [HttpGet]
    public async Task<IActionResult> Create()
    {
        var companyId = User.GetCompanyId();
        var model = new LabReferenceRangeFormViewModel
        {
            CompanyId = companyId,
            Age_From = 0,
            Age_To = 100,
            Age_Unit = "Years",
            Gender = "All",
            Pregnancy_Trimester = "Not Applicable",
            Effective_From = DateTime.Today,
            Status = true
        };

        await PopulateDropdownsAsync(model, companyId);
        return View(model);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(LabReferenceRangeFormViewModel model)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? 1;

        if (model.Is_Common_For_All)
        {
            ValidateRanges(model);

            if (!ModelState.IsValid)
            {
                await PopulateDropdownsAsync(model, companyId);
                return View(model);
            }

            try
            {
                var req = new LabReferenceRangeCreateRequestModel
                {
                    CompanyId = companyId,
                    Test_ID = model.Test_ID,
                    Method_ID = model.Method_ID,
                    Unit_ID = model.Unit_ID,
                    Age_From = model.Age_From ?? 0,
                    Age_To = model.Age_To ?? 100,
                    Age_Unit = model.Age_Unit,
                    Gender = model.Gender,
                    Pregnancy_Trimester = string.IsNullOrWhiteSpace(model.Pregnancy_Trimester) ? "Not Applicable" : model.Pregnancy_Trimester,
                    Low_Value = model.Low_Value,
                    High_Value = model.High_Value,
                    Special_Remarks = model.Special_Remarks,
                    Range_Source = model.Range_Source,
                    Effective_From = model.Effective_From,
                    Effective_To = model.Effective_To,
                    Is_Common_For_All = true,
                    Status = true, // Default active on insert
                    UserId = User.GetUserId()
                };

                var newId = await refRangeApiClient.CreateAsync(req);

                await auditLogService.LogAsync(
                    "Create Lab Reference Range",
                    "Create",
                    $"Created Reference Range #{newId} for Test ID #{model.Test_ID} (Common for all)",
                    User.GetUserId(),
                    branchId
                );

                TempData["SuccessMessage"] = "Common Reference Range created successfully.";
                return RedirectToAction(nameof(Index));
            }
            catch (InvalidOperationException ex)
            {
                ModelState.AddModelError(string.Empty, ex.Message);
                await PopulateDropdownsAsync(model, companyId);
                return View(model);
            }
            catch (HttpRequestException)
            {
                ViewData["PageName"] = "Create Reference Range";
                return View("ApiDown");
            }
        }
        else
        {
            // Multi-range Grid Bulk Save mode
            ModelState.Remove(nameof(model.Age_From));
            ModelState.Remove(nameof(model.Age_To));
            ModelState.Remove(nameof(model.Age_Unit));
            ModelState.Remove(nameof(model.Gender));

            if (model.Test_ID <= 0)
                ModelState.AddModelError(nameof(model.Test_ID), "Investigation Test is required.");

            if (model.Unit_ID <= 0)
                ModelState.AddModelError(nameof(model.Unit_ID), "Unit is required.");

            if (string.IsNullOrWhiteSpace(model.RangeItemsJson) || model.RangeItemsJson == "[]")
            {
                ModelState.AddModelError(string.Empty, "Please add at least one reference range bracket to the table.");
            }

            List<LabReferenceRangeGridItemModel>? gridItems = null;
            if (!string.IsNullOrWhiteSpace(model.RangeItemsJson) && model.RangeItemsJson != "[]")
            {
                try
                {
                    gridItems = System.Text.Json.JsonSerializer.Deserialize<List<LabReferenceRangeGridItemModel>>(model.RangeItemsJson, new System.Text.Json.JsonSerializerOptions
                    {
                        PropertyNameCaseInsensitive = true
                    });
                }
                catch
                {
                    ModelState.AddModelError(string.Empty, "Invalid reference range items format.");
                }
            }

            if (gridItems == null || gridItems.Count == 0)
            {
                if (!ModelState.ContainsKey(string.Empty))
                    ModelState.AddModelError(string.Empty, "Please add at least one reference range bracket to the table.");
            }

            if (!ModelState.IsValid)
            {
                await PopulateDropdownsAsync(model, companyId);
                return View(model);
            }

            try
            {
                var bulkReq = new LabReferenceRangeBulkSaveRequestModel
                {
                    CompanyId = companyId,
                    Test_ID = model.Test_ID,
                    Method_ID = model.Method_ID,
                    Unit_ID = model.Unit_ID,
                    Range_Source = model.Range_Source,
                    Effective_From = model.Effective_From,
                    Effective_To = model.Effective_To,
                    Is_Common_For_All = false,
                    UserId = User.GetUserId(),
                    RangeItems = gridItems!
                };

                await refRangeApiClient.BulkSaveAsync(bulkReq);

                await auditLogService.LogAsync(
                    "Bulk Save Lab Reference Ranges",
                    "BulkSave",
                    $"Saved {gridItems!.Count} reference ranges for Test ID #{model.Test_ID}",
                    User.GetUserId(),
                    branchId
                );

                TempData["SuccessMessage"] = $"Successfully saved {gridItems!.Count} reference range(s) for the selected test.";
                return RedirectToAction(nameof(Index));
            }
            catch (InvalidOperationException ex)
            {
                ModelState.AddModelError(string.Empty, ex.Message);
                await PopulateDropdownsAsync(model, companyId);
                return View(model);
            }
            catch (HttpRequestException)
            {
                ViewData["PageName"] = "Create Reference Range";
                return View("ApiDown");
            }
        }
    }

    [HttpGet]
    public async Task<IActionResult> Edit(int id)
    {
        var companyId = User.GetCompanyId();
        try
        {
            var item = await refRangeApiClient.GetByIdAsync(id, companyId);
            if (item == null)
            {
                TempData["ErrorMessage"] = "Reference Range not found.";
                return RedirectToAction(nameof(Index));
            }

            // Fetch all reference ranges configured for this test
            var allTestRanges = (await refRangeApiClient.GetListAsync(testId: item.Test_ID, companyId: companyId)).ToList();
            var gridItems = allTestRanges.Select(r => new LabReferenceRangeGridItemModel
            {
                Age_From = r.Age_From,
                Age_To = r.Age_To,
                Age_Unit = r.Age_Unit,
                Gender = r.Gender,
                Pregnancy_Trimester = r.Pregnancy_Trimester ?? "Not Applicable",
                Low_Value = r.Low_Value,
                High_Value = r.High_Value,
                Special_Remarks = r.Special_Remarks
            }).ToList();

            var model = new LabReferenceRangeFormViewModel
            {
                RefRange_ID = item.RefRange_ID,
                CompanyId = item.CompanyId,
                Test_ID = item.Test_ID,
                Test_Name = item.Test_Name,
                Method_ID = item.Method_ID,
                Method_Name = item.Method_Name,
                Unit_ID = item.Unit_ID,
                Age_From = item.Age_From,
                Age_To = item.Age_To,
                Age_Unit = item.Age_Unit,
                Gender = item.Gender,
                Pregnancy_Trimester = item.Pregnancy_Trimester ?? "Not Applicable",
                Low_Value = item.Low_Value,
                High_Value = item.High_Value,
                Special_Remarks = item.Special_Remarks,
                Range_Source = item.Range_Source,
                Effective_From = item.Effective_From,
                Effective_To = item.Effective_To,
                Is_Common_For_All = item.Is_Common_For_All,
                Status = item.Status,
                RangeItemsJson = System.Text.Json.JsonSerializer.Serialize(gridItems)
            };

            await PopulateDropdownsAsync(model, companyId);
            return View(model);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Edit Reference Range";
            return View("ApiDown");
        }
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(int id, LabReferenceRangeFormViewModel model)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? 1;

        if (id != model.RefRange_ID)
            return BadRequest();

        if (model.Is_Common_For_All)
        {
            ValidateRanges(model);

            if (!ModelState.IsValid)
            {
                await PopulateDropdownsAsync(model, companyId);
                return View(model);
            }

            try
            {
                var req = new LabReferenceRangeUpdateRequestModel
                {
                    RefRange_ID = model.RefRange_ID,
                    CompanyId = companyId,
                    Test_ID = model.Test_ID,
                    Method_ID = model.Method_ID,
                    Unit_ID = model.Unit_ID,
                    Age_From = model.Age_From ?? 0,
                    Age_To = model.Age_To ?? 100,
                    Age_Unit = model.Age_Unit,
                    Gender = model.Gender,
                    Pregnancy_Trimester = string.IsNullOrWhiteSpace(model.Pregnancy_Trimester) ? "Not Applicable" : model.Pregnancy_Trimester,
                    Low_Value = model.Low_Value,
                    High_Value = model.High_Value,
                    Special_Remarks = model.Special_Remarks,
                    Range_Source = model.Range_Source,
                    Effective_From = model.Effective_From,
                    Effective_To = model.Effective_To,
                    Is_Common_For_All = true,
                    Status = model.Status,
                    UserId = User.GetUserId()
                };

                await refRangeApiClient.UpdateAsync(req);

                await auditLogService.LogAsync(
                    "Update Lab Reference Range",
                    "Edit",
                    $"Updated Reference Range #{model.RefRange_ID} for Test ID #{model.Test_ID}",
                    User.GetUserId(),
                    branchId
                );

                TempData["SuccessMessage"] = "Reference Range updated successfully.";
                return RedirectToAction(nameof(Index));
            }
            catch (InvalidOperationException ex)
            {
                ModelState.AddModelError(string.Empty, ex.Message);
                await PopulateDropdownsAsync(model, companyId);
                return View(model);
            }
            catch (HttpRequestException)
            {
                ViewData["PageName"] = "Edit Reference Range";
                return View("ApiDown");
            }
        }
        else
        {
            // Multi-range Grid Bulk Save Mode in Edit
            ModelState.Remove(nameof(model.Age_From));
            ModelState.Remove(nameof(model.Age_To));
            ModelState.Remove(nameof(model.Age_Unit));
            ModelState.Remove(nameof(model.Gender));

            if (model.Test_ID <= 0)
                ModelState.AddModelError(nameof(model.Test_ID), "Investigation Test is required.");

            if (model.Unit_ID <= 0)
                ModelState.AddModelError(nameof(model.Unit_ID), "Unit is required.");

            List<LabReferenceRangeGridItemModel>? gridItems = null;
            if (!string.IsNullOrWhiteSpace(model.RangeItemsJson) && model.RangeItemsJson != "[]")
            {
                try
                {
                    gridItems = System.Text.Json.JsonSerializer.Deserialize<List<LabReferenceRangeGridItemModel>>(model.RangeItemsJson, new System.Text.Json.JsonSerializerOptions
                    {
                        PropertyNameCaseInsensitive = true
                    });
                }
                catch
                {
                    ModelState.AddModelError(string.Empty, "Invalid reference range items format.");
                }
            }

            if (gridItems == null || gridItems.Count == 0)
            {
                ModelState.AddModelError(string.Empty, "Please add at least one reference range bracket to the table.");
            }

            if (!ModelState.IsValid)
            {
                await PopulateDropdownsAsync(model, companyId);
                return View(model);
            }

            try
            {
                var bulkReq = new LabReferenceRangeBulkSaveRequestModel
                {
                    CompanyId = companyId,
                    Test_ID = model.Test_ID,
                    Method_ID = model.Method_ID,
                    Unit_ID = model.Unit_ID,
                    Range_Source = model.Range_Source,
                    Effective_From = model.Effective_From,
                    Effective_To = model.Effective_To,
                    Is_Common_For_All = false,
                    UserId = User.GetUserId(),
                    RangeItems = gridItems!
                };

                await refRangeApiClient.BulkSaveAsync(bulkReq);

                await auditLogService.LogAsync(
                    "Bulk Save Lab Reference Ranges (Edit)",
                    "BulkSave",
                    $"Updated {gridItems!.Count} reference ranges for Test ID #{model.Test_ID}",
                    User.GetUserId(),
                    branchId
                );

                TempData["SuccessMessage"] = $"Successfully updated {gridItems!.Count} reference range bracket(s) for the test.";
                return RedirectToAction(nameof(Index));
            }
            catch (InvalidOperationException ex)
            {
                ModelState.AddModelError(string.Empty, ex.Message);
                await PopulateDropdownsAsync(model, companyId);
                return View(model);
            }
            catch (HttpRequestException)
            {
                ViewData["PageName"] = "Edit Reference Range";
                return View("ApiDown");
            }
        }
    }

    [HttpGet]
    public async Task<IActionResult> Details(int id)
    {
        var companyId = User.GetCompanyId();
        try
        {
            var item = await refRangeApiClient.GetByIdAsync(id, companyId);
            if (item == null)
            {
                TempData["ErrorMessage"] = "Reference Range not found.";
                return RedirectToAction(nameof(Index));
            }

            return View(item);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Reference Range Details";
            return View("ApiDown");
        }
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> ToggleStatus(int id)
    {
        var branchId = User.GetCurrentBranchId() ?? 1;
        var companyId = User.GetCompanyId();
        try
        {
            var req = new LabReferenceRangeToggleStatusRequestModel
            {
                RefRange_ID = id,
                CompanyId = companyId,
                UserId = User.GetUserId()
            };

            await refRangeApiClient.ToggleStatusAsync(req);

            await auditLogService.LogAsync(
                "Toggle Lab Reference Range Status",
                "ToggleStatus",
                $"Toggled status for Reference Range #{id}",
                User.GetUserId(),
                branchId
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
        var branchId = User.GetCurrentBranchId() ?? 1;
        var companyId = User.GetCompanyId();
        try
        {
            await refRangeApiClient.DeleteAsync(id, companyId, User.GetUserId());

            await auditLogService.LogAsync(
                "Delete Lab Reference Range",
                "Delete",
                $"Deleted Reference Range #{id}",
                User.GetUserId(),
                branchId
            );

            TempData["SuccessMessage"] = "Reference Range deleted successfully.";
        }
        catch (Exception ex)
        {
            TempData["ErrorMessage"] = ex.Message;
        }

        return RedirectToAction(nameof(Index));
    }

    [HttpGet]
    public async Task<IActionResult> GetTestDetails(int testId)
    {
        try
        {
            var companyId = User.GetCompanyId();
            var numericTests = await refRangeApiClient.GetNumericTestsAsync(companyId);
            var test = numericTests.FirstOrDefault(t => t.Test_ID == testId);
            if (test == null)
                return NotFound(new { message = "Numeric test not found." });

            return Json(new
            {
                success = true,
                testId = test.Test_ID,
                testName = test.Test_Name,
                testCode = test.Test_Code,
                methodId = test.Method_ID,
                methodName = test.Method_Name ?? "N/A",
                unitId = test.Unit_ID,
                unitName = test.Unit_Name,
                unitSymbol = test.Unit_Symbol,
                gender = test.Applicable_Gender ?? "All"
            });
        }
        catch (Exception ex)
        {
            return StatusCode(500, new { message = ex.Message });
        }
    }

    private void ValidateRanges(LabReferenceRangeFormViewModel model)
    {
        if (model.Age_From < 0)
            ModelState.AddModelError(nameof(model.Age_From), "Age From cannot be negative.");

        if (model.Age_To < 0)
            ModelState.AddModelError(nameof(model.Age_To), "Age To cannot be negative.");

        if (model.Age_From > model.Age_To)
            ModelState.AddModelError(nameof(model.Age_To), "Age To must be greater than or equal to Age From.");

        if (model.Low_Value.HasValue && model.High_Value.HasValue && model.Low_Value.Value > model.High_Value.Value)
            ModelState.AddModelError(nameof(model.High_Value), "High Value must be greater than or equal to Low Value.");

        if (model.Effective_To.HasValue && model.Effective_From > model.Effective_To.Value)
            ModelState.AddModelError(nameof(model.Effective_To), "Effective To must be on or after Effective From.");
    }

    private async Task PopulateDropdownsAsync(LabReferenceRangeFormViewModel model, int companyId)
    {
        try
        {
            var numericTests = (await refRangeApiClient.GetNumericTestsAsync(companyId)).ToList();
            model.TestOptions = numericTests.Select(t => new SelectListItem
            {
                Value = t.Test_ID.ToString(),
                Text = $"{t.Test_Name} ({t.Test_Code})" + (!string.IsNullOrWhiteSpace(t.Method_Name) ? $" - [{t.Method_Name}]" : ""),
                Selected = model.Test_ID == t.Test_ID
            }).ToList();

            var units = (await unitApiClient.GetListAsync(status: true, companyId: companyId)).ToList();
            model.UnitOptions = units.Select(u => new SelectListItem
            {
                Value = u.Unit_ID.ToString(),
                Text = $"{u.Unit_Name} ({u.Unit_Code})" + (!string.IsNullOrWhiteSpace(u.Unit_Symbol) ? $" [{u.Unit_Symbol}]" : ""),
                Selected = model.Unit_ID == u.Unit_ID
            }).ToList();

            model.AgeUnitOptions =
            [
                new() { Value = "Years", Text = "Years", Selected = model.Age_Unit == "Years" },
                new() { Value = "Months", Text = "Months", Selected = model.Age_Unit == "Months" },
                new() { Value = "Days", Text = "Days", Selected = model.Age_Unit == "Days" }
            ];

            model.GenderOptions = GetGenderOptions(model.Gender);

            model.TrimesterOptions =
            [
                new() { Value = "Not Applicable", Text = "Not Applicable", Selected = model.Pregnancy_Trimester == "Not Applicable" },
                new() { Value = "1st Trimester", Text = "1st Trimester", Selected = model.Pregnancy_Trimester == "1st Trimester" },
                new() { Value = "2nd Trimester", Text = "2nd Trimester", Selected = model.Pregnancy_Trimester == "2nd Trimester" },
                new() { Value = "3rd Trimester", Text = "3rd Trimester", Selected = model.Pregnancy_Trimester == "3rd Trimester" }
            ];
        }
        catch
        {
            // Dropdowns will be empty on connection failure
        }
    }

    private static List<SelectListItem> GetGenderOptions(string? selectedGender = null)
    {
        return
        [
            new() { Value = "All", Text = "All Genders", Selected = string.Equals(selectedGender, "All", StringComparison.OrdinalIgnoreCase) || string.IsNullOrEmpty(selectedGender) },
            new() { Value = "Male", Text = "Male", Selected = string.Equals(selectedGender, "Male", StringComparison.OrdinalIgnoreCase) },
            new() { Value = "Female", Text = "Female", Selected = string.Equals(selectedGender, "Female", StringComparison.OrdinalIgnoreCase) },
            new() { Value = "Transgender", Text = "Transgender", Selected = string.Equals(selectedGender, "Transgender", StringComparison.OrdinalIgnoreCase) }
        ];
    }
}
