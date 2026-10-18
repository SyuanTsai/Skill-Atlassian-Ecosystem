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
- 變更：以 ordinal 排序發現全部 `*.Tests.ps1`，並以 source start line 排序同檔 definitions，將一般檔案依最多六個 definition 以 round-robin 建立 shard；source order 讓原始檔案中相鄰的上限正反例分到不同 shards，避免 selector 字串排序把多個高成本邊界案例集中在單一 critical-path shard。重複 selector 的檔案退回完整單檔；`CanonicalValidation.Tests.ps1` 與 `ProtectedRunner.Tests.ps1` 各自由全新的 dedicated process 執行完整單檔，該 process 完成一項後立即退出，不取得其他 shard。所有 priority、dedicated 與一般 tasks 依序進入同一個 deterministic bounded queue；priority 只改變 queue 前置順序，不保留固定 worker pool，任何完成前置 task 的 worker 都立即 work-steal 其餘 inventory。`ConfluenceDocs.MarkdownPushCli.Tests.ps1` 的七個 definition 以 fine-grained inventory 各成一個 shard，避免 46.838、32.778 與 39.084 秒的三個高成本 cases 被 source-order round-robin 集中到同一 shard。其餘 tasks 依檔案 discovered definition 數量遞減、再依檔名與 shard ordinal 建立 queue，使用 definition inventory 作為無須預知 runtime 的 largest-first 成本代理。全部 processes 共用 `MaxConcurrency=12` 上限；worker 先以 strict UTF-8 擷取 parent 建立後不再修改的 queue payload，再以 atomic move 判定唯一 winner，winner 直接使用已擷取 payload，不重新開啟 moved claim path，loser 丟棄副本並競爭下一個 task。每個 worker 固定相同 Pester module/version、只在 `Invoke-Pester` 期間停用 scheduler 的 StrictMode，並使用獨立 run-owned result/stdout/stderr。scheduler 精確核對 discovered definition、expanded runtime cases、test-file inventory、total/passed/skipped/failed/container failures 與 observed concurrency。任何 worker 無結果、非零退出、definition／case 缺件或重複、inventory 不一致或結果格式錯誤時 fail closed；異常時終止仍在執行的 task-owned children。
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
- 變更：在同一 Stage 4 child event 內先啟動七個 isolated scanner processes，每個只讀一個 Skill root並寫不同的 create-only report；全部成功後，父程序依原 ordinal skill order 讀取、驗證與彙整 findings。若 manage-confluence 原始 report 符合既有 exact parse-limit predicate，再循原中央 wrapper 路徑序列執行 correction；不平行或改寫 correction evidence。任何 scan 失敗時終止仍在執行的 siblings 並使整個 static event fail closed。resolver 對原生 SkillSpector 以 JSON `null` 表示沒有 executable prefix；child 在跨 process 傳入 helper 前把 absent／`null` 正規化為 `[]`，仍逐項拒絕任何實際存在的非字串 prefix。每個 initial scan 明確設定 `PYTHONDONTWRITEBYTECODE=1`，避免 console launcher import 在 resolver 已雜湊的 venv 內新增 `.pyc`，讓後續中央 correction 的 before/after closure identity 保持與 receipt 相同。
- 原因：初始 scans 沒有資料相依，中央契約只要求一個完整的 Stage 4 event、完整 analyzer coverage 與固定 findings aggregation order；在 event 內重疊 processes 可保留 stage order 與原 evidence shape。
- 影響／風險：七個 Python scanner graph 同時執行會提高短時間 CPU／記憶體負載；以 active Skill 數量作固定上限、不同 output path、完整 report inventory、process-tree cleanup 與父程序 ordinal aggregation 控制。不得在 Static 通過前啟動 Stage 5，也不得平行或省略中央 correction。

### 2.9 重用未改變 attachment state 的 terminal budget plans

- 目標檔案／符號：`skills/manage-confluence-docs-as-code/scripts/ConfluenceDocs.psm1` 的 attachment download loop；`tests/ConfluenceDocs.Capture.Tests.ps1` 的 duplicate-content fixture 與 terminal-plan call observer。
- 已驗證現況：largest-first 完整 preflight 為 `504/504`、`677.673s`；source-order 為 `505/505`、`669.501s`。兩個關鍵 shards 分別只剩 1,000 與 1,001 identities 案例，卻同時約在 parallel phase 開始後 596 秒才完成。fixture identities 的下載 bytes 相同；第一個 asset 建立後，後續 duplicate iterations 沒有改變 reasons、pending audit、data bytes、pages 或 incomplete IDs，但仍每次重新 `ConvertTo-Json` 兩份相同 terminal state。
- 變更：對 attachment loop 內會影響 terminal plan 的 append-only state 維護 monotonic version。`potentialFallback` 依 state version 重用；duplicate content asset 的 `preAssetWrite` 只在相同 state version 第一次序列化，其後重用已驗收 plan。新 reason、新 unique asset audit 或 data byte 變化立即遞增 version；新 unique asset 的 prospective audit 仍每次獨立重算。HTTP attempts、attempt/byte limits、每次 asset path reparse check、private ACL、existing bytes hash、before/after identity stability、最終 manifest 與 audit plan 全部保留。
- 原因：將成本與改變安全結論的 state transition 綁定，避免 content-addressed duplicate assets 對未改變 JSON evidence 做二次方的重複序列化，同時不快取檔案系統安全檢查。
- 影響／風險：cache invalidation 漏掉 state transition 會誤用舊 budget 結論；以只增加的 version、只讀 plan object、duplicate 與 unique-content 現有行為案例，以及 26 個 duplicate identities 的呼叫次數上限固定。不快取 HTTP 或 filesystem validation 結果。

### 2.10 以單一 bounded queue 的前置工作保護關鍵路徑

- 目標檔案／符號：`scripts/Invoke-ShardedPester.ps1` 的 task payload 與 phase scheduling；`scripts/Invoke-SourceConformance.ps1` 的 priority/exclusive inventories；`tests/StandardV1Conformance.Tests.ps1` 的 priority 與 lifecycle fixtures。
- 已驗證現況：獨立 Capture priority pool 的完整 preflight 為 `506/507`、`593.656s`，固定 2+10 workers 使其他長尾檔案延後；移除 priority pool 的單一 queue 通過 `507/507`，牆鐘 `563.834s`，但 MarkdownPush、RepositoryValidation 與其他小型 integration files 仍在 queue 尾端。MarkdownPush 隔離完整檔為 `142.493s`；逐案例 profile 顯示原兩個 source-order shards 約為 123.569 與 50.721 秒，且前者在 12-way workload 中成為 523 秒 critical path。
- 變更：priority inventory 只作同一 queue 的前置提示；production 清單包含六個原長尾檔案及後續 benchmark 最晚完成的十二個小型 integration files。MarkdownPush 另列 fine-grained inventory，每個 definition 各成一個 shard；fine-grained 可以與 priority 重疊，但不得與 exclusive inventory 重疊。Priority tasks 完成後，原 12 個 workers 直接取得 dedicated 或一般 tasks；dedicated worker 完成 payload 後退出，parent 在 queue 尚有工作時補充容量。Aggregate 顯式回報 `priorityScheduling=queue-front`、priority/fine-grained inventories 與 shard counts。
- 原因：queue-front 讓已量測的長尾工作提早開始，但不把總容量永久切成 pools；fine-grained MarkdownPush 讓 work stealing 平衡七個 runtime 差異大的 CLI cases。expanded queue 的最後二十個檔案在 4 秒內密集完成，沒有留下單一尾端 shard。
- 影響／風險：清單來自固定完整 suite 的實測，測試成本改變時可能需要重測；以完整 inventory/result schema、存在／唯一／overlap 驗證、兩個實際 priority PIDs、正常 worker 補充與全量 preflight 固定。Max16 (`523.921s`) 與 MaxCases8 (`536.701s`) 均較 Max12/6 慢，明確不採用。

### 2.11 重用 Windows ACL runtime metadata，保留每次檔案驗證

- 目標檔案／符號：`skills/manage-confluence-docs-as-code/scripts/ConfluenceDocs.psm1` 的 Windows ACL reflection setup 與 `Test-CapturePrivatePathPermissions`；`tests/ConfluenceDocs.Capture.Tests.ps1` 的測試副本 observer。
- 已驗證現況：1,000/1,001 identities 內容相同時，每次 iteration 仍必須核對 path/reparse、ACL、existing bytes 與 hash；但 ACL helper 每次都重新 `Assembly.Load`、搜尋相同 reflection methods 並取得當前 user SID。這些 runtime metadata 在同一 process 與 identity 內不變，且不是檔案安全狀態。
- 變更：在 module scope 懶建一個 read-only ACL runtime record，包含 extension type、create/read methods 與 current user SID。每次 permission check 仍重新 `Get-Item`、取得該 path/stream 的 current access control、檢查 protected rules、兩個 exact SIDs、inheritance/propagation 與 FullControl；每次 duplicate asset 仍重新做 reparse、bytes/hash 檢查。
- 原因：把不變的 reflection discovery 成本從 attachment identity 數量中移除，不快取任何可被檔案系統改變的結果。

### 2.12 以唯一 content-addressed asset 為單位做最終完整性驗證

- 目標檔案／符號：`skills/manage-confluence-docs-as-code/scripts/ConfluenceDocs.psm1` 的 attachment download loop 與 staging-to-final 邊界；`tests/ConfluenceDocs.Capture.Tests.ps1` 的 1,000 identities 邊界與 asset verification observer。
- 已驗證現況：相同空 bytes 的 1,000 與 1,001 個不同 attachment identities 都對應同一 SHA-256 asset。每次 identity 仍須保留 HTTP attempt、bytes budget、content hash、remote identity 與 manifest record，但現行 loop 對同一個 run-owned staging file 重複做 reparse、ACL、read-all-bytes 與 hash 檢查 999 次；完整 preflight 的兩個 shards 各約 624–625 秒，成為 repository Pester 關鍵路徑。
- 變更：以本次 capture 內 append-only 的 SHA-256→relative-path map 記錄已由 private writer 建立或驗證的唯一 asset；duplicate identity 仍下載並雜湊 bytes，但不重開同一 staging path。寫入 terminal manifest 前及 move 後，各依唯一 asset map 重新執行 path/reparse、private ACL、bytes/hash 驗證；缺件、路徑替換、ACL 變更或內容漂移仍 fail closed。未知但已存在的 asset path 仍先完整驗證後才加入 map。
- 原因：驗證成本應隨唯一 captured bytes 數量增長，而不是隨引用同一內容的遠端 identities 數量增長。staging tree 仍由 private ACL 保護，publication 邊界保留 fresh pre-move 與 post-move verification，不快取 HTTP、budget 或 remote identity 結果。
- 影響／風險：runtime record 建立不完整時必須仍 fail closed；以既有 private-permissions unavailable/書寫案例與 duplicate-content observer 固定，observer 只在測試副本記錄 expensive initialization 次數。

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
- Then：每個 test file 的全部 discovered definitions 精確執行一次、成功結果完整加總、實際 concurrency 不超過設定且大於一；atomic move 成功後不需要再次以 path 開啟 claim payload；priority 與 fine-grained inventories 只改變 task 建立／分組，不改變 cases 或 pass 條件；任一 failing／crashed／missing worker 使彙整結果失敗，其他檔案仍被記錄；production adapter 不再以單一 process 執行整個 `tests/`，也不改變中央看到的一個 `repository-test-pester` event。
- TDD：Red＝新增行為測試時 helper 尚不存在且 source runner 仍是單 process；正式 v14 另捕捉到 worker 已成功 claim 後重新開啟 `claim-task-0004.json` 得到 file-not-found，`UnitT35_CapturesTheQueuePayloadBeforePublishingTheAtomicClaim` 對舊順序得到 Red。正式 v15 證明 88 個 shards 全數完成且 `503/503` 通過，但 largest file 的 `case-10` 在其餘 shards 完成後才單獨執行，總牆鐘 `1423.936s`；`UnitT37_ClaimsEveryShardFromTheLargestDefinitionInventoryFirst` 與 `UnitT38_DistributesDefinitionsBySourceOrderBeforeSharding` 固定 largest-first/source-order grouping。terminal-plan cache 後的 `505/505` 仍為 `648.850s`；`UnitT49_OverlapsDedicatedLifecycleWorkerWithoutReusingIt` 對舊的 exclusive-then-parallel phases 因不能觀察到 overlap 得到 Red。完整單檔 Capture (`827.069s`) 與固定 priority pool (`593.656s`) 均為負向證據。`UnitT39_SchedulesPriorityShardsAtTheFrontOfOneBoundedQueue` 對分離 pools 與未提供 fine-grained grouping 的 helper 得到 Red。Green＝加入最小 bounded scheduler 與 adapter 接線，把 immutable payload capture 移到 atomic move 之前，以 source line order 進行一般檔案 round-robin grouping，將 priority/fine-grained/dedicated/normal tasks 放入同一 bounded queue；Refactor＝共用 child launch/result validation/cleanup，保持 ordinal inventory、唯一 move ownership與 fail-closed 診斷。

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
- Then：成功 fixture 的 elapsed 明顯小於七次 delay 總和、每個 Skill 恰有一份 create-only report、summary inventory 完整；`null` prefix 跨界時成為精確 `[]`，而不是 `[null]` 或 JSON `null`；scanner child 收到 `PYTHONDONTWRITEBYTECODE=1`，因此 initial scans 不改變 frozen install closure；失敗 fixture 非零退出並終止 siblings；production static event 在回收全部原始 reports 後才執行既有 parse-limit predicate、中央 correction 與 findings aggregation。
- TDD：Red＝helper 尚不存在且 `static` mode 仍在 aggregation loop 同步啟動 scanner；正式 v12 另證明 native `null` prefix 被傳成 JSON `null` 並由 helper fail closed；v13 通過 initial scans 後由中央 correction 的 before check 證明 scanner closure 已漂移，直接 fixture 同時得到 no-bytecode environment 為空的 Red。Green＝加入 bounded scanner scheduler、cleanup 與 wiring，在 child 邊界最小正規化 absent／`null` prefix，並對每個 scanner process 固定 no-bytecode environment；Refactor＝把 scan process lifecycle留在 helper，把 report/correction/security assertions留在既有父程序。

### 3.10 duplicate attachment state 不重複序列化 terminal plans

- 關聯變更：2.9。
- 測試層級：consumer integration performance regression。
- Given：26 個不同 attachment identities 下載相同 bytes，因 content address 共用一個 asset file；fixture 只在測試副本中記錄 private `Get-CaptureTerminalPlan` 呼叫。
- When：完整執行 capture，包含 26 次 HTTP attempts、每次 filesystem validation、attachment reread 與最終 manifest。
- Then：capture 仍完整保留 26 identities，terminal-plan 呼叫數只隨 state transitions 增加且不超過固定上限；unique-content、failed download、budget stop 與 metadata cap 的既有案例仍通過。
- TDD：Red＝舊 loop 對每個 duplicate identity 重新序列化 potential 與 pre-write plans，超過呼叫上限；Green＝只快取同 state version 的相同 plan inputs；Refactor＝以明確 version bump 集中 invalidation，不引入一般化 cache framework。

### 3.11 dedicated 完整檔案 worker 退出後補充容量且不重用

- 關聯變更：2.6、2.10。
- 測試層級：unit performance/concurrency regression。
- Given：一個必須完整單檔執行的 lifecycle fixture 與一個可分兩個 shards 的一般檔案，worker 上限為二。
- When：lifecycle task 快速完成並退出；第一個一般 shard 等待第二個一般 shard 的 start marker，三項都記錄 process ID。
- Then：parent 在 queue 尚有任務時補上一個 worker，第二個一般 shard 在 timeout 前開始；lifecycle PID 不出現於一般 shards，兩個一般 shards 來自兩個 PIDs，累計啟動三個 workers 但 `maxObservedConcurrency` 仍為二。
- TDD：Red＝未補充容量時，第一個一般 shard 只能在 timeout 後才釋放 worker 執行第二個；完整 priority=2 preflight 另實際觸發 nested helper 留下 unclaimed task 而 fail closed。Green＝將 dedicated task 與一般 tasks 交給同一 bounded phase，完成 dedicated payload 後退出，parent 在 queue 尚非空時補充同 lane worker；Refactor＝共用 child launch/result validation/cleanup，不超過 phase concurrency。

### 3.12 priority 與 fine-grained shards 位於同一 bounded queue 前端

- 關聯變更：2.6、2.10。
- 測試層級：unit scheduling/performance regression。
- Given：一個含兩個 definitions 的 priority/fine-grained 檔案、一個一般檔案、一般 shard 上限六與總 worker 上限二。
- When：兩個 priority definitions 各自成為 shard、記錄不同 PID、等待對方 start marker 後完成；一般 task 等待兩個 done markers再寫入自己的 marker。
- Then：兩個 priority shards 在同一 queue 最先由兩個不同 workers 取得；一般 task 之後由其中一個 persistent worker取得。Aggregate 包含三個 cases、兩個 priority shards、fine-grained inventory、`priorityScheduling=queue-front` 與 `maxObservedConcurrency=2`，且沒有獨立 priority concurrency 欄位。
- TDD：Red＝分離 priority pool 需要額外 concurrency 介面且不能讓全部 workers work-steal；Green＝依 priority inventory 把 tasks 放到單一 queue 前端，fine-grained inventory 將指定檔案分成每 definition 一 shard；Refactor＝aggregate 顯式回報 scheduling mode 與 inventories，沿用 worker/result schema。

### 3.13 ACL runtime metadata 只初始化一次

- 關聯變更：2.11。
- 測試層級：consumer integration performance regression。
- Given：26 個 attachment identities 共用同一 content-addressed asset，測試副本在 ACL runtime expensive initialization 進入點記錄呼叫。
- When：執行完整 capture，包含每次 duplicate path/ACL/bytes/hash 驗證。
- Then：ACL runtime initialization 只有一次；capture 仍完成 26 downloads/identities、一個 asset file 與原有 audit/manifest 斷言。
- TDD：Red：舊 module 沒有可觀測的 cached runtime 入口，fixture instrumentation fail closed；Green＝懶建 immutable runtime record 並讓現有 Windows ACL paths 共用；Refactor＝新 helper 不 export，不接受 path 或儲存 ACL result。

### 3.14 duplicate identities 只按唯一 asset 驗證 staging bytes

- 關聯變更：2.12。
- 測試層級：consumer integration performance/security regression。
- Given：1,000 個不同 attachment identities 下載相同空 bytes，測試副本在 production asset path／ACL／bytes/hash 驗證邊界記錄呼叫。
- When：capture 完成全部 1,000 次 HTTP attempts、budget debit、identity records、terminal manifest 與 staging-to-final publication。
- Then：manifest 保留 1,000 identities、磁碟只有一個 content-addressed asset；同一 SHA-256 的完整 asset 驗證次數只隨 publication boundaries 增加，不隨 identity 數量增加，且 pre-move 與 post-move 均重新驗證。
- TDD：Red＝現行 duplicate loop 記錄 999 次既有 asset 驗證；Green＝加入 per-capture unique asset map 與兩個 fresh final verifications；Refactor＝集中 private asset verification helper，所有 mismatch 沿用 fail-closed security result。

## 4. 交付與驗證

- 直接驗證：中央 reader consumer fixture、`tests/SourceStaticBridge.Tests.ps1`、`tests/StandardV1Conformance.Tests.ps1`，及實際受影響的 `CanonicalValidation` subset。
- 結構驗證：PowerShell parser、JSON parse、authority paths ordinal sort／唯一性、逐檔 SHA-256、中央 runner raw-byte equality、`git diff --check`。
- 完整驗收：在獨立 feature worktree 的 candidate commit 執行 `scripts/Validate.ps1 -SourceConformance` 所需命令與 required checks，保存 report、工具 receipts、開始／結束／elapsed 與 exit codes。既有 PR18 run 38923965069 作未變 baseline，不冒充新差異驗證。v11 因 live worktree 含 local-ignored `.agents/skills` 而在候選清潔檢查拒絕；v12 在乾淨 snapshot 通過 Stages 1–3，但因 native SkillSpector 的 `null` prefix 未正規化而在 Stage 4 拒絕；v13 在 `801.220s` 內通過 prefix 邊界與全部 initial scans，但後續中央 correction 在執行前偵測到 scanner closure 漂移而拒絕；v14 在 `832.160s` 內通過 Stages 1–4、Atlassian 與 internal-use events，Stage 5 Pester 因 moved claim path 消失而 fail closed；v15 的 Stages 1–5 與 `503/503` Pester 全通過，但總牆鐘 `1423.936s` 超過上限。這五次都只作 failure evidence。修正後必須以新的 named、`--no-track` clean candidate worktree重跑，且只有 Stages 1–5 全通過並在 1,200 秒內才算接受。
- 效能驗證：在無 `.git` 的 immutable snapshot 以固定 Pester 6.2.0 驗證 sharded `495/495`、36 檔／466 definitions 完整 inventory、沒有 child leak；sequential 為 `1046.770s`，v9 sharded 為 `593.520s`，Capture 單檔 idle baseline 為 `380.816s`。加入 resolver／Static 正反例後的早期 working-tree preflight 為 `501/501`、690.129 秒。唯一 asset 驗證把 Capture 全檔降到 151.27 秒；單一 queue baseline 為 `507/507`、563.834 秒。queue-front 為 523.069 秒；MarkdownPush fine-grained 為 520.569 秒；expanded queue-front + fine-grained 的接受配置完整通過 `507/507`、36 檔／478 definitions／94 shards、零 skipped/failed/failed containers，aggregate `496.986s`、牆鐘 `501.493s`。Max16 為 `523.921s`、MaxCases8 為 `536.701s`，均不採用。resolver 250 秒 head-start 以 exact authority/formal runtime 完整產生四份 receipts，但 `427.997s` 慢於同時啟動 baseline `422.328s`，因此撤回。最終仍以新 immutable consumer commit 與全新 evidence root 的完整 formal run判定 1,200 秒接受門檻。
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
- v13 invocation 完整綁定具名 branch、commit `03f7f130b91fe87d55852384ebac633607409df6` 與中央 PR94 archive；四工具 resolver elapsed `472.643s`，Stages 1–3 通過。Stage 4 的七個 initial scans 已通過 null prefix 邊界，之後中央 correction fail closed：`Installed scanner closure differs before execution.`；總牆鐘 `801.220s`、Stage 5 未執行。這把殘餘問題縮小為 parallel helper 啟動 console launcher 時未停用 Python bytecode；`UnitT60_ScansEveryActiveSkillConcurrentlyWithoutWritingPythonBytecode` 先得到環境值為空的 Red，再以 scanner child 固定 `PYTHONDONTWRITEBYTECODE=1` 得到 Green。
- v14 invocation 綁定 commit `f24605bebefbb5fba266eba53f4e19cd3294f846`；resolver elapsed `442.917s`，Stages 1–4 全通過，Stage 4 event `c9ee040c-2215-451a-8977-95b2eb8390f8` exit 0 且 stderr 空，證明 null prefix 與 no-bytecode closure 修正均有效。Stage 5 的 Atlassian 與 exact internal-use events 通過；Pester persistent worker 在 atomic move 後重新讀 `worker-0002/claim-task-0004.json` 時得到 file-not-found，總牆鐘 `832.160s` 後 fail closed，沒有 repository test result 被誤報為通過。worker 改為 move 前讀取 immutable payload、move 只決定唯一 winner，並由 `UnitT35_CapturesTheQueuePayloadBeforePublishingTheAtomicClaim` 固定此競爭順序。
- v15 invocation 綁定 commit `8dbdfb1c2d8c0ed21d31e8f1542368200290d80a`、tree `6fc79334949562d136c0bbea4b59a210682b2127` 與中央 PR94 archive SHA-256 `befc8c1395da90af7ecbcbf5b7036765bde4bea4aa84204315139ffa3037727f`；Stages 1–5 全通過，Pester event `89f2de77-ce41-4309-a85d-01e8b893fca3` 完整執行 `503/503`、43 個 test-file inventory，零 skipped、failed 與 failed container。canonical 如預期因未提供 semantic consent 以 `BLOCKED/10` 結束，沒有轉為 release eligible。formal 總牆鐘 `1423.936s`、report SHA-256 `40066b00a9f3613e701b985977fafb7ac65776911be040262cfae8799ad389f7`，因 `withinTwentyMinutes=false` 不接受且不可推送。Pester queue 的前 87 個 shards 完成後，definition inventory 最大的 `ConfluenceDocs.Capture.Tests.ps1::case-10` 才在最後一個 worker 獨立執行；後續以 largest-definition-inventory-first 修正關鍵路徑，不刪減案例或放寬驗收條件。
- v18 preflight 先以唯一 asset map 讓四個 Capture regression `4/4` 在 26.86 秒通過、Capture 全檔 `57/57` 在 151.27 秒通過。最終 scheduler 對全部 `507/507` 使用單一 Max12 queue、94 shards、18 個 priority files、MarkdownPush 逐 definition sharding 與兩個 dedicated lifecycle files，aggregate `496.986s`、外層 `501.493s`。最後二十個檔案在 4 秒內完成，顯示沒有單一 tail shard。Max16、MaxCases8、分離 priority pool與 resolver head-start 都以完整或真實 acquisition evidence 證明較慢並撤回；這些 evidence 不取代候選 commit 的正式 1,200 秒 gate。
