## 1. 原生格式與執行環境

固定版 CLI、原生結構與專案語意檢查依[實作契約](../../../docs/syp171/implementation-plan.md)驗證。下列勾選代表正式來源分支中的實際交付與驗證，依[來源交付契約](../../../docs/syp171/source-simplification-and-goal-plan.md) AC171-01～06 保存版本綁定證據。中央 release、部署及 installed/live 由接收工作驗收；原生 spec 的功能預期不變，未執行項目不勾選。

- [ ] 1.1 固定 OpenSpec v1.13.0、Node、package integrity 與 lock，回讀版本及來源證據。
- [ ] 1.2 以本 change 及損壞變體執行官方 strict validator，保存正例通過與負例拒絕結果。
- [ ] 1.3 固定 renderer parser/runtime 與支援節點，驗證中文、code、連結及附件 golden fixtures。

## 2. SDD 來源與版本核心

- [ ] 2.1 先建立 ID、來源、狀態及缺少 validator 的失敗測試，再實作 OpenSpecSource 並取得 PASS。
- [ ] 2.2 實作 mapping、projection 與 code/docs/spec bindings，驗證改名、過期證據及版本混用會正確停止。
- [ ] 2.3 用同份 SCN fixture 串接測試 consumer 與 renderer；合成錯誤行為應被 assertion 捕捉而不改 THEN。

## 3. 匯入與 Git 流程

- [ ] 3.1 實作完整分頁、附件、staging/recovery，測試部分失敗不回報完整成功。
- [ ] 3.2 定義並驗證原文至 spec/design/tasks/reference 的候選整理，缺少預期時保留缺口而不標 ready。
- [ ] 3.3 驗證隔離 Git repo 的精確提交與版本解析，保留所有無關未提交檔案。

## 4. 發布與恢復

- [ ] 4.1 實作 preview、drift/draft 檢查、不可變 plan 與 ID 對應；負例零 mutating calls。
- [ ] 4.2 實作 create/update/attachment/journal/readback，驗證 timeout reconciliation 與無盲目重試。
- [ ] 4.3 驗證 SDD 內容、情境、版本標記回讀及第二次 no-op，不由 publish 自動 archive。

## 5. Repository 與正式交付

- [ ] 5.1 更新 Skill/access routing、catalog、inventory、授權及依賴證據，執行適用既有 regression。
- [ ] 5.2 將完整測試納入正式 source gate，完成來源 review／required CI／正常 merge 與不可變來源交付；正式 release approval 由 SYP-259 承接，來源 required gate 不豁免。
- [ ] 5.3 SYP-259 owner：在已授權 Confluence 合成目標執行 installed SDD→Git→publish→readback E2E，保存證據。接收 SYP-171 固定版本、runtime 建置與同候選來源證據後執行；本單未執行 installed live，不勾選。
- [ ] 5.4 SYP-259 owner：驗證中央 managed replacement、customized/unmanaged 保護及回復，再完成舊 Skill 實際退役。接收本單 replacement／alias 契約、不可變包與恢復限制後執行；本單未執行部署，不勾選。
- [ ] 5.5 提供固定基線、原生 artifacts、IDs 與驗證證據作 SYP-5 接手資料；不宣稱其已採用。
