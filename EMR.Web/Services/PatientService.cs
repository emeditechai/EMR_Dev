using System.Data;
using Dapper;
using EMR.Web.Data;
using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;

namespace EMR.Web.Services;

public class PatientService(IDbConnectionFactory db) : IPatientService
{
    // ─── List ─────────────────────────────────────────────────────────────────

    public async Task<IEnumerable<PatientListItemViewModel>> GetListForBranchAsync(int? branchId)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<PatientListItemViewModel>(@"
            SELECT
                p.PatientId,
                p.PatientCode,
                LTRIM(RTRIM(
                    ISNULL(p.Salutation + ' ', '') +
                    p.FirstName + ' ' +
                    ISNULL(p.MiddleName + ' ', '') +
                    p.LastName
                )) AS FullName,
                p.PhoneNumber,
                p.Gender,
                p.BloodGroup,
                p.CreatedDate,
                p.IsActive,
                d.FullName AS ConsultingDoctorName
            FROM PatientMaster p
            OUTER APPLY (
                SELECT TOP 1 ConsultingDoctorId
                FROM PatientOPDService
                WHERE PatientId = p.PatientId AND IsActive = 1
                ORDER BY OPDServiceId DESC
            ) latest
            LEFT JOIN DoctorMaster d ON d.DoctorId = latest.ConsultingDoctorId
            WHERE p.IsActive = 1
              AND (@BranchId IS NULL OR p.BranchId = @BranchId)
            ORDER BY p.CreatedDate DESC",
            new { BranchId = branchId });
    }

    public async Task<PatientPagedListViewModel> GetPagedListAsync(int? branchId, int page, int pageSize, string? search)
    {
        using var con = db.CreateConnection();
        var rows = (await con.QueryAsync<PatientListItemViewModel>(
            "usp_GetPatientListPaged",
            new { BranchId = branchId, PageNumber = page, PageSize = pageSize, SearchTerm = search },
            commandType: System.Data.CommandType.StoredProcedure)).ToList();

        return new PatientPagedListViewModel
        {
            Items      = rows,
            TotalCount = rows.FirstOrDefault()?.TotalCount ?? 0,
            Page       = page,
            PageSize   = pageSize,
            Search     = search
        };
    }

    // ─── Get By ID ────────────────────────────────────────────────────────────

    public async Task<PatientMaster?> GetByIdAsync(int patientId)
    {
        using var con = db.CreateConnection();
        return await con.QuerySingleOrDefaultAsync<PatientMaster>(
            "SELECT * FROM PatientMaster WHERE PatientId = @PatientId",
            new { PatientId = patientId });
    }

    // ─── Quick Search ─────────────────────────────────────────────────────────

    public async Task<IEnumerable<PatientQuickSearchResult>> SearchByPhoneAsync(string phone, int? branchId = null)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<PatientQuickSearchResult>(@"
            SELECT TOP 10
                p.PatientId,
                p.PatientCode,
                LTRIM(RTRIM(
                    ISNULL(p.Salutation + ' ', '') +
                    p.FirstName + ' ' +
                    ISNULL(p.MiddleName + ' ', '') +
                    p.LastName
                )) AS FullName,
                p.PhoneNumber,
                p.SecondaryPhoneNumber,
                p.Gender,
                p.BloodGroup,
                p.DateOfBirth,
                p.Address,
                r.RelationName,
                (SELECT TOP 1 OPDBillNo FROM PatientOPDService
                 WHERE PatientId = p.PatientId ORDER BY CreatedDate DESC) AS LastOpdBillNo
            FROM PatientMaster p
            LEFT JOIN RelationMaster r ON r.RelationId = p.RelationId
            WHERE p.IsActive = 1
              AND (@BranchId IS NULL OR p.BranchId = @BranchId)
              AND (p.PhoneNumber LIKE @Phone OR p.SecondaryPhoneNumber LIKE @Phone)
            ORDER BY p.CreatedDate DESC",
            new { Phone = "%" + phone + "%", BranchId = branchId });
    }

    public async Task<IEnumerable<PatientQuickSearchResult>> SearchByCodeAsync(string code, int? branchId = null)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<PatientQuickSearchResult>(@"
            SELECT TOP 10
                p.PatientId,
                p.PatientCode,
                LTRIM(RTRIM(
                    ISNULL(p.Salutation + ' ', '') +
                    p.FirstName + ' ' +
                    ISNULL(p.MiddleName + ' ', '') +
                    p.LastName
                )) AS FullName,
                p.PhoneNumber,
                p.SecondaryPhoneNumber,
                p.Gender,
                p.BloodGroup,
                p.DateOfBirth,
                p.Address,
                r.RelationName,
                (SELECT TOP 1 OPDBillNo FROM PatientOPDService
                 WHERE PatientId = p.PatientId ORDER BY CreatedDate DESC) AS LastOpdBillNo
            FROM PatientMaster p
            LEFT JOIN RelationMaster r ON r.RelationId = p.RelationId
            WHERE p.IsActive = 1
              AND (@BranchId IS NULL OR p.BranchId = @BranchId)
              AND p.PatientCode LIKE @Code
            ORDER BY p.PatientCode",
            new { Code = "%" + code + "%", BranchId = branchId });
    }

    public async Task<IEnumerable<PatientQuickSearchResult>> SearchByNameAsync(string name, int? branchId = null)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<PatientQuickSearchResult>(@"
            SELECT TOP 10
                p.PatientId,
                p.PatientCode,
                LTRIM(RTRIM(
                    ISNULL(p.Salutation + ' ', '') +
                    p.FirstName + ' ' +
                    ISNULL(p.MiddleName + ' ', '') +
                    p.LastName
                )) AS FullName,
                p.PhoneNumber,
                p.SecondaryPhoneNumber,
                p.Gender,
                p.BloodGroup,
                p.DateOfBirth,
                p.Address,
                r.RelationName,
                (SELECT TOP 1 OPDBillNo FROM PatientOPDService
                 WHERE PatientId = p.PatientId ORDER BY CreatedDate DESC) AS LastOpdBillNo
            FROM PatientMaster p
            LEFT JOIN RelationMaster r ON r.RelationId = p.RelationId
            WHERE p.IsActive = 1
              AND (@BranchId IS NULL OR p.BranchId = @BranchId)
              AND (
                    p.FirstName  LIKE @Name
                 OR p.LastName   LIKE @Name
                 OR LTRIM(RTRIM(p.FirstName + ' ' + ISNULL(p.MiddleName + ' ', '') + p.LastName)) LIKE @Name
              )
            ORDER BY p.FirstName, p.LastName",
            new { Name = "%" + name + "%", BranchId = branchId });
    }

    // ─── Create ───────────────────────────────────────────────────────────────

    public async Task<(string PatientCode, string OPDBillNo, string TokenNo, int NewPatientId, int NewOPDServiceId)>
        CreateAsync(PatientMaster patient, PatientOPDService opdBill, string lineItemsJson, int? userId)
    {
        using var con = db.CreateConnection();

        var p = new DynamicParameters();
        AddPatientParams(p, patient);
        p.Add("@BranchId",           patient.BranchId);
        p.Add("@UserId",             userId);
        p.Add("@ConsultingDoctorId", opdBill.ConsultingDoctorId);
        p.Add("@LineItemsJson",      lineItemsJson);

        // OUTPUT parameters
        p.Add("@PatientCode",     dbType: DbType.String, size: 30, direction: ParameterDirection.Output);
        p.Add("@NewPatientId",    dbType: DbType.Int32,            direction: ParameterDirection.Output);
        p.Add("@NewOPDServiceId", dbType: DbType.Int32,            direction: ParameterDirection.Output);
        p.Add("@OPDBillNo",       dbType: DbType.String, size: 30, direction: ParameterDirection.Output);
        p.Add("@TokenNo",         dbType: DbType.String, size: 20, direction: ParameterDirection.Output);

        await con.ExecuteAsync("dbo.usp_Patient_Create", p, commandType: CommandType.StoredProcedure);

        return (
            p.Get<string>("@PatientCode"),
            p.Get<string>("@OPDBillNo"),
            p.Get<string>("@TokenNo"),
            p.Get<int>("@NewPatientId"),
            p.Get<int>("@NewOPDServiceId")
        );
    }

    // ─── Update ───────────────────────────────────────────────────────────────

    public async Task<(string OPDBillNo, string TokenNo, int NewOPDServiceId)>
        UpdateAsync(PatientMaster patient, PatientOPDService opdBill, string lineItemsJson, int? userId)
    {
        using var con = db.CreateConnection();

        var p = new DynamicParameters();
        p.Add("@PatientId", patient.PatientId);
        AddPatientParams(p, patient);
        p.Add("@UserId",             userId);
        p.Add("@OPDServiceId",       opdBill.OPDServiceId);
        p.Add("@BranchId",           opdBill.BranchId);
        p.Add("@ConsultingDoctorId", opdBill.ConsultingDoctorId);
        p.Add("@LineItemsJson",      lineItemsJson);

        // OUTPUT parameters
        p.Add("@NewOPDServiceId", dbType: DbType.Int32,            direction: ParameterDirection.Output);
        p.Add("@OPDBillNo",       dbType: DbType.String, size: 20, direction: ParameterDirection.Output);
        p.Add("@TokenNo",         dbType: DbType.String, size: 15, direction: ParameterDirection.Output);

        await con.ExecuteAsync("dbo.usp_Patient_Update", p, commandType: CommandType.StoredProcedure);

        return (
            p.Get<string>("@OPDBillNo"),
            p.Get<string>("@TokenNo"),
            p.Get<int>("@NewOPDServiceId")
        );
    }

    // ─── Shared parameter builder ─────────────────────────────────────────────

    private static void AddPatientParams(DynamicParameters p, PatientMaster patient)
    {
        p.Add("@PhoneNumber",            patient.PhoneNumber);
        p.Add("@SecondaryPhoneNumber",   patient.SecondaryPhoneNumber);
        p.Add("@Salutation",             patient.Salutation);
        p.Add("@FirstName",              patient.FirstName);
        p.Add("@MiddleName",             patient.MiddleName);
        p.Add("@LastName",               patient.LastName);
        p.Add("@Gender",                 patient.Gender);
        p.Add("@DateOfBirth",            patient.DateOfBirth);
        p.Add("@ReligionId",             patient.ReligionId);
        p.Add("@EmailId",                patient.EmailId);
        p.Add("@GuardianName",           patient.GuardianName);
        p.Add("@CountryId",              patient.CountryId);
        p.Add("@StateId",                patient.StateId);
        p.Add("@DistrictId",             patient.DistrictId);
        p.Add("@CityId",                 patient.CityId);
        p.Add("@AreaId",                 patient.AreaId);
        p.Add("@Address",                patient.Address);
        p.Add("@RelationId",             patient.RelationId);
        p.Add("@IdentificationTypeId",   patient.IdentificationTypeId);
        p.Add("@IdentificationNumber",   patient.IdentificationNumber);
        p.Add("@IdentificationFilePath", patient.IdentificationFilePath);
        p.Add("@OccupationId",           patient.OccupationId);
        p.Add("@MaritalStatusId",        patient.MaritalStatusId);
        p.Add("@BloodGroup",             patient.BloodGroup);
        p.Add("@KnownAllergies",         patient.KnownAllergies);
        p.Add("@Remarks",                patient.Remarks);
    }

    // ─── Demographics-only Update ────────────────────────────────────

    public async Task UpdateDemographicsAsync(PatientMaster patient, int? userId)
    {
        using var con = db.CreateConnection();
        patient.ModifiedBy   = userId;
        patient.ModifiedDate = DateTime.Now;
        await con.ExecuteAsync(@"
            UPDATE PatientMaster SET
                PhoneNumber            = @PhoneNumber,
                SecondaryPhoneNumber   = @SecondaryPhoneNumber,
                Salutation             = @Salutation,
                FirstName              = @FirstName,
                MiddleName             = @MiddleName,
                LastName               = @LastName,
                Gender                 = @Gender,
                DateOfBirth            = @DateOfBirth,
                ReligionId             = @ReligionId,
                EmailId                = @EmailId,
                GuardianName           = @GuardianName,
                CountryId              = @CountryId,
                StateId                = @StateId,
                DistrictId             = @DistrictId,
                CityId                 = @CityId,
                AreaId                 = @AreaId,
                Address                = @Address,
                RelationId             = @RelationId,
                IdentificationTypeId   = @IdentificationTypeId,
                IdentificationNumber   = @IdentificationNumber,
                IdentificationFilePath = @IdentificationFilePath,
                OccupationId           = @OccupationId,
                MaritalStatusId        = @MaritalStatusId,
                BloodGroup             = @BloodGroup,
                KnownAllergies         = @KnownAllergies,
                Remarks                = @Remarks,
                ModifiedBy             = @ModifiedBy,
                ModifiedDate           = @ModifiedDate
            WHERE PatientId = @PatientId", patient);
    }

    // ─── Delete ───────────────────────────────────────────────────────────────

    public async Task DeleteAsync(int patientId, int? userId)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync(
            "UPDATE PatientMaster SET IsActive=0, ModifiedBy=@UserId, ModifiedDate=SYSUTCDATETIME() WHERE PatientId=@PatientId",
            new { PatientId = patientId, UserId = userId });
    }

    // ─── Latest OPD Service ───────────────────────────────────────────────────

    public async Task<PatientOPDService?> GetLatestOPDServiceAsync(int patientId)
    {
        using var con = db.CreateConnection();
        return await con.QuerySingleOrDefaultAsync<PatientOPDService>(@"
            SELECT TOP 1 *
            FROM PatientOPDService
            WHERE PatientId = @PatientId AND IsActive = 1
            ORDER BY OPDServiceId DESC",
            new { PatientId = patientId });
    }

    // ─── OPD Doctors ─────────────────────────────────────────────────────────

    public async Task<IEnumerable<(int DoctorId, string FullName)>> GetOpdDoctorsAsync(int? branchId)
    {
        using var con = db.CreateConnection();
        var rows = await con.QueryAsync(@"
            SELECT DISTINCT d.DoctorId, d.FullName
            FROM DoctorMaster d
            INNER JOIN DoctorDepartmentMap ddm ON ddm.DoctorId = d.DoctorId AND ddm.IsActive = 1
            INNER JOIN DepartmentMaster    dm  ON dm.DeptId    = ddm.DeptId  AND dm.DeptType = 'OPD' AND dm.IsActive = 1
            WHERE d.IsActive = 1
              AND (@BranchId IS NULL
                   OR d.CreatedBranchId = @BranchId
                   OR EXISTS (
                        SELECT 1 FROM DoctorBranchMap dbm
                        WHERE dbm.DoctorId = d.DoctorId AND dbm.BranchId = @BranchId AND dbm.IsActive = 1))
            ORDER BY d.FullName",
            new { BranchId = branchId });

        return rows.Select(r => ((int)r.DoctorId, (string)r.FullName));
    }

    // ─── Services by Type ─────────────────────────────────────────────────────

    public async Task<IEnumerable<(int ServiceId, string ItemName, decimal ItemCharges)>> GetServicesByTypeAsync(string serviceType, int? branchId)
    {
        using var con = db.CreateConnection();
        var rows = await con.QueryAsync(@"
            SELECT s.ServiceId, s.ItemName, s.ItemCharges
            FROM ServiceMaster s
            WHERE s.IsActive = 1
              AND s.ServiceType = @ServiceType
              AND (@BranchId IS NULL OR s.BranchId = @BranchId)
            ORDER BY s.ItemName",
            new { ServiceType = serviceType, BranchId = branchId });

        return rows.Select(r => ((int)r.ServiceId, (string)r.ItemName, (decimal)r.ItemCharges));
    }

    // ─── Service Booking List ─────────────────────────────────────────────────

    public async Task<IEnumerable<ServiceBookingListItem>> GetServiceBookingsAsync(int? branchId, DateOnly? fromDate, DateOnly? toDate)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<ServiceBookingListItem>(@"
            SELECT
                s.OPDServiceId,
                s.VisitDate,
                s.OPDBillNo,
                s.TokenNo,
                p.PatientCode,
                p.PatientId,
                LTRIM(RTRIM(
                    ISNULL(p.Salutation + ' ', '') +
                    p.FirstName + ' ' +
                    ISNULL(p.MiddleName + ' ', '') +
                    p.LastName
                ))                        AS PatientName,
                p.Gender,
                d.FullName                AS ConsultingDoctorName,
                ISNULL(s.TotalAmount, 0)  AS TotalAmount,
                s.Status,
                ISNULL(
                    STUFF((
                        SELECT DISTINCT ', ' + ISNULL(si.ServiceType, '')
                        FROM PatientOPDServiceItem si
                        WHERE si.OPDServiceId = s.OPDServiceId AND si.IsActive = 1
                        FOR XML PATH(''), TYPE
                    ).value('.','NVARCHAR(MAX)'), 1, 2, ''), ''
                )                         AS ServiceTypesSummary
            FROM PatientOPDService s
            INNER JOIN PatientMaster p ON p.PatientId = s.PatientId
            LEFT  JOIN DoctorMaster  d ON d.DoctorId  = s.ConsultingDoctorId
            WHERE s.IsActive = 1
              AND p.IsActive = 1
              AND (@BranchId IS NULL OR s.BranchId = @BranchId)
              AND (@FromDate IS NULL OR CAST(s.VisitDate AS DATE) >= @FromDate)
              AND (@ToDate   IS NULL OR CAST(s.VisitDate AS DATE) <= @ToDate)
            ORDER BY s.OPDServiceId DESC",
            new { BranchId = branchId,
                  FromDate = fromDate.HasValue ? (DateTime?)fromDate.Value.ToDateTime(TimeOnly.MinValue) : null,
                  ToDate   = toDate.HasValue   ? (DateTime?)toDate.Value.ToDateTime(TimeOnly.MinValue)   : null });
    }

    public async Task<ServiceBookingPagedListViewModel> GetServiceBookingsPagedAsync(
        int? branchId, DateOnly? fromDate, DateOnly? toDate, int page, int pageSize, string? search)
    {
        using var con = db.CreateConnection();
        var rows = (await con.QueryAsync<ServiceBookingListItem>(
            "usp_GetServiceBookingsPaged",
            new
            {
                BranchId   = branchId,
                FromDate   = fromDate.HasValue ? (DateTime?)fromDate.Value.ToDateTime(TimeOnly.MinValue) : null,
                ToDate     = toDate.HasValue   ? (DateTime?)toDate.Value.ToDateTime(TimeOnly.MinValue)   : null,
                PageNumber = page,
                PageSize   = pageSize,
                SearchTerm = search
            },
            commandType: System.Data.CommandType.StoredProcedure)).ToList();

        var first = rows.FirstOrDefault();
        return new ServiceBookingPagedListViewModel
        {
            Items          = rows,
            TotalCount     = first?.TotalCount     ?? 0,
            TotalFeesAll   = first?.TotalFeesAll   ?? 0,
            RegisteredCount= first?.RegisteredCount ?? 0,
            CompletedCount = first?.CompletedCount  ?? 0,
            Page           = page,
            PageSize       = pageSize,
            Search         = search,
            FromDate       = fromDate?.ToString("yyyy-MM-dd"),
            ToDate         = toDate?.ToString("yyyy-MM-dd")
        };
    }

    // ─── Service Booking Detail ───────────────────────────────────────────────

    public async Task<ServiceBookingDetailViewModel?> GetServiceBookingDetailAsync(int opdServiceId)
    {
        using var con = db.CreateConnection();

        var header = await con.QuerySingleOrDefaultAsync<ServiceBookingDetailViewModel>(@"
            SELECT
                s.OPDServiceId,
                s.OPDBillNo,
                s.TokenNo,
                p.PatientCode,
                LTRIM(RTRIM(
                    ISNULL(p.Salutation + ' ', '') +
                    p.FirstName + ' ' +
                    ISNULL(p.MiddleName + ' ', '') +
                    p.LastName
                ))                        AS PatientName,
                p.PhoneNumber,
                p.Gender,
                p.DateOfBirth,
                d.FullName                AS ConsultingDoctorName,
                s.VisitDate,
                ISNULL(s.TotalAmount, 0)  AS TotalAmount,
                s.Status
            FROM PatientOPDService s
            INNER JOIN PatientMaster p ON p.PatientId = s.PatientId
            LEFT  JOIN DoctorMaster  d ON d.DoctorId  = s.ConsultingDoctorId
            WHERE s.OPDServiceId = @OPDServiceId",
            new { OPDServiceId = opdServiceId });

        if (header is null) return null;

        var items = await con.QueryAsync<ServiceBookingDetailItem>(@"
            SELECT
                si.ServiceType,
                ISNULL(sm.ItemName, '(Unknown)')   AS ItemName,
                ISNULL(si.ServiceCharges, 0)        AS ServiceCharges
            FROM PatientOPDServiceItem si
            LEFT JOIN ServiceMaster sm ON sm.ServiceId = si.ServiceId
            WHERE si.OPDServiceId = @OPDServiceId AND si.IsActive = 1
            ORDER BY si.ItemId",
            new { OPDServiceId = opdServiceId });

        header.Items = items.ToList();
        return header;
    }

    // ─── Lookup helpers ───────────────────────────────────────────────────────

    public async Task<string?> GetIdentificationTypeNameAsync(int identificationTypeId)
    {
        using var con = db.CreateConnection();
        return await con.QuerySingleOrDefaultAsync<string>(
            "SELECT IdentificationTypeName FROM IdentificationTypeMaster WHERE IdentificationTypeId = @Id",
            new { Id = identificationTypeId });
    }

    public async Task<(string? ReligionName, string? MaritalStatusName, string? OccupationName,
         string? AreaName, string? CityName, string? DistrictName, string? StateName, string? CountryName)>
        GetDemographicNamesAsync(int patientId)
    {
        using var con = db.CreateConnection();
        var row = await con.QuerySingleOrDefaultAsync(@"
            SELECT
                r.ReligionName,
                ms.StatusName    AS MaritalStatusName,
                oc.OccupationName,
                a.AreaName,
                ci.CityName,
                di.DistrictName,
                st.StateName,
                co.CountryName
            FROM PatientMaster pm
            LEFT JOIN ReligionMaster       r   ON r.ReligionId       = pm.ReligionId
            LEFT JOIN MaritalStatusMaster  ms  ON ms.MaritalStatusId = pm.MaritalStatusId
            LEFT JOIN OccupationMaster     oc  ON oc.OccupationId    = pm.OccupationId
            LEFT JOIN AreaMaster           a   ON a.AreaId           = pm.AreaId
            LEFT JOIN CityMaster           ci  ON ci.CityId          = pm.CityId
            LEFT JOIN DistrictMaster       di  ON di.DistrictId      = pm.DistrictId
            LEFT JOIN StateMaster          st  ON st.StateId         = pm.StateId
            LEFT JOIN CountryMaster        co  ON co.CountryId       = pm.CountryId
            WHERE pm.PatientId = @PatientId",
            new { PatientId = patientId });
        return (
            (string?)row?.ReligionName,
            (string?)row?.MaritalStatusName,
            (string?)row?.OccupationName,
            (string?)row?.AreaName,
            (string?)row?.CityName,
            (string?)row?.DistrictName,
            (string?)row?.StateName,
            (string?)row?.CountryName
        );
    }

    // ─── Service Booking Only (no patient demographics update) ────────────────

    public async Task<(string OPDBillNo, string TokenNo, int NewOPDServiceId)>
        CreateServiceBookingOnlyAsync(PatientOPDService bill, string lineItemsJson, int? userId)
    {
        using var con = db.CreateConnection();

        // 1. Get next bill number
        var bp = new DynamicParameters();
        bp.Add("@BranchId", bill.BranchId);
        bp.Add("@BillNo",   dbType: DbType.String, size: 30, direction: ParameterDirection.Output);
        await con.ExecuteAsync("dbo.usp_OPD_GetNextBillNo", bp, commandType: CommandType.StoredProcedure);
        var billNo = bp.Get<string>("@BillNo");

        // 2. Get next token number
        var tp = new DynamicParameters();
        tp.Add("@BranchId", bill.BranchId);
        tp.Add("@TokenNo",  dbType: DbType.String, size: 20, direction: ParameterDirection.Output);
        await con.ExecuteAsync("dbo.usp_OPD_GetNextTokenNo", tp, commandType: CommandType.StoredProcedure);
        var tokenNo = tp.Get<string>("@TokenNo");

        // 3. Insert OPD service header
        var newSvcId = await con.ExecuteScalarAsync<int>(@"
            INSERT INTO PatientOPDService
                (PatientId, BranchId, ConsultingDoctorId, OPDBillNo, TokenNo,
                 TotalAmount, VisitDate, Status, IsActive, CreatedBy, CreatedDate)
            VALUES
                (@PatientId, @BranchId, @ConsultingDoctorId, @OPDBillNo, @TokenNo,
                 0, GETDATE(), 'Registered', 1, @CreatedBy, GETDATE());
            SELECT CAST(SCOPE_IDENTITY() AS INT);",
            new
            {
                bill.PatientId, bill.BranchId, bill.ConsultingDoctorId,
                OPDBillNo = billNo, TokenNo = tokenNo,
                CreatedBy = userId
            });

        // 4. Parse and insert line items
        if (!string.IsNullOrWhiteSpace(lineItemsJson) && lineItemsJson != "[]")
        {
            var items = System.Text.Json.JsonSerializer.Deserialize<List<OPDServiceLineItem>>(
                lineItemsJson,
                new System.Text.Json.JsonSerializerOptions { PropertyNameCaseInsensitive = true });

            if (items?.Count > 0)
            {
                decimal total = 0;
                foreach (var item in items)
                {
                    await con.ExecuteAsync(@"
                        INSERT INTO PatientOPDServiceItem
                            (OPDServiceId, ServiceType, ServiceId, ServiceCharges,
                             IsActive, CreatedBy, CreatedDate)
                        VALUES
                            (@OPDServiceId, @ServiceType, @ServiceId, @ServiceCharges,
                             1, @CreatedBy, GETDATE())",
                        new
                        {
                            OPDServiceId   = newSvcId,
                            item.ServiceType,
                            item.ServiceId,
                            ServiceCharges = item.ServiceCharges,
                            CreatedBy      = userId
                        });
                    total += item.ServiceCharges;
                }

                await con.ExecuteAsync(
                    "UPDATE PatientOPDService SET TotalAmount = @Total WHERE OPDServiceId = @Id",
                    new { Total = total, Id = newSvcId });
            }
        }

        return (billNo, tokenNo, newSvcId);
    }
}
