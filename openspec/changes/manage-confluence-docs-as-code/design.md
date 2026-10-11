## Context

動機及範圍見 [proposal.md](proposal.md)，行為要求見 [spec.md](specs/confluence-docs/spec.md)。Repository 基線、影響檔案、API 邊界與完整設計以 [實作計畫](../../../docs/syp171/implementation-plan.md) 第 2～7 節為準；不在此複製一份可能漂移的詳細設計。

## Goals / Non-Goals

本版從開始就讀寫固定 OpenSpec 原生 artifacts，保留 code/docs/spec 版本與 stable IDs。SYP-5 可後續接手同一來源。

本版不定義 SYP-5 全部治理規則，不建置產品通用整合測試平台，也不把未知格式相容性視為已完成。

## Decisions

- 採 OpenSpec v1.13.0、原生 spec-driven v1。需求在 spec，技術方案在 design，執行項在 tasks；JSON 不複製需求與 THEN。
- `OpenSpecSource` 現在交付；原生 validator 加本專案 ID/引用/狀態檢查，再由共用 renderer 與 publish 核心處理。
- 匯入保留原文及 paragraph/section 對應；語意轉換先作候選。格式檢查不能取代 code review、核准或真正 assertions。
- IDs 放在原生 Requirement/Scenario 名稱中，不 fork schema。版本、rename、alias、mapping 與 evidence 的策略見主計畫。
- Publish 不執行 apply/archive，不更改現行規格或產品程式；Git 提交只涵蓋已授權的精確檔案。

## Risks / Trade-offs

- 上游日後可能換格式：保留固定版本、原生文件及 stable IDs，以 gap analysis 遷移；無零成本保證。
- API 草稿競爭與 timeout：維持 preflight、journal、readback 及受控 live 測試；不能只憑 published version 宣稱原子保護。
- 原生 validator 不涵蓋全部專案語意；missing THEN／重複 ID 另由[實作契約](../../../docs/syp171/implementation-plan.md)的來源檢查拒絕。來源測試、正式 gates 與 receiving live 驗收分別綁定其實際證據。

## Migration Plan

初期以候選整理既有頁面，審核後納入 Git。固定來源後發布，保留 page ID。新 Skill 完成 gate/E2E 後才走 deprecated→replacement→removed。回復同時處理來源、adapter、mapping 與相符版本證據，詳細步驟見主計畫。
