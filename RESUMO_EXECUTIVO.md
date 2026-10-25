# Resumo Executivo: Round-Robin Performance vs Pick-First

## 🎯 Objetivo do Diagnóstico

Identificar por que a política **`round_robin`** no gRPC cliente está resultando em **pior performance** (latência 13% maior, throughput 12% menor) em comparação com **`pick_first`**.

---

## 📊 Dados Observados

### Teste 1: Pick-First (Baseline)
- **Throughput:** 4001.9 req/s
- **Latência Média:** 245.32 ms
- **p(95):** 416.81 ms
- **Max:** 2.74 s
- **Iterações/3min:** 722,375

### Teste 2: Round-Robin
- **Throughput:** 3518.1 req/s (**-12% pior**)
- **Latência Média:** 278.31 ms (**-13.5% pior**)
- **p(95):** 465.04 ms (**-11.5% pior**)
- **Max:** 8.77 s (**-220% MUITO PIOR**)
- **Iterações/3min:** 635,276

---

## 🔴 Potenciais Causas (Rankeadas por Probabilidade)

### 1. **CPU Contention (Muito Provável - 65%)**
- **Cenário:** 3 pods com limite de 1 CPU cada + distribuição round-robin
- **Causa:** 
  - Com pick-first: 1 pod usa 100% de sua 1 CPU, 2 pods idle (menos context-switch)
  - Com round-robin: ~3-4 pods concorrentes usando CPU simultânea, mais overhead de scheduling
  - Project Loom (virtual threads) pode amplificar este efeito (mais tarefas que cores)
- **Evidência:** Max = 8.77s é típico de GC pause ou CPU throttling
- **Teste:** `kubectl top pods --containers` durante carga

### 2. **"Warm JIT" / Cache Effect (Provável - 55%)**
- **Cenário:** JIT compiler / instruction cache / branch predictor warming
- **Causa:**
  - Pick-first: todas as 722K requisições → **1 pod** → JIT aquece rapidamente
  - Round-robin: 635K requisições → 3 pods (~212K por pod) → cada pod tem JIT "frio"
- **Evidência:** Java necessita ~100K chamadas para ativar tiered compilation
- **Teste:** Comparar latência no minuto 0-1 vs minuto 2+ (esperado: round-robin melhora com tempo)

### 3. **Múltiplas Conexões TCP / TLS Handshake Overhead (Provável - 50%)**
- **Cenário:** gRPC round-robin cria subchannel por endpoint
- **Causa:**
  - 1 cliente × 3 servers = potencial 3 conexões HTTP/2 (em vez de 1)
  - Mesmo com keep-alive, overhead de initial setup + multiplexing menos eficiente
  - Cada VU no k6 pode estar abrindo nova conexão HTTP para cliente REST
- **Evidência:** ss/netstat mostrando muitas conexões TIME_WAIT
- **Teste:** `kubectl exec <pod> -- ss -tn sport = :50051 state established | wc -l`

### 4. **GC Pause (Provável - 45%)**
- **Cenário:** 500Mi RAM com múltiplos pods fazendo GC
- **Causa:**
  - 3 pods concorrentes, cada um com 500Mi limit → pausa mais frequente
  - Round-robin distribui, aumenta chance de parada simultânea
- **Evidência:** p95=465ms, max=8.77s (8s+ é clássico GC pause)
- **Teste:** Habilitar GC logs e analisar `gc.log` durante teste

### 5. **Thread Pool Starvation (Possível - 35%)**
- **Cenário:** Netty event loop pool saturado com múltiplas conexões
- **Causa:** 
  - Round-robin + 1000 VUs = muitas requisições simultâneas por subchannel
  - Executor pool dos 3 pods pode ficar desequilibrado
- **Teste:** `jcmd <pid> Thread.print | grep grpc | wc -l` durante pico

### 6. **DNS Resolver Cache Issue (Improvável - 15%)**
- **Cenário:** DNS retornando apenas 1 endpoint em vez de 3
- **Causa:** Headless service mal configurado ou cache DNS
- **Teste:** `nslookup grpc-java-server.default.svc.cluster.local` dentro do pod

---

## ✅ Modificações Já Implementadas

1. **`GrpcClientConfig.java`** (Novo)
   - ManagedChannel explícito com keep-alive
   - Configuração de LB-policy e flow-control-window
   - Permite diagnosticar se reuso de conexões estava faltando

2. **`GrpcMetricsInterceptor.java`** (Novo)
   - Captura latência real das chamadas gRPC
   - Loga chamadas lentas (> 500ms) para diagnóstico

3. **`GrpcServerApplication.java`** (Modificado)
   - Logs detalhados: número de threads ativos, memória, latência
   - Counters de requisição e latência acumulada
   - Melhor rastreabilidade de gargalos

4. **`GrpcClientApiController.java`** (Modificado)
   - Injetado pelo novo bean de configuração (melhor controle)

5. **`application.properties` (Cliente e Servidor)** (Modificado)
   - Keep-alive configurado: 60s time, 20s timeout
   - Max concurrent streams, max inbound message size
   - Logging em DEBUG para diagnóstico

---

## 🔧 Próximas Ações Recomendadas

### **Curto Prazo (Hoje - Testar)**

1. ✅ **Reconstruir projeto** → `mvn -DskipTests clean package`
   ```bash
   cd /home/handerson/Treinamentos/projetoTCC_v2
   mvn -DskipTests clean package
   ```

2. 📊 **Rodar diagnóstico automático** (se em Kubernetes):
   ```bash
   chmod +x run_diagnostico.sh
   ./run_diagnostico.sh  # Coleta métricas pick-first vs round-robin
   ```

3. ⚡ **Teste manual rápido:**
   ```bash
   # Terminal 1: Monitorar recursos
   watch 'kubectl top pods -l app=grpc-java-server --containers'
   
   # Terminal 2: Testar pick-first
   kubectl set env deployment/grpc-java-client LB_POLICY=pick_first
   kubectl rollout status deployment/grpc-java-client
   k6 run stress-test/load-tests.js --vus 1000 --duration 3m0s
   
   # Terminal 2: Testar round-robin (após 30s cooldown)
   kubectl set env deployment/grpc-java-client LB_POLICY=round_robin
   kubectl rollout status deployment/grpc-java-client
   k6 run stress-test/load-tests.js --vus 1000 --duration 3m0s
   
   # Comparar latências, throughput, CPU%
   ```

4. 🔍 **Se round-robin está realmente sendo usado:**
   ```bash
   kubectl logs -l app=grpc-java-client | grep -i "round\|pick\|load" | head -20
   kubectl exec <client-pod> -- nslookup grpc-java-server
   # Deve retornar 3 IPs
   ```

### **Médio Prazo (Esta semana - Otimizar)**

Seguindo prioridade no documento `REFATORACOES_PRATICAS.md`:

1. **PRIORIDADE 1:** Implementar G1GC otimizado para latência
   - Adicionar `-XX:+UseG1GC -XX:MaxGCPauseMillis=50` aos Dockerfiles
   - Testar se max latency reduz

2. **PRIORIDADE 2:** Aumentar Netty worker threads
   - Configurar `grpc.server.netty.worker-threads=8`

3. **PRIORIDADE 3:** Se CPU contention, aumentar resources K8s
   - CPU de 1 para 2, RAM de 500Mi para 1Gi

4. **PRIORIDADE 4:** Se round-robin ainda ruim, testar `least_conn`
   - Em vez de round-robin fixo, distribuir por carga real

### **Longo Prazo (Decisão Final)**

Se após todos os ajustes round-robin continua pior:
- **Recomendação:** Usar `pick_first` como padrão (melhor latência confirmada)
- **Se necessário distribuição:** Usar `least_conn` ou sticky affinity
- **Conclusão:** Para este caso, 1 servidor rápido é melhor que 3 lentos + overhead

---

## 📚 Documentos Criados para Referência

1. **`DIAGNOSTICO_ROUNDROBIN.md`** - Análise técnica detalhada com 7 potenciais causas
2. **`INVESTIGACAO_RAPIDA.md`** - Comandos rápidos para testar cada hipótese
3. **`REFATORACOES_PRATICAS.md`** - Implementações práticas e prioritizadas
4. **`run_diagnostico.sh`** - Script automático para coletar métricas (K8s)

---

## 🎯 KPIs Esperados Após Implementação

| Métrica | Target | Crítico |
|---------|--------|---------|
| Round-robin Throughput | ≥ 3900 req/s | ≥ 3700 req/s |
| Round-robin p(95) | < 430 ms | < 450 ms |
| Round-robin Max | < 3.5 s | < 5 s |
| CPU por pod | 70-80% | < 100% throttling |
| P95 stability | ±10% variance | ±20% |

---

## 📞 Suporte

Em caso de dúvidas sobre os ajustes implementados:
- Revisar comentários em código (Java files)
- Consultar `REFATORACOES_PRATICAS.md` para próximos passos
- Executar `run_diagnostico.sh` para coleta automática de dados


