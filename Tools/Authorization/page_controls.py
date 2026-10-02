"""Page-control catalogue: every action a screen offers becomes a control of that page.

For each placement (endpoint on a page) it decides the control the endpoint belongs to:
  VIEW        opening the screen, its lists, searches and look-ups
  ADD / EDIT / DETAILS / STATUS / DELETE / PRINT / EXPORT / IMPORT   the standard actions of a screen
  APPROVE / UNAUTHORIZE / CANCEL / REFUND / SETTLE / DISCOUNT        money and report-integrity actions
  <custom>    anything else the screen offers (e.g. Doctor Master > Consulting Charges, Configure Scheduler),
              named from the button / menu item on the screen or from OVERRIDES below
A control is kept active only when the screen really offers it: some view or script of that page calls one of its
endpoints. An endpoint no screen calls (e.g. POST Areas/Delete, which has no button) stays mapped to an inactive
control, so nobody but a super admin can reach it.

Controls not set on a role follow the page: a role allowed a page may use all its actions unless one is denied.

Usage (repo root):
  python3 Tools/Authorization/page_controls.py            -> report (catalogue per page)
  python3 Tools/Authorization/page_controls.py --apply    -> writes it (usp_Auth_Admin_ApplyControlCatalog)
"""
import collections, json, os, re, subprocess, sys, tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import map_endpoints as me   # shared: DB access, views, page resolution, callers

# ── standard controls: code -> (title, sort) ─────────────────────────────────
STANDARD = {
    "VIEW": ("Open page", 10), "ADD": ("Add", 20), "DETAILS": ("View details", 30), "EDIT": ("Edit", 40),
    "STATUS": ("Activate / Deactivate", 50), "DELETE": ("Delete", 60), "PRINT": ("Print", 70), "EXPORT": ("Export", 80),
    "IMPORT": ("Bulk upload", 85), "APPROVE": ("Approve", 90), "UNAUTHORIZE": ("Un-approve", 92), "CANCEL": ("Cancel", 94),
    "REFUND": ("Refund", 96), "SETTLE": ("Settle", 97), "DISCOUNT": ("Discount", 98),
    "BOOK_SLOT": ("Book slot", 20), "VALIDATE": ("Validate", 88),
}

# Controls that are not reached through an endpoint of their own (checked inside a save), or declared in code.
IN_ACTION = {
    ("LAB.LABREPORTING", "APPROVE"), ("LAB.LABIMAGEREPORTING", "APPROVE"),
    ("LAB.LABREPORTING", "VALIDATE"), ("LAB.LABIMAGEREPORTING", "VALIDATE"),   # a save with status Validated (3)
    ("LAB.MICROBIOLOGYREPORTING", "APPROVE"), ("LAB.MICROBIOLOGYREPORTING", "VALIDATE"),
    ("OPD.PATIENTREGISTRATION", "DISCOUNT"), ("OPD.SERVICEBOOKING", "DISCOUNT"), ("OPD.DASHBOARD", "DISCOUNT"),
    ("LAB.LABORDERBOOKING.B2CBOOKING", "DISCOUNT"), ("LAB.LABORDERBOOKING.B2BBOOKING", "DISCOUNT"),
    ("LAB.LABORDERBOOKING.B2CORDERLIST", "DISCOUNT"), ("LAB.LABORDERBOOKING.B2BREGISTRATION", "DISCOUNT"),
    ("OPD.DOCTORROSTER", "BOOK_SLOT"),       # a slot opens Patient Registration pre-filled; checked there
}

# ── curated groups: (page or "*", controller, action) -> (code, title) ──────
# Actions that belong together on a screen, and names the screen uses.
OVERRIDES = {
    # Doctor Master: the row's drop-down
    ("MASTER.DOCTORS", "Doctors", "AddConsultingFee"): ("CONSULTING_CHARGES", "Consulting Charges"),
    ("MASTER.DOCTORS", "Doctors", "RemoveConsultingFee"): ("CONSULTING_CHARGES", "Consulting Charges"),
    ("MASTER.DOCTORS", "Doctors", "UpdateGraceTime"): ("CONSULTING_CHARGES", "Consulting Charges"),
    ("MASTER.DOCTORS", "Doctors", "GetDoctorFees"): ("CONSULTING_CHARGES", "Consulting Charges"),
    ("MASTER.DOCTORS", "Doctors", "GetConsultingServices"): ("CONSULTING_CHARGES", "Consulting Charges"),
    ("MASTER.DOCTORS", "DoctorSchedules", "*"): ("CONFIGURE_SCHEDULER", "Configure Scheduler"),
    # payments / bills reached from many screens
    ("*", "OPD", "SavePayment"): ("COLLECT_PAYMENT", "Collect payment"),
    ("*", "OPD", "PrintBill"): ("PRINT", "Print"),
    ("*", "LabOrderBooking", "PrintBill"): ("PRINT", "Print"),
    ("MASTER.DOCTORS", "Doctors", "Create"): ("ADD", None),
    ("*", "Doctors", "Create"): ("ADD_DOCTOR", "Add doctor (quick)"),
    ("REPORTS.LABFRANCHISEWALLET", "LabOrderBooking", "FranchiseWalletStatement"): ("VIEW", None),
    ("*", "OPD", "CreateReferralDoctorQuick"): ("ADD_REFERRAL_DOCTOR", "Add referral doctor (quick)"),
    # booking / registration screens: the save is the screen's own work
    ("OPD.PATIENTREGISTRATION", "OPD", "PatientRegistration"): ("SAVE", "Register patient"),
    ("OPD.PATIENTREGISTRATION", "OPD", "SaveRegistrationWithPayment"): ("SAVE", "Register patient"),
    ("OPD.SERVICEBOOKING", "OPD", "NewServiceBooking"): ("SAVE", "New service booking"),
    ("LAB.LABORDERBOOKING.B2CBOOKING", "LabOrderBooking", "B2CBooking"): ("SAVE", "Save booking"),
    ("LAB.LABORDERBOOKING.B2CBOOKING", "LabOrderBooking", "SaveBookingWithPayment"): ("SAVE", "Save booking"),
    ("LAB.LABORDERBOOKING.B2BBOOKING", "LabOrderBooking", "B2BBooking"): ("SAVE", "Save booking"),
    ("LAB.LABORDERBOOKING.B2BBOOKING", "LabOrderBooking", "FranchiseWalletStatement"): ("VIEW", None),
    ("LAB.LABORDERBOOKING.B2BINVOICES", "LabOrderBooking", "GenerateInvoice"): ("GENERATE_INVOICE", "Generate invoice"),
    ("LAB.LABORDERBOOKING.B2BINVOICES", "LabOrderBooking", "B2BInvoiceDetail"): ("DETAILS", "View invoice"),
    ("LAB.LABORDERBOOKING.B2BSETTLEMENT", "LabOrderBooking", "B2BInvoiceDetail"): ("VIEW", None),
    # lab work screens
    ("LAB.LABREPORTING", "LabReporting", "Entry"): ("ENTRY", "Result entry"),
    ("LAB.LABREPORTING", "LabReporting", "SaveEntryJson"): ("ENTRY", "Result entry"),
    ("LAB.LABREPORTING", "LabReporting", "CalculateFormulasJson"): ("VIEW", None),
    ("LAB.LABREPORTING", "LabReporting", "UpdateSampleStatusJson"): ("SAMPLE_STATUS", "Reject / re-collect sample"),
    ("LAB.LABIMAGEREPORTING", "LabImageReporting", "Entry"): ("ENTRY", "Report entry"),
    ("LAB.LABIMAGEREPORTING", "LabImageReporting", "SaveReportJson"): ("ENTRY", "Report entry"),
    ("*", "LabReporting", "Entry"): ("VIEW", None),            # opening a report from another screen reads it
    ("*", "LabImageReporting", "Entry"): ("VIEW", None),
    ("LAB.MICROBIOLOGYREPORTING", "MicrobiologyReporting", "Entry"): ("ENTRY", "Report entry"),
    ("REPORTS.LABOUTSOURCED", "Reports", "MarkOutsourceSent"): ("OUTSOURCE_SEND", "Mark sent to outside lab"),
    ("REPORTS.LABOUTSOURCED", "Reports", "MarkOutsourceReceived"): ("OUTSOURCE_RESULT", "Record outside-lab result"),
    ("LAB.MICROBIOLOGYREPORTING", "MicrobiologyReporting", "SaveEntryJson"): ("ENTRY", "Report entry"),
    ("LAB.MICROBIOLOGYREPORTING", "MicrobiologyReporting", "CalculateFormulasJson"): ("VIEW", None),
    ("LAB.MICROBIOLOGYREPORTING", "MicrobiologyReporting", "UpdateSampleStatusJson"): ("SAMPLE_STATUS", "Reject / re-collect sample"),
    ("LAB.MICROBIOLOGYREPORTING", "MicrobiologyReporting", "PrintReportPdf"): ("PRINT", "Print"),
    ("LAB.MICROBIOLOGYREPORTING", "MicrobiologyReporting", "LogReportPrintedJson"): ("PRINT", "Print"),
    ("*", "MicrobiologyReporting", "Entry"): ("VIEW", None),
    ("*", "LabReporting", "LogReportPrintedJson"): ("PRINT", "Print"),
    ("LAB.SAMPLECOLLECTION", "SampleCollection", "CollectAllJson"): ("COLLECT", "Collect sample"),
    ("LAB.SAMPLECOLLECTION", "SampleCollection", "UpdateStatusJson"): ("COLLECT", "Collect sample"),
    ("LAB.SAMPLECOLLECTION", "SampleCollection", "UpdateProfileStatusJson"): ("COLLECT", "Collect sample"),
    ("LAB.SAMPLECOLLECTION", "SampleCollection", "ValidateFranchiseBarcodeJson"): ("VIEW", None),
    ("LAB.SAMPLETRANSFER", "SampleTransfer", "ExecuteTransferJson"): ("TRANSFER", "Transfer samples"),
    ("LAB.SAMPLETRANSFER", "SampleTransfer", "ExecuteReceiveJson"): ("RECEIVE", "Receive samples"),
    ("LAB.PATHOLOGISTDASHBOARD", "PathologistDashboard", "Approve"): ("VIEW", None),
    ("LAB.PATHOLOGISTDASHBOARD", "Users", "Signature"): ("VIEW", None),
    # OPD work screens
    ("OPD.DOCTORDASHBOARD", "OPD", "SavePatientConsultation"): ("CONSULTATION", "Save consultation"),
    ("OPD.DOCTORDASHBOARD", "OPD", "UpdateTokenStatus"): ("TOKEN_STATUS", "Update token status"),
    ("OPD.DOCTORDASHBOARD", "Vitals", "RecordVital"): ("RECORD_VITALS", "Record vitals"),
    ("OPD.DOCTORDASHBOARD", "Vitals", "History"): ("VIEW", None),
    ("OPD.TOKENMANAGEMENT", "OPD", "UpdateTokenStatus"): ("TOKEN_STATUS", "Update token status"),
    ("OPD.TOKENMANAGEMENT", "OPD", "MonitorDisplay"): ("MONITOR", "Monitor display"),
    ("OPD.VITALS", "Vitals", "RecordVital"): ("RECORD_VITALS", "Record new vitals"),
    ("OPD.VITALS", "Vitals", "History"): ("HISTORY", "View vital history"),
    ("OPD.VITALS", "Vitals", "PrintVital"): ("PRINT", "Print vitals"),
    ("OPD.DOCTORDISBURSAL", "DoctorDisbursal", "Calculate"): ("CALCULATE", "Calculate disbursal"),
    ("OPD.DOCTORDISBURSAL", "DoctorDisbursal", "AddAdjustment"): ("ADJUSTMENT", "Add adjustment"),
    ("OPD.DOCTORDISBURSAL", "DoctorDisbursal", "ProcessPayout"): ("PAYOUT", "Process payout"),
    ("OPD.DOCTORDISBURSAL", "DoctorDisbursal", "UpdateStatus"): ("PAYOUT", "Process payout"),
    ("MASTER.ROOMDOCTORASSIGNMENT", "RoomDoctorAssignment", "AssignDoctor"): ("ASSIGN", "Assign / unassign doctor"),
    ("MASTER.ROOMDOCTORASSIGNMENT", "RoomDoctorAssignment", "UnassignDoctor"): ("ASSIGN", "Assign / unassign doctor"),
    ("MASTER.LABFRANCHISEBARCODES", "LabFranchiseBarcodes", "GenerateSeries"): ("GENERATE", "Generate barcode series"),
    ("MASTER.LABFRANCHISEBARCODES", "LabFranchiseBarcodes", "PrintLabels"): ("PRINT", "Print labels"),
    ("MASTER.LABFRANCHISES", "LabFranchises", "ToggleSuspension"): ("SUSPEND", "Suspend / resume"),
    ("MASTER.LABDESCRIPTIVETESTTEMPLATES", "LabDescriptiveTestTemplates", "BatchCreate"): ("ADD", None),
    ("MASTER.LABDESCRIPTIVETESTTEMPLATES", "LabDescriptiveTestTemplates", "DeleteByTestId"): ("DELETE", None),
    ("MASTER.OPD", "OPD", "DeletePatient"): ("DELETE", "Delete patient"),
    ("MASTER.OPD", "OPD", "Details"): ("DETAILS", "View patient"),
    ("MASTER.INSURANCES", "Insurances", "GeneratePrefix"): ("VIEW", None),
    ("MASTER.DISCOUNTTYPES", "DiscountTypes", "VerifyName"): ("VIEW", None),
    ("MASTER.CORPORATES", "Corporates", "SaveCorporateRate"): ("RATES", "Rate rules"),
    ("MASTER.CORPORATES", "Corporates", "DeleteCorporateRate"): ("RATES", "Rate rules"),
    ("MASTER.CORPORATES", "Corporates", "ToggleRateStatus"): ("RATES", "Rate rules"),
    ("MASTER.INSURANCES", "Insurances", "SaveInsuranceTariff"): ("TARIFFS", "Tariff rules"),
    ("MASTER.INSURANCES", "Insurances", "DeleteInsuranceTariff"): ("TARIFFS", "Tariff rules"),
    ("MASTER.INSURANCES", "Insurances", "ToggleTariffStatus"): ("TARIFFS", "Tariff rules"),
    ("SETTINGS.HOSPITALSETTINGS", "HospitalSettings", "SaveSignatoriesJson"): ("SIGNATORIES", "Default signatories"),
    ("SETTINGS.SMTPCONFIG", "SmtpConfig", "SetDefault"): ("SET_DEFAULT", "Set default"),
    ("SETTINGS.SMTPCONFIG", "SmtpConfig", "TestEmail"): ("TEST", "Send test email"),
    ("SETTINGS.VIDEOCONFIG", "VideoConfig", "AddConfig"): ("ADD", None),
    ("SETTINGS.VIDEOCONFIG", "VideoConfig", "Save"): ("EDIT", None),
    ("SETTINGS.VIDEOCONFIG", "VideoConfig", "TestConnection"): ("TEST", "Test connection"),
    ("SETTINGS.VIDEOCONFIG", "OPD", "RetriggerVideoRoom"): ("RETRIGGER", "Re-create video room"),
    ("SETTINGS.WHATSAPPCONFIG", "WhatsAppConfig", "Save"): ("EDIT", None),
    ("SETTINGS.WHATSAPPCONFIG", "WhatsAppConfig", "CopyToBranch"): ("COPY_TO_BRANCH", "Copy to branch"),
    ("SETTINGS.WHATSAPPCONFIG", "WhatsAppConfig", "SendTestMessage"): ("TEST", "Send test message"),
    ("SETTINGS.ACCESS", "Access", "Assign"): ("ASSIGN", "Assign branches / roles"),
    ("SETTINGS.USERS", "Users", "Signature"): ("VIEW", None),
    ("*", "LabBulkUpload", "*"): ("IMPORT", "Bulk upload"),
    ("*", "SampleCollection", "PrintBarcode"): ("PRINT", "Print barcode"),
}

# Code-declared controls (Security screens carry [RequiresPermission]); never changed here.
CODE_DECLARED_PAGES = ("SETTINGS.SECURITY.",)

LOOKUP = re.compile(r"^(get|search|load|fetch|check|verify|lookup|find|preview|list|calculate|validate)", re.I)


def humanize(name):
    name = re.sub(r"Json$", "", name)
    words = re.sub(r"(?<=[a-z0-9])(?=[A-Z])", " ", name).split()
    return " ".join([words[0]] + [w.lower() for w in words[1:]]) if words else name


def snake(name):
    return re.sub(r"(?<=[a-z0-9])(?=[A-Z])", "_", re.sub(r"Json$", "", name)).upper()[:30]


def control_for(page, method, controller, action):
    pc, a = page["code"], action.lower()
    if method == "GET" and controller == page["controller"] and action == page["action"]:
        return ("VIEW", None)                             # opening the screen itself
    for key in ((pc, controller, action), (pc, controller, "*"), ("*", controller, action), ("*", controller, "*")):
        if key in OVERRIDES:
            return OVERRIDES[key]
    if controller == page["controller"] and action == page["action"]:
        return ("VIEW", None)
    if (method == "GET" and (LOOKUP.match(a) or a.endswith("json") or a == "index")) or (method != "GET" and LOOKUP.match(a)):
        return ("VIEW", None)
    if a.startswith("print") or "pdf" in a or "worksheet" in a: return ("PRINT", None)
    if a.startswith("export") or "excel" in a or "csv" in a: return ("EXPORT", None)
    if "unapprove" in a or "unauthori" in a: return ("UNAUTHORIZE", None)
    if "approve" in a: return ("APPROVE", None)
    if "refund" in a: return ("REFUND", None)
    if "cancel" in a: return ("CANCEL", None)
    if "settle" in a or "wallettopup" in a: return ("SETTLE", None)
    if "discount" in a: return ("DISCOUNT", None)
    own = controller == page["controller"]
    if not own:
        if a == "details": return ("VIEW", None)          # opening a related record
        return (snake(controller), "Manage " + humanize(controller).lower().replace("ot ", "OT "))   # a related screen managed from here
    if a.startswith("create") or a.startswith("add") or a.startswith("new"): return ("ADD", None)
    if a.startswith("edit") or a.startswith("update") or a == "save" or a.startswith("save"): return ("EDIT", None)
    if a == "details" or a.startswith("view"): return ("DETAILS", None)
    if a.startswith("delete") or a.startswith("remove"): return ("DELETE", None)
    if a.startswith("toggle") or a.startswith("activate") or a.startswith("deactivate") or a.startswith("setactive"): return ("STATUS", None)
    return (snake(action), humanize(action))


# ── labels from the screen ──────────────────────────────────────────────────
TAG_TEXT = re.compile(r"<[^>]+>|@\([^)]*\)|@[A-Za-z_.]+(\([^)]*\))?|&[a-z]+;|\s+")


def label_near(text, pos):
    """The visible text of the element that holds the reference at pos (a link, button or menu item)."""
    start = text.rfind("<", 0, pos)
    m = re.match(r"<(a|button|li)\b", text[start:start + 8])
    if not m:
        return None
    end = text.find("</" + m.group(1), pos)
    if end < 0 or end - pos > 600:
        return None
    inner = text[text.find(">", pos) + 1:end]
    label = TAG_TEXT.sub(" ", inner).strip()
    title = re.search(r'\btitle="([^"@]+)"', text[start:text.find(">", pos) + 1])
    label = label or (title.group(1) if title else "")
    return label if 2 < len(label) <= 40 and re.search(r"[A-Za-z]", label) else None


def evidence(page_code, controller, action):
    """(called from this page's screens?, a label found next to the call)"""
    found, label = False, None
    pats = [rf'Url\.Action\(\s*"{action}"\s*,\s*"{controller}"', rf"/{controller}/{action}\b",
            rf'asp-controller="{controller}"[^>]*asp-action="{action}"', rf'asp-action="{action}"[^>]*asp-controller="{controller}"']
    own = [rf'Url\.Action\(\s*"{action}"\s*[,)]', rf'asp-action="{action}"(?![^>]*asp-controller)', rf"['\"]{action}['\"?/]"]
    for v, t in me.files.items():
        is_own = v.startswith(f"Views/{controller}/")
        hits = [m for x in pats for m in re.finditer(x, t)] + ([m for x in own for m in re.finditer(x, t)] if is_own else [])
        if not hits or page_code not in me.pages_for_view(v):
            continue
        found = True
        for m in hits:
            label = label or label_near(t, m.start())
    return found, label


def build():
    rows = me.q("""SELECT m.Endpoint_ID, m.Http_Method, m.Controller, m.Action, p.Page_ID, p.Page_Code, p.Controller, p.Action
                   FROM dbo.PageEndpointMap m JOIN dbo.PageMaster p ON p.Page_ID = m.Page_ID
                   WHERE m.App = 'WEB' AND m.IsActive = 1 AND p.CompanyId = 1""")
    pages = {}
    for eid, meth, c, a, pid, pc, pctl, pact in rows:
        page = pages.setdefault(pc, dict(id=int(pid), code=pc, controller=pctl, action=pact, controls={}, placements=[]))
        if pc.startswith(CODE_DECLARED_PAGES):
            continue
        code, title = control_for(page, meth, c, a)
        ctl = page["controls"].setdefault(code, dict(code=code, title=title, endpoints=[], active=code == "VIEW"))
        ok, label = evidence(pc, c, a) if code != "VIEW" else (True, None)
        ctl["active"] = ctl["active"] or ok
        if not ctl["title"] and label and code == "ADD":
            ctl["title"] = label
        ctl["endpoints"].append(f"{meth} {c}/{a}" + ("" if ok else " (no button)"))
        page["placements"].append(dict(m=meth, ctl=c, act=a, c=code))
    for pc, code in IN_ACTION:
        if pc in pages:
            pages[pc]["controls"].setdefault(code, dict(code=code, title=None, endpoints=["(checked inside the save)"], active=True))
    for page in pages.values():
        for ctl in page["controls"].values():
            std = STANDARD.get(ctl["code"])
            ctl["title"] = ctl["title"] or (std[0] if std else humanize(ctl["code"].title().replace("_", "")))
            ctl["sort"] = std[1] if std else 75
    return pages


def main():
    pages = build()
    for pc in sorted(pages):
        p = pages[pc]
        if pc.startswith(CODE_DECLARED_PAGES):
            continue
        print(f"\n{pc}  [{p['controller']}/{p['action']}]")
        for ctl in sorted(p["controls"].values(), key=lambda c: (c["sort"], c["code"])):
            flag = "" if ctl["active"] else "   [inactive - no button on the screen]"
            eps = [e for e in ctl["endpoints"]] if ctl["code"] != "VIEW" else [f"{len(ctl['endpoints'])} endpoint(s)"]
            print(f"   {ctl['code']:<20} {ctl['title']:<34}{flag}  <- {', '.join(sorted(set(eps)))}")

    if "--apply" in sys.argv:
        payload = dict(
            controls=[dict(p=pc, c=c["code"], t=c["title"], s=c["sort"], a=1 if c["active"] else 0)
                      for pc, p in pages.items() if not pc.startswith(CODE_DECLARED_PAGES) for c in p["controls"].values()],
            placements=[dict(pc=pc, **x) for pc, p in pages.items() for x in p["placements"]],
            pages=[pc for pc in pages if not pc.startswith(CODE_DECLARED_PAGES)])
        # Kept as a migration too, so another database gets the same catalogue (after its endpoints are mapped).
        script = os.path.join(me.ROOT, "SQLScripts", "2171_authorization_page_control_catalog_data.sql")
        with open(script, "w") as f:
            f.write("-- ============================================================================\n"
                    "-- Migration: 2171_authorization_page_control_catalog_data.sql  (GENERATED - do not edit)\n"
                    "-- Generated by Tools/Authorization/page_controls.py --apply: the controls of every page and\n"
                    "-- which control each endpoint belongs to. Run after 2170 and after the endpoints are mapped.\n"
                    "-- ============================================================================\n"
                    "SET QUOTED_IDENTIFIER ON;\nSET ANSI_NULLS ON;\nGO\nEXEC dbo.usp_Auth_Admin_ApplyControlCatalog @Json = N'"
                    + json.dumps(payload, indent=0).replace("'", "''") + "';\nGO\n")
        r = subprocess.run(me.SQLCMD + ["-i", script], capture_output=True, text=True)
        print("\nAPPLIED:", (r.stdout + r.stderr).strip()[-600:])


if __name__ == "__main__":
    main()
