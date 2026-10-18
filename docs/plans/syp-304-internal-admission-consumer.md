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
- 原現況：consumer 固定 PR92 merge `d574cf903567cb30d7f9051b671d6be61de1f42e`、34 個 authority files、archive SHA-256 `e79395d308bb2b8212eac3366cf64067f73f8d7a0687c6d4d5153c63c44cc993` 與 runner SHA-256 `e19d34f6bc4287f19b53ab377c7574c7403ba4f3e240f4107fba17fcc9d36051`；其中 static parser profile 只接受 SkillSpector 2.12.0，無法接受 latest-stable resolver 已解析到的 2.13.0。
- 變更：採用已正常合併的中央 PR94 merge `3d00939e76e8ae6108ff793ef7e6c41d94815ebc`，archive SHA-256 `befc8c1395da90af7ecbcbf5b7036765bde4bea4aa84204315139ffa3037727f`，並以一個不可拆分的 tuple 更新完整 34-file inventory 與所有重複 pin；runner SHA-256 維持 `e19d34f6bc4287f19b53ab377c7574c7403ba4f3e240f4107fba17fcc9d36051`，本地 runner 必須與中央 archive bytes 相同。
- archive bytes 邊界：`.gitattributes` 對 `skills/review-bitbucket-pull-request/**` 固定 `text eol=lf`，使 Windows `core.autocrlf=true` 下的 `git archive` 仍保留中央 registry 審查的五個 Git blob bytes；直接 regression 從 immutable commit archive 逐檔驗證既有 package hash。
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

### 2.6 在不減少案例的前提下平行執行 repository Pester

- 目標檔案／符號：新增 `scripts/Invoke-ShardedPester.ps1` 的 bounded worker scheduler；更新 `scripts/Invoke-SourceConformance.ps1` 的 `repository-pester` mode；更新 `tests/StandardV1Conformance.Tests.ps1` 的直接行為契約。
- 已驗證現況：正式 v10 的 Stages 1–4 通過，Stage 5 的 Atlassian repository check 與中央 internal-use reader 均通過；其後單一 Pester process 在 supervisor 固定的 900 秒被終止。相同 immutable snapshot 在 supervisor 外完整執行 `488/488` 通過，但耗時 `1046.770s`；因此是可重現的完整 suite 執行時間問題，不是 test failure，也不是本次 archive hash test 的成本。
- 變更：以 ordinal 排序發現全部 `*.Tests.ps1` 與 source definition，將一般檔案依最多六個 definition 建立 shard；重複 selector 的檔案退回完整單檔，`CanonicalValidation.Tests.ps1` 與 `ProtectedRunner.Tests.ps1` 各自在全新的 serial process 執行。其餘 shard 由最多十二個 persistent worker 以 atomic claim work-stealing 執行，每個 worker 固定相同 Pester module/version、只在 `Invoke-Pester` 期間停用 scheduler 的 StrictMode，並使用獨立 run-owned result/stdout/stderr。scheduler 精確核對 discovered definition、expanded runtime cases、test-file inventory、total/passed/skipped/failed/container failures 與 observed concurrency。任何 worker 無結果、非零退出、definition／case 缺件或重複、inventory 不一致或結果格式錯誤時 fail closed；異常時終止仍在執行的 task-owned children。
- 原因：把互相獨立且已以 GUID/TestDrive/process-local environment 隔離的 test files 並行，保留全部案例與既有 outer canonical event，讓完整 SourceValidation 有機會在 1,200 秒總牆鐘目標內完成。
- 影響／風險：平行 worker 增加短時間 CPU／process 壓力；以固定最大 concurrency、獨立 output paths、完整 inventory binding、失敗彙整、child cleanup 與順序無關測試契約控制。不得以排除慢測試、縮小 `tests/` inventory 或放寬 pass 條件換取時間。

### 2.7 平行解析四個獨立 validation tools

- 目標檔案／符號：新增 `scripts/Invoke-ParallelToolResolution.ps1`；更新 `scripts/Invoke-SourceConformance.ps1` 的 resolver setup；更新 `tests/StandardV1Conformance.Tests.ps1` 的 scheduler 與 production wiring 契約。
- 已驗證現況：v10 從 formal process 起點到 Stage 1 前約耗時 669 秒；stdout 顯示 SkillSpector Python closure、Pester module、skill-validator 與 skill-tools 依序解析／安裝。四個 resolver 共用同一 authenticated authority policy 與 `resolutionRunId`，但各自建立 GUID 命名的 tool-specific install root 與獨立 receipt，沒有資料相依。v10 Stages 1–4 合計約 239 秒；即使完整 Pester 已降到 593.520 秒，若維持串行 resolver，推算 formal 仍約 1,516 秒，無法符合 1,200 秒門檻。
- 變更：先啟動四個 isolated PowerShell resolver children，再等待全部完成；每個 child 仍收到同一 policy path、run ID、expected Go runtime 與共同 run-owned parent root，但只寫自己的 GUID install directory、receipt 與 captured streams。任何 child 啟動、退出或 receipt 失敗時，終止尚存 task-owned process trees 並 fail closed；全部成功後才依固定 tool order 回放輸出、讀取 receipts、驗證 exact identity 與建立 toolchain。
- 原因：將互不相依的 acquisition wall time 收斂到最慢 resolver，而不重用舊安裝、不略過 latest-stable resolution，也不改變 receipt／closure／launcher identity。
- 影響／風險：同時進行 PyPI、Go、npm 與 PSGallery acquisition 會提高短時間網路、CPU 與磁碟負載；以固定四個已知工具、獨立 child process、不同 install/receipt paths、create-only output、完整 process-tree cleanup 與父程序逐份 receipt 驗證控制。不得共用先前 run receipt 或 installed closure。

### 2.8 平行執行七個獨立的初始 SkillSpector scans

- 目標檔案／符號：新增 `scripts/Invoke-ParallelSkillSpector.ps1`；更新 `scripts/Invoke-SourceConformance.ps1` 內嵌 child runner 的 `static` mode；更新 `tests/StandardV1Conformance.Tests.ps1` 的 scan scheduler 與 production wiring 契約。
- 已驗證現況：v10 Stage 4 單一 event 為 197.189 秒，child runner 依 active Skill ordinal 逐一呼叫相同 frozen SkillSpector executable。以同一 2.13.0 receipt 對七個現有 Skill 做 direct benchmark，七個 processes 全部 exit 0 且各自產生 report；parallel wall time 為 32.181 秒。只有 `manage-confluence-docs-as-code` 的受支援 parse-limit correction 必須在原始 report 回收後，以中央 wrapper 另行執行並保留 original/corrected/profile evidence。
- 變更：在同一 Stage 4 child event 內先啟動七個 isolated scanner processes，每個只讀一個 Skill root並寫不同的 create-only report；全部成功後，父程序依原 ordinal skill order 讀取、驗證與彙整 findings。若 manage-confluence 原始 report 符合既有 exact parse-limit predicate，再循原中央 wrapper 路徑序列執行 correction；不平行或改寫 correction evidence。任何 scan 失敗時終止仍在執行的 siblings 並使整個 static event fail closed。resolver 對原生 SkillSpector 以 JSON `null` 表示沒有 executable prefix；child 在跨 process 傳入 helper 前把 absent／`null` 正規化為 `[]`，仍逐項拒絕任何實際存在的非字串 prefix。
- 原因：初始 scans 沒有資料相依，中央契約只要求一個完整的 Stage 4 event、完整 analyzer coverage 與固定 findings aggregation order；在 event 內重疊 processes 可保留 stage order 與原 evidence shape。
- 影響／風險：七個 Python scanner graph 同時執行會提高短時間 CPU／記憶體負載；以 active Skill 數量作固定上限、不同 output path、完整 report inventory、process-tree cleanup 與父程序 ordinal aggregation 控制。不得在 Static 通過前啟動 Stage 5，也不得平行或省略中央 correction。

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

### 3.7 bounded Pester sharding 保留完整結果

- 關聯變更：2.6。
- 測試層級：unit／consumer integration performance regression。
- Given：至少三個獨立 fixture test files、固定 Pester module/version、bounded concurrency 與各自 run-owned output；另有一組包含 failing test 的 fixture。
- When：執行 sharded helper，並由 `repository-pester` mode 採用其彙整結果。
- Then：每個 test file 精確執行一次、成功結果完整加總、實際 concurrency 不超過設定且大於一；任一 failing／crashed／missing worker 使彙整結果失敗，其他檔案仍被記錄；production adapter 不再以單一 process 執行整個 `tests/`，也不改變中央看到的一個 `repository-test-pester` event。
- TDD：Red＝新增行為測試時 helper 尚不存在且 source runner 仍是單 process；Green＝加入最小 bounded scheduler 與 adapter 接線；Refactor＝共用 child launch/result validation/cleanup，保持 ordinal inventory 與 fail-closed 診斷。

### 3.8 bounded resolver concurrency 保留 exact receipts

- 關聯變更：2.7。
- 測試層級：unit／consumer integration performance regression。
- Given：四個 fake resolver children 使用相同 run ID、不同 tool/receipt path 並各自延遲；另有一個快速失敗、其他長時間執行的 failure fixture。
- When：執行 parallel resolver helper，並由 SourceConformance 採用其四份 outputs。
- Then：成功 fixture 的 elapsed 明顯小於四次 delay 總和，四份 create-only receipt 均存在且 tool inventory 精確；失敗 fixture 非零退出、終止仍在執行的 siblings 且不產生成功 summary；production wiring 不再在 `foreach` 中同步呼叫 resolver，父程序仍逐份驗證 frozen identity 與相同 `resolutionRunId`。
- TDD：Red＝helper 尚不存在且 production 仍同步解析；Green＝加入固定四工具 scheduler、process-tree cleanup 與 adapter 接線；Refactor＝集中 child lifecycle、stream capture、summary validation，保持 receipt 驗證在父程序。

### 3.9 bounded Static concurrency 保留單一完整 Stage 4 event

- 關聯變更：2.8。
- 測試層級：unit／consumer integration performance regression。
- Given：七個 fake Skill roots 與會延遲後各自寫 report 的 scanner；另有一個快速失敗、其餘長時間執行的 failure fixture，以及與正式 native launcher 相同的 `skillSpectorPrefixArguments: null` toolchain。
- When：執行 parallel SkillSpector helper，再由 `static` mode 依 fixed active Skill order 讀取 reports。
- Then：成功 fixture 的 elapsed 明顯小於七次 delay 總和、每個 Skill 恰有一份 create-only report、summary inventory 完整；`null` prefix 跨界時成為精確 `[]`，而不是 `[null]` 或 JSON `null`；失敗 fixture 非零退出並終止 siblings；production static event 在回收全部原始 reports 後才執行既有 parse-limit predicate、中央 correction 與 findings aggregation。
- TDD：Red＝helper 尚不存在且 `static` mode 仍在 aggregation loop 同步啟動 scanner；正式 v12 另證明 native `null` prefix 被傳成 JSON `null` 並由 helper fail closed。Green＝加入 bounded scanner scheduler、cleanup 與 wiring，並在 child 邊界最小正規化 absent／`null` prefix；Refactor＝把 scan process lifecycle留在 helper，把 report/correction/security assertions留在既有父程序。

## 4. 交付與驗證

- 直接驗證：中央 reader consumer fixture、`tests/SourceStaticBridge.Tests.ps1`、`tests/StandardV1Conformance.Tests.ps1`，及實際受影響的 `CanonicalValidation` subset。
- 結構驗證：PowerShell parser、JSON parse、authority paths ordinal sort／唯一性、逐檔 SHA-256、中央 runner raw-byte equality、`git diff --check`。
- 完整驗收：在獨立 feature worktree 的 candidate commit 執行 `scripts/Validate.ps1 -SourceConformance` 所需命令與 required checks，保存 report、工具 receipts、開始／結束／elapsed 與 exit codes。既有 PR18 run 38923965069 作未變 baseline，不冒充新差異驗證。v11 因 live worktree 含 local-ignored `.agents/skills` 而在候選清潔檢查拒絕；v12 在乾淨 snapshot 通過 Stages 1–3，但因 native SkillSpector 的 `null` prefix 未正規化而在 Stage 4 拒絕，兩者都只作 failure evidence。修正後必須以新的 named、`--no-track` clean candidate worktree 執行 v13，且只有 Stages 1–5 全通過並在 1,200 秒內才算接受。
- 效能驗證：在無 `.git` 的 immutable snapshot 以固定 Pester 6.2.0 驗證 sharded `495/495`、36 檔／466 definitions 完整 inventory、沒有 child leak；sequential 為 `1046.770s`，v9 sharded 為 `593.520s`，Capture 單檔 idle baseline 為 `380.816s`。加入六個 parallel resolver／Static 正反例並回復 v9 round-robin scheduler 後，consumer working-tree 預驗證為 `501/501`、36 檔／472 definitions／88 shards、零失敗與零 failed containers，aggregate `690.129s`、牆鐘 `698.136s`。resolver helper 先以 deterministic delay fixture 證明實際重疊，再以中央 merge、exact repin 後的新 immutable consumer commit 與全新 evidence root 的完整 formal run 判定 1,200 秒接受門檻。
- 發佈：production diff 與 targeted tests 先完成；commit、push、PR 另依 repository 明確授權執行。正式 consumer pin 只指向經正常 review/merge 或明確允許的 immutable 中央 commit。
- 回復：把 consumer 整個 authority tuple 與 reader invocation 一起回復到 PR91 merge tuple；不得只回退 hash 或只刪 decision check。舊 review-only assessment、scanner report 與 finding 保留。
- 成功訊號：允許與拒絕 fixture 均通過，完整 source gate 在新 candidate 上通過，evidence 明確顯示 internal approval 不改變 release/semantic 結果。

## 5. 風險與未決項目

- 中央 PR92 已在悉尼時間 2026-10-18 05:00:42 正常合併；consumer 端已獨立驗證 handoff SHA、merge tree／parents、codeload archive，以及全部 34 個 authority member 的 Git raw 與 archive bytes。接收證據為 `SYP304-internal-admission-evidence-20261017/central-reception.json`。
- 中央 PR93 已正常合併為 `fcee565d5df993daf69bf7f2ac266478cfef55fe`；consumer repin 使用其精確 codeload archive SHA-256 `664c9290d1feeffc323ec323df8f25f043cb08f175eeb75024ab4e26a5642ecd`，並重新計算全部 34 個 authority member。此 revision 把 PowerShell ownership profile 綁定到官方 SkillSpector 2.13.0 release commit、wheel 與 analyzer bytes；正式 SourceValidation 仍須以 repin 後的新 immutable consumer commit 驗收。
- 中央 PR94 已在 Windows Core、Windows Install Smoke、code review 與 security review 全數通過後正常合併為 `3d00939e76e8ae6108ff793ef7e6c41d94815ebc`；merge parents 為 PR93 merge 與 reviewed head `75b0a1db95dc421231431728b2a3338e7581aaa1`，merge tree 與 reviewed head tree 相同。consumer reception 重新下載 355-entry codeload archive，得到 SHA-256 `befc8c1395da90af7ecbcbf5b7036765bde4bea4aa84204315139ffa3037727f`；34 個 authority members 中只有 standard、Python closure helper 與 PowerShell resolver 三個預期 hash 改變，其餘 31 個及 runner identity 不變。
- 正式 PR92 reader 已以 PR18 五檔 package 及 `local-pr-review` 實測通過；`release` 用途、Skill bytes 漂移與 registry authority pin 漂移均 fail closed。consumer 仍須在自己的 immutable candidate 上完成完整 source gate，不能用中央 CI 或先前 local smoke 取代。
- reader 是中央 function 而非獨立 executable 時，dot-source 必須使用中央提供的 `-DefineFunctionsOnly` 安全入口，且只能在 archive/逐檔 hash 驗證後執行。
- 完整 source validation 依賴固定工具解析與候選 commit。未提交 working tree 不能成為 immutable candidate；需在取得精確 commit 授權後完成最後耗時驗收。
- `.github/workflows/validate.yml` 目前沒有已證實必改理由；若 reader decision 能在現有 run evidence 中驗收，保持不變。
- v10 report SHA-256 `17b5630be114955703e382d5b3aeccdbf1e529196ceaa60071717350ae5a2e33`；精確牆鐘 `1822.423s`。Stage 4 通過，Stage 5 internal-use event `440bcb4d-5f99-40a5-b199-e956da1a6d6a` 通過並回傳 exact approved package identity；Stage 5 最終僅因 Pester event `2a91bec3-bf65-457f-a50b-5abbb973e9ec` 在 900 秒 timeout 而失敗。此證據允許針對 Pester 執行模型修正，但不能被宣稱為 source acceptance。
- v12 的四工具 resolver 已完整成功，parallel resolver elapsed `492.017s`，Stages 1–3 通過；Stage 4 event `f7e9f5c6-a13b-4f06-92f9-4677ce821171` 在 candidate helper 的字串型別檢查拒絕 `null` prefix，因此 Stage 5 未執行。回歸 `InterT05_NormalizesNullNativePrefixArgumentsToAnEmptyArray` 先以相同 toolchain 形狀得到 Red，再由 child boundary 的最小正規化得到 Green；helper 對非字串實際元素的防線不變。
