package com.example.promptroute.controller;

import com.example.promptroute.service.PdfService;
import com.example.promptroute.service.PromptRoutingService;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.http.codec.multipart.FilePart;
import org.springframework.web.bind.annotation.*;
import reactor.core.publisher.Mono;

import java.util.Map;

@RestController
@RequestMapping("/api/exams")
public class ExamController {

    private final PdfService pdfService;
    private final PromptRoutingService promptRoutingService;

    public ExamController(PdfService pdfService, PromptRoutingService promptRoutingService) {
        this.pdfService = pdfService;
        this.promptRoutingService = promptRoutingService;
    }

    /**
     * Endpoint tiếp nhận file PDF đề thi gốc và điều phối giải tự động qua Gemini Multimodal
     * Phương thức: POST
     * Content-Type: multipart/form-data
     *
     * Form fields:
     *   - file      : file PDF đề thi (required)
     *   - examCode  : mã đề thi, ví dụ "0101" (optional, query param hoặc form field)
     */
    @PostMapping(value = "/upload", consumes = MediaType.MULTIPART_FORM_DATA_VALUE)
    public Mono<ResponseEntity<Map<String, Object>>> uploadAndSolve(
            @RequestPart("file") FilePart file,
            @RequestParam(value = "examCode", required = false, defaultValue = "0101") String examCode) {

        return pdfService.savePdf(file)
                .flatMap(savedPath -> promptRoutingService.solveExamAsync(savedPath, examCode))
                .map(ResponseEntity::ok)
                .onErrorResume(e -> Mono.just(
                        ResponseEntity.internalServerError().body(Map.of("error", e.getMessage()))
                ));
    }
}