namespace EMR.Api.Services;

public interface IPaymentSummaryService
{
    Task<EMR.Api.Models.PaymentSummaryResult?> GetByBillAsync(string moduleCode, int moduleRefId);
}
