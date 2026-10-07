# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Bitbucket review actions' {
    BeforeAll {
        $script:ActionsScript = Join-Path (Split-Path -Parent $PSScriptRoot) 'skills/review-bitbucket-pull-request/scripts/Invoke-BitbucketReviewActions.ps1'
    }

    BeforeEach {
        $script:PlanPath = Join-Path $TestDrive 'plan.json'
        $script:ReceiptPath = Join-Path $TestDrive 'receipt.json'
        $script:Plan = [ordered]@{
            schemaVersion = 1; workspace = 'demo'; repository = 'service'; pullRequestId = 42
            sourceCommit = ('a' * 40); destinationCommit = ('b' * 40)
            review = @{ completeLocalDiff = $true; validationComplete = $true; evidence = 'offline diff and regression' }
            actions = @(@{ id = 'create-01'; findingId = 'finding-01'; type = 'Create'; assessment = 'new'; content = 'Retry duplicates a write'; evidence = 'src/retry.ps1:12' })
        }
        $script:Calls = [Collections.ArrayList]::new()
        $script:Http = { param($Method, $Uri, $Headers, $Body); [void]$script:Calls.Add($Method); throw 'Unexpected HTTP call' }
    }

    It 'UnitT10_Given_preview_When_actions_are_planned_Then_no_HTTP_or_receipt_mutation' {
        # Scenario: A complete local review has one finding but Apply is absent.
        # Purpose: Drafting requires neither credentials nor remote or receipt writes.
        $script:Plan | ConvertTo-Json -Depth 10 | Set-Content $script:PlanPath
        $result = & $script:ActionsScript -PlanPath $script:PlanPath -ReceiptPath $script:ReceiptPath -HttpInvoker $script:Http -AsObject
        $result.results[0].status | Should -Be 'preview'
        $script:Calls.Count | Should -Be 0
        Test-Path $script:ReceiptPath | Should -BeFalse
    }

    It 'UnitT20_Given_missing_authority_When_apply_is_requested_Then_zero_mutations' {
        # Scenario: Apply is requested without a trusted authorization argument.
        # Purpose: Plan data cannot confer permission to publish.
        $script:Plan | ConvertTo-Json -Depth 10 | Set-Content $script:PlanPath
        $result = & $script:ActionsScript -PlanPath $script:PlanPath -ReceiptPath $script:ReceiptPath -Apply -HttpInvoker $script:Http -AsObject
        $result.results[0].status | Should -Be 'unauthorized'
        $result.exitCode | Should -Be 1
        $script:Calls.Count | Should -Be 0
    }

    It 'UnitT30_Given_local_only_When_iterative_authority_exists_Then_zero_mutations' {
        # Scenario: The user switches an authorized PR to local-only.
        # Purpose: The latest user scope takes precedence over earlier authority.
        $script:Plan | ConvertTo-Json -Depth 10 | Set-Content $script:PlanPath
        $result = & $script:ActionsScript -PlanPath $script:PlanPath -ReceiptPath $script:ReceiptPath -Apply -LocalOnly -AuthorizationMode Iterative -AuthorizedTarget 'demo/service/42' -HttpInvoker $script:Http -AsObject
        $result.results[0].status | Should -Be 'preview'
        $script:Calls.Count | Should -Be 0
    }
}

Describe 'Bitbucket review offline smoke and invocation cost' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'fixtures/BitbucketReviewFixture.ps1')
        $script:ActionsScript = Join-Path (Split-Path -Parent $PSScriptRoot) 'skills/review-bitbucket-pull-request/scripts/Invoke-BitbucketReviewActions.ps1'
    }

    It 'InterT10_Given_six_local_findings_When_publish_and_re_review_run_Then_verified_roots_resolve_once' {
        # Scenario: A local review becomes an authorized publication and fresh PR fixes.
        # Purpose: Smoke the complete lifecycle with six findings and durable receipts.
        $fixture = New-BitbucketReviewFixture
        $fixture.plan.actions = @(1..6 | ForEach-Object { @{ id = "create-$_"; findingId = "finding-$_"; type = 'Create'; assessment = 'new'; content = "Finding $_"; evidence = 'offline diff and test' } })
        $caseRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $caseRoot | Out-Null
        $planPath = Join-Path $caseRoot 'plan.json'; $receiptPath = Join-Path $caseRoot 'receipt.json'
        $fixture.plan | ConvertTo-Json -Depth 15 | Set-Content $planPath
        $arguments = @{ PlanPath = $planPath; ReceiptPath = $receiptPath; EnvironmentReader = $fixture.environment; HttpInvoker = $fixture.http; DelayInvoker = $fixture.delay; AsObject = $true }
        $preview = & $script:ActionsScript @arguments
        @($preview.results | Where-Object status -EQ 'preview').Count | Should -Be 6
        $fixture.state.postCount | Should -Be 0
        $published = & $script:ActionsScript @arguments -Apply -AuthorizationMode Iterative -AuthorizedTarget 'demo/service/42'
        @($published.results | Where-Object status -EQ 'succeeded').Count | Should -Be 6
        $fixture.state.source = 'c' * 40; $fixture.plan.sourceCommit = 'c' * 40
        $fixture.plan.actions = @(1..6 | ForEach-Object { @{ id = "resolve-$_"; findingId = "finding-$_"; type = 'Resolve'; commentId = (99 + $_); assessment = 'fixed'; verifiedInPr = $true; evidence = 'new exact PR pair and regression' } })
        $fixture.plan | ConvertTo-Json -Depth 15 | Set-Content $planPath
        $resolved = & $script:ActionsScript @arguments -Apply -AuthorizationMode Iterative -AuthorizedTarget 'demo/service/42'
        @($resolved.results | Where-Object status -EQ 'succeeded').Count | Should -Be 6
        $again = & $script:ActionsScript @arguments -Apply -AuthorizationMode Iterative -AuthorizedTarget 'demo/service/42'
        @($again.results | Where-Object status -EQ 'already-resolved').Count | Should -Be 6
        $fixture.state.postCount | Should -Be 12
    }

    It 'InterT20_Given_same_six_findings_When_legacy_scratch_calls_and_batch_run_Then_measure_bytes_without_token_estimates' {
        # Scenario: Compare six generated success-path fixture scripts with one shared helper call.
        # Purpose: Measure orchestration/generation/output cost without fabricating token savings.
        $legacy = New-BitbucketReviewFixture
        $shared = New-BitbucketReviewFixture
        $findings = @(1..6 | ForEach-Object { @{ id = "create-$_"; findingId = "finding-$_"; type = 'Create'; assessment = 'new'; content = "Finding $_"; evidence = 'same pre-reviewed offline diff' } })
        # This deliberately limited baseline is an offline successful-path sample,
        # not a supported REST replacement or a release/authorization gate.
        $scratch = @'
param($Fixture, $Finding)
$origin = 'https://api.bitbucket.org/2.0/repositories/demo/service/pullrequests/42'
$comments = @(); $next = "$origin/comments"
while ($next) {
    $response = & $Fixture.http 'GET' ([uri]$next) @{} $null
    $page = $response.Content | ConvertFrom-Json
    $comments += $page.values
    $next = if ($page.PSObject.Properties['next']) { $page.next } else { $null }
}

$before = (& $Fixture.http 'GET' ([uri]$origin) @{} $null).Content | ConvertFrom-Json
if ($before.source.commit.hash -ne $Fixture.plan.sourceCommit -or $before.destination.commit.hash -ne $Fixture.plan.destinationCommit) { throw 'stale' }
$payload = @{ content = @{ raw = $Finding.content } } | ConvertTo-Json -Compress
$created = (& $Fixture.http 'POST' ([uri]"$origin/comments") @{} $payload).Content | ConvertFrom-Json
$verified = (& $Fixture.http 'GET' ([uri]"$origin/comments/$($created.id)") @{} $null).Content | ConvertFrom-Json
if ($verified.id -ne $created.id -or $verified.content.raw -ne $Finding.content) { throw 'unverified' }
$after = (& $Fixture.http 'GET' ([uri]$origin) @{} $null).Content | ConvertFrom-Json
if ($before.source.commit.hash -ne $after.source.commit.hash -or $before.destination.commit.hash -ne $after.destination.commit.hash) { throw 'changed' }
@{ actionId = $Finding.id; metadata = $before; priorComments = $comments; created = $created; verified = $verified; after = $after } | ConvertTo-Json -Depth 15 -Compress
'@
        $legacyOutputs = @(foreach ($finding in $findings) { & ([scriptblock]::Create($scratch)) $legacy $finding })
        $shared.plan.actions = $findings
        $caseRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $caseRoot | Out-Null
        $planPath = Join-Path $caseRoot 'plan.json'
        $shared.plan | ConvertTo-Json -Depth 15 | Set-Content $planPath
        $result = & $script:ActionsScript -PlanPath $planPath -ReceiptPath (Join-Path $caseRoot 'receipt.json') -Apply -AuthorizationMode Iterative -AuthorizedTarget 'demo/service/42' -EnvironmentReader $shared.environment -HttpInvoker $shared.http -DelayInvoker $shared.delay -AsObject
        $sharedOutput = $result | ConvertTo-Json -Depth 12 -Compress
        $sharedCall = '& $helper -PlanPath $planPath -Apply -AuthorizationMode Iterative -AuthorizedTarget ''demo/service/42'''
        $metrics = [ordered]@{
            fixture = 'six-identical-pre-reviewed-findings-success-path'; reviewJudgmentCost = 'excluded-same-evidence'
            legacy = @{ toolInvocations = 6; generatedPowerShellBytes = ([Text.Encoding]::UTF8.GetByteCount($scratch) * 6); returnedBytes = [Text.Encoding]::UTF8.GetByteCount(($legacyOutputs -join "`n")); httpCalls = $legacy.state.calls.Count }
            shared = @{ toolInvocations = 1; generatedPowerShellBytes = [Text.Encoding]::UTF8.GetByteCount($sharedCall); returnedBytes = [Text.Encoding]::UTF8.GetByteCount($sharedOutput); httpCalls = $shared.state.calls.Count }
            tokens = $null; tokenMeasurement = 'not-available'; scope = 'synthetic invocation count and UTF8 bytes; baseline lacks new recovery/ownership features'
        }
        $legacy.state.postCount | Should -Be 6
        $shared.state.postCount | Should -Be 6
        @($result.results | Where-Object status -EQ 'succeeded').Count | Should -Be 6
        $metrics.shared.returnedBytes | Should -BeLessThan $metrics.legacy.returnedBytes
        Write-Host ('SYP275_BENCHMARK=' + ($metrics | ConvertTo-Json -Depth 10 -Compress))
    }
}

Describe 'Bitbucket remote mechanics with offline fixtures' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'fixtures/BitbucketReviewFixture.ps1')
        $script:ActionsScript = Join-Path (Split-Path -Parent $PSScriptRoot) 'skills/review-bitbucket-pull-request/scripts/Invoke-BitbucketReviewActions.ps1'
        function Invoke-FixtureReview {
            param([hashtable] $Extra = @{})
            $script:Fixture.plan | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $script:PlanPath
            $arguments = @{
                PlanPath = $script:PlanPath; ReceiptPath = $script:ReceiptPath; Apply = $true
                AuthorizationMode = 'Iterative'; AuthorizedTarget = 'demo/service/42'; AsObject = $true
                HttpInvoker = $script:Fixture.http; EnvironmentReader = $script:Fixture.environment; DelayInvoker = $script:Fixture.delay
            }
            foreach ($key in $Extra.Keys) { $arguments[$key] = $Extra[$key] }
            & $script:ActionsScript @arguments
        }
        function Add-Root {
            param([long] $Id = 9, [long] $ParentId = 0)
            $parent = if ($ParentId) { @{ id = $ParentId } } else { $null }
            [void]$script:Fixture.state.comments.Add(@{ id = $Id; content = @{ raw = 'existing finding' }; parent = $parent; inline = $null; resolution = $null; deleted = $false })
        }
        function Set-Resolve {
            param([string] $Assessment = 'fixed', [bool] $Verified = $true, [long] $CommentId = 9)
            $script:Fixture.plan.actions = @(@{ id = 'resolve-01'; findingId = 'finding-01'; type = 'Resolve'; commentId = $CommentId; assessment = $Assessment; verifiedInPr = $Verified; evidence = 'verified PR diff and test' })
        }
    }
    BeforeEach {
        $script:Fixture = New-BitbucketReviewFixture
        $caseRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $caseRoot | Out-Null
        $script:PlanPath = Join-Path $caseRoot 'plan.json'
        $script:ReceiptPath = Join-Path $caseRoot 'receipt.json'
    }

    It 'UnitT10_Given_complete_review_When_create_is_authorized_Then_re_read_and_persist_mapping' {
        # Scenario: One new finding is published on an unchanged commit pair.
        # Purpose: Preserve a verified finding-to-root mapping and compact result.
        $result = Invoke-FixtureReview
        $result.results[0].status | Should -Be 'succeeded'
        $result.results[0].rootCommentId | Should -Be 100
        $result.exitCode | Should -Be 0
        $receipt = Get-Content $script:ReceiptPath -Raw | ConvertFrom-Json
        $receipt.records[0].findingId | Should -Be 'finding-01'
        $receipt.records[0].sourceCommit | Should -Be ('a' * 40)
        $script:Fixture.state.calls.method | Should -Contain 'POST'
    }

    It 'UnitT15_Given_one_shot_publication_When_other_actions_are_requested_Then_no_lifecycle_authority' {
        # Scenario: Only create-01 is included in a one-time publish instruction.
        # Purpose: A draft publication does not authorize replies or Resolve.
        Add-Root
        $script:Fixture.plan.actions += @{ id = 'resolve-01'; findingId = 'other'; type = 'Resolve'; commentId = 9; assessment = 'fixed'; verifiedInPr = $true; evidence = 'test' }
        $result = Invoke-FixtureReview @{ AuthorizationMode = 'Publish'; AuthorizedActionIds = @('create-01'); IncludedRootCommentIds = @(9) }
        $result.results.status | Should -Be @('succeeded', 'unauthorized')
        $script:Fixture.state.postCount | Should -Be 1
        $result.exitCode | Should -Be 1
    }

    It 'UnitT20_Given_authority_for_other_PR_When_apply_runs_Then_zero_HTTP' {
        # Scenario: Trusted authority names a different PR ID.
        # Purpose: PR identity must isolate authorization.
        $result = Invoke-FixtureReview @{ AuthorizedTarget = 'demo/service/43' }
        $result.results[0].status | Should -Be 'unauthorized'
        $script:Fixture.state.calls.Count | Should -Be 0
    }

    It 'UnitT25_Given_new_commits_When_review_is_fresh_Then_same_PR_authority_continues' {
        # Scenario: A previously authorized PR has a new source commit and fresh review.
        # Purpose: Analysis changes do not revoke trusted session authority.
        $script:Fixture.state.source = 'c' * 40
        $script:Fixture.plan.sourceCommit = 'c' * 40
        (Invoke-FixtureReview).results[0].status | Should -Be 'succeeded'
    }

    It 'UnitT30_Given_stale_pair_When_publish_runs_Then_no_POST' {
        # Scenario: Destination changes before the first operation.
        # Purpose: Both reviewed commits gate publication.
        $script:Fixture.state.destination = 'c' * 40
        $result = Invoke-FixtureReview
        $result.results[0].status | Should -Be 'stale-review'
        $script:Fixture.state.postCount | Should -Be 0
    }

    It 'UnitT35_Given_batch_When_pair_changes_after_first_write_Then_report_partial_completion' {
        # Scenario: Two findings are planned; destination changes after the first POST.
        # Purpose: Stop remaining operations and retain truthful success evidence.
        $script:Fixture.plan.actions += @{ id = 'create-02'; findingId = 'finding-02'; type = 'Create'; assessment = 'new'; content = 'Second finding'; evidence = 'test' }
        $script:Fixture.state.changeAtRead = 2
        $result = Invoke-FixtureReview
        $result.results.status | Should -Be @('succeeded', 'not-run')
        $result.results[0].error | Should -Be 'version-changed-after-write'
        $result.exitCode | Should -Be 1
        $script:Fixture.state.postCount | Should -Be 1
    }

    It 'UnitT40_Given_fixed_in_PR_When_root_is_explicitly_included_Then_resolve_and_verify' {
        # Scenario: An included root finding is verified fixed in the reviewed PR.
        # Purpose: Support deliberate inclusion of other threads.
        Add-Root; Set-Resolve
        $result = Invoke-FixtureReview @{ IncludedRootCommentIds = @(9) }
        $result.results[0].status | Should -Be 'succeeded'
        $script:Fixture.state.comments[0].resolution | Should -Not -BeNullOrEmpty
    }

    It 'UnitT45_Given_<Assessment>_When_resolve_is_requested_Then_preserve_thread' -ForEach @(
        @{ Assessment = 'still-present'; Verified = $true }, @{ Assessment = 'insufficient'; Verified = $false }, @{ Assessment = 'local-only'; Verified = $false }, @{ Assessment = 'fixed'; Verified = $false }
    ) {
        # Scenario: A finding is not established as fixed in the remote PR.
        # Purpose: Local changes and missing verification cannot resolve a thread.
        Add-Root; Set-Resolve -Assessment $Assessment -Verified $Verified
        $result = Invoke-FixtureReview @{ IncludedRootCommentIds = @(9) }
        $result.results[0].status | Should -Be 'retained'
        $script:Fixture.state.postCount | Should -Be 0
    }

    It 'UnitT50_Given_unowned_same_author_thread_When_resolve_runs_Then_preserve' {
        # Scenario: A matching-looking root has no process receipt or explicit inclusion.
        # Purpose: Author identity or content similarity is not ownership.
        Add-Root; Set-Resolve
        (Invoke-FixtureReview).results[0].status | Should -Be 'not-owned'
        $script:Fixture.state.postCount | Should -Be 0
    }

    It 'UnitT52_Given_created_root_When_re_review_fixes_finding_Then_receipt_proves_scope' {
        # Scenario: The same process created the root, then fresh evidence proves a fix.
        # Purpose: Iterative Resolve uses a traceable finding mapping without inclusion.
        [void](Invoke-FixtureReview)
        Set-Resolve -CommentId 100
        $result = Invoke-FixtureReview
        $result.results[0].status | Should -Be 'succeeded'
        $result.results[0].rootCommentId | Should -Be 100
    }

    It 'UnitT55_Given_paged_reply_chain_When_resolve_targets_child_Then_use_root' {
        # Scenario: A grandchild and root span multiple comment pages.
        # Purpose: Resolve the actual root and preserve all context evidence.
        Add-Root 9; Add-Root 10 9; Add-Root 11 10; Set-Resolve -CommentId 11
        $result = Invoke-FixtureReview @{ IncludedRootCommentIds = @(9); ContextPath = (Join-Path $TestDrive 'context.json') }
        $result.results[0].rootCommentId | Should -Be 9
        @($script:Fixture.state.calls | Where-Object { $_.uri -match 'comments\?page=2' }).Count | Should -BeGreaterThan 0
        $context = Get-Content (Join-Path $TestDrive 'context.json') -Raw | ConvertFrom-Json
        $context.comments.Count | Should -Be 3
        $context.activity.Count | Should -Be 1
    }

    It 'UnitT60_Given_inline_create_and_reply_When_publish_runs_Then_payloads_have_correct_sides_and_parent' {
        # Scenario: New-side and old-side inline findings and a reply are planned.
        # Purpose: Prevent misplaced inline comments or child-root confusion.
        $script:Fixture.plan.actions[0].inline = @{ path = 'src/retry.ps1'; to = 12; start_to = 10 }
        [void](Invoke-FixtureReview)
        $script:Fixture.plan.actions = @(@{ id = 'reply-01'; findingId = 'finding-01'; type = 'Reply'; commentId = 100; assessment = 'still-present'; newEvidence = $true; content = 'Fresh failure evidence'; evidence = 'regression' })
        $result = Invoke-FixtureReview
        $posts = @($script:Fixture.state.calls | Where-Object method -EQ 'POST')
        ($posts[0].body | ConvertFrom-Json).inline.to | Should -Be 12
        ($posts[1].body | ConvertFrom-Json).parent.id | Should -Be 100
        $result.results[0].rootCommentId | Should -Be 100
        $script:Fixture.plan.actions = @(@{ id = 'old-01'; findingId = 'old'; type = 'Create'; assessment = 'new'; content = 'Removed-side bug'; inline = @{ path = 'src/retry.ps1'; from = 4 }; evidence = 'diff' })
        [void](Invoke-FixtureReview)
        $lastPost = @($script:Fixture.state.calls | Where-Object method -EQ 'POST')[-1]
        ($lastPost.body | ConvertFrom-Json).inline.from | Should -Be 4
    }

    It 'UnitT62_Given_no_new_evidence_When_reply_runs_Then_retain_without_noise' {
        # Scenario: A still-present finding has no new evidence to add.
        # Purpose: Avoid repeating the original comment.
        Add-Root
        $script:Fixture.plan.actions = @(@{ id = 'reply-01'; findingId = 'finding-01'; type = 'Reply'; commentId = 9; assessment = 'still-present'; newEvidence = $false; content = 'Same evidence'; evidence = 'old' })
        (Invoke-FixtureReview).results[0].status | Should -Be 'retained'
        $script:Fixture.state.postCount | Should -Be 0
    }

    It 'UnitT65_Given_success_receipt_When_same_action_repeats_Then_verify_without_POST' {
        # Scenario: A caller repeats the same publication after completion.
        # Purpose: Idempotency relies on the remote comment plus receipt.
        [void](Invoke-FixtureReview)
        (Invoke-FixtureReview).results[0].status | Should -Be 'already-completed'
        $script:Fixture.state.postCount | Should -Be 1
    }

    It 'UnitT67_Given_resolved_root_When_resolve_runs_Then_skip' {
        # Scenario: A root is already resolved on the server.
        # Purpose: Repeated Resolve needs no mutation.
        Add-Root; $script:Fixture.state.comments[0].resolution = @{ type = 'comment_resolution' }; Set-Resolve
        (Invoke-FixtureReview @{ IncludedRootCommentIds = @(9) }).results[0].status | Should -Be 'already-resolved'
        $script:Fixture.state.postCount | Should -Be 0
    }

    It 'UnitT68_Given_failed_resolve_and_unrelated_empty_comment_When_retried_Then_target_root_is_resolved' {
        # Scenario: A failed Resolve is retried while another root has empty content.
        # Purpose: Comment payload reconciliation cannot prove that a Resolve succeeded.
        Add-Root; Set-Resolve
        [void]$script:Fixture.state.comments.Add(@{ id = 10; content = @{ raw = '' }; parent = $null; inline = $null; resolution = $null; deleted = $false })
        $script:Fixture.state.postStatus = 409
        (Invoke-FixtureReview @{ IncludedRootCommentIds = @(9) }).results[0].status | Should -Be 'failed'
        $script:Fixture.state.postStatus = 0

        $retry = Invoke-FixtureReview @{ IncludedRootCommentIds = @(9) }
        $retry.results[0].status | Should -Be 'succeeded'
        $script:Fixture.state.postCount | Should -Be 2
        $script:Fixture.state.comments[0].resolution | Should -Not -BeNullOrEmpty
        $script:Fixture.state.comments[1].resolution | Should -BeNullOrEmpty
    }

    It 'UnitT70_Given_timeout_<Mode>_When_write_is_checked_Then_<Expected>_and_no_blind_retry' -ForEach @(
        @{ Mode = 'after'; Expected = 'succeeded' }, @{ Mode = 'before'; Expected = 'uncertain' }, @{ Mode = 'ambiguous'; Expected = 'uncertain' }
    ) {
        # Scenario: A timed-out POST may succeed, fail before sending, or match multiple comments.
        # Purpose: Reconcile uniquely or keep uncertainty durable across retries.
        $script:Fixture.state.timeoutMode = $Mode
        $result = Invoke-FixtureReview
        $result.results[0].status | Should -Be $Expected
        $script:Fixture.state.timeoutMode = ''
        [void](Invoke-FixtureReview)
        $script:Fixture.state.postCount | Should -Be 1
    }

    It 'UnitT75_Given_HTTP_<Status>_When_POST_fails_Then_nonzero_and_no_success_claim' -ForEach @(@{ Status = 401 }, @{ Status = 403 }, @{ Status = 404 }, @{ Status = 409 }, @{ Status = 429 }) {
        # Scenario: A POST returns a definite HTTP failure.
        # Purpose: Conflicts and throttling do not become success or blind retry.
        $script:Fixture.state.postStatus = $Status
        $result = Invoke-FixtureReview
        $result.results[0].status | Should -Be 'failed'
        $result.results[0].error | Should -Be "http-$Status"
        $result.exitCode | Should -Be 1
        $LASTEXITCODE | Should -Be 1
        $result | ConvertTo-Json -Depth 10 | Should -Not -Match 'private-token-canary|private-email'
    }

    It 'UnitT77_Given_GET_429_When_read_retries_Then_bounded_success' {
        # Scenario: The first metadata read is throttled.
        # Purpose: Safe reads have bounded retry with server delay.
        $script:Fixture.state.getStatus = 429
        (Invoke-FixtureReview).results[0].status | Should -Be 'succeeded'
        $script:Fixture.state.delayCount | Should -Be 1
    }

    It 'UnitT80_Given_cross_host_or_cross_PR_next_When_pages_are_read_Then_reject_before_credentials_leave_target' -ForEach @(
        @{ Next = 'https://evil.example/steal' }, @{ Next = 'https://api.bitbucket.org/2.0/repositories/demo/service/pullrequests/43/comments' }, @{ Next = 'https://api.bitbucket.org@evil.example/steal' }
    ) {
        # Scenario: A response provides an untrusted pagination location.
        # Purpose: Never follow credentials to another host or PR.
        $script:Fixture.state.nextUrl = $Next
        $result = Invoke-FixtureReview
        $result.results[0].status | Should -Be 'failed'
        $script:Fixture.state.calls.Count | Should -Be 1
        $script:Fixture.state.postCount | Should -Be 0
    }

    It 'UnitT82_Given_corrupt_receipt_When_apply_runs_Then_fail_closed_before_HTTP' {
        # Scenario: A malformed or future-version mapping exists.
        # Purpose: Unknown mapping state cannot authorize ownership or replay.
        Set-Content $script:ReceiptPath '{"schemaVersion":999,"records":[]}'
        (Invoke-FixtureReview).results[0].status | Should -Be 'failed'
        $script:Fixture.state.calls.Count | Should -Be 0
    }

    It 'UnitT84_Given_incomplete_local_review_When_apply_runs_Then_zero_mutations' {
        # Scenario: Full local diff validation is incomplete.
        # Purpose: API context and metadata cannot replace local Review.
        $script:Fixture.plan.review.completeLocalDiff = $false
        (Invoke-FixtureReview).results[0].status | Should -Be 'incomplete-review'
        $script:Fixture.state.postCount | Should -Be 0
    }

    It 'UnitT86_Given_remote_instructions_When_local_only_runs_Then_ignore_instructions' {
        # Scenario: Remote metadata contains text that asks for unauthorized actions.
        # Purpose: HTTP and plan data never become executable directives or authority.
        $script:Fixture.plan.actions[0].content = '$(Set-Content injected.txt bad)'
        $result = Invoke-FixtureReview @{ LocalOnly = $true }
        $result.results[0].status | Should -Be 'preview'
        Test-Path 'injected.txt' | Should -BeFalse
        $script:Fixture.state.calls.Count | Should -Be 0
    }

    It 'UnitT88_Given_unverified_readback_When_POST_returns_success_Then_uncertain' {
        # Scenario: A created comment re-read does not match the submitted payload.
        # Purpose: HTTP success alone does not prove action completion.
        $script:Fixture.state.tamperReadback = $true
        (Invoke-FixtureReview).results[0].status | Should -Be 'uncertain'
    }

    It 'UnitT90_Given_six_findings_When_batch_completes_Then_each_has_compact_result_and_no_credentials' {
        # Scenario: Six independent findings are published in one invocation.
        # Purpose: Compact output retains every action while excluding API envelopes and secrets.
        $script:Fixture.plan.actions = @(1..6 | ForEach-Object { @{ id = "create-$_"; findingId = "finding-$_"; type = 'Create'; assessment = 'new'; content = "Finding $_"; evidence = 'fixture' } })
        $result = Invoke-FixtureReview
        $result.results.Count | Should -Be 6
        @($result.results | Where-Object status -EQ 'succeeded').Count | Should -Be 6
        $json = $result | ConvertTo-Json -Depth 12 -Compress
        $json | Should -Not -Match 'private-token-canary|private-email|content|Authorization'
        Get-Content $script:ReceiptPath -Raw | Should -Not -Match 'private-token-canary|private-email|Authorization'
    }

    It 'UnitT91_Given_POST_succeeded_When_readback_401_Then_uncertain_and_retry_reconciles' {
        # Scenario: The server accepted a comment but its verification read fails.
        # Purpose: A read error must not permit replay of an accepted mutation.
        $script:Fixture.state.readbackStatus = 401
        (Invoke-FixtureReview).results[0].status | Should -Be 'uncertain'
        $script:Fixture.state.readbackStatus = 0
        (Invoke-FixtureReview).results[0].status | Should -Be 'already-completed'
        $script:Fixture.state.postCount | Should -Be 1
    }

    It 'UnitT92_Given_verified_comment_When_post_pair_read_fails_Then_keep_success_and_stop_batch' {
        # Scenario: Verification succeeded but the subsequent commit check times out.
        # Purpose: Preserve verified success and stop without making replay possible.
        $script:Fixture.state.pairErrorAfterPost = $true
        $result = Invoke-FixtureReview
        $result.results[0].status | Should -Be 'succeeded'
        $result.exitCode | Should -Be 1
        $script:Fixture.state.pairErrorAfterPost = $false
        (Invoke-FixtureReview).results[0].status | Should -Be 'already-completed'
        $script:Fixture.state.postCount | Should -Be 1
    }

    It 'UnitT93_Given_unmapped_pending_finding_When_new_action_ID_runs_Then_no_duplicate' {
        # Scenario: A caller changes action ID while the original creation is uncertain.
        # Purpose: Pending finding state must prevent deduplication bypass.
        $script:Fixture.state.timeoutMode = 'before'
        [void](Invoke-FixtureReview)
        $script:Fixture.state.timeoutMode = ''
        $script:Fixture.plan.actions[0].id = 'create-renamed'
        (Invoke-FixtureReview).results[0].status | Should -Be 'uncertain'
        $script:Fixture.state.postCount | Should -Be 1
    }

    It 'UnitT94_Given_read_context_When_preview_runs_Then_actual_metadata_and_all_evidence_are_saved' {
        # Scenario: Context acquisition precedes review and its supplied pair is stale.
        # Purpose: Read-only acquisition identifies actual commits without claiming review.
        $script:Fixture.state.source = 'c' * 40
        $script:Fixture.plan.actions = @()
        $contextPath = Join-Path (Split-Path $script:ReceiptPath) 'context.json'
        $result = Invoke-FixtureReview @{ Apply = $false; ReadContext = $true; ContextPath = $contextPath }
        $result.exitCode | Should -Be 0
        $context = Get-Content $contextPath -Raw | ConvertFrom-Json
        $context.metadata.source.commit.hash | Should -Be ('c' * 40)
        $script:Fixture.state.postCount | Should -Be 0
    }

    It 'UnitT95_Given_redirect_When_read_runs_Then_no_follow_or_credential_leak' {
        # Scenario: An API request responds with a redirect.
        # Purpose: Transport must not automatically forward Basic headers.
        $script:Fixture.state.getStatus = 302
        (Invoke-FixtureReview).results[0].error | Should -Be 'http-302'
        $script:Fixture.state.calls.Count | Should -Be 1
        $script:Fixture.state.postCount | Should -Be 0
    }

    It 'UnitT96_Given_duplicate_JSON_property_When_plan_is_loaded_Then_no_HTTP' {
        # Scenario: JSON contains duplicate case-equivalent target keys.
        # Purpose: Older PowerShell deserializers cannot silently change identity.
        $json = $script:Fixture.plan | ConvertTo-Json -Depth 15 -Compress
        $json = $json.Replace('"workspace":"demo"', '"workspace":"demo","workspace":"evil"')
        Set-Content $script:PlanPath $json
        $result = & $script:ActionsScript -PlanPath $script:PlanPath -Apply -AuthorizationMode Iterative -AuthorizedTarget 'demo/service/42' -HttpInvoker $script:Fixture.http -AsObject
        $result.exitCode | Should -Be 1
        $script:Fixture.state.calls.Count | Should -Be 0
    }

    It 'UnitT97_Given_partial_HTTP_failure_When_batch_stops_Then_every_action_has_result' {
        # Scenario: Two actions are planned and the first POST fails.
        # Purpose: Do not hide failed or unattempted operations in compact output.
        $script:Fixture.plan.actions += @{ id = 'create-02'; findingId = 'finding-02'; type = 'Create'; assessment = 'new'; content = 'Another'; evidence = 'fixture' }
        $script:Fixture.state.postStatus = 403
        $result = Invoke-FixtureReview
        $result.results.status | Should -Be @('failed', 'not-run')
        $result.results.actionId | Should -Be @('create-01', 'create-02')
        $script:Fixture.state.postCount | Should -Be 1
    }

    It 'UnitT98_Given_changed_action_identity_When_same_ID_is_reused_Then_block' {
        # Scenario: A caller edits content while reusing a completed action ID.
        # Purpose: Receipts cannot silently describe a different requested operation.
        [void](Invoke-FixtureReview)
        $script:Fixture.plan.actions[0].content = 'Different problem'
        (Invoke-FixtureReview).results[0].error | Should -Be 'action-identity-changed'
        $script:Fixture.state.postCount | Should -Be 1
    }

    It 'UnitT99_Given_receipt_with_fabricated_ownership_When_root_has_no_marker_Then_no_resolve' {
        # Scenario: A valid-looking receipt points at another process's root.
        # Purpose: Ownership requires remote marker and payload verification, not just IDs.
        [void](Invoke-FixtureReview)
        $script:Fixture.state.comments[0].content.raw = 'somebody else finding'
        $receipt = Get-Content $script:ReceiptPath -Raw | ConvertFrom-Json
        $raw = [ordered]@{ raw = 'somebody else finding'; parentId = $null; inline = $null } | ConvertTo-Json -Compress
        $receipt.records[0].payloadSha256 = ([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($raw))) -replace '-', '').ToLowerInvariant()
        $receipt | ConvertTo-Json -Depth 15 | Set-Content $script:ReceiptPath
        Set-Resolve -CommentId 100
        (Invoke-FixtureReview).results[0].status | Should -Be 'not-owned'
        $script:Fixture.state.postCount | Should -Be 1
    }

    Context 'Interrupted transport and root verification' {
        It 'UnitT10_Given_POST_500_after_mutation_When_resumed_Then_no_duplicate' {
            # Scenario: Server error occurs after the comment was stored.
            # Purpose: HTTP 5xx cannot justify a blind replay of a non-idempotent POST.
            $script:Fixture.state.postStatusAfterMutation = 500
            $result = Invoke-FixtureReview
            $result.results[0].status | Should -Be 'succeeded'
            $script:Fixture.state.postStatusAfterMutation = 0
            (Invoke-FixtureReview).results[0].status | Should -Be 'already-completed'
            $script:Fixture.state.postCount | Should -Be 1
        }

        It 'UnitT20_Given_wrong_root_in_resolution_read_When_verify_runs_Then_uncertain' {
            # Scenario: Post-write response contains another resolved comment ID.
            # Purpose: Verification must bind resolution to the requested root.
            Add-Root; Set-Resolve
            $script:Fixture.state.wrongResolutionId = $true
            (Invoke-FixtureReview @{ IncludedRootCommentIds = @(9) }).results[0].status | Should -Be 'uncertain'
        }
    }
}

Describe 'Windows PowerShell default receipt compatibility' {
    It 'InterT10_Given_<Kind>_When_PS51_uses_default_receipt_Then_verified_write_succeeds' -ForEach @(@{ Kind = 'repository' }, @{ Kind = 'worktree' }, @{ Kind = 'long-worktree' }) -Skip:(-not $IsWindows) {
        # Scenario: The default receipt is in .git or a worktree administrative directory.
        # Purpose: Expected Git stderr under Windows PowerShell must not abort receipt setup.
        $caseRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $repo = Join-Path $caseRoot 'repo'
        if ($Kind -eq 'long-worktree') {
            # Keep the final receipt below MAX_PATH while exercising an atomic
            # temporary filename that would exceed it if appended to the digest.
            $suffix = '\.git\worktrees\worktree\bitbucket-review\' + ('a' * 64) + '.json'
            $padding = 236 - ($repo.Length + $suffix.Length)
            if ($padding -gt 0) { $repo += 'x' * $padding }
        }
        New-Item -ItemType Directory -Path $repo -Force | Out-Null
        & git -C $repo init --quiet
        & git -C $repo -c user.name=Fixture -c user.email=fixture@example.test commit --allow-empty --quiet -m fixture
        if ($LASTEXITCODE -ne 0) { throw 'Could not prepare the isolated Git fixture.' }
        $cwd = $repo
        if ($Kind -like '*worktree') {
            $cwd = Join-Path $caseRoot 'worktree'
            & git -C $repo worktree add --quiet --detach $cwd HEAD
            if ($LASTEXITCODE -ne 0) { throw 'Could not prepare the isolated worktree fixture.' }
        }
        $wrapper = Join-Path $caseRoot 'wrapper.ps1'
        $wrapperText = @'
param($Root, $FixturePath, $HelperPath, $PlanPath)
Set-Location -LiteralPath $Root
. $FixturePath
$fixture = New-BitbucketReviewFixture
$fixture.plan | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $PlanPath
$result = & $HelperPath -PlanPath $PlanPath -Apply -AuthorizationMode Iterative -AuthorizedTarget 'demo/service/42' -EnvironmentReader $fixture.environment -HttpInvoker $fixture.http -DelayInvoker $fixture.delay -AsObject
$code = $LASTEXITCODE
$gitPath = & git rev-parse --git-path bitbucket-review
$receiptPresent = @(Get-ChildItem -LiteralPath $gitPath -Filter '*.json' -ErrorAction SilentlyContinue).Count -eq 1
$result | Add-Member -NotePropertyName actualReceiptPresent -NotePropertyValue $receiptPresent
$result | ConvertTo-Json -Depth 12 -Compress
exit $code
'@
        Set-Content -LiteralPath $wrapper -Value $wrapperText
        $fixturePath = Join-Path $PSScriptRoot 'fixtures/BitbucketReviewFixture.ps1'
        $helperPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'skills/review-bitbucket-pull-request/scripts/Invoke-BitbucketReviewActions.ps1'
        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapper -Root $cwd -FixturePath $fixturePath -HelperPath $helperPath -PlanPath (Join-Path $caseRoot 'plan.json')
        $LASTEXITCODE | Should -Be 0
        ($output | ConvertFrom-Json).results[0].status | Should -Be 'succeeded'
        ($output | ConvertFrom-Json).actualReceiptPresent | Should -BeTrue
    }
}
