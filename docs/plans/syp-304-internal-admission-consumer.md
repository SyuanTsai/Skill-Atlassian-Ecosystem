# 計畫：SYP-304 Atlassian 內部 Skill 准用接入與耗時驗收

## 1. 目標與範圍

- 預期結果：Skill-Atlassian-Ecosystem 以固定、完整的中央 authority tuple 讀取 SYP-314 內部准用資料，並能對 `review-bitbucket-pull-request` 的核准內部用途做出可驗證的允許或拒絕決定。
- 驗收條件：
  - consumer 實際呼叫中央 `Resolve-StandardValidationInternalSkillUse` reader；不能以讀 JSON、字串比對或本地自我宣告取代中央判斷。
  - 允許案例綁定中央資料所要求的 repository、Skill、package bytes、來源身分、用途、工具條件、人類處置與 authority 成員雜湊。
  - 未登錄、Skill bytes 漂移、用途不符、必要工具條件不符、authority inventory 缺件／重複／hash 不符及中央回傳非准用時 fail closed。
  - 原 LP3 finding、severity 與歷史 report digest 仍可追溯；reader 結果不得把 scanner finding 改成已修復或受 suppression。
  - `releaseEligible=false`；不授予 Bitbucket Create／Reply／Resolve、live mutation、安裝、發佈、Catalog 或 Lock 操作。
  - 記錄 setup、authority inventory/hash/sort、完整 SourceValidation 與 total wall time；20 分鐘內為 SYP-280 目標，超過時保留分段診斷而不略過 gate。
- 交付：consumer production 接入、直接正反例、完整 authority pin、耗時證據與回復方式。
- 不在範圍：外部第三方 Skill、通用 eligibility 平台、semantic scan、live API write、USER 安裝、release/catalog/lock，以及修改中央 schema/registry/reader。後續協調另交付的 SYP-317 單檔來源清理依 2.5 接入，但不擴成 317 其他功能修改。
- 依賴：SYP-314 中央單一 writer 先完成 reader 的實際函式簽章、決定 schema、完整 authority inventory 與可驗證候選。consumer 不自行創造平行 schema。
- 已確認的 revision 語意：consumer 將目前 immutable source candidate revision 傳入中央 reader；中央 decision 以 `sourceRevision` 回傳目前 revision，並以 `reviewedSourceRevision=7e8228c393579d5d21ac9c0ad729c7b5d219bab6` 保留原審查來源。准用身分由 repository、Skill ID 與完整 package content hash 決定，因此 repository 後續 commit 在該 Skill bytes 未變時不會被誤擋，Skill bytes 變動則必須重新審查。

## 2. 預計變更

### 2.1 採用完整中央 authority tuple

- 目標檔案／符號：`config/standard-v1.json`、`scripts/Invoke-SourceConformance.ps1` 的 `$script:AuthorityCommit`／`$script:AuthorityArchiveSha256`／`$script:AuthorityFiles`、`scripts/Validate.ps1`、`scripts/Test-Repository.ps1`、本地鏡像 `scripts/Invoke-StandardValidation.ps1`。
- 原現況：consumer 固定 PR91 merge `e510ca172620d5b2d46c1647714af2553bfa925f`、34 個 authority files 與 runner SHA-256 `426a1251898d6849c20605f162a6ba5b2568aeee877181b904fd30791b52fe95`。
- 變更：採用已正常合併的中央 PR92 merge `d574cf903567cb30d7f9051b671d6be61de1f42e`，archive SHA-256 `e79395d308bb2b8212eac3366cf64067f73f8d7a0687c6d4d5153c63c44cc993`，並以一個不可拆分的 tuple 更新完整 34-file inventory、runner SHA-256 `e19d34f6bc4287f19b53ab377c7574c7403ba4f3e240f4107fba17fcc9d36051` 與所有重複 pin；本地 runner 必須與中央 Git raw／archive bytes 相同。
- 原因：reader、registry、schema 任一成員未同步都不能構成可信准用判斷。
- 影響／風險：漏更新任一重複 pin 會造成 authority drift 或讓測試只驗到舊 reader；以 inventory contract 與逐檔 hash 測試阻擋。

### 2.2 在來源驗證入口呼叫中央 reader

- 目標檔案／符號：`scripts/Invoke-SourceConformance.ps1` 的 authority 解壓與逐檔驗證後、執行 central runner 前的來源 gate；若中央契約要求 child adapter 承載結果，再最小更新 `$childRunnerText` 與 static adapter 參數。
- 現況：來源入口會驗證完整 authority archive，下載固定工具，建立 candidate archive，並呼叫中央 runner。Static bridge 目前只接受 correction 的 `authorizationGranted=false`、空 `authorizedOperations` 與 `releaseEligible=false`；這是 parser correction 的非授權保證，不能冒充內部准用。
- 變更：在已驗證 authority root 內載入中央 reader，傳入中央簽章要求的 exact consumer inputs，將 decision 寫入 run-owned evidence；對本次明確要求的 Bitbucket 內部用途，reader 非准用、輸出不完整、`contentSha256` 不等於完整已審查 package digest `056b8e520460e6612b10c8c9248fd7c217c6e4708ca65f3bc6c05b98ee84dec9`，或其他 binding 不符時終止來源 gate。parser correction 的既有 false/empty/release false 檢查保持不變。
- 原因：讓 consumer 實際採用中央准用決定，同時維持 parser correction、canonical gate 與 release gate 的不同職責。
- 影響／風險：reader 只應讀取已驗證 authority 與 candidate snapshot，不得從 working tree、candidate 自帶 registry 或環境字串取得信任資料。decision artifact 必須留在本次 run root，並經 bounded JSON／exact property validation 後才使用。

### 2.3 保留 canonical 與 workflow 邊界

- 目標檔案／符號：`.github/workflows/validate.yml` 的 `Run canonical Standard v1 validation`／source report routing、`scripts/Validate.ps1` 的 source-conformance entry。
- 現況：workflow 以 `scripts/Validate.ps1 -SourceConformance` 執行 canonical Stages 1–5，之後從 canonical report 路由 source 結果；Stage 6 沒有 semantic consent 時仍為 BLOCKED/10，source Stages 1–5 可獨立通過。
- 變更：預設不改 workflow。只有中央 reader 的 run-owned decision 需要新增到既有 report/evidence contract 且現行路由無法承載時，才加入最小 routing；不得把內部准用轉為 `releaseEligible=true` 或跳過任何 stage。
- 原因：本次是來源准用接入，不是 release 或 semantic 流程重寫。
- 影響／風險：若中央契約只回傳獨立 decision，consumer 應以明確 gate event 或受控 sidecar 留證，不任意擴充 canonical schema。

### 2.4 更新直接 contract tests

- 目標檔案／符號：`tests/StandardV1Conformance.Tests.ps1` 的 expected authority tuple；`tests/SourceStaticBridge.Tests.ps1` 或中央介面穩定後最接近實際呼叫邊界的既有 test file；必要時 `tests/CanonicalValidation.Tests.ps1` 的 source route 驗證。
- 現況：`StandardV1Conformance.Tests.ps1` 固定 PR91 34-file tuple；`SourceStaticBridge.Tests.ps1` 只證明 parser correction 保留 finding 並拒絕不支援的 partial reason。
- 變更：以中央實際函式簽章建立可信 reader fixture；證明允許 case 真的由 pinned central function 回傳，並對用途、bytes、decision 回傳錯誤 content identity、authority pin、工具條件與非准用結果逐一拒絕。若不新增 test file 即可完整覆蓋，優先沿用既有 inventory 內的 suite，避免無意擴大 protected test inventory。
- 原因：中央 suite 證明 reader 自身；consumer suite 必須另外證明此 repository 傳入正確資料、採用輸出且 fail closed。
- 影響／風險：避免只測字串存在、複製中央演算法或直接讀 registry，因這些測試無法證明 consumer 使用正式 reader。

### 2.5 接收 SYP-317 精確單檔來源清理

- 來源：branch `codex/syp317-source-cleanup-20261017`，baseline `7e8228c393579d5d21ac9c0ad729c7b5d219bab6`、tree `ef618283c4ee144eea0d9388d197d34a284a32bb`；精確 patch SHA-256 `08dc67a57a104f7097e4a53580fe3cbe6d51576a46228200b1bd3d0fec43b3ec`。
- 變更：只在 `skills/manage-confluence-docs-as-code/scripts/ConfluenceDocs.psm1` 刪除六行未匯出且無 caller 的 `Write-CapturePrivateText` wrapper；`Write-CapturePrivateBytes` 與 public exports 不變。
- 整合：由本 304 consumer worktree 套用精確 patch，317 worktree 保持不動。最終以同一 consumer PR 交付，但 Git 歷史保留獨立 commit 邏輯，讓 reviewer 可分開審查來源清理與 authority／reader 接入。
- 准用影響：此路徑不在 `review-bitbucket-pull-request` 的五檔 package；該 package 的 Git raw content digest 維持 `056b8e520460e6612b10c8c9248fd7c217c6e4708ca65f3bc6c05b98ee84dec9`，不需改中央准用 identity。
- 驗證：在合併 worktree 重新執行七個既有 Capture／Draft 行為案例、24 個功能 PowerShell parser、public exports／private bytes writer 檢查，以及 consumer reader targeted suites。既有 317 API／Bitbucket 離線證據保留，不為統計重跑未受影響的完整集合。

## 3. 測試情境

### 3.1 已登錄 exact Skill 與用途允許

- 關聯變更：2.1、2.2、2.4。
- 測試層級：consumer integration。
- Given：完整 pinned authority、PR18 受核准的 exact `review-bitbucket-pull-request` package、中央定義的用途與必要工具條件。
- When：source gate 呼叫中央 reader。
- Then：得到中央契約定義的准用 decision；包含可追溯的人類處置與 LP3 residual finding context；`releaseEligible=false`，且不含 mutation/install/release 授權。
- TDD：Red＝現行 consumer 沒有 reader 呼叫或 decision；Green＝只加入正式 reader 呼叫與 strict output validation；Refactor＝抽出小型 invocation/validation helper，不複製中央 policy。

### 3.2 未登錄、用途不符與 package 漂移拒絕

- 關聯變更：2.2、2.4。
- 測試層級：consumer integration negative cases。
- Given：分別修改 repository/Skill identity、要求 Bitbucket mutation 用途，或新增／修改／移除一個 Skill 檔案。
- When：執行相同 consumer gate。
- Then：在執行 Skill、網路 mutation 或中央 canonical run 前 fail closed，診斷指出不相符類別且不洩漏敏感內容。
- TDD：Red＝現行入口沒有內部准用判斷；Green＝最小傳參與拒絕；Refactor＝共用 fixture，只保留會改變信任結論的案例。

### 3.3 authority 或工具條件不可信時拒絕

- 關聯變更：2.1、2.2、2.4。
- 測試層級：unit/integration。
- Given：authority inventory 缺 reader／registry／schema、重複 path、hash mismatch，或中央要求的工具條件未滿足。
- When：consumer 準備呼叫 reader。
- Then：拒絕且不改用 consumer 自帶 registry、working-tree file 或環境 override。
- TDD：Red＝若直接 dot-source 路徑而未驗證 inventory，測試應先顯示錯誤准用；Green＝先完成現有 exact authority loop，再允許 reader invocation；Refactor＝沿用現有 path/hash helper。

### 3.4 canonical 結果與 parser correction 不被准用洗白

- 關聯變更：2.2、2.3、2.4。
- 測試層級：regression。
- Given：准用 decision 成功且原 scanner finding 仍存在。
- When：執行 static bridge 與 source report routing。
- Then：finding/severity 保留；parser correction 仍要求 `authorizationGranted=false` 與空 operations；canonical Stage 6 無 consent 時仍 BLOCKED/10；source gate 不將任何結果改成 release eligible。
- TDD：Red＝新增一個會抓到准用欄位錯誤影響 correction/release 的 fixture；Green＝分離 decision 與 correction properties；Refactor＝命名明確區分 `internalUseDecision` 與 `staticCorrection`。

### 3.5 完整 SourceValidation 與 20 分鐘目標

- 關聯變更：全部。
- 測試層級：完整 acceptance。
- Given：可重現的中央候選或已正常 merge 的 immutable authority tuple、乾淨 consumer candidate commit 與固定工具 receipts。
- When：執行 repository 要求的完整 `-SourceConformance` 路徑，以 monotonic stopwatch 與 UTC 起訖記錄 setup、inventory/hash/sort、source validation 及 total wall time。
- Then：Stages 1–5 與 required repository checks 通過；總時間與分段時間寫入 evidence。20 分鐘內達標；超過時保留真實結果、最慢階段與後續處置，不把局部 suite 宣稱為完整驗收。
- TDD：完整 gate 是驗收而非單元實作，不另寫會複製 timer 的測試；先以直接正反例完成 Green，再在可提交 candidate 上執行一次必要完整 gate。

### 3.6 SYP-317 單檔清理在合併候選維持行為

- 關聯變更：2.5。
- 測試層級：consumer integration regression。
- Given：同基線的 317 精確 patch 已由 304 套用，其他 56 個 package files、public exports 與 private bytes writer 未改。
- When：執行選定七個 Capture／Draft 案例、24 檔 PowerShell parse 與 consumer reader targeted suites。
- Then：七個案例全通過、parse errors 為零、wrapper 不存在、bytes writer 與 exports 保留，且 Bitbucket 五檔 content identity 不變。

## 4. 交付與驗證

- 直接驗證：中央 reader consumer fixture、`tests/SourceStaticBridge.Tests.ps1`、`tests/StandardV1Conformance.Tests.ps1`，及實際受影響的 `CanonicalValidation` subset。
- 結構驗證：PowerShell parser、JSON parse、authority paths ordinal sort／唯一性、逐檔 SHA-256、中央 runner raw-byte equality、`git diff --check`。
- 完整驗收：在獨立 feature worktree 的 candidate commit 執行 `scripts/Validate.ps1 -SourceConformance` 所需命令與 required checks，保存 report、工具 receipts、開始／結束／elapsed 與 exit codes。既有 PR18 run 38923965069 作未變 baseline，不冒充新差異驗證。
- 發佈：production diff 與 targeted tests 先完成；commit、push、PR 另依 repository 明確授權執行。正式 consumer pin 只指向經正常 review/merge 或明確允許的 immutable 中央 commit。
- 回復：把 consumer 整個 authority tuple 與 reader invocation 一起回復到 PR91 merge tuple；不得只回退 hash 或只刪 decision check。舊 review-only assessment、scanner report 與 finding 保留。
- 成功訊號：允許與拒絕 fixture 均通過，完整 source gate 在新 candidate 上通過，evidence 明確顯示 internal approval 不改變 release/semantic 結果。

## 5. 風險與未決項目

- 中央 PR92 已在悉尼時間 2026-10-18 05:00:42 正常合併；consumer 端已獨立驗證 handoff SHA、merge tree／parents、codeload archive，以及全部 34 個 authority member 的 Git raw 與 archive bytes。接收證據為 `SYP304-internal-admission-evidence-20261017/central-reception.json`。
- 正式 PR92 reader 已以 PR18 五檔 package 及 `local-pr-review` 實測通過；`release` 用途、Skill bytes 漂移與 registry authority pin 漂移均 fail closed。consumer 仍須在自己的 immutable candidate 上完成完整 source gate，不能用中央 CI 或先前 local smoke 取代。
- reader 是中央 function 而非獨立 executable 時，dot-source 必須使用中央提供的 `-DefineFunctionsOnly` 安全入口，且只能在 archive/逐檔 hash 驗證後執行。
- 完整 source validation 依賴固定工具解析與候選 commit。未提交 working tree 不能成為 immutable candidate；需在取得精確 commit 授權後完成最後耗時驗收。
- `.github/workflows/validate.yml` 目前沒有已證實必改理由；若 reader decision 能在現有 run evidence 中驗收，保持不變。
