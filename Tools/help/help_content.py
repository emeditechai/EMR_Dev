"""
Utility > Help Center content (SQLScripts/2300_help_center.sql is generated from this file).

    python3 Tools/help/build_help_sql.py

Kinds:
  MODULE  - a module overview with its setup order (the pages that must be ready first)
  GUIDE   - a step-by-step guide for a task (prerequisites, steps, tips, next steps)
  FAQ     - a question and its answer
  TROUBLE - a problem, why it happens and how to fix it

pages:  page codes (PageMaster.Page_Code) the article explains - the in-page "?" help shows them
prereq: page codes that must be set up / done first ("Before you start")
next:   page codes that usually come next
Every page of the application also gets help built automatically from its menu path and its actions
(PageControlMaster), with the guides of its module, so no page is without help.
"""

MODULES = [
    # code, nav menu code(s), title, icon, summary, setup order [(page, why)]
    dict(code="GENERAL", menus=["HOME"], title="Getting Started", icon="bi-rocket-takeoff",
         summary="Signing in, choosing a branch and role, finding your way, notifications and your account.",
         setup=[]),
    dict(code="SETTINGS", menus=["SETTINGS", "SETTINGS.SECURITY"], title="Settings & Security", icon="bi-gear",
         summary="Company, branches, users, roles and permissions, hospital settings, email / WhatsApp and the licence. Set these up first.",
         setup=[("SETTINGS.COMPANIES", "Your organisation (company) details"),
                ("SETTINGS.BRANCHES", "Every branch / centre; one is the Head Office"),
                ("SETTINGS.HOSPITALSETTINGS", "Name, address, logo and the rules of each branch (billing, LAB, printing, AI)"),
                ("SETTINGS.SMTPCONFIG", "Mail settings of each branch: bills, reports and password emails go out with them"),
                ("SETTINGS.USERS", "Staff accounts, the branches they work in, Lab Technician / Pathologist flags"),
                ("SETTINGS.SECURITY.ROLEPERMISSIONS", "What each role may open and do"),
                ("SETTINGS.APPROVALMATRIX", "Who approves discounts and master changes"),
                ("SETTINGS.LABAPPROVALFLOWS", "Pathologist sign-off levels for LAB reports")]),
    dict(code="MASTER", menus=["MASTER.GENERAL", "MASTER.OPD_MASTER", "MASTER.LAB_MASTER", "MASTER.IPD_MASTER", "MASTER.PHARMACY_MASTER"],
         title="Masters", icon="bi-database", summary="The lists everything else is built on: departments, doctors, services, tests, rates, places.",
         setup=[("MASTER.DEPARTMENTS", "Departments (OPD, LAB, IPD, ...)"),
                ("MASTER.COUNTRIES", "Country, state, district, city, area - used in addresses"),
                ("MASTER.DOCTORSPECIALITIES", "Doctor specialities"),
                ("MASTER.DOCTORS", "Doctors (consulting) and their charges"),
                ("MASTER.REFERRALDOCTORS", "Referral doctors who send patients"),
                ("MASTER.CORPORATES", "Corporates / partners who are billed (B2B)"),
                ("MASTER.DISCOUNTTYPES", "Discount types allowed at billing"),
                ("MASTER.MEMBERSHIPPLANS", "Membership plans, then issue Membership Cards")]),
    dict(code="OPD", menus=["OPD"], title="OPD", icon="bi-person-vcard",
         summary="Patient registration, doctor rosters, appointments and service billing, tokens, vitals, consultation and day closing.",
         setup=[("MASTER.DOCTORS", "Doctors with consultation fees"),
                ("MASTER.SERVICES", "OPD services and their charges"),
                ("MASTER.DOCTORROOMS", "Consultation rooms"),
                ("MASTER.ROOMDOCTORASSIGNMENT", "Which doctor sits in which room"),
                ("OPD.DOCTORROSTER", "Doctor schedules and slots"),
                ("MASTER.EMRINVESTIGATIONS", "Investigations doctors can advise"),
                ("MASTER.EMRMEDICATIONS", "Medicines doctors can prescribe"),
                ("UTILITY.EMAILTEMPLATE", "Booking and prescription emails")]),
    dict(code="LAB", menus=["LAB", "LAB.LAB_ORDER_BOOKING_REGISTRATION"], title="LAB", icon="bi-droplet",
         summary="Booking (B2C / B2B), sample collection and transfer, result entry, validation and approval, dispatch, cancellation and day closing.",
         setup=[("MASTER.LABTESTCATEGORIES", "Test categories, then sub categories"),
                ("MASTER.LABSAMPLETYPES", "Sample types and containers"),
                ("MASTER.LAB_MASTER.LABUNITS", "Units of measure"),
                ("MASTER.LABTESTMETHODS", "Test methods"),
                ("MASTER.LABINVESTIGATIONS", "Every test (investigation) with department, category, sample, unit, TAT"),
                ("MASTER.LABINVESTIGATIONPROFILES", "Profiles and packages made of tests"),
                ("MASTER.LABREFERENCERANGES", "Normal ranges by gender and age"),
                ("MASTER.LABRATELISTB2C", "Walk-in prices (B2C rate list)"),
                ("MASTER.LABFRANCHISES", "Franchises / collection centres (B2B), with their rate lists"),
                ("SETTINGS.USERS", "Mark Lab Technicians and Pathologists; give department access"),
                ("SETTINGS.LABAPPROVALFLOWS", "Pathologist approval levels")]),
    dict(code="IPD", menus=["IPD"], title="IPD", icon="bi-hospital",
         summary="In-patient admissions with beds, wards, tariffs, procedures and packages.",
         setup=[("MASTER.WARDS", "Wards and nursing stations"), ("MASTER.ROOMS", "Rooms"), ("MASTER.BEDCATEGORIES", "Bed categories"),
                ("MASTER.BEDS", "Beds"), ("MASTER.TARIFFCATEGORIES", "Tariff categories"), ("MASTER.BEDROOMTARIFFS", "Bed / room tariffs"),
                ("MASTER.HOSPITALSERVICES", "Hospital services and rates"), ("MASTER.PROCEDURES", "Procedures and tariffs"),
                ("MASTER.HOSPITALPACKAGES", "Hospital packages")]),
    dict(code="QUALITY", menus=["QUALITY.BOM", "QUALITY.EQUIPMENT", "QUALITY.IQC", "QUALITY.MASTERS"], title="Quality & Compliance", icon="bi-patch-check",
         summary="Internal QC with Levey-Jennings charts, EQAS, equipment, CAPA and the bill of material (cost) of tests.",
         setup=[("QC.MASTER.ITEMS", "Consumable items"), ("QC.MASTER.SUPPLIERS", "Suppliers"), ("QC.MASTER.STORES", "Stores / locations"),
                ("QC.EQUIPMENT", "Equipment (analyzers) register"), ("QC.IQC.SETUP", "QC materials, lots and targets"),
                ("QC.BOM.TEST", "What each test consumes (BOM)")]),
    dict(code="REPORTS", menus=["REPORTS", "REPORTS.LAB", "REPORTS.OPD", "REPORTS.FINANCE_DOCTOR_SETTLEMENT", "REPORTS.ACCOUNTS_MENU"],
         title="Reports", icon="bi-bar-chart", summary="Billing, collection, dues, discounts, cancellations, workload, TAT, quality, doctor settlement and MIS reports.",
         setup=[]),
    dict(code="UTILITY", menus=["UTILITY", "UTILITY.ACCOUNTS"], title="Utility", icon="bi-tools",
         summary="Audit and email logs, email templates, campaigns, approvals, franchise top-up, patient portal, petty cash and accounts.",
         setup=[("SETTINGS.SMTPCONFIG", "Mail settings (for templates and campaigns)"),
                ("UTILITY.EMAILTEMPLATE", "Email templates"),
                ("UTILITY.ACCOUNTS.SETTINGS", "Accounts settings before petty cash and vouchers"),
                ("UTILITY.ACCOUNTS.LEDGERS", "Bank ledgers (one per real bank account) under Bank Accounts"),
                ("UTILITY.ACCOUNTS.OPENING", "Opening balances of each branch on the go-live date")]),
]

ARTICLES = []

def guide(code, module, title, summary, steps, pages=(), prereq=(), tips=(), next=(), keywords=""):
    ARTICLES.append(dict(code=code, kind="GUIDE", module=module, title=title, summary=summary, steps=list(steps),
                         pages=list(pages), prereq=list(prereq), tips=list(tips), next=list(next), keywords=keywords))

def faq(code, module, question, answer, steps=(), pages=(), keywords=""):
    ARTICLES.append(dict(code=code, kind="FAQ", module=module, title=question, summary=answer, steps=list(steps),
                         pages=list(pages), prereq=[], tips=[], next=[], keywords=keywords))

def trouble(code, module, problem, why, fixes, pages=(), keywords=""):
    ARTICLES.append(dict(code=code, kind="TROUBLE", module=module, title=problem, summary=why, steps=list(fixes),
                         pages=list(pages), prereq=[], tips=[], next=[], keywords=keywords))

# ════════════════════════════════ GETTING STARTED ════════════════════════════════
guide("GS.SIGNIN", "GENERAL", "Sign in, choose your branch and role",
      "How to sign in and start working in the right branch with the right role.",
      ["Open the application and enter your Email and Password, then click Sign In (or press Enter). You sign in with your e-mail address, not a user name.",
       "If you work in more than one branch, choose the branch and press Enter or click Continue to Dashboard. Your last used branch is pre-selected.",
       "If you have more than one role, choose the role (arrow keys move between roles) and press Enter. The left side shows what the role can open.",
       "The Home page opens. The top bar shows the menus your role may use, the notification bell, your branch and your profile."],
      pages=["HOME.DASHBOARD"],
      tips=["Tick Remember me only on your own computer.",
            "You can switch branch or role any time from your profile menu (top right) without signing out.",
            "Too many wrong passwords lock the account for a while - wait, or use Forgot password?"],
      next=["HOME.DASHBOARD"], keywords="login log in sign in signin branch role select switch start dashboard")

guide("GS.FORGOT", "GENERAL", "Forgot your password? Reset it by email",
      "Get a reset link by email and set a new password without calling the administrator.",
      ["On the sign-in screen click Forgot password?.",
       "Enter your user name or the email address on your account and click Send Reset Link.",
       "Open the email 'eCare360Plus+ - Reset your password' and click Reset Password (the link works once, for 30 minutes).",
       "Type a new password twice (at least 8 characters, with a letter and a number) and click Reset Password.",
       "Sign in with the new password. You also get an email saying the password was changed."],
      tips=["No email? Check Spam / Junk. Your user account must have an email address - ask the administrator to add it in User Master.",
            "Asking for a new link cancels the earlier ones."],
      keywords="forgot password reset link email change password locked")

guide("GS.CHANGEPWD", "GENERAL", "Change your password",
      "Change the password of your own account.",
      ["Open your profile menu (your name, top right) and choose Change Password.",
       "Enter the current password, then the new password twice (8+ characters with a letter and a number).",
       "Click Save. Use the new password from your next sign-in."],
      keywords="change password profile security")

guide("GS.NAVIGATE", "GENERAL", "Find your way around",
      "The top menus, the notification bell, help on every page and switching branch or role.",
      ["The top bar holds the menus: Home, OPD, LAB, IPD, Master, Settings, Utility, Quality & Compliance and Reports. You only see what your role may open.",
       "Point at a menu to open it; menus with an arrow open a sub-menu (near the right edge it opens to the left).",
       "The bell shows notifications such as approval requests. New ones ring the bell, show a message and play a tone (turn the sound on/off with the speaker button inside the bell).",
       "Ask AI at the bottom right of Home, or Utility > Help Center, opens the AI Help Assistant - ask what to do next.",
       "Your profile menu (top right) has Change Password, Switch Branch, Switch Role and Sign Out."],
      tips=["The branch badge (e.g. HO) shows which branch you are working in - bills and reports belong to it."],
      keywords="menu navigation bell notification help question tone sound switch branch role")

# ════════════════════════════════ SETTINGS ════════════════════════════════
guide("SET.BRANCH", "SETTINGS", "Set up a new branch",
      "Add a branch (centre) so it can bill, collect samples and report.",
      ["Settings > Branch Master: click Add, enter the branch name, code, address and contact; mark exactly one branch as Head Office.",
       "Settings > Hospital Settings: choose the branch and fill the hospital name, address, logo, contact and the LAB / billing / printing options.",
       "Settings > Email Configuration: add the branch's mail account (SMTP) and send a test email.",
       "Settings > User Master: give users access to the new branch (branch mapping) and the roles they work in.",
       "Masters: check rate lists and doctors apply to the branch."],
      pages=["SETTINGS.BRANCHES", "SETTINGS.HOSPITALSETTINGS"], prereq=["SETTINGS.COMPANIES"],
      next=["SETTINGS.SMTPCONFIG", "SETTINGS.USERS"], keywords="branch centre new branch head office HO setup")

guide("SET.USER", "SETTINGS", "Create a user and give access",
      "Add a staff member, map branches and roles, and set special flags.",
      ["Settings > User Master: click Add User; enter the e-mail first - it is the sign-in, must be unique in the whole application and is checked as you type (green = available); the user name is the e-mail. Then name and phone.",
       "Choose the branches the user works in and the role(s) in each branch.",
       "For LAB staff tick Lab Technician or Pathologist and choose the departments they may report (Department Access). Without this, Lab Reporting is not available to them.",
       "Save. The user signs in with the default password and changes it.",
       "If the user cannot open a page, check the role in Settings > Security > Role Permissions, or the user's own extra permissions."],
      pages=["SETTINGS.USERS"], prereq=["SETTINGS.BRANCHES"],
      next=["SETTINGS.SECURITY.ROLEPERMISSIONS", "SETTINGS.SECURITY.EFFECTIVEPERMISSIONS"],
      keywords="user staff add user create account login access role department pathologist technician")

guide("SET.PERMISSIONS", "SETTINGS", "Give a role access to pages and actions",
      "Decide which pages a role may open and which actions (add, edit, approve, print...) it may use.",
      ["Settings > Security > Role Permissions: choose the role.",
       "Tick the pages the role may open; inside a page tick the actions it may use (for example Approve, Print, Cancel).",
       "Save. Users of the role see the change at their next page load (menus refresh within a few minutes).",
       "To check one person, open Settings > Security > Effective Permissions and choose the user: it shows what they can really do and why."],
      pages=["SETTINGS.SECURITY.ROLEPERMISSIONS", "SETTINGS.SECURITY.USERPERMISSIONS", "SETTINGS.SECURITY.EFFECTIVEPERMISSIONS", "SETTINGS.SECURITY.MENUPAGES"],
      prereq=["SETTINGS.USERS"],
      tips=["New screens are added without access for any role - give them to the right roles here.",
            "User Permissions add or remove a page for one user on top of the role."],
      keywords="permission role access rights menu missing page denied security grant")

guide("SET.SMTP", "SETTINGS", "Set up email for a branch",
      "Bills, reports, password resets and campaigns are emailed with the branch's mail account.",
      ["Settings > Email Configuration: click Add and choose the branch.",
       "Enter the SMTP host, port, SSL, sender email / display name, user name and password from your email provider.",
       "Enter the Application Base URL (the address users open the application with) - links in emails use it.",
       "Mark it Default and Active, save, then use Test Email to send yourself a message.",
       "Check Utility > Email Logs if an email did not arrive."],
      pages=["SETTINGS.SMTPCONFIG"], prereq=["SETTINGS.BRANCHES"], next=["UTILITY.EMAILLOGS", "UTILITY.EMAILTEMPLATE"],
      tips=["Password-reset emails always use the Head Office branch's mail settings.",
            "Gmail / Office 365 often need an 'app password' instead of the normal password."],
      keywords="email smtp mail configuration test email gmail outlook base url")

guide("SET.HOSPITAL", "SETTINGS", "Hospital Settings: the rules of a branch",
      "Name and logo on prints, billing and LAB options, approvals, printing and AI features.",
      ["Settings > Hospital Settings: open the branch.",
       "General: hospital name, address, phone, email, website and logo (printed on bills and reports).",
       "LAB: email / WhatsApp report delivery, pathologist approval required, bill print page size (A4 or A5 landscape) and other LAB rules.",
       "AI: Enable AI Features at Billing (Smart ID Scan, document check and test suggestions).",
       "Save. The changes apply to that branch at once."],
      pages=["SETTINGS.HOSPITALSETTINGS"], prereq=["SETTINGS.BRANCHES"],
      keywords="hospital settings logo print a4 a5 page size ai features pathologist approval report email whatsapp")

guide("SET.APPROVALS", "SETTINGS", "Approvals: discounts and master changes",
      "Decide who must approve discounts and changes to masters, and handle the requests.",
      ["Settings > Approval Matrix: for each type (for example discount above a limit) choose the approver role / user and the limits.",
       "When a request needs approval the approver gets a notification (bell) and finds it in Utility > Approval Dashboard.",
       "The approver opens the request, checks it and clicks Approve or Reject with a remark.",
       "The person who asked is notified of the decision."],
      pages=["SETTINGS.APPROVALMATRIX", "UTILITY.APPROVALDASHBOARD"],
      keywords="approval matrix discount approve reject request notification approver")

guide("SET.LABFLOW", "SETTINGS", "Pathologist approval flow (report sign-off levels)",
      "Set how many pathologists must sign a LAB report and who they are.",
      ["Settings > Pathologist Approval Flow: choose the branch / department.",
       "Add the levels (for example Level 1 Senior Technician, Level 2 Pathologist) and the users for each level.",
       "Hospital Settings > LAB: switch on Pathologist approval required if reports must be signed from the Report Approval Dashboard.",
       "Pathologists then approve from LAB > Report Approval Dashboard."],
      pages=["SETTINGS.LABAPPROVALFLOWS"], next=["LAB.PATHOLOGISTDASHBOARD"],
      keywords="pathologist approval flow levels sign off signatory")

guide("SET.LICENCE", "SETTINGS", "Licence",
      "See the licence of this server and re-check it with the licence server.",
      ["Settings > Licence shows the licence, its validity and the registered server.",
       "If the sign-in screen asks to re-validate, click Re-validate licence with the licence server and follow the OTP step if shown."],
      pages=["SETTINGS.LICENSE"], keywords="licence license expired validate otp renewal")

# ════════════════════════════════ MASTERS ════════════════════════════════
guide("MAS.DOCTOR", "MASTER", "Add a doctor",
      "Add consulting doctors (and referral doctors) used in OPD, LAB referrals and commissions.",
      ["Master > General > Doctor Speciality Master: make sure the speciality exists.",
       "Master > General > Doctor Master: click Add; enter name, prefix (Dr.), gender, speciality, registration (licence) number, phone and email.",
       "Set consultation charges and the branches the doctor works in, then save.",
       "For OPD: assign a room (Room Doctor Assignment) and create the roster (OPD > Doctor Roster).",
       "Referral doctors who send patients are added in Referral Doctor Master."],
      pages=["MASTER.DOCTORS", "MASTER.REFERRALDOCTORS", "MASTER.DOCTORSPECIALITIES"], prereq=["MASTER.DOCTORSPECIALITIES"],
      next=["MASTER.ROOMDOCTORASSIGNMENT", "OPD.DOCTORROSTER"], keywords="doctor add doctor consultant speciality referral fee")

guide("MAS.TEST", "MASTER", "Add a LAB test (investigation)",
      "Create a test with everything reporting and billing need.",
      ["Make sure the masters it uses exist: Department, Test Category / Sub Category, Sample Type, Unit and Method.",
       "Master > Lab Master > Investigation Master: click Add; enter code, name, department, category, sub category, sample type, unit, method and TAT (hours).",
       "Choose the reporting type (numeric, text / picklist, descriptive template, culture...).",
       "Save, then add normal ranges in Reference Range Master (by gender and age).",
       "Add the price in Rate List (B2C) - and in franchise / corporate rate lists for B2B.",
       "Optional: add it to a profile or package (Investigation Profile Master), a formula (Lab Formula Component) or a reflex rule."],
      pages=["MASTER.LABINVESTIGATIONS", "MASTER.LABREFERENCERANGES"],
      prereq=["MASTER.LABTESTCATEGORIES", "MASTER.LABSAMPLETYPES", "MASTER.LAB_MASTER.LABUNITS", "MASTER.LABTESTMETHODS"],
      next=["MASTER.LABRATELISTB2C", "MASTER.LABINVESTIGATIONPROFILES"],
      keywords="test investigation add test new test reference range normal range unit sample type tat")

guide("MAS.PROFILE", "MASTER", "Create a profile or package",
      "Group tests that are booked together (Lipid Profile, health packages).",
      ["Master > Lab Master > Investigation Profile Master: click Add.",
       "Choose the type (profile or package), enter code, name and price, and add the tests in the order they print.",
       "Save. Add the profile / package price in the rate lists.",
       "At booking, choosing the profile adds all its tests; reports print them together."],
      pages=["MASTER.LABINVESTIGATIONPROFILES"], prereq=["MASTER.LABINVESTIGATIONS"], next=["MASTER.LABRATELISTB2C"],
      keywords="profile package panel group tests lipid health check")

guide("MAS.RATELIST", "MASTER", "Prices: B2C, franchise and corporate rate lists",
      "Set what walk-in patients, franchises and corporates pay for each test.",
      ["Master > Lab Master > Rate List (B2C): set the price of each test / profile / package for walk-in patients and whether a discount is allowed.",
       "Rate List (Franchise): the price a franchise / collection centre pays (B2B).",
       "Rate List (Corporate): the price a corporate pays.",
       "Changes may need approval (Approval Matrix). Bills made after the change use the new price."],
      pages=["MASTER.LABRATELISTB2C", "MASTER.LABRATELISTFRANCHISE", "MASTER.LABRATELISTCORPORATE"], prereq=["MASTER.LABINVESTIGATIONS"],
      keywords="price rate list mrp b2c b2b franchise corporate discount allowed")

guide("MAS.REFLEX", "MASTER", "Reflex rules (suggest a follow-up test)",
      "When a result meets a condition, Lab Reporting suggests a follow-up test to the pathologist.",
      ["Master > Lab Master > Reflex Rules. Standard rules are added switched off - review and switch on the ones you use.",
       "To add a rule: choose the result test, the condition (greater than, between, flagged high, contains text...), the value and the test to suggest; add the reason.",
       "Save. Suggestions show on Lab Reporting Entry when AI features are on; the pathologist advises or dismisses them."],
      pages=["MASTER.LABREFLEXRULES"], prereq=["MASTER.LABINVESTIGATIONS"], next=["LAB.LABREPORTING"],
      keywords="reflex rule follow up test suggestion advise")

guide("MAS.MEMBERSHIP", "MASTER", "Membership plans and cards",
      "Sell membership cards with benefits and points.",
      ["Master > General > Membership Plan Master: create the plan (price, validity, discount / points rules, family members).",
       "Master > General > Membership Cards: issue a card - search the patient by phone (an existing patient is filled in), add family members and collect payment.",
       "Send the card by email / WhatsApp. At billing the card's discount applies and points can be redeemed with an OTP."],
      pages=["MASTER.MEMBERSHIPPLANS", "MASTER.MEMBERSHIPCARDS"], keywords="membership card plan points family redeem otp")

# ════════════════════════════════ OPD ════════════════════════════════
guide("OPD.REGISTER", "OPD", "Register a new patient",
      "Create the patient record (patient ID) used by OPD, LAB and IPD.",
      ["OPD > Patient Registration: search by phone first - the patient may already exist.",
       "Enter name, gender, date of birth (or age), phone, email and address; add an ID document if needed.",
       "Save. The patient gets a Patient ID (e.g. PHO2627000053) used everywhere.",
       "Continue to Service Booking to book a consultation, or to LAB booking for tests."],
      pages=["OPD.PATIENTREGISTRATION", "MASTER.OPD"], next=["OPD.SERVICEBOOKING", "LAB.LABORDERBOOKING.B2CBOOKING"],
      tips=["Always search by phone before registering to avoid duplicates. Family members can share a phone."],
      keywords="register patient new patient registration uhid patient id duplicate")

guide("OPD.BOOK", "OPD", "Book a consultation or service and bill it",
      "Book the doctor / service, take payment and give a token.",
      ["OPD > Service Booking: find the patient (or register a new one).",
       "Choose the doctor, date and slot (from the doctor's roster) and the service; the fee is filled in.",
       "Apply a discount if allowed (above the limit it needs approval) and collect payment (cash, card, UPI...).",
       "Save and print the bill. The patient gets a token and, if email is set up, a booking confirmation email."],
      pages=["OPD.SERVICEBOOKING"], prereq=["OPD.PATIENTREGISTRATION", "OPD.DOCTORROSTER", "MASTER.SERVICES"],
      next=["OPD.TOKENMANAGEMENT", "OPD.VITALS"], keywords="appointment booking consultation opd bill token service slot fee")

guide("OPD.ROSTER", "OPD", "Doctor roster (schedules and slots)",
      "Set when each doctor sits, so appointments can be booked.",
      ["OPD > Doctor Roster: choose the doctor.",
       "Add the days and times, slot length and maximum patients; save.",
       "Leaves / holidays block booking for those days."],
      pages=["OPD.DOCTORROSTER"], prereq=["MASTER.DOCTORS"], next=["OPD.SERVICEBOOKING"],
      keywords="roster schedule slot doctor timing availability")

guide("OPD.FLOW", "OPD", "Patient flow on the day: token, vitals, consultation",
      "Move the patient from the waiting area to the doctor and out with a prescription.",
      ["OPD > Token Management: call the next token; the patient goes to vitals.",
       "OPD > Patient Vitals: record BP, pulse, temperature, weight, SpO2...",
       "OPD > Doctor Dashboard: the doctor opens the patient, writes complaints, diagnosis, advises investigations and prescribes medicines, sets follow-up.",
       "Finish the consultation; the prescription can be printed and emailed (Prescription Delivery template)."],
      pages=["OPD.TOKENMANAGEMENT", "OPD.VITALS", "OPD.DOCTORDASHBOARD", "OPD.DASHBOARD"], prereq=["OPD.SERVICEBOOKING"],
      keywords="token queue vitals consultation doctor dashboard prescription emr follow up")

guide("OPD.CLOSE", "OPD", "OPD day closing",
      "Close the day's cash and get it verified.",
      ["OPD > OPD Day Closing: check the day's collection by payment mode against the cash in hand and submit.",
       "A supervisor verifies it in OPD > OPD Day Closing Verification.",
       "Use Reports > OPD > OPD Cashier Day-end Closing for the detail."],
      pages=["OPD.DAYCLOSING", "OPD.DAYCLOSINGVERIFY"], keywords="day closing cash collection verify cashier end of day")

guide("OPD.CANCEL", "OPD", "Cancel an OPD bill or refund",
      "Cancel a bill fully or partly and refund the patient.",
      ["OPD > Bill Cancellation & Refund: find the bill.",
       "Choose full or partial cancellation, the reason and the refund mode; it may need approval.",
       "Save; the cancellation note can be printed. It shows in the cancellation reports."],
      pages=["OPD.BILLCANCELLATION.OPD"], keywords="cancel bill refund opd cancellation")

guide("OPD.DUE", "OPD", "Collect a due payment on an OPD bill",
      "Take the balance of an OPD bill that was saved unpaid or part-paid.",
      ["OPD > OPD Dashboard: choose the date and click the Payment due filter.",
       "Click the action menu (three dots) of the bill and choose Collect payment.",
       "Enter the amount received and the payment mode, then save; print the receipt."],
      pages=["OPD.DASHBOARD"], prereq=["OPD.SERVICEBOOKING"],
      keywords="opd due payment collect due balance pending unpaid consultation bill partial payment receipt")

guide("OPD.COMMISSION", "OPD", "Doctor commission and disbursal",
      "Pay doctors their share of OPD earnings.",
      ["Set up the doctor's share in Master > OPD Master > Doctor Commission Config.",
       "OPD > Doctor Commission & Disbursals: choose the doctor and period, review the earned amount, and record the payout.",
       "See Reports > Finance / Doctor Settlement and Reports > OPD (Doctor Share, Payout, TDS) for the statements."],
      pages=["OPD.DOCTORDISBURSAL", "MASTER.DOCTORCOMMISSIONCONFIGS"], keywords="doctor commission share payout disbursal tds settlement")

# ════════════════════════════════ LAB ════════════════════════════════
guide("LAB.B2C", "LAB", "Book tests for a walk-in patient (B2C billing)",
      "Find or register the patient, add tests, take payment and print the bill.",
      ["LAB > LAB Order Booking > B2C Booking / Registration: search the patient by phone or ID - or register a new one on the same page (Smart ID Scan can read an Aadhaar / PAN / passport photo when AI is on).",
       "Choose the referring doctor and collection type (walk-in or home collection).",
       "Add tests, profiles or packages by name or code. AI suggestions may offer a cheaper package or often-ordered tests.",
       "Add misc charges if any (home collection...), apply a discount (may need approval) or redeem membership points.",
       "Collect payment and save. Print the bill (A4 or A5 as set in Hospital Settings); the patient can get it by email / WhatsApp."],
      pages=["LAB.LABORDERBOOKING.B2CBOOKING", "LAB.LABORDERBOOKING.B2CORDERLIST"],
      prereq=["MASTER.LABINVESTIGATIONS", "MASTER.LABRATELISTB2C"], next=["LAB.SAMPLECOLLECTION"],
      tips=["Uploading an Aadhaar / passport lets the system check the name, age and gender on save.",
            "B2C Order List shows the bills to reprint or open; a balance is collected there too (see 'Collect a due')."],
      keywords="b2c booking lab billing bill tests walk in patient package discount payment print smart id scan")

guide("LAB.B2B", "LAB", "Book tests for a franchise or corporate (B2B)",
      "Bill tests on the partner's rates and account.",
      ["LAB > LAB Order Booking > B2B Lab Billing & Booking: choose the partner (franchise / collection centre or corporate).",
       "Find or add the patient, add tests - prices come from the partner's rate list.",
       "Save. The amount goes to the partner's account (franchise wallet or credit).",
       "B2B Order List, B2B Invoices and B2B Multi-Bill Settlement handle invoicing and payments."],
      pages=["LAB.LABORDERBOOKING.B2BBOOKING", "LAB.LABORDERBOOKING.B2BREGISTRATION", "LAB.LABORDERBOOKING.B2BINVOICES", "LAB.LABORDERBOOKING.B2BSETTLEMENT"],
      prereq=["MASTER.LABFRANCHISES", "MASTER.LABRATELISTFRANCHISE", "MASTER.CORPORATES"], next=["LAB.SAMPLECOLLECTION"],
      tips=["A franchise needs balance in its wallet - top up in Utility > Franchise Top-Up."],
      keywords="b2b franchise corporate partner billing invoice settlement wallet credit")

guide("LAB.COLLECT", "LAB", "Collect samples and print barcodes",
      "Mark samples collected so they reach the lab for reporting.",
      ["LAB > Sample Collection Management: find the bill (today's pending list or search).",
       "For each container print the barcode label and stick it on the tube.",
       "Click Collect (one sample, a profile, or all) - the collection time is recorded.",
       "If a sample is unsuitable choose Reject / Re-collect with a reason.",
       "Collected samples now appear in Lab Reporting Entry (or go to Sample Transfer if another branch tests them)."],
      pages=["LAB.SAMPLECOLLECTION"], prereq=["LAB.LABORDERBOOKING.B2CBOOKING"], next=["LAB.LABREPORTING", "LAB.SAMPLETRANSFER"],
      keywords="sample collection collect barcode label tube reject recollect phlebotomy")

guide("LAB.TRANSFER", "LAB", "Send samples to another branch",
      "Transfer samples to the branch that runs the test, and receive them there.",
      ["LAB > Sample Transfer: choose the collected samples and the target branch, then Transfer.",
       "At the target branch open Sample Transfer, find the incoming samples and Receive them.",
       "Received samples appear in the target branch's Lab Reporting."],
      pages=["LAB.SAMPLETRANSFER"], prereq=["LAB.SAMPLECOLLECTION"], next=["LAB.LABREPORTING"],
      keywords="sample transfer send receive branch outsource")

guide("LAB.REPORT", "LAB", "Enter, validate and approve results",
      "Report the tests of a bill from entry to final approval.",
      ["LAB > Lab Reporting Entry: filter by date (Sample Collection DateTime by default), department or search, then click Report Entry on the bill.",
       "Type the results. The flag (H / L / Critical) shows at once; 'Previous' shows the last result and the graph icon opens the last 5 results with a trend.",
       "Add remarks if needed and click Submit.",
       "A senior validates (Validate) and the pathologist approves (Approve) - or approves from the Report Approval Dashboard when pathologist approval is required.",
       "A Critical / Panic result needs the communication recorded (who was informed) before sign-off.",
       "Approved reports can be printed and are emailed / sent by WhatsApp if switched on."],
      pages=["LAB.LABREPORTING", "LAB.LABIMAGEREPORTING", "LAB.MICROBIOLOGYREPORTING"],
      prereq=["LAB.SAMPLECOLLECTION", "SETTINGS.USERS", "MASTER.LABREFERENCERANGES"], next=["LAB.PATHOLOGISTDASHBOARD", "LAB.LABREPORTDISPATCH"],
      tips=["The i icon on a bill opens its Audit History with the workflow from booking to delivery.",
            "Only users marked Lab Technician or Pathologist (or Administrators) can open reporting."],
      keywords="report entry result validate approve submit lab reporting critical flag delta previous trend image microbiology")

guide("LAB.APPROVE", "LAB", "Approve reports as a pathologist",
      "Sign off reports from the Report Approval Dashboard.",
      ["LAB > Report Approval Dashboard lists reports waiting for your level.",
       "Open a report, check the results, flags, previous values and remarks.",
       "Approve (or send back). With several levels, the report goes to the next level until the last one signs.",
       "Record critical value communication if asked."],
      pages=["LAB.PATHOLOGISTDASHBOARD"], prereq=["SETTINGS.LABAPPROVALFLOWS"], next=["LAB.LABREPORTDISPATCH"],
      keywords="pathologist approve sign off dashboard level authorize")

guide("LAB.UNAPPROVE", "LAB", "Correct an approved report (Re-Test / Re-Collect)",
      "Withdraw approval to correct a result or to draw a new sample.",
      ["LAB > Un-Authorize Report: find the bill and choose the tests.",
       "Choose Re-Test (results go back for correction) or Re-Collect (a new sample is needed), and enter the reason.",
       "Correct and approve again (Re-Test) or collect the new sample and report it (Re-Collect).",
       "Send the revised report; the Audit History shows the rework."],
      pages=["LAB.LABUNAPPROVE"], next=["LAB.LABREPORTING", "LAB.LABREPORTDISPATCH"],
      keywords="unapprove unauthorize re-test retest re-collect recollect correct amend revised report")

guide("LAB.DISPATCH", "LAB", "Deliver reports (print, email, WhatsApp)",
      "Hand over or send approved reports.",
      ["LAB > Lab Report Dispatch: search the bill / patient.",
       "Print the report, or send it by email / WhatsApp (needs the patient's email / phone and the branch settings).",
       "The dispatch is recorded; a revised report is marked as revised."],
      pages=["LAB.LABREPORTDISPATCH"], prereq=["LAB.LABREPORTING"], keywords="dispatch deliver print report email whatsapp send")

guide("LAB.CANCEL", "LAB", "Cancel a LAB bill or refund",
      "Cancel all or some tests and refund.",
      ["LAB > Bill Cancellation & Refund: find the bill.",
       "Choose full or partial cancellation, the tests, the reason and the refund mode; it may need approval.",
       "Save. Cancelled tests leave the work lists."],
      pages=["LAB.BILLCANCELLATION.LAB"], keywords="cancel lab bill refund partial cancellation")

guide("LAB.DUE", "LAB", "Collect a due (balance) payment on an existing LAB bill",
      "Take the remaining amount of a B2C bill that was saved unpaid or part-paid, and give the money receipt.",
      ["LAB > LAB Order Booking / Registration > B2C Order List.",
       "Find the bill: search by bill no, token, patient name or phone, and set Payment Status to Full Due or Partial Due (the due amount shows in red under the bill amount). Widen the dates for an older bill.",
       "Click the action menu (three dots) of the bill and choose Collect Payment - or open the bill and click Collect Payment at the bottom.",
       "The payment screen shows the bill amount, what was paid and the balance due. Enter the amount received (all or part of the due) with the payment mode (cash, card, UPI...).",
       "Save. A money receipt (A5) is offered for printing; the bill's balance and payment status update at once."],
      pages=["LAB.LABORDERBOOKING.B2CORDERLIST"], prereq=["LAB.LABORDERBOOKING.B2CBOOKING"], next=["LAB.LABREPORTDISPATCH", "LAB.DAYCLOSING"],
      tips=["The collected amount counts in the day's collection of the person who takes it (Day Closing, Collection Register).",
            "Reports > LAB > Outstanding Dues lists every bill with a balance.",
            "A discount at due collection is possible only when the bill has no discount yet (one discount per bill); above the limit it needs approval."],
      keywords="due payment collect due take due receive balance pending amount outstanding unpaid part paid partial payment existing bill old bill money receipt settle bill pay balance lab bill")

guide("LAB.B2BPAY", "LAB", "Collect payment on B2B bills (franchise / corporate)",
      "Take a partner's payment on one B2B bill or settle many bills at once.",
      ["One bill: LAB > LAB Order Booking / Registration > B2B Order List - find the bill and use Collect payment.",
       "Many bills: B2B Multi-Bill Settlement - choose the partner, tick the bills (or the period), enter the amount and payment mode and Settle.",
       "Print the settlement / receipt. Invoices for the period are in B2B Invoices."],
      pages=["LAB.LABORDERBOOKING.B2BREGISTRATION", "LAB.LABORDERBOOKING.B2BSETTLEMENT", "LAB.LABORDERBOOKING.B2BINVOICES"],
      prereq=["LAB.LABORDERBOOKING.B2BBOOKING"],
      keywords="b2b payment partner payment franchise corporate due collect settle settlement multi bill outstanding credit")

guide("LAB.REPRINT", "LAB", "Reprint a LAB bill, money receipt or report",
      "Print a bill or an approved report again.",
      ["LAB > LAB Order Booking / Registration > B2C Order List (B2B Order List for partners): find the bill.",
       "Action menu (three dots) > Print Bill - or Print Lab Report when tests are approved.",
       "Reports can also be printed or sent again from LAB > Lab Report Dispatch."],
      pages=["LAB.LABORDERBOOKING.B2CORDERLIST", "LAB.LABREPORTDISPATCH"],
      keywords="reprint print again duplicate bill copy report print receipt print bill again")

guide("LAB.CLOSE", "LAB", "LAB day closing",
      "Close the day's LAB collection and get it verified.",
      ["LAB > LAB Day Closing: compare the day's collection by payment mode with the cash and submit.",
       "A supervisor verifies it in LAB Day Closing Verification.",
       "Reports > LAB > Cashier Day-end Closing gives the detail."],
      pages=["LAB.DAYCLOSING", "LAB.DAYCLOSINGVERIFY"], keywords="lab day closing cash verify cashier")

guide("LAB.AI", "LAB", "AI features at billing and reporting",
      "Smart ID Scan, document check, test suggestions and reflex suggestions.",
      ["Switch on in Settings > Hospital Settings > Enable AI Features at Billing (per branch).",
       "Smart ID Scan: upload a photo / PDF of Aadhaar, PAN or passport in B2C / B2B booking; name, age, gender and address are filled in.",
       "Document check: on save, the details are compared with the uploaded Aadhaar / passport and differences are shown to confirm.",
       "Test suggestions: while adding tests, cheaper packages and tests often ordered together are suggested.",
       "Reflex suggestions: in Lab Reporting, follow-up tests suggested by Reflex Rules."],
      pages=["SETTINGS.HOSPITALSETTINGS"], keywords="ai artificial intelligence smart id scan aadhaar pan ocr suggestion package reflex")

# ════════════════════════════════ QUALITY ════════════════════════════════
guide("QC.IQC", "QUALITY", "Daily internal QC (IQC) and Levey-Jennings charts",
      "Run QC, enter results and watch the charts.",
      ["Quality & Compliance > Internal QC > QC Materials, Lots & Targets: set the control material, lot, level, mean and SD for each test / analyzer.",
       "Daily QC Entry: enter the QC results of the run; Westgard rule violations are flagged.",
       "Levey-Jennings Charts: see the trend and act on shifts or outliers (record a CAPA if needed)."],
      pages=["QC.IQC.SETUP", "QC.IQC.ENTRY", "QC.IQC.CHART"], prereq=["QC.EQUIPMENT"], next=["QC.CAPA"],
      keywords="iqc quality control westgard levey jennings lj chart lot target mean sd")

guide("QC.EQAS", "QUALITY", "EQAS, equipment and CAPA",
      "External quality schemes, the equipment register and corrective actions.",
      ["Equipment Register: add each analyzer / instrument with calibration and maintenance schedules.",
       "EQAS Programmes & Results: record the scheme, the samples and your results against the peer group.",
       "CAPA Register: record a problem, its root cause, the corrective and preventive action and close it."],
      pages=["QC.EQUIPMENT", "QC.EQAS", "QC.CAPA"], keywords="eqas external quality equipment calibration maintenance capa corrective preventive")

guide("QC.BOM", "QUALITY", "Bill of material and test cost",
      "Know what each test consumes and costs.",
      ["Quality & Compliance > Masters: add items, suppliers and stores.",
       "Bill of Material > Test BOM: list the items (reagents, consumables) each test uses and the quantity.",
       "Sample Collection Kit: the kit used per sample.",
       "BOM Cost Preview and Reports > LAB (Test Cost Sheet, Price vs Cost, Margin Alert) show cost and margin."],
      pages=["QC.BOM.TEST", "QC.BOM.SAMPLEKIT", "QC.BOM.COSTPREVIEW"], prereq=["QC.MASTER.ITEMS"],
      keywords="bom bill of material cost reagent consumable margin kit")

# ════════════════════════════════ REPORTS ════════════════════════════════
guide("REP.USE", "REPORTS", "Use any report: filters, export and print",
      "All reports work the same way.",
      ["Open the report from the Reports menu (LAB, OPD, Finance / Doctor Settlement, Accounts).",
       "Choose the period (Today, 7 Days, This Month, Last Month or your dates) and the filters; click Apply / Show Report.",
       "Switch between Summary and Detail tabs; click a row or chart to drill down.",
       "Export with Excel or PDF; Print where offered."],
      keywords="report filter export excel pdf print date range summary detail mis")

guide("REP.WORKLOAD", "REPORTS", "Testwise Workload report",
      "Per test: patients, bills, status of samples and reports, turnaround and abnormal results.",
      ["Reports > LAB > Testwise Workload: choose the bill dates; Head Office can choose a branch.",
       "Filter by department, test category / sub category, tests (profiles count as one test) and B2C / B2B.",
       "Tabs: Workload Summary, Test-wise Patient Count and Patient-wise Details (click a test to drill down).",
       "Export Excel (all three) or PDF (the tab you are on)."],
      pages=["REPORTS.LABTESTWISEWORKLOAD"], keywords="workload testwise test wise patient count tat volume")

guide("REP.DAILY", "REPORTS", "Daily billing, collection and dues",
      "Check what was billed, what was collected and what is still due.",
      ["Reports > LAB > Daily Billing Register (or OPD Daily Billing Register): every bill of the period.",
       "Daily Collection Register: money collected by mode and cashier.",
       "Outstanding Dues & Ageing: unpaid balances by age.",
       "Discount Register and Cancellation & Refund Register: discounts given (with reason and approver) and cancellations."],
      pages=["REPORTS.LABBILLINGREGISTER", "REPORTS.LABB2CCOLLECTIONREGISTER", "REPORTS.LABOUTSTANDINGDUES", "REPORTS.LABDISCOUNTREGISTER",
             "REPORTS.OPDBILLINGREGISTER", "REPORTS.DAILYCOLLECTION", "REPORTS.OPDOUTSTANDINGDUES"],
      keywords="billing register collection dues outstanding ageing discount cancellation refund daily")

# ════════════════════════════════ UTILITY ════════════════════════════════
guide("UT.TEMPLATES", "UTILITY", "Change the wording of system emails (Email Templates)",
      "Edit the booking and prescription emails in a designer - no HTML needed.",
      ["Utility > Email Templates: click Edit / Preview on an email.",
       "Change the subject, heading, message (purple chips are patient details filled in automatically), the details box, note and closing.",
       "The preview on the right shows the email exactly as the patient gets it; Send test emails it to you.",
       "Save. A missing template means that email is not sent - add it from the list page."],
      pages=["UTILITY.EMAILTEMPLATE"], prereq=["SETTINGS.SMTPCONFIG"],
      keywords="email template wording booking confirmation prescription designer preview")

guide("UT.CAMPAIGN", "UTILITY", "Send an email to all (or chosen) patients, users or doctors - Campaigns",
      "Email many people (or a few chosen ones) at once.",
      ["Utility > Campaigns > New Campaign.",
       "1 Campaign: name it and choose Send from (the branch whose mail account sends it).",
       "2 Recipients: Patients, Users or Doctors; then Everyone, A filtered group (branch, gender, age, visit dates, role, speciality) or Choose people. The box shows how many will get it.",
       "3 Message: start from a template or write it; Insert field adds the person's name etc. Check the preview and Send test to yourself.",
       "4 Send now or Schedule for a time. Watch the results page: sent, waiting, failed (with reason) and skipped; cancel or retry failed."],
      pages=["UTILITY.CAMPAIGNS"], prereq=["SETTINGS.SMTPCONFIG"],
      tips=["Patients can unsubscribe with the link in the email; they are skipped from then on.",
            "Save messages you send often as Templates (Templates tab)."],
      keywords="campaign bulk send email patients everyone mass mailing newsletter health camp promotion staff schedule")

guide("UT.AUDIT", "UTILITY", "Audit log and email log",
      "See who did what, and whether emails went out.",
      ["Utility > Audit Log: filter by date, user, module or text to see actions (sign-in, billing, approvals, changes).",
       "Utility > Email Logs: every email sent or failed, with the reason for failures.",
       "On a LAB bill, the i icon shows its own audit history and workflow."],
      pages=["UTILITY.AUDITLOGS", "UTILITY.EMAILLOGS"], keywords="audit log history who changed email log failed sent")

guide("UT.FRANCHISE", "UTILITY", "Franchise wallet top-up and dashboard",
      "Add money to a franchise's wallet and watch its business.",
      ["Utility > Franchise Top-Up: choose the franchise, enter the amount and payment details, save (may need approval).",
       "Utility > Franchise Dashboard: bookings, wallet balance and dues of each franchise.",
       "Reports > LAB > Franchise Wallet Statement: every credit and debit."],
      pages=["UTILITY.FRANCHISETOPUP", "UTILITY.FRANCHISEDASHBOARD"], prereq=["MASTER.LABFRANCHISES"],
      keywords="franchise wallet top up recharge balance dashboard")

guide("UT.PORTAL", "UTILITY", "Patient portal login",
      "Give a patient access to the patient portal.",
      ["Utility > Patient Login: find the patient (must have an email).",
       "Generate the login; the patient gets the user name and password by email.",
       "The patient signs in to see bookings and reports and should change the password."],
      pages=["UTILITY.PATIENTPORTAL.LOGIN"], keywords="patient portal login credentials app")

guide("UT.PETTY", "UTILITY", "Petty cash and vouchers",
      "Record small expenses and close petty cash.",
      ["Utility > Accounts > Accounts Settings, Expense Heads, Payees and Ledgers: set up once.",
       "Petty Cash Counters: the counters that hold cash.",
       "Petty Expenses: record each expense with head, payee, amount and bill.",
       "Petty Cash Closing: close the counter's day; Voucher Entry for accounting vouchers."],
      pages=["UTILITY.ACCOUNTS.PETTYEXPENSE", "UTILITY.ACCOUNTS.COUNTERS", "UTILITY.ACCOUNTS.CLOSING", "UTILITY.ACCOUNTS.VOUCHERS",
             "UTILITY.ACCOUNTS.LEDGERS", "UTILITY.ACCOUNTS.EXPENSEHEADS", "UTILITY.ACCOUNTS.PAYEES", "UTILITY.ACCOUNTS.SETTINGS"],
      prereq=["UTILITY.ACCOUNTS.SETTINGS"], keywords="petty cash expense voucher ledger accounts payee closing")

guide("ACC.SETUP", "UTILITY", "Set up Accounts: bank ledgers and payment mode ledgers",
      "Decide which cash or bank ledger each payment method (Cash, Card, UPI, NEFT, Cheque, Wallet) posts to - once, from the head office.",
      ["Utility > Accounts > Ledgers and Groups: create one ledger for each real bank account (e.g. \"HDFC Current A/c\") under the group Bank Accounts. "
       "For card / UPI money that reaches the bank a day later you may also create a clearing ledger (e.g. \"Card / UPI Clearing\") under Bank Accounts.",
       "Utility > Accounts > Accounts Settings > Payment Mode Ledgers: for every payment method choose the ledger in the column All branches "
       "(Cash -> Cash Account, Card / UPI -> your bank or clearing ledger, NEFT / Cheque -> your bank).",
       "If a branch banks elsewhere, choose its own ledger in that branch's column; leave \"Same as all branches\" otherwise.",
       "Click Save Payment Mode Ledgers. Every new receipt, refund, B2B settlement, franchise wallet top-up and membership card payment posts to the chosen ledger.",
       "Check the next day in Reports > Accounts > Cash Book / Bank Book that the money is in the right book."],
      pages=["UTILITY.ACCOUNTS.SETTINGS", "UTILITY.ACCOUNTS.LEDGERS"], prereq=["UTILITY.ACCOUNTS.SETTINGS"], next=["UTILITY.ACCOUNTS.OPENING"],
      tips=["Only the head office can change the mapping; branches see it read-only.",
            "Entries already posted keep their ledger - the mapping applies from the next entry.",
            "Cash deposited into the bank: Voucher Entry > Contra (Dr the bank ledger, Cr Cash Account)."],
      keywords="payment mode ledger bank account cash upi card neft cheque mapping bank book cash book contra deposit clearing")

guide("ACC.OPENING", "UTILITY", "Enter opening balances (go-live)",
      "Bring the balances of the day the books start here - cash, bank, receivables, payables, capital - branch by branch.",
      ["Utility > Accounts > Opening Balances. The head office chooses the branch; a branch user sees only its own.",
       "Set Opening as of: the first day of the financial year, or the go-live date.",
       "Enter each balance on its side: assets (cash, bank, receivables, advances) usually under Debit; liabilities and capital (payables, loans, capital) under Credit. Leave the rest blank.",
       "Watch Difference at the bottom: it should read Balanced. Then click Save Opening Balances.",
       "The balances are posted as one Opening Balance voucher (OPN/...); the Trial Balance, Ledger Statement, Cash Book and Bank Book start from them."],
      pages=["UTILITY.ACCOUNTS.OPENING"], prereq=["UTILITY.ACCOUNTS.LEDGERS", "UTILITY.ACCOUNTS.SETTINGS"], next=["REPORTS.ACCOUNTS"],
      tips=["Saving again replaces the branch's opening entry: the old one is cancelled (kept for audit), never deleted.",
            "If debits and credits differ, the difference is held in \"Opening Balance Difference\" (Capital Account) and the screen warns you - correct it before closing the first month.",
            "Income and expense ledgers always start at zero - they are not on this screen.",
            "A branch whose books are locked on or after the opening date cannot take the entry: unlock it first in Accounts Settings."],
      keywords="opening balance go live start books brought forward capital difference first day financial year")

guide("ACC.RECON", "REPORTS", "Reconcile bills with the ledger (Bill Reconciliation)",
      "Make sure what the books say patients owe is exactly what the bills say - and fix what was missed.",
      ["Reports > Accounts > Bill Reconciliation. The head office can pick a branch or see all.",
       "Look at the Patient Receivable card: \"agrees\" means the books and the bills match. \"differs by\" shows the gap.",
       "Can be repaired lists bills whose entries are missing or wrong - a bill, receipt, refund or cancellation that was not posted, "
       "a B2B bill posted twice, or an entry left behind by a deleted bill.",
       "Click Repair. Missing entries are posted on their own date; wrong ones are reversed by a new entry. Nothing is edited or deleted, and running it again changes nothing.",
       "Needs a person to check lists bills the repair does not touch: a bill without a payment record (collect it or cancel the bill) and a bill whose payment rows do not add up to its Total Paid (stray or test rows - check the bill).",
       "Open any bill from the list (the bill number opens its print) to check it."],
      pages=["REPORTS.ACCOUNTS"], next=["REPORTS.ACCOUNTS"],
      tips=["Run it at least once a month, before locking the books.",
            "Patient credit: money kept after a cancellation or an over-payment is shown as a credit the patient is owed - refund it from the bill.",
            "Repair needs the Repair permission on Reports > Accounts (Settings > Security > Role Permissions)."],
      keywords="reconciliation reconcile receivable ledger mismatch difference repair missing posting duplicate patient receivable books bills")

guide("ACC.MONTHEND", "REPORTS", "Month-end: check and close the books",
      "The checks to run before a month is final, then lock it.",
      ["Reports > Accounts > Bill Reconciliation: Patient Receivable agrees with the bills (Repair what can be repaired).",
       "Reports > Accounts > Ledger Posting Audit for the month: no document left unposted.",
       "Reports > Accounts > Cash Book and Bank Book: closing balances match the counted cash and the bank statement.",
       "Reports > Accounts > Trial Balance: debits equal credits and no unbalanced voucher is reported.",
       "Utility > Accounts > Accounts Settings > Books Lock: lock each branch up to the last day of the month."],
      pages=["REPORTS.ACCOUNTS", "UTILITY.ACCOUNTS.SETTINGS"], prereq=["UTILITY.ACCOUNTS.OPENING"],
      tips=["A locked branch takes no voucher, petty expense or closing dated on or before the lock date; billing is never stopped.",
            "Voucher numbers restart every financial year: RCT/HO/26-27/00001, then RCT/HO/27-28/00001."],
      keywords="month end closing lock books trial balance cash book bank book reconcile audit period close")

guide("SET.LOGINRETRY", "SETTINGS", "Lock accounts after wrong passwords and unlock a user",
      "Set how many wrong passwords are allowed before an account is locked for 10 minutes, and unlock a user early.",
      ["Settings > Hospital Settings > OPD Configuration > Login Retry Count: 0 (default) means no lock; any number from 1 to 20 is the wrong passwords allowed.",
       "After each wrong password the user sees how many attempts are left. When they run out, the account is locked for 10 minutes.",
       "To unlock early: Settings > User Master, filter Status = Locked (the count is shown in the filter). A locked user has a \"Locked till\" badge.",
       "Click the unlock button on the user's row, confirm the user's identity, enter the reason and click Unlock. The user can sign in at once; the reason is kept in the audit log."],
      pages=["SETTINGS.HOSPITALSETTINGS", "SETTINGS.USERS"],
      tips=["A user in several branches gets the strictest count of those branches; a user without a branch (Super Admin) gets the head office's.",
            "Unlock needs its own permission (User Master > Unlock) - give it only to administrators.",
            "Unlock does not change an Inactive user - activate the user in User Master for that."],
      keywords="login retry wrong password attempts lock lockout unlock locked user security brute force")

guide("AI.DATA", "GENERAL", "Ask AI: find a bill, open screens and see today's numbers",
      "Ask AI also answers from live data - only what your role may see, only in your branch.",
      ["Type a bill number (LAB/HO2627000295 or just HO2627000295): the bill card shows the patient, amount, paid, due, samples and reports, with buttons for the bill's screens.",
       "Add what you want to open: \"... open bill\", \"... lab reporting entry\", \"... print report\", \"... sample collection\", \"... barcode\". "
       "That screen opens at once (Report Entry opens the right one for the bill's tests: Lab, Image or Microbiology).",
       "A token (\"token LAB-HO-0003\"), a phone number or a Patient ID finds the bill or patient.",
       "Numbers of a period: \"today's collection\", \"opd revenue this month\", \"how many bills last month\", \"pending dues\", \"pending samples today\", \"reports pending approval\".",
       "How-to questions (\"how do I collect a due\") still get the help guides."],
      pages=["HOME.DASHBOARD"],
      tips=["Spelling mistakes are understood (\"colection yesturday\").",
            "Every night Ask AI learns the answers several users chose for the same question; administrators see it in Help Insights."],
      keywords="ask ai data bill number open bill report entry sample collection barcode collection revenue dues today token patient search")

# ════════════════════════════════ FAQ ════════════════════════════════
faq("FAQ.MENU.MISSING", "GENERAL", "Why can't I see a menu or page?",
    "Menus show only the pages your role may open. Ask your administrator to give the page to your role in Settings > Security > Role Permissions (or to you in User Permissions). Lab Reporting also needs the Lab Technician or Pathologist tick in User Master.",
    pages=["SETTINGS.SECURITY.ROLEPERMISSIONS"], keywords="menu missing page not visible access denied permission")
faq("FAQ.SWITCH.BRANCH", "GENERAL", "How do I work in another branch?",
    "Open your profile menu (top right) and choose Switch Branch, pick the branch and continue. Bills and reports you make belong to the branch shown in the HO / branch badge.",
    keywords="switch branch change branch another centre")
faq("FAQ.SESSION", "GENERAL", "Why was I signed out?",
    "For safety you are signed out after a period without activity, or when the browser tab session ends. Sign in again; unsaved work on the page is lost, so save often.",
    keywords="logout signed out session timeout idle")
faq("FAQ.LOCKED", "GENERAL", "My account is locked. What do I do?",
    "When your branch has a Login Retry Count, that many wrong passwords lock the account for 10 minutes - the message shows when you can try again. "
    "Wait, reset the password with Forgot password?, or ask an administrator to unlock you in User Master (filter Status = Locked).",
    pages=["SETTINGS.USERS", "SETTINGS.HOSPITALSETTINGS"], keywords="locked account wrong password attempts lockout unlock retry")
faq("FAQ.ACC.VOUCHERNO", "UTILITY", "How are voucher numbers formed?",
    "Type / branch / financial year / number - e.g. RCT/HO/26-27/00042 is the 42nd Receipt of Head Office in 2026-27. "
    "SLS = sales (bills), RCT = receipts and refunds, CN = discounts, cancellations and reversals, PMT / CTR / JRN = manual payment, contra and journal, "
    "PCV = petty cash, OPN = opening balances. Every entry has its own number; it restarts each financial year. "
    "Entries made before October 2026 were renumbered this way; their old number (VCH-...) is kept with them.",
    pages=["REPORTS.ACCOUNTS"], keywords="voucher number numbering format prefix financial year rct sls cn vch")
faq("FAQ.TOKEN.SEQ", "OPD", "Why do OPD and LAB tokens have their own numbers?",
    "Each kind of bill has its own daily token sequence per branch: OPD (HO-0001), B2C LAB (LAB-HO-0001) and B2B LAB (B2B-LAB-HO-0001). "
    "An OPD bill never uses up a LAB token number, so each sequence runs without gaps; all restart at 0001 every day.",
    pages=["OPD.SERVICEBOOKING", "LAB.LABORDERBOOKING.B2CBOOKING"], keywords="token number gap sequence opd lab b2b skip missing")
faq("FAQ.ACC.RECEIVABLE", "UTILITY", "Why does Patient Receivable not match the dues report?",
    "The ledger counts every patient's balance, including credits (money kept after a cancellation or over-payment), while the dues report shows only amounts owed. "
    "Reports > Accounts > Bill Reconciliation explains every difference bill by bill and repairs missing or duplicate entries.",
    pages=["REPORTS.ACCOUNTS"], keywords="patient receivable mismatch dues ledger difference credit reconciliation")

faq("FAQ.PASSWORD.RULES", "GENERAL", "What are the password rules?",
    "At least 8 characters with at least one letter and one number. Choose one you do not use elsewhere.",
    keywords="password rules length strong")
faq("FAQ.TONE", "GENERAL", "How do I turn the notification sound on or off?",
    "Click the bell, then the speaker button at the top of the panel. It is remembered for that browser. Browsers play sound only after you have clicked on the page once.",
    keywords="notification sound tone mute bell")
faq("FAQ.A5", "LAB", "How do I print LAB bills on half a page (A5)?",
    "Settings > Hospital Settings > LAB > Printing: set LAB Bill Print Page Size to A5 landscape. Bills of that branch then print on half an A4 sheet.",
    pages=["SETTINGS.HOSPITALSETTINGS"], keywords="a5 half page bill print size landscape")
faq("FAQ.DISCOUNT.APPROVAL", "LAB", "Why does my discount need approval?",
    "Discounts above the limit set in Settings > Approval Matrix need an approver. The approver gets a notification and approves in Utility > Approval Dashboard; then the bill can be completed. One discount is allowed per bill.",
    pages=["SETTINGS.APPROVALMATRIX", "UTILITY.APPROVALDASHBOARD"], keywords="discount approval limit approver")
faq("FAQ.DUE.DISCOUNT", "LAB", "Can I give a discount while collecting a due?",
    "Yes, if the bill has no discount yet - a bill gets one discount only. Apply it on the payment screen when you collect the due; above your limit it needs approval. If the bill already has a discount, or a membership benefit was applied, the discount is locked.",
    pages=["LAB.LABORDERBOOKING.B2CORDERLIST", "SETTINGS.APPROVALMATRIX"], keywords="discount at due collection due discount second discount locked")
faq("FAQ.DUE.LIST", "LAB", "Where do I see all bills with a balance due?",
    "In LAB > B2C Order List set Payment Status to Full Due or Partial Due; Reports > LAB > Outstanding Dues lists every bill with a balance for any period.",
    pages=["LAB.LABORDERBOOKING.B2CORDERLIST", "REPORTS.LABOUTSTANDINGDUES"], keywords="due list outstanding pending payment bills balance unpaid report")
faq("FAQ.PACKAGE.SUGGEST", "LAB", "Why did the system suggest a package?",
    "With AI features on, test suggestions compare the tests you added with packages that contain them at a lower price. Click Switch to use the package; your tests are replaced by it.",
    keywords="package suggestion cheaper ai switch")
faq("FAQ.MEMBERSHIP.POINTS", "LAB", "How do I redeem membership points at billing?",
    "Choose the patient with an active card, click Redeem points, enter the points; an OTP goes to the card holder's phone / email. Enter it to apply the value to the bill.",
    keywords="membership points redeem otp card")
faq("FAQ.REPORT.EMAIL", "LAB", "How do reports reach patients by email or WhatsApp?",
    "Switch on report email / WhatsApp in Hospital Settings (LAB) and set up Email / WhatsApp Configuration for the branch. When a bill's reports are approved they are sent automatically; you can also send from Lab Report Dispatch.",
    pages=["LAB.LABREPORTDISPATCH", "SETTINGS.HOSPITALSETTINGS"], keywords="report email whatsapp send patient automatic")
faq("FAQ.PROFILE.COUNT", "REPORTS", "In Testwise Workload, why is a profile counted as one test?",
    "A profile booked on a bill is one test of the Investigation Master (for example Lipid Profile Total). Its status shows the stage all its tests reached. A package counts as the profiles and tests in it.",
    pages=["REPORTS.LABTESTWISEWORKLOAD"], keywords="profile count one test workload")
faq("FAQ.CRITICAL", "LAB", "What is critical value communication?",
    "A Critical or Panic result must be told to the doctor / patient quickly. Before the report is signed, record who was informed, how and when (Record critical value communication). The Critical & Panic Value Register lists them.",
    pages=["LAB.LABREPORTING", "REPORTS.LABCRITICAL"], keywords="critical panic value communication inform doctor")
faq("FAQ.DELTA", "LAB", "What does 'Previous' and the graph icon show in result entry?",
    "Previous is the patient's last result of the same test (delta check). The graph icon opens the last 5 results with dates and a trend graph, with the normal range shaded.",
    pages=["LAB.LABREPORTING"], keywords="previous delta check trend graph history last results")
faq("FAQ.WORKFLOW", "LAB", "How can I see where a LAB bill stands?",
    "Click the i icon on the bill in Lab Reporting (and other LAB lists). Audit History shows the workflow from booking to delivery - each stage done, in progress or pending, with rework such as Re-Test or Re-Collect - and every recorded activity.",
    pages=["LAB.LABREPORTING"], keywords="status workflow audit history track bill stage")
faq("FAQ.CAMPAIGN.SKIP", "UTILITY", "Why were some campaign recipients skipped?",
    "People without an email address, patients who unsubscribed, and people sharing an email with another recipient (sent once) are skipped. The results page shows the reason for each.",
    pages=["UTILITY.CAMPAIGNS"], keywords="campaign skipped not sent unsubscribed no email")
faq("FAQ.TEMPLATE.FIELDS", "UTILITY", "What are the purple chips in the email designer?",
    "They are fields - the patient's name, the doctor, the date, the hospital name and so on. They are filled in for each person when the email is sent. Insert them with Insert field.",
    pages=["UTILITY.EMAILTEMPLATE", "UTILITY.CAMPAIGNS"], keywords="field chip placeholder merge name email designer")
faq("FAQ.EXPORT", "REPORTS", "Can I export reports to Excel or PDF?",
    "Yes - use the Excel and PDF buttons on the report. Some reports build the files on the server with all rows even when the screen shows only the first part.",
    keywords="export excel pdf download report")
faq("FAQ.HO.BRANCH", "REPORTS", "Why do I only see my branch in reports?",
    "Reports show the branch you are working in. Head Office users can choose another branch or all branches where the report offers it.",
    keywords="report branch all branches head office")
faq("FAQ.DUPLICATE.PATIENT", "OPD", "How do I avoid duplicate patients?",
    "Always search by phone (and name) before registering. Family members may share a phone - pick the right person from the list. Membership card issue fills in an existing patient when you choose the phone.",
    keywords="duplicate patient search phone family")
faq("FAQ.OPD.EMAIL", "OPD", "Why did the patient not get the booking or prescription email?",
    "The patient needs an email address, the branch needs Email Configuration, and the template (Booking Confirmation / Prescription Delivery) must exist and be active for the branch in Utility > Email Templates. Check Utility > Email Logs for the reason.",
    pages=["UTILITY.EMAILTEMPLATE", "UTILITY.EMAILLOGS"], keywords="booking email prescription email not received opd")
faq("FAQ.APPROVAL.WHERE", "UTILITY", "Where do I approve requests?",
    "Utility > Approval Dashboard lists requests waiting for you (discounts, master changes, top-ups...). The bell also notifies you; click the notification to open it.",
    pages=["UTILITY.APPROVALDASHBOARD"], keywords="approve request pending approval dashboard")
faq("FAQ.IQC.WESTGARD", "QUALITY", "What do the Westgard flags in Daily QC mean?",
    "They are rules that detect errors in QC results (for example 1-3s: one value beyond 3 SD; 2-2s: two in a row beyond 2 SD). A rejection rule means: do not report patient results of that run until the cause is fixed; record a CAPA.",
    pages=["QC.IQC.ENTRY"], keywords="westgard rule 1-3s 2-2s qc reject warning")
faq("FAQ.HELP.ASK", "GENERAL", "How do I ask the Help Assistant?",
    "Click Ask AI at the bottom right of Home, or open Utility > Help Center, and type your question in plain words - for example 'how do I cancel a bill' or 'after creating a B2C bill, what is next?'. It answers with steps, the screens to open and where the step sits in the workflow; tell it whether the answer helped.",
    keywords="help assistant ask question ai")

# ════════════════════════════════ TROUBLESHOOTING ════════════════════════════════
trouble("TS.SAMPLE.NOT.IN.REPORTING", "LAB", "A sample does not appear in Lab Reporting Entry",
        "Reporting lists only collected, in-house samples of the dates and departments you can see.",
        ["Check the sample is Collected in Sample Collection (pending or rejected samples are not listed).",
         "The date filter is Sample Collection DateTime by default - widen the dates or switch Filter by date to Booking Date.",
         "Check the department / category filters and your Department Access in User Master.",
         "If the sample was transferred, it shows at the receiving branch after Receive.",
         "Outsourced tests are not reported here."],
        pages=["LAB.LABREPORTING", "LAB.SAMPLECOLLECTION"], keywords="sample missing not showing lab reporting not visible")
trouble("TS.REPORTING.DENIED", "LAB", "Lab Reporting says access is denied",
        "Lab Reporting is open only to users marked Lab Technician or Pathologist (or Administrators), in addition to page permission.",
        ["Ask the administrator to tick Lab Technician or Pathologist for you in Settings > User Master.",
         "Check your role has the Lab Reporting page in Role Permissions.",
         "Sign out and in again after the change."],
        pages=["SETTINGS.USERS", "LAB.LABREPORTING"], keywords="access denied lab reporting technician pathologist")
trouble("TS.CANNOT.APPROVE", "LAB", "I cannot approve a report",
        "Approval may be reserved to the Report Approval Dashboard, need your level in the approval flow, or wait for critical value communication.",
        ["If Hospital Settings says Pathologist approval required, approve from LAB > Report Approval Dashboard.",
         "Check you are a user of the right level in Settings > Pathologist Approval Flow.",
         "If a result is Critical / Panic, record the critical value communication first.",
         "Results must be submitted (and validated, if your flow uses validation) before approval.",
         "Your role needs the Approve action on the page."],
        pages=["LAB.PATHOLOGISTDASHBOARD", "SETTINGS.LABAPPROVALFLOWS"], keywords="cannot approve approve button missing sign off blocked")
trouble("TS.EMAIL.NOT.SENT", "SETTINGS", "Emails are not being sent",
        "Emails need the branch's mail settings, a correct address and a working mail server.",
        ["Settings > Email Configuration: the branch has an Active, Default configuration; use Test Email.",
         "Utility > Email Logs shows each failure with the reason (wrong password, blocked, invalid address).",
         "With Gmail / Office 365 use an app password and the right port (587 STARTTLS or 465 SSL).",
         "The recipient must have a valid email; ask them to check Spam."],
        pages=["SETTINGS.SMTPCONFIG", "UTILITY.EMAILLOGS"], keywords="email not sent failed smtp mail not received emails not going not delivered not working bounce")
trouble("TS.RESET.NO.EMAIL", "GENERAL", "The password reset email does not arrive",
        "The link is sent only to the email on your user account, with the Head Office mail settings.",
        ["Check Spam / Junk and wait a minute.",
         "Make sure your user account has your email (User Master) - ask the administrator.",
         "If several accounts share the email, enter your user name instead.",
         "At most 3 links are sent per 15 minutes; the newest link cancels older ones."],
        pages=["SETTINGS.USERS"], keywords="reset email not received forgot password link password reset not working reset mail not coming")
trouble("TS.SLOW", "GENERAL", "The application is slow",
        "Most slowness comes from the network between the application and the database server, or very large date ranges.",
        ["Try a shorter date range or more filters on lists and reports.",
         "Check your internet connection; ask IT whether the database server is reachable without packet loss.",
         "Close unused tabs of the application; refresh the page.",
         "If one page is always slow, tell your administrator which page and what you did."],
        keywords="slow loading performance hang lag")
trouble("TS.PRINT.WRONG", "LAB", "The bill prints on the wrong page size",
        "The page size is set per branch in Hospital Settings and must match the printer paper.",
        ["Settings > Hospital Settings > LAB > Printing: choose A4 or A5 landscape.",
         "In the print dialog choose the same paper size, scale 100% and no headers / footers."],
        pages=["SETTINGS.HOSPITALSETTINGS"], keywords="print size wrong page a4 a5 printer bill")
trouble("TS.ACC.BILL.MISSING", "UTILITY", "A bill or receipt is missing from the Cash Book / ledger",
        "The ledger entry is posted right after the bill or payment is saved; if that step failed (for example the connection dropped), the document is saved but its entry is not.",
        ["Reports > Accounts > Bill Reconciliation (or Ledger Posting Audit for the period) lists it.",
         "Click Repair on Bill Reconciliation: the missing entry is posted on the document's own date.",
         "If it stays under \"Needs a person to check\", open the bill - its payment rows do not agree with its Total Paid, or it has no payment record."],
        pages=["REPORTS.ACCOUNTS"], keywords="missing ledger entry cash book bill not posted receipt not posted repair reconciliation")
trouble("TS.ACC.WRONG.BOOK", "UTILITY", "Card / UPI money shows in the wrong bank (or in cash)",
        "Each payment method posts to the ledger chosen in Accounts Settings > Payment Mode Ledgers; it was set to another ledger when the payment was saved.",
        ["Head office: Utility > Accounts > Accounts Settings > Payment Mode Ledgers - choose the right ledger for the method (and branch) and save; new payments follow it.",
         "Entries already posted: move them with a Contra voucher (Dr the right ledger, Cr the wrong one) in Voucher Entry."],
        pages=["UTILITY.ACCOUNTS.SETTINGS", "UTILITY.ACCOUNTS.VOUCHERS"], keywords="wrong bank ledger upi card cash book bank book payment mode mapping")
trouble("TS.SAVE.ERROR", "GENERAL", "Saving fails with an error",
        "The message says why; usually a required field, a rule (approval, duplicate) or a lost connection.",
        ["Read the message and fill / correct the highlighted fields.",
         "If it mentions approval, wait for the approver or ask them in Approval Dashboard.",
         "If it says the server could not be reached, check the connection and try again - do not create the record twice.",
         "Refresh the page and retry; if it repeats, note the time and tell the administrator (Audit Log helps)."],
        keywords="error save failed cannot save unexpected")
trouble("TS.SCAN.FAILED", "LAB", "Smart ID Scan could not read the document",
        "Blurred, cropped or very small images and unsupported documents cannot be read.",
        ["Use a clear, straight photo of the whole card in good light (or the original PDF).",
         "Supported: Aadhaar, PAN, passport. Other IDs can be uploaded but are not read.",
         "Check AI features are on for the branch (Hospital Settings).",
         "Type the details by hand if needed - the document is still attached."],
        keywords="smart id scan ocr not read aadhaar pan failed")
trouble("TS.CAMPAIGN.FAILED", "UTILITY", "Campaign emails failed",
        "Failures come from the sending branch's mail account or invalid addresses.",
        ["Open the campaign's results, filter Failed and read the reason.",
         "Fix the branch's Email Configuration (Test Email) and click Retry failed.",
         "Many failures at once may mean the provider's sending limit - send to smaller groups or schedule."],
        pages=["UTILITY.CAMPAIGNS", "SETTINGS.SMTPCONFIG"], keywords="campaign failed emails not delivered retry")
trouble("TS.BARCODE", "LAB", "The barcode label does not print or scan",
        "Label printing depends on the printer settings and label size.",
        ["Select the label printer and the correct label size in the print dialog; scale 100%.",
         "Print a test label; if bars are faint, clean / adjust the printer darkness.",
         "If a scanner does not read it, check the label is not wrinkled or covered by tape."],
        pages=["LAB.SAMPLECOLLECTION"], keywords="barcode label print scan sticker")
trouble("TS.FRANCHISE.BALANCE", "LAB", "B2B booking says the franchise has no balance",
        "Prepaid franchises need wallet balance for each booking.",
        ["Top up the wallet in Utility > Franchise Top-Up (it may need approval).",
         "Check the franchise's credit settings in Franchise Setup.",
         "Reports > LAB > Franchise Wallet Statement shows the balance and movements."],
        pages=["UTILITY.FRANCHISETOPUP", "MASTER.LABFRANCHISES"], keywords="franchise balance wallet insufficient b2b")
trouble("TS.LICENCE", "SETTINGS", "The sign-in screen asks for the licence",
        "The server's licence must be valid before anyone can sign in.",
        ["Click Re-validate licence with the licence server and follow the steps (an OTP may be sent).",
         "Check the server has internet access to the licence server.",
         "If it still fails, contact your vendor with the message shown."],
        pages=["SETTINGS.LICENSE"], keywords="licence license expired invalid sign in blocked")
trouble("TS.NO.TOKEN.SLOT", "OPD", "No slots are available for a doctor",
        "Slots come from the doctor's roster for that day.",
        ["Check OPD > Doctor Roster has the day and time for the doctor and the branch.",
         "Check leaves / holidays and that the slots are not already full.",
         "Check the doctor is active and assigned to the branch."],
        pages=["OPD.DOCTORROSTER"], keywords="no slot doctor not available appointment roster")
trouble("TS.REPORT.EMPTY", "REPORTS", "A report shows no data",
        "The filters exclude everything, or the period has no records for your branch.",
        ["Widen the date range and clear filters, then Apply again.",
         "Check the branch (Head Office can choose a branch).",
         "Some reports use the bill date, others the collection or approval date - read the label of the date filter."],
        keywords="report empty no data blank zero")

# ════════════════════════════════ WORKFLOWS ════════════════════════════════
# The order the work really happens in. The Help Assistant uses them to answer "what next / what before / what is
# the process" questions, and every answer shows where its step sits in the flow. Each module's setup order is also
# turned into a "Set up <module>" workflow by build_help_sql.py.
#   step(page, title, what to do, guide that explains it, optional=..., when=...)

WORKFLOWS = []

def step(page, title, do, article=None, optional=False, when=None):
    return dict(page=page, title=title, do=do, article=article, optional=optional, when=when)

def workflow(code, module, title, summary, steps, keywords="", primary=False):
    # primary: an everyday workflow - "what is next after X" is answered from it unless the question names another one
    WORKFLOWS.append(dict(code=code, module=module, title=title, summary=summary, steps=steps, keywords=keywords, primary=primary))

workflow("FLOW.LAB.B2C", "LAB", "LAB walk-in patient (B2C): from bill to report",
         "A walk-in patient's tests from the bill to the delivered report and the day's cash closing.",
         [step("LAB.LABORDERBOOKING.B2CBOOKING", "Create the B2C bill",
               "Find or register the patient, add tests / profiles / packages, take payment and print the bill.", "LAB.B2C"),
          step("LAB.SAMPLECOLLECTION", "Collect the sample",
               "Find the bill, print the barcode labels, stick them on the tubes and click Collect.", "LAB.COLLECT"),
          step("LAB.SAMPLETRANSFER", "Send the sample to the testing branch",
               "Transfer the collected samples; the other branch receives them.", "LAB.TRANSFER",
               optional=True, when="only when another branch runs the test"),
          step("LAB.LABREPORTING", "Enter and validate the results",
               "Open the bill in Lab Reporting Entry, type the results, Submit; a senior validates.", "LAB.REPORT"),
          step("LAB.PATHOLOGISTDASHBOARD", "Pathologist approves the report",
               "The pathologist checks and approves (sign-off levels as set in Lab Approval Flows).", "LAB.APPROVE"),
          step("LAB.LABREPORTDISPATCH", "Deliver the report",
               "Print the approved report or send it by email / WhatsApp.", "LAB.DISPATCH"),
          step("LAB.LABORDERBOOKING.B2CORDERLIST", "Collect the balance due",
               "Open the bill in B2C Order List > Collect Payment and take the balance; a money receipt is printed.", "LAB.DUE",
               optional=True, when="only when the bill has a due amount"),
          step("LAB.DAYCLOSING", "Close the day",
               "At the end of the day submit the LAB Day Closing; a supervisor verifies it.", "LAB.CLOSE")],
         keywords="b2c walk in lab bill billing booking sample report", primary=True)

workflow("FLOW.LAB.B2B", "LAB", "LAB franchise / corporate (B2B): from booking to settlement",
         "Tests booked for a franchise, collection centre or corporate, from the wallet to the invoice and settlement.",
         [step("UTILITY.FRANCHISETOPUP", "Make sure the partner has balance",
               "Top up the franchise wallet (prepaid franchises).", "UT.FRANCHISE", optional=True, when="only for prepaid franchises"),
          step("LAB.LABORDERBOOKING.B2BBOOKING", "Create the B2B booking",
               "Choose the partner, add the patient and tests on the partner's rates, and save.", "LAB.B2B"),
          step("LAB.SAMPLECOLLECTION", "Collect / receive the sample",
               "Print barcodes and mark the samples collected.", "LAB.COLLECT"),
          step("LAB.SAMPLETRANSFER", "Send the sample to the testing branch",
               "Transfer and receive the samples.", "LAB.TRANSFER", optional=True, when="only when another branch runs the test"),
          step("LAB.LABREPORTING", "Enter and validate the results",
               "Type the results in Lab Reporting Entry and Submit; a senior validates.", "LAB.REPORT"),
          step("LAB.PATHOLOGISTDASHBOARD", "Pathologist approves the report", "Sign off the report.", "LAB.APPROVE"),
          step("LAB.LABREPORTDISPATCH", "Deliver the report", "Print, email or WhatsApp the report to the partner / patient.", "LAB.DISPATCH"),
          step("LAB.LABORDERBOOKING.B2BINVOICES", "Invoice the partner", "Raise the partner's invoice for the period.", "LAB.B2B"),
          step("LAB.LABORDERBOOKING.B2BSETTLEMENT", "Settle the partner's payment", "Record the partner's payment against one or many bills.", "LAB.B2B")],
         keywords="b2b franchise corporate partner collection centre booking invoice settlement")

workflow("FLOW.LAB.CORRECT", "LAB", "Correct an approved LAB report (Re-Test / Re-Collect)",
         "What happens after a report is un-authorised, until the revised report reaches the patient.",
         [step("LAB.LABUNAPPROVE", "Un-authorise the report",
               "Choose the tests, Re-Test or Re-Collect, and the reason.", "LAB.UNAPPROVE"),
          step("LAB.SAMPLECOLLECTION", "Collect a new sample", "Collect the new sample and print its barcode.", "LAB.COLLECT",
               optional=True, when="only for Re-Collect"),
          step("LAB.LABREPORTING", "Enter the corrected results", "Correct the results and Submit; a senior validates.", "LAB.REPORT"),
          step("LAB.PATHOLOGISTDASHBOARD", "Approve again", "The pathologist approves the corrected report.", "LAB.APPROVE"),
          step("LAB.LABREPORTDISPATCH", "Send the revised report", "Deliver the report; it is marked as revised.", "LAB.DISPATCH")],
         keywords="unapprove unauthorize retest re-test recollect re-collect correct amend revised report")

workflow("FLOW.OPD", "OPD", "OPD patient visit: from registration to day closing",
         "A patient's OPD visit from registration and booking to consultation, tests and the day's closing.",
         [step("OPD.PATIENTREGISTRATION", "Register (or find) the patient",
               "Search by phone first; register a new patient only when not found.", "OPD.REGISTER"),
          step("OPD.SERVICEBOOKING", "Book and bill the consultation",
               "Choose the doctor, slot and service, take payment and print the bill; the patient gets a token.", "OPD.BOOK"),
          step("OPD.TOKENMANAGEMENT", "Call the token", "Call the next token; the patient goes for vitals.", "OPD.FLOW"),
          step("OPD.VITALS", "Record vitals", "BP, pulse, temperature, weight, SpO2...", "OPD.FLOW"),
          step("OPD.DOCTORDASHBOARD", "Doctor consultation",
               "The doctor writes the notes and diagnosis, advises tests, prescribes and sets the follow-up.", "OPD.FLOW"),
          step("LAB.LABORDERBOOKING.B2CBOOKING", "Bill the advised tests",
               "Book the advised LAB tests (then the LAB walk-in workflow follows).", "LAB.B2C",
               optional=True, when="only when the doctor advised tests"),
          step("OPD.DAYCLOSING", "Close the day", "Submit the OPD Day Closing; a supervisor verifies it.", "OPD.CLOSE")],
         keywords="opd visit consultation appointment patient doctor", primary=True)

workflow("FLOW.EMAIL", "UTILITY", "Emails to patients: from mail settings to campaigns",
         "Everything needed before bills, reports and campaign emails reach patients.",
         [step("SETTINGS.SMTPCONFIG", "Set up the branch's mail settings", "Server, port, sender and password of the branch; send a test mail.", "SET.SMTP"),
          step("UTILITY.EMAILTEMPLATE", "Word the email templates", "Edit the wording of the system emails in the designer.", "UT.TEMPLATES"),
          step("UTILITY.CAMPAIGNS", "Send a campaign", "Choose patients / users / doctors, the template, and send now or later.", "UT.CAMPAIGN",
               optional=True, when="for bulk or one-off emails"),
          step("UTILITY.EMAILLOGS", "Check what was sent", "See sent and failed emails and the reason.", "UT.AUDIT")],
         keywords="email mail smtp template campaign", primary=True)

workflow("FLOW.ACC.GOLIVE", "UTILITY", "Accounts go-live: from setup to the first trial balance",
         "Everything to do once before the books of a branch can be trusted.",
         [step("UTILITY.ACCOUNTS.SETTINGS", "Set the accounts rules", "Financial year start, petty cash limits and approvals.", "UT.PETTY"),
          step("UTILITY.ACCOUNTS.LEDGERS", "Create the bank ledgers", "One ledger per real bank account under Bank Accounts.", "ACC.SETUP"),
          step("UTILITY.ACCOUNTS.SETTINGS", "Map payment modes to ledgers", "Cash, Card, UPI, NEFT, Cheque, Wallet -> their ledger.", "ACC.SETUP"),
          step("UTILITY.ACCOUNTS.OPENING", "Enter the opening balances", "Each branch's balances on the go-live date; Difference = Balanced.", "ACC.OPENING"),
          step("REPORTS.ACCOUNTS", "Reconcile bills with the ledger", "Bill Reconciliation: agrees, or Repair.", "ACC.RECON"),
          step("REPORTS.ACCOUNTS", "Check the Trial Balance", "Debits equal credits, no unbalanced voucher.", "ACC.MONTHEND")],
         keywords="accounts go live setup ledger bank opening balance payment mode trial balance start books")

workflow("FLOW.ACC.MONTHEND", "UTILITY", "Accounts month-end close",
         "The monthly checks before the books of a month are locked.",
         [step("REPORTS.ACCOUNTS", "Reconcile bills with the ledger", "Bill Reconciliation: repair what can be repaired, check the rest.", "ACC.RECON"),
          step("REPORTS.ACCOUNTS", "Run the Ledger Posting Audit", "No document of the month left unposted.", "ACC.MONTHEND"),
          step("REPORTS.ACCOUNTS", "Tally the Cash Book and Bank Book", "Closing balances against counted cash and the bank statement.", "ACC.MONTHEND"),
          step("REPORTS.ACCOUNTS", "Check the Trial Balance", "Debits equal credits.", "ACC.MONTHEND"),
          step("UTILITY.ACCOUNTS.SETTINGS", "Lock the month", "Books Lock: each branch up to the month's last day.", "ACC.MONTHEND")],
         keywords="month end close lock books reconcile trial balance cash book bank book audit")
