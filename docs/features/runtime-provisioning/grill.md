# Grill 기록 — runtime-provisioning

## 결정 (2026-08-24, 사관장 검토 보고에서 확정)

- D1 이식 범위: fm-worktree-runtime-lib.sh + fm-spawn 포트 페어 플래그(--backend-port/--frontend-port) + fm-worktree-bootstrap.sh + fm-kill-port.sh. codegraph-sync-lib·token-report는 범위 밖(별도 작업).
- D2 방식: 구현물은 구 홈(ai2/firstmate)의 검증된 코드를 **현재 firstmate2 fm-spawn 구조에 맞게 적응** — 무단 복사 금지. 현행 spawn은 herdr 등 백엔드 지원으로 크게 다름.
- D3 계약 유지: 포트 페어는 접수 시 firstmate가 배정(라이브러리·spawn이 스캔해 정하지 않음), 잘못된 값은 조용한 기본값 대신 실패. DB·env 복사는 프로젝트에 실제 존재하는 것만, 없으면 건너뜀.
- D4 테스트: 구 홈의 해당 테스트(fm-worktree-runtime-lib.test.sh, fm-spawn-ports-guard.test.sh, fm-kill-port.test.sh)를 현재 tests/ 관례에 맞게 이식.
- D5 상태 출처 참고: gootte 연동 시 백로그(tasks-axi)가 단일 SoT, id `<parent>-t<NN>` 조인 - 사관장 확정(b안).

## Frontier 상태

비었음 - 위 결정은 2026-08-24 검토 보고와 사관장 승인("승인")으로 닫힘.
