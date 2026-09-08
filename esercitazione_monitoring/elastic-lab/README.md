# Elastic Stack su Docker — Laboratorio metriche

Stack Elastic completo su Docker per raccogliere e visualizzare le **metriche di sistema**: **Elasticsearch + Kibana + Elastic Agent (Fleet)** con sicurezza attiva, TLS sul Fleet Server, viste Inventory/Hosts e una regola di alert sulla CPU.

> **Contesto:** Sourcesense DevOps Academy — Track Observability
> **Teoria di riferimento:** [`TEORIA.md`](./TEORIA.md) — trattazione argomenti in 10 capitoli
> **Versione stack:** 8.15.0 · **Ambiente:** macOS + Docker Desktop

---

## Cosa ho ottenuto:

- Elasticsearch e Kibana con **sicurezza abilitata** (password + token);
- Un **Fleet Server** sano su `:8220` (TLS);
- Raccolta delle metriche tramite un agent che raccoglie le metriche del modulo `system` (CPU, memoria, rete, disco);
- Le app **Inventory** e **Hosts** popolate;
- Una regola di **alert** sulla CPU funzionante.

## Architettura

```
   sorgente (host / container)
        │  raccoglie + arricchisce + spinge (push)
        ▼
   [ Elastic Agent ] ──────▶ [ Fleet Server ]  (:8220, TLS)
        │                          │  policy / config
        │ metriche (_bulk)         ▼
        ▼                    [   Kibana   ]  (:5601)
   [ Elasticsearch ] ◀─────▶ (interfaccia)
        (:9200)

   tutti sulla rete Docker "elastic-lab-net"
```
> Ho scelto Docker essendo Elasticsearch e Kibana molto pesanti con dipendenze delicate e mettendole in container risultano isolate, riproducibili e smontabili in un secondo.

| Componente | Ruolo | Porta |
|---|---|---|
| Elasticsearch | Storage, indicizzazione, analisi | 9200 | 
| Kibana | Interfaccia web, Fleet, alerting | 5601 |
| Fleet Server | "Quartier generale" degli agent | 8220 |
| kibana_setup | Container usa-e-getta (password di sistema) | — |

---

## Prerequisiti

- **Docker Desktop** in esecuzione
- **RAM per Docker ≥ 4 GB** — Elasticsearch con poca RAM parte e muore
- **Openssl** (già presente su macOS)
> Tutti i container(Elasticsearch, Kibana e gli agent) utilizzano la stessa versione fissata `8.15.0` dato che per comunicare devono essere della stessa versione.
---

## Struttura della cartella

```
elastic-lab/
├── README.md            # questo file 
├── TEORIA.md            # teoria in 10 capitoli
├── docker-compose.yml   # lo stack (segreti via ${VARIABILI} fatte in un secondo momento per migliorare la sicurezza)
├── .gitignore           # esclude .env e certs/
├── .env                 # segreti che non vanno su Git
└── certs/               # certificato TLS che non va su Git
```

> **`.env` e `certs/` non vanno su GitHub** - Contengono password, service token e la chiave privata, li ho esclusi dal `.gitignore`.

---

## Svolgimento passo-passo

### 0. Preparazione
Per prima cosa ho creato la cartella di lavoro ho creato una rete Docker `elastic-lab-net` dedicata, dove i container si vedono per nome e così possono comunicare tra loro.
Ho dovuto generare un certificato self-signed valido per i nomi flette-server e localhost dato che a differenza di Elasticsearch e Kibana, Fleet Server pretende TLS sulla porta 8220.
Quindi ho generato, tramite il comando openssl rea -x509, il certificato autofirmato e con newkey rsa:2048 -nodes la chiave privata( 2048 bit senza passphrase e -nodes = noDES senza password),creando la cartella certs dove poi sono finiti i file prodotti(fleet-server.crt e fleet-server.key, certificato e chiave) con durata di un anno e altre flag per l'identità del certificato.

```bash
mkdir -p elastic-lab && cd elastic-lab
docker network create elastic-lab-net

# Certificato TLS per il Fleet Server (valido per i nomi fleet-server e localhost)
mkdir -p certs && openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout certs/fleet-server.key \
  -out certs/fleet-server.crt \
  -days 365 \
  -subj "/CN=fleet-server" \
  -addext "subjectAltName=DNS:fleet-server,DNS:localhost"
```

### 1. File `.env` (segreti)
Prima di costruire il Docker compose con i servizi che mi serviranno, ho configurato il file .env per i segreti (password, token,...) che verranno chiamati con la sintassi ${VARIABILE}, per pubblicare su GitHub il docker-compose.yml in tutta sicurezza.

```env
ELASTIC_PASSWORD=password_usata_da_me
KIBANA_PASSWORD=password_usata_da_me_kibana
KIBANA_ENCRYPTION_KEY=una_chiave_lunga_almeno_32_caratteri_123456
FLEET_SERVER_SERVICE_TOKEN=token_generato_poi
```
### 2. Avvia lo stack base (senza il Fleet Server)

> Il fleet-server ha bisogno del token, che devo generare dopo dato che non ho le password.
Ho costruito un unico docker-compose.yml con 4 servizi in catena elasticsearch, kibana_setup, kibana, fleet-server più la rete docker.
#### Servizio `elasticsearch`

| Riga | Significato |
|---|---|
| `image: ...elasticsearch:8.15.0` | Versione **fissa** 8.15.0 (mai `latest`: tutti i componenti devono coincidere). |
| `container_name: elasticsearch` | Nome del container, usato anche dagli altri servizi per raggiungerlo **per nome** sulla rete. |
| `networks: [elastic-lab-net]` | Aggancio alla rete Docker privata dove i container si risolvono per nome. |
| `ports: "9200:9200"` | Espone l'API REST sul Mac (`localhost:9200`). |
| `discovery.type=single-node` | Singolo nodo per semplificare il lab |
| `ES_JAVA_OPTS=-Xms1g -Xmx1g` | 1 GB di heap Java (min e max uguali). |
| `xpack.security.enabled=true` | **Accendo la sicurezza** (password/token). Obbligatorio per Fleet. |
| `ELASTIC_PASSWORD=${ELASTIC_PASSWORD}` | Password del user `elastic`, letta dal `.env`. |
| `xpack.security.http.ssl.enabled=false` | **Spegne il TLS** su ES (scelta mia per facilitare il lavoro: autenticazione sì, certificati no). |

**Healthcheck:** insegna a Docker a capire *quando* ES è davvero pronto.
- Un `curl` autenticato verso `_cluster/health` che aspetta lo stato ≥ `yellow`;
- `--fail` lo fa fallire su errori HTTP (es. 401);
- `start_period: 60s` dà 60s di "grazia" iniziale in cui i fallimenti non contano.
In questo modo gli altri servizi aspettano che ES sia `healthy` prima di partire.

#### Servizio `kibana_setup`

Container **usa-e-getta** che risolve un problema preciso: con la sicurezza attiva, Kibana non può connettersi come `elastic`, deve usare l'utente di sistema **`kibana_system`**, che però nasce senza password.

- Usa l'immagine di **Elasticsearch** (non di Kibana), poi ha anche lui container-name etc...
- `depends_on: elasticsearch → service_healthy` — Parte solo quando ES è sano.
- Il `command` fa un `POST` a `_security/user/kibana_system/_password` per impostare la password (dal `.env`), riprovando ogni 5s finché non riesce, poi **termina** (`Exited 0`).

#### Servizio `kibana`

L'interfaccia web. Come elesticsearch ha immagine, nome, network e porte( 5601:5601);
- `depends_on: kibana_setup → service_completed_successfully`: Parte solo dopo che la password di `kibana_system` esiste.
- **Catena: ES sano → password → Kibana**.
- `ELASTICSEARCH_HOSTS/USERNAME/PASSWORD` — Kibana si collega a ES (per nome) autenticandosi come `kibana_system`.
- Le variabili **`XPACK_FLEET_*`** pre-configurano Fleet all'avvio (senza doverlo fare a mano, e per questo ci metterà un pò all'inizio):
  - `FLEET_SERVER_HOSTS` — indirizzo del Fleet Server (`https://fleet-server:8220`);
  - `OUTPUTS` — dove gli agent mandano i dati (`http://elasticsearch:9200`, **il nome, non `localhost`**);
  - `PACKAGES` — pacchetti da installare (`fleet_server`, `system`);
  - `AGENT_POLICIES` — pre-crea la policy con id `fleet-server-policy`.
- `XPACK_ENCRYPTEDSAVEDOBJECTS_ENCRYPTIONKEY` — chiave di cifratura degli oggetti salvati. **Obbligatoria per l'alerting**.

#### Servizio `fleet-server`

Il "quartier generale" degli agent. Il Fleet Server **è** un Elastic Agent in modalità speciale, quindi usa l'immagine dell'agent(Elastic).

| Riga | Significato |
|---|---|
| `image: ...elastic-agent:8.15.0` | Il Fleet Server è un Elastic Agent. |
| `container_name` | fleet-server |
| `networks` | elastic-lab-net |
| `ports: "8220:8220"` | Espone la porta di Fleet. |
| `volumes: ./certs:/certs:ro` | Monta la cartella dei certificati in sola lettura. |
| `FLEET_SERVER_ENABLE=true` | Modalità "sono un Fleet Server". |
| `FLEET_SERVER_ELASTICSEARCH_HOST` | Dove trova ES (per nome). |
| `FLEET_SERVER_SERVICE_TOKEN` | **Service token** (dal `.env`) per autenticarsi verso ES. |
| `FLEET_SERVER_POLICY_ID=fleet-server-policy` | La policy da applicare (pre-creata da Kibana). |
| `FLEET_SERVER_CERT` / `CERT_KEY` | Certificato e chiave TLS (dai file montati). Il Fleet Server **pretende** TLS sulla 8220. |
| `FLEET_URL=https://fleet-server:8220` | Indirizzo verso cui l'agent fa il check-in (nome per cui il certificato è valido). |
| `FLEET_CA=/certs/fleet-server.crt` | CA di cui fidarsi per il certificato self-signed. Insieme a `FLEET_URL` risolve l'errore `x509: unknown authority` e porta il Fleet Server a **Healthy**. |

#### La rete

```yaml
networks:
  elastic-lab-net:
    external: true
```

`external: true` dice al compose di **non creare** una rete nuova, ma di usare quella `elastic-lab-net` creata a mano con `docker network create` (`external` = "esiste già, fuori da questo file").

Per cui non mi è restato che farlo partire, e seguire la catena: elasticsearch diventa healthy (~30-60s) → kibana_setup imposta la password di kibana_system ed esce con Exited (0) → kibana parte(ci vuole un pò di più dato che installerà i pacchetti Fleet).
```bash
docker compose up -d elasticsearch kibana_setup kibana

# attendo un pò e poi verifico.
docker compose ps
# elasticsearch: Up (healthy) · kibana: Up · kibana_setup: Exited (0)
# Catena: ES sano → password → Kibana.
```
### 3. Service token + Fleet Server
Come detto Fleet ha bisogno di un service token tramite si può autenticare. Per prima cosa lo genero una volta che elasticsearch è healty usando la password di Elastic, poi lo inserisco nel file .env come FLEET_SERVER_SERVICE_TOKEN=AAEA... .

```bash
# 3.1 genera il token (usa la tua ELASTIC_PASSWORD)
curl -s -u elastic:LA_TUA_PASSWORD -X POST \
  "http://localhost:9200/_security/service/elastic/fleet-server/credential/token/token1" \
  -H "Content-Type: application/json"
# copio il "value" e lo metto nel .env come FLEET_SERVER_SERVICE_TOKEN
```
**3.2 Crea la policy in Kibana**:
Poi creo la policy del Fleet Server in Kibana, dato che il fleet server cerca una policy con id fleet-server-policy che ho impostato nel compose.
La creo dall'interfaccia:
- Apro `http://localhost:5601` e accedo con utente elastic e la mia password;
- Vado su Fleet (menu → Management → Fleet, oppure /app/fleet );
- Tab **Agents** → **Add Fleet Server** → **Quick Start**.
- Come host imposto https://fleet-server:8220 e premendo continue comparirà "Fleet Server policy created".

**3.3 Avvio il Fleet Server**

```bash
# 3.3 avvia il Fleet Server
docker compose up -d fleet-server

# 3.4 verifica (dopo ~40s)
docker logs --tail 15 fleet-server
# atteso: "Running on policy with Fleet Server integration: fleet-server-policy" · HEALTHY
```

In **Fleet → Agents** il Fleet Server deve comparire **Healthy** (verde) da **Updating** (blu).
![seconda_parte](elastic/Screenshot%202026-09-08%20alle%2012.56.59.png)
![seconda_parte](elastic/Screenshot%202026-09-08%20alle%2012.57.08.png)

### 4. Visualizza le metriche

- **Inventory** → `http://localhost:5601/app/metrics/inventory`
- **Hosts** → `http://localhost:5601/app/metrics/hosts`

Dovresti vedere il tuo host con CPU, memoria, rete, disco graficati.

### 5. Alert sulla CPU

Observability → Alerts → Rules → **Create rule** → **Custom threshold**:
- **Data view:** `metrics-*`
- **Condizione:** `AVERAGE` di `system.cpu.total.norm.pct` **IS ABOVE 0.2** (20%)
- **Actions:** vuote · **Save**

Testa generando carico:

```bash
docker run --rm -d --name cpu-stress --network elastic-lab-net \
  busybox sh -c "while true; do :; done"
# guarda /app/observability/alerts → l'alert passa a "Active"

# ⚠️ POI SPEGNILO (il loop è infinito):
docker rm -f cpu-stress
```

---

## Gestione quotidiana

```bash
docker compose stop     # spegni conservando i dati
docker compose start    # riaccendi
docker compose ps -a    # stato
docker stats --no-stream  # consumo risorse
```

> ⚠️ **Non usare `docker compose down -v`** per lo spegnimento: cancella i volumi (dati, policy, **token**). Usa `stop`. Il `-v` serve solo per ripartire davvero da zero — e in quel caso vanno rigenerati token e policy.

---

## Sicurezza e Git

`.gitignore` (già in cartella) esclude i segreti:

```gitignore
.env
certs/
*.log
*.pdf
```

**Verifica che Git ignori davvero i segreti** prima di pushare:

```bash
# devono stampare una riga (= ignorati)
git check-ignore -v .env
git check-ignore -v certs/fleet-server.key

# il compose NON deve contenere segreti in chiaro (nessun output atteso)
grep -E "password_reale|token_reale|chiave_reale" docker-compose.yml

# ma Docker DEVE risolverli dal .env (i valori veri compaiono qui)
docker compose config | grep -E "ELASTIC_PASSWORD|SERVICE_TOKEN|ENCRYPTIONKEY"
```

Commit:

```bash
git add elastic-lab
git status            # conferma: .env e certs/ NON in lista
git commit -m "Aggiungi lab Elastic (compose + docs, segreti esclusi)"
git push
```

---

## Troubleshooting

| Sintomo | Causa / soluzione |
|---|---|
| ES resta `health: starting` | Password nell'healthcheck non combacia con `.env`. Testa con `curl -u elastic:...`. |
| Fleet: `401 failed to authenticate service account` | Token non valido (tipico dopo `down -v`). Rigenera (passo 3.1), aggiorna `.env`, ricrea il fleet-server. |
| Fleet: `Waiting on policy... fleet-server-policy` | Policy assente o id sbagliato. Creala col wizard (passo 3.2); id = `fleet-server-policy`. |
| Fleet: `connection refused localhost:9200` | Output errato. Fleet → Settings → Outputs → host `http://elasticsearch:9200`. Poi `--force-recreate`. |
| Fleet: `x509: certificate signed by unknown authority` | Manca la CA. Verifica `FLEET_CA=/certs/fleet-server.crt` + `FLEET_URL=https://fleet-server:8220`. Non mischiare `FLEET_INSECURE` con `FLEET_CA`. |
| Alert: `encryption key required` | Manca `XPACK_ENCRYPTEDSAVEDOBJECTS_ENCRYPTIONKEY` (≥32 char). Aggiungi al `.env` e ricrea Kibana. |
| Log `add_cloud_metadata 169.254.169.254` | Innocuo: l'agent cerca metadati cloud inesistenti in locale. Ignora. |

> Per ricreare un solo servizio dopo una modifica: `docker compose up -d --force-recreate <servizio>`

---

*Guida operativa. Per la teoria completa vedi [`TEORIA.md`](./TEORIA.md).*

