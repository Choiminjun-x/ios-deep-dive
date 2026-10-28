# UIGestureRecognizer

> 작성일: 2026-10-28

## 큰 그림

02 노트 끝의 화살표 `UIApplication.sendEvent → UIWindow.sendEvent → touchesBegan / 버튼 액션`을 자세하게 펼친 그림이다.

```
손가락 닿음
 → ① hit-test: 이 터치의 주인 뷰(hitView) 결정            (01 노트 2번)
 → ② hitView부터 윈도우까지 올라가며 붙어 있는 인식기 수집
 → ③ UIWindow.sendEvent: 인식기들에 먼저, 그다음 hitView에 전달
 → ④ 인식기가 "판정 성공"하면 뷰에는 touchesCancelled, 이후 터치는 인식기만 받음
    인식기가 "판정 실패"하면 뷰는 끝까지 정상적으로 받음
```

인식기는 터치를 지켜보다 의미를 판정하는 객체이고(1번), 뷰와 같은 터치를 나눠 받는다(2번). 판정은 상태 머신으로 진행되며(3번), 판정 결과가 뷰에 미치는 영향은 세 가지 속성으로 조절한다(4번).

## 1. 인식기란

인식기: gesture recognizer - "터치 흐름을 지켜보다가 특정 동작인지 판정하는 객체"

터치와 제스처는 다르다 → 손가락이 화면에 닿으면 앱이 받는 건 좌표와 시간뿐이다. "탭", "드래그" 같은 의미는 들어 있지 않다.

```
UIKit이 주는 것 (터치, 원재료)
 began (100,200) t=0.00
 moved (101,200) t=0.03
 moved (140,205) t=0.10
 ended (180,210) t=0.15

사람이 원하는 것 (제스처, 의미)
 "오른쪽으로 드래그했다"
```

원재료를 의미로 바꾸는 판정 로직이 필요하다 → 그 로직을 담은 객체가 "인식기"다.

### 인식기가 있으면: 판정은 맡기고 결과만 받는다

```swift
let tap = UITapGestureRecognizer(target: self, action: #selector(didTap))
someView.addGestureRecognizer(tap)

@objc func didTap(_ gr: UITapGestureRecognizer) { print("탭!") }
```

판정은 UIKit이 만든 인식기가 하고, 내 코드는 결과만 받는다. 공식 문서도 인식기를 뷰에서 터치를 다루는 가장 간단한 방법으로 소개한다.

```
someView ── 붙어 있음 ── [UITapGestureRecognizer]  ← 터치를 지켜보며 판정
                               │ "탭이다!"
                               ↓ target-action
                         ViewController.didTap
```

인식기 없이 같은 일을 하려면 `touchesBegan`/`Ended`에서 이동 거리와 시간을 직접 재서 판정해야 한다. 뷰마다 코드가 반복되고, 기준값이 시스템과 어긋나고, 여러 제스처를 함께 판정하기 어렵다.

### 인식기의 정체

- `NSObject` 서브클래스, 화면에 그려지지 않는다
- `view.addGestureRecognizer(_:)`로 뷰에 붙인다. 한 뷰에 여러 개 붙일 수 있다
- target-action, 판정되면 지정한 메서드를 호출한다. action 시그니처는 인자 없음 또는 `UIGestureRecognizer` 하나
- Responder Chain에 있지 않고, 별개다

### 인식기 종류

| 인식기 | 판정하는 것 | 종류 |
|---|---|---|
| `UITapGestureRecognizer` | 탭 (횟수·손가락 수 지정) | discrete |
| `UISwipeGestureRecognizer` | 스와이프 (방향) | discrete |
| `UILongPressGestureRecognizer` | 길게 누르기 | continuous |
| `UIPanGestureRecognizer` | 드래그 | continuous |
| `UIScreenEdgePanGestureRecognizer` | 화면 가장자리에서 시작하는 드래그 | continuous |
| `UIPinchGestureRecognizer` | 두 손가락 벌리기·오므리기 | continuous |
| `UIRotationGestureRecognizer` | 두 손가락 회전 | continuous |

### 실무에서: 이미 쓰고 있다

- 키보드 내리기용 `UITapGestureRecognizer`를 `view`에 붙이는 코드
- `UIScrollView`의 스크롤: 내부에 `panGestureRecognizer`(줌이 있으면 `pinchGestureRecognizer`도)를 가지고 있다
- 내비게이션 뒤로 가기 스와이프: `navigationController?.interactivePopGestureRecognizer`
- 셀 롱프레스 메뉴나 드래그 앤 드롭도 내부적으로 인식기를 쓴다 (내부 구성은 확인 필요)
- `UITextField`도 내부 인식기를 여러 개 가진다 (셀프 체크 Q5 실험)

## 2. 전달 순서: 인식기 먼저, 그다음 뷰

### hit-test: 주인 뷰 결정

- 좌표와 뷰 상태(`isHidden`, `isUserInteractionEnabled`, `alpha` 등)만 보고 주인을 결정한다
- 인식기는 고려하지 않는다. 그래서 hit-test에서 탈락한 뷰의 인식기는 후보가 될 수 없다 (예: `isUserInteractionEnabled`가 기본 `false`인 `UIImageView`에 붙인 탭 인식기)
- 확인 필요: 01 노트 다이어그램은 hit-test를 `UIWindow.sendEvent` 안에 그렸지만, Neuburg 책은 hit-test 후 `sendEvent`를 호출한다고 설명한다. `hitTest` 브레이크포인트의 `bt`로 확인한다

### 이 터치를 지켜볼 인식기 모으기

hitView와 그 위로 슈퍼뷰를 거쳐 윈도우까지, 경로에 붙은 인식기가 전부 후보다.

```
window
 └ VC.view          ← [Tap] 키보드 내리기용
    └ tableView     ← [Pan] 스크롤 (내장)
       └ cell
          └ myView  ← hitView, 인식기 없음

손가락이 myView에 닿으면 → 지켜보는 인식기: Pan, Tap
```

→ myView에는 인식기가 없지만, 부모들의 인식기 두 개가 이 터치를 지켜본다. `touch.gestureRecognizers`로 볼 수 있다.

```
내려가며 주인 찾기 (hit-test)    window → VC.view → tableView → cell → myView
올라가며 인식기 모으기           myView → cell → tableView → VC.view → window
윈도우가 양쪽에 직접 전달        window → 인식기들 / window → myView
```

전달은 경로의 뷰를 하나씩 거치지 않는다. 상위 뷰가 터치를 받는 건 `myView`가 `super.touchesBegan`으로 넘겨 Responder Chain을 탈 때뿐이다.

### 전달: 인식기 먼저, 그다음 뷰

```
UIWindow.sendEvent
 → 인식기들.touchesBegan   ("판정 시작")
 → myView.touchesBegan     (뷰도 받음)
 → 인식기들.touchesMoved
 → myView.touchesMoved
 ...
```

→ 순서일 뿐, 독점이 아니다. 기본값(`delaysTouchesBegan = false`)에서는 판정 전까지 인식기와 뷰가 둘 다 받는다.

### 판정 결과에 따라 갈린다

VC.view에 `UIPanGestureRecognizer`를 붙이고 그 안의 myView를 만지는 경우

탭만 했을 때: Pan 판정 실패

```
began  → Pan 받음 → myView.touchesBegan
ended  → Pan 받음 → "움직임이 없으니 드래그 아님" (실패)
       → myView.touchesEnded          ← 뷰는 정상적으로 끝까지 받음
```

드래그했을 때: Pan 판정 성공

```
began  → Pan 받음 → myView.touchesBegan
moved  → Pan 받음 → myView.touchesMoved     (아직 판정 중)
moved  → Pan 받음 → "일정 거리 이상 움직임, 드래그다!" (성공)
       → myView.touchesCancelled     ← 지금까지 받던 터치를 취소
moved  → Pan만 받음                  ← 뷰에는 더 이상 안 감
ended  → Pan만 받음
```

→ 인식에 성공하면 남은 터치는 뷰에 전달하지 않고, `touchesCancelled`로 취소한다. 인식하지 못하면 뷰가 터치를 전부 받는다.

`touchesBegan`은 받았는데 `touchesEnded` 대신 `touchesCancelled`가 오는 이 동작을 끄는 옵션이 `cancelsTouchesInView = false`다 (4번).

### UIButton은 인식기가 아니라 터치로 동작한다

`UIButton`에는 기본으로 탭 인식기가 붙어 있지 않다. `UIControl`이 `touchesBegan`/`Moved`/`Ended`를 직접 받아 판정하고, `.touchUpInside`도 `touchesEnded` 안에서 보낸다.

```
UIButton   ← 인식기 없음. touchesXxx로 직접 판정 (뷰 쪽)
myView     ← 인식기 없음
VC.view    ← [Pan]       (인식기 쪽)

드래그하면
began  → Pan 받음 → button.touchesBegan       (하이라이트)
moved  → Pan "드래그다!" (성공)
       → button.touchesCancelled             ← 하이라이트 해제
ended  → Pan만 받음                           → .touchUpInside 없음 → 안 눌림
```

예외: 컨트롤 영역 안의 다음 제스처는 컨트롤이 먼저 처리한다 (공식 문서).

| 컨트롤 | 컨트롤이 이기는 제스처 |
|---|---|
| `UIButton`, `UISwitch`, `UIStepper`, `UISegmentedControl`, `UIPageControl` | 한 손가락 한 번 탭 |
| `UISlider` | 노브 위에서 슬라이더 방향으로 스와이프 |
| `UISwitch` | 노브 위에서 스위치 방향으로 팬 |

그래서 조상에 Tap을 붙여도 버튼의 한 번 탭은 눌리고, 조상의 Pan이나 LongPress는 버튼을 취소한다. 예외를 만드는 원리는 UIControl 편에서 확인한다.

### 실무에서

| 증상 | 원인 | 확인 |
|---|---|---|
| 커스텀 뷰가 `touchesEnded` 대신 `touchesCancelled`를 받음 | 조상의 Pan이나 스크롤 뷰가 판정에 성공함 | `touchesCancelled`에서 `touches.first?.gestureRecognizers` 출력 |
| 키보드 내리기 탭을 붙였더니 셀 선택이 안 됨 | 조상 Tap이 후보가 되고 성공해서 셀 터치를 취소함 | `cancelsTouchesInView = false` |
| 부모에 Pan이 있는 카드·바텀시트 안의 버튼이 살짝만 끌려도 안 눌림 | Pan이 성공해 버튼에 `touchesCancelled` | 컨트롤 예외 목록에 팬 없음 |
| 인식기를 아무리 설정해도 뒤쪽 형제 뷰가 못 받음 | hit-test에서 주인이 정해졌고, 형제의 인식기는 후보가 아님 | 인식기를 공통 부모로 옮김 |
| 어떤 인식기가 개입했는지 모름 | 후보가 조상 전체 | `gestureRecognizer.name`(iOS 11+) 지정 후 출력 |

크래시 스택에서도 두 경로가 구분된다 (02 노트 "크래시 스택 읽기"에 이어서).

| `-[UIWindow sendEvent:]` 위에 보이는 것 | 경로 |
|---|---|
| `_UIGestureEnvironmentUpdate` | 인식기 경로: 제스처 action 안에서 크래시 |
| `-[UIWindow _sendTouchesForEvent:]` | 뷰 경로: `touchesXxx`나 버튼 액션 안에서 크래시 |

비공개 심볼이라 버전마다 바뀔 수 있다. 구버전에서는 인식기 경로가 `_sendGesturesForEvent:`로 보였다.

## 3. 상태 머신

인식기는 판정하는 동안 `state`로 진행 상황을 나타낸다. 모든 인식기는 `.possible`에서 시작한다.

| 상태 | rawValue | 의미 | action 호출 |
|---|---|---|---|
| `.possible` | 0 | 지켜보는 중, 아직 판정 전 | X |
| `.began` | 1 | (연속) 제스처 시작 | O |
| `.changed` | 2 | (연속) 진행 중, 값이 바뀜 | O (계속) |
| `.ended` | 3 | (연속) 정상 종료 | O |
| `.recognized` | 3 | (단발) 인식 성공. `.ended`와 같은 값 | O |
| `.cancelled` | 4 | (연속) 시작했지만 도중에 취소 | O (마지막 1번) |
| `.failed` | 5 | 판정 실패 | X |

### discrete vs continuous

```
discrete (Tap, Swipe)
 .possible ─┬→ .recognized   action 1번
            └→ .failed       action 없음

continuous (Pan, LongPress, Pinch, Rotation)
 .possible ─┬→ .began → .changed … → .ended       action: began, changed마다, ended
            │                    └→ .cancelled     action: 마지막 1번
            └→ .failed  (began 전에 실패)          action 없음

끝난 뒤 (ended/recognized/cancelled/failed)
 → UIKit이 reset() 호출 → state가 자동으로 .possible로 돌아감
```

### 인식(= 뷰 취소) 시점이 종류마다 다르다

discrete는 `.recognized`, continuous는 `.began`이 될 때가 "인식"이고, 이때 뷰 터치가 취소된다. 공식 문서도 "인식"이 꼭 Recognized 상태를 뜻하지는 않는다고 주의를 준다.

- discrete - Tap: 손가락을 뗄 때
- continuous - Pan: 일정 거리를 움직였을 때 (정확한 거리는 문서에 없음, 확인 필요) / LongPress: 0.5초(`minimumPressDuration` 기본값)가 지났을 때

### 롱프레스: 이벤트 없이 시간으로 넘어간다

아무 이벤트가 없어도 10pt(`allowableMovement`) 이내로 0.5초 동안 누르고 있으면 `.possible`에서 `.began`으로 넘어간다.

```
0.0s  닿음      .possible   (판정 대기, 타이머 시작)
0.5s  시간 충족  .possible → .began   ← 새 터치 이벤트 없이 저절로 넘어감
                action 호출
...   가만히    .began 유지            ← action 추가 호출 없음
1.0s  손 뗌     .began → .ended
                action 호출
```

- `.began` 후 손가락이 움직이거나 터치가 변하면 `.changed`. 실기기는 손가락이 미세하게 떨려서 `.changed`가 끼는 경우가 많다
- 0.5초 전에 `allowableMovement`을 넘으면 `.failed` → 뷰는 끝까지 정상으로 받는다
- 이벤트 없이 넘어가는 경로가 런루프의 어느 칸인지는 확인 필요

### 실무에서

롱프레스 핸들러가 두 번 불린다 → 연속 제스처라 `.began`과 `.ended`(움직이면 `.changed`도)마다 action이 불리기 때문이다. `.began`으로 넘어가면 반드시 끝맺음(`.ended`/`.cancelled`)이 온다.

```swift
@objc func didLongPress(_ gr: UILongPressGestureRecognizer) {
    guard gr.state == .began else { return }   // 한 번만 실행
    showMenu()
}
```

`.cancelled`를 처리하지 않으면 UI가 중간에 멈춘다. 전화 수신, 다른 인식기와의 경쟁, 도중에 `isEnabled = false` 등으로 취소될 수 있다.

```swift
@objc func didPan(_ gr: UIPanGestureRecognizer) {
    switch gr.state {
    case .began:              startDrag()
    case .changed:            updateDrag(gr.translation(in: view))
    case .ended:              finishDrag()
    case .cancelled, .failed: rollbackDrag()   // 원위치. 빠지기 쉬움
    default: break
    }
}
```

디버깅: action 첫 줄에 `print(gr.name ?? "", gr.state.rawValue)`. 시뮬레이터 클릭과 실기기 손가락은 `.changed` 횟수가 다를 수 있다.

## 4. 터치 취소·지연

2번의 기본 동작("같이 받다가, 인식되면 뷰 취소")을 바꾸는 스위치 세 개다. 건드리는 시점이 다르다.

```
터치 흐름:   began ──── moved … ──── ended
              │                       │
delaysTouchesBegan     인식 전에 뷰에 began을 줄지 말지     (기본 false)
cancelsTouchesInView   인식된 순간 뷰 터치를 취소할지        (기본 true)
delaysTouchesEnded     판정 중일 때 뷰에 ended를 바로 줄지   (기본 true)
```

### cancelsTouchesInView: 인식 후 뷰를 끊을지

```
true (기본)   Tap 인식 → view.touchesCancelled → 이후 뷰는 못 받음
false        Tap 인식 → 뷰는 아무 일 없음      → touchesEnded까지 정상으로 받음
```

`false`면 인식기 action과 뷰 처리가 둘 다 일어난다.

인식기마다 따로 가진 값이다. 내 인식기를 `false`로 해도, 같은 터치를 지켜보는 다른 인식기가 성공하면 그 인식기 설정대로 취소된다 (셀프 체크 Q5).

### delaysTouchesBegan: 판정 끝날 때까지 뷰를 기다리게 할지 - 뷰 전달 지연

```
false (기본)  began → 인식기 + view.touchesBegan (바로)
true         began → 인식기만. 뷰는 대기
               ├ 인식 성공 → 뷰는 began을 끝내 못 받음 (cancelled도 없음. 시작한 적이 없으니까)
               └ 인식 실패 → 그제야 view.touchesBegan (+ 필요하면 touchesMoved로 현재 위치)
```

판정 전에 뷰가 반응하면 곤란할 때 쓴다 (드래그할 때 아래 버튼 하이라이트 깜빡임 등). 대가는 반응 지연이다. `UIScrollView.delaysContentTouches`가 같은 발상이다.

### delaysTouchesEnded: 판정 중이면 ended를 미룰지

```
true (기본)   ended → 인식기 판정 중이면 뷰의 ended 보류
               ├ 인식 성공 → view.touchesCancelled
               └ 인식 실패 → view.touchesEnded (늦게 도착)
false        ended → 바로 view.touchesEnded
```

손을 뗀 뒤에도 판정이 끝나지 않는 인식기에서 티가 난다.

```
조상에 더블탭 인식기, 그 안의 커스텀 뷰를 한 번 탭
 ended  → 더블탭: "두 번째 탭이 올 수도 있음" (.possible 유지)
        → view.touchesEnded 보류
 (잠시 대기)
        → 더블탭: 두 번째 탭이 안 옴 → .failed
        → 그제야 view.touchesEnded
```

→ "더블탭 인식기를 붙였더니 한 번 탭 반응이 느려졌다". 보류 시간은 문서에 없어 확인 필요.

### 한눈에 비교

| 속성 | 기본값 | 건드리는 시점 | true일 때 | false일 때 |
|---|---|---|---|---|
| `cancelsTouchesInView` | `true` | 인식된 순간 | 뷰 터치 취소 | 뷰도 끝까지 받음 (둘 다 동작) |
| `delaysTouchesBegan` | `false` | 터치 시작 | 실패할 때까지 뷰의 began 보류 | 뷰가 바로 began 받음 |
| `delaysTouchesEnded` | `true` | 터치 끝 | 판정 중이면 뷰의 ended 보류 | 뷰가 바로 ended 받음 |

### 실무에서

키보드 내리기

```swift
let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
tap.cancelsTouchesInView = false   // 이게 없으면 셀 선택·셀 안 스위치 등이 막힘
view.addGestureRecognizer(tap)

@objc private func dismissKeyboard() { view.endEditing(true) }
```

셀 선택은 셀이 `touchesEnded`를 정상으로 받아야 일어난다. `touchesCancelled`는 "이 터치는 없던 걸로"라서 선택되지 않는다.

```
셀 위를 탭
 → cell.touchesEnded (취소되지 않고 정상 도착)
 → super.touchesEnded → Responder Chain을 타고 테이블 뷰로
 → 선택 처리 → delegate.tableView(_:didSelectRowAt:)
```

- `touchesEnded`는 필요조건이다. `allowsSelection = false`, `willSelectRowAt`이 `nil` 반환이면 선택 안 됨. 코드로 `selectRow`를 부르면 `didSelectRowAt`은 안 불림
- 커스텀 셀에서 touches 메서드를 override하고 `super`를 안 부르면 선택이 안 된다
- 테이블 뷰 내부의 정확한 선택 경로는 확인 필요 (`didSelectRowAt` 브레이크포인트의 `bt`)

포럼 사례: 윈도우에 탭 인식기 + 내비게이션 바 버튼 (2025-10, 답변 없음)

| 설정 | 결과 |
|---|---|
| 기본값 | 메뉴만 |
| `cancels = false` | 윈도우 + 메뉴 |
| `delaysBegan = true` | 메뉴만 |
| `cancels = false` + `delaysBegan = true` | 윈도우만 |
| `cancels = true` + `delaysBegan = true` | 메뉴만 |

해석(확인 필요): `cancels = false`면 컨트롤이 인식기를 막지 않아 탭이 인식되고, `delaysBegan = true`로 붙잡혀 있던 began은 버려져 버튼이 시작조차 못 한다. UIControl 편에서 다시 본다.

## 핵심 정리

1. 인식기는 터치 흐름(좌표·시간)을 지켜보다 의미(탭·드래그)를 판정하는 객체다. 뷰에 붙이고 target-action으로 결과를 알리며, Responder Chain과는 별개다.
2. hit-test로 주인 뷰를 정하고(인식기는 안 봄), 주인부터 윈도우까지 붙은 인식기를 모으고, 윈도우가 인식기에 먼저 그다음 주인 뷰에 직접 전달한다.
3. 판정 전까지는 인식기와 뷰가 둘 다 받는다. 인식에 성공하면 뷰는 `touchesCancelled`를 받고 이후 터치는 인식기만 받는다. 실패하면 뷰가 끝까지 받는다.
4. `UIButton`은 인식기가 아니라 `touchesXxx`로 동작한다. 조상 인식기가 성공하면 취소되지만, 한 번 탭 등 일부 제스처는 컨트롤이 우선한다.
5. discrete는 `.possible → .recognized/.failed`, continuous는 `.possible → .began → .changed … → .ended/.cancelled`. 인식 시점은 discrete가 `.recognized`, continuous가 `.began`이다.
6. continuous의 action은 상태가 바뀔 때마다 불린다. 롱프레스는 `guard .began`, 드래그는 `.cancelled` 처리가 필요하다.
7. `cancelsTouchesInView`(인식 후 취소), `delaysTouchesBegan`(began 보류), `delaysTouchesEnded`(ended 보류)는 인식기마다 따로 가진 값이다. 같은 터치를 지켜보는 다른 인식기가 결과를 바꿀 수 있다.

## 셀프 체크

**Q1. 뷰까지 내려가면서 중간에 인식기가 있는지 확인하는 건가?**

- 아니다. 내려가는 hit-test는 인식기를 보지 않고 주인 뷰만 정한다. 인식기는 주인이 정해진 뒤 주인부터 윈도우까지 올라가며 모으고, 윈도우가 인식기와 주인 뷰에 직접 전달한다

**Q2. `VC.view`에 Pan이 있고 그 안 `myView`에 `UIButton`이 있다. 버튼 위에서 드래그하면 버튼이 눌리나?**

- 안 눌린다. 버튼에는 탭 인식기가 내장돼 있지 않고 `touchesXxx`로 동작한다. 버튼은 began·moved를 받다가 Pan이 성공하는 순간 `touchesCancelled`를 받아 `.touchUpInside`가 없다. 취소는 인식기끼리가 아니라 인식기 → 뷰로 간다

**Q3. `VC.view`에 LongPress를 붙이고 그 안의 버튼을 1초 누른 뒤 뗐다. `touchUpInside`는 불리나? LongPress action은 몇 번 불리나?**

- `touchUpInside`는 안 불린다. 롱프레스는 컨트롤 예외 목록에 없어서 0.5초에 `.began`이 되는 순간 버튼에 `touchesCancelled`가 간다
- action은 최소 2번(`.began`, `.ended`)이다. 손가락이 움직이면 `.changed`가 끼어 더 늘어난다. 실제 동작을 한 번만 하려면 `guard gr.state == .began`

**Q4. 셀이 `touchesEnded`를 정상으로 받으면 선택되나?**

- 대체로 그렇다. `touchesEnded`가 Responder Chain으로 테이블 뷰에 가야 선택이 처리된다. 취소되면 선택되지 않는다. 다만 `allowsSelection`, `willSelectRowAt` 등 테이블 뷰 조건도 통과해야 한다

**Q5. 키보드 내리기 탭에 `cancelsTouchesInView = false`를 줬다. 같은 화면에서 텍스트 필드를 탭하면? 탭 action(`endEditing`)과 텍스트 필드의 편집 시작이 모두 일어난다면, 키보드는 결국 어떻게 되나?**

- 전제가 성립하지 않는다. 실험 결과 텍스트 필드 탭에서는 `dismissTap` action이 `cancels` 값과 관계없이 한 번도 불리지 않았다. 키보드는 유지된다

```
텍스트 필드 탭
 → 지켜보는 인식기: 내부 SingleTap 외 다수 + dismissTap
 → 내부 SingleTap 성공 → 편집 시작 + 텍스트 필드 터치 취소
 → dismissTap 실패 → endEditing 안 불림 → 키보드 유지
```

- 지켜보는 인식기는 15개였다: `UITextInteractionNameSingleTap`, `TapAndAHalf`, 두 손가락 커서 이동, 드래그 앤 드롭, 컨텍스트 메뉴 관련, `dismissTap`, `_UISystemGestureGateGestureRecognizer` 등. 이름은 비공개 값이라 버전마다 바뀔 수 있다
- `cancels = false`인데도 텍스트 필드가 `touchesCancelled`를 받았다. 성공한 건 내부 SingleTap이고 그 인식기의 설정(기본 `true`)대로 취소됐다 → `cancelsTouchesInView`는 인식기마다 따로다
- `dismissTap`이 실패한 이유는 내부 SingleTap과의 경쟁으로 보이지만 확인 필요 (인식기 충돌 편에서 `shouldRecognizeSimultaneouslyWith`로 재실험)

## 참고 자료

**공식**

- [UIGestureRecognizer](https://developer.apple.com/documentation/uikit/uigesturerecognizer) — 인식기 먼저 → 뷰, 인식 시 취소, Responder Chain 비참여, 상태 전이, action 시그니처, "recognize ≠ Recognized"
- [Handling UIKit gestures](https://developer.apple.com/documentation/uikit/handling-uikit-gestures) — 정의, target-action, discrete vs continuous
- [Touches, presses, and gestures](https://developer.apple.com/documentation/uikit/touches-presses-and-gestures) — 인식기와 `touchesXxx` 직접 처리, 표준 인식기 목록
- [About the gesture recognizer state machine](https://developer.apple.com/documentation/uikit/about-the-gesture-recognizer-state-machine) — action 호출 시점, 취소 시 마지막 action, reset 후 `.possible`
- [reset()](https://developer.apple.com/documentation/uikit/uigesturerecognizer/reset())
- [cancelsTouchesInView](https://developer.apple.com/documentation/uikit/uigesturerecognizer/cancelstouchesinview) · [delaysTouchesBegan](https://developer.apple.com/documentation/uikit/uigesturerecognizer/delaystouchesbegan) · [delaysTouchesEnded](https://developer.apple.com/documentation/uikit/uigesturerecognizer/delaystouchesended)
- [UITouch.gestureRecognizers](https://developer.apple.com/documentation/uikit/uitouch/gesturerecognizers)
- [UILongPressGestureRecognizer](https://developer.apple.com/documentation/uikit/uilongpressgesturerecognizer) · [Handling long-press gestures](https://developer.apple.com/documentation/uikit/handling-long-press-gestures) — `minimumPressDuration`, `allowableMovement`, `.changed` 조건
- [Attaching gesture recognizers to UIKit controls](https://developer.apple.com/documentation/uikit/attaching-gesture-recognizers-to-uikit-controls) — 컨트롤 예외 목록
- [Coordinating multiple gesture recognizers](https://developer.apple.com/documentation/uikit/coordinating-multiple-gesture-recognizers) — 기본적으로 한 번에 한 제스처만 인식
- [Handling row selection in a table view](https://developer.apple.com/documentation/uikit/handling-row-selection-in-a-table-view) — 코드로 선택하면 delegate 미호출
- [WWDC12 233 — Building Advanced Gesture Recognizers](https://developer.apple.com/videos/play/wwdc2012/233/)

**외부**

- [Matt Neuburg, Programming iOS 6 — Touch Delivery](https://www.oreilly.com/library/view/programming-ios-6/9781449365783/ch18s06.html) — hit-test → sendEvent → 인식기 → 뷰 순서. iOS 6 시절 책이라 hit-test 시점은 현행 확인 필요
- [Apple Developer Forums 803956 (2025-10)](https://developer.apple.com/forums/thread/803956) — 윈도우 탭 인식기와 바 버튼 아이템 조합 실험. 답변 없음
- 크래시 스택 사례: [iOSDropDown #92](https://github.com/jriosdev/iOSDropDown/issues/92) (`_UIGestureEnvironmentUpdate`), [ActionSheetPicker #417](https://github.com/skywinder/ActionSheetPicker-3.0/issues/417) (`_sendTouchesForEvent:` → `UIControl touchesEnded`), [between-kit #12](https://github.com/ice3-software/between-kit/issues/12) (구버전 `_sendGesturesForEvent:`)
- [Habr Q&A 102123](https://qna.habr.com/q/102123) — 컬렉션 뷰 셀 `touchesEnded`에서 `super`를 건너뛰면 선택 안 됨. iOS 7 무렵 글
- [technetexperts — hit-test가 제스처 인식보다 먼저](https://www.technetexperts.com/?p=16099) — 형제 뷰 함정. 작성 시점 확인 필요
