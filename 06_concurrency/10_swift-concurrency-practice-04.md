# Swift Concurrency 실전 4 — TaskGroup과 동시 실행 개수 제한

> 작성일: 2026-11-10

## 1. 문제 상황

상품 목록 화면에서 여러 카테고리의 상품을 조회해야 한다고 가정한다.

```swift
let categories = [
    "전자기기",
    "의류",
    "식품",
    "도서",
    "가구"
]
```

각 카테고리마다 별도의 API 요청이 필요하다.

요구사항은 다음과 같다.

- 카테고리 개수는 실행 시점에 결정된다.
- 모든 카테고리 API를 동시에 실행하고 싶다.
- 각 API의 결과를 수집해야 한다.
- 화면을 이탈하면 전체 작업을 취소해야 한다.
- 동시에 실행되는 API 요청의 개수를 제한하고 싶다.

### 실전 3과 달라진 점

| 구분 | 실전 3 | 실전 4 |
|---|---|---|
| 동시 작업 개수 | 2개 고정 (상품, 추천) | 실행 시점에 결정 (카테고리 수) |
| 도구 | `async let` | `TaskGroup` |
| 새 주제 | 부분 성공 | 동시 실행 개수 제한 |

## 2. async let과 TaskGroup의 차이

### async let

실행할 작업의 개수와 종류가 미리 정해져 있는 경우 적합하다.

```swift
async let products = API.fetchProducts()
async let recommendations = API.fetchRecommendations()

let result = try await (products, recommendations)
```

특징:

- 독립적인 비동기 작업을 동시에 시작한다.
- 각 작업의 결과를 개별적으로 await할 수 있다.
- 고정된 개수의 작업을 관리하기 편리하다.
- Structured Concurrency에 속한다.

### TaskGroup

작업 개수가 동적으로 결정되거나 반복문 등을 통해 여러 작업을 추가해야 하는 경우 적합하다.

```swift
await withTaskGroup(of: [Product].self) { group in
    for category in categories {
        group.addTask {
            await API.fetchProducts(category: category)
        }
    }

    for await result in group {
        // 결과 수집
    }
}
```

특징:

- 실행 중 새로운 작업을 추가할 수 있다.
- `addTask`로 자식 Task를 등록한다.
- `for await`으로 완료된 작업의 결과를 수집한다.
- Structured Concurrency에 속한다.

### 비교

| 구분 | async let | TaskGroup |
|---|---|---|
| 작업 개수 | 일반적으로 고정적 | 동적으로 추가 가능 |
| 작업 생성 | 선언 시 생성 | `addTask`로 추가 |
| 결과 수집 | 각 작업을 await | `for await`으로 순회 |
| 결과 타입 | 작업마다 달라도 됨 | 모든 자식이 같은 타입 |
| 결과 순서 | 내가 await한 순서 | 완료된 순서 |
| 기다리지 않고 스코프를 벗어나면 | 남은 작업 취소 후 대기 | 남은 작업 대기 (취소하지 않음) |
| 적합한 상황 | 독립적인 소수 작업 | 동적 개수의 작업 |

`async let`도 반복문에서 사용할 수 있는 상황이 있지만, 동적 작업을 관리할 때는 TaskGroup이 더 자연스럽다.

### 버전 차이

| 항목 | 버전 |
|---|---|
| `withTaskGroup`, `withThrowingTaskGroup` | Swift 5.5, iOS 13+ |
| `withDiscardingTaskGroup` (결과를 모으지 않는 그룹) | Swift 5.9, iOS 17+ |
| `withTaskGroup { }`에서 `of:` 생략 (자식 결과 타입 추론, SE-0442) | Swift 6.1+ 컴파일러 |

`of:` 생략은 컴파일러 기능이라 Xcode 26.4에서는 Swift 5 언어 모드에서도 쓸 수 있다. 다만 이 노트는 명시적으로 `of:`를 적는다.

## 3. TaskGroup의 기본 구조

```swift
await withTaskGroup(of: [Product].self) { group in

    // 1. 자식 Task 등록
    group.addTask {
        await API.fetchProducts(category: "전자기기")
    }

    // 2. 완료된 작업의 결과 수집
    for await result in group {
        print(result)
    }
}
```

```
withTaskGroup 시작
 → addTask: 자식 Task 생성 → 바로 실행 시작 (부모와 동시에)
 → for await result in group: 완료된 자식부터 하나씩 꺼냄
 → 모든 자식이 끝나면 루프 종료
 → withTaskGroup 반환 (남은 자식이 있으면 끝날 때까지 기다린 뒤 반환)
```

### 주요 구성 요소

| 구성 요소 | 역할 |
|---|---|
| `withTaskGroup` | 자식 Task 그룹 생성 및 관리 |
| `group.addTask` | 새로운 자식 Task 등록 |
| `for await` | 완료된 작업의 결과 수집 |
| `group.next()` | 완료된 작업 하나를 꺼냄 (`for await`의 한 번 분) |
| `group.addTaskUnlessCancelled` | 그룹이 취소되지 않았을 때만 등록, 성공 여부를 `Bool`로 반환 |
| `group.cancelAll()` | 남은 자식 전체에 취소 요청 |

### 결과 수집 순서

TaskGroup은 작업을 추가한 순서가 아니라 **완료된 순서대로 결과를 전달한다.**

예를 들어 작업 1, 2, 3을 등록했더라도 작업 3이 가장 먼저 완료되면 작업 3의 결과가 먼저 전달된다.

실전 3의 `try await (a, b)`가 왼쪽부터 기다리는 것과 반대다. 그래서 "먼저 끝난 쪽부터 처리"나 "하나 실패하면 바로 나머지 취소"가 필요할 때 TaskGroup을 쓴다.

### 실무에서 — 어떤 결과가 어떤 카테고리인지 잃어버린다

완료 순서로 오기 때문에 `[[Product]]`만 모으면 몇 번째 배열이 어느 카테고리인지 알 수 없다.

증상: 카테고리 섹션에 상품이 엉뚱하게 섞여 보이고, 새로고침할 때마다 순서가 바뀐다.

자식 결과에 식별자를 같이 담는다.

```swift
await withTaskGroup(of: (String, [Product]).self) { group in
    for category in categories {
        group.addTask {
            (category, await API.fetchProducts(category: category))
        }
    }

    var productsByCategory: [String: [Product]] = [:]
    for await (category, products) in group {
        productsByCategory[category] = products
    }
    return productsByCategory
}
```

원래 순서가 필요하면 인덱스를 담고 나중에 정렬한다.

## 4. 동시 실행 개수 제한

카테고리가 100개라면 다음과 같이 모든 작업을 등록할 수도 있다.

```swift
await withTaskGroup(of: [Product].self) { group in
    for category in categories {
        group.addTask {
            await API.fetchProducts(category: category)
        }
    }
}
```

하지만 작업을 한꺼번에 많이 실행하면 다음과 같은 문제가 발생할 수 있다.

- 네트워크 연결 및 소켓 사용량 증가
- 서버에 순간적으로 많은 요청 집중
- 응답 데이터 보관에 따른 메모리 사용량 증가
- CPU 및 디코딩 작업 증가
- 서버의 Rate Limit에 걸릴 가능성

**TaskGroup은 동시 실행 개수를 자동으로 제한하지 않는다.**

따라서 작업을 추가하는 시점을 직접 제어해야 한다.

자식 Task 100개가 생겨도 스레드가 100개 생기지는 않는다. 자식 Task는 CPU 코어 수만큼의 스레드 풀(cooperative thread pool)에서 나눠 실행된다. 하지만 await 중인 네트워크 요청은 스레드를 쓰지 않으므로, 100개 요청이 실제로 동시에 나간다. 스레드 수가 제한된다고 요청 수가 제한되는 건 아니다.

## 5. 제한된 동시성(Bounded Concurrency)

최대 동시 실행 개수를 5개로 제한한다고 가정한다.

동작 방식:

1. 최초 5개 작업 등록
2. 등록된 작업들이 실행
3. 작업 하나가 완료되면 결과 수집
4. 다음 작업 하나를 추가
5. 모든 작업이 끝날 때까지 반복

이 구조를 활용하면 동시에 실행되는 작업의 개수를 제한할 수 있다.

### 묶음(batch) 방식과 비교

5개씩 끊어서 실행하는 방법도 있지만, 묶음 안에서 가장 느린 작업이 다음 묶음을 막는다.

```
묶음 방식 (5개씩, 끝날 때까지 기다린 뒤 다음 5개)
  [1 2 3 4 5] → 5개 모두 끝나야 → [6 7 8 9 10]
  느린 작업 하나 때문에 나머지 4칸이 놀고 있음

슬라이딩 방식 (이 노트의 구현)
  [1 2 3 4 5] → 하나 끝나면 바로 6 추가 → 항상 5칸이 차 있음
```

### 전체 구현

```swift
func fetchAllProducts(
    categories: [String],
    maxConcurrentTasks: Int = 5
) async -> [[Product]] {

    await withTaskGroup(of: [Product].self) { group in

        var results: [[Product]] = []
        var nextIndex = 0

        // 1. 최초 작업 등록
        let initialCount = min(maxConcurrentTasks, categories.count)

        for _ in 0..<initialCount {
            let category = categories[nextIndex]
            nextIndex += 1

            group.addTask {
                await API.fetchProducts(category: category)
            }
        }

        // 2. 작업 완료 시 결과 수집 및 다음 작업 등록
        for await result in group {
            results.append(result)

            if nextIndex < categories.count {
                let category = categories[nextIndex]
                nextIndex += 1

                group.addTask {
                    await API.fetchProducts(category: category)
                }
            }
        }

        return results
    }
}
```

`for await` 루프를 도는 동안 그룹에 작업을 추가해도 된다. 루프는 "그룹이 빌 때까지" 계속되므로 새로 추가한 작업도 순회 대상이 된다.

### 핵심 코드 분석

**① 최초 작업 등록**

```swift
let initialCount = min(maxConcurrentTasks, categories.count)

for _ in 0..<initialCount {
    let category = categories[nextIndex]
    nextIndex += 1

    group.addTask {
        await API.fetchProducts(category: category)
    }
}
```

최초 작업 개수를 최대 동시 실행 개수와 카테고리 개수 중 작은 값으로 결정한다.

카테고리가 2개인데 최대 동시 실행 개수가 5개라면 2개만 등록한다.

`let category = categories[nextIndex]`로 값을 먼저 꺼낸 뒤 클로저에서 캡처한다. `nextIndex`는 그룹 본문(부모 쪽)의 `var`라서 자식 Task 클로저에서 직접 읽으면 동시성 오류가 난다. 자식에게는 `Sendable`한 값(`String`)만 넘긴다.

**② 완료된 작업의 결과 수집**

```swift
for await result in group {
    results.append(result)
}
```

자식 Task가 완료될 때마다 결과를 수집한다.

아직 완료되지 않은 작업이 있다면 다음 결과가 나올 때까지 기다린다.

`results`와 `nextIndex`는 그룹 본문에서만 읽고 쓴다. 자식 Task는 값을 반환할 뿐 이 변수들을 건드리지 않으므로 데이터 경쟁이 없다.

**③ 다음 작업 등록**

```swift
if nextIndex < categories.count {
    let category = categories[nextIndex]
    nextIndex += 1

    group.addTask {
        await API.fetchProducts(category: category)
    }
}
```

새로운 작업을 등록할 카테고리가 남아 있다면 다음 작업을 추가한다.

카테고리가 남아 있지 않다면 아무 작업도 추가하지 않고 기존 작업들의 완료를 기다린다.

## 6. 동시 실행 개수 제한의 실행 흐름

카테고리 10개, 최대 동시 실행 개수 3개를 가정한다.

| 시점 | 완료 직후 실행 중인 작업 | 동작 |
|---|---|---|
| 최초 | 1, 2, 3 | 최초 3개 등록 |
| 작업 2 완료 | 1, 3 | 결과 수집 후 4 등록 |
| 작업 1 완료 | 3, 4 | 결과 수집 후 5 등록 |
| 작업 5 완료 | 3, 4 | 결과 수집 후 6 등록 |
| 반복 | 최대 3개 | 완료될 때마다 다음 작업 등록 |
| 마지막 | 10 완료 | 전체 그룹 종료 |

항상 최대 3개의 작업만 실행되도록 관리한다.

```
시간 →
칸 1: [ 1 ──────][ 5 ─][ 6 ───── ] ...
칸 2: [ 2 ──][ 4 ─────────── ] ...
칸 3: [ 3 ───────────────] ...
```

### 실무에서

- 디버깅 포인트: 자식 Task 시작과 끝에 로그를 찍고 "현재 실행 중인 개수"를 출력한다. 이 값이 `maxConcurrentTasks`를 넘지 않아야 한다. 카운터는 그룹 본문에서 증감한다
- Instruments의 Swift Concurrency 템플릿(Swift Tasks)에서 동시에 살아 있는 Task 수를 볼 수 있다
- `maxConcurrentTasks`가 0이면 아무 작업도 등록되지 않고 빈 배열이 반환된다. 외부에서 받는 값이면 `max(1, …)`로 막는다

## 7. TaskGroup과 취소

TaskGroup은 Structured Concurrency이므로 부모 Task와 자식 Task의 생명주기가 연결된다.

- 부모 Task가 취소되면 자식 Task에도 취소가 전파된다.
- 그룹의 작업이 완료되기 전에 그룹 scope를 벗어날 수 없다.
- 자식 Task의 취소는 협력적 취소 방식이다.

따라서 실제 API가 취소에 협력하는지도 확인해야 한다.

```
화면 이탈 → .task 취소
 → fetchAllProducts를 실행 중인 Task 취소
 → 그룹 취소 → 실행 중인 자식 전체에 취소 전파
 → 자식들이 취소에 반응해 끝남
 → withTaskGroup은 모든 자식이 끝난 뒤에 반환
```

### 그룹이 끝나는 방식

| 상황 | 남은 자식 |
|---|---|
| 본문이 정상 반환 | 취소하지 않고 끝날 때까지 기다림 |
| 본문이 throw (`withThrowingTaskGroup`) | 취소한 뒤 끝날 때까지 기다림 |
| 부모 Task 취소 | 취소 전파, 그룹은 계속 결과를 받으며 끝까지 기다림 |
| `group.cancelAll()` | 취소 요청 후, 본문이 끝날 때 기다림 |

"먼저 하나만 받으면 된다"처럼 일부 결과만 필요하면, 반환하기 전에 `group.cancelAll()`을 직접 호출해야 한다. 그러지 않으면 나머지가 다 끝날 때까지 반환되지 않는다.

### 실무에서 — 취소된 뒤에도 남은 카테고리를 계속 등록한다

5장 구현은 그룹이 취소된 뒤에도 `for await`가 결과를 계속 받는다. 그 결과마다 다음 카테고리를 `addTask`로 등록한다.

취소된 그룹에 `addTask`로 추가한 작업은 생성되자마자 취소 상태다. 그래서 금방 끝나기는 하지만, 카테고리 100개라면 남은 수십 개의 Task를 만들었다가 버리게 된다. API 구현이 취소를 확인하지 않으면 실제 요청까지 나간다.

`addTaskUnlessCancelled`를 쓰면 취소된 뒤에는 새 작업을 만들지 않는다.

```swift
if nextIndex < categories.count {
    let category = categories[nextIndex]
    nextIndex += 1

    group.addTaskUnlessCancelled {
        await API.fetchProducts(category: category)
    }
}
```

또는 루프 맨 앞에서 `if Task.isCancelled { break }`로 수집을 멈출 수도 있다. 이때도 이미 실행 중인 자식은 그룹이 끝날 때까지 기다린다.

### 실무에서 — 실제 API는 throw한다

이 노트의 `API.fetchProducts(category:)`는 throw하지 않는다고 가정했다. 실제 네트워크 API라면 throw하므로 둘 중 하나를 고른다.

| 정책 | 방법 |
|---|---|
| 하나라도 실패하면 전체 실패 | `withThrowingTaskGroup` + `for try await`. 첫 오류에서 본문이 throw하면 남은 자식이 취소됨 |
| 실패한 카테고리만 빼고 표시 | `withTaskGroup(of: (String, Result<[Product], Error>).self)`. 실전 3의 부분 성공과 같은 방식 |

## 핵심 정리

1. `async let`은 고정된 개수의 독립 작업을 관리할 때 적합하다.
2. `TaskGroup`은 동적으로 작업을 추가하고 관리할 때 적합하다.
3. `group.addTask`로 새로운 자식 Task를 등록한다.
4. `for await`으로 완료된 작업의 결과를 수집한다.
5. TaskGroup은 작업을 추가한 순서가 아니라 완료된 순서로 결과를 전달한다.
6. TaskGroup은 동시 실행 개수를 자동으로 제한하지 않는다.
7. 작업 추가 시점을 제어하면 제한된 동시성을 구현할 수 있다.
8. 부모 Task의 취소는 자식 Task에 전파되지만, 취소는 협력적으로 처리된다.
9. 완료 순서로 결과가 오므로, 자식 결과에 식별자(카테고리, 인덱스)를 함께 담아야 한다.
10. 그룹 본문이 정상 반환하면 남은 자식은 취소되지 않고 끝까지 기다린다. 일부 결과만 필요하면 `cancelAll()`을 직접 호출한다.
11. 취소된 그룹에 `addTask`한 작업은 생성 즉시 취소된다. 취소 후 새 작업을 만들지 않으려면 `addTaskUnlessCancelled`를 쓴다.
12. 자식 Task 클로저에는 그룹 본문의 `var`가 아니라 미리 꺼낸 `Sendable` 값을 넘긴다.

## 참고 자료

**공식**

- [Swift — TaskGroup](https://developer.apple.com/documentation/swift/taskgroup) — 그룹은 항상 모든 자식을 기다림, cancelAll은 실행을 강제로 끊지 않음
- [Swift — withTaskGroup(of:returning:isolation:body:)](https://developer.apple.com/documentation/swift/withtaskgroup(of:returning:isolation:body:))
- [Swift — TaskGroup.addTaskUnlessCancelled(priority:operation:)](https://developer.apple.com/documentation/swift/taskgroup/addtaskunlesscancelled(priority:operation:))
- [Swift — ThrowingTaskGroup](https://developer.apple.com/documentation/swift/throwingtaskgroup)
- [Swift — DiscardingTaskGroup](https://developer.apple.com/documentation/swift/discardingtaskgroup) — iOS 17+
- [WWDC21 — Explore structured concurrency in Swift](https://developer.apple.com/videos/play/wwdc2021/10134) — task group, 취소 전파
- [WWDC21 — Swift concurrency: Behind the scenes](https://developer.apple.com/videos/play/wwdc2021/10254) — cooperative thread pool
- [SE-0304 Structured concurrency](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0304-structured-concurrency.md) — 스코프 탈출 시 자식 대기, throw 시 취소
- [SE-0442 Allow TaskGroup's ChildTaskResult Type To Be Inferred](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0442-allow-taskgroup-childtaskresult-type-to-be-inferred.md) — Swift 6.1
- [Swift Forums — SE-0304 구현과 제안서 차이 (Apple 엔지니어 답변)](https://forums.swift.org/t/accepted-with-modifications-se-0304-structured-concurrency/51850/9) — 정상 반환 시 남은 자식은 기다리고 오류는 버림

**외부**

- [Hacking with Swift — How to cancel a task group](https://www.hackingwithswift.com/books/concurrency/how-to-cancel-a-task-group) — addTask는 취소된 그룹에도 추가됨, addTaskUnlessCancelled
- [Swift Forums — What's the expected behavior of TaskGroup.next() on cancellation?](https://forums.swift.org/t/whats-the-expected-behavior-of-throwing-taskgroup-next-on-cancellation/62211) — 부모 취소 후에도 그룹이 결과를 계속 내보냄
- [Swift Forums — Identifying child tasks within a TaskGroup](https://forums.swift.org/t/identifying-child-tasks-within-a-taskgroup/67913) — 결과에 식별자 담기
- [Antoine van der Lee — Task groups](https://course-lessons.avanderlee.com/swift-concurrency/tasks/task-groups)
