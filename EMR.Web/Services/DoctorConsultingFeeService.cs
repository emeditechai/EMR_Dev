using Dapper;
using EMR.Web.Data;
using EMR.Web.Models.ViewModels;

namespace EMR.Web.Services;

public class DoctorConsultingFeeService(IDbConnectionFactory db) : IDoctorConsultingFeeService
{
    public async Task<IEnumerable<ConsultingServiceOptionDto>> GetConsultingServicesAsync(int branchId)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<ConsultingServiceOptionDto>(@"
            SELECT ServiceId, ItemCode, ItemName, ItemCharges
            FROM   ServiceMaster
            WHERE  BranchId    = @branchId
              AND  ServiceType = 'Consulting'
              AND  IsActive    = 1
            ORDER BY ItemCode",
            new { branchId });
    }

    public async Task<IEnumerable<ConsultingFeeItemDto>> GetByDoctorAsync(int doctorId, int branchId)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<ConsultingFeeItemDto>(@"
            SELECT m.MappingId, m.ServiceId, s.ItemCode, s.ItemName, s.ItemCharges
            FROM   DoctorConsultingFeeMap m
            INNER JOIN ServiceMaster s ON s.ServiceId = m.ServiceId
            WHERE  m.DoctorId  = @doctorId
              AND  m.BranchId  = @branchId
              AND  m.IsActive  = 1
            ORDER BY s.ItemCode",
            new { doctorId, branchId });
    }

    public async Task AddAsync(int doctorId, int serviceId, int branchId, int? userId)
    {
        using var con = db.CreateConnection();
        // Upsert: re-activate if soft-deleted, otherwise insert
        await con.ExecuteAsync(@"
            IF EXISTS (SELECT 1 FROM DoctorConsultingFeeMap
                       WHERE DoctorId = @doctorId AND ServiceId = @serviceId AND BranchId = @branchId)
                UPDATE DoctorConsultingFeeMap
                SET    IsActive = 1
                WHERE  DoctorId = @doctorId AND ServiceId = @serviceId AND BranchId = @branchId
            ELSE
                INSERT INTO DoctorConsultingFeeMap (DoctorId, ServiceId, BranchId, IsActive, CreatedBy, CreatedDate)
                VALUES (@doctorId, @serviceId, @branchId, 1, @userId, GETDATE())",
            new { doctorId, serviceId, branchId, userId });
    }

    public async Task RemoveAsync(int mappingId, int doctorId, int branchId)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync(@"
            UPDATE DoctorConsultingFeeMap
            SET    IsActive = 0
            WHERE  MappingId = @mappingId
              AND  DoctorId  = @doctorId
              AND  BranchId  = @branchId",
            new { mappingId, doctorId, branchId });
    }
}
