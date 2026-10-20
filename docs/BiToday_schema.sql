-- ============================================================
--  BiToday 스키마 초안 v1  (PostgreSQL)
--  요구사항분석서 v5 + 2026-09-20 시즌제 반영
--  주의: 구현(JPA 엔티티) 단계에서 조정될 수 있는 초안입니다.
-- ============================================================

-- ------------------------------------------------------------
-- 1. season
-- ------------------------------------------------------------
CREATE TABLE season (
    id          BIGSERIAL     PRIMARY KEY,
    name        VARCHAR(50)   NOT NULL,
    seed_point  NUMERIC(24,8) NOT NULL,                  -- 시즌 시작 지급 포인트
    status      VARCHAR(20)   NOT NULL,                  -- UPCOMING / ACTIVE / ENDED
    started_at  TIMESTAMP,
    ended_at    TIMESTAMP,
    created_at  TIMESTAMP     NOT NULL DEFAULT now()
);

-- ------------------------------------------------------------
-- 2. member
--    login_id / password_hash 는 소셜 전용 가입을 위해 NULL 허용
-- ------------------------------------------------------------
CREATE TABLE member (
    id                BIGSERIAL    PRIMARY KEY,
    login_id          VARCHAR(50)  UNIQUE,
    password_hash     VARCHAR(100),
    nickname          VARCHAR(30)  NOT NULL UNIQUE,      -- 리더보드 식별
    email             VARCHAR(255) NOT NULL UNIQUE,
    profile_image_url VARCHAR(500),
    bio               VARCHAR(500),
    created_at        TIMESTAMP    NOT NULL DEFAULT now(),
    updated_at        TIMESTAMP    NOT NULL DEFAULT now()
);

-- ------------------------------------------------------------
-- 3. member_social_account
--    액세스 토큰은 저장하지 않음 (로그인 확인 용도뿐)
-- ------------------------------------------------------------
CREATE TABLE member_social_account (
    id          BIGSERIAL    PRIMARY KEY,
    member_id   BIGINT       NOT NULL,
    provider    VARCHAR(20)  NOT NULL,                   -- KAKAO / GOOGLE
    provider_id VARCHAR(100) NOT NULL,
    created_at  TIMESTAMP    NOT NULL DEFAULT now(),
    CONSTRAINT fk_social_member   FOREIGN KEY (member_id) REFERENCES member(id),
    CONSTRAINT uk_social_provider UNIQUE (provider, provider_id),  -- 복수 가입 차단
    CONSTRAINT uk_social_member   UNIQUE (member_id, provider)
);

-- ------------------------------------------------------------
-- 4. member_point   [경합 지점]
--    시즌별 잔고. 리셋 = 새 행 생성
-- ------------------------------------------------------------
CREATE TABLE member_point (
    member_id       BIGINT        NOT NULL,
    season_id       BIGINT        NOT NULL,
    available_point NUMERIC(24,8) NOT NULL,
    version         BIGINT        NOT NULL DEFAULT 0,    -- 낙관적 락 (JPA @Version)
    updated_at      TIMESTAMP     NOT NULL DEFAULT now(),
    CONSTRAINT pk_member_point     PRIMARY KEY (member_id, season_id),
    CONSTRAINT fk_point_member     FOREIGN KEY (member_id) REFERENCES member(id),
    CONSTRAINT fk_point_season     FOREIGN KEY (season_id) REFERENCES season(id),
    CONSTRAINT ck_point_nonnegative CHECK (available_point >= 0)   -- 동시성 최후 방어선
);

-- ------------------------------------------------------------
-- 5. coin
--    가격 컬럼 없음. 시세는 전부 업비트에서 수신
--    상장폐지는 DELETE 금지, is_active = false
-- ------------------------------------------------------------
CREATE TABLE coin (
    id            BIGSERIAL   PRIMARY KEY,
    market_code   VARCHAR(20) NOT NULL UNIQUE,           -- KRW-BTC
    symbol        VARCHAR(20) NOT NULL,
    korean_name   VARCHAR(50) NOT NULL,
    english_name  VARCHAR(50),
    is_active     BOOLEAN     NOT NULL DEFAULT TRUE,
    display_order INT,
    created_at    TIMESTAMP   NOT NULL DEFAULT now()
);

-- ------------------------------------------------------------
-- 6. position   [경합 지점]
--    헤지 모드: (member_id, coin_id) UNIQUE 걸지 말 것
--    미실현 손익은 컬럼 없음 (조회 시 계산)
-- ------------------------------------------------------------
CREATE TABLE position (
    id                BIGSERIAL     PRIMARY KEY,
    member_id         BIGINT        NOT NULL,
    season_id         BIGINT        NOT NULL,
    coin_id           BIGINT        NOT NULL,
    side              VARCHAR(10)   NOT NULL,            -- LONG / SHORT
    status            VARCHAR(20)   NOT NULL,            -- OPEN / CLOSED / LIQUIDATED
    leverage          INT           NOT NULL,
    entry_price       NUMERIC(20,8) NOT NULL,            -- 생성 후 불변
    quantity          NUMERIC(30,8) NOT NULL,            -- 부분 종료 시 감소
    margin            NUMERIC(24,8) NOT NULL,
    liquidation_price NUMERIC(20,8) NOT NULL,
    opened_at         TIMESTAMP     NOT NULL,
    closed_at         TIMESTAMP,
    version           BIGINT        NOT NULL DEFAULT 0,
    CONSTRAINT fk_position_member   FOREIGN KEY (member_id) REFERENCES member(id),
    CONSTRAINT fk_position_season   FOREIGN KEY (season_id) REFERENCES season(id),
    CONSTRAINT fk_position_coin     FOREIGN KEY (coin_id)   REFERENCES coin(id),
    CONSTRAINT ck_position_quantity CHECK (quantity >= 0),
    CONSTRAINT ck_position_leverage CHECK (leverage IN (1, 5, 25, 125))
);

-- 청산 엔진 대량 스캔 (NFR-07 핵심)
CREATE INDEX idx_position_liquidation ON position (status, coin_id, liquidation_price);
-- 보유 포지션 조회 (P-02)
CREATE INDEX idx_position_member      ON position (member_id, season_id, status);

-- ------------------------------------------------------------
-- 7. position_execution
--    append-only. UPDATE 하지 않음 → 경합 없음
--    member_id / season_id 는 조회 성능을 위한 비정규화 (불변값)
-- ------------------------------------------------------------
CREATE TABLE position_execution (
    id              BIGSERIAL     PRIMARY KEY,
    position_id     BIGINT        NOT NULL,
    member_id       BIGINT        NOT NULL,
    season_id       BIGINT        NOT NULL,
    type            VARCHAR(20)   NOT NULL,              -- ENTRY / PARTIAL_CLOSE / CLOSE / LIQUIDATION / SEASON_END
    quantity        NUMERIC(30,8) NOT NULL,
    price           NUMERIC(20,8) NOT NULL,
    realized_pnl    NUMERIC(24,8),                       -- 진입이면 NULL
    margin_released NUMERIC(24,8),                       -- 진입이면 NULL
    executed_at     TIMESTAMP     NOT NULL,
    CONSTRAINT fk_exec_position FOREIGN KEY (position_id) REFERENCES position(id),
    CONSTRAINT fk_exec_member   FOREIGN KEY (member_id)   REFERENCES member(id),
    CONSTRAINT fk_exec_season   FOREIGN KEY (season_id)   REFERENCES season(id)
);

-- 거래 내역 조회 (O-09)
CREATE INDEX idx_exec_member   ON position_execution (member_id, season_id, executed_at DESC);
-- 포지션별 체결 추적 / 정합성 검증
CREATE INDEX idx_exec_position ON position_execution (position_id, executed_at);

-- ------------------------------------------------------------
-- 8. attendance
--    UNIQUE(member_id, attended_date) 가 중복 지급 방어선
--    → 락 없이 제약만으로 해결되는 사례
-- ------------------------------------------------------------
CREATE TABLE attendance (
    id            BIGSERIAL     PRIMARY KEY,
    member_id     BIGINT        NOT NULL,
    season_id     BIGINT        NOT NULL,
    attended_date DATE          NOT NULL,
    reward_point  NUMERIC(24,8) NOT NULL,                -- 정책 변경 대비 스냅샷
    streak_count  INT           NOT NULL,
    created_at    TIMESTAMP     NOT NULL DEFAULT now(),
    CONSTRAINT fk_attendance_member FOREIGN KEY (member_id) REFERENCES member(id),
    CONSTRAINT fk_attendance_season FOREIGN KEY (season_id) REFERENCES season(id),
    CONSTRAINT uk_attendance_date   UNIQUE (member_id, attended_date)
);

-- ------------------------------------------------------------
-- 9. season_result
--    시즌 종료 시 배치로 1회만 기록 → 경합 없음
--    티어/순위는 소급 변경되면 안 되므로 스냅샷 저장
-- ------------------------------------------------------------
CREATE TABLE season_result (
    id            BIGSERIAL     PRIMARY KEY,
    season_id     BIGINT        NOT NULL,
    member_id     BIGINT        NOT NULL,
    final_point   NUMERIC(24,8) NOT NULL,                -- 시즌 종료 시 가용 포인트
    granted_point NUMERIC(24,8) NOT NULL,                -- seed + SUM(출석 보상)
    net_profit    NUMERIC(24,8) NOT NULL,                -- P-06 순수 거래 수익금
    final_rank    INT           NOT NULL,
    tier          VARCHAR(20),
    finalized_at  TIMESTAMP     NOT NULL,
    CONSTRAINT fk_result_season FOREIGN KEY (season_id) REFERENCES season(id),
    CONSTRAINT fk_result_member FOREIGN KEY (member_id) REFERENCES member(id),
    CONSTRAINT uk_result        UNIQUE (season_id, member_id)
);

-- 리더보드 (P-06)
CREATE INDEX idx_result_rank ON season_result (season_id, final_rank);
