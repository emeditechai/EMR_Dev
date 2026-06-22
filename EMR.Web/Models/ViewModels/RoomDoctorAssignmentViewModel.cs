using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Models.ViewModels;

public class RoomDoctorAssignmentViewModel
{
    public int RoomId { get; set; }
    public string RoomName { get; set; } = string.Empty;
    public string FloorName { get; set; } = string.Empty;
    public string AssignedDoctors { get; set; } = string.Empty;
    public System.Collections.Generic.List<OPDDoctorOptionDto> Doctors { get; set; } = new();
}

public class RoomDoctorAssignmentPostDto
{
    public int RoomId { get; set; }
    public int DoctorId { get; set; }
}

public class RoomDoctorUnassignPostDto
{
    public int DoctorId { get; set; }
}

public class OPDDoctorOptionDto
{
    public int DoctorId { get; set; }
    public string FullName { get; set; } = string.Empty;
    public string SpecialityName { get; set; } = string.Empty;
}
