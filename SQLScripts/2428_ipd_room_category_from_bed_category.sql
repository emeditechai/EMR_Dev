-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 2428  Master > IPD > Room: Room Category now comes from the Bed Category Master (names after 2426). The old
--       fixed list values stored on rooms are renamed to the matching Bed Category names. Run after 2426. Safe to re-run.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
SET NOCOUNT ON;
DECLARE @m TABLE (OldName NVARCHAR(100), NewName NVARCHAR(150));
INSERT @m VALUES (N'General', N'General Ward'), (N'Semi-Private', N'Semi Private'), (N'Super Deluxe', N'Deluxe'), (N'Executive Suite', N'Suite'),
                 (N'ICU / Critical Care', N'ICU'), (N'Isolation / Negative Pressure', N'Isolation');
UPDATE r SET RoomCategory = m.NewName, ModifiedDate = GETDATE()
FROM dbo.RoomMaster r JOIN @m m ON m.OldName = r.RoomCategory;
PRINT CONCAT('2428 rooms renamed: ', @@ROWCOUNT);
GO
