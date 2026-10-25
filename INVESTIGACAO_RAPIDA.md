# Potenciais Causas: Round-Robin Pior que Pick-First

## 🔍 Investigação Rápida (Sem Kubernetes, Localmente)

Se você está rodando tudo localmente ou em container único, use esses comandos:

### 1️⃣ Verificar se round-robin está realmente sendo usado
```bash
# Dentro do cliente, procurar por logs de descoberta DNS
kubectl logs -l app=grpc-java-client | grep -i "dns\|roundrobin\|endpoint" | tail -20

# Ou, conectar ao client pod e fazer discovery manual
kubectl exec <client-pod> -- nslookup grpc-java-server.default.svc.cluster.local
kubectl exec <client-pod> -- dig grpc-java-server.default.svc.cluster.local +short

# Esperado: múltiplos IPs (para round-robin funcionar)
# Se ver apenas 1 IP: round-robin não pode distribuir!
```

### 2️⃣ Verificar Conexões TCP (Cliente para Servidor)
```bash
# Do lado do cliente (executar durante teste)
kubectl exec <client-pod> -- ss -tn dport = :50051 state established | wc -l
# Esperado com round-robin: múltiplas conexões (1+ por servidor)
# Esperado com pick-first: 1 conexão única

# Do lado do servidor (ver quantos clientes conectados por pod)
for pod in $(kubectl get pods -l app=grpc-java-server -o jsonpath='{.items[*].metadata.name}'); do
  echo "$pod:"
  kubectl exec $pod -- ss -tn sport = :50051 state established | wc -l
done
```

### 3️⃣ Verificar Latência Real do gRPC (não via HTTP)
#Se o k6 está testando HTTP (lento) e não gRPC direto, o overhead pode estar ali.
```bash
# Substituir no load-tests.js para testar gRPC direto (menos overhead)
# OU focar em HTTP overhead
```

### 4️⃣ Thread Count / CPU Load
```bash
# Observar threads ativos nos pods
for pod in $(kubectl get pods -l app=grpc-java-server -o jsonpath='{.items[*].metadata.name}'); do
  echo "=== $pod ==="
  kubectl exec $pod -- jcmd $(pgrep java) Thread.print | grep -c "grpc"
done

# Observar CPU em tempo real durante o teste
kubectl top pods -l app=grpc-java-server --containers --watch
```

### 5️⃣ GC Pause Analysis
```bash
# Adicionar variável de ambiente ao deployment do servidor
kubectl set env deployment/grpc-java-server \
  JAVA_OPTS="-Xlog:gc*:file=/tmp/gc.log:time,uptime,level,tags"

# Depois, copiar os logs de GC
kubectl cp grpc-java-server-<pod-id>:/tmp/gc.log ./gc_roundrobin.log

# Buscar pausas longas
grep "Pause" gc_roundrobin.log | head -20
```

### 6️⃣ Comparar Latência por Backend
```bash
# No servidor, modificar resposta para incluir informação de qual pod processou
# Depois logar qual pod respondeu no cliente
# Verificar se distribution está realmente round-robin ou se há preferência

kubectl logs -l app=grpc-java-server | tail -100 | \
  grep -o "REQ=\[[0-9]*\]" | sort | uniq -c | sort -rn
# Se todos os REQ=[] vão para 1 pod → round-robin NÃO está funcionando
```

### 7️⃣ Memória / Out-of-Memory
```bash
# Verificar memory pressure
kubectl describe nodes | grep -A 5 "Memory:"

# Se houver swap ou memory pressure → problemas de GC/thrashing
kubectl top nodes --show-capacity
```

---

## 📊 Diagnóstico em Profundidade

### A. Cenário: CPU Contention (MAIS PROVÁVEL)
**Sintoma:** Max e p95 muito altos com round-robin

**Verificação:**
```
1. Rodar teste pick-first → observar CPU de \*cada\* pod: esperado ~33% (1 pod 100%, 2 pods idle)
2. Rodar teste round-robin → observar CPU: esperado ~33% por pod, mas com mais variância
3. Se round-robin tiver CPU throttling em alguns pods → é contention!
```

**Solução:**
- Aumentar CPU nos pods (teste com 2-4 CPUs)
- Ou usar pick-first / sticky affinity

---

### B. Cenário: Warm Cache / JIT Effect (PROVÁVEL)
**Sintoma:** Pick-first ótimo desde o começo, round-robin melhora após 1-2 min

**Verificação:**
```
1. Coletar latências por minuto:
   - Minuto 0-1 (cold start)
   - Minuto 1-2 (JIT warmup)
   - Minuto 2+ (steady state)
2. Comparar p95 por minuto
3. Se pick-first melhora rápido e round-robin não → JIT effect
```

**Solução:**
- Usar "warmed up" instances (pre-compilação)
- Ou aceitar que pick-first é melhor para latência, round-robin para throughput

---

### C. Cenário: DNS Discovery Issue (IMPROVÁVEL)
**Symptom:** Round-robin não distribui de verdade, tudo vai para 1 servidor

**Verificação:**
```
1. kubectl exec <client-pod> -- nslookup grpc-java-server
   → Deve retornar 3 IPs diferentes
2. Si retorna apenas 1 IP → headless service não está configurado
```

**Solução:**
- Garantir headless service (`clusterIP: None`)
- Ou usar direct pod IPs em vez de DNS

---

### D. Cenário: Multiple TCP Connection Overhead (IMPROVÁVEL)
**Symptom:** Muitas conexões abertas, TIME_WAITs elevados

**Verificação:**
```
ss -tn state time-wait | wc -l
ss -tn sport = :50051 state established | wc -l
```

**Solução:**
- Habilitar SO_REUSE + TCP_NODELAY
- Aumentar `tcp_tw_reuse` host

```
sudo sysctl -w net.ipv4.tcp_tw_reuse=1
```

---

## 🚀 Teste Rápido (5 minutos)

Se quer resultado rápido, execute:

```bash
# 1. Terminal 1: Monitor de recursos
watch 'kubectl top pods -l app=grpc-java-server --containers'

# 2. Terminal 2: Monitor de conexões
watch 'for pod in $(kubectl get pods -l app=grpc-java-server -o jsonpath=..); do echo "$pod:" && kubectl exec $pod -- ss -tn sport = :50051 state established | wc -l; done'

# 3. Terminal 3: Teste A (pick-first)
kubectl set env deployment/grpc-java-client LB_POLICY=pick_first
kubectl rollout status deployment/grpc-java-client
k6 run stress-test/load-tests.js --duration 3m --vus 1000

# 4. Esperar ~30s de cooldown

# 5. Terminal 3: Teste B (round-robin)
kubectl set env deployment/grpc-java-client LB_POLICY=round_robin
kubectl rollout status deployment/grpc-java-client
k6 run stress-test/load-tests.js --duration 3m --vus 1000

# 6. Comparar resultados!
```

---

## 💡 Se Round-Robin Melhorar Após Ajustes

Se os ajustes no código (GrpcClientConfig, keep-alive, interceptors) fizerem round-robin melhorar:
- **Causa era:** Perda de multiplexing / criação excessiva de conexões
- **Solução:** Manter a configuração otimizada

Se round-robin NOT melhorar mesmo após ajustes:
- **Causa provável:** CPU contention ou JIT effect
- **Solução:** Aumentar recursos ou usar pick-first

---

## 📝 Checklist de Diagnóstico

- [ ] DNS resolve múltiplos IPs?
- [ ] Round-robin cria múltiplas conexões TCP?
- [ ] CPU está distribuída entre pods ou concentrada?
- [ ] Há pausas de GC longas (p95/max)?
- [ ] Memória está sob pressão (swap/OOMKilled)?
-[] JIT está aquecendo em ambos (ou apenas em pick-first)?
- [ ] Latência melhora ao longo do tempo (warmup)?
- [ ] Thread count equilibrado ou desequilibrado?


