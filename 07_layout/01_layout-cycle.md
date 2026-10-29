# 레이아웃 사이클 큰 그림

> 작성일: 2026-10-29

## 큰 그림

[03_event-handling](../03_event-handling/05_target-action.md)은 "터치 → 내 action 메서드"에서 끝났다. 이 폴더는 그 메서드 안에서 바꾼 것(텍스트, 제약)이 화면에 반영되기까지를 본다.

[렌더 루프와 첫 프레임](../02_app-lifecycle/06_render-loop-first-frame.md) 2번 commit의 **Layout · Display** 단계를 확대한 것이다.

```
action 메서드에서 변경 (text, constraint.constant …)
 → "다시 해 줘" 표시만 붙음
 → commit 때 한꺼번에:
    ① 제약 업데이트   제약을 최신 상태로
    ② 레이아웃       제약대로 frame 계산·배치
    ③ 디스플레이     필요한 뷰만 다시 그리기
 → Render Server → 화면
```

## 1. "Render Loop"라는 이름이 두 범위로 쓰인다

| | Tech Talk 10855/10856 (02/06에서 본 것) | WWDC18 220 High Performance Auto Layout |
|---|---|---|
| 범위 | 이벤트 → commit → Render Server → 화면 | 앱 안에서 뷰가 준비되는 과정 |
| 단계 | Event → Commit(Layout · Display · Prepare · Commit) → Render Prepare → Render Execute → Display | Update Constraints → Layout → Display |
| 관점 | 프레임 파이프라인 전체 | 뷰 API 3세트 |

이 폴더의 "레이아웃 사이클"은 WWDC18 쪽이다. 02/06 commit의 Layout이 ①②, Display가 ③에 해당한다.

## 2. 세 단계

뷰를 바꾸면 바로 반영되지 않고 **표시만** 붙는다. 시스템은 프레임을 즉시 고치지 않고 가까운 미래에 deferred layout pass를 예약한다.

| 단계 | 하는 일 | 순회 방향 |
|---|---|---|
| ① 제약 업데이트 | VC `updateViewConstraints`, 뷰 `updateConstraints` | leaf → window (아래에서 위로) |
| ② 레이아웃 | VC `viewWillLayoutSubviews`, 뷰 `layoutSubviews` → 엔진이 계산한 값으로 frame 설정 | window → leaf (위에서 아래로) |
| ③ 디스플레이 | `draw(_:)`를 override한 뷰만 다시 그림 | window → leaf |

제약을 바꾸는 행동: 제약 활성화·비활성화, `constant` · `priority` 변경, 뷰 계층에서 뷰 제거 등.

## 3. 세 단계는 같은 모양의 API

| 단계 | 예약 | 지금 당장 | 실제 작업 |
|---|---|---|---|
| ① 제약 업데이트 | `setNeedsUpdateConstraints()` | `updateConstraintsIfNeeded()` | `updateConstraints()` |
| ② 레이아웃 | `setNeedsLayout()` | `layoutIfNeeded()` | `layoutSubviews()` |
| ③ 디스플레이 | `setNeedsDisplay()` | — | `draw(_:)` |

"예약 → 모아서 한 번에" 하는 이유는 낭비를 줄이기 위해서다. 텍스트를 다섯 번 바꿔도 크기 계산은 마지막에 한 번만 한다. 02/06의 "예약은 여러 번 불러도 한 번으로 합쳐진다"와 같은 원리다.

### 실무에서

- **제약을 바꾼 직후 frame은 옛날 값이다.** 아직 ②가 안 돌았기 때문이다. 바로 필요하면 `layoutIfNeeded()`, 아니면 `viewDidLayoutSubviews`에서 읽는다
- **버튼 탭에 반응한 제약 변경은 action 메서드에서 바로 하면 된다.** `updateConstraints` override는 성능 문제가 있을 때만 쓰라는 게 Apple 권장이다
- **`updateConstraints`나 `layoutSubviews` 안에서 다시 "해 줘"를 걸면 무한 루프가 생길 수 있다.** 화면이 멈추면 이걸 의심한다 (→ [05](05_layout-performance-debugging.md))

### 확인 필요

02/06의 "런치 첫 화면 레이아웃 경로"와 관련해, 외부 크래시 스택(iOS 14.4.2)에 `-[UIApplication _firstCommitBlock]_block_invoke` → `CA::Transaction::commit` 경로가 보인다. 첫 commit이 observer가 아니라 블록으로 실행된다는 단서다. 런치 때 `layoutSubviews`에 브레이크포인트를 걸고 `bt`로 현재 버전 스택을 직접 확인한다.

## 핵심 정리

1. 뷰를 바꾸면 표시만 붙고, 실제 처리는 다음 commit 때 한꺼번에 한다.
2. 레이아웃 사이클은 제약 업데이트(아래 → 위) → 레이아웃(위 → 아래) → 디스플레이 순이다. 02/06 commit의 Layout · Display 단계에 해당한다.
3. 세 단계는 "예약 / 지금 당장 / 실제 작업"의 평행한 API를 갖는다. 목적은 중간 작업을 버리고 한 번만 계산하는 것이다.

## 셀프 체크

**Q1. WWDC18의 Render Loop와 Tech Talk 10855의 render loop는 같은 것인가?**

- 범위가 다르다. WWDC18은 앱 안의 Update Constraints → Layout → Display이고, 10855는 이벤트부터 화면 표시까지 전체다. WWDC18의 세 단계는 10855 commit 단계 안의 Layout · Display에 들어간다

**Q2. 제약 업데이트와 레이아웃은 왜 순회 방향이 반대인가?**

- 제약은 자식 크기(intrinsic size 등)가 정해져야 부모가 정해지므로 아래 → 위, 레이아웃은 부모 bounds가 정해져야 자식 frame을 놓을 수 있으므로 위 → 아래다

**Q3. 제약을 바꾼 직후 frame을 읽으면?**

- 옛날 값이다. 표시만 붙었고 레이아웃 단계가 아직 안 돌았다

## 참고 자료

**공식**

- [High Performance Auto Layout (WWDC18 220)](https://developer.apple.com/videos/play/wwdc2018/220/) — Render Loop 3단계, 평행 API
- [Mysteries of Auto Layout, Part 2 (WWDC15 219)](https://developer.apple.com/videos/play/wwdc2015/219/) — layout cycle, 2-pass
- [Auto Layout Guide: Changing Constraints](https://developer.apple.com/library/archive/documentation/UserExperience/Conceptual/AutolayoutPG/ModifyingConstraints.html) — deferred layout pass, update/layout pass, 피드백 루프 주의
- [updateConstraints()](https://developer.apple.com/documentation/uikit/uiview/updateconstraints()) — action 메서드에서 바로 바꾸라는 권장
- [Find and fix hitches in the commit phase (Tech Talk 10856)](https://developer.apple.com/videos/play/tech-talks/10856/) — commit 4단계

**외부**

- [WWDC Notes: WWDC18 220](https://wwdcnotes.com/documentation/wwdc18-220-high-performance-auto-layout/) — 단계별 순회 방향
- [Tencent/wcdb #1027 (iOS 14.4.2)](https://github.com/Tencent/wcdb/issues/1027) — `_firstCommitBlock` 경로 크래시 스택
