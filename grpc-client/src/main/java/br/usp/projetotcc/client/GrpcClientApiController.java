package br.usp.projetotcc.client;

import br.usp.projetotcc.contracts.message.HelloRequest;
import br.usp.projetotcc.contracts.message.HelloResponse;
import br.usp.projetotcc.contracts.message.SimpleMessageServiceGrpc;
import org.springframework.beans.factory.annotation.Autowired;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.web.bind.annotation.*;

@SpringBootApplication
@RestController
@RequestMapping("/api")
public class GrpcClientApiController {

    @Autowired
    private SimpleMessageServiceGrpc.SimpleMessageServiceBlockingStub blockingStub;

    private Logger LOGGER = LoggerFactory.getLogger(GrpcClientApiController.class);

    public static void main(String[] args) {
        SpringApplication.run(GrpcClientApiController.class, args);
    }

    @GetMapping("/messages")
    public String healthCheck() {
        return "gRPC Client API - Status: OK (pronto para receber mensagens em POST /api/messages)";
    }

    @PostMapping("/messages")
    public String enviarMensagem(@RequestBody String textoUsuario) {
        String clientThreadInfo = Thread.currentThread().toString();

        try {
            HelloRequest request = HelloRequest.newBuilder()
                    .setName(textoUsuario != null ? textoUsuario : "Texto Vazio")
                    .build();

            LOGGER.info("API [" + clientThreadInfo + "] enviando para gRPC -> " + textoUsuario);

            HelloResponse response = this.blockingStub.sayHello(request);


            return "API [" + clientThreadInfo + "] recebeu do gRPC -> " + response.getMessage();
        } catch (Exception e) {
            return "Erro ao comunicar com gRPC via Spring: " + e.getMessage();
        }
    }
}
