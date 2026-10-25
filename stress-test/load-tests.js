import http from 'k6/http';
import { check } from 'k6';
import { sleep } from 'k6';
import { htmlReport } from "https://raw.githubusercontent.com/benc-uk/k6-reporter/main/dist/bundle.js";
import { textSummary } from "https://jslib.k6.io/k6-summary/0.1.0/index.js";


export const options = {
    // Definimos um cenário explícito para garantir os 500 VUs
    scenarios: {
        teste_carga_mensagens: {
            executor: 'ramping-vus',
            startVUs: 0,
            stages: [
                { duration: '1m', target: 200 },  // 1. Ramping Up: Sobe de 1 para 200 VUs em 1 minuto
                { duration: '2m', target: 1000 }, // 2. Ramping Up+: Sobe de 200 para 1000 VUs nos próximos 2 minutos
                { duration: '3m', target: 1000 }, // 3. Estabilidade (Sustain): Mantém 1000 VUs por 3 minutos
                { duration: '1m', target: 0 },    // 4. Ramping Down: Reduz de 1000 para 0 VUs em 1 minuto (rescalonamento)
            ],
            gracefulRampDown: '30s'
        },
    },
    thresholds: {
        'http_req_duration': ['p(95)<20'], // 95% das requisições < 25ms
        'http_req_failed': ['rate<0.01'],  // Falhas < 1%
    },
};

export default function () {
    const url = 'http://localhost:8080/api/messages';

    const payload = JSON.stringify({
        "text": "Olha mundo"
    });

    const params = {
        headers: {
            'Content-Type': 'application/json',
        },
    };

    const res = http.post(url, payload, params);

    check(res, {
        'status 200': (r) => r.status === 200,
    });

    let tempoRandom = Math.random() * (2 - 0.5) + 0.5;
    sleep(tempoRandom);
}
export function handleSummary(data) {
    return {
        "resultado_r3.html": htmlReport(data),
        "stdout": textSummary(data, { indent: " ", enableColors: true }),
    };
}