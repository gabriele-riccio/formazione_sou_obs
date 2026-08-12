# Zabbix Lab — Monitoraggio con Zabbix, Grafana e datasource unificato

Stack di monitoraggio **Zabbix** containerizzato, con **Grafana** collegato via
datasource Zabbix. Stessa filosofia dell'OTel lab: VM Vagrant (Ubuntu 24.04),
Podman + Podman Compose, accesso dal Mac via port-forward NAT su `127.0.0.1`.

Obiettivo didattico: capire il modello di Zabbix (host → item → trigger → alert)
e come **Grafana faccia da cruscotto unico** sopra sorgenti diverse — qui Zabbix,
ma nella stessa Grafana si potrebbe aggiungere anche Prometheus (OTel lab).

## Concetti Zabbix

A differenza di Prometheus (pull, serie temporali + PromQL), Zabbix è
**push/agent** e **database-centrico**:

- **Server** — raccoglie i dati, valuta i trigger, lancia le azioni.
- **Database** (PostgreSQL) — conserva *sia* la configurazione *sia* i dati storici.
- **Web UI** (nginx + PHP) — l'interfaccia di configurazione e visualizzazione.
- **Agent** — installato sull'host monitorato; raccoglie e invia le metriche.

Gerarchia: **Host -> Item -> Trigger -> Action**
(host monitorato -> metrica raccolta -> soglia/condizione -> notifica).

## Architettura

```
                          +-----------------+
  zabbix-agent  --push-->  |  zabbix-server  |  <---->  zabbix-postgres (dati+config)
  (metriche host)          +-----------------+
                                   ^
                                   |  API JSON-RPC
                          +-----------------+
                          |   zabbix-web    |  <-- UI :8080
                          +-----------------+
                                   ^
                                   |  http://zabbix-web:8080/api_jsonrpc.php
                          +-----------------+
                          |     grafana     |  <-- cruscotto :3000
                          +-----------------+
```

## Servizi (podman-compose)

| Servizio        | Immagine                                    | Ruolo                          |
|-----------------|---------------------------------------------|--------------------------------|
| zabbix-postgres | postgres:16-alpine                          | Database (volume persistente)  |
| zabbix-server   | zabbix/zabbix-server-pgsql:alpine-7.0-latest| Motore di raccolta/valutazione |
| zabbix-web      | zabbix/zabbix-web-nginx-pgsql:alpine-7.0    | Web UI (porta 8080)            |
| zabbix-agent    | zabbix/zabbix-agent2:alpine-7.0-latest      | Agent che monitora l'host      |
| grafana         | grafana/grafana:latest                      | Cruscotto (porta 3000)         |

## Prerequisiti

- VirtualBox, Vagrant
- Le credenziali del DB stanno in un file `.env` (non versionato):
  `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`.

## Avvio

```bash
# 1. Crea e provisiona la VM
vagrant up

# 2. Entra nella VM e avvia lo stack
vagrant ssh
cd /vagrant
podman-compose up -d

# 3. Verifica i 5 container
podman ps
```

L'ordine di avvio conta (database -> server -> web); i depends_on lo gestiscono.

## Accesso alle interfacce (dal Mac)

| Servizio    | URL                    | Credenziali        |
|-------------|------------------------|--------------------|
| Zabbix UI   | http://127.0.0.1:8080  | Admin / zabbix     |
| Grafana     | http://127.0.0.1:3000  | admin / admin      |

> Usare `127.0.0.1`, non `localhost` (il forward NAT e' su IPv4).

## Collegare Grafana a Zabbix

1. In Zabbix creare un utente API: **Users -> Users -> Create user**,
   assegnare un gruppo e (tab Permissions) il Role **Super admin**.
   La password non deve contenere lo username.
2. In Grafana abilitare il plugin: **Connections -> Plugins -> Zabbix -> Enable**
   (il plugin `alexanderzobnin-zabbix-app` si installa da solo via
   `GF_INSTALL_PLUGINS`).
3. **Connections -> Data sources -> Add data source -> Zabbix**:
   - URL: `http://zabbix-web:8080/api_jsonrpc.php` (nome del container, non 127.0.0.1)
   - Sezione **Zabbix Connection**: Auth type "User and password", username e
     password dell'utente API creato al punto 1.
   - **Save & test** -> "Zabbix API version 7.0.x".

Il punto chiave: Grafana raggiunge Zabbix via `http://zabbix-web:8080` (nome del
container) perche' condividono la rete Podman dello stesso stack.

## Esercizio: ciclo trigger -> problem -> recovery

```
# Trigger sull'host "Zabbix server" (Data collection -> Hosts -> Triggers):
#   Name: CPU load alta (test)
#   Expression: avg(/Zabbix server/system.cpu.load[all,avg1],1m)>0.5

# Generare carico dalla VM:
yes > /dev/null &
yes > /dev/null &

# Il problem compare in Monitoring -> Problems.
# Fermare il carico:
killall yes
# Dopo ~1-2 min il problem passa a RESOLVED.
```

> La soglia 0.5 e' volutamente bassa per il test: in produzione va tarata piu'
> alta (es. >2 o >4 a seconda dei core) per evitare falsi allarmi (alert fatigue).

## Note operative

- Tenere accesa **una VM alla volta**: otel-lab e zabbix-lab usano entrambe la
  porta 3000 sul Mac. Fare `vagrant halt` sull'altra prima di avviare.
- Il plugin Zabbix e' un'**app**: va abilitato (Enable) prima che il datasource
  compaia nella lista.
- In Grafana Explore, ricordarsi di selezionare il datasource **Zabbix** (non
  `-- Grafana --`, che genera dati demo casuali).
- `podman-compose up -d` riusa i container: per applicare modifiche a porte/env,
  `podman rm -f <servizio>` prima.
- Il widget Geomap della dashboard Zabbix mostra Riga di default finche' non si
  danno coordinate agli host: e' normale, non un errore.

## Struttura del progetto

```
zabbix-lab/
|-- Vagrantfile            # VM Ubuntu 24.04 + rete + provisioning
|-- podman-compose.yml     # definizione dei 5 servizi
|-- .env                   # credenziali DB (NON versionato)
`-- .gitignore             # esclude .env e .vagrant/
```

## Confronto Prometheus vs Zabbix

| Aspetto        | Prometheus                      | Zabbix                          |
|----------------|---------------------------------|---------------------------------|
| Raccolta       | Pull (scrape endpoint)          | Push / agent                    |
| Modello dati   | Serie temporali + label (PromQL)| Host/item/trigger su DB relazionale |
| Configurazione | File YAML / as-code             | UI + template                   |
| Alerting       | Alertmanager (separato)         | Integrato (trigger -> action)   |
| Adatto a       | Cloud-native, container, K8s    | Infrastruttura classica, host stabili |

**Grafana** non compete con nessuno dei due: li **unifica** come datasource in un
cruscotto unico. Pattern tipico in produzione: Zabbix per server/rete/hardware,
Prometheus per app/container, Grafana come vista consolidata sopra entrambi.
