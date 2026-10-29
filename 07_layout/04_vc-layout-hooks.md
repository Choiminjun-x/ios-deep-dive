# VC 레이아웃 훅

> 작성일: 2026-10-29

## 큰 그림

VC의 `view`가 `layoutSubviews`를 돌 때 그 앞뒤로 VC에게 알려 준다.

```
view.layoutSubviews 시작 전  → viewWillLayoutSubviews()
view.layoutSubviews          → 제약대로 서브뷰 frame 배치
view.layoutSubviews 끝난 뒤  → viewDidLayoutSubviews()
```

첫 표시 때 순서 (Apple 문서 기준):

```
viewWillAppear
 → viewIsAppearing
 → viewWillLayoutSubviews
 → 레이아웃
 → viewDidLayoutSubviews
 → 화면 표시
 → viewDidAppear
```

[렌더 루프와 첫 프레임](../02_app-lifecycle/06_render-loop-first-frame.md) 4번 실험 로그와 같은 흐름이다.

## 1. 두 메서드

| | `viewWillLayoutSubviews` | `viewDidLayoutSubviews` |
|---|---|---|
| 시점 | view가 서브뷰를 배치하기 직전 | 배치가 끝난 뒤 |
| 기본 구현 | 아무것도 안 함 | 아무것도 안 함 |
| 주로 하는 일 | 배치 전에 바꿀 것 | 확정된 `view.bounds`로 계산 |

`viewDidLayoutSubviews`가 불렸다고 각 서브뷰 내부 레이아웃까지 끝난 건 아니다. 서브뷰는 각자 자기 레이아웃을 책임진다.

## 2. 여러 번 불린다

레이아웃 메서드는 view가 `layoutSubviews`를 돌 때마다 불리고, 전환 중에도 여러 번, 화면에 보이는 동안 언제든 불릴 수 있다. 02/06에서 VC 레이아웃이 두 번 돈 것도 이 범위 안의 정상 동작이다. 두 번째 원인이 safe area · trait인지는 확인 필요.

그래서 여기엔 "여러 번 불려도 결과가 같은 일"만 둔다.

| 넣어도 됨 | 넣으면 안 됨 |
|---|---|
| `bounds` 기준 frame 계산, 레이어 `cornerRadius` · `shadowPath` 갱신 | 서브뷰 추가, 제약 새로 만들기, 네트워크 요청, 옵저버 등록 |

## 3. "한 번만, 크기 확정 후"가 필요하면 → viewIsAppearing

iOS 17에서 추가됐고 iOS 13까지 back-deploy된다. `viewWillAppear` 시점엔 trait과 geometry가 아직 최신이 아니지만 `viewIsAppearing`에서는 최신이다.

| | 너무 이르다 | 너무 자주 | 딱 맞음 |
|---|---|---|---|
| 메서드 | `viewWillAppear` | `viewDidLayoutSubviews` | `viewIsAppearing` |

WWDC23은 이걸 "Goldilocks 콜백"이라고 부른다.

iOS 16 미만에서는 중첩된 자식 VC에서 이 콜백이 불리지 않는 경우가 있는 알려진 이슈가 있다 (Apple Frameworks Engineer 답변). 최소 지원 버전이 iOS 15 이하라면 자식 VC에서 의존하지 않도록 주의한다.

### 실무에서

- **`viewDidLoad`에서 frame을 읽었더니 0 또는 스토리보드 크기**: 아직 레이아웃 전이다 → `viewIsAppearing` 또는 `viewDidLayoutSubviews`
- **`viewDidLayoutSubviews`에 `addSubview`나 제약 추가를 넣었다**: 매번 쌓이거나, 레이아웃을 다시 무효화해 무한 루프가 된다
- **그라데이션 레이어 크기가 회전 후 안 맞는다**: `viewDidLayoutSubviews`(또는 커스텀 뷰의 `layoutSubviews`)에서 `layer.frame = bounds`로 맞춘다. 여러 번 불려도 결과가 같은 대표적인 일이다
- **`super` 호출**: 기본 구현은 비어 있지만 상위 클래스가 커스텀 VC일 수 있으니 습관적으로 호출한다

## 핵심 정리

1. `viewWillLayoutSubviews` / `viewDidLayoutSubviews`는 VC의 `view`가 `layoutSubviews`를 돌 때 앞뒤로 불린다.
2. 여러 번 불리므로 여러 번 불려도 결과가 같은 일만 둔다.
3. 표시될 때 한 번, 크기·trait이 확정된 뒤 할 일은 `viewIsAppearing`(iOS 17+, iOS 13까지 back-deploy)에 둔다.

## 셀프 체크

**Q1. `viewDidLayoutSubviews`가 불리면 모든 서브뷰의 내부 레이아웃이 끝난 것인가?**

- 아니다. VC `view` 바로 아래 서브뷰 배치까지다. 서브뷰 내부는 각자 책임진다

**Q2. `viewDidLayoutSubviews`에 `addSubview`를 넣으면?**

- 여러 번 불리므로 뷰가 쌓이거나, 레이아웃을 다시 무효화해 무한 루프가 될 수 있다

**Q3. `viewWillAppear` 대신 `viewIsAppearing`을 쓰는 이유는?**

- `viewWillAppear` 시점엔 trait · geometry가 최신이 아니고, `viewIsAppearing`에서는 최신이다. 그러면서 표시될 때 한 번만 불린다

## 참고 자료

**공식**

- [viewWillLayoutSubviews()](https://developer.apple.com/documentation/uikit/uiviewcontroller/viewwilllayoutsubviews())
- [viewDidLayoutSubviews()](https://developer.apple.com/documentation/uikit/uiviewcontroller/viewdidlayoutsubviews())
- [viewIsAppearing(_:)](https://developer.apple.com/documentation/uikit/uiviewcontroller/viewisappearing(_:)) — 여러 번 불리는 레이아웃 메서드와의 차이
- [Displaying and managing views with a view controller](https://developer.apple.com/documentation/uikit/displaying-and-managing-views-with-a-view-controller) — 표시 순서
- [What's new in UIKit (WWDC23 10055)](https://developer.apple.com/videos/play/wwdc2023/10055/) — iOS 13 back-deploy
- [Apple Developer Forums 749169](https://developer.apple.com/forums/thread/749169) — iOS 16 미만 자식 VC 이슈 (Frameworks Engineer 답변)

**외부**

- [UIKit View Lifecycle - viewIsAppearing (Use Your Loaf)](https://useyourloaf.com/blog/uikit-view-lifecycle-viewisappearing/)
