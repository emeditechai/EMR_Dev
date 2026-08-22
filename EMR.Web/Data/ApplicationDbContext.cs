using EMR.Web.Models.Entities;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Data;

public class ApplicationDbContext(DbContextOptions<ApplicationDbContext> options) : DbContext(options)
{
    public DbSet<CompanyMaster> CompanyMasters => Set<CompanyMaster>();
    public DbSet<User> Users => Set<User>();
    public DbSet<DoctorMaster> DoctorMasters => Set<DoctorMaster>();
    public DbSet<ReferralDoctorMaster> ReferralDoctorMasters => Set<ReferralDoctorMaster>();
    public DbSet<Role> Roles => Set<Role>();
    public DbSet<BranchMaster> BranchMasters => Set<BranchMaster>();
    public DbSet<UserBranch> UserBranches => Set<UserBranch>();
    public DbSet<UserRole> UserRoles => Set<UserRole>();
    public DbSet<AuditLog> AuditLogs => Set<AuditLog>();
    public DbSet<HospitalSettings> HospitalSettings => Set<HospitalSettings>();
    public DbSet<EmailTemplate> EmailTemplates => Set<EmailTemplate>();
    public DbSet<BuildingMaster> BuildingMasters => Set<BuildingMaster>();
    public DbSet<FloorMaster> FloorMasters => Set<FloorMaster>();
    public DbSet<DepartmentMaster> DepartmentMasters => Set<DepartmentMaster>();
    public DbSet<CorporateMaster> CorporateMasters => Set<CorporateMaster>();
    public DbSet<CorporateHospitalRateMaster> CorporateHospitalRateMasters => Set<CorporateHospitalRateMaster>();
    public DbSet<InsuranceTPAMaster> InsuranceTPAMasters => Set<InsuranceTPAMaster>();
    public DbSet<InsuranceTariffMaster> InsuranceTariffMasters => Set<InsuranceTariffMaster>();
    public DbSet<GovernmentSchemeMaster> GovernmentSchemeMasters => Set<GovernmentSchemeMaster>();
    public DbSet<ShiftMaster> ShiftMasters => Set<ShiftMaster>();
    public DbSet<HKLocationMaster> HKLocationMasters => Set<HKLocationMaster>();
    public DbSet<HKChecklistTemplateMaster> HKChecklistTemplateMasters => Set<HKChecklistTemplateMaster>();
    public DbSet<HKCleaningMaster> HKCleaningMasters => Set<HKCleaningMaster>();
    public DbSet<HKStaffMaster> HKStaffMasters => Set<HKStaffMaster>();


    // Patient Registration masters
    public DbSet<ReligionMaster> ReligionMasters => Set<ReligionMaster>();
    public DbSet<RelationMaster> RelationMasters => Set<RelationMaster>();
    public DbSet<IdentificationTypeMaster> IdentificationTypeMasters => Set<IdentificationTypeMaster>();
    public DbSet<OccupationMaster> OccupationMasters => Set<OccupationMaster>();
    public DbSet<MaritalStatusMaster> MaritalStatusMasters => Set<MaritalStatusMaster>();
    public DbSet<PatientMaster> PatientMasters => Set<PatientMaster>();
    public DbSet<PatientOPDService> PatientOPDServices => Set<PatientOPDService>();
    public DbSet<PatientOPDServiceItem> PatientOPDServiceItems => Set<PatientOPDServiceItem>();
    public DbSet<ServiceMaster> ServiceMasters => Set<ServiceMaster>();

    // Payment
    public DbSet<PaymentMethodMaster> PaymentMethodMasters => Set<PaymentMethodMaster>();
    public DbSet<PaymentHeader> PaymentHeaders => Set<PaymentHeader>();
    public DbSet<PaymentLineItem> PaymentLineItems => Set<PaymentLineItem>();
    public DbSet<PaymentDetail> PaymentDetails => Set<PaymentDetail>();

    // EMR Templates
    public DbSet<EmrTemplate> EmrTemplates => Set<EmrTemplate>();
    public DbSet<EmrTemplateSpecialityMap> EmrTemplateSpecialityMaps => Set<EmrTemplateSpecialityMap>();
    public DbSet<EmrTemplateSection> EmrTemplateSections => Set<EmrTemplateSection>();
    public DbSet<EmrTemplateField> EmrTemplateFields => Set<EmrTemplateField>();
    public DbSet<DoctorSpecialityMaster> DoctorSpecialityMasters => Set<DoctorSpecialityMaster>();
    public DbSet<DoctorSubSpecialityMaster> DoctorSubSpecialityMasters => Set<DoctorSubSpecialityMaster>();
    public DbSet<ClinicalUnitMaster> ClinicalUnitMasters => Set<ClinicalUnitMaster>();
    public DbSet<WardMaster> WardMasters => Set<WardMaster>();
    public DbSet<NursingStationMaster> NursingStationMasters => Set<NursingStationMaster>();
    public DbSet<RoomMaster> RoomMasters => Set<RoomMaster>();
    public DbSet<BedCategoryMaster> BedCategoryMasters => Set<BedCategoryMaster>();
    public DbSet<BedMaster> BedMasters => Set<BedMaster>();
    public DbSet<TariffCategoryMaster> TariffCategoryMasters => Set<TariffCategoryMaster>();
    public DbSet<BedRoomTariffMaster> BedRoomTariffMasters => Set<BedRoomTariffMaster>();
    public DbSet<BedRoomTariffHistory> BedRoomTariffHistories => Set<BedRoomTariffHistory>();
    public DbSet<HospitalServiceMaster> HospitalServiceMasters => Set<HospitalServiceMaster>();
    public DbSet<HospitalServiceRateMaster> HospitalServiceRateMasters => Set<HospitalServiceRateMaster>();
    public DbSet<ProcedureMaster> ProcedureMasters => Set<ProcedureMaster>();
    public DbSet<ProcedureTariffMaster> ProcedureTariffMasters => Set<ProcedureTariffMaster>();
    public DbSet<OtMaster> OtMasters => Set<OtMaster>();
    public DbSet<OtEquipmentMaster> OtEquipmentMasters => Set<OtEquipmentMaster>();
    public DbSet<OtTariffMaster> OtTariffMasters => Set<OtTariffMaster>();
    public DbSet<AnaesthesiaTypeMaster> AnaesthesiaTypeMasters => Set<AnaesthesiaTypeMaster>();
    public DbSet<AnaesthesiaRateMaster> AnaesthesiaRateMasters => Set<AnaesthesiaRateMaster>();
    public DbSet<IcuMaster> IcuMasters => Set<IcuMaster>();
    public DbSet<IcuTariffMaster> IcuTariffMasters => Set<IcuTariffMaster>();
    public DbSet<IcuTariffDetail> IcuTariffDetails => Set<IcuTariffDetail>();
    public DbSet<ConsentMaster> ConsentMasters => Set<ConsentMaster>();
    public DbSet<DoctorVisitProcessConfig> DoctorVisitProcessConfigs => Set<DoctorVisitProcessConfig>();
    public DbSet<DoctorCommissionConfig> DoctorCommissionConfigs => Set<DoctorCommissionConfig>();
    public DbSet<DoctorDisbursal> DoctorDisbursals => Set<DoctorDisbursal>();
    public DbSet<DoctorBillingAdjustment> DoctorBillingAdjustments => Set<DoctorBillingAdjustment>();









    // EMR Master Lists
    public DbSet<EmrInvestigationMaster> EmrInvestigationMasters => Set<EmrInvestigationMaster>();
    public DbSet<EmrMedicationMaster> EmrMedicationMasters => Set<EmrMedicationMaster>();

    // Patient consultations
    public DbSet<EmrPatientConsultation> EmrPatientConsultations => Set<EmrPatientConsultation>();

    // SMTP Email Configuration
    public DbSet<SmtpEmailConfiguration> SmtpEmailConfigurations => Set<SmtpEmailConfiguration>();

    // Email Logs
    public DbSet<EmailLog> EmailLogs => Set<EmailLog>();

    // Video Consultation
    public DbSet<VideoSystemConfig> VideoSystemConfigs => Set<VideoSystemConfig>();
    public DbSet<VideoConsultation> VideoConsultations => Set<VideoConsultation>();

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        base.OnModelCreating(modelBuilder);

        modelBuilder.Entity<CompanyMaster>(entity =>
        {
            entity.ToTable("CompanyMaster");
            entity.HasKey(x => x.CompanyId);
            entity.HasIndex(x => x.CompanyCode).IsUnique();
        });

        modelBuilder.Entity<User>(entity =>
        {
            entity.ToTable("Users");
            entity.HasKey(x => x.Id);
            entity.HasIndex(x => x.Username).IsUnique();
            entity.HasOne(x => x.Company)
                .WithMany(x => x.Users)
                .HasForeignKey(x => x.CompanyId)
                .OnDelete(DeleteBehavior.Restrict);
        });

        modelBuilder.Entity<Role>(entity =>
        {
            entity.ToTable("roles");
            entity.HasKey(x => x.Id);
            entity.Property(x => x.BranchId).HasColumnName("BranchID");
            entity.HasOne(x => x.Branch)
                .WithMany(x => x.Roles)
                .HasForeignKey(x => x.BranchId)
                .OnDelete(DeleteBehavior.Restrict);
        });

        modelBuilder.Entity<BranchMaster>(entity =>
        {
            entity.ToTable("Branchmaster");
            entity.HasKey(x => x.BranchId);
            entity.Property(x => x.BranchId).HasColumnName("BranchID");
            entity.HasOne(x => x.Company)
                .WithMany(x => x.Branches)
                .HasForeignKey(x => x.CompanyId)
                .OnDelete(DeleteBehavior.Restrict);
        });


        modelBuilder.Entity<UserBranch>(entity =>
        {
            entity.ToTable("UserBranches");
            entity.HasKey(x => x.Id);
            entity.Property(x => x.BranchId).HasColumnName("BranchID");
            entity.HasOne(x => x.User)
                .WithMany(x => x.UserBranches)
                .HasForeignKey(x => x.UserId)
                .OnDelete(DeleteBehavior.Cascade);
            entity.HasOne(x => x.Branch)
                .WithMany(x => x.UserBranches)
                .HasForeignKey(x => x.BranchId)
                .OnDelete(DeleteBehavior.Restrict);
        });

        modelBuilder.Entity<UserRole>(entity =>
        {
            entity.ToTable("Userroles");
            entity.HasKey(x => x.Id);
            entity.HasOne(x => x.User)
                .WithMany(x => x.UserRoles)
                .HasForeignKey(x => x.UserId)
                .OnDelete(DeleteBehavior.Cascade);
            entity.HasOne(x => x.Role)
                .WithMany(x => x.UserRoles)
                .HasForeignKey(x => x.RoleId)
                .OnDelete(DeleteBehavior.Restrict);
        });

        modelBuilder.Entity<HospitalSettings>(entity =>
        {
            entity.ToTable("HospitalSettings");
            entity.HasKey(x => x.Id);
            entity.Property(x => x.BranchId).HasColumnName("BranchID");
            entity.Property(x => x.HospitalName).HasColumnName("HotelName");
            entity.HasOne(x => x.Branch)
                .WithMany()
                .HasForeignKey(x => x.BranchId)
                .OnDelete(DeleteBehavior.Restrict);
        });

        modelBuilder.Entity<BuildingMaster>(entity =>
        {
            entity.ToTable("BuildingMaster");
            entity.HasKey(x => x.BuildingId);
            entity.HasMany(x => x.Floors)
                .WithOne(x => x.Building)
                .HasForeignKey(x => x.BuildingId)
                .OnDelete(DeleteBehavior.Restrict);
        });

        modelBuilder.Entity<FloorMaster>(entity =>
        {
            entity.ToTable("FloorMaster");
            entity.HasKey(x => x.FloorId);
        });

        modelBuilder.Entity<DepartmentMaster>(entity =>
        {
            entity.ToTable("DepartmentMaster");
            entity.HasKey(x => x.DeptId);
        });

        modelBuilder.Entity<DoctorMaster>(entity =>
        {
            entity.ToTable("DoctorMaster");
            entity.HasKey(x => x.DoctorId);
        });

        modelBuilder.Entity<DoctorSubSpecialityMaster>(entity =>
        {
            entity.ToTable("DoctorSubSpecialityMaster");
            entity.HasKey(x => x.SubSpecialityId);
            entity.HasOne(x => x.Speciality)
                .WithMany(x => x.SubSpecialities)
                .HasForeignKey(x => x.SpecialityId)
                .OnDelete(DeleteBehavior.Cascade);
        });


        modelBuilder.Entity<ClinicalUnitMaster>(entity =>
        {
            entity.ToTable("ClinicalUnitMaster");
            entity.HasKey(x => x.UnitId);
            entity.HasOne(x => x.Department)
                .WithMany()
                .HasForeignKey(x => x.DepartmentId)
                .OnDelete(DeleteBehavior.Restrict);
            entity.HasOne(x => x.Speciality)
                .WithMany()
                .HasForeignKey(x => x.SpecialityId)
                .OnDelete(DeleteBehavior.Restrict);
            entity.HasOne(x => x.ConsultantInCharge)
                .WithMany()
                .HasForeignKey(x => x.ConsultantInChargeDoctorId)
                .OnDelete(DeleteBehavior.SetNull);
        });

        modelBuilder.Entity<WardMaster>(entity =>

        {
            entity.ToTable("WardMaster");
            entity.HasKey(x => x.WardId);
            entity.HasOne(x => x.Floor)
                .WithMany()
                .HasForeignKey(x => x.FloorId)
                .OnDelete(DeleteBehavior.Restrict);
            entity.HasOne(x => x.Department)
                .WithMany()
                .HasForeignKey(x => x.DepartmentId)
                .OnDelete(DeleteBehavior.Restrict);
            entity.HasMany(x => x.NursingStations)
                .WithOne(x => x.Ward)
                .HasForeignKey(x => x.WardId)
                .OnDelete(DeleteBehavior.Cascade);
        });

        modelBuilder.Entity<NursingStationMaster>(entity =>
        {
            entity.ToTable("NursingStationMaster");
            entity.HasKey(x => x.NursingStationId);
            entity.HasOne(x => x.Ward)
                .WithMany(x => x.NursingStations)
                .HasForeignKey(x => x.WardId)
                .OnDelete(DeleteBehavior.Cascade);
        });

        modelBuilder.Entity<RoomMaster>(entity =>
        {
            entity.ToTable("RoomMaster");
            entity.HasKey(x => x.RoomId);
            entity.HasOne(x => x.Building)
                .WithMany()
                .HasForeignKey(x => x.BuildingId)
                .OnDelete(DeleteBehavior.Restrict);
            entity.HasOne(x => x.Floor)
                .WithMany()
                .HasForeignKey(x => x.FloorId)
                .OnDelete(DeleteBehavior.Restrict);
            entity.HasOne(x => x.Ward)
                .WithMany()
                .HasForeignKey(x => x.WardId)
                .OnDelete(DeleteBehavior.Restrict);
        });

        modelBuilder.Entity<BedCategoryMaster>(entity =>
        {
            entity.ToTable("BedCategoryMaster");
            entity.HasKey(x => x.BedCategoryId);
        });

        modelBuilder.Entity<BedMaster>(entity =>
        {
            entity.ToTable("BedMaster");
            entity.HasKey(x => x.BedId);
            entity.HasOne(x => x.Building)
                .WithMany()
                .HasForeignKey(x => x.BuildingId)
                .OnDelete(DeleteBehavior.Restrict);
            entity.HasOne(x => x.Ward)
                .WithMany()
                .HasForeignKey(x => x.WardId)
                .OnDelete(DeleteBehavior.Restrict);
            entity.HasOne(x => x.Room)
                .WithMany()
                .HasForeignKey(x => x.RoomId)
                .OnDelete(DeleteBehavior.Restrict);
            entity.HasOne(x => x.BedCategory)
                .WithMany()
                .HasForeignKey(x => x.BedCategoryId)
                .OnDelete(DeleteBehavior.Restrict);
        });

        modelBuilder.Entity<TariffCategoryMaster>(entity =>
        {
            entity.ToTable("TariffCategoryMaster");
            entity.HasKey(x => x.TariffCategoryId);
        });

        modelBuilder.Entity<BedRoomTariffMaster>(entity =>
        {
            entity.ToTable("BedRoomTariffMaster");
            entity.HasKey(x => x.BedRateId);
            entity.HasOne(x => x.Ward)
                .WithMany()
                .HasForeignKey(x => x.WardId)
                .OnDelete(DeleteBehavior.Restrict);
            entity.HasOne(x => x.Room)
                .WithMany()
                .HasForeignKey(x => x.RoomId)
                .OnDelete(DeleteBehavior.Restrict);
            entity.HasOne(x => x.BedCategory)
                .WithMany()
                .HasForeignKey(x => x.BedCategoryId)
                .OnDelete(DeleteBehavior.Restrict);
            entity.HasOne(x => x.TariffCategory)
                .WithMany()
                .HasForeignKey(x => x.TariffCategoryId)
                .OnDelete(DeleteBehavior.Restrict);
        });

        modelBuilder.Entity<BedRoomTariffHistory>(entity =>
        {
            entity.ToTable("BedRoomTariffHistory");
            entity.HasKey(x => x.HistoryId);
            entity.HasOne(x => x.BedRate)
                .WithMany()
                .HasForeignKey(x => x.BedRateId)
                .OnDelete(DeleteBehavior.Cascade);
        });









        modelBuilder.Entity<AuditLog>(entity =>
        {
            entity.ToTable("AuditLogs");
            entity.HasKey(x => x.Id);
            entity.HasIndex(x => x.CreatedDate);
            entity.HasIndex(x => new { x.UserId, x.BranchId, x.CreatedDate });
        });


        // ── Patient Registration Masters ─────────────────────────────────────

        modelBuilder.Entity<ReligionMaster>(entity =>
        {
            entity.ToTable("ReligionMaster");
            entity.HasKey(x => x.ReligionId);
        });

        modelBuilder.Entity<RelationMaster>(entity =>
        {
            entity.ToTable("RelationMaster");
            entity.HasKey(x => x.RelationId);
        });

        modelBuilder.Entity<IdentificationTypeMaster>(entity =>
        {
            entity.ToTable("IdentificationTypeMaster");
            entity.HasKey(x => x.IdentificationTypeId);
        });

        modelBuilder.Entity<OccupationMaster>(entity =>
        {
            entity.ToTable("OccupationMaster");
            entity.HasKey(x => x.OccupationId);
        });

        modelBuilder.Entity<MaritalStatusMaster>(entity =>
        {
            entity.ToTable("MaritalStatusMaster");
            entity.HasKey(x => x.MaritalStatusId);
        });

        modelBuilder.Entity<PatientMaster>(entity =>
        {
            entity.ToTable("PatientMaster");
            entity.HasKey(x => x.PatientId);
            entity.HasIndex(x => x.PatientCode).IsUnique();
            entity.HasIndex(x => x.PhoneNumber);
        });

        modelBuilder.Entity<PatientOPDService>(entity =>
        {
            entity.ToTable("PatientOPDService");
            entity.HasKey(x => x.OPDServiceId);
            entity.HasOne(x => x.Patient)
                  .WithMany()
                  .HasForeignKey(x => x.PatientId)
                  .OnDelete(DeleteBehavior.Cascade);
        });

        modelBuilder.Entity<PatientOPDServiceItem>(entity =>
        {
            entity.ToTable("PatientOPDServiceItem");
            entity.HasKey(x => x.ItemId);
            entity.HasOne(x => x.OPDService)
                  .WithMany(x => x.Items)
                  .HasForeignKey(x => x.OPDServiceId)
                  .OnDelete(DeleteBehavior.Cascade);
        });

        modelBuilder.Entity<ServiceMaster>(entity =>
        {
            entity.ToTable("ServiceMaster");
            entity.HasKey(x => x.ServiceId);
        });

        // ── Payment ──────────────────────────────────────────────────────────

        modelBuilder.Entity<PaymentMethodMaster>(entity =>
        {
            entity.ToTable("PaymentMethodMaster");
            entity.HasKey(x => x.PaymentMethodId);
        });

        modelBuilder.Entity<PaymentHeader>(entity =>
        {
            entity.ToTable("PaymentHeader");
            entity.HasKey(x => x.PaymentHeaderId);
            entity.Property(x => x.PaymentStatus).HasMaxLength(1);
            entity.Property(x => x.HeaderDiscountType).HasMaxLength(1);
            entity.HasIndex(x => new { x.ModuleCode, x.ModuleRefId });
            entity.HasIndex(x => x.OPDServiceId);
            entity.HasOne(x => x.OPDService)
                  .WithMany()
                  .HasForeignKey(x => x.OPDServiceId)
                  .OnDelete(DeleteBehavior.Restrict)
                  .IsRequired(false);
            entity.HasMany(x => x.LineItems)
                  .WithOne(x => x.Header)
                  .HasForeignKey(x => x.PaymentHeaderId)
                  .OnDelete(DeleteBehavior.Cascade);
            entity.HasMany(x => x.Details)
                  .WithOne(x => x.Header)
                  .HasForeignKey(x => x.PaymentHeaderId)
                  .OnDelete(DeleteBehavior.Cascade);
        });

        modelBuilder.Entity<PaymentLineItem>(entity =>
        {
            entity.ToTable("PaymentLineItem");
            entity.HasKey(x => x.PaymentLineItemId);
            entity.Property(x => x.LineDiscountType).HasMaxLength(1);
            entity.HasIndex(x => x.PaymentHeaderId);
        });

        modelBuilder.Entity<PaymentDetail>(entity =>
        {
            entity.ToTable("PaymentDetail");
            entity.HasKey(x => x.PaymentDetailId);
            entity.HasIndex(x => x.PaymentHeaderId);
            entity.HasOne(x => x.Method)
                  .WithMany()
                  .HasForeignKey(x => x.PaymentMethodId)
                  .OnDelete(DeleteBehavior.Restrict);
        });

        modelBuilder.Entity<EmrTemplateSpecialityMap>(entity =>
        {
            entity.HasKey(x => new { x.TemplateId, x.SpecialityId });
        });

        // ── SMTP Email Configuration ────────────────────────────────────────
        modelBuilder.Entity<SmtpEmailConfiguration>(entity =>
        {
            entity.ToTable("SmtpEmailConfiguration");
            entity.HasKey(x => x.Id);
            entity.Property(x => x.BranchId).HasColumnName("BranchId");
            entity.Property(x => x.ProviderType).HasMaxLength(50);
            entity.HasOne(x => x.Branch)
                .WithMany()
                .HasForeignKey(x => x.BranchId)
                .OnDelete(DeleteBehavior.Restrict);
        });

        // ── Email Logs ──────────────────────────────────────────────────────
        modelBuilder.Entity<EmailLog>(entity =>
        {
            entity.ToTable("EmailLogs");
            entity.HasKey(x => x.Id);
            entity.Property(x => x.Status).HasMaxLength(50);
            entity.HasOne(x => x.Branch)
                .WithMany()
                .HasForeignKey(x => x.BranchId)
                .OnDelete(DeleteBehavior.Restrict);
            entity.HasOne(x => x.Config)
                .WithMany()
                .HasForeignKey(x => x.ConfigId)
                .OnDelete(DeleteBehavior.Restrict);
        });

        // ── Video System Config ──────────────────────────────────────────────
        modelBuilder.Entity<VideoSystemConfig>(entity =>
        {
            entity.ToTable("tbl_VideoSystemConfig");
            entity.HasKey(x => x.ConfigId);
            entity.HasIndex(x => x.ConfigKey).IsUnique();
            entity.Property(x => x.ConfigKey).HasMaxLength(100);
            entity.Property(x => x.MeetingCreationUrl).HasMaxLength(200);
        });

        // ── Video Consultation ───────────────────────────────────────────────
        modelBuilder.Entity<VideoConsultation>(entity =>
        {
            entity.ToTable("tbl_VideoConsultation");
            entity.HasKey(x => x.ConsultationId);
            entity.Property(x => x.WherebyMeetingId).HasMaxLength(50);
            entity.Property(x => x.DoctorHostUrl).HasMaxLength(500);
            entity.Property(x => x.PatientRoomUrl).HasMaxLength(500);
            entity.Property(x => x.RoomNamePrefix).HasMaxLength(100);
            entity.Property(x => x.Status).HasMaxLength(20);
            entity.Property(x => x.CreatedBy).HasMaxLength(100);
        });

        // ── Insurance / TPA Master ──────────────────────────────────────────
        modelBuilder.Entity<InsuranceTPAMaster>(entity =>
        {
            entity.ToTable("InsuranceTPAMaster");
            entity.HasKey(x => x.InsuranceTPA_ID);
            entity.Property(x => x.Branch_ID).HasColumnName("Branch_ID");
            entity.HasOne(x => x.Branch)
                .WithMany()
                .HasForeignKey(x => x.Branch_ID)
                .OnDelete(DeleteBehavior.Restrict);
        });

        // ── Corporate Hospital Rate Master ───────────────────────────────────
        modelBuilder.Entity<CorporateHospitalRateMaster>(entity =>
        {
            entity.ToTable("CorporateHospitalRateMaster");
            entity.HasKey(x => x.CorpRate_ID);
            entity.Property(x => x.Branch_ID).HasColumnName("Branch_ID");
            entity.Property(x => x.Corporate_ID).HasColumnName("Corporate_ID");
            entity.HasOne(x => x.Branch)
                .WithMany()
                .HasForeignKey(x => x.Branch_ID)
                .OnDelete(DeleteBehavior.Restrict);
            entity.HasOne(x => x.Corporate)
                .WithMany()
                .HasForeignKey(x => x.Corporate_ID)
                .OnDelete(DeleteBehavior.Cascade);
        });

        // ── Insurance Tariff Configuration ──────────────────────────────────
        modelBuilder.Entity<InsuranceTariffMaster>(entity =>
        {
            entity.ToTable("InsuranceTariffMaster");
            entity.HasKey(x => x.InsTariff_ID);
            entity.Property(x => x.Branch_ID).HasColumnName("Branch_ID");
            entity.Property(x => x.InsuranceTPA_ID).HasColumnName("InsuranceTPA_ID");
            entity.HasOne(x => x.Branch)
                .WithMany()
                .HasForeignKey(x => x.Branch_ID)
                .OnDelete(DeleteBehavior.Restrict);
            entity.HasOne(x => x.InsuranceTPA)
                .WithMany()
                .HasForeignKey(x => x.InsuranceTPA_ID)
                .OnDelete(DeleteBehavior.Cascade);
        });

        // ── Government Scheme Master ────────────────────────────────────────
        modelBuilder.Entity<GovernmentSchemeMaster>(entity =>
        {
            entity.ToTable("GovernmentSchemeMaster");
            entity.HasKey(x => x.Scheme_ID);
            entity.Property(x => x.Branch_ID).HasColumnName("Branch_ID");
            entity.HasOne(x => x.Branch)
                .WithMany()
                .HasForeignKey(x => x.Branch_ID)
                .OnDelete(DeleteBehavior.Restrict);
        });

        // ── Shift Master ────────────────────────────────────────────────────
        modelBuilder.Entity<ShiftMaster>(entity =>
        {
            entity.ToTable("ShiftMaster");
            entity.HasKey(x => x.ShiftMaster_ID);
            entity.Property(x => x.Branch_ID).HasColumnName("Branch_ID");
            entity.HasOne(x => x.Branch)
                .WithMany()
                .HasForeignKey(x => x.Branch_ID)
                .OnDelete(DeleteBehavior.Restrict);
        });

        // ── Housekeeping Masters ────────────────────────────────────────────
        modelBuilder.Entity<HKLocationMaster>(entity =>
        {
            entity.ToTable("HKLocationMaster");
            entity.HasKey(x => x.Location_ID);
            entity.Property(x => x.Branch_ID).HasColumnName("Branch_ID");
            entity.Property(x => x.Reference_ID).HasColumnName("Reference_ID");
            entity.Property(x => x.Floor_ID).HasColumnName("Floor_ID");
            entity.Property(x => x.Building_ID).HasColumnName("Building_ID");
            entity.HasOne(x => x.Branch).WithMany().HasForeignKey(x => x.Branch_ID).OnDelete(DeleteBehavior.Restrict);
            entity.HasOne(x => x.Floor).WithMany().HasForeignKey(x => x.Floor_ID).OnDelete(DeleteBehavior.Restrict);
            entity.HasOne(x => x.Building).WithMany().HasForeignKey(x => x.Building_ID).OnDelete(DeleteBehavior.Restrict);
        });

        modelBuilder.Entity<HKChecklistTemplateMaster>(entity =>
        {
            entity.ToTable("HKChecklistTemplateMaster");
            entity.HasKey(x => x.Template_ID);
            entity.Property(x => x.Branch_ID).HasColumnName("Branch_ID");
            entity.HasOne(x => x.Branch).WithMany().HasForeignKey(x => x.Branch_ID).OnDelete(DeleteBehavior.Restrict);
        });

        modelBuilder.Entity<HKCleaningMaster>(entity =>
        {
            entity.ToTable("HKCleaningMaster");
            entity.HasKey(x => x.Cleaning_ID);
            entity.Property(x => x.Branch_ID).HasColumnName("Branch_ID");
            entity.Property(x => x.ChecklistTemplate_ID).HasColumnName("ChecklistTemplate_ID");
            entity.HasOne(x => x.Branch).WithMany().HasForeignKey(x => x.Branch_ID).OnDelete(DeleteBehavior.Restrict);
            entity.HasOne(x => x.ChecklistTemplate).WithMany().HasForeignKey(x => x.ChecklistTemplate_ID).OnDelete(DeleteBehavior.SetNull);
        });

        modelBuilder.Entity<HKStaffMaster>(entity =>
        {
            entity.ToTable("HKStaffMaster");
            entity.HasKey(x => x.HKStaff_ID);
            entity.Property(x => x.Branch_ID).HasColumnName("Branch_ID");
            entity.Property(x => x.Staff_ID).HasColumnName("Staff_ID");
            entity.Property(x => x.ShiftMaster_ID).HasColumnName("ShiftMaster_ID");
            entity.Property(x => x.Supervisor_ID).HasColumnName("Supervisor_ID");
            entity.Property(x => x.AreaAllocation_ID).HasColumnName("AreaAllocation_ID");
            entity.HasOne(x => x.Branch).WithMany().HasForeignKey(x => x.Branch_ID).OnDelete(DeleteBehavior.Restrict);
            entity.HasOne(x => x.StaffUser).WithMany().HasForeignKey(x => x.Staff_ID).OnDelete(DeleteBehavior.Restrict);
            entity.HasOne(x => x.Shift).WithMany().HasForeignKey(x => x.ShiftMaster_ID).OnDelete(DeleteBehavior.Restrict);
            entity.HasOne(x => x.SupervisorUser).WithMany().HasForeignKey(x => x.Supervisor_ID).OnDelete(DeleteBehavior.Restrict);
            entity.HasOne(x => x.AreaAllocation).WithMany().HasForeignKey(x => x.AreaAllocation_ID).OnDelete(DeleteBehavior.Restrict);
        });
    }
}
