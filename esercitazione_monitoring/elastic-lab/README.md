# Elastic Stack su Docker — Laboratorio metriche

Stack Elastic completo su Docker per raccogliere e visualizzare le **metriche di sistema**: **Elasticsearch + Kibana + Elastic Agent (Fleet)** con sicurezza attiva, TLS sul Fleet Server, viste Inventory/Hosts e una regola di alert sulla CPU.

> **Contesto:** Sourcesense DevOps Academy — Track Observability
> **Teoria di riferimento:** [`TEORIA.md`](./TEORIA.md) — trattazione in 10 capitoli
> **Versione stack:** 8.15.0 · **Ambiente:** macOS + Docker Desktop

---

## Cosa ottieni

- Elasticsearch e Kibana con **sicurezza abilitata** (password + token)
- Un **Fleet Server** sano su `:8220` (TLS)
- Raccolta delle metriche del modulo `system` (CPU, memoria, rete, disco)
- Le app **Inventory** e **Hosts** popolate
- Una regola di **alert** sulla CPU funzionante

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

| Componente | Ruolo | Porta |
|---|---|---|
| Elasticsearch | Storage, indicizzazione, analisi | 9200 |
| Kibana | Interfaccia web, Fleet, alerting | 5601 |
| Fleet Server | "Quartier generale" degli agent | 8220 |
| kibana_setup | Container usa-e-getta (password di sistema) | — |

---

## Prerequisiti

- **Docker Desktop** in esecuzione
- **RAM per Docker ≥ 4 GB** (consigliati 6+) — Elasticsearch con meno parte e muore
- **openssl** (già presente su macOS)

---

## Struttura della cartella

```
elastic-lab/
├── README.md            # questo file (guida al lab)
├── TEORIA.md            # teoria in 10 capitoli
├── docker-compose.yml   # lo stack (segreti via ${VARIABILI})
├── .gitignore           # esclude .env e certs/
├── .env                 # segreti — NON su Git
└── certs/               # certificato TLS — NON su Git
```

> ⚠️ **`.env` e `certs/` non vanno su Git.** Contengono password, service token e la chiave privata. Sono esclusi dal `.gitignore`.

---

## Setup passo-passo

### 0. Preparazione

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

Crea `.env` con i tuoi valori (la chiave di cifratura ≥ 32 caratteri). Il token si genera al passo 3.

```env
ELASTIC_PASSWORD=cambia_questa_password
KIBANA_PASSWORD=cambia_questa_password_kibana
KIBANA_ENCRYPTION_KEY=una_chiave_lunga_almeno_32_caratteri_123456
FLEET_SERVER_SERVICE_TOKEN=DA_GENERARE_AL_PASSO_3
```

Il `docker-compose.yml` (in questa cartella) legge questi valori tramite `${VARIABILE}`.

### 2. Avvia lo stack base (senza il Fleet Server)

> Il fleet-server ha bisogno del token, che generiamo dopo. Avviarlo ora darebbe un 401 inutile.

```bash
docker compose up -d elasticsearch kibana_setup kibana

# attendi ~1-2 min, poi verifica
docker compose ps
# elasticsearch: Up (healthy) · kibana: Up · kibana_setup: Exited (0)
```

### 3. Service token + Fleet Server

```bash
# 3.1 genera il token (usa la tua ELASTIC_PASSWORD)
curl -s -u elastic:LA_TUA_PASSWORD -X POST \
  "http://localhost:9200/_security/service/elastic/fleet-server/credential/token/token1" \
  -H "Content-Type: application/json"
# copia il "value" e mettilo nel .env come FLEET_SERVER_SERVICE_TOKEN
```

**3.2 Crea la policy in Kibana** (`http://localhost:5601` → login `elastic`):
Fleet → Agents → **Add Fleet Server** → **Quick Start** → host `https://fleet-server:8220` → **Continue**.
Compare *"Fleet Server policy created"*. **Ignora** i comandi di installazione proposti.

```bash
# 3.3 avvia il Fleet Server
docker compose up -d fleet-server

# 3.4 verifica (dopo ~40s)
docker logs --tail 15 fleet-server
# atteso: "Running on policy with Fleet Server integration: fleet-server-policy" · HEALTHY
```

In **Fleet → Agents** il Fleet Server deve comparire **Healthy** (verde).

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
