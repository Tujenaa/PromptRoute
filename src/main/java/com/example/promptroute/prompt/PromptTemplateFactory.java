package com.example.promptroute.prompt;

import org.springframework.core.io.ClassPathResource;
import org.springframework.stereotype.Component;

import java.io.IOException;
import java.nio.charset.StandardCharsets;

@Component
public class PromptTemplateFactory {

    public String loadPrompt(String filename) {
        try {
            ClassPathResource resource = new ClassPathResource("prompts/" + filename);
            return new String(resource.getInputStream().readAllBytes(), StandardCharsets.UTF_8);
        } catch (IOException e) {
            throw new RuntimeException("Không thể nạp prompt template: " + filename, e);
        }
    }

    public String getPromptPartI() {
        return loadPrompt("multiple-choice.txt");
    }

    public String getPromptPartII() {
        return loadPrompt("true-false.txt");
    }

    public String getPromptPartIII() {
        return loadPrompt("short-answers.txt");
    }
}