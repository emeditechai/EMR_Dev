using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Rendering;
using Microsoft.EntityFrameworkCore;
using EMR.Web.Data;
using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using EMR.Web.Services.Geography;
using EMR.Web.ApiClients;
using EMR.Web.Models.DTOs;
using EMR.Web.Extensions;
using Dapper;
using System.Net.Http;
using System.Text.Json;

namespace EMR.Web.Controllers
{
    [Authorize]
    public class LabOrderBookingController(
        ApplicationDbContext dbContext,
        IPatientService patientService,
        IPaymentService paymentService,
        ILedgerService ledgerService,
        IAuditLogService auditLogService,
        ILabOrderApiClient labOrderApiClient,
        ICountryService countryService,
        IStateService stateService,
        IDistrictService districtService,
        ICityService cityService,
        IAreaService areaService,
        IQueryStringEncryptionService encryptionService,
        IWebHostEnvironment env,
        ISampleCollectionApiClient sampleCollectionApiClient) : Controller
    {
        [HttpGet]
        public async Task<IActionResult> B2CBooking(int? patientId)
        {
            var model = new LabOrderBookingViewModel();

            if (patientId.HasValue && patientId > 0)
            {
                var patient = await patientService.GetByIdAsync(patientId.Value);
                if (patient != null)
                {
                    model.PatientId = patient.PatientId;
                    model.PatientCode = patient.PatientCode;
                    model.FirstName = patient.FirstName;
                    model.LastName = patient.LastName;
                    model.PhoneNumber = patient.PhoneNumber;
                    model.EmailId = patient.EmailId;
                    model.Gender = patient.Gender;
                    model.DateOfBirth = patient.DateOfBirth;
                    if (patient.DateOfBirth.HasValue)
                    {
                        var (y, m, d) = EMR.Web.Utils.AgeCalculator.FromDateOfBirth(patient.DateOfBirth.Value);
                        model.AgeYears = y;
                        model.AgeMonths = m;
                        model.AgeDays = d;
                    }
                    model.RelationId = patient.RelationId;
                    model.Salutation = patient.Salutation;
                    model.PhotoPath = patient.PhotoPath;
                    model.IdentificationFilePath = patient.IdentificationFilePath;
                    model.Address = patient.Address;
                    model.HomeCollectionAddress = patient.HomeCollectionAddress;
                    model.Latitude = patient.Latitude;
                    model.Longitude = patient.Longitude;
                }
            }

            await PopulateSelectLists(model);
            return View(model);
        }

        [HttpPost, ValidateAntiForgeryToken]
        public async Task<IActionResult> B2CBooking(LabOrderBookingViewModel model, IFormFile? identificationFile, IFormFile? profilePictureFile)
        {
            var branchId = User.GetCurrentBranchId();
            if (branchId is null)
            {
                TempData["Error"] = "Please select a branch first.";
                return RedirectToAction("SelectBranch", "Account");
            }

            List<LabOrderItemRequestDto>? lineItems = null;
            if (!model.DemographicsOnly)
            {
                if (model.BookingDateTime < DateTime.Now.AddMinutes(-2))
                {
                    ModelState.AddModelError("BookingDateTime", "Booking Date & Time cannot be less than current Date & Time.");
                }

                try
                {
                    var serializeOptions = new System.Text.Json.JsonSerializerOptions { PropertyNameCaseInsensitive = true };
                    lineItems = string.IsNullOrWhiteSpace(model.LineItemsJson)
                        ? null
                        : System.Text.Json.JsonSerializer.Deserialize<List<LabOrderItemRequestDto>>(model.LineItemsJson, serializeOptions);
                    if (lineItems != null)
                    {
                        foreach (var itm in lineItems)
                        {
                            if (string.IsNullOrWhiteSpace(itm.Type))
                            {
                                itm.Type = itm.IsPackage ? "P" : "I";
                            }
                        }
                    }
                }
                catch { }

                if (lineItems == null || !lineItems.Any())
                {
                    ModelState.AddModelError(nameof(model.LineItemsJson), "At least one investigation is required.");
                }
            }

            // Validate & Reconcile Age / Date of Birth
            if (model.AgeMonths is > 12)
                ModelState.AddModelError(nameof(model.AgeMonths), "Month cannot exceed 12.");
            if (model.AgeDays is > 30)
                ModelState.AddModelError(nameof(model.AgeDays), "Days cannot exceed 30.");
            if (model.AgeYears is < 0 or > 150)
                ModelState.AddModelError(nameof(model.AgeYears), "Years must be between 0 and 150.");

            bool hasAgeInput = model.AgeYears.HasValue || model.AgeMonths.HasValue || model.AgeDays.HasValue;
            if (hasAgeInput)
            {
                int y = model.AgeYears ?? 0;
                int m = model.AgeMonths ?? 0;
                int d = model.AgeDays ?? 0;
                if (y == 0 && m == 0 && d == 0 && !model.DateOfBirth.HasValue)
                {
                    ModelState.AddModelError(nameof(model.AgeYears), "Age is required.");
                }
                else
                {
                    model.DateOfBirth = EMR.Web.Utils.AgeCalculator.ToDateOfBirth(y, m, d);
                }
            }
            else if (model.DateOfBirth.HasValue)
            {
                if (model.DateOfBirth.Value > DateTime.Today)
                {
                    ModelState.AddModelError(nameof(model.DateOfBirth), "Date of Birth cannot be in the future.");
                }
                else
                {
                    var (y, m, d) = EMR.Web.Utils.AgeCalculator.FromDateOfBirth(model.DateOfBirth.Value);
                    model.AgeYears = y;
                    model.AgeMonths = m;
                    model.AgeDays = d;
                }
            }
            else
            {
                ModelState.AddModelError(nameof(model.AgeYears), "Age or Date of Birth is required.");
            }

            if (!ModelState.IsValid)
            {
                await PopulateSelectLists(model);
                return View(model);
            }

            // Handle file upload
            if (identificationFile is { Length: > 0 })
            {
                var allowed = new[] { ".pdf", ".jpg", ".jpeg", ".png" };
                var ext = Path.GetExtension(identificationFile.FileName).ToLowerInvariant();
                if (!allowed.Contains(ext))
                {
                    ModelState.AddModelError("IdentificationFilePath", "Only PDF, JPG, JPEG and PNG files are allowed.");
                    await PopulateSelectLists(model);
                    return View(model);
                }

                var uploadsDir = Path.Combine(env.WebRootPath, "uploads", "patients");
                Directory.CreateDirectory(uploadsDir);
                var fileName = $"{Guid.NewGuid()}{ext}";
                var fullPath = Path.Combine(uploadsDir, fileName);
                await using (var stream = new FileStream(fullPath, FileMode.Create))
                {
                    await identificationFile.CopyToAsync(stream);
                }
                model.IdentificationFilePath = $"/uploads/patients/{fileName}";
            }

            // Handle profile picture upload
            if (profilePictureFile is { Length: > 0 })
            {
                var allowed = new[] { ".jpg", ".jpeg", ".png", ".gif" };
                var ext = Path.GetExtension(profilePictureFile.FileName).ToLowerInvariant();
                if (!allowed.Contains(ext))
                {
                    ModelState.AddModelError("PhotoPath", "Only JPG, JPEG, PNG and GIF files are allowed for Profile Picture.");
                    await PopulateSelectLists(model);
                    return View(model);
                }

                var uploadsDir = Path.Combine(env.WebRootPath, "uploads", "patients");
                Directory.CreateDirectory(uploadsDir);
                var fileName = $"{Guid.NewGuid()}{ext}";
                var fullPath = Path.Combine(uploadsDir, fileName);
                await using (var stream = new FileStream(fullPath, FileMode.Create))
                {
                    await profilePictureFile.CopyToAsync(stream);
                }
                model.PhotoPath = $"/uploads/patients/{fileName}";
            }

            var patient = new PatientMaster
            {
                PatientId = model.PatientId,
                FirstName = model.FirstName,
                MiddleName = model.MiddleName,
                LastName = model.LastName,
                PhoneNumber = model.PhoneNumber,
                SecondaryPhoneNumber = model.SecondaryPhoneNumber,
                EmailId = model.EmailId,
                Gender = model.Gender,
                DateOfBirth = model.DateOfBirth,
                RelationId = model.RelationId,
                Salutation = model.Salutation,
                PhotoPath = model.PhotoPath,
                IdentificationFilePath = model.IdentificationFilePath,
                IdentificationTypeId = model.IdentificationTypeId,
                IdentificationNumber = model.IdentificationNumber,
                ReligionId = model.ReligionId,
                GuardianName = model.GuardianName,
                CountryId = model.CountryId,
                StateId = model.StateId,
                DistrictId = model.DistrictId,
                CityId = model.CityId,
                AreaId = model.AreaId,
                Address = string.IsNullOrWhiteSpace(model.Address) ? model.HomeCollectionAddress : model.Address,
                HomeCollectionAddress = string.IsNullOrWhiteSpace(model.HomeCollectionAddress) ? model.Address : model.HomeCollectionAddress,
                Latitude = model.Latitude,
                Longitude = model.Longitude,
                OccupationId = model.OccupationId,
                MaritalStatusId = model.MaritalStatusId,
                ReferralDoctorId = model.ReferralDoctorId,
                BloodGroup = model.BloodGroup,
                KnownAllergies = model.KnownAllergies,
                Remarks = model.Remarks,
                BranchId = branchId,
                CompanyId = 1, // Default
                IsActive = true
            };

            int actualPatientId = model.PatientId;
            if (model.PatientId == 0)
            {
                // Create demographics
                actualPatientId = await patientService.CreateDemographicsOnlyAsync(patient, User.GetUserId());
                patient.PatientId = actualPatientId;
                await auditLogService.LogAsync("LAB", "Patient.Create", $"Registered patient: {patient.FirstName} {patient.LastName} for LAB.");
            }
            else
            {
                // Update demographics
                var existing = await patientService.GetByIdAsync(model.PatientId);
                if (string.IsNullOrWhiteSpace(model.IdentificationFilePath)) patient.IdentificationFilePath = existing?.IdentificationFilePath;
                if (string.IsNullOrWhiteSpace(model.PhotoPath)) patient.PhotoPath = existing?.PhotoPath;

                await patientService.UpdateDemographicsAsync(patient, User.GetUserId());
            }

            if (model.DemographicsOnly)
            {
                TempData["Success"] = $"Patient demographics updated successfully.";
                return RedirectToAction(nameof(B2CBooking), new { patientId = actualPatientId });
            }

            // Create Lab Order
            var labOrderReq = new LabOrderRequestDto
            {
                PatientId = actualPatientId,
                BranchId = branchId.Value,
                CollectionType = string.IsNullOrWhiteSpace(model.CollectionType) ? "Lab" : model.CollectionType,
                PhlebotomistId = model.CollectionType == "Home Collection" ? model.PhlebotomistId : null,
                BookingDate = model.BookingDateTime,
                Items = lineItems!
            };

            var labOrderRes = await labOrderApiClient.CreateOrderAsync(labOrderReq);
            await labOrderApiClient.CreateSampleCollectionAsync(labOrderRes.LabOrderId, branchId.Value, patient.CompanyId);

            decimal totalAmount = lineItems!.Sum(x => x.Price);
            await ledgerService.PostLabBillLedgerAsync(labOrderRes.LabOrderId, totalAmount, branchId, patient.CompanyId, User.GetUserId(), labOrderRes.BillNo);

            TempData["NewPatientName"]  = ((patient.Salutation ?? "") + " " + patient.FirstName + " " + patient.LastName).Trim();
            TempData["BillNo"]          = labOrderRes.BillNo;
            TempData["NewLabOrderId"]   = labOrderRes.LabOrderId.ToString();
            return RedirectToAction(nameof(B2CBooking), new { registered = true });
        }

        [HttpPost]
        public async Task<IActionResult> SaveBookingWithPayment(
            [FromForm] LabOrderBookingViewModel model,
            [FromForm] IFormFile? profilePictureFile,
            [FromForm] IFormFile? identificationFile,
            [FromForm] string? paymentDataJson)
        {
            try
            {
            var branchId = User.GetCurrentBranchId();
            if (branchId == null)
            {
                return Json(new { success = false, error = "Please select a branch first." });
            }

            List<LabOrderItemRequestDto>? lineItems = null;
            try
            {
                lineItems = string.IsNullOrWhiteSpace(model.LineItemsJson)
                    ? null
                    : System.Text.Json.JsonSerializer.Deserialize<List<LabOrderItemRequestDto>>(model.LineItemsJson, new System.Text.Json.JsonSerializerOptions { PropertyNameCaseInsensitive = true });
                if (lineItems != null)
                {
                    foreach (var itm in lineItems)
                    {
                        if (string.IsNullOrWhiteSpace(itm.Type))
                        {
                            itm.Type = itm.IsPackage ? "P" : "I";
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                return Json(new { success = false, error = $"Invalid line items data: {ex.Message}" });
            }

            if (model.BookingDateTime < DateTime.Now.AddHours(-1))
            {
                return Json(new { success = false, error = "Booking Date & Time cannot be less than current Date & Time." });
            }

            if (lineItems == null || !lineItems.Any())
            {
                return Json(new { success = false, error = "Please select at least one investigation test." });
            }

            // Save uploaded files
            if (identificationFile != null && identificationFile.Length > 0)
            {
                var uploadsFolder = Path.Combine(env.WebRootPath, "uploads", "identifications");
                Directory.CreateDirectory(uploadsFolder);
                var fileName = $"{Guid.NewGuid()}{Path.GetExtension(identificationFile.FileName)}";
                var fullPath = Path.Combine(uploadsFolder, fileName);
                await using (var stream = new FileStream(fullPath, FileMode.Create))
                {
                    await identificationFile.CopyToAsync(stream);
                }
                model.IdentificationFilePath = $"/uploads/identifications/{fileName}";
            }

            if (profilePictureFile != null && profilePictureFile.Length > 0)
            {
                var uploadsFolder = Path.Combine(env.WebRootPath, "uploads", "patients");
                Directory.CreateDirectory(uploadsFolder);
                var fileName = $"{Guid.NewGuid()}{Path.GetExtension(profilePictureFile.FileName)}";
                var fullPath = Path.Combine(uploadsFolder, fileName);
                await using (var stream = new FileStream(fullPath, FileMode.Create))
                {
                    await profilePictureFile.CopyToAsync(stream);
                }
                model.PhotoPath = $"/uploads/patients/{fileName}";
            }

            // Reconcile Age / Date of Birth
            if (model.AgeMonths is > 12)
                return Json(new { success = false, error = "Month cannot exceed 12." });
            if (model.AgeDays is > 30)
                return Json(new { success = false, error = "Days cannot exceed 30." });
            if (model.AgeYears is < 0 or > 150)
                return Json(new { success = false, error = "Years must be between 0 and 150." });

            bool hasSaveAge = model.AgeYears.HasValue || model.AgeMonths.HasValue || model.AgeDays.HasValue;
            if (hasSaveAge)
            {
                int y = model.AgeYears ?? 0;
                int m = model.AgeMonths ?? 0;
                int d = model.AgeDays ?? 0;
                if (y > 0 || m > 0 || d > 0)
                {
                    model.DateOfBirth = EMR.Web.Utils.AgeCalculator.ToDateOfBirth(y, m, d);
                }
            }
            else if (model.DateOfBirth.HasValue)
            {
                var (y, m, d) = EMR.Web.Utils.AgeCalculator.FromDateOfBirth(model.DateOfBirth.Value);
                model.AgeYears = y;
                model.AgeMonths = m;
                model.AgeDays = d;
            }

            var patient = new PatientMaster
            {
                PatientId = model.PatientId,
                FirstName = model.FirstName,
                LastName = model.LastName,
                PhoneNumber = model.PhoneNumber,
                EmailId = model.EmailId,
                Gender = model.Gender,
                DateOfBirth = model.DateOfBirth,
                RelationId = model.RelationId,
                Salutation = model.Salutation,
                PhotoPath = model.PhotoPath,
                IdentificationFilePath = model.IdentificationFilePath,
                IdentificationTypeId = model.IdentificationTypeId,
                IdentificationNumber = model.IdentificationNumber,
                ReligionId = model.ReligionId,
                GuardianName = model.GuardianName,
                CountryId = model.CountryId,
                StateId = model.StateId,
                DistrictId = model.DistrictId,
                CityId = model.CityId,
                AreaId = model.AreaId,
                Address = string.IsNullOrWhiteSpace(model.Address) ? model.HomeCollectionAddress : model.Address,
                HomeCollectionAddress = string.IsNullOrWhiteSpace(model.HomeCollectionAddress) ? model.Address : model.HomeCollectionAddress,
                Latitude = model.Latitude,
                Longitude = model.Longitude,
                OccupationId = model.OccupationId,
                MaritalStatusId = model.MaritalStatusId,
                ReferralDoctorId = model.ReferralDoctorId,
                BloodGroup = model.BloodGroup,
                SecondaryPhoneNumber = model.SecondaryPhoneNumber,
                MiddleName = model.MiddleName,
                KnownAllergies = model.KnownAllergies,
                Remarks = model.Remarks,
                BranchId = branchId,
                CompanyId = 1,
                IsActive = true
            };

            int actualPatientId = model.PatientId;
            string actualPatientCode = model.PatientCode ?? string.Empty;
            if (model.PatientId == 0)
            {
                actualPatientId = await patientService.CreateDemographicsOnlyAsync(patient, User.GetUserId());
                patient.PatientId = actualPatientId;
                var createdPatient = await patientService.GetByIdAsync(actualPatientId);
                actualPatientCode = createdPatient?.PatientCode ?? string.Empty;
                await auditLogService.LogAsync("LAB", "Patient.Create", $"Registered patient: {patient.FirstName} {patient.LastName} for LAB.");
            }
            else
            {
                var existing = await patientService.GetByIdAsync(model.PatientId);
                if (string.IsNullOrWhiteSpace(model.IdentificationFilePath)) patient.IdentificationFilePath = existing?.IdentificationFilePath;
                if (string.IsNullOrWhiteSpace(model.PhotoPath)) patient.PhotoPath = existing?.PhotoPath;
                actualPatientCode = existing?.PatientCode ?? string.Empty;
                await patientService.UpdateDemographicsAsync(patient, User.GetUserId());
            }

            // Create Lab Order in DB and generate BillNo
            var labOrderReq = new LabOrderRequestDto
            {
                PatientId = actualPatientId,
                BranchId = branchId.Value,
                CollectionType = string.IsNullOrWhiteSpace(model.CollectionType) ? "Lab" : model.CollectionType,
                PhlebotomistId = model.CollectionType == "Home Collection" ? model.PhlebotomistId : null,
                BookingDate = model.BookingDateTime,
                Items = lineItems
            };

            var labOrderRes = await labOrderApiClient.CreateOrderAsync(labOrderReq);
            await labOrderApiClient.CreateSampleCollectionAsync(labOrderRes.LabOrderId, branchId.Value, patient.CompanyId);

            decimal totalAmount = lineItems.Sum(x => x.Price);
            await ledgerService.PostLabBillLedgerAsync(labOrderRes.LabOrderId, totalAmount, branchId, patient.CompanyId, User.GetUserId(), labOrderRes.BillNo);

            // Process Payment
            SavePaymentResult? paymentResult = null;
            if (!string.IsNullOrWhiteSpace(paymentDataJson))
            {
                var paymentReq = System.Text.Json.JsonSerializer.Deserialize<SavePaymentRequest>(paymentDataJson, new System.Text.Json.JsonSerializerOptions { PropertyNameCaseInsensitive = true });
                if (paymentReq != null)
                {
                    paymentReq.ModuleCode = "LAB";
                    paymentReq.ModuleRefId = labOrderRes.LabOrderId;
                    paymentReq.OPDServiceId = labOrderRes.LabOrderId;
                    paymentReq.PatientId = actualPatientId;
                    paymentReq.BranchId = branchId.Value;
                    paymentReq.SubTotal = totalAmount;

                    // Map created LabOrderItemIds to PaymentLineItem rows so ModuleLineRefId accurately points to LabOrderItemId
                    var con = dbContext.Database.GetDbConnection();
                    if (con.State != System.Data.ConnectionState.Open)
                        await con.OpenAsync();

                    var createdItems = (await con.QueryAsync<dynamic>(@"
                        SELECT LabOrderItemId, InvestigationId
                        FROM dbo.LabOrderItem
                        WHERE LabOrderId = @LabOrderId",
                        new { LabOrderId = labOrderRes.LabOrderId })).ToList();

                    if (paymentReq.LineItems != null && paymentReq.LineItems.Any())
                    {
                        foreach (var li in paymentReq.LineItems)
                        {
                            var matchingCreated = createdItems.FirstOrDefault(ci => (int)ci.InvestigationId == li.ModuleLineRefId);
                            if (matchingCreated != null)
                            {
                                li.ModuleLineRefId = (int)matchingCreated.LabOrderItemId;
                            }
                        }
                    }

                    paymentResult = await paymentService.SavePaymentAsync(paymentReq, User.GetUserId());
                    if (paymentResult != null && !paymentResult.Success)
                    {
                        return Json(new { success = false, error = paymentResult.Error ?? "Failed to save payment." });
                    }
                }
            }

            // ── Auto-collect samples if HospitalSettings.IsSampleCollectionMandatory == NO ──
            try
            {
                await sampleCollectionApiClient.AutoCollectIfNotMandatoryAsync(labOrderRes.LabOrderId);
            }
            catch
            {
                // Non-blocking catch to ensure billing and payment completion is not hindered
            }

            string patientFullName = ((patient.Salutation ?? "") + " " + patient.FirstName + " " + patient.LastName).Trim();

            // ── TRIGGER BACKGROUND EMAIL NOTIFICATION IF CONFIGURED ─────────────────
            var savedLabOrderId = labOrderRes.LabOrderId;
            var savedBillNo = labOrderRes.BillNo;
            var safeBillNo = savedBillNo?.Replace("/", "_").Replace("\\", "_");
            var patientEmail = patient.EmailId;
            var patientNameStr = patientFullName;
            
            if (savedLabOrderId > 0)
            {
                var bId = branchId.Value;
                var hostUrl = $"{Request.Scheme}://{Request.Host}{Request.PathBase}";
                var serviceScopeFactory = HttpContext.RequestServices.GetRequiredService<IServiceScopeFactory>();

                _ = Task.Run(async () =>
                {
                    using var scope = serviceScopeFactory.CreateScope();
                    var db = scope.ServiceProvider.GetRequiredService<ApplicationDbContext>();
                    var emailSvc = scope.ServiceProvider.GetRequiredService<IEmailService>();
                    var logger = scope.ServiceProvider.GetRequiredService<ILogger<LabOrderBookingController>>();

                    string? tempPdfPath = null;
                    try
                    {
                        // 1. Generate Lab Bill PDF via headless Chrome so both WhatsApp and Email can use it
                        if (!string.IsNullOrWhiteSpace(safeBillNo))
                        {
                            try
                            {
                                tempPdfPath = Path.Combine(Path.GetTempPath(), $"Lab_Bill_{safeBillNo}.pdf");
                                var secret = "lab_print_" + savedLabOrderId.ToString();
                                var billUrl = $"{hostUrl}/LabOrderBooking/PrintBillAnonymous?labOrderId={savedLabOrderId}&secret={Uri.EscapeDataString(secret)}";
                                logger.LogInformation($"[LAB-NOTIF] Generating PDF for lab bill. URL: {billUrl}, Output: {tempPdfPath}");
                                var chromeArgs = $"--headless --disable-gpu --ignore-certificate-errors --print-to-pdf=\"{tempPdfPath}\" \"{billUrl}\"";

                                using var process = new System.Diagnostics.Process();
                                process.StartInfo.FileName = OperatingSystem.IsWindows() ? "chrome" : "google-chrome";
                                if (OperatingSystem.IsMacOS()) process.StartInfo.FileName = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
                                process.StartInfo.Arguments = chromeArgs;
                                process.StartInfo.UseShellExecute = true;
                                process.Start();
                                await process.WaitForExitAsync();
                            }
                            catch (Exception ex)
                            {
                                logger.LogWarning(ex, "[LAB-NOTIF] Headless chrome PDF generation failed for LabOrderId {Id}", savedLabOrderId);
                            }
                        }

                        // 2. Trigger WhatsApp notification (attaches generated bill PDF)
                        try
                        {
                            var whatsAppSvc = scope.ServiceProvider.GetRequiredService<IWhatsAppService>();
                            await whatsAppSvc.TriggerLabBillWhatsAppAsync(bId, savedLabOrderId, tempPdfPath, hostUrl);
                        }
                        catch (Exception ex)
                        {
                            logger.LogError(ex, "[WhatsApp] Error sending LAB bill notification for LabOrderId {Id}", savedLabOrderId);
                        }

                        // 3. Trigger Email notification (if patient has email configured)
                        if (!string.IsNullOrWhiteSpace(patientEmail))
                        {
                            try
                            {
                                var hs = await db.HospitalSettings.FirstOrDefaultAsync(s => s.BranchId == bId && s.IsActive);
                                if (hs != null && hs.LabEmailNotificationRequired)
                                {
                                    string subj = $"Your Lab Order Bill [{savedBillNo}] - {hs.HospitalName}";
                                    string body = $@"
<!DOCTYPE html>
<html>
<head>
<meta charset=""utf-8"">
<title>Your Lab Bill</title>
<style>
  body {{ font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; background-color: #f4f7f6; margin: 0; padding: 20px; }}
  .container {{ max-width: 600px; margin: 0 auto; background: #ffffff; border-radius: 8px; overflow: hidden; box-shadow: 0 4px 6px rgba(0,0,0,0.05); }}
  .header {{ background-color: #4a6ee0; color: #ffffff; padding: 20px; text-align: center; }}
  .header h1 {{ margin: 0; font-size: 24px; }}
  .content {{ padding: 30px; color: #333333; line-height: 1.6; }}
  .greeting {{ font-size: 18px; font-weight: 600; margin-bottom: 20px; color: #2c3e50; }}
  .info-box {{ background-color: #f8f9fa; border-left: 4px solid #4a6ee0; padding: 15px; margin: 20px 0; border-radius: 4px; }}
  .info-box p {{ margin: 5px 0; }}
  .footer {{ background-color: #f8f9fa; padding: 20px; text-align: center; color: #777777; font-size: 14px; border-top: 1px solid #eeeeee; }}
</style>
</head>
<body>
<div class=""container"">
  <div class=""header"">
    <h1>{hs.HospitalName}</h1>
  </div>
  <div class=""content"">
    <div class=""greeting"">Dear {patientNameStr},</div>
    <p>Thank you for choosing <strong>{hs.HospitalName}</strong> for your healthcare needs.</p>
    <div class=""info-box"">
      <p><strong>Bill No:</strong> {savedBillNo}</p>
      <p><strong>Date:</strong> {DateTime.Now:dd MMM yyyy}</p>
    </div>
    <p>Please find your detailed lab order bill attached to this email as a PDF document.</p>
    <p>If you have any questions or require further assistance, please do not hesitate to contact us.</p>
    <p>Wishing you the best of health,<br/><br/><strong>The {hs.HospitalName} Team</strong></p>
  </div>
  <div class=""footer"">
    &copy; {DateTime.Now.Year} {hs.HospitalName}. All rights reserved.<br>
    {hs.Address}
  </div>
</div>
</body>
</html>";

                                    if (!string.IsNullOrEmpty(tempPdfPath) && System.IO.File.Exists(tempPdfPath))
                                    {
                                        var attachment = new System.Net.Mail.Attachment(tempPdfPath, "application/pdf");
                                        await emailSvc.SendEmailAsync(bId, patientEmail, subj, body, new[] { attachment });
                                    }
                                    else
                                    {
                                        await emailSvc.SendEmailAsync(bId, patientEmail, subj, body);
                                    }
                                }
                            }
                            catch (Exception ex)
                            {
                                logger.LogError(ex, "[DEBUG-LAB-EMAIL] Error sending lab email notification.");
                            }
                        }
                    }
                    finally
                    {
                        if (!string.IsNullOrEmpty(tempPdfPath) && System.IO.File.Exists(tempPdfPath))
                        {
                            try { System.IO.File.Delete(tempPdfPath); } catch { }
                        }
                    }
                });
            }
            // ────────────────────────────────────────────────────────────────────────
            // ── CHECK IF BARCODE SHOULD BE PRINTED AT BILLING ──────────────────────
            bool showPrintBarcode = false;
            if (branchId.HasValue)
            {
                var settings = await dbContext.HospitalSettings.FirstOrDefaultAsync(s => s.BranchId == branchId.Value && s.IsActive);
                if (settings != null)
                {
                    showPrintBarcode = settings.BarcodeGenerateAtBilling;
                }
            }
            // ────────────────────────────────────────────────────────────────────────

            return Json(new
            {
                success = true,
                labOrderId = labOrderRes.LabOrderId,
                billNo = labOrderRes.BillNo,
                tokenNo = paymentResult?.TokenNo,
                patientCode = actualPatientCode,
                patientName = patientFullName,
                totalAmount = totalAmount,
                netAmount = paymentResult?.NetAmount ?? totalAmount,
                totalPaid = paymentResult?.TotalPaid ?? 0,
                balanceDue = paymentResult?.BalanceDue ?? totalAmount,
                paymentStatus = paymentResult?.PaymentStatus ?? "U",
                showPrintBarcode = showPrintBarcode
            });
            }
            catch (Exception ex)
            {
                return Json(new { success = false, error = $"An error occurred while saving the booking: {ex.Message}" });
            }
        }

        private async Task PopulateSelectLists(LabOrderBookingViewModel model)
        {
            var branchId = User.GetCurrentBranchId();

            model.RelationOptions = await dbContext.RelationMasters
                .Where(x => x.IsActive)
                .OrderBy(x => x.SortOrder).ThenBy(x => x.RelationName)
                .Select(x => new SelectListItem(x.RelationName, x.RelationId.ToString()))
                .ToListAsync();

            model.IdentificationTypeOptions = await dbContext.IdentificationTypeMasters
                .Where(i => i.IsActive)
                .OrderBy(i => i.IdentificationTypeName)
                .Select(i => new SelectListItem(i.IdentificationTypeName, i.IdentificationTypeId.ToString()))
                .ToListAsync();

            model.ReligionOptions = await dbContext.ReligionMasters
                .Where(r => r.IsActive)
                .OrderBy(r => r.ReligionName)
                .Select(r => new SelectListItem(r.ReligionName, r.ReligionId.ToString()))
                .ToListAsync();

            model.OccupationOptions = await dbContext.OccupationMasters
                .Where(o => o.IsActive)
                .OrderBy(o => o.OccupationName)
                .Select(o => new SelectListItem(o.OccupationName, o.OccupationId.ToString()))
                .ToListAsync();

            model.MaritalStatusOptions = await dbContext.MaritalStatusMasters
                .Where(m => m.IsActive)
                .OrderBy(m => m.StatusName)
                .Select(m => new SelectListItem(m.StatusName, m.MaritalStatusId.ToString()))
                .ToListAsync();

            model.ReferralDoctorOptions = await dbContext.ReferralDoctorMasters
                .Where(r => r.IsActive)
                .OrderBy(r => r.DoctorName)
                .Select(r => new SelectListItem(r.DoctorName, r.ReferralDoctorId.ToString()))
                .ToListAsync();

            var countries = await countryService.GetActiveAsync();
            model.CountryOptions = countries
                .Select(c => new SelectListItem(c.CountryName, c.CountryId.ToString()))
                .ToList();

            if (model.CountryId.HasValue)
            {
                var states = await stateService.GetByCountryAsync(model.CountryId.Value);
                model.StateOptions = states
                    .Where(s => s.IsActive)
                    .Select(s => new SelectListItem(s.StateName, s.StateId.ToString()))
                    .ToList();
            }

            if (model.StateId.HasValue)
            {
                var districts = await districtService.GetByStateAsync(model.StateId.Value);
                model.DistrictOptions = districts
                    .Where(d => d.IsActive)
                    .Select(d => new SelectListItem(d.DistrictName, d.DistrictId.ToString()))
                    .ToList();
            }

            if (model.DistrictId.HasValue)
            {
                var cities = await cityService.GetByDistrictAsync(model.DistrictId.Value);
                model.CityOptions = cities
                    .Where(c => c.IsActive)
                    .Select(c => new SelectListItem(c.CityName, c.CityId.ToString()))
                    .ToList();
            }

            if (model.CityId.HasValue)
            {
                var areas = await areaService.GetByCityAsync(model.CityId.Value);
                model.AreaOptions = areas
                    .Where(a => a.IsActive)
                    .Select(a => new SelectListItem(a.AreaName, a.AreaId.ToString()))
                    .ToList();
            }
            var departments = await labOrderApiClient.GetDepartmentsAsync();
            model.DepartmentOptions = departments
                .Select(x => new SelectListItem { Value = x.DepartmentId.ToString(), Text = x.DepartmentName })
                .ToList();

            var categories = await labOrderApiClient.GetCategoriesAsync();
            model.CategoryOptions = categories
                .Select(x => new SelectListItem { Value = x.CategoryId.ToString(), Text = x.CategoryName })
                .ToList();

            var subCategories = await labOrderApiClient.GetSubCategoriesAsync();
            model.SubCategoryOptions = subCategories
                .Select(x => new SelectListItem { Value = x.SubCategoryId.ToString(), Text = x.SubCategoryName })
                .ToList();

            model.PhlebotomistOptions = await dbContext.Users
                .Where(u => u.IsPathologist && u.IsActive)
                .OrderBy(u => u.FullName ?? u.Username)
                .Select(u => new SelectListItem { Value = u.Id.ToString(), Text = u.FullName ?? u.Username })
                .ToListAsync();
        }

        [HttpGet]
        public async Task<IActionResult> GetAvailableInvestigations(int? branchId, int? departmentId, int? categoryId, int? subCategoryId, string? gender = null, int? ageInYears = null)
        {
            int resolvedBranchId = branchId.HasValue && branchId.Value > 0
                ? branchId.Value
                : (HttpContext.Session.GetInt32("SelectedBranchId") ?? User.GetCurrentBranchId() ?? 1);

            var tests = await labOrderApiClient.GetAvailableInvestigationsAsync(resolvedBranchId, departmentId, categoryId, subCategoryId, gender, ageInYears);

            foreach (var t in tests)
            {
                if (t.IsProfileTest && t.ProfileId.HasValue && t.ProfileId.Value > 0)
                {
                    string encryptedToken = encryptionService.EncryptParameters(new Dictionary<string, string?> { ["id"] = t.ProfileId.Value.ToString() });
                    t.ProfileEncryptedUrl = $"/LabInvestigationProfiles/Details?q={encryptedToken}";
                }
            }

            return Json(new { isSuccess = true, data = tests });
        }

        [HttpGet]
        public async Task<IActionResult> GetProfileDetails(int? profileId, int? testId)
        {
            try
            {
                var con = dbContext.Database.GetDbConnection();
                if (con.State != System.Data.ConnectionState.Open)
                    await con.OpenAsync();

                var profile = await con.QueryFirstOrDefaultAsync<dynamic>(@"
                    SELECT TOP 1 h.Profile_ID, h.Profile_Code, h.Profile_Name, h.Profile_Type, h.Test_ID, h.MRP, h.Profile_TAT_Hours
                    FROM LabInvestigationProfileHeader h
                    WHERE ((@ProfileId IS NOT NULL AND h.Profile_ID = @ProfileId)
                       OR (@TestId IS NOT NULL AND (h.Test_ID = @TestId OR h.Profile_Name = (SELECT TOP 1 Test_Name FROM LabInvestigationMaster WHERE Test_ID = @TestId))))
                       AND h.IsDeleted = 0",
                    new { ProfileId = profileId, TestId = testId });

                if (profile == null)
                {
                    return Json(new { success = false, message = "Profile details not found." });
                }

                int resolvedProfileId = (int)profile.Profile_ID;
                string encryptedToken = encryptionService.EncryptParameters(new Dictionary<string, string?> { ["id"] = resolvedProfileId.ToString() });
                string fullUrl = $"/LabInvestigationProfiles/Details?q={encryptedToken}";

                var tests = await con.QueryAsync<dynamic>(@"
                    SELECT d.Detail_ID, d.Test_ID, d.Sequence,
                           t.Test_Code, t.Test_Name, t.TAT_Hours, t.Reporting_Type,
                           COALESCE(t.MRP, 0) as MRP,
                           dept.DeptName as DepartmentName,
                           cat.Category_Name as CategoryName
                    FROM LabInvestigationProfileDetail d
                    JOIN LabInvestigationMaster t ON t.Test_ID = d.Test_ID
                    LEFT JOIN DepartmentMaster dept ON dept.DeptId = t.Department_ID
                    LEFT JOIN LabTestCategoryMaster cat ON cat.Category_ID = t.Category_ID
                    WHERE d.Profile_ID = @ProfileId AND d.IsDeleted = 0
                    ORDER BY d.Sequence",
                    new { ProfileId = resolvedProfileId });

                return Json(new
                {
                    success = true,
                    profileId = resolvedProfileId,
                    profileCode = (string)profile.Profile_Code,
                    profileName = (string)profile.Profile_Name,
                    profileType = profile.Profile_Type?.ToString() == "2" ? "Package" : "Profile",
                    tatHours = profile.Profile_TAT_Hours,
                    mrp = profile.MRP,
                    profileUrl = fullUrl,
                    testCount = tests.Count(),
                    tests = tests.Select(x => new
                    {
                        testId = (int)x.Test_ID,
                        sequence = x.Sequence,
                        testCode = (string)x.Test_Code,
                        testName = (string)x.Test_Name,
                        reportingType = (string)(x.Reporting_Type ?? "Numeric"),
                        categoryName = (string)(x.CategoryName ?? ""),
                        departmentName = (string)(x.DepartmentName ?? ""),
                        mrp = (decimal)(x.MRP ?? 0)
                    })
                });
            }
            catch (Exception ex)
            {
                return Json(new { success = false, message = ex.Message });
            }
        }

        [HttpGet]
        public async Task<IActionResult> GetCategoriesForDropdown(int? departmentId)
        {
            var categories = await labOrderApiClient.GetCategoriesAsync(departmentId);
            return Json(categories.Select(c => new { value = c.CategoryId, text = c.CategoryName }));
        }

        [HttpGet]
        public async Task<IActionResult> GetSubCategoriesForDropdown(int? categoryId)
        {
            var subCategories = await labOrderApiClient.GetSubCategoriesAsync(categoryId);
            return Json(subCategories.Select(s => new { value = s.SubCategoryId, text = s.SubCategoryName }));
        }

        [HttpGet]
        public async Task<IActionResult> B2COrderList(string? fromDate, string? toDate, string? search, int page = 1, int pageSize = 10)
        {
            int branchId = HttpContext.Session.GetInt32("SelectedBranchId") ?? 1;

            var result = await labOrderApiClient.GetPagedOrdersAsync(branchId, fromDate, toDate, search, page, pageSize);

            var vm = new LabOrderPagedListViewModel
            {
                Items = result?.Items ?? new List<LabOrderListItemDto>(),
                Stats = result?.Stats ?? new LabOrderStatsDto(),
                TotalCount = result?.TotalCount ?? 0,
                Page = page,
                PageSize = pageSize,
                FromDate = fromDate ?? DateTime.Today.AddDays(-30).ToString("yyyy-MM-dd"),
                ToDate = toDate ?? DateTime.Today.ToString("yyyy-MM-dd"),
                Search = search
            };

            return View(vm);
        }

        [HttpGet]
        public async Task<IActionResult> GetOrderDetail(int id)
        {
            if (id <= 0) return BadRequest("Invalid order ID.");
            var detail = await labOrderApiClient.GetOrderDetailAsync(id);
            if (detail == null) return NotFound();
            return Json(detail);
        }

        [HttpGet]
        public async Task<IActionResult> PrintBill(int labOrderId)
        {
            if (labOrderId <= 0) return BadRequest("Invalid lab order ID.");

            var detail = await labOrderApiClient.GetOrderDetailAsync(labOrderId);
            if (detail == null) return NotFound("Lab order not found.");

            var branchId = detail.BranchId;

            // Fetch hospital settings for this branch
            var settings = await dbContext.HospitalSettings
                .Where(s => s.BranchId == branchId && s.IsActive)
                .FirstOrDefaultAsync();

            // Line discounts: if item-level discounts exist (from PaymentLineItem), use them directly.
            // Non-discountable items have DiscountAmount == 0.
            // Proportional split is only used as a fallback for legacy orders with no line-level discount data.
            decimal grossAmount = detail.Items.Sum(i => i.Price);
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

            var vm = new PrintBillViewModel
            {
                IsActive              = detail.IsActive,
                // Hospital
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

                // Patient
                PatientName  = detail.PatientName,
                PatientCode  = detail.PatientCode,
                PhoneNumber  = detail.PhoneNumber,
                EmailId      = detail.EmailId,
                Gender       = detail.Gender,
                Age          = detail.Age,
                DateOfBirth  = detail.DateOfBirth,
                Address      = detail.Address,

                // Order
                LabOrderId        = detail.LabOrderId,
                BillNo            = detail.BillNo,
                TokenNo           = detail.TokenNo,
                OrderDate         = detail.OrderDate,
                CreatedDate       = detail.CreatedDate,
                BookingDate       = detail.BookingDate,
                CollectionType    = detail.CollectionType,
                PhlebotomistName  = detail.PhlebotomistName,
                CreatedByName     = detail.CreatedByName,

                // Payment
                GrossAmount     = grossAmount,
                DiscountAmount  = headerDiscount,
                RoundOffAmount  = detail.RoundOffAmount,
                GrandTotal      = detail.NetAmount,
                ReceivedAmount  = detail.TotalPaid,
                Balance         = detail.BalanceDue,
                PaymentStatus   = detail.PaymentStatus,

                LineItems = lineItems,
                Payments  = detail.Payments.Select(p => new PrintBillPaymentRow
                {
                    MethodName     = p.MethodName,
                    PaidAmount     = p.PaidAmount,
                    TransactionRef = p.TransactionRef,
                    ReceiptNo      = p.ReceiptNo
                }).ToList()
            };

            return View(vm);
        }

        [AllowAnonymous]
        [HttpGet]
        public async Task<IActionResult> SearchAddressGeoSuggestions(
            [FromQuery] string query,
            [FromQuery] string? country,
            [FromQuery] string? state,
            [FromQuery] string? district,
            [FromQuery] string? city,
            [FromServices] IHttpClientFactory httpFactory)
        {
            if (string.IsNullOrWhiteSpace(query) || query.Trim().Length < 2)
            {
                return Json(Array.Empty<object>());
            }

            try
            {
                var client = httpFactory.CreateClient();
                client.Timeout = TimeSpan.FromSeconds(5);
                client.DefaultRequestHeaders.Add("User-Agent", "eClinicPlus-EMR/1.0 (AddressSearch)");

                string cleanQuery = query.Trim();

                // Helper to clean dropdown values
                static string CleanGeo(string? val)
                {
                    if (string.IsNullOrWhiteSpace(val)) return "";
                    val = val.Trim();
                    if (val.StartsWith("--", StringComparison.Ordinal)) return "";
                    return val;
                }

                string cleanCountry = CleanGeo(country);
                string cleanState = CleanGeo(state);
                string cleanDistrict = CleanGeo(district);
                string cleanCity = CleanGeo(city);

                // Stop words that do not count as distinctive address identifiers
                var stopWords = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
                {
                    "para", "pally", "sarani", "road", "rd", "street", "st", "lane", "ln", "avenue", "ave",
                    "block", "blk", "bazar", "bazaar", "market", "mkt", "nagar", "colony", "near", "opp",
                    "opposite", "beside", "behind", "dist", "district", "po", "ps", "vill", "village",
                    "more", "crossing", "chowk", "ground", "pond", "pukur", "flat", "apartment", "floor",
                    "house", "building", "sector", "sec", "west", "bengal", "india", "hno", "house"
                };
                if (!string.IsNullOrWhiteSpace(cleanDistrict)) stopWords.Add(cleanDistrict);
                if (!string.IsNullOrWhiteSpace(cleanCity)) stopWords.Add(cleanCity);
                if (!string.IsNullOrWhiteSpace(cleanState)) stopWords.Add(cleanState);
                if (!string.IsNullOrWhiteSpace(cleanCountry)) stopWords.Add(cleanCountry);

                var rawWords = cleanQuery.Split(new[] { ' ', ',', '-', '/', '.' }, StringSplitOptions.RemoveEmptyEntries);
                var distinctiveTokens = rawWords
                    .Where(w => w.Length >= 3 && !stopWords.Contains(w) && !w.All(char.IsDigit))
                    .ToList();

                var candidates = new List<GeoSuggestionItem>();

                // Helper to geocode a 6-digit pincode to lat/lon
                async Task<(double lat, double lon)> GeocodePincodeAsync(string pin)
                {
                    try
                    {
                        var geoPinUrl = $"https://photon.komoot.io/api/?q={pin}&limit=1";
                        var geoResp = await client.GetAsync(geoPinUrl);
                        if (geoResp.IsSuccessStatusCode)
                        {
                            var geoJson = await geoResp.Content.ReadAsStringAsync();
                            using var geoDoc = JsonDocument.Parse(geoJson);
                            if (geoDoc.RootElement.TryGetProperty("features", out var fArr) && fArr.ValueKind == JsonValueKind.Array && fArr.GetArrayLength() > 0)
                            {
                                var c = fArr[0].GetProperty("geometry").GetProperty("coordinates");
                                return (c[1].GetDouble(), c[0].GetDouble());
                            }
                        }

                        // Nominatim fallback for pincode
                        var nomPinUrl = $"https://nominatim.openstreetmap.org/search?postalcode={pin}&country=India&format=json&limit=1";
                        var nomResp = await client.GetAsync(nomPinUrl);
                        if (nomResp.IsSuccessStatusCode)
                        {
                            var nomJson = await nomResp.Content.ReadAsStringAsync();
                            using var nomDoc = JsonDocument.Parse(nomJson);
                            if (nomDoc.RootElement.ValueKind == JsonValueKind.Array && nomDoc.RootElement.GetArrayLength() > 0)
                            {
                                var first = nomDoc.RootElement[0];
                                if (double.TryParse(first.GetProperty("lat").GetString(), System.Globalization.NumberStyles.Any, System.Globalization.CultureInfo.InvariantCulture, out double nLat) &&
                                    double.TryParse(first.GetProperty("lon").GetString(), System.Globalization.NumberStyles.Any, System.Globalization.CultureInfo.InvariantCulture, out double nLon))
                                {
                                    return (nLat, nLon);
                                }
                            }
                        }
                    }
                    catch { }
                    return (0, 0);
                }

                // 1. Pincode Direct Search (if 6-digit pincode is typed)
                var pinMatch = System.Text.RegularExpressions.Regex.Match(cleanQuery, @"\b(\d{6})\b");
                if (pinMatch.Success)
                {
                    string pincode = pinMatch.Groups[1].Value;
                    try
                    {
                        var pinUrl = $"https://api.postalpincode.in/pincode/{pincode}";
                        var pinResp = await client.GetAsync(pinUrl);
                        if (pinResp.IsSuccessStatusCode)
                        {
                            var pinJson = await pinResp.Content.ReadAsStringAsync();
                            using var pinDoc = JsonDocument.Parse(pinJson);
                            var rootArray = pinDoc.RootElement;
                            if (rootArray.ValueKind == JsonValueKind.Array && rootArray.GetArrayLength() > 0)
                            {
                                var firstObj = rootArray[0];
                                string status = firstObj.TryGetProperty("Status", out var st) ? st.GetString() ?? "" : "";
                                if (string.Equals(status, "Success", StringComparison.OrdinalIgnoreCase) &&
                                    firstObj.TryGetProperty("PostOffice", out var poArray) &&
                                    poArray.ValueKind == JsonValueKind.Array)
                                {
                                    var (pLat, pLon) = await GeocodePincodeAsync(pincode);
                                    string otherKeywords = cleanQuery.Replace(pincode, "").Trim(' ', ',');

                                    foreach (var po in poArray.EnumerateArray())
                                    {
                                        string poName = po.TryGetProperty("Name", out var pon) ? pon.GetString() ?? "" : "";
                                        string poDistrict = po.TryGetProperty("District", out var pod) ? pod.GetString() ?? "" : "";
                                        string poState = po.TryGetProperty("State", out var pos) ? pos.GetString() ?? "" : "";
                                        string poCountry = po.TryGetProperty("Country", out var poc) ? poc.GetString() ?? "India" : "India";

                                        if (!string.IsNullOrWhiteSpace(cleanState) && !poState.Equals(cleanState, StringComparison.OrdinalIgnoreCase))
                                            continue;
                                        if (!string.IsNullOrWhiteSpace(cleanDistrict) && !poDistrict.Equals(cleanDistrict, StringComparison.OrdinalIgnoreCase))
                                            continue;

                                        int score = 400;
                                        if (!string.IsNullOrWhiteSpace(otherKeywords) && poName.Contains(otherKeywords, StringComparison.OrdinalIgnoreCase))
                                            score += 100;

                                        string displayName = !string.IsNullOrWhiteSpace(otherKeywords) ? $"{otherKeywords}, {poName} - {pincode}" : $"{poName} - {pincode}";
                                        string secondary = $"{poDistrict}, {poState}, {poCountry}";
                                        string fullAddr = $"{displayName}, {secondary}".TrimStart(',', ' ');

                                        candidates.Add(new GeoSuggestionItem
                                        {
                                            Name = displayName,
                                            Secondary = secondary,
                                            FullAddress = fullAddr,
                                            Latitude = pLat,
                                            Longitude = pLon,
                                            City = poDistrict,
                                            District = poDistrict,
                                            State = poState,
                                            Postcode = pincode,
                                            Country = poCountry,
                                            Score = score
                                        });
                                    }
                                }
                            }
                        }
                    }
                    catch { }
                }

                // 2. India Post PostOffice Lookup on Distinctive Words (e.g. "Unsani", "Santragachi", "Kadamtala")
                var wordsToLookup = new List<string>();
                if (distinctiveTokens.Count > 0)
                {
                    wordsToLookup.AddRange(distinctiveTokens.Take(2));
                }
                else if (rawWords.Length > 0 && !rawWords[0].All(char.IsDigit) && rawWords[0].Length >= 3)
                {
                    wordsToLookup.Add(rawWords[0]);
                }

                foreach (var word in wordsToLookup.Distinct(StringComparer.OrdinalIgnoreCase))
                {
                    try
                    {
                        var poResp = await client.GetAsync($"https://api.postalpincode.in/postoffice/{Uri.EscapeDataString(word)}");
                        if (poResp.IsSuccessStatusCode)
                        {
                            var poJson = await poResp.Content.ReadAsStringAsync();
                            using var poDoc = JsonDocument.Parse(poJson);
                            var root = poDoc.RootElement;
                            if (root.ValueKind == JsonValueKind.Array && root.GetArrayLength() > 0)
                            {
                                var first = root[0];
                                if (first.TryGetProperty("Status", out var st) && string.Equals(st.GetString(), "Success", StringComparison.OrdinalIgnoreCase) &&
                                    first.TryGetProperty("PostOffice", out var pos) && pos.ValueKind == JsonValueKind.Array)
                                {
                                    foreach (var po in pos.EnumerateArray())
                                    {
                                        string poName = po.TryGetProperty("Name", out var pon) ? pon.GetString() ?? "" : "";
                                        string poDistrict = po.TryGetProperty("District", out var pod) ? pod.GetString() ?? "" : "";
                                        string poState = po.TryGetProperty("State", out var postt) ? postt.GetString() ?? "" : "";
                                        string poPincode = po.TryGetProperty("Pincode", out var popc) ? popc.GetString() ?? "" : "";
                                        string poCountry = po.TryGetProperty("Country", out var pocnt) ? pocnt.GetString() ?? "India" : "India";

                                        if (!string.IsNullOrWhiteSpace(cleanState) && !poState.Equals(cleanState, StringComparison.OrdinalIgnoreCase))
                                            continue;
                                        if (!string.IsNullOrWhiteSpace(cleanDistrict) && !poDistrict.Equals(cleanDistrict, StringComparison.OrdinalIgnoreCase))
                                            continue;

                                        var (poLat, poLon) = await GeocodePincodeAsync(poPincode);

                                        // If user typed custom sub-locality / lane along with this area (e.g. "Unsani Kachari para")
                                        if (!cleanQuery.Equals(poName, StringComparison.OrdinalIgnoreCase) && cleanQuery.Length > poName.Length)
                                        {
                                            candidates.Add(new GeoSuggestionItem
                                            {
                                                Name = cleanQuery,
                                                Secondary = $"{poName}, {poDistrict}, {poState} {poPincode}, {poCountry}",
                                                FullAddress = $"{cleanQuery}, {poName}, {poDistrict}, {poState} {poPincode}, {poCountry}",
                                                Latitude = poLat,
                                                Longitude = poLon,
                                                City = poDistrict,
                                                District = poDistrict,
                                                State = poState,
                                                Postcode = poPincode,
                                                Country = poCountry,
                                                Score = 350
                                            });
                                        }

                                        candidates.Add(new GeoSuggestionItem
                                        {
                                            Name = $"{poName} - {poPincode}",
                                            Secondary = $"{poDistrict}, {poState}, {poCountry}",
                                            FullAddress = $"{poName}, {poDistrict}, {poState} {poPincode}, {poCountry}",
                                            Latitude = poLat,
                                            Longitude = poLon,
                                            City = poDistrict,
                                            District = poDistrict,
                                            State = poState,
                                            Postcode = poPincode,
                                            Country = poCountry,
                                            Score = 300
                                        });
                                    }
                                }
                            }
                        }
                    }
                    catch { }
                }

                // 3. Nominatim (OpenStreetMap) Structured Search
                try
                {
                    string nomQuery = cleanQuery;
                    if (!string.IsNullOrWhiteSpace(cleanDistrict) && !nomQuery.Contains(cleanDistrict, StringComparison.OrdinalIgnoreCase))
                        nomQuery += $" {cleanDistrict}";
                    if (!string.IsNullOrWhiteSpace(cleanState) && !nomQuery.Contains(cleanState, StringComparison.OrdinalIgnoreCase))
                        nomQuery += $" {cleanState}";

                    var nomUrl = $"https://nominatim.openstreetmap.org/search?q={Uri.EscapeDataString(nomQuery)}&format=json&addressdetails=1&countrycodes=in&limit=8";
                    var nomResp = await client.GetAsync(nomUrl);
                    if (nomResp.IsSuccessStatusCode)
                    {
                        var nomJson = await nomResp.Content.ReadAsStringAsync();
                        using var nomDoc = JsonDocument.Parse(nomJson);
                        if (nomDoc.RootElement.ValueKind == JsonValueKind.Array)
                        {
                            foreach (var item in nomDoc.RootElement.EnumerateArray())
                            {
                                string displayName = item.TryGetProperty("display_name", out var dn) ? dn.GetString() ?? "" : "";
                                string name = item.TryGetProperty("name", out var n) ? n.GetString() ?? "" : "";
                                if (string.IsNullOrWhiteSpace(name)) name = displayName.Split(',').FirstOrDefault()?.Trim() ?? "";

                                if (!double.TryParse(item.GetProperty("lat").GetString(), System.Globalization.NumberStyles.Any, System.Globalization.CultureInfo.InvariantCulture, out double lat) ||
                                    !double.TryParse(item.GetProperty("lon").GetString(), System.Globalization.NumberStyles.Any, System.Globalization.CultureInfo.InvariantCulture, out double lon))
                                {
                                    continue;
                                }

                                string road = "", suburb = "", county = "", stateVal = "", postVal = "", countryVal = "India";
                                if (item.TryGetProperty("address", out var addr) && addr.ValueKind == JsonValueKind.Object)
                                {
                                    if (addr.TryGetProperty("road", out var r)) road = r.GetString() ?? "";
                                    if (addr.TryGetProperty("suburb", out var sb)) suburb = sb.GetString() ?? "";
                                    if (addr.TryGetProperty("neighbourhood", out var nh) && string.IsNullOrWhiteSpace(suburb)) suburb = nh.GetString() ?? "";
                                    if (addr.TryGetProperty("county", out var co)) county = co.GetString() ?? "";
                                    if (addr.TryGetProperty("state_district", out var sd) && string.IsNullOrWhiteSpace(county)) county = sd.GetString() ?? "";
                                    if (addr.TryGetProperty("state", out var stt)) stateVal = stt.GetString() ?? "";
                                    if (addr.TryGetProperty("postcode", out var pc)) postVal = pc.GetString() ?? "";
                                    if (addr.TryGetProperty("country", out var cnt)) countryVal = cnt.GetString() ?? "India";
                                }

                                // Relevance Scoring
                                int score = 150;
                                int matchedDistinctive = 0;
                                if (distinctiveTokens.Count > 0)
                                {
                                    foreach (var token in distinctiveTokens)
                                    {
                                        if (displayName.Contains(token, StringComparison.OrdinalIgnoreCase) || name.Contains(token, StringComparison.OrdinalIgnoreCase))
                                        {
                                            matchedDistinctive++;
                                        }
                                    }
                                    if (matchedDistinctive == 0)
                                    {
                                        continue; // Discard irrelevant matches that didn't match distinctive words
                                    }
                                    score += (matchedDistinctive * 50);
                                }

                                if (!string.IsNullOrWhiteSpace(cleanState) && stateVal.Equals(cleanState, StringComparison.OrdinalIgnoreCase)) score += 30;
                                if (!string.IsNullOrWhiteSpace(cleanDistrict) && county.Equals(cleanDistrict, StringComparison.OrdinalIgnoreCase)) score += 30;

                                var subList = new List<string>();
                                if (!string.IsNullOrWhiteSpace(road) && !road.Equals(name, StringComparison.OrdinalIgnoreCase)) subList.Add(road);
                                if (!string.IsNullOrWhiteSpace(suburb) && !suburb.Equals(name, StringComparison.OrdinalIgnoreCase)) subList.Add(suburb);
                                if (!string.IsNullOrWhiteSpace(county) && !county.Equals(name, StringComparison.OrdinalIgnoreCase)) subList.Add(county);
                                if (!string.IsNullOrWhiteSpace(stateVal)) subList.Add(!string.IsNullOrWhiteSpace(postVal) ? $"{stateVal} {postVal}" : stateVal);
                                if (!string.IsNullOrWhiteSpace(countryVal)) subList.Add(countryVal);

                                string secondary = string.Join(", ", subList.Distinct());
                                string fullAddr = string.IsNullOrWhiteSpace(secondary) ? name : $"{name}, {secondary}";

                                candidates.Add(new GeoSuggestionItem
                                {
                                    Name = name,
                                    Secondary = secondary,
                                    FullAddress = fullAddr,
                                    Latitude = lat,
                                    Longitude = lon,
                                    City = county,
                                    District = county,
                                    State = stateVal,
                                    Postcode = postVal,
                                    Country = countryVal,
                                    Score = score
                                });
                            }
                        }
                    }
                }
                catch { }

                // 4. Photon Geocoding with Strict Word Relevance Filtering
                try
                {
                    string photonQuery = cleanQuery;
                    if (!string.IsNullOrWhiteSpace(cleanDistrict) && !photonQuery.Contains(cleanDistrict, StringComparison.OrdinalIgnoreCase))
                        photonQuery += $" {cleanDistrict}";
                    if (!string.IsNullOrWhiteSpace(cleanState) && !photonQuery.Contains(cleanState, StringComparison.OrdinalIgnoreCase))
                        photonQuery += $" {cleanState}";

                    var pUrl = $"https://photon.komoot.io/api/?q={Uri.EscapeDataString(photonQuery)}&limit=10";
                    var pResp = await client.GetAsync(pUrl);
                    if (pResp.IsSuccessStatusCode)
                    {
                        var pJson = await pResp.Content.ReadAsStringAsync();
                        using var pDoc = JsonDocument.Parse(pJson);
                        if (pDoc.RootElement.TryGetProperty("features", out var feats) && feats.ValueKind == JsonValueKind.Array)
                        {
                            foreach (var feat in feats.EnumerateArray())
                            {
                                var props = feat.GetProperty("properties");
                                var geom = feat.GetProperty("geometry");
                                var coords = geom.GetProperty("coordinates");
                                double lon = coords[0].GetDouble();
                                double lat = coords[1].GetDouble();

                                string name = props.TryGetProperty("name", out var n) ? n.GetString() ?? "" : "";
                                string street = props.TryGetProperty("street", out var st) ? st.GetString() ?? "" : "";
                                string housenumber = props.TryGetProperty("housenumber", out var hn) ? hn.GetString() ?? "" : "";
                                string featDistrict = props.TryGetProperty("district", out var d) ? d.GetString() ?? "" : "";
                                string featCity = props.TryGetProperty("city", out var c) ? c.GetString() ?? "" : "";
                                string county = props.TryGetProperty("county", out var co) ? co.GetString() ?? "" : "";
                                string featState = props.TryGetProperty("state", out var s) ? s.GetString() ?? "" : "";
                                string postcode = props.TryGetProperty("postcode", out var pc) ? pc.GetString() ?? "" : "";
                                string featCountry = props.TryGetProperty("country", out var cnt) ? cnt.GetString() ?? "" : "";

                                string combinedText = $"{name} {street} {featDistrict} {featCity} {county}";

                                int score = 100;
                                int matchedDistinctive = 0;
                                if (distinctiveTokens.Count > 0)
                                {
                                    foreach (var token in distinctiveTokens)
                                    {
                                        if (combinedText.Contains(token, StringComparison.OrdinalIgnoreCase))
                                        {
                                            matchedDistinctive++;
                                        }
                                    }
                                    // CRITICAL: If none of user's distinctive tokens matched, discard this feature
                                    if (matchedDistinctive == 0)
                                    {
                                        continue;
                                    }
                                    score += (matchedDistinctive * 50);
                                }

                                if (!string.IsNullOrWhiteSpace(cleanState) && featState.Equals(cleanState, StringComparison.OrdinalIgnoreCase)) score += 30;
                                if (!string.IsNullOrWhiteSpace(cleanDistrict) && (featDistrict.Equals(cleanDistrict, StringComparison.OrdinalIgnoreCase) || county.Equals(cleanDistrict, StringComparison.OrdinalIgnoreCase))) score += 30;

                                var subParts = new List<string>();
                                if (!string.IsNullOrWhiteSpace(street) && !street.Equals(name, StringComparison.OrdinalIgnoreCase))
                                    subParts.Add(!string.IsNullOrWhiteSpace(housenumber) ? $"{housenumber} {street}" : street);
                                if (!string.IsNullOrWhiteSpace(featDistrict) && !featDistrict.Equals(name, StringComparison.OrdinalIgnoreCase))
                                    subParts.Add(featDistrict);
                                if (!string.IsNullOrWhiteSpace(featCity) && !featCity.Equals(name, StringComparison.OrdinalIgnoreCase))
                                    subParts.Add(featCity);
                                if (!string.IsNullOrWhiteSpace(county) && !county.Equals(featCity, StringComparison.OrdinalIgnoreCase) && !county.Equals(name, StringComparison.OrdinalIgnoreCase))
                                    subParts.Add(county);
                                if (!string.IsNullOrWhiteSpace(featState))
                                    subParts.Add(!string.IsNullOrWhiteSpace(postcode) ? $"{featState} {postcode}" : featState);
                                if (!string.IsNullOrWhiteSpace(featCountry))
                                    subParts.Add(featCountry);

                                string secondary = string.Join(", ", subParts.Distinct());
                                string fullDisplay = string.IsNullOrWhiteSpace(secondary) ? name : $"{name}, {secondary}";

                                candidates.Add(new GeoSuggestionItem
                                {
                                    Name = string.IsNullOrWhiteSpace(name) ? fullDisplay : name,
                                    Secondary = secondary,
                                    FullAddress = fullDisplay,
                                    Latitude = lat,
                                    Longitude = lon,
                                    City = featCity,
                                    District = featDistrict,
                                    State = featState,
                                    Postcode = postcode,
                                    Country = featCountry,
                                    Score = score
                                });
                            }
                        }
                    }
                }
                catch { }

                // 5. Deduplication & Ranking
                var results = new List<GeoSuggestionItem>();
                foreach (var item in candidates.OrderByDescending(c => c.Score))
                {
                    bool isDuplicate = results.Any(existing =>
                        (Math.Abs(existing.Latitude - item.Latitude) < 0.0015 && Math.Abs(existing.Longitude - item.Longitude) < 0.0015) ||
                        string.Equals(existing.FullAddress, item.FullAddress, StringComparison.OrdinalIgnoreCase) ||
                        (string.Equals(existing.Name, item.Name, StringComparison.OrdinalIgnoreCase) && string.Equals(existing.Postcode, item.Postcode, StringComparison.OrdinalIgnoreCase)));

                    if (!isDuplicate)
                    {
                        results.Add(item);
                        if (results.Count >= 8) break;
                    }
                }

                if (results.Count > 0)
                {
                    return Json(results.Select(r => new
                    {
                        name = r.Name,
                        secondary = r.Secondary,
                        fullAddress = r.FullAddress,
                        latitude = r.Latitude,
                        longitude = r.Longitude,
                        city = r.City,
                        district = r.District,
                        state = r.State,
                        postcode = r.Postcode,
                        country = r.Country
                    }));
                }
            }
            catch
            {
                // Fallback handled on client side
            }

            return Json(Array.Empty<object>());
        }

        [AllowAnonymous]
        [HttpGet]
        public async Task<IActionResult> ReverseGeoLookup(
            [FromQuery] double lat,
            [FromQuery] double lon,
            [FromServices] IHttpClientFactory httpFactory)
        {
            if (lat == 0 && lon == 0)
            {
                return Json(new { success = false, message = "Invalid coordinates." });
            }

            try
            {
                var client = httpFactory.CreateClient();
                client.Timeout = TimeSpan.FromSeconds(5);
                client.DefaultRequestHeaders.Add("User-Agent", "eClinicPlus-EMR/1.0 (ReverseGeo)");

                // 1. Try Nominatim Reverse Geocoding
                try
                {
                    var nomUrl = $"https://nominatim.openstreetmap.org/reverse?lat={lat}&lon={lon}&format=json&addressdetails=1";
                    var nomResp = await client.GetAsync(nomUrl);
                    if (nomResp.IsSuccessStatusCode)
                    {
                        var nomJson = await nomResp.Content.ReadAsStringAsync();
                        using var doc = JsonDocument.Parse(nomJson);
                        var root = doc.RootElement;
                        string displayName = root.TryGetProperty("display_name", out var dn) ? dn.GetString() ?? "" : "";
                        if (!string.IsNullOrWhiteSpace(displayName))
                        {
                            return Json(new
                            {
                                success = true,
                                address = displayName,
                                latitude = lat,
                                longitude = lon
                            });
                        }
                    }
                }
                catch { }

                // 2. Try BigDataCloud reverse geocode client API (free, fast)
                try
                {
                    var bdcUrl = $"https://api.bigdatacloud.net/data/reverse-geocode-client?latitude={lat}&longitude={lon}&localityLanguage=en";
                    var bdcResp = await client.GetAsync(bdcUrl);
                    if (bdcResp.IsSuccessStatusCode)
                    {
                        var bdcJson = await bdcResp.Content.ReadAsStringAsync();
                        using var doc = JsonDocument.Parse(bdcJson);
                        var root = doc.RootElement;

                        string locality = root.TryGetProperty("locality", out var loc) ? loc.GetString() ?? "" : "";
                        string city = root.TryGetProperty("city", out var ct) ? ct.GetString() ?? "" : "";
                        string principalSubdiv = root.TryGetProperty("principalSubdivision", out var ps) ? ps.GetString() ?? "" : "";
                        string countryName = root.TryGetProperty("countryName", out var cn) ? cn.GetString() ?? "" : "";
                        string postcode = root.TryGetProperty("postcode", out var pc) ? pc.GetString() ?? "" : "";

                        var parts = new List<string>();
                        if (!string.IsNullOrWhiteSpace(locality)) parts.Add(locality);
                        if (!string.IsNullOrWhiteSpace(city) && !city.Equals(locality, StringComparison.OrdinalIgnoreCase)) parts.Add(city);
                        if (!string.IsNullOrWhiteSpace(principalSubdiv))
                            parts.Add(!string.IsNullOrWhiteSpace(postcode) ? $"{principalSubdiv} {postcode}" : principalSubdiv);
                        if (!string.IsNullOrWhiteSpace(countryName)) parts.Add(countryName);

                        string formatted = string.Join(", ", parts);
                        if (!string.IsNullOrWhiteSpace(formatted))
                        {
                            return Json(new
                            {
                                success = true,
                                address = formatted,
                                latitude = lat,
                                longitude = lon
                            });
                        }
                    }
                }
                catch { }

                // 3. Fallback to Photon reverse
                try
                {
                    var pUrl = $"https://photon.komoot.io/reverse?lat={lat}&lon={lon}";
                    var pResp = await client.GetAsync(pUrl);
                    if (pResp.IsSuccessStatusCode)
                    {
                        var pJson = await pResp.Content.ReadAsStringAsync();
                        using var doc = JsonDocument.Parse(pJson);
                        if (doc.RootElement.TryGetProperty("features", out var fArr) && fArr.ValueKind == JsonValueKind.Array && fArr.GetArrayLength() > 0)
                        {
                            var props = fArr[0].GetProperty("properties");
                            string name = props.TryGetProperty("name", out var n) ? n.GetString() ?? "" : "";
                            string street = props.TryGetProperty("street", out var st) ? st.GetString() ?? "" : "";
                            string city = props.TryGetProperty("city", out var c) ? c.GetString() ?? "" : "";
                            string state = props.TryGetProperty("state", out var s) ? s.GetString() ?? "" : "";
                            string country = props.TryGetProperty("country", out var cnt) ? cnt.GetString() ?? "" : "";
                            string postcode = props.TryGetProperty("postcode", out var pc) ? pc.GetString() ?? "" : "";

                            var parts = new List<string>();
                            if (!string.IsNullOrWhiteSpace(name)) parts.Add(name);
                            if (!string.IsNullOrWhiteSpace(street) && !street.Equals(name, StringComparison.OrdinalIgnoreCase)) parts.Add(street);
                            if (!string.IsNullOrWhiteSpace(city)) parts.Add(city);
                            if (!string.IsNullOrWhiteSpace(state)) parts.Add(!string.IsNullOrWhiteSpace(postcode) ? $"{state} {postcode}" : state);
                            if (!string.IsNullOrWhiteSpace(country)) parts.Add(country);

                            string formatted = string.Join(", ", parts);
                            if (!string.IsNullOrWhiteSpace(formatted))
                            {
                                return Json(new
                                {
                                    success = true,
                                    address = formatted,
                                    latitude = lat,
                                    longitude = lon
                                });
                            }
                        }
                    }
                }
                catch { }
            }
            catch (Exception ex)
            {
                return Json(new { success = false, message = ex.Message });
            }

            return Json(new
            {
                success = true,
                address = $"Location at Lat: {lat:F5}, Lon: {lon:F5}",
                latitude = lat,
                longitude = lon
            });
        }

        [HttpGet]
        [AllowAnonymous]
        public async Task<IActionResult> PrintBillAnonymous(int labOrderId, string secret)
        {
            if (string.IsNullOrEmpty(secret) || secret != $"lab_print_{labOrderId}")
            {
                return Unauthorized("Invalid or missing secret key for anonymous bill generation.");
            }

            if (labOrderId <= 0) return BadRequest("Invalid lab order ID.");

            var detail = await labOrderApiClient.GetOrderDetailAsync(labOrderId);
            if (detail == null) return NotFound("Lab order not found.");

            var branchId = detail.BranchId;

            var settings = await dbContext.HospitalSettings
                .Where(s => s.BranchId == branchId && s.IsActive)
                .FirstOrDefaultAsync();

            decimal grossAmount = detail.Items.Sum(i => i.Price);
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

            var vm = new PrintBillViewModel
            {
                IsActive              = detail.IsActive,
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
                PhoneNumber  = detail.PhoneNumber,
                EmailId      = detail.EmailId,
                Gender       = detail.Gender,
                Age          = detail.Age,
                DateOfBirth  = detail.DateOfBirth,
                Address      = detail.Address,

                LabOrderId        = detail.LabOrderId,
                BillNo            = detail.BillNo,
                TokenNo           = detail.TokenNo,
                OrderDate         = detail.OrderDate,
                CreatedDate       = detail.CreatedDate,
                BookingDate       = detail.BookingDate,
                CollectionType    = detail.CollectionType,
                PhlebotomistName  = detail.PhlebotomistName,
                CreatedByName     = detail.CreatedByName,

                GrossAmount     = grossAmount,
                DiscountAmount  = headerDiscount,
                RoundOffAmount  = detail.RoundOffAmount,
                GrandTotal      = detail.NetAmount,
                ReceivedAmount  = detail.TotalPaid,
                Balance         = detail.BalanceDue,
                PaymentStatus   = detail.PaymentStatus,

                LineItems = lineItems,
                Payments  = detail.Payments.Select(p => new PrintBillPaymentRow
                {
                    MethodName     = p.MethodName,
                    PaidAmount     = p.PaidAmount,
                    TransactionRef = p.TransactionRef
                }).ToList()
            };

            return View("PrintBill", vm);
        }
    }

    public class GeoSuggestionItem
    {
        public string Name { get; set; } = "";
        public string Secondary { get; set; } = "";
        public string FullAddress { get; set; } = "";
        public double Latitude { get; set; }
        public double Longitude { get; set; }
        public string City { get; set; } = "";
        public string District { get; set; } = "";
        public string State { get; set; } = "";
        public string Postcode { get; set; } = "";
        public string Country { get; set; } = "";
        public int Score { get; set; }
    }
}
