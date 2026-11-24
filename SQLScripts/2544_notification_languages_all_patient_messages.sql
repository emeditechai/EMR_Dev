-- ============================================================================================================
-- Migration: 2544_notification_languages_all_patient_messages.sql (after 2543; UTF-8 with BOM - run as Unicode:
--   SSMS, or sqlcmd -f 65001)
-- Every message sent to a patient goes in the patient's language (PatientMaster.LanguageId). One event per message, the
-- exact English as sent today stored on the event as the reference (Settings > Notification Languages shows it beside the
-- translation), and Hindi / Bengali texts translated sentence by sentence - same meaning as the English.
-- English stays exactly as today (WhatsApp Configuration / Hospital Settings templates and the built-in texts): an English
-- text, if one is added on the page, replaces it.
-- Optional parts in a text: {#Key}...{/Key} only when Key has a value, {^Key}...{/Key} only when it has none.
-- Re-runnable: existing texts are never overwritten (only missing ones are added).
-- ============================================================================================================
SET NOCOUNT ON;
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
IF COL_LENGTH('dbo.NotifyEvent', 'RefWhatsApp') IS NULL
    ALTER TABLE dbo.NotifyEvent ADD RefWhatsApp NVARCHAR(MAX) NULL, RefEmailSubject NVARCHAR(300) NULL, RefEmailHeading NVARCHAR(200) NULL, RefEmailBody NVARCHAR(MAX) NULL;
GO

MERGE dbo.NotifyEvent AS t
USING (VALUES
 ('LAB_BILL', 'LAB', N'LAB bill', 'WHATSAPP,EMAIL', N'{PatientName},{HospitalName},{BillNo},{TokenNo},{Amount},{BillDate},{HospitalAddress}', N'Sent to the patient when a LAB bill is made (B2C, and B2B when the franchise sends notifications): WhatsApp and e-mail with the bill PDF.', 10, N'Dear {PatientName}, thank you for choosing {HospitalName}. Your Lab Order {BillNo} of Rs. {Amount} has been registered. Token: {TokenNo}. Please find your bill attached. Thank you!', N'Your Lab Order Bill [{BillNo}] - {HospitalName}', N'Your lab bill', N'Dear {PatientName},

Thank you for choosing {HospitalName} for your healthcare needs.

Bill No: {BillNo}
Date: {BillDate}

Please find your detailed lab order bill attached to this email as a PDF document.

If you have any questions or require further assistance, please do not hesitate to contact us.

Wishing you the best of health,
The {HospitalName} Team'),
 ('LAB_REPORT', 'LAB', N'LAB report ready', 'WHATSAPP,EMAIL', N'{PatientName},{HospitalName},{BillNo},{TokenNo},{ApprovedOn},{TestCount},{TestList},{Revised}', N'Sent when the report of a bill is approved: WhatsApp and e-mail with the report PDF (a revised report says so).', 20, N'Dear {PatientName}, your report for Bill {BillNo} at {HospitalName} has been approved. Please find your report attached. Thank you for choosing us!', N'{#Revised}Revised {/Revised}Lab Report - {BillNo} | {HospitalName}', N'Your lab report is ready', N'Dear {PatientName},

{#Revised}This is a revised report and replaces the one sent earlier for this bill.

{/Revised}Your laboratory test report is ready. It has been reviewed and approved, and a copy is attached to this email as a PDF document.

Bill No: {BillNo}
Token No: {TokenNo}
Report approved on: {ApprovedOn}
Tests reported: {TestCount}

{TestList}

Please share this report with your doctor, who will interpret the results in the context of your health. If you have any questions, feel free to contact us.

Wishing you good health,
{HospitalName}'),
 ('LAB_ESTIMATE', 'LAB', N'LAB estimate', 'WHATSAPP', N'{PatientName},{BranchName},{EstimateNo},{TestCount},{Amount},{ValidTill},{ViewUrl}', N'The lab test estimate sent by WhatsApp from LAB > Estimates (PDF attached).', 30, N'Dear {PatientName},
Please find attached the estimate for your lab tests at {BranchName}.
Estimate No: {EstimateNo}
Tests: {TestCount}
Estimated amount: Rs {Amount}
Valid till: {ValidTill}
{#ViewUrl}
View online: {ViewUrl}
{/ViewUrl}
This is an estimate, not a bill.', NULL, NULL, NULL),
 ('OPD_BILL', 'OPD', N'OPD bill', 'WHATSAPP', N'{PatientName},{HospitalName},{BillNo},{Amount},{TokenNo},{DoctorName}', N'Sent to the patient when an OPD bill is made: WhatsApp with the bill PDF.', 40, N'Dear {PatientName}, thank you for visiting {HospitalName}. Your OPD Bill {BillNo} of Rs. {Amount} has been generated. Token: {TokenNo}, Doctor: {DoctorName}. Please find your bill attached. Wish you a speedy recovery!', NULL, NULL, NULL),
 ('OPD_BOOKING', 'OPD', N'OPD booking confirmation', 'EMAIL', N'{PatientName},{HospitalName},{DoctorName},{VisitDate},{SlotTime},{TokenNo},{TotalAmount}', N'The booking confirmation e-mail (English text: Utility > Email Templates > Booking Confirmation).', 45, NULL, N'Booking Confirmation at {HospitalName}', N'Booking Confirmation', N'Dear {PatientName},

Your appointment at {HospitalName} has been scheduled. Here are your booking details:

Consulting Doctor: {DoctorName}
Appointment Date: {VisitDate}
Slot Time: {SlotTime}
Token Number: {TokenNo}
Total Paid / Fee: Rs. {TotalAmount}

Please arrive at least 15 minutes before your slot for registration and vitals checks.

Warm regards,
{HospitalName} Team'),
 ('OPD_FOLLOWUP', 'OPD', N'OPD follow-up reminder', 'WHATSAPP,EMAIL', N'{PatientName},{HospitalName},{DoctorName},{FollowUpDate},{PatientCode},{Contact},{Tomorrow}', N'Reminder a week before and the day before the follow-up date set by the doctor: WhatsApp and e-mail.', 50, N'Dear {PatientName},

This is a reminder from {HospitalName}: your follow-up visit with {DoctorName} is {#Tomorrow}tomorrow{/Tomorrow}{^Tomorrow}in 7 days{/Tomorrow}, on {FollowUpDate}.{#PatientCode}
Patient ID: {PatientCode}{/PatientCode}{#Contact}
To book or change the visit, please call {Contact}.{/Contact}

Thank you.', N'Follow-up reminder: {FollowUpDate} - {HospitalName}', N'Follow-up visit reminder', N'Dear {PatientName},

This is a friendly reminder that your follow-up visit with {DoctorName} is {#Tomorrow}tomorrow{/Tomorrow}{^Tomorrow}in 7 days{/Tomorrow}.

Date: {FollowUpDate}
Doctor: {DoctorName}
Patient ID: {PatientCode}{#Contact}

To book or change the visit, please call {Contact}.{/Contact}

Regards,
{HospitalName}'),
 ('OPD_VIDEO', 'OPD', N'Video consultation', 'WHATSAPP,EMAIL', N'{PatientName},{DoctorName},{Date},{Time},{EndTime},{GraceMinutes},{Link}', N'The patient''s video consultation confirmation with the join link: WhatsApp and e-mail (the doctor''s message stays English).', 55, N'Dear {PatientName}, your Video Consultation with Dr. {DoctorName} on {Date} at {Time} is confirmed. Join using: {Link}', N'Your Video Consultation with Dr. {DoctorName} on {Date}', N'Your video consultation', N'Dear {PatientName},

Your video consultation has been confirmed:

Doctor: Dr. {DoctorName}
Date: {Date}
Time: {Time} to {EndTime}{#GraceMinutes} (+{GraceMinutes} min grace){/GraceMinutes}

Click the link below to join your appointment:
{Link}

How to join:
1. Click the link at your scheduled appointment time.
2. You will enter a waiting room.
3. Click "Knock" and the doctor will admit you.
4. No software download required - works directly in your browser.'),
 ('CERTIFICATE', 'OPD', N'Certificate issued', 'WHATSAPP,EMAIL', N'{PatientName},{CertificateType},{CertificateNo},{IssueDate},{SignedBy},{HospitalName},{VerifyUrl}', N'A certificate (medical, fitness ...) sent to the patient: WhatsApp and e-mail with the PDF.', 60, N'Dear {PatientName}, your {CertificateType} No. {CertificateNo} dated {IssueDate}{#SignedBy}, signed by {SignedBy}{/SignedBy}, issued by {HospitalName}, is attached.{#VerifyUrl} It can be verified at {VerifyUrl}{/VerifyUrl} Thank you.', N'Your {CertificateType} {CertificateNo} - {HospitalName}', N'{CertificateType}', N'Dear {PatientName}, your {CertificateType} No. {CertificateNo} dated {IssueDate}{#SignedBy}, signed by {SignedBy}{/SignedBy}, issued by {HospitalName}, is attached.{#VerifyUrl} It can be verified at {VerifyUrl}{/VerifyUrl} Thank you.

Your certificate is attached to this e-mail as a PDF. Scan its QR code to check that it is genuine.'),
 ('MEM_POINTS', 'MEMBERSHIP', N'Membership points added', 'WHATSAPP', N'{CardHolderName},{PatientName},{HospitalName},{CardNo},{PlanName},{BillNo},{PointsEarned},{PointsValue},{PointsBalance},{BalanceValue},{ExpiryDate}', N'Points credited to the membership card on a bill: WhatsApp.', 70, N'Dear {CardHolderName}, {PointsEarned} points (worth Rs. {PointsValue}) have been added to your {HospitalName} membership card {CardNo} for Bill {BillNo}. Your balance is now {PointsBalance} points (Rs. {BalanceValue}). These points are valid till {ExpiryDate}. Thank you!', NULL, NULL, NULL),
 ('MEM_CARD', 'MEMBERSHIP', N'Membership card issued', 'WHATSAPP,EMAIL', N'{PatientName},{HospitalName},{PlanName},{CardNo},{ValidFrom},{ValidTo}', N'The membership card sent to the primary member: WhatsApp and e-mail with the card PDF.', 75, N'Dear {PatientName}, welcome to the {PlanName} membership of {HospitalName}. Your card number is {CardNo}, valid from {ValidFrom} to {ValidTo}. Your membership card is attached.', N'Your {PlanName} membership card - {HospitalName}', N'Your membership card', N'Dear {PatientName}, welcome to the {PlanName} membership of {HospitalName}. Your card number is {CardNo}, valid from {ValidFrom} to {ValidTo}. Your membership card is attached.

Card No: {CardNo}
Plan: {PlanName}
Valid: {ValidFrom} to {ValidTo}

Your membership card is attached to this email as a PDF.'),
 ('MEM_RENEWAL', 'MEMBERSHIP', N'Membership renewal reminder', 'EMAIL', N'{PatientName},{HospitalName},{PlanName},{CardNo},{ValidTo},{DaysLeft},{Points},{Today}', N'E-mail before the membership card expires.', 80, NULL, N'Your {PlanName} membership expires {#Today}today{/Today}{^Today}in {DaysLeft} day(s){/Today} - {HospitalName}', N'{#Today}Your membership expires today{/Today}{^Today}Your membership is due for renewal{/Today}', N'Dear {PatientName}, your {PlanName} membership card {CardNo} at {HospitalName} expires {#Today}today{/Today}{^Today}in {DaysLeft} day(s){/Today}, on {ValidTo}. Renew it at any of our centres to keep your benefits and carry your {Points} points forward to the new card.

Card No: {CardNo}
Plan: {PlanName}
Valid to: {ValidTo}
Points balance: {Points}'),
 ('PH_BILL', 'PHARMACY', N'Pharmacy bill', 'WHATSAPP,EMAIL', N'{CustomerName},{PharmacyName},{BillNo},{Amount},{BillDate}', N'The pharmacy sale bill: WhatsApp and e-mail with the bill PDF.', 90, N'Dear {CustomerName}, thank you for your purchase at {PharmacyName}. Your bill {BillNo} of ₹{Amount} dated {BillDate} is attached.', N'Your pharmacy bill {BillNo} - {PharmacyName}', N'Pharmacy bill', N'Dear {CustomerName}, thank you for your purchase at {PharmacyName}. Your bill {BillNo} of ₹{Amount} dated {BillDate} is attached.

Bill No: {BillNo}
Date: {BillDate}
Amount: ₹{Amount}'),
 ('PH_LOYALTY', 'PHARMACY', N'Pharmacy loyalty (points used / earned)', 'WHATSAPP', N'{CustomerName},{BillNo},{Amount},{Discount},{PointsUsed},{PointsEarned},{PointsEarnedValue},{UsableFrom},{Wallet},{WalletPoints},{WalletValue},{Pending},{PharmacyName}', N'After a sale: points used and earned with the wallet balance, or the member discount saved: WhatsApp.', 95, N'Hello{#CustomerName} {CustomerName}{/CustomerName},

Thank you for your purchase (bill {BillNo}, ₹{Amount}).
{#Discount}⭐ As a loyalty member you saved *₹{Discount}* on this bill.
{/Discount}{#PointsUsed}Points used: *{PointsUsed}*
{/PointsUsed}{#PointsEarned}⭐ *{PointsEarned} points* (₹{PointsEarnedValue}) credited to your wallet{#UsableFrom} - usable from {UsableFrom}{/UsableFrom}.
{/PointsEarned}{#Wallet}Wallet balance: *{WalletPoints} points* (₹{WalletValue}) to use on your next bill{#Pending}; {Pending} more on the way{/Pending}.
{/Wallet}
- {PharmacyName}', NULL, NULL, NULL),
 ('PH_REFILL', 'PHARMACY', N'Pharmacy refill reminder', 'WHATSAPP', N'{CustomerName},{ItemName},{BillNo},{RunOutDate},{PharmacyPhone},{PharmacyName}', N'Before a medicine bought runs out: WhatsApp.', 100, N'Hello{#CustomerName} {CustomerName}{/CustomerName},

Your medicine *{ItemName}* (bill {BillNo}) is due to run out on {RunOutDate}. Please refill it in time - do not stop a medicine without asking your doctor.{#PharmacyPhone}
Call {PharmacyPhone} to keep it ready.{/PharmacyPhone}

- {PharmacyName}', NULL, NULL, NULL),
 ('PH_WALLET_EXPIRY', 'PHARMACY', N'Pharmacy wallet points expiring', 'WHATSAPP', N'{CustomerName},{Points},{PointsValue},{ExpiresOn},{Available},{PharmacyName}', N'Before wallet points expire: WhatsApp.', 105, N'Hello{#CustomerName} {CustomerName}{/CustomerName},

*{Points} loyalty points* (₹{PointsValue}) in your wallet expire on {ExpiresOn}. Use them on your next purchase.
Wallet balance: {Available} points.

- {PharmacyName}', NULL, NULL, NULL),
 ('PORTAL_LOGIN', 'PATIENT', N'Patient portal login', 'WHATSAPP,EMAIL', N'{PatientName},{HospitalName},{PatientCode},{Password},{PortalUrl},{Reset}', N'Patient portal / app sign-in details (new account or password reset): WhatsApp and e-mail.', 110, N'{HospitalName} - Patient portal
Patient ID: {PatientCode}
Password: {Password}{#PortalUrl}
Sign in: {PortalUrl}{/PortalUrl}
You will be asked to choose your own password at the first sign-in.', N'{#Reset}{HospitalName} - Patient portal password reset{/Reset}{^Reset}Welcome to {HospitalName} - Your Login Credentials{/Reset}', N'{#Reset}Your patient portal password{/Reset}{^Reset}Welcome to {HospitalName}{/Reset}', N'Dear {PatientName},

{#Reset}Your patient portal password has been reset. Use the details below to sign in.{/Reset}{^Reset}Thank you for registering with us! We have created a secure patient portal account for you. You can use it to view your health records and stay connected with our care team.{/Reset}

Patient ID: {PatientCode}
Password: {Password}{#PortalUrl}
Sign in at: {PortalUrl}{/PortalUrl}

Sign in with your Patient ID. You will be asked to choose your own password at the first sign-in.

Regards,
{HospitalName}')
) s (EventCode, Module, Name, Channels, Placeholders, Description, SortOrder, RefWhatsApp, RefEmailSubject, RefEmailHeading, RefEmailBody)
ON t.EventCode = s.EventCode
WHEN MATCHED THEN UPDATE SET Module = s.Module, Name = s.Name, Channels = s.Channels, Placeholders = s.Placeholders, Description = s.Description, SortOrder = s.SortOrder,
    RefWhatsApp = s.RefWhatsApp, RefEmailSubject = s.RefEmailSubject, RefEmailHeading = s.RefEmailHeading, RefEmailBody = s.RefEmailBody, IsActive = 1
WHEN NOT MATCHED THEN INSERT (EventCode, Module, Name, Channels, Placeholders, Description, SortOrder, RefWhatsApp, RefEmailSubject, RefEmailHeading, RefEmailBody)
    VALUES (s.EventCode, s.Module, s.Name, s.Channels, s.Placeholders, s.Description, s.SortOrder, s.RefWhatsApp, s.RefEmailSubject, s.RefEmailHeading, s.RefEmailBody);
GO

DECLARE @t TABLE (EventCode VARCHAR(40), Channel VARCHAR(10), Lang VARCHAR(10), Subject NVARCHAR(300), Heading NVARCHAR(200), Body NVARCHAR(MAX));
INSERT @t VALUES
 ('LAB_REPORT', 'WHATSAPP', 'hi', NULL, NULL, N'प्रिय {PatientName}, {HospitalName} में बिल {BillNo} की आपकी रिपोर्ट स्वीकृत हो गई है। कृपया संलग्न रिपोर्ट देखें। हमें चुनने के लिए धन्यवाद!'),
 ('LAB_REPORT', 'EMAIL', 'hi', N'{#Revised}संशोधित {/Revised}लैब रिपोर्ट - {BillNo} | {HospitalName}', N'आपकी लैब रिपोर्ट तैयार है', N'प्रिय {PatientName},

{#Revised}यह एक संशोधित रिपोर्ट है और इस बिल के लिए पहले भेजी गई रिपोर्ट की जगह लेती है।

{/Revised}आपकी लैब जाँच रिपोर्ट तैयार है। इसकी समीक्षा और स्वीकृति हो चुकी है, और इसकी एक प्रति इस ईमेल के साथ PDF दस्तावेज़ के रूप में संलग्न है।

बिल नंबर: {BillNo}
टोकन नंबर: {TokenNo}
रिपोर्ट स्वीकृत: {ApprovedOn}
रिपोर्ट की गई जाँचें: {TestCount}

{TestList}

कृपया यह रिपोर्ट अपने डॉक्टर को दिखाएँ, जो आपके स्वास्थ्य के संदर्भ में परिणामों की व्याख्या करेंगे। यदि आपका कोई प्रश्न हो, तो बेझिझक हमसे संपर्क करें।

उत्तम स्वास्थ्य की शुभकामनाओं सहित,
{HospitalName}'),
 ('LAB_REPORT', 'WHATSAPP', 'bn', NULL, NULL, N'প্রিয় {PatientName}, {HospitalName}-এ বিল {BillNo}-এর আপনার রিপোর্ট অনুমোদিত হয়েছে। অনুগ্রহ করে সংযুক্ত রিপোর্টটি দেখুন। আমাদের বেছে নেওয়ার জন্য ধন্যবাদ!'),
 ('LAB_REPORT', 'EMAIL', 'bn', N'{#Revised}সংশোধিত {/Revised}ল্যাব রিপোর্ট - {BillNo} | {HospitalName}', N'আপনার ল্যাব রিপোর্ট প্রস্তুত', N'প্রিয় {PatientName},

{#Revised}এটি একটি সংশোধিত রিপোর্ট এবং এই বিলের জন্য আগে পাঠানো রিপোর্টের পরিবর্তে প্রযোজ্য।

{/Revised}আপনার ল্যাব পরীক্ষার রিপোর্ট প্রস্তুত। এটি পর্যালোচনা ও অনুমোদন করা হয়েছে, এবং এর একটি কপি এই ইমেলের সাথে PDF নথি হিসেবে সংযুক্ত করা হয়েছে।

বিল নম্বর: {BillNo}
টোকেন নম্বর: {TokenNo}
রিপোর্ট অনুমোদিত: {ApprovedOn}
রিপোর্ট করা পরীক্ষা: {TestCount}

{TestList}

অনুগ্রহ করে এই রিপোর্টটি আপনার ডাক্তারকে দেখান, যিনি আপনার স্বাস্থ্যের প্রেক্ষিতে ফলাফলগুলি ব্যাখ্যা করবেন। কোনো প্রশ্ন থাকলে নির্দ্বিধায় আমাদের সাথে যোগাযোগ করুন।

সুস্বাস্থ্য কামনা করি,
{HospitalName}'),
 ('LAB_ESTIMATE', 'WHATSAPP', 'hi', NULL, NULL, N'प्रिय {PatientName},
{BranchName} में आपकी लैब जाँचों का अनुमान (एस्टिमेट) संलग्न है।
एस्टिमेट नंबर: {EstimateNo}
जाँचें: {TestCount}
अनुमानित राशि: रु. {Amount}
मान्य: {ValidTill} तक
{#ViewUrl}
ऑनलाइन देखें: {ViewUrl}
{/ViewUrl}
यह केवल एक अनुमान है, बिल नहीं।'),
 ('LAB_ESTIMATE', 'WHATSAPP', 'bn', NULL, NULL, N'প্রিয় {PatientName},
{BranchName}-এ আপনার ল্যাব পরীক্ষার আনুমানিক খরচের হিসাব (এস্টিমেট) সংযুক্ত করা হলো।
এস্টিমেট নম্বর: {EstimateNo}
পরীক্ষা: {TestCount}
আনুমানিক পরিমাণ: ₹{Amount}
বৈধ: {ValidTill} পর্যন্ত
{#ViewUrl}
অনলাইনে দেখুন: {ViewUrl}
{/ViewUrl}
এটি একটি আনুমানিক হিসাব, বিল নয়।'),
 ('OPD_BILL', 'WHATSAPP', 'hi', NULL, NULL, N'प्रिय {PatientName}, {HospitalName} आने के लिए धन्यवाद। आपका ओपीडी बिल {BillNo}, राशि रु. {Amount}, बन गया है। टोकन: {TokenNo}, डॉक्टर: {DoctorName}। कृपया संलग्न बिल देखें। आपके शीघ्र स्वस्थ होने की कामना करते हैं!'),
 ('OPD_BILL', 'WHATSAPP', 'bn', NULL, NULL, N'প্রিয় {PatientName}, {HospitalName}-এ আসার জন্য ধন্যবাদ। আপনার ওপিডি বিল {BillNo}, মোট টাকা {Amount}, তৈরি হয়েছে। টোকেন: {TokenNo}, ডাক্তার: {DoctorName}। অনুগ্রহ করে সংযুক্ত বিলটি দেখুন। আপনার দ্রুত আরোগ্য কামনা করি!'),
 ('OPD_BOOKING', 'EMAIL', 'hi', N'{HospitalName} में बुकिंग की पुष्टि', N'बुकिंग की पुष्टि', N'प्रिय {PatientName},

{HospitalName} में आपका अपॉइंटमेंट तय हो गया है। आपकी बुकिंग का विवरण:

परामर्श डॉक्टर: {DoctorName}
अपॉइंटमेंट की तारीख: {VisitDate}
स्लॉट का समय: {SlotTime}
टोकन नंबर: {TokenNo}
कुल भुगतान / शुल्क: रु. {TotalAmount}

कृपया पंजीकरण और वाइटल्स जाँच के लिए अपने स्लॉट से कम से कम 15 मिनट पहले पहुँचें।

सादर,
{HospitalName} टीम'),
 ('OPD_BOOKING', 'EMAIL', 'bn', N'{HospitalName}-এ বুকিং নিশ্চিতকরণ', N'বুকিং নিশ্চিতকরণ', N'প্রিয় {PatientName},

{HospitalName}-এ আপনার অ্যাপয়েন্টমেন্ট নির্ধারিত হয়েছে। আপনার বুকিংয়ের বিবরণ:

পরামর্শদাতা ডাক্তার: {DoctorName}
অ্যাপয়েন্টমেন্টের তারিখ: {VisitDate}
স্লটের সময়: {SlotTime}
টোকেন নম্বর: {TokenNo}
মোট প্রদত্ত / ফি: ₹{TotalAmount}

অনুগ্রহ করে নিবন্ধন ও ভাইটালস পরীক্ষার জন্য আপনার স্লটের অন্তত ১৫ মিনিট আগে পৌঁছান।

শুভেচ্ছা সহ,
{HospitalName} টিম'),
 ('OPD_FOLLOWUP', 'WHATSAPP', 'hi', NULL, NULL, N'प्रिय {PatientName},

{HospitalName} की ओर से याद दिलाना: {DoctorName} के साथ आपकी फॉलो-अप विज़िट {#Tomorrow}कल{/Tomorrow}{^Tomorrow}7 दिन बाद{/Tomorrow}, {FollowUpDate} को है।{#PatientCode}
मरीज़ आईडी: {PatientCode}{/PatientCode}{#Contact}
विज़िट बुक करने या बदलने के लिए कृपया {Contact} पर कॉल करें।{/Contact}

धन्यवाद।'),
 ('OPD_FOLLOWUP', 'EMAIL', 'hi', N'फॉलो-अप रिमाइंडर: {FollowUpDate} - {HospitalName}', N'फॉलो-अप विज़िट रिमाइंडर', N'प्रिय {PatientName},

यह याद दिलाने के लिए है कि {DoctorName} के साथ आपकी फॉलो-अप विज़िट {#Tomorrow}कल{/Tomorrow}{^Tomorrow}7 दिन बाद{/Tomorrow} है।

तारीख: {FollowUpDate}
डॉक्टर: {DoctorName}
मरीज़ आईडी: {PatientCode}{#Contact}

विज़िट बुक करने या बदलने के लिए कृपया {Contact} पर कॉल करें।{/Contact}

सादर,
{HospitalName}'),
 ('OPD_FOLLOWUP', 'WHATSAPP', 'bn', NULL, NULL, N'প্রিয় {PatientName},

{HospitalName}-এর পক্ষ থেকে মনে করিয়ে দেওয়া হচ্ছে: {DoctorName}-এর সাথে আপনার ফলো-আপ ভিজিট {#Tomorrow}আগামীকাল{/Tomorrow}{^Tomorrow}৭ দিন পরে{/Tomorrow}, {FollowUpDate} তারিখে।{#PatientCode}
রোগীর আইডি: {PatientCode}{/PatientCode}{#Contact}
ভিজিট বুক বা পরিবর্তন করতে অনুগ্রহ করে {Contact} নম্বরে কল করুন।{/Contact}

ধন্যবাদ।'),
 ('OPD_FOLLOWUP', 'EMAIL', 'bn', N'ফলো-আপ রিমাইন্ডার: {FollowUpDate} - {HospitalName}', N'ফলো-আপ ভিজিটের রিমাইন্ডার', N'প্রিয় {PatientName},

মনে করিয়ে দিচ্ছি যে {DoctorName}-এর সাথে আপনার ফলো-আপ ভিজিট {#Tomorrow}আগামীকাল{/Tomorrow}{^Tomorrow}৭ দিন পরে{/Tomorrow}।

তারিখ: {FollowUpDate}
ডাক্তার: {DoctorName}
রোগীর আইডি: {PatientCode}{#Contact}

ভিজিট বুক বা পরিবর্তন করতে অনুগ্রহ করে {Contact} নম্বরে কল করুন।{/Contact}

শুভেচ্ছা সহ,
{HospitalName}'),
 ('OPD_VIDEO', 'WHATSAPP', 'hi', NULL, NULL, N'प्रिय {PatientName}, डॉ. {DoctorName} के साथ {Date} को {Time} बजे आपका वीडियो परामर्श कन्फ़र्म हो गया है। इस लिंक से जुड़ें: {Link}'),
 ('OPD_VIDEO', 'EMAIL', 'hi', N'डॉ. {DoctorName} के साथ {Date} को आपका वीडियो परामर्श', N'आपका वीडियो परामर्श', N'प्रिय {PatientName},

आपका वीडियो परामर्श कन्फ़र्म हो गया है:

डॉक्टर: डॉ. {DoctorName}
तारीख: {Date}
समय: {Time} से {EndTime}{#GraceMinutes} (+{GraceMinutes} मिनट की छूट){/GraceMinutes}

अपने अपॉइंटमेंट से जुड़ने के लिए नीचे दिए गए लिंक पर क्लिक करें:
{Link}

कैसे जुड़ें:
1. अपॉइंटमेंट के तय समय पर लिंक पर क्लिक करें।
2. आप एक वेटिंग रूम में पहुँचेंगे।
3. "Knock" पर क्लिक करें, डॉक्टर आपको अंदर ले लेंगे।
4. कोई सॉफ़्टवेयर डाउनलोड करने की ज़रूरत नहीं - यह सीधे आपके ब्राउज़र में चलता है।'),
 ('OPD_VIDEO', 'WHATSAPP', 'bn', NULL, NULL, N'প্রিয় {PatientName}, ডাঃ {DoctorName}-এর সাথে {Date} তারিখে {Time}-এ আপনার ভিডিও পরামর্শ নিশ্চিত হয়েছে। এই লিঙ্কে যোগ দিন: {Link}'),
 ('OPD_VIDEO', 'EMAIL', 'bn', N'ডাঃ {DoctorName}-এর সাথে {Date} তারিখে আপনার ভিডিও পরামর্শ', N'আপনার ভিডিও পরামর্শ', N'প্রিয় {PatientName},

আপনার ভিডিও পরামর্শ নিশ্চিত হয়েছে:

ডাক্তার: ডাঃ {DoctorName}
তারিখ: {Date}
সময়: {Time} থেকে {EndTime}{#GraceMinutes} (+{GraceMinutes} মিনিট অতিরিক্ত সময়){/GraceMinutes}

আপনার অ্যাপয়েন্টমেন্টে যোগ দিতে নিচের লিঙ্কে ক্লিক করুন:
{Link}

কীভাবে যোগ দেবেন:
১. নির্ধারিত সময়ে লিঙ্কে ক্লিক করুন।
২. আপনি একটি ওয়েটিং রুমে প্রবেশ করবেন।
৩. "Knock"-এ ক্লিক করুন, ডাক্তার আপনাকে ভিতরে নেবেন।
৪. কোনো সফটওয়্যার ডাউনলোড করতে হবে না - সরাসরি আপনার ব্রাউজারে চলে।'),
 ('CERTIFICATE', 'WHATSAPP', 'hi', NULL, NULL, N'प्रिय {PatientName}, आपका {CertificateType} नंबर {CertificateNo}, दिनांक {IssueDate}{#SignedBy}, {SignedBy} द्वारा हस्ताक्षरित{/SignedBy}, {HospitalName} द्वारा जारी, संलग्न है।{#VerifyUrl} इसे {VerifyUrl} पर सत्यापित किया जा सकता है।{/VerifyUrl} धन्यवाद।'),
 ('CERTIFICATE', 'EMAIL', 'hi', N'आपका {CertificateType} {CertificateNo} - {HospitalName}', N'{CertificateType}', N'प्रिय {PatientName}, आपका {CertificateType} नंबर {CertificateNo}, दिनांक {IssueDate}{#SignedBy}, {SignedBy} द्वारा हस्ताक्षरित{/SignedBy}, {HospitalName} द्वारा जारी, संलग्न है।{#VerifyUrl} इसे {VerifyUrl} पर सत्यापित किया जा सकता है।{/VerifyUrl} धन्यवाद।

आपका प्रमाणपत्र इस ईमेल के साथ PDF के रूप में संलग्न है। यह असली है, यह जाँचने के लिए इसका QR कोड स्कैन करें।'),
 ('CERTIFICATE', 'WHATSAPP', 'bn', NULL, NULL, N'প্রিয় {PatientName}, আপনার {CertificateType} নম্বর {CertificateNo}, তারিখ {IssueDate}{#SignedBy}, {SignedBy}-এর স্বাক্ষরিত{/SignedBy}, {HospitalName} দ্বারা জারি করা, সংযুক্ত করা হলো।{#VerifyUrl} এটি {VerifyUrl}-এ যাচাই করা যাবে।{/VerifyUrl} ধন্যবাদ।'),
 ('CERTIFICATE', 'EMAIL', 'bn', N'আপনার {CertificateType} {CertificateNo} - {HospitalName}', N'{CertificateType}', N'প্রিয় {PatientName}, আপনার {CertificateType} নম্বর {CertificateNo}, তারিখ {IssueDate}{#SignedBy}, {SignedBy}-এর স্বাক্ষরিত{/SignedBy}, {HospitalName} দ্বারা জারি করা, সংযুক্ত করা হলো।{#VerifyUrl} এটি {VerifyUrl}-এ যাচাই করা যাবে।{/VerifyUrl} ধন্যবাদ।

আপনার সার্টিফিকেট এই ইমেলের সাথে PDF হিসেবে সংযুক্ত করা হয়েছে। এটি আসল কিনা যাচাই করতে এর QR কোড স্ক্যান করুন।'),
 ('MEM_POINTS', 'WHATSAPP', 'hi', NULL, NULL, N'प्रिय {CardHolderName}, बिल {BillNo} के लिए आपके {HospitalName} सदस्यता कार्ड {CardNo} में {PointsEarned} पॉइंट (मूल्य रु. {PointsValue}) जोड़े गए हैं। अब आपका बैलेंस {PointsBalance} पॉइंट (रु. {BalanceValue}) है। ये पॉइंट {ExpiryDate} तक मान्य हैं। धन्यवाद!'),
 ('MEM_POINTS', 'WHATSAPP', 'bn', NULL, NULL, N'প্রিয় {CardHolderName}, বিল {BillNo}-এর জন্য আপনার {HospitalName} সদস্যপদ কার্ড {CardNo}-এ {PointsEarned} পয়েন্ট (মূল্য ₹{PointsValue}) যোগ করা হয়েছে। এখন আপনার ব্যালেন্স {PointsBalance} পয়েন্ট (₹{BalanceValue})। এই পয়েন্টগুলি {ExpiryDate} পর্যন্ত বৈধ। ধন্যবাদ!'),
 ('MEM_CARD', 'WHATSAPP', 'hi', NULL, NULL, N'प्रिय {PatientName}, {HospitalName} की {PlanName} सदस्यता में आपका स्वागत है। आपका कार्ड नंबर {CardNo} है, जो {ValidFrom} से {ValidTo} तक मान्य है। आपका सदस्यता कार्ड संलग्न है।'),
 ('MEM_CARD', 'EMAIL', 'hi', N'आपका {PlanName} सदस्यता कार्ड - {HospitalName}', N'आपका सदस्यता कार्ड', N'प्रिय {PatientName}, {HospitalName} की {PlanName} सदस्यता में आपका स्वागत है। आपका कार्ड नंबर {CardNo} है, जो {ValidFrom} से {ValidTo} तक मान्य है। आपका सदस्यता कार्ड संलग्न है।

कार्ड नंबर: {CardNo}
प्लान: {PlanName}
मान्य: {ValidFrom} से {ValidTo}

आपका सदस्यता कार्ड इस ईमेल के साथ PDF के रूप में संलग्न है।'),
 ('MEM_CARD', 'WHATSAPP', 'bn', NULL, NULL, N'প্রিয় {PatientName}, {HospitalName}-এর {PlanName} সদস্যপদে আপনাকে স্বাগত। আপনার কার্ড নম্বর {CardNo}, {ValidFrom} থেকে {ValidTo} পর্যন্ত বৈধ। আপনার সদস্যপদ কার্ড সংযুক্ত করা হলো।'),
 ('MEM_CARD', 'EMAIL', 'bn', N'আপনার {PlanName} সদস্যপদ কার্ড - {HospitalName}', N'আপনার সদস্যপদ কার্ড', N'প্রিয় {PatientName}, {HospitalName}-এর {PlanName} সদস্যপদে আপনাকে স্বাগত। আপনার কার্ড নম্বর {CardNo}, {ValidFrom} থেকে {ValidTo} পর্যন্ত বৈধ। আপনার সদস্যপদ কার্ড সংযুক্ত করা হলো।

কার্ড নম্বর: {CardNo}
প্ল্যান: {PlanName}
বৈধ: {ValidFrom} থেকে {ValidTo}

আপনার সদস্যপদ কার্ড এই ইমেলের সাথে PDF হিসেবে সংযুক্ত করা হয়েছে।'),
 ('MEM_RENEWAL', 'EMAIL', 'hi', N'आपकी {PlanName} सदस्यता {#Today}आज{/Today}{^Today}{DaysLeft} दिन में{/Today} समाप्त हो रही है - {HospitalName}', N'{#Today}आपकी सदस्यता आज समाप्त हो रही है{/Today}{^Today}आपकी सदस्यता के नवीनीकरण का समय आ गया है{/Today}', N'प्रिय {PatientName}, {HospitalName} पर आपका {PlanName} सदस्यता कार्ड {CardNo} {#Today}आज{/Today}{^Today}{DaysLeft} दिन में{/Today}, {ValidTo} को समाप्त हो रहा है। अपने लाभ बनाए रखने और अपने {Points} पॉइंट नए कार्ड में आगे ले जाने के लिए इसे हमारे किसी भी केंद्र पर नवीनीकृत कराएँ।

कार्ड नंबर: {CardNo}
प्लान: {PlanName}
मान्य: {ValidTo} तक
पॉइंट बैलेंस: {Points}'),
 ('MEM_RENEWAL', 'EMAIL', 'bn', N'আপনার {PlanName} সদস্যপদের মেয়াদ {#Today}আজ{/Today}{^Today}{DaysLeft} দিনের মধ্যে{/Today} শেষ হচ্ছে - {HospitalName}', N'{#Today}আপনার সদস্যপদের মেয়াদ আজ শেষ হচ্ছে{/Today}{^Today}আপনার সদস্যপদ নবীকরণের সময় হয়েছে{/Today}', N'প্রিয় {PatientName}, {HospitalName}-এ আপনার {PlanName} সদস্যপদ কার্ড {CardNo}-এর মেয়াদ {#Today}আজ{/Today}{^Today}{DaysLeft} দিনের মধ্যে{/Today}, {ValidTo} তারিখে শেষ হচ্ছে। আপনার সুবিধাগুলি বজায় রাখতে এবং আপনার {Points} পয়েন্ট নতুন কার্ডে নিয়ে যেতে আমাদের যেকোনো কেন্দ্রে এটি নবীকরণ করুন।

কার্ড নম্বর: {CardNo}
প্ল্যান: {PlanName}
বৈধ: {ValidTo} পর্যন্ত
পয়েন্ট ব্যালেন্স: {Points}'),
 ('PH_BILL', 'WHATSAPP', 'hi', NULL, NULL, N'प्रिय {CustomerName}, {PharmacyName} से ख़रीदारी के लिए धन्यवाद। आपका बिल {BillNo}, राशि ₹{Amount}, दिनांक {BillDate}, संलग्न है।'),
 ('PH_BILL', 'EMAIL', 'hi', N'आपका फ़ार्मेसी बिल {BillNo} - {PharmacyName}', N'फ़ार्मेसी बिल', N'प्रिय {CustomerName}, {PharmacyName} से ख़रीदारी के लिए धन्यवाद। आपका बिल {BillNo}, राशि ₹{Amount}, दिनांक {BillDate}, संलग्न है।

बिल नंबर: {BillNo}
दिनांक: {BillDate}
राशि: ₹{Amount}'),
 ('PH_BILL', 'WHATSAPP', 'bn', NULL, NULL, N'প্রিয় {CustomerName}, {PharmacyName} থেকে কেনাকাটার জন্য ধন্যবাদ। আপনার বিল {BillNo}, মোট ₹{Amount}, তারিখ {BillDate}, সংযুক্ত করা হলো।'),
 ('PH_BILL', 'EMAIL', 'bn', N'আপনার ফার্মেসি বিল {BillNo} - {PharmacyName}', N'ফার্মেসি বিল', N'প্রিয় {CustomerName}, {PharmacyName} থেকে কেনাকাটার জন্য ধন্যবাদ। আপনার বিল {BillNo}, মোট ₹{Amount}, তারিখ {BillDate}, সংযুক্ত করা হলো।

বিল নম্বর: {BillNo}
তারিখ: {BillDate}
পরিমাণ: ₹{Amount}'),
 ('PH_LOYALTY', 'WHATSAPP', 'hi', NULL, NULL, N'नमस्ते{#CustomerName} {CustomerName}{/CustomerName},

आपकी ख़रीदारी के लिए धन्यवाद (बिल {BillNo}, ₹{Amount})।
{#Discount}⭐ लॉयल्टी सदस्य के रूप में आपने इस बिल पर *₹{Discount}* बचाए।
{/Discount}{#PointsUsed}उपयोग किए गए पॉइंट: *{PointsUsed}*
{/PointsUsed}{#PointsEarned}⭐ *{PointsEarned} पॉइंट* (₹{PointsEarnedValue}) आपके वॉलेट में जमा किए गए{#UsableFrom} - {UsableFrom} से उपयोग किए जा सकते हैं{/UsableFrom}।
{/PointsEarned}{#Wallet}वॉलेट बैलेंस: *{WalletPoints} पॉइंट* (₹{WalletValue}), अगले बिल पर उपयोग के लिए{#Pending}; {Pending} और पॉइंट जल्द जुड़ेंगे{/Pending}।
{/Wallet}
- {PharmacyName}'),
 ('PH_LOYALTY', 'WHATSAPP', 'bn', NULL, NULL, N'নমস্কার{#CustomerName} {CustomerName}{/CustomerName},

আপনার কেনাকাটার জন্য ধন্যবাদ (বিল {BillNo}, ₹{Amount})।
{#Discount}⭐ লয়্যালটি সদস্য হিসেবে আপনি এই বিলে *₹{Discount}* সাশ্রয় করেছেন।
{/Discount}{#PointsUsed}ব্যবহৃত পয়েন্ট: *{PointsUsed}*
{/PointsUsed}{#PointsEarned}⭐ *{PointsEarned} পয়েন্ট* (₹{PointsEarnedValue}) আপনার ওয়ালেটে জমা হয়েছে{#UsableFrom} - {UsableFrom} থেকে ব্যবহার করা যাবে{/UsableFrom}।
{/PointsEarned}{#Wallet}ওয়ালেট ব্যালেন্স: *{WalletPoints} পয়েন্ট* (₹{WalletValue}), পরের বিলে ব্যবহারের জন্য{#Pending}; আরও {Pending} পয়েন্ট শীঘ্রই যোগ হবে{/Pending}।
{/Wallet}
- {PharmacyName}'),
 ('PH_REFILL', 'WHATSAPP', 'hi', NULL, NULL, N'नमस्ते{#CustomerName} {CustomerName}{/CustomerName},

आपकी दवा *{ItemName}* (बिल {BillNo}) {RunOutDate} को ख़त्म होने वाली है। कृपया समय पर दोबारा लें - डॉक्टर से पूछे बिना कोई दवा बंद न करें।{#PharmacyPhone}
दवा तैयार रखवाने के लिए {PharmacyPhone} पर कॉल करें।{/PharmacyPhone}

- {PharmacyName}'),
 ('PH_REFILL', 'WHATSAPP', 'bn', NULL, NULL, N'নমস্কার{#CustomerName} {CustomerName}{/CustomerName},

আপনার ওষুধ *{ItemName}* (বিল {BillNo}) {RunOutDate} তারিখে শেষ হয়ে যাবে। অনুগ্রহ করে সময়মতো আবার নিন - ডাক্তারকে জিজ্ঞাসা না করে কোনো ওষুধ বন্ধ করবেন না।{#PharmacyPhone}
ওষুধ তৈরি রাখতে {PharmacyPhone} নম্বরে কল করুন।{/PharmacyPhone}

- {PharmacyName}'),
 ('PH_WALLET_EXPIRY', 'WHATSAPP', 'hi', NULL, NULL, N'नमस्ते{#CustomerName} {CustomerName}{/CustomerName},

आपके वॉलेट के *{Points} लॉयल्टी पॉइंट* (₹{PointsValue}) {ExpiresOn} को समाप्त हो रहे हैं। इन्हें अपनी अगली ख़रीदारी पर उपयोग करें।
वॉलेट बैलेंस: {Available} पॉइंट।

- {PharmacyName}'),
 ('PH_WALLET_EXPIRY', 'WHATSAPP', 'bn', NULL, NULL, N'নমস্কার{#CustomerName} {CustomerName}{/CustomerName},

আপনার ওয়ালেটের *{Points} লয়্যালটি পয়েন্ট* (₹{PointsValue})-এর মেয়াদ {ExpiresOn} তারিখে শেষ হবে। আপনার পরের কেনাকাটায় এগুলি ব্যবহার করুন।
ওয়ালেট ব্যালেন্স: {Available} পয়েন্ট।

- {PharmacyName}'),
 ('PORTAL_LOGIN', 'WHATSAPP', 'hi', NULL, NULL, N'{HospitalName} - मरीज़ पोर्टल
मरीज़ आईडी: {PatientCode}
पासवर्ड: {Password}{#PortalUrl}
साइन इन: {PortalUrl}{/PortalUrl}
पहली बार साइन इन करने पर आपसे अपना पासवर्ड चुनने को कहा जाएगा।'),
 ('PORTAL_LOGIN', 'EMAIL', 'hi', N'{#Reset}{HospitalName} - मरीज़ पोर्टल पासवर्ड रीसेट{/Reset}{^Reset}{HospitalName} में आपका स्वागत है - आपके लॉगिन विवरण{/Reset}', N'{#Reset}आपका मरीज़ पोर्टल पासवर्ड{/Reset}{^Reset}{HospitalName} में आपका स्वागत है{/Reset}', N'प्रिय {PatientName},

{#Reset}आपका मरीज़ पोर्टल पासवर्ड रीसेट कर दिया गया है। साइन इन करने के लिए नीचे दिए गए विवरण का उपयोग करें।{/Reset}{^Reset}हमारे साथ पंजीकरण के लिए धन्यवाद! हमने आपके लिए एक सुरक्षित मरीज़ पोर्टल खाता बनाया है। इससे आप अपने स्वास्थ्य रिकॉर्ड देख सकते हैं और हमारी देखभाल टीम से जुड़े रह सकते हैं।{/Reset}

मरीज़ आईडी: {PatientCode}
पासवर्ड: {Password}{#PortalUrl}
यहाँ साइन इन करें: {PortalUrl}{/PortalUrl}

अपनी मरीज़ आईडी से साइन इन करें। पहली बार साइन इन करने पर आपसे अपना पासवर्ड चुनने को कहा जाएगा।

सादर,
{HospitalName}'),
 ('PORTAL_LOGIN', 'WHATSAPP', 'bn', NULL, NULL, N'{HospitalName} - রোগী পোর্টাল
রোগীর আইডি: {PatientCode}
পাসওয়ার্ড: {Password}{#PortalUrl}
সাইন ইন: {PortalUrl}{/PortalUrl}
প্রথমবার সাইন ইন করার সময় আপনাকে নিজের পাসওয়ার্ড বেছে নিতে বলা হবে।'),
 ('PORTAL_LOGIN', 'EMAIL', 'bn', N'{#Reset}{HospitalName} - রোগী পোর্টালের পাসওয়ার্ড রিসেট{/Reset}{^Reset}{HospitalName}-এ আপনাকে স্বাগত - আপনার লগইন বিবরণ{/Reset}', N'{#Reset}আপনার রোগী পোর্টালের পাসওয়ার্ড{/Reset}{^Reset}{HospitalName}-এ আপনাকে স্বাগত{/Reset}', N'প্রিয় {PatientName},

{#Reset}আপনার রোগী পোর্টালের পাসওয়ার্ড রিসেট করা হয়েছে। সাইন ইন করতে নিচের বিবরণ ব্যবহার করুন।{/Reset}{^Reset}আমাদের সাথে নিবন্ধনের জন্য ধন্যবাদ! আমরা আপনার জন্য একটি সুরক্ষিত রোগী পোর্টাল অ্যাকাউন্ট তৈরি করেছি। এর মাধ্যমে আপনি আপনার স্বাস্থ্য রেকর্ড দেখতে এবং আমাদের পরিচর্যা দলের সাথে যুক্ত থাকতে পারবেন।{/Reset}

রোগীর আইডি: {PatientCode}
পাসওয়ার্ড: {Password}{#PortalUrl}
এখানে সাইন ইন করুন: {PortalUrl}{/PortalUrl}

আপনার রোগীর আইডি দিয়ে সাইন ইন করুন। প্রথমবার সাইন ইন করার সময় আপনাকে নিজের পাসওয়ার্ড বেছে নিতে বলা হবে।

শুভেচ্ছা সহ,
{HospitalName}');
INSERT dbo.NotifyTemplate (CompanyId, BranchId, EventCode, Channel, LanguageId, Subject, Heading, Body)
SELECT c.CompanyId, NULL, x.EventCode, x.Channel, l.LanguageId, x.Subject, x.Heading, x.Body
FROM @t x JOIN dbo.LanguageMaster l ON l.LanguageCode = x.Lang CROSS JOIN dbo.CompanyMaster c
WHERE c.IsActive = 1 AND NOT EXISTS (SELECT 1 FROM dbo.NotifyTemplate n WHERE n.CompanyId = c.CompanyId AND n.BranchId IS NULL AND n.EventCode = x.EventCode
                                     AND n.Channel = x.Channel AND n.LanguageId = l.LanguageId);
GO

-- the page shows the English reference of each notification
CREATE OR ALTER PROCEDURE dbo.usp_Api_NotifyTemplate_Lookups @CompanyId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT EventCode, Module, Name, Channels, Placeholders, Description, RefWhatsApp, RefEmailSubject, RefEmailHeading, RefEmailBody
    FROM dbo.NotifyEvent WHERE IsActive = 1 ORDER BY SortOrder, Name;
    SELECT LanguageId, LanguageName, LanguageCode FROM dbo.LanguageMaster WHERE IsActive = 1 ORDER BY CASE WHEN LanguageCode = 'en' THEN 0 ELSE 1 END, LanguageName;
    SELECT BranchID AS BranchId, BranchName FROM dbo.BranchMaster WHERE CompanyId = @CompanyId AND ISNULL(IsActive, 1) = 1 ORDER BY BranchName;
END
GO
PRINT 'Script 2544 applied: every patient message in the patient''s language (Hindi / Bengali texts).';
GO
