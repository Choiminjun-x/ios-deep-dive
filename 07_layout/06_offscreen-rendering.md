# 오프스크린 렌더링

> 작성일: 2026-11-02

## 큰 그림

[05](05_layout-performance-debugging.md)가 commit hitch(앱이 마감을 놓침)를 다뤘다면, 이 노트는 render hitch(Render Server · GPU가 마감을 놓침)의 가장 흔한 원인인 오프스크린 패스를 다룬다.

```
commit (Layout → Display → Prepare → 전송)   ← 앱 프로세스. 늦으면 commit hitch (05)
 → render prepare   Render Server가 레이어 트리를 GPU 명령 파이프라인으로 바꿈
 → render execute   GPU가 최종 텍스처 한 장을 그림   ← 오프스크린 패스는 여기
 → VSync에 표시      늦으면 render hitch
```

Render Server는 앱 밖의 프로세스지만 앱의 레이어 트리를 대신 그리는 것이라, 걸리는 시간은 앱 책임이다.

## 1. 오프스크린 패스

GPU는 레이어를 뒤에서 앞 순서로 최종 텍스처(화면에 나갈 이미지)에 바로 그린다. 그런데 지금 그릴 정보가 부족하면 다른 텍스처에 먼저 그리고, 가공한 뒤 최종 텍스처로 복사해 온다. 이것이 **오프스크린 패스**다.

```
보통        레이어 → 최종 텍스처에 바로 그림
오프스크린   레이어 → 다른 텍스처에 먼저 그림 → 가공(모양 추출 · 잘라내기 · 블러) → 최종 텍스처로 복사
```

작업이 한 번 더 들고 텍스처 전환도 생긴다. 셀마다 몇 개씩 쌓이면 render execute가 VSync 마감을 놓친다.

## 2. 네 가지 원인과 고치는 법

| 종류 | 왜 오프스크린이 필요한가 | 고치는 법 |
|---|---|---|
| 그림자 | 그림자 모양은 레이어와 자식들을 다 그려 봐야 안다 | `shadowPath`로 모양을 직접 알려 준다 |
| 마스크 레이어 | 마스크 밖 픽셀을 덮어쓰지 않으려고 서브트리 전체를 따로 그린 뒤 잘라 온다 | 사각형 · 둥근 사각형 · 타원이면 `masksToBounds`로 대체. 배경색만 있는 레이어를 마스크로 쓰지 않는다 |
| 둥근 모서리 | 정보가 부족하면 뷰 전체를 따로 그린 뒤 모서리 안쪽만 복사한다 | `CAShapeLayer` 마스크 대신 `cornerRadius` + `cornerCurve = .continuous`(iOS 13+) |
| visual effect (블러 · vibrancy) | 아래에 있는 걸 복사해 와야 효과를 줄 수 있다 | 피할 수 없다. 내비게이션 바 · 탭 바도 쓴다. 개수만 줄인다 |

```swift
view.layer.shadowColor = UIColor.black.cgColor
view.layer.shadowOpacity = 0.5
view.layer.shadowPath = UIBezierPath(roundedRect: view.layer.bounds,
                                     cornerRadius: view.layer.cornerRadius).cgPath
```

`masksToBounds`도 **자식 레이어가 있으면** 올바르게 잘라내려고 오프스크린이 생긴다. 자식이 경계 밖으로 나갈 일이 없으면 끄는 게 가장 좋다. Tech Talk 데모는 이런 수정 몇 줄로 셀 하나의 오프스크린을 36개에서 0개로 줄였다.

### `cornerRadius`만으로 충분한 경우

`cornerRadius`는 기본적으로 배경색과 테두리에만 적용되고, `contents` 이미지에는 적용되지 않는다. `masksToBounds`를 켜야 내용이 둥근 모서리에 맞춰 잘린다.

| 상황 | 고치는 법 |
|---|---|
| 이미지 · 라벨이 안쪽 여백 안에만 있다 | 셀은 `cornerRadius`만 주고 `masksToBounds`를 끈다. 배경색이 둥글게 그려지니 겉보기는 같다 |
| 이미지가 카드 위쪽을 꽉 채워 모서리에 닿는다 | 셀이 아니라 **이미지 뷰만** 자른다. 일부 모서리만 둥글게 하려면 `maskedCorners`를 쓴다 |

자르는 범위를 자식이 많은 셀 전체에서 이미지 뷰 하나로 좁히는 게 핵심이다.

## 3. 둥근 모서리 + 그림자: 두 겹으로 나눈다

그림자는 레이어 경계 밖에 그려지는데, `masksToBounds = true`는 경계 밖을 전부 잘라낸다. 그래서 그림자도 같이 잘려 안 보인다. 한 레이어에서 둘 다 할 수 없다.

```
cardView (바깥)         그림자만, 자르지 않음, shadowPath 지정
 └ containerView (안쪽)  둥근 모서리, 필요할 때만 자르기
    └ 이미지 뷰, 라벨
```

```swift
// 바깥: 그림자 담당
cardView.layer.shadowColor = UIColor.black.cgColor
cardView.layer.shadowOpacity = 0.15
cardView.layer.shadowRadius = 8
cardView.layer.shadowOffset = CGSize(width: 0, height: 4)

// 안쪽: 모양 담당
containerView.backgroundColor = .systemBackground
containerView.layer.cornerRadius = 12
containerView.layer.cornerCurve = .continuous   // iOS 13+

override func layoutSubviews() {
    super.layoutSubviews()
    cardView.layer.shadowPath = UIBezierPath(roundedRect: cardView.bounds,
                                             cornerRadius: 12).cgPath
}
```

바깥 뷰는 배경색이 없어서, `shadowPath`가 없으면 그림자가 안쪽 내용과 자식 레이어를 따라 계산된다. 2번의 그림자 오프스크린이 그대로 생기므로 여기서는 `shadowPath`가 특히 중요하다.

### 실무에서

- 그림자 + 둥근 이미지가 들어간 카드형 셀 목록이 스크롤할 때만 끊기고, Time Profiler에서 메인 스레드는 한가하다 → render hitch를 의심한다
- 흔한 원인: `shadowPath` 없는 그림자, 둥근 모서리를 위한 `CAShapeLayer` 마스크, 습관적으로 켠 `clipsToBounds`
- "그림자를 넣었는데 안 보인다" → 같은 뷰에 `clipsToBounds = true`가 있는지 본다. `clipsToBounds`는 `layer.masksToBounds`와 같은 값이다
- `shadowPath`는 `bounds` 기준 경로라 크기가 바뀌면 다시 만들어야 한다. 셀처럼 크기가 레이아웃 뒤에 정해지면 `layoutSubviews`에서 갱신한다
- Swift 5 모드와 6 모드 차이는 없다. 레이어 속성 설정이라 언어 모드와 관계없다

## 4. 확인 도구

```
Instruments: Animation Hitches 템플릿 (Instruments 12+)
 → Hitches 트랙에서 hitch type이 GPU 쪽인지 확인
 → Renders / GPU 트랙 선택 → 렌더 횟수 열에서 오프스크린 수 확인
      ↓ 어느 레이어인지는 여기서 안 보임
Xcode View Debugger
 → Editor > Show Layers (Xcode 11.2+): 레이어 인스펙터에 오프스크린 수와 원인 플래그
 → Show Optimization Opportunities (Xcode 12+, 기본 켜짐): 보라색 런타임 이슈로 수정 방법 제안
 → File > Export View Hierarchy: 상태를 파일로 저장해 동료와 공유
```

실무에서는 View Debugger만으로 충분한 경우가 많다. 일시 정지하고 보라색 아이콘이 붙은 레이어만 따라가면 된다. 메뉴 이름과 위치가 Xcode 26.4에서도 같은지는 확인 필요.

## 핵심 정리

1. 오프스크린 패스는 GPU가 정보가 부족해 다른 텍스처에 먼저 그린 뒤 복사해 오는 것이다. 쌓이면 render hitch가 된다.
2. 원인은 그림자 · 마스크 · 둥근 모서리 · visual effect 넷이다. `shadowPath`, `cornerRadius` + `cornerCurve`, 필요 없는 `masksToBounds` 끄기로 대부분 없앤다.
3. `masksToBounds`는 그림자까지 자른다. 둥근 모서리와 그림자가 둘 다 필요하면 그림자 뷰와 콘텐츠 뷰 두 겹으로 나눈다.
4. Animation Hitches로 render hitch인지 보고, View Debugger의 Show Layers와 Optimization Opportunities로 어느 레이어인지 찾는다.

## 셀프 체크

**Q1. 셀에 `cornerRadius = 12`, `masksToBounds = true`를 주고 안에 이미지 뷰와 라벨을 넣었다. 오프스크린이 생기나?**

- 생긴다. 자식 레이어가 있는 상태에서 자르기 때문이다. 자식이 여백 안에만 있으면 `masksToBounds`를 끄고, 이미지가 모서리에 닿으면 이미지 뷰만 자른다

**Q2. `masksToBounds = true`인 레이어에 그림자를 주면?**

- 그림자는 경계 밖에 그려지므로 같이 잘려 안 보인다. 그림자 뷰(바깥)와 콘텐츠 뷰(안쪽) 두 겹으로 나눈다

**Q3. 두 겹으로 나눴는데 바깥 그림자 뷰에 `shadowPath`가 없으면?**

- 바깥 뷰에 배경색이 없어 그림자 모양을 안쪽 내용과 자식들로 계산해야 한다. 그림자 오프스크린이 생긴다

**Q4. 스크롤이 끊기는데 Time Profiler에서 메인 스레드는 한가하다. 무엇을 의심하나?**

- render hitch. 일은 Render Server와 GPU에서 일어나므로 앱 메인 스레드에는 안 보인다. Animation Hitches의 Renders / GPU 트랙과 View Debugger로 오프스크린을 찾는다

## 참고 자료

**공식**

- [Demystify and eliminate hitches in the render phase (Tech Talk 10857)](https://developer.apple.com/videos/play/tech-talks/10857/) — 오프스크린 정의, 4종, `shadowPath` 코드, `cornerCurve`(iOS 13), Show Layers(Xcode 11.2), Optimization Opportunities(Xcode 12), 36 → 0 데모
- [Explore UI animation hitches and the render loop (Tech Talk 10855)](https://developer.apple.com/videos/play/tech-talks/10855/) — render prepare · execute의 위치
- [cornerRadius (CALayer)](https://developer.apple.com/documentation/quartzcore/calayer/cornerradius) — 기본은 배경색 · 테두리에만 적용, `masksToBounds`를 켜야 내용이 잘림
- [Core Animation Programming Guide: Layer Style Property Animations (2015)](https://developer.apple.com/library/ios/documentation/cocoa/conceptual/coreanimation_guide/LayerStyleProperties/LayerStyleProperties.html) — 배경색이 없으면 그림자가 내용 · 자식 레이어를 따라 적용

**외부**

- [Why masksToBounds YES prevents CALayer shadow (Codemia)](https://codemia.io/knowledge-hub/path/why_maskstobounds_yes_prevents_calayer_shadow) — 그림자가 경계 밖이라 잘림
- [UIView with cornerRadius and Shadow (GitHub Gist, 2017)](https://gist.github.com/cwalo/076b30a3848118f042fcb40cd9787082) — 컨테이너 뷰로 두 겹 분리
- [High performance shadows for UIView (Donny Wals, 2015)](https://donnywals.com/high-performance-shadows-for-uiview) — `shadowPath`로 스크롤 끊김 해결 사례
