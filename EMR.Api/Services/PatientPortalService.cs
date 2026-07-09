using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;

namespace EMR.Api.Services;

public class PatientPortalService(IDbConnectionFactory factory) : IPatientPortalService
{
    public async Task<PortalDashboardSummary> GetDashboardSummaryAsync(int patientId)
    {
        var sql = @"
            SELECT 
                COUNT(*) as TotalBookings,
                SUM(CASE WHEN VisitDate >= CAST(GETDATE() AS DATE) THEN 1 ELSE 0 END) as UpcomingBookings,
                (SELECT COUNT(*) FROM EmrPatientConsultation WHERE PatientId = @PatientId) as TotalPrescriptions,
                (SELECT TOP 1 CONVERT(VARCHAR, VisitDate, 106) FROM PatientOPDService WHERE PatientId = @PatientId AND VisitDate <= GETDATE() AND IsActive = 1 ORDER BY VisitDate DESC) as LastVisitDate
            FROM PatientOPDService 
            WHERE PatientId = @PatientId AND IsActive = 1";
            
        using var db = factory.CreateConnection();
        var summary = await db.QueryFirstOrDefaultAsync<PortalDashboardSummary>(sql, new { PatientId = patientId });
        
        return summary ?? new PortalDashboardSummary();
    }

    public async Task<IEnumerable<PortalDependent>> GetDependentsAsync(int patientId)
    {
        // First get the phone number of the current patient
        var sqlPhone = "SELECT PhoneNumber FROM PatientMaster WHERE PatientId = @PatientId";
        using var db = factory.CreateConnection();
        var phone = await db.QueryFirstOrDefaultAsync<string>(sqlPhone, new { PatientId = patientId });
        
        if (string.IsNullOrWhiteSpace(phone))
            return [];

        // Find all other patients with the same phone number
        var sqlDeps = @"
            SELECT 
                p.PatientId,
                p.PatientCode,
                p.FirstName + ' ' + ISNULL(p.MiddleName + ' ', '') + p.LastName as FullName,
                r.RelationName as Relation,
                p.Gender,
                CAST(DATEDIFF(YEAR, p.DateOfBirth, GETDATE()) AS VARCHAR) + ' Yrs' as Age
            FROM PatientMaster p
            LEFT JOIN RelationMaster r ON p.RelationId = r.RelationId
            WHERE p.PhoneNumber = @Phone AND p.PatientId != @PatientId AND p.IsActive = 1";
            
        return await db.QueryAsync<PortalDependent>(sqlDeps, new { Phone = phone, PatientId = patientId });
    }

    public async Task<IEnumerable<PortalVital>> GetVitalsAsync(int patientId)
    {
        var sql = @"
            SELECT 
                PatientVitalId as VitalId,
                RecordedOn as RecordDate,
                BpSystolic,
                BpDiastolic,
                PulseRate as HeartRate,
                Temperature,
                Weight,
                Height,
                Spo2
            FROM PatientVitals
            WHERE PatientId = @PatientId AND IsActive = 1
            ORDER BY RecordedOn DESC";
            
        using var db = factory.CreateConnection();
        return await db.QueryAsync<PortalVital>(sql, new { PatientId = patientId });
    }

    public async Task<IEnumerable<PortalBooking>> GetBookingsAsync(int patientId)
    {
        var sql = @"
            SELECT 
                o.OPDServiceId,
                o.TokenNo,
                o.VisitDate,
                d.FullName as DoctorName,
                dept.SpecialityName as Department,
                o.Status,
                ISNULL(o.TotalAmount, 0) as TotalAmount,
                ISNULL((SELECT TOP 1 ph.PaymentStatus FROM PaymentHeader ph 
                        WHERE ph.ModuleCode = 'OPD' AND ph.ModuleRefId = o.OPDServiceId AND ph.IsActive = 1), 'U') AS PaymentStatus
            FROM PatientOPDService o
            LEFT JOIN DoctorMaster d ON o.ConsultingDoctorId = d.DoctorId
            LEFT JOIN DoctorSpecialityMaster dept ON d.PrimarySpecialityId = dept.SpecialityId
            WHERE o.PatientId = @PatientId AND o.IsActive = 1
            ORDER BY o.VisitDate DESC";
            
        using var db = factory.CreateConnection();
        return await db.QueryAsync<PortalBooking>(sql, new { PatientId = patientId });
    }

    public async Task<IEnumerable<PortalPrescription>> GetPrescriptionsAsync(int patientId)
    {
        var sql = @"
            SELECT 
                e.ConsultationId,
                e.VisitDate as ConsultationDate,
                e.DoctorId,
                d.FullName as DoctorName,
                e.OPDServiceId,
                ISNULL(e.EmrDataJson, '{}') as EmrDataJson
            FROM EmrPatientConsultation e
            LEFT JOIN DoctorMaster d ON e.DoctorId = d.DoctorId
            WHERE e.PatientId = @PatientId
            ORDER BY e.VisitDate DESC";
            
        using var db = factory.CreateConnection();
        return await db.QueryAsync<PortalPrescription>(sql, new { PatientId = patientId });
    }

    public async Task<PortalFullProfile> GetFullProfileAsync(int patientId)
    {
        var sql = @"
            SELECT 
                p.PatientId,
                p.PatientCode,
                p.FirstName + ' ' + ISNULL(p.MiddleName + ' ', '') + p.LastName as FullName,
                UPPER(LEFT(p.FirstName, 1) + ISNULL(LEFT(p.LastName, 1), '')) as Initials,
                p.PhotoPath,
                p.IsActive,
                ISNULL(p.Gender, '--') as Gender,
                CASE WHEN p.DateOfBirth IS NOT NULL THEN CAST(DATEDIFF(YEAR, p.DateOfBirth, GETDATE()) AS VARCHAR) + ' Yrs' ELSE '--' END as Age,
                ISNULL(p.BloodGroup, '--') as BloodGroup,
                
                ISNULL(p.PhoneNumber, '--') as PhoneNumber,
                ISNULL(p.SecondaryPhoneNumber, '--') as SecondaryPhoneNumber,
                ISNULL(p.EmailId, '--') as EmailId,
                FORMAT(p.CreatedDate, 'dd MMM yyyy, HH:mm') as RegistrationDate,
                
                ISNULL(p.Address, '--') as Address,
                ISNULL(am.AreaName, '--') as Area,
                ISNULL(cm.CityName, '--') as City,
                ISNULL(dm.DistrictName, '--') as District,
                ISNULL(sm.StateName, '--') as State,
                ISNULL(cou.CountryName, '--') as Country,
                
                CASE WHEN p.DateOfBirth IS NOT NULL THEN FORMAT(p.DateOfBirth, 'dd MMM yyyy') ELSE '--' END as DateOfBirth,
                ISNULL(p.Salutation, '--') as Salutation,
                ISNULL(rel.ReligionName, '--') as Religion,
                ISNULL(occ.OccupationName, '--') as Occupation,
                ISNULL(mar.StatusName, '--') as MaritalStatus,
                ISNULL(p.GuardianName, '--') + CASE WHEN rlm.RelationName IS NOT NULL THEN ' (' + rlm.RelationName + ')' ELSE '' END as GuardianName,
                ISNULL(idm.IdentificationTypeName, 'Not Provided') + CASE WHEN p.IdentificationNumber IS NOT NULL THEN ' - ' + p.IdentificationNumber ELSE '' END as IdentificationDoc,
                
                ISNULL(NULLIF(p.KnownAllergies, ''), 'No known allergies recorded.') as KnownAllergies,
                ISNULL(NULLIF(p.Remarks, ''), 'No remarks or history recorded.') as Remarks
                
            FROM PatientMaster p
            LEFT JOIN AreaMaster am ON p.AreaId = am.AreaId
            LEFT JOIN CityMaster cm ON p.CityId = cm.CityId
            LEFT JOIN DistrictMaster dm ON p.DistrictId = dm.DistrictId
            LEFT JOIN StateMaster sm ON p.StateId = sm.StateId
            LEFT JOIN CountryMaster cou ON p.CountryId = cou.CountryId
            LEFT JOIN ReligionMaster rel ON p.ReligionId = rel.ReligionId
            LEFT JOIN OccupationMaster occ ON p.OccupationId = occ.OccupationId
            LEFT JOIN MaritalStatusMaster mar ON p.MaritalStatusId = mar.MaritalStatusId
            LEFT JOIN RelationMaster rlm ON p.RelationId = rlm.RelationId
            LEFT JOIN IdentificationTypeMaster idm ON p.IdentificationTypeId = idm.IdentificationTypeId
            WHERE p.PatientId = @PatientId";

        using var db = factory.CreateConnection();
        var profile = await db.QueryFirstOrDefaultAsync<PortalFullProfile>(sql, new { PatientId = patientId });
        return profile ?? new PortalFullProfile();
    }
}
