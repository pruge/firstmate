# Grill 기록 — planning-skill-family

## Design tree snapshot (확정)

- D1 패밀리 구성 → 3종 분리 확정 (task-grill / task-design / task-planning 오케스트레이터)
  - D1.1 implement·code-review → 제외 확정 (기존 기제 소유)
  - D1.2 참조문서 방식(A안) → 기각, 스킬 패밀리(B안) 확정
- D2 task-design 필수 범위 → (a) non-Simple 전부, grill이 디자인 질문 존재를 판정
- D3 프로토타입 보존 → (a) docs/features/&lt;slug&gt;/design/ 미커밋 운용문서
- D4 grill 강제력 → (a) 하드 게이트: frontier 소진 + 사관장 확인 없으면 다음 단계 금지
- D5 용어집 위치 → (a) 프로젝트 AGENTS.md 'Domain terms' 섹션, 착륙 시 승격
- D6 재귀 → 복잡도 게이트 재판정(dispatch 직전마다) + fog 졸업 + 식별자 중첩(&lt;parent&gt;-t&lt;NN&gt;), 크기 상한 = 티켓당 컨텍스트 윈도우 1개
- D7 검수 → feature별 말단 T-review 티켓 의무화: 경미=즉시 보완+문서갱신, 중대=재귀 진입, 통과 후 착륙 승인(merge authority는 사관장 유지)

## Frontier 상태

비었음 - 2026-08-24 사관장 확정으로 공유 이해 도달. 원본 출처: mattpocock/skills (MIT), 참조 클론 보관.
