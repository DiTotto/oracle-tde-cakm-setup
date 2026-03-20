#!/bin/bash
# =============================================================================
# CAKM + Oracle TDE - Script di configurazione
# Target: Oracle Single Instance
# =============================================================================
# Utilizzo:
#   ./cakm_setup.sh                  → esegue tutti i moduli
#   ./cakm_setup.sh --modulo 3       → esegue solo il modulo indicato
#   ./cakm_setup.sh --da-modulo 3    → esegue dal modulo 3 in poi
#   ./cakm_setup.sh --help           → mostra questo messaggio
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURAZIONE — modificare questi valori prima di eseguire lo script
# =============================================================================

# --- KMS ---
KMS_IP="10.0.0.10"                         # IP o hostname del KMS
KMS_PORT_SSL="9001"                        # Porta SSL dell'interfaccia NAE
KMS_DOMAIN="Test_Figlio"                   # Nome del dominio sul KMS
KMS_USER="user"                         # Utente KMS per questo DB Oracle
KMS_PASSWORD="password"                  # Password utente KMS

# --- CAKM ---
CAKM_VERSION="8.14.1.002"
CAKM_PACKAGE="610-000825-007_cakm_for_oracle_tde_linux_64b_v${CAKM_VERSION}.tar.gz"
CAKM_PACKAGE_DIR="/tmp"                    # Directory dove si trova il pacchetto

# --- Certificati (path locali sul server, dopo il trasferimento) ---
CERT_KEY_PASSPHRASE=""                     # lasciare vuoto se la chiave non è cifrata     

# --- Oracle ---
ORACLE_USER="oracle"
ORACLE_GROUP="dba"
ORACLE_SID="test1_N"                              # lasciare vuoto per usare $ORACLE_SID dell'ambiente
WALLET_PATH="/oradata/KWallet"
VERIFY_SSL="no"                            # "yes" per abilitare la verifica del certificato server

# --- Cluster (solo per NAE_IP multipli) ---
KMS_CLUSTER_IPS=""                         # es: "10.0.0.1:10.0.0.2" — lasciare vuoto se KMS singolo

# --- Autologin ---
AUTOLOGIN_ENABLED=true                     # true per abilitare il modulo 6 (autologin)
KEYSTORE_PASSWORD="password"   # password del keystore locale su file (scegliere una password sicura)
IS_CDB=true                               # true se il database è un Container Database (CDB)

# =============================================================================
# VARIABILI INTERNE — non modificare
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
LOG_FILE="${LOG_DIR}/cakm_setup_$(hostname)_$(date +%Y%m%d_%H%M%S).log"
STATE_FILE="${SCRIPT_DIR}/.cakm_state_$(hostname)"
RIAVVIO_AUTOMATICO="unknown" # unknown | yes | no
WALLET_TDE_DIR="${WALLET_PATH}/tde"                                         
KMS_CREDENTIAL="${KMS_DOMAIN}:${KMS_DOMAIN}::${KMS_USER}:${KMS_PASSWORD}"

MODULO_START=1
MODULO_ONLY=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# =============================================================================
# FUNZIONI DI SUPPORTO
# =============================================================================

log() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local log_line="[${timestamp}] [${level}] ${message}"

    echo "${log_line}" >> "${LOG_FILE}"

    case "${level}" in
        INFO)  echo -e "${BLUE}${log_line}${NC}" >&2 ;;
        OK)    echo -e "${GREEN}${log_line}${NC}" >&2 ;;
        WARN)  echo -e "${YELLOW}${log_line}${NC}" >&2 ;;
        ERROR) echo -e "${RED}${log_line}${NC}" >&2 ;;
        *)     echo "${log_line}" >&2 ;;
    esac
}

log_info()  { log "INFO"  "$1"; }
log_ok()    { log "OK"    "$1"; }
log_warn()  { log "WARN"  "$1"; }
log_error() { log "ERROR" "$1"; }

separator() {
    local title="$1"
    local line="================================================================="
    log "INFO" "${line}"
    log "INFO" "  ${title}"
    log "INFO" "${line}"
}

# Verifica se un modulo è già stato completato con successo
modulo_completato() {
    local modulo="$1"
    grep -q "MODULO_${modulo}=OK" "${STATE_FILE}" 2>/dev/null
}

# Segna un modulo come completato
segna_completato() {
    local modulo="$1"
    echo "MODULO_${modulo}=OK" >> "${STATE_FILE}"
    log_ok "Modulo ${modulo} completato e registrato."
}

# Esegui un comando e logga il risultato
esegui() {
    local descrizione="$1"
    shift
    log_info "Eseguo: ${descrizione}"
    log_info "Comando: $*"
    if "$@" >> "${LOG_FILE}" 2>&1; then
        log_ok "${descrizione} — OK"
        return 0
    else
        log_error "${descrizione} — FALLITO (vedi log: ${LOG_FILE})"
        return 1
    fi
}

# Esegui come utente oracle
esegui_come_oracle() {
    local descrizione="$1"
    shift
    esegui "${descrizione}" su - "${ORACLE_USER}" -c "$*"
}

# Esegui comandi SQL via sqlplus
esegui_sql() {
    local descrizione="$1"
    local sql="$2"
    log_info "Eseguo SQL: ${descrizione}"
    echo "${sql}" >> "${LOG_FILE}"

    local risultato
    if risultato=$(su - "${ORACLE_USER}" -c "
        export ORACLE_SID=${ORACLE_SID:-\$ORACLE_SID}
        sqlplus -S / as sysdba << 'SQLEOF'
SET PAGESIZE 100
SET LINESIZE 200
SET FEEDBACK ON
${sql}
EXIT;
SQLEOF
    " 2>&1); then
        echo "${risultato}" >> "${LOG_FILE}"
        log_ok "SQL eseguito con successo: ${descrizione}"
        echo "${risultato}"
        return 0
    else
        echo "${risultato}" >> "${LOG_FILE}"
        log_error "SQL fallito: ${descrizione}"
        return 1
    fi
}
# Esegui SQL senza loggare l'output (per comandi con credenziali)
esegui_sql_secret() {
    local descrizione="$1"
    local sql="$2"
    local sql_tmp
    sql_tmp=$(mktemp /tmp/cakm_sql_XXXXXX.sql)

    log_info "Eseguo SQL (output nascosto): ${descrizione}"

    cat > "${sql_tmp}" << EOF
WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR EXIT FAILURE
SET PAGESIZE 100
SET LINESIZE 200
SET FEEDBACK ON
${sql}
EXIT;
EOF

    chown "${ORACLE_USER}" "${sql_tmp}"

    local risultato
    local exit_code
    risultato=$(su - "${ORACLE_USER}" -c "
        export ORACLE_SID='${ORACLE_SID}'
        sqlplus -S / as sysdba @${sql_tmp}
    " 2>&1)
    exit_code=$?

    # File rimosso subito — contiene credenziali
    rm -f "${sql_tmp}"

    # Log solo dell'esito, mai del contenuto
    echo "[${descrizione}] eseguito — output omesso per sicurezza (exit code: ${exit_code})" >> "${LOG_FILE}"

    if [[ ${exit_code} -ne 0 ]] || echo "${risultato}" | grep -qi "ORA-\|SP2-\|ERROR"; then
        log_error "SQL fallito (exit code: ${exit_code}): ${descrizione}"
        # Logga gli errori ma non l'intero output (potrebbe contenere credenziali)
        echo "${risultato}" | grep -i "ORA-\|SP2-\|ERROR" | tee -a "${LOG_FILE}"
        return 1
    fi

    log_ok "SQL eseguito con successo: ${descrizione}"
    return 0
}

chiedi_conferma() {
    local domanda="$1"
    local risposta
    read -r -p "$(echo -e "${YELLOW}[?] ${domanda} [s/N]: ${NC}")" risposta
    case "${risposta}" in
        [sS]) return 0 ;;
        *)    return 1 ;;
    esac
}

gestisci_riavvio_db() {
    local motivo="$1"

    # Se abbiamo già deciso, non chiediamo più
    if [[ "${RIAVVIO_AUTOMATICO}" == "yes" ]]; then
        log_warn "Riavvio automatico database (${motivo})..."
        esegui_sql "Shutdown database" "SHUTDOWN IMMEDIATE;"
        esegui_sql "Startup database" "STARTUP;"
        log_ok "Database riavviato."
        return 0
    elif [[ "${RIAVVIO_AUTOMATICO}" == "no" ]]; then
        log_warn "Riavvio *non* automatico (${motivo}) — deve essere fatto manualmente."
        log_warn "Comando: sqlplus / as sysdba → SHUTDOWN IMMEDIATE; → STARTUP;"
        chiedi_conferma "Ho riavviato il database manualmente, posso continuare?" || exit 1
        return 0
    fi

    # Prima volta: chiediamo e memorizziamo la scelta
    log_warn "Il database verrà riavviato più volte per applicare le modifiche necessarie."
    if chiedi_conferma "Posso riavviare automaticamente il database per tutta la durata dello script?"; then
        RIAVVIO_AUTOMATICO="yes"
        log_ok "Riavvio automatico abilitato per tutti i passaggi successivi."
        gestisci_riavvio_db "${motivo}"
    else
        RIAVVIO_AUTOMATICO="no"
        log_warn "Riavvio automatico disabilitato: verrà richiesto il riavvio manuale ad ogni step critico."
        gestisci_riavvio_db "${motivo}"
    fi
}


# Mostra help
mostra_help() {
    echo ""
    echo "Utilizzo: $0 [OPZIONE]"
    echo ""
    echo "Opzioni:"
    echo "  --modulo N       Esegui solo il modulo N"
    echo "  --da-modulo N    Esegui dal modulo N in poi"
    echo "  --reset          Cancella lo stato e ricomincia da zero"
    echo "  --stato          Mostra lo stato corrente dei moduli"
    echo "  --help           Mostra questo messaggio"
    echo ""
    echo "Moduli disponibili:"
    echo "  1 - Verifica prerequisiti"
    echo "  2 - Configurazione wallet Oracle (sqlplus)"
    echo "  3 - Configurazione autologin (opzionale)"
    echo ""
}

mostra_stato() {
    separator "STATO CORRENTE DEI MODULI"
    for i in 1 2 3 ; do
        if modulo_completato "${i}"; then
            echo -e "  Modulo ${i}: ${GREEN}COMPLETATO${NC}"
        else
            echo -e "  Modulo ${i}: ${YELLOW}NON COMPLETATO${NC}"
        fi
    done
    echo ""
}

# =============================================================================
# PARSING ARGOMENTI
# =============================================================================

while [[ $# -gt 0 ]]; do
    case "$1" in
        --modulo)
            MODULO_ONLY="$2"; shift 2 ;;
        --da-modulo)
            MODULO_START="$2"; shift 2 ;;
        --reset)
            rm -f "${STATE_FILE}"
            echo "Stato resettato. Rieseguire lo script."
            exit 0 ;;
        --stato)
            mostra_stato; exit 0 ;;
        --help)
            mostra_help; exit 0 ;;
        *)
            echo "Opzione non riconosciuta: $1"; mostra_help; exit 1 ;;
    esac
done

# =============================================================================
# INIZIALIZZAZIONE
# =============================================================================

mkdir -p "${LOG_DIR}"
touch "${LOG_FILE}"

separator "CAKM + Oracle TDE - Setup Script"
log_info "Host:        $(hostname)"
log_info "Data/ora:    $(date)"
log_info "Log file:    ${LOG_FILE}"
log_info "State file:  ${STATE_FILE}"
log_info "Utente:      $(whoami)"
echo ""

# Deve girare come root
if [[ $EUID -ne 0 ]]; then
    log_error "Lo script deve essere eseguito come root (usa sudo)."
    exit 1
fi

# Verifica variabile ORACLE_SID
if [[ -z "${ORACLE_SID}" ]]; then
    ORACLE_SID_ENV=$(su - "${ORACLE_USER}" -c "echo \$ORACLE_SID" 2>/dev/null || true)
    if [[ -n "${ORACLE_SID_ENV}" ]]; then
        ORACLE_SID="${ORACLE_SID_ENV}"
        log_ok "ORACLE_SID rilevato automaticamente: ${ORACLE_SID}"
        
    else
        log_warn "ORACLE_SID non impostato — i comandi sqlplus potrebbero fallire"
    fi
else
    log_ok "ORACLE_SID configurato: ${ORACLE_SID}"
fi

if chiedi_conferma "Procedere con l'ORACLE_SID - ${ORACLE_SID}?"; then
        log_ok "Utilizzo ORACLE_SID: ${ORACLE_SID}"
else
    log_error "ORACLE_SID non confermato dall'utente. Impostare manualmente ORACLE_SID prima di eseguire lo script."
    exit 1
fi

# =============================================================================
# FUNZIONE: Decide se eseguire un modulo
# =============================================================================

esegui_modulo() {
    local num="$1"

    # se è stato specificato --modulo N, esegui solo quello
    [[ -n "${MODULO_ONLY}" && "${MODULO_ONLY}" != "${num}" ]] && return 1

    # se è stato specificato --da-modulo N, salta quelli precedenti
    [[ "${num}" -lt "${MODULO_START}" ]] && return 1

    # se il modulo è già completato, chiedi se rieseguire
    if modulo_completato "${num}"; then
        log_warn "Modulo ${num} già completato in precedenza."
        if chiedi_conferma "Vuoi rieseguirlo?"; then
            return 0
        else
            return 1
        fi
    fi

    return 0
}

# =============================================================================
# MODULO 1 — VERIFICA PREREQUISITI
# =============================================================================

if esegui_modulo 1; then
    separator "MODULO 1 — Verifica prerequisiti"
    ERRORI=0


    # Verifica step 1.1 — Installazione CAKM
    CAKM_INSTALL_DIR="/opt/CipherTrust/CAKM_for_Oracle_TDE"
    CAKM_PROPERTIES="${CAKM_INSTALL_DIR}/CADP_PKCS11.properties"

    if [[ -d "${CAKM_INSTALL_DIR}" ]]; then
        log_ok "Directory installazione CAKM trovata: ${CAKM_INSTALL_DIR}"
    else
        log_error "CAKM non installato — directory non trovata: ${CAKM_INSTALL_DIR}"
        log_error "Eseguire lo step 1.1: cd /tmp/CipherTrust_Application_Key_Management/ && sudo ./install.sh"
        ((ERRORI++))
    fi

    if [[ -f "${CAKM_PROPERTIES}" ]]; then
        log_ok "File properties CAKM trovato: ${CAKM_PROPERTIES}"
    else
        log_error "File properties CAKM non trovato: ${CAKM_PROPERTIES}"
        ((ERRORI++))
    fi

    # Verifica Configurazione PKCS#11
    PKCS11_DIR="/opt/oracle/extapi/64/hsm/CipherTrust/CAKM_for_Oracle_TDE"
    PKCS11_LIB="${PKCS11_DIR}/libcadp_pkcs11.so"

    if [[ -d "${PKCS11_DIR}" ]]; then
        log_ok "Directory PKCS#11 trovata: ${PKCS11_DIR}"
    else
        log_error "Directory PKCS#11 non trovata: ${PKCS11_DIR}"
        log_error "Eseguire lo step 1.2: mkdir -p ${PKCS11_DIR}"
        ((ERRORI++))
    fi

    # Verifica LIBRARY_PATH nel .bash_profile di oracle
    BASH_PROFILE="/home/${ORACLE_USER}/.bash_profile"
    if grep -q "LIBRARY_PATH" "${BASH_PROFILE}" 2>/dev/null; then
        log_ok "LIBRARY_PATH presente in ${BASH_PROFILE}"
    else
        log_error "LIBRARY_PATH non trovato in ${BASH_PROFILE}"
        log_error "Eseguire lo step 1.2: echo 'export LIBRARY_PATH=${PKCS11_DIR}' >> ${BASH_PROFILE}"
        ((ERRORI++))
    fi

    # Verifica utente oracle
    if id "${ORACLE_USER}" &>/dev/null; then
        log_ok "Utente oracle trovato: ${ORACLE_USER}"
    else
        log_error "Utente Oracle non trovato: ${ORACLE_USER}"
        ((ERRORI++))
    fi

    # Verifica sqlplus
    if su - "${ORACLE_USER}" -c "which sqlplus" &>/dev/null; then
        log_ok "sqlplus trovato"
    else
        log_error "sqlplus non trovato nel PATH dell'utente ${ORACLE_USER}"
        ((ERRORI++))
    fi

    # Verifica connettività KMS
    log_info "Verifico connettività verso KMS ${KMS_IP}:${KMS_PORT_SSL}..."
    if timeout 5 bash -c "cat < /dev/null > /dev/tcp/${KMS_IP}/${KMS_PORT_SSL}" 2>/dev/null; then
        log_ok "KMS raggiungibile su ${KMS_IP}:${KMS_PORT_SSL}"
    else
        log_warn "KMS non raggiungibile su ${KMS_IP}:${KMS_PORT_SSL} — verificare la connettività di rete"
        # warn, non errore bloccante: potrebbe essere un problema temporaneo
    fi

    # Verifica che WALLET_PATH sia vuoto (o non esista)
    WALLET_TDE_DIR="${WALLET_PATH}/tde"
    if [[ -d "${WALLET_TDE_DIR}" ]]; then
        WALLET_FILES=$(find "${WALLET_TDE_DIR}" -mindepth 1 2>/dev/null)
        if [[ -n "${WALLET_FILES}" ]]; then
            log_error "La directory wallet '${WALLET_TDE_DIR}' non è vuota. Contenuto trovato:"
            find "${WALLET_TDE_DIR}" -mindepth 1 | tee -a "${LOG_FILE}"
            log_error "Rimuovere o spostare i file esistenti prima di procedere."
            ((ERRORI++))
        else
            log_ok "Directory wallet '${WALLET_TDE_DIR}' esistente e vuota — OK."
        fi
    else
        log_ok "Directory wallet '${WALLET_TDE_DIR}' non ancora presente — verrà creata nel modulo 2."
    fi

    # Verifica permessi di scrittura su WALLET_PATH o sulla sua parent directory
    if [[ -d "${WALLET_PATH}" ]]; then
        CHECK_DIR="${WALLET_PATH}"
    else
        CHECK_DIR="$(dirname "${WALLET_PATH}")"
    fi

    if su - "${ORACLE_USER}" -c "test -w '${CHECK_DIR}'" 2>/dev/null; then
        log_ok "Utente '${ORACLE_USER}' ha permessi di scrittura su '${CHECK_DIR}'"
    else
        log_error "Utente '${ORACLE_USER}' non ha permessi di scrittura su '${CHECK_DIR}'"
        ((ERRORI++))
    fi

    # Verifica che il database sia in running
    DB_STATUS=$(su - "${ORACLE_USER}" -c "
        export ORACLE_SID=${ORACLE_SID}
        sqlplus -S / as sysdba << 'SQLEOF'
SET PAGESIZE 0 FEEDBACK OFF
SELECT STATUS FROM V\$INSTANCE;
EXIT;
SQLEOF
    " 2>/dev/null | tr -d '[:space:]')

    if echo "${DB_STATUS}" | grep -qi "OPEN"; then
        log_ok "Database in stato OPEN — OK"
    else
        log_error "Database non risulta in stato OPEN (stato rilevato: '${DB_STATUS}'). Avviare il database prima di procedere."
        ((ERRORI++))
    fi

    # Verifica che le password siano state settate
    for VAR_NAME in "KMS_PASSWORD" "KEYSTORE_PASSWORD"; do
        VAR_VALUE="${!VAR_NAME}"

        if [[ "${VAR_VALUE}" == "password" ]]; then
            log_error "${VAR_NAME} non è stata modificata dal valore di default — impostare un valore nella sezione CONFIGURAZIONE."
            ((ERRORI++))
        else
            log_ok "${VAR_NAME} impostata."
        fi
    done

    # Verifica che l'utenza KMS_USER non sia quella di default 
    if [[ "${KMS_USER}" == "USER" ]]; then
        log_error "KMS_USER non impostato. Modificarlo con un nome utente specifico per questo database."
        ((ERRORI++))
    else
        log_ok "KMS_USER sembra essere personalizzato: ${KMS_USER}"
    fi

    if [[ ${ERRORI} -gt 0 ]]; then
        log_error "Trovati ${ERRORI} errori nei prerequisiti. Correggili prima di continuare."
        exit 1
    fi

    # Verifica CDB e lista PDB
    if [[ "${IS_CDB}" == "true" ]]; then
        log_info "Configurazione CDB abilitata — verifico la presenza di PDB..."

        PDB_LIST=$(esegui_sql "Lista PDB" \
            "SET PAGES 0 FEEDBACK OFF
             SELECT NAME || ' (' || OPEN_MODE || ')' FROM V\$PDBS ORDER BY NAME;")

        if [[ -z "${PDB_LIST}" ]]; then
            log_error "IS_CDB=true ma nessun PDB rilevato — verificare che ORACLE_SID punti a un CDB."
            ((ERRORI++))
        else
            log_ok "PDB rilevati:"
            while IFS= read -r PDB_LINE; do
                [[ -z "${PDB_LINE}" ]] && continue
                log_info "  → ${PDB_LINE}"
            done <<< "${PDB_LIST}"

            # Verifica che almeno un PDB sia READ WRITE
            PDB_OPEN=$(echo "${PDB_LIST}" | grep -i "READ WRITE" || true)
            if [[ -z "${PDB_OPEN}" ]]; then
                log_warn "Nessun PDB in stato READ WRITE — i PDB devono essere aperti prima di procedere con il modulo 2."
            else
                log_ok "Almeno un PDB in stato READ WRITE."
            fi
        fi
    fi

    log_ok "Tutti i prerequisiti verificati con successo."
    segna_completato 1
fi

# =============================================================================
# MODULO 2 — CONFIGURAZIONE WALLET ORACLE (sqlplus)
# =============================================================================
 
if esegui_modulo 2; then
    separator "MODULO 2 — Configurazione wallet Oracle"
 
    # Crea directory wallet
    log_info "Creo directory wallet: ${WALLET_PATH}"
    esegui "Creazione directory wallet" mkdir -p "${WALLET_PATH}"
    esegui "Permessi directory wallet" \
        chown -R "${ORACLE_USER}:${ORACLE_GROUP}" "${WALLET_PATH}"
 
    # Imposta WALLET_ROOT e riavvia il DB
    log_info "Imposto WALLET_ROOT e riavvio il database..."
    esegui_sql "Impostazione WALLET_ROOT" \
        "ALTER SYSTEM SET WALLET_ROOT='${WALLET_PATH}' SCOPE=SPFILE;"
 
    gestisci_riavvio_db "Applicazione WALLET_ROOT"

    # Configura TDE per usare HSM
    log_info "Configuro TDE_CONFIGURATION=HSM..."
    if [[ "${IS_CDB}" == "true" ]]; then
        esegui_sql "Apertura di tutti i PDB" \
            "ALTER PLUGGABLE DATABASE ALL OPEN READ WRITE;"
    fi
    esegui_sql "Configurazione TDE per HSM" \
        "ALTER SYSTEM SET TDE_CONFIGURATION='KEYSTORE_CONFIGURATION=HSM' SCOPE=BOTH;"
 
    # Verifica stato wallet (atteso: CLOSED o NOT_AVAILABLE)
    log_info "Verifica stato wallet prima dell'apertura..."
    STATO_PRE=$(esegui_sql "Stato wallet iniziale" \
        "COLUMN WRL_PARAMETER FORMAT A50
         SELECT WRL_TYPE, WRL_PARAMETER, WALLET_TYPE, STATUS FROM V\$ENCRYPTION_WALLET;")
    log_info "Stato attuale wallet:"
    echo "${STATO_PRE}" | tee -a "${LOG_FILE}"
 
    # Apri keystore sul KMS
    log_info "Apro il keystore sul KMS..."
    if [[ "${IS_CDB}" == "true" ]]; then
        esegui_sql_secret "Apertura keystore sul KMS" \
        "ADMINISTER KEY MANAGEMENT SET KEYSTORE OPEN IDENTIFIED BY \"${KMS_CREDENTIAL}\" CONTAINER=ALL;" \
        || exit 1
    else
        esegui_sql_secret "Apertura keystore sul KMS" \
        "ADMINISTER KEY MANAGEMENT SET KEYSTORE OPEN IDENTIFIED BY \"${KMS_CREDENTIAL}\";" \
        || exit 1
    fi
    
    log_ok "Keystore aperto sul KMS."
 
    # Imposta Master Key TDE
    # ORA-28415 = chiave già esistente nel KMS — accettabile se il modulo 5
    # era già stato completato in un run precedente. Usiamo un file temporaneo
    # (non heredoc inline) per evitare blocchi con su -c.
    log_info "Imposto la Master Key TDE sul KMS..."
    
    SET_KEY_TMP=$(mktemp /tmp/cakm_sql_XXXXXX.sql)
    if [[ "${IS_CDB}" == "true" ]]; then
        cat > "${SET_KEY_TMP}" << EOF
SET PAGESIZE 100
SET LINESIZE 200
ADMINISTER KEY MANAGEMENT SET KEY IDENTIFIED BY "${KMS_CREDENTIAL}" CONTAINER=ALL;
EXIT;
EOF
    else
        cat > "${SET_KEY_TMP}" << EOF
SET PAGESIZE 100
SET LINESIZE 200
ADMINISTER KEY MANAGEMENT SET KEY IDENTIFIED BY "${KMS_CREDENTIAL}";
EXIT;
EOF
    fi
    
    chown "${ORACLE_USER}" "${SET_KEY_TMP}"
 
SET_KEY_OUTPUT=$(su - "${ORACLE_USER}" -c "
    export ORACLE_SID='${ORACLE_SID}'
    sqlplus -S / as sysdba @${SET_KEY_TMP}
" 2>&1)
    SET_KEY_EXIT=$?
    rm -f "${SET_KEY_TMP}"
 
    echo "[SET KEY] eseguito (exit code: ${SET_KEY_EXIT})" >> "${LOG_FILE}"
 
    if [[ ${SET_KEY_EXIT} -eq 0 ]]; then
        log_ok "Master Key TDE impostata sul KMS."
    elif echo "${SET_KEY_OUTPUT}" | grep -q "ORA-28415"; then
        log_warn "Master Key già esistente nel KMS (ORA-28415) — wallet già configurato, procedo."
    else
        log_error "Impostazione Master Key fallita (exit code: ${SET_KEY_EXIT}):"
        echo "${SET_KEY_OUTPUT}" | grep -i "ORA-\|ERROR" | tee -a "${LOG_FILE}"
        exit 1
    fi
 
    # Verifica finale dello stato del wallet
    log_info "Verifica finale stato wallet..."
    STATO_FINALE=$(esegui_sql "Stato wallet finale" \
        "COLUMN WRL_PARAMETER FORMAT A50
         COLUMN WALLET_TYPE FORMAT A15
         COLUMN STATUS FORMAT A20
         SELECT WRL_TYPE, WRL_PARAMETER, WALLET_TYPE, STATUS FROM V\$ENCRYPTION_WALLET;")
    
    log_info "Stato finale wallet:"
    echo "${STATO_FINALE}" | tee -a "${LOG_FILE}"
 
    # Verifica che lo stato sia OPEN
    if echo "${STATO_FINALE}" | grep -qi "OPEN"; then
        log_ok "Wallet in stato OPEN — configurazione completata con successo!"
    else
        log_error "Wallet NON in stato OPEN. Verificare manualmente."
        exit 1
    fi

    # Verifiche aggiuntive per CDB
    if [[ "${IS_CDB}" == "true" ]]; then

        # Recupera la lista dei PDB aperti
        PDB_LIST=$(esegui_sql "Lista PDB aperti" \
            "SET PAGES 0 FEEDBACK OFF
             SELECT NAME FROM V\$PDBS WHERE OPEN_MODE='READ WRITE';")

        if [[ -z "${PDB_LIST}" ]]; then
            log_warn "Nessun PDB in stato READ WRITE trovato — saltato il controllo per singolo PDB."
        else
            # Verifica stato wallet dentro ogni PDB
            log_info "Verifica stato wallet per ogni PDB..."
            while IFS= read -r PDB_NAME; do
                PDB_NAME=$(echo "${PDB_NAME}" | tr -d '[:space:]')
                [[ -z "${PDB_NAME}" ]] && continue

                STATO_PDB=$(esegui_sql "Stato wallet in PDB ${PDB_NAME}" \
                    "ALTER SESSION SET CONTAINER=${PDB_NAME};
                     COLUMN WRL_PARAMETER FORMAT A50
                     COLUMN WALLET_TYPE FORMAT A15
                     COLUMN STATUS FORMAT A20
                     SET LINES 200
                     SELECT WRL_TYPE, WRL_PARAMETER, WALLET_TYPE, STATUS FROM V\$ENCRYPTION_WALLET;")

                echo "${STATO_PDB}" | tee -a "${LOG_FILE}"

                if echo "${STATO_PDB}" | grep -qi "OPEN"; then
                    log_ok "Wallet aperto correttamente nel PDB: ${PDB_NAME}"
                else
                    log_error "Wallet NON risulta OPEN nel PDB: ${PDB_NAME}"
                    exit 1
                fi
            done <<< "${PDB_LIST}"
        fi

        # Verifica chiavi di cifratura: attesa una chiave per CDB + una per ogni PDB
        log_info "Verifica chiavi di cifratura sul KMS (attesa: 1 chiave CDB + 1 per ogni PDB)..."
        CHIAVI=$(esegui_sql "Chiavi di cifratura" \
            "COLUMN KEY_ID FORMAT A70
             SET LINES 200
             SELECT CON_ID, KEY_ID, CREATION_TIME FROM V\$ENCRYPTION_KEYS
             WHERE CON_ID > 0
             ORDER BY CON_ID;")

        log_info "Chiavi trovate:"
        echo "${CHIAVI}" | tee -a "${LOG_FILE}"

        NUM_CHIAVI=$(echo "${CHIAVI}" | grep -c "^[[:space:]]*[0-9][0-9]*[[:space:]]" || true)
        NUM_PDB=$(echo "${PDB_LIST}" | grep -vc '^[[:space:]]*$' || true)
        CHIAVI_ATTESE=$(( NUM_PDB + 1 )) # +1 per il CDB (CON_ID=1)

        if [[ ${NUM_CHIAVI} -ge ${CHIAVI_ATTESE} ]]; then
            log_ok "Trovate ${NUM_CHIAVI} chiavi — attese almeno ${CHIAVI_ATTESE} (1 CDB + ${NUM_PDB} PDB)."
        else
            log_warn "Trovate ${NUM_CHIAVI} chiavi, attese almeno ${CHIAVI_ATTESE} — verificare manualmente."
        fi
    fi
 
    segna_completato 2
fi

# =============================================================================
# MODULO 3 — CONFIGURAZIONE AUTOLOGIN
# =============================================================================
 
if [[ "${AUTOLOGIN_ENABLED}" == "true" ]] && esegui_modulo 3; then
    separator "MODULO 3 — Configurazione Autologin"
 
 
    # ------------------------------------------------------------------
    # CONTROLLO PRELIMINARE — Pulizia run precedenti parziali
    # ------------------------------------------------------------------
    # Se esistono già cwallet.sso o ewallet.p12 da un run precedente
    # interrotto, li spostiamo in backup per evitare ORA-46630
    WALLET_FILES_ESISTENTI=false
    for f in "${WALLET_TDE_DIR}/cwallet.sso" "${WALLET_TDE_DIR}/ewallet.p12"; do
        [[ -f "${f}" ]] && WALLET_FILES_ESISTENTI=true && break
    done
 
    if [[ "${WALLET_FILES_ESISTENTI}" == "true" ]]; then
        log_warn "Trovati file wallet da un run precedente in ${WALLET_TDE_DIR}:"
        ls -la "${WALLET_TDE_DIR}/" | tee -a "${LOG_FILE}"
 
        BACKUP_DIR="${WALLET_PATH}/tde_backup_$(date +%Y%m%d_%H%M%S)"
        mkdir -p "${BACKUP_DIR}"
 
        # ewallet.p12 va CONSERVATO — contiene la chiave già migrata da HSM.
        # Cancellandolo Oracle rifiuterebbe un nuovo REVERSE MIGRATE con ORA-28410.
        # Spostiamo solo cwallet.sso (verrà ricreato) e i file di backup con timestamp.
        if [[ -f "${WALLET_TDE_DIR}/cwallet.sso" ]]; then
            mv "${WALLET_TDE_DIR}/cwallet.sso" "${BACKUP_DIR}/" 2>/dev/null || true
            log_info "cwallet.sso spostato in backup (verrà ricreato)."
        fi
        find "${WALLET_TDE_DIR}" -name "ewallet_*.p12" \
            -exec mv {} "${BACKUP_DIR}/" \; 2>/dev/null || true
 
        log_ok "ewallet.p12 mantenuto — contiene la chiave già migrata da HSM."
        log_info "Contenuto attuale di ${WALLET_TDE_DIR}:"
        ls -la "${WALLET_TDE_DIR}/" | tee -a "${LOG_FILE}"
    fi

 
    # ------------------------------------------------------------------
    # FASE 2 — TDE_CONFIGURATION=FILE
    # ------------------------------------------------------------------
    log_info "FASE 2 — Imposto TDE_CONFIGURATION=FILE..."
    esegui_sql "Configurazione TDE su FILE" \
        "ALTER SYSTEM SET TDE_CONFIGURATION='KEYSTORE_CONFIGURATION=FILE' SCOPE=BOTH;"
 
    TDE_CHECK=$(esegui_sql "Verifica TDE parameter" "SHOW PARAMETER tde;")
    echo "${TDE_CHECK}" | tee -a "${LOG_FILE}"
    if echo "${TDE_CHECK}" | grep -qi "KEYSTORE_CONFIGURATION=FILE"; then
        log_ok "TDE_CONFIGURATION=FILE confermato."
    else
        log_error "TDE_CONFIGURATION non risulta FILE — verificare."
        exit 1
    fi
 
    STATO=$(esegui_sql "Stato wallet dopo switch a FILE" \
        "COLUMN WRL_PARAMETER FORMAT A50
         COLUMN WALLET_TYPE FORMAT A15
         COLUMN STATUS FORMAT A20
         SELECT WRL_TYPE, WRL_PARAMETER, WALLET_TYPE, STATUS FROM V\$ENCRYPTION_WALLET;")
    echo "${STATO}" | tee -a "${LOG_FILE}"
 
    # ------------------------------------------------------------------
    # FASE 3+4 — Crea wallet FILE, aprilo e fai REVERSE MIGRATE
    # in un'UNICA sessione sqlplus.
    # Motivo: il wallet FILE aperto in una sessione non è visibile
    # alla sessione successiva — CREATE/OPEN/REVERSE MIGRATE devono
    # avvenire nella stessa connessione sqlplus.
    # ------------------------------------------------------------------
    log_info "FASE 3+4 — Creo wallet FILE e faccio REVERSE MIGRATE in sessione unica..."
 
    FASE34_TMP=$(mktemp /tmp/cakm_sql_XXXXXX.sql)
    if [[ "${IS_CDB}" == "true" ]]; then
        cat > "${FASE34_TMP}" << EOF
SET PAGESIZE 100
SET LINESIZE 200
SET FEEDBACK ON
ADMINISTER KEY MANAGEMENT CREATE KEYSTORE IDENTIFIED BY "${KEYSTORE_PASSWORD}";
ADMINISTER KEY MANAGEMENT SET KEYSTORE OPEN IDENTIFIED BY "${KEYSTORE_PASSWORD}" CONTAINER=ALL;
ADMINISTER KEY MANAGEMENT SET ENCRYPTION KEY IDENTIFIED BY "${KEYSTORE_PASSWORD}" REVERSE MIGRATE USING "${KMS_CREDENTIAL}" WITH BACKUP;
SELECT WRL_TYPE, WRL_PARAMETER, WALLET_TYPE, STATUS FROM V\$ENCRYPTION_WALLET;
EXIT;
EOF
    else
        cat > "${FASE34_TMP}" << EOF
SET PAGESIZE 100
SET LINESIZE 200
SET FEEDBACK ON
ADMINISTER KEY MANAGEMENT CREATE KEYSTORE IDENTIFIED BY "${KEYSTORE_PASSWORD}";
ADMINISTER KEY MANAGEMENT SET KEYSTORE OPEN IDENTIFIED BY "${KEYSTORE_PASSWORD}";
ADMINISTER KEY MANAGEMENT SET ENCRYPTION KEY IDENTIFIED BY "${KEYSTORE_PASSWORD}" REVERSE MIGRATE USING "${KMS_CREDENTIAL}" WITH BACKUP;
SELECT WRL_TYPE, WRL_PARAMETER, WALLET_TYPE, STATUS FROM V\$ENCRYPTION_WALLET;
EXIT;
EOF
    fi
 
    chown "${ORACLE_USER}" "${FASE34_TMP}"
    log_info "Eseguo CREATE KEYSTORE + OPEN + REVERSE MIGRATE in sessione unica [credenziali omesse]"
 
    FASE34_OUT=$(su - "${ORACLE_USER}" -c "
        export ORACLE_SID='${ORACLE_SID}'
        sqlplus -S / as sysdba @${FASE34_TMP}
    " 2>&1)
    FASE34_RC=$?
    rm -f "${FASE34_TMP}"
 
    echo "[FASE34] exit code: ${FASE34_RC}" >> "${LOG_FILE}"
    # Log dell'output senza mostrare credenziali a terminale
    echo "${FASE34_OUT}" >> "${LOG_FILE}"
 
    # Controlla errori fatali:
    # - ORA-28354 = wallet già aperto → accettabile, procedi
    # - ORA-28410 = chiave già migrata in run precedente → accettabile,
    #               ewallet.p12 contiene già la chiave, procedi
    FASE34_ERRORS=$(echo "${FASE34_OUT}" | grep "ORA-" | grep -v "ORA-28354\|ORA-28410" || true)
 
    if [[ -n "${FASE34_ERRORS}" ]]; then
        log_error "Errori in FASE 3+4:"
        echo "${FASE34_ERRORS}" | tee -a "${LOG_FILE}"
        exit 1
    fi
 
    if echo "${FASE34_OUT}" | grep -q "ORA-28410"; then
        log_warn "ORA-28410: chiave già migrata in run precedente — ewallet.p12 esistente contiene la chiave, procedo."
    elif echo "${FASE34_OUT}" | grep -qi "keystore altered\|key management"; then
        log_ok "REVERSE MIGRATE completato — Master Key locale creata."
    else
        log_warn "Output inatteso da FASE 3+4 — verificare il log: ${LOG_FILE}"
    fi
 
    # Verifica stato in una nuova sessione
    STATO=$(esegui_sql "Stato wallet dopo reverse migrate"         "COLUMN WRL_PARAMETER FORMAT A50
         COLUMN WALLET_TYPE FORMAT A15
         COLUMN STATUS FORMAT A20
         SELECT WRL_TYPE, WRL_PARAMETER, WALLET_TYPE, STATUS FROM V\$ENCRYPTION_WALLET;")
    echo "${STATO}" | tee -a "${LOG_FILE}"
 
    log_ok "Fasi 3+4 completate."
 
    # ------------------------------------------------------------------
    # FASE 5 — Aggiunge il secret KMS al keystore locale
    # ------------------------------------------------------------------
    log_info "FASE 5 — Aggiungo il secret KMS al keystore locale (HSM_PASSWORD)..."
    esegui_sql_secret "Aggiunta secret HSM_PASSWORD" \
        "ADMINISTER KEY MANAGEMENT ADD SECRET '${KMS_CREDENTIAL}' FOR CLIENT 'HSM_PASSWORD' IDENTIFIED BY \"${KEYSTORE_PASSWORD}\" WITH BACKUP;" \
        || exit 1
    log_ok "Secret HSM_PASSWORD aggiunto al keystore locale."
 
    # ------------------------------------------------------------------
    # FASE 6 — Crea il keystore di autologin
    # ------------------------------------------------------------------
    log_info "FASE 6 — Creo il keystore di autologin (cwallet.sso)..."
    esegui_sql_secret "Creazione autologin keystore" \
        "ADMINISTER KEY MANAGEMENT CREATE AUTO_LOGIN KEYSTORE FROM KEYSTORE IDENTIFIED BY \"${KEYSTORE_PASSWORD}\";" \
        || exit 1
    log_ok "Autologin keystore creato."
 
    CWALLET_PATH="${WALLET_PATH}/tde/cwallet.sso"
    if su - "${ORACLE_USER}" -c "test -f '${CWALLET_PATH}'" 2>/dev/null; then
        log_ok "File cwallet.sso trovato in: ${CWALLET_PATH}"
    else
        log_warn "File cwallet.sso non trovato in ${CWALLET_PATH} — verificare il path del wallet."
    fi
 
    # ------------------------------------------------------------------
    # FASE 7 — Riavvio per attivare l'autologin
    # ------------------------------------------------------------------
    gestisci_riavvio_db "Attivazione autologin"
    if [[ "${IS_CDB}" == "true" ]]; then
        esegui_sql "Apertura di tutti i PDB" \
            "ALTER PLUGGABLE DATABASE ALL OPEN READ WRITE;"
    fi

 
    # ------------------------------------------------------------------
    # FASE 8 — Dual mode HSM|FILE
    # ------------------------------------------------------------------
    log_info "FASE 8 — Imposto la modalità dual: HSM|FILE..."
    esegui_sql "Configurazione TDE dual mode HSM|FILE" \
        "ALTER SYSTEM SET TDE_CONFIGURATION='KEYSTORE_CONFIGURATION=HSM|FILE' SCOPE=BOTH;"
 
    STATO=$(esegui_sql "Stato wallet dual mode" \
        "COLUMN WRL_PARAMETER FORMAT A50
         COLUMN WALLET_TYPE FORMAT A15
         COLUMN STATUS FORMAT A20
         SELECT WRL_TYPE, WRL_PARAMETER, WALLET_TYPE, STATUS FROM V\$ENCRYPTION_WALLET;")
    echo "${STATO}" | tee -a "${LOG_FILE}"
 
    if echo "${STATO}" | grep -i "FILE" | grep -qi "OPEN\|AUTOLOGIN"; then
        log_ok "Wallet FILE attivo — procedo con la migrazione al KMS."
    else
        log_error "Wallet FILE non risulta attivo — verificare."
        exit 1
    fi
 
    # ------------------------------------------------------------------
    # FASE 9 — Migrazione finale dal wallet locale al KMS
    # ------------------------------------------------------------------
    log_info "FASE 9 — Migrazione finale: Master Key da wallet locale al KMS..."
    esegui_sql_secret "Migrazione Master Key al KMS" \
        "ADMINISTER KEY MANAGEMENT SET ENCRYPTION KEY IDENTIFIED BY \"${KMS_CREDENTIAL}\" FORCE KEYSTORE MIGRATE USING \"${KEYSTORE_PASSWORD}\";" \
        || exit 1
    log_ok "Migrazione al KMS completata."
 
    # ------------------------------------------------------------------
    # FASE 10 — Riavvio finale e verifica
    # ------------------------------------------------------------------
    gestisci_riavvio_db "Riavvio finale per attivare la configurazione definitiva"
    if [[ "${IS_CDB}" == "true" ]]; then
        esegui_sql "Apertura di tutti i PDB" \
            "ALTER PLUGGABLE DATABASE ALL OPEN READ WRITE;"
    fi
 
    log_info "Verifica finale (atteso: HSM=OPEN, FILE=AUTOLOGIN)..."
    STATO_FINALE=$(esegui_sql "Stato wallet finale autologin" \
        "COLUMN WRL_PARAMETER FORMAT A50
         COLUMN WALLET_TYPE FORMAT A15
         COLUMN STATUS FORMAT A20
         SELECT WRL_TYPE, WRL_PARAMETER, WALLET_TYPE, STATUS FROM V\$ENCRYPTION_WALLET;")
    echo "${STATO_FINALE}" | tee -a "${LOG_FILE}"
 
    HSM_OK=false
    FILE_OK=false
    echo "${STATO_FINALE}" | grep -i "HSM"  | grep -qi "OPEN"      && HSM_OK=true
    echo "${STATO_FINALE}" | grep -i "FILE" | grep -qi "AUTOLOGIN" && FILE_OK=true
 
    if [[ "${HSM_OK}" == "true" && "${FILE_OK}" == "true" ]]; then
        log_ok "Configurazione autologin completata con successo!"
        log_ok "  → Wallet HSM:  OPEN      (chiavi sul KMS)"
        log_ok "  → Wallet FILE: AUTOLOGIN (si apre automaticamente al riavvio)"
    else
        [[ "${HSM_OK}" == "false" ]]  && log_error "Wallet HSM non risulta OPEN."
        [[ "${FILE_OK}" == "false" ]] && log_error "Wallet FILE non risulta AUTOLOGIN."
        exit 1
    fi
 
    segna_completato 3
fi

 
# =============================================================================
# RIEPILOGO FINALE
# =============================================================================

separator "RIEPILOGO CONFIGURAZIONE"
log_info "Host:       $(hostname)"
log_info "Data/ora:   $(date)"
log_info "KMS:        ${KMS_IP}:${KMS_PORT_SSL}"
log_info "Dominio:    ${KMS_DOMAIN}"
log_info "Utente KMS: ${KMS_USER}"
log_info "Wallet:     ${WALLET_PATH}"
echo ""

mostra_stato

log_ok "Script completato. Log completo disponibile in: ${LOG_FILE}"
echo ""

