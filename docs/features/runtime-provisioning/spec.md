# Specification — runtime-provisioning

## Goal
crew 작업 사본이 앱을 실제로 실행할 수 있게 한다: 접수 시 배정된 dev 포트 페어, 프로젝트의 gitignored 개발 DB·env 복사, 안전한 포트 기반 정리.

## User-visible behavior
1. fm-spawn이 --backend-port/--frontend-port를 받아 작업 사본에 기록하고, 워크트리가 프로젝트의 dev DB·env 사본을 가진 채 시작된다.
2. 둘이 동시에 떠도 포트가 부딪히지 않는다. 설정이 잘못되면 기본값으로 넘어가지 않고 무엇이 문제인지 말하고 멈춘다.
3. crew는 자기 트리 밖 리스너를 건드리지 않으면서 자기 포트를 정리할 수 있다.

## Scope
- bin/fm-worktree-runtime-lib.sh 이식·적응
- bin/fm-spawn.sh 플래그·메타 연결(--backend-port/--frontend-port, state/<id>.meta 기록)
- bin/fm-worktree-bootstrap.sh 이식·적응
- bin/fm-kill-port.sh 이식
- tests/: 구 홈 3종 테스트를 현재 관례(<subject>.test.sh)로 이식

## Out of scope
- fm-codegraph-sync-lib.sh, fm-token-report.sh (별도 작업)
- 오케스트라 백엔드별(herdr 등) 차이에 대한 신규 설계 - 현행 spawn 구조에 맞추는 적응만

## Decisions
grill.md D1~D5 참조(단일 출처).

## Existing seams / integration points
- 현행 fm-spawn.sh의 플래그 파싱·meta 기록 지점에 붙인다.
- 프로젝트 레이아웃 판정은 파일 존재 여부만 본다(경로 추측 금지).

## Data and migration
state/&lt;id&gt;.meta에 port 필드 추가 - 기존 태스크 메타와 호환(부재 허용).

## Security / authorization
fm-kill-port의 경계 규칙(자기 트리 밖 리스너 거부) 유지 - fleet 전체 pkill 방지 계약 계승.

## Compatibility / rollout
프로젝트가 해당 레이아웃이 아니면 아무 것도 하지 않고 지나간다(구현 주석의 계약 유지). firstmate 자체 워크트리 포함.

## Acceptance criteria
1. 스폰 시 포트 페어가 meta와 워크트리 파일에 기록된다.
2. DB·env가 프로젝트에 있으면 복사, 없으면 조용히 생략된다.
3. 잘못된 포트 값은 spawn 실패로 이어진다.
4. kill-port가 경계 밖 리스너를 거부한다.
5. 이식된 3종 테스트가 현재 tests/ 러너에서 green.
6. shellcheck 통과(bin/fm-lint.sh).

## Verification strategy
위험도 elevated(spawn 안전 경로 변경). 이식 테스트 + fm-lint + 실제 스폰 1회 스모크(후속 검증 작업에서).
