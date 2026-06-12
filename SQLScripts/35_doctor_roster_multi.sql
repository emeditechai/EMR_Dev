USE [Dev_EMR]
GO

-- 1. usp_Api_DoctorSchedule_GetByDoctor
CREATE OR ALTER PROCEDURE [dbo].[usp_Api_DoctorSchedule_GetByDoctor]
    @DoctorId INT = NULL,
    @BranchId INT = NULL,
    @DepartmentId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 
        dsm.ScheduleId,
        dsm.DoctorId,
        d.FullName AS DoctorName,
        dsm.BranchId,
        dsm.RoomId,
        drm.RoomName,
        dsm.DayOfWeek,
        dsm.StartTime,
        dsm.EndTime,
        dsm.SlotDurationMinutes,
        dsm.MaxPatientsPerSlot,
        dsm.MaxPatientsPerSession,
        dsm.ScheduleType,
        dsm.EffectiveFrom,
        dsm.EffectiveTo,
        dsm.IsActive,
        CASE dsm.DayOfWeek
            WHEN 1 THEN 'Monday'
            WHEN 2 THEN 'Tuesday'
            WHEN 3 THEN 'Wednesday'
            WHEN 4 THEN 'Thursday'
            WHEN 5 THEN 'Friday'
            WHEN 6 THEN 'Saturday'
            WHEN 7 THEN 'Sunday'
        END AS DayName
    FROM DoctorScheduleMaster dsm
    INNER JOIN DoctorMaster d ON dsm.DoctorId = d.DoctorId
    LEFT JOIN DoctorRoomMaster drm ON dsm.RoomId = drm.RoomId
    WHERE (@DoctorId IS NULL OR dsm.DoctorId = @DoctorId) 
      AND (@BranchId IS NULL OR dsm.BranchId = @BranchId)
      AND (@DepartmentId IS NULL OR EXISTS (
          SELECT 1 FROM DoctorDepartmentMap ddm
          WHERE ddm.DoctorId = dsm.DoctorId AND ddm.DeptId = @DepartmentId AND ddm.IsActive = 1
      ))
      AND dsm.IsActive = 1
    ORDER BY dsm.DayOfWeek, dsm.StartTime;
END
GO

-- 2. usp_Api_DoctorScheduleException_GetByDoctor
CREATE OR ALTER PROCEDURE [dbo].[usp_Api_DoctorScheduleException_GetByDoctor]
    @DoctorId INT = NULL,
    @BranchId INT = NULL,
    @FromDate DATE = NULL,
    @ToDate DATE = NULL,
    @DepartmentId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 
        e.ExceptionId,
        e.DoctorId,
        d.FullName AS DoctorName,
        e.BranchId,
        e.ExceptionDate,
        e.Reason,
        e.ExceptionType
    FROM DoctorScheduleException e
    INNER JOIN DoctorMaster d ON e.DoctorId = d.DoctorId
    WHERE (@DoctorId IS NULL OR e.DoctorId = @DoctorId)
      AND (@BranchId IS NULL OR e.BranchId = @BranchId)
      AND (@FromDate IS NULL OR e.ExceptionDate >= @FromDate)
      AND (@ToDate IS NULL OR e.ExceptionDate <= @ToDate)
      AND (@DepartmentId IS NULL OR EXISTS (
          SELECT 1 FROM DoctorDepartmentMap ddm
          WHERE ddm.DoctorId = e.DoctorId AND ddm.DeptId = @DepartmentId AND ddm.IsActive = 1
      ))
      AND e.IsActive = 1
    ORDER BY e.ExceptionDate DESC;
END
GO
