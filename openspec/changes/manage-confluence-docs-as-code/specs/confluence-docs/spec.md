## Purpose

讓使用者將有權讀取的 Confluence 文件完整擷取至本機，從第一次整理就採用可追溯的原生 SDD，與指定程式碼版本及測試保持一致，再經預覽、衝突檢查與回讀發布，降低文件漂移及日後規格重整成本。

## ADDED Requirements

### Requirement: [SYP171-REQ-001] 完整擷取候選與來源

系統 SHALL 將指定頁面或明確 space 範圍內的可讀、受支援內容擷取為候選，保存站台、page ID、版本、階層、連結、附件與來源定位；不得直接覆蓋正式 Git 文件。

#### Scenario: [SYP171-SCN-001] 擷取包含多頁及附件的範圍

- **GIVEN** 使用者已指定有權讀取的站台與範圍，其中包含分頁及附件
- **WHEN** 系統完成擷取
- **THEN** 每個可讀項目均有唯一來源及版本對應，原本的正式 Git 文件保持不變

#### Scenario: [SYP171-SCN-002] 部分內容讀取失敗

- **WHEN** 指定範圍內有頁面無權限、分頁不完整或附件版本在擷取時變動
- **THEN** 系統保留已擷取候選並指出未完成項目，不回報整個範圍完整成功

### Requirement: [SYP171-REQ-002] 從匯入起採用原生 SDD

工作流程 SHALL 將有證據的需求與行為整理成原生 OpenSpec Requirement/Scenario，將設計、工作與參考內容放入對應 artifacts；保留原文對應，不補造預期結果。

#### Scenario: [SYP171-SCN-003] 混合文件整理為原生 artifacts

- **GIVEN** 候選同時含需求、技術方案、工作清單及操作說明
- **WHEN** 工作流程整理內容
- **THEN** 產生可回溯原文的 spec、design、tasks 及必要 references，不建立另一份可編輯需求 JSON

#### Scenario: [SYP171-SCN-004] 缺少可驗收預期

- **GIVEN** 原文與既有核准資料未定義某行為的預期結果
- **WHEN** 工作流程整理該需求
- **THEN** 缺口保持可見且該需求不標 implementation-ready，不憑目前 code 輸出補成核准的 THEN

### Requirement: [SYP171-REQ-003] 固定 Git 與程式碼版本

系統 SHALL 在正式發布前固定 spec/docs commits、適用 code commit、範圍及一致性證據；Git 提交僅包含已授權的文件變更。

#### Scenario: [SYP171-SCN-005] 保留無關 Git 工作

- **GIVEN** 文件已依指定 code commit 更新，工作樹另有無關未提交檔案
- **WHEN** 已授權工作流程提交文件並建立發布預覽
- **THEN** 文件版本可精確解析，無關檔案及其 Git 狀態保持不變

#### Scenario: [SYP171-SCN-006] 程式變更使現況文件失效

- **GIVEN** 相關 code 已變更而文件未更新，且沒有本次仍正確的 review 或測試證據
- **WHEN** 系統檢查發布資格
- **THEN** 回報 DocumentationStale，停止該現況文件發布

### Requirement: [SYP171-REQ-004] 精確預覽與頁面發布

系統 SHALL 預設產生預覽，依固定站台、page ID 或明確新頁目標發布；preview SHALL 包含內容、附件與中間寫入，來源變更使舊 plan 失效。

#### Scenario: [SYP171-SCN-007] 原生規格發布至已對應頁面

- **GIVEN** 來源已驗證並提交，目標已明確授權且無衝突
- **WHEN** 系統執行與預覽一致的 plan
- **THEN** 更新精確對應的頁面，保留原需求／情境身分及版本，不以標題認領其他頁面

### Requirement: [SYP171-REQ-005] 格式及語意完整性

系統 SHALL 使用固定版本的原生驗證器與專案檢查驗證 SDD，保留完整選定範圍的情境、來源及引用；不支援內容不得靜默刪除。

#### Scenario: [SYP171-SCN-008] 原生格式或情境無效

- **WHEN** 指定 SDD 有無效原生結構、缺少必要情境內容、重複 ID，或原生驗證器缺失／版本不符
- **THEN** 系統停止發布並指出問題，不降級成一般 Markdown 繞過驗證

#### Scenario: [SYP171-SCN-009] 頁面包含不支援內容

- **WHEN** 擷取或投影遇到無法完整表示的 macro 或節點
- **THEN** 保存原文與定位，停止受影響範圍發布，不用略去內容換取成功

### Requirement: [SYP171-REQ-006] 衝突與不確定寫入

系統 SHALL 檢查 published/draft 漂移並維持持久操作紀錄；無法唯一確認寫入結果時不得盲目重試或覆蓋。

#### Scenario: [SYP171-SCN-010] 遠端在預覽後改變

- **GIVEN** plan 已建立
- **WHEN** 目標版本或 draft 狀態在執行前與 plan 不同
- **THEN** 系統停止寫入並保留差異，不直接改用新版本覆蓋

#### Scenario: [SYP171-SCN-011] 建頁後回應逾時

- **WHEN** 建頁請求結果不確定
- **THEN** 系統依原 operation ID 及可驗證證據調查；不能唯一確認時保持 uncertain，不重新建立同頁

### Requirement: [SYP171-REQ-007] 回讀及無變更重跑

系統 SHALL 在回讀內容、身分、版本與附件吻合後才更新同步基準；相同來源及遠端狀態的再次發布不得新增版本或重複上傳。

#### Scenario: [SYP171-SCN-012] 發布後回讀及重跑

- **GIVEN** 本次發布已成功回讀
- **WHEN** 來源、工具版本及遠端內容均未改變而再次執行
- **THEN** 系統回報 no-op，不增加頁面版本或附件

### Requirement: [SYP171-REQ-008] 同一規格供測試與文件使用

工作流程 SHALL 讓開發、測試案例對應與 Confluence 投影引用同一原生 spec revision 與穩定 scenario ID；結果保存 code/test/build/run 證據，不回寫或另複製驗收答案。

#### Scenario: [SYP171-SCN-013] 行為違反同源驗收情境

- **GIVEN** 測試與文件投影引用相同 scenario，但被測行為違反其中的 THEN
- **WHEN** 測試執行並產生文件預覽
- **THEN** assertion 失敗、原預期保持不變，文件不能顯示該情境已通過

#### Scenario: [SYP171-SCN-014] 覆蓋缺口或證據過期

- **WHEN** 有適用情境未映射、未執行或結果屬於不同 spec/code 版本
- **THEN** 工作流程保留缺口與狀態，不宣稱整份規格已驗收

### Requirement: [SYP171-REQ-009] 區分預期、現況與完成狀態

系統 SHALL 分別呈現規格核准、實作、測試與發布狀態；發布本身不得修改規格預期或將提議的變更歸檔為現行行為。

#### Scenario: [SYP171-SCN-015] 發布尚未實作的目標

- **GIVEN** 已授權發布的提案尚未實作或未通過測試
- **WHEN** 系統發布其文件投影
- **THEN** 目標與未完成狀態清楚可見，沒有偽造 PASS 或自動 apply/archive

### Requirement: [SYP171-REQ-010] 不等待 SYP-5 完整交付

系統 SHALL 使用本單固定的原生 SDD 基線完成主要工作流程，不要求先安裝 SYP-5 artifacts；未來移轉保留需求／情境及頁面身分。

#### Scenario: [SYP171-SCN-016] 未提供 SYP-5 artifacts

- **GIVEN** 採用者具備本單所需原生 validator、Git 來源及已授權 Confluence 目標，沒有 SYP-5 bundle
- **WHEN** 執行擷取、SDD 整理、review、提交、驗證及發布
- **THEN** 系統可完成並回讀，不因缺少 SYP-5 的未定案格式而停止

### Requirement: [SYP171-REQ-011] 正式驗證及可回復遷移

交付流程 SHALL 在完成適用 canonical gate、review、installed SDD E2E 及 managed replacement 驗證後才退役舊 Skill，保護 customized/unmanaged 內容並保留回復路徑。

#### Scenario: [SYP171-SCN-017] 遷移存在個人修改的舊入口

- **GIVEN** 採用者的舊 Skill 有個人修改
- **WHEN** 正式 replacement 流程檢查安裝狀態
- **THEN** 不覆蓋個人內容，依中央規則回報及保留；不得以 catalog 變更直接宣稱遷移成功
