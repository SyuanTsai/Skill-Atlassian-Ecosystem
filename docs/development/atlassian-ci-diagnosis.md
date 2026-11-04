# Atlassian CI 診斷與離線修正

日期：2026-11-04。基準：main `8274c13d7755211891b2324b782063a475323864`。
本文件是診斷紀錄，不是 Human Review disposition、release approval 或 policy exception。

## 依據與根因

`config/standard-v1.json` 固定 AI-Instructions authority commit
`098e40d26de585e5565a031d9b826454e6a34720`，central runner SHA-256 為
`e19d34f6bc4287f19b53ab377c7574c7403ba4f3e240f4107fba17fcc9d36051`。
本次離線讀取該 commit 的 Git objects，核對 Standard、security policy、toolchain、static wrapper
及 runner 的 bytes 與 adapter hash 相符。Repo 的部分同名文件是較早 mirror；正式執行取得並驗證
adapter 指定的 authority snapshot，不能僅以同名 mirror 推定目前執行契約。

已證實的失敗鏈：

1. `.ci-evidence/main-run.log:420–421`：latest-stable resolver 選到 SkillSpector 2.13.3。
2. 修改前的 `scripts/Invoke-SourceConformance.ps1` 固定讓
   `manage-confluence-docs-as-code` 先經中央 correction wrapper；該 skill 不在原生平行掃描 inventory。
3. Pinned `scripts/Invoke-StandardStaticScan.ps1:164–178` 僅接受 2.13.0 的 receipt、release、wheel identity。
   日誌第 2492 行明確記錄 correction exit 20 與 `Scanner receipt has no supported frozen parser profile`。
   這項檢查在產生原始 report 前執行。
4. 日誌第 3599–3601 行的 `provider-acquisition`／`provider-report-not-found` 是失敗後的診斷輸出，
   不能據此推定所有原生 scanner 都未產生 stdout。
5. 日誌第 3656 行 source projection 為 failed；第 3731、3774、3817 行的三個必要 checks
   均鏡射同一結果。對應 `.github/workflows/validate.yml:1282` 起的三個 mirror jobs。

額外確認的工具相容性問題：pinned static wrapper 第 222 行仍傳 `--output`。
2.13.3 使用 stdout JSON，因此只更新版本檢查仍不足以修好 correction。
Repo 原生 `Invoke-ParallelSkillSpector.ps1` 已以 stdout/stderr 分流擷取，沒有傳 `--output`。
這次沒有修改 workflow 的 pass/fail 規則或 required contexts。

現有日誌足以證明最近這次 run 的上述原因；沒有逐次歷史 run 證據，不能宣稱自 2026-10-16
以來每次失敗的細節都相同。

## 本 repo 修改

- Static bridge：完整 inventory 先原生掃描並驗證 skill、source、components 與 report binding。
  僅已確認符合既有 `static_parse_limit` 條件的 Confluence report 才啟動 pinned correction。
  其他 incomplete 狀態仍拒絕；correction failure 仍拒絕；原生 findings 與 raw reports 保留。
  比對兩次掃描的 findings 時，僅排除每次生成的 `finding_id`，其餘欄位仍須一致。
- LP3 不在本次修正範圍。`review-bitbucket-pull-request` 保持 `origin/main` 的完整位元組，
  repository validator 也維持 main 的 frontmatter 契約並拒絕 `allowed-tools`。原因是
  `docs/standards/upstream-interoperability.md` 將 `allowed-tools` 定義為 experimental、host-specific metadata，
  且不得授予 credentials、write 或 network access；在 source package 宣告寫入或網路工具會擴張 host 權限風險。
  現有中央 internal-use 核准 `atlassian-bitbucket-review-7e8228c` 已將 LP3 以
  `accepted-host-mediated-internal-use` 留存，並綁定核准的 Skill bytes、歷史 finding 與 report digest；
  該核准不代表 LP3 已修復，也不授予 release、install 或額外 host tool 權限。
  第一輪獨立 review 也確認，若 validator 無條件接受 `Read`、`Write`、`Bash`、`WebFetch` 等值，
  將無法證明 host 沒有把 experimental metadata 當成預先授權；Pester 6.1.0 的
  `UnitT20_PreservesApprovedBitbucketSkillBytesInGitArchive` 同時證明修改後 bytes 已偏離中央核准版本。
  因此完整撤回 Skill、validator 與相關測試的 `allowed-tools` 變更。
- Confluence：將受影響的續行改為 splatting、插值改為 `-f`，拆開路徑正規化與過長條件；
  Markdown extension 使用等價的 case-insensitive operator，path-list 比較保留 LF separator。
  不改 API URL、request payload、授權、readback 或 failure semantics。
- Static bridge 測試：涵蓋 native-first ordering、完整 coverage 不啟動 correction、partial profile failure、
  finding drift、identity drift、unsupported limitation、child cleanup 與原生 findings 保留。
  既有 speculative ordering 測試改為驗證新的 native-first 契約，未刪除測試。

## 驗證與限制

離線 SkillSpector 2.13.3 結果：

| Skill | Coverage | 剩餘 findings |
| --- | --- | --- |
| configure-bitbucket-api-access | 100% | 4 × E1 MEDIUM |
| configure-confluence-api-access | 100% | 4 × E1 MEDIUM |
| configure-jira-api-access | 100% | 5 × E1 MEDIUM |
| manage-confluence-docs-as-code | 100% | 1 × E1 MEDIUM |
| publish-requirements-to-confluence | 100% | 2 × E1 MEDIUM |
| review-bitbucket-pull-request | 100% | 2 × E1 MEDIUM、1 × LP3 MEDIUM |
| work-with-jira | 100% | 0 |

所有掃描 exit 0、complete；沒有 static_parse_limit。仍有 18 個 E1 MEDIUM 與上述留存的 LP3 MEDIUM，
不是「零 findings」或 release approval。Scanner 是既有離線安裝，並非本次 canonical resolver run。

已通過：

- `tests/validate-repository.ps1`（PowerShell 7）。
- `tests/validate-api-access.ps1`（PowerShell 7；27 個離線 scenarios）。
- `tests/validate-windows-powershell.ps1`（Windows PowerShell 5.1）。
- PowerShell parser：76 個 `.ps1`／`.psm1` 檔案無語法錯誤。
- 直接載入既有測試 fixture 做 9 個 static bridge scenarios，
  以及 9 個 Confluence mapping／code binding／Markdown preview／publication scenarios；HTTP 僅使用 fixture。
- `git diff --check`。

Pester policy 為 latest-stable；所附 CI run 使用 6.2.0。本機僅找到 6.1.0／較舊版本，
依任務限制沒有安裝、連網或用舊版本宣稱 canonical 通過。上述 fixture 檢查不等同 Pester suite。
待備妥 6.2.0 後應執行：

```powershell
Import-Module Pester -RequiredVersion 6.2.0
Invoke-Pester -Path tests/Test-Repository.Tests.ps1, tests/SourceStaticBridge.Tests.ps1, tests/StandardV1Conformance.Tests.ps1, tests/ConfluenceDocs.*.Tests.ps1 -Output Detailed
```

沒有執行遠端 CI 或完整 canonical resolver／release pipeline；不能宣稱必要 checks 已轉綠。

## Authority 後續工作

若仍有套件需要中央 PowerShell correction，authority 必須以經驗證的 2.13.3 identity 更新：

- `docs/standards/static-parser-host-ownership.json` 的 `officialScannerVersion`、
  `officialScannerReleaseCommit`、`officialScannerReleaseAssetSha256`、`officialAnalyzerSha256`。
- `docs/standards/schemas/static-parser-host-ownership-v1.schema.json` 與
  `static-parser-profile-execution-v1.schema.json` 的相應 const。
- `scripts/standard_static_powershell.py` 的 `OFFICIAL_*` identities，以及與該版 analyzer 相容的 bridge。
- `scripts/Invoke-StandardStaticScan.ps1` 的 receipt／closure 驗證與原始 JSON stdout 擷取；
  同步 Standard 的 profile contract 及 authority parser／workflow regressions。

日誌提供的 2.13.3 release commit 是 `38a1dfe93325d2f8bfcd4f8d0241eed706334915`，wheel digest 是
`a421dffba5e0f966bf1baf8acd77f4750a8ece0afc5520ecf49252b4004a8577`；authority 實作仍須驗證
analyzer bytes、closure 與 parser 行為，不能只把版本常數改成接受任意 2.13.x。
完成 authority review 後，再更新 consumer 的 immutable pin／hashes。本次未變更 authority 檔案或 pin。
目前七個原生掃描均 complete，因此本次 source 修正不必依賴上述 correction 升級。

## Human Review 待決事項

Pinned Standard 第 9.4 節及 `validation-security-gate.json` 定義
MEDIUM → `HUMAN_REVIEW_REQUIRED`；沒有以一般 skill metadata 宣告 hostname 就免除 E1 的機制。
Source stages 1–5 projection 與 release eligibility 是不同結果：pinned runner 的 Stage 4 可保留
MEDIUM 並要求後續 review；後續 semantic／approval 未完成，不代表三個 source-only mirror checks
必然失敗，也不代表可 release/install。正式 CI readback 仍必要。

建議 reviewer 逐筆審查以上 18 個 E1；LP3 則沿用上述 candidate-bound internal-use 決定，
不得描述為已修復或一般 release exception。E1 限於 `https://api.atlassian.com/` 的已驗證 Cloud ID／product route
與 `https://api.bitbucket.org/2.0`。Disposition 建議記錄：用途、實際資料流、必要的認證傳送、
exact host/base validation、授權 header 的 redirect 邊界、redaction、寫入授權、affected skill／file／finding、
reviewer、scope、evidence、candidate identity、release decision 與重審條件。
不能將必要 API 認證誤寫成「完全不傳送 secrets」。Candidate bytes、目的地或權限範圍改變時重審。
若需影響 gate 結果的 suppression／exception，須使用 authority 的正式、窄範圍、Human Approved 契約；
本次沒有建立 disposition 或核可，也沒有隱藏或混淆 URL。
