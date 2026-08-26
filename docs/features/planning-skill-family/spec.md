# Specification — planning-skill-family

## Goal
단일 task-planning 스킬을 Matt Pocock 원본(grilling·prototype·domain-modeling·wayfinder·to-spec·to-tickets) 대조 기반의 3종 패밀리로 분리·심화한다: task-grill(요구사항 심문), task-design(디자인·프로토타입), task-planning(오케스트레이터).

## User-visible behavior (firstmate 운용자 관점)
1. non-Simple 작업 접수 시 firstmate가 frontier 라운드 프로토콜로 사관장에게 번호 붙은 질문과 추천답안을 제시하고, 답변이 채워지기 전까지 다음 단계에 진행하지 않는다.
2. 디자인 질문이 있으면 Lavish 리뷰 화면(논리 시연 또는 UI 변형 비교)으로 프로토타입을 올려 사관장 응답을 받는다.
3. 계획 승인 그래프에는 항상 말단 T-review 검수 티켓이 포함되고, 경미한 피드백은 즉시 보완, 중대한 것은 재귀로 새 계획이 된다.
4. 계획 산출물은 projects/&lt;project&gt;/docs/features/&lt;slug&gt;/ 아래 grill.md, design/(해당시), spec.md, tickets/로 축적된다.

## Scope
- .agents/skills/task-grill/SKILL.md 신규
- .agents/skills/task-design/SKILL.md 신규
- .agents/skills/task-planning/SKILL.md 개편
- AGENTS.md 라우팅 최소 갱신(§7 트리거 문장, §13 등재 2줄) + docs/task-planning.md 패밀리 구조 반영

## Out of scope
- implement/code-review 대응물 신규 작성(기존 fm-brief/spawn/no-mistakes 소유 유지)
- 이슈트래커 연동, setup 스킬, triage 대응물(tasks-axi와 기존 §7 라우팅이 소유)
- bin/ 스크립트 변경

## Decisions
- D1~D7 확정: docs/features/planning-skill-family/grill.md 참조(단일 출처).
- 용어 충돌 시 프로젝트 AGENTS.md 'Domain terms' 섹션과 대조하고, 착륙 시 승격한다.
- 원본 방법론은 Firstmate-native 재작성 원칙 유지(Wayfinder implement 미도입 등 handoff §25 계승).

## Existing seams / integration points
- 기존 복잡도 게이트(Simple/Planned/Wayfinder-planned)와 §7 트리거 문장을 패밀리 진입점으로 재사용.
- HITL=captain hold, research=--scout, prototype=task-design 매핑으로 기존 기제 재사용, 중복 구현 금지.
- 티켓 실행 인계는 기존 fm-brief.sh → fm-spawn.sh → 감독 체계 그대로.

## Data and migration
기존 단일 SKILL.md 내용은 T03에서 패밀리로 흡수 후 중복 제거. 진행 중인 계획문서 관례(docs/features/)는 유지.

## Security / authorization
없음 - 문서·스킬 변경만 포함, 런타임 동작 변경 없음.

## Compatibility / rollout
스킬은 로드 시점에만 비용을 지불하므로 기존 세션 영향 없음. AGENTS.md 변경은 트리거 한 줄 수준으로 최소화(size discipline).

## Acceptance criteria
1. 세 스킬 파일이 존재하고 각자 단일 트리거 조건이 선언되어 있다.
2. task-grill에 rounds/frontier 프로토콜과 하드 게이트가 명문화되어 있다.
3. task-design에 LOGIC/UI 분기와 Lavish 계약, 보존 정책이 명문화되어 있다.
4. task-planning에 fog 졸업, seam 확인, 티켓 퀴즈, expand-contract, T-review 의무, 재귀 게이트가 명문화되어 있다.
5. AGENTS.md는 트리거 포인터만 추가하고 상세를 복제하지 않는다(one-owner rule).
6. fm-doc-audience-check.sh 통과.

## Verification strategy
위험도 elevated(공유 명령 계약 변경). 각 수용기준의 문자열 존재 확인 + fm-doc-audience-check + fm-lint(해당시) + diff 리뷰. 이후 실제 medium feature 하나로 end-to-end 검증(handoff §27.10, 별도 작업).

## T-review
말단 검수 티켓 필수 - 사관장이 승인된 수용기준대로 검수, 경미는 즉시 보완, 중대는 재귀.
