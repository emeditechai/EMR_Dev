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
using EMR.Shared.Security;
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
        ILogger<LabOrderBookingController> logger,
        EMR.Shared.Security.IActionPermissionGuard permissionGuard,
        IPatientPortalLoginService portalLoginService,
        IBillingSubmissionApiClient billingSubmissionApiClient) : Controller
    {
        /// <summary>One bill per booking (SQLScripts/2310): the billed tests / packages / misc lines, to tell a retry of the
        /// same booking from a changed one.</summary>
        private static string LabItemsSignature(IEnumerable<LabOrderItemRequestDto> items, IEnumerable<object>? misc)
        {
            var parts = items.Select(x => $"{x.Type}:{x.InvestigationId}:{x.Price:0.00}").OrderBy(x => x, StringComparer.Ordinal).ToList();
            if (misc != null) parts.AddRange(misc.Select(m => "M:" + System.Text.Json.JsonSerializer.Serialize(m)).OrderBy(x => x, StringComparer.Ordinal));
            var text = string.Join(",", parts);
            return text.Length <= 1000 ? text
                : Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(text)));
        }

        /// <summary>For a franchise login the partner on a B2B bill is always its own franchise, whatever the form posted.</summary>
        private void LockToOwnFranchise(LabOrderBookingViewModel model)
        {
            if (User.GetFranchiseId() is not int ownFranchiseId) return;
            model.IsB2B = true;
            model.AgentType = "F";
            model.B2BAgentId = ownFranchiseId;
        }

        /// <summary>A franchise login sees and acts only for its own franchise on the B2B invoice / settlement screens,
        /// whoever generated the invoice; other logins: any partner. True when the partner is allowed.</summary>
        private bool FranchiseMayUsePartner(string? agentType, int? agentId)
        {
            if (User.GetFranchiseId() is not int ownFranchiseId) return true;
            var type = agentType?.Trim().ToUpperInvariant();
            return (type == "F" || type == "FRANCHISE") && agentId == ownFranchiseId;
        }

        /// <summary>True unless a franchise login asks for a bill that is not its own (created by that login, or for its franchise - 2258).</summary>
        private async Task<bool> FranchiseOwnsOrderAsync(int labOrderId)
        {
            if (User.GetFranchiseId() is not int ownFranchiseId) return true;
            var owned = await dbContext.Database
                .SqlQuery<int>($"SELECT COUNT(1) AS Value FROM dbo.LabOrder WHERE LabOrderId = {labOrderId} AND ((AgentType = 'F' AND B2BAgentID = {ownFranchiseId}) OR CreatedBy = {User.GetUserId()})")
                .SingleAsync();
            return owned > 0;
        }

        [HttpGet]
        public async Task<IActionResult> B2BBooking(int? patientId)
        {
            var model = new LabOrderBookingViewModel
            {
                IsB2B = true,
                AgentType = "F",
                CollectionType = "B2BCollector"
            };
            // a franchise login bills only for its own franchise: preselected, and the selector is locked in the view
            if (User.GetFranchiseId() is int ownFranchiseId)
            {
                model.B2BAgentId = ownFranchiseId;
            }

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
        public async Task<IActionResult> B2BBooking(
            LabOrderBookingViewModel model, IFormFile? identificationFile, IFormFile? profilePictureFile,
            IFormFile? prescriptionFile, string? prescriptionRemarks,
            IFormFile? ovdDocumentFile, string? ovdDocumentRemarks,
            IFormFile? consentFile, string? consentRemarks)
        {
            model.IsB2B = true;
            LockToOwnFranchise(model);
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
                else if (PaymentService.HasDiscount(discountCheck)
                         && !await permissionGuard.AllowsAsync(HttpContext, "LAB.LABORDERBOOKING.B2BBOOKING", EMR.Shared.Security.PermissionControls.Discount))
                    ModelState.AddModelError(string.Empty, PaymentService.DiscountNotPermittedMessage);
                // Hospital Settings "Block Billing Until Day Closed" (SQLScripts/2275)
                if (await DayClosingGuard.BlockMessageAsync(HttpContext, "LAB", branchId, User.GetUserId()) is string dayClosingBlock)
                    ModelState.AddModelError(string.Empty, dayClosingBlock);
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
                CompanyId = User.GetCompanyId(),
                IsActive = true
            };

            // an existing patient must be of the user's company (patients are company-wise; GetByIdAsync hides others)
            if (model.PatientId > 0 && await patientService.GetByIdAsync(model.PatientId) == null)
            {
                ModelState.AddModelError(string.Empty, "The selected patient does not belong to this company. Search the patient again.");
                await PopulateSelectLists(model);
                return View(model);
            }
            int actualPatientId = model.PatientId;
            if (model.PatientId == 0)
            {
                actualPatientId = await patientService.CreateDemographicsOnlyAsync(patient, User.GetUserId());
                patient.PatientId = actualPatientId;
                // the Patient ID is generated by the database: read it back for the success popup, bill audit and e-mail
                patient.PatientCode = (await patientService.GetByIdAsync(actualPatientId))?.PatientCode;
                await auditLogService.LogAsync("LAB", "Patient.Create", $"Registered patient: {patient.FirstName} {patient.LastName} for B2B LAB.");
            }
            else
            {
                var existing = await patientService.GetByIdAsync(model.PatientId);
                if (string.IsNullOrWhiteSpace(model.IdentificationFilePath)) patient.IdentificationFilePath = existing?.IdentificationFilePath;
                if (string.IsNullOrWhiteSpace(model.PhotoPath)) patient.PhotoPath = existing?.PhotoPath;
                // The B2B form has no religion, guardian, country/state/district/city/area, occupation, marital status,
                // language, allergies or remarks fields: keep what the patient already has (B2C / OPD may have set them).
                if (existing is not null)
                {
                    patient.ReligionId = existing.ReligionId;
                    patient.GuardianName = existing.GuardianName;
                    patient.CountryId = existing.CountryId;
                    patient.StateId = existing.StateId;
                    patient.DistrictId = existing.DistrictId;
                    patient.CityId = existing.CityId;
                    patient.AreaId = existing.AreaId;
                    patient.OccupationId = existing.OccupationId;
                    patient.MaritalStatusId = existing.MaritalStatusId;
                    patient.LanguageId = existing.LanguageId;
                    patient.KnownAllergies = existing.KnownAllergies;
                    patient.Remarks = existing.Remarks;
                }

                await patientService.UpdateDemographicsAsync(patient, User.GetUserId());
                patient.PatientCode = existing?.PatientCode;   // after the save: the update itself is unchanged
            }

            if (model.DemographicsOnly)
            {
                TempData["Success"] = $"Patient demographics updated successfully.";
                return RedirectToAction(nameof(B2BBooking), new { patientId = actualPatientId });
            }

            decimal totalAmount = lineItems!.Sum(x => x.Price);
            decimal b2bTotal = lineItems!.Sum(x => x.B2BRate ?? x.Price);

            // ── Misc charges (SQLScripts/2240): the partner is charged them with their GST - priced from the master here
            //    for the credit / wallet checks; the order procedure prices them again and adds them to the B2B total ──
            var (b2bMisc, b2bMiscError) = EMR.Web.Services.LabMiscCharges.Parse(model.MiscChargesJson);
            var b2bMiscPrices = new List<EMR.Web.Services.LabMiscChargePrice>();
            if (b2bMiscError == null && b2bMisc.Count > 0)
                (b2bMiscPrices, b2bMiscError) = await EMR.Web.Services.LabMiscCharges.PriceAsync(dbContext.Database.GetDbConnection(), branchId.Value, b2bMisc);
            if (b2bMiscError != null)
            {
                ModelState.AddModelError(string.Empty, b2bMiscError);
                await PopulateSelectLists(model);
                return View(model);
            }
            decimal b2bTestsTotal = b2bTotal;
            b2bTotal += b2bMiscPrices.Sum(x => x.Total);

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

                // a franchise login on a Prepaid (Wallet) facility pays from its wallet only - no spot payment
                if (creditStatus.CreditFacilityType == 1 && User.IsFranchiseUser())
                {
                    if (!string.IsNullOrWhiteSpace(model.PaymentDataJson))
                    {
                        ModelState.AddModelError(string.Empty, "Spot payment is not available for a franchise login. The bill is paid from the franchise wallet.");
                        await PopulateSelectLists(model);
                        return View(model);
                    }
                    model.DeductFromWallet = true;
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
                            ModelState.AddModelError(string.Empty, $"Insufficient wallet balance for {creditStatus.PartnerName}! Available Wallet: ₹{creditStatus.WalletBalance:N2}, Required: ₹{b2bTotal:N2} (Deficit: ₹{deficit:N2}). " + (User.IsFranchiseUser() ? "Please contact the lab to top up your wallet." : "Please recharge wallet or complete spot payment."));
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
                B2BTotal = b2bTestsTotal,            // the procedure adds the misc charges (with GST)
                CreatedBy = User.GetUserId(),
                Items = lineItems!,
                MiscCharges = b2bMisc
            };

            LabOrderResponseDto labOrderRes;
            try
            {
                labOrderRes = await labOrderApiClient.CreateOrderAsync(labOrderReq);
            }
            catch (InvalidOperationException ex)
            {
                // a billing rule refused the order (e.g. a test not on the branch's rate list - script 2199)
                ModelState.AddModelError(string.Empty, ex.Message);
                await PopulateSelectLists(model);
                return View(model);
            }
            await labOrderApiClient.CreateSampleCollectionAsync(labOrderRes.LabOrderId, branchId.Value, patient.CompanyId, User.GetUserId());
            await SaveComplianceDocumentsAsync(labOrderRes.LabOrderId,
                prescriptionFile, prescriptionRemarks, ovdDocumentFile, ovdDocumentRemarks, consentFile, consentRemarks);

            // Post B2B Bill Ledger (Dr Franchise Receivable or Corporate Receivable, Cr LAB Revenue)
            // NOTE: b2bShowPrintBarcode is resolved after payment processing below (same ordering as B2C).
            bool b2bShowPrintBarcode = false;
            // misc charges: the bill's own B2B total; its GST goes to GST Output Payable, not to revenue
            var b2bMiscTotals = await ReadLabMiscTotalsAsync(labOrderRes.LabOrderId);
            if (b2bMiscTotals.B2BTotal > 0) b2bTotal = b2bMiscTotals.B2BTotal;
            await ledgerService.PostB2BLabBillLedgerAsync(labOrderRes.LabOrderId, b2bTotal - b2bMiscTotals.MiscGst, model.AgentType, model.B2BAgentId.Value, branchId, patient.CompanyId, User.GetUserId(), labOrderRes.BillNo);
            await SyncLabGstAsync(labOrderRes.LabOrderId);

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
                {
                    b2bShowPrintBarcode = b2bSettings.BarcodeGenerateAtBilling;
                    if (b2bShowPrintBarcode)
                    {
                        var conn = dbContext.Database.GetDbConnection();
                        b2bShowPrintBarcode = await conn.ExecuteScalarAsync<bool>(
                            "SELECT CASE WHEN EXISTS (SELECT 1 FROM dbo.SampleCollection WHERE Laborderid = @LabOrderId AND BarcodeNo IS NOT NULL AND LTRIM(RTRIM(BarcodeNo)) <> '') THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END",
                            new { LabOrderId = labOrderRes.LabOrderId });
                    }
                }
            }
            catch
            {
                // Non-blocking: settings lookup failure must not interrupt B2B billing
            }
            // ─────────────────────────────────────────────────────────────────────────────────────────

            string patientFullName = ((patient.Salutation ?? "") + " " + patient.FirstName + " " + patient.LastName).Trim();

            // ── TRIGGER BACKGROUND EMAIL/WHATSAPP BILL NOTIFICATION (B2B) ───────────────────
            // Gated by the booking Franchise's "Notification Required" flag (Master > Franchise Setup):
            // a franchise with it switched off never has its patients notified - it hands the bill to
            // the patient itself instead. Corporate (AgentType == "C") bookings are not gated by this flag.
            {
                var savedLabOrderId = labOrderRes.LabOrderId;
                var savedBillNo = labOrderRes.BillNo;
                var safeBillNo = savedBillNo?.Replace("/", "_").Replace("\\", "_");
                var patientEmail = patient.EmailId;
                var patientNameStr = patientFullName;
                var bId = branchId.Value;
                var hostUrl = $"{Request.Scheme}://{Request.Host}{Request.PathBase}";
                var b2bAgentType = model.AgentType;
                var b2bFranchiseId = model.B2BAgentId;
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
                        bool franchiseBlocksNotification = false;
                        if (string.Equals(b2bAgentType, "F", StringComparison.OrdinalIgnoreCase) && b2bFranchiseId.HasValue)
                        {
                            var allow = await db.Database.GetDbConnection().QueryFirstOrDefaultAsync<bool?>(
                                "SELECT IsNotificationRequired FROM dbo.LabFranchiseMaster WHERE Franchise_ID = @Id",
                                new { Id = b2bFranchiseId.Value });
                            franchiseBlocksNotification = allow != true;
                        }

                        if (franchiseBlocksNotification)
                        {
                            logger.LogInformation("[LAB-NOTIF] Franchise notification disabled for FranchiseId {Id} - skipping LAB bill Email/WhatsApp for LabOrderId {LabOrderId}", b2bFranchiseId, savedLabOrderId);
                            return;
                        }

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
                                    string body = LabBillEmail.Body(hs.HospitalName, patientNameStr, savedBillNo, hs.Address);

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
            // ─────────────────────────────────────────────────────────────────────────────────────────

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
                CompanyId = User.GetCompanyId(),
                IsActive = true
            };

            // an existing patient must be of the user's company (patients are company-wise; GetByIdAsync hides others)
            if (model.PatientId > 0 && await patientService.GetByIdAsync(model.PatientId) == null)
            {
                ModelState.AddModelError(string.Empty, "The selected patient does not belong to this company. Search the patient again.");
                await PopulateSelectLists(model);
                return View(model);
            }
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
            // misc charges (SQLScripts/2240)
            var (legacyMisc, legacyMiscError) = EMR.Web.Services.LabMiscCharges.Parse(model.MiscChargesJson);
            if (legacyMiscError != null)
            {
                ModelState.AddModelError(string.Empty, legacyMiscError);
                await PopulateSelectLists(model);
                return View(model);
            }
            labOrderReq.MiscCharges = legacyMisc;

            LabOrderResponseDto labOrderRes;
            try
            {
                labOrderRes = await labOrderApiClient.CreateOrderAsync(labOrderReq);
            }
            catch (InvalidOperationException ex)
            {
                // a billing rule refused the order (e.g. a test not on the branch's rate list - script 2199)
                ModelState.AddModelError(string.Empty, ex.Message);
                await PopulateSelectLists(model);
                return View(model);
            }
            await labOrderApiClient.CreateSampleCollectionAsync(labOrderRes.LabOrderId, branchId.Value, patient.CompanyId, User.GetUserId());

            decimal totalAmount = lineItems!.Sum(x => x.Price);
            var legacyMiscTotals = await ReadLabMiscTotalsAsync(labOrderRes.LabOrderId);
            await ledgerService.PostLabBillLedgerAsync(labOrderRes.LabOrderId, totalAmount + legacyMiscTotals.MiscAmount, branchId, patient.CompanyId, User.GetUserId(), labOrderRes.BillNo);
            await SyncLabGstAsync(labOrderRes.LabOrderId);

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

            await TryCreatePortalLoginForB2CAsync(branchId.Value, actualPatientId, patient.PatientCode, patient);

            TempData["NewPatientName"]  = patientFullName;
            TempData["BillNo"]          = labOrderRes.BillNo;
            TempData["NewLabOrderId"]   = labOrderRes.LabOrderId.ToString();
            return RedirectToAction(nameof(B2CBooking), new { registered = true });
        }

        /// <summary>
        /// Hospital Settings "Required Patient Portal" (script 2219, checked in PatientPortalLoginService for OPD and B2C
        /// alike): when Yes, the booked patient gets a Patient Portal login with the credentials sent, once per patient.
        /// B2B bookings never call this. Never stops or delays the booking.
        /// </summary>
        private async Task TryCreatePortalLoginForB2CAsync(int branchId, int patientId, string? patientCode, PatientMaster patient)
        {
            try
            {
                if (string.IsNullOrWhiteSpace(patientCode)) patientCode = (await patientService.GetByIdAsync(patientId))?.PatientCode;
                if (string.IsNullOrWhiteSpace(patientCode)) return;
                await portalLoginService.TryGenerateAsync(patientId, patientCode, patient.PhoneNumber ?? "", patient.EmailId ?? "",
                    patient.FirstName + " " + patient.LastName, branchId);
            }
            catch (Exception ex)
            {
                logger.LogWarning(ex, "Patient Portal login for B2C LAB patient {PatientId} was not created.", patientId);
            }
        }

        [HttpPost]
        public async Task<IActionResult> SaveBookingWithPayment(
            [FromForm] LabOrderBookingViewModel model,
            [FromForm] IFormFile? profilePictureFile,
            [FromForm] IFormFile? identificationFile,
            [FromForm] string? paymentDataJson,
            [FromForm] IFormFile? prescriptionFile,
            [FromForm] string? prescriptionRemarks,
            [FromForm] IFormFile? ovdDocumentFile,
            [FromForm] string? ovdDocumentRemarks,
            [FromForm] IFormFile? consentFile,
            [FromForm] string? consentRemarks,
            [FromForm] string? bookingRequestKey)
        {
            LockToOwnFranchise(model);
            // One bill per booking (SQLScripts/2310): the key of this booking form; a retry reuses the bill it created
            Guid requestKey = Guid.TryParse(bookingRequestKey, out var rk) ? rk : Guid.Empty;
            bool keyClaimed = false;      // this request holds the key and has not created the bill yet
            try
            {
            var branchId = User.GetCurrentBranchId();
            if (branchId == null)
            {
                return Json(new { success = false, error = "Please select a branch first." });
            }

            // Hospital Settings "Block Billing Until Day Closed" (SQLScripts/2275): refuse before anything is saved
            if (await DayClosingGuard.BlockMessageAsync(HttpContext, "LAB", branchId, User.GetUserId()) is string dayClosingBlock)
                return Json(new { success = false, error = dayClosingBlock });

            // A discount must carry its reason and approver: refuse before anything is saved.
            if (!string.IsNullOrWhiteSpace(paymentDataJson))
            {
                SavePaymentRequest? discountCheck = null;
                try { discountCheck = System.Text.Json.JsonSerializer.Deserialize<SavePaymentRequest>(paymentDataJson, new System.Text.Json.JsonSerializerOptions { PropertyNameCaseInsensitive = true }); }
                catch { /* malformed payment data is reported by the normal flow */ }
                if (PaymentService.IsDiscountApprovalMissing(discountCheck))
                    return Json(new { success = false, error = PaymentService.DiscountApprovalRequiredMessage });
                if (PaymentService.HasDiscount(discountCheck)
                    && !await permissionGuard.AllowsAsync(HttpContext, "LAB.LABORDERBOOKING.B2CBOOKING", EMR.Shared.Security.PermissionControls.Discount))
                    return Json(new { success = false, error = PaymentService.DiscountNotPermittedMessage });
                // membership points: a wrong / expired OTP is refused before the order is created
                var otpError = await paymentService.VerifyRedeemOtpAsync(discountCheck);
                if (otpError != null)
                    return Json(new { success = false, error = otpError });
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

            // misc charges (SQLScripts/2240): ids and quantities only - priced from the master by the order procedure
            var (bookingMisc, bookingMiscError) = EMR.Web.Services.LabMiscCharges.Parse(model.MiscChargesJson);
            if (bookingMiscError != null)
                return Json(new { success = false, error = bookingMiscError });

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

            // ── One bill per booking (SQLScripts/2310) ─────────────────────────────────────────────────────────
            // A retry of this booking (payment refused / timed out, Collect clicked again) reuses the bill created the
            // first time - same bill no. and, once paid, the same token - instead of creating a second bill.
            var itemsSignature = LabItemsSignature(lineItems, bookingMisc?.Cast<object>());
            BillingSubmissionClaim? reuse = null;
            if (requestKey != Guid.Empty)
            {
                var claim = await billingSubmissionApiClient.ClaimAsync(requestKey, "LAB", User.GetUserId());
                switch (claim.Status)
                {
                    case "BUSY":
                        return Json(new { success = false, error = "This booking is still being saved. Please wait a few seconds and check the B2C Order List before clicking Collect again." });
                    case "EXISTS" when claim.ModuleRefId is > 0:
                        if (!string.Equals(claim.Stage, "READY", StringComparison.OrdinalIgnoreCase))
                            return Json(new { success = false, billNo = claim.BillNo,
                                error = $"Bill {claim.BillNo} was already created for this booking, but its set-up did not finish. Open it from the B2C Order List (collect its payment there) instead of booking again." });
                        if (!string.Equals(claim.ItemsSignature, itemsSignature, StringComparison.Ordinal))
                            return Json(new { success = false, billNo = claim.BillNo,
                                error = $"Bill {claim.BillNo} was already created for this booking with a different list of tests. Collect its payment from the B2C Order List, or cancel it there, before billing other tests." });
                        if (claim.HasPayment)
                            return await LabBookingAlreadySavedAsync(claim, model, branchId.Value);
                        reuse = claim;
                        break;
                    case "NEW":
                        keyClaimed = true;
                        break;
                    default:
                        requestKey = Guid.Empty;   // a key of another user / module: book as before, without retry protection
                        break;
                }
            }

            var patient = new PatientMaster
            {
                PatientId = reuse?.PatientId ?? model.PatientId,
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
                CompanyId = User.GetCompanyId(),
                IsActive = true
            };

            // an existing patient must be of the user's company (patients are company-wise; GetByIdAsync hides others)
            if (model.PatientId > 0 && await patientService.GetByIdAsync(model.PatientId) == null)
                return Json(new { success = false, error = "The selected patient does not belong to this company. Search the patient again." });
            int actualPatientId = model.PatientId;
            string actualPatientCode = model.PatientCode ?? string.Empty;
            LabOrderResponseDto labOrderRes;
            decimal totalAmount = lineItems.Sum(x => x.Price);
            string patientFullName;
            if (reuse != null)
            {
                // retry of a booking whose bill exists: the patient and the bill were saved the first time - only the payment is left
                actualPatientId = reuse.PatientId ?? model.PatientId;
                var savedPatient = await patientService.GetByIdAsync(actualPatientId);
                actualPatientCode = savedPatient?.PatientCode ?? actualPatientCode;
                patient.PatientId = actualPatientId;
                labOrderRes = new LabOrderResponseDto { LabOrderId = reuse.ModuleRefId!.Value, BillNo = reuse.BillNo ?? string.Empty, TokenNo = reuse.TokenNo ?? string.Empty };
                patientFullName = ((patient.Salutation ?? "") + " " + patient.FirstName + " " + patient.LastName).Trim();
                await auditLogService.LogActivityAsync(
                    eventType: "LAB Billing",
                    actionName: "LAB.OrderRetryPayment",
                    description: $"Payment retried on Lab Order Bill {labOrderRes.BillNo} (the same booking - no new bill created).",
                    userId: User.GetUserId(), branchId: branchId, moduleCode: "LAB",
                    referenceNo: labOrderRes.BillNo, referenceId: labOrderRes.LabOrderId, patientCode: actualPatientCode,
                    metadata: new { labOrderRes.LabOrderId, labOrderRes.BillNo, RequestKey = requestKey });
            }
            else
            {
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
                Items = lineItems,
                MiscCharges = bookingMisc
            };

            try
            {
                labOrderRes = await labOrderApiClient.CreateOrderAsync(labOrderReq);
            }
            catch (InvalidOperationException ex)
            {
                // a billing rule refused the order (e.g. a test not on the branch's rate list - script 2199)
                await ReleaseBookingKeyAsync(requestKey, keyClaimed);
                return Json(new { success = false, error = ex.Message });
            }
            if (requestKey != Guid.Empty)
            {
                // the bill exists: from here a retry of this booking reuses it
                await billingSubmissionApiClient.UpdateAsync(requestKey, labOrderRes.LabOrderId, labOrderRes.BillNo, actualPatientId, itemsSignature, "CREATED");
                keyClaimed = false;
            }
            await labOrderApiClient.CreateSampleCollectionAsync(labOrderRes.LabOrderId, branchId.Value, patient.CompanyId, User.GetUserId());
            await SaveComplianceDocumentsAsync(labOrderRes.LabOrderId,
                prescriptionFile, prescriptionRemarks, ovdDocumentFile, ovdDocumentRemarks, consentFile, consentRemarks);

            // revenue = tests + misc charges (taxable); the misc GST goes to GST Output Payable
            var bookingMiscTotals = await ReadLabMiscTotalsAsync(labOrderRes.LabOrderId);
            await ledgerService.PostLabBillLedgerAsync(labOrderRes.LabOrderId, totalAmount + bookingMiscTotals.MiscAmount, branchId, patient.CompanyId, User.GetUserId(), labOrderRes.BillNo);
            await SyncLabGstAsync(labOrderRes.LabOrderId);

            patientFullName = ((patient.Salutation ?? "") + " " + patient.FirstName + " " + patient.LastName).Trim();
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

            await TryCreatePortalLoginForB2CAsync(branchId.Value, actualPatientId, actualPatientCode, patient);

            // the bill is fully set up: a retry of this booking now only redoes the payment
            if (requestKey != Guid.Empty)
                await billingSubmissionApiClient.UpdateAsync(requestKey, labOrderRes.LabOrderId, null, null, null, "READY");
            }

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
                            if (string.Equals(li.ServiceType, EMR.Web.Services.LabMiscCharges.ServiceType, StringComparison.OrdinalIgnoreCase)) continue;   // misc lines are rebuilt by the payment
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
                        // the bill stays as it is: correcting the payment and clicking Collect again pays this same bill
                        var payError = paymentResult.Error ?? "Failed to save payment.";
                        if (requestKey != Guid.Empty)
                            payError += $" Bill {labOrderRes.BillNo} is kept for this booking - correct the payment and click Collect again; the same bill no. will be used.";
                        return Json(new { success = false, error = payError, billNo = labOrderRes.BillNo, labOrderId = labOrderRes.LabOrderId });
                    }

                    if (paymentResult != null && paymentResult.Success)
                    {
                        var statusStr = paymentResult.PaymentStatus == "P" ? "Fully Paid" : "Partial Payment";
                        var paidAmt = paymentReq.Payments?.Sum(p => p.PaidAmount) ?? paymentResult.TotalPaid;
                        var receiptNo = paymentResult.PaymentHeaderId.HasValue ? $"RCP-{paymentResult.PaymentHeaderId}" : labOrderRes.BillNo;
                        await auditLogService.LogActivityAsync(
                            eventType: "Payment Collection",
                            actionName: "LAB.PaymentReceived",
                            description: $"Payment of ₹{paidAmt:F2} collected for Lab Order {labOrderRes.BillNo}{(string.IsNullOrWhiteSpace(labOrderRes.TokenNo?.ToString()) ? "" : $" (Token: {labOrderRes.TokenNo})")}. Receipt: {receiptNo}. Status: {statusStr}. Balance Due: ₹{paymentResult.BalanceDue:F2}.",
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
                                // B2B Franchise gate: a franchise with "Notification Required" switched off
                                // never has its patients emailed the bill - the franchise handles delivery instead.
                                bool franchiseBlocksEmail = false;
                                if (model.IsB2B && model.AgentType == "F" && model.B2BAgentId.HasValue)
                                {
                                    var franchiseAllowsNotification = await db.Database.GetDbConnection().QueryFirstOrDefaultAsync<bool?>(
                                        "SELECT IsNotificationRequired FROM dbo.LabFranchiseMaster WHERE Franchise_ID = @Id",
                                        new { Id = model.B2BAgentId.Value });
                                    franchiseBlocksEmail = franchiseAllowsNotification != true;
                                }

                                var hs = franchiseBlocksEmail ? null : await db.HospitalSettings.FirstOrDefaultAsync(s => s.BranchId == bId && s.IsActive);
                                if (franchiseBlocksEmail)
                                {
                                    logger.LogInformation("[LAB-NOTIF] Franchise notification disabled for B2BAgentId {Id} - skipping LAB bill email for LabOrderId {LabOrderId}", model.B2BAgentId, savedLabOrderId);
                                }
                                else if (hs != null && hs.LabEmailNotificationRequired)
                                {
                                    string subj = $"Your Lab Order Bill [{savedBillNo}] - {hs.HospitalName}";
                                    string body = LabBillEmail.Body(hs.HospitalName, patientNameStr, savedBillNo, hs.Address);

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
                    if (showPrintBarcode)
                    {
                        var conn = dbContext.Database.GetDbConnection();
                        showPrintBarcode = await conn.ExecuteScalarAsync<bool>(
                            "SELECT CASE WHEN EXISTS (SELECT 1 FROM dbo.SampleCollection WHERE Laborderid = @LabOrderId AND BarcodeNo IS NOT NULL AND LTRIM(RTRIM(BarcodeNo)) <> '') THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END",
                            new { LabOrderId = labOrderRes.LabOrderId });
                    }
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
                await ReleaseBookingKeyAsync(requestKey, keyClaimed);
                return Json(new { success = false, error = $"An error occurred while saving the booking: {ex.Message}" });
            }
        }

        /// <summary>One bill per booking (SQLScripts/2310): a request that stopped before creating the bill frees its key.</summary>
        private async Task ReleaseBookingKeyAsync(Guid requestKey, bool keyClaimed)
        {
            if (requestKey == Guid.Empty || !keyClaimed) return;
            try { await billingSubmissionApiClient.ReleaseAsync(requestKey); }
            catch (Exception ex) { logger.LogWarning(ex, "Could not release booking request key {Key}", requestKey); }
        }

        /// <summary>
        /// One bill per booking (SQLScripts/2310): the booking was saved with its payment already (e.g. the answer was lost
        /// on the way back) - answer with that bill instead of creating another one.
        /// </summary>
        private async Task<IActionResult> LabBookingAlreadySavedAsync(BillingSubmissionClaim claim, LabOrderBookingViewModel model, int branchId)
        {
            var labOrderId = claim.ModuleRefId!.Value;
            var con = dbContext.Database.GetDbConnection();
            if (con.State != System.Data.ConnectionState.Open) await con.OpenAsync();
            var ph = await con.QueryFirstOrDefaultAsync<(decimal NetAmount, decimal TotalPaid, decimal BalanceDue, string PaymentStatus, decimal SubTotal)>(@"
                SELECT ISNULL(NetAmount, 0), ISNULL(TotalPaid, 0), ISNULL(BalanceDue, 0), ISNULL(PaymentStatus, 'U'), ISNULL(SubTotal, 0)
                FROM dbo.PaymentHeader WHERE ModuleCode = 'LAB' AND ModuleRefId = @Id AND IsActive = 1", new { Id = labOrderId });
            var patient = claim.PatientId is > 0 ? await patientService.GetByIdAsync(claim.PatientId.Value) : null;
            var showPrintBarcode = await con.ExecuteScalarAsync<bool>(@"
                SELECT CASE WHEN EXISTS (SELECT 1 FROM dbo.HospitalSettings hs WHERE hs.BranchId = @BranchId AND hs.IsActive = 1 AND hs.BarcodeGenerateAtBilling = 1)
                             AND EXISTS (SELECT 1 FROM dbo.SampleCollection WHERE Laborderid = @LabOrderId AND BarcodeNo IS NOT NULL AND LTRIM(RTRIM(BarcodeNo)) <> '')
                            THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END", new { BranchId = branchId, LabOrderId = labOrderId });
            var name = patient != null
                ? ((patient.Salutation ?? "") + " " + patient.FirstName + " " + patient.LastName).Trim()
                : ((model.Salutation ?? "") + " " + model.FirstName + " " + model.LastName).Trim();
            return Json(new
            {
                success = true,
                alreadySaved = true,
                labOrderId,
                billNo = claim.BillNo,
                tokenNo = claim.TokenNo,
                patientCode = patient?.PatientCode ?? model.PatientCode,
                patientName = name,
                totalAmount = ph.SubTotal,
                netAmount = ph.NetAmount,
                totalPaid = ph.TotalPaid,
                balanceDue = ph.BalanceDue,
                paymentStatus = ph.PaymentStatus,
                showPrintBarcode
            });
        }

        /// <summary>
        /// Saves whichever of the three compliance uploads (prescription / OVD document / consent) or their
        /// bypass remarks were supplied, against the given order. Called once, right after the order is
        /// created, from both the B2C and the B2B booking save. A bill that needed none of the three
        /// conditions calls this with everything null, which does nothing.
        /// </summary>
        private async Task SaveComplianceDocumentsAsync(
            int labOrderId,
            IFormFile? prescriptionFile, string? prescriptionRemarks,
            IFormFile? ovdDocumentFile, string? ovdDocumentRemarks,
            IFormFile? consentFile, string? consentRemarks)
        {
            async Task<string?> SaveUploadAsync(IFormFile? file, string subFolder)
            {
                if (file == null || file.Length == 0) return null;
                var uploadsFolder = Path.Combine(env.WebRootPath, "uploads", "lab-compliance", subFolder);
                Directory.CreateDirectory(uploadsFolder);
                var fileName = $"{Guid.NewGuid()}{Path.GetExtension(file.FileName)}";
                var fullPath = Path.Combine(uploadsFolder, fileName);
                await using (var stream = new FileStream(fullPath, FileMode.Create))
                {
                    await file.CopyToAsync(stream);
                }
                return $"/uploads/lab-compliance/{subFolder}/{fileName}";
            }

            var prescriptionPath = await SaveUploadAsync(prescriptionFile, "prescription");
            var ovdPath = await SaveUploadAsync(ovdDocumentFile, "ovd");
            var consentPath = await SaveUploadAsync(consentFile, "consent");

            prescriptionRemarks = string.IsNullOrWhiteSpace(prescriptionRemarks) ? null : prescriptionRemarks.Trim();
            ovdDocumentRemarks = string.IsNullOrWhiteSpace(ovdDocumentRemarks) ? null : ovdDocumentRemarks.Trim();
            consentRemarks = string.IsNullOrWhiteSpace(consentRemarks) ? null : consentRemarks.Trim();

            if (prescriptionPath == null && prescriptionRemarks == null
                && ovdPath == null && ovdDocumentRemarks == null
                && consentPath == null && consentRemarks == null)
            {
                return; // this bill needed none of the three conditions - nothing to record
            }

            var con = dbContext.Database.GetDbConnection();
            if (con.State != System.Data.ConnectionState.Open)
                await con.OpenAsync();

            await con.ExecuteAsync(
                "dbo.usp_LabOrder_SaveComplianceDocuments",
                new
                {
                    LabOrderId = labOrderId,
                    PrescriptionFilePath = prescriptionPath,
                    PrescriptionRemarks = prescriptionRemarks,
                    OVDDocumentFilePath = ovdPath,
                    OVDDocumentRemarks = ovdDocumentRemarks,
                    ConsentFilePath = consentPath,
                    ConsentRemarks = consentRemarks
                },
                commandType: System.Data.CommandType.StoredProcedure);
        }

        private async Task PopulateSelectLists(LabOrderBookingViewModel model)
        {
            var branchId = User.GetCurrentBranchId();

            // the three catalogue lists come from the API: asked for now, in parallel with the database below
            var departmentsTask = labOrderApiClient.GetDepartmentsAsync();
            var categoriesTask = labOrderApiClient.GetCategoriesAsync();
            var subCategoriesTask = labOrderApiClient.GetSubCategoriesAsync();

            // every master list of the form in ONE database round trip (was one round trip per list); same filters and order
            var refCon = dbContext.Database.GetDbConnection();
            if (refCon.State != System.Data.ConnectionState.Open)
                await refCon.OpenAsync();
            using (var lists = await refCon.QueryMultipleAsync(@"
                SELECT RelationName AS Text, CONVERT(varchar(11), RelationId) AS Value FROM dbo.RelationMaster WHERE IsActive = 1 ORDER BY SortOrder, RelationName;
                SELECT IdentificationTypeName AS Text, CONVERT(varchar(11), IdentificationTypeId) AS Value FROM dbo.IdentificationTypeMaster WHERE IsActive = 1 ORDER BY IdentificationTypeName;
                SELECT ReligionName AS Text, CONVERT(varchar(11), ReligionId) AS Value FROM dbo.ReligionMaster WHERE IsActive = 1 ORDER BY ReligionName;
                SELECT OccupationName AS Text, CONVERT(varchar(11), OccupationId) AS Value FROM dbo.OccupationMaster WHERE IsActive = 1 ORDER BY OccupationName;
                SELECT StatusName AS Text, CONVERT(varchar(11), MaritalStatusId) AS Value FROM dbo.MaritalStatusMaster WHERE IsActive = 1 ORDER BY StatusName;
                SELECT LanguageName AS Text, CONVERT(varchar(11), LanguageId) AS Value FROM dbo.LanguageMaster WHERE IsActive = 1 ORDER BY LanguageName;
                SELECT CountryName AS Text, CONVERT(varchar(11), CountryId) AS Value FROM dbo.CountryMaster WHERE IsActive = 1 ORDER BY CountryName;
                SELECT COALESCE(FullName, Username) AS Text, CONVERT(varchar(11), Id) AS Value FROM dbo.Users WHERE IsPathologist = 1 AND IsActive = 1 ORDER BY COALESCE(FullName, Username);
                -- Referral doctor = Doctor Master doctors assigned to a LAB-type department (script 2127)
                EXEC dbo.usp_Lab_GetReferralDoctors @CompanyId = @CompanyId, @BranchId = @BranchId;",
                new { CompanyId = User.GetCompanyId(), BranchId = branchId }))
            {
                async Task<List<SelectListItem>> Next() =>
                    (await lists.ReadAsync<(string Text, string Value)>()).Select(x => new SelectListItem(x.Text, x.Value)).ToList();
                model.RelationOptions = await Next();
                model.IdentificationTypeOptions = await Next();
                model.ReligionOptions = await Next();
                model.OccupationOptions = await Next();
                model.MaritalStatusOptions = await Next();
                model.LanguageOptions = await Next();
                model.CountryOptions = await Next();
                model.PhlebotomistOptions = (await lists.ReadAsync<(string Text, string Value)>())
                    .Select(x => new SelectListItem { Value = x.Value, Text = x.Text }).ToList();
                var referralDoctors = await lists.ReadAsync<(int DoctorId, string DoctorName, string? SpecialityName, string? DepartmentNames)>();
                model.ReferralDoctorOptions = referralDoctors
                    .Select(r => new SelectListItem(
                        string.IsNullOrWhiteSpace(r.DepartmentNames) ? r.DoctorName : $"{r.DoctorName} ({r.DepartmentNames})",
                        r.DoctorId.ToString()))
                    .ToList();
            }

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
            var departments = await departmentsTask;
            model.DepartmentOptions = departments
                .Select(x => new SelectListItem { Value = x.DepartmentId.ToString(), Text = x.DepartmentName })
                .ToList();

            var categories = await categoriesTask;
            model.CategoryOptions = categories
                .Select(x => new SelectListItem { Value = x.CategoryId.ToString(), Text = x.CategoryName })
                .ToList();

            var subCategories = await subCategoriesTask;
            model.SubCategoryOptions = subCategories
                .Select(x => new SelectListItem { Value = x.SubCategoryId.ToString(), Text = x.SubCategoryName })
                .ToList();

            if (model.IsB2B)
            {
                try
                {
                    var franchises = await franchiseApiClient.GetListAsync(status: null, isActive: true);
                    if (User.GetFranchiseId() is int onlyFranchiseId)
                        franchises = franchises.Where(f => f.Franchise_ID == onlyFranchiseId).ToList();
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
                    if (User.IsFranchiseUser()) corporates = [];   // a franchise login never bills for a company
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

        // ── AI assist: read an uploaded prescription and suggest its tests (optional; manual search is unchanged) ──
        private static readonly string[] PrescriptionImageTypes = [".jpg", ".jpeg", ".png", ".webp", ".bmp", ".tif", ".tiff", ".pdf"];

        /// <summary>
        /// Reads the prescription image with OCR on this server (Tesseract - the image is not stored or sent anywhere)
        /// and matches what it says to the investigations / profiles / packages bookable here for this patient (ML.NET).
        /// Returns suggestions only: the user picks which to add, through the same add logic as the search box.
        /// </summary>
        [HttpPost]
        [ValidateAntiForgeryToken]
        [RequestSizeLimit(20_000_000)]
        [RequiresPermission("LAB.LABORDERBOOKING.B2CBOOKING", "AI_ASSIST")]
        public async Task<IActionResult> PrescriptionAssist(IFormFile? prescription, string? gender, int? ageInYears,
            [FromServices] Microsoft.Extensions.Options.IOptionsMonitor<EMR.Web.Services.PrescriptionAssist.PrescriptionAssistOptions> assistOptions,
            [FromServices] EMR.Web.Services.PrescriptionAssist.IPrescriptionOcrEngine ocr,
            [FromServices] EMR.Web.Services.PrescriptionAssist.IPrescriptionTestMatcher matcher,
            CancellationToken ct)
        {
            var o = assistOptions.CurrentValue;
            if (!o.Enabled || !await HttpContext.RequestServices.GetRequiredService<EMR.Web.Services.IAiBillingFeatures>().IsEnabledAsync(HttpContext))
                return Json(new { success = false, message = "AI features are switched off for this branch (Hospital Settings > LAB > Enable AI Features at Billing)." });
            if (prescription is null || prescription.Length == 0) return Json(new { success = false, message = "Choose a prescription image first." });
            if (prescription.Length > o.MaxFileSizeMb * 1024L * 1024L)
                return Json(new { success = false, message = $"The image is larger than {o.MaxFileSizeMb} MB. Use a smaller photo." });
            var ext = Path.GetExtension(prescription.FileName ?? string.Empty).ToLowerInvariant();
            if (!PrescriptionImageTypes.Contains(ext) || !LooksLikeImage(prescription))
                return Json(new { success = false, message = "Upload a photo, scan or PDF of the prescription (JPG, PNG, WEBP, BMP, TIFF or PDF)." });

            var branchId = HttpContext.Session.GetInt32("SelectedBranchId") ?? User.GetCurrentBranchId() ?? 1;
            try
            {
                var catalogue = (await labOrderApiClient.GetAvailableInvestigationsAsync(branchId, null, null, null,
                    string.IsNullOrWhiteSpace(gender) ? null : gender, ageInYears is > 0 and < 150 ? ageInYears : null, "B2C", null)).ToList();

                EMR.Web.Services.PrescriptionAssist.PrescriptionReading reading;
                await using (var stream = prescription.OpenReadStream())
                    reading = await ocr.ReadAsync(stream, ext, matcher.HandwritingCandidates(catalogue), ct);
                var text = reading.Text;
                var catalogueKey = $"{branchId}|{gender}|{ageInYears}|{catalogue.Count}|" +
                    string.Join(',', catalogue.Select(t => $"{(t.IsPackage ? 'P' : 'I')}{t.InvestigationId}:{t.TestName}")).GetHashCode();
                var result = matcher.Match(text, catalogue, catalogueKey, o.MinScore, o.PreselectScore, reading.Handwriting);

                await auditLogService.LogAsync("LAB", "LAB.PrescriptionAssist",
                    $"AI assist read a prescription: {result.Suggestions.Count} test(s) suggested, {result.UnmatchedLines.Count} line(s) not matched.");
                return Json(new
                {
                    success = true,
                    suggestions = result.Suggestions,
                    unmatched = result.UnmatchedLines,
                    text = text.Length > 4000 ? text[..4000] : text
                });
            }
            catch (EMR.Web.Services.PrescriptionAssist.PrescriptionOcrUnavailableException ex)
            {
                logger.LogError(ex, "Prescription assist: OCR engine unavailable");
                return Json(new { success = false, message = ex.Message + " Ask your administrator to install it; tests can still be added from the search box." });
            }
            catch (TimeoutException ex)
            {
                return Json(new { success = false, message = ex.Message });
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                logger.LogError(ex, "Prescription assist failed");
                return Json(new { success = false, message = "The prescription could not be read. Try a clearer photo, or add the tests from the search box." });
            }
        }

        /// <summary>
        /// AI test suggestions for a B2C bill (SQLScripts/2287): tests usually billed with the selected ones, learned from
        /// past B2C bills, and profiles / packages that cover several of the selected tests. Keys as the booking screen
        /// uses them ("I_12", "P_7"). Only with Hospital Settings > Enable AI Features at Billing; suggestions only.
        /// </summary>
        [HttpGet]
        [RequiresPermission("LAB.LABORDERBOOKING.B2CBOOKING", "AI_SUGGEST")]
        public async Task<IActionResult> TestSuggestions(string? keys, string? gender, int? referralDoctorId,
            [FromServices] EMR.Web.Services.IAiBillingFeatures aiFeatures,
            [FromServices] EMR.Web.Services.TestSuggestions.ILabTestSuggestionService suggestions)
        {
            if (!await aiFeatures.IsEnabledAsync(HttpContext)) return Json(new { success = false, enabled = false });
            var list = (keys ?? "").Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                .Where(k => System.Text.RegularExpressions.Regex.IsMatch(k, @"^[IP]_\d{1,9}$")).Take(60).ToList();
            var branchId = HttpContext.Session.GetInt32("SelectedBranchId") ?? User.GetCurrentBranchId() ?? 0;
            try
            {
                var r = await suggestions.SuggestAsync(User.GetCompanyId(), branchId, list,
                    new EMR.Web.Services.TestSuggestions.TestSuggestionContext(gender, referralDoctorId is > 0 ? referralDoctorId : null));
                return Json(new { success = true, enabled = true, together = r.Together, bundles = r.Bundles, learnedFromBills = r.LearnedFromBills, companyWide = r.CompanyWide });
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                logger.LogWarning(ex, "AI test suggestions failed");
                return Json(new { success = false, enabled = true });   // billing goes on without suggestions
            }
        }

        /// <summary>Follow-up tests the pathologist advised for this patient (reflex testing, SQLScripts/2289) that no
        /// later bill carries yet - shown on B2C booking for the front desk to offer. Read only.</summary>
        [HttpGet]
        public async Task<IActionResult> ReflexAdvised(int patientId,
            [FromServices] EMR.Web.Services.IAiBillingFeatures aiFeatures,
            [FromServices] EMR.Web.Services.Reflex.ILabReflexService reflex)
        {
            if (patientId <= 0 || !await aiFeatures.IsEnabledAsync(HttpContext)) return Json(new { success = false });
            try { return Json(new { success = true, items = await reflex.GetOpenAdviceAsync(User.GetCompanyId(), patientId) }); }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                logger.LogWarning(ex, "Reflex advice not loaded");
                return Json(new { success = false });
            }
        }

        /// <summary>A suggestion accepted (Add / Switch) or dismissed (x): the engine learns from it (SQLScripts/2288).</summary>
        [HttpPost]
        [ValidateAntiForgeryToken]
        [RequiresPermission("LAB.LABORDERBOOKING.B2CBOOKING", "AI_SUGGEST")]
        public async Task<IActionResult> TestSuggestionFeedback(string? key, string? contextKey, string? kind, string? action,
            [FromServices] EMR.Web.Services.IAiBillingFeatures aiFeatures,
            [FromServices] EMR.Web.Services.TestSuggestions.ILabTestSuggestionService suggestions)
        {
            static bool IsKey(string? k) => k is not null && System.Text.RegularExpressions.Regex.IsMatch(k, @"^[IP]_\d{1,9}$");
            if (!await aiFeatures.IsEnabledAsync(HttpContext) || !IsKey(key) || (contextKey is not null && !IsKey(contextKey))
                || kind is not ("T" or "B") || action is not ("A" or "D"))
                return Json(new { success = false });
            try
            {
                var branchId = HttpContext.Session.GetInt32("SelectedBranchId") ?? User.GetCurrentBranchId() ?? 0;
                await suggestions.RecordFeedbackAsync(User.GetCompanyId(), branchId, User.GetUserId(), key!, contextKey, kind[0], action[0]);
                return Json(new { success = true });
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                logger.LogWarning(ex, "AI test suggestion feedback not saved");
                return Json(new { success = false });
            }
        }

        private static readonly string[] IdDocumentTypes = [".jpg", ".jpeg", ".png", ".pdf"];

        /// <summary>
        /// ID document assist (SQLScripts/2284): reads the uploaded ID document with OCR on this server (nothing is stored
        /// or sent anywhere), recognises its type (ML.NET) and number (each document's format and check digit) and returns
        /// the matching ID Type of the master. The page fills ID Type / ID Number; the user can change them.
        /// </summary>
        [HttpPost]
        [ValidateAntiForgeryToken]
        [RequestSizeLimit(20_000_000)]
        [RequiresPermission("LAB.LABORDERBOOKING.B2CBOOKING", "ID_AI_ASSIST")]
        public Task<IActionResult> IdDocumentAssist(IFormFile? document,
            [FromServices] Microsoft.Extensions.Options.IOptionsMonitor<EMR.Web.Services.PrescriptionAssist.PrescriptionAssistOptions> assistOptions,
            [FromServices] EMR.Web.Services.IdDocumentAssist.IIdDocumentReader reader,
            CancellationToken ct) => ReadIdDocumentAsync(document, assistOptions, reader, "B2C", ct);

        /// <summary>The same ID document assist on B2B booking (SQLScripts/2285), under that page's own control.</summary>
        [HttpPost]
        [ValidateAntiForgeryToken]
        [RequestSizeLimit(20_000_000)]
        [RequiresPermission("LAB.LABORDERBOOKING.B2BBOOKING", "ID_AI_ASSIST")]
        public Task<IActionResult> B2BIdDocumentAssist(IFormFile? document,
            [FromServices] Microsoft.Extensions.Options.IOptionsMonitor<EMR.Web.Services.PrescriptionAssist.PrescriptionAssistOptions> assistOptions,
            [FromServices] EMR.Web.Services.IdDocumentAssist.IIdDocumentReader reader,
            CancellationToken ct) => ReadIdDocumentAsync(document, assistOptions, reader, "B2B", ct);

        private async Task<IActionResult> ReadIdDocumentAsync(IFormFile? document,
            Microsoft.Extensions.Options.IOptionsMonitor<EMR.Web.Services.PrescriptionAssist.PrescriptionAssistOptions> assistOptions,
            EMR.Web.Services.IdDocumentAssist.IIdDocumentReader reader, string screen, CancellationToken ct)
        {
            var o = assistOptions.CurrentValue;
            if (!o.Enabled || !await HttpContext.RequestServices.GetRequiredService<EMR.Web.Services.IAiBillingFeatures>().IsEnabledAsync(HttpContext))
                return Json(new { success = false, message = "AI features are switched off for this branch (Hospital Settings > LAB > Enable AI Features at Billing)." });
            if (document is null || document.Length == 0) return Json(new { success = false, message = "Choose the ID document first." });
            if (document.Length > o.MaxFileSizeMb * 1024L * 1024L)
                return Json(new { success = false, message = $"The file is larger than {o.MaxFileSizeMb} MB." });
            var ext = Path.GetExtension(document.FileName ?? string.Empty).ToLowerInvariant();
            if (!IdDocumentTypes.Contains(ext) || !LooksLikeImage(document))
                return Json(new { success = false, message = "Upload a photo, scan or PDF of the ID document (JPG, PNG or PDF)." });

            try
            {
                EMR.Web.Services.IdDocumentAssist.IdDocumentReading r;
                await using (var stream = document.OpenReadStream())
                    r = await reader.ReadAsync(stream, ext, ct);

                if (r.Kind == EMR.Web.Services.IdDocumentAssist.IdDocumentKind.Unknown)
                    return Json(new { success = true, recognised = false, message = "This does not look like a supported ID document (Aadhaar, PAN, Voter ID, Passport, Driving Licence, Ration Card). Select the ID Type and enter the number yourself." });

                var pattern = r.Kind switch
                {
                    EMR.Web.Services.IdDocumentAssist.IdDocumentKind.Aadhaar => "aadha?ar",
                    EMR.Web.Services.IdDocumentAssist.IdDocumentKind.Pan => @"\bpan\b",
                    EMR.Web.Services.IdDocumentAssist.IdDocumentKind.VoterId => "voter|epic|election",
                    EMR.Web.Services.IdDocumentAssist.IdDocumentKind.Passport => "passport",
                    EMR.Web.Services.IdDocumentAssist.IdDocumentKind.DrivingLicence => "driving|licen[cs]e",
                    _ => "ration"
                };
                var types = await dbContext.IdentificationTypeMasters.AsNoTracking().Where(x => x.IsActive)
                    .Select(x => new { x.IdentificationTypeId, x.IdentificationTypeName }).ToListAsync(ct);
                var type = types.FirstOrDefault(x => System.Text.RegularExpressions.Regex.IsMatch(x.IdentificationTypeName ?? "", pattern,
                    System.Text.RegularExpressions.RegexOptions.IgnoreCase));
                var label = r.Kind switch
                {
                    EMR.Web.Services.IdDocumentAssist.IdDocumentKind.Aadhaar => "Aadhaar Card",
                    EMR.Web.Services.IdDocumentAssist.IdDocumentKind.Pan => "PAN Card",
                    EMR.Web.Services.IdDocumentAssist.IdDocumentKind.VoterId => "Voter ID Card",
                    EMR.Web.Services.IdDocumentAssist.IdDocumentKind.Passport => "Passport",
                    EMR.Web.Services.IdDocumentAssist.IdDocumentKind.DrivingLicence => "Driving Licence",
                    _ => "Ration Card"
                };

                await auditLogService.LogAsync("LAB", "LAB.IdDocumentAssist",
                    $"AI assist read an ID document ({screen} booking): {label}, number {(r.Number is null ? "not found" : r.NumberVerified ? "verified" : "found")}.");
                return Json(new
                {
                    success = true,
                    recognised = true,
                    documentType = type?.IdentificationTypeName ?? label,
                    identificationTypeId = type?.IdentificationTypeId,
                    number = r.Number,
                    verified = r.NumberVerified,
                    masked = r.NumberMasked,
                    confidence = r.Confidence,
                    evidence = r.Evidence,
                    // Aadhaar / passport holder details: the page checks them against the entered details on Save
                    person = r.Person
                });
            }
            catch (EMR.Web.Services.PrescriptionAssist.PrescriptionOcrUnavailableException ex)
            {
                logger.LogError(ex, "ID document assist: OCR engine unavailable");
                return Json(new { success = false, message = "The OCR engine (Tesseract) is not available on the server. Select the ID Type and enter the number yourself." });
            }
            catch (TimeoutException)
            {
                return Json(new { success = false, message = "Reading the document took too long. Try a smaller or clearer image." });
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                logger.LogError(ex, "ID document assist failed");
                return Json(new { success = false, message = "The document could not be read. Try a clearer photo, or enter the details yourself." });
            }
        }

        /// <summary>Checks the file starts like an image (JPEG, PNG, WEBP, BMP, TIFF) or a PDF, not just that its name says so.</summary>
        private static bool LooksLikeImage(IFormFile file)
        {
            Span<byte> head = stackalloc byte[12];
            using var s = file.OpenReadStream();
            var n = s.Read(head);
            if (n < 4) return false;
            return (head[0] == 0xFF && head[1] == 0xD8)                                                   // JPEG
                || (head[0] == 0x89 && head[1] == 0x50 && head[2] == 0x4E && head[3] == 0x47)              // PNG
                || (n >= 12 && head[0] == 'R' && head[1] == 'I' && head[2] == 'F' && head[3] == 'F' && head[8] == 'W' && head[9] == 'E' && head[10] == 'B' && head[11] == 'P')
                || (head[0] == '%' && head[1] == 'P' && head[2] == 'D' && head[3] == 'F')                  // PDF
                || (head[0] == 'B' && head[1] == 'M')                                                     // BMP
                || (head[0] == 'I' && head[1] == 'I' && head[2] == 0x2A) || (head[0] == 'M' && head[1] == 'M' && head[3] == 0x2A); // TIFF
        }

        [HttpGet]
        public async Task<IActionResult> GetAvailableInvestigations(int? branchId, int? departmentId, int? categoryId, int? subCategoryId, string? gender = null, int? ageInYears = null, string? rateType = "B2C", int? agentId = null)
        {
            // a franchise login always prices from its own franchise rate list
            if (User.GetFranchiseId() is int ownFranchiseId) { rateType = "Franchise"; agentId = ownFranchiseId; }

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

        /// <summary>
        /// Prescription / OVD document / consent flags for the tests currently on the booking grid.
        /// <paramref name="plainIds"/> are single-investigation line items (Test_ID); <paramref name="groupIds"/>
        /// are profile / package line items, resolved to their constituent tests server-side (Profile_ID first,
        /// then Test_ID or a matching Profile_Name - the same fallback GetProfileDetails uses - plus one level
        /// of nested sub-profiles), so a flagged test inside a profile is caught even though the booking grid
        /// never fetched its own id. Both lists are the compact "id[,id...]" CSV already used elsewhere on
        /// this page. B2C and B2B both call this; neither page's own line-item logic is touched.
        /// </summary>
        [HttpGet]
        public async Task<IActionResult> GetInvestigationDocFlags(string? plainIds, string? groupIds)
        {
            if (string.IsNullOrWhiteSpace(plainIds) && string.IsNullOrWhiteSpace(groupIds))
                return Json(new { success = true, rows = Array.Empty<object>() });

            try
            {
                var con = dbContext.Database.GetDbConnection();
                if (con.State != System.Data.ConnectionState.Open)
                    await con.OpenAsync();

                var rows = await con.QueryAsync<dynamic>(
                    "dbo.usp_Lab_GetInvestigationDocFlags",
                    new { PlainTestIds = plainIds, GroupIds = groupIds },
                    commandType: System.Data.CommandType.StoredProcedure);

                return Json(new
                {
                    success = true,
                    rows = rows.Select(r => new
                    {
                        sourceType = (string)r.SourceType,
                        sourceId = (int)r.SourceId,
                        testId = (int)r.Test_ID,
                        testName = (string)r.Test_Name,
                        prescriptionRequired = (bool)r.PrescriptionRequired,
                        ovdRequired = (bool)r.OvdRequired,
                        consentRequired = (bool)r.ConsentRequired
                    })
                });
            }
            catch (Exception ex)
            {
                return Json(new { success = false, message = ex.Message });
            }
        }

        /// <summary>
        /// The prescription / OVD document / consent uploaded for a bill (or the remark recorded instead),
        /// for the "View Uploaded Documents" action on the B2C and B2B order lists.
        /// </summary>
        [HttpGet]
        public async Task<IActionResult> GetOrderComplianceDocuments(int labOrderId)
        {
            if (labOrderId <= 0)
                return Json(new { success = false, message = "A valid order is required." });

            try
            {
                var con = dbContext.Database.GetDbConnection();
                if (con.State != System.Data.ConnectionState.Open)
                    await con.OpenAsync();

                var row = await con.QueryFirstOrDefaultAsync<dynamic>(
                    "dbo.usp_LabOrder_GetComplianceDocuments",
                    new { LabOrderId = labOrderId },
                    commandType: System.Data.CommandType.StoredProcedure);

                if (row == null)
                    return Json(new { success = false, message = "Order not found." });

                return Json(new
                {
                    success = true,
                    billNo = (string)row.BillNo,
                    patientName = (string)row.PatientName,
                    prescriptionFilePath = (string?)row.PrescriptionFilePath,
                    prescriptionRemarks = (string?)row.PrescriptionRemarks,
                    ovdDocumentFilePath = (string?)row.OVDDocumentFilePath,
                    ovdDocumentRemarks = (string?)row.OVDDocumentRemarks,
                    consentFilePath = (string?)row.ConsentFilePath,
                    consentRemarks = (string?)row.ConsentRemarks
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
        public async Task<IActionResult> B2COrderList(string? dateType, string? fromDate, string? toDate, string? search, string? paymentStatus, int page = 1, int pageSize = 10)
        {
            // always the signed-in branch (no branch picker: a branch in the address cannot list another branch's orders)
            int? currentBranchId = User.GetCurrentBranchId()
                ?? HttpContext.Session.GetInt32("SelectedBranchId")
                ?? HttpContext.Session.GetInt32("BranchId");
            if (currentBranchId is not > 0) return RedirectToAction("SelectBranch", "Account");
            int resolvedBranchId = currentBranchId.Value;

            // the range applies to the booking date (default) or the bill (created) date; both ends default to today
            var effectiveDateType = string.Equals(dateType, "C", StringComparison.OrdinalIgnoreCase) ? "C" : "B";
            var effectiveFromDate = DateOnly.TryParse(fromDate, out var f) ? f.ToString("yyyy-MM-dd") : DateTime.Today.ToString("yyyy-MM-dd");
            var effectiveToDate = DateOnly.TryParse(toDate, out var t) ? t.ToString("yyyy-MM-dd") : DateTime.Today.ToString("yyyy-MM-dd");
            if (string.CompareOrdinal(effectiveFromDate, effectiveToDate) > 0) (effectiveFromDate, effectiveToDate) = (effectiveToDate, effectiveFromDate);
            if (page < 1) page = 1;
            if (pageSize is not (10 or 25 or 50 or 100)) pageSize = 10;

            // payment status filter (script 2233): All / Full Due / Partial Due / Paid / Partial Cancelled / Full Cancelled
            var effectivePaymentStatus = paymentStatus?.Trim().ToUpperInvariant() is "DUE" or "PARTIAL" or "PAID" or "PCAN" or "FCAN"
                ? paymentStatus.Trim().ToUpperInvariant() : null;
            ViewBag.PaymentStatus = effectivePaymentStatus ?? string.Empty;

            var result = await labOrderApiClient.GetPagedOrdersAsync(resolvedBranchId, effectiveFromDate, effectiveToDate, search, page, pageSize, isB2B: false, dateType: effectiveDateType, paymentFilter: effectivePaymentStatus);

            var currentBranch = await dbContext.BranchMasters
                .Where(b => b.BranchId == resolvedBranchId)
                .Select(b => b.BranchName)
                .FirstOrDefaultAsync();

            ViewBag.ShowLabReportPrintOnList = await dbContext.HospitalSettings
                .Where(s => s.BranchId == resolvedBranchId && s.IsActive)
                .Select(s => s.ShowLabReportPrintOnList)
                .FirstOrDefaultAsync();

            // cancelled tests / refunds of the orders on this page (the list shows the bill after cancellation)
            ViewBag.Adjustments = await EMR.Web.Services.LabBillAdjustments.LoadAsync(
                dbContext.Database.GetDbConnection(), (result?.Items ?? new List<LabOrderListItemDto>()).Select(o => o.LabOrderId));

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
                Search = search,
                DateType = effectiveDateType
            };

            return View(vm);
        }

        [HttpGet]
        public async Task<IActionResult> B2BRegistration(int? branchId, string? fromDate, string? toDate, string? search, string? agentType, int? agentId, int page = 1, int pageSize = 10)
        {
            int resolvedBranchId = branchId 
                ?? User.GetCurrentBranchId() 
                ?? HttpContext.Session.GetInt32("SelectedBranchId") 
                ?? HttpContext.Session.GetInt32("BranchId") 
                ?? 1;

            var effectiveFromDate = fromDate ?? DateTime.Today.AddDays(-30).ToString("yyyy-MM-dd");
            var effectiveToDate = toDate ?? DateTime.Today.ToString("yyyy-MM-dd");

            // Partner Type (F franchise / C company) and one partner of that type - script 2234; a partner needs its type
            var effectiveAgentType = agentType?.Trim().ToUpperInvariant() is "F" or "C" ? agentType.Trim().ToUpperInvariant() : null;
            var effectiveAgentId = effectiveAgentType != null && agentId is > 0 ? agentId : null;
            // a franchise login sees the bills it created or that are for its own franchise (2258)
            int? createdBy = null;
            if (User.GetFranchiseId() is int ownFranchiseId)
            {
                effectiveAgentType = "F";
                effectiveAgentId = ownFranchiseId;
                createdBy = User.GetUserId();
            }
            ViewBag.AgentType = effectiveAgentType ?? string.Empty;
            ViewBag.AgentId = effectiveAgentId ?? 0;
            ViewBag.Partners = (await dbContext.Database.GetDbConnection().QueryAsync<(string Type, int Id, string Name, string? Code)>(@"
                SELECT 'F', Franchise_ID, Franchise_Name, Franchise_Code FROM dbo.LabFranchiseMaster WHERE ISNULL(IsDeleted, 0) = 0
                UNION ALL
                SELECT 'C', Corporate_ID, Corporate_Name, Corporate_Code FROM dbo.CorporateMaster
                ORDER BY 1, 3")).Where(p => createdBy == null || (p.Type == "F" && p.Id == effectiveAgentId)).ToList();

            var result = await labOrderApiClient.GetPagedOrdersAsync(resolvedBranchId, effectiveFromDate, effectiveToDate, search, page, pageSize, isB2B: true,
                agentType: effectiveAgentType, agentId: effectiveAgentId, createdBy: createdBy);

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

        // ─── Department-wise discount: the discount heads of a B2C bill ─────────────
        /// <summary>
        /// Discount heads for the payment screen's "Department-wise" popup: one per department on the bill plus
        /// "Packages", each line's head and whether the B2C rate card allows a discount on it. For a saved bill
        /// (labOrderId, own branch only) or for the tests of a bill still being booked (items). B2B bills: isB2B = true.
        /// </summary>
        // ── Membership points on B2C LAB billing (SQLScripts/2236) ────────────────────────────────────────────
        /// <summary>The active, in-date membership card of the bill's patient - by patient, or by the patient's phone
        /// number - with its points balance and the plan's points settings. data = null when there is none.</summary>
        [HttpGet]
        public async Task<IActionResult> MembershipForBilling(int? patientId, string? phone, int? labOrderId)
        {
            phone = string.IsNullOrWhiteSpace(phone) ? null : phone.Trim();
            if (labOrderId is > 0)
            {
                // a saved bill: its own patient; points are for B2C bills only
                var bill = await dbContext.Database.GetDbConnection().QueryFirstOrDefaultAsync<(int PatientId, bool IsB2B)>(
                    "SELECT PatientId, CAST(ISNULL(IsB2B, 0) AS BIT) FROM dbo.LabOrder WHERE LabOrderId = @Id", new { Id = labOrderId });
                if (bill.PatientId <= 0 || bill.IsB2B) return Json(new { success = true, data = (object?)null });
                patientId = bill.PatientId;
            }
            if (patientId is not > 0 && phone == null) return Json(new { success = true, data = (object?)null });
            var row = await dbContext.Database.GetDbConnection().QueryFirstOrDefaultAsync(
                "dbo.usp_Membership_CardForBilling",
                new { PatientId = patientId is > 0 ? patientId : null, Phone = phone, CompanyId = User.GetCompanyId() },
                commandType: System.Data.CommandType.StoredProcedure);
            return Json(new { success = true, data = row });
        }

        // ── Membership benefits preview (SQLScripts/2241): the payment screen of a new B2C bill shows what the plan gives;
        //    the payment works it out again from the saved bill ──
        public sealed class MemberBenefitPreviewRequest
        {
            public int PatientId { get; set; }
            public List<MemberBenefitPreviewLine> Items { get; set; } = [];
        }
        public sealed class MemberBenefitPreviewLine
        {
            public string Key { get; set; } = "";
            public string Kind { get; set; } = "T";   // T test / profile, P package, M misc charge
            public int ItemId { get; set; }
            public decimal Price { get; set; }
        }

        [HttpPost]
        public async Task<IActionResult> MembershipBenefitPreview([FromBody] MemberBenefitPreviewRequest req)
        {
            var branchId = User.GetCurrentBranchId();
            if (req == null || req.PatientId <= 0 || branchId == null) return Json(new { success = true, data = (object?)null });
            var lines = (req.Items ?? []).Where(i => !string.IsNullOrWhiteSpace(i.Key) && i.ItemId > 0)
                .Select(i => new EMR.Web.Services.LabBenefitLineInput(i.Key, (i.Kind ?? "T").ToUpperInvariant() is "P" or "M" ? i.Kind!.ToUpperInvariant() : "T", i.ItemId, i.Price));
            var b = await EMR.Web.Services.LabMembershipBenefits.ComputeAsync(dbContext.Database.GetDbConnection(), req.PatientId, branchId.Value, lines);
            if (b == null) return Json(new { success = true, data = (object?)null });
            return Json(new
            {
                success = true,
                data = new
                {
                    b.CardNo, b.PlanName, b.FreeHomeCollection, b.TestDiscount, b.MiscDiscount, b.Total,
                    lines = b.Lines.Select(kv => new { key = kv.Key, discount = kv.Value.Discount, rule = kv.Value.Rule })
                }
            });
        }

        // ── Misc charges (Misc Charges Master, SQLScripts/2239 / 2240) ──────────────────────────────────────────
        /// <summary>Active misc charges offered on the booking screens (Home Collection first).</summary>
        [HttpGet]
        public async Task<IActionResult> MiscChargesForBilling()
        {
            var rows = await dbContext.Database.GetDbConnection().QueryAsync("dbo.usp_LabMiscCharge_ForBilling",
                new { CompanyId = User.GetCompanyId() }, commandType: System.Data.CommandType.StoredProcedure);
            return Json(new { success = true, data = rows });
        }

        /// <summary>A saved bill's misc taxable amount, misc GST and B2B total.</summary>
        private async Task<(decimal MiscAmount, decimal MiscGst, decimal B2BTotal)> ReadLabMiscTotalsAsync(int labOrderId) =>
            await dbContext.Database.GetDbConnection().QueryFirstOrDefaultAsync<(decimal, decimal, decimal)>(
                "SELECT ISNULL(MiscAmount, 0), ISNULL(MiscGstAmount, 0), ISNULL(B2BTotal, 0) FROM dbo.LabOrder WHERE LabOrderId = @Id", new { Id = labOrderId });

        /// <summary>GST Output Payable follows the bill's misc GST (idempotent).</summary>
        private async Task SyncLabGstAsync(int labOrderId)
        {
            try
            {
                await dbContext.Database.GetDbConnection().ExecuteAsync("dbo.usp_Ledger_SyncLabGst",
                    new { LabOrderId = labOrderId, UserId = User.GetUserId() }, commandType: System.Data.CommandType.StoredProcedure);
            }
            catch (Exception ex) { logger.LogError(ex, "GST ledger sync failed for LabOrderId {LabOrderId}", labOrderId); }
        }

        public sealed class MembershipOtpRequest { public int CardId { get; set; } public decimal Points { get; set; } }

        /// <summary>Sends a one-time code for redeeming these points to the card holder (primary member) by WhatsApp,
        /// and by e-mail when the holder has one. The code is valid 10 minutes and for these points only.</summary>
        [HttpPost]
        public async Task<IActionResult> MembershipSendRedeemOtp([FromBody] MembershipOtpRequest? request)
        {
            if (request is null || request.CardId <= 0 || request.Points <= 0)
                return Json(new { success = false, message = "Enter the points to redeem." });
            var branchId = User.GetCurrentBranchId() ?? HttpContext.Session.GetInt32("SelectedBranchId") ?? 1;
            var p = new DynamicParameters();
            p.Add("@CardId", request.CardId);
            p.Add("@Points", request.Points);
            p.Add("@BranchId", branchId);
            p.Add("@UserId", User.GetUserId());
            p.Add("@OtpId", dbType: System.Data.DbType.Int32, direction: System.Data.ParameterDirection.Output);
            p.Add("@Code", dbType: System.Data.DbType.String, size: 6, direction: System.Data.ParameterDirection.Output);
            p.Add("@SentTo", dbType: System.Data.DbType.String, size: 30, direction: System.Data.ParameterDirection.Output);
            p.Add("@Email", dbType: System.Data.DbType.String, size: 200, direction: System.Data.ParameterDirection.Output);
            p.Add("@Name", dbType: System.Data.DbType.String, size: 200, direction: System.Data.ParameterDirection.Output);
            p.Add("@CardNo", dbType: System.Data.DbType.String, size: 50, direction: System.Data.ParameterDirection.Output);
            p.Add("@ValueRs", dbType: System.Data.DbType.Decimal, precision: 12, scale: 2, direction: System.Data.ParameterDirection.Output);
            try
            {
                await dbContext.Database.GetDbConnection().ExecuteAsync("dbo.usp_Membership_RedeemOtpCreate", p, commandType: System.Data.CommandType.StoredProcedure);
            }
            catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number >= 50000)
            {
                return Json(new { success = false, message = ex.Message });
            }

            int otpId = p.Get<int>("@OtpId");
            string code = p.Get<string>("@Code"), sentTo = p.Get<string>("@SentTo"), name = p.Get<string?>("@Name") ?? "Member";
            string? email = p.Get<string?>("@Email");
            string cardNo = p.Get<string>("@CardNo");
            decimal value = p.Get<decimal>("@ValueRs");
            var text = $"Dear {name}, your OTP to redeem {request.Points:0} membership points (Rs {value:0.00}) on card {cardNo} is {code}. " +
                       "It is valid for 10 minutes. Do not share it with anyone except the billing counter.";

            var channels = new List<string>();
            try
            {
                var wa = await HttpContext.RequestServices.GetRequiredService<IWhatsAppService>()
                    .SendTextMessageAsync(sentTo, text, branchId, "MEM_OTP", otpId);
                if (wa.Success) channels.Add("WhatsApp");
            }
            catch (Exception ex) { logger.LogWarning(ex, "Membership OTP WhatsApp failed for card {CardNo}", cardNo); }
            if (!string.IsNullOrWhiteSpace(email))
            {
                try
                {
                    var (ok, _) = await HttpContext.RequestServices.GetRequiredService<IEmailService>()
                        .SendEmailAsync(branchId, email!, $"OTP to redeem membership points - card {cardNo}",
                            EmailLayout.Wrap(
                                EmailLayout.Greeting(name ?? "Member")
                                + EmailLayout.P($"Your OTP to redeem <strong>{request.Points:0} points</strong> (Rs {value:0.00}) on membership card <strong>{System.Net.WebUtility.HtmlEncode(cardNo)}</strong> is:")
                                + $"<p style=\"margin:20px 0;text-align:center;\"><span style=\"display:inline-block;font-size:28px;font-weight:800;letter-spacing:8px;color:{EmailLayout.Purple};background:#f5f1fa;border:1px dashed {EmailLayout.Purple};border-radius:8px;padding:10px 22px;\">{code}</span></p>"
                                + EmailLayout.Callout("It is valid for 10 minutes. Do not share it with anyone except the billing counter.", "warn"),
                                heading: "Your membership OTP"));
                    if (ok) channels.Add("e-mail");
                }
                catch (Exception ex) { logger.LogWarning(ex, "Membership OTP e-mail failed for card {CardNo}", cardNo); }
            }
            if (channels.Count == 0)
                return Json(new { success = false, message = "The OTP could not be sent (WhatsApp / e-mail not available for this branch or the card holder). Please try again." });

            var masked = sentTo.Length >= 4 ? new string('x', sentTo.Length - 4) + sentTo[^4..] : sentTo;
            return Json(new { success = true, otpId, sentTo = masked, channels = string.Join(" and ", channels), value, expiresInSeconds = 600 });
        }

        [HttpPost]
        public async Task<IActionResult> DiscountHeads([FromBody] DiscountHeadsRequest? request)
        {
            var branchId = User.GetCurrentBranchId();
            if (branchId is not > 0 || request is null) return BadRequest(new { error = "Select a branch first." });

            var con = dbContext.Database.GetDbConnection();
            if (con.State != System.Data.ConnectionState.Open) await con.OpenAsync();

            List<LabDiscountLine> lines;
            bool isB2B = false;
            if (request.LabOrderId is > 0)
            {
                var (orderLines, orderIsB2B, orderBranch) = await LabDepartmentDiscount.LoadForOrderAsync(con, request.LabOrderId.Value);
                if (orderBranch != branchId.Value) return NotFound(new { error = "Bill not found." });
                lines = orderLines;
                isB2B = orderIsB2B;
            }
            else
            {
                var items = (request.Items ?? new())
                    .Where(x => x.InvestigationId > 0)
                    .Take(200)
                    .Select(x => (x.InvestigationId, x.IsPackage, Math.Max(0m, x.Price)))
                    .ToList();
                lines = await LabDepartmentDiscount.LoadForItemsAsync(con, branchId.Value, items);
            }

            var heads = lines
                .GroupBy(l => l.GroupKey)
                .Select(g => new
                {
                    key = g.Key,
                    name = g.First().GroupName,
                    isPackages = g.Key == LabDepartmentDiscount.PackagesKey,
                    tests = g.Count(),
                    eligibleAmount = g.Where(l => l.Eligible).Sum(l => l.Price),
                    nonEligibleAmount = g.Where(l => !l.Eligible).Sum(l => l.Price)
                })
                .OrderBy(h => h.isPackages).ThenBy(h => h.name)
                .ToList();

            return Json(new
            {
                isB2B,
                heads,
                lines = lines.Select(l => new
                {
                    index = l.Index, labOrderItemId = l.LabOrderItemId, investigationId = l.InvestigationId,
                    isPackage = l.IsPackage, price = l.Price, eligible = l.Eligible, groupKey = l.GroupKey
                })
            });
        }

        public sealed class DiscountHeadsRequest
        {
            public int? LabOrderId { get; set; }
            public List<DiscountHeadItem>? Items { get; set; }
        }

        public sealed class DiscountHeadItem
        {
            public int InvestigationId { get; set; }
            public bool IsPackage { get; set; }
            public decimal Price { get; set; }
        }

        [HttpGet]
        public async Task<IActionResult> GetOrderDetail(int id)
        {
            if (id <= 0) return BadRequest("Invalid order ID.");
            if (!await FranchiseOwnsOrderAsync(id)) return Forbid();
            var detail = await labOrderApiClient.GetOrderDetailAsync(id);
            if (detail == null) return NotFound();
            // + cancelled tests, cancellation notes and refunds, so the order details add up after a cancellation
            var node = System.Text.Json.JsonSerializer.SerializeToNode(detail, new JsonSerializerOptions(JsonSerializerDefaults.Web))!.AsObject();
            var adj = (await EMR.Web.Services.LabBillAdjustments.LoadAsync(dbContext.Database.GetDbConnection(), [id])).GetValueOrDefault(id);
            node["adjustments"] = adj is null ? null : System.Text.Json.JsonSerializer.SerializeToNode(adj, new JsonSerializerOptions(JsonSerializerDefaults.Web));
            return Content(node.ToJsonString(), "application/json");
        }

        [HttpGet]
        // One receipt row of the bill print (receipt no, date, mode, mode details, amount, received by; SQLScripts/2205)
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

        public async Task<IActionResult> PrintBill(int labOrderId, int? previewTemplateId = null)
        {
            if (labOrderId <= 0) return BadRequest("Invalid lab order ID.");
            if (!await FranchiseOwnsOrderAsync(labOrderId)) return Forbid();

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

            // franchise B2B bill: the franchise's Report Header Required decides (null for B2C / company B2B)
            var franchiseHeader = await LabFranchiseHeader.ForOrderAsync(dbContext, labOrderId);

            var vm = new PrintBillViewModel
            {
                IsActive              = detail.IsActive,
                // B2C: Hospital Settings > LAB > Required B2C Bill Print Header. B2B: a franchise's Report Header Required
                // (Franchise Master); a company's B2B bill always has the header / footer.
                ShowHeaderFooter      = detail.IsB2B ? (franchiseHeader ?? true) : (settings?.LabB2CBillPrintHeaderRequired ?? true),
                PageSize              = settings?.LabBillPrintPageSize == "A5L" ? "A5L" : "A4",
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

            await ApplyBillTemplateAsync(vm, branchId, previewTemplateId);
            return View(vm);
        }

        /// <summary>
        /// Utility > Print Templates (SQLScripts/2324): the branch's Bill template for the header and footer (none = Classic).
        /// previewTemplateId: the designer's Preview shows that template's draft (only to a user who may open Print Templates).
        /// </summary>
        private async Task ApplyBillTemplateAsync(PrintBillViewModel vm, int branchId, int? previewTemplateId)
        {
            var runtime = HttpContext.RequestServices.GetRequiredService<IPrintTemplateRuntime>();
            if (previewTemplateId is > 0) vm.ShowHeaderFooter = true;   // the designer's preview always shows the header and footer
            await runtime.ApplyToBillAsync(ViewData, User, branchId, new PrintDocInfo
            {
                DocNo = vm.BillNo,
                DocDate = (vm.CreatedDate > DateTime.MinValue ? vm.CreatedDate : vm.OrderDate).ToString("dd-MMM-yyyy hh:mm tt"),
                TokenNo = vm.TokenNo,
                CopyLabel = vm.IsActive ? "Original" : "Cancelled",
                PrintedBy = vm.PrintedByName,
                CreatedBy = vm.CreatedByName ?? vm.CreatedByUsername
            }, previewTemplateId);
        }

        /// <summary>
        /// Home Collection Address search (LAB B2C / B2B booking): Google Places when GoogleMaps:ApiKey is configured
        /// (signed-in users only - the key is billed), otherwise the free OpenStreetMap services; biased to the chosen
        /// district / city, ranked and cached. See <see cref="GeoAddressService"/>.
        /// </summary>
        [AllowAnonymous]
        [HttpGet]
        public async Task<IActionResult> SearchAddressGeoSuggestions(
            [FromQuery] string query,
            [FromQuery] string? country,
            [FromQuery] string? state,
            [FromQuery] string? district,
            [FromQuery] string? city,
            [FromQuery] string? sessionToken,
            [FromServices] GeoAddressService geo,
            CancellationToken ct)
        {
            if (string.IsNullOrWhiteSpace(query) || query.Trim().Length < 3) return Json(Array.Empty<object>());
            // the Google key is billed: only signed-in users use it; anonymous calls get the free services
            var signedIn = User.Identity?.IsAuthenticated == true;
            var list = await geo.SearchAsync(query, country, state, district, city, signedIn ? sessionToken : null, ct, allowGoogle: signedIn);
            return Json(list.Select(x => new
            {
                name = x.Name, secondary = x.Secondary, fullAddress = x.FullAddress, latitude = x.Latitude, longitude = x.Longitude,
                city = x.City, district = x.District, state = x.State, postcode = x.Postcode, country = x.Country, placeId = x.PlaceId, source = x.Source
            }));
        }

        /// <summary>Coordinates and full address of a picked Google suggestion (signed-in users only).</summary>
        [AllowAnonymous]
        [HttpGet]
        public async Task<IActionResult> AddressPlaceDetails([FromQuery] string placeId, [FromQuery] string? sessionToken,
            [FromServices] GeoAddressService geo, CancellationToken ct)
        {
            if (User.Identity?.IsAuthenticated != true) return Unauthorized();
            var d = await geo.PlaceDetailsAsync(placeId, sessionToken, ct);
            if (d is null) return NotFound();
            return Json(new
            {
                name = d.Name, fullAddress = d.FullAddress, latitude = d.Latitude, longitude = d.Longitude,
                city = d.City, district = d.District, state = d.State, postcode = d.Postcode, country = d.Country
            });
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

            await ApplyBillTemplateAsync(vm, branchId, null);   // the shared link prints with the branch's template too
            return View("PrintBill", vm);
        }

        #region ── B2B Billing, Credit Policy, Invoicing & Multi-Bill Settlement ──

        [HttpGet]
        public async Task<IActionResult> GetPartnerCreditStatus(string agentType, int agentId)
        {
            if (User.GetFranchiseId() is int ownFranchiseId) { agentType = "F"; agentId = ownFranchiseId; }
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

        // Franchise wallet top-up moved to Utility > Franchise Top-Up (FranchiseTopUpController, SQLScripts/2225).

        [HttpGet]
        public async Task<IActionResult> FranchiseWalletStatement(int franchiseId, DateTime? fromDate, DateTime? toDate)
        {
            if (User.IsFranchiseUser()) return Forbid();   // the wallet screens stay with the lab
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
            if (!FranchiseMayUsePartner(agentType, agentId)) return Json(new { success = false, error = "You can only work with your own franchise's bills." });
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

                if (!await permissionGuard.AllowsAsync(HttpContext, "LAB.LABORDERBOOKING.B2BSETTLEMENT", "SETTLE")) return Json(new { success = false, error = "You do not have permission for this action." });
                if (!FranchiseMayUsePartner(request.AgentType, request.AgentId))
                    return Json(new { success = false, error = "You can only work with your own franchise's bills." });

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
            catch (HttpRequestException ex)
            {
                // the procedure's own reason (already settled, more than due, reference reused ...) comes back as {"message": "..."}
                return Json(new { success = false, error = ApiErrorMessage(ex.Message) ?? ex.Message });
            }
            catch (Exception ex)
            {
                return Json(new { success = false, error = ex.Message });
            }
        }

        private static string? ApiErrorMessage(string raw)
        {
            var i = raw.IndexOf('{');
            if (i < 0) return null;
            try
            {
                using var doc = JsonDocument.Parse(raw[i..]);
                return doc.RootElement.TryGetProperty("message", out var m) ? m.GetString() : null;
            }
            catch (JsonException) { return null; }
        }

        [HttpGet]
        public async Task<IActionResult> PrintSettlementReceipt(string receiptNo)
        {
            if (string.IsNullOrWhiteSpace(receiptNo))
            {
                return BadRequest("Receipt number is required.");
            }

            var receipt = await b2bBillingApiClient.GetSettlementReceiptAsync(receiptNo);
            if (receipt != null && !FranchiseMayUsePartner(receipt.AgentType, receipt.AgentId)) receipt = null;
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

            // a franchise login: only its own franchise's invoices (whoever generated them)
            if (User.GetFranchiseId() is int ownFranchiseId)
            {
                agentType = "F";
                agentId = ownFranchiseId;
                ViewBag.Franchises = ((List<SelectListItem>)ViewBag.Franchises).Where(f => f.Value == ownFranchiseId.ToString()).ToList();
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
            if (User.GetFranchiseId() is int ownFranchiseId) { agentType = "F"; agentId = ownFranchiseId; agentIds = null; }
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

        public sealed class CancelB2BInvoiceRequest { public int InvoiceId { get; set; } public string? Reason { get; set; } }

        /// <summary>B2B Invoices > Actions > Cancel (SQLScripts/2281): an unpaid invoice is cancelled with a reason, its bills
        /// become un-invoiced again. Permission: LAB.LABORDERBOOKING.B2BINVOICES : CANCEL; the procedure checks the rules.</summary>
        [HttpPost]
        public async Task<IActionResult> CancelB2BInvoice([FromBody] CancelB2BInvoiceRequest request)
        {
            if (!await permissionGuard.AllowsAsync(HttpContext, "LAB.LABORDERBOOKING.B2BINVOICES", EMR.Shared.Security.PermissionControls.Cancel))
                return Json(new { success = false, error = "You do not have permission to cancel invoices." });
            if (request == null || request.InvoiceId <= 0) return Json(new { success = false, error = "Invoice not found." });
            if (string.IsNullOrWhiteSpace(request.Reason)) return Json(new { success = false, error = "Enter the reason for cancelling the invoice." });
            try
            {
                var con = dbContext.Database.GetDbConnection();
                var r = await Dapper.SqlMapper.QueryFirstAsync<(int InvoiceId, string InvoiceNo, int BillsReleased)>(con, "dbo.usp_B2B_CancelInvoice",
                    new { request.InvoiceId, Reason = request.Reason.Trim(), UserId = User.GetUserId(), FranchiseId = User.GetFranchiseId() },
                    commandType: System.Data.CommandType.StoredProcedure);
                await auditLogService.LogActivityAsync(
                    eventType: "B2B Invoicing",
                    actionName: "LAB.B2BInvoiceCancelled",
                    description: $"B2B Invoice {r.InvoiceNo} cancelled ({r.BillsReleased} bill(s) released for re-invoicing). Reason: {request.Reason.Trim()}",
                    userId: User.GetUserId(),
                    branchId: User.GetCurrentBranchId(),
                    moduleCode: "LAB",
                    referenceNo: r.InvoiceNo,
                    referenceId: r.InvoiceId);
                return Json(new { success = true, message = $"Invoice {r.InvoiceNo} cancelled. {r.BillsReleased} bill(s) can be invoiced again." });
            }
            catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number >= 50000)
            {
                return Json(new { success = false, error = ex.Message });
            }
            catch (Exception ex)
            {
                logger.LogWarning(ex, "B2B invoice {InvoiceId} cancel failed", request.InvoiceId);
                return Json(new { success = false, error = "The invoice could not be cancelled. Please try again." });
            }
        }

        [HttpPost]
        public async Task<IActionResult> GenerateInvoice([FromBody] GenerateInvoiceRequestDto request)
        {
            try
            {
                var branchId = User.GetCurrentBranchId();
                if (branchId.HasValue) request.BranchId = branchId.Value;

                if (!await permissionGuard.AllowsAsync(HttpContext, "LAB.LABORDERBOOKING.B2BINVOICES", "GENERATE_INVOICE")) return Json(new { success = false, error = "You do not have permission for this action." });
                // a franchise login: only its own franchise, in the single invoice and in every batch group
                if (User.GetFranchiseId() is int ownId
                    && (!string.Equals(request.AgentType, "F", StringComparison.OrdinalIgnoreCase)
                        || (request.AgentId > 0 && request.AgentId != ownId)
                        || (request.PartnerGroups != null && request.PartnerGroups.Any(g => g.AgentId != ownId))))
                    return Json(new { success = false, error = "You can only work with your own franchise's bills." });

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
            if (detail == null || !FranchiseMayUsePartner(detail.PartnerType, detail.PartnerId))
            {
                TempData["Error"] = "Invoice not found.";
                return RedirectToAction(nameof(B2BInvoices));
            }
            ViewBag.Letterhead = await BuildInvoiceLetterheadAsync(detail.BranchId);
            return View(detail);
        }

        private static readonly Dictionary<string, string> GstStates = new()
        {
            ["01"] = "Jammu & Kashmir", ["02"] = "Himachal Pradesh", ["03"] = "Punjab", ["04"] = "Chandigarh", ["05"] = "Uttarakhand",
            ["06"] = "Haryana", ["07"] = "Delhi", ["08"] = "Rajasthan", ["09"] = "Uttar Pradesh", ["10"] = "Bihar", ["11"] = "Sikkim",
            ["12"] = "Arunachal Pradesh", ["13"] = "Nagaland", ["14"] = "Manipur", ["15"] = "Mizoram", ["16"] = "Tripura", ["17"] = "Meghalaya",
            ["18"] = "Assam", ["19"] = "West Bengal", ["20"] = "Jharkhand", ["21"] = "Odisha", ["22"] = "Chhattisgarh", ["23"] = "Madhya Pradesh",
            ["24"] = "Gujarat", ["26"] = "Dadra & Nagar Haveli and Daman & Diu", ["27"] = "Maharashtra", ["29"] = "Karnataka", ["30"] = "Goa",
            ["31"] = "Lakshadweep", ["32"] = "Kerala", ["33"] = "Tamil Nadu", ["34"] = "Puducherry", ["35"] = "Andaman & Nicobar Islands",
            ["36"] = "Telangana", ["37"] = "Andhra Pradesh", ["38"] = "Ladakh"
        };

        /// <summary>Supplier block of the B2B tax invoice - real company / branch data only, nothing hard-coded.</summary>
        private async Task<B2BInvoiceLetterheadViewModel> BuildInvoiceLetterheadAsync(int branchId)
        {
            var settings = await dbContext.HospitalSettings.AsNoTracking()
                .FirstOrDefaultAsync(s => s.BranchId == branchId && s.IsActive);
            var branch = await dbContext.BranchMasters.AsNoTracking().FirstOrDefaultAsync(b => b.BranchId == branchId);
            var companyId = settings?.CompanyId ?? branch?.CompanyId ?? User.GetCompanyId();
            var company = await dbContext.CompanyMasters.AsNoTracking().FirstOrDefaultAsync(c => c.CompanyId == companyId);

            string? Join(params string?[] parts) =>
                string.Join(", ", parts.Where(p => !string.IsNullOrWhiteSpace(p)).Select(p => p!.Trim())) is { Length: > 0 } s ? s : null;
            string? First(params string?[] values) => values.FirstOrDefault(v => !string.IsNullOrWhiteSpace(v))?.Trim();

            var gstin = First(settings?.GSTCode, company?.GSTIN)?.ToUpperInvariant();
            var vm = new B2BInvoiceLetterheadViewModel
            {
                DisplayName = First(settings?.HospitalName, company?.CompanyName, branch?.BranchName) ?? "Diagnostic Laboratory",
                LegalName = First(company?.LegalName, company?.CompanyName),
                Tagline = settings?.HospitalType,
                LogoPath = First(settings?.LogoPath, company?.LogoPath),
                // the Hospital Settings address is printed as entered (same as the other print pages)
                Address = First(settings?.Address,
                                Join(branch?.Address, branch?.City, branch?.State, branch?.Pincode),
                                Join(company?.Address, company?.City, company?.State, company?.Pincode)),
                Phone = First(settings?.ContactNumber1, company?.Phone),
                Email = First(settings?.EmailAddress, company?.Email),
                Website = First(settings?.Website, company?.Website),
                RegistrationNumber = First(settings?.RegistrationNumber, company?.RegistrationNumber),
                GSTIN = gstin,
                PAN = First(company?.PAN, gstin is { Length: 15 } ? gstin.Substring(2, 10) : null),
                StateCode = gstin is { Length: >= 2 } && char.IsDigit(gstin[0]) && char.IsDigit(gstin[1]) ? gstin[..2] : null
            };
            // on a tax invoice the state is the one the GSTIN is registered in
            vm.State = (vm.StateCode != null && GstStates.TryGetValue(vm.StateCode, out var gstState) ? gstState : null)
                       ?? First(branch?.State, company?.State);

            try
            {
                var conn = dbContext.Database.GetDbConnection();
                var bank = await conn.QueryFirstOrDefaultAsync<(string? BankName, string? AccountNumber, string? BranchName, string? IFSCCode, string? UpiId)>(
                    "SELECT TOP 1 BankName, AccountNumber, BranchName, IFSCCode, UpiId FROM dbo.BankMaster WHERE IsActive = 1 ORDER BY IsPrimary DESC, Id");
                vm.BankName = bank.BankName; vm.BankAccountNumber = bank.AccountNumber; vm.BankBranch = bank.BranchName;
                vm.BankIfsc = bank.IFSCCode; vm.UpiId = bank.UpiId;
            }
            catch (Exception ex)
            {
                logger.LogWarning(ex, "B2B invoice: bank details could not be read");
            }
            return vm;
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

    /// <summary>The "your lab bill" email (bill PDF attached), in the common email layout.</summary>
    internal static class LabBillEmail
    {
        public static string Body(string? hospitalName, string? patientName, string? billNo, string? address)
        {
            static string H(string? v) => System.Net.WebUtility.HtmlEncode(v ?? string.Empty);
            var hospital = string.IsNullOrWhiteSpace(hospitalName) ? "our hospital" : hospitalName.Trim();
            return EmailLayout.Wrap(
                EmailLayout.Greeting(patientName ?? "Patient")
                + EmailLayout.P($"Thank you for choosing <strong>{H(hospital)}</strong> for your healthcare needs.")
                + EmailLayout.Details(("Bill No", H(billNo)), ("Date", DateTime.Now.ToString("dd MMM yyyy")))
                + EmailLayout.P("Please find your detailed lab order bill attached to this email as a PDF document.")
                + EmailLayout.P("If you have any questions or require further assistance, please do not hesitate to contact us.")
                + EmailLayout.P($"Wishing you the best of health,<br/><strong>The {H(hospital)} Team</strong>"),
                heading: "Your lab bill",
                organisation: hospital,
                footerHtml: $"&copy; {DateTime.Now.Year} {H(hospital)}. All rights reserved."
                            + (string.IsNullOrWhiteSpace(address) ? "" : $"<br/>{H(address)}"));
        }
    }
}
