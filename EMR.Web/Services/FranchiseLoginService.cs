using EMR.Shared.Security;
using EMR.Web.Data;
using EMR.Web.Models.Entities;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Services;

/// <summary>
/// The sign-in of a Lab Franchise (Users.User_Type 'F', ReferenceUserID = Franchise_ID), kept in step with the franchise's
/// e-mail when the franchise is created, edited or its change approved:
///  - no login yet and an e-mail given: a login is made (Franchise role, parent branch) and, when active, its details mailed;
///  - a login already there and the e-mail changed: its sign-in moves to the new e-mail (password unchanged).
/// Sign-in is by e-mail, so an e-mail used by another sign-in is never taken over - the caller is told instead.
/// </summary>
public interface IFranchiseLoginService
{
    /// <summary>Answers null when nothing needs saying, else a note for the user (what was done, or why it was not).</summary>
    Task<string?> EnsureAsync(int franchiseId, string franchiseName, string? email, string? mobile, int branchId, int companyId,
        bool active, int actingUserId, int? fallbackBranchId, string baseUrl);
}

public class FranchiseLoginService(ApplicationDbContext dbContext, IPasswordHasherService passwordHasher, ILoginCredentialsMailer mailer,
    ILogger<FranchiseLoginService> logger) : IFranchiseLoginService
{
    public async Task<string?> EnsureAsync(int franchiseId, string franchiseName, string? email, string? mobile, int branchId, int companyId,
        bool active, int actingUserId, int? fallbackBranchId, string baseUrl)
    {
        email = email?.Trim();
        var login = await dbContext.Users.FirstOrDefaultAsync(u => u.UserType == UserTypes.Franchise && u.ReferenceUserId == franchiseId);
        if (string.IsNullOrWhiteSpace(email)) return null;   // no e-mail: nothing to sign in with

        var lower = email.ToLower();
        bool TakenByOther(User u) => login == null || u.Id != login.Id;
        var other = await dbContext.Users.Where(u => u.Username == email || (u.Email != null && u.Email.Trim().ToLower() == lower)).ToListAsync();

        if (login != null)
        {
            if (string.Equals(login.Username, email, StringComparison.OrdinalIgnoreCase)) return null;   // already this e-mail
            if (other.Any(TakenByOther))
                return $"The franchise login was not moved to {email}: that e-mail is used by another sign-in. It still signs in as {login.Username}.";
            var old = login.Username;
            login.Username = email; login.Email = email; login.LastModifiedDate = DateTime.Now;
            await dbContext.SaveChangesAsync();
            logger.LogInformation("[FRANCHISE-LOGIN] franchise {Id}: sign-in moved {Old} -> {New}", franchiseId, old, email);
            return $"The franchise login now signs in with {email} (was {old}); its password is unchanged.";
        }

        if (other.Count > 0)
            return $"No login was created for this franchise: the e-mail {email} is already used by another sign-in.";

        var password = LoginCredentialsMailer.DefaultPassword;
        var (hash, salt) = passwordHasher.HashPassword(password);
        var user = new User
        {
            CompanyId = companyId, Username = email, Email = email, PasswordHash = hash, Salt = salt,
            FullName = franchiseName, FirstName = franchiseName, PhoneNumber = mobile, Phone = mobile,
            IsActive = active, UserType = UserTypes.Franchise, ReferenceUserId = franchiseId,
            MustChangePassword = true, PasswordLastChanged = DateTime.Now, CreatedDate = DateTime.Now, LastModifiedDate = DateTime.Now
        };
        dbContext.Users.Add(user);
        await dbContext.SaveChangesAsync();
        dbContext.UserBranches.Add(new UserBranch
        {
            UserId = user.Id, BranchId = branchId, IsActive = true, CreatedDate = DateTime.Now, ModifiedDate = DateTime.Now,
            CreatedBy = actingUserId, ModifiedBy = actingUserId
        });
        // a login cannot sign in without a role: every franchise login carries the "Franchise" role (roles are global, 2334)
        var role = await dbContext.Roles.OrderBy(r => r.Id).FirstOrDefaultAsync(r => r.Name == "Franchise");
        if (role is null)
        {
            role = new Role { Name = "Franchise", Description = "Franchise-level access", IconClass = "fas fa-building", CompanyId = 1 };
            dbContext.Roles.Add(role);
            await dbContext.SaveChangesAsync();
        }
        dbContext.UserRoles.Add(new UserRole
        {
            UserId = user.Id, RoleId = role.Id, Branch_ID = branchId, IsActive = true, AssignedDate = DateTime.Now,
            AssignedBy = actingUserId, CreatedBy = actingUserId, CreatedDate = DateTime.Now
        });
        await dbContext.SaveChangesAsync();
        if (!active) return $"A franchise login {email} was created; it is enabled (and its details e-mailed) when the franchise is active / approved.";

        var (sent, reason) = await mailer.SendAsync(branchId, fallbackBranchId, franchiseName, email, password, baseUrl);
        return sent ? $"A franchise login {email} was created and its login details were e-mailed."
                    : $"A franchise login {email} was created, but its login details could not be e-mailed ({reason}). Please share them with the franchise.";
    }
}
