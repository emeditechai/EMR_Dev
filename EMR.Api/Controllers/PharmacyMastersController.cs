using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

/// <summary>Pharmacy masters and Item Master (SQLScripts/2357). Called by EMR.Web's PharmacyApiClient.</summary>
[ApiController]
[Route("api/pharmacy/masters")]
[Produces("application/json")]
public class PharmacyMastersController(IPharmacyMasterService service) : ControllerBase
{
    [HttpPost("ensure")]
    public async Task<IActionResult> Ensure([FromBody] PhCompanyBranchRequest req)
    {
        await service.EnsureMastersAsync(req.CompanyId, req.BranchId);
        return Ok(ApiResponse.Ok());
    }

    [HttpGet("branch-code/{branchId:int}")]
    public async Task<IActionResult> BranchCode(int branchId) =>
        Ok(ApiResponse<string>.Ok(await service.BranchCodeAsync(branchId)));

    [HttpGet("lookups")]
    public async Task<IActionResult> Lookups([FromQuery] int companyId) =>
        Ok(ApiResponse<Dictionary<string, List<PhOptionDto>>>.Ok(await service.LookupsAsync(companyId)));

    [HttpGet("list/{key}")]
    public async Task<IActionResult> List(string key, [FromQuery] int companyId, [FromQuery] int branchId)
    {
        if (!service.IsKnownMaster(key)) return NotFound(ApiResponse<object>.Fail("Unknown master."));
        return Ok(ApiResponse<List<IDictionary<string, object?>>>.Ok(await service.ListAsync(key, companyId, branchId)));
    }

    [HttpPost("save/{key}")]
    public async Task<IActionResult> Save(string key, [FromBody] PhMasterSaveRequest req)
    {
        if (!service.IsKnownMaster(key)) return NotFound(ApiResponse<object>.Fail("Unknown master."));
        return Ok(ApiResponse<PhSaveResult>.Ok(await service.SaveAsync(key, req)));
    }

    // ── Item Master ────────────────────────────────────────────────────────────────────────────────────
    [HttpGet("items")]
    public async Task<IActionResult> Items([FromQuery] int companyId, [FromQuery] int branchId, [FromQuery] string? search, [FromQuery] int? categoryId,
        [FromQuery] string? schedule, [FromQuery] int? manufacturerId, [FromQuery] bool? active, [FromQuery] int page = 1, [FromQuery] int pageSize = 50) =>
        Ok(ApiResponse<List<PhItemListRowDto>>.Ok(await service.ItemsAsync(companyId, branchId, search, categoryId, schedule, manufacturerId, active, page, pageSize)));

    [HttpGet("items/search")]
    public async Task<IActionResult> SearchItems([FromQuery] int companyId, [FromQuery] string q, [FromQuery] int take = 15) =>
        Ok(ApiResponse<List<PhItemListRowDto>>.Ok(await service.SearchItemsAsync(companyId, q ?? "", take)));

    [HttpGet("items/{itemId:int}/substitutes")]
    public async Task<IActionResult> Substitutes(int itemId, [FromQuery] int companyId) =>
        Ok(ApiResponse<List<PhItemListRowDto>>.Ok(await service.SubstitutesAsync(companyId, itemId)));

    [HttpGet("items/{itemId:int}")]
    public async Task<IActionResult> Item(int itemId, [FromQuery] int companyId, [FromQuery] int branchId)
    {
        var item = await service.ItemAsync(companyId, branchId, itemId);
        return item == null ? NotFound(ApiResponse<object>.Fail("Item not found.")) : Ok(ApiResponse<PhItemDto>.Ok(item));
    }

    [HttpGet("items/counts")]
    public async Task<IActionResult> ItemCounts([FromQuery] int companyId) =>
        Ok(ApiResponse<PhItemCountsDto>.Ok(await service.ItemCountsAsync(companyId)));

    [HttpGet("items/lookups")]
    public async Task<IActionResult> ItemLookups([FromQuery] int companyId) =>
        Ok(ApiResponse<PhItemLookupsDto>.Ok(await service.ItemLookupsAsync(companyId)));

    [HttpPost("items/save")]
    public async Task<IActionResult> SaveItem([FromBody] PhItemSaveRequest req) =>
        Ok(ApiResponse<PhSaveResult>.Ok(await service.SaveItemAsync(req)));
}
