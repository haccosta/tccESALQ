# Teste Local: Round-Robin vs Pick-First (Sem Kubernetes)

Se você está testando **localmente** (não em Kubernetes), use este guia para replicar o diagnóstico.

---

## 🎯 Cenário Local

```
Cliente REST (localhost:8080)
  ↓ gRPC
  ├─ Server 1 (localhost:50051)
  ├─ Server 2 (localhost:50052)  
  └─ Server 3 (localhost:50053)
```

---

## 📋 Pré-requisitos

- Java 21+ com Maven
- k6 instalado
- 3 terminais disponíveis

---

## 🚀 Teste A: Pick-First (Baseline)

### Terminal 1: Inicia 3 Servidores em Ports Diferentes

```bash
# Server 1
export GRPC_SERVER_PORT=50051
export HOSTNAME=server-1
cd grpc-server
mvn -DskipTests spring-boot:run

# (Em outro terminal)
# Server 2
export GRPC_SERVER_PORT=50052
export HOSTNAME=server-2
cd grpc-server
mvn -DskipTests spring-boot:run

# (Em outro terminal)
# Server 3
export GRPC_SERVER_PORT=50053
export HOSTNAME=server-3
cd grpc-server
mvn -DskipTests spring-boot:run
```

### Terminal 4: Inicia Cliente com Pick-First

```bash
export GRPC_CLIENT_MEU_SERVICO_GRPC_ADDRESS="dns:///127.0.0.1:50051,127.0.0.1:50052,127.0.0.1:50053"
export LB_POLICY=pick_first
cd grpc-client
mvn -DskipTests spring-boot:run
```

### Terminal 5: Executa k6 Test

```bash
# Aguardar 10s para cliente estabilizar
sleep 10

# Rodar teste
k6 run stress-test/load-tests.js --duration 3m --vus 1000 > results_pick_first.txt

# Anotar resultados:
# - Throughput
# - p(95)
# - max
grep "http_reqs\|http_req_duration\|max=" results_pick_first.txt
```

**Esperado:**
- Throughput: ~4000 req/s
- p(95): ~420 ms
- max: ~2.7 s

---

##🚀 Teste B: Round-Robin

### Parar Tudo E Reiniciar

```bash
# Matar todos os processos Java
killall java

# Aguardar 5s
sleep 5
```

### Terminal 1-3: Recomeçar 3 Servidores (mesma forma)

```bash
# Server 1 (port 50051)
export GRPC_SERVER_PORT=50051
export HOSTNAME=server-1
mvn -DskipTests spring-boot:run

# Server 2 (port 50052)
export GRPC_SERVER_PORT=50052
export HOSTNAME=server-2
mvn -DskipTests spring-boot:run

# Server 3 (port 50053)
export GRPC_SERVER_PORT=50053
export HOSTNAME=server-3
mvn -DskipTests spring-boot:run
```

### Terminal 4: Inicia Cliente com Round-Robin

```bash
export GRPC_CLIENT_MEU_SERVICO_GRPC_ADDRESS="dns:///127.0.0.1:50051,127.0.0.1:50052,127.0.0.1:50053"
export LB_POLICY=round_robin  # ← MUDANÇA
cd grpc-client
mvn -DskipTests spring-boot:run
```

### Terminal 5: Executa k6 Test

```bash
sleep 10
k6 run stress-test/load-tests.js --duration 3m --vus 1000 > results_round_robin.txt
grep "http_reqs\|http_req_duration\|max=" results_round_robin.txt
```

**Esperado (reproduzindo seu resultado):**
- Throughput: ~3518 req/s (-12%)
- p(95): ~465 ms (-11%)
- max: ~8.7 s (-220%)

---

## 📊 Comparação

```bash
echo "=== PICK_FIRST ==="
grep "http_reqs\|http_req_duration\|max=" results_pick_first.txt

echo ""
echo "=== ROUND_ROBIN ==="
grep "http_reqs\|http_req_duration\|max=" results_round_robin.txt
```

---

## 🔍 Diagnóstico Local

### 1. Ver Logs de Qual Server Recebe Requisições

**Pick-first:**
```bash
# Terminal de server-1 deve ter todos os logs
# Terminal de server-2 e server-3 devem estar silenciosos

# Verificar:
grep "REQ=" <(tail -f grpc-server.log)  # server-1 deve ter muitos
```

**Round-robin:**
```bash
# Terminal de server-1, server-2, server-3 devem ter distribuição

# Verificar:
for i in 1 2 3; do
  echo "=== Server $i ===" 
  grep -c "REQ=" grpc-server_$i.log
done
# Esperado: ~212K cada (total 635K / 3)
```

### 2. Contar Conexões (netstat local)

```bash
# Durante o teste, em outro terminal:

# Pick-first: 1 conexão ESTABLISHED para port 50051
netstat -an | grep 50051 | grep ESTABLISHED | wc -l
# Esperado: 1

# Round-robin: múltiplas para 50051,50052,50053
netstat -an | grep -E "50051|50052|50053" | grep ESTABLISHED | wc -l
# Esperado: 3+
```

### 3. Monitorar CPU Localmente

```bash
# Terminal separado, durante teste
top -p $(pgrep -f "grpc-server|grpc-client") -n 1 -b

# Ou, mais detalhado
while true; do
  echo "=== $(date) ==="
  ps aux | grep "[g]rpc-server\|[g]rpc-client" | awk '{print $3 "% CPU - " $11}'
  sleep 5
done
```

**Pick-first:**
- 1 server ~100% CPU
- 2 servers ~0% CPU

**Round-robin:**
- 3 servers ~30-40% CPU cada (mais contexto-switch overhead)

---

## 🧩 Verificar DNS Local

Se usando `dns:///` local, verificar resolução:

```bash
# Dentro do cliente (Java process):
nslookup 127.0.0.1:50051,127.0.0.1:50052,127.0.0.1:50053  # May not work locally

# Alternativa: Log o que o cliente está descobrindo
# Adicionar ao código: System.out.println("Discoveredendpoints:")
```

Ou, simpler, ver logs do cliente:

```bash
# Procurar por logs de découvert
grep -i "endpoint\|discover\|address" <(tail -f grpc-client.log)
```

---

## 📝 Resumo do Teste Local

| Métrica | Pick-First | Round-Robin | Delta |
|---------|-----------|------------|-------|
| Throughput | ~4000 | ~3500 | -12.5% |
| p(95) | ~420 ms | ~465 ms | -10.7% |
| Max | ~2.7 s | ~8.7 s | +222% |
| CPU distribution | 1 server 100% | 3 servers ~33% | Mais overhead |
| Logs distribution | Server 1 only | 3~servers mixed | Verificável |

---

## 🎯 Se Reproduzir Localmente

Se conseguir reproduzir o padrão localmente (pick-first melhor), confirma:
1. **Não é problema de Kubernetes**
2. **Problema é na lógica/configuração gRPC**
3. **Causas mais prováveis: CPU contention + JIT warming + múltiplas conexões**

---

## 🚀 Próximas Ações (Local)

Depois de reproduzir:

1. **Implementar G1GC:**
   ```bash
   export JAVA_OPTS="-XX:+UseG1GC -XX:MaxGCPauseMillis=50"
   # Reiniciar servidores e testar
   k6 run stress-test/load-tests.js --vus 1000 --duration 3m > results_roundrobin_g1gc.txt
   ```

2. **Mudar para least-conn:**
   ```bash
   export LB_POLICY=least_conn
   # Reiniciar cliente e testar
   ```

3. **Aumentar CPU (simular 2 CPUs):**
   ```bash
   export JAVA_OPTS="-XX:+UseG1GC -Xms512m -Xmx512m"
   # Reiniciar e testar
   ```


