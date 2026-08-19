using Dapper;
using EMR.Web.Data;
using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Services;

public class BedRoomTariffService(IDbConnectionFactory db) : IBedRoomTariffService
{
    public async Task<IEnumerable<BedRoomTariffListItemViewModel>> GetAllAsync(
        int? wardId = null, int? roomId = null, int? bedCategoryId = null, 
        int? tariffCategoryId = null, int? companyId = null, int? branchId = null)
    {
        using var con = db.CreateConnection();
        var sql = @"
            SELECT 
                t.BedRateId,
                t.WardId,
                w.WardName,
                w.WardCode,
                t.RoomId,
                r.RoomNumber,
                r.RoomType,
                t.BedCategoryId,
                bc.CategoryName AS BedCategoryName,
                t.TariffCategoryId,
                tc.Name AS TariffCategoryName,
                tc.Code AS TariffCategoryCode,
                tc.PatientCategory,
                t.EffectiveFrom,
                t.EffectiveTo,
                t.RoomCharge,
                t.BedCharge,
                t.NursingCharge,
                t.AttendantCharge,
                t.IsolationCharge,
                t.GstPercentage,
                t.IsActive
            FROM BedRoomTariffMaster t
            INNER JOIN WardMaster w ON t.WardId = w.WardId
            INNER JOIN RoomMaster r ON t.RoomId = r.RoomId
            INNER JOIN BedCategoryMaster bc ON t.BedCategoryId = bc.BedCategoryId
            INNER JOIN TariffCategoryMaster tc ON t.TariffCategoryId = tc.TariffCategoryId
            WHERE (@wardId IS NULL OR t.WardId = @wardId)
              AND (@roomId IS NULL OR t.RoomId = @roomId)
              AND (@bedCategoryId IS NULL OR t.BedCategoryId = @bedCategoryId)
              AND (@tariffCategoryId IS NULL OR t.TariffCategoryId = @tariffCategoryId)
              AND (@companyId IS NULL OR t.CompanyId = @companyId)
              AND (@branchId IS NULL OR t.BranchId = @branchId)
            ORDER BY w.WardName, r.RoomNumber, bc.CategoryName, tc.Name, t.EffectiveFrom DESC";

        return await con.QueryAsync<BedRoomTariffListItemViewModel>(sql, new
        {
            wardId, roomId, bedCategoryId, tariffCategoryId, companyId, branchId
        });
    }

    public async Task<BedRoomTariffMaster?> GetByIdAsync(int id)
    {
        using var con = db.CreateConnection();
        var sql = @"
            SELECT 
                t.BedRateId,
                t.CompanyId,
                t.BranchId,
                t.WardId,
                w.WardName,
                w.WardCode,
                t.RoomId,
                r.RoomNumber,
                r.RoomType,
                t.BedCategoryId,
                bc.CategoryName AS BedCategoryName,
                bc.CategoryCode AS BedCategoryCode,
                t.TariffCategoryId,
                tc.Name AS TariffCategoryName,
                tc.Code AS TariffCategoryCode,
                tc.PatientCategory,
                t.EffectiveFrom,
                t.EffectiveTo,
                t.RoomCharge,
                t.BedCharge,
                t.NursingCharge,
                t.AttendantCharge,
                t.IsolationCharge,
                t.GstPercentage,
                t.IsActive,
                t.CreatedBy,
                t.CreatedDate,
                t.ModifiedBy,
                t.ModifiedDate
            FROM BedRoomTariffMaster t
            INNER JOIN WardMaster w ON t.WardId = w.WardId
            INNER JOIN RoomMaster r ON t.RoomId = r.RoomId
            INNER JOIN BedCategoryMaster bc ON t.BedCategoryId = bc.BedCategoryId
            INNER JOIN TariffCategoryMaster tc ON t.TariffCategoryId = tc.TariffCategoryId
            WHERE t.BedRateId = @id";

        return await con.QueryFirstOrDefaultAsync<BedRoomTariffMaster>(sql, new { id });
    }

    public async Task<BedRoomTariffDetailsViewModel?> GetDetailsByIdAsync(int id)
    {
        using var con = db.CreateConnection();
        var sql = @"
            SELECT 
                t.BedRateId,
                t.CompanyId,
                t.BranchId,
                b.BranchName,
                t.WardId,
                w.WardName,
                w.WardCode,
                t.RoomId,
                r.RoomNumber,
                r.RoomType,
                t.BedCategoryId,
                bc.CategoryName AS BedCategoryName,
                bc.CategoryCode AS BedCategoryCode,
                t.TariffCategoryId,
                tc.Name AS TariffCategoryName,
                tc.Code AS TariffCategoryCode,
                tc.PatientCategory,
                t.EffectiveFrom,
                t.EffectiveTo,
                t.RoomCharge,
                t.BedCharge,
                t.NursingCharge,
                t.AttendantCharge,
                t.IsolationCharge,
                t.GstPercentage,
                t.IsActive,
                t.CreatedDate,
                t.ModifiedDate,
                t.CreatedBy,
                t.ModifiedBy
            FROM BedRoomTariffMaster t
            INNER JOIN WardMaster w ON t.WardId = w.WardId
            INNER JOIN RoomMaster r ON t.RoomId = r.RoomId
            INNER JOIN BedCategoryMaster bc ON t.BedCategoryId = bc.BedCategoryId
            INNER JOIN TariffCategoryMaster tc ON t.TariffCategoryId = tc.TariffCategoryId
            LEFT JOIN Branchmaster b ON t.BranchId = b.BranchID
            WHERE t.BedRateId = @id";

        var details = await con.QueryFirstOrDefaultAsync<BedRoomTariffDetailsViewModel>(sql, new { id });
        if (details != null)
        {
            var history = await GetHistoryByTariffIdAsync(id);
            details.HistoryLogs = history.ToList();
        }
        return details;
    }

    public async Task<IEnumerable<BedRoomTariffHistoryItemViewModel>> GetHistoryByTariffIdAsync(int bedRateId)
    {
        using var con = db.CreateConnection();
        var sql = @"
            SELECT 
                h.HistoryId,
                h.BedRateId,
                h.EffectiveFrom,
                h.EffectiveTo,
                h.RoomCharge,
                h.BedCharge,
                h.NursingCharge,
                h.AttendantCharge,
                h.IsolationCharge,
                h.GstPercentage,
                h.IsActive,
                h.ChangeAction,
                h.ChangeReason,
                COALESCE(u.FullName, u.FirstName + ' ' + u.LastName, u.Username, 'System Admin') AS ChangedByName,
                h.ChangedDate
            FROM BedRoomTariffHistory h
            LEFT JOIN Users u ON h.ChangedBy = u.Id
            WHERE h.BedRateId = @bedRateId
            ORDER BY h.ChangedDate DESC, h.HistoryId DESC";

        return await con.QueryAsync<BedRoomTariffHistoryItemViewModel>(sql, new { bedRateId });
    }

    public async Task<bool> HasOverlappingDatesAsync(
        int branchId, int wardId, int roomId, int bedCategoryId, int tariffCategoryId,
        DateTime effectiveFrom, DateTime? effectiveTo, int? excludeId = null)
    {
        using var con = db.CreateConnection();
        var sql = @"
            SELECT COUNT(1) 
            FROM BedRoomTariffMaster
            WHERE BranchId = @branchId
              AND WardId = @wardId
              AND RoomId = @roomId
              AND BedCategoryId = @bedCategoryId
              AND TariffCategoryId = @tariffCategoryId
              AND (@excludeId IS NULL OR BedRateId <> @excludeId)
              AND (
                  (@effectiveTo IS NULL AND (EffectiveTo IS NULL OR EffectiveTo >= @effectiveFrom))
                  OR
                  (@effectiveTo IS NOT NULL AND EffectiveFrom <= @effectiveTo AND (EffectiveTo IS NULL OR EffectiveTo >= @effectiveFrom))
              )";

        var count = await con.ExecuteScalarAsync<int>(sql, new
        {
            branchId,
            wardId,
            roomId,
            bedCategoryId,
            tariffCategoryId,
            effectiveFrom = effectiveFrom.Date,
            effectiveTo = effectiveTo?.Date,
            excludeId
        });

        return count > 0;
    }

    public async Task<int> CreateAsync(BedRoomTariffMaster model, int? userId, string? changeReason = null)
    {
        using var con = db.CreateConnection();
        var sql = @"
            INSERT INTO BedRoomTariffMaster (
                CompanyId, BranchId, WardId, RoomId, BedCategoryId, TariffCategoryId,
                EffectiveFrom, EffectiveTo, RoomCharge, BedCharge, NursingCharge,
                AttendantCharge, IsolationCharge, GstPercentage, IsActive,
                CreatedBy, CreatedDate
            ) VALUES (
                @CompanyId, @BranchId, @WardId, @RoomId, @BedCategoryId, @TariffCategoryId,
                @EffectiveFrom, @EffectiveTo, @RoomCharge, @BedCharge, @NursingCharge,
                @AttendantCharge, @IsolationCharge, @GstPercentage, @IsActive,
                @userId, GETDATE()
            );
            SELECT SCOPE_IDENTITY();";

        var newId = await con.ExecuteScalarAsync<int>(sql, new
        {
            model.CompanyId,
            model.BranchId,
            model.WardId,
            model.RoomId,
            model.BedCategoryId,
            model.TariffCategoryId,
            model.EffectiveFrom,
            model.EffectiveTo,
            model.RoomCharge,
            model.BedCharge,
            model.NursingCharge,
            model.AttendantCharge,
            model.IsolationCharge,
            model.GstPercentage,
            model.IsActive,
            userId
        });

        // Insert initial history record
        var histSql = @"
            INSERT INTO BedRoomTariffHistory (
                BedRateId, CompanyId, BranchId, WardId, RoomId, BedCategoryId, TariffCategoryId,
                EffectiveFrom, EffectiveTo, RoomCharge, BedCharge, NursingCharge,
                AttendantCharge, IsolationCharge, GstPercentage, IsActive,
                ChangeAction, ChangeReason, ChangedBy, ChangedDate
            ) VALUES (
                @newId, @CompanyId, @BranchId, @WardId, @RoomId, @BedCategoryId, @TariffCategoryId,
                @EffectiveFrom, @EffectiveTo, @RoomCharge, @BedCharge, @NursingCharge,
                @AttendantCharge, @IsolationCharge, @GstPercentage, @IsActive,
                'CREATED', @changeReason, @userId, GETDATE()
            );";

        await con.ExecuteAsync(histSql, new
        {
            newId,
            model.CompanyId,
            model.BranchId,
            model.WardId,
            model.RoomId,
            model.BedCategoryId,
            model.TariffCategoryId,
            model.EffectiveFrom,
            model.EffectiveTo,
            model.RoomCharge,
            model.BedCharge,
            model.NursingCharge,
            model.AttendantCharge,
            model.IsolationCharge,
            model.GstPercentage,
            model.IsActive,
            changeReason = string.IsNullOrWhiteSpace(changeReason) ? "Initial tariff rate creation" : changeReason,
            userId
        });

        return newId;
    }

    public async Task UpdateAsync(BedRoomTariffMaster model, int? userId, string? changeReason = null)
    {
        using var con = db.CreateConnection();
        var sql = @"
            UPDATE BedRoomTariffMaster SET
                WardId           = @WardId,
                RoomId           = @RoomId,
                BedCategoryId    = @BedCategoryId,
                TariffCategoryId = @TariffCategoryId,
                EffectiveFrom    = @EffectiveFrom,
                EffectiveTo      = @EffectiveTo,
                RoomCharge       = @RoomCharge,
                BedCharge        = @BedCharge,
                NursingCharge    = @NursingCharge,
                AttendantCharge  = @AttendantCharge,
                IsolationCharge  = @IsolationCharge,
                GstPercentage    = @GstPercentage,
                IsActive         = @IsActive,
                ModifiedBy       = @userId,
                ModifiedDate     = GETDATE()
            WHERE BedRateId = @BedRateId";

        await con.ExecuteAsync(sql, new
        {
            model.WardId,
            model.RoomId,
            model.BedCategoryId,
            model.TariffCategoryId,
            model.EffectiveFrom,
            model.EffectiveTo,
            model.RoomCharge,
            model.BedCharge,
            model.NursingCharge,
            model.AttendantCharge,
            model.IsolationCharge,
            model.GstPercentage,
            model.IsActive,
            userId,
            model.BedRateId
        });

        // Add history log of the updated revision
        var histSql = @"
            INSERT INTO BedRoomTariffHistory (
                BedRateId, CompanyId, BranchId, WardId, RoomId, BedCategoryId, TariffCategoryId,
                EffectiveFrom, EffectiveTo, RoomCharge, BedCharge, NursingCharge,
                AttendantCharge, IsolationCharge, GstPercentage, IsActive,
                ChangeAction, ChangeReason, ChangedBy, ChangedDate
            ) VALUES (
                @BedRateId, @CompanyId, @BranchId, @WardId, @RoomId, @BedCategoryId, @TariffCategoryId,
                @EffectiveFrom, @EffectiveTo, @RoomCharge, @BedCharge, @NursingCharge,
                @AttendantCharge, @IsolationCharge, @GstPercentage, @IsActive,
                'UPDATED', @changeReason, @userId, GETDATE()
            );";

        await con.ExecuteAsync(histSql, new
        {
            model.BedRateId,
            model.CompanyId,
            model.BranchId,
            model.WardId,
            model.RoomId,
            model.BedCategoryId,
            model.TariffCategoryId,
            model.EffectiveFrom,
            model.EffectiveTo,
            model.RoomCharge,
            model.BedCharge,
            model.NursingCharge,
            model.AttendantCharge,
            model.IsolationCharge,
            model.GstPercentage,
            model.IsActive,
            changeReason = string.IsNullOrWhiteSpace(changeReason) ? "Tariff rate modified" : changeReason,
            userId
        });
    }

    public async Task<bool> DeleteAsync(int id, int? userId)
    {
        using var con = db.CreateConnection();
        var rows = await con.ExecuteAsync("DELETE FROM BedRoomTariffMaster WHERE BedRateId = @id", new { id });
        return rows > 0;
    }

    public async Task<IEnumerable<SelectListItem>> GetWardOptionsAsync(int? selectedWardId = null)
    {
        using var con = db.CreateConnection();
        var list = await con.QueryAsync<WardMaster>(@"
            SELECT WardId, WardCode, WardName, WardType 
            FROM WardMaster 
            WHERE IsActive = 1 
            ORDER BY WardName");

        return list.Select(w => new SelectListItem
        {
            Value = w.WardId.ToString(),
            Text = $"{w.WardName} ({w.WardCode}) - {w.WardType}",
            Selected = selectedWardId.HasValue && w.WardId == selectedWardId.Value
        });
    }

    public async Task<IEnumerable<SelectListItem>> GetRoomOptionsAsync(int? wardId = null, int? selectedRoomId = null)
    {
        using var con = db.CreateConnection();
        var sql = @"
            SELECT RoomId, RoomNumber, RoomType, RoomCategory 
            FROM RoomMaster 
            WHERE IsActive = 1 
              AND (@wardId IS NULL OR WardId = @wardId)
            ORDER BY RoomNumber";

        var list = await con.QueryAsync<dynamic>(sql, new { wardId });
        return list.Select(r => new SelectListItem
        {
            Value = ((int)r.RoomId).ToString(),
            Text = $"Room {r.RoomNumber} ({r.RoomType} - {r.RoomCategory})",
            Selected = selectedRoomId.HasValue && (int)r.RoomId == selectedRoomId.Value
        });
    }

    public async Task<IEnumerable<SelectListItem>> GetBedCategoryOptionsAsync(int? selectedCategoryId = null)
    {
        using var con = db.CreateConnection();
        var list = await con.QueryAsync<BedCategoryMaster>(@"
            SELECT BedCategoryId, CategoryCode, CategoryName 
            FROM BedCategoryMaster 
            WHERE IsActive = 1 
            ORDER BY CategoryName");

        return list.Select(c => new SelectListItem
        {
            Value = c.BedCategoryId.ToString(),
            Text = string.IsNullOrWhiteSpace(c.CategoryCode)
                ? c.CategoryName
                : $"{c.CategoryName} ({c.CategoryCode})",
            Selected = selectedCategoryId.HasValue && c.BedCategoryId == selectedCategoryId.Value
        });
    }

    public async Task<IEnumerable<SelectListItem>> GetTariffCategoryOptionsAsync(int? selectedTariffId = null)
    {
        using var con = db.CreateConnection();
        var list = await con.QueryAsync<TariffCategoryMaster>(@"
            SELECT TariffCategoryId, Code, Name, PatientCategory 
            FROM TariffCategoryMaster 
            WHERE IsActive = 1 
            ORDER BY Code, Name");

        return list.Select(t => new SelectListItem
        {
            Value = t.TariffCategoryId.ToString(),
            Text = $"{t.Name} ({t.Code}) - {t.PatientCategory}",
            Selected = selectedTariffId.HasValue && t.TariffCategoryId == selectedTariffId.Value
        });
    }
}
