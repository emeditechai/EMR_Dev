using System;
using System.Linq;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;

var services = new ServiceCollection();
services.AddDbContext<EMR.Web.Data.ApplicationDbContext>(options =>
    options.UseSqlServer("Server=103.178.113.61,1232;Database=Dev_EMR;User Id=sa;Password=Ehospit@lity@#1926;TrustServerCertificate=True"));

var sp = services.BuildServiceProvider();
var db = sp.GetRequiredService<EMR.Web.Data.ApplicationDbContext>();

var consultation = new EMR.Web.Models.Entities.VideoConsultation
{
    OPDServiceId = 34,
    DoctorId = 2,
    PatientId = 1,
    RoomNamePrefix = "P1202609071030",
    GraceTimeMinutes = 15,
    CreatedDate = DateTime.Now,
    CreatedBy = "System",
    Status = "Failed",
    WherebyMeetingId = "ERROR",
    DoctorHostUrl = string.Empty,
    PatientRoomUrl = string.Empty,
    MeetingStartDate = DateTime.UtcNow,
    MeetingEndDate = DateTime.UtcNow,
    ErrorMessage = "Whereby API call failed. Check logs."
};

db.VideoConsultations.Add(consultation);
try {
    db.SaveChanges();
    Console.WriteLine("Saved successfully! ID: " + consultation.ConsultationId);
} catch (Exception ex) {
    Console.WriteLine("Exception: " + ex.ToString());
}
