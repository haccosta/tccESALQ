package br.usp.projetotcc.client;

import io.grpc.*;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * Interceptor para coletar métricas de performance das chamadas gRPC.
 * Registra tempo de latência e identifica o backend (pod remoto) se possível.
 */
public class GrpcMetricsInterceptor implements ClientInterceptor {

    private static final Logger LOGGER = LoggerFactory.getLogger(GrpcMetricsInterceptor.class);

    @Override
    public <ReqT, RespT> ClientCall<ReqT, RespT> interceptCall(
            MethodDescriptor<ReqT, RespT> method,
            CallOptions callOptions,
            Channel next) {

        return new ForwardingClientCall.SimpleForwardingClientCall<ReqT, RespT>(
                next.newCall(method, callOptions)) {

            @Override
            public void start(Listener<RespT> responseListener, Metadata headers) {
                long startTimeNanos = System.nanoTime();

                Listener<RespT> wrappedListener = new ForwardingClientCallListener.SimpleForwardingClientCallListener<RespT>(
                        responseListener) {

                    @Override
                    public void onHeaders(Metadata headers) {
                        super.onHeaders(headers);
                        // Pode conter informações do servidor (ex. custom header com pod name)
                    }

                    @Override
                    public void onMessage(RespT message) {
                        super.onMessage(message);
                    }

                    @Override
                    public void onClose(Status status, Metadata trailers) {
                        long elapsedMs = (System.nanoTime() - startTimeNanos) / 1_000_000;
                        String methodName = method.getFullMethodName();

                        if (status.isOk()) {
                            LOGGER.debug("gRPC call [{}] completed in {}ms", methodName, elapsedMs);
                        } else {
                            LOGGER.warn("gRPC call [{}] failed with status [{}] after {}ms",
                                    methodName, status.getCode(), elapsedMs);
                        }

                        // Publicar métrica (Micrometer / custom)
                        publishMetric(methodName, elapsedMs, status.isOk());

                        super.onClose(status, trailers);
                    }
                };

                super.start(wrappedListener, headers);
            }
        };
    }

    private void publishMetric(String methodName, long elapsedMs, boolean success) {
        // Aqui você pode integrar com Micrometer, Prometheus, etc.
        // Por enquanto, apenas logamos
        if (elapsedMs > 500) {
            LOGGER.warn("SLOW_CALL: method={}, duration={}ms", methodName, elapsedMs);
        }
    }
}

