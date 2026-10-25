package br.usp.projetotcc.server;

import br.usp.projetotcc.contracts.message.HelloRequest;
import br.usp.projetotcc.contracts.message.HelloResponse;
import br.usp.projetotcc.contracts.message.SimpleMessageServiceGrpc;

import io.grpc.stub.StreamObserver;
import net.devh.boot.grpc.server.service.GrpcService;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

import java.util.concurrent.atomic.AtomicLong;

@SpringBootApplication
public class GrpcServerApplication {
    public static void main(String[] args) {
        SpringApplication.run(GrpcServerApplication.class, args);
    }
}

@GrpcService
class SimpleMessageServiceImpl extends SimpleMessageServiceGrpc.SimpleMessageServiceImplBase {

    private static final String HOSTNAME = System.getenv().getOrDefault("HOSTNAME", "local-host");
    private static final Logger LOGGER = LoggerFactory.getLogger(SimpleMessageServiceImpl.class);

    // Métricas locais
    private final java.util.concurrent.atomic.AtomicLong requestCounter =
            new java.util.concurrent.atomic.AtomicLong(0);
    private final java.util.concurrent.atomic.AtomicLong totalLatencyMs =
            new java.util.concurrent.atomic.AtomicLong(0);

    @Override
    public void sayHello(HelloRequest request, StreamObserver<HelloResponse> responseObserver) {
        long startNanos = System.nanoTime();
        String serverThreadInfo = Thread.currentThread().toString();
        String textoDoUsuario = request.getName();
        long requestNum = requestCounter.incrementAndGet();

        // Log detalhado para diagnóstico
        int threadCount = Thread.activeCount();
        long memUsed = Runtime.getRuntime().totalMemory() - Runtime.getRuntime().freeMemory();

        LOGGER.info("REQ=[{}] HOSTNAME=[{}] THREAD=[{}] ACTIVE_THREADS=[{}] MEM_MB=[{}] MSG=[{}]",
                requestNum, HOSTNAME, serverThreadInfo, threadCount, memUsed / (1024*1024), textoDoUsuario);

        HelloResponse reply = HelloResponse.newBuilder()
                .setMessage("[" + HOSTNAME + "] [" + serverThreadInfo + "] Processado: " + textoDoUsuario)
                .build();

        responseObserver.onNext(reply);
        responseObserver.onCompleted();

        long elapsedMs = (System.nanoTime() - startNanos) / 1_000_000;
        totalLatencyMs.addAndGet(elapsedMs);

        if (elapsedMs > 100) {
            LOGGER.warn("SLOW_REQUEST: req=[{}] duration={}ms", requestNum, elapsedMs);
        }
    }
}

