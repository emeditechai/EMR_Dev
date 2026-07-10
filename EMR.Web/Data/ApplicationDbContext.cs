using EMR.Web.Models.Entities;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Data;

public class ApplicationDbContext(DbContextOptions<ApplicationDbContext> options) : DbContext(options)
{
    public DbSet<User> Users => Set<User>();
    public DbSet<ReferralDoctorMaster> ReferralDoctorMasters => Set<ReferralDoctorMaster>();
    public DbSet<Role> Roles => Set<Role>();
    public DbSet<BranchMaster> BranchMasters => Set<BranchMaster>();
    public DbSet<UserBranch> UserBranches => Set<UserBranch>();
    public DbSet<UserRole> UserRoles => Set<UserRole>();
    public DbSet<AuditLog> AuditLogs => Set<AuditLog>();
    public DbSet<HospitalSettings> HospitalSettings => Set<HospitalSettings>();
    public DbSet<EmailTemplate> EmailTemplates => Set<EmailTemplate>();

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

        modelBuilder.Entity<User>(entity =>
        {
            entity.ToTable("Users");
            entity.HasKey(x => x.Id);
            entity.HasIndex(x => x.Username).IsUnique();
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
    }
}
