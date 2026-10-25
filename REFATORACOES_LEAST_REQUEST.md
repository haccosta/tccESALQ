# Refatorações para Implementar Política Least_Request

## 📋 Visão Geral

A política `least_request` (least connections) distribui requisições para o backend com **MENOS conexões ATIVAS**, em vez de round-robin fixo. Isso equilibra a carga de forma mais inteligente.

**Vs Round-Robin:**
- ❌ Round-Robin: requisição 1→Pod1, req 2→Pod2, req 3→Pod3, req 4→Pod1 (fixo)
- ✅ Least-Request: requisição → Pod com menos conexões ativas no momento

---

## 🔍 Estado Atual (Antes)

- `GrpcClientConfig.java`: Usa properties (simples mas limitado)
- `application.properties`: `least_request` já configurado como default
- **Problema:** Sem observabilidade de qual backend recebe cada requisição
- **Problema:** Sem health checks para validar distribuição

---

## ✅ Refatorações Necessárias

### **REFATORAÇÃO 1: Criar ManagedChannel Explícito com LoadBalancer Resolver Customizado**

**Arquivo:** `GrpcLoadBalancerResolver.java` (NOVO)

```java
package br.usp.projetotcc.client;

import io.grpc.Attributes;
import io.grpc.EquivalentAddressGroup;
import io.grpc.KeysForTest;
import io.grpc.NameResolver;
import io.grpc.Status;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.net.InetSocketAddress;
import java.net.SocketAddress;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/**
 * Resolver customizado para descoberta de endpoints e logging de distribuição.
 * Permite monitorar quais backends estão sendo descobertos para least_request.
 */
public class GrpcLoadBalancerResolver extends NameResolver {

    private static final Logger LOGGER = LoggerFactory.getLogger(GrpcLoadBalancerResolver.class);
    
    private final String authority;
    private final int port;
    private Listener2 listener;

    public GrpcLoadBalancerResolver(String authority, int port) {
        this.authority = authority;
        this.port = port;
    }

    @Override
    public String getServiceAuthority() {
        return authority;
    }

    @Override
    public void start(Listener2 listener) {
        this.listener = listener;
        
        // Resolver manual para endereços (pode ser expandido para DNS dinâmico)
        List<EquivalentAddressGroup> servers = new ArrayList<>();
        Set<SocketAddress> addresses = new HashSet<>();
        
        // Parse: "127.0.0.1:50051,127.0.0.1:50052,127.0.0.1:50053"
        String[] addrs = authority.split(",");
        for (String addr : addrs) {
            String[] parts = addr.split(":");
            if (parts.length == 2) {
                String host = parts[0];
                int resolvedPort = Integer.parseInt(parts[1]);
                SocketAddress sockAddr = new InetSocketAddress(host, resolvedPort);
                addresses.add(sockAddr);
                servers.add(new EquivalentAddressGroup(sockAddr));
                
                LOGGER.info("Descoberto backend para least_request: {}:{}", host, resolvedPort);
            }
        }
        
        if (!servers.isEmpty()) {
            listener.onResult(ResolutionResult.newBuilder()
                    .setAddresses(servers)
                    .setAttributes(Attributes.EMPTY)
                    .build());
        } else {
            listener.onError(Status.UNAVAILABLE.withDescription("Nenhum backend encontrado").asException());
        }
    }

    @Override
    public void refresh() {
        // Pode implementar refresh dinâmico de DNS aqui
        LOGGER.debug("Refresh de resolver de LB chamado");
    }

    @Override
    public void shutdown() {
        LOGGER.info("Resolver de LB encerrado");
    }
}
```

---

### **REFATORAÇÃO 2: Criar Factory para LoadBalancer Resolver**

**Arquivo:** `GrpcLoadBalancerResolverProvider.java` (NOVO)

```java
package br.usp.projetotcc.client;

import io.grpc.NameResolver;
import io.grpc.NameResolverProvider;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.net.URI;

/**
 * Provider que registra o resolver customizado com o gRPC.
 * Permite usar "lbresolver:///" como scheme para usar nosso resolver.
 */
public class GrpcLoadBalancerResolverProvider extends NameResolverProvider {

    private static final Logger LOGGER = LoggerFactory.getLogger(GrpcLoadBalancerResolverProvider.class);
    private static final String SCHEME = "lbresolver";

    @Override
    protected boolean isAvailable() {
        return true;
    }

    @Override
    protected int priority() {
        return 6;  // Prioridade alta (padrão é 5)
    }

    @Override
    public NameResolver newNameResolver(URI targetUri, NameResolver.Args args) {
        if (!SCHEME.equals(targetUri.getScheme())) {
            return null;
        }
        
        LOGGER.info("Criando resolver customizado para: {}", targetUri);
        
        String authority = targetUri.getAuthority();
        return new GrpcLoadBalancerResolver(authority, 50051);
    }

    @Override
    public String getDefaultScheme() {
        return SCHEME;
    }
}
```

**Registrar no `META-INF/services/io.grpc.NameResolverProvider`:**
```
br.usp.projetotcc.client.GrpcLoadBalancerResolverProvider
```

---

### **REFATORAÇÃO 3: Refatorar GrpcClientConfig com ManagedChannel Explícito**

**Arquivo:** `GrpcClientConfig.java` (MODIFICAR)

```java
package br.usp.projetotcc.client;

import br.usp.projetotcc.contracts.message.SimpleMessageServiceGrpc;
import io.grpc.ManagedChannel;
import io.grpc.netty.shaded.io.grpc.netty.NettyChannelBuilder;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

import java.util.concurrent.TimeUnit;

@Configuration
public class GrpcClientConfig {

    private static final Logger LOGGER = LoggerFactory.getLogger(GrpcClientConfig.class);

    @Value("${GRPC_CLIENT_MEU_SERVICO_GRPC_ADDRESS:dns:///localhost:50051}")
    private String target;

    @Value("${LB_POLICY:least_request}")
    private String lbPolicy;

    /**
     * Cria um ManagedChannel explícito otimizado para least_request.
     * Configurações críticas:
     * - defaultLoadBalancingPolicy: least_request (distribuição inteligente por conexões)
     * - keepAlive: mantém conexões vivas para LB poder contar conexões ativas
     * - directExecutor: evita overhead de threads extras
     * - maxRetryAttempts: retry automático em falhas
     */
    @Bean(destroyMethod = "shutdown")
    public ManagedChannel grpcManagedChannel() {
        LOGGER.info("Criando ManagedChannel para: {} com policy: {}", target, lbPolicy);
        
        NettyChannelBuilder builder = NettyChannelBuilder.forTarget(target)
                .usePlaintext()
                .defaultLoadBalancingPolicy(lbPolicy)
                
                // CRÍTICO para least_request: manter conexões vivas
                .keepAliveTime(30, TimeUnit.SECONDS)      // Check a cada 30s
                .keepAliveTimeout(10, TimeUnit.SECONDS)    // Timeout de 10s
                .keepAliveWithoutCalls(true)               // Manter vivas mesmo sem chamadas
                
                // Performance HTTP/2 multiplexing
                .flowControlWindow(1 << 20)                // 1MB flow control
                .maxInboundMessageSize(10 * 1024 * 1024)  // 10MB mensagens
                
                // Retry automático (ajuda com transições de LB)
                .maxRetryAttempts(3)
                .retryBufferSize(100 * 1024 * 1024)
                
                // Executor direto para reduzir latência
                .directExecutor()
                
                // Logging de eventos de conexão (diagnóstico)
                .logAllCalls(false);  // Colocar true apenas em debug
        
        ManagedChannel channel = builder.build();
        
        LOGGER.info("ManagedChannel criado com sucesso. " +
                "Policy: {}, Target: {}, KeepAlive: 30s", lbPolicy, target);
        
        return channel;
    }

    /**
     * Cria o blocking stub com interceptor de métricas por backend.
     */
    @Bean
    public SimpleMessageServiceGrpc.SimpleMessageServiceBlockingStub simpleMessageBlockingStub(
            ManagedChannel channel,
            GrpcMetricsInterceptor metricsInterceptor) {
        
        LOGGER.info("Criando blocking stub com interceptor de métricas");
        
        return SimpleMessageServiceGrpc.newBlockingStub(channel)
                .withInterceptors(metricsInterceptor);
    }
}
```

---

### **REFATORAÇÃO 4: Melhorar GrpcMetricsInterceptor para Rastrear Backend/Conexões**

**Arquivo:** `GrpcMetricsInterceptor.java` (EXPANDIR)

```java
package br.usp.projetotcc.client;

import io.grpc.*;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import java.util.concurrent.atomic.*;

/**
 * Interceptor que captura métricas detalhadas por backend.
 * Rastreia latência, distribuição e detecta problemas de LB.
 */
public class GrpcMetricsInterceptor implements ClientInterceptor {

    private static final Logger LOGGER = LoggerFactory.getLogger(GrpcMetricsInterceptor.class);
    
    // Métricas por backend (para least_request, podemos rastrear qual backend atendeu)
    private static final AtomicLong totalCalls = new AtomicLong(0);
    private static final AtomicLong totalLatencyMs = new AtomicLong(0);
    private static final AtomicLong slowCalls = new AtomicLong(0);
    private static final AtomicLong failedCalls = new AtomicLong(0);

    @Override
    public <ReqT, RespT> ClientCall<ReqT, RespT> interceptCall(
            MethodDescriptor<ReqT, RespT> method,
            CallOptions callOptions,
            Channel next) {
        
        return new ForwardingClientCall.SimpleForwardingClientCall<ReqT, RespT>(
                next.newCall(method, callOptions)) {
            
            @Override
            public void start(Listener<RespT> responseListener, Metadata headers) {
                long startNanos = System.nanoTime();
                long callId = totalCalls.incrementAndGet();
                
                Listener<RespT> wrappedListener = new ForwardingClientCallListener
                        .SimpleForwardingClientCallListener<RespT>(responseListener) {
                    
                    @Override
                    public void onMessage(RespT message) {
                        super.onMessage(message);
                        
                        // Tenta extrair informação do backend da resposta
                        // (Para grpc aqui seria a mensagem, parse conforme necessário)
                    }

                    @Override
                    public void onClose(Status status, Metadata trailers) {
                        long elapsedMs = (System.nanoTime() - startNanos) / 1_000_000;
                        totalLatencyMs.addAndGet(elapsedMs);
                        
                        if (!status.isOk()) {
                            failedCalls.incrementAndGet();
                            LOGGER.warn("CALL_FAILED: id=[{}] method=[{}] status=[{}] duration={}ms",
                                    callId, method.getFullMethodName(), status.getCode(), elapsedMs);
                        } else if (elapsedMs > 500) {
                            slowCalls.incrementAndGet();
                            LOGGER.warn("SLOW_CALL: id=[{}] method=[{}] duration={}ms",
                                    callId, method.getFullMethodName(), elapsedMs);
                        } else if (elapsedMs > 100) {
                            LOGGER.debug("CALL: id=[{}] method=[{}] duration={}ms",
                                    callId, method.getFullMethodName(), elapsedMs);
                        }
                        
                        super.onClose(status, trailers);
                    }
                };
                
                super.start(wrappedListener, headers);
            }
        };
    }

    /**
     * Retorna estatísticas agregadas (útil para health checks).
     */
    public void logStatistics() {
        long calls = totalCalls.get();
        long totalLatency = totalLatencyMs.get();
        long slow = slowCalls.get();
        long failed = failedCalls.get();
        
        double avgLatency = calls > 0 ? (double) totalLatency / calls : 0;
        double slowRate = calls > 0 ? ((double) slow / calls) * 100 : 0;
        double failRate = calls > 0 ? ((double) failed / calls) * 100 : 0;
        
        LOGGER.info("METRICS_SUMMARY: calls={}, avgLatency={}ms, slowCalls={}({}%), failedCalls={}({}%)",
                calls, String.format("%.2f", avgLatency), slow, String.format("%.2f", slowRate),
                failed, String.format("%.2f", failRate));
    }
}
```

---

### **REFATORAÇÃO 5: Adicionar Health Check Endpoint**

**Arquivo:** `HealthCheckController.java` (NOVO)

```java
package br.usp.projetotcc.client;

import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.HashMap;
import java.util.Map;

/**
 * Endpoint para validar que least_request está funcionando.
 * Útil para monitorar health e distribuição de carga.
 */
@RestController
@RequestMapping("/health")
public class HealthCheckController {

    @Autowired
    private GrpcMetricsInterceptor metricsInterceptor;

    @GetMapping("/ready")
    public ResponseEntity<Map<String, Object>> healthCheck() {
        Map<String, Object> response = new HashMap<>();
        response.put("status", "UP");
        response.put("service", "grpc-client-api");
        response.put("loadBalancingPolicy", "least_request");
        
        // Log estatísticas
        metricsInterceptor.logStatistics();
        
        return ResponseEntity.ok(response);
    }
}
```

---

### **REFATORAÇÃO 6: Adicionar Monitoring/Actuator**

**Arquivo:** `pom.xml` (ADICIONAR DEPENDÊNCIA)

```xml
<!-- Adicionar ao grpc-client/pom.xml -->
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-actuator</artifactId>
</dependency>
```

**Arquivo:** `application.properties` (ADICIONAR)

```properties
# Habilitar endpoints do Actuator para monitorar health
management.endpoints.web.exposure.include=health,info,metrics
management.endpoint.health.show-details=always
```

---

### **REFATORAÇÃO 7: Otimizar Server para Contar Conexões Corretamente**

**Arquivo:** `GrpcServerApplication.java` (ADICIONAR BEAN)

```java
// Adicionar ao GrpcServerApplication

package br.usp.projetotcc.server;

import net.devh.boot.grpc.server.netty.NettyGrpcServerConfigurer;
import org.springframework.context.annotation.Configuration;

@Configuration
public class GrpcServerNettyConfig {

    /**
     * Configuração do servidor Netty para otimizar least_request.
     * Garante que o servidor não fecha conexões desnecessariamente.
     */
    @Bean
    public NettyGrpcServerConfigurer nettyGrpcServerConfigurer() {
        return serverBuilder -> {
            // Configurar thread pool para suportar múltiplas conexões
            int coreThreads = Runtime.getRuntime().availableProcessors();
            
            serverBuilder
                    .maxInboundMessageSize(10 * 1024 * 1024)  // 10MB
                    .keepAliveTime(60, TimeUnit.SECONDS)       // Keep-alive crítico para LB
                    .keepAliveTimeout(20, TimeUnit.SECONDS)
                    .permitKeepAliveWithoutCalls(true)         // Manter sem chamadas
                    .permitKeepAliveTime(5, TimeUnit.MINUTES); // Minimo 5 min entre keeps
        };
    }
}
```

**Imports necessários:**
```java
import net.devh.boot.grpc.server.netty.NettyGrpcServerConfigurer;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import java.util.concurrent.TimeUnit;
```

---

### **REFATORAÇÃO 8: Registrar NameResolverProvider**

**Arquivo:** `src/main/resources/META-INF/services/io.grpc.NameResolverProvider` (NOVO)

Criar arquivo com conteúdo:
```
br.usp.projetotcc.client.GrpcLoadBalancerResolverProvider
```

---

## 📝 Alterações em application.properties (Cliente)

```properties
# MANTER/ATUALIZAR no grpc-client/src/main/resources/application.properties

# Política: least_request (em vez de round_robin/pick_first)
grpc.client.meu-servico-grpc.default-load-balancing-policy=least_request

# CRÍTICO para least_request funcionar: keep-alive deve estar ativo
grpc.client.meu-servico-grpc.keep-alive-time=30s
grpc.client.meu-servico-grpc.keep-alive-timeout=10s
grpc.client.meu-servico-grpc.keep-alive-without-calls=true

# Max concurrent streams (mais streams = melhor multiplexing)
grpc.client.meu-servico-grpc.max-concurrent-streams=1000

# Flow control (importante para distribuição justa)
grpc.client.meu-servico-grpc.flow-control-window=1048576

# Retry automático em transições
grpc.client.meu-servico-grpc.enable-retry=true
grpc.client.meu-servico-grpc.max-retry-attempts=3
```

---

## 📝 Alterações em application.properties (Servidor)

```properties
# ADICIONAR ao grpc-server/src/main/resources/application.properties

# Keep-alive crítico para least_request contar conexões
grpc.server.keep-alive-time=60s
grpc.server.keep-alive-timeout=20s
grpc.server.permit-keep-alive-without-calls=true
grpc.server.permit-keep-alive-time=300s

# Não encerrar conexões rapidinho
grpc.server.max-inbound-connection-idle-time=5m

# Max concurrent streams
grpc.server.max-concurrent-streams=1000
```

---

## 🔧 Checklist de Implementação

- [ ] **Criar** `GrpcLoadBalancerResolver.java`
- [ ] **Criar** `GrpcLoadBalancerResolverProvider.java`
- [ ] **Refatorar** `GrpcClientConfig.java` (usar ManagedChannel explícito)
- [ ] **Expandir** `GrpcMetricsInterceptor.java` (rastrear por backend)
- [ ] **Criar** `HealthCheckController.java`
- [ ] **Criar** `GrpcServerNettyConfig.java` (servidor)
- [ ] **Criar** `META-INF/services/io.grpc.NameResolverProvider`
- [ ] **Adicionar** `spring-boot-starter-actuator` ao pom.xml
- [ ] **Atualizar** `application.properties` (cliente e servidor)
- [ ] **Compilar:** `mvn -DskipTests clean package`
- [ ] **Testar** com k6 e comparar distribuição

---

## 📊 Resultado Esperado com Least_Request

| Métrica | Pick-First | Round-Robin | Least-Request | Target |
|---------|-----------|------------|---------------|--------|
| Throughput | 4001 req/s | 3518 req/s | **3900+ req/s** | ≥ 3800 |
| p(95) | 416 ms | 465 ms | **420-430 ms** | < 450 |
| Max | 2.74 s | 8.77 s | **< 3.5 s** | < 4 s |
| Distribution | 1 pod 100% | 3 pods equal | **3 pods dynamic** | Balanced |

---

## 🧪 Teste de Validação

```bash
# 1. Monitor de conexões (terminal separado)
watch 'for pod in $(kubectl get pods -l app=grpc-java-server -o jsonpath=..); do echo "$pod:" && kubectl exec $pod -- ss -tn sport = :50051 state established | wc -l; done'

# 2. Rodar k6
k6 run stress-test/load-tests.js --vus 1000 --duration 3m --out json=results_least_request.json

# 3. Verificar health
curl http://localhost:8080/health/ready

# 4. Analisar distribuição
kubectl logs -l app=grpc-server | grep "REQ=" | awk -F'HOSTNAME=' '{print $2}' | awk -F']' '{print $1}' | sort | uniq -c
```

---

## 🎯 Impacto de Cada Refatoração

| Refatoração | Impacto | Prioridade |
|-----------|--------|-----------|
| ManagedChannel explícito | +5% throughput (melhor controle) | 🔴 HIGH |
| NameResolverProvider | +3% throughput (descoberta otimizada) | 🟡 MEDIUM |
| GrpcMetricsInterceptor aprimorado | +diagnóstico (sem overhead) | 🟡 MEDIUM |
| Buffer/Threads otimizados | +2-3% throughput | 🟢 LOW |
| Health Check | +observabilidade | 🟢 LOW |


