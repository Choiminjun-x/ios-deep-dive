# 레이아웃 성능 · 디버깅

> 작성일: 2026-10-29

## 큰 그림

레이아웃이 잘못될 때 어떤 증상이고, 무엇으로 보나. 문제 유형 넷만 기억한다.

| 유형 | 증상 | 콘솔 로그 | 도구 |
|---|---|---|---|
| ① 느림 (commit hitch) | 스크롤·애니메이션이 끊김 | 없음 | Instruments Animation Hitches |
| ② 충돌 (unsatisfiable) | 뷰 크기·위치가 이상함 | `Unable to simultaneously satisfy constraints` | 심볼릭 브레이크포인트, identifier |
| ③ 모호함 (ambiguous) | 실행할 때마다 배치가 다르거나 엉뚱함 | **없음** | View Debugger, `hasAmbiguousLayout` |
| ④ 무한 루프 (feedback loop) | 화면 멈춤, CPU 100%, 메모리 증가 | 없음 | `-UIViewLayoutFeedbackLoopDebuggingThreshold` |

## 1. 느림: commit hitch

[01](01_layout-cycle.md)의 commit 안에서 ①②③(제약 → 레이아웃 → 디스플레이)이 너무 오래 걸려 VSync 마감을 놓친 것이다.

```
Instruments → Animation Hitches
 → Commits 트랙에서 긴 구간 선택
 → 같이 들어 있는 Time Profiler로 그 구간에 돈 코드 확인
```

자주 나오는 원인: `layoutIfNeeded` 남발([02](02_set-needs-layout-layout-if-needed.md)), 매번 제약 전부 갈아끼우기([03](03_auto-layout-engine.md)), `viewDidLayoutSubviews`에 무거운 일([04](04_vc-layout-hooks.md)).

## 2. 충돌: 로그가 나오는 것

제약끼리 동시에 만족할 수 없으면 엔진이 하나를 깨고 진행한다. 로그에 "어떤 제약을 깨서 복구하겠다"가 나오고, `UIViewAlertForUnsatisfiableConstraints`에 심볼릭 브레이크포인트를 걸라는 안내가 붙는다.

- **`identifier`를 붙인다.** 붙여 두면 로그에서 내 제약을 바로 알아볼 수 있다. 안 붙이면 `0x7b56d020` 같은 주소만 보인다
- **`h=` / `v=`가 보이면 autoresizing mask에서 온 제약이다.** `-`는 고정, `&`는 유연이다. 코드로 만든 뷰에 `translatesAutoresizingMaskIntoConstraints = false`를 빠뜨린 게 가장 흔한 원인이다
- **고치는 법은 둘**: 필요 없는 제약을 지우거나, 하나를 optional(priority < 1000)로 바꾼다

## 3. 모호함: 로그가 안 나오는 것

해가 둘 이상인 경우다. 원인은 제약이 부족하거나, 같은 우선순위의 optional 제약끼리 부딪혀 시스템이 뭘 깰지 모르는 경우다. 03의 "Hugging / Compression Resistance가 같아 아무거나 고른 것"이 두 번째 경우다.

런타임에 Auto Layout이 해 하나를 골라 쓰고, 콘솔 경고도 없고 브레이크포인트를 걸 방법도 없다.

```
Debug View Hierarchy (Xcode 상단 버튼)
 → 보라색 느낌표 경고 = 모호한 뷰
 → 또는 lldb: po view.hasAmbiguousLayout
```

## 4. 무한 루프

레이아웃 도중 무언가가 다시 레이아웃 패스를 시작시키는 경우다. CPU가 꽉 차고 RAM이 계속 오르는데, 디버거로 보면 레이아웃 코드만 잔뜩 보여서 어디가 루프인지 알기 어렵다.

```
Scheme → Run → Arguments Passed On Launch
 -UIViewLayoutFeedbackLoopDebuggingThreshold 100
```

숫자는 50~1000 사이로, 한 런루프 안에서 뷰가 서브뷰 레이아웃을 몇 번 하면 루프로 볼지다. WWDC16에서 소개됐고 iOS · tvOS용이다.

원인은 01~04에서 "하지 말 것"으로 나온 것들이다: `updateConstraints` 안의 `setNeedsUpdateConstraints`, `layoutSubviews`에서 부모·형제 무효화, `viewDidLayoutSubviews`에서 제약 추가.

### 실무에서

- 심볼릭 브레이크포인트 `UIViewAlertForUnsatisfiableConstraints`를 User Breakpoint로 만들어 두면 모든 프로젝트에 적용된다
- 코드로 만든 제약에는 `identifier`를 붙인다
- 피드백 루프 launch argument는 평소엔 아무 일도 안 하니 디버그 scheme에 켜 두어도 된다

## 핵심 정리

1. 레이아웃 문제는 느림 · 충돌 · 모호함 · 무한 루프 넷으로 나뉜다.
2. 충돌만 콘솔 로그가 나온다. 모호함과 무한 루프는 로그 없이 증상으로 찾아야 한다.
3. 느림은 Animation Hitches, 충돌은 심볼릭 브레이크포인트 + identifier, 모호함은 View Debugger, 무한 루프는 launch argument로 본다.

## 셀프 체크

**Q1. 콘솔에 아무 경고도 없는데 뷰 배치가 엉뚱하다. 무엇을 의심하나?**

- 모호한 레이아웃. Debug View Hierarchy나 `hasAmbiguousLayout`으로 확인한다

**Q2. 충돌 로그에 `h=--&` 같은 표기가 보이면?**

- autoresizing mask에서 온 제약이다. `translatesAutoresizingMaskIntoConstraints = false` 누락을 확인한다

**Q3. 화면이 멈추고 메모리가 계속 오른다. 레이아웃 쪽이라면?**

- 피드백 루프. `-UIViewLayoutFeedbackLoopDebuggingThreshold`를 켜고 재현한다

## 참고 자료

**공식**

- [Auto Layout Guide: Debugging Tricks and Tips](https://developer.apple.com/library/archive/documentation/UserExperience/Conceptual/AutolayoutPG/DebuggingTricksandTips.html) — 충돌 로그, `h=`/`v=`, identifier
- [Auto Layout Guide: Ambiguous Layouts](https://developer.apple.com/library/archive/documentation/UserExperience/Conceptual/AutolayoutPG/AmbiguousLayouts.html) — 경고·브레이크포인트 없음, `hasAmbiguousLayout`
- [Find and fix hitches in the commit phase (Tech Talk 10856)](https://developer.apple.com/videos/play/tech-talks/10856/) — Animation Hitches + Time Profiler
- [Understanding hitches in your app](https://developer.apple.com/documentation/xcode/understanding-hitches-in-your-app)

**외부**

- [How to use UIViewLayoutFeedbackLoopDebuggingThreshold today (Hacking with Swift)](https://www.hackingwithswift.com/articles/59/debugging-auto-layout-feedback-loops) — WWDC16 소개, 50~1000
- [Debugging Out of Memory Issues: Layout Feedback Loop (AppCoda)](https://appcoda.com/layout-feedback-loop/) — 피드백 루프와 OOM
