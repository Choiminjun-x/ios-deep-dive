# iCloud 백업/복원 정리

> iOS 개발자 관점에서 정리한 iCloud 생태계와 백업/복원 메커니즘
>
> 작성일: 2026-09-23

---

## 1. iCloud의 두 축 — 동기화 vs 백업

같은 iCloud라는 이름을 쓰지만 **완전히 다른 메커니즘**이다. 이 구분이 모든 것의 출발점.

| 구분 | 동기화 (Sync) | 백업 (Backup) |
|---|---|---|
| 목적 | 여러 기기 간 실시간 데이터 공유 | 기기 복원용 스냅샷 |
| 개발자 개입 | 명시적으로 API 사용 (CloudKit 등) | 거의 자동 (제외 설정만 관리) |
| 동작 시점 | 앱 실행 중 또는 백그라운드 | 기기 잠금 + 충전 + Wi-Fi |
| 데이터 접근 | 앱이 직접 읽고 씀 | 앱은 접근 불가, 복원 시에만 사용 |
| 저장 용량 | 앱별 컨테이너 (사용자 iCloud 용량 차감, Public DB는 앱 쿼터) | 사용자 iCloud 용량 차감 |

> 💡 **백업은 "기기를 새로 샀을 때 되살리는 것", 동기화는 "iPhone에서 쓴 메모를 iPad에서 바로 보는 것"**

> 📌 iCloud로 **이미 동기화되는 데이터는 백업에 중복 포함되지 않는다.**
> (예: iCloud 사진이 켜져 있으면 사진은 백업 대상에서 빠짐)
> 앱 데이터도 iCloud Drive/CloudKit에 있으면 백업이 아니라 그쪽에 저장된다.

---

## 2. 백업 대상 — 디렉토리별 정리

| 경로 | 백업 | 용도 |
|---|:---:|---|
| `Documents/` | ✅ | 사용자가 직접 만든 데이터 (파일 앱 노출 가능) |
| `Library/Application Support/` | ✅ | 앱이 생성한 필수 데이터 (DB 파일 등) |
| `Library/Preferences/` | ✅ | UserDefaults (직접 건드리지 않음) |
| App Group 컨테이너 | ✅ | 확장(Extension)과 공유하는 데이터 |
| `Library/Caches/` | ❌ | 재생성/재다운로드 가능한 데이터 |
| `tmp/` | ❌ | 임시 파일 (시스템이 언제든 삭제) |
| `.app` 번들 (앱 바이너리) | ❌ | 복원 시 App Store에서 재다운로드 |

> ⚠️ `Caches/`는 **저장 공간 부족 시 시스템이 삭제**할 수 있다.
> "백업은 필요 없지만 지워지면 안 되는" 데이터는 `Caches`가 아니라
> **`Application Support` + `isExcludedFromBackup`** 조합이 정답.

---

## 3. `isExcludedFromBackup` — 백업 제외 처리

**대상**
재다운로드/재생성 가능한 대용량 데이터(오프라인 지도, 다운로드 영상, 모델 파일), 또는 백업에 남으면 안 되는 민감 데이터.

**동작**
파일/디렉토리에 붙는 **확장 속성(extended attribute)**. 따라서 **실제 파일이 존재하는 시점에 적용**되어야 하고, 앱을 한 번 실행해 플래그를 찍은 뒤 **다음 백업이 돌아야** 반영된다.

```swift
extension URL {
    func excludeFromBackup() throws {
        var url = self                      // setResourceValues는 mutating
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
}
```

### 권장: 파일이 아니라 디렉토리 단위로 제외

```swift
let secureDir = URL.applicationSupportDirectory
    .appending(path: "PaymentStore", directoryHint: .isDirectory)

try FileManager.default.createDirectory(at: secureDir, withIntermediateDirectories: true)
try secureDir.excludeFromBackup()          // 하위 파일 전체에 적용

let dbURL = secureDir.appending(path: "payment.sqlite")
```

### ⚠️ 주의사항

| 함정 | 설명 |
|---|---|
| **SQLite 부속 파일** | `.sqlite`만 제외하면 `-wal`, `-shm`에 남은 데이터가 그대로 백업된다. WAL 모드에서는 최근 트랜잭션이 통째로 `-wal`에 있을 수 있음 → **디렉토리 단위 제외로 해결** |
| **파일 재생성 시 유실** | DB를 삭제 후 재생성하는 마이그레이션 경로가 있으면 플래그를 다시 찍어야 함 |
| **심사 리젝** | 재다운로드 가능한 대용량 데이터를 백업 대상에 두면 iOS Data Storage Guidelines 위반 사례 있음 |

### 적용 검증

```swift
func verifyExcluded(_ url: URL) -> Bool {
    let values = try? url.resourceValues(forKeys: [.isExcludedFromBackupKey])
    return values?.isExcludedFromBackup ?? false
}

#if DEBUG
assert(verifyExcluded(secureDir), "백업 제외가 적용되지 않았습니다")
#endif
```

**육안 확인**
`설정 > Apple ID > iCloud > 저장 공간 관리 > 백업 > [기기]`에서 앱별 백업 용량 변화 확인.

---

## 4. Keychain 백업/복원

Keychain은 파일 데이터와 **규칙이 다르다.** 두 개의 축으로 나눠서 봐야 한다.

### 축 1 — 백업의 종류

| 백업 종류 | Keychain 복원 |
|---|---|
| **iCloud 백업** | Secure Enclave UID 파생 키로 암호화 → **백업을 만든 그 기기로만** 복원 가능 |
| **암호화된 Finder/iTunes 백업** | 백업 비밀번호로 재암호화 → **다른 기기로도** 복원 가능 |
| **암호화 안 된 Finder 백업** | 기기 고유 키 → 같은 기기만 |
| **iCloud 키체인 (동기화)** | 백업이 아닌 별도 경로. `kSecAttrSynchronizable = true` 항목만 해당 |

### 축 2 — Accessibility 속성

| 속성 | iCloud 백업<br>→ 같은 기기 | iCloud 백업<br>→ 다른 기기 | 암호화 Finder 백업<br>→ 다른 기기 | iCloud 키체인<br>동기화 |
|---|:---:|:---:|:---:|:---:|
| `...AfterFirstUnlock` | ✅ | ❌ | ✅ | ✅ (synchronizable 시) |
| `...AfterFirstUnlockThisDeviceOnly` | ✅ | ❌ | ❌ | ❌ |
| `...WhenPasscodeSetThisDeviceOnly` | ❌ (백업 미포함) | ❌ | ❌ | ❌ |

> 📌 **`ThisDeviceOnly` 계열은 UID로 보호**되어 다른 기기에 복원되더라도 복호화가 불가능하다.
> `WhenPasscodeSet...`은 백업에 아예 포함되지 않으며, 패스코드를 해제하면 항목이 삭제된다.

```swift
let query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrAccount as String: "deviceKey",
    kSecValueData as String: keyData,
    // 기기 고유 값 → 새 기기로 넘어가지 않도록
    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
]
SecItemAdd(query as CFDictionary, nil)
```

### 실무 판단 기준

| 데이터 성격 | 권장 속성 |
|---|---|
| 기기 식별 키, 생체인증 연동 키 | `...ThisDeviceOnly` (새 기기에 "유령 인증 상태"가 복원되는 것 방지) |
| 여러 기기에서 공유해야 할 로그인 토큰 | 일반 속성 + `kSecAttrSynchronizable = true` |
| 최고 수준 보호가 필요한 값 | `...WhenPasscodeSetThisDeviceOnly` |

> ⚠️ **Team ID 주의**
> Keychain access group은 `TeamID.bundleID` 형태다.
> bundle ID가 같아도 **서명 팀이 다르면 기존 Keychain 항목을 읽지 못한다.**

---

## 5. 백업/복원 메커니즘 — 바이너리는 백업되지 않는다

### 핵심

> **백업에 담기는 것은 앱의 샌드박스 컨테이너(데이터)일 뿐, `.app` 번들(실행 바이너리)이 아니다.**

Apple 공식 문서 표현으로는 **"기기에 설치한 앱들의 앱 데이터"**가 백업 대상이다.
앱 바이너리는 **Apple ID의 구매 이력(메타데이터)** 형태로만 기록된다.
백업 크기가 기기 사용량보다 항상 작은 이유.

### 복원 시퀀스

```
[1] 기기 초기화 → 백업 선택
      ↓
[2] 설정 / 홈 화면 레이아웃 / 앱 목록(bundle ID + App Store ID) 복원
      ↓
[3] 각 앱의 데이터 컨테이너를 bundle ID 기준으로 생성하고 채움
    ← 이 시점에 앱 데이터는 이미 디스크에 존재
      ↓
[4] 홈 화면에 회색 placeholder 아이콘 표시
      ↓
[5] App Store 구매 이력 있음 → 백그라운드 자동 다운로드 → 바이너리가 그 자리에 채워짐
    구매 이력 없음 → 가져올 곳을 모름 → "수동으로 다시 설치" 얼럿
```

**핵심:** 데이터 복원(3)과 바이너리 설치(5)는 **분리된 단계**다.
그래서 "데이터는 이미 있고 껍데기만 비어 있는" 상태가 존재한다.

### 설치 경로별 동작

iOS가 바이너리를 자동으로 채우려면 "이 bundle ID를 어디서 받아오는가"를 알아야 하고,
그 정보원은 **App Store 구매 이력뿐**이다.

| 설치 경로 | 구매 이력 | 복원 후 |
|---|:---:|---|
| App Store | ✅ | 자동 다운로드, 얼럿 없음 |
| TestFlight | ❌ | 얼럿 (App Store 구매가 아님) |
| 엔터프라이즈 (In-House) | ❌ | 얼럿 |
| Ad Hoc / Development | ❌ | 얼럿 |

> 이 얼럿은 **오류가 아니라 iOS의 정상 동작**이다.

### 데이터 재연결 조건

> **복원된 데이터 컨테이너와 새로 설치한 바이너리를 묶는 키는 bundle identifier.**

| 조건 | 데이터 연결 |
|---|---|
| bundle ID 동일 | ✅ |
| bundle ID 다름 (`.dev`, `.stg` suffix 등) | ❌ 별개 앱, 새 컨테이너 생성 |
| bundle ID 동일 + Team ID 다름 | ⚠️ 파일은 연결, **Keychain은 접근 불가** |

> ⚠️ **`placeholder 삭제 = 앱 삭제 = 컨테이너 삭제`**
> 회색 아이콘을 길게 눌러 지우면 복원된 데이터도 함께 사라진다.

---

## 6. 백업에 포함되지 않는 것 (자주 오해하는 항목)

| 항목 | 복원 후 |
|---|---|
| **앱 권한 승인 기록** (알림, 카메라, 위치 등) | iOS가 **기기 단위로 관리**하며 백업 미포함 → 다른 기기 복원 시 **항상 다시 묻는다.** 앱 데이터 복원과는 무관한 정상 동작 |
| 앱 바이너리 | App Store 재다운로드 또는 수동 설치 |
| iCloud로 이미 동기화되는 데이터 | 동기화 경로로 복원 |
| Apple Pay 카드 정보 | 재등록 필요 |
| Face ID / Touch ID 설정 | 재설정 필요 |

---

## 7. 핵심 요약

1. **동기화 ≠ 백업.** 목적도, 개발자 개입 방식도, 접근 경로도 다르다.
2. **백업에 앱 바이너리는 없다.** 데이터만 있고, 재연결 키는 bundle ID.
3. **복원은 2단계**(데이터 → 바이너리)이며 그 사이의 회색 아이콘 상태를 삭제하면 데이터도 사라진다.
4. **Keychain은 iCloud 백업으로 다른 기기에 넘어가지 않는다.** 기기 간 전달이 필요하면 `kSecAttrSynchronizable`(iCloud 키체인) 또는 암호화된 로컬 백업.
5. **백업 제외는 디렉토리 단위로**, 앱 실행 시 적용 → 다음 백업부터 반영.

---

## 📚 참고 자료

- Apple Support — *What does iCloud back up?*
- Apple Support — *Backup methods for iPhone or iPad*
- Apple Developer — *Optimizing Your App's Data for iCloud Backup*
- Apple Platform Security — *iCloud Backup security*
- Apple Platform Security — *Keychain data protection*
- Apple Developer Forums — thread 93373 (iCloud 백업의 Keychain 복원 제약, DTS 답변)
