# 런치: 탭부터 첫 프레임까지

> 작성일: 2026-10-15

## 큰 그림

```
탭
 → ① System Interface   dyld + libSystem 초기화           ┐ main 이전
 → ② Runtime Init       ObjC·Swift 런타임 + static init   ┘
 → ③ UIKit Init         UIApplication · AppDelegate 생성   ← @main → UIApplicationMain
 → ④ Application Init   didFinishLaunching → willConnectTo
 → ⑤ Initial Frame      레이아웃 · 그리기 → 첫 프레임       ← 런치 측정 끝
 → ⑥ Extended           비동기 로딩 (런치 지표에 안 잡힘)
```

WWDC19의 6단계 구분이다. 목표는 400ms 안에 첫 프레임이고, 그중 약 100ms는 시스템, 약 300ms가 앱 몫이다.

Launch Screen은 탭 직후 시스템이 띄우는 자리 표시이고, dyld부터 `willConnectTo`까지는 그 뒤에서 진행된다. Launch Screen이 앱의 첫 프레임으로 교체되는 순간 런치 측정이 끝난다.

## 1. main 이전: dyld

```
커널: 앱 실행 파일 + dyld를 매핑 (아직 RAM에 다 올리지 않음)
 → dyld: Load Commands에서 의존 목록 읽기
 → 의존 dylib을 찾아 mmap → 그 dylib의 의존도 재귀로 로드
 → 전부 로드한 뒤 bind할 심볼 주소 조회
 → fixup 적용: rebase / bind (DATA 영역의 포인터만 고침)
 → initializer 실행 (bottom-up: 의존 받는 쪽이 먼저)
 → main()
```

### 누가 무엇을 하나

| | 앱 실행 파일 | 동적 프레임워크 |
|---|---|---|
| 매핑 | 커널 | dyld |
| Load Commands 읽기 · fixup · initializer | dyld | dyld |

정적 라이브러리는 빌드 때 이미 실행 파일 안에 합쳐져 있으므로, 커널이 실행 파일을 올릴 때 함께 올라간다.

### Load Commands: 링커가 적은 지시 목록

dyld는 dynamic linker(Apple 문서에서는 dynamic loader라고도 부름)다.

Load Commands는 링커가 Mach-O 파일(실행 파일, 동적 프레임워크)의 헤더 바로 뒤에 적어 둔 "이 파일을 어떻게 올리고 실행할지"에 대한 지시 목록 전체다. 동적 라이브러리 목록은 그 일부다.

| Load Command | 내용 | 예 |
|---|---|---|
| `LC_SEGMENT_64` | 세그먼트 위치 · 권한 | TEXT, DATA, LINKEDIT |
| `LC_LOAD_DYLIB` | 의존하는 동적 라이브러리 | `@rpath/Foo.framework/Foo` |
| `LC_RPATH` | `@rpath`를 찾을 위치 | `@executable_path/Frameworks` |
| `LC_MAIN` | 진입점 | main 위치 |

전체는 `otool -l`, 라이브러리 목록만은 `otool -L`로 본다.

```
링크 (ld)  → 실행 파일에 목록 기록
패키징      → 프레임워크 실물을 .app/Frameworks에 배치
코드 서명   → 완성된 내용에 서명
```

dyld는 동적 프레임워크(Mach-O 파일 하나)를 세그먼트마다 따로 매핑한다. Load Commands 목록에 있으면 코드에서 쓰지 않아도 전부 매핑한다. `.framework`는 폴더이고, dyld가 매핑하는 건 그 안의 바이너리(`Foo.framework/Foo`) 하나다.

### 세그먼트별 권한 매핑

| 세그먼트 | 권한 | 막는 것 |
|---|---|---|
| TEXT (코드) | 읽기 + 실행, 쓰기 ❌ | 코드 변조 |
| DATA (변수, fixup 빈칸) | 읽기 + 쓰기, 실행 ❌ | 써 넣은 코드 실행 |
| LINKEDIT (심볼 · 서명 정보) | 읽기만 | 둘 다 |

권한을 나누는 이유는 세 가지다.

1. 보안: 쓰기와 실행을 한 페이지에 같이 주지 않는다. 일반 앱은 쓰기 + 실행 페이지를 가질 수 없다
2. 코드 서명: 실행 페이지는 로드될 때 서명과 대조된다. TEXT가 안 바뀌어야 이 검사가 성립한다
3. 메모리: 안 바뀌는 페이지는 버렸다가 파일에서 다시 읽을 수 있다

권한은 링커가 정해 Load Commands에 적고, dyld는 적힌 대로 매핑을 요청하고, 커널이 강제한다. 매핑은 연결만 해 두는 것이고, 실제로는 접근한 페이지만 RAM에 올라온다.

### fixup: 런치 때 주소 빈칸 채우기

| | rebase | bind |
|---|---|---|
| 빈칸 | 내 안을 가리키는 주소 | 남의 라이브러리 함수 주소 (`_malloc` 등) |
| 왜 생기나 | ASLR로 로드 위치가 매번 달라서 | 빌드 때 주소를 몰라서 (01_build/04의 남은 U) |
| dyld가 하는 일 | 실제 시작 주소를 더함 | 이름으로 찾아서 씀 |

코드(TEXT)는 서명돼 있어 고칠 수 없으므로, dyld는 코드가 참고하는 DATA의 빈칸만 채운다.

```
TEXT (서명됨, 수정 불가)                DATA (수정 가능)
"malloc 호출"
  → "DATA의 3번 칸을 읽고 점프"   →    [3번 칸: ????] ← dyld가 채움
```

### 그래도 남는 비용

```
예전      매 런치마다: 찾기 + 빈칸 전부 채우기
iOS 13    찾기 결과를 저장해 재사용 (launch closure)
iOS 16    빈칸 채우기도 페이지를 처음 읽을 때로 미룸 (page-in linking)
```

page-in linking은 chained fixups로 빌드된 바이너리에서만 동작한다 (deployment target iOS 13.4 이상).

그래도 프레임워크 개수만큼 열기 · 매핑과 initializer 실행이 반복되고, 이것이 런치 비용으로 남는다.

```
동적 30개 → 파일 30개 → dyld가 30번 열고 매핑, 각자의 initializer 실행
정적 30개 → 실행 파일 1개에 합쳐짐 → 커널이 한 번에 매핑
```

initializer: 라이브러리가 로드되자마자 자동 실행되는 코드 (예: ObjC `+load`). main보다 먼저 돈다.

목록에 있으면 로드되고, 로드되면 실행된다. 그래서 안 쓰는 SDK도 비용이 들고, 없애려면 호출 코드가 아니라 **링크**를 빼야 한다.

Swift 코드는 initializer를 거의 만들지 않는다. 비용은 주로 ObjC · C++ 서드파티 SDK에서 나온다.

### 실무에서

- 런치가 느린데 `didFinishLaunching` 로그는 빠름 → 동적 프레임워크 수, 링크만 된 SDK의 `+load` → Instruments App Launch의 main 이전 구간, `otool -L MyApp | grep @rpath`
- 빌드는 성공했는데 런치 직후 `dyld: Library not loaded` → 목록(링커)과 실물(패키징) 불일치, 주로 Embed 누락 → `otool -L` 목록과 `.app/Frameworks/` 비교
- 런치 직후 종료, `code signing blocked mmap()` → 프레임워크 서명 깨짐 또는 팀 ID 불일치 → 서명 후 프레임워크를 수정하는 빌드 스크립트 확인

## 2. 진입점: `@main`

UIApplicationDelegate가 `main()` 기본 구현을 제공한다. 이 덕분에 AppDelegate가 UIKit 앱의 진입점이 될 수 있고, 시스템이 이걸 불러 앱을 시작한다. 이 `main()`이 `UIApplicationMain`을 호출한다. 앱에는 진입점이 정확히 하나만 있어야 한다.

SwiftUI도 동일하게 `@main`을 붙이면 시스템이 `App`의 `main()`을 호출한다. 그리고 SwiftUI의 기본 구현이 플랫폼에 맞게 시작 과정을 처리한다.

```
@main AppDelegate → AppDelegate.main() (기본 구현) → UIApplicationMain
                                                     → UIApplication · AppDelegate 생성
                                                     → 런루프 시작 (리턴 안 함)
@main App         → App.main() (기본 구현)         → 플랫폼에 맞게 시작
```

| | UIKit | SwiftUI |
|---|---|---|
| 붙이는 타입 | `UIApplicationDelegate` 채택 클래스 | `App` 채택 타입 |
| 호출되는 것 | `AppDelegate.main()` | `App.main()` |
| 격리 | `@MainActor @preconcurrency` | `@MainActor @preconcurrency` |

진입점부터 메인 액터에서 시작하므로, 이 경로는 Swift 6 모드에서도 동시성 에러가 나지 않는다.

옛 방식은 알아볼 정도로만 정리한다.

| 방식 | Swift 5 모드 | Swift 6 모드 |
|---|---|---|
| `@UIApplicationMain` | ⚠️ 경고 (Swift 5.10+) | ❌ 에러 |
| `main.swift` | 동작 | top-level 코드에 격리 에러 가능 |

```
@main              → 컴파일러가 만든 main → AppDelegate.main() (기본 구현) → UIApplicationMain
@UIApplicationMain → 컴파일러가 만든 main ──────────────────────────────────→ UIApplicationMain
```

`@UIApplicationMain`은 컴파일러가 `UIApplicationMain`을 직접 부르는 main을 만든다 (기본 `main()`은 쓰지 않음). 경로는 달라도 도착지가 같아서, `@main`으로 바꿔도 런치 동작은 같다.

### 실무에서

- `@UIApplicationMain` 경고 → Swift 5.10+ deprecation (SE-0383) → fix-it으로 `@main` 교체, 동작 변화 없음
- `main` 중복 빌드 에러 → `@main`과 `main.swift` 공존 → 둘 중 하나 제거

## 3. 첫 프레임: `willConnectTo`

### 런치 순서

```
UIApplicationMain
 → willFinishLaunching
 → didFinishLaunching             ← 앱 전체 준비 (UI는 만들지 않음)
 → 씬 설정 결정 (Info.plist의 UIApplicationSceneManifest)
 → scene(_:willConnectTo:)        ← 첫 화면 구성
```

| | AppDelegate | SceneDelegate |
|---|---|---|
| 담당 | 앱 프로세스 전체 | 화면 하나(씬) |
| 런치 때 콜백 | `willFinish` / `didFinishLaunching` | `willConnectTo` |
| 여기서 할 일 | DB, 앱 전역 서비스 설정 | 화면 구성, user activity 처리 |

### willConnectTo 네 줄

```
UIKit이 준 UIScene → UIWindowScene 캐스팅
 → UIWindow를 만든 뒤 SceneDelegate의 window에 보관
 → rootViewController를 설정
 → makeKeyAndVisible
 → willConnectTo 리턴
 → 메인 스레드가 비면 레이아웃 · 그리기 → 첫 프레임 → Launch Screen 교체
```

```swift
guard let windowScene = scene as? UIWindowScene else { return }
window = UIWindow(windowScene: windowScene)
window?.rootViewController = RootViewController()
window?.makeKeyAndVisible()
```

| 줄 | 한 마디 | 빠뜨리면 |
|---|---|---|
| `as? UIWindowScene` | 창을 가질 수 있는 씬인지 확인 | `UIScene`으로는 창 생성 불가 |
| `window = UIWindow(...)` | 씬 소속 창 생성 + 보관 | 지역 변수면 해제 → 검은 화면 |
| `rootViewController` | 창에 담을 첫 화면(루트) | 빈 창 → 검은 화면 |
| `makeKeyAndVisible()` | 보이게 + key window로 (요청) | 숨겨진 창 → 검은 화면 |

`makeKeyAndVisible`은 표시 **요청**이다. 실제 그리기는 `willConnectTo`가 리턴하고 메인 스레드가 빈 뒤라서, 이 콜백에서 무거운 작업을 하면 그만큼 Launch Screen이 오래 보인다.

### 씬 / 창 / rootVC 관계

```
UIWindowScene
 └─ UIWindow
     └─ rootVC
```

상속이 아니라 소속이다. 상속은 "무엇인가", 소속은 "어디에 있나"다.

```
상속 (무엇인가)                     소속 (어디에 있나)
UIResponder                        UIWindowScene (씬)
 ├─ UIView                          └─ UIWindow (창)
 │   └─ UIWindow   ← 창은 뷰            └─ rootVC
 └─ UIScene
     ├─ UIWindowScene               ← iPhone / iPad
     └─ CPTemplateApplicationScene  ← CarPlay
```

`UIWindow(windowScene:)`에 씬을 넘기는 건 "이 창은 이 씬 소속"이라고 알려 주는 것이다. 창은 씬을 weak로 가리킬 뿐이라, 창은 `SceneDelegate`의 `window` 프로퍼티에 강하게 보관해야 한다. 씬마다 `SceneDelegate`가 따로 있으므로 창도 씬마다 따로 보관된다.

```
SceneDelegate ──strong──→ UIWindow ──weak──→ UIWindowScene
```

### Launch Screen

- 앱이 아니라 **시스템**이 보여 준다. 앱 코드가 돌기 전에 떠야 하기 때문이다
- Info.plist `UILaunchScreen` 키 또는 Launch Screen storyboard로 만든다. storyboard는 UIKit 클래스만 쓰고, 코드 연결과 커스텀 클래스를 쓸 수 없다
- 시스템은 Launch Screen의 스냅샷을 미리 만들어 캐시하고, 런치 때는 그 스냅샷을 쓴다

### 버전별 차이

| | Xcode 26.x (iOS 26 SDK) — 현재 환경 | Xcode 27 (iOS 27 SDK) |
|---|---|---|
| 씬 미채택 앱 | 경고 로그만 남음 | 런치 실패 |
| Launch Screen 없음 | 허용 | 필수 |

기준은 빌드에 쓴 SDK다. 이미 배포된 바이너리는 iOS 27 기기에서도 그대로 동작한다.

Prewarming은 현재 Apple 문서 기준으로 프로세스를 만들고 라이브러리를 로드한 다음, 앱 코드를 실행하지 않고 정지시킨다. 03 노트 §3의 "`UIApplicationMain` 직전까지 실행"은 예전 문서 표현이다.

### 실무에서

- Launch Screen이 오래 보임 → `didFinishLaunching` / `willConnectTo`의 동기 작업 → Instruments App Launch에서 메인 스레드 상태
- Launch Screen 뒤 검은 화면 → `window` 미보관, rootVC 누락, `makeKeyAndVisible` 누락 → 이 순서대로 확인
- Launch Screen을 고쳤는데 안 바뀜 → 시스템 스냅샷 캐시 → 앱 삭제, 안 되면 기기 재시작 · 시뮬레이터 재실행

## 핵심 정리

- 런치 측정은 탭부터 앱의 첫 프레임까지다. Launch Screen 표시는 끝이 아니다
- 앱 실행 파일은 커널이, 동적 프레임워크는 dyld가 매핑한다. 정적 라이브러리는 이미 실행 파일 안에 있다
- dyld 흐름: 목록 → 매핑 → 빈칸 채우기 → initializer → main
- 동적 프레임워크는 쓰지 않아도 목록에 있으면 로드되고, 개수만큼 매핑과 initializer 비용이 든다
- `@main`은 프로토콜의 기본 `main()`을 쓰고, UIKit에서는 그 `main()`이 `UIApplicationMain`을 호출한다
- `makeKeyAndVisible`은 표시 요청이다. 실제 그리기는 `willConnectTo`가 리턴하고 메인 스레드가 빈 뒤다
- 씬 ⊃ 창 ⊃ rootVC는 상속이 아니라 소속이다

## 셀프 체크

1. 찾기는 저장(iOS 13+)하고 채우기는 미뤄도(iOS 16+), 동적 프레임워크 30개가 여전히 비용인 이유는?

   파일 열기·매핑, initializer 실행이 개수만큼 반복되기 때문이다.

2. 빌드는 성공했는데 런치 직후 `dyld: Library not loaded`로 죽는 이유는?

   의존 목록은 링커가 적고 실물 파일은 패키징이 넣으므로, Embed 누락 등으로 둘이 어긋날 수 있다.

3. `window`를 `AppDelegate` 프로퍼티에 보관하면 iPad에서 창을 두 개 열 때 무슨 문제가 생기나?

   창은 씬마다 따로 보관돼야 하는데, 하나뿐인 자리에 보관하면 두 번째 씬의 창이 첫 번째를 덮어쓴다.

4. `UIWindow`는 `UIWindowScene`을 상속하나?

   아니다. 창은 뷰의 한 종류이고, 씬에 소속되어 붙는다.

## 참고 자료

공식

- [Reducing your app's launch time (Apple Developer Documentation)](https://developer.apple.com/documentation/xcode/reducing-your-app-s-launch-time)
- [About the app launch sequence (UIKit)](https://developer.apple.com/documentation/uikit/about-the-app-launch-sequence)
- [Optimizing App Launch (WWDC19)](https://developer.apple.com/videos/play/wwdc2019/423/)
- [Link fast: Improve build and launch times (WWDC22)](https://developer.apple.com/videos/play/wwdc2022/110362/)
- [Security of runtime process in iOS, iPadOS, and visionOS (Apple Platform Security)](https://support.apple.com/guide/security/sec15bfe098e)
- [SE-0383: Deprecate @UIApplicationMain and @NSApplicationMain](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0383-deprecate-uiapplicationmain-and-nsapplicationmain.md)
- [SE-0343: Concurrency in Top-level Code](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0343-top-level-concurrency.md)
- [UIApplicationDelegate.main() (UIKit)](https://developer.apple.com/documentation/uikit/uiapplicationdelegate/main())
- [App.main() (SwiftUI)](https://developer.apple.com/documentation/swiftui/app/main())
- [UIWindow.windowScene (UIKit)](https://developer.apple.com/documentation/uikit/uiwindow/windowscene)
- [Specifying your app's launch screen (Apple Developer Documentation)](https://developer.apple.com/documentation/xcode/specifying-your-apps-launch-screen)
- [TN3187: Migrating to the UIKit scene-based life cycle](https://developer.apple.com/documentation/technotes/tn3187-migrating-to-the-uikit-scene-based-life-cycle)
- [TN3118: Debugging your app's launch screen](https://developer.apple.com/documentation/technotes/tn3118-debugging-your-apps-launch-screen)

외부

- [UIKit in iOS 27 (Michael Tsai, 2026-06-18)](https://mjtsai.com/blog/?p=52313)
- [First used launch screen file is forever cached… (Apple Developer Forums)](https://developer.apple.com/forums/thread/105790)
