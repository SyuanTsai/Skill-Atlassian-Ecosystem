## ADDED Requirements

### Requirement: [SYN-REQ-001] Disabled retry switch

The synthetic request handler SHALL send a subsequent request once when the administrator has disabled retries.

#### Scenario: [SYN-SCN-001] Next request after disabling retries

<!-- Source: BLOCK-1cc3e4409441085a3503 /root[1]/p[1], page 101 version 3 -->

- **GIVEN** The administrator has disabled the synthetic retry switch
- **WHEN** The next synthetic request is made
- **THEN** The request is sent once
