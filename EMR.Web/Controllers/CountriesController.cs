using EMR.Web.Extensions;
using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services.Geography;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

[Authorize]
public class CountriesController(ICountryService countryService) : Controller
{
    public async Task<IActionResult> Index()
    {
        var list = await countryService.GetAllAsync();
        return View(list);
    }

    [HttpGet]
    public IActionResult Create() => View(new CountryFormViewModel());

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(CountryFormViewModel model)
    {
        if (await countryService.CodeExistsAsync(model.CountryCode))
            ModelState.AddModelError(nameof(model.CountryCode), "Country Code already exists.");

        if (!ModelState.IsValid) return View(model);

        await countryService.CreateAsync(new CountryMaster
        {
            CountryCode = model.CountryCode.Trim().ToUpper(),
            CountryName = model.CountryName.Trim(),
            Currency = model.Currency?.Trim(),
            IsActive = model.IsActive
        }, User.GetUserId());

        TempData["Success"] = "Country created successfully.";
        return RedirectToAction(nameof(Index));
    }

    [HttpGet]
    public async Task<IActionResult> Edit(int id)
    {
        var entity = await countryService.GetByIdAsync(id);
        if (entity is null) return NotFound();

        return View(new CountryFormViewModel
        {
            CountryId = entity.CountryId,
            CountryCode = entity.CountryCode,
            CountryName = entity.CountryName,
            Currency = entity.Currency,
            IsActive = entity.IsActive
        });
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(CountryFormViewModel model)
    {
        if (await countryService.CodeExistsAsync(model.CountryCode, model.CountryId))
            ModelState.AddModelError(nameof(model.CountryCode), "Country Code already exists.");

        if (!ModelState.IsValid) return View(model);

        await countryService.UpdateAsync(new CountryMaster
        {
            CountryId = model.CountryId,
            CountryCode = model.CountryCode.Trim().ToUpper(),
            CountryName = model.CountryName.Trim(),
            Currency = model.Currency?.Trim(),
            IsActive = model.IsActive
        }, User.GetUserId());

        TempData["Success"] = "Country updated successfully.";
        return RedirectToAction(nameof(Index));
    }

    [HttpGet]
    public async Task<IActionResult> Details(int id)
    {
        var entity = await countryService.GetByIdAsync(id);
        if (entity is null) return NotFound();
        return View(entity);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Delete(int id)
    {
        var deleted = await countryService.DeleteAsync(id);
        TempData[deleted ? "Success" : "Error"] = deleted
            ? "Country deleted successfully."
            : "Cannot delete: States are linked to this Country.";
        return RedirectToAction(nameof(Index));
    }
}
