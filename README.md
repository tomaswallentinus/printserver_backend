# Printserver (CUPS) – verktyg & städning

Det här projektet innehåller ett enkelt hanteringsskript samt ett antal Python-skript som pratar med CUPS (via pycups) för att:

- lista jobb och deras ålder
- släppa/ta bort jobb (t.ex. held/followme)
- rensa fastnade jobb som blockerar köer

## Innehåll

- `servicectl.sh`: interaktiv meny för drift/åtgärder (CUPS/Avahi, kö-åtgärder, städ-jobb).
- `scripts/`: pythonverktyg som använder `cups` (pycups).

## Krav

- **CUPS** installerat och igång.
- **Python 3**.
- **pycups** (Python-modulen `cups`).
- **sqlite3** (CLI-verktyg) för VLAN-databasen i `servicectl.sh`.
- För e-postnotiser: **lokal MTA** med `sendmail` (t.ex. Postfix/Exim) eller kompatibelt `sendmail`-kommando.

## Installera servern (manuell)

Exempel för Ubuntu/Debian:

1) Installera paket:

```bash
sudo apt update
sudo apt install -y cups python3 python3-pip python3-cups sqlite3 postfix
```

`cups-browsed` är **valfritt** och behövs främst för auto-upptäckt av nätverksskrivare:

```bash
sudo apt install -y cups-browsed
```

2) Skapa lokal miljöfil för webservice:

```bash
cat > /srv/printserver/.env <<'EOF'
API_TOKEN=<ditt_losenord>
EOF
```

3) Aktivera och starta tjänster:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now cups printapi.service
```

Om `cups-browsed` används:

```bash
sudo systemctl enable --now cups-browsed
```

4) Verifiera installationen:

```bash
sudo systemctl status cups --no-pager
sudo systemctl status printapi.service --no-pager
sudo journalctl -u printapi.service -n 100 --no-pager
ss -lntp | grep :5000
```

Kontrollera även att CUPS-webben svarar och att `servicectl.sh` fungerar:

```bash
bash /srv/printserver/servicectl.sh
```

## servicectl.sh

Kör:

```bash
bash /srv/printserver/servicectl.sh
```

Menyval:

- **1) Starta om CUPS**: startar om CUPS-tjänsten.
- **2) Starta om Avahi**: startar om Avahi-tjänsten.
- **3) Visa aktiva skrivare**: visar installerade skrivare och default-skrivare.
- **4) Visa status för alla köer**: visar detaljerad köstatus.
- **5) Debug/log (senaste 50 raderna)**: visar senaste CUPS-loggar.
- **6) Sätt Duplex + Shared på alla skrivare**: sätter duplex och delning på samtliga köer.
- **7) Tömma en skrivares kö**: avbryter alla jobb i vald kö.
- **8) Aktivera skrivare (ta bort paus)**: aktiverar pausad/disabled skrivare.
- **9) Visa pågående jobb (ålder i kö)**: kör `scripts/list_jobs_with_age.py` (via sudo).
- **10) Lägg till ny skrivare**: skapar ny CUPS-kö och kopplar standard-VLAN enligt skrivartyp.
- **11) Rensa fastnade jobb (DRY_RUN)**: kör `scripts/purge_stuck_jobs.py` utan att radera.
- **12) Rensa fastnade jobb (SKARPT)**: kör `scripts/purge_stuck_jobs.py` och raderar jobb (kräver bekräftelse).
- **13) Byt skrivare till IPP Everywhere**: försöker byta modell från raw till IPP Everywhere.
- **14) Hantera VLAN-katalog**: lägg till/ändra/ta bort VLAN (namn + CIDR) i lokal databas.
- **15) Koppla VLAN till skrivare**: välj vilka VLAN en enskild skrivare ska tillåta.
- **16) Ta bort VLAN från skrivare**: ta bort en VLAN-koppling för vald skrivare.
- **17) Visa VLAN-kopplingar för skrivare**: visa vilka VLAN vald skrivare är kopplad till.
- **18) Importera/synka från cupsd.conf**: läser `Allow from ...` ur CUPS Location-block och importerar till databasen.
- **q) Avsluta**: stänger menyn.

### VLAN-databas (lokal, auto-skapas)

`servicectl.sh` använder en lokal SQLite-databas för VLAN-hantering per skrivare:

- Databasfil: `/srv/printserver/data/vlans.db`
- Skapas automatiskt om den saknas när VLAN-funktioner används.
- Datamodell:
  - `vlans` (namn + CIDR)
  - `printer_vlans` (koppling mellan skrivare och VLAN)

När VLAN kopplas/ändras/tas bort för en skrivare regenereras motsvarande `<Location /printers/...>`-block i `/etc/cups/cupsd.conf` automatiskt.

## Städning av fastnade jobb (viktigast)

### `scripts/purge_stuck_jobs.py`

Syfte: Ta bort **ej-klara** jobb (pending/held/processing/stopped) som är äldre än en timeout och som annars kan blockera efterföljande jobb.

- **Åldersberäkning**: För jobb som visar "processing since ..." används CUPS-attributet `time-at-processing` (hur länge jobbet legat i processing). Övriga jobb mäts från `time-at-creation`. Det säkerställer att jobb som fastnat i processing rensas efter timeout.
- **Exkluderar alltid** kön `FollowMe`.
- Timeout per kö:
  - `SalA214` och `KunskapensHav`: **5 minuter**
  - Övriga köer: **20 minuter**
- E-postnotis:
  - Skickas **endast** om `job-originating-user-name` innehåller en punkt (`.`).
  - Mottagare:
    - om kö är `SalA214` eller `KunskapensHav`: `<username>@student.tabyenskilda.se`
    - annars: `<username>@tabyenskilda.se`
- **Avpausning**: Sist i körningen kontrollerar skriptet om någon skrivare är pausad/disabled; i så fall avpausas den med `cupsenable` så att köer inte förblir blockerade. Sker endast när `DRY_RUN=0`.

Skriptet körs vanligtvis via **sudo crontab** (root) så att alla användares jobb kan rensas och skrivare kan avpausas.

### Test (utan att radera)

```bash
sudo env DRY_RUN=1 python3 /srv/printserver/scripts/purge_stuck_jobs.py
```

### Skarpt läge

```bash
sudo env DRY_RUN=0 python3 /srv/printserver/scripts/purge_stuck_jobs.py
```

### Konfiguration via env

- `DRY_RUN=1` – logga bara.
- **SalA214 / KunskapensHav (priority):**
  - `TIME_LIMIT_PRIORITY_SECONDS` – timeout för både processing och kö (default **300** s = 5 min).
  - `TIME_LIMIT_PRIORITY_PROCESSING_SECONDS` – endast jobb i "processing" (annars PRIORITY).
  - `TIME_LIMIT_PRIORITY_QUEUED_SECONDS` – endast jobb i kö (pending/held, ej processing) (annars PRIORITY).
- **Övriga köer:**
  - `TIME_LIMIT_DEFAULT_SECONDS` – timeout för båda (default **1200** s = 20 min).
  - `TIME_LIMIT_DEFAULT_PROCESSING_SECONDS` – endast jobb i "processing".
  - `TIME_LIMIT_DEFAULT_QUEUED_SECONDS` – endast jobb i kö (ej processing).

### Cron-exempel (sudo crontab)

Kör som root (t.ex. `sudo crontab -e`). **Varje minut** (`* * * * *`) så att fastnade jobb rensas inom timeout:

```bash
* * * * * /usr/bin/env DRY_RUN=0 /usr/bin/python3 /srv/printserver/scripts/purge_stuck_jobs.py >> /var/log/purge_stuck_jobs.log 2>&1
```

Om du vill ändra timeout i cron, använd rätt variabelnamn (inte `TIME_LIMIT_SECONDS`):

```bash
* * * * * /usr/bin/env DRY_RUN=0 TIME_LIMIT_PRIORITY_SECONDS=300 TIME_LIMIT_DEFAULT_SECONDS=1200 /usr/bin/python3 /srv/printserver/scripts/purge_stuck_jobs.py >> /var/log/purge_stuck_jobs.log 2>&1
```

**Vanligt misstag:** `* 10 * * *` kör bara varje minut mellan 10:00–10:59; efter 11:00 körs inget förrän nästa dag. Använd `* * * * *` för varje minut dygnet runt.

## Lista pågående jobb med ålder

### `scripts/list_jobs_with_age.py`

Visar ej-klara jobb, sorterat äldst först:

```bash
sudo python3 /srv/printserver/scripts/list_jobs_with_age.py
```

## Övriga scripts (kort)

- `scripts/cleanup_held_jobs.py`: tar bort **held**-jobb äldre än 1 timme.
- `scripts/purge_completed_jobs.py`: tar bort jobb (i nuvarande version: avbryter alla jobb som returneras av CUPS).
- `scripts/release_core.py`, `scripts/list_core.py`, `scripts/cleanup_core.py`: core-funktioner (list/cleanup/release) som även används av `scripts/webservice.py`.

## Nätverk / VLAN

Vid **Lägg till ny skrivare** (meny 10) i `servicectl.sh` väljer man skrivartyp; varje typ styr vilka VLAN som får åtkomst (CUPS Location-block):

- **TEG** – jobb hålls tills release; åtkomst från: Lärare, TRC, Management, AREA54 och Gäster
- **AREA53** – åtkomst från: Lärare, TRC och Management
- **TRC** – åtkomst från: TRC och Management; skriver direkt som personal, ingen QR-release

För att servern ska kunna nå skrivare i **TRC** krävs att maskinen har nätverksåtkomst till TRC, t.ex.:

- Ett nätverksgränssnitt i VLAN TRC (VLAN-interface eller eget nät), eller
- Routing så att TRC är nåbart från servern.

Skrivare som lades till *före* att VLAN TRC lades in har inte nödvändigtvis `Allow from xxx.xxx.xxx.xxx/xx` i `/etc/cups/cupsd.conf`. Lägg då till en rad `Allow from xxx.xxx.xxx.xxx/xx` i respektive `<Location /printers/Könamn>`-block och starta om CUPS.

**Make and Model / "Local Raw Printer":** Skriptet lägger till skrivare med `-m everywhere` (IPP Everywhere). Om en skrivare ändå visar "Local Raw Printer" i CUPS-webben använd **meny 13** i `servicectl.sh` (byter till IPP Everywhere med URI satt på nytt – det behövs ibland). Efteråt: ladda om CUPS-webben med **Ctrl+F5** (hard refresh) så att "Make and Model" uppdateras. Manuellt: `sudo lpadmin -p <könamn> -v "ipp://IP/ipp/print" -m everywhere -E` (samma URI som skrivaren redan har).

**Vissa HP-skrivare (t.ex. Color LaserJet E45028)** returnerar tomma strängar för IPP-attribut som `output-bin-default`, `media-type-default` eller `hp-easycolor-default`. Det bryter mot RFC 8011 (keyword får inte vara tom), så CUPS och ipptool rapporterar fel och skrivaren visas som "Local Raw Printer". Utskrift fungerar normalt med raw-kön. Eventuell firmwareuppdatering från HP kan åtgärda IPP-svaren.

**Könamn:** CUPS tillåter inte mellanslag i skrivarnamn. Skriptet ersätter mellanslag med understreck (t.ex. "TRC Lunch" → "TRC_Lunch").

**Kontaktkontroll:** Direkt efter att du angett IP-adressen kontrollerar skriptet att skrivaren svarar på port 631 (IPP), med 5 sekunders timeout. Om kontakten misslyckas visas en varning och inget sparas – välj 10 igen för att försöka med annan IP eller efter nätverkskontroll.

**Persistens till printers.conf:** CUPS sparar skrivare via temporär fil och atomisk rename; om tjänsten startas om för tidigt kan skrivaren synas i webbgränssnittet men saknas i filen. Skriptet väntar därför 5 sekunder efter lpadmin, uppdaterar sedan cupsd.conf, **stoppar** CUPS (så att cupsd hinner spara printers.conf vid avslut), väntar 2 sekunder, och startar CUPS igen. Om skrivaren fortfarande saknas: kontrollera med `sudo cat /etc/cups/printers.conf` (filen är ofta endast läsbar för root/lp) och eventuella tillfälliga filer under `/etc/cups/` (t.ex. `printers.conf.N`).

**Om skrivare inte syns efter "Lägg till ny skrivare":** Skriptet skapar nu köer *utan* att först aktivera skrivaren (`-E`), så att tillägget lyckas även om skrivaren är oåtkomlig eller långsam. Aktivering görs sedan med `cupsenable`. Om `lpadmin` ändå misslyckas visas ett felmeddelande – kontrollera då IP, att du kör med behörighet (t.ex. användare i gruppen `lpadmin`) och att skrivaren svarar på IPP (port 631). Du kan testa manuellt: `sudo lpadmin -p TestKö -v ipp://172.31.10.33/ipp/print -m everywhere -E` (byter ut IP mot skrivarens).

## Säkerhet / hemligheter

Webservice-delen använder en API-token för att skydda endpoints som `/list` och `/cleanup`.
Håll hemligheter utanför versionshanterade filer och se till att token inte exponeras i loggar eller delad dokumentation.

Du måste skapa filen `/srv/printserver/.env` med token innan webservice startas.
Variabelnamnet ska vara:

```bash
API_TOKEN=<ditt_losenord>
```

## Webservice som systemd-tjänst

Exempel på systemd-enhet för webservice (`/etc/systemd/system/printapi.service`):

```ini
[Unit]
Description=Flask Print API
After=network.target

[Service]
User=cupsadmin
WorkingDirectory=/srv/printserver/scripts
EnvironmentFile=/srv/printserver/.env
ExecStart=/usr/bin/python3 /srv/printserver/scripts/webservice.py
Restart=always
RestartSec=10
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
```

Ladda om, aktivera och starta tjänsten:

```bash
sudo systemctl daemon-reload
sudo systemctl enable printapi.service
sudo systemctl restart printapi.service
```

Snabb felsökning/verifiering:

```bash
sudo systemctl status printapi.service --no-pager
sudo journalctl -u printapi.service -n 100 --no-pager
ss -lntp | grep :5000
```

