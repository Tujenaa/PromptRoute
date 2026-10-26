package com.example.promptroute.config;

import lombok.Data;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.context.annotation.Configuration;

@Configuration
@ConfigurationProperties(prefix = "app.gemini")
@Data
public class GeminiConfig {
    private String apiKey;
    private String baseUrl = "https://generativelanguage.googleapis.com/v1beta";
    private Double temperature = 0.1;
    private String flashModel = "gemini-3.1-flash-lite";
    private String proModel = "gemini-3.1-flash-lite";
    private Integer thinkingBudget = 0;
}