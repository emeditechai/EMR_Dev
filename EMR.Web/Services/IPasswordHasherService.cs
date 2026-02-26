namespace EMR.Web.Services;

public interface IPasswordHasherService
{
    (string Hash, string Salt) HashPassword(string password);
    bool VerifyPassword(string password, string hash);
}
