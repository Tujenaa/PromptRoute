-- ============================================================
-- ĐỀ TÀI NCKH:
-- Khung điều phối prompt động giải đề thi tốt nghiệp THPT môn Toán
-- bằng mô hình ngôn ngữ lớn (Gemini API)
-- Hệ quản trị: PostgreSQL 14+
--
-- Lưu ý:
-- 1) Script này xóa schema nckh_math nếu đã tồn tại.
--    Nếu không muốn mất dữ liệu cũ, hãy bỏ khối DROP SCHEMA.
-- 2) PDF được lưu bằng đường dẫn/URL trong pdf_path, không lưu byte PDF
--    trực tiếp trong PostgreSQL.
-- 3) Không lưu "suy nghĩ nội bộ" của mô hình; buoc_giai_nhap là nội dung
--    lời giải nháp do mô hình trả về theo thiết kế thí nghiệm.
-- ============================================================

BEGIN;

DROP SCHEMA IF EXISTS nckh_math CASCADE;
CREATE SCHEMA nckh_math;
SET search_path TO nckh_math, public;

-- ============================================================
-- 1. ĐỀ THI
-- ============================================================
CREATE TABLE exams (
    exam_id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    exam_code        VARCHAR(100) NOT NULL UNIQUE,
    exam_year        SMALLINT NOT NULL CHECK (exam_year BETWEEN 2000 AND 2100),
    exam_title       VARCHAR(255) NOT NULL DEFAULT 'Đề thi tốt nghiệp THPT môn Toán',
    source_type      VARCHAR(30) NOT NULL DEFAULT 'PDF'
                     CHECK (source_type IN ('PDF', 'SCAN_PDF', 'DIGITAL_PDF', 'OTHER')),
    pdf_path         TEXT NOT NULL,
    file_sha256      CHAR(64),
    status           VARCHAR(20) NOT NULL DEFAULT 'ACTIVE'
                     CHECK (status IN ('ACTIVE', 'INACTIVE', 'ARCHIVED')),
    notes            TEXT,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK (file_sha256 IS NULL OR file_sha256 ~ '^[0-9a-fA-F]{64}$')
);

COMMENT ON TABLE exams IS 'Thông tin đề thi gốc; PDF được tham chiếu qua pdf_path.';
COMMENT ON COLUMN exams.pdf_path IS 'Đường dẫn hoặc URL tới PDF nguyên bản; không bắt buộc OCR.';
COMMENT ON COLUMN exams.file_sha256 IS 'SHA-256 tùy chọn để kiểm tra tính toàn vẹn của tệp.';

-- ============================================================
-- 2. CẤU HÌNH PHẦN THI
-- Mỗi bản ghi là một loại phần thi: PART_I, PART_II, PART_III.
-- question_count ở đây là số câu dự kiến theo cấu hình nghiên cứu;
-- nếu cấu trúc thay đổi theo từng đề, nên quản lý ở bảng riêng.
-- ============================================================
CREATE TABLE exam_sections (
    section_id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    section_code     VARCHAR(20) NOT NULL UNIQUE,
    section_name     VARCHAR(150) NOT NULL,
    description      TEXT,
    default_question_count INTEGER CHECK (default_question_count IS NULL OR default_question_count >= 0),
    answer_schema    JSONB NOT NULL DEFAULT '{}'::JSONB,
    display_order    SMALLINT NOT NULL UNIQUE CHECK (display_order > 0),
    is_active        BOOLEAN NOT NULL DEFAULT TRUE,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK (jsonb_typeof(answer_schema) = 'object')
);

COMMENT ON TABLE exam_sections IS 'Danh mục ba phần thi: trắc nghiệm, đúng/sai, trả lời ngắn.';
COMMENT ON COLUMN exam_sections.answer_schema IS 'Mô tả schema đầu ra mong đợi cho phần thi dưới dạng JSONB.';

-- ============================================================
-- 3. ĐÁP ÁN CHUẨN / THANG ĐIỂM
-- Có thể lưu nhiều phiên bản đáp án cho một đề, ví dụ bản chính thức
-- và bản đã hiệu chỉnh dùng trong thực nghiệm.
-- ============================================================
CREATE TABLE answer_keys (
    answer_key_id    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    exam_id          BIGINT NOT NULL REFERENCES exams(exam_id) ON DELETE CASCADE,
    answer_key_name  VARCHAR(150) NOT NULL DEFAULT 'Đáp án chuẩn',
    version          INTEGER NOT NULL DEFAULT 1 CHECK (version > 0),
    answer_data      JSONB NOT NULL,
    scoring_rules    JSONB NOT NULL DEFAULT '{}'::JSONB,
    source_reference TEXT,
    is_official      BOOLEAN NOT NULL DEFAULT FALSE,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (exam_id, answer_key_name, version),
    CHECK (jsonb_typeof(answer_data) = 'object'),
    CHECK (jsonb_typeof(scoring_rules) = 'object')
);

COMMENT ON TABLE answer_keys IS 'Đáp án chuẩn và quy tắc chấm dùng để đánh giá kết quả Gemini.';
COMMENT ON COLUMN answer_keys.answer_data IS 'Đáp án theo mã câu/phần, lưu dạng JSONB.';
COMMENT ON COLUMN answer_keys.scoring_rules IS 'Quy tắc chấm, gồm quy tắc điểm thành phần nếu có.';

-- ============================================================
-- 4. CẤU HÌNH PROMPT
-- strategy có thể là BASELINE, FEW_SHOT, DYNAMIC_SCOPE hoặc tên chiến lược
-- thực tế được sử dụng trong đề tài.
-- ============================================================
CREATE TABLE prompt_configs (
    prompt_id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    prompt_name        VARCHAR(150) NOT NULL,
    strategy           VARCHAR(50) NOT NULL,
    version            INTEGER NOT NULL DEFAULT 1 CHECK (version > 0),
    system_prompt      TEXT NOT NULL,
    prompt_parameters  JSONB NOT NULL DEFAULT '{}'::JSONB,
    description        TEXT,
    is_active          BOOLEAN NOT NULL DEFAULT TRUE,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (prompt_name, version),
    CHECK (jsonb_typeof(prompt_parameters) = 'object')
);

COMMENT ON TABLE prompt_configs IS 'Lưu phiên bản prompt và tham số điều phối để tái lập thí nghiệm.';
COMMENT ON COLUMN prompt_configs.prompt_parameters IS 'Tham số động như phạm vi phần thi, few-shot examples, yêu cầu JSON.';

-- ============================================================
-- 5. CẤU HÌNH MÔ HÌNH
-- Không lưu API key trong bảng này. API key nên nằm trong biến môi trường
-- hoặc secret manager.
-- ============================================================
CREATE TABLE model_configs (
    model_config_id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    provider              VARCHAR(50) NOT NULL DEFAULT 'Google',
    model_name            VARCHAR(150) NOT NULL,
    model_role            VARCHAR(50),
    generation_parameters JSONB NOT NULL DEFAULT '{}'::JSONB,
    is_active             BOOLEAN NOT NULL DEFAULT TRUE,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (provider, model_name),
    CHECK (jsonb_typeof(generation_parameters) = 'object')
);

COMMENT ON TABLE model_configs IS 'Cấu hình tên model và tham số sinh; không lưu thông tin bí mật.';
COMMENT ON COLUMN model_configs.model_role IS 'Vai trò định tuyến, ví dụ SPEED_OPTIMIZED hoặc REASONING.';

-- ============================================================
-- 6. LẦN CHẠY THỰC NGHIỆM
-- Mỗi run đại diện cho một lần chạy một chiến lược trên một đề.
-- ============================================================
CREATE TABLE experiment_runs (
    run_id            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    exam_id           BIGINT NOT NULL REFERENCES exams(exam_id) ON DELETE RESTRICT,
    prompt_id         BIGINT NOT NULL REFERENCES prompt_configs(prompt_id) ON DELETE RESTRICT,
    experiment_name   VARCHAR(200) NOT NULL,
    experiment_stage  VARCHAR(50) NOT NULL DEFAULT 'EVALUATION',
    run_parameters    JSONB NOT NULL DEFAULT '{}'::JSONB,
    started_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    finished_at       TIMESTAMPTZ,
    status            VARCHAR(20) NOT NULL DEFAULT 'RUNNING'
                      CHECK (status IN ('RUNNING', 'COMPLETED', 'FAILED', 'CANCELLED')),
    notes             TEXT,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK (finished_at IS NULL OR finished_at >= started_at),
    CHECK (jsonb_typeof(run_parameters) = 'object')
);

COMMENT ON TABLE experiment_runs IS 'Theo dõi một lượt thực nghiệm trên một đề và chiến lược prompt.';
COMMENT ON COLUMN experiment_runs.run_parameters IS 'Có thể ghi baseline/few-shot/dynamic scope và các điều kiện thực nghiệm.';

-- ============================================================
-- 7. LỊCH SỬ GỌI API
-- Một lần gọi API gắn với một phần thi, một model và prompt thực tế.
-- prompt_id ở đây cho phép ghi nhận prompt khác với prompt tổng của run
-- nếu bộ điều phối chọn prompt động theo phần thi.
-- ============================================================
CREATE TABLE api_calls (
    api_call_id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id            BIGINT NOT NULL REFERENCES experiment_runs(run_id) ON DELETE CASCADE,
    section_id        BIGINT NOT NULL REFERENCES exam_sections(section_id) ON DELETE RESTRICT,
    model_config_id   BIGINT NOT NULL REFERENCES model_configs(model_config_id) ON DELETE RESTRICT,
    prompt_id         BIGINT NOT NULL REFERENCES prompt_configs(prompt_id) ON DELETE RESTRICT,
    attempt_no        INTEGER NOT NULL DEFAULT 1 CHECK (attempt_no > 0),
    request_id        VARCHAR(150),
    requested_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    completed_at      TIMESTAMPTZ,
    latency_ms        BIGINT CHECK (latency_ms IS NULL OR latency_ms >= 0),
    input_tokens      INTEGER CHECK (input_tokens IS NULL OR input_tokens >= 0),
    output_tokens     INTEGER CHECK (output_tokens IS NULL OR output_tokens >= 0),
    status            VARCHAR(20) NOT NULL DEFAULT 'PENDING'
                      CHECK (status IN ('PENDING', 'SUCCESS', 'ERROR', 'TIMEOUT', 'INVALID_RESPONSE')),
    error_message     TEXT,
    request_metadata  JSONB NOT NULL DEFAULT '{}'::JSONB,
    UNIQUE (run_id, section_id, attempt_no),
    CHECK (completed_at IS NULL OR completed_at >= requested_at),
    CHECK (jsonb_typeof(request_metadata) = 'object')
);

COMMENT ON TABLE api_calls IS 'Lưu từng lần gọi Gemini, thời gian, token, model, prompt và lỗi.';
COMMENT ON COLUMN api_calls.request_metadata IS 'Metadata không nhạy cảm của request; tuyệt đối không lưu API key.';

-- ============================================================
-- 8. PHẢN HỒI MÔ HÌNH
-- raw_response_text giữ nguyên phản hồi dạng text kể cả khi JSON lỗi.
-- raw_response và parsed_result là JSONB khi có thể phân tích được.
-- ============================================================
CREATE TABLE model_responses (
    response_id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    api_call_id        BIGINT NOT NULL REFERENCES api_calls(api_call_id) ON DELETE CASCADE,
    response_sequence  SMALLINT NOT NULL DEFAULT 1 CHECK (response_sequence > 0),
    raw_response_text  TEXT,
    raw_response       JSONB,
    parsed_result      JSONB,
    draft_solution     TEXT,
    json_valid         BOOLEAN NOT NULL DEFAULT FALSE,
    schema_valid       BOOLEAN NOT NULL DEFAULT FALSE,
    parse_status       VARCHAR(30) NOT NULL DEFAULT 'NOT_PARSED'
                       CHECK (parse_status IN ('NOT_PARSED', 'PARSED', 'INVALID_JSON', 'TRUNCATED', 'EMPTY', 'ERROR')),
    validation_errors  JSONB NOT NULL DEFAULT '[]'::JSONB,
    received_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (api_call_id, response_sequence),
    CHECK (raw_response IS NULL OR jsonb_typeof(raw_response) IN ('object', 'array', 'string', 'number', 'boolean', 'null')),
    CHECK (parsed_result IS NULL OR jsonb_typeof(parsed_result) IN ('object', 'array')),
    CHECK (jsonb_typeof(validation_errors) = 'array')
);

COMMENT ON TABLE model_responses IS 'Lưu phản hồi nguyên bản và kết quả parse/validate.';
COMMENT ON COLUMN model_responses.raw_response_text IS 'Lưu nguyên văn để truy vết JSON lỗi hoặc phản hồi bị cắt cụt.';
COMMENT ON COLUMN model_responses.draft_solution IS 'Lời giải nháp được trả về trong response nếu cấu hình thực nghiệm yêu cầu.';

-- ============================================================
-- 9. KẾT QUẢ ĐÁNH GIÁ
-- Một response có thể được đánh giá lại nhiều lần khi thay đổi bộ chấm,
-- vì vậy không đặt UNIQUE(response_id).
-- ============================================================
CREATE TABLE evaluations (
    evaluation_id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    response_id         BIGINT NOT NULL REFERENCES model_responses(response_id) ON DELETE CASCADE,
    answer_key_id       BIGINT NOT NULL REFERENCES answer_keys(answer_key_id) ON DELETE RESTRICT,
    evaluator_version   VARCHAR(100) NOT NULL DEFAULT 'v1',
    earned_score        NUMERIC(8, 4) CHECK (earned_score IS NULL OR earned_score >= 0),
    max_score           NUMERIC(8, 4) CHECK (max_score IS NULL OR max_score >= 0),
    accuracy            NUMERIC(7, 4) CHECK (accuracy IS NULL OR (accuracy >= 0 AND accuracy <= 1)),
    data_type_valid     BOOLEAN NOT NULL DEFAULT FALSE,
    evaluated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    question_results    JSONB NOT NULL DEFAULT '{}'::JSONB,
    evaluation_notes    TEXT,
    CHECK (earned_score IS NULL OR max_score IS NULL OR earned_score <= max_score),
    CHECK (jsonb_typeof(question_results) = 'object')
);

COMMENT ON TABLE evaluations IS 'Kết quả chấm đáp án, độ chính xác và tuân thủ kiểu dữ liệu.';
COMMENT ON COLUMN evaluations.accuracy IS 'Tỷ lệ chính xác từ 0 đến 1; có thể để NULL nếu chưa tính.';
COMMENT ON COLUMN evaluations.question_results IS 'Kết quả theo từng câu, bao gồm điểm từng ý nếu có.';

-- ============================================================
-- 10. PHÂN TÍCH LỖI
-- Phân loại lỗi phục vụ phân tích nguyên nhân và cải tiến prompt.
-- ============================================================
CREATE TABLE error_analyses (
    error_analysis_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    evaluation_id     BIGINT NOT NULL REFERENCES evaluations(evaluation_id) ON DELETE CASCADE,
    error_category    VARCHAR(50) NOT NULL
                      CHECK (error_category IN (
                          'VISUAL_HALLUCINATION',
                          'KNOWLEDGE_GAP',
                          'LOGICAL_REASONING_FAILURE',
                          'JSON_FORMAT_ERROR',
                          'SCHEMA_TYPE_ERROR',
                          'OTHER'
                      )),
    error_description TEXT NOT NULL,
    evidence          JSONB NOT NULL DEFAULT '{}'::JSONB,
    suggested_cause   TEXT,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK (jsonb_typeof(evidence) = 'object')
);

COMMENT ON TABLE error_analyses IS 'Ghi nhận loại lỗi, bằng chứng và nguyên nhân giả định để truy vết.';
COMMENT ON COLUMN error_analyses.suggested_cause IS 'Nguyên nhân đề xuất sau phân tích; không mặc định là kết luận chắc chắn.';

-- ============================================================
-- 11. CHỈ MỤC PHỤC VỤ TRUY VẤN / THỐNG KÊ
-- ============================================================
CREATE INDEX idx_exams_year ON exams(exam_year);
CREATE INDEX idx_answer_keys_exam ON answer_keys(exam_id);
CREATE INDEX idx_runs_exam_started ON experiment_runs(exam_id, started_at DESC);
CREATE INDEX idx_runs_status ON experiment_runs(status);
CREATE INDEX idx_api_calls_run ON api_calls(run_id);
CREATE INDEX idx_api_calls_section_status ON api_calls(section_id, status);
CREATE INDEX idx_api_calls_model ON api_calls(model_config_id);
CREATE INDEX idx_api_calls_requested_at ON api_calls(requested_at DESC);
CREATE INDEX idx_model_responses_api_call ON model_responses(api_call_id);
CREATE INDEX idx_model_responses_json_valid ON model_responses(json_valid, schema_valid);
CREATE INDEX idx_evaluations_response ON evaluations(response_id);
CREATE INDEX idx_evaluations_answer_key ON evaluations(answer_key_id);
CREATE INDEX idx_errors_category ON error_analyses(error_category);

-- GIN indexes cho các trường JSONB thường dùng để lọc/truy vấn.
CREATE INDEX idx_prompt_parameters_gin ON prompt_configs USING GIN (prompt_parameters);
CREATE INDEX idx_answer_data_gin ON answer_keys USING GIN (answer_data);
CREATE INDEX idx_parsed_result_gin ON model_responses USING GIN (parsed_result);
CREATE INDEX idx_question_results_gin ON evaluations USING GIN (question_results);

-- ============================================================
-- 12. DỮ LIỆU DANH MỤC BAN ĐẦU
-- ============================================================
INSERT INTO exam_sections
    (section_code, section_name, description, default_question_count, answer_schema, display_order)
VALUES
    (
        'PART_I',
        'Phần I - Trắc nghiệm nhiều lựa chọn',
        'Mỗi câu chọn một phương án trong các lựa chọn.',
        12,
        '{"type":"object","required":["answers"],"properties":{"answers":{"type":"array","items":{"type":"object","required":["question_no","answer"],"properties":{"question_no":{"type":"integer"},"answer":{"type":"string"}}}}}}'::JSONB,
        1
    ),
    (
        'PART_II',
        'Phần II - Trắc nghiệm đúng/sai',
        'Mỗi câu có các mệnh đề cần xác định đúng hoặc sai.',
        NULL,
        '{"type":"object","required":["answers"],"properties":{"answers":{"type":"array","items":{"type":"object","required":["question_no","statements"],"properties":{"question_no":{"type":"integer"},"statements":{"type":"array"}}}}}}'::JSONB,
        2
    ),
    (
        'PART_III',
        'Phần III - Trả lời ngắn',
        'Thí sinh nhập kết quả ngắn gọn cho từng câu.',
        NULL,
        '{"type":"object","required":["answers"],"properties":{"answers":{"type":"array","items":{"type":"object","required":["question_no","answer"],"properties":{"question_no":{"type":"integer"},"answer":{"type":["string","number"]}}}}}}'::JSONB,
        3
    );

-- ============================================================
-- 13. VÍ DỤ DỮ LIỆU CẤU HÌNH (tùy chọn)
-- Có thể xóa phần này nếu chỉ muốn tạo cấu trúc bảng.
-- ============================================================
INSERT INTO prompt_configs
    (prompt_name, strategy, version, system_prompt, prompt_parameters, description, is_active)
VALUES
    (
        'Baseline - JSON',
        'BASELINE',
        1,
        'Giải các câu hỏi Toán trong phần được cung cấp. Trả lời đúng cấu trúc JSON được yêu cầu.',
        '{"require_json":true,"include_draft_solution":false,"scope":"section"}'::JSONB,
        'Đường cơ sở để so sánh với các chiến lược prompt khác.',
        TRUE
    ),
    (
        'Few-shot - JSON',
        'FEW_SHOT',
        1,
        'Giải các câu hỏi Toán theo hướng dẫn và ví dụ mẫu. Trả lời đúng cấu trúc JSON được yêu cầu.',
        '{"require_json":true,"include_draft_solution":true,"scope":"section","few_shot_count":2}'::JSONB,
        'Cấu hình few-shot minh họa; cần điều chỉnh theo thiết kế thực nghiệm thực tế.',
        TRUE
    ),
    (
        'Dynamic Scope - JSON',
        'DYNAMIC_SCOPE',
        1,
        'Giải riêng phần thi được chỉ định. Chỉ trả về dữ liệu của phần đó theo schema JSON được cung cấp.',
        '{"require_json":true,"include_draft_solution":true,"scope":"dynamic_section","separate_api_call_per_section":true}'::JSONB,
        'Cấu hình phạm vi động; mỗi phần thi có thể được gọi API riêng.',
        TRUE
    );

INSERT INTO model_configs
    (provider, model_name, model_role, generation_parameters, is_active)
VALUES
    (
        'Google',
        'gemini-model-placeholder-speed',
        'SPEED_OPTIMIZED',
        '{"temperature":0,"response_mime_type":"application/json"}'::JSONB,
        FALSE
    ),
    (
        'Google',
        'gemini-model-placeholder-reasoning',
        'REASONING',
        '{"temperature":0,"response_mime_type":"application/json"}'::JSONB,
        FALSE
    );

-- ============================================================
-- 14. VIEW THỐNG KÊ HIỆU NĂNG TỪNG LƯỢT THỰC NGHIỆM
-- ============================================================
CREATE VIEW v_experiment_performance AS
SELECT
    r.run_id,
    r.experiment_name,
    r.experiment_stage,
    e.exam_code,
    pc.prompt_name,
    pc.strategy,
    COUNT(DISTINCT ac.api_call_id) AS total_api_calls,
    COUNT(DISTINCT ac.api_call_id) FILTER (WHERE ac.status = 'SUCCESS') AS successful_api_calls,
    COUNT(DISTINCT ac.api_call_id) FILTER (WHERE ac.status <> 'SUCCESS') AS non_successful_api_calls,
    ROUND(AVG(ac.latency_ms)::NUMERIC, 2) AS avg_latency_ms,
    SUM(ac.input_tokens) AS total_input_tokens,
    SUM(ac.output_tokens) AS total_output_tokens,
    ROUND(AVG(ev.accuracy)::NUMERIC, 4) AS avg_accuracy,
    COUNT(DISTINCT mr.response_id) FILTER (WHERE mr.json_valid) AS json_valid_responses,
    COUNT(DISTINCT mr.response_id) FILTER (WHERE mr.schema_valid) AS schema_valid_responses
FROM experiment_runs r
JOIN exams e ON e.exam_id = r.exam_id
JOIN prompt_configs pc ON pc.prompt_id = r.prompt_id
LEFT JOIN api_calls ac ON ac.run_id = r.run_id
LEFT JOIN model_responses mr ON mr.api_call_id = ac.api_call_id
LEFT JOIN evaluations ev ON ev.response_id = mr.response_id
GROUP BY r.run_id, r.experiment_name, r.experiment_stage, e.exam_code, pc.prompt_name, pc.strategy;

COMMENT ON VIEW v_experiment_performance IS 'Tổng hợp độ chính xác, độ hợp lệ JSON, thời gian và token theo lượt chạy.';

-- ============================================================
-- 15. VIEW TỔNG HỢP LỖI THEO CHIẾN LƯỢC PROMPT
-- ============================================================
CREATE VIEW v_error_summary AS
SELECT
    pc.strategy,
    ea.error_category,
    COUNT(*) AS error_count
FROM error_analyses ea
JOIN evaluations ev ON ev.evaluation_id = ea.evaluation_id
JOIN model_responses mr ON mr.response_id = ev.response_id
JOIN api_calls ac ON ac.api_call_id = mr.api_call_id
JOIN prompt_configs pc ON pc.prompt_id = ac.prompt_id
GROUP BY pc.strategy, ea.error_category;

COMMIT;

-- ============================================================
-- 16. MỘT SỐ TRUY VẤN THAM KHẢO (chạy riêng sau khi tạo schema)
-- ============================================================

-- A. Xem danh mục phần thi:
-- SELECT section_code, section_name, default_question_count
-- FROM nckh_math.exam_sections ORDER BY display_order;

-- B. So sánh hiệu năng các lượt thực nghiệm:
-- SELECT * FROM nckh_math.v_experiment_performance ORDER BY run_id;

-- C. Đếm loại lỗi theo chiến lược:
-- SELECT * FROM nckh_math.v_error_summary ORDER BY strategy, error_count DESC;

-- D. Tỷ lệ phản hồi JSON hợp lệ theo phần thi:
-- SELECT s.section_code,
--        COUNT(*) AS response_count,
--        COUNT(*) FILTER (WHERE mr.json_valid) AS valid_json_count,
--        ROUND(
--          COUNT(*) FILTER (WHERE mr.json_valid)::NUMERIC / NULLIF(COUNT(*), 0),
--          4
--        ) AS json_valid_rate
-- FROM nckh_math.model_responses mr
-- JOIN nckh_math.api_calls ac ON ac.api_call_id = mr.api_call_id
-- JOIN nckh_math.exam_sections s ON s.section_id = ac.section_id
-- GROUP BY s.section_code
-- ORDER BY s.section_code;

-- E. Tìm các phản hồi có JSON/schema không hợp lệ:
-- SELECT ac.api_call_id, s.section_code, ac.status, mr.parse_status,
--        mr.json_valid, mr.schema_valid, mr.validation_errors, mr.raw_response_text
-- FROM nckh_math.model_responses mr
-- JOIN nckh_math.api_calls ac ON ac.api_call_id = mr.api_call_id
-- JOIN nckh_math.exam_sections s ON s.section_id = ac.section_id
-- WHERE NOT mr.json_valid OR NOT mr.schema_valid
-- ORDER BY mr.received_at DESC;

-- F. Đếm lỗi theo nhóm:
-- SELECT error_category, COUNT(*) AS total
-- FROM nckh_math.error_analyses
-- GROUP BY error_category
-- ORDER BY total DESC;
