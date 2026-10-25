from collections import Counter, defaultdict
from pathlib import Path
import re


def analisar_logs_com_colchetes(caminhos_arquivos):
  """Analisa múltiplos ficheiros de log, identifica pods, quantifica

  requisições e extrai o consumo de memória do formato MEM_MB=[valor].
  """
  requisicoes_por_pod = Counter()
  soma_mem_mb = defaultdict(float)
  contagem_mem_mb = Counter()

  # Padrão para detetar o nome/ID do pod
  padrao_pod = re.compile(r'(grpc-java-server-[a-zA-Z0-9]+-[a-zA-Z0-9]+)')

  # Padrão ajustado para capturar MEM_MB=[83] ou variações com espaços
  padrao_mem_mb = re.compile(r'MEM_MB\s*=\s*\[\s*([0-9.]+)\s*\]', re.IGNORECASE)

  for caminho in caminhos_arquivos:
    arquivo = Path(caminho)
    if not arquivo.exists():
      print(f'Aviso: O ficheiro "{caminho}" não foi encontrado.')
      continue

    with open(arquivo, 'r', encoding='utf-8', errors='ignore') as f:
      for linha in f:
        match_pod = padrao_pod.search(linha)
        if match_pod:
          nome_pod = match_pod.group(1)
          requisicoes_por_pod[nome_pod] += 1

          # Procura pelo campo MEM_MB=[valor] na linha
          match_mem = padrao_mem_mb.search(linha)
          if match_mem:
            valor_mem = float(match_mem.group(1))
            soma_mem_mb[nome_pod] += valor_mem
            contagem_mem_mb[nome_pod] += 1

  # Exibição dos resultados consolidados
  total_pods = len(requisicoes_por_pod)
  total_requisicoes = sum(requisicoes_por_pod.values())

  print('=== Relatório de Análise: Requisições e MEM_MB ===')
  print(f'Total de pods distintos encontrados: {total_pods}')
  print(f'Total geral de requisições processadas: {total_requisicoes}\n')

  print('Distribuição e Memória Média por Pod:')
  for pod, qtd in requisicoes_por_pod.most_common():
    print(f'  • Pod: {pod}')
    print(f'    - Total de Requisições: {qtd}')

    if contagem_mem_mb[pod] > 0:
      media_mem = soma_mem_mb[pod] / contagem_mem_mb[pod]
      print(f'    - Média de Consumo (MEM_MB): {media_mem:.2f} MB')
      print(f'    - Amostras de memória recolhidas: {contagem_mem_mb[pod]}')
    else:
      print(
          '    - Média de Consumo (MEM_MB): Nenhum registo encontrado para este'
          ' pod'
      )
    print()


if __name__ == '__main__':
  arquivos_de_log = ['logs-teste-05-10-26_r1.txt', 'logs-teste-05-10-26_r2.txt', 'logs-teste-05-10-26_r3.txt']
  analisar_logs_com_colchetes(arquivos_de_log)