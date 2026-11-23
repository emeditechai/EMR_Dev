namespace EMR.Common;

/// <summary>The "your lab bill" email (bill PDF attached), in the common email layout.</summary>
public static class LabBillEmail
{
    public static string Body(string? hospitalName, string? patientName, string? billNo, string? address)
    {
        static string H(string? v) => System.Net.WebUtility.HtmlEncode(v ?? string.Empty);
        var hospital = string.IsNullOrWhiteSpace(hospitalName) ? "our hospital" : hospitalName.Trim();
        return EmailLayout.Wrap(
            EmailLayout.Greeting(patientName ?? "Patient")
            + EmailLayout.P($"Thank you for choosing <strong>{H(hospital)}</strong> for your healthcare needs.")
            + EmailLayout.Details(("Bill No", H(billNo)), ("Date", DateTime.Now.ToString("dd MMM yyyy")))
            + EmailLayout.P("Please find your detailed lab order bill attached to this email as a PDF document.")
            + EmailLayout.P("If you have any questions or require further assistance, please do not hesitate to contact us.")
            + EmailLayout.P($"Wishing you the best of health,<br/><strong>The {H(hospital)} Team</strong>"),
            heading: "Your lab bill",
            organisation: hospital,
            footerHtml: $"&copy; {DateTime.Now.Year} {H(hospital)}. All rights reserved."
                        + (string.IsNullOrWhiteSpace(address) ? "" : $"<br/>{H(address)}"));
    }
}
