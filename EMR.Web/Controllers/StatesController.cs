using EMR.Web.Extensions;
using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services.Geography;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Controllers;

[Authorize]
public class StatesController(IStateService stateService, ICountryService countryService) : Controller
{
    public async Task<IActionResult> Index()
    {
        var list = await stateService.GetAllAsync();
        return View(list);
    }

    [HttpGet]
    public async Task<IActionResult> Create()
    {
        return View(new StateFormViewModel
        {
            Countries = await GetCountryList()
        });
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(StateFormViewModel model)
    {
        if (await stateService.CodeExistsAsync(model.StateCode))
            ModelState.AddModelError(nameof(model.StateCode), "State Code already exists.");

        if (!ModelState.IsValid)
        {
            model.Countries = await GetCountryList(model.CountryId);
            return View(model);
        }

        await stateService.CreateAsync(new StateMaster
        {
            StateCode = model.StateCode.Trim().ToUpper(),
            StateName = model.StateName.Trim(),
            CountryId = model.CountryId,
            IsActive = model.IsActive
        }, User.GetUserId());

        TempData["Success"] = "State created successfully.";
        return RedirectToAction(nameof(Index));
    }

    [HttpGet]
    public async Task<IActionResult> Edit(int id)
    {
        var entity = await stateService.GetByIdAsync(id);
        if (entity is null) return NotFound();

        return View(new StateFormViewModel
        {
            StateId = entity.StateId,
            StateCode = entity.StateCode,
            StateName = entity.StateName,
            CountryId = entity.CountryId,
            IsActive = entity.IsActive,
            Countries = await GetCountryList(entity.CountryId)
        });
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(StateFormViewModel model)
    {
        if (await stateService.CodeExistsAsync(model.StateCode, model.StateId))
            ModelState.AddModelError(nameof(model.StateCode), "State Code already exists.");

        if (!ModelState.IsValid)
        {
            model.Countries = await GetCountryList(model.CountryId);
            return View(model);
        }

        await stateService.UpdateAsync(new StateMaster
        {
            StateId = model.StateId,
            StateCode = model.StateCode.Trim().ToUpper(),
            StateName = model.StateName.Trim(),
            CountryId = model.CountryId,
            IsActive = model.IsActive
        }, User.GetUserId());

        TempData["Success"] = "State updated successfully.";
        return RedirectToAction(nameof(Index));
    }

    [HttpGet]
    public async Task<IActionResult> Details(int id)
    {
        var entity = await stateService.GetByIdAsync(id);
        if (entity is null) return NotFound();
        return View(entity);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Delete(int id)
    {
        var deleted = await stateService.DeleteAsync(id);
        TempData[deleted ? "Success" : "Error"] = deleted
            ? "State deleted successfully."
            : "Cannot delete: Districts are linked to this State.";
        return RedirectToAction(nameof(Index));
    }

    // AJAX: returns states by country
    [HttpGet]
    public async Task<IActionResult> GetByCountry(int countryId)
    {
        var states = await stateService.GetByCountryAsync(countryId);
        return Json(states.Select(s => new { s.StateId, s.StateName }));
    }

    private async Task<IEnumerable<SelectListItem>> GetCountryList(int? selected = null)
    {
        var countries = await countryService.GetActiveAsync();
        return countries.Select(c => new SelectListItem(c.CountryName, c.CountryId.ToString(),
            c.CountryId == selected));
    }
}
