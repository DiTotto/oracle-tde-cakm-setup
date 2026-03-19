# CAKM + Oracle TDE — Script di configurazione

Questo script automatizza la configurazione di Oracle TDE su un database **Oracle Single Instance** con gestione delle chiavi di cifratura su HSM.

> ⚠️ Questo script è pensato per configurare TDE da zero su un database Oracle che non ha mai avuto TDE abilitata. Non è adatto a migrare una configurazione TDE esistente o a riconfigurare un wallet già presente.

---

## Ambienti supportati

| Componente        | Versione testata      |
|-------------------|-----------------------|
| Sistema operativo | Oracle Linux 8 (OL8)  |
| Oracle Database   | 19.27                 |
| CAKM              | 8.14.1.002            |

---

## ⚠️ Operazioni preliminari sul KMS (da fare PRIMA di eseguire lo script)

La macchina virtuale su cui si va a configurare Oracle per la gestione delle chiavi in HSM deve essere già configurata per la comunicazione corretta con il KMS. In particolare, devono essere già stati eseguiti i seguenti step:

- **1.1** — Installazione del client CAKM sul server Oracle
- **1.2** — Configurazione PKCS#11 e collegamento della libreria (`libcadp_pkcs11.so`)
- **1.3** — Configurazione SSL nel file `CADP_PKCS11.properties`

Il modulo 1 dello script verifica automaticamente che tutti questi step siano stati completati correttamente e blocca l'esecuzione in caso contrario.

Fare riferimento alla documentazione operativa CAKM per il dettaglio delle operazioni.



## Prerequisiti sul server Oracle

### Il database deve essere acceso

Lo script esegue comandi SQL via `sqlplus`. Il database Oracle deve essere **avviato e aperto** prima di eseguire i moduli 5 e 6. Verificare:

```bash
su - oracle -c "sqlplus -S / as sysdba <<'EOF'
SELECT STATUS FROM V\$INSTANCE;
EXIT;
EOF"
```

Il risultato deve essere `OPEN`.

### Il percorso  `WALLET_PATH` deve essere vuoto

Assicurarsi che all'interno del percorso specificato in  `WALLET_PATH`, all'interno della directory  `tde`, non vi sia alcuna traccia di configurazione di chiavi di cifratura, effettuate in passato. In caso contrario, questo viene controllato dal modulo 1 e l'esecuzione viene terminata.\
Inoltre, verificare che la directory candidata ad essere utilizzata come wallet, sia scrivibile dall'utente Oracle.

---

## Configurazione dello script

Aprire `cakm_setup.sh` e modificare le variabili nella sezione **CONFIGURAZIONE** in testa al file:

| Variabile            | Descrizione                                       | Esempio              |
|----------------------|---------------------------------------------------|----------------------|
| `KMS_IP`             | IP o hostname del KMS                             | `10.0.0.10`          |
| `KMS_PORT_SSL`       | Porta NAE del KMS (verificare sulla GUI)          | `9001`               |
| `KMS_DOMAIN`         | Nome del dominio KMS per questo database          | `rtgn`               |
| `KMS_USER`           | Utente KMS creato per questo database             | `oracle_db_01`       |
| `KMS_PASSWORD`       | Password dell'utente KMS                          | `Password123+`       |
| `ORACLE_USER`        | Utente OS Oracle                                  | `oracle`             |
| `ORACLE_SID`         | SID del database Oracle                           | `ORCL`               |
| `WALLET_PATH`        | Directory del wallet Oracle (su path con backup)  | `/oradata/KWallet`   |
| `AUTOLOGIN_ENABLED`  | `true` per configurare l'autologin (modulo 3)     | `true`               |
| `KEYSTORE_PASSWORD`  | Password del wallet FILE locale (solo modulo 3)   | `KeystorePass123+`   |
| `IS_CDB`             | `true` se il database è un Container Database     | `false`              |

> ⚠️ **`ORACLE_SID` è fortemente consigliato**: se non valorizzato, lo script usa il valore dal `.bash_profile` dell'utente oracle. In presenza di più istanze Oracle sullo stesso server, impostarlo esplicitamente per evitare di operare sull'istanza sbagliata. Il controllo sul valore di ORACLE_SID viene eseguito indipendentemente dal modulo eseguito, cosi da controllare che sia sempre valorizzato

> ⚠️ **`WALLET_PATH`** deve essere su una directory sottoposta a backup. Se il wallet viene perso, i dati cifrati diventano inaccessibili.

> ⚠️ **`KMS_PASSWORD` e `KEYSTORE_PASSWORD`** non devono essere lasciate al valore di default (`password`). Il modulo 1 blocca l'esecuzione se rileva il valore di default.

---

## Database CDB (Container Database)

Se il database è un CDB, impostare `IS_CDB=true` nella sezione CONFIGURAZIONE. Questo abilita una serie di comportamenti specifici per la gestione dei PDB:

**Modulo 1** — verifica che il database sia effettivamente un CDB, elenca i PDB rilevati con il relativo stato e avvisa se nessun PDB è in stato `READ WRITE`.

**Modulo 2** — prima di configurare `TDE_CONFIGURATION=HSM`, apre tutti i PDB con `ALTER PLUGGABLE DATABASE ALL OPEN READ WRITE`. Al termine verifica lo stato del wallet sia nel CDB che in ogni singolo PDB, e controlla la presenza delle chiavi di cifratura sul KMS — attesa una chiave per il CDB (`CON_ID=1`) e una per ogni PDB.

**Modulo 3** — il comportamento è identico a un non-CDB. Al riavvio del database, lo script riaprirà automaticamente tutti i PDB prima di procedere con le fasi successive.

### Stato wallet atteso in un CDB

`V$ENCRYPTION_WALLET` in un CDB mostra una riga per ogni container attivo. Con 1 PDB applicativo le righe saranno sempre 3 (CDB\$ROOT, PDB\$SEED, PDB applicativo), con 2 PDB saranno 4, e così via. Al termine del modulo 3, lo stato atteso è:

```
WRL_TYPE   WALLET_TYPE   STATUS
--------   -----------   ------
FILE       AUTOLOGIN     OPEN      ← CDB$ROOT
HSM        HSM           OPEN      ← CDB$ROOT
FILE       AUTOLOGIN     OPEN      ← PDB$SEED
HSM        HSM           OPEN      ← PDB$SEED
FILE       AUTOLOGIN     OPEN      ← PDB applicativo
HSM        HSM           OPEN      ← PDB applicativo
```

---

## Server con più database Oracle

Se il server ospita più istanze Oracle, lo script deve essere eseguito **una volta per ogni database**, modificando ogni volta le seguenti variabili:

| Variabile       | Perché deve cambiare                                                         |
|-----------------|------------------------------------------------------------------------------|
| `ORACLE_SID`    | Identifica quale istanza Oracle viene configurata                            |
| `WALLET_PATH`   | Ogni database deve avere una directory wallet dedicata e separata            |
| `IS_CDB`        | Impostare correttamente in base alla tipologia del database                  |
| `KMS_USER`      | È consigliato usare un utente KMS distinto per ogni database                 |
| `KMS_PASSWORD`  | Coerente con l'utente KMS scelto                                             |

Esempio per due database sullo stesso server:
```bash
# Prima esecuzione — database ORCL1
# ORACLE_SID="ORCL1"
# WALLET_PATH="/oradata/KWallet/ORCL1"
sudo ./cakm_setup.sh --modulo 1
sudo ./cakm_setup.sh --modulo 2
sudo ./cakm_setup.sh --modulo 3

# Seconda esecuzione — database ORCL2
# ORACLE_SID="ORCL2"
# WALLET_PATH="/oradata/KWallet/ORCL2"
sudo ./cakm_setup.sh --reset   # azzera lo stato prima di procedere con il secondo DB
sudo ./cakm_setup.sh --modulo 1
sudo ./cakm_setup.sh --modulo 2
sudo ./cakm_setup.sh --modulo 3
```

> ⚠️ Non condividere mai lo stesso `WALLET_PATH` tra database diversi: ogni wallet contiene la Master Key specifica del database a cui appartiene.

---

## Checklist pre-esecuzione

Prima di lanciare lo script, verificare ogni punto:

- [ ] Operazioni preliminari sul KMS completate (sezione sopra)
- [ ] Database Oracle avviato e in stato `OPEN`
- [ ] `ORACLE_SID` impostato correttamente nella sezione CONFIGURAZIONE
- [ ] `IS_CDB` impostato correttamente (`true` per CDB, `false` per non-CDB)
- [ ] In caso di CDB: tutti i PDB aperti in stato `READ WRITE`
- [ ] `KMS_PASSWORD` e `KEYSTORE_PASSWORD` impostate (diverse dal valore di default)
- [ ] KMS raggiungibile sulla porta NAE: `timeout 5 bash -c "cat < /dev/null > /dev/tcp/<KMS_IP>/<PORTA>" && echo OK`
- [ ] `WALLET_PATH` su filesystem con spazio sufficiente e sottoposto a backup
- [ ] `WALLET_PATH/tde` inesistente o vuota
- [ ] Script eseguito come **root**

---

## Utilizzo

```bash
# Rendi eseguibile
chmod +x cakm_setup.sh

# Modalità consigliata: un modulo alla volta, verificando l'esito prima di procedere
sudo ./cakm_setup.sh --modulo 1
sudo ./cakm_setup.sh --modulo 2
sudo ./cakm_setup.sh --modulo 3   # solo se AUTOLOGIN_ENABLED=true

# Altri comandi utili
sudo ./cakm_setup.sh --stato           # mostra stato dei moduli
sudo ./cakm_setup.sh --da-modulo 2     # riprende dal modulo 3 in poi
sudo ./cakm_setup.sh --reset           # azzera lo stato (riparte da zero)
./cakm_setup.sh --help                 # mostra l'help
```

> ⚠️ **Eseguire sempre un modulo alla volta** e verificare l'esito prima di procedere al successivo. I moduli 2 e 3 eseguono riavvii del database e operazioni sul wallet TDE — un errore non gestito in questi moduli può lasciare il database in uno stato inconsistente.

---

## Descrizione dei moduli

| N. | Modulo                | Cosa fa                                                                                                                                                     | Tocca il DB? |
|----|-----------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------|:------------:|
| 1  | Verifica prerequisiti | Controlla installazione CAKM, symlink PKCS#11, configurazione SSL, certificati, utente oracle, sqlplus, connettività KMS, password, wallet path             | No           |
| 2  | Wallet Oracle         | Imposta `WALLET_ROOT`, configura `TDE_CONFIGURATION=HSM`, apre il keystore sul KMS, imposta la Master Key TDE. Riavvia il database una volta.               | **Sì**       |
| 3  | Autologin             | Migra la Master Key dal KMS a un wallet FILE locale, aggiunge il secret KMS, crea il keystore di autologin (`cwallet.sso`) e configura la modalità dual `HSM\|FILE`. Al riavvio il wallet si apre automaticamente senza intervento manuale. Riavvia il database due volte. | **Sì**       |

---
## Ripresa in caso di errore

Lo script salva lo stato di ogni modulo in `.cakm_state_<hostname>`. Se un modulo fallisce a metà, correggere il problema e rilanciare lo stesso modulo:

```bash
sudo ./cakm_setup.sh --modulo 2
```

I moduli già completati vengono saltati automaticamente, o rieseguiti solo su conferma esplicita.

Se si vuole ripartire completamente da zero:

```bash
sudo ./cakm_setup.sh --reset
```

### Interruzione durante il modulo 3

Il modulo 3 è il più delicato: un'interruzione a metà può lasciare il wallet in uno stato inconsistente (es. `TDE_CONFIGURATION=FILE` senza wallet autologin creato). In questo caso:

1. Verificare lo stato del wallet: `SELECT WRL_TYPE, WALLET_TYPE, STATUS FROM V$ENCRYPTION_WALLET;`
2. Se il wallet HSM risulta `CLOSED`, aprirlo e gestire la situazione manualmente

---

## Log

Ogni esecuzione produce un log con timestamp in:
```
logs/cakm_setup_<hostname>_<YYYYMMDD_HHMMSS>.log
```

Il log registra tutte le operazioni eseguite. Le credenziali KMS e le password wallet non vengono mai scritte in chiaro nel log.

Per seguire l'esecuzione in tempo reale da un secondo terminale:
```bash
tail -f logs/cakm_setup_$(hostname)_*.log
```

---

## Note su ambienti RAC

Questo script è progettato per **Oracle Single Instance**.
