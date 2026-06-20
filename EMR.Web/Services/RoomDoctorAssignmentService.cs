using Dapper;
using EMR.Web.Data;
using EMR.Web.Models.ViewModels;

namespace EMR.Web.Services;

public class RoomDoctorAssignmentService(IDbConnectionFactory db) : IRoomDoctorAssignmentService
{
    public async Task<IEnumerable<RoomDoctorAssignmentViewModel>> GetRoomAssignmentsAsync(int branchId)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<RoomDoctorAssignmentViewModel>(@"
            SELECT 
                r.RoomId, 
                r.RoomName, 
                f.FloorName,
                ISNULL(STUFF((
                    SELECT ', ' + d.FullName
                    FROM DoctorRoomMapping drm
                    INNER JOIN DoctorMaster d ON drm.DoctorId = d.DoctorId
                    WHERE drm.RoomId = r.RoomId
                    FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, ''), '') AS AssignedDoctors
            FROM DoctorRoomMaster r
            INNER JOIN FloorMaster f ON f.FloorId = r.FloorId
            WHERE r.BranchId = @branchId AND r.IsActive = 1
            ORDER BY f.FloorName, r.RoomName
        ", new { branchId });
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
}
