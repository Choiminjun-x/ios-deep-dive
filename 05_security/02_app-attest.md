# App Attest

> 작성일: 2026-10-14

## 큰 그림

App Attest는 서버로 오는 요청이 "실제 Apple 기기에서 실행 중인 정품 우리 앱"이 보낸 것인지 서버가 검증할 수 있게 해주는 Apple의 앱 무결성 검증 기능이다.

최초 1회 Secure Enclave에서 만든 키를 Apple 인증서로 보증받아 서버에 등록하고, 이후 요청마다 그 키로 서명해 서버가 검증한다.

- "보안 솔루션"보다 "검증 기능"이 기대치에 맞는 표현 (혼자서 어뷰징을 다 막는 게 아님)
- "변조되지 않은 요청"보다 "정품 앱이 보낸 요청"이 본질. 바디 변조 방지는 부가 효과

```
[등록 · 1회]  generateKey → challenge → attestKey(Apple 보증) → 서버가 검증 → 공개키 저장
[요청 · 매번] challenge → generateAssertion(기기 안 서명) → 요청 + assertion → 서버가 공개키로 검증
```

## 1. 기본 개념

### 증명 대상

- Team ID + Bundle ID로 식별되는 우리 앱
- Secure Enclave가 있는 실제 Apple 기기에서 실행 중
- 배포 경로(App Store)를 증명하는 게 아님. 개발 빌드도 개발 환경(development)으로 attestation 생성

### Attestation과 Assertion

- Attestation (최초 등록): 이 앱 인스턴스의 키를 신뢰할 수 있는지 서버가 확인하는 과정
- Assertion (이후 요청 검증): 이미 등록된 키로 개별 요청이 해당 앱 인스턴스에서 생성되었음을 확인하는 과정

| | 등록 (Attestation) | 요청 (Assertion) |
|---|---|---|
| 횟수 | 앱 인스턴스당 1회 | 보호 API 호출마다 |
| 메서드 | `attestKey(keyId, clientDataHash)` → attestation | `generateAssertion(keyId, clientDataHash)` → assertion |
| Apple 서버 | 거침 | 거치지 않음 (기기 안에서 서명) |
| 해시 대상 | challenge | 요청 바디 + challenge |
| 서버 API | 신규 (challenge 발급, 등록) | 기존 보호 API에 헤더 추가 |

- assertion은 "재서명"이 아니라 요청마다 새로 하는 서명 (바디·challenge가 매번 다르고 counter도 증가)

### 앱 인스턴스(키) 등록

- "기기 등록"보다 "앱 인스턴스(키) 등록"이 정확한 표현
- 키는 기기의 사용자 계정마다 하나씩 생성한다. 한 기기에서 여러 계정이 키를 공유하지 않는다 (공유하면 탈취한 기기 하나로 여러 원격 사용자를 흉내 내는 공격을 탐지하기 어려워짐)
- 일반 앱 업데이트에서는 유지되지만, 재설치하면 새 키 필요. 백업 복원·기기 이전으로 키가 따라가지 않음

### 키 정리

| | 위치 | 역할 |
|---|---|---|
| 개인키 | Secure Enclave (밖으로 안 나감) | 요청마다 서명 |
| 공개키 | 서버 DB (등록 때 저장) | 서명 검증 |
| keyId | 앱 저장소 + 서버 DB | 키 쌍을 가리키는 이름표 |

```
           keyId (키 쌍의 이름표)
          ┌──────┴──────┐
     기기 (SE)          서버 DB
   keyId → 개인키     keyId → 공개키
   (서명할 때)        (검증할 때)
```

- keyId = 공개키(X9.62 비압축 형식)의 SHA-256 해시를 Base64로 만든 식별자 문자열
- keyId만으로 공개키를 거꾸로 계산할 수 없음 → 서버는 등록 때 공개키를 keyId와 함께 저장해야 함
- 등록은 "공개키를 믿을 수 있게 만드는 과정", 개인키가 실제로 일하는 건 요청 때의 서명

### 알고리즘

- ECDSA P-256 + SHA-256 (비대칭키 기반 전자서명 알고리즘)
- 비대칭키 암호(공개키 암호): 대칭키 암호의 반대 개념, 키 두 개를 쌍으로 사용
- 전자서명(디지털 서명): 개인키로 서명, 공개키로 검증하는 용도
- ECDSA = Elliptic Curve Digital Signature Algorithm (타원곡선 전자서명 알고리즘)
- P-256(secp256r1): Secure Enclave가 지원하는 곡선
- 개인키(Secure Enclave)로 서명하고, 공개키(서버)로 검증한다. 검증에 통과하면 등록된 그 앱 인스턴스가 보낸, 변조되지 않은 요청임이 보장된다
- 서명은 암호화가 아님: 서버는 서명을 "여는" 게 아니라 데이터·서명·공개키로 참/거짓을 판정
- 요청 바디는 서명과 별도로 평문으로 함께 전송됨

## 2. 등록 흐름 (Attestation)

```
클라이언트                     Apple 서버              우리 서버
   │ ① generateKey()                                    │
   │   → keyId 반환 (개인키는 Secure Enclave 안에만)    │
   │ ② challenge 요청 ────────────────────────────────→ │ 일회용 랜덤값 발급
   │ ←─────────────────────────────────────── challenge │
   │ ③ clientDataHash = SHA256(challenge)               │
   │ ④ attestKey(keyId, clientDataHash) ──→ │            │
   │ ←──────────────── attestation 객체 ─── │            │
   │ ⑤ attestation + keyId 전송 ──────────────────────→ │ ⑥ 검증
   │                                                    │ ⑦ 공개키·keyId·counter(0) 저장
```

### ① generateKey()

- keyId만 반환. 공개키를 돌려주는 API는 없음
- 공개키는 이후 attestation 객체 안 인증서에 담겨 서버로 전달됨
- keyId는 나중에 다시 얻을 방법이 없으므로 바로 영구 저장소에 기록

### ② challenge

- 우리 서버가 발급하는 일회용 랜덤값 (Apple이 발급하지 않음)
- 키와 무관하므로 ①과 순서를 바꾸거나 동시에 해도 됨
- 서버는 발급 기록을 보관하고, 한 번 쓰면 폐기 + 짧은 만료 시간 적용 (재사용 방지)
- 우리 서버가 발급해야 하는 이유: 서버가 직접 만든 값이어야 발급 기록과 대조하고 폐기할 수 있음
- 길이는 최소 16바이트 (추측할 수 없을 만큼)

### ③ clientDataHash

| 단계 | clientDataHash |
|---|---|
| 등록 | `SHA256(challenge)` |
| 요청 | `SHA256(요청 바디 + challenge)` |

### ④ attestKey(keyId, clientDataHash)

- iOS가 내부적으로 Apple App Attest 서버와 통신해 attestation 객체를 받아옴
- 앱은 메서드 하나만 호출, Apple로 무엇을 보낼지는 신경 쓰지 않음
- Apple과 통신하는 건 앱 인스턴스당 최초 등록 한 번뿐
- 네트워크 필요. Apple 장애 시 `serverUnavailable` → 같은 키로 재시도
- `serverUnavailable` 외의 오류는 keyId를 버리고 새 키로 처음부터
- 한 번 attest에 성공한 키는 다시 attest 불가 → 재등록은 새 키로
- Apple 측 호출량 제한 있음 → 전체 사용자에게 점진적으로 적용 권장

### ⑤ attestation + keyId 전송

- attestation 객체 = Apple이 서명한 증명서. 안에 인증서(공개키)와 challenge 해시
- 앱은 열어보지 않고 그대로 전달 (클라이언트 개발자는 내부 구조를 몰라도 됨)
- 공개키는 앱이 "모르는" 게 아니라 "꺼내 쓸 일이 없는" 것. 서버가 인증서를 파싱해 꺼냄
- 공개키가 Apple 서명 인증서 안에 있어야 서버가 믿을 수 있음 (앱이 공개키를 그냥 보내면 공격자도 아무 키나 보낼 수 있음)

```
POST /app-attest/register
{
  "keyId": "Base64 문자열",
  "attestation": "Base64 인코딩된 attestation 객체",
  "challenge": "②에서 받은 challenge (또는 challenge ID)"
}
```

- challenge를 보내는 이유: attestation 안에는 challenge 원문이 없고 해시만 있음. 세션에 묶어 서버가 이미 알고 있다면 생략 가능
- 로그인 후 등록이면 인증 토큰도 함께 보내 계정과 연결

### attestation 객체 구조 (서버 개발자용 참고)

```
attestation 객체 (CBOR 형식)
├ fmt: "apple-appattest"
├ attStmt
│  ├ x5c: [ 리프 인증서, 중간 인증서 ]   ← Apple이 서명
│  │        └ 리프 인증서 안에 공개키, nonce
│  └ receipt                            ← 위험 지표 조회용 (선택)
└ authData
   ├ rpIdHash   = SHA256(TeamID.BundleID)
   ├ counter    = 0
   ├ aaguid     = 운영 / 개발 환경
   └ credentialId = keyId
```

### ⑥ 서버 검증

- 선행 조건: 서버가 Apple App Attestation Root CA 인증서를 미리 보유
- 검증 시 Apple 서버 호출 없음 (브라우저의 HTTPS 인증서 확인과 같은 방식)

```
Apple 루트 인증서 (서버가 미리 보유)
   └ 서명 → 중간 인증서 (attestation 안)
              └ 서명 → 리프 인증서 (attestation 안, 공개키가 여기)
```

| 순서 | 검증 내용 | 막는 공격 |
|---|---|---|
| 1 | 인증서 체인이 Apple App Attestation Root CA로 이어지는가 | 위조된 증명서 |
| 2 | `SHA256(authData ‖ SHA256(challenge))`가 인증서의 nonce와 같은가 | 예전 attestation 재사용 |
| 3 | 인증서 공개키의 해시 = keyId = credentialId 인가 | 다른 키로 바꿔치기 |
| 4 | rpIdHash가 우리 앱 ID의 해시인가 | 다른 앱에서 만든 증명서 |
| 5 | counter = 0, aaguid가 기대한 환경인가 | 개발 빌드로 운영 서버 접근 |

### ⑦ 저장 및 응답

- 저장 항목: keyId, 공개키, counter(0), receipt
- 같은 공개키가 이미 다른 사용자와 연결돼 있지 않은지 확인
- 한 사용자에게 기기별로 여러 (key, receipt) 쌍이 생길 수 있음. 개발 환경과 운영 환경 쌍은 따로 보관
- challenge 폐기 후 성공 응답

### 응답 이후 클라이언트

- 성공: keyId와 등록 완료 상태 저장, 이후 assertion만 생성
- 실패
  - 네트워크 오류 → 같은 attestation으로 재전송 (challenge 만료 전)
  - 검증 실패 → 새 키로 등록 다시 시작

Apple이 주는 "등록 완료" 값은 없으므로 앱이 직접 관리한다.

```swift
keyId      : String   // generateKey() 결과
isAttested : Bool     // 서버 등록 성공 여부 (앱이 직접 기록)
```

## 3. 요청 흐름 (Assertion)

```
클라이언트                                         우리 서버
   │ ① (권장) challenge 요청 ───────────────────────→ │
   │ ② clientData = 요청 바디 + challenge            │
   │    clientDataHash = SHA256(clientData)          │
   │ ③ generateAssertion(keyId, clientDataHash)      │  ← 로컬 서명(SE 개인키), Apple 미개입
   │ ④ 요청 + assertion + keyId 전송 ────────────────→ │ ⑤ 검증
```

### SHA256(바디 + challenge)

- 저장된 keyId·isAttested 확인 → 미등록이면 등록부터 진행
- 바디 = 보호 대상 API에 보내는 HTTP 요청 본문
- challenge를 바디의 필드로 넣고, 바디 전체를 해시
- 앱과 서버가 완전히 같은 바이트를 해시해야 함 (JSON 키 순서·공백이 달라지면 정상 요청도 실패)
- 보통 서버는 받은 원본 바이트를 그대로 해시

### generateAssertion()

- Secure Enclave가 keyId로 개인키를 찾아, counter를 1 올리고, 서명
- 네트워크를 쓰지 않음 (오프라인에서도 생성, 빠름)
- 서명 대상 = `SHA256(authenticatorData ‖ SHA256(바디 + challenge))` → 서명 하나로 요청 내용과 counter를 함께 보증

```
assertion
├ signature          ← 개인키로 만든 서명 (ECDSA: 숫자 r, s 두 개. DER 형식 약 72바이트)
└ authenticatorData  ← 서명 당시 기기 정보 (37바이트)
   ├ rpIdHash  (32B) = SHA256(TeamID.BundleID)
   ├ flags     (1B)
   └ counter   (4B)
```

- assertion에 해시 값은 들어 있지 않음 (서버가 바디 원문으로 직접 계산)

### 요청 형태

- 실제 전송 = 바디 원문(challenge 포함) + assertion + keyId
- 해시는 보내지 않음. 해시를 받아서 믿으면 바디가 바뀌어도 알 수 없기 때문
- 신규 API가 아니라 기존 보호 API에 헤더 추가

```
POST /coupons/issue
X-AppAttest-KeyId: <keyId>
X-AppAttest-Assertion: <Base64 assertion>

{ "couponId": "C-1001", "amount": 5000, "challenge": "..." }
```

### 서버 검증

1. 받은 바디 원문으로 `SHA256(바디 + challenge)` 계산
2. assertion의 authenticatorData와 묶어 서명 대상을 다시 만듦
3. 공개키, 다시 만든 서명 대상, 앱이 보낸 서명 세 가지를 넣고 "이 서명이 이 대상에 대해 짝이 되는 개인키로 만든 것인가"를 참/거짓으로 판정
4. rpIdHash가 우리 앱인지, counter가 저장값보다 큰지 확인
5. challenge가 발급한 미사용 값인지 확인 후 폐기
6. 통과하면 비즈니스 로직 실행

- 서버가 다시 만드는 건 "서명"이 아니라 "서명 대상" (서버는 개인키가 없어 서명을 만들 수 없음)
- 서명끼리 비교하는 게 아님. ECDSA는 같은 대상에 서명해도 매번 r, s가 달라짐
- 앱은 서명 대상을 보내지 않음. 서버가 만든 대상이 앱이 서명할 때 쓴 대상과 같아야만 검증이 참
- 바디가 한 글자라도 바뀌면 서명 대상이 달라져 검증 실패, 개인키가 없어 새 서명도 만들 수 없음
- SHA-256은 입력이 1비트만 달라도 결과가 완전히 달라짐
- authenticatorData(counter)를 바꿔도 서명 대상이 달라져 실패

### 보호 API 호출 시 확인 순서

| | ① 등록 확인 | ② 서명 |
|---|---|---|
| 클라이언트 | 저장된 keyId·isAttested 확인 (미등록이면 등록부터) | `generateAssertion()` → 헤더에 첨부 |
| 서버 | keyId로 저장된 공개키 조회 (없으면 실패) | 공개키로 assertion 검증 → 통과 시 비즈니스 로직 |

- 이미 등록된 상태면 ①은 조회 한 번. 등록 흐름이 다시 도는 건 처음 한 번과 재등록 때뿐

### 실제 값으로 본 서명 예시

같은 알고리즘(P-256, SHA-256)으로 직접 만들어 본 값이다 (앱 ID는 예시). 개념 모델용 예시라서, 실제 기기 서명과 해시를 몇 번 거치는지까지 같은지는 확인 필요.

```
바디 = {"amount":5000,"challenge":"abc","couponId":"C-1001"}

H         = SHA256(바디)                     = 8619e240...f665
authenticatorData (37B)
  ├ rpIdHash (32B) = 92677d04...9b3e
  ├ flags    (1B)  = 40
  └ counter  (4B)  = 00000001
서명 대상 = SHA256(authenticatorData ‖ H)    = 49daea3a...cc2c

서명 (DER, 72B) = 3046 0221 00f5...
  ├ r (32B) = f52d1c4a...7586
  └ s (32B) = 9b4fe660...ba52
```

| 받은 바디 | 서버가 계산한 H | 공개키 검증 |
|---|---|---|
| `amount: 5000` (원본) | `8619e240...f665` | True |
| `amount: 50000` (변조) | `c3fabbf1...8b6b` | False |

- 서명 = 서명 대상(해시)을 개인키로 계산한 숫자 두 개(r, s)
- 서명 안에 해시가 숨어 있는 게 아님. r, s에서 해시나 바디를 거꾸로 꺼낼 수 없음

## 4. 재전송 방지: challenge와 counter

### counter

- assertion마다 Secure Enclave가 자동으로 1씩 증가 (앱이 관리할 필요 없음)
- 등록 시점 counter = 0
- 서버는 키마다 마지막 counter를 저장해 두고, 받은 값이 더 클 때만 통과시킨 뒤 갱신
- 막는 것
  - 재전송: 가로챈 assertion을 그대로 보내면 counter가 같거나 작아서 실패
  - 키 복제 시도: 같은 키로 두 곳에서 서명하면 counter 순서가 어긋나 탐지

### challenge와의 차이

| | 누가 만드나 | 확인하는 것 |
|---|---|---|
| challenge | 서버가 발급 | "방금 만든 요청인가" |
| counter | 기기(SE)가 증가 | "이전에 쓴 요청이 아닌가" |

- 둘 다 재전송 방지 목적, 함께 쓰면 더 확실함
- challenge는 서버가 발급하는 일회용 랜덤값. 등록이든 요청이든 "방금, 이 서버의 요청을 받고 만든 것"임을 증명

### 실무에서

challenge를 assertion에 공급하는 방식은 세 가지다.

| 방식 | 특징 |
|---|---|
| 매번 발급 | 왕복 1회 추가, 단순 |
| 응답에 다음 값 포함 | 왕복 없음, 복잡 |
| counter만 사용 | 비권장 |

- 만료 시간: 짧으면 느린 네트워크에서 실패, 길면 재사용 위험 시간 증가 (보통 1~5분 범위에서 결정)
- 발급 기록 저장소: 서버가 "내가 줬다"를 기억해야 대조·폐기 가능 (Redis 등)
- 세션·계정 묶기: A에게 준 값을 B가 가로채 쓰지 못하게
- 동시 요청은 counter 순서가 뒤바뀌어 정상 요청이 실패할 수 있음 → 보호 API 호출을 순차 처리하거나, 서버가 순서 역전을 어디까지 허용할지 정해야 함

## 5. 키 수명과 실패 처리

### 재설치 주의

- App Attest 키는 재설치 시 사라짐 (Keychain 항목은 남을 수 있음)
- 방법 1: 재설치 시 함께 지워지는 UserDefaults에 저장
- 방법 2: Keychain 사용 + `invalidKey` 받으면 재등록
- 기기 변경·백업 복원 시 UserDefaults도 복원될 수 있음 → 저장소와 무관하게 `invalidKey` 처리가 최종 안전장치
- 새 키 생성은 재설치·기기 이전·백업 복원·새 사용자 추가 때로 한정 (기기의 키 개수가 적어야 사기 탐지에 유리)

### 실패 케이스

등록 단계

| 케이스 | 원인 | 처리 |
|---|---|---|
| 미지원 | `isSupported == false` | 등록 시도 안 함 → 서버 정책 |
| challenge 발급 실패 | 네트워크·서버 장애 | 재시도 |
| `serverUnavailable` | Apple 장애, 네트워크 | 같은 키로 재시도 |
| `invalidKey` | 이미 attest된 키, 사라진 키 | 초기화 → 새 키로 처음부터 |
| `invalidInput` | 잘못된 clientDataHash | 코드 버그 → 로그, 새 키로 처음부터 |
| `unknownSystemFailure` | 시스템 오류 | 로그, 새 키로 처음부터 (횟수 제한) |
| 서버 전송 실패 | 네트워크 | 만료 전이면 같은 attestation 재전송 |
| challenge 만료 | 전송 지연 | 새 키로 처음부터 |
| 서버 검증 실패 | 위조, 환경 불일치 | 새 키로 재등록, 반복 시 중단 |

요청 단계

| 케이스 | 원인 | 처리 |
|---|---|---|
| `invalidKey` | 키 사라짐 | 재등록 후 1회 재시도 |
| 서버 검증 실패 | 키 기록 없음, 서명 불일치 | 재등록 후 1회 재시도, 반복 시 서버 정책 |
| 동시 요청 | counter 순서 뒤바뀜 | 보호 API 호출 순차 처리 |

키 상태 변화

| 케이스 | 결과 | 처리 |
|---|---|---|
| 앱 재설치 | 키 삭제. UserDefaults면 함께 삭제, Keychain이면 keyId 잔존 | 재등록 / `invalidKey` → 재등록 |
| 기기 변경·백업 복원 | 키는 안 따라감, UserDefaults는 복원될 수 있음 | `invalidKey` → 재등록 |

공통

| 케이스 | 위험 | 처리 |
|---|---|---|
| 재시도 무한 반복 | Apple·서버 호출 폭주 | 횟수 상한, 간격 두고 재시도 |

### 실무에서

프로젝트 세팅

1. Capability: 메인 앱 타깃에 App Attest 추가. Extension은 Action, extensible SSO, watchOS extension만 지원하고 나머지는 `isSupported`가 true여도 지원하지 않음
2. Entitlements: `com.apple.developer.devicecheck.appattest-environment` 키. Capability를 추가하면 `development`로 들어감. 이 값은 개발 서명 빌드에서만 의미가 있고, TestFlight·App Store·Enterprise 배포 빌드는 설정과 무관하게 항상 production
3. Deployment Target: iOS 14 이상
4. 프레임워크: `DeviceCheck`, `CryptoKit` import만 필요
5. 프로비저닝 프로파일: 재발급 필요 (인증서는 변경 없음). capability 추가 시 바뀌는 건 인증서가 아니라 프로비저닝 프로파일 (entitlement 목록을 담고 있음)
6. CI·팀 공유 프로파일도 함께 갱신

디버깅 포인트

- 시뮬레이터에서는 `isSupported`가 항상 false → 실기기 필수
- 저장소를 UserDefaults로 두면 재설치만으로 키 소멸 → 재등록 흐름을 확인하기 쉬움

등록 시점

| 시점 | 장점 | 단점 |
|---|---|---|
| 앱 최초 실행 | 보호 API 호출 시 이미 준비됨 | 계정 연결 안 됨, 불필요한 Apple 호출 |
| 로그인 직후 | 키를 계정에 바로 연결 | 로그인 흐름에 단계 추가 |
| 보호 API 첫 호출 직전 | 필요한 사용자만 등록 | 첫 호출 때 지연 |

## 6. 한계와 다른 방식

### 증명하지 못하는 것

- 정상 사용자인지 (정품 앱을 사람이 직접 조작하는 어뷰징, 다계정은 통과)
- 요청 내용이 비즈니스적으로 맞는지 (금액·한도 검증은 서버 몫)
- 탈옥·OS 변조 완벽 판별 (위험 신호 중 하나로 사용)
- 미지원 환경 (시뮬레이터 등 `isSupported == false`)
- → "누가 보냈는가"를 확인할 뿐, "무엇을 보냈는가"의 정당성은 판단하지 않음
- 미등록·검증 실패 시 API 호출을 막을지는 App Attest가 아니라 서버 정책이 결정 (차단 / 로그만 / 추가 검증)

### 실무에서

보호 대상 선정 기준

- 금전적 가치가 있다
- 앱 밖에서 자동화하기 쉽다
- 호출 빈도가 적당하다 (조회성 API는 부적합)

| API 유형 | 위협 | 적합도 |
|---|---|---|
| 혜택(쿠폰·포인트) 발급 | 스크립트로 대량 수령 | 높음 |
| 충전·결제 요청 | 한도 우회, 파라미터 조작 | 높음~중간 (금액 검증은 서버가 1차) |
| 송금·선물 | 자동화된 자금 이동 | 중간 |
| 회원가입·기기 등록 | 다계정 후 혜택 수령 | 중간 |
| 잔액·내역 조회 | 위협 낮고 빈도 높음 | 제외 |

검증 방식 비교

| | 직접 구현 | Firebase App Check |
|---|---|---|
| 서버 작업량 | 많음 (신규 API 2개 + 검증) | 적음 (토큰 검증만) |
| 증명 단위 | 요청마다 서명 | 토큰 (재사용 또는 일회용) |
| 바디 변조 검증 | 가능 | 불가 |
| Android 통합 | 별도 구현 | 한 구조로 가능 |
| 외부 의존 | 없음 | Google/Firebase |
| 세밀한 제어 | 높음 | 낮음 |

- Firebase App Check: 세션 토큰 유효 시간 30분~7일. 재전송 방지(일회용 토큰)는 베타이고 Node.js SDK만 지원

생체 서명 방식과의 관계

같은 Secure Enclave 서명 구조를 쓰지만, 생체 서명 방식은 "사용자가 인증했는가"를, App Attest는 "정품 앱이 보낸 요청인가"를 확인한다. 둘은 대체 관계가 아니라 보완 관계다.

| | 생체 서명 키 | App Attest 키 |
|---|---|---|
| 증명하는 것 | 사용자가 생체인증을 통과했다 | 정품 앱이 진짜 기기에서 보냈다 |
| 생성 API | `SecKeyCreateRandomKey` (SE 지정) | `DCAppAttestService.generateKey()` |
| 접근 제어 | `biometryCurrentSet` → 생체인증 통과해야 서명 | 설정 없음 → 앱이 사용자 개입 없이 서명 |
| 공개키를 믿는 근거 | 등록 때 비밀번호 확인 | Apple 인증서 (attestation) |
| 키 무효 | 생체 정보 변경, 재설치, 기기 변경 | 재설치, 기기 변경 |
| 적용 범위 | 생체 경로 거래 | 보호 대상 API 전체 |
| Android | Keystore로 같은 구조 | 별도 기술 (Play Integrity) |

| 공격 | 생체 서명 | App Attest |
|---|---|---|
| 탈취한 비밀번호로 스크립트에서 직접 등록·호출 | 통과 | 차단 |
| 정품 앱을 후킹해 생체인증을 건너뜀 | 차단 | 통과 가능 |

- 함께 쓰면 다층 방어. 두 키는 따로 관리, 재등록 흐름도 각각

도입 전 서버와 정할 것

1. 검증 방식: 직접 구현 / 외부 서비스
2. challenge 관리: 길이, 만료, 발급 기록 저장소, 세션·계정 묶기, assertion용 방식
3. 저장 단위: 계정 × 기기, 한 계정에 여러 키 허용 여부
4. 등록 시점
5. 적용 API
6. 실패 정책: 차단 / 로그만 / 추가 검증, 미지원 기기, Apple 장애, 초기와 안정화 이후
7. Android(Play Integrity)와 공통 구조로 맞출지

## 핵심 정리

- App Attest는 "정품 앱이 진짜 기기에서 보낸 요청인가"를 서버가 확인하게 해 주는 검증 기능이다. 요청 내용의 정당성은 판단하지 않는다
- 등록(attestation)은 1회, Apple이 공개키를 인증서로 보증한다. 요청(assertion)은 매번, Apple 없이 기기 안에서 서명한다
- 개인키는 Secure Enclave 밖으로 나가지 않고, 서버는 attestation 인증서에서 꺼낸 공개키로 서명을 검증한다
- 서버는 서명을 다시 만드는 게 아니라 바디 원문으로 서명 대상을 다시 만들어 참/거짓을 판정한다
- 재전송은 challenge("방금 만든 요청인가")와 counter("이전에 쓴 요청이 아닌가")로 막는다
- 키는 재설치·기기 이전·백업 복원에서 사라진다. `invalidKey` → 재등록이 최종 안전장치
- attestKey 오류는 `serverUnavailable`만 같은 키로 재시도, 나머지는 새 키로 처음부터

## 셀프 체크

Q. generateKey()가 반환한 공개키로 서버에 challenge를 요청하나?

A. 아니다. generateKey()는 keyId만 반환하고, challenge 요청에는 키가 필요 없다.

Q. challenge는 Apple 서버에 요청하나?

A. 아니다. 우리 서버가 발급한다. Apple이 개입하는 건 attestKey() 한 번뿐이다.

Q. challenge 때문에 신규 API를 만들어야 하나?

A. 직접 구현하면 challenge 발급, attestation 등록 API 2개가 신규. 보호 API는 기존 API에 검증만 추가.

Q. 앱이 공개키를 모르는데 서버는 어떻게 저장하나?

A. attestation 객체 안 인증서에 공개키가 있고, 서버가 파싱해서 꺼낸다.

Q. 개인키는 어디에 쓰이나?

A. assertion 서명. 공개키는 그 서명을 검증.

Q. keyId로 공개키·개인키 둘 다 찾나?

A. 기기에서는 개인키를, 서버에서는 공개키를 찾는 이름표. 키 자체가 들어 있지는 않다.

Q. 등록 확인 → 서명 확인 둘 다 하나?

A. 그렇다. 다만 등록 확인은 로컬·DB 조회 한 번이라 가볍다.

Q. 미등록·불가면 API 호출이 안 되나?

A. App Attest가 막는 게 아니라 서버 정책이 결정한다 (차단 / 로그만 / 추가 검증).

Q. 서버는 Apple 보증 증명서를 어떻게 검증하나?

A. 미리 보유한 Apple 루트 인증서로 인증서 체인을 확인한다. 검증 시 Apple 호출 없음.

Q. 요청 형태가 해시 + assertion + keyId인가?

A. 해시는 보내지 않는다. 바디 원문 + assertion + keyId.

Q. assertion의 "서명"은 해시를 서명한 것인가?

A. 서명 대상(authenticatorData + 바디 해시)을 개인키로 계산한 숫자 두 개.

Q. 서버가 서명을 다시 만들어 비교하나?

A. 서명 대상을 다시 만들고, 공개키로 참/거짓을 판정한다.

Q. 클라이언트 개발자가 attestation 내부 구조를 알아야 하나?

A. 몰라도 된다. 그대로 전달만 한다.

Q. attestKey()가 `unknownSystemFailure`를 반환하면 같은 키로 재시도하나?

A. 아니다. 같은 키로 재시도하는 건 `serverUnavailable`뿐이고, 나머지 오류는 keyId를 버리고 새 키로 시작한다.

Q. 한 기기에서 여러 계정이 로그인하면 키를 공유해도 되나?

A. 안 된다. 기기의 사용자 계정마다 키를 따로 만든다.

## 참고 자료

- [Establishing your app's integrity — Apple Developer](https://developer.apple.com/documentation/devicecheck/establishing-your-app-s-integrity)
- [Validating apps that connect to your server — Apple Developer](https://developer.apple.com/documentation/devicecheck/validating-apps-that-connect-to-your-server)
- [App Attest Environment entitlement — Apple Developer](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.devicecheck.appattest-environment)
- [Verify App Check tokens from a custom backend — Firebase](https://firebase.google.com/docs/app-check/custom-resource-backend)
