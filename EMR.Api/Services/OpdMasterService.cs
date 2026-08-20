using System.Data;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;

namespace EMR.Api.Services;

public class OpdMasterService(IDbConnectionFactory db) : IOpdMasterService
{
    private class RoomDoctorMapResult
    {
        public int RoomId { get; set; }
        public int DoctorId { get; set; }
        public string FullName { get; set; } = string.Empty;
        public string SpecialityName { get; set; } = string.Empty;
    }

    public async Task<IEnumerable<ServiceListItem>> GetServicesAsync(int branchId)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<ServiceListItem>(
            "usp_Api_Service_GetList",
            new { BranchId = branchId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<DoctorRoomListItem>> GetDoctorRoomsAsync(int branchId)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<DoctorRoomListItem>(
            "usp_Api_DoctorRoom_GetList",
            new { BranchId = branchId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<RoomDoctorAssignmentListItem>> GetRoomDoctorAssignmentsAsync(int branchId)
    {
        using var con = db.CreateConnection();
        using var multi = await con.QueryMultipleAsync(
            "usp_Api_RoomDoctorAssignment_GetList",
            new { BranchId = branchId },
            commandType: CommandType.StoredProcedure);

        var rooms = (await multi.ReadAsync<RoomDoctorAssignmentListItem>()).ToList();
        var mappings = await multi.ReadAsync<RoomDoctorMapResult>();

        var mappingDict = mappings
            .GroupBy(m => m.RoomId)
            .ToDictionary(
                g => g.Key,
                g => g.Select(x => new OPDDoctorOptionDto
                {
                    DoctorId = x.DoctorId,
                    FullName = x.FullName,
                    SpecialityName = x.SpecialityName
                }).ToList()
            );

        foreach (var room in rooms)
        {
            if (mappingDict.TryGetValue(room.RoomId, out var doctors))
            {
                room.Doctors = doctors;
                room.AssignedDoctors = string.Join(", ", doctors.Select(d => d.FullName));
            }
        }

        return rooms;
    }

    public async Task<IEnumerable<OPDDoctorOptionDto>> GetOPDDoctorsAsync(int branchId)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<OPDDoctorOptionDto>(
            "usp_Api_OPDDoctor_GetList",
            new { BranchId = branchId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<EmrInvestigationListItem>> GetEmrInvestigationsAsync(string? search = null)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<EmrInvestigationListItem>(
            "usp_Api_EmrInvestigation_GetList",
            new { Search = search },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<EmrMedicationListItem>> GetEmrMedicationsAsync(string? search = null)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<EmrMedicationListItem>(
            "usp_Api_EmrMedication_GetList",
            new { Search = search },
            commandType: CommandType.StoredProcedure);
    }
}
