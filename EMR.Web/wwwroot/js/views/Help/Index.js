// moved from Views/Help/Index.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
    if (document.getElementById('hpAsk')) HelpAssistant.mount(document.getElementById('hpAsk'), {
        big: true,
        suggestions: ['After creating a B2C bill, what is next?', 'What comes before sample collection?', 'Show the LAB workflow', 'How do I cancel a LAB bill?',
                      'Sample not showing in lab reporting', 'After adding a test, what next?', 'Send an email to all patients']
    }).focus();
