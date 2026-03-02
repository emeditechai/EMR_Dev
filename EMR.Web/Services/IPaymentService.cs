using EMR.Web.Models.ViewModels;

namespace EMR.Web.Services;

public interface IPaymentService
{
    Task<IEnumerable<PaymentMethodViewModel>> GetActiveMethodsAsync();
    Task<PaymentSummaryViewModel?> GetPaymentSummaryAsync(string moduleCode, int moduleRefId);
    Task<SavePaymentResult> SavePaymentAsync(SavePaymentRequest request, int? userId);
    Task<BillPaymentSummary?> GetPaymentForBillAsync(string moduleCode, int moduleRefId);
}
