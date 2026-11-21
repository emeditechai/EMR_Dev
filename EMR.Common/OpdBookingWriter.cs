using System.Data;
using Dapper;

namespace EMR.Common;

/// <summary>A line of an OPD service booking (a consultation or a service of Service Master).</summary>
public sealed class OpdBookingLine
{
    public string? ServiceType { get; set; }
    public int? ServiceId { get; set; }
    public string? ItemName { get; set; }
    public decimal ServiceCharges { get; set; }
}

/// <summary>
/// OPD > New Service Booking without changing the patient: the OPD bill number, the visit and its lines, left Due. The
/// token is given once the bill is paid (at once for a ₹0 bill). Used by EMR.Web's OPD booking and the patient app (EMR.Api).
/// </summary>
public static class OpdBookingWriter
{
    public static async Task<(string OPDBillNo, string? TokenNo, int NewOPDServiceId)> CreateAsync(IDbConnection con,
        int patientId, int? branchId, int? consultingDoctorId, int? scheduleId, DateTime visitDate, TimeSpan? appointmentTime,
        decimal? headerTotal, IReadOnlyList<OpdBookingLine>? items, int? userId)
    {

        // 1. Get next bill number
        var bp = new DynamicParameters();
        bp.Add("@BranchId", branchId);
        bp.Add("@BillNo",   dbType: DbType.String, size: 50, direction: ParameterDirection.Output);
        await con.ExecuteAsync("dbo.usp_OPD_GetNextBillNo", bp, commandType: CommandType.StoredProcedure);
        var billNo = bp.Get<string>("@BillNo");

        // 2. Token is NOT generated at booking time — it is assigned after full payment.
        //    Exception: zero-amount bills are auto-assigned a token immediately.
        string? tokenNo = null;
        if (headerTotal == 0)
        {
            var tp = new DynamicParameters();
            tp.Add("@BranchId",  branchId);
            tp.Add("@TokenDate", visitDate.Date, dbType: DbType.Date);
            tp.Add("@TokenNo",   dbType: DbType.String, size: 20, direction: ParameterDirection.Output);
            await con.ExecuteAsync("dbo.usp_OPD_GetNextTokenNo", tp, commandType: CommandType.StoredProcedure);
            tokenNo = tp.Get<string>("@TokenNo");
        }

        // 3. Insert OPD service header
        var newSvcId = await con.ExecuteScalarAsync<int>(@"
            INSERT INTO PatientOPDService
                (PatientId, BranchId, ConsultingDoctorId, OPDBillNo, TokenNo,
                 TotalAmount, VisitDate, Status, IsActive, CreatedBy, CreatedDate,
                 ScheduleId, AppointmentTime)
            VALUES
                (@PatientId, @BranchId, @ConsultingDoctorId, @OPDBillNo, @TokenNo,
                 0,
                 -- a booking for a later day is on that day (the doctor's slots and the OPD lists go by VisitDate)
                 CASE WHEN CAST(@VisitDate AS DATE) > CAST(GETDATE() AS DATE) THEN @VisitDate ELSE GETDATE() END,
                 'Registered', 1, @CreatedBy, GETDATE(),
                 @ScheduleId, @AppointmentTime);
            SELECT CAST(SCOPE_IDENTITY() AS INT);",
            new
            {
                PatientId = patientId, BranchId = branchId, ConsultingDoctorId = consultingDoctorId,
                OPDBillNo = billNo, TokenNo = tokenNo,
                CreatedBy = userId,
                ScheduleId = scheduleId, AppointmentTime = appointmentTime,
                VisitDate = visitDate == default ? DateTime.Now : visitDate
            });

        // 4. Insert line items
        {
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
