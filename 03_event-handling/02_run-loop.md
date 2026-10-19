# 런루프 (Run Loop)

> 작성일: 2026-10-19

## 큰 그림

```
메인 스레드
 → UIApplicationMain → CFRunLoopRunSpecific   ← 런루프 진입. 이 함수가 안 끝남
 → 한 바퀴: 타이머 → Source0 → (할 일 없음) 잠듦 → 깸 → 처리 → 다시 …   (1·2번)
 → 잠든 동안: 현재 모드의 포트 묶음 하나를 붙잡고 대기                    (3번)
 → 어떤 목록을 볼지: 모드 (default / tracking / common)                  (4번)
 → 탭 한 번: 터치(Source0) → commit(observer) → Render Server → VSync    (5번)
```

런루프는 스레드가 들어가서 도는 순서표다. 할 일이 있으면 스레드를 바쁘게 돌리고, 없으면 재운다. 메인 런루프는 `UIApplicationMain`이 시작하고, 터치 · 타이머 · `DispatchQueue.main` · Core Animation commit이 모두 이 순서표 위에서 실행된다.

## 1. 런루프와 스레드

RunLoop

- 스레드가 들어가서 이벤트 핸들러를 실행하는 루프
- 런루프가 별도 스레드를 띄워서 도는 게 아님, 별도 실행 주체 X
- 스레드가 따라 도는 순서표

```
스레드
 → 런루프 진입
 → 처리할 일(타이머·소스) 처리
 → 할 일 없음 → 잠듦 (CPU 0%)
 → 이벤트 도착 → 커널이 깨움
 → 처리 → 다시 잠듦 …
```

스레드 - 런루프를 실제로 도는 주체

### 소유와 실행은 따로 본다

```
① 소유 (데이터)   스레드 ─1:1─ 런루프 객체 (모드·소스·타이머·observer 목록)
② 실행 (코드)     스레드가 run 함수를 호출 → 그 스레드의 스택 위에서 루프가 돈다
```

- 스레드당 런루프 객체는 정확히 하나다. 직접 만들거나 없애지 않는다
- 객체는 처음 `RunLoop.current` / `CFRunLoopGetCurrent()`로 접근할 때 생기고, 스레드를 key로 전역 딕셔너리에 저장된다 (오픈소스 CF 기준)
- **"객체가 있다" ≠ "돌고 있다"**. 누군가 run을 호출해야 돈다

| | 메인 스레드 | 내가 만든 스레드 |
|---|---|---|
| 런루프 객체 | 있음 | 있음 |
| 누가 돌리나 | 앱 프레임워크가 시작 과정에서 자동으로 (`UIApplicationMain`) | 직접 돌려야 한다 |
| 소스 없이 돌리면 | — | 감시할 소스가 없으면 바로 빠져나온다 |

### 두 층으로 나누기

```
[실행 주체]  스레드          → 메인 스레드, 백그라운드 스레드들 … (일하는 사람)
[실행될 일]  런루프에 등록된 객체 → Source0, Source1, 타이머, observer (할 일 항목)
```

Source0 같은 소스는 스레드가 아니라 런루프 목록에 꽂아 두는 객체다. 실행하는 건 항상 그 런루프를 돌고 있는 스레드다.

### 실무에서

- 백그라운드에서 `Timer.scheduledTimer`가 안 불림 → GCD 큐의 스레드는 런루프를 돌리지 않기 때문이다. `perform(_:with:afterDelay:)`도 같은 이유로 무시된다 → 메인에서 걸거나 `DispatchSourceTimer`를 쓴다
- 메인 스레드 hang → 메인에서 무거운 동기 작업을 하면 런루프가 한 바퀴를 못 끝내고 잠들지도 못한다. 터치도 commit도 그 뒤로 밀린다
- 일시정지했을 때 메인 스레드 스택 맨 위가 `mach_msg2_trap` 근처면 잠들어서 이벤트를 기다리는 중(정상 idle)이다. 심볼 이름은 OS 버전마다 조금 다르다
- `RunLoop`(`NSRunLoop`)은 그 런루프를 가진 스레드에서만 수정한다. CF 함수는 대체로 thread-safe다

## 2. 한 바퀴 실제 순서

```
1  [Entry]          런루프 진입 알림
2  [BeforeTimers]   "타이머 처리할게" 알림
3  [BeforeSources]  "Source0 처리할게" 알림
4                    준비된 Source0 실행
5                    포트 기반 소스가 이미 와 있으면 → 바로 9로 (잠들지 않음)
6  [BeforeWaiting]  "잠들게" 알림            ← 06 실험의 observer
7                    잠듦 (포트 메시지·타이머·타임아웃·WakeUp까지)
8  [AfterWaiting]   "깼어" 알림
9                    깨운 원인 처리 (타이머 / Source1 / 명시적 WakeUp) → 2로
10 [Exit]           런루프 종료 알림
```

[ ] 칸이 observer가 끼어들 수 있는 자리

진입, 타이머 직전, 입력 소스 직전, 잠들기 직전, 깨어난 직후, 종료 (`CFRunLoopActivity`의 `.entry`, `.beforeTimers`, `.beforeSources`, `.beforeWaiting`, `.afterWaiting`, `.exit`)

- 메인 런루프는 2 → 9 → 2로 계속 돌아서 Entry/Exit은 거의 안 찍힌다. 메인에서 Exit이 보이면 누군가 런루프를 중첩해서 돌렸다 빠져나왔다는 신호다
- 타이머·소스 알림은 실제 처리보다 먼저 온다. 시점이 중요하면 잠들기/깨어남 알림으로 맞춘다

### 지름길과 poll

"바쁘다" -> 매번 우편함에 무언가 있다

```
평소:   … → 5 우편함 비었음 → 6 BeforeWaiting → 7 잠듦 → 8 AfterWaiting → 9 처리
지름길: … → 5 우편함에 이미 있음 ─────────────────────────────→ 9 처리
```

공식 가이드는 5번을 "포트 기반 소스"로 설명하지만, 오픈소스 CF 구현은 조금 다르다.

| 상황 | 잠드나 | BeforeWaiting/AfterWaiting 알림 |
|---|---|---|
| 할 일 없음 | 잠듦 | 둘 다 찍힘 |
| 이번 바퀴에 Source0 처리함 (`poll`) | 안 잠들고 확인만 | 둘 다 안 찍힘 |
| 메인 큐 블록이 이미 대기 (지름길) | 안 잠듦 | 둘 다 안 찍힘. 단 연속 2번 불가 |

- 지름길은 모든 Source1이 아니라 메인 큐(GCD) 포트만 미리 확인한다 (`didDispatchPortLastTime`)
- BeforeWaiting이 빠지는 더 흔한 경우는 Source0을 처리한 바퀴다
- iOS에 탑재된 CF가 이 오픈소스와 같은지는 확인 필요

### 실무에서

- hang 감지: AfterWaiting(깸) → BeforeWaiting(다시 잠들기) 사이가 "한 번 일한 시간"이다. 서드파티 hang 감지 라이브러리가 이 두 칸에 observer를 거는 방식을 많이 쓴다. 다만 Source0을 처리한 바퀴는 두 알림을 건너뛰므로 간격이 실제 일한 시간과 어긋날 수 있다. 공식 도구는 Instruments Hangs, MetricKit `MXHangDiagnostic`
- autorelease pool이 Entry / BeforeWaiting / Exit에서 비워진다는 분석이 있다 (ibireme, 2015, 현재 구현 확인 필요). 루프 안에서 임시 객체를 대량으로 만들면 한 바퀴가 끝날 때까지 메모리가 쌓이는 이유다

## 3. 무엇이 런루프를 깨우나

잠든 스레드 - Mach 포트 묶음(port set) 하나를 붙잡고 기다린다. 묶음은 현재 모드의 것이다.

```
잠든 메인 스레드: mach_msg로 현재 모드의 포트 묶음 대기
 ├ Source1 포트들     ← 다른 프로세스·커널이 메시지를 보냄
 ├ 타이머 포트        ← 정해진 시각에 커널이 신호
 ├ 메인 큐 포트       ← DispatchQueue.main.async 등
 └ wakeUp 포트        ← CFRunLoopWakeUp() 호출
         (Source0은 이 묶음에 없음!)
```

### Source0 / Source1

공식 용어가 아니라 API의 `version` 번호에서 나온 별칭이다. CF 내부 콜아웃 함수 이름도 이렇게 지어져 있어서 콜스택에 그대로 보인다.

| 부르는 이름 | 공식 문서 용어 | API (CF 헤더) |
|---|---|---|
| Source0 | 커스텀 입력 소스 (custom input source) | `CFRunLoopSourceContext`, `version = 0` |
| Source1 | 포트 기반 입력 소스 (port-based input source) | `CFRunLoopSourceContext1`, `version = 1` |

| | Source0 | Source1 | 타이머 |
|---|---|---|---|
| 신호를 주는 쪽 | 다른 스레드가 직접 (`CFRunLoopSourceSignal`) | 커널이 자동 (포트에 메시지 도착) | 커널 (예약 시각) |
| 스스로 깨우나 | 못 깨움 → `CFRunLoopWakeUp` 필요 | 깨움 | 깨움 |
| 처리 위치 | 4번 | 9번 (또는 5번 지름길) | 9번 → 처리 후 2번으로 |

Source0 객체 생김새

```
Source0 = { 콜백 함수(할 일), 깃발(지금 처리할까?) }
```

### 잠든 스레드를 깨우는 건 그때 깨어 있는 다른 누군가

```
[자는 쪽]  메인 스레드 ─ 포트 묶음 붙잡고 대기

[깨우는 쪽]
 Source1  ← 앱 밖 프로세스·커널이 포트에 메시지를 보냄 → 그 자체로 깸
 타이머    ← 커널이 시각 되면 타이머 포트에 신호        → 그 자체로 깸
 Source0  ← 앱 안의 다른 스레드가
              ① 깃발 세움 (CFRunLoopSourceSignal)
              ② wakeUp 포트 두드림 (CFRunLoopWakeUp)    → 이걸로 깸
```

①은 "무엇을", ②는 "지금"이다. ②는 어떤 Source0인지 말해 주지 않는다. 깨어난 스레드가 4번 칸에서 깃발이 선 Source0을 전부 찾아 실행한다. ①만 하고 ②를 빼면 다른 이유로 깰 때까지 처리가 늦어진다.

메인 스레드가 깨어 있는 동안 스스로 깃발을 세우는 경우(UIKit이 이벤트 처리 중 다음 처리를 예약 등)는 깨울 필요가 없다. 다음 바퀴 4번에서 처리된다.

### wakeUp 포트

- 런루프 만들 때 하나 생김
- 코드 주석에 `CFRunLoopWakeUp` 명시
- "깨워서 목록을 다시 보게 하는" 용도

### 타이머 포트

- 모드당 커널 타이머 포트 하나를 두고, 등록된 타이머 중 가장 빠른 시각 하나에만 알람을 맞춘다
- 타이머 시각은 등록 시점 기준의 절대 시각, 누적되지 않는다. 같은 기준점에서 잰 시각

```
타이머 목록 (시각순 정렬): 0.1초 뒤, 0.5초 뒤, 2초 뒤
 → 타이머 포트 알람: 0.1초 뒤로 맞춤
 → 0.1초 → 커널이 포트에 메시지 → 깸
 → 시각 지난 타이머들 실행 → 다음으로 빠른 0.5초에 알람 다시 맞춤
```

- 타이머가 늦어지는 건 앞 핸들러가 오래 걸려 메인이 바쁠 때다. 핸들러 실행 중에 시각이 되면 다음 바퀴까지 기다린다
- 반복 타이머의 다음 발동은 실제 발동 시각이 아니라 예정 시각 기준이다. 여러 번 놓치면 한 번만 발동하고 다음 예정 시각으로 맞춘다
- `tolerance`가 있으면 커널 타이머 대신 dispatch 타이머(모드 전용 큐 포트)로 깨운다. 원리는 같고 통로만 다르다

### 메인 큐 포트

- `DispatchQueue.main.async { … }`가 메인 스레드에서 실행되는 통로
- Source0도 Source1도 아닌 별도 통로다

```
아무 스레드: DispatchQueue.main.async { 블록 }
 → libdispatch가 메인 큐에 블록 넣고, 메인 큐 포트에 메시지
 → 자던 메인 스레드 깸
 → __CFRUNLOOP_IS_SERVICING_THE_MAIN_DISPATCH_QUEUE__
 → 쌓인 메인 큐 블록 실행
```

듣는 건 메인 런루프뿐, 보내는 건 누구나

```
보내는 쪽 (누구나)                         받는 쪽 (메인만)
백그라운드 스레드 ─ DispatchQueue.main.async ─┐
메인 스레드 자신 ─ DispatchQueue.main.async ─┼→ libdispatch → 메인 큐 포트 → 메인 런루프가 깸
다른 GCD 작업      ─ …                       ─┘
```

- 받는 쪽: 메인 런루프의 묶음에만 들어간다. "지금 런루프가 메인 런루프이고, 현재 모드가 common 집합에 속할 때만"이다. 다른 스레드는 이 포트를 듣지 않는다
- 보내는 쪽: 메인 큐에 일을 넣는 쪽은 어느 스레드든 가능하다. 다만 그 스레드가 포트를 직접 만지진 않고, `DispatchQueue.main.async`를 부르면 libdispatch가 대신 메시지를 넣는다
- 포트 주인은 libdispatch의 메인 큐이고, 메인 런루프는 그 포트를 빌려서 듣는 쪽이다

| 포트 | 개수 | 누가 메시지를 보내나 | 깨면 하는 일 |
|---|---|---|---|
| wakeUp | 런루프당 1 | `CFRunLoopWakeUp` 호출한 쪽 | 루프 다시 돌기 |
| 타이머 | 모드당 1 (+ tolerance용 큐 포트) | 커널 (가장 빠른 타이머 시각) | 시각 지난 타이머 실행, 다음 알람 설정 |
| 메인 큐 | 메인 런루프에만 | libdispatch | 메인 큐 블록 실행 |
| Source1 | 소스마다 1 | 다른 프로세스·커널 | 해당 Source1 콜백 |

### 실무에서

콜스택 아래쪽 CF 함수 이름이 곧 "누가 나를 불렀나"다.

| 스택 아래쪽 | 경로 |
|---|---|
| `…SOURCE0_PERFORM_FUNCTION__` | Source0 (UIKit 이벤트 처리 등) |
| `…SOURCE1_PERFORM_FUNCTION__` | Source1 (포트 메시지) |
| `…TIMER_CALLBACK_FUNCTION__` | `Timer` / `perform(afterDelay:)` |
| `…SERVICING_THE_MAIN_DISPATCH_QUEUE__` | `DispatchQueue.main.async`, 메인 큐로 온 작업 |
| `…OBSERVER_CALLBACK_FUNCTION__` | observer (Core Animation commit 등) |

## 4. Mode

포트 묶음 한 세트의 이름이다. 런루프는 한 번 돌 때 모드 하나를 골라서, 해당 모드에 등록된 것만 본다.

```
메인 런루프 객체
 ├ default 모드   { Source0들, Source1들, 타이머들, observer들, 포트 묶음 }
 ├ tracking 모드  { Source0들, Source1들, 타이머들, observer들, 포트 묶음 }
 └ (기타 시스템 모드들)

지금 돌고 있는 모드 = 하나뿐 → 그 모드의 묶음만 보고, 그 묶음 포트로만 깸
```

다른 모드의 소스는 사라지는 게 아니라 이벤트를 쥐고 있다가 해당 모드로 돌 때 전달한다. 모드는 run 할 때 고르는 것이라, 돌던 중에 모드만 바꿀 수는 없다. 지금 run을 빠져나오거나(Exit) 새 모드로 중첩 run을 해야 한다. 스크롤 때 UIKit이 어느 방식인지는 확인 필요.

실제로 만나는 모드

| 모드 | Swift | 언제 |
|---|---|---|
| default | `.default` | 평소 대부분 |
| tracking | `.tracking` (= `UITrackingRunLoopMode`) | 스크롤, 컨트롤 추적 중 |
| common | `.common` | 진짜 모드가 아닌 묶음. 메인 런루프에서는 default + tracking |

`eventTracking`, `modalPanel`은 macOS 전용이다. 메인 런루프 common 집합이 default + tracking이라는 건 공식 문서에 없고 외부 분석 기준이다. `print(RunLoop.main)`의 `common modes`로 확인할 수 있다.

### 스크롤하면 타이머가 멈추는 이유

"메인 런루프가 tracking 모드로 돈다"는 스크롤하는 동안 메인 스레드가 tracking 모드의 목록만 보고 돈다는 뜻이다. 목록을 바꾸는 건 UIKit(스크롤 뷰)이다.

```
① Timer.scheduledTimer(…)          → 현재 런루프의 default 모드에 등록
② 사용자가 스크롤 시작               → UIKit이 메인 런루프를 tracking 모드로 돌림
③ tracking 모드의 묶음에는 이 타이머 없음 → 타이머 포트도 안 봄 → 발동 안 함
④ 스크롤 끝 → 다시 default 모드      → 밀린 타이머가 한 번 발동 (놓친 구간은 1회만)
```

-> 해결하려면 common에 등록한다. common에 등록하면 default + tracking 둘 다에서 발동한다.

```swift
let timer = Timer(timeInterval: 1, repeats: true) { _ in /* … */ }
RunLoop.main.add(timer, forMode: .common)   // default + tracking 둘 다에서 발동
```

| | 등록되는 곳 | 스크롤 중 |
|---|---|---|
| `DispatchQueue.main.async` | 메인 큐 포트 (common 모드일 때 묶음에 들어감) | 실행됨 |
| `Timer.scheduledTimer` | default 모드 | 멈춤 |
| `RunLoop.main.add(timer, forMode: .common)` | common 집합 전체 | 실행됨 |

### 모드는 모든 런루프에 있다

- 런루프를 만들 때는 default 모드 하나뿐이고, common 집합도 default만 들어 있다
- 다른 모드는 그 이름으로 소스를 추가하거나 run하는 순간 생긴다. 모드는 문자열이라 커스텀 모드도 만들 수 있다
- tracking 모드가 "메인 전용 정의"인 것은 아니다. UIKit이 스크롤·컨트롤 추적을 메인 스레드에서 하니까 메인 런루프에서만 쓰일 뿐이다. 백그라운드 런루프에는 누가 그 이름으로 등록하지 않는 한 없다
- 메인 런루프의 common에 tracking이 들어 있는 건 UIKit이 추가했기 때문이다 (외부 분석 기준). 백그라운드 런루프에 common으로 등록하면 사실상 default와 같다

### 실무에서

- 스크롤 중 타이머·카운트다운·배너 자동 넘김이 멈춤 → `.common`으로 등록
- 스크롤 중 무거운 작업을 미루고 싶으면 일부러 `.default`에만 건다 (`perform(_:with:afterDelay:inModes: [.default])`)
- observer도 모드 소속이다. `.defaultMode`에만 걸면 스크롤 중 BeforeWaiting은 안 찍힌다
- 메인 런루프를 커스텀 모드로 중첩 실행하면 그동안 메인 큐 블록과 default 타이머가 멈춘다

## 5. 연결: 탭 한 번 → 화면 반영

```
① 터치가 들어오는 길     backboardd → eventfetch 스레드(Source1) → 메인(Source0)
② 이벤트 처리            메인 런루프 4번 칸: touchesBegan, 버튼 액션 → setNeedsLayout (예약)
③ Core Animation commit  잠들기 직전(또는 Exit) observer: 레이아웃 → 그리기 → 전송
④ 앱 밖                  Render Server → GPU → VSync에 표시
(+) CADisplayLink        ③·④의 박자(VSync)에 맞춰 메인 런루프를 깨우는 타이머
```

Apple 테크톡의 렌더 루프(이벤트 → commit → render)에서 이벤트와 commit 칸이 런루프 안에서 어디인지를 채운 그림이다. 레이아웃이 필요하면 이벤트 단계가 끝나자마자 commit이 시작된다.

### 터치가 들어오는 길: 다른 스레드가 Source0 깃발 + WakeUp

```
손가락 터치
 → 시스템 프로세스(backboardd)가 Mach 포트로 앱에 메시지
 → [eventfetch 스레드] Source1 콜백이 받음           ← 메인 아님!
 → 메인 런루프의 Source0에 깃발 + 메인 깨움          ← 3번 그대로
 → [메인 스레드] 4번 칸에서 Source0 실행
 → UIApplication.sendEvent → UIWindow.sendEvent → touchesBegan / 버튼 액션
```

- 공식 문서는 "메인 스레드 런루프의 입력 소스로 이벤트를 받아 FIFO 큐로 처리한다"는 개념까지만 말한다
- eventfetch 스레드 경로는 외부 분석과 iOS 14 크래시 스택(`eventFetcherSourceCallback` → `processEventQueue` → `sendEvent:`)으로 확인된다
- 2015년 분석은 메인 스레드의 Source1이 받는다고 썼다. iOS 버전에 따라 바뀐 부분으로 보이고, 시스템 프로세스 이름과 도입 버전은 확인 필요

### Core Animation commit

```
Source0: 터치 핸들러 실행 → view.frame 변경, setNeedsLayout   (예약만)
 → Source0 끝
 → (잠들기 직전 / Exit) Core Animation observer
 → commit: Layout → Display → Prepare → Render Server로 전송
```

- 공식: 암묵적 트랜잭션은 그 스레드 런루프의 다음 바퀴에 commit된다. 정확히 몇 번 칸인지는 문서에 없다
- 외부: Core Animation이 BeforeWaiting과 Exit에 observer를 건다 (ibireme, 2015)
- 확인 필요: 터치 처리는 Source0이고, Source0을 처리한 바퀴는 BeforeWaiting을 건너뛴다(2번). 터치 직후 commit이 정확히 어느 경로인지, 06 노트 4번 후보(A: 소스 콜백 안 직접 commit / B: Exit observer / C: 메인 큐 블록 안)와 함께 실험으로 확정한다

### CADisplayLink

VSync(화면 갱신 박자)에 맞춰 불리는 런루프용 타이머

| | `Timer` | `CADisplayLink` |
|---|---|---|
| 박자 | 내가 정한 간격 (절대 시각) | 화면 갱신 박자 |
| 런루프 등록 | 필요 (`scheduledTimer`는 default) | 필요 (`add(to:forMode:)`) |
| 다음 프레임 정보 | 없음 | `targetTimestamp`: 다음 프레임 표시 시각 |
| 프레임 수 지정 | 간격으로 직접 | `preferredFrameRateRange` (최대 주사율의 약수로 맞춰짐) |
| 용도 | 일반 주기 작업 | 프레임 단위 애니메이션·그리기 |

- 실제 프레임 간격은 `targetTimestamp - timestamp`. 120Hz에서 약 8.3ms, 60Hz에서 약 16.7ms
- 공식 예제가 `.defaultRunLoopMode`로 등록한다. 스크롤 중에도 돌아야 하면 `.common`
- iOS 15부터 저전력 모드·발열·접근성 설정에 따라 사용할 수 있는 프레임 레이트가 바뀔 수 있다
- 내부적으로 어떤 소스로 런루프를 깨우는지는 확인 필요

### 실무에서

- 터치 반응이 늦다: 터치 핸들러(Source0) 안에서 무거운 동기 작업을 하면 그 바퀴가 안 끝나서 commit이 밀린다 → commit hitch. Instruments Animation Hitches / Hangs로 확인
- 크래시 스택 읽기: 메인 스레드 스택에 `eventFetcherSourceCallback`, `SOURCE0_PERFORM_FUNCTION`이 보이면 "터치 처리 중 크래시", `OBSERVER_CALLBACK` + `CA::Transaction`이면 "commit(레이아웃·그리기) 중 크래시"다. 원인 코드가 어느 단계에서 돌았는지 바로 좁혀진다
- 애니메이션을 `Timer`로 돌리면 끊긴다: 화면 박자와 안 맞고 스크롤 중엔 멈춘다 → `CADisplayLink`(`.common`) 또는 `UIView.animate` / Core Animation
- 터치 핸들러가 끝났다고 화면이 바뀐 게 아니다. commit → Render Server → VSync를 지나야 한다 (06 노트의 "`viewDidAppear` ≠ 화면 표시"와 같은 원리)

## 핵심 정리

1. 런루프는 스레드가 들어가서 도는 순서표다. 런루프에는 자기 스레드가 없고, run을 호출한 스레드의 스택 위에서 돈다. 스레드와 런루프 객체는 1:1이다.
2. 한 바퀴는 Entry → 타이머 → Source0 → 잠들기 직전 → 잠듦 → 깸 → 처리 → (반복) → Exit 순이다. observer는 여섯 칸에 끼어들 수 있다.
3. Source0을 처리한 바퀴는 잠들지 않고(poll) BeforeWaiting/AfterWaiting을 건너뛴다. observer 기반 측정·해석에서 주의한다.
4. 잠든 스레드는 현재 모드의 포트 묶음 하나를 기다린다. 묶음에는 Source1 · 타이머 · 메인 큐 · wakeUp 포트가 있고, Source0은 없다.
5. Source0은 깃발 + WakeUp이 필요하고, Source1과 타이머는 그 자체로 깨운다. Source0/Source1은 `version` 0/1에서 온 별칭이다.
6. 타이머는 모드당 포트 하나에 가장 빠른 절대 시각으로 알람을 맞춘다. 늦어지는 건 메인이 바빠서다.
7. 모드는 "이번에 볼 목록"이다. 스크롤 중에는 tracking 목록만 보므로 default 타이머는 멈추고, common에 등록한 것과 메인 큐 블록은 계속 돈다.
8. 탭 한 번은 eventfetch 스레드(Source1) → 메인 Source0(이벤트) → Core Animation commit → Render Server → VSync 순으로 화면에 반영된다.

## 셀프 체크

**Q1. 스레드와 런루프는 정확히 어떤 관계인가?**

- 소유는 1:1이다. 스레드마다 런루프 객체가 하나 있다. 실행은 스레드가 run 함수를 호출해서 자기 스택 위에서 루프를 도는 것이다. 런루프는 별도 실행 주체가 아니다

**Q2. Source0도 스레드인가?**

- 아니다. 런루프 목록에 등록된 할 일 항목(콜백 + 깃발)이다. 실행하는 건 그 런루프를 돌고 있는 스레드다

**Q3. Source0/Source1은 공식 명칭인가?**

- 아니다. 공식 용어는 커스텀 입력 소스 / 포트 기반 입력 소스이고, `CFRunLoopSourceContext`의 `version` 0/1과 CF 내부 함수 이름에서 나온 별칭이다

**Q4. 다른 스레드가 Source0에 `CFRunLoopSourceSignal`만 하고 `CFRunLoopWakeUp`을 빼면?**

- 깃발은 서 있지만 메인이 자고 있어서, 다른 이유로 깰 때까지 처리가 늦어진다. Signal은 "무엇을", WakeUp은 "지금"이다

**Q5. "바쁘면 바로 9로 간다"는 무슨 뜻인가?**

- 잠들기 직전에 이미 처리할 메시지가 와 있으면 잠들었다 바로 깨는 게 의미 없으니 6~8을 건너뛴다는 뜻이다. 오픈소스 CF 구현에서는 메인 큐 포트만 이렇게 미리 보고 연속 2번은 못 탄다. BeforeWaiting이 빠지는 더 흔한 경우는 Source0을 처리한 바퀴(poll)다

**Q6. 0.1초 뒤, 0.5초 뒤 타이머가 있으면 두 번째는 0.6초 뒤에 발동하나?**

- 아니다. 타이머 시각은 같은 기준점의 절대 시각이라 누적되지 않는다. 0.5초에 발동한다. 늦어지는 건 앞 핸들러가 오래 걸려 메인이 바쁠 때뿐이다

**Q7. 메인 큐 포트는 누가 듣고 누가 보내나?**

- 듣는 건 메인 런루프뿐이다. 보내는 건 메인 큐에 일을 넣는 어느 스레드든 되지만, 포트는 libdispatch가 대신 만진다

**Q8. `DispatchQueue.main.async`로 넣은 블록은 스크롤 중에도 실행되나?**

- 실행된다. 메인 큐 포트는 메인 런루프이고 현재 모드가 common 집합에 속할 때 묶음에 들어가는데, tracking은 common에 속한다. 반면 `Timer.scheduledTimer`는 default에만 등록돼 멈춘다

**Q9. "스크롤 중 메인 런루프가 tracking 모드로 돈다"는 무슨 뜻인가?**

- 스크롤하는 동안 메인 스레드가 tracking 모드의 목록만 보고 돈다는 뜻이다. 목록은 UIKit이 바꾸고, default에만 있는 일은 스크롤이 끝날 때까지 기다린다

**Q10. 모드는 메인 런루프에만 있는 개념인가?**

- 아니다. 모든 런루프에 있다. 처음엔 default뿐이고 다른 모드는 이름을 쓰는 순간 생긴다. tracking은 UIKit이 메인에서 쓰기 때문에 메인 런루프에 있을 뿐이다

## 참고 자료

**공식**

- [Threading Programming Guide — Run Loops](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/Multithreading/RunLoopManagement/RunLoopManagement.html) — 2014년 아카이브 문서. 정의, 한 바퀴 순서(1~10), 입력 소스·타이머·observer, 모드
- [Core Foundation Run Loops — About Run Loops (아카이브)](https://developer.apple.com/library/archive/documentation/CoreFoundation/Conceptual/CFRunLoops/Concepts/RunLoops.html) — 2008년, 은퇴 문서
- [CFRunLoop](https://developer.apple.com/documentation/corefoundation/cfrunloop)
- [CFRunLoopActivity](https://developer.apple.com/documentation/corefoundation/cfrunloopactivity)
- [CFRunLoopSourceContext](https://developer.apple.com/documentation/corefoundation/cfrunloopsourcecontext) · [CFRunLoopSourceContext1](https://developer.apple.com/documentation/corefoundation/cfrunloopsourcecontext1)
- [RunLoop.Mode](https://developer.apple.com/documentation/foundation/runloop/mode) · [.tracking](https://developer.apple.com/documentation/foundation/runloop/mode/tracking) · [.common](https://developer.apple.com/documentation/foundation/runloop/mode/common)
- [CADisplayLink](https://developer.apple.com/documentation/quartzcore/cadisplaylink)
- [CATransaction](https://developer.apple.com/documentation/quartzcore/catransaction)
- [Explore UI animation hitches and the render loop (Tech Talk 10855, 2020)](https://developer.apple.com/videos/play/tech-talks/10855)
- [Main event loop (Cocoa Application Competencies, 은퇴 문서)](https://developer.apple.com/library/archive/documentation/General/Conceptual/Devpedia-CocoaApp/MainEventLoop.html)
- [swift-corelibs-foundation `CFRunLoop.c`](https://github.com/swiftlang/swift-corelibs-foundation/blob/main/Sources/CoreFoundation/CFRunLoop.c) — Apple·Swift 프로젝트의 오픈소스 CF. iOS 탑재 버전과 동일한지는 확인 필요

**외부**

- [深入理解RunLoop (ibireme, 2015)](https://blog.ibireme.com/2015/05/18/runloop/) — Core Animation·autorelease pool observer, iOS common 집합, 2015년 기준 터치 경로. 현재 구현은 확인 필요
- [iOS 响应者链与事件处理全过程分析 (掘金)](https://juejin.cn/post/6918580923793408008) — eventfetch 스레드 Source1 → 메인 Source0 경로
- [RunLoop 源码解析 (Tencent Cloud)](https://cloud.tencent.com/developer/article/1615137) — 런루프 저장 구조, 지연 생성
- [Apple Developer Forums 670925](https://developer.apple.com/forums/thread/670925) — iOS 14 터치 처리 크래시 스택. 사용자 게시 글
