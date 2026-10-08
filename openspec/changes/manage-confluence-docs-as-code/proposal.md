## Why

Confluence 文件需進入 Git 並與 code commit 保持一致。若先匯成自由格式文件、等 SYP-5 定案後才整理需求與測試情境，會增加重寫成本；SYP-171 因此現在就採用固定版本 OpenSpec 原生 SDD。

## What Changes

- 新增 Confluence 擷取候選、來源追溯及原生 SDD 整理流程。
- 從同一份 spec 驅動文件投影、開發及測試案例對應。
- 建立精確 code/docs/spec 綁定、預覽、衝突保護、發布及回讀。
- 需求、設計、工作與參考資料各自保留適當角色；缺少預期時記錄缺口，不補造驗收答案。
- 新增 `manage-confluence-docs-as-code`，依既有生命週期分階段取代舊發布 Skill。

## Capabilities

### New Capabilities

- `confluence-docs`: 將 Confluence 內容納入 Git 與原生 SDD，依版本化來源安全發布並保存證據。

### Modified Capabilities

無。此規劃包沒有既有 OpenSpec capability 基線。

## Impact

影響 `Skill-Atlassian-Ecosystem` 的新 Skill、既有 access 導流、catalog、inventory、tests 與中央 replacement 整合。新增固定版本 OpenSpec validator 依賴；目前只交付規劃，沒有安裝或執行。

不等待 SYP-5 完整治理規格；後續提供這份基線供其評估沿用。既有 SYP-159 release gate、權限與 live E2E 門檻維持。
