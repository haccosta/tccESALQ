# Diagnóstico: Por que Round-Robin está com pior desempenho

## Resumo dos Dados Observados

| Métrica | Round-Robin | Pick-First | Delta |
|---------|-------------|-----------|-------|
| Throughput (req/s) | 3518 | 4001.9 | **-12% pior** |
| http_req_duration (avg) | 278.31ms | 245.32ms | **-13.5% pior** |
| p(95) | 465.04ms | 416.81ms | **-11.5% pior** |
| max | 8.77s | 2.74s | **-220% pior** |
| Iterações/3m | 635276 | 722375 | **-12.1% pior** |

## 🔴 Potenciais Causas (Ordem de Probabilidade)

### 1. **ALTA: CPU contention em pods com limite de 1CPU (Recurso limitado)**
**Sintoma:** p95 e max muito ruins; comportamento degradado com distribuição.
**Causa raiz:**
- 3 pods com limite de `1 CPU` cada + 1 cliente = muita competição por CPU
- Round-robin distribui carga entre 3 pods; cada pod recebe ~1/3 do tráfego, mas com overhead de context-switch
- Pick-first concentra tudo em 1 pod (talvez menos context-switch)
- Com apenas 1 CPU por pod, GC/thread scheduling fica crítico

**Evidence (procurar em logs):**
- Picos de latência quando múltiplos pods recebem requisições simultâneas
- CPU de cada pod próximo a 100%
- p95/max muito piores = indicativo de "queuing" em thread pools

**Verificação:**
```bash
# No cluster, verificar CPU real dos pods durante carga
kubectl top pods -l app=grpc-java-server --containers
# Verificar eventos de OOMKilled ou CPU throttling
kubectl describe pod <pod-name>
```

---

### 2. **ALTA: Múltiplas conexões TCP / TLS overhead por subchannel (gRPC round-robin behavior)**
**Sintoma:** latência aumentada, máximo alto.
**Causa raiz:**
- gRPC round-robin cria um **subchannel por endpoint descoberto** (ex.: 3 endpoints = 3 conexões TCP)
- Mesmo com o ManagedChannel singleton, HTTP/2 multiplexing, se há problema de handshake/keep-alive:
  - Cada subchannel pode estar abrindo/fechando conexões
  - Com alta concorrência (1000 VUs), multiplexing pode não ser eficiente
  - Pick-first usa apenas 1 conexão → menos overhead

**Evidence:**
- `netstat/ss` no servidor mostrando muitas conexões ESTABLISHED / TIME_WAIT
- Latências altas em picos (conexões sendo abertas)

**Verificação:**
```bash
# No servidor, verificar conexões ao port 50051
ss -tn state established sport = :50051 | wc -l
ss -tn state time-wait | head -20
# Do cliente, verificar conexões ao port 50051 (destino)
ss -tn dport = :50051 state established | wc -l
```

---

### 3. **ALTA: "Warm cache" / JIT compiler effect**
**Sintoma:** pick-first bom, round-robin ruim, especialmente em picos.
**Causa raiz:**
- **Pick-first:** todas as 635K requisições vão para **1 pod** → JIT compiler aquece bem, método caches quentes, inline caches eficientes
- **Round-robin:** ~212K req/pod (635K / 3) → cada pod tem cache "frio", JIT menos ativo
- Java startup/warmup é lento; após~10min de carga, ambos convergem? (testar)

**Evidence:**
- Latências mais estáveis após alguns minutos (if JIT kicks in)
- p95 antes vs depois de 1min = indicador

**Verificação:**
```bash
# Habilitar JIT/GC logs no servidor
# Adicionar a container Dockerfile/deployment:
-XX:+PrintCompilation -XX:+PrintInlining -Xlog:jit+compilation:file=/tmp/jit.log
```

---

### 4. **MÉDIA: GC Pause / Garbage Collection**
**Sintoma:** picos ocasionais (max muito alto, p95 alto).
**Causa raiz:**
- Com 3 pods concorrentes fazendo GC ao mesmo tempo + context-switching de threads
- Limite de 500Mi RAM pode causar GC mais agressivo (young/old gen pauses)
- Round-robin pode desencadear padrão GC diferente (mais disparatado)

**Evidence:**
- Picos de latência que recaem (GC pause)
- Max = 8.77s é muito alto para uma operação simples (8s+ é típico de GC pause)

**Verificação:**
```bash
# Habilitar GC logs detalhados
# Adicionar ao server JVM:
-Xlog:gc*:file=/tmp/gc.log:time,uptime,level,tags -XX:+PrintGCDetails
# Então rodar carga e analisar gc.log
```

---

### 5. **MÉDIA: Thread pool exhaustion / Executor starvation**
**Sintoma:** latências aumentadas com distribuição.
**Causa raiz:**
- gRPC server usa Netty executor pool
- Com 3 pods e virtual threads, limite de concorrência por pod pode ser atingido
- Round-robin distribuído pode saturar threads em alguns pods (load imbalance real)
- Pick-first sem distribuição: menos disputa por threads

**Evidence:**
- Spring Boot logs mostrando "queue too long" ou rejected tasks
- Netty event loops bloqueados

**Verificação:**
```bash
# Verificar número de threads por pod
kubectl exec <pod-name> -- jcmd <pid> Thread.print | grep -c "grpc"
# Verificar se há rejeição de tasks
kubectl logs <pod-name> | grep -i "reject\|queue\|starvation"
```

---

### 6. **MÉDIA: Overhead do DNS resolver / headless service discovery**
**Sintoma:** resolve oscilante, endpoints descobertos de forma inconsistente.
**Causa raiz:**
- Headless Service setup está correto, MAS:
  - DNS cache no cliente pode estar retornando ordem aleatória (não round-robin puro)
  - TTL baixo = muitas queries DNS
  - Round-robin sem cache = mais descoberta, mais latência

**Evidence:**
- DNS queries frequentes no cluster
- Order de endpoints muda aleatoriamente

**Verificação:**
```bash
# Dentro do cliente pod, checar DNS resolution
kubectl exec <client-pod> -- nslookup grpc-java-server.default.svc.cluster.local
kubectl exec <client-pod> -- dig grpc-java-server.default.svc.cluster.local +trace
```

---

### 7. **BAIXA: Application-level lock contention / database bottleneck**
**Sintoma:** pior com múltiplos threads (round-robin), melhor com serializados (pick-first).
**Causa raiz:**
- Se houver estado compartilhado (cache, DB) e aplicação não thread-safe
- Round-robin com mais concorrência simultânea = mais lock contention

**Evidence:**
- Traces/Jaeger mostrando spans longos em locks/sincronização
- Logs de "synchronized" method latências altas

**Verificação:**
- Adicionar tracing (OpenTelemetry) ao handler `/api/messages` e ao `sayHello`
- Medir tempo verdadeiro de processamento vs total

---

## 🔧 Ações de Diagnóstico Recomendadas

### 1️⃣ Diagnóstico Rápido (5-10 min)
```bash
# Teste A: Pick-first com resources monitados
kubectl set env deployment/grpc-java-client LB_POLICY=pick_first
kubectl top pods -l app=grpc-java-server --containers --all-namespaces &
# Rodar carga por 3 min com k6
k6 run stress-test/load-tests.js

# Teste B: Round-robin com resources monitados
kubectl set env deployment/grpc-java-client LB_POLICY=round_robin
# Rodar carga por 3 min com k6
k6 run stress-test/load-tests.js

# Comparar:
# - CPU real dos pods
# - Memória
# - Latências
```

### 2️⃣ Verificar Conexões TCP
```bash
# Durante round-robin em outro terminal
kubectl exec <server-pod-0> -- ss -tn state established sport = :50051 | wc -l
kubectl exec <server-pod-1> -- ss -tn state established sport = :50051 | wc -l
kubectl exec <server-pod-2> -- ss -tn state established sport = :50051 | wc -l
# Compare com pick-first: esperamos 1 conexão em 1 pod, 0 em outros
```

### 3️⃣ Habilitar GC Logs no Servidor
**Modificar `Dockerfile-server` ou deployment:**
```dockerfile
ENV JAVA_OPTS="-Xlog:gc*:file=/tmp/gc$HOSTNAME.log:time,uptime,level,tags -XX:+PrintGCDetails"
```
Depois rodar carga e analisar:
```bash
kubectl exec <pod> -- cat /tmp/gc*.log | grep "Pause" | head -20
```

### 4️⃣ Adicionar Tracing / Metricas por Request
Modificar `GrpcClientApiController.java` para logar tempo de processamento:
```java
long start = System.nanoTime();
HelloResponse response = this.blockingStub.sayHello(request);
long duration = (System.nanoTime() - start) / 1_000_000; // ms
LOGGER.info("gRPC call took {}ms", duration);
```

### 5️⃣ Teste com Menos Concorrência
Se for CPU contention, testar com menos VUs:
```javascript
// load-tests.js: alterar stages para 100 VUs em vez de 1000
stages: [
    { duration: '3m', target: 100 }
]
```
Se latência melhora muito → é CPU contention.

### 6️⃣ Testar com Mais Recursos
```yaml
# k8s-grpc-stress-test.yaml
resources:
  limits:
    cpu: "2"           # aumentar de 1
    memory: "1Gi"      # aumentar de 500Mi
```
Se round-robin melhora significativamente → é CPU/memória contention.

---

## 🎯 Hipótese Mais Provável

**CPU contention + "warm JIT" effect**

1. **Round-robin** distribui 4000 req/s entre 3 pods = ~1333 req/s por pod
2. Cada pod com 1 CPU, Project Loom (virtual threads) pode ter mais overhead de scheduling
3. 3 pods concorrentes fazendo GC/compilação ao mesmo tempo
4. Pick-first concentra 4000 req/s em 1 pod = melhor CPU utilization de esse pod (100% utilizado) vs 3 pods com 40% cada (mais overhead de context-switch)

**Recomendação:** Rodar Teste A com `top` / `kubectl top pods` monitorando CPU em tempo real.

---

## 📊 Próximos Passos Automáticos

Vou criar um script automático para coletar dados de diagnóstico:
- [ ] Script k6 que mede latência por backend (se houver header)
- [ ] Coletor de métricas (CPU/mem/threads) durante testes
- [ ] Análise de logs GC

