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
using Microsoft.Extensions.Logging;

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
        ISampleCollectionApiClient sampleCollectionApiClient,
        ILabFranchiseApiClient franchiseApiClient,
        ICorporateApiClient corporateApiClient,
        IB2BBillingApiClient b2bBillingApiClient,
        ILogger<LabOrderBookingController> logger) : Controller
    {
        [HttpGet]
        public async Task<IActionResult> B2BBooking(int? patientId)
        {
            var model = new LabOrderBookingViewModel
            {
                IsB2B = true,
                AgentType = "F",
                CollectionType = "B2BCollector"
            };

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
        public async Task<IActionResult> B2BBooking(LabOrderBookingViewModel model, IFormFile? identificationFile, IFormFile? profilePictureFile)
        {
            model.IsB2B = true;
            var branchId = User.GetCurrentBranchId();
            if (branchId is null)
            {
                TempData["Error"] = "Please select a branch first.";
                return RedirectToAction("SelectBranch", "Account");
            }

            if (!model.DemographicsOnly && !string.IsNullOrWhiteSpace(model.PaymentDataJson))
            {
                SavePaymentRequest? discountCheck = null;
                try { discountCheck = System.Text.Json.JsonSerializer.Deserialize<SavePaymentRequest>(model.PaymentDataJson, new System.Text.Json.JsonSerializerOptions { PropertyNameCaseInsensitive = true }); }
                catch { /* malformed payment data is reported by the normal flow */ }
                if (PaymentService.IsDiscountApprovalMissing(discountCheck))
                    ModelState.AddModelError(string.Empty, PaymentService.DiscountApprovalRequiredMessage);
            }

            if (!model.DemographicsOnly)
            {
                if (!model.B2BAgentId.HasValue || model.B2BAgentId.Value <= 0)
                {
                    var partnerTypeLabel = model.AgentType == "C" ? "Company" : "Franchise";
                    ModelState.AddModelError(nameof(model.B2BAgentId), $"Please select a {partnerTypeLabel}.");
                }
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
                            if (itm.InvestigationId <= 0 && itm.Id.HasValue && itm.Id.Value > 0)
                            {
                                itm.InvestigationId = itm.Id.Value;
                            }

                            if (itm.IsPackage || string.Equals(itm.Type, "P", StringComparison.OrdinalIgnoreCase))
                            {
                                itm.Type = "P";
                                itm.IsPackage = true;
                            }
                            else
                            {
                                itm.Type = "I";
                                itm.IsPackage = false;
                            }
                        }
                    }
                }
                catch { }

                if (lineItems == null || !lineItems.Any())
                {
                    ModelState.AddModelError(nameof(model.LineItemsJson), "At least one test investigation is required. You cannot create a laboratory bill without tests.");
                }
                else if (lineItems.Any(x => x.InvestigationId <= 0))
                {
                    ModelState.AddModelError(nameof(model.LineItemsJson), "One or more tests have an invalid Investigation ID. Please re-select the tests.");
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
                LanguageId = model.LanguageId,
                BloodGroup = model.BloodGroup,
                KnownAllergies = model.KnownAllergies,
                Remarks = model.Remarks,
                BranchId = branchId,
                CompanyId = 1,
                IsActive = true
            };

            int actualPatientId = model.PatientId;
            if (model.PatientId == 0)
            {
                actualPatientId = await patientService.CreateDemographicsOnlyAsync(patient, User.GetUserId());
                patient.PatientId = actualPatientId;
                await auditLogService.LogAsync("LAB", "Patient.Create", $"Registered patient: {patient.FirstName} {patient.LastName} for B2B LAB.");
            }
            else
            {
                var existing = await patientService.GetByIdAsync(model.PatientId);
                if (string.IsNullOrWhiteSpace(model.IdentificationFilePath)) patient.IdentificationFilePath = existing?.IdentificationFilePath;
                if (string.IsNullOrWhiteSpace(model.PhotoPath)) patient.PhotoPath = existing?.PhotoPath;

                await patientService.UpdateDemographicsAsync(patient, User.GetUserId());
            }

            if (model.DemographicsOnly)
            {
                TempData["Success"] = $"Patient demographics updated successfully.";
                return RedirectToAction(nameof(B2BBooking), new { patientId = actualPatientId });
            }

            decimal totalAmount = lineItems!.Sum(x => x.Price);
            decimal b2bTotal = lineItems!.Sum(x => x.B2BRate ?? x.Price);

            // ── Fetch Partner Credit Status & Enforce Credit Facility Policies ──
            var creditStatus = await b2bBillingApiClient.GetPartnerCreditStatusAsync(model.AgentType, model.B2BAgentId!.Value, branchId);
            if (creditStatus != null)
            {
                // 1. Corporate contract validity enforcement
                if (model.AgentType == "C" && !creditStatus.IsContractValid)
                {
                    ModelState.AddModelError(nameof(model.B2BAgentId), creditStatus.BlockReason ?? "Corporate company contract is expired or inactive. Billing cannot proceed.");
                    await PopulateSelectLists(model);
                    return View(model);
                }

                // 2. Postpaid (Credit) Facility Limit validation
                if (creditStatus.CreditFacilityType == 2)
                {
                    if (creditStatus.CreditLimit > 0 && (creditStatus.CurrentOutstanding + b2bTotal) > creditStatus.CreditLimit)
                    {
                        var overBy = (creditStatus.CurrentOutstanding + b2bTotal) - creditStatus.CreditLimit;
                        ModelState.AddModelError(string.Empty, $"Credit limit exceeded for {creditStatus.PartnerName}! Credit Limit: ₹{creditStatus.CreditLimit:N2}, Current Outstanding: ₹{creditStatus.CurrentOutstanding:N2}, Bill Total: ₹{b2bTotal:N2}. Exceeds limit by ₹{overBy:N2}. Billing cannot proceed until outstanding bills are settled.");
                        await PopulateSelectLists(model);
                        return View(model);
                    }
                }

                // If spot payment data is provided, precedence is given to Spot Payment (bypassing wallet deduction)
                if (!string.IsNullOrWhiteSpace(model.PaymentDataJson))
                {
                    model.DeductFromWallet = false;
                }

                // 3. Prepaid (Wallet) Facility validation
                if (creditStatus.CreditFacilityType == 1)
                {
                    if (model.DeductFromWallet)
                    {
                        if (creditStatus.WalletBalance < b2bTotal)
                        {
                            var deficit = b2bTotal - creditStatus.WalletBalance;
                            ModelState.AddModelError(string.Empty, $"Insufficient wallet balance for {creditStatus.PartnerName}! Available Wallet: ₹{creditStatus.WalletBalance:N2}, Required: ₹{b2bTotal:N2} (Deficit: ₹{deficit:N2}). Please recharge wallet or complete spot payment.");
                            await PopulateSelectLists(model);
                            return View(model);
                        }
                    }
                    else if (string.IsNullOrWhiteSpace(model.PaymentDataJson))
                    {
                        ModelState.AddModelError(string.Empty, $"Prepaid (Wallet) facility requires immediate payment at billing. Please check 'Pay from Wallet Balance' (Available: ₹{creditStatus.WalletBalance:N2}) or complete immediate spot payment.");
                        await PopulateSelectLists(model);
                        return View(model);
                    }
                }
            }

            // Calculate Due Date based on Credit Days for Postpaid
            int creditDays = creditStatus?.CreditDays ?? 0;
            DateTime? dueDate = (creditStatus != null && creditStatus.CreditFacilityType == 2 && creditDays > 0)
                ? model.BookingDateTime.AddDays(creditDays)
                : (DateTime?)null;

            // Create B2B Lab Order
            var labOrderReq = new LabOrderRequestDto
            {
                PatientId = actualPatientId,
                BranchId = branchId.Value,
                CollectionType = string.IsNullOrWhiteSpace(model.CollectionType) ? "B2BCollector" : model.CollectionType,
                PhlebotomistId = model.CollectionType == "Home Collection" ? model.PhlebotomistId : null,
                BookingDate = model.BookingDateTime,
                ReferralDoctorId = model.ReferralDoctorId is > 0 ? model.ReferralDoctorId : null,
                DueDate = dueDate,
                IsB2B = true,
                B2BAgentId = model.B2BAgentId,
                AgentType = model.AgentType,
                B2BTotal = b2bTotal,
                CreatedBy = User.GetUserId(),
                Items = lineItems!
            };

            var labOrderRes = await labOrderApiClient.CreateOrderAsync(labOrderReq);
            await labOrderApiClient.CreateSampleCollectionAsync(labOrderRes.LabOrderId, branchId.Value, patient.CompanyId, User.GetUserId());

            // Post B2B Bill Ledger (Dr Franchise Receivable or Corporate Receivable, Cr LAB Revenue)
            // NOTE: b2bShowPrintBarcode is resolved after payment processing below (same ordering as B2C).
            bool b2bShowPrintBarcode = false;
            await ledgerService.PostB2BLabBillLedgerAsync(labOrderRes.LabOrderId, b2bTotal, model.AgentType, model.B2BAgentId.Value, branchId, patient.CompanyId, User.GetUserId(), labOrderRes.BillNo);

            string paymentModeUsed = "Credit (Postpaid)";

            // Handle Prepaid Payment Processing
            if (creditStatus != null && creditStatus.CreditFacilityType == 1)
            {
                if (model.DeductFromWallet)
                {
                    var deductReq = new DeductWalletRequestDto
                    {
                        LabOrderId = labOrderRes.LabOrderId,
                        FranchiseId = model.B2BAgentId.Value,
                        Amount = b2bTotal,
                        BranchId = branchId.Value,
                        BillNo = labOrderRes.BillNo
                    };
                    var deductRes = await b2bBillingApiClient.DeductWalletPaymentAsync(deductReq);
                    if (deductRes != null && !string.IsNullOrWhiteSpace(deductRes.TokenNo))
                    {
                        labOrderRes.TokenNo = deductRes.TokenNo;
                    }
                    paymentModeUsed = "Prepaid Wallet Deduction";
                }
                else if (!string.IsNullOrWhiteSpace(model.PaymentDataJson))
                {
                    try
                    {
                        var paymentReq = JsonSerializer.Deserialize<SavePaymentRequest>(model.PaymentDataJson, new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
                        if (paymentReq != null)
                        {
                            paymentReq.ModuleCode = "LAB";
                            paymentReq.ModuleRefId = labOrderRes.LabOrderId;
                            paymentReq.OPDServiceId = labOrderRes.LabOrderId;
                            paymentReq.PatientId = actualPatientId;
                            paymentReq.BranchId = branchId.Value;
                            paymentReq.SubTotal = b2bTotal;

                            var payRes = await paymentService.SavePaymentAsync(paymentReq, User.GetUserId());
                            if (payRes != null && !string.IsNullOrWhiteSpace(payRes.TokenNo))
                            {
                                labOrderRes.TokenNo = payRes.TokenNo;
                            }
                            paymentModeUsed = "Immediate Spot Payment";
                        }
                    }
                    catch (Exception payEx)
                    {
                        logger.LogError(payEx, "Error processing spot payment for B2B order {BillNo}", labOrderRes.BillNo);
                    }
                }
            }

            // ── B2B: HospitalSettings parity with B2C — evaluated AFTER payment (same ordering) ─────
            // Auto-collect: call unconditionally — the SP checks IsSampleCollectionMandatory internally
            // (exactly the same pattern as B2C SaveBookingWithPayment line ~1096).
            // This also avoids double-invocation on the Prepaid Spot Payment path where
            // PaymentService.SavePaymentAsync already calls the same SP internally.
            try
            {
                await sampleCollectionApiClient.AutoCollectIfNotMandatoryAsync(labOrderRes.LabOrderId);
            }
            catch
            {
                // Non-blocking: billing must not fail due to auto-collect error
            }

            // BarcodeGenerateAtBilling: read setting to decide whether to show the Print Barcode prompt
            // (barcodes themselves are already generated by usp_CreateSampleCollectionFromLabOrder
            //  when CreateSampleCollectionAsync is called above — same as B2C).
            try
            {
                var b2bSettings = await dbContext.HospitalSettings
                    .FirstOrDefaultAsync(s => s.BranchId == branchId.Value && s.IsActive);
                if (b2bSettings != null)
                    b2bShowPrintBarcode = b2bSettings.BarcodeGenerateAtBilling;
            }
            catch
            {
                // Non-blocking: settings lookup failure must not interrupt B2B billing
            }
            // ─────────────────────────────────────────────────────────────────────────────────────────

            string patientFullName = ((patient.Salutation ?? "") + " " + patient.FirstName + " " + patient.LastName).Trim();
            string agentLabel = model.AgentType == "C" ? "Company" : "Franchise";
            await auditLogService.LogActivityAsync(
                eventType: "B2B LAB Billing",
                actionName: "LAB.B2BOrderBooked",
                description: $"B2B Lab Order Bill {labOrderRes.BillNo} generated for patient {patientFullName} ({patient.PatientCode ?? actualPatientId.ToString()}). Agent: {agentLabel} #{model.B2BAgentId}. Total: ₹{totalAmount:F2}, B2B Total: ₹{b2bTotal:F2}. Payment Mode: {paymentModeUsed}. Token: {labOrderRes.TokenNo}.",
                userId: User.GetUserId(),
                branchId: branchId,
                moduleCode: "LAB",
                referenceNo: labOrderRes.BillNo,
                referenceId: labOrderRes.LabOrderId,
                patientCode: patient.PatientCode,
                metadata: new {
                    labOrderRes.LabOrderId,
                    labOrderRes.BillNo,
                    labOrderRes.TokenNo,
                    IsB2B = true,
                    AgentType = model.AgentType,
                    B2BAgentId = model.B2BAgentId,
                    TotalAmount = totalAmount,
                    B2BTotal = b2bTotal,
                    PaymentMode = paymentModeUsed,
                    DueDate = dueDate,
                    CreditDays = creditDays,
                    ItemCount = lineItems!.Count,
                    Items = lineItems!.Select(x => new { x.InvestigationId, x.Price, x.B2BRate, x.Type })
                });

            TempData["NewPatientName"]   = patientFullName;
            TempData["NewPatientCode"]   = patient.PatientCode;   // parity with B2C — used in success modal
            TempData["BillNo"]           = labOrderRes.BillNo;
            TempData["NewLabOrderId"]    = labOrderRes.LabOrderId.ToString();
            TempData["IsB2B"]            = "true";
            TempData["AgentType"]        = model.AgentType;
            TempData["B2BAgentId"]       = model.B2BAgentId?.ToString();
            TempData["B2BTotal"]         = b2bTotal.ToString("F2");
            TempData["TokenNo"]          = labOrderRes.TokenNo;
            TempData["PaymentMode"]      = paymentModeUsed;
            TempData["ShowPrintBarcode"] = b2bShowPrintBarcode ? "true" : "false"; // BarcodeGenerateAtBilling (B2B parity)
            return RedirectToAction(nameof(B2BBooking), new { registered = true });
        }

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
                            if (itm.InvestigationId <= 0 && itm.Id.HasValue && itm.Id.Value > 0)
                            {
                                itm.InvestigationId = itm.Id.Value;
                            }

                            if (itm.IsPackage || string.Equals(itm.Type, "P", StringComparison.OrdinalIgnoreCase))
                            {
                                itm.Type = "P";
                                itm.IsPackage = true;
                            }
                            else
                            {
                                itm.Type = "I";
                                itm.IsPackage = false;
                            }
                        }
                    }
                }
                catch { }

                if (lineItems == null || !lineItems.Any())
                {
                    ModelState.AddModelError(nameof(model.LineItemsJson), "At least one test investigation is required. You cannot create a laboratory bill without tests.");
                }
                else if (lineItems.Any(x => x.InvestigationId <= 0))
                {
                    ModelState.AddModelError(nameof(model.LineItemsJson), "One or more tests have an invalid Investigation ID. Please re-select the tests.");
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
                LanguageId = model.LanguageId,
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
                ReferralDoctorId = model.ReferralDoctorId is > 0 ? model.ReferralDoctorId : null,
                CreatedBy = User.GetUserId(),
                Items = lineItems!
            };

            var labOrderRes = await labOrderApiClient.CreateOrderAsync(labOrderReq);
            await labOrderApiClient.CreateSampleCollectionAsync(labOrderRes.LabOrderId, branchId.Value, patient.CompanyId, User.GetUserId());

            decimal totalAmount = lineItems!.Sum(x => x.Price);
            await ledgerService.PostLabBillLedgerAsync(labOrderRes.LabOrderId, totalAmount, branchId, patient.CompanyId, User.GetUserId(), labOrderRes.BillNo);

            string patientFullName = ((patient.Salutation ?? "") + " " + patient.FirstName + " " + patient.LastName).Trim();
            await auditLogService.LogActivityAsync(
                eventType: "LAB Billing",
                actionName: "LAB.OrderBooked",
                description: $"Lab Order Bill {labOrderRes.BillNo} generated for patient {patientFullName} ({patient.PatientCode ?? actualPatientId.ToString()}). Total Items: {lineItems!.Count}. Total: ₹{totalAmount:F2}. Token: {labOrderRes.TokenNo}.",
                userId: User.GetUserId(),
                branchId: branchId,
                moduleCode: "LAB",
                referenceNo: labOrderRes.BillNo,
                referenceId: labOrderRes.LabOrderId,
                patientCode: patient.PatientCode,
                metadata: new {
                    labOrderRes.LabOrderId,
                    labOrderRes.BillNo,
                    labOrderRes.TokenNo,
                    TotalAmount = totalAmount,
                    ItemCount = lineItems!.Count,
                    Items = lineItems!.Select(x => new { x.InvestigationId, x.Price, x.Type })
                });

            TempData["NewPatientName"]  = patientFullName;
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

            // A discount must carry its reason and approver: refuse before anything is saved.
            if (!string.IsNullOrWhiteSpace(paymentDataJson))
            {
                SavePaymentRequest? discountCheck = null;
                try { discountCheck = System.Text.Json.JsonSerializer.Deserialize<SavePaymentRequest>(paymentDataJson, new System.Text.Json.JsonSerializerOptions { PropertyNameCaseInsensitive = true }); }
                catch { /* malformed payment data is reported by the normal flow */ }
                if (PaymentService.IsDiscountApprovalMissing(discountCheck))
                    return Json(new { success = false, error = PaymentService.DiscountApprovalRequiredMessage });
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
                        if (itm.IsPackage || string.Equals(itm.Type, "P", StringComparison.OrdinalIgnoreCase))
                        {
                            itm.Type = "P";
                            itm.IsPackage = true;
                        }
                        else
                        {
                            itm.Type = "I";
                            itm.IsPackage = false;
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
                LanguageId = model.LanguageId,
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
                CollectionType = string.IsNullOrWhiteSpace(model.CollectionType) ? (model.IsB2B ? "B2BCollector" : "Lab") : model.CollectionType,
                PhlebotomistId = model.CollectionType == "Home Collection" ? model.PhlebotomistId : null,
                BookingDate = model.BookingDateTime,
                ReferralDoctorId = model.ReferralDoctorId is > 0 ? model.ReferralDoctorId : null,
                IsB2B = model.IsB2B,
                B2BAgentId = model.B2BAgentId,
                AgentType = model.AgentType,
                B2BTotal = model.B2BTotal ?? (model.IsB2B ? lineItems.Sum(x => x.B2BRate ?? x.Price) : null),
                CreatedBy = User.GetUserId(),
                Items = lineItems
            };

            var labOrderRes = await labOrderApiClient.CreateOrderAsync(labOrderReq);
            await labOrderApiClient.CreateSampleCollectionAsync(labOrderRes.LabOrderId, branchId.Value, patient.CompanyId, User.GetUserId());

            decimal totalAmount = lineItems.Sum(x => x.Price);
            await ledgerService.PostLabBillLedgerAsync(labOrderRes.LabOrderId, totalAmount, branchId, patient.CompanyId, User.GetUserId(), labOrderRes.BillNo);

            string patientFullName = ((patient.Salutation ?? "") + " " + patient.FirstName + " " + patient.LastName).Trim();
            await auditLogService.LogActivityAsync(
                eventType: "LAB Billing",
                actionName: "LAB.OrderBooked",
                description: $"Lab Order Bill {labOrderRes.BillNo} generated for patient {patientFullName} ({actualPatientCode}). Total Items: {lineItems.Count}. Total: ₹{totalAmount:F2}. Token: {labOrderRes.TokenNo}.",
                userId: User.GetUserId(),
                branchId: branchId,
                moduleCode: "LAB",
                referenceNo: labOrderRes.BillNo,
                referenceId: labOrderRes.LabOrderId,
                patientCode: actualPatientCode,
                metadata: new {
                    labOrderRes.LabOrderId,
                    labOrderRes.BillNo,
                    labOrderRes.TokenNo,
                    TotalAmount = totalAmount,
                    ItemCount = lineItems.Count,
                    Items = lineItems.Select(x => new { x.InvestigationId, x.Price, x.Type })
                });

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

                    if (paymentResult != null && paymentResult.Success)
                    {
                        var statusStr = paymentResult.PaymentStatus == "P" ? "Fully Paid" : "Partial Payment";
                        var paidAmt = paymentReq.Payments?.Sum(p => p.PaidAmount) ?? paymentResult.TotalPaid;
                        var receiptNo = paymentResult.PaymentHeaderId.HasValue ? $"RCP-{paymentResult.PaymentHeaderId}" : labOrderRes.BillNo;
                        await auditLogService.LogActivityAsync(
                            eventType: "Payment Collection",
                            actionName: "LAB.PaymentReceived",
                            description: $"Payment of ₹{paidAmt:F2} collected for Lab Order {labOrderRes.BillNo} (Token: {labOrderRes.TokenNo}). Receipt: {receiptNo}. Status: {statusStr}. Balance Due: ₹{paymentResult.BalanceDue:F2}.",
                            userId: User.GetUserId(),
                            branchId: branchId,
                            moduleCode: "LAB",
                            referenceNo: labOrderRes.BillNo,
                            referenceId: labOrderRes.LabOrderId,
                            patientCode: actualPatientCode,
                            metadata: new {
                                labOrderRes.LabOrderId,
                                labOrderRes.BillNo,
                                Amount = paidAmt,
                                ReceiptNo = receiptNo,
                                PaymentHeaderId = paymentResult.PaymentHeaderId,
                                PaymentStatus = paymentResult.PaymentStatus,
                                BalanceDue = paymentResult.BalanceDue,
                                TokenNo = labOrderRes.TokenNo
                            });
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

            patientFullName = ((patient.Salutation ?? "") + " " + patient.FirstName + " " + patient.LastName).Trim();

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

            model.LanguageOptions = await dbContext.LanguageMasters
                .Where(l => l.IsActive)
                .OrderBy(l => l.LanguageName)
                .Select(l => new SelectListItem(l.LanguageName, l.LanguageId.ToString()))
                .ToListAsync();

            // Referral doctor = Doctor Master doctors assigned to a LAB-type department (script 2127)
            var refCon = dbContext.Database.GetDbConnection();
            if (refCon.State != System.Data.ConnectionState.Open)
                await refCon.OpenAsync();
            var referralDoctors = await refCon.QueryAsync<(int DoctorId, string DoctorName, string? SpecialityName, string? DepartmentNames)>(
                "dbo.usp_Lab_GetReferralDoctors",
                new { CompanyId = User.GetCompanyId(), BranchId = branchId },
                commandType: System.Data.CommandType.StoredProcedure);
            model.ReferralDoctorOptions = referralDoctors
                .Select(r => new SelectListItem(
                    string.IsNullOrWhiteSpace(r.DepartmentNames) ? r.DoctorName : $"{r.DoctorName} ({r.DepartmentNames})",
                    r.DoctorId.ToString()))
                .ToList();

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

            if (model.IsB2B)
            {
                try
                {
                    var franchises = await franchiseApiClient.GetListAsync(status: null, isActive: true);
                    model.FranchiseOptions = franchises
                        .OrderBy(f => f.Franchise_Name)
                        .Select(f => new SelectListItem { Value = f.Franchise_ID.ToString(), Text = $"{f.Franchise_Name} ({f.Franchise_Code})" })
                        .ToList();
                }
                catch
                {
                    model.FranchiseOptions = new();
                }

                try
                {
                    var corporates = await corporateApiClient.GetListAsync(type: null, status: true);
                    model.CorporateOptions = corporates
                        .Where(c => string.IsNullOrEmpty(c.Corporate_Type) || c.Corporate_Type == "ALL" || c.Corporate_Type == "LAB" || c.Corporate_Type == "OPD" || c.Corporate_Type == "MED")
                        .OrderBy(c => c.Corporate_Name)
                        .Select(c => new SelectListItem { Value = c.Corporate_ID.ToString(), Text = $"{c.Corporate_Name} ({c.Corporate_Code})" })
                        .ToList();
                }
                catch
                {
                    model.CorporateOptions = new();
                }

                ViewBag.Franchises = model.FranchiseOptions;
                ViewBag.Companies = model.CorporateOptions;
            }
        }

        [HttpGet]
        public async Task<IActionResult> GetAvailableInvestigations(int? branchId, int? departmentId, int? categoryId, int? subCategoryId, string? gender = null, int? ageInYears = null, string? rateType = "B2C", int? agentId = null)
        {
            int resolvedBranchId = branchId.HasValue && branchId.Value > 0
                ? branchId.Value
                : (HttpContext.Session.GetInt32("SelectedBranchId") ?? User.GetCurrentBranchId() ?? 1);

            var tests = await labOrderApiClient.GetAvailableInvestigationsAsync(resolvedBranchId, departmentId, categoryId, subCategoryId, gender, ageInYears, rateType, agentId);

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

                dynamic? profile = null;
                if (profileId.HasValue && profileId.Value > 0)
                {
                    profile = await con.QueryFirstOrDefaultAsync<dynamic>(@"
                        SELECT TOP 1 h.Profile_ID, h.Profile_Code, h.Profile_Name, h.Profile_Type, h.Test_ID, h.MRP, h.Profile_TAT_Hours
                        FROM LabInvestigationProfileHeader h
                        WHERE h.Profile_ID = @ProfileId AND h.IsDeleted = 0",
                        new { ProfileId = profileId.Value });
                }

                if (profile == null && testId.HasValue && testId.Value > 0)
                {
                    profile = await con.QueryFirstOrDefaultAsync<dynamic>(@"
                        SELECT TOP 1 h.Profile_ID, h.Profile_Code, h.Profile_Name, h.Profile_Type, h.Test_ID, h.MRP, h.Profile_TAT_Hours
                        FROM LabInvestigationProfileHeader h
                        WHERE h.IsDeleted = 0 
                          AND h.Profile_Type = 1
                          AND (h.Test_ID = @TestId OR h.Profile_Name = (SELECT TOP 1 Test_Name FROM LabInvestigationMaster WHERE Test_ID = @TestId))",
                        new { TestId = testId.Value });
                }

                if (profile == null)
                {
                    return Json(new { success = false, message = "Profile details not found." });
                }

                int resolvedProfileId = (int)profile.Profile_ID;
                string encryptedToken = encryptionService.EncryptParameters(new Dictionary<string, string?> { ["id"] = resolvedProfileId.ToString() });
                string fullUrl = $"/LabInvestigationProfiles/Details?q={encryptedToken}";

                var tests = (await con.QueryAsync<dynamic>(@"
                    SELECT d.Detail_ID, d.Test_ID, d.Sequence,
                           t.Test_Code, t.Test_Name, t.TAT_Hours, t.Reporting_Type,
                           COALESCE(t.MRP, 0) as MRP,
                           CAST(ISNULL(t.Is_Profile_Test, 0) AS BIT) as IsProfileTest,
                           subH.Profile_ID as SubProfileId,
                           dept.DeptName as DepartmentName,
                           cat.Category_Name as CategoryName
                    FROM LabInvestigationProfileDetail d
                    JOIN LabInvestigationMaster t ON t.Test_ID = d.Test_ID
                    LEFT JOIN LabInvestigationProfileHeader subH ON (subH.Test_ID = t.Test_ID OR subH.Profile_Name = t.Test_Name) 
                         AND subH.Profile_Type = 1 AND subH.IsDeleted = 0
                    LEFT JOIN DepartmentMaster dept ON dept.DeptId = t.Department_ID
                    LEFT JOIN LabTestCategoryMaster cat ON cat.Category_ID = t.Category_ID
                    WHERE d.Profile_ID = @ProfileId AND d.IsDeleted = 0
                    ORDER BY d.Sequence",
                    new { ProfileId = resolvedProfileId })).ToList();

                var allIncludedTestIds = new HashSet<int>();
                var allIncludedTestNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

                foreach (var dt in tests)
                {
                    allIncludedTestIds.Add((int)dt.Test_ID);
                    allIncludedTestNames.Add((string)dt.Test_Name);
                }

                // If any test in this profile/package is itself a profile, fetch its sub-tests too
                var subProfileIds = tests
                    .Where(x => (bool)x.IsProfileTest && x.SubProfileId != null)
                    .Select(x => (int)x.SubProfileId)
                    .Distinct()
                    .ToList();

                if (subProfileIds.Any())
                {
                    var subTests = await con.QueryAsync<dynamic>(@"
                        SELECT d.Test_ID, t.Test_Name
                        FROM LabInvestigationProfileDetail d
                        JOIN LabInvestigationMaster t ON t.Test_ID = d.Test_ID
                        WHERE d.Profile_ID IN @SubProfileIds AND d.IsDeleted = 0",
                        new { SubProfileIds = subProfileIds });

                    foreach (var st in subTests)
                    {
                        allIncludedTestIds.Add((int)st.Test_ID);
                        allIncludedTestNames.Add((string)st.Test_Name);
                    }
                }

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
                    testCount = tests.Count,
                    tests = tests.Select(x => new
                    {
                        testId = (int)x.Test_ID,
                        sequence = x.Sequence,
                        testCode = (string)x.Test_Code,
                        testName = (string)x.Test_Name,
                        isProfileTest = (bool)x.IsProfileTest,
                        subProfileId = (int?)(x.SubProfileId != null ? (int)x.SubProfileId : null),
                        reportingType = (string)(x.Reporting_Type ?? "Numeric"),
                        categoryName = (string)(x.CategoryName ?? ""),
                        departmentName = (string)(x.DepartmentName ?? ""),
                        mrp = (decimal)(x.MRP ?? 0)
                    }),
                    allIncludedTestIds = allIncludedTestIds.ToList(),
                    allIncludedTestNames = allIncludedTestNames.ToList()
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
        public async Task<IActionResult> B2COrderList(int? branchId, string? fromDate, string? toDate, string? search, int page = 1, int pageSize = 10)
        {
            int resolvedBranchId = branchId 
                ?? User.GetCurrentBranchId() 
                ?? HttpContext.Session.GetInt32("SelectedBranchId") 
                ?? HttpContext.Session.GetInt32("BranchId") 
                ?? 1;

            var effectiveFromDate = fromDate ?? DateTime.Today.AddDays(-30).ToString("yyyy-MM-dd");
            var effectiveToDate = toDate ?? DateTime.Today.ToString("yyyy-MM-dd");

            var result = await labOrderApiClient.GetPagedOrdersAsync(resolvedBranchId, effectiveFromDate, effectiveToDate, search, page, pageSize, isB2B: false);

            var branches = await dbContext.BranchMasters
                .Where(b => b.IsActive)
                .OrderBy(b => b.BranchName)
                .Select(b => new SelectListItem
                {
                    Value = b.BranchId.ToString(),
                    Text = b.BranchName,
                    Selected = b.BranchId == resolvedBranchId
                })
                .ToListAsync();
            ViewBag.Branches = branches;

            var currentBranch = branches.FirstOrDefault(b => b.Selected)?.Text;

            ViewBag.ShowLabReportPrintOnList = await dbContext.HospitalSettings
                .Where(s => s.BranchId == resolvedBranchId && s.IsActive)
                .Select(s => s.ShowLabReportPrintOnList)
                .FirstOrDefaultAsync();

            var vm = new LabOrderPagedListViewModel
            {
                Items = result?.Items ?? new List<LabOrderListItemDto>(),
                Stats = result?.Stats ?? new LabOrderStatsDto(),
                TotalCount = result?.TotalCount ?? 0,
                Page = page,
                PageSize = pageSize,
                BranchId = resolvedBranchId,
                BranchName = currentBranch,
                FromDate = effectiveFromDate,
                ToDate = effectiveToDate,
                Search = search
            };

            return View(vm);
        }

        [HttpGet]
        public async Task<IActionResult> B2BRegistration(int? branchId, string? fromDate, string? toDate, string? search, int page = 1, int pageSize = 10)
        {
            int resolvedBranchId = branchId 
                ?? User.GetCurrentBranchId() 
                ?? HttpContext.Session.GetInt32("SelectedBranchId") 
                ?? HttpContext.Session.GetInt32("BranchId") 
                ?? 1;

            var effectiveFromDate = fromDate ?? DateTime.Today.AddDays(-30).ToString("yyyy-MM-dd");
            var effectiveToDate = toDate ?? DateTime.Today.ToString("yyyy-MM-dd");

            var result = await labOrderApiClient.GetPagedOrdersAsync(resolvedBranchId, effectiveFromDate, effectiveToDate, search, page, pageSize, isB2B: true);

            var branches = await dbContext.BranchMasters
                .Where(b => b.IsActive)
                .OrderBy(b => b.BranchName)
                .Select(b => new SelectListItem
                {
                    Value = b.BranchId.ToString(),
                    Text = b.BranchName,
                    Selected = b.BranchId == resolvedBranchId
                })
                .ToListAsync();
            ViewBag.Branches = branches;

            var currentBranch = branches.FirstOrDefault(b => b.Selected)?.Text;

            ViewBag.ShowLabReportPrintOnList = await dbContext.HospitalSettings
                .Where(s => s.BranchId == resolvedBranchId && s.IsActive)
                .Select(s => s.ShowLabReportPrintOnList)
                .FirstOrDefaultAsync();

            var vm = new LabOrderPagedListViewModel
            {
                Items = result?.Items ?? new List<LabOrderListItemDto>(),
                Stats = result?.Stats ?? new LabOrderStatsDto(),
                TotalCount = result?.TotalCount ?? 0,
                Page = page,
                PageSize = pageSize,
                BranchId = resolvedBranchId,
                BranchName = currentBranch,
                FromDate = effectiveFromDate,
                ToDate = effectiveToDate,
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
                ReferralDoctorName = detail.ReferralDoctorName,
                CreatedByName     = detail.CreatedByName,
                CreatedByUsername = detail.CreatedByUsername,
                PrintedByName     = User.FindFirst("DisplayName")?.Value ?? User.Identity?.Name ?? "Auto",

                // B2B vs B2C Payment & Billing Handling
                IsB2B           = detail.IsB2B,
                PartnerName     = detail.AgentName,
                PartnerCode     = detail.AgentCode,
                GrossAmount     = grossAmount,
                DiscountAmount  = headerDiscount,
                RoundOffAmount  = detail.RoundOffAmount,
                GrandTotal      = detail.IsB2B ? (grossAmount - headerDiscount + detail.RoundOffAmount) : detail.NetAmount,
                ReceivedAmount  = detail.IsB2B ? (grossAmount - headerDiscount + detail.RoundOffAmount) : detail.TotalPaid,
                Balance         = detail.IsB2B ? 0.00m : detail.BalanceDue,
                PaymentStatus   = detail.IsB2B ? "P" : detail.PaymentStatus,

                LineItems = lineItems,
                Payments  = detail.IsB2B
                    ? (detail.Payments.Any()
                        ? detail.Payments.Select(p => new PrintBillPaymentRow
                          {
                              MethodName     = p.MethodName,
                              PaidAmount     = grossAmount - headerDiscount + detail.RoundOffAmount,
                              TransactionRef = p.TransactionRef,
                              ReceiptNo      = p.ReceiptNo
                          }).ToList()
                        : new List<PrintBillPaymentRow>
                          {
                              new PrintBillPaymentRow
                              {
                                  MethodName     = "B2B Partner Credit",
                                  PaidAmount     = grossAmount - headerDiscount + detail.RoundOffAmount,
                                  ReceiptNo      = detail.BillNo
                              }
                          })
                    : detail.Payments.Select(p => new PrintBillPaymentRow
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
                GrandTotal      = detail.IsB2B ? (grossAmount - headerDiscount + detail.RoundOffAmount) : detail.NetAmount,
                ReceivedAmount  = detail.IsB2B ? (grossAmount - headerDiscount + detail.RoundOffAmount) : detail.TotalPaid,
                Balance         = detail.IsB2B ? 0.00m : detail.BalanceDue,
                PaymentStatus   = detail.IsB2B ? "P" : detail.PaymentStatus,

                LineItems = lineItems,
                Payments  = detail.IsB2B
                    ? (detail.Payments.Any()
                        ? detail.Payments.Select(p => new PrintBillPaymentRow
                          {
                              MethodName     = p.MethodName,
                              PaidAmount     = grossAmount - headerDiscount + detail.RoundOffAmount,
                              TransactionRef = p.TransactionRef,
                              ReceiptNo      = p.ReceiptNo
                          }).ToList()
                        : new List<PrintBillPaymentRow>
                          {
                              new PrintBillPaymentRow
                              {
                                  MethodName     = "B2B Partner Credit",
                                  PaidAmount     = grossAmount - headerDiscount + detail.RoundOffAmount,
                                  ReceiptNo      = detail.BillNo
                              }
                          })
                    : detail.Payments.Select(p => new PrintBillPaymentRow
                      {
                          MethodName     = p.MethodName,
                          PaidAmount     = p.PaidAmount,
                          TransactionRef = p.TransactionRef,
                          ReceiptNo      = p.ReceiptNo
                      }).ToList()
            };

            return View("PrintBill", vm);
        }

        #region ── B2B Billing, Credit Policy, Invoicing & Multi-Bill Settlement ──

        [HttpGet]
        public async Task<IActionResult> GetPartnerCreditStatus(string agentType, int agentId)
        {
            try
            {
                var branchId = User.GetCurrentBranchId();
                var status = await b2bBillingApiClient.GetPartnerCreditStatusAsync(agentType, agentId, branchId);
                if (status == null || !status.Found)
                {
                    return Json(new { success = false, error = "Partner credit status could not be found." });
                }
                return Json(new { success = true, data = status });
            }
            catch (Exception ex)
            {
                return Json(new { success = false, error = ex.Message });
            }
        }

        [HttpPost]
        public async Task<IActionResult> FranchiseWalletTopUp([FromBody] WalletTopUpDto request)
        {
            try
            {
                var branchId = User.GetCurrentBranchId();
                if (branchId.HasValue) request.BranchId = branchId.Value;

                var result = await b2bBillingApiClient.TopUpWalletAsync(request);
                if (result != null && result.Success)
                {
                    await auditLogService.LogActivityAsync(
                        eventType: "Franchise Wallet Top-Up",
                        actionName: "LAB.FranchiseWalletTopUp",
                        description: $"Wallet top-up of ₹{request.Amount:F2} processed for Franchise #{request.FranchiseId}. Receipt: {result.ReceiptNo}. New Balance: ₹{result.NewBalance:F2}.",
                        userId: User.GetUserId(),
                        branchId: branchId,
                        moduleCode: "LAB",
                        referenceNo: result.ReceiptNo
                    );
                    return Json(new { success = true, receiptNo = result.ReceiptNo, newBalance = result.NewBalance, message = result.Message });
                }
                return Json(new { success = false, error = result?.Message ?? "Wallet top-up failed." });
            }
            catch (Exception ex)
            {
                return Json(new { success = false, error = ex.Message });
            }
        }

        [HttpGet]
        public async Task<IActionResult> FranchiseWalletStatement(int franchiseId, DateTime? fromDate, DateTime? toDate)
        {
            try
            {
                var statement = await b2bBillingApiClient.GetWalletStatementAsync(franchiseId, fromDate, toDate);
                return Json(new { success = true, data = statement });
            }
            catch (Exception ex)
            {
                return Json(new { success = false, error = ex.Message });
            }
        }

        [HttpGet]
        public async Task<IActionResult> B2BSettlement(string? agentType = "F", int? agentId = null)
        {
            var branchId = User.GetCurrentBranchId();
            if (branchId == null)
            {
                TempData["Error"] = "Please select a branch first.";
                return RedirectToAction("SelectBranch", "Account");
            }

            ViewBag.SelectedAgentType = agentType ?? "F";
            ViewBag.SelectedAgentId = agentId ?? 0;

            try
            {
                var franchises = await franchiseApiClient.GetListAsync(status: null, isActive: true);
                ViewBag.Franchises = franchises.OrderBy(f => f.Franchise_Name)
                    .Select(f => new SelectListItem { Value = f.Franchise_ID.ToString(), Text = $"{f.Franchise_Name} ({f.Franchise_Code})" })
                    .ToList();
            }
            catch
            {
                ViewBag.Franchises = new List<SelectListItem>();
            }

            try
            {
                var corporates = await corporateApiClient.GetListAsync(type: null, status: true);
                ViewBag.Corporates = corporates.OrderBy(c => c.Corporate_Name)
                    .Select(c => new SelectListItem { Value = c.Corporate_ID.ToString(), Text = $"{c.Corporate_Name} ({c.Corporate_Code})" })
                    .ToList();
            }
            catch
            {
                ViewBag.Corporates = new List<SelectListItem>();
            }

            try
            {
                var paymentMethods = await paymentService.GetActiveMethodsAsync();
                ViewBag.PaymentMethods = paymentMethods.Select(m => new SelectListItem { Value = m.PaymentMethodId.ToString(), Text = m.MethodName }).ToList();
            }
            catch
            {
                ViewBag.PaymentMethods = new List<SelectListItem>();
            }

            return View();
        }

        [HttpGet]
        public async Task<IActionResult> GetOutstandingBillsForSettlement(string agentType, int agentId)
        {
            try
            {
                var branchId = User.GetCurrentBranchId();
                var partnerStatus = await b2bBillingApiClient.GetPartnerCreditStatusAsync(agentType, agentId, branchId);
                var bills = await b2bBillingApiClient.GetOutstandingBillsForSettlementAsync(agentType, agentId);
                return Json(new { success = true, partner = partnerStatus, bills });
            }
            catch (Exception ex)
            {
                return Json(new { success = false, error = ex.Message });
            }
        }

        [HttpPost]
        public async Task<IActionResult> SettleBillsPayment([FromBody] B2BSettleBillsRequestDto request)
        {
            try
            {
                var branchId = User.GetCurrentBranchId();
                if (branchId.HasValue) request.BranchId = branchId.Value;

                if (request.PaidAmount <= 0)
                {
                    return Json(new { success = false, error = "Payment amount must be greater than zero." });
                }

                if (request.SelectedBills == null || !request.SelectedBills.Any())
                {
                    return Json(new { success = false, error = "Please select at least one bill or invoice to settle." });
                }

                var result = await b2bBillingApiClient.SettleBillsPaymentAsync(request);
                if (result != null && result.Success)
                {
                    await auditLogService.LogActivityAsync(
                        eventType: "B2B Multi-Bill Settlement",
                        actionName: "LAB.B2BSettlement",
                        description: $"B2B Multi-bill settlement of ₹{request.PaidAmount:F2} processed for {request.AgentType} #{request.AgentId}. Batch Receipt: {result.BatchReceiptNo}. Settled Bill Count: {result.SettledBillCount}.",
                        userId: User.GetUserId(),
                        branchId: branchId,
                        moduleCode: "LAB",
                        referenceNo: result.BatchReceiptNo
                    );
                    return Json(new { success = true, batchReceiptNo = result.BatchReceiptNo, count = result.SettledBillCount, message = result.Message });
                }
                return Json(new { success = false, error = result?.Message ?? "Payment settlement failed." });
            }
            catch (Exception ex)
            {
                return Json(new { success = false, error = ex.Message });
            }
        }

        [HttpGet]
        public async Task<IActionResult> PrintSettlementReceipt(string receiptNo)
        {
            if (string.IsNullOrWhiteSpace(receiptNo))
            {
                return BadRequest("Receipt number is required.");
            }

            var receipt = await b2bBillingApiClient.GetSettlementReceiptAsync(receiptNo);
            if (receipt == null)
            {
                return NotFound($"Settlement receipt '{receiptNo}' was not found.");
            }

            var branchId = receipt.BranchId > 0 ? receipt.BranchId : (User.GetCurrentBranchId() ?? 1);

            // Fetch hospital settings for this branch (fallback to any active hospital settings)
            var settings = await dbContext.HospitalSettings
                .Where(s => s.BranchId == branchId && s.IsActive)
                .FirstOrDefaultAsync()
                ?? await dbContext.HospitalSettings.FirstOrDefaultAsync(s => s.IsActive);

            var vm = new PrintSettlementReceiptViewModel
            {
                // Hospital
                HospitalName           = settings?.HospitalName ?? "eMeditech Hospital",
                HospitalType           = settings?.HospitalType,
                RegistrationNumber     = settings?.RegistrationNumber,
                HospitalAddress        = settings?.Address,
                HospitalPhone          = settings?.ContactNumber1,
                HospitalEmergencyPhone = settings?.EmergencyNumber,
                HospitalEmail          = settings?.EmailAddress,
                HospitalWebsite        = settings?.Website,
                HospitalGSTIN          = settings?.GSTCode,
                HospitalLogoPath       = settings?.LogoPath,
                BranchName             = receipt.BranchName,
                NabhStatus             = settings?.NabhStatus,
                NabhCertificateNo      = settings?.NabhCertificateNo,

                // Receipt
                ReceiptNo              = receipt.ReceiptNo,
                PaymentDate            = receipt.PaymentDate,
                CreatedDate            = receipt.CreatedDate,
                TotalAmount            = receipt.TotalAmount,
                SettledBillCount       = receipt.SettledBillCount,
                PaymentMethod          = receipt.PaymentMethod,
                TransactionRef         = receipt.TransactionRef,
                BankName               = receipt.BankName,
                ChequeNo               = receipt.ChequeNo,
                Notes                  = receipt.Notes,
                CreatedByName          = receipt.CreatedByName,
                DebitLedgerName        = receipt.DebitLedgerName,
                CreditLedgerName       = receipt.CreditLedgerName,

                // Partner
                AgentType              = receipt.AgentType,
                AgentId                = receipt.AgentId,
                PartnerName            = receipt.PartnerName,
                PartnerCode            = receipt.PartnerCode,
                PartnerType            = receipt.PartnerType,
                PartnerPhone           = receipt.PartnerPhone,
                PartnerEmail           = receipt.PartnerEmail,
                PartnerAddress         = receipt.PartnerAddress,

                // Bills
                Bills                  = receipt.Bills
            };

            return View("PrintSettlementReceipt", vm);
        }

        [HttpGet]
        public async Task<IActionResult> B2BInvoices(string? agentType, int? agentId, string? status, DateTime? fromDate, DateTime? toDate, string? search, int page = 1)
        {
            var branchId = User.GetCurrentBranchId();
            if (branchId == null)
            {
                TempData["Error"] = "Please select a branch first.";
                return RedirectToAction("SelectBranch", "Account");
            }

            try
            {
                var franchises = await franchiseApiClient.GetListAsync(status: null, isActive: true);
                ViewBag.Franchises = franchises.OrderBy(f => f.Franchise_Name)
                    .Select(f => new SelectListItem { Value = f.Franchise_ID.ToString(), Text = $"{f.Franchise_Name} ({f.Franchise_Code})" })
                    .ToList();
            }
            catch
            {
                ViewBag.Franchises = new List<SelectListItem>();
            }

            try
            {
                var corporates = await corporateApiClient.GetListAsync(type: null, status: true);
                ViewBag.Corporates = corporates.OrderBy(c => c.Corporate_Name)
                    .Select(c => new SelectListItem { Value = c.Corporate_ID.ToString(), Text = $"{c.Corporate_Name} ({c.Corporate_Code})" })
                    .ToList();
            }
            catch
            {
                ViewBag.Corporates = new List<SelectListItem>();
            }

            ViewBag.CurrentAgentType = agentType;
            ViewBag.CurrentAgentId = agentId;
            ViewBag.CurrentStatus = status;
            ViewBag.FromDate = fromDate?.ToString("yyyy-MM-dd");
            ViewBag.ToDate = toDate?.ToString("yyyy-MM-dd");
            ViewBag.Search = search;
            ViewBag.CurrentPage = page;

            var invoices = await b2bBillingApiClient.GetInvoiceListAsync(agentType, agentId, status, fromDate, toDate, search, page, 15);
            return View(invoices);
        }

        [HttpGet]
        public async Task<IActionResult> GetUninvoicedOrders(string agentType, int? agentId = null, string? agentIds = null, DateTime? fromDate = null, DateTime? toDate = null)
        {
            try
            {
                var orders = await b2bBillingApiClient.GetUninvoicedOrdersAsync(agentType, agentId, agentIds, fromDate, toDate);
                return Json(new { success = true, orders });
            }
            catch (Exception ex)
            {
                return Json(new { success = false, error = ex.Message });
            }
        }

        [HttpPost]
        public async Task<IActionResult> GenerateInvoice([FromBody] GenerateInvoiceRequestDto request)
        {
            try
            {
                var branchId = User.GetCurrentBranchId();
                if (branchId.HasValue) request.BranchId = branchId.Value;

                bool hasGroups = request.PartnerGroups != null && request.PartnerGroups.Any(g => !string.IsNullOrWhiteSpace(g.SelectedOrderIds));
                bool hasSingle = request.AgentId > 0 && !string.IsNullOrWhiteSpace(request.SelectedOrderIds);

                if (!hasGroups && !hasSingle)
                {
                    return Json(new { success = false, error = "Please select at least one order to include in the invoice." });
                }

                var result = await b2bBillingApiClient.GenerateInvoiceAsync(request);
                if (result != null && result.Success)
                {
                    if (result.GeneratedInvoices != null && result.GeneratedInvoices.Count > 1)
                    {
                        foreach (var inv in result.GeneratedInvoices)
                        {
                            await auditLogService.LogActivityAsync(
                                eventType: "B2B Invoicing",
                                actionName: "LAB.B2BInvoiceGenerated",
                                description: $"B2B Batch Invoice {inv.InvoiceNo} generated for {inv.PartnerName} ({inv.OrderCount} orders, ₹ {inv.TotalAmount:N2}).",
                                userId: User.GetUserId(),
                                branchId: branchId,
                                moduleCode: "LAB",
                                referenceNo: inv.InvoiceNo,
                                referenceId: inv.InvoiceId
                            );
                        }
                    }
                    else
                    {
                        await auditLogService.LogActivityAsync(
                            eventType: "B2B Invoicing",
                            actionName: "LAB.B2BInvoiceGenerated",
                            description: $"B2B Invoice {result.InvoiceNo} generated for {request.AgentType} #{request.AgentId}.",
                            userId: User.GetUserId(),
                            branchId: branchId,
                            moduleCode: "LAB",
                            referenceNo: result.InvoiceNo,
                            referenceId: result.InvoiceId
                        );
                    }

                    return Json(new {
                        success = true,
                        invoiceId = result.InvoiceId,
                        encryptedInvoiceId = encryptionService.EncryptParameters(new Dictionary<string, string?> { ["id"] = result.InvoiceId.ToString() }),
                        invoiceNo = result.InvoiceNo,
                        message = result.Message,
                        generatedInvoices = result.GeneratedInvoices?.Select(g => new {
                            g.InvoiceId,
                            encryptedInvoiceId = encryptionService.EncryptParameters(new Dictionary<string, string?> { ["id"] = g.InvoiceId.ToString() }),
                            g.InvoiceNo, g.PartnerName, g.PartnerCode, g.OrderCount, g.TotalAmount
                        })
                    });
                }
                return Json(new { success = false, error = result?.Message ?? "Failed to generate invoice." });
            }
            catch (Exception ex)
            {
                return Json(new { success = false, error = ex.Message });
            }
        }

        [HttpGet]
        public async Task<IActionResult> B2BInvoiceDetail(int id)
        {
            var detail = await b2bBillingApiClient.GetInvoiceDetailAsync(id);
            if (detail == null)
            {
                TempData["Error"] = "Invoice not found.";
                return RedirectToAction(nameof(B2BInvoices));
            }
            return View(detail);
        }

        #endregion
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
