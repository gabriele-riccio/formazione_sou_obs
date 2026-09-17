# Installazione Splunk Universal Forwarder su VM (RHEL/Rocky 9)

Materiale pronto da controllare prima di applicarlo. Niente è stato eseguito:
nessun SSH, nessuna installazione, nessuna modifica ai server.

## Scope di questa guida

Solo l'installazione dell'**agent** (Splunk Universal Forwarder) su una VM e
la verifica che il servizio parta correttamente. **Non è ancora inclusa**
la configurazione dell'invio dati (outputs.conf verso un indexer/HEC) né
cosa raccogliere (inputs.conf) — quello si fa quando sapremo lo scopo
esatto (log applicativi? infrastruttura? verso quale indexer TIM?).

Target ipotizzato: RHEL/Rocky Linux 9, x86_64 — stesso schema OS usato per
gli altri host di questo ambiente (vedi `Zabbix-IAM-Onboarding/`, che usa
`dnf`/`rpm` su Rocky 9). Se la VM reale è un'altra distro/versione, dimmelo
e aggiorno i comandi.

## Cos'è l'Universal Forwarder (UF)

Non è Splunk Enterprise: è un agente leggero che gira su ogni VM, legge i
log/dati locali definiti in `inputs.conf` e li inoltra a un indexer Splunk
(o a un Heavy Forwarder intermedio). Non ha interfaccia web, non indicizza
nulla localmente — stesso ruolo che ha `zabbix_agent2` per Zabbix, ma per
Splunk.

## 1. Prerequisiti

- Accesso `sudo` sulla VM target.
- Connettività in uscita verso `download.splunk.com` (per scaricare il
  pacchetto) — se la VM non ha accesso internet diretto, il pacchetto va
  scaricato altrove e copiato via `scp`.
- Spazio disco: l'installazione occupa circa 500MB-1GB in `/opt/splunkforwarder`.
- **Da confermare più avanti**: se l'installazione andrà automatizzata via
  Ansible (come gli altri agent in questo ambiente) o resta manuale per
  ora — questa guida è scritta per un'installazione manuale, il porting ad
  Ansible è immediato una volta validata.

## 2. Verifica versione corrente

Prima di scaricare, controlla sulla pagina ufficiale che la versione sotto
sia ancora quella corrente (i link di download cambiano ad ogni release, il
filename include un hash di build):

<https://www.splunk.com/en_us/download/universal-forwarder.html>

Al momento della stesura di questa guida (17 set 2026), la versione stabile
per Linux x86_64 (RPM) risulta:

```
Versione: 10.4.3
File:     splunkforwarder-10.4.3-4174a2deda5d.x86_64.rpm
URL:      https://download.splunk.com/products/universalforwarder/releases/10.4.3/linux/splunkforwarder-10.4.3-4174a2deda5d.x86_64.rpm
```

**Verifica comunque il link sulla pagina ufficiale prima di lanciare il
download** — non fidarti ciecamente di questo valore se sono passati più di
pochi giorni da quando l'hai letto.

## 3. Download e verifica checksum

```bash
cd /tmp

# Scarica il pacchetto (sostituisci l'URL se la versione è cambiata)
wget https://download.splunk.com/products/universalforwarder/releases/10.4.3/linux/splunkforwarder-10.4.3-4174a2deda5d.x86_64.rpm

# Scarica il checksum ufficiale
wget https://download.splunk.com/products/universalforwarder/releases/10.4.3/linux/splunkforwarder-10.4.3-4174a2deda5d.x86_64.rpm.sha512

# Verifica che combaci
sha512sum -c splunkforwarder-10.4.3-4174a2deda5d.x86_64.rpm.sha512
```

Deve stampare `OK`. Se non combacia, **non installare** — ridownload o
verifica la connessione.

## 4. Installazione

L'UF richiede una password admin esplicita al primo avvio (dalla 8.x in poi
non esiste più una password di default) — va impostata in fase di comando
con `--seed-passwd`, altrimenti chiede interattivamente.

```bash
sudo rpm -ivh splunkforwarder-10.4.3-4174a2deda5d.x86_64.rpm
```

Questo installa i file in `/opt/splunkforwarder` ma **non avvia** il
servizio automaticamente.

## 5. Primo avvio e licenza

```bash
# Primo avvio: accetta la licenza, imposta utente/password admin locali,
# non chiede altro grazie a --no-prompt
sudo /opt/splunkforwarder/bin/splunk start --accept-license --answer-yes \
  --no-prompt --seed-passwd '<PASSWORD_ADMIN_DA_DECIDERE>'
```

**Da decidere prima di eseguire**: quale password admin usare e dove
conservarla (stesso discorso fatto per gli altri agent — non va scritta in
chiaro in playbook/repo, va in vault come per le altre credenziali
OpenStack/Zabbix di questo ambiente).

## 6. Avvio automatico al boot

```bash
sudo /opt/splunkforwarder/bin/splunk enable boot-start
```

Questo crea il systemd unit (`SplunkForwarder`) e lo abilita. Da questo
punto il servizio riparte da solo al riavvio della VM.

## 7. Verifica

```bash
# Stato del servizio
sudo systemctl status SplunkForwarder

# Stato applicativo Splunk (deve rispondere "splunkd is running")
sudo /opt/splunkforwarder/bin/splunk status
```

## 8. Prossimi passi (non ancora fatti)

Da decidere prima di procedere oltre l'installazione base:

1. **A cosa si collega** — indirizzo dell'indexer/deployment server Splunk
   di TIM (host:port, tipicamente `9997` per il forwarding dati) — serve
   per configurare `outputs.conf`.
2. **Cosa raccoglie** — quali log/path monitorare su questa VM, per
   configurare `inputs.conf` (es. log applicativi, syslog, log Cinder/Nova
   per l'ambiente OpenStack, ecc.).
3. **Deployment Server o config manuale** — se TIM ha un deployment server
   Splunk centrale, l'UF si registra lì e riceve la config automaticamente
   (`deploymentclient.conf`) invece di configurare `outputs.conf`/`inputs.conf`
   a mano su ogni VM — da chiarire con chi ha dato l'indicazione iniziale.
4. **Automazione** — una volta validati i passi sopra su una VM di test,
   portare il tutto in un ruolo Ansible (stesso schema di
   `Zabbix-IAM-Onboarding/`) per il rollout sulle altre VM.

## Disinstallazione (per riferimento, se il test va rifatto da capo)

```bash
sudo /opt/splunkforwarder/bin/splunk stop
sudo /opt/splunkforwarder/bin/splunk disable boot-start
sudo rpm -e splunkforwarder
sudo rm -rf /opt/splunkforwarder
```

