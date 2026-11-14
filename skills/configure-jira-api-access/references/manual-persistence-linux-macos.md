<!--
SPDX-FileCopyrightText: 2026 SyuanTsai
SPDX-License-Identifier: Apache-2.0
-->

# Manual persistence on Linux and macOS

On Linux and macOS, this Skill's configure helper script configures only the current process. User scope is supported on Windows only, so the configure helper script rejects `-TargetScope User` on these hosts.

To keep settings across sessions, you can add the non-secret settings listed in this Skill's configuration reference to your own shell startup file yourself, and inject this Skill's API token setting through an approved secret-store launcher when you start the Agent host. Never write the token in plain text to a shell startup file.

After you change these settings, recreate the Agent host process; only processes started after the change inherit them.

This Skill never edits shell startup files or OS secret stores.
