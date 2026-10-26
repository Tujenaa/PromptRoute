package com.example.promptroute.service;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.codec.multipart.FilePart;
import org.springframework.stereotype.Service;
import reactor.core.publisher.Mono;

import java.io.IOException;
import java.nio.file.*;

@Service
public class PdfService {

    private final Path storageLocation;

    public PdfService(@Value("${app.upload-dir:./uploads}") String uploadDir) {
        this.storageLocation = Paths.get(uploadDir).toAbsolutePath().normalize();
        try {
            Files.createDirectories(this.storageLocation);
        } catch (IOException e) {
            throw new RuntimeException("Không thể tạo thư mục uploads", e);
        }
    }

    public Mono<Path> savePdf(FilePart filePart) {
        String fileName = System.currentTimeMillis() + "_" + filePart.filename();
        Path targetPath = this.storageLocation.resolve(fileName);
        return filePart.transferTo(targetPath).thenReturn(targetPath);
    }

    public byte[] readBytes(Path path) throws IOException {
        return Files.readAllBytes(path);
    }
}