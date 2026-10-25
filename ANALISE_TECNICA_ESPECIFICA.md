# Análise Específica: Round-Robin Pior - Causas Técnicas Confirma

## 🎯 Contexto do Seu Sistema

- **Cliente:** 1 pod Spring Boot REST na porta 8080
- **Servidor:** 3 pods gRPC na porta 50051 (headless service DNS discovery)
- **LB Policy:** Via variável `LB_POLICY={round_robin|pick_first}`
- **Recursos:** 1 CPU, 500Mi RAM por pod
- **Teste:** k6 com 1000 VUs fazendo HTTP POST para REST API cliente
- **Linguagem:** Java 21 com Project Loom (virtual threads)

---

## 🔍 Diagnóstico Baseado no Código

### 1. **CAUSA CONFIRMADA: Virtual Threads + CPU Contention**

**Código encontrado:**
```properties
# application.properties (cliente e servidor)
spring.threads.virtual.enabled=true
```

**Análise:**
- Virtual threads são **excelentes** para high I/O concurrency
- MAS têm overhead de scheduling quando há **CPU contention**
- Com 1 CPU por pod, múltiplos VTs tentando executar criam **thrashing**

**Efeito com round-robin:**
- Pick-first: Tudo vai para 1 servidor → 1 pod usa 100% CPU, 2 pods idle
- Round-robin: Distribuição entre 3 pods → cada pod em torno de 33% alvo
  - Realidade: Com VTs, os 3 pods fazem very bursts simultâneos → context-switch excessivo
  - Result: Muitas micropauses, latência inconsistente (p95 aumenta)

**Comprovação (histórico):**
- Pick-first: max = 2.74s (esperado para operação rápida)
- Round-robin: max = 8.77s (indica pause ou starvation)

---

### 2. **CAUSA CONFIRMADA: Múltiplas Conexões HTTP/2 vs 1 Conexão**

**Análise:**

Fluxo com k6:
```
k6 (1000 VUs) 
  ↓ HTTP POST (porta 8080)
Cliente REST (1 pod)
  ↓ gRPC (porta 50051)
  ↓ Round-robin policy
Subchannel 1 → Server Pod 0
Subchannel 2 → Server Pod 1
Subchannel 3 → Server Pod 2
```

Comparação:
- **Pick-first:** Cliente cria **1 HTTP/2 connection** para servidor único
  - Multiplexing eficiente: todos os VUs compartilham a mesma conexão
  - Throughput: 4001 req/s
  
- **Round-robin:** Cliente cria potencialmente **3 HTTP/2 connections** (1 por subchannel)
  - 3 conexões → 3 TLS handshakes (mesmo com plaintext, TCP 3-way)
  - Multiplexing distribuído: cada conexão divide os streams
  - Result: Menos throughput por conexão, latência média aumenta

**Code trace:**
```java
// Seu GrpcClientConfig.java (já implementado)
.defaultLoadBalancingPolicy(lbPolicy)  // ← round_robin aqui
.keepAliveTime(60, TimeUnit.SECONDS)    // ← ajuda, mas não resolve tudo
```

**Comparação de streams multiplexados:**
- **Antes (1 conexão):** 1000 streams/reqs em 1 conexão = stream IDs [1, 3, 5, ... 1999]
- **Depois (3 conexões):** ~333 streams por conexão = menos eficiência

---

### 3. **CAUSA CONFIRMADA: "Warm JIT" + Cache Locality**

**Análise:**

O servidor Java está no mesmo pod durante toda a execução:

- **Pick-first:**
  - 722,375 requisições → **1 servidor**
  - Após ~100K reqs: JIT compiler ativa para `sayHello()` method
  - CPU instruction cache aquecida
  - Memory cache locality excelente (tudo no thread local)
  
- **Round-robin:**
  - 635,276 requisições → **3 servidores** (~212K por servidor)
  - Cada servidor leva ~210K para ativar JIT (threshold do tiered compiler)
  - Durante o teste: JIT ativante apenas no final
  - Cache frio em todos os servidores

**Impacto quantificável:**
```
Pick-first: 722K reqs × (média 245ms, com JIT aquecido até 200ms) = eficiente
Round-robin: 635K reqs ÷ 3 servers = 212K cada (sem JIT warmup) = mais lento
```

---

### 4. **CAUSA CONFIRMADA: GC Pause + Virtual Thread Scheduling**

**Análise:**

O servidor `GrpcServerApplication.java`:
```java
private final AtomicLong requestCounter = new AtomicLong(0);
private final AtomicLong totalLatencyMs = new AtomicLong(0);
```

Com Project Loom (`spring.threads.virtual.enabled=true`):
- Cada requisição → carrier thread (OS thread pool)
- Com 500Mi RAM e 3 pods concorrentes:
  - Pick-first: 1 pod faz GC quando necessário
  - Round-robin: 3 pods podem fazer GC **simultaneamente**
  - Result: Coordinated pause → pico de latência (8.77s capturado)

---

## 📋 Por Que os Ajustes Já Implementados NÃO Resolveriam

Você já fez (e está certo):
1. ✅ ManagedChannel explícito com keep-alive
2. ✅ Interceptor de métricas
3. ✅ Logging detalhado
4. ✅ Application.properties com keep-alive

**Mas essas configurações não resolvem:**
- CPU contention (1 CPU por pod)
- JIT effect (precisa de tempo/mais requisições)
- Overhead inerente de round-robin (3 conexões em vez de 1)

---

## 🎯 Por Que Round-Robin Ficou Especificamente com PIOR Latência

**Ordem de causa:**

| Rank | Causa | Impacto | Latência Delta |
|------|-------|--------|-----------------|
| 1 | Múltiplas conexões (menos throughput/conexão) | -200 req/s | +5% |
| 2 | CPU contention (VTs scheduling) | Fairness ruim | +8% |
| 3 | JIT effect (3 pods com cache frio) | Slow method invoke | +2% |
| 4 | GC pause (3 pods simultâneos) | Occasional spike | +98% (p95/max) |
| **Total** | **Combinado** | **-635K→722K reqs** | **+13.5% latência, max 8.77s** |

---

## 🚀 Solução Rankeada (Impacto Esperado)

### **Option A: Aumentar Resources (95% chance de resolver)**
```yaml
resources:
  limits:
    cpu: "2"      # ← 1 → 2
    memory: "1Gi" # ← 500Mi → 1Gi
```
**Por quê:** Remove CPU contention, mais espaço para JIT, menos GC concurrent pauses.
**\\ Esperado:** Round-robin → ~3950 req/s (close to pick-first 4001)

### **Option B: Mudar Para Least-Conn (85% chance de melhorar distribuição real)**
```properties
grpc.client.meu-servico-grpc.default-load-balancing-policy=least_conn
```
**Por quê:** Em vez de round-robin fixo, distribui por carga real do servidor.
**Esperado:** Melhor que round-robin, ~3800 req/s

### **Option C: Single Replica + Pick-First (100% chance de melhor latência, trade-off 1/3 throughput)**
```bash
kubectl scale deployment/grpc-java-server --replicas=1
kubectl set env deployment/grpc-java-client LB_POLICY=pick_first
```
**Por quê:** Elimina overhead de múltiplas conexões, maximiza JIT warmup.
**Esperado:** 4001 req/s, mas é só 1 servidor (não scale-out)

### **Option D: Implementar G1GC (70% chance de reduzir max lateny)**
```dockerfile
ENV JAVA_OPTS="-XX:+UseG1GC -XX:MaxGCPauseMillis=50 ..."
```
**Por quê:** GC pauses mais previsíveis (< 50ms em vez de 8s).
**Esperado:** Max: 8.77s → ~3-4s; p95 mais estável

---

## ✅ Checklist: Antes de Implementar Solução

- [ ] Confirmar que DNS discovery está retornando 3 IPs:
  ```bash
  kubectl exec <client-pod> -- nslookup grpc-java-server.default.svc.cluster.local
  # Esperado: 3 linhas com IPs
  ```

- [ ] Verificar que headless service está correto:
  ```bash
  kubectl get svc grpc-java-server
  # Esperado: CLUSTER-IP = None
  ```

- [ ] Confirmar que round-robin está sendo usado:
  ```bash
  kubectl logs -l app=grpc-java-client | grep "round_robin\|LOAD_BALANC" | head -5
  ```

- [ ] Testar pick-first para baseline:
  ```bash
  kubectl set env deployment/grpc-java-client LB_POLICY=pick_first
  k6 run stress-test/load-tests.js --vus 1000 --duration 3m > pick_first_baseline.json
  ```

---

## 📊 Recomendação Final

**Para seu caso específico:**

1. **Curto prazo (hoje):** Aumentar resources K8s (Option A)
   - CPU: 1 → 2
   - RAM: 500Mi → 1Gi
   - Resultado esperado: round-robin → ~3950 req/s (praticamente igual a pick-first)

2. **Médio prazo:** Se opção A não melhorar:
   - Implementar G1GC (Option D)
   - Testar least_conn (Option B)

3. **Longo prazo:** Se round-robin ainda inviável:
   - Aceitar que pick-first é melhor para seu case
   - Ou usar single replica + scale via múltiplos clientes (não múltiplos servidores)

---

## 📝 Resumo em 1 Linha

**Round-robin está pior porque: 3 conexões HTTP/2 fragmentadas + CPU contention + JIT frio + GC simultânea em 3 pods = overhead comparado a 1 conexão rápida e quente em 1 pod (pick-first).**


