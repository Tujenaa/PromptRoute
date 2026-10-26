package com.example.promptroute.service.gemini;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.springframework.stereotype.Component;

import java.util.Map;

@Component
public class GeminiResponseParser {

    private final ObjectMapper objectMapper;

    public GeminiResponseParser(ObjectMapper objectMapper) {
        this.objectMapper = objectMapper;
    }

    public Map<String, Object> parseResponse(String rawApiResponse) {
        try {
            JsonNode rootNode = objectMapper.readTree(rawApiResponse);
            // Trích xuất text JSON từ cấu trúc candidates của Gemini API
            String jsonText = rootNode.path("candidates")
                    .get(0)
                    .path("content")
                    .path("parts")
                    .get(0)
                    .path("text")
                    .asText();

            // Loại bỏ markdown code block nếu có ```json ... ```
            String cleanJson = jsonText.trim();
            if (cleanJson.startsWith("```json")) {
                cleanJson = cleanJson.substring(7);
            } else if (cleanJson.startsWith("```")) {
                cleanJson = cleanJson.substring(3);
            }
            if (cleanJson.endsWith("```")) {
                cleanJson = cleanJson.substring(0, cleanJson.length() - 3);
            }

            return objectMapper.readValue(cleanJson.trim(), new TypeReference<Map<String, Object>>() {
            });
        } catch (Exception e) {
            return Map.of("error", "Lỗi phân tích cú pháp JSON: " + e.getMessage(), "raw", rawApiResponse);
        }
    }
}