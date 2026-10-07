# 빌드 심화 학습 순서

> 다 공부하면 이 파일은 지운다

## 1. 심볼과 링킹

- `nm`으로 `.o`의 심볼 보기 (U / T)
- 링커가 하는 두 가지: 심볼 해결, 재배치
- `Undefined symbol` / `duplicate symbol` 에러 원리
- 정적 vs 동적: 앱 크기, Pre-main 시간, 중복 포함 문제
- Dead Code Stripping, `-ObjC`
- 체크: Undefined symbol은 왜 컴파일이 아니라 링크에서 나나? / 같은 정적 라이브러리를 앱과 동적 프레임워크가 둘 다 넣으면?

## 2. SPM과 의존성 빌드

- `Package.swift`, `Package.resolved`
- 패키지 해결은 빌드 앞 단계
- 패키지가 어떤 형태로 빌드·링크되나 (타입 미지정 시 Xcode가 결정)
- binary target = `.xcframework`
- workspace 없이 되는 이유
- 체크: `Package.resolved`는 왜 git에 올리나? / CocoaPods는 xcconfig를 주입하는데 SPM은?

## 3. Swift 컴파일러 내부와 모듈

- Parse → 타입 체크 → SIL → LLVM IR → 기계어
- `.swiftmodule`: `import`가 실제로 읽는 것
- 증분 빌드 vs WMO, `-Onone` / `-O`
- Build Timeline으로 느린 파일 찾기
- 체크: Debug는 왜 빌드가 빠르고 실행이 느린가? / 파일 하나 고쳤는데 왜 여러 파일이 다시 컴파일되나?

## 4. Archive와 배포

- Build vs Archive (Archive = Release)
- dSYM, Debug Information Format, 크래시 심볼리케이션
- 업로드 후 Apple이 하는 일: App Thinning, FairPlay 암호화, 재서명
- 체크: 크래시 로그에 주소만 찍히는 이유와 dSYM의 역할? / App Store 앱은 왜 내 인증서가 만료돼도 켜지나?

## 덤: 코드 서명 노트 보강

- 인증서 체인: Apple Root CA → WWDR 중간 인증서 → 내 인증서
