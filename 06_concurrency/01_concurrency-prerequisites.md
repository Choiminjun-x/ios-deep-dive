# Swift Concurrency 선수 개념

> 작성일: 2026-10-28

## 큰 그림

```
1 큐가 순서를 정한다
 → 2 UI는 main 큐 하나에 줄 세운다
 → 3 줄 세우지 않은 동시 쓰기 = 데이터 경쟁, 줄 사이의 틈 = 경쟁 상태
 → 4 줄 세우기(직렬)와 기다리기(sync)가 겹치면 데드락
 → 5·6 무엇이 공유되는지(캡처, 참조)를 알아야 줄 세울 대상이 보인다
```

Swift Concurrency는 줄 세우기를 `actor`로, 공유 확인을 `Sendable`로, 기다리기를 스레드를 막지 않는 `await`로 바꾼 모델이다.

| 선수 개념 | Swift Concurrency에서 이어지는 것 |
|---|---|
| 동기/비동기, 직렬/동시 | `await`, `actor`, `async let` · `TaskGroup` |
| UI는 메인에서만 | `@MainActor` |
| 데이터 경쟁 vs 경쟁 상태 | Swift 6 데이터 경쟁 검사, actor reentrancy |
| sync 데드락 | 스레드를 막지 않는 `await`, 협력 스레드 풀에서 블로킹 금지 |
| 클로저의 self 캡처 | `Task` 클로저, `@Sendable` 클로저 |
| 값/참조 타입 공유 | `Sendable` |

## 1. 동기/비동기, 직렬/동시

핵심: 두 쌍은 서로 다른 축이다

| | 기준 | 질문 |
|---|---|---|
| 동기/비동기 | 호출하는 쪽 | 맡긴 작업이 끝날 때까지 내가 기다리나? |
| 직렬/동시 | 작업을 받는 큐 | 이 큐는 한 번에 몇 개를 실행하나? |

두 축은 독립적이라 `serial.sync`, `serial.async`, `concurrent.sync`, `concurrent.async` 네 조합이 모두 가능하다.

비동기는 "지금 기다리지 않는다"는 뜻이지, "다른 스레드에서 돈다"는 뜻이 아니다.

- main에서 `DispatchQueue.main.async`를 부르면 블록은 나중에 같은 main 스레드에서 실행된다
- 반대로 `sync`는 성능 최적화로 가능하면 호출한 스레드에서 블록을 실행한다. 예외는 main 큐로, 항상 main 스레드에서 실행된다

**큐 ≠ 스레드**다. 큐는 작업을 줄 세우는 곳이고, 실제 실행은 시스템이 관리하는 스레드 풀이 한다.

```swift
queue.async { print("A") }   // serial 큐
queue.sync  { print("B") }
print("C")
// A → B → C
// A와 B의 순서는 큐가 "직렬"이라서, B와 C의 순서는 호출이 "sync"라서 정해짐
```

main 큐도 직렬 큐다.

### 실무에서

- main에서 다른 큐로 `sync`를 걸면 그 큐의 앞선 작업과 이 블록이 끝날 때까지 UI가 멈춘다 → 버벅임, hang 리포트
- 큐에 label을 붙여 두면 일시정지 후 Debug Navigator에서 스레드마다 어느 큐의 작업인지 보인다

## 2. UI를 메인 스레드에서만 업데이트해야 하는 이유

Apple 문서는 UIKit 클래스를 메인 스레드나 메인 디스패치 큐에서만 쓰라고 정해 둔다. 이유는 둘이다.

**이유 1 — 동시 접근**

```
스레드 A → tableView.reloadData()  ┐
스레드 B → tableView.deleteRows()  ┴→ 같은 객체를 동시에 수정 → 상태 깨짐 / 크래시
```

UIKit은 스레드 안전하지 않다. 모든 프로퍼티에 락을 걸면 모든 UI 호출이 느려진다. 그래서 UI 작업 전체를 main이라는 **직렬 큐 하나**에 줄 세웠다 (1번의 직렬 개념). 이것이 Apple의 의도적인 설계라는 설명은 외부 글에서 흔히 인용되는 것이고, Apple 문서가 직접 밝힌 이유는 아니다.

**이유 2 — 반영 타이밍**

```
이벤트 처리 → 커밋 (앱, main) → 렌더 준비 (렌더 서버) → 렌더 실행 (GPU) → 화면
```

앱은 커밋 단계에서 UI 변경을 모아 렌더 서버로 보낸다. 렌더 서버는 앱과 별도 프로세스다 ([렌더 루프와 첫 프레임](../02_app-lifecycle/06_render-loop-first-frame.md)). 백그라운드에서 UI를 바꾸면 이 커밋 흐름에 언제 실릴지 보장되지 않는다. run loop가 없는 스레드에서는 트랜잭션이 커밋되지 않을 수 있다는 외부 분석이 있지만, 내부 동작은 확인 필요다.

어기면 항상 크래시가 나는 게 아니라 UI 업데이트 누락, 화면 결함, 데이터 손상, 크래시가 **가끔** 생긴다. 재현이 안 되는 버그가 된다.

### 실무에서

- 단골 위치: `URLSession` completion handler 안의 `self.label.text = …`, Combine에서 `receive(on:)` 없이 `sink`
- **Main Thread Checker**가 잡아 준다

| 항목 | 내용 |
|---|---|
| 도입 | Xcode 9 |
| 방식 | 앱 실행 시 메인 전용 메서드를 검사 코드가 붙은 버전으로 바꿔 끼움 (재컴파일 불필요) |
| 비용 | CPU 1~2%, 실행 시간 0.1초 미만 |
| 켜짐 | 디버거로 실행하면 자동 (Scheme → Diagnostics) |
| 한계 | 실행된 경로만 잡음. Apple API만 검사하고 내 모델 코드의 경쟁은 못 잡음 → Thread Sanitizer |

- 증상: Xcode에 보라색 런타임 경고. 출시 빌드에서는 "가끔 안 바뀌는 라벨"이나 재현 안 되는 크래시
- 고치기: `DispatchQueue.main.async { … }`

## 3. 데이터 경쟁 vs 경쟁 상태

데이터 경쟁은 **메모리 접근** 수준의 문제, 경쟁 상태는 **로직 순서** 수준의 문제다.

| | 데이터 경쟁 (data race) | 경쟁 상태 (race condition) |
|---|---|---|
| 조건 | 같은 메모리에, 동기화 없이, 동시에, 하나 이상이 쓰기 | 실행 타이밍이나 순서에 따라 결과가 달라짐 |
| 결과 | 정의되지 않은 동작 (값 깨짐, 크래시) | 값은 멀쩡한데 결과가 틀림 |
| 고치기 | 락, 직렬 큐, actor | 확인과 변경을 한 덩어리로 묶기 |
| 잡는 도구 | Thread Sanitizer, Swift 6 컴파일러 | 코드 리뷰, 테스트 |

### 락이 동기화하는 방법

`lock()`은 락을 얻을 수 있을 때까지 호출한 스레드를 멈춰 세운다. `unlock()`은 락을 내려놓는다.

```
스레드 1                      락 상태            스레드 2
lock()  → 획득                [1이 보유]
balance 읽기                                     lock() → 이미 잡혀 있음 → 대기
unlock()                      [비어 있음]   →    획득 → 진행
```

그래서 `lock()`과 `unlock()` 사이(임계 구역)는 한 번에 한 스레드만 실행한다. "동기화됐다"는 건 동시에 접근하려 해도 실제 접근은 한 줄로 줄 세워진다는 뜻이다. 직렬 큐와 같은 효과다.

### 락이 있어도 생기는 경쟁 상태

```swift
func withdraw(_ amount: Int) {
    lock.lock(); let current = balance; lock.unlock()
    if current >= amount {
        lock.lock(); balance = current - amount; lock.unlock()
    }
}
// 두 스레드가 동시에 withdraw(100) 호출
```

```
[lock — 읽기 — unlock]   ← 틈 →   [lock — 쓰기 — unlock]

스레드 1: 100 읽음
                         스레드 2: 100 읽음
스레드 1: 100 >= 100 ✓
                         스레드 2: 100 >= 100 ✓
스레드 1: balance = 0
                         스레드 2: balance = 0
→ 100원 잔고에서 200원이 나감. 잔고는 0으로 멀쩡해 보임
```

- 각 접근은 락 안에 있어서 데이터 경쟁은 없다
- 확인과 변경 사이에 락이 풀려서 다른 스레드가 끼어든다 → 경쟁 상태
- 고치려면 읽기 · 확인 · 쓰기 전체를 하나의 임계 구역으로 묶는다. 락의 범위가 원자적이어야 하는 단위와 맞아야 한다

### 둘은 독립적이다

| | 데이터 경쟁 O | 데이터 경쟁 X |
|---|---|---|
| 경쟁 상태 O | 락 없는 `withdraw` | 위 코드 |
| 경쟁 상태 X | 결과에 영향 없는 플래그 쓰기 | 정상 코드 |

Regehr의 정리 기준이다. "모든 데이터 경쟁은 경쟁 상태"라고 쓰는 외부 글도 있지만, 많이 겹칠 뿐 독립적이라고 보는 쪽이 정확하다. 다만 Swift에서는 데이터 경쟁 자체가 허용되지 않는다.

### 실무에서

- Thread Sanitizer는 데이터 경쟁만 잡는다. 위 `withdraw`는 TSan을 켜도 조용하다
- 경쟁 상태의 흔한 증상: 버튼 연타로 중복 결제·중복 요청, 토큰 갱신 두 번, 캐시 확인 후 중복 다운로드
- "값이 깨진다" → 데이터 경쟁, "값은 정상인데 결과가 틀리다" → 경쟁 상태를 의심한다
- `lock()` · `unlock()`은 `defer { lock.unlock() }`으로 짝을 맞춘다. unlock을 빠뜨리면 다음 스레드가 영원히 기다린다
- 락으로 보호하는 변수는 모든 접근이 락을 거쳐야 한다. 한 곳이라도 락 없이 읽으면 거기서 데이터 경쟁이 생긴다

## 4. GCD `sync` 데드락

데드락은 스레드가 모자라서 생기는 게 아니라, 큐의 규칙(직렬)과 sync의 기다림이 부딪쳐서 생긴다.

```
규칙 ① 직렬 큐:  앞 작업이 끝나야 다음 작업이 시작된다   (큐가 지키는 규칙)
규칙 ② sync:     맡긴 작업이 끝나야 내가 다음 줄로 간다   (호출자가 지키는 규칙)
```

Apple 문서도 현재 큐를 대상으로 `sync`를 부르면 데드락이 난다고 적어 둔다.

### 직렬 큐 안에서 같은 큐로 sync

```swift
let serial = DispatchQueue(label: "s")
serial.async {
    serial.sync { print("inner") }
}
```

창구가 하나뿐인 은행으로 보면 이렇다. 직렬 큐는 창구 하나, 블록은 손님, `async`는 번호표만 뽑고 떠나기, `sync`는 업무가 끝날 때까지 그 자리에서 기다리기다.

```
1단계  main이 serial.async { 바깥 } 호출
       → 바깥이 번호표 받음. main은 기다리지 않고 떠남
2단계  창구가 바깥을 부름 → 바깥 실행 시작
3단계  바깥 안에서 serial.sync { inner }
       → inner가 대기줄 맨 뒤로
       → 바깥은 sync라서 inner가 끝날 때까지 창구를 붙잡은 채 기다림
4단계  창구: "바깥이 끝나야 inner를 부를 수 있음"
       바깥: "inner가 끝나야 나도 끝남"
       → 아무도 못 움직임 = 데드락
```

```
바깥 블록 ──(②) inner 끝날 때까지 기다림──→ inner
    ↑                                      │
    └────(①) 바깥이 끝나야 시작 가능─────────┘
```

바깥이 `async`인 건 상관없다. 바깥 `async`는 main과 바깥 블록 사이의 관계이고, 데드락은 바깥과 inner 사이에서 생긴다.

### 안쪽을 async로 바꾸면

```swift
serial.async {
    serial.async { print("inner") }   // 번호표만 주고 떠남
    print("outer end")
}
// 항상 outer end → inner
```

바깥이 inner를 기다리지 않고 끝까지 실행한다 → 창구가 빈다 → inner가 불려 나온다. 기다림이 한 방향뿐이라 원이 안 생긴다. 직렬 큐라서 순서도 항상 보장된다. 같은 코드를 동시 큐에서 돌리면 순서는 보장되지 않는다.

### 정리

| 상황 | 결과 | 이유 |
|---|---|---|
| main에서 `main.sync` | 데드락 → 크래시 | main은 직렬 큐 |
| 직렬 큐 안에서 같은 큐 `sync` | 데드락 | 규칙 ①과 ②가 충돌 |
| 동시 큐 안에서 같은 큐 `sync` | 괜찮음 | 규칙 ①이 없음. 단 `.barrier`면 직렬처럼 동작 |
| 안쪽을 `async`로 | 괜찮음 | ② 방향의 기다림이 사라져 원이 끊김 |
| 큐 A 안에서 B `sync`, B 안에서 A `sync` | 타이밍에 따라 데드락 | 큐 두 개로 원이 생김 |

### 실무에서

- 실제 증상은 멈춤보다 크래시다. libdispatch가 감지해서 `BUG IN CLIENT OF LIBDISPATCH: dispatch_sync called on queue already owned by current thread`를 남기고, 스택에 `__DISPATCH_WAIT_FOR_QUEUE__`가 찍힌다
- 흔한 원인은 숨은 재진입이다. `queue.sync`를 쓰는 헬퍼를 누군가 그 큐 안에서 부른다. 코드에는 `sync`가 한 번뿐이라 찾기 어렵다
- 큐 두 개가 서로 기다리는 경우는 감지되지 않고 그냥 멈춘다 → 디버거로 일시정지 후 `dispatch_sync` 대기 중인 스레드 두 개를 찾는다

## 5. 클로저의 `self` 캡처

### 순환 참조

ARC는 클래스 인스턴스의 강한 참조 수를 세다가 0이 되면 해제한다. 순환 참조는 서로를 **강하게** 붙잡아서 카운트가 0이 안 되는 상태다.

```
[A] ──강──→ [B]
 ↑           │
 └────강─────┘
외부 참조가 다 사라져도 A 1, B 1 → 영원히 해제 안 됨 (메모리 누수)
```

한쪽을 `weak`로 바꾸면 카운트를 올리지 않아서 원이 끊긴다.

순환 참조는 클로저를 self가 (직접 또는 간접으로) 소유하고, 클로저 내부에서 self를 강하게 캡처하면 원이 생기므로 순환 참조다.

### 캡처 ≠ 순환 참조

클로저 안에서 `self`를 쓰면 클로저 → `self` 화살표는 항상 생긴다. 확인할 건 반대 방향이다. 클로저를 누가 보관하는지 거슬러 올라가다가 `self`가 나오면 원이다.

| 코드 | 보관 경로 | 순환 |
|---|---|---|
| `self.onComplete = { self… }` | self → closure | O |
| `button.tapHandler = { self… }` | self → button → closure | O (간접) |
| `manager.fetch { self… }` (manager가 completion을 저장) | self → manager → closure | O (간접) |
| `.sink { self… }.store(in: &cancellables)` | self → cancellables → 구독 → closure | O |
| `DispatchQueue.main.async { self… }` | main 큐 → closure (실행 후 해제) | X |
| `[1, 2].map { self… }` | 즉시 실행 후 사라짐 | X |

`DispatchQueue.main.async { self… }`는 순환이 아니고, 블록이 실행될 때까지 `self`의 수명을 늘릴 뿐이다. 여기서 `[weak self]`는 필수가 아니라 선택이다.

| | 강한 캡처 (기본) | `[weak self]` |
|---|---|---|
| 블록 실행 시점의 `self` | 반드시 살아 있음 | 이미 해제됐으면 `nil` |
| 고르는 기준 | 실행이 꼭 돼야 할 때 | 화면이 닫혔으면 안 해도 될 때 |

`manager`가 completion을 호출한 뒤 비운다면 원은 호출될 때까지만 있다. `manager`의 구현을 보장할 수 없으면 `[weak self]`를 붙인다.

### 캡처 시점

캡처 - 캡처는 클로저가 만들어지는 순간에 일어난다. 클로저를 선언한 시점의 값으로 초기화된다. → 순환 참조는 클로저를 만들어서 저장하는 순간 이미 생긴다.

단, 선언 시점의 값으로 고정되는 건 캡처 리스트(`[x]`, `[weak self]`)에 적은 것이다. 캡처 리스트 없이 쓴 변수는 참조로 잡혀서 실행할 때 그 변수의 최신 값을 본다 (→ 6번).

캡처한 self는 실행이 끝나도 놓지 않는다. 클로저가 해제될 때 놓는다.

### `[weak self]` + `guard let self`의 한계

```swift
queue.async { [weak self] in
    guard let self else { return }   // 여기서 강한 참조가 새로 생김
    heavyWork()                      // 이 동안 self는 해제되지 않음
    self.label.text = "done"
}
```

`guard let self` 이후는 다시 강한 참조이고 클로저 스코프가 끝날 때까지 유지된다. `weak`는 실행이 시작되는 순간에만 의미가 있다. 긴 루프라면 반복마다 `self?`로 확인해서 중간에 빠져나온다.

### non-escaping 클로저에 `self.`가 필요 없는 이유

`self.`를 강제하는 목적은 "여기서 self를 캡처한다"를 눈에 보이게 하는 것이다. non-escaping 클로저(`map`, `sync`)는 함수가 리턴하기 전에 끝나서 순환이 불가능하므로, 컴파일러는 escaping 클로저에만 명시적 `self`를 요구한다.

| 버전 | 제안 | 내용 |
|---|---|---|
| Swift 5.3 | SE-0269 | escaping이어도 `[self] in`으로 명시하면 암시적 `self` 허용 |
| Swift 5.8 | SE-0365 | `[weak self]` 후 `guard let self`로 풀면 암시적 `self` 허용 |

### 실무에서

- 화면을 닫았는데 `deinit`이 안 불리면 순환 참조 → Memory Graph Debugger로 원을 찾는다
- 화면을 닫았는데 콜백이 뒤늦게 UI를 건드리면 수명이 늘어난 경우다
- 단골 위치: 프로퍼티로 저장하는 클로저, `NotificationCenter` 블록 옵저버, `cancellables`에 저장하는 Combine `sink`, completion을 저장하는 매니저

## 6. 값 타입과 참조 타입을 여러 스레드에서 공유할 때

안전한지는 타입이 아니라, 여러 스레드가 같은 저장 공간을 동시에 바꾸느냐로 정해진다. 하나라도 쓰기가 섞이면 데이터 경쟁이라 값이 깨진다. 읽기만 하면 안전하다.

```
값 타입, 복사해서 나눠 줌 → 안전
  스레드 1: var a = original → a.append(1)   [a의 저장 공간]
  스레드 2: var b = original → b.append(2)   [b의 저장 공간]

값 타입이라도 변수 하나를 공유 → 위험
  스레드 1 ─┐
            ├→ numbers.append(…)   [numbers 하나]
  스레드 2 ─┘

참조 타입 → 복사해도 같은 객체
  스레드 1: let a = obj ─┐
                        ├→ [같은 인스턴스]
  스레드 2: let b = obj ─┘
```

| 상황 | 안전 |
|---|---|
| struct를 복사해서 각 스레드에 전달 | O |
| `var` 하나(struct, Array)를 여러 스레드가 변경 | X — 클로저가 `var`를 참조로 잡음 |
| 클래스 프로퍼티를 가진 struct 복사 | X — 그 객체는 공유됨 |
| `let` 클래스인데 안에 `var` 프로퍼티 | X — `let`은 참조만 고정 |
| `final class`, 저장 프로퍼티가 전부 `let` + Sendable 타입 | O |
| 여러 스레드가 읽기만 | O |

```swift
var numbers: [Int] = []
DispatchQueue.concurrentPerform(iterations: 100) { i in
    numbers.append(i)   // 데이터 경쟁 → 원소 누락, 가끔 EXC_BAD_ACCESS · SIGABRT
}
```

Swift 6 검사에서는 "동시 실행 코드에서 캡처한 var를 변경했다"는 진단이 나온다. Swift 5 모드 + Complete 검사에서도 나오는지는 확인 필요 (샘플 프로젝트에서 확인).

### 복사와 공유의 딜레마

캡처 리스트로 각자 복사본을 가지면 안전하지만 결과가 원본에 합쳐지지 않는다. 캡처 리스트로 잡은 값은 상수라서 `{ [numbers] i in numbers.append(i) }`는 컴파일조차 안 된다. 공유하면 결과는 모이지만 위험하다. 해결은 둘이다.

| 방법 | 내용 | 주의 |
|---|---|---|
| A. 줄 세우기 | 공유 변수 접근만 락이나 직렬 큐로 보호 | 순서는 보장 안 됨 |
| B. 각자 계산 후 합치기 | 작업 중에는 아무도 공유 변수를 안 건드리고, 한 곳에서 모음 | `TaskGroup`의 설계 |

```swift
let lock = NSLock()
var numbers: [Int] = []
DispatchQueue.concurrentPerform(iterations: 100) { i in
    let value = heavyCompute(i)   // 무거운 계산은 동시에
    lock.lock()
    numbers.append(value)         // 공유 변수 접근만 줄 세움
    lock.unlock()
}
```

### 실무에서

- 가장 흔한 곳: 싱글톤 매니저 안의 `var cache: [String: Data]`를 여러 큐의 콜백에서 읽고 쓰기
- 스택에 `Array.append`, `Dictionary` 내부, `_StringGuts`가 찍히고 재현이 안 되면 데이터 경쟁 → Scheme → Diagnostics에서 Thread Sanitizer를 켠다
- 락: `OSAllocatedUnfairLock`은 iOS 16 이상이다. 최소 버전이 iOS 15면 `NSLock`을 쓰거나 가용성 분기가 필요하다

## 핵심 정리

1. 동기/비동기는 호출하는 쪽이 기다리느냐, 직렬/동시는 큐가 한 번에 몇 개를 실행하느냐다. 두 축은 독립적이고, 비동기는 다른 스레드를 뜻하지 않는다. 큐 ≠ 스레드.
2. UIKit은 스레드 안전하지 않고 그리기는 메인 run loop의 커밋에 묶여 있어서, UI 작업 전체를 main이라는 직렬 큐 하나에 줄 세운다. 어기면 가끔 깨지고, Main Thread Checker가 잡는다.
3. 데이터 경쟁은 동기화 없는 동시 쓰기(메모리 수준), 경쟁 상태는 순서에 따라 결과가 달라지는 것(로직 수준)이다. 락을 걸어도 임계 구역 사이에 틈이 있으면 경쟁 상태가 남는다. Swift 6 컴파일러와 TSan은 데이터 경쟁만 잡는다.
4. 데드락은 직렬 큐의 순서와 sync의 기다림이 같은 큐에서 원을 이룰 때 생긴다. 동시 큐나 안쪽 async면 원이 끊긴다. 실제로는 "already owned by current thread" 크래시로 나타난다.
5. 캡처와 순환 참조는 다르다. 클로저 보관자를 거슬러 올라가 self가 나와야 순환이다. 캡처는 클로저가 만들어지는 순간에 일어나고, `guard let self` 이후는 다시 강한 참조다.
6. 스레드 안전은 타입이 아니라 같은 저장 공간을 동시에 바꾸느냐로 정해진다. 값 타입도 변수 하나를 공유하면 위험하고, `let` 클래스도 `var` 프로퍼티가 있으면 위험하다. 해결은 줄 세우기 또는 각자 계산 후 합치기다.

## 셀프 체크

**Q1. 직렬/동시는 동기/비동기와 비슷한 말인가?**

- 아니다. 동기/비동기는 호출하는 쪽이 기다리느냐, 직렬/동시는 큐가 한 번에 몇 개를 실행하느냐다. 서로 독립이라 네 조합이 다 가능하다

**Q2. Apple은 왜 UIKit을 스레드 안전하게 만들지 않고 "main에서만"이라는 규칙을 택했나?**

- 모든 프로퍼티에 락을 걸면 모든 UI 호출이 느려진다. 대신 UI 작업을 main 직렬 큐 하나에 줄 세웠다. 그리기도 메인 run loop의 커밋에 묶여 있다. 어기면 항상 크래시가 아니라 가끔 깨진다

**Q3. 각 접근마다 락을 건 `withdraw`를 두 스레드가 동시에 부르면 데이터 경쟁인가, 경쟁 상태인가?**

- 경쟁 상태다. 각 접근은 락으로 동기화돼 있어서 데이터 경쟁은 아니지만, 확인과 변경 사이에 락이 풀려 다른 스레드가 끼어들 수 있고, 그 실행 순서에 따라 결과가 달라진다. Swift 6 컴파일러와 TSan은 이걸 잡지 못한다

**Q4. `serial.async { serial.sync { … } }`는 바깥이 async인데 왜 데드락인가? 동시 큐라면?**

- 바깥 async는 main이 기다리지 않는다는 뜻일 뿐이다. 바깥 블록은 큐를 차지한 채 inner를 기다리고, inner는 직렬 규칙 때문에 바깥이 끝나야 시작할 수 있다. 동시 큐는 앞 작업이 끝나지 않아도 다음 작업을 시작할 수 있어서 데드락이 안 난다

**Q5. `DispatchQueue.main.async { self.label.text = "done" }`에 순환 참조가 있나?**

- 없다. self가 그 클로저를 보관하지 않는다. 블록이 실행될 때까지 self의 수명이 늘어날 뿐이라 `[weak self]`는 선택이다. 보관자를 거슬러 올라가 self가 나와야 순환이다

**Q6. `[weak self]` 후 `guard let self`를 하고 그 아래에서 오래 걸리는 작업을 하면?**

- guard 이후는 강한 참조라 작업이 끝날 때까지 self가 해제되지 않는다. weak는 실행이 시작되는 순간에만 의미가 있다

**Q7. struct는 값 타입이니 여러 스레드에서 써도 항상 안전한가? `let` 클래스는?**

- 둘 다 아니다. struct도 변수 하나를 공유하면 같은 저장 공간이라 위험하다. `let`은 참조만 고정해서, 안에 `var` 프로퍼티가 있으면 위험하다. 기준은 타입이 아니라 같은 저장 공간을 동시에 바꾸느냐다

## 참고 자료

**공식**

- [Apple — DispatchQueue.sync(execute:)](https://developer.apple.com/documentation/dispatch/dispatchqueue/sync(execute:)-3segw)
- [Apple — DispatchQueue](https://developer.apple.com/documentation/dispatch/dispatchqueue)
- [libdispatch queue.h (Apple 오픈소스)](https://opensource.apple.com/source/libdispatch/libdispatch-500.10.1/dispatch/queue.h.auto.html)
- [Apple — UIKit](https://developer.apple.com/documentation/uikit)
- [Apple — Main Thread Checker](https://developer.apple.com/documentation/code_diagnostics/main_thread_checker)
- [Apple Tech Talk — Explore UI animation hitches and the render loop](https://developer.apple.com/videos/play/tech-talks/10855/)
- [Apple — NSLocking](https://developer.apple.com/documentation/foundation/nslocking)
- [Swift Migration Guide — Data Race Safety](https://github.com/apple/swift-migration-guide/blob/main/Guide.docc/DataRaceSafety.md)
- [The Swift Programming Language — Automatic Reference Counting](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/automaticreferencecounting/)
- [The Swift Programming Language — Closures](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/closures/)
- [Swift 표준 라이브러리 — Sendable.swift](https://github.com/apple/swift/blob/2cf7b3a063698d1f0e4c2a8e981f328ae077e7f4/stdlib/public/core/Sendable.swift)
- [swift-evolution — John McCall(Apple) 답변: 디스패치 큐 클로저와 순환 참조 (2017)](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20170828/039336.html)
- [Swift Forums — SE-0365 리뷰](https://forums.swift.org/t/se-0365-allow-implicit-self-for-weak-self-captures-after-self-is-unwrapped/59040)

**외부**

- [John Regehr — Race Condition vs. Data Race (2011)](https://blog.regehr.org/archives/490)
- [Swift Forums — GCD expected deadlock did not work out (2025)](https://forums.swift.org/t/gcd-expected-deadlock-did-not-work-out/81529)
- [Swift Forums — Deadlock When Using DispatchQueue from Swift Task](https://forums.swift.org/t/deadlock-when-using-dispatchqueue-from-swift-task/66058)
- [Apple Developer Forums — .sync in concurrent queue](https://developer.apple.com/forums/thread/106319)
- [Apple Developer Forums — dispatch_sync called on queue already owned 크래시](https://developer.apple.com/forums/thread/699524)
- [Capital One — Main Thread Checker 튜토리얼](https://capitalone.com/tech/software-engineering/main-thread-checker-tutorial)
- [GitHub — CoreAnimationPerformanceTuning (백그라운드 CATransaction)](https://github.com/dinozaurus0/CoreAnimationPerformanceTuning)
- [Swift by Sundell — Is using [weak self] always required? (2020)](https://swiftbysundell.com/questions/is-weak-self-always-required)
- [Swift Forums — Is [weak self] actually necessary in a Task closure?](https://forums.swift.org/t/is-weak-self-actually-necessary-in-a-task-closure/88555)
- [Apple Developer Forums — Memory leaks caused by closures](https://developer.apple.com/forums/thread/765587)
- [Swift Forums — Use of capture lists in structs](https://forums.swift.org/t/use-of-capture-lists-in-structs/39050)
- [Sarunw — Allow implicit self for weak self captures (Swift 5.8)](https://sarunw.com/posts/allow-implicit-self-for-weak-self/)
- [Swift Forums — Understanding Swift's value type thread safety (2020)](https://forums.swift.org/t/understanding-swifts-value-type-thread-safety/41406)
- [Apple Developer Forums — Potential of race condition in ARC?](https://developer.apple.com/forums/thread/769002)
- [SwiftLee — Sendable and @Sendable](https://avanderlee.com/?p=5134)
