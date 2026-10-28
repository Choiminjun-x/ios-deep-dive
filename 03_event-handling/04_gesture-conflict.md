# 제스처 충돌

> 작성일: 2026-10-28

## 큰 그림

03 노트는 인식기 하나가 터치를 어떻게 판정하는지였다. 이 노트는 같은 터치를 여럿이 노릴 때 누가 이기는지다.

```
같은 터치를 노리는 쪽
 ├ 인식기 ↔ 인식기        → 기본은 한쪽만 이긴다                         (1번)
 ├ 인식기 ↔ UIControl     → 일부 제스처는 컨트롤이 인식기를 거부해서 이긴다  (2·3번)
 └ 스크롤 뷰 ↔ 안쪽 버튼   → 스크롤인지 판단할 때까지 버튼에 터치를 늦게 준다  (4번)
```

## 1. 기본 규칙: 같은 터치에서는 한 인식기만 이긴다

- UIKit은 보통 한 뷰에서 한 번에 한 제스처만 인식하게 한다

→ 팬과 스와이프 인식기가 함께 붙은 뷰에서는 스와이프가 절대 인식되지 않는다 (팬은 연속 제스처라서 이산 제스처인 스와이프보다 항상 먼저 인식)

- 같은 뷰가 아니어도, 같은 터치를 지켜보는 인식기끼리는 마찬가지다 (예: 텍스트 필드 내부 탭 vs `VC.view`의 `dismissTap`)

```
같은 터치를 지켜보는 인식기 A, B (둘 다 .possible)
 → A가 먼저 인식 (.recognized 또는 .began)
 → B는 A에게 막힘 → .failed
 → B의 action은 불리지 않음
```

터치는 둘 다 받는다. 이기는 것(action)이 하나다.

### 규칙을 바꾸는 도구

| 이럴 때 | 쓰는 것 |
|---|---|
| 둘 다 인식하게 | delegate `gestureRecognizer(_:shouldRecognizeSimultaneouslyWith:)` → `true` |
| 순서를 정하게 (싱글탭은 더블탭 실패 후) | `singleTap.require(toFail: doubleTap)` |

- 동시 인식은 한쪽 delegate만 `true`여도 된다. `false`는 막는다는 보장이 없다 (상대 delegate가 `true`일 수 있음)
- `require(toFail:)`을 걸면 싱글탭은 더블탭이 실패할 때까지 기다리므로 반응이 늦어진다. 대기 시간은 문서에 없어 확인 필요

### 실무에서

키보드 내리기 탭(`dismissTap`, `VC.view`)을 붙인 화면에서 텍스트 필드를 탭하면, 텍스트 필드 내부 탭 인식기가 이기고 `dismissTap`은 `.failed`가 된다. `cancelsTouchesInView` 값과 관계없다. 내부 인식기가 먼저 인식해서 막은 것인지, 실패 관계를 걸어 둔 것인지는 비공개 구현이라 확인 필요.

## 2. UIControl

UIControl - "터치를 의미 있는 이벤트로 번역해서 target-action으로 알려주는 뷰"

```
UIResponder
 └ UIView
    └ UIControl            ← 추상 클래스, 직접 만들지 않음
       ├ UIButton
       ├ UISwitch · UISlider · UIStepper
       ├ UISegmentedControl · UIPageControl
       └ UITextField · UIDatePicker …
```

인식기와 판정을 맡기고 결과만 받는다는 점은 같지만, 인식기는 뷰에 붙은 `NSObject`이고 UIControl은 뷰 자체라서 `touchesXxx`(뷰 경로)로 터치를 받는다.

### 터치가 액션이 되는 과정

touchesBegan → touchesMoved → touchesEnded

```
UIWindow.sendEvent
 → button.touchesBegan
    → beginTracking(touch)      true면 추적 시작, isTracking = true
    → .touchDown 발생
 → button.touchesMoved
    → continueTracking(touch)   반복 호출
    → .touchDragInside / .touchDragExit / .touchDragEnter …
 → button.touchesEnded
    → endTracking(touch)        isTracking = false
    → 손가락 위치에 따라 .touchUpInside 또는 .touchUpOutside
 (취소되면 → touchesCancelled → cancelTracking → .touchCancel)

이벤트 발생 → sendActions(for:) → 등록된 target마다 sendAction
```

### 이벤트 종류

- 터치 - `.touchDown`, `.touchUpInside`, `.touchDragExit`, `.touchCancel` / 버튼
- 값 변경 - `.valueChanged` / 스위치, 슬라이더
- 편집 - `.editingDidBegin`, `.editingChanged`, `.editingDidEnd` / 텍스트 필드

### 실무에서

- 버튼이 안 눌리면 `.touchDown`과 `.touchCancel`에 로그를 건다. `.touchDown` 다음에 `.touchUpInside` 대신 `.touchCancel`이 오면 인식기나 스크롤 뷰가 취소한 것이다
- 커스텀 컨트롤은 `touchesXxx` 대신 tracking 메서드를 override한다. `endTracking`을 override하면 `super`를 불러야 `isTracking`이 갱신된다
- 한 selector에 여러 이벤트를 등록하면 action 안에서 어떤 이벤트인지 구분할 수 없다. 이벤트마다 action을 따로 등록한다

## 3. 인식기와 만났을 때: 컨트롤 예외

`UIView.gestureRecognizerShouldBegin(_:)`

- 뷰에게 인식기가 터치 추적을 계속해야 하는지 묻는다. `false` → `.failed`
- 서브클래스는 이걸 override해서 특정 제스처의 인식을 막을 수 있다. `UISlider` → 슬라이더 방향과 나란한 스와이프는 막는다
- 불리는 시점에 인식기는 `.possible` 상태, `.began`으로 넘어갈 이벤트를 다 받았다고 판단한 상태

03 노트의 컨트롤 예외 목록(버튼의 한 번 탭 등)이 이 메서드로 만들어진다고 보면 이렇게 동작한다.

```
조상 VC.view에 Tap, 버튼을 한 번 탭
 → Tap: "탭 조건 충족, .recognized로 가려 함"
 → button.gestureRecognizerShouldBegin(tap)
 → 버튼: "한 번 탭은 내가 처리" → false
 → Tap .failed → 버튼 touchesEnded 정상 도착 → .touchUpInside
```

확인 필요: 문서가 이 메서드를 쓴다고 명시한 건 `UISlider`뿐이다. 버튼의 한 번 탭 예외도 같은 메서드인지, 인식기가 붙은 뷰가 아니라 터치된 컨트롤에게 묻는지는 `UIButton` 서브클래스에서 이 메서드를 override해 로그로 확인한다.

### 실무에서

- 바텀시트·모달 안 커스텀 컨트롤이 시트의 팬 때문에 끊기면, 커스텀 컨트롤에서 이 메서드를 override해 `false`를 반환한다. 모든 조상 인식기를 막게 되므로 상대 인식기 종류를 보고 골라 막는다
- 반대로 버튼 탭을 인식기가 먼저 처리하게 하려면 인식기를 컨트롤 자체에 붙인다 (공식 문서)

## 4. UIScrollView 안의 버튼

스크롤 뷰는 손가락이 닿으면 "스크롤하려는 건가?" 판단할 때까지 안쪽 버튼에 터치를 잠깐 안 준다 (`delaysContentTouches`, 기본 `true`).

```
빠르게 탭            → 판단: 스크롤 아님 → 버튼에 전달 → 눌림 (하이라이트는 늦게)
바로 드래그          → 판단: 스크롤임   → 버튼은 아예 못 받음 → 스크롤
누르고 있다 드래그    → 이미 버튼에 줬음 → 버튼이 안 놓아줌 → 스크롤 안 됨
```

버튼이 안 놓아주는 이유는 스크롤 뷰가 `touchesShouldCancel(in:)`로 "이 뷰의 터치를 취소할까?"를 묻는데, 기본값이 UIControl이면 `false`라서다. 2번의 "컨트롤이 우선"이 스크롤 뷰에서는 이 메서드로 나타난다.

03 노트의 `delaysTouchesBegan`과 같은 장치다. WWDC14 235에 따르면 스크롤 뷰는 팬·핀치 외에 터치 전달만 늦추는 인식기(`delaysTouchesBegan = true`)를 하나 더 가진다.

### 실무에서

| 증상 | 손댈 곳 |
|---|---|
| 셀 안 버튼 하이라이트가 늦다 | `delaysContentTouches = false` (기다리지 말고 바로 줘) |
| 버튼 위에서 드래그하면 스크롤이 안 된다 | `touchesShouldCancel(in:)`에서 버튼이면 `true` (버튼한테서 뺏어 와) |

```swift
final class ButtonFriendlyScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        if view is UIButton { return true }   // UISlider·UISwitch는 드래그가 본업이라 제외
        return super.touchesShouldCancel(in: view)
    }
}
```

`canCancelContentTouches`(기본 `true`)가 `false`면 위 override가 소용없다.

## 핵심 정리

1. 같은 터치를 지켜보는 인식기는 터치를 모두 받지만, 기본적으로 먼저 인식한 하나만 이기고 나머지는 `.failed`가 된다. 같은 뷰가 아니어도 마찬가지다.
2. 둘 다 인식하게 하려면 `shouldRecognizeSimultaneouslyWith`, 순서를 정하려면 `require(toFail:)`을 쓴다.
3. UIControl은 터치를 `.touchDown`·`.touchUpInside`·`.valueChanged` 같은 이벤트로 번역해 target-action으로 알리는 뷰다. tracking 메서드(begin/continue/end/cancel)가 이벤트를 만든다.
4. 컨트롤 예외는 `UIView.gestureRecognizerShouldBegin(_:)`에서 뷰가 인식기를 거부해 만든다 (슬라이더는 문서 명시, 버튼은 확인 필요).
5. 스크롤 뷰는 스크롤 판단 전까지 안쪽 뷰에 터치를 늦게 주고(`delaysContentTouches`), 터치를 잡은 UIControl은 기본적으로 취소하지 않는다(`touchesShouldCancel(in:)`).

## 셀프 체크

**Q1. 키보드 내리기 탭(`dismissTap`)을 붙인 화면에서 텍스트 필드를 탭하면 왜 `dismissTap` action이 안 불리나?**

- 텍스트 필드 내부 탭 인식기와 `dismissTap`이 같은 터치를 두고 경쟁해서, 내부 인식기가 이기고 `dismissTap`은 `.failed`가 되기 때문이다. 같은 뷰에 붙어 있지 않아도 같은 터치를 지켜보면 경쟁한다
- 구체적으로 먼저 인식해서 막은 것인지, 실패 관계가 걸려 있는 것인지는 확인 필요

**Q2. 인식기가 윈도우에서 먼저 터치를 받는데, 조상의 Tap이 있어도 버튼의 한 번 탭이 눌리는 이유는?**

- Tap이 `.recognized`로 가기 직전에 `gestureRecognizerShouldBegin(_:)`으로 허락을 받는데, 컨트롤이 이걸 `false`로 거부해서 Tap이 실패하기 때문으로 본다. 버튼에 대해서는 확인 필요

**Q3. 스크롤 뷰 안 버튼을 누르고 있다가 드래그하면 왜 스크롤이 안 되나?**

- 누르고 있는 사이 터치가 버튼에 전달됐고, 스크롤 뷰가 `touchesShouldCancel(in:)`로 물었을 때 UIControl은 기본 `false`라 버튼 터치를 취소하지 못하기 때문이다. 바로 드래그하면 버튼이 터치를 받기 전에 스크롤로 판정돼 스크롤된다

## 참고 자료

**공식**

- [Coordinating multiple gesture recognizers](https://developer.apple.com/documentation/uikit/coordinating-multiple-gesture-recognizers) — 한 번에 한 제스처, 팬 vs 스와이프
- [Preferring one gesture over another](https://developer.apple.com/documentation/uikit/preferring-one-gesture-over-another) — 싱글/더블탭, delegate는 한쪽만
- [Allowing the simultaneous recognition of multiple gestures](https://developer.apple.com/documentation/uikit/allowing-the-simultaneous-recognition-of-multiple-gestures)
- [require(toFail:)](https://developer.apple.com/documentation/uikit/uigesturerecognizer/require(tofail:))
- [gestureRecognizer(_:shouldRecognizeSimultaneouslyWith:)](https://developer.apple.com/documentation/uikit/uigesturerecognizerdelegate/gesturerecognizer(_:shouldrecognizesimultaneouslywith:)) — true 보장, false 비보장
- [UIGestureRecognizerDelegate](https://developer.apple.com/documentation/uikit/uigesturerecognizerdelegate) — 하위 뷰 인식기와의 실패 관계 예제
- [UIControl](https://developer.apple.com/documentation/uikit/uicontrol)
- [beginTracking(_:with:)](https://developer.apple.com/documentation/uikit/uicontrol/begintracking(_:with:)) · [continueTracking(_:with:)](https://developer.apple.com/documentation/uikit/uicontrol/continuetracking(_:with:)) · [endTracking(_:with:)](https://developer.apple.com/documentation/uikit/uicontrol/endtracking(_:with:))
- [UIControl.Event](https://developer.apple.com/documentation/uikit/uicontrol/event) · [sendActions(for:)](https://developer.apple.com/documentation/uikit/uicontrol/sendactions(for:))
- [UIView.gestureRecognizerShouldBegin(_:)](https://developer.apple.com/documentation/uikit/uiview/gesturerecognizershouldbegin(_:)) — UISlider 예, 호출 시점
- [Attaching gesture recognizers to UIKit controls](https://developer.apple.com/documentation/uikit/attaching-gesture-recognizers-to-uikit-controls) — 컨트롤 예외 목록, 컨트롤에 직접 붙이기
- [delaysContentTouches](https://developer.apple.com/documentation/uikit/uiscrollview/delayscontenttouches)
- [WWDC14 235 — Advanced Scrollviews and Touch Handling Techniques](https://developer.apple.com/videos/play/wwdc2014/235/) — 스크롤 뷰의 인식기 세 개
- [Apple Developer Forums 129511](https://developer.apple.com/forums/thread/129511) — 시트 안 커스텀 컨트롤 터치 취소 (사용자 답변)
- [Apple Developer Forums 756542](https://developer.apple.com/forums/thread/756542) — 셀 안 버튼 반응 지연 = `delaysContentTouches`
- [Apple Developer Forums 797322](https://developer.apple.com/forums/thread/797322) — 한 selector에 여러 이벤트 등록 시 구분 불가

**외부**

- [WWDCNotes — WWDC14 235](https://wwdcnotes.com/documentation/wwdc14-235-advanced-scrollviews-and-touch-handling-techniques/) — 세션 요약, Touch Delay 인식기 구현 예 (커뮤니티 작성)
- [DeveloperLx/Notes](https://github.com/DeveloperLx/Notes) — `touchesShouldCancel(in:)` 문서 문구 인용, 버튼 위 스크롤 해법
- [Matt Neuburg, Programming iOS 6 — UIControl](https://www.oreilly.com/library/view/programming-ios-6/9781449365783/ch25s05.html) — 컨트롤 이벤트 분류 (2013년, iOS 6 기준)
