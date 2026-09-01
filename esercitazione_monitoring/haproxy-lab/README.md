# HAProxy Lab — Monitoraggio applicativo con Prometheus + Grafana

Primo dei tre lab di monitoraggio (**HAProxy · Nexus · Kong**).
Obiettivo: monitorare HAProxy con una dashboard Grafana dedicata, seguendo il pattern pull
`tool → Prometheus → Grafana`.

L'obiettivo operativo era costruire una pipeline di osservabilità completa,
dal load balancer alla dashboard, e dimostrare dal vivo il comportamento in alta disponibilità.

Risultato: HAProxy bilancia il traffico su due backend(`web1` e `web2`), espone metriche in formato Prometheus,
Prometheus le raccoglie e Grafana le visualizza su una dashboard dedicata a 4 pannelli.

HAProxy l'ho eseguito come container(non nativo sulla VM) perchè ho usato una rete netawark rootless che ha il confine container-host che impediva a Prometheus di raggiungere HAProxy.
Containerizzando il tutto, i servizi si parlano per nome sulla rete interna(soluzione più pulita e portabile).


## Architettura

Stack a 5 container gestito con Podman Compose dentro una VM Vagrant (Ubuntu 24.04):

```
client (curl) ──▶ HAProxy :8080 (proxy) ──▶ web1 / web2 (nginx, backend)
                     │
                     └── :8404 /metrics ──▶ Prometheus :9090 ──▶ Grafana :3000
```

- **haproxy**: bilancia in roundrobin su due backend ed espone le metriche
  Prometheus sulla porta 8404 tramite l'exporter integrato
  (`http-request use-service prometheus-exporter`).
- **web1 / web2** (`nginx:alpine`): due backend che rispondono "Sono web1" / "Sono web2".
- **prometheus**: scrapa `haproxy:8404/metrics`.
- **grafana**: dashboard, datasource `http://prometheus:9090`.

## Contesto teorico: Cosa è HAProxy

`HAProxy` (High Availability Proxy) è un reverse proxy e load balancer open source per applicazioni TCP e HTTP. Si colloca davanti a uno o più server applicativi e distribuisce il traffico in ingresso, presentandosi ai client come un unico punto d'accesso.
Migliora `disponibilità` (se un server cade il traffico va sugli altri), `efficienza` (carico distribuito) e `scalabilità` (si aggiungono server senza interruzioni).

**Concetti di configurazione**

| Sezione | Ruolo |
|------|-------|
| `frontend` | Dove HAProxy ascolta (IP:porta) e le regole di instradamento. |
| `backend` | Il pool di server di destinazione, l'algoritmo di bilanciamento e gli health check. |
| `server` | Le singole istanze reali dentro un backend. |
| `global/defaults` | Impostazioni generali e valori ereditati. |

Senza osservabilità, un load balancer sano e uno in sofferenza si assomigliano finché non è troppo tardi. HAProxy è osservabile nativamente per tre vie: la stats page (pagina HTML di stato), la Runtime API (socket di controllo) e l'exporter Prometheus integrato (dalla versione 2.0). In questo lab si usa il terzo: HAProxy espone /metrics e Prometheus lo scrapa. Le metriche si raggruppano in famiglie: carico/traffico, errori (4xx/5xx), latenza, e — la più importante per l'HA — salute dei backend dagli health check.

## File

| File | Ruolo |
|------|-------|
| `Vagrantfile` | VM Ubuntu 24.04 + Podman 4.x (netavark) + podman-compose via pipx |
| `compose.yml` | i 5 servizi |
| `haproxy/haproxy.cfg` | config HAProxy (frontend proxy :8080, frontend stats/metrics :8404) |
| `prometheus.yml` | scrape job verso `haproxy:8404` |
| `nginx-nosendfile.conf` | config nginx con `sendfile off` (vedi gotcha) |
| `web1/index.html`, `web2/index.html` | pagine di test dei backend |
| `grafana/haproxy-dashboard.json` | dashboard esportata (4 pannelli) |

## Passo 1 - VM e provisioning
Ho scritto il Vagrantfile con file box bento/ubuntu-24.04 e realizzato il port forwarding verso il Mac (porte: 8080, 8404, 9090, 3000) 
e il provisioning che installa podman e podman-compose.

```bash
vagrant up
vagrant ssh
cd /vagrant
```

Accessi dal browser del Mac:
- Traffico HAProxy → http://localhost:8080
- Stats page → http://localhost:8404/stats
- Metriche → http://localhost:8404/metrics
- Prometheus → http://localhost:9090
- Grafana → http://localhost:3000 (admin/admin)

## Passo 2 - compose.yml, haproxy.cfg (web1 e web2)/index.html
Ho poi scritto il file di configurazione di haproxy, dove ho definito due frontend:
- web_inper il traffico(:8080) verso il backend web_pool.
- Un altro per stats e metriche (:8404) che attiva l'exporter Prometheus.

Ho scritto poi il podman-compose per costruire i container che mi serviranno, definendo per ognuno l'immagine da Docker Hub, volume e porte descritte anche sopra.:
- **HAProxy**
- **web1**
- **web2**
- **Prometheus**
- **Grafana**

Infine ho scritto due pagine di prova html per i due backend che devo gestire con HAProxy `web1` e `web2`, che mostrano solo una riga di testo(che poi il load balancer di HAProxy gestirà per mandare traffico randomicamente su una e sull'altra).

## Passo 3 - Avvio dei container da dentro la VM e verifica del bilanciamento
```bash
vagrant ssh
cd /vagrant
Podman-compose up -d #partiranno tutti i container
```
Il bilanciamento si verifica con richieste ripetute che alternano i due backend:

```bash
for i in 1 2 3 4 5 6; do curl -s localhost:8080; done
 # -> Sono web1 / Sono web2 / Sono web1 / ...  (roundrobin)
```

## Passo4 - Scrape e dashboard
Prometheus raccoglie le metriche (target haproxy UP) e in Grafana una volta aggiunto il datasource costruisco i pannelli con query PromQL:
| Pannello | Query |
|----------|-------|
| Server UP per backend | `sum by (proxy) (haproxy_server_status{state="UP"})` |
| Richieste/sec per backend | `sum by (proxy) (rate(haproxy_backend_http_responses_total[1m]))` |
| Codici HTTP di risposta | `sum by (code) (rate(haproxy_backend_http_responses_total[1m]))` |
| Latenza media backend | `haproxy_backend_response_time_average_seconds` |

> **Nota versione:** HAProxy 2.8 espone la salute come gauge `haproxy_server_status` con
> label `state` (UP/DOWN/MAINT/DRAIN/NOLB), **non** come `haproxy_server_up` (versioni più recenti).

![seconda_parte](haproxy/Screenshot%202026-09-01%20alle%2012.36.37.png)

## Passo 5 - Dimostrazione Alta Disponibilità

Spengo un backend e osservo l'intero ciclo di HAProxy, misurato dalle metriche
```bash
podman stop  vagrant_web2_1   # ottengo un guasto  → health check falliscono → web2 DOWN → traffico solo su web1 (servizio resta disponibile)
podman start vagrant_web2_1   # recovery → health check falliscono → web2 rientra nel bilanciamento e l'alternanza riprende.
```

## Passo 6 - Esportazione sul Mac della Dashboard in formato json
Infine ho esportato da Grafana la dashboard in formato json, in modo da poterla riutilizzare e per vedere oltre all'importazione delle dashboard (come ho fatto con Nexus) anche come fare l'esportazione e l'ho salvato in una cartella `grafana/` che è presente come gli altri file in questa repo.

```bash
{
    "meta": {
       "...
...
   }
}
```
