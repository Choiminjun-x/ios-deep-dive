# Auto Layout 엔진

> 작성일: 2026-10-29

## 큰 그림

제약을 넣으면 누가 frame을 계산하나.

```
내가 쓴 제약 (leading = 16, width = 100 …)
 + 뷰가 스스로 원하는 크기 (intrinsic content size)
 → Auto Layout 엔진이 방정식으로 바꿔서 풂
 → 뷰마다 frame 값이 나옴
 → layoutSubviews에서 그 값으로 frame 설정
```

엔진은 window에 붙어 있는 내부 객체이고, 제약을 추가하면 그 제약에 해당하는 방정식이 엔진에 들어간다 (WWDC18 220, 외부 정리 기준). 직접 만질 일은 없다. "제약 = 방정식, 엔진 = 푸는 쪽"으로 기억한다.

## 1. updateConstraints: 제약을 고치는 자리

[01](01_layout-cycle.md)의 ① 단계다. `setNeedsUpdateConstraints()`로 예약하면 시스템이 레이아웃 직전에 `updateConstraints()`를 부른다.

Apple 권장은 반대 방향이다. 버튼 탭에 반응한 제약 변경은 action 메서드에서 바로 하는 게 거의 항상 더 깔끔하고, override는 너무 느리거나 중복 변경이 많을 때만 한다.

| | 쓴다면 지킬 것 |
|---|---|
| 마지막 줄 | `super.updateConstraints()` 호출 |
| 금지 | 안에서 `setNeedsUpdateConstraints()` → 무한 루프 |
| 금지 | 매번 전부 비활성화 → 다시 활성화. 바뀐 것만 바꾼다 |

실무에선 거의 override하지 않는다고 봐도 된다.

## 2. intrinsic content size: 뷰가 원하는 크기

`UILabel`, `UIButton`처럼 내용물이 있는 뷰는 "나는 이만큼이면 된다"는 크기를 스스로 안다. 레이블이면 텍스트 크기, 버튼이면 텍스트·이미지 + 여백이다. 그냥 `UIView`는 없다.

그래서 레이블은 위치 제약만 줘도 되고 width·height 제약이 필요 없다. Auto Layout이 intrinsic size를 차원마다 자동 제약으로 바꿔 넣기 때문이다.

```
label.text = longText
 → 레이블이 "내 원하는 크기가 바뀌었다" 표시 (invalidateIntrinsicContentSize)
 → 다음 레이아웃 때 엔진이 새 크기를 반영
 → 그래서 text만 바꿔도 레이아웃이 다시 돈다
```

커스텀 뷰에서 `intrinsicContentSize`를 override했다면, 크기에 영향 주는 값이 바뀔 때 직접 `invalidateIntrinsicContentSize()`를 불러야 다음 레이아웃 패스에 반영된다.

## 3. Hugging / Compression Resistance

intrinsic size에서 나온 자동 제약은 "꼭"이 아니라 우선순위가 있는 "가능하면"이다.

| | 뜻 | 기본값 (레이블, IB) |
|---|---|---|
| Content Hugging | 내용보다 **커지기** 싫은 정도 | 251 |
| Compression Resistance | 내용보다 **작아지기** 싫은 정도 | 750 |

공간이 남거나 모자랄 때 누가 늘어나고 누가 줄어들지를 이 숫자로 정한다.

### 실무에서

- **레이블 두 개가 나란히 있고 하나가 `...`으로 잘린다**: 둘의 Compression Resistance가 같아서 엔진이 아무거나 고른 것이다. 잘려도 되는 쪽을 낮춘다
- **텍스트필드가 레이블 대신 늘어나야 한다**: 레이블 Hugging을 더 높게 (IB가 251 vs 250으로 자동 설정하는 이유)
- **IB에 "Content Priority Ambiguity" 경고**: 위 두 경우처럼 우선순위가 같아 엔진이 못 고르는 상황이다
- **커스텀 뷰 크기가 안 바뀐다**: `intrinsicContentSize` override 후 `invalidateIntrinsicContentSize()` 호출을 빠뜨렸는지 확인한다

## 핵심 정리

1. 엔진은 제약과 intrinsic size를 방정식으로 풀어 frame 값을 낸다.
2. 제약 변경은 action 메서드에서 바로 하는 게 기본이고, `updateConstraints` override는 성능 문제가 있을 때만 쓴다.
3. 내용물이 있는 뷰는 intrinsic size를 가지며, 이것이 자동 제약이 된다. 값이 바뀌면 `invalidateIntrinsicContentSize()`로 알려야 한다.
4. Hugging(커지기 싫음)과 Compression Resistance(작아지기 싫음) 우선순위로 공간 배분을 정한다.

## 셀프 체크

**Q1. 레이블에 width·height 제약을 안 줘도 되는 이유는?**

- intrinsic content size가 차원마다 자동 제약으로 들어가기 때문이다

**Q2. 레이블 두 개 중 하나가 잘릴 때 어느 쪽이 잘릴지 정하려면?**

- 잘려도 되는 쪽의 Compression Resistance를 낮춘다

**Q3. 커스텀 뷰의 값을 바꿨는데 크기가 그대로다. 무엇을 의심하나?**

- `invalidateIntrinsicContentSize()` 호출 누락

## 참고 자료

**공식**

- [updateConstraints()](https://developer.apple.com/documentation/uikit/uiview/updateconstraints())
- [invalidateIntrinsicContentSize()](https://developer.apple.com/documentation/uikit/uiview/invalidateintrinsiccontentsize())
- [Auto Layout Guide: Views with Intrinsic Content Size](https://developer.apple.com/library/archive/documentation/UserExperience/Conceptual/AutolayoutPG/ViewswithIntrinsicContentSize.html) — CHCR 기본값 251/250/750
- [High Performance Auto Layout (WWDC18 220)](https://developer.apple.com/videos/play/wwdc2018/220/)

**외부**

- [WWDC High Performance Auto Layout 정리 (DEV-YONG, velog, 2021)](https://velog.io/@dev-yong/WWDC-High-Performance-Auto-Layout) — window의 엔진, 제약 → 방정식
- [What Is Intrinsic Content Size (Cocoacasts)](https://cocoacasts.com/what-is-intrinsic-content-size-in-swift) — 암묵적 제약, compression resistance 충돌 예시
