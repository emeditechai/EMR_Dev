// moved from Views/HospitalSettings/Edit.cshtml (inline <script>) - EMR.Web string-literal limit (CS8103)
                    (function () {
                        const t = document.getElementById('loyType'), help = document.getElementById('loyTypeHelp');
                        const sync = () => {
                            const d = t.value === 'DISCOUNT';
                            document.querySelectorAll('.loy-pts').forEach(e => e.classList.toggle('d-none', d));
                            document.querySelectorAll('.loy-disc').forEach(e => e.classList.toggle('d-none', !d));
                            help.textContent = d ? 'The member gets the % off at once; nothing goes to a wallet.' : 'Points go to the member\'s wallet and are used on a later bill (like health credits).';
                        };
                        t.addEventListener('change', sync); sync();
                    })();
                
