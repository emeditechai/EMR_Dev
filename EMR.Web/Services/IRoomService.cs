using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Services;

public interface IRoomService
{
    Task<IEnumerable<RoomListItemViewModel>> GetAllAsync(
        int? buildingId = null, int? floorId = null, int? wardId = null, 
        string? roomCategory = null, string? roomType = null, 
        int? companyId = null, int? branchId = null);

    Task<RoomMaster?> GetByIdAsync(int id);
    Task<RoomDetailsViewModel?> GetDetailsByIdAsync(int id);
    Task<bool> RoomNumberExistsAsync(string roomNumber, int? excludeId = null, int? companyId = null);
    Task<int> CreateAsync(RoomMaster model, int? userId);
    Task UpdateAsync(RoomMaster model, int? userId);
    Task<bool> DeleteAsync(int id);

    Task<IEnumerable<SelectListItem>> GetBuildingOptionsAsync(int? selectedBuildingId = null);
    Task<IEnumerable<SelectListItem>> GetFloorOptionsAsync(int? buildingId = null, int? selectedFloorId = null);
    Task<IEnumerable<SelectListItem>> GetWardOptionsAsync(int? floorId = null, int? selectedWardId = null);
    Task<IEnumerable<FloorOptionDto>> GetFloorsByBuildingAsync(int buildingId);
    Task<IEnumerable<WardOptionDto>> GetWardsByFloorAsync(int floorId);

    IEnumerable<SelectListItem> GetRoomTypeOptions(string? selectedType = null);
    IEnumerable<SelectListItem> GetRoomCategoryOptions(string? selectedCategory = null);
}
