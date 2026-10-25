#!/bin/bash

###############################################################################
# Script de Diagnóstico Automático: Round-Robin vs Pick-First
# Este script executa testes de carga e coleta métricas do Kubernetes
###############################################################################

set -e

NAMESPACE="${NAMESPACE:-default}"
K6_DURATION="${K6_DURATION:-3m0s}"
K6_SCRIPT="${K6_SCRIPT:-stress-test/load-tests.js}"
RESULTS_DIR="diagnostico_results_$(date +%Y%m%d_%H%M%S)"

echo "=========================================="
echo " Diagnóstico: Round-Robin vs Pick-First"
echo "=========================================="

mkdir -p "$RESULTS_DIR"

# Função para executar teste e coletar métricas
run_test() {
    local policy=$1
    local test_name="test_${policy}_$(date +%Y%m%d_%H%M%S)"

    echo ""
    echo ">>> Preparando teste com LB_POLICY=$policy"

    # 1. Definir política de LB
    echo "  - Atualizando LB_POLICY no cliente..."
    kubectl set env deployment/grpc-java-client \
        LB_POLICY="$policy" \
        -n "$NAMESPACE" \
        --record

    # 2. Aguardar pod do cliente estar pronto
    echo "  - Aguardando pod do cliente..."
    kubectl rollout status deployment/grpc-java-client \
        -n "$NAMESPACE" \
        --timeout=120s

    sleep 10  # Dar tempo para o cliente aplicação realmente usar a nova policy

    # 3. Começar monitoramento em background
    echo "  - Iniciando coleta de métricas do Kubernetes..."

    # Coletar resources a cada 5 segundos durante 3m
    {
        for i in {1..36}; do
            echo "=== TIMESTAMP: $(date +%Y-%m-%d\ %H:%M:%S) ==="
            kubectl top pods -n "$NAMESPACE" \
                -l app=grpc-java-server,app=grpc-java-client \
                --containers 2>/dev/null || echo "  (resources unavailable)"
            echo ""
            sleep 5
        done
    } > "$RESULTS_DIR/metrics_${policy}.log" 2>&1 &

    METRICS_PID=$!

    # 4. Coletar número de conexões no servidor (a cada 10 segundos)
    {
        for pod in $(kubectl get pods -n "$NAMESPACE" -l app=grpc-java-server -o jsonpath='{.items[*].metadata.name}'); do
            {
                for i in {1..18}; do
                    echo "=== $pod TIMESTAMP: $(date +%Y-%m-%d\ %H:%M:%S) ==="
                    kubectl exec -n "$NAMESPACE" "$pod" -- \
                        ss -tn state established sport = :50051 2>/dev/null | wc -l || echo "0"
                    sleep 10
                done
            } > "$RESULTS_DIR/connections_${policy}_${pod}.log" 2>&1 &
        done
    }

    # 5. Executar teste k6
    echo "  - Iniciando teste k6..."
    K6_VUS=1000 K6_DURATION="$K6_DURATION" \
        k6 run "$K6_SCRIPT" \
        --out json="$RESULTS_DIR/k6_${policy}.json" \
        > "$RESULTS_DIR/k6_${policy}.log" 2>&1 || true

    # 6. Aguardar monitoramento finalizar
    wait $METRICS_PID 2>/dev/null || true

    # 7. Coletar logs de aplicação
    echo "  - Coletando logs de aplicação..."
    for pod in $(kubectl get pods -n "$NAMESPACE" -l app=grpc-java-server,app=grpc-java-client -o jsonpath='{.items[*].metadata.name}'); do
        kubectl logs -n "$NAMESPACE" "$pod" \
            --tail=200 \
            > "$RESULTS_DIR/logs_${policy}_${pod}.log" 2>&1 || true
    done

    echo "  ✓ Teste com $policy concluído"
}

# ============================================================================
# EXECUTAR TESTES
# ============================================================================

echo ""
echo "Verificando pré-requisitos..."
echo "  - Namespace: $NAMESPACE"
echo "  - Script k6: $K6_SCRIPT"
echo "  - Duração: $K6_DURATION"
echo "  - Output: $RESULTS_DIR"

# Verificar deployment de cliente
if ! kubectl get deployment grpc-java-client -n "$NAMESPACE" > /dev/null 2>&1; then
    echo "❌ ERRO: Deployment 'grpc-java-client' não encontrado no namespace '$NAMESPACE'"
    exit 1
fi

if ! kubectl get deployment grpc-java-server -n "$NAMESPACE" > /dev/null 2>&1; then
    echo "❌ ERRO: Deployment 'grpc-java-server' não encontrado no namespace '$NAMESPACE'"
    exit 1
fi

echo "✓ Pré-requisitos OK"

# Executar Teste 1: pick_first (baseline de melhor case)
echo ""
echo "===== TESTE 1/2: pick_first (baseline) ====="
run_test "pick_first"

sleep 30  # Cooldown entre testes

# Executar Teste 2: round_robin
echo ""
echo "===== TESTE 2/2: round_robin ====="
run_test "round_robin"

# ============================================================================
# GERAR RELATÓRIO
# ============================================================================

echo ""
echo "=========================================="
echo " Gerando Relatório de Análise"
echo "=========================================="

cat > "$RESULTS_DIR/ANALISE.md" << 'EOF'
# Análise Diagnóstica: Round-Robin vs Pick-First

## Resumo dos Resultados

| Métrica | pick_first | round_robin | Delta | Status |
|---------|-----------|------------|-------|---------|
| Throughput (req/s) | $(grep 'http_reqs' k6_pick_first.log) | $(grep 'http_reqs' k6_round_robin.log) | ? | ? |
| Latência Média (ms) | $(grep 'avg=' k6_pick_first.log) | $(grep 'avg=' k6_round_robin.log) | ? | ? |
| p(95) (ms) | $(grep 'p(95)=' k6_pick_first.log) | $(grep 'p(95)=' k6_round_robin.log) | ? | ? |
| Max (ms) | $(grep 'max=' k6_pick_first.log) | $(grep 'max=' k6_round_robin.log) | ? | ? |

## Análise de CPU/Memória

### pick_first
- Recursos por pod (servidor): [Ver metrics_pick_first.log]
- Número de conexões por pod: [Ver connections_pick_first_*.log]

### round_robin
- Recursos por pod (servidor): [Ver metrics_round_robin.log]
- Número de conexões por pod: [Ver connections_round_robin_*.log]

## Hipóteses Validadas

- [ ] **CPU contention**: round-robin distribuiu carga melhor? Verificar CPU% nos pods
- [ ] **Múltiplas conexões TCP**: round-robin criou mais conexões que pick-first?
- [ ] **Warm cache/JIT**: pick-first teve mais tempo para JIT? Verificar latência ao longo do tempo
- [ ] **GC Pause**: Há picos altos em max latency? Pode ser GC

## Recomendações

1. Se round-robin não melhora com mais recursos → usar pick-first
2. Se round-robin melhora com mais recursos → aumentar CPU/RAM dos pods
3. Se pick-first atingiu limite → considerar mais replicas + round-robin com configuração otimizada

EOF

echo ""
echo "✓ Diagnóstico completo!"
echo "✓ Resultados em: $RESULTS_DIR/"
echo ""
echo "Próximos passos:"
echo "  1. Comparar k6_pick_first.log vs k6_round_robin.log"
echo "  2. Analisar CPU/memória em metrics_*.log"
echo "  3. Comparar conexões TCP em connections_*.log"
echo "  4. Revisar logs de aplicação em logs_*.log"
echo ""

