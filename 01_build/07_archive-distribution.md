# Archive와 배포

> 작성일: 2026-10-12

## 큰 그림

Archive - 사용자에게 보낼 최종본을 만들어서 보관함에 넣는 것. 배포는 그 보관함에서 꺼내 포장해 보내는 것이다.

```
⌘R (Run)                    Product > Archive
  │                            │
  Debug 빌드                   Release 빌드 (WMO·최적화)
  │                            │
  내 폰/시뮬에 바로 설치        .xcarchive 생성 → Organizer에 보관
                               │
                               Distribute App (서명 + 포장 방법 고르기)
                               ├─ Upload → App Store Connect → TestFlight / App Store
                               └─ Export → .ipa 파일 → 직접 설치·배포
```

핵심 - 빌드(Archive)와 포장(Distribute)이 분리됨. 한 번 만든 Archive를 TestFlight 용으로도, 사내 테스트용 .ipa로도 다시 포장할 수 있다.

```
[Mac]          Archive → Distribute (서명 + 포장) → Upload
[Apple 서버]   Processing → 재서명·FairPlay·App Thinning → TestFlight / App Review → 출시
[사용자 기기]   Apple 서명 + 암호화된, 기기에 맞는 조각만 설치
[크래시 발생]   주소만 찍힌 로그 → dSYM으로 이름 번역
```

## 1. Archive 만들기

- Archive는 디버깅 정보를 포함한 앱 빌드를 하나의 번들로 저장한 것, Xcode는 고른 배포 설정에 맞춰 그 내용을 다시 포장한다
- `.xcarchive`는 사실 폴더, Finder > "패키지 내용 보기"로 열면 아래와 같이 생김

```
MyApp.xcarchive/
 ├─ Products/Applications/MyApp.app   ← 앱 본체 (Release 빌드 결과)
 ├─ dSYMs/                            ← 크래시 로그 해석용 "번역 사전" (6번)
 └─ Info.plist                        ← 버전·빌드 번호 등 메타데이터
```

### Archive는 Release 빌드 — 정확히는 "기본값이 Release"

스킴의 Archive 액션 기본 Build Configuration이 Release다 ([Xcode 프로젝트 구조와 빌드 설정](01_xcode-project-settings.md) 2번).

```
Edit Scheme
 ├─ Run     → Debug   (기본)
 ├─ Test    → Debug
 ├─ Profile → Release
 └─ Archive → Release  ← 바꿀 수 있음
```

- 바꿀 수 있으므로 "Archive = 무조건 Release"는 아니다. 스킴의 Archive 항목에 적힌 설정으로 빌드할 뿐이다
- "Release"라는 이름에 마법이 있는 게 아니라, 그 설정 안의 값(`-O`, WMO, dSYM 생성)이 결과를 정한다

Xcode 15부터는 실행 대상이 시뮬레이터여도 Archive할 수 있다. 그 기기 종류에 필요한 모든 CPU 아키텍처로 Archive한다. 예전처럼 "Any iOS Device"로 바꿀 필요가 없다.

### 실무에서

- Archive가 유독 오래 걸리는 건 Release 설정이라 WMO와 최적화가 켜지기 때문이다 ([Swift 컴파일러 내부와 모듈](06_swift-compiler-module.md) 4번)

## 2. Distribute — Upload vs Export

- Archive를 Export하면 App Store 밖에서 배포할 수 있다
- App Store Connect에 Upload하면 TestFlight나 App Store로 배포한다

`.ipa`는 iOS 기기에 앱을 설치하기 위해 사용하는 압축 파일 형식이다. 안드로이드의 `.apk` 파일과 같은 개념이다.

Organizer의 기본 선택지 (iOS 기준)

| 선택지 | 누구에게 | 결과 | 옛 이름 (Xcode 15.3 이전) |
|---|---|---|---|
| TestFlight & App Store | 베타 테스터, 일반 사용자 | Upload | App Store Connect |
| TestFlight Internal Only | 우리 팀만 | Upload | — |
| Release Testing | 등록된 기기 (QA) | .ipa Export | Ad Hoc |
| Debugging | 등록된 기기, 디버깅용 | .ipa Export | Development |
| Enterprise | 사내 직원 (별도 프로그램) | .ipa Export | Enterprise |

- TestFlight Internal Only는 개발용 빌드가 실수로 App Store에 제출되는 것을 막는 용도다

업로드 때 나오는 체크박스

- **Upload your app's symbols** — Apple이 크래시 로그를 함수 이름·줄 번호로 바꿔 준다. 끄면 Organizer > Crashes가 주소로만 나온다
- **Manage version and build number** — Xcode가 Archive 안 콘텐츠의 빌드 번호를 갱신한다. 업로드되는 .ipa만 바뀌고 프로젝트 파일은 그대로다

### 실무에서

- CI의 `ExportOptions.plist`의 `method` 값이 위 선택지다. Xcode 15.3에서 이름이 바뀌어서 옛 값을 쓰면 deprecated 경고가 뜬다 (아직 동작은 함)

```
app-store   → app-store-connect
ad-hoc      → release-testing
development → debugging
enterprise  → 그대로
```

## 3. 용도별 서명 — 인증서와 프로파일

용도마다 다른 건 코드가 아니라 서명(누가 어디에 설치할 수 있나)이고, 서명과 포장은 Distribute 단계에서 한다. 그래서 같은 빌드를 서명만 바꿔 다시 포장할 수 있다.

```
Archive (1번)
 └─ MyApp.app  ← 코드는 이미 완성
      │
      Distribute 때 용도에 맞는 서명 + 포장
      ├─ TestFlight & App Store → App Store용 서명 → Upload
      └─ Release Testing        → 등록 기기용 서명 → .ipa Export
```

서명 = 인증서(누가 만들었나) + 프로파일(어디에 설치할 수 있나)

| | 인증서 | 프로파일 | 기기 목록(UDID) |
|---|---|---|---|
| TestFlight & App Store | 배포 | App Store | 없음 |
| Release Testing (Ad Hoc) | 배포 | Ad Hoc | 있음 |
| Debugging (Development) | 개발 | Development | 있음 |

- App Store와 Ad Hoc은 **인증서는 같고 프로파일만 다르다**. 결정적 차이는 기기 목록이 들어 있느냐다
- Ad Hoc 앱은 번들 ID가 App ID와 맞고, 서명이 배포 인증서와 맞고, 기기가 프로파일의 기기 목록에 있어야 실행된다
- 서명 원리 자체는 [iOS 코드 서명](03_code-signing.md) 참고

### 실무에서

- QA가 ".ipa 설치가 안 돼요" → 그 기기 UDID가 Ad Hoc 프로파일에 없는 경우가 대부분이다. 기기 등록 → 프로파일 재생성 → **같은 Archive에서 다시 Distribute**. Archive는 다시 안 해도 된다

## 4. Version과 Build

General 탭의 Version, Build는 내부 이름이 다르다.

```
General 탭        Build Settings              Info.plist                     사용자에게
Version  2.3.0 → MARKETING_VERSION       → CFBundleShortVersionString  → App Store에 보이는 버전
Build    42    → CURRENT_PROJECT_VERSION → CFBundleVersion             → 안 보임 (업로드 구분용)
```

Xcode 11부터 General 탭에서 고친 값은 Build Settings에 저장되고, Info.plist에는 `$(MARKETING_VERSION)`, `$(CURRENT_PROJECT_VERSION)` 같은 변수가 들어간다.

| | Version | Build |
|---|---|---|
| 누구를 위한 번호 | 사용자 | Apple·개발팀 |
| 언제 올리나 | 새 버전 출시할 때 | 업로드할 때마다 |
| 예시 | 2.3.0 → 2.4.0 | 41 → 42 → 43 |

업로드할 때마다 Build는 바뀐다. Version은 새 출시일 때만 바뀐다. App Store Connect는 같은 버전 안의 빌드를 빌드 번호로 구분한다.

```
2.3.0 (41) → 2.3.0 (42) → 2.3.0 (43) → 2.4.0 (44) → 2.4.0 (45)
             버그 수정     버그 수정     새 출시
```

Version이 바뀔 때 Build를 1로 되돌려도 되는지는 공식 규칙을 확인하지 못했다. 실무에서는 헷갈리지 않게 계속 올리기만 하는 방식이 가장 흔하다.

### 실무에서

- "General에서 Version을 바꿨는데 Archive에 옛 값이 찍혀요" → Info.plist에 변수 대신 숫자가 직접 적혀 있는 경우다. 오래된 프로젝트에서 자주 생긴다
- 위젯 같은 확장 타깃도 각자 Version/Build가 있다. 본체와 맞춰야 업로드 경고가 안 난다

## 5. App Store Connect로 올린 이후, Apple 서버에서 일어나는 일

```
[Mac]  Archive → Distribute (서명 + 포장) → Upload
─────────────────────────────────────────────────────
[Apple 서버]
  ① Processing (검사 + 가공)
       │
  ② TestFlight
       ├─ 내부 테스터 (우리 팀)  → 처리 끝나면 바로
       └─ 외부 테스터            → TestFlight 심사 통과 후
       │
  ③ App Review (정식 심사) → App Store 출시
       │
  ④ 사용자 다운로드 → 자기 기기에 맞는 조각만 받음 (App Thinning)
```

**Processing - 올렸는데 바로 안 보이는 이유**

- 검사: 업로드 요건을 만족하는지 확인. 만족 못 하면 Invalid Binary가 되고 TestFlight에 아예 안 나타난다
- 가공: App Store가 추가 처리를 하면서 불법 복제 방지용 DRM을 넣고 바이너리를 다시 압축, 기기별 버전을 만든다 (8번)

**TestFlight - 내부 vs 외부**

| | 내부 | 외부 |
|---|---|---|
| 누구 | App Store Connect 팀원 (최대 100명) | 이메일, 공개 링크로 초대한 누구나 (최대 10,000명) |
| 심사 | 없음 | TestFlight 심사 필요 (Beta App Review) |
| 언제 받나 | Processing 끝나면 바로 | 심사 통과 후 |

외부 테스트는 앱 버전의 첫 빌드가 심사를 받는다.

**App Review -> 출시**

- TestFlight에서 검증한 그 빌드를 그대로 골라 심사에 제출, 새로 Archive하지 않는다

**App Thinning - 사용자는 일부만 받는다**

- Processing 과정에서 만든 기기별 버전 중 사용자 기기에 맞는 것만 내려준다 (해상도별 이미지, CPU 아키텍처 등)
- 그래서 `.app`, `.xcarchive`, 업로드한 `.ipa`는 앱 크기 측정에 쓰면 안 된다. dSYM처럼 사용자가 받지 않는 파일이 들어 있다

### 실무에서

- "업로드 성공했는데 TestFlight에 없어요" → Processing 중인지, Invalid Binary 메일이 왔는지 확인. 빌드 상태가 Missing Compliance면 암호화 수출 규정 질문에 답을 안 한 것이다

## 6. dSYM과 크래시 심볼리케이션

컴파일할 때 컴파일러가 "주소 ↔ 함수 이름·파일·줄 번호" 대응표를 만든다 (디버그 심볼).

```
Debug 빌드   → 대응표를 실행 파일 안에 같이 넣음   → Xcode 디버거가 바로 씀
Release 빌드 → 대응표를 dSYM 파일로 따로 뺌       → 앱은 가벼워지고, 사전은 내 Mac(Archive)에 남음

사용자 폰에서 크래시 → 앱엔 사전이 없음 → 크래시 로그에 주소만 찍힘
                    → 나중에 dSYM으로 주소를 이름으로 번역 (심볼리케이션)
```

Debug 빌드는 기본적으로 디버그 심볼을 바이너리 안에 넣고, Release 빌드는 배포하는 앱 크기를 줄이려고 심볼을 별도 dSYM 파일에 넣는다. 그래서 dSYM이 있어야 크래시 로그의 주소를 "코드 내 42번째 줄"로 바꿀 수 있다.

### Debug Information Format

이것을 정하는 빌드 설정이다.

| 값 | 뜻 | 보통 쓰는 곳 |
|---|---|---|
| DWARF | 대응표를 실행 파일 쪽에만 둠, dSYM 안 만듦 | Debug |
| DWARF with dSYM File | 대응표를 dSYM으로 따로 만듦 | Release |

DWARF는 대응표의 형식 이름이고, dSYM은 그걸 담는 봉투(번들)다. 배포 빌드 전에 이 설정이 DWARF with dSYM File인지 확인한다.

### dSYM은 "그 빌드 전용" 사전

```
Archive A → 실행 파일 (UUID: E3EA…)  ↔  dSYM (UUID: E3EA…)   ✅ 짝
Archive B → 실행 파일 (UUID: 7F21…)  ↔  dSYM (UUID: 7F21…)
```

- 실행 파일과 dSYM은 빌드 UUID로 묶여 있고, 같은 소스라도 Xcode 버전이나 빌드 설정이 다르면 UUID가 달라진다
- 그래서 "같은 커밋으로 다시 Archive해서 dSYM을 만들면 된다"가 안 된다. **배포한 빌드의 Archive는 반드시 보관한다**

### 심볼리케이션 - 주소를 이름으로

```
번역 전:  0  TouchCanvas  0x1045a19b4  0x10459c000 + 22964
번역 후:  0  TouchCanvas  0x1046a59b4  Line.updateRectForExistingPoint(_:) + 988
```

번역 경로

```
① TestFlight/App Store + 업로드 때 symbols 체크
   → Apple이 번역해서 Xcode Organizer > Crashes에 보여 줌 (제일 편함)

② 내 Mac에 맞는 dSYM이 있음
   → Xcode가 Spotlight로 UUID 맞는 dSYM을 찾아 자동 번역

③ 수동
   → xcrun crashlog <크래시 파일>  또는  atos (주소 하나씩)

①②③ 모두 안 되면 (Archive 버림) → 주소만 보임 → 사실상 분석 불가
```

주소로 남는 건 내 코드 줄만이 아니다. 줄의 주인에 따라 필요한 사전이 다르다.

| 줄의 주인 | 번역에 필요한 것 |
|---|---|
| 내 앱, 내 확장, 내 프레임워크 | 내 dSYM (UUID 일치) |
| 서드파티 바이너리 SDK | 그 SDK 제공자의 dSYM |
| UIKit 등 시스템 | 해당 iOS 버전의 기기 심볼 |

### 실무에서

- UUID 비교: 크래시 로그 맨 아래 Binary Images의 UUID와 dSYM의 UUID가 같은지 본다

```bash
dwarfdump --uuid MyApp.app.dSYM
```

## 7. dSYM 업로드 — Apple vs 서드파티

```
dSYM이 가는 곳
 ├─ Apple (App Store Connect)
 │    → 별도 업로드 아님. 앱 업로드할 때 "Upload your app's symbols" 체크로 같이 올라감
 │
 └─ 서드파티 (Crashlytics, Sentry 등)
      → 별도 업로드. Apple에 올린 걸 가져가지 않음
      → Xcode Build Phases의 Run Script, 또는 fastlane 같은 배포 스크립트가 올림
```

누락되는 경우

| 원인 | 어디서 | 증상 |
|---|---|---|
| Debug Information Format이 DWARF (dSYM 안 만듦) | 둘 다 | 애초에 dSYM이 없음 |
| Distribute 때 symbols 체크 해제 | Apple | Organizer 크래시가 주소로 나옴 |
| CI ExportOptions의 `uploadSymbols`가 false | Apple | 위와 같음 |
| Run Script 누락·실패·경로 오류 | 서드파티 | "Missing dSYM" 경고 |
| 서드파티 바이너리 SDK가 dSYM을 안 줌 | 둘 다 | 그 SDK 프레임만 주소로 남음 |
| 확장 타깃 dSYM만 빠짐 | 둘 다 | 위젯·알림 확장 크래시만 안 읽힘 |

Crashlytics Run Script는 Xcode 15부터 Input Files를 정확히 적어야 한다. User Script Sandboxing이 켜져 있으면 Xcode가 Input Files에 적힌 파일만 스크립트에 허용하기 때문이다.

```
${DWARF_DSYM_FOLDER_PATH}/${DWARF_DSYM_FILE_NAME}
${DWARF_DSYM_FOLDER_PATH}/${DWARF_DSYM_FILE_NAME}/Contents/Resources/DWARF/${PRODUCT_NAME}
${DWARF_DSYM_FOLDER_PATH}/${DWARF_DSYM_FILE_NAME}/Contents/Info.plist
$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/GoogleService-Info.plist
$(TARGET_BUILD_DIR)/$(EXECUTABLE_PATH)
```

### 실무에서

- 실제 사례: Firebase에 `dSYM 누락 - iOS <번들 ID> <Version> (<Build>)` 경고가 왔다. Run Script가 Firebase 문서의 수동 업로드 예시(`find dSYM_DIRECTORY …`)를 자리 표시 경로 그대로 쓰고 있어서, 빌드는 성공하고 업로드만 조용히 안 됐다. fastlane의 `upload_symbols_to_crashlytics`로 업로드를 옮겨 해결했다
- 이미 출시된 빌드는 설정을 고쳐도 소급되지 않는다. 보관한 Archive의 dSYMs 폴더를 Firebase 콘솔에 수동 업로드한다

## 8. FairPlay / 재서명

```
[내가 올린 .ipa]
  내 서명 (배포 인증서 + App Store 프로파일)
  = "이건 이 팀이 만든 게 맞다"는 제출용 신분증
        │
        ▼  Apple 서버
  ① 검사 (Processing, 심사)
  ② 재서명 → 내 서명을 Apple 서명으로 교체
  ③ FairPlay 암호화 → 실행 파일을 암호화 (DRM)
  ④ App Thinning → 기기별 버전으로 나눔
        │
        ▼
[사용자 기기에 설치되는 앱]
  Apple 서명 + 암호화된 실행 파일
```

### 재서명 — 내 신분증은 "제출할 때"만 쓰인다

- App Store 앱은 사용자 기기에서 내 서명이 아니라 Apple 서명으로 검증된다
- Apple이 필요한 검사를 다 한 뒤 재서명하기 때문에, 기기에서 실행할 때 내 프로파일도 필요 없다

```
내 인증서 만료
 ├─ App Store 앱       → 계속 켜짐 (기기는 Apple 서명을 봄)
 │                       단, 새 업데이트 업로드는 불가 → 인증서 재발급 필요
 └─ 내 서명 그대로인 앱 → 영향 받음
     (Ad Hoc / Development / Enterprise)
```

- 조건은 Developer Program 멤버십 유효다. 인증서와 멤버십은 별개 문제다
- Ad Hoc 앱은 기기가 실행할 때마다 내 서명과 프로파일을 확인한다. 그래서 프로파일·인증서가 만료되면 실행되지 않는다

### FairPlay 암호화

- 재서명하면서 FairPlay 암호화를 적용한다. 목적은 불법 복제·분석 방지
- 실행할 때 기기가 복호화해서 메모리에 올린다

```
App Store 앱의 실행 파일 (Mach-O)
  Load Commands
   └─ LC_ENCRYPTION_INFO_64
        cryptid = 1  → 암호화됨 (App Store 버전)
        cryptid = 0  → 암호화 안 됨 (내가 만든 .ipa)
```

Mach-O의 Load Commands([iOS 빌드 과정](02_build-process.md) 4번)에 "이 부분이 암호화돼 있다"는 표시가 들어가는 것이다.

### 실무에서

- App Store 앱은 배포 인증서 만료 메일이 와도 당장 할 일이 없다. 다음 업데이트 전에만 재발급하면 된다
- 보안 점검(MobSF 등)에서 "binary is not encrypted" 경고 → App Store를 거치지 않은 앱(MDM·Ad Hoc 배포)이면 정상이다. 개발자가 거는 암호화가 아니라 App Store가 거는 암호화다

## 핵심 정리

1. Archive는 배포용 최종 빌드(기본 Release)를 dSYM과 함께 보관하는 것이고, Distribute는 그걸 용도별 서명으로 포장하는 것이다. 둘이 분리돼 있어서 Archive 하나를 여러 용도로 다시 포장할 수 있다.
2. 용도별 차이는 서명이다. App Store와 Ad Hoc은 같은 배포 인증서를 쓰고, 프로파일에 기기 목록이 있느냐가 다르다.
3. 코드가 바뀌면 Archive부터 다시, 서명만 바뀌면 Distribute만 다시 한다.
4. Version은 사용자용(출시 때 올림), Build는 업로드 구분용(업로드마다 올림)이다.
5. 업로드 후 Apple은 검사 → 재서명 → FairPlay 암호화 → App Thinning을 한다. 사용자 기기의 앱은 Apple 서명이라 내 인증서가 만료돼도 켜진다.
6. Release 빌드는 심볼을 dSYM으로 분리해서 크래시 로그에 주소만 찍힌다. dSYM은 UUID로 짝지어진 그 빌드 전용 사전이라, 배포한 Archive는 반드시 보관한다.
7. dSYM은 Apple에는 업로드 때 같이, 서드파티에는 따로 올린다. 업로드 스크립트는 실패해도 조용히 넘어가기 쉽다.

## 셀프 체크

**Q1. Archive 하나로 TestFlight 업로드도 하고 QA용 .ipa도 만들 수 있을까? 왜 그럴까?**

- 같은 빌드로 용도마다 다른 건 서명과 포장인데, 해당 과정은 Distribute에서 수행하기 때문이다. 같은 빌드를 서명만 바꿔서 다시 포장한다.

**Q2. App Store용 서명과 등록 기기용(Ad Hoc) 서명은 무엇이 다른가?**

- 인증서는 같은 배포 인증서이고 프로파일이 다르다. Ad Hoc 프로파일에는 설치할 수 있는 기기 목록(UDID)이 들어 있고, App Store 프로파일에는 없다.

**Q3. TestFlight 외부 테스트에서 버그를 찾아 코드를 고쳤다. 같은 버전으로 다시 올리려면 무엇부터 다시 해야 하고, 빌드 번호는 어떻게 해야 할까?**

- 코드가 바뀌었으니 Archive부터 다시 한다. Distribute는 서명만 바꿀 뿐 코드는 Archive 때 굳는다. 버전은 그대로 두고 빌드 번호만 올린다. App Store Connect는 같은 버전의 빌드를 빌드 번호로 구분하기 때문이다.

**Q4. Version을 올리면 Build도 같이 올려야 하나?**

- 업로드할 때마다 Build는 바뀌므로 Version을 올리는 업로드에서도 Build는 바뀐다. 반대로 Build를 올릴 때 Version까지 올릴 필요는 없다.

**Q5. 크래시 로그에 주소만 찍히는 이유는 뭐고, dSYM은 무슨 역할을 할까?**

- Release 빌드는 앱을 가볍게 하려고 심볼을 실행 파일에서 빼서 dSYM으로 분리한다. 그래서 사용자 기기의 앱에는 이름표가 없어 크래시 로그에 주소만 찍힌다.

- dSYM은 그 주소를 함수 이름·파일·줄 번호로 바꿔 주는 사전이다. 빌드 UUID로 실행 파일과 짝지어져 있어서, 그 빌드에서 나온 dSYM만 쓸 수 있다. 그래서 배포한 Archive는 보관해야 한다.

**Q6. App Store에서 설치한 앱이 크래시 나면, 개발자는 dSYM 없이 주소만 보게 되나?**

- dSYM이 아무 데도 없으면 그렇다. 업로드 때 symbols를 올렸으면 Apple이 번역해 Organizer에 보여 주고, 내 Mac에 맞는 dSYM이 있으면 Xcode가 번역한다.

**Q7. App Store 앱은 왜 내 인증서가 만료돼도 켜지나?**

- App Store가 배포 과정에서 앱을 Apple 서명으로 재서명하기 때문이다. 기기는 실행할 때 Apple 서명을 확인하므로 내 인증서·프로파일 만료와 무관하다. 단, 새 업데이트를 올리려면 인증서를 재발급해야 한다.

**Q8. QA에게 Release Testing(Ad Hoc)으로 준 앱은, 그 프로파일이나 인증서가 만료되면 어떻게 될까? App Store 앱과 왜 다를까?**

- 만료되면 실행 불가. App Store 앱처럼 Apple이 재서명하지 않아서, 기기가 실행할 때마다 내 서명과 프로파일을 확인하기 때문이다.

## 참고 자료

**공식**

- [Distributing your app for beta testing and releases (Apple Developer Documentation)](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases)
- [Building your app to include debugging information (Apple Developer Documentation)](https://developer.apple.com/documentation/xcode/building-your-app-to-include-debugging-information)
- [Adding identifiable symbol names to a crash report (Apple Developer Documentation)](https://developer.apple.com/documentation/xcode/adding-identifiable-symbol-names-to-a-crash-report)
- [Reducing your app's size (Apple Developer Documentation)](https://developer.apple.com/documentation/xcode/reducing-your-app-s-size)
- [CFBundleVersion (Apple Developer Documentation)](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleversion)
- [App build statuses (App Store Connect Help)](https://developer.apple.com/help/app-store-connect/reference/app-build-statuses/)
- [Certificates overview (Apple Developer Account Help)](https://developer.apple.com/help/account/create-certificates/certificates-overview)
- [Command line name "app-store" is deprecated (Apple Developer Forums)](https://developer.apple.com/forums/thread/773749) — Xcode 15.3 method 이름 변경
- [Difference ios ipa export with development or ad hoc profile (Apple Developer Forums)](https://developer.apple.com/forums/thread/100614) — Ad Hoc 서명 구성과 실행 조건
- [What do Xcode Project Versioning settings do? (Apple Developer Forums)](https://developer.apple.com/forums/thread/709065) — `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`
- [The archived version number is showing up different (Apple Developer Forums)](https://developer.apple.com/forums/thread/64241) — Info.plist 하드코딩 증상
- [Certificates vs. provisioning profiles for iOS apps (Apple Developer Forums, Quinn)](https://developer.apple.com/forums/thread/726031) — 재서명 후 서명 자산 만료 무관
- [How to verify App certificate at runtime? (Apple Developer Forums, Quinn)](https://developer.apple.com/forums/thread/711877) — App Store 앱엔 프로파일 불필요, 재서명으로 해시 변경
- [Is there a way to check your app signature… (Apple Developer Forums, Quinn)](https://developer.apple.com/forums/thread/702914) — 재서명·DRM·App Thinning
- [Security issues applications not encrypted (Apple Developer Forums, Quinn)](https://developer.apple.com/forums/thread/733183) — 재서명 시 FairPlay 적용
- [App launches fail after App Store update… fairplay decryption (Apple Developer Forums, 2026-09)](https://developer.apple.com/forums/thread/845557)

**외부**

- [Get readable crash reports in the Crashlytics dashboard (Firebase 문서)](https://firebase.google.com/docs/crashlytics/ios/get-deobfuscated-reports) — Missing dSYM 원인, Xcode 15+ Input Files, 수동 업로드
- [upload_symbols_to_crashlytics (fastlane 문서)](https://docs.fastlane.tools/actions/upload_symbols_to_crashlytics/)
- [Export iOS and tvOS Xcode archive v4.8.0 (Bitrise)](https://discuss.bitrise.io/t/export-ios-and-tvos-xcode-archive-v4-8-0/25171) — Xcode 15.3 method 이름 변경 대응
- [Understanding provisioning for iOS applications (Bitrise 블로그)](https://bitrise.io/blog/post/understanding-provisioning-for-ios-applications) — 프로파일 종류별 기기 목록
- [fastlane-plugin-versioning 문서](https://www.rubydoc.info/gems/fastlane-plugin-versioning/0.5.0) — Xcode 11부터 버전 값이 Build Settings로 이동
- [Submit to TestFlight (Expo 문서)](https://docs.expo.dev/submit/testflight/) — 내부/외부 테스트, Beta App Review
- [TestFlight Overview (Thunkable 문서)](https://docs.thunkable.com/snap-to-place/publish-to-app-store-ios/testflight-overview) — 내부 100명·외부 10,000명 한도
- [App in production when Distribution Certificate expires (Expo Forums)](https://forums.expo.dev/t/app-in-production-when-distribution-certificate-expires/69326) — Enterprise 배포 앱은 만료 후 동작 중지
- [Dev:Crack prevention (The Apple Wiki)](https://theapplewiki.com/wiki/Dev:Crack_prevention) — `cryptid`로 암호화 여부 판단
