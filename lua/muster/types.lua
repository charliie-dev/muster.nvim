---Type definitions for muster.nvim. This module is documentation only: it holds
---no runtime state and exports an empty table, so requiring it is free.
---

---How a declared tool resolved.
---@alias muster.Status
---| '"found"'        # executable resolved
---| '"missing"'      # string command, not on $PATH
---| '"unverifiable"' # function-form command, or a predicate needing a real buffer
---| '"unknown"'      # the subsystem does not recognise this name
---| '"broken"'       # the subsystem's own lookup failed: it raised, or it
---                    # returned a structurally invalid config

---Where a found executable came from. `unknown` means `found` but `fs_realpath`
---failed — never the fallback for an unrecognised prefix, which is `system`.
---@alias muster.Source '"mason"'|'"nix"'|'"mise"'|'"brew"'|'"system"'|'"unknown"'

---@class muster.Probe
---@field status muster.Status
---@field binary? string    Executable NAME: the $PATH target and the Mason registry key.
---@field path? string      As resolved on $PATH; required when status == "found".
---@field realpath? string  Symlinks followed; present when "found" and fs_realpath succeeded.
---@field source? muster.Source Required when status == "found".
---@field reason? string    Required for "unverifiable", "unknown" and "broken".

---@class muster.LspDeclaration
---@field name string
---@field command string
---@alias muster.LspEntry string|muster.LspDeclaration

---@class (exact) muster.NvimLintDeclaration
---@field name string
---@field command string
---@alias muster.NvimLintEntry string|muster.NvimLintDeclaration

---@alias muster.UiBorderPart string|[string, string]
---@alias muster.UiBorder string|muster.UiBorderPart[]
---@alias muster.UiKeymap string|string[]|false

---@class (exact) muster.UiIcons
---@field found string
---@field missing string
---@field unknown string
---@field broken string
---@field unverifiable string
---@field pending string
---@field discovered string
---@field expanded string
---@field collapsed string

---@class (exact) muster.UiKeymaps
---@field close muster.UiKeymap
---@field active muster.UiKeymap
---@field all muster.UiKeymap
---@field issues muster.UiKeymap
---@field next_tab muster.UiKeymap
---@field previous_tab muster.UiKeymap
---@field details muster.UiKeymap
---@field search muster.UiKeymap
---@field help muster.UiKeymap
---@field refresh muster.UiKeymap
---@field copy_path muster.UiKeymap

---@class (exact) muster.UiTabs
---@field active string
---@field all string
---@field issues string

---@class muster.UiAdapterLabels
---@field [string] string

---@class (exact) muster.UiColumns
---@field status string
---@field tool string
---@field adapter string
---@field version string

---@class (exact) muster.UiDetails
---@field source string
---@field executable string
---@field path string
---@field realpath string
---@field reason string
---@field advice string

---@class (exact) muster.UiLabels
---@field title string
---@field tabs muster.UiTabs
---@field adapters muster.UiAdapterLabels
---@field columns muster.UiColumns
---@field details muster.UiDetails
---@field empty string
---@field no_matches string
---@field no_issues string
---@field search_prompt string
---@field help string

---@class (exact) muster.UiIconsOpts
---@field found? string
---@field missing? string
---@field unknown? string
---@field broken? string
---@field unverifiable? string
---@field pending? string
---@field discovered? string
---@field expanded? string
---@field collapsed? string

---@class (exact) muster.UiKeymapsOpts
---@field close? muster.UiKeymap
---@field active? muster.UiKeymap
---@field all? muster.UiKeymap
---@field issues? muster.UiKeymap
---@field next_tab? muster.UiKeymap
---@field previous_tab? muster.UiKeymap
---@field details? muster.UiKeymap
---@field search? muster.UiKeymap
---@field help? muster.UiKeymap
---@field refresh? muster.UiKeymap
---@field copy_path? muster.UiKeymap

---@class (exact) muster.UiTabsOpts
---@field active? string
---@field all? string
---@field issues? string

---@class (exact) muster.UiColumnsOpts
---@field status? string
---@field tool? string
---@field adapter? string
---@field version? string

---@class (exact) muster.UiDetailsOpts
---@field source? string
---@field executable? string
---@field path? string
---@field realpath? string
---@field reason? string
---@field advice? string

---@class (exact) muster.UiLabelsOpts
---@field title? string
---@field tabs? muster.UiTabsOpts
---@field adapters? muster.UiAdapterLabels
---@field columns? muster.UiColumnsOpts
---@field details? muster.UiDetailsOpts
---@field empty? string
---@field no_matches? string
---@field no_issues? string
---@field search_prompt? string
---@field help? string

---@class (exact) muster.UiOpts
---@field width? number
---@field height? number
---@field border? muster.UiBorder
---@field backdrop? integer
---@field icons? muster.UiIconsOpts
---@field labels? muster.UiLabelsOpts
---@field keymaps? muster.UiKeymapsOpts

---@class (exact) muster.UiConfig
---@field width number
---@field height number
---@field border muster.UiBorder
---@field backdrop integer
---@field icons muster.UiIcons
---@field labels muster.UiLabels
---@field keymaps muster.UiKeymaps

---@alias muster.UiTab '"active"'|'"all"'|'"issues"'

---@class muster.UiRenderState
---@field view muster.OverlayView
---@field ui muster.UiConfig
---@field tab muster.UiTab
---@field query string
---@field showing_help boolean
---@field expanded_key? string
---@field versions table<string, muster.Version>
---@field source_error? string
---@field revision integer

---@class muster.UiExtmark
---@field line integer 0-based line
---@field col integer 0-based byte column
---@field opts vim.api.keyset.set_extmark

---@class muster.UiVirtualText
---@field line integer 0-based line
---@field chunks [string, string][]
---@field pos? "eol"|"right_align"

---@class muster.UiRow
---@field kind "entry"|"diagnostic"|"note"
---@field key? string
---@field entry? muster.Entry

---@class muster.UiRender
---@field lines string[]
---@field extmarks muster.UiExtmark[]
---@field virtual_text muster.UiVirtualText[]
---@field row_by_line table<integer, muster.UiRow>
---@field line_by_key table<string, integer>
---@field anchors table<string, integer>
---@field revision integer

---@class muster.UiWindowOpenOpts
---@field source_bufnr integer
---@field ui muster.UiConfig
---@field on_resize fun(window: muster.UiWindow)
---@field on_error fun(err: any)

---@class muster.UiWindow
---@field source_bufnr integer
---@field buf integer
---@field win integer
---@field backdrop_buf? integer
---@field backdrop_win? integer
---@field valid fun(self: muster.UiWindow): boolean
---@field focus fun(self: muster.UiWindow)
---@field content_width fun(self: muster.UiWindow): integer
---@field cursor_line fun(self: muster.UiWindow): integer
---@field draw fun(self: muster.UiWindow, output: muster.UiRender, selected_key?: string)
---@field map fun(self: muster.UiWindow, lhs: string, callback: fun(), desc: string)
---@field close fun(self: muster.UiWindow)

---@class muster.UiHelpOpenOpts
---@field parent_win integer
---@field ui muster.UiConfig
---@field output muster.UiRender
---@field on_close fun()

---@class muster.UiHelp
---@field parent_win integer
---@field ui muster.UiConfig
---@field buf integer
---@field win integer
---@field valid fun(self: muster.UiHelp): boolean
---@field focus fun(self: muster.UiHelp)
---@field content_width fun(self: muster.UiHelp): integer
---@field draw fun(self: muster.UiHelp, output: muster.UiRender)
---@field resize fun(self: muster.UiHelp)
---@field close fun(self: muster.UiHelp, notify?: boolean)

---@class muster.SetupOpts
---@field mason_install_fallback? boolean Permit automatic Mason installation fallback.
---@field notify_on_startup? boolean Emit the automatic summary when problems exist.
---@field ui? muster.UiOpts
---@field lsp? muster.LspEntry[]
---@field conform? string[]
---@field nvim_lint? muster.NvimLintEntry[]
---@field lint? nil Rejected tombstone; use nvim_lint.
---@field install? nil Rejected tombstone; use mason_install_fallback.
---@field [string] any Adapter lists are keyed by adapter id.

---@class muster.Config
---@field mason_install_fallback boolean
---@field notify_on_startup boolean
---@field ui muster.UiConfig
---@field lsp? muster.LspEntry[]
---@field conform? string[]
---@field nvim_lint? muster.NvimLintEntry[]
---@field lint? nil Rejected tombstone; use nvim_lint.
---@field install? nil Rejected tombstone; use mason_install_fallback.
---@field [string] any Adapter lists are keyed by adapter id.

---One subsystem, adapted to a single interface.
---@class muster.Adapter
---@field id string
---@field __muster_builtin? boolean Internal marker set by the registry for built-in adapters.
---@field available fun(): boolean, string|nil Is the host plugin loaded? The
---  second return is why not — "installed but not loaded yet" and "not
---  installed" are different things and must not read alike.
---@field identity fun(entry: any): string Stable per-adapter report/dedupe key.
---@field probe fun(entry: any, bufnr: integer): muster.Probe
---@field live? fun(bufnr: integer): any[], string|nil Entries live for this
---  buffer, in the shape this adapter's own `identity`/`probe` accept, plus an
---  error when the query itself failed. Omitting `live` is a stated degradation;
---  a `live` that FAILED is not the same thing and must not render alike.
---  Overlay only.

---@class muster.Advice
---@field provider '"mason"'|'"nix"'|'"mise"'
---@field action '"install"'|'"declare"'
---@field ["package"]? string Only for one unique machine-readable package match.
---@field command? string Only when the provider has a real, unambiguous command.
---@field eligible? boolean E2 hand-off eligibility; automatic install results only.
---@field reason? string Honest generic reason when eligible == false.

---@class muster.ProcessResult
---@field code integer
---@field signal integer
---@field output string
---@field error? string

---@alias muster.MasonInstallOutcome
---| '"planned"'
---| '"dispatched"'
---| '"verifying"'
---| '"completed"'
---| '"failed"'
---| '"unknown"'

---@alias muster.MasonAvailability
---| '"not_checked"'
---| '"found"'
---| '"missing"'
---| '"unverifiable"'
---| '"unknown"'
---| '"broken"'

---@alias muster.MasonAttestation '"not_checked"'|'"full"'|'"partial"'|'"failed"'

---@class (exact) muster.MasonNonterminalResult
---@field outcome '"planned"'|'"dispatched"'|'"verifying"'
---@field availability '"not_checked"'
---@field attestation '"not_checked"'

---@class (exact) muster.MasonOperationFailureResult
---@field outcome '"failed"'|'"unknown"'
---@field availability '"not_checked"'
---@field attestation '"not_checked"'
---@field error string

---@class (exact) muster.MasonVerifiedResult
---@field outcome '"completed"'
---@field availability '"found"'
---@field attestation '"full"'

---@class (exact) muster.MasonPartialResult
---@field outcome '"completed"'
---@field availability '"found"'
---@field attestation '"partial"'
---@field attestation_reason string

---@class (exact) muster.MasonFoundAttestationFailedResult
---@field outcome '"completed"'
---@field availability '"found"'
---@field attestation '"failed"'
---@field attestation_reason string

---@class (exact) muster.MasonUnavailableAttestationFailedResult
---@field outcome '"completed"'
---@field availability '"not_checked"'|'"missing"'|'"unverifiable"'|'"unknown"'|'"broken"'
---@field attestation '"failed"'
---@field availability_reason string
---@field attestation_reason string

---@alias muster.MasonInstallResult muster.MasonNonterminalResult|muster.MasonOperationFailureResult|muster.MasonVerifiedResult|muster.MasonPartialResult|muster.MasonFoundAttestationFailedResult|muster.MasonUnavailableAttestationFailedResult

---@class muster.MasonAvailabilityEvidence
---@field status muster.MasonAvailability
---@field reason? string

---@class muster.MasonAttestationEvidence
---@field status muster.MasonAttestation
---@field reason? string

---@class (exact) muster.AutomaticMasonNonterminalStatus: muster.MasonNonterminalResult
---@field package string

---@class (exact) muster.AutomaticMasonOperationFailureStatus: muster.MasonOperationFailureResult
---@field package string

---@class (exact) muster.AutomaticMasonVerifiedStatus: muster.MasonVerifiedResult
---@field package string

---@class (exact) muster.AutomaticMasonPartialStatus: muster.MasonPartialResult
---@field package string

---@class (exact) muster.AutomaticMasonFoundAttestationFailedStatus: muster.MasonFoundAttestationFailedResult
---@field package string

---@class (exact) muster.AutomaticMasonUnavailableAttestationFailedStatus: muster.MasonUnavailableAttestationFailedResult
---@field package string

---@alias muster.AutomaticMasonItemStatus muster.AutomaticMasonNonterminalStatus|muster.AutomaticMasonOperationFailureStatus|muster.AutomaticMasonVerifiedStatus|muster.AutomaticMasonPartialStatus|muster.AutomaticMasonFoundAttestationFailedStatus|muster.AutomaticMasonUnavailableAttestationFailedStatus

---@class muster.AutomaticMasonStatus
---@field items muster.AutomaticMasonItemStatus[]

---@alias muster.AutomaticState '"idle"'|'"running"'|'"reported"'|'"failed"'|'"bridge_failed"'

---@class muster.AutomaticStatusBase
---@field mason? muster.AutomaticMasonStatus

---@class muster.AutomaticIdleStatus: muster.AutomaticStatusBase
---@field state '"idle"'

---@class muster.AutomaticRunningStatus: muster.AutomaticStatusBase
---@field state '"running"'

---@class muster.AutomaticReportedStatus: muster.AutomaticStatusBase
---@field state '"reported"'
---@field reason? string Degraded completion reason.

---@class muster.AutomaticFailedStatus: muster.AutomaticStatusBase
---@field state '"failed"'
---@field reason string

---@class muster.AutomaticBridgeFailedStatus: muster.AutomaticStatusBase
---@field state '"bridge_failed"'
---@field reason string

---@alias muster.AutomaticStatus muster.AutomaticIdleStatus|muster.AutomaticRunningStatus|muster.AutomaticReportedStatus|muster.AutomaticFailedStatus|muster.AutomaticBridgeFailedStatus

---@class muster.MasonInstallState
---@field outcome? muster.MasonInstallOutcome
---@field availability? muster.MasonAvailability
---@field attestation? muster.MasonAttestation
---@field error? string
---@field availability_reason? string
---@field attestation_reason? string

---@class muster.MasonInstallItem: muster.MasonInstallState
---@field package string
---@field binaries string[]
---@field registry_identity table
---@field spec_snapshot table
---@field entries muster.Entry[]
---@field lsp_names string[]
---@field install_path string
---@field deadline_reached? boolean
---@field _effects_disabled? boolean
---@field _expected_source? table
---@field _install_options? table
---@field _effective_install_options? table
---@field _compiler_state? { fingerprint: string, identity_matches: boolean, purl_type: string, source_representable: boolean, source: table }

---@class muster.MasonPlan
---@field enabled boolean
---@field refreshed boolean
---@field registry_identities string[]
---@field install_root string
---@field location any
---@field items muster.MasonInstallItem[]
---@field notes string[]

---@class muster.Entry
---@field adapter string      Adapter id; with `name` this is the dedupe key.
---@field name string         From `adapter.identity(entry)`.
---@field declared boolean    false = discovered live, never named in setup().
---@field probe muster.Probe
---@field advice muster.Advice[] Empty in raw `probe()` results and whenever
---  `declared == false`; complete when async `check()` invokes its callback.

---@class muster.Skip
---@field adapter string
---@field count integer  How many declared entries went unchecked.
---@field severity "info"|"warn"|"error" Follows the KIND of skip, not the count:
---  an adapter that raised is an error even with nothing declared behind it.
---@field reason string

---The public result. Its shape is covered by the compatibility promise.
---@class muster.Result
---@field entries muster.Entry[] Declared entries only.
---@field skipped muster.Skip[]
---@field bufnr integer         The buffer probes were resolved against.
---@field notes string[]        Environment warnings, e.g. Mason's PATH mode.

---Overlay-only. NOT part of muster.Result and carries no compatibility promise.
---@class muster.Version
---@field value? string   nil when unresolved; the column renders "—".
---@field tier 1|2|3|4
---@field reason? string  Why it is nil.

return {}
