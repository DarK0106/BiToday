# BiToday 패키지 구조

> 요구사항분석서 v6 / ERD 초안 v1 기준
> Spring Boot + JPA / Hibernate + PostgreSQL + Redis

---

## 1. 도메인형을 선택한 이유

| | 계층형 | **도메인형 (채택)** |
| --- | --- | --- |
| 최상위 구조 | `controller/` `service/` `entity/` | `member/` `position/` `coin/` |
| 테이블 9개일 때 | 각 폴더에 파일 수십 개가 뒤섞임 | 도메인 경계가 코드에 그대로 드러남 |
| "포지션 코드 어디 있지?" | 3~4군데로 흩어짐 | 한 폴더 |
| 도메인 삭제·분리 | 전 폴더를 뒤져야 함 | 폴더 하나 |

테이블이 9개이므로 계층형은 금세 뒤엉킨다. 도메인형으로 간다.

---

## 2. 전체 구조

```
com.bitoday
├── BiTodayApplication.java
│
├── common/                공통 — 아무 도메인도 참조하지 않는다
│   ├── config/            Security, JPA, Redis, Scheduler, WebSocket
│   ├── exception/         전역 예외 처리
│   └── response/          공통 응답 포맷
│
├── auth/                  JWT 발급·검증, 로그인/로그아웃, Redis 블랙리스트 (M-02, M-03)
│
├── member/                회원 (M-01, M-04~M-07)
│   └── Member, MemberSocialAccount
│
├── point/                 포인트 잔고 (P-01)                        [경합 지점]
│   ├── MemberPoint
│   └── lock/              락 전략 구현체 — NFR-01 실험 대상
│
├── coin/                  코인 마스터 (C-01, C-02) — 가격 컬럼 없음
│
├── market/                외부 시세 연동 (C-03, C-06, C-07, MK, CH)
│   ├── MarketDataProvider 인터페이스 — 교체 가능성의 핵심
│   ├── upbit/             업비트 WebSocket·REST 구현체
│   └── MarkPriceStore     마크 가격 + 수신 시각 보관 (메모리 또는 Redis)
│
├── position/              포지션 (O-01~O-13)                        [경합 지점]
│   ├── Position, PositionExecution
│   └── calculator/        청산가·손익·증거금 계산
│
├── liquidation/           청산 엔진 (O-08, NFR-03, NFR-07)
│   ├── LiquidationScanner 주기 스캔
│   └── LiquidationService 청산 처리
│
├── season/                시즌 (S-01~S-05)
│   ├── Season, SeasonResult
│   └── settlement/        시즌 종료 정산 배치
│
├── attendance/            출석 (M-09, M-10) — 자동 처리, 트리거 3곳에서 호출됨
│
└── portfolio/             조회 전용 집계 (P-02~P-06)
```

도메인 패키지 내부는 `entity / repository / service / controller / dto` 로 나눈다. 파일이 적은 패키지는 굳이 하위 폴더를 만들지 않는다.

---

## 3. 핵심 결정

### 3-1. 여러 도메인을 가로지르는 기능은 별도 패키지로

**`liquidation`을 `position` 안에 넣지 않는다.**

청산은 `position`만 건드리는 작업이 아니다.

| 청산이 건드리는 것 | 소속 |
| --- | --- |
| 포지션 상태 변경 | `position` |
| 증거금 반환 (유지증거금만큼) | `point` |
| 체결 이력 기록 | `position` |
| 마크 가격 조회·신선도 확인 | `market` |

`position` 안에 넣으면 position 패키지가 다른 도메인을 전부 알게 되어 경계가 무너진다. 같은 이유로 `season/settlement`(시즌 정산)와 `portfolio`(총자산 집계)도 독립 패키지다.

부수 효과로 **청산 엔진이 최상위에 드러난다.** 이 프로젝트 학습 목표의 절반(NFR-03 경합 제어, NFR-07 처리량)이 거기 있으므로, 구조만 봐도 무엇을 다루는 프로젝트인지 보이는 편이 낫다.

### 3-2. 계산 로직은 엔티티 안에 둔다

Service가 아니라 `Position` 엔티티의 메서드로 둔다.

```
position.calculateUnrealizedPnl(markPrice)
position.calculateLiquidationPrice()
position.partialClose(quantity, markPrice)   // 검증 + 상태 변경
```

**이유 셋**

1. **검증을 빠뜨릴 수 없다.** "본인 소유 · 열린 상태 · 종료 수량 ≤ 보유 수량"(O-07, O-11)을 엔티티가 스스로 지킨다. Service에 두면 호출하는 쪽마다 검증을 반복해야 하고 한 군데만 빠뜨려도 뚫린다.
2. **NFR-03이 자연스러워진다.** "락 획득 후 상태 재확인 → OPEN일 때만 처리"가 엔티티 책임이 되므로, 수동 종료든 자동 청산이든 같은 메서드를 거친다.
3. **DB 없이 단위 테스트가 된다.** 청산가·손익 계산은 반드시 테스트해야 하는 부분인데, 엔티티 메서드면 객체만 만들어 바로 검증할 수 있다.

MMR(0.5%), 레버리지 허용값, `NUMERIC(24,8)` 반올림 규칙 같은 정책 상수는 별도 상수 클래스로 분리한다.

### 3-3. 락 전략을 설정으로 갈아끼운다

**NFR-01이 요구하는 비교 실험을 가능하게 하는 구조다.**

```
point/
├── PointService                     인터페이스
└── lock/
    ├── PessimisticPointService      SELECT ... FOR UPDATE
    ├── OptimisticPointService       @Version + 재시도
    └── DistributedLockPointService  Redis 분산 락
```

설정값 하나로 구현체를 교체할 수 있게 해두면, 부하 테스트에서 **코드 수정 없이 세 전략을 비교**할 수 있다. 전략마다 브랜치를 파거나 코드를 고쳐가며 측정하면 조건이 달라져 비교 자체가 무의미해진다.

> 포트폴리오 관점: "비관적 락을 썼습니다"보다 "세 전략을 교체 가능하게 만들고 부하 테스트 지표로 선택했습니다"가 훨씬 강하다. NFR-01의 문구도 그것을 요구한다.

---

## 4. 의존 방향 규칙

순환 참조를 막기 위한 규칙이다.

| 패키지 | 참조해도 되는 것 | 참조하면 안 되는 것 |
| --- | --- | --- |
| `common` | 없음 | **모든 도메인** |
| `market` | `common`, `coin` | 다른 도메인 전부 |
| `member` `coin` `season` | `common` | 서로, 그리고 상위 유스케이스 |
| `point` | `common`, `member`, `season` | `position`, `liquidation` |
| `attendance` | `common`, `member`, `point`, `season` | `auth`, `portfolio` (호출당하는 쪽) |
| `position` | `common`, `member`, `point`, `coin`, `market`, `season` | **`liquidation`, `portfolio`** |
| `liquidation` `portfolio` `season/settlement` | 아래 모든 도메인 | 서로 |

핵심은 **아래에서 위를 참조하지 않는 것**이다. `position`이 `liquidation`을 알게 되는 순간 둘이 엉켜 테스트도 분리도 어려워진다.

**`attendance`는 방향에 주의가 필요하다.** 출석은 자동 처리이므로 `auth`(로그인·토큰 갱신)와 `portfolio`(메인 조회)가 트리거가 된다. 그렇다고 `auth`가 `attendance`를 직접 import하면 인증이라는 하위 관심사가 출석이라는 도메인 기능을 알게 되어 어색하다. 두 가지 선택지가 있다.

| 방식 | 장점 | 단점 |
| --- | --- | --- |
| 직접 호출 (`auth` → `attendance`) | 단순, 흐름이 눈에 보임 | 의존 방향이 뒤집힘 |
| **Spring 이벤트** (`auth`가 이벤트 발행 → `attendance`가 구독) | 의존 방향이 깨끗함 | 흐름 추적이 간접적 |

어느 쪽이든 **출석 처리 실패가 로그인이나 조회를 막아서는 안 된다.** 예외를 삼키거나 이벤트를 분리해 트랜잭션 경계를 끊는다. 최종 선택은 구현 시점에 한다.

`market`이 아무 도메인도 참조하지 않는 점이 특히 중요하다. 외부 연동을 격리해야 `MarketDataProvider` 교체(업비트 → 바이낸스)가 실제로 가능하다.

---

## 5. 지금 만들 것 / 나중에 만들 것

**빈 패키지를 미리 13개 만들지 않는다.** 구조는 합의해두되 실제 폴더는 기능을 구현하면서 생기게 한다. 빈 껍데기가 쌓이면 무엇이 완성됐는지 보이지 않는다.

| 단계 | 필요한 패키지 |
| --- | --- |
| 1. 회원가입·로그인 | `common` `auth` `member` |
| 2. 포인트 잔고 | `point` |
| 3. 롱 진입 (1배) | `coin` `market` `position` |
| 4. 종료 | (3과 동일) |
| 5. 청산 엔진 | `liquidation` |
| 6. 부하 테스트 | `point/lock` 구현체 추가 |
| 7. 시즌·출석·포트폴리오 | `season` `attendance` `portfolio` |

구현 순서는 도메인 순서(M → C → O → P)가 아니라 **수직 슬라이스**다. `로그인 → 시세 수신 → 롱 진입 → 종료 → 청산`을 얇게 관통한 뒤 기능을 넓힌다. 이 관통이 끝나는 즉시 부하 테스트를 시작해야 한다 — 마지막으로 미루면 락 전략을 바꿔볼 시간이 없다.

---

## 6. 네이밍

| 종류 | 규칙 | 예 |
| --- | --- | --- |
| 엔티티 | 테이블명 파스칼케이스 | `MemberPoint`, `PositionExecution` |
| 리포지토리 | `~Repository` | `PositionRepository` |
| 서비스 | `~Service` | `LiquidationService` |
| 컨트롤러 | `~Controller` | `PositionController` |
| 요청/응답 DTO | `~Request` / `~Response` | `OpenPositionRequest` |
| 설정 | `~Config` | `RedisConfig` |

테스트는 `src/test/java` 아래에 **같은 패키지 구조를 그대로 미러링**한다.

> 주의: `position`은 패키지명으로는 문제없으나 **테이블명으로 쓸 때 PostgreSQL 예약어와 충돌할 수 있다.** 실제 DB 생성 시 확인하고, 걸리면 테이블명만 `trade_position`으로 바꾼다(패키지·클래스명은 유지).

---

## 7. 변경 이력

| 일자 | 내용 |
| --- | --- |
| 2026-10-20 | 최초 작성. 도메인형 채택, 가로지르는 기능 분리, 계산 로직 엔티티 배치, 락 전략 교체 구조, 의존 방향 규칙 정의 |
| 2026-10-20 | 출석을 자동 처리로 전환 — `attendance`가 `auth`·`portfolio`에서 트리거되는 구조가 되어 의존 방향 항목 추가 |
