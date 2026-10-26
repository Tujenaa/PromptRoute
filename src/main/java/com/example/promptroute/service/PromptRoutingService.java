package com.example.promptroute.service;

import com.example.promptroute.config.GeminiConfig;
import com.example.promptroute.prompt.PromptTemplateFactory;
import com.example.promptroute.service.gemini.GeminiClient;
import com.example.promptroute.service.gemini.GeminiResponseParser;
import org.springframework.stereotype.Service;
import reactor.core.publisher.Mono;
import reactor.core.scheduler.Schedulers;

import java.nio.file.Path;
import java.util.HashMap;
import java.util.Map;

@Service
public class PromptRoutingService {

    private final PdfService pdfService;
    private final PromptTemplateFactory promptFactory;
    private final GeminiClient geminiClient;
    private final GeminiResponseParser responseParser;
    private final GeminiConfig geminiConfig;

    public PromptRoutingService(PdfService pdfService,
                                PromptTemplateFactory promptFactory,
                                GeminiClient geminiClient,
                                GeminiResponseParser responseParser,
                                GeminiConfig geminiConfig) {
        this.pdfService = pdfService;
        this.promptFactory = promptFactory;
        this.geminiClient = geminiClient;
        this.responseParser = responseParser;
        this.geminiConfig = geminiConfig;
    }

    public Mono<Map<String, Object>> solveExamAsync(Path pdfPath, String examCode) {
        long startTime = System.currentTimeMillis();

        return Mono.fromCallable(() -> pdfService.readBytes(pdfPath))
                .subscribeOn(Schedulers.boundedElastic())
                .flatMap(pdfBytes -> {
                    // Luồng 1 (Phần I - Trắc nghiệm): Flash Model — tốc độ cao, chi phí thấp
                    Mono<Map<String, Object>> threadPartI = geminiClient
                            .callGeminiMultimodal(pdfBytes, promptFactory.getPromptPartI(), geminiConfig.getFlashModel())
                            .map(responseParser::parseResponse);

                    // Luồng 2 (Phần II - Đúng/Sai): Pro Model — suy luận sâu hơn
                    Mono<Map<String, Object>> threadPartII = geminiClient
                            .callGeminiMultimodal(pdfBytes, promptFactory.getPromptPartII(), geminiConfig.getProModel())
                            .map(responseParser::parseResponse);

                    // Luồng 3 (Phần III - Tự luận): Pro Model — suy luận sâu, trình bày chi tiết
                    Mono<Map<String, Object>> threadPartIII = geminiClient
                            .callGeminiMultimodal(pdfBytes, promptFactory.getPromptPartIII(), geminiConfig.getProModel())
                            .map(responseParser::parseResponse);

                    // Gộp song song 3 luồng
                    return Mono.zip(threadPartI, threadPartII, threadPartIII)
                            .map(tuple -> {
                                long totalLatency = System.currentTimeMillis() - startTime;
                                Map<String, Object> finalResult = new HashMap<>();
                                finalResult.put("exam_code", examCode);
                                finalResult.put("phan_i", tuple.getT1());
                                finalResult.put("phan_ii", tuple.getT2());
                                finalResult.put("phan_iii", tuple.getT3());
                                finalResult.put("latency_ms", totalLatency);
                                return finalResult;
                            });
                });
    }
}