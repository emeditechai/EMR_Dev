-- ============================================================================
-- Migration: 2168_authorization_in_action_controls.sql
-- Description:
--   Server-Side Authorization - sensitive actions that travel inside an ordinary
--   save, so no endpoint of their own can carry the control. The controller
--   checks them from what is posted (IActionPermissionGuard):
--     LAB.LABREPORTING / LAB.LABIMAGEREPORTING   APPROVE   a save with status "Approved" (5)
--     OPD.PATIENTREGISTRATION                    DISCOUNT  a bill saved with a discount
--     LAB.LABORDERBOOKING.B2CBOOKING             DISCOUNT
--     LAB.LABORDERBOOKING.B2BBOOKING             DISCOUNT
--     OPD.SERVICEBOOKING, OPD.DASHBOARD,
--     LAB.LABORDERBOOKING.B2CORDERLIST / B2BREGISTRATION  DISCOUNT  in the shared payment modal
--       (/OPD/SavePayment accepts a new discount when the user holds DISCOUNT on any
--        billing screen of the bill's module; collecting a due is never blocked)
--   Like every sensitive control, each must be ticked explicitly on the role; the
--   page's VIEW alone does not grant it. Nothing is blocked while the page's
--   module is still in audit.
--
--   Also removes stray placements of screen post-backs: a POST that is a screen's
--   own action (e.g. POST LabOrderBooking/B2BBooking) belongs to that screen only.
--   The mapper had also placed it on screens that merely link to the GET page.
--   Run after 2167.
-- ============================================================================
USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
DECLARE @x TABLE (Page_Code NVARCHAR(150), Control_Code VARCHAR(30), Title NVARCHAR(150), Sort_Order INT);
INSERT INTO @x VALUES
    ('LAB.LABREPORTING',               'APPROVE',  N'Approve a report (save with status Approved)', 60),
    ('LAB.LABIMAGEREPORTING',          'APPROVE',  N'Approve a report (save with status Approved)', 60),
    ('OPD.PATIENTREGISTRATION',        'DISCOUNT', N'Give a discount on the bill',                   70),
    ('LAB.LABORDERBOOKING.B2CBOOKING', 'DISCOUNT', N'Give a discount on the bill',                   70),
    ('LAB.LABORDERBOOKING.B2BBOOKING', 'DISCOUNT', N'Give a discount on the bill',                   70),
    ('OPD.SERVICEBOOKING',             'DISCOUNT', N'Give a discount on the bill',                   70),
    ('OPD.DASHBOARD',                  'DISCOUNT', N'Give a discount when collecting payment',       70),
    ('LAB.LABORDERBOOKING.B2CORDERLIST',  'DISCOUNT', N'Give a discount when collecting payment',    70),
    ('LAB.LABORDERBOOKING.B2BREGISTRATION', 'DISCOUNT', N'Give a discount when collecting payment',  70);

INSERT INTO dbo.PageControlMaster (Page_ID, Control_Code, Title, Sort_Order)
SELECT p.Page_ID, x.Control_Code, x.Title, x.Sort_Order
FROM @x x INNER JOIN dbo.PageMaster p ON p.Page_Code = x.Page_Code
WHERE NOT EXISTS (SELECT 1 FROM dbo.PageControlMaster c WHERE c.Page_ID = p.Page_ID AND c.Control_Code = x.Control_Code);

-- A screen's post-back stays on that screen only.
DELETE m
FROM dbo.PageEndpointMap m
INNER JOIN dbo.PageMaster p ON p.Page_ID = m.Page_ID
WHERE m.Http_Method <> 'GET'
  AND NOT (p.Controller = m.Controller AND p.Action = m.Action)
  AND EXISTS (SELECT 1 FROM dbo.PageEndpointMap o
              INNER JOIN dbo.PageMaster op ON op.Page_ID = o.Page_ID AND op.IsActive = 1
              WHERE o.App = m.App AND o.Http_Method = m.Http_Method AND o.Controller = m.Controller AND o.Action = m.Action
                AND op.Controller = o.Controller AND op.Action = o.Action);
DECLARE @removed INT = @@ROWCOUNT;

-- Opening the sign-off screen is reading (the dashboard's "View" opens it too); only its POST signs.
UPDATE m SET m.Control_ID = v.Control_ID
FROM dbo.PageEndpointMap m
INNER JOIN dbo.PageControlMaster v ON v.Page_ID = m.Page_ID AND v.Control_Code = 'VIEW'
WHERE m.App = 'WEB' AND m.Http_Method = 'GET' AND m.Controller = 'PathologistDashboard' AND m.Action = 'Approve';

PRINT CONCAT('Script 2168 applied: in-action controls ready; ', @removed, ' stray post-back placement(s) removed.');
GO
