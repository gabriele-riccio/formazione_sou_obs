# Kong Lab — Monitoraggio di un API Gateway su Kubernetes

**Obiettivo**: monitorare **Kong Gateway** (API gateway) su **Kubernetes** (minikube), usando
l'approccio k8s-nativo allo scraping tramite **ServiceMonitor** e **Prometheus Operator**, importando una dashboard dal catalogo grafana.com con **l'import da ID**.

**Risultato**: **Kong** instrada il traffico verso un servizio di test, espone metriche di gateway (richieste per service/route/codice, latenze, bandwidth), **Prometheus** le raccoglie via ServiceMonitor e **Grafana** le mostra con la dashboard ufficiale di Kong.

## Architettura

Cluster minikube (driver Docker, 4 GB). Due namespace: `kong` e `monitoring`.

```
┌────── namespace: kong ─────────┐              ┌─── namespace: monitoring  ───┐
│                                │ "Scrape via  │                              │
│  Kong (DB-less)                │   Service    │    kube-prometheus-stack     │
│    :8000  proxy                │   Monitor"   │      ┌──────────────┐        │
│    :8100  status / metrics ────┼──────────────┼──▶   │  Prometheus  │        │
│    plugin prometheus (opt-in)  │              │      │  (operator)  │        │
│                                │              │      └──────┬───────┘        │
│  httpbin (service di test)     │              │             │                │
│                                │              │      ┌──────▼───────┐        │
│                                │              │      │   Grafana    │        │
│                                │              │      └──────────────┘        │
└────────────────────────────────┘              └──────────────────────────────┘       
```

- **Kong DB-less** installato via Helm (`kong/kong`): nessun database, **config dichiarativa**.
- **httpbin** app di test raggiunta attraverso Kong via un Ingress (`/httpbin`).
- **kube-prometheus-stack** (Helm) Prometheus + Grafana + Operator, con datasource già
  pre-collegato.
  
## Cosa è Kong?
**Kong Gateway** è un **API gateway** che si trova davanti alle API/microservizi e fa da punto d'ingresso unico (il client parla con Kong, che inoltra al servizio giusto a monte).
Rispetto a un reverse proxy generico(HAProxy), Kong è pensato per le API e aggiunge un livello di funzionalità tramite plugin:
- autenticazione
- rate limiting
- trasformazioni
- logging (per noi metriche)

## Cosa espone?
Kong non espone metriche di default, si attiva il plugin prometheus che pubblica `/metrics` sulla Status API (porta 8100).
Le metriche più caratteristiche di un gateway sono le tre latenze: `totale (request)`, `tempo dentro Kong (proxy)` e `tempo dell'upstream`.

Punto critico: nelle versioni recenti del plugin, le metriche di traffico (codici di stato per service/route, latenze, bandwidth, salute upstream) sono `opt-in` ovvero disattivate di default. Vanno abilitate esplicitamente, altrimenti si vedono solo metriche di sistema (memoria, connessioni).

## File (manifest Kubernetes)

| File | Ruolo |
|------|-------|
| `kong-values.yml` | values Helm: `database: off`, admin disabilitata, proxy NodePort |
| `httpbin.yml` | Deployment + Service + Ingress dell'app di test |
| `kong-prometheus-plugin.yml` | `KongClusterPlugin` che abilita le metriche opt-in |
| `kong-metrics-monitor.yml` | Service `kong-status` (porta 8100) + ServiceMonitor |

## Passo 1 - Creazione del cluster
Per prima cosa ho creato un cluster Kubernetes a nodo singolo isolato, chiamato kong-lab (il flag -p è il profilo, che lo tiene separato da altri cluster minikube).
Gli ho inoltre assegnato il driver Docker (Kubernetes girerà dentro un container Docker), 4 GB di RAM e 2 CPU.

```bash
# 1. cluster dedicato
minikube start -p kong-lab --driver=docker --memory=4096 --cpus=2
```
## Passo 2 - Namespace e repository Helm
Ho creato un namespace dedicato dentro il cluster, dove vivranno i pod di Kong, ed ho scaricato il catalogo ufficiale ed aggiornato dei chart di Kong.

```bash
# 2. namespace e repo Helm
kubectl create namespace kong
helm repo add kong https://charts.konghq.com && helm repo update
```
## Passo 3 - Installazione di Kong DB-less
Ho installato kong nel namespace, usando il file di values kong-values.yml scritto in precedenza per configurarlo in modalità DB-less(nessun database e configurazione dichiarativa), con l'Admin API disabilitato per sicurezza e il proxy esposto come NodePort.
> Il flag `--set ingressController.installCRDs=false` evita di reinstallare le Custom Resource Definition già presenti nel cluster.

```bash
# 3. Kong DB-less
helm install kong kong/kong -n kong --values kong-values.yml \
  --set ingressController.installCRDs=false
```
## Passo 4 - Applicazione dell'app di test dietro Kong
Poi ho creato un app di test, attraverso il manifest `httpbin.yml`, per dare a kong un servizio da monitorare, dato che senza un' applicazione a monte Kong non genererebbe metriche di traffico. E' un'app che espone endpoint HTTP dal comportamento prevedibile: `/get` restituisce un JSON con i dettagli della richiesta, `/status/404` e `/status/500` rispondono con quel preciso codice HTTP. Questo permette di generare traffico controllato e vedere le risposte comparire nelle metriche di Kong divise per codice di stato.

Applicando il manifest vengono creati 3 oggetti:
- **Deployment**: Esegue e mantiene attivo il pod di httpbin e se esso muore viene ricreato.
- **Service**: Indirizzo interno stabile per raggiungere il pod poiché gli IP dei pod cambiano di continuo, avevo bisogno di qualcosa che smistasse le richieste al pod corrente.
- **Ingress**: E' la regola di instradamento che collega l'app a kong, dichiarando che il traffico sul path `/httpbin` debba essere inoltrato al Service httpbin.
Catena completa : Una richiesta a `/httpbin/get` arriva al proxy di Kong, che grazie alla route generata dall'Ingress la inoltra al Service httpbin, che a sua volta la consegna al pod httpbin.
La risposta torna indietro per la stessa strada, e nel passaggio Kong registra le metriche (codice di stato, latenza, banda) che poi Prometheus raccoglie.

```bash
# 4. app di test dietro Kong
kubectl apply -f httpbin.yml
```
## Passo 5 - Abilitazione metriche di traffico
Come detto prima nelle versioni recenti del plugin, le metriche di traffico sono `opt-in` quindi ho bisogno di qualcosa che attivi/abiliti le metriche di traffico.
Ho scritto un file `kong-prometheus-plugin.yml` che una volta applicato crea un `KongClusterPlugin` globale che attiva il plugin Prometheus con le famiglie di metriche opt-in (codici di stato per service/route, latenze, bandwidth, salute upstream).

```bash
# 5. abilita le metriche di traffico (opt-in) del plugin prometheus
kubectl apply -f kong-prometheus-plugin.yml
```
## Passo 6 - Stack di monitoraggio
Dopodiché ho installato l'infrastruttura che raccoglie e visualizza le metriche, andando prima a creare un namespace separato `monitoring` per distinguere "l'applicazione da monitorare" dal "sistema che la monitora".
Quindi ho installato nel nuovo namespace la chart helm `kube-prometheus-stack` che distribuisce, già integrati tra loro, Prometheus (distribuisce, già integrati tra loro, Prometheus (raccoglie e conserva le metriche), Grafana (per visualizzarle) e il Prometheus Operator (che sa quale Service andare a Scrapare grazie al ServiceMonitor).

Le flag inserite:
- `alertmanager.enabled=false` che disabilita gli alert, dato che avevo in mente di visualizzare soltanto le metriche.
- `grafana.adminPassword=admin` che imposta una password semplice per grafana 
- `prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false` che fa in modo che Prometheus adotti tutti i ServiceMonitor del cluster, per fargli adottare anche quello di
  kong che spiego al prossimo punto, che altrimenti non troverebbe.
  
```bash
# 6. stack di monitoraggio
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
kubectl create namespace monitoring
helm install monitoring prometheus-community/kube-prometheus-stack -n monitoring \
  --set alertmanager.enabled=false \
  --set grafana.adminPassword=admin \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false
```
## Passo 7 - Esposizione delle metriche e scrape
Infine ho scritto e applicato un nuovo manifest `kong-metrics-monitor.yml` per creare due risorse importanti:
- **Service** che pubblica la porta 8100 del pod Kong (dove vivono le metriche del gateway).
- **ServiceMonitor** che dice al Prometheus Operator di scrapare proprio quel Service.
Su Kubernetes gli IP dei pod cambiano di continuo per cui configurare indirizzi statici in un prometheus.yml sarebbe ingestibile.
Con il `ServiceMonitor` invece di dire 'scrapa l'indirizzo X' lo faccio in maniera dichiarativan('scrapa i Service con questa label, su questa porta, su questo path').
Il Prometheus Operator legge il ServiceMonitor, trova i Service corrispondenti, scopre gli IP correnti e genera la configurazione di Prometheus automaticamente, e la aggiorna quando i pod cambiano.

```bash
# 7. esponi la porta 8100 di Kong e dì a Prometheus di scraparla
kubectl apply -f kong-metrics-monitor.yml
```

## Accessi (via port-forward / tunnel)
In questo lab non ho il port forwarding di Vagrant, i servizi vivono dentro il cluster e sono isolati(non possono essere raggiunti dal Mac con localhost).
Ho bisogno quindi:
- Un tunnel verso il `proxy di Kong` e restituisce un URL con porta casuale,(valido finché il terminale resta aperto) per inviargli traffico di test.
- Un port-forward per aprire l'interfaccia di Grafana nel Browser del Mac, che mappa la porta 80 del service Grafana sulla porta 3000 del Mac rendendo la UI accessibile su
  http://localhost:3000 (valido finché il terminale resta aperto).
> In produzione userei un LoadBalancer o un ingress fatto meglio ma era per velocizzare la visualizzazione.


```bash
# proxy Kong (per generare traffico) — porta casuale, tenere il terminale aperto
minikube -p kong-lab service kong-kong-proxy -n kong --url

# Grafana
kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80
# → http://localhost:3000  (admin/admin)
```

## Dashboard

Importata dal catalogo grafana.com — **Kong (official), ID 7424** — via
*Dashboards → New → Import → ID 7424*. Sezioni: Request rate, Latencies, Bandwidth, Caching,
Upstream, Nginx. I dati compaiono generando traffico attraverso il proxy.

![seconda_parte](nexus/Screenshot%202026-09-01%20alle%2015.44.15.png)

## Deployment: perché Kubernetes (nota teorica)

Kong DB-less è stateless → si presta a Kubernetes (replicabile, scalabile, come Ingress
Controller). "Kong va dove vivono le API": se le API sono su K8s, ci va anche il gateway.
Su VM avrebbe più senso la modalità con database (PostgreSQL) per installazioni piccole.
