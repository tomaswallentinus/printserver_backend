#!/bin/bash

# Färger för utskrift
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
RESET='\033[0m'

DB_DIR="/srv/printserver/data"
DB_PATH="$DB_DIR/vlans.db"
CUPSD_CONF="/etc/cups/cupsd.conf"

sql_escape() {
    printf "%s" "$1" | sed "s/'/''/g"
}

ensure_db() {
    if ! command -v sqlite3 >/dev/null 2>&1; then
        echo -e "${YELLOW}⚠ sqlite3 saknas. Installera med: sudo apt install sqlite3${RESET}"
        return 1
    fi
    mkdir -p "$DB_DIR"
    sqlite3 "$DB_PATH" <<'SQL'
PRAGMA foreign_keys=ON;
CREATE TABLE IF NOT EXISTS vlans (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL UNIQUE,
  cidr TEXT NOT NULL UNIQUE,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS printer_vlans (
  printer_name TEXT NOT NULL,
  vlan_id INTEGER NOT NULL,
  PRIMARY KEY (printer_name, vlan_id),
  FOREIGN KEY (vlan_id) REFERENCES vlans(id) ON DELETE CASCADE
);
SQL
}

is_valid_cidr() {
    python3 - "$1" <<'PY'
import ipaddress
import sys
try:
    ipaddress.ip_network(sys.argv[1], strict=False)
except Exception:
    print("0")
else:
    print("1")
PY
}

restart_cups_clean() {
    sudo systemctl stop cups
    sleep 2
    sudo systemctl start cups
}

printer_exists() {
    lpstat -p "$1" &>/dev/null
}

list_vlans() {
    ensure_db || return 1
    echo "ID | Namn | CIDR"
    sqlite3 -separator " | " "$DB_PATH" "SELECT id,name,cidr FROM vlans ORDER BY name;"
}

sync_location_block_for_printer() {
    local printer_name="$1"
    local escaped_name
    local cidrs
    local location_block

    escaped_name="$(sql_escape "$printer_name")"
    cidrs="$(sqlite3 "$DB_PATH" "SELECT v.cidr FROM vlans v JOIN printer_vlans pv ON pv.vlan_id=v.id WHERE pv.printer_name='$escaped_name' ORDER BY v.name;")"

    if [ -z "$cidrs" ]; then
        echo -e "${YELLOW}⚠ Inga VLAN kopplade till $printer_name. Hoppar över uppdatering av Location-block.${RESET}"
        return 1
    fi

    location_block="<Location /printers/$printer_name>
  Order deny,allow
  Deny from all"
    while IFS= read -r cidr; do
        [ -z "$cidr" ] && continue
        location_block="$location_block
  Allow from $cidr"
    done <<< "$cidrs"
    location_block="$location_block
  AuthType None
</Location>"

    sudo sed -i "/<Location \/printers\/$printer_name>/,/<\/Location>/d" "$CUPSD_CONF"
    echo "$location_block" | sudo tee -a "$CUPSD_CONF" > /dev/null
    restart_cups_clean
    echo -e "${GREEN}✓ Location-block synkat för $printer_name.${RESET}"
    return 0
}

sync_location_blocks_for_vlan_id() {
    local vlan_id="$1"
    local printers
    printers="$(sqlite3 "$DB_PATH" "SELECT printer_name FROM printer_vlans WHERE vlan_id=$vlan_id;")"
    while IFS= read -r p; do
        [ -z "$p" ] && continue
        sync_location_block_for_printer "$p"
    done <<< "$printers"
}

link_vlans_to_printer() {
    local printer_name="$1"
    local vlan_ids_csv="$2"
    local escaped_name
    escaped_name="$(sql_escape "$printer_name")"

    sqlite3 "$DB_PATH" "DELETE FROM printer_vlans WHERE printer_name='$escaped_name';"
    IFS=',' read -ra ids <<< "$vlan_ids_csv"
    for id in "${ids[@]}"; do
        id="$(echo "$id" | xargs)"
        [[ "$id" =~ ^[0-9]+$ ]] || continue
        sqlite3 "$DB_PATH" "INSERT OR IGNORE INTO printer_vlans(printer_name, vlan_id) VALUES ('$escaped_name', $id);"
    done
}

select_printer_interactive() {
    local prompt="$1"
    local printer_input
    local printers
    SELECTED_PRINTER=""
    printers=($(lpstat -p | awk '{print $2}'))
    if [ ${#printers[@]} -eq 0 ]; then
        echo -e "${YELLOW}⚠ Inga skrivare hittades.${RESET}"
        return
    fi
    for i in "${!printers[@]}"; do
        echo "  $i) ${printers[$i]}"
    done
    echo
    read -p "$prompt" printer_input
    if [[ "$printer_input" =~ ^[bB]$ ]] || [[ "$printer_input" == "tillbaka" ]] || [[ "$printer_input" == "Tillbaka" ]]; then
        return
    fi
    if [[ "$printer_input" =~ ^[0-9]+$ ]] && [ "$printer_input" -ge 0 ] && [ "$printer_input" -lt "${#printers[@]}" ]; then
        SELECTED_PRINTER="${printers[$printer_input]}"
    else
        SELECTED_PRINTER="$printer_input"
    fi
}

assign_vlans_to_printer_menu() {
    local selected_printer
    local selected_ids
    ensure_db || return
    echo -e "${CYAN}→ Koppla VLAN till skrivare${RESET}"
    select_printer_interactive "Ange nummer eller skrivarnamn (eller 'b' för tillbaka): "
    selected_printer="$SELECTED_PRINTER"
    [ -z "$selected_printer" ] && return
    if ! printer_exists "$selected_printer"; then
        echo -e "${YELLOW}⚠ Skrivaren $selected_printer hittades inte.${RESET}"
        return
    fi
    echo "Tillgängliga VLAN:"
    list_vlans
    echo
    read -p "Ange VLAN-ID (kommaseparerat, t.ex. 1,2,3): " selected_ids
    if [ -z "$selected_ids" ]; then
        echo -e "${YELLOW}⚠ Inget valt. Avbryter.${RESET}"
        return
    fi
    link_vlans_to_printer "$selected_printer" "$selected_ids"
    sync_location_block_for_printer "$selected_printer"
}

remove_vlan_from_printer_menu() {
    local selected_printer
    local selected_vlan_id
    local escaped_name
    ensure_db || return
    echo -e "${CYAN}→ Ta bort VLAN från skrivare${RESET}"
    select_printer_interactive "Ange nummer eller skrivarnamn (eller 'b' för tillbaka): "
    selected_printer="$SELECTED_PRINTER"
    [ -z "$selected_printer" ] && return
    if ! printer_exists "$selected_printer"; then
        echo -e "${YELLOW}⚠ Skrivaren $selected_printer hittades inte.${RESET}"
        return
    fi
    escaped_name="$(sql_escape "$selected_printer")"
    echo "Nuvarande VLAN-kopplingar:"
    sqlite3 -separator " | " "$DB_PATH" "SELECT v.id,v.name,v.cidr FROM vlans v JOIN printer_vlans pv ON pv.vlan_id=v.id WHERE pv.printer_name='$escaped_name' ORDER BY v.name;"
    echo
    read -p "Ange VLAN-ID att ta bort: " selected_vlan_id
    [[ "$selected_vlan_id" =~ ^[0-9]+$ ]] || { echo -e "${YELLOW}⚠ Ogiltigt VLAN-ID.${RESET}"; return; }
    sqlite3 "$DB_PATH" "DELETE FROM printer_vlans WHERE printer_name='$escaped_name' AND vlan_id=$selected_vlan_id;"
    sync_location_block_for_printer "$selected_printer"
}

show_printer_vlan_links_menu() {
    local selected_printer
    local escaped_name
    ensure_db || return
    while true; do
        echo -e "${CYAN}→ Visa VLAN-kopplingar per skrivare${RESET}"
        echo "Tillgängliga skrivare:"
        select_printer_interactive "Ange nummer eller skrivarnamn (eller 'b' för tillbaka): "
        selected_printer="$SELECTED_PRINTER"
        [ -z "$selected_printer" ] && return
        escaped_name="$(sql_escape "$selected_printer")"
        echo
        echo "VLAN för skrivare: $selected_printer"
        sqlite3 -separator " | " "$DB_PATH" "SELECT v.id,v.name,v.cidr FROM vlans v JOIN printer_vlans pv ON pv.vlan_id=v.id WHERE pv.printer_name='$escaped_name' ORDER BY v.name;"
        echo
        read -p "Tryck [Enter] för att visa en annan skrivare, eller skriv 'b' för tillbaka: " show_more
        if [[ "$show_more" =~ ^[bB]$ ]] || [[ "$show_more" == "tillbaka" ]] || [[ "$show_more" == "Tillbaka" ]]; then
            return
        fi
    done
}

vlan_catalog_menu() {
    local action vlan_name vlan_cidr vlan_id new_name new_cidr valid escaped_name escaped_new_name old_cidr cidr_changed
    ensure_db || return
    while true; do
        echo
        echo -e "${CYAN}→ Hantera VLAN-katalog${RESET}"
        echo "1) Visa VLAN"
        echo "2) Lägg till VLAN"
        echo "3) Ändra VLAN"
        echo "4) Ta bort VLAN"
        echo "b) Tillbaka"
        read -p "Välj: " action
        case "$action" in
            1)
                list_vlans
                ;;
            2)
                read -p "VLAN-namn: " vlan_name
                read -p "CIDR (t.ex. 192.168.0.0/24): " vlan_cidr
                valid="$(is_valid_cidr "$vlan_cidr")"
                [ "$valid" = "1" ] || { echo -e "${YELLOW}⚠ Ogiltig CIDR.${RESET}"; continue; }
                escaped_name="$(sql_escape "$vlan_name")"
                sqlite3 "$DB_PATH" "INSERT INTO vlans(name,cidr,created_at,updated_at) VALUES ('$escaped_name','$vlan_cidr',datetime('now'),datetime('now'));"
                [ $? -eq 0 ] && echo -e "${GREEN}✓ VLAN tillagt.${RESET}" || echo -e "${YELLOW}⚠ Kunde inte lägga till VLAN (duplikat?).${RESET}"
                ;;
            3)
                list_vlans
                read -p "Ange VLAN-ID att ändra: " vlan_id
                [[ "$vlan_id" =~ ^[0-9]+$ ]] || { echo -e "${YELLOW}⚠ Ogiltigt VLAN-ID.${RESET}"; continue; }
                old_cidr="$(sqlite3 "$DB_PATH" "SELECT cidr FROM vlans WHERE id=$vlan_id LIMIT 1;")"
                [ -z "$old_cidr" ] && { echo -e "${YELLOW}⚠ VLAN-ID $vlan_id hittades inte.${RESET}"; continue; }
                read -p "Nytt namn (lämna tomt för oförändrat): " new_name
                read -p "Ny CIDR (lämna tom för oförändrat): " new_cidr
                if [ -n "$new_cidr" ]; then
                    valid="$(is_valid_cidr "$new_cidr")"
                    [ "$valid" = "1" ] || { echo -e "${YELLOW}⚠ Ogiltig CIDR.${RESET}"; continue; }
                fi
                if [ -n "$new_name" ]; then
                    escaped_new_name="$(sql_escape "$new_name")"
                    sqlite3 "$DB_PATH" "UPDATE vlans SET name='$escaped_new_name', updated_at=datetime('now') WHERE id=$vlan_id;"
                fi
                if [ -n "$new_cidr" ]; then
                    sqlite3 "$DB_PATH" "UPDATE vlans SET cidr='$new_cidr', updated_at=datetime('now') WHERE id=$vlan_id;"
                fi
                cidr_changed=0
                if [ -n "$new_cidr" ] && [ "$new_cidr" != "$old_cidr" ]; then
                    cidr_changed=1
                fi
                if [ "$cidr_changed" -eq 1 ]; then
                    sync_location_blocks_for_vlan_id "$vlan_id"
                    echo -e "${GREEN}✓ VLAN uppdaterat och berörda Location-block synkade.${RESET}"
                else
                    echo -e "${GREEN}✓ VLAN uppdaterat. Ingen Location-sync behövdes (CIDR oförändrad).${RESET}"
                fi
                ;;
            4)
                list_vlans
                read -p "Ange VLAN-ID att ta bort: " vlan_id
                [[ "$vlan_id" =~ ^[0-9]+$ ]] || { echo -e "${YELLOW}⚠ Ogiltigt VLAN-ID.${RESET}"; continue; }
                sync_location_blocks_for_vlan_id "$vlan_id"
                sqlite3 "$DB_PATH" "DELETE FROM vlans WHERE id=$vlan_id;"
                echo -e "${GREEN}✓ VLAN borttaget.${RESET}"
                ;;
            b|B)
                return
                ;;
            *)
                echo -e "${YELLOW}Ogiltigt val.${RESET}"
                ;;
        esac
    done
}

import_vlans_from_cupsd_menu() {
    local current_printer cidr safe_name vlan_id created=0 linked=0
    ensure_db || return
    if ! sudo test -r "$CUPSD_CONF" 2>/dev/null; then
        echo -e "${YELLOW}⚠ Kan inte läsa $CUPSD_CONF. Kontrollera sudo-behörighet.${RESET}"
        return
    fi
    while IFS= read -r line; do
        if [[ "$line" =~ ^\<Location[[:space:]]+/printers/([^[:space:]]+)\> ]]; then
            current_printer="${BASH_REMATCH[1]}"
            continue
        fi
        if [[ "$line" =~ ^\</Location\> ]]; then
            current_printer=""
            continue
        fi
        if [ -n "$current_printer" ] && [[ "$line" =~ ^[[:space:]]*Allow[[:space:]]+from[[:space:]]+([^[:space:]]+) ]]; then
            cidr="${BASH_REMATCH[1]}"
            if ! [[ "$cidr" =~ / ]]; then
                continue
            fi
            safe_name="IMPORTED_$(echo "$cidr" | sed 's/[^a-zA-Z0-9]/_/g')"
            sqlite3 "$DB_PATH" "INSERT OR IGNORE INTO vlans(name,cidr,created_at,updated_at) VALUES ('$safe_name','$cidr',datetime('now'),datetime('now'));"
            vlan_id="$(sqlite3 "$DB_PATH" "SELECT id FROM vlans WHERE cidr='$cidr' LIMIT 1;")"
            if [ -n "$vlan_id" ]; then
                sqlite3 "$DB_PATH" "INSERT OR IGNORE INTO printer_vlans(printer_name,vlan_id) VALUES ('$(sql_escape "$current_printer")',$vlan_id);"
                linked=$((linked + 1))
            fi
        fi
    done < <(sudo cat "$CUPSD_CONF")
    created="$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM vlans WHERE name LIKE 'IMPORTED_%';")"
    echo -e "${GREEN}✓ Import klar. IMPORTED-VLAN totalt: $created. Kopplingsförsök: $linked.${RESET}"
}

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
    echo "14) Hantera VLAN-katalog (lägg till/ändra/ta bort)"
    echo "15) Koppla VLAN till skrivare"
    echo "16) Ta bort VLAN från skrivare"
    echo "17) Visa VLAN-kopplingar för skrivare"
    echo "18) Importera/synka VLAN från cupsd.conf"
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
            select_printer_interactive "Ange nummer eller skrivarens namn (eller 'b' för tillbaka): "
            printer_name="$SELECTED_PRINTER"
            [ -z "$printer_name" ] || {
                if printer_exists "$printer_name"; then
                    echo -e "${YELLOW}→ Tömmer kö för $printer_name...${RESET}"
                    cancel -a "$printer_name" 2>/dev/null || sudo cancel -a "$printer_name"
                    echo -e "${GREEN}✓ Kö för $printer_name är nu tom.${RESET}"
                else
                    echo -e "${YELLOW}⚠ Skrivaren $printer_name hittades inte.${RESET}"
                fi
            }
            ;;
        8)
            echo -e "${CYAN}→ Aktivera skrivare (ta bort paus)${RESET}"
            paused_printers=($(lpstat -p | grep -i "paused\|disabled" | awk '{print $2}'))
            if [ ${#paused_printers[@]} -eq 0 ]; then
                echo -e "${GREEN}✓ Inga pausade skrivare hittades.${RESET}"
            else
                for i in "${!paused_printers[@]}"; do
                    echo "  $i) ${paused_printers[$i]}"
                done
                echo
                read -p "Ange nummer eller skrivarens namn (eller 'b' för tillbaka): " printer_input
                if [[ "$printer_input" =~ ^[0-9]+$ ]] && [ "$printer_input" -ge 0 ] && [ "$printer_input" -lt "${#paused_printers[@]}" ]; then
                    printer_name="${paused_printers[$printer_input]}"
                else
                    printer_name="$printer_input"
                fi
                if printer_exists "$printer_name"; then
                    cupsenable "$printer_name" 2>/dev/null || sudo cupsenable "$printer_name"
                    [ $? -eq 0 ] && echo -e "${GREEN}✓ Skrivaren $printer_name är nu aktiverad.${RESET}" || echo -e "${YELLOW}⚠ Kunde inte aktivera skrivaren.${RESET}"
                fi
            fi
            ;;
        9)
            echo -e "${YELLOW}→ Pågående jobb (ålder i kö):${RESET}"
            sudo python3 /srv/printserver/scripts/list_jobs_with_age.py
            ;;
        10)
            ensure_db || { echo -e "${YELLOW}⚠ Kan inte fortsätta utan SQLite-databas.${RESET}"; continue; }
            echo -e "${CYAN}→ Lägg till ny skrivare${RESET}"
            read -p "Ange IP-adress till skrivaren: " printer_ip
            if ! timeout 5 bash -c "echo >/dev/tcp/$printer_ip/631" 2>/dev/null; then
                echo -e "${YELLOW}Kunde inte nå skrivaren på $printer_ip (port 631). Kontrollera IP och nätverk.${RESET}"
            else
                read -p "Ange namn på kön (t.ex. SalA214): " printer_name
                printer_name=$(echo "$printer_name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/ /_/g')
                [ -z "$printer_name" ] && printer_name="Printer"
                read -p "Ange beskrivning (Info): " printer_info
                read -p "Ange plats (Location): " printer_location
                echo "Välj skrivartyp (TEG = alla, jobb hålls tills release/QR; AREA53/TRC = skriver direkt, ingen QR):"
                lpadmin_ok=0
                selected_type=""
                select skrivartyp in "TEG" "AREA53" "TRC"; do
                    case $skrivartyp in
                        TEG|AREA53|TRC)
                            selected_type="$skrivartyp"
                            break
                            ;;
                    esac
                done
                if [ "$selected_type" = "TEG" ]; then
                    sudo lpadmin -p "$printer_name" -v "ipp://$printer_ip/ipp/print" -m everywhere -D "$printer_info" -L "$printer_location" -o printer-is-shared=true -o Duplex=DuplexNoTumble -o ErrorPolicy=abort-job -o job-hold-until=indefinite
                    lpadmin_ok=$?
                else
                    sudo lpadmin -p "$printer_name" -v "ipp://$printer_ip/ipp/print" -m everywhere -D "$printer_info" -L "$printer_location" -o printer-is-shared=true -o Duplex=DuplexNoTumble -o ErrorPolicy=abort-job
                    lpadmin_ok=$?
                fi
                if [ "$lpadmin_ok" -ne 0 ]; then
                    echo -e "${YELLOW}lpadmin misslyckades – skrivaren lades inte till.${RESET}"
                else
                    sleep 5
                    echo -e "${YELLOW}→ Ingen automatisk default-VLAN kopplas vid skapande.${RESET}"
                    echo -e "${YELLOW}→ Koppla VLAN manuellt via menyval 15 eller importera från cupsd.conf via menyval 18.${RESET}"
                    sudo cupsenable "$printer_name" 2>/dev/null || true
                    echo -e "${GREEN}✓ Skrivaren $printer_name är tillagd.${RESET}"
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
        13)
            echo -e "${CYAN}→ Byt skrivare till IPP Everywhere (fix \"Local Raw Printer\")${RESET}"
            select_printer_interactive "Ange nummer eller skrivarens namn (eller 'b' för tillbaka): "
            fix_printer="$SELECTED_PRINTER"
            [ -z "$fix_printer" ] || {
                fix_uri=$(lpstat -v 2>/dev/null | sed -n "s/^device for $fix_printer: //p")
                if [ -n "$fix_uri" ]; then
                    sudo lpadmin -p "$fix_printer" -v "$fix_uri" -m everywhere -E
                fi
            }
            ;;
        14)
            vlan_catalog_menu
            ;;
        15)
            assign_vlans_to_printer_menu
            ;;
        16)
            remove_vlan_from_printer_menu
            ;;
        17)
            show_printer_vlan_links_menu
            ;;
        18)
            echo -e "${CYAN}→ Importera/synka VLAN från cupsd.conf${RESET}"
            import_vlans_from_cupsd_menu
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
