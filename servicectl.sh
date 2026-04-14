#!/bin/bash

# Färger för utskrift
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
RESET='\033[0m'

while true; do
    clear
    echo -e "${CYAN}==== CUPS Service Control ====${RESET}"
    echo "1) Starta om CUPS"
    echo "2) Starta om Avahi"
    echo "3) Visa aktiva skrivare"
    echo "4) Visa status för alla köer"
    echo "5) Debug/log (senaste 50 raderna)"
    echo "6) Sätt Duplex + Shared på alla skrivare"
    echo "7) Tömma en skrivares kö"
    echo "8) Aktivera skrivare (ta bort paus)"
    echo "9) Visa pågående jobb (ålder i kö)"
    echo "10) Lägg till ny skrivare"
    echo "11) Rensa fastnade jobb (DRY_RUN)"
    echo "12) Rensa fastnade jobb (SKARPT)"
    echo "13) Byt skrivare till IPP Everywhere (fix \"Local Raw Printer\")"
    echo "q) Avsluta"
    echo
    read -p "Välj alternativ: " val

    case $val in
        1)
            echo -e "${YELLOW}→ Startar om CUPS...${RESET}"
            sudo systemctl restart cups
            echo -e "${GREEN}✓ CUPS startad om.${RESET}"
            ;;
        2)
            echo -e "${YELLOW}→ Startar om Avahi...${RESET}"
            sudo systemctl restart avahi-daemon
            echo -e "${GREEN}✓ Avahi startad om.${RESET}"
            ;;
        3)
            echo -e "${YELLOW}→ Aktiva skrivare:${RESET}"
            lpstat -p -d
            ;;
        4)
            echo -e "${YELLOW}→ Status för alla köer:${RESET}"
            lpstat -l -p
            ;;
        5)
            echo -e "${YELLOW}→ CUPS logg (senaste 50 raderna):${RESET}"
            journalctl -u cups -n 50 --no-pager
            ;;
        6)
            echo -e "${YELLOW}→ Sätter DuplexNoTumble och Shared=true på alla skrivare...${RESET}"
            for printer in $(lpstat -p | awk '{print $2}'); do
                echo "  $printer..."
                sudo lpadmin -p "$printer" -o Duplex=DuplexNoTumble -o printer-is-shared=true
            done
            echo -e "${GREEN}✓ Alla skrivare uppdaterade.${RESET}"
            ;;
        7)
            echo -e "${CYAN}→ Tömma skrivares kö${RESET}"
            echo "Tillgängliga skrivare:"
            printers=($(lpstat -p | awk '{print $2}'))
            for i in "${!printers[@]}"; do
                echo "  $i) ${printers[$i]}"
            done
            echo
            read -p "Ange nummer eller skrivarens namn (eller 'b' för tillbaka): " printer_input
            # Kontrollera om användaren vill gå tillbaka
            if [[ "$printer_input" =~ ^[bB]$ ]] || [[ "$printer_input" == "tillbaka" ]] || [[ "$printer_input" == "Tillbaka" ]]; then
                echo -e "${YELLOW}→ Går tillbaka till huvudmenyn...${RESET}"
            else
                # Kontrollera om input är ett nummer
                if [[ "$printer_input" =~ ^[0-9]+$ ]] && [ "$printer_input" -ge 0 ] && [ "$printer_input" -lt "${#printers[@]}" ]; then
                    printer_name="${printers[$printer_input]}"
                else
                    printer_name="$printer_input"
                fi
                if lpstat -p "$printer_name" &>/dev/null; then
                    echo -e "${YELLOW}→ Tömmer kö för $printer_name...${RESET}"
                    cancel -a "$printer_name" 2>/dev/null || sudo cancel -a "$printer_name"
                    echo -e "${GREEN}✓ Kö för $printer_name är nu tom.${RESET}"
                else
                    echo -e "${YELLOW}⚠ Skrivaren $printer_name hittades inte.${RESET}"
                fi
            fi
            ;;
        8)
            echo -e "${CYAN}→ Aktivera skrivare (ta bort paus)${RESET}"
            # Hämta bara pausade skrivare
            paused_printers=($(lpstat -p | grep -i "paused\|disabled" | awk '{print $2}'))
            if [ ${#paused_printers[@]} -eq 0 ]; then
                echo -e "${GREEN}✓ Inga pausade skrivare hittades.${RESET}"
            else
                echo "Pausade skrivare:"
                for i in "${!paused_printers[@]}"; do
                    echo "  $i) ${paused_printers[$i]}"
                done
                echo
                read -p "Ange nummer eller skrivarens namn (eller 'b' för tillbaka): " printer_input
                # Kontrollera om användaren vill gå tillbaka
                if [[ "$printer_input" =~ ^[bB]$ ]] || [[ "$printer_input" == "tillbaka" ]] || [[ "$printer_input" == "Tillbaka" ]]; then
                    echo -e "${YELLOW}→ Går tillbaka till huvudmenyn...${RESET}"
                else
                    # Kontrollera om input är ett nummer
                    if [[ "$printer_input" =~ ^[0-9]+$ ]] && [ "$printer_input" -ge 0 ] && [ "$printer_input" -lt "${#paused_printers[@]}" ]; then
                        printer_name="${paused_printers[$printer_input]}"
                    else
                        printer_name="$printer_input"
                    fi
                    if lpstat -p "$printer_name" &>/dev/null; then
                        echo -e "${YELLOW}→ Aktiverar $printer_name...${RESET}"
                        cupsenable "$printer_name" 2>/dev/null || sudo cupsenable "$printer_name"
                        if [ $? -eq 0 ]; then
                            echo -e "${GREEN}✓ Skrivaren $printer_name är nu aktiverad.${RESET}"
                        else
                            echo -e "${YELLOW}⚠ Kunde inte aktivera skrivaren. Kontrollera behörigheter.${RESET}"
                        fi
                    else
                        echo -e "${YELLOW}⚠ Skrivaren $printer_name hittades inte.${RESET}"
                    fi
                fi
            fi
            ;;
        9)
            echo -e "${YELLOW}→ Pågående jobb (ålder i kö):${RESET}"
            sudo python3 /srv/printserver/scripts/list_jobs_with_age.py
            ;;
        10)
            echo -e "${CYAN}→ Lägg till ny skrivare${RESET}"
            read -p "Ange IP-adress till skrivaren: " printer_ip

            connect_ok=0
            if timeout 5 bash -c "echo >/dev/tcp/$printer_ip/631" 2>/dev/null; then
                connect_ok=1
            fi
            if [ "$connect_ok" -eq 0 ]; then
                echo -e "${YELLOW}Kunde inte nå skrivaren på $printer_ip (port 631). Kontrollera IP och nätverk. Ingen inställning sparad – välj 10 igen för att försöka.${RESET}"
            else
                read -p "Ange namn på kön (t.ex. SalA214): " printer_name
                # CUPS tillåter inte mellanslag i skrivarnamn – ersätt med understreck
                printer_name=$(echo "$printer_name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/ /_/g')
                [ -z "$printer_name" ] && printer_name="Printer"
                read -p "Ange beskrivning (Info): " printer_info
                read -p "Ange plats (Location): " printer_location
                echo "Välj skrivartyp (TEG = alla, jobb hålls tills release/QR; AREA53/TRC = skriver direkt, ingen QR):"
                lpadmin_ok=0
                select skrivartyp in "TEG" "AREA53" "TRC"; do
                case $skrivartyp in
                    TEG )
                        echo -e "${YELLOW}→ Skapar skrivarkö $printer_name (TEG)...${RESET}"
                        sudo lpadmin -p "$printer_name" \
                          -v "ipp://$printer_ip/ipp/print" \
                          -m everywhere \
                          -D "$printer_info" \
                          -L "$printer_location" \
                          -o printer-is-shared=true \
                          -o Duplex=DuplexNoTumble \
                          -o ErrorPolicy=abort-job \
                          -o job-hold-until=indefinite
                        lpadmin_ok=$?
                        location_block="<Location /printers/$printer_name>
  Order deny,allow
  Allow from 172.31.53.0/24
  Allow from 172.31.10.0/24
  Allow from 172.31.0.0/21
  Allow from 172.31.64.0/21
  Allow from 172.31.80.0/20
  AuthType None
</Location>"
                        break
                        ;;
                    AREA53 )
                        echo -e "${YELLOW}→ Skapar skrivarkö $printer_name (AREA53)...${RESET}"
                        sudo lpadmin -p "$printer_name" \
                          -v "ipp://$printer_ip/ipp/print" \
                          -m everywhere \
                          -D "$printer_info" \
                          -L "$printer_location" \
                          -o printer-is-shared=true \
                          -o Duplex=DuplexNoTumble \
                          -o ErrorPolicy=abort-job
                        lpadmin_ok=$?
                        location_block="<Location /printers/$printer_name>
  Order deny,allow
  Deny from all
  Allow from 172.31.53.0/24
  Allow from 172.31.10.0/24
  Allow from 172.31.0.0/21
  AuthType None
</Location>"
                        break
                        ;;
                    TRC )
                        echo -e "${YELLOW}→ Skapar skrivarkö $printer_name (TRC, endast VLAN 10 – skriver direkt som personal, ingen QR)...${RESET}"
                        sudo lpadmin -p "$printer_name" \
                          -v "ipp://$printer_ip/ipp/print" \
                          -m everywhere \
                          -D "$printer_info" \
                          -L "$printer_location" \
                          -o printer-is-shared=true \
                          -o Duplex=DuplexNoTumble \
                          -o ErrorPolicy=abort-job
                        lpadmin_ok=$?
                        location_block="<Location /printers/$printer_name>
  Order deny,allow
  Deny from all
  Allow from 172.31.10.0/24
  Allow from 172.31.0.0/21
  AuthType None
</Location>"
                        break
                        ;;
                esac
            done

            if [ "$lpadmin_ok" -ne 0 ]; then
                echo -e "${YELLOW}lpadmin misslyckades – skrivaren lades inte till. Kontrollera IP, behörighet (sudo/lpadmin) och att skrivaren svarar på IPP (port 631).${RESET}"
            else
                # Ge cupsd tid att skriva printers.conf till disk (CUPS använder temporär fil + rename)
                sleep 5
                # Ta bort ev. gammalt Location-block i cupsd.conf
                sudo sed -i "/<Location \/printers\/$printer_name>/,/<\/Location>/d" /etc/cups/cupsd.conf

                # Lägg till nytt block sist i filen
                echo "$location_block" | sudo tee -a /etc/cups/cupsd.conf > /dev/null

                # Stoppa CUPS så att cupsd hinner spara printers.conf vid avslut, starta sedan om
                sudo systemctl stop cups
                sleep 2
                sudo systemctl start cups

                # Aktivera skrivaren (kan misslyckas om enheten är oåtkomlig – då syns den ändå i listan)
                sudo cupsenable "$printer_name" 2>/dev/null || true

                echo -e "${GREEN}✓ Skrivaren $printer_name är tillagd och cupsd.conf uppdaterad.${RESET}"
                echo -e "${YELLOW}→ Dubbelkolla /etc/cups/cupsd.conf och /etc/cups/printers.conf så att allt ser rätt ut.${RESET}"
            fi
            fi
            ;;
        13)
            echo -e "${CYAN}→ Byt skrivare till IPP Everywhere (fix \"Local Raw Printer\")${RESET}"
            echo "Välj skrivare:"
            printers=($(lpstat -p | awk '{print $2}'))
            for i in "${!printers[@]}"; do
                echo "  $i) ${printers[$i]}"
            done
            echo
            read -p "Ange nummer eller skrivarens namn (eller 'b' för tillbaka): " printer_input
            if [[ "$printer_input" =~ ^[bB]$ ]] || [[ "$printer_input" == "tillbaka" ]] || [[ "$printer_input" == "Tillbaka" ]]; then
                echo -e "${YELLOW}→ Går tillbaka till huvudmenyn...${RESET}"
            else
                if [[ "$printer_input" =~ ^[0-9]+$ ]] && [ "$printer_input" -ge 0 ] && [ "$printer_input" -lt "${#printers[@]}" ]; then
                    fix_printer="${printers[$printer_input]}"
                else
                    fix_printer="$printer_input"
                fi
                if lpstat -p "$fix_printer" &>/dev/null; then
                    fix_uri=$(lpstat -v 2>/dev/null | grep "device for $fix_printer:" | sed 's/.*: //')
                    if [ -n "$fix_uri" ]; then
                        echo -e "${YELLOW}→ Sätter $fix_printer till IPP Everywhere (URI: $fix_uri)...${RESET}"
                        sudo lpadmin -p "$fix_printer" -v "$fix_uri" -m everywhere -E
                        if [ $? -eq 0 ]; then
                            echo -e "${GREEN}✓ Klart. Ladda om CUPS-webben (Ctrl+F5) för att se uppdaterad \"Make and Model\".${RESET}"
                        else
                            echo -e "${YELLOW}lpadmin misslyckades. Prova manuellt: sudo lpadmin -p $fix_printer -v \"$fix_uri\" -m everywhere -E${RESET}"
                        fi
                    else
                        echo -e "${YELLOW}Kunde inte läsa URI för $fix_printer (lpstat -v).${RESET}"
                    fi
                else
                    echo -e "${YELLOW}Okänd skrivare: $fix_printer${RESET}"
                fi
            fi
            ;;
        11)
            echo -e "${YELLOW}→ Rensar fastnade jobb (DRY_RUN, raderar inget)...${RESET}"
            sudo env DRY_RUN=1 python3 /srv/printserver/scripts/purge_stuck_jobs.py
            ;;
        12)
            echo -e "${YELLOW}→ Rensar fastnade jobb (SKARPT)...${RESET}"
            read -p "Är du säker? Skriv 'JA' för att fortsätta: " confirm
            if [ "$confirm" = "JA" ]; then
                sudo env DRY_RUN=0 python3 /srv/printserver/scripts/purge_stuck_jobs.py
            else
                echo -e "${YELLOW}Avbrutet.${RESET}"
            fi
            ;;
        q)
            echo "Avslutar..."
            break
            ;;
        *)
            echo "Ogiltigt val."
            ;;
    esac
    echo
    read -p "Tryck [Enter] för att fortsätta..."
done
