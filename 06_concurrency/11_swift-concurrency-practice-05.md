# Swift Concurrency 실전 5 — 공유 데이터 관리와 Actor

> 작성일: 2026-11-10

## 1. 문제 상황

쇼핑 앱에서 여러 비동기 작업이 하나의 장바구니 데이터를 동시에 수정하는 상황을 가정한다.

```swift
final class CartManager {
    var totalPrice = 0

    func addItem(price: Int) async {
        let currentPrice = totalPrice

        try? await Task.sleep(for: .milliseconds(100))

        totalPrice = currentPrice + price
    }
}
```

두 작업이 거의 동시에 실행되면 다음과 같은 문제가 발생할 수 있다.

```swift
async let first = cartManager.addItem(price: 1000)
async let second = cartManager.addItem(price: 2000)

await (first, second)
```

`Task.sleep(for:)`는 iOS 16+다. iOS 15 타깃에서 실험하려면 `Task.sleep(nanoseconds: 100_000_000)`을 쓴다.

### 발생 가능한 실행 순서

1. 작업 A가 `totalPrice`를 읽는다. → 0
2. 작업 B가 `totalPrice`를 읽는다. → 0
3. 작업 A가 대기한다.
4. 작업 B가 대기한다.
5. 작업 A가 `totalPrice = 1000`을 수행한다.
6. 작업 B가 `totalPrice = 2000`을 수행한다.

최종 결과는 3,000원이 아니라 1,000원 또는 2,000원이 될 수 있다.

이를 Lost Update 문제라고 볼 수 있다.

### 이 코드에는 문제가 두 개 겹쳐 있다

| 문제 | 원인 | 결과 |
|---|---|---|
| Data Race | 두 자식 Task가 서로 다른 스레드에서 `totalPrice`를 동시에 읽고 씀 | 메모리 수준에서 정의되지 않은 동작 |
| Lost Update (Logical Race) | 읽기와 쓰기 사이에 `await`가 있어 다른 작업이 끼어듦 | 값이 덮어써짐 |

`async let`의 두 자식은 동시에 실행되고, `CartManager`는 아무 격리도 없는 class다. 그래서 두 자식이 정말로 같은 메모리를 동시에 건드린다.

Actor는 첫 번째 문제만 해결한다. 두 번째 문제는 3장에서 보듯 Actor로 바꿔도 그대로 남는다. 두 개념의 차이는 [04_actor.md의 7장](04_actor.md)에 정리해 두었다.

### 실무에서

- Swift 5 언어 모드 + Strict Concurrency Minimal이면 이 코드는 경고 없이 컴파일된다. Complete 검사나 Swift 6 모드에서는 Sendable이 아닌 `cartManager`를 두 자식 Task가 함께 쓰는 지점을 컴파일러가 지적한다 (정확한 메시지는 샘플 프로젝트에서 확인 필요)
- Thread Sanitizer를 켜고 실행하면 class 버전은 data race로 잡힌다. Actor 버전의 Lost Update는 메모리 접근 자체가 안전하므로 TSan에 잡히지 않는다

## 2. Actor를 사용한 공유 상태 보호

`actor`는 내부 상태에 대한 동시 접근을 직렬화하여 Data Race를 방지한다.

```swift
actor CartManager {
    var totalPrice = 0

    func addItem(price: Int) async {
        let currentPrice = totalPrice

        try? await Task.sleep(for: .milliseconds(100))

        totalPrice = currentPrice + price
    }
}
```

하지만 Actor를 사용했다고 해서 모든 논리적 경쟁 상태가 해결되는 것은 아니다.

이 코드는 Data Race는 없어졌지만, 여전히 1,000원 또는 2,000원이 나온다.

## 3. Actor Reentrancy

Actor 내부 메서드에서 `await`를 만나면 해당 작업은 중단될 수 있다.

이때 Actor는 다른 작업의 접근을 허용한다.

즉, Actor는 메서드 전체를 하나의 원자적 작업으로 보장하지 않는다.

### 실행 흐름

| 순서 | 작업 A | 작업 B |
|---|---|---|
| 1 | totalPrice 읽기 (0) | |
| 2 | await 대기 | |
| 3 | | totalPrice 읽기 (0) |
| 4 | | await 대기 |
| 5 | totalPrice = 1000 | |
| 6 | | totalPrice = 2000 |

```
Actor가 한 번에 실행하는 단위 = await와 await 사이의 동기 구간

작업 A: [읽기 0] ─await─ ................ [쓰기 1000]
작업 B:            [읽기 0] ─await─ ..................... [쓰기 2000]
         ↑ 각 [ ] 구간은 서로 겹치지 않음 (직렬화)
         ↑ 하지만 A의 [읽기]와 [쓰기] 사이에 B의 [읽기]가 들어옴 (재진입)
```

Actor 내부에서도 `await` 전후의 공유 상태가 동일하다고 가정하면 안 된다.

Swift actor가 재진입을 허용하는 이유(데드락 방지)는 [04_actor.md의 4장](04_actor.md)에 있다.

## 4. 해결 방법

공유 상태를 읽고 수정하는 구간에 suspension point가 없도록 구성한다.

```swift
actor CartManager {
    private var totalPrice = 0

    func addItem(price: Int) async {
        try? await Task.sleep(for: .milliseconds(100))

        let currentPrice = totalPrice
        totalPrice = currentPrice + price
    }
}
```

이제 비동기 대기 이후에 공유 상태를 읽고 수정한다.

`totalPrice`를 읽는 시점부터 수정하는 시점까지 같은 Actor의 다른 작업이 끼어들 수 없으므로 Lost Update를 방지할 수 있다.

```
작업 A: ─await─ ........ [읽기 0 → 쓰기 1000]
작업 B: ─await─ ................ [읽기 1000 → 쓰기 3000]
         ↑ 읽기와 쓰기가 한 동기 구간 안에 있음 → 끼어들 틈이 없음
```

마지막 두 줄은 `totalPrice += price` 한 줄로 써도 같다.

### 비동기 검증이 필요한 경우

```swift
func addItem(price: Int) async {
    let validatedPrice = await validatePrice(price)

    totalPrice += validatedPrice
}
```

검증 작업이 끝난 다음 공유 상태를 읽고 수정한다.

다음과 같이 작성하면 문제가 다시 발생할 수 있다.

```swift
func addItem(price: Int) async {
    let currentPrice = totalPrice

    let validatedPrice = await validatePrice(price)

    totalPrice = currentPrice + validatedPrice
}
```

`await` 이전에 읽어둔 값이 다른 작업에 의해 오래된 값이 될 수 있기 때문이다.

### 실무에서 — 상태를 바꾸는 메서드는 동기로 만든다

WWDC21 "Protect mutable state with Swift actors"의 가이드는 "상태 변경은 동기 코드에서 하라"다. 이걸 가장 확실하게 지키는 방법은 상태를 바꾸는 메서드 자체를 `async`가 아닌 동기 메서드로 두는 것이다.

```swift
actor CartManager {
    private var totalPrice = 0

    // 동기 메서드 → 본문에 await를 쓸 수 없음 → 재진입이 원천적으로 불가능
    func add(_ price: Int) {
        totalPrice += price
    }

    func total() -> Int { totalPrice }
}

// 비동기 작업(검증 등)은 호출하는 쪽에서 먼저 끝낸다
let validated = await validatePrice(price)
await cartManager.add(validated)
```

| 구분 | async 메서드 안에서 조심하기 | 동기 메서드로 분리 |
|---|---|---|
| 보장 방식 | 코드 리뷰로 await 위치를 확인 | 컴파일러가 await를 막음 |
| 나중에 누가 await를 추가하면 | 조용히 버그가 다시 생김 | 컴파일 오류 |
| 외부에서 호출 | `await` 필요 | 외부에서는 여전히 `await` 필요 (actor 진입 대기) |

외부에서 `await cartManager.add(_:)`로 부르는 건 "actor에 들어가기를 기다리는 것"일 뿐이다. 메서드 본문 안에 중단 지점이 생기는 것은 아니다.

### 실무에서 — await 전 값을 써야 하는 경우

검증 결과가 "검증 시작 시점의 장바구니 상태"에 의존한다면, `await` 뒤에 최신 값으로 다시 확인해야 한다(재검증). 또는 `await` 전에 미리 반영해 두고 실패하면 되돌린다(예약).

재고 차감 예시로 두 방식을 비교한 내용은 [04_actor.md의 6장](04_actor.md)에 있다. 같은 요청이 중복으로 들어오는 경우(같은 상품 동시 추가 등)는 진행 중인 Task를 공유하는 패턴을 쓴다 (04_actor.md 5장).

## 5. Actor가 보장하는 것과 보장하지 않는 것

Actor를 사용한다고 모든 동시성 문제가 해결되는 것은 아니다.

공유 상태를 안전하게 보호하는 것과 여러 비동기 작업으로 구성된 비즈니스 로직의 일관성을 보장하는 것은 서로 다른 문제다.

특히 Actor 내부에서 `await`를 사용하는 경우, 중단된 동안 다른 작업이 상태를 변경할 수 있다는 점을 고려해야 한다.

| Actor가 보장하는 것 | Actor가 보장하지 않는 것 |
|---|---|
| 한 번에 하나의 동기 구간만 상태에 접근 (Data Race 없음) | 메서드 전체의 원자성 |
| 외부에서는 `await`를 거쳐서만 접근 | `await` 전후 상태가 같다는 것 |
| 컴파일 타임 격리 검사 | 호출이 들어온 순서대로 실행된다는 것 |

### 실무에서 — 재현 테스트

Lost Update는 타이밍 문제라 가끔만 나타난다. 동시 호출 수를 늘리면 확실하게 재현된다.

```swift
let cart = CartManager()   // 2장 버전 (await 전에 읽는 코드)

await withTaskGroup(of: Void.self) { group in
    for _ in 0..<100 {
        group.addTask { await cart.addItem(price: 10) }
    }
}

print(await cart.totalPrice)   // 기대값 1000 → 실제로는 10 근처
```

2장 버전은 모든 작업이 `0`을 읽고 sleep에 들어가므로 결과가 `10` 근처가 된다. 4장 버전으로 바꾸면 항상 `1000`이 나온다. 이 테스트를 단위 테스트로 남겨 두면, 나중에 누가 `await` 위치를 바꿔도 잡아낼 수 있다.

### 실무에서 — Actor 대신 lock을 고를 때

상태 변경이 짧은 동기 연산뿐이고 호출부에 `await`를 퍼뜨리고 싶지 않다면 lock도 선택지다. `Mutex`(Synchronization 프레임워크)는 iOS 18+다. iOS 15 타깃이면 `OSAllocatedUnfairLock`(iOS 16+)이나 `NSLock`을 쓴다. 어느 쪽이든 lock을 잡은 채 `await`할 수 없으므로, "읽기·쓰기 사이에 중단 없음"이 구조적으로 보장된다.

## 핵심 정리

- Actor는 공유 상태에 대한 동시 접근을 직렬화한다.
- Actor는 메서드 전체의 원자성을 보장하지 않는다.
- `await`는 Actor Reentrancy가 발생할 수 있는 지점이다.
- `await` 전후의 공유 상태가 동일하다고 가정하면 안 된다.
- 공유 상태를 읽고 수정하는 구간에는 불필요한 `await`를 두지 않는다.
- 비동기 작업이 필요하다면 가능한 한 먼저 실행하고, 완료 후 최신 공유 상태를 읽는다.
- class 버전에는 Data Race와 Lost Update가 함께 있고, Actor는 Data Race만 없앤다.
- 상태를 바꾸는 actor 메서드를 동기로 두면 컴파일러가 재진입 버그를 막아 준다.
- Lost Update는 Thread Sanitizer에 잡히지 않으므로, 동시 호출을 늘린 테스트로 확인한다.

## 참고 자료

**공식**

- [WWDC21 — Protect mutable state with Swift actors](https://developer.apple.com/videos/play/wwdc2021/10133/) — reentrancy, "상태 변경은 동기 코드에서, await 뒤에는 가정을 다시 확인"
- [Swift — Actor](https://developer.apple.com/documentation/swift/actor)
- [SE-0306 Actors](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0306-actors.md) — Actor reentrancy 절
- [Swift — Task.sleep(nanoseconds:)](https://developer.apple.com/documentation/swift/task/sleep(nanoseconds:))
- [Synchronization — Mutex](https://developer.apple.com/documentation/synchronization/mutex) — iOS 18+
- [Xcode — Diagnosing memory, thread, and crash issues early](https://developer.apple.com/documentation/xcode/diagnosing-memory-thread-and-crash-issues-early) — Thread Sanitizer
- [Apple Developer Forums — Will TSAN or the Swift compiler identify async-await race conditions?](https://developer.apple.com/forums/thread/698539)

**외부**

- [Donny Wals — Actor reentrancy in Swift explained (2024)](https://donnywals.com/actor-reentrancy-in-swift-explained)
- [Antoine van der Lee — Data races vs race conditions](https://course-lessons.avanderlee.com/swift-concurrency/sendable/understanding-data-races-vs-race-conditions-key-differences-explained) — race condition은 Swift Concurrency로 해결되지 않을 수 있음
- [Swift with Majid — Thread safety in Swift with actors (2023)](https://swiftwithmajid.com/2023/09/19/thread-safety-in-swift-with-actors/)
- [Swift Forums — Writing tests to demonstrate actor re-entrance bugs](https://forums.swift.org/t/writing-tests-to-demonstrate-actor-re-entrance-bugs/73969)
