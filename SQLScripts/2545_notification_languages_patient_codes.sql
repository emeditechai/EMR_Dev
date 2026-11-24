-- ============================================================================================================
-- 2545 - Notification languages: the one-time codes sent to patients (after 2543, 2544)
-- Membership points redemption OTP (LAB billing), pharmacy loyalty points OTP, patient app verification / reset code,
-- home sample collection code - in the patient's language (PatientMaster.LanguageId). English stays exactly as today.
-- Re-runnable: existing texts are never overwritten (only missing ones are added).
-- ============================================================================================================
SET NOCOUNT ON;
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

MERGE dbo.NotifyEvent AS t
USING (VALUES
 ('MEM_REDEEM_OTP', 'MEMBERSHIP', N'Membership points redemption OTP', 'WHATSAPP,EMAIL', N'{CardHolderName},{Points},{PointsValue},{CardNo},{Code}', N'The one-time code the card holder gets to redeem membership points at the LAB billing counter: WhatsApp and e-mail.', 85, N'Dear {CardHolderName}, your OTP to redeem {Points} membership points (Rs {PointsValue}) on card {CardNo} is {Code}. It is valid for 10 minutes. Do not share it with anyone except the billing counter.', N'OTP to redeem membership points - card {CardNo}', N'Your membership OTP', N'Dear {CardHolderName},

Your OTP to redeem {Points} points (Rs {PointsValue}) on membership card {CardNo} is:

{Code}

It is valid for 10 minutes. Do not share it with anyone except the billing counter.'),
 ('PH_LOYALTY_OTP', 'PHARMACY', N'Pharmacy loyalty points OTP', 'WHATSAPP', N'{PharmacyName},{Code}', N'The one-time code the customer gets to use wallet / loyalty points on a pharmacy bill: WhatsApp.', 96, N'Your OTP to use loyalty points at {PharmacyName} is *{Code}*. It is valid for 10 minutes. Do not share it with anyone else.', NULL, NULL, NULL),
 ('PATIENT_APP_OTP', 'PATIENT', N'Patient app verification / reset code', 'WHATSAPP', N'{PatientName},{Code},{Minutes},{Reset}', N'The code the patient app sends to verify the patient or reset the password: WhatsApp.', 115, N'{#Reset}Dear {PatientName}, your eCare360Plus patient app password reset code is {Code}. It is valid for {Minutes} minutes. Do not share it with anyone.{/Reset}{^Reset}Dear {PatientName}, your eCare360Plus patient app verification code is {Code}. Enter it in the app to set your password. It is valid for {Minutes} minutes. Do not share it with anyone.{/Reset}', NULL, NULL, NULL),
 ('HOME_COLLECTION_OTP', 'LAB', N'Home sample collection code', 'WHATSAPP', N'{PatientName},{Code},{Minutes}', N'The code the patient shares with the phlebotomist at a home sample collection: WhatsApp.', 25, N'Dear {PatientName}, your home sample collection code is {Code}. Share it with the phlebotomist at your door. It is valid for {Minutes} minutes.', NULL, NULL, NULL)
) s (EventCode, Module, Name, Channels, Placeholders, Description, SortOrder, RefWhatsApp, RefEmailSubject, RefEmailHeading, RefEmailBody)
ON t.EventCode = s.EventCode
WHEN MATCHED THEN UPDATE SET Module = s.Module, Name = s.Name, Channels = s.Channels, Placeholders = s.Placeholders, Description = s.Description, SortOrder = s.SortOrder,
    RefWhatsApp = s.RefWhatsApp, RefEmailSubject = s.RefEmailSubject, RefEmailHeading = s.RefEmailHeading, RefEmailBody = s.RefEmailBody, IsActive = 1
WHEN NOT MATCHED THEN INSERT (EventCode, Module, Name, Channels, Placeholders, Description, SortOrder, RefWhatsApp, RefEmailSubject, RefEmailHeading, RefEmailBody)
    VALUES (s.EventCode, s.Module, s.Name, s.Channels, s.Placeholders, s.Description, s.SortOrder, s.RefWhatsApp, s.RefEmailSubject, s.RefEmailHeading, s.RefEmailBody);
GO

DECLARE @t TABLE (EventCode VARCHAR(40), Channel VARCHAR(10), Lang VARCHAR(10), Subject NVARCHAR(300), Heading NVARCHAR(200), Body NVARCHAR(MAX));
INSERT @t VALUES
 ('MEM_REDEEM_OTP', 'WHATSAPP', 'hi', NULL, NULL, N'प्रिय {CardHolderName}, कार्ड {CardNo} पर {Points} मेंबरशिप पॉइंट (रु. {PointsValue}) रिडीम करने के लिए आपका OTP {Code} है। यह 10 मिनट के लिए मान्य है। इसे बिलिंग काउंटर के अलावा किसी और के साथ साझा न करें।'),
 ('MEM_REDEEM_OTP', 'EMAIL', 'hi', N'मेंबरशिप पॉइंट रिडीम करने के लिए OTP - कार्ड {CardNo}', N'आपका मेंबरशिप OTP', N'प्रिय {CardHolderName},

मेंबरशिप कार्ड {CardNo} पर {Points} पॉइंट (रु. {PointsValue}) रिडीम करने के लिए आपका OTP है:

{Code}

यह 10 मिनट के लिए मान्य है। इसे बिलिंग काउंटर के अलावा किसी और के साथ साझा न करें।'),
 ('MEM_REDEEM_OTP', 'WHATSAPP', 'bn', NULL, NULL, N'প্রিয় {CardHolderName}, কার্ড {CardNo}-এ {Points} মেম্বারশিপ পয়েন্ট (₹{PointsValue}) রিডিম করার জন্য আপনার OTP হল {Code}। এটি 10 মিনিটের জন্য বৈধ। বিলিং কাউন্টার ছাড়া অন্য কারও সাথে এটি শেয়ার করবেন না।'),
 ('MEM_REDEEM_OTP', 'EMAIL', 'bn', N'মেম্বারশিপ পয়েন্ট রিডিম করার OTP - কার্ড {CardNo}', N'আপনার মেম্বারশিপ OTP', N'প্রিয় {CardHolderName},

মেম্বারশিপ কার্ড {CardNo}-এ {Points} পয়েন্ট (₹{PointsValue}) রিডিম করার জন্য আপনার OTP হল:

{Code}

এটি 10 মিনিটের জন্য বৈধ। বিলিং কাউন্টার ছাড়া অন্য কারও সাথে এটি শেয়ার করবেন না।'),
 ('PH_LOYALTY_OTP', 'WHATSAPP', 'hi', NULL, NULL, N'{PharmacyName} पर लॉयल्टी पॉइंट इस्तेमाल करने के लिए आपका OTP *{Code}* है। यह 10 मिनट के लिए मान्य है। इसे किसी और के साथ साझा न करें।'),
 ('PH_LOYALTY_OTP', 'WHATSAPP', 'bn', NULL, NULL, N'{PharmacyName}-এ লয়্যালটি পয়েন্ট ব্যবহার করার জন্য আপনার OTP হল *{Code}*। এটি 10 মিনিটের জন্য বৈধ। এটি অন্য কারও সাথে শেয়ার করবেন না।'),
 ('PATIENT_APP_OTP', 'WHATSAPP', 'hi', NULL, NULL, N'{#Reset}प्रिय {PatientName}, आपके eCare360Plus पेशेंट ऐप का पासवर्ड रीसेट कोड {Code} है। यह {Minutes} मिनट के लिए मान्य है। इसे किसी के साथ साझा न करें।{/Reset}{^Reset}प्रिय {PatientName}, आपके eCare360Plus पेशेंट ऐप का वेरिफ़िकेशन कोड {Code} है। अपना पासवर्ड सेट करने के लिए इसे ऐप में डालें। यह {Minutes} मिनट के लिए मान्य है। इसे किसी के साथ साझा न करें।{/Reset}'),
 ('PATIENT_APP_OTP', 'WHATSAPP', 'bn', NULL, NULL, N'{#Reset}প্রিয় {PatientName}, আপনার eCare360Plus পেশেন্ট অ্যাপের পাসওয়ার্ড রিসেট কোড হল {Code}। এটি {Minutes} মিনিটের জন্য বৈধ। এটি কারও সাথে শেয়ার করবেন না।{/Reset}{^Reset}প্রিয় {PatientName}, আপনার eCare360Plus পেশেন্ট অ্যাপের ভেরিফিকেশন কোড হল {Code}। আপনার পাসওয়ার্ড সেট করতে অ্যাপে এটি লিখুন। এটি {Minutes} মিনিটের জন্য বৈধ। এটি কারও সাথে শেয়ার করবেন না।{/Reset}'),
 ('HOME_COLLECTION_OTP', 'WHATSAPP', 'hi', NULL, NULL, N'प्रिय {PatientName}, घर से सैंपल कलेक्शन के लिए आपका कोड {Code} है। इसे अपने दरवाज़े पर आए फ्लेबोटोमिस्ट को बताएँ। यह {Minutes} मिनट के लिए मान्य है।'),
 ('HOME_COLLECTION_OTP', 'WHATSAPP', 'bn', NULL, NULL, N'প্রিয় {PatientName}, বাড়ি থেকে নমুনা সংগ্রহের জন্য আপনার কোড হল {Code}। আপনার দরজায় আসা ফ্লেবোটোমিস্টকে এটি জানান। এটি {Minutes} মিনিটের জন্য বৈধ।');
INSERT dbo.NotifyTemplate (CompanyId, BranchId, EventCode, Channel, LanguageId, Subject, Heading, Body)
SELECT c.CompanyId, NULL, x.EventCode, x.Channel, l.LanguageId, x.Subject, x.Heading, x.Body
FROM @t x JOIN dbo.LanguageMaster l ON l.LanguageCode = x.Lang CROSS JOIN dbo.CompanyMaster c
WHERE c.IsActive = 1 AND NOT EXISTS (SELECT 1 FROM dbo.NotifyTemplate n WHERE n.CompanyId = c.CompanyId AND n.BranchId IS NULL AND n.EventCode = x.EventCode
                                     AND n.Channel = x.Channel AND n.LanguageId = l.LanguageId);
GO

PRINT 'Script 2545 applied: patient one-time codes in the patient''s language.';
GO
