# OTel Lab — Osservabilità con OpenTelemetry, Prometheus e Grafana

Laboratorio di osservabilità *metrics-first*: un'applicazione Python (Flask)
instrumentata con OpenTelemetry invia metriche e tracce a un Collector, che
espone le metriche a Prometheus; Grafana le visualizza in dashboard.

Tutto gira dentro una VM Vagrant (Ubuntu 24.04) tramite Podman + Podman Compose.

## Architettura

```
  App Python (Flask)            OpenTelemetry            Prometheus            Grafana
  otel-lab-app         --OTLP-->  Collector    --scrape-->  (TSDB)   --query--> (dashboard)
  :5000                gRPC 4317   :9464                     :9090               :3000
```

- **app-python** — Flask instrumentata con OpenTelemetry SDK. Espone due
  endpoint e una metrica custom `app_requests_total`. Invia telemetria via
  OTLP/gRPC al Collector (`OTEL_EXPORTER_OTLP_ENDPOINT`, default
  `http://otel-collector:4317`).
- **otel-collector** — riceve la telemetria OTLP e la espone in formato
  Prometheus sulla porta `9464`.
- **prometheus** — scrapa il Collector (`otel-collector:9464`) e se stesso
  (`localhost:9090`) ogni 15s.
- **grafana** — datasource Prometheus pre-provisionato; dashboard delle metriche.

## Endpoint e metriche dell'app

| Endpoint      | Risposta            | Metrica incrementata                       |
|---------------|---------------------|--------------------------------------------|
| `GET /`       | `Ciao da otel-lab!` | `app_requests_total{endpoint="/"}`         |
| `GET /health` | `{"status": "ok"}`  | `app_requests_total{endpoint="/health"}`   |

`service.name` = `otel-lab-app`. La metrica `app_requests_total` è un counter
con label `endpoint`.

## Prerequisiti

- VirtualBox
- Vagrant

## Avvio

```bash
# 1. Crea e provisiona la VM (installa podman + podman-compose, attiva il linger)
vagrant up

# 2. Entra nella VM e avvia lo stack
vagrant ssh
cd /vagrant
podman-compose up -d

# 3. Verifica che i container siano attivi
podman ps
```

I file del lab sono nella cartella condivisa `/vagrant` dentro la VM.

## Accesso alle interfacce (dal Mac)

| Servizio   | URL                    | Credenziali       |
|------------|------------------------|-------------------|
| Grafana    | http://127.0.0.1:3000  | `admin` / `admin` |
| Prometheus | http://127.0.0.1:9090  | —                 |
| App        | http://127.0.0.1:5000  | —                 |

> **Usare `127.0.0.1`, non `localhost`.** Vedi la sezione Troubleshooting.

## Generare traffico

```bash
# Dal Mac o dalla VM: colpisce l'app per produrre metriche
for i in $(seq 1 30); do curl -s http://127.0.0.1:5000/ > /dev/null; done
```

## Query utili (PromQL)

```promql
# Richieste al secondo, tutte le rotte aggregate
sum(rate(app_requests_total[1m]))

# Richieste al secondo separate per endpoint
sum by (endpoint) (rate(app_requests_total[1m]))

# Totale richieste (contatore aggregato)
sum(app_requests_total)
```

> Prometheus può mostrare serie doppie dopo un riavvio dell'app (cambia il
> `service.instance.id`): aggregare con `sum(...)` per una lettura pulita.

## Verifica del flusso

In Prometheus (`http://127.0.0.1:9090`), **Status -> Targets**: il target
`otel-collector:9464` deve risultare **UP**. Se e' DOWN, le metriche non
arrivano — controllare che il Collector sia attivo (`podman ps`).

## Troubleshooting — accesso alle UI dal Mac

Sintomo: dal Mac Prometheus si apre ma Grafana no (o viceversa), con
connessioni rifiutate/resettate.

**Causa.** La rete host-only di VirtualBox (`192.168.56.x`) su questo Mac non
e' disponibile: manca il driver di rete kernel di VirtualBox
(`/dev/vboxnetctl` assente, `VBoxManage hostonlyif create` fallisce). Su un Mac
gestito l'autorizzazione dell'estensione kernel Oracle puo' richiedere l'IT.

**Soluzione adottata: port-forward NAT su IPv4 esplicito.** Nel `Vagrantfile`
i forward usano `host_ip: "127.0.0.1"`:

```ruby
config.vm.network "forwarded_port", guest: 3000, host: 3000, host_ip: "127.0.0.1"
config.vm.network "forwarded_port", guest: 9090, host: 9090, host_ip: "127.0.0.1"
config.vm.network "forwarded_port", guest: 5000, host: 5000, host_ip: "127.0.0.1"
```

Si accede quindi via `http://127.0.0.1:<porta>`.

**Note pratiche imparate:**
- Usare `127.0.0.1`, **non** `localhost`: `localhost` sul Mac puo' risolvere a
  IPv6 (`::1`) mentre il forward e' su IPv4 -> connessione resettata.
- `podman-compose up -d` **riusa** i container esistenti: per applicare
  modifiche a porte o variabili d'ambiente serve prima `podman rm -f <servizio>`.
- Un `curl` dalla VM verso il proprio IP fa loopback interno e **non** prova la
  raggiungibilita' dall'esterno: testare sempre dal Mac.
- Non usare `vagrant suspend` (corrompe lo stato); usare `vagrant halt`.
- Safari storpia gli IP digitati a mano (aggiunge `www.`): usare Chrome/Firefox
  o incollare l'URL completo.

## Struttura del progetto

```
otel-lab/
├── Vagrantfile               # VM Ubuntu 24.04 + rete + provisioning
├── podman-compose.yml        # definizione dei 4 servizi
├── Dockerfile                # build dell'app Python
├── app.py                    # app Flask instrumentata OTel
├── requirements.txt          # dipendenze Python
├── prometheus.yml            # config scrape di Prometheus
└── grafana/
    ├── grafana.ini           # config server Grafana
    └── provisioning/
        └── datasources/      # datasource Prometheus pre-provisionato
```
