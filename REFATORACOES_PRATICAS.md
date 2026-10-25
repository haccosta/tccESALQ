# Refatorações Práticas para Melhorar Round-Robin Performance

## 📋 Status Atual

✅ **Já Implementado:**
1. `GrpcClientConfig.java` - ManagedChannel explicit + keep-alive + LB-policy aware
2. `GrpcMetricsInterceptor.java` - Instrumentação de latência
3. Server enhanced logging - Métricas de thread count, memory, latência
4. Application.properties otimizado - Keep-alive no cliente e servidor

---

## 🔧 Refatorações Adicionais Recomendadas (Por Prioridade)

### PRIORIDADE 1: Limit Memory Churn / Reduce GC Pauses ✨

**Problema:** Limitados em 500Mi, com 3 pods concorrentes + round-robin, pode haver GC pause elevado.

**Refatoração:**

#### A. Configurar GC Padrão para Baixa Latência (cliente + servidor)

Adicionar ao Dockerfile-server e Dockerfile-client:

```dockerfile
ENV GC_OPTS="-XX:+UseG1GC \
  -XX:MaxGCPauseMillis=50 \
  -XX:G1HeapRegionSize=16m \
  -XX:InitiatingHeapOccupancyPercent=35"

ENV JAVA_OPTS="${GC_OPTS} -XX:+PrintCMSStatistics -Xms256m -Xmx400m"
```

**Por que:** G1GC com pause target de 50ms reduz spikes de latência. -Xms256m evita resizing.

---

#### B. Habilitar ZGC (Java 15+) em vez de G1GC

```dockerfile
# Se projeto suporta Java 17+:
ENV GC_OPTS="-XX:+UseZGC -XX:+ZGenerational"
ENV JAVA_OPTS="${GC_OPTS} -Xms256m -Xmx400m"
```

**Por que:** ZGC tem pausas <10ms, ideal para latência baixa.

---

### PRIORIDADE 2: Otimizar Thread Pool / Executor Sizing 🧵

**Problema:** Virtual threads ajudam, mas Netty event-loop pool pode ser um gargalo com round-robin + distribuição.

**Refatoração:**

Criar um bean `GrpcServerNettyConfig.java` (novo arquivo server):

```java
package br.usp.projetotcc.server;

import io.grpc.netty.shaded.io.grpc.netty.NettyServerBuilder;
import io.grpc.netty.shaded.io.netty.channel.nio.NioEventLoopGroup;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

@Configuration
public class GrpcServerNettyConfig {

    /**
     * Configurar thread pools do Netty com mais workers para lidar com múltiplas conexões
     * quando round-robin está ativo.
     */
    @Bean
    public NettyServerBuilder nettyServerBuilderCustomizer() {
        int cores = Runtime.getRuntime().availableProcessors();
        
        // Event loops para I/O (sockets)
        NioEventLoopGroup bossGroup = new NioEventLoopGroup(1);  // Aceita conexões
        NioEventLoopGroup workerGroup = new NioEventLoopGroup(cores * 2); // I/O
        
        return NettyServerBuilder.forPort(50051)
                .bossEventLoopGroup(bossGroup)
                .workerEventLoopGroup(workerGroup);
    }
}
```

**Ou**, via properties (mais simples):

```properties
# grpc-server application.properties
grpc.server.netty.boss-threads=1
grpc.server.netty.worker-threads=8  # increase from default=1
```

---

### PRIORIDADE 3: Adicionar Circuit Breaker / Failover 🔄

**Problema:** Se um backend fica lento, round-robin continua mandando tráfego lá.

**Refatoração:**

Adicionar biblioteca ao `pom.xml`:

```xml
<dependency>
    <groupId>io.github.resilience4j</groupId>
    <artifactId>resilience4j-grpc</artifactId>
    <version>2.1.0</version>
</dependency>
```

Criar interceptor com circuit breaker:

```java
package br.usp.projetotcc.client;

import io.github.resilience4j.circuitbreaker.CircuitBreaker;
import io.github.resilience4j.circuitbreaker.CircuitBreakerConfig;
import io.github.resilience4j.circuitbreaker.CircuitBreakerRegistry;
import io.grpc.*;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

import java.time.Duration;

@Configuration
public class GrpcCircuitBreakerConfig {

    @Bean
    public CircuitBreakerRegistry circuitBreakerRegistry() {
        CircuitBreakerConfig config = CircuitBreakerConfig.custom()
                .failureRateThreshold(50.0f)  // Abrir após 50% falhas
                .slowCallRateThreshold(50.0f) // Abrir se 50% das chamadas forem lentas
                .slowCallDurationThreshold(Duration.ofMillis(500))
                .waitDurationInOpenState(Duration.ofSeconds(10))
                .permittedNumberOfCallsInHalfOpenState(3)
                .minimumNumberOfCalls(10)
                .build();

        return CircuitBreakerRegistry.of(config);
    }
}
```

**Benefício:** Isola backends lentos, evita cascata de timeouts.

---

### PRIORIDADE 4: Adicionar Load Balancer com Least-Connections 🎯

**Problema:** Round-robin distribui igualmente; se backends forem diferentes, ideal usar least-connections.

**Refatoração (via properties):**

```properties
# grpc-client application.properties
grpc.client.meu-servico-grpc.default-load-balancing-policy=least_conn
```

**Ou, se quiser customizado, criar bean:**

```java
// Em GrpcClientConfig.java
builder.defaultLoadBalancingPolicy("least_conn") // em vez de "round_robin"
```

**Benefício:** Distribui com base em número de conexões ativas, não round-robin fixo.

---

### PRIORIDADE 5: Connection Pooling Explícito / Channel Reuse ♻️

**Problema:** Mesmo com singleton channel, Java/gRPC pode estar criando novos canais em alguns casos.

**Refatoração:**

Adicionar validação ao `GrpcClientConfig`:

```java
@Configuration
public class GrpcClientConfig {

    // ... código anterior ...

    @Bean(destroyMethod = "shutdown")
    public ManagedChannel grpcManagedChannel() {
        // ... código ...
        
        NettyChannelBuilder builder = NettyChannelBuilder.forTarget(target)
                .usePlaintext()
                .defaultLoadBalancingPolicy(lbPolicy)
                .keepAliveTime(60, TimeUnit.SECONDS)
                .keepAliveTimeout(20, TimeUnit.SECONDS)
                .keepAliveWithoutCalls(true)
                .flowControlWindow(1 << 20)
                // ↓ NOVO: Garantir que não cria canais adicionais
                .directExecutor()  // Usar executor direto (menos overhead)
                .maxRetryAttempts(3)  // Retry automático
                .retryBufferSize(100 * 1024 * 1024);  // 100MB retry buffer
        
        return builder.build();
    }
}
```

---

### PRIORIDADE 6: Aumentar Resources no Kubernetes ↗️

Se nenhuma das refatorações funcionar, aumentar recursos K8s:

```yaml
# k8s-grpc-stress-test.yaml
spec:
  resources:
    limits:
      cpu: "2"          # ← aumentar de 1
      memory: "1Gi"     # ← aumentar de 500Mi
    requests:
      cpu: "0.5"        # ← aumentar de 0.2
      memory: "256Mi"   # ← aumentar de 100Mi
```

**Benefício:** Menos CPU throttling, mais espaço para JIT, GC, thread scheduling.

---

## ✅ Checklist de Implementação

- [ ] Implementar G1GC ou ZGC (PRIORIDADE 1)
- [ ] Configurar Netty thread pools (PRIORIDADE 2)
- [ ] Testar semapalternante entre pick-first e round-robin com nova GC
- [ ] Se ainda pior, adicionar Circuit Breaker (PRIORIDADE 3)
- [ ] Se ainda pior, tentar least_conn em vez de round-robin (PRIORIDADE 4)
- [ ] Se CPU saturado, aumentar resources K8s (PRIORIDADE 6)

---

## 🧪 Teste A/B Recomendado

```bash
# Baseline: sem alterações, round-robin
k6 run stress-test/load-tests.js --duration 3m1000 > baseline_rr.json

# Teste 1: Com G1GC otimizado
kubectl set env deployment/grpc-java-server JAVA_OPTS="-XX:+UseG1GC -XX:MaxGCPauseMillis=50 ..."
k6 run stress-test/load-tests.js --duration 3m --vus 1000 > test1_g1gc_rr.json

# Teste 2: Com least_conn
kubectl set env deployment/grpc-java-client LB_POLICY=least_conn
k6 run stress-test/load-tests.js --duration 3m --vus 1NFORTH > test2_leastconn_rr.json

# Teste 3: Com recursos aumentados
kubectl patch deployment grpc-java-server -p '{"spec":{"template":{"spec":{"containers":[{"name":"grpc-java-server","resources":{"limits":{"cpu":"2","memory":"1Gi"}}}]}}}}'
k6 run stress-test/load-tests.js --duration 3m --vus 1000 > test3_more_resources_rr.json

# Comparar:
diff baseline_rr.json test1_g1gc_rr.json
diff baseline_rr.json test2_leastconn_rr.json
diff baseline_rr.json test3_more_resources_rr.json
```

---

## 📊 Métricas Esperadas Após Refatorações

| Métrica | Pick-First | Round-Robin (original) | Round-Robin (refatorado) | Meta |
|---------|-----------|----------------------|-------------------------|------|
| Throughput | 4001 req/s | 3518 req/s (-12%) | **3800+ req/s** | 90%+ pick-first |
| Latência Média | 245 ms | 278 ms (-13%) | **250-260 ms** | Próximo a pick-first |
| p(95) | 416 ms | 465 ms (-11%) | **420-430 ms** | < 450 ms |
| Max | 2.74 s | 8.77 s (-220%) | **< 3.5 s** | Reduzir spikes |

---

## 🎯 Se Round-Robin Não Melhorar Mesmo Após Tudo

**Conclusão:** Round-robin pode não ser apropriado para este caso.

**Recomendação:**
1. Usar pick-first como padrão (melhor latência)
2. Se precisar de distribuição, usar **least_conn** em vez de round-robin
3. Ou implementar sticky-affinity (hash IP cliente)
4. Ou considerar que uma única instância rápida é melhor que múltiplas lentas + overhead de distribuição


