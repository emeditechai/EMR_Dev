using Dapper;
using EMR.Web.Data;
using EMR.Web.Models.ViewModels;

namespace EMR.Web.Services;

public class RoomDoctorAssignmentService(IDbConnectionFactory db) : IRoomDoctorAssignmentService
{
    private class RoomDoctorMapResult
    {
        public int RoomId { get; set; }
        public int DoctorId { get; set; }
        public string FullName { get; set; } = string.Empty;
        public string SpecialityName { get; set; } = string.Empty;
    }

    public async Task<IEnumerable<RoomDoctorAssignmentViewModel>> GetRoomAssignmentsAsync(int branchId)
    {
        using var con = db.CreateConnection();
        
        var rooms = (await con.QueryAsync<RoomDoctorAssignmentViewModel>(@"
            SELECT 
                r.RoomId, 
                r.RoomName, 
                f.FloorName
            FROM DoctorRoomMaster r
            INNER JOIN FloorMaster f ON f.FloorId = r.FloorId
            WHERE r.BranchId = @branchId AND r.IsActive = 1
            ORDER BY f.FloorName, r.RoomName
        ", new { branchId })).ToList();

        var mappings = await con.QueryAsync<RoomDoctorMapResult>(@"
            SELECT 
                drm.RoomId, 
                d.DoctorId, 
                d.FullName, 
                s.SpecialityName
            FROM DoctorRoomMapping drm
            INNER JOIN DoctorMaster d ON drm.DoctorId = d.DoctorId
            INNER JOIN DoctorSpecialityMaster s ON s.SpecialityId = d.PrimarySpecialityId
            INNER JOIN DoctorBranchMap dbm ON dbm.DoctorId = d.DoctorId
            WHERE dbm.BranchId = @branchId AND d.IsActive = 1
        ", new { branchId });

        var mappingDict = System.Linq.Enumerable.ToDictionary(
            System.Linq.Enumerable.GroupBy(mappings, m => m.RoomId),
            g => g.Key,
            g => System.Linq.Enumerable.ToList(System.Linq.Enumerable.Select(g, m => new OPDDoctorOptionDto {
                DoctorId = m.DoctorId,
                FullName = m.FullName,
                SpecialityName = m.SpecialityName
            }))
        );

        foreach (var r in rooms)
        {
            if (mappingDict.TryGetValue(r.RoomId, out var docs))
            {
                r.Doctors = docs;
                r.AssignedDoctors = string.Join(", ", System.Linq.Enumerable.Select(docs, d => d.FullName));
            }
        }

        return rooms;
    }

    public async Task<IEnumerable<OPDDoctorOptionDto>> GetOPDDoctorsAsync(int branchId)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<OPDDoctorOptionDto>(@"
            SELECT DISTINCT 
                d.DoctorId, 
                d.FullName, 
                s.SpecialityName
            FROM DoctorMaster d
            INNER JOIN DoctorBranchMap dbm ON dbm.DoctorId = d.DoctorId
            INNER JOIN DoctorDepartmentMap ddm ON ddm.DoctorId = d.DoctorId
            INNER JOIN DepartmentMaster dept ON dept.DeptId = ddm.DeptId
            INNER JOIN DoctorSpecialityMaster s ON s.SpecialityId = d.PrimarySpecialityId
            WHERE dbm.BranchId = @branchId 
              AND d.IsActive = 1
              AND dept.DeptType = 'OPD'
            ORDER BY d.FullName
        ", new { branchId });
    }

    public async Task AssignDoctorAsync(int roomId, int doctorId, int? userId)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync(@"
            DELETE FROM DoctorRoomMapping WHERE DoctorId = @doctorId;
            INSERT INTO DoctorRoomMapping (DoctorId, RoomId, CreatedBy, CreatedDate)
            VALUES (@doctorId, @roomId, @userId, GETDATE());
        ", new { doctorId, roomId, userId });
    }

    public async Task UnassignDoctorAsync(int doctorId)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync(@"
            DELETE FROM DoctorRoomMapping WHERE DoctorId = @doctorId;
        ", new { doctorId });
    }
}
