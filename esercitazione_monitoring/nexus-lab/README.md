# Nexus Lab — Monitoraggio JVM con scrape autenticato
Rispetto al lab HAProxy che monitorava il traffico, qui l'oggetto è un'applicazione Java dove il focus si sposta sulla salute della JVM(memoria, garbage collector, thread).

Obiettivo: monitorare **Sonatype Nexus Repository 3** (un'applicazione Java) con Prometheus +
Grafana, imparando a fare uno **scrape autenticato** e a **importare** una dashboard da file JSON.


Risultato: 
Nexus espone ~2200 metriche su un endpoint protetto;
Prometheus le raccoglie autenticandosi con un utente dedicato a soli permessi di lettura; 
Grafana le visualizza su una dashboard a 8 pannelli costruita sulle metriche reali dell'istanza.

# Contesto teorico:

**Cos'è Nexus?**

**Nexus Repository** è un repository manager: un magazzino centralizzato per gli artefatti software e le dipendenze di build.
Ospita gli artefatti interni (hosted), fa da cache verso repository pubblici (proxy) e li aggrega dietro un unico URL (group). Supporta molti formati (Maven, npm, Docker, PyPI, ...).
È un'applicazione Java sulla JVM, infatti la sua salute coincide in larga parte con la salute della sua JVM.
> Se Nexus è lento o si riempie il disco, si ferma l'intera catena di build dell'organizzazione.

**Cosa espone Nexus?**
Le metriche sono in formato Prometheus e si dividono in due grandi famiglie: 
- **JVM/piattaforma** (heap, garbage collection, thread — le più importanti perché Nexus vive sulla JVM);
- **applicative** (richieste HTTP, componenti, task, analytics per formato).

L'endpoint è /service/rest/metrics/prometheus ed è protetto: richiede autenticazione e il privilegio nx-metrics-all.

## Architettura

Stack a 3 container gestito con Podman Compose dentro una VM Vagrant (Ubuntu 24.04, 4 GB RAM):

```
Nexus :8081 (UI/API + /service/rest/metrics/prometheus, PROTETTO da auth)
    │  scrape con basic_auth (utente read-only "metrics")
    ▼
Prometheus :9090 ──▶ Grafana :3000
```

- **nexus** (`sonatype/nexus3`): repository manager Java; heap JVM limitato a 2 GB via
  `INSTALL4J_ADD_VM_PARAMS=-Xms1g -Xmx2g`.
- Dati su un **volume Podman** con nome (`nexus-data`), non su synced folder (evita il gotcha sendfile/vboxsf del lab HAProxy).
- **prometheus**: scrapa l'endpoint metrics di Nexus **con credenziali**.
- **grafana**: dashboard importata da JSON.

## File

| File | Ruolo |
|------|-------|
| `Vagrantfile` | VM Ubuntu 24.04 (4 GB) + Podman 4.x + podman-compose via pipx |
| `compose.yml` | nexus (+ volume) · prometheus · grafana |
| `prometheus.yml` | scrape job con `basic_auth` (password mascherata nel repo) |
| `grafana/nexus-dashboard.json` | dashboard importata (8 pannelli JVM/applicativi) |

## Passo 1 - Scrittura Vagrantfile e vagrant up
Ho scritto il Vagrantfile con file box bento/ubuntu-24.04 ed ho realizzato il port fowording verso il Mac (porte: 8081, 9090, 3000) e il provisioning che installa podman e podman-compose.

```bash
vagrant up
vagrant ssh
cd /vagrant
```

Accessi:
- Nexus UI → http://localhost:8081
- Prometheus → http://localhost:9090
- Grafana → http://localhost:3000 (admin/admin), datasource `http://prometheus:9090`

## Passo 2 - Scrittura podman-compose e costruzione container

Ho poi scritto il file compose.yml attraverso il quale costruisco i container che mi serviranno:
- **Nexus**
- **Prometheus**
- **Grafana**

Definendo per ognuno l'immagine da Docker Hub, volume e porte descritte anche sopra.
Il parametro `INSTALL4J_ADD_VM_PARAMS=-Xms1g -Xmx2g -XX:MaxDirectMemorySize=2g` è la variabile d'ambiente con cui Nexus passa alla propria JVM i limiti di memoria, imponendo un heap che parte da 1 GB all'avvio (-Xms1g), non supera i 2 GB (-Xmx2g, il tetto oltre il quale la JVM solleva un `OutOfMemoryError` anziché continuare a consumare RAM) e una memoria off-heap (usata per l'I/O efficiente nel trasferimento degli artefatti) limitata a 2 GB (`-XX:MaxDirectMemorySize=2g`).
Questo "budget di memoria" è necessario perché, lasciata libera, la JVM di Nexus tenderebbe ad allocare troppa RAM e, in una VM da soli 4 GB condivisa con Prometheus, Grafana e il sistema operativo, la manderebbe in swap degradando l'intero lab.

Ho quindi costruito i container dentro la VM:

```bash
vagrant ssh
cd /vagrant
podman-compose up -d   # all'inizio ci metterà un pò
```

## Passo 3 - Endpoint metriche e autenticazione nel prometheus.yml

Le metriche di Nexus sono in formato Prometheus su:

```
/service/rest/metrics/prometheus
```

(l'endpoint `/service/metrics/prometheus` risponde con un redirect 301 verso questo).
L'endpoint è **protetto**: richiede autenticazione e il privilegio `nx-metrics-all`.

**Buona pratica applicata (least privilege):** invece dell'admin, ho creato un utente
dedicato `metrics` con un ruolo `metrics-reader` che possiede **solo** il privilegio
`nx-metrics-all`.

Verifica:

```bash
# legge le metriche → 200
curl -o /dev/null -w "%{http_code}" -u metrics:*** http://localhost:8081/service/rest/metrics/prometheus
# NON può fare azioni da admin → 403
curl -o /dev/null -w "%{http_code}" -u metrics:*** http://localhost:8081/service/rest/v1/security/users
```

Ho poi scritto il config di scrape (`prometheus.yml`):

```yaml
scrape_configs:
  - job_name: 'nexus'
    metrics_path: /service/rest/metrics/prometheus
    basic_auth:
      username: metrics
      password: __NEXUS_METRICS_PASSWORD__   # La password è privata
    static_configs:
      - targets: ['nexus:8081']
```
Dove ho inserito una password e username in modo che prometheus effettuasse lo scrape una volta fatta prima l'autenticazione.

## Dashboard Grafana importata con 8 pannelli su metriche reali.

Importo una Dashboard che mi fa visionare 8 pannelli su metriche reali in Grafana(descritti sotto):
> Nota: Bisogna prima andare a scegliere il datasource Prometheus, dato che non l'ho impostato di default ma si può impostare facilmente.
![seconda_parte](nexus/Screenshot%202026-09-01%20alle%2015.44.15.png)

**Metriche chiave** (famiglia JVM + applicative):

| Pannello | Metrica |
|----------|---------|
| Stato Nexus | `up{job="nexus"}` |
| Utilizzo Heap JVM (%) | `jvm_memory_heap_usage * 100` |
| Thread totali | `jvm_thread_states_count` |
| Componenti totali | `nexus_analytics_component_total_count` |
| Memoria Heap | `jvm_memory_heap_used / _committed / _max` |
| Pool G1 (Garbage Collector) | `jvm_memory_pools_G1_Eden_Space_used`, `_Old_Gen_used`, `_Survivor_Space_used` |
| Thread per stato | `jvm_thread_states_runnable_count`, `_waiting_count`, `_blocked_count` |
| Non-Heap / Metaspace | `jvm_memory_non_heap_used`, `jvm_memory_pools_Metaspace_used` |
