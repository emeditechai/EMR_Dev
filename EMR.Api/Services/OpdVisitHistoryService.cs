using System.Data;
using System.Globalization;
using System.Text.RegularExpressions;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;

namespace EMR.Api.Services;

public interface IOpdVisitHistoryService
{
    Task<List<OpdVisitActivityDto>> ActivityAsync(int opdServiceId);
    Task<OpdVisitWorkflow> WorkflowAsync(int opdServiceId);
}

/// <summary>
/// OPD Dashboard > visit Audit History (SQLScripts/2304): the visit's activity, and its workflow - booked / billed,
/// registration, payment, token, vitals, then the consultation and / or the services on the bill - each stage with where
/// it stands, when and by whom, worked out from the visit itself (like the LAB bill's workflow). The stages follow the
/// bill: a consultation only, services only (dressing...), or both; the registration service is a stage of its own.
/// </summary>
public class OpdVisitHistoryService(IDbConnectionFactory connectionFactory) : IOpdVisitHistoryService
{
    public async Task<List<OpdVisitActivityDto>> ActivityAsync(int opdServiceId)
    {
        using var db = connectionFactory.CreateConnection();
        return (await db.QueryAsync<OpdVisitActivityDto>("dbo.usp_Api_OpdVisit_ActivityHistory",
            new { OPDServiceId = opdServiceId }, commandType: CommandType.StoredProcedure)).ToList();
    }

    private static string When(DateTime? d) => d?.ToString("dd MMM yyyy, hh:mm tt", CultureInfo.InvariantCulture) ?? "";
    private static string Money(decimal? v) => "₹" + (v ?? 0).ToString("#,##0.00", CultureInfo.GetCultureInfo("en-IN"));

    public async Task<OpdVisitWorkflow> WorkflowAsync(int opdServiceId)
    {
        OpdVisitWorkflowFacts? f;
        List<OpdVisitItem> items;
        OpdVisitRegistrationFacts reg;
        List<OpdVisitCancellation> cancellations;
        using (var db = connectionFactory.CreateConnection())
        {
            using var multi = await db.QueryMultipleAsync("dbo.usp_Api_OpdVisit_WorkflowFacts",
                new { OPDServiceId = opdServiceId }, commandType: CommandType.StoredProcedure);
            f = await multi.ReadFirstOrDefaultAsync<OpdVisitWorkflowFacts>();
            if (f is null) return new OpdVisitWorkflow { Message = "Visit not found." };
            items = (await multi.ReadAsync<OpdVisitItem>()).ToList();
            reg = await multi.ReadFirstOrDefaultAsync<OpdVisitRegistrationFacts>() ?? new OpdVisitRegistrationFacts();
            cancellations = (await multi.ReadAsync<OpdVisitCancellation>()).ToList();
        }
        var activity = await ActivityAsync(opdServiceId);

        var steps = new List<OpdWorkflowStep>();
        void Step(string key, string label, string icon, string state, string detail, DateTime? at = null, string? by = null) =>
            steps.Add(new OpdWorkflowStep { Key = key, Label = label, Icon = icon, State = state, Detail = detail, At = at is null ? null : When(at), By = by });

        // what the visit is for: a consultation, other services (dressing, procedures...), or both - plus the registration
        var consultations = items.Where(i => i.ServiceType.Equals("Consulting", StringComparison.OrdinalIgnoreCase)).ToList();
        var registration = items.FirstOrDefault(i => i.IsRegistration);
        var services = items.Where(i => !i.IsRegistration && !i.ServiceType.Equals("Consulting", StringComparison.OrdinalIgnoreCase)).ToList();
        var hasConsult = consultations.Count > 0;
        var hasServices = services.Count > 0;
        var kind = hasConsult && hasServices ? "MIXED" : hasConsult ? "CONSULT" : "SERVICE";
        var serviceNames = string.Join(", ", services.Select(i => i.ItemName).Distinct());

        var status = f.Status ?? "";
        var completed = status.Equals("Completed", StringComparison.OrdinalIgnoreCase);
        var inProgress = status.Equals("Consulting", StringComparison.OrdinalIgnoreCase);

        // 1. booked / registered and billed - with what the bill is for
        var slot = f.AppointmentTime is TimeSpan t ? " · slot " + DateTime.Today.Add(t).ToString("hh:mm tt", CultureInfo.InvariantCulture) : "";
        var forWhat = string.Join(" + ", new[] { hasConsult ? "Consultation" : null, hasServices ? serviceNames : null }.Where(x => x is not null));
        Step("booked", f.IsBooked ? "Appointment Booked" : "Visit Registered", "bi-calendar-check", "done",
             $"Bill {f.OPDBillNo}" + (forWhat.Length > 0 ? " · " + forWhat : "")
             + (hasConsult && !string.IsNullOrWhiteSpace(f.DoctorName) ? $" · Dr. {f.DoctorName}" : "") + (f.IsBooked ? slot : " · walk-in"),
             f.BookedAt, f.BookedBy);

        // 2. registration (the registration service): on this bill, or an earlier one still in use; no stage when never registered
        if (registration is not null)
        {
            var validTill = reg.ValidityDays is > 0 && f.BookedAt is DateTime b ? b.Date.AddDays(reg.ValidityDays.Value) : (DateTime?)null;
            Step("registration", "Registration", "bi-person-vcard", "done",
                 $"Registration charged {Money(registration.ServiceCharges)} on this bill"
                 + (validTill is null ? "" : $" · valid till {validTill:dd MMM yyyy}"), f.BookedAt, f.BookedBy);
        }
        else if (reg.LastRegisteredAt is DateTime last)
        {
            var validTill = reg.ValidityDays is > 0 ? last.Date.AddDays(reg.ValidityDays.Value) : (DateTime?)null;
            Step("registration", "Registration", "bi-person-vcard", "done",
                 $"Not charged - registered on {last:dd MMM yyyy} (bill {reg.LastRegisteredBillNo})"
                 + (validTill is null ? "" : $", valid till {validTill:dd MMM yyyy}"), last);
        }

        // 3. payment
        var paidAct = activity.FirstOrDefault(a => a.ActionName == "OPD.PaymentReceived");
        if (f.NetAmount is null)
            Step("payment", "Payment", "bi-cash-coin", "pending", "No payment recorded yet");
        else if (f.NetAmount == 0)
            Step("payment", "Payment", "bi-cash-coin", "done", "No charge for this visit", f.BookedAt);
        else if ((f.BalanceDue ?? 0) <= 0)
            Step("payment", "Payment", "bi-cash-coin", "done", "Fully paid " + Money(f.TotalPaid), paidAct?.EventDate ?? f.PaidAt, paidAct?.UserName);
        else if ((f.TotalPaid ?? 0) > 0)
            Step("payment", "Payment", "bi-cash-coin", "current", $"Paid {Money(f.TotalPaid)} of {Money(f.NetAmount)} · due {Money(f.BalanceDue)}", paidAct?.EventDate ?? f.PaidAt, paidAct?.UserName);
        else
            Step("payment", "Payment", "bi-cash-coin", "current", "Payment due " + Money(f.BalanceDue));

        // 4. token
        if (!string.IsNullOrWhiteSpace(f.TokenNo))
            Step("token", "Token Issued", "bi-ticket-perforated", "done", $"Token {f.TokenNo}", f.TokenAt, f.TokenBy);
        else
            Step("token", "Token Issued", "bi-ticket-perforated", "pending", (f.BalanceDue ?? 0) > 0 ? "Issued once the bill is paid" : "Not issued yet");

        // 5. vitals: part of a consultation visit (optional); for services only, shown only when recorded
        if (f.VitalsCount > 0)
            Step("vitals", "Vitals Recorded", "bi-heart-pulse", "done", f.VitalsCount > 1 ? $"{f.VitalsCount} readings" : "BP, pulse, temperature...", f.VitalsAt, f.VitalsBy);
        else if (hasConsult)
        {
            if (inProgress || completed) Step("vitals", "Vitals Recorded", "bi-heart-pulse", "skipped", "Not recorded for this visit");
            else Step("vitals", "Vitals Recorded", "bi-heart-pulse", "pending", "Not recorded yet");
        }

        if (hasConsult)
        {
            // 6a. the consultation with the doctor
            if (f.ConsultStartAt is not null || completed)
                Step("consulting", "In Consultation", "bi-person-video2", "done",
                     (f.IsVideo ? "Video consultation" : "With the doctor") + (string.IsNullOrWhiteSpace(f.DoctorName) ? "" : $" · Dr. {f.DoctorName}"),
                     f.ConsultStartAt ?? f.CompletedAt, f.ConsultStartBy ?? f.CompletedBy);
            else
                Step("consulting", "In Consultation", "bi-person-video2", "pending", string.IsNullOrWhiteSpace(f.TokenNo) ? "After the token" : "Waiting for the doctor");

            var extras = new List<string>();
            if (f.ConsultationSavedAt is not null) extras.Add("Prescription saved");
            if (f.FollowUpDate is not null) extras.Add("Follow-up " + f.FollowUpDate.Value.ToString("dd MMM yyyy", CultureInfo.InvariantCulture));
            if (!string.IsNullOrWhiteSpace(f.ReferredTo)) extras.Add("Referred to Dr. " + f.ReferredTo);
            if (completed)
                Step("completed", "Consultation Completed", "bi-clipboard2-check", "done", extras.Count > 0 ? string.Join(" · ", extras) : "Consultation closed",
                     f.CompletedAt ?? f.ConsultationSavedAt, f.CompletedBy ?? f.ConsultationBy);
            else if (inProgress)
                Step("completed", "Consultation Completed", "bi-clipboard2-check", "current",
                     f.ConsultationSavedAt is not null ? "Notes saved - not closed yet" : "Consultation in progress", f.ConsultationSavedAt, f.ConsultationBy);
            else
                Step("completed", "Consultation Completed", "bi-clipboard2-check", "pending", "After the consultation");

            // 6b. other services on the same bill: given during the visit, done when the visit is closed
            if (hasServices)
                Step("services", "Services Provided", "bi-bandaid", completed ? "done" : "pending",
                     completed ? serviceNames : $"{serviceNames} - during the visit", completed ? f.CompletedAt : null, completed ? f.CompletedBy : null);
        }
        else
        {
            // 6. services only (no doctor consultation): in progress, then done
            var what = hasServices ? serviceNames : "Service";
            if (inProgress || completed)
                Step("service-start", "Service In Progress", "bi-bandaid", "done", what, f.ConsultStartAt ?? f.CompletedAt, f.ConsultStartBy ?? f.CompletedBy);
            else
                Step("service-start", "Service In Progress", "bi-bandaid", "pending", string.IsNullOrWhiteSpace(f.TokenNo) ? "After the token" : "Waiting for the service");
            if (completed)
                Step("service-done", "Service Completed", "bi-check2-square", "done", what + " given", f.CompletedAt, f.CompletedBy);
            else
                Step("service-done", "Service Completed", "bi-check2-square", inProgress ? "current" : "pending", inProgress ? "Service being given" : "After the service");
        }

        // a "current" stage only where the visit really is: before it everything is done, after it pending
        var firstOpen = steps.FindIndex(s => s.State is "pending" or "current");
        if (firstOpen >= 0 && steps[firstOpen].State == "pending") steps[firstOpen].State = "current";

        // changes after billing: every cancellation (from the cancellation record - full or part of the bill) and refund
        static bool IsFull(string? type) => type is not null && (type.Equals("F", StringComparison.OrdinalIgnoreCase) || type.Equals("FULL", StringComparison.OrdinalIgnoreCase));
        var rework = new List<(DateTime At, OpdWorkflowChange C)>();
        foreach (var c in cancellations)
            rework.Add((c.CancellationDate, new OpdWorkflowChange
            {
                At = When(c.CancellationDate), Kind = "cancelled", Title = IsFull(c.CancellationType) ? "Bill cancelled" : "Part of the bill cancelled",
                Detail = string.Join(" · ", new[] { c.CancellationNo, c.CancelledAmount is null ? null : Money(c.CancelledAmount),
                                                    string.IsNullOrWhiteSpace(c.Reason) ? null : "Reason: " + c.Reason }.Where(x => !string.IsNullOrWhiteSpace(x))),
                By = c.CancelledBy
            }));
        foreach (var a in activity.Where(a => a.ActionName == "OPD.BillRefunded"))
            rework.Add((a.EventDate, new OpdWorkflowChange { At = When(a.EventDate), Kind = "refund", Title = "Refund paid", Detail = Reason(a.Description), By = a.UserName }));

        // a cancelled visit: the stages it never reached are stopped, and the cancellation closes the flow
        var full = cancellations.LastOrDefault(c => IsFull(c.CancellationType));
        var cancelled = !f.IsActive || status.Equals("Cancelled", StringComparison.OrdinalIgnoreCase) || full is not null;
        if (cancelled)
        {
            foreach (var s in steps.Where(s => s.State != "done")) { s.State = "skipped"; s.Detail = "Stopped - visit cancelled"; s.At = null; s.By = null; }
            var cx = full ?? cancellations.LastOrDefault();
            Step("cancelled", "Visit Cancelled", "bi-x-octagon", "issue",
                 cx is null ? "The visit was cancelled"
                 : string.Join(" · ", new[] { cx.CancellationNo, cx.CancelledAmount is null ? null : Money(cx.CancelledAmount), string.IsNullOrWhiteSpace(cx.Reason) ? null : "Reason: " + cx.Reason }
                     .Where(x => !string.IsNullOrWhiteSpace(x))),
                 cx?.CancellationDate, cx?.CancelledBy);
        }

        return new OpdVisitWorkflow
        {
            Success = true, Cancelled = cancelled, PatientName = f.PatientName, BillNo = f.OPDBillNo, VisitKind = kind, Steps = steps,
            Rework = rework.OrderBy(r => r.At).Select(r => r.C).ToList()
        };
    }

    /// <summary>"... Cancellation No: CN-.., Amount: ₹500.00, Reason: Wrong doctor." -> the useful part.</summary>
    private static string Reason(string? description)
    {
        if (string.IsNullOrWhiteSpace(description)) return "";
        var no = Regex.Match(description, @"Cancellation No:\s*([^,]+)");
        var amount = Regex.Match(description, @"(?:Amount:\s*|:\s*)(₹[\d,\.]+)");
        var why = Regex.Match(description, @"(?:Reason|Notes):\s*(.+?)\.?\s*$");
        return string.Join(" · ", new[] { no.Success ? no.Groups[1].Value.Trim() : null, amount.Success ? amount.Groups[1].Value : null,
                                          why.Success ? "Reason: " + why.Groups[1].Value.Trim() : null }.Where(x => x is not null));
    }
}
