using EMR.Web.Data;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;
using Dapper;
using EMR.Web.ApiClients;

namespace EMR.Web.Controllers;

[AllowAnonymous] // Allow anyone to access the login page
public class PatientPortalController(
    ApplicationDbContext dbContext,
    IPasswordHasherService passwordHasher,
    IPatientPortalApiClient portalApiClient) : Controller
{
    // GET: /PatientPortal/Login
    [HttpGet]
    public IActionResult Login()
    {
        return View();
    }

    // POST: /PatientPortal/Login
    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Login(PatientLoginViewModel model)
    {
        if (!ModelState.IsValid)
            return View(model);

        var patient = await dbContext.PatientMasters
            .FirstOrDefaultAsync(p => p.PatientCode == model.Username || p.EmailId == model.Username);

        if (patient == null || !patient.IsLoginGenerated)
        {
            ModelState.AddModelError(string.Empty, "Invalid login credentials or account not yet setup.");
            return View(model);
        }

        // Use BCrypt to verify the password against the stored PasswordHash
        bool isPasswordCorrect = false;
        if (!string.IsNullOrEmpty(patient.PasswordHash))
        {
            isPasswordCorrect = passwordHasher.VerifyPassword(model.Password, patient.PasswordHash);
        }

        if (!isPasswordCorrect)
        {
            ModelState.AddModelError(string.Empty, "Invalid login credentials.");
            return View(model);
        }

        // Password is correct.
        // Check if it's the first login (IsPasswordchanged == false)
        if (!patient.IsPasswordchanged)
        {
            TempData["Success"] = "For your security, please change your password on your first login.";
            
            // Redirect to change password
            var changeViewModel = new PatientChangePasswordViewModel
            {
                PatientId = patient.PatientId
            };
            
            // Set session or use tempdata so we don't expose patientId openly for the change form
            HttpContext.Session.SetInt32("ChangePasswordPatientId", patient.PatientId);
            return RedirectToAction(nameof(ChangePassword));
        }

        // Normal Login: Update Lastlogin
        await dbContext.Database.GetDbConnection().ExecuteAsync(
            "UPDATE PatientMaster SET Lastlogin = @Now WHERE PatientId = @Id",
            new { Now = DateTime.Now, Id = patient.PatientId }
        );

        // Authenticate the user (using session for this simple mockup)
        HttpContext.Session.SetInt32("PatientId", patient.PatientId);
        HttpContext.Session.SetString("PatientName", patient.FirstName + " " + patient.LastName);

        return RedirectToAction(nameof(Dashboard));
    }

    // GET: /PatientPortal/ChangePassword
    [HttpGet]
    public IActionResult ChangePassword()
    {
        var patientId = HttpContext.Session.GetInt32("ChangePasswordPatientId");
        if (patientId == null)
            return RedirectToAction(nameof(Login));

        var model = new PatientChangePasswordViewModel
        {
            PatientId = patientId.Value
        };

        return View(model);
    }

    // POST: /PatientPortal/ChangePassword
    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> ChangePassword(PatientChangePasswordViewModel model)
    {
        if (!ModelState.IsValid)
            return View(model);

        var patientId = HttpContext.Session.GetInt32("ChangePasswordPatientId");
        if (patientId == null || patientId != model.PatientId)
            return RedirectToAction(nameof(Login));

        var patient = await dbContext.PatientMasters.FirstOrDefaultAsync(p => p.PatientId == patientId);
        if (patient == null)
            return RedirectToAction(nameof(Login));

        // Hash the new password
        var (Hash, Salt) = passwordHasher.HashPassword(model.NewPassword);

        // Update DB: IsPasswordchanged = 1, Lastlogin = getdate(), new hash & salt
        await dbContext.Database.GetDbConnection().ExecuteAsync(
            @"UPDATE PatientMaster 
              SET PasswordHash = @Hash, 
                  Salt = @Salt, 
                  IsPasswordchanged = 1, 
                  Lastlogin = @Now 
              WHERE PatientId = @Id",
            new { Hash, Salt, Now = DateTime.Now, Id = patientId }
        );

        TempData["Success"] = "Password changed successfully! You are now logged in.";
        
        // Log them in
        HttpContext.Session.Remove("ChangePasswordPatientId");
        HttpContext.Session.SetInt32("PatientId", patient.PatientId);
        HttpContext.Session.SetString("PatientName", patient.FirstName + " " + patient.LastName);

        return RedirectToAction(nameof(Dashboard));
    }

    // GET: /PatientPortal/Dashboard
    [HttpGet]
    public async Task<IActionResult> Dashboard()
    {
        var patientId = HttpContext.Session.GetInt32("PatientId");
        if (patientId == null)
            return RedirectToAction(nameof(Login));

        var patientProfile = await portalApiClient.GetFullProfileAsync(patientId.Value);
        if (patientProfile == null || patientProfile.PatientId == 0)
            return RedirectToAction(nameof(Login));

        return View(patientProfile);
    }

    // POST: /PatientPortal/Logout
    [HttpPost]
    [ValidateAntiForgeryToken]
    public IActionResult Logout()
    {
        HttpContext.Session.Remove("PatientId");
        HttpContext.Session.Remove("PatientName");
        HttpContext.Session.Remove("ChangePasswordPatientId");
        
        return RedirectToAction(nameof(Login));
    }
}
