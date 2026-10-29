# setNeedsLayout · layoutIfNeeded · layoutSubviews

> 작성일: 2026-10-29

## 큰 그림

[01](01_layout-cycle.md)의 ② 레이아웃 단계를 다루는 세 메서드다. "예약 / 지금 당장 / 실제 작업"으로 나눠 보면 끝이다.

```
setNeedsLayout()   "다음 commit 때 레이아웃 해 줘"  → 바로 리턴
layoutIfNeeded()   "예약된 게 있으면 지금 당장 해"  → 그 자리에서 실행
layoutSubviews()   실제로 서브뷰 frame을 놓는 곳     → 시스템이 부름 (직접 호출 X)
```

## 1. 세 메서드

**`setNeedsLayout()`**

요청을 메모만 하고 바로 리턴한다. 다음 업데이트 사이클까지 기다리므로 여러 뷰를 무효화해 두고 한 사이클에 몰아서 처리할 수 있다. 기본 선택은 이쪽이다.

**`layoutIfNeeded()`**

받은 뷰를 루트로 그 아래 서브트리를 즉시 레이아웃한다. 대기 중인 레이아웃이 없으면 아무것도 바꾸지 않고 콜백도 부르지 않는다. "표시 없이 부르면 공짜, 표시 있으면 지금 비용 지불"이다.

**`layoutSubviews()`**

기본 구현은 설정한 제약으로 서브뷰의 크기와 위치를 정한다. override는 autoresizing이나 제약만으로 원하는 배치가 안 될 때만 한다. 직접 호출하지 말고 `setNeedsLayout`이나 `layoutIfNeeded`를 쓴다.

| | `setNeedsLayout` | `layoutIfNeeded` |
|---|---|---|
| 언제 실행 | 다음 commit | 지금 |
| 표시 없을 때 | 표시를 붙임 | 아무 일 없음 |
| 비용 | 쌈 (모아서 한 번) | 즉시 계산, 반복하면 비쌈 |
| 언제 쓰나 | 기본 | 바뀐 frame이 지금 꼭 필요할 때 |

## 2. 자주 보는 패턴

**제약 애니메이션**

```swift
heightConstraint.constant = 200      // 표시만 붙음
UIView.animate(withDuration: 0.3) {
    self.view.layoutIfNeeded()       // 애니메이션 블록 안에서 지금 레이아웃 → frame 변화가 애니메이션됨
}
```

`layoutIfNeeded`를 블록 밖에 두거나 빠뜨리면 애니메이션 없이 툭 바뀐다. 부모(`self.view`)에 부르는 이유는 바뀐 뷰와 형제들까지 함께 다시 배치되게 하기 위해서다.

**제약 바꾼 직후 frame 읽기**

```swift
label.text = longText
print(label.frame)        // 옛날 값
view.layoutIfNeeded()
print(label.frame)        // 새 값
```

### 실무에서

- `layoutSubviews()` 직접 호출 → 대신 `setNeedsLayout()`
- 스크롤·셀 구성 같은 반복 경로에서 `layoutIfNeeded()` 남발 → commit hitch 원인 (02/06 실무 항목과 같은 이야기)
- `layoutSubviews` 안에서 부모·형제 뷰에 `setNeedsLayout` → 무한 레이아웃

## 핵심 정리

1. `setNeedsLayout`은 예약, `layoutIfNeeded`는 예약된 게 있으면 즉시 실행, `layoutSubviews`는 시스템이 부르는 실제 작업이다.
2. 기본은 `setNeedsLayout`이고, `layoutIfNeeded`는 바뀐 frame이 지금 필요할 때(제약 애니메이션, 직후 frame 읽기)만 쓴다.
3. `layoutSubviews`는 직접 부르지 않는다.

## 셀프 체크

**Q1. 표시가 없는 상태에서 `layoutIfNeeded()`를 부르면?**

- 아무것도 바꾸지 않고 레이아웃 콜백도 부르지 않고 끝난다

**Q2. 제약 애니메이션에서 `layoutIfNeeded()`를 애니메이션 블록 안에서 부르는 이유는?**

- 블록 안에서 레이아웃이 실행돼야 frame 변화가 애니메이션으로 기록된다. 밖에 두면 즉시 바뀐다

**Q3. `text`만 바꿨는데 왜 레이아웃이 다시 도나?**

- 레이블의 intrinsic content size가 무효화되기 때문이다 (→ [03](03_auto-layout-engine.md))

## 참고 자료

**공식**

- [setNeedsLayout()](https://developer.apple.com/documentation/uikit/uiview/setneedslayout())
- [layoutIfNeeded()](https://developer.apple.com/documentation/uikit/uiview/layoutifneeded())
- [layoutSubviews()](https://developer.apple.com/documentation/uikit/uiview/layoutsubviews())
- [Find and fix hitches in the commit phase (Tech Talk 10856)](https://developer.apple.com/videos/play/tech-talks/10856/) — `layoutIfNeeded` 남용 주의

**외부**

- [iOS Layout (hyosing92, Medium)](https://medium.com/@hyosing92/ios-layout-77fe68869b94) — 제약 애니메이션에서 `layoutIfNeeded` 쓰는 패턴
