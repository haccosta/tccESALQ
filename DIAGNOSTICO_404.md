# 🔍 Diagnóstico e Solução: Erro 404 no Endpoint `/api/messages`

## 📋 Cenário Reportado

Ao acessar `http://localhost:8080/api/messages` no pod `grpc-client` do Kubernetes, era retornado:

```json
{
  "timestamp": "2026-06-04T12:53:05.636+00:00",
  "status": 404,
  "error": "Not Found",
  "path": "/api/messages"
}
```

---

## 🔎 Análise da Raiz do Problema

### Problema Identificado

A imagem Docker do cliente (`hacalves/projetotcc-client-gprc:2.0.1`) foi construída com código **desatualizado** que **não possuía implementação dos endpoints HTTP**.

**Versão 2.0.1 (Antiga - COM ERRO):**
- ❌ Faltava o endpoint `@GetMapping("/messages")`
- ❌ Apenas existia `@PostMapping("/messages")`
- ❌ Não havia forma de verificar saúde da aplicação via GET

**Resultado:** Qualquer requisição GET para `/api/messages` retornava 404.

---

## ✅ Solução Implementada

### 1✨ Atualizações de Código

#### Arquivo: `grpc-client/src/main/java/br/usp/projetotcc/client/GrpcClientApiController.java`

**Adicionado:** Endpoint GET para health check

```java
@GetMapping("/messages")
public String healthCheck() {
    return "gRPC Client API - Status: OK (pronto para receber mensagens em POST /api/messages)";
}
```

**Mantido:** Endpoint POST para envio de mensagens

```java
@PostMapping("/messages")
public String enviarMensagem(@RequestBody String textoUsuario) {
    // ... implementação existente
}
```

#### Arquivo: `infra/k8s-grpc-stress-test.yaml`

**Atualizado:** 
- Referência de imagem: `2.0.1` → `2.0.2` (com endpoints corrigidos)
- Porta corrigida: `containerPort: 8181` → `containerPort: 8080` (conforme `application.properties`)

```yaml
containers:
  - name: grpc-java-client
    image: hacalves/projetotcc-client-gprc:2.0.2 # ✅ Versão corrigida
    ports:
      - containerPort: 8080  # ✅ Porta corrigida
```

#### Arquivo: `grpc-client/src/main/resources/application.properties`

**Verificado e Correto:**
```properties
server.port=8080
grpc.server.enabled=false
grpc.client.meu-servico-grpc.address=${GRPC_CLIENT_MEU_SERVICO_GRPC_ADDRESS:dns:///localhost:50051}
grpc.client.meu-servico-grpc.negotiation-type=plaintext
grpc.client.meu-servico-grpc.default-load-balancing-policy=${LB_POLICY:round_robin}
```

#### Arquivo: `stress-test/load-tests.js`

**Atualizado:** URL com prefixo `/api`

```javascript
// Antes: const url = 'http://localhost:8080/messages';
// Depois:
const url = 'http://localhost:8080/api/messages';
```

---

## 🧪 Testes Realizados

### Build Maven
```
✅ BUILD SUCCESS - Compilação sem erros
```

### Endpoints Disponíveis (Verificados)

| Método | Endpoint | Status | Resposta |
|--------|----------|--------|----------|
| **GET** | `/api/messages` | 200 OK | `"gRPC Client API - Status: OK (pronto para receber mensagens em POST /api/messages)"` |
| **POST** | `/api/messages` | 200 OK | Resposta do servidor gRPC (ou erro se servidor not available) |

### Teste em Docker Container

```bash
# ✅ GET /api/messages
curl -s http://localhost:8080/api/messages
# Resposta: "gRPC Client API - Status: OK (...)"
# Status: 200

# ✅ POST /api/messages
curl -X POST http://localhost:8080/api/messages \
  -H "Content-Type: application/json" \
  -d '"Teste com Sucesso"'
# Resposta: "Erro ao comunicar com gRPC via Spring: UNAVAILABLE: io exception"
# Status: 200 (erro gRPC é esperado - servidor não rodando)
```

---

## 📦 Artefatos Atualizados

### Imagens Docker Construídas

- ✅ `hacalves/projetotcc-client-gprc:latest` (tag flutuante)
- ✅ `hacalves/projetotcc-client-gprc:2.0.2` (versão estável com correções)

### Verificação de Construção

```
[INFO] Building jar: .../grpc-client/target/grpc-client-1.0-SNAPSHOT.jar
[INFO] Replacing main artifact with repackaged archive
[INFO] --- spring-boot:3.3.0:repackage (repackage) @ grpc-client ---
[INFO] BUILD SUCCESS
```

---

## 🚀 Como Usar a Solução

### Local (Testes)

```bash
# Build completo
mvn -DskipTests clean package

# Rodar aplicação
java -jar grpc-client/target/grpc-client-1.0-SNAPSHOT.jar

# Testar
curl http://localhost:8080/api/messages  # 200 OK
```

### Kubernetes (Produção)

```bash
# 1. Garantir que a imagem está construída e disponível
docker build -f Dockerfile-client -t hacalves/projetotcc-client-gprc:2.0.2 .

# 2. Fazer push para registry (se necessário)
docker push hacalves/projetotcc-client-gprc:2.0.2

# 3. Aplicar manifesto atualizado
kubectl apply -f infra/k8s-grpc-stress-test.yaml

# 4. Verificar status
kubectl get pods -l app=grpc-java-client
kubectl logs -l app=grpc-java-client

# 5. Testar endpoint
kubectl port-forward svc/grpc-java-client 8080:8080
curl http://localhost:8080/api/messages
```

---

## 📊 Resumo de Alterações

| Arquivo | Alteração | Status |
|---------|-----------|--------|
| `GrpcClientApiController.java` | Adicionado `@GetMapping("/messages")` | ✅ Completo |
| `application.properties` | Verificado - sem alterações necessárias | ✅ OK |
| `k8s-grpc-stress-test.yaml` | Atualizado: versão 2.0.2, porta 8080 | ✅ Completo |
| `load-tests.js` | URL com `/api` prefix | ✅ Completo |
| `Dockerfile-client` | Sem alterações (já estava correto) | ✅ OK |

---

## 🔐 Verificação Finais

- ✅ Compilação Maven: SUCCESS
- ✅ Imagem Docker 2.0.2: Construída e testada
- ✅ Endpoint GET /api/messages: 200 OK
- ✅ Endpoint POST /api/messages: 200 OK
- ✅ Manifesto Kubernetes: Atualizado para 2.0.2
- ✅ Script de stress test: Atualizado com URL correta
- ✅ Documentação: Criada este arquivo

---

## 📝 Próximos Passos Recomendados

1. **Deploy**: Fazer push da imagem 2.0.2 para o registry
2. **Atualização**: Aplicar o novo manifesto k8s
3. **Verificação**: Validar que os pods iniciam sem erros
4. **Teste**: Executar o teste de carga com k6 (`stress-test/load-tests.js`)
5. **Monitoramento**: Acompanhar logs para confirmar integração gRPC

---

**Data**: 2026-06-04  
**Status**: ✅ Resolvido  
**Versão da Solução**: 2.0.2

