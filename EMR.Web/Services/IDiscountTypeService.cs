namespace EMR.Web.Services;

public interface IDiscountTypeService
{
    Task<bool> NameExistsAsync(string name, int? excludeId = null, int? companyId = null);
}
