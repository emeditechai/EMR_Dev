using EMR.Web.ApiClients;
using EMR.Web.Data;
using EMR.Web.Models.DTOs;
using EMR.Web.Models.ViewModels;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Services;

/// <summary>
/// The LAB bill as the shared link prints it (LabOrderBooking/PrintBillAnonymous): the figures and lines of the bill,
/// without the branch's print template. Also the patient app's bill PDF (PatientBillPdfDocument).
/// </summary>
public static class LabBillPrintBuilder
{
    public static async Task<(PrintBillViewModel Vm, int BranchId)?> BuildAnonymousAsync(ILabOrderApiClient labOrderApiClient,
        ApplicationDbContext dbContext, int labOrderId)
    {
        var detail = await labOrderApiClient.GetOrderDetailAsync(labOrderId);
        if (detail == null) return null;

        var branchId = detail.BranchId;

        var settings = await dbContext.HospitalSettings
            .Where(s => s.BranchId == branchId && s.IsActive)
            .FirstOrDefaultAsync();

        decimal grossAmount = detail.Items.Sum(i => i.Price);
        // tests cancelled after billing: shown as "Less: cancelled tests" so gross - cancelled - discount = the bill
        decimal cancelledAmount = detail.Items.Where(i => !i.IsActive).Sum(i => i.Price);
        var printAdj = (await EMR.Web.Services.LabBillAdjustments.LoadAsync(dbContext.Database.GetDbConnection(), [labOrderId])).GetValueOrDefault(labOrderId);
        decimal headerDiscount = detail.DiscountAmount;
        bool hasRecordedLineDiscounts = detail.Items.Any(i => i.DiscountAmount > 0);

        var lineItems = detail.Items.Select(i =>
        {
            decimal lineDiscount = hasRecordedLineDiscounts
                ? i.DiscountAmount
                : (grossAmount > 0 && headerDiscount > 0 ? Math.Round(headerDiscount * i.Price / grossAmount, 2) : 0);

            return new PrintBillLineItem
            {
                TestCode     = i.TestCode,
                TestName     = i.TestName,
                SampleType   = i.SampleType,
                MRP          = i.Price,
                DiscountAmount = lineDiscount,
                IsActive     = i.IsActive
            };
        }).ToList();

        // misc charges (SQLScripts/2240) print after the investigations: amount, its discount, cancelled ones struck through;
        // their GST is a row of its own in the summary
        foreach (var m in printAdj?.MiscLines ?? [])
            lineItems.Add(new PrintBillLineItem
            {
                TestCode = m.ChargeType == "Home Collection" ? "HOME-COLL" : "MISC",
                TestName = m.DisplayName + (m.IsGstRequired ? $" (GST {m.GstPercentage:0.##}%)" : ""),
                SampleType = m.ChargeType == "Home Collection" ? "Home Collection" : "Misc Charge",
                MRP = detail.IsB2B ? m.Amount : m.Amount,
                DiscountAmount = detail.IsB2B ? 0 : m.DiscountAmount,
                IsActive = m.IsActive
            });
        decimal miscGross = printAdj?.MiscLines.Sum(m => m.Amount) ?? 0m;
        decimal miscCancelled = printAdj?.MiscLines.Where(m => !m.IsActive).Sum(m => m.Amount) ?? 0m;
        decimal miscGst = printAdj?.MiscGstAmount ?? 0m;
        grossAmount += miscGross;
        cancelledAmount += miscCancelled;

        var vm = new PrintBillViewModel
        {
            IsActive              = detail.IsActive,
            // the e-mailed / sent bill PDF: a franchise B2B bill follows the franchise's Report Header Required;
            // B2C and company B2B bills keep the header / footer as before
            ShowHeaderFooter      = await LabFranchiseHeader.ForOrderAsync(dbContext, labOrderId) ?? true,
            PageSize              = settings?.LabBillPrintPageSize == "A5L" ? "A5L" : "A4",
            HospitalName          = settings?.HospitalName ?? "eMeditech Hospital",
            HospitalType          = settings?.HospitalType,
            RegistrationNumber    = settings?.RegistrationNumber,
            HospitalAddress       = settings?.Address,
            HospitalPhone         = settings?.ContactNumber1,
            HospitalEmergencyPhone = settings?.EmergencyNumber,
            HospitalEmail         = settings?.EmailAddress,
            HospitalWebsite       = settings?.Website,
            HospitalGSTIN         = settings?.GSTCode,
            HospitalLogoPath      = settings?.LogoPath,
            BranchName            = detail.BranchName,
            NabhStatus            = settings?.NabhStatus,
            NabhCertificateNo     = settings?.NabhCertificateNo,
            NabhValidFrom         = settings?.NabhValidFrom,
            NabhValidTo           = settings?.NabhValidTo,

            PatientName  = detail.PatientName,
            PatientCode  = detail.PatientCode,
            BeneficiaryId = detail.BeneficiaryId,
            GovtSchemeName = detail.GovtSchemeName,
            PhoneNumber  = detail.PhoneNumber,
            EmailId      = detail.EmailId,
            Gender       = detail.Gender,
            LmpDate      = detail.LmpDate,   // 2453
            Age          = detail.Age,
            DateOfBirth  = detail.DateOfBirth,
            Address      = detail.Address,

            LabOrderId        = detail.LabOrderId,
            BillNo            = detail.BillNo,
            TokenNo           = detail.TokenNo,
            BookingNo         = detail.BookingNo,   // 2384
            OrderDate         = detail.OrderDate,
            CreatedDate       = detail.CreatedDate,
            BookingDate       = detail.BookingDate,
            CollectionType    = detail.CollectionType,
            PhlebotomistName  = detail.PhlebotomistName,
            ReferralDoctorName = detail.ReferralDoctorName,
            CreatedByName     = detail.CreatedByName,
            CreatedByUsername = detail.CreatedByUsername,
            PrintedByName     = "Patient Portal",

            // B2B vs B2C Payment & Billing Handling
            IsB2B           = detail.IsB2B,
            PartnerName     = detail.AgentName,
            PartnerCode     = detail.AgentCode,
            GrossAmount     = grossAmount,
            DiscountAmount  = headerDiscount,
            RoundOffAmount  = detail.RoundOffAmount,
            CancelledAmount = cancelledAmount,
            MiscCgstAmount  = printAdj?.MiscCgstAmount ?? 0m,
            MiscSgstAmount  = printAdj?.MiscSgstAmount ?? 0m,
            RefundedAmount  = detail.IsB2B ? 0m : (printAdj?.RefundedAmount ?? 0m),
            MembershipCardNo     = detail.IsB2B ? null : printAdj?.MembershipCardNo,
            PointsRedeemed       = detail.IsB2B ? 0m : (printAdj?.PointsRedeemed ?? 0m),
            PointsRedeemedAmount = detail.IsB2B ? 0m : (printAdj?.PointsRedeemedAmount ?? 0m),
            PointsEarned         = detail.IsB2B ? 0m : (printAdj?.PointsEarned ?? 0m),
            MembershipDiscountAmount = detail.IsB2B ? 0m : (printAdj?.MembershipDiscountAmount ?? 0m),
            GrandTotal      = detail.IsB2B ? (grossAmount - cancelledAmount - headerDiscount + miscGst + detail.RoundOffAmount) : detail.NetAmount,
            ReceivedAmount  = detail.IsB2B ? (grossAmount - cancelledAmount - headerDiscount + miscGst + detail.RoundOffAmount) : detail.TotalPaid,
            Balance         = detail.IsB2B ? 0.00m : detail.BalanceDue,
            PaymentStatus   = detail.IsB2B ? "P" : detail.PaymentStatus,

            LineItems = lineItems,
            Payments  = detail.IsB2B
                ? (detail.Payments.Any()
                    ? detail.Payments.Select(p =>
                      {
                          var row = ToPrintBillPaymentRow(p);
                          row.PaidAmount = grossAmount - headerDiscount + detail.RoundOffAmount;
                          row.ReceivedByName ??= detail.CreatedByName ?? detail.CreatedByUsername;
                          row.PaymentDate ??= detail.CreatedDate;
                          return row;
                      }).ToList()
                    : new List<PrintBillPaymentRow>
                      {
                          new PrintBillPaymentRow
                          {
                              MethodName     = "B2B Partner Credit",
                              PaidAmount     = grossAmount - headerDiscount + detail.RoundOffAmount,
                              ReceiptNo      = detail.BillNo,
                              // the partner's account is charged when the bill is booked: by whom and when
                              ReceivedByName = detail.CreatedByName ?? detail.CreatedByUsername,
                              PaymentDate    = detail.CreatedDate
                          }
                      })
                : detail.Payments.Select(ToPrintBillPaymentRow).ToList()
        };


        return (vm, branchId);
    }

    private static PrintBillPaymentRow ToPrintBillPaymentRow(LabOrderPaymentDetailDto p) => new()
    {
        MethodName      = p.MethodName,
        PaidAmount      = p.PaidAmount,
        TransactionRef  = p.TransactionRef,
        ReceiptNo       = p.ReceiptNo,
        PaymentDate     = p.PaymentDate == default ? null : p.PaymentDate,
        ChequeNo        = p.ChequeNo,
        BankName        = p.BankName,
        UPIRefNo        = p.UPIRefNo,
        CardLast4       = p.CardLast4,
        ReceivedByName  = p.ReceivedByName,
        IsDueCollection = p.IsDueCollection
    };
}
