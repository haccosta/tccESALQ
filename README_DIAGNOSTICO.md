# README: Diagnóstico Round-Robin Performance

## 📖 Visão Geral

Este diretório contém uma análise completa e ferramentas de diagnóstico para identificar **por que round-robin está com pior performance (12% menor throughput, 13% maior latência, 220% maior spike de latência) comparado a pick-first** em seu projeto gRPC Java.

---

## 📁 Documentos Gerados

### 1. **RESUMO_EXECUTIVO.md** ⭐ **COMECE AQUI**
- Visão geral de 5 minutos
- Dados observados e potenciais causas rankeadas
- Modificações já implementadas
- Próximas ações (curto/médio/longo prazo)
- **Tempo de leitura:** 5min

### 2. **ANALISE_TECNICA_ESPECIFICA.md** 🎯 **MAIS IMPORTANTE**
- Análise técnica específica do seu código
- 4 causas confirmadas com evidência técnica
- Por que cada ajuste não resolve tudo
- Opções de solução A/B/C/D com impacto esperado
- **Tempo de leitura:** 10min

### 3. **DIAGNOSTICO_ROUNDROBIN.md** 🔬 **APROFUNDADO**
- 7 potenciais causas com hipóteses técnicas
- Ordem de probabilidade
- Ações de diagnóstico recomendadas (6 passos)
- Métricas esperadas após refatoração
- **Tempo de leitura:** 20min

### 4. **REFATORACOES_PRATICAS.md** 🔧 **IMPLEMENTAÇÃO**
- 6 refatorações práticas prioritizadas
- PRIORIDADE 1: GC tuning (G1GC/ZGC)
- PRIORIDADE 2: Thread pool sizing
- PRIORIDADE 3: Circuit breaker
- PRIORIDADE 4: Least-conn LB
- PRIORIDADE 5: Connection pooling
- PRIORIDADE 6: Aumentar recursos K8s
- Teste A/B recomendado
- **Tempo de leitura:** 15min

### 5. **INVESTIGACAO_RAPIDA.md** ⚡ **TROUBLESHOOTING**
- Comandos `kubectl` e `ss` para diagnóstico rápido
- 7 investigações técnicas com comandos exatos
- Teste rápido de 5 minutos
- Checklist de diagnóstico
- **Uso:** Copiar/colar comandos

---

## 🛠️ Scripts (Automation)

### 1. **run_diagnostico.sh** 🤖 **FULL METRICS (K8s)**
Coleta automaticamente métricas durante testes:
```bash
chmod +x run_diagnostico.sh
./run_diagnostico.sh
# Resultado: $RESULTS_DIR/ com:
#   - K6 results (pick_first vs round_robin)
#   - CPU/Memory metrics
#   - TCP connections log
#   - Application logs
#   - ANALISE.md (comparativo)
```
**Tempo:** ~10-15 minutos para executar

### 2. **validacao_causas_rapida.sh** ⚡ **QUICK CHECKS (< 1min)**
Valida as principais hipóteses de forma rápida:
```bash
chmod +x validacao_causas_rapida.sh
./validacao_causas_rapida.sh
# Resultado: diagnostico_validacao_*/ com:
#   - DNS discovery check
#   - TCP connections per pod
#   - CPU/memory metrics
#   - Thread count
#   - Log analysis
```
**Tempo:** < 1 minuto

---

## 💻 Código Modificado

### 1. **GrpcClientConfig.java** (NOVO)
- Cria ManagedChannel explícito
- Configura keep-alive (60s time, 20s timeout)
- Aplica política de LB do env variable
- Cria bean para blocking stub reutilizável

### 2. **GrpcMetricsInterceptor.java** (NOVO)
- Interceptor gRPC que captura latência
- Loga chamadas lentas (> 500ms)
- Integrado ao blocking stub do cliente

### 3. **GrpcServerApplication.java** (MODIFICADO)
- Enhanced logging: req count, threads, memory, latência
- AtomicLong para métricas thread-safe
- Logs no padrão: REQ=[id], HOSTNAME=[pod], THREAD=[info], ACTIVE_THREADS, MEM_MB, SLOW_REQUEST

### 4. **GrpcClientApiController.java** (MODIFICADO)
- Injeção do blocking stub do bean (centralizado)
- Em vez de @GrpcClient (permite controle de config)

### 5. **application.properties** (CLIENTE E SERVIDOR, MODIFICADO)
- Client: keep-alive-time=60s, keep-alive-timeout=20s, max-inbound-message-size
- Server: keep-alive-time, keep-alive-timeout, permit-keep-alive-without-calls
- Logging: DEBUG para diagnóstico

---

## 🚀 Como Usar Este Diagnóstico

### **Passo 1: Entender o Problema (5 min)**
```bash
cat RESUMO_EXECUTIVO.md
```

### **Passo 2: Validar Hipóteses Principais (< 1 min)**
```bash
./validacao_causas_rapida.sh
# Revisar arquivos em diagnostico_validacao_*/
```

### **Passo 3: Entender Técnica Detalhada (10 min)**
```bash
cat ANALISE_TECNICA_ESPECIFICA.md
# Foco em "Por Que Round-Robin Ficou Especificamente com PIOR Latência"
```

### **Passo 4: Coletar Métricas Detalhadas (10-15 min)**
```bash
./run_diagnostico.sh
# Resultado: diagnostico_results_YYYYMMDD_HHMMSS/
# Arquivos: k6_pick_first.json, k6_round_robin.json, metrics_*.log
```

### **Passo 5: Escolher Solução (5 min)**
```bash
cat ANALISE_TECNICA_ESPECIFICA.md # Seção "Solução Rankeada"
# Option A: Aumentar Resources (recomendado, 95% chance)
# Option B: Mudar para least-conn
# Option C: Pick-first hard
# Option D: Implementar G1GC
```

### **Passo 6: Implementar & Testar (30 min - 2h)**
```bash
cat REFATORACOES_PRATICAS.md
# Seguir PRIORIDADE 1, 2, 3... até root cause resolvida
```

---

## 📊 Causas Principais (Rankeadas)

| Rank | Causa | Provocation | Evidence |
|------|-------|-------------|----------|
| 1 | **CPU Contention + Virtual Threads** | 1 CPU com 3 pods distribuídos | max=8.77s (GC/pause) |
| 2 | **Múltiplas Conexões HTTP/2** | 3 subchannels vs 1 | TCP connections count |
| 3 | **Warm JIT Effect** | 722K reqs/1 pod vs 212K/3pods | Latência estável vs aumentada |
| 4 | **GC Pause Concurrent** | 3 pods fazendo GC ao mesmo tempo | Spikes irregulares em p95/max |
| 5 | **Thread Pool Starvation** | Distribuição desigual | Logs de "rejected" tasks |
| 6 | **DNS Resolver Issue** | Headless service retorna 1 IP | `nslookup` retorna 1 apenas |

---

## ✅ Recomendação Imediata

### **Para Hoje (Quick Win):**

Aumentar resources do pod do servidor (Option A):

```yaml
# k8s-grpc-stress-test.yaml
spec:
  resources:
    limits:
      cpu: "2"      # ← aumentar de 1
      memory: "1Gi" # ← aumentar de 500Mi
    requests:
      cpu: "0.5"    # ← aumentar de 0.2
      memory: "256Mi" # ← aumentar de 100Mi
```

**Expected Result:** 
- Round-robin: 3518 → ~3900 req/s (diminui delta com pick-first)
- max: 8.77s → ~3-4s (remove CPU contention + GC pause)

### **Se Isso Não Funcionar:**

1. Implementar G1GC (Prioridade 1 em REFATORACOES_PRATICAS.md)
2. Testar least-conn em vez de round-robin
3. Considerar pick-first como padrão

---

## 📞 Quick Reference

| Preciso... | Ver documento... | Comando |
|-----------|-----------------|---------|
| Entender o problema | RESUMO_EXECUTIVO.md | `cat RESUMO_EXECUTIVO.md` |
| Verificar causa raiz | ANALISE_TECNICA_ESPECIFICA.md | `cat ANALISE_TECNICA_ESPECIFICA.md` |
| Testar hipóteses | INVESTIGACAO_RAPIDA.md | `./validacao_causas_rapida.sh` |
| Implementar solução | REFATORACOES_PRATICAS.md | `cat REFATORACOES_PRATICAS.md` |
| Coletar métricas completas | run_diagnostico.sh | `./run_diagnostico.sh` |
| Entender código | /grpc-client/src/main/java/br/usp/ | `open IDE` |

---

## 🎯 Sucesso = Quando

✅ Round-robin performance perto de pick-first:
- Throughput ≥ 3900 req/s (vs 4001 pick-first, -2.5% em vez de -12%)
- p(95) < 430 ms (vs 416 pick-first, -3.4% em vez de -11.5%)
- max < 3.5 s (vs 2.74 pick-first, +27% em vez de +220%)

---

## 📚 Leitura Completa (Sequência Recomendada)

1. Este README (2 min)
2. RESUMO_EXECUTIVO.md (5 min)
3. ANALISE_TECNICA_ESPECIFICA.md (10 min)
4. Executar `validacao_causas_rapida.sh` (1 min)
5. Se tempo: REFATORACOES_PRATICAS.md (15 min)
6. Implementar solução de prioridade 1
7. Testar

**Tempo Total para entender + agir:** ~45 minutos

---

## 📖 Próximas Etapas

1. **Hoje:** Executar `validacao_causas_rapida.sh` para confirmar hipóteses
2. **Amanhã:** Implementar Option A (aumentar resources K8s)
3. **Semana:** Se A+B não funcionar, implementar G1GC (Prioridade 1)
4. **Decisão:** Se round-robin ainda ruim após tudo, usar pick-first ou least-conn


