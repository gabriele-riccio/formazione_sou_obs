# Lab: Monitoraggio su Kubernetes con Prometheus + Grafana

App .NET (`/metrics` via prometheus-net) -> **Prometheus** (scrape) -> **Grafana** (dashboard).
Namespace `monitoring`, Service di tipo **ClusterIP**, accesso via **kubectl port-forward**.
Datasource Prometheus **pre-provisionato** in Grafana.

## Ordine di applicazione
```bash
kubectl apply -f 00-namespace.yaml
kubectl apply -f 01-monitoredapp.yaml
kubectl apply -f 02-prometheus.yaml
kubectl apply -f 03-grafana.yaml
# oppure: kubectl apply -f .
```

## Verifica
```bash
kubectl get pods,svc -n monitoring
```

## Accessi (un port-forward per servizio, ognuno in un terminale separato)
```bash
# App + /metrics
kubectl -n monitoring port-forward svc/monitoredapplication 8080:80
#   -> http://localhost:8080/  e  http://localhost:8080/metrics

# Prometheus
kubectl -n monitoring port-forward svc/prometheus-svc 9090:9090
#   -> http://localhost:9090   (Status > Targets per vedere lo scrape)

# Grafana
kubectl -n monitoring port-forward svc/grafana-svc 3000:3000
#   -> http://localhost:3000   (admin / admin)
```

## Grafana
- Il datasource **Prometheus** e' gia' configurato (provisioning).
- Crea una dashboard e prova una query, es. `http_requests_received_total`.

## Note
- Config Prometheus in chiaro nella ConfigMap (niente base64/BOM).
- `requests/limits` ridimensionati; readiness/liveness probe aggiunte.
- `fsGroup: 472` su Grafana per la scrittura sul volume persistente.
- Il datasource punta a `http://prometheus-svc:9090` (DNS interno del cluster).
# Laboratorio: Monitoraggio su Kubernetes con Prometheus + Grafana

Monitoraggio end-to-end di un'applicazione **.NET** su Kubernetes (Minikube),
seguendo la catena classica **App → Prometheus → Grafana**.

> Basato sul tutorial di Michele Ferracin
> ([repo](https://github.com/phenixita/MonitoredApplication-Prometheus-Grafana)),
> con alcune migliorie rispetto alla versione originale (vedi in fondo).

---

## 1. Cosa costruiamo (architettura)

```
                 scrape /metrics (pull, in-cluster DNS)
  +--------------------+        +--------------+        +-----------+
  |  monitoredapp      | :80    |  Prometheus  | :9090  |  Grafana  | :3000
  |  (.NET + prom-net) | -----> |  (TSDB)      | -----> |  (dashb.) |
  |  espone /metrics   |        |  job UP      |  query |  datasource
  +--------------------+        +--------------+        +-----------+
        namespace: monitoring
```

- L'app .NET usa la libreria **prometheus-net** (`UseHttpMetrics()` + `MapMetrics()`)
  ed espone le metriche su `/metrics`.
- **Prometheus** fa lo *scrape* (modello **pull**) del target
  `monitoredapplication:80` tramite il DNS interno del cluster.
- **Grafana** legge da Prometheus (datasource **pre-provisionato**) e disegna le dashboard.

Metriche principali esposte dall'app:

| Metrica | Tipo | Uso |
|---|---|---|
| `http_requests_received_total` | counter | richieste totali -> `rate()` per req/sec |
| `http_request_duration_seconds` | histogram | latenza -> percentili con `histogram_quantile()` |
| `http_requests_in_progress` | gauge | richieste in corso |

---

## 2. Prerequisiti

- **Minikube** (o Docker Desktop con Kubernetes) attivo.
- **kubectl** configurato sul contesto giusto.
- Concetti di base di container / Kubernetes.

```bash
minikube start                       # se usi Minikube
kubectl config current-context       # deve essere: minikube (o docker-desktop)
kubectl get nodes                    # il nodo deve essere Ready
```

---

## 3. I manifest

Tutti nel namespace `monitoring`, Service di tipo **ClusterIP**
(accesso via `kubectl port-forward`).

| File | Contenuto |
|---|---|
| `00-namespace.yaml` | il namespace `monitoring` |
| `01-monitoredapp.yaml` | Deployment + Service dell'app .NET |
| `02-prometheus.yaml` | ConfigMap (config) + Deployment + Service |
| `03-grafana.yaml` | ConfigMap datasource + PVC + Deployment + Service |

### 3.1 App (`01-monitoredapp.yaml`)
- immagine `phenixita/monitoredapplication`, porta **80**, `ASPNETCORE_URLS=http://+:80`;
- `requests/limits` ridimensionati (128Mi/100m -> 256Mi/500m);
- **readiness/liveness probe** su `/`.

### 3.2 Prometheus (`02-prometheus.yaml`)
- la config e' scritta **in chiaro** nella ConfigMap (niente base64/BOM):

```yaml
global:
  scrape_interval: 15s
scrape_configs:
  - job_name: 'monitoredapp_job'
    scrape_interval: 5s
    static_configs:
      - targets: ['monitoredapplication:80']
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']
```

- il Deployment monta la ConfigMap in `/etc/prometheus`;
- probe su `/-/ready` e `/-/healthy`.

### 3.3 Grafana (`03-grafana.yaml`)
- **ConfigMap di provisioning** montata in
  `/etc/grafana/provisioning/datasources`: il datasource Prometheus
  (`http://prometheus-svc:9090`) e' gia' presente al primo avvio;
- **PVC** da 512Mi montato su `/var/lib/grafana` -> le dashboard **persistono**;
- `securityContext.fsGroup: 472` per rendere scrivibile il volume (Grafana gira come uid 472);
- probe su `/api/health`.

---

## 4. Deploy passo-passo

```bash
kubectl apply -f 00-namespace.yaml
kubectl apply -f 01-monitoredapp.yaml
kubectl apply -f 02-prometheus.yaml
kubectl apply -f 03-grafana.yaml
# oppure tutto insieme:  kubectl apply -f .
```

Verifica che i pod siano `Running 1/1`:

```bash
kubectl get pods -n monitoring
# NB: con -w controlla un solo tipo alla volta, es. kubectl get pods -n monitoring -w
```

---

## 5. Accessi (port-forward)

Ogni `port-forward` e' **bloccante**: aprilo in un terminale dedicato e lascialo attivo.

```bash
# App + /metrics
kubectl -n monitoring port-forward svc/monitoredapplication 8080:80
#   -> http://localhost:8080/        (web app)
#   -> http://localhost:8080/metrics (metriche Prometheus)

# Prometheus
kubectl -n monitoring port-forward svc/prometheus-svc 9090:9090
#   -> http://localhost:9090   (Status > Targets)

# Grafana
kubectl -n monitoring port-forward svc/grafana-svc 3000:3000
#   -> http://localhost:3000   (admin / admin)
```

> Nota: il port-forward dell'app **non serve** per lo scrape (Prometheus lo
> raggiunge via DNS interno). Serve solo per aprire l'app dal browser e
> generare traffico.

---

## 6. Verifica

### 6.1 L'endpoint /metrics
```bash
curl -s http://localhost:8080/metrics | head -30
```
Deve restituire righe `# HELP` / `# TYPE` e metriche come `http_requests_received_total`.

### 6.2 I target di Prometheus
`http://localhost:9090` -> **Status > Targets**: sia `monitoredapp_job`
(endpoint `http://monitoredapplication/metrics`) sia `prometheus` devono essere **UP**.

### 6.3 Le query PromQL
Genera prima un po' di traffico ricaricando `http://localhost:8080/`, poi in Prometheus:

```promql
http_requests_received_total
sum(rate(http_requests_received_total[5m]))
histogram_quantile(0.95, sum by (le) (rate(http_request_duration_seconds_bucket[5m])))
```

---

## 7. Grafana

1. Login su `http://localhost:3000` (admin / admin, poi cambia password).
2. **Connections > Data sources**: il datasource **Prometheus** e' gia' li' -> **Save & test**
   deve dire *"Successfully queried the Prometheus API"*.
3. **Dashboards > New > New dashboard > + Add visualization** -> data source **Prometheus**.
4. Editor query in modalita' **Code**:
   ```promql
   sum(rate(http_requests_received_total[5m]))
   ```
5. Range **Last 15 minutes**, refresh **5s**, tipo **Time series**, Title *"Richieste/sec"*.
6. **Save** con nome **MonitoredApp**.

La dashboard sopravvive al riavvio del pod Grafana grazie al PVC.

---

## 8. Troubleshooting

### "Load failed" in Grafana / la pagina non carica
Quasi sempre e' il **port-forward caduto** (timeout, standby del Mac).
- Controlla il terminale del port-forward: se e' tornato al prompt o dice
  `lost connection to pod`, e' caduto.
- Rilancialo e ricarica la pagina:
  ```bash
  kubectl -n monitoring port-forward svc/grafana-svc 3000:3000
  ```
- I dati/dashboard **non si perdono**: e' solo la UI che non parla col server.

### "Non puo' connettersi al server" su :9090 / :3000 / :8080
Manca il **port-forward** su quella porta, oppure e' caduto. Aprilo (vedi §5)
e ricarica **dopo** che stampa `Forwarding from 127.0.0.1:PORT -> ...`.

### Target `monitoredapp_job` **DOWN** in Prometheus
Accanto al target Prometheus scrive il motivo. Cause tipiche:
- **DNS**: il target deve essere il *nome del Service* (`monitoredapplication:80`),
  e Prometheus deve stare nello **stesso namespace** (`monitoring`).
- **App non pronta**: controlla `kubectl get pods -n monitoring` (deve essere `Running 1/1`).
- **Porta sbagliata**: il `port` del Service e il `targetPort` devono combaciare (80/80).

### `kubectl get pods,svc -n ... -w` -> "you may only specify a single resource type"
Il flag `-w` (watch) accetta **un solo tipo** per volta:
```bash
kubectl get pods -n monitoring -w
```

### Pod bloccato in `ContainerCreating` / `ErrImagePull`
- `ContainerCreating` al primo avvio e' normale (sta scaricando l'immagine): attendi.
- `ErrImagePull` / `ImagePullBackOff`: verifica il nome immagine e la connessione;
  `kubectl describe pod <nome> -n monitoring` per il dettaglio.

### Grafana in `CrashLoopBackOff` per permessi sul volume
Assicurati che nel Deployment ci sia `securityContext.fsGroup: 472`
(il PVC nuovo altrimenti non e' scrivibile dall'utente di Grafana).

---

## 9. Migliorie rispetto al tutorial originale

| Aspetto | Video | Questo lab |
|---|---|---|
| Config Prometheus | blob base64 con BOM | YAML leggibile inline |
| `requests/limits` | 1-2 Gi / 500m-1 CPU (sovradimensionati) | ridimensionati |
| Probe | assenti | readiness/liveness |
| Namespace | default | dedicato `monitoring` |
| Accesso | `LoadBalancer` | `ClusterIP` + `port-forward` (portabile) |
| Datasource Grafana | manuale | pre-provisionato via ConfigMap |
| Volume Grafana | PVC senza fsGroup | PVC + `fsGroup: 472` |

---

## 10. Pulizia

```bash
kubectl delete namespace monitoring
```
(rimuove tutte le risorse del lab in un colpo solo)