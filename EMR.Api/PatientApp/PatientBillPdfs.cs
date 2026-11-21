using EMR.Api.Services;

namespace EMR.Api.PatientApp;

/// <summary>The bill PDFs (QuestPDF, PatientDocumentService) attached to the patient app's booking WhatsApp / e-mail.</summary>
public sealed class PatientBillPdfs(IPatientDocumentService documents) : IPatientBillPdfs
{
    public async Task<BillPdf?> LabBillAsync(int labOrderId) =>
        await documents.LabBillAsync(labOrderId) is { Pdf: { } pdf, FileName: { } name } ? new BillPdf(name, pdf) : null;

    public async Task<BillPdf?> OpdBillAsync(int opdServiceId) =>
        await documents.OpdBillAsync(opdServiceId) is { Pdf: { } pdf, FileName: { } name } ? new BillPdf(name, pdf) : null;
}
