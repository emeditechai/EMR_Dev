namespace EMR.Common;

/// <summary>
/// A LAB bill's workflow, from booking to report delivery (the Audit History modal, SQLScripts/2297): shown to staff by
/// EMR.Web (LabReporting/GetOrderWorkflowJson) and to the patient by the patient portal and the patient app, without
/// staff names. Read-only.
/// </summary>
public static class LabOrderWorkflow
{
    private sealed class WorkflowFacts
    {
        public DateTime OrderDate { get; set; }
        public bool IsB2B { get; set; }
        public bool IsActive { get; set; }
        public string? BookedBy { get; set; }
        public decimal? NetAmount { get; set; }
        public decimal? TotalPaid { get; set; }
        public decimal? BalanceDue { get; set; }
        public DateTime? PaidAt { get; set; }
        public int Total { get; set; }
        public int Collected { get; set; }
        public int ReCollect { get; set; }
        public int Rejected { get; set; }
        public int Outsourced { get; set; }
        public DateTime? LastCollected { get; set; }
        public int Transferred { get; set; }
        public int Received { get; set; }
        public DateTime? LastTransferred { get; set; }
        public DateTime? LastReceived { get; set; }
        public int Entered { get; set; }
        public int Validated { get; set; }
        public int Approved { get; set; }
        public DateTime? LastEntered { get; set; }
        public DateTime? LastValidated { get; set; }
        public DateTime? LastApproved { get; set; }
        public DateTime? EmailedAt { get; set; }
        public DateTime? WhatsAppAt { get; set; }
    }

    public static async Task<object> BuildAsync(System.Data.Common.DbConnection con, int labOrderId)
    {
        try
        {
            using var multi = await Dapper.SqlMapper.QueryMultipleAsync(con, @"
                SELECT lo.OrderDate, CAST(ISNULL(lo.IsB2B, 0) AS BIT) AS IsB2B, CAST(ISNULL(lo.IsActive, 1) AS BIT) AS IsActive,
                       (SELECT COALESCE(NULLIF(u.FullName, ''), u.Username) FROM dbo.Users u WHERE u.Id = lo.CreatedBy) AS BookedBy,
                       ph.NetAmount, ph.TotalPaid, ph.BalanceDue, COALESCE(ph.LastModifiedDate, ph.CreatedDate) AS PaidAt,
                       s.Total, s.Collected, s.ReCollect, s.Rejected, s.Outsourced, s.LastCollected,
                       s.Transferred, s.Received, s.LastTransferred, s.LastReceived,
                       e.Entered, e.Validated, e.Approved, e.LastEntered, e.LastValidated, e.LastApproved,
                       (SELECT MAX(SentDate) FROM dbo.LabReportEmailLog m WHERE m.LabOrderId = lo.LabOrderId AND m.SentDate IS NOT NULL) AS EmailedAt,
                       (SELECT MAX(SentDate) FROM dbo.LabReportWhatsAppLog w WHERE w.LabOrderId = lo.LabOrderId AND w.SentDate IS NOT NULL) AS WhatsAppAt
                  FROM dbo.LabOrder lo
                 OUTER APPLY (SELECT TOP 1 h.NetAmount, h.TotalPaid, h.BalanceDue, h.LastModifiedDate, h.CreatedDate
                                FROM dbo.PaymentHeader h
                               WHERE h.ModuleCode = 'LAB' AND h.ModuleRefId = lo.LabOrderId AND ISNULL(h.IsActive, 1) = 1
                               ORDER BY h.PaymentHeaderId DESC) ph
                 OUTER APPLY (SELECT COUNT(*) AS Total,
                                     SUM(CASE WHEN sc.CollectionstatusID = 2 THEN 1 ELSE 0 END) AS Collected,
                                     SUM(CASE WHEN sc.CollectionstatusID = 3 THEN 1 ELSE 0 END) AS ReCollect,
                                     SUM(CASE WHEN sc.CollectionstatusID = 4 THEN 1 ELSE 0 END) AS Rejected,
                                     SUM(CASE WHEN ISNULL(sc.IsoutSource, 0) = 1 THEN 1 ELSE 0 END) AS Outsourced,
                                     MAX(CASE WHEN sc.CollectionstatusID = 2 AND sc.Samplecollectiondate IS NOT NULL
                                              THEN CAST(CAST(sc.Samplecollectiondate AS DATE) AS DATETIME) + CAST(ISNULL(sc.Samplecollectiontime, '00:00') AS DATETIME) END) AS LastCollected,
                                     SUM(CASE WHEN ISNULL(sc.IsTransferred, 0) = 1 THEN 1 ELSE 0 END) AS Transferred,
                                     SUM(CASE WHEN ISNULL(sc.IsTransferred, 0) = 1 AND ISNULL(sc.IsReceived, 0) = 1 THEN 1 ELSE 0 END) AS Received,
                                     MAX(sc.TransferredDate) AS LastTransferred, MAX(sc.ReceivedDate) AS LastReceived
                                FROM dbo.samplecollection sc
                               WHERE sc.Laborderid = lo.LabOrderId AND ISNULL(sc.Is_Active, 1) = 1
                                 AND (ISNULL(sc.Iscancelled, 0) = 0 OR ISNULL(lo.IsActive, 1) = 0)) s
                 OUTER APPLY (SELECT SUM(CASE WHEN x.ReportStatusId IN (2, 3, 5) AND x.HasResult = 1 THEN 1 ELSE 0 END) AS Entered,
                                     SUM(CASE WHEN x.ReportStatusId IN (3, 5) THEN 1 ELSE 0 END) AS Validated,
                                     SUM(CASE WHEN x.ReportStatusId = 5 THEN 1 ELSE 0 END) AS Approved,
                                     MAX(x.Submitted_Date) AS LastEntered, MAX(x.Validated_date) AS LastValidated, MAX(x.Approved_Date) AS LastApproved
                                FROM dbo.samplecollection sc
                               CROSS APPLY (SELECT TOP 1 l.ReportStatusId, l.Submitted_Date, l.Validated_date, l.Approved_Date,
                                                   CASE WHEN LTRIM(RTRIM(ISNULL(l.TestValue, ''))) <> '' OR LTRIM(RTRIM(ISNULL(l.Template_Html, ''))) <> '' THEN 1 ELSE 0 END AS HasResult
                                              FROM dbo.labentrydetails l
                                             WHERE l.SamplecollectionID = sc.samplecollectionID AND l.IsActive = 1
                                             ORDER BY l.LabEntryDetailId DESC) x
                               WHERE sc.Laborderid = lo.LabOrderId AND ISNULL(sc.Is_Active, 1) = 1
                                 AND (ISNULL(sc.Iscancelled, 0) = 0 OR ISNULL(lo.IsActive, 1) = 0)) e
                 WHERE lo.LabOrderId = @labOrderId;

                SELECT a.ActionName, a.CreatedDate, COALESCE(NULLIF(u.FullName, ''), u.Username) AS UserName, a.Description
                  FROM dbo.AuditLogs a
                  LEFT JOIN dbo.Users u ON u.Id = a.UserId
                 WHERE a.ReferenceId = @labOrderId AND a.ModuleCode = 'LAB'
                   AND a.ActionName IN ('LAB.OrderBooked', 'LAB.B2BOrderBooked', 'LAB.PaymentReceived', 'LAB.SampleCollected',
                                        'LAB.AllSamplesCollected', 'LAB.ProfileSamplesCollected', 'LAB.ReportEntryCompleted',
                                        'LAB.ReportValidated', 'LAB.ReportApproved', 'LAB.ReportPrinted', 'LAB.BillCancelled')
                 ORDER BY a.CreatedDate DESC;

                -- rework: approvals withdrawn (Re-Test / Re-Collect, with reason)
                SELECT a.CreatedDate, COALESCE(NULLIF(u.FullName, ''), u.Username) AS UserName, a.MetadataJson, a.Description
                  FROM dbo.AuditLogs a
                  LEFT JOIN dbo.Users u ON u.Id = a.UserId
                 WHERE a.ReferenceId = @labOrderId AND a.ModuleCode = 'LAB' AND a.ActionName = 'LAB.ReportUnapproved'
                 ORDER BY a.CreatedDate;

                -- rework: samples sent for re-collection (3) or rejected (4), one row per action
                SELECT DATEADD(SECOND, DATEDIFF(SECOND, '2000-01-01', l.ChangedOn), '2000-01-01') AS ChangedOn, l.ToStatusId,
                       MAX(l.RejectionReason) AS Reason, MAX(COALESCE(NULLIF(u.FullName, ''), u.Username)) AS UserName,
                       COUNT(*) AS Tests, MIN(lim.Test_Name) AS FirstTest
                  FROM dbo.LabSampleStatusLog l
                  LEFT JOIN dbo.Users u ON u.Id = l.ChangedBy
                  LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = l.InvestigationId
                 WHERE l.LabOrderId = @labOrderId AND l.ToStatusId IN (3, 4)
                 GROUP BY DATEADD(SECOND, DATEDIFF(SECOND, '2000-01-01', l.ChangedOn), '2000-01-01'), l.ToStatusId, l.ChangedBy
                 ORDER BY 1;

                -- deliveries after a change: revised reports sent
                SELECT SentDate, 'emailed' AS Channel FROM dbo.LabReportEmailLog
                 WHERE LabOrderId = @labOrderId AND IsRevised = 1 AND SentDate IS NOT NULL
                UNION ALL
                SELECT SentDate, 'sent on WhatsApp' FROM dbo.LabReportWhatsAppLog
                 WHERE LabOrderId = @labOrderId AND IsRevised = 1 AND SentDate IS NOT NULL
                 ORDER BY 1;", new { labOrderId });

            var f = await multi.ReadFirstOrDefaultAsync<WorkflowFacts>();
            if (f is null) return (object)(new { success = false, message = "Order not found." });
            var acts = (await multi.ReadAsync<(string ActionName, DateTime CreatedDate, string? UserName, string? Description)>()).ToList();
            (DateTime? At, string? By) Last(params string[] names)
            {
                var a = acts.FirstOrDefault(x => names.Contains(x.ActionName));
                return a.ActionName is null ? (null, null) : (a.CreatedDate, a.UserName);
            }

            // ── rework: re-test / re-collect / rejection / revised report ──
            var unapprovals = (await multi.ReadAsync<(DateTime CreatedDate, string? UserName, string? MetadataJson, string? Description)>())
                .Select(u =>
                {
                    string? kind = null, reason = null; int tests = 0;
                    try
                    {
                        using var doc = System.Text.Json.JsonDocument.Parse(string.IsNullOrWhiteSpace(u.MetadataJson) ? "{}" : u.MetadataJson);
                        var root = doc.RootElement;
                        if (root.TryGetProperty("UnapprovedFor", out var k) && k.ValueKind == System.Text.Json.JsonValueKind.String) kind = k.GetString();
                        if (root.TryGetProperty("Reason", out var r) && r.ValueKind == System.Text.Json.JsonValueKind.String) reason = r.GetString();
                        if (root.TryGetProperty("ChangedTestCount", out var c) && c.ValueKind == System.Text.Json.JsonValueKind.Number) tests = c.GetInt32();
                    }
                    catch (System.Text.Json.JsonException) { }
                    kind ??= System.Text.RegularExpressions.Regex.IsMatch(u.Description ?? "", "Re-?Collect", System.Text.RegularExpressions.RegexOptions.IgnoreCase) ? "Re-Collect" : "Re-Test";
                    return (At: u.CreatedDate, By: u.UserName, Kind: kind, Reason: reason, Tests: tests);
                }).ToList();
            var sampleChanges = (await multi.ReadAsync<(DateTime ChangedOn, int ToStatusId, string? Reason, string? UserName, int Tests, string? FirstTest)>()).ToList();
            var revisedSends = (await multi.ReadAsync<(DateTime SentDate, string Channel)>()).ToList();

            var rework = new List<(DateTime At, string Kind, string Title, string Detail, string? By)>();
            foreach (var u in unapprovals)
                rework.Add((u.At, u.Kind.Contains("Collect", StringComparison.OrdinalIgnoreCase) ? "recollect" : "retest",
                    $"Approval withdrawn for {u.Kind}",
                    (u.Tests > 0 ? $"{u.Tests} test(s)" : "") + (string.IsNullOrWhiteSpace(u.Reason) ? "" : (u.Tests > 0 ? " · " : "") + "Reason: " + u.Reason), u.By));
            foreach (var c in sampleChanges)
            {
                // a re-collection requested by withdrawing approval is already listed above
                if (c.ToStatusId == 3 && unapprovals.Any(u => u.Kind.Contains("Collect", StringComparison.OrdinalIgnoreCase) && Math.Abs((u.At - c.ChangedOn).TotalSeconds) <= 10)) continue;
                var what = c.Tests > 1 ? $"{c.Tests} tests" : c.FirstTest ?? "1 test";
                rework.Add((c.ChangedOn, c.ToStatusId == 4 ? "rejected" : "recollect",
                    c.ToStatusId == 4 ? "Sample rejected" : "Sample sent for re-collection",
                    what + (string.IsNullOrWhiteSpace(c.Reason) ? "" : " · Reason: " + c.Reason), c.UserName));
            }
            foreach (var c in acts.Where(a => a.ActionName == "LAB.BillCancelled"))
                rework.Add((c.CreatedDate, "cancelled", "Bill cancelled", CancelReason(c.Description), c.UserName));
            foreach (var g in revisedSends.GroupBy(r => r.SentDate.ToString("yyyyMMddHHmm")))
                rework.Add((g.Min(r => r.SentDate), "revised", "Revised report " + string.Join(", ", g.Select(r => r.Channel).Distinct()), "", null));
            rework = rework.OrderBy(r => r.At).ToList();
            var lastUnapproval = unapprovals.LastOrDefault();
            var recollections = sampleChanges.Count(c => c.ToStatusId == 3) + unapprovals.Count(u => u.Kind.Contains("Collect", StringComparison.OrdinalIgnoreCase));

            static string Money(decimal? v) => "₹" + (v ?? 0).ToString("#,##0.00", System.Globalization.CultureInfo.GetCultureInfo("en-IN"));
            var steps = new List<object>();
            void Step(string key, string label, string icon, string state, string detail, DateTime? at = null, string? by = null) =>
                steps.Add(new { key, label, icon, state, detail, at = at?.ToString("dd MMM yyyy, hh:mm tt"), by });

            // 1. booked
            var booked = Last("LAB.OrderBooked", "LAB.B2BOrderBooked");
            Step("booked", f.IsB2B ? "B2B Order Booked" : "Order Booked", "bi-receipt", "done",
                 f.IsB2B ? "Billed to the partner" : "Bill generated", f.OrderDate, booked.By ?? f.BookedBy);

            // 2. payment
            var paid = Last("LAB.PaymentReceived");
            if (f.IsB2B && (f.TotalPaid ?? 0) <= 0)
                Step("payment", "Payment", "bi-cash-coin", "done", "On the partner's credit account", f.OrderDate);
            else if (f.NetAmount is null)
                Step("payment", "Payment", "bi-cash-coin", "pending", "No payment recorded yet");
            else if ((f.BalanceDue ?? 0) <= 0)
                Step("payment", "Payment", "bi-cash-coin", "done", "Fully paid " + Money(f.TotalPaid), paid.At ?? f.PaidAt, paid.By);
            else if ((f.TotalPaid ?? 0) > 0)
                Step("payment", "Payment", "bi-cash-coin", "current", $"Paid {Money(f.TotalPaid)} of {Money(f.NetAmount)} · due {Money(f.BalanceDue)}", paid.At ?? f.PaidAt, paid.By);
            else
                Step("payment", "Payment", "bi-cash-coin", "current", "Payment due " + Money(f.BalanceDue));

            // 3. sample collection
            var coll = Last("LAB.AllSamplesCollected", "LAB.SampleCollected", "LAB.ProfileSamplesCollected");
            var outNote = f.Outsourced > 0 ? $" · {f.Outsourced} outsourced" : "";
            if (f.Total == 0)
                Step("collection", "Sample Collection", "bi-eyedropper", "pending", "No tests to collect");
            else if (f.Rejected > 0 || f.ReCollect > 0)
            {
                var lastChange = sampleChanges.LastOrDefault();
                Step("collection", "Sample Collection", "bi-eyedropper", "issue",
                     $"{f.Collected} of {f.Total} collected · " + string.Join(", ", new[] { f.Rejected > 0 ? $"{f.Rejected} rejected" : null, f.ReCollect > 0 ? $"{f.ReCollect} to re-collect" : null }.Where(x => x != null))
                     + (string.IsNullOrWhiteSpace(lastChange.Reason) ? "" : " · " + lastChange.Reason) + outNote,
                     lastChange.UserName is null && lastChange.Reason is null ? f.LastCollected ?? coll.At : lastChange.ChangedOn, lastChange.UserName ?? coll.By);
            }
            else if (f.Collected >= f.Total)
                Step("collection", "Sample Collection", "bi-eyedropper", "done",
                     $"All {f.Total} sample(s) collected" + (recollections > 0 ? " (after re-collection)" : "") + outNote, f.LastCollected ?? coll.At, coll.By);
            else
                Step("collection", "Sample Collection", "bi-eyedropper", f.Collected > 0 ? "current" : "pending",
                     f.Collected > 0 ? $"{f.Collected} of {f.Total} collected{outNote}" : "Awaiting collection", f.LastCollected ?? coll.At, coll.By);

            // 4. transfer to another branch (only when samples were sent)
            if (f.Transferred > 0)
                Step("transfer", "Sample Transfer", "bi-arrow-left-right", f.Received >= f.Transferred ? "done" : "current",
                     f.Received >= f.Transferred ? $"{f.Transferred} sample(s) sent and received" : $"{f.Received} of {f.Transferred} sample(s) received",
                     f.Received > 0 ? f.LastReceived : f.LastTransferred);

            // 5-7. results: the tests that can be reported (rejected ones cannot)
            var reportable = Math.Max(0, f.Total - f.Rejected);
            string Stage(int count) => reportable == 0 ? "pending" : count >= reportable ? "done" : count > 0 ? "current" : "pending";
            string Of(int count, string verb) => reportable == 0 ? "No reportable tests" : count >= reportable ? $"All {reportable} test(s) {verb}" : count > 0 ? $"{count} of {reportable} test(s) {verb}" : "Not started";
            var ent = Last("LAB.ReportEntryCompleted");
            var val = Last("LAB.ReportValidated");
            var apr = Last("LAB.ReportApproved");
            // withdrawn: the last un-approval is newer than the last approval and the tests are not all approved again
            var lastApprovedAt = new[] { f.LastApproved, apr.At }.Where(d => d.HasValue).DefaultIfEmpty().Max();
            var withdrawn = lastUnapproval.Kind is not null && f.Approved < reportable && (lastApprovedAt is null || lastUnapproval.At >= lastApprovedAt);
            var reworkFor = lastUnapproval.Kind is null ? "" : $" (after {lastUnapproval.Kind})";
            var waitingResample = withdrawn && lastUnapproval.Kind!.Contains("Collect", StringComparison.OrdinalIgnoreCase) && f.ReCollect > 0;

            Step("entry", "Result Entry", "bi-pencil-square", Stage(f.Entered),
                 waitingResample && f.Entered < reportable ? "Waiting for the re-collected sample" : Of(f.Entered, "entered") + (lastUnapproval.Kind is not null && f.Entered >= reportable ? reworkFor : ""),
                 f.LastEntered ?? ent.At, ent.By);
            Step("validation", "Validation", "bi-patch-check", Stage(f.Validated), Of(f.Validated, "validated"), f.LastValidated ?? val.At, val.By);
            if (withdrawn)
                Step("approval", "Approval", "bi-check2-circle", "issue",
                     $"Approval withdrawn for {lastUnapproval.Kind}" + (string.IsNullOrWhiteSpace(lastUnapproval.Reason) ? "" : " · " + lastUnapproval.Reason)
                     + (f.Approved > 0 ? $" · {f.Approved} of {reportable} approved" : ""),
                     lastUnapproval.At, lastUnapproval.By);
            else
                Step("approval", "Approval", "bi-check2-circle", Stage(f.Approved),
                     Of(f.Approved, "approved") + (lastUnapproval.Kind is not null && f.Approved >= reportable ? $" - re-approved{reworkFor}" : ""),
                     f.LastApproved ?? apr.At, apr.By);

            // 8. report delivered: printed / emailed / WhatsApp
            var printed = Last("LAB.ReportPrinted");
            var channels = new List<string>();
            if (printed.At is not null) channels.Add("printed");
            if (f.EmailedAt is not null) channels.Add("emailed");
            if (f.WhatsAppAt is not null) channels.Add("sent on WhatsApp");
            var deliveredAt = new[] { printed.At, f.EmailedAt, f.WhatsAppAt }.Where(d => d.HasValue).DefaultIfEmpty().Max();
            var allApproved = reportable > 0 && f.Approved >= reportable;
            var lastRevised = revisedSends.Count > 0 ? revisedSends.Max(r => r.SentDate) : (DateTime?)null;
            if (channels.Count == 0)
                Step("delivery", "Report Delivered", "bi-send-check", allApproved ? "current" : "pending",
                     allApproved ? "Ready - not printed or sent yet" : "After approval");
            else if (withdrawn)
                // the patient already has a report that is now being corrected
                Step("delivery", "Report Delivered", "bi-send-check", "issue",
                     $"Earlier report {string.Join(", ", channels)} on {deliveredAt:dd MMM} - revised report needed after {lastUnapproval.Kind}", deliveredAt, printed.By);
            else if (allApproved && lastApprovedAt is not null && deliveredAt < lastApprovedAt)
                Step("delivery", "Report Delivered", "bi-send-check", "current",
                     $"Revised report not sent yet (earlier report {string.Join(", ", channels)} on {deliveredAt:dd MMM})", deliveredAt, printed.By);
            else
                Step("delivery", "Report Delivered", "bi-send-check", allApproved ? "done" : "current",
                     (lastRevised is not null && lastRevised >= (lastApprovedAt ?? DateTime.MinValue) ? "Revised report " : "Report ") + string.Join(", ", channels)
                     + (allApproved ? "" : " (part of the tests)"), deliveredAt, printed.By ?? "sent automatically");

            // a cancelled bill: stages it never reached are stopped, and the cancellation closes the flow
            if (!f.IsActive)
            {
                for (var i = 0; i < steps.Count; i++)
                {
                    var st = System.Text.Json.JsonSerializer.SerializeToElement(steps[i]);
                    if (st.GetProperty("state").GetString() == "done") continue;
                    steps[i] = new
                    {
                        key = st.GetProperty("key").GetString(), label = st.GetProperty("label").GetString(), icon = st.GetProperty("icon").GetString(),
                        state = "skipped", detail = "Stopped - bill cancelled", at = (string?)null, by = (string?)null
                    };
                }
                var cx = acts.FirstOrDefault(a => a.ActionName == "LAB.BillCancelled");
                Step("cancelled", "Bill Cancelled", "bi-x-octagon", "issue",
                     cx.ActionName is null ? "The bill was cancelled" : CancelReason(cx.Description) is { Length: > 0 } why ? why : "The bill was cancelled",
                     cx.ActionName is null ? null : cx.CreatedDate, cx.UserName);
            }

            return (object)(new
            {
                success = true, cancelled = !f.IsActive, steps,
                rework = rework.Select(r => new { at = r.At.ToString("dd MMM yyyy, hh:mm tt"), kind = r.Kind, title = r.Title, detail = r.Detail, by = r.By })
            });
        }
        catch (Exception)
        {
            return (object)(new { success = false, message = "The workflow could not be loaded." });
        }
    }

    /// <summary>"Cancelled Full LAB Bill (Ref #305) → Cancellation No: CN-.., Amount: ₹850.00, Reason: Fault." → the useful part.</summary>
    private static string CancelReason(string? description)
    {
        if (string.IsNullOrWhiteSpace(description)) return "";
        var full = description.Contains("Full", StringComparison.OrdinalIgnoreCase) ? "Full bill" : "Part of the bill";
        var m = System.Text.RegularExpressions.Regex.Match(description, @"Reason:\s*(.+?)\.?\s*$");
        var no = System.Text.RegularExpressions.Regex.Match(description, @"Cancellation No:\s*([^,]+)");
        return full + (no.Success ? " · " + no.Groups[1].Value.Trim() : "") + (m.Success ? " · Reason: " + m.Groups[1].Value.Trim() : "");
    }
}
