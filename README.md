# claude-alerte-vocale

Alerte vocale în română pentru **Claude Code** și **Claude Cowork**, pe Windows. Când Claude termină sau are nevoie de tine, auzi o voce și apare o fereastră mică în colțul de jos al ecranului. Fereastra stă deasupra celorlalte și nu îți fură focusul.

| Când | Claude Code (stânga jos, vocea Emil) | Cowork (dreapta jos, vocea Alina) |
|---|---|---|
| a terminat | M-am terminat! | Și eu m-am terminat! |
| cere permisiune sau un răspuns | Am nevoie de tine! | Și eu am nevoie de tine! |

Vocea se repetă la 5 secunde, cel mult 5 minute. Alertele Claude Code și Cowork sunt independente și pot suna în același timp.

## Cerințe

- Windows 10 sau 11
- Claude Code (pentru alertele Claude Code)
- aplicația desktop Claude (pentru alertele Cowork)
- internet la instalare (vocile se generează cu edge-tts)

Python, edge-tts și ffmpeg se instalează automat dacă lipsesc (prin winget și pip).

## Instalare

**Varianta a) în Claude Code.** Scrie-i:

```
Instalează alertele din https://github.com/dragoslavflorin-ux/claude-alerte-vocale urmând README-ul
```

**Varianta b) în PowerShell:**

```powershell
git clone https://github.com/dragoslavflorin-ux/claude-alerte-vocale.git "$env:USERPROFILE\claude-alerte-vocale"
cd "$env:USERPROFILE\claude-alerte-vocale"
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

Opțiuni: `-DoarClaudeCode`, `-DoarCowork`, `-FaraVerificare`.

Instalarea:
- copiază scripturile în `%USERPROFILE%\.claude\hooks\`;
- face backup la `settings.json` și adaugă hook-urile, fără să atingă alte setări;
- creează scurtătura de oprire cu tasta Ctrl+Alt+M pe Desktop;
- pune watcher-ul Cowork la pornirea automată și îl pornește;
- la final, pornește fiecare alertă câteva secunde, verifică poziția ferestrei și oprirea, apoi afișează un rezumat.

După instalare, închide și redeschide sesiunile Claude Code deschise.

### Ca să meargă detecția Cowork

Watcher-ul citește lista de conversații din aplicația desktop Claude. Pentru asta trebuie ca:
1. aplicația Claude să fie pornită, cu fereastra deschisă (poate sta în spate, dar nu închisă în tray);
2. interfața aplicației să fie în limba engleză;
3. conversațiile Cowork să se vadă în bara laterală.

Cât timp aplicația Claude e fereastra activă, alerta Cowork nu sună. Nu e nevoie să activezi notificările din aplicația Claude.

## Personalizare

Modifici `config.json`, apoi rulezi din nou `install.ps1`. Poți schimba:
- textele celor 4 alerte;
- vocile (de exemplu `ro-RO-EmilNeural`, `ro-RO-AlinaNeural`);
- titlul și poziția ferestrei (`Stanga` sau `Dreapta`);
- `pauza_secunde`: pauza dintre repetări;
- `limita_secunde`: după cât timp se oprește singură alerta;
- `margine_px`: distanța ferestrei față de marginea ecranului;
- `hotkey`: tasta de oprire (de exemplu `Ctrl+Alt+M`).

Vocile se generează din nou doar pentru textele sau vocile schimbate.

## Oprirea unei alerte

- click oriunde pe fereastră;
- Ctrl+Alt+M oprește toate alertele, Claude Code și Cowork;
- Claude Code: alerta se oprește singură când scrii un mesaj nou sau Claude continuă lucrul;
- Cowork: alerta se oprește singură când aduci aplicația Claude în față;
- după limita din config (implicit 5 minute).

Pentru o verificare manuală:

```powershell
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.claude\hooks\verifica-alerte.ps1"
```

Logul watcher-ului Cowork e în `%USERPROFILE%\.claude\hooks\cowork\watch.log`.

## Actualizare

```powershell
cd "$env:USERPROFILE\claude-alerte-vocale"
git pull
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

## Dezinstalare

```powershell
cd "$env:USERPROFILE\claude-alerte-vocale"
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
```

Scoate hook-urile, fișierele, scurtătura și pornirea automată, și lasă restul setărilor neatins.

## Licență

MIT
