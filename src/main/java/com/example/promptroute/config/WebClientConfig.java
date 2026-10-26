package com.example.promptroute.config;

import com.fasterxml.jackson.databind.ObjectMapper;
import io.netty.channel.ChannelOption;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.http.client.reactive.ReactorClientHttpConnector;
import org.springframework.web.reactive.function.client.ExchangeStrategies;
import org.springframework.web.reactive.function.client.WebClient;
import reactor.netty.http.client.HttpClient;

import java.time.Duration;

@Configuration
public class WebClientConfig {

    // 1. Khai báo Bean ObjectMapper cho Spring Context tiêm vào GeminiResponseParser
    @Bean
    public ObjectMapper objectMapper() {
        return new ObjectMapper();
    }

    // 2. Bean WebClient với bộ đệm 20MB cho True-PDF và timeout 120s cho LLM
    @Bean
    public WebClient webClient(GeminiConfig geminiConfig) {
        ExchangeStrategies strategies = ExchangeStrategies.builder()
                .codecs(codecs -> codecs.defaultCodecs().maxInMemorySize(20 * 1024 * 1024))
                .build();

        // Cấu hình timeout đúng cách cho WebFlux (không dùng spring.mvc.async)
        HttpClient httpClient = HttpClient.create()
                .option(ChannelOption.CONNECT_TIMEOUT_MILLIS, 10_000)       // 10s connect timeout
                .responseTimeout(Duration.ofSeconds(120));                   // 120s response timeout

        return WebClient.builder()
                .baseUrl(geminiConfig.getBaseUrl())
                .clientConnector(new ReactorClientHttpConnector(httpClient))
                .exchangeStrategies(strategies)
                .build();
    }
}