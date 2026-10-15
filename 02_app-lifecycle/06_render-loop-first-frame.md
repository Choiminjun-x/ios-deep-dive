# 렌더 루프와 첫 프레임

> 작성일: 2026-10-15

## 큰 그림

`makeKeyAndVisible`은 표시 요청이다. 이 노트는 두 가지를 따라간다.

- 요청은 정확히 무엇을 남겨 두나?
- "메인 스레드가 빈 뒤"에 누가, 어떤 순서로 그리나?

전체를 한 줄로 이으면 다음과 같다.

```
willConnectTo: 레이어 트리 변경 + "그려 줘" 예약
 → 리턴, 메인 스레드는 런루프로 복귀
 → 런루프가 잠들기 직전: commit (Layout → Display → Prepare → 전송)   ← 앱 프로세스
 → Render Server → GPU → VSync에 표시 = 첫 프레임                    ← 앱 밖
```

[런치: 탭부터 첫 프레임까지](04_launch-tap-to-first-frame.md) 3번의 `willConnectTo` 뒤를 이어서 본다. 단, 런치의 첫 화면은 실험해 보니 "잠들기 직전" 경로와 다르게 보였다 (→ 4번).

## 1. `willConnectTo`는 "그려 줘" 메모만 남긴다

```swift
guard let windowScene = scene as? UIWindowScene else { return }
window = UIWindow(windowScene: windowScene)
window?.rootViewController = RootViewController()
window?.makeKeyAndVisible()
```

네 줄을 실행해도 화면에 픽셀이 찍히지 않는다. 바뀌는 건 "이 창에 이런 뷰들이 이렇게 놓여 있다"는 구조 정보뿐이다. 뷰마다 뒤에 `CALayer`가 하나씩 붙어 있고, 이것이 나무 모양으로 연결된 것을 **레이어 트리**라고 부른다.

이때 뷰에는 `setNeedsLayout`("레이아웃 다시 해 줘"), `setNeedsDisplay`("다시 그려 줘") 같은 표시가 붙는다. 실행이 아니라 **예약**이라서, 여러 번 불러도 한 번으로 합쳐져 commit 때 처리된다.

```
willConnectTo 안
 → 레이어 트리에 창·rootVC의 뷰가 붙음
 → "레이아웃 필요", "그리기 필요" 표시가 붙음
 → 아직 화면엔 Launch Screen 그대로
```

| | 언제 처리되나 |
|---|---|
| `setNeedsLayout` | 예약만. 다음 commit 때 |
| `layoutIfNeeded` | 지금 당장 레이아웃 실행. 남용하면 비용이 커진다 |

## 2. 앱 프로세스 안: 런루프와 commit

`willConnectTo`가 리턴하면 메인 스레드는 런루프로 돌아간다. `UIApplicationMain`이 시작한 메인 런루프는 리턴하지 않고, `willConnectTo`는 그 안에서 불린 콜백 하나다 ([AppDelegate와 SceneDelegate](01_app-scene-delegate.md) 1번).

```
메인 런루프
 → ... willConnectTo 실행 → 리턴
 → 남은 이벤트·콜백 처리
 → 더 할 일이 없음 → 잠들기 직전   ← 여기!
```

런루프가 한 바퀴 돌고 잠들기 직전, Core Animation이 자리 잡아 둔 곳에서 그동안 쌓인 예약을 한꺼번에 처리한다. 이것이 **commit**이다.

```
commit
 → Layout   "레이아웃 필요" 표시된 뷰마다 layoutSubviews  → 위치·크기 확정
 → Display  "그리기 필요" 표시된 뷰마다 draw(_:)          → 직접 그리는 뷰만
 → Prepare  이미지 디코딩 (압축된 PNG/JPEG를 픽셀로 풀기)
 → 전송     완성된 레이어 트리를 Render Server에 보냄
```

전송까지가 우리 앱 프로세스가 하는 일이다.

### "자리 잡아 둔 곳"의 정체

- 런루프에는 "들어갈 때", "잠들기 직전", "깨어난 직후" 같은 시점마다 콜백을 걸어 두는 장치(observer)가 있다. 런루프를 중간에 끊고 들어오는 게 아니라, 런루프가 정해진 시점에 부르는 것이다
- 공식 문서가 말하는 건 "암묵적 트랜잭션은 그 스레드의 런루프가 다음에 돌 때 commit된다"까지다
- "잠들기 직전(BeforeWaiting)과 Exit에 걸린 observer"라는 구체적인 구현은 외부 분석(2015)이다. 비공개 구현이라 현재 iOS와 같은지는 확인 필요

### 여기서 말하는 런루프 = 메인 스레드의 런루프

런루프는 스레드마다 하나씩 짝지어져 있다. `willConnectTo`, commit, 첫 프레임 준비는 모두 메인 스레드 런루프에서 일어난다.

| | 메인 스레드 | 다른 스레드 |
|---|---|---|
| 런루프 객체 | 있음 | 있음 (필요할 때 시스템이 만듦) |
| 누가 돌리나 | `UIApplicationMain`이 자동으로 | 직접 `run()`을 불러야 돎 |
| 화면 commit | 여기서 일어남 | UI 작업은 여기서 하면 안 됨 |

암묵적 트랜잭션은 "그 스레드의" 런루프가 돌 때 commit되므로, 백그라운드 스레드에서 뷰를 바꾸면 화면 반영이 꼬인다.

| 백그라운드에서 `UIView` 변경 | 진단 |
|---|---|
| Swift 5 모드 | 동시성 검사 수준에 따라 경고 또는 진단 없음 → 런타임 Main Thread Checker가 잡음 |
| Swift 6 모드 | `UIView`가 `@MainActor`라서 컴파일 에러 |

## 3. 앱 밖: Render Server와 VSync

레이어 트리는 앱 밖에서 픽셀이 된다.

```
Render Server (iOS가 띄워 둔 별도 프로세스)
 → 받은 레이어 트리를 GPU 작업 목록으로 바꿈
 → GPU가 최종 이미지 한 장을 그림
 → 화면이 다음 VSync에 그 이미지를 표시     = 첫 프레임
 → Launch Screen이 이 화면으로 교체           = 런치 측정 끝
```

### Render Server

- 시스템이 항상 띄워 두는 별도 프로세스다
- 한 앱 전용이 아니다. 화면에 뭔가를 그리는 모든 앱과 시스템 UI가 하나를 공유하고, 각자 보낸 Core Animation 업데이트를 받아 합친다

```
[내 앱]        commit → 레이어 트리 ──┐
[다른 앱]      commit → 레이어 트리 ──┤  IPC(프로세스 간 통신)
[홈 화면·상태바 등 시스템 UI] ────────┤
                                     ▼
                  Render Server (항상 떠 있음, 하나뿐)
                   → 전부 합쳐 GPU로 한 장의 화면을 그림
                   → VSync에 디스플레이로
```

- 다른 프로세스라 메모리를 공유하지 않는다 → commit 마지막 단계가 레이어 트리를 "포장해서 보내기"인 이유
- 프로세스 이름은 Apple의 visionOS 문서에 `backboardd`로 나온다. iOS도 같다고 널리 알려져 있지만, iOS 기준 공식 문장은 확인 필요

| 왜 별도 프로세스인가 | 설명 |
|---|---|
| 화면은 하나 | 여러 앱, 상태바, 알림, 앱 전환 애니메이션을 한 장으로 합성할 주체가 필요 |
| 애니메이션이 앱과 독립 | 애니메이션을 넘겨 두면 매 프레임 앱에 물어볼 필요가 없음 |
| 앱보다 먼저 있어야 함 | Launch Screen처럼 앱 코드가 돌기 전에 보여야 하는 화면도 그려야 함 |

### VSync

VSync는 디스플레이 하드웨어가 "새 그림을 받을 시간"이라고 보내는 신호다. 60Hz 화면이면 16.67ms마다 오고, 그림이 준비돼 있으면 그 박자에 맞춰 교체된다.

Render Server가 VSync를 부르는 게 아니다. 하드웨어가 박자를 만들고, 앱과 Render Server가 그 박자에 맞춰 일한다. VSync 시점에 화면 쪽(디스플레이 드라이버)이 준비된 이미지가 있는지 보고 가져간다.

| | 하는 일 |
|---|---|
| 디스플레이 하드웨어 | VSync를 만든다 (메트로놈) |
| Render Server | 그 박자에 맞춰 이미지를 준비한다 |
| 앱 | 그 박자에 맞춰 commit을 끝낸다 |

사이클은 VSync 한 칸 안에 다 끝나지 않고 여러 칸에 걸쳐 진행된다. 각 단계의 마감은 다음 VSync다.

```
VSync ───────── VSync ───────── VSync
│ 앱: commit    │ Render Server │ 화면 교체
│               │  + GPU 렌더    │
```

기본이 이렇게 2칸이라 이벤트가 화면에 반영되기까지 보통 2프레임이 걸린다 (double buffering). Render Server가 밀리면 1칸을 더 주는 triple buffering으로 바뀐다.

준비가 안 돼 있으면 화면은 기다려 주지 않고 이전 그림을 한 번 더 보여 준다. 이 "1프레임 늦게 나온 것"이 **hitch**다.

| 놓친 곳 | 이름 | 원인 쪽 |
|---|---|---|
| 앱이 commit 마감을 놓침 | commit hitch | 내 앱 메인 스레드 |
| Render Server·GPU가 렌더 마감을 놓침 | render hitch | 렌더링 부담 (그림자·블러·마스크 등) |

런치에 대입하면, 첫 프레임이 준비되기 전까지 VSync가 여러 번 지나가도 화면은 계속 Launch Screen이라는 "이전 그림"을 보여 주고 있는 것이다.

### 실무에서

- 스크롤이 끊기면 hitch → Instruments **Animation Hitches**로 commit hitch인지 render hitch인지 보고, Time Profiler로 느린 코드를 찾는다
- commit을 무겁게 하는 습관: `layoutIfNeeded` 남용, 부모·형제 레이아웃까지 무효화하는 뷰, 셀 `prepareForReuse`에서 서브뷰를 지웠다 다시 만들기, 원본 크기 그대로 넣은 큰 이미지(Prepare 단계)
- hitch time ratio: 5ms/s 미만 양호, 5~10 조사, 10 초과면 바로 최적화
- render hitch도 내가 보낸 레이어 트리가 무거워서 생기는 경우가 많다. 프로세스는 남의 것이어도 비용은 내 책임일 수 있다

## 4. 실험: `willConnectTo` 이후 실제 순서

`willConnectTo`에 ①②③ 로그, 루트 VC 생명주기 메서드와 `layoutSubviews`에 로그를 넣고, 메인 런루프에 "잠들기 직전" observer(순서 0)를 직접 걸어 비교했다.

```swift
let vc = RootViewController()
print("① 대입 전, isViewLoaded =", vc.isViewLoaded)
window?.rootViewController = vc
print("② 대입 후, isViewLoaded =", vc.isViewLoaded)
window?.makeKeyAndVisible()
print("③ makeKeyAndVisible 후, willConnectTo 리턴 직전")
```

```swift
// didFinishLaunching: 잠들기 직전마다 로그 (순서 0 → Core Animation보다 먼저 불릴 것으로 예상)
var count = 0
let observer = CFRunLoopObserverCreateWithHandler(
    kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, 0
) { _, _ in
    count += 1
    if count <= 5 { print("— 메인 런루프 잠들기 직전 #\(count)") }
}
CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
```

`isViewLoaded`는 view를 건드리지 않고 로드 여부만 확인한다. `vc.view`로 확인하면 그 접근 자체가 로드를 일으킨다.

결과

```
① 대입 전, isViewLoaded = false
② 대입 후, isViewLoaded = false
  [VC] loadView
  [VC] viewDidLoad
  [VC] viewWillAppear
③ makeKeyAndVisible 후, willConnectTo 리턴 직전
  [VC] viewWillLayoutSubviews
  [VC] viewDidLayoutSubviews
  [VC] viewWillLayoutSubviews
  [VC] viewDidLayoutSubviews
  [LoggingView] layoutSubviews, size = (342.0, 120.0)
  [VC] viewDidAppear
— 메인 런루프 잠들기 직전 #1
```

| 확인된 것 | 내용 |
|---|---|
| `viewDidLoad` 시점 | `rootViewController` 대입이 아니라 `makeKeyAndVisible()` 안. `viewWillAppear`까지 `willConnectTo` 리턴 전에 동기로 불린다 |
| 레이아웃 시점 | `willConnectTo` 리턴 뒤 → "안에서는 예약만"은 맞음 |
| 첫 잠들기 전 | 레이아웃과 `viewDidAppear`까지 끝났다 |

런루프가 처음 잠들기 전에 `viewDidAppear`까지 끝났지만, 그건 앱 프로세스 쪽 처리가 끝난 것이다. Render Server · GPU를 거쳐 VSync에 실제로 화면이 바뀌었는지는 앱 로그로는 알 수 없다.

순서 0인 내 observer가 레이아웃보다 늦게 찍혔으므로, 런치 첫 화면의 레이아웃은 "잠들기 직전 observer" 경로가 아닌 것으로 보인다. 후보는 둘이고, 확인 필요다.

| 후보 | 내용 | 구분법 |
|---|---|---|
| A | 씬 연결 소스 콜백 안에서 UIKit이 직접 레이아웃·commit | 콜스택 아래쪽에 `SOURCE0` / `SOURCE1` |
| B | 런루프 Exit 시점의 Core Animation observer에서 commit | observer에 `.exit` 추가 시 레이아웃 바로 앞에 Exit, 콜스택에 `OBSERVER_CALLBACK` |

VC 레이아웃이 두 번 돈 이유(safe area·trait 반영 추정)도 확인 필요.

### 실무에서

- 런치가 느리면 `didFinishLaunching` · `willConnectTo`뿐 아니라 루트 VC의 `viewDidLoad` · `viewWillAppear`도 의심한다. 모두 첫 레이아웃 전에 동기로 돈다
- **"`viewDidAppear`가 불렸다 ≠ 사용자가 화면을 봤다"**. 실제 표시 시점은 Instruments App Launch · Animation Hitches, MetricKit `MXAppLaunchMetric`(Time To First Draw)로 본다
- 검은 화면 사례: `UIWindow(frame:)`으로 만들고 `window?.windowScene = windowScene`을 빠뜨렸다. 창이 씬에 소속되지 않아 화면에 나갈 자리가 없었고, 생명주기 로그(`viewDidAppear`까지)는 찍혔지만 레이아웃 로그는 0개였다 → `UIWindow(windowScene:)` 한 줄로 만들면 빠뜨릴 틈이 없다. `UIScreen.main`도 Apple이 사용을 권장하지 않는다
- 검은 화면 디버깅은 Debug View Hierarchy가 가장 빠르다. 창 개수와 각 뷰의 frame이 바로 보인다. 다크 모드에서는 `.systemBackground`가 원래 검정이라 배경색만으로 판단하지 않는다

## 핵심 정리

1. `willConnectTo`의 네 줄은 레이어 트리를 바꾸고 "레이아웃·그리기 필요" 예약만 남긴다. 화면은 아직 Launch Screen이다.
2. 예약은 메인 스레드 런루프가 돌 때 Core Animation이 commit으로 몰아서 처리한다 (Layout → Display → Prepare → 전송). 평소에는 잠들기 직전이 그 자리라고 알려져 있다.
3. commit의 전송까지가 앱 프로세스의 일이다. 그 뒤는 항상 떠 있고 모든 앱이 공유하는 Render Server와 GPU가 그린다.
4. VSync는 디스플레이 하드웨어가 만드는 박자다. 각 단계가 다음 VSync까지 마감을 지키며 여러 칸에 걸쳐 진행되고, 놓치면 이전 그림이 한 번 더 보인다(hitch).
5. 실험: `viewDidLoad`는 `makeKeyAndVisible` 안에서, 첫 레이아웃과 `viewDidAppear`는 런루프가 처음 잠들기 전에 끝났다. 다만 이건 앱 쪽 처리이고 실제 화면 표시 시점은 앱 로그로 알 수 없다.

## 셀프 체크

**Q1. `makeKeyAndVisible`을 부른 직후 화면이 바로 바뀌지 않는 이유는?**

- 표시 요청일 뿐이라 레이어 트리 변경과 예약만 남긴다. 실제 레이아웃·그리기는 `willConnectTo`가 리턴한 뒤 commit에서, 픽셀은 Render Server·GPU를 거쳐 VSync에 나간다

**Q2. Render Server는 항상 떠 있나?**

- 그렇다. 내 앱과 다른 별도 프로세스이고, 시스템이 항상 띄워 두며 모든 앱과 시스템 UI가 하나를 공유한다

**Q3. VSync를 Render Server가 부르나?**

- 아니다. 디스플레이 하드웨어가 내보내는 신호이고, 앱과 Render Server가 그 박자에 맞춰 일한다

**Q4. 여기서 말하는 런루프는 메인 스레드의 런루프인가?**

- 그렇다. 런루프는 스레드마다 있지만, `willConnectTo`·commit·첫 프레임 준비는 모두 메인 스레드 런루프에서 일어난다

**Q5. VSync 시점에 이미지가 준비되지 않았으면?**

- 화면은 기다리지 않고 이전 그림을 한 번 더 보여 준다. 새 그림은 다음 VSync에 나간다 (hitch). 런치 중에는 그 "이전 그림"이 Launch Screen이다

**Q6. `viewDidLoad`는 정확히 언제 불렸나?**

- `rootViewController`에 대입할 때가 아니라 `makeKeyAndVisible()` 안에서 불렸다. `viewWillAppear`까지 `willConnectTo`가 리턴하기 전에 동기로 불린다

**Q7. `viewDidAppear`가 불렸으면 사용자가 화면을 본 것인가?**

- 아니다. 앱 프로세스 쪽 처리가 끝났다는 뜻이다. 검은 화면에서도 `viewDidAppear`는 찍혔다

## 참고 자료

**공식**

- [Explore UI animation hitches and the render loop (Tech Talk 10855)](https://developer.apple.com/videos/play/tech-talks/10855/) — 렌더 루프 5단계, VSync, double·triple buffering, hitch time ratio
- [Find and fix hitches in the commit phase (Tech Talk 10856)](https://developer.apple.com/videos/play/tech-talks/10856/) — commit 4단계, `layoutIfNeeded`, `prepareForReuse` 사례
- [Advanced Graphics and Animations for iOS Apps (WWDC14 419)](https://developer.apple.com/videos/play/wwdc2014/419/) — Render Server는 별도 프로세스
- [Understanding the visionOS render pipeline](https://developer.apple.com/documentation/visionos/understanding-the-visionos-render-pipeline) — render server = 계속 실행 중인 `backboardd`, 모든 앱 공유
- [CATransaction](https://developer.apple.com/documentation/quartzcore/catransaction) — 암묵적 트랜잭션은 그 스레드의 런루프가 다음에 돌 때 commit
- [RunLoop](https://developer.apple.com/documentation/foundation/runloop) — 시스템이 각 스레드마다 런루프를 만듦
- [CFRunLoopActivity](https://developer.apple.com/documentation/corefoundation/cfrunloopactivity)
- [rootViewController (UIWindow)](https://developer.apple.com/documentation/uikit/uiwindow/rootviewcontroller)
- [view (UIViewController)](https://developer.apple.com/documentation/uikit/uiviewcontroller/view) — `isViewLoaded`는 로드를 일으키지 않음
- [windowScene (UIWindow)](https://developer.apple.com/documentation/uikit/uiwindow/windowscene)
- [UIScreen.main](https://developer.apple.com/documentation/uikit/uiscreen/main) — 사용을 권장하지 않음
- [MXAppLaunchMetric (MetricKit)](https://developer.apple.com/documentation/metrickit/mxapplaunchmetric)

**외부**

- [深入理解RunLoop (ibireme, 2015)](https://blog.ibireme.com/2015/05/18/runloop/) — Core Animation observer가 BeforeWaiting · Exit, 순서 2000000. iOS 8~9 시절 분석이라 현재 구현 일치 여부는 확인 필요
- [WWDC14 419 트랜스크립트 (nonstrict.eu WWDC Index)](https://nonstrict.eu/wwdcindex/wwdc2014/419/)
