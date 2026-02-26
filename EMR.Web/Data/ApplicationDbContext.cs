using EMR.Web.Models.Entities;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Data;

public class ApplicationDbContext(DbContextOptions<ApplicationDbContext> options) : DbContext(options)
{
    public DbSet<User> Users => Set<User>();
    public DbSet<Role> Roles => Set<Role>();
    public DbSet<BranchMaster> BranchMasters => Set<BranchMaster>();
    public DbSet<UserBranch> UserBranches => Set<UserBranch>();
    public DbSet<UserRole> UserRoles => Set<UserRole>();
    public DbSet<AuditLog> AuditLogs => Set<AuditLog>();
    public DbSet<HospitalSettings> HospitalSettings => Set<HospitalSettings>();

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
    }
}
