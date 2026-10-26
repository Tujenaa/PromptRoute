package com.example.promptroute.service.gemini;

import com.example.promptroute.config.GeminiConfig;
import org.springframework.http.MediaType;
import org.springframework.stereotype.Service;
import org.springframework.web.reactive.function.client.WebClient;
import reactor.core.publisher.Mono;

import java.util.Base64;
import java.util.List;
import java.util.Map;

import reactor.util.retry.Retry;
import org.springframework.web.reactive.function.client.WebClientResponseException;
import java.time.Duration;

@Service
public class GeminiClient {

        private final WebClient webClient;
        private final GeminiConfig geminiConfig;

        public GeminiClient(WebClient webClient, GeminiConfig geminiConfig) {
                this.webClient = webClient;
                this.geminiConfig = geminiConfig;
        }

        public Mono<String> callGeminiMultimodal(byte[] pdfBytes, String systemPrompt, String modelName) {
                Map<String, Object> requestBody = buildGeminiRequestBody(pdfBytes, systemPrompt);

                // Nối trực tiếp query string, tránh lỗi UriBuilder ghi đè mất /v1beta của baseUrl
                String uri = String.format("/models/%s:generateContent?key=%s",
                                modelName,
                                geminiConfig.getApiKey());

                return webClient.post()
                        .uri(uri)
                        .contentType(MediaType.APPLICATION_JSON)
                        .bodyValue(requestBody)
                        .retrieve()
                        .bodyToMono(String.class)
                        .retryWhen(
                                Retry.backoff(3, Duration.ofSeconds(2))
                                        .maxBackoff(Duration.ofSeconds(10))
                                        .filter(e ->
                                                e instanceof WebClientResponseException w
                                                        && (w.getStatusCode().value() == 503
                                                        || w.getStatusCode().value() == 429)
                                        )
                                        .doBeforeRetry(signal ->
                                                System.out.println(
                                                        "Gemini API lỗi, đang thử lại lần "
                                                                + (signal.totalRetries() + 1)
                                                                + "/3. Nguyên nhân: "
                                                                + signal.failure().getMessage()
                                                )
                                        )
                                        .onRetryExhaustedThrow(
                                                (spec, signal) -> signal.failure()
                                        )
                        );

        }

        private Map<String, Object> buildGeminiRequestBody(byte[] pdfBytes, String systemPrompt) {
                String base64Pdf = Base64.getEncoder().encodeToString(pdfBytes);

                return Map.of(
                                "contents", List.of(
                                                Map.of("parts", List.of(
                                                                Map.of("inline_data", Map.of(
                                                                                "mime_type", "application/pdf",
                                                                                "data", base64Pdf))))),
                                "system_instruction", Map.of(
                                                "parts", List.of(
                                                                Map.of("text", systemPrompt))),
                                "generationConfig", Map.of(
                                                "temperature",
                                                geminiConfig.getTemperature() != null ? geminiConfig.getTemperature()
                                                                : 0.1,
                                                "response_mime_type", "application/json"));
        }
}