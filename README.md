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
- För e-postnotiser: **lokal MTA** med `sendmail` (t.ex. Postfix/Exim) eller kompatibelt `sendmail`-kommando.

## servicectl.sh

Kör:

```bash
bash /srv/printserver/servicectl.sh
```

Relevanta menyval (urval):

- **7) Tömma en skrivares kö**: avbryter alla jobb i vald kö (kan välja via nummer eller namn).
- **8) Aktivera skrivare**: visar bara pausade/disabled skrivare och aktiverar vald kö.
- **9) Visa pågående jobb (ålder i kö)**: kör `scripts/list_jobs_with_age.py` (via sudo).
- **11) Rensa fastnade jobb (DRY_RUN)**: kör `scripts/purge_stuck_jobs.py` utan att radera.
- **12) Rensa fastnade jobb (SKARPT)**: kör `scripts/purge_stuck_jobs.py` och raderar jobb (kräver bekräftelse).

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

Vid **Lägg till ny skrivare** (meny 10) i `servicectl.sh` väljer man skrivartyp; varje typ styr vilka nät som får åtkomst (CUPS Location-block):

- **TEG** – jobb hålls tills release; åtkomst från: 172.31.53.0/24, 172.31.10.0/24, 172.31.0.0/21, 172.31.64.0/21, 172.31.80.0/20
- **AREA53** – åtkomst från: 172.31.53.0/24, 172.31.10.0/24, 172.31.0.0/21
- **TRC** – VLAN 10 + 172.31.0.0/21 (åtkomst från 172.31.10.0/24 och 172.31.0.0/21); skriver direkt som personal, ingen QR-release

För att servern ska kunna nå skrivare i VLAN 10 (172.31.10.0/24) krävs att maskinen har nätverksåtkomst till det nätet, t.ex.:

- Ett nätverksgränssnitt med adress i 172.31.10.0/24 (VLAN-interface eller eget nät), eller
- Routing så att 172.31.10.0/24 är nåbart från servern.

Skrivare som lades till *före* att VLAN 10 lades in har inte nödvändigtvis `Allow from 172.31.10.0/24` i `/etc/cups/cupsd.conf`. Lägg då till en rad `Allow from 172.31.10.0/24` i respektive `<Location /printers/Könamn>`-block och starta om CUPS.

**Make and Model / "Local Raw Printer":** Skriptet lägger till skrivare med `-m everywhere` (IPP Everywhere). Om en skrivare ändå visar "Local Raw Printer" i CUPS-webben använd **meny 13** i `servicectl.sh` (byter till IPP Everywhere med URI satt på nytt – det behövs ibland). Efteråt: ladda om CUPS-webben med **Ctrl+F5** (hard refresh) så att "Make and Model" uppdateras. Manuellt: `sudo lpadmin -p <könamn> -v "ipp://IP/ipp/print" -m everywhere -E` (samma URI som skrivaren redan har).

**Vissa HP-skrivare (t.ex. Color LaserJet E45028)** returnerar tomma strängar för IPP-attribut som `output-bin-default`, `media-type-default` eller `hp-easycolor-default`. Det bryter mot RFC 8011 (keyword får inte vara tom), så CUPS och ipptool rapporterar fel och skrivaren visas som "Local Raw Printer". Utskrift fungerar normalt med raw-kön. Eventuell firmwareuppdatering från HP kan åtgärda IPP-svaren.

**Könamn:** CUPS tillåter inte mellanslag i skrivarnamn. Skriptet ersätter mellanslag med understreck (t.ex. "TRC Lunch" → "TRC_Lunch").

**Kontaktkontroll:** Direkt efter att du angett IP-adressen kontrollerar skriptet att skrivaren svarar på port 631 (IPP), med 5 sekunders timeout. Om kontakten misslyckas visas en varning och inget sparas – välj 10 igen för att försöka med annan IP eller efter nätverkskontroll.

**Persistens till printers.conf:** CUPS sparar skrivare via temporär fil och atomisk rename; om tjänsten startas om för tidigt kan skrivaren synas i webbgränssnittet men saknas i filen. Skriptet väntar därför 5 sekunder efter lpadmin, uppdaterar sedan cupsd.conf, **stoppar** CUPS (så att cupsd hinner spara printers.conf vid avslut), väntar 2 sekunder, och startar CUPS igen. Om skrivaren fortfarande saknas: kontrollera med `sudo cat /etc/cups/printers.conf` (filen är ofta endast läsbar för root/lp) och eventuella tillfälliga filer under `/etc/cups/` (t.ex. `printers.conf.N`).

**Om skrivare inte syns efter "Lägg till ny skrivare":** Skriptet skapar nu köer *utan* att först aktivera skrivaren (`-E`), så att tillägget lyckas även om skrivaren är oåtkomlig eller långsam. Aktivering görs sedan med `cupsenable`. Om `lpadmin` ändå misslyckas visas ett felmeddelande – kontrollera då IP, att du kör med behörighet (t.ex. användare i gruppen `lpadmin`) och att skrivaren svarar på IPP (port 631). Du kan testa manuellt: `sudo lpadmin -p TestKö -v ipp://172.31.10.33/ipp/print -m everywhere -E` (byter ut IP mot skrivarens).

## Säkerhet / hemligheter

Webservice-delen använder en API-token för att skydda endpoints som `/list` och `/cleanup`.
Håll hemligheter utanför versionshanterade filer och se till att token inte exponeras i loggar eller delad dokumentation.

