using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

public interface IPaymentSummaryApiClient
{
    Task<PaymentSummaryResult?> GetAsync(string moduleCode, int moduleRefId);
}
