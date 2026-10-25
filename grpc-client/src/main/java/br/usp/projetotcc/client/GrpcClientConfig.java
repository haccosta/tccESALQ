package br.usp.projetotcc.client;

import br.usp.projetotcc.contracts.message.SimpleMessageServiceGrpc;
import net.devh.boot.grpc.client.inject.GrpcClient;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

@Configuration
public class GrpcClientConfig {

    @Bean
    public GrpcMetricsInterceptor grpcMetricsInterceptor() {
        return new GrpcMetricsInterceptor();
    }

    /**
     * O Spring Boot Starter injetará automaticamente o Stub configurado via properties.
     * Vinculamos o seu Interceptor de métricas customizado de forma limpa aqui.
     */
    @Bean
    public SimpleMessageServiceGrpc.SimpleMessageServiceBlockingStub simpleMessageBlockingStub(
            @GrpcClient("meu-servico-grpc") SimpleMessageServiceGrpc.SimpleMessageServiceBlockingStub stub,
            GrpcMetricsInterceptor metricsInterceptor) {

        return stub.withInterceptors(metricsInterceptor);
    }
}
