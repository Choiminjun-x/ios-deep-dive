# SPM과 의존성 빌드

> 작성일: 2026-10-08

## 큰 그림

SPM (Swift Package Manager) - Apple이 만든 패키지 매니저

```
① 기억      Package.swift(조건) + Package.resolved(실제 버전)     → 1번
② 다운로드   resolve → DerivedData/SourcePackages에 저장          → 2번
③ 연결      내 코드처럼 컴파일 → 링커가 앱에 붙임                  → 3번, 4번
   + CocoaPods와 달리 workspace 없이 되는 이유                    → 5번
```

SPM이 해 주는 일

- **기억** - "나는 Alamofire 5.8 이상이 필요해"를 파일에 적어 둔다
- **다운로드** - 그 조건에 맞는 버전을 찾아서 받아 온다
- **연결** - 받아 온 코드를 내 앱과 같이 빌드되게 붙인다

## 1. Package.swift와 Package.resolved

| | Package.swift | Package.resolved |
|---|---|---|
| 정체 | 매니페스트 (Swift 코드) | lock 파일 (JSON) |
| 내용 | 원하는 범위: `from: "5.8.0"` (5.8.0 이상 6.0.0 미만) | 실제 고른 버전 + 커밋 해시 |
| 작성자 | 사람 | SPM이 자동으로 |
| 비유 | 장보기 메모 | 영수증 |
| CocoaPods 대응 | Podfile | Podfile.lock |

- 조건만 있으면 받는 시점마다 다른 버전을 받을 수 있다 (오늘 5.9.1, 다음 달 5.10.0) → 실제 버전을 따로 기록해 모두가 같은 버전을 받게 한다
- 앱 프로젝트에서 File → Add Package Dependencies…로 추가하면 `Package.swift`는 생기지 않는다. 같은 정보가 `project.pbxproj`에 패키지 참조로 저장된다

```
라이브러리를 만드는 쪽 (예: Alamofire 저장소)  → Package.swift 있음
라이브러리를 쓰는 앱 프로젝트                  → .xcodeproj 안에 저장 (Package.swift 없음)
Package.resolved                           → 둘 다 있음
```

## 2. 패키지 해결 (resolve)

"패키지 해결(resolve)" = 장 보러 가는 것

```
조건 읽기 ("5.8 이상")
  → 조건에 맞는 버전 고르기 (5.9.1)
  → GitHub에서 받아 오기
  → 영수증에 기록 (Package.resolved)
```

- 빌드 앞 단계다. 프로젝트를 열거나 패키지를 추가할 때 "Resolving Package Graph…"가 뜨는 것이 이 과정이고, 이게 끝나야 빌드할 수 있다

### 받아 온 코드는 어디에 있나

resolve가 끝나면 Alamofire 소스 코드가 내 Mac에 저장된다. 위치는 DerivedData 안이다.

```
~/Library/Developer/Xcode/DerivedData/MyApp-abcd…/
└── SourcePackages/
    └── checkouts/
        └── Alamofire/      ← 받아 온 소스 코드 (.swift 파일들)
```

- DerivedData를 지우면 패키지도 다시 받아야 하는 이유
- 내 프로젝트 폴더가 아니므로 git에는 패키지 소스가 아니라 `Package.resolved`만 올라간다

### 실무에서

- 빌드 전에 `Missing package product 'X'`가 나면 빌드 문제가 아니라 resolve 실패다

```
File → Packages → Reset Package Caches
  → 안 되면 File → Packages → Resolve Package Versions
  → 그래도 안 되면 DerivedData/<프로젝트>/SourcePackages 삭제
```

- CI에서는 `Package.resolved`와 다른 버전을 고르지 못하게 막을 수 있다

```bash
xcodebuild -resolvePackageDependencies
xcodebuild ... -onlyUsePackageVersionsFromResolvedFile   # resolved와 어긋나면 실패
xcodebuild ... -clonedSourcePackagesDirPath ./spm         # 체크아웃 위치 지정 (캐시용)
```

## 3. 패키지가 빌드·링크되는 방식

### 패키지도 "내 코드처럼" 빌드된다

```
내 코드          ViewController.swift ──swiftc──▶ ViewController.o ─┐
                                                                    ├─▶ 링커(ld) ─▶ MyApp 실행 파일
패키지 코드       Session.swift ────────swiftc──▶ Session.o ─────────┘
(Alamofire)      (DerivedData에 받아 온 소스)
```

- 처음 빌드가 오래 걸리는 이유 → 라이브러리도 내 코드와 같이 컴파일하기 때문이다. 두 번째 빌드부터는 라이브러리도 증분 빌드가 적용되어 이미 만든 `.o`를 재사용한다

### 링커가 붙이는 방식은 두 가지

```
정적 (static)
  Alamofire 코드가 MyApp 실행 파일 "안에" 녹아 들어감
  MyApp.app/
   └─ MyApp          ← 내 코드 + Alamofire 코드가 한 파일에

동적 (dynamic)
  Alamofire가 "별도 파일"로 들어가고, 실행할 때 dyld가 연결
  MyApp.app/
   ├─ MyApp          ← 내 코드만
   └─ Frameworks/
       └─ Alamofire.framework
```

| | 정적 | 동적 |
|---|---|---|
| Alamofire 코드 위치 | 실행 파일 안 | `Frameworks/` 폴더 |
| 연결 시점 | 빌드할 때 (링커) | 앱 켤 때 (dyld) |
| 앱 시작 속도 | 빠름 | 프레임워크마다 로딩·서명 확인 비용 |

### 누가 정하나

패키지를 만든 사람이 `Package.swift`에 적는다.

```swift
.library(name: "Alamofire", targets: ["Alamofire"])                  // 아무것도 안 적음
.library(name: "Alamofire", type: .dynamic, targets: ["Alamofire"])  // 동적으로 해 줘
```

- 아무것도 안 적으면(automatic) Xcode가 정하고, 실제로는 대부분 **정적으로** 붙인다
- 그래서 SPM 패키지를 여러 개 붙여도 `.app/Frameworks/`가 비어 있는 게 정상이다. `otool -L`에도 패키지 이름이 보이지 않는다

### 정적 패키지는 링크한 실행 파일마다 복사된다

정적 패키지는 링크한 실행 파일마다 복사된다. 다른 프로세스(위젯)면 용량 문제뿐이고, **같은 프로세스**(동적 프레임워크)면 사본 두 개가 충돌한다.

```
MyApp.app/
 ├─ MyApp                          ← 실행 파일 ① 앱
 ├─ PlugIns/MyWidget.appex/MyWidget  ← 실행 파일 ② 위젯 (다른 프로세스)
 └─ Frameworks/Core.framework/Core   ← 실행 파일 ③ 내 동적 프레임워크 (앱과 같은 프로세스)
```

| 링크하는 쪽 | 프로세스 | 결과 |
|---|---|---|
| 앱 + 위젯 | 다름 | 앱 용량 증가뿐 |
| 앱 + 내 동적 프레임워크 | 같음 | 사본 두 개가 한 메모리 공간에서 충돌 |

같은 프로세스에서 생기는 증상

| 증상 | 이유 |
|---|---|
| 싱글턴이 두 개 | `Session.default`가 사본마다 따로 있어서 한쪽 설정이 다른 쪽에 반영 안 됨 |
| `as?` 캐스팅이 이유 없이 실패 | 사본마다 타입이 따로 있어서 다른 타입으로 취급됨 |
| `Class X is implemented in both … One of the two will be used.` | Objective-C 클래스가 두 곳에 있어서 런타임이 하나만 고름 |

### 실무에서

- Xcode가 빌드할 때 미리 경고한다. 이 경고는 넘기면 안 된다

```
Swift package product 'Alamofire' is linked as a static library by 'MyApp' and 'Core'.
This will result in duplication of library code.
```

- 해결: 패키지는 동적 프레임워크에만 링크하고, 앱 타겟에는 의존성을 추가하지 않는다

```
❌ MyApp → Alamofire     Core → Alamofire      (두 곳에서 링크, 사본 2개)
✅ MyApp → Core → Alamofire                    (Core에만 링크, 사본 1개)
```

- 앱 타겟 의존성에 없는 모듈을 `import`하면 같은 `Build/Products` 덕분에 우연히 빌드될 때가 있지만, 클린 빌드나 CI에서 `No such module`로 깨질 수 있다

| 앱에서 Alamofire를 써야 할 때 | 평가 |
|---|---|
| Core가 자기 API(`APIClient` 등)로 감싸고, 앱은 그것만 쓴다 | 정석. 라이브러리를 바꿔도 앱은 그대로 |
| Core에 `@_exported import Alamofire` | 동작하지만 `_`로 시작하는 비공식 기능 |

- 실행 파일마다 사본이 있는지 확인 (Swift 심볼 이름에 모듈 이름이 들어 있다)

```bash
nm MyApp.app/MyApp | grep -c Alamofire
nm MyApp.app/Frameworks/Core.framework/Core | grep -c Alamofire
# 둘 다 0이 아니면 → 사본이 두 개
```

- 언어 모드는 모듈 단위다. 앱이 Swift 5 모드여도 패키지는 자기 모드(`swift-tools-version`, `swiftLanguageModes`)로 컴파일된다

## 4. 소스 vs 바이너리 (binary target)

- 소스 패키지 - Alamofire, Kingfisher
- 바이너리 패키지 - 컴파일된 .xcframework, Firebase 일부, 결제, 광고 같은 상용 SDK

| | 소스 패키지 | 바이너리 패키지 |
|---|---|---|
| 받는 것 | `.swift` 파일들 | 컴파일된 `.xcframework` |
| 내 빌드에서 컴파일 | ✅ | ❌ (이미 됨) |
| 코드를 볼 수 있나 | ✅ | ❌ |

- 바이너리로 주는 이유: 소스를 공개하기 싫거나(상용 SDK), 빌드가 오래 걸려서 미리 만들어 둔 것 ([iOS 빌드 과정](02_build-process.md) 4번)

### 왜 .xcframework인가

바이너리는 이미 특정 타겟 트리플용으로 만들어진 기계어다. 그래서 실기기용, 시뮬레이터용을 다 담아 와야 한다.

```
VendorSDK.xcframework/
├── ios-arm64/                     ← 실기기용
└── ios-arm64_x86_64-simulator/    ← 시뮬레이터용
```

- SPM binary target은 `.xcframework`만 받는다

### 선언 방법

```swift
// 인터넷에서 받기
.binaryTarget(
    name: "VendorSDK",
    url: "https://example.com/VendorSDK.xcframework.zip",
    checksum: "a1b2c3d4…"
)

// 저장소 안에 파일로 두기
.binaryTarget(name: "VendorSDK", path: "Frameworks/VendorSDK.xcframework")
```

### checksum = 코드 서명의 "지문"

```
패키지 만든 사람:  zip 파일 → 지문 계산 → Package.swift에 적음
내 Xcode:         zip 받음 → 지문 직접 계산 → 적힌 값과 비교
                  같으면 ✅ / 다르면 ❌ resolve 단계에서 실패
```

- 같은 URL의 zip을 누가 바꿔치기하면 지문이 달라져서 걸린다 ([iOS 코드 서명](03_code-signing.md) 1번)

```bash
swift package compute-checksum VendorSDK.xcframework.zip
```

### 정적/동적은 바이너리가 이미 정해져 있다

- 소스 패키지와 달리 Xcode가 고를 수 없다. `.xcframework` 안의 바이너리가 정적이면 실행 파일 안으로, 동적이면 `.app/Frameworks/`로 들어간다
- 동적이면 Xcode가 `Frameworks/`에 넣고 서명까지 자동으로 한다

### 실무에서

| 에러 | 원인 |
|---|---|
| `Module compiled with Swift 6.1 cannot be imported by the Swift 6.3 compiler` | SDK를 만들 때 Build Libraries for Distribution을 안 켜서 `.swiftinterface`가 없음 → SDK 제공사에 요청 |
| 시뮬레이터에서만 링크 에러 | `.xcframework`에 시뮬레이터 폴더가 없음 |
| `checksum … does not match` | zip이 바뀌었거나 URL이 잘못됨 → 패키지 쪽 확인 |

- 남의 컴퓨터, 남의 컴파일러로 만든 결과물이라 생기는 문제들이다. 소스 패키지는 내 컴파일러로 직접 컴파일하므로 첫 번째 문제가 없다

## 5. workspace 없이 되는 이유

SPM은 "두 번째 프로젝트"를 만들지 않는다.

```
CocoaPods
  MyApp.xcodeproj ──┐
                    ├─ workspace로 묶어야 서로 앎
  Pods.xcodeproj ───┘

SPM
  MyApp.xcodeproj
   └─ 패키지 참조 (Alamofire)
        → Xcode가 Package.swift를 읽어서
          Alamofire 타겟을 "내 빌드 그래프 안에" 바로 끼워 넣음
```

- CocoaPods에 workspace가 필요했던 두 조건(빌드 순서, 같은 `Build/Products`)을 SPM은 Xcode가 안에서 맞춘다 ([Xcode 프로젝트 구조와 빌드 설정](01_xcode-project-settings.md) 3번)

실제 빌드 과정

```
Planning build (빌드 지시서 만들기)
  CocoaPods: 지시서에 "Pods 프로젝트의 타겟"이 들어가려면 workspace가 필요
  SPM:       Xcode가 패키지를 직접 해석해서 지시서에 바로 넣음
→ llbuild 입장에서는 둘 다 그냥 "먼저 빌드할 타겟"
```

### 덤: 사실 workspace는 이미 있다

"SPM은 workspace가 없다"보다 "내가 따로 만들 필요가 없다"가 더 정확하다.

```
MyApp.xcodeproj/
├── project.pbxproj
└── project.xcworkspace/        ← Xcode가 자동으로 만든 숨은 workspace
    └── xcshareddata/swiftpm/
        └── Package.resolved    ← 영수증이 여기 있었던 이유
```

- `.xcworkspace`를 쓰는 프로젝트라면 `MyApp.xcworkspace/xcshareddata/swiftpm/Package.resolved`에 있다

### 내 설정을 건드리지 않는다

| | CocoaPods | SPM |
|---|---|---|
| 설정 전달 방법 | `.xcconfig`를 만들어 **내 타겟에 연결** | 빌드 시스템이 **안에서** 넘김 |
| 빌드 페이즈 | `[CP] Embed Pods Frameworks` 등 추가 | 추가 안 함 |
| 내 Build Settings 변화 | `HEADER_SEARCH_PATHS`, `OTHER_LDFLAGS` 등이 바뀜 | 안 바뀜 |

- 반대 방향도 막혀 있다. 패키지의 `swiftSettings` 등은 그 패키지에만 적용되고 내 앱 타겟으로 넘어오지 않는다

### 실무에서

| 상황 | CocoaPods | SPM |
|---|---|---|
| `.xcodeproj`로 열기 | `No such module` | 정상 |
| 라이브러리 제거 후 | xcconfig·빌드 페이즈 흔적이 남기도 함 (`pod deintegrate`로 정리) | 패키지 참조만 지우면 끝 |
| `$(inherited)` 경고 | 내 설정이 주입된 xcconfig를 덮을 때 발생 | 해당 없음 |

결론 - CocoaPods는 별도 프로젝트 + 내 설정 수정이라 workspace로 묶어야 한다. SPM은 Xcode가 패키지를 직접 읽어 같은 빌드 그래프에 넣고, 내 설정은 건드리지 않는다.

## 핵심 정리

1. SPM은 남의 코드를 **기억 → 다운로드 → 연결**해 준다. `Package.swift`는 원하는 조건, `Package.resolved`는 실제로 받은 버전이다.
2. resolve는 빌드 앞 단계이고, 받아 온 소스는 **DerivedData/SourcePackages**에 저장된다.
3. 소스 패키지는 내 코드처럼 컴파일되고, 타입을 안 적으면 대부분 **정적으로** 실행 파일 안에 들어간다.
4. 정적 패키지는 링크한 실행 파일마다 복사된다. **같은 프로세스**에서 사본 두 개가 만나면 충돌하므로 한 곳에만 링크한다.
5. binary target은 이미 컴파일된 `.xcframework`를 받는다. checksum으로 바꿔치기를 막고, 정적/동적은 바이너리가 이미 정해져 있다.
6. SPM은 Xcode가 패키지를 직접 읽어 같은 빌드 그래프에 넣으므로 workspace를 따로 만들 필요가 없고, 내 빌드 설정도 건드리지 않는다.

## 셀프 체크

**Q1. `Package.resolved`는 왜 git에 올리나?**

- clone한 사람, CI 모두가 나와 똑같은 버전을 받게 하기 위해서

**Q2. CocoaPods는 xcconfig를 주입하는데 SPM은?**

- SPM은 내 프로젝트의 빌드 설정을 고치지 않는다.

**Q3. 앱 타겟과 내 동적 프레임워크가 같은 SPM 패키지(타입 미지정)를 둘 다 링크하면 무슨 일이 생기나?**

- 앱 실행 파일과 프레임워크 실행 파일에 각각 사본이 들어간다. 둘은 같은 프로세스에서 돌기 때문에 사본 두 개가 충돌한다. 싱글턴이 둘이 되고, 타입 캐스팅이 실패할 수 있다. 해결은 패키지를 프레임워크에만 링크하는 것이다.

**Q4. 동적 프레임워크가 Alamofire를 쓰고 있을 때, 앱에는 의존성을 따로 두지 않는 게 맞나?**

- 맞다. 의존성은 프레임워크에만 둔다. 앱이 Alamofire를 직접 써야 한다면 프레임워크가 감싼 API를 쓰게 하는 게 정석이다.

## 참고 자료

- WWDC19 — *Adopting Swift Packages in Xcode*
- WWDC19 — *Binary Frameworks in Swift*
- WWDC20 — *Distribute binary frameworks as Swift packages*
- WWDC20 — *Swift packages: Resources and localization*
- Apple Developer Documentation — *PackageDescription*
