#!/bin/bash

###############################################################################
# Script de Validação Rápida: Quais Causas Afetam Seu Round-Robin
# Execute este script durante/após testes para diagnosticar raiz
###############################################################################

set -e

NAMESPACE="${NAMESPACE:-default}"
OUTPUT_DIR="diagnostico_validacao_$(date +%Y%m%d_%H%M%S)"

echo "=========================================="
echo " Validação Rápida de Causas"
echo "=========================================="

mkdir -p "$OUTPUT_DIR"

# =============================================================================
# 1. Verificar DNS Resolution
# =============================================================================

echo ""
echo ">>> 1. Verificando DNS Discovery (Round-Robin precisa de múltiplos IPs)"

CLIENT_POD=$(kubectl get pods -n "$NAMESPACE" -l app=grpc-java-client -o jsonpath='{.items[0].metadata.name}')

if [ -z "$CLIENT_POD" ]; then
    echo "❌ Cliente pod não encontrado"
    exit 1
fi

echo "  Cliente pod: $CLIENT_POD"

DNS_RESULT=$(kubectl exec -n "$NAMESPACE" "$CLIENT_POD" -- \
    nslookup grpc-java-server.default.svc.cluster.local 2>/dev/null | \
    grep "Address:" | grep -v "Nameserver" || echo "")

IP_COUNT=$(echo "$DNS_RESULT" | wc -l)

echo "  IPs descobertos: $IP_COUNT"
echo "$DNS_RESULT" | while read -r line; do echo "    $line"; done

if [ "$IP_COUNT" -lt 3 ]; then
    echo "  ⚠️  PROBLEMA: Esperado 3 IPs para headless service"
    echo "       → headless service.spec.clusterIP pode não estar None"
    echo "       → round-robin não terá 3 backends para distribuir"
fi

tee -a "$OUTPUT_DIR/dns_discovery.txt" <<< "$DNS_RESULT"

# =============================================================================
# 2. Contar Conexões TCP por Pod
# =============================================================================

echo ""
echo ">>> 2. Verificando Conexões TCP (Múltiplas conexões = overhead)"

for pod in $(kubectl get pods -n "$NAMESPACE" -l app=grpc-java-server -o jsonpath='{.items[*].metadata.name}'); do
    CONN_COUNT=$(kubectl exec -n "$NAMESPACE" "$pod" -- \
        ss -tn state established sport = :50051 2>/dev/null | tail -n +2 | wc -l || echo "0")

    echo "  $pod: $CONN_COUNT conexões ESTABLISHED"
    echo "$pod: $CONN_COUNT" >> "$OUTPUT_DIR/tcp_connections.txt"
done

TOTAL_CONN=$(cat "$OUTPUT_DIR/tcp_connections.txt" | awk -F: '{sum += $2} END {print sum}')
echo "  TOTAL: $TOTAL_CONN conexões (pick-first = 1, round-robin = 3+)"

# =============================================================================
# 3. Verificar CPU Usage por Pod
# =============================================================================

echo ""
echo ">>> 3. Verificando CPU & Memory (Contention?)

 (Nota: requer metrics-server)"

CPU_OUTPUT=$(kubectl top pods -n "$NAMESPACE" -l app=grpc-java-server --containers 2>/dev/null || echo "")

if [ -z "$CPU_OUTPUT" ]; then
    echo "  ⚠️  Métricas indisponíveis (metrics-server not running?)"
else
    echo "$CPU_OUTPUT" | head -10
    echo "$CPU_OUTPUT" >> "$OUTPUT_DIR/cpu_metrics.txt"

    # Analisar se algum pod está em throttling (CPU > 950m com limit 1000m)
    echo "$CPU_OUTPUT" | awk '{if (NF >= 2) {cpu = $2; gsub("m", "", cpu); if (cpu > 950) print "  ⚠️  Pod próximo ao limit de CPU: " $0}}'
fi

# =============================================================================
# 4. Verificar Thread Count nos Pods
# =============================================================================

echo ""
echo ">>> 4. Verificando Thread Count (Project Loom + Virtual Threads)"

for pod in $(kubectl get pods -n "$NAMESPACE" -l app=grpc-java-server -o jsonpath='{.items[*].metadata.name}'); do
    THREAD_COUNT=$(kubectl exec -n "$NAMESPACE" "$pod" -- \
        jcmd $(pgrep java 2>/dev/null || echo "0") Thread.print 2>/dev/null | grep -c "tid:" || echo "0")

    echo "  $pod: $THREAD_COUNT threads"
    echo "$pod: $THREAD_COUNT" >> "$OUTPUT_DIR/thread_count.txt"
done

# =============================================================================
# 5. Coletar Logs de Aplicação - Procurar por Padrões
# =============================================================================

echo ""
echo ">>> 5. Analisando Logs de Aplicação"

for pod in $(kubectl get pods -n "$NAMESPACE" -l app=grpc-java-server,app=grpc-java-client -o jsonpath='{.items[*].metadata.name}'); do
    echo "  Coletando logs de $pod..."
    kubectl logs -n "$NAMESPACE" "$pod" --tail=500 > "$OUTPUT_DIR/logs_${pod}.txt" 2>&1 || true

    # Procurar por padrões de problema
    SLOW_CALLS=$(grep -c "SLOW_" "$OUTPUT_DIR/logs_${pod}.txt" || echo "0")
    ERRORS=$(grep -c "ERROR\|Exception" "$OUTPUT_DIR/logs_${pod}.txt" || echo "0")

    if [ "$SLOW_CALLS" -gt 0 ]; then
        echo "    ⚠️  $SLOW_CALLS chamadas lentas detectadas"
    fi

    if [ "$ERRORS" -gt 0 ]; then
        echo "    ⚠️  $ERRORS erros detectados"
    fi
done

# =============================================================================
# 6. Verificar Configuração de LB Policy Atual
# =============================================================================

echo ""
echo ">>> 6. Verificando Configuração ativa"

LB_POLICY=$(kubectl get deployment grpc-java-client -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="LB_POLICY")].value}' || echo "not-set")

echo "  LB_POLICY no deployment: $LB_POLICY"

# =============================================================================
# 7. Análise de Resultado
# =============================================================================

echo ""
echo "=========================================="
echo " Análise de Hipóteses"
echo "=========================================="

echo ""
echo "📊 Resumo dos Achados:"
echo "  ✓ arquivos salvos em: $OUTPUT_DIR/"
echo ""

if [ "$IP_COUNT" -lt 3 ]; then
    echo "❌ PROBLEMA 1: DNS não retorna 3 IPs"
    echo "   → round-robin não está funcionando"
    echo "   → Solução: Verificar headless service configuration"
else
    echo "✓ DNS: OK (3 IPs descobertos)"
fi

if [ "$TOTAL_CONN" -gt 3 ]; then
    echo "⚠️  3+ conexões TCP detectadas"
    echo "   → Multiple subchannels abertos para round-robin"
    echo "   → Comparem: 1 conexão (pick-first) vs múltiplas"
else
    echo "✓ TCP: Poucas conexões"
fi

echo ""
echo "🔍 Próximas Ações:"
echo "  1. Comparar arquivo 'diagnostico_results_*/' com estes"
echo "  2. Se DNS OK mas muitas conexões → problema de multiplexing"
echo "  3. Se CPU próximo a 100% → CPU contention"
echo "  4. Se muitos threads → Project Loom scheduling overhead"
echo ""
echo "📁 Detalhes completos em: $OUTPUT_DIR/"
ls -la "$OUTPUT_DIR"/


