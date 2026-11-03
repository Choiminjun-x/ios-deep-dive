# Sendable

> 작성일: 2026-11-03

## 큰 그림

[02](02_swift-concurrency-basics.md)에서 actor와 Task가 "격리 영역(isolation domain)"을 나눈다는 걸 봤다. 이 노트는 그 경계를 넘어가는 값이 안전한지를 다룬다.

```
격리 영역 A (MainActor)          격리 영역 B (actor, 다른 Task)
   값 생성
    → await 호출 / Task 클로저 캡처 / 반환값
       → 경계를 넘을 때 컴파일러가 검사
            ├ Sendable 타입        → 통과 (값 타입, 불변 final class, actor, @MainActor class)
            ├ @Sendable 클로저     → 캡처한 값이 안전한지 검사
            ├ Sendable이 아님      → 넘긴 뒤 원래 쪽에서 안 쓰면 통과 (region-based isolation)
            └ @unchecked Sendable  → 검사 생략, 안전성은 내가 책임
```

Sendable은 컴파일 타임 검사다. 런타임에 lock을 걸어 주지 않는다.

## 1. Sendable이란?

`Sendable`은 서로 다른 동시성 영역(Concurrency Domain) 사이에서 데이터를 안전하게 전달할 수 있음을 나타내는 프로토콜이다.

쉽게 표현하면 다음과 같다.

> 서로 다른 작업 영역 사이에서 데이터를 주고받을 때, 해당 데이터가 안전하게 전달될 수 있는지를 나타내는 개념이다.

서로 다른 Actor 격리 영역이나 동시성 실행 영역 사이에서 데이터가 전달될 때 중요하다.

`Sendable`에는 구현할 메서드나 프로퍼티가 없다. 타입에 "안전하게 넘길 수 있다"는 표시만 붙이고, 그 표시가 맞는지는 컴파일러가 검사한다.

### Sendable이 필요한 이유

여러 Task 또는 Actor에서 동일한 데이터를 공유하면 Data Race가 발생할 수 있다.

특히 참조 타입은 여러 작업 영역에서 동일한 인스턴스를 참조할 수 있기 때문에 주의해야 한다.

```swift
final class User {
    var name = "Minjun"
}
```

여러 Task가 동일한 `User` 인스턴스에 접근하면서 한쪽에서 읽고 다른 쪽에서 수정하면 Data Race가 발생할 수 있다.

Sendable은 이러한 데이터가 동시성 영역 사이에서 안전하게 전달될 수 있는지를 표현하고, 컴파일러가 관련 안전성 규칙을 검사할 수 있도록 한다.

## 2. 타입별 Sendable 준수

| 타입 | Sendable이 되는 조건 | 명시 선언 |
|---|---|---|
| struct · enum | 저장 프로퍼티(enum은 연관값)가 모두 Sendable | public이 아니면 생략 가능 (→ 3절) |
| class | `final` + 모든 저장 프로퍼티가 `let`이고 Sendable + 상위 클래스가 없거나 `NSObject` | 필요 |
| actor | 항상 | 불필요 |
| `@MainActor` 등 global actor 격리 class | 항상 | 불필요 |

### 2.1 Struct (값 타입)

Struct는 값 타입이므로 값을 전달할 때 독립적인 값을 다룰 수 있다는 장점이 있다.

```swift
struct User: Sendable {
    let id: Int
    let name: String
}
```

저장 프로퍼티인 `Int`와 `String`이 모두 Sendable을 준수하므로 `User`도 Sendable을 준수할 수 있다.

단, 모든 프로퍼티가 반드시 `let`이어야 하는 것은 아니다.

```swift
struct User: Sendable {
    var name: String
}
```

이 코드도 Sendable을 준수할 수 있다.

Struct의 저장 프로퍼티들이 모두 Sendable을 준수한다면 `var` 프로퍼티가 있더라도 값 타입의 특성에 따라 안전하게 전달할 수 있다.

### 2.2 Class (참조 타입)

Class는 참조 타입이므로 여러 작업 영역에서 동일한 인스턴스를 공유할 수 있다.

```swift
final class User {
    var name: String
}
```

이처럼 변경 가능한 상태를 가진 일반적인 참조 타입은 동시성 안전성을 보장하기 어렵다.

여기에 `: Sendable`을 붙이면 "stored property 'name' of 'Sendable'-conforming class 'User' is mutable" 진단이 나온다.

반면 불변 참조 타입은 조건을 만족하면 Sendable을 준수할 수 있다.

```swift
final class User: Sendable {
    let id: Int
    let name: String

    init(id: Int, name: String) {
        self.id = id
        self.name = name
    }
}
```

주요 조건은 다음과 같다.

- 상속을 제한하기 위해 `final` 사용
- 저장 프로퍼티가 모두 불변(`let`)
- 저장 프로퍼티의 타입이 Sendable을 준수
- 상위 클래스가 없거나 `NSObject`

class는 조건을 만족해도 자동으로 추론되지 않는다. `: Sendable`을 직접 선언해야 한다.

참고로 `let`으로 참조를 선언했다고 해서 참조 대상까지 불변이 되는 것은 아니다.

```swift
let storage: UserStorage
```

이 경우 `storage`가 가리키는 인스턴스 내부의 상태는 변경될 수 있다. 그래서 "저장 프로퍼티의 타입이 Sendable"이라는 조건이 따로 있다.

### 2.3 Actor

모든 Actor 타입은 암시적으로 Sendable을 준수한다.

```swift
actor UserManager {
    private var users: [String] = []

    func addUser(_ name: String) {
        users.append(name)
    }
}
```

Actor는 참조 타입이지만 Actor Isolation을 통해 내부 상태에 대한 접근을 보호한다.

따라서 내부에 변경 가능한 상태가 있더라도 Actor 자체는 Sendable을 준수할 수 있다.

중요한 점은 Actor 자체가 Sendable이라고 해서 내부의 모든 프로퍼티가 Sendable이어야 하는 것은 아니라는 것이다.

Actor 내부 상태는 Actor Isolation 규칙에 따라 접근하기 때문이다.

### 2.4 @MainActor Class

`@MainActor`처럼 global actor에 격리된 class도 암시적으로 Sendable이다. 메인 액터가 상태 접근을 모두 조율하기 때문이다.

```swift
@MainActor
final class LoginViewModel {
    var isLoading = false   // var여도 됨
}
```

actor와 같은 이유로 `var`이나 Sendable이 아닌 프로퍼티를 가져도 된다. [02](02_swift-concurrency-basics.md)에서 `UserViewModel`을 다른 격리 영역에서 `await viewModel.getUsername()`으로 부를 수 있었던 것도 이 때문이다.

## 3. Struct의 자동 Sendable 준수

모든 Struct에 명시적으로 `Sendable`을 선언해야 하는 것은 아니다.

저장 프로퍼티들이 모두 Sendable을 준수한다면 컴파일러가 암시적으로 Sendable 준수를 추론할 수 있다.

```swift
struct User {
    let id: Int
    let name: String
}
```

`Int`와 `String`은 이미 Sendable을 준수하므로 `User`도 조건을 만족할 수 있다.

반면 다음 코드의 `User`는 Sendable로 추론되지 않는다.

```swift
struct User {
    let id: Int
    let name: String
    let storage: UserStorage
}

class UserStorage {
    var value = ""
}
```

`UserStorage`는 Sendable을 준수하지 않는 가변 참조 타입이다.

따라서 `User`도 자동으로 Sendable을 준수할 수 없다.

선언 자체는 컴파일된다. 이 `User`를 격리 경계 너머로 넘기는 곳에서 진단이 나온다.

핵심은 단순히 `let` 또는 `var`인지가 아니라 저장 프로퍼티의 타입이 Sendable을 준수하는지 여부다.

참고로 암시적 추론은 public이 아닌(그리고 `@usableFromInline`이 아닌) struct·enum, 또는 `@frozen` struct·enum에만 적용된다. public 타입에 자동으로 붙이면, 나중에 Sendable이 아닌 프로퍼티를 추가했을 때 의도하지 않게 API 계약이 깨지기 때문이다. 공개 API에서는 Sendable 준수를 명시적으로 선언한다.

| | 암시적 추론 |
|---|---|
| internal · private struct·enum | 됨 |
| public struct·enum | 안 됨 (`@frozen`이면 됨) |
| class | 안 됨 |

Sendable 준수 선언은 타입을 정의한 파일 안에서 해야 한다. `@unchecked Sendable`은 이 규칙도 적용되지 않는다.

### 실무에서

- **SPM 모듈로 분리한 모델이 갑자기 Sendable이 아니라고 나온다**: 모듈 밖에서 쓰려고 `public`을 붙이는 순간 암시적 추론이 사라진다. 모듈 안에서는 문제가 없다가 앱 타깃에서 넘길 때 진단이 생긴다

## 4. @Sendable Closure

`Sendable`이 타입의 안전한 전달을 표현한다면, `@Sendable`은 클로저의 안전한 전달을 위한 캡처 규칙을 적용한다.

클로저도 다른 Task에 전달되어 실행될 수 있기 때문에 클로저가 캡처하는 값들의 안전성을 확인해야 한다.

함수 타입은 프로토콜을 채택할 수 없어서, 타입에 쓰는 `Sendable` 대신 함수 타입에 붙이는 속성 `@Sendable`로 표현한다.

### 4.1 일반 클로저

```swift
var count = 0

let handler = {
    count += 1
}
```

이 클로저는 외부의 가변 상태인 `count`를 캡처한다.

여러 Task에서 동시에 실행하면 Data Race가 발생할 수 있다.

### 4.2 @Sendable 클로저

```swift
let count = 10

let handler: @Sendable () -> Void = {
    print(count)
}
```

이 코드는 안전하게 전달할 수 있다.

이유는 다음과 같다.

- `count`는 변경할 수 없는 값이다.
- `Int`는 이미 Sendable을 준수한다.

반면 다음 코드는 동시성 안전성 검사에서 진단이 나온다.

```swift
var count = 0

let handler: @Sendable () -> Void = {
    count += 1   // mutation of captured var 'count' in concurrently-executing code
}
```

외부의 가변 상태를 안전하지 않은 방식으로 캡처하고 있기 때문이다.

Swift 5 언어 모드에서는 "this is an error in the Swift 6 language mode"가 붙은 경고로, Swift 6 언어 모드에서는 에러로 나온다.

`@Sendable` 클로저가 받는 규칙은 두 가지다.

- 캡처한 `var`를 읽거나 쓸 수 없다
- Sendable이 아닌 값을 캡처할 수 없다 ("capture of 'x' with non-Sendable type … in a '@Sendable' closure")

따라서 `@Sendable`은 클로저가 동시성 환경에서 안전하게 전달될 수 있도록 캡처하는 값들을 컴파일러가 검사하게 한다.

**주의:** `@Sendable` 자체가 Lock을 제공하거나 Data Race를 직접 방지하는 동기화 도구는 아니다.

### 실무에서

- Swift 6 SDK부터 `Task { }`, `Task.detached`, `TaskGroup.addTask`의 클로저 파라미터는 `@Sendable` 대신 `sending`으로 바뀌었다. 넘긴 뒤 원래 쪽에서 쓰지 않는 값이면 Sendable이 아니어도 캡처할 수 있다 (→ 7절)
- 콜백 API를 감싼 코드에서 "mutation of captured var"가 자주 나온다. 결과를 바깥 `var`에 담는 대신 반환값으로 받도록 바꾸는 게 기본 해결책이다

## 5. @unchecked Sendable

일반적인 가변 참조 타입은 Sendable을 준수하기 어렵다.

하지만 실제로 Lock 등의 동기화 수단을 사용해 내부 상태를 안전하게 보호하고 있다면 개발자가 직접 Sendable 안전성을 보장할 수 있다.

이때 사용하는 것이 `@unchecked Sendable`이다.

```swift
final class Counter: @unchecked Sendable {
    private var count = 0
    private let lock = NSLock()

    func increment() {
        lock.lock()
        defer { lock.unlock() }

        count += 1
    }

    func getCount() -> Int {
        lock.lock()
        defer { lock.unlock() }

        return count
    }
}
```

`@unchecked Sendable`의 의미는 다음과 같다.

- 컴파일러가 일반적인 Sendable 안전성 검증을 수행하지 않는다.
- 개발자가 직접 동시성 안전성을 보장해야 한다.
- 잘못 사용하면 Data Race가 발생할 수 있다.

즉, 컴파일러에게 안전성을 증명하는 대신 개발자가 그 책임을 지겠다고 선언하는 것이다.

### 사용 시 주의사항

- 모든 공유 가변 상태가 적절하게 보호되는지 확인해야 한다.
- Lock을 사용하는 경우 모든 관련 접근이 동일한 동기화 규칙을 따라야 한다.
- 단순히 컴파일 오류를 제거하기 위한 목적으로 사용하면 안 된다.

### 선택 순서

```
가변 상태를 공유해야 한다
 → actor로 만들 수 있나?                     → actor (await 필요)
 → 동기 접근이 꼭 필요하고 iOS 18+인가?       → Mutex로 감싸면 @unchecked 없이 Sendable
 → iOS 15 지원 (실무 기준)                    → lock + @unchecked Sendable, 이유를 주석으로 남김
```

`Mutex`는 iOS 18부터 쓸 수 있다 (로드맵 2단계 실습 항목).

### 실무에서

- **`@unchecked Sendable`을 붙였더니 경고가 다 사라졌다**: 검사가 꺼진 것이지 안전해진 것이 아니다. 로드맵 8~9주차 기록 항목처럼, 남긴 곳과 이유를 따로 적어 둔다
- **크래시가 가끔 `EXC_BAD_ACCESS`로 난다**: `@unchecked Sendable` 타입 중 lock 밖에서 접근하는 경로가 하나라도 있는지 본다. Thread Sanitizer로 런타임 확인이 가능하다

## 6. 실무에서 Sendable을 고려해야 하는 상황

모든 Struct나 모델에 무조건 Sendable을 선언할 필요는 없다.

중요한 것은 서로 다른 작업 영역 사이에서 데이터가 전달되는지 확인하는 것이다.

대표적인 상황은 다음과 같다.

| 상황 | 전달되는 데이터 |
|---|---|
| MainActor → 일반 Actor | 요청 모델 |
| 일반 Actor → MainActor | 응답 모델 |
| 부모 Task → 자식 Task | 작업에 필요한 입력 데이터 |
| 자식 Task → 부모 Task | 작업 결과 |
| 동시성 API의 입력 및 반환 | API에서 전달하거나 반환하는 데이터 |

### 예시 1. MainActor → 일반 Actor

```swift
struct LoginRequest: Sendable {
    let email: String
    let password: String
}

struct User: Sendable {
    let id: Int
    let name: String
}

actor AuthService {
    func login(request: LoginRequest) async throws -> User {
        User(id: 1, name: "Minjun")
    }
}

@MainActor
final class LoginViewModel {
    private let authService = AuthService()

    func login(email: String, password: String) async throws {
        let request = LoginRequest(
            email: email,
            password: password
        )

        let user = try await authService.login(request: request)

        print(user.name)
    }
}
```

실행 흐름:

```text
MainActor
    |
    | LoginRequest 전달
    v
AuthService Actor
    |
    | User 반환
    v
MainActor
```

`LoginRequest`와 `User`가 서로 다른 Actor 격리 영역 사이에서 전달된다.

`authService` 자체도 actor라서 Sendable이므로, `LoginViewModel`이 이를 프로퍼티로 들고 있어도 문제가 없다.

### 예시 2. TaskGroup

```swift
struct ProductID: Sendable {
    let value: Int
}

struct ProductInfo: Sendable {
    let id: Int
    let name: String
}

func fetchProduct(_ id: ProductID) async -> ProductInfo {
    ProductInfo(
        id: id.value,
        name: "Product \(id.value)"
    )
}

func fetchAllProducts() async -> [ProductInfo] {
    await withTaskGroup(
        of: ProductInfo.self,
        returning: [ProductInfo].self
    ) { group in

        for id in 1...3 {
            let productID = ProductID(value: id)

            group.addTask {
                await fetchProduct(productID)
            }
        }

        var products: [ProductInfo] = []

        for await product in group {
            products.append(product)
        }

        return products
    }
}
```

여기서는 부모 Task와 자식 Task 사이에 데이터가 전달된다.

- `ProductID`: 자식 Task로 전달되는 입력 데이터
- `ProductInfo`: 자식 Task에서 반환되는 결과 데이터

이러한 상황에서 Sendable이 중요하다.

`withTaskGroup`의 `of:` 타입(자식 결과 타입)은 Sendable이어야 한다. 자식 작업끼리 동시에 실행되고, 결과가 부모로 넘어가기 때문이다.

단, Task가 다르다는 사실만으로 반드시 서로 다른 Actor 격리 영역인 것은 아니다. `Task { }`는 생성 위치의 실행 문맥을 상속할 수도 있다. 반면 TaskGroup의 자식 작업은 actor 격리를 상속하지 않고 서로 동시에 실행되므로, 전달되는 값의 안전성이 항상 필요하다.

### 실무에서

- **Apple 프레임워크 타입에서 Sendable 경고가 쏟아진다**: 아직 Sendable 표시가 없는 모듈이면 `@preconcurrency import`로 그 모듈 타입의 경고를 낮출 수 있다. 임시 조치이므로 남긴 곳을 기록한다
- **진단이 어디서 나오는지 보면 경계가 보인다**: Strict Concurrency Checking을 complete로 켰을 때 Sendable 경고가 나는 줄이 곧 격리 경계를 넘는 지점이다. Swift 5 모드에서는 경고, Swift 6 모드에서는 에러다

## 7. Sendable이 아니어도 넘길 수 있는 경우

Swift 6 컴파일러부터 region-based isolation(SE-0414)이 들어왔다. Sendable이 아닌 값이라도 넘긴 뒤 원래 쪽에서 다시 쓰지 않는다는 것을 컴파일러가 증명할 수 있으면 경계를 넘길 수 있다.

```swift
class Draft {               // Sendable 아님
    var text = ""
}

@MainActor func show(_ draft: Draft) {}

func makeAndShow() async {
    let draft = Draft()     // 방금 만들어서 아무도 참조하지 않음
    await show(draft)       // OK: MainActor로 넘김
    // draft.text = "x"     // 넘긴 뒤 다시 쓰면 진단
}
```

| | 의미 |
|---|---|
| region-based isolation (SE-0414) | 컴파일러가 값의 흐름을 추적해, 넘긴 뒤 안 쓰면 허용 |
| `sending` (SE-0430) | 파라미터·반환값에 "넘기면 원래 쪽에서 못 쓴다"를 명시 |
| `Sendable` | 어디서 몇 번을 넘겨도 안전한 타입 |

Swift 5 언어 모드에서도 Strict Concurrency Checking을 complete로 켜면 region-based isolation이 함께 켜진다. 실무 프로젝트 설정에서 직접 확인한다. `sending`과 region은 로드맵 4~5주차에서 자세히 다룬다.

## 8. Sendable과 Actor Isolation의 관계

두 개념은 동시성 안전성을 다루지만 역할이 다르다.

| 개념 | 역할 |
|---|---|
| Sendable | 데이터가 서로 다른 동시성 영역 사이에서 안전하게 전달될 수 있는지 표현 |
| Actor Isolation | Actor가 보호하는 내부 상태에 대한 접근을 관리 |
| Actor Reentrancy | Actor 내부에서 await로 중단된 동안 다른 작업이 실행될 수 있는 특성 |
| @Sendable | 클로저의 안전한 전달을 위한 캡처 규칙 적용 |
| @unchecked Sendable | 개발자가 직접 안전성을 보장하겠다고 선언 |

핵심은 다음과 같다.

- Actor Isolation은 공유 상태에 대한 동시 접근을 제어한다.
- Sendable은 서로 다른 동시성 영역 사이의 데이터 전달 안전성을 다룬다.
- Sendable을 준수한다고 모든 비즈니스 로직의 논리적 경쟁 상태까지 해결되는 것은 아니다.

두 개념은 서로 맞물린다. actor와 `@MainActor` class는 격리로 상태를 보호하기 때문에 그 자체가 Sendable이 된다. 상태는 격리로 지키고, 경계를 넘는 값은 Sendable로 지킨다.

## 핵심 정리

1. Sendable은 서로 다른 동시성 영역 사이에서 안전하게 전달할 수 있는 타입임을 나타낸다.
2. Struct는 저장 프로퍼티들이 Sendable을 준수한다면 Sendable을 준수할 수 있다.
3. Struct의 모든 프로퍼티가 반드시 let일 필요는 없다.
4. 일반적인 가변 Class는 동일한 인스턴스를 여러 작업 영역에서 공유할 수 있어 주의가 필요하다.
5. Actor는 Actor Isolation으로 내부 상태를 보호하므로 암시적으로 Sendable을 준수한다. `@MainActor` class도 같다.
6. @Sendable은 클로저가 캡처하는 값들의 동시성 안전성을 검사하도록 한다.
7. @unchecked Sendable은 컴파일러 검증을 생략하고 개발자가 직접 안전성을 책임지는 선언이다.
8. 모든 모델에 무조건 Sendable을 선언할 필요는 없으며, 서로 다른 동시성 영역 사이에서 데이터가 전달되는 상황을 중심으로 검토한다.
9. 암시적 추론은 public이 아닌 struct·enum에만 적용된다. public 타입과 class는 직접 선언한다.
10. Sendable이 아닌 값도 넘긴 뒤 다시 쓰지 않으면 경계를 넘길 수 있다 (region-based isolation).

**가장 중요한 개념:**

Sendable은 단순히 값 타입인지 참조 타입인지 구분하는 개념이 아니다.

서로 다른 동시성 영역에 데이터를 전달했을 때도 데이터의 안전성이 유지될 수 있는지를 표현하는 개념이다.

## 셀프 체크

**Q1. 모든 프로퍼티가 `let`인 `final class`는 자동으로 Sendable인가?**

- 아니다. class는 암시적 추론이 없어서 `: Sendable`을 직접 선언해야 한다. 상위 클래스가 없거나 `NSObject`여야 하고, 프로퍼티 타입도 Sendable이어야 한다

**Q2. `var` 프로퍼티가 있는 struct는 Sendable이 될 수 있나? class와 무엇이 다른가?**

- 된다. struct는 넘길 때 복사되어 각자 독립된 값을 갖는다. class는 같은 인스턴스를 공유하므로 `var`가 있으면 안 된다

**Q3. 앱 타깃에서는 문제없던 모델 struct가 SPM 모듈로 옮긴 뒤 Sendable 진단이 난다. 왜인가?**

- `public`이 되면서 암시적 Sendable 추론이 사라졌다. public 타입에는 명시적으로 선언해야 한다

**Q4. `@MainActor` class에 `var` 프로퍼티가 있는데 왜 Sendable인가?**

- 모든 접근이 메인 액터를 거치도록 격리되어 있기 때문이다. actor가 Sendable인 것과 같은 이유다

**Q5. `@unchecked Sendable`과 `Sendable`의 차이는?**

- `Sendable`은 컴파일러가 조건을 검사한다. `@unchecked Sendable`은 검사를 끄고 안전성을 개발자가 책임진다. lock 등으로 내부를 실제로 보호할 때만 쓴다

**Q6. Sendable이 아닌 class 인스턴스를 MainActor 함수에 넘겼는데 경고가 없다. 왜인가?**

- region-based isolation 때문이다. 방금 만든 값이고 넘긴 뒤 다시 쓰지 않으면 컴파일러가 안전하다고 증명할 수 있다

## 참고 자료

**공식**

- [Swift — Sendable](https://developer.apple.com/documentation/swift/sendable) — 타입별 조건, 암시적 준수 범위, `@MainActor` class
- [SE-0302 Sendable and @Sendable closures](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0302-concurrent-value-and-concurrent-closures.md)
- [Swift Forums — [Accepted] SE-0302 (Doug Gregor 답변)](https://forums.swift.org/t/accepted-se-0302-sendable-and-sendable-closures/45786) — public이 아니거나 frozen인 타입만 추론
- [SE-0414 Region based Isolation](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0414-region-based-isolation.md)
- [SE-0430 sending parameter and result values](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0430-transferring-parameters-and-results.md)
- [WWDC21 — Protect mutable state with Swift actors](https://developer.apple.com/videos/play/wwdc2021/10133/) — Sendable 타입 종류
- [WWDC22 — Eliminate data races using Swift Concurrency](https://developer.apple.com/videos/play/wwdc2022/110351)
- [swiftlang/swift PR #83617 (2025-08)](https://github.com/swiftlang/swift/pull/83617) — complete 검사에서 RegionBasedIsolation이 추론됨

**외부**

- [Swift Forums — New task-creation APIs (2024)](https://forums.swift.org/t/new-task-creation-apis/74322) — Swift 6에서 Task 생성 API가 `sending`으로 바뀜
- [Swift Forums — Non-Sendable value type can be mutated concurrently (2025)](https://forums.swift.org/t/non-sendable-value-type-can-be-mutated-concurrently/77459) — Swift 5 모드 경고 문구 예시
- [Swift Forums — Why public non-frozen enums aren't implicitly Sendable (2025)](https://forums.swift.org/t/understanding-why-public-non-frozen-enums-aren-t-implicitly-sendable-even-though-no-one-else-can-add-cases/80905)
- [Matt Massicotte — SE-0414 Region based Isolation (2024-06)](https://massicotte.org/concurrency-swift-6-se-0414/)
