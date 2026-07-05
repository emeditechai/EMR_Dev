using System.Data;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;

namespace EMR.Api.Services;

public class EmrConsultationService(IDbConnectionFactory db) : IEmrConsultationService
{
    public async Task<EmrConsultationResponse?> GetConsultationDataAsync(int opdServiceId, int doctorId)
    {
        using var con = db.CreateConnection();

        // 1. Get Booking Info
        var booking = await con.QueryFirstOrDefaultAsync<EmrBookingInfo>(@"
            SELECT 
                s.OPDBillNo, 
                s.PatientId, 
                m.PatientCode, 
                LTRIM(RTRIM(ISNULL(m.FirstName, '') + ' ' + ISNULL(m.MiddleName + ' ', '') + ISNULL(m.LastName, ''))) AS PatientName, 
                m.Gender, 
                CAST(DATEDIFF(year, m.DateOfBirth, GETDATE()) AS VARCHAR) + ' Yrs' AS Age, 
                m.PhoneNumber AS MobileNumber, 
                CONVERT(varchar, s.VisitDate, 120) AS VisitDate
            FROM PatientOPDService s
            INNER JOIN PatientMaster m ON s.PatientId = m.PatientId
            WHERE s.OPDServiceId = @opdServiceId", 
            new { opdServiceId });

        if (booking == null) return null;

        // 2. Get Booked Consulting Type
        var consultingType = await con.QueryFirstOrDefaultAsync<string>(@"
            SELECT TOP 1 sm.ConsultingType
            FROM PatientOPDServiceItem si
            INNER JOIN ServiceMaster sm ON si.ServiceId = sm.ServiceId
            WHERE si.OPDServiceId = @opdServiceId AND si.IsActive = 1 AND si.ServiceType = 'Consulting'", 
            new { opdServiceId });

        booking.BookedConsultingType = consultingType ?? "Walking";

        // 3. Get Doctor Speciality
        var specialityId = await con.QueryFirstOrDefaultAsync<int?>(
            "SELECT PrimarySpecialityId FROM DoctorMaster WHERE DoctorId = @doctorId AND IsActive = 1",
            new { doctorId });

        if (specialityId == null) return null;

        // 4. Get Template Map
        var template = await con.QueryFirstOrDefaultAsync<EmrTemplateInfo>(@"
            SELECT t.TemplateId, t.TemplateName
            FROM EmrTemplateSpecialityMap m
            INNER JOIN EmrTemplates t ON m.TemplateId = t.TemplateId
            WHERE m.SpecialityId = @specialityId AND m.IsActive = 1 AND t.IsActive = 1", 
            new { specialityId });

        if (template == null) return null;

        // 5. Get Sections
        var sections = (await con.QueryAsync<EmrSectionInfo>(@"
            SELECT SectionId, SectionName
            FROM EmrTemplateSections
            WHERE TemplateId = @templateId AND IsActive = 1
            ORDER BY DisplayOrder", 
            new { templateId = template.TemplateId })).AsList();

        // 6. Get Fields for all sections
        var sectionIds = sections.Select(s => s.SectionId).ToList();
        var allFields = new List<dynamic>();
        
        if (sectionIds.Any())
        {
            allFields = (await con.QueryAsync<dynamic>(@"
                SELECT FieldId, FieldName, FieldType, IsRequired, OptionsJson, SectionId
                FROM EmrTemplateFields
                WHERE SectionId IN @sectionIds AND IsActive = 1
                ORDER BY DisplayOrder", 
                new { sectionIds })).AsList();
        }

        foreach (var sec in sections)
        {
            var secFields = allFields.Where(f => f.SectionId == sec.SectionId).Select(f => {
                var options = new List<string>();
                if (!string.IsNullOrWhiteSpace((string)f.OptionsJson))
                {
                    try {
                        var list = System.Text.Json.JsonSerializer.Deserialize<List<string>>((string)f.OptionsJson);
                        if (list != null) options = list;
                    } catch {}
                }
                return new EmrFieldInfo {
                    FieldId = f.FieldId,
                    FieldName = f.FieldName,
                    FieldType = f.FieldType,
                    IsRequired = f.IsRequired,
                    Options = options,
                    OptionsString = (string?)f.OptionsJson ?? string.Empty
                };
            }).ToList();
            sec.Fields = secFields;
        }

        template.Sections = sections;

        // 7. Get Saved Consultation
        var savedConsultation = await con.QueryFirstOrDefaultAsync<EmrSavedConsultationInfo>(@"
            SELECT ConsultationId, VisitType, ConsultationType, EmrDataJson
            FROM EmrPatientConsultation
            WHERE OPDServiceId = @opdServiceId", 
            new { opdServiceId });

        return new EmrConsultationResponse
        {
            Booking = booking,
            Template = template,
            SavedConsultation = savedConsultation
        };
    }

    public async Task<bool> SaveConsultationAsync(SaveConsultationRequest req)
    {
        using var con = db.CreateConnection();

        var exists = await con.ExecuteScalarAsync<bool>(
            "SELECT CAST(COUNT(1) AS BIT) FROM EmrPatientConsultation WHERE OPDServiceId = @OPDServiceId", 
            new { req.OPDServiceId });

        if (!exists)
        {
            var sql = @"
                INSERT INTO EmrPatientConsultation 
                (OPDServiceId, PatientId, DoctorId, TemplateId, OPDBillNo, PatientCode, PatientName, Gender, Age, MobileNumber, VisitDate, VisitType, ConsultationType, EmrDataJson, CreatedBy, CreatedDate)
                VALUES 
                (@OPDServiceId, @PatientId, @DoctorId, @TemplateId, @OPDBillNo, @PatientCode, @PatientName, @Gender, @Age, @MobileNumber, GETDATE(), @VisitType, @ConsultationType, @EmrDataJson, @RequestedByUserId, GETDATE())";
            
            await con.ExecuteAsync(sql, req);
        }
        else
        {
            var sql = @"
                UPDATE EmrPatientConsultation 
                SET VisitType = @VisitType,
                    ConsultationType = @ConsultationType,
                    EmrDataJson = @EmrDataJson,
                    ModifiedBy = @RequestedByUserId,
                    ModifiedDate = GETDATE()
                WHERE OPDServiceId = @OPDServiceId";
                
            await con.ExecuteAsync(sql, req);
        }

        return true;
    }
}
