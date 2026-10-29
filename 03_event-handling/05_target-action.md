# Target-Action

> 작성일: 2026-10-29

## 큰 그림

04 노트는 `sendActions(for:)` → "등록된 target마다 sendAction"에서 끝났다. 이 노트는 그 뒤 액션이 내 메서드까지 가는 길이다.

```
.touchUpInside 발생
 → sendActions(for:)
    → button.sendAction(_:to:for:)          ← 컨트롤 (가로채기 ①, 3번)
       → UIApplication.sendAction(...)      ← 실제 배달 (가로채기 ②, 3번)
          ├ target 있음 → target의 메서드 호출   (1번)
          └ target nil → Responder Chain 탐색  (2번)

iOS 14+ UIAction → sendAction(_ action: UIAction) → 클로저 실행  (4번)
```

## 1. 전달 주체: 컨트롤은 UIApplication에 배달을 맡긴다

```
button.touchesEnded → endTracking → .touchUpInside 발생
 → sendActions(for: .touchUpInside)
    → 등록된 (target, action) 쌍마다
       → self.sendAction(action, to: target, for: event)
          → UIApplication.shared.sendAction(action, to: target,
                                            from: self, for: event)
             → target.action(sender, event)
```

1. `sendActions(for:)`는 등록된 쌍 중 해당 이벤트에 걸린 것마다 `sendAction(_:to:for:)`를 부른다
2. 컨트롤의 `sendAction(_:to:for:)`는 직접 배달하지 않고 싱글턴 `UIApplication`에 넘긴다. 이때 sender는 컨트롤 자신이다
3. `UIApplication.sendAction(_:to:from:for:)`가 실제로 보낸다. 처리됐으면 `true`, 아무도 처리 안 했으면 `false`를 반환한다. 컨트롤 쪽 메서드는 반환값이 없어서 이 값을 버린다 → "처리자가 없으면 조용히 무시"

### action 시그니처 세 가지

UIApplication이 sender와 event를 실어 보내고, 받는 쪽은 뒤에서부터 생략해도 된다.

| ObjC (문서) | Swift | 쓸 때 |
|---|---|---|
| `- (void)action` | `@objc func tap()` | 누가 보냈는지 필요 없을 때 |
| `- (void)action:(id)sender` | `@objc func tap(_ sender: UIButton)` | 여러 버튼이 한 action을 공유할 때 |
| `- (void)action:(id)sender forEvent:(UIEvent *)event` | `@objc func tap(_ sender: UIButton, forEvent event: UIEvent)` | 터치 위치 등 이벤트 정보가 필요할 때 |

`#selector`는 메서드가 있는지만 확인하고, 시그니처는 검사하지 않는다.

### 컨트롤은 target을 retain하지 않는다

```
VC ──strong──→ view ──strong──→ button
 ↑                                 │
 └───────── target (retain 안 함) ──┘
```

- 그래서 `addTarget(self, ...)`는 순환 참조가 안 생긴다
- 반대로 별도 핸들러 객체를 target으로 넘기면 아무도 안 잡고 있어서 사라진다

```swift
// ❌ handler는 viewDidLoad가 끝나면 해제 → 탭해도 반응 없음
let handler = TapHandler()
button.addTarget(handler, action: #selector(TapHandler.tap), for: .touchUpInside)
```

- `controlEvents`에 0을 넘겨도 기존 등록은 안 끊긴다. 끊으려면 `removeTarget(_:action:for:)`

### 실무에서

`let` 초기화 클로저 안의 `self` 함정

```swift
let button: UIButton = {
    let b = UIButton(type: .system)
    b.addTarget(self, action: #selector(doButton), for: .touchUpInside) // ⚠️
    return b
}()
```

- 여기서 `self`는 VC 인스턴스가 아니라 NSObject의 `self` 메서드다. `lazy var`로 바꾸면 VC 인스턴스가 된다
- Swift 5.6부터 컴파일러 경고가 붙는다
- 증상이 들쭉날쭉하다 (iOS 8 크래시, iOS 9+ 동작, 한동안 되다가 끊김 등). `allTargets`에 nil이 들어 있었다는 외부 보고가 있어, nil-target이 돼서 체인에서 VC를 만나 "우연히 동작"한 것으로 보인다 (확인 필요)

디버깅 포인트

- action이 안 불리면 `button.allTargets`, `actions(forTarget:forControlEvent:)`로 등록 상태부터 본다. 단, nil target은 이걸로 못 본다
- `-[UIApplication sendAction:to:from:forEvent:]` 심볼릭 브레이크포인트 + `bt` → `sendActions` → `sendAction` → UIApplication 경로가 보인다
- `sendActions(for:)`를 코드로 직접 부르면 event가 nil로 간다. `forEvent event: UIEvent`(non-optional)로 받으면 어떻게 되는지는 확인 필요 → `UIEvent?`로 받는 게 안전해 보인다

## 2. target이 nil일 때: 체인에 던진다

`addTarget(self, ...)`는 받을 사람을 정해서 보내고, `addTarget(nil, ...)`는 "이 메서드 가진 사람 누구든 받아" 하고 Responder Chain에 던진다.

```
버튼 탭 → UIApplication: "target이 nil이네"
 → 체인을 따라 올라가며 "이 메서드 있어?"
 → 처음 "있다"고 한 객체가 받고 끝
 → 아무도 없으면 조용히 무시 (크래시 없음)
```

01 노트 3번의 `saveDocument` 예시가 이 경우다.

### 어디서부터 올라가나

| 상황 | 출발점 |
|---|---|
| 키보드가 올라와 있음 (텍스트 필드가 first responder) | 그 텍스트 필드 |
| 키보드 없음 | 버튼 자신 (실측 사례 기반, 확인 필요) |

- 문서(`UIApplication.sendAction`)는 first responder부터라고만 한다. first responder가 없어도 VC 메서드가 불리는 사례가 있어서, 그때는 sender부터 시작하는 것으로 보인다
- 같은 VC 안이면 어디서 출발하든 결국 그 VC를 지나가니까 차이가 거의 없다

### 실무에서

- 처리자가 없어도 아무 에러가 없다 → 오타·구현 누락을 못 잡는다. selector는 `@objc protocol`로 묶어 두는 게 관례다
- 스토리보드에서 action을 "First Responder" 아이콘에 연결하면 `addTarget(nil, ...)`과 같다

## 3. 가로채는 곳 두 군데

```
버튼 탭
 → sendActions(for:)
    → button.sendAction(_:to:for:)        ← 문 1: 이 버튼만
       → UIApplication.sendAction(...)    ← 문 2: 앱 전체 모든 컨트롤
          → target 메서드 호출
```

| | 문 1: 컨트롤 서브클래스 | 문 2: UIApplication 서브클래스 |
|---|---|---|
| 범위 | 그 클래스의 버튼만 | 앱의 모든 action |
| 만드는 법 | `UIButton` 상속 후 override | `UIApplication` 상속 + `main.swift`에서 등록 |
| 주 용도 | 연타 막기, 버튼별 로깅 | 앱 전체 탭 로깅·분석 |

`super`를 부르면 원래대로 배달되고, 안 부르면 action이 사라진다.

### 문 1: 연타 막는 버튼

```swift
final class ThrottledButton: UIButton {
    private var lastSent = Date.distantPast

    override func sendAction(_ action: Selector, to target: Any?, for event: UIEvent?) {
        guard Date().timeIntervalSince(lastSent) > 0.5 else { return }  // super 안 부름 → 무시
        lastSent = Date()
        super.sendAction(action, to: target, for: event)
    }
}
```

### 문 2: 앱 전체 action 로깅

```swift
final class LoggingApplication: UIApplication {
    override func sendAction(_ action: Selector, to target: Any?, from sender: Any?, for event: UIEvent?) -> Bool {
        print("[action]", action, "→", target.map { type(of: $0) } ?? "nil(체인)")
        return super.sendAction(action, to: target, from: sender, for: event)
    }
}
```

UIApplication은 직접 만들지 않으므로, `@main`을 지우고 `main.swift`에서 이 클래스를 쓰라고 알려 준다.

```swift
UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv,
                  NSStringFromClass(LoggingApplication.self),
                  NSStringFromClass(AppDelegate.self))
```

### 실무에서

- Apple 문서는 이벤트 가로채기는 드물게만 필요하니 가능하면 피하라고 한다 → 디버그 빌드 전용 로깅 정도로 쓴다
- 2번의 "반환값이 버려진다"는 문 2에서 `super`의 반환값을 찍으면 볼 수 있다
- UIAction으로 등록한 액션은 `sendAction(_:to:for:)`가 아니라 `sendAction(_:)`을 거친다 → 위 `ThrottledButton`으로는 못 막는다. 둘 다 막으려면 두 메서드를 다 override한다. UIAction이 문 2도 지나가는지는 확인 필요

## 4. UIAction (iOS 14+): selector 대신 클로저

```swift
// 기존: target-action
button.addTarget(self, action: #selector(didTap), for: .touchUpInside)
@objc private func didTap() { save() }

// iOS 14+: UIAction
button.addAction(UIAction { [weak self] _ in
    self?.save()
}, for: .touchUpInside)
```

`@objc`도, selector도, nil-target 체인 탐색도 없다. 버튼이 클로저를 들고 있다가 그대로 실행한다.

| | 코드 | 언제 |
|---|---|---|
| `addAction(_:for:)` | `button.addAction(action, for: .touchUpInside)` | 이벤트를 직접 고를 때, 기존 버튼에 추가할 때 |
| `primaryAction` | `UIButton(primaryAction: action)` | 버튼 만들 때 한 번에. `.primaryActionTriggered`에 등록되고 액션의 title·image가 버튼에 들어간다 |

### identifier: 같은 이름이면 교체된다

UIAction은 identifier로 구분되고, 같은 identifier로 다시 추가하면 이전 것을 교체한다.

### 참조 방향: target-action과 반대

| | target-action | UIAction |
|---|---|---|
| 버튼 → 처리자 | target을 retain 안 함 | 액션(클로저)을 버튼이 들고 있음 |
| 순환 참조 | 안 생김 | 클로저가 `self`를 강하게 잡으면 생김 |
| 대책 | 없어도 됨 | `[weak self]` |

```
VC ──→ view ──→ button ──→ UIAction ──→ 클로저
 ↑                                       │
 └──────── self 강한 캡처 ────────────────┘   ← 순환 → VC 해제 안 됨
```

target-action에서 `[weak self]` 없이 쓰던 습관 그대로 UIAction으로 옮기면 메모리 누수가 난다.

버튼(sender)이 필요하면 `action.sender`로 꺼낸다.

```swift
UIAction { action in
    let button = action.sender as? UIButton
}
```

### 실무에서

셀 재사용: `configure`에서 매번 `addAction`하면 액션이 쌓인다 → 스크롤 후 한 번 탭에 여러 번 실행된다.

```swift
// ❌ configure가 불릴 때마다 하나씩 쌓임
func configure(item: Item) {
    button.addAction(UIAction { _ in print(item.id) }, for: .touchUpInside)
}

// ✅ 같은 identifier → 교체되므로 항상 하나
func configure(item: Item) {
    button.addAction(UIAction(identifier: .init("tap")) { _ in print(item.id) },
                     for: .touchUpInside)
}
```

identifier를 안 줬을 때의 기본값은 확인 필요.

## 5. 남은 실험

03 폴더를 닫기 전에 돌려 볼 것들. 결과가 나오면 해당 노트에 반영한다.

| 실험 | 확인할 것 | 관련 노트 |
|---|---|---|
| nil-target 출발점 | 키보드 유무에 따라 출발점이 first responder / 버튼으로 바뀌는지 (`-[UIResponder targetForAction:withSender:]` 브레이크포인트) | 05 · 2번 |
| 해제된 target | 핸들러 객체 해제 후 탭 → 무시인지 크래시인지 | 05 · 1번 |
| `let` 클로저 `self` | `allTargets`에 nil이 들어 있는지 | 05 · 1번 |
| `sendActions(for:)` 직접 호출 | `forEvent event: UIEvent`에 nil이 들어가면 어떻게 되는지 | 05 · 1번 |
| ProbeButton | 버튼이 `gestureRecognizerShouldBegin`으로 조상 Tap을 거부하는지, `cancels` 값에 따라 달라지는지 | 04 · 3번 |
| 텍스트 필드 vs `dismissTap` | 먼저 인식해서 막는지, 실패 관계가 걸려 있는지 | 04 · 1번 |
| 지연 시간 | 더블탭 대기, 스크롤 뷰 touch delay | 03 · 04 |
| hit-test 시점 | `sendEvent` 전인지 안인지 (`hitTest` 브레이크포인트 `bt`) | 01 · 03 |

## 핵심 정리

1. 컨트롤은 action을 직접 부르지 않는다. `sendActions(for:)` → 컨트롤의 `sendAction(_:to:for:)` → `UIApplication.sendAction(_:to:from:for:)`가 배달한다.
2. action 메서드는 인자 0개 · sender · sender+event 세 가지 시그니처를 쓸 수 있다.
3. 컨트롤은 target을 retain하지 않는다. 그래서 `addTarget(self)`는 안전하고, 별도 핸들러 객체는 직접 잡아 둬야 한다.
4. target이 nil이면 Responder Chain에 던지고, 그 메서드를 처음 가진 객체가 받는다. 아무도 없으면 조용히 무시된다.
5. 가로채려면 버튼 하나는 컨트롤의 `sendAction`, 앱 전체는 UIApplication의 `sendAction`을 override한다. `super`를 부르면 배달, 안 부르면 차단.
6. UIAction(iOS 14+)은 버튼이 클로저를 직접 들고 실행한다. 그래서 `[weak self]`가 필요하고, 셀처럼 여러 번 설정하는 곳에서는 identifier를 줘서 교체되게 한다.

## 셀프 체크

**Q1. 버튼 action이 처리자가 없는데도 크래시가 안 나는 이유는?**

- target이 nil이면 UIApplication이 체인을 탐색하고, 아무도 처리하지 않으면 `false`를 반환한다. 컨트롤의 `sendAction`은 반환값이 없어서 이 `false`를 버린다

**Q2. `addTarget(self, ...)`는 `[weak self]` 없이도 괜찮은데, `addAction(UIAction { self.save() })`은 왜 문제인가?**

- 컨트롤은 target을 retain하지 않지만, UIAction은 버튼이 클로저를 들고 있어야 동작한다. 클로저가 `self`를 강하게 잡으면 VC → view → button → UIAction → VC 순환이 생긴다

**Q3. 연타 막기 버튼을 만들었는데 UIAction으로 등록한 액션은 막히지 않는다. 왜?**

- UIAction은 `sendAction(_:to:for:)`가 아니라 `sendAction(_:)`을 거친다. 둘 다 override해야 한다

**Q4. 셀 안 버튼이 스크롤한 뒤로 한 번 탭에 여러 번 실행된다. 원인과 해결은?**

- 재사용될 때마다 `configure`에서 `addAction`을 해서 액션이 쌓였다. 같은 identifier를 주면 교체되어 항상 하나만 남는다

## 참고 자료

**공식**

- [UIControl.sendAction(_:to:for:)](https://developer.apple.com/documentation/uikit/uicontrol/sendaction(_:to:for:)) — UIApplication에 넘겨 배달, override 시 계속하려면 super
- [UIControl.sendActions(for:)](https://developer.apple.com/documentation/uikit/uicontrol/sendactions(for:)) — 등록된 쌍마다 sendAction
- [UIApplication.sendAction(_:to:from:for:)](https://developer.apple.com/documentation/uikit/uiapplication/sendaction(_:to:from:for:)) — 시그니처 세 가지, Bool 반환, nil이면 first responder부터
- [UIControl.addTarget(_:action:for:)](https://developer.apple.com/documentation/uikit/uicontrol/addtarget(_:action:for:)) — target 비retain, nil이면 체인 탐색
- [UIControl.actions(forTarget:forControlEvent:)](https://developer.apple.com/documentation/uikit/uicontrol/actions(fortarget:forcontrolevent:)) — nil target이면 항상 nil
- [Using responders and the responder chain to handle events](https://developer.apple.com/documentation/uikit/using-responders-and-the-responder-chain-to-handle-events) — action은 이벤트가 아니지만 체인을 쓸 수 있음
- [UIApplication](https://developer.apple.com/documentation/uikit/uiapplication) — Subclassing notes
- [UIControl.sendAction(_:)](https://developer.apple.com/documentation/uikit/uicontrol/sendaction(_:)) — iOS 14+, UIAction 배달 경로
- [UIControl.addAction(_:for:)](https://developer.apple.com/documentation/uikit/uicontrol/addaction(_:for:)) — identifier로 구분, 같은 identifier는 교체
- [UIButton.init(frame:primaryAction:)](https://developer.apple.com/documentation/uikit/uibutton/init(frame:primaryaction:)) — `.primaryActionTriggered` 등록, title·image 복사

**외부**

- [SwiftRocks — Understanding the iOS Responder Chain](https://swiftrocks.com/understanding-the-ios-responder-chain) — first responder 없이도 VC가 받은 사례 (작성 시점 확인 필요)
- [Use Your Loaf — Using The Responder Chain](https://useyourloaf.com/blog/using-the-responder-chain/) — `@objc protocol` 패턴 (2019)
- [Jesse Squires — Swift self-executing anonymous closures](https://www.jessesquires.com/blog/2020/12/22/swift-self-executing-anonymous-closures/) — `let` vs `lazy var`에서의 `self` (2020)
- [swiftlang/swift #47442 (SR-4865)](https://bugs.swift.org/browse/SR-4865) — 버전별 크래시·동작·끊김 보고 (2017~, iOS 8~11)
- [swiftlang/swift #47136 (SR-4559)](https://bugs.swift.org/browse/SR-4559) — Swift 5.6 경고 추가
- [Zenn — 버튼 탭부터 액션 발화까지](https://zenn.dev/k_koheyi/articles/b974858cc93762) — `let` 클로저 `self` → `allTargets`에 nil (작성 시점 미표기)
- [Stack Overflow — Subclass UIApplication with Swift](https://stackoverflow.com/questions/24020000/subclass-uiapplication-with-swift) — `main.swift`로 principal class 지정 (2014~2016)
- [Swift Forums — @selfsafe 초안](https://forums.swift.org/t/draft-selfsafe-a-new-way-to-avoid-reference-cycles/5246) — addTarget은 안전, 클로저 방식은 순환 위험 (2017)
