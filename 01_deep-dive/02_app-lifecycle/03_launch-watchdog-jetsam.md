# Launch, Prewarming, Watchdog, Jetsam

> 작성일: 2026-09-29

## A. Launch의 종류: "앱 시작"은 한 가지가 아니다

### Launch 종류

- **Cold launch** - 재부팅 후 첫 실행, 또는 오래 안 써서 메모리/캐시에 아무것도 없음 / 가장 느림, 디스크에서 모든 걸 읽어옴
- **Warm launch** - 프로세스는 없지만 최근 실행해서 라이브러리가 캐시에 남아 있음 / 중간
- **Resume** - 프로세스가 Suspended 상태로 메모리에 살아 있음 / 가장 빠름, 사실상 launch가 아니라 깨어나기

### 실무 포인트

- Resume은 `didFinishLaunching`이 불리지 않는다. 프로세스가 이미 살아있기 때문에
  → 앱이 화면에 나타날 때마다 실행해야 하는 코드는 `sceneWillEnterForeground`에 둔다
- 런치 속도는 Cold 기준으로 재야 한다. 개발 중엔 대부분 Warm이라 실제 사용자보다 빠르게 느껴진다

## B. main() 이전: Pre-main 단계

```
탭 → 커널이 프로세스 생성
   → dyld (동적 링커)                        ← Pre-main
       1. 앱이 의존하는 동적 라이브러리(.dylib, .framework) 로딩
       2. 주소 재배치·심볼 연결 (rebase / bind)
       3. Objective-C 런타임 준비 (클래스 등록)
       4. 정적 초기화 코드 실행 (+load, C++ 생성자 등)
   → main() → UIApplicationMain() ...        ← 지난 문서의 시작점
```

## C. Prewarming (iOS 15+): 탭하기 전에 이미 시작된 앱

- iOS 15부터 시스템은 사용 패턴을 보고 사용자가 탭하기 전에 앱 프로세스를 미리 띄워둘 수 있다
- Prewarming은 `main()`이 `UIApplicationMain`을 호출하기 직전까지만 실행, 위 B의 Pre-main 단계가 미리 돌고, `didFinishLaunching`은 실제로 사용자 탭 시 호출됨

Prewarm으로 시작된 프로세스는 환경 변수 `ActivePrewarm`이 `"1"`로 설정돼서 구분할 수 있음

```swift
let isPrewarmed = ProcessInfo.processInfo.environment["ActivePrewarm"] == "1"
```

## D. Watchdog: 메인 스레드를 너무 오래 막으면 강제 종료

- 감시 시점: 런치, 포그라운드/백그라운드 전환, 종료 같은 라이프사이클 전환 구간
- 크래시 리포트의 예외 코드: `0x8badf00d`
- 제한 시간: Apple이 정확한 수치를 공개하지 않고 버전, 상황마다 다르므로, "수 초 이상 메인 스레드를 막으면 위험"

가장 흔한 원인은 `didFinishLaunching`이나 `scene(_:willConnectTo:)`에서의 동기 작업

```swift
// ❌ 런치 중 메인 스레드에서 동기 네트워크/파일 작업
func application(_ application: UIApplication, didFinishLaunchingWithOptions ...) -> Bool {
    let config = try? Data(contentsOf: remoteConfigURL)   // 네트워크가 느리면 Watchdog에 걸림
    ...
}

// ✅ 필요한 최소한만 하고, 나머지는 비동기로 미루기
func application(_ application: UIApplication, didFinishLaunchingWithOptions ...) -> Bool {
    Task { await RemoteConfig.shared.fetch() }
    return true
}
```

### 디버깅 포인트

- `0x8badf00d`를 보면 크래시 리포트의 **메인 스레드(Thread 0) 스택**부터 확인한다. 그 순간 메인 스레드가 하고 있던 작업(동기 네트워크, 파일 I/O, 락 대기 등)이 원인이다
- **디버거가 연결되어 있으면 Watchdog이 동작하지 않는다** → 개발 중엔 재현되지 않고 사용자 기기에서만 발생한다

## E. Suspended와 Jetsam: 예고 없는 종료

> Jetsam = 커널의 메모리 압박 종료 메커니즘 (Linux의 OOM Killer와 같은 역할)

```
Active → Background (수 초간 코드 실행 가능)
       → Suspended (메모리엔 있지만 코드 실행 0)
       → [메모리 부족] → 종료 (콜백 없음!)
```

메모리가 부족하면 커널의 Jetsam이 우선순위가 낮은 프로세스부터 강제 종료한다. 종료된 앱은 아무 콜백도 받지 못한다. → 이미 코드가 멈춘 상태

→ 저장은 `sceneDidEnterBackground`에서! 저장할 수 있는 마지막 확실한 기회

- 크래시가 아니므로 **크래시 리포트가 남지 않는다** → 사용자에겐 "다시 열었더니 처음 화면이 나왔다"로 보인다 (Jetsam 종료 후 Cold launch)
- **포그라운드 앱도** 기기별 메모리 한도를 넘으면 Jetsam에 종료된다. 이때는 일반 크래시 리포트가 아니라 **JetsamEvent 리포트**가 남는다 (설정 > 개인정보 보호 및 보안 > 분석 및 향상 > 분석 데이터)
- 백그라운드에서 메모리를 적게 쓸수록 Jetsam 우선순위가 뒤로 밀려 오래 살아남는다 → `sceneDidEnterBackground`에서 이미지 캐시 등을 비우는 것이 권장된다

## F. 백그라운드 실행: 시간을 더 얻는 방법

Background에 들어가면 기본적으로 수 초 안에 Suspended가 된다. 그 이상 필요 시 명시적으로 요청해야 한다.
